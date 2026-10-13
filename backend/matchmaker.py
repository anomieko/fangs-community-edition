"""Best-effort matchmaker for the client's matchmaking websocket (Play -> Casual / Ranked / beginner queue).

No ratings: everyone who queues is pooled. A match is made as soon as `size` players are queued, or when
the longest-waiting player has waited `wait` seconds (then with whoever is queued, at least 1).

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
"""
import asyncio, base64, json, random, time, uuid

from aiohttp import web, WSMsgType

AUTH_PREFIX = 'Bearer secret-token:accelbyte/'
STARTING_EXPIRY_MS = 240_000   # keeps the accept dialog open while the game server boots


def _b64(obj):
    return base64.b64encode(json.dumps(obj, separators=(',', ':')).encode()).decode()


def assignment_token(ticket, team):
    payload = {'sub': ticket, 'assign': {'extensions': {'team': {'ticketToTeamIndex': {ticket: team}}}}}
    return f"{_b64({'alg': 'none', 'typ': 'JWT'})}.{_b64(payload)}.fangs"


class Match:
    def __init__(self, players, queued_at, accept_secs):
        self.id = uuid.uuid4().hex
        self.players = list(players)
        self.queued_at = dict(queued_at)        # to put players back in line if the match falls through
        self.accepted = set()
        self.deadline = time.time() + accept_secs + 2   # the client rejects by itself at accept_secs
        self.starting = False


class Matchmaker:
    def __init__(self, app, *, size=8, wait=15.0, accept_secs=15):
        self.app, self.size, self.wait, self.accept_secs = app, size, wait, accept_secs
        self.clients = {}    # user id -> websocket
        self.queue = {}      # user id -> time queued
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
        if uid in self.queue:
            await self.status(uid, 'Queued')
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
            if uid not in self.match_of:
                self.queue.setdefault(uid, time.time())
            await self.report(uid)
        elif t in ('ClientResetRequest', 'RejectMatchRequest'):
            await self.leave(uid, 'left' if t == 'ClientResetRequest' else 'rejected')
            await self.status(uid, 'Idle', id=uid)
        elif t == 'AcceptMatchRequest':
            await self.accept(uid, str(msg.get('id', '')))

    # ------------------------------------------------------------ queue / matches

    async def leave(self, uid, reason):
        self.queue.pop(uid, None)
        m = self.matches.get(self.match_of.get(uid))
        if not m:
            return
        if m.starting:   # game server is booting: it starts without them (FangsHost shrinks the lobby)
            m.players.remove(uid)
            self.match_of.pop(uid, None)
        else:
            await self.cancel(m, drop={uid}, reason=reason)

    async def cancel(self, m, drop, reason):
        """Match fell through: dropped players go idle, the others go back in line."""
        self.matches.pop(m.id, None)
        self.log('cancel', match=m.id, reason=reason, dropped=sorted(drop))
        for p in m.players:
            self.match_of.pop(p, None)
            if p in drop:
                continue
            self.queue[p] = m.queued_at.get(p, time.time())
            await self.status(p, 'Idle', id=p)       # closes the accept dialog
            await self.status(p, 'Queued')

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
        for i, p in enumerate(list(m.players)):
            self.match_of.pop(p, None)
            await self.send(p, 'ServerAssignmentResponse',
                            {'assignment': address, 'token': assignment_token(uuid.uuid4().hex, i % 2)})
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
        line = sorted(self.queue.items(), key=lambda kv: kv[1])
        if not line or (len(line) < self.size and now - line[0][1] < self.wait):
            return
        if not self.app['hosts'].free_ports():
            return   # all game server slots busy: keep everyone queued
        picked = dict(line[:self.size])
        m = Match(picked, picked, self.accept_secs)
        self.matches[m.id] = m
        for p in m.players:
            self.queue.pop(p, None)
            self.match_of[p] = m.id
            await self.status(p, 'Matched', match={'id': m.id, 'expiresInMillis': self.accept_secs * 1000})
        self.log('matched', match=m.id, players=m.players)
