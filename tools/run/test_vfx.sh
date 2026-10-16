#!/usr/bin/env bash
# VFX lab: one GPU-rendered headless client plays HERO in a solo custom match; FangsCtl (tools/run/test_vfx.lua)
# spawns Niagara systems next to the hero and casts abilities, with a screenshot after each step:
# work/logs/vfx-<RUN>/. Own backend data and game servers; local play untouched. FANGS_PAKS=<dir> loads patch paks.
#   MODE=zoey     Zoey's ult systems side by side (default and Hellhound), then her ult with the Hellhound VFX pack
#   MODE=astrada  Astrada's ally and enemy cage systems: no colour, the pack's (0,0,0,1), test colours; then her cage
#   MODE=shield   Ethryn's shield effect at scale 1 and at the patch's (1, 0.85, 0.9); then her shield (E)
# Usage: MODE=zoey|astrada|shield [RUN=<name>] [FANGS_PAKS=<dir>] tools/run/test_vfx.sh
set -u
cd "$(dirname "$0")/../.."
MODE=${MODE:?set MODE=zoey, astrada or shield}
case $MODE in zoey) HERO=CatSupp ;; astrada) HERO=FireMage ;; shield) HERO=ShieldGirl ;; *) echo "unknown MODE $MODE"; exit 2 ;; esac
R=${RUN:-vfx-$MODE}
rm -rf work/run/$R-hosts work/run/$R-store.json
A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
L='lua return V.'
step() { echo "$L$1" >> $A; sleep "${2:-1}"; echo 'shot' >> $A; }
HOSTS="work/run/$R-hosts/host-*/MOBA/Binaries/Win64"
host() { for h in $HOSTS; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("VFX Test", "The Garden of Vermilia", FText("LE_Arena02_Map"), 1); return "create"' >> $A
  sleep 40
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$HERO"'", false);'\
' pcall(function() pc:UpdateChosenHero("'"$HERO"'") end); return "picked '"$HERO"'"' >> $A
  sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  sleep 150
  echo 'lua local n=0 for _, w in ipairs(FindAllOf("WB_LobbyMenu_C") or {}) do if w:IsValid() and w:IsInViewport() then w:RemoveFromParent(); n=n+1 end end return "removed lobby screen x" .. n' >> $A
  echo "lua return dofile(\"Z:$PWD/tools/run/test_vfx.lua\")" >> $A
  host "lua return dofile(\"Z:$PWD/tools/run/test_vfx.lua\")"
  sleep 2; echo 'shot' >> $A
  if [[ $MODE == zoey ]]; then
    step 'zoey()' 1; sleep 1; echo 'shot' >> $A; step 'clear()' 1
    step 'pack("HellhoundCatSuppRed")' 1
    host 'lua return V.fill()'; sleep 1
    echo "${L}fire(\"CatSupp_Skill3\")" >> $A; sleep 0.4; echo 'shot' >> $A; sleep 0.6; echo 'shot' >> $A; sleep 1; echo 'shot' >> $A
  elif [[ $MODE == shield ]]; then
    step 'shield()' 0.6; sleep 0.6; echo 'shot' >> $A; step 'clear()' 1
    echo "${L}fire(\"ShieldGirl_Skill4\")" >> $A; sleep 0.3; echo 'shot' >> $A; sleep 0.4; echo 'shot' >> $A
  else
    step 'cage(nil, nil)' 1; step 'clear()' 1
    step 'cage({0,0,0,1}, {0,0,0,1})' 1; step 'clear()' 1
    step 'cage({1,0.45,0.02,1}, {1,0.02,0.01,1})' 1; step 'clear()' 1
    step 'cage({15,6,0.3,1}, {15,0.3,0.1,1})' 1; step 'clear()' 1
    host 'lua return V.fill()'; sleep 1
    echo "${L}fire(\"Firemage_E\")" >> $A; sleep 0.6; echo 'shot' >> $A; sleep 1; echo 'shot' >> $A
  fi
  sleep 3; echo 'shot showui' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-330}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=vfxer -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -h 'lua \|exec' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | cut -c21-300
grep -h 'lua ' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | grep -v 'server lobby' | sed 's/^/server: /' | cut -c1-200
rm -rf work/logs/vfx-$R; mkdir -p work/logs/vfx-$R
cp work/run/$R.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png work/logs/vfx-$R/ 2>/dev/null
ls work/logs/vfx-$R
