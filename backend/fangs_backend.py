#!/usr/bin/env python3
"""FANGS replacement backend — speaks the subset of the AccelByte API the game uses.

Discovery-driven: every request is logged (stdout + JSONL); anything not implemented
returns an AccelByte-style 404 so we can see what the game needs next.

Run:  backend/.venv/bin/python backend/fangs_backend.py --port 8080
"""
import argparse, asyncio, base64, hashlib, hmac, json, math, os, re, time, uuid
from pathlib import Path

from aiohttp import web, WSMsgType

from hosts import HostManager
from matchmaker import Matchmaker
from social import Social

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


def tagged_name(user):
    """AccelByte-style display name "<name>#<4 digits>". The client splits names on '#' and uses the first
    part as the player name; an untagged name reads as empty (top bar "#name", lobby creator not owner)."""
    tag = int(hashlib.sha256(user['user_id'].encode()).hexdigest(), 16) % 10000
    return f"{user['display_name']}#{tag:04d}"


def make_token(store, *, user=None, client_id=''):
    exp = int(time.time()) + 3600 * 24
    claims = {'namespace': NAMESPACE, 'client_id': client_id, 'exp': exp, 'iat': int(time.time()),
              'iss': 'fangs-backend', 'jti': uuid.uuid4().hex, 'scope': 'account commerce social publishing analytics',
              'roles': [], 'permissions': [], 'bans': [], 'jflgs': 0}
    if user:
        claims.update({'sub': user['user_id'], 'display_name': tagged_name(user)})
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
        body.update({'user_id': user['user_id'], 'display_name': tagged_name(user)})
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
    return web.json_response({'userId': u['user_id'], 'displayName': tagged_name(u), 'userName': u['display_name'],
                              'namespace': NAMESPACE, 'emailAddress': '', 'country': 'US', 'dateOfBirth': '2000-01-01',
                              'emailVerified': True, 'enabled': True, 'eligible': True, 'createdAt': u['created_at'],
                              'bans': [], 'permissions': [], 'roles': [], 'namespaceRoles': [], 'platformId': '',
                              'platformUserId': '', 'phoneVerified': False, 'deletionStatus': False, 'authType': 'EMAILPASSWD'})


# Names for user ids (friends and party lists, leaderboard rows). The SDK sends it with and without the /iam prefix.
@route('POST', r'(?:/iam)?/v3/public/namespaces/[^/]+/users/bulk/basic')
async def users_bulk_basic(request):
    store = request.app['store']
    if not caller(request):
        return err(401, 20001, 'unauthorized')
    body = await request.json()
    ids = body.get('userIds', []) if isinstance(body, dict) else []
    users = [u for u in (store.user_by_id(str(i)) for i in ids[:100]) if u]
    return web.json_response({'data': [{'userId': u['user_id'], 'displayName': tagged_name(u), 'namespace': NAMESPACE,
                                        'avatarUrl': '', 'publisherAvatarUrl': '', 'platformUserIds': {}}
                                       for u in users]})


# ---------------------------------------------------------------- CloudSave

# GameplayTutorialComplete (WB_MainMenu): 0 forced tutorial, 1 starter-hero pick, 2 menu hints, 3 done.
# Everything is unlocked, so players start past all of it.
TUTORIAL_DONE = 3
PROFILE_IDENTITY = {'Username', 'AccountType', 'Version', 'UserId', 'GameplayTutorialComplete'}   # not player-settable


def default_player_record(store, uid, key):
    """Records the old AWS lambdas created for new players (CreatePlayerURL); schema from FPlayerInfo."""
    user = store.user_by_id(uid) or {'user_id': uid, 'display_name': uid[:8]}
    if key == 'PROFILE_INFO_KEY':
        return {'Username': tagged_name(user), 'Version': 'main_v0_0_444', 'AccountType': 'Player',
                'Hero': 'Berserker', 'Region': 'Local', 'Sigil': '', 'Stickers': [],
                'GameplayTutorialComplete': TUTORIAL_DONE, 'Cosmetics': dict(DEFAULT_COSMETICS)}
    return None


# Match statistics, written only by the backend from finished matches (see ingest_match): players can't set them.
# Defaults are served, not stored. MatchesPlayed is left out until the first match ("0% of 0" on the profile).
DEFAULT_RATING = {'mu': 25.0, 'sigma': 8.33333}   # the game's own defaults (BP_AC_MatchReport)
STATS_DEFAULTS = {'PROFILE_HISTORY_KEY': {'Matches': []},
                  'PROFILE_MASTERY_KEY': {'Level': 1, 'XPToNext': 0},
                  'PROFILE_RATINGS_KEY': {'casual_rating': DEFAULT_RATING, 'ranked_rating': DEFAULT_RATING}}


