// Rewriting a function's bytecode: whole statements can be inserted or removed, and every code offset that points
// into the function moves with them (docs/PATCHING.md, "Rewriting functions").
//
// Where code offsets live in a cooked 4.26 Blueprint:
// - in the function itself: EX_Jump, EX_JumpIfNot, EX_PushExecutionFlow, EX_Skip, EX_SwitchValue (case and end);
// - for an ubergraph (ExecuteUbergraph_<Class>), in other functions too: each event stub calls it with its entry
//   point as an int constant, latent actions resume it through FLatentActionInfo.Linkage (an EX_SkipOffsetConst inside
//   the struct constant, next to the function's name), and a UFunction may name it with an EventGraphCallOffset.
// EX_Context's skip count is the size of its own sub-expression, not an offset into the function: it only changes if
// that sub-expression does, so statements that move unchanged keep it.
using System.Buffers.Binary;
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;

static partial class Program
{
    // One stored code offset: the function it points into, and how to read and write it.
    sealed record Slot(FunctionExport Into, Func<uint> Get, Action<uint> Set, string What);

    static uint[] Starts(UAsset a, KismetExpression[] code, out uint total)
    {
        var s = new uint[code.Length];
        uint off = 0;
        for (int i = 0; i < code.Length; i++) { s[i] = off; off += code[i].GetSize(a); }
        total = off;
        return s;
    }

    static bool IsUbergraph(FunctionExport f) => f.ObjectName.ToString().StartsWith("ExecuteUbergraph_");

    static Dictionary<string, FunctionExport> CodeFunctions(UAsset a) =>
        a.Exports.OfType<FunctionExport>().Where(x => x.ScriptBytecode != null).ToDictionary(x => x.ObjectName.ToString());

    // The offsets stored in one statement of `own`.
    static List<Slot> SlotsIn(UAsset a, FunctionExport own, KismetExpression statement, Dictionary<string, FunctionExport> funcs)
    {
        var list = new List<Slot>();
        var latent = new HashSet<KismetExpression>(ReferenceEqualityComparer.Instance);
        var skips = new List<EX_SkipOffsetConst>();
        uint off = 0;
        statement.Visit(a, ref off, (e, _) =>
        {
            switch (e)
            {
                case EX_Jump j: list.Add(new(own, () => j.CodeOffset, v => j.CodeOffset = v, "jump")); break;
                case EX_JumpIfNot j: list.Add(new(own, () => j.CodeOffset, v => j.CodeOffset = v, "jump if not")); break;
                case EX_PushExecutionFlow p: list.Add(new(own, () => p.PushingAddress, v => p.PushingAddress = v, "push flow")); break;
                case EX_Skip s: list.Add(new(own, () => s.CodeOffset, v => s.CodeOffset = v, "skip")); break;
                case EX_SwitchValue sw:
                    list.Add(new(own, () => sw.EndGotoOffset, v => sw.EndGotoOffset = v, "switch end"));
                    for (int k = 0; k < sw.Cases.Length; k++)
                    {
                        int c = k;
                        list.Add(new(own, () => sw.Cases[c].NextOffset, v => sw.Cases[c].NextOffset = v, "switch case"));
                    }
                    break;
                case EX_FinalFunction call when call.Parameters is { Length: > 0 } && call.Parameters[0] is EX_IntConst entry
                                               && funcs.TryGetValue(Name(a, call.StackNode), out var g) && IsUbergraph(g):
                    list.Add(new(g, () => (uint)entry.Value, v => entry.Value = (int)v, "entry point"));
                    break;
                case EX_StructConst sc when Name(a, sc.Struct) == "LatentActionInfo":
                    // Linkage, UUID, ExecutionFunction, CallbackTarget
                    if (sc.Value.Length < 3 || sc.Value[2] is not EX_NameConst fn)
                        throw new PatchError($"{own.ObjectName}: a latent action info without a function name");
                    if (!funcs.TryGetValue(fn.Value.ToString(), out var h)) break;   // resumes a function without code here
                    switch (sc.Value[0])
                    {
                        case EX_SkipOffsetConst so: latent.Add(so); list.Add(new(h, () => so.Value, v => so.Value = v, "latent resume")); break;
                        case EX_IntConst ic: list.Add(new(h, () => (uint)ic.Value, v => ic.Value = (int)v, "latent resume")); break;
                        default: throw new PatchError($"{own.ObjectName}: latent action info with linkage {sc.Value[0].Token}");
                    }
                    break;
                case EX_SkipOffsetConst so: skips.Add(so); break;
            }
        });
        if (skips.Any(s => !latent.Contains(s)))
            throw new PatchError($"{own.ObjectName}: a code offset constant outside a latent action info; not handled");
        return list;
    }

