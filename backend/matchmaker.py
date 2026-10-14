"""Best-effort matchmaker for the client's matchmaking websocket (Play -> Casual / Ranked / beginner queue).

No ratings: everyone who queues is pooled. A match is made once `size` players are queued (a full game:
the queue never starts a match with empty seats). With `wait` > 0 it also starts when the longest-waiting
player has waited that long, with whoever is queued (at least 2 players).

Protocol (UMOBAMatchMakerSubsystem in the Feb 2023 client; JSON text frames, subprotocol "json",
Authorization "Bearer secret-token:accelbyte/<access token>"):
  client -> {"msg_type": "ClientStatusRequest" | "QueueJoinRequest" | "ClientResetRequest" |
                         "AcceptMatchRequest" (msg.id) | "RejectMatchRequest" (msg.id), "msg": {...}}
  server -> ClientStatusResponse  msg.status = "Idle" (msg.id = matchmaker id) | "Queued" |
                                  "Matched" (msg.match.id, msg.match.expiresInMillis: accept dialog) |
                                  "Accepted" (msg.match.accepted, msg.match.expiresInMillis)
            ServerAssignmentResponse  msg.assignment = "<ip>:<port>", msg.token = JWT
The client then joins the game server like a custom lobby. The lobby server seats each player from the
token: payload (standard base64, not base64url) assign.extensions.team.ticketToTeamIndex[sub] -> team.
The game server is told the match size and a random map from FANGSConfig CasualMaps (fangshost_match.json,
see FangsHost); the lobby is otherwise hard-wired to 8 players and gets no map.

Parties (social.py): the party leader's QueueJoinRequest opens a ticket for the whole party and its Queued
answer carries msg.partyToken; the leader's client hands the token to the members (signaling), who queue with
{"partyToken": T}. A party ticket is matched once every member has joined (or after PARTY_WAIT s, without the
missing ones), always as a whole and on one team. If anyone of a party leaves or rejects, the whole ticket is
dropped (the others go idle; the clients' own party logic makes them leave the queue too).
"""
import asyncio, base64, json, random, time, uuid

from aiohttp import web, WSMsgType

AUTH_PREFIX = 'Bearer secret-token:accelbyte/'
STARTING_EXPIRY_MS = 240_000   # keeps the accept dialog open while the game server boots
PARTY_WAIT = 20                # seconds a party ticket waits for members who haven't queued


def _b64(obj):
    return base64.b64encode(json.dumps(obj, separators=(',', ':')).encode()).decode()


def assignment_token(ticket, team):
    payload = {'sub': ticket, 'assign': {'extensions': {'team': {'ticketToTeamIndex': {ticket: team}}}}}
    return f"{_b64({'alg': 'none', 'typ': 'JWT'})}.{_b64(payload)}.fangs"


class Ticket:
    """One player, or a party that queues together."""

    def __init__(self, leader, expected=()):
        self.token = uuid.uuid4().hex
        self.leader, self.expected, self.joined = leader, list(expected) or [leader], [leader]
        self.queued_at = time.time()

    @property
    def party(self):
        return len(self.expected) > 1

    def ready(self, now):
        return set(self.joined) >= set(self.expected) or now - self.queued_at >= PARTY_WAIT


def split(tickets, per_side):
    """Sides (0/1 per ticket) with at most per_side players each and as even as possible, or None.
    A party is never split; there are at most a few tickets, so all splits are tried."""
    sizes = [len(t.joined) for t in tickets]
    best = None
    for mask in range(1 << len(sizes)):
        a = sum(n for i, n in enumerate(sizes) if mask >> i & 1)
        b = sum(sizes) - a
        if a <= per_side and b <= per_side and (best is None or abs(a - b) < best[0]):
            best = (abs(a - b), [mask >> i & 1 for i in range(len(sizes))])
    return best and best[1]


