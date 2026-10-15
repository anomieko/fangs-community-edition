"""PLAY matchmaking (backend/matchmaker.py, Casual): characterization tests that pin what the matchmaker does today,
above all when more matches could form than there are game servers. An @expectedFailure test states the correct
behavior where today's is wrong. Ranked has its own tests (test_ranked_queue.py, test_ranked.py).

Three levels, none needs the game or Wine:
- Queue, Parties: the real Matchmaker with fake websockets, a fake clock and a fake allocator, ticked by hand;
- Capacity: the same with the real HostManager, its game servers planted in its table (no process) or started from
  fake_host.py where a match needs a new one (ready after ~2 s: HostManager's status poll);
- Endpoints, PartyQueue: the real backend (support.BackendCase) over its /matchmaker and /lobby websockets.

    python -I -m unittest discover -s backend/tests -p test_matchmaker.py -v
"""
import asyncio
import base64
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

from aiohttp import WSMsgType

sys.path.insert(0, str(Path(__file__).resolve().parent))   # support.py, also when run as a script
import support
import fangs_backend as fb
import matchmaker
import social
from hosts import Host, HostManager
from matchmaker import PARTY_WAIT, STARTING_EXPIRY_MS, Matchmaker
from test_social import Lobby, LobbyCase

P1, P2 = 17777, 17778


class FakeWS:
    closed = False

    def __init__(self):
        self.sent, self.gate = [], None   # gate: a slow connection, sends wait for it

    async def send_str(self, s):
        if self.gate:
            await self.gate.wait()
        self.sent.append(json.loads(s))


class FakeHosts:
    """The host manager as the matchmaker uses it: `ports` slots, each allocation keeps one. Allocations wait for
    `gate` if set (a server booting)."""

    def __init__(self, ports=2):
        self.ports, self.allocated, self.gate, self.waiting = ports, [], None, 0

    def capacity(self):   # as HostManager.capacity: slots neither taken nor being allocated
        return self.ports - len(self.allocated) - self.waiting

    async def allocate(self, session_id, match=None):
        self.waiting += 1
        try:
            if self.gate:
                await self.gate.wait()
        finally:
            self.waiting -= 1
        self.allocated.append((session_id, match))
        return SimpleNamespace(port=7776 + len(self.allocated), session_id=session_id)


class FakeSocial:
    def __init__(self):
        self.parties = []

    def party_members(self, uid):
        return next((p for p in self.parties if uid in p), [uid])


def token_team(token):
    payload = json.loads(base64.b64decode(token.split('.')[1]))
    return next(iter(payload['assign']['extensions']['team']['ticketToTeamIndex'].values()))


class MatchmakerCase(unittest.IsolatedAsyncioTestCase):
    """The real Matchmaker with fake websockets (players are named by one letter), a fake clock (self.now) and
    FakeHosts; tick() is called by hand."""

    async def asyncSetUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.now = 1_000_000.0
        clock = mock.patch.object(matchmaker, 'time', SimpleNamespace(time=lambda: self.now))
        clock.start()
        self.addCleanup(clock.stop)
        store = fb.Store(self.tmp / 'store.json')
        store.data['game_records']['FANGSConfig'] = {'v': {'CasualMaps': [{'Map': 'LE_Casual', 'Name': 'Casual'}]}}
        self.logs, self.ws = [], {}
        self.app = {'store': store, 'log': self.logs.append, 'cfg': SimpleNamespace(public_ip='203.0.113.1'),
                    'hosts': FakeHosts(), 'social': FakeSocial()}
        self.mm = Matchmaker(self.app)

    def matchmaker(self, **kw):
        self.mm = Matchmaker(self.app, **kw)
        return self.mm

    async def queue(self, *uids, **msg):
        """Each player presses PLAY, one second after the one before (the line's order is explicit)."""
        for u in uids:
            self.mm.clients[u] = self.ws.setdefault(u, FakeWS())
            await self.mm.on_message(u, 'QueueJoinRequest', {'id': 'casual', **msg})
            self.now += 1

    async def accept(self, *uids):
        for u in uids:
            await self.mm.on_message(u, 'AcceptMatchRequest', {'id': self.sent(u)[-1]['match']['id']})
        await self.settle()

    async def settle(self):
        for _ in range(10):   # start() runs as a task
            await asyncio.sleep(0)

    async def disconnect(self, u):
        """What the matchmaker websocket handler does when a player's connection closes."""
        del self.mm.clients[u]
        await self.mm.leave(u, 'disconnected')

    def sent(self, u, msg_type='ClientStatusResponse'):
        return [m['msg'] for m in self.ws[u].sent if m['msg_type'] == msg_type]

    def status(self, u):
        return self.sent(u)[-1]['status']

    def statuses(self, uids):
        return {u: self.status(u) for u in uids}

    def history(self, u):
        """What the player was told: statuses, and 'Server' for the server assignment."""
        return [m['msg'].get('status', 'Server') for m in self.ws[u].sent]

    def place(self, u):
        """When the player's ticket joined the line (None: not in line)."""
        ticket = self.mm.tickets.get(self.mm.ticket_of.get(u))
        return ticket and ticket.queued_at

    def team(self, u):
        return token_team(self.sent(u, 'ServerAssignmentResponse')[-1]['token'])

    def assigned(self, u):
        got = self.sent(u, 'ServerAssignmentResponse')
        return got[-1]['assignment'] if got else None

    async def until(self, cond, seconds=10):
        async with asyncio.timeout(seconds):
            while not cond():   # noqa: ASYNC110 - backend state that has no event to wait for
                await asyncio.sleep(0.02)


