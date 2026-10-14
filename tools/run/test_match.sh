#!/usr/bin/env bash
# Match-result test: one GPU-rendered headless client creates a 1-player custom lobby, picks a hero and starts
# the match; the game server then ends it (the game's surrender: team B defeated). Checks that FangsHost saved
# the result and the backend turned it into match history, levels and wins (and screenshots the end screen and
# the profile). Own backend data and game-server directory, so local play is untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_match.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-match}
rm -rf work/run/$R-hosts work/run/$R-store.json
A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
host_cmd() { for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
WHERE='lua local gs=FindFirstOf("GameStateBase"); return "map: " .. (gs and gs:IsValid() and gs:GetFullName() or "none")'
OUTPARAM='lua local mr=FindFirstOf("BP_AC_MatchReport_C"); local a, b = {}, {}; local ok, r = pcall(function() return mr:GetMatchResults(a, b) end)'\
' local function d(t) local o={} for k, v in pairs(t) do local s=tostring(v); pcall(function() s=v:ToString() end); o[#o+1]=tostring(k) .. "=" .. s:sub(1, 80) end return table.concat(o, ",") end'\
' return "GetMatchResults ok=" .. tostring(ok) .. " ret=" .. tostring(r) .. " a={" .. d(a) .. "} b={" .. d(b) .. "}"'
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Match Test", "The Garden of Vermilia", FText("LE_Arena02_Map"), 1); return "create"' >> $A
  sleep 40; echo "$WHERE" >> $A
  echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):UpdateChosenHero("Berserker"); return "picked"' >> $A
  sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  sleep 75; echo "$WHERE" >> $A; host_cmd "$WHERE"; host_cmd "$OUTPARAM"
  sleep 5; host_cmd 'lua FindFirstOf("GS_MOBA_Battle_C"):SurrenderForceTeamDefeat(2); return "surrendered team B"'
  sleep 15; echo 'shot showui' >> $A; host_cmd "$OUTPARAM"
  sleep 30; echo "$WHERE" >> $A; echo 'shot showui' >> $A
  echo 'lua local m=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef; if m and m:IsValid() then m:SelectMainMenuTab(2) return "career tab" end return "no menu"' >> $A
  sleep 6; echo 'shot showui' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts" \
  tools/run/headless.sh "${DURATION:-260}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=matcher -TestPass=x" 2>&1 | grep -v Segmentation
wait
echo "== client"; grep -h 'lua \|exec' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | cut -c21-400
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
