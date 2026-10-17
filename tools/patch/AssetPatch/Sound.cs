// New sounds in the patch pak (docs/PATCHING.md, "New sounds").
//
// A patch asset with "template" is a new asset: the template (one of the game's own assets) is copied under the new
// path and renamed. For a SoundWave template, "soundwave-audio" then puts an audio file in it: the file is encoded to
// Ogg Vorbis with ffmpeg, the cooked audio (an inline bulk payload in the template's own "OGG…" format) and the
// NumChannels / SampleRate / Duration / TotalSamples properties are replaced. The audio file is never in git: the
// patch states its sha256 and where to get it.
//
// "insert-play-sound" plays a sound from a Blueprint function: a GameplayStatics.SpawnSoundAttached call inserted as a
// new statement (Splice moves every code offset), attached where an existing call of the same function attaches.
using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.Cryptography;
using Newtonsoft.Json.Linq;
using UAssetAPI;
using UAssetAPI.ExportTypes;
using UAssetAPI.Kismet.Bytecode;
using UAssetAPI.Kismet.Bytecode.Expressions;
using UAssetAPI.PropertyTypes.Objects;
using UAssetAPI.UnrealTypes;

static partial class Program
{
    // "MOBA/Content/FangsCE/Audio/X" -> "/Game/FangsCE/Audio/X"
    static string GamePath(string rel)
    {
        const string prefix = "MOBA/Content/";
        if (!rel.StartsWith(prefix)) throw new PatchError($"'{rel}' is not under {prefix}");
        return "/Game/" + rel[prefix.Length..];
    }

    // The asset a patch entry edits: the game's own, or for a new asset ("template"), a renamed copy of the template.
    static UAsset LoadForPatch(JObject asset, string inRoot, string rel)
    {
        if ((string)asset["template"] is not string template) return Load(Path.Combine(inRoot, rel + ".uasset"));
        if (File.Exists(Path.Combine(inRoot, rel + ".uasset"))) throw new PatchError($"{rel} already exists in the game: not a new asset");
        var a = Load(Path.Combine(inRoot, template + ".uasset"));
        foreach (var (from, to) in new[] { (GamePath(template), GamePath(rel)), (Path.GetFileName(template), Path.GetFileName(rel)) })
        {
            int i = a.SearchNameReference(new FString(from));
            if (i < 0) throw new PatchError($"template {template}: no name '{from}'");
            a.SetNameReference(i, new FString(to));
        }
        Console.WriteLine($"  new asset from {template}");
        return a;
    }

