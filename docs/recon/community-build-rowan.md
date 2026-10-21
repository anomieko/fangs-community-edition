# Community patch, part 2: Rowan, and CC immunity on dashes (built 16 Oct)

What a community member OK'd (the proposal PDF, cards 3 and 16; `docs/recon/community-patchnotes.md`), as built in
`tools/patch/patches/community-rowan.json` (`"enabled": false`) and FangsBoot. Feb 2023 build. Branch `cp-rowan`.

## What changes (now → after)

| What | Now (Feb) | After | How |
|---|---|---|---|
| Rowan, Dourling Dive (Space) | stun, root, charm or fear stops him | immune to them while dashing (Aug 2022) | `insert-call` `ApplyUnstoppable` at the start of `Lock Pre Dash` (Feb has the function, nothing calls it; `K2_OnEndAbility` already removes its effect) |
| Belroth, Vicious Lunge (Space) | same | immune to roots, stuns, charms, fears and knockbacks while lunging (Aug) | `insert-call` `ApplyUnstoppable` at the start of `MakeCastUIData`, called once just before the lunge's cast, where Aug called it; its two effects last the dash plus the cast and are removed when the ability ends |
| Rush (boon, `BP_GA_Flash`) | a stun or root (anything with `Effect.LockMovement`) cancels the dash | the dash goes on; the stun is there when it ends (Aug) | `set-branch`: the dash payload's `AddGameplayTag(…, Event.Identifiers.CanBeCrowdControlled)` sits behind a constant `if (!true)`; flipped to `false`, so `BP_GA_ServerInitiatedDash` doesn't cancel it. The live path is the server-initiated dash (`if (!false) goto` it); the other path, with the ability's own LockMovement wait, is dead code |
| Dourling Caltrops: where | a box `Dash Extent` long *ahead* of Rowan's end point (`SetForwardLocation`: location + forward × extent/2) | on the path he dashed, behind him | `set-call-arg` `Divide_FloatFloat(self.Dash Extent, 2.0)` → `-2.0` (`SetForwardLocation` is only used by the caltrops) |
| Dourling Caltrops: the "cube" | the box component is drawn (`bHiddenInGame` false) | not drawn | `set-export-prop` `Box_GEN_VARIABLE.bHiddenInGame` |
| Dourling Caltrops: the look | the cue replays Dourling Dive's burst (`VFXPack.Skill1.AOEVFX` = `NS_RowanSpaceAOE`) on Rowan | Iron Thorns (`VFXPack.Skill2.AugmentVFX` = `NS_IronThorns`) at the vines | cue `OnExecute`: `set-name-const` on the tag; `insert-copy` of `BreakGameplayCueParameters` before `GetGroundLocation`, whose location becomes the cue's `Location`; the ability's `MakeGameplayCueParameters` gets `self.ForwardImpactLocation` as `Location` |
| Dourling Caltrops after the recast (Glimmerbranch Hilt) | — | — | nothing to change: every dash end (the first and the recast) raises `Event.EndDash`, whose handler runs `CheckForItemsPostCast` → `Apply Items Post Cast` → `Apply Dourling Caltrops`. Checked in the match test |
| Dourling Caltrops' tooltip ("Wall of Roots [SHIFT]") | | unchanged | a community member: may be his own keybinds |
| Rowan's passive heal on Overgrowth (live 17 Oct, **replaced 21 Oct**: see "21 Oct" below) | proportional to his current missing health, with a strength fixed when he steps on: per 0.25 s, (missing share at step-on × 2 %) × missing health (measured: entered at 530/950, +3.7 HP per tick, 0.88 % of missing). Entered at full health it heals about nothing for that whole stay | 2 % of current missing health plus 3 health per second, every 0.25 s, whatever his health was when he stepped on (Aug) | passive `GetMissingHpValue`: `Multiply(1 − HP/max, rate)` → `Multiply(1.0, rate)` (`set-call-arg`, resized); creep timer `Activate Regenerate Item`: the SetByCaller tag `Data.Heal` → `Data.Heal.MissingMultiple` (the healing execution's fraction of current missing health), and a copy of the `Divide` and of the `AssignTagSetByCallerMagnitude` adds `Data.Heal` = `ModifiedHealPerSecond` (3) ÷ 4 to the same spec |
| Passive tooltip (live 17 Oct, replaced 21 Oct) | "heals for 2% of his missing HP per second" | "… plus 3 HP per second" | `replace-text` `WoodenSword_P_desc` |
| Propagator's charge bar | sits near empty, then jumps when the charge comes | fills at the faster speed (not verified in a match, see below) | FangsBoot (player update), see below |

