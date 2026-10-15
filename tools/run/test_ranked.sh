#!/usr/bin/env bash
# Ranked end to end with two real clients (1 vs 1, backend --ranked-size 2): both have 10 wins, open the game-mode
# chooser (checks the Ranked tile is enabled), pick Ranked (MapGameMode 3: the ranked queue), accept, draft-pick
# and lock in, play; the game server then ends the match (surrender: team B defeated). Checks the backend matched
# them from the Ranked queue, settled the ratings from the result, and serves them as ranked_rating / leaderboard.
# Own backend data and game-server directory, so local play is untouched.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_ranked.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-ranked}
rm -rf work/run/$R-hosts work/run/$R-store.json work/logs/$R-backend.jsonl
python3 -I - work/run/$R-store.json <<'PY'
import json, sys, uuid
users, recs = {}, {}
for name in ('rankeda', 'rankedb'):     # ids as the backend makes them (Store.user_for)
    uid = uuid.uuid5(uuid.NAMESPACE_DNS, 'fangs:' + name).hex
    users[name] = {'user_id': uid, 'display_name': name, 'created_at': '2026-10-15T00:00:00Z'}
    # 10 wins unlock the Ranked tile (WB_GameModeTallBtn.CheckIfEnabled)
    recs[uid] = {'PROFILE_MASTERY_KEY': {'Level': 5, 'XPToNext': 0, 'MatchesPlayed': 14, 'MatchesWon': 10}}
json.dump({'users': users, 'player_records': recs, 'game_records': {}}, open(sys.argv[1], 'w'))
PY
A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
B=work/run/${R}2/MOBA/Binaries/Win64/fangsctl_cmd.txt
both() { echo "$1" >> $A; echo "$1" >> $B; }
host_cmd() { for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
STATUS='lua local mm=FindFirstOf("MOBAMatchMakerSubsystem"); local gs=FindFirstOf("GameStateBase"); local gi=FindFirstOf("BP_MOBAInstance_C");'\
' return string.format("mode=%d queue=%s queued=%s match=%s server=%s map=%s", gi.MapGameMode, mm.MatchMakerJoinQueueId:ToString(),'\
' tostring(mm.bMatchQueued), mm.MatchId:ToString(), mm.MatchServerAddress:ToString(), gs:GetFullName():match("Maps/([%w_]+)") or "?")'
TILE='lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.WB_MainMenuRef.WB_PlayMenu.BP_MOBAInstanceRef=gi; gi:ShowChoseGameMode();'\
' local t=gi.WB_ChoseGameModeRef.RankedGameMode; local ok, en=pcall(function() return t:CheckIfEnabled() end)'\
' return string.format("ranked tile: CheckIfEnabled=%s overlay enabled=%s sub=\"%s\"", tostring(en), tostring(t.Overlay_31:GetIsEnabled()),'\
' t.GameModeDescSubLbl:GetText():ToString())'
DRAFT='lua local gs=FindFirstOf("GS_Lobby_GameState_C"); local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); if not (gs and gs:IsValid()) then return "no lobby" end'\
' local ps=pc.PlayerState; return string.format("lobby: step=%d size=%d slot=%s hero=%s locked=%s", gs.GS_HeroSelectStep, gs.MatchSize,'\
' tostring(ps.ChosenSlot), ps.ChosenHero:ToString(), tostring(ps.IsLockedIn))'
pick() { echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$2"'", false);'\
' pcall(function() pc:UpdateChosenHero("'"$2"'") end); pcall(function() pc:SetChosenHero() end); return "picked and locked '"$2"'"' >> $1; }
(
  sleep 45; both "$TILE"
  sleep 4; both 'lua local c=FindFirstOf("BP_MOBAInstance_C").WB_ChoseGameModeRef; c:SetRankedMode(); return "chose Ranked"'
  sleep 6; both "$STATUS"
  echo 'lua local d=FindFirstOf("BP_MOBAInstance_C").WB_AcceptMatchRef; d:BndEvt__OkBtn_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature(); return "accepted"' >> $A
  echo 'lua local d=FindFirstOf("BP_MOBAInstance_C").WB_AcceptMatchRef; d:BndEvt__OkBtn_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature(); return "accepted"' >> $B
  # Ranked hero select is the game's draft: 16 s per round to lock in, or the lobby ends. Pick from the moment
  # the server is assigned (until the clients are in the lobby the commands just fail).
  for i in $(seq 1 60); do grep -q '"mm": "assigned"' work/logs/$R-backend.jsonl 2>/dev/null && break; sleep 1; done
  for i in $(seq 1 20); do sleep 2; pick $A Lancer; pick $B Berserker; done
  both "$DRAFT"
  for i in $(seq 1 24); do   # until the clients are in the arena
    sleep 5; echo "$STATUS" >> $A
    grep -q 'map=LE_\(Arena\|Payload\)' work/run/$R/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null && break
  done
  sleep 20; both "$STATUS"; both 'shot showui'
  sleep 5; host_cmd 'lua FindFirstOf("GS_MOBA_Battle_C"):SurrenderForceTeamDefeat(2); return "surrendered team B"'
  sleep 20; both 'shot showui'
  sleep 25; both "$STATUS"; both 'shot showui'
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --ranked-size 2" \
  tools/run/headless.sh "${DURATION:-360}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=rankeda -TestPass=x" -- ${R}2:3:"-TestUser=rankedb -TestPass=x" 2>&1 | grep -v Segmentation
wait
for c in $R ${R}2; do echo "== client $c"; grep -h 'lua \|exec' work/run/$c/MOBA/Binaries/Win64/fangsctl.log | cut -c21-300; done
echo "== game server"; grep -h 'lua \|match end\|matchmade\|lobby:' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangs{ctl,host}.log 2>/dev/null | cut -c21-300
echo "== backend"; grep -h '"mm": "\(queue join\|matched\|starting\|assigned\|cancel\)\|"match": "[0-9a-f]\{16\}"' work/logs/$R-backend.jsonl | cut -c1-700
python3 -I - "$PWD/work/run/$R-store.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
names = {u['user_id']: u['display_name'] for u in d['users'].values()}
for uid, r in (d.get('ranked') or {}).get('players', {}).items():
    print('ranked:', names.get(uid), {k: round(v, 2) if isinstance(v, float) else v for k, v in r.items()})
for uid, recs in d['player_records'].items():
    m = recs.get('PROFILE_MASTERY_KEY', {})
    print('mastery:', names.get(uid), {k: m.get(k) for k in ('MatchesPlayed', 'MatchesWon')},
          'stored PROFILE_RATINGS_KEY:', recs.get('PROFILE_RATINGS_KEY'))
    try:    # what FangsHost hands the game servers (GetServerPlayerRatings)
        print('  game servers get:', open(f"{sys.argv[1].rsplit('/', 1)[0]}/records/players/{uid}/PROFILE_RATINGS_KEY.json").read())
    except OSError as e:
        print('  game servers get: nothing', e)
EOF
rm -rf work/logs/$R-shots; mkdir -p work/logs/$R-shots
for c in $R ${R}2; do
  for f in work/run/$c.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png; do
    [[ -f $f ]] && cp "$f" "work/logs/$R-shots/$c-$(basename "$f")"
  done
done
ls work/logs/$R-shots
