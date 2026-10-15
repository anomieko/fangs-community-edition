#!/usr/bin/env bash
# In-game chat (Feb 2023 build): two GPU-rendered headless players who are not friends meet in a custom lobby (alice
# creates it, bob joins from the lobby list), go through hero select into the match, and chat the way Enter + typing
# does (the chat window's own input handler): all and team chat in the custom lobby, team chat in hero select, all and
# team chat in the match. Each client logs its chat lobby list (who all/team chat goes to) and the chat lines it shows.
# SLOTS="0 2" (default) puts both on one team, "0 1" on opposite teams (team chat must then stay on the sender's side).
# PARTY=1: they become friends and form a party in the lobby, and also party chat in the match.
# QUEUE=1: both press PLAY instead (matchmade 1 vs 1, backend --match-size 2), so the chat lobby list only comes from
# hero select; no custom lobby, no PARTY.
# Own backend data and game servers; local play is untouched. Evidence: work/logs/<run>/ (log + screenshots).
# Usage: RUN=chat-<name> [SLOTS="0 1"] [PARTY=1 | QUEUE=1] tools/run/test_chat.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-chat}
rm -rf work/run/$R-hosts work/run/$R-data work/logs/$R
A=work/run/$R-alice/MOBA/Binaries/Win64/fangsctl_cmd.txt; B=work/run/$R-bob/MOBA/Binaries/Win64/fangsctl_cmd.txt
LOAD="lua dofile(\"Z:$PWD/tools/run/test_chat.lua\") return 'chat helpers'"
both() { echo "lua return FCE_CHAT.$1" >> $A; echo "lua return FCE_CHAT.$1" >> $B; }
say() { echo "lua return FCE_CHAT.say(\"$2\", \"$3\")" >> $1; }
shots() { echo 'shot showui' >> $A; echo 'shot showui' >> $B; }
ident() {   # tagged display name and user id, as the backend makes them
  python3 -I -c 'import uuid, hashlib, sys; n = sys.argv[1]; u = uuid.uuid5(uuid.NAMESPACE_DNS, "fangs:" + n.lower()).hex
print("%s#%04d %s" % (n, int(hashlib.sha256(u.encode()).hexdigest(), 16) % 10000, u))' "$1"
}
read -r BTAG BID <<< "$(ident bob)"
LOCKIN='lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); local h=pc.WB_LobbyHeroSelectRef;'\
' if h:ShowSelectHeroBtn() == 0 then h:BndEvt__ReadyBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature() return "locked in" end return "lock in hidden"'
WHERE='lua local gs=FindFirstOf("GameStateBase"); local p=FindFirstOf("BP_PlayerChar_C");'\
' return "map=" .. (gs:GetFullName():match("Maps/([%w_]+)") or "?") .. " pawn=" .. (p and p:IsValid() and p:GetFName():ToString() or "none")'
pick() {
  echo 'lua local pc=FindFirstOf("BP_PC_Lobby_PlayerController_C"); FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef:UpdatePlayerHero("'"$2"'", false); pcall(function() pc:UpdateChosenHero("'"$2"'") end); return "picked '"$2"'"' >> "$1"
}
(
  sleep 40
  echo "$LOAD" >> $A; echo "$LOAD" >> $B
  if [[ -n ${QUEUE:-} ]]; then
    for f in $A $B; do
      echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi; gi.MapGameMode=2;'\
' pm:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "pressed PLAY"' >> $f
    done
    sleep 12
    for f in $A $B; do
      echo 'lua FindFirstOf("BP_MOBAInstance_C").WB_AcceptMatchRef:BndEvt__OkBtn_K2Node_ComponentBoundEvent_2_OnButtonClickedEvent__DelegateSignature(); return "accepted"' >> $f
    done
    sleep 55; both 'users()'
    say $B team "hero select team from bob"; sleep 1; say $A all "hero select all from alice"
    sleep 4; both 'history()'; shots
    pick $A Lancer; pick $B Berserker
    sleep 4; for f in $A $B; do echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SetChosenHero(); return "locked in"' >> $f; done
  else
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi.MapGameMode=4; local pm=gi.WB_MainMenuRef.WB_PlayMenu; pm.BP_MOBAInstanceRef=gi;'\
' pm:CreateLobbyAndJoin("Chat Test", "Embersong", FText("LE_Arena02_Map"), 8); return "alice: create 8-slot lobby"' >> $A
    sleep 50
    echo 'lua local gi=FindFirstOf("BP_MOBAInstance_C"); gi:ShowChoseGameMode(); gi.WB_ChoseGameModeRef:SetJoinCustomMode(); return "bob: chose Join a lobby"' >> $B
    sleep 2
    echo 'lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu;'\
' pm:BndEvt__PlayBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "bob: pressed PLAY"' >> $B
    sleep 10
    echo 'lua local pm=FindFirstOf("BP_MOBAInstance_C").WB_MainMenuRef.WB_PlayMenu; if pm.LobbyList:GetChildrenCount() == 0 then return "bob: no lobby to click" end'\
' pm.LobbyList:GetChildAt(0):BndEvt__SelectSessionBtn_K2Node_ComponentBoundEvent_0_OnButtonClickedEvent__DelegateSignature(); return "bob: clicked the lobby"' >> $B
    sleep 30
    read -r sa sb <<< "${SLOTS:-0 2}"
    echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer('$sa'); return "alice: seat '$sa'"' >> $A
    echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):SelectTeamSlotOnServer('$sb'); return "bob: seat '$sb'"' >> $B
    if [[ -n ${PARTY:-} ]]; then   # friends, then a party (alice leads)
      echo 'lua local f=FindFirstOf("MOBAFriends"); f:SendFriendRequestDisplayName("'$BTAG'") return "alice: friend request to '$BTAG'"' >> $A
      sleep 5; echo 'lua local f=FindFirstOf("MOBAFriends"); local id="" f.IncomingFriendRequests:ForEach(function(_, e) id=e:get().UserId:ToString() end)'\
