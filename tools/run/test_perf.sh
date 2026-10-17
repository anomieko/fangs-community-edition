#!/usr/bin/env bash
# Game-server load test: a GPU-rendered headless client starts a custom match on Embersong, the game server gets
# BOTS AI heroes (the game's own bots: GS_MOBA_Battle.SpawnBot with each hero's behaviour tree), and the server's
# frame times and CPU are recorded for SECS seconds of the match:
#   - tools/run/perf_frames.lua in every game server of the run (per-second fps / longest frame, every frame > 40 ms);
#   - tools/run/perf_sample.py: the game thread's CPU, run-queue wait and syscalls (~2 ms), its wineserver, all threads;
#   - the report (perf_sample.py report) at the end, also saved as work/logs/<RUN>-report.txt.
# The servers run like on the VPS: own Wine prefix each (FANGS_PREFIX_PER_HOST), a standby next to the match, pinned
# to CPUS (4 CPUs, like the 4-vCPU VPS), and by default WITHOUT ntsync (the VPS kernel has no /dev/ntsync).
# Own backend data and game-server directory, so local play is untouched.
# CLIENTS=2..3: more GPU clients join the lobby from the lobby list (real connections, like players); ACTIVE=1: every
# client walks around all the time (normal client movement -> ServerMove) and fires its abilities every ~5 s.
# Usage: [RUN=perf-x] [BOTS=11] [CLIENTS=1] [ACTIVE=0] [SECS=240] [NTSYNC=0|1] [CPUS=12-15] [STANDBY=1] [HERO=Lancer]
#        [SERVER_CMDS="<console command>;..."] [FANGS_*=... (passed to server/run-host.sh)] tools/run/test_perf.sh
#   SERVER_CMDS: FangsCtl lines (console commands or "lua ...") for every game server of the run when the measurement
#   starts (A/B tests); GC_PROBE=1: three forced garbage collections after the window, with the frames they cost.
#   SERVER_MOVIES=0: the game servers run on a copy of the game without its movies.
#   RUNHOST: another game-server start script than server/run-host.sh (relative to the repo).
#   MODS: another tools/ue4ss-like directory for the game servers' mods (e.g. a changed FangsHost to compare).
#   MAP=LE_Payload03_Map (default LE_Arena02_Map, Embersong): the arena of the match.
#   FIGHT=1: every hero is put in the middle of the map when the measurement starts (a big team fight), and ACTIVE
#   clients walk back towards the middle when they are more than 900 away from it.
#   SNAPS=1: tools/run/net_snaps.lua on every client (rubber-banding: own position snaps, other heroes' jumps, client
#   frames per second); summary by tools/run/net_snaps_report.py.
#   NETEM="delay 25ms 5ms loss 0.5%": latency between everything in the test (tools/run/headless.sh).
#   DASH=1: every client charges and releases Space every 2.5 s (tools/run/net_dash.lua; e.g. HERO=Sidekick).
set -u
cd "$(dirname "$0")/../.."
REPO=$PWD
# An outer user + mount namespace (headless.sh nests its network namespace in it): NTSYNC=0 hides /dev/ntsync there,
# and the sampler, running inside, may read the game thread's current syscall.
if [[ -z ${PERF_NS:-} ]]; then exec env PERF_NS=1 unshare -rm --propagation private bash "$0" "$@"; fi
R=${RUN:-perf}
MAP=${MAP:-LE_Arena02_Map}
case $MAP in LE_Arena02_Map) MAPNAME=Embersong ;; LE_Arena06_Map) MAPNAME=Stormheart ;; LE_Payload03_Map) MAPNAME=Crownwatch ;; *) MAPNAME=$MAP ;; esac
BOTS=${BOTS:-11}; SECS=${SECS:-240}; CLIENTS=${CLIENTS:-1}; HERO=${HERO:-Lancer}; CPUS=${CPUS:-12-15}
if [[ ${NTSYNC:-0} == 0 ]]; then
  sock=work/run/.$R.nosync; rm -f "$sock"
  python3 -I -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock" && mount --bind "$sock" /dev/ntsync \
    || { echo "could not hide /dev/ntsync" >&2; exit 1; }
