# Crowd control changes, Aug 2022 → Feb 2023, and how to revert them

Players report that a patch between the Aug 2022 build (`alpha7.0.7.51`) and the Feb 2023 build we run
(`Playtest021523v1_v0_0_02`) turned several crowd-control (CC) effects into roots and changed durations. This file
lists every such change, with the Dec 2023 playtest (`main_v0_0_444`) as "did the developers keep it", and a plan
to revert them. The revert of the root conversions and Somnia's ult lock is built as a patch pak; see "The revert as
built" below.

**How it was compared.**
- Every Blueprint's pseudocode was diffed (Aug `work/shard/bp-aug`, Feb `work/bp-2023-02-15`, Dec `work/bp`).
- The class defaults (CDO) of every Blueprint were diffed: `work/bin/bpdump/BpDump --raw` on
  `work/extract-2022-08-26`, `work/extract-2023-02-15` and `work/extract`.
- Scripts and outputs (local, git-ignored) are in `work/cc-audit/`:
  - `sem_cc.txt`: CC calls per file, with Aug/Feb/Dec counts;
  - `cdovals_all.txt`: CDO value changes;
  - `props.py <Class> <regex>`: one class's defaults in all three builds;
  - `ctx.sh <path> <regex>`: the matching code in all three builds.
- Native behaviour comes from disassembling the Feb exe. Addresses are below.
- Ability names come from the Feb string tables (`LOC_EN_ABILITIES_*`), heirloom names from `LOC_EN_AUGMENTS_*`.

Asset paths are under `MOBA/Content/Gameplay/Abilities/Player/` unless they start with another top folder.

**Keys.**
- The ability slot enum maps to keys as: `Q` slot = Space, `E` slot = Shift, `Skill4` slot = E key, `R` slot = R.
- Dec renamed some files: Ishir's and Rayo's Skill2/Skill4 swapped, and Rowan's Sourblossom/wall swapped.

## Hero names (DT_Heroes row → in-game)

Every released hero has at least one change below.

| Row | Name |
|---|---|
| FireMage | Astrada |
| Berserker | Brutus |
| ShieldGirl | Ethryn |
| Lancer | Fiorne |
| Gunslinger | Wylde |
| Backstab | Ishir |
| IceMage | Kiona |
| LightningArcher | Rayo |
| DemonGirl | Rose |
| WoodenSword | Rowan |
| BookMage | Somnia |
| Sidekick | Tufts |
| BattleMonk | Yanari |
| CatSupp | Zoey & Boo |
| BigBoi | Belroth |

## What each CC does (Feb build; unchanged since Aug)

All of them take their duration from SetByCaller `Data.Duration`. The helpers
`BP_FL_MOBA_AbilitySystemFunctionLibrary.Make{Root,Stun,Charm,Fear,…}EffectSpec(Instigator, Duration)` are identical in
Aug and Feb. Only the call sites changed.

| GE (`Gameplay/Effects/Shared/`) | Owned tags | Effect on the target | Ignored or removed by |
|---|---|---|---|
| `BP_GE_Root` | LockMovement, State.Rooted | can't move, **can still cast** | AntiStun, State.Counter; ends on AntiRoot |
| `BP_GE_Stun` | LockCasts, LockMovement, State.Stun | can't move or cast | AntiStun |
| `BP_GE_Charm` | LockCasts, State.Charm, grants `BP_GA_Charm` | can't cast; walks to the caster (`DoTargetKnockback`, `Data.Distance` or 150 uu over the duration) | AntiCharm, AntiStun |
| `BP_GE_Fear` | LockCasts, State.Fear, grants `BP_GA_Fear` | can't cast; runs away | AntiFear, AntiStun |
| `BP_GE_KnockUp` (new in Feb) | LockCasts, LockMovement | airborne | AntiKnockUp |
| `BP_GE_Incapacitate` | LockCasts, LockMovement | can't move or cast | AntiStun |
| `BP_GE_Generic_Grounded` | State.Grounded | no dashes or blinks | CC immunity |

A root is therefore much weaker than the stun or charm it replaced: the target keeps casting, dashing out excepted.
The only Aug → Feb change to these effects: Root and Stun now also grant `BP_GA_CC_CameraShake`, a cosmetic camera
shake on the target.

## Summary: CC that became roots

| Hero | Ability (key) | Aug | Feb | Dec |
|---|---|---|---|---|
| Somnia | **Allure** (E): the first enemy hit by the projectile | charm 0.75 s (+0.5 empowered) | **root 1.25 s** (+0.5) | root 1.25 s |
| Brutus | **Earthquake** (Shift): centre of the first tremor (augment Quakebreak Talisman) | stun 1.5 s, radius 150 | **root 1.5 s, radius 350** | root |
| Ethryn | **Knightseeker** (Space): enemy pushed into a wall | stun 0.75 s | **root 1.5 s** | root 0.85 s |
| Ethryn | Ironclad Slam (Shift) + heirloom **Vortex Pauldrons** | slow 50 % 1.25 s + flip behind her | **root 2 s** | slow |
| Fiorne | Hiari Smash (Shift) + heirloom **Earthbreaker Pommel** | stun 1.0 s | **root 1.5 s** | reworked (fading slow) |
| Astrada | **Flame Cage** (Shift): enemies crossing the walls | stun 1.0 s, cage 3 s | **root 1.25 s**, cage 2 s | stun 1.2 s (moved to E) |
| Astrada | Blast Wave (RMB) + heirloom **Repulsing Scepter**: knocked into a wall | stun 0.5 s | **root 1.5 s** | reworked (fading slow) |
| Zoey | **Spirit Scratch** (E) | stun 0.9 s | **root 1.3 s** | root 1.0 s |
| Rowan | **Dourling Dive** (Space): dash hit | stun 0.75 s | **root 1.0 s** | root 1.0 s |

Notes on this table:
- Belroth's Boulder Toss was already a root in Aug (0.75 s → 1.2 s in Feb; Dec makes it a 0.8 s stun).
- The developers usually lengthened the CC when they made it a root. Reverting only the type would leave it stronger
  than in Aug, so revert both.
