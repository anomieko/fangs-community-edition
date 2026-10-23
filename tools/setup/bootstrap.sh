#!/usr/bin/env bash
# Prepares a clone of this repository to build and deploy your own Fangs: Community Edition server
# (docs/SELF-HOSTING.md). Run it from the machine you deploy from (Linux, or WSL2 on Windows).
#
#   tools/setup/bootstrap.sh [--check] [<game dir>]      (game dir default: clients/fangs-2023-02-15-b10554626)
#
# It checks the tools, verifies your game files against clients/<build>.sha256, fetches UE4SS and UAssetAPI at the
# pinned versions (checked by SHA-256 / commit), recovers the game pak's AES key from your own copy of the game into
# work/re/, makes a join code (work/joincode) and turns on the pre-commit privacy check. Then it builds the patch pak
# once to prove the tool chain, and prints the next steps. Nothing it makes is ever committed or sent anywhere.
# --check: only report (exit 1 while anything required is missing). Safe to run again at any time.
set -uo pipefail
cd "$(dirname "$0")/../.."
REPO=$PWD
CHECK=; [[ ${1:-} == --check ]] && { CHECK=1; shift; }
GAME=${1:-clients/fangs-2023-02-15-b10554626}
BUILD=Playtest021523v1_v0_0_02
HASHES=clients/fangs-2023-02-15-b10554626.sha256
MIRROR=https://github.com/anomieko/fangs-community-edition/releases/download/third-party
UE4SS=UE4SS_v3.0.1-1170-g9e7fed53.zip
UE4SS_SHA=c07a0ece72ccb381a3ca97b602071fe919eb6def052f4ff183ffc524d8b18933
UE4SS_URLS=("https://github.com/UE4SS-RE/RE-UE4SS/releases/download/experimental/$UE4SS" "$MIRROR/$UE4SS")
UASSETAPI_COMMIT=3228c1e86261aa08131f7ec0ff1a395f5d0b2a84
UASSETAPI_ZIP=UAssetAPI-3228c1e.zip
UASSETAPI_ZIP_SHA=3c04301579487c85fb40366a500d7c27736aad1072d9aedfac9fa87fa2993399
KEY=work/re/aeskey-2023-02-15.txt

missing=0
ok()   { printf '  ok       %s\n' "$*"; }
need() { printf '  MISSING  %s\n' "$*"; missing=1; }
note() { printf '  note     %s\n' "$*"; }
section() { printf '\n== %s\n' "$*"; }
sha() { sha256sum "$1" 2>/dev/null | cut -c1-64; }
fetch() {   # fetch <file> <sha256> <url>...: the first URL whose download has that SHA-256
  local out=$1 want=$2 url; shift 2
  mkdir -p "$(dirname "$out")"
  for url in "$@"; do
    curl -fsSL --retry 2 -o "$out.part" "$url" 2>/dev/null && [[ $(sha "$out.part") == "$want" ]] \
      && { mv "$out.part" "$out"; return 0; }
    rm -f "$out.part"
  done
  return 1
}

section "tools on this machine"
for t in git curl rsync ssh sha256sum unzip; do
  command -v $t >/dev/null && ok "$t" || need "$t (Debian/Ubuntu: sudo apt install $t)"
done
if python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then ok "python3 $(python3 -V | cut -d' ' -f2)"
else need "python3 3.10 or newer (sudo apt install python3)"; fi
if python3 -I -c 'import Crypto' 2>/dev/null || python3 -I -c 'import cryptography' 2>/dev/null; then ok "python AES (pycryptodome or cryptography)"
else need "python AES library for the game's encrypted pak (Debian/Ubuntu: sudo apt install python3-pycryptodome)"; fi
if python3 -I -c 'import pefile' 2>/dev/null; then ok "python pefile (finds the pak key in the game's exe)"
else need "python pefile (Debian/Ubuntu: sudo apt install python3-pefile; Arch: sudo pacman -S python-pefile)"; fi
if [[ $(dotnet --list-sdks 2>/dev/null) == *"10."* ]]; then ok ".NET SDK 10"
else need ".NET 10 SDK, for the patch pak tool (https://dotnet.microsoft.com/download/dotnet/10.0; Ubuntu: sudo apt install dotnet-sdk-10.0)"; fi
go=$REPO/work/toolchains/go/bin/go; [[ -x $go ]] || go=$(command -v go || true)
if [[ -n $go ]] && "$go" version 2>/dev/null | grep -qE 'go1\.(2[7-9]|[3-9][0-9])'; then ok "Go ($("$go" version | cut -d' ' -f3))"
else need "Go 1.27 or newer, for the launcher (https://go.dev/dl/; or unpack it into work/toolchains/go)"; fi
command -v docker >/dev/null && ok "docker (optional: run the server on this machine)" \
  || note "docker not found (optional: only to run the server on this machine instead of a VPS)"