## Propagator's charge bar

- Propagator (`Items.WoodenSword.P.GainPlants`, item `Item_WoodenSword_P_CreepSourblosom`) runs the creep timer's
  `Reduce CD` every 0.25 s on the game server: remaining time of `Effect.WoodenSword.Skill4.Cooldown` minus 0.25, through
  `MOBAAbilitySystemComponent.SetGameplayEffectDurationHandle`.
- That native (Feb exe, decompiled with `tools/re/decomp.sh`, `FUN_14127d680`) sets the active effect's
  `Spec.Duration` to the new value, its start times to now, marks the item dirty (replicates) and fires the duration
  change. So the timer restarts with the remaining time as its full length. It's the only duration setter the exe has
  (no `ModifyActiveEffectStartTime` UFUNCTION).
- The icon (`WB_AbilityIcon.UpdateStacksProgress`, every 0.05 s, `ChargeType` Cooldown) draws `1 − remaining / total`
  with `MOBAAbilityLibrary.GetEffectRemainingTime`, and total is that shrinking length: the bar stays near 0 and jumps
  when the charge comes. The client was told; the bar's formula breaks with a restarted timer.
- Fix: FangsBoot post-hooks `UpdateStacksProgress`. For an icon whose stack effect is
  `Effect.WoodenSword.Skill4.Cooldown`, it redraws the bar against the length the timer had when it started (a new
  timer = remaining went up). Other icons are untouched. It logs the game's and its own value (`fangsboot.log`,
  "Propagator bar", the first 40 differences).
- Not done in the pak: drawing against a fixed length for every Cooldown-type icon would need new widget logic, and
  changing Propagator to shift the start time needs a native the game doesn't expose.

## Tests

`tools/run/test_rowan.sh` (`test_patch.sh` with bob as Rowan and alice as Somnia; `test_rowan.pre` equips Dourling
Caltrops, Glimmerbranch Hilt, Propagator and Rush before the round; `test_rowan.steps` runs the checks), with the pak
(`ccrevert fiorne community-rowan`) and without it (`PATCHES=none`, the control). Belroth: `test_patch.sh` with
`HERO_B=BigBoi CAST_B=BigBoi_Skill1`. Runs of 16-17 Oct, one test at a time through a shared lock.

