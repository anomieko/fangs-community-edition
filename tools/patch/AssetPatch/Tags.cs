// set-tags: replace the tags of one gameplay tag container in an export, e.g. an ability's ActivationBlockedTags
// (docs/PATCHING.md). Like the other edits it states what it expects to find ("from") and fails otherwise.
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.PropertyTypes.Objects;
using UAssetAPI.PropertyTypes.Structs;
using UAssetAPI.UnrealTypes;

static partial class Program
{
    static List<string> TagList(JObject ed, string key) =>
        ((JArray)ed[key] ?? throw new PatchError($"set-tags needs \"{key}\" (a list of tags)")).Select(t => (string)t).ToList();

    // The tag container property of an export: stored as a tag container, or as a struct holding one of the same name.
    static GameplayTagContainerPropertyData TagContainer(PropertyData p) => p switch
    {
        GameplayTagContainerPropertyData g => g,
        StructPropertyData { Value.Count: 1 } s when s.Value[0] is GameplayTagContainerPropertyData g => g,
        _ => throw new PatchError($"{p.Name} is not a gameplay tag container ({p.PropertyType})"),
    };

    static string SetTags(UAsset a, JObject ed)
    {
        string prop = Req(ed, "property");
        NormalExport exp = ed["export"] != null ? FindExport(a, (string)ed["export"]) : ClassDefaults(a);
        List<string> from = TagList(ed, "from"), to = TagList(ed, "to");
        var hits = exp.Data.Where(d => d.Name.ToString() == prop).ToList();
        if (hits.Count != 1)
            throw new PatchError($"{exp.ObjectName}.{prop}: found {hits.Count} (only tags stored in this export can be changed)");
        var c = TagContainer(hits[0]);
        var now = c.Value.Select(n => n.ToString()).ToList();
        if (!now.SequenceEqual(from))
            throw new PatchError($"{exp.ObjectName}.{prop} is [{string.Join(", ", now)}], patch expects [{string.Join(", ", from)}]");
        foreach (var t in to) a.AddNameReference(new FString(t));
        c.Value = to.Select(t => new FName(a, t)).ToArray();
        return $"{exp.ObjectName}.{prop}: [{string.Join(", ", now)}] -> [{string.Join(", ", to)}]";
    }
}