def history_for_viewer(history, owner, viewer):
    """A friend's match list renders the rows of whoever is looking (WB_MatchOverviewBtn finds the viewer's own
    UserId in each match): hand out a copy with the owner's rows under the viewer's id (and the viewer's own
    rows, from games they played together, under none)."""
    history = json.loads(json.dumps(history))
    for match in history.get('Matches') or []:
        for rnd in match.get('MatchResults') or []:
            for row in rnd.get('RoundResults') or []:
                if row.get('UserId') == owner:
                    row['UserId'] = viewer
                elif row.get('UserId') == viewer:
                    row['UserId'] = ''
    return history


def stats_record(store, uid, key):
    value = store.data['player_records'].get(uid, {}).get(key)
    return value if value is not None else json.loads(json.dumps(STATS_DEFAULTS[key]))


# What WB_AccountMenu equips at login when Cosmetics has no Banner/Title.
DEFAULT_COSMETICS = {'Banner': 'banner_redplayfangs', 'Title': 'title_aspectwarrior'}


def fix_profile(info):
    """Repairs profiles written by earlier versions of update-player-info; True if anything changed.
    Stickers must stay a list (the client's JSON-to-struct conversion stops at a non-array TArray field and
    drops the fields after it), and Cosmetics only holds plain keys (hero name -> skin, Banner, Title, Mount)."""
    changed = False
    st = info.get('Stickers')
    if not isinstance(st, list) or not all(isinstance(x, str) for x in st):
        info['Stickers'] = sticker_slots(st); changed = True
    cos = info.get('Cosmetics')
    if not isinstance(cos, dict):
        info['Cosmetics'] = cos = {}; changed = True
    for k in [k for k in cos if '.' in k or k == 'Hero' or not isinstance(cos[k], str)]:
        del cos[k]; changed = True
    return changed


def sticker_slots(value):
    """The sticker wheel's 5 slots ("" = empty); the client sends them as a JSON string of a list."""
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            value = []
    if not isinstance(value, list):
        return []
    return [x if isinstance(x, str) and re.fullmatch(r'[A-Za-z0-9_]{0,32}', x) else '' for x in value[:5]]


def record_body(key, value, user_id=None, is_public=False):
    b = {'key': key, 'namespace': NAMESPACE, 'value': value, 'is_public': is_public,
         'created_at': now_iso(), 'updated_at': now_iso(), 'set_by': 'SERVER'}
    if user_id:
        b['user_id'] = user_id
    return b


# Leaderboard rows: one entry per requested user, in request order (the client matches rows by index).
@route('POST', r'/cloudsave/v1/namespaces/[^/]+/users/bulk/records/(?P<key>[^/]+)/public')
async def bulk_public_records(request):
    store, key = request.app['store'], request.match_info['key']
    if not caller(request):
        return err(401, 20001, 'unauthorized')
    body = await request.json()
    ids = [str(i) for i in (body.get('userIds', []) if isinstance(body, dict) else [])][:100]
    if key in STATS_DEFAULTS:
        values = [stats_record(store, uid, key) for uid in ids]
    else:
        values = [store.data['player_records'].get(uid, {}).get(key, {}) for uid in ids]
    return web.json_response({'data': [record_body(key, v, uid, True) for uid, v in zip(ids, values)]})


@route('*', r'/cloudsave/v1(?:/admin)?/namespaces/[^/]+/users/(?P<uid>[^/]+)/records/(?P<key>[^/]+?)(?P<pub>/public)?')
async def player_record(request):
    store = request.app['store']
    uid, key = request.match_info['uid'], request.match_info['key']
    who = caller(request)
    if not who and not is_local(request):
        return err(401, 20001, 'unauthorized')
    if request.method != 'GET' and not is_server(request) and who.get('user_id') != uid:
        return err(403, 20013, 'you can only change your own records')
    if key in STATS_DEFAULTS:
        if request.method != 'GET':
            return err(403, 20013, f'{key} is kept by the server')
        if not store.user_by_id(uid):
            return err(404, 18022, f'record {key} not found for user {uid}')
        value = stats_record(store, uid, key)
        viewer = who.get('user_id')
        if key == 'PROFILE_HISTORY_KEY' and viewer and viewer != uid:
            value = history_for_viewer(value, uid, viewer)
        return web.json_response(record_body(key, value, uid, bool(request.match_info['pub'])))
    recs = store.data['player_records'].setdefault(uid, {})
    if request.method == 'GET':
        if key not in recs and (default := default_player_record(store, uid, key)) is not None:
            recs[key] = default; store.save()
        if key == 'PROFILE_INFO_KEY' and isinstance(recs.get(key), dict):   # profiles from older versions
            info, user = recs[key], store.user_by_id(uid)
            if info.get('GameplayTutorialComplete', 0) < TUTORIAL_DONE:
                info['GameplayTutorialComplete'] = TUTORIAL_DONE; store.save()
            if user and '#' not in str(info.get('Username', '#')):
                info['Username'] = tagged_name(user); store.save()
            if fix_profile(info):
                store.save()
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
    # cosmeticType is a path into the profile: "Hero" (the lobby re-reads it as the pick), "Cosmetics.Title", ...
    path = str(body.get('cosmeticType', '')).split('.')
    if not all(re.fullmatch(r'[A-Za-z0-9_]{1,32}', k) for k in path) or len(path) > 3 or path[0] in PROFILE_IDENTITY:
        return err(400, 20002, 'invalid cosmeticType')
    node = info
    for k in path[:-1]:
        if not isinstance(node.get(k), dict):
            node[k] = {}
        node = node[k]
    if path == ['Stickers']:
        node['Stickers'] = sticker_slots(body.get('cosmeticId'))
    else:
        node[path[-1]] = str(body.get('cosmeticId', ''))
    fix_profile(info)
    recs['PROFILE_INFO_KEY'] = info
    store.save()
    return web.json_response(info)