| What | Control (Feb) | Patched |
|---|---|---|
| Patched values loaded on both clients and the server | – | 50/51 (the 51st, Fiorne's nested HP value, `check()` can't read) |
| Rowan, Dourling Dive: effects on Rowan while dashing | ability lock only | ability lock + ANTI-CC (`BP_GE_AntiDisplacement_Duration`) until the dash ends |
| Belroth, Vicious Lunge: effects on Belroth | ability lock only | ANTI-ROOT + ANTI-CC+DISPLACEMENT for the lunge, then the ability lock |
| Dourling Caltrops after a dash: box from Rowan along his facing, drawn? | +359 / +372 (ahead), drawn | −357 / −416 (on the path behind him), hidden |
| Rowan's passive on a Sourblossom ring, shot down to 530/950 by alice first (health every 0.25 s, 6 s) | +3.7 HP per tick at 420 missing, falling with missing health (+3.0 at 340): 0.88 % of missing per tick | +2.8 at 420 missing, +2.5 at 355: 0.5 % of missing + 0.75 per tick, the 2 %/s + 3 HP/s of the patch |
| Rush hit by a stun (held 1 s) once the dash is under way (bob's speed every 50 ms) | stun 0.43 s in: one sample at 3000, then 0 (the dash stops) | stun 0.13 s in: 3000 for the rest of the dash (0.12-0.40 s), then 0; the stun was there |
| Dourling Caltrops after the Glimmerbranch recast | one box in all runs: the recast didn't fire in the test (key presses through `BP_AC_InputManager.QueueInput(3)` 0.7 s apart) | same |

Test lessons, kept in the helpers:
- A health value written into the attribute set isn't seen by the game's heal code (the heal effect ticks, health
  stays put): damage has to come from a real hit (`chain` alice's LMB at bob).
- A gameplay effect spec made by a library call from Lua and applied from Lua arrives empty (no stun, no damage).
  `DoTargetKnockUp` (makes and applies inside) works, and so does applying an effect class directly
  (`BP_ApplyGameplayEffectToSelf`, used for a held stun).
- A knock-up launches the target, which ends any dash in either build: it can't test Rush. A held stun (the stun effect
  applied without a duration, removed by the test) can.
- Both heroes start near alice's base, whose defence kills bob: the shots and Rush run in the middle of the map
  (`moveto`).

## Not changed / notes

- **"Stops healing for the rest of the game" is not the round-start pattern** (Wylde's 0 ammo, Fiorne's 0 Bunny Stacks:
  abilities set up only at round start). Rowan's passive has no round-start setup (`OnRoundStart` only calls its
  parent). The Overgrowth actors apply the creep effect each time he steps on, and the creep timer is granted and
  activated by that effect. Nothing there can be missed for a whole game. What matches "stops healing" instead: in Feb
  the heal's strength is fixed when he steps on Overgrowth (the missing share of his health at that moment). Stepping on
  at full health gives a heal of about nothing for that stay, even after he takes damage, until he steps off and on
  again. The patch's heal doesn't depend on that moment. Also, Earth Rend's arc heal drops when Rowan leaves one arc
  while standing in another (`Remove Periodic Effects` removes every arc heal by tag) until he re-enters.
- **Correction to `docs/recon/community-patchnotes.md` (stream 4):** the Feb passive heal is not ≈ 0. The match shows
  it heals; it is proportional to his current missing health. Our reading of `Data.Heal` as a flat amount was wrong for
  this case.
- **Balance note (17 Oct; superseded 21 Oct):** the Aug rule (2 %/s + 3 HP/s) heals less than Feb's when Rowan steps on
  badly hurt (entered at 56 %: Feb ~14.8 HP/s, patched ~11.4 HP/s at that moment) and more when he steps on healthy or
  takes damage while standing there (Feb ~0 if entered at full health). a community member asked for the Aug rule, then found it
  heals too little (21 Oct): see below.
- **Propagator's bar fix is not verified in a match:** the hook runs on the Sourblossom icon (`fangsboot.log`) and
  reads the timer, but the test produced no Propagator-shortened timer to compare (no difference logged). Check it in
  play.
