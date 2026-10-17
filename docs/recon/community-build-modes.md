# Community patch, part 4: game modes, server and backend (built 16 Oct 2026)

Sheepa OK'd the proposal (the second PDF, `docs/recon/community-patchnotes.md`). This part covers Training, the base
blockers, presets, the two removed artifacts and Wylde's ammo in the dummy phase. Branch `cp-modes`, on top of
`fiorne-restore`. Nothing is enabled for players or deployed.

Where each change lives, and why not the patch pak:

| Change | Where | Why there |
|---|---|---|
| Training servers freed in seconds | backend (`hosts.py`, `fangs_backend.py`) | server lifecycle |
| TRAINING loads the floating island | backend seed (`make_seed.py` `AvailableMaps`) | the cause is our map list |
| Shardseeker, Wing Rush removed | backend seed (`make_seed.py` `REMOVED`) | what players are offered |
| Training's augment phase held until F6, damage in it, dummies kept | FangsHost `modes.lua` + FangsBoot (F6) | only for one-player games: a session decision, not the game's data |
| Wylde's gun in the dummy phase, Bounty's Reward stacks from dummies removed | FangsHost `modes.lua` | needs a new hook on the round phases; a call the rewriter could add wouldn't know the phase |
| Presets load and save | FangsHost `modes.lua` + backend | the server's CloudSave calls are compiled out of this build (like the lobby shims) |
| Base blockers | FangsHost + FangsBoot `blockers.lua` | map actors: the patch tool can't add actors to a map |

## TRAINING loaded Embersong: our map list

Sheepa (Q16): "the current training tile just loads a solo game on the embersong map". The cause is in our seed, not
in FangsBoot (FangsBoot's `onCreate` session code is the Aug 2022 client's):
- `WB_PlayMenu.PlayGameMode`, mode 0 (Training): `MapGameLevel = "LE_BeautifulCorner"`, `MapPlayerCount = 1`, then
  `CreateCustomGame("Solo", <map_basic_training_title>)` → `WB_CreateLobby.CreateLobby` → `SelectMap("Basic Training")`.
- `SelectMap` looks the name up in `MapLevel`, built from `AvailableMaps` (name = `BP_FL_MOBADetails.GetMapLocName`:
  `LE_BeautifulCorner` → `map_basic_training_title`). Our `AvailableMaps` had only the three arenas: "Failed to find
  Map Level", and the level stayed the preselected Embersong.
- Fix: `AvailableMaps` gets `{"Name": "Basic Training", "Map": "LE_BeautifulCorner", "Custom": false}`. Entries
  without `Custom` go into `MapLevel` but not into the create-lobby map list.
- The island map: `BP_GM_GameMode_TurtleMap`, 20 placed `BP_AI_FireMage` dummies, no dummy spawn tags. It is in the
  same folder as the arenas (`/Game/Environment/Maps/`), so the lobby's `servertravel` finds it.
- Practice on Embersong (or any map) stays available as a custom lobby in Solo mode.

## Training servers: 10 s instead of 180 s

`hosts.py`: a host gets `solo` when its session asked for `max_player` 1 (TRAINING and custom Solo lobbies,
`handle_create_ds`). Once its player was seen on the current map and is gone, it stops after `solo_grace` (10 s);
`empty_for` (the slot reclaim) uses the same grace. A player still loading a new map (the lobby → arena travel) isn't
"seen on this map" yet and keeps the normal grace. `session_create` also stops the owner's running solo game when
they start a new one. Unit tests: `backend/tests/test_hosts.py` (5 new).

## Training's augment phase (FangsHost `modes.lua`, FangsBoot F6)

Training = `MapGameMode` 0, or a custom lobby (4) launched with one player (`MapPlayerCount` 1).

**Why the first version ended the phase at once (found 17 Oct).** It held the phase by setting `ItemSelectStartTime`
to 0, from a 200 ms loop or a post-hook on `CanSkipItemSelect`. Traced (Solo lobby, world seconds): KingSelected 105.45
→ `CanSkipItemSelect` called once, returning false (player present, controlled, not locked in; start already 0 from our
hook) → CountDownStart 106.02, and `CanSkipItemSelect` was never called again. The game's native item-select state
treats a start time of 0 or below as "no item selection" and moves on. One-player games don't skip the phase by
themselves. The native side: `StartItemSelect` (exe `0x1413c7190`) sets `CurrentRoundEvent` = ItemSelectStart and
`ItemSelectStartTime` (offset `0x294`) to the world time; `GetItemSelectCurrentTime` (`0x1412fc540`) = world time −
that, floored at 0.

**How it holds now.** `ItemSelectStartTime` is left alone, and the lock-in itself is undone:
- the client's lock-in (`ReportetFinishedItemSelectOnServer`) reaches the server as the native RPC
  `MOBAPlayerState.ServerSetFinishedItemSelect(bool)`;
- a post-hook on it clears the player's `bSelectedItems` again in the same frame, so `AllPlayersSelectedItems` stays
  false;
