# The community patch list (16 Oct 2026): what each item takes

The community put together a three-page patch list ("FANGS COMMUNITY PATCHNOTES"; a community member sent it, the user forwarded
it on 16 Oct). It isn't in the repo. This file records what each item is in the **Feb 2023 build**, how we would
change it, how big the change is, and what we still need to ask. It is static research: Blueprint pseudocode, class
defaults, extracted assets, string tables and two targeted exe decompiles. Six streams ran in parallel. **Nothing has
been run in a match, built or deployed.** Every "cause" below is a reading of the code, and each change needs a match
test before it ships.

Local scripts and raw outputs (git-ignored): `work/community-patchnotes/` (`findings/` = the six stream reports as
written, `perf/` = map statistics, `f4`/`f6` = VFX-pack and item dumps).

**Questions.** The open questions went to a community member as a fillable PDF, made outside the repo. Its 42 questions are
numbered in the table below as **Q1-Q42**, and the field names inside the PDF are `q<NN>_<part>` / `q<NN>_notes`. The
"Michael Mouse fountain" was cleared up through swagnaros (see "Base blockers"). Answers go into "Answers" at the end of
this file.

## Every item

Size: S = a value or text (under an hour plus a test), M = about a day, L = days or more. "pak" = the patch pak
(`docs/PATCHING.md`; players and servers get the same file), "FangsHost" = server-only Lua, "FangsBoot" = players' Lua
(a player update), "backend" = `backend/`, "op" = a new AssetPatch edit type (see below).

| Item (community wording, shortened) | What we found | How | Size | Q |
|---|---|---|---|---|
| **General** | | | | |
| Fix presets | In-match preset load/save go through server CloudSave calls compiled out of this exe; FangsHost doesn't shim `BP_PC_MOBA_PlayerController` `GetHeroLoadouts`/`SaveHeroLoadouts`, so `LoadoutAugments` stays empty and a save falls back to recommended build 1 | FangsHost shim + backend ingest of `PROFILE_LOADOUT_KEY` | M | 1 |
| Choosing captain faster | `BP_RS_King.MaxKingVotingTime` 18 s (Aug 10, Dec 2); the server has no HUD, so it always waits the full time while clients finish after 2 s | pak `set-default` | S | 2 |
| CC immunity on dashes (Rowan, Belroth, Rush) | Rowan's and Belroth's `ApplyUnstoppable()` still exist but nothing calls them; Rush ("Flash") got `CanBeCrowdControlled = true` and a LockMovement wait | op `insert-call` (straight-line functions) + op `set-literal` | M | 3 |
| Remove the "Michael Mouse" (Mickey Mouse) fountain | The base you can walk back into for safety (swagnaros, via the user: "once you leave base you are blocked from going back into it"). Aug placed 2 `BP_SpawnBlocker` per arena map; Feb removed them from the maps, but the class and the heroes' `BP_AC_SpawnBlocker` component are still in Feb (see "Base blockers") | FangsHost + FangsBoot spawn the blockers at the Aug spots (server and clients must agree: movement is predicted) | M | – |
| Green / blue Shard instant | Aug: instant 50 % heal (+ cleanse) / full mana; Feb: 5 s heal-over-time / 125 per 0.25 s | pak: `BP_GA_GreenBuffHoT.Duration` 5 → 0.25, `BP_GA_ManaFill.ManaPerQuarterSecond` 125 → 10000 | S | 4 |
| Knock-up "MISSING STRING TABLE ENTRY" | `DT_GameplayEffectData` KnockUp row points at `FANGS_LOC_EN:statusbar_statusname_knockup_lbl`, which doesn't exist | op `add-text` (or `rename-import` KnockUp → Stun) | S | 5 |
| Heirlooms → Augments | 17 string-table entries, 20 occurrences, 3 tables; no hard-coded widget text | pak `replace-text` × 17 | S | 6 |
| Training servers not freed | Backend: an emptied match server gets 180 s (`hosts.py` idle grace, `empty_for`/`_reclaim`), Training included; the game never ends a Training itself | backend: short grace for 1-player sessions; stop an owner's old solo server | S-M | 7 |
| **Artifacts** | | | | |
| Remove Shardseeker, Wing Rush | Shardseeker = `Generic_BobAndWeave` (our restore, `_old_shards`); Wing Rush = `Generic_FlyPhoenixFly` (stock pool) | backend seed: park + a `REMOVED` set in `make_seed.py` | S | 8 |
| **Custom lobby** | | | | |
| Change mode/map inside a lobby | No lobby settings UI in any build; FangsHost `setLobbyMap`/`setLobbySize` already work for matchmade lobbies | FangsHost + backend session update + owner chat command (button = FangsBoot UI, L); maybe a rematch instead (L) | M | 9 |
| Bo5 / Bo7 / Bo9 | `MaxRounds` on the game state: Aug 3, **Feb 2**, Dec 5; not replicated; the match report ends the match at it | FangsHost per lobby (lobby-name tag or chat); pak = every match | S-M | 10 |
| Randomize teams | Team = `ChosenSlot % 2` | FangsHost permutes seats before hero select; backend can balance by rating | M | 11 |
| Spectator mode | Only developer spectating (`BP_AC_Spectator`) | new system | L | 12 |
| **Training** | | | | |
| Infinite round start timer | `ItemSelectFirstRoundMaxTime` / `ItemSelectMaxTime` (native, replicated) | FangsHost in Training/Solo | S | 13, 14 |
| Change augments after lock-in (Tab → P) | P (`ReOpenAugment`) exists but only during item selection; alone, lock-in ends it; the "[TAB]" text is stale | pak `replace-text`; FangsHost keeps the phase open (`bSelectedItems`) | S + M | 15 |
| Practice island / keep dummies | The floating sky island is most likely Feb's own Training map `LE_BeautifulCorner`; spawned dummies exist only on arena maps (Solo lobbies) | nothing to port; FangsHost retags `TaggingSpawnedDummies` | S-M | 16 |
| Training while in queue | Menu blocks it; a match pop-up isn't seen in an arena; each Training costs a game server | FangsBoot accept-and-travel; lobby case not feasible | L | 17 |
| **Optimization** | | | | |
| Crownwatch laggy | Client rendering: 2575 mesh actors (700 × a 589 kB canopy tree), sun with a light function and long shadows; occlusion culling off in this build (`r.AllowOcclusionQueries=False`); server fine there | measure; `r.AllowOcclusionQueries=1` for players (Dec had it); FangsBoot per-map light/cull tweaks; later a map-edit op | S-M | 18 |
| Maps loaded below the map | No streaming sublevels in any Feb map; each arena's own scenery underneath is always drawn (occlusion off) | runtime leak check; fix = occlusion | S | 19 |
| (Rubber-banding in general) | Feb: `MAXPOSITIONERRORSQUARED` 0.5 (Aug 8.5), client moves 20/s (Aug 60/s), net tick 30 with the listen-server clamp on, 40 kB/s caps; Dec: tick 60, no clamp, 800 kB/s | A/B test Dec's config on the servers (and the shipped `FangsCE/Engine.ini`) | S-M + tests | 20 |
| **Heroes** | | | | |
| Astrada: ally/enemy cage colour | `DA_VFXPack_AstradaDefault` Skill2 slot is already team-split (Ally/Enemy Niagara), colours unset | op `set-export-prop` on the VFX pack; fallback FangsBoot tint | S-M | 23 |
| Somnia ult rubber-banding | `BP_GA_BookMage_RNEw` re-applies a fresh one-tick slow to every tethered enemy every 0.1 s | pak: `Tick Frequency` 0.1 → 0.25 (Dec), `ATTickHeal` 3.333 → 8.333 | S | 21 |
| Ishir: gun sound on ult | Sounds are FMOD bank events; Feb added `Backstab_Skill3_Shadow` and `_ReturnToShadow` | `rename-import` of the event once identified | S | 24 |
| Rowan: passive stops healing | Feb passive heal ≈ 0 always (missing-HP fraction computed once and passed as flat `Data.Heal`); Earth Rend's arc heal drops out when leaving one arc | FangsHost heal tick like Dec; or op `set-name-const` | M | 25 |
| Rowan: Propagator charge bar | Server shortens the charge cooldown (`SetGameplayEffectDurationHandle`); the client bar never learns it | RE the native, then a FangsHost replication nudge or FangsBoot bar | M | 26 |
| Rowan: Dourling Caltrops | Box spawned *in front of* Rowan after the dash (`SetForwardLocation`), `bHiddenInGame = False` (the cube), cue replays the Space burst; tooltip says [SHIFT] | pak `set-call-arg` 2.0 → -2.0, op `set-export-prop` (hide), op `set-name-const` (VFX), `replace-text`; trail visual FangsBoot | S-M | 27 |
| Rowan: item with missing text | `WoodenSword_Skill4_PlantHide` = **Pwyff's Saplings** (texts deleted in Feb, Aug has them) | FangsBoot texts (or `add-text`), numbers by `set-default` | S | 28 |
| Tufts: Space laggy | Local root-motion dash with `WaitNetSync(OnlyClientWait)`; `VelocityOnFinishMode` 0 (Aug 1) | pak `set-call-arg` 0 → 1; maybe sync type 2 → 1 (riskier) | S / M | 22 |
| Rose: Klaive's Puzzlebox 50 → 75 | `BP_GA_DemonGirl_Q_Instant.TPDamage` 50 (Aug 100) | pak `set-default` | S | – |
| Wylde: LMB 35 → 40 | `BP_GA_Gunslinger_LMB` `AbilityDamage`/`ModifiedAbilityDamage` 35 | pak `set-default` | S | – |
| Wylde: old RMB | Aug: 95 dmg, range 562.5, 2 ammo, 1 s cd, no hold; Feb: 65, 932/950, 1, 0.5 s, hold | pak `set-default` × 6-8 | S | 29 |
| Wylde: ammo in the dummy phase | Magazine filled only on `OnRoundStart_CountDownEndDel`; Bounty's Reward stacks on dummies | FangsHost hooks on `Spawn/Destroy Preround Dummies` | M | 30 |
| Wylde: Bounty's Reward 35 → 30 | `MaxAmmoIncrease Stack Count Required` + the stack GE's `StackLimitCount`; tooltip hard-codes 35 | pak `set-default` × 2 + `replace-text` | S | – |
| Wylde: Speedshine +10 → +20 % | `BP_GA_Gunslinger_P.ReloadSpeedBoostPercentageSpeedUp` 0.1 | pak `set-default` | S | – |
| Ethryn: M1 50 → 40 | `FirstAttackDamage`/`SecondAttackDamage` 50; third hit `ShieldAttack Damage` 55 | pak `set-default` | S | 31 |
| Ethryn: Holy Brazier 2 → 4 s, 0.75 → 1 s | `ItemPrecisionShieldAbilityCooldown`, `ItemPrecisionShieldMaxShieldLifetime` | pak `set-default` × 2 | S | – |
| Ethryn: shield too wide / reflects from behind | `BP_TA_ShieldGirl_Skill4` box `wer` half-width 240 at X 109 vs capsule radius 80; `OnProjectileOverlap` has no direction check | op `set-export-prop` (width); a direction check is code | M (L) | 32 |
| Ethryn: shield vs Belroth's boulder | Boulder `ProjectileSphereCollision` radius 170 (Dec 100); clone spawned radius + 50 back | op `set-export-prop` 170 → 100 | S-M | 33 |
| Ethryn: reflected Wylde E one-shots | Each Fan the Hammers bullet is cloned separately; likely Wylde's passive procs on himself per bullet (untested) | 2-player test first; then a non-reflect tag (S-M) or code (L) | test + S-M | 34 |
| Brutus: +100 HP | `BP_GE_Berserker_Stats` MaxHealth override 950 (Aug 1000) | op `set-export-prop` (nested modifier) | S | 35 |
| Zoey: M1 heal 48 → 60 | `BaseHealPerTick` 4; tooltip says ×12 = 48, the code heals ≈ 40 | pak `set-default` 4 → 5 (or 6 + tooltip fix) | S | 36 |
| Zoey: M2 shield 45 → 50, 1.5 → 2 s | `Base Shield Amont`, `ModifiedShieldAmount`, `Shield Duration` (also the RMB heirlooms' durations) | pak `set-default` × 3 | S | 37 |
| Zoey: Shieldnip 0.75 → 1.5 s | `AOESDuration` | pak `set-default` | S | 37 |
| Zoey: ult AoE VFX invisible | Since Feb the cue asks the VFX pack (`VFXPack.Skill3.AOEVFX`); both packs have it; cause needs a repro | FangsBoot fallback spawn | M | 38 |
| Zoey: Mentor's Locket +35 → +75 | `AVHealPerEnemy` 35; ult tooltip says 200 heal, real 150 | pak `set-default` | S | 39 |
| Fiorne: 0 bunny stacks | `BP_GA_Lancer_Ammo` sets itself up only at round start; a mid-round re-grant (the passive's own safety net) leaves 0 stacks | FangsHost watcher + re-init | M | 40 |
| Rayo: red M2 +75 → +50 % | "red" = combat heirlooms; Pinpoint Spotter `BonusDamage` 75 | pak `set-default` | S | 41 |
| Rayo: red Shift +85 → +50 % | Stormlense Scope: ramp `1 + r` fixed in code, then `EagleEyeMaxDamageMultiplier` 1.85 | pak `set-default` + `set-call-arg` cut-off 0.85 → 0.5 | S | 41 |
| Rayo: Blitzhead Arrows max 35, no self-damage | `DeathstrikeMaxStacks` 60; self-damage in `ActivateDeathstrikeMissEffect` | pak `set-default` + `set-call-arg` (x > x) + `replace-text` | S | – |
| Rayo: stand still less for M1 | `CastTime` 0.45 (Aug 0.25) standing still, `AbilityCooldown` 0.25 | pak `set-default` × 2-3, or `set-call-arg` CastSlowdown 0 → 0.5 | S | 42 |
| Belroth: Angerstone Talons +40 | Item sets Shift damage to `ODMagnitude` 60, base went 30 → 70: −10 | pak `set-default` 60 → 110 | S | – |
| Belroth: Craterthorns 40 → 50 | `PUDMagnitude` 40 | pak `set-default` | S | – |

## Base blockers (the "Mickey Mouse fountain")

"Michael Mouse fountain" is the community's joke for a base you can always retreat into, like League of Legends'
fountain. swagnaros, through the user (16 Oct): "Remove the LoL style fountain, once you leave base you are blocked from
going back into it". In the old version, a hero who left the base couldn't walk back in. Now a hero can step out and
back in whenever they like, and the base laser protects them there.

- **Aug 2022.** Each arena map places two `BP_SpawnBlocker` actors (`/Game/BluePrints/BP_SpawnBlocker`, a
  `StaticMeshActor` with a collision mesh and a `Sphere`), one per base:
  - Embersong (`LE_Arena02_Map`): `BP_SpawnBlocker`, `BP_SpawnBlocker3`, at about (0, ±4220), scale 16.8.
  - Stormheart (`LE_Arena06_Map`): `BP_SpawnBlocker2`, `BP_SpawnBlocker_2`.
  - Crownwatch (`LE_Payload03_Map`): `BP_SpawnBlocker2`, `BP_SpawnBlocker_2`, each with its own mesh, scale and yaw.
  - Stormheart's and Crownwatch's root locations in the dump are near the origin, so their placement is probably
    relative to an attach parent. Read the full transforms from `work/shard/maps-aug/*.json` before using them.
- **Feb 2023.** None of the arena maps places a `BP_SpawnBlocker` any more. Everything else is still in the pak and
  runs:
  - `BP_SpawnBlocker` itself. Feb added a `SpawnTrapperCylinder` mesh, and at BeginPlay sets its sphere and mesh to
    overlap channel 16.
  - Every hero's `BP_AC_SpawnBlocker` component (on `BP_PlayerChar`, `Enabled` true in all three builds). When the
    hero's `OnActorEndOverlap` fires for a `BP_SpawnBlocker` (the hero walked out of it), the component sets the
    hero's capsule to block channel 25 (`BlockSpawn` locally for the owning client, `BlockSpawnServer` on the server).
    From then on the blocker's mesh stops the hero.
  - It also removes the hero's spawn damage immunity (`RemoveImmunity`).
  - Death, revive and round end unblock again (`UnblockSpawnAll` / `UnblockSpawnServer`).
  - So in Feb that code waits for an overlap that never happens.
- **How we'd do it.** Spawn the two blockers on every arena map at the Aug transforms, with the Aug mesh and scale
  overrides.
  - On the game server: FangsHost, at arena BeginPlay, deferred like `shards.lua`; one spawn per map, no loops.
  - On every client: FangsBoot at map load. Collision has to be identical on both sides. Character movement is
    predicted, so a blocker that exists only on the server makes the client rubber-band at the base edge.
    `StaticMeshActor`s don't replicate.
  - A pak edit that adds actors to a `.umap` is beyond AssetPatch.
  - Check in a match:
    - a hero who leaves can't re-enter;
    - teammates still inside aren't affected;
    - death and the next round unblock;
    - the pre-round spawn trapping (`GS_MOBA_Battle.PreRoundInvulAndSpawnTrapping`) and the `SpawnTrapperCylinder`
      don't conflict.
- **Size**: M (FangsHost + FangsBoot, so a player update). This is gameplay through hooks, so it needs the user's OK
  (decision of 15 Oct).
- **Open**:
  - Does the base laser stay? Not asked; the request is about re-entry.
  - Does the base also heal in Feb ("fountain")? Not checked.

## Work several items share

- **One balance patch file**: `tools/patch/patches/balance.json` (new, `"enabled": false` until tested) for all the
  value edits. None of its assets overlap `ccrevert.json`, except that Rowan's Dourling Dive asset holds the Caltrops
  code (other functions).
- **New AssetPatch edit types** (each size-neutral):
  - `set-export-prop`: a value in any export, by a dotted path with array indices. Unlocks Brutus' HP, Ethryn's
    shield width, Belroth's boulder radius, Astrada's cage colour, hiding the Caltrops box, and map edits. About
    half a day.
  - `set-name-const`: swap the FName of a literal in one call (Caltrops VFX tag, the pure-pak Rowan passive).
  - `insert-call`: only into functions without jumps (the CC-immune dashes).
  - `set-literal`: EX_True → EX_False (Rush).
  - `add-text`: a new string-table row (the knock-up label, Pwyff's Saplings).
- **Gameplay through FangsHost.** The user decided on 15 Oct that gameplay changes to the game's data go into the pak,
  not runtime hooks. Some items here need new logic the pak can't express: Rowan's heal tick, Wylde's dummy-phase ammo,
  Fiorne's stack re-init, the training phase/timer, `MaxRounds` per lobby, team shuffle, keeping dummies. They need
  the user's OK as FangsHost changes, or a heavier AssetPatch op that recomputes jumps.
- **Netcode settings** (all rubber-banding items): A/B the Dec 2023 values (net tick 60, no listen-server clamp,
  higher rate caps, `MAXPOSITIONERRORSQUARED` 3.0) on the servers first, then the shipped client ini. The template's
  warning applies: a 100000 rate cap once dropped players in hero select. Re-test with `test_lobby.sh` several times.
- **Tests.** Every pak change gets a `test_patch.sh`-style match (with and without the pak). The netcode A/B and the
  per-map fps runs follow the measurement plan in the optimization section. Never run them while people play.

## Questions sent to a community member (Q1-Q42)

General: 1 where presets break; 2 captain wait length; 3 dash immunity (old exactly? Rush: uninterruptible or immune);
4 green Shard cleanse too; 5 knock-up word or stuns, other symptoms; 6 Augments wording; 7 what players see when
training servers stick; 8 remove or weaken the two artifacts. Custom lobby: 9 settings before the first game vs a
rematch, chat commands OK; 10 where Bo5+ applies, how to pick it; 11 random vs skill, parties, when; 12 spectator
audience and priority. Training: 13 TRAINING tile or Solo lobby; 14 which timer; 15 stay in the augment phase vs swap
mid-round, Solo lobbies too; 16 is the island `LE_BeautifulCorner`; 17 auto-accept from training. Lag: 18 Crownwatch fps
vs teleporting, when, PC; 19 another map seen through the floor?; 20 rubber-banding better in older playtests?;
21 Somnia ult: who rubber-bands, 4 ticks/s OK; 22 Tufts: own screen or others, stop-dead OK. Heroes: 23 cage colours;
24 Ishir sound bug or wish, when; 25 where Rowan heals, old or tooltip heal; 26 Propagator: only the bar wrong?;
27 Caltrops placement, root or stun, look; 28 Pwyff's Saplings confirm, weaker or not, the cut-off idea; 29 Wylde RMB
version, hold-to-fire, shared cooldown; 30 full gun in the dummy phase; 31 Ethryn third hit; 32 shield width vs visual,
slow zone shrinks; 33 smaller boulder for everyone; 34 Fan the Hammers vs the shield; 35 Brutus 1050; 36 Zoey heal:
tooltip 60 or real 60; 37 RMB heirloom durations, Shieldnip shield; 38 Zoey ult VFX: which part, who, which skin; 39 ult
tooltip 200 vs real 150; 40 when Fiorne's stacks break; 41 "red" = combat heirlooms, Stormlense ramp; 42 Rayo M1:
shorter draw or walk while drawing.

## Answers (a community member, 16 Oct)

A community member filled in the PDF the same day. His ticks and notes, decoded (`q<NN>` fields of the returned PDF):

| Question | Answer | Notes |
|---|---|---|
| Q1 Presets reset your augments | In a match, on the augment screen (the Presets tab) | so far there is no loadouts screen in the main menu. it should be in inventory->heroes menu as a tab after you click on a sepcific hero. would be nice if you add this here as well though! make sure the loadouts are persistent between here and the in game augment selection screen |
| Q2 The “choosing captain” wait | Something else (write it below) | can you add an option in custom games (a checkmark) to vote on who will be ally captain for a round & then give people about 8 seconds to vote for a specific captain? (cant pick same captain twice in a row). If this option is not picked or the gamemode is casual/ranked, just skip this "vote for captain screen" entirely and instantly start on augment selection screen |
| Q3 CC immunity on dashes (Rowan, Belroth, Rush) | a) Yes, exactly like the old version<br>b) The dash keeps going, and you get stunned when it ends (like the old version) |  |
| Q4 Green and blue Shards: instant again | Heal at once, nothing else |  |
| Q5 Knock-ups show “MISSING STRING TABLE ENTRY” | a) Turn them all into stuns<br>b) Yes, only the text |  |
| Q6 Renaming “Heirlooms” to “Augments” | Combat Augments, Utility Augments, Ultimate Augments |  |
| Q7 Training servers not freed | Making a lobby or a Training fails; It works again after a few minutes | currently there is no reconnect feature. Could you add this for custom games? (training does not need this) |
| Q8 Removing Shardseeker and Wing Rush | Remove them | Somnia hero is missing most of the artifact choices, i forgot to mention this. please make them all available to her (minus these 2 removed ones) |
| Q9 Changing mode and map inside a lobby | a) Change the map or size before the first game, without making a new lobby<br>b) We really need buttons | the people in the lowest slots should be put in the "users in lobby" screen (like when you click the (-) button on yourself. for now, if the game is started with users in this list, they should just be kicked. at a later point if there is spectator mode, these players should be spectators. |
| Q10 Best of 5, 7 or 9 | a) Only in custom lobbies<br>b) As an extra mode in the list when making the lobby (needs a mod update) | they matter a bit but not super much. But please add a dropdown for this in the lobby or 2 buttons to go more/less rounds (<) (>). make it cleanly fit the rest of the lobby screen. feel free to move other things in the lobby screen though |
| Q11 Randomize teams | a) Fully random<br>b) Yes<br>c) When the owner asks for it | in the custom lobby, just add a single click button to fully randomize teams. for casual&ranked, matchmaking doesnt matter yet so you can skip it (except do keep people in a party on the same side) |
| Q12 Spectator mode | a) Friends watching each other; Recording videos<br>b) Not needed for now | short delay is fine, best would be seeing the fog of war from the perspective of the team that you are currently watching |
| Q13 Which training do you use? | Both | whichever doesn't need to block a full server. bonus points if you add a dps & damage dealt number to these. also currently dummies are lagging the game quite a bit, look into it if you can make them less laggy/causing fps drops |
| Q14 Which timer should never run out? | The augment-pick timer, while the dummies are there | even after the round starts, just keep the dummies alive in training mode instead of making them vanish like in an actual game |
| Q15 Changing augments after locking in | a) Stay in the augment phase with the dummies as long as I like, and start the round myself<br>b) Yes | if its too hard to allow changing augments later, starting the round manually is fine. If you opt for this, then allow players to take damage in this phase in training mode. |
| Q16 The “blue flying island” practice mode | Yes, that’s the one | the current training tile just loads a solo game on the embersong map, it does not use this extra map. would be banger if you could give the option to go into either of these. |
| Q17 Training while in queue | Accept it automatically and take me to the match |  |
| Q18 Crownwatch | a) Both<br>b) In big team fights | graphics settings are on high, 90% texture streaming quality. the best way to describe it is stutters, the shown fps stays at 144 but its not true. additionally to these fps drop stutters, there is teleporting/rubberbanding in bigger team fights. All maps have this to an extent but crownwatch by far the most. my cpu&graphics card: ryzen 9 7950x and amd radeon rx 7900xt |
| Q19 Other maps loaded below the map | People said so, and we saw fps drops |  |
| Q20 Rubber-banding in general | Don’t know | i think older versions were worse, current felt better than old ones. but still happens too often |
| Q21 Somnia’s ult makes people rubber-band | a) Everyone on screen, even players it didn’t hit<br>b) Yes | idk |
| Q22 Tufts’ Space (Wing Dive) lag | a) On my own screen when I play Tufts<br>b) No, the slide is part of Tufts | it was reported by player tigga. his ping is pretty low afaik like ~30ms & hes not on wifi |
| Q23 Astrada: ally and enemy cage colours | a) Yes, exactly the same<br>b) Ally yellow-orange, enemy red<br>c) Yes |  |
| Q24 Ishir: gun sound on the ult | a) A wish: we want a gun sound on the ult<br>b) When the mark on the enemy pops | yeh. use a shotgun sound but make it not overly loud. also could you colour the hp that an enemy is about to lose from ishir ult differently? like croak ult in battlerite |
| Q25 Rowan: passive stops healing | a) The green ring around a Sourblossom (E); The arc from Earth Rend (right click); The ult’s overgrowth<br>b) Like the old version: 2% of missing health per second plus 3 per second | most of the time rowan is actually healing correctly from E (sourblossom) overgrowth area and from his M2. It seemed to happen more likely on captains round but not sure. picked augments do not seem connected(?) possibly an ally using spite could have caused it but not sure. it is more like a rare bug. also add this +3 per second to the tooltip. |
| Q26 Rowan: Propagator’s charge bar | a) Yes, only the bar is wrong<br>b) No |  |
| Q27 Rowan: Dourling Caltrops | a) On the path Rowan just dashed (behind)<br>b) Root, like now (can’t move, can still cast)<br>c) Thorny, like Iron Thorns | 0.75s root and vines staying 3s is good. make sure the space recast also spawns them when picking that augment |
| Q28 Rowan: the item with missing text | a) No<br>b) Something else: see my idea below | turn it red, name it "Burning Harvest" and make the effect:  "Using Glade slash on a sourblossom destroys it, applying its damage to enemies in the area of effect". (in other words: m1 a plant to pop it, applying its dot to enemies in its area. however, it does not slow when applied this way. make sure shardpouch does work in combination with it.) |
| Q29 Wylde: the old RMB | a) Yes, but with different numbers (write them below)<br>b) –<br>c) Yes | 95 damage, 1 ammo, 1 second cooldown, and hold to keep firing should also exist |
| Q30 Wylde: ammo during the dummy phase | Yes | no |
| Q31 Ethryn: the third LMB hit | Something else (write it below) | do 40-40-50 |
| Q32 Ethryn: shield too wide, reflects from behind | a) Only as wide as her body (the shield’s look may be a little wider)<br>b) No | will do. Could you please shrink the shield visual a bit as well, like 15% less wide & 10% less tall to not make it look out of proportion |
| Q33 Ethryn’s shield and Belroth’s boulder | No, only fix how early the shield reflects it (harder) | the boulder hits other heros at a normal timing, only ethryn shield reflects it wayy too early (and maybe tufts suck thing, not sure). so please fix this specific interaction |
| Q34 Ethryn’s shield and Wylde’s Fan the Hammers | The bullets come back, each with its normal damage | it is not fan the hammers (shift) that im talking about, the issue is wylde E (shotgun that self knockbacks a bit). normally wylde E deals damage once, but on ethryn shield reflect each of the little projectiles deals the full damage. how much damage exactly im not sure, but easily 500+ it just depends how close he is to ethryn |
| Q35 Brutus: +100 health | Yes, 1050 |  |
| Q36 Zoey: LMB heal 48 to 60 | – | i wasnt aware the actual number was 40. So instead, increase her actual healing to 50 and fix the tooltip. |
| Q37 Zoey: shields | a) Yes<br>b) Keep 125 |  |
| Q38 Zoey: invisible ult effect | a) Both<br>b) Everyone<br>c) Hellhound colours | i for sure saw it missing on hellhound, it might exist on other skins too not sure. |
| Q39 Zoey: the ult heals less than it says | Fix the text to say 150 |  |
| Q40 Fiorne: 0 Bunny Stacks | a) Not sure<br>b) No, it stays broken all match |  |
| Q41 Rayo: the “red” heirlooms | a) Yes<br>b) A smooth rise to +50% at max range (takes longer to make) |  |
| Q42 Rayo: standing still for LMB | A shorter draw: stand still 0.25 seconds (like the old version) and wait a bit longer after, same shots per second |  |

