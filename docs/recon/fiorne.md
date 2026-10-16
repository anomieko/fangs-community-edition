# Fiorne (Lancer): what changed from Aug 2022 to Feb 2023, her bugs, and a restore plan

Research of 16 Oct 2026 for the user ("she feels super weak … rubberbands a lot"). It's static only: class defaults
(`work/cc-audit/props.py`, `cdo_{aug,feb,dec}.json`), pseudocode (Aug `work/shard/bp-aug`, Feb `work/bp-2023-02-15`,
Dec `work/bp`), item assets (`BpDump --raw`) and string tables (`st_{aug,feb}.json`). Nothing was run in a match.
Assets are under `MOBA/Content/Gameplay/Abilities/Player/Lancer/` unless noted. Keys: Space = `Skill1`, Shift =
`Skill2`, E = `Skill4`, R = `Skill3`. Dec 2023 reworked her (Shift moved to E, a new RMB `FocusAttack`, stacks inside
Space), so its column only fills where the same ability still exists.

## Bottom line

- **Feb 2023 turned her from a glass cannon into a bruiser.** Base HP went 650 → 900 (+38 %, the biggest raise of any
  hero), while almost every damage number was cut by a third to a half. Her R does half the damage. Her LMB lost a
  quarter of its reach. Her parry got a much smaller catch area, a longer self-lock, and half the damage.
- **Space got a real cooldown between dashes**: 0.3 s → 1.0 s, and the dash is 15 % slower. The user's guess is right.
- **Shift is not slower.** Its cooldown is still 12 s, and the slam comes a little sooner (0.3 → 0.2 s). Its damage
  went up (50 → 80). Its recast moved to a native recast task: a 0.75 s window and a 0.5 s input buffer. Only its
  heirloom Earthbreaker Pommel was cut (125 → 40 bonus damage).
- **12 of her heirlooms were weakened**, 5 were buffed, and the rest are unchanged (table below).
- **The 0 Bunny Stacks bug.** The stacks are only set up when a round starts. Any restart of the ammo ability during
  a round leaves her at 0 stacks with nothing refilling them until the next round. With Julienne's Javelin her E is
  also blocked.
- **Rubber-banding.** She chains the most fast dashes of any hero. In Feb, every dash keeps its speed after it ends.
  Her Shift and R also lost the sync point where the server waits for the player's own client, and the game corrects
  positions for tiny differences.

## Base stats (`Gameplay/Effects/Player/Lancer/BP_GE_Lancer_Stats`, `BP_Lancer_Char`)

| | Aug | Feb | Dec |
|---|---|---|---|
| Max HP | 650 | **900** | 800 + 75 per round |
| Move speed | 573 | 600 | 600 |
| Max mana | 1400 | 2325 | – |

Other heroes' HP, Aug → Feb, moved by −100 to +150 (Sidekick −100, Gunslinger +150). Fiorne's +250 is the outlier.

## Abilities

### LMB Swift Strike (`LMB/BP_GA_Lancer_LMB`)

| | Aug | Feb | Dec |
|---|---|---|---|
| Damage (`AbilityDamage`) | 45 | **30** | 50 (cone, reworked) |
| Reach (`Range`, `ModifiedRange`) | 550 | **425** | 350 |
| Cooldown after the cast | 0.30 s | 0.17 s | 0.8 s |
| Cast 0.25 s, cast slowdown 0.75 | same | same | same |

That's 45 per ~0.55 s in Aug against 30 per ~0.42 s in Feb (before attack speed): about −15 % sustained damage and a
quarter less reach.

### Passive Duelist's Momentum (Aug: `BP_GA_Lancer_LMB`; Feb: `P/GA_Lancer_P`)

| | Aug | Feb | Dec |
|---|---|---|---|
| Attack speed after an LMB hit | +100 % (`Passive AS` 1.0) | **+50 %** (`PassiveASMagnitude` 0.5) | +100 % |
| Duration | 1.25 s | **0.7 s** | 1.0 s |
| Cooldown | 7 s | 5 s | 5 s |