- the max times are 5999 s, so the timer doesn't end the phase either;
- F6 sets every player's `bSelectedItems` to true, and the game ends the phase the normal way.

**Status: off** (`HOLD_PHASE = false` in `modes.lua`). Tested 17 Oct with it on, in both TRAINING and a Solo lobby:
- the phase stays open with the timer at 5999 s: still "in item selection" 70 s in, ended at ~90 s by the test's lock-in;
- **but a lock-in still ends it.** Our post-hook on `ServerSetFinishedItemSelect` ran ("lock-in kept the augment phase
  open"), yet the next round event was CountDownStart. The lock-in code (decompiled: `ReportetFinishedItemSelectOnServer`
  `0x1413dd340` → `0x141319c30`) also sets a byte on the game state at offset `0x621` to 1, then sends the RPC (its
  server side, vfunc `0x6f8`, likely does the same). Most likely the item-select state ends on that flag, whatever
  `bSelectedItems` says. `RequestChangeAugments` from the Dec dump doesn't exist in the Feb exe.
- Next step: find which game-state bool sits at `0x621` (log every game-state bool before and after a lock-in), reset it
  in the same post-hook, and test lock-in, P and F6 again. Then turn `HOLD_PHASE` on.
- What stays on: the dummies are kept, and the augment-phase immunity is gone (both tested).

In Training (the TRAINING tile and custom Solo lobbies), once on:
- **Held until F6** (above). Lock-in and P (`ShowAugmentSelectAgain`, which only works during the phase) both work. A
  200 ms loop ends the hold when the round event (`CurrentRoundEvent`) reaches the countdown.
- **F6 starts the round.** FangsBoot binds F6 to `pc:DebugSpawnBot("FangsStartRound", 0)`. `DebugSpawnBot` is a server
  RPC that returns at once in Shipping builds (`IsInShippingBuild`); FangsHost's post-hook on it is our command
  channel.
- **Damage in the phase.** The game gives each hero `BP_GE_Immunity_All` for the pre-round (application immunity to
  `Effect.Damage.Generic`) and grants `Effect.PreRoundUnlocked` (lets abilities be used then, `BP_AC_InputManager`)
  through the same spec. In Training, FangsHost removes it and applies `BP_GE_EmptyDuration` (no modifiers, no tags)
  with `Effect.PreRoundUnlocked` granted. The round start removes effects granting that tag, ours too.
- **Dummies stay.** On arena maps the game spawns dummies for the phase (tag from `TaggingSpawnedDummies`) and
  `Destroy Preround Dummies` removes actors tagged `PreroundDummy` (a literal) at the round start. In Training,
  FangsHost re-tags them `FangsKeptDummy` after they spawn, and replaces the previous round's at the next spawn.
- `GS_MOBA_Battle`'s own `OnCountdownStart` can't be hooked from Lua (no UFunction by that name on the class), hence
  the round-event loop.
- The "[TAB]" text of the training tip (Tab is the scoreboard) is a string-table edit, left to the values-and-texts
  part to avoid two patches editing one key.

## Wylde in the dummy phase (FangsHost `modes.lua`)

His gun is loaded only by `BP_GA_Gunslinger_P.ForceReloadRoundStart`, bound to `OnRoundStart_CountDownEndDel`, so it
was empty with the dummies. Post-hook on `Spawn Preround Dummies` (every arena match): `Add Loaded Bullets(Modified
MaxBullets)` on each Wylde, and the counts of `BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack` / `…Applied` are
noted. Post-hook on `Destroy Preround Dummies`: the stacks gained since are removed
(`RemoveActiveGameplayEffectBySourceEffect`). If the bonus bullet was earned on dummies, it is taken back too (the
Applied effect, `Modified MaxBullets` and `Base Max Bullets` − 1, the ammo bar).

**For merging with the stream that fixes "0 ammo all game"** (abilities that only set themselves up at round start,
Sheepa; that stream edits `BP_GA_Gunslinger_P` and others). This change edits no game asset and is server-only, in
`tools/ue4ss/Mods/FangsHost/scripts/modes.lua` (`wyldeLoad`, `wyldeUndo`):
- hooks: `GS_MOBA_Battle_C:Spawn Preround Dummies`, `GS_MOBA_Battle_C:Destroy Preround Dummies` (post, server);
- calls on `BP_Gunslinger_Char_C`: `Add Loaded Bullets`, `SetUIAmmoMaxStacksOverride`; reads/writes `Modified
  MaxBullets`, `Base Max Bullets`;
- effects read and removed: `Gunslinger/E/Items/BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack`,
  `…MaxAmmoIncreaseApplied`;
- doesn't touch `BP_GA_Gunslinger_P`, `ForceReloadRoundStart` or `BP_GA_Gunslinger_Reload`.
If that fix loads the gun whenever the passive starts, the dummy-phase reload only tops it up (harmless). The Bounty's
Reward undo stays needed either way.

## Presets (FangsHost `modes.lua`, backend)