### What the answers change

- **Captain wait (Q2):** skip the screen entirely and go straight to augment selection. Exception: a new custom-game
  option (a checkbox) for a teammate vote on the Captain, about 8 s, no same Captain twice in a row. That option is
  new lobby UI.
- **Knock-ups (Q5):** all become stuns (`rename-import` `BP_GE_KnockUp_C` → `BP_GE_Stun_C` in `DoTargetKnockUp`), even
  though the missing text was the only problem.
- **Lobby (Q9, Q10, Q11):** real buttons, not chat commands:
  - map and size;
  - rounds (a dropdown or < > buttons);
  - a one-click team shuffle.

  When the size shrinks, the lowest seats move to the "users in lobby" list, and they're kicked if the game starts
  with them still there. All of this is new lobby UI (FangsBoot or widget edits) plus FangsHost.
- **Spectator (Q12):** not now.
- **Training (Q13-Q17):**
  - both maps, and it shouldn't block a whole game server (Training on the player's PC);
  - the augment timer never runs out, the player starts the round, the dummies stay alive after it, and damage is
    taken in that phase;
  - also in custom Solo lobbies;
  - a match found while training is accepted automatically.

  New: DPS and damage-dealt numbers, and the dummies' own lag.
- **Q16 contradicts our finding:** a community member says the TRAINING tile loads a solo game on Embersong, not the island. To
  check: what our backend or mods do to the Training session's map.
- **Q18:** a Ryzen 9 7950X + RX 7900 XT on high settings stutters while the fps counter shows 144 (frame pacing, not
  low fps), plus teleporting in big fights, worst on Crownwatch.
- **Q22:** Tufts rubber-bands on the Tufts player's own screen at about 30 ms ping on a wired connection, and the
  slide stays. So the fix is the sync and the network settings, not `VelocityOnFinishMode`.
- **Q25 contradicts our finding:** Rowan "mostly heals correctly" from Sourblossom overgrowth and M2. We read the Feb
  passive heal as ≈ 0. Measure it in a match before changing anything. Also: rare, maybe more often in Captain
  rounds, maybe an ally's Spite; add the +3/s to the tooltip.
- **Q28:** the screenshot item becomes **Burning Harvest**, a red (combat) heirloom: Glade Slash on a Sourblossom
  destroys it and applies its damage over time (no slow) to enemies in its area; must work with Shardpouch. New
  code. A community member ticked "not this item" at Pwyff's Saplings; which item the screenshot shows needs a check.
- **Q29:** Wylde's RMB: 95 damage, 1 ammo, 1 s cooldown, hold to keep firing (range: the old short range, to confirm).
- **Q31:** Ethryn's LMB 40-40-50.
- **Q32:** the reflect zone as narrow as her body, but the slow-and-push zone stays as it is (one box today, so they
  must be separated). The shield's visual is 15 % narrower and 10 % lower.
- **Q33:** keep the boulder's size; only the shield's early reflect of it gets fixed (maybe Tufts' suck too).
- **Q34:** it's **Wylde's E, Lamblaster** (`Gunslinger/Skill4`), not Fan the Hammers. Normally it deals damage once; a
  reflected Lamblaster deals full damage per pellet (500+ up close). Wanted: the same damage as a normal hit.
- **Q36:** Zoey's real LMB heal goes to 50, and the tooltip shows the true number.
- **Q41:** Stormlense rises smoothly to +50 % at max range (code).

### Checked after the answers

- **Q16, Training on Embersong:** most likely our bug. FangsBoot's `onCreate` (`tools/ue4ss/Mods/FangsBoot/scripts/main.lua`,
  the `/zeuz/sessions` request) sends `map_level` = `pm.FindMapLevel`, the map of the create-lobby menu. TRAINING sets
  the game instance's `MapGameLevel` = `LE_BeautifulCorner`. To confirm in a test, then send the Training map.
- **Q5, knock-ups → stuns:** `DoTargetKnockUp` (`BP_FL_MOBA_FunctionLibrary`) only applies `BP_GE_KnockUp`, which grants
  `BP_GA_KnockUp` (the airborne motion). Swapping the effect for `BP_GE_Stun` therefore removes the fly-up. The
  proposal says so and asks again.

### The proposal (16 Oct)

A second fillable PDF for a community member (made 16 Oct, sent by the user): 24 cards of "now → after", each with OK / Change something, a few follow-ups (Q5
fly-up, Somnia before or after the 15 Oct fix, how to start a training round, Wylde's RMB range, where Stormlense's
ramp starts), Fiorne for information, and a "later" list (bigger features) to rank. Nothing for the community list is
built before his OK.

### a community member's OK (16 Oct, second PDF)

Everything OK'd as proposed, except:
- **Captain vote (card 2):** wanted now: "put the captain voting option in custom game now".
- **Ishir (card 15):** a specific shotgun sound from a sound website instead of Wylde's Lamblaster. Open: the sound's
  licence (we redistribute what we ship) and how to add a new sound to an FMOD game. The user decides.
- **Rowan (card 16):** don't change Dourling Caltrops' tooltip key ("I might just have different keybinds").
  The tooltip also names Wall of Roots; it stays as it is.

Follow-ups answered:
- knock-ups become stuns even without the fly-up;
- his Somnia game was before the 15 Oct fix;
- F6 starts a training round;
- Wylde's RMB keeps the old short range (562.5);
- Stormlense rises from 0 % at the start to +50 % at max range;
- Fiorne "sounds good".

Order for the bigger features:
1. lobby buttons;
2. reconnect;
3. the captain vote (wanted in this update);
4. Burning Harvest;
5. Ishir's health preview;
6. Training on the player's PC and less laggy dummies.

Later: the Loadouts tab, DPS numbers, spectating.

Build started 16 Oct in five streams, branches from `fiorne-restore`:
- `cp-values`: values and texts, `community.json`;
- `cp-rowan`: Rowan and the CC-immune dashes;
- `cp-heroes`: Ethryn's shield, Lamblaster, Stormlense, Zoey's ult VFX, Astrada;
- `cp-modes`: Training, base blockers, presets, artifacts, Wylde's dummy ammo, the Training server grace;
- `cp-lobby`: lobby UI, the captain vote, reconnect research.

Each writes `docs/recon/community-build-<area>.md`.

### New requests from the answers

- Loadouts in Inventory → Heroes (a tab per hero), the same loadouts as the in-match presets (Q1).
- Reconnect to custom games (Q7).
- Somnia "missing most of the artifact choices" (Q8). One cause was fixed in `deploy-2026-10-15-2336`; check
  whether a community member's games were before it.
- Ishir: a shotgun sound (not loud) when the ult's mark pops, and the health an enemy is about to lose shown in
  another colour, like Croak's ult in Battlerite (Q24).
- Dourling Caltrops also on the Space recast (Q27).

# The six stream reports

As the streams wrote them (16 Oct), headings one level down. Where they disagree with the table above, the table wins (it is newer).


## Stream 1: General + Artifacts (community patch notes)

Static research, Feb 2023 build (the live one) unless noted. Pseudocode paths are under `work/bp-2023-02-15/MOBA/Content/`
(Aug: `work/shard/bp-aug/...`, Dec: `work/bp/...`). CDO values from `work/cc-audit/props.py` (Aug / Feb / Dec).

---

#### FIX PRESETS (trying to save a preset just resets equipped augments to one of the standard builds)

- **What it is**: the in-match preset panel (`UI/MainMenu/WB_LoadoutPresets`, inside `UI/Hud/WB_PreRoundSelection`).
  Two "standard builds" come from `DT_Presets` (Build1/Build2 per hero); the custom presets are a JSON object
  `LoadoutAugments` = `{<hero>: {CurrentLoadoutIndex, Loadout1..3: {Name, Augments[]}}}`.
  - Load: round 1 only, `WB_LoadoutPresets.GetHeroLoadouts` → `BP_PC_MOBA_PlayerController.GetHeroLoadouts` (a **server
    RPC**) → on the game server `UAccelByte::ServerRetrievePlayerRecord("PROFILE_LOADOUT_KEY", id)` → success/failure
    callback → client RPC `ControllerUpdateLoadouts(json)` → `WB_LoadoutPresets.UpdateLoadouts` sets `LoadoutAugments`
    (an empty string gives a fresh empty object).
  - Save: lock-in calls `SetHeroLoadouts` → server RPC `SaveHeroLoadouts(json)` → `ServerAddOrReplacePlayerRecord`.
  - **`ServerRetrievePlayerRecord` is one of the server CloudSave calls compiled out of this client exe** (FangsHost
    `main.lua` comment; `docs/clients/fangs-2023-02-15-b10554626.md`), and FangsHost only shims the *lobby* PC's calls,
    not `BP_PC_MOBA_PlayerController:GetHeroLoadouts` / `SaveHeroLoadouts`. So neither callback ever fires, and
    `UpdateLoadouts` never runs: `LoadoutAugments` stays an uninitialised JSON object (a null `TSharedPtr`).
  - Saving (OK button, WB_LoadoutPresets.txt ~L6038/L9719): `UpdateHeroLoadout` writes each slot into
    `LoadoutAugments`, then `SelectHeroLoadOut(SaveIndex)` → `RefreshHeroLoadouts`: `JsonHasField(LoadoutAugments, hero)`
    is false → `LoadoutIndex = 0` → `SelectRecommendations(0)` (debug text "MRE: Apply recommended") → **the equipped
    augments are replaced by standard build 1**. That is exactly the reported symptom. (Writes into a null JSON object
    are lost; this part is inferred from the symptom, the plugin's source isn't in the build.)
  - Even if it worked inside one match, presets would never persist: the save also goes through a server CloudSave
    call, and nothing loads them back.
  - The main-menu Loadouts screen (`WB_LoadOuts`) is a different path: client CloudSave `ReceivePlayerRecord` +
    lambda `update-loadouts`, which our backend implements (`fangs_backend.py` `fangs_update_loadouts`, stores
    `PROFILE_LOADOUT_KEY`, exported to `records/players/<uid>/PROFILE_LOADOUT_KEY.json`). Same JSON shape. Untested.
- **How we'd do it**: FangsHost shim (server only, like the lobby CloudSave shims; not a gameplay change, so the
  "gameplay goes in the pak" decision doesn't apply):
  1. Hook `/Game/BluePrints/Gameplay/BP_PC_MOBA_PlayerController.BP_PC_MOBA_PlayerController_C:GetHeroLoadouts`:
     read `records/players/<PCPlayfabId>/PROFILE_LOADOUT_KEY.json` (or `""`) and call `pc:ControllerUpdateLoadouts(json)`
     (client RPC, deferred 50 ms like the other shims). This alone fixes the reset within a match.
  2. Hook `...:SaveHeroLoadouts`: write the JSON as `fangshost_loadout-<uid>-<time>.json` next to the result files;
     `backend/hosts.py` picks it up (as it does `fangshost_result-*.json`) and stores it as `PROFILE_LOADOUT_KEY`, so the
     menu and the next match see it. Call `pc:ControllerSavedLoadouts(true)`.
  Backend: ingest + validate (object, size cap, only the player's own uid).
- **Effort / risk**: M (Lua hooks + backend ingest + a test). Low risk: only the preset panel is affected. Server deploy,
  no player update.
- **Confidence**: high that the load/save never reaches our backend (stub + no shim); medium-high that this is the reset
  cause. Match test: one player, item selection, save a custom preset → equipped augments stay; next match → the preset
  is offered again; `fangshost.log` shows the served/saved record.
- **Questions for a community member**: Where does it happen: in the augment screen at the start of a match (the "Presets" tab), or
  in the main menu's hero Loadouts screen? Does picking one of the two standard builds work? (Our guess: in-match, and
  it happens on every save.)

---

#### make intro "choosing captain" faster (waiting on blank screen for like 10s)

- **What it is**: the captain phase is `BP_RS_King` (`BluePrints/Gameplay/GameRules/King/BP_RS_King`). It lasts while
  `IsAtKingSelection()`: now − `KingSelectStartTime` < `GetKingVoteMinTime()`, which is
  `SelectFloat(MaxKingVotingTime, MinCaptainSelectTime, CurrentRound >= <local PC>.WB_HUDGamplayRef.KingVoteRound)`.
  - CDO: `MaxKingVotingTime` Aug 10 / **Feb 18** / Dec 2; `MinCaptainSelectTime` 2 / 2 / 2. `WB_HUD.KingVoteRound` = 4.
  - On a player's PC the HUD exists, so rounds 1-3 use 2 s (no vote UI), round 4+ 18 s (vote UI).
  - **On the game server there is no HUD**: `GetPlayerController(0)` is a remote player's PC whose
    `WB_HUDGamplayRef` is None, so the compare reads `KingVoteRound` = 0 and the server always waits
    `MaxKingVotingTime` = **18 s**. The client's UI is done after 2 s and shows nothing for the remaining ~16 s: the
    "blank screen". (Same on the developers' dedicated servers; Dec changed `MaxKingVotingTime` to 2.)
- **How we'd do it**: patch pak `set-default` `BP_RS_King_C.MaxKingVotingTime` 18.0 → 2.0 (Dec's value) or another
  number a community member picks. Server and client get the same file.