### Space Nimble Thrust (`Skill1/BP_GA_Lancer_Skill1`, stacks `Skill1/BP_GA_Lancer_Ammo`)

| | Aug | Feb | Dec |
|---|---|---|---|
| Time between dashes (`AbilityCooldown`, applied by `ApplyAbilityCooldown` after each dash) | **0.3 s** | **1.0 s** | 1.0 s |
| Dash speed (`DashSpeed`) | 2750 | **2325** | 2325 |
| Dash length (`Range`) | 450 | 525 | 525 |
| Damage | 25 | 25 | 55 |
| Bunny Stacks: max 3 (+2 with Wanderer's Travelpack), one every 6 s | same | same | 2 stacks, 6 s |
| End of the dash | velocity cleared (`VelocityOnFinishMode` 1) | **momentum kept** (0) | 0 |
| Net sync | server waits for the client at the start (`WaitNetSync` 1); client waits at the end (2, `SyncDashes` true) | **both wait at the end** (0); `SyncDashes` false, so the client wait is skipped | – |

In Feb the dash also ends as soon as Fiorne gets `Effect.LockMovement` (rooted, stunned) on the server
(`MOBAWaitGameplayTagsAdd`). Wanderer's Travelpack sets the time between dashes to `More Stacks CD` 2.5 s in both
builds. That was 8× Aug's base, and is 2.5× Feb's.

### Shift Hiari Smash (`Skill2/BP_GA_Lancer_Skill2`)

| | Aug | Feb | Dec (E key now) |
|---|---|---|---|
| Damage | 50 | **80** | 20 + ratios |
| Radius / range | 300 / 300 | 330 / 340 | 400 / – |
| Cooldown; −3 s on hit | 12 s | 12 s | 8 s |
| Slam delay / slam event | 0.3 / 0.6 | 0.2 / 0.29 | – |
| Recast | `MOBAWaitInputPressed` + `CanRecast`, auto-slam after `MaxAirTime` 0.75 | native `WaitRecast(bTestAlreadyPressed, …, BetweenCastsDelay 0.05, MaxRecasts 2, RecastWindow 0.75, BufferInput true, BufferTime 0.5)` | – |
| Ability lock | `LockAbilities(GetAbilityLifeTime)` + standing still, ≈ 1.4 s | the same through `Lock()`, ≈ 1.46 s | – |
| Net sync | client waits (2) and server waits (1), in pairs | **only client waits (2)**; the two server-waits and their 0.25 s timeouts are gone | – |
| Jumps end | velocity cleared (1) | momentum kept (0) | – |

`GetAbilityLifeTime` = `MaxAirTime` + `Slam Cast Time` + 2 × range / dash speed. The lock always lasts that long, even
when the slam comes early. That was already so in Aug.

### E Spear Throw (`Skill4/BP_GA_Lancer_Skill4`)

| | Aug | Feb | Dec |
|---|---|---|---|
| Damage | 85 | **70** | (reworked) |
| Cooldown | 6.0 s | **6.5 s**, plus the player's round-trip time (`AddAnticipatedRoundTripTimeToCooldown`) | 12 s |
| Projectile speed / range | 3750 / 1200 | 3375 / 1120 | – |
| Slow 35 % 1 s, knockback 250 | same | same | – |

The round-trip addition is netcode hygiene (the client's cooldown matches the server's). Keep it.

### RMB Retaliate (`RMB/BP_GA_Lancer_RMB`; Dec moved it to Shift)

| | Aug | Feb |
|---|---|---|
| Damage per parried hit (`AbilityDamage`) | 40 | **20** |
| Area ticks (`Dmg Per AOE Tick`) | 20 | **10** |
| Parries (`CounterCap`) | 5 | **4** (the tooltip still says 5) |
| Stance, which is also an ability lock (`CounterDuration`, `LockAbilities`) | 0.85 s | **1.5 s** |
| Parry catch area: her hit capsule × `IncreasedCapsuleSize` during the stance (`Increase Hitbox Size`) | **× 2.6** | **× 1.0** (no enlargement) |
| Move speed while in stance (`Slowdown`/`CastSlowdown`) | 0.33 | 0.5 |
| Heal per parry 20, cooldown 8 s | same | same |

### R Grand Finale (`Skill3/BP_GA_Lancer_Skill3`)

| | Aug | Feb | Dec |
|---|---|---|---|
| Grab damage (`AbilityDamage`) | 65 | **30** | 30 + AD |
| 3 aerial hits (`AerialDamage`) | 3 × 60 | **3 × 30** | 3 × 50 |
| Knockdown (`KnockDownDamage`; the CDO's stale `ModifiedKnockDownDamage`) | 120 (120) | **60** (30) | 100 |
| Total on one target | ≈ 365 (tooltip: 300) | **≈ 180** | ≈ 280 |
| Hooking Ribbons, damage to extra targets | 33 % | 50 % | 50 % |
| Dash 3000 / 1000, end velocity | cleared (1) | momentum kept (0) | 0 |
| Net sync | client waits (2) and server waits (1) | only client waits (2) | – |

The Feb tooltip computes `ModifiedKnockDownDamage + AerialDamage × AerialAttacks` from the stale 30.

## Heirlooms (offered rows in `backend/seed/augments-feb2023.json`, owner `Lancer`)

Names are Feb's. Aug had most of the same items; some had no texts in Aug (GUID keys), but their code and values were
there.

| Heirloom (key) | Asset value | Aug | Feb | Verdict |
|---|---|---|---|---|
| Relaxing Tankard (LMB) | LMB `Item 17 Heal Per Bunny Stack` | 7 | 5 | nerfed |
| Stabbers (LMB) | LMB `Damage Per Ramp Stack` | 2.0 | 1.5 | nerfed |
| Pouch of Devil Sprites (LMB) | LMB `TS …` 8 %, 35-120 | same | same | – |
| Demoneye Necklace (LMB) | reveal + ground 1.25 s | same | same | – |
| Bossblade (passive) | passive cooldown cut on a Captain hit | 2 s (LMB `ItemKingHitReduceCDAmount`) | 3 s (`CRCDReduction`) | buffed |
| Meanie's Belt (passive) | 75 shield 1.5 s | same | same | – |
| Warrior's Bounty (passive) | P `Item23 Kill/Assist Stacks to Add` | 3 | 2 | nerfed |
| Fifi's Little Helper (passive) | P `Snowball Damage Percent` / `LS Percent` per stack | 3 % / 1 % | 1 % / 0.75 % | heavily nerfed |
| Duelist's Zone (artifact) | 6 / 10 heal | same | same | – |
| Champion's Helm (Space) | Space `Debuffing Dash Heal Reduction` | 50 % | 40 % | nerfed |
| Trickster's Mixture (Space) | the stack ability's `UntargetableArmor` (`ApplyDamageReductionItem`); Space's `UntargetableArmorPercent` (Aug 0.10, Feb 0.15) is read by no code | 10 | 10 | – (tooltip right) |
| Wanderer's Travelpack (Space) | +2 stacks, dash cooldown 2.5 s | same | same | relatively better (base went to 1.0 s) |
| Dreadland's Corsage (Space) | resets the passive | same | same | – |
| Earthbreaker Pommel (Shift) | Shift `DHDamageIncrease`; CC | 125, stun 1.0 | 40, root 1.5 | nerfed; the CC is back to stun 1.0 through `ccrevert.json` |
| Dreadborn Artifact (Shift) | Shift `ItemKillResetExecuteRatio` | 20 % missing HP | 10 % | nerfed |
| Aegis Greaves, Sneaky Shardring (Shift) | shields, stealth 2.5 s | same | same | – |
| Pin Cushion, Hiari Charm, Guard Drill, Draining Ointment (E) | | same | same | – |
| Julienne's Javelin (E) | E `ChargedLancesBonusDmg` | 40 % | 45 % | buffed |
| Lance Frills (E) | +1 stack on hit, "+2 if rooted" | the +2 is text only (no code reads `BP_GE_Lancer_MoreBunnyStacks`) | same | text bug |
| Warmother's Glaive (RMB) | RMB `CA Damage Bonus`, `Dmg Per AOE Tick` | 20 / 20 | 10 / 10 | nerfed |
| Master's Visor (RMB) | `RechargeParryThreshold` | 3 parries | 2 | buffed |
| Dragging Manica (RMB) | pull range | 600 | 750 | buffed |
| Shieldcharm (RMB) | 75 + 25 per parry | same | same | – |
| Woemaker (R) | R bonus per Bunny Stack | 40 | 35 | nerfed |
| Deathly Carnival (R) | R `ItemStackingAdditionalDamage` | 60 | 40 | nerfed |
| Hooking Ribbons (R) | see R | 33 % | 50 % | buffed |
| `LancerItem19` (Space, restored) | no texts in any build | – | – | `docs/recon/items.md` |

Every Feb tooltip above is computed from the ability's values (`$Property$`), so value patches update them. The
exceptions: Retaliate's "up to 5 attacks" and Trickster's "10 %" are written out in the text (both right with the
restore).

## Bugs

### 0 Bunny Stacks for the rest of the round

- The stacks are an ability of their own, `Skill1/BP_GA_Lancer_Ammo` (child of `Shared/BP_GA_Template_Ammo`), granted
  by the infinite effect `BP_GE_GrantLancerAmmoSystem`.
- **It only sets itself up when a round starts** (`OnRoundStart_CountDownEndDel` → `On Round Start`):
  - `SetAmmoClass`;
  - `ListenForStackChange`: a used stack starts a 6 s cooldown;
  - `ListenForCooldownRemoved`: an ended cooldown adds a stack;
  - `ApplyMaxStacks`.
- `Round End` (`OnPreRoundEndDel`) clears all of it. Its `K2_ActivateAbility` only binds those two delegates.
- So **an ammo ability that starts during a round has no stacks and nothing that refills them until the next
  round**. With Julienne's Javelin it is worse: at 0 stacks it applies a `Lancer.Skill4.CantCast` effect with
  `Data.Duration` 0, which never expires, and only that dead listener removes it. Her E stays blocked too.
- **New in Feb: a safety net that restarts it.**
  - The passive (`P/GA_Lancer_P`, authority only) applies the grant effect in `Init Ammo`. About 6 s later it runs
    `CheckAmmoSystemIsInit`.
  - That check looks for the instance (`GetAbilityInstanceFromAbilityClass`). If none is found, it logs
    "GA_Lancer_Ammo insttance NOT FOUND", removes the grant (`Effect.Lancer.AmmoGAGranted`), re-applies it and checks
    again every second.
  - A re-grant during a round lands in exactly the state above.
  - Aug applied the grant once, with no check.
- **Possible triggers, not confirmed**: the safety net firing after the round started, a late spawn or reconnect, an
  ability cancel on death followed by a re-activation, and the grant effect having no stacking rule (a second
  application grants a second ammo ability). A FangsCtl logger on the server shows which one: per round, the count of
  `BP_GA_Lancer_Ammo` instances, the stack count, running `Effect.Ammo.Cooldown.Skill1` effects and the "NOT FOUND"
  line, across deaths, rounds and a reconnect.

### Others

- Retaliate's tooltip says 5 parries; `CounterCap` is 4.
- Lance Frills' "+2 stacks if rooted" has no code.
- R's tooltip total uses the stale `ModifiedKnockDownDamage` (30).

## Rubber-banding

Fiorne is the hero with the most predicted dashes in a row (3-5 Space dashes at 2325 uu/s, Shift's two jumps, R's
3000 uu/s dash), so every netcode weakness shows on her first:

1. **Every dash keeps its speed after it ends** (`ApplyRootMotionJumpForce` argument 8, `VelocityOnFinishMode` Aug 1 →
   Feb 0): Space (1 call), Shift (2), R (1). After the dash, she slides at dash speed and then brakes. Client and server
   end the dash at slightly different moments, so the slide ends in different places and the server corrects her.
2. **Feb removed the "server waits for the client" sync points** on Shift and R. Those were the pattern where the
   player's own client moves at once and the server catches up. What is left is "client waits for server" (type 2). The
   player's dash then starts a round trip late on their own screen, and the server's version runs ahead. Space ends
   with a both-wait sync (type 0, 0.25 s timeout) instead of Aug's client-wait (`SyncDashes` was true in Aug and is
   unset in Feb).
3. **A Space dash ends on the server when she gets rooted or stunned**, while her client keeps dashing until it hears.
   The result is a snap back.
4. **The game's own netcode settings**: corrections from 0.7 units of difference (Aug 2.9), client moves sent 20 times
   a second (Aug 60), the net tick capped at 30 on listen servers (`docs/recon/community-patchnotes.md`, optimization).
   They hurt every hero, and her most.

Most likely to rubber-band: chained Space (1, 2 and 4), then R (1, 2), then Shift (1, 2).

## Proposed restore (built as `tools/patch/patches/fiorne.json`: see "Built and tested" at the end)

### (a) Bug fixes

| Fix | Edit | Tool |
|---|---|---|
| Stacks are set up whenever the ammo ability starts, not only at round start | `BP_GA_Lancer_Ammo`: `insert-call` `On Round Start` at the end of its `K2_ActivateAbility` stub; and `Clear Stacks and Listeners` at the start of its `On Round Start` stub, so a second setup in the same round doesn't double the listeners | `insert-call` exists (branch `assetpatch-rewrite`). It must also accept a function inherited from the parent Blueprint (`Clear Stacks and Listeners` lives in `BP_GA_Template_Ammo`): small extension |
| Fallback | FangsHost watcher (server): Fiorne at 0 stacks with no `Effect.Ammo.Cooldown.Skill1` running → call the instance's `On Round Start` | Lua |
| Tooltips | Retaliate "5" (fixed by restoring 5 parries below), Trickster's "10 %", Lance Frills' rooted sentence, R total (set `ModifiedKnockDownDamage` with `KnockDownDamage`) | `replace-text`, `set-default` |

### (b) Undo the Feb nerfs (Aug values)

| Ability | Edits (`set-default` unless noted) |
|---|---|
| LMB | `AbilityDamage`/`ModifiedAbilityDamage` 30 → 45; `Range`/`ModifiedRange` 425 → 550; `AbilityCooldown`/`ModifiedAbilityCooldown` 0.17 → 0.3 |
| Passive (`GA_Lancer_P`) | `PassiveASMagnitude` 0.5 → 1.0; `PassiveASDuration` 0.7 → 1.25 (keep Feb's 5 s cooldown, or 7 for pure Aug) |
| Space | `AbilityCooldown` 1.0 → 0.3; `DashSpeed` 2325 → 2750 (`Range` 525 can stay) |
| RMB | `AbilityDamage` 20 → 40; `Dmg Per AOE Tick` 10 → 20; `CounterCap` 4 → 5; `CounterDuration` 1.5 → 0.85; `IncreasedCapsuleSize` 1.0 → 2.6 (keep Feb's 0.5 move speed and 2-parry Master's Visor) |
| E | `AbilityDamage`/`ModifiedAbilityDamage` 70 → 85; `AbilityCooldown`/`ModifiedAbilityCooldown` 6.5 → 6.0; `Projectile Speed` 3375 → 3750; `Range` 1120 → 1200 (keep the round-trip cooldown) |
| R | `AbilityDamage`/`ModifiedAbilityDamage` 30 → 65; `AerialDamage` 30 → 60; `KnockDownDamage` 60 → 120 and `ModifiedKnockDownDamage` 30 → 120 (keep Hooking Ribbons' 50 %) |
| Heirlooms | Relaxing Tankard 5 → 7; Stabbers 1.5 → 2.0; Warrior's Bounty 2 → 3 (both floats); Fifi's Little Helper 0.01 → 0.03 and 0.0075 → 0.01; Champion's Helm 0.4 → 0.5; Earthbreaker Pommel `DHDamageIncrease` 40 → 125; Dreadborn Artifact 0.1 → 0.2; Warmother's Glaive `CA Damage Bonus` 10 → 20; Woemaker 35 → 40; Deathly Carnival 40 → 60 |
| Kept from Feb (buffs or fixes) | Shift's 80 damage and larger area; move speed 600; the buffed heirlooms; E's round-trip cooldown |

**Don't overshoot.** Aug's damage on top of Feb's 900 HP is stronger than either build. Pick one:
- (1) Aug kit and Aug HP 650: the original glass cannon;
- (2) Aug kit with HP 800 (Dec's base): our suggestion as the playtest starting point;
- (3) Aug kit with HP 900: likely too strong.

Brutus' HP goes through the same edit type: `set-export-prop` `BP_GE_Lancer_Stats` `Modifiers[0]…Value` (branch
`assetpatch-export-prop`).

### (c) Rubber-band fixes

| Fix | Edit | Tool |
|---|---|---|
| Stop dead at the end of every dash, as in Aug | `set-call-arg` `ApplyRootMotionJumpForce` arg 8, 0 → 1: Space ×1, Shift ×2, R ×1 | The literal is an `EX_ByteConst`. `set-call-arg` writes numbers as floats today, which changes the size, so it refuses: it must keep the literal's type (small fix) |
| Aug's dash sync (client-wait at the end) | `SyncDashes` true on Space | Feb doesn't store the value, and no op can add one yet: new op, or flip the `JumpIfNot` with the rewriter |
| Server-waits on Shift and R | re-add Aug's `WaitNetSync(1)` + 0.25 s timeout | new code (copy from Aug with the rewriter: not built yet) |
| Netcode settings (all heroes) | `MAXPOSITIONERRORSQUARED`, `ClientNetSendMoveDeltaTime`, net tick | config A/B, `docs/recon/community-patchnotes.md` |

### Tests (when nobody plays)

- `test_patch.sh` with `HERO_B=Lancer`: damage per ability on the dummy hero, Space chain timing, Retaliate catching
  shots from beside her, stacks after death, round change and a forced re-grant (FangsCtl).
- Then a latency run with `netem` inside the test's own network namespace, counting snaps (measurement plan in
  `docs/recon/community-patchnotes.md`) before and after (c).

## Built and tested (16 Oct)

The user approved the plan with **800 HP** ("for fiorne, we should go with your plan!"). Built as
`tools/patch/patches/fiorne.json` (`"enabled": false`, branch `fiorne-restore`):
- (a) the Bunny Stacks fix: `insert-call` `Clear Stacks and Listeners` (inherited from `BP_GA_Template_Ammo`) at the
  start of `BP_GA_Lancer_Ammo`'s `On Round Start`, and `On Round Start` at the end of its `K2_ActivateAbility`. The
  decompile reads `ExecuteUbergraph_BP_GA_Lancer_Ammo(948); On Round Start(); return`. The Lance Frills and Spear Throw
  tooltips are fixed (no "+2 if rooted"; a wall pin "stuns").
- (b) every Aug value of the table above, 800 HP through `set-export-prop` on `BP_GE_Lancer_Stats`.
- (c) `VelocityOnFinishMode` 0 → 1 on the four dash calls (`set-call-arg` keeps the byte literal).
- Not built: Aug's sync points (`SyncDashes`, the server-waits on Shift and R; new code) and the netcode settings
  (all heroes, `docs/recon/community-patchnotes.md`).
- Correction to the table above: Trickster's Mixture wasn't buffed. Space's `UntargetableArmorPercent` is read by no
  code; the damage reduction is the stack ability's `UntargetableArmor` 10, as the tooltip says.

The patch builds alone and after `ccrevert` (`tools/patch/build.sh <game> ccrevert fiorne`). Both edit `Lancer/Skill2`
and `LOC_EN_AUGMENTS_LANCER`, on different values.

**Match test** (`tools/run/test_fiorne.sh`: `test_patch.sh` with bob as Fiorne plus `test_fiorne.steps`), with the pak
(`RUN=fio-a`) and without it (`RUN=fio-ctl`, `PATCHES=none`):

| | Without (Feb) | With the patch |
|---|---|---|
| Patched values loaded (alice, bob, server) | – | 38/38 (the 39th, the nested HP value, `check()` can't read; `stats` shows it) |
| Max HP | 900 | **800** |
| Space ×3, 0.6 s apart (client `TryActivateAbilityByClass`) | true, false, false: one dash | **true, true, true: three dashes** |
| Dash speed; speed in the 50 ms samples after the dash | 2325; 2325 → 338 → 0 | **2750; 2750 → 0** |
| Stacks after the chain, then 7 s later | 2, then 3 | 0, then 1 (6 s per stack) |
| Stack system removed and granted again mid-round (`regrant`, as `CheckAmmoSystemIsInit` does), then 3 dashes | 3 → 0, and still **0 with no stack cooldown running** 8 s later: the bug | 3 → 0, then **1 back** 8 s later: refilling |

What a match didn't show: damage numbers on targets, Retaliate's catch area, E and R in use, and how she feels.

## Rebalanced: 700 HP (user, 16 Oct)

The user asked whether the 800 HP build was too strong. Compared with the roster, it was:
- The other heroes' damage barely changed Aug → Feb. A rough measure, the median Feb/Aug ratio of each hero's
  damage-named ability defaults, is 1.00 for 9 of the 12 other heroes it covers (Brutus 0.94, Rowan 0.92, Belroth
  1.67; Fiorne 0.82). Their HP moved −100 to +150. So Aug Fiorne, balanced around **650 HP**, is the
  reference, and her Aug damage is normal for today's roster.
- On top of the Aug kit, the 800 build gave her +150 HP (+23 %). It also kept Feb's 5 s passive cooldown (Aug 7 s:
  about 40 % more uptime of an Aug-strength passive), and Feb's 80 Shift base with Aug's +125 Earthbreaker Pommel (205,
  Aug 175).

The user's choice, "Aug Fiorne with a small cushion":
- `BP_GE_Lancer_Stats` HP 900 → **700**;
- `GA_Lancer_P.PassiveCooldown` 5 → **7** (read by the LMB as `Modified Passive CD`);
- Earthbreaker Pommel `DHDamageIncrease` 40 → **95**, so Shift with it does Aug's 175.

Kept: Feb's move speed (600, Aug 573) and its buffed heirlooms. Tune further from players' feedback; each value is
one line in `fiorne.json`.

Rerun with these values (`RUN=fiorne-700`, `tools/run/test_fiorne.sh`): 39 of 40 patched values loaded on both clients
and the server (the 40th, the nested HP value, `check()` can't read), health **700/700**, Space dashes at 2750 that
stop dead, stacks refilling after a dash chain and after a mid-round restart of the stack system (0 → 1).
Those need play.

The 0 stacks trigger in real games is still unconfirmed. Sheepa (Q40, 16 Oct): when it starts, "not sure"; once
broken, it "stays broken all match". In Feb the restarted stack system would set itself up again at the next round
start (it binds the round delegates when it activates), so "all match" points to a second cause: an activation that
ends before it binds them (`K2_CommitAbility` failing, or no `Player`). The patch covers that too, as long as the
ability activates at all. One that never activates again isn't covered: a FangsHost watcher would be the safety net
(not built).
