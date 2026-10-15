"""Ranked rating + queue tests (stdlib only, no game, no network).

    python3 -I backend/tests/test_ranked.py            # or: python3 -I -m unittest backend/tests/test_ranked.py -v

With the user's matchmaking research checked out next to this repo (or ELOMMR_DIR=<path>), it also replays that
handoff's own fixtures (rating examples, party example, the 71 dev-queue scenarios) through backend/skill.py and
backend/allocator.py; nothing from it is copied into this repo.
"""
import json
import math
import os
import random
import sys
import time
import unittest
from itertools import combinations
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'backend'))
import allocator  # noqa: E402
import skill      # noqa: E402

ELOMMR = Path(os.environ.get('ELOMMR_DIR', REPO.parent / 'elommr'))
HAVE_ELOMMR = (ELOMMR / 'AGENTS' / 'dev_queue_scenarios.json').exists()


def R(pid, rating=1500.0, sigma=170.0, played=200, **kw):
    return skill.Rating(pid, float(rating), float(sigma), played, **kw)


def solos(ratings, joined=0.0, prefix='p', **kw):
    return [allocator.Ticket(f'{prefix}{i:03d}', (R(f'{prefix}{i:03d}', r, **kw),), joined) for i, r in enumerate(ratings)]


# ------------------------------------------------------------ independent gate oracle (written rules, n vs n)

def oracle_band(age):
    pts = ((0, 100), (60, 100), (180, 200), (300, 400), (480, 800))
    for (t0, v0), (t1, v1) in zip(pts, pts[1:]):
        if age <= t1:
            return v0 + (v1 - v0) * (age - t0) / (t1 - t0)
    return 800.0


def oracle_cap(age):
    if age <= 60: return .55
    if age <= 300: return .55 + .05 * (age - 60) / 240
    return min(.70, .60 + .10 * (age - 300) / 180)


def oracle_legal(a, b, now, n, late=True):
    """Every launch gate from the written rules, without allocator helpers."""
    ts = list(a) + list(b)
    players = [p for t in ts for p in t.players]
    if len({p.player_id for p in players}) != 2 * n: return False
    if sum(t.size for t in a) != n or sum(t.size for t in b) != n: return False
    sa, sb = sorted(t.size for t in a), sorted(t.size for t in b)
    level = 0 if sa == sb else min(3, max(1, abs(len(sa) - len(sb))))
    if now - min(t.joined_at for t in ts) < (0, 60, 180, 300)[level]: return False
    centre = sum(p.rating for p in players) / (2 * n)
    if any(abs(t.mean - centre) > oracle_band(now - t.joined_at) + 1e-9 for t in ts): return False
    prof = lambda team: sorted((p.rating, p.player_id, now - t.joined_at) for t in team for p in t.players)
    if any(abs(x[0] - y[0]) > 2 * min(oracle_band(x[2]), oracle_band(y[2])) + 1e-9 for x, y in zip(prof(a), prof(b))):
        return False
    gamma = (0, 60, 100, 140)
    strength = lambda team: sum(p.rating for t in team for p in t.players) / n + sum(t.size * gamma[t.size - 1] for t in team) / n
    p = .5 * math.erfc(-(strength(a) - strength(b)) / (400 * math.sqrt(2 / n)) / math.sqrt(2))
    fav = max(p, 1 - p)
    if fav > oracle_cap(min(now - t.joined_at for t in ts)) + 1e-9: return False
    prov = lambda team: sum(q.played < 10 or q.uncertainty > 350 for t in team for q in t.players)
    gap = abs(prov(a) - prov(b))
    return gap <= 1 or (late and now - min(t.joined_at for t in ts) >= 300 and fav <= .55 + 1e-12)


def oracle_cost(a, b, n):
    gamma = (0, 60, 100, 140)
    strength = lambda team: sum(p.rating for t in team for p in t.players) / n + sum(t.size * gamma[t.size - 1] for t in team) / n
    p = .5 * math.erfc(-(strength(a) - strength(b)) / (400 * math.sqrt(2 / n)) / math.sqrt(2))
    rs = [q.rating for t in list(a) + list(b) for q in t.players]
    return ((p - .5) / .1) ** 2 + .05 * ((max(rs) - min(rs)) / 800) ** 2


# ------------------------------------------------------------ rating arithmetic

