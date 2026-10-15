"""Matchmaker for the client's matchmaking websocket (Play -> Casual / Ranked).

Casual (queue ids "casual" / "beginner"): no ratings, everyone who queues is pooled. A match is made once
`size` players are queued (a full game: the queue never starts a match with empty seats). With `wait` > 0 it
also starts when the longest-waiting player has waited that long, with whoever is queued (at least 2 players).

Ranked (queue id "ranked", MapGameMode 3): `ranked_size` players (n vs n) chosen and split into teams by
allocator.py from their skill ratings (skill.py, ranked.py): fair games first, quality limits widening with the
wait, mirrored party shapes first. Only these games change ratings (settled when the result arrives,
`ranked_result`). A ranked ticket can wait a long time when nobody of similar skill is queued.

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
The game server is told the match size and a random map from FANGSConfig CasualMaps / RankedMaps
(fangshost_match.json, see FangsHost); the lobby is otherwise hard-wired to 8 players and gets no map.

Parties (social.py): the party leader's QueueJoinRequest opens a ticket for the whole party and its Queued
answer carries msg.partyToken; the leader's client hands the token to the members (signaling), who queue with
{"partyToken": T}. A party ticket is matched once every member has joined (or after PARTY_WAIT s, without the
missing ones), always as a whole and on one team. If anyone of a party leaves or rejects, the whole ticket is
dropped (the others go idle; the clients' own party logic makes them leave the queue too).
"""
import asyncio, base64, json, random, time, uuid

from aiohttp import web, WSMsgType

import allocator, ranked
from hosts import NoFreeSlot

AUTH_PREFIX = 'Bearer secret-token:accelbyte/'
STARTING_EXPIRY_MS = 240_000   # keeps the accept dialog open while the game server boots
PARTY_WAIT = 20                # seconds a party ticket waits for members who haven't queued
RANKED_QUEUE = 'ranked'        # QueueJoinRequest id for Ranked (FANGSConfig MatchMakerABRanked)
RANKED_MAX_PARTY = 2           # the game's own limit (WB_ChoseGameMode "ranked_party_limit")
TEAM_NAMES = ('TeamA', 'TeamB')   # token team index 0 takes the even seats, TeamA (BP_PC_Lobby GetFreeTeamSlot)


def _b64(obj):
    return base64.b64encode(json.dumps(obj, separators=(',', ':')).encode()).decode()


def assignment_token(ticket, team):
    payload = {'sub': ticket, 'assign': {'extensions': {'team': {'ticketToTeamIndex': {ticket: team}}}}}
    return f"{_b64({'alg': 'none', 'typ': 'JWT'})}.{_b64(payload)}.fangs"


