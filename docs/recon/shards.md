# Shards: old carry-and-turn-in vs the Feb 2023 kill system

Research 2026-10-14 (Aug 2022, Feb 2023 and Dec 2023 builds). Paths: B = Feb Blueprint dump
(`BluePrints/...` under the Feb decompile), A = Aug 2022 decompile. Decompiles are local only.

## Bottom line

The old carry-and-turn-in Shard system is complete in the Feb build and only switched off. The game server can
turn it back on with no new assets: one property at game-mode BeginPlay, plus spawning one Shard actor on the
maps that lost theirs. Tried on our stack (solo, server functions called directly): pickup, own-zone turn-in
and back-cap all worked, and the client showed the Shard HUD messages.

## Names

| Code | In game |
|---|---|
| Relic, `BP_ShrineOrb(_BUff)` | the carried Shard (Aug UI still said "Relic") |
| `BP_TeamGoalChannel(_Buff)` | Capture Zone |
| `BP_East/WestShrine` | Shard spawn points ("South"/"North") |
| `BP_Payload`, Phoenix | Aspect |
| King | Captain |
| `BP_HealingOrb` | channeled Health Shrine (grants the `Ability.OrbHeal` source tag) |
| `BP_PickupActor` | Feb walk-over health pickup (`Effect.Generic.Health.OrbPickup`, no OrbHeal tag) |
| `BP_BuffActor` | Feb destructible "Prismatic Shard" (`Effect.Buff.PrismaticShard`) |

Shard buffs: Life (red), Aether (blue), Spirit (yellow). Feb match stats call captures "Shards Shattered".

## How each build plays

- The arena maps (Arena02, Arena06, Payload03, Payload04) use `BP_GM_MOBA_GameMode_Garden2` in every build;
  its rule components (King, Phoenix, Relic (disabled), Relic_Garden2) are the same in Aug and Feb.
- **The only rule change Aug → Feb**: the `Default__BP_GR_Relic_Garden2_C` CDO sets
  `RuleStateClasss = BP_RS_Relic_Destructible_C` instead of the inherited `BP_RS_Relic_C`
  (the property is on `BP_GameRule_Base`). Dec 2023 went back to `BP_RS_Relic_C`. No data table controls it.
- **Carry (Aug)**: the Shard spawns at a random shrine, a 2.5 s channel picks it up (HoldingOrb effect), the
  carrier drops it on death, and it can be turned in at either Capture Zone. Own zone: your team gets the Shard's
  buff. Enemy zone ("back-cap"): you steal the enemy's buffs; in Feb's code a back-cap also respawns your dead
  teammates. Aug only: each capture sped the Aspect up (×1.3 per capture; Feb still has a ×1.5 formula, but
  nothing increments the count).
- **Kill (Feb)**: `BP_RS_Relic_Destructible` shows `BP_BuffActor` at a shrine; killing it gives the team a
  Prismatic Shard buff and a stat point.
- Rounds are won by the Aspect or Captain lives in both; Shards never win a round.

Map actors:

| Map | Aug 2022 | Feb 2023 |
|---|---|---|
| Arena02, Arena06, Payload03 | Shard, 2 Capture Zones, 4 Health Shrines, shrines | Shard removed; `BP_BuffActor`, 2 turrets, 3 berserker pickups added; Health Shrines replaced by walk-over pickups; Capture Zones and shrines still placed |
| Payload04 (Payload II) | not in the Aug pak | Shard, both Capture Zones and 6 Health Shrines still placed |

**Payload II is broken in Feb as shipped**: the rule state is the destructible one but the map has no
`BP_BuffActor`, so no Shard ever appears there. It needs only the switch below to work as a carry map.

## Switching carry back on (FangsHost, server only)

- `RegisterBeginPlayPreHook`: when the actor is `BP_GM_MOBA_GameMode_Garden2_C`, set
  `gm.BP_GR_Relic_Garden2.RuleStateClasss` to
  `StaticFindObject("/Game/BluePrints/Gameplay/GameRules/Relic/BP_RS_Relic.BP_RS_Relic_C")` (the rule state
  doesn't exist yet at that point).
- On maps without a Shard: 200 ms later (`ExecuteInGameThreadWithDelay`) spawn `BP_ShrineOrb_BUff_C`
  (`BeginDeferredActorSpawnFromClass` + `FinishSpawningActor`; its defaults are complete) and set `RelicRef_0`
  on every `BP_TeamGoalChannel_Buff_C` to it. Skip if one exists (Payload04).
- Optional Aug flavour in Lua: Aspect speed-up (increment `RS_Phoenix.RelicsCapturedByTeamA/B` per capture);
  channeled Health Shrines (spawn `BP_HealingOrb_C` at the `BP_PickupActor` spots, hide the pickups).
- Porting cooked Aug assets instead is not worth it (days to weeks, Aug native code, players would need a pak).

Not tested yet: real channel input, death drop, two players, round resets, whether Payload II's shrines are
reachable, buff balance, whether the destructible Shard and turrets should stay alongside. Estimate for the
whole job including tests: 2-3 days.

## Items that depend on it

Checked 480 rows (restore list and every live pool). Nothing misbehaves under the kill system; the affected
items just do nothing.

- **Need carry Shards** (parked as `_parked_old_shards`): ShootTheMoon (Mask of Glory: back-cap branch of
  `BP_TeamGoalChannel_Buff`), RelicRunner_Garden (Swiftrunner: HoldingOrb), BubbleBobble (Shadowbringer:
  HoldingOrb), RocketFuel (Mask of Speed: `OnRelicCaptured`), Prescience (Allseer: reads the carry rule state),
  RoleGetSwole (Mask of Ascension: shard buff tags or HoldingOrb), BobAndWeave (Shardseeker: channel time on
  Shards, Capture Zones, Health Shrines).
- **Need channeled Health Shrines** (parked as `_parked_old_health_shrines`): EnergyDrink (Mask of Mana) and
  RoyalTax (Vital Offering) only react to `Ability.OrbHeal`, which only `BP_HealingOrb` grants; Feb's walk-over
  pickups don't. They work on Payload II only.
- Description keys: Mask of Mana and Allseer point to missing `position_maskofmana_desc` /
  `position_allseer_desc`; the texts exist as `position_energydrink_desc` / `position_prescience_desc`.
- **Work today**: Kingslayer, RepeatRegicide (Captain); ShootingGallery, MoshPit, LittlePush,
  UnstoppableForce (Aspect); MeCarry_Garden; the 5 boons; all 21 heirlooms; the live Generic pool.
- Nuali's (WaterBlade, unreleased) passive is built on carried Shards (`BP_GA_WaterBlade_P`): dead now, works
  again with carry.
