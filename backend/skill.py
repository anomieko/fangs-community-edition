"""Ranked skill ratings: a Gaussian team model (TrueSkill-style, with TrueSkill 2's party offset).

Pure functions, no I/O. Ported from the user's matchmaking research handoff (rating arithmetic 0.5, confidence
reopening 0.9, party context 0.5, quality widening 0.8) and generalized from 4v4 to n vs n.

Model: each player's skill s ~ N(mu, q = sigma^2); a team performs as the AVERAGE of its n players' performances
(s + noise, noise ~ N(0, beta^2)) plus a party-context offset. The winner is the team with the higher performance;
no draws. Before a game the variance gets process noise (tau); a confident player whose recent results keep
missing the prediction is reopened to sigma 300. After the game all 2n players are updated from the same frozen
snapshot. Rating units: new players 1500 / 450; the game's own 25 / 8.33 scale is only for display.

Equations (n players per side, a_i = +1/n on A, -1/n on B, b_A/b_B the party contexts):
    d = sum a_i mu_i + b_A - b_B          c^2 = 2 beta^2 / n + sum a_i^2 q_i         p_A = Phi(d / c)
    t = y d / c,  v = phi(t) / Phi(t),  w = v (v + t)    (y = +1 if A won, -1 if B won)
    mu_i' = mu_i + y a_i q_i v / c        q_i' = q_i (1 - a_i^2 q_i w / c^2)
For n = 4 this is exactly the research's 4v4 arithmetic (its fixtures pass: backend/tests/test_ranked.py).
"""
from dataclasses import dataclass, replace
from math import erfc, exp, isfinite, pi, sqrt

INITIAL_RATING, INITIAL_UNCERTAINTY = 1500.0, 450.0
PERFORMANCE_NOISE = 400.0      # beta: per-player performance noise
ADAPTATION_NOISE = 20.0        # tau: per-game process noise (skill can change)
MAX_UNCERTAINTY, MIN_VARIANCE = 450.0, 1.0
EVIDENCE_DECAY = 0.9           # discount of past prediction errors (half-life ~6.6 games)
EVIDENCE_SCORE, EVIDENCE_GAMES = 3.0, 20
REOPEN_UNCERTAINTY, REOPEN_IF_BELOW = 300.0, 225.0
PROVISIONAL_PLAYED, PROVISIONAL_UNCERTAINTY = 10, 350.0

# Party context: per-member rating units by party size (1..4). A team's offset is sum(size * value) / n. These are
# the research's uncalibrated playtest hypotheses (party-size-hypothesis-0.5), never added to stored ratings.
PARTY_CONTEXT = (0.0, 60.0, 100.0, 140.0)

# Wait-earned quality limits (quality-widening-0.8): (seconds waited, value), linear between points.
BAND_POINTS = ((0., 100.), (60., 100.), (180., 200.), (300., 400.), (480., 800.))
FAVORITE_POINTS = ((0., .55), (60., .55), (300., .60), (480., .70))

# Display on the game's scale (BP_AC_MatchReport defaults mu 25, sigma 8.333): a new player shows 25 / 8.333,
# so the profile's rank points 90 * (mu - 2 sigma) start where they always did (750).
DISPLAY_SCALE = INITIAL_UNCERTAINTY / (25.0 / 3.0)    # 54 rating units per display unit


@dataclass(frozen=True)
class Rating:
    player_id: str
    rating: float = INITIAL_RATING
    uncertainty: float = INITIAL_UNCERTAINTY    # a standard deviation, not a variance
    played: int = 0
    recent_residual: float = 0.0                # discounted sum of (result - predicted win chance)
    recent_variance: float = 0.0                # discounted sum of p (1 - p)
    evidence_games: int = 0                     # games since the last reopening

    def to_json(self):
        return {'rating': self.rating, 'uncertainty': self.uncertainty, 'played': self.played,
                'recent_residual': self.recent_residual, 'recent_variance': self.recent_variance,
                'evidence_games': self.evidence_games}

    @classmethod
    def from_json(cls, player_id, d):
        d = d or {}
        return cls(player_id, float(d.get('rating', INITIAL_RATING)), float(d.get('uncertainty', INITIAL_UNCERTAINTY)),
                   int(d.get('played', 0)), float(d.get('recent_residual', 0.0)), float(d.get('recent_variance', 0.0)),
                   int(d.get('evidence_games', 0)))


def display(r):
    """{'mu', 'sigma'} on the game's scale, for PROFILE_RATINGS_KEY and the leaderboard."""
    return {'mu': round(25.0 + (r.rating - INITIAL_RATING) / DISPLAY_SCALE, 4),
            'sigma': round(r.uncertainty / DISPLAY_SCALE, 4)}


def is_provisional(r):
    """Placement protection: fewer than 10 games or still very uncertain."""
    return r.played < PROVISIONAL_PLAYED or r.uncertainty > PROVISIONAL_UNCERTAINTY


def normal_cdf(x):
    return 0.5 * erfc(-x / sqrt(2.0))


def normal_pdf(x):
    return exp(-0.5 * x * x) / sqrt(2.0 * pi)


