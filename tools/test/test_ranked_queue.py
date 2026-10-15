"""Ranked and Casual queues end to end inside the backend: the real Matchmaker and ingest_match with fake
websockets, a fake host manager and a throwaway store (no game, no network, nothing under backend/data).

    backend/.venv/bin/python -I tools/test/test_ranked_queue.py
"""
import asyncio
import base64
import json
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'backend'))
import fangs_backend as fb  # noqa: E402
import ranked  # noqa: E402
import skill  # noqa: E402
from matchmaker import Matchmaker  # noqa: E402


class FakeWS:
    closed = False

    def __init__(self):
        self.sent = []

    async def send_str(self, s):
        self.sent.append(json.loads(s))


class FakeHosts:
    def __init__(self, ports=2):
        self.ports, self.allocated = ports, []

    def free_ports(self):
        return list(range(self.ports - len(self.allocated)))

    async def allocate(self, session_id, match=None):
        self.allocated.append((session_id, match))
        return SimpleNamespace(port=7777 + len(self.allocated), session_id=session_id)


class FakeSocial:
    def __init__(self):
        self.parties = []

    def party_members(self, uid):
        return next((p for p in self.parties if uid in p), [uid])


def token_team(token):
    payload = json.loads(base64.b64decode(token.split('.')[1]))
    return next(iter(payload['assign']['extensions']['team']['ticketToTeamIndex'].values()))


