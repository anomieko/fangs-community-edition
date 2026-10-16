#!/usr/bin/env bash
# Community patch test (tools/patch/patches/community.json, docs/recon/community-build-values.md): two
# tools/run/test_patch.sh matches with the patch pak (ccrevert fiorne community), so check() confirms every patched
# class default on both clients and the game server, plus:
#   A: alice Belroth, bob Zoey. Belroth's Vicious Lunge and Zoey's ult on each other (STUN, not KNOCKUP), the Green and
#      Blue Shard buffs from 30 % health and 0 mana (tools/run/test_community_a.steps).
#   B: alice Somnia, bob Brutus. Brutus' health; Somnia's ult on him with his MoveSpeed every 50 ms
#      (tools/run/test_community_b.steps).
# Usage: [PATCHES=none] [RUN=<name>] [ONLY=a|b] tools/run/test_community.sh   (PATCHES=none: the control run)
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-community}
P=${PATCHES:-ccrevert fiorne community}
C=${CHECK:-ccrevert fiorne community}
if [[ ${ONLY:-a} == a || -z ${ONLY:-} ]]; then
  RUN=$R-a PATCHES=$P CHECK=$C HERO_A=BigBoi CAST_A=BigBoi_Skill1 ULT_A=BigBoi_Skill3 \
    HERO_B=CatSupp CAST_B=CatSupp_Skill4 LMB_B=CatSupp_LMB CUE_A= STEPS=$PWD/tools/run/test_community_a.steps \
    DURATION=${DURATION:-480} tools/run/test_patch.sh
fi
if [[ ${ONLY:-b} == b || -z ${ONLY:-} ]]; then
  RUN=$R-b PATCHES=$P CHECK=$C HERO_A=BookMage CAST_A=BookMage_Skill4 ULT_A=BookMage_RNEw \
    HERO_B=Berserker CAST_B=Berserker_Skill2 LMB_B=Berserker_LMB CUE_A= STEPS=$PWD/tools/run/test_community_b.steps \
    DURATION=${DURATION:-480} tools/run/test_patch.sh
  echo "== bob's MoveSpeed during Somnia's ult (game server, every 50 ms)"
  cat work/run/$R-b-hosts/host-*/MOBA/Binaries/Win64/track.log 2>/dev/null
fi
