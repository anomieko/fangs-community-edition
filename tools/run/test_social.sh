#!/usr/bin/env bash
# Friends, party and chat (Feb 2023 build): two GPU-rendered headless clients. A adds B by "name#1234", B
# accepts; A invites B to a party, B joins (both must list each other with their heroes, which travel between
# the players as signaling messages); party chat and a whisper; then A presses PLAY and B must follow into the
# queue with the party's token. Own backend data and host dir (no game server is started), so local play is
# untouched. Screenshots end up in work/logs/<run>-shots/.
# Usage: CLIENT_DIR=clients/<build> tools/run/test_social.sh
set -u
cd "$(dirname "$0")/../.."
R=${RUN:-soc}
rm -rf work/run/$R-hosts work/run/$R-store.json
A=work/run/$R-a/MOBA/Binaries/Win64/fangsctl_cmd.txt; B=work/run/$R-b/MOBA/Binaries/Win64/fangsctl_cmd.txt
ident() {   # tagged display name and user id, as the backend makes them
  python3 -c 'import uuid, hashlib, sys; n = sys.argv[1]; u = uuid.uuid5(uuid.NAMESPACE_DNS, "fangs:" + n.lower()).hex
print("%s#%04d %s" % (n, int(hashlib.sha256(u.encode()).hexdigest(), 16) % 10000, u))' "$1"
}
read -r ATAG AID <<< "$(ident ${R}a)"; read -r BTAG BID <<< "$(ident ${R}b)"
FRIENDS='lua local f=FindFirstOf("MOBAFriends"); local function names(arr) local t={} arr:ForEach(function(_, e) local x=e:get()'\
' t[#t+1]=x.DisplayName:ToString() .. "/" .. tostring(x.availability) end) return table.concat(t, ", ") end'\
' return "friends: [" .. names(f.FriendList) .. "] incoming [" .. names(f.IncomingFriendRequests) .. "] outgoing [" .. names(f.OutgoingFriendRequests) .. "]"'
PARTY='lua local p=FindFirstOf("MOBAPartySubsystem"); local t={} p.PartyMembers:ForEach(function(_, e) local x=e:get()'\
' t[#t+1]=x.DisplayName:ToString() .. "(" .. x.Hero:ToString() .. ")" end) local inv={} p.PartyInvitesIn:ForEach(function(_, e) inv[#inv+1]=e:get().DisplayName:ToString() end)'\
' return string.format("party: in=%s leader=%s state=%d members=[%s] invites=[%s]", tostring(p:IsInParty()), tostring(p:IsPartyLeader()),'\
' p.CurrentPartyDetails.PartyState, table.concat(t, ", "), table.concat(inv, ", "))'
CHAT='lua local t={} FindFirstOf("Chat").ChatHistory:ForEach(function(_, e) local x=e:get() t[#t+1]=x.Message:ToString() end) return "chat: " .. table.concat(t, " | ")'
(
  sleep 75
  for f in $A $B; do echo "$FRIENDS" >> $f; echo "$PARTY" >> $f; done
  sleep 3; echo 'lua FindFirstOf("MOBAFriends"):SendFriendRequestDisplayName("'$BTAG'") return "A: friend request to '$BTAG'"' >> $A
  sleep 6; for f in $A $B; do echo "$FRIENDS" >> $f; done
  sleep 1; echo 'lua local f=FindFirstOf("MOBAFriends"); local id="" f.IncomingFriendRequests:ForEach(function(_, e) id=e:get().UserId:ToString() end)'\
' f:AcceptFriendRequest(id) return "B: accepted " .. id' >> $B
  sleep 6; for f in $A $B; do echo "$FRIENDS" >> $f; done
  sleep 1; echo 'lua return "A: invite -> " .. tostring(FindFirstOf("MOBAPartySubsystem"):InviteToParty("'$BID'"))' >> $A
  sleep 5; for f in $A $B; do echo "$PARTY" >> $f; done
  sleep 1; echo 'lua local p=FindFirstOf("MOBAPartySubsystem"); local r="no invite" p.PartyInvitesIn:ForEach(function(_, e) local x=e:get()'\
' if r == "no invite" then r=tostring(p:AcceptPartyInvite(x.PartyId:ToString(), x.InvitationToken:ToString())) end end) return "B: join -> " .. r' >> $B
  sleep 8; for f in $A $B; do echo "$PARTY" >> $f; echo 'shot showui' >> $f; done
  sleep 2; echo 'lua FindFirstOf("Chat"):ExecuteChatCommand("/p hello party") return "A: party chat sent"' >> $A
  echo 'lua FindFirstOf("Chat"):ExecuteChatCommand("/w '$ATAG' psst full tag") return "B: whisper sent"' >> $B
  sleep 1; echo 'lua FindFirstOf("Chat"):ExecuteChatCommand("/w '${R}a' psst short name") return "B: whisper 2 sent"' >> $B
  sleep 5; for f in $A $B; do echo "$CHAT" >> $f; echo 'shot showui' >> $f; done
  sleep 2; echo 'lua FindFirstOf("MOBAMatchMakerSubsystem"):MatchMakerStart() return "A: PLAY"' >> $A
  sleep 12; for f in $A $B; do echo "$PARTY" >> $f; done
  echo 'lua FindFirstOf("MOBAMatchMakerSubsystem"):MatchMakerLeaveQueue() FindFirstOf("MOBAPartySubsystem"):ReportLeaveQueue() return "A: left the queue"' >> $A
  sleep 6; for f in $A $B; do echo "$PARTY" >> $f; done
) &
UE4SS=1 GPU=1 NOMOVIES=1 BACKEND=127.0.0.1:8080 RUN_BACKEND=1 \
  BACKEND_ARGS="--data $PWD/work/run/$R-store.json --instances $PWD/work/run/$R-hosts --host-standby 0 --match-wait 600" \
  tools/run/headless.sh "${DURATION:-150}" "${CLIENT_DIR:-clients/fangs-2023-02-15-b10554626}" \
  -- $R-a:0:"-TestUser=${R}a -TestPass=x" -- $R-b:3:"-TestUser=${R}b -TestPass=x" 2>&1 | grep -v Segmentation
wait
for n in a b; do
  grep -h 'lua \(ok\|error\)' work/run/$R-$n/MOBA/Binaries/Win64/fangsctl.log | sed "s/^/$n: /" | cut -c1-300
  grep -h 'friends:' work/run/$R-$n/MOBA/Binaries/Win64/fangsboot.log | sed "s/^/$n boot: /"
done
echo "backend:"; grep -h '"mm": "\(queue join\|party queued\|party ticket dropped\)"\|"ws": "social"' work/logs/$R-a-backend.jsonl | cut -c1-250
grep -h '"recv"' work/logs/$R-a-backend.jsonl | grep -o 'type: [A-Za-z0-9]*' | sort | uniq -c | sort -rn
grep -h '"status": 4[0-9][0-9]' work/logs/$R-a-backend.jsonl | cut -c1-200 | sort | uniq -c | head
rm -rf work/logs/$R-shots; mkdir -p work/logs/$R-shots
for n in a b; do
  for f in work/run/$R-$n.prefix/drive_c/users/*/AppData/Local/MOBA/Saved/Screenshots/WindowsNoEditor/*.png; do
    [[ -f $f ]] && cp "$f" work/logs/$R-shots/$n-$(basename "$f")
  done
done
ls work/logs/$R-shots
