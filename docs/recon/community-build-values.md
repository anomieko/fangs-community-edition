# Community patch, part 1: values, texts and knock-ups (built 16 Oct)

What Sheepa OK'd in the second PDF (`docs/recon/community-patchnotes.md`, "The proposal"), as far as it is numbers,
texts and one effect swap. All of it is in `tools/patch/patches/community.json` (`"enabled": false`), built on top of
`ccrevert` and `fiorne` (`tools/patch/build.sh <game> ccrevert fiorne community`). Other parts of the community patch
(Rowan, Rush, Belroth's dash, Stormlense, Ethryn's shield, Lamblaster, Astrada, Zoey's ult VFX, Ishir, training,
lobby, base blockers, presets, artifacts) are built on other branches.

Every starting value was read from the Feb assets first (`AssetPatch info`) and matched the proposal.

## Edits

Asset paths are under `MOBA/Content/Gameplay/Abilities/Player/` unless they start with another folder.

| Who | What | Asset: value | From → to |
|---|---|---|---|
| Rose | Klaive's Puzzlebox | `DemonGirl/Q/BP_GA_DemonGirl_Q_Instant`: `TPDamage` | 50 → 75 |
| Wylde | Brim (LMB) | `Gunslinger/LMB/BP_GA_Gunslinger_LMB`: `AbilityDamage`, `ModifiedAbilityDamage` | 35 → 40 |
| Wylde | Blight (RMB) | `Gunslinger/RMB/BP_GA_Gunslinger_RMB`: damage (both) / `Range` / `ModifiedRange` / `AbilityCooldown` | 65 → 95 / 932 → 562.5 / 950 → 562.5 / 0.5 → 1.0 (`ModifiedAbilityCooldown` already 1.0; 1 ammo, hold-to-fire and projectile speed unchanged) |
| Wylde | Bounty's Reward | `Gunslinger/E/BP_GA_Gunslinger_E`: `MaxAmmoIncrease Stack Count Required`; `Gunslinger/E/Items/BP_GE_Gunslinger_Skill2_MaxAmmoIncreaseStack`: `StackLimitCount`; tooltip `gunslinger_maxammoincrease_desc` | 35 → 30 (both); "lands 35 bullets" → "lands 30 bullets" |
| Wylde | Speedshine | `Gunslinger/Passive/BP_GA_Gunslinger_P`: `ReloadSpeedBoostPercentageSpeedUp` | 0.1 → 0.2 |
| Ethryn | Talon Strike (LMB) | `ShieldGirl/LMB/BP_GA_ShieldGirl_LMB`: `FirstAttackDamage` / `SecondAttackDamage` / `ShieldAttack Damage` | 50 / 50 / 55 → 40 / 40 / 50 |
| Ethryn | Holy Brazier | `ShieldGirl/Skill4/BP_GA_ShieldGirl_Skill4`: `ItemPrecisionShieldAbilityCooldown` / `…MaxShieldLifetime` | 2 → 4 / 0.75 → 1 |
| Brutus | base health | `Gameplay/Effects/Player/Berserker/BP_GE_Berserker_Stats`: `Modifiers[0]` (MaxHealth, Override) `…ScalableFloatMagnitude.Value` (`set-export-prop`) | 950 → 1050 |
| Zoey | Witch Ball (LMB) heal | `CatSupp/LMB/BP_GA_CatSupp_LMB`: `BaseHealPerTick` (and the stale CDO copy `ModifiedHealPerTickToApply` 8 → 5; `ResetAbilityAttributes` sets it from the base) | 4 → 5 |
| Zoey | Witch Ball tooltip | `UI/Localization/LOC_EN_ABILITIES_CATSUPP` `catsupp_basicattack_desc` | `$BaseHealPerTick*12$` → `$BaseHealPerTick*10$` (shows 50) |
| Zoey | Shield of Hope (RMB) | `CatSupp/RMB/BP_GA_CatSupp_RMB`: `Base Shield Amont`, `ModifiedShieldAmount` / `Shield Duration` | 45 → 50 / 1.5 → 2 |
| Zoey | Shieldnip | `CatSupp/Skill2/BP_GA_CatSupp_Skill2`: `AOESDuration` (shield `AOEShield` 125 stays) | 0.75 → 1.5 |
| Zoey | Mentor's Locket | `CatSupp/Skill3/BP_GA_CatSupp_Skill3`: `AVHealPerEnemy` | 35 → 75 |
| Zoey | ult tooltip | `catsupp_ult_desc`: the hard-coded "200 HP" | → `$AV Heal$ HP` (150, the real heal; spaced variable names like `$Shield Duration$` already work in this table) |
| Rayo | Pinpoint Spotter | `LightningArcher/RMB/BP_GA_LightningArcher_RMB`: `BonusDamage` | 75 → 50 |
| Rayo | Storm Shot (LMB) | `LightningArcher/LMB/BP_GA_LightningArcher_LMB`: `CastTime` / `AbilityCooldown` / `ModifiedAbilityCooldown` (stale CDO; `ResetAbilityAttributes` copies the base) | 0.45 → 0.25 / 0.25 → 0.45 / 0.5 → 0.45 |
| Rayo | Blitzhead Arrows | same asset: `DeathstrikeMaxStacks`; in `ActivateDeathstrikeMissEffect` the health check `Greater_FloatFloat(health, damage)` becomes `Greater_FloatFloat(damage, damage)` (`set-call-arg`, a local for a local), so no self-damage spec is ever made | 60 → 35; self-damage off |
| Rayo | Blitzhead tooltip | `LOC_EN_AUGMENTS_LIGHTNINGARCHER` `LightningArcher_BlitzheadArrows_desc` | the "Missing with … deals … damage to Rayo." sentence removed |
| Belroth | Angerstone Talons | `BigBoi/Skill1/BP_GA_BigBoi_Skill2`: `ODMagnitude` (the Shift damage with the item; base `AbilityDamage` 70) | 60 → 110 (+40) |
| Belroth | Craterthorns | `BigBoi/Skill4/BP_GA_BigBoi_Skill4`: `PUDMagnitude` | 40 → 50 |
| Somnia | Tethers of Eternity (R) | `BookMage/R/BP_GA_BookMage_RNEw`: `Tick Frequency` (the tick loop's `WaitDelay`, each tick's slow length, and the damage split `Max Duration / Tick Frequency`); `ATTickHeal` (AllyTether, per tick) | 0.1 → 0.25; 3.3333 → 8.3333 (same total). `TickRate` 0.25 isn't read by this ability |
| Shards | Green (Life) | `Gameplay/Effects/Shared/BP_GA_GreenBuffHoT`: `Duration` | 5 → 0.25 |
| Shards | Blue (Aether) | `Gameplay/Effects/Shared/BP_GA_ManaFill`: `ManaPerQuarterSecond` (a 0.25 s timer applies `BP_GE_ManaGain_Generic` until Mana ≥ MaxMana) | 125 → 10000 |
| Captain | the blank wait | `BluePrints/Gameplay/GameRules/King/BP_RS_King`: `MaxKingVotingTime` (`MinCaptainSelectTime` is 2) | 18 → 2 |
| Knock-ups | all of them become stuns | `BluePrints/Library/BP_FL_MOBA_FunctionLibrary` (`DoTargetKnockUp`, the only user of the effect): imports `BP_GE_KnockUp_C`, `Default__BP_GE_KnockUp_C`, `/Game/Gameplay/Effects/Shared/BP_GE_KnockUp` (uses 1 / 0 / 2) | → `BP_GE_Stun_C` and its default and package. Both take their length from SetByCaller `Data.Duration`, so each stun lasts as long as the knock-up did |
| Texts | Heirlooms → Augments | `UI/Localization/LOC_EN_FEATURE_ROUNDSTART` (5 keys), `FANGS_LOC_EN` (4), `LOC_EN_FEATURE_TUTORIAL` (8): 17 entries | "COMBAT/UTILITY/ULTIMATE AUGMENTS", "Combat Augment", "select all your Augments", "CHOOSE AN AUGMENT", "AUGMENT ROLL"; in the tutorial "Combat, Utility and Ultimate Augments are specific to your hero", "Hero Augments" where a sentence lists all three kinds |
| Texts | Training | `FANGS_LOC_EN` `gamemode_training_desc`, `FANGS_CLIENT_LOC_EN` `STR_TRAINING_DESC` | "[TAB]" → "[P]" |

