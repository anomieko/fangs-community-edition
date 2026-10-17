#!/usr/bin/env bash
# Unreleased heroes picked in a custom lobby the way players do it (FangsBoot's toggle in hero select): alice creates
# the lobby through the mode chooser's "create custom" card, bob joins it from the lobby list (PLAY, as players do).
# Both open the unreleased group with the toggle and click a hero button (alice Priest, bob Warlock), lock in, and the
# owner launches. Logged at each step: each client's game mode, hero select's filter buttons and shown heroes, what
# the click did (Ready button, the player state's hero), the server's lobby picks and the pawns spawned in the arena.
# Own backend data and game servers; local play is untouched.
# Usage: [RUN=<name>] [CLIENT_DIR=clients/<build>] tools/run/test_unreleased_pick.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-unrelpick}
CLIENT=${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}
rm -rf work/run/$R-hosts work/run/$R-store.json
A=work/run/$R-alice/MOBA/Binaries/Win64/fangsctl_cmd.txt; B=work/run/$R-bob/MOBA/Binaries/Win64/fangsctl_cmd.txt
HOSTS="work/run/$R-hosts/host-*/MOBA/Binaries/Win64"
host() { for h in $HOSTS; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
HS='local gi=FindFirstOf("BP_MOBAInstance_C"); local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local hs=pc.WB_LobbyHeroSelectRef'
INFO="lua $HS"'; local t={} hs.HeroButtonList:ForEach(function(_, e) local b=e:get() if b:GetVisibility()==0 then t[#t+1]=b.HeroType:ToString() end end)'\
' return "mode " .. gi.MapGameMode .. ", " .. hs.FilterBtnPanel:GetChildrenCount() .. " filter buttons, heroes: " .. table.concat(t, ",")'
TOGGLE="lua $HS"'; local p=hs.FilterBtnPanel; local b=p:GetChildAt(p:GetChildrenCount()-1)'\
' if b.ClassFilter ~= 4 then return "no unreleased toggle (last filter " .. b.ClassFilter .. ")" end'\
' b:BndEvt__WB_FilterClassButton_FilterButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "clicked the unreleased toggle"'
click() {   # a hero button, as a player clicks it
  echo "lua $HS"'; local f hs.HeroButtonList:ForEach(function(_, e) local b=e:get() if not f and b:GetVisibility()==0 and b.HeroType:ToString()=="'"$2"'" then f=b end end)'\
' if not f then return "no '"$2"' button" end f:BndEvt__CharacterBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "clicked '"$2"'"' >> "$1"
}
STATE="lua $HS"'; local ok, h = pcall(function() return pc.PlayerState.HeroType:ToString() end)'\
' return "after the click: player state hero " .. tostring(ok and h or "?") .. ", Ready enabled " .. tostring(hs.ReadyBtn:GetIsEnabled()) .. ", profile hero " .. tostring(select(2, pcall(function() return FindFirstOf("AccelByte").SavedPlayerInfo.Hero:ToString() end)))'
LOCKIN_BTN='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef;'\
' if h:ShowSelectHeroBtn() == 0 then h:BndEvt__ReadyBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "locked in" end return "lock in button hidden"'
PICKS='lua local t={} for _, p in ipairs(FindAllOf("PS_LobbyHero_PlayerState_C") or {}) do if p:IsValid() then'\
' t[#t+1]=p:GetPlayerName():ToString() .. "=" .. p.HeroType:ToString() end end return "server lobby picks: " .. table.concat(t, " ")'
PAWNS='lua local t={} for _, p in ipairs(FindAllOf("BP_PlayerChar_C") or {}) do if p:IsValid() then'\
' t[#t+1]=p:GetClass():GetFName():ToString() end end return "server arena pawns: " .. table.concat(t, " ")'
(
  sleep 40
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi:ShowChoseGameMode(); gi.WB_ChoseGameModeRef:SetCreateCustomMode();'\
' local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; local m=gi.MapGameMode;'\
' pm:CreateLobbyAndJoin("Unreleased Pick", "Embersong", FText("LE_Arena02_Map"), 8); return "alice: create custom lobby (mode " .. m .. ")"' >> $A
  sleep 50
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi:ShowChoseGameMode(); gi.WB_ChoseGameModeRef:SetJoinCustomMode(); return "bob: join a lobby"' >> $B
  sleep 2
  echo 'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "bob: PLAY"' >> $B
  sleep 10
  echo 'lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu; if pm.LobbyList:GetChildrenCount() == 0 then return "bob: no lobby to join" end'\
' pm.LobbyList:GetChildAt(0):BndEvt__SelectSessionBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "bob: joined the lobby"' >> $B
  sleep 30
  echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer(0); return "alice: seat 0"' >> $A
  echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer(1); return "bob: seat 1"' >> $B
  sleep 10
  echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "alice: launch"' >> $A
  sleep 12; echo "$INFO" >> $A; echo "$INFO" >> $B
  sleep 1; echo "$TOGGLE" >> $A; echo "$TOGGLE" >> $B
  sleep 3; echo "$INFO" >> $A; echo "$INFO" >> $B; echo 'shot showui' >> $A
  sleep 1; click $A Priest; click $B Warlock
  sleep 3; echo "$STATE" >> $A; echo "$STATE" >> $B; host "$PICKS"; echo 'shot showui' >> $A; echo 'shot showui' >> $B
  sleep 1; echo "$LOCKIN_BTN" >> $A; echo "$LOCKIN_BTN" >> $B
  sleep 60; host "$PAWNS"; echo 'shot showui' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-260}" "$CLIENT" \
  -- $R-alice:0:"-TestUser=alice -TestPass=x" -- $R-bob:3:"-TestUser=bob -TestPass=x" 2>&1 | grep -v Segmentation
wait
for n in alice bob; do grep -h 'lua \(ok\|error\)' work/run/$R-$n/MOBA/Binaries/Win64/fangsctl.log | sed "s/^/$n: /" | cut -c1-300; done
grep -h 'lua \(ok\|error\)' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | sed 's/^/server: /' | cut -c1-300
for n in alice bob; do grep -h 'unreleased\|lobby\|loop error' work/run/$R-$n/MOBA/Binaries/Win64/fangsboot.log | sed "s/^/$n fangsboot: /" | cut -c1-200; done
rm -rf work/logs/$R-shots; mkdir -p work/logs/$R-shots
for n in alice bob; do for f in work/run/$R-$n.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png; do
  [[ -f $f ]] && cp "$f" work/logs/$R-shots/$n-$(basename "$f"); done; done
echo "screenshots: $(ls work/logs/$R-shots | wc -l) in work/logs/$R-shots"
