// recolor-curve: a new colour for one emitter of a Niagara system (docs/PATCHING.md), e.g. the blue and purple parts of
// Astrada's Flame Cage. An emitter's colour comes from curves in its scripts, not from the system's user parameters
// (the cage's User.Color and User.CircleColor, which the game sets per team, are read by no emitter). A cooked curve
// keeps only its baked table, ShaderLUT: one sample after another over the particle's life, RGBA for a colour curve, RGB
// for a vector curve. Each colour or vector curve under the emitter whose first sample is "from" gets "to", scaled per
// sample by the old sample's brightest channel, so it brightens and fades as before but keeps one hue; alpha stays.
using System.Globalization;
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.PropertyTypes.Objects;

static partial class Program
{
    static float[] Rgb(JObject ed, string key)
    {
        var v = ((JArray)ed[key] ?? throw new PatchError($"recolor-curve needs \"{key}\" ([R, G, B])")).Select(t => (float)t).ToArray();
        return v.Length == 3 ? v : throw new PatchError($"recolor-curve: \"{key}\" needs 3 numbers (R, G, B)");
    }

    static string RecolorCurve(UAsset a, JObject ed)
    {
        var emitter = FindExport(a, Req(ed, "export"));
        float[] from = Rgb(ed, "from"), to = Rgb(ed, "to");
        float peak = from.Max();
        if (peak <= 0) throw new PatchError("recolor-curve: \"from\" needs a channel above 0");
        int root = a.Exports.IndexOf(emitter) + 1;   // FPackageIndex of the emitter
        bool Under(Export e)
        {
            for (var o = e.OuterIndex; o != null && o.IsExport(); o = o.ToExport(a).OuterIndex)
                if (o.Index == root) return true;
            return false;
        }
        string Show(IEnumerable<float> v) => "(" + string.Join(", ", v.Select(x => x.ToString("0.####", CultureInfo.InvariantCulture))) + ")";

        int n = 0;
        var others = new List<string>();
        foreach (var e in a.Exports.OfType<NormalExport>().Where(Under))
        {
            int stride = Name(a, e.ClassIndex) switch { "NiagaraDataInterfaceColorCurve" => 4, "NiagaraDataInterfaceVectorCurve" => 3, _ => 0 };
            var lut = e.Data.OfType<ArrayPropertyData>().SingleOrDefault(p => p.Name.ToString() == "ShaderLUT")?.Value;
            if (stride == 0 || lut == null || lut.Length == 0) continue;
            if (lut.Length % stride != 0 || lut.Any(v => v is not FloatPropertyData))
                throw new PatchError($"{ExportPath(a, e)}: ShaderLUT is not {stride} floats per sample");
            float V(int i) => ((FloatPropertyData)lut[i]).Value;
            var first = new[] { V(0), V(1), V(2) };
            if (first.Zip(from).Any(p => Math.Abs(p.First - p.Second) > 1e-3f * Math.Max(1, Math.Abs(p.Second))))
            {
                others.Add(Show(first));
                continue;
            }
            for (int s = 0; s < lut.Length; s += stride)
            {
                float k = Math.Max(V(s), Math.Max(V(s + 1), V(s + 2))) / peak;
                for (int c = 0; c < 3; c++) ((FloatPropertyData)lut[s + c]).Value = to[c] * k;
            }
            n++;
        }
        if (n == 0)
            throw new PatchError($"{ExportPath(a, emitter)}: no colour curve starts at {Show(from)}"
                                 + (others.Count > 0 ? $" (its curves start at {string.Join(", ", others.Distinct())})" : " (it has no colour curve)"));
        return $"{emitter.ObjectName}: {n} colour curve(s) {Show(from)} -> {Show(to)}";
    }
}
