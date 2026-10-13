#!/usr/bin/env bash
# Install the Fangs: Community Edition player files into a FANGS game directory (or a staging dir).
# Usage: install-player-files.sh <game-or-staging-dir> [backend host:port]
#   - UE4SS (dwmapi.dll + ue4ss/) with only the FangsBoot mod
#   - MOBA/Saved/Config/WindowsNoEditor/Engine.ini pointing the game at the backend (if given)
# Game files themselves are never modified.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
dest=$1; backend=${2:-}
: "${UE4SS_DIST:=$REPO/third_party/ue4ss/dist}"
[[ -f $UE4SS_DIST/dwmapi.dll ]] || { echo "UE4SS not found in $UE4SS_DIST (see README)" >&2; exit 1; }

bin=$dest/MOBA/Binaries/Win64
mkdir -p "$bin"
rm -rf "$bin/ue4ss"
cp "$UE4SS_DIST/dwmapi.dll" "$bin/"
mkdir -p "$bin/ue4ss/Mods"
cp "$UE4SS_DIST/ue4ss/UE4SS.dll" "$UE4SS_DIST/ue4ss/LICENSE" "$bin/ue4ss/"
cp -r "$UE4SS_DIST/ue4ss/Mods/shared" "$bin/ue4ss/Mods/"           # UEHelpers
cp -r "$REPO/tools/ue4ss/Mods/FangsBoot" "$bin/ue4ss/Mods/"
printf 'FangsBoot : 1\n' > "$bin/ue4ss/Mods/mods.txt"
cp "$REPO/tools/ue4ss/UE4SS-settings.ini" "$bin/ue4ss/"
[[ -f $bin/MOBA.exe ]] && cp -r "$REPO/tools/ue4ss/UE4SS_Signatures" "$bin/ue4ss/"   # Development build only

if [[ -n $backend ]]; then
  cfg=$dest/MOBA/Saved/Config/WindowsNoEditor
  mkdir -p "$cfg"
  sed "s/@BACKEND@/$backend/g" "$REPO/tools/run/config/Engine.ini.template" > "$cfg/Engine.ini"
fi
echo "player files installed in $dest${backend:+ (backend $backend)}"
