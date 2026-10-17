#!/usr/bin/env bash
# Tufts' Wing Dive test (tools/patch/patches/tufts-sync.json, docs/recon/server-performance.md): tools/run/test_patch.sh
# with bob as Tufts, then tools/run/test_tufts.steps: four dashes measured on his own client and on the game server.
# With latency (NETEM, default about 50 ms round trip) the client's dash starts a round trip after the server's
# without the patch, and at once with it; distance, speed, bursts and the hit should match.
# Usage: [PATCHES="tufts-sync" | PATCHES=none] [RUN=<name>] [NETEM="delay 25ms 5ms loss 0.5%"] tools/run/test_tufts.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-tufts}
RUN=$R PATCHES=${PATCHES:-tufts-sync} CHECK=${CHECK:-} HERO_B=Sidekick CUE_A= SKIP_CC=1 \
  NETEM=${NETEM-delay 25ms 5ms loss 0.5%} STEPS=$PWD/tools/run/test_tufts.steps DURATION=${DURATION:-480} \
  tools/run/test_patch.sh
echo "== bob's dashes on his own screen (client; seconds after Space went down)"
cat work/run/$R-bob/MOBA/Binaries/Win64/dash.log 2>/dev/null
echo "== bob's dashes on the game server (seconds after the host's watch began)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/dash.log 2>/dev/null