fi
rm -rf work/run/$R-hosts work/run/$R-store.json work/logs/$R-perf
mkdir -p work/logs/$R-perf
# Game servers like on the VPS: pinned to CPUS (the clients and backend stay off them), a Wine prefix without DXVK
# (copied per server by run-host.sh) and no GPU driver (no Vulkan ICD).
rm -rf work/run/$R-hosts.cpuprefix; cp -a --reflink=auto work/wine/prefix work/run/$R-hosts.cpuprefix
cat > work/run/$R-runhost.sh <<EOF
#!/usr/bin/env bash
export WINEPREFIX=$REPO/work/run/$R-hosts.cpuprefix VK_DRIVER_FILES=/dev/null VK_ICD_FILENAMES=/dev/null ${MODS:+FANGS_MODS=$(realpath "${MODS:-.}")}
exec ${CPUS:+taskset -c $CPUS} "$REPO/${RUNHOST:-server/run-host.sh}" "\$@"
EOF
chmod +x work/run/$R-runhost.sh
export FANGS_PREFIX_PER_HOST=${FANGS_PREFIX_PER_HOST:-1}
CLIENT=${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}; GAME=$CLIENT
if [[ ${SERVER_MOVIES:-1} == 0 ]]; then   # game servers on a copy of the game without its .mp4s
  GAME=work/run/$R-game; rm -rf $GAME; cp -a --reflink=always "$CLIENT" $GAME; find $GAME/MOBA/Content/Movies -name '*.mp4' -delete
fi

