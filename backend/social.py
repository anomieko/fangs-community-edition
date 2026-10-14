"""Friends, presence, parties and chat over the AccelByte lobby websocket (Feb 2023 client).

Frames are "key: value" lines (AccelByte lobby protocol); the client turns them into JSON with a small parser
(AccelByteMessageParser): a value starting with [ is a list (items quoted here, so empty items survive), { an
object, anything else a string (numbers and enum names convert from strings). Values must not contain line
breaks. Every response echoes the request id and carries code 0 on success; the game's handlers only check
for "0", any other code is a failure (11232 is special: the client re-requests party info on it, never sent).

Friends and friend requests are kept in the store; presence and parties only in memory. A player whose lobby
connection drops is kept (party, "online") for GRACE seconds: the game reconnects after map changes.
Party members tell each other their hero, skin, matchmaking token, ... with signalingP2PNotif messages, which
are relayed (only between friends and party mates) with destinationId set to the sender.
"""
import asyncio, time, uuid

GRACE = 60
MAX_PARTY = 4          # a matchmade game is 4 vs 4 and a party always plays on one team
AVAILABILITY = ('offline', 'online', 'busy', 'invisible')   # EAvailability, by name
ERR_BAD_REQUEST, ERR_IN_PARTY, ERR_NOT_IN_PARTY, ERR_CANT_INVITE, ERR_BAD_INVITE, ERR_NOT_LEADER, ERR_FRIEND, \
    ERR_OFFLINE = 11201, 11221, 11231, 11253, 11271, 11301, 11401, 11501


def _clean(s):
    return str(s).replace('\r', ' ').replace('\n', ' ').strip()


def _value(v):
    if isinstance(v, (list, tuple)):
        return '[' + ','.join('"' + _clean(x).replace('"', '') + '"' for x in v) + ']'
    if isinstance(v, dict):
        return '{}' if not v else '{' + ','.join(f'"{k}":"{_clean(x)}"' for k, x in v.items()) + '}'
    s = _clean(v)
    return '​' + s if s[:1] in ('[', '{') else s


def frame(type_, **fields):
    return '\n'.join([f'type: {type_}'] + [f'{k}: {_value(v)}' for k, v in fields.items()])


def chat_text(s):
    """A chat line as a frame value: backslashes kept (the client reads JSON escapes), quotes at either end
    kept (the parser drops a leading and a trailing one), no list/object parsing."""
    s = _clean(s).replace('\\', '\\\\')
    if s[:1] in ('[', '{', '"'):
        s = '​' + s
    if s.endswith('"'):
        s += '​'
    return s[:500]


def iso(t):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))


class Conn:
    def __init__(self, ws):
        self.ws, self.availability, self.activity, self.last_seen = ws, 'online', '', time.time()
        self.grace = None   # task that drops the player GRACE s after the connection closed


class Party:
    def __init__(self, leader):
        self.id, self.token = uuid.uuid4().hex, uuid.uuid4().hex
        self.leader, self.members, self.invitees, self.updated = leader, [leader], [], time.time()

    def view(self):
        return {'partyID': self.id, 'leaderID': self.leader, 'leader': self.leader, 'members': self.members,
                'invitees': self.invitees, 'invitationToken': self.token}