class Queue(MatchmakerCase):
    async def test_a_full_game_is_matched_accepted_and_sent_to_a_server(self):
        players = 'abcdefgh'
        await self.queue(*players)
        self.assertEqual(set(self.statuses(players).values()), {'Queued'})
        await self.mm.tick()
        match = self.sent('a')[-1]['match']
        self.assertEqual({self.sent(u)[-1]['match']['id'] for u in players}, {match['id']})
        self.assertEqual(match['expiresInMillis'], 15_000)
        for i, u in enumerate(players, 1):
            await self.mm.on_message(u, 'AcceptMatchRequest', {'id': match['id']})
            self.assertEqual(self.sent('h')[-1]['match']['accepted'], i)   # everyone sees the count
        await self.settle()
        self.assertEqual(self.sent('a')[-1]['match']['expiresInMillis'], STARTING_EXPIRY_MS)   # open while the server boots
        self.assertEqual(self.app['hosts'].allocated, [(match['id'], {'size': 8, 'map': 'LE_Casual', 'map_name': 'Casual'})])
        self.assertEqual({self.assigned(u) for u in players}, {'203.0.113.1:7777'})
        self.assertEqual(sorted(self.team(u) for u in players), [0] * 4 + [1] * 4)
        self.assertEqual((self.mm.tickets, self.mm.ticket_of, self.mm.matches, self.mm.match_of), ({}, {}, {}, {}))

    async def test_a_game_only_starts_full(self):
        await self.queue(*'abcdefg')
        self.now += 3600
        await self.mm.tick()
        self.assertEqual(set(self.statuses('abcdefg').values()), {'Queued'})
        await self.queue('h')
        await self.mm.tick()
        self.assertEqual(set(self.statuses('abcdefgh').values()), {'Matched'})

    async def test_match_size_two_pairs_the_longest_waiting_one_match_per_tick(self):
        self.matchmaker(size=2)
        await self.queue(*'abcde')
        await self.mm.tick()
        self.assertEqual(self.statuses('abcde'), {'a': 'Matched', 'b': 'Matched', 'c': 'Queued', 'd': 'Queued', 'e': 'Queued'})
        await self.mm.tick()   # the next tick forms the next match, the first one still in its accept phase (2 servers)
        self.assertEqual(self.statuses('cde'), {'c': 'Matched', 'd': 'Matched', 'e': 'Queued'})
        await self.accept('a', 'b')
        self.assertEqual(self.app['hosts'].allocated[0][1]['size'], 2)
        self.assertEqual({self.team('a'), self.team('b')}, {0, 1})

    async def test_with_a_wait_a_game_starts_early_with_at_least_two(self):
        self.matchmaker(wait=30)
        start = self.now
        await self.queue(*'abc')
        self.now = start + 29.9
        await self.mm.tick()
        self.assertEqual(set(self.statuses('abc').values()), {'Queued'})
        self.now = start + 30   # the longest-waiting player's wait counts
        await self.mm.tick()
        await self.accept(*'abc')
        self.assertEqual(self.app['hosts'].allocated[0][1]['size'], 3)
        self.assertEqual(sorted([self.team(u) for u in 'abc'].count(t) for t in (0, 1)), [1, 2])

    async def test_with_a_wait_nobody_plays_alone(self):
        self.matchmaker(wait=30)
        await self.queue('a')
        self.now += 3600
        await self.mm.tick()
        self.assertEqual(self.status('a'), 'Queued')

    async def test_a_reject_idles_the_rejecter_and_puts_the_others_back_in_their_place(self):
        self.matchmaker(size=2)
        await self.queue('a', 'b')
        place = self.place('a')
        await self.mm.tick()
        await self.queue('c', 'd')
        await self.mm.on_message('b', 'RejectMatchRequest', {'id': self.sent('b')[-1]['match']['id']})
        self.assertEqual(self.history('a'), ['Queued', 'Matched', 'Idle', 'Queued'])   # Idle closes the accept dialog
        self.assertEqual((self.status('b'), self.place('b'), self.place('a')), ('Idle', None, place))
        await self.mm.tick()
        self.assertEqual(self.statuses('acd'), {'a': 'Matched', 'c': 'Matched', 'd': 'Queued'})   # a ahead of c and d

    async def test_an_accept_timeout_idles_who_did_not_accept(self):
        self.matchmaker(size=4)
        await self.queue(*'abcd')
        places = {u: self.place(u) for u in 'abc'}
        await self.mm.tick()
        formed = self.now
        await self.accept('a', 'b', 'c')
        self.now = formed + 15 + 2   # the client gives up after 15 s; the backend waits 2 s longer
        await self.mm.tick()
        self.assertEqual(set(self.statuses('abcd').values()), {'Accepted'})
        self.now += 0.5
        await self.mm.tick()
        self.assertEqual(self.statuses('abcd'), {'a': 'Queued', 'b': 'Queued', 'c': 'Queued', 'd': 'Idle'})
        self.assertEqual(({u: self.place(u) for u in 'abc'}, self.place('d')), (places, None))
        self.assertIn('not accepted in time', [e.get('reason') for e in self.logs])

    async def test_disconnecting_while_queued_leaves_the_line(self):
        self.matchmaker(size=3)
        await self.queue('a', 'b')
        place, told = self.place('b'), len(self.ws['b'].sent)
        await self.disconnect('a')
        self.assertEqual((self.place('a'), self.place('b'), len(self.ws['b'].sent)), (None, place, told))

    async def test_disconnecting_while_matched_cancels_the_match_and_requeues_the_others(self):
        self.matchmaker(size=2)
        await self.queue('a', 'b')
        place = self.place('b')
        await self.mm.tick()
        await self.disconnect('a')
        self.assertEqual(self.history('b'), ['Queued', 'Matched', 'Idle', 'Queued'])
        self.assertEqual((self.place('a'), self.place('b')), (None, place))
        self.assertEqual((self.mm.matches, self.mm.match_of), ({}, {}))

    async def test_disconnecting_while_the_server_starts_leaves_the_others_in_the_game(self):
        self.matchmaker(size=3)
        hosts = self.app['hosts']
        hosts.gate = asyncio.Event()
        await self.queue(*'abc')
        await self.mm.tick()
        await self.accept(*'abc')
        await self.mm.on_message('a', 'ClientStatusRequest', {})
        self.assertEqual((self.status('a'), self.sent('a')[-1]['match']['expiresInMillis']), ('Matched', STARTING_EXPIRY_MS))
        await self.disconnect('c')
        hosts.gate.set()
        await self.settle()
        self.assertEqual([u for u in 'abc' if self.assigned(u)], ['a', 'b'])
        self.assertEqual(hosts.allocated[0][1]['size'], 3)   # asked before c left: FangsHost starts with whoever comes
        self.assertEqual((self.mm.matches, self.mm.match_of), ({}, {}))

    async def test_a_match_cancelled_while_an_accept_is_announced_does_not_start(self):
        # accept() announces, then starts: a match cancelled while it announced must not start (review P2)
        self.matchmaker(size=2)
        await self.queue('a', 'b')
        await self.mm.tick()
        await self.accept('a')
        self.ws['a'].gate = asyncio.Event()   # telling a that b accepted takes a while
        accepting = asyncio.create_task(self.accept('b'))
        await self.settle()
        await self.disconnect('a')            # meanwhile a's connection drops: the match is cancelled, b back in line
        self.ws['a'].gate.set()
        await accepting
        self.assertEqual((self.status('b'), self.assigned('b'), self.app['hosts'].allocated), ('Queued', None, []))

    async def test_queueing_again_keeps_the_one_place_in_line(self):
        await self.queue('a')
        place = self.place('a')
        await self.queue('a')
        self.assertEqual((len(self.mm.tickets), self.place('a'), self.history('a')), (1, place, ['Queued', 'Queued']))

    async def test_leaving_the_queue(self):
        await self.queue('a', 'b')
        await self.mm.on_message('a', 'ClientResetRequest', {})
        self.assertEqual((self.sent('a')[-1], self.place('a')), ({'status': 'Idle', 'id': 'a'}, None))
        self.assertIsNotNone(self.place('b'))


