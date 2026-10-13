# Match flow (from the playtest client, `main_v0_0_444`)

Sources: headless boot test (`work/logs/run1.log`) + decompiled Blueprints (`tools/bpdump`).
Everything here is from the **playtest** build unless noted.

## Headless boot test — what works with no backend

`MOBA.exe "LE_TrainingGround?listen" -nullrhi -nosound -unattended -log` under Wine, no network:

- Engine boots in ~3 s, map loads, **listen server on UDP 7777**, `BP_GM_MOBA_GameMode` runs.
- Round state machine (C++ `UMobaGameState*` states) advances on its own:
  `Init → PreRound → ObjectiveSelect → KingSelect → …` with game mode "Training", 5 rounds.
- AI heroes (e.g. `BP_AI_FireMage`) spawn and cast abilities server-side.
- **Local player gets no hero**: `SendCharInfoToServer Playfabid=` is empty →
  "Unable to find playfab id to user character info" / "not valid ClientIndex".
- Backend calls fail harmlessly (AccelByte telemetry, Zeuz payload API).

## Normal (online) flow, as far as decoded

1. **Client login** → AccelByte IAM (`dev2.hiddenleaf.accelbyte.io`). Player ID is still called
   "PlayfabId" everywhere (the game used PlayFab before AccelByte).
   `BP_MOBAInstance.PlayfabId` holds it on the client.
2. **Matchmaking** → custom matchmaker (`UMOBAMatchMakerSubsystem`, JSON messages with
   `msg`/`msg_type`, "Join Match With Token: %s Server: %s"). Custom lobbies go through
   `WB_PlayMenu.CreateZeuzServer()` → Zeuz/Improbable session manager.
3. **Dedicated server** boots on `ServerDefaultMap = LE_Lobby_Map` (`BP_GM_Lobby_GameMode`):
   - reads env `ORCHESTRATION_PAYLOAD_API` → `http://<it>/api/v0/session-manager/config`
     (match config) and `.../status`; calls a "ready" endpoint (Zeuz IMS payload API);
   - logs into AccelByte as a server (client-credentials);
   - runs hero draft / skin select (`HandleHeroDraftPick`, `MapUserCharToPlayfabId`, `PlayMatch`, `LaunchGame`).
4. Server travels to an arena map (`BP_GM_MOBA_GameMode`). Server's
   `BP_MOBAInstance.PlayfabIdToUserCharacter` (PlayfabId → character info) survives the travel.
5. Each client's `BP_PC_MOBA_PlayerController` sets `PCPlayfabId` (from GameInstance) →
   `SendPlayfabIdToServer` → `GameMode.PlayerControllerInitialized(PC, id)` → C++
   `AMOBAPlayerControllerBase::SendCharInfoToServer` looks the id up, assigns `ClientIndex`
   (team = `ClientIndex % 2 == 0 ? 1 : 2`) and spawns the hero.

## Notable bits

- `BP_MOBAInstance.UseLAN` / `ToggleLANSetting` exists ("LAN: ON/OFF" in `WB_PlayMenu`), but with LAN on
  the custom-lobby path simply skips `CreateZeuzServer()` — appears vestigial, not a working offline mode.
- `MOBA/Content/Data/config.json` flags are read by `UMOBAGameInstanceBase::SyncJsonConfiguration`.
- "Accelbyte Editor Client Login" path exists in `AMOBAPlayerControllerBase` (editor-only login flow).
- Game-instance exe is a *Game* target (client+server code). It can listen-serve; a true dedicated
  server (`-server`) normally needs a *Server* target build, which we don't have.

## Open questions

- Exact JSON schema of the Zeuz session config payload (→ disassemble `UMOBAZeuzIMSSubysystem`,
  `BP_GM_Lobby_GameMode.ParseSessionConfig`).
- Which AccelByte endpoints the client hard-requires before reaching the main menu.
- Whether a listen-server host can act as a "server-only" player (spectator) cleanly.