class Social:
    def __init__(self, app):
        self.app, self.conns, self.parties, self.party_of = app, {}, {}, {}
        data = app['store'].data
        self.friends = data.setdefault('friends', {})            # uid -> [uid] (both directions)
        self.requests = data.setdefault('friend_requests', {})   # receiver uid -> [sender uid]

    # ------------------------------------------------------------ plumbing

    def log(self, **kw):
        self.app['log']({'ws': 'social', **kw})

    def save(self):
        self.app['store'].save()

    def user(self, uid):
        return self.app['store'].user_by_id(uid)

    def online(self, uid):
        c = self.conns.get(uid)
        return c is not None and c.ws is not None and not c.ws.closed

    async def send(self, uid, type_, **fields):
        c = self.conns.get(uid)
        if c is None or c.ws is None or c.ws.closed:
            return False
        try:
            await c.ws.send_str(frame(type_, **fields))
            return True
        except (ConnectionError, RuntimeError):
            return False

    async def reply(self, ws, t, mid, code=0, **fields):
        await ws.send_str(frame(t[:-len('Request')] + 'Response', id=mid, code=code, **fields))

    def friends_of(self, uid):
        return self.friends.get(uid, [])

    def presence(self, uid):
        c = self.conns.get(uid)
        if c is None or (c.ws is None and c.grace is None):
            return 'offline', '', iso(c.last_seen if c else 0)
        return c.availability, c.activity, iso(c.last_seen)

    async def tell_friends_status(self, uid):
        availability, activity, seen = self.presence(uid)
        for f in self.friends_of(uid):
            await self.send(f, 'userStatusNotif', userID=uid, availability=availability, activity=activity,
                            namespace='fangs', lastSeenAt=seen)

    # ------------------------------------------------------------ connections

    async def connect(self, uid, ws):
        old = self.conns.get(uid)
        if old and old.ws is not None and old.ws is not ws and not old.ws.closed:
            self.log(event='replaced connection', user=uid)
            await old.ws.close()          # the same player logged in again (one lobby connection each)
        if old and old.grace:
            old.grace.cancel()
        reconnect = old is not None
        c = self.conns[uid] = old or Conn(ws)
        c.ws, c.grace, c.last_seen = ws, None, time.time()
        p = self.parties.get(self.party_of.get(uid))
        if reconnect and p:
            for m in p.members:
                if m != uid:
                    await self.send(m, 'partyConnectNotif', userId=uid, partyId=p.id)

    def disconnect(self, uid, ws):
        c = self.conns.get(uid)
        if c is None or c.ws is not ws:
            return                        # an old, replaced connection
        c.ws, c.last_seen = None, time.time()
        c.grace = asyncio.create_task(self._drop_later(uid, c))
        p = self.parties.get(self.party_of.get(uid))
        if p:
            for m in p.members:
                if m != uid:
                    asyncio.create_task(self.send(m, 'partyDisconnectNotif', userId=uid, partyId=p.id))

    async def _drop_later(self, uid, c):
        try:
            await asyncio.sleep(GRACE)
        except asyncio.CancelledError:
            return
        if self.conns.get(uid) is not c or c.ws is not None:
            return
        c.grace = None
        self.log(event='offline', user=uid)
        for p in list(self.parties.values()):   # unanswered invites don't hold a party slot
            if uid in p.invitees:
                p.invitees.remove(uid)
                await self.party_update(p)
        await self.leave_party(uid)
        await self.tell_friends_status(uid)
        self.conns.pop(uid, None)

    # ------------------------------------------------------------ messages

    async def handle(self, uid, ws, t, f):
        """True if the frame was handled here (else the caller acks it generically)."""
        fn = getattr(self, 'on_' + t, None)
        if fn is None:
            return False
        try:
            await fn(uid, ws, t, f.get('id', ''), f)
        except (ConnectionError, RuntimeError) as e:
            self.log(event='send failed', type=t, error=str(e))
        return True

    # friends

    async def on_requestFriendsRequest(self, me, ws, t, mid, f):
        other = f.get('friendId', '').strip()
        if other == me or not self.user(other):
            return await self.reply(ws, t, mid, ERR_FRIEND)
        if other in self.friends_of(me):
            return await self.reply(ws, t, mid)
        if other in self.requests.get(me, []):       # they asked first: that's a yes
            await self.reply(ws, t, mid)
            return await self._accept(me, other)
        lst = self.requests.setdefault(other, [])
        if me not in lst:
            lst.append(me)
            self.save()
        await self.reply(ws, t, mid)
        await self.send(other, 'requestFriendsNotif', friendId=me)

    async def on_cancelFriendsRequest(self, me, ws, t, mid, f):
        other = f.get('friendId', '').strip()
        if me in self.requests.get(other, []):
            self.requests[other].remove(me)
            self.save()
            await self.send(other, 'cancelFriendsNotif', userId=me)
        await self.reply(ws, t, mid)

    async def on_acceptFriendsRequest(self, me, ws, t, mid, f):
        other = f.get('friendId', '').strip()
        if other not in self.requests.get(me, []):
            return await self.reply(ws, t, mid, ERR_FRIEND)
        await self.reply(ws, t, mid)
        await self._accept(me, other)

    async def _accept(self, me, other):
        """me says yes to other's friend request."""
        for x, y in ((me, other), (other, me)):
            lst = self.friends.setdefault(x, [])
            if y not in lst:
                lst.append(y)
        for x, y in ((me, other), (other, me)):
            if y in self.requests.get(x, []):
                self.requests[x].remove(y)
        self.save()
        await self.send(other, 'acceptFriendsNotif', friendId=me)
        for x, y in ((me, other), (other, me)):
            availability, activity, seen = self.presence(y)
            await self.send(x, 'userStatusNotif', userID=y, availability=availability, activity=activity,
                            namespace='fangs', lastSeenAt=seen)

    async def on_rejectFriendsRequest(self, me, ws, t, mid, f):
        other = f.get('friendId', '').strip()
        if other in self.requests.get(me, []):
            self.requests[me].remove(other)
            self.save()
            await self.send(other, 'rejectFriendsNotif', userId=me)
        await self.reply(ws, t, mid)

    async def on_unfriendRequest(self, me, ws, t, mid, f):
        other = f.get('friendId', '').strip()
        if other in self.friends_of(me):
            self.friends[me].remove(other)
            if me in self.friends_of(other):
                self.friends[other].remove(me)
            self.save()
            await self.send(other, 'unfriendNotif', friendId=me)
        await self.reply(ws, t, mid)

    async def on_listOfFriendsRequest(self, me, ws, t, mid, f):
        await self.reply(ws, t, mid, friendsId=self.friends_of(me))

    async def on_listIncomingFriendsRequest(self, me, ws, t, mid, f):
        await self.reply(ws, t, mid, friendsId=self.requests.get(me, []))

    async def on_listOutgoingFriendsRequest(self, me, ws, t, mid, f):
        await self.reply(ws, t, mid, friendsId=[u for u, senders in self.requests.items() if me in senders])

    async def on_getFriendshipStatusRequest(self, me, ws, t, mid, f):
        other = f.get('friendId', '').strip()
        status = (3 if other in self.friends_of(me) else 2 if other in self.requests.get(me, [])
                  else 1 if me in self.requests.get(other, []) else 0)
        await self.reply(ws, t, mid, friendshipStatus=status)

    async def on_friendsStatusRequest(self, me, ws, t, mid, f):
        ids = self.friends_of(me)
        rows = [self.presence(u) for u in ids]
        await self.reply(ws, t, mid, friendsId=ids, availability=[r[0] for r in rows],
                         activity=[r[1] for r in rows], lastSeenAt=[r[2] for r in rows])

    # presence

    async def on_setUserStatusRequest(self, me, ws, t, mid, f):
        c = self.conns.get(me)
        availability = f.get('availability', 'online').strip().lower()
        if c:
            c.availability = availability if availability in AVAILABILITY else 'online'
            c.activity, c.last_seen = _clean(f.get('activity', ''))[:64], time.time()
        await self.reply(ws, t, mid)
        await self.tell_friends_status(me)

    # parties

    def party(self, uid):
        return self.parties.get(self.party_of.get(uid))

    async def party_update(self, p):
        p.updated = time.time()
        for m in p.members:
            await self.send(m, 'partyDataUpdateNotif', partyId=p.id, namespace='fangs', leader=p.leader,
                            members=p.members, invitees=p.invitees, custom_attribute={}, updatedAt=iso(p.updated))

    async def on_partyCreateRequest(self, me, ws, t, mid, f):
        if self.party(me):
            return await self.reply(ws, t, mid, ERR_IN_PARTY)
        p = Party(me)
        self.parties[p.id], self.party_of[me] = p, p.id
        self.log(event='party created', party=p.id, leader=me)
        await self.reply(ws, t, mid, **p.view(), partyCode='')

    async def on_partyInfoRequest(self, me, ws, t, mid, f):
        p = self.party(me)
        if p is None:   # not in a party: the client reads "one member or none" as no party
            return await self.reply(ws, t, mid, partyID='', leaderID='', leader='', members=[], invitees=[],
                                    invitationToken='')
        await self.reply(ws, t, mid, **p.view())

    async def on_partyInviteRequest(self, me, ws, t, mid, f):
        other, p = f.get('friendID', '').strip(), self.party(me)
        if p is None:
            p = Party(me)   # the client normally creates one first
            self.parties[p.id], self.party_of[me] = p, p.id
        if other in p.invitees:   # the client sends each invite twice: one notification is enough
            return await self.reply(ws, t, mid, inviteeID=other)
        if (other == me or not self.online(other) or other in p.members or self.party(other)
                or len(p.members) + len(p.invitees) >= MAX_PARTY
                or other not in self.friends_of(me)):
            return await self.reply(ws, t, mid, ERR_CANT_INVITE, inviteeID=other)
        if other not in p.invitees:
            p.invitees.append(other)
        await self.reply(ws, t, mid, inviteeID=other)
        await self.send(other, 'partyGetInvitedNotif', **{'from': me}, partyID=p.id, invitationToken=p.token)
        for m in p.members:
            await self.send(m, 'partyInviteNotif', inviterID=me, inviteeID=other)
        await self.party_update(p)

    async def on_partyJoinRequest(self, me, ws, t, mid, f):
        p = self.parties.get(f.get('partyID', '').strip())
        if p is not None and me in p.members:   # already joined (an invite accepted twice)
            return await self.reply(ws, t, mid, **p.view())
        if p is None or f.get('invitationToken', '').strip() != p.token or me not in p.invitees \
                or len(p.members) >= MAX_PARTY:
            return await self.reply(ws, t, mid, ERR_BAD_INVITE)
        if self.party(me) and self.party(me) is not p:
            await self.leave_party(me)
        p.invitees.remove(me)
        if me not in p.members:
            p.members.append(me)
        self.party_of[me] = p.id
        self.log(event='party joined', party=p.id, user=me)
        await self.reply(ws, t, mid, **p.view())
        for m in p.members:
            if m != me:
                await self.send(m, 'partyJoinNotif', userId=me)
        await self.party_update(p)

    async def on_partyRejectRequest(self, me, ws, t, mid, f):
        p = self.parties.get(f.get('partyID', '').strip())
        await self.reply(ws, t, mid, partyID=f.get('partyID', '').strip())
        if p and me in p.invitees:
            p.invitees.remove(me)
            await self.send(p.leader, 'partyRejectNotif', partyID=p.id, leaderID=p.leader, leader=p.leader, userID=me)
            await self.party_update(p)

    async def on_partyLeaveRequest(self, me, ws, t, mid, f):
        await self.reply(ws, t, mid)
        await self.leave_party(me)

    async def leave_party(self, uid):
        p = self.party(uid)
        self.party_of.pop(uid, None)
        if p is None:
            return
        if uid in p.members:
            p.members.remove(uid)
        mm = self.app.get('matchmaker')
        if mm is not None and hasattr(mm, 'party_changed'):
            await mm.party_changed(p.id, left=uid)
        if not p.members:
            self.parties.pop(p.id, None)
            self.log(event='party disbanded', party=p.id)
            return
        if p.leader == uid:
            p.leader = p.members[0]
        for m in p.members:
            await self.send(m, 'partyLeaveNotif', userID=uid, leaderID=p.leader, leader=p.leader, partyId=p.id)
        await self.party_update(p)

    async def on_partyKickRequest(self, me, ws, t, mid, f):
        other, p = f.get('memberID', '').strip(), self.party(me)
        if p is None or p.leader != me or other not in p.members or other == me:
            return await self.reply(ws, t, mid, ERR_NOT_LEADER, userId=other)
        await self.reply(ws, t, mid, userId=other)
        for m in list(p.members):
            await self.send(m, 'partyKickNotif', leaderID=me, leader=me, userID=other, partyId=p.id)
        p.members.remove(other)
        self.party_of.pop(other, None)
        mm = self.app.get('matchmaker')
        if mm is not None and hasattr(mm, 'party_changed'):
            await mm.party_changed(p.id, left=other)
        await self.party_update(p)

    async def on_partyPromoteLeaderRequest(self, me, ws, t, mid, f):
        other, p = f.get('newLeaderUserId', '').strip(), self.party(me)
        if p is None or p.leader != me or other not in p.members:
            return await self.reply(ws, t, mid, ERR_NOT_LEADER)
        p.leader = other
        await self.reply(ws, t, mid, **p.view())
        await self.party_update(p)

    # chat

    async def on_personalChatRequest(self, me, ws, t, mid, f):
        to, text = f.get('to', '').strip(), f.get('payload', '')
        if not self.online(to) or to == me:
            return await self.reply(ws, t, mid, ERR_OFFLINE)
        await self.reply(ws, t, mid)
        await self.send(to, 'personalChatNotif', id=uuid.uuid4().hex, **{'from': me}, to=to, payload=chat_text(text),
                        receivedAt=iso(time.time()))

    async def on_partyChatRequest(self, me, ws, t, mid, f):
        p, text = self.party(me), f.get('payload', '')
        if p is None:
            return await self.reply(ws, t, mid, ERR_NOT_IN_PARTY)
        await self.reply(ws, t, mid)
        for m in p.members:
            if m != me:
                await self.send(m, 'partyChatNotif', id=uuid.uuid4().hex, **{'from': me}, to=p.id,
                                payload=chat_text(text), receivedAt=iso(time.time()))

    # party member details (hero, skin, matchmaking token, ...), sent player to player

    async def on_signalingP2PNotif(self, me, ws, t, mid, f):
        to = f.get('destinationId', '').strip()
        p = self.party(me)
        if to == me or not (to in self.friends_of(me) or (p and to in p.members + p.invitees)):
            return self.log(event='signaling dropped', user=me, to=to)
        await self.send(to, 'signalingP2PNotif', destinationId=me, message=f.get('message', ''))

    # ------------------------------------------------------------ REST helpers

    def presence_rows(self, ids):
        rows = []
        for uid in ids:
            availability, activity, seen = self.presence(uid)
            rows.append({'userID': uid, 'availability': availability, 'activity': activity, 'namespace': 'fangs',
                         'lastSeenAt': seen})
        return rows

    def party_members(self, uid):
        """Members of uid's party (uid alone if in none), leader first."""
        p = self.party(uid)
        if p is None:
            return [uid]
        return [p.leader] + [m for m in p.members if m != p.leader]

    def party_id(self, uid):
        return self.party_of.get(uid)
