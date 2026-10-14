#!/usr/bin/env bash
# Main-menu test: one GPU-rendered headless client logs in; checks that the inventory owns the heroes and
# cosmetics, that the Play panel is shown and enabled, and the FangsBoot menu cleanup (no Battle Pass/Store
# tabs, no Discord banner, players online in place of missions). Screenshots of Home, Leaderboard and
# Collection > Artifacts end up in work/logs/menu-shots/. Own backend data, so local profiles are untouched.
# Usage: CLIENT_DIR=clients/<build> [MOVIES=1] tools/run/test_menu.sh   (MOVIES=1 keeps the menu background video)
#   STORE=<backend store.json> PLAYER=<name>: start from a copy of that data (e.g. after test_join.sh END=1) and
#   log in as that player (test password "x") to see their profile, match history and the leaderboard.
set -u
cd "$(dirname "$0")/../.."
rm -f work/run/menu-store.json
[[ -n ${STORE:-} ]] && cp "$STORE" work/run/menu-store.json
A=work/run/menu/MOBA/Binaries/Win64/fangsctl_cmd.txt
GI='local function n(a) if type(a) == "table" then return #a end return a:GetArrayNum() end'\
' local gi=FindFirstOf("BP_MOBAInstance_C"); local menu=gi.WB_MainMenuRef; local pm=menu.WB_PlayMenu;'
CHECK="lua $GI"' local inv=FindFirstOf("MOBAInventorySubsystem"); local pp=pm.PlayPanel;'\
' return string.format("heroes owned=%d available=%d playpanel visibility=%d enabled=%s",'\
' n(inv:GetItemsByClass(1, false)), n(gi.AvailableHeroes), pp:GetVisibility(), tostring(pp:GetIsEnabled()))'
COSMETICS="lua $GI"' local inv=FindFirstOf("MOBAInventorySubsystem"); local out={}'\
' for _, c in ipairs({{"skins",2},{"mounts",5},{"stickers",6},{"sigils",8},{"banners",9},{"titles",10}}) do'\
' out[#out+1]=c[1] .. "=" .. n(inv:GetItemsByClass(c[2], false)) end'\
' return "owned cosmetics: " .. table.concat(out, " ")'
MENU="lua $GI"' local cards=pm.WB_Missions.MissionsSizeBox:GetParent()'\
' return string.format("menu: battlepass=%d store=%d discord=%d missionbtn=%d missions=%d header=\"%s\" bkg video playing=%s",'\
' menu.BattlePassTab:GetVisibility(), menu.ShopTab:GetVisibility(), pm.PromoButton:GetVisibility(),'\
' menu.MissionBtn:GetVisibility(), cards:GetVisibility(), cards:GetParent():GetChildAt(0):GetChildAt(0):GetText():ToString(),'\
' tostring(menu.BkgMediaPlayer and menu.BkgMediaPlayer:IsPlaying()))'
STORE="lua $GI"' menu:SelectMainMenuTab(5) return "store tab requested"'
PAGE="lua $GI"' return "shown page " .. menu.MainMenuSwitcher:GetActiveWidgetIndex() .. " (0 = home: the redirect works)"'
BATTLE="lua $GI"' pm.BP_MOBAInstanceRef=gi; pm:CreateSessionDialog();'\
' local cl=pm.WB_CreateLobbyRef; local out={}'\
' for _, m in ipairs({"Battle", "Duel", "4vs4"}) do cl:SelectGameMode(m); out[#out+1]=m .. "=" .. cl.PlayerCount end return "custom lobby sizes: " .. table.concat(out, " ")'
(
  sleep 70; echo "$CHECK" >> $A; sleep 20
  echo "$CHECK" >> $A; echo "$COSMETICS" >> $A; echo "$MENU" >> $A; echo 'shot showui' >> $A; sleep 3
  echo "lua $GI menu:SelectMainMenuTab(3)" >> $A; sleep 4; echo 'shot showui' >> $A; sleep 2
  echo "lua $GI menu:SelectMainMenuTab(2)" >> $A; sleep 4; echo 'shot showui' >> $A; sleep 2
  echo "lua $GI menu:SelectMainMenuTab(1) menu.WB_Collection:SelectCollectionMenu(1)" >> $A; sleep 4
  echo 'shot showui' >> $A; sleep 2
  echo "$STORE" >> $A; sleep 2; echo "$PAGE" >> $A; echo "lua $GI menu:SelectMainMenuTab(0)" >> $A; sleep 2; echo "$BATTLE" >> $A; echo 'shot showui' >> $A
) &
[[ ${MOVIES:-0} == 1 ]] && nomovies=0 || nomovies=1
UE4SS=1 GPU=1 NOMOVIES=$nomovies BACKEND=127.0.0.1:8080 RUN_BACKEND=1 BACKEND_ARGS="--data $PWD/work/run/menu-store.json" \
  tools/run/headless.sh "${DURATION:-130}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- menu:0:"-TestUser=${PLAYER:-menu} -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -E 'fangsctl\]|fangsboot\] (custom|menu)' work/run/menu/MOBA/Binaries/Win64/ue4ss/UE4SS.log | cut -c30-400
rm -rf work/logs/menu-shots; mkdir -p work/logs/menu-shots
find work/run/menu work/run/menu.prefix -path '*Screenshots*' -name '*.png' -exec cp {} work/logs/menu-shots/ \; 2>/dev/null
ls work/logs/menu-shots
