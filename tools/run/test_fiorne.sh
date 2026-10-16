#!/usr/bin/env bash
# Fiorne restore test (tools/patch/patches/fiorne.json, docs/recon/fiorne.md): tools/run/test_patch.sh with bob as
# Fiorne (alice, Somnia, casts on her first), then tools/run/test_fiorne.steps: health, Bunny Stacks, a Space chain
# with her speed every 50 ms, and her stack system granted again mid-round.
# Usage: [PATCHES="fiorne" | PATCHES=none] [RUN=<name>] tools/run/test_fiorne.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-fiorne}
RUN=$R PATCHES=${PATCHES:-fiorne} CHECK=${CHECK:-fiorne} HERO_B=Lancer CAST_B=Lancer_Skill1 LMB_B=Lancer_LMB CUE_A= \
  STEPS=$PWD/tools/run/test_fiorne.steps DURATION=${DURATION:-520} tools/run/test_patch.sh
echo "== bob's Space chains (client)"
cat work/run/$R-bob/MOBA/Binaries/Win64/chain.log 2>/dev/null
echo "== bob's speed and Bunny Stacks during the first chain (game server, every 50 ms)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/track.log 2>/dev/null
