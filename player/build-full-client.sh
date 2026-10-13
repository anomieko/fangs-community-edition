#!/usr/bin/env bash
# Build a ready-to-play Windows client zip: game files + Fangs CE player files + launcher.
# Friends unzip it anywhere and double-click FangsCE.bat.
#
#   player/build-full-client.sh <server host:port> <game-dir> [build label]
#   -> dist/FangsCE-Client.zip  (~13 GB; the game data is encrypted, so it barely compresses)
#
# Only share this with people who should have it; it contains the game files.
set -euo pipefail
# Env: FANGS_JOIN_CODE = the server's community join code (written to FangsCE/joincode.txt)
REPO=$(cd "$(dirname "$0")/.." && pwd)
server=${1:?usage: build-full-client.sh <server host:port> <game-dir> [build label]}
game=$(realpath "${2:?game dir}"); build=${3:-$(basename "$game")}
top="FANGS Community Edition"
stage=${STAGE_DIR:-$REPO/dist/client-stage}; out=${OUT:-$REPO/dist/FangsCE-Client.zip}
rm -rf "$stage" "$out"; mkdir -p "$stage"
# cheap staging: reflink, else hard links, else a symlink farm (zip reads through the links)
cp -a --reflink=always "$game" "$stage/$top" 2>/dev/null || { rm -rf "$stage/$top"; cp -al "$game" "$stage/$top" 2>/dev/null; } \
  || { rm -rf "$stage/$top"; cp -as "$game" "$stage/$top"; }
rm -rf "$stage/$top/MOBA/Saved"
"$REPO/player/install-player-files.sh" "$stage/$top" >/dev/null
mkdir -p "$stage/$top/FangsCE"
sed "s/@BACKEND@/$server/g" "$REPO/tools/run/config/Engine.ini.template" > "$stage/$top/FangsCE/Engine.ini"
[[ -n ${FANGS_JOIN_CODE:-} ]] && printf '%s' "$FANGS_JOIN_CODE" > "$stage/$top/FangsCE/joincode.txt"
cp "$REPO/player/windows/FangsCE.bat" "$stage/$top/"
cp "$REPO/player/windows/launch.cmd" "$stage/$top/FangsCE/"
# auto-update: FangsCE.bat fetches FangsCE-Update.* from the server's download folder (behind the join code)
printf 'http://%s/download/%s/' "$server" "${FANGS_JOIN_CODE:-}" > "$stage/$top/FangsCE/update-url.txt"
"$REPO/player/build-update.sh" "$server" "$stage/update" > /dev/null
cp "$stage/update/FangsCE-Update.txt" "$stage/$top/FangsCE/version.txt"; rm -rf "$stage/update"
sed -e "s/@SERVER@/$server/" -e "s/@BUILD@/$build/" \
    -e 's/^1\. You need FANGS installed.*$/1. Nothing else to install - this folder already contains the game./' \
    -e 's/^2\. Extract this zip INTO your FANGS game folder.*$/2. Extract this zip anywhere (e.g. C:\\Games). Keep the folder together./' \
    -e '/^   Allow it to merge folders.$/d' \
    -e 's/This package contains no game files\./These game files are shared privately and free of charge -\nplease do not sell or re-upload them./' \
    "$REPO/player/windows/README.txt" > "$stage/$top/FangsCE-README.txt"
python3 - "$stage" "$out" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', allowZip64=True) as z:
    for root, _, files in os.walk(stage):
        for f in sorted(files):
            p = os.path.join(root, f); rel = os.path.relpath(p, stage)
            if f in ('FangsCE.bat', 'FangsCE-README.txt') or rel.endswith(('FangsCE/Engine.ini', 'FangsCE/launch.cmd')):
                data = open(p, 'rb').read().replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
                z.writestr(rel, data, compress_type=zipfile.ZIP_DEFLATED)
            else:  # store big/encrypted files as-is (fast, barely compressible anyway)
                big = os.path.getsize(p) > 8 << 20
                z.write(p, rel, compress_type=zipfile.ZIP_STORED if big else zipfile.ZIP_DEFLATED)
PY
rm -rf "$stage"
echo "built $out ($(du -h "$out" | cut -f1))"