- **Effort / risk**: S. Side effect: in round 4+ (only Bo5 and longer) the teammate vote for Captain would also get
  only 2 s, i.e. practically no vote.
- **Confidence**: medium-high (the server-side None read is inferred from code). Match test: time the phase from
  `StartKingSelect` to `StartItemSelect` on the server (FangsHost log line per round state) before/after.
- **Questions for a community member**: Do you want the Captain to just be picked fast (2 s, like the developers' last version), or
  keep a few seconds so teams can vote in later rounds (e.g. 5 s)?

---

#### Bring back CC immune on some dashes that was removed when CC's got turned into roots (rowan, belroth, rush boon)

- **What it is**:
  - **Rowan, Dourling Dive (Space)** `Gameplay/Abilities/Player/WoodenSword/Skill1/BP_GA_WoodenSword_Skill1`: Aug
    (`WoodenSword/Q/BP_GA_WoodenSword_Q`) called `ApplyUnstoppable()` right before `Lock Pre Dash()`: a 2 s
    `BP_GE_AntiDisplacement_Duration` granting Effect.AntiCharm/AntiFear/AntiRoot/AntiStun, removed when the dash ends.
    Feb still has the function and still removes the effect at the end, but **nothing calls it**; the dash is also
    flagged `CanBeCrowdControlled` (ends on `Effect.LockMovement`). Dec: called only with the Overgrowth buff.
  - **Belroth, Vicious Lunge (Space)** `Characters/Bigboi/Gameplay_Abilities/Skill1/BP_GA_BigBoi_Skill1`: Aug called
    `ApplyUnstoppable()` (AntiRoot + AntiDisplacementandCC) before `MakeCastUIData(...)`. Feb: the function exists (even
    improved: lasts dash time + cast time) and `RemoveUnstoppable()` still runs, but **no call**. Dec: same as Feb.
  - **Rush (boon)** = row "Flash" (`active_flash_title`), `Items/Characters/Generic/Actives/Flash/BP_GA_Flash`. Aug: the
    dash could not be interrupted. Feb added two things: the dash payload has `Event.Identifiers.CanBeCrowdControlled`
    = **true** (a constant), so `BP_GA_ServerInitiatedDash` cancels it on `Effect.LockMovement`; and the ability itself
    waits for `State.Dead`/`Effect.LockMovement` and ends. (Feb also raised its cooldown 30 → 70 s, 90 modified.)
    Aug Rush had no anti-CC effect either: "immune" there meant "not stopped by CC".
- **How we'd do it** (patch pak; the existing ops can't add a call or flip a constant, so AssetPatch needs two new
  same-file edits):
  - Rowan + Belroth: new op `insert-call`: insert a call to the ability's own `ApplyUnstoppable` at the start of a
    *straight-line* function called once at dash start: Rowan `Lock Pre Dash` (no jumps), Belroth `MakeCastUIData` (no
    jumps). In a function without jumps, nothing else needs moving (only the function's script size). The ubergraph is
    off limits (its offsets are referenced from event stubs and latent actions).
  - Rush: new op `set-literal`: EX_True → EX_False on the `CanBeCrowdControlled` flag (1 byte); and swap the
    `Effect.LockMovement` tag literal in the `MOBAWaitGameplayTagsAdd` container to an existing tag (same size), or leave
    that wait if a community member wants the Rush to end when stunned.
  - Fallback without new ops: FangsHost post-hooks (`Lock Pre Dash` → `ga:ApplyUnstoppable()`), server only. Against the
    "gameplay goes in the pak" decision (user, 15 Oct), so only if the user OKs it.
- **Effort / risk**: M (two small AssetPatch ops + `test_patch.sh` runs casting a stun on the dashing hero). Risk low-medium
  (balance; the developers removed it on purpose and kept it removed in Dec).
- **Confidence**: high on what changed; medium on the new op (needs a roundtrip check of the edited functions).
- **Questions for a community member**:
  - Rush: should it just not be stopped by stuns (how it was in the old version: you still get stunned at the end),
    or should you be fully immune while dashing?
  - Rowan / Belroth: the old version made them immune to stun, root, charm and fear for the dash. Belroth's also
    stopped knockbacks. OK to bring back exactly that?
  - Any other dashes you remember being unstoppable?

---

#### REMOVE MICHAEL MOUSE FOUNTAIN

*Identified after this report: the base re-entry, see "Base blockers" at the top.*

- **What it is**: not identified. No asset or map actor is named fountain/mouse in any Feb map (each arena map is one
  `.umap`: Embersong `LE_Arena02_Map`, Stormheart `LE_Arena06_Map`, Crownwatch `LE_Payload03_Map`). Gameplay objects that
  could look like a fountain with "ears": the channeled **Health Shrine** we put back with the old Shard system
  (`BP_HealingOrb`, a brazier + orb, `SM_Garden_Brazier_Top_01`/`SM_Garden_HealthPack_01`), the **Shard capture zone**
  (`BP_TeamGoalChannel_Buff`, `SM_Queendom_GroundBase`), the Shard spawn shrines (`BP_East/WestShrine`), the Feb
  **energy/berserker pickups** (`BP_BerserkerPickup`, 3 per map), or plain decoration (Embersong has Queendom statues
  and a water plane).
- **How we'd do it**: depends on what it is.
  - A gameplay actor (shrine, pickup, zone): FangsHost on the game server destroys it / doesn't spawn it at match start
    (like the old Shard switch). Server only.
  - Decoration in the map: hidden on the clients (FangsBoot hides the actor on map load, player update) or a pak edit of
    the map (new op to set `bHidden`/collision on one export). If it blocks movement, server and clients must agree,
    so the pak.
- **Effort / risk**: S-M once identified.
- **Confidence**: low (unknown object).
- **Questions for a community member**: Which map is it on, and where (a screenshot is best)? Is it something you can use (heal,
  pick up, stand in) or just decoration? Is it in the way (blocks walking or shots), or just ugly?

---

#### Make green shard heal and blue shard mana instant again

- **What it is** (old Shard system, `docs/recon/shards.md`; the code names are Red/Blue/Yellow, the in-game capture
  effects are green/blue/yellow: `NS_RelicCapture_Ally_Green`…). Turn-in buffs `BP_TeamGoalChannel_Buff.BuffArray`:
  - **Green (Life)** `Gameplay/Effects/Shared/BP_GA_RedBuff_Garden` (a GE): Aug `ConditionalGameplayEffects =
    [BP_GE_RedBuffHeal]` = **instant heal of 50 % max HP** (parent `BP_GE_OrbHeal`) that also removes negative effects.
    Feb removed that and grants `BP_GA_GreenBuffHoT`: 50 % max HP **over 5 s** (`Duration` 5.0,
    `PercentHealthTotalHeal` 0.5, 4 ticks/s, stops when full). Lifesteal +10 % unchanged.
  - **Blue (Aether)** `BP_GE_BlueBuff` → `BP_GE_ManaFill`: Aug: instant, Mana += MaxMana (**full at once**). Feb:
    infinite GE granting `BP_GA_ManaFill`: +`ManaPerQuarterSecond` 125 every 0.25 s until full (0 → 2500 takes 5 s).
  - The same buffs are also given by `BP_GA_CaptainLastLifeRage` (Captain's last life) and `BP_BuffActor` (Feb's
    Prismatic Shard, hidden with the old system), so those become instant too.
- **How we'd do it**: patch pak, 2 × `set-default`:
  - `BP_GA_GreenBuffHoT_C.Duration` 5.0 → 0.25 (the whole 50 % in the first tick, within 0.25 s).
  - `BP_GA_ManaFill_C.ManaPerQuarterSecond` 125 → 10000 (full in the first tick).
  - Restoring Aug's exact effect (the conditional instant GE + cleanse) needs `copy-default` of an object reference,
    which the tool refuses; not needed for "instant".
- **Effort / risk**: S. Check in a match that Energy is clamped to max (no overflow above the bar).
- **Confidence**: high on the cause; medium on "first tick ≈ instant" (0-0.25 s delay).
- **Questions for a community member**: Is "full in a quarter of a second" instant enough? The old green Shard also removed slows
  and other bad effects from your team when it healed: do you want that back too?

---

#### All knockup cc currently doesnt work properly, it is showing "missing string table entry" above enemy heads (zoey ult, belroth space). You could change these to stun though

- **What it is**: every knock-up goes through `BP_FL_MOBA_FunctionLibrary.DoTargetKnockUp` → `BP_GE_KnockUp` (new in Feb,
  LockCasts + LockMovement, grants `BP_GA_KnockUp`, blocked only by Effect.AntiKnockUp). The overhead/status-bar labels
  come from `DataContent/DataTables/DT_GameplayEffectData`: its KnockUp row points both labels at
  `FANGS_LOC_EN` key **`statusbar_statusname_knockup_lbl`, which doesn't exist** in the string table (every other CC
  row has its `status_effect_*`/`statusbar_statusname_*` key). Hence `<MISSING STRING TABLE ENTRY>`. Affects every
  knock-up: Zoey ult, Belroth Space, Brutus Head Splitter, Ethryn ult, Tufts LMB, Kiona Space heirloom, blast cones…
- **How we'd do it**:
  - Recommended: add the missing entry, `statusbar_statusname_knockup_lbl` = "KNOCKED UP" (or "AIRBORNE"). Needs a new
    AssetPatch op `add-text` (≈10 lines next to `ReplaceText`: `StringTableExport.Table.Add`). Client-visible text, pak.
  - Community's alternative: `rename-import` `BP_GE_KnockUp_C` → `BP_GE_Stun_C` in `DoTargetKnockUp` (one edit, all
    knock-ups become stuns). Changes balance: stuns are blocked by anti-stun (Cleanse, unstoppables) and knock-ups aren't.
- **Effort / risk**: S (text) / S (stun swap, plus a balance risk).
- **Confidence**: high for the text cause.
- **Questions for a community member**: Is the wrong text the only problem, or does the knock-up itself misbehave (enemy doesn't fly
  up, can still move or cast)? If we fix the text, which word: "KNOCKED UP" or "AIRBORNE"? Or do you really prefer them
  as plain stuns (then Cleanse and "unstoppable" effects would block them)?

---

#### change the name heirlooms to augments in menus

- **What it is**: every visible "Heirloom" is a string-table text (no hardcoded widget text found, ASCII or UTF-16):
  **17 entries, 20 occurrences** in 3 tables.
  - `LOC_EN_FEATURE_ROUNDSTART` (5): `augment_combative` COMBAT HEIRLOOMS, `augment_utility`, `augment_epic` ULTIMATE
    HEIRLOOMS, `flex_augment_help`, `tip_heirloom_artifact_desc`.
  - `FANGS_LOC_EN` (4): `heroes_heromastery_augments_tab`, `choose_hero_augment_title`, `heroes_heirlooms`,
    `Heirloom_roll` (HEIRLOOM ROLL).
  - `LOC_EN_FEATURE_TUTORIAL` (8, tutorial only): `tutorial_augments_ultimate/utility/types/heroabilities/combat/flex`,
    `tutorial_client_earncores`, `tutorial_client_coresheirloom`.
- **How we'd do it**: patch pak, one `replace-text` per entry (Heirloom→Augment, Heirlooms→Augments, HEIRLOOM(S)→
  AUGMENT(S)). Our own mods/launcher don't say "heirloom".
