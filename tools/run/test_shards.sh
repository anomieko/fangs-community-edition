#!/usr/bin/env bash
# Old Shard system test (docs/recon/shards.md): one GPU-rendered headless client plays HERO in a solo custom match on
# MAP with ITEMS (artifact rows) equipped (slots 1, 4, 7, 8: the solo player is the Captain). The game server logs every
# change of the Shard / Health Shrine / hero state (shardwatch.log); the client channels with the F key's own handler.
# Sequence: Health Shrine channel (before the Shard spawns: Energy still 0); Shard spawn; pick up; own Capture Zone;
# respawn; pick up; carrier killed by the enemy turret (the Shard goes back to a shrine); pick up; enemy Capture Zone
# (back-cap); Health Shrine channel after turret damage; round end; round 2 Shard, picked up, then the carrier's hero
# removed without dying (a player leaving): the Shard must go back. Maps without turrets (Payload II) skip the turret
# steps.
# MODE=off: the Feb 2023 kill system instead (seed with the switch off): Prismatic Shard spawn and kill, pickups.
# Own backend data, seed and game servers; local play is untouched.
# Usage: RUN=shards-<name> MAP=LE_Arena02_Map [MODE=on|off] [SPEEDUP=off|mask_of_speed|every_capture]
#        [HERO=FireMage] [ITEMS="<restore rows>"] tools/run/test_shards.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:?set RUN}; MAP=${MAP:-LE_Arena02_Map}; MODE=${MODE:-on}; HERO=${HERO:-FireMage}; ITEMS=${ITEMS:-}
rm -rf work/run/$R-hosts work/run/$R-store.json work/logs/$R
python3 -I backend/seed/make_seed.py 127.0.0.1:8080 work/run/$R-seed.json >/dev/null
PATHS=$(python3 -I - "$MODE" "${SPEEDUP:-}" work/run/$R-seed.json $ITEMS <<'PY'
import json, sys
mode, speedup, seed, rows = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
d = json.load(open(seed))
paths = json.load(open('backend/seed/itempaths-feb2023.json'))['items']
groups = json.load(open('backend/seed/restore-feb2023.json'))
if mode == 'off':   # what make_seed.py writes with OLD_SHARDS = False
    d['CEOldShards']['Enabled'] = False
    old = {r for g in ('_old_shards', '_old_health_shrines') for r in groups[g]}
    cfg = d['FANGSConfig']['Playtest021523v1_v0_0_02']
    cfg['AvailableAugments'] = [a for a in cfg['AvailableAugments'] if a['Item'] not in old]
    d['CERestoredItems']['Playtest021523v1_v0_0_02'] = [x for x in d['CERestoredItems']['Playtest021523v1_v0_0_02']
                                                         if x['Item'] not in {paths[r] for r in old}]
if speedup:
    d['CEOldShards']['AspectSpeedup'] = speedup
json.dump(d, open(seed, 'w'))
print(', '.join('"%s"' % paths[r] for r in rows))
PY
)
NINE=$(python3 -I -c "
import json; p = json.load(open('backend/seed/itempaths-feb2023.json'))['items']; g = json.load(open('backend/seed/restore-feb2023.json'))
print(', '.join('\"%s\"' % p[r] for k in ('_old_shards', '_old_health_shrines') for r in g[k]))")
A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
LOAD="lua dofile(\"Z:$PWD/tools/run/test_shards.lua\") return 'helpers'"
host() { for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "lua return FCE_SHARDS.$1" >> $h/fangsctl_cmd.txt; done; }
host_load() { for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$LOAD" >> $h/fangsctl_cmd.txt; done; }
client() { echo "lua return FCE_SHARDS.$1" >> $A; }
shot() { echo 'lua local n=0 for _, w in ipairs(FindAllOf("WB_LobbyMenu_C") or {}) do if w:IsValid() and w:IsInViewport() then w:RemoveFromParent(); n=n+1 end end return "lobby screens removed: " .. n' >> $A; echo 'shot showui' >> $A; }
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    "lua FindFirstOf(\"BP_MOBAInstance_C\").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin(\"Shard Test\", \"Shard Test\", FText(\"$MAP\"), 1); return \"create\"" >> $A
  sleep 35; host_load
  sleep 5
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$HERO"'", false);'\
' pcall(function() pc:UpdateChosenHero("'"$HERO"'") end); return "picked '"$HERO"'"' >> $A
  sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  sleep 60; echo "$LOAD" >> $A; client "texts()"; client "pool({ $NINE })"; client "equip({ $PATHS })"
  sleep 5; host 'equipment()'; host 'watch()'
  if [[ $MODE == off ]]; then
    sleep 40; host 'state()'; host 'tp("prismatic")'; sleep 2; shot
    sleep 2; host 'hitPrismatic()'; sleep 3; host 'state()'; shot
    sleep 30; host 'state()'
  else
    sleep 18; host 'tp("shrine")'; sleep 2; client 'channel()'; sleep 4; host 'state()'
    sleep 6; host 'tp("shard")'; sleep 2; client 'channel()'; sleep 1; shot
    sleep 4; host 'tp("own")'; sleep 2; client 'channel()'; sleep 4; shot; host 'ascension()'
    sleep 22; host 'tp("shard")'; sleep 2; client 'channel()'; sleep 4; host 'tp("turret")'
    sleep 14; host 'state()'
    sleep 26; host 'tp("shard")'; sleep 2; client 'channel()'; sleep 4; host 'tp("enemy")'; sleep 2; client 'channel()'; sleep 4; shot
    sleep 2; host 'tp("turret")'; sleep 3; host 'tp("shrine")'; sleep 2; client 'channel()'; sleep 1; shot; sleep 4; host 'state()'
    sleep 3; host 'endRound(1)'
    sleep 30; client 'equip({})'; sleep 5; host 'equipment()'
    sleep 30; host 'state()'; shot
    sleep 2; host 'tp("shard")'; sleep 2; client 'channel()'; sleep 4; host 'vanish()'; sleep 4; host 'state()'
  fi
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --seed $PWD/work/run/$R-seed.json" \
  tools/run/headless.sh "${DURATION:-480}" clients/fangs-2023-02-15-b10554626 \
  -- $R:0:"-TestUser=sharder -TestPass=x" 2>&1 | grep -v Segmentation
wait
mkdir -p work/logs/$R
echo "== client"; grep -h 'lua ' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | cut -c21-600
grep -h 'item texts\|restored items' work/run/$R/MOBA/Binaries/Win64/fangsboot.log | cut -c21-200
for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do
  [[ -f $h/shardwatch.log ]] || continue
  echo "== server $h"; grep -h 'old shards' $h/fangshost.log | cut -c21-300
  grep -h 'lua ' $h/fangsctl.log | grep -v "helpers\|watching" | cut -c21-1200
  cp $h/shardwatch.log work/logs/$R/shardwatch-$(echo $h | grep -o 'host-[0-9]*').log
  python3 -I tools/run/test_shards_log.py $h/shardwatch.log > work/logs/$R/timeline-$(echo $h | grep -o 'host-[0-9]*').txt
done
cp work/run/$R/MOBA/Binaries/Win64/shardtexts.log work/logs/$R/ 2>/dev/null
cp work/run/$R.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png work/logs/$R/ 2>/dev/null
echo "evidence: work/logs/$R ($(ls work/logs/$R | wc -l) files)"