@route('PUT', r'/fangsapi/[^/]+/update-player-settings')
async def fangs_update_player_settings(request):
    store, uid = request.app['store'], lambda_user(request)
    if not uid:
        return err(401, 20001, 'unauthorized')
    body = await request.json()   # FPlayerSettings (volumes, ...); the client reads it back from PROFILE_SETTINGS_KEY
    if not isinstance(body, dict):
        return err(400, 20002, 'settings must be an object')
    store.data['player_records'].setdefault(uid, {})['PROFILE_SETTINGS_KEY'] = body
    store.save()
    return web.json_response(body)


@route('*', r'/fangsapi/[^/]+/(?:update-loadouts|update_augment_loadouts)')
async def fangs_update_loadouts(request):
    # Augment loadouts from the lobby (WB_LoadOuts -> UAccelByte::UpdateLoadouts): the client sends its whole
    # {hero: {CurrentLoadoutIndex, Loadout1: {Name, Augments}}} object and reads it back from PROFILE_LOADOUT_KEY.
    # The request shape isn't known for sure: a bare object, {"Loadouts": ...} or {RecordId, Key, Value}.
    store, uid = request.app['store'], lambda_user(request)
    if not uid:
        return err(401, 20001, 'unauthorized')
    body = await request.json()
    value = next((body[k] for k in ('Value', 'Loadouts', 'loadouts') if isinstance(body, dict) and k in body), body)
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except ValueError:
            value = None
    if not isinstance(value, dict):
        return err(400, 20002, 'loadouts must be an object')
    store.data['player_records'].setdefault(uid, {})['PROFILE_LOADOUT_KEY'] = value
    store.save()
    return web.json_response({'success': True})


@route('*', r'/fangsapi/[^/]+/(?:log-gameplay-tutorial-complete|sync-user-friend-stat|create-shard-selection|redeem-shards)')
async def fangs_accept(request):   # Aug 2022 client: progression/stat bookkeeping we don't keep
    return web.json_response({'success': True})


@route('GET', r'/fangsapi/[^/]+/get-epoc')
async def fangs_epoch(request):   # Aug 2022 client: server time for missions/shop (UAccelByte OnEpocParsed)
    return web.json_response({'timestamp': int(time.time())})


@route('GET', r'/fangsapi/[^/]+/get-shop-data')
async def fangs_shop_data(request):
    return web.json_response({})   # {shopId: {StartTime, EndTime, Items}}; no shops (nothing to buy)


@route('GET', r'/fangsapi/[^/]+/get-player-missions')
async def fangs_player_missions(request):
    return web.json_response({})


# ---------------------------------------------------------------- Platform (no economy: everything unlocked)

# The client's inventory (UMOBAInventorySubsystem) only counts items that are in the catalog *and* entitled:
# catalog item title = internal id (DT_Heroes row, e.g. "Berserker"), first categoryPath segment = item class
# ("Hero", "Skin", ...), and an entitlement matches a catalog item by name == title. The Play panel stays
# hidden until the player owns a Hero, so the catalog holds every hero in AvailableHeroes and everyone owns them;
# the cosmetics (skins, stickers, sigils, banners, titles, mounts) come from the seed's CECatalog, per namespace.
def catalog_items(store, namespace=None):
    records = store.data['game_records']
    items = []
    for version in (records.get('FANGSConfig') or {}).values():
        if isinstance(version, dict):
            items += [('Hero', h) for h in version.get('AvailableHeroes', []) if ('Hero', h) not in items]
    for ns, classes in (records.get('CECatalog') or {}).items():
        if namespace in (None, ns):
            items += [(cls, i) for cls, ids in classes.items() for i in ids]
    stamp = '2023-02-15T00:00:00.000Z'
    return [{'title': i, 'name': i, 'itemId': hashlib.md5(f'{cls.lower()}:{i}'.encode()).hexdigest(),
             'sku': f'{cls.lower()}-{i}', 'namespace': NAMESPACE, 'categoryPath': f'/{cls}', 'status': 'ACTIVE',
             'entitlementType': 'DURABLE', 'itemType': 'INGAMEITEM', 'useCount': 0, 'listable': False,
             'purchasable': False, 'regionData': [], 'tags': [], 'features': [], 'images': [], 'itemIds': [],
             'boundItemIds': [], 'createdAt': stamp, 'updatedAt': stamp} for cls, i in dict.fromkeys(items)]


