#!/usr/bin/env bash
# Build the Fangs CE patch pak (docs/PATCHING.md): take the game files that the patches change out of the game's own
# pak, apply the patches (tools/patch/AssetPatch), and pack the results into one unencrypted pak, FangsCE_P.pak.
# The game loads it after its own pak, so its files replace the originals.
#
#   tools/patch/build.sh <game-dir> [patch ...]
#     patch: a file in tools/patch/patches/, without .json. None given: every patch with "enabled": true that is
#     made for this build.
#   -> work/patch/<build>/FangsCE_P.pak, or OUT=<file>. With no patch to apply, an old pak at that path is removed.
# Env: PAK_KEY = file with the game's AES key (default work/re/aeskey-2023-02-15.txt; never print or commit it).
# Needs .NET 10 and third_party/UAssetAPI. The pak holds game data: it never goes into git.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
game=$(realpath "${1:?usage: build.sh <game-dir> [patch ...]}"); shift
build=$(tr -d '\r\n' < "$game/MOBA/Content/Data/version.txt")
out=${OUT:-$REPO/work/patch/$build/FangsCE_P.pak}
key=${PAK_KEY:-$REPO/work/re/aeskey-2023-02-15.txt}
patchdir=$REPO/tools/patch/patches

if [[ $# -gt 0 ]]; then patches=("$@")
else mapfile -t patches < <(python3 -I - "$patchdir" "$build" <<'PY'
import json, pathlib, sys
for p in sorted(pathlib.Path(sys.argv[1]).glob('*.json')):
    d = json.loads(p.read_text())
    if d.get('enabled') and d['build'] == sys.argv[2]:
        print(p.stem)
PY
)
fi
if [[ ${#patches[@]} -eq 0 ]]; then
  rm -f "$out"; echo "no patch enabled: no patch pak"; exit 0
fi
for p in "${patches[@]}"; do
  [[ -f $patchdir/$p.json ]] || { echo "no patch $patchdir/$p.json" >&2; exit 1; }
  want=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"])' "$patchdir/$p.json")
  [[ $want == "$build" ]] || { echo "patch $p is for build $want, the game in $game is $build" >&2; exit 1; }
done

mkdir -p "$REPO/work/patch"
stage=$(mktemp -d "$REPO/work/patch/stage.XXXXXX"); trap 'rm -rf "$stage"' EXIT
dotnet build "$REPO/tools/patch/AssetPatch/AssetPatch.csproj" -c Release -o "$REPO/work/bin/assetpatch" \
  -p:UAssetAPIDir="$(realpath "$REPO/third_party/UAssetAPI")" > "$stage/dotnet.log" 2>&1 || { cat "$stage/dotnet.log" >&2; exit 1; }

# the game's own copies of every asset a patch changes (.uasset + .uexp)
for p in "${patches[@]}"; do
  python3 -I -c 'import json,sys
for a in json.load(open(sys.argv[1]))["assets"]: print(a["path"] + ".uasset"); print(a["path"] + ".uexp")' "$patchdir/$p.json"
done | sort -u > "$stage/files.txt"
for pak in "$game"/MOBA/Content/Paks/*.pak; do   # in load order; never our own pak
  [[ $(basename "$pak") == FangsCE_P.pak ]] && continue
  python3 -I "$REPO/tools/pak/pakextract.py" "$pak" "$stage/in" "@$stage/files.txt" "@$key" > /dev/null
done
missing=$(cd "$stage/in" 2>/dev/null && comm -23 "$stage/files.txt" <(find . -type f | sed 's#^\./##' | sort) || cat "$stage/files.txt")
[[ -z $missing ]] || { echo "not in the game's paks:" >&2; echo "$missing" >&2; exit 1; }

for p in "${patches[@]}"; do
  echo "== patch $p"
  "$REPO/work/bin/assetpatch/AssetPatch" apply "$patchdir/$p.json" "$stage/in" "$stage/out"
  cp -a "$stage/out/." "$stage/in/"   # a later patch builds on this one's changes
done

mkdir -p "$(dirname "$out")"
python3 -I "$REPO/tools/pak/pakwrite.py" "$out.tmp" "$stage/out" > /dev/null
mv "$out.tmp" "$out"
printf '%s\n' "${patches[@]}" > "$(dirname "$out")/FangsCE_P.patches"
echo "built $out ($(du -h "$out" | cut -f1), patches: ${patches[*]}, sha256 $(sha256sum "$out" | cut -c1-12))"
