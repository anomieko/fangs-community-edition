# Lifecycle matrix: how every game ends, and what it must release

The question this answers: when a lobby, a match, a party or the backend itself ends in any way (normally, by a crash,
a timeout or a disconnect), is every piece of state it held released, through one path, so that nobody is left stuck
in a game that no longer exists?

How it was made: an independent audit (15 Oct, review sprint) traced each cell through the code. Cells marked
"reproduced" were checked with deterministic scripts. Those scripts ran the real `HostManager`, `Matchmaker`, `Store`
and request dispatch, with a fake game server in place of Wine. Line numbers are at `6f26b44`. Gaps link to
`docs/review/FINDINGS.md` and are updated there as fixes land.

**Short answer:** every way a game server ends goes through `HostManager.stop()` (`hosts.py`), which waits for the
process, frees the port only after it exited, collects any result, then fires `on_stopped` (which removes the lobby).
The matchmaker forgets a match the moment it hands out the server address, so a crashed or finished server can't leave
players "in a match": they can queue again at once. The gaps found were around that core: who may stop a server (S2), when the
matchmaker may start one (M1, M2), reclaim and boot edge cases (H3, H5), a server that hangs without exiting (H2), and
state with a second lifetime (H6). All but H2 and H6 are fixed, each with a test.

Legend: `ok <where>` means it is handled there. `GAP → <id>` means it is not handled, or handled wrongly. `n/a` means
that state doesn't exist in this case. `game:` is the game's own behavior (per `docs/recon/`). `unknown` needs a
headless client test.

## Custom lobbies

| Way it ends | Game server (process, port, files) | Lobby listing | Results | Player's client |
|---|---|---|---|---|
| Owner presses Leave | game: `EndLobbyOnServer` → `QuitGameServer`, exit 0 (`docs/recon/backend-api.md`) → ok `hosts.py` `_watch` → `stop()` (port freed after exit; stale files cleaned at the next spawn) | ok `on_stopped` → `host_stopped` | n/a | game: everyone back to the menu |
| Everyone leaves | ok `_watch` after `lobby_grace` (20 s) (reproduced) | listed with 0 players during the grace, then ok | n/a | n/a |
| Nobody joins | ok `_watch` after `unused_timeout` (180 s). A hung server is never stopped: GAP → H2 | listed ≤180 s | n/a | owner's client gives up after ~18 s on a cold boot (ROADMAP Known issues) |
| Launched into a match | keeps running: ok `_watch` (180 s once empty; 120 s after the result, or 10 s after everyone left). Only its owner or a game server can stop it early (was open to anyone: S2, fixed) | ok: unlisted once launched; rejoin only for players in the session | ok `collect_results` → `ingest_match`, once (deduplicated by match id) (reproduced) | end screen, then back to the menu when the server stops |
| Owner crashes out and makes a new lobby | ok: the running match is left alone; only an open lobby is replaced (L1, fixed) | ok | ok | ok: the match goes on |

## Matchmade games (Casual, Ranked)

| Way it ends | Game server | Matchmaker state (tickets, matches) | Ranked roster | Party | Results | Player's client |
|---|---|---|---|---|---|---|
| Accept timeout | n/a | ok `cancel()`: non-accepters (and their party) go Idle, the rest go back in line with their original wait | n/a | unchanged | n/a | the accept dialog closes on Idle |
| A player rejects | n/a | ok `cancel()` (tested) | n/a | unchanged | n/a | as above |
| Party member leaves while queued | n/a | ok `party_changed` → the whole ticket is dropped | n/a | ok | n/a | Idle |
| Party member leaves while matched | n/a | ok `party_changed` → `cancel()`; a member who isn't in the match causes no cancel (reproduced) | n/a | ok | n/a | as accept timeout |
| Everyone leaves while the server boots | ok: the server is stopped, not kept for nobody (M2, fixed) | ok | n/a | ok | n/a | n/a |
| Server boot fails | ok: 3 attempts, each dead process stopped; a standby whose boots all fail is retried after a minute (H3, fixed) | the match is cleared and its players are sent Idle (a broken server shouldn't keep them in repeated accept dialogs) | ok | unchanged | n/a | Idle; must press PLAY again |
| No server slot | ok: `HostManager.capacity()` counts idle and booting standbys and reclaimable servers (M1, fixed); reclaim waits for the watcher's own graces (H5, fixed) | ok: no more matches form than servers; a match that still finds none goes back in line with its place (M2, fixed) | n/a | unchanged | n/a | stays queued until a server is free |
| Server crash in lobby or hero select | ok: exit seen within 2 s → `stop()` (reproduced). A hang without exit: GAP → H2 (reproduced) | ok: nothing kept after assignment; players can queue again (reproduced) | roster kept until pruned: GAP → H6 | unchanged | none | unknown (needs a headless test) |
| Crash mid-match | ok, as above (reproduced: "process exited (3)", port freed, player queues again) | ok | no rating change; roster kept: GAP → H6 | unchanged | a result written just before the crash is still collected in `stop()` | unknown |
| Normal match end | ok `_watch`: "match finished" after the end screen | n/a | ok: taken once, settled once | n/a | ok: exactly once (file deleted on collect; duplicates skipped) (reproduced) | end screen, then back to the menu |
| A player disconnects mid-match | keeps running; if all leave, 180 s | ok | settled from the assigned teams | ok: party kept 60 s (grace) | ok | no way back into a matchmade game: GAP → T3 |
| A player never connects | FangsHost starts with those present after 45 s; nobody at all → ok after 180 s (reproduced) | ok | void if uneven | n/a | none or partial | the client's own 45 s timeout races FangsHost's: GAP? → T3 (unknown) |

## Backend restart, and a client reconnecting

| Way it ends | Game servers | Matchmaker, parties | Logins | Player's client |
|---|---|---|---|---|
| Backend restart (deploy or crash) | in production the container restart ends every game server. Outside a container they are orphaned: GAP → H7 | memory only: tickets and parties are lost (documented) | memory only: every login ends: GAP → T2 (reproduced) | must restart the game; deploys happen only when nobody plays |
| A client crashes and reconnects | custom lobby: still listed, rejoin works | a new connection replaces the old one without losing the ticket or match (reproduced) | ok | matchmade game: no rejoin (T3) |

## Tests that pin this down

`backend/tests/test_hosts.py`, `test_matchmaker.py`, `test_social.py` and `test_api.py` cover these rows with a fake
game server (no Wine). Each finding above is fixed with a test that failed before the fix.
