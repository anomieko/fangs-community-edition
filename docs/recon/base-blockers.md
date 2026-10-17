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
found the bugs above; `base-all` (every live patch with this one, old placement) passed the same cases as `base-e`.
Pending (they wait while the user plays): `base-all3`, every live patch with the final code (`base-all2` never reached
the arena: the lock-in found no lobby controller, before any blocker code ran), and `base-ctl2`, the control again for
the safety net's empty-list guard.

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
| Safety net releases | 0 (only the control's) | 0 | 0 |

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
  spawn, protected. Whether abilities should work inside the base during the augment phase is a question for a community member.
- **Dashes out of the base** can't happen during a round: abilities are locked inside (`Systems.Input.LockAbilities`).
  A dash back in was not tested (headless clients can't aim); the teleport case covers being moved out.
