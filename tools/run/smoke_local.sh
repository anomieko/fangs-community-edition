#!/usr/bin/env bash
# Start backend + one game host for a client build inside a private network namespace and run the
# server smoke test against it. Usage: tools/run/smoke_local.sh <client-dir> [seconds-to-keep-host]
set -u
REPO=$(cd "$(dirname "$0")/../.." && pwd); client=$(realpath "$1"); keep=${2:-30}
rm -rf "$REPO/work/hosts" "$REPO/backend/data"
cat > "$REPO/work/smoke_local.inner" <<IN
ip link set lo up; mount -t tmpfs tmpfs /tmp/.X11-unix
export WINEPREFIX=$REPO/work/wine/prefix
'$REPO/backend/.venv/bin/python' -u '$REPO/backend/fangs_backend.py' --port 8080 --game-dir '$client' > '$REPO/work/logs/smoke-backend.log' 2>&1 &
sleep 2
'$REPO/backend/.venv/bin/python' '$REPO/tools/run/smoke_server.py' 127.0.0.1:8080
sleep $keep; wineserver -k; sleep 2; kill \$(jobs -p) 2>/dev/null; wait
IN
env -u WAYLAND_DISPLAY -u DISPLAY unshare -rnm bash "$REPO/work/smoke_local.inner"
for h in "$REPO"/work/hosts/host-*/MOBA/Binaries/Win64/ue4ss/UE4SS.log; do echo "== $h"; grep -E 'fangshost|Using engine version|ProcessLocalScriptFunction|Failed to find|scan' "$h" | cut -c30-200 | head -30; done
