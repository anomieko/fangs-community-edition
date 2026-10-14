#!/usr/bin/env bash
# Item test: one GPU-rendered headless client plays HERO in a solo custom match with ITEMS (DT_MOBALoot rows)
# added to its hero's in-match pool, the way the restore list does (this test's own copy of the seed). In the
# pre-round item selection it equips each item through its slot (by tier: artifact 1, combat 2, utility 3,
# flex 4, ultimate 5, boon 6), locks in, then fires each of the hero's abilities. Checks: the item is in the
# hero's pool, the game server has it equipped, which abilities/effects the server's hero has. Screenshots in
# work/logs/items-<RUN>/. Own backend data and game servers; local play is untouched.
# Usage: HERO=<DT_Heroes row> ITEMS="<row> <row> ..." [RUN=<name>] tools/run/test_items.sh
set -u
cd "$(dirname "$0")/../.."
HERO=${HERO:?set HERO}; ITEMS=${ITEMS:?set ITEMS}
R=${RUN:-items-$HERO}
rm -rf work/run/$R-hosts work/run/$R-store.json
PATHS=$(python3 - "$HERO" work/run/$R-seed.json $ITEMS <<'PY'
import json, sys
hero, out, rows = sys.argv[1], sys.argv[2], sys.argv[3:]
d = json.load(open('backend/seed/game_records.json'))
m = json.load(open('backend/seed/itempaths-feb2023.json'))
cfg = d['FANGSConfig']['Playtest021523v1_v0_0_02']
if hero not in cfg['AvailableHeroes']:
    cfg['AvailableHeroes'].append(hero)
have = {a['Item'] for a in cfg['AvailableAugments']}
cfg['AvailableAugments'] += [{'Item': r, 'Owner': hero} for r in rows if r not in have]
d['CERestoredItems']['Playtest021523v1_v0_0_02'] += [
    {'Class': m['heroes'][hero], 'List': 'PossibleItems', 'Item': m['items'][r]} for r in rows]
json.dump(d, open(out, 'w'))
print(' '.join('"%s"' % m['items'][r] for r in rows).replace(' ', ', '))
PY
)
A=work/run/$R/MOBA/Binaries/Win64/fangsctl_cmd.txt
host_cmd() { for h in work/run/$R-hosts/host-*/MOBA/Binaries/Win64; do echo "$1" >> $h/fangsctl_cmd.txt; done; }
ME='local gi=FindFirstOf("BP_MOBAInstance_C"); local pc=StaticFindObject("/Script/Engine.Default__GameplayStatics"):GetPlayerController(gi, 0)'\
' local pawn, ps = pc.Pawn, pc.PlayerState'
EQUIP="lua $ME"' local hud=pc.WB_HUDGamplayRef; local pre=hud.PreRoundSelection; local taken, out = {}, {}'\
' local pool={} local function add(x) pcall(function() local o=x; if type(x.get) == "function" then o=x:get() end pool[o:GetAddress()]=true end) end'\
' local ok, list = pcall(function() return pawn:GetPossibleItemsSorted() end)'\
' if ok and type(list) == "table" then for _, x in ipairs(list) do add(x) end elseif ok then pcall(function() list:ForEach(function(_, e) add(e) end) end) end'\
' for _, path in ipairs({'"$PATHS"'}) do local it=StaticFindObject(path); local name=path:match("([^.]+)$")'\
' if not (it and it:IsValid()) then out[#out+1]=name .. ": not loaded" else'\
' local tier=it.ItemTier; local s; for _, c in ipairs(({[2]={1,4}, [0]={2,4}, [1]={3,4}, [4]={5}, [5]={6}})[tier] or {}) do if not taken[c] then s=c break end end'\
' if not s then out[#out+1]=name .. ": no free slot (tier " .. tier .. ")" else taken[s]=true'\
' local slot=pre["PlayerItem" .. s]; hud.SelectedSlot=slot; hud.CurrentTierFilter=tier; pcall(function() hud:RefreshItemStash() end)'\
' local okset, err = pcall(function() slot:SetItem(it, true) end)'\
' out[#out+1]=name .. ": tier " .. tier .. " -> slot " .. s .. (pool[it:GetAddress()] and " (in pool)" or " (NOT in pool)") .. (okset and "" or (" SetItem failed: " .. tostring(err))) end end end'\
' ps:ReportetFinishedItemSelectOnServer(false); pc:PlayerLockedIn(); return "equip: " .. table.concat(out, "; ")'
SERVER='lua local ps=FindFirstOf("BP_PlayerState_MOBA_Hero_C"); local p=FindFirstOf("BP_PlayerChar_C"); local eq, ab = {}, {}'\
' if ps and ps:IsValid() then ps.HeroEquipment:ForEach(function(i, e) local it=e:get() if it and it:IsValid() then eq[#eq+1]=i .. "=" .. it:GetFName():ToString() end end) end'\
' if p and p:IsValid() then p.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e) local a=e:get().Ability'\
' if a and a:IsValid() then local n=a:GetClass():GetFName():ToString() if not n:find("Emote") then ab[#ab+1]=n end end end) end'\
' return "server: equipped [" .. table.concat(eq, ", ") .. "] abilities [" .. table.concat(ab, ", ") .. "]"'
OWN="$ME"' local own={} pawn.AbilitySystemComponent.ActivatableAbilities.Items:ForEach(function(_, e) local a=e:get().Ability'\
' if a and a:IsValid() and a:GetClass():GetFName():ToString():lower():find(("'"$HERO"'"):lower(), 1, true) then own[#own+1]=a:GetClass() end end)'
fire() { echo "lua $OWN"' local c=own['"$1"'] if not c then return "no ability '"$1"'" end'\
' return "ability '"$1"' " .. c:GetFName():ToString() .. " -> " .. tostring(pawn.AbilitySystemComponent:TryActivateAbilityByClass(c, true))' >> $A; }
(
  sleep 40
  printf '%s\n' 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; return "ready"' \
    'lua FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu:CreateLobbyAndJoin("Item Test", "The Garden of Vermilia", FText("LE_Arena02_Map"), 1); return "create"' >> $A
  sleep 40
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$HERO"'", false);'\
' pcall(function() pc:UpdateChosenHero("'"$HERO"'") end); return "picked '"$HERO"'"' >> $A
  sleep 8; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartMatch(); return "start"' >> $A
  sleep 70; echo "$EQUIP" >> $A; echo 'shot showui' >> $A
  sleep 12; host_cmd "$SERVER"
  sleep 60
  echo 'lua local n=0 for _, w in ipairs(FindAllOf("WB_LobbyMenu_C") or {}) do if w:IsValid() and w:IsInViewport() then w:RemoveFromParent(); n=n+1 end end return "removed lobby screen x" .. n' >> $A
  for i in 1 2 3 4 5 6 7 8; do sleep 4; fire $i; sleep 1; echo 'shot' >> $A; done
  sleep 3; host_cmd "$SERVER"; echo 'shot showui' >> $A
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --seed $PWD/work/run/$R-seed.json" \
  tools/run/headless.sh "${DURATION:-330}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R:0:"-TestUser=itemer -TestPass=x" 2>&1 | grep -v Segmentation
wait
grep -h 'lua \|exec' work/run/$R/MOBA/Binaries/Win64/fangsctl.log | grep -v 'exec: shot' | cut -c21-700
grep -h 'restored items' work/run/$R/MOBA/Binaries/Win64/fangsboot.log | cut -c21-200
grep -h 'lua \(ok\|error\): server' work/run/$R-hosts/host-*/MOBA/Binaries/Win64/fangsctl.log 2>/dev/null | cut -c21-1500
rm -rf work/logs/$R; mkdir -p work/logs/$R
cp work/run/$R.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png work/logs/$R/ 2>/dev/null
ls work/logs/$R | wc -l
