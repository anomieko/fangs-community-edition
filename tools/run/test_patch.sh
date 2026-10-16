#!/usr/bin/env bash
# Patch pak test (docs/PATCHING.md): builds the patch pak, then alice and bob play a custom match on opposite teams
# with it on both clients and the game server.
#   1. Every process (alice, bob, the game server) reports the patched class defaults it loaded: all as patched means
#      the pak is mounted and wins over the game's own pak (a control run without it shows the game's values).
#   2. The game server logs every CC and ability-lock effect on both heroes as it starts and ends (patchwatch.log),
#      while: bob is put in alice's line of fire and alice casts CAST_A; then alice in bob's and bob casts CAST_B
#      (twice: far along the line, then right next to the caster); alice casts her ult (mana filled); bob uses LMB.
# Defaults test the ccrevert patch: alice = Somnia (ult lock 0.5 s instead of the whole tether; Allure charms bob),
# bob = Rowan (no ability lock on LMB; Dourling Dive stuns alice).
# Own backend data, game servers and instances; local play is untouched.
# Usage: [PATCHES="<patch> ..." | PATCHES=none] [CLIENT_DIR=clients/<build>] tools/run/test_patch.sh
#   Env: HERO_A/HERO_B (DT_Heroes rows), ULT_A, LMB_B, CAST_A, CAST_B (ability class name parts), RUN, DURATION,
#        CHECK="<patch> ..." (whose values check() expects; default PATCHES, or ccrevert in a control run),
#        AIM_A=<range>: CAST_A lands at alice's pointer (e.g. Brutus' Earthquake, 1350): bob is put there instead.
#        STEPS=<file>: bash steps run after the CC casts (helpers host, \$A, \$B as in this script).
#        PRE_STEPS=<file>: bash steps run in the arena before the round (e.g. equip items).
#        CUE_A=<class>: the gameplay cue actor CAST_A's hit spawns on the clients, counted after each cast
#        (default Allure's charm visual, BP_GC_BookMage_Skill4CharmVFX_C; CUE_A= to skip).
#   e.g. Brutus' Earthquake centre (root -> stun): HERO_A=Berserker CAST_A=Berserker_Skill2 AIM_A=1350 ULT_A=Berserker_Skill3
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-patch}
CLIENT=${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}
PATCHES=${PATCHES:-ccrevert}
HERO_A=${HERO_A:-BookMage}; ULT_A=${ULT_A:-BookMage_RNEw}; CAST_A=${CAST_A:-BookMage_Skill4}
CUE_A=${CUE_A-BP_GC_BookMage_Skill4CharmVFX_C}   # a cue actor CAST_A's hit should spawn on the clients ("" = no check)
HERO_B=${HERO_B:-WoodenSword}; LMB_B=${LMB_B:-WoodenSword_LMB}; CAST_B=${CAST_B:-WoodenSword_Skill1}
rm -rf work/run/$R-hosts work/run/$R-store.json work/run/$R-paks work/run/$R-built; mkdir -p work/run/$R-paks

# The pak is built in every run: its build output says which class defaults check() must find patched. A control
# run (PATCHES=none) doesn't load it, and shows the game's own values.
built=${CHECK:-$PATCHES}; [[ $built == none ]] && built=ccrevert
OUT=$PWD/work/run/$R-built/FangsCE_P.pak tools/patch/build.sh "$CLIENT" $built > work/run/$R-build.txt || { cat work/run/$R-build.txt; exit 1; }
grep -v '^  ' work/run/$R-build.txt
if [[ $PATCHES == none ]]; then echo "control run: no patch pak loaded"; else cp work/run/$R-built/FangsCE_P.pak work/run/$R-paks/; fi
python3 -I - work/run/$R-build.txt work/run/$R-want.lua <<'PY'
import re, sys
rows, asset = [], None
for line in open(sys.argv[1]):
    if line.startswith('MOBA/Content/'):
        asset = '/Game/' + line.strip()[len('MOBA/Content/'):]
    m = re.match(r'  Default__(.+?)_C\.(.+): (.+) -> (.+)$', line.rstrip('\n'))
    if m and asset:
        rows.append('  { "%s", "%s", "%s", %s },' % (asset, m[1], m[2], float(m[4])))
open(sys.argv[2], 'w').write('FCE_PATCH_WANT = {\n' + '\n'.join(rows) + '\n}\n')
PY
export FANGS_PAKS=$PWD/work/run/$R-paks   # empty folder in a control run

