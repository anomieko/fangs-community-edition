"""Ranked play: rating states in the store, and settling a finished ranked match (skill.py has the math).

Only matches the matchmaker made from the Ranked queue are rated; Casual and custom lobbies change no rating.
States live in store.data['ranked'] (server-only, never a CloudSave record players could write):
  players:        user id -> skill.Rating.to_json()
  last_opponents: user id -> [user ids of their last ranked opponents] (an exact-tie breaker for the queue)
The game's PROFILE_RATINGS_KEY ranked_rating and the leaderboard are derived from these (skill.display).
"""
import skill


def _ranked(store):
    return store.data.setdefault('ranked', {'players': {}, 'last_opponents': {}})


def rating_of(store, uid):
    return skill.Rating.from_json(uid, _ranked(store)['players'].get(uid))


def has_played(store, uid):
    return bool((_ranked(store)['players'].get(uid) or {}).get('played'))


def previous_opponents(store, uids):
    last = _ranked(store)['last_opponents']
    return {u: frozenset(last[u]) for u in uids if u in last}


def settle_match(store, teams, parties, winner):
    """teams: {'TeamA': [uid, ...], 'TeamB': [...]} as they played (from the game's result); parties: the
    matchmaker's tickets [[uid, ...], ...]; winner: 'TeamA' / 'TeamB'. Updates the store (the caller saves) and
    returns a summary for the log. A game whose teams don't match a fair n vs n is void (nothing changes)."""
    a, b = teams.get('TeamA') or [], teams.get('TeamB') or []
    roster = {u for party in parties for u in party}
    if not a or len(a) != len(b):
        return {'rated': False, 'reason': f'teams {len(a)} vs {len(b)}'}
    if not set(a + b) <= roster:
        return {'rated': False, 'reason': 'players who were not matched'}
    if winner not in ('TeamA', 'TeamB'):
        return {'rated': False, 'reason': 'no winner'}
    n = len(a)

    def context(team):
        sizes = [len(set(party) & set(team)) for party in parties]
        return skill.team_context([s for s in sizes if s], n)
    frozen = skill.freeze([rating_of(store, u) for u in a], [rating_of(store, u) for u in b], context(a), context(b))
    after = skill.settle(frozen, 'A' if winner == 'TeamA' else 'B')
    state = _ranked(store)
    for old, new in zip(frozen.team_a + frozen.team_b, after):
        state['players'][new.player_id] = new.to_json()
    for team, others in ((a, b), (b, a)):
        for u in team:
            state['last_opponents'][u] = sorted(others)
    return {'rated': True, 'predicted_win_a': round(frozen.predicted_win_a, 4),
            'contexts': [frozen.context_a, frozen.context_b], 'reopened': sum(frozen.reopened),
            'change': {new.player_id: round(new.rating - old.rating, 1)
                       for old, new in zip(frozen.team_a + frozen.team_b, after)}}


def leaderboard(store):
    """[(user id, rank points)], best first: everyone with a ranked game. Points: the profile's 90 * (mu - 2 sigma)
    on the game's display scale, i.e. a conservative skill estimate."""
    rows = []
    for uid, d in _ranked(store)['players'].items():
        if d.get('played'):
            r = skill.display(skill.Rating.from_json(uid, d))
            rows.append((uid, int(90 * (r['mu'] - 2 * r['sigma']))))
    return sorted(rows, key=lambda r: -r[1])
