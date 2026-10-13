#!/usr/bin/env bash
# Container entrypoint: prepare Wine + seed data, then run the backend (which launches game hosts).
set -euo pipefail
cd /opt/fangs
ls /game/MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe /game/MOBA/Binaries/Win64/MOBA.exe >/dev/null 2>&1 || ls /game/MOBA/Binaries/Win64/MOBA*.exe >/dev/null 2>&1 \
  || { echo "Mount your FANGS install at /game (no MOBA/Binaries/Win64/MOBA*.exe found)" >&2; exit 1; }
mkdir -p /data/hosts /data/backend
if [[ ! -f $WINEPREFIX/system.reg ]]; then
  echo "initialising Wine prefix..."; wineboot -i >/dev/null 2>&1 || true; wineserver -w || true
fi
python3 backend/seed/make_seed.py "$PUBLIC_HOST:$BACKEND_PORT" /data/backend/seed.json >/dev/null
[[ -n ${FANGS_JOIN_CODE:-} ]] || echo "WARNING: FANGS_JOIN_CODE not set - anyone can log in" >&2
exec python3 -u backend/fangs_backend.py --host 0.0.0.0 --port "$BACKEND_PORT" --public-ip "$PUBLIC_HOST" \
  --qos-port "$QOS_PORT" --host-ports "$HOST_PORTS" --game-dir /game --instances /data/hosts \
  --downloads /downloads --run-host /opt/fangs/server/run-host.sh --seed /data/backend/seed.json --data /data/backend/store.json --log /data/backend/requests.jsonl "$@"