- Somnia's other CC changed with Allure. Her Delirium heirloom **Petunia** charms everyone in the pool when the pool
  damages a charmed enemy. Allure no longer charms, so Allure can no longer trigger it. When Petunia does trigger,
  its charm lasts as long as Allure's (Aug 0.5 s, Feb 1.25 s).

## Self-restrictions

### Somnia's ult (`BookMage/R/BP_GA_BookMage_RNEw`, Tethers of Eternity)

Feb added `PreCastLock()` at activation: `LockAbilities(0.0f, [])`, `LockRotation()` and `StartSlowdown(0)`.

**What `LockAbilities(Timeout, OptionalIndividualAbilities)` does** (native `UMOBAGameplayAbility`, Feb exe
`0x141266db0`):
1. If the ability has already locked, it does nothing.
2. Otherwise it sets the "locked" flag and starts a timer of `Timeout`. `Timeout` 0 means no timer.
3. With no individual abilities listed, it applies the ability's `LockoutEffect` (`BP_GE_LockAbilities`, owned tag
   `Systems.Input.LockAbilities`) to the caster, with SetByCaller `Data.Duration` = max(Timeout, 0).
4. A HasDuration effect with duration 0 gets no expiry timer, so the lock has no end time of its own.

**Only `UnlockAbilities` lifts the lock** (`0x141282200`; removes the effect, clears the flag). It is called by:
- `CastAndSpeedUnlock` (`0x1412506f0`);
- the cast task's `UnlockAndStopRooting` (`0x141282540`), but only for tasks created with `LockWhileCasting`;
- death and round end, through the effect's own tags.

| | Aug | Feb | Dec |
|---|---|---|---|
| Cast task (`MOBAWaitCastTime`) | `LockWhileCasting` = true: abilities locked, standing still, rotation locked for the 0.5 s cast, then released | `LockWhileCasting` = false | false |
| PreCastLock | none | ability lock **until the ult ends** (`K2_OnEndAbility` → `CastAndSpeedUnlock`): 0.5 s cast + ≈3 s tether. Standing still and rotation lock until the cast event (`Remove Slows`) | `LockRotation` + standing still only, no ability lock |

The players are right: in Feb, Somnia can't use any ability during the whole tether. In Aug she could after the 0.5 s
cast. The developers removed this lock again by Dec.

### Other self-locks

