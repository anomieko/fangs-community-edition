#!/usr/bin/env bash
# Wylde's Fan the Hammers at the start of a match (the user: "the first 2 or 3 fan the hammers of a game are shooting
# with much more bullets than they are supposed to"; docs/recon/community-build-modes.md): tools/run/test_patch.sh with
# bob as Wylde, then tools/run/test_fth.pre and .steps. The game server logs his loaded bullets, his magazine size and
# the Fan the Hammers bullets each cast spawns (fth.log, every 50 ms when they change) and every call that loads his gun,
# from the augment phase with its dummies through round 1 into round 2; bob's client logs his bullets as it sees them.
# Fan the Hammers: Shift pressed as a player does, or the ability started directly (test_fth.steps).
# Usage: [PATCHES="<patches>" | PATCHES=none] [FTH_ROUND1=0] [RUN=<name>] tools/run/test_fth.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-fth}
ALL=$(grep -l '"enabled": true' tools/patch/patches/*.json | xargs -n1 basename | sed 's/\.json$//' | tr '\n' ' ')
RUN=$R PATCHES=${PATCHES:-$ALL} CHECK=${CHECK:-$ALL} HERO_A=${HERO_A:-WoodenSword} HERO_B=Gunslinger SKIP_CC=1 CUE_A= \
  PRE_STEPS=$PWD/tools/run/test_fth.pre STEPS=$PWD/tools/run/test_fth.steps DURATION=${DURATION:-600} tools/run/test_patch.sh
echo "== bob's ammo on the game server (fth.log)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fth.log 2>/dev/null
echo "== bob's ammo on his own client (fth.log)"
cat work/run/$R-bob/MOBA/Binaries/Win64/fth.log 2>/dev/null
echo "== FangsHost on Wylde"
grep -h 'wylde\|always-on\|presets' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangshost.log 2>/dev/null | cut -c1-200
