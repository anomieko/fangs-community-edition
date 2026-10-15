# Backend API the client needs (playtest `main_v0_0_444`)

Discovered by running the client against `backend/fangs_backend.py` (which logs every request to
`work/logs/backend.jsonl`) plus Blueprint/C++ reading. ✅ = implemented in our backend.

## How the client is pointed at us

- AccelByte SDK URLs: user-level `MOBA/Saved/Config/WindowsNoEditor/Engine.ini`
  (template: `tools/run/config/Engine.ini.template`). No game files modified.
- Everything else (matchmaker, AWS lambdas, Zeuz) comes from the **`FANGSConfig` game record** we
  serve, so it's all redirectable from the backend.

## Boot → main menu sequence

1. Logo movie (skippable once `WB_Logo.bCanSkip`) → `WB_AccountMenu`.
2. Login method by `GetBuildType()`: 1 = Epic (EOS), 2 = Steam, 5 = Xbox. Built-in dev path:
   **`-TestUser=<name> -TestPass=<pw>`** → AccelByte username login, but only after EOS reports
   success. `tools/ue4ss/Mods/FangsBoot` fakes `OnEOSLoginDone(true)` and skips the logo.
3. `POST /iam/oauth/token` (`grant_type=password`, Basic client auth) ✅
4. Game records (retry forever on failure): `FANGSConfig`, `HeroLevelRewards`, `season`, `Mission` ✅ (seeded)
5. `GET /qosm/public/qos` + UDP echo ping ✅
6. User record `PROFILE_INFO_KEY` (schema = `FPlayerInfo`) — auto-created on first read ✅
7. Many optional user records (404 tolerated so far): `PROFILE_MASTERY_KEY`, `PROFILE_RATINGS_KEY`,
   `PROFILE_SETTINGS_KEY`, `PLAYER_SHARD_SELECTION`, `PLAYER_MISSION_CLEARS`, `Justice`.
8. Platform: entitlements ✅, currencies ✅, DLC/IAP sync ✅, wallets ❌, `items/byCriteria` ❌
9. `GET /iam/v3/public/users/me` ✅
10. Lambda `vivox-token` → `{"token": ...}` ✅ — **login completes only after this succeeds.**
11. Main menu: lobby WebSocket (`/lobby/`, subprotocol `wss`), matchmaker WebSocket, `basic/misc/time`,
    `social/statitems`, `lobby/v1/messages`.

## `FANGSConfig` game record

```json
{ "NoServerMessage": "...",
  "<game version, e.g. main_v0_0_444>": {
     "Servers": [ { "Name": "Local", "Alias": "local", "Region": "local",
                    "MatchMaker": "...", "CasualMatchMaker": "...", "MatchMakerLink": "...",
                    "MatchMakerABLink": "ws://host/matchmaker", "MatchMakerABRanked": "...",
                    "MatchMakerABCasual": "...", "MatchMakerABBeginner": "...", "Allocation": "...",
                    "ZeuzIMSProject": "...", "SessionManagerUrl": "...", "ABArmadaDeploymentName": "...",
                    "FANGSApiBaseURL": "http://host/fangsapi",
                    "CreatePlayerURL": "create-player", "VivoxTokenURL": "vivox-token",
                    "UpdatePlayerInfoURL": "update-player-info", "UpdateRegionURL": "...",
                    "UpdatePlayerSettingsURL": "...", "UpdateLoadoutsURL": "..." } ],
     "UnlockAllHeroes": true, "UnlockAllSkins": true, "EnableAllMounts": true,
     "EnableAugmentProgress": ..., "AvailableGameModes": ..., "AvailableCustomModes": ...,
     "AvailableMaps": ..., "AvailableSkins": ..., "AvailableHeroes": ..., "AvailableAugments": [...] } }
```