def paged(data):
    return web.json_response({'data': data, 'paging': {'previous': '', 'next': ''}})


@route('GET', r'/platform/public/namespaces/[^/]+/users/(?P<uid>[^/]+)/entitlements')
async def entitlements(request):
    uid, stamp = request.match_info['uid'], '2023-02-15T00:00:00.000Z'
    return paged([{'id': hashlib.md5(f"{uid}:{i['itemId']}".encode()).hexdigest(), 'namespace': NAMESPACE,
                   'clazz': 'ENTITLEMENT', 'type': 'DURABLE', 'status': 'ACTIVE', 'sku': i['sku'], 'userId': uid,
                   'itemId': i['itemId'], 'itemNamespace': NAMESPACE, 'name': i['title'], 'features': [],
                   'useCount': 0, 'source': 'GIFT', 'stackable': False,
                   'grantedAt': stamp, 'createdAt': stamp, 'updatedAt': stamp}
                  for i in catalog_items(request.app['store'])])


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


@route('GET', r'/platform/public/namespaces/(?P<ns>[^/]+)/items/byCriteria')
async def items_by_criteria(request):
    return paged(catalog_items(request.app['store'], request.match_info['ns']))


@route('GET', r'/social/v1/public/namespaces/[^/]+/users/[^/]+/statitems')
async def stat_items(request):
    return web.json_response({'data': [], 'paging': {'previous': '', 'next': ''}})


# The game server adds kills, damage, ... per player after a match; match statistics come from ingest_match instead.
@route('PUT', r'/social/v2/admin/namespaces/[^/]+/statitems/value/bulk')
async def stat_items_bulk(request):
    if not is_server(request):
        return err(403, 20013, 'server only')
    body = await request.json()
    return web.json_response([{'statCode': i.get('statCode', ''), 'userId': i.get('userId', ''), 'success': True,
                               'details': {}} for i in (body if isinstance(body, list) else []) if isinstance(i, dict)])


# ---------------------------------------------------------------- Leaderboard

def rank_points(rating):
    """The profile screen's rank points (WB_ReputationMenu CalcOnlineRank): 90 * (mu - 2 sigma)."""
    return int(90 * (rating.get('mu', 25.0) - 2 * rating.get('sigma', 8.33333)))


def leaderboard(store):
    """[(user id, points)], best first: everyone who has finished a match."""
    rows = []
    for uid, recs in store.data['player_records'].items():
        if (recs.get('PROFILE_MASTERY_KEY') or {}).get('MatchesPlayed'):
            rows.append((uid, rank_points((recs.get('PROFILE_RATINGS_KEY') or {}).get('ranked_rating') or {})))
    return sorted(rows, key=lambda r: -r[1])


# The leaderboard code is the season id, which our (empty) season record leaves blank; every code is one board.
@route('GET', r'/leaderboard/v\d/public/namespaces/[^/]+/leaderboards/[^/]*/users/(?P<uid>[^/]+)')
async def leaderboard_user(request):
    uid, rows = request.match_info['uid'], leaderboard(request.app['store'])
    rank = next((i + 1 for i, (u, _) in enumerate(rows) if u == uid), 0)
    pts = rows[rank - 1][1] if rank else rank_points(stats_record(request.app['store'], uid, 'PROFILE_RATINGS_KEY')
                                                     .get('ranked_rating') or {})
    entry = {'point': pts, 'rank': rank}
    return web.json_response({'userId': uid, 'allTime': entry, 'current': entry, 'daily': entry, 'monthly': entry,
                              'weekly': entry})


@route('GET', r'/leaderboard/v\d/public/namespaces/[^/]+/leaderboards/[^/]*/(?:alltime|season|month|week|today)')
async def leaderboard_page(request):
    rows = leaderboard(request.app['store'])
    try:
        offset, limit = max(0, int(request.query.get('offset', 0))), max(0, min(100, int(request.query.get('limit', 20))))
    except ValueError:
        offset, limit = 0, 20
    return web.json_response({'data': [{'userId': u, 'point': p} for u, p in rows[offset:offset + limit]],
                              'paging': {'first': '', 'last': '', 'previous': '', 'next': ''}})


