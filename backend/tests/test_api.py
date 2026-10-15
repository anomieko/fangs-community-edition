"""The backend's HTTP API and lobby websocket as they behave now (backend/fangs_backend.py): login, who may call what,
player and game records, custom lobbies and their game servers, downloads, routing, and match results through the
real app. Pinned before the review sprint's fixes; a known bug is an expectedFailure test named for the correct
behavior ("# bug: ..."). Game servers are fake_host.py processes (with hosts.py's polls sped up) or ready_host(): a
booted server without a process.

    python -I -m unittest discover -s backend/tests -p 'test_api.py' -v
"""
import asyncio
import json
import logging
import time
import unittest
from unittest import mock

from aiohttp import WSMsgType

from support import BackendCase, backend_args, fb
import hosts  # after support, which puts backend/ on sys.path
from hosts import LOBBY_MAP, Host

NS = '/cloudsave/v1/namespaces/fangs'
GAME = f'{NS}/records'
SESSIONS = '/sessionbrowser/namespaces/fangs/gamesession'
API = '/fangsapi/prod'      # the lambda routes; the Feb 2023 build's stage
CODE = 'join-7f3a'          # join code of the tests that set one
GHOST = '0' * 32            # a user id nobody has


def rec(uid, key):
    return f'{NS}/users/{uid}/records/{key}'


def parse(frame):
    """A lobby websocket frame ("key: value" lines) as a dict."""
    return dict(line.split(': ', 1) for line in frame.split('\n') if ': ' in line)


def create_ds(sid, mid='1'):
    return fb.lobby_frame(type='createDSRequest', id=mid, matchId=sid, deployment='fangs', clientVersion='test')


class FastPolls:
    """hosts.py's asyncio with its sleeps (2 s status polls, 0.5 s waits) cut 40 times, so a fake host is up at once."""
    def __getattr__(self, name):
        return getattr(asyncio, name)

    @staticmethod
    async def sleep(secs):
        await asyncio.sleep(secs / 40)


class ApiCase(BackendCase):
    async def call(self, method, path, token=None, *, local=False, headers=None, **kw):
        """(status, body) of a request by the player holding `token` (None: no token) or, with `local`, by a game
        server on this machine. The body is parsed JSON, or text."""
        headers = {**(self.auth(token) if token else {}), **(headers or {})}
        async with (self.local if local else self.client).request(method, path, headers=headers, **kw) as r:
            return r.status, (await r.json() if r.content_type == 'application/json' else await r.text())

    async def token(self, *, local=False, **form):
        return await self.call('POST', '/iam/v3/oauth/token', local=local, data=form)

    async def until(self, cond, what):
        deadline = time.monotonic() + 5
        while not cond():
            self.assertLess(time.monotonic(), deadline, f'timed out waiting for {what}')
            await asyncio.sleep(0.01)

    def ready_host(self, port, **status):
        """A booted game server on the lobby map, free for allocate(). It has no process (stop() needs none)."""
        hm = self.app['hosts']
        host = hm.hosts[f'host-{port}'] = Host(f'host-{port}', port, hm.inst_root / f'host-{port}')
        host.ready.set()
        self.set_status(host, **status)
        return host

    @staticmethod
    def set_status(host, **status):
        """FangsHost's heartbeat file: map, players, launched (match started)."""
        win64 = host.inst / 'MOBA' / 'Binaries' / 'Win64'
        win64.mkdir(parents=True, exist_ok=True)
        (win64 / 'fangshost_status.json').write_text(json.dumps({'map': LOBBY_MAP, 'ready': True, 'players': 0,
                                                                 **status}))

    async def lobby(self, token=None):
        """A lobby websocket opened the way the game does (subprotocol wss), past its connectNotif."""
        ws = await self.client.ws_connect('/lobby/', protocols=('wss',), headers=self.auth(token) if token else None)
        self.assertEqual(parse(await ws.receive_str())['type'], 'connectNotif')
        return ws

    async def recv(self, ws, type_):
        """The next lobby frame of type `type_`; frames of other types are skipped."""
        while True:
            f = parse(await asyncio.wait_for(ws.receive_str(), 5))
            if f['type'] == type_:
                return f

    async def new_lobby(self, token, **body):
        status, sess = await self.call('POST', SESSIONS, token, json=body)
        self.assertEqual(status, 200, sess)
        return sess

    async def server_for(self, token, sid):
        """The dsNotif answering a createDSRequest for lobby `sid` from `token`'s lobby websocket."""
        ws = await self.lobby(token)
        await ws.send_str(create_ds(sid))
        notif = await self.recv(ws, 'dsNotif')
        await ws.close()
        return notif


# ---------------------------------------------------------------- login