- **Effort / risk**: S. Wording: the game already uses "Augments" for *all three* kinds ("CHOOSE YOUR AUGMENTS!", "FLEX
  AUGMENTS", "BOON AUGMENT"; tutorial: "augments--choose from Heirlooms, Artifacts, and Boons"), so a blind replace gives
  sentences like "choose from Augments, Artifacts, and Boons".
- **Confidence**: high.
- **Questions for a community member**: In the game "Augments" already means all three kinds (heirlooms + artifacts + boons). Should
  heirlooms simply become "Augments" (Combat Augments, Utility Augments, Ultimate Augments), or something like "Hero
  Augments"? Menus only, or the tutorial texts too?

---

#### ARTIFACTS: Remove Shardseeker, Remove Wing Rush

- **What it is**:
  - **Shardseeker** = `Generic_BobAndWeave` ("channel Shards and Health Shrines 40 % faster"): one of *our* restored
    items, group `_old_shards` in `backend/seed/restore-feb2023.json` (on while `OLD_SHARDS`).
  - **Wing Rush** = `Generic_FlyPhoenixFly` (`position_flyphoenixfly_title`; "Aspect's speed +X % while you are near
    it"): a **stock Feb artifact** (in `BP_PlayerChar.GenericItems`, i.e. `itempaths-feb2023.json` `pools.Generic`).
  - What players can pick = `AvailableAugments` (`make_seed.py offered_augments`: stock pools + restored groups). The
    match HUD and the menus skip any item not in it; FangsBoot adds only the restored list the server sends.
- **How we'd do it** (backend seed, server deploy, no player update):
  - Shardseeker: move it from `_old_shards` to a parked key (e.g. `"_removed_community": [...]`; keys starting with `_`
    are parked).
  - Wing Rush: add a small `REMOVED = {'Generic_FlyPhoenixFly', 'Generic_BobAndWeave'}` in `make_seed.py` that
    `offered_augments` subtracts from `keep` (stock items can't be parked through the restore list). The one tutorial
    text that mentions Wing Rush (`tutorial_augments_position`) is never shown (no tutorial mode).
  - Docs: `docs/recon/items.md`, `shards.md` lists.
- **Effort / risk**: S. A preset/loadout that contained one just shows that slot empty.
- **Confidence**: high.
- **Questions for a community member**: none needed. (Optional: removed for being too strong, or useless? If too strong, we could
  also just nerf the numbers instead.)

---

### Summary

| Item | Mechanism | Effort | Confidence | Needs a community member? |
|---|---|---|---|---|
| Fix presets | FangsHost shim for the in-match preset load/save (+ backend ingest) | M | high (cause: medium-high) | yes (where it happens) |
| Captain select faster | pak `set-default BP_RS_King_C.MaxKingVotingTime` 18 → 2 | S | medium-high | yes (2 s or a bit more) |
| CC immune dashes (Rowan, Belroth, Rush) | pak, new AssetPatch ops `insert-call` (ApplyUnstoppable) + `set-literal` (Rush) | M | high (what), medium (op) | yes (Rush: uninterruptible vs immune) |
| Remove "Michael Mouse" fountain | FangsHost (gameplay actor) or FangsBoot/pak (decoration) | S-M | low (not identified) | yes (screenshot, map) |
| Green/blue shard instant | pak `set-default` GreenBuffHoT.Duration 5 → 0.25, ManaFill.ManaPerQuarterSecond 125 → 10000 | S | high | small (cleanse too?) |
| Knock-up "missing string table entry" | pak, new op `add-text` for `statusbar_statusname_knockup_lbl` (or rename-import KnockUp → Stun) | S | high | yes (text vs stun, other symptoms) |
| Heirlooms → Augments | pak, 17 × `replace-text` in 3 string tables | S | high | yes (wording, tutorial) |
| Remove Shardseeker, Wing Rush | backend seed (park + `REMOVED` set) | S | high | no |

Notes for other streams: `FANGS_LOC_EN map_augments_reopenaugmentselect_desc` = "[P] REOPEN AUGMENT SELECT" (the P key
the training-mode item mentions exists as a text). Rush's Feb cooldown went 30 → 70 s (90 modified), in case a community member asks.


## Community patch notes, stream 2: custom lobby, training, game-server lifecycle

Static research on 16 Oct 2026, Feb 2023 build (the live one) unless a build is named. Sources: Feb pseudocode
`work/bp-2023-02-15/` (paths below are under `MOBA/Content/`), Aug `work/bp-2022-08-26/`, Dec `work/bp/`, class
defaults `work/cc-audit/props.py`, string tables `work/cc-audit/st_feb.json`, `AssetPatch info` on
`work/extract-2023-02-15/`, the backend and FangsHost in the repo. Native facts: UPROPERTY flags read straight from
the Feb exe's UHT tables (a small PE reader, `CPF_Net` = replicated), and two Ghidra decompiles
(`tools/re/decomp.sh … GetItemSelectMaxTime CanSkipItemSelect`, output
`work/re/ghidra/MOBA-Win64-Shipping-88bd8dda/out/20261016T163323Z/`). Nothing was run against the game.

Key facts found on the way (used by several items):
- **Training** (Play → TRAINING) = `WB_PlayMenu` sets `MapGameLevel = "LE_BeautifulCorner"`, `MapPlayerCount = 1`,
  then `CreateCustomGame("Solo", "Basic Training")` (`UI/MainMenu/WB_PlayMenu.txt` ~L22811). So a Training is a
  1-player custom session on its own game server, map **LE_BeautifulCorner**, `MapGameMode` 0. The session body has
  `max_player: 1` and `settings.map_level` (seen in a logged `POST /sessionbrowser/.../gamesession`).
- **LE_BeautifulCorner is a floating island in the sky** (assets `TrainingGrounds/FloatingRocks2/…skybox_Island_*`,
  `Sky/Cloud2`, `HDRI_CartoonWater`) with 20 placed `BP_AI_FireMage` dummies. Aug 2022's Training used
  `LE_TrainingGround` (an older landscape test map with 6 teleporters, also still in the Feb pak). Dec 2023 uses
  BeautifulCorner like Feb. So the "blue flying island" is most likely the **Feb build's own Training map**, already
  installed.
- **The "dummy phase"** is the item-selection phase of every round: `GS_MOBA_Battle.PreRoundInvulAndSpawnTrapping`
  gives players immunity and calls `Spawn Preround Dummies` (BP_AI_FireMage at actors tagged `TeamADummySpawn` /
  `TeamBDummySpawn`, tagged with `TaggingSpawnedDummies` = `PreroundDummy`); at countdown start
  (`OnCountdownStart` → `RefreshPlayersAfterPreRound`) players are revived, put back at spawn and `Destroy Preround
  Dummies` removes every actor tagged `PreroundDummy` (`BluePrints/Gameplay/GS_MOBA_Battle.txt` L9407-10092,
  L13050-13537, L21806-21860). Only the arena maps have the dummy spawn tags (Arena02 has them; BeautifulCorner and
  TrainingGround don't).
- **Item-select timer** (native `MOBAGameStateBase`, replicated): `ItemSelectFirstRoundMaxTime` (offset 0x298) and
  `ItemSelectMaxTime` (0x29c), both `CPF_Net`. Decompiled `GetItemSelectMaxTime`: first round (TeamA+TeamB rounds won
  == 0) uses the first-round value, later rounds the other. The phase ends when `CanSkipItemSelect` is true:
  `(elapsed > max time OR AllPlayersSelectedItems) AND ItemSelectStartTime > 0` (BP override in GS_MOBA_Battle
  L1463; the native default returns false). `AllPlayersSelectedItems` = every player-controlled hero's
  `BP_PlayerState_MOBA_Hero.bSelectedItems`. With one player, locking in ends the phase at once.
- **Rounds to win**: native `MOBAGameStateBase.MaxRounds` (offset 0x280, editable, **not replicated**), class default
  in `GS_MOBA_Battle`: **Aug 3, Feb 2, Dec 5** (`props.py GS_MOBA_Battle`). `BP_AC_MatchReport` ends the match when
  `max(TeamARoundsWon, TeamBRoundsWon) >= MaxRounds` (`BluePrints/Gameplay/BP_AC_MatchReport.txt` L431, L3222). So
  Feb is first-to-2 (Bo3), Aug was first-to-3 (Bo5).
- Lobby settings travel with every joiner: each client sends `InitLobbyState(MapName, GameMode, Level, …, MatchSize,
  LobbyName, Owner)` from its own `UserMatch` save (`LoadMatchInfo`) → `BP_GM_Lobby_GameMode.GMSetupLobbyState` sets
  `MaxPlayers` and calls `GSSetupLobbyState` on the lobby game state (`BluePrints/Lobby/BP_PC_Lobby_PlayerController.txt`
  L242-256, `BP_GM_Lobby_GameMode.txt` L517, L3231). FangsHost already overrides `MatchSize`/`MaxPlayers`
  (`setLobbySize`) and `Level`/`MapName` (`setLobbyMap`) for matchmade games (`tools/ue4ss/Mods/FangsHost/scripts/main.lua`
  L364-418), so changing them server-side is proven.
- Lobby/match chat goes through the backend (`signalingP2PNotif` relay in `backend/social.py` L461-469), so the
  backend can read lobby chat lines. Note: the game sends a team/all line only to the *other* players in the lobby, so
  a player alone sends nothing.

Out of my scope but found: the "choosing captain" wait is most likely `BP_RS_King.MaxKingVotingTime`: Aug 10 s,
**Feb 18 s**, Dec 2 s (class defaults) — for stream 1.

---

#### Training match servers are not correctly freed when leaving the game
- **What it is**: Leaving a Training (menu Leave = `OpenLevel(LE_MainMenu_Map)` on the client, alt-F4 or a lost
  connection all look the same to the server: the player's connection ends). The game never ends a Training match by
  itself: `BP_GM_MOBA_GameMode.CheckGameOverFromLackOfPlayers` skips Training and 1-player games ("No need to Check
  because Training Mode", `BluePrints/Gameplay/BP_GM_MOBA_GameMode.txt` L5124-5135), and Training sends no match result.
  So only the backend's host manager stops it, and it treats Training like a real match that players may reconnect to:
  - `backend/hosts.py` `_watch_until_stopped` L302-304: once the server is off the lobby map, it is stopped only after
    `idle_grace` = **180 s** with 0 players.
  - `empty_for` L135-146 / `_reclaim` L148: a full server pool reclaims an empty server only after the same 180 s, so for
    3 minutes a new lobby or Training gets "no free game server slots" (the VPS has 2 slots).
  - `backend/fangs_backend.py` `session_create` L799: when the same player starts a new Training/lobby, their old
    Training server is kept because its "match is running" (`not lobby_open`) — meant for real matches with other players.
  - (The player count itself is fine: the arena's `K2_OnLogout` destroys the leaver's PlayerState, L9115-10461, and
    FangsHost counts remote PlayerControllers in `GameState.PlayerArray`, main.lua L201-213.)
  So each Training blocks one of the two servers for ~3 minutes after the player left, and a second Training right
  after needs a second server.
- **How we'd do it** (backend only, no player update):
  1. Mark solo sessions: in `handle_create_ds` set `host.solo = sess['game_session_setting'].get('max_player') == 1`
     (Training and custom "Solo" lobbies; optionally also `settings.map_level == 'LE_BeautifulCorner'`).
  2. `hosts.py`: a solo host that had its player and is empty stops after a short `solo_grace` (e.g. 10 s) wherever it is
     (lobby or arena); `empty_for` uses the same grace so `_reclaim` and `capacity()` count it at once.
  3. `session_create`: when an owner opens a new session, stop their old *solo* server even if launched.
  4. Optional: FangsHost writes `gi.MapGameMode` into `fangshost_status.json` so the backend can tell Training from a
     Solo custom lobby for logs.
  Tests: `backend/tests/test_hosts.py` with the fake game server (solo host empty → stopped after the short grace; reclaim
  takes it), then one real Training (leave by menu, by closing the game) and check the backend log line `stopping …`.
- **Effort / risk**: S-M (½ day with tests). Low risk; only 1-player sessions change.
- **Confidence**: high on the 180 s cause; medium that it is all the players see (check the VPS backend log for a
  Training host: `stopping … match over / empty` about 3 min after its player left, and failed lobby creations meanwhile).
- **Questions for a community member**: What do you see when it happens: lobby creation fails, "no free servers" in the menu, or
  something else? Does it go away by itself after a few minutes?

#### Allow changing between 1v1/2v2/3v3/4v4 and changing map while already in a custom lobby
- **What it is**: The create screen (`UI/MainMenu/WB_CreateLobby.txt`) has only a map and a mode combo box. The lobby
  screen (`UI/Lobby/WB_LobbyMenu.txt`) has no settings: Feb has an unused `SettingBtn` (declared, never bound); Dec has
  an `ObjectiveComboBox` (objective choice, a Dec-only system), nothing for map or size. The size mostly works as a cap
  already: FangsHost shrinks the match to the players present when the owner launches (main.lua L378-390), and the seed
  preselects the biggest mode (6vs6). The map is the lobby game state's `Level` (+ `MapName`), set by every joiner's
  `InitLobbyState` from their own save, which comes from the session browser entry.
- **How we'd do it**:
  - Server side (FangsHost): apply new `Level`/`MapName` and `MaxPlayers`/`MatchSize` with the existing `setLobbyMap` /
    `setLobbySize`, re-applied after every `GMSetupLobbyState` (a later joiner would otherwise reset it), only while
    `LobbyState == 0`. Shrinking below the players present: refuse, or kick the newest.
  - Backend: update the session entry (`settings.map_level`, `map_name`, `max_player`) so the lobby list and later
    joiners see the new values; tell the host through a file like `fangshost_match.json` (e.g. `fangshost_lobby.json`).
  - The owner's "button": cheapest is a **chat command** the backend reads from the owner's lobby chat (`!map
    crownwatch`, `!mode 2v2`), with a reply line; a real button needs a FangsBoot UI (UMG from Lua: no widget creation so
    far in our mods, so polling an existing button or text) and a player update.
  - Possibly the real wish is a **rematch**: after a match everyone is back in the menu and the lobby is gone ("lobbies
    close when their match starts; a finished match's server stops"). A "back to the lobby" (server travels back to
    `LE_Lobby_Map` with the same players) would let a group play map after map without recreating. L, untested.
- **Effort / risk**: chat-command version M (1-2 days; lobby UI may not refresh the map preview or slot count until a
  test shows it does); button version L; rematch L.
- **Confidence**: medium (server side proven in matchmade lobbies; client lobby UI refresh unknown).
- **Questions for a community member**: Is the problem changing settings *before* the first game, or playing several games in a row
  with the same group (needing a new lobby each time)? Would typing a command in the lobby chat (only the owner) be OK
  instead of buttons? When switching to a smaller mode with too many people in, what should happen?

#### Add Bo5 / Bo7 / Bo9 as lobby setting instead of only Bo3 (win score 2 → 3/4/5)
- **What it is**: `MaxRounds` on the arena game state: Feb 2 (first to 2), Aug 3, Dec 5 (see key facts). Native, not
  replicated, read by the match report (and very likely the native round-end state) on the server.
- **How we'd do it**: FangsHost sets `gs.MaxRounds = N` at arena BeginPlay (deferred, as `shards.lua` does), N from the
  backend per lobby. How the owner picks it, cheapest first: (a) a tag in the lobby name, e.g. `[Bo5]`, parsed by the
  backend at `session_create` (no player update); (b) a lobby chat command `!bo5`; (c) extra entries in the seed's
  `AvailableCustomModes` ("4vs4 Bo5" …) plus FangsBoot mapping the name to the player count (the create screen maps
  unknown names to 6) and passing N on (player update). A patch-pak `set-default` of `MaxRounds` 2 → 3 would change
  every match (Casual and Ranked too), which is a different decision.
- **Effort / risk**: S-M for (a) (FangsHost + backend, ½-1 day with a match test); M for (b)/(c). Risks: the HUD round
  pips/announcer lines (`PreRoundOneRoundLeftToVictory` in `BP_AC_VOManager`) may assume first-to-2, clients keep their
  own `MaxRounds` = 2 (not replicated), so "match point" voice lines/HUD may be off; check a Bo5 match end-to-end.
- **Confidence**: medium-high that `MaxRounds` decides the match end (match report code); the native round-end check was
  not decompiled yet.
- **Questions for a community member**: Only for custom lobbies, or also Casual/Ranked (Aug's playtest was first to 3)? Is "write
  [Bo5] in the lobby name" an OK way to pick it? Do Bo7/Bo9 matter (long matches; one server per match the whole time)?

#### Randomize teams button?
- **What it is**: Team = seat parity: `PS_LobbyHero_PlayerState.ChosenSlot % 2` (set by `SelectTeamSlotOnServer`,
  `BluePrints/Lobby/BP_PC_Lobby_PlayerController.txt` L13715-13950, which also sets `UserCharacterRP.ClientIndex`); the
  arena team is `ClientIndex % 2`. No shuffle anywhere in the build.
- **How we'd do it**: FangsHost permutes the present players' `ChosenSlot` (+ `ClientIndex`, `MarkPropertyDirty`, as
  the RPC does) while the lobby is still in state 0, triggered by the owner (chat `!shuffle`, or a lobby-name tag
  `[random]` applied at Launch). The backend could compute a **skill-balanced** split instead of a random one: it has
  every player's rating (`backend/skill.py`, `allocator.py` from Ranked) and passes the seat list to the host.
- **Effort / risk**: M (1 day). Risks: lobby slot UI refresh and chat team lists (`UChat.LobbyUsers.bTeammate` is filled
  from seats in the lobby/hero select) must follow; shuffle before hero select starts, never during it.
- **Confidence**: medium.
- **Questions for a community member**: Fully random, or balanced by skill? Keep friends/parties together? Only the lobby owner can
  shuffle? Shuffle on demand in the lobby, or automatically at launch?

#### Spectator mode
- **What it is**: The build has developer/marketing spectating, not a spectator seat: `BP_AC_Spectator`
  (`BluePrints/Character/Spectator/`) on a *playing* player's controller hides their own hero, unlocks the camera,
  follows other heroes (number keys → `SetTargetByID`), free camera, fog of war off; invulnerability only in debug
  builds. It is entered through level-blueprint events `EnterSpectatorMode`/`ExitSpectatorMode` (console/debug use).
  `BP_SpectatorPawn` is a cinematic camera (key frames, replay). The lobby has no spectator slots; the session browser
  API has `as_spectator`/`spectators` (our backend stores them, nothing uses them).
- **How we'd do it**: Two levels. (1) "Ghost seat": the spectator joins as an extra player; FangsHost keeps their hero
  hidden, invulnerable, out of team counts and never Captain, FangsBoot puts their client into `EnterSpectatorMode`.
  Many edge cases (team sizes, Captain choice, round end conditions, match report). (2) A real spectator (no hero,
  UE spectator pawn): new lobby/hero-select/arena logic. Either way also: 7+ players per server (CPU, RAM on the VPS).
- **Effort / risk**: L (days to weeks), high risk. Not recommended before the other items.
- **Confidence**: low-medium on (1) working at all.
- **Questions for a community member**: Who would spectate and why (tournaments/casting, friends watching, recording)? Must they see
  both teams with no fog? Is a small delay OK? How many spectators per game?

#### Make the round start timer infinite in the training mode
- **What it is**: Most likely the item-selection timer (the "dummy phase"), native `ItemSelectFirstRoundMaxTime` /
  `ItemSelectMaxTime` on the game state (replicated, so clients show the server's value). Feb sets no value in its
  Blueprint defaults (Dec sets 45 / 45), so the Feb value is the native constructor's (not read yet). There is also a
  separate native `CountdownTime` (0x290, not replicated) between lock-in and the round start.
  Note: if "training" means the TRAINING tile, its map BeautifulCorner has no dummy spawn points (its 20 dummies are
  placed in the map and stay); the spawned-then-despawned dummies only exist on the arena maps, i.e. in custom "Solo"
  lobbies. Which one players mean decides the fix.
- **How we'd do it** (FangsHost, server only): at arena BeginPlay, only when `gi.MapGameMode == 0` (Training) and/or the
  match has 1 player (Solo lobby), set both item-select times to a very large value (e.g. 99 min, so the HUD timer still
  reads sanely). Lock-in still ends the phase early (`AllPlayersSelectedItems`); see the next item for keeping it open.
- **Effort / risk**: S (1-2 h + a solo test). Low risk (only Training/Solo).
- **Confidence**: high for the timer; medium on what players call "round start timer".
- **Questions for a community member**: Do you practise with the TRAINING tile (floating island, "Basic Training") or with a Custom
  lobby in Solo mode on a normal map? Which timer: the one while you pick augments and the dummies are there, or the
  short countdown just before the round starts?

#### Allow changing augments after locking in (says press Tab, doesn't work; should be on P)
- **What it is**: The "[TAB]" text is stale: `FANGS_LOC_EN.gamemode_training_desc` and
  `FANGS_CLIENT_LOC_EN.STR_TRAINING_DESC` say "Press [TAB] to equip and unequip Augments", but Tab is the scoreboard (and
  chat command cycling) in Aug and Feb (`Config/DefaultInput.ini`). **P already exists**: action `ReOpenAugment` (P) →
  `BP_PC_MOBA_PlayerController` L4736 → `WB_PreRoundSelection.ShowAugmentSelectAgain` (`UI/Hud/WB_PreRoundSelection.txt`
  L25739): it reopens the picker and un-locks you (`ReportetFinishedItemSelectOnServer(true)`), but **only while the game
  is still in item selection** (`IsAtItemSelection`). Alone in Training/Solo, locking in ends that phase at once, so P
  never gets a chance; in team games it works until the last player locks in.
- **How we'd do it**:
  1. Text: patch pak `replace-text` on both keys, "[TAB]" → "[P]" (and say it works during the augment phase). S.
  2. Keep the phase open in Training/Solo: FangsHost post-hook on `BP_PlayerState_MOBA_Hero.ReportetFinishedItemSelectOnServer`
     resets `bSelectedItems` to false there, so locking in applies the build but doesn't end the dummy phase; with the
     infinite timer (above) you stay with the dummies, press P, change, lock in again. A way to start the real round
     when wanted is needed (a chat command, or "lock in twice"). M.
  3. Changing augments mid-round (outside item selection): the server accepts any equipment change
     (`UpdateEquipmentOnServer`, `docs/recon/items.md`), but item abilities are granted around round start and the HUD
     blocks P; FangsBoot would open the picker itself and FangsHost re-apply items. L, uncertain.
- **Effort / risk**: 1 S; 2 M (needs a test that augment effects are active during item selection: the Wylde item in the
  same patch notes suggests they are); 3 L.
- **Confidence**: high on why P "doesn't work"; medium on 2.
- **Questions for a community member**: In training, do you want to stay in the "dummy phase" (pick → test on dummies → P → change,
  no real rounds), or play normal rounds and swap augments in the middle of a round? Should this also work in custom
  Solo lobbies?

#### Add practise mode from a later patch (the blue flying island thingy) or just don't despawn dummies after locking in
- **What it is**: The floating sky island is very likely `LE_BeautifulCorner`, Feb's own TRAINING map (see key facts),
  already in the game and used by the TRAINING tile. Dec 2023 (our newest build) has no other practice map (same map
  list; Dec Training is also BeautifulCorner). If players mean something newer than Dec 2023, we don't have it.
  Dummy despawn: `Destroy Preround Dummies` at countdown start removes actors tagged `PreroundDummy`, the tag
  `Spawn Preround Dummies` gives them from `GS_MOBA_Battle.TaggingSpawnedDummies`.
- **How we'd do it**:
  - If the island is BeautifulCorner: nothing to port; make sure players know the TRAINING tile and that it works on our
    servers (one test run), and give it the fixes above (timer, P, quick server release).
  - Keep dummies (FangsHost, Training/Solo only): at arena BeginPlay give `TaggingSpawnedDummies` another tag, so the
    destroy step finds nothing; before each later round's spawn, remove the previous round's dummies (they would pile up),
    or spawn only once. S-M.
  - Porting a map from another build: same engine (4.26) and unversioned assets, but every referenced asset must exist in
    Feb with a compatible layout; only worth it for a map Feb lacks. L.
- **Effort / risk**: keep dummies S-M; island nothing/S.
- **Confidence**: medium-high that the island is BeautifulCorner (from its asset names, not a screenshot).
- **Questions for a community member**: (with two screenshots: the TRAINING tile's map, and `LE_TrainingGround`) Is one of these the
  "blue flying island"? If it's neither, which game version did you see it in, and roughly when?

#### Allow going into practise/training mode while in queue (maybe even while waiting in a custom lobby)
- **What it is**: The Play menu has one selected mode and one PLAY button (`WB_PlayMenu.PlayGameMode`, L24576); while
  queued (`MOBAMatchMakerSubsystem.MatchMakerJoinQueueId` / `bMatchQueued`) the menu keeps you in the queue flow. The
  match pop-up (accept) belongs to the main menu; in an arena nobody sees it, so the backend's accept timeout would drop
  the player (the matchmaker handles that cleanly: non-accepters go Idle, the others back in line; `docs/review/LIFECYCLE.md`).
  Capacity: Training takes a whole game server (2 on the VPS), so queue + Training doubles what a player holds.
  In a custom lobby you are connected to the lobby's server; a client can't be on two servers at once, and leaving loses
  the seat (the owner leaving ends the lobby).
- **How we'd do it**: Queue + Training is possible but L: FangsBoot lets the player start Training while queued, watches
  the matchmaker subsystem in the arena, shows "Match found" and accepts (or auto-accepts), and the game's own
  assignment then travels to the match server (leaving Training; with the fix above its server frees in seconds). Better
  after "Training on the player's own PC" (ROADMAP idea: local listen server, no server slot), which is L itself
  (FangsBoot must provide the hero info the server normally gets from the lobby). Lobby + training: not feasible.
- **Effort / risk**: L (days), medium-high risk; capacity cost on the VPS until Training runs locally.
- **Confidence**: medium.
- **Questions for a community member**: Is it OK if a queue pop pulls you straight out of training into the match (auto-accept), or do
  you want a prompt? Is practice-while-queued enough (practice while sitting in a custom lobby can't be done)?

---

### Summary

| Item | Mechanism | Effort | Confidence | Needs a community member? |
|---|---|---|---|---|
| Training servers not freed | backend (`hosts.py` short grace for 1-player sessions, reclaim, owner's new session) | S-M | high | small (what they see) |
| Change mode/map inside a custom lobby | FangsHost `setLobbyMap`/`setLobbySize` + backend session update + chat command (button = FangsBoot UI); maybe rematch instead | M (chat) / L (button, rematch) | medium | yes |
| Bo5/Bo7/Bo9 | FangsHost sets `MaxRounds` per lobby, picked by lobby-name tag or chat; (patch pak = all matches) | S-M | medium-high | yes |
| Randomize teams | FangsHost permutes `ChosenSlot` before hero select; backend can balance by rating | M | medium | yes |
| Spectator mode | dev spectating exists (hide own hero, follow cam); real spectator = new system | L | low-medium | yes |
| Training: infinite round start timer | FangsHost sets `ItemSelect(FirstRound)MaxTime` in Training/Solo | S | high (timer) / medium (meaning) | yes (which mode, which timer) |
| Training: change augments after lock-in (P) | text fix in patch pak; P exists but only in item select → FangsHost keeps the phase open (`bSelectedItems`) | S + M (mid-round: L) | high (cause) / medium (fix) | yes |
| Practice island / keep dummies | island is most likely Feb's own Training map (BeautifulCorner); keep dummies via `TaggingSpawnedDummies` in FangsHost | S-M | medium-high | yes (screenshots) |
| Training while queued / in lobby | FangsBoot in-match accept + travel; local Training first; lobby case not feasible | L | medium | yes |


## Stream 3: optimization and netcode (Feb 2023 build unless noted)

Static research only (16 Oct 2026): map dumps `work/shard/maps-{aug,feb,dec}/*.json`, Blueprint pseudocode
(`work/bp-2023-02-15`, Aug `work/shard/bp-aug`, Dec `work/bp`), class defaults (`work/cc-audit/props.py`), the game's
config files (Feb/Aug `work/extract-*/MOBA/Config/`, Dec extracted from its pak into `work/community-patchnotes/perf/dec-config`). Nothing was run.
Scripts and raw outputs: `work/community-patchnotes/perf/`
(`mapstats.py`, `cmp.py`, `analyze.py`, `outliers.py`, `geom.py`, `comps.py`; `cmp-feb.txt`, `analyze-feb.txt`,
`beneath.txt`, `payload03-meshdiff.txt`).

### The big finding first: the Feb build's network settings, and what the developers changed by Dec

Four of the five complaints in this stream involve rubber-banding. The game's own config explains a lot of it, and the
Dec 2023 playtest (the developers' later build) changed exactly these settings:

| Setting (file) | Aug 2022 | **Feb 2023 (ours)** | Dec 2023 | What it does |
|---|---|---|---|---|
| `MAXPOSITIONERRORSQUARED` (DefaultGame.ini, `GameNetworkManager`) | 8.5 | **0.5** | 0.5 | How far (squared, in uu²) a client's own position may differ from the server's before the server corrects it. 0.5 = 0.7 uu; UE's default is 3.0. The server snaps players back for tiny differences |
| `ClientNetSendMoveDeltaTime` (same) | 0.0166 (60/s) | **0.05 (20/s)** | 0.05 | How often a client sends its moves |
| `NetServerMaxTickRate` / `MaxNetTickRate` (DefaultEngine.ini, `IpNetDriver`) | 30 / 30 | **30 / 30** | 60 / 60 | Net tick caps |
| `bClampListenServerTickRate` (same) | true | **true** | false | Our game servers are listen servers (FangsHost), so the clamp applies to them |
| `MaxClientRate` / `MaxInternetClientRate` (same) | 40000 | **40000** | 800000 | Bytes/s the server may send each client |
| `ConfiguredInternetSpeed` (`Engine.Player`, client side) | 40000 | **40000** | 800000 | The rate the client asks for |
| `net.MaxRPCPerNetUpdate` | 10 | 15 | 32 | Unreliable multicasts per actor per net update; extras are dropped |
| `r.AllowOcclusionQueries` (client rendering) | False | **False** | True | Occlusion culling: off means everything in view is drawn, hidden or not |

- `docs/recon/server-performance.md` finding 6 (replication at ~20-25 Hz "whatever `NetServerMaxTickRate` says",
  gaps alternating 33/50 ms at 60 fps) fits a 30 Hz net tick cap on a 60 fps server: `test_perf.sh` logged
  `clamp=true` in every run and never read `MaxNetTickRate`, which is 30 in the game's config. Changing
  `NetServerMaxTickRate` alone (30/32/62 were tried) can't lift a clamp to `MaxNetTickRate`. The Dec build sets all three
  together (60, 60, false). Not verified in the exe (the clamp function wasn't found by byte pattern); verify by test.
- These are config values: they can be set without touching game files. Servers: the `Engine.ini`/`Game.ini` that
  `server/run-host.sh` writes into each instance (`tools/run/config/Engine.ini.template` today has only the rate
  caps). Players: the same template is shipped as `FangsCE/Engine.ini` (`server/deploy.sh`) and installed by the
  launcher, so client-side values (`ConfiguredInternetSpeed`, `[SystemSettings] r.AllowOcclusionQueries=1`) reach
  players with a deploy and a launcher start. A `Game.ini` for players (`ClientNetSendMoveDeltaTime`) would need the
  same treatment (new file in the overlay + launcher).
- Caution from the template's own comment: a server rate cap of 100000 once made a player drop in hero select in about
  half of two-player lobbies. Re-test any rate change with `tools/run/test_lobby.sh` several times.

### Items

#### Crownwatch map is very laggy, has more rubberbanding & fps drops than the other maps
- **What it is**: Crownwatch = `LE_Payload03_Map` (`backend/seed/make_seed.py`). Gameplay-wise it's the same as
  Embersong (`LE_Arena02_Map`) and Stormheart (`LE_Arena06_Map`): same actors (2 turrets, 1 Prismatic Shard, 4 health
  pickups that FangsHost swaps for Health Shrines, 3 berserker pickups, 8-10 bushes, one Aspect), the same flat floor
  collision (one floor mesh; the landscape is visual only, `NoCollision`), almost all scenery meshes `NoCollision`.
  The server side shows no problem: the one VPS 4v4 on Crownwatch ran at 58-60 fps like the others
  (`server-performance.md`, 15 Oct). The difference is what the client has to draw:

  | Feb build | Embersong | Stormheart | **Crownwatch** |
  |---|---|---|---|
  | Static mesh actors (each its own draw) | 2110 | 1734 | **2575** |
  | ... in the play area / around it / directly under it | 1675 / 196 / 160 | 1205 / 441 / 19 | **1798 / 553 / 224** |
  | Most-used mesh | Lily1 (11 kB) ×189 | snow pile (15 kB) ×161 | **canopy tree `ST_queen_canopy_1_V1` (589 kB) ×700** |
  | Mesh data × instances (rough geometry load) | 631 MB | 369 MB | **1077 MB** |
  | Sun (directional light) | stationary, CSM 12.4k uu, distance-field shadows | movable, CSM 12k uu | stationary, CSM **17.7k uu**, distance-field shadows to **100k uu**, plus a **light function** material (an extra full-screen pass) |
  | Same map in Aug 2022 | 950 meshes | 380 | **359 meshes, one sun without shadows** |
  | Same map in Dec 2023 | 2048 | 1743 | 2385 (the developers trimmed ivy and ornate tiles) |

  With occlusion culling off (`r.AllowOcclusionQueries=False`), all of it within the camera's view is processed every
  frame, including the forest under the floating arena. So: Crownwatch is the heaviest map for players' PCs, by a
  wide margin, and was completely re-arted between Aug 2022 (359 meshes) and Feb 2023 (2629 incl. non-actor meshes).
  Rubber-banding on that map most likely follows from the players' frame drops (a client that hitches sends late,
  big moves; with the 0.7 uu correction tolerance above, the server corrects it) plus the general netcode settings,
  not from the server.
- **How we'd do it** (cheapest first):
  1. Measure (plan below): client fps per map, same spot, same settings.
  2. Turn occlusion culling on for players, as the developers did in Dec: `[SystemSettings] r.AllowOcclusionQueries=1`
     in the shipped `FangsCE/Engine.ini` (or `ExecuteConsoleCommand` from FangsBoot). It's a render-thread cvar, not
     read-only, so it can be A/B tested at runtime first. Culls the forest under the floor and anything hidden.
  3. Crownwatch only, from FangsBoot when the map loads (client rendering, no gameplay effect): drop the sun's light
     function and shorten its dynamic shadow distance (`DirectionalLightComponent` properties; one lookup at map load,
     not in a loop), and/or give the background meshes far below the arena a cull distance (`SetCullDistance`) or hide
     the ones that can't be seen from the game camera (needs a visual check with screenshots).
  4. If a permanent map edit is wanted: the patch pak can't edit map actors today (`set-default` only handles class
     defaults). A new AssetPatch op that sets a property on a named export of a `.umap` (UAssetAPI can) would allow
     e.g. `LightFunctionMaterial = None` or `bHiddenInGame` on chosen meshes. Don't change mobility (breaks baked
     lighting).
  5. Larger: Aug 2022's Crownwatch is a much lighter map (359 meshes); bringing it into the Feb build would need its
     assets in the patch pak and a layout check (FangsHost already places Health Shrines at Aug spots there).
- **Effort / risk**: measuring S; occlusion cvar S (player update via deploy; risk: possible pop-in at screen edges);
  FangsBoot per-map tweaks M (player update); new AssetPatch op M-L; Aug map port L.
- **Confidence**: medium. The static numbers are solid; that they are what players feel needs the per-map fps test.
- **Questions for a community member**:
  - On Crownwatch, is it your own game that gets choppy (low fps, stutters), or do other players jump around while
    your game runs smoothly? Or both?
  - Is it bad from the very start of the match, or only in big team fights?
  - What graphics settings and roughly what PC/graphics card do you play on? Do friends with stronger PCs see it too?
  - Was Crownwatch this laggy in earlier playtests too, or only since this version?

#### check if other maps are still being loaded in below the current map (this used to be the case and cause for a lot of fps drops)
- **What it is**: not in this build. None of the Feb maps (the three arenas, Payload II, Training, Tutorial, Underworld,
  lobby, main menu) has a streaming sublevel, and no Blueprint loads or streams levels (no `LoadStreamLevel`,
  `LevelStreaming*` or `LoadLevelInstance` anywhere). What *is* under every arena is the map's own background scenery
  (forest, towers, mountains around and below the floating arena): 160 meshes directly under Embersong, 19 under
  Stormheart, 224 under Crownwatch (plus 200-550 around each). With occlusion culling off they are drawn whether or
  not anyone can see them, which is probably what people remember as "another map under the map".
  Match travel: lobby → arena is a seamless travel (`BP_GM_Lobby_GameMode.bUseSeamlessTravel = True`,
  `TransitionMap=None`). The old world should be garbage-collected after travel; a leaked lobby or menu world would
  cost memory, not drawing.
- **How we'd do it**: one runtime check in a test match (client side, once, after the arena loaded; never in a loop
  on a server): FangsCtl
  `lua local t={} for _,w in ipairs(FindAllOf("World") or {}) do t[#t+1]=w:GetFullName() end for _,l in ipairs(FindAllOf("Level") or {}) do t[#t+1]=l:GetFullName() end return table.concat(t," | ")`
  Expect only the arena's world and level (and possibly the transition world for a moment). If the lobby or main
  menu world shows up minutes into the match, it leaked. The fps side is the occlusion setting above.
- **Effort / risk**: S (one test run); the fix is the Crownwatch item's.
- **Confidence**: high for "no sublevels in the files"; the runtime leak check is open.
- **Questions for a community member**: Where did you see this before: which map, and in which version of the game? Could you see
  another map through the floor, or was it only the fps drop people blamed on it?

#### when somnia ult is affecting many players, people start to rubberband/teleport everywhere (check netcode on this)
(Listed under Astrada in the document; it's Somnia's ult, Tethers of Eternity, `BookMage/R/BP_GA_BookMage_RNEw`.)
- **What it is**: the ult ticks every **0.1 s** (`Tick Frequency`, Aug and Feb; Dec changed it to 0.25) for 3 s
  (`Max Duration`). Every tick, every tethered enemy gets a **new** slow effect (`BP_GE_GenericSlowdown`, duration =
  one tick, `MoveSpeed` × (1 − 30 %)) plus a damage effect and a hit gameplay cue (`Play Hit VFX` →
  `ExecuteGameplayCueOnCharacterWithParams`). The slow effect has no stacking rule, so each tick an old slow expires
  and a new one is applied: on the server the target's speed flips every 100 ms (for a frame it's either unslowed, or
  slowed twice: GAS adds multipliers, 1 − 0.3 − 0.3 = 0.4). The target's own client only learns of each change a
  round trip (plus the 20-25 Hz replication gap) later, so its predicted movement disagrees with the server's, and with
  the 0.7 uu correction tolerance the server corrects it again and again: the tethered players rubber-band. On top,
  6 targets × (slow added + slow removed + damage + cue) × 10/s is a lot of replication; with the 40 kB/s per-client
  cap a client can saturate, and then *everyone* on its screen updates late and teleports.
  Per-tick damage is `TotalDamage / (Max Duration / Tick Frequency)`, so the total doesn't depend on the tick rate.
  The only other per-tick value is the heirloom AllyTether's heal (`ATTickHeal` 3.33 per tick per ally).
- **How we'd do it**:
  1. Patch pak (`set-default` on `BP_GA_BookMage_RNEw`): `Tick Frequency` 0.1 → 0.25 (Dec's value): 2.5× fewer slow
     flips and updates, same damage and slow. Keep AllyTether's total with `ATTickHeal` 3.333 → 8.333 (Dec kept 3.33,
     a nerf). Damage numbers then pop 4×/s instead of 10×/s. No code change, same file for players and servers.
  2. Netcode settings above (correction tolerance, rate cap, net tick): help this and everything else.
  3. A slow that doesn't flip (one slow for the whole tether, removed when the tether breaks) needs new Blueprint
     logic: the patch tool can't add code, and giving the shared slow effect a stacking rule would change every
     other slow in the game. Not recommended.
- **Measure**: `test_perf.sh` with `HERO=BookMage`, 5-11 bots around, the ult cast into them (FangsCtl), with and
  without the patch: per-client packet gaps and kB/s (already recorded by `perf_sample.py`), plus a snap counter on the
  clients (below). Add latency in the test's own network namespace (`tc ... netem`, below).
- **Effort / risk**: S (two values in a patch, and a test). Risk low: Dec shipped the same tick rate.
- **Confidence**: medium-high for the mechanism (read from the code); that it is the main cause needs the A/B test.
- **Questions for a community member**:
  - When the ult hits many people: is it the players who are tethered that rubber-band, or everyone on the screen,
    even players the ult didn't hit?
  - Does it start with 2-3 players hit, or only with 5 or more?
  - Fix idea: the ult would hit 4 times per second instead of 10, with the same total damage, slow and duration
    (the developers did this in a later version). The only visible difference: fewer, bigger damage numbers. OK?

#### TUFTS: check for space netcode something idk it is insanely laggy in some games i legit was flying through the walls on my screen with it
- **What it is**: Space = Wing Dive (`SideKick/Skill1/BP_GA_Sidekick_Skill1`), a charged dash at up to 2000 uu/s
  (`MaxSpeed`), range 1250. In the Feb build the dash that actually runs is a local root-motion dash
  (`AbilityTask_ApplyRootMotionJumpForce`, height 0); the server-initiated variant in the same Blueprint sits behind a
  constant `if (!true)` and is dead code (pseudocode lines 165/200/546). What can make it lag:
  - **The client waits for the server before it dashes**: two `WaitNetSync(OnlyClientWait)` points (type 2) in the
    charge flow. The server goes first; the player's own client follows a round trip (plus a replication gap of up to
    50 ms) later, so client and server run the same dash at different times and the server corrects the client. On a
    high-ping or jittery connection that is large: "laggy in some games".
  - **Momentum after the dash**: Feb changed this dash's `VelocityOnFinishMode` from 1 (Aug: stop at the end) to 0
    (keep the last root-motion velocity, up to 2000 uu/s, then brake). Small timing differences at the end become big
    position differences → corrections (the change listed in `docs/recon/cc-changes.md`; Dec kept 0).
  - **Corrections teleport the client**: a correction (`ClientAdjustRootMotionSourcePosition` etc.) sets the client's
    position to the server's directly, so on the player's screen Tufts can jump across a wall or appear to fly
    through it. During the dash Tufts also passes through players (Pawn channel set to ignore/overlap), not walls.
  - Plus the general settings: 0.7 uu correction tolerance, 20 moves/s from the client, 20-25 Hz server updates.
  The bump on hitting an enemy (`ApplyRootMotionJumpForce`, height 200 → 250, 0.2 → 0.3 s in Feb) is a jump; a jump
  arc that client and server disagree on can also look like flying over a low wall.
- **How we'd do it**:
  1. Patch pak, `set-call-arg` in `ExecuteUbergraph_BP_GA_Sidekick_Skill1` on the dash's `ApplyRootMotionJumpForce`:
     `VelocityOnFinishMode` 0 → 1 (Aug: stop dead). Same size in bytecode (a byte constant), so the tool can do it;
     `AssetPatch calls` first to see how the argument prints and to `match` only the dash call (the bump call has 2).
     This changes the feel (no slide at the end) and could be applied to the other ~25 dashes of the same change.
  2. Experiment: the two sync points `MakeLiteralByte(2)` → `1` (OnlyServerWait: the client dashes at once, the server
     catches up, the usual predicted pattern). Riskier: must be tested with latency for double dashes or cancels.
  3. The netcode settings above.
- **Measure**: two-player test (`tools/run/test_join.sh`/`test_patch.sh`-style) with Tufts dashing into and along
  walls and through an enemy, with latency added (40-120 ms, jitter, 1 % loss), counting the client's snaps;
  with and without each patch.
- **Effort / risk**: patch 1 S (feel change); patch 2 M (needs careful testing); settings S-M.
- **Confidence**: medium. The code paths are read, not run; which of the causes dominates needs the latency test.
- **Questions for a community member**:
  - Is it Wing Dive (Space) only, or other abilities too? Short tap or full charge?
  - Does it happen on your own screen when you play Tufts, or when you watch an enemy Tufts? Every map?
  - In those games, was your ping high (above ~80) or were you on Wi-Fi? Was it laggy only for you or for others too?
  - In this version Tufts keeps sliding a little after the dash ends; in the older version (Aug 2022) the dash stopped
    dead. Would stopping dead feel OK, or is the slide part of how Tufts should feel?

### Measured (17 Oct): see `docs/recon/server-performance.md`, "Rubber-banding"

- With a 6v6 fight at 50 ms latency, **net tick 60 without the listen-server clamp halved the small position
  corrections and other heroes' visible jumps**. It is switched on (`server/netcode.env`).
- The correction tolerance (3.0) added nothing on top; Aug's 8.5 made large snaps worse; higher rate caps changed
  nothing.
- **Tufts' Wing Dive with `OnlyServerWait`** (`tools/patch/patches/tufts-sync.json`) more than halved his snaps
  while dashing. On for the next deploy (user, 17 Oct: "on"); `tools/run/test_tufts.sh` found the dash itself
  unchanged (start, distance, a single burst, the hit).

### Measurement plan (to run later, never while people play; tests stay in their own network namespace and data)

1. **Client fps per map** (Crownwatch, "maps below"): a per-second frame logger for clients (the `perf_frames.lua`
   idea: fps and longest frame per second, the map name), as a test Lua for headless GPU clients (`GPU=1`, gamescope +
   DXVK) and optionally in FangsBoot so players can send their `fangsboot.log`. Same spawn point and camera on each
   map; then A/B `r.AllowOcclusionQueries 1`, sun light function off, shadow distance. Headless absolute fps differ from
   players' PCs; the ratios between maps and settings are what count.
2. **Rubber-band counter** (all netcode items): a client-side snap detector in the test Lua: each frame, own hero
   position jump minus velocity × dt; count jumps > 30-50 uu per minute. Optional: with `p.NetUsePackedMovementRPCs 0`
   on both ends in a test, corrections arrive as separate RPCs (`Character:ClientAdjustPosition`,
   `ClientVeryShortAdjustPosition`, `ClientAdjustRootMotionSourcePosition`) that UE4SS can hook and count.
3. **Latency like real players**: `tc qdisc add dev lo root netem delay 60ms 15ms loss 1%` inside the test's own
   network namespace (`tools/run/headless.sh` creates it; `unshare -rn` gives us root there). Never on the host.
4. **Server side**: `tools/run/test_perf.sh` as today (fps, longest frame, CPU, per-client packet gaps and kB/s from
   `perf_sample.py`), extended with `MAP=` (it is Embersong-only now) and a cast schedule for `HERO=BookMage` /
   Sidekick.
5. **A/B matrix** (each against the same baseline):
   a. baseline;
   b. server `Engine.ini` `[/Script/OnlineSubsystemUtils.IpNetDriver]` `NetServerMaxTickRate=60`, `MaxNetTickRate=60`,
      `bClampListenServerTickRate=false` (Dec): expect packets every ~17 ms instead of 33/50; watch server CPU
      (two matches must still fit the VPS) and kB/s per client (may hit the 40000 cap → c);
   c. b + `MaxClientRate`/`MaxInternetClientRate` and the client's `ConfiguredInternetSpeed` raised together (e.g.
      100000), with `test_lobby.sh` repeated 4-8× for the hero-select drop seen before;
   d. server `Game.ini` `[/Script/Engine.GameNetworkManager]` `MAXPOSITIONERRORSQUARED=3.0` (UE default) or 8.5 (Aug);
   e. patch pak: Somnia `Tick Frequency` 0.25;
   f. patch pak: Wing Dive `VelocityOnFinishMode` 1.
   Record per run: server fps/longest frame/CPU, client fps, snaps per minute, packet gaps, kB/s.
6. **On the VPS** (no tests there, just better logs): add each player's ping and packet loss (from
   `GameState.PlayerArray`, no object scans) and the map to the backend's 30 s `perf` lines, so a "laggy game" can be
   matched to a player's connection or a map afterwards.

### Summary

| Item | Mechanism | Effort | Confidence | Needs a community member? |
|---|---|---|---|---|
| Crownwatch lag | measure; occlusion cvar for players (Dec had it on); FangsBoot per-map light/cull tweaks; later a map-edit op in AssetPatch | S (cvar) to M-L | medium | yes: fps vs teleporting, PC/settings, since when |
| Maps loaded below | none needed in Feb (no sublevels); one runtime leak check; fps part = occlusion | S | high (files), runtime check open | yes: where/which version |
| Somnia ult rubber-band | patch pak `Tick Frequency` 0.1 → 0.25 + `ATTickHeal` 3.33 → 8.33; netcode settings | S | medium-high | yes: who rubber-bands, OK with 4 ticks/s |
| Tufts Wing Dive lag | patch pak `VelocityOnFinishMode` 0 → 1; maybe sync type 2 → 1; netcode settings | S / M | medium | yes: tap/charge, own screen or enemy, ping, slide OK? |
| General netcode (all of the above) | config: Dec's net tick 60 / no clamp, higher rate caps, correction tolerance 3.0; server ini first, client ini via the shipped `FangsCE/Engine.ini` | S-M + tests | medium (Dec config supports it; exe not checked) | one: "was rubber-banding better in older playtests?" |


## Community patch notes, stream 4: hero bugs and visuals (Feb 2023 build)

Static research only (decompiled Blueprints `work/bp-2023-02-15`, Aug `work/shard/bp-aug`, Dec `work/bp`, class
defaults `work/cc-audit/cdo_*.json`, data assets dumped with `work/bin/bpdump/BpDump --raw`). Nothing was run in a
match; every "cause" below is a reading of the code and needs a match test. Paths are under
`MOBA/Content/Gameplay/Abilities/Player/` unless they start with another folder.

Two facts used throughout:
- **VFX packs.** Since Feb, most ability effects are not hard-wired: the cue asks the caster's VFX pack
  (`DataContent/Cosmetics/VFXPacks/<Hero>/DA_VFXPack_*`, one per skin family) for a tag like `VFXPack.Skill2.VFX`.
  Every slot in a pack has `DefaultVFX`, `CasterVFX`, `AllyVFX`, `EnemyVFX` (each a Niagara system plus
  `ColorOptions.Color`). `BP_FL_MOBA_AbilitySystemFunctionLibrary.Get Team Filtered Niagara From Team Structure` picks
  Caster/Ally/Enemy on each client (empty slot → Default), and `Generic Spawn System …` sets the Niagara user
  parameter `Color` when the pack's colour is not the default. So team colours are mostly **data in the VFX pack**.
- **New patch ops needed.** Several fixes below change a property that is not in a `Default__` object (a component
  template, a data asset field) or a gameplay-tag/name literal inside bytecode. Today's `AssetPatch` can't do either
  (`docs/PATCHING.md`). Both are size-neutral and look small to add: `set-export-prop` (any export, nested struct
  path) and `set-name-const` (swap the FName of a literal in one call argument). Marked "needs new op" below.

---

#### ASTRADA: colour ally Astrada cage differently from enemy Astrada cage
- **What it is**: Flame Cage (Shift) = actor `BluePrints/Abilities/Player/FireMage/E/BP_FireMage_Cage_RP`.
  `SetCageColor()` spawns the cage Niagara from the VFX pack tag `VFXPack.Skill2.VFX`. In
  `DA_VFXPack_AstradaDefault` that slot is **already team-split**: `DefaultVFX` = `NS_Astrada_Shift_System_Ally`,
  `EnemyVFX` = `NS_Astrada_Shift_System_Enemy`, Caster/Ally empty (→ Default). Both systems exist and differ, and both
  expose user parameters `User.Color` and `User.CircleColor`. All `ColorOptions.Color` in the pack are unset, so no
  tint is applied. The cage actor also has replicated `AllyColor` (0, 1.43, 15 = blue), `CasterColor` (blue),
  `EnemyColor` (15, 0.7, 0 = orange) defaults that no current code uses (leftover from the Cascade cage).
  So either the two systems look alike in play, or the team pick fails on our clients (it relies on each client
  knowing who is an ally).
- **How we'd do it**: cheapest = data: set `Skill2VFX[0].DefaultVFX.ColorOptions.Color` (and `CasterVFX`, pointing it
  at the Ally system) in `DA_VFXPack_AstradaDefault` to a blue (e.g. the actor's unused `AllyColor`), leave Enemy
  as is (or set it red). `Generic Spawn System Attached` already applies it (`UseVFXPackColor` = true in that call).
  Needs new op `set-export-prop` (data asset, nested struct). Fallback if `User.Color` doesn't tint the cage:
  FangsBoot post-hook on `BP_FireMage_Cage_RP_C:SetCageColor` → `CageVFX:SetColorParameter("CircleColor", …)` for
  ally/caster (client only, player update).
- **Effort / risk**: S–M (the op once, then a value); low risk (client visuals only). Other skins: only the default
  Astrada pack exists in the Feb pak.
- **Confidence**: medium. Must check in a 2-client match: does an enemy's cage already look different, and does
  `User.Color`/`User.CircleColor` change the visible colour.
- **Answer (17 Oct, matches)**: the team pick works, and neither parameter changes the colour: no emitter of either
  system reads them. The colours are curves baked into each emitter, and the fix recolours those
  (`docs/recon/community-build-heroes.md`).
- **Questions for a community member**:
  1. Right now, does the cage of an Astrada on *your* team look exactly like the enemy Astrada's cage? (Yes / a bit different / no idea)
  2. Which colours? (a) ally blue, enemy red-orange as now (b) ally yellow-orange, enemy red (c) something else.
  3. Should the Astrada player see her own cage in the ally colour too? (yes / no)

#### ASTRADA (listed there): when Somnia ult is affecting many players, people rubberband/teleport
- Netcode — stream 3 (performance) owns it. Not investigated here.

#### ISHIR: Gun Sound on ishir Ult
- **What it is**: Sever Spirit (R) = `BackStab/Skill3/BP_GA_Backstab_Skill3`. Sounds in Feb:
  - cast SFX cue `BackStab/Skill3/SFX/BP_GC_BackStab_Skill3_CastSFX` plays **nothing** (`SpawnSoundAttached(nullptr…)`;
    Aug played `WoodenSword_LMB_Cast_WhooshHeavy`, Dec also nothing);
  - FMOD events: `Backstab_Skill3_Hit` (mark debuff), `Backstab_Skill3_Lifetime` / `_Lifetime_END` (the mark on the
    enemy, `BP_GC_UltimateMark`) — same in Aug;
  - **new in Feb**: `Backstab_Skill3_Shadow` (the shadow left at the start point, `BP_GC_BackStab_Skill3_GroundIndicator_VFX`)
    and `Backstab_Skill3_ReturnToShadow` (teleport back, `BP_GC_Backstab_Skill3_TeleportReturnFX`).
  - An old cue `Characters/BackStab/BP_GC_BackStab_R_Cast` (tag `GameplayCue.Backstab.R.Cast`) plays a meme voice
    line `omaemoshinderu`; nothing in Feb executes that exact tag (the ult executes `…R.Cast.VFX`, whose notify
    overrides its parent), so it should be silent.
  The sound itself lives in the FMOD banks (`MOBA/Content/FMOD/…`), not in UE assets, so "which one sounds like a gun"
  can't be read from code. Most likely one of the two Feb-new events.
- **How we'd do it**: if unwanted: point that cue's event at a quieter/other existing event with `rename-import`
  (e.g. `ReturnToShadowEvent` in `BP_GC_Backstab_Skill3_TeleportReturnFX`, a class default) — or a FangsBoot hook that
  skips the cue. If *wanted* (a request to add a gun sound): pick an existing FMOD event (e.g. one of Wylde's) and
  rename-import it into the cue; new sounds can't be added without building an FMOD bank.
- **Effort / risk**: S once we know which sound; low. Listening to the bank events (FMOD bank extractor, local) would
  pin it without a match.
- **Confidence**: low (ambiguous request, audio not inspectable statically).
- **Questions for a community member**:
  1. Is the gun sound a *bug* (it shouldn't be there) or a *wish* (you want a gun sound on the ult)?
  2. When exactly do you hear it: (a) when Ishir teleports behind the enemy (b) when the mark/seal on the enemy pops
     (c) when Ishir jumps back to his shadow (d) the whole time the mark is up?
  3. Does it happen with every skin?

#### ROWAN: Sometimes his passive stops healing for the rest of the game (gamebreaking)
- **What it is**: passive Strength of the Wilds ("on Overgrowth: +10 % speed, +10 % damage, heals 2 % of missing HP per
  second"). Chain: Overgrowth sources (Sourblossom plants `WoodenSword/Skill4/Actors/BP_TA_WoodenSword_Skill4`, Earth Rend
  arc `RMB/Actors/BP_TA_WoodenSword_RMB`, ult overgrowth, the passive's plants) apply `BP_GE_WoodenSword_Skill4_Creep`
  (infinite, removed on death / pre-round / leaving) which grants `Passive/BP_GA_WoodenSword_CreepTimer`; that ability
  applies the damage, speed and heal effects.
  **Finding (strong): in the Feb build the passive's heal is effectively zero, always.**
  - `BP_GA_WoodenSword_P.MakeCreepEffect` computes `(1 − HP/MaxHP) × 2/100` *once, when Rowan steps on the Overgrowth*,
    and passes it as SetByCaller `Data.Heal.MissingMultiple`.
  - `CreepTimer.Activate Regenerate Item` puts that number ÷ 4 into **`Data.Heal`** of a 0.25 s heal-over-time
    (`BP_GE_DotHealFourPerSec`, 3600 s). `Data.Heal` is a flat HP amount (Belroth's regen passes `MaxHealth × x` the same
    way); `Data.Heal.MissingMultiple` is the native "fraction of current missing HP" (Astrada's Regal Salve uses it).
    So Rowan heals ≈ 0.003 HP per tick, i.e. nothing.
  - Aug passed both `Data.Heal` (3 HP/s flat) and `Data.Heal.MissingMultiple` (2 %/s of *current* missing HP). Dec
    rewrote it as a timer `HealTick` that recomputes `(MaxHP − HP) × rate ÷ 4` every tick. So the developers broke it in
    Feb and fixed it by Dec.
  - What players probably see healing: Earth Rend's own arc heal (`BP_GE_WoodenSword_HealingOverTime`, "heals Rowan for
    X HP per second" while on the arc). That one can drop out: leaving one arc removes *all* arc heals by tag
    (`Remove Periodic Effects`), also those of another arc he still stands in, until he re-enters.
  - Other stuck-state risks in the same chain (temporary, not "rest of the game"): each source only re-applies the
    buff if Rowan doesn't already have `Effect.WoodenSword.Passive.Buff`, and sources don't know about each other
    (Sourblossoms check other Sourblossoms, the arc checks plants and ult overgrowth, the passive's plants check
    nothing), so leaving one source can strip the buff while standing in another until he re-enters. The plant's
    `ReceiveDestroyed` does `Array_AddUnique(ActiveCreeps, self)` instead of removing itself (Dec added an `IsValid`
    check around it instead). `Heal Caster` (Heal Sprite's 10 HP heal) is never called in Feb.
- **How we'd do it**: Port Dec's behaviour. Best route: **FangsHost Lua (server only, heals are server-side)**: post-hook
  `BP_GA_WoodenSword_CreepTimer_C:K2_ActivateAbility`/`K2_OnEndAbility` to track Rowans on Overgrowth (no object scans),
  and every 0.25 s apply a heal of `(MaxHP − HP) × 0.02 × ItemRegenMultiplier-if-Heal-Sprite ÷ 4` (via the game's
  `BP_FL_MOBA_AbilitySystemFunctionLibrary.MakeHealEffectSpec` like Dec, or `MissingMultiple` on the existing GE).
  Pure-pak alternative (needs new op `set-name-const`): rename the SetByCaller tag in `Activate Regenerate Item` from
  `Data.Heal` to `Data.Heal.MissingMultiple` — the native then recomputes from current HP every tick — and make
  `GetMissingHpValue` return the plain rate (0.02) instead of rate × missing fraction (an arg swap, not size-neutral
  today; needs thought). Also optional: fix the arc's "leave one, lose all" with a FangsHost re-apply.
- **Effort / risk**: M (Lua + a 2-player test measuring HP over time on Overgrowth); low-medium risk (heals only).
- **Confidence**: high that the Feb passive heal ≈ 0 (code + Aug/Dec comparison); medium on what players experience
  as "stops healing". A match test must show HP over time on a Sourblossom ring vs on an Earth Rend arc.
- **Questions for a community member**:
  1. When the passive *does* heal, where is Rowan standing: on the green ring around a Sourblossom (E), on the arc from
     Earth Rend (right click), or on the ult's overgrowth?
  2. How do you notice it stopped: green numbers stop, health bar stops, the green glow is gone?
  3. Does it come back after Rowan dies, or after the next round starts?
  4. Which heirlooms were equipped (e.g. Heal Sprite, Propagator, Vitalshroom)?
  5. In the old game (Aug 2022) the passive healed 2 % of missing HP per second *plus* 3 HP per second. Should we bring
     back exactly that, or only the 2 % the tooltip says?

#### ROWAN: Propagator causes the bar that represents remaining cooldown to gain another charge to bug out (stays orange and then jumps at the end)
- **What it is**: Propagator (`Items.WoodenSword.P.GainPlants`) = "on Overgrowth, Sourblossom charges twice as fast".
  `CreepTimer.Setup Sourblossom Charge Aug` runs `Reduce CD` every 0.25 s **on the server only** (the ability is
  ServerOnly): it shortens the remaining duration of the charge cooldown effect (`BP_GE_WoodenSword_Skill4_Cooldown`,
  tag `Effect.WoodenSword.Skill4.Cooldown`, 3 stacks, "remove one stack and refresh") with the native
  `SetGameplayEffectDurationHandle`. The HUD bar (`UI/Hud/WB_AbilityIcon.UpdateStacksProgress`, ChargeType Cooldown from
  `BP_WoodenSword_Char.UIStackInfo`) is drawn on the client as `1 − remaining/total` from the client's copy of that
  effect. Most likely the client never learns the shortened duration, so the bar fills at normal speed and jumps when
  the server's charge arrives early. Dec has the same code.
- **How we'd do it**: first read `SetGameplayEffectDurationHandle` in the exe (`tools/re/decomp.sh`) to see whether it
  marks the effect dirty / moves the start time. If not: FangsHost, after each `Reduce CD`, nudge replication of that
  effect (e.g. `UpdateActiveGameplayEffectSetByCallerMagnitude` on it, which marks it dirty) — or FangsBoot computes the
  bar from the server's remaining time. Alternative design: make Propagator a cooldown-rate effect instead of cutting
  durations (bigger change).
- **Effort / risk**: M (RE + a 2-player test); low risk (the bar is cosmetic; the charges are right on the server).
- **Confidence**: medium.
- **Questions for a community member**: 1. Do the charges themselves come at the right (faster) time, and only the bar is wrong?
  2. Does it also happen without Propagator? (no / yes)

#### ROWAN: Dourling caltrops is spawning a cube hitbox thingy & puts another space visual in front of rowan; also seems to not actually root(?); remove the extra space decal & cube and add a visual for the "trail of vines"
- **What it is**: Dourling Caltrops is a **Space (Dourling Dive) heirloom** (`Item_WoodenSword_Skill1_DourlingCaltrops`,
  slot Skill1) although its tooltip header says "Wall of Roots [SHIFT]". Code: `Skill1/BP_GA_WoodenSword_Skill1.Apply
  Dourling Caltrops`, run from `CheckForItemsPostCast` **after the dash ends**:
  - spawns `Skill1/Items/BP_TA_Woodensword_DourlingCaltrops` (a `BoxComponent`, lifespan `DC_Lifetime` 3 s, extent
    dash length/2 × width/2 × 150) at `SetForwardLocation()` = **Rowan's end position + forward × 375**, i.e. a
    750-long box *in front of* Rowan, not on the path he dashed;
  - the box's component template has **`bHiddenInGame = False`** → the visible wireframe "cube";
  - enemies entering the box get `BP_GE_Root` for `DC_RootDuration` 0.75 s (only on begin-overlap; the enemies he dashed
    through are behind him, so it rarely roots anyone — "doesn't root");
  - the cue `GameplayCue.WoodenSword.Q.DourlingCaltrops.AoEVFX` (`Skill1/Cues/BP_GC_WoodenSword_Skill1_DourlingCaltrops_AoEVFX`)
    spawns VFX-pack tag `VFXPack.Skill1.AOEVFX` = `NS_RowanSpaceAOE`, **the normal Dourling Dive burst**, at Rowan → the
    "second Space visual". There is no vine effect for it; Aug's code was the same.
- **How we'd do it** (all patch pak except the visual):
  1. Box on the trail: `set-call-arg` in function `SetForwardLocation`, `Divide_FloatFloat(self.Dash Extent, 2.0)` →
     `-2.0` (that function is only used by the caltrops), so the box covers the dashed path behind Rowan.
  2. Hide the cube: `Box_GEN_VARIABLE.bHiddenInGame` False → True (needs new op `set-export-prop`; or FangsBoot
     `SetHiddenInGame` on spawn).
  3. Remove the extra Space burst / give a vine look: `set-name-const` in the cue's spawn call, `VFXPack.Skill1.AOEVFX` →
     a vine-ish slot of Rowan's pack: `VFXPack.RMB.VFX` (Earth Rend's Overgrowth arc, already ally/enemy-coloured),
     `VFXPack.Skill2.AugmentVFX` (`NS_IronThorns`), `VFXPack.LMB.AugmentVFX` (`NS_Rootblade`, Siegil's Rootblade's root),
     or `VFXPack.Skill2.VFX` (Wall of Roots leaves). The cue spawns one effect at Rowan, unscaled; a real "trail" (an
     effect stretched or repeated along the box for 3 s) needs a FangsBoot hook on the caltrops actor's BeginPlay.
  4. Tooltip: `replace-text` `WoodenSword_DourlingCaltrops_desc`: `WoodenSword_Shift_title# [SHIFT]` →
     `WoodenSword_Spacebar_title# [SPACE]`.
  5. Keep it a root (tooltip says root) or make it a stun like the CC revert did for Dourling Dive — a community member's call.
- **Effort / risk**: S for 1, 4, 5; S–M for 2–3 (new ops); M for a proper trail visual (FangsBoot). Low risk.
- **Confidence**: high on cube, position and extra VFX; medium on "doesn't root" (test: enemy walking into the box).
- **Questions for a community member**:
  1. Should the vines lie on the path Rowan just dashed (behind him), or in front of him?
  2. Should the vines root (can't move, can still cast) or stun (like Dourling Dive itself now)? For how long (now 0.75 s, lasting 3 s)?
  3. Look of the vines: (a) like Earth Rend's green overgrowth (b) thorny like Iron Thorns (c) root tendrils like Siegil's Rootblade (d) no preference.

#### ROWAN: the item in the screenshot (<MISSING STRING TABLE ENTRY>, "make this something cool (idea: …")
- **What it is**: `Items/Characters/WoodenSword/Skill4/UNUSED_Item_WoodenSword_Skill4_PlantHide` (row
  `WoodenSword_Skill4_PlantHide`, tier Armor = UTILITY HEIRLOOM, icon `WoodenSword_Pwyff_s_Saplings`). Its texts point to
  `LOC_EN_AUGMENTS_WOODENSWORD` keys `WoodenSword_PwyffsSaplings_title/_desc`, which **exist in Aug but were deleted from
  the Feb string table** → "<MISSING STRING TABLE ENTRY>". It is in the Feb build's own `AvailableAugments` list (not
  one of our restores). Aug text: **"Pwyff's Saplings — Sourblossom [E]: Sourblossoms are invisible to Rowan's enemies,
  but receive 25 % less damage and slow."** Code (Feb, works on paper): `Skill4/BP_GA_WoodenSword_SpawnPlant.Apply
  PlantHide Item` multiplies the plant's damage and slow by `HidePlantDamageRatio` 0.75 and makes each plant hide itself
  for enemy viewers once its spawn animation ends (`BP_TA_WoodenSword_Skill4.Activate PlantHide Augment`, client side).
  (Not to confuse with Tangleroot Gauntlets, which has inline texts.)
- **How we'd do it**: texts: FangsBoot sets them like it does for Mask of Mana / Allseer (Aug's name and text), or a
  new patch op that adds string-table rows. "Something cool" = a design change; possible within existing code by
  numbers only (e.g. `HidePlantDamageRatio` 0.75 → 1.0 so hidden plants lose nothing, via `set-default`), anything new
  needs Lua.
- **Effort / risk**: S for texts and numbers; M+ for a new effect. Low risk.
- **Confidence**: high (identity), medium (that the invisibility works for enemies — test with 2 clients).
- **Questions for a community member**:
  1. Is this the item (icon: green-teal glowing roots, "UTILITY")? Its old name was **Pwyff's Saplings**: "your
     Sourblossoms are invisible to enemies, but deal 25 % less damage and slow less".
  2. Your idea text was cut off after "(idea:". What was the idea?
  3. If we keep the current effect: should invisible plants still be weaker (25 % less), or full strength?

#### FIORNE: sometimes her passive breaks (0 bunny stacks) which makes it near unplayable for her
- **What it is**: Bunny Stacks are Nimble Thrust's (Space) ammo: `Lancer/Skill1/BP_GA_Lancer_Ammo` (child of
  `Shared/BP_GA_Template_Ammo`), granted by `BP_GE_GrantLancerAmmoSystem`, which the passive `Lancer/P/GA_Lancer_P`
  applies at activation (authority only). The ammo ability only sets itself up **at a round's start**: on
  `OnRoundStart_CountDownEndDel` it starts the stack/cooldown listeners and fills the stacks; on `OnPreRoundEndDel` it
  clears stacks and listeners. A stack refills only via those listeners (stack used → cooldown effect; cooldown ends →
  +1 stack). So if the ammo ability is (re)created after the round countdown ended, Fiorne has 0 stacks and nothing
  refills them until the next round starts. The developers knew it fails to appear: the passive has a safety net
  `CheckAmmoSystemIsInit` (after 5 s, then every 1 s) that removes and re-grants the ammo system when its instance is
  missing ("GA_Lancer_Ammo insttance NOT FOUND") — and a re-grant mid-round lands exactly in that 0-stack state. The old,
  cancelled instance also stays bound to the game state's round delegates. Possible triggers: late spawn / hero
  re-spawn path, a reconnect, the safety net firing. Julienne's Javelin also adds an infinite "can't cast E" effect at 0
  stacks (removed on the next stack change), which would make it worse.
- **How we'd do it**: FangsHost (server) safety net: at each round start + once a second for Fiorne pawns only (from
  `GameState.PlayerArray`, no object scans), if her ammo instance exists but has no listeners/stacks and no
  `Effect.Ammo.Cooldown.Skill1` running, call the instance's own `On Round Start` (re-inits listeners and fills
  stacks) or `ListenForStackChange` + `ListenForCooldownRemoved` + `AddStack`. First a FangsHost watcher that logs her
  stack count, the ammo instance and the cooldown effect per round to catch the real trigger.
- **Effort / risk**: M (watcher, fix, 2-player test incl. death and round changes); low-medium risk.
- **Confidence**: medium-low on the exact trigger (several candidates), high that "set up only at round start" is the
  weak spot.
- **Questions for a community member**:
  1. When does it break: from the very start of a match, after Fiorne dies, at the start of round 2/3, after someone
     reconnects, after swapping heroes in the lobby?
  2. Does it fix itself in the next round, or stay broken for the whole match?
  3. Which heirlooms were on: Wanderer's Travelpack (+2 max stacks), Julienne's Javelin (E costs a stack), Trickster's
     Mixture, Lance Frills, Master's Visor, Warrior's Bounty?
  4. Does the stack counter under her health bar show 0, or is it missing completely?

#### ZOEY: Ult Aoe vfx is currently invisible (possibly only on some skins?)
- **What it is**: Feline Attraction (R) `CatSupp/Skill3/BP_GA_CatSupp_Skill3.Play Cast VFX` executes cue
  `GameplayCue.CatSupp.Skill3.CastVFX` at `ImpactTargetLocation`. The notify `CatSupp/Skill3/BP_GC_CatSupp_Skill3_CastVFX`:
  - **Aug** spawned `NS_CatSupp_Skill3_ULT` directly;
  - **Feb** (and Dec) passes no system and asks the caster's VFX pack for `VFXPack.Skill3.AOEVFX`. Both Zoey packs have
    it (`DA_VFXPack_DefaultCatSupp` → `NS_CatSupp_Skill3_ULT`, `DA_VFXPack_Hellhound_CatSupp` →
    `NS_Hellhound_CatSupp_Skill3_ULT`, both in the pak). So it's invisible whenever the pack lookup returns nothing
    (`BP_PlayerChar.GetVFXPack()`, native; the character's `VFXPack` is a *soft* reference to the default pack, and
    which pack a skin uses isn't in the skin collection asset) — that would fit "only some skins".
  - The cue is an "executed" cue: other players get it through an unreliable multicast, so under load it can be
    dropped for them. The cue also reads its rotation from a null `EffectCauser` (harmless).
  - The Hellhound pack lacks several augment VFX slots (Skill2/Skill4/Passive augment VFX) → those augment effects are
    probably invisible on Hellhound skins.
- **How we'd do it**: FangsBoot post-hook on `BP_GC_CatSupp_Skill3_CastVFX_C:OnExecute`: if `self.VFX` is not valid,
  spawn `NS_CatSupp_Skill3_ULT` (or the Hellhound one) at `Parameters.Location` — Aug behaviour as a fallback. Needs a
  repro first (which skin, own view vs others' view). A pure-pak "back to Aug" would add an object reference to the
  cue's bytecode (not size-neutral; not possible with today's tool).
- **Effort / risk**: M (repro on each skin + client hook, player update); low risk.
- **Confidence**: medium-low (the cause needs a repro).
- **Questions for a community member**:
  1. Which part is invisible: the circle where Boo lands (right when Zoey casts) or the hit effect when enemies get
     knocked up?
  2. Invisible for the Zoey player herself, for her teammates, for enemies, or for everyone?
  3. Which skin(s)? (Default, Kigurumi colours, Hellhound colours.) Does the default skin show it?

---

### Summary

| Item | Mechanism | Effort | Confidence | Needs a community member? |
|---|---|---|---|---|
| Astrada ally/enemy cage colour | VFX-pack colour data (new op `set-export-prop`); fallback FangsBoot tint | S–M | medium | yes (colours, current look) |
| Ishir ult gun sound | patch `rename-import` of an FMOD event in a cue, or FangsBoot skip | S once identified | low | yes (bug or wish? when?) |
| Rowan passive stops healing | Feb passive heal ≈ 0 always (wrong SetByCaller); FangsHost Lua heal tick like Dec | M | high (cause) / medium (symptom) | yes (where/how it heals) |
| Rowan Propagator charge bar | RE `SetGameplayEffectDurationHandle`, then FangsHost replication nudge or FangsBoot bar | M | medium | small |
| Rowan Dourling Caltrops | patch: box behind (`set-call-arg` −2.0), hide box (new op), swap VFX tag (new op), fix tooltip key; trail visual FangsBoot | S–M (+M visual) | high | yes (root/stun, look, placement) |
| Rowan missing-text item | Pwyff's Saplings: FangsBoot texts (Aug's), numbers by `set-default` | S | high | yes (idea text, confirm item) |
| Fiorne 0 bunny stacks | FangsHost watcher + re-init of the ammo ability at round start/when empty | M | medium-low | yes (when it happens, items) |
| Zoey ult AoE VFX invisible | repro per skin; FangsBoot fallback spawn of the Aug system | M | medium-low | yes (which part, which skin, who) |

Tool work that unlocks several items: AssetPatch `set-export-prop` (Astrada colour, Caltrops box) and `set-name-const`
(Caltrops VFX, Rowan passive pure-pak variant).


## Community patch notes, stream 5: Rose, Wylde, Ethryn, Brutus (Feb 2023 build)

Static research only (decompiled Blueprints `work/bp-2023-02-15`, class defaults `work/cc-audit/cdo_*.json`, extracted
assets, string tables `st_feb.json`). Nothing was run in a match. "Aug" = Aug 2022 build, "Dec" = Dec 2023 playtest.

**Tooltips:** almost every tooltip here is computed from the ability's own values (`$Variable$` placeholders in the
`LOC_EN_*` string tables), so a value patch updates the tooltip by itself. The one exception is Bounty's Reward
(hard-coded "35 bullets").

**Patch tool gap found:** `set-default` only edits top-level values of the class defaults. Three requests need a value
inside a struct, or in a component template (not the CDO):
- Brutus' HP: `BP_GE_Berserker_Stats` `Modifiers[0]…ScalableFloatMagnitude.Value`;
- Ethryn's shield box: export `wer_GEN_VARIABLE` `BoxExtent.Y`;
- Belroth's boulder: export `ProjectileSphereCollision` `SphereRadius`.

A small new AssetPatch op would cover all three: `set-export-value` with `export`, a dotted `path` with array indices,
`from` and `to`, for floats/ints/bools and FVector fields. Effort: about half a day, including a roundtrip check.

---

#### ROSE: Revert Klaive's Puzzlebox from 50 to 75 (was 100 pre-nerf)
- **What it is**
  - Heirloom "Klaive's Puzzlebox" = item `Item_DemonGirl_TeleportDamage` (tag `Item.DemonGirl.TeleportDamage`, Space).
  - After Rose teleports with Space, she deals `TPDamage` damage to enemies within `TPDRadius` (350). Each enemy hit gives
    her 25 % attack speed for 3 s.
  - The live Feb pawn uses `DemonGirl/Q/BP_GA_DemonGirl_Q_Instant`: `TPDamage` = **50**.
  - Aug used `BP_GA_DemonGirl_Q`: `TPDamage` = **100** (the "pre-nerf" number). Dec removed this damage from the ability.
  - The community's "50" matches the game.
- **How**
  - `set-default BP_GA_DemonGirl_Q_Instant.TPDamage 50 → 75`.
  - The old, unused `BP_GA_DemonGirl_Q` (still 100) doesn't matter.
  - Tooltip `demongirl_unstablepuzzlebox_desc` shows `$TPDamage$`, so it updates by itself.
- **Effort / risk:** S. Patch pak (players + servers).
- **Confidence:** high. Match test: the teleport AoE does 75.
- **A community member:** none.

#### WYLDE: LMB base damage 35 → 40
- **What it is**
  - LMB "Brim" = `Gunslinger/LMB/BP_GA_Gunslinger_LMB`.
  - `AbilityDamage` / `ModifiedAbilityDamage` = **35** (Aug 45, Dec 55). Matches the community's number.
- **How**
  - `set-default` both `AbilityDamage` and `ModifiedAbilityDamage` 35 → 40 (`ResetAbilityAttributes` copies base → modified).
  - Tooltip `gunslinger_basicattack_desc` = `$ModifiedAbilityDamage$`, so it updates by itself.
- **Effort / risk:** S. Patch pak.
- **Confidence:** high.
- **A community member:** none.

#### WYLDE: Revert RMB to the short range high dmg release version (PLEASE)
- **What it is.** RMB "Blight" = `Gunslinger/RMB/BP_GA_Gunslinger_RMB`. It is the same Blueprint in all three builds: one
  projectile (`BP_MOBA_Gunslinger_RMB_Projectile`), costs ammo, procs Hunter's Brand. Only the values differ:

  | | Aug 2022 | **Feb 2023 (live)** | Dec 2023 |
  |---|---|---|---|
  | Damage (`AbilityDamage`) | **95** | 65 | 80 (+ AD bonus ratios) |
  | Range (`Range`/`ModifiedRange`) | **562.5** | 932 / 950 (same as LMB's 930) | 1220 |
  | Ammo per shot (`Bullets to Fire`) | **2** | 1 | 1 |
  | Cooldown (`AbilityCooldown`) | 1.0 s | 0.5 s | 0.7 s |
  | Projectile speed | 2500 | 2725 | 3050 |
  | Hold to keep firing (`CanBeHeldDown`) | no | yes | yes |
  | Cast slowdown | 0 | 0.1 | 0 |

  - The Aug version is the short-range, high-damage one.
  - In Feb, Blight's range equals LMB's, although its tooltip still says "fires a short range shot".
  - RMB and LMB share one cooldown effect (`BP_GE_Cooldown_LMB_C`) in every build, so a 1 s RMB cooldown also delays LMB.
- **How:** values only (no code change). `set-default` on `BP_GA_Gunslinger_RMB`:
  - `AbilityDamage` and `ModifiedAbilityDamage` 65 → 95;
  - `Range` 932 → 562.5 and `ModifiedRange` 950 → 562.5;
  - `Bullets to Fire` 1 → 2;
  - `AbilityCooldown` 0.5 → 1.0 (`ModifiedAbilityCooldown` is already 1.0);
  - `Projectile Speed` 2725 → 2500;
  - optional: `CanBeHeldDown` true → false, `CastSlowdown` 0.1 → 0.

  What stays:
  - the Feb RMB heirlooms (OnHitAOEStack, SelfMissingHPDamage, OnHitShield) and the passive's RMB proc keep working;
  - the tooltip computes the damage by itself and already says "short range".
- **Effort / risk:** S. Patch pak. Balance risk: 95 plus the RMB proc (+10 flat + 10 % missing HP) up close.
- **Confidence:** high on the values. Unverified: that "release version" means Aug. We have no build older than Aug.
- **A community member:**
  - Is this the version you mean: 95 damage, about 60 % of LMB's range, uses 2 ammo, 1 s cooldown (Aug 2022)? Or do you
    remember different numbers?
  - Should holding RMB keep firing (Feb), or one shot per click (Aug)?
  - Is the 1 s shared cooldown with LMB OK?

#### WYLDE: Allow using ammo during the dummy phase, without Bounty's Reward stacking there
- **What it is**
  - Ammo is a stacking effect (`BP_GE_Gunslinger_P_Bullets`, tag `Effect.Gunslinger.Ammo`).
  - LMB, RMB and Shift require that tag (`ActivationRequiredTags`).
  - The only thing that fills the magazine at the start of a round is `BP_GA_Gunslinger_P.ForceReloadRoundStart`. It is
    bound to the game state's `OnRoundStart_CountDownEndDel`, which fires when the round countdown ends, after the item
    phase. Aug had no such reload.
  - So during the item / dummy phase (`GS_MOBA_Battle.Spawn Preround Dummies` … `Destroy Preround Dummies`, heroes have
    `Effect.PreRoundUnlocked`), Wylde has 0 ammo. The auto-reload only starts after a shot, so it never starts.
  - Bounty's Reward (`Item.Gunslinger.Skill2.MaxAmmoIncrease`, in `BP_GA_Gunslinger_E.Activate Max Ammo Increase`) adds
    one stack of `BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack` per Fan the Hammers projectile hit, on any target hit,
    dummies included. The stacks last all game.
- **How:** code-level, so not doable with the patch pak (it would add calls). A FangsHost hook (server only; ammo and the
  stacks are replicated effects, so clients follow):
  - Post-hook `GS_MOBA_Battle_C:Spawn Preround Dummies`, deferred about 0.5 s. For each player pawn from
    `GameState.PlayerArray` that is a `BP_Gunslinger_Char_C`:
    - call `Add Loaded Bullets(Modified MaxBullets)`, the server event that sends `Event.Gunslinger.Reload.Instant`, an
      instant refill;
    - record the stack count of `Effect.Gunslinger.Skill2.MaxAmmoIncreaseStack`, and whether
      `Effect.Gunslinger.Skill2.MaxAmmoIncreaseApplied` is present.
  - Post-hook `Destroy Preround Dummies`:
    - remove the stacks gained since: `RemoveActiveGameplayEffectBySourceEffect(<Stack GE>, nil, gained)`;
    - if the bonus was reached in this phase, also remove the Applied effect, take 1 off `Modified MaxBullets` and
      `Base Max Bullets`, and reset `SetUIAmmoMaxStacksOverride`.
  - The round-start reload then tops up as before.
  - No object scans; runs twice per round.
- **Effort / risk:** M (about a day with a 2-player test). Server only, no player update.
  - Risks: the hook timing (whether the hero exists when dummies spawn), and the UI ammo bar.
- **Confidence:** medium. A test must show: ammo in the dummy phase, auto-reload after emptying it, no Bounty's Reward
  stacks kept at round start, and the normal round-start reload.
- **A community member:**
  - Should Wylde start the dummy phase with a full magazine and reload normally?
  - Does anything else Wylde stacks for the rest of the game also need to ignore the dummy phase?

#### WYLDE: Bounty's Reward bullets needed 35 → 30
- **What it is**
  - Two values, both **35** in all builds (matches the community):
    - `BP_GA_Gunslinger_E."MaxAmmoIncrease Stack Count Required"` (the check: stacks == required);
    - the stack GE's `BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack.StackLimitCount`.
  - Tooltip `gunslinger_maxammoincrease_desc` hard-codes "If … lands 35 bullets with Fan the Hammers…".
- **How**
  - `set-default BP_GA_Gunslinger_E."MaxAmmoIncrease Stack Count Required" 35 → 30`;
  - `set-default BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack.StackLimitCount 35 → 30`;
  - `replace-text LOC_EN_AUGMENTS_GUNSLINGER gunslinger_maxammoincrease_desc "lands 35 bullets" → "lands 30 bullets"`.
- **Effort / risk:** S. Patch pak.
- **Confidence:** high.
- **A community member:** none.

#### WYLDE: Speedshine +10 % → +20 % move speed
- **What it is**
  - Heirloom "Speedshine" = `ITEM_Gunslinger_PassiveReloadSpeedBoost` (passive): move speed while reloading.
  - Both code paths (in `BP_GA_Gunslinger_Reload` and `BP_GA_Gunslinger_P`) use
    `BP_GA_Gunslinger_P.ReloadSpeedBoostPercentageSpeedUp` = **0.1** (Aug 0.1, Dec 0.35).
  - The Reload ability's own `Reload Speed Boost Percentage SpeedUp` (0.1) is unused.
- **How**
  - `set-default BP_GA_Gunslinger_P.ReloadSpeedBoostPercentageSpeedUp 0.1 → 0.2`; optionally the unused copy too, for
    consistency.
  - Tooltip `$ReloadSpeedBoostPercentageSpeedUp%100$` updates by itself.
- **Effort / risk:** S. Patch pak.
- **Confidence:** high.
- **A community member:** none.

#### ETHRYN: M1 damage 50 → 40
- **What it is**
  - LMB "Talon Strike" = `ShieldGirl/LMB/BP_GA_ShieldGirl_LMB`, a 3-hit combo:

    | Hit | Value | Aug | Feb | Dec |
    |---|---|---|---|---|
    | 1 | `FirstAttackDamage` | 40 | **50** | 45 |
    | 2 | `SecondAttackDamage` | 40 | **50** | 45 |
    | 3, the shield bash that applies a Pummel stack | `ShieldAttack Damage` | 40 | **55** | 50 |

  - Tooltip `ShieldGirl_LMB_desc` says "each attack dealing `$FirstAttackDamage$`" (computed).
  - So the community's 50 is right for hits 1-2. The third hit is 55.
- **How**
  - `set-default` `FirstAttackDamage` 50 → 40 and `SecondAttackDamage` 50 → 40;
  - third hit as a community member decides (`ShieldAttack Damage` 55 → ?; Aug had 40).
- **Effort / risk:** S. Patch pak.
- **Confidence:** high.
- **A community member:** The third hit (shield bash) does 55. Should it go to 40 too (as in Aug 2022), 45, or stay 55?

#### ETHRYN: Holy Brazier cooldown 2 s → 4 s, duration 0.75 s → 1 s
- **What it is**
  - Heirloom "Holy Brazier" = `ITEM_ShieldGirl_Skill4_PrecisionReflect` (tag `Items.Shieldgirl.Skill4.PrecisionReflect`,
    E "Stalwart Aegis").
  - `BP_GA_ShieldGirl_Skill4.ItemPrecisionShieldApply` sets the cooldown to `ItemPrecisionShieldAbilityCooldown` (**2.0**)
    and the shield's lifetime to `ItemPrecisionShieldMaxShieldLifetime` (**0.75**). Without it: 8 s and 1.75 s.
  - Same values in Aug/Feb/Dec. Match the community.
- **How**
  - `set-default ItemPrecisionShieldAbilityCooldown 2.0 → 4.0`;
  - `set-default ItemPrecisionShieldMaxShieldLifetime 0.75 → 1.0`;
  - the tooltip (`ShieldGirl_GlintingReflection_desc`, both placeholders) updates by itself.
- **Effort / risk:** S. Patch pak.
- **Confidence:** high.
- **A community member:** none.

#### ETHRYN: shield hitbox too big (past her sides) and reflects from behind
- **What it is**
  - The shield is a target actor `Gameplay/TargetTypes/ShieldGirl/BP_TA_ShieldGirl_Skill4`. It spawns at Ethryn, faces the
    cursor (yaw) and is attached to her.
  - Its collision box `wer`: `BoxExtent` = (5, **240**, 162) at `RelativeLocation` X = 109. That is a thin plate 109 uu in
    front of her, **480 uu wide**, while her hit capsule (`CharCapsule`) has radius 80. So it reaches about 160 uu past
    her body on each side.
  - Identical in Aug, Feb and Dec.
  - `OnProjectileOverlap` reflects every non-allied projectile that touches the box and lacks `Identifier.DontTrigerReflect`
    / `Projectile.Identifier.Inactive`. **There is no direction check.**
    - The melee block (`OnAOEImpact`) does have a front-only check (dot product < 0).
    - So a projectile that passes beside her from behind crosses the plate and is reflected.
    - So is a piercing projectile that goes through her from behind.
  - The same box is also the 90 % slow and knockback zone (`KnockbackTick`) and the melee block zone.
- **How**
  1. Narrow the box to her width: `wer_GEN_VARIABLE.BoxExtent.Y` 240 → about 80-90. Data only, but it needs the new
     `set-export-value` op (see the top).
     - This fixes "too wide" and most "from behind" cases: from straight behind, a projectile hits her body first.
     - The shield's visual effect (team-coloured Niagara, `VFXPack.Skill4.VFX`) keeps its size, so the visible shield may
       look wider than where it reflects.
  2. A real front-only check for projectiles is new code in `OnProjectileOverlap`.
     - The patch pak can't add code, and UE4SS Blueprint hooks run after the function, so FangsHost can't veto it either.
     - It needs either a jump-recomputing AssetPatch edit (L) or a native hook on the projectile→interface call
       (unproven, L).
- **Effort / risk:** (1) M including the new op and a test. (2) L.
- **Confidence:** high on the numbers. Medium on how big the visual is versus the box: check in a screenshot.
- **A community member:**
  - Should the reflecting zone be only as wide as Ethryn's body, even if the visible shield looks a bit wider? Or should
    it match the visible shield?
  - After narrowing, is "reflects from behind" still a problem in your games (e.g. piercing shots that go through her)?
  - Narrowing also shrinks the zone that slows and pushes enemies walking through the shield. Is that OK?

#### ETHRYN: shield "magnetically" absorbs Belroth's E boulder and reflects it long before it reaches her
- **What it is**
  - Belroth's E "Boulder Toss" projectile `BigBoi/Skill4/BP_MOBA_BigBoi_Skill4_Projectile_2` has a root hit sphere
    `ProjectileSphereCollision` of **radius 170** (interaction sphere 20 × scale 3 = 60). Aug had 170 too. **Dec reduced
    it to 100.**
  - The shield reflects as soon as the boulder's sphere touches the plate.
  - It then spawns the reflected clone a further `ProjectileSphere radius + 50` = 220 uu back along the path
    (`BP_TA_ShieldGirl_Skill4` ubergraph L610).
  - So the boulder turns around up to ~390 uu before reaching the shield, and the shield is already 109 uu in front of her.
- **How**
  - Use Dec's value: `ProjectileSphereCollision.SphereRadius` 170 → 100 on the boulder (new op).
  - This also shrinks the boulder's hit size against heroes (Dec's balance).
  - The clone offset is code (a constant 50 + the radius), so it follows the radius.
- **Effort / risk:** S-M (with the op). Patch pak.
- **Confidence:** medium. Which of the boulder's spheres triggers the shield overlap is native code (not checked). A
  2-player test should measure the reflect distance before and after.
- **A community member:** Belroth's boulder would also get a smaller hit area against everyone (as the developers did in Dec 2023).
  Is that OK, or should only the reflect distance change (harder)?

#### ETHRYN: reflect one-shots when Wylde's E is reflected
- **What it is**
  - Fan the Hammers fires all loaded rounds. Each is a projectile (`BP_MOBA_Gunslinger_Skill2_Projectile`) with its own
    damage spec: 25 damage, asset tag `Effect.Gunslinger.Passive.MainAbilityDamage`.
  - The shield clones each one separately (`CloneDeferred(Ethryn, …, DestroyExisting = true, IsReflect = true)`, native).
  - Nothing in the Feb shield code scales reflected damage. Whatever multiplies it is native or in Wylde's passive.
  - Likely cause (code reading, untested): if the clone keeps Wylde's original spec, each returning bullet counts as
    Wylde's own main-ability damage. His passive (`BP_GA_Gunslinger_P.Check Stacks and Apply`, bound to his ASC's
    `PreDamageDoneDel`) would then stack Hunter's Brand and proc bonus damage on Wylde himself, bullet by bullet.
- **How (options, after a test shows the cause):**
  - a) Fan the Hammers bullets can't be reflected: they get `Identifier.DontTrigerReflect`. Then they pass the shield and
    hit Ethryn.
    - Needs a tag-container edit on the projectile CDO. `copy-default` from a CDO with exactly that tag doesn't exist;
      the closest ones carry extra tags. A small op is needed.
  - b) Keep the reflect, stop the self-procs: code (FangsHost can't veto a Blueprint function). L.
  - c) Cap it: code. L.
- **Effort / risk:** test first (2 players: Wylde E into a raised shield, log the damage and effects on Wylde). Then a) is
  S-M, b) and c) are L.
- **Confidence:** low on the cause.
- **A community member:**
  - When Ethryn's shield meets Fan the Hammers, what should happen?
    - A) the bullets come back, but each only does its normal damage;
    - B) the shield blocks them (no damage to Ethryn, nothing comes back);
    - C) they pass through the shield.
  - Roughly how much damage does Wylde take now: all his HP from full?

#### BRUTUS: increase base HP by 100
- **What it is**
  - Base stats come from `Gameplay/Effects/Player/Berserker/BP_GE_Berserker_Stats`, the pawn's `PassiveGameplayEffects[0]`.
  - `MaxHealth` Override = **950** (Aug 1000; Dec moved base HP to the pawn, `BaseMaxHP` 1150 + 125 per round).
  - The same GE also sets MaxMana 2500 and MoveSpeed 600. No other HP source for Brutus in Feb.
- **How:** `Modifiers[0].ModifierMagnitude.ScalableFloatMagnitude.Value` 950 → 1050 in that GE's defaults. This is a nested
  value, so it needs the new op (`set-default` can't reach it). No tooltip shows base HP.
- **Effort / risk:** S once the op exists. Patch pak (the GE is applied on the server; clients see the replicated attribute).
- **Confidence:** high. Match test: Brutus spawns with 1050 / 1050.
- **A community member:** Brutus has 950 HP now (1000 in Aug 2022). So +100 = 1050. Correct?

---

### Summary

| Item | Mechanism | Effort | Confidence | Needs a community member? |
|---|---|---|---|---|
| Rose Klaive's Puzzlebox 50 → 75 | patch `set-default` `BP_GA_DemonGirl_Q_Instant.TPDamage` | S | high | no |
| Wylde LMB 35 → 40 | patch `set-default` (base + modified) | S | high | no |
| Wylde RMB revert (Aug: 95 dmg, 562 range, 2 ammo, 1 s) | patch `set-default` × 6-8, values only | S | high (values) | yes: confirm the version, hold-to-fire |
| Wylde ammo in dummy phase, Bounty's Reward not stacking there | FangsHost hooks on the preround dummy spawn/despawn | M | medium | small (full magazine?) |
| Bounty's Reward 35 → 30 | patch `set-default` × 2 + `replace-text` | S | high | no |
| Speedshine +10 % → +20 % | patch `set-default` `BP_GA_Gunslinger_P.ReloadSpeedBoostPercentageSpeedUp` | S | high | no |
| Ethryn M1 50 → 40 | patch `set-default` × 2 (+ third hit 55?) | S | high | yes: third hit |
| Holy Brazier 2 → 4 s, 0.75 → 1 s | patch `set-default` × 2 | S | high | no |
| Ethryn shield too wide / from behind | new op: box half-width 240 → ~80; true direction check is L | M (L for the full fix) | high (numbers) | yes: width vs visual |
| Shield vs Belroth boulder | new op: boulder sphere 170 → 100 (Dec) | S-M | medium | yes: smaller boulder hit area OK? |
| Reflected Wylde E one-shots | 2-player test first; then non-reflectable tag (S-M) or code (L) | test + S-M/L | low | yes: desired behaviour |
| Brutus +100 HP (950 → 1050) | new op: nested GE modifier value | S | high | confirm 1050 |

New tooling these share: an AssetPatch `set-export-value` op (nested paths and non-CDO exports), about half a day.
Everything except the dummy-phase ammo is a patch-pak change (players get it from the launcher, servers from
`FANGS_PAKS`). The dummy-phase ammo is FangsHost only (server).


## Community patch notes: Zoey, Rayo, Belroth (Feb 2023 build)

Investigator 6, static research only (no game runs). Sources: Feb pseudocode `work/bp-2023-02-15/`, class defaults
`work/cc-audit/cdo_{aug,feb,dec}.json` (`props.py`), string tables `st_feb.json`, `AssetPatch calls`.
Asset paths below are under `MOBA/Content/Gameplay/Abilities/Player/`.

General notes:
- Every tooltip in this stream except one is computed from the ability's own values (`$Property$` in the string
  table), so a `set-default` also updates the tooltip. The exceptions are called out.
- None of these assets is touched by `ccrevert.json` (it edits Zoey's `Skill4` and `LOC_EN_ABILITIES_CATSUPP`, not
  these), so a new patch file (e.g. `tools/patch/patches/balance.json`) doesn't overlap it. Rayo's tooltip edits go
  into `LOC_EN_AUGMENTS_LIGHTNINGARCHER`, which nothing else patches yet.
- All of it goes into the patch pak: players (launcher) and game servers get the same file.

### Zoey & Boo (CatSupp)

#### M1: increase heal from 48 → 60 (over 2s)
- **What it is**: Witch Ball, `CatSupp/LMB/BP_GA_CatSupp_LMB`. Tooltip: "heals allies for `$BaseHealPerTick*12$` HP
  over `$HealDuration$` seconds" = 4 × 12 = **48** over 2.0 s. `BaseHealPerTick` Feb 4 (Aug 6, Dec 4); `HealDuration`
  2.0 (Dec 1.25).
- What the code really does per ally hit (`MakeEffectSpecs`): an instant heal of 4 (`Modified Flat Heal To Apply`),
  another instant heal of 4 (`ModifiedHealPerTickToApply`), and a heal over time `BP_GE_DotHealFourPerSec` of 4 per
  tick, period 0.25 s, 2 s (8 ticks, no tick on application) = **about 40 HP, not 48**. The "×12" in the tooltip
  doesn't match the code (unverified in a match; heal power also scales it).
- **How we'd do it**: `set-default BP_GA_CatSupp_LMB.BaseHealPerTick 4 → 5` (`ModifiedHealPerTickToApply` and the flat
  heal are re-derived from it in `ResetAbilityAttributes`; also set the stale CDO `ModifiedHealPerTickToApply 8 → 10`
  for tidiness, optional). Tooltip then says 60; the real heal goes ~40 → ~50 (+25 %, the same ratio).
  If the real heal should be 60: `BaseHealPerTick 4 → 6` (real ~60) and fix the tooltip with
  `replace-text catsupp_basicattack_desc "$BaseHealPerTick*12$" → "$BaseHealPerTick*10$"` (6 × 10 = 60).
- **Effort / risk**: S. Low.
- **Confidence**: high for the edit; medium for the "real heal ≈ 40" reading. A match test should log the ally's
  health over 2 s after one bolt (with and without the patch).
- **Questions for a community member**: "The tooltip says 48, but by our reading one bolt really heals about 40. Do you want
  (a) the tooltip number to go to 60 (real heal ~50, everything +25 %), or (b) the real heal to be 60 (we fix the
  tooltip so it shows the true number)?"

#### Increase base M2 shield from 45 → 50 & duration 1.5s → 2s
- **What it is**: Shield of Hope, `CatSupp/RMB/BP_GA_CatSupp_RMB`. `Base Shield Amont` (sic) 45 (Aug 75, Dec 70),
  `ModifiedShieldAmount` 45 (re-derived from the base), `Shield Duration` 1.5 (Aug 3.0, Dec 3.0). Values match the
  community's.
- **How we'd do it**: `set-default "Base Shield Amont" 45 → 50`, `ModifiedShieldAmount 45 → 50`,
  `"Shield Duration" 1.5 → 2.0`. Tooltip computed (`$ModifiedShieldAmount$`, `$Shield Duration$`).
- Side effect: `Shield Duration` is also the duration of the RMB heirlooms' effects: Cursed Candle's lifesteal,
  Bloom's Brew's healing bonus, and one of Haste Chimes' speed effects (`MakeSpeedUpEffectSpec(…, Shield Duration, …)`).
  They all get 2 s too.
- **Effort / risk**: S. Low.
- **Confidence**: high.
- **Questions for a community member**: "Making the shield last 2 s also makes Cursed Candle's lifesteal, Bloom's Brew's
  healing bonus and Haste Chimes' speed boost last 2 s. Is that OK?"

#### Increase Shieldnip duration from 0.75s -> 1.5s
- **What it is**: Shieldnip (utility heirloom on Bell Blare, Shift), `CatSupp/Skill2/BP_GA_CatSupp_Skill2`
  (`ApplyAOEShield`: `MakeShieldEffectSpec(Player, AOEShield, AOESDuration)`). `AOESDuration` 0.75, `AOEShield` 125.
  Dec: 1.5 s but 60 shield. (Aug: the Shift asset had another name; no Shieldnip there.)
- **How we'd do it**: `set-default AOESDuration 0.75 → 1.5`. Tooltip computed (`$AOESDuration$`).
- **Effort / risk**: S. Low.
- **Confidence**: high.
- **Questions for a community member** (optional): "The later build (Dec 2023) also made it 1.5 s but cut the shield from 125 to
  60. Keep 125?"

#### Buff Mentor's Locket (ult aug) +35 -> +75 per target
- **What it is**: Mentor's Locket (ult heirloom), `CatSupp/Skill3/BP_GA_CatSupp_Skill3`: `ActivateAllyVamp` heals each
  ally in the area for (enemies hit × `AVHealPerEnemy`). `AVHealPerEnemy` 35 (Dec 35). The enemy list is filled
  before the ally loop, so the count is right.
- **How we'd do it**: `set-default AVHealPerEnemy 35 → 75`. Tooltip computed.
- **Effort / risk**: S. Low.
- **Confidence**: high.
- Also noticed (not asked): the ult's own tooltip says it heals allies for "200 HP" (hard-coded text, Aug's value);
  the Feb heal (`AV Heal`) is 150. A `replace-text catsupp_ult_desc "200 HP" → "150 HP"` (or `$AV Heal$`) would fix it.
  Question for a community member: "The ult's tooltip says it heals 200, but it really heals 150. Should we fix the text, or make
  the heal 200 like the tooltip says?"

### Rayo (LightningArcher)

"Red" = a **combat heirloom** (the red slot; `ItemTier` default = Weapons = COMBAT HEIRLOOMS). Rayo's red items on
these keys and their bonuses match the numbers in the patch notes exactly:
- red M2 = **Pinpoint Spotter** (`ITEM_LightningArcher_RMB_SingleTarget`): Flashbolt "+75 % bonus damage and +75 %
  range, but only hits 1 enemy";
- red Shift = **Stormlense Scope** (`ITEM_LightningArcher_ShiftRangeDamageAmp`): Lightning Strike double range and
  "up to +85 % damage based on distance".
(Sniper's Dynamo, the other RMB heirloom, is a utility item.)

#### Reduce red M2 bonus dmg (+75% -> +50%)
- **What it is**: Pinpoint Spotter, `LightningArcher/RMB/BP_GA_LightningArcher_RMB` `Setup Single Target Aug`:
  damage × (1 + `BonusDamage`/100). `BonusDamage` 75 (Aug 75, Dec 30); `BonusRange` 75 (Aug 100) unchanged.
- **How we'd do it**: `set-default BonusDamage 75 → 50`. Tooltip computed (`$BonusDamage$%`).
- **Effort / risk**: S. Low.
- **Confidence**: high.
- **Questions for a community member**: "By 'red M2' and 'red Shift' you mean the combat heirlooms Pinpoint Spotter and
  Stormlense Scope, right?"

#### Reduce red Shift bonus dmg (up to +85% -> up to +50%)
- **What it is**: Stormlense Scope, `LightningArcher/E/BP_GA_LightningArcher_E_` `Range Damage Amp Calculate Damage`.
  r = distance travelled / range:
  - r < 1/3: no bonus;
  - 1/3 ≤ r < 0.85: damage × (1 + r), i.e. +33 % … +85 % (the "1 + r" ramp is fixed in the code);
  - r ≥ 0.85: damage × `EagleEyeMaxDamageMultiplier` (1.85, same in Aug).
- **How we'd do it**: lowering only the multiplier to 1.5 would leave +84 % just below 85 % of the range and drop
  to +50 % beyond it, so the cut-off must move too:
  - `set-default EagleEyeMaxDamageMultiplier 1.85 → 1.5`, and
  - `set-call-arg function "Range Damage Amp Calculate Damage" call Less_FloatFloat arg 1 from 0.85 to 0.5 count 1`
    (match `{"1": "0.85"}`; a float literal → float literal, same size).
  - Result: +33 % at a third of the range, rising to +50 % at half range, +50 % from there on. Tooltip computed
    (`$EagleEyeMaxDamageMultiplier-1%100$%` → 50 %).
  - Alternative (flat): cut-off `0.85 → 0.0`: no bonus up to a third of the range, flat +50 % beyond.
  - A smooth ramp up to +50 % at full range needs a code change (Lua or a new patch op): M.
- Also: the tooltip header says "Lightning Strike **[LEFT]**" (should be [SHIFT]):
  `replace-text LightningArcher_StormlenseScope_desc "[LEFT]" → "[SHIFT]"` (optional).
- **Effort / risk**: S (two edits). Low.
- **Confidence**: high for the code reading; a match test should check damage at short/medium/long distance.
- **Questions for a community member**: "Stormlense Scope's bonus grows with distance: none up to a third of the range, then
  +33 % rising to +85 %. Capping it at +50 %, which feels best? (a) rises from +33 % to +50 % by half range, then
  stays +50 %; (b) a flat +50 % beyond a third of the range; (c) a smooth rise to +50 % at max range (takes longer to
  make)."

#### Blitzhead arrows: reduce max stacks to 35. Remove the self damage on miss part
- **What it is**: Blitzhead Arrows (combat heirloom on LMB, `Items/Characters/LightningArcher/Legendary/BlitzheadArrows`,
  tag `Item.Archer.DamageStackLMB`), code in `LightningArcher/LMB/BP_GA_LightningArcher_LMB`:
  - `ApplyDamageStack`: LMB damage + min(hits, `DeathstrikeMaxStacks`). `DeathstrikeMaxStacks` 60 (Dec 60) =
    tooltip "up to a maximum of 60 damage".
  - `ActivateDeathstrikeMissEffect` (bound to projectile miss): if Health > `DeathstrikeSelfDamage`/AttackPower,
    deals `DeathstrikeSelfDamage` (35, same in Aug/Dec) to Rayo. It never kills him (the Health check).
- **How we'd do it**:
  - `set-default DeathstrikeMaxStacks 60 → 35`. Tooltip computed.
  - Self-damage off, cleanest: `set-call-arg function ActivateDeathstrikeMissEffect call Greater_FloatFloat arg 0
    from CallFunc_GetFloatAttributeFromAbilitySystemComponent_ReturnValue to CallFunc_Divide_FloatFloat_ReturnValue
    count 1`. The check becomes "x > x", always false, so no damage effect is ever made (variable → variable, same
    size).
  - Simpler alternative: `set-default DeathstrikeSelfDamage 35 → 0` (a damage, not a duration, so 0 is allowed). It
    still applies a 0-damage effect on every miss; could show a "0" or count as being hit. Test before choosing it.
  - Tooltip: remove the miss sentence, `replace-text LightningArcher_BlitzheadArrows_desc` from
    "Missing with <RichText.TooltipKeyWords>#LOC_EN_ABILITIES_LIGHTNINGARCHER|LightningArcher_LMB_title#</> deals
    <RichText.TooltipDamage>$DeathstrikeSelfDamage$ damage</> to <RichText.TooltipKeyWords>#LOC_EN_GENERAL_LIGHTNINGARCHER|LightningArcher_Name_title#</>.<br><br>"
    to "" (exact raw text from `st_feb.json`).
- **Effort / risk**: S. Low.
- **Confidence**: high; a match test should miss a few shots (no health loss) and hit 40 times (bonus stops at +35).
- **Questions for a community member**: none ("max stacks 35" = at most +35 damage on LMB; today +60).

#### Reduce the amount of time he has to stand still to M1 (do not increase his base attack speed with this)
- **What it is**: Storm Shot, `BP_GA_LightningArcher_LMB`. The cast task (`MOBAWaitCastTime`) runs `CastTime` 0.45 s
  (Aug 0.25, Dec 0.40) with `LockWhileCasting` true and a literal `CastSlowdown` 0.0 (speed × 0 = he stands still),
  scaled by attack speed (`UseAttackSpeed` true). The cooldown, `AbilityCooldown` 0.25 s (Aug 0.5, Dec 0.65), starts
  after the cast (`ApplyCooldownPostCast`). One shot every 0.45 + 0.25 = **0.70 s**; he stands still for 0.45 of it.
  (Aug: 0.25 standing + 0.5 cooldown = 0.75 s.)
- **How we'd do it**, two ways:
  - (a) shorter draw, same fire rate: `set-default CastTime 0.45 → 0.25` (Aug's), `AbilityCooldown 0.25 → 0.45`,
    `ModifiedAbilityCooldown 0.5 → 0.45` (re-derived, set for tidiness). Still 0.70 s per shot; he stands still
    0.25 s instead of 0.45 s. The draw animation speeds up to match (`AdjustAnimationPlayRateToMontageEvent`).
  - (b) same timing, but he can walk slowly while drawing: `set-call-arg function
    ExecuteUbergraph_BP_GA_LightningArcher_LMB call MOBAWaitCastTime arg 16 from 0.0 to 0.5` (CastSlowdown = 50 %
    move speed; arg 16 is the 0.0 after the four bools; 0.0 also appears at args 8 and 18, so it needs the arg index).
- Caveat for (a): attack speed shortens the cast; whether it also shortens the cooldown is decided natively
  (`Data.Cooldown` SetByCaller). If only the cast scales, moving time from the cast into the cooldown makes attack-speed
  boosts (Storm Shardstring, Quickdraw Talisman, Shard buffs) worth less. A match test with and without attack-speed
  buffs measures shots per second.
- The client predicts its own cast timing; the pak changes it for both client and server, so no desync.
- **Effort / risk**: S. Low-medium (feel of the hero; attack-speed interaction unverified).
- **Confidence**: medium-high.
- **Questions for a community member**: "Which fix do you want for Rayo's M1? (a) a shorter draw where he stands still (0.45 →
  0.25 s, like the Aug 2022 build), with the same shots per second; (b) the same draw time, but he can walk slowly
  while drawing (e.g. at 50 % speed)."

### Belroth (BigBoi)

#### Angerstone talons is currently bugged: "deals -10 damage but no longer heals belroth". Make this +40 damage instead
- **What it is**: Angerstone Talons (heirloom on Shift, Slam), `BigBoi/Skill1/BP_GA_BigBoi_Skill2`.
  `ApplyOnlyDamage`: `HealPerHit = ODHeal` (0: no heal) and `ModifiedAbilityDamage = ODMagnitude` (a fixed number,
  not a bonus). `ODMagnitude` 60, but the base damage `AbilityDamage` went 30 (Aug) → 70 (Feb) and the item wasn't
  updated, so the item sets 60 instead of 70: tooltip `$ODMagnitude-AbilityDamage$` = **−10**. Not a sign bug in the
  code: a stale number. (The item isn't in Aug; Dec removed `ODMagnitude`.)
- **How we'd do it**: `set-default ODMagnitude 60 → 110` (70 + 40). Tooltip computed: "deals 40 bonus damage, but no
  longer heals Belroth". The heal loss stays, as the notes ask.
- **Effort / risk**: S. Low.
- **Confidence**: high.
- **Questions for a community member**: none.

#### Slightly revert the craterthorns nerf (40 -> 50dmg)
- **What it is**: Craterthorns (heirloom on Boulder Toss, E), `BigBoi/Skill4/BP_GA_BigBoi_Skill4`: the boulder pickup
  actor gets `PickUpDamage = PUDMagnitude`. `PUDMagnitude` 40. The boulder pickup and this item don't exist in Aug
  and are gone in Dec, so the pre-nerf value is from a build we don't have; we take the notes' 50.
- **How we'd do it**: `set-default PUDMagnitude 40 → 50`. Tooltip computed.
- **Effort / risk**: S. Low.
- **Confidence**: high.
- **Questions for a community member**: none.

### Summary

| Item | Mechanism (patch pak) | Effort | Confidence | Needs a community member? |
|---|---|---|---|---|
| Zoey M1 heal 48 → 60 | `BaseHealPerTick` 4 → 5 (or 6 + tooltip fix) | S | high (real heal ≈ 40 needs a test) | yes: tooltip 60 or real 60 |
| Zoey M2 shield 45 → 50, 1.5 → 2 s | `Base Shield Amont`, `ModifiedShieldAmount`, `Shield Duration` | S | high | yes: RMB heirloom durations follow |
| Shieldnip 0.75 → 1.5 s | `AOESDuration` | S | high | optional (keep 125 shield) |
| Mentor's Locket 35 → 75 | `AVHealPerEnemy` | S | high | no (ult tooltip 200 vs 150: optional) |
| Rayo red M2 +75 → +50 % | Pinpoint Spotter `BonusDamage` | S | high | confirm "red" = combat heirloom |
| Rayo red Shift +85 → +50 % | Stormlense `EagleEyeMaxDamageMultiplier` + `set-call-arg` cut-off | S | high | yes: ramp shape |
| Blitzhead max 35, no self-damage | `DeathstrikeMaxStacks`, `set-call-arg` (x > x), `replace-text` | S | high | no |
| Rayo M1 stand-still shorter | `CastTime` ↓ + `AbilityCooldown` ↑, or `CastSlowdown` 0 → 0.5 | S | medium-high | yes: (a) or (b) |
| Angerstone Talons +40 | `ODMagnitude` 60 → 110 | S | high | no |
| Craterthorns 40 → 50 | `PUDMagnitude` | S | high | no |

All ten fit in one new patch file; about 2 h to write and build, plus one `test_patch.sh`-style match per hero to
confirm (Zoey heal and shields, Rayo damage by distance and shot rate, Belroth Shift/E damage).
