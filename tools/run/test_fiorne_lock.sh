#!/usr/bin/env bash
# Fiorne's Bunny Stacks and the base lock (tools/patch/patches/fiorne-stacks.json, docs/recon/fiorne.md): her stack
# system is granted again while she is protected in her base (round 1's augment phase), then checked once the round
# is on. Without fiorne-stacks the game refuses that start (0 stacks all match); with it, the stacks are there.
# Usage: [PATCHES="<patches>"] [RUN=<name>] tools/run/test_fiorne_lock.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-fiorne-lock}
RUN=$R PATCHES=${PATCHES:-base-blockers fiorne fiorne-stacks} CHECK=${CHECK:-} HERO_A=Lancer HERO_B=Gunslinger SKIP_CC=1 CUE_A= \
  PRE_STEPS=$PWD/tools/run/test_fiorne_lock.pre STEPS=$PWD/tools/run/test_fiorne_lock.steps DURATION=${DURATION:-460} \
  tools/run/test_patch.sh
echo "== passives (game server)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/passives.log 2>/dev/null