The in-match preset panel (`WB_LoadoutPresets`) loads with the server RPC `GetHeroLoadouts` and saves with
`SaveHeroLoadouts`. On the server both call CloudSave functions that are compiled-out stubs in this build, so the
panel never got its presets and a save fell back to standard build 1 (`docs/recon/community-patchnotes.md`).
- Load: post-hook on `GetHeroLoadouts`: `ControllerUpdateLoadouts(<PROFILE_LOADOUT_KEY record>)` from the exported
  records (`records/players/<uid>/`).
- Save: post-hook on `SaveHeroLoadouts`: the JSON goes to `fangshost_loadout-<uid>-<n>.json` (an object up to 64 KiB),
  then `ControllerSavedLoadouts(true)`. `hosts.py` collects these like match results. The backend stores them as
  `PROFILE_LOADOUT_KEY` for a known player and exports them for the next match. That's the same record the lobby's
  loadout screen uses (`update-loadouts`).
- The player id comes from the client (`PCPlayfabId`, as for everything the server does for a player): it must be 32
  hex characters before it goes into a path. The uid is in the file name, and the file holds only the client's JSON.

## Base blockers (FangsHost + FangsBoot `blockers.lua`)

`docs/recon/community-patchnotes.md` ("Base blockers") has the mechanism. The Aug 2022 placements, as world
transforms (attach parents resolved from `work/shard/maps-aug`):

| Map | Blocker | Center | Yaw | Scale | Mesh (radius) |
|---|---|---|---|---|---|
| Embersong | ×2 | (0, ±4220, 215 / 69) | 0 / −43.5 | 16.8 × 16.8 × 16.2 | `/Engine/BasicShapes/Sphere` (50) |
| Stormheart | ×2 | (−85, 4637.5, 94), (−72, −4718, 96) | −180 | 6.0 × 7.3 × 4.9 | `Stylized_VFX_StPack/Meshes/SM_Sphere` (100) |
| Crownwatch | ×2 | (−1964, 3491, 116), (−2040, −3588, 146) | −108.7 / 137.2 | ≈ 8.5-9 × 7.8-8.3 × 5-6 | SM_Sphere (100) |

**Spawn scale:** a spawned actor's root gets the spawn transform's scale multiplied by the class's own (BP_SpawnBlocker's
mesh template: 5 × 5 × 5). The first test run placed 84× blockers (a radius of 4200 on Embersong). `blockers.lua` now
divides the class scale out (read from the class defaults at run time).
Every Feb 2023 player start lies inside its base's blocker (checked against the Feb maps' `BP_MOBAPlayerStart`s).
The blocker's own mesh has an invisible material. Feb's added `SpawnTrapperCylinder` (no collision) is hidden.
FangsHost and FangsBoot place them 200 ms after the arena's game state `BeginPlay`. The file is the same in both mods
(`tools/run/test_modes.sh` checks it). A player with an older FangsBoot than the server would rubber-band at the base
edge; the launcher updates FangsBoot before the game starts.
Heroes in their base are also damage-immune until they leave (`BP_AC_SpawnBlocker.ApplyImmunity`), as in Aug.
**17 Oct, switched on** after the fixes in `docs/recon/base-blockers.md`: Feb's spawn protection asked the first
player's hero (patch `base-blockers`), and Stormheart's and Crownwatch's blockers had the class sphere's collision
(radius 50 × the smallest scale) instead of SM_Sphere's, and the class's small protection Sphere.
Not checked: whether the Aug spheres cut into paths of the re-arted Feb bases (Crownwatch most). Players' feedback.

## Tests

`tools/run/test_modes.sh` (`MODE=train`, `MODE=solo`), helpers `tools/run/test_modes.lua` (`watch()` traces the round
events). Backend unit tests: `backend/tests/test_hosts.py`: 61 pass, the full suite (219) and ruff too.

| What | Result (17 Oct, headless, Feb build) |
|---|---|
| TRAINING map | `LE_BeautifulCorner` (`GS_MOBA_Battle_Map3_C`); before the seed fix Embersong |
| Training server freed | backend: "solo player left" ~12 s after the player left (log 20:10:22 → last server line 20:10:33) |
| Augment phase held / F6 | held with the timer at 5999 s (TRAINING 104.8 → 195.2, Solo 106.2 → 195.5 world s, ended by the test's lock-in); a lock-in still ends it, so it's off (above) |
| Dummies kept (Solo lobby) | 3 re-tagged `FangsKeptDummy`, 3 alive before and 35 s after the round start |
| Wylde's gun in the dummy phase | "gun loaded", 12 ammo from the dummy phase on; no Bounty's Reward hits in the test (0 removed) |
| Presets | served at round 1, a save from `SaveHeroLoadouts` stored by the backend and exported |
| Base blockers | Embersong: 2 placed on the server and the client, scale 16.8. After the hero was moved out of its base, its capsule blocks the blockers' channel on both sides (`GetCollisionResponseToChannel(25)` 1 → 2) and the in-base immunity is gone. Swept back towards its spawn, it stopped 1179 short of it, about 225 before the sphere's edge: blocked, though the base's own geometry isn't ruled out (no control sweep yet). The first run spawned them 5× too big (below). Stormheart and Crownwatch: not run. |
