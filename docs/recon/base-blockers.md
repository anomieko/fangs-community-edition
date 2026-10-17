# Base blockers: no walking back into your base (the community's "Mickey Mouse fountain")

The community's request (swagnaros, through the user, 16 Oct): "Remove the LoL style fountain, once you leave base you
are blocked from going back into it". Aug 2022 worked that way; Feb 2023 only took the blocker actors off the maps.
Placement and the first build: `docs/recon/community-patchnotes.md` ("Base blockers") and
`docs/recon/community-build-modes.md`.

## How the game does it (Feb 2023, `BluePrints/Components/BP_AC_SpawnBlocker`)

Every hero has the component. 2 s after its `BeginPlay` it lists the map's `BP_SpawnBlocker` actors (`SpawnBlockers`)
and calls `ApplyImmunity`.
- **`ApplyImmunity`** (server only): if the hero is "inside a base", apply `BP_GE_Immunity_All` with no end, granting
  `Effect.SpawnBlocker` and `Systems.Input.LockAbilities`. So a hero in its base is immune and can't use abilities, as
  in Aug.
- **Leaving:** the hero's `OnActorEndOverlap` with a blocker runs `BlockSpawn` (its player) and `BlockSpawnServer` (the
  server). Each sets the capsule to block the blockers' channel (25), so the hero can't walk back in, and calls
  `RemoveImmunity`.
- **Round start** (`OnRoundStart`): a hero touching no blocker gets `RemoveImmunity` and the block; a hero inside gets
  unblocked.
- **Death, revive** (`OnDeath`, `OnRevive`) and **round end** unblock; death and revive also run `ApplyImmunity` again
  (after `UnblockSpawnServer`).

**The Feb bug.** Aug's `ApplyImmunity` asked `IsInsideSpawnBlockers()`: is the hero itself overlapping a blocker. Feb
replaced it with `HasRespawnedInsideBase()`, which asks whether `GameplayStatics.GetPlayerPawn(self, 0)` overlaps a
blocker's `Sphere`.
- On a dedicated server there is no player 0, so the protection never applied at all.
- On our servers (listen servers with the local player removed) player 0 is the first remote player. Every hero got the
  protection whenever that player's hero stood in a base, wherever the hero itself was.
- A hero protected outside its base touches no blocker, so the only thing that would take it off is the next round
  start.
- In the combined run of 17 Oct, test heroes could cast nothing all match. The blockers were switched off for
  `deploy-2026-10-17-1223`.

## The fix (17 Oct)

1. **Patch `base-blockers`** (`tools/patch/patches/base-blockers.json`): in `HasRespawnedInsideBase`, the overlap test
   takes `GetOwner()` (the hero itself) instead of player 0's pawn. One `replace-call-arg`; the decompile reads
   `CallFunc_Array_Get_Item.Sphere.IsOverlappingActor(GetOwner())`. This is Aug's rule: protection only for a hero
   inside a base.
2. **Safety net in FangsHost** (`modes.lua`): once a second, a hero who has `Effect.SpawnBlocker` while touching none of
   the map's blockers gets the component's own `BlockSpawnServer()` (server) and `BlockSpawnClient()` (its player).
   - That takes the protection off and blocks the way back, as walking out does.
   - It only runs on a map that got blockers, reads `GameState.PlayerArray` and the component's own blocker list
     (no object scans), and logs `base blockers: released …`. A hero whose list is empty (its component would have
     started before the blockers were placed) is left alone: blocking it could push it out of its own base.
   - It covers any exit the game might not see: a teleport, a displacement, a respawn elsewhere.
3. **Placement, Stormheart and Crownwatch** (both `blockers.lua`). The first test round showed their blockers far too
   small: heroes walking back stopped 276 (Stormheart) and 328 (Crownwatch) from the centre, and Crownwatch's team A
   start (283 from the centre) was outside its blocker. Two causes:
   - **Collision.** The Aug mesh there is `SM_Sphere` (a convex hull of radius 100, same file in Aug and Feb). The
     blocker's root mesh registers, and takes its collision, while the actor is being created (`PostSpawnInitialize`),
     before a deferred spawn can change anything. Setting `StaticMesh` on the new actor changed its looks and bounds but
     kept the collision of the class's own `/Engine/BasicShapes/Sphere`: radius 50 × the smallest scale (247 on
     Stormheart, 298 and 249 on Crownwatch, plus a hero capsule's ~30: the 276 and 328 above). Now the class default's mesh is swapped for the spawn and
     put back right after. Embersong uses the class's mesh anyway (its blocker stopped heroes at 842 = 811 + 31).
   - **Protection sphere.** Feb's `HasRespawnedInsideBase` gives protection inside the blocker's `Sphere` component
     (overlap only, radius 32 × its smallest world scale). The Aug Stormheart and Crownwatch blockers set their own
     Sphere scale (5.4375 × 5.4375 × 3.625 and 5.375 × 5.375 × 3.5625, relative to the mesh); with the class's
     (3.156 × 3.156 × 1.375) the sphere was only 217-262 across. `blockers.lua` now sets the Aug scale per blocker.