    // UFunction.EventGraphFunction / EventGraphCallOffset, the last 8 bytes of a function export's extra data.
    static IEnumerable<Slot> EventGraphSlots(UAsset a, Dictionary<string, FunctionExport> funcs)
    {
        foreach (var f in a.Exports.OfType<FunctionExport>())
        {
            var x = f.Extras;
            if (x == null || x.Length < 8) continue;
            int graph = BinaryPrimitives.ReadInt32LittleEndian(x.AsSpan(x.Length - 8));
            if (graph == 0) continue;
            var g = new FPackageIndex(graph);
            if (!g.IsExport() || g.ToExport(a) is not FunctionExport target || target.ScriptBytecode == null) continue;
            yield return new(target,
                () => (uint)BinaryPrimitives.ReadInt32LittleEndian(f.Extras.AsSpan(f.Extras.Length - 4)),
                v => BinaryPrimitives.WriteInt32LittleEndian(f.Extras.AsSpan(f.Extras.Length - 4), (int)v),
                "event graph call");
        }
    }

    // Replace statements [index, index + remove) of f with `insert`, and move every code offset into f along.
    // - A jump to the statement at `index` lands on the inserted code, so it runs wherever that statement used to.
    // - With nothing inserted, a jump to removed code lands on what follows it. A jump into the middle of removed
    //   code, or (when replacing) to one of its later statements, is refused.
    // - Offsets inside `insert` that point into f are relative to the first inserted statement.
    static void Splice(UAsset a, FunctionExport f, int index, int remove, KismetExpression[] insert)
    {
        var old = f.ScriptBytecode;
        if (index < 0 || remove < 0 || index + remove > old.Length) throw new PatchError($"{f.ObjectName}: statements {index}..{index + remove} out of range");
        var funcs = CodeFunctions(a);
        var lo = Starts(a, old, out uint oldTotal);

        // Read every offset before anything moves.
        var slots = new List<Slot>();
        foreach (var g in funcs.Values)
            for (int i = 0; i < g.ScriptBytecode.Length; i++)
                if (g != f || i < index || i >= index + remove)
                    slots.AddRange(SlotsIn(a, g, g.ScriptBytecode[i], funcs));
        slots.AddRange(EventGraphSlots(a, funcs));
        var mine = slots.Where(s => s.Into == f).Select(s => (s, v: s.Get())).ToList();
        var inner = insert.SelectMany(st => SlotsIn(a, f, st, funcs)).Where(s => s.Into == f).Select(s => (s, v: s.Get())).ToList();

        f.ScriptBytecode = [.. old[..index], .. insert, .. old[(index + remove)..]];
        var ln = Starts(a, f.ScriptBytecode, out uint newTotal);
        uint At(int i) => i < ln.Length ? ln[i] : newTotal;

        uint Map(uint t)
        {
            if (t == uint.MaxValue) return t;   // -1: a latent action that resumes nowhere (e.g. a Delay with nothing after it)
            if (t == oldTotal) return newTotal;
            if (t > oldTotal) throw new PatchError($"{f.ObjectName}: an offset {t} past the end ({oldTotal})");
            int i = Array.FindLastIndex(lo, s => s <= t);
            if (i < index) return ln[i] + (t - lo[i]);
            if (i >= index + remove)
            {
                if (remove == 0 && i == index && t == lo[i]) return At(index);
                int j = i - remove + insert.Length;
                return ln[j] + (t - lo[i]);
            }
            if (t == lo[i] && (i == index || insert.Length == 0)) return At(index);
            throw new PatchError($"{f.ObjectName}: an offset points into the removed code (statement {i}, offset {t})");
        }

        foreach (var (s, v) in mine) s.Set(Map(v));
        foreach (var (s, v) in inner) s.Set(v + At(index));
    }

    // --- edits --------------------------------------------------------------------------------------------------

    static KismetExpression[] Statement(UAsset a, KismetExpression st)
    {
        var l = new List<KismetExpression>();
        uint off = 0;
        st.Visit(a, ref off, (e, _) => l.Add(e));
        return [.. l];
    }

