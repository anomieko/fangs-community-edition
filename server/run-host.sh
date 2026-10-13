#!/usr/bin/env bash
# Launch one headless FANGS game host (dedicated lobby server) under Wine.
# Usage: run-host.sh <game-dir> <instance-dir> <port> [extra game args...]
# The instance dir is a hard-linked (or symlinked) view of the game dir plus private
# MOBA/Saved and UE4SS files, so many hosts can share one copy of the 14 GB install.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
game=$(realpath "$1"); inst=$2; port=$3; shift 3
: "${UE4SS_DIST:=$REPO/third_party/ue4ss/dist}" "${FANGS_MODS:=$REPO/tools/ue4ss}"

exe=; for e in MOBA-Win64-Shipping.exe MOBA.exe; do [[ -f "$game/MOBA/Binaries/Win64/$e" ]] && { exe=$e; break; }; done
[[ -n $exe ]] || { echo "no game exe in $game/MOBA/Binaries/Win64" >&2; exit 1; }
if [[ ! -e $inst/MOBA/Binaries/Win64/$exe ]]; then
  mkdir -p "$(dirname "$inst")"
  cp -al "$game" "$inst" 2>/dev/null || { rm -rf "$inst"; cp -as "$game" "$inst"; cp --remove-destination "$game/MOBA/Binaries/Win64/$exe" "$inst/MOBA/Binaries/Win64/$exe"; }
fi
bin=$inst/MOBA/Binaries/Win64
rm -rf "$bin/ue4ss" "$bin/dwmapi.dll"
cp -a "$UE4SS_DIST/dwmapi.dll" "$UE4SS_DIST/ue4ss" "$bin/"
cp -a "$FANGS_MODS/Mods/." "$bin/ue4ss/Mods/"
cp "$FANGS_MODS/mods.txt" "$bin/ue4ss/Mods/mods.txt"
cp "$FANGS_MODS/UE4SS-settings.ini" "$bin/ue4ss/UE4SS-settings.ini"
# Custom AOBs are only needed for the Development (MOBA.exe) build; Shipping builds scan natively.
[[ $exe == MOBA.exe ]] && cp -a "$FANGS_MODS/UE4SS_Signatures" "$bin/ue4ss/"
: > "$bin/fangsctl_cmd.txt"
if [[ -n ${FANGS_BACKEND:-} ]]; then   # server-side AccelByte calls (server login, player records)
  mkdir -p "$inst/MOBA/Saved/Config/WindowsNoEditor"
  sed "s/@BACKEND@/$FANGS_BACKEND/g" "$REPO/tools/run/config/Engine.ini.template" > "$inst/MOBA/Saved/Config/WindowsNoEditor/Engine.ini"
fi
rm -f "$inst/MOBA/Saved/Logs/MOBA.log"

cd "$bin"
export WINEDEBUG=-all WINEDLLOVERRIDES="dwmapi=n,b"
exec xvfb-run -a -s '-screen 0 640x480x24' wine "$exe" /Game/Environment/Maps/LE_Loading_Map \
  -FangsHost -port="$port" ${FANGS_BACKEND:+-FangsBackend=$FANGS_BACKEND} -nullrhi -nosound -unattended -nosplash -log \
  -ExecCmds="t.MaxFPS ${FANGS_TICKRATE:-60}" "$@"
