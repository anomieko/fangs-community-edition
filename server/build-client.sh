#!/usr/bin/env bash
# Build the player downloads ON THE SERVER, into the folder the backend serves behind the join code
# (http://<PUBLIC_HOST>:8080/download/<join code>/<file>). Run from the server's repo/server directory:
#   sudo ./build-client.sh          full Windows client zip (FangsCE-Client.zip, ~14 GB) + update package
#   sudo ./build-client.sh update   only the update package FangsCE.bat fetches (FangsCE-Update.zip/.txt)
set -euo pipefail
cd "$(dirname "$0")"; set -a; . ./.env; set +a
mkdir -p "${DOWNLOADS_DIR:-./downloads}"; out=$(realpath "${DOWNLOADS_DIR:-./downloads}")
run() { docker run --rm --user 0 -e FANGS_JOIN_CODE="$FANGS_JOIN_CODE" -v "$GAME_DIR":/game:ro -v "$out":/out \
          --entrypoint bash fangs-ce-server -c "$1"; }
run "player/build-update.sh '$PUBLIC_HOST:8080' /out" | sed 's/^/update package version: /'
[[ ${1:-} == update ]] && exit 0
run "OUT=/out/FangsCE-Client.zip.tmp STAGE_DIR=/tmp/stage player/build-full-client.sh '$PUBLIC_HOST:8080' /game 'FANGS 2023-02-15 (build 10554626)'"
mv "$out/FangsCE-Client.zip.tmp" "$out/FangsCE-Client.zip"
echo "download link: http://$PUBLIC_HOST:8080/download/$FANGS_JOIN_CODE/FangsCE-Client.zip"
