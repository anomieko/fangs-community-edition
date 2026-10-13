#!/usr/bin/env bash
# End-to-end test: backend + 2 GPU-rendered headless clients. alice creates a custom lobby,
# bob finds it in the lobby browser and joins. Logs end up in work/logs/.
set -u
cd "$(dirname "$0")/../.."
rm -rf work/hosts; rm -f work/logs/backend.jsonl backend/data/store.json
A=work/run/alice/MOBA/Binaries/Win64/fangsctl_cmd.txt; B=work/run/bob/MOBA/Binaries/Win64/fangsctl_cmd.txt
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; return gi.MapGameMode' \
    'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "playmenu ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Revival Test", "The Garden of Vermilia", FText("LE_Arena02_Map"), 2); return "create"' >> $A
  sleep 35
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; return gi.MapGameMode' \
    'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "playmenu ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:FindLobbies(); return "find"' >> $B
  sleep 10
  echo 'lua local n=0; for _,w in ipairs(FindAllOf("WB_GameSession_C") or {}) do if w:GetFullName():find("/Engine/Transient", 1, true) then w:BndEvt__SelectSessionBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); n=n+1; break end end; return "clicked "..n' >> $B
  sleep 25
  PICK='lua local pc=require("UEHelpers").GetPlayerController(); pc:UpdateChosenHero("%s"); return "picked %s"'
  printf "$PICK\n" FireMage FireMage >> $A
  printf "$PICK\n" LightningArcher LightningArcher >> $B
  sleep 10
  echo 'lua local pc=require("UEHelpers").GetPlayerController(); pc:StartMatch(); return "start"' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 tools/run/headless.sh "${DURATION:-200}" clients/playtest-main_v0_0_444 \
  -- alice:0:"-TestUser=alice -TestPass=x" -- bob:3:"-TestUser=bob -TestPass=x" 2>&1 | grep -v Segmentation
wait
