# Status — Fangs: Community Edition

**Target build: FANGS Closed Playtest Alpha 7 hotfix, 26 Aug 2022 (build 9396481, `alpha7.0.7.51`)** —
see `docs/clients/fangs-2022-08-26-b9396481.md`. The 15 Feb 2023 build (10554626) was the first target
and still runs on the same stack; the Dec 2023 Closed Playtest (`main_v0_0_444`) is kept as a reference.

## Where things are (2026-10-13)

- Aug 2022 build, verified headless: custom lobbies (create → instant standby server → launch any time →
  hero pick → match) and PLAY/Casual matchmaking (matched → server-started hero select → match).
  Augments come from the backend's `AvailableAugments` (generated per build from its own data).
- Feb 2023 build: full flow verified (2 players and solo, headless, and on the VPS).
- Server: hardened Debian 13 VPS + Docker image (`server/`, `docs/SERVER.md`); one standby game server
  is kept booted so lobbies start instantly; failed server starts are retried.
- Players: Windows launcher `FangsCE.exe` (`launcher/`): asks for install dir and name, downloads and
  verifies the game from the server (resumable, only changed files), updates itself, starts the game.
- Linux players: `tools/play/local.sh` (Wine + DXVK; local backend or `SERVER=...`).

## History

**2026-10-13: a full custom-lobby match runs end-to-end on our stack.** Automated test
`tools/run/test_lobby.sh`: alice logs in → creates a custom lobby → backend starts a game host →
bob finds it in the lobby browser and joins → both pick heroes → owner starts → server travels to
the arena → heroes spawn → rounds run (PreRound → ObjectiveSelect → KingSelect → round start).

Scope agreed with the team: **everything unlocked, one package for a small Linux VPS.** First custom
lobbies only; then (same day) simple best-effort matchmaking for PLAY, because lobbies alone felt
convoluted (`backend/matchmaker.py`: no ratings, whoever is queueing gets a match).

## Pieces

| Piece | Where | What it does |
|---|---|---|
| Backend | `backend/fangs_backend.py` | AccelByte-compatible API: IAM login (any name/password), CloudSave (records auto-created), session browser, lobby WebSocket incl. `createDSRequest`→`dsNotif BUSY`, QoS + UDP echo, platform stubs, FANGS lambda API, idle matchmaker. Exports records to `backend/data/records/` for hosts. |
| Host manager | `backend/hosts.py` + `server/run-host.sh` | Starts one headless Wine game host per custom lobby on ports 7777+, retires it when empty. Instances are hard-linked views of one game install. |
| FangsHost (UE4SS mod) | `tools/ue4ss/Mods/FangsHost` | Turns a client exe into a dedicated server: removes local player, opens `LE_Lobby_Map?listen`, points the server SDK at the backend, server login, and **shims the server CloudSave calls that are compiled out of this client build** (`ServerRetrievePlayerInfoRecord` etc. are `ret` stubs). Writes a heartbeat (map, players). |
| FangsBoot (UE4SS mod) | `tools/ue4ss/Mods/FangsBoot` | Player side: skips the logo movie; with `-TestUser=<name> -TestPass=<pw>` fakes the dead Epic login so the game uses its built-in username login. |
| UE4SS signature | `tools/ue4ss/UE4SS_Signatures/ProcessLocalScriptFunction.lua` | UE4SS can't find this function in the Development build; without it Blueprint hooks don't work. |
| Client config | `tools/run/config/Engine.ini.template` | User-level `Saved/Config/WindowsNoEditor/Engine.ini` redirecting the AccelByte SDK. |

## Gotchas learned

- Game-target exe can't `-server`; "dedicated" = local player removed + listen server. Its
  `IsDedicatedServer()` is false, so DS-only BP init is replicated in FangsHost.
- Server SDK settings are only loaded from config in Server builds → set via
  `AccelByteBlueprintsServerSettings` setters at runtime.
- Client only proceeds on `dsNotif status: BUSY`; lobby browser hides sessions with empty
  `lobby_owner` or full player count; lobby WebSocket subprotocol must be `wss`.
- Headless *clients* (tests only): `-nullrhi` crashes in the main menu; use gamescope headless + DXVK
  (`GPU=1`), and remove the .mp4s (`NOMOVIES=1`) — Wine's media decoding hangs. Real players unaffected.
- `FindFirstOf("WB_…")` can return a widget-tree template; use live refs (`gi.WB_MainMenuRef…`).
- The Play panel only shows when the inventory owns a Hero: a catalog item (`title` = DT_Heroes row,
  `categoryPath` `/Hero`) plus an entitlement whose `name` equals that title. `UnlockAllHeroes` alone
  only affects the lobby hero select.
- Display names must look like `name#1234`: the client uses the part before `#` as the player name
  (lobby owner check, top bar). Untagged names read as empty -> nobody owns their lobby.
- `update-player-info` `cosmeticType` is a path into PROFILE_INFO_KEY (`Hero`, `Cosmetics.Title`);
  the lobby server re-reads `Hero` from the profile as the player's pick.
- UE4SS (this build): a hook on a Blueprint function runs once, after the function body; changing a
  Blueprint function's out parameters from a hook has no effect on the caller.

## Next

1. Play tests with friends on the VPS.
2. Match end → return to menu → host teardown (untested); root cause of the occasional server crash at
   start (covered by retries).
3. Cosmetics (skins etc. in the catalog); TLS/domain for the server.
