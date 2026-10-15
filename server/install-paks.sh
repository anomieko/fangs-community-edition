#!/usr/bin/env bash
# Put our patch paks (docs/PATCHING.md) into a copy of the game, and take out the ones put there before.
# Used by run-host.sh (game servers), tools/run/headless.sh (test clients) and tools/play/local.sh (players).
# Usage: install-paks.sh <game-dir> <copy-dir> [pak-dir]
#   pak-dir (default $FANGS_PAKS): every .pak in it goes into <copy-dir>/MOBA/Content/Paks. None, empty or missing:
#   the copy gets no patch pak. The game install itself is never changed.
set -euo pipefail
game=$1; paks=$2/MOBA/Content/Paks; src=${3:-${FANGS_PAKS:-}}
[[ -d $paks ]] || exit 0
for p in "$paks"/*.pak; do   # a pak the game install doesn't have is one of ours
  if [[ -e $p && ! -e $game/MOBA/Content/Paks/$(basename "$p") ]]; then rm -f "$p"; fi
done
if [[ -n $src && -d $src ]]; then
  for p in "$src"/*.pak; do
    if [[ -e $p ]]; then cp "$p" "$paks/"; echo "patch pak: $(basename "$p")"; fi
  done
fi