class RatingMath(unittest.TestCase):
    def test_published_4v4_table(self):
        """The research's worked table: all sigma 170, A at 1500 against B's mean."""
        for b_mean, win, loss, p in ((1500, 19.00, -19.00, .5), (1535, 20.75, -17.31, .4547),
                                     (1600, 24.18, -14.36, .3726), (1700, 29.82, -10.36, .2578)):
            f = skill.freeze([R(f'a{i}') for i in range(4)], [R(f'b{i}', b_mean) for i in range(4)])
            self.assertAlmostEqual(f.predicted_win_a, p, places=4)
            self.assertAlmostEqual(skill.settle(f, 'A')[0].rating - 1500, win, places=2)
            self.assertAlmostEqual(skill.settle(f, 'B')[0].rating - 1500, loss, places=2)

    def test_newcomer_moves_more(self):
        f = skill.freeze([skill.Rating('new')] + [R(f'a{i}') for i in range(3)], [R(f'b{i}') for i in range(4)])
        after = skill.settle(f, 'A')
        self.assertAlmostEqual(after[0].rating - 1500, 124.37, places=2)
        self.assertAlmostEqual(after[1].rating - 1500, 18.00, places=2)

    def test_n_vs_n_is_consistent(self):
        """Same mean gap is more decisive with more players per side (as in TrueSkill); equal sigmas: zero-sum."""
        chances = []
        for n in (1, 2, 3, 4, 5, 6):
            f = skill.freeze([R(f'a{i}', 1550) for i in range(n)], [R(f'b{i}') for i in range(n)])
            chances.append(f.balance_win_a)
            after = skill.settle(f, 'B')
            self.assertAlmostEqual(sum(p.rating for p in after) - 1500 * 2 * n - 50 * n, 0.0, places=9)
            self.assertTrue(all(p.uncertainty < math.sqrt(170 ** 2 + 20 ** 2) for p in after))
        self.assertEqual(chances, sorted(chances))
        self.assertAlmostEqual(skill.freeze([R('a')], [R('b')]).scale, math.sqrt(2 * 400 ** 2 + 2 * (170 ** 2 + 400)))

    def test_extreme_upset_is_finite(self):
        f = skill.freeze([R(f'a{i}', 3500, 20) for i in range(4)], [R(f'b{i}', 0, 20) for i in range(4)])
        for p in skill.settle(f, 'B'):
            self.assertTrue(math.isfinite(p.rating) and p.uncertainty > 0)

    def test_display_keeps_the_games_scale(self):
        self.assertEqual(skill.display(skill.Rating('x')), {'mu': 25.0, 'sigma': 8.3333})
        r = skill.Rating.from_json('x', skill.Rating('x', 1608.0, 270.0, 12).to_json())
        self.assertEqual(skill.display(r), {'mu': 27.0, 'sigma': 5.0})

    @unittest.skipUnless(HAVE_ELOMMR, 'research handoff not found')
    def test_research_rating_examples(self):
        data = json.loads((ELOMMR / 'AGENTS' / 'rating_examples.json').read_text())
        tol = data['absolute_tolerances']
        fields = ('player_id', 'rating', 'uncertainty', 'played', 'recent_residual', 'recent_variance', 'evidence_games')
        load = lambda ps: [skill.Rating(**{k: p[k] for k in fields}) for p in ps]
        for ex in data['examples']:
            with self.subTest(ex['name']):
                f = skill.freeze(load(ex['input']['team_a']), load(ex['input']['team_b']))
                e = ex['expected']
                self.assertEqual(list(f.variances), e['prepared_variances'])
                self.assertEqual(list(f.reopened), e['calibration_reopened'])
                for k in ('margin', 'scale', 'predicted_win_a', 'balance_win_a'):
                    self.assertAlmostEqual(getattr(f, k), e[k], delta=tol['probability'])
                for got, want in zip(skill.settle(f, ex['input']['winner']), e['after']):
                    for k in ('rating', 'uncertainty', 'recent_residual', 'recent_variance'):
                        self.assertAlmostEqual(getattr(got, k), want[k], delta=tol[k])
                    self.assertEqual((got.played, got.evidence_games), (want['played'], want['evidence_games']))

    @unittest.skipUnless(HAVE_ELOMMR, 'research handoff not found')
    def test_research_party_example(self):
        data = json.loads((ELOMMR / 'AGENTS' / 'party_examples.json').read_text())
        for ex in data['shape_context_examples']:
            self.assertEqual(skill.team_context(ex['shape'], 4), ex['team_context'])
        wm = data['worked_match']
        f = skill.freeze([R(f'a{i}', wm['a']['each_rating']) for i in range(4)],
                         [R(f'b{i}', wm['b']['each_rating']) for i in range(4)],
                         skill.team_context(wm['a']['parties'], 4), skill.team_context(wm['b']['parties'], 4))
        e = wm['expected']
        self.assertAlmostEqual(f.margin, e['margin'])
        self.assertAlmostEqual(f.scale, e['scale'], places=9)
        after = skill.settle(f, e['winner'])
        self.assertAlmostEqual(after[0].rating, e['each_a_new_rating'], places=6)
        self.assertAlmostEqual(after[4].rating, e['each_b_new_rating'], places=6)


