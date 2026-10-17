#!/usr/bin/env bash
# Base blockers (docs/recon/base-blockers.md): tools/run/test_patch.sh with alice (team A, the first player) and bob
# (team B) on MAP, no default casts, then tools/run/test_base.steps: spawn protection in the augment phase and at the
# round start, walking out, Feb's first-player bug (ApplyImmunity on bob while he is outside and alice inside), a
# teleport out, death and respawn, a round change; abilities tried after each; walking back in after each exit.
# Usage: [PATCHES="<patch> ..." | PATCHES=none] [MAP=LE_Arena02_Map|LE_Arena06_Map|LE_Payload03_Map] [RUN=<name>]
#        tools/run/test_base.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-base}
MAP=${MAP:-LE_Arena02_Map}
case $MAP in
  LE_Arena02_Map) MN=Embersong ;; LE_Arena06_Map) MN=Stormheart ;; LE_Payload03_Map) MN=Crownwatch ;;
  *) echo "unknown MAP $MAP"; exit 2 ;;
esac
HA=${HERO_A:-WoodenSword}; HB=${HERO_B:-FireMage}
export BASE_LMB_A=${HA}_LMB BASE_LMB_B=${HB}_LMB
RUN=$R PATCHES=${PATCHES:-base-blockers} CHECK=${CHECK:-base-blockers} MAP=$MAP MAP_NAME=$MN SKIP_CC=1 ROUND_WAIT=${ROUND_WAIT:-40} \
  HERO_A=$HA HERO_B=$HB CAST_A=${HA}_LMB CAST_B=${HB}_LMB ULT_A=${HA}_LMB LMB_B=${HB}_LMB CUE_A= \
  STEPS=$PWD/tools/run/test_base.steps DURATION=${DURATION:-640} tools/run/test_patch.sh
echo "== base (game server)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/base.log 2>/dev/null
echo "== FangsHost"
grep -h 'base blockers\|modes:' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangshost.log 2>/dev/null | cut -c1-200
echo "== clients' ability tries"
grep -h 'fire BP_GA' work/run/$R-alice/MOBA/Binaries/Win64/fangsctl.log work/run/$R-bob/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | cut -c1-200