class Match:
    def __init__(self, tickets, accept_secs, size):
        self.id = uuid.uuid4().hex
        self.tickets = list(tickets)            # to put them back in line if the match falls through
        self.players = [p for t in tickets for p in t.joined]
        self.team = {}                          # user id -> 0/1; a party is never split
        sides = split(tickets, (size + 1) // 2) or split(tickets, len(self.players))
        for t, side in zip(tickets, sides):
            for p in t.joined:
                self.team[p] = side
        self.accepted = set()
        self.deadline = time.time() + accept_secs + 2   # the client rejects by itself at accept_secs
        self.starting = False


class Matchmaker:
    def __init__(self, app, *, size=8, wait=0.0, accept_secs=15):
        self.app, self.size, self.wait, self.accept_secs = app, size, wait, accept_secs
        self.clients = {}    # user id -> websocket
        self.tickets = {}    # token -> Ticket waiting in line
        self.ticket_of = {}  # user id -> token (while in line)
        self.matches = {}    # match id -> Match (until the players got their server)
        self.match_of = {}   # user id -> match id

    def log(self, event, **kw):
        self.app['log']({'mm': event, **kw})

    async def send(self, uid, msg_type, msg):
        ws = self.clients.get(uid)
        if ws is not None and not ws.closed:
            try:
                await ws.send_str(json.dumps({'msg_type': msg_type, 'msg': msg}))
            except ConnectionError:
                pass

    async def status(self, uid, status, **kw):
        await self.send(uid, 'ClientStatusResponse', {'status': status, **kw})

    async def report(self, uid):
        m = self.matches.get(self.match_of.get(uid))
        t = self.tickets.get(self.ticket_of.get(uid))
        if t:
            await self.status(uid, 'Queued', **({'partyToken': t.token} if t.party and uid == t.leader else {}))
        elif m:
            left = STARTING_EXPIRY_MS if m.starting else max(0, int((m.deadline - 2 - time.time()) * 1000))
            await self.status(uid, 'Matched', match={'id': m.id, 'expiresInMillis': left})
        else:
            await self.status(uid, 'Idle', id=uid)

    # ------------------------------------------------------------ websocket

    async def handle(self, request):
        ws = web.WebSocketResponse(protocols=('json',), heartbeat=30)
        await ws.prepare(request)
        auth = request.headers.get('Authorization', '')
        who = self.app['store'].tokens.get(auth[len(AUTH_PREFIX):]) if auth.startswith(AUTH_PREFIX) else None
        uid = (who or {}).get('user_id')
        if not uid:
            await ws.close(code=4001, message=b'unauthorized')
            return ws
        old, self.clients[uid] = self.clients.get(uid), ws
        if old is not None:
            await old.close()
        try:
            async for frame in ws:
                if frame.type != WSMsgType.TEXT:
                    continue
                try:
                    data = json.loads(frame.data)
                    t, msg = data.get('msg_type', ''), data.get('msg') or {}
                except (ValueError, AttributeError):
                    continue
                self.log('recv', user=uid, type=t)
                await self.on_message(uid, t, msg)
        finally:
            if self.clients.get(uid) is ws:
                del self.clients[uid]
                await self.leave(uid, 'disconnected')
        return ws

    async def on_message(self, uid, t, msg):
        if t == 'ClientStatusRequest':
            await self.report(uid)
        elif t == 'QueueJoinRequest':
            self.log('queue join', user=uid, msg=json.dumps(msg)[:1000])
            if uid not in self.match_of and uid not in self.ticket_of:
                token = str(msg.get('partyToken') or '')
                if token:                       # a party member following the leader
                    ticket = self.tickets.get(token)
                    if ticket is None or uid not in ticket.expected:
                        return await self.status(uid, 'Idle', id=uid)
                    ticket.joined.append(uid)
                    self.ticket_of[uid] = token
                else:
                    social = self.app.get('social')
                    party = social.party_members(uid) if social is not None else [uid]
                    if party[0] != uid:          # only the leader queues a party
                        party = [uid]
                    ticket = Ticket(uid, party)
                    self.tickets[ticket.token], self.ticket_of[uid] = ticket, ticket.token
                    if ticket.party:
                        self.log('party queued', user=uid, party=party, token=ticket.token)
            await self.report(uid)
        elif t in ('ClientResetRequest', 'RejectMatchRequest'):
            await self.leave(uid, 'left' if t == 'ClientResetRequest' else 'rejected')
            await self.status(uid, 'Idle', id=uid)
        elif t == 'AcceptMatchRequest':
            await self.accept(uid, str(msg.get('id', '')))

    # ------------------------------------------------------------ queue / matches

    async def drop_ticket(self, ticket, reason, keep=()):
        """Take a ticket out of line; its players go idle (except those in keep)."""
        self.tickets.pop(ticket.token, None)
        for p in ticket.joined:
            self.ticket_of.pop(p, None)
        if ticket.party:
            self.log('party ticket dropped', token=ticket.token, reason=reason)
        for p in ticket.joined:
            if p not in keep:
                await self.status(p, 'Idle', id=p)

    async def leave(self, uid, reason):
        ticket = self.tickets.get(self.ticket_of.get(uid))
        if ticket:
            await self.drop_ticket(ticket, reason, keep={uid})
        m = self.matches.get(self.match_of.get(uid))
        if not m:
            return
        if m.starting:   # game server is booting: it starts without them (FangsHost shrinks the lobby)
            m.players.remove(uid)
            self.match_of.pop(uid, None)
        else:
            await self.cancel(m, drop={uid}, reason=reason)

    async def party_changed(self, party_id, left):
        """Someone left (or was kicked from) a party: its ticket in line is off."""
        for ticket in [t for t in self.tickets.values() if left in t.expected]:
            await self.drop_ticket(ticket, 'party changed')
        m = self.matches.get(self.match_of.get(left))
        if m and not m.starting and any(left in t.expected and t.party for t in m.tickets):
            await self.cancel(m, drop={left}, reason='party changed')

    async def cancel(self, m, drop, reason):
        """Match fell through: dropped players (and their party) go idle, the others go back in line."""
        self.matches.pop(m.id, None)
        self.log('cancel', match=m.id, reason=reason, dropped=sorted(drop))
        for p in m.players:
            self.match_of.pop(p, None)
        for ticket in m.tickets:
            if drop & set(ticket.joined):
                for p in ticket.joined:
                    await self.status(p, 'Idle', id=p)
                continue
            self.tickets[ticket.token] = ticket          # keeps its place in line
            for p in ticket.joined:
                self.ticket_of[p] = ticket.token
                await self.status(p, 'Idle', id=p)       # closes the accept dialog
            for p in ticket.joined:
                await self.report(p)

    async def accept(self, uid, mid):
        m = self.matches.get(mid)
        if not m or uid not in m.players or m.starting:
            return
        m.accepted.add(uid)
        left = max(0, int((m.deadline - 2 - time.time()) * 1000))
        for p in m.players:
            await self.status(p, 'Accepted', match={'id': m.id, 'accepted': len(m.accepted), 'expiresInMillis': left})
        if m.accepted >= set(m.players):
            m.starting = True
            asyncio.create_task(self.start(m))

    def pick_map(self):
        """Random map from FANGSConfig CasualMaps (the lobby server doesn't pick one by itself here)."""
        pool = []
        for version in (self.app['store'].data['game_records'].get('FANGSConfig') or {}).values():
            if isinstance(version, dict):
                pool += [m for m in version.get('CasualMaps', []) if isinstance(m, dict) and m.get('Map')]
        return random.choice(pool) if pool else None

    async def start(self, m):
        for p in m.players:
            await self.status(p, 'Accepted', match={'id': m.id, 'accepted': len(m.players),
                                                     'expiresInMillis': STARTING_EXPIRY_MS})
        self.log('starting', match=m.id, players=m.players)
        try:
            match = {'size': len(m.players)}
            if (game_map := self.pick_map()):
                match.update(map=game_map['Map'], map_name=game_map.get('Name', game_map['Map']))
            host = await self.app['hosts'].allocate(m.id, match=match)
        except Exception as e:  # noqa: BLE001 - tell the players instead of leaving them waiting
            self.log('start failed', match=m.id, error=str(e))
            self.matches.pop(m.id, None)
            for p in m.players:
                self.match_of.pop(p, None)
                await self.status(p, 'Idle', id=p)
            return
        address = f"{self.app['cfg'].public_ip}:{host.port}"
        self.matches.pop(m.id, None)
        for p in list(m.players):
            self.match_of.pop(p, None)
            await self.send(p, 'ServerAssignmentResponse',
                            {'assignment': address, 'token': assignment_token(uuid.uuid4().hex, m.team.get(p, 0))})
        self.log('assigned', match=m.id, server=address, players=m.players)

    async def run(self):
        while True:
            await asyncio.sleep(1)
            try:
                await self.tick()
            except Exception as e:  # noqa: BLE001 - keep matching even if one round fails
                self.log('tick error', error=repr(e))

    async def tick(self):
        now = time.time()
        for m in [m for m in self.matches.values() if not m.starting and now > m.deadline]:
            await self.cancel(m, drop=set(m.players) - m.accepted, reason='not accepted in time')
        picked, count = [], 0
        for ticket in sorted(self.tickets.values(), key=lambda t: t.queued_at):
            if ticket.ready(now) and count + len(ticket.joined) <= self.size \
                    and split(picked + [ticket], (self.size + 1) // 2) is not None:   # even teams stay possible
                picked.append(ticket)
                count += len(ticket.joined)
        early = self.wait > 0 and count >= 2 and now - picked[0].queued_at >= self.wait
        if not picked or (count < self.size and not early):
            return
        if not self.app['hosts'].free_ports():
            return   # all game server slots busy: keep everyone queued
        m = Match(picked, self.accept_secs, self.size)
        self.matches[m.id] = m
        for ticket in picked:
            self.tickets.pop(ticket.token, None)
            for p in ticket.joined:
                self.ticket_of.pop(p, None)
        for p in m.players:
            self.match_of[p] = m.id
            await self.status(p, 'Matched', match={'id': m.id, 'expiresInMillis': self.accept_secs * 1000})
        self.log('matched', match=m.id, players=m.players, teams=m.team)
