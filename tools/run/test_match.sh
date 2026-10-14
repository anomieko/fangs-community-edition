#!/usr/bin/env bash
# Match-result test: one GPU-rendered headless client creates a 1-player custom lobby, picks a hero and starts
# the match; the game server then ends it (the game's surrender: team B defeated). Checks that FangsHost saved
# the result and the backend turned it into match history, levels and wins (and screenshots the end screen and
# the profile). Own backend data and game-server directory, so local play is untouched.
# Usage: CLIENT_DIR=clients/<build> [HERO=<DT_Heroes row>] [MAP=<level, default LE_Arena02_Map>] tools/run/test_match.sh
#   HERO: play that hero (default Berserker); one the seed doesn't offer (an unreleased hero) is added to this
#   test's own copy of the seed. The test then also lists the hero's abilities and screenshots the match.
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-match}
HERO=${HERO:-Berserker}
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
host_cmd() { for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
WHERE='lua local gs=FindFirstOf("GameStateBase"); return "map: " .. (gs and gs:IsValid() and gs:GetFullName() or "none")'
OUTPARAM='lua local mr=FindFirstOf("BP_AC_MatchReport_C"); local a, b = {}, {}; local ok, r = pcall(function() return mr:GetMatchResults(a, b) end)'\
' local function d(t) local o={} for k, v in pairs(t) do local s=tostring(v); pcall(function() s=v:ToString() end); o[#o+1]=tostring(k) .. "=" .. s:sub(1, 80) end return table.concat(o, ",") end'\
' return "GetMatchResults ok=" .. tostring(ok) .. " ret=" .. tostring(r) .. " a={" .. d(a) .. "} b={" .. d(b) .. "}"'
ITEMS='lua local function n(a) if type(a) == "table" then return #a end return a:GetArrayNum() end'\
' local gi=FindFirstOf("BP_MOBAInstance_C"); local p=StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0).Pawn'\
' return string.format("items on %s: generic=%d hero=%d offered=%d", p:GetClass():GetFName():ToString(), n(p.GenericItems), n(p.PossibleItems), n(p:GetPossibleItemsSorted()))'
ABILITIES='lua local gi=FindFirstOf("BP_MOBAInstance_C"); local p=StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0).Pawn'\
' local t={} p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e) local a=e:get().Ability'\
' if a and a:IsValid() then t[#t+1]=a:GetClass():GetFName():ToString() end end)'\
' return "abilities on " .. p:GetClass():GetFName():ToString() .. " (" .. #t .. "): " .. table.concat(t, ", ")'
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Match Test", "The Garden of Vermilia", FText("'"${MAP:-LE_Arena02_Map}"'"), 1); return "create"' >> $A
  sleep 40; echo "$WHERE" >> $A
  # as the hero select does: the profile's hero (what the lobby server reads) and the lobby pick
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$HERO"'", false);'\
' pcall(function() pc:UpdateChosenHero("'"$HERO"'") end); return "picked '"$HERO"'"' >> $A
  sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  sleep 60; echo 'shot showui' >> $A
  sleep 15; echo "$WHERE" >> $A; echo "$ITEMS" >> $A; echo "$ABILITIES" >> $A; echo 'shot showui' >> $A; host_cmd "$WHERE"; host_cmd "$OUTPARAM"
  sleep 5; host_cmd 'lua FindFirstOf("GS_MOBA_Battle_C"):SurrenderForceTeamDefeat(2); return "surrendered team B"'
  sleep 15; echo 'shot showui' >> $A; host_cmd "$OUTPARAM"
  sleep 30; echo "$WHERE" >> $A; echo 'shot showui' >> $A
  echo 'lua local m=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef; if m and m:IsValid() then m:SelectMainMenuTab(2) return "career tab" end return "no menu"' >> $A
  sleep 6; echo 'shot showui' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --seed $PWD/work/run/$R-seed.json" \
  tools/run/headless.sh "${DURATION:-260}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=matcher -TestPass=x" 2>&1 | grep -v Segmentation
wait
echo "== client"; grep -h 'lua \|exec' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | cut -c21-400
grep -h 'restored items' work/run/$R/MOBA/Binaries/Win64/fangsboot.log | cut -c21-200
echo "== game server"; grep -h 'lua \|match end\|hooked SendEndResults' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangs{ctl,host}.log 2>/dev/null | cut -c21-600
echo "== backend"; grep -h '"match"' work/logs/$R-backend.jsonl | cut -c1-400
python3 - "$PWD/work/run/$R-store.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
uid = next(u['user_id'] for u in d['users'].values() if u['display_name'] == 'matcher')
recs = d['player_records'].get(uid, {})
h = recs.get('PROFILE_HISTORY_KEY', {}).get('Matches', [])
print('history:', len(h), 'matches', (h[-1].get('GameMode'), h[-1].get('MapLevel'), len(h[-1].get('MatchResults', []))) if h else '')
if h and h[-1].get('MatchResults'):
    print('first row:', {k: v for k, v in h[-1]['MatchResults'][0]['RoundResults'][0].items() if k in ('UserId', 'Name', 'Type', 'Team', 'Kills')})
print('mastery:', recs.get('PROFILE_MASTERY_KEY'))
print('ratings:', recs.get('PROFILE_RATINGS_KEY'))
EOF
rm -rf work/logs/$R-shots; mkdir -p work/logs/$R-shots
cp work/run/$R.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png work/logs/$R-shots/ 2>/dev/null
ls work/logs/$R-shots
