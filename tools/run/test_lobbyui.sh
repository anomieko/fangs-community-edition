#!/usr/bin/env bash
# Custom lobby settings test (FangsBoot lobbyui.lua, FangsHost lobby.lua, docs/recon/community-build-lobby.md): alice
# makes a 3v3 custom lobby, bob and carol join. alice's LOBBY SETTINGS panel (driven through its widgets' own click
# handlers): map Crownwatch, Best of 5, Captain vote on, shuffle twice; everyone's panel must show the server's
# settings. Then 1 vs 1: carol's seat is gone, she waits; alice's LAUNCH has the server remove her, then the game
# launches; alice and bob play: the HUD's vote every round, MaxRounds 3 on server and clients, an 8 s vote window on the
# server. Screenshots in work/logs/lobbyui-shots/. Own backend data and game servers; local play is untouched.
# Usage: [RUN=<name>] [CLIENT_DIR=clients/<build>] tools/run/test_lobbyui.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
R=${RUN:-lobbyui}
CLIENT=${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}
rm -rf work/run/$R-hosts work/run/$R-store.json work/run/$R-paks; mkdir -p work/run/$R-paks
OUT=$PWD/work/run/$R-paks/FangsCE_P.pak tools/patch/build.sh "$CLIENT" community-lobby > work/run/$R-build.txt || { cat work/run/$R-build.txt; exit 1; }
export FANGS_PAKS=$PWD/work/run/$R-paks
W=MOBA/Binaries/Win64/fangsctl_cmd.txt
A=work/run/$R-alice/$W; B=work/run/$R-bob/$W; C=work/run/$R-carol/$W
HOSTS="work/run/$R-hosts/host-*/MOBA/Binaries/Win64"
host() { for h in $HOSTS; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
all() { echo "$1" >> $A; echo "$1" >> $B; echo "$1" >> $C; }
# our widgets, found by class and label (FangsBoot's Lua state isn't reachable from FangsCtl's)
HELPERS='lua function FW(class, label) for _, w in ipairs(FindAllOf(class) or {}) do if w:IsValid() and not w:GetFullName():find("Default__", 1, true) then'\
' local ok, t = pcall(function() return w.OptionLbl:GetText():ToString() end); if ok and t == label then return w end end end end;'\
' function FB(text) for _, w in ipairs(FindAllOf("WB_IconButton_Secondary_C") or {}) do if w:IsValid() and not w:GetFullName():find("Default__", 1, true) then'\
' local ok, t = pcall(function() return w.BtnText:ToString() end); if ok and t:find(text, 1, true) then return w end end end end; return "helpers ready"'
PANEL='lua local function sel(l) local w = FW("WB_SettingComboBoxOption_C", l); return w and w.OptionDropDown:GetSelectedOption():ToString() or "none" end;'\
' local v = FW("WB_SettingToggleButton_C", "CAPTAIN VOTE"); return string.format("panel map=%s teams=%s rounds=%s vote=%s enabled=%s",'\
' sel("MAP"), sel("TEAMS"), sel("ROUNDS"), v and tostring(v.CurrentState) or "none", v and tostring(v:GetIsEnabled()) or "?")'
CHOOSE='lua FW("WB_SettingComboBoxOption_C", "%s"):BndEvt__OptionDropDown_K2Node_ComponentBoundEvent_0_OnSelectionChangedEvent__DelegateSignature("%s", 2); return "chose %s"'
BTN=BndEvt__WB_BattlePassBtn_Secondary_SecondaryBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature
VOTE='lua FW("WB_SettingToggleButton_C", "CAPTAIN VOTE"):BndEvt__ToggleBtn_K2Node_ComponentBoundEvent_1_OnButtonClickedEvent__DelegateSignature(); return "vote clicked"'
PRESS="lua FB(\"%s\"):$BTN(); return \"pressed %s\""
SEATS='lua local gs=FindFirstOf("GS_Lobby_GameState_C"); local t={}; gs.PlayerArray:ForEach(function(_,e) local ps=e:get();'\
' t[#t+1]=ps:GetPlayerName():ToString()..":"..ps.ChosenSlot end); table.sort(t); return "seats "..table.concat(t," ").." | "..gs.ServerPayload:ToString()'
SWITCH='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); return "launch page "..pc.WB_LobbyMenuRef.LobbyStatusSwitch:GetActiveWidgetIndex()'
SEAT='lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer(%d); return "seat %d"'
LOCKIN='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef;'\
' if h:ShowSelectHeroBtn() == 0 then h:BndEvt__ReadyBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "locked in" end return "lock in button hidden"'
PICK='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("%s", false); pcall(function() pc:UpdateChosenHero("%s") end); return "picked %s"'
CLIENT_MATCH='lua local gi=FindFirstOf("BP_MOBAInstance_C"); local gs=gi:GetWorld().GameState; local pc=FindFirstOf("BP_PC_MOBA_PlayerController_C");'\
' local rs; for _,r in ipairs(FindAllOf("BP_RS_King_C") or {}) do if not r:GetFullName():find("Default__") then rs=r end end;'\
' return string.format("match: map=%s KingVoteRound=%s MaxRounds=%s vote window=%s", gs:GetFullName():match("Maps/([%w_]+)") or "?",'\
' tostring(pc.WB_HUDGamplayRef.KingVoteRound), tostring(gs.MaxRounds), tostring(rs and rs.MaxKingVotingTime))'
SERVER_MATCH='lua local gi=FindFirstOf("BP_MOBAInstance_C"); local gs=gi:GetWorld().GameState; if not gs:GetClass():GetFName():ToString():find("^GS_MOBA_Battle") then return "server: no match" end; local rs; for _,r in ipairs(FindAllOf("BP_RS_King_C") or {}) do if not r:GetFullName():find("Default__") then rs=r end end;'\
' local t={}; gs.PlayerArray:ForEach(function(_,e) local ps=e:get(); t[#t+1]=ps:GetPlayerName():ToString().." team "..ps.Team.." captain="..tostring(ps.IsKing).." vote="..ps.KingVoteCustomID:ToString() end);'\
' return string.format("server: MaxRounds=%s vote window=%s kings=%s/%s | %s", tostring(gs.MaxRounds), tostring(rs and rs.MaxKingVotingTime), rs and rs.TeamAKingPlayerID:ToString() or "?", rs and rs.TeamBKingPlayerID:ToString() or "?", table.concat(t, "; "))'
JOIN1='lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi:ShowChoseGameMode(); gi.WB_ChoseGameModeRef:SetJoinCustomMode(); return "join a lobby"'
JOIN2='lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "PLAY"'
JOIN3='lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu; if pm.LobbyList:GetChildrenCount() == 0 then return "no lobby to join" end'\
' pm.LobbyList:GetChildAt(0):BndEvt__SelectSessionBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "joined the lobby"'
(
  sleep 40
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:CreateLobbyAndJoin("Lobby UI Test", "Embersong", FText("LE_Arena02_Map"), 6); return "alice: create lobby"' >> $A
  sleep 50
  echo "$JOIN1" >> $B; sleep 2; echo "$JOIN2" >> $B; sleep 10; echo "$JOIN3" >> $B
  sleep 8
  echo "$JOIN1" >> $C; sleep 2; echo "$JOIN2" >> $C; sleep 10; echo "$JOIN3" >> $C
  sleep 25
  all "$HELPERS"
  all "$PANEL"; echo "$SEATS" >> $A; all 'shot showui'
  sleep 3
  # alice changes the settings through the panel's own widgets
  printf "$CHOOSE\n" MAP Crownwatch Crownwatch >> $A; sleep 1
  printf "$CHOOSE\n" ROUNDS "Best of 5" "Best of 5" >> $A; sleep 1
  echo "$VOTE" >> $A; sleep 3
  all "$PANEL"; echo "$SEATS" >> $A; all 'shot showui'
  sleep 2
  printf "$PRESS\n" SHUFFLE shuffle >> $A; sleep 2; echo "$SEATS" >> $A
  printf "$PRESS\n" SHUFFLE shuffle >> $A; sleep 2; echo "$SEATS" >> $A
  # known seats, then 1 vs 1: carol's seat (2) is gone
  printf "$SEAT\n" -1 -1 >> $C; printf "$SEAT\n" -1 -1 >> $B; sleep 1
  printf "$SEAT\n" 0 0 >> $A; sleep 1; printf "$SEAT\n" 1 1 >> $B; sleep 1; printf "$SEAT\n" 2 2 >> $C; sleep 2
  echo "$SEATS" >> $A
  printf "$CHOOSE\n" TEAMS "1 vs 1" "1 vs 1" >> $A; sleep 3
  echo "$SEATS" >> $A; echo "$SWITCH" >> $A; all "$PANEL"; all 'shot showui'
  sleep 3
  printf "$PRESS\n" START launch >> $A
  sleep 10; echo "$SEATS" >> $A
  printf "$PICK\n" FireMage FireMage FireMage >> $A; printf "$PICK\n" Lancer Lancer Lancer >> $B
  sleep 4; echo "$LOCKIN" >> $A; echo "$LOCKIN" >> $B
  sleep 55
  echo "$CLIENT_MATCH" >> $A; echo "$CLIENT_MATCH" >> $B; host "$SERVER_MATCH"
  for i in 1 2 3 4 5 6; do sleep 5; echo 'shot showui' >> $A; echo "$CLIENT_MATCH" >> $A; host "$SERVER_MATCH"; done
  sleep "${HOLD:-90}"; host "$SERVER_MATCH"; echo "$CLIENT_MATCH" >> $A
  host "$SERVER_MATCH"
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-420}" "$CLIENT" \
  -- $R-alice:0:"-TestUser=alice -TestPass=x" -- $R-bob:3:"-TestUser=bob -TestPass=x" -- $R-carol:6:"-TestUser=carol -TestPass=x" 2>&1 | grep -v Segmentation
wait
rm -rf work/logs/$R-shots; mkdir -p work/logs/$R-shots
for n in alice bob carol; do
  find work/run/$R-$n work/run/$R-$n.prefix -path '*Screenshots*' -name '*.png' 2>/dev/null | sort | while read -r f; do
    cp "$f" "work/logs/$R-shots/$n-$(basename "$f")"; done
done
ls work/logs/$R-shots
for n in alice bob carol; do grep -h 'lua \(ok\|error\)' work/run/$R-$n/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | sed "s/^/$n: /" | cut -c1-300; done
for n in alice bob carol; do grep -h 'lobby settings\|match:' work/run/$R-$n/MOBA/Binaries/Win64/fangsboot.log 2>/dev/null | sed "s/^/$n boot: /" | cut -c1-200; done
grep -h 'lua \(ok\|error\)' $HOSTS/fangsctl.log 2>/dev/null | grep -v 'no match' | sed 's/^/server: /' | cut -c1-400
grep -h 'lobby\|captain\|match:' $HOSTS/fangshost.log 2>/dev/null | sed 's/^/server log: /' | cut -c1-200