| Hero | Ability | Aug | Feb | Dec |
|---|---|---|---|---|
| Rowan | Glade Slash (LMB) | no lock | `LockAbilities(0)` on every swing, `UnlockAbilities` only when LMB is released: no abilities while LMB is held | removed |
| Tufts | Slap! (LMB) | `LockAbilities(0.3)`, unlocked on release and on finish | `LockAbilities(5.0)`, unlocked only on release: no abilities while LMB is held (up to 5 s) | as Feb |
| Rowan | Earth Rend (RMB) | locked during the 0.4 s cast (cast task) | `LockPreCast()` (same three calls as Somnia's), unlocked at the cast sync: same window, a refactor | as Feb |
| Brutus | Head Splitter (RMB) | rotation lock + standing still at full charge | removed (looser) | as Feb |
| Rose | Sword Sling (LMB) | `LockAbilities` + slowdown per attack | removed (looser) | as Feb |
| Wylde | Fan the Hammers (Shift), LMB, Full Fury (R) | castable while stunned or charmed (`Effect.LockCasts` not in `ActivationBlockedTags`) | blocked by LockCasts; Fan the Hammers ends when LockCasts is applied | as Feb |

Longer casts mean longer locks during the cast:

| Hero | Ability | Cast (Aug → Feb) |
|---|---|---|
| Somnia | Allure | 0.25 → 0.75 s |
| Somnia | Dream Shot | 0.25 → 0.4 s |
| Somnia | Delirium | 0.25 → 0.5 s |
| Somnia | Night Blast | 0.25 → 0.5 s |
| Kiona | Shattershot | 0.35 → 0.7 s (Dec 0.35) |
| Astrada | Flame Cage | 0.25 → 0.4 s |
| Astrada | Snapflare | 0.2 → 0.4 s |
| Astrada | LMB | 0.3 → 0.4 s |
| Rayo | LMB | 0.25 → 0.45 s |
| Ishir | Sever Spirit | 0.1 → 0.625 s |
| Fiorne | Retaliate | counter 0.85 → 1.5 s, cast slowdown 0.33 → 0.5 |

**Victims of displacements** are now locked too:
- `BP_GA_JumpDisplacement` (pulls), `BP_GA_ServerInitiatedDash`, `BP_GA_ShieldGirl_Q_Knockback` (Knightseeker's
  push) and `BluePrints/Abilities/Shared/BP_GA_LaunchCharacter` call `LockAbilities` for the displacement.
- `BP_GA_DisplacementAtLocation` gets `LockoutEffect = BP_GE_LockCastDebuff` (Effect.LockCasts).
- Dec keeps all of it.
- Whether Aug locked victims some other way (`BlockAbilities` is true in both builds) is not confirmed.

## All CC and duration changes per hero (Aug → Feb, Dec)

Values: seconds unless marked. "Heirloom" rows only apply with that item equipped.

### Somnia (BookMage)

| Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| E Allure | `BookMage/Skill4/BP_GA_BookMage_Skill4` (`Make Effect Specs`) | charm → root (`MakeRootEffectSpec(nullptr, CharmDuration)`). Aug used `BP_GE_BookMage_Skill4_Charm` (a `BP_GE_Charm` with a charm VFX cue); that asset is gone | charm `BaseCharmDuration` 0.75, +0.5 empowered | root 1.25, +0.5 (`EmpowerSkill4CharmBonus`) | root 1.25 |
| E Allure, heirloom Glamorfume | same | duration per stack | +0.05/stack, no cap | +0.035/stack, max 15 | +0.05, max 15 |
| E Allure | same | projectile speed / swap-dash speed (swap = heirloom Dreamglass Mirror) | 1250 / 2250 | 3250 / 3000 | as Feb |
| Shift Delirium, heirloom Petunia | `BookMage/E/BP_GA_BookMage_E` (`ActivateAOECharm`) | charm on everyone in the pool | 0.5 | Allure's `CharmDuration` (1.25) | removed |
| R Tethers of Eternity | `BookMage/R/BP_GA_BookMage_RNEw` | ability lock (see above) | cast only | whole ult | none |
| R | same | tether slow / tick total / end damage; end charm 1.5 unchanged | 27.5 % / 120 / 150 | 30 % / 150 / 100 | 60 % / 200 / 150 |
| Passive, heirloom Soul Mine | `BookMage/P/Effects/GrantedAbilities/BP_GA_Charm_Explosion` | charm explosion | 1.5 | 1.5 (via `Data.Stun`) | removed |
| Space Fleeting Fancy | `BookMage/Q/BP_GA_BookMage_Q` | haste duration | 1.0 | 1.5 | 1.5 |

### Brutus (Berserker)

| Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| Shift Earthquake, centre | `Berserker/Skill2/BP_GA_Berserker_Skill2` (`ActivateOnCenterStun`) | stun → root (`MakeRootEffectSpec(nullptr, CenterStunDuration)`); `CenterStunRadius` | stun 1.5, r 150 | root 1.5, r 350 | root |
| Shift Earthquake, first tremor | same (`MakeEffectSpecs`) | unchanged | stun 0.25 | stun 0.25 | 50 % slow 0.5 |
| RMB Head Splitter, full charge | `Berserker/RMB/BP_GA_Berserker_RMB_Slam` | `StunDuration`; charge time | 1.25; 0.5 | 0.8; 0.98–1.1 | 0.8 |
| RMB Head Splitter | same | self anti-CC while charging | anti-displacement | `ApplyUnstoppable` exists (now `BP_GE_AntiCC`) but no caller was found | as Feb |
| E Shackle Drag | `Berserker/Skill4/BP_GA_Berserker_Skill4_Hook` | new on the hooked enemy: `BP_GE_ChannelBlock` 1.15 (can't channel); root 1.2 unchanged | – | added | kept |
| R Unchained Fury, heirloom | `Berserker/Skill3/BP_GA_Berserker_Skill3` | self immunity reworked | AntiRoot + AntiStun per spin | `BP_GE_Generic_Unstoppable` until the ult ends | as Feb |

`Berserker/BP_GE_Berserker_PassiveRoot` (0.7 s root) is gone from the pak. It was only referenced from dead containers
(Brutus' and Rose's): not a live change.

### Ethryn (ShieldGirl)

| Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| Space Knightseeker, wall hit (also heirloom Spiked Targe) | `ShieldGirl/Skill1/BP_GA_ShieldGirl_Skill1` (`Apply Debuffs to Targets`) | stun → root (`MakeRootEffectSpec(self.Player, "Stun Duration")`) | stun 0.75, wall dmg 90 | root 1.5, wall dmg 60 | root 0.85 |
| Space Knightseeker, during the push | same + `Gameplay/Abilities/Shared/BP_GA_ShieldGirl_Q_Knockback` | stun for the rest of the push unchanged; the pushed enemy is now also ability-locked | stun | stun + lock | as Feb |
| Shift Ironclad Slam | `ShieldGirl/Skill2/BP_GA_ShieldGirl_Skill2` (`MakeEffectSpecs`) | base effect | slow 50 % 1.25 + pull into Ethryn + 0.25 s stun | slow 50 % 2.0; no pull or stun in the code (the tooltip still says "pulled") | slow 45 % 2.0 |
| Shift, heirloom Vortex Pauldrons | same | slow → root (`MakeRootEffectSpec(self.Player, SlowDuration)` when `HasVacuumItem` is false) | flip + slow 1.25 | root 2.0 | slow |
| Passive Pummel (3 stacks) | `ShieldGirl/Passive/BP_GA_ShieldGirl_P` (`BaseStunDuration`), `ShieldGirl/LMB/BP_GA_Bashed` | stun | 0.75 | 0.4 | 0.4 |
| Passive, heirloom Titan's Effigy | same (`ItemBashIncreasedStunDuration`) | stun | 1.25 | 0.7 | 0.7 |
| R Eagle's Descent, heirloom Starfall | `ShieldGirl/ULT/BP_GA_ShieldGirl_Skill3` | multi-hit stun (base stun 1.0 unchanged) | 1.75 | 1.5 | 1.5 |

### Fiorne (Lancer)

| Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| Shift Hiari Smash, heirloom Earthbreaker Pommel | `Lancer/Skill2/BP_GA_Lancer_Skill2` (`Activate Dehabilitating Hop`) | stun → root (`MakeRootEffectSpec(self.Player, DHRootDuration)`) | stun 1.0, +125 dmg | root 1.5, +40 dmg | fading slow |
| R Grand Finale | `Lancer/Skill3/BP_GA_Lancer_R_KnockUp` | new: the knocked-up target's casts are cancelled (`CancelAbilitiesWithTag`) | – | added | kept |

E Spear Throw is unchanged: the wall pin is a stun in every build, although the tooltip says "rooted".

### Astrada (FireMage)

| Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| Shift Flame Cage | `FireMage/E/BP_GA_Firemage_E` | stun → root (`MakeRootEffectSpec(nullptr, ModifiedStunTime)`; CDO `StunEffectClass` Stun → Root) | stun 1.0, cage 3 | root 1.25, cage 2 | stun 1.2 (E key) |
| Shift, heirloom Royal Detonator | same | new slow when the cage ends | – | 30 % 2.0 | kept |
| RMB Blast Wave, heirloom Repulsing Scepter | `FireMage/RMB/BP_GA_FireMage_RMB` (`Activate RMBKnockback`) | wall hit: stun → root (`MakeRootEffectSpec(nullptr, RMBKnockbackItemStunDuration)`) | stun 0.5 | root 1.5 | fading slow |
| Passive, heirloom Nail Bomb | `FireMage/Passive/BP_GA_FireMage_P` | slow | 50 % 1.0 | 40 % 1.0 | 40 % 2.5 |

### Zoey & Boo (CatSupp)

| Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| E Spirit Scratch | `CatSupp/Skill4/BP_GA_CatSupp_Skill4` | stun → root (`MakeEffectSpecs`: `MakeRootEffectSpec(nullptr, "Stun Duration")`; heirloom hit-extension paths: `(self.Player, …)`) | stun 0.9 | root 1.3 | root 1.0 |
| R Feline Attraction | `CatSupp/Skill3/BP_GA_CatSupp_Skill3` | knock-up / stun (`BaseKnockUpDuration`, `BaseUltStunDuration`) | 1.0 / 1.0 | 1.75 / 1.5 | 1.75 / 1.5 |
| Space Duoblast | `CatSupp/Skill1/BP_GA_CatSupp_Skill1` | slow | 35 % 1.5 | 30 % 1.0 | 30 % 1.0 |
| Shift Bell Blare | `CatSupp/Skill2/BP_GA_CatSupp_Skill2` (was `…Skill2Knockback2`) | knockback 425 uu unchanged; new heirloom slow (Purr's Paw 60 % 2) | – | added | 30 % 3 |

### Rowan (WoodenSword): reworked into new assets, same names and keys

| Ability | Asset (Aug → Feb) | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| Space Dourling Dive | `WoodenSword/Q/BP_GA_WoodenSword_Q` → `WoodenSword/Skill1/BP_GA_WoodenSword_Skill1` (`MakeAOEEffect`) | stun → root (`MakeRootEffectSpec(nullptr, StunDuration)`) | stun 0.75 | root 1.0 | root 1.0 |
| Space Dourling Dive | same | self Unstoppable at dash start | yes | `ApplyUnstoppable` never called | only on Overgrowth |
| LMB Glade Slash | `WoodenSword/LMB/BP_GA_WoodenSword_LMB` | ability lock while LMB is held | – | added | removed |
| LMB, heirloom Siegil's Rootblade | same (`SiegilsBladeRootDuration`, `…RootICD`) | root / per-target cooldown | 0.7 / 5 | 1.25 / 10 | 0.7 / 10 |
| E Sourblossom, Shift Wall of Roots, R Nature's Fury | `Skill4/…`, `E → Skill2`, `Ult → Skill3` | no CC change (Sourblossom slow 90 → 20 % fading over 3 s, Tangleroot root 0.75 unchanged) | | | |

### Belroth (BigBoi)

| Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| E Boulder Toss | `BigBoi/Skill4/BP_GA_BigBoi_Skill4` | root duration (`RootDuration`; Aug `SlowDuration`) | root 0.75 | root 1.2 | stun 0.8 |
| Space Vicious Lunge | `Characters/Bigboi/Gameplay_Abilities/Skill1/BP_GA_BigBoi_Skill1` | knock-up + stun `StunDuration`; heirloom Uprooters `FTDuration` | 0.8; 1.2 | 0.4; 0.7 | 0.4; 0.85 |
| Shift Slam | `BigBoi/Skill1/BP_GA_BigBoi_Skill2` | slow 50 %, `SlowDuration` | 1.0 | 2.0 | reworked |
| R Roar, heirloom Rage of Remembrance | `Characters/Bigboi/Gameplay_Abilities/Skill3/BP_GA_BigBoi_Skill3` | fear `SUDMaxDuration` (base fear 1.5 unchanged) | 2.25 | 3.0 | 3.0 |

### Yanari (BattleMonk), Tufts (Sidekick)

| Hero | Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|---|
| Yanari | RMB Hand of Acara (empowered) | `BattleMonk/RMB/BP_GA_BattleMonk_RMB` | stun `StunDuration` | 1.0 | 0.5 | 0.5 |
| Yanari | E Divine Comet, heirloom Cleansing Shankha | `BattleMonk/Skill4/BP_GA_BattleMonk_Skill4` | ally anti-stun `ImmunityDuration` | 1.5 | 0.1 | 0.1 |
| Yanari | LMB, heirloom Pauper's Prayer | `BattleMonk/LMB/BP_GA_BattleMonk_LMB` | slow | 40 % 1.75 | 50 % 1.5 | 25 % 1.0 |
| Tufts | Space Wing Dive | `SideKick/Skill1/BP_GA_Sidekick_Skill1` | stun by charge (`Min Stun` + charge × extra) | 0.5–1.2 | 0.3–0.7 | 0.5–1.0 |
| Tufts | RMB Sky Smack | `SideKick/RMB/BP_GA_Sidekick_RMB` | `KnockbackDistance` | 300 | 750 | 750 |
| Tufts | E Spit | `SideKick/Skill4/BP_GA_Sidekick_Skill4_New` | slow | 25 % | 50 % | 50 % |

### Rayo, Ishir, Kiona, Rose, Wylde

| Hero | Ability | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|---|
| Rayo | RMB Flashbolt | `LightningArcher/RMB/BP_GA_LightningArcher_RMB` | stun `StunDuration` (heirloom Twilight Sandals `BonusStunDuration`) | 0.8 (+0.15) | 0.5 (+0.2) | 0.5 (+0.6) |
| Rayo | R, heirloom Harah's Betrayal | `LightningArcher/R/BP_GA_LightningArcher_R` | distance-scaled stun `RSMinStun`–`RSMaxStun`, `RSMaxRange` | 0.5–2.5, 5000 uu | 0.4–0.8, 2500 uu | 0.4–0.8 |
| Rayo | E Thunder Blast, heirloom Shardburst Belt | `LightningArcher/Skill4/BP_GA_LightningArcher_Skill4` | stun when 2 enemies are hit `GS2ManStunDuration` | 0.75 | 1.0 | 1.25 |
| Rayo | Shift Lightning Strike | `LightningArcher/E/BP_GA_LightningArcher_E_` | new fading slow (`SlowdownPercentage`) | – | 25 % 1.5 | kept |
| Ishir | Space Spectral Dash | `BackStab/Skill1/BP_GA_Backstab_Skill1` | incapacitate `Base IncapDuration` | 0.75 | 2.0 | 1.5 |
| Ishir | E Ghostly Flicker, new heirloom Ishala's Amulet | `BackStab/Skill4/BP_GA_Backstab_Skill4` | incapacitate on the attacker `ItemFlashbangDuration` | – | 1.0 | changed |
| Kiona | Passive Frostwalker | `IceMage/P/BP_GA_IceMage_P_Chill` | immunity after a freeze `ChillCooldown`; freeze 1.2 unchanged | 4.0 | 3.0 | 8.0 |
| Kiona | Space Vital Freeze, heirloom Cyclone Generator | `IceMage/Q/BP_GA_IceMage_Q` | pull → knock-up (`DoTargetKnockUp`, 0.3) | pull 0.3 + stun 0.3 | knock-up 0.3 + stun 0.3 | knock-up 0.6 |
| Kiona | Shift Polar Pull, heirloom Winterclaw Choker | `IceMage/E/BP_GA_IceMage_E` | stun `ChokerStunDuration` | 0.4 | 0.5 | – |
| Rose | E Desecrate | `DemonGirl/Skill4/BP_GA_DemonGirl_Skill4` | slow `SlowPercent` (grounding unchanged; the Feb tooltip still says 20 %) | 20 % | 35 % | 35 % |
| Wylde | Shift, heirloom Balthazar's Lasso | `Gunslinger/E/BP_GA_Gunslinger_E` | new slow `SHPercent`, `SHDuration` | – | 60 % 1.0 | 45 % 2.0 |
| Wylde | Space Devilstep | `Gunslinger/Q/BP_GA_Gunslinger_Q` | the dash now ends when rooted, stunned or displaced | – | added | kept |

### Boons, artifacts and shared systems

| Item / system | Asset | Change | Aug | Feb | Dec |
|---|---|---|---|---|---|
| Cleanse (boon) | `Items/Characters/Generic/Actives/Cleanse/BP_GA_ActiveCleanse` | anti-CC after cleansing `Anti CC Duration` | 1.5 | **0.1** | 0.1 |
| Time Out (boon) | `…/Actives/TImeOut/BP_GA_TimeOut` | polymorph + invulnerable `Duration` | 3.0 | 1.5 | 1.5 |
| Venom (boon) | `…/Actives/Poisonivy/BP_GA_PoisonIvyCast` | lingering effect | 2.0 | 1.0, needs `State.InBrush` | 1.0 |
| Regicide Totem | `Items/Characters/Generic/Garden/Revolution/BP_GA_RegicideTotem` | slow → armour reduction | slow 2 | none | none |
| Fire Cannon (map) | `Gameplay/Abilities/Shared/BP_GA_FireCannon` | reworked; Suppressing Fire grounding gone | grounded 2.5 + slow 10 % | slow 10 % 2.5 | as Feb |
| All root-motion dashes and displacements | ~25 abilities (`AbilityTask_ApplyRootMotionJumpForce`) | `VelocityOnFinishMode` 1 → 0 (bytecode constant) | stop dead at the end | keep momentum | 0 |
| Cast tasks | `MOBAWaitCastTime` callers | new `SubtractRoundTripTime` = true (netcode compensation) | – | most abilities | – |

## The revert as built: a patch pak (15 Oct)

**The user's decisions (15 Oct):**
- Revert the stun/charm → root conversions and Somnia's ult lock. Duration changes elsewhere stay as they are for now.
- The changes must be permanent once validated, so the game's own data is changed and runtime hooks are not used.
- Nothing is deployed before the user has tested it locally.

How it is done: `tools/patch/patches/ccrevert.json`, built into `FangsCE_P.pak` for players and servers alike
(`docs/PATCHING.md`). The A–D mechanisms below were the server-only plan and are not used.

| Change | Edit in the asset |
|---|---|
| Somnia, Allure | call `MakeRootEffectSpec` → `MakeCharmEffectSpec`; `BaseCharmDuration`/`CharmDuration` 1.25 → 0.75; Glamorfume `CCStackDurationIncrease` 0.035 → 0.05 |
| Somnia, ult | `PreCastLock`: `LockAbilities(0.0)` → `LockAbilities(0.5)`, so the lock covers the 0.5 s cast (`CastTime`), not the tether |
| Brutus, Earthquake centre (augment Quakebreak Talisman) | → `MakeStunEffectSpec`; `CenterStunRadius` 350 → 150 |
| Ethryn, Knightseeker wall | → `MakeStunEffectSpec`; `Stun Duration` 1.5 → 0.75 |
| Fiorne, Earthbreaker Pommel | → `MakeStunEffectSpec`; `DHRootDuration` 1.5 → 1.0 |
| Astrada, Flame Cage | → `MakeStunEffectSpec`; `StunEffectClass` `BP_GE_Root_C` → `BP_GE_Stun_C` (the cage's hit effects use it too); `StunDuration` 1.25 → 1.0; `CageDuration` 2 → 3 |
| Astrada, Repulsing Scepter | → `MakeStunEffectSpec`; `RMBKnockbackItemStunDuration` 1.5 → 0.5 |
| Zoey, Spirit Scratch | → `MakeStunEffectSpec` on all three hit paths; `Stun Duration` 1.3 → 0.9; the hit-extension heirloom path's target from Zoey herself to the enemy hit |
| Rowan, Dourling Dive | → `MakeStunEffectSpec`; `StunDuration` 1.0 → 0.75 |
| Rowan, Glade Slash (LMB) | both swings' `LockAbilities(0.0)` → `LockAbilities(0.01)`: no lock while LMB is held (Aug had none; Dec removed it) |
| Charm visual | `BP_GE_Charm` gets `GameplayCue.BookMage.Skill4.CharmVFX` (Aug Allure's), see below |
| Tooltips | "roots" → "stuns" in the 8 texts listed below |

**Tested** with `tools/run/test_patch.sh` (15 Oct): each run was done with the pak and once more without it as the
control. The game server logs the effects on both heroes.

| What | Control (Feb) | Patched |
|---|---|---|
| Patched class defaults loaded by the server, alice and bob | 0/11 | 11/11 |
| Allure on Rowan | `BP_GE_Root` 1.3 s | `BP_GE_Charm` 0.75 s |
| Dourling Dive on Brutus | `BP_GE_Root` 1.1 s | `BP_GE_Stun` 0.75 s |
| Somnia's ult: `BP_GE_LockAbilities` on Somnia | 3.2 s | 0.5 s |
| Rowan's LMB: `BP_GE_LockAbilities` on Rowan | 0.4 s | none |

Earthquake's centre, Ethryn, Fiorne, Astrada and Zoey haven't been seen in a match yet. They use the same edits,
and their values are loaded. The test's Earthquake only hit with the first tremor (0.25 s stun, unchanged): the centre CC needs the Quakebreak Talisman augment.

**Augments that interact with the reverted CC** (code review of the Feb build, 15 Oct; no test):

| Augment | How it works | With the patch |
|---|---|---|
| Petunia (Somnia, Shift) | Delirium checks each enemy it damages for `State.Charm`. If found, it charms everyone in the pool for Allure's `CharmDuration` (0.5 s if Somnia has no Allure); `Effect.BookMage.Skill2.AOECCApplied` stops it triggering itself | works: Allure's charm grants `State.Charm` |
| Soul Mine (Somnia, passive) | The passive watches every effect Somnia applies to a target (`OnGameplayEffectAppliedToTargetDel`, `Detect Giving Fear and Charm`). Any effect granting `State.Charm` raises `OnCharmGranted`. Soul Mine then deals % max HP damage and marks the enemy for the charm's duration; dying in that window explodes and charms nearby enemies for `SoulMineDuration` (1.5 s) | works, and Allure triggers it again (Feb's root didn't) |
| Glamorfume (Somnia, E) | Each Allure hit stacks `BP_GE_BookMage_CCStack_Stack` on Somnia. Each cast, `CharmDuration` = `BaseCharmDuration` + stacks × `CCStackDurationIncrease` (max 15) | works: 0.75 s + 0.05 s per stack |
| Dreamglass Mirror, Piercing Butterfly (Somnia, E) | Based on hits (dash to the first enemy hit; the projectile pierces) | work; every enemy pierced is charmed |
| Relic of Calamity, Paralyzing Specter (Somnia, ult) | The ult's own charm and lock | not affected |
| Fiorne, Spear Throw "+2 Bunny Stacks if rooted" | Only in the tooltip: `BP_GE_Lancer_MoreBunnyStacks` is referenced by no code, and Spear Throw and the passive check no CC tags | not affected |

Nothing else checks a target for `State.Charm`, `State.Stun` or `State.Rooted` (apart from a tutorial bot), and no code
checks a target's movement or cast locks.
- Some dashes end when their caster gets rooted (Ishir, Wylde, Tufts, Astrada's Space, Scythe). They are about the
  caster, not about augments.
- `GA_State_Listener` handles root, stun and grounded alike.

Two client-side differences from Aug that the review found, now fixed in the patch (user, 15 Oct):
- **Charm visual.**
  - The generic `BP_GE_Charm` had no gameplay cue, so Allure's charm showed nothing on the target (Petunia's and
    Soul Mine's charms look that way in Feb).
  - Aug's Allure used `BP_GE_BookMage_Skill4_Charm`, with cue `GameplayCue.BookMage.Skill4.CharmVFX`. Feb deleted
    that effect, but the cue (`BP_GC_BookMage_Skill4CharmVFX`, a `GameplayCueNotify_Actor` spawning
    `NS_Somnia_Skill4_Charmed`) and its tag are still in the game.
  - The patch gives `BP_GE_Charm` that cue (`copy-default` from the ult charm's `GameplayCues`, tag renamed).
  - Only Somnia's charms use `BP_GE_Charm`: Allure, Petunia and Soul Mine. The ult's charm
    (`BP_GE_BookMage_Skill3_Charm`) sets its own cues and keeps them.
- **Tooltips that said "roots"** now say stun (`replace-text` in the `LOC_EN_*` string tables). Changed:
  - Spirit Scratch, Dourling Dive, Knightseeker, Flame Cage;
  - Quakebreak Talisman, Earthbreaker Pommel, Spiked Targe (and an unused Ethryn row with the same text).
  - Already right: Allure, Repulsing Scepter, and the short help texts (`LOC_EN_ABILITIES_F1`).
  - Vortex Pauldrons still roots.

**Brutus' Earthquake centre is the Quakebreak Talisman augment.** `ActivateOnCenterStun` is only bound in
`Apply Items Pre Cast`, and the augment's text is "enemies caught in the center … are rooted". The tables above call
it Earthquake's centre.

**Findings while building it:**
- **The calls are by name.** Every `Make…EffectSpec` call is an `EX_VirtualFunction` on the library's default object,
  not an import, so swapping root for stun only changes the called name.
- **Zoey's hit-extension heirloom bug.** That path (new in Feb) applied the root to `self.Player`, which is Zoey
  herself, and not to the enemy it had just damaged. Dec applies it to the enemy (`CallFunc_Array_Get_Item`). A
  plain root → stun swap would have stunned Zoey, so the patch also retargets that call to the enemy, as in Dec.
- **Ethryn's Vortex Pauldrons stays a root.** The Aug heirloom was a flip behind Ethryn plus a slow, and the flip code
  is gone. A revert would leave an heirloom that does nothing extra: with the item, `HasVacuumItem` is set to false,
  which picks the root branch, while without it the base slow applies.
- **Somnia's other self-lock is unchanged.** `Activate Tether Lock` (a `TetherLockDuration` 2.5 s
  `BP_GE_LockAbilities`) belongs to the heirloom `Item.BookMage.TetherLock` and is the same in all three builds.
- **Petunia follows Allure's charm duration.** It charms again, now from Allure as well, for 0.75 s (Aug 0.5 s).

## Reverting on our server (first plan, not used)

All gameplay effects are made and applied on the game server: spec creation, projectile hits, GE application. A
FangsHost-only change therefore changes what players get hit by.

Clients keep the Feb numbers for:
- tooltips (computed from the client's own ability defaults);
- their own predicted movement and cast timing.

So revert only CC types and durations on the server. Don't change cast times, projectile speeds or dashes there:
those are predicted by the casting client and would desync.

### Mechanisms

**A. Default overrides (durations, slows, radii).**
- Set the value on the class default object: `StaticFindObject("<path>.Default__<Class>_C").<Property> = v`.
  Properties with spaces work as `cdo["Stun Duration"]`.
- Abilities are `InstancedPerActor`: an instance copies the defaults when the ability is granted (hero spawn). The
  `Base…`/`Modified…` pairs are re-derived from the base value in `ResetAbilityAttributes`, so always set the base
  value.
- When: in the arena game mode's BeginPlay pre-hook, deferred as `shards.lua` does. Load each class first
  (`LoadAsset_Blocking`, see `loadClass` in `shards.lua`), then set. This runs once per match, before anyone's hero
  spawns.
- Rules: no object scans; nothing runs during the match. It runs at every arena BeginPlay, so a class reloaded for
  a later match gets the values again.
- Feasibility high, risk low. Effort: the table below is about 2 h of Lua; testing is extra.

**B. GE class swap (root → stun/charm).** Every converted call site goes through
`BP_FL_MOBA_FunctionLibrary.MakeEffectSpec`, which takes one of two native paths:
- **Instigator `nullptr`** (Allure, Earthquake, Flame Cage, Repulsing Scepter, Spirit Scratch main hit, Dourling
  Dive): `self:MakeOutgoingGameplayEffectSpec(BP_GE_Root_C, 1.0)` on the ability (native
  `/Script/GameplayAbilities.GameplayAbility:MakeOutgoingGameplayEffectSpec`).
  - Pre-hook: `if self:GetClass() == <GA class> and GameplayEffectClass == BP_GE_Root_C then
    GameplayEffectClass:set(<Stun or Charm>)`.
  - The duration is still set afterwards through `Data.Duration`, which Stun and Charm read the same way.
- **Instigator `self.Player`** (Knightseeker, Earthbreaker Pommel, Spirit Scratch heirloom paths):
  `ASC:MakeOutgoingSpec(BP_GE_Root_C, 0, ctx)` on the caster's ASC (native
  `/Script/GameplayAbilities.AbilitySystemComponent:MakeOutgoingSpec`).
  - The ability is not known here. Only when the class is `BP_GE_Root_C` (rare), walk the ASC's
    `ActivatableAbilities.Items` (≈10 entries; no object scan) and swap if a listed ability has `ActiveCount > 0`.
  - Neither hero has another root source of her own.
- Somnia: use `BP_GE_BookMage_Skill3_Charm_C`. It is a `BP_GE_Charm` with a charm VFX cue, the closest to the deleted
  Aug asset. The charm walks the target to the effect causer, which `MakeOutgoingGameplayEffectSpec` sets to Somnia.
- Rules: native hooks only read properties and set the parameter. No Blueprint calls, no scans.
- Cost: a Lua callback on every spec the server makes (a few hundred per second in a 12-hero fight). Measure with
  `tools/run/test_perf.sh`.
- **Unverified:** that this UE4SS build applies a parameter `:set()` in a pre-hook of a native function called
  from Blueprint bytecode. Its DLL steps the bytecode frame for native hooks ("unable to Step frame" message), which
  suggests yes. FangsHost has no native hook yet; prove it first with a 1-hour test.
- Feasibility medium-high, risk medium. Effort ½ day once the test passes.

**C. Somnia's ult lock.**
- Post-hook the Blueprint function `BP_GA_BookMage_RNEw_C:Remove Slows`, which runs at the cast event and gives
  Aug timing.
- In it, defer `ExecuteInGameThreadWithDelay(1, …)` to `ga:UnlockAbilities()` (native, BlueprintCallable) if the
  ability is still active.
- Hooking `PreCastLock` instead would give Dec behaviour (no lock at all).
- Only well-tested mechanics: a Blueprint post-hook plus a deferred native call.
- The hero's classes aren't loaded at boot. Register the hook in the same deferred match-start step as A, after
  loading the class. Native hooks (B) can be registered once at startup.
- The lock tag comes from a replicated GE, so a server-side unlock should also free the client's input. Check with 2
  players. If the client still blocks, the same hook goes into FangsBoot (player update).
- Rowan's LMB and Tufts' LMB holds could be lifted the same way (post-hook the swing, defer `UnlockAbilities`), but
  that also lets players cast mid-swing, which Aug didn't fully allow for Tufts.
- Feasibility high, risk low. Effort 1–2 h.

**D. Fallback if B fails: a server-only patch pak.**
- Rename the import `MakeRootEffectSpec` → `MakeStunEffectSpec`/`MakeCharmEffectSpec` in each affected ability (same
  signature in the same library, so the bytecode is untouched). Use UAssetAPI (as in BpDump).
- Pack the result into an unencrypted `_P` pak in the server's instance view. The game ships no `.sig` file, so extra
  paks are most likely not signature-checked (test).
- Generate it at deploy from the server's own game files; it must never be committed.
- The ability's replicated layout doesn't change.
- Feasibility medium, risk medium (needs a pak writer for v11, e.g. repak). Effort 1½–2 days.

### Per change

Switch it all with one backend record (e.g. `CECCRevert`, like `CEOldShards`), with per-group flags.

| Change | How | Values (Feb → Aug) |
|---|---|---|
| Somnia Allure | B (ability path, `BP_GA_BookMage_Skill4_C`: Root → `BP_GE_BookMage_Skill3_Charm_C`) + A | `BaseCharmDuration` 1.25 → 0.75. This also brings Petunia from 1.25 to 0.75 (Aug 0.5). Glamorfume `CCStackDurationIncrease` 0.035 → 0.05 |
| Somnia ult lock | C | – |
| Brutus Earthquake centre | B (ability path, `BP_GA_Berserker_Skill2_C`: Root → Stun) + A | `CenterStunRadius` 350 → 150 |
| Ethryn Knightseeker wall | B (ASC path, `BP_GA_ShieldGirl_Skill1_C` active: Root → Stun) + A | `Stun Duration` 1.5 → 0.75 |
| Ethryn Vortex Pauldrons | Set `HasVacuumItem` = true on the instance (post-hook on its item setup) so the Feb slow branch runs + A | `SlowDuration` 2.0 → 1.25 (also the base slow, as in Aug). The Aug flip can't be restored |
| Fiorne Earthbreaker Pommel | B (ASC path, `BP_GA_Lancer_Skill2_C` active: Root → Stun) + A | `DHRootDuration` 1.5 → 1.0 |
| Astrada Flame Cage | A (`StunEffectClass` = `BP_GE_Stun_C` covers `SetStunTimeForAbility`) + B (ability path, `BP_GA_Firemage_E_C`) | `StunDuration` 1.25 → 1.0, `CageDuration` 2 → 3 |
| Astrada Repulsing Scepter | B (ability path, `BP_GA_FireMage_RMB_C`) + A | `RMBKnockbackItemStunDuration` 1.5 → 0.5 |
| Zoey Spirit Scratch | B (both paths, `BP_GA_CatSupp_Skill4_C`) + A | `Stun Duration` 1.3 → 0.9 |
| Rowan Dourling Dive | B (ability path, `BP_GA_WoodenSword_Skill1_C`) + A | `StunDuration` 1.0 → 0.75. The Aug Unstoppable needs a deferred `ApplyUnstoppable()` call (optional) |
| Shortened CC (Feb nerfs) | A | Brutus `BP_GA_Berserker_RMB_Slam.StunDuration` 0.8 → 1.25 · Ethryn `BP_GA_ShieldGirl_P.BaseStunDuration` 0.4 → 0.75, `ItemBashIncreasedStunDuration` 0.7 → 1.25 · Rayo `BP_GA_LightningArcher_RMB.StunDuration` 0.5 → 0.8, `BonusStunDuration` 0.2 → 0.15, `BP_GA_LightningArcher_R.RSMinStun`/`RSMaxStun`/`RSMaxRange` 0.4/0.8/2500 → 0.5/2.5/5000 · Yanari `BP_GA_BattleMonk_RMB.StunDuration` 0.5 → 1.0, `BP_GA_BattleMonk_Skill4.ImmunityDuration` 0.1 → 1.5 · Belroth `BP_GA_BigBoi_Skill1.StunDuration` 0.4 → 0.8, `FTDuration` 0.7 → 1.2 · Tufts `BP_GA_Sidekick_Skill1."Min Stun"` 0.3 → 0.5, `"Extra Stun From Charge"` 0.4 → 0.7 · Kiona `BP_GA_IceMage_P_Chill.ChillCooldown` 3 → 4 · Rowan `SiegilsBladeRootICD` 10 → 5 · Cleanse `BP_GA_ActiveCleanse."Anti CC Duration"` 0.1 → 1.5 · Time Out `BP_GA_TimeOut.Duration` 1.5 → 3 |
| Lengthened CC (Feb buffs) | A, if the group wants Aug balance | Belroth `BP_GA_BigBoi_Skill4.RootDuration` 1.2 → 0.75, `BP_GA_BigBoi_Skill2.SlowDuration` 2 → 1, `BP_GA_BigBoi_Skill3.SUDMaxDuration` 3 → 2.25 · Zoey `BP_GA_CatSupp_Skill3.BaseKnockUpDuration`/`BaseUltStunDuration` 1.75/1.5 → 1/1 · Ishir `BP_GA_Backstab_Skill1."Base IncapDuration"` 2.0 → 0.75 · Rayo `GS2ManStunDuration` 1.0 → 0.75 · Rowan `SiegilsBladeRootDuration` 1.25 → 0.7 · Rose `BP_GA_DemonGirl_Skill4.SlowPercent` 0.35 → 0.2 · Kiona `ChokerStunDuration` 0.5 → 0.4 · new slows off: Rayo Lightning Strike `SlowdownPercentage` → 0, Wylde `SHPercent` → 0, Astrada `RoyalDetonatorSlow` → 0 |

Don't set a duration to 0 to turn something off: a 0-duration effect never expires (see the ult lock). Zero the
magnitude instead.

Rough effort for the whole revert:

| Step | Effort |
|---|---|
| UE4SS native-hook test | 1 h |
| Lua module (`FangsHost/scripts/ccrevert.lua`, loaded like `shards.lua`) with A + B + C and the switch | ½–1 day |
| Tests: every converted ability in a 2-player match (`tools/run/test_join.sh`: CC tags on the target via `ASC:HasMatchingGameplayTag`), plus a `test_perf.sh` run | 1 day |
| Optional FangsBoot pass so tooltips show the reverted numbers (same overrides, client side) | ½ day + a player update |

### Not revertible (or not worth it)

- **Ethryn's Ironclad Slam:** the Aug pull and its 0.25 s stun are gone from the code, as is the Vortex Pauldrons
  flip.
- **Kiona's Cyclone Generator:** the Aug pull was a gameplay event sent to each enemy. It could be re-sent from Lua
  (deferred), but that is medium effort for one heirloom.
- **Dash momentum** (`VelocityOnFinishMode`): this is client-predicted root motion. A server-only change
  rubber-bands the caster. It needs a client patch (native pre-hook on
  `AbilityTask_ApplyRootMotionJumpForce:ApplyRootMotionJumpForce` in FangsBoot too). Not recommended.
- **New locks on displacement victims, Fiorne's ult cancel, Wylde's LockCasts blocks, Brutus' channel block:** all
  code. Possible with more hooks, low value. Wylde's change looks like a bug fix.
- **Brutus' Head Splitter** charge-time rotation lock and anti-CC: code, and charge timing is client-predicted.

### Open questions

- Which groups to revert: root conversions plus the ult lock only, or also the shortened and lengthened CC
  durations? The developers kept most of these in Dec (the ult lock was the exception).
- Does the UE4SS pre-hook parameter swap work? Mechanism B depends on it; D is the fallback.
- **Brutus' Head Splitter:** does it still apply its anti-CC while charging? No caller of `ApplyUnstoppable` was
  found in Feb.
- **Ethryn's Ironclad Slam:** is there a pull outside the ability (the tooltip says so)?
- Is Knightseeker's wall root applied while her Skill1 is still active (needed by the ASC-path swap)?
- Did Aug lock displacement victims some other way?