def surprise_terms(t):
    """v = phi(t)/Phi(t) and w = v (v + t), clamped to [0, 1]; an asymptotic series below -8 (no underflow)."""
    if t < -8.0:
        x = -t
        v = x + 1 / x - 2 / x ** 3 + 10 / x ** 5 - 74 / x ** 7 + 706 / x ** 9
    else:
        v = normal_pdf(t) / normal_cdf(t)
    return v, min(1.0, max(0.0, v * (v + t)))


def prepare_variance(r):
    """Variance used for this game (process noise, or reopening on strong past evidence) and whether it reopened.
    Pure: nothing is stored until the result is settled."""
    q = min(MAX_UNCERTAINTY ** 2, r.uncertainty ** 2 + ADAPTATION_NOISE ** 2)
    score = abs(r.recent_residual) / sqrt(max(r.recent_variance, 0.25))
    reopen = r.evidence_games >= EVIDENCE_GAMES and q < REOPEN_IF_BELOW ** 2 and score >= EVIDENCE_SCORE
    return (max(q, REOPEN_UNCERTAINTY ** 2) if reopen else q), reopen


def team_context(party_sizes, team_size):
    """Party-context offset of one team in rating units: sum(size * per-member value) / n."""
    return sum(s * PARTY_CONTEXT[s - 1] for s in party_sizes) / team_size


def mean_win_chance(margin, team_size):
    """Mean-strength win chance (no uncertainty): the launch gate, never the settlement probability."""
    return normal_cdf(margin / (PERFORMANCE_NOISE / sqrt(team_size / 2.0)))


def at_wait(seconds, points):
    for (t0, v0), (t1, v1) in zip(points, points[1:]):
        if seconds <= t1:
            return v0 + (seconds - t0) / (t1 - t0) * (v1 - v0)
    return points[-1][1]


def player_band(wait):
    """How far (rating units) a ticket's mean may sit from the lobby centre after waiting `wait` seconds."""
    return at_wait(wait, BAND_POINTS)


def favorite_cap(youngest_wait):
    """Highest mean-strength win chance allowed for either team; the youngest ticket's wait sets it."""
    return at_wait(youngest_wait, FAVORITE_POINTS)


@dataclass(frozen=True)
class Frozen:
    """A pre-game snapshot: everything settlement needs, computed once."""
    team_a: tuple
    team_b: tuple
    variances: tuple       # prepared variances, team A then team B
    reopened: tuple
    margin: float
    scale: float
    predicted_win_a: float  # with uncertainty: prediction and settlement
    balance_win_a: float    # means only: the launch gate
    context_a: float = 0.0
    context_b: float = 0.0


def freeze(team_a, team_b, context_a=0.0, context_b=0.0):
    team_a, team_b = tuple(team_a), tuple(team_b)
    n = len(team_a)
    if n < 1 or len(team_b) != n:
        raise ValueError('a rated game needs two teams of the same size')
    if len({p.player_id for p in team_a + team_b}) != 2 * n:
        raise ValueError('every player must be distinct')
    if not all(isfinite(x) for p in team_a + team_b for x in (p.rating, p.uncertainty)) \
            or not isfinite(context_a) or not isfinite(context_b):
        raise ValueError('ratings must be finite')
    prepared = [prepare_variance(p) for p in team_a + team_b]
    variances = tuple(q for q, _ in prepared)
    margin = (sum(p.rating for p in team_a) - sum(p.rating for p in team_b)) / n + context_a - context_b
    scale = sqrt(2.0 * PERFORMANCE_NOISE ** 2 / n + sum(variances) / n ** 2)
    return Frozen(team_a, team_b, variances, tuple(r for _, r in prepared), margin, scale,
                  normal_cdf(margin / scale), mean_win_chance(margin, n), context_a, context_b)


def settle(frozen, winner):
    """New states for all 2n players (team A then team B) after `winner` ('A' or 'B') won. Commit all or none,
    once per game; a void game calls nothing."""
    if winner not in ('A', 'B'):
        raise ValueError("winner must be 'A' or 'B'")
    n = len(frozen.team_a)
    y = 1.0 if winner == 'A' else -1.0
    v, w = surprise_terms(y * frozen.margin / frozen.scale)
    out = []
    for i, p in enumerate(frozen.team_a + frozen.team_b):
        side = 1.0 if i < n else -1.0
        q = frozen.variances[i]
        new_q = q * (1.0 - q * w / (n * n * frozen.scale ** 2))
        # Evidence: this player's own result against their own frozen prediction (one observation per game).
        fresh = frozen.reopened[i]
        own_p = frozen.predicted_win_a if i < n else 1.0 - frozen.predicted_win_a
        won = 1.0 if side == y else 0.0
        out.append(replace(
            p, rating=p.rating + side * y * q * v / (n * frozen.scale),
            uncertainty=sqrt(max(MIN_VARIANCE, new_q)), played=p.played + 1,
            recent_residual=EVIDENCE_DECAY * (0.0 if fresh else p.recent_residual) + won - own_p,
            recent_variance=EVIDENCE_DECAY ** 2 * (0.0 if fresh else p.recent_variance) + own_p * (1.0 - own_p),
            evidence_games=(0 if fresh else p.evidence_games) + 1))
    return tuple(out)