@route('GET', r'/basic/v1/public/misc/time')
async def server_time(request):
    return web.json_response({'currentTime': time.strftime('%Y-%m-%dT%H:%M:%S.000Z', time.gmtime())})


@route('GET', r'/lobby/v1/messages')
async def lobby_messages(request):
    return web.json_response([])


# ---------------------------------------------------------------- Match results (history, mastery, ratings)

# From the game's BP_AC_MatchReport: XP per match, the match-history length, and its rating model's parameters.
XP_MATCH_CAP, XP_WIN, XP_LOSE = 5400.0, (0.11, 6.6), (0.09, 5.4)    # seconds counted; (per second, base)
HISTORY_LENGTH = 20
RATED_MODES = {2, 3, 4}                    # ENUM_MapGameMode Casual, Ranked, Custom (not training/tutorial)
PL_BETA, PL_EPSILON = 5.0, 0.001           # OpenSkill Plackett-Luce, as the game sent it to its ratings service
TEAMS = {1: 'TeamA', 2: 'TeamB'}


def level_up(level, xp, table, strict):
    """Carries XP over into levels: table[n-1] is the XP needed to leave level n. Account levels need more than
    that (Process XPRewards), hero mastery at least that (GetHeroMasteryIfClaimed); the last level keeps the XP."""
    while 1 <= level <= len(table) and (xp > table[level - 1] if strict else xp >= table[level - 1]):
        xp -= table[level - 1]
        level += 1
    return level, xp


def plackett_luce(teams):
    """OpenSkill Plackett-Luce update. teams: [(rank, [rating dict, ...])], lower rank = better; new ratings."""
    c = math.sqrt(sum(sum(r['sigma'] ** 2 for r in rs) + PL_BETA ** 2 for _, rs in teams))
    mus = [sum(r['mu'] for r in rs) for _, rs in teams]
    s2 = [sum(r['sigma'] ** 2 for r in rs) for _, rs in teams]
    ranks = [rank for rank, _ in teams]
    tied = [ranks.count(rk) for rk in ranks]
    sum_q = [sum(math.exp(mus[i] / c) for i in range(len(teams)) if ranks[i] >= ranks[q]) for q in range(len(teams))]
    out = []
    for i, (_, rs) in enumerate(teams):
        omega = delta = 0.0
        for q in range(len(teams)):
            if ranks[q] > ranks[i]:
                continue
            quotient = math.exp(mus[i] / c) / sum_q[q]
            omega += ((1 - quotient) if q == i else -quotient) / tied[q]
            delta += quotient * (1 - quotient) / tied[q]
        omega *= s2[i] / c
        delta *= (s2[i] / c ** 2) * (math.sqrt(s2[i]) / c)
        out.append([{'mu': r['mu'] + r['sigma'] ** 2 / s2[i] * omega,
                     'sigma': r['sigma'] * math.sqrt(max(1 - r['sigma'] ** 2 / s2[i] * delta, PL_EPSILON))}
                    for r in rs])
    return out