class Login(ApiCase):
    async def test_first_login_binds_the_name_to_its_secret(self):
        alice = await self.login('alice', 's1')
        self.assertRegex(alice['display_name'], r'^alice#\d{4}$')   # the client takes the part before '#' as the name
        status, body = await self.token(grant_type='password', username='alice', password='s2')
        self.assertEqual((status, body['errorCode']), (401, 10130))
        again = await self.login('alice', 's1')
        self.assertEqual(again['user_id'], alice['user_id'])
        status, me = await self.call('GET', '/iam/v3/public/users/me', again)
        self.assertEqual((status, me['userId'], me['userName'], me['displayName']),
                         (200, alice['user_id'], 'alice', alice['display_name']))

    async def test_a_name_in_other_case_cannot_log_into_an_account(self):
        # the user id comes from the lower-cased name: "ALICE" is alice's account and needs her secret (review S1)
        alice = await self.login('alice', 's1')
        status, body = await self.token(grant_type='password', username='ALICE', password='other')
        self.assertEqual((status, body.get('errorCode')), (401, 10130), body)
        again = await self.login('ALICE', 's1')
        self.assertEqual((again['user_id'], again['display_name']), (alice['user_id'], alice['display_name']))
        self.assertEqual(list(self.app['store'].data['users']), ['alice'])

    def test_names_stored_twice_in_other_case_log_in_as_the_first(self):
        # stores from before the fix can hold "Alice" and "ALICE" with one user id and two secrets
        store = fb.Store(self.tmp / 'old.json')
        for name, secret in (('Alice', 's1'), ('ALICE', 's2')):
            store.data['users'][name] = {'user_id': 'u1', 'display_name': name}
            store.check_secret(store.data['users'][name], secret)
        user = store.user_for('alice')
        self.assertEqual(user['display_name'], 'Alice')
        self.assertTrue(store.check_secret(user, 's1'))
        self.assertFalse(store.check_secret(user, 's2'))
        logs = []
        fb.make_app(backend_args(self.tmp, '--data', str(self.tmp / 'old.json')), logs.append)
        self.assertIn({'store': 'names that differ only in case (the first one is the account)',
                       'names': [['Alice', 'ALICE']]}, logs)

    async def test_names_are_3_to_16_letters_digits_or_underscores(self):
        for name, ok in (('ab', False), ('abc', True), ('a_b_9' * 3 + 'x', True), ('a' * 17, False),
                         ('two words', False), ('dash-ed', False), ('ünï', False), ('', False)):
            with self.subTest(name=name):
                status, body = await self.token(grant_type='password', username=name, password='s')
                self.assertEqual(status, 200 if ok else 400, body)
                if not ok:
                    self.assertEqual(body['errorCode'], 10132)

    async def test_secret_is_stored_salted_and_redacted_in_the_log(self):
        await self.login('alice', 'hunter2-install-secret')
        self.assertRegex(self.app['store'].data['users']['alice']['secret'], r'^[0-9a-f]{16}\$[0-9a-f]{64}$')   # salt$sha256
        self.assertNotIn('hunter2', (self.tmp / 'store.json').read_text())
        logged = json.dumps(self.logs)
        self.assertNotIn('hunter2', logged)
        self.assertIn('password=<redacted>', logged)

    async def test_refresh_token_logs_the_same_player_in_again(self):
        alice = await self.login('alice')
        status, new = await self.token(grant_type='refresh_token', refresh_token=alice['refresh_token'])
        self.assertEqual((status, new['user_id'], new['display_name']), (200, alice['user_id'], alice['display_name']))
        self.assertNotEqual(new['access_token'], alice['access_token'])
        status, body = await self.token(grant_type='refresh_token', refresh_token='not-a-token')
        self.assertEqual((status, body['errorCode']), (401, 10196))
        # pinned as is, see report (questions): access and refresh tokens share one table, so either works as either
        status, _ = await self.call('GET', '/iam/v3/public/users/me', {'access_token': alice['refresh_token']})
        self.assertEqual(status, 200)

    async def test_server_login_only_from_this_machine(self):
        status, body = await self.token(grant_type='client_credentials')
        self.assertEqual((status, body['errorCode']), (401, 10133))
        status, server = await self.token(local=True, grant_type='client_credentials')
        self.assertEqual((status, server['user_id']), (200, ''))
        # the token makes a server, not the address: from a player's address it still writes game records
        status, _ = await self.call('PUT', f'{GAME}/CETest', server, json={'on': True})
        self.assertEqual(status, 200)

    async def test_other_grant_types_and_platform_logins_are_refused(self):
        status, body = await self.token(grant_type='authorization_code', code='x')
        self.assertEqual((status, body['errorCode']), (400, 10140))
        # Steam/Epic logins can't be verified without those services: only the launcher's name login
        status, body = await self.call('POST', '/iam/v3/oauth/platforms/steam/token', data={'platform_token': 'x'})
        self.assertEqual((status, body['errorCode']), (401, 10134))

    async def test_revoke_answers_ok_but_the_token_keeps_working(self):
        # pinned as is, see report (questions): tokens are only dropped by a backend restart
        alice = await self.login('alice')
        status, _ = await self.call('POST', '/iam/v3/oauth/revoke', alice, data={'token': alice['access_token']})
        self.assertEqual(status, 200)
        status, _ = await self.call('GET', '/iam/v3/public/users/me', alice)
        self.assertEqual(status, 200)


class JoinCode(ApiCase):
    extra_args = ('--join-code', CODE)

    async def test_login_needs_the_join_code_before_the_secret(self):
        for password in ('wrong:s1', 's1', ':s1', ''):
            with self.subTest(password=password):
                status, body = await self.token(grant_type='password', username='alice', password=password)
                self.assertEqual((status, body['errorCode']), (401, 10131))
        self.assertNotIn('alice', self.app['store'].data['users'])     # no account without the code
        await self.login('alice', f'{CODE}:s1')                         # the launcher sends "<join code>:<secret>"
        status, body = await self.token(grant_type='password', username='alice', password=f'{CODE}:s2')
        self.assertEqual((status, body['errorCode']), (401, 10130))     # the part after the code is the secret
        self.assertNotIn(CODE, json.dumps(self.logs))


# ---------------------------------------------------------------- who may call what

