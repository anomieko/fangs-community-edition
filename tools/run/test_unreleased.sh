#!/usr/bin/env bash
# Unreleased heroes in the menus (FangsBoot): one GPU-rendered headless client checks Inventory > Heroes (separate
# "UNRELEASED HEROES" section, an unreleased hero's page opens from its card), then in a custom lobby's hero
# select: released heroes by default, the toggle shows the unreleased ones, picking one shows the notice.
# Screenshots in work/logs/unreleased-shots/. Own backend data and game servers; local play is untouched.
# Usage: [CLIENT_DIR=clients/<build>] tools/run/test_unreleased.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-unrel}
rm -rf work/run/$R-hosts work/run/$R-store.json
A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
GI='local gi=FindFirstOf("BP_MOBAInstance_C"); local menu=gi.WB_MainMenuRef'
INV="lua $GI"' local h=menu.WB_Collection.WB_Heroes; local list=h.HeroButtonList; local scroll=list:GetParent(); local wrap'\
' for i=0, scroll:GetChildrenCount()-1 do local w=scroll:GetChildAt(i) if w:GetFName():ToString()=="FCE_UnreleasedHeroes" then wrap=w end end'\
' local function names(p) local t={} for i=0, p:GetChildrenCount()-1 do t[#t+1]=p:GetChildAt(i).HeroType:ToString() end return table.concat(t, ",") end'\
' return "inventory: released [" .. names(list) .. "] unreleased [" .. (wrap and names(wrap) or "NO SECTION") .. "] counter " .. h.OwnedHeroesTxt:GetText():ToString() .. h.TotalHeroesTxt:GetText():ToString()'
CARD="lua $GI"' local scroll=menu.WB_Collection.WB_Heroes.HeroButtonList:GetParent()'\
' for i=0, scroll:GetChildrenCount()-1 do local w=scroll:GetChildAt(i) if w:GetFName():ToString()=="FCE_UnreleasedHeroes" then'\
' for j=0, w:GetChildrenCount()-1 do local b=w:GetChildAt(j) if b.HeroType:ToString()=="Warlock" then'\
' b:BndEvt__WB_HeroButton_CharacterBtn_K2Node_ComponentBoundEvent_3_OnButtonClickedEvent__DelegateSignature() return "clicked Warlock card" end end end end return "no Warlock card"'
SELECT='lua local hs=FindFirstOf("BP_PC_Lobby_PlayerController_C").WB_LobbyHeroSelectRef; local t={}'\
' hs.HeroButtonList:ForEach(function(_, e) local b=e:get() if b:GetVisibility()==0 then t[#t+1]=b.HeroType:ToString() end end)'\
' return "hero select (" .. hs.FilterBtnPanel:GetChildrenCount() .. " filter buttons): " .. table.concat(t, ",")'
TOGGLE='lua local hs=FindFirstOf("BP_PC_Lobby_PlayerController_C").WB_LobbyHeroSelectRef; local p=hs.FilterBtnPanel; local b=p:GetChildAt(p:GetChildrenCount()-1)'\
' b:BndEvt__WB_FilterClassButton_FilterButton_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "clicked toggle (filter " .. b.ClassFilter .. ")"'
PICK='lua local hs=FindFirstOf("BP_PC_Lobby_PlayerController_C").WB_LobbyHeroSelectRef; local f'\
' hs.HeroButtonList:ForEach(function(_, e) local b=e:get() if not f and b:GetVisibility()==0 and b.HeroType:ToString()=="Priest" then f=b end end)'\
' if not f then return "no Priest button" end f:BndEvt__CharacterBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "clicked Priest"'
NOTICE='lua local n=0 for _, w in ipairs(FindAllOf("WB_Confirm_C") or {}) do if w:IsValid() and w:IsInViewport() then n=n+1 end end return "notices on screen: " .. n'
(
  sleep 70
  echo "lua $GI menu:SelectMainMenuTab(1) menu.WB_Collection:SelectCollectionMenu(0) return \"inventory\"" >> $A
  sleep 4; echo "$INV" >> $A; echo 'shot showui' >> $A
  sleep 2; echo "$CARD" >> $A; sleep 4; echo 'shot showui' >> $A
  echo "lua $GI menu:SelectMainMenuTab(0) return \"home\"" >> $A
  sleep 3
  printf '%s\n' "lua $GI gi.MapGameMode=4; local pm=menu.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; pm:CreateLobbyAndJoin(\"Unreleased Test\", \"Embersong\", FText(\"LE_Arena02_Map\"), 2); return \"create\"" >> $A
  sleep 45; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "launch"' >> $A
  sleep 10; echo "$SELECT" >> $A; echo 'shot showui' >> $A
  sleep 2; echo "$TOGGLE" >> $A; sleep 3; echo "$SELECT" >> $A; echo 'shot showui' >> $A
  sleep 2; echo "$PICK" >> $A; sleep 3; echo "$NOTICE" >> $A; echo 'shot showui' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-190}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=unrel -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -h 'lua \|exec' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | grep -v 'exec: shot' | cut -c21-600
grep -h 'unreleased' work/run/$R/MOBA/Binaries/Win64/fangsboot.log | cut -c21-300
rm -rf work/logs/unreleased-shots; mkdir -p work/logs/unreleased-shots
cp work/run/$R.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png work/logs/unreleased-shots/ 2>/dev/null
ls work/logs/unreleased-shots | wc -l
