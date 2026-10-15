#!/usr/bin/env bash
# Solo end-to-end test: one GPU-rendered headless client creates a 1-player custom lobby, picks a hero
# and starts the match. Own backend data and game-server directory (work/run/solo-*), so local play is untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_solo.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
R=solo
rm -rf work/run/$R-hosts work/run/$R-store.json
A=work/run/solo/MOBA/Binaries/Win64/fangsctl_cmd.txt
WHERE='lua local gs=FindFirstOf("GameStateBase"); return "map: " .. (gs and gs:IsValid() and gs:GetFullName() or "none")'
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Solo Test", "The Garden of Vermilia", FText("LE_Arena02_Map"), 1); return "create"' >> $A
  sleep 40; echo "$WHERE" >> $A
  echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):UpdateChosenHero("Berserker"); return "picked"' >> $A
  sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  sleep 60; echo "$WHERE" >> $A
  echo 'lua local p=FindFirstOf("BP_PlayerChar_C"); return "pawn: " .. (p and p:IsValid() and p:GetFullName() or "none")' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-220}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- solo:0:"-TestUser=solo -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -E 'fangsctl\]' work/run/solo/MOBA/Binaries/Win64/ue4ss/UE4SS.log | cut -c30-220
