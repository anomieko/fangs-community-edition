"""Ranked play: rating states in the store, and settling a finished ranked match (skill.py has the math).

Only matches the matchmaker made from the Ranked queue are rated; Casual and custom lobbies change no rating.
States live in store.data['ranked'] (server-only, never a CloudSave record players could write):
  players:        user id -> skill.Rating.to_json() + 'shown_uncertainty'
  last_opponents: user id -> [user ids of their last ranked opponents] (an exact-tie breaker for the queue)
The game's PROFILE_RATINGS_KEY ranked_rating and the leaderboard are derived from these (`shown`).

Shown uncertainty: the profile's rank points are 90 * (mu - 2 sigma), so when the model reopens a confident
player's uncertainty (to 300, skill.prepare_variance) their points would drop by hundreds at once, even after a win.
Players see the lowest uncertainty they have had instead (never rising); points then follow the skill estimate.
"""
from dataclasses import replace

import skill


def _ranked(store):
    return store.data.setdefault('ranked', {'players': {}, 'last_opponents': {}})


def rating_of(store, uid):
    return skill.Rating.from_json(uid, _ranked(store)['players'].get(uid))


def shown(store, uid):
    """{'mu', 'sigma'} on the game's scale as players see it (see Shown uncertainty above)."""
    d = _ranked(store)['players'].get(uid) or {}
    r = skill.Rating.from_json(uid, d)
    return skill.display(replace(r, uncertainty=min(r.uncertainty, d.get('shown_uncertainty', r.uncertainty))))


def previous_opponents(store, uids):
    last = _ranked(store)['last_opponents']
    return {u: frozenset(last[u]) for u in uids if u in last}


def settle_match(store, played, game, winner):
    """Rate a finished Ranked game. played: {'TeamA': [uid, ...], 'TeamB': [...]}, who appears in the game's
    result (played at least one round); game: the matchmaker's roster {'parties': [[uid, ...]], 'teams': {uid:
    'TeamA' / 'TeamB'}} plus 'everyone_joined' (the server saw the whole roster connected); winner: 'TeamA' /
    'TeamB'. Updates the store (the caller saves) and returns a summary for the log.

    The assigned teams are rated, so a player who quits mid-match still counts for their team: quitting can't
    void a lost game (abandonment is a normal result). Void (nothing changes) when a matched player never joined,
    the assigned teams aren't n vs n (someone left while the server booted), or the result disagrees with them."""
    assigned = game.get('teams') or {}
    if winner not in ('TeamA', 'TeamB'):
        return {'rated': False, 'reason': 'no winner'}
    if any(assigned.get(u) != team for team, uids in played.items() for u in uids):
        return {'rated': False, 'reason': 'result teams differ from the assignment'}
    a = [u for u, t in assigned.items() if t == 'TeamA']
    b = [u for u, t in assigned.items() if t == 'TeamB']
    if not a or len(a) != len(b):
        return {'rated': False, 'reason': f'assigned teams {len(a)} vs {len(b)}'}
    if not game.get('everyone_joined'):
        return {'rated': False, 'reason': 'a matched player never joined'}
    parties = game.get('parties') or []
    n = len(a)

    def context(team):
        sizes = [len(set(party) & set(team)) for party in parties]
        return skill.team_context([s for s in sizes if s], n)
    frozen = skill.freeze([rating_of(store, u) for u in a], [rating_of(store, u) for u in b], context(a), context(b))
    after = skill.settle(frozen, 'A' if winner == 'TeamA' else 'B')
    state = _ranked(store)
    for old, new in zip(frozen.team_a + frozen.team_b, after):
        was = (state['players'].get(new.player_id) or {}).get('shown_uncertainty', old.uncertainty)
        state['players'][new.player_id] = {**new.to_json(), 'shown_uncertainty': min(was, new.uncertainty)}
    for team, others in ((a, b), (b, a)):
        for u in team:
            state['last_opponents'][u] = sorted(others)
    quit = sorted(set(a + b) - {u for uids in played.values() for u in uids})
    return {'rated': True, 'predicted_win_a': round(frozen.predicted_win_a, 4),
            'contexts': [frozen.context_a, frozen.context_b], 'reopened': sum(frozen.reopened),
            **({'quit': quit} if quit else {}),
            'change': {new.player_id: round(new.rating - old.rating, 1)
                       for old, new in zip(frozen.team_a + frozen.team_b, after)}}


def leaderboard(store):
    """[(user id, rank points)], best first: everyone with a ranked game. Points: the profile's 90 * (mu - 2 sigma)
    on the game's display scale, i.e. a conservative skill estimate."""
    rows = []
    for uid, d in _ranked(store)['players'].items():
        if d.get('played'):
            r = shown(store, uid)
            rows.append((uid, int(90 * (r['mu'] - 2 * r['sigma']))))
    return sorted(rows, key=lambda r: -r[1])
