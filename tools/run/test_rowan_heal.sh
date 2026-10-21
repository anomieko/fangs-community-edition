#!/usr/bin/env bash
# Rowan's passive on Overgrowth (docs/recon/community-build-rowan.md, "21 Oct: the heal amount, and a Sourblossom
# losing the passive"):
# tools/run/test_patch.sh with bob as Rowan and alice as Somnia, no CC casts. Before the round bob fills every heirloom
# slot (a default pick could be Heal Sprite): The Bloomblade (the ult leaves Overgrowth), Heal Sprite only with
# HEALSPRITE=1 (tools/run/test_rowan_heal.pre); then
# tools/run/test_rowan_heal.steps: alice shoots him down to 60-120 HP and he stands in a Sourblossom's ring for 15 s
# (a community member's case: from 90 HP, about 13 s); an Earth Rend arc and the ult's Overgrowth ending while he stands in a
# Sourblossom's ring too; the Sourblossom again from 60-120 HP with Heal Sprite's rate (SetupRegenAugment on the
# server's passive, what the item does). Health, the passive's effects and the plant's state every 0.25 s: rowan.log.
# Usage: [PATCHES="<patch> ...", PATCHES=none] [HEALSPRITE=1] [RUN=<name>] tools/run/test_rowan_heal.sh
# A corpse in a ring: tools/run/test_patch.sh with HERO_B=WoodenSword SKIP_CC=1 CUE_A= PRE_STEPS=tools/run/test_rowan_heal.pre
#   STEPS=tools/run/test_rowan_dead.steps (absolute paths), as for this script.
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-rowanheal}
P=${PATCHES:-ccrevert fiorne community-rowan}
[[ $P == none ]] && C=${CHECK:-community-rowan} || C=${CHECK:-$P}
RUN=$R PATCHES=$P CHECK=$C HERO_B=WoodenSword SKIP_CC=1 CUE_A= PRE_STEPS=$PWD/tools/run/test_rowan_heal.pre \
  STEPS=$PWD/tools/run/test_rowan_heal.steps DURATION=${DURATION:-720} tools/run/test_patch.sh
echo "== bob's items (client)"
cat work/run/$R-bob/MOBA/Binaries/Win64/equip.log 2>/dev/null
echo "== alice's shots (client)"
grep -c 'true' work/run/$R-alice/MOBA/Binaries/Win64/chain.log 2>/dev/null
echo "== Rowan on Overgrowth (game server, every 0.25 s)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/rowan.log 2>/dev/null
