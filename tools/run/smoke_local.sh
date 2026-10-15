#!/usr/bin/env bash
# Start backend + one game host for a client build inside a private network namespace and run the
# server smoke test against it. Own backend data and game-server directory (work/run/smoke-*), so local play is
# untouched. Usage: tools/run/smoke_local.sh <client-dir> [seconds-to-keep-host]
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd) || exit 1; client=$(realpath "$1"); keep=${2:-30}
R=smoke
rm -rf "$REPO/work/run/$R-hosts" "$REPO/work/run/$R-data"; mkdir -p "$REPO/work/run" "$REPO/work/logs"
cat > "$REPO/work/smoke_local.inner" <<IN
ip link set lo up; mount -t tmpfs tmpfs /tmp/.X11-unix
export WINEPREFIX=$REPO/work/wine/prefix
'$REPO/backend/.venv/bin/python' -u '$REPO/backend/fangs_backend.py' --port 8080 --game-dir '$client' \\
  --data '$REPO/work/run/$R-data/store.json' --instances '$REPO/work/run/$R-hosts' --log '$REPO/work/logs/$R-backend.jsonl' \\
  > '$REPO/work/logs/$R-backend.log' 2>&1 &
sleep 2
'$REPO/backend/.venv/bin/python' '$REPO/tools/run/smoke_server.py' 127.0.0.1:8080
sleep $keep; wineserver -k; sleep 2; kill \$(jobs -p) 2>/dev/null; wait
IN
env -u WAYLAND_DISPLAY -u DISPLAY unshare -rnm bash "$REPO/work/smoke_local.inner"
for h in "$REPO"/work/run/$R-hosts/host-*/MOBA/Binaries/Win64/ue4ss/UE4SS.log; do echo "== $h"; grep -E 'fangshost|Using engine version|ProcessLocalScriptFunction|Failed to find|scan' "$h" | cut -c30-200 | head -30; done