section "game files ($GAME)"
if [[ ! -f $GAME/MOBA/Content/Data/version.txt ]]; then
  need "the FANGS game files (15 Feb 2023, build 10554626) in $GAME: see docs/SELF-HOSTING.md, \"Get the game\""
elif [[ $(tr -d '\r\n' < "$GAME/MOBA/Content/Data/version.txt") != "$BUILD" ]]; then
  need "$GAME is build '$(tr -d '\r\n' < "$GAME/MOBA/Content/Data/version.txt")', not $BUILD (15 Feb 2023)"
else
  echo "  checking $(wc -l < "$HASHES") files against $HASHES (13 GB, about a minute)..."
  bad=$(cd "$GAME" && sha256sum --quiet -c "$REPO/$HASHES" 2>/dev/null | sed 's/: FAILED.*//;s/^\.\///')
  if [[ -z $bad ]]; then ok "all files match build 10554626"
  elif [[ $bad == FANGS.exe ]]; then ok "all files match (FANGS.exe differs: normal in a player's install, where it is our launcher)"
  else need "files that don't match (re-download them; a player's install: see docs/SELF-HOSTING.md): $(echo $bad | cut -c1-300)"; fi
  extra=$(cd "$GAME" && find . -type f ! -path './MOBA/Saved/*' | sed 's/^\.\///' | sort \
          | comm -23 - <(sed 's/^[0-9a-f]* *\.\///' "$REPO/$HASHES" | sort))
  [[ -z $extra ]] && ok "no extra files" \
    || need "extra files, e.g. left by our launcher in a player's install (delete them): $(echo $extra | cut -c1-300)"
fi

section "UE4SS (pinned: $UE4SS)"
zip=third_party/ue4ss/dl/$UE4SS
if [[ $(sha "$zip") == "$UE4SS_SHA" ]]; then ok "$zip"
elif [[ -n $CHECK ]]; then need "$zip (run without --check to download it)"
elif fetch "$zip" "$UE4SS_SHA" "${UE4SS_URLS[@]}"; then ok "downloaded $zip (SHA-256 checked)"
else need "$zip: no download matched SHA-256 $UE4SS_SHA (tried ${UE4SS_URLS[*]})"; fi
if [[ $(sha "$zip") == "$UE4SS_SHA" && ! -f third_party/ue4ss/dist/dwmapi.dll && -z $CHECK ]]; then
  mkdir -p third_party/ue4ss/dist && unzip -q -o "$zip" -d third_party/ue4ss/dist && ok "unpacked into third_party/ue4ss/dist (local tests)"
fi

section "UAssetAPI (pinned: commit ${UASSETAPI_COMMIT:0:7})"
api=third_party/UAssetAPI
have=$(git -C "$api" rev-parse HEAD 2>/dev/null || cat "$api/.fangs-commit" 2>/dev/null || true)
if [[ $have == "$UASSETAPI_COMMIT" ]]; then ok "$api"
elif [[ -n $CHECK ]]; then need "$api at commit $UASSETAPI_COMMIT (run without --check to get it)"
elif [[ -e $api ]]; then need "$api exists at another version ($have): move it away, then run this again"
else
  if git clone -q --filter=blob:none https://github.com/atenfyr/UAssetAPI "$api" 2>/dev/null \
     && git -C "$api" checkout -q "$UASSETAPI_COMMIT" 2>/dev/null; then ok "cloned $api at ${UASSETAPI_COMMIT:0:7}"
  else
    rm -rf "$api"; tmp=$(mktemp -d)
    if fetch "$tmp/$UASSETAPI_ZIP" "$UASSETAPI_ZIP_SHA" "$MIRROR/$UASSETAPI_ZIP"; then
      unzip -q "$tmp/$UASSETAPI_ZIP" -d third_party && echo "$UASSETAPI_COMMIT" > "$api/.fangs-commit" && ok "$api from the mirror"
    else need "$api: neither github.com/atenfyr/UAssetAPI nor the mirror ($MIRROR/$UASSETAPI_ZIP) worked"; fi
    rm -rf "$tmp"
  fi