class Parties(MatchmakerCase):
    async def party(self, leader, *members):
        """The leader presses PLAY for the party; returns the token the members follow with."""
        self.app['social'].parties.append([leader, *members])
        await self.queue(leader)
        return self.sent(leader)[-1]['partyToken']

    async def matched_party(self):
        """A 2 vs 2: party l+m against s and t, in its accept phase."""
        self.matchmaker(size=4)
        await self.queue('m', partyToken=await self.party('l', 'm'))
        await self.queue('s', 't')
        places = {u: self.place(u) for u in 'st'}
        await self.mm.tick()
        return places

    async def test_a_party_ticket_waits_for_its_members_and_plays_on_one_team(self):
        self.matchmaker(size=4)
        token = await self.party('l', 'm')
        await self.queue('s', 't')
        await self.mm.tick()
        self.assertEqual(set(self.statuses('lst').values()), {'Queued'})   # waits for m
        await self.queue('m', partyToken=token)
        self.assertNotIn('partyToken', self.sent('m')[-1])                 # only the leader hands it on
        await self.mm.tick()
        await self.accept(*'lmst')
        teams = {u: self.team(u) for u in 'lmst'}
        self.assertEqual((teams['l'] == teams['m'], teams['s'] == teams['t'], teams['l'] == teams['s']), (True, True, False))

    async def test_a_party_goes_without_missing_members_after_the_party_wait(self):
        self.matchmaker(size=2)
        start = self.now
        token = await self.party('l', 'm')
        await self.queue('s')
        self.now = start + PARTY_WAIT - 0.1
        await self.mm.tick()
        self.assertEqual(self.statuses('ls'), {'l': 'Queued', 's': 'Queued'})
        self.now = start + PARTY_WAIT
        await self.mm.tick()
        self.assertEqual(self.statuses('ls'), {'l': 'Matched', 's': 'Matched'})
        await self.queue('m', partyToken=token)   # too late: the ticket has left the line
        self.assertEqual(self.status('m'), 'Idle')

    async def test_a_party_token_admits_only_its_members(self):
        token = await self.party('l', 'm')
        await self.queue('x', partyToken=token)
        await self.queue('m', partyToken='0' * 32)
        self.assertEqual(self.statuses('xm'), {'x': 'Idle', 'm': 'Idle'})
        self.assertEqual(self.mm.tickets[token].joined, ['l'])

    async def test_a_member_leaving_the_queue_drops_the_whole_party_ticket(self):
        await self.queue('m', partyToken=await self.party('l', 'm'))
        await self.mm.on_message('m', 'ClientResetRequest', {})
        self.assertEqual(self.statuses('lm'), {'l': 'Idle', 'm': 'Idle'})
        self.assertEqual((self.mm.tickets, self.mm.ticket_of), ({}, {}))

    async def test_a_party_change_drops_its_ticket_in_line(self):
        await self.queue('m', partyToken=await self.party('l', 'm', 'n'))   # n hasn't followed yet
        await self.mm.party_changed('party', left='n')                       # n left the party or was kicked
        self.assertEqual(self.statuses('lm'), {'l': 'Idle', 'm': 'Idle'})
        self.assertEqual(self.mm.tickets, {})

    async def test_a_party_member_rejecting_idles_the_party_and_requeues_the_others(self):
        places = await self.matched_party()
        await self.mm.on_message('m', 'RejectMatchRequest', {'id': self.sent('m')[-1]['match']['id']})
        self.assertEqual(self.statuses('lmst'), {'l': 'Idle', 'm': 'Idle', 's': 'Queued', 't': 'Queued'})
        self.assertEqual(({u: self.place(u) for u in 'st'}, self.place('l')), (places, None))

    async def test_a_party_change_while_matched_cancels_the_match(self):
        places = await self.matched_party()
        await self.mm.party_changed('party', left='m')
        self.assertEqual(self.statuses('lmst'), {'l': 'Idle', 'm': 'Idle', 's': 'Queued', 't': 'Queued'})
        self.assertEqual(({u: self.place(u) for u in 'st'}, self.place('l')), (places, None))

    async def test_a_party_change_while_the_server_starts_changes_nothing(self):
        self.app['hosts'].gate = asyncio.Event()
        await self.matched_party()
        await self.accept(*'lmst')
        await self.mm.party_changed('party', left='m')
        self.app['hosts'].gate.set()
        await self.settle()
        self.assertEqual([u for u in 'lmst' if self.assigned(u)], list('lmst'))
        self.assertEqual(self.team('l'), self.team('m'))

    async def test_parties_are_never_split_and_one_that_breaks_even_teams_waits(self):
        for leader, *members in ('abc', 'def', 'gh'):
            await self.queue(*members, partyToken=await self.party(leader, *members))
        await self.queue('x', 'y')
        await self.mm.tick()
        self.assertEqual(self.statuses('gh'), {'g': 'Queued', 'h': 'Queued'})   # 3 + 3 + 2 can't make 4 vs 4
        await self.accept(*'abcdefxy')
        teams = {u: self.team(u) for u in 'abcdefxy'}   # each party on one side; the parties apart, the solos apart
        self.assertEqual([len({teams[u] for u in group}) for group in ('abc', 'def', 'ad', 'xy')], [1, 1, 2, 2])


