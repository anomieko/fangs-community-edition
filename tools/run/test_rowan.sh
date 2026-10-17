#!/usr/bin/env bash
# Rowan and dash test (tools/patch/patches/community-rowan.json, docs/recon/community-build-rowan.md):
# tools/run/test_patch.sh with bob as Rowan (alice, Somnia, casts on him first). Before the round bob equips Dourling
# Caltrops, Glimmerbranch Hilt and Rush (tools/run/test_rowan.pre); then tools/run/test_rowan.steps: his health every
# 0.25 s on a Sourblossom ring, an Earth Rend arc and the ult's overgrowth; the vines after a dash and its recast; Rush
# hit by a stun mid-dash. Belroth's lunge: tools/run/test_patch.sh with HERO_B=BigBoi CAST_B=BigBoi_Skill1.
# Usage: [PATCHES="ccrevert fiorne community-rowan" | PATCHES=none] [RUN=<name>] tools/run/test_rowan.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-rowan}
P=${PATCHES:-ccrevert fiorne community-rowan}
# test_patch.sh builds (and, unless PATCHES=none, loads) the patches named in CHECK
[[ $P == none ]] && C=${CHECK:-community-rowan} || C=${CHECK:-$P}
RUN=$R PATCHES=$P CHECK=$C HERO_B=WoodenSword \
  CAST_B=WoodenSword_Skill1 LMB_B=WoodenSword_LMB CUE_A= PRE_STEPS=$PWD/tools/run/test_rowan.pre \
  STEPS=$PWD/tools/run/test_rowan.steps DURATION=${DURATION:-600} tools/run/test_patch.sh
echo "== bob's items (client)"
cat work/run/$R-bob/MOBA/Binaries/Win64/equip.log 2>/dev/null
echo "== bob's health (game server, every 0.25 s)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/hp.log 2>/dev/null
echo "== Propagator's charge bar (bob's client, FangsBoot)"
grep -h "Propagator bar" work/run/$R-bob/MOBA/Binaries/Win64/fangsboot.log 2>/dev/null | head -40
echo "== bob's speed during Rush (game server, every 50 ms)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/track.log 2>/dev/null
