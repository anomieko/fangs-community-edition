// wrap-call-arg: put a math call around one argument of matching calls, e.g. Add_FloatFloat(r, 1.0) ->
// Add_FloatFloat(Multiply_FloatFloat(r, 0.5), 1.0). The statement grows, so the code offsets after it move (Reflow).
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;

static partial class Program
{
    // Statements of f were edited in place (same count, other sizes): move every code offset into f along. An offset
    // into the middle of an edited statement is refused; one at its start stays at its start.
    static void Reflow(UAsset a, FunctionExport f, uint[] lo, uint oldTotal, HashSet<int> edited)
    {
        var funcs = CodeFunctions(a);
        var slots = funcs.Values.SelectMany(g => g.ScriptBytecode.SelectMany(st => SlotsIn(a, g, st, funcs)))
            .Concat(EventGraphSlots(a, funcs)).Where(s => s.Into == f).Select(s => (s, v: s.Get())).ToList();
        var ln = Starts(a, f.ScriptBytecode, out uint newTotal);
        if (ln.Length != lo.Length) throw new PatchError($"{f.ObjectName}: the statement count changed");
        uint Map(uint t)
        {
            if (t == uint.MaxValue) return t;
            if (t == oldTotal) return newTotal;
            if (t > oldTotal) throw new PatchError($"{f.ObjectName}: an offset {t} past the end ({oldTotal})");
            int i = Array.FindLastIndex(lo, s => s <= t);
            if (edited.Contains(i) && t != lo[i]) throw new PatchError($"{f.ObjectName}: an offset points into the edited statement {i}");
            return ln[i] + (t - lo[i]);
        }
        foreach (var (s, v) in slots) s.Set(Map(v));
    }

    // {"op": "wrap-call-arg", "function", "call", "arg", "from", "count", "with": <math function>, "args": [more args]}
    // The wrapping function must be called somewhere in this asset already: its call node (and import) is reused.
    static string WrapCallArg(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string call = Req(ed, "call"), from = Req(ed, "from"), with = Req(ed, "with");
        if (ed["arg"] == null || ed["count"] == null) throw new PatchError("wrap-call-arg needs \"arg\" and \"count\"");
        int arg = (int)ed["arg"], count = (int)ed["count"];
        var extra = ((JArray)ed["args"])?.Select(t => (string)t).ToList() ?? [];
        var template = a.Exports.OfType<FunctionExport>().Where(x => x.ScriptBytecode != null).SelectMany(x => All(a, x))
            .OfType<EX_FinalFunction>().FirstOrDefault(e => CallName(a, e) == with)
            ?? throw new PatchError($"wrap-call-arg: this asset never calls {with}; add the call another way");

        // the matching calls and the top-level statement each one is in
        var hits = new List<(int st, KismetExpression e)>();
        for (int i = 0; i < f.ScriptBytecode.Length; i++)
            foreach (var e in Statement(a, f.ScriptBytecode[i]))
                if (CallName(a, e) == call && Args(e) is { } ps && arg < ps.Length && Render(a, ps[arg]) == from) hits.Add((i, e));
        if (hits.Count != count)
            throw new PatchError($"{f.ObjectName}: {hits.Count} calls {call} with argument {arg} = {from}, patch expects {count}");

        var lo = Starts(a, f.ScriptBytecode, out uint oldTotal);
        foreach (var (_, e) in hits)
        {
            var wrapped = (EX_FinalFunction)Activator.CreateInstance(template.GetType());
            wrapped.StackNode = template.StackNode;
            wrapped.Parameters = [Args(e)[arg], .. extra.Select(t => MakeArg(a, f, t))];
            Args(e)[arg] = wrapped;
        }
        Reflow(a, f, lo, oldTotal, hits.Select(h => h.st).ToHashSet());
        return $"{f.ObjectName}: {hits.Count}x {call} argument {arg}: {from} -> {with}({from}{string.Concat(extra.Select(x => ", " + x))})";
    }

    // {"op": "replace-call-arg", "function", "call", "arg", "from", "count", "to": <insert-code expression>}: like
    // set-call-arg, but the new argument may have another size (e.g. a vector literal for a property read).
    static string ReplaceCallArg(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string call = Req(ed, "call"), from = Req(ed, "from");
        if (ed["arg"] == null || ed["count"] == null || ed["to"] == null) throw new PatchError("replace-call-arg needs \"arg\", \"count\" and \"to\"");
        int arg = (int)ed["arg"], count = (int)ed["count"];
        var hits = new List<(int st, KismetExpression e)>();
        for (int i = 0; i < f.ScriptBytecode.Length; i++)
            foreach (var e in Statement(a, f.ScriptBytecode[i]))
                if (CallName(a, e) == call && Args(e) is { } ps && arg < ps.Length && Render(a, ps[arg]) == from) hits.Add((i, e));
        if (hits.Count != count)
            throw new PatchError($"{f.ObjectName}: {hits.Count} calls {call} with argument {arg} = {from}, patch expects {count}");
        var lo = Starts(a, f.ScriptBytecode, out uint oldTotal);
        foreach (var (_, e) in hits) Args(e)[arg] = Expr(a, f, ed["to"]);
        Reflow(a, f, lo, oldTotal, hits.Select(h => h.st).ToHashSet());
        return $"{f.ObjectName}: {hits.Count}x {call} argument {arg}: {from} -> {ed["to"].ToString(Newtonsoft.Json.Formatting.None)}";
    }

    // {"op": "rename-prop-ref", "function", "from", "to", "count", optional "call"}: point property reads in one function at another
    // property of the same owner (e.g. MOBAProjectile.ProjectileSphere -> ProjectileInteractionsSphere). Same size.
    static string RenamePropRef(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string from = Req(ed, "from"), to = Req(ed, "to");
        if (ed["count"] == null) throw new PatchError("rename-prop-ref needs \"count\"");
        var ptrs = new List<KismetPropertyPointer>();
        string only = (string)ed["call"];   // optional: only in statements that make this call
        var exprs = only == null ? All(a, f)
            : f.ScriptBytecode.Select(st => Statement(a, st)).Where(es => es.Any(e => CallName(a, e) == only)).SelectMany(es => es).ToList();
        foreach (var e in exprs)
        {
            if (e is EX_VariableBase v && v.Variable?.New?.Path is { Length: > 0 } p1 && p1[^1].ToString() == from) ptrs.Add(v.Variable);
            if (e is EX_Context c && c.RValuePointer?.New?.Path is { Length: > 0 } p2 && p2[^1].ToString() == from) ptrs.Add(c.RValuePointer);
        }
        if (ptrs.Count != (int)ed["count"]) throw new PatchError($"{f.ObjectName}: {ptrs.Count} references to {from}, patch expects {(int)ed["count"]}");
        a.AddNameReference(new FString(to));
        uint size = Size(a, f);
        foreach (var ptr in ptrs) ptr.New.Path[^1] = new FName(a, to);
        if (Size(a, f) != size) throw new PatchError("rename-prop-ref changed the function's size");
        return $"{f.ObjectName}: {ptrs.Count} reference(s) {from} -> {to}";
    }
}