class Capacity(MatchmakerCase):
    """More players than game servers, with the real HostManager (production: 2 ports, 1 standby)."""

    def servers(self, ports, standby=0):
        hosts = HostManager(game_dir=str(self.tmp / 'game'), inst_root=self.tmp / 'hosts', ports=ports,
                            run_script=str(support.FAKE_HOST), backend_addr='127.0.0.1:1', log=self.logs.append,
                            data_dir=str(self.tmp), standby=standby)
        self.app['hosts'] = hosts
        self.addAsyncCleanup(hosts.shutdown)
        return hosts

    def plant(self, port, session=None):
        """A booted game server on `port` without a process: an idle standby, or in use by `session` (a custom lobby
        or a running match)."""
        hosts = self.app['hosts']
        host = Host(f'host-{port}', port, hosts.inst_root / f'host-{port}')
        (host.inst / 'MOBA' / 'Binaries' / 'Win64').mkdir(parents=True, exist_ok=True)
        host.session_id = session
        host.ready.set()
        hosts.hosts[host.id] = host
        return host

    async def test_while_every_server_is_busy_everyone_keeps_their_place_in_line(self):
        hosts = self.servers([P1])
        lobby = self.plant(P1, session='lobby')
        self.matchmaker(size=2)
        await self.queue(*'abc')
        await self.mm.tick()
        self.assertEqual(set(self.statuses('abc').values()), {'Queued'})
        await hosts.stop(lobby, 'everyone left the lobby')
        await self.mm.tick()
        self.assertEqual(self.statuses('abc'), {'a': 'Matched', 'b': 'Matched', 'c': 'Queued'})

    async def test_no_second_match_while_the_first_ones_server_boots_on_the_last_port(self):
        hosts = self.servers([P1])
        self.matchmaker(size=2)
        await self.queue(*'abcd')
        await self.mm.tick()
        await self.accept('a', 'b')
        await self.until(lambda: hosts.hosts)   # the new server holds its port from the start
        await self.mm.tick()
        self.assertEqual(self.statuses('cd'), {'c': 'Queued', 'd': 'Queued'})
        await self.until(lambda: self.assigned('a'))
        self.assertEqual({self.assigned('a'), self.assigned('b')}, {f'203.0.113.1:{P1}'})
        await self.mm.tick()
        self.assertEqual(self.statuses('cd'), {'c': 'Queued', 'd': 'Queued'})   # their match runs there
        await hosts.stop(hosts.hosts[f'host-{P1}'], 'match over')
        await self.mm.tick()
        self.assertEqual(self.statuses('cd'), {'c': 'Matched', 'd': 'Matched'})

    async def test_with_a_standby_two_matches_get_it_and_its_replacement(self):
        self.servers([P1, P2], standby=1)
        self.plant(P1)   # the booted standby; P2 is free
        self.matchmaker(size=2)
        await self.queue(*'abcd')
        await self.mm.tick()
        await self.mm.tick()   # forms during the first one's accept phase: two servers, two matches
        self.assertEqual(set(self.statuses('abcd').values()), {'Matched'})
        await self.accept('a', 'b')
        self.assertEqual(self.assigned('a'), f'203.0.113.1:{P1}')   # the standby, at once
        await self.accept('c', 'd')                                  # waits for the standby that boots on P2
        await self.until(lambda: self.assigned('c'))
        self.assertEqual(self.assigned('d'), f'203.0.113.1:{P2}')

    async def test_a_boot_failure_tells_the_players(self):
        self.servers([P1])
        (self.tmp / 'hosts').mkdir()
        (self.tmp / 'hosts' / 'fake_host_mode').write_text('die')   # every start dies at once (3 attempts)
        self.matchmaker(size=2)
        await self.queue('a', 'b')
        await self.mm.tick()
        await self.accept('a', 'b')
        await self.until(lambda: not self.mm.matches)
        self.assertEqual([self.history(u)[-1] for u in 'ab'], ['Idle', 'Idle'])
        self.assertEqual((self.place('a'), self.mm.match_of), (None, {}))   # out of line: they press PLAY again
        self.assertEqual([e['error'] for e in self.logs if e.get('mm') == 'start failed'], ['game server failed to start'])

    async def test_matches_never_outnumber_the_free_servers(self):
        # a match in its accept dialog holds a server too, so no more matches form than there are servers (review M2)
        self.servers([P1])
        self.matchmaker(size=2)
        await self.queue(*'abcd')   # four players press PLAY at once; one server
        await self.mm.tick()
        await self.mm.tick()
        self.assertEqual(self.statuses('abcd'), {'a': 'Matched', 'b': 'Matched', 'c': 'Queued', 'd': 'Queued'})

    async def test_two_servers_take_two_matches_not_three(self):
        # as above, in the live shape (standby + one free port): no third match forms (review M2)
        self.servers([P1, P2], standby=1)
        self.plant(P1)
        self.matchmaker(size=2)
        await self.queue(*'abcdef')
        for _ in range(3):
            await self.mm.tick()
        self.assertEqual(self.statuses('ef'), {'e': 'Queued', 'f': 'Queued'})

    async def test_a_match_that_finds_no_server_goes_back_in_line(self):
        # a lobby took the last server during the accept dialog: the players go back in line with their place (review M2)
        self.servers([P1])
        self.matchmaker(size=2)
        await self.queue(*'abc')
        places = {u: self.place(u) for u in 'ab'}
        await self.mm.tick()
        self.plant(P1, session='lobby')   # a custom lobby takes the server during the accept phase
        await self.accept('a', 'b')
        await self.until(lambda: not self.mm.matches)
        self.assertEqual(({u: self.place(u) for u in 'ab'}, self.statuses('ab')), (places, {'a': 'Queued', 'b': 'Queued'}))

    async def test_a_server_booted_for_a_match_everyone_left_is_not_kept_for_it(self):
        # all its players left during the boot: the server isn't kept for nobody (review M2)
        hosts = self.servers([P1])
        self.matchmaker(size=2)
        await self.queue('a', 'b')
        await self.mm.tick()
        await self.accept('a', 'b')
        await self.until(lambda: hosts.hosts)   # booting
        await self.disconnect('a')
        await self.disconnect('b')
        await self.until(lambda: not self.mm.matches)
        self.assertEqual([h.session_id for h in hosts.hosts.values() if h.session_id], [])

    async def test_an_idle_standby_server_is_free_for_a_match(self):
        # an idle standby is a free server for a match, not a busy slot (review M1)
        self.servers([P1, P2])
        self.plant(P1, session='lobby')
        self.plant(P2)   # the booted standby, idle
        self.matchmaker(size=2)
        await self.queue('a', 'b')
        await self.mm.tick()
        self.assertEqual(self.statuses('ab'), {'a': 'Matched', 'b': 'Matched'})
        await self.accept('a', 'b')
        self.assertEqual(self.assigned('a'), f'203.0.113.1:{P2}')


