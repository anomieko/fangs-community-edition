#!/usr/bin/env bash
# Hero showcase: one GPU-rendered headless client plays HERO in a solo custom match (an unreleased hero is added
# to this test's own copy of the seed), and once the round is on fires each of the hero's abilities in turn,
# with a screenshot (without UI) after each: work/logs/hero-<HERO>/. Own backend data and game servers; local play untouched.
# Usage: HERO=<DT_Heroes row> [CLIENT_DIR=clients/<build>] tools/run/test_hero.sh
set -u
cd "$(dirname "$0")/../.."
HERO=${HERO:?set HERO, e.g. HERO=Warlock}
R=${RUN:-show-$HERO}
rm -rf work/run/$R-hosts work/run/$R-store.json
python3 - "$HERO" work/run/$R-seed.json <<'PY'
import json, sys
d = json.load(open('backend/seed/game_records.json'))
for v in d['FANGSConfig'].values():
    if isinstance(v, dict) and sys.argv[1] not in v['AvailableHeroes']:
        v['AvailableHeroes'].append(sys.argv[1])
json.dump(d, open(sys.argv[2], 'w'))
PY
A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
PAWN='local gi=FindFirstOf("BP_MOBAInstance_C"); local p=StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0).Pawn'
# the hero's own abilities (class name contains the hero id), in the order the pawn has them
OWN="$PAWN"' local own={} p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e) local a=e:get().Ability'\
' if a and a:IsValid() and a:GetClass():GetFName():ToString():lower():find(("'"$HERO"'"):lower(), 1, true) then own[#own+1]=a:GetClass() end end)'
fire() {   # fire() <n>: activate the hero's n-th ability
  echo "lua $OWN"' local c=own['"$1"'] if not c then return "no ability '"$1"'" end'\
' return "ability '"$1"' " .. c:GetFName():ToString() .. " -> " .. tostring(p.AbilitySystemComponent:TryActivateAbilityByClass(c, true))' >> $A
}
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Hero Test", "The Garden of Vermilia", FText("LE_Arena02_Map"), 1); return "create"' >> $A
  sleep 40
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$HERO"'", false);'\
' pcall(function() pc:UpdateChosenHero("'"$HERO"'") end); return "picked '"$HERO"'"' >> $A
  sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  sleep 150
  echo "lua $OWN"' local t={} for i, c in ipairs(own) do t[#t+1]=i .. "=" .. c:GetFName():ToString() end return "own abilities: " .. table.concat(t, ", ")' >> $A
  # a solo match started this way keeps the lobby screen up over the arena: take it away
  echo 'lua local n=0 for _, w in ipairs(FindAllOf("WB_LobbyMenu_C") or {}) do if w:IsValid() and w:IsInViewport() then w:RemoveFromParent(); n=n+1 end end return "removed lobby screen x" .. n' >> $A
  echo 'shot showui' >> $A
  for i in 1 2 3 4 5 6 7 8 9; do sleep 4; fire $i; sleep 1; echo 'shot' >> $A; done   # without UI: the hero and effects
  sleep 3; echo 'shot showui' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --seed $PWD/work/run/$R-seed.json" \
  tools/run/headless.sh "${DURATION:-300}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=shower -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -h 'lua \|exec' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | cut -c21-300
rm -rf work/logs/hero-$HERO; mkdir -p work/logs/hero-$HERO
cp work/run/$R.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png work/logs/hero-$HERO/ 2>/dev/null
ls work/logs/hero-$HERO
