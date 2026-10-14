#!/usr/bin/env bash
# What an idle game server's CPU goes to: one headless client that only logs in (so the backend boots a
# standby game server), then on that server: GameThread CPU, and the cost of the UE4SS lookups our mods
# run periodically. Own backend data and host dir; local play is untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_hostcost.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-cost}
rm -rf work/run/$R-hosts work/run/$R-store.json
TIMING='lua local function t(name, n, f) local c=os.clock() for _=1,n do f() end return string.format("%s %.2f ms", name, (os.clock()-c)*1000/n) end'\
' return "cost: " .. table.concat({'\
' t("FindFirstOf(GameStateBase)", 50, function() return FindFirstOf("GameStateBase") end),'\
' t("FindAllOf(PlayerController)", 20, function() return FindAllOf("PlayerController") end),'\
' t("FindFirstOf(BP_MOBAInstance_C)", 50, function() return FindFirstOf("BP_MOBAInstance_C") end),'\
' t("FindFirstOf(BP_GM_Lobby_GameMode_C)", 50, function() return FindFirstOf("BP_GM_Lobby_GameMode_C") end),'\
' t("StaticFindObject", 200, function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)}, ", ")'
(
  sleep 100
  for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$TIMING" >> $h/fangsctl_cmd.txt; done
  sleep 5
  for pid in $(pgrep -x GameThread); do
    cwd=$(readlink /proc/$pid/cwd 2>/dev/null); [[ $cwd == *"/$R-hosts/"* ]] || continue
    t0=$(awk '{print $14+$15}' /proc/$pid/stat); sleep 20; t1=$(awk '{print $14+$15}' /proc/$pid/stat)
    echo "probe cpu: $(( (t1 - t0) * 100 / 20 / $(getconf CLK_TCK) ))% of a core ($(cat ${cwd}/fangshost_status.json))"
  done
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-140}" "${CLIENT_DIR:-clients/fangs-2022-08-26-b9396481}" \
  -- $R:0:"-TestUser=idle -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -h 'lua \(ok\|error\): cost' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangsctl.log | cut -c1-400