class Queuer:
    """A player's matchmaker websocket."""

    def __init__(self, uid, ws):
        self.uid, self.ws, self.got = uid, ws, []

    async def send(self, msg_type, **msg):
        await self.ws.send_json({'msg_type': msg_type, 'msg': msg})

    async def next(self, n=1):
        """The kinds (status, or ServerAssignmentResponse) of the next n messages; the messages go to self.got."""
        kinds = []
        for _ in range(n):
            m = await self.ws.receive_json(timeout=10)
            self.got.append(m['msg'])
            kinds.append(m['msg'].get('status', m['msg_type']))
        return kinds


class EndpointCase(LobbyCase):
    """The real backend, its matchmaker ticked by the tests; game servers from fake_host.py on one port."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.app['matchmaking'].cancel()   # its 1 s loop: the tests call tick() themselves
        self.mm = self.app['matchmaker']

    async def play(self, who):
        """`who`'s matchmaker connection: a name, or a Lobby (a player who is on the lobby websocket too)."""
        token = who.token if isinstance(who, Lobby) else await self.login(who)
        ws = await self.client.ws_connect('/matchmaker', protocols=('json',),
                                          headers={'Authorization': matchmaker.AUTH_PREFIX + token['access_token']})
        return Queuer(token['user_id'], ws)

    async def queued(self, *names):
        players = [await self.play(n) for n in names]
        for q in players:
            await q.send('QueueJoinRequest', id='casual')
            self.assertEqual(await q.next(), ['Queued'])
        return players


