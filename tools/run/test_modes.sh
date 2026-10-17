#!/usr/bin/env bash
# The community patch's game-mode changes (docs/recon/community-build-modes.md), one player, headless:
#   MODE=train (default): the TRAINING tile. Checks the map (the floating island), the augment phase held through
#     lock-in and P until F6, no augment-phase immunity, the round after F6, the training dummies, then the player
#     leaves and the backend frees the server ("solo player left").
#   MODE=solo: a custom Solo lobby on Embersong as Wylde. Checks the base blockers (server and client), Wylde's gun in
#     the dummy phase, the kept dummies after F6, leaving the base and trying to walk back in, and a preset save
#     reaching the backend.
# Own backend data, game servers and instances (work/run/<RUN>-*); local play is untouched.
# Usage: [MODE=train|solo] [RUN=<name>] [CLIENT_DIR=clients/<build>] tools/run/test_modes.sh
set -u
cd "$(dirname "$0")/../.." || exit 1
MODE=${MODE:-train}
R=${RUN:-modes-$MODE}
CLIENT=${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}
cmp -s tools/ue4ss/Mods/FangsBoot/scripts/blockers.lua tools/ue4ss/Mods/FangsHost/scripts/blockers.lua \
  || { echo "FAIL: FangsBoot's and FangsHost's blockers.lua differ (server and players must place the same blockers)"; exit 1; }
rm -rf work/run/$R-hosts work/run/$R-store.json work/run/$R-records
P=work/run/$R-p/MOBA/Binaries/Win64/fangsctl_cmd.txt
HOSTS="work/run/$R-hosts/host-*/MOBA/Binaries/Win64"
LOAD="lua return dofile(\"Z:$PWD/tools/run/test_modes.lua\")"
host() { for h in $HOSTS; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
both() { echo "$1" >> $P; host "$1"; }
HERO=Berserker; [[ $MODE == solo ]] && HERO=Gunslinger
LOCKIN_BTN='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef;'\
' if h:ShowSelectHeroBtn() == 0 then h:BndEvt__ReadyBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "locked in" end return "lock in button hidden"'
(
  sleep 40
  if [[ $MODE == train ]]; then
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=0; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:PlayGameMode(); return "TRAINING tile"' >> $P
  else
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:CreateLobbyAndJoin("Solo Test", "Embersong", FText("LE_Arena02_Map"), 1); return "Solo lobby on Embersong"' >> $P
  fi
  sleep 45
  echo 'lua pcall(function() FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer(0) end); return "seat 0"' >> $P
  sleep 3
  echo 'lua pcall(function() FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer() end); return "launch"' >> $P
  host "$LOAD"; sleep 1; host 'lua return FCE_MODES.watch()'
  sleep 10
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'$HERO'", false);'\
' pcall(function() pc:UpdateChosenHero("'$HERO'") end); return "picked '$HERO'"' >> $P
  sleep 4; echo "$LOCKIN_BTN" >> $P
  sleep 60
  both "$LOAD"; sleep 2
  both 'lua return FCE_MODES.where()'; host 'lua return FCE_MODES.phase()'
  both 'lua return FCE_MODES.hero()'; both 'lua return FCE_MODES.dummies()'; both 'lua return FCE_MODES.blockers()'
  sleep 45   # past the game's own augment-phase time
  host 'lua return FCE_MODES.phase()'
  echo 'lua return FCE_MODES.lockin()' >> $P
  sleep 6; host 'lua return FCE_MODES.phase()'
  echo 'lua return FCE_MODES.reopen()' >> $P
  sleep 3; echo 'lua return FCE_MODES.lockin()' >> $P
  sleep 3; host 'lua return FCE_MODES.phase()'; both 'lua return FCE_MODES.hero()'
  if [[ $MODE == solo ]]; then
    echo 'lua return FCE_MODES.save("{\"Gunslinger\":{\"CurrentLoadoutIndex\":1,\"Loadout1\":{\"Name\":\"Test\",\"Augments\":[]}}}")' >> $P
    sleep 3
  fi
  echo 'lua return FCE_MODES.f6()' >> $P
  sleep 15; host 'lua return FCE_MODES.phase()'; both 'lua return FCE_MODES.dummies()'
  sleep 20; host 'lua return FCE_MODES.phase()'; both 'lua return FCE_MODES.dummies()'; both 'lua return FCE_MODES.hero()'
  if [[ $MODE == solo ]]; then
    host 'lua return FCE_MODES.leave()'
    sleep 3; both 'lua return FCE_MODES.hero()'
    host 'lua return FCE_MODES.enter()'
    sleep 2; both 'lua return FCE_MODES.hero()'
  fi
  echo 'lua GPS = StaticFindObject("/Script/Engine.Default__GameplayStatics"); GPS:OpenLevel(FindFirstOf("BP_MOBAInstance_C"), FName("LE_MainMenu_Map"), true, ""); return "left the game"' >> $P
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-400}" "$CLIENT" -- $R-p:0:"-TestUser=player -TestPass=x" 2>&1 | grep -v Segmentation
wait
echo "== client (fangsctl, fangsboot)"
grep -h 'lua \(ok\|error\)' work/run/$R-p/MOBA/Binaries/Win64/fangsctl.log | cut -c1-300
grep -h 'base blockers\|F6' work/run/$R-p/MOBA/Binaries/Win64/fangsboot.log | cut -c1-200
echo "== game server (fangsctl, fangshost)"
grep -h 'lua \(ok\|error\)' $HOSTS/fangsctl.log 2>/dev/null | grep -v 'server lobby' | cut -c1-300
grep -h 'training\|wylde\|presets\|base blockers\|modes:' $HOSTS/fangshost.log 2>/dev/null | cut -c1-200
echo "== round events, item select (game server, world seconds)"
cat $HOSTS/modeswatch.log 2>/dev/null | cut -c1-200
echo "== backend"
grep -h '"stopping"\|preset\|"ready"\|createDS' work/logs/$R-p-backend.jsonl 2>/dev/null | cut -c1-240 | tail -15
[[ $MODE == solo ]] && python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print('stored presets:', [ (u, r.get('PROFILE_LOADOUT_KEY')) for u, r in d.get('player_records', {}).items() if 'PROFILE_LOADOUT_KEY' in r])" work/run/$R-store.json