Who calls `DoTargetKnockUp` in Feb: Zoey's ult, Belroth's Vicious Lunge, Brutus' Head Splitter, Ethryn's ult, Tufts' LMB,
Kiona's Space (Cyclone Generator), the Blast Cone map objective, Springpad, and the unreleased Priest, Scythe and
WaterBlade abilities. No other asset references `BP_GE_KnockUp` (pseudocode and class defaults searched). Side effects,
as the proposal said: no fly-up (the knock-up's airborne motion came from the ability its effect granted), and
Cleanse and anti-stun effects block these stuns now.

Not checked: whether attack speed also shortens Rayo's LMB cooldown. The cast scales with attack speed (the cast
task's attack-speed flag); the cooldown is applied natively. If only the cast scales, moving 0.2 s from the cast into
the cooldown makes attack-speed boosts slightly weaker for him.

## Tests

`tools/run/test_community.sh` (new): two `tools/run/test_patch.sh` matches with the pak (`ccrevert fiorne community`),
whose `check()` reads every patched class default on both clients and the game server, plus steps of its own
(`tools/run/test_community_a.steps`, `_b.steps`; new helpers `attr`, `trackms`, `lower`, `apply` in
`tools/run/test_patch.lua`):
- A: alice Belroth, bob Zoey: Vicious Lunge and Zoey's ult on each other (the server's effect log shows STUN or
  KNOCKUP), then the Green and Blue Shard buffs on alice from 30 % health and 0 mana;
