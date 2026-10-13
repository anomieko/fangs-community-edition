// bpdump: dump Blueprint classes (variables, functions, Kismet bytecode) from cooked
// UE 4.26 assets to JSON, for tools/bpdump/bp2txt.py to render as pseudocode.
//
// Usage: bpdump <extract-root> <out-dir> <asset.uasset|dir>...
//   Paths in the output mirror paths relative to <extract-root>.
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.FieldTypes;
using UAssetAPI.Kismet;
using UAssetAPI.UnrealTypes;

static class Program
{
    static UAsset A;

    static string Ref(FPackageIndex i)
    {
        if (i == null || i.IsNull()) return null;
        if (i.IsImport()) return i.ToImport(A).ObjectName.ToString();
        return i.ToExport(A).ObjectName.ToString();
    }

    static string TypeOf(FProperty p) => p switch
    {
        FArrayProperty a => $"TArray<{TypeOf(a.Inner)}>",
        FSetProperty s => $"TSet<{TypeOf(s.ElementProp)}>",
        FMapProperty m => $"TMap<{TypeOf(m.KeyProp)}, {TypeOf(m.ValueProp)}>",
        FStructProperty s => $"F{Ref(s.Struct)}",
        FClassProperty c => $"TSubclassOf<{Ref(c.MetaClass)}>",
        FSoftClassProperty c => $"TSoftClassPtr<{Ref(c.MetaClass)}>",
        FSoftObjectProperty o => $"TSoftObjectPtr<{Ref(o.PropertyClass)}>",
        FWeakObjectProperty o => $"TWeakObjectPtr<{Ref(o.PropertyClass)}>",
        FObjectProperty o => $"{Ref(o.PropertyClass)}*",
        FInterfaceProperty i => $"TScriptInterface<{Ref(i.InterfaceClass)}>",
        FEnumProperty e => $"{Ref(e.Enum)}",
        FByteProperty b when b.Enum != null && !b.Enum.IsNull() => $"{Ref(b.Enum)}",
        FMulticastDelegateProperty d => $"MulticastDelegate<{Ref(d.SignatureFunction)}>",
        FDelegateProperty d => $"Delegate<{Ref(d.SignatureFunction)}>",
        _ => p.SerializedType.ToString().Replace("Property", ""),
    };

    static JArray Props(FProperty[] props)
    {
        var arr = new JArray();
        foreach (var p in props ?? Array.Empty<FProperty>())
        {
            var o = new JObject
            {
                ["name"] = p.Name.ToString(),
                ["type"] = TypeOf(p),
                ["flags"] = p.PropertyFlags.ToString(),
            };
            if (p.RepNotifyFunc != null && p.RepNotifyFunc.ToString() != "None")
                o["repnotify"] = p.RepNotifyFunc.ToString();
            arr.Add(o);
        }
        return arr;
    }

    static JObject Dump(string path)
    {
        A = new UAsset(path, EngineVersion.VER_UE4_26);
        KismetSerializer.asset = A;
        var root = new JObject { ["imports_count"] = A.Imports.Count };
        var funcs = new JArray();
        var classes = new JArray();
        foreach (var e in A.Exports)
        {
            switch (e)
            {
                case FunctionExport f:
                    var fo = new JObject
                    {
                        ["name"] = f.ObjectName.ToString(),
                        ["outer"] = Ref(f.OuterIndex),
                        ["flags"] = f.FunctionFlags.ToString(),
                        ["super"] = Ref(f.SuperStruct),
                        ["props"] = Props(f.LoadedProperties),
                    };
                    try { fo["script"] = KismetSerializer.SerializeScript(f.ScriptBytecode ?? Array.Empty<UAssetAPI.Kismet.Bytecode.KismetExpression>()); }
                    catch (Exception ex) { fo["script_error"] = ex.Message; }
                    funcs.Add(fo);
                    break;
                case ClassExport c:
                    classes.Add(new JObject
                    {
                        ["name"] = c.ObjectName.ToString(),
                        ["super"] = Ref(c.SuperStruct),
                        ["flags"] = c.ClassFlags.ToString(),
                        ["interfaces"] = new JArray(c.Interfaces.Select(i => Ref(FPackageIndex.FromRawIndex(i.Class)))),
                        ["props"] = Props(c.LoadedProperties),
                    });
                    break;
                case StructExport s when s.GetType() == typeof(StructExport) || s is not FunctionExport:
                    classes.Add(new JObject
                    {
                        ["name"] = s.ObjectName.ToString(),
                        ["kind"] = s.GetType().Name,
                        ["super"] = Ref(s.SuperStruct),
                        ["props"] = Props(s.LoadedProperties),
                    });
                    break;
            }
        }
        root["classes"] = classes;
        root["functions"] = funcs;
        return root;
    }

    static int Main(string[] args)
    {
        if (args.Length == 2 && args[0] == "--raw")
        {   // full UAssetAPI JSON of one asset (data tables, data assets, ...)
            Console.WriteLine(new UAsset(args[1], EngineVersion.VER_UE4_26).SerializeJson(true));
            return 0;
        }
        if (args.Length < 3) { Console.Error.WriteLine("usage: bpdump <extract-root> <out-dir> <asset|dir>...  |  bpdump --raw <asset>"); return 2; }
        string rootDir = Path.GetFullPath(args[0]), outDir = args[1];
        var files = args.Skip(2).SelectMany(a => Directory.Exists(a)
            ? Directory.EnumerateFiles(a, "*.uasset", SearchOption.AllDirectories)
            : new[] { a }).ToList();
        int ok = 0, fail = 0;
        foreach (var f in files)
        {
            var rel = Path.GetRelativePath(rootDir, Path.GetFullPath(f));
            var dst = Path.Combine(outDir, Path.ChangeExtension(rel, ".json"));
            try
            {
                var j = Dump(f);
                if (((JArray)j["functions"]).Count == 0 && ((JArray)j["classes"]).Count == 0) continue;
                j["asset"] = rel;
                Directory.CreateDirectory(Path.GetDirectoryName(dst));
                File.WriteAllText(dst, j.ToString(Formatting.Indented));
                ok++;
            }
            catch (Exception ex) { Console.Error.WriteLine($"FAIL {rel}: {ex.GetType().Name}: {ex.Message}"); fail++; }
        }
        Console.Error.WriteLine($"dumped {ok}, failed {fail}");
        return 0;
    }
}