A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
CL=($A); for ((i = 2; i <= CLIENTS; i++)); do CL+=(work/run/$R-c$i/MOBA/Binaries/Win64/fangsctl_cmd.txt); done
all_clients() { for f in "${CL[@]}"; do echo "$1" >> "$f"; done; }
host_cmd() { for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
match_cmd() {   # the server(s) of the run that are in the arena
  for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do grep -q 'Arena\|Payload' $h/fangshost_status.json 2>/dev/null && echo "$1" >> $h/fangsctl_cmd.txt; done
}
WHERE='lua local gs=FindFirstOf("GameStateBase"); return "map: " .. (gs and gs:IsValid() and gs:GetFullName():match("Maps/([%w_]+)") or "none")'
COUNT='lua local n, ai, moving = 0, 0, 0 for _, p in ipairs(FindAllOf("BP_PlayerChar_C") or {}) do if p:IsValid() and not p:GetFullName():find("Default__", 1, true) then n=n+1'\
' local c=p.Controller if c and c:IsValid() and c:IsA(StaticFindObject("/Script/AIModule.AIController")) then ai=ai+1 end'\
' local ok, v = pcall(function() return p:GetVelocity() end) if ok and v and (v.X * v.X + v.Y * v.Y) > 100 then moving=moving+1 end end end'\
' local gi=FindFirstOf("BP_MOBAInstance_C") return string.format("heroes: %d (%d AI, %d moving), mode %d, players %d", n, ai, moving, gi.MapGameMode, gi.MapPlayerCount)'
CVARS='lua local K=StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") local t={}'\
' for _, n in ipairs({"gc.TimeBetweenPurgingPendingKillObjects", "gc.IncrementalBeginDestroyEnabled", "gc.MultithreadedDestructionEnabled", "gc.AllowParallelGC",'\
' "gc.CreateGCClusters", "gc.ActorClusteringEnabled", "gc.LowMemory.MemoryThresholdMB", "gc.MaxObjectsNotConsideredByGC", "net.UseAdaptiveNetUpdateFrequency",'\
' "net.MaxRPCPerNetUpdate", "t.MaxFPS", "net.IsPushModelEnabled"}) do local ok, v = pcall(function() return K:GetConsoleVariableFloatValue(n) end)'\
' t[#t+1]=n .. "=" .. (ok and tostring(v) or "?") end return "cvars: " .. table.concat(t, " ")'
# released heroes that have a behaviour tree (DT_Heroes BehaviorTree)
BOT_HEROES=(Berserker Gunslinger ShieldGirl FireMage Backstab IceMage LightningArcher DemonGirl WoodenSword BookMage Sidekick BattleMonk CatSupp BigBoi Lancer)
spawn_bots() {
  local n=$1 i code='lua local gs=FindFirstOf("GS_MOBA_Battle_C"); local out={}'
  for ((i = CLIENTS; i < CLIENTS + n; i++)); do   # client indexes after the players' (team = index % 2)
    code+=' local ok'$i', e'$i' = pcall(function() gs:SpawnBot(FName("'${BOT_HEROES[$(( (i - 1) % ${#BOT_HEROES[@]} ))]}'"), '$i') end) out[#out+1]=ok'$i' and "ok" or tostring(e'$i')'
  done
  code+=' return "spawned bots: " .. table.concat(out, ",")'
  match_cmd "$code"
}
measure_s=$SECS
LOCKIN_BTN='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef;'\
' if h:ShowSelectHeroBtn() == 0 then h:BndEvt__ReadyBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "lock in clicked" end'\
' pcall(function() pc:SetChosenHero() end) return "locked in (no button)"'
PICK_HEROES=(Lancer Berserker Gunslinger)
pick() { echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$2"'", false);'\
' pcall(function() pc:UpdateChosenHero("'"$2"'") end); return "picked '"$2"'"' >> "$1"; }
# walk (a new direction every 2 s) and fire every ability every ~5 s, like a player (ACTIVE=1)
PLAY='lua if PERF_PLAY then return "already playing" end local n, dir = 0, 0'\
' PERF_PLAY = LoopInGameThreadWithDelay(50, function() pcall(function()'\
' local gi=FindFirstOf("BP_MOBAInstance_C") local p=StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0).Pawn'\
' if not (p and p:IsValid()) then return end n = n + 1 if n % 40 == 0 then dir = math.random() * 6.283 end'\
' if FIGHT then local l=p:K2_GetActorLocation() if l.X * l.X + l.Y * l.Y > 810000 then dir = math.atan(-l.Y, -l.X) + (math.random() - 0.5) end end'\
' p:AddMovementInput({X=math.cos(dir), Y=math.sin(dir), Z=0}, 1.0, false)'\
' if n % 100 == 0 then p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e) local a=e:get().Ability'\
' if a and a:IsValid() and not a:GetClass():GetFName():ToString():find("Emote") then p.AbilitySystemComponent:TryActivateAbilityByClass(a:GetClass(), true) end end) end'\
' end) end) return "playing"'
(
  sleep 40
  if [[ $CLIENTS -le 1 ]]; then
    printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
      'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Perf Test", "'$MAPNAME'", FText("'$MAP'"), 1); return "create"' >> $A
    sleep 40; echo "$WHERE" >> $A
    pick $A "$HERO"
    sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  else   # the others join from the lobby list (test_join.sh), the owner launches, everyone picks and locks in
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:CreateLobbyAndJoin("Perf Test", "'$MAPNAME'", FText("'$MAP'"), 12); return "create 12-slot lobby"' >> $A
    sleep 50
    for f in "${CL[@]:1}"; do echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi:ShowChoseGameMode(); gi.WB_ChoseGameModeRef:SetJoinCustomMode(); return "join mode"' >> $f; done
    sleep 2
    for f in "${CL[@]:1}"; do echo 'lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu; pm:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "PLAY"' >> $f; done
    sleep 12
    for f in "${CL[@]:1}"; do
      echo 'lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu; if pm.LobbyList:GetChildrenCount() == 0 then return "no lobby listed" end'\
' pm.LobbyList:GetChildAt(0):BndEvt__SelectSessionBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "joined"' >> $f
      sleep 3
    done
    sleep 30
    echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "launch"' >> $A
    sleep 12
    for ((i = 0; i < CLIENTS; i++)); do pick "${CL[$i]}" "${PICK_HEROES[$i]}"; done
    sleep 4; all_clients "$LOCKIN_BTN"
  fi
  for _ in $(seq 45); do sleep 2; grep -qs 'Arena\|Payload' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangshost_status.json && break; done
  sleep 10; all_clients "$WHERE"
  LOCKIN='lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pc=StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0)'\
' pcall(function() pc.PlayerState:ReportetFinishedItemSelectOnServer(false) end) pcall(function() pc:PlayerLockedIn() end) return "locked in"'
  all_clients "$LOCKIN"
  [[ ${FIGHT:-0} == 1 ]] && all_clients 'lua FIGHT = true return "fight: walk to the middle"'
  [[ ${ACTIVE:-0} == 1 ]] && all_clients "$PLAY"
  match_cmd "$COUNT"
  [[ $BOTS -gt 0 ]] && spawn_bots "$BOTS"
  sleep 5; match_cmd "$COUNT"
  # what the object lookups FangsHost's loops use cost in this world (before the measurement starts)
  match_cmd 'lua local function t(name, n, f) local c=os.clock() for _=1,n do f() end return string.format("%s %.1f ms", name, (os.clock()-c)*1000/n) end'\
' return "lookup cost: " .. table.concat({ t("FindFirstOf(GameStateBase)", 10, function() return FindFirstOf("GameStateBase") end),'\
' t("FindAllOf(PlayerController)", 10, function() return FindAllOf("PlayerController") end),'\
' t("FindFirstOf(BP_MOBAInstance_C)", 10, function() return FindFirstOf("BP_MOBAInstance_C") end),'\
' t("StaticFindObject", 100, function() return StaticFindObject("/Script/Engine.Default__GameplayStatics") end)}, ", ")'
  sleep 3
  if [[ ${FIGHT:-0} == 1 ]]; then   # every hero into a ring around the middle of the map (keeps each one's height)
    match_cmd 'lua local hs={} for _, p in ipairs(FindAllOf("BP_PlayerChar_C") or {}) do if p:IsValid() and not p:GetFullName():find("Default__", 1, true) then hs[#hs+1]=p end end'\
' for i, p in ipairs(hs) do local a = i * 6.283 / #hs local l=p:K2_GetActorLocation()'\
' p:K2_SetActorLocation({X=450 * math.cos(a), Y=450 * math.sin(a), Z=l.Z}, false, {}, true) end return "fight: " .. #hs .. " heroes in the middle"'
    sleep 2
  fi
  if [[ ${SNAPS:-0} == 1 ]]; then
    for f in "${CL[@]}"; do cp tools/run/net_snaps.lua "$(dirname "$f")/"; done
    all_clients 'lua return dofile("net_snaps.lua")'
  fi
  if [[ ${DASH:-0} == 1 ]]; then   # every client charges and releases Space every 2.5 s (tools/run/net_dash.lua)
    for f in "${CL[@]}"; do cp tools/run/net_dash.lua "$(dirname "$f")/"; done
    all_clients 'lua return dofile("net_dash.lua")'
  fi
  for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do cp tools/run/perf_frames.lua $h/; done
  host_cmd 'lua return dofile("perf_frames.lua")'
  if [[ -n ${SERVER_CMDS:-} ]]; then IFS=';' read -ra cmds <<< "$SERVER_CMDS"; for c in "${cmds[@]}"; do host_cmd "$c"; done; fi
  python3 -I tools/run/perf_sample.py sample work/logs/$R-perf work/run/$R-hosts "$measure_s" &
  # game traffic, from inside the test's network namespace (the backend's)
  bpid=$(pgrep -f "fangs_backend.py.*$R-store.json" | head -1)
  [[ -n $bpid ]] && nsenter -t "$bpid" -U -n --preserve-credentials python3 -I tools/run/perf_sample.py net work/logs/$R-perf "$measure_s" &
  # keep the client's hero doing something: fire its abilities now and then
  for ((t = 0; t < measure_s; t += 30)); do
    sleep 30
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local p=StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0).Pawn'\
' local n=0 p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e) local a=e:get().Ability'\
' if a and a:IsValid() and not a:GetClass():GetFName():ToString():find("Emote") then p.AbilitySystemComponent:TryActivateAbilityByClass(a:GetClass(), true) n=n+1 end end)'\
' return "fired " .. n' >> $A
    all_clients "$LOCKIN"
  done
  wait
  match_cmd "$COUNT"
  match_cmd "$CVARS"
  # which tick / net concurrency cvars this Shipping build has: set 1, read back, set 0, read back, restore
  match_cmd 'lua local K=StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") local gs=FindFirstOf("GameStateBase") local t={}'\
' for _, n in ipairs({"tick.AllowAsyncTickDispatch", "tick.AllowAsyncTickCleanup", "tick.AllowConcurrentTickQueue", "tick.AllowAsyncComponentTicks",'\
' "net.UseAdaptiveNetUpdateFrequency", "net.MaxConnectionsToTickPerServerFrame"}) do local v0=K:GetConsoleVariableFloatValue(n)'\
' K:ExecuteConsoleCommand(gs, n .. " 1", nil) local v1=K:GetConsoleVariableFloatValue(n) K:ExecuteConsoleCommand(gs, n .. " 0", nil) local v2=K:GetConsoleVariableFloatValue(n)'\
' K:ExecuteConsoleCommand(gs, n .. " " .. v0, nil) t[#t+1]=n .. "=" .. v0 .. ((v1 == 1 and v2 == 0) and " (exists)" or " (missing)") end return "tickvars: " .. table.concat(t, ", ")'
  match_cmd 'lua local p=FindFirstOf("BP_PlayerChar_C") local ps=p.PlayerState local gs=FindFirstOf("GameStateBase")'\
' return string.format("netfreq: hero %.0f (min %.0f, priority %.1f), player state %.0f, game state %.0f", p.NetUpdateFrequency, p.MinNetUpdateFrequency, p.NetPriority,'\
' ps.NetUpdateFrequency, gs.NetUpdateFrequency)'
  match_cmd 'lua local out={} for _, d in ipairs(FindAllOf("IpNetDriver") or {}) do if d:IsValid() and not d:GetFullName():find("Default__", 1, true) then'\
' out[#out+1]=string.format("%s tick=%s clamp=%s rate=%d conns=%d", d.NetDriverName:ToString(), tostring(d.NetServerMaxTickRate), tostring(d.bClampListenServerTickRate),'\
' d.MaxClientRate, d.ClientConnections:GetArrayNum()) .. " repdriver=" .. tostring(d.ReplicationDriver and d.ReplicationDriver:IsValid() and d.ReplicationDriver:GetFullName())'\
' end end local e=FindFirstOf("GameEngine") return "netdriver: " .. table.concat(out, " | ") .. " clientticks=" .. tostring(e and e.NetClientTicksPerSecond)'
  if [[ -n ${GC_PROBE:-} ]]; then   # cost of a full garbage collection (KismetSystemLibrary.CollectGarbage), after the window
    for _ in 1 2 3; do sleep 4; match_cmd 'lua StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"):CollectGarbage() return "gc at " .. os.clock()'; done
  fi
  sleep 4
  # memory per game server: anonymous memory of every process in its Wine prefix (what counts against the VPS limit)
  for pid in $(pgrep -u "$(id -u)"); do
    e=$(tr '\0' '\n' < /proc/$pid/environ 2>/dev/null | grep "^WINEPREFIX=.*/$R-hosts/" | cut -d= -f2)
    [[ -n $e ]] && echo "$(basename "$e") $(cat /proc/$pid/comm 2>/dev/null | tr ' ' _) $(awk '/^RssAnon:/{print $2}' /proc/$pid/status 2>/dev/null)"
  done | awk '{a[$1]+=$3; if ($3 > 20000) p[$1]=p[$1] " " $2 "=" int($3/1024)} END {for (h in a) printf "memory %s: %d MB anonymous (%s )\n", h, a[h]/1024, p[h]}' \
    > work/logs/$R-perf/memory.txt
) &
taskset -c 0-7,16-23 env UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --run-host $PWD/work/run/$R-runhost.sh --host-standby ${STANDBY:-1} --game-dir $(realpath $GAME)" \
  tools/run/headless.sh "$((40 + 40 + 8 + 90 + 10 + 5 + measure_s + 20 + (CLIENTS > 1 ? 80 : 0)))" "$CLIENT" \
  -- $R:0:"-TestUser=perfer -TestPass=x" $(for ((i = 2; i <= CLIENTS; i++)); do echo "-- $R-c$i:$((3 * i)):-TestUser=perfer$i -TestPass=x"; done) 2>&1 | grep -v Segmentation
wait
echo "== client"; grep -h 'lua \|exec' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | grep -v 'fired' | cut -c21-300 | tail -8
for ((i = 2; i <= CLIENTS; i++)); do grep -h 'lua \|exec' work/run/$R-c$i/MOBA/Binaries/Win64/fangsctl.log | grep -v 'fired' | cut -c21-300 | tail -4 | sed "s/^/client $i: /"; done
echo "== game servers"; grep -h 'lua \(ok\|error\)' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | cut -c21-300 | sort | uniq -c | sort -rn | head -12
grep -h 'tick:' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangshost.log 2>/dev/null | cut -c21-200
if [[ -n ${GC_PROBE:-} ]]; then   # the frames right after each forced garbage collection
  for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do
    grep -h 'gc at' $h/fangsctl.log | sed 's/.*gc at //' | while read -r t; do
      echo "gc probe at $t: $(awk -v t="$t" '$1=="F" && $2>=t && $2<=t+2 {printf "%s ms ", $3}' $h/perf_frames.log)"
    done
  done
fi
for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do cp $h/perf_frames.log work/logs/$R-perf/$(basename "$(dirname "$(dirname "$(dirname "$h")")")").frames.log 2>/dev/null; done
cat work/logs/$R-perf/memory.txt 2>/dev/null
if [[ ${SNAPS:-0} == 1 ]]; then
  for ((i = 0; i < CLIENTS; i++)); do cp "$(dirname "${CL[$i]}")/net_snaps.log" work/logs/$R-perf/client$((i + 1)).snaps.log 2>/dev/null; done
  python3 -I tools/run/net_snaps_report.py work/logs/$R-perf "${SKIP:-10}" | tee work/logs/$R-snaps.txt
fi
python3 -I tools/run/perf_sample.py report work/logs/$R-perf work/run/$R-hosts "${SKIP:-10}" "$measure_s" | tee work/logs/$R-report.txt
rm -rf work/run/.$R.nosync work/run/$R-hosts.cpuprefix work/run/$R-game
