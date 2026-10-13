#!/usr/bin/env bash
# Build the full Windows client zip ON THE SERVER, into the downloads folder the backend serves at
# http://<PUBLIC_HOST>:8080/download/<join code>/FangsCE-Client.zip
# Run from the server's repo/server directory (uses the server's .env):  sudo ./build-client.sh
set -euo pipefail
cd "$(dirname "$0")"; set -a; . ./.env; set +a
mkdir -p "${DOWNLOADS_DIR:-./downloads}"; out=$(realpath "${DOWNLOADS_DIR:-./downloads}")
docker run --rm --user 0 -e FANGS_JOIN_CODE="$FANGS_JOIN_CODE" -e OUT=/out/FangsCE-Client.zip.tmp -e STAGE_DIR=/tmp/stage \
  -v "$GAME_DIR":/game:ro -v "$out":/out --entrypoint bash fangs-ce-server \
  -c "player/build-full-client.sh '$PUBLIC_HOST:8080' /game 'FANGS 2023-02-15 (build 10554626)'"
mv "$out/FangsCE-Client.zip.tmp" "$out/FangsCE-Client.zip"
echo "download link: http://$PUBLIC_HOST:8080/download/$FANGS_JOIN_CODE/FangsCE-Client.zip"