- Player profile `Region` must equal a server `Name`.
- `AvailableAugments` (Feb 2023 and Aug 2022 builds): `[{"Item": <DT_MOBALoot row name>, "Owner": <hero
  HeroName>}]`. `BP_MOBAInstance.MapAugmentDetails` maps each row to its `MOBAItem` in `AugmentDetailMap` /
  `AugmentRevDetailMap` and adds it to the hero's preview asset (`GetPreviewHeroByName(Owner)`). The in-match
  HUD (`Map_Contains(AugmentRevDetailMap, item)`) and the loadout screen skip every augment missing from
  these maps, so without this key nothing is selectable. The game server reads the same key from
  `FANGSConfig[version]` in `LE_Lobby_Map`; the client also accepts it from the `season` record.
  `EnableAugmentProgress: true` would further limit augments to owned ones. Our lists come from each build's
  data (`tools/re/augments.py` → `backend/seed/augments-*.json`).
- Lambda URLs are built as `FANGSApiBaseURL + "/dev/" + <route>`; seen routes:
  `update-player-record-key` (POST `{RecordId, Key, Value}`), `get-player-missions`,
  `update-player-info` (PUT `{namespace, cosmeticType, cosmeticId, version}`), `update-player-settings`,
  `vivox-token`. All carry the player's AccelByte bearer token. The environment segment is `/dev/` in the
  Dec 2023 playtest and `/prod/` in the Feb 2023 build.

## `PROFILE_INFO_KEY` (FPlayerInfo)

`{Username, Version, AccountType, Hero, Region, Sigil, Stickers: [], GameplayTutorialComplete, Cosmetics: {}}`
Hero ids are internal names (`Berserker`, `FireMage`, `LightningArcher`, `ShieldGirl`, `CatSupp`, …).

## Custom matchmaker (WebSocket, `MatchMakerABLink`)

Client connects with `Authorization: Bearer secret-token:accelbyte/<token>`. JSON frames `{msg_type, msg}`.

- Client → server: `QueueJoinRequest {partyToken}`, `AcceptMatchRequest {id}`, `RejectMatchRequest {id}`.
- Server → client: `ClientStatusResponse {status: Idle|Queued|Matched|Accepted, match: {id?, expiresInMillis, accepted}}`,
  `ServerAssignmentResponse {assignment: "<server address>", token}` → client `OpenLevel(<address>)`.

## Hosting matches

- Game target exe can't run `-server`, but a headless instance whose local player is removed
  (`GameplayStatics.RemovePlayer`) then `OpenLevel(LE_Lobby_Map, listen)` is effectively a dedicated
  server: verified a client joins its lobby as player 1.
- Lobby (`BP_GM_Lobby_GameMode`) gets its config from the lobby owner's `UserMatch` SaveGame
  (`LoadMatchInfo`) → `InitLobbyState` → `GMSetupLobbyState`; launches with `servertravel /Game/Environment/Maps/<Level>`.
- Server fetches each player's `PROFILE_INFO_KEY` (server token) and retries forever on failure.
- How a lobby server ends itself (Feb 2023 blueprints; `BP_GM_Lobby_GameMode`, `WB_LobbyMenu`). Each goes through
  `KickAllPlayers` and then `UnreserveServer`/`QuitGameServer`, so the process exits with code 0 and the backend logs
  `process exited (0)`:
  - **the owner presses Leave**: `WB_LobbyMenu` calls `EndLobbyOnServer("")` when `IsLobbyOwner`, which kicks
    everyone with an **empty** message (FangsHost logs `lobby: kicking everyone: ` with nothing after it, and no
    `the game stops the server` line). On prod 9 of the 10 `process exited (0)` exits between 14 Oct 23:00 and
    15 Oct 03:00 UTC were this (the 10th: a player didn't lock in), some 2-3 s after the owner joined their own new
    lobby;
  - `StopServer` (logs `the game stops the server`, with a message): a player didn't lock in a hero
    (`error_player_didnt_lockin`), a player left during hero select (`CheckAllPlayersPresent`, `error_player_left_lobby`),
    entry timeout (`error_player_didnt_join_lobby`, not in custom mode 4), empty or ownerless lobby every
    `CheckUnReserveTime` (300 s; FangsHost resets the timer while the lobby is empty).
- Custom games: `WB_PlayMenu.CreateZeuzServer` → if `ABArmadaDeploymentName` set, AccelByte SessionBrowser
  (`CreateCustomGameSessions`, settings `lobby_name/lobby_owner/map_level`) and `GetGameSessionsByTypeEnum`;
  otherwise Zeuz IMS payload APIs.
