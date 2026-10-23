# Community patch, part 3: Ethryn's shield, Lamblaster, Stormlense (built 16-17 Oct), Zoey's ult and Astrada's cage (17 Oct)

The code-level hero fixes a community member OK'd (`docs/recon/community-patchnotes.md`, proposal Q-cards Ethryn, Rayo, Zoey,
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
- **After**: damage × (1 + 0.5 r) from r = 0, × 1.5 from r = 1 (a community member: "from 0 % at the start, rising to +50 % at
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
  its full size (Pawn overlap unchanged), as a community member asked. Other `PhysicsBody` ability objects (e.g. Tufts' pull,
  which a community member mentioned) also stop reacting to the big sphere.
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

## Astrada: Flame Cage colours (built 17 Oct, branch `cp2-astrada`)

- **Which effect** (code and matches): the cage picks its effect per viewer from `DA_VFXPack_AstradaDefault`
  (`Get Team Filtered Niagara From Team Structure`): `NS_Astrada_Shift_System_Ally` for Astrada and her teammates (the
  pack's Caster and Ally slots are empty, so its Default), `NS_Astrada_Shift_System_Enemy` for her enemies. Seen in
  matches: Astrada's client spawns the first, the enemy's the second.
- **Cause** (assets): `SetCageColor` then sets the effect's `Color` from the pack, but no emitter reads it. Both systems
  expose `User.Color` and `User.CircleColor`, and no emitter script lists either among its parameters
  (`AssetPatch props <asset> <script>`: each script's `SortedParameterOffsets`). Each emitter's colour is a curve
  baked into the asset. The ally system mixes yellow and orange with blue and purple: two waves magenta and
  blue-violet (`NE_MidBright_Slash_A003`, `A004`), a blue torus (`NE_MidBright_Slash_A`), a blue flash
  (`NE_FlashStar001`); the orange wave and the swords fade to blue and purple. The enemy system is the same effect
  plus a red-orange floor disc (`NE_AOE`), with a red flash and an orange torus instead of the blue ones. So both cages
  looked alike, yellow-orange with purple.
- The first try (pack colours, then `CircleColor` defaults) changed nothing on screen; a match that set both
  parameters to green (Astrada's client) at runtime showed no green (`cage-p3`).
- **Edit** (`recolor-curve`, a new AssetPatch edit: a curve's baked table gets one new hue and keeps its fade):
  - ally system: the blue and purple parts orange and yellow; the orange wave and the swords keep their colour to the
    end (8 emitters);
  - enemy system: all red: ring, waves, flashes, swords, embers, flames (21 emitters). `NE_AOE`'s disc keeps its
    colour (a value in its script's bytecode, already red-orange).
  - Each emitter keeps three copies of each curve (spawn script, update script twice); all three are edited.
- **Tested** (17 Oct, the steps now in `tools/run/test_cage.steps`, run by `tools/run/test_shield.sh MODE=cage`: both
  heroes mid-map, one cast on bob, screenshots from both clients at +0.6, +1.3, +2.0 s; `cage-v1` with the pak,
  `cage-p3` without): Astrada's own view yellow-orange throughout (was a purple-blue ring from +1.3 s; a faint blue
  fringe stays at the ring's lower edge), the enemy's view red, swords and flames included (was orange with purple).
  A teammate's view uses the same system as Astrada's own (pack code), not seen with a third client.

## Zoey: ult effect invisible to the Zoey player (every skin; fixed 17 Oct, branch `cp2-zoey`)

The report was "Zoey's ult effect is missing on Hellhound skins". In a 2-player match (Feb build,
`tools/run/test_shield.sh MODE=zoey`, alice's Zoey in mid-map, ult cast twice at bob) the landing burst
(`GameplayCue.CatSupp.Skill3.CastVFX`, which spawns the pack's `Skill3AOEVFX`) was missing **only on Zoey's own
screen**, on the Hellhound skin and on the default skin alike. Bob saw it every time. Live Niagara systems on each
client about 1 and 2 s after each cast (`S.vfx`; the cast effect itself showed on both):

| Run | alice (Zoey) | bob |
|---|---|---|
| Hellhound Red, no fix (`zoey-hh`) | cast effect only, 0 `…Skill3_ULT` | `NS_Hellhound_CatSupp_Skill3_ULT` x1 |
| Default, no fix (`zoey-def2`) | cast effect only, 0 `…Skill3_ULT` | `NS_CatSupp_Skill3_ULT` x1 |
| Hellhound Red, with the fix (`zoey-hh-fix`) | `NS_Hellhound_CatSupp_Skill3_ULT` x1 | x1 (no doubles) |
| Default, with the fix (`zoey-def-fix`) | `NS_CatSupp_Skill3_ULT` x1 | x1 |

Screenshots: `work/logs/zoey-{hh,def2,hh-fix,def-fix}-{alice,bob}-shots/` (ScreenShot00000-00002 at 0.5 / 1.0 / 1.7 s
after the first cast, 00003-00005 after the second), and alice's ScreenShot00002 without and with the fix side by side
in `work/logs/zoey-before-after.png`; local only, as all of `work/`.

**Cause.** `BP_GA_CatSupp_Skill3` waits in `WaitNetSync` with type 2 (OnlyClientWait) before it plays the landing cue
(`ListenForTotoLand` → `Play Cast VFX` → `K2_ExecuteGameplayCueWithParams`). The server doesn't wait: it runs the cue
inside the activation's prediction window and multicasts it with Zoey's prediction key, so Zoey's own client skips it
(GAS assumes she predicted it). Her client resumes after the sync without a prediction key and doesn't run the cue
either. The skin plays no part; Hellhound players probably noticed because the Hellhound burst is the larger one.

**Fix** (`community-heroes.json`, first entry): after that cue call, `if (Player.IsLocallyControlled())
GetAbilitySystemComponent(Player).ExecuteGameplayCueLocal(<same tag>, <same parameters>)`. Only the Zoey player's
machine runs it; the server and the other players don't (the server's Zoey isn't locally controlled). It needed two
new `insert-code` options: `anchor-match` (pick the one cue call with that tag, as the graph has several) and
`{"anchor-arg": i}` (copy the anchor call's argument). The pack choice stays the game's
(`Generic Spawn System At Location` takes the instigator's pack), so each skin gets its own effect.
Built with all 8 live patches; `rewrite-check` 0 failed.

A community member's "hit effect on knock-up" isn't a separate effect: the ult's GenericAOE has no hit effect, and knock-ups are
stuns now (`ccrevert`).

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
| Astrada's cage, her view / the enemy's (`cage-v1` / `cage-p3`, one cast mid-map) | yellow-orange / red | yellow ring turning purple-blue / orange with purple |

In every pak run the patched class defaults loaded on both clients and the server (51/52; the 52nd is Fiorne's nested
health value, which `check()` can't read). One end-of-match server check found `BP_GA_Lancer_Skill4.Projectile Speed`
at 180 instead of the patched value, changed at runtime: a question for the `fiorne` patch, not this one. A match can't show how the changes feel,
nor Ethryn's narrower reflect against shots passing beside her (no test for that).

Test harness notes: `test_patch.sh`'s opening casts put the heroes next to each other in the caster's base, so a
second hero can die to the base laser before the steps run (`S.stage` moves both to mid-map and heals them, but
can't revive). Steering aim with `SetMouseLocation` works for the hero's facing; alice's own aim stays her pointer.

## Ethryn nerfs (a community member, 21 Oct)

A community member's list via the user: "Nerf Ethryn: (these are purely number changes …)". All six are plain values, done in
the new patch `tools/patch/patches/community-ethryn.json` (`"enabled": true`, branch `cp4-ethryn`). Off switch: its
`"enabled": false`, or remove one asset's entry. Feb build; values read with `AssetPatch info`/`props`, code from
`work/bp-2023-02-15`. Asset paths under `MOBA/Content/Gameplay/Abilities/Player/ShieldGirl/` unless they start with
another folder.

| Heirloom (item asset) | Who reads it (code) | Edit | Before → after | Tooltip |
|---|---|---|---|---|
| Knight's Prayer Book, LMB (`Items/…/LMB/ITEM_ShieldGirl_LMB_StackingArmor`) | `BP_GA_ShieldGirl_LMB.GrantItemStackingArmor` applies `LMB/BP_GE_ShieldGirl_Item_LMB_ArmorStack` (armor by SetByCaller, 10 per stack, 3 s); the cap is that effect's `StackLimitCount`. The same function plays the "max stacks" book cue when current = max stacks, both read from the effect, so it follows | `set-default` `StackLimitCount` on the effect | 6 → 4 | written into the text: `LOC_EN_AUGMENTS_SHIELDGIRL` `ShieldGirl_StackingArmor_desc` "stacking</> up to 6 times." → "… 4 times." (`replace-text`) |
| Dawncleave, passive (`Items/…/HeroPassive/ITEM_ShieldGirl_DefenseReductionDebuffOnPassive`) | `LMB/BP_GA_Bashed.Apply Debuff on Passive` (on the bashed enemy): `MakeDefenseReductionEffectSpec` with the passive's `ItemBashDamageAmpPerStack` (at max Pummel stacks, max stacks × it) | `set-default` on `Passive/BP_GA_ShieldGirl_P` | `ItemBashDamageAmpPerStack` 0.09 → 0.07 | computed, `$ItemBashDamageAmpPerStack%100$%`: says 7 % |
| Brawler's Aegis, passive (`…/HeroPassive/ITEM_ShieldGirl_DamageOnBashProc`) | `BP_GA_Bashed.ApplyItemBashBonusDamage` (bound to the Pummel stun, `OnBashProc`): a damage spec of the passive's `ItemBashBonusDamage` | `set-default` on `BP_GA_ShieldGirl_P` | `ItemBashBonusDamage` 40 → 30 | computed, `$ItemBashBonusDamage$`: says 30 |
| Oathsworn Mask, passive (`…/HeroPassive/ITEM_ShieldGirl_Passive_PermastackingCDR`) | `BP_GA_ShieldGirl_P.GrantPermaStackingCDRPassiveItem` (called through the character from `BP_GA_Bashed.GrantPermastackingCDRPassive` on each Pummel stun): `FMin(current + ItemPermaStackingCDRIncrement (0.03), ItemPermaStackingCDRMaximum)` into `BP_GE_ShieldGirl_P_Item_PermaCDR` (CooldownReduction, SetByCaller) | `set-default` on `BP_GA_ShieldGirl_P`; twin: `LMB/Cues/BP_GC_ShieldGirl_P_CDRMask.CDRMaskMaxStack` (the mask cue shows its "maxed" effect when her total cooldown reduction is ≥ this) | 0.45 → 0.33, both. Still +3 % per stun, so the cap comes after 11 stuns (was 15) | computed, `$ItemPermaStackingCDRMaximum%100$%`: says 33 % |
| Elysian Warbrew, LMB (`…/LMB/ITEM_ShieldGirl_LMB_CannotIgnoreMe`) | `BP_GA_ShieldGirl_LMB.GrantCurrentHPDamageItem`: damage = her `Health` attribute (current health, not max) × `ItemCurrentHPCoefficient` | `set-default` on `BP_GA_ShieldGirl_LMB` | 0.025 → 0.02 | computed, `$ItemCurrentHPCoefficient%100$%`: says 2 %. The text says "current HP", which is what the code uses; a community member's "max hp" was the wrong word: he confirmed current HP (21 Oct, via the user); the percentage is what changes |
| Matriarch's Halo, Shift (`…/Shift/ITEM_ShieldGirl_Skill2_MissingHPHeal`) | `Skill2/BP_GA_ShieldGirl_Skill2.ItemMissingHPHeal` (post-hit): per hit actor, a heal of (MaxHealth − Health) × `ItemMissingHPHealCoefficient` | `set-default` on `BP_GA_ShieldGirl_Skill2` | 0.12 → 0.10 | computed, `$ItemMissingHPHealCoefficient%100$%`: says 10 % |

Checked on the way:
- No "Modified…" twin and no `ResetAbilityAttributes` copy for any of these values; the item assets (`MOBASkillItem`)
  hold only the tag and texts; the skill data assets (`Skills/ShieldGirl/*/DA_*`) hold no numbers.
- `BP_GA_Bashed` has its own `DamageOnBashProc` = 40, read by no code (Brawler's Aegis reads the passive's value).
  Left as it is.
- Tooltip numbers come from `BP_FL_MOBA_AbilitySystemFunctionLibrary`: `Find Variable` reads the property by name
  from the hero's ability (by slot), `%100` multiplies, and `MakePrettyString` prints a whole number when the value is
  within 0.001 of one (so 0.07 × 100 shows "7", not 7.0000001).
- Earlier builds, for reference: Aug 2022 had Knight's Prayer Book 3 stacks of 20 armor, Elysian Warbrew 3 %,
  Matriarch's Halo 15 %; Dec 2023 has 5 stacks of 6 armor and the Feb values for Dawncleave, Oathsworn Mask and
  Elysian Warbrew.

Test (21 Oct, headless, under the shared lock): `tools/patch/build.sh clients/fangs-2023-02-15-b10554626` builds with
every enabled patch (13, 7.5 MB). `tools/run/test_patch.sh` with the live set plus `community-ethryn` (`RUN=ethryn`,
`SKIP_CC=1`, `HERO_A=ShieldGirl`): alice (Ethryn), bob and both game servers loaded 93/95 patched class defaults, all
7 of this patch among them; the other 2 are the nested Brutus/Fiorne health values `check()` can't read. Not tested
in a match: the stack cap, the damage, heal and cooldown numbers as they play, and the tooltips on screen (only the
values they compute from).