- **Glimmerbranch recast:** not exercised by the test (the second Space press didn't recast); by the code, every dash end
  places the vines.
- Earth Rend's arc and the ult's overgrowth weren't reached in the test (teleporting Rowan onto the arc actor's
  origin, or ahead of it, didn't overlap its cone; the ult's overgrowth actor wasn't found in time). Solved 21 Oct:
  `R.into` in `tools/run/test_rowan.lua` puts him where the collision itself overlaps him (its bounds centre).

## 21 Oct: the heal amount, and a Sourblossom losing the passive (a community member's two requests)

Branch `cp4-rowan`. Feb 2023 build. a community member, through the user:
1. "rowan passive heal numbers are much lower than it used to be after the previous patch you did. [...] from 90hp a
   plant with the +82.5% passive heal only heals him to 460 hp over 13s. it used to heal him to ~650 without augment
   from 90hp over the plant duration, and with the +82.5% passive aug to about 800. please revert this shadow nerf, but
   also fix the tooltip to the actual healing amount."
2. "when using M2 or Ult with the "bloomblade" augment on top of a plant overgrowth aoe, the plant stops healing
   through passive as soon as the M2 or Ult overgrowth area duration ends. stepping outside of the plant area and
   re-entering it does cause the plant to heal again. this bug does not occur when another plant dies [...]"

### How the passive heals (read from the Blueprints and the exe)

- **Stepping on Overgrowth** (a Sourblossom's ring, an Earth Rend arc, the ult's Overgrowth with The Bloomblade): the
  source applies `BP_GE_WoodenSword_Skill4_Creep` built by the passive's `MakeCreepEffect`, with SetByCaller
  `Data.Heal.MissingMultiple` = `GetMissingHpValue` = (1 − HP/MaxHP) × `ModifiedMissingHealthHPS` / 100, computed once,
  at that moment. `ModifiedMissingHealthHPS` = `MissingHealthHPS` (2.0), or × `ItemRegenMultiplier` (1.65) with Heal
  Sprite (`Items.WoodenSword.P.Regenerate`, `SetupRegenAugment`).
- The effect grants `BP_GA_WoodenSword_CreepTimer`. An ability granted by an effect carries the effect's SetByCallers,
  and `MakeOutgoingGameplayEffectSpec` copies them into every spec the ability makes (stock UE 4.26). So the heal over
  time it applies (`BP_GE_DotHealFourPerSec`: every 0.25 s, 3600 s) carries that `Data.Heal.MissingMultiple`, plus its
  own `Data.Heal` = the same number ÷ `HealTickFrequency` (4): a flat 0.002-0.008 HP, nothing.
- **The healing execution** (`MOBAHealingExecutionCalculation`, native; Feb exe, `tools/re/decomp.sh` at
  `0x1412fbf2f`, the code that reads the two tag names): heal = ((MaxHealth − Health) × `Data.Heal.MissingMultiple` +
  `Data.Heal`) × two captured multipliers (heal power; `Effect.Heal.Neutral` sets one to 1), clamped to the missing
  health. `MissingMultiple` is a share of the **current** missing health, **per execution** (per 0.25 s tick).
- **Feb**, per 0.25 s: (share of his health missing when he stepped on) × 2 % × his missing health now. Per second at
  that moment 4 × that: up to 8 % of missing HP (stepping on near 0 HP), 7.2 % from 90/950. Stepping on at full health
  gives about nothing for that whole stay, even after he is hit. The tooltip said "2 % of his missing HP per second"
  (`$MissingHealthHPS$`). Measured 17 Oct (`rowan-ctl5`): entered at 530/950, +3.7 HP per tick at 420 missing = 0.88 %
  = 0.442 × 2 %.
- **Live since `deploy-2026-10-17-1223`** (our 17 Oct `community-rowan.json`): `GetMissingHpValue` = 2 % (no share);
  the creep timer set `Data.Heal.MissingMultiple` = 2 % ÷ 4 = 0.5 % (overriding the copied 2 %) and `Data.Heal` = 3 ÷ 4.
  So 0.5 % of missing per tick + 0.75 HP = 2 %/s + 3 HP/s (Aug's numbers, as chosen in Q25). Measured 17 Oct
  (`rowan-f`): +2.8 per tick at 420 missing.
- **Why it heals less in a community member's case:** from 90 HP Feb heals 1.81 % of missing per tick, ours 0.5 % + 0.75 HP: 62
  vs 20 HP/s at the start, 3× less. Our 17 Oct reading took Feb's "2 %" as per second; Feb's real rate is per tick,
  scaled by the step-on share. Heal Sprite's tooltip also overstates: `$ItemRegenMultiplier*50$` = 82.5 %, the real
  increase is ×1.65 = 65 %.

### a community member's case computed (MaxHP 950, from 90 HP, a tick every 0.25 s)

A Sourblossom's ring heals for about 14.25 s from when he steps in (measured: 56-58 ticks when he stepped in 1.5 s
after the cast; the plant lives `LifeTime` 11 s after its 0.6 s setup, then its death animation).

| Formula | 13 s, no augment | 13 s, Heal Sprite | plant's 14.25 s, no augment | 14.25 s, Heal Sprite |
|---|---|---|---|---|
| a community member (approx.) | | 460 (live) | ~650 (before 17 Oct) | ~800 (before 17 Oct) |
| Feb (before 17 Oct) | 617 | 772 | **646** | **797** |
| live (2 %/s + 3 HP/s) | 322 | 423 | 341 | **448** |
| **new: 1.8 % of missing per tick (7.2 %/s)** | 616 | 771 | **645** | **796** |
| 2 % per tick (8 %/s), considered | 649 | 800 | 678 | 823 |

Feb over the plant's duration gives a community member's numbers (646 / 797 vs ~650 / ~800), and live gives his 460 (448). A
continuous rate matches Feb in this case when it equals Feb's rate at 90 HP: 0.905 × 2 % = 1.81 % per tick. 1.8 %
does it to 1 HP, with and without Heal Sprite (the augment multiplies both the same way).

### The choice: 1.8 % of current missing HP per tick (7.2 %/s), recomputed every tick

- Keeps our 17 Oct fix's good part (the heal doesn't depend on his health when he stepped on) and heals as much as Feb
  in a community member's case. Not the same as Feb elsewhere: stepping on with more health it heals more than Feb (Feb punished
  stepping on healthy), and at nearly full health it heals a little less than live (no flat 3 HP/s):

  | Steps on at | after 14.25 s: Feb / live / new | first second: Feb / live / new (HP/s) |
  |---|---|---|
  | 90 | 646 / 341 / 645 | 62 / 20 / 62 |
  | 300 | 654 / 499 / 719 | 36 / 16 / 47 |
  | 475 | 682 / 630 / 781 | 19 / 13 / 34 |
  | 700 | 765 / 799 / 861 | 5 / 8 / 18 |
  | 900 | 903 / 950 / 932 | 0.2 / 4 / 3.6 |

