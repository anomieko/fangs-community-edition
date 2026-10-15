# Architecture

How the replacement backend and the game servers fit together, where state lives, and how every game ends. Written
for someone reviewing the code. For what exists and its gotchas see `docs/STATUS.md`; for running a server see
`docs/SERVER.md`; for findings about the game itself see `docs/recon/`.

## The problem it solves

FANGS (UE 4.26, Feb 2023 build) talked to services that are gone:
- AccelByte, for login, CloudSave records, the session browser, the lobby websocket, the matchmaker, entitlements and
  leaderboards;
- AWS lambdas (`FANGSApiBaseURL`), for profile updates;
- Zeuz/Improbable, which hosted the game servers.

There is no server build of the game. This project:
- replaces the services with one Python process that speaks the client's protocols;
- runs the game client itself as a headless dedicated server under Wine, steered by a UE4SS Lua mod;
- ships the players' side mods with a signed launcher.

Nothing of the game is in this repository (`README.md`, disclaimer).

## Pieces

```
 players (Windows)                        VPS: one Docker container (server/)
 ┌──────────────────────────┐            ┌──────────────────────────────────────────────────────────────────┐
 │ FangsCE.exe launcher     │──HTTP────▶ │ backend (Python, aiohttp, one process, one event loop)           │
 │  signed file list,       │  8080      │  fangs_backend.py  routes, auth, records, lobbies, downloads     │
 │  self-update             │            │  matchmaker.py     PLAY queues (Casual, Ranked)                  │
 │ game client + FangsBoot  │──HTTP/WS─▶ │  social.py         friends, presence, parties, chat              │
 │  (UE4SS mod)             │            │  hosts.py          game server lifecycle (HostManager)           │
 │                          │──UDP 7777+▶│  skill.py, allocator.py, ranked.py   Ranked rating and teams     │
 └──────────────────────────┘            │        │ spawns, watches, stops           ▲ heartbeat, result files│
                                         │        ▼                                  │                      │
                                         │  game servers: the client exe under Wine + FangsHost (UE4SS mod) │
                                         │  (server/run-host.sh, one per UDP port, 7777-7778 by default)    │
                                         └──────────────────────────────────────────────────────────────────┘
```

| Module | Responsibility | Size |
|---|---|---|
| `backend/fangs_backend.py` | AccelByte-compatible HTTP API and lobby websocket, `Store` (persistence), auth, records, custom lobbies (session browser), player downloads, match results, app wiring (`make_app`) | ~1,300 lines |
| `backend/hosts.py` | `HostManager`: starts game servers, keeps one booted standby, watches heartbeats, stops servers through one path, hands match results over | ~300 |
| `backend/matchmaker.py` | The client's matchmaking websocket: Casual (first come, full games) and Ranked; accept dialog; party tickets | ~370 |
| `backend/social.py` | Friends, presence, parties, party chat and whispers, on the lobby websocket | ~460 |
| `backend/skill.py`, `allocator.py`, `ranked.py` | Ranked: a TrueSkill-style Gaussian team model with party offsets, the team allocator, settlement (`docs/recon/ranked.md`) | ~570 |
| `tools/ue4ss/Mods/FangsHost` | Inside each game server: removes the local player, opens the lobby map as a listen server, answers the server-side CloudSave calls compiled out of this build from exported files, writes a heartbeat and match results | ~770 |
| `tools/ue4ss/Mods/FangsBoot` | Players' mod: login without the dead Epic layer, menu cleanup, unreleased-heroes group, online list | ~1,030 |
| `launcher/` (Go) | Downloads and verifies the game and mods from the server against an Ed25519-signed file list; updates itself | ~730 |
| `server/` | Docker image (pinned Wine, SHA-checked UE4SS), compose file, deploy and hardening scripts | |

The backend is deliberately small and single-process: one community, two game server slots, a few dozen players.
There is no database: state is in memory or in one JSON file (below).

## Trust boundaries

- **Players** log in with a name, the community join code and a per-install secret the launcher generates. Names are
  first come; the secret is stored salted and hashed. Any player may read any profile (the game shows them), but a
  player may change only their own records, and only the fields that are theirs. Wins, levels, history, ratings and the identity fields (`Username`, `AccountType`) are
  written only by the server.
- **Game servers** are our own processes on the same machine. They get a server token through `client_credentials`,
  which is accepted only over loopback, and may write game records and any player's records.
- **Anyone else** reaches only what the login screen needs: the QoS echo, game records, the player count, and
  downloads behind the join code.
- **The operator** holds the update signing key. It never goes to the server, so a compromised VPS can't push code to
  players' machines.

## Where state lives