# ------------------------------------------------------------ queue decision

class Allocator(unittest.TestCase):
    def test_shapes_and_composition_match_the_research_4v4_matrix(self):
        self.assertEqual(allocator.shapes(4), ((1, 1, 1, 1), (1, 1, 2), (2, 2), (1, 3), (4,)))
        matrix = ((0, 1, 2, 2, 3), (1, 0, 1, 1, 2), (2, 1, 0, 1, 1), (2, 1, 1, 0, 1), (3, 2, 1, 1, 0))
        s = allocator.shapes(4)
        for i in range(5):
            for j in range(5):
                self.assertEqual(allocator.composition_level(s[i], s[j]), matrix[i][j])
        self.assertEqual(allocator.shapes(2), ((1, 1), (2,)))
        self.assertEqual(len(allocator.shapes(6)), 9)    # partitions of 6 into parts <= 4

    def test_balanced_split_and_parties_stay_together(self):
        ts = solos([1300, 1350, 1450, 1500, 1500, 1550, 1650, 1700])
        self.assertEqual(allocator.allocate(ts, 0.0), [])    # 1300 is 200 from the centre; the band starts at 100
        (m,) = allocator.allocate(solos([1420, 1450, 1480, 1500, 1500, 1520, 1550, 1580]), 0.0)
        self.assertLess(abs(m.probability - .5), .01)
        duo = allocator.Ticket('duo', (R('d1', 1500), R('d2', 1500)), 0.0)
        (m,) = allocator.allocate([duo] + solos([1500] * 8), 0.0)   # 8 solos play mirrored at once, the duo waits
        self.assertNotIn(duo, m.team_a + m.team_b)
        ts = [duo] + solos([1500] * 6)
        self.assertEqual(allocator.allocate(ts, 59.0), [])   # a duo + 6 solos: 2+1+1 vs 1+1+1+1 is level 1
        (m,) = allocator.allocate(ts, 60.0)
        self.assertEqual(m.composition_level, 1)
        self.assertTrue(duo in m.team_a or duo in m.team_b)
        ts = [duo, allocator.Ticket('duo2', (R('e1'), R('e2')), 0.0)] + solos([1500] * 4)
        (m,) = allocator.allocate(ts, 0.0)     # mirrored 2+1+1 vs 2+1+1 at once
        self.assertEqual(m.composition_level, 0)
        self.assertNotEqual(duo in m.team_a, any(t.ticket_id == 'duo2' for t in m.team_a))

    def test_wait_widening(self):
        ts = solos([1000, 1100, 1200, 1300, 1400, 1500, 1600, 1700])
        self.assertEqual(allocator.allocate(ts, 100.0), [])
        first = next(t for t in range(0, 600) if allocator.allocate(ts, float(t)))
        self.assertEqual(first, 270)    # the research's small-pool table: centre band reaches 350
        fast = allocator.Policy(widen_speed=2.0)
        self.assertEqual(next(t for t in range(0, 600) if allocator.allocate(ts, float(t), fast)), 135)
        self.assertEqual(allocator.allocate(solos([1500] * 7 + [2400]), 5000.0), [])   # 70% cap never opens

    def test_random_pools_obey_every_gate(self):
        """n = 2, 3, 4: every proposal passes the written gates; with exactly 2n solos the best legal split is found."""
        rng = random.Random(7)
        for n in (2, 3, 4):
            pol = allocator.Policy(team_size=n)
            for _ in range(150):
                k = rng.randint(2 * n, 3 * n)
                ts = []
                for i in range(k):
                    size = 1 if rng.random() < .75 else rng.randint(2, min(4, n))
                    ts.append(allocator.Ticket(f't{i:02d}', tuple(R(f't{i:02d}m{j}', rng.gauss(1500, 220), rng.choice((170, 400)),
                                                                     rng.choice((3, 50))) for j in range(size)),
                                               float(rng.randint(0, 500))))
                now = 520.0
                for m in allocator.allocate(ts, now, pol):
                    self.assertTrue(oracle_legal(m.team_a, m.team_b, now, n), (n, m))
                exact = solos([rng.gauss(1500, 120) for _ in range(2 * n)], joined=float(rng.randint(0, 400)))
                legal = [oracle_cost(a, [t for t in exact if t not in a], n)
                         for a in combinations(exact, n) if exact[0] in a
                         and oracle_legal(a, [t for t in exact if t not in a], now, n)]
                got = allocator.allocate(exact, now, pol)
                self.assertEqual(bool(got), bool(legal))
                if got:
                    self.assertAlmostEqual(got[0].score, min(legal), places=9)

    @unittest.skipUnless(HAVE_ELOMMR, 'research handoff not found')
    def test_research_dev_queue_fixtures(self):
        data = json.loads((ELOMMR / 'AGENTS' / 'dev_queue_scenarios.json').read_text())
        p = data['canonical_policy']
        pol = allocator.Policy(composition_age_rule=p['composition_age_rule'],
                               provisional_late_age=p['provisional_late_age'], expiry_seconds=p['expiry_seconds'])
        self.assertEqual(len(data['fixtures']), 71)
        for case in data['fixtures']:
            with self.subTest(case['name']):
                replay_fixture(self, case, pol)


