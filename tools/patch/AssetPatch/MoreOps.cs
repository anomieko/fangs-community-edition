// Edits added for the community patch (docs/PATCHING.md): name constants, constant branches, copies of a statement,
// and in-place edits that change a statement's size (Reshape, used by set-call-arg).
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;

static partial class Program
{
    // Where each expression of a function starts and ends (its whole subtree), in one layout.
    static Dictionary<KismetExpression, (uint start, uint end)> Spans(UAsset a, KismetExpression[] code)
    {
        var spans = new Dictionary<KismetExpression, (uint, uint)>(ReferenceEqualityComparer.Instance);
        uint off = 0;
        foreach (var st in code)
            st.Visit(a, ref off, (e, at) => { if (!spans.ContainsKey(e)) spans[e] = (at, at + e.GetSize(a)); });
        return spans;
    }

    // Change statements of f in place (none added or removed), then move every code offset into f to the new layout.
    // An offset into a statement whose size changed must be the start or the end of an expression that is still
    // there (a switch's case or its end), and moves with it.
    static void Reshape(UAsset a, FunctionExport f, Action change)
    {
        var funcs = CodeFunctions(a);
        var code = f.ScriptBytecode;
        var lo = Starts(a, code, out uint oldTotal);
        var oldSize = code.Select(st => st.GetSize(a)).ToArray();
        var before = Spans(a, code);
        var slots = new List<Slot>();
        foreach (var g in funcs.Values)
            foreach (var st in g.ScriptBytecode) slots.AddRange(SlotsIn(a, g, st, funcs));
        slots.AddRange(EventGraphSlots(a, funcs));
        var mine = slots.Where(s => s.Into == f).Select(s => (s, v: s.Get())).ToList();
        change();
        if (!ReferenceEquals(code, f.ScriptBytecode)) throw new PatchError($"{f.ObjectName}: statements were replaced, not changed");
        var ln = Starts(a, code, out uint newTotal);
        var after = Spans(a, code);
        uint Map(uint t)
        {
            if (t == uint.MaxValue) return t;
            if (t == oldTotal) return newTotal;
            int i = Array.FindLastIndex(lo, s => s <= t);
            if (t == lo[i] || code[i].GetSize(a) == oldSize[i]) return ln[i] + (t - lo[i]);
            // inside a statement that changed: the expression starting (or else ending) there, if it is still there
            foreach (var (e, (s, end)) in before)
                if (s == t && after.TryGetValue(e, out var n)) return n.start;
            foreach (var (e, (s, end)) in before)
                if (end == t && after.TryGetValue(e, out var n)) return n.end;
            throw new PatchError($"{f.ObjectName}: an offset points inside statement {i}, whose size changed, at no expression that is still there");
        }
        foreach (var (s, v) in mine) s.Set(Map(v));
    }

    // Swap the name in name constants of one function, e.g. the tag of a gameplay tag literal
    // (GameplayTag{Name("Data.Heal")}): the same size, so nothing moves.
    static string SetNameConst(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string from = Req(ed, "from"), to = Req(ed, "to");
        if (ed["count"] == null) throw new PatchError("set-name-const needs \"count\"");
        var hits = All(a, f).OfType<EX_NameConst>().Where(n => n.Value?.ToString() == from).ToList();
        if (hits.Count != (int)ed["count"]) throw new PatchError($"{f.ObjectName}: {hits.Count} name constants '{from}', patch expects {(int)ed["count"]}");
        uint size = Size(a, f);
        a.AddNameReference(new FString(to));
        foreach (var n in hits) n.Value = new FName(a, to);
        if (Size(a, f) != size) throw new PatchError($"{f.ObjectName}: the name change changed the function's size");
        return $"{f.ObjectName}: {hits.Count}x name '{from}' -> '{to}'";
    }

    static bool ArgsMatch(UAsset a, KismetExpression call, Dictionary<int, string> match) =>
        match.All(m => m.Key < Args(call).Length && Render(a, Args(call)[m.Key]) == m.Value);

    static Dictionary<int, string> MatchOf(JToken t) =>
        ((JObject)t)?.Properties().ToDictionary(p => int.Parse(p.Name), p => (string)p.Value) ?? [];