def ingest_match(store, result, log):
    """A match FangsHost saved at its end (fangshost_result-*.json): the game's own match-history entry plus the
    winner. Every player with an account gets it in PROFILE_HISTORY_KEY, XP/levels/wins in PROFILE_MASTERY_KEY,
    and (when both teams had players) a new rating in PROFILE_RATINGS_KEY, the same for casual and ranked."""
    entry, winner = result.get('results') or {}, TEAMS.get(result.get('winning_team'))
    rounds = entry.get('MatchResults') or []
    match_id = hashlib.sha1(json.dumps([entry.get('TimePlayed'), entry.get('MapLevel'),
                                        [r.get('TotalRoundTime') for r in rounds]]).encode()).hexdigest()[:16]
    seen = store.data.setdefault('matches_seen', [])
    if match_id in seen or not rounds or not winner:
        return log({'match': match_id, 'skipped': 'duplicate' if match_id in seen else 'no rounds or winner'})
    players = {}   # user id -> {'user', 'team', 'hero'} from the last round each one appears in
    for rnd in rounds:
        for row in rnd.get('RoundResults') or []:
            user = store.user_by_id(str(row.get('UserId', '')))
            if user and row.get('Team') in TEAMS.values():
                players[user['user_id']] = {'user': user, 'team': row['Team'], 'hero': str(row.get('Type', ''))}
                row['Name'] = user['display_name']
    seen.append(match_id)
    del seen[:-200]
    mode, levels = result.get('game_mode'), store.data['game_records'].get('CELevels') or {}
    secs = min(float(result.get('match_time') or sum(r.get('TotalRoundTime', 0) for r in rounds)), XP_MATCH_CAP)
    for uid, p in players.items():
        recs, won = store.data['player_records'].setdefault(uid, {}), p['team'] == winner
        history = stats_record(store, uid, 'PROFILE_HISTORY_KEY')
        history['Matches'] = (history.get('Matches') or [])[-(HISTORY_LENGTH - 1):] + [entry]
        recs['PROFILE_HISTORY_KEY'] = history
        if mode not in RATED_MODES:
            continue
        per_sec, base = XP_WIN if won else XP_LOSE
        xp = int(secs * per_sec + base)
        m = stats_record(store, uid, 'PROFILE_MASTERY_KEY')
        m['Level'], m['XPToNext'] = level_up(m.get('Level', 1), m.get('XPToNext', 0) + xp, levels.get('Account', []), True)
        m['MatchesPlayed'] = m.get('MatchesPlayed', 0) + 1
        m['MatchesWon'] = m.get('MatchesWon', 0) + won
        m['RoundsWon'] = m.get('RoundsWon', 0) + int(result.get('rounds_a' if p['team'] == 'TeamA' else 'rounds_b') or 0)
        if p['hero']:
            h = m.get(p['hero']) if isinstance(m.get(p['hero']), dict) else {'Level': 1, 'XPToNext': 0}
            h['Level'], h['XPToNext'] = level_up(h.get('Level', 1), h.get('XPToNext', 0) + xp, levels.get('Hero', []), False)
            h['MatchesPlayed'] = h.get('MatchesPlayed', 0) + 1
            h['MatchesWon'] = h.get('MatchesWon', 0) + won
            m[p['hero']] = h
        recs['PROFILE_MASTERY_KEY'] = m
    sides = [[uid for uid, p in players.items() if p['team'] == t] for t in (winner, *(set(TEAMS.values()) - {winner}))]
    rated = mode in RATED_MODES and all(sides)
    if rated:
        old = [[stats_record(store, uid, 'PROFILE_RATINGS_KEY').get('ranked_rating') or DEFAULT_RATING for uid in side]
               for side in sides]
        for side, new in zip(sides, plackett_luce([(0, old[0]), (1, old[1])])):
            for uid, r in zip(side, new):
                r = {'mu': round(r['mu'], 4), 'sigma': round(r['sigma'], 4)}
                store.data['player_records'][uid]['PROFILE_RATINGS_KEY'] = {'casual_rating': r, 'ranked_rating': dict(r)}
    store.save()
    log({'match': match_id, 'mode': mode, 'map': entry.get('MapLevel'), 'winner': winner, 'rated': rated,
         'players': {p['user']['display_name']: p['team'] for p in players.values()}})


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


_manifest_cache = {}


def launcher_files(downloads):
    """Paths listed in <downloads>/manifest.json (cached until the file changes)."""
    mf = Path(downloads) / 'manifest.json'
    try:
        mtime = mf.stat().st_mtime_ns
    except OSError:
        return set()
    if _manifest_cache.get('mtime') != mtime:
        files = {f['path'] for f in json.loads(mf.read_text()).get('files', [])}
        _manifest_cache.update(mtime=mtime, files=files)
    return _manifest_cache['files']


@route('GET', r'/download/(?P<code>[^/]+)/files/(?P<path>.+)')
async def download_file(request):
    """Game and player files for the launcher (FangsCE.exe): only paths listed in manifest.json, from
    <downloads>/overlay (our player files) or else the game install. Supports Range (resumable)."""
    cfg = request.app['cfg']
    if not cfg.downloads or not cfg.join_code or not hmac.compare_digest(request.match_info['code'], cfg.join_code):
        return err(404, 404, 'not found')
    rel = request.match_info['path']
    if rel not in launcher_files(cfg.downloads):
        return err(404, 404, 'not found')
    for root in (Path(cfg.downloads) / 'overlay', Path(cfg.game_dir)):
        path = (root / rel).resolve()
        if path.is_relative_to(root.resolve()) and path.is_file():
            return web.FileResponse(path)
    return err(404, 404, 'not found')


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


# ---------------------------------------------------------------- Zeuz-style custom lobbies (Aug 2022 client)
# That client creates/lists custom lobbies at a hard-coded Improbable "Zeuz" URL. FangsBoot puts it in LAN
# mode (which skips those calls) and makes them here instead:
#   POST /zeuz/sessions {"session_config": "max_players,6,lobby_name,..,map_name,..,map_level,.."}
#        -> {"id", "address", "ports": [{"port"}]} of a game server for the lobby (the client then joins it)
#   GET  /zeuz/sessions.txt -> one joinable lobby per line, tab separated (parsed by FangsBoot):
#        id, address:port, lobby name, owner, map name, map level, players, max players

