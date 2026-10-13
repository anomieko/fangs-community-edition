#!/usr/bin/env bash
# Main-menu test: one GPU-rendered headless client logs in; checks that the inventory owns the heroes and
# that the Play panel is shown and enabled. Own backend data, so local profiles are untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_menu.sh
set -u
cd "$(dirname "$0")/../.."
rm -f work/run/menu-store.json
A=work/run/menu/MOBA/Binaries/Win64/fangsctl_cmd.txt
CHECK='lua local function n(a) if type(a) == "table" then return #a end return a:GetArrayNum() end'\
' local gi=FindFirstOf("BP_MOBAInstance_C"); local inv=FindFirstOf("MOBAInventorySubsystem");'\
' local pp=gi.WB_MainMenuRef.WB_PlayMenu.PlayPanel;'\
' return string.format("heroes owned=%d available=%d playpanel visibility=%d enabled=%s",'\
' n(inv:GetItemsByClass(1, false)), n(gi.AvailableHeroes), pp:GetVisibility(), tostring(pp:GetIsEnabled()))'
BATTLE='lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; pm:CreateSessionDialog();'\
' local cl=pm.WB_CreateLobbyRef; local out={}'\
' for _, m in ipairs({"Battle", "Duel", "4vs4"}) do cl:SelectGameMode(m); out[#out+1]=m .. "=" .. cl.PlayerCount end return "custom lobby sizes: " .. table.concat(out, " ")'
( sleep 70; echo "$CHECK" >> $A; sleep 20; echo "$CHECK" >> $A; echo "$BATTLE" >> $A; echo 'shot showui' >> $A ) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 BACKEND_ARGS="--data $PWD/work/run/menu-store.json" \
  tools/run/headless.sh "${DURATION:-110}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- menu:0:"-TestUser=menu -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -E 'fangsctl\]|fangsboot\] custom' work/run/menu/MOBA/Binaries/Win64/ue4ss/UE4SS.log | cut -c30-260
