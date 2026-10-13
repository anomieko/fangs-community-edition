#!/usr/bin/env bash
# Deploy (or update) a Fangs: Community Edition server on a fresh Debian/Ubuntu x86 machine.
#
#   FANGS_JOIN_CODE=<code> server/deploy.sh <ssh-target> <game-dir> [public-host]
#   e.g. FANGS_JOIN_CODE=$(cat work/joincode) server/deploy.sh admin@203.0.113.10 clients/fangs-2023-02-15-b10554626
# The SSH user needs passwordless sudo (server/harden.sh sets that up).
#
# Uploads the game files (once; later runs only send changes) and the server code, installs
# Docker if needed, starts the server with docker compose and runs the smoke test against it.
# Open in any firewall in front of the server: TCP 8080, UDP 11032, UDP 7777-7786.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/.." && pwd)
target=${1:?usage: deploy.sh <ssh-target> <game-dir> [public-host]}
game=$(realpath "${2:?game dir}")
public=${3:-${target#*@}}
remote=/opt/fangs-ce
code=${FANGS_JOIN_CODE:?set FANGS_JOIN_CODE (players need it; it is baked into the player package)}
ssh_() { ssh -o StrictHostKeyChecking=accept-new "$target" "$@"; }
rsync_() { rsync --rsync-path="sudo rsync" "$@"; }

echo "==> preparing $target"
ssh_ 'set -e; export DEBIAN_FRONTEND=noninteractive
      command -v docker >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq docker.io docker-cli docker-compose rsync >/dev/null; }
      command -v rsync >/dev/null || sudo apt-get install -y -qq rsync >/dev/null; sudo systemctl enable --now docker >/dev/null 2>&1 || true
      sudo mkdir -p '"$remote"'/game '"$remote"'/repo'

echo "==> uploading game files (first time ~14 GB; later runs only send changes)"
rsync_ -a --delete --info=progress2 --exclude 'MOBA/Saved/' \
  "$game/" "$target:$remote/game/"

echo "==> uploading server code"
ue4ss_zip=$REPO/third_party/ue4ss/dl/UE4SS_v3.0.1-1170-g9e7fed53.zip   # see server/Dockerfile
[[ -f $ue4ss_zip ]] || { echo "missing $ue4ss_zip (UE4SS v3.0.1-1170-g9e7fed53)" >&2; exit 1; }
cp "$ue4ss_zip" "$REPO/server/ue4ss.zip"
rsync_ -a --delete --relative \
  "$REPO/./backend/fangs_backend.py" "$REPO/./backend/hosts.py" "$REPO/./backend/matchmaker.py" "$REPO/./backend/seed/make_seed.py" \
  "$REPO/./backend/seed/augments-alpha7.json" "$REPO/./backend/seed/augments-feb2023.json" \
  "$REPO/./server/" "$REPO/./tools/ue4ss/" "$REPO/./tools/run/config/" "$REPO/./player/" "$REPO/./.dockerignore" \
  "$target:$remote/repo/"

# never restart the server under people's feet: a restart ends every lobby and match
if [[ -z ${FANGS_DEPLOY_FORCE:-} ]]; then
  busy=$(ssh_ "sudo docker exec server-fangs-1 sh -c 'cat /data/hosts/host-*/MOBA/Binaries/Win64/fangshost_status.json 2>/dev/null' 2>/dev/null" \
         | grep -o '"players": [1-9][0-9]*' | awk '{n += $2} END {print n + 0}')
  if [[ ${busy:-0} -gt 0 ]]; then
    echo "!! $busy player(s) are in a lobby or match right now; restarting the server would end their games." >&2
    echo "!! Deploy again when they're done, or force it with FANGS_DEPLOY_FORCE=1." >&2
    exit 1
  fi
fi

echo "==> building and starting (public address: $public)"
# settings for compose live in a root-only .env next to the compose file (also used on reboot/updates)
printf 'GAME_DIR=%s\nPUBLIC_HOST=%s\nFANGS_JOIN_CODE=%s\nHOST_PORTS=%s\n' "$remote/game" "$public" "$code" "${HOST_PORTS:-7777-7778}" \
  | ssh_ "sudo install -m 600 /dev/stdin $remote/repo/server/.env"
ssh_ "set -e; cd $remote/repo/server
      compose() { if sudo docker compose version >/dev/null 2>&1; then sudo docker compose \"\$@\"; else sudo docker-compose \"\$@\"; fi; }
      compose up -d --build
      for i in \$(seq 1 60); do compose logs fangs 2>&1 | grep -q 'fangs backend on' && break; sleep 3; done
      compose logs --tail 3 fangs"

echo "==> launcher and signed file list (built and signed here; the signing key never leaves this machine)"
go=$REPO/work/toolchains/go/bin/go; [[ -x $go ]] || go=$(command -v go || true)
[[ -n $go ]] || { echo "need a Go toolchain (work/toolchains/go or go on PATH) for the launcher" >&2; exit 1; }
export GOCACHE=$REPO/work/toolchains/gocache
dist=$REPO/work/dist/$public; key=$REPO/work/signing/fangsce-update.key
sign=$(mktemp -d)/sign; (cd "$REPO/launcher" && "$go" build -o "$sign" ./sign)
if [[ ! -f $key ]]; then
  mkdir -p "$(dirname "$key")"; "$sign" keygen "$key" >/dev/null
  echo "   NEW update signing key: $key - back it up somewhere safe (password manager). Without it you can't"
  echo "   ship updates to existing launchers; if it leaks, someone could. Never put it on the server."
fi
pub=$("$sign" pub "$key")
mkdir -p "$dist"; rm -rf "$dist/overlay" "$dist/FangsCE.exe"
(cd "$REPO/launcher" && GOOS=windows GOARCH=amd64 "$go" build -trimpath -ldflags "-s -w -X main.server=$public:8080 \
   -X main.joinCode=$code -X main.pubKey=$pub -X main.version=$(git -C "$REPO" rev-parse --short HEAD)" -o "$dist/FangsCE.exe" .)
"$REPO/player/install-player-files.sh" "$dist/overlay" >/dev/null
mkdir -p "$dist/overlay/FangsCE"
sed "s/@BACKEND@/$public:8080/g" "$REPO/tools/run/config/Engine.ini.template" > "$dist/overlay/FangsCE/Engine.ini"
python3 "$REPO/player/build-manifest.py" "$game" "$dist" "$(tr -d '\r\n' < "$game/MOBA/Content/Data/version.txt")"
"$sign" sign "$key" "$dist/manifest.json"
"$sign" verify "$pub" "$dist/manifest.json" | sed 's/^/   /'
rm -rf "$(dirname "$sign")"
# only what the launcher needs; --delete drops older packages (zips for the old .bat launcher: unsigned)
ssh_ "sudo mkdir -p $remote/repo/server/downloads"
rsync_ -a --delete --exclude .hashcache.json "$dist/" "$target:$remote/repo/server/downloads/"

echo "==> smoke test"
py=python3; [[ -x $REPO/backend/.venv/bin/python ]] && py=$REPO/backend/.venv/bin/python
"$py" "$REPO/tools/run/smoke_server.py" "$public:8080" --join-code "$code"
echo "==> server is up at $public:8080 (full client zip: ssh $target 'cd $remote/repo/server && sudo ./build-client.sh')"
