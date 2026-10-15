#!/usr/bin/env bash
# Play FANGS on Linux (Wine + DXVK on your GPU).
#
#   tools/play/local.sh <name>                      local backend + game servers on this machine
#   SERVER=<host:port> JOIN_CODE=<code> tools/play/local.sh <name>   play on a remote Fangs CE server
#   tools/play/local.sh stop                        stop the local backend and its game servers
#
# Each name gets its own game copy per build (work/play/<name>.<build>, reflink/hard-link view of the install)
# and its own Wine prefix. Intro/background movies are removed from that copy: Wine's video decoding hangs on them.
# Env: CLIENT_DIR (default clients/fangs-2022-08-26-b9396481), PLAY_HEADLESS=1 (off-screen, for tests),
#      PATCHES="<patch> ..." | none: the patch paks of a local backend (default: the enabled ones; docs/PATCHING.md).
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
# Playing on a server: use the local game copy of the build that server runs (its file list names it)
if [[ -z ${CLIENT_DIR:-} && -n ${SERVER:-} && -n ${JOIN_CODE:-} ]]; then
  want=$(curl -fsS --max-time 10 "http://$SERVER/download/$JOIN_CODE/manifest.json" 2>/dev/null \
         | python3 -c 'import json,sys; print(json.load(sys.stdin)["build"])' 2>/dev/null || true)
  for d in "$REPO"/clients/*/; do
    [[ -n $want && "$(tr -d '\r\n' < "$d/MOBA/Content/Data/version.txt" 2>/dev/null)" == "$want" ]] && { CLIENT_DIR=$d; break; }
  done
  [[ -n $want && -z ${CLIENT_DIR:-} ]] && { echo "the server runs build $want; no local copy of it in clients/" >&2; exit 1; }
  [[ -n $want ]] && echo "server runs $want: using $(basename "$CLIENT_DIR")"
fi
CLIENT_DIR=$(realpath "${CLIENT_DIR:-$REPO/clients/fangs-2022-08-26-b9396481}")
build=$(basename "$CLIENT_DIR")
DXVK=${DXVK:-$(ls -d "$HOME"/.local/share/Steam/steamapps/common/Proton*/files/lib/wine/dxvk/x86_64-windows 2>/dev/null | tail -1)}
PIDFILE=$REPO/work/play/backend.pid
mkdir -p "$REPO/work/play" "$REPO/work/logs"
backend_up() { [[ -f $PIDFILE ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

if [[ ${1:-} == stop ]]; then
  if backend_up; then
    pid=$(cat "$PIDFILE"); kill "$pid"
    for _ in $(seq 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done   # it stops its game servers first
    echo "local backend stopped (game servers stop with it)"
  fi
  rm -f "$PIDFILE"; exit 0
fi
name=${1:?usage: local.sh <name> | stop}
[[ $name =~ ^[A-Za-z0-9_]{3,16}$ ]] || { echo "name: 3-16 letters/numbers/_" >&2; exit 1; }

# Patch paks (docs/PATCHING.md), for the game copy and, with the local backend, for its game servers.
# Local backend: PATCHES="<patch> ..." builds those (default: the enabled patches for this build; PATCHES=none: none).
# On a server: the patch paks in the server's file list.
if [[ -n ${SERVER:-} ]]; then
  export FANGS_PAKS=$REPO/work/play/server-paks/$build; mkdir -p "$FANGS_PAKS"
  python3 - "$SERVER" "${JOIN_CODE:-}" "$CLIENT_DIR" "$FANGS_PAKS" <<'PY' || echo "warning: couldn't get the server's patch paks" >&2
import hashlib, json, os, sys, urllib.request
server, code, game, paks = sys.argv[1:]
base = f'http://{server}/download/{code}/'
files = json.load(urllib.request.urlopen(base + 'manifest.json', timeout=10))['files']
want = {f['path'].rsplit('/', 1)[1]: f for f in files if f['path'].startswith('MOBA/Content/Paks/')
        and f['path'].endswith('.pak') and not os.path.exists(os.path.join(game, f['path']))}
for name in os.listdir(paks):
    if name.endswith('.pak') and name not in want:
        os.remove(os.path.join(paks, name))
for name, f in want.items():
    dst = os.path.join(paks, name)
    if os.path.exists(dst) and hashlib.sha256(open(dst, 'rb').read()).hexdigest() == f['sha256']:
        continue
    data = urllib.request.urlopen(base + 'files/' + f['path'], timeout=120).read()
    if hashlib.sha256(data).hexdigest() != f['sha256']:
        sys.exit(f'{name}: checksum mismatch')
    open(dst, 'wb').write(data)
    print(f'patch pak from the server: {name}')
PY
else
  export FANGS_PAKS=$REPO/work/play/paks/$build; mkdir -p "$FANGS_PAKS"
  if [[ ${PATCHES:-} == none ]]; then rm -f "$FANGS_PAKS"/*.pak
  else OUT=$FANGS_PAKS/FangsCE_P.pak "$REPO/tools/patch/build.sh" "$CLIENT_DIR" ${PATCHES:-}
  fi
fi
paksum() { { cat "$FANGS_PAKS"/*.pak 2>/dev/null || true; } | sha256sum | cut -c1-16; }

if [[ -n ${SERVER:-} ]]; then
  backend=$SERVER
else
  backend=127.0.0.1:8080
  if backend_up && [[ "$(paksum)" != "$(cat "$REPO/work/play/backend.paks" 2>/dev/null)" ]]; then
    echo "note: the patch paks changed since the local backend started; its standby game server still has the old" \
         "ones. To be sure: tools/play/local.sh stop, then start again."
  fi
  if ! backend_up; then
    paksum > "$REPO/work/play/backend.paks"
    [[ -x $REPO/backend/.venv/bin/python ]] || { python3 -m venv "$REPO/backend/.venv"; "$REPO/backend/.venv/bin/pip" install -q aiohttp; }
    python3 "$REPO/backend/seed/make_seed.py" "$backend" >/dev/null
    [[ -d $REPO/work/wine/prefix ]] || WINEPREFIX=$REPO/work/wine/prefix WINEDEBUG=-all wineboot -i >/dev/null 2>&1
    WINEPREFIX=$REPO/work/wine/prefix setsid "$REPO/backend/.venv/bin/python" -u "$REPO/backend/fangs_backend.py" \
        --host 127.0.0.1 --port 8080 --public-ip 127.0.0.1 --game-dir "$CLIENT_DIR" > "$REPO/work/logs/local-backend.log" 2>&1 &
    echo $! > "$PIDFILE"
    sleep 2; backend_up || { echo "backend failed to start, see work/logs/local-backend.log" >&2; exit 1; }
    echo "local backend running on $backend (log: work/logs/local-backend.log)"
  fi
fi

# game copy + player files
exe=; for e in MOBA-Win64-Shipping.exe MOBA.exe; do [[ -f "$CLIENT_DIR/MOBA/Binaries/Win64/$e" ]] && { exe=$e; break; }; done
inst=$REPO/work/play/$name.$build   # one game copy (and Wine prefix) per player name and build
if [[ ! -e $inst/MOBA/Binaries/Win64/$exe ]]; then
  cp -a --reflink=auto "$CLIENT_DIR" "$inst" 2>/dev/null || cp -al "$CLIENT_DIR" "$inst"
  find "$inst/MOBA/Content/Movies" -name '*.mp4' -delete 2>/dev/null || true
fi
"$REPO/player/install-player-files.sh" "$inst" "$backend" >/dev/null
"$REPO/server/install-paks.sh" "$CLIENT_DIR" "$inst"

# own Wine prefix with DXVK (D3D11 -> Vulkan on your GPU)
export WINEPREFIX=$inst.prefix WINEDEBUG=-all WINEDLLOVERRIDES="dwmapi,d3d11,dxgi,d3d10core=n,b"
if [[ ! -f $WINEPREFIX/system.reg ]]; then
  echo "creating Wine prefix for $name..."; wineboot -i >/dev/null 2>&1 || true
  [[ -n $DXVK ]] && cp "$DXVK"/{d3d11,dxgi,d3d10core}.dll "$WINEPREFIX/drive_c/windows/system32/"
fi
cfg=$WINEPREFIX/drive_c/users/$USER/AppData/Local/MOBA/Saved/Config/WindowsNoEditor   # Shipping builds
mkdir -p "$cfg" && cp "$inst/MOBA/Saved/Config/WindowsNoEditor/Engine.ini" "$cfg/Engine.ini"

# account secret (the server ties the name to it) + optional community join code
secret_file=$REPO/work/play/$name.secret
[[ -f $secret_file ]] || python3 -c 'import secrets; print(secrets.token_hex(16))' > "$secret_file"
pass=$(cat "$secret_file"); [[ -n ${JOIN_CODE:-} ]] && pass="$JOIN_CODE:$pass"

cd "$inst/MOBA/Binaries/Win64"
args=(-TestUser="$name" -TestPass="$pass" -windowed -ResX=1600 -ResY=900)
echo "starting FANGS as '$name' against $backend"
if [[ ${PLAY_HEADLESS:-0} == 1 ]]; then
  exec gamescope --backend headless -W 1920 -H 1080 -w 1600 -h 900 -- wine "$exe" "${args[@]}" -nosound
else
  exec wine "$exe" "${args[@]}"
fi