| State | Where | Survives a restart |
|---|---|---|
| Accounts, player records, match history, Ranked ratings, game records (seeded at start) | `Store`: one JSON file (`store.json`). Each change is saved with a write to a temp file plus `replace` (atomic). | yes |
| Records the game servers read | exported by `Store.export_records` as one file per record (`<data>/records/…`), read by FangsHost | rebuilt at start |
| Login tokens | memory (`Store.tokens`) | no: players restart the game after a backend restart (deploys happen when nobody plays) |
| Custom lobbies (sessions), matchmaker tickets and matches, parties, presence | memory | no (documented) |
| Game servers | processes; `HostManager.hosts` in memory | no: the container restart ends them |
| A game server's status | its heartbeat file `fangshost_status.json` (FangsHost writes it every 3 s through a temp file); the backend reads it every 2 s | n/a |
| Match results | `fangshost_result-*.json` next to the game server until the backend has taken them; a result is ingested once (deduplicated by match id, persisted) | yes: one left by a crash is taken at the next start on that port |

## Main flows

**Login.** `POST /iam/v3/oauth/token` with `password = <join code>:<secret>` → an opaque token. With the token, the
client connects the lobby websocket (`/lobby`) and the matchmaker websocket (`/matchmaker`).

**Custom lobby.**
1. The client creates a session (`POST /sessionbrowser/…/gamesession`).
2. It sends `createDSRequest` on the lobby websocket.
3. `HostManager.allocate()` hands over the booted standby server, or starts one, and a new standby boots behind it.
4. The backend answers `dsNotif BUSY` with the server's address, and the client joins the server.
5. Other players find the lobby in the session browser and join it.
6. The owner launches the match. FangsHost writes the result file at the end, and the backend ingests it (history,
   levels, wins).

**Matchmade game (PLAY).**
1. `QueueJoinRequest` on the matchmaker websocket creates a ticket; a party queues as one ticket.
2. When enough players are queued, the matchmaker forms a match: Casual takes the oldest tickets, Ranked asks the
   allocator for the fairest teams.
3. Everyone gets the accept dialog. When all accept, `allocate()` provides a server, which is told the match size and
   map (`fangshost_match.json`).
4. Each player gets the server address and a team token. From then on the matchmaker keeps nothing about the match.
5. Ranked keeps only the roster, to settle the ratings when the result arrives.

## How a game ends (the lifecycle rule)

Every way a game server ends goes through one method, `HostManager.stop()`:
- normal end, crash, boot failure, ready timeout, everyone left, nobody came, slot reclaim, lobby deleted by its owner,
  backend shutdown.

`stop()` does the same things in the same order every time:
1. It unregisters the server before its first `await`, so a second stop is a no-op.
2. It stops the process group and holds the port until the process is gone.
3. It collects any result left behind.
4. It fires `on_stopped`, which removes the custom lobby that server served.
5. It tops up the standby.

The watcher task `_watch` decides when a running server ends. The other places that end a server (reclaiming a slot,
an owner deleting their lobby, shutdown) also call `stop()`. None of them cleans up by itself.

The matchmaker is built so that this rule is enough: it hands a match to a server and forgets it. A crashed or
finished server therefore can't leave a player "in a match" on the backend; they can queue again at once.

`docs/review/LIFECYCLE.md` goes through every way a lobby, match, party or backend session ends, against every piece
of state it must release. Each gap found there is fixed with a test, or listed with a reason in
`docs/review/FINDINGS.md`.

## Tests

- **`backend/tests/`:**
  - Runs the real app (`make_app`) on loopback with throwaway data. A player client connects from 127.0.0.2, so it
    isn't trusted as a local game server.
  - Uses `fake_host.py` in place of Wine. It writes the same heartbeat and result files as FangsHost, and can crash,
    hang or refuse to boot on command.
  - Covers the HTTP API, auth, records, lobbies, the game-server lifecycle, the matchmaker, social, and Ranked.
  - Run it with `python3 -m unittest discover -s backend/tests`.
- **CI** (`.github/workflows/backend.yml`) runs those tests on production's Debian packages (Python 3.13, aiohttp 3.11),
  plus ruff.
- **Headless game tests** (`tools/run/test_*.sh`) run the real game: real clients and real game servers, in their own
  network namespace and with their own data. Examples are a full custom match, PLAY, parties, chat, Ranked and items.
  They need the game files, so they run on a developer machine, not in CI.

## Known limitations

These are listed so a reader doesn't have to discover them:
- **One process, memory state.** A backend restart ends logins, lobbies, queues and parties (deploys happen when
  nobody plays, `server/deploy.sh` checks).
- **No rejoin into a matchmade game** after a client crash. Custom matches allow it.
- **A game server that hangs without exiting** is only noticed by its stale heartbeat in the logs; automatic stop is
  planned (`docs/review/FINDINGS.md` H2).
- **Wine** runs the client as a server. Under Wine a few percent of server starts die early, so starts are retried up
  to 3 times.
- **Voice chat (Vivox)** is unavailable.
- **Ratings** are the community's own: a TrueSkill-style model, not the game's original system (`docs/recon/ranked.md`).
