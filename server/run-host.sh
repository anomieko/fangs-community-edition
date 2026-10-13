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
# The view is rebuilt whenever the game install changes (new build deployed): across filesystems it is
# symlinks plus a *copy* of the exe, which would otherwise stay the old build's exe.
stamp="$exe $(stat -c '%s %Y' "$game/MOBA/Binaries/Win64/$exe") $(cat "$game/MOBA/Content/Data/version.txt" 2>/dev/null || true)"
if [[ ! -e $inst/MOBA/Binaries/Win64/$exe || "$(cat "$inst/.game-stamp" 2>/dev/null)" != "$stamp" ]]; then
  [[ -n $inst && $inst != / ]] || { echo "bad instance dir '$inst'" >&2; exit 1; }
  rm -rf "$inst"; mkdir -p "$(dirname "$inst")"
  cp -al "$game" "$inst" 2>/dev/null || { rm -rf "$inst"; cp -as "$game" "$inst"; cp --remove-destination "$game/MOBA/Binaries/Win64/$exe" "$inst/MOBA/Binaries/Win64/$exe"; }
  echo "$stamp" > "$inst/.game-stamp"
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

# FANGS_PREFIX_PER_HOST: each game server gets its own Wine prefix (a copy of $WINEPREFIX, refreshed when the
# Wine version changes), so its own wineserver. Servers sharing one died (exit 3) when another one started.
if [[ -n ${FANGS_PREFIX_PER_HOST:-} && -n ${WINEPREFIX:-} ]]; then
  pfx=$inst.wine; ver=$(cat "$WINEPREFIX/.wine-version" 2>/dev/null || true)
  if [[ ! -f $pfx/system.reg || "$(cat "$pfx/.wine-version" 2>/dev/null)" != "$ver" ]]; then
    rm -rf "$pfx.tmp"; cp -a "$WINEPREFIX" "$pfx.tmp"; rm -rf "$pfx"; mv "$pfx.tmp" "$pfx"
  fi
  export WINEPREFIX=$pfx
fi
# Shipping builds read the user config from the Wine user's AppData, not from MOBA/Saved
# (the Wine user's profile, whatever its name: in a user namespace `id -un` is root but the profile isn't)
if [[ -n ${FANGS_BACKEND:-} && -n ${WINEPREFIX:-} ]]; then
  profiles=(); for d in "$WINEPREFIX"/drive_c/users/*/; do [[ $(basename "$d") == Public ]] || profiles+=("$d"); done
  [[ ${#profiles[@]} -gt 0 ]] || profiles=("$WINEPREFIX/drive_c/users/${USER:-$(id -un)}/")
  for d in "${profiles[@]}"; do
    appcfg=${d}AppData/Local/MOBA/Saved/Config/WindowsNoEditor
    mkdir -p "$appcfg" && cp "$inst/MOBA/Saved/Config/WindowsNoEditor/Engine.ini" "$appcfg/Engine.ini"
  done
fi

cd "$bin"
export WINEDEBUG=-all WINEDLLOVERRIDES="dwmapi=n,b"
# FANGS_HOST_DISPLAY: shared X display (the server container's); otherwise a private Xvfb per game server
if [[ -n ${FANGS_HOST_DISPLAY:-} ]]; then export DISPLAY=$FANGS_HOST_DISPLAY; x=(); else x=(xvfb-run -a -e "$inst/xvfb.log" -s '-screen 0 640x480x24'); fi
exec "${x[@]}" wine "$exe" /Game/Environment/Maps/LE_Loading_Map \
  -FangsHost -port="$port" ${FANGS_BACKEND:+-FangsBackend=$FANGS_BACKEND} -nullrhi -nosound -unattended -nosplash -log \
  -ExecCmds="t.MaxFPS ${FANGS_TICKRATE:-60}" "$@"