    // Statements of f that contain a call to `call` (the statement is the call, or uses its result).
    static List<int> StatementsCalling(UAsset a, FunctionExport f, string call) =>
        Enumerable.Range(0, f.ScriptBytecode.Length).Where(i => Statement(a, f.ScriptBytecode[i]).Any(e => CallName(a, e) == call)).ToList();

    // A literal for a parameter of the given property type, or a variable the function already uses.
    static KismetExpression TypedArg(UAsset a, FunctionExport f, FProperty p, string text)
    {
        string type = p.SerializedType.ToString();
        switch (type, text)
        {
            case ("BoolProperty", "true"): return new EX_True();
            case ("BoolProperty", "false"): return new EX_False();
            case ("ObjectProperty", "self"): return new EX_Self();
            case ("ObjectProperty", "nullptr"): return new EX_NoObject();
        }
        if (type == "FloatProperty" && float.TryParse(text, System.Globalization.NumberStyles.Float, Inv, out var fv)) return new EX_FloatConst { Value = fv };
        if (type == "IntProperty" && int.TryParse(text, Inv, out var iv)) return new EX_IntConst { Value = iv };
        if (type == "ByteProperty" && byte.TryParse(text, Inv, out var bv)) return new EX_ByteConst { Value = bv };
        return MakeArg(a, f, text) is EX_VariableBase v ? v
            : throw new PatchError($"argument {p.Name}: '{text}' is not a {type} literal this tool can write, nor a variable of {f.ObjectName}");
    }

    // Insert a call to one of this Blueprint's own functions as a new statement of `function`:
    // at "start" or "end" (before the final return), or "before"/"after" the one statement that calls another function.
    static string InsertCall(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string call = Req(ed, "call");
        var target = a.Exports.OfType<FunctionExport>().SingleOrDefault(x => x.ObjectName.ToString() == call);
        // A function of a parent Blueprint isn't in this asset: the call works by name, but its parameters can't be
        // checked here, so the patch says "inherited" and the call takes no arguments.
        bool inherited = (bool?)ed["inherited"] ?? false;
        if (target == null && !inherited)
            throw new PatchError($"insert-call: '{call}' is not a function of this Blueprint (one of a parent Blueprint: \"inherited\": true)");
        if (target != null && inherited) throw new PatchError($"insert-call: '{call}' is a function of this Blueprint, not inherited");
        if (inherited && ed["args"] is JArray { Count: > 0 }) throw new PatchError("insert-call: an inherited function is called without arguments");
        var parms = target == null ? [] : (target.LoadedProperties ?? []).Where(p => p.PropertyFlags.HasFlag(EPropertyFlags.CPF_Parm)
                                                            && !p.PropertyFlags.HasFlag(EPropertyFlags.CPF_ReturnParm)).ToList();
        if (parms.Any(p => p.PropertyFlags.HasFlag(EPropertyFlags.CPF_OutParm)))
            throw new PatchError($"insert-call: {call} has output parameters; not supported");
        var texts = ((JArray)ed["args"])?.Select(t => (string)t).ToList() ?? [];
        if (texts.Count != parms.Count)
            throw new PatchError($"insert-call: {call} takes {parms.Count} arguments ({string.Join(", ", parms.Select(p => $"{p.SerializedType} {p.Name}"))}), patch gives {texts.Count}");
        var args = parms.Select((p, i) => TypedArg(a, f, p, texts[i])).ToArray();

        int index;
        string where;
        if ((string)ed["at"] is string at)
        {
            index = at switch
            {
                "start" => 0,
                "end" => EndIndex(f),
                _ => throw new PatchError($"insert-call: \"at\" is start or end, not '{at}'"),
            };
            where = $"at the {at}";
        }
        else
        {
            bool before = ed["before"] != null;
            string anchor = (string)(ed["before"] ?? ed["after"]) ?? throw new PatchError("insert-call needs \"at\", \"before\" or \"after\"");
            var hits = StatementsCalling(a, f, anchor);
            if (hits.Count != 1) throw new PatchError($"insert-call: {hits.Count} statements of {f.ObjectName} call {anchor}, need exactly 1");
            index = before ? hits[0] : hits[0] + 1;
            where = $"{(before ? "before" : "after")} the call to {anchor}";
        }
        if (IsUbergraph(f)) throw new PatchError("insert-call into an ubergraph isn't supported yet: its entry points and latent resumes need a test first");

        a.AddNameReference(new FString(call));
        var expr = new EX_LocalVirtualFunction { VirtualFunctionName = new FName(a, call), Parameters = args };
        Splice(a, f, index, 0, [expr]);
        return $"{f.ObjectName}: call {call}({string.Join(", ", texts)}) inserted {where} (statement {index})";
    }