class Ticket:
    """One player, or a party that queues together."""

    def __init__(self, leader, expected=(), ranked=False):
        self.token = uuid.uuid4().hex
        self.leader, self.expected, self.joined = leader, list(expected) or [leader], [leader]
        self.queued_at = time.time()
        self.ranked = ranked

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
    def __init__(self, tickets, accept_secs, size, sides=None, ranked=None):
        self.id = uuid.uuid4().hex
        self.tickets = list(tickets)            # to put them back in line if the match falls through
        self.players = [p for t in tickets for p in t.joined]
        self.team = {}                          # user id -> 0/1; a party is never split
        self.ranked = ranked                    # ranked: what the queue decided (for the log)
        sides = sides or split(tickets, (size + 1) // 2) or split(tickets, len(self.players))
        for t, side in zip(tickets, sides):
            for p in t.joined:
                self.team[p] = side
        self.accepted = set()
        self.deadline = time.time() + accept_secs + 2   # the client rejects by itself at accept_secs
        self.starting = False
        self.allocating = False                 # asked the host manager for its server (which counts it from then)


class Matchmaker:
    def __init__(self, app, *, size=8, wait=0.0, accept_secs=15, ranked_size=8, ranked_widen_speed=1.0):
        self.app, self.size, self.wait, self.accept_secs = app, size, wait, accept_secs
        self.ranked_policy = allocator.Policy(team_size=max(1, ranked_size // 2), widen_speed=ranked_widen_speed)
        self.clients = {}    # user id -> websocket
        self.tickets = {}    # token -> Ticket waiting in line
        self.ticket_of = {}  # user id -> token (while in line)
        self.matches = {}    # match id -> Match (until the players got their server)
        self.match_of = {}   # user id -> match id
        self.ranked_games = {}   # match id (= its server's session id) -> {'parties', 'teams'}, until its result

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
                    queue_id = msg.get('id')
                    if queue_id and (queue_id == RANKED_QUEUE) != ticket.ranked:
                        # a member asking for the other mode: each client brings its own game mode into the lobby,
                        # so the party can't play together this way; stop it whole (never the leader without them)
                        self.log('party member queued for another mode', user=uid, token=token, id=queue_id)
                        await self.drop_ticket(ticket, 'member in another mode')
                        return await self.status(uid, 'Idle', id=uid)
                    ticket.joined.append(uid)
                    self.ticket_of[uid] = token
                else:
                    social = self.app.get('social')
                    party = social.party_members(uid) if social is not None else [uid]
                    if party[0] != uid:          # only the leader queues a party
                        party = [uid]
                    is_ranked = msg.get('id') == RANKED_QUEUE
                    if is_ranked and len(party) > min(RANKED_MAX_PARTY, self.ranked_policy.team_size):
                        self.log('ranked party too big', user=uid, party=party)
                        return await self.status(uid, 'Idle', id=uid)
                    ticket = Ticket(uid, party, ranked=is_ranked)
                    self.tickets[ticket.token], self.ticket_of[uid] = ticket, ticket.token
                    if ticket.party:
                        self.log('party queued', user=uid, party=party, token=ticket.token, ranked=is_ranked)
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
        for p in list(m.players):
            if self.matches.get(mid) is not m:   # cancelled while we announced it: its players are told already
                return
            await self.status(p, 'Accepted', match={'id': m.id, 'accepted': len(m.accepted), 'expiresInMillis': left})
        if self.matches.get(mid) is not m or m.starting:
            return
        if m.accepted >= set(m.players):
            m.starting = True
            asyncio.create_task(self.start(m))

    def pick_map(self, key='CasualMaps'):
        """Random map from FANGSConfig CasualMaps / RankedMaps (the lobby server doesn't pick one by itself here)."""
        pool = []
        for version in (self.app['store'].data['game_records'].get('FANGSConfig') or {}).values():
            if isinstance(version, dict):
                pool += [m for m in version.get(key, []) if isinstance(m, dict) and m.get('Map')]
        return random.choice(pool) if pool else (self.pick_map() if key != 'CasualMaps' else None)

    def ranked_result(self, session_id):
        """A ranked game whose server is `session_id` (once; None for any other game): {'parties': [[user id]],
        'teams': {user id: 'TeamA' / 'TeamB'}} as assigned when its server started (ranked.settle_match)."""
        return self.ranked_games.pop(session_id, None)

    async def start(self, m):
        for p in m.players:
            await self.status(p, 'Accepted', match={'id': m.id, 'accepted': len(m.players),
                                                     'expiresInMillis': STARTING_EXPIRY_MS})
        self.log('starting', match=m.id, players=m.players)
        try:
            match = {'size': len(m.players)}
            if (game_map := self.pick_map('RankedMaps' if m.ranked else 'CasualMaps')):
                match.update(map=game_map['Map'], map_name=game_map.get('Name', game_map['Map']))
            m.allocating = True
            host = await self.app['hosts'].allocate(m.id, match=match)
        except NoFreeSlot as e:   # a lobby took the last server meanwhile: back in line, keeping their place
            self.log('start failed', match=m.id, error=str(e))
            for t in m.tickets:                           # without those who left while it was starting
                t.joined = [p for p in t.joined if p in m.players]
            m.tickets = [t for t in m.tickets if t.joined]
            await self.cancel(m, drop=set(), reason='no free game server')
            return
        except Exception as e:  # noqa: BLE001 - the server failed to start: tell the players instead of leaving them waiting
            self.log('start failed', match=m.id, error=str(e))
            self.matches.pop(m.id, None)
            for p in m.players:
                self.match_of.pop(p, None)
                await self.status(p, 'Idle', id=p)
            return
        if not m.players:   # everyone left while it booted: don't keep a server for nobody
            self.matches.pop(m.id, None)
            await self.app['hosts'].stop(host, 'everyone left before the match started')
            return
        address = f"{self.app['cfg'].public_ip}:{host.port}"
        if m.ranked:   # the roster: everyone still in when the server was ready (leave() drops those who left)
            self.ranked_games[m.id] = {'parties': [[p for p in t.joined if p in m.players] for t in m.tickets],
                                       'teams': {p: TEAM_NAMES[m.team[p]] for p in m.players}}
            for old in list(self.ranked_games)[:-50]:      # results that never came (crashed servers)
                del self.ranked_games[old]
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
        if self.free_servers() <= 0:
            return   # every game server is taken or promised to a match: keep everyone queued
        m = self.casual_match(now) or self.ranked_match(now)
        if m is None:
            return
        self.matches[m.id] = m
        for ticket in m.tickets:
            self.tickets.pop(ticket.token, None)
            for p in ticket.joined:
                self.ticket_of.pop(p, None)
        for p in m.players:
            self.match_of[p] = m.id
        for p in m.players:
            await self.status(p, 'Matched', match={'id': m.id, 'expiresInMillis': self.accept_secs * 1000})
        self.log('matched', match=m.id, players=m.players, teams=m.team, **({'ranked': m.ranked} if m.ranked else {}))

    def free_servers(self):
        """Game servers a new match could get: what the host manager can still serve (HostManager.capacity), less
        the matches that hold none yet. A match is counted until it asks for its server, then the host manager counts
        it, so more matches never form than there are servers (with a small population, queued players wait for the
        next server instead of being matched into a game that can't start)."""
        return self.app['hosts'].capacity() - sum(1 for m in self.matches.values() if not m.allocating)

    def casual_match(self, now):
        """First come, first served: the oldest tickets that fill a game (or fewer after `wait`)."""
        picked, count = [], 0
        for ticket in sorted((t for t in self.tickets.values() if not t.ranked), key=lambda t: t.queued_at):
            if ticket.ready(now) and count + len(ticket.joined) <= self.size \
                    and split(picked + [ticket], (self.size + 1) // 2) is not None:   # even teams stay possible
                picked.append(ticket)
                count += len(ticket.joined)
        early = self.wait > 0 and count >= 2 and now - picked[0].queued_at >= self.wait
        if not picked or (count < self.size and not early):
            return None
        return Match(picked, self.accept_secs, self.size)

    def ranked_match(self, now):
        """The allocator's first proposal among the ranked tickets, if any. Costs nothing until a full game's
        worth of ranked players is queued; then one search per second, ~1.5 ms with up to 16 players queued
        (backend/tests/test_ranked.py measures it)."""
        n = self.ranked_policy.team_size
        ready = [t for t in self.tickets.values() if t.ranked and t.ready(now)]
        if sum(len(t.joined) for t in ready) < 2 * n:
            return None
        store = self.app['store']
        queued = [allocator.Ticket(t.token, tuple(ranked.rating_of(store, p) for p in t.joined), min(t.queued_at, now))
                  for t in ready]
        proposals = allocator.allocate(queued, now, self.ranked_policy,
                                       ranked.previous_opponents(store, [p for t in ready for p in t.joined]), limit=1)
        if not proposals:
            return None
        best, by_token = proposals[0], {t.token: t for t in ready}
        logical = (best.team_a, best.team_b)
        bit = random.getrandbits(1)   # which logical team gets which side: independent of ids and waits
        picked = [by_token[t.ticket_id] for team in logical for t in team]
        sides = [i ^ bit for i, team in enumerate(logical) for _ in team]
        info = {'win_chance': round(best.probability, 3), 'predicted': round(best.frozen.predicted_win_a, 3),
                'level': best.composition_level, 'score': round(best.score, 3),
                'waits': [round(now - max(t.queued_at for t in picked)), round(now - min(t.queued_at for t in picked))],
                'ratings': [[round(p.rating) for t in team for p in t.players] for team in logical]}
        return Match(picked, self.accept_secs, 2 * n, sides=sides, ranked=info)