' f:AcceptFriendRequest(id) return "bob: accepted " .. id' >> $B
      sleep 5; echo 'lua return "alice: invite -> " .. tostring(FindFirstOf("MOBAPartySubsystem"):InviteToParty("'$BID'"))' >> $A
      sleep 5; echo 'lua local p=FindFirstOf("MOBAPartySubsystem"); local r="no invite" p.PartyInvitesIn:ForEach(function(_, e) local x=e:get()'\
' if r == "no invite" then r=tostring(p:AcceptPartyInvite(x.PartyId:ToString(), x.InvitationToken:ToString())) end end) return "bob: join -> " .. r' >> $B
    fi
    sleep 8; both 'users()'
    say $A all "lobby all from alice"; sleep 1; say $B team "lobby team from bob"
    sleep 5; both 'history()'; shots
    sleep 2; echo 'lua FindFirstOf("BP_PC_Lobby_PlayerController_C"):StartHeroSelectionTimer(); return "alice: launch"' >> $A
    sleep 12; both 'users()'
    say $B team "hero select team from bob"; sleep 1; say $A all "hero select all from alice"
    sleep 4; both 'history()'; shots
    pick $A Lancer; pick $B Berserker
    sleep 4; echo "$LOCKIN" >> $A; echo "$LOCKIN" >> $B
  fi
  for _ in 1 2 3; do sleep 20; echo "$WHERE" >> $A; echo "$WHERE" >> $B; done
  sleep 5; both 'users()'
  say $A all "match all from alice"; sleep 1; say $B team "match team from bob"; sleep 1; say $B all "match all from bob"
  [[ -n ${PARTY:-} ]] && { sleep 1; say $A party "match party from alice"; }
  sleep 5; both 'history()'; both 'open()'; sleep 1; shots
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-data/store.json --instances $PWD/work/run/$R-hosts ${QUEUE:+--match-size 2}" \
  tools/run/headless.sh "${DURATION:-320}" clients/fangs-2023-02-15-b10554626 \
  -- $R-alice:0:"-TestUser=alice -TestPass=x" -- $R-bob:3:"-TestUser=bob -TestPass=x" 2>&1 | grep -v Segmentation
wait
mkdir -p work/logs/$R
{
  for n in alice bob; do grep -h 'lua \(ok\|error\)' work/run/$R-$n/MOBA/Binaries/Win64/fangsctl.log | sed "s/^/$n: /" | cut -c1-400; done
  echo "backend (lobby websocket):"
  grep -h '"recv"' work/logs/$R-alice-backend.jsonl | grep -o 'type: [A-Za-z0-9]*' | sort | uniq -c | sort -rn
  grep -h '"recv"' work/logs/$R-alice-backend.jsonl | grep 'signalingP2PNotif\|ChatRequest' | grep -v '<' | cut -c1-200
  grep -h '"ws": "social"' work/logs/$R-alice-backend.jsonl | cut -c1-200
} | tee work/logs/$R/test.log
for n in alice bob; do
  for f in work/run/$R-$n.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png; do
    [[ -f $f ]] && cp "$f" work/logs/$R/$n-$(basename "$f")
  done
done
echo "evidence: work/logs/$R ($(ls work/logs/$R | wc -l) files)"
