# Community patch, part 3: Ethryn's shield, Lamblaster, Stormlense (built 16-17 Oct); Zoey's ult, Astrada's cage (not yet)

The code-level hero fixes Sheepa OK'd (`docs/recon/community-patchnotes.md`, proposal Q-cards Ethryn, Rayo, Zoey,
Astrada). Patch `tools/patch/patches/community-heroes.json` (`"enabled": false`), branch `cp-heroes` (on top of
`fiorne-restore`). It builds together with `ccrevert` and `fiorne` (`tools/patch/build.sh <game> ccrevert fiorne
community-heroes`, 2.2 MB pak).

Tests, all headless, each with a control run without the pak (`PATCHES=none`), each under the shared test lock:
- `tools/run/test_vfx.sh` (MODE `zoey`, `astrada`, `shield`): an effects lab, a solo match where FangsCtl spawns Niagara
  systems next to the hero and takes screenshots (`work/logs/vfx-<run>/`).
- `tools/run/test_shield.sh` (MODE `boulder`, `lamblaster`, `cage`, `stormlense`): `test_patch.sh` with extra steps.
  Both heroes are moved to the middle of the map first (`S.stage`: the bases' lasers kill enemies; the first runs
  lost their heroes that way), healed and refilled. The server logs every reflect and tracks the projectile every
  20 ms relative to the shield (`shield.log`).

## Rayo: Stormlense Scope

- **Before** (`BP_GA_LightningArcher_E_`, `Range Damage Amp Calculate Damage`, r = distance / range): no bonus below
  r = 1/3, then damage × (1 + r), then × 1.85 (`EagleEyeMaxDamageMultiplier`) from r = 0.85.