class Endpoints(EndpointCase):
    extra_args = ('--match-size', '2', '--host-ports', f'{P1}-{P1}')

    async def test_a_connection_without_a_valid_token_is_closed(self):
        for headers in ({}, {'Authorization': matchmaker.AUTH_PREFIX + 'nope'}):
            ws = await self.client.ws_connect('/matchmaker', protocols=('json',), headers=headers)
            msg = await ws.receive(timeout=5)
            self.assertEqual((msg.type, msg.data), (WSMsgType.CLOSE, 4001))

    async def test_queue_match_accept_and_join_the_server(self):
        a, b = await self.queued('ann', 'ben')
        await self.mm.tick()
        for q in (a, b):
            self.assertEqual(await q.next(), ['Matched'])
            await q.send('AcceptMatchRequest', id=a.got[-1]['match']['id'])
        for q in (a, b):   # accepted 1, 2, then starting (while fake_host.py boots)
            self.assertEqual(await q.next(4), ['Accepted', 'Accepted', 'Accepted', 'ServerAssignmentResponse'])
        self.assertEqual({q.got[-1]['assignment'] for q in (a, b)}, {f'127.0.0.1:{P1}'})
        self.assertEqual({token_team(q.got[-1]['token']) for q in (a, b)}, {0, 1})
        match = json.loads((self.tmp / 'hosts' / f'host-{P1}' / 'MOBA' / 'Binaries' / 'Win64' / 'fangshost_match.json')
                           .read_text())
        maps = {m['Map'] for v in self.app['store'].data['game_records']['FANGSConfig'].values() if isinstance(v, dict)
                for m in v.get('CasualMaps', [])}
        self.assertEqual(match['size'], 2)
        self.assertIn(match['map'], maps)

    async def test_closing_the_connection_leaves_the_queue_or_the_match(self):
        a, b, c = await self.queued('ann', 'ben', 'cat')
        await self.mm.tick()
        self.assertEqual((await a.next(), await b.next()), (['Matched'], ['Matched']))
        await c.ws.close()
        await self.until(lambda: c.uid not in self.mm.ticket_of)
        await a.ws.close()
        self.assertEqual(await b.next(2), ['Idle', 'Queued'])
        self.assertEqual(list(self.mm.ticket_of), [b.uid])

    async def test_a_second_connection_replaces_the_first_and_keeps_the_place(self):
        a, = await self.queued('ann')
        place = self.mm.tickets[self.mm.ticket_of[a.uid]].queued_at
        a2 = await self.play('ann')
        self.assertEqual((await a.ws.receive(timeout=5)).type, WSMsgType.CLOSE)
        await a2.send('ClientStatusRequest')
        self.assertEqual(await a2.next(), ['Queued'])
        self.assertEqual(self.mm.tickets[self.mm.ticket_of[a.uid]].queued_at, place)


