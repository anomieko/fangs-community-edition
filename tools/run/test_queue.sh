#!/usr/bin/env bash
# Matchmaking test along the real UI path: a client presses PLAY (Casual queue), accepts the match,
# joins the game server the matchmaker started, picks Lancer + locks in and plays (1-player match).
# Own backend data and host dir, so a local play session is untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_queue.sh
set -u
cd "$(dirname "$0")/../.."
rm -rf work/run/queue-hosts work/run/queue-store.json
A=work/run/queue/MOBA/Binaries/Win64/fangsctl_cmd.txt
STATUS='lua local mm=FindFirstOf("MOBAMatchMakerSubsystem"); local gs=FindFirstOf("GameStateBase");'\
' return string.format("queued=%s match=%s server=%s map=%s", tostring(mm.bMatchQueued), mm.MatchId:ToString(),'\
' mm.MatchServerAddress:ToString(), gs:GetFullName():match("Maps/([%w_]+)") or "?")'
H=work/run/queue-hosts/host-7777/MOBA/Binaries/Win64/fangsctl_cmd.txt   # the game server's FangsCtl
HOST_STATUS='lua local gm=FindFirstOf("BP_GM_Lobby_GameMode_C"); if not (gm and gm:IsValid()) then'\
' return "host map: " .. FindFirstOf("GameStateBase"):GetFullName():match("Maps/([%w_]+)") end'\
' local gs=FindFirstOf("GS_Lobby_GameState_C"); local ps=nil; gs.PlayerArray:ForEach(function(_, e) ps = ps or e:get() end)'\
' return string.format("host lobby state=%d mode=%d max=%d pcs=%d matchsize=%d step=%d level=%s entry=%.0f/%.0f | %s locked=%s",'\
' gm.LobbyState, FindFirstOf("BP_MOBAInstance_C").MapGameMode, gm.MaxPlayers, gm.PlayerControllersRP:GetArrayNum(), gs.MatchSize, gs.GS_HeroSelectStep,'\
' gs.Level:ToString(), gm.EntryTime, gm.EntryTimeOutTime, ps and ps.ChosenHero:ToString() or "-", tostring(ps and ps.IsLockedIn))'
(
  sleep 45
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; gi.MapGameMode=2;'\
' pm:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "pressed PLAY (mode " .. gi.MapGameMode .. ")"' >> $A
  sleep 12; echo "$STATUS" >> $A
  echo 'lua local d=FindFirstOf("BP_MOBAInstance_C").WB_AcceptMatchRef; d:BndEvt__OkBtn_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature(); return "accepted"' >> $A
  sleep 60; echo "$STATUS" >> $A
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef; local gi=FindFirstOf("BP_MOBAInstance_C");'\
' gi.WB_MainMenuRef:UpdatePlayerHero("Lancer", false); pcall(function() pc:UpdateChosenHero("Lancer") end); return "hero select open=" .. tostring(h:IsValid() and h:IsInViewport()) .. ", slot " .. tostring(pc.PlayerState.ChosenSlot)' >> $A
  sleep 4; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SetChosenHero(); return "locked in"' >> $A
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local L=StaticFindObject("/Script/BlueprintJson.Default__BlueprintJsonLibrary");'\
' return "host season data: " .. L:Conv_JsonObjectToString(gi.CloudSeasonDataBP):ToString():sub(1, 400)' >> $H
  for i in $(seq 1 ${WATCH:-4}); do sleep 20; echo "$HOST_STATUS" >> $H; done
  echo 'shot showui' >> $A
  sleep 10; echo "$STATUS" >> $A
  echo 'lua local p=FindFirstOf("BP_PlayerChar_C"); return "pawn: " .. (p and p:IsValid() and p:GetFName():ToString() or "none")' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/queue-store.json --instances $PWD/work/run/queue-hosts --match-size 1" \
  tools/run/headless.sh "${DURATION:-290}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- queue:0:"-TestUser=queuer -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -hE 'fangsctl\]|fangsboot\] (lobby|HUD|retag)' work/run/queue/MOBA/Binaries/Win64/ue4ss/UE4SS.log | cut -c30-260
grep -hE 'fangshost\] (lobby|matchmade|removed)|fangsctl\] lua' work/run/queue-hosts/host-*/MOBA/Binaries/Win64/ue4ss/UE4SS.log 2>/dev/null | cut -c30-200
grep -h '"mm"' work/logs/queue-backend.stdout | grep -v recv | cut -c1-160
