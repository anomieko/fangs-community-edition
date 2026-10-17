# Custom lobby settings, the Captain vote, and reconnect (community patch, 16 Oct)

a community member ranked the big features (`docs/recon/community-patchnotes.md`): #1 lobby buttons, #2 reconnect, #3 the
custom-game Captain vote, which he wants in this update. This file has the design, what was built and tested (branch
`cp-lobby`), and the reconnect research. Feb 2023 build.

## What players get

- **The lobby screen** of a custom lobby has a LOBBY SETTINGS panel in the game's own settings-menu style (top right):
  - MAP (the custom maps of the seed's `AvailableMaps`);
  - TEAMS: 1 vs 1 … 6 vs 6. When it shrinks, players in seats that no longer exist move to the "users in lobby" list,
    as with the (-) button;
  - ROUNDS: Best of 3 / 5 / 7 / 9 (first to 2 / 3 / 4 / 5);
  - CAPTAIN VOTE: on / off;
  - SHUFFLE TEAMS: everyone seated, in random seats (even seats team A, odd seats team B).
  The owner changes them; everyone else sees them greyed out, with the owner's values.
- **Launch with players waiting** outside the seats: the owner's start button reads "START (WAITING PLAYERS LEAVE)"; it
  has the server remove those players first, then the game's own launch runs.
- **In the match**: the rounds to win are the lobby's. The Captain:
  - vote on: teammates vote every round, 8 s; the Captain is the most voted teammate who wasn't Captain yet (the
    game's own rule), so never the same one twice in a row; a player who doesn't vote gets a random vote;
  - vote off, and in Casual and Ranked: no vote screen at all, augment selection starts at once, the Captain is a
    random teammate who wasn't Captain yet.

## Design

**UI: the game's own widgets, made at runtime by FangsBoot** (`tools/ue4ss/Mods/FangsBoot/scripts/lobbyui.lua`).
- Options weighed:
  - reusing unused widgets: `WB_LobbyMenu.SettingBtn` is a single icon button (no place for five settings); the Dec
    build's `ObjectiveComboBox` is a Dec-only objective choice;
  - patching the widget Blueprint: new widget-tree exports, slots and bindings in `WB_LobbyMenu` (AssetPatch can't add
    exports), heavy and fragile;
  - runtime widgets: FangsBoot already builds UI this way (the unreleased-heroes section and toggle). Chosen.
- The panel is a `Border` + `VerticalBox` added to the lobby menu's root canvas (`WidgetTree.RootWidget`,
  `AddChildToCanvas`, anchored top right, 500 design units wide).
  - Its rows are made of the settings menu's widget Blueprints: `WB_SettingComboBoxOption` (label + the game's styled
    dropdown), `WB_SettingToggleButton` (Enable/Disable) and `WB_IconButton_Secondary` (SHUFFLE TEAMS, and the owner's
    start button as a third page of `LobbyStatusSwitch`).
  - `WB_IconButton_Secondary` shows no text of its own (its `BtnText` is unused), so a text block goes into its
    `TextWrapper`.
  - The two team columns (`TeamsPanel`) are moved 200 units left (render translation) to make room: at 1080p design
    size the right side had 400 free units, the panel needs ~550.
  - Classes are loaded with `LoadAsset_Blocking` (the settings widgets aren't loaded in the lobby).
  - The owner flag (`IsLobbyOwner`) replicates a moment after joining: the panel is built again when it changes.
- Clicks: hooks on the widgets' own bound events (`BndEvt__…OnSelectionChanged…`, `…ToggleBtn…OnButtonClicked…`,
  `…SecondaryBtn…OnButtonClicked…`), filtered by our widgets' addresses. A dropdown change made by the code
  (`SetSelectedOption`: `ESelectInfo::Direct`) is not sent; only key (0) and mouse (2) choices are.

**Owner → server: the lobby controller's own RPC.** `RefreshPlayerInfoOnServer(Str UserId)` is a server RPC that only
acts when `UserId` is the caller's backend id (else it prints "User Id Don't Match"). FangsBoot sends
`"fce:<cmd>=<value>"` through it; FangsHost's CloudSave shim on that function hands those to `lobby.lua`, which
accepts them only from the lobby owner (`PS_LobbyHero_PlayerState.IsLobbyOwner`), in a custom lobby
(`MapGameMode` 4), before hero select. No new network path, nothing for the backend.