- How: `community-rowan.json`, passive `BP_GA_WoodenSword_P`: `GetMissingHpValue` → `Multiply(1.0, rate)` (kept from
  17 Oct) and `MissingHealthHPS` 2.0 → 1.8 (`set-default`; Heal Sprite: 1.8 × 1.65 = 2.97 % per tick). The 17 Oct
  creep timer edits (the 0.5 % and the flat 3 HP/s) are gone: the timer is Feb's again, so the heal takes the copied
  rate per tick.
- Tooltip (`WoodenSword_P_desc`): "heals for 2% of his missing HP plus 3 HP per second" (live) → "heals for **7.2%** of
  his missing HP per second" (`$MissingHealthHPS*4$`; `MakePrettyString` prints 7.2). Heal Sprite
  (`WoodenSword_HealSprite_desc`): "increased by 82.5%" → "increased by **65%**" (a literal: the tooltip formulas take
  one operator, `*`, and can't compute (x − 1) × 100).
- Other ways: Feb exactly (remove the passive's entry: the strength fixed at step-on again; the tooltip would then
  give the most, 8 %); a round 8 %/s (remove only the `MissingHealthHPS` edit; the tooltip follows: 678 / 823 in
  a community member's case, +4 %); a flat 3 HP/s on top as on 17 Oct (`Data.Heal` = 3 ÷ 4 on the creep timer's heal: about
  +25 HP over a plant from low health, 3 HP/s near full health).

### A Sourblossom losing the passive under an Earth Rend arc or the ult's Overgrowth (a community member's request 2)

- **Cause (Feb, unpatched: our patches never touched these actors).** When Rowan leaves an Earth Rend arc
  (`BP_TA_WoodenSword_RMB`, its `ConeMesh` end-overlap) or the ult's Overgrowth (`BP_TA_WoodenSword_Skill3Overgrowth`,
  `ReceiveActorEndOverlap`), including when the area ends under him (a destroyed actor ends its overlaps), it runs
  `Check Remove Passive Buff`. Its `Should Remove Passive Buff` keeps the passive only if his capsule overlaps a
  Sourblossom actor (`BP_TA_WoodenSword_Skill4`), an Earth Rend arc or ult Overgrowth. But a Sourblossom's only
  overlapping part is its small body (`PlantTrapCollision`, radius ~96): its ring is not a collision. The plant tests
  the ring by distance on its `Creep Growth` timer (every 0.1 s: within 2 × `CurrentCreepRadius` + 3 × his capsule
  radius). So standing in the ring, not on the plant, the area takes the passive away (`RemoveActiveEffectsWithTags
  Effect.WoodenSword.Passive.Buff`: the creep effect, so the creep timer and its heal end).
