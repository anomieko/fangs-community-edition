#!/usr/bin/env bash
# Launcher download test: a fake game with big files, the real backend and player/build-manifest.py, a signed
# file list and a Linux build of the launcher, in a private network namespace with its own folders
# (work/run/download; no game files, backend data or play session touched). Checks that the game arrives intact:
#   1. fresh install, big files in gzipped pieces;
#   2. resume: the pak's .part has its first 40 MiB with a damaged byte (only the bad and missing pieces come again);
#   3. a server without pieces (an older deploy): ranges of the whole file.
# Usage: tools/run/test_download.sh
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd); T=$REPO/work/run/download
go=$REPO/work/toolchains/go/bin/go; [[ -x $go ]] || go=go
rm -rf "$T"; mkdir -p "$T/game/MOBA/Binaries/Win64" "$T/game/MOBA/Content/Paks" "$T/game/MOBA/Content/Data" \
  "$T/dist/overlay/FangsCE" "$T/home"

# fake game: 70 MiB pak (40 MiB that compresses, 30 random: pieces of 32, 32 and 6 MiB), a 6 MiB random file
echo test-build > "$T/game/MOBA/Content/Data/version.txt"
head -c 100000 /dev/urandom > "$T/game/MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe"
{ head -c $((40 << 20)) < <(yes 'fangs community edition 0123456789'); head -c $((30 << 20)) /dev/urandom; } \
  > "$T/game/MOBA/Content/Paks/MOBA-WindowsNoEditor.pak"
head -c $((6 << 20)) /dev/urandom > "$T/game/MOBA/Content/Paks/small.pak"
echo '[test]' > "$T/dist/overlay/FangsCE/Engine.ini"

"$go" build -C "$REPO/launcher" -o "$T/sign" ./sign
"$T/sign" keygen "$T/key" >/dev/null; pub=$("$T/sign" pub "$T/key")
"$go" build -C "$REPO/launcher" -o "$T/FangsCE" \
  -ldflags "-X main.server=127.0.0.1:18080 -X main.joinCode=testcode -X main.pubKey=$pub" .
python3 -I "$REPO/player/build-manifest.py" "$T/game" "$T/dist" test-build
"$T/sign" sign "$T/key" "$T/dist/manifest.json"

cat > "$T/inner.sh" <<'IN'
set -euo pipefail
ip link set lo up
"$REPO/backend/.venv/bin/python" -u "$REPO/backend/fangs_backend.py" --port 18080 --qos-port 18081 \
  --game-dir "$T/game" --downloads "$T/dist" --join-code testcode --host-standby 0 --instances "$T/hosts" \
  --data "$T/store.json" --log "$T/backend.jsonl" > "$T/backend.log" 2>&1 &
trap 'kill %1 2>/dev/null; wait' EXIT
for _ in $(seq 50); do curl -sf -o /dev/null http://127.0.0.1:18080/download/testcode/manifest.json && break; sleep 0.2; done
launcher() {   # first run answers the install-dir and name questions
  printf '%s\ntester\n' "$T/install" | HOME=$T/home XDG_CONFIG_HOME=$T/home/.config FANGSCE_NO_LAUNCH=1 "$T/FangsCE" \
    | tr '\r' '\n' | grep -v '^\s*$' | tail -4 | sed 's/^/     /'
}
same() {
  if diff -rq -x .fangsce -x FangsCE -x Saved "$T/game" "$T/install" && [[ -z $(find "$T/install" -name '*.part') ]]; then
    echo "   ok: $1"
  else echo "!! FAIL: $1"; exit 1; fi
}
pak=MOBA/Content/Paks/MOBA-WindowsNoEditor.pak

echo "== 1. fresh install"
launcher; same "fresh install"

echo "== 2. resume"
head -c $((40 << 20)) "$T/install/$pak" > "$T/install/$pak.part"; rm "$T/install/$pak"
printf 'X' | dd of="$T/install/$pak.part" bs=1 seek=1000 conv=notrunc status=none
launcher; same "resumed install"

echo "== 3. server without pieces"
mkdir "$T/chunks.off"; mv "$T/dist/chunks/"* "$T/chunks.off/"
rm "$T/install/$pak" "$T/install/MOBA/Content/Paks/small.pak"
launcher; same "install from ranges"
IN
env -u WAYLAND_DISPLAY -u DISPLAY REPO="$REPO" T="$T" unshare -rnm bash "$T/inner.sh"
echo "== all download checks passed"
