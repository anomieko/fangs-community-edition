# Community patch, part 2: Rowan, and CC immunity on dashes (built 16 Oct)

What Sheepa OK'd (the proposal PDF, cards 3 and 16; `docs/recon/community-patchnotes.md`), as built in
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
| Dourling Caltrops' tooltip ("Wall of Roots [SHIFT]") | | unchanged | Sheepa: may be his own keybinds |
| Rowan's passive heal on Overgrowth | proportional to his current missing health, with a strength fixed when he steps on: per 0.25 s, (missing share at step-on × 2 %) × missing health (measured: entered at 530/950, +3.7 HP per tick, 0.88 % of missing). Entered at full health it heals about nothing for that whole stay | 2 % of current missing health plus 3 health per second, every 0.25 s, whatever his health was when he stepped on (Aug) | passive `GetMissingHpValue`: `Multiply(1 − HP/max, rate)` → `Multiply(1.0, rate)` (`set-call-arg`, resized); creep timer `Activate Regenerate Item`: the SetByCaller tag `Data.Heal` → `Data.Heal.MissingMultiple` (the healing execution's fraction of current missing health), and a copy of the `Divide` and of the `AssignTagSetByCallerMagnitude` adds `Data.Heal` = `ModifiedHealPerSecond` (3) ÷ 4 to the same spec |
| Passive tooltip | "heals for 2% of his missing HP per second" | "… plus 3 HP per second" | `replace-text` `WoodenSword_P_desc` |
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
- **Balance note:** the Aug rule (2 %/s + 3 HP/s) heals less than Feb's when Rowan steps on badly hurt (entered at 56 %:
  Feb ~14.8 HP/s, patched ~11.4 HP/s at that moment) and more when he steps on healthy or takes damage while standing
  there (Feb ~0 if entered at full health). Sheepa asked for the Aug rule.
- **Propagator's bar fix is not verified in a match:** the hook runs on the Sourblossom icon (`fangsboot.log`) and
  reads the timer, but the test produced no Propagator-shortened timer to compare (no difference logged). Check it in
  play.
- **Glimmerbranch recast:** not exercised by the test (the second Space press didn't recast); by the code, every dash end
  places the vines.
- Earth Rend's arc and the ult's overgrowth weren't reached in the test (teleporting Rowan onto the arc actor's
  origin, or ahead of it, didn't overlap its cone; the ult's overgrowth actor wasn't found in time).