class Auth(ApiCase):
    """Players (a token with a user), game servers (on this machine, or a client_credentials token) and anyone."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.alice, self.bob = await self.login('alice'), await self.login('bob')
        self.a = self.alice['user_id']
        _, self.server = await self.token(local=True, grant_type='client_credentials')

    async def test_requests_without_a_login_get_401(self):
        a = self.a
        # (method, path, json body, whether a game server's token is enough)
        for method, path, body, server_ok in (
                ('GET', '/iam/v3/public/users/me', None, False),
                ('GET', '/iam/v3/public/namespaces/fangs/users?query=alice', None, False),
                ('GET', f'/lobby/v1/public/presence/namespaces/fangs/users/presence?userIds={a}', None, False),
                ('POST', '/iam/v3/public/namespaces/fangs/users/bulk/basic', {'userIds': [a]}, True),
                ('POST', f'{NS}/users/bulk/records/PROFILE_INFO_KEY/public', {'userIds': [a]}, True),
                ('GET', rec(a, 'PROFILE_INFO_KEY'), None, True),
                ('PUT', rec(a, 'Justice'), {'k': 1}, True),
                ('POST', f'{API}/update-player-record-key', {'RecordId': 'Justice', 'Key': 'k', 'Value': 1}, False),
                ('PUT', f'{API}/update-player-info', {'cosmeticType': 'Hero', 'cosmeticId': 'FireMage'}, False),
                ('PUT', f'{API}/update-player-settings', {'Volume': 1}, False),
                ('POST', f'{API}/update-loadouts', {'Berserker': {}}, False),
                ('POST', SESSIONS, {}, False),
                ('POST', '/zeuz/sessions', {}, False),
                ('GET', '/zeuz/sessions.txt', None, False)):
            with self.subTest(method=method, path=path):
                status, resp = await self.call(method, path, json=body)
                self.assertEqual((status, resp['errorCode']), (401, 20001))
                status, resp = await self.call(method, path, self.server, json=body)
                self.assertEqual(status, 200 if server_ok else 401, resp)

    async def test_public_endpoints_answer_without_a_token(self):
        # the unauthenticated surface as it is (plus the session_one routes, see test_only_the_owner_can_delete_a_lobby)
        for path in ('/qosm/public/qos', f'{GAME}/FANGSConfig', f'/platform/public/namespaces/fangs/users/{self.a}/entitlements',
                     '/leaderboard/v3/public/namespaces/fangs/leaderboards/s/alltime',
                     f'/leaderboard/v3/public/namespaces/fangs/leaderboards/s/users/{self.a}', f'{API}/vivox-token',
                     f'{API}/online-players', f'{API}/server-status', SESSIONS, f'{SESSIONS}/bulk?user_ids={self.a}'):
            with self.subTest(path=path):
                self.assertEqual((await self.call('GET', path))[0], 200)

    async def test_player_cannot_use_server_only_endpoints(self):
        config = json.dumps(self.app['store'].data['game_records']['FANGSConfig'])
        for method, path, body in (('PUT', f'{GAME}/FANGSConfig', {}), ('POST', f'{GAME}/CENew', {'a': 1}),
                                   ('DELETE', f'{GAME}/FANGSConfig', None),
                                   ('PUT', '/social/v2/admin/namespaces/fangs/statitems/value/bulk',
                                    [{'statCode': 'kills', 'userId': self.a, 'value': 99}])):
            with self.subTest(method=method, path=path):
                status, resp = await self.call(method, path, self.alice, json=body)
                self.assertEqual((status, resp['errorCode']), (403, 20013))
        status, resp = await self.call('GET', f'{GAME}/FANGSConfig', self.alice)
        self.assertEqual((status, json.dumps(resp['value'])), (200, config))
        self.assertNotIn('CENew', self.app['store'].data['game_records'])

    async def test_game_server_writes_game_records(self):
        await self.call('POST', f'{GAME}/CENew', local=True, json={'a': 1})
        status, resp = await self.call('POST', f'{GAME}/CENew', local=True, json={'b': 2})
        self.assertEqual((status, resp['value']), (200, {'a': 1, 'b': 2}))   # POST merges, PUT replaces
        self.assertEqual((await self.call('DELETE', f'{GAME}/CENew', local=True))[0], 204)
        status, resp = await self.call('GET', f'{GAME}/CENew', self.alice)
        self.assertEqual((status, resp['errorCode']), (404, 18003))
        # stat items (kills, damage) are accepted and dropped: match statistics come from the result file instead
        status, resp = await self.call('PUT', '/social/v2/admin/namespaces/fangs/statitems/value/bulk', local=True,
                                       json=[{'statCode': 'kills', 'userId': self.a, 'value': 3}])
        self.assertEqual((status, resp), (200, [{'statCode': 'kills', 'userId': self.a, 'success': True, 'details': {}}]))

    async def test_player_cannot_write_another_players_records(self):
        mine = rec(self.a, 'PROFILE_SETTINGS_KEY')
        await self.call('PUT', mine, self.alice, json={'Volume': 1})
        for method in ('PUT', 'POST', 'DELETE'):
            for path in (mine, f'{mine}/public', mine.replace('/cloudsave/v1/', '/cloudsave/v1/admin/')):
                with self.subTest(method=method, path=path):
                    status, resp = await self.call(method, path, self.bob, json={'Volume': 0})
                    self.assertEqual((status, resp['errorCode']), (403, 20013))
        status, resp = await self.call('GET', mine, self.bob)
        self.assertEqual((status, resp['value']), (200, {'Volume': 1}))
        status, _ = await self.call('PUT', mine, local=True, json={'Volume': 2})   # FangsHost writes players' records
        self.assertEqual(status, 200)

    async def test_player_cannot_post_match_results(self):
        # Results only come as files from our game servers (MatchResults below); over HTTP the match statistics are
        # read-only for everyone, game servers included.
        for key in ('PROFILE_HISTORY_KEY', 'PROFILE_MASTERY_KEY', 'PROFILE_RATINGS_KEY'):
            for method in ('PUT', 'POST', 'DELETE'):
                for token, local in ((self.alice, False), (None, True)):
                    with self.subTest(key=key, method=method, local=local):
                        status, resp = await self.call(method, rec(self.a, key), token, local=local,
                                                       json={'MatchesWon': 99})
                        self.assertEqual((status, resp['errorCode']), (403, 20013))
        status, resp = await self.call('GET', rec(self.a, 'PROFILE_MASTERY_KEY'), self.alice)
        self.assertEqual((status, resp['value']), (200, {'Level': 1, 'XPToNext': 0}))   # served, no MatchesPlayed yet
        status, resp = await self.call('GET', rec(GHOST, 'PROFILE_MASTERY_KEY'), self.alice)
        self.assertEqual((status, resp['errorCode']), (404, 18022))

    # bug: update-player-record-key writes any field of any of the caller's records, match statistics and profile
    # identity included, see report
    @unittest.expectedFailure
    async def test_record_key_lambda_cannot_set_match_statistics_or_identity(self):
        await self.call('GET', rec(self.a, 'PROFILE_INFO_KEY'), self.alice)   # the profile exists
        for record, key, value in (('PROFILE_MASTERY_KEY', 'MatchesWon', 999), ('PROFILE_INFO_KEY', 'Username', 'bob#0001')):
            await self.call('POST', f'{API}/update-player-record-key', self.alice,
                            json={'RecordId': record, 'Key': key, 'Value': value})
        _, mastery = await self.call('GET', rec(self.a, 'PROFILE_MASTERY_KEY'), self.bob)
        _, info = await self.call('GET', rec(self.a, 'PROFILE_INFO_KEY'), self.bob)
        self.assertEqual((mastery['value'].get('MatchesWon'), info['value']['Username']),
                         (None, self.alice['display_name']))

    # bug: a CloudSave write to your own PROFILE_INFO_KEY sets Username, which update-player-info keeps read-only, see
    # report
    @unittest.expectedFailure
    async def test_cloudsave_write_cannot_change_profile_identity(self):
        _, info = await self.call('GET', rec(self.a, 'PROFILE_INFO_KEY'), self.alice)
        await self.call('PUT', rec(self.a, 'PROFILE_INFO_KEY'), self.alice, json={**info['value'], 'Username': 'bob#0001'})
        _, info = await self.call('GET', rec(self.a, 'PROFILE_INFO_KEY'), self.bob)
        self.assertEqual(info['value']['Username'], self.alice['display_name'])


# ---------------------------------------------------------------- player records

class Records(ApiCase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.alice, self.bob = await self.login('alice'), await self.login('bob')
        self.a, self.b = self.alice['user_id'], self.bob['user_id']

    async def test_player_reads_and_writes_own_records(self):
        path = rec(self.a, 'PROFILE_LOADOUT_KEY')
        status, resp = await self.call('GET', path, self.alice)
        self.assertEqual((status, resp['errorCode']), (404, 18022))   # no default for this key
        for method, body, value in (('PUT', {'A': 1, 'B': 1}, {'A': 1, 'B': 1}),
                                    ('POST', {'B': 2}, {'A': 1, 'B': 2}),    # POST merges top-level fields
                                    ('PUT', {'C': 3}, {'C': 3})):             # PUT replaces
            status, resp = await self.call(method, path, self.alice, json=body)
            self.assertEqual((status, resp['value']), (200, value))
        # any player reads anyone's records, /public or not (see report, questions)
        for p in (path, f'{path}/public'):
            status, resp = await self.call('GET', p, self.bob)
            self.assertEqual((status, resp['value'], resp['is_public']), (200, {'C': 3}, p.endswith('/public')))
        self.assertEqual((await self.call('DELETE', path, self.alice))[0], 204)
        self.assertEqual((await self.call('GET', path, self.alice))[0], 404)

    async def test_profile_is_created_on_first_read(self):
        status, resp = await self.call('GET', rec(self.a, 'PROFILE_INFO_KEY') + '/public', self.bob)
        info = resp['value']
        # GameplayTutorialComplete 3: everything is unlocked, so players start past the tutorial
        self.assertEqual((status, info['Username'], info['GameplayTutorialComplete']), (200, self.alice['display_name'], 3))
        self.assertEqual(self.app['store'].data['player_records'][self.a]['PROFILE_INFO_KEY'], info)
        # also for a user id nobody has (pinned as is, see report, questions): a read stores a profile for it
        status, resp = await self.call('GET', rec(GHOST, 'PROFILE_INFO_KEY'), self.alice)
        self.assertEqual((status, resp['value']['Username'].split('#')[0]), (200, GHOST[:8]))
        self.assertIn(GHOST, json.loads((self.tmp / 'store.json').read_text())['player_records'])

    async def test_update_player_info_edits_the_profile_but_not_identity_fields(self):
        for ctype, cid in (('Hero', 'FireMage'), ('Cosmetics.Title', 'title_x'), ('Stickers', '["happy", "no spaces", ""]')):
            status, info = await self.call('PUT', f'{API}/update-player-info', self.alice,
                                           json={'cosmeticType': ctype, 'cosmeticId': cid})
            self.assertEqual(status, 200, info)
        self.assertEqual((info['Hero'], info['Cosmetics']['Title'], info['Stickers']), ('FireMage', 'title_x', ['happy', '', '']))
        for ctype in ('Username', 'GameplayTutorialComplete', 'UserId', 'Cosmetics..x', 'a.b.c.d', 'Hero/x', ''):
            with self.subTest(cosmeticType=ctype):
                status, resp = await self.call('PUT', f'{API}/update-player-info', self.alice,
                                               json={'cosmeticType': ctype, 'cosmeticId': 'x'})
                self.assertEqual((status, resp['errorCode']), (400, 20002))
        _, resp = await self.call('GET', rec(self.a, 'PROFILE_INFO_KEY'), self.alice)
        self.assertEqual((resp['value']['Username'], resp['value']['Hero']), (self.alice['display_name'], 'FireMage'))

    async def test_settings_and_loadouts_go_to_the_callers_own_records(self):
        await self.call('PUT', f'{API}/update-player-settings', self.alice, json={'Volume': 0.5})
        loadouts = {'Berserker': {'CurrentLoadoutIndex': 0}}
        await self.call('POST', f'{API}/update-loadouts', self.alice, json={'Value': json.dumps(loadouts)})
        self.assertEqual(self.app['store'].data['player_records'][self.a],
                         {'PROFILE_SETTINGS_KEY': {'Volume': 0.5}, 'PROFILE_LOADOUT_KEY': loadouts})
        for path, body in ((f'{API}/update-player-settings', [1]), (f'{API}/update-loadouts', 'not an object')):
            status, resp = await self.call('PUT', path, self.alice, json=body)
            self.assertEqual((status, resp['errorCode']), (400, 20002), path)

    async def test_bulk_lookups_answer_per_requested_user(self):
        # names: the SDK sends this with and without the /iam prefix; unknown ids are left out
        status, resp = await self.call('POST', '/v3/public/namespaces/fangs/users/bulk/basic', self.alice,
                                       json={'userIds': [self.b, GHOST, self.a]})
        self.assertEqual((status, [u['displayName'] for u in resp['data']]),
                         (200, [self.bob['display_name'], self.alice['display_name']]))
        # records: the client matches rows by index, so one row per requested id, in order, unknown ones too
        status, resp = await self.call('POST', f'{NS}/users/bulk/records/PROFILE_MASTERY_KEY/public', self.alice,
                                       json={'userIds': [self.b, GHOST, self.a]})
        self.assertEqual((status, [(r['user_id'], r['value']) for r in resp['data']]),
                         (200, [(u, {'Level': 1, 'XPToNext': 0}) for u in (self.b, GHOST, self.a)]))


# ---------------------------------------------------------------- custom lobbies and their game servers

class Lobbies(ApiCase):
    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.alice, self.bob = await self.login('alice'), await self.login('bob')
        self.hm = self.app['hosts']

    async def test_create_ds_boots_a_game_server_and_answers_busy(self):
        self.enterContext(mock.patch.object(hosts, 'asyncio', FastPolls()))
        sess = await self.new_lobby(self.alice, game_session_setting={'mode': 'Custom', 'max_player': 4})
        sid = sess['session_id']
        self.assertFalse(sess['joinable'])
        ws = await self.lobby(self.alice)
        await ws.send_str(create_ds(sid, mid='7'))
        self.assertEqual(await self.recv(ws, 'createDSResponse'), {'type': 'createDSResponse', 'id': '7', 'code': '0'})
        notif = await self.recv(ws, 'dsNotif')   # no standby server (--host-standby 0): fake_host.py boots for it
        # the client only goes on with BUSY (= a server claimed for this lobby)
        self.assertEqual({k: notif[k] for k in ('status', 'matchId', 'podName', 'ip', 'port', 'isOK')},
                         {'status': 'BUSY', 'matchId': sid, 'podName': 'host-17777', 'ip': '127.0.0.1', 'port': '17777',
                          'isOK': 'true'})
        host = self.hm.hosts['host-17777']
        self.assertEqual((host.session_id, host.proc.returncode), (sid, None))
        _, sess = await self.call('GET', f'{SESSIONS}/{sid}', self.bob)
        self.assertEqual((sess['joinable'], sess['server']['port'], sess['server']['status']), (True, 17777, 'READY'))
        _, status = await self.call('GET', f'{API}/server-status')
        self.assertEqual(status, '1\t1\t2\n')   # alice online; 1 of 2 game servers free
        await ws.close()

    async def test_create_ds_for_an_unknown_lobby_fails(self):
        notif = await self.server_for(self.alice, 'no-such-lobby')
        self.assertEqual((notif['status'], notif['isOK'], notif['message']), ('FAILED', 'false', 'unknown session no-such-lobby'))
        self.assertEqual(self.hm.hosts, {})

    async def test_owner_who_makes_a_new_lobby_while_its_server_boots_gets_that_server(self):
        # The client gives up after ~18 s but a server boots in 20-25 s; its retry is a new lobby (fixed 14 Oct).
        self.enterContext(mock.patch.object(hosts, 'asyncio', FastPolls()))
        (self.tmp / 'hosts').mkdir()
        (self.tmp / 'hosts' / 'fake_host_mode').write_text('hang')   # boots, but isn't ready until we say so
        first = (await self.new_lobby(self.alice))['session_id']
        ws = await self.lobby(self.alice)
        await ws.send_str(create_ds(first))
        await self.until(lambda: 'host-17777' in self.hm.hosts, 'the server to start')
        second = (await self.new_lobby(self.alice))['session_id']
        await ws.send_str(create_ds(second))
        self.set_status(self.hm.hosts['host-17777'])                  # now it is up
        notif = await self.recv(ws, 'dsNotif')
        self.assertEqual((notif['status'], notif['matchId'], notif['podName']), ('BUSY', second, 'host-17777'))
        self.assertEqual(list(self.hm.hosts), ['host-17777'])          # one server for both requests
        self.assertNotIn(first, self.app['sessions'])
        await ws.close()

    # bug: createDSRequest doesn't check that the sender owns the lobby: any connection, even one without a login,
    # claims a game server for it, see report
    @unittest.expectedFailure
    async def test_only_the_owner_can_request_a_lobbys_server(self):
        host = self.ready_host(17777)
        sid = (await self.new_lobby(self.alice))['session_id']
        for token in (self.bob, None):
            self.assertEqual((await self.server_for(token, sid))['status'], 'FAILED')
        self.assertIsNone(host.session_id)

    # bug: a second createDSRequest for a lobby claims a second server; the first stays assigned to the lobby, and
    # when it stops, host_stopped drops the lobby that the second one serves, see report
    @unittest.expectedFailure
    async def test_repeated_create_ds_keeps_the_lobbys_one_server(self):
        first, spare = self.ready_host(17777), self.ready_host(17778)
        sid = (await self.new_lobby(self.alice))['session_id']
        await self.server_for(self.alice, sid)
        await self.server_for(self.alice, sid)
        self.assertEqual((spare.session_id, self.app['sessions'][sid]['_host']), (None, first))

    async def test_one_custom_lobby_per_player(self):
        host = self.ready_host(17777)
        first = (await self.new_lobby(self.alice))['session_id']
        self.assertEqual((await self.server_for(self.alice, first))['podName'], 'host-17777')
        bobs = (await self.new_lobby(self.bob))['session_id']
        second = (await self.new_lobby(self.alice))['session_id']
        status, resp = await self.call('GET', f'{SESSIONS}/{first}', self.alice)
        self.assertEqual((status, resp['errorCode']), (404, 9014))
        await self.until(lambda: not self.hm.is_live(host), "the old lobby's server to stop")
        self.assertEqual(set(self.app['sessions']), {second, bobs})

    async def test_lobby_browser_lists_open_lobbies_with_owner_and_live_player_count(self):
        host = self.ready_host(17777)
        sess = await self.new_lobby(self.alice, game_session_setting={'mode': 'Custom', 'max_player': 4,
                                                                      'settings': {'lobby_name': 'fun'}})
        sid = sess['session_id']
        # the client's lobby browser hides lobbies without an owner name: an empty one is filled in
        self.assertEqual(sess['game_session_setting']['settings']['lobby_owner'], 'alice')
        named = await self.new_lobby(self.bob, game_session_setting={'settings': {'lobby_owner': 'someone'}})
        self.assertEqual(named['game_session_setting']['settings']['lobby_owner'], 'someone')   # the client's is kept

        async def listed(query=''):
            _, resp = await self.call('GET', SESSIONS + query)
            return [s['session_id'] for s in resp['sessions']]
        self.assertEqual(await listed(), [])                 # no server yet
        await self.server_for(self.alice, sid)
        self.assertEqual(await listed(), [sid])              # bob's still has none
        self.set_status(host, players=4)
        _, resp = await self.call('GET', SESSIONS)
        gs = resp['sessions'][0]['game_session_setting']
        self.assertEqual((gs['current_player'], gs['max_player']), (4, 4))   # full ones stay listed; the client hides them
        for query, ids in (('?session_type=dedicated', [sid]), ('?session_type=p2p', []), ('?game_mode=CUSTOM', [sid]),
                           ('?game_mode=battle', [])):
            self.assertEqual(await listed(query), ids, query)
        self.set_status(host, launched=True)                 # its match started
        self.assertEqual(await listed(), [])
        self.set_status(host)
        host.match_over = time.time()                        # its match is over
        self.assertEqual(await listed(), [])
        _, resp = await self.call('GET', f"{SESSIONS}/bulk?user_ids={self.alice['user_id']}")
        self.assertEqual([s['session_id'] for s in resp['data']], [sid])   # its players still find it

    async def test_join_needs_a_ready_lobby_and_a_started_match_takes_only_its_players(self):
        host = self.ready_host(17777)
        sid = (await self.new_lobby(self.alice))['session_id']

        async def join(token):
            return await self.call('POST', f'{SESSIONS}/{sid}/join', token)
        status, resp = await join(self.bob)
        self.assertEqual((status, resp['errorCode'], resp['errorMessage']), (409, 9015, 'session not ready'))
        await self.server_for(self.alice, sid)
        self.assertEqual((await join(self.bob))[0], 200)
        await self.call('POST', f'{SESSIONS}/{sid}/player', self.bob, json={'user_id': self.bob['user_id']})
        carol = await self.login('carol')
        self.set_status(host, launched=True)
        status, resp = await join(carol)
        self.assertEqual((status, resp['errorMessage']), (409, 'match already started'))
        self.assertEqual((await join(self.bob))[0], 200)     # back into his own match
        host.match_over = time.time()
        self.assertEqual((await join(self.bob))[0], 409)     # never into a finished one

    async def test_owner_deletes_a_lobby_and_its_server_stops(self):
        host = self.ready_host(17777)
        sid = (await self.new_lobby(self.alice))['session_id']
        await self.server_for(self.alice, sid)
        self.assertEqual((await self.call('DELETE', f'{SESSIONS}/{sid}', self.alice))[0], 200)
        self.assertEqual((await self.call('GET', f'{SESSIONS}/{sid}', self.alice))[0], 404)
        await self.until(lambda: not self.hm.is_live(host), 'its server to stop')

    # bug: session_one checks no token: anyone can delete any lobby (which stops its game server, mid-match too) or
    # change it, see report
    @unittest.expectedFailure
    async def test_only_the_owner_can_delete_a_lobby(self):
        host = self.ready_host(17777)
        sid = (await self.new_lobby(self.alice))['session_id']
        await self.server_for(self.alice, sid)
        for token in (None, self.bob):
            status, _ = await self.call('DELETE', f'{SESSIONS}/{sid}', token)
            self.assertIn(status, (401, 403))
        self.assertEqual((self.app['sessions'][sid]['_host'], self.hm.is_live(host)), (host, True))

    async def test_zeuz_lobby_owner_comes_from_the_login_and_an_unjoined_server_is_reused(self):
        # The Aug 2022 client's custom lobbies (FangsBoot makes these calls with "secret-token:accelbyte/<token>").
        host = self.ready_host(17777)

        def auth(t):
            return {'Authorization': f"Bearer secret-token:accelbyte/{t['access_token']}"}
        config = {'session_config': 'max_players,4,lobby_name,fun,lobby_owner,bob,map_name,Crownwatch,map_level,LE_Crownwatch'}
        status, made = await self.call('POST', '/zeuz/sessions', headers=auth(self.alice), json=config)
        self.assertEqual((status, made['address'], made['ports']), (200, '127.0.0.1', [{'port': 17777}]))
        _, listing = await self.call('GET', '/zeuz/sessions.txt', headers=auth(self.bob))
        self.assertEqual(listing, f"{made['id']}\t127.0.0.1:17777\tfun\talice\tCrownwatch\tLE_Crownwatch\t0\t4")
        _, again = await self.call('POST', '/zeuz/sessions', headers=auth(self.alice), json=config)   # Create clicked twice
        self.assertEqual((again['ports'], self.hm.is_live(host)), ([{'port': 17777}], True))
        _, listing = await self.call('GET', '/zeuz/sessions.txt', headers=auth(self.bob))
        self.assertEqual([line.split('\t')[0] for line in listing.splitlines()], [again['id']])
        self.set_status(host, players=4)                      # full: not listed
        self.assertEqual((await self.call('GET', '/zeuz/sessions.txt', headers=auth(self.bob)))[1], '')


# ---------------------------------------------------------------- lobby websocket: protocol and who is online

class LobbySocket(ApiCase):
    async def text(self, path, token=None):
        status, body = await self.call('GET', path, token)
        self.assertEqual(status, 200)
        return body

    async def test_lobby_acks_every_request_and_skips_pings(self):
        ws = await self.lobby(await self.login('alice'))
        self.assertEqual(ws.protocol, 'wss')                  # the game needs it (docs/STATUS.md, gotchas)
        await ws.send_str('')                                 # the SDK's ping
        await ws.send_str(fb.lobby_frame(type='joinDefaultChannelRequest', id='9'))
        self.assertEqual(parse(await ws.receive_str()), {'type': 'joinDefaultChannelResponse', 'id': '9', 'code': '0'})
        await ws.close()

    async def test_lobby_connection_counts_a_player_online_until_a_minute_after_it_closes(self):
        alice, bob = await self.login('alice'), await self.login('bob')
        self.app['store'].data['game_records']['CENameStyles'] = {'alice': 'rainbow'}
        ws = await self.lobby(alice)
        self.assertEqual(await self.text(f'{API}/online-players'), '1')
        # "<online>\t<free game servers>\t<game servers>", then the online names, for players only
        self.assertEqual(await self.text(f'{API}/server-status'), '1\t2\t2\n')
        self.assertEqual(await self.text(f'{API}/server-status', bob), '1\t2\t2\nalice\n')
        self.assertEqual(await self.text(f'{API}/server-status?v=2', bob), '1\t2\t2\nalice\trainbow\n')
        again = await self.lobby(alice)                       # the same player again: the old connection is closed
        self.assertIn((await ws.receive()).type, (WSMsgType.CLOSE, WSMsgType.CLOSED))
        self.assertEqual(await self.text(f'{API}/online-players'), '1')
        await again.close()
        await self.until(lambda: alice['user_id'] not in self.app['lobby_users'], 'the backend to see the close')
        self.assertEqual(await self.text(f'{API}/online-players'), '1')   # a minute's grace: map changes reconnect
        self.app['lobby_left'][alice['user_id']] -= 61
        self.assertEqual(await self.text(f'{API}/online-players'), '0')

    async def test_service_accounts_are_not_counted_online(self):
        bob = await self.login('bob')
        ws = await self.lobby(await self.login('smoketest'))    # server/deploy.sh's smoke test logs in like a player
        self.assertEqual(await self.text(f'{API}/online-players'), '0')
        self.assertEqual(await self.text(f'{API}/server-status', bob), '0\t2\t2\n')
        await ws.close()


# ---------------------------------------------------------------- downloads

class Downloads(ApiCase):
    """The player package behind the join code: /download/<code>/<file> (launcher, client zip) and the launcher's
    /download/<code>/files/<path> (paths listed in manifest.json, from <downloads>/overlay or else the game install)."""
    extra_args = ('--join-code', CODE)

    async def asyncSetUp(self):
        await super().asyncSetUp()
        dl, game = self.tmp / 'downloads', self.tmp / 'game'
        for path, text in ((dl / 'FangsCE.exe', 'launcher'), (dl / 'overlay' / 'FangsCE' / 'Engine.ini', 'ini'),
                           (dl / 'overlay' / 'unlisted.txt', 'unlisted'), (game / 'MOBA' / 'game.pak', '0123456789'),
                           (self.tmp / 'private.txt', 'private')):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        (dl / 'overlay' / 'link.txt').symlink_to(self.tmp / 'private.txt')
        # the last three are listed by mistake and lead outside both roots: never served all the same
        listed = ['FangsCE/Engine.ini', 'MOBA/game.pak', 'link.txt', '../private.txt', str(self.tmp / 'private.txt')]
        (dl / 'manifest.json').write_text(json.dumps({'files': [{'path': p} for p in listed]}))
        self.app['cfg'].downloads = str(dl)   # only known once the temp dir exists
        fb._manifest_cache.clear()

    async def raw_get(self, path):
        """A GET of `path` sent byte for byte (an HTTP client would normalize '..' and %2E): (status, body)."""
        reader, writer = await asyncio.open_connection(self.server.host, self.server.port, local_addr=('127.0.0.2', 0))
        writer.write(f'GET {path} HTTP/1.1\r\nHost: test\r\nConnection: close\r\n\r\n'.encode())
        head, _, body = (await reader.read()).partition(b'\r\n\r\n')
        writer.close()
        await writer.wait_closed()
        return int(head.split()[1]), body.decode(errors='replace')

    async def test_player_package_is_served_behind_the_join_code(self):
        async with self.client.get(f'/download/{CODE}/FangsCE.exe') as r:
            self.assertEqual((r.status, await r.text()), (200, 'launcher'))
            self.assertEqual(r.headers['Content-Disposition'], 'attachment; filename="FangsCE.exe"')
        self.assertEqual(await self.call('GET', f'/download/{CODE}/files/FangsCE/Engine.ini'), (200, 'ini'))   # overlay
        async with self.client.get(f'/download/{CODE}/files/MOBA/game.pak', headers={'Range': 'bytes=6-'}) as r:
            self.assertEqual((r.status, await r.text()), (206, '6789'))   # from the game install; resumable

    async def test_wrong_or_no_join_code_serves_nothing(self):
        for path in ('/download/wrong/FangsCE.exe', '/download/wrong/files/MOBA/game.pak'):
            self.assertEqual((await self.call('GET', path))[0], 404, path)
        self.app['cfg'].join_code = ''                       # a server without a join code serves no downloads
        self.assertEqual((await self.call('GET', f'/download/{CODE}/FangsCE.exe'))[0], 404)

    async def test_paths_outside_the_package_are_refused(self):
        private = str(self.tmp / 'private.txt')
        for path in (f'/download/{CODE}/files/unlisted.txt',          # in the overlay but not in the manifest
                     f'/download/{CODE}/files/link.txt',              # listed, a symlink to a file outside
                     f'/download/{CODE}/files/../private.txt',
                     f'/download/{CODE}/files/%2E%2E/private.txt',
                     f'/download/{CODE}/files/..%2Fprivate.txt',
                     f'/download/{CODE}/files/{private}',              # absolute (".../files//tmp/...")
                     f'/download/{CODE}/files/%2F{private[1:]}',
                     f'/download/{CODE}/..', f'/download/{CODE}/%2E%2E', f'/download/{CODE}/%2E%2E/private.txt'):
            with self.subTest(path=path):
                status, body = await self.raw_get(path)
                self.assertEqual(status, 404)
                self.assertNotIn('private', body)


# ---------------------------------------------------------------- routing

class Routing(ApiCase):
    async def test_unknown_route_is_a_json_404_logged_as_unhandled(self):
        for method, path in (('GET', '/nothing/here'), ('GET', '/iam/v3/oauth/token')):   # a known path, other method
            with self.subTest(method=method, path=path):
                status, body = await self.call(method, path)
                self.assertEqual((status, body['errorCode'], body['errorMessage']),
                                 (404, 404, 'not implemented by fangs backend'))
                self.assertEqual({k: self.logs[-1].get(k) for k in ('path', 'status', 'unhandled')},
                                 {'path': path, 'status': 404, 'unhandled': True})

    async def test_aug_2022_fangsapi_paths_without_separator_or_stage_are_rewritten(self):
        # some Aug 2022 Blueprints join FANGSApiBaseURL and the route directly: "/fangsapiget-epoc"
        for path in ('/fangsapiget-epoc', '/fangsapi/prod/get-epoc', '/fangsapi/dev/get-epoc'):
            status, body = await self.call('GET', path)
            self.assertEqual(status, 200, path)
            self.assertAlmostEqual(body['timestamp'], time.time(), delta=5)
        self.assertEqual(await self.call('GET', '/fangsapionline-players'), (200, '0'))

    # bug: request bodies are parsed unguarded: malformed JSON or a missing field is a 500 (with a traceback, and no
    # entry in the backend's log) instead of a 400, see report
    @unittest.expectedFailure
    async def test_malformed_bodies_get_a_400(self):
        alice = await self.login('alice')
        with mock.patch.object(logging.getLogger('aiohttp.server'), 'disabled', True):   # keep the tracebacks quiet
            for method, path, kw in (('POST', SESSIONS, {'data': 'not json'}),
                                     ('PUT', rec(alice['user_id'], 'Justice'), {'data': 'not json'}),
                                     ('POST', f'{API}/update-player-record-key', {'json': {'Key': 'k'}})):
                with self.subTest(method=method, path=path):
                    self.assertEqual((await self.call(method, path, alice, **kw))[0], 400)


# ---------------------------------------------------------------- match results

class MatchResults(ApiCase):
    """A finished match reaches the backend as FangsHost's fangshost_result-*.json next to its game server; the
    HostManager hands it to make_app's on_result (ingest_match)."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.alice, self.bob = await self.login('alice'), await self.login('bob')
        self.a, self.b = self.alice['user_id'], self.bob['user_id']
        # a win's 72 XP is exactly one level: account levels need more than that, hero levels as much
        self.app['store'].data['game_records']['CELevels'] = {'Account': [72, 100], 'Hero': [72, 100]}
        self.host = self.ready_host(17777)
        self.host.session_id = 'custom-lobby'

    def finish(self):
        """FangsHost saves the result; the HostManager picks it up (its watcher does so every 2 s)."""
        rows = [{'UserId': self.a, 'Team': 'TeamA', 'Type': 'Berserker'}, {'UserId': self.b, 'Team': 'TeamB', 'Type': 'FireMage'},
                {'UserId': '', 'Team': 'TeamA', 'Type': 'Scythe'}]   # no account (a bot)
        result = {'results': {'MatchResults': [{'RoundResults': rows, 'TotalRoundTime': 412.5}],
                              'TimePlayed': '2026.10.15-20.00.00', 'MapLevel': 'LE_Crownwatch'},
                  'winning_team': 1, 'game_mode': 4, 'match_time': 600, 'rounds_a': 3, 'rounds_b': 1}
        (self.host.inst / 'MOBA' / 'Binaries' / 'Win64' / 'fangshost_result-1.json').write_text(json.dumps(result))
        self.app['hosts'].collect_results(self.host)
        return result

    async def record(self, owner, key, viewer=None):
        status, resp = await self.call('GET', rec(owner['user_id'], key), viewer or owner)
        self.assertEqual(status, 200, resp)
        return resp['value']

    async def test_a_result_updates_history_levels_and_wins(self):
        ratings = await self.record(self.alice, 'PROFILE_RATINGS_KEY')
        self.finish()
        entry = self.logs[-1]
        self.assertEqual({k: v for k, v in entry.items() if k != 'match'},
                         {'mode': 4, 'map': 'LE_Crownwatch', 'winner': 'TeamA', 'players': {'alice': 'TeamA', 'bob': 'TeamB'}})
        # 600 s played: a win is 72 XP, a loss 59 (BP_AC_MatchReport's rates)
        self.assertEqual(await self.record(self.alice, 'PROFILE_MASTERY_KEY'),
                         {'Level': 1, 'XPToNext': 72, 'MatchesPlayed': 1, 'MatchesWon': 1, 'RoundsWon': 3,
                          'Berserker': {'Level': 2, 'XPToNext': 0, 'MatchesPlayed': 1, 'MatchesWon': 1}})
        self.assertEqual(await self.record(self.bob, 'PROFILE_MASTERY_KEY'),
                         {'Level': 1, 'XPToNext': 59, 'MatchesPlayed': 1, 'MatchesWon': 0, 'RoundsWon': 1,
                          'FireMage': {'Level': 1, 'XPToNext': 59, 'MatchesPlayed': 1, 'MatchesWon': 0}})
        history = await self.record(self.alice, 'PROFILE_HISTORY_KEY')
        self.assertEqual(len(history['Matches']), 1)
        rows = history['Matches'][0]['MatchResults'][0]['RoundResults']
        self.assertEqual([(r['UserId'], r.get('Name')) for r in rows], [(self.a, 'alice'), (self.b, 'bob'), ('', None)])
        # bob looking at alice's matches sees her rows as his own (the client finds the viewer's id), his under none
        seen = await self.record(self.alice, 'PROFILE_HISTORY_KEY', viewer=self.bob)
        self.assertEqual([r['UserId'] for r in seen['Matches'][0]['MatchResults'][0]['RoundResults']], [self.b, '', ''])
        self.assertEqual(await self.record(self.alice, 'PROFILE_RATINGS_KEY'), ratings)   # custom games are unrated
        self.assertIsNotNone(self.host.match_over)           # its lobby is no longer listed or joinable

    async def test_the_same_result_twice_counts_once(self):
        result = self.finish()
        self.finish()                                        # e.g. saved again by FangsHost
        self.assertEqual(self.logs[-1]['skipped'], 'duplicate')
        self.assertEqual((await self.record(self.alice, 'PROFILE_MASTERY_KEY'))['MatchesPlayed'], 1)
        self.assertEqual(len((await self.record(self.alice, 'PROFILE_HISTORY_KEY'))['Matches']), 1)
        # the matches seen (the last 200) are stored, so this holds across a backend restart too
        log = []
        fb.ingest_match(fb.Store(self.tmp / 'store.json'), result, log.append)
        self.assertEqual(log[-1]['skipped'], 'duplicate')


if __name__ == '__main__':
    unittest.main(verbosity=2)