- **After**: damage × (1 + 0.5 r) from r = 0, × 1.5 from r = 1 (Sheepa: "from 0 % at the start, rising to +50 % at
  max range"). Edits:
  - the 1/3 threshold → 0 (`set-call-arg`);
  - `Add_FloatFloat(r, 1.0)` → `Add_FloatFloat(Multiply_FloatFloat(r, 0.5), 1.0)` (new `wrap-call-arg`);
  - the 0.85 cut-off → 1.0;
  - `EagleEyeMaxDamageMultiplier` 1.85 → 1.5.
- The tooltip computes `$EagleEyeMaxDamageMultiplier-1%100$` %, so it says 50 %.
- The decompile of the patched function reads exactly that, and its one jump moved by 15 bytes.
- In a match: see "Results".

## Ethryn: Stalwart Aegis (E)

The shield is a target actor, `BP_TA_ShieldGirl_Skill4`. Its box `wer` is extent (5, 240, 162), 109 in front of her.
That box decides three things:
- the reflect, through the native overlap that calls `OnProjectileOverlap`;
- the melee block (`OnAOEImpact`);
- the push on enemies walking through (`KnockbackTick`, an AOE box query with `self.wer.BoxExtent`).

Edits:
- **Reflect zone as wide as her body:** `wer` `BoxExtent.Y` 240 → 85 (`set-export-prop`). The melee block narrows with
  it, since it uses the same collision.
- **The push keeps today's size:** `KnockbackTick`'s query gets the literal extent (5, 240.06, 161.81) instead of
  `self.wer.BoxExtent` (new `replace-call-arg`).
- **The look is 15 % narrower and 10 % lower:** after `SpawnSystemAttached`, `SetRelativeScale3D(1, 0.85, 0.9)` on the
  spawned shield effect (new `insert-code`; adds the `/Script/Engine.SceneComponent:SetRelativeScale3D` import).
  Measured in the lab, the raised shield's yellow arc on screen is 208/199 px with the pak against 227/219 px
  without: about 9 % smaller from the game's slanted camera.

Found on the way: a reflected projectile is always finished at the shield actor's own transform
(`FinishSpawningDeferredProjectile(clone, GetTransform(), …)`). So it starts at Ethryn's position and flies along her
facing. The `radius + 50` offset computed for `CloneDeferred` is overwritten: every logged copy started 109 behind the
plate, with and without the pak.

## Belroth's boulder vs the shield

- **Measured** (`MODE=boulder`, track every 20 ms): the shield reflects the boulder when its centre is about 255 to
  the side of the narrowed plate (85 + 170). So the trigger is the boulder's big hit sphere `ProjectileSphereCollision`
  (radius 170), not the 60-unit interaction sphere. Its responses overlap `PhysicsBody`, the shield box's object type.
  That's "reflects it long before it reaches her".
- **Edit:** on `BP_MOBA_BigBoi_Skill4_Projectile_2`, the big sphere's `PhysicsBody` response Overlap → Ignore
  (`set-export-prop`). The shield then reacts to the interaction sphere (radius 60). The boulder still hits heroes with
  its full size (Pawn overlap unchanged), as Sheepa asked. Other `PhysicsBody` ability objects (e.g. Tufts' pull,
  which Sheepa mentioned) also stop reacting to the big sphere.
- In a match: see "Results".

## Wylde's Lamblaster reflected

- **Cause** (code): Lamblaster spawns its pellets through `BP_ConeProjectileBase`. When a pellet hits someone, the
  cone adds that character to every pellet's `IgnoreCharacters`, so a target is hit once. Ethryn's shield clones each
  pellet (`CloneDeferred`, a new actor outside the cone and its delegates), so every reflected pellet hits Wylde in full.
- **Edit** (`insert-code`, ubergraph of the shield actor, no new variables):
  - before each clone, the previous clone (`CallFunc_CloneDeferred_ReturnValue`, a persistent frame variable, `None`
    at first) is kept in `CallFunc_Array_Get_Item` (an Actor local the reflect path doesn't use);
  - after it, if both the incoming projectile's and the previous clone's object names contain
    `Gunslinger_Skill4_Projectile`, the new clone gets `bShouldApplyEffects = false`.
  - So per shield raise, the first reflected pellet keeps its damage (one normal Lamblaster hit) and the rest of the
    burst none. Wylde can't cast Lamblaster twice in one raise.
  - The imports `KismetStringLibrary:Contains` and `KismetSystemLibrary:GetObjectName` are added (`/Script` only).
- In a match: see "Results".

## Astrada: Flame Cage colours

- **Cause** (code): `SetCageColor` spawns the cage through `Generic Spawn System Attached` with `UseVFXPackColor`. The
  pack's colour counts as "set" unless it is (0, 0, 0, 0). `DA_VFXPack_AstradaDefault` stores (0, 0, 0, 1) for the
  ally/default and enemy slots, so the game sets the effect's `Color` to black on both cages.
- **Edit:**
  - `Skill2VFX[0].DefaultVFX.ColorOptions.Color` (her own and teammates' cages: the Caster and Ally slots are empty,
    so Default is used) = (15, 6.5, 0.4) yellow-orange;
  - `EnemyVFX` = (15, 0.35, 0.1) red. HDR values, like the cage actor's old unused defaults.
- **Not in the patch.** Screenshots (`MODE=cage`, Astrada's own view, with and without the pak) show the colour reaches
  only part of the effect: the cage's opening ring turns yellow-orange, but the burning ring stays purple-blue. That
  colour is the systems' other parameter, `User.CircleColor`, which the game never sets per team. The enemy's view
  couldn't be captured: the test's opening moves leave bob in Astrada's base, where the base laser kills him.
- **Next:**
  - set `CircleColor` per team too, by calling `Get Niagara VFX with Tag Based on Team` in `SetCageColor` after the
    spawn (`insert-code` can't call Blueprint library functions with out parameters yet);
  - a test where both clients are alive to compare both views.

## Zoey: ult effect invisible on Hellhound skins

Not reproduced, no fix in the patch.
- **Checked statically:**
  - the Hellhound skins' IDs match `DT_VFXPacks` rows (Red, Blue, Green, Purple, White, Rainbow), all to
    `DA_VFXPack_Hellhound_CatSupp`;
  - its `Skill3AOEVFX` slot is `NS_Hellhound_CatSupp_Skill3_ULT`;
  - all 24 packages that system references are in the pak;
  - neither pack stores a colour for that slot.
- **Lab:**
  - spawned directly, both ult systems render (default purple, Hellhound an orange star with rings);
  - with the Hellhound pack set on the client (`Load VFXPack`), the pawn's pack is the Hellhound one.
  - Zoey's real ult couldn't be watched in the solo lab: from her base, Boo stops at the base's edge, and no landing
    burst shows for the default skin either.
- **Next:** a 2-player match with a Hellhound skin on one client, ult cast mid-map.

## New AssetPatch edits (docs/PATCHING.md)

`wrap-call-arg`, `replace-call-arg`, `rename-prop-ref` (used for a while, then dropped: see the reflected-copy
finding), and `insert-code`: new statements from a JSON form, with engine function imports added when missing.
`AssetPatch rewrite-check` on all Feb Blueprints: still 1,779 assets, 20,486 functions, 0 failed.

## Results (17 Oct, headless, each against a control without the pak)

| Test | With the pak | Without |
|---|---|---|
| Stormlense, damage left from 100 at r = 0 / 0.2 / 0.33 / 0.5 / 0.8 / 0.95 / 1 / 1.2 (`MODE=stormlense`: the server runs the function on Rayo's own ability) | 100 / 110 / 116.7 / 125 / 140 / 147.5 / 150 / 150 | 100 / 100 / 100 / 150 / 180 / 185 / 185 / 185 |
| Boulder vs shield, last tracked boulder centre in front of the plate before the reflect (`MODE=boulder`, 20 ms samples, ~80 units apart) | 94: reflected within ~65 of the plate (the 60 sphere) | 195: reflected between 195 and ~115 (the 170 sphere) |
| Lamblaster into the shield (`MODE=lamblaster`) | 8 pellets reflected, only the first keeps its effects; Wylde 850 → 800 | 12 pellets reflected, all with effects; Wylde 850 → 250 |
| Shield look (`test_vfx.sh MODE=shield`, raised shield's yellow arc on screen) | 208 / 199 px | 227 / 219 px |
| Astrada's own cage (`MODE=cage`) | opening ring yellow-orange, burning ring purple-blue | white-purple, purple-blue |

In every pak run the patched class defaults loaded on both clients and the server (51/52; the 52nd is Fiorne's nested
health value, which `check()` can't read). One end-of-match server check found `BP_GA_Lancer_Skill4.Projectile Speed`
at 180 instead of the patched value, changed at runtime: a question for the `fiorne` patch, not this one. A match can't show how the changes feel,
nor Ethryn's narrower reflect against shots passing beside her (no test for that).

Test harness notes: `test_patch.sh`'s opening casts put the heroes next to each other in the caster's base, so a
second hero can die to the base laser before the steps run (`S.stage` moves both to mid-map and heals them, but
can't revive). Steering aim with `SetMouseLocation` works for the hero's facing; alice's own aim stays her pointer.