**Server → everyone: `GS_Lobby_GameState.ServerPayload`.** A replicated string (rep index 20) that
`GSSetupLobbyState` sets from each joiner's `PayloadId` and nothing reads. FangsHost writes
`fce1|map=…|size=…|rounds=…|vote=…|maps=Name:Level,…` there; FangsBoot reads it. A joiner's `InitLobbyState` resets
map, size and ServerPayload: FangsHost's 500 ms lobby loop puts them back (as `setLobbyMap`/`setLobbySize` do for
matchmade games).

**Backend:** the heartbeat (`fangshost_status.json`) carries `"lobby": {map_level, map_name, size, rounds, vote}`;
`session_view` (`backend/fangs_backend.py`, `lobby_settings`) puts map and size into the session, so the lobby list
and later joiners see them (unit test `test_lobby_list_follows_the_map_and_size_the_owner_changes_in_the_lobby`).

**Map and size on the server** (`tools/ue4ss/Mods/FangsHost/scripts/lobby.lua`): `gs.Level`/`MapName` (+ the game
instance's `MapGameLevel`), `gm.MaxPlayers`, `gs.MatchSize`; seats ≥ the new size get `SelectTeamSlotOnServer(-1)`.
Shuffle: everyone seated to -1, then to seats 0…n-1 in random order (the RPC body runs directly on the server).
Kick before launch: the server starts hero select inside `StartHeroSelectionTimer` (`ShowHeroSelectionMenu`), and a
player leaving during hero select ends the lobby (`CheckAllPlayersPresent`). So the kick (`gm:KickPlayer(AccelyteId)`)
must come first: the owner's LAUNCH sends `fce:kickwaiting`, waits until nobody waits (≤ 6 s), then runs the game's own
Launch handler.

**Rounds:** `MOBAGameStateBase.MaxRounds` (native, not replicated; `BP_AC_MatchReport` ends the match at it). FangsHost
sets it at the arena game state's BeginPlay; FangsBoot sets the clients' copy (HUD round count).

**The Captain vote** (`BluePrints/Gameplay/GameRules/King/BP_RS_King`):
- How Feb does it:
  - `StartKingVoting` opens the window (`KingSelectStartTime`).
  - The window lasts `GetKingVoteMinTime`: per team, `MaxKingVotingTime` (18) if the current round ≥ the HUD's
    `KingVoteRound` (4), else `MinCaptainSelectTime` (2).
  - `DetermineKings` picks, per team, the teammate with the most votes who wasn't Captain yet (`WasKing`). Votes
    (`KingVoteCustomID`) count only from round 4 on (`GetClientVotes`); before that each candidate gets a random
    0-100. Once everyone on a team was Captain, `WasKing` resets.
  - Players see the vote when round ≥ `KingVoteRound` (`WB_HUD` → `InitPreRoundUI(1)`).
- On our servers the window is always `MaxKingVotingTime`: `GetTeamKingVoteTime` reads `KingVoteRound` from player
  controller 0's HUD, and a server has none (the read gives 0). That was the 18 s blank screen.
- Ours:
  - **patch** `community-lobby.json`: `GetClientVotes` counts votes from round 1 (`set-call-arg` `GreaterEqual_IntInt`
    4 → 1);
  - **FangsHost**, post-hook on `StartKingVoting`:
    - sets the server's `MaxKingVotingTime` (8 s with the vote on, 0 without);
    - without the vote, gives every player a random vote for an eligible teammate, so the Captain stays random;
    - with the vote, fills in random votes for those who haven't voted 0.5 s before the window ends;
    - keeps the last Captain out for one round after the game's `WasKing` reset (no Captain twice in a row, teams
      of 2+);
  - **FangsBoot** in the match: `KingVoteRound` 1 (vote on) or 99 (off), and the client's `MaxKingVotingTime` /
    `MinCaptainSelectTime` to match (8 / 2 with the vote, 0 / 0 without), so the HUD shows the vote and the same
    countdown.
- The values patch's `MaxKingVotingTime` 18 → 2 (another stream) stays a fallback; FangsHost overrides it per match.

## Tests

`tools/run/test_lobbyui.sh` (three headless GPU clients, own backend data and game servers, the community-lobby patch
pak). It drives the panel through its widgets' own click handlers, which FangsCtl finds by class and label (each UE4SS
mod has its own Lua state: FangsBoot's variables aren't reachable from FangsCtl).

Result (17 Oct, runs `lobbyui`):
- **Lobby:**
  - Panels were built for all three players; alice's could be changed, bob's and carol's were greyed out ("Set by the
    lobby owner").
  - alice chose Crownwatch, Best of 5 and Captain vote on. The server's `ServerPayload` and all three panels showed
    them within 3 s.
  - Shuffle twice: seats alice 0 / bob 2 / carol 4 → 2 / 0 / 1 → 1 / 0 / 2.
  - Teams 1 vs 1: carol's seat 2 was gone, she waited outside (seat -1), and alice's start page switched to our button.
  - Start: the server kicked carol ("launching: 1 waiting player(s) kicked"), then the game launched with alice and bob.