def zeuz_user(request):
    auth = request.headers.get('Authorization', '')
    token = auth.split('accelbyte/', 1)[1] if 'accelbyte/' in auth else auth.removeprefix('Bearer ')
    return request.app['store'].tokens.get(token, {}).get('user_id')


@route('POST', r'/zeuz/sessions')
async def zeuz_create(request):
    app, uid = request.app, zeuz_user(request)
    user = app['store'].user_by_id(uid or '')
    if not user:
        return err(401, 20001, 'unauthorized')
    body = await request.json()
    parts = str(body.get('session_config', '')).split(',')
    conf = {k: v for k, v in zip(parts[0::2], parts[1::2])}
    conf['lobby_owner'] = user['display_name']           # trust the login, not the client
    sid, hosts, reuse = uuid.uuid4().hex, app['hosts'], None
    for old_sid, old in list(app['zeuz'].items()):        # one custom lobby per player
        if old['user_id'] == uid:
            app['zeuz'].pop(old_sid)
            # nobody ever joined its server (e.g. Create clicked twice): hand that server to the new lobby
            if reuse is None and hosts.is_live(old['host']) and not old['host'].had_players:
                reuse = old['host']
            else:
                asyncio.create_task(hosts.stop(old['host'], 'owner created a new lobby'))
    if reuse:
        host = reuse
        host.session_id, host.started = sid, time.time()
    else:
        try:
            host = await hosts.allocate(sid)
        except RuntimeError as e:
            app['log']({'zeuz': 'create failed', 'error': str(e)})
            return err(503, 503, str(e))
    app['zeuz'][sid] = {'user_id': uid, 'config': conf, 'host': host, 'created': time.time()}
    app['log']({'zeuz': 'lobby', 'session': sid, 'host': host.id, 'config': conf})
    return web.json_response({'id': sid, 'address': app['cfg'].public_ip, 'ports': [{'port': host.port}]})


@route('GET', r'/zeuz/sessions\.txt')
async def zeuz_list(request):
    app = request.app
    if not zeuz_user(request):
        return err(401, 20001, 'unauthorized')
    lines = []
    for sid, s in app['zeuz'].items():
        st, conf = s['host'].status, s['config']
        if not st.get('map', '').endswith('LE_Lobby_Map'):      # gone to the arena (or gone)
            continue
        players, max_players = int(st.get('players', 0)), int(conf.get('max_players', '8') or 8)
        if players >= max_players or (s['host'].had_players and not players):   # full, or abandoned
            continue
        clean = lambda v: str(v).replace('\t', ' ').replace('\n', ' ')
        lines.append('\t'.join(clean(v) for v in (
            sid, f"{app['cfg'].public_ip}:{s['host'].port}", conf.get('lobby_name', ''), conf.get('lobby_owner', ''),
            conf.get('map_name', ''), conf.get('map_level', ''), players, max_players)))
    return web.Response(text='\n'.join(lines), content_type='text/plain')


async def lobby_ws(request):
    ws = web.WebSocketResponse(protocols=('wss',), heartbeat=30)
    await ws.prepare(request)
    app, who, log = request.app, caller(request), request.app['log']
    log({'ws': 'lobby', 'event': 'connect', 'who': who})
    uid = who.get('user_id')   # players only (game hosts log in without a user)
    if uid:
        app['lobby_users'].setdefault(uid, set()).add(ws)
    try:
        await ws.send_str(lobby_frame(type='connectNotif', lobbySessionID=uuid.uuid4().hex))
        if uid:
            await app['social'].connect(uid, ws)   # friends, presence, parties, chat: social.py
        async for msg in ws:
            if msg.type != WSMsgType.TEXT or not msg.data.strip():   # empty frames are the SDK's pings
                continue
            log({'ws': 'lobby', 'recv': msg.data[:2000]})
            fields = {k: v.strip() for k, v in (line.split(': ', 1) for line in msg.data.split('\n') if ': ' in line)}
            t, mid = fields.get('type', ''), fields.get('id', '')
            if uid and await app['social'].handle(uid, ws, t, fields):
                continue
            if t.endswith('Request'):
                await ws.send_str(lobby_frame(type=t[:-len('Request')] + 'Response', id=mid, code=0))
            if t == 'createDSRequest':
                asyncio.create_task(handle_create_ds(app, ws, fields))
    finally:
        if uid:
            socks = app['lobby_users'].get(uid, set())
            socks.discard(ws)
            if not socks:
                app['lobby_users'].pop(uid, None)
                app['lobby_left'][uid] = time.time()
            app['social'].disconnect(uid, ws)
        log({'ws': 'lobby', 'event': 'close', 'who': who})
    return ws


