# Status — Fangs: Community Edition

**Target build: FANGS 15 Feb 2023 (Steam build 10554626, `Playtest021523v1_v0_0_02`)**, the build the
server runs. The Aug 2022 Closed Playtest Alpha 7 hotfix (`alpha7.0.7.51`, `docs/clients/fangs-2022-08-26-b9396481.md`)
runs on the same stack; the Dec 2023 Closed Playtest (`main_v0_0_444`) is kept as a reference.

## Where things are (2026-10-14)

- Play: custom lobbies (create → instant standby server → launch any time → hero pick → match) and
  PLAY/Casual matchmaking, solo or as a party. Verified headless with 1–2 players and on the VPS.
- Ranked (game mode tile, unlocks at 10 wins, parties of up to 2): skill-based teams and a rating (TrueSkill-style
  Gaussian team model with party offsets, `backend/skill.py`, `allocator.py`, `ranked.py`; `docs/recon/ranked.md`).
  Casual and custom games have no rating.
- Everything unlocked: heroes, skins, stickers, avatars (sigils), banners, titles, mounts (backend catalog +
  entitlements; lists generated per build by `tools/re/cosmetics.py`). Augments: the seed's `AvailableAugments`.
- Profiles: match history, account and hero levels, wins, the Ranked rating and the leaderboard come from finished
  matches (FangsHost saves the game's own match report; the backend keeps the records).
- Social: friends (add by `name#1234`), presence, parties, party chat and whispers (`backend/social.py`).
- Main menu: no Battle Pass, Store, missions or Discord banner; players-online count instead of missions;
  a static background where the menu video can't play (Wine).
- Server: hardened Debian 13 VPS + Docker image (`server/`, `docs/SERVER.md`); one standby game server
  is kept booted so lobbies start instantly; failed server starts are retried.
- Players: Windows launcher `FangsCE.exe` (`launcher/`): asks for an invite code (public build from GitHub Releases),
  then, after updating itself to the server's launcher, for the install folder (checked: no invite codes, a full
  folder gets a subfolder, writable, enough space, not in OneDrive) and a name; downloads and verifies the game from
  the server (resumable, only changed files, signed file list; big files as gzipped pieces, 4 at a time),
  keeps a copy of itself in `%LOCALAPPDATA%\Programs\Fangs Community Edition` with desktop and Start menu shortcuts,
  starts the game. The game folder's `FANGS.exe` is a copy of the launcher (the game's own can't log in). Linux players: `tools/play/local.sh` (Wine + DXVK; local backend or `SERVER=...`).

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
| Patch pak | `tools/patch`, `docs/PATCHING.md` | Permanent changes to the game's data (`FangsCE_P.pak`): built at deploy from the game files and the patch files in `tools/patch/patches/`, the same file for players (launcher) and game servers (`FANGS_PAKS`). |
| UE4SS signature | `tools/ue4ss/UE4SS_Signatures/ProcessLocalScriptFunction.lua` | UE4SS can't find this function in the Development build; without it Blueprint hooks don't work. |
| Client config | `tools/run/config/Engine.ini.template` | User-level `Saved/Config/WindowsNoEditor/Engine.ini` redirecting the AccelByte SDK. |

## Gotchas learned

- Every `tools/run/test_*.sh` runs its backend on its own data and game-server directories (`work/run/<run>-*`, via
  `BACKEND_ARGS`) and deletes only those. Never let a test use the backend's defaults (`backend/data/store.json`,
  `work/hosts`): those are local play's (`test_lobby.sh`, `test_solo.sh` and `smoke_local.sh` did until 15 Oct and deleted them).

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
- UE4SS: `obj:IsValid()` stays true for a destroyed actor until garbage collection (15 s and more); check
  `obj:HasAnyInternalFlags(EInternalObjectFlags.PendingKill)` too (`KismetSystemLibrary:IsValid(x)` didn't help:
  most likely UE4SS's own `IsValid` method answers for the library object).

- A player's mod can send the game server a command through `BP_PC_MOBA_PlayerController.DebugSpawnBot(Name, Int)`:
  a server RPC whose body returns at once in Shipping builds (`IsInShippingBuild`), so FangsHost's post-hook on it is
  a clean channel (F6 in Training sends "FangsStartRound", `docs/recon/community-build-modes.md`). The server must
  check what it gets: any player can send any name.
- The patch tool can't add actors to a map: actors both sides need (the base blockers) are spawned by FangsHost and
  FangsBoot from the same table, at the arena game state's BeginPlay.

- Joining a custom lobby from the lobby list: the PLAY button sets the game mode to Casual, which arms the
  lobby screen's 45 s matchmade timeout for the joiner ("Failed to Connect to Match.", then the lobby ends).
  FangsBoot keeps it Custom; `fangsboot.log` records why a player leaves a lobby.
- In a match, team = client index (lobby seat) % 2: even seats are team A, odd seats team B.
- Game servers: no `FindFirstOf`/`FindAllOf` in loops that run during matches. Each walks every object on the game
  thread (10-17 ms in a full arena on a fast PC, several times that on the VPS) and was the source of the ~200 ms
  hitches. Don't cancel UE4SS loops (`CancelDelayedAction`): in this UE4SS build that sometimes stopped another loop.
  Loading a map resets `t.MaxFPS` (`docs/recon/server-performance.md`).

## Next

1. Play tests with friends on the VPS.
2. Voice chat (Vivox) is not available; TLS/domain for the server.