    // The one statement of f that makes a call to `call` with arguments matching `match`.
    static int OneStatement(UAsset a, FunctionExport f, string call, Dictionary<int, string> match, string what)
    {
        var hits = Enumerable.Range(0, f.ScriptBytecode.Length)
            .Where(i => Statement(a, f.ScriptBytecode[i]).Any(e => CallName(a, e) == call && ArgsMatch(a, e, match))).ToList();
        if (hits.Count != 1)
            throw new PatchError($"{what}: {hits.Count} statements of {f.ObjectName} call {call}"
                                 + (match.Count > 0 ? $" with {string.Join(", ", match.Select(m => $"arg {m.Key} = {m.Value}"))}" : "") + ", need exactly 1");
        return hits[0];
    }

    // Flip a constant branch: the "if (!true)" or "if (!false)" right before the statement that calls `call` (with
    // "match" on its arguments; "count" such statements, default 1). E.g. a dash payload's flag
    // AddGameplayTag(…, Event.Identifiers.CanBeCrowdControlled) behind "if (!true)". One byte, nothing moves.
    static string SetBranch(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string call = Req(ed, "call");
        if (ed["from"] == null || ed["to"] == null) throw new PatchError("set-branch needs \"from\" and \"to\" (true/false)");
        bool from = (bool)ed["from"], to = (bool)ed["to"];
        var match = MatchOf(ed["match"]);
        var code = f.ScriptBytecode;
        var hits = Enumerable.Range(1, Math.Max(0, code.Length - 1))
            .Where(i => Statement(a, code[i]).Any(e => CallName(a, e) == call && ArgsMatch(a, e, match))).ToList();
        int expect = (int?)ed["count"] ?? 1;
        if (hits.Count != expect) throw new PatchError($"{f.ObjectName}: {hits.Count} statements call {call} (with the match), patch expects {expect}");
        foreach (int i in hits)
        {
            if (code[i - 1] is not EX_JumpIfNot j || j.BooleanExpression is not (EX_True or EX_False))
                throw new PatchError($"{f.ObjectName}: statement {i - 1}, before the call to {call}, is no constant branch");
            if (j.BooleanExpression is EX_True != from)
                throw new PatchError($"{f.ObjectName}: the branch before {call} is {(j.BooleanExpression is EX_True ? "true" : "false")}, patch expects {from}");
            j.BooleanExpression = to ? new EX_True() : new EX_False();
        }
        return $"{f.ObjectName}: {hits.Count}x branch before {call}{(match.Count > 0 ? " (" + string.Join(", ", match.Values) + ")" : "")}: {(from ? "true" : "false")} -> {(to ? "true" : "false")}";
    }

    // A new argument in place of `old`: a gameplay tag literal gets its tag swapped (text = the new tag); everything
    // else as set-call-arg makes it (a number, true/false, a variable, self.<class variable>).
    static KismetExpression NewArg(UAsset a, FunctionExport f, string text, KismetExpression old)
    {
        if (old is EX_StructConst sc && Name(a, sc.Struct) == "GameplayTag" && sc.Value is [EX_NameConst, ..]
            && !All(a, f).OfType<EX_VariableBase>().Any(v => Render(a, v) == text))
        {
            var copy = (EX_StructConst)Clone(a, sc);
            a.AddNameReference(new FString(text));
            ((EX_NameConst)copy.Value[0]).Value = new FName(a, text);
            return copy;
        }
        return MakeArgLike(a, f, text, old);
    }

