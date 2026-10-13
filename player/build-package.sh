#!/usr/bin/env bash
# Build the Windows player zip for a given server.
# Usage: player/build-package.sh <server host:port> [build label]   -> dist/FangsCE-Player.zip
set -euo pipefail
# Env: FANGS_JOIN_CODE = the server's community join code (written to FangsCE/joincode.txt)
REPO=$(cd "$(dirname "$0")/.." && pwd)
server=${1:?usage: build-package.sh <server host:port> [build label]}; build=${2:-see project page}
stage=$REPO/dist/stage; out=$REPO/dist/FangsCE-Player.zip
rm -rf "$stage" "$out"; mkdir -p "$stage/FangsCE"
"$REPO/player/install-player-files.sh" "$stage" >/dev/null
sed "s/@BACKEND@/$server/g" "$REPO/tools/run/config/Engine.ini.template" > "$stage/FangsCE/Engine.ini"
[[ -n ${FANGS_JOIN_CODE:-} ]] && printf '%s' "$FANGS_JOIN_CODE" > "$stage/FangsCE/joincode.txt"
cp "$REPO/player/windows/FangsCE.bat" "$stage/"
sed -e "s/@SERVER@/$server/" -e "s/@BUILD@/$build/" "$REPO/player/windows/README.txt" > "$stage/FangsCE-README.txt"
python3 - "$stage" "$out" <<'PY'
import os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED) as z:
    for root, _, files in os.walk(stage):
        for f in files:
            p = os.path.join(root, f); rel = os.path.relpath(p, stage)
            data = open(p, 'rb').read()
            if f.endswith(('.bat', '.txt', '.ini')) and not rel.startswith('MOBA'):
                data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')   # Windows line endings
            z.writestr(rel, data)
PY
rm -rf "$stage"
echo "built $out ($(du -h "$out" | cut -f1))"
