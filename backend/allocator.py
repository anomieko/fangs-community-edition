"""Ranked queue decision: which queued tickets play together, and on which team. Pure, no I/O.

Port of the user's matchmaking research allocator (queue-1.1), generalized from 4v4 to n vs n. It proposes
lobbies; the caller reserves them. Parties stay intact and on one team. Per lobby it requires:
- composition: mirrored party shapes first; uneven shapes open as the OLDEST ticket waits 60/180/300 s;
- skill bands: every ticket's mean within its own wait-earned band of the lobby centre, and the two teams'
  sorted players pairwise within twice the smaller band (100 rating units at first, 800 after 480 s);
- balance: the mean-strength favorite (with party context) at most 55%, widening to 70% with the YOUNGEST
  ticket's wait;
- provisional players: team counts differ by at most 1 (late: up to n after 300 s at a favorite <= 55%).
Among feasible lobbies of the lowest composition level it minimizes ((p - .5) / .1)^2 + .05 (span / 800)^2;
exact ties prefer fewer exact repeats of a player's last opponents, then ticket ids.

`widen_speed` scales the whole wait schedule (bands, favorite cap, composition, late placement): the research
uses 1; a small community gets the same fairness from a faster one (backend/tests/test_ranked.py, docs/recon/ranked.md).

Search is bounded (anchor = oldest ticket; 32 index neighbours each side; per-size quotas; 4 anchored teams per
shape; 64 opposing teams per anchored team and level), so its cost doesn't grow with the queue. Not modelled
here (no data for it): regions/latency, visible-tier party admission, several modes in one pool.
"""
from bisect import bisect_left
from collections import Counter
from dataclasses import dataclass
from functools import lru_cache
from itertools import combinations, product
from math import sqrt

import skill

MAX_PARTY = 4
WIDENING_SECONDS = (0.0, 60.0, 180.0, 300.0)    # composition level 0..3 opens after this wait


@dataclass(frozen=True)
class Ticket:
    ticket_id: str
    players: tuple          # skill.Rating, one per member
    joined_at: float

    @property
    def size(self):
        return len(self.players)

    @property
    def mean(self):
        return sum(p.rating for p in self.players) / self.size


@dataclass(frozen=True)
class Policy:
    team_size: int = 4
    composition_age_rule: str = 'oldest_ticket'      # 'all_tickets': the youngest must have waited (older control)
    provisional_late_age: float | None = 300.0
    provisional_late_favorite: float = 0.55
    provisional_late_max_difference: int | None = None   # None: the whole team
    max_provisional_difference: int = 1
    expiry_seconds: float | None = None              # search never expires (only for replaying older fixtures)
    index_radius: int = 32
    quotas: tuple = (9, 5, 5, 8)                     # nearby tickets kept per party size 1..4
    anchored_teams_per_shape: int = 4
    opposing_budget_per_level: int = 64
    widen_speed: float = 1.0          # how fast waiting earns wider limits: 2 = every limit reached in half the time


@dataclass(frozen=True)
class Proposal:
    team_a: tuple           # Tickets
    team_b: tuple
    probability: float      # mean-strength win chance of A (the launch gate)
    score: float
    composition_level: int
    youngest_wait: float
    oldest_wait: float
    context_a: float
    context_b: float
    frozen: skill.Frozen    # predicted_win_a: with uncertainty
    repeats: int


@lru_cache(maxsize=16)
def shapes(n):
    """Party-size layouts of one team (sorted tuples), mirrored first in the research's 4v4 order."""
    out = set()

    def parts(left, largest, acc):
        if left == 0:
            out.add(tuple(sorted(acc)))
        for s in range(min(left, largest), 0, -1):
            parts(left - s, s, acc + [s])
    parts(n, min(MAX_PARTY, n), [])
    return tuple(sorted(out, key=lambda s: (max(s), -len(s), s)))


def composition_level(shape_a, shape_b):
    """0 for mirrored shapes; otherwise the difference in party count (at least 1, at most 3). For 4v4 this is
    the research's matrix: 1+1+1+1 vs 4 is level 3, 2+2 vs 3+1 level 1, and so on."""
    return 0 if shape_a == shape_b else min(3, max(1, abs(len(shape_a) - len(shape_b))))


@lru_cache(maxsize=256)
def _split_indices(sizes, n):
    """Every way to put whole tickets into two teams of n (team A holds ticket 0, so each split appears once)."""
    result = []
    for k in range(1, len(sizes)):
        for other in combinations(range(1, len(sizes)), k - 1):
            ai = (0,) + other
            if sum(sizes[i] for i in ai) == n:
                result.append((ai, tuple(i for i in range(len(sizes)) if i not in ai)))
    return tuple(result)


@dataclass(frozen=True, slots=True)
class _TeamView:
    raw_sum: float
    context: float
    shape: tuple
    youngest_wait: float
    oldest_wait: float
    profile: tuple          # sorted (rating, player id, band)
    minimum_rating: float
    maximum_rating: float
    provisional_count: int
    player_ids: frozenset


