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
      command -v docker >/dev/null || { sudo apt-get update -qq && sudo apt-get install -y -qq docker.io docker-compose rsync >/dev/null; }
      command -v rsync >/dev/null || sudo apt-get install -y -qq rsync >/dev/null; sudo systemctl enable --now docker >/dev/null 2>&1 || true
      sudo mkdir -p '"$remote"'/game '"$remote"'/repo'

echo "==> uploading game files (first time ~13 GB; movies are skipped, servers do not need them)"
rsync_ -a --delete --info=progress2 --exclude 'MOBA/Content/Movies/' --exclude 'MOBA/Saved/' \
  "$game/" "$target:$remote/game/"

echo "==> uploading server code"
rsync_ -a --delete --relative \
  "$REPO/./backend/fangs_backend.py" "$REPO/./backend/hosts.py" "$REPO/./backend/seed/make_seed.py" \
  "$REPO/./server/" "$REPO/./tools/ue4ss/" "$REPO/./tools/run/config/" "$REPO/./.dockerignore" \
  "$target:$remote/repo/"

echo "==> building and starting (public address: $public)"
# settings for compose live in a root-only .env next to the compose file (also used on reboot/updates)
printf 'GAME_DIR=%s\nPUBLIC_HOST=%s\nFANGS_JOIN_CODE=%s\nHOST_PORTS=%s\n' "$remote/game" "$public" "$code" "${HOST_PORTS:-7777-7778}" \
  | ssh_ "sudo install -m 600 /dev/stdin $remote/repo/server/.env"
ssh_ "set -e; cd $remote/repo/server
      compose() { if sudo docker compose version >/dev/null 2>&1; then sudo docker compose \"\$@\"; else sudo docker-compose \"\$@\"; fi; }
      compose up -d --build
      for i in \$(seq 1 60); do compose logs fangs 2>&1 | grep -q 'fangs backend on' && break; sleep 3; done
      compose logs --tail 3 fangs"

echo "==> smoke test"
py=python3; [[ -x $REPO/backend/.venv/bin/python ]] && py=$REPO/backend/.venv/bin/python
"$py" "$REPO/tools/run/smoke_server.py" "$public:8080" --join-code "$code"
echo "==> server is up at $public:8080 — build the player package with: player/build-package.sh $public:8080"
