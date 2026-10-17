#!/usr/bin/env bash
# Passives that stop working for a whole match (Wylde 0 ammo, Fiorne 0 Bunny Stacks; docs/recon/community-build-passives.md):
# tools/run/test_patch.sh with alice and bob on two heroes, then tools/run/test_passives.steps: the game server logs
# each hero's passive and always-running helpers (running or not, spec handle), ammo / stacks and the tags that block
# their start, while a hero locks in augments mid-shot and while a hero is dead at a round change (passives.log).
# Usage: [PATCHES=... | PATCHES=none] [RUN=<name>] [HERO_A=Lancer HERO_B=Gunslinger] [ITEMS_WAIT=40 ROUND_GAP=40 DEATH_WAIT=10] [ITEM_A=<path> ITEM_B=<path>]
#        tools/run/test_passives.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-passives}
HA=${HERO_A:-Lancer}; HB=${HERO_B:-Gunslinger}
RUN=$R PATCHES=${PATCHES:-none} CHECK=${CHECK:-fiorne} HERO_A=$HA HERO_B=$HB CAST_A=${HA}_LMB CAST_B=${HB}_LMB \
  ULT_A=${HA}_LMB LMB_B=${HB}_LMB CUE_A= STEPS=$PWD/tools/run/test_passives.steps DURATION=${DURATION:-700} \
  tools/run/test_patch.sh
echo "== passives (game server)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/passives.log 2>/dev/null