4. **Switched on:** `ENABLED = true` in both `blockers.lua` (FangsBoot and FangsHost, identical).

Why both: the patch fixes the rule itself, the same for players and servers. The safety net costs little and closes the
"left without being seen leaving" case, which would otherwise last until the next round.

**Off switches:**
- `ENABLED = false` in both `blockers.lua` (no blockers, the patch and the net do nothing);
- `"enabled": false` in `base-blockers.json`.

## Tests

`tools/run/test_base.sh` (`test_base.lua`, `test_base.steps`) runs `tools/run/test_patch.sh` with two players: alice is
team A and the first player, bob is team B. It uses `MAP=` and `SKIP_CC=1`, and logs each hero against its base
(`base.log` on the game server). It also measures what stops a hero walking back in: `free()` walks the same way with
the blockers' channel ignored, so a hero who gets in that way was stopped by the blocker, not by the base's walls.
Helpers: `info()` (each blocker's mesh, scale, Sphere radius), `die()` (a real death at the enemy turret, at the nearest
spot in its range clear of both blockers).

Results, 17 Oct, Feb 2023 build, Rowan (alice, team A) and Astrada (bob, team B). Runs `base-s2`, `base-c3`
(`base-c2` before the death fix), `base-e2`. The first round (`base-ctl`, `base-e`, `base-s`, `base-c`, `base-all`)
found the bugs above. With the final code:
- `base-all3` (Embersong, every live patch plus this one): every case as in `base-e2`, and 86/88 patched values loaded
  on both clients and the server, as at the deploy. (`base-all2` never reached the arena: the lock-in found no lobby
  controller, before any blocker code ran.)
- `base-ctl2` (no patch): Feb's bug is back (`ApplyImmunity` on bob outside his base, with alice in hers: protected,
  locked), and the safety net released him within a second (`base blockers: released …`).