- **Match:**
  - On Crownwatch (the lobby's new map).
  - The server set `MaxRounds` 3 ("match: first to 3 rounds") and an 8 s Captain window ("captain: vote, 8.0 s").
  - Both players had `KingVoteRound` 1, `MaxRounds` 3 and an 8 s window.
  - Screens: "ROUND 1 – SELECTING A CAPTAIN" for the window, the Captain reveal, then augment selection. Both
    Captains were chosen.
- **Screenshots** (local): `work/logs/lobbyui-shots/` in the `cp-lobby` worktree:
  - `alice-ScreenShot00001.png`: the owner's panel;
  - `bob-ScreenShot00002.png`: a player's panel;
  - `alice-ScreenShot00002.png`: 1 vs 1 with the waiting player and our start button;
  - `alice-ScreenShot00005-00008.png`: the Captain phase.
- Backend unit tests: 211 pass, including the new lobby-list test.

Not covered yet:
- Teammate vote cards: a 1v1 has no teammate to vote for; a 2v2 test needs four clients.
- Round 2 and later: Captain rotation, the reset rule, and the match ending at 3 round wins.
- Vote off in a match (instant, random votes; the code path is the same hook).
- Casual/Ranked.
- The start button's final text, "START (WAITING PLAYERS LEAVE)", was set after the last run; that run showed a fixed
  "START" set the same way.

## Reconnect (research only, a community member #2)

**The game has a full reconnect design** (Feb build); our setup never turns it on:
- **Client, PLAY:**
  - `WB_PlayMenu` checks for a previous game when the season record has `ReconnectEnabled: true` (ours doesn't: the
    check is skipped).
  - It lists servers from the Zeuz session manager (`ZeuzSessionManagerURL` + `ZeuzIMSProject` +
    `/sessions?session_type=<region>`), parsed by `Zeuz Get Server Info`.
  - It looks for one with `GameActive` "1", `GameId` = the player's saved `LastGameID` and more than one joined player.
    `GS_MOBA_Battle` saves `LastGameID` = its `GameId` when a match begins.
  - Then it shows `WB_ReconnectMenu`; "reconnect" runs `ReconnectRestoreMatchInfo` (a `UserMatch` save with
    `isReconnect`) and `OpenLevel(<server address>)`.
- **Server, arena:**
  - `BP_GM_MOBA_GameMode` keeps every player's data (`CachedPlayerDataInst.CachedPlayerData` with the old player state).
  - It marks a leaver as disconnected (`ReconnectSetPlayerDisconnected`).
  - A returning player gets their player state back (`ReconnectSetPlayerStateInfo`), their hero
    (`ReconnectPossesOriginalCharacter`) and their HUD and fog (`BP_PC_MOBA_PlayerController.ReconnectRestore*`).

**What we'd need:**
1. Seed: `ReconnectEnabled: true`. FANGSConfig's Zeuz URLs point at our backend, as Aug's `/zeuz/sessions` does.
2. Backend: a Zeuz-style session list (`id`, `address`, `ports[].port`, plus the fields `Zeuz Get Server Info` reads:
   game id, active flag, joined players, max players, owner, lobby name, map), listing the running custom matches the
   asking player was in. A running match's server stays allocated while its player is away (today: 180 s grace with 0
   players, then stopped).
3. FangsHost:
   - the match's `GameId` (empty on our servers today: set it to the session id at arena start, so `LastGameID`
     matches);
   - the heartbeat says who was in the match;
   - check that the game mode doesn't end a match when a team is empty for a moment (`CheckGameOverFromLackOfPlayers`
     runs on logout).
4. FangsBoot: stop answering "no previous game" at once in the PLAY check (Aug path) for the Feb build. Check the
   reconnect menu's texts.
5. Tests: a 2-player custom match; bob's game quits (FangsCtl `exit`) and a fresh client logs in as bob, presses PLAY,
   gets the reconnect menu and is put back into his hero; the match goes on.

**Size and risks:**
- About 2 days with tests (M-L).
- Risks:
  - the reconnect path was written for the developers' dedicated servers and has never run on our listen-style
    servers: DS-only branches, or server CloudSave calls that are compiled out of this exe (as in the lobby), may sit
    in it;
  - a 1v1 whose only opponent left may end before the player is back;
  - Casual/Ranked would need the matchmaker to hold the player's place (not asked: custom games only).
