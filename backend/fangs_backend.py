#!/usr/bin/env python3
"""FANGS replacement backend — speaks the subset of the AccelByte API the game uses.

Discovery-driven: every request is logged (stdout + JSONL); anything not implemented
returns an AccelByte-style 404 so we can see what the game needs next.

Run:  backend/.venv/bin/python backend/fangs_backend.py --port 8080
"""
import argparse, asyncio, base64, hashlib, hmac, json, os, re, time, uuid
from pathlib import Path

from aiohttp import web, WSMsgType

from hosts import HostManager

NAMESPACE = 'fangs'
ROUTES = []  # (method-or-*, compiled regex, handler)


def route(method, pattern):
    def deco(fn):
        ROUTES.append((method, re.compile('^' + pattern + '$'), fn))
        return fn
    return deco


def now_iso():
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())


def err(status, code, msg):
    return web.json_response({'errorCode': code, 'errorMessage': msg,
                              'numericErrorCode': code, 'error': str(code), 'error_description': msg}, status=status)


class Store:
    """Tiny JSON-file persistence: users, player records, game records."""

    def __init__(self, path):
        self.path = Path(path)
        self.data = {'users': {}, 'player_records': {}, 'game_records': {}}
        if self.path.exists():
            self.data.update(json.loads(self.path.read_text()))
        self.tokens = {}  # access/refresh token -> {'user_id':..} or {'client':..}

    def save(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        tmp = self.path.with_suffix('.tmp')
        tmp.write_text(json.dumps(self.data, indent=1))
        tmp.replace(self.path)
        self.export_records()

    def export_records(self):
        """Mirror records as <data>/records/{game,players/<uid>}/<key>.json for game hosts: this client build
        compiled out its server-side CloudSave calls, so FangsHost answers them from these files."""
        root = self.path.parent / 'records'
        for key, value in self.data['game_records'].items():
            self._write(root / 'game' / f'{key}.json', value)
        for uid, recs in self.data['player_records'].items():
            for key, value in recs.items():
                self._write(root / 'players' / uid / f'{key}.json', value)

    @staticmethod
    def _write(path, value):
        text = json.dumps(value)
        if path.exists() and path.read_text() == text:
            return
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def user_for(self, username):
        users = self.data['users']
        if username not in users:
            users[username] = {'user_id': uuid.uuid5(uuid.NAMESPACE_DNS, 'fangs:' + username.lower()).hex,
                               'display_name': username, 'created_at': now_iso()}
            self.save()
        return users[username]

    def check_secret(self, user, secret):
        """Names are first-come: the first login binds the name to the launcher's per-install secret."""
        if 'secret' not in user:
            salt = os.urandom(8).hex()
            user['secret'] = f"{salt}${hashlib.sha256((salt + secret).encode()).hexdigest()}"
            self.save()
            return True
        salt, digest = user['secret'].split('$', 1)
        return hmac.compare_digest(digest, hashlib.sha256((salt + secret).encode()).hexdigest())

    def user_by_id(self, user_id):
        return next((u for u in self.data['users'].values() if u['user_id'] == user_id), None)


def b64url(obj):
    return base64.urlsafe_b64encode(json.dumps(obj, separators=(',', ':')).encode()).rstrip(b'=').decode()


def make_token(store, *, user=None, client_id=''):
    exp = int(time.time()) + 3600 * 24
    claims = {'namespace': NAMESPACE, 'client_id': client_id, 'exp': exp, 'iat': int(time.time()),
              'iss': 'fangs-backend', 'jti': uuid.uuid4().hex, 'scope': 'account commerce social publishing analytics',
              'roles': [], 'permissions': [], 'bans': [], 'jflgs': 0}
    if user:
        claims.update({'sub': user['user_id'], 'display_name': user['display_name']})
    access = f"{b64url({'alg': 'RS256', 'typ': 'JWT', 'kid': 'fangs'})}.{b64url(claims)}.{b64url('sig')}"
    refresh = uuid.uuid4().hex
    who = {'user_id': user['user_id']} if user else {'client': client_id}
    store.tokens[access] = who
    store.tokens[refresh] = who
    body = {'access_token': access, 'refresh_token': refresh, 'token_type': 'Bearer',
            'expires_in': 3600 * 24, 'refresh_expires_in': 3600 * 24 * 7, 'is_comply': True,
            'permissions': [], 'roles': [], 'bans': [], 'namespace': NAMESPACE, 'scope': claims['scope'],
            'jflgs': 0, 'user_id': '', 'display_name': '', 'platform_id': '', 'platform_user_id': ''}
    if user:
        body.update({'user_id': user['user_id'], 'display_name': user['display_name']})
    return body


def caller(request):
    auth = request.headers.get('Authorization', '')
    if auth.startswith('Bearer '):
        return request.app['store'].tokens.get(auth[7:], {})
    return {}


def is_local(request):
    """Game hosts run on this machine and talk to us over loopback."""
    return request.remote in ('127.0.0.1', '::1')


def is_server(request):
    return is_local(request) or 'client' in caller(request)


# ---------------------------------------------------------------- IAM

@route('POST', r'/iam(?:/v3)?/oauth/token')
async def oauth_token(request):
    store = request.app['store']
    form = await request.post()
    gt = form.get('grant_type', '')
    client_id = ''
    if request.headers.get('Authorization', '').startswith('Basic '):
        client_id = base64.b64decode(request.headers['Authorization'][6:]).decode().split(':')[0]
    if gt == 'password':
        secret = form.get('password', '')
        code = request.app['cfg'].join_code
        if code:  # launcher sends "<community join code>:<per-install secret>"
            given, _, secret = secret.partition(':')
            if not hmac.compare_digest(given, code):
                return err(401, 10131, 'wrong community join code')
        name = form.get('username', '')
        if not re.fullmatch(r'[A-Za-z0-9_]{3,16}', name):
            return err(400, 10132, 'invalid player name')
        user = store.user_for(name)
        if not store.check_secret(user, secret):
            return err(401, 10130, 'this name is taken (wrong secret)')
        return web.json_response(make_token(store, user=user, client_id=client_id))
    if gt == 'client_credentials':  # server login: only our own game hosts, which run on this machine
        if not is_local(request):
            return err(401, 10133, 'server login is only allowed locally')
        return web.json_response(make_token(store, client_id=client_id))
    if gt == 'refresh_token':
        who = store.tokens.get(form.get('refresh_token', ''))
        if not who:
            return err(401, 10196, 'invalid refresh token')
        user = store.user_by_id(who['user_id']) if 'user_id' in who else None
        return web.json_response(make_token(store, user=user, client_id=client_id))
    return err(400, 10140, f'unsupported grant_type {gt}')


@route('POST', r'/iam/v3/oauth/platforms/(?P<platform>[^/]+)/token')
async def platform_token(request):
    # Platform logins (Steam/Epic/Xbox) can't be verified without those services; use -TestUser logins.
    return err(401, 10134, 'platform login not supported; use the Fangs CE launcher')


@route('POST', r'/iam/v3/oauth/revoke')
async def oauth_revoke(request):
    return web.Response(status=200)


@route('GET', r'/iam/v3/public/users/me')
async def users_me(request):
    store = request.app['store']
    u = store.user_by_id(caller(request).get('user_id', ''))
    if not u:
        return err(401, 20001, 'unauthorized')
    return web.json_response({'userId': u['user_id'], 'displayName': u['display_name'], 'userName': u['display_name'],
                              'namespace': NAMESPACE, 'emailAddress': '', 'country': 'US', 'dateOfBirth': '2000-01-01',
                              'emailVerified': True, 'enabled': True, 'eligible': True, 'createdAt': u['created_at'],
                              'bans': [], 'permissions': [], 'roles': [], 'namespaceRoles': [], 'platformId': '',
                              'platformUserId': '', 'phoneVerified': False, 'deletionStatus': False, 'authType': 'EMAILPASSWD'})


# ---------------------------------------------------------------- CloudSave

def default_player_record(store, uid, key):
    """Records the old AWS lambdas created for new players (CreatePlayerURL); schema from FPlayerInfo."""
    user = store.user_by_id(uid) or {'display_name': uid[:8]}
    if key == 'PROFILE_INFO_KEY':
        return {'Username': user['display_name'], 'Version': 'main_v0_0_444', 'AccountType': 'Player',
                'Hero': 'Berserker', 'Region': 'Local', 'Sigil': '', 'Stickers': [],
                'GameplayTutorialComplete': 1, 'Cosmetics': {}}
    return None


def record_body(key, value, user_id=None, is_public=False):
    b = {'key': key, 'namespace': NAMESPACE, 'value': value, 'is_public': is_public,
         'created_at': now_iso(), 'updated_at': now_iso(), 'set_by': 'SERVER'}
    if user_id:
        b['user_id'] = user_id
    return b


@route('*', r'/cloudsave/v1(?:/admin)?/namespaces/[^/]+/users/(?P<uid>[^/]+)/records/(?P<key>[^/]+?)(?P<pub>/public)?')
async def player_record(request):
    store = request.app['store']
    uid, key = request.match_info['uid'], request.match_info['key']
    who = caller(request)
    if not who and not is_local(request):
        return err(401, 20001, 'unauthorized')
    if request.method != 'GET' and not is_server(request) and who.get('user_id') != uid:
        return err(403, 20013, 'you can only change your own records')
    recs = store.data['player_records'].setdefault(uid, {})
    if request.method == 'GET':
        if key not in recs and (default := default_player_record(store, uid, key)) is not None:
            recs[key] = default; store.save()
        if key not in recs:
            return err(404, 18022, f'record {key} not found for user {uid}')
        return web.json_response(record_body(key, recs[key], uid, bool(request.match_info['pub'])))
    if request.method == 'DELETE':
        recs.pop(key, None); store.save()
        return web.Response(status=204)
    value = await request.json()
    if request.method == 'POST' and isinstance(recs.get(key), dict) and isinstance(value, dict):
        recs[key] = {**recs[key], **value}   # POST = merge top-level fields
    else:
        recs[key] = value                   # PUT = replace
    store.save()
    return web.json_response(record_body(key, recs[key], uid))


@route('*', r'/cloudsave/v1(?:/admin)?/namespaces/[^/]+/records/(?P<key>[^/]+)')
async def game_record(request):
    store = request.app['store']
    key = request.match_info['key']
    recs = store.data['game_records']
    if request.method != 'GET' and not is_server(request):
        return err(403, 20013, 'game records are read-only')
    if request.method == 'GET':
        if key not in recs:
            return err(404, 18003, f'game record {key} not found')
        return web.json_response(record_body(key, recs[key]))
    if request.method == 'DELETE':
        recs.pop(key, None); store.save()
        return web.Response(status=204)
    value = await request.json()
    recs[key] = {**recs.get(key, {}), **value} if request.method == 'POST' and isinstance(value, dict) else value
    store.save()
    return web.json_response(record_body(key, recs[key]))


# ---------------------------------------------------------------- QoS (region list + UDP echo)

@route('GET', r'/qosm/public/qos')
async def qos_list(request):
    cfg = request.app['cfg']
    return web.json_response({'servers': [{'ip': cfg.public_ip, 'port': cfg.qos_port, 'region': 'local',
                                           'status': 'ACTIVE', 'last_update': now_iso(), 'alias': 'local'}]})


class _UdpEcho(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        self.transport.sendto(data, addr)


# ---------------------------------------------------------------- FANGS lambda API (was AWS API Gateway)
# Client calls {FANGSApiBaseURL}/dev/<route>. Original lambdas are lost; behaviour is inferred from the client.

def lambda_user(request):
    return caller(request).get('user_id')


@route('GET', r'/fangsapi/[^/]+/vivox-token')
async def fangs_vivox_token(request):
    return web.json_response({'token': 'fangs-local-vivox'})


@route('POST', r'/fangsapi/[^/]+/update-player-record-key')
async def fangs_update_record_key(request):
    store, uid = request.app['store'], lambda_user(request)
    if not uid:
        return err(401, 20001, 'unauthorized')
    body = await request.json()
    rec = store.data['player_records'].setdefault(uid, {}).setdefault(body['RecordId'], {})
    rec[body['Key']] = body.get('Value')
    store.save()
    return web.json_response({'success': True, 'RecordId': body['RecordId'], 'Key': body['Key']})


@route('PUT', r'/fangsapi/[^/]+/update-player-info')
async def fangs_update_player_info(request):
    store, uid = request.app['store'], lambda_user(request)
    if not uid:
        return err(401, 20001, 'unauthorized')
    body = await request.json()
    recs = store.data['player_records'].setdefault(uid, {})
    info = recs.get('PROFILE_INFO_KEY') or default_player_record(store, uid, 'PROFILE_INFO_KEY')
    if body.get('cosmeticType'):
        info.setdefault('Cosmetics', {})[body['cosmeticType']] = body.get('cosmeticId', '')
    recs['PROFILE_INFO_KEY'] = info
    store.save()
    return web.json_response(info)


@route('GET', r'/fangsapi/[^/]+/get-player-missions')
async def fangs_player_missions(request):
    return web.json_response({})


# ---------------------------------------------------------------- Platform (no store/economy: everything unlocked via config)

@route('GET', r'/platform/public/namespaces/[^/]+/users/[^/]+/entitlements')
async def entitlements(request):
    return web.json_response({'data': [], 'paging': {'previous': '', 'next': ''}})


@route('GET', r'/platform/public/namespaces/[^/]+/currencies')
async def currencies(request):
    return web.json_response([])


@route('PUT', r'/platform/public/namespaces/[^/]+/users/[^/]+/(?:dlc|iap)/[^/]+/sync')
async def platform_sync(request):
    return web.Response(status=204)


@route('GET', r'/platform/public/namespaces/[^/]+/users/(?P<uid>[^/]+)/wallets/(?P<cur>[^/]+)')
async def wallet(request):
    uid, cur = request.match_info['uid'], request.match_info['cur']
    return web.json_response({'id': f'{uid}-{cur}', 'namespace': NAMESPACE, 'userId': uid, 'currencyCode': cur,
                              'currencySymbol': cur, 'balance': 0, 'status': 'ACTIVE',
                              'createdAt': now_iso(), 'updatedAt': now_iso()})


@route('GET', r'/platform/public/namespaces/[^/]+/items/byCriteria')
async def items_by_criteria(request):
    return web.json_response({'data': [], 'paging': {'previous': '', 'next': ''}})


@route('GET', r'/social/v1/public/namespaces/[^/]+/users/[^/]+/statitems')
async def stat_items(request):
    return web.json_response({'data': [], 'paging': {'previous': '', 'next': ''}})


@route('GET', r'/basic/v1/public/misc/time')
async def server_time(request):
    return web.json_response({'currentTime': time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime())})


@route('GET', r'/lobby/v1/messages')
async def lobby_messages(request):
    return web.json_response([])


# ---------------------------------------------------------------- Session browser (custom lobbies)
# Sessions live in memory; a session becomes joinable once its game host is up (see lobby createDSRequest).

def session_view(sess):
    host = sess.get('_host')
    if host is not None:  # live player count from the host's FangsHost heartbeat
        sess['game_session_setting']['current_player'] = host.status.get('players', 0)
    return {k: v for k, v in sess.items() if not k.startswith('_')}


@route('POST', r'/sessionbrowser/namespaces/[^/]+/gamesession')
async def session_create(request):
    app, who = request.app, caller(request)
    if 'user_id' not in who:
        return err(401, 20001, 'unauthorized')
    for old in [s for s in app['sessions'].values() if s['user_id'] == who['user_id']]:
        app['sessions'].pop(old['session_id'], None)          # one custom lobby per player
        if old['_host']:
            asyncio.create_task(app['hosts'].stop(old['_host'], 'owner created a new lobby'))
    body = await request.json()
    user = app['store'].user_by_id(who.get('user_id', '')) or {}
    sid = uuid.uuid4().hex
    sess = {'session_id': sid, 'namespace': NAMESPACE, 'user_id': who.get('user_id', ''),
            'username': body.get('username') or user.get('display_name', ''),
            'session_type': body.get('session_type', 'dedicated'), 'game_version': body.get('game_version', ''),
            'joinable': False, 'game_session_setting': body.get('game_session_setting', {}),
            'server': {}, 'all_players': [], 'players': [], 'spectators': [], 'match': {},
            'created_at': now_iso(), '_host': None}
    settings = sess['game_session_setting'].setdefault('settings', {})
    if not settings.get('lobby_owner'):  # lobby browser hides sessions without an owner name
        settings['lobby_owner'] = sess['username'] or user.get('display_name', 'player')
    app['sessions'][sid] = sess
    return web.json_response(session_view(sess))


@route('GET', r'/sessionbrowser/namespaces/[^/]+/gamesession')
async def session_list(request):
    q = request.query
    mode = q.get('game_mode', '').lower()
    out = [session_view(s) for s in request.app['sessions'].values()
           if s['joinable'] and s['session_type'] == q.get('session_type', s['session_type'])
           and (not mode or s['game_session_setting'].get('mode', '').lower() == mode)]
    return web.json_response({'sessions': out, 'pagination': {'first': '', 'last': '', 'next': '', 'previous': ''}})


@route('GET', r'/sessionbrowser/namespaces/[^/]+/gamesession/bulk')
async def session_bulk(request):
    ids = set(request.query.get('user_ids', '').split(','))
    return web.json_response({'data': [session_view(s) for s in request.app['sessions'].values()
                                       if ids & set(s['players'] + [s['user_id']])]})


@route('*', r'/sessionbrowser/namespaces/[^/]+/gamesession/(?P<sid>[^/]+)(?P<sub>/join|/settings|/player(?:/[^/]+)?)?')
async def session_one(request):
    app = request.app
    sess = app['sessions'].get(request.match_info['sid'])
    if not sess:
        return err(404, 9014, 'session not found')
    sub, m = request.match_info['sub'] or '', request.method
    if sub == '/join':
        return web.json_response(session_view(sess)) if sess['joinable'] else err(409, 9015, 'session not ready')
    if sub == '/player' and m == 'POST':
        body = await request.json()
        lst = sess['spectators'] if body.get('as_spectator') else sess['players']
        if body.get('user_id') and body['user_id'] not in lst:
            lst.append(body['user_id']); sess['all_players'] = sess['players'] + sess['spectators']
        return web.json_response({'status': True})
    if sub.startswith('/player/') and m == 'DELETE':
        uid = sub.split('/')[-1]
        for k in ('players', 'spectators', 'all_players'):
            if uid in sess[k]:
                sess[k].remove(uid)
        return web.json_response({'status': True})
    if sub == '/settings' and m == 'PUT':
        sess['game_session_setting']['settings'] = await request.json()
        return web.json_response(session_view(sess))
    if m == 'PUT':
        body = await request.json()
        gs = sess['game_session_setting']
        gs['current_player'] = body.get('game_current_player', gs.get('current_player', 0))
        gs['max_player'] = body.get('game_max_player', gs.get('max_player', 0))
        return web.json_response(session_view(sess))
    if m == 'DELETE':
        app['sessions'].pop(sess['session_id'], None)
        if sess['_host']:
            asyncio.create_task(app['hosts'].stop(sess['_host'], 'session deleted'))
        return web.json_response(session_view(sess))
    return web.json_response(session_view(sess))


# ---------------------------------------------------------------- Player package downloads
# Served behind the community join code: http://<server>/download/<join code>/<file>

@route('GET', r'/download/(?P<code>[^/]+)/(?P<name>[A-Za-z0-9._-]+)')
async def download(request):
    cfg = request.app['cfg']
    if not cfg.downloads or not cfg.join_code or not hmac.compare_digest(request.match_info['code'], cfg.join_code):
        return err(404, 404, 'not found')
    path = Path(cfg.downloads) / request.match_info['name']
    if not path.is_file():
        return err(404, 404, 'not found')
    return web.FileResponse(path, headers={'Content-Disposition': f'attachment; filename="{path.name}"'})


# ---------------------------------------------------------------- Telemetry (accept and drop)

@route('POST', r'/game-telemetry/.*')
async def telemetry(request):
    await request.read()
    return web.Response(status=204)


# ---------------------------------------------------------------- Lobby websocket
# AccelByte lobby protocol: text frames "type: X\nid: Y\nkey: value...". We answer every *Request with a
# success *Response and implement createDSRequest (custom-lobby game server allocation) for real.

def lobby_frame(**fields):
    return '\n'.join(f'{k}: {v}' for k, v in fields.items())


async def handle_create_ds(app, ws, fields):
    sid = fields.get('matchId', '')
    sess = app['sessions'].get(sid)
    cfg = app['cfg']
    try:
        if not sess:
            raise RuntimeError(f'unknown session {sid}')
        host = await app['hosts'].allocate(sid)
        sess['_host'] = host
        sess['server'] = {'ip': cfg.public_ip, 'port': host.port, 'region': 'local', 'status': 'READY',
                          'pod_name': host.id, 'deployment': fields.get('deployment', ''),
                          'game_version': fields.get('clientVersion', '')}
        sess['joinable'] = True
        # The client only proceeds on BUSY (= server claimed for this session), see AccelByteSubsystem DS notif handler.
        await ws.send_str(lobby_frame(type='dsNotif', status='BUSY', matchId=sid, podName=host.id,
                                      ip=cfg.public_ip, port=host.port, imageVersion='', serverVersion='',
                                      message='', isOK='true', region='local', customAttribute=''))
    except Exception as e:  # noqa: BLE001 - report any allocation failure to the client
        app['log']({'ws': 'lobby', 'event': 'createDS failed', 'error': str(e)})
        await ws.send_str(lobby_frame(type='dsNotif', status='FAILED', matchId=sid, podName='', ip='', port=0,
                                      imageVersion='', serverVersion='', message=str(e), isOK='false',
                                      region='local', customAttribute=''))


async def lobby_ws(request):
    ws = web.WebSocketResponse(protocols=('wss',), heartbeat=30)
    await ws.prepare(request)
    app, who, log = request.app, caller(request), request.app['log']
    log({'ws': 'lobby', 'event': 'connect', 'who': who})
    await ws.send_str(lobby_frame(type='connectNotif', lobbySessionID=uuid.uuid4().hex))
    async for msg in ws:
        if msg.type != WSMsgType.TEXT:
            continue
        log({'ws': 'lobby', 'recv': msg.data})
        fields = dict(line.split(': ', 1) for line in msg.data.split('\n') if ': ' in line)
        t, mid = fields.get('type', ''), fields.get('id', '')
        if t.endswith('Request'):
            await ws.send_str(lobby_frame(type=t[:-len('Request')] + 'Response', id=mid, code=0))
        if t == 'createDSRequest':
            asyncio.create_task(handle_create_ds(app, ws, fields))
    log({'ws': 'lobby', 'event': 'close', 'who': who})
    return ws


async def matchmaker_ws(request):
    """Matchmaking is disabled (custom lobbies only); keep the client's connection happy and idle."""
    ws = web.WebSocketResponse(heartbeat=30)
    await ws.prepare(request)
    await ws.send_str(json.dumps({'msg_type': 'ClientStatusResponse', 'msg': {'status': 'Idle'}}))
    async for msg in ws:
        if msg.type == WSMsgType.TEXT:
            request.app['log']({'ws': 'matchmaker', 'recv': msg.data})
    return ws


# ---------------------------------------------------------------- plumbing

@web.middleware
async def dispatch(request, handler):
    body = await request.read()
    entry = {'t': round(time.time(), 3), 'method': request.method, 'path': request.path, 'query': request.query_string}
    if body:
        entry['body'] = re.sub(r'(password=)[^&]*', r'\1<redacted>', body[:2000].decode('utf-8', 'replace'))
    if 'Authorization' in request.headers:
        entry['auth'] = request.headers['Authorization'][:24]
    if request.path.rstrip('/') == '/lobby':
        request.app['log'](entry)
        return await lobby_ws(request)
    if request.path.rstrip('/') == '/matchmaker':
        request.app['log'](entry)
        return await matchmaker_ws(request)
    for method, rx, fn in ROUTES:
        m = rx.match(request.path)
        if m and method in ('*', request.method):
            resp = await fn(_Req(request, m.groupdict()))
            break
    else:
        resp = err(404, 404, 'not implemented by fangs backend')
        entry['unhandled'] = True
    entry['status'] = resp.status
    if isinstance(resp, web.Response) and resp.body is not None and resp.status >= 400:
        entry['resp'] = resp.body.decode()[:300] if isinstance(resp.body, bytes) else str(resp.body)[:300]
    request.app['log'](entry)
    return resp


class _Req:
    """Wraps aiohttp request so handlers can use request.match_info with our regex groups."""

    def __init__(self, req, groups):
        self._req, self.match_info = req, groups

    def __getattr__(self, name):
        return getattr(self._req, name)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--host', default='0.0.0.0')
    ap.add_argument('--port', type=int, default=8080)
    ap.add_argument('--public-ip', default='127.0.0.1', help='address clients use to reach this machine')
    ap.add_argument('--downloads', default='', help='directory with player packages served at /download/<join code>/')
    ap.add_argument('--join-code', default=os.environ.get('FANGS_JOIN_CODE', ''),
                    help='community code players need to log in (baked into the player package)')
    ap.add_argument('--qos-port', type=int, default=11032)
    ap.add_argument('--seed', default=str(Path(__file__).parent / 'seed' / 'game_records.json'))
    ap.add_argument('--game-dir', default=str(Path(__file__).parent.parent / 'clients' / 'playtest-main_v0_0_444'))
    ap.add_argument('--instances', default=str(Path(__file__).parent.parent / 'work' / 'hosts'))
    ap.add_argument('--host-ports', default='7777-7786', help='UDP port range for game hosts')
    ap.add_argument('--run-host', default=str(Path(__file__).parent.parent / 'server' / 'run-host.sh'))
    ap.add_argument('--data', default=str(Path(__file__).parent / 'data' / 'store.json'))
    ap.add_argument('--log', default=str(Path(__file__).parent.parent / 'work' / 'logs' / 'backend.jsonl'))
    a = ap.parse_args()
    Path(a.log).parent.mkdir(parents=True, exist_ok=True)
    logf = open(a.log, 'a', buffering=1)

    def log(entry):
        line = json.dumps(entry)
        logf.write(line + '\n')
        print(line[:300], flush=True)

    app = web.Application(middlewares=[dispatch], client_max_size=16 * 1024 * 1024)
    app['store'], app['log'], app['cfg'] = Store(a.data), log, a
    app['sessions'] = {}
    lo, hi = map(int, a.host_ports.split('-'))
    app['hosts'] = HostManager(game_dir=a.game_dir, inst_root=a.instances, ports=range(lo, hi + 1),
                               run_script=a.run_host, backend_addr=f'127.0.0.1:{a.port}', log=log,
                               data_dir=str(Path(a.data).resolve().parent))

    def host_stopped(host):  # drop the custom lobby whose game server went away
        app['sessions'].pop(host.session_id, None)
    app['hosts'].on_stopped.append(host_stopped)
    if Path(a.seed).exists():  # seed (re)defines the global game records on every start
        app['store'].data['game_records'].update(json.loads(Path(a.seed).read_text()))
    app['store'].export_records()

    async def start_udp(app):
        loop = asyncio.get_running_loop()
        app['udp'], _ = await loop.create_datagram_endpoint(_UdpEcho, local_addr=(a.host, a.qos_port))

    async def stop_udp(app):
        app['udp'].close()
        await app['hosts'].shutdown()
    app.on_startup.append(start_udp)
    app.on_cleanup.append(stop_udp)
    app.router.add_route('*', '/{tail:.*}', lambda r: web.Response(status=500))  # never reached; middleware answers
    web.run_app(app, host=a.host, port=a.port, print=lambda *_: print(f'fangs backend on {a.host}:{a.port}', flush=True))


if __name__ == '__main__':
    main()