| Case | Embersong | Stormheart | Crownwatch |
|---|---|---|---|
| Blocker (`info`) | class sphere, collision 811, Sphere 714 | SM_Sphere 601 × 726, Sphere 573 / 563 | SM_Sphere 848 / 899 across, Sphere 691 / 567 |
| Augment phase, at spawn | protected, client's LMB refused | same | same (`base-c2`: alice unprotected, see below) |
| Walks out in the augment phase | ability works, stopped at 842 on the way back, back at spawn and protected at round start | – | ability works, stopped at 888, back at spawn and protected at round start |
| Round start, at spawn | protected, locked, LMB refused | same | same |
| Walks out | protection off within the step, channel 25 → block, LMB works | same | same |
| Walks back | stopped at 842 from the centre; with the blocker ignored: back at spawn | stopped at 789; ignored: in | stopped at 888; ignored: in |
| Feb bug (`ApplyImmunity` outside, alice in her base) | no protection (control `base-ctl`: protected, the safety net took it off in ≤ 1 s) | same | same |
| Teleported out | protection off at once, LMB works, stopped at 842; ignored: in | stopped at 764; ignored: in | off, LMB works; the straight way back hits the map at 2228 even with the blocker ignored (walls: not a test of the blocker) |
| Dies in the lane, respawns | at spawn, protected, channel 25 overlap; walks out: off, stopped at 842; ignored: in | same, 789 | same, 888 |
| Round change | 20 s after the end: at spawn, unprotected (see below); round start: protected; walks out: off, stopped at 842 | same, 771 | same, 873 |
| Safety net releases | 0 (the controls': 1 each) | 0 | 0 |

Before the placement fix (`base-s`, `base-c`): heroes walking back stopped at 276 (Stormheart) and 328 (Crownwatch)
from the centre, and Crownwatch's team A start was outside its blocker.

**What the tests also showed**
- **The death in the first round of tests** (`base-e`): the old turret helper put bob in front of the enemy turret,
  inside the enemy blocker. On his respawn the move to his start ended that overlap; the component's `OnEndOverlap` then
  blocked him (any blocker counts), and his own blocker pushed him out to its edge, unprotected (841 from the centre,
  exactly on the line from his start). In play an alive hero can't be inside the enemy blocker: whoever has left their
  base blocks every blocker, and a dead hero doesn't move. A teleport ability that ignores collision could still do it;
  the hero then starts outside their own base, as after leaving it. `die()` now kills the hero in the lane.
- **Spawn protection in the augment phase** is uneven, as in the game itself: round 1 gives it if the hero is in its
  Sphere when its component starts, 2 s after the hero spawns (in `base-c2` alice stood in hers but wasn't protected,
  in `base-c3` she was: probably that timing, not checked further), and later rounds don't (the round end runs `ApplyImmunity` where the hero then stands, and the move back to spawn
  doesn't). Every hero gets the game's pre-round immunity anyway; the difference is only whether abilities work from
  inside the base. The dummies stand a few hundred units outside each base: a hero walks out to them, can't walk back in until
  the round starts, and `RefreshPlayersAfterPreRound` then revives every hero, unblocks them and puts them at their
  spawn, protected. Abilities inside the base during the augment phase stay as the game has them: locked in round 1
  only (user, 17 Oct: "keep as is").
- **Dashes out of the base** can't happen during a round: abilities are locked inside (`Systems.Input.LockAbilities`).
  A dash back in was not tested (headless clients can't aim); the teleport case covers being moved out.

## Walls: how Aug 2022 showed the bases (17 Oct, night)

The user after `deploy-2026-10-17-2043`: "theres no visuals about the base. in the old version like a wall spawned you
couldnt get into". The blockers worked (no way back in), but nothing showed where the border was.

**What Aug had** (Aug 2022 build; the maps' exports in `work/shard/maps-aug/`, attach chains resolved):
- **The blocker class shows nothing.** `BP_SpawnBlocker`'s root mesh (`/Engine/BasicShapes/Sphere`, scale 5) has
  `OverrideMaterials[0] = M_InvisbleCursor_Decal` (an invisible material), in Aug and Feb alike. Feb added a
  `SpawnTrapperCylinder` (hidden, no collision).
- **Per map instance:**
  - Embersong's two blockers clear that material (`OverrideMaterials[0] = None`) but set `bVisible = false`
    (`CastShadow = false`): hidden.
  - Stormheart's and Crownwatch's clear it too and stay visible, with their mesh `SM_Sphere`
    (`/Game/VFX_Packs/Stylized_VFX_StPack/Meshes/SM_Sphere`, radius 100), whose own material is `M_SphereHit` (masked,
    unlit). In the game only a thin white rim of the sphere shows: a ring that outlines the blocker.
- **A wall of fire across each exit**: two auto-active `NiagaraActor`s per map, never touched by any code (the level
  scripts only play music; `BP_AC_SpawnBlocker`'s `BlockSpawn`/`BlockSpawnServer` only set the capsule's channel 25 and
  take the protection off: no mesh, material or effect for anyone):
  - Embersong: `NS_PhoenixGate` (`/Game/HiddenLeafVFX/ObjectVFX/NewGardenMap/Gate/`, gate meshes `SM_PhoenixGate_*`,
    Astrada phoenix materials) at (-101, 3475, 0) yaw 180 and (2, -3491, -17) yaw 1.5, scale 1.
  - Stormheart: `NS_PheonixWall` (`/Game/HiddenLeafVFX/ObjectVFX/GardenMap/Base/`), attached to the bases' floor planes:
    world (-151.2, 4063.7, 67) yaw 180 and (-151, -4139, 67) yaw 0, scale (1.3125, 1, 1).
  - Crownwatch: `NS_PheonixWall` (`/Game/HiddenLeafVFX/ObjectVFX/Base/`), attached to the base meshes: world (-1397.3,
    3119.2, 66) yaw -124 scale 1 and (-1668.6, -3120.4, 87.8) yaw -42.66 scale (1.4375, 1, 1).
  - `NS_PheonixWall`'s mesh (`M_MagicFire_v3`, read from the cooked vertex buffer) is a half ring of fire: radius ~456,
    280 high, its centre 376 behind the system's origin. On Stormheart Aug scaled it to the blocker's width
    (456 × 1.3125 ≈ 601); the ring's front sits 70 inside the blocker's front.

**What Feb 2023 has instead:** none of those actors. `NS_PhoenixGate` and its meshes and materials, and the GardenMap
copy of `NS_PheonixWall`, are gone from the pak; `Base/NS_PheonixWall` (same mesh, byte for byte) and `M_SphereHit` are
still there. Feb placed a "baseline" per base instead (`NS_Garden_Baseline`, `NS_Dragon_Baseline`,
`NS_Payload03_Baseline`, made from the gate's wave materials): a thin red line on the ground that pulses, at the Aug
gate's place on Embersong and ~170 outside the blockers' front elsewhere (it marked the turret's zone). Screenshots of
the before runs (`walls-e0`, `walls-s0`, `walls-c0`) show only that line.

**What we do** (`blockers.lua`, both mods; on players' machines only, the game server renders nothing):
- **Rings (`SPHERES`):** every placed blocker gets `M_SphereHit` (`StaticMeshComponent:SetMaterial(0, …)`): the white
  ring outlining the blocker, as Aug showed it on Stormheart and Crownwatch. Embersong's blockers (the engine sphere) get it too:
  its own marker, the gate, no longer exists. Materials don't change collision.
- **Fire walls (`WALLS`):** a `NiagaraActor` per base (spawned, so the level keeps it and its effect alive all match)
  with `Base/NS_PheonixWall`, its `Asset` set before the spawn finishes so it starts by itself.
  - Stormheart and Crownwatch: the Aug transforms above. Stormheart's Aug system (the GardenMap copy) is gone; the
    Base copy is the same mesh and material name.
  - Embersong: the gate is gone; the closest Feb asset is the same fire ring, centred on the blocker and scaled to its
    radius (840 / 456 = 1.842 in X and Y, 1 in Z): origin (0, ±3527.5), yaw 180 / 0, so it runs along the border.
- Feb's red baselines stay: they sit at or just outside the border and don't contradict it.
- Off switches: `WALLS = false`, `SPHERES = false` (both `blockers.lua`); `ENABLED = false` takes everything off.
- The first try (`walls-e2`) checked for the server with `KismetSystemLibrary.IsServer` and set the system with
  `SetAsset` after the spawn: both players logged `walls: 0`, then crashed in the test's `walls()` (`GetActorBounds` on
  the `NiagaraActor`s); which call failed wasn't pinned down. Now: `HasAuthority()` on the game state (only the
  server's has it), `Asset` set before `FinishSpawningActor` (the component starts by itself), a failure logs
  `base walls: …` and destroys the actor, and `walls()` reads properties only. Since then every run placed 2 walls on
  each player.

## No base laser (17 Oct, night)

The user: "no laser: since you cant re-enter base its not needed. the laser that deals dmg". That is `BP_Turret_C`
(`/Game/Environment/MapAssets/Assault/BP_Turret`), two per arena map, added by Feb when it removed the blockers
(Aug has none). Only Embersong, Stormheart and Crownwatch place it (no other Feb map).

**What it is** (Feb 2023): a replicated `MOBABaseActor` (Team, Target and IsAttacking replicated), immune to all
damage. It shoots the nearest enemy hero within `AttackRange` 1175 (2D, from its `AttackRangeCapsule`) with
`BP_GE_Damage_DOT_Turret` (150 + 5 % of max health a second, `DamagePerSec` 100 on Crownwatch), a laser effect and
sound; its `BuffRangeCapsule` gives its own team `Effect.Map.FriendlyTurret` buffs (heal 60/s, armour); it gives its
team vision (`BP_AC_VisibilityHandling`, `SightRange` 1750); a kill by it shows in the kill feed.

**What else uses it** (Feb Blueprints): `BP_Task_FindBases` (an AI behaviour-tree task: the bots' blackboard gets the
bases' locations from the turrets; without them those keys stay unset; bots only exist in our server-performance tests,
players have no AI mode), `BP_CTFlag` (capture the flag, not on these maps), `IsDamagableActor` and Rose's ult
(`BP_GA_DemonGirl_R`; both only skip turrets as targets). No game rule, round flow, Shard or `BP_BuffActor` rule state
refers to it; `shards.lua` only says turrets stay.

**The patch** `base-turrets` (`tools/patch/patches/base-turrets.json`): `insert-code` at the start of
`BP_Turret.ReceiveBeginPlay`: `SetActorHiddenInGame(true)`, `SetActorEnableCollision(false)`,
`SetActorTickEnabled(false)`, `K2_DestroyActor()`.
- On the game server the turret destroys itself at the map's start; the engine tells every player's game to remove its
  copy (a destroyed level actor), also players who join later.
- On a player's machine `K2_DestroyActor` does nothing (not the authority), but the first three calls already hide it,
  take its collision and stop it ticking, before the server's word arrives.
- With it go the base heal/armour buff for the own team and the turret's vision of the base (Aug had neither).
- The decompile of the patched function reads exactly those four calls, then the original `ExecuteUbergraph` call.
- `AssetPatch rewrite-check` on the whole Feb `MOBA/Content` (18 Oct): 1,779 assets, 20,486 functions, 0 failed.
- Off switch: `"enabled": false` in `base-turrets.json`.

## Tests of the walls and the laser (17-18 Oct)

`tools/run/test_walls.steps` through `tools/run/test_base.sh` (`STEPS=`, `MAP=`), Feb 2023 build, Rowan (alice, team
A) and Astrada (bob, team B). After the round starts each hero walks out to 300 beyond its blocker
(`edge`), each player's mouse pointer is put towards its base (`aim`: the camera leads towards the pointer) and both
take screenshots, then again after walking back (stopped at the border). Then bob stands in alice's turret's range
outside both bases for 8 s (`lane`) and on the turret's own spot for 6 s (`at`); `turrets()` and `walls()` list what is
there on the game server and on both players. Screenshots: `work/logs/<run>-shots/` (local).

| Map | Before (`PATCHES=base-blockers`) | After (`base-blockers base-turrets`, walls and rings on) |
|---|---|---|
| Embersong | `walls-e0`: no wall; Feb's red line pulses on the ground at the border. 2 turrets on the server and both players; bob in the range: 850 → 0, dead within 8 s | `walls-e5`: white ring and fire ring on both players' screens (2 walls, 2 blockers shown each, `active=true`); 0 turrets on the server and both players; bob 850 → 850 in the range and on the turret's spot |
| Stormheart | `walls-s0`: red line only; turrets kill bob (850 → 0) | `walls-s2`: ring and Aug fire wall on both players; 0 turrets everywhere; no damage |
| Crownwatch | `walls-c0`: red line only; turrets kill bob (850 → 0) | `walls-c1`: ring and Aug fire wall on both players; 0 turrets everywhere; no damage |

- Collision is unchanged: walking back stops at the same distance from the blocker's centre before and after (842 on
  Embersong, 771 / 789 on Stormheart, 873 / 888 on Crownwatch); the game server places no walls and shows no blockers
  (`walls: 0, blockers shown: 0`).
- The players' copies of the turrets are gone too (`turrets: 0` on both clients), so nothing of them is left to
  collide with or to draw.
- Screenshots, for instance: `walls-e5-shots/bob-ScreenShot00000.png` (Embersong, bob just outside his base: white
  ring, fire ring along the steps, Feb's red line), `walls-s2-shots/bob-ScreenShot00000.png` (Stormheart),
  `walls-c1-shots/alice-ScreenShot00002.png` (Crownwatch, alice stopped at the ring); before:
  `walls-e0-shots/bob-ScreenShot00000.png`, `walls-s0-shots/bob-ScreenShot00001.png`,
  `walls-c0-shots/alice-ScreenShot00000.png`.
- Runs that went wrong: `walls-e1` stuck in the lobby (the known flake). `walls-s1`, `walls-e4` and `base-c5` each lost
  one client 13-14 s after it started, in the main menu, right after FangsBoot logged `patch notes: tab added` (the
  same call stack each time, inside Blueprint code): that is the live PATCH NOTES tab, not this change, and none of
  this code runs before the arena; 43 other client starts in the worktrees' runs got past that point. Open: worth a
  look, players could hit it. `walls-e2` and the first `walls-e0` crashed in the test's own `walls()` (fixed: it reads `NiagaraActor` properties only); `walls-e3` had Embersong's wall at the gate's
  place, scale 1 (a short flame inside the border; now sized to the blocker). In `walls-s2` bob fell off the map 5 s
  after being put on Stormheart's turret spot (no floor there at his height), unhurt until then.
- The tests' deaths: with `base-turrets` there is no turret to die at. Through Lua neither a damage spec
  (`MakeDamageEffectSpec` + `ApplyEffectSpecToTarget`: no damage, most likely the spec handle doesn't survive UE4SS)
  nor health 0 plus `HandleDeath` gave a real death (`walls-e3`, `walls-c1`, `walls-s2`), so `test_base.steps` (its
  death step), `test_passives` and `test_shards` (turret deaths) run without `base-turrets`, as their defaults do.
