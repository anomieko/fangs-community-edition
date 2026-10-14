#!/usr/bin/env bash
# Builds the public launcher for GitHub Releases: nothing baked in but the update-signing public key, so it is
# safe to publish; players paste an invite code (server/invite.sh) on the first start, then it updates itself
# to the server's launcher. Output: work/dist/release/FangsCE.exe. Publish (after testing):
#   gh release create launcher-<version> work/dist/release/FangsCE.exe --title ... --notes ...
# Players' stable link: https://github.com/<owner>/<repo>/releases/latest/download/FangsCE.exe
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
go=$REPO/work/toolchains/go/bin/go; [[ -x $go ]] || go=$(command -v go)
export GOCACHE=$REPO/work/toolchains/gocache
key=$REPO/work/signing/fangsce-update.key
[[ -f $key ]] || { echo "no signing key ($key): deploy once first" >&2; exit 1; }
[[ -z $(git -C "$REPO" status --porcelain -- launcher) ]] || { echo "launcher/ has uncommitted changes" >&2; exit 1; }
out=$REPO/work/dist/release; mkdir -p "$out"
sign=$(mktemp -d)/sign; (cd "$REPO/launcher" && "$go" build -o "$sign" ./sign)
pub=$("$sign" pub "$key"); rm -rf "$(dirname "$sign")"
ver=$(git -C "$REPO" rev-parse --short HEAD)
(cd "$REPO/launcher" && GOOS=windows GOARCH=amd64 "$go" build -trimpath \
   -ldflags "-s -w -X main.pubKey=$pub -X main.version=$ver" -o "$out/FangsCE.exe" .)
echo "built $out/FangsCE.exe (launcher $ver, $(stat -c %s "$out/FangsCE.exe") bytes, sha256 $(sha256sum "$out/FangsCE.exe" | cut -c1-16)...)"