class Queues(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.store = fb.Store(Path(self.tmp.name) / 'store.json')
        self.store.data['game_records']['FANGSConfig'] = {'v': {'CasualMaps': [{'Map': 'LE_Casual'}],
                                                                'RankedMaps': [{'Map': 'LE_Ranked', 'Name': 'R'}]}}
        self.logs = []
        self.app = {'store': self.store, 'log': self.logs.append, 'cfg': SimpleNamespace(public_ip='203.0.113.1'),
                    'hosts': FakeHosts(), 'social': FakeSocial()}
        self.mm = Matchmaker(self.app)
        self.ws = {}

    async def asyncTearDown(self):
        self.tmp.cleanup()

    def player(self, name, rating=None, sigma=170.0, played=30):
        uid = self.store.user_for(name)['user_id']
        if rating is not None:
            self.store.data.setdefault('ranked', {'players': {}, 'last_opponents': {}})['players'][uid] = \
                skill.Rating(uid, rating, sigma, played).to_json()
        self.ws[uid] = self.mm.clients[uid] = FakeWS()
        return uid

    def last(self, uid, msg_type='ClientStatusResponse'):
        return next((m['msg'] for m in reversed(self.ws[uid].sent) if m['msg_type'] == msg_type), None)

    async def queue(self, uids, queue='ranked'):
        for u in uids:
            await self.mm.on_message(u, 'QueueJoinRequest', {'id': queue, 'attributes': []})

    async def play(self, uids):
        """Accept the match everyone is in; return {uid: team index} from their server assignment tokens."""
        mid = self.last(uids[0])['match']['id']
        for u in uids:
            await self.mm.on_message(u, 'AcceptMatchRequest', {'id': mid})
        for _ in range(5):
            await asyncio.sleep(0)
        teams = {u: token_team(self.last(u, 'ServerAssignmentResponse')['token']) for u in uids}
        return mid, teams

    def result(self, teams, winner_index, mode=2, leave=()):
        rows = [{'UserId': u, 'Team': ('TeamA', 'TeamB')[t], 'Type': 'Berserker'} for u, t in teams.items() if u not in leave]
        return {'results': {'MatchResults': [{'RoundResults': rows, 'TotalRoundTime': 300.0 + time.time() % 1}],
                            'TimePlayed': time.time(), 'MapLevel': 'LE_Ranked'},
                'winning_team': winner_index + 1, 'game_mode': mode, 'match_time': 600}

    async def test_ranked_balances_settles_and_ranks(self):
        ratings = [1420, 1450, 1480, 1500, 1500, 1520, 1550, 1580]
        uids = [self.player(f'r{i}', r) for i, r in enumerate(ratings)]
        await self.queue(uids)
        self.assertEqual(self.last(uids[0])['status'], 'Queued')
        await self.mm.tick()
        self.assertEqual(self.last(uids[0])['status'], 'Matched')
        info = next(e for e in self.logs if e.get('mm') == 'matched')['ranked']
        self.assertLess(abs(info['win_chance'] - .5), .01, info)
        mid, teams = await self.play(uids)
        self.assertEqual(self.app['hosts'].allocated[0][1]['map'], 'LE_Ranked')
        team_sum = [sum(r for u, r in zip(uids, ratings) if teams[u] == t) for t in (0, 1)]
        self.assertLessEqual(abs(team_sum[0] - team_sum[1]), 20)
        before = {u: ranked.rating_of(self.store, u) for u in uids}
        fb.ingest_match(self.store, self.result(teams, 0), self.logs.append, ranked_parties=self.mm.ranked_result(mid))
        self.assertIsNone(self.mm.ranked_result(mid))          # settled once
        log = self.logs[-1]['ranked']
        self.assertTrue(log['rated'], log)
        for u in uids:
            after = ranked.rating_of(self.store, u)
            self.assertEqual(after.played, before[u].played + 1)
            self.assertEqual(after.rating > before[u].rating, teams[u] == 0)
            self.assertAlmostEqual(after.rating - before[u].rating, (1 if teams[u] == 0 else -1) * 19.0, delta=1.5)
        winner = next(u for u in uids if teams[u] == 0)
        served = fb.stats_record(self.store, winner, 'PROFILE_RATINGS_KEY')['ranked_rating']
        self.assertEqual(served, skill.display(ranked.rating_of(self.store, winner)))
        board = fb.leaderboard(self.store)
        points = {u: fb.rank_points(fb.stats_record(self.store, u, 'PROFILE_RATINGS_KEY')['ranked_rating']) for u in uids}
        self.assertEqual(sorted(board, key=lambda r: -r[1]), board)
        self.assertEqual(dict(board), points)                # leaderboard = the profile's rank points
        mastery = fb.stats_record(self.store, winner, 'PROFILE_MASTERY_KEY')
        self.assertEqual((mastery['MatchesPlayed'], mastery['MatchesWon']), (1, 1))

    async def test_game_servers_get_the_served_rating(self):
        """FangsHost answers the lobby's GetServerPlayerRatings from the exported records: they must hold the
        Ranked rating, not an old stored (casual, OpenSkill) PROFILE_RATINGS_KEY."""
        uid = self.player('old', 1700, 200, 40)
        old = {'mu': 31.0, 'sigma': 4.0}
        self.store.data['player_records'].setdefault(uid, {})['PROFILE_RATINGS_KEY'] = \
            {'casual_rating': old, 'ranked_rating': old}
        self.store.save()
        exported = json.loads((Path(self.tmp.name) / 'records' / 'players' / uid / 'PROFILE_RATINGS_KEY.json').read_text())
        self.assertEqual(exported, fb.stats_record(self.store, uid, 'PROFILE_RATINGS_KEY'))
        self.assertEqual(exported['ranked_rating'], skill.display(ranked.rating_of(self.store, uid)))

    async def test_casual_is_first_come_and_unrated(self):
        uids = [self.player(f'c{i}', r) for i, r in enumerate([900, 1500, 1500, 1500, 1500, 1500, 1500, 2600])]
        await self.queue(uids, 'beginner')
        await self.mm.tick()
        self.assertEqual(self.last(uids[0])['status'], 'Matched')   # no skill limits in Casual
        mid, teams = await self.play(uids)
        self.assertEqual(self.app['hosts'].allocated[0][1]['map'], 'LE_Casual')
        before, board = dict(self.store.data['ranked']['players']), fb.leaderboard(self.store)
        fb.ingest_match(self.store, self.result(teams, 1), self.logs.append, ranked_parties=self.mm.ranked_result(mid))
        self.assertNotIn('ranked', self.logs[-1])
        self.assertEqual(self.store.data['ranked']['players'], before)
        self.assertEqual(fb.leaderboard(self.store), board)
        self.assertEqual(fb.stats_record(self.store, uids[0], 'PROFILE_MASTERY_KEY')['MatchesPlayed'], 1)

    async def test_ranked_waits_for_a_fair_game_while_casual_plays(self):
        rk = [self.player(f'r{i}', 1500) for i in range(7)] + [self.player('star', 2400)]
        cs = [self.player(f'c{i}') for i in range(8)]
        await self.queue(rk)
        await self.queue(cs, 'casual')
        await self.mm.tick()
        await self.mm.tick()
        self.assertEqual([self.last(u)['status'] for u in cs], ['Matched'] * 8)
        self.assertEqual([self.last(u)['status'] for u in rk], ['Queued'] * 8)   # 2400 vs 1500s: never over 70%
        late = [self.player(f'late{i}', 2350) for i in range(7)]
        await self.queue(late)
        await self.mm.tick()
        self.assertEqual(self.last(rk[-1])['status'], 'Matched')        # the 2400 now has 7 of similar skill
        self.assertEqual(sum(self.last(u)['status'] == 'Matched' for u in late), 7)

    async def test_duo_stays_together_and_counts_as_a_party(self):
        uids = [self.player(f'd{i}', 1500) for i in range(8)]
        duo_a, duo_b = [uids[0], uids[1]], [uids[2], uids[3]]
        self.app['social'].parties = [duo_a, duo_b]
        await self.mm.on_message(duo_a[0], 'QueueJoinRequest', {'id': 'ranked'})
        await self.mm.on_message(duo_b[0], 'QueueJoinRequest', {'id': 'ranked'})
        for leader, member in (duo_a, duo_b):
            token = self.last(leader)['partyToken']
            await self.mm.on_message(member, 'QueueJoinRequest', {'id': 'ranked', 'partyToken': token})
        await self.queue(uids[4:])
        await self.mm.tick()
        mid, teams = await self.play(uids)
        self.assertEqual(teams[duo_a[0]], teams[duo_a[1]])
        self.assertEqual(teams[duo_b[0]], teams[duo_b[1]])
        self.assertNotEqual(teams[duo_a[0]], teams[duo_b[0]])      # mirrored 2+1+1 vs 2+1+1
        fb.ingest_match(self.store, self.result(teams, teams[duo_a[0]]), self.logs.append,
                        ranked_parties=self.mm.ranked_result(mid))
        self.assertEqual(self.logs[-1]['ranked']['contexts'], [30.0, 30.0])

    async def test_uneven_result_is_void_and_decline_requeues(self):
        uids = [self.player(f'v{i}', 1500) for i in range(8)]
        await self.queue(uids)
        queued_at = self.mm.tickets[self.mm.ticket_of[uids[1]]].queued_at
        await self.mm.tick()
        await self.mm.on_message(uids[0], 'RejectMatchRequest', {'id': self.last(uids[0])['match']['id']})
        self.assertEqual(self.last(uids[1])['status'], 'Queued')
        self.assertEqual(self.mm.tickets[self.mm.ticket_of[uids[1]]].queued_at, queued_at)   # keeps its wait
        await self.queue(uids[:1])
        await self.mm.tick()
        mid, teams = await self.play(uids)
        before = dict(self.store.data['ranked']['players'])
        fb.ingest_match(self.store, self.result(teams, 0, leave={uids[0]}), self.logs.append,
                        ranked_parties=self.mm.ranked_result(mid))
        self.assertFalse(self.logs[-1]['ranked']['rated'])
        self.assertEqual(self.store.data['ranked']['players'], before)

    async def test_party_too_big_for_ranked(self):
        a, b, c = self.player('a'), self.player('b'), self.player('c')
        self.app['social'].parties = [[a, b, c]]            # the game allows Ranked parties of 2 at most
        await self.queue([a])
        self.assertEqual(self.last(a)['status'], 'Idle')
        await self.queue([a], 'casual')
        self.assertEqual(self.last(a)['status'], 'Queued')  # Casual takes them
        self.mm = Matchmaker(self.app, ranked_size=2)       # 1 vs 1: no duos either
        self.mm.clients.update({u: self.ws[u] for u in (a, b)})
        self.app['social'].parties = [[a, b]]
        await self.queue([a])
        self.assertEqual(self.last(a)['status'], 'Idle')
        self.assertEqual(sum(e.get('mm') == 'ranked party too big' for e in self.logs), 2)


if __name__ == '__main__':
    unittest.main(verbosity=2)