- B: alice Somnia, bob Brutus: Brutus' health, then Somnia's ult on him with his MoveSpeed attribute every 50 ms.

Each ran with the pak and again without it (`PATCHES=none`, the control).

Results (16 Oct, `RUN=cpv` with the pak, `RUN=cpv-ctl` without):

| | Without the pak (Feb) | With the pak |
|---|---|---|
| Patched class defaults loaded (alice, bob, game server) | 0/87 | **85/87**; the other 2 are the nested health values (Brutus, Fiorne), which `check()` can't read: `attr` shows them |
| Belroth's Vicious Lunge on Zoey | `KNOCKUP+STUN` | **`STUN+STUN`** |
| Zoey's ult on Belroth | `KNOCKUP+STUN` (1.7 s) | **`STUN+STUN`** (1.8 s) |
| Blue Shard on Belroth at 0 mana | 125 after 0.7 s, 1125 after 2.7 s, full (2900) after 6.7 s | **2900/2900 after 0.7 s**: full at once, capped at the maximum |
| Green Shard on Belroth at 315/1050 | +53 after 0.7 s, +263 after 2.7 s, **+525** (840) after 6.7 s | first try (`Duration` 0.25, one tick of 525): only **+331** (646), then nothing |
| Brutus' health | 950 | **1050/1050** |

**The Green Shard can't be a single quarter-second tick.** The proposal says it lands "within a quarter of a second",
but measured on Belroth from 315/1050 health (the heal should be +525, 50 % of his maximum):

| `Duration` | Ticks of `GetHealPerTick` (MaxHealth × 0.5 / 4 / `Duration`) | Healed |
|---|---|---|
| 5 (Feb) | 20 × 26 over 5 s | +525 (100 %) |
| 0.25 | 1 × 525 | +331 (63 %) |
| **0.5 (built)** | 2 × 262.5 | **+487 (93 %)**, all within 0.7 s |
| 1.0 | 4 × 131 | not tested (the shared test queue was full); likely closer to 100 %, but takes 1 s |

The Blueprint isn't the cause: it only computes the per-tick heal, and its listener stops the heal at full health. The
shortfall comes from the native healing execution (`MOBAHealingExecutionCalculation`, not decompiled), and it grows
with the size of one heal. So the build uses `Duration` **0.5**: two ticks within half a second, 93 % of the heal. If the full 50 % matters more
than speed, 1.0 s is the next value to try.

**Somnia's ult on Brutus** (`RUN=cpv4`, his MoveSpeed attribute and health every 50 ms after the cast):
- With the pak: the 30 % slow (600 → 420) is renewed once every 0.25 s, so one 50 ms sample at 600 shows at 1.00,
  1.27, 1.53, 1.78, 2.00, 2.27, 2.53 s. His health falls in steps every 0.25 s.
- Without it (`RUN=cpv-ctl`): small drops of about 5 HP every 0.1 s (the ult's 10 ticks a second, 150 / 30), and the
  slow drops out at irregular 0.2-0.5 s gaps in the 50 ms samples.
- In both runs he also took about 60 HP every 0.25 s from something else where `face()` put him (likely a turret), so
  he died within about 3 s. The tick rate is what this test shows.