fi

section "the game pak's AES key ($KEY, local only)"
pak=$GAME/MOBA/Content/Paks/MOBA-WindowsNoEditor.pak
exe=$GAME/MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe
if [[ -s $KEY ]]; then ok "$KEY"
elif [[ -n $CHECK ]]; then need "$KEY (run without --check to recover it from your game files)"
elif [[ -f $pak && -f $exe ]]; then
  echo "  recovering it from your MOBA-Win64-Shipping.exe (a few minutes)..."
  mkdir -p work/re
  if (umask 077; python3 -I tools/pak/findkey_code.py "$exe" "$pak" > "$KEY.part" 2>/dev/null) && grep -qE '^0x[0-9A-F]{64}$' "$KEY.part"; then
    mv "$KEY.part" "$KEY"; ok "recovered into $KEY (never commit or share it)"
  else rm -f "$KEY.part"; need "$KEY: no key found in $exe (is it the 15 Feb 2023 build?)"; fi
else need "$KEY: needs the game files first"; fi

section "your server's secrets (local only, never committed)"
if [[ -s work/joincode ]]; then ok "work/joincode"
elif [[ -n $CHECK ]]; then need "work/joincode (run without --check to make one)"
else mkdir -p work && (umask 077; python3 -I -c 'import secrets; print(secrets.token_urlsafe(9))' > work/joincode) && ok "made work/joincode"; fi
[[ -s work/signing/fangsce-update.key ]] && ok "work/signing/fangsce-update.key (back it up privately)" \
  || note "work/signing/fangsce-update.key: made by your first deploy; back it up privately then"
if [[ $(git config core.hooksPath) == tools/setup/hooks ]]; then ok "pre-commit privacy check (tools/setup/leakcheck.py)"
elif [[ -n $CHECK ]]; then note "pre-commit privacy check is off (run without --check to turn it on)"
else git config core.hooksPath tools/setup/hooks && ok "turned on the pre-commit privacy check (tools/setup/leakcheck.py)"; fi
clip=work/media/shotgun-clip/snd-shotgun_blast.mp3
[[ -f $clip ]] && ok "$clip (optional)" \
  || note "optional: $clip (Ishir's ult sound; without it that one patch is left out): docs/recon/community-build-ishir.md"

if [[ $missing == 0 && -z $CHECK ]]; then
  section "test build of the patch pak (proves the tool chain)"
  if OUT=$REPO/work/patch/bootstrap-test.pak tools/patch/build.sh "$GAME" > work/patch-bootstrap.log 2>&1; then
    ok "$(grep '^built' work/patch-bootstrap.log | sed "s|$REPO/||" | cut -c1-160)"
  else need "the patch pak build failed: see work/patch-bootstrap.log"; fi
fi

section "result"
if [[ $missing != 0 ]]; then
  echo "  Something is missing (above). Fix it and run tools/setup/bootstrap.sh again."
  exit 1
fi
cat <<EOF
  Ready. Next (docs/SELF-HOSTING.md, from step 4):
    1. a Debian 13 x86-64 VPS with 8 GB RAM; harden it: server/harden.sh (docs/SERVER.md, "First-time setup")
    2. deploy:   FANGS_JOIN_CODE=\$(cat work/joincode) server/deploy.sh <admin>@<server> $GAME <server>
    3. players: your server's own launcher, http://<server>:8080/download/\$(cat work/joincode)/FangsCE.exe (a private
       link: it holds the join code), or your public build plus an invite code (docs/SELF-HOSTING.md, step 6)
EOF