def allocate(tickets, now, policy=Policy(), previous_opponents=None, counts=None):
    """Disjoint lobbies [Proposal] for live tickets at time `now`; nothing is mutated or reserved.
    previous_opponents: player id -> frozenset of their last ranked opponents (exact-tie breaker only).
    counts: optional Counter that receives search diagnostics."""
    n = policy.team_size
    late_max = n if policy.provisional_late_max_difference is None else policy.provisional_late_max_difference
    counts = Counter() if counts is None else counts
    eligible = [t for t in tickets
                if policy.expiry_seconds is None or now - t.joined_at < policy.expiry_seconds]
    for t in eligible:
        if not 1 <= t.size <= min(MAX_PARTY, n) or t.joined_at > now:
            raise ValueError(f'ticket {t.ticket_id}: bad size or join time')
    history = {p: frozenset(o) for p, o in (previous_opponents or {}).items()}
    all_shapes = shapes(n)
    values = {t.ticket_id: t.mean + skill.PARTY_CONTEXT[t.size - 1] for t in eligible}   # effective strength
    ages = {t.ticket_id: (now - t.joined_at) * policy.widen_speed for t in eligible}   # earned wait
    sizes = {t.ticket_id: t.size for t in eligible}
    raw_sums = {t.ticket_id: sum(p.rating for p in t.players) for t in eligible}
    means = {t.ticket_id: raw_sums[t.ticket_id] / sizes[t.ticket_id] for t in eligible}
    bands = {t.ticket_id: skill.player_band(ages[t.ticket_id]) for t in eligible}
    intervals = {i: (means[i] - bands[i], means[i] + bands[i]) for i in means}
    caps = {age: skill.favorite_cap(age) for age in ages.values()}
    probability_scale = skill.PERFORMANCE_NOISE / sqrt(n / 2.0)
    provisional = {t.ticket_id: sum(skill.is_provisional(p) for p in t.players) for t in eligible}
    team_views, assignment_cache = {}, {}

    def team_view(team):
        key = tuple(t.ticket_id for t in team)
        view = team_views.get(key)
        if view is None:
            shape = tuple(sorted(sizes[i] for i in key))
            ratings = [p.rating for t in team for p in t.players]
            view = team_views[key] = _TeamView(
                sum(raw_sums[i] for i in key), sum(s * skill.PARTY_CONTEXT[s - 1] for s in shape) / n, shape,
                min(ages[i] for i in key), max(ages[i] for i in key),
                tuple(sorted((p.rating, p.player_id, bands[t.ticket_id]) for t in team for p in t.players)),
                min(ratings), max(ratings), sum(provisional[i] for i in key),
                frozenset(p.player_id for t in team for p in t.players))
        return view

    def interval(team):
        return max(intervals[t.ticket_id][0] for t in team), min(intervals[t.ticket_id][1] for t in team)

    def team_distance(team, target):
        return abs(sum(sizes[t.ticket_id] * values[t.ticket_id] for t in team) / n - target)

    def candidate_teams(candidates, shape, target, anchor=None):
        needed = Counter(shape)
        if anchor is not None:
            if not needed[anchor.size]:
                return []
            needed[anchor.size] -= 1
        options = []
        for size, k in sorted(needed.items()):
            if not k:
                continue
            bucket = [t for t in candidates if t.size == size]
            if len(bucket) < k:
                return []
            options.append(tuple(combinations(bucket, k)))
        result = []
        for selected in product(*options):
            team = ((anchor,) if anchor is not None else ()) + tuple(t for part in selected for t in part)
            counts['constructed_teams'] += 1
            lo, hi = interval(team)
            if lo <= hi:
                result.append(team)
        return sorted(result, key=lambda team: (team_distance(team, target), tuple(t.ticket_id for t in team)))

    def check(a, b, level):
        """None, or (probability, score, youngest, oldest, context A, context B, repeats) if every gate passes."""
        counts['assignment_gate_checks'] += 1
        va, vb = team_view(a), team_view(b)
        if composition_level(va.shape, vb.shape) != level:
            return None
        youngest, oldest = min(va.youngest_wait, vb.youngest_wait), max(va.oldest_wait, vb.oldest_wait)
        if (youngest if policy.composition_age_rule == 'all_tickets' else oldest) < WIDENING_SECONDS[level]:
            counts['blocked_composition_age'] += 1
            return None
        selected = a + b
        centre = sum(raw_sums[t.ticket_id] for t in selected) / (2 * n)
        if any(abs(means[t.ticket_id] - centre) > bands[t.ticket_id] for t in selected):
            counts['blocked_ticket_band'] += 1
            return None
        if any(abs(x[0] - y[0]) > 2 * min(x[2], y[2]) for x, y in zip(va.profile, vb.profile)):
            counts['blocked_profile_band'] += 1
            return None
        margin = (va.raw_sum - vb.raw_sum) / n + va.context - vb.context
        probability = skill.normal_cdf(margin / probability_scale)
        favorite = max(probability, 1.0 - probability)
        if favorite > caps[youngest] + 1e-12:
            counts['blocked_favorite'] += 1
            return None
        allowed_gap = policy.max_provisional_difference
        if (policy.provisional_late_age is not None and oldest >= policy.provisional_late_age
                and favorite <= policy.provisional_late_favorite + 1e-12):
            allowed_gap = max(allowed_gap, late_max)
        if abs(va.provisional_count - vb.provisional_count) > allowed_gap:
            counts['blocked_provisional'] += 1
            return None
        span = max(va.maximum_rating, vb.maximum_rating) - min(va.minimum_rating, vb.minimum_rating)
        score = ((probability - 0.5) / 0.1) ** 2 + 0.05 * (span / 800.0) ** 2
        repeats = sum(history.get(p) == vb.player_ids for p in va.player_ids) \
            + sum(history.get(p) == va.player_ids for p in vb.player_ids)
        return probability, score, youngest, oldest, va.context, vb.context, repeats

    def assign(selected, level):
        """Best legal team split of these 2n players' tickets at this composition level (cached per call)."""
        ordered = tuple(sorted(selected, key=lambda t: t.ticket_id))
        ids = tuple(t.ticket_id for t in ordered)
        if (level, ids) in assignment_cache:
            counts['assignment_cache_hits'] += 1
            return assignment_cache[level, ids]
        counts['candidate_sets_evaluated'] += 1
        best = None
        for ai, bi in _split_indices(tuple(sizes[i] for i in ids), n):
            a, b = tuple(ordered[i] for i in ai), tuple(ordered[i] for i in bi)
            quality = check(a, b, level)
            if quality is not None:
                key = quality[1], quality[6], ids, tuple(t.ticket_id for t in a)
                if best is None or key < best[0]:
                    best = key, a, b, quality
        assignment_cache[level, ids] = best
        return best

    buckets = {size: sorted((t for t in eligible if t.size == size), key=lambda t: (values[t.ticket_id], t.ticket_id))
               for size in range(1, MAX_PARTY + 1)}
    keys = {size: tuple((values[t.ticket_id], t.ticket_id) for t in bucket) for size, bucket in buckets.items()}
    used, proposals = set(), []
    for anchor in sorted(eligible, key=lambda t: (t.joined_at, t.ticket_id)):
        if anchor.ticket_id in used:
            continue
        counts['anchors_examined'] += 1
        best = None
        for level, required_wait in enumerate(WIDENING_SECONDS):
            if ages[anchor.ticket_id] < required_wait:
                break
            counts['levels_examined'] += 1
            lo, hi = interval((anchor,))
            nearby = []
            for size in range(1, MAX_PARTY + 1):
                pos = bisect_left(keys[size], (values[anchor.ticket_id], anchor.ticket_id))
                possible = []
                for t in buckets[size][max(0, pos - policy.index_radius):pos + policy.index_radius + 1]:
                    counts['index_entries_examined'] += 1
                    if t.ticket_id in used or t.ticket_id == anchor.ticket_id:
                        continue
                    if policy.composition_age_rule == 'all_tickets' and ages[t.ticket_id] < required_wait:
                        continue
                    other_lo, other_hi = interval((t,))
                    if max(lo, other_lo) > min(hi, other_hi):
                        continue
                    if anchor.size == size == n and check((anchor,), (t,), level) is None:
                        continue
                    possible.append(t)
                possible.sort(key=lambda t: (abs(values[t.ticket_id] - values[anchor.ticket_id]), t.joined_at,
                                             t.ticket_id))
                nearby.extend(possible[:policy.quotas[size - 1]])
            if sum(t.size for t in nearby) + anchor.size < 2 * n:
                continue
            for shape in all_shapes:
                if anchor.size not in shape:
                    continue
                for a in candidate_teams(nearby, shape, values[anchor.ticket_id], anchor)[:policy.anchored_teams_per_shape]:
                    own = {t.ticket_id for t in a}
                    others = [t for t in nearby if t.ticket_id not in own]
                    target = sum(t.size * values[t.ticket_id] for t in a) / n
                    opposing = [s for s in all_shapes if composition_level(shape, s) == level]
                    budget = policy.opposing_budget_per_level // len(opposing) if opposing else 0
                    for opposing_shape in opposing:
                        for b in candidate_teams(others, opposing_shape, target)[:budget]:
                            counts['proposed_candidates'] += 1
                            found = assign(a + b, level)
                            if found is not None and (best is None or found[0] < best[0]):
                                best = found
            if best is not None:
                break       # the lowest feasible composition level wins
        if best is None:
            counts['bounded_anchor_misses'] += 1
            continue
        _, a, b, (probability, score, youngest, oldest, ca, cb, repeats) = best
        frozen = skill.freeze([p for t in a for p in t.players], [p for t in b for p in t.players], ca, cb)
        proposals.append(Proposal(a, b, probability, score, composition_level(team_view(a).shape, team_view(b).shape),
                                  youngest, oldest, ca, cb, frozen, repeats))
        used.update(t.ticket_id for t in a + b)
    counts['matches'] = len(proposals)
    return proposals