class PartyQueue(EndpointCase):
    """Parties from the lobby websocket (social.py) in the matchmaker's line."""
    extra_args = ('--match-size', '4', '--host-ports', f'{P1}-{P1}')

    async def party_in_line(self):
        """ann's party with ben, queued: ben follows with the token from ann's Queued, as the clients pass it on."""
        ann, ben = await self.connect('ann'), await self.connect('ben')
        await self.befriend(ann, ben)
        await self.make_party(ann, ben)
        qa, qb = await self.play(ann), await self.play(ben)
        await qa.send('QueueJoinRequest', id='casual')
        self.assertEqual(await qa.next(), ['Queued'])
        await qb.send('QueueJoinRequest', id='casual', partyToken=qa.got[-1]['partyToken'])
        self.assertEqual(await qb.next(), ['Queued'])
        self.assertNotIn('partyToken', qb.got[-1])
        return ann, ben, qa, qb

    async def test_a_party_queues_through_its_leader_and_is_matched_on_one_team(self):
        ann, _, qa, qb = await self.party_in_line()
        others = await self.queued('cat', 'dan')
        await self.mm.tick()
        for q in (qa, qb, *others):
            self.assertEqual(await q.next(), ['Matched'])
        team = self.mm.matches[qa.got[-1]['match']['id']].team
        self.assertEqual([team[q.uid] == team[ann.uid] for q in (qb, *others)], [True, False, False])

    async def test_leaving_the_party_drops_its_ticket(self):
        _, ben, qa, qb = await self.party_in_line()
        await ben.request('partyLeaveRequest')
        self.assertEqual((await qa.next(), await qb.next()), (['Idle'], ['Idle']))
        self.assertEqual(self.mm.tickets, {})

    async def test_a_kick_while_matched_sends_the_solo_players_back_in_line(self):
        ann, ben, qa, qb = await self.party_in_line()
        others = await self.queued('cat', 'dan')
        await self.mm.tick()
        for q in (qa, qb, *others):
            await q.next()
        await ann.request('partyKickRequest', memberID=ben.uid)
        self.assertEqual((await qa.next(), await qb.next()), (['Idle'], ['Idle']))
        for q in others:
            self.assertEqual(await q.next(2), ['Idle', 'Queued'])

    async def test_a_member_gone_past_the_grace_period_drops_the_ticket(self):
        _, ben, qa, qb = await self.party_in_line()
        with mock.patch.object(social, 'GRACE', 0):
            await self.drop(ben)
            self.assertEqual((await qa.next(), await qb.next()), (['Idle'], ['Idle']))
        self.assertEqual(self.mm.tickets, {})


if __name__ == '__main__':
    unittest.main(verbosity=2)
