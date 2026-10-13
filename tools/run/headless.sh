#!/usr/bin/env bash
# Run one or more headless FANGS instances inside a private network namespace
# (loopback only, nothing leaves the machine), off-screen via Xvfb.
#
# Usage: tools/run/headless.sh <seconds> <client-dir> -- <name>:<delay>:<MOBA.exe args> [-- ...]
#   Each instance gets its own reflink copy at work/run/<name> (logs in its MOBA/Saved/Logs).
# Env: UE4SS=1 installs UE4SS + tools/ue4ss mods (FangsCtl: append commands to
#      work/run/<name>/MOBA/Binaries/Win64/fangsctl_cmd.txt).
#      BACKEND=<host:port> points the AccelByte SDK at our backend (user-level Engine.ini).
#      RUN_BACKEND=1 also starts backend/fangs_backend.py inside the namespace on BACKEND's port.
#      RENDER=1 uses software rendering (wined3d + llvmpipe) instead of -nullrhi; the main menu needs it.
#      GPU=1 renders on the real GPU, off-screen: gamescope --backend headless + DXVK prefix (work/wine/prefix-gpu).
#      NOMOVIES=1 deletes the .mp4s from each instance copy (media playback crashes -nullrhi clients).
#      SAVES=<dir> copies <dir>/*.sav into each instance's MOBA/Saved/SaveGames.
# Example:
#   tools/run/headless.sh 120 clients/playtest-main_v0_0_444 \
#     -- host:0:"LE_Lobby_Map?listen" -- c1:30:"127.0.0.1"
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
secs=$1; client=$(realpath "$2"); shift 2
[[ ${1:-} == -- ]] && shift
export WINEPREFIX=$REPO/work/wine/prefix WINEDEBUG=-all
[[ ${UE4SS:-0} == 1 ]] && export WINEDLLOVERRIDES="dwmapi=n,b"
specs=(); cur=""
for a in "$@"; do
  if [[ $a == -- ]]; then specs+=("$cur"); cur=""; else cur+="${cur:+ }$a"; fi
done
[[ -n $cur ]] && specs+=("$cur")

script=$(mktemp); trap 'rm -f "$script"' EXIT
if [[ ${RENDER:-0} == 1 || ${GPU:-0} == 1 ]]; then rflags="-windowed -ResX=1280 -ResY=720 -d3d11"; else rflags="-nullrhi"; fi
launcher="xvfb-run -a -s '-screen 0 1280x720x24'"
if [[ ${GPU:-0} == 1 ]]; then
  launcher="gamescope --backend headless -r 60 -W 1920 -H 1080 -w 1280 -h 720 --"
  export DXVK_FILTER_DEVICE_NAME="NVIDIA" DXVK_CONFIG="dxgi.syncInterval = 0" DXVK_LOG_LEVEL=warn
  export WINEPREFIX=$REPO/work/wine/prefix-gpu WINEDLLOVERRIDES="dwmapi,d3d11,dxgi,d3d10core=n,b"
fi
{
  echo 'ip link set lo up; mount -t tmpfs tmpfs /tmp/.X11-unix'
  if [[ ${RUN_BACKEND:-0} == 1 ]]; then
    echo "'$REPO/backend/.venv/bin/python' -u '$REPO/backend/fangs_backend.py' --port ${BACKEND##*:} > '$REPO/work/logs/backend.stdout' 2>&1 &"
    echo "sleep 1"
  fi
  for s in "${specs[@]}"; do
    name=${s%%:*}; rest=${s#*:}; delay=${rest%%:*}; margs=${rest#*:}
    dir=$REPO/work/run/$name
    rm -rf "$dir"; cp -a --reflink=always "$client" "$dir"
    bin=$dir/MOBA/Binaries/Win64
    [[ ${NOMOVIES:-0} == 1 ]] && find "$dir/MOBA/Content/Movies" -name '*.mp4' -delete
    if [[ ${UE4SS:-0} == 1 ]]; then
      cp -a "$REPO/third_party/ue4ss/dist/dwmapi.dll" "$REPO/third_party/ue4ss/dist/ue4ss" "$bin/"
      cp -a "$REPO/tools/ue4ss/Mods/." "$bin/ue4ss/Mods/"
      cp "$REPO/tools/ue4ss/mods.txt" "$bin/ue4ss/Mods/mods.txt"
      cp "$REPO/tools/ue4ss/UE4SS-settings.ini" "$bin/ue4ss/UE4SS-settings.ini"
      cp -a "$REPO/tools/ue4ss/UE4SS_Signatures" "$bin/ue4ss/"
      : > "$bin/fangsctl_cmd.txt"
    fi
    if [[ -n ${BACKEND:-} ]]; then
      mkdir -p "$dir/MOBA/Saved/Config/WindowsNoEditor"
      sed "s/@BACKEND@/$BACKEND/g" "$REPO/tools/run/config/Engine.ini.template" > "$dir/MOBA/Saved/Config/WindowsNoEditor/Engine.ini"
    fi
    if [[ -n ${SAVES:-} ]]; then
      mkdir -p "$dir/MOBA/Saved/SaveGames"; cp "$SAVES"/*.sav "$dir/MOBA/Saved/SaveGames/"
    fi
    echo "( sleep $delay; cd '$dir/MOBA/Binaries/Win64' && exec $launcher wine MOBA.exe $margs $rflags -nosound -unattended -nosplash -log ) > '$REPO/work/logs/$name.stdout' 2>&1 &"
  done
  echo "sleep $secs; wineserver -k; sleep 3; kill \$(jobs -p) 2>/dev/null; wait"
} > "$script"
mkdir -p "$REPO/work/logs"
env -u WAYLAND_DISPLAY -u DISPLAY unshare -rnm bash "$script" || true
for s in "${specs[@]}"; do
  name=${s%%:*}
  cp "$REPO/work/run/$name/MOBA/Saved/Logs/MOBA.log" "$REPO/work/logs/$name.log" 2>/dev/null && echo "log: work/logs/$name.log"
  cp "$REPO/work/run/$name/MOBA/Binaries/Win64/ue4ss/UE4SS.log" "$REPO/work/logs/$name.ue4ss.log" 2>/dev/null && echo "log: work/logs/$name.ue4ss.log"
done