def replay_fixture(test, case, pol):
    """The research's replay loop (1 s ticks), with this repo's allocator; region/mode pools and the
    latency / visible-tier admission it has (and we don't) applied here."""
    fields = ('player_id', 'rating', 'uncertainty', 'played', 'recent_residual', 'recent_variance', 'evidence_games')
    pending, rejected = {}, []
    for d in case['tickets']:
        members = d['members']
        tiers = [m['visible_major_tier'] for m in members if m['visible_major_tier'] is not None]
        tid = str(d['ticket_id']).zfill(4)
        t = allocator.Ticket(tid, tuple(skill.Rating(**{k: m[k] for k in fields if k in m}) for m in members), d['joined_at'])
        if any(m['rtt_ms'] > 100 for m in members) or (d['mode'] == 'ranked' and tiers and max(tiers) - min(tiers) > 2):
            rejected.append(tid)
        else:
            pending[tid] = (t, (d['region'], d['mode']))
    last_join = max((t.joined_at for t, _ in pending.values()), default=0)
    deadline = math.ceil(case.get('observation_seconds', last_join + 1800))
    pool, matches = {}, []
    for now in range(deadline + 1):
        for tid, (t, key) in list(pending.items()):
            if t.joined_at <= now:
                pool[tid] = pending.pop(tid)
        if sum(t.size for t, _ in pool.values()) < 8:
            continue
        for key in sorted({k for _, k in pool.values()}):
            for m in allocator.allocate([t for t, k in pool.values() if k == key], float(now), pol):
                test.assertTrue(oracle_legal(m.team_a, m.team_b, now, 4, late=pol.provisional_late_age is not None))
                matches.append((now, [t.ticket_id for t in m.team_a + m.team_b]))
                for t in m.team_a + m.team_b:
                    del pool[t.ticket_id]
        if not pending and not pool:
            break
    expected = case.get('expected')
    if expected:
        test.assertEqual(len(matches), expected['matches'], matches)
        if 'times' in expected:
            test.assertEqual([at for at, _ in matches], expected['times'])
        for ident, at in expected.get('ticket_match_times', {}).items():
            test.assertEqual([t for t, ids in matches if str(ident).zfill(4) in ids], [at])


# ------------------------------------------------------------ a small community, simulated