    static string Run(string exe, params string[] args)
    {
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var x in args) psi.ArgumentList.Add(x);
        Process p;
        try { p = Process.Start(psi); }
        catch (Exception) { throw new PatchError($"{exe} is needed for this patch and isn't installed"); }
        var stdout = p.StandardOutput.ReadToEndAsync();
        string err = p.StandardError.ReadToEnd();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new PatchError($"{exe} failed: {err.Trim().Split('\n')[^1]}");
        return stdout.Result;
    }

    // Byte layout after a cooked SoundWave's properties (4.26): bCooked (u32), format count (u32), format name (FName:
    // index, number), bulk data flags (u32), element count (i32), size on disk (i32), offset in file (i64, from the
    // start of the .uasset), the payload, then CompressedDataGuid (16 bytes).
    const int SoundHeader = 36;

    static string SoundWaveAudio(UAsset a, JObject ed)
    {
        string root = Environment.GetEnvironmentVariable("PATCH_MEDIA_ROOT") ?? Directory.GetCurrentDirectory();
        string media = Path.Combine(root, Req(ed, "media"));
        if (!File.Exists(media))
            throw new PatchError($"the sound file {Req(ed, "media")} is missing. Download it from {ed["source"]} into that path (it is never in git; see {ed["doc"]})");
        string sha = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(media))).ToLowerInvariant();
        if (sha != Req(ed, "sha256")) throw new PatchError($"{Req(ed, "media")}: sha256 {sha}, patch expects {ed["sha256"]}");

        var ex = a.Exports.OfType<NormalExport>().SingleOrDefault() ?? throw new PatchError("soundwave-audio: the asset must have one export");
        if (a.Imports[-(ex.ClassIndex.Index) - 1].ObjectName.ToString() != "SoundWave") throw new PatchError("soundwave-audio: not a SoundWave");
        var x = ex.Extras;
        if (x == null || x.Length < SoundHeader + 16) throw new PatchError("soundwave-audio: no cooked audio in the template");
        uint cooked = BinaryPrimitives.ReadUInt32LittleEndian(x), formats = BinaryPrimitives.ReadUInt32LittleEndian(x.AsSpan(4));
        string format = a.GetNameReference(BinaryPrimitives.ReadInt32LittleEndian(x.AsSpan(8))).Value;
        uint flags = BinaryPrimitives.ReadUInt32LittleEndian(x.AsSpan(16));
        int count = BinaryPrimitives.ReadInt32LittleEndian(x.AsSpan(20)), onDisk = BinaryPrimitives.ReadInt32LittleEndian(x.AsSpan(24));
        if (cooked != 1 || formats != 1 || !format.StartsWith("OGG") || flags != 0x48 || count != onDisk || SoundHeader + count + 16 != x.Length)
            throw new PatchError($"soundwave-audio: the template's audio isn't one inline Ogg payload (cooked {cooked}, formats {formats}, {format}, flags 0x{flags:x})");

        // encode: the template's channels and sample rate, the patch's gain
        int channels = Prop<IntPropertyData>(ex, "NumChannels").Value, rate = Prop<IntPropertyData>(ex, "SampleRate").Value;
        double gain = (double?)ed["gain_db"] ?? 0;
        string tmp = Path.Combine(Path.GetTempPath(), $"assetpatch-{Guid.NewGuid():N}");
        Directory.CreateDirectory(tmp);
        try
        {
            string ogg = Path.Combine(tmp, "a.ogg");
            Run("ffmpeg", "-nostdin", "-v", "error", "-i", media, "-map_metadata", "-1", "-ac", channels.ToString(Inv), "-ar", rate.ToString(Inv),
                "-af", $"volume={gain.ToString(Inv)}dB", "-c:a", "libvorbis", "-q:a", "5", "-f", "ogg", ogg);
            byte[] payload = File.ReadAllBytes(ogg);
            long samples = new FileInfo(Decode(ogg, tmp)).Length / 2;   // decoded as mono 16-bit: 2 bytes per frame
            float duration = (float)samples / rate;

            Prop<FloatPropertyData>(ex, "Duration").Value = duration;
            SetNumber(ex, "TotalSamples", samples);
            var nx = new byte[SoundHeader + payload.Length + 16];
            x.AsSpan(0, SoundHeader).CopyTo(nx);
            BinaryPrimitives.WriteInt32LittleEndian(nx.AsSpan(20), payload.Length);
            BinaryPrimitives.WriteInt32LittleEndian(nx.AsSpan(24), payload.Length);
            payload.CopyTo(nx, SoundHeader);
            Guid.NewGuid().ToByteArray().CopyTo(nx, SoundHeader + payload.Length);   // CompressedDataGuid: new audio, new key
            ex.Extras = nx;

            // the payload's offset in the file: known once the asset is laid out (sizes don't change after this)
            a.WriteData();
            long propsSize = ex.SerialSize - nx.Length;
            BinaryPrimitives.WriteInt64LittleEndian(nx.AsSpan(28), ex.SerialOffset + propsSize + SoundHeader);
            return $"{ex.ObjectName}: {Path.GetFileName(media)} (sha256 {sha[..12]}) as {format}, {channels} ch, {rate} Hz, " +
                   $"{duration:0.###} s, {payload.Length} bytes, gain {gain} dB";
        }
        finally { Directory.Delete(tmp, true); }
    }

    static string Decode(string ogg, string dir)
    {
        string raw = Path.Combine(dir, "a.raw");
        Run("ffmpeg", "-nostdin", "-v", "error", "-i", ogg, "-f", "s16le", "-ac", "1", raw);
        return raw;
    }

    static T Prop<T>(NormalExport ex, string name) where T : PropertyData =>
        ex.Data.OfType<T>().SingleOrDefault(p => p.Name.ToString() == name)
        ?? throw new PatchError($"{ex.ObjectName}: no {typeof(T).Name[..^12]} '{name}'");

    static void SetNumber(NormalExport ex, string name, long v)
    {
        switch (ex.Data.SingleOrDefault(p => p.Name.ToString() == name))
        {
            case FloatPropertyData f: f.Value = v; break;
            case IntPropertyData i: i.Value = (int)v; break;
            default: throw new PatchError($"{ex.ObjectName}: no number '{name}'");
        }
    }

    // An import, found or added: classPackage/className say what it is, outer is another import (or null).
    static FPackageIndex EnsureImport(UAsset a, string classPackage, string className, FPackageIndex outer, string objectName)
    {
        for (int i = 0; i < a.Imports.Count; i++)
        {
            var m = a.Imports[i];
            if (m.ObjectName.ToString() == objectName && m.ClassName.ToString() == className
                && m.ClassPackage.ToString() == classPackage && m.OuterIndex.Index == (outer?.Index ?? 0))
                return FPackageIndex.FromImport(i);
        }
        foreach (var s in new[] { classPackage, className, objectName }) a.AddNameReference(new FString(s));
        return a.AddImport(new Import(new FName(a, classPackage), new FName(a, className), outer ?? new FPackageIndex(0), new FName(a, objectName), false));
    }

    static FPackageIndex EnsurePackage(UAsset a, string package) => EnsureImport(a, "/Script/CoreUObject", "Package", null, package);

    // An asset import: "/Game/A/B" of class /Script/Engine.<cls> -> the object B in package /Game/A/B
    static FPackageIndex EnsureAsset(UAsset a, string path, string cls) =>
        EnsureImport(a, "/Script/Engine", cls, EnsurePackage(a, path), path[(path.LastIndexOf('/') + 1)..]);

    // Insert GameplayStatics.SpawnSoundAttached(sound, <attach>, None, 0, 0, KeepRelativeOffset, false, volume, 1, 0,
    // attenuation, nullptr, true) before the one statement of `function` that calls `before`; <attach> is that call's
    // argument `attach_arg` (e.g. the component an FMOD event is attached to).
    static string InsertPlaySound(UAsset a, JObject ed)
    {
        var f = Function(a, Req(ed, "function"));
        string before = Req(ed, "before"), sound = Req(ed, "sound"), atten = (string)ed["attenuation"];
        int attachArg = (int?)ed["attach_arg"] ?? throw new PatchError("insert-play-sound needs \"attach_arg\"");
        float volume = (float?)ed["volume"] ?? 1f;
        var hits = StatementsCalling(a, f, before);
        if (hits.Count != 1) throw new PatchError($"insert-play-sound: {hits.Count} statements of {f.ObjectName} call {before}, need exactly 1");
        var anchor = Statement(a, f.ScriptBytecode[hits[0]]).First(e => CallName(a, e) == before);
        var attach = Clone(a, Args(anchor)[attachArg]);

        var engine = EnsurePackage(a, "/Script/Engine");
        var statics = EnsureImport(a, "/Script/CoreUObject", "Class", engine, "GameplayStatics");
        var spawn = EnsureImport(a, "/Script/CoreUObject", "Function", statics, "SpawnSoundAttached");
        var wave = EnsureAsset(a, sound, "SoundWave");
        var attenuation = atten == null ? null : EnsureAsset(a, atten, "SoundAttenuation");
        a.AddNameReference(new FString("None"));
        var call = new EX_CallMath
        {
            StackNode = spawn,
            Parameters =
            [
                new EX_ObjectConst { Value = wave },
                attach,
                new EX_NameConst { Value = new FName(a, "None") },
                new EX_VectorConst { Value = new FVector(0f, 0f, 0f) },
                new EX_RotationConst { Value = new FRotator(0f, 0f, 0f) },
                new EX_ByteConst { Value = 0 },              // EAttachLocation::KeepRelativeOffset
                new EX_False(),                              // bStopWhenAttachedToDestroyed
                new EX_FloatConst { Value = volume },
                new EX_FloatConst { Value = 1f },            // pitch
                new EX_FloatConst { Value = 0f },            // start time
                attenuation == null ? new EX_NoObject() : new EX_ObjectConst { Value = attenuation },
                new EX_NoObject(),                           // concurrency
                new EX_True(),                               // bAutoDestroy
            ],
        };
        Splice(a, f, hits[0], 0, [call]);
        // the function's code references them: created before it is serialized, as the cooker lists bytecode references
        foreach (var dep in new[] { wave, attenuation, spawn, statics }.Where(d => d != null))
            if (!f.CreateBeforeSerializationDependencies.Any(d => d.Index == dep.Index)) f.CreateBeforeSerializationDependencies.Add(dep);
        return $"{f.ObjectName}: SpawnSoundAttached({sound}, volume {volume}{(atten != null ? ", " + atten : "")}) inserted before the call to {before} (statement {hits[0]})";
    }
}
