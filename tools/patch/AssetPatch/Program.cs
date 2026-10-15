// assetpatch: small, checked edits to cooked UE 4.26 Blueprint assets, for our patch pak (docs/PATCHING.md).
//
//   assetpatch info <asset.uasset>                       imports with their uses, class defaults, functions
//   assetpatch calls <asset.uasset> <function> [call]    calls in one function, with their arguments
//   assetpatch roundtrip <asset.uasset> <out-dir>         read and write back unchanged; fails if a byte differs
//   assetpatch apply <patch.json> <in-root> <out-root>    apply a patch; writes the edited assets under out-root
//
// Edits ("op"): set-default, rename-call, rename-import, set-call-arg (docs/PATCHING.md has the fields).
// Every edit states what it expects to find ("from", "uses", "count") and fails if the asset differs, so a patch
// can't silently apply to another build. Bytecode edits must keep the function's in-memory size: jump offsets
// inside the function are not recomputed.
using System.Globalization;
using System.Reflection;
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.PropertyTypes.Objects;
using UAssetAPI.PropertyTypes.Structs;
using UAssetAPI.UnrealTypes;

static class Program
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    class PatchError(string message) : Exception(message);

    static UAsset Load(string path) => new UAsset(path, EngineVersion.VER_UE4_26);

    static string Name(UAsset a, FPackageIndex i)
    {
        if (i == null || i.IsNull()) return "null";
        return i.IsImport() ? i.ToImport(a).ObjectName.ToString() : i.ToExport(a).ObjectName.ToString();
    }

    static string VarName(UAsset a, KismetPropertyPointer p)
    {
        if (p == null) return "?";
        if (p.New?.Path is { Length: > 0 } path) return path[^1].ToString();
        return Name(a, p.Old);
    }

    static string Num(float f) => f.ToString("0.0###", Inv);

    // Short text form of an argument, used to show calls and to match them in patches.
    static string Render(UAsset a, KismetExpression e) => e switch
    {
        EX_FloatConst f => Num(f.Value),
        EX_IntConst i => i.Value.ToString(Inv),
        EX_ByteConst b => b.Value.ToString(Inv),
        EX_True => "true",
        EX_False => "false",
        EX_Self => "self",
        EX_NoObject => "nullptr",
        EX_ObjectConst o => Name(a, o.Value),
        EX_InstanceVariable v => "self." + VarName(a, v.Variable),
        EX_VariableBase v => VarName(a, v.Variable),
        EX_Context c => Render(a, c.ObjectExpression) + "." + Render(a, c.ContextExpression),
        EX_FinalFunction f => Name(a, f.StackNode) + "(...)",
        EX_VirtualFunction f => f.VirtualFunctionName + "(...)",
        _ => e.Token.ToString(),
    };

    static string CallName(UAsset a, KismetExpression e) => e switch
    {
        EX_FinalFunction f => Name(a, f.StackNode),
        EX_VirtualFunction f => f.VirtualFunctionName.ToString(),
        _ => null,
    };

    static KismetExpression[] Args(KismetExpression e) => e switch
    {
        EX_FinalFunction f => f.Parameters,
        EX_VirtualFunction f => f.Parameters,
        _ => null,
    };

    // Every expression of a function, nested ones included.
    static List<KismetExpression> All(UAsset a, FunctionExport f)
    {
        var list = new List<KismetExpression>();
        uint off = 0;
        foreach (var st in f.ScriptBytecode ?? [])
            st.Visit(a, ref off, (e, _) => list.Add(e));
        return list;
    }

    static uint Size(UAsset a, FunctionExport f) => (uint)f.ScriptBytecode.Sum(st => st.GetSize(a));

    static FunctionExport Function(UAsset a, string name)
    {
        var fs = a.Exports.OfType<FunctionExport>().Where(f => f.ObjectName.ToString() == name).ToList();
        if (fs.Count != 1) throw new PatchError($"function '{name}': found {fs.Count}");
        if (fs[0].ScriptBytecode == null) throw new PatchError($"function '{name}': bytecode could not be parsed");
        return fs[0];
    }

    static NormalExport ClassDefaults(UAsset a)
    {
        var cdo = a.Exports.OfType<NormalExport>().Where(e => e.ObjectName.ToString().StartsWith("Default__")).ToList();
        if (cdo.Count != 1) throw new PatchError($"class defaults: found {cdo.Count} Default__ exports");
        return cdo[0];
    }

    // --- where imports are used -------------------------------------------------------------------------------

    static IEnumerable<FPackageIndex> IndexFields(KismetExpression e)
    {
        foreach (var fld in e.GetType().GetFields(BindingFlags.Public | BindingFlags.Instance))
        {
            switch (fld.GetValue(e))
            {
                case FPackageIndex pi: yield return pi; break;   // StackNode, object constants (RawValue), ...
                case KismetPropertyPointer kp:
                    if (kp.Old != null) yield return kp.Old;
                    if (kp.New?.ResolvedOwner != null) yield return kp.New.ResolvedOwner;
                    break;
            }
        }
    }

    static IEnumerable<FPackageIndex> PropertyRefs(IEnumerable<PropertyData> props)
    {
        foreach (var p in props ?? [])
        {
            switch (p)
            {
                case ObjectPropertyData o: yield return o.Value; break;
                case StructPropertyData s: foreach (var r in PropertyRefs(s.Value)) yield return r; break;
                case ArrayPropertyData arr: foreach (var r in PropertyRefs(arr.Value)) yield return r; break;
            }
        }
    }

    // How often an import is used: in function bytecode, in property values (class defaults, components), and as
    // the outer of other imports (a package import is the outer of its class).
    static (int code, int props, int outer) Uses(UAsset a, int importIndex)
    {
        int raw = -(importIndex + 1);
        bool Hit(FPackageIndex i) => i != null && i.Index == raw;
        int code = a.Exports.OfType<FunctionExport>().Where(f => f.ScriptBytecode != null)
            .Sum(f => All(a, f).Sum(e => IndexFields(e).Count(Hit)));
        int props = a.Exports.OfType<NormalExport>().Sum(e => PropertyRefs(e.Data).Count(Hit));
        int outer = a.Imports.Count(i => Hit(i.OuterIndex));
        return (code, props, outer);
    }

    // --- edits --------------------------------------------------------------------------------------------------

    static string Req(JObject o, string k) => (string)o[k] ?? throw new PatchError($"edit is missing '{k}'");

    // Point an import at another object (e.g. the class BP_GE_Root_C -> BP_GE_Stun_C, and its package with it).
    // Every use in the asset follows; "uses" must match the number of uses. Imports whose class or class package
    // is the renamed object (Default__BP_GE_Root_C is a BP_GE_Root_C from package BP_GE_Root) are updated too:
    // the game checks an import's class when it loads it.
    static string RenameImport(UAsset a, JObject ed)
    {
        string from = Req(ed, "from"), to = Req(ed, "to");
        var hits = Enumerable.Range(0, a.Imports.Count).Where(i => a.Imports[i].ObjectName.ToString() == from).ToList();
        if (hits.Count != 1) throw new PatchError($"import '{from}': found {hits.Count}");
        if (a.Imports.Any(i => i.ObjectName.ToString() == to)) throw new PatchError($"import '{to}' already exists; point the uses at it instead");
        var imp = a.Imports[hits[0]];
        var (code, props, outer) = Uses(a, hits[0]);
        int uses = code + props + outer;
        string where = $"{code} in code, {props} in values, outer of {outer} imports";
        if (ed["uses"] == null) throw new PatchError($"import '{from}': state \"uses\" ({uses}: {where})");
        if ((int)ed["uses"] != uses) throw new PatchError($"import '{from}': {uses} uses ({where}), patch expects {(int)ed["uses"]}");
        a.AddNameReference(new FString(to));
        imp.ObjectName = new FName(a, to);
        int typed = 0;
        foreach (var other in a.Imports)
        {
            if (other.ClassName.ToString() == from) { other.ClassName = new FName(a, to); typed++; }
            if (other.ClassPackage.ToString() == from) { other.ClassPackage = new FName(a, to); typed++; }
        }
        return $"import {imp.ClassName} {from} -> {to} ({where}{(typed > 0 ? $"; class of {typed} imports updated" : "")})";
    }

    // Calls to Blueprint functions of other classes (e.g. BP_FL_MOBA_AbilitySystemFunctionLibrary_C.MakeRootEffectSpec)
    // are calls by name, resolved when they run: rename the calls. The new function must take the same arguments.
    static string RenameCall(UAsset a, JObject ed)
    {
        string from = Req(ed, "from"), to = Req(ed, "to");
        if (ed["count"] == null) throw new PatchError("rename-call needs \"count\"");
        var funcs = ed["function"] != null ? [Function(a, (string)ed["function"])]
            : a.Exports.OfType<FunctionExport>().Where(f => f.ScriptBytecode != null).ToList();
        var hits = funcs.SelectMany(f => All(a, f).OfType<EX_VirtualFunction>()
            .Where(e => e.VirtualFunctionName.ToString() == from).Select(e => (f, e))).ToList();
        if (hits.Count != (int)ed["count"])
            throw new PatchError($"{hits.Count} calls to {from}, patch expects {(int)ed["count"]}"
                                 + (a.Imports.Any(i => i.ObjectName.ToString() == from) ? " (it is also an import: see rename-import)" : ""));
        var sizes = funcs.ToDictionary(f => f, f => Size(a, f));
        a.AddNameReference(new FString(to));
        foreach (var (_, e) in hits) e.VirtualFunctionName = new FName(a, to);
        if (funcs.Any(f => Size(a, f) != sizes[f])) throw new PatchError("renaming the call changed a function's size");
        return $"{hits.Count}x call {from} -> {to} (in {string.Join(", ", hits.Select(h => h.f.ObjectName.ToString()).Distinct())})";
    }

    // Change a value in the class defaults (Default__<Class>_C).
    static string SetDefault(UAsset a, JObject ed)
    {
        string prop = Req(ed, "property");
        var cdo = ClassDefaults(a);
        var p = cdo.Data.Where(d => d.Name.ToString() == prop).ToList();
        if (p.Count != 1) throw new PatchError($"default '{prop}': found {p.Count} (only values stored in this class's defaults can be changed)");
        string before;
        switch (p[0])
        {
            case FloatPropertyData f:
                before = Num(f.Value);
                if (Math.Abs(f.Value - (float)ed["from"]) > 1e-4) throw new PatchError($"default '{prop}' is {before}, patch expects {ed["from"]}");
                f.Value = (float)ed["to"];
                break;
            case IntPropertyData i:
                before = i.Value.ToString(Inv);
                if (i.Value != (int)ed["from"]) throw new PatchError($"default '{prop}' is {before}, patch expects {ed["from"]}");
                i.Value = (int)ed["to"];
                break;
            case BoolPropertyData b:
                before = b.Value ? "true" : "false";
                if (b.Value != (bool)ed["from"]) throw new PatchError($"default '{prop}' is {before}, patch expects {ed["from"]}");
                b.Value = (bool)ed["to"];
                break;
            default:
                throw new PatchError($"default '{prop}': type {p[0].PropertyType} not supported");
        }
        return $"{cdo.ObjectName}.{prop}: {before} -> {ed["to"]}";
    }

    // The new argument: a number, true/false, or a variable that the same function already uses.
    static KismetExpression MakeArg(UAsset a, FunctionExport f, string text)
    {
        if (text == "true") return new EX_True();
        if (text == "false") return new EX_False();
        if (float.TryParse(text, NumberStyles.Float, Inv, out var v)) return new EX_FloatConst { Value = v };
        var seen = All(a, f).OfType<EX_VariableBase>().FirstOrDefault(e => Render(a, e) == text)
            ?? throw new PatchError($"'{text}' is not a number, and {f.ObjectName} uses no variable of that name");
        var copy = (EX_VariableBase)Activator.CreateInstance(seen.GetType());
        copy.Variable = seen.Variable;
        return copy;
    }

    // Change one argument of matching calls inside one function.
    static string SetCallArg(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string call = Req(ed, "call"), from = Req(ed, "from"), to = Req(ed, "to");
        if (ed["arg"] == null || ed["count"] == null) throw new PatchError("set-call-arg needs \"arg\" and \"count\"");
        int arg = (int)ed["arg"], count = (int)ed["count"];
        var match = ((JObject)ed["match"])?.Properties().ToDictionary(p => int.Parse(p.Name), p => (string)p.Value) ?? [];
        match[arg] = from;
        uint size = Size(a, f);
        var calls = All(a, f).Where(e => CallName(a, e) == call).ToList();
        var hits = calls.Where(e => match.All(m => m.Key < Args(e).Length && Render(a, Args(e)[m.Key]) == m.Value)).ToList();
        if (hits.Count != count)
        {
            var seen = string.Join("; ", calls.Select(e => $"{call}({string.Join(", ", Args(e).Select(x => Render(a, x)))})"));
            throw new PatchError($"{f.ObjectName}: {hits.Count} matching calls, patch expects {count}. Calls: {seen}");
        }
        foreach (var e in hits) Args(e)[arg] = MakeArg(a, f, to);
        if (Size(a, f) != size)
            throw new PatchError($"{f.ObjectName}: the edit changes the function's size ({size} -> {Size(a, f)}), which would break its jumps");
        return $"{f.ObjectName}: {hits.Count}x {call} argument {arg}: {from} -> {to}";
    }

    static string Apply(UAsset a, JObject ed) => (string)ed["op"] switch
    {
        "rename-import" => RenameImport(a, ed),
        "rename-call" => RenameCall(a, ed),
        "set-default" => SetDefault(a, ed),
        "set-call-arg" => SetCallArg(a, ed),
        var op => throw new PatchError($"unknown op '{op}'"),
    };

    // --- commands -----------------------------------------------------------------------------------------------

    static int CmdApply(string patchFile, string inRoot, string outRoot)
    {
        var patch = JObject.Parse(File.ReadAllText(patchFile));
        int failed = 0;
        foreach (JObject asset in (JArray)patch["assets"])
        {
            string rel = Req(asset, "path");
            Console.WriteLine(rel);
            try
            {
                var a = Load(Path.Combine(inRoot, rel + ".uasset"));
                foreach (JObject ed in (JArray)asset["edits"])
                    Console.WriteLine("  " + Apply(a, ed));
                string dst = Path.Combine(outRoot, rel + ".uasset");
                Directory.CreateDirectory(Path.GetDirectoryName(dst));
                a.Write(dst);
                // the written asset must load again with every function's bytecode parsed
                var bad = Load(dst).Exports.OfType<FunctionExport>().Where(x => x.ScriptBytecode == null).Select(x => x.ObjectName.ToString()).ToList();
                if (bad.Count > 0) throw new PatchError($"written asset: bytecode of {string.Join(", ", bad)} doesn't parse");
            }
            catch (PatchError ex) { Console.Error.WriteLine($"  FAILED: {ex.Message}"); failed++; }
        }
        Console.WriteLine(failed == 0 ? "all edits applied" : $"{failed} asset(s) failed");
        return failed == 0 ? 0 : 1;
    }

    static int CmdInfo(string path)
    {
        var a = Load(path);
        Console.WriteLine("imports (index: class name <- outer: uses in code / in values / as outer):");
        for (int i = 0; i < a.Imports.Count; i++)
        {
            var imp = a.Imports[i];
            var (code, props, outer) = Uses(a, i);
            Console.WriteLine($"  {-(i + 1),4}: {imp.ClassName} {imp.ObjectName} <- {Name(a, imp.OuterIndex)}: {code} / {props} / {outer}");
        }
        Console.WriteLine("class defaults:");
        foreach (var p in ClassDefaults(a).Data)
        {
            string v = p switch
            {
                FloatPropertyData f => Num(f.Value),
                IntPropertyData n => n.Value.ToString(Inv),
                BoolPropertyData b => b.Value ? "true" : "false",
                ObjectPropertyData o => Name(a, o.Value),
                _ => p.PropertyType.ToString(),
            };
            Console.WriteLine($"  {p.Name} = {v}");
        }
        Console.WriteLine("functions:");
        foreach (var f in a.Exports.OfType<FunctionExport>())
            Console.WriteLine($"  {f.ObjectName}{(f.ScriptBytecode == null ? "  (bytecode not parsed)" : "")}");
        return 0;
    }

    // function "*": every function, each line prefixed with the function's name
    static int CmdCalls(string path, string function, string call)
    {
        var a = Load(path);
        var funcs = function == "*" ? a.Exports.OfType<FunctionExport>().Where(f => f.ScriptBytecode != null).ToList() : [Function(a, function)];
        foreach (var f in funcs)
            foreach (var e in All(a, f))
            {
                var name = CallName(a, e);
                if (name != null && (call == null || name == call))
                    Console.WriteLine($"{(function == "*" ? f.ObjectName + ": " : "")}{name}({string.Join(", ", Args(e).Select(x => Render(a, x)))})");
            }
        return 0;
    }

    static int CmdRoundtrip(string path, string outDir)
    {
        Directory.CreateDirectory(outDir);
        string dst = Path.Combine(outDir, Path.GetFileName(path));
        Load(path).Write(dst);
        int diff = 0;
        foreach (var ext in new[] { ".uasset", ".uexp" })
        {
            string src = Path.ChangeExtension(path, ext), cpy = Path.ChangeExtension(dst, ext);
            if (!File.Exists(src)) continue;
            bool same = File.ReadAllBytes(src).AsSpan().SequenceEqual(File.ReadAllBytes(cpy));
            Console.WriteLine($"{Path.GetFileName(src)}: {(same ? "identical" : "DIFFERENT")}");
            if (!same) diff++;
        }
        return diff == 0 ? 0 : 1;
    }

    static int Main(string[] args)
    {
        try
        {
            return args switch
            {
                ["info", var p] => CmdInfo(p),
                ["calls", var p, var fn] => CmdCalls(p, fn, null),
                ["calls", var p, var fn, var c] => CmdCalls(p, fn, c),
                ["roundtrip", var p, var o] => CmdRoundtrip(p, o),
                ["apply", var patch, var i, var o] => CmdApply(patch, i, o),
                _ => Usage(),
            };
        }
        catch (PatchError ex) { Console.Error.WriteLine("error: " + ex.Message); return 1; }
    }

    static int Usage()
    {
        Console.Error.WriteLine("usage: assetpatch info <asset> | calls <asset> <function> [call] | roundtrip <asset> <out-dir>"
                                + " | apply <patch.json> <in-root> <out-root>");
        return 2;
    }
}