A=work/run/$R-alice/MOBA/Binaries/Win64/fangsctl_cmd.txt; B=work/run/$R-bob/MOBA/Binaries/Win64/fangsctl_cmd.txt
HOSTS="work/run/$R-hosts/host-*/MOBA/Binaries/Win64"
LOAD="lua dofile(\"Z:$PWD/work/run/$R-want.lua\") return dofile(\"Z:$PWD/tools/run/test_patch.lua\")"
WHERE='lua local gs=FindFirstOf("GameStateBase"); local p=FindFirstOf("BP_PlayerChar_C");'\
' return "map=" .. (gs:GetFullName():match("Maps/([%w_]+)") or "?") .. " pawn=" .. (p and p:IsValid() and p:GetFName():ToString() or "none")'
LOCKIN_BTN='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef;'\
' if h:ShowSelectHeroBtn() == 0 then h:BndEvt__ReadyBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "locked in" end return "lock in button hidden"'
host() { for h in $HOSTS; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
pick() {
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$2"'", false); pcall(function() pc:UpdateChosenHero("'"$2"'") end); return "picked '"$2"'"' >> "$1"
}
(
  # lobby: alice creates it, bob joins from the lobby list, opposite teams (even seats team A, odd seats team B)
  sleep 40
  echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:CreateLobbyAndJoin("Patch Test", "Embersong", FText("LE_Arena02_Map"), 8); return "alice: create lobby"' >> $A
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
  sleep 12; pick $A $HERO_A; pick $B $HERO_B
  sleep 4; echo "$LOCKIN_BTN" >> $A; echo "$LOCKIN_BTN" >> $B
  sleep 60; echo "$WHERE" >> $A; echo "$WHERE" >> $B
  # in the arena: what each process loaded, then the effects log
  echo "$LOAD" >> $A; echo "$LOAD" >> $B; host "$LOAD"
  sleep 2
  echo 'lua return FCE_PATCH.check()' >> $A; echo 'lua return FCE_PATCH.check()' >> $B; host 'lua return FCE_PATCH.check()'
  host 'lua return FCE_PATCH.watch()'
  [[ -n ${PRE_STEPS:-} ]] && source "$PRE_STEPS"   # before the round, e.g. equip items (tools/run/test_rowan.pre)
  sleep "${ROUND_WAIT:-90}"   # until the round is on: no casts before it
  # CC: the target in the caster's line of fire (far along it, then right next to the caster)
  for d in 300 60; do
    if [[ -n ${AIM_A:-} ]]; then host "lua return FCE_PATCH.aim(\"alice\", \"bob\", $AIM_A)"
    else host "lua return FCE_PATCH.face(\"alice\", \"bob\", $d)"; fi
    sleep 0.5; echo "lua return FCE_PATCH.fire(\"$CAST_A\")" >> $A
    if [[ -n $CUE_A ]]; then sleep 1.5; echo "lua return FCE_PATCH.count(\"$CUE_A\")" >> $A; echo "lua return FCE_PATCH.count(\"$CUE_A\")" >> $B; fi
    sleep 6; host "lua return FCE_PATCH.face(\"bob\", \"alice\", $d)"
    sleep 0.5; echo "lua return FCE_PATCH.fire(\"$CAST_B\")" >> $B
    sleep 6
  done
  [[ -n ${STEPS:-} ]] && source "$STEPS"   # a hero's own extra steps (e.g. tools/run/test_fiorne.steps)
  # self-locks: alice's ult (mana filled first: ults cost mana), then bob's LMB (it stays active: no button release)
  host 'lua return FCE_PATCH.fill("alice")'
  sleep 2; echo "lua return FCE_PATCH.fire(\"$ULT_A\")" >> $A
  sleep 8; echo "lua return FCE_PATCH.fire(\"$LMB_B\")" >> $B
  sleep 5; host 'lua return FCE_PATCH.check()'
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-420}" "$CLIENT" \
  -- $R-alice:0:"-TestUser=alice -TestPass=x" -- $R-bob:3:"-TestUser=bob -TestPass=x" 2>&1 | grep -v Segmentation
wait
echo "== patch paks in the game copies"
ls work/run/$R-alice/MOBA/Content/Paks work/run/$R-hosts/host-*/MOBA/Content/Paks 2>/dev/null | grep -v '^$'
for n in alice bob; do grep -h 'lua \(ok\|error\)' work/run/$R-$n/MOBA/Binaries/Win64/fangsctl.log | sed "s/^/$n: /" | cut -c1-260; done
grep -h 'lua \(ok\|error\)' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | grep -v 'server lobby' | sed 's/^/server: /' | cut -c1-260
echo "== effects on the heroes (game server, seconds since the first entry)"
cat work/run/$R-hosts/host-*/MOBA/Binaries/Win64/patchwatch.log 2>/dev/null
