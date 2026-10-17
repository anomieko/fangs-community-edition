#!/usr/bin/env bash
# Ethryn's shield test (tools/patch/patches/community-heroes.json, docs/recon/community-build-heroes.md):
# tools/run/test_patch.sh with bob as Ethryn and alice shooting into her raised shield (tools/run/test_shield.steps).
# The game server logs every reflect to shield.log: depth into the plate, side offset, where the copy starts, whether
# it still applies its effects, alice's health before and after.
#   MODE=boulder     alice = Belroth, Boulder Toss (E)
#   MODE=lamblaster  alice = Wylde, Lamblaster (E)
#   MODE=stormlense  alice = Rayo: his Stormlense damage formula run on the server for distances 0 to 1.2 x range
#   MODE=cage        alice = Astrada drops her Flame Cage on bob (Ethryn); screenshots on both clients (cage colours)
# Usage: MODE=boulder|lamblaster|cage|stormlense [PATCHES="ccrevert fiorne community-heroes" | PATCHES=none] [RUN=<name>] tools/run/test_shield.sh
set -u
cd "$(dirname "$0")/../.."
MODE=${MODE:?set MODE=boulder, lamblaster, cage or stormlense}
case $MODE in
  boulder) HA=BigBoi; SHOT=BigBoi_Skill4; ULT=BigBoi_Skill3; FIRST=BigBoi_LMB; TRACK=BP_MOBA_BigBoi_Skill4_Projectile_2 ;;
  lamblaster) HA=Gunslinger; SHOT=Gunslinger_Skill4; ULT=Gunslinger_R; FIRST=Gunslinger_LMB; TRACK=BP_MOBA_Gunslinger_Skill4_Projectile ;;
  cage) HA=FireMage; SHOT=Firemage_E; ULT=FireMage_R; FIRST=FireMage_LMB; TRACK=none ;;
  stormlense) HA=LightningArcher; SHOT=LightningArcher_E_; ULT=LightningArcher_R; FIRST=LightningArcher_LMB; TRACK=none ;;
  *) echo "unknown MODE $MODE"; exit 2 ;;
esac
R=${RUN:-shield-$MODE}
export SHOT TRACK
P=${PATCHES:-ccrevert fiorne community-heroes}; [[ $P == none ]] && C=community-heroes || C=$P
RUN=$R PATCHES=$P CHECK=${CHECK:-$C} HERO_A=$HA CAST_A=$FIRST ULT_A=$ULT \
  HERO_B=ShieldGirl CAST_B=ShieldGirl_LMB LMB_B=ShieldGirl_LMB CUE_A= \
  STEPS=$PWD/tools/run/test_$(case $MODE in cage) echo cage ;; stormlense) echo storm ;; *) echo shield ;; esac).steps DURATION=${DURATION:-480} tools/run/test_patch.sh
echo "== the shield's reflects (game server)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/shield.log 2>/dev/null
for n in alice bob; do
  rm -rf work/logs/$R-$n-shots; mkdir -p work/logs/$R-$n-shots
  cp work/run/$R-$n.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png work/logs/$R-$n-shots/ 2>/dev/null
done
ls work/logs/$R-alice-shots work/logs/$R-bob-shots 2>/dev/null | head -20
