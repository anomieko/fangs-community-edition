// insert-code: new statements built from a small JSON form, put into a function through Splice (every code offset
// moves along). Engine functions it calls are added as imports when the asset lacks them (/Script only: script
// packages are always loaded, so no load-order dependency is needed). Variables are copied from existing uses.
//
//   expr: {"local": name} | {"self": name}              a variable the function (or class) already uses
//         {"str": s} | {"bool": b} | {"float": f} | {"int": n} | {"vec": [x, y, z]}
//         {"null": true} | {"this": true}                    no object (nullptr), the Blueprint object itself (self)
//         {"cast": className, "of": expr}                    Cast<className>(expr), a class the asset already imports
//         {"math": "/Script/<Module>.<Class>:<Function>", "args": [expr...]}   static pure call (EX_CallMath)
//         {"on": expr, "call": "/Script/<Module>.<Class>:<Function>", "args": [...]}   member call on an object
//         {"anchor-arg": i}                                  a copy of argument i of the anchor call (before/after)
//   stmt: {"do": expr} | {"let-obj": localName, "value": expr} | {"let-self-obj": variableName, "value": expr}
//         {"set-bool": {"on": expr, "prop": name}, "value": bool}   a bool property of that object
//         {"if": expr, "then": [stmt...]}                            skips "then" unless expr is true
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.UnrealTypes;

static partial class Program
{
    // A deep copy of an expression of this asset (written and read back).
    static KismetExpression Clone(UAsset a, KismetExpression e)
    {
        using var ms = new MemoryStream();
        using (var w = new AssetBinaryWriter(ms, System.Text.Encoding.UTF8, true, a)) ExpressionSerializer.WriteExpression(e, w);
        ms.Position = 0;
        using var r = new AssetBinaryReader(ms, a);
        return ExpressionSerializer.ReadExpression(r);
    }

    static FPackageIndex FindOrAddImport(UAsset a, string classPackage, string className, FPackageIndex outer, string name)
    {
        for (int i = 0; i < a.Imports.Count; i++)
        {
            var im = a.Imports[i];
            if (im.ObjectName.ToString() == name && im.ClassName.ToString() == className && im.OuterIndex.Index == outer.Index)
                return FPackageIndex.FromImport(i);
        }
        foreach (var s in new[] { classPackage, className, name }) a.AddNameReference(new FString(s));
        return a.AddImport(new Import(classPackage, className, outer, name, false, a));
    }

    // "/Script/Engine.KismetStringLibrary:Contains" -> the function's import (package, class and function as needed)
    static FPackageIndex ScriptFunction(UAsset a, string path)
    {
        var m = System.Text.RegularExpressions.Regex.Match(path, @"^(/Script/[A-Za-z0-9_]+)\.([A-Za-z0-9_]+):([A-Za-z0-9_]+)$");
        if (!m.Success) throw new PatchError($"insert-code: '{path}' is not /Script/<Module>.<Class>:<Function>");
        var pkg = FindOrAddImport(a, "/Script/CoreUObject", "Package", FPackageIndex.FromRawIndex(0), m.Groups[1].Value);
        var cls = FindOrAddImport(a, "/Script/CoreUObject", "Class", pkg, m.Groups[2].Value);
        return FindOrAddImport(a, "/Script/CoreUObject", "Function", cls, m.Groups[3].Value);
    }

    // a copy of the first variable expression of this kind and name in the asset
    static EX_VariableBase CopyVariable<T>(UAsset a, FunctionExport f, string name) where T : EX_VariableBase
    {
        var funcs = new[] { f }.Concat(a.Exports.OfType<FunctionExport>().Where(x => x != f && x.ScriptBytecode != null));
        var seen = funcs.SelectMany(x => All(a, x)).OfType<T>().FirstOrDefault(e => e.GetType() == typeof(T) && VarName(a, e.Variable) == name)
            ?? throw new PatchError($"insert-code: no {typeof(T).Name} '{name}' in {f.ObjectName}");
        return (EX_VariableBase)Clone(a, seen);
    }

    static KismetPropertyPointer PropertyPointer(UAsset a, string name)
    {
        var seen = a.Exports.OfType<FunctionExport>().Where(x => x.ScriptBytecode != null).SelectMany(x => All(a, x))
            .OfType<EX_InstanceVariable>().FirstOrDefault(e => VarName(a, e.Variable) == name)
            ?? throw new PatchError($"insert-code: the asset never uses a property '{name}'; can't point at it");
        return ((EX_InstanceVariable)Clone(a, seen)).Variable;
    }