    // Insert a copy of the one statement of `function` that calls `copy` ("match" narrows it by its arguments), with
    // arguments of the copied call changed ("args": {"<index>": "<new>"}), "before" or "after" the one statement that
    // calls another function ("anchor-match" narrows that one). The copy must hold no code offsets.
    static string InsertCopy(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string copy = Req(ed, "copy");
        var match = MatchOf(ed["match"]);
        int src = OneStatement(a, f, copy, match, "insert-copy");
        var clone = Clone(a, f.ScriptBytecode[src]);
        if (SlotsIn(a, f, clone, CodeFunctions(a)).Count > 0) throw new PatchError($"insert-copy: statement {src} holds code offsets; not supported");
        var call = Statement(a, clone).First(e => CallName(a, e) == copy && ArgsMatch(a, e, match));
        var changes = new List<string>();
        foreach (var p in ((JObject)ed["args"])?.Properties() ?? [])
        {
            int k = int.Parse(p.Name);
            if (k >= Args(call).Length) throw new PatchError($"insert-copy: {copy} has {Args(call).Length} arguments, not {k + 1}");
            string before = Render(a, Args(call)[k]);
            Args(call)[k] = NewArg(a, f, (string)p.Value, Args(call)[k]);
            changes.Add($"arg {k} {before} -> {(string)p.Value}");
        }
        bool isBefore = ed["before"] != null;
        string anchor = (string)(ed["before"] ?? ed["after"]) ?? throw new PatchError("insert-copy needs \"before\" or \"after\"");
        int at = OneStatement(a, f, anchor, MatchOf(ed["anchor-match"]), "insert-copy anchor");
        int index = isBefore ? at : at + 1;
        Splice(a, f, index, 0, [clone]);
        return $"{f.ObjectName}: copy of statement {src} ({copy}{(changes.Count > 0 ? "; " + string.Join(", ", changes) : "")}) inserted {(isBefore ? "before" : "after")} the call to {anchor} (statement {index})";
    }

    // self.<name>: a variable of this Blueprint's class that the function doesn't use yet.
    static EX_VariableBase ClassVariable(UAsset a, string text)
    {
        if (!text.StartsWith("self.")) return null;
        string name = text[5..];
        int ci = a.Exports.FindIndex(e => e is ClassExport);
        if (ci < 0) return null;
        var cls = (ClassExport)a.Exports[ci];
        if (!(cls.LoadedProperties ?? []).Any(p => p.Name?.ToString() == name)) return null;
        a.AddNameReference(new FString(name));
        return new EX_InstanceVariable
        {
            Variable = new KismetPropertyPointer(new FFieldPath([new FName(a, name)], FPackageIndex.FromExport(ci))),
        };
    }

    // For every function under `root` that has a number argument and a variable: swap that number for the variable
    // (another size: every offset after it moves, through Reshape), then back; the asset must write back byte for byte.
    static int CmdReshapeCheck(string root)
    {
        int assets = 0, tries = 0, failed = 0;
        foreach (var path in Directory.EnumerateFiles(root, "*.uasset", SearchOption.AllDirectories).Order())
        {
            UAsset a;
            try { a = Load(path); } catch { continue; }
            var names = a.Exports.OfType<FunctionExport>().Where(x => x.ScriptBytecode != null).Select(x => x.ObjectName.ToString()).ToList();
            if (names.Count == 0) continue;
            byte[] orig;
            try { orig = a.WriteData().ToArray(); } catch { continue; }
            assets++;
            foreach (var name in names)
            {
                var f = CodeFunctions(a)[name];
                var calls = All(a, f).Where(e => Args(e) != null).ToList();
                var site = calls.SelectMany(c => Args(c).Select((x, i) => (c, i, x))).FirstOrDefault(t => t.x is EX_FloatConst);
                var v = All(a, f).OfType<EX_LocalVariable>().FirstOrDefault();
                if (site.c == null || v == null) continue;
                tries++;
                try
                {
                    var old = Args(site.c)[site.i];
                    Reshape(a, f, () => Args(site.c)[site.i] = new EX_LocalVariable { Variable = v.Variable });
                    Reshape(a, f, () => Args(site.c)[site.i] = old);
                    if (!a.WriteData().ToArray().AsSpan().SequenceEqual(orig)) throw new PatchError("differs after the swap and back");
                }
                catch (Exception ex)
                {
                    failed++;
                    Console.WriteLine($"{Path.GetRelativePath(root, path)} {name}: {ex.Message}");
                    a = Load(path);
                }
            }
        }
        Console.WriteLine($"{assets} assets, {tries} functions reshaped and back, {failed} failed");
        return failed == 0 ? 0 : 1;
    }
}