- The plant gives it only on the edge: `if (!IsPlayerInCreep)` → `IsPlayerInCreep = true` and apply the creep if he
  lacks the buff. He is still "in" for the plant, so nothing happens until he leaves the ring (`IsPlayerInCreep`
  false) and steps in again. Another plant dying doesn't do it: plants remove the passive only if
  `IsPlayerInsideOtherCreep` (the other plants' `IsPlayerInCreep`) says he is in no other ring.
- The same happens when he walks out of an arc or ult Overgrowth while standing in a ring (the same end-overlap).
- **Fix** (`community-rowan.json`, `BP_TA_WoodenSword_Skill4`): in the plant's `Creep Growth` check,
  `Not_PreBool(self.IsPlayerInCreep)` → `Not_PreBool(false)` (`set-call-arg` in the ubergraph, 8 bytes shorter,
  offsets moved by `Reshape`; the decompile differs only on that line and every later label, entry point and latent
  resume moved by −8). Every 0.1 s while he is in the ring the plant checks `HasMatchingGameplayTag(Passive.Buff)` and
  applies the creep effect if it is missing; with the buff there it does nothing. Whatever takes the passive away
  while he stands in a ring (arc, ult Overgrowth, ending or walked out of), the plant gives it back within 0.1 s. A dead
  Rowan in a ring isn't re-buffed: the creep effect's `RemovalTagRequirements` require `State.Dead` (removed on
  death), and the engine doesn't apply it to a hero who has that tag (measured: `rh-dead`, below). Clients run the
  same check but can't apply the effect (no authority, no prediction key): nothing changes there.
- Not fixed (not reported): a plant dying while he stands only in an arc or ult Overgrowth takes the passive away too
  (`IsPlayerInsideOtherCreep` knows only plants), and the arc/Overgrowth gives it only on entry. Arcs last 3 s, ult
  Overgrowth 6 s.

### Tests (21 Oct)

`tools/run/test_rowan_heal.sh` (`test_patch.sh` with bob = Rowan, alice = Somnia, no CC casts; helpers
`tools/run/test_rowan.lua`, log `rowan.log` on the game server). Before the round bob fills every heirloom slot
(`test_rowan_heal.pre`: Dourling Caltrops, Glimmerbranch Hilt, Propagator, The Bloomblade): a slot left alone keeps a
default pick, and in one run (`rh-new`, first try) that default was Heal Sprite. The steps: alice shoots him down to
60-120 HP (as many 60-damage basic attacks as his health allows; retried if her pointer was stale and the shots
missed); he plants a Sourblossom and stands 200 from it, in the ring; health and effects every 0.25 s. Then an Earth Rend
arc and the ult's Overgrowth (The Bloomblade), each with him put where its collision overlaps him and the newest
Sourblossom moved 200 from him, until the area ends. Then the Sourblossom again from low health with Heal Sprite's rate
(`SetupRegenAugment` on the server's passive, what the item does). Patches: the live set (`base-blockers base-turrets
ccrevert community-heroes community-ishir community-lobby community-passives community-rowan community fiorne
tufts-sync`), with the live (17 Oct) `community-rowan.json` for "live", without it for "Feb", with the new one for "new".

| Run | Sourblossom from low health, no augment: start → 13 s → last tick (model) | Heal Sprite's rate: start → 13 s → last tick (model) | Earth Rend arc ends while he stands in the ring | He leaves the ult's Overgrowth while in the ring |
|---|---|---|---|---|
| `rh-feb` (Feb heal) | 110 → 612 → 635 at 13.96 s (641) | 92 → 767 → 797 at 14.48 s (802) | passive gone at 2.95 s (arc end), never back; the plant still has him "in" | passive gone at once, never back |
| `rh-live` (17 Oct heal) | 110 → 333 → 356 at 14.40 s (360) | 104 → 427 → 461 at 14.59 s (461) | gone at 3.02 s, never back | gone at once, never back |
| `rh-new` | 110 → 618 → 641 at 14.03 s (646) | 81 → 763 → 790 at 14.12 s (789) | **kept**; the ring heals on (1.79 % of missing per tick) | **kept** |
| `rh-new-item` (`HEALSPRITE=1`) | 110 → 624 → 652 at 14.45 s | 82 → 764 → 785 at 13.97 s | **kept** | **kept** |

- Per tick, measured: Feb 1.77 % of missing from 110 (= 0.884 × 2 %), 2.98 % with Heal Sprite's rate from 92 (0.903 ×
  3.3 %); live 0.58 % (0.5 % + 0.75 HP); new 1.80 %, 2.97 % with Heal Sprite's rate. Measured and model agree within
  6 HP. A Sourblossom's ring heals for 56-58 ticks (14-14.5 s) from when he steps in.
- a community member's numbers are these: ~650 / ~800 before 17 Oct = Feb over the plant's duration; 460 with Heal Sprite on live
  = `rh-live`'s 461.
- The real Heal Sprite: in `rh-new`'s first try (the 8 %/s build, only The Bloomblade equipped) the default pick was
  Heal Sprite: the server's passive had `ModifiedMissingHealthHPS` 3.3 at round start and healed 3.30 % of missing per
  tick from 110 (803 HP at 13 s, as the model): the item does exactly what `SetupRegenAugment` does. In `rh-new-item`
  the test's own equip of Heal Sprite didn't reach the server (its slot held Item_WoodenSword_LMB_CD there; rate 1.8),
  so that run is a second no-augment and Heal-Sprite-rate measurement.
- The ult: Rowan's ult moves him after the cast, so he left the Overgrowth (~170 units) right after being put in it.
  That is the walked-out-of variant of the same end-overlap; in Feb and live the passive was gone at once and never came
  back, with the fix it stayed.
- `rh-live`'s first try stuck in the lobby (no hero select: the known flake), rerun.
- **A corpse in a ring** (`rh-dead`, new build: `test_patch.sh` with `STEPS=tools/run/test_rowan_dead.steps`,
  `PRE_STEPS=tools/run/test_rowan_heal.pre`): alice shot bob dead outside a ring, his corpse was put 200 from a
  fresh Sourblossom. The plant had him "in" (and with the fix tried to give the passive every 0.1 s) for 1.07 s,
  until the game moved the corpse to his spawn (`DeathDelayTimer` 2.5 s after death): no creep effect, no heal, health
  0 throughout, `State.Dead` on.