    static KismetExpression Expr(UAsset a, FunctionExport f, JToken j)
    {
        var o = j as JObject ?? throw new PatchError($"insert-code: expression expected, got {j}");
        if (o["local"] != null) return CopyVariable<EX_LocalVariable>(a, f, (string)o["local"]);
        if (o["self"] != null) return CopyVariable<EX_InstanceVariable>(a, f, (string)o["self"]);
        if (o["str"] != null) return new EX_StringConst { Value = (string)o["str"] };
        if (o["bool"] != null) return (bool)o["bool"] ? new EX_True() : new EX_False();
        if (o["float"] != null) return new EX_FloatConst { Value = (float)o["float"] };
        if (o["int"] != null) return new EX_IntConst { Value = (int)o["int"] };
        if (o["vec"] is JArray v) return new EX_VectorConst { Value = new FVector((float)v[0], (float)v[1], (float)v[2]) };
        if (o["null"] != null) return new EX_NoObject();
        if (o["this"] != null) return new EX_Self();
        if (o["cast"] != null)
        {
            string n = (string)o["cast"];
            var hits = Enumerable.Range(0, a.Imports.Count).Where(i => a.Imports[i].ObjectName.ToString() == n).ToList();
            if (hits.Count != 1) throw new PatchError($"insert-code: {hits.Count} imports named '{n}', need exactly 1 (no new references are added)");
            return new EX_DynamicCast { ClassPtr = FPackageIndex.FromImport(hits[0]), Target = Expr(a, f, o["of"]) };
        }
        if (o["anchor-arg"] != null)
        {
            int i = (int)o["anchor-arg"];
            if (anchorCall == null || i >= Args(anchorCall).Length) throw new PatchError($"insert-code: no anchor argument {i}");
            return Clone(a, Args(anchorCall)[i]);
        }
        var args = ((JArray)o["args"])?.Select(x => Expr(a, f, x)).ToArray() ?? [];
        if (o["math"] != null) return new EX_CallMath { StackNode = ScriptFunction(a, (string)o["math"]), Parameters = args };
        if (o["call"] != null)
        {
            var call = new EX_FinalFunction { StackNode = ScriptFunction(a, (string)o["call"]), Parameters = args };
            if (o["on"] == null) return call;
            return Context(a, Expr(a, f, o["on"]), call, new KismetPropertyPointer(new FFieldPath([], FPackageIndex.FromRawIndex(0))));
        }
        throw new PatchError($"insert-code: unknown expression {o}");
    }

    static EX_Context Context(UAsset a, KismetExpression on, KismetExpression inner, KismetPropertyPointer rvalue) =>
        new() { ObjectExpression = on, Offset = inner.GetSize(a), RValuePointer = rvalue, ContextExpression = inner };

    // statements; jump targets are relative to the first statement of the whole inserted block (`at` = where this
    // list starts within it), as Splice expects
    static List<KismetExpression> Stmts(UAsset a, FunctionExport f, JArray code, uint at)
    {
        var list = new List<KismetExpression>();
        uint here() => at + (uint)list.Sum(s => s.GetSize(a));
        foreach (JObject s in code)
        {
            if (s["do"] != null) list.Add(Expr(a, f, s["do"]));
            else if (s["let-obj"] != null)
                list.Add(new EX_LetObj { VariableExpression = CopyVariable<EX_LocalVariable>(a, f, (string)s["let-obj"]), AssignmentExpression = Expr(a, f, s["value"]) });
            else if (s["let-self-obj"] != null)
                list.Add(new EX_LetObj { VariableExpression = CopyVariable<EX_InstanceVariable>(a, f, (string)s["let-self-obj"]), AssignmentExpression = Expr(a, f, s["value"]) });
            else if (s["set-bool"] is JObject sb)
            {
                var ptr = PropertyPointer(a, (string)sb["prop"]);
                var target = Context(a, Expr(a, f, sb["on"]), new EX_InstanceVariable { Variable = ptr }, PropertyPointer(a, (string)sb["prop"]));
                list.Add(new EX_LetBool { VariableExpression = target, AssignmentExpression = (bool)s["value"] ? new EX_True() : new EX_False() });
            }
            else if (s["if"] != null)
            {
                var jump = new EX_JumpIfNot { BooleanExpression = Expr(a, f, s["if"]) };
                list.Add(jump);
                var then = Stmts(a, f, (JArray)s["then"], here());
                list.AddRange(then);
                jump.CodeOffset = here();
            }
            else throw new PatchError($"insert-code: unknown statement {s}");
        }
        return list;
    }

    static KismetExpression anchorCall;   // the call `before`/`after` names, for {"anchor-arg": i}

    // {"op": "insert-code", "function", "before"|"after": <call name, exactly one statement>, or "at": "start"|"end",
    //  optional "anchor-match": {"<arg index>": "<text>"} (the anchor call's arguments as AssetPatch calls prints them),
    //  "code": [...]}
    static string InsertCode(UAsset a, JObject ed)
    {
        anchorCall = null;
        var f = Function(a, Req(ed, "function"));
        int index;
        string where;
        if ((string)ed["at"] is string at)
        {
            index = at == "start" ? 0 : at == "end" && f.ScriptBytecode[^1] is EX_Return ? f.ScriptBytecode.Length - 1
                : throw new PatchError($"insert-code: \"at\" is start or end, not '{at}'");
            where = $"at the {at}";
        }
        else
        {
            bool before = ed["before"] != null;
            string anchor = (string)(ed["before"] ?? ed["after"]) ?? throw new PatchError("insert-code needs \"at\", \"before\" or \"after\"");
            var match = ((JObject)ed["anchor-match"])?.Properties().ToDictionary(x => int.Parse(x.Name), x => (string)x.Value) ?? [];
            bool Fits(KismetExpression e) => CallName(a, e) == anchor
                && match.All(m => m.Key < Args(e).Length && Render(a, Args(e)[m.Key]) == m.Value);
            var hits = Enumerable.Range(0, f.ScriptBytecode.Length).Where(i => Statement(a, f.ScriptBytecode[i]).Any(Fits)).ToList();
            if (hits.Count != 1) throw new PatchError($"insert-code: {hits.Count} statements of {f.ObjectName} call {anchor}"
                                                      + (match.Count > 0 ? " with those arguments" : "") + ", need exactly 1");
            anchorCall = Statement(a, f.ScriptBytecode[hits[0]]).First(Fits);
            index = before ? hits[0] : hits[0] + 1;
            where = $"{(before ? "before" : "after")} the call to {anchor}";
        }
        int imports = a.Imports.Count;
        var code = Stmts(a, f, (JArray)ed["code"], 0);
        Splice(a, f, index, 0, [.. code]);
        return $"{f.ObjectName}: {code.Count} statement(s) inserted {where} (statement {index})"
               + (a.Imports.Count > imports ? $", {a.Imports.Count - imports} import(s) added" : "");
    }
}
