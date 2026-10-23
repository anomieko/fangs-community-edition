#!/usr/bin/env bash
# Ishir's shotgun sound test (tools/patch/patches/community-ishir.json, docs/recon/community-build-ishir.md):
# tools/run/test_patch.sh with alice as Ishir, then tools/run/test_ishir.steps: both clients run the mark cue's OnRemove
# (the pop) for bob and log the new SoundWave as the engine loaded it and the SpawnSoundAttached call it makes. Clients
# run with -nosound (a client with sound on but no Wine audio driver hangs at startup): playback isn't observed.
# MODE=ult: tools/run/test_ishir_ult.steps instead: alice ults bob for real (R pressed as a player does) and both clients
# log each start and end of the mark and each shotgun play with the time.
# Usage: [PATCHES="community-ishir" | PATCHES=none] [MODE=ult] [RUN=<name>] tools/run/test_ishir.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-ishir}
RUN=$R PATCHES=${PATCHES:-community-ishir} CHECK=${CHECK:-community-ishir} HERO_A=Backstab ULT_A=Backstab_Skill3 \
  CAST_A=Backstab_Skill1 CUE_A= SKIP_CC=${SKIP_CC:-${MODE:+1}} STEPS=$PWD/tools/run/test_ishir${MODE:+_$MODE}.steps DURATION=${DURATION:-460} \
  tools/run/test_patch.sh
echo "== the shotgun sound on each client"
for n in alice bob; do sed "s/^/$n: /" work/run/$R-$n/MOBA/Binaries/Win64/ishirsound.log 2>/dev/null; done
