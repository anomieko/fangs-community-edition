# Review findings

Ledger for the review sprint (`docs/review/SPRINT.md`). Each component reviewer wrote a scratch report with `file:line`,
a failure scenario and a reproduction script. Below are the findings that survived: where reviewers overlapped they are
merged (the ids in brackets are the reviewers' own). "Reproduced" means a script or test showed the failure against the
real code. The rest is marked "reasoning".

Severity: **high** means players get stuck, data is lost or there is a security hole; **medium** means wrong behavior in
a reachable case; **low** means an edge case or a clarity problem. State: *open*, *fix now*, *later*, *decision* (the
user's call), *won't fix: reason*, *fixed in `<commit>`*.

## Baseline

Taken 15 Oct 2026 at `6f26b44` (ruff 0.17.1, Python 3.12, aiohttp 3.14).
- **Python:** 26 tracked files.
  - Pyflakes (`ruff --select F`): `backend/` has 0 findings; tools have 8 (unused imports, one unused variable).
  - A broader rule set (E, F, W, B, SIM, PLE, PLW, ASYNC, RUF; line length 130) gives 223 findings over the repo, mostly
    one-line `;`/`:` statements and long lines.
  - The ones that point at behavior: 8 un-kept `asyncio.create_task` results in `backend/` (RUF006), one blocking `open`
    in an async function (`hosts.py`), and three zero-width spaces written literally in `social.py`.
- **Unit tests:**
  - `test_ranked.py` 14 OK (41 s) and `test_ranked_queue.py` 7 OK, both moved from `tools/test/` to `backend/tests/`.
  - Nothing else in `backend/` had unit tests; the other flows were covered only by headless game tests
    (`tools/run/*.sh`, which need the game).
  - Three ranked tests need the research checkout `../elommr` and skip without it (CI).
  - The same tests pass on production's versions (Debian trixie: Python 3.13.5, aiohttp 3.11.16).
- **Shell:** shellcheck 0.11 finds 0 errors in all 32 tracked scripts, 34 warnings and 443 info (401 of them SC2086,
  mostly in `tools/run/test_*.sh`); `server/*.sh` has 1 warning.
- **Lua and Go:** luacheck and Go aren't installed (the Go code was reviewed by reading).

## What held up

Each reviewer looked for these first:
- **Crash cleanup has one path.** Every way a game server ends (crash, failed boot, timeout, everyone left, match over,
  slot reclaim, shutdown) goes through `HostManager.stop()`. It unregisters the server before its first `await`, holds
  the port until the process is gone, collects results, removes the lobby (`on_stopped`) and tops up the standby. Once
  a game has a server, the matchmaker keeps no state for it, so a crash can't leave a player stuck in a dead match.
- **No silent removals.** All 117 commits were read. No file, backend route, backend flag or test was ever deleted on
  `main`. Removals of player-visible content carry a reason and an off switch in the CHANGELOG; hidden content is parked
  in data (`_parked_*`, `OLD_SHARDS`). Four removals lack a recorded decision: they are on the decision list below.
- **Repo hygiene.** No game file, key, join code, credential or server address was ever committed (every ref and blob
  checked). The pre-scrub history never reached GitHub.
- **Ratings and results.** Ranked state can't be written by players. Results come only from files the game servers write,
  are taken once and are deduplicated by match id. `skill.py` matches its documented equations term by term, and
  `allocator.py` is pure, deterministic and checked against an independent oracle.
- **Updates.** The launcher checks an Ed25519 signature over the file list before using any path (the key never leaves
  the operator's machine), and its path guard rejects absolute paths, `..`, drive letters and alternate data streams.
- **Container.** It runs as a non-root uid with a read-only root, `cap_drop ALL`, `no-new-privileges`, pinned Wine, and
  a SHA-256-checked UE4SS.

## Findings: backend

| id | sev | crit | where | defect | evidence | state |
|---|---|---|---|---|---|---|
| S1 [A-1, D-7, E-1, F-1] | high | R6 | `fangs_backend.py` `Store.user_for` | Login names are case-sensitive, but the user id comes from the lower-cased name: logging in as `ALICE` creates a new user with Alice's id, so any invited player can take over any account. | reproduced | fixed; `test_api.py` Login: `test_a_name_in_other_case_cannot_log_into_an_account`, `test_names_stored_twice_in_other_case_log_in_as_the_first` |
| S2 [A-2, C-1, D-8, X1-3] | high | R6 | `fangs_backend.py` session browser, `lobby_ws` | The session-browser routes and the lobby websocket need no login. Anyone who can reach port 8080 can list lobbies, `DELETE` a session (which stops its game server mid-match) or start servers. Anonymous lobby frames are logged without limit, which can fill the disk. | reproduced | fixed; `test_api.py`: `test_only_the_owner_can_delete_or_change_a_lobby`, `test_only_the_owner_can_request_a_lobbys_server`, `test_requests_without_a_login_get_401` |
| M1 [B-1, C-5, X1-1] | high | R1 | `matchmaker.py` `tick`, `hosts.py` `free_ports` | The matchmaker's capacity check counts the idle standby as busy. With 2 slots and 1 standby, one open lobby or one running game blocks all Casual and Ranked matchmaking next to an idle server. | reproduced | fixed; `test_matchmaker.py` Capacity: `test_an_idle_standby_server_is_free_for_a_match` |
| M2 [B-2, X1-7, X1-8] | medium | R1, R2 | `matchmaker.py` `tick`, `start` | Matches in the accept dialog or still booting hold no slot, so more matches form than servers exist. The extra match's players are sent Idle and lose their place in line, a second way for a match to end that skips `cancel()`. If every player leaves while their server boots, the server is still assigned to the empty match. | reproduced | fixed; `test_matchmaker.py` Capacity: `test_matches_never_outnumber_the_free_servers`, `test_two_servers_take_two_matches_not_three`, `test_a_match_that_finds_no_server_goes_back_in_line`, `test_a_server_booted_for_a_match_everyone_left_is_not_kept_for_it` |
| L1 [A-3, C-3] | medium | R1 | `fangs_backend.py` `session_create`, `zeuz_create` | "One custom lobby per player" stops the owner's previous server in any state, so an owner who crashed out and creates a new lobby ends the other players' running match. | reproduced | fixed; `test_api.py`: `test_a_new_lobby_leaves_the_owners_running_match_alone` |
| L2 [C-2] | medium | R1 | `fangs_backend.py` `handle_create_ds`, `host_stopped` | A second `createDSRequest` for one session starts a second server. When the unused one stops, `host_stopped` removes the session that is live on the other. | reproduced | fixed; `test_api.py`: `test_repeated_create_ds_keeps_the_lobbys_one_server` |
| R1 [A-4] | medium | R6 | `fangs_backend.py` record routes | Players can write server-kept records (`PROFILE_MASTERY_KEY`, `PROFILE_HISTORY_KEY`) through `update-player-record-key`, and identity fields (`Username`, `AccountType`) through a CloudSave PUT. The client only ever writes `Justice` through that route (1,728 writes in local test logs). | reproduced | fixed; `test_api.py`: `test_record_key_lambda_cannot_set_match_statistics_or_identity`, `test_cloudsave_write_cannot_change_profile_identity` |
| R2 [A-5] | medium | R5, R7 | `fangs_backend.py` `ingest_match` | The match is marked seen before the per-player updates. One malformed record stops the loop halfway, and the retry is skipped as a duplicate. | reproduced | fixed; `test_api.py`: `test_one_unreadable_record_costs_only_its_player` |
| R3 [A-6] | medium | R6, R7 | `fangs_backend.py` player records | A GET of any user id creates a stored entry and export files. Record values may be up to 16 MB under any number of keys, and each save rewrites the whole store. | reproduced | later |
| H1 [C-10] | low | R1 | `hosts.py` `_watch` | The one task that ever stops a running server has no `try/finally`: if it raised, the server would never be stopped or its port freed. | reproduced (fault injected) | fixed; `test_hosts.py`: `test_server_whose_watcher_failed_is_still_stopped` |
| H2 [C-4, X1-4] | medium | R1 | `hosts.py` `_watch` | Liveness is only "the process exited". A hung server (alive, no heartbeats) keeps its slot and its last player count forever. | reproduced | later: the threshold needs heartbeat-gap data from production first, so a slow map load is never taken for a hang |
| H3 [C-6, C-7, C-8, C-11, X1-13, B-3, X1-9] | low | R1, R5 | `hosts.py` | A standby can spawn after `shutdown()`. A failed process launch leaks its port. A leftover result marks the next server "match over". A ready timeout leaks two helper tasks. An `allocate()` waiting for a releasing port loses it to the standby. A standby whose boots all fail is never retried. | reproduced | fixed; `test_hosts.py`: one test each (marked "a bug until the review sprint fixed it") |
| H5 [X1-5] | medium | R1 | `hosts.py` `empty_for`, `_reclaim` | When every slot is taken, `_reclaim` may stop a running match whose players have shown 0 for 20 s (e.g. still loading the arena), while the normal watcher gives it 180 s. | reproduced | fixed; `test_hosts.py`: `test_full_slots_never_reclaim_a_match_within_idle_grace` |
| H8 (found by the tests) | low | R5 | `hosts.py` | A standby claimed the moment it was ready was never replaced (the next lobby waited for a cold boot); a server booted for one `allocate()` could be claimed by another once ready (two lobbies on one server). | reproduced | fixed; `test_hosts.py`: `test_standby_claimed_the_moment_it_is_ready_is_replaced`, `test_server_booted_for_one_allocate_is_not_claimed_by_another` |
| H6 [X1-10] | low | R1 | `matchmaker.py` `ranked_games` | A Ranked game's roster isn't released when its server stops without a result (crash, nobody came); it is only pruned at 50 entries. | reproduced | fixed; `test_api.py`: `test_a_ranked_roster_is_released_when_its_server_stops_without_a_result` |
| H7 [X1-12] | low | R1 | `hosts.py` | Outside the container, game servers outlive a crashed backend and the next one doesn't adopt or kill them. Production's container kills them all. | observed | later |
| H4 [C-9, F-7] | low | R7 | `hosts.py` `stop`, FangsHost | `stop()` leaves the dead server's status file in place, so `deploy.sh` counts phantom players. | reproduced | fixed; `test_hosts.py`: `test_stopped_server_leaves_no_status_behind` |
| P1 [D-1, D-2] | medium | R1 | `social.py` parties | A player left alone in a party can't be invited and can't create a party, and stale invitees keep party slots. | reproduced | fixed (user's decision: in this deploy); `test_social.py`: `test_a_party_of_one_is_no_party`, `test_an_invitee_who_joined_another_party_holds_no_slot` |
| P2 [D-3, D-5, B-4] | low | R5 | `social.py` `_drop_later`, kick/join; `matchmaker.py` `accept` | State is checked before an `await` and changed after it: a reconnect during the grace drop goes "offline" while connected, and a kick racing a leave raises and closes the leader's socket. A late accept can also start a match that was just cancelled. | reproduced | fixed; `test_social.py` Races and Presence, `test_matchmaker.py`: `test_a_match_cancelled_while_an_accept_is_announced_does_not_start` |
| P3 [D-4, D-6, D-12] | low | R6, R4 | `social.py` `chat_text` | Escaping happens before truncation, so a cut can undo it; the "Report" guard is case-sensitive; the zero-width-space guards are invisible literals. | reproduced | fixed; `test_social.py` Chat: `test_a_line_cut_at_500_characters_keeps_its_escaping`, `test_a_lobby_chat_line_carries_no_party_command_in_any_case` |
| O1 [A-7, F-10] | low | R6, R9 | `fangs_backend.py` `dispatch` | The request log stores refresh tokens and the join code (from `/download/<code>/` paths) in clear. | reproduced | fixed; `test_api.py`: `test_refresh_token_logs_the_same_player_in_again`, `test_the_join_code_in_download_paths_is_not_logged` |
| O2 [A-9] | low | R4 | `fangs_backend.py` `dispatch`, 8 × `create_task` | A handler exception becomes a bare 500 with no log line; background task results are dropped, so their exceptions go unseen. | reproduced | fixed; `test_api.py`: `test_malformed_bodies_get_a_400`, `test_a_handler_error_is_a_500_with_the_error_in_the_log` |
| T1 [A-7] | low | R6 | tokens | Token expiry is never enforced and refresh tokens never rotate. | reproduced | later (needs a check of how the client refreshes) |
| T2 [X1-2] | medium | R7 | `Store.tokens` | Login tokens live only in memory: every backend restart (deploy or crash) ends every login, and the lobby websocket then answers a dead token with fake successes. The second half is fixed with S2 (unknown tokens are refused). | reproduced | later (persist or sign tokens); deploys happen when nobody plays |
| T3 [X1-6, X1-14] | medium | R1 | FangsHost no-show timer, matchmade games | FangsHost starts a matchmade lobby without a no-show after 45 s, the same as the client's own 45 s timeout, so the first joiner may give up first. A player whose client crashes out of a matchmade game has no way back in. | reasoning | later (needs a 2-client headless test; document "no rejoin") |

## Findings: server and deploy

| id | sev | crit | where | defect | evidence | state |
|---|---|---|---|---|---|---|
| D1 [F-2] | high | R7, R1 | `server/deploy.sh` | The server-code upload (`rsync --delete` of `server/`) runs before the "people are playing" check and deletes the server's `server/.env` and `server/downloads/`. A refused deploy leaves no downloads (new players can't install); a deploy that doesn't rebuild the image keeps a mount of the deleted folder. | reproduced (rsync, locally) | fixed, on `main` with the user's OK (`90ebe4e`) |
| D2 [F-3, F-6, X1-11] | medium | R1 | `server/deploy.sh` | The busy check counts only players in game servers (not menus, queues or parties), reads errors as 0, and the image build runs between the check and the restart. | reasoning | later (deploy script; can only be checked against the server) |
| D3 [F-5] | medium | R7 | `server/` | `store.json` (all accounts and history) has no backup and no documented restore. | reasoning | later (a backup needs a tested restore procedure; the volume's files belong to uid 10001) |
| D4 [F-4, E-2] | medium | R6 | `docs/SERVER.md`, launcher | The documented join-code rotation doesn't work, and a launcher can't replace a remembered invite. | reasoning | later |
| D5 [F-8, F-9, F-11, F-12, F-13, F-15, F-16, F-17, F-18] | low | various | `server/` | Ops hardening: QoS echo without a rate limit, harden.sh doesn't check the keys file, wineboot stamped on failure, untracked files shipped, a 10 s stop grace shorter than aiohttp's, three hand-kept file lists, a floating base image, Xvfb unwatched. | mixed | later |

## Findings: player side

| id | sev | crit | where | defect | evidence | state |
|---|---|---|---|---|---|---|
| C1 [E-3, F-14] | high | R6, R2 | `player/windows/FangsCE.bat`, `server/build-client.sh`, `docs/SERVER.md` | The old `.bat` client's update channel is unsigned over plain HTTP, yet still built and documented. `build-client.sh` also rewrites the served file list without re-signing it. | reasoning | fixed: retired (the user's decision, 15 Oct) |
| C2 [E-6] | medium | R3 | FangsBoot | Loops call `FindAllOf` every 5 s (and every 500 ms when the logo was skipped) all session on players' PCs: the cause of the server hitches, on the client. | reasoning | later (needs a player update) |
| C3 [E-4, E-5, E-7..E-14] | low to medium | various | launcher, FangsBoot | Install folder and name aren't validated or changeable; old signed lists can be replayed; download size isn't checked; case-sensitive cleanup on NTFS; FangsBoot's 1,028 lines describe 2 of its 17 features. | reasoning | later |

## Removals and hygiene that need a decision

| id | what | evidence |
|---|---|---|
| X1 [X2-C] | **Decided (user, 15 Oct): keep full games only.** Casual starts only full games (8 players) since 14 Oct (`5643344`). The old 15 s early start is behind `--match-wait`. The reason is recorded, the user's decision is not; ROADMAP Decisions call Casual "quick matches". | `git show 5643344` |
| X2 [X2-A] | **Decided (user, 15 Oct): the user's call.** Trio custom mode removed on 15 Oct (`ac76b9a`) without a recorded reason; FangsBoot's "Battle = 8 players" hook is dead since. | |
| X3 [X2-B, E-3, F-14] | **Decided: the `.bat` client is retired (C1).** Each deploy deletes the full-client zip that `SERVER.md` still tells you to build (the `.bat` path, C1). | |
| X4 [X2-1] | **Decided (user, 15 Oct): kept.** `tools/pak/findkey.py` and `findkey_code.py` recover the pak's AES key from the exe. No key is in the repo, but the tool is public. | |
| X5 [X2-2] | The server distributes the whole game install to players; the README says players need their own legitimately obtained copy. | |
| X6 [X2-3, X2-4, X2-5] | **Path list kept (user, 15 Oct).** `docs/recon/playtest-source-paths.txt` (261 internal source paths from the playtest exe's strings), the class-name list, and a build-farm path in `docs/clients/playtest-main_v0_0_444.md`. | |
| X7 [X2-10, X2-13] | Local refs `backup-before-scrub` and `refs/original` hold pre-scrub history; `.gitignore` gaps (`.claude/`, files directly in `clients/`, `*.pak`, `*.key`, `.env`). | |

## Second review: the fixes themselves

A fresh reviewer read the sprint's own diff, looking for regressions the fixes introduced. It found none that breaks a
verified player flow. It found one fix resting on evidence that couldn't rule out a client path (R2-1), and four
lows. All five are corrected and tested:

| id | sev | what the fix had broken or risked | state |
|---|---|---|---|
| R2-1 | medium | S2 made "register player in a lobby" owner-only. It is the SDK's own call and the only way a player gets back into a started custom match. The evidence (no such call in local test logs) can't rule out paths the tests don't cover, because every headless client is local. | corrected: a player may add or remove themselves; `test_join_needs_a_ready_lobby_and_a_started_match_takes_only_its_players` |
| R2-2 | low | With L1 an owner can have a running match next to a new lobby; the bulk lookup listed the old one first. | corrected: newest first; `test_bulk_lookup_lists_the_newest_session_first` |
| R2-3 | low | H1 stopped a server at once when its watcher failed, which ends a live match. | corrected: logged, stopped when the process exits; `test_server_whose_watcher_failed_is_stopped_when_it_exits` |
| R2-4 | low | A cancelled `allocate()` left its booting server reserved for nobody (not reachable today). | corrected: it becomes claimable; `test_allocate_that_gives_up_leaves_its_server_claimable` |
| R2-5 | low | O2 turned every JSON parse error into a 400 and stopped printing tracebacks to stderr. | corrected: only a bad request body is a 400; 500s print their traceback |

Noted, not changed: a standby whose boots keep failing (e.g. a broken game install) is retried every minute without
backoff; each failure is logged.

## Lifecycle matrix

Every way a lobby, match, party or backend session ends, against every piece of state it must release (server
process and port, lobby listing, matchmaker state, Ranked roster, party, results, what the player's client sees):
`docs/review/LIFECYCLE.md`, updated as fixes land. Gaps there are the findings above with an X1 id.

## Readability and minimalism (R3, R4)

Reviewers agree the code is dense but not bloated: few speculative options, comments that say why. What they would cite:
- **`fangs_backend.py` is 1,222 lines.** It has a clean split (sessions/lobbies, records, the rest); left for after the
  review (no file splits the night before).
- **Presence is tracked twice** (`lobby_users`/`lobby_left` and `Social.conns`) [A-11, D-11].
- **Dead code:**
  - `ranked.has_played`, the `leaderboard` wrapper, a second `rank_points` [B-6, A-11];
  - unreachable party checks and an unused `party_id` [D-9];
  - FangsHost's unused `-FangsMatch*` arguments and FangsCtl's cancel branch [C-12];
  - FangsBoot's BladeMaster code [E-13].
- **`allocator.Policy`** has 11 options, of which the backend sets 2 (the rest replay the research fixtures) [B-7].
