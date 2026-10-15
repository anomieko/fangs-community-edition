#!/usr/bin/env bash
# Container entrypoint: prepare Wine + seed data, then run the backend (which launches game hosts).
set -euo pipefail
cd /opt/fangs
ls /game/MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe /game/MOBA/Binaries/Win64/MOBA.exe >/dev/null 2>&1 || ls /game/MOBA/Binaries/Win64/MOBA*.exe >/dev/null 2>&1 \
  || { echo "Mount your FANGS install at /game (no MOBA/Binaries/Win64/MOBA*.exe found)" >&2; exit 1; }
mkdir -p /data/hosts /data/backend
# One virtual display for Wine and every game server, alive as long as the container. With a display per
# game server (xvfb-run), Wine's shared helper processes (one prefix) were left on a display that died
# with the server that started them, and later servers crashed on window changes.
mkdir -p -m 1777 /tmp/.X11-unix 2>/dev/null || true
Xvfb :99 -screen 0 640x480x24 -nolisten tcp > /data/xvfb.log 2>&1 &
export DISPLAY=:99 FANGS_HOST_DISPLAY=:99
sleep 1
# (Re)create the shared Wine prefix when it's missing or was made by another Wine version.
if [[ ! -f $WINEPREFIX/system.reg || "$(cat "$WINEPREFIX/.wine-version" 2>/dev/null)" != "$(wine --version)" ]]; then
  echo "initialising Wine prefix ($(wine --version))..."
  # no Mono/Gecko (the game needs neither; WineHQ builds would otherwise wait on an install prompt)
  rm -rf "${WINEPREFIX:?}"
  WINEARCH=win64 WINEDLLOVERRIDES="mscoree,mshtml=" timeout 300 wineboot -i >/dev/null 2>&1 || true
  timeout 60 wineserver -w || wineserver -k || true
  wine --version > "$WINEPREFIX/.wine-version"
fi
python3 backend/seed/make_seed.py "$PUBLIC_HOST:$BACKEND_PORT" /data/backend/seed.json >/dev/null
[[ -n ${FANGS_JOIN_CODE:-} ]] || echo "WARNING: FANGS_JOIN_CODE not set - anyone can log in" >&2
exec python3 -u backend/fangs_backend.py --host 0.0.0.0 --port "$BACKEND_PORT" --public-ip "$PUBLIC_HOST" \
  --qos-port "$QOS_PORT" --host-ports "$HOST_PORTS" --game-dir /game --instances /data/hosts \
  --downloads /downloads --run-host /opt/fangs/server/run-host.sh --seed /data/backend/seed.json --data /data/backend/store.json --log /data/backend/requests.jsonl \
  --ranked-widen-speed 2 "$@"
