#!/usr/bin/env bash
# Lobby-launch test along the real UI path: the owner creates a 2-slot custom lobby, picks a side,
# the Launch button must appear although the lobby isn't full; Launch -> hero select -> pick + lock in
# -> the match starts with just the owner. Own backend data and host dir, so local play is untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_launch.sh
set -u
cd "$(dirname "$0")/../.."
rm -rf work/run/launch-hosts work/run/launch-store.json
A=work/run/launch/MOBA/Binaries/Win64/fangsctl_cmd.txt
STATUS='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local ps=pc.PlayerState;'\
' local gs=FindFirstOf("GS_Lobby_GameState_C"); local m=pc.WB_LobbyMenuRef;'\
' return string.format("slot=%s owner=%s matchsize=%d players=%d launch-panel=%s", tostring(ps.ChosenSlot),'\
' tostring(ps.IsLobbyOwner), gs.MatchSize, gs.PlayerArray:GetArrayNum(),'\
' (m:IsValid() and tostring(m.LobbyStatusSwitch:GetActiveWidgetIndex() == 1) or "no lobby menu"))'\
' .. (function() local t={} gs.PlayerArray:ForEach(function(_, e) local p=e:get() t[#t+1]=p:GetFullName():match("[^.:]+$")'\
' .. "(" .. p:GetPlayerName():ToString() .. ", slot " .. tostring(p.ChosenSlot) .. ")" end) return " | " .. table.concat(t, " ") end)()'
WHERE='lua local gs=FindFirstOf("GameStateBase"); return "map: " .. (gs and gs:IsValid() and gs:GetFullName() or "none")'
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Launch Test", "The Garden of Vermilia", FText("LE_Arena02_Map"), 2); return "create 2-slot lobby"' >> $A
  sleep 60; echo "$STATUS" >> $A
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); if pc.PlayerState.ChosenSlot < 0 then pc:SelectTeamSlotOnServer(0) return "picked slot 0" end return "already had a slot"' >> $A
  sleep 4; echo "$STATUS" >> $A
  echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "launch pressed"' >> $A
  sleep 12; echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef; pc:UpdateChosenHero("Berserker"); return "hero select open=" .. tostring(h:IsValid() and h:IsInViewport())' >> $A
  sleep 4; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SetChosenHero(); return "locked in"' >> $A
  sleep 70; echo "$WHERE" >> $A
  echo 'lua local p=FindFirstOf("BP_PlayerChar_C"); return "pawn: " .. (p and p:IsValid() and p:GetFullName() or "none")' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/launch-store.json --instances $PWD/work/run/launch-hosts" \
  tools/run/headless.sh "${DURATION:-220}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- launch:0:"-TestUser=owner -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -hE 'fangsctl\]|fangsboot\] lobby' work/run/launch/MOBA/Binaries/Win64/ue4ss/UE4SS.log | cut -c30-260
grep -hE 'fangshost\] lobby' work/run/launch-hosts/host-*/MOBA/Binaries/Win64/ue4ss/UE4SS.log 2>/dev/null | cut -c30-200