    // Where "at end" inserts: before the function's final return (a cooked function ends with EX_Return, then
    // EX_EndOfScript). Every path that returns jumps there, so the inserted code runs on every way out.
    static int EndIndex(FunctionExport f)
    {
        var code = f.ScriptBytecode;
        int i = code.Length - 1;
        while (i >= 0 && code[i] is EX_EndOfScript) i--;
        if (i < 0 || code[i] is not EX_Return) throw new PatchError($"{f.ObjectName} doesn't end with a return");
        return i;
    }

    // Remove the statements that are a call to `call` (not those that use its result); "count" must match.
    static string RemoveCall(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string call = Req(ed, "call");
        if (ed["count"] == null) throw new PatchError("remove-call needs \"count\"");
        var hits = Enumerable.Range(0, f.ScriptBytecode.Length).Where(i => CallName(a, f.ScriptBytecode[i]) == call).ToList();
        if (hits.Count != (int)ed["count"]) throw new PatchError($"{f.ObjectName}: {hits.Count} statements are a call to {call}, patch expects {(int)ed["count"]}");
        foreach (int i in Enumerable.Reverse(hits)) Splice(a, f, i, 1, []);
        return $"{f.ObjectName}: {hits.Count}x call {call} removed";
    }

    // --- check ----------------------------------------------------------------------------------------------------

    // For every function of every asset under `root`: insert a 1-byte statement (start, middle, end), which moves
    // every offset after it, then remove it again; the asset must write back byte for byte. Also counts what was moved.
    static int CmdRewriteCheck(string root)
    {
        int assets = 0, funcs = 0, tries = 0, failed = 0, skipped = 0;
        var moved = new Dictionary<string, int>();
        foreach (var path in Directory.EnumerateFiles(root, "*.uasset", SearchOption.AllDirectories).Order())
        {
            UAsset a;
            try { a = Load(path); } catch { skipped++; continue; }
            var code = a.Exports.OfType<FunctionExport>().Where(x => x.ScriptBytecode != null).ToList();
            if (code.Count == 0) continue;
            byte[] orig;
            try { orig = a.WriteData().ToArray(); } catch { skipped++; continue; }
            assets++;
            foreach (var name in code.Select(x => x.ObjectName.ToString()).ToList())
            {
                var f = CodeFunctions(a)[name];
                funcs++;
                int n = f.ScriptBytecode.Length;
                foreach (int k in new[] { 0, n / 2, n }.Distinct())
                {
                    tries++;
                    try
                    {
                        var all = CodeFunctions(a);
                        foreach (var s in all.Values.SelectMany(g => g.ScriptBytecode.SelectMany(st => SlotsIn(a, g, st, all))).Concat(EventGraphSlots(a, all)))
                            if (s.Into == f) moved[s.What] = moved.GetValueOrDefault(s.What) + 1;
                        Splice(a, f, k, 0, [new EX_Nothing()]);
                        Splice(a, f, k, 1, []);
                        if (!a.WriteData().ToArray().AsSpan().SequenceEqual(orig))
                            throw new PatchError("differs after insert + remove");
                    }
                    catch (Exception ex)
                    {
                        failed++;
                        Console.WriteLine($"{Path.GetRelativePath(root, path)} {f.ObjectName} at {k}: {ex.Message}");
                        a = Load(path);   // start the asset over
                        break;
                    }
                }
            }
        }
        Console.WriteLine($"{assets} assets, {funcs} functions, {tries} insert+remove runs, {failed} failed, {skipped} assets not readable");
        Console.WriteLine("offsets moved per run: " + string.Join(", ", moved.OrderBy(m => m.Key).Select(m => $"{m.Key} {m.Value}")));
        return failed == 0 ? 0 : 1;
    }

    // Test aid: write a copy of the asset with a 1-byte statement (EX_Nothing) inserted before statement `at` of
    // `function`, so a decompile of the copy can be compared with the original's (every offset after it moves by 1).
    static int CmdNop(string path, string function, int at, string outDir)
    {
        var a = Load(path);
        Splice(a, Function(a, function), at, 0, [new EX_Nothing()]);
        Directory.CreateDirectory(outDir);
        a.Write(Path.Combine(outDir, Path.GetFileName(path)));
        return 0;
    }
}
