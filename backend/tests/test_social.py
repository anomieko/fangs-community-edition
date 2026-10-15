"""Friends, presence, parties and chat (backend/social.py) through the real backend's lobby websocket
(support.BackendCase): AccelByte "key: value" frames as the Feb 2023 client sends them; Races drives Social directly
with fake connections, for interleavings a real socket can't force. Characterization tests: they pin what the backend
does today; an @expectedFailure test states the correct behavior where today's is wrong.

    python -I -m unittest discover -s backend/tests -p test_social.py -v
"""
import asyncio
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from aiohttp import WSMsgType
from aiohttp.test_utils import TestClient, TestServer

sys.path.insert(0, str(Path(__file__).resolve().parent))   # support.py, also when run as a script
import support
import fangs_backend as fb
import social

ZWSP = '\u200b'


def parse(text):
    return dict(line.split(': ', 1) for line in text.split('\n') if ': ' in line)


def ids(value):
    """A frame's list value (["a","b"])."""
    return json.loads(value)


class Lobby:
    """One player's lobby connection. Frames that don't answer this client's own requests collect in `inbox`."""

    def __init__(self, name, token, ws):
        self.name, self.token, self.uid, self.ws = name, token, token['user_id'], ws
        self.inbox, self._n = [], 0

    async def send(self, type_, **fields):
        self._n += 1
        await self.ws.send_str('\n'.join([f'type: {type_}', f'id: {self._n}', *(f'{k}: {v}' for k, v in fields.items())]))
        return str(self._n)

    async def request(self, type_, **fields):
        """Sends a *Request and returns its *Response (the server answers one frame at a time, in order)."""
        mid, want = await self.send(type_, **fields), type_.removesuffix('Request') + 'Response'
        while (f := await self.recv())['type'] != want or f.get('id') != mid:
            self.inbox.append(f)
        return f

    async def recv(self):
        msg = await self.ws.receive(timeout=5)
        if msg.type != WSMsgType.TEXT:
            raise AssertionError(f'{self.name}: {msg}')
        return parse(msg.data)

    async def sync(self):
        """Round trip: the server has handled everything this client sent, and every frame it sent this client
        before that is in the inbox."""
        await self.request('listOfFriendsRequest')

    def take(self, type_=None):
        """The collected frames (only those of `type_`), removed from the inbox."""
        got = [f for f in self.inbox if type_ in (None, f['type'])]
        self.inbox = [f for f in self.inbox if f not in got]
        return got


class LobbyCase(support.BackendCase):
    """BackendCase with players on the lobby websocket (also used by test_matchmaker.py)."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.social = self.app['social']

    async def connect(self, name):
        token = await self.login(name)
        ws = await self.client.ws_connect('/lobby/', protocols=('wss',), headers=self.auth(token))
        lobby = Lobby(name, token, ws)
        self.assertEqual((await lobby.recv())['type'], 'connectNotif')
        await lobby.sync()   # social.connect has run
        return lobby

    async def settle(self, *lobbies):
        """Let the first client's requests finish (with what they send others), then collect the others' frames."""
        for lobby in lobbies:
            await lobby.sync()

    async def until(self, cond, seconds=5):
        async with asyncio.timeout(seconds):
            while not cond():   # noqa: ASYNC110 - backend state that has no event to wait for
                await asyncio.sleep(0.01)

    async def befriend(self, a, *others):
        for b in others:
            await a.request('requestFriendsRequest', friendId=b.uid)
            await b.request('acceptFriendsRequest', friendId=a.uid)
            await self.settle(a, b)
            a.take(), b.take()

    async def make_party(self, leader, *members):
        """leader's party with `members` (friends of the leader) joined; returns (party id, invitation token)."""
        r = await leader.request('partyCreateRequest')
        pid, token = r['partyID'], r['invitationToken']
        for m in members:
            await leader.request('partyInviteRequest', friendID=m.uid)
            await m.request('partyJoinRequest', partyID=pid, invitationToken=token)
        await self.settle(leader, *members)
        for x in (leader, *members):
            x.take()
        return pid, token

    async def drop(self, lobby):
        """Close a player's lobby connection and wait until the backend noticed."""
        await lobby.ws.close()
        await self.until(lambda: (c := self.social.conns.get(lobby.uid)) is None or c.ws is None)