# Friend search: the client looks up "name#1234" and takes the result whose displayName matches exactly.
@route('GET', r'/iam/v3/public/namespaces/[^/]+/users')
async def users_search(request):
    store = request.app['store']
    if not caller(request).get('user_id'):
        return err(401, 20001, 'unauthorized')
    q = request.query.get('query', '').strip().lower()
    users = [u for u in store.data['users'].values() if q and tagged_name(u).lower() == q][:1]
    return web.json_response({'data': [{'userId': u['user_id'], 'displayName': tagged_name(u),
                                        'userName': u['display_name'], 'namespace': NAMESPACE,
                                        'createdAt': u['created_at']} for u in users],
                              'paging': {'first': '', 'last': '', 'next': '', 'previous': ''}})


@route('GET', r'/lobby/v1/public/presence/namespaces/[^/]+/users/presence')
async def users_presence(request):
    if not caller(request).get('user_id'):
        return err(401, 20001, 'unauthorized')
    ids = [i for i in request.query.get('userIds', '').split(',') if i][:100]
    rows = request.app['social'].presence_rows(ids)
    count = {a: sum(r['availability'] == a for r in rows) for a in ('online', 'busy', 'invisible', 'offline')}
    if request.query.get('countOnly', 'false').lower() == 'true':
        rows = []
    return web.json_response({'data': rows, **count})


# Main-menu "players online" (FangsBoot, in place of the missions list): players with an open lobby connection,
# which the game keeps from login to quit, or who lost it less than a minute ago (map changes, reconnects).
# Public like the rest of the login screen's data; it is just a number.
@route('GET', r'/fangsapi/[^/]+/online-players')
async def fangs_online_players(request):
    app, now = request.app, time.time()
    for uid, t in list(app['lobby_left'].items()):
        if now - t > 60 or uid in app['lobby_users']:
            del app['lobby_left'][uid]
    return web.Response(text=str(len(app['lobby_users']) + len(app['lobby_left'])), content_type='text/plain')


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
        return await request.app['matchmaker'].handle(request)
    path = request.path
    if path.startswith('/fangsapi') and not path.startswith('/fangsapi/'):
        # Aug 2022 client: some Blueprints join FANGSApiBaseURL and the route without separator or stage
        path = '/fangsapi/prod/' + path[len('/fangsapi'):]
    for method, rx, fn in ROUTES:
        m = rx.match(path)
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
    ap.add_argument('--host-standby', type=int, default=1,
                    help='game servers kept booted and idle so lobbies/matches start at once (each ~3 GB RAM)')
    ap.add_argument('--match-size', type=int, default=8, help='players per matchmade game (Play -> Casual)')
    ap.add_argument('--match-wait', type=float, default=0,
                    help='if > 0: seconds the first queued player waits before a match starts with whoever is queued '
                         '(at least 2); by default matches only start full')
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
    app['lobby_users'], app['lobby_left'] = {}, {}   # user id -> open lobby websockets / when the last one closed
    app['social'] = Social(app)
    lo, hi = map(int, a.host_ports.split('-'))
    app['hosts'] = HostManager(game_dir=a.game_dir, inst_root=a.instances, ports=range(lo, hi + 1),
                               run_script=a.run_host, backend_addr=f'127.0.0.1:{a.port}', log=log,
                               data_dir=str(Path(a.data).resolve().parent), standby=a.host_standby)

    app['matchmaker'] = Matchmaker(app, size=a.match_size, wait=a.match_wait)

    app['zeuz'] = {}

    def host_stopped(host):  # drop the custom lobby whose game server went away
        app['sessions'].pop(host.session_id, None)
        app['zeuz'].pop(host.session_id, None)
    app['hosts'].on_stopped.append(host_stopped)
    app['hosts'].on_result.append(lambda host, result: ingest_match(app['store'], result, log))
    if Path(a.seed).exists():  # seed (re)defines the global game records on every start
        app['store'].data['game_records'].update(json.loads(Path(a.seed).read_text()))
    app['store'].export_records()

    async def start_udp(app):
        loop = asyncio.get_running_loop()
        app['udp'], _ = await loop.create_datagram_endpoint(_UdpEcho, local_addr=(a.host, a.qos_port))
        app['matchmaking'] = asyncio.create_task(app['matchmaker'].run())
        app['hosts'].replenish()   # boot the standby game server(s)

    async def stop_udp(app):
        app['udp'].close()
        app['matchmaking'].cancel()
        await app['hosts'].shutdown()
    app.on_startup.append(start_udp)
    app.on_cleanup.append(stop_udp)
    app.router.add_route('*', '/{tail:.*}', lambda r: web.Response(status=500))  # never reached; middleware answers
    web.run_app(app, host=a.host, port=a.port, print=lambda *_: print(f'fangs backend on {a.host}:{a.port}', flush=True))


if __name__ == '__main__':
    main()
