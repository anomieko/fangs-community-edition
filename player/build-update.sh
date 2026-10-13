#!/usr/bin/env bash
# Build the auto-update package FangsCE.bat fetches on every start: our player files only (UE4SS +
# FangsBoot, FangsCE\launch.cmd, FangsCE\Engine.ini) - never game files, FangsCE.bat or the player's
# account/join code.
#   player/build-update.sh <server host:port> <out dir>
#   -> <out dir>/FangsCE-Update.zip and FangsCE-Update.txt (version = content hash; the zip is built
#      deterministically, so the version only changes when a file does)
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
server=${1:?usage: build-update.sh <server host:port> <out dir>}; out=${2:?out dir}
stage=$(mktemp -d); trap 'rm -rf "$stage"' EXIT
"$REPO/player/install-player-files.sh" "$stage" >/dev/null
mkdir -p "$stage/FangsCE" "$out"
sed "s/@BACKEND@/$server/g" "$REPO/tools/run/config/Engine.ini.template" > "$stage/FangsCE/Engine.ini"
cp "$REPO/player/windows/launch.cmd" "$stage/FangsCE/"
python3 - "$stage" "$out" <<'PY'
import hashlib, os, sys, zipfile
stage, out = sys.argv[1], sys.argv[2]
files = sorted(os.path.relpath(os.path.join(r, f), stage) for r, _, fs in os.walk(stage) for f in fs)
tmp = os.path.join(out, 'FangsCE-Update.zip.tmp')
with zipfile.ZipFile(tmp, 'w', zipfile.ZIP_DEFLATED) as z:
    for rel in files:
        data = open(os.path.join(stage, rel), 'rb').read()
        if rel.startswith('FangsCE' + os.sep) and rel.endswith(('.cmd', '.ini')):
            data = data.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')   # Windows line endings
        info = zipfile.ZipInfo(rel.replace(os.sep, '/'), date_time=(2023, 2, 15, 0, 0, 0))
        info.compress_type, info.external_attr = zipfile.ZIP_DEFLATED, 0o644 << 16
        z.writestr(info, data)
version = hashlib.sha256(open(tmp, 'rb').read()).hexdigest()[:12]
os.replace(tmp, os.path.join(out, 'FangsCE-Update.zip'))
open(os.path.join(out, 'FangsCE-Update.txt'), 'w').write(version)
print(version)
PY