class Friends(LobbyCase):
    async def test_request_and_accept_make_friends_both_ways(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        self.assertEqual((await a.request('requestFriendsRequest', friendId=b.uid))['code'], '0')
        await self.settle(a, b)
        self.assertEqual([(f['type'], f['friendId']) for f in b.take()], [('requestFriendsNotif', a.uid)])
        self.assertEqual(ids((await a.request('listOutgoingFriendsRequest'))['friendsId']), [b.uid])
        self.assertEqual(ids((await b.request('listIncomingFriendsRequest'))['friendsId']), [a.uid])
        self.assertEqual((await a.request('getFriendshipStatusRequest', friendId=b.uid))['friendshipStatus'], '1')
        self.assertEqual((await b.request('getFriendshipStatusRequest', friendId=a.uid))['friendshipStatus'], '2')

        self.assertEqual((await b.request('acceptFriendsRequest', friendId=a.uid))['code'], '0')
        await self.settle(b, a)
        self.assertEqual([(f['type'], f.get('friendId'), f.get('userID'), f.get('availability')) for f in a.take()],
                         [('acceptFriendsNotif', b.uid, None, None), ('userStatusNotif', None, b.uid, 'online')])
        self.assertEqual([(f['type'], f['userID'], f['availability']) for f in b.take()], [('userStatusNotif', a.uid, 'online')])
        for x, y in ((a, b), (b, a)):
            self.assertEqual(ids((await x.request('listOfFriendsRequest'))['friendsId']), [y.uid])
            self.assertEqual((await x.request('getFriendshipStatusRequest', friendId=y.uid))['friendshipStatus'], '3')
            self.assertEqual(ids((await x.request('listIncomingFriendsRequest'))['friendsId']), [])

    async def test_reject_and_cancel_withdraw_a_request(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await a.request('requestFriendsRequest', friendId=b.uid)
        self.assertEqual((await b.request('rejectFriendsRequest', friendId=a.uid))['code'], '0')
        await self.settle(b, a)
        self.assertEqual([(f['type'], f['userId']) for f in a.take()], [('rejectFriendsNotif', b.uid)])
        self.assertEqual(ids((await b.request('listIncomingFriendsRequest'))['friendsId']), [])

        await a.request('requestFriendsRequest', friendId=b.uid)
        await self.settle(a, b)
        b.take()
        self.assertEqual((await a.request('cancelFriendsRequest', friendId=b.uid))['code'], '0')
        await self.settle(a, b)
        self.assertEqual([(f['type'], f['userId']) for f in b.take()], [('cancelFriendsNotif', a.uid)])
        self.assertEqual(ids((await b.request('listIncomingFriendsRequest'))['friendsId']), [])
        self.assertEqual(ids((await a.request('listOfFriendsRequest'))['friendsId']), [])

        # nothing to reject or cancel: still a success, and nobody is told
        self.assertEqual((await b.request('rejectFriendsRequest', friendId=a.uid))['code'], '0')
        self.assertEqual((await a.request('cancelFriendsRequest', friendId=b.uid))['code'], '0')
        await self.settle(a, b, a)
        self.assertEqual((a.take(), b.take()), ([], []))

    async def test_unfriend_removes_both_directions(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        self.assertEqual((await a.request('unfriendRequest', friendId=b.uid))['code'], '0')
        await self.settle(a, b)
        self.assertEqual([(f['type'], f['friendId']) for f in b.take()], [('unfriendNotif', a.uid)])
        for x, y in ((a, b), (b, a)):
            self.assertEqual(ids((await x.request('listOfFriendsRequest'))['friendsId']), [])
            self.assertEqual((await x.request('getFriendshipStatusRequest', friendId=y.uid))['friendshipStatus'], '0')
        await a.request('setUserStatusRequest', availability='busy', activity='')
        await self.settle(a, b)
        self.assertEqual(b.take(), [])          # no presence for former friends

    async def test_mutual_requests_make_friends_at_once(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await a.request('requestFriendsRequest', friendId=b.uid)
        await self.settle(a, b)
        b.take()
        self.assertEqual((await b.request('requestFriendsRequest', friendId=a.uid))['code'], '0')   # "that's a yes"
        await self.settle(b, a)
        self.assertEqual([f['type'] for f in a.take()], ['acceptFriendsNotif', 'userStatusNotif'])
        # b's own client sent a request, not an accept: it is told too, or it would keep listing a request
        self.assertEqual([(f['type'], f.get('friendId')) for f in b.take()],
                         [('userStatusNotif', None), ('acceptFriendsNotif', a.uid)])
        for x, y in ((a, b), (b, a)):
            self.assertEqual(ids((await x.request('listOfFriendsRequest'))['friendsId']), [y.uid])
            self.assertEqual(ids((await x.request('listIncomingFriendsRequest'))['friendsId']), [])
        # the stale accept and a repeated request between friends: success, nothing sent
        self.assertEqual((await a.request('acceptFriendsRequest', friendId=b.uid))['code'], '0')
        self.assertEqual((await a.request('requestFriendsRequest', friendId=b.uid))['code'], '0')
        await self.settle(a, b)
        self.assertEqual((a.take(), b.take()), ([], []))
        self.assertEqual(self.social.friends[a.uid], [b.uid])

    async def test_requests_to_yourself_or_unknown_ids_are_refused(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        for other in (a.uid, 'f' * 32, ''):
            self.assertEqual((await a.request('requestFriendsRequest', friendId=other))['code'], str(social.ERR_FRIEND))
        self.assertEqual((await a.request('acceptFriendsRequest', friendId=b.uid))['code'], str(social.ERR_FRIEND))
        await a.request('requestFriendsRequest', friendId=b.uid)
        await a.request('requestFriendsRequest', friendId=b.uid)
        self.assertEqual(self.social.requests, {b.uid: [a.uid]})   # stored once
        self.assertEqual(self.social.friends, {})

    async def test_friends_and_requests_survive_a_restart(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b)
        await c.request('requestFriendsRequest', friendId=a.uid)
        restarted = TestClient(TestServer(fb.make_app(support.backend_args(self.tmp), self.logs.append), host='127.0.0.1'))
        await restarted.start_server()
        try:
            r = await restarted.post('/iam/v3/oauth/token',
                                     data={'grant_type': 'password', 'username': 'ann', 'password': 'secret'})
            token = await r.json()
            lobby = Lobby('ann', token, await restarted.ws_connect('/lobby/', protocols=('wss',), headers=self.auth(token)))
            await lobby.recv()
            self.assertEqual(ids((await lobby.request('listOfFriendsRequest'))['friendsId']), [b.uid])
            self.assertEqual(ids((await lobby.request('listIncomingFriendsRequest'))['friendsId']), [c.uid])
        finally:
            await restarted.close()


class Presence(LobbyCase):
    async def test_status_changes_reach_friends_only(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b)
        self.assertEqual((await a.request('setUserStatusRequest', availability='busy', activity='In a match'))['code'], '0')
        await self.settle(a, b, c)
        self.assertEqual([(f['type'], f['userID'], f['availability'], f['activity']) for f in b.take()],
                         [('userStatusNotif', a.uid, 'busy', 'In a match')])
        self.assertEqual(c.take(), [])
        # an unknown availability reads as online; the activity is cut to 64 characters
        await a.request('setUserStatusRequest', availability='away', activity='x' * 100)
        r = await b.request('friendsStatusRequest')
        self.assertEqual((ids(r['friendsId']), ids(r['availability']), ids(r['activity'])), ([a.uid], ['online'], ['x' * 64]))

    async def test_within_the_grace_period_a_dropped_player_still_shows_online(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        await self.drop(b)
        r = await a.request('friendsStatusRequest')
        self.assertEqual(ids(r['availability']), ['online'])   # the game reconnects after map changes
        self.assertEqual(a.take(), [])
        self.assertFalse(self.social.conns[b.uid].grace.done())

    async def test_after_the_grace_period_friends_see_the_player_offline(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b)
        with mock.patch.object(social, 'GRACE', 0):
            await self.drop(b)
            await self.until(lambda: b.uid not in self.social.conns)
        await self.settle(a, c)
        self.assertEqual([(f['type'], f['userID'], f['availability']) for f in a.take()], [('userStatusNotif', b.uid, 'offline')])
        self.assertEqual(c.take(), [])
        self.assertEqual(ids((await a.request('friendsStatusRequest'))['availability']), ['offline'])

    async def test_coming_back_online_is_announced_by_the_players_status_request(self):
        # Question (see report): connecting alone tells friends nothing; the client's setUserStatusRequest does
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        with mock.patch.object(social, 'GRACE', 0):
            await self.drop(b)
            await self.until(lambda: b.uid not in self.social.conns)
        await self.settle(a)
        a.take()
        b = await self.connect('ben')
        await self.settle(b, a)
        self.assertEqual(a.take(), [])
        self.assertEqual(ids((await a.request('friendsStatusRequest'))['availability']), ['online'])
        await b.request('setUserStatusRequest', availability='online', activity='')
        await self.settle(b, a)
        self.assertEqual([(f['type'], f['availability']) for f in a.take()], [('userStatusNotif', 'online')])

    async def test_reconnecting_within_the_grace_period_keeps_the_party(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        pid, _ = await self.make_party(a, b)
        await self.drop(b)
        grace = self.social.conns[b.uid].grace
        await self.settle(a)
        self.assertEqual([(f['type'], f['userId']) for f in a.take()], [('partyDisconnectNotif', b.uid)])
        b = await self.connect('ben')
        await self.settle(b, a)
        self.assertEqual([(f['type'], f['userId'], f['partyId']) for f in a.take()], [('partyConnectNotif', b.uid, pid)])
        self.assertTrue(grace.done())                     # the pending drop is called off
        self.assertIsNone(self.social.conns[b.uid].grace)
        self.assertEqual(ids((await b.request('partyInfoRequest'))['members']), [a.uid, b.uid])

    async def test_a_second_connection_replaces_the_first(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        await self.make_party(a, b)
        b2 = await self.connect('ben')
        self.assertEqual((await b.ws.receive(timeout=5)).type, WSMsgType.CLOSE)   # the backend closed the old one
        self.assertTrue(any(e.get('event') == 'replaced connection' for e in self.logs))
        await self.settle(b2, a)
        self.assertTrue(self.social.online(b.uid))
        self.assertIsNone(self.social.conns[b.uid].grace)       # the old connection's close starts no drop
        self.assertEqual(ids((await b2.request('partyInfoRequest'))['members']), [a.uid, b.uid])
        self.assertNotIn('userStatusNotif', [f['type'] for f in a.take()])

    async def test_party_mates_last_hear_that_a_replaced_player_is_connected(self):
        # the new connection takes over before the old one closes, so no partyDisconnectNotif lands after it (review P2)
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        await self.make_party(a, b)
        b2 = await self.connect('ben')
        await self.settle(b2, a)
        got = [f['type'] for f in a.take() if f['type'] in ('partyConnectNotif', 'partyDisconnectNotif')]
        self.assertNotEqual(got[-1:], ['partyDisconnectNotif'], got)

    async def test_after_the_grace_period_a_player_leaves_their_party_and_invites(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b, c)
        await self.make_party(a, b)
        await a.request('partyInviteRequest', friendID=c.uid)
        await self.settle(a)
        a.take()
        with mock.patch.object(social, 'GRACE', 0):
            await self.drop(b)
            await self.drop(c)
            await self.until(lambda: b.uid not in self.social.conns and c.uid not in self.social.conns)
        await self.settle(a)
        got = a.take()
        self.assertIn(('partyLeaveNotif', b.uid, a.uid), [(f['type'], f.get('userID'), f.get('leaderID')) for f in got])
        update = [f for f in got if f['type'] == 'partyDataUpdateNotif'][-1]
        self.assertEqual((ids(update['members']), ids(update['invitees'])), ([a.uid], []))
        self.assertIsNone(self.social.party_id(b.uid))


class Parties(LobbyCase):
    async def test_create_invite_and_join(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        r = await a.request('partyCreateRequest')
        self.assertEqual((r['code'], r['leaderID'], ids(r['members']), ids(r['invitees'])), ('0', a.uid, [a.uid], []))
        pid, token = r['partyID'], r['invitationToken']

        r = await a.request('partyInviteRequest', friendID=b.uid)
        self.assertEqual((r['code'], r['inviteeID']), ('0', b.uid))
        await self.settle(a, b)
        self.assertEqual([(f['type'], f['from'], f['partyID'], f['invitationToken']) for f in b.take()],
                         [('partyGetInvitedNotif', a.uid, pid, token)])
        got = a.take()
        self.assertEqual([(f['inviterID'], f['inviteeID']) for f in got if f['type'] == 'partyInviteNotif'], [(a.uid, b.uid)])
        self.assertEqual([ids(f['invitees']) for f in got if f['type'] == 'partyDataUpdateNotif'], [[b.uid]])

        r = await b.request('partyJoinRequest', partyID=pid, invitationToken=token)
        self.assertEqual((r['code'], r['partyID'], ids(r['members']), ids(r['invitees'])), ('0', pid, [a.uid, b.uid], []))
        await self.settle(b, a)
        self.assertEqual([(f['type'], f.get('userId')) for f in a.take()],
                         [('partyJoinNotif', b.uid), ('partyDataUpdateNotif', None)])
        self.assertEqual([(f['type'], ids(f['members'])) for f in b.take()], [('partyDataUpdateNotif', [a.uid, b.uid])])
        r = await b.request('partyInfoRequest')
        self.assertEqual((r['partyID'], r['leaderID'], ids(r['members'])), (pid, a.uid, [a.uid, b.uid]))

    async def test_invites_go_only_to_online_friends_outside_a_party(self):
        a, b, c, d, e = [await self.connect(n) for n in ('ann', 'ben', 'cat', 'dan', 'eve')]
        await self.befriend(a, b, c, d)
        await a.request('partyCreateRequest')
        await b.request('partyCreateRequest')                      # b is in a party of their own
        await self.drop(d)                                         # d is offline (even within the grace period)
        cant = str(social.ERR_CANT_INVITE)
        for who in (a, b, d, e):                                   # self, in a party, offline, not a friend
            self.assertEqual((await a.request('partyInviteRequest', friendID=who.uid))['code'], cant, who.name)
        self.assertEqual((await a.request('partyInviteRequest', friendID=c.uid))['code'], '0')
        self.assertEqual((await a.request('partyInviteRequest', friendID=c.uid))['code'], '0')   # the client sends each twice
        await self.settle(a, c, e)
        self.assertEqual([f['type'] for f in c.take()], ['partyGetInvitedNotif'])                # one invite
        self.assertEqual(e.take(), [])

    async def test_a_party_holds_four_with_its_invitees(self):
        a, b, c, d, e = [await self.connect(n) for n in ('ann', 'ben', 'cat', 'dan', 'eve')]
        await self.befriend(a, b, c, d, e)
        await self.make_party(a, b)
        for who in (c, d):
            self.assertEqual((await a.request('partyInviteRequest', friendID=who.uid))['code'], '0')
        self.assertEqual((await a.request('partyInviteRequest', friendID=e.uid))['code'], str(social.ERR_CANT_INVITE))
        await c.request('partyRejectRequest', partyID=self.social.party_id(a.uid))
        self.assertEqual((await a.request('partyInviteRequest', friendID=e.uid))['code'], '0')   # c's slot is free again

    async def test_joining_needs_an_invite_and_its_token(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b)
        r = await a.request('partyCreateRequest')
        pid, token = r['partyID'], r['invitationToken']
        bad = str(social.ERR_BAD_INVITE)
        self.assertEqual((await c.request('partyJoinRequest', partyID=pid, invitationToken=token))['code'], bad)   # not invited
        await a.request('partyInviteRequest', friendID=b.uid)
        self.assertEqual((await b.request('partyJoinRequest', partyID=pid, invitationToken='x' * 32))['code'], bad)
        self.assertEqual((await b.request('partyJoinRequest', partyID='x' * 32, invitationToken=token))['code'], bad)
        self.assertEqual((await b.request('partyJoinRequest', partyID=pid, invitationToken=token))['code'], '0')
        r = await b.request('partyJoinRequest', partyID=pid, invitationToken=token)   # an invite accepted twice
        self.assertEqual((r['code'], ids(r['members'])), ('0', [a.uid, b.uid]))

    async def test_declining_an_invite_tells_the_leader(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        pid = (await a.request('partyCreateRequest'))['partyID']
        await a.request('partyInviteRequest', friendID=b.uid)
        await self.settle(a)
        a.take()
        r = await b.request('partyRejectRequest', partyID=pid)
        self.assertEqual((r['code'], r['partyID']), ('0', pid))
        await self.settle(b, a)
        got = a.take()
        self.assertEqual([(f['type'], f.get('userID')) for f in got],
                         [('partyRejectNotif', b.uid), ('partyDataUpdateNotif', None)])
        self.assertEqual(ids(got[1]['invitees']), [])
        r = await b.request('partyJoinRequest', partyID=pid, invitationToken=self.social.parties[pid].token)
        self.assertEqual(r['code'], str(social.ERR_BAD_INVITE))      # the invite is gone

    async def test_only_the_leader_kicks(self):
        a, b, c, d = [await self.connect(n) for n in ('ann', 'ben', 'cat', 'dan')]
        await self.befriend(a, b, c, d)
        pid, _ = await self.make_party(a, b, c)
        not_leader = str(social.ERR_NOT_LEADER)
        self.assertEqual((await b.request('partyKickRequest', memberID=c.uid))['code'], not_leader)
        self.assertEqual((await a.request('partyKickRequest', memberID=a.uid))['code'], not_leader)
        self.assertEqual((await a.request('partyKickRequest', memberID=d.uid))['code'], not_leader)   # not a member
        r = await a.request('partyKickRequest', memberID=c.uid)
        self.assertEqual((r['code'], r['userId']), ('0', c.uid))
        await self.settle(a, b, c)
        for x in (a, b, c):   # the kicked player is told too
            self.assertEqual([(f['userID'], f['partyId']) for f in x.take('partyKickNotif')], [(c.uid, pid)], x.name)
        self.assertEqual([ids(f['members']) for f in b.take('partyDataUpdateNotif')], [[a.uid, b.uid]])
        self.assertEqual((await c.request('partyInfoRequest'))['partyID'], '')
        self.assertEqual(c.take(), [])

    async def test_only_the_leader_promotes(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b, c)
        await self.make_party(a, b)
        not_leader = str(social.ERR_NOT_LEADER)
        self.assertEqual((await b.request('partyPromoteLeaderRequest', newLeaderUserId=b.uid))['code'], not_leader)
        self.assertEqual((await a.request('partyPromoteLeaderRequest', newLeaderUserId=c.uid))['code'], not_leader)
        r = await a.request('partyPromoteLeaderRequest', newLeaderUserId=b.uid)
        self.assertEqual((r['code'], r['leaderID'], ids(r['members'])), ('0', b.uid, [a.uid, b.uid]))
        await self.settle(a, b)
        self.assertEqual([f['leader'] for f in b.take('partyDataUpdateNotif')], [b.uid])
        self.assertEqual((await a.request('partyKickRequest', memberID=b.uid))['code'], not_leader)
        self.assertEqual((await b.request('partyKickRequest', memberID=a.uid))['code'], '0')

    async def test_the_leader_leaving_hands_the_party_to_the_next_member(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b, c)
        pid, _ = await self.make_party(a, b, c)
        self.assertEqual((await a.request('partyLeaveRequest'))['code'], '0')
        await self.settle(a, b, c)
        for x in (b, c):
            got = x.take()
            self.assertEqual([(f['userID'], f['leaderID'], f['partyId']) for f in got if f['type'] == 'partyLeaveNotif'],
                             [(a.uid, b.uid, pid)])
            self.assertEqual([(f['leader'], ids(f['members'])) for f in got if f['type'] == 'partyDataUpdateNotif'],
                             [(b.uid, [b.uid, c.uid])])
        self.assertEqual(a.take(), [])
        self.assertEqual((await a.request('partyInfoRequest'))['partyID'], '')
        self.assertEqual((await c.request('partyInfoRequest'))['leaderID'], b.uid)

    async def test_the_last_member_leaving_disbands_the_party(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        pid, _ = await self.make_party(a, b)
        await b.request('partyLeaveRequest')
        self.assertEqual(self.social.parties[pid].members, [a.uid])   # a party of one stays
        await a.request('partyLeaveRequest')
        self.assertEqual((self.social.parties, self.social.party_of), ({}, {}))
        self.assertIn({'ws': 'social', 'event': 'party disbanded', 'party': pid}, self.logs)
        self.assertEqual((await a.request('partyLeaveRequest'))['code'], '0')   # leaving no party is fine

    async def test_joining_another_party_leaves_the_first(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        await self.befriend(a, b)
        await self.befriend(c, b)
        r = await c.request('partyCreateRequest')
        second, token = r['partyID'], r['invitationToken']
        await c.request('partyInviteRequest', friendID=b.uid)   # before b is in a party: no invites to party members
        first, _ = await self.make_party(a, b)
        r = await b.request('partyJoinRequest', partyID=second, invitationToken=token)
        self.assertEqual(ids(r['members']), [c.uid, b.uid])
        await self.settle(b, a)
        self.assertEqual([(f['userID'], f['partyId']) for f in a.take('partyLeaveNotif')], [(b.uid, first)])
        self.assertEqual(self.social.parties[first].members, [a.uid])
        self.assertEqual(self.social.party_id(b.uid), second)

    async def test_one_party_at_a_time_and_an_invite_creates_one(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await self.befriend(a, b)
        await a.request('partyCreateRequest')
        self.assertEqual((await a.request('partyCreateRequest'))['code'], str(social.ERR_IN_PARTY))
        self.assertEqual((await b.request('partyInviteRequest', friendID=a.uid))['code'], str(social.ERR_CANT_INVITE))
        self.assertEqual(self.social.party(b.uid).leader, b.uid)   # the client normally creates one first


class Chat(LobbyCase):
    async def test_party_chat_reaches_the_other_members_only(self):
        a, b, c, d = [await self.connect(n) for n in ('ann', 'ben', 'cat', 'dan')]
        await self.befriend(a, b, c, d)
        pid, _ = await self.make_party(a, b, c)
        self.assertEqual((await a.request('partyChatRequest', payload='gl hf'))['code'], '0')
        await self.settle(a, b, c, d)
        for x in (b, c):
            self.assertEqual([(f['type'], f['from'], f['to'], f['payload']) for f in x.take()],
                             [('partyChatNotif', a.uid, pid, 'gl hf')])
        self.assertEqual((a.take(), d.take()), ([], []))
        self.assertEqual((await d.request('partyChatRequest', payload='hi'))['code'], str(social.ERR_NOT_IN_PARTY))

    async def test_whispers_reach_only_their_addressee(self):
        a, b, c = await self.connect('ann'), await self.connect('ben'), await self.connect('cat')
        self.assertEqual((await a.request('personalChatRequest', to=b.uid, payload='psst'))['code'], '0')   # no friendship needed
        await self.settle(a, b, c)
        self.assertEqual([(f['type'], f['from'], f['to'], f['payload']) for f in b.take()],
                         [('personalChatNotif', a.uid, b.uid, 'psst')])
        self.assertEqual((a.take(), c.take()), ([], []))
        await self.drop(c)
        offline = str(social.ERR_OFFLINE)
        for to in (a.uid, c.uid, 'f' * 32):   # yourself, offline, unknown
            self.assertEqual((await a.request('personalChatRequest', to=to, payload='psst'))['code'], offline)

    def test_chat_text_is_escaped_for_the_clients_frame_parser(self):
        cases = {'plain': 'plain', '  padded ': 'padded', 'two\nlines\r': 'two lines', 'C:\\dir': 'C:\\\\dir',
                 '[1,2]': ZWSP + '[1,2]', '{"a":1}': ZWSP + '{"a":1}', '"quoted"': ZWSP + '"quoted"' + ZWSP,
                 'x' * 600: 'x' * 500}
        self.assertEqual({s: social.chat_text(s) for s in cases}, cases)

    async def test_chat_text_arrives_escaped(self):
        a, b = await self.connect('ann'), await self.connect('ben')
        await a.request('personalChatRequest', to=b.uid, payload='[list] \\ "')
        await self.settle(a, b)
        self.assertEqual([f['payload'] for f in b.take()], [ZWSP + '[list] \\\\ "' + ZWSP])

    def test_a_line_cut_at_500_characters_keeps_its_escaping(self):
        # chat_text cuts before escaping, so a doubled backslash or the quote guard is never cut in half (review P3)
        cut = social.chat_text('a' * 499 + '\\')
        self.assertEqual((len(cut) - len(cut.rstrip('\\'))) % 2, 0, 'ends in half an escaped backslash')
        self.assertFalse(social.chat_text('a' * 499 + '"b').endswith('"'), 'the parser drops a trailing quote')

    async def test_a_lobby_chat_line_carries_no_party_command_in_any_case(self):
        # the receiving game's search for party commands ignores case, so the "Report" guard does too (review P3)
        a, c = await self.connect('ann'), await self.connect('cat')
        await a.send('signalingP2PNotif', destinationId=c.uid, message='/a reportLeaveQueueCommand')
        await self.settle(a, c)
        self.assertNotIn('report', c.take()[0]['message'].lower())

    async def test_signaling_goes_between_friends_and_party_mates_only(self):
        a, b, c, d, e = [await self.connect(n) for n in ('ann', 'ben', 'cat', 'dan', 'eve')]
        await self.befriend(a, b, d, e)
        await self.make_party(a, b, e)
        await a.request('partyInviteRequest', friendID=d.uid)
        msg = 'ReportDetailsann'   # party details: relayed as they are
        for frm, to in ((a, b), (e, b), (a, d), (a, c), (a, a)):   # friend, party mate, invitee; stranger, self
            await frm.send('signalingP2PNotif', destinationId=to.uid, message=msg)
            await self.settle(frm)
        await self.settle(b, c, d)
        self.assertEqual([(f['destinationId'], f['message']) for f in b.take('signalingP2PNotif')], [(a.uid, msg), (e.uid, msg)])
        self.assertEqual([(f['destinationId'], f['message']) for f in d.take('signalingP2PNotif')], [(a.uid, msg)])
        self.assertEqual((c.take(), a.take('signalingP2PNotif')), ([], []))
        self.assertEqual(sum(e.get('event') == 'signaling dropped' for e in self.logs), 2)

    async def test_team_and_all_chat_reach_any_online_player_defused(self):
        a, c = await self.connect('ann'), await self.connect('cat')   # strangers in one custom lobby or match
        for line in ('/t gl', '/A ReportLeaveQueueCommand', '/a back\\slash "'):
            await a.send('signalingP2PNotif', destinationId=c.uid, message=line)
        await self.settle(a, c)
        self.assertEqual([(f['destinationId'], f['message']) for f in c.take()],
                         [(a.uid, '/t gl'), (a.uid, f'/A Re{ZWSP}portLeaveQueueCommand'), (a.uid, '/a back\\\\slash "' + ZWSP)])
        with mock.patch.object(social, 'LOBBY_CHAT', False):   # the off switch: friends and party mates only, as before
            await a.send('signalingP2PNotif', destinationId=c.uid, message='/t gl')
            await self.settle(a, c)
        self.assertEqual(c.take(), [])
        await self.drop(c)
        await a.send('signalingP2PNotif', destinationId=c.uid, message='/t gl')   # offline: dropped
        await self.settle(a)
        self.assertEqual(sum(e.get('event') == 'signaling dropped' for e in self.logs), 2)


class SlowWS:
    """A lobby connection whose sends wait for `gate` when it is set (a slow or dying player)."""
    closed = False

    def __init__(self):
        self.sent, self.gate = [], None

    async def send_str(self, s):
        if self.gate:
            await self.gate.wait()
        self.sent.append(parse(s))

    async def close(self):
        self.closed = True


class Races(unittest.IsolatedAsyncioTestCase):
    """Interleavings the websocket tests can't force: Social with fake connections, a's sends held back."""

    async def asyncSetUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.social = social.Social({'store': fb.Store(Path(tmp.name) / 'store.json'), 'log': lambda entry: None})
        self.ws = {u: SlowWS() for u in 'ab'}
        for u, ws in self.ws.items():
            await self.social.connect(u, ws)
        self.social.friends.update(a=['b'], b=['a'])
        await self.frame('a', 'partyCreateRequest')
        await self.frame('a', 'partyInviteRequest', friendID='b')
        p = self.social.party('a')
        await self.frame('b', 'partyJoinRequest', partyID=p.id, invitationToken=p.token)
        self.ws['a'].gate = asyncio.Event()

    async def frame(self, uid, type_, **fields):
        return await self.social.handle(uid, self.ws[uid], type_, {'id': '1', **fields})

    async def settle(self):
        for _ in range(10):
            await asyncio.sleep(0)

    async def test_reconnecting_while_the_drop_runs_keeps_the_player_online(self):
        # _drop_later re-checks the connection after its awaits before it removes it (review P2)
        with mock.patch.object(social, 'GRACE', 0):
            self.social.disconnect('b', self.ws['b'])
            await self.settle()               # the drop is telling a that b left
        await self.social.connect('b', SlowWS())
        self.ws['a'].gate.set()
        await self.settle()
        self.assertTrue(self.social.online('b'))

    async def test_a_kick_racing_a_leave_completes(self):
        # the kick re-checks membership after its awaits (it used to raise and close the leader's socket) (review P2)
        kick = asyncio.create_task(self.frame('a', 'partyKickRequest', memberID='b'))
        leave = asyncio.create_task(self.frame('b', 'partyLeaveRequest'))
        await self.settle()
        self.ws['a'].gate.set()
        self.assertEqual(await asyncio.gather(kick, leave, return_exceptions=True), [True, True])
        self.assertEqual(self.social.party('a').members, ['a'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