def simulate(players=24, sessions=400, seed=3, policy=allocator.Policy()):
    """Players with hidden true skills queue Ranked in small, irregular groups (8-14 per session, joining over two
    minutes, giving up after 15). Games are decided by the true skills under the same Gaussian performance model;
    ratings start at 1500 / 450. Returns per-game and per-player measurements."""
    rng = random.Random(seed)
    true = {f'u{i:02d}': rng.gauss(1500, 300) for i in range(players)}
    state = {u: skill.Rating(u) for u in true}
    true_win = lambda a, b: skill.normal_cdf((sum(true[u] for u in a) - sum(true[u] for u in b)) / 4 / (400 / math.sqrt(2)))
    games, waits, casual_waits, empty_sessions = [], [], [], 0
    for session in range(sessions):
        joined = {u: rng.uniform(0, 120) for u in rng.sample(sorted(true), rng.randint(8, 14))}
        order = sorted(joined, key=joined.get)
        casual_a, casual_b = order[:4], order[4:8]          # Casual: the first eight, teams as they come
        casual_waits += [joined[order[7]] - joined[u] for u in order[:8]]
        waiting, played = dict(joined), len(games)
        for now in range(0, 901, 5):
            pool = [allocator.Ticket(u, (state[u],), t) for u, t in waiting.items() if t <= now]
            for m in allocator.allocate(pool, float(now), policy):
                a = [t.ticket_id for t in m.team_a]
                b = [t.ticket_id for t in m.team_b]
                p = true_win(a, b)
                after = skill.settle(m.frozen, 'A' if rng.random() < p else 'B')
                for r in after:
                    state[r.player_id] = r
                for u in a + b:
                    waits.append(now - waiting.pop(u))
                games.append({'session': session, 'true_fav': max(p, 1 - p), 'predicted': m.frozen.predicted_win_a,
                              'true_p': p, 'casual_fav': max(true_win(casual_a, casual_b), 1 - true_win(casual_a, casual_b))})
        empty_sessions += len(games) == played
    return true, state, games, waits, casual_waits, empty_sessions


def pearson(xs, ys):
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    return sxy / math.sqrt(sum((x - mx) ** 2 for x in xs) * sum((y - my) ** 2 for y in ys))


class Community(unittest.TestCase):
    def test_ratings_converge_and_ranked_games_are_fairer(self):
        true, state, games, waits, casual_waits, empty = simulate()
        late = [g for g in games if g['session'] >= 200]
        corr = pearson([true[u] for u in true], [state[u].rating for u in true])
        ranked_fav = sum(g['true_fav'] for g in late) / len(late)
        casual_fav = sum(g['casual_fav'] for g in late) / len(late)
        med = lambda xs, q=.5: round(sorted(xs)[int(len(xs) * q)])
        print(f"\n  24 players, 400 sessions of 8-14: {len(games)} ranked games, {empty} sessions without one; "
              f"rating vs true skill r = {corr:.3f}; true favorite's win chance (last 200 sessions): "
              f"ranked {ranked_fav:.3f}, casual {casual_fav:.3f}; wait median / 90%: ranked {med(waits)} / "
              f"{med(waits, .9)} s, casual {med(casual_waits)} / {med(casual_waits, .9)} s", file=sys.stderr)
        self.assertGreater(corr, 0.8)
        self.assertLess(ranked_fav, casual_fav - 0.05)
        self.assertLess(empty, 20)


# ------------------------------------------------------------ cost on a small server

class Cost(unittest.TestCase):
    def test_decision_time(self):
        """One queue decision (the matchmaker makes at most one per second, only with >= 2n ranked players)."""
        rng = random.Random(1)
        worst = {}
        for players in (8, 12, 16, 24, 40):
            for now in (30.0, 200.0, 650.0):     # oldest ticket's wait: bands and composition levels open up
                ts, i = [], 0
                while sum(t.size for t in ts) < players:
                    size = 2 if rng.random() < .3 else 1
                    ts.append(allocator.Ticket(f't{i:03d}', tuple(R(f't{i}m{j}', rng.gauss(1500, 300)) for j in range(size)),
                                               now - rng.uniform(0, now)))
                    i += 1
                t0 = time.perf_counter()
                allocator.allocate(ts, now)
                worst[players] = max(worst.get(players, 0), (time.perf_counter() - t0) * 1000)
        print('\n  allocate() worst ms per decision by ranked players queued:',
              ', '.join(f'{k}: {v:.1f}' for k, v in worst.items()), file=sys.stderr)
        self.assertLess(worst[16], 250)


if __name__ == '__main__':
    unittest.main(verbosity=2)
