// assetpatch: small, checked edits to cooked UE 4.26 Blueprint assets, for our patch pak (docs/PATCHING.md).
//
//   assetpatch info <asset.uasset>                       imports with their uses, class defaults, functions
//   assetpatch calls <asset.uasset> <function> [call]    calls in one function, with their arguments
//   assetpatch props <asset.uasset> [export]             exports; or every value stored in one, by path
//   assetpatch roundtrip <asset.uasset> <out-dir>         read and write back unchanged; fails if a byte differs
//   assetpatch apply <patch.json> <in-root> <out-root>    apply a patch; writes the edited assets under out-root
//   assetpatch rewrite-check <dir>                       insert + remove a statement in every function; must write back identical
//
// Edits ("op"): set-default, rename-call, rename-import, set-call-arg, replace-text, copy-default, set-export-prop,
// insert-call, remove-call, soundwave-audio, insert-play-sound (Sound.cs; a patch asset with "template" is a new asset)
// (docs/PATCHING.md has the fields).
// Every edit states what it expects to find ("from", "uses", "count") and fails if the asset differs, so a patch
// can't silently apply to another build. Edits inside a statement must keep the function's in-memory size; edits
// that add or remove whole statements go through Splice (Rewrite.cs), which moves every code offset along.
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

static partial class Program
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

    // The new argument as the same kind of literal as the one it replaces (a byte stays a byte, an int an int, so the
    // function keeps its size), or else as MakeArg makes it.
    static KismetExpression MakeArgLike(UAsset a, FunctionExport f, string text, KismetExpression old) => old switch
    {
        EX_ByteConst when byte.TryParse(text, NumberStyles.Integer, Inv, out var b) => new EX_ByteConst { Value = b },
        EX_IntConstByte when byte.TryParse(text, NumberStyles.Integer, Inv, out var b) => new EX_IntConstByte { Value = b },
        EX_IntConst when int.TryParse(text, NumberStyles.Integer, Inv, out var i) => new EX_IntConst { Value = i },
        _ => MakeArg(a, f, text),
    };

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
        foreach (var e in hits) Args(e)[arg] = MakeArgLike(a, f, to, Args(e)[arg]);
        if (Size(a, f) != size)
            throw new PatchError($"{f.ObjectName}: the edit changes the function's size ({size} -> {Size(a, f)}), which would break its jumps");
        return $"{f.ObjectName}: {hits.Count}x {call} argument {arg}: {from} -> {to}";
    }

    // Change text in a string table entry (tooltips): "from" must occur "count" times (default 1).
    static string ReplaceText(UAsset a, JObject ed)
    {
        string key = Req(ed, "key"), from = Req(ed, "from"), to = Req(ed, "to");
        int count = (int?)ed["count"] ?? 1;
        var st = a.Exports.OfType<StringTableExport>().SingleOrDefault() ?? throw new PatchError("not a string table");
        var k = st.Table.Keys.FirstOrDefault(x => x.Value == key) ?? throw new PatchError($"string table: no key '{key}'");
        string text = st.Table[k].Value;
        int n = (text.Length - text.Replace(from, "").Length) / from.Length;
        if (n != count) throw new PatchError($"{key}: \"{from}\" occurs {n} times, patch expects {count}");
        st.Table[k] = new FString(text.Replace(from, to), st.Table[k].Encoding);
        return $"{key}: \"{from}\" -> \"{to}\"";
    }

    // Move a value read from another asset into this one: every name goes into this asset's name map (renamed as
    // asked). References to other objects can't be moved this way.
    static void Adopt(UAsset a, object o, Dictionary<string, string> rename, HashSet<string> used, HashSet<object> seen)
    {
        if (o == null || o is string || o is FString || o is INameMap || o is Type || o.GetType().IsPrimitive || o is Enum) return;
        if (!o.GetType().IsValueType && !seen.Add(o)) return;
        if (o is FPackageIndex pi)
        {
            if (pi.Index != 0) throw new PatchError("the copied value references another object; not supported");
            return;
        }
        if (o is PropertyData pd) a.AddNameReference(pd.PropertyType);
        if (o is FName[] arr) { for (int i = 0; i < arr.Length; i++) arr[i] = Moved(a, arr[i], rename, used); return; }
        if (o is List<FName> list) { for (int i = 0; i < list.Count; i++) list[i] = Moved(a, list[i], rename, used); return; }
        if (o is System.Collections.IEnumerable en && o is not FName) foreach (var x in en) Adopt(a, x, rename, used, seen);
        for (var t = o.GetType(); t != null && t != typeof(object); t = t.BaseType)
            foreach (var f in t.GetFields(BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Instance | BindingFlags.DeclaredOnly))
            {
                if (f.FieldType == typeof(FName)) { if (f.GetValue(o) is FName n) f.SetValue(o, Moved(a, n, rename, used)); }
                else if (!f.FieldType.IsPrimitive && f.FieldType != typeof(string)) Adopt(a, f.GetValue(o), rename, used, seen);
            }
    }

    static FName Moved(UAsset a, FName n, Dictionary<string, string> rename, HashSet<string> used)
    {
        if (n == null) return null;
        string v = n.Value?.Value;
        if (v != null && rename.TryGetValue(v, out var nv)) { used.Add(v); v = nv; }
        return v == null ? n : new FName(a, v, n.Number);
    }

    // Add a class default copied from the same property of another asset's class defaults (e.g. the gameplay cues of
    // one effect onto another), with names in it renamed. The property must not be set in this class yet.
    static string CopyDefault(UAsset a, JObject ed, string inRoot)
    {
        string from = Req(ed, "from"), prop = Req(ed, "property");
        var src = Load(Path.Combine(inRoot, from + ".uasset"));
        var p = ClassDefaults(src).Data.SingleOrDefault(d => d.Name.ToString() == prop)
            ?? throw new PatchError($"copy-default: '{prop}' is not set in {from}");
        var cdo = ClassDefaults(a);
        if (cdo.Data.Any(d => d.Name.ToString() == prop)) throw new PatchError($"copy-default: '{prop}' is already set here");
        var rename = ((JObject)ed["rename"])?.Properties().ToDictionary(x => x.Name, x => (string)x.Value) ?? [];
        var used = new HashSet<string>();
        Adopt(a, p, rename, used, new HashSet<object>(ReferenceEqualityComparer.Instance));
        var unused = rename.Keys.Where(k => !used.Contains(k)).ToList();
        if (unused.Count > 0) throw new PatchError($"copy-default: no name {string.Join(", ", unused)} in the copied value");
        cdo.Data.Add(p);
        return $"{cdo.ObjectName}.{prop} copied from {Path.GetFileName(from)}" + string.Concat(rename.Select(r => $"; {r.Key} -> {r.Value}"));
    }

    // --- values anywhere in an asset (set-export-prop, props) ------------------------------------------------------
    // An export is named by its ObjectName, or "<outer>.<name>" when several exports share the name. A path is
    // property names joined by dots; "[i]" picks an element of an array (or of a fixed-size array). Vector, Rotator,
    // Vector2D and LinearColor values end in a component: BoxExtent.Y, ColorOptions.Color.R.

    static string ExportName(UAsset a, Export e) =>
        (e.OuterIndex == null || e.OuterIndex.IsNull() ? "" : Name(a, e.OuterIndex) + ".") + e.ObjectName;

    static NormalExport FindExport(UAsset a, string name)
    {
        var hits = a.Exports.Where(e => e.ObjectName.ToString() == name || ExportName(a, e) == name).ToList();
        if (hits.Count != 1)
            throw new PatchError($"export '{name}': found {hits.Count}" + (hits.Count > 1
                ? $" ({string.Join(", ", hits.Select(e => ExportName(a, e)))}; name one as <outer>.<name>)" : ""));
        return hits[0] as NormalExport ?? throw new PatchError($"export '{name}' holds no property values");
    }

    static readonly Dictionary<Type, string[]> Components = new()
    {
        [typeof(VectorPropertyData)] = ["X", "Y", "Z"],
        [typeof(Vector2DPropertyData)] = ["X", "Y"],
        [typeof(RotatorPropertyData)] = ["Pitch", "Yaw", "Roll"],
        [typeof(LinearColorPropertyData)] = ["R", "G", "B", "A"],
    };

    // UAssetAPI reads a Vector/LinearColor/... struct as a struct holding one value of the same name: look through it.
    static PropertyData Unwrap(PropertyData p) =>
        p is StructPropertyData { Value.Count: 1 } s && Components.ContainsKey(s.Value[0].GetType())
            && s.Value[0].Name.ToString() == s.Name.ToString() ? s.Value[0] : p;

    // The value a path points at: a property, and the component when the property is a vector, rotator or colour.
    static (PropertyData prop, string comp) Resolve(NormalExport ex, string path)
    {
        var props = ex.Data;
        PropertyData cur = null;
        string done = "";
        var parts = path.Split('.');
        for (int i = 0; i < parts.Length; i++)
        {
            var m = System.Text.RegularExpressions.Regex.Match(parts[i], @"^(.+?)(?:\[(\d+)\])?$");
            string name = m.Groups[1].Value;
            int? index = m.Groups[2].Success ? int.Parse(m.Groups[2].Value, Inv) : null;
            if (cur != null)
            {
                cur = Unwrap(cur);
                if (Components.TryGetValue(cur.GetType(), out var comps))
                {
                    if (!comps.Contains(name) || index != null || i != parts.Length - 1)
                        throw new PatchError($"'{done}' is a {cur.PropertyType}: the path must end in one of {string.Join(", ", comps)}");
                    return (cur, name);
                }
                props = cur is StructPropertyData s ? s.Value
                    : throw new PatchError($"'{done}' is a {cur.PropertyType}, not a struct");
            }
            var found = props.Where(p => p.Name.ToString() == name).ToList();
            if (found.Count == 0)
                throw new PatchError($"'{done}{(done == "" ? "" : ".")}{name}' is not stored in {ex.ObjectName} (a value equal to its default isn't saved; see 'props')");
            if (index is int n)
            {
                if (found.Count == 1 && found[0] is ArrayPropertyData arr)
                    cur = n < arr.Value.Length ? arr.Value[n] : throw new PatchError($"'{done}{name}' has {arr.Value.Length} elements, no [{n}]");
                else
                    cur = found.SingleOrDefault(p => p.ArrayIndex == n) ?? throw new PatchError($"'{done}{name}' has no element [{n}]");
            }
            else if (found.Count > 1) throw new PatchError($"'{done}{name}' is a fixed-size array: say which element, [i]");
            else cur = found[0];
            done += (done == "" ? "" : ".") + parts[i];
        }
        cur = Unwrap(cur);
        if (Components.ContainsKey(cur.GetType()))
            throw new PatchError($"'{path}' is a {cur.PropertyType}: name a component ({string.Join(", ", Components[cur.GetType()])})");
        return (cur, null);
    }

    // The value as a number (double), a bool or a name (string); null if the type can't be read or set.
    static object GetValue(PropertyData p, string comp) => (p, comp) switch
    {
        (FloatPropertyData f, null) => (double)f.Value,
        (DoublePropertyData d, null) => d.Value,
        (IntPropertyData n, null) => (double)n.Value,
        (Int8PropertyData n, null) => (double)n.Value,
        (Int16PropertyData n, null) => (double)n.Value,
        (Int64PropertyData n, null) => (double)n.Value,
        (UInt16PropertyData n, null) => (double)n.Value,
        (UInt32PropertyData n, null) => (double)n.Value,
        (BoolPropertyData b, null) => b.Value,
        (BytePropertyData b, null) => b.ByteType == BytePropertyType.Byte ? (double)b.Value : b.EnumValue?.ToString(),
        (EnumPropertyData e, null) => e.Value?.ToString(),
        (VectorPropertyData v, _) => comp switch { "X" => v.Value.X, "Y" => v.Value.Y, _ => v.Value.Z },
        (Vector2DPropertyData v, _) => comp == "X" ? v.Value.X : v.Value.Y,
        (RotatorPropertyData r, _) => comp switch { "Pitch" => r.Value.Pitch, "Yaw" => r.Value.Yaw, _ => r.Value.Roll },
        (LinearColorPropertyData c, _) => (double)(comp switch { "R" => c.Value.R, "G" => c.Value.G, "B" => c.Value.B, _ => c.Value.A }),
        _ => null,
    };

    static string Show(object v) => v switch
    {
        double d => Num((float)d),
        bool b => b ? "true" : "false",
        null => "?",
        _ => v.ToString(),
    };

    static void SetValue(UAsset a, PropertyData p, string comp, JToken to)
    {
        double Number() => to.Type is JTokenType.Float or JTokenType.Integer ? (double)to
            : throw new PatchError($"'to' must be a number, not {to}");
        long Whole() => to.Type == JTokenType.Integer ? (long)to : throw new PatchError($"'to' must be a whole number, not {to}");
        FName Named()
        {
            if (to.Type != JTokenType.String) throw new PatchError($"'to' must be a name, not {to}");
            a.AddNameReference(new FString((string)to));
            return new FName(a, (string)to);
        }
        checked
        {
            switch (p)
            {
                case FloatPropertyData f: f.Value = (float)Number(); break;
                case DoublePropertyData d: d.Value = Number(); break;
                case IntPropertyData n: n.Value = (int)Whole(); break;
                case Int8PropertyData n: n.Value = (sbyte)Whole(); break;
                case Int16PropertyData n: n.Value = (short)Whole(); break;
                case Int64PropertyData n: n.Value = Whole(); break;
                case UInt16PropertyData n: n.Value = (ushort)Whole(); break;
                case UInt32PropertyData n: n.Value = (uint)Whole(); break;
                case BoolPropertyData b:
                    b.Value = to.Type == JTokenType.Boolean ? (bool)to : throw new PatchError($"'to' must be true or false, not {to}");
                    break;
                case BytePropertyData { ByteType: BytePropertyType.Byte } b: b.Value = (byte)Whole(); break;
                case BytePropertyData b: b.EnumValue = Named(); break;
                case EnumPropertyData e: e.Value = Named(); break;
                case VectorPropertyData v:   // FVector & co. are structs: change a copy, put it back
                    var vec = v.Value;
                    if (comp == "X") vec.X = Number(); else if (comp == "Y") vec.Y = Number(); else vec.Z = Number();
                    v.Value = vec;
                    break;
                case Vector2DPropertyData v:
                    var v2 = v.Value;
                    if (comp == "X") v2.X = Number(); else v2.Y = Number();
                    v.Value = v2;
                    break;
                case RotatorPropertyData r:
                    var rot = r.Value;
                    if (comp == "Pitch") rot.Pitch = Number(); else if (comp == "Yaw") rot.Yaw = Number(); else rot.Roll = Number();
                    r.Value = rot;
                    break;
                case LinearColorPropertyData c:
                    var col = c.Value;
                    float x = (float)Number();
                    if (comp == "R") col.R = x; else if (comp == "G") col.G = x; else if (comp == "B") col.B = x; else col.A = x;
                    c.Value = col;
                    break;
                default: throw new PatchError($"type {p.PropertyType} not supported");
            }
        }
    }

    static bool Same(object have, JToken want) => (have, want.Type) switch
    {
        (double d, JTokenType.Float or JTokenType.Integer) => Math.Abs(d - (double)want) <= 1e-4 * Math.Max(1, Math.Abs(d)),
        (bool b, JTokenType.Boolean) => b == (bool)want,
        (string s, JTokenType.String) => s == (string)want,
        _ => false,
    };

    // Change one value anywhere in the asset: a component template (wer_GEN_VARIABLE), a value nested in the class
    // defaults (a gameplay effect's modifiers), a data asset's field. Only values stored in the asset can be changed.
    static string SetExportProp(UAsset a, JObject ed)
    {
        string exName = Req(ed, "export"), path = Req(ed, "path");
        var from = ed["from"] ?? throw new PatchError("edit is missing 'from'");
        var to = ed["to"] ?? throw new PatchError("edit is missing 'to'");
        var (p, comp) = Resolve(FindExport(a, exName), path);
        var have = GetValue(p, comp) ?? throw new PatchError($"{exName}.{path}: type {p.PropertyType} not supported");
        if (!Same(have, from)) throw new PatchError($"{exName}.{path} is {Show(have)}, patch expects {from}");
        try { SetValue(a, p, comp, to); }
        catch (OverflowException) { throw new PatchError($"{exName}.{path}: {to} doesn't fit a {p.PropertyType}"); }
        return $"{exName}.{path}: {Show(have)} -> {Show(GetValue(p, comp))}";
    }

    static string Apply(UAsset a, JObject ed, string inRoot) => (string)ed["op"] switch
    {
        "rename-import" => RenameImport(a, ed),
        "rename-call" => RenameCall(a, ed),
        "set-default" => SetDefault(a, ed),
        "set-call-arg" => SetCallArg(a, ed),
        "replace-text" => ReplaceText(a, ed),
        "copy-default" => CopyDefault(a, ed, inRoot),
        "set-export-prop" => SetExportProp(a, ed),
        "insert-call" => InsertCall(a, ed),
        "remove-call" => RemoveCall(a, ed),
        "soundwave-audio" => SoundWaveAudio(a, ed),
        "insert-play-sound" => InsertPlaySound(a, ed),
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
                var a = LoadForPatch(asset, inRoot, rel);
                foreach (JObject ed in (JArray)asset["edits"])
                    Console.WriteLine("  " + Apply(a, ed, inRoot));
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

    // No export: every export (name, class, number of stored values). An export: every value stored in it, by the
    // path set-export-prop takes.
    static int CmdProps(string path, string export)
    {
        var a = Load(path);
        if (export == null)
        {
            foreach (var e in a.Exports)
                Console.WriteLine($"  {ExportName(a, e)}  ({Name(a, e.ClassIndex)}{(e is NormalExport n ? $", {n.Data.Count} values" : "")})");
            return 0;
        }
        foreach (var line in Flatten(a, FindExport(a, export).Data, "")) Console.WriteLine("  " + line);
        return 0;
    }

    static IEnumerable<string> Flatten(UAsset a, List<PropertyData> props, string prefix)
    {
        foreach (var p in props)
        {
            string name = p.Name.ToString();
            if (p.ArrayIndex > 0 || props.Count(q => q.Name.ToString() == name) > 1) name += $"[{p.ArrayIndex}]";
            foreach (var line in Leaf(a, p, prefix + name)) yield return line;
        }
    }

    static IEnumerable<string> Leaf(UAsset a, PropertyData p, string path)
    {
        p = Unwrap(p);
        if (Components.TryGetValue(p.GetType(), out var comps))
            foreach (var c in comps) yield return $"{path}.{c} = {Show(GetValue(p, c))}";
        else if (p is StructPropertyData s)
            foreach (var line in Flatten(a, s.Value, path + ".")) yield return line;
        else if (p is ArrayPropertyData arr)
        {
            if (arr.Value.Length == 0) yield return $"{path} = []";
            for (int i = 0; i < arr.Value.Length; i++)
                foreach (var line in Leaf(a, arr.Value[i], $"{path}[{i}]")) yield return line;
        }
        else
        {
            var v = GetValue(p, null);
            yield return $"{path} = " + (v != null ? Show(v) : p switch   // names, strings and objects: shown, not settable
            {
                ObjectPropertyData o => Name(a, o.Value),
                NamePropertyData n => $"'{n.Value}'",
                StrPropertyData str => $"\"{str.Value}\"",
                _ => $"<{p.PropertyType}>",
            });
        }
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
                ["props", var p] => CmdProps(p, null),
                ["props", var p, var e] => CmdProps(p, e),
                ["roundtrip", var p, var o] => CmdRoundtrip(p, o),
                ["apply", var patch, var i, var o] => CmdApply(patch, i, o),
                ["rewrite-check", var d] => CmdRewriteCheck(d),
                ["nop", var p, var fn, var at, var o] => CmdNop(p, fn, int.Parse(at), o),
                _ => Usage(),
            };
        }
        catch (PatchError ex) { Console.Error.WriteLine("error: " + ex.Message); return 1; }
    }

    static int Usage()
    {
        Console.Error.WriteLine("usage: assetpatch info <asset> | calls <asset> <function> [call] | props <asset> [export]"
                                + " | roundtrip <asset> <out-dir>"
                                + " | apply <patch.json> <in-root> <out-root> | rewrite-check <dir>");
        return 2;
    }
}
