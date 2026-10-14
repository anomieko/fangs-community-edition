# Shards: old carry-and-turn-in vs the Feb 2023 kill system

Research 2026-10-14 (Aug 2022, Feb 2023 and Dec 2023 builds). Paths: B = Feb Blueprint dump
(`BluePrints/...` under the Feb decompile), A = Aug 2022 decompile. Decompiles are local only.

## Bottom line

The old carry-and-turn-in Shard system is complete in the Feb build and only switched off. It is back, behind one
switch (`OLD_SHARDS` in `backend/seed/make_seed.py`, on by default): the game server sets one property at the
arena game mode's BeginPlay, spawns the Shard on the maps that lost it and puts channeled Health Shrines back in
place of the walk-over health pickups. No new assets, nothing for players to install. Built and tested on branch
`shards` (see "The switch" and "Tests" below).

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
- **Carry (Aug)**: the Shard spawns at a random shrine, a 2.5 s channel picks it up (HoldingOrb effect), and it
  can be turned in at either Capture Zone. Own zone: your team gets the Shard's buff. Enemy zone ("back-cap"): you
  steal the enemy's buffs; in Feb's code a back-cap also respawns your dead teammates. A carrier who dies loses
  the Shard: it goes back to a shrine after the respawn time (no Shard left on the ground; same in Aug and Feb,
  `BP_ShrineOrb` DropOrb → ResetChannelActor). Carrying it ~30 s grounds and reveals the carrier ("Shard Penalty").
- **Aspect speed-up**: the Aspect's speed is multiplied per Shard capture of the pushing team (`BP_Payload` "Relic
  Boost": ×1.3 per capture in Aug, ×1.5 in Feb; the count resets every round). In Aug only a capture by a carrier
  wearing the artifact Rocket Fuel raised the count (A `BP_TeamGoalChannel_Buff.txt:833-959` → Garden2 game mode
  `Phoenix SpeedUp`; Aug text: "Capturing a Relic will make your team push the Phoenix 50% faster (stacking)").
  Feb turned Rocket Fuel into Mask of Speed (movement/attack speed for the team) and nothing raises the count.
- **Kill (Feb)**: `BP_RS_Relic_Destructible` shows `BP_BuffActor` at a shrine; killing it gives the team a
  Prismatic Shard buff and a stat point.
- Rounds are won by the Aspect or Captain lives in both; Shards never win a round.

Map actors:

| Map | Aug 2022 | Feb 2023 |
|---|---|---|
| Arena02, Arena06, Payload03 | Shard, 2 Capture Zones, 4 Health Shrines, shrines | Shard removed; `BP_BuffActor`, 2 turrets, 3 berserker pickups added; Health Shrines replaced by walk-over pickups; Capture Zones and shrines still placed |
| Payload04 (Payload II) | not in the Aug pak | Shard, both Capture Zones and 6 Health Shrines still placed |

**Payload II is broken in Feb as shipped**: the rule state is the destructible one but the map has no
`BP_BuffActor`, so no Shard ever appears there. With the switch on it is a working carry map (nothing spawned).
In Feb the health pickups are the Aug Health Shrine actors (same names, same x/y) with a new class.

## The switch (FangsHost, server only)

- **One place**: `OLD_SHARDS = True` in `backend/seed/make_seed.py`. It writes the game record `CEOldShards`
  (`{"Enabled": true, "AspectSpeedup": "off"}`; the backend exports it for the game servers) and restores the nine
  artifacts below (restore-list keys `_old_shards`, `_old_health_shrines`; parked again when off). Off: the game
  as Feb 2023 shipped it. Flipping it needs a server deploy only (the seed is made when the server starts).
- **Sub-switch** `OLD_SHARDS_ASPECT_SPEEDUP` (default `'off'`, as Feb 2023): `'mask_of_speed'` = Aug 2022 (only
  captures by a Mask of Speed carrier speed the Aspect up), `'every_capture'`. Uses Feb's ×1.5 per capture (Aug's
  code had ×1.3; the factor is fixed in `BP_Payload`, the count is all FangsHost can change).
- **FangsHost** `tools/ue4ss/Mods/FangsHost/scripts/shards.lua` (loaded by `main.lua`, Feb build only), on every
  arena start (`BP_GM_MOBA_GameMode_Garden2_C` BeginPlay, before the rule state exists):
  - `gm.BP_GR_Relic_Garden2.RuleStateClasss = BP_RS_Relic_C` (property only, inside the hook);
  - 200 ms later: if the map has no `BP_ShrineOrb_BUff_C`, spawn one at the West shrine
    (`BeginDeferredActorSpawnFromClass` + `FinishSpawningActor`; class defaults are complete) and set `RelicRef_0`
    on every `BP_TeamGoalChannel_Buff_C` (they look the Shard up once, at their BeginPlay);
  - replace each map's `BP_PickupActor_C` (walk-over health, exact class: the berserker pickups stay) by
    `BP_HealingOrb_C` at the Aug spots (Embersong, Stormheart, Crownwatch; other maps: the pickup spot, 44 higher),
    loading the class if needed, then destroy the pickups;
  - the destructible `BP_BuffActor` stays hidden (only its rule state shows it); turrets stay;
  - with the sub-switch: watch the rule state's team counters; a rise is a capture by the last carrier; raise
    `BP_RS_Phoenix_C.RelicsCapturedByTeamA/B`;
  - safety net the game lacks: a carrier whose hero goes away without dying (a player leaving) would keep the Shard
    "taken" until the round ends, and so would a dead carrier who had lost the HoldingOrb tag (open issue below);
    after 2 s FangsHost sends it back to a shrine (`ResetOrb`);
  - no object scans while a match runs (`docs/recon/server-performance.md`): the 250 ms loop takes the rule states
    from the game mode's rule components (`gm.BP_GR_Relic_Garden2` / `BP_GR_Phoenix` `.RuleStateComp`); the
    one-time setup finds actors with `GetAllActorsOfClass`.
- **FangsBoot** (players): Mask of Mana and Allseer point to missing string-table keys; FangsBoot sets their
  descriptions to `position_energydrink_desc` / `position_prescience_desc` (`KismetTextLibrary.TextFromStringTable`)
  and gives Mikado's Power Gong (no texts in Feb) its Aug name and a description, whenever the assets load.

## Tests (2026-10-14, `tools/run/test_shards.sh`)

Solo custom match, FireMage, four artifacts equipped (slots 1, 4, 7, 8; the solo player is the Captain). The game
server logs every state change (`shardwatch.log`, condensed by `tools/run/test_shards_log.py`); the client channels
with the F key's own handler (`InpActEvt_Channel`); the server only moves the hero; deaths come from the enemy
turret. Evidence in `work/logs/<run>/` (local): `timeline-host-7777.txt`, screenshots, `shardtexts.log`.

- All four arena maps, switch on (`shards-e1b`, `shards-e2` Embersong; `shards-s6b` Stormheart; `shards-c3`
  Crownwatch; `shards-p2` Payload II): Shard spawns at a shrine ~13 s after the round starts (Payload II: its own
  Shard; the others a spawned one); channel 2.3 s (1.4 s with Shardseeker); pickup gives the HoldingOrb effect and
  the "You have acquired the ... Shard" HUD messages; own-zone turn-in: the team gets the Shard's buff (Spirit: CD
  reset + CDR; Life: heal + lifesteal; Aether: full Energy + speed); the Shard comes back ~15 s later at the other
  shrine; carrying ~30 s grounds the carrier; the carrier killed by the turret loses the Shard, back at a shrine
  15 s later; back-cap counted; Health Shrines (spawned, or Payload II's own) channel in 1.4-2.8 s and heal (270 →
  690 HP); round 2: counters reset, Shard spawns again. Prismatic Shard hidden, health pickups gone, 42 items
  restored (9 of 9 offered to the hero), every restored item has a name and a description on the client.
- Carrier's hero removed without dying (`shards-s6b`, as a player leaving): FangsHost sent the Shard back to a
  shrine after 2 s (without it the Shard stays "taken" until the round ends; seen in an earlier run).
- Items (granted on the server, reactions seen): Swiftrunner +22 % speed while carrying; Shadowbringer ~5 s stealth
  on pickup; Shardseeker channel 2.3 → 1.4 s on Shards and Health Shrines; Allseer (Feb code): damage buff within
  1000 of the Shard (not the speed-on-announce of its text); Mask of Speed: a stack per capture; Mask of Glory:
  Life, Aether and Spirit buffs on a back-cap; Mask of Mana: Energy 0 → 1250 (50 % of max) per Health Shrine
  channel; Vital Offering: 12 s heal on the Captain per Health Shrine channel; Aspect speed-up sub-switch:
  `mask_of_speed` counted Mask of Speed captures only, `every_capture` every capture, reset in round 2.
- Server frame times with the switch on (`shards-perf2`, Embersong, after merging the server-performance fix): the
  backend's 30 s `perf` lines for the arena show fps 60, `frame_ms` 17-19 and `slow` 0 in every window but the first
  (the map load: `frame_ms` 320, `slow` 1). Switch off for comparison (`shards-perf-off`): first window 166 ms /
  `slow` 2, then 18-24 ms / 0.
- Switch off (`shards-off`, Embersong): destructible rule state, Prismatic Shard at a shrine ~13 s after the round
  starts, its kill gives the Prismatic buffs (damage, heal/shield power, Energy), back ~35 s later; 4 walk-over
  pickups; 33 items restored, none of the nine offered.
- Not triggered in solo: Mask of Ascension (granted; needs the hero to hit a Shard-buffed enemy), Vital Offering's
  missile to a Captain who isn't the channeler, back-cap respawning dead teammates, two-player play. Bots (custom "AI" lobbies)
  know neither Shards nor Health Shrines, in either system.
- **Open issue (round 2+)**: now and then a carrier loses the HoldingOrb tag ~1.4 s after the pickup while the
  Shard's HoldingOrb effect stays (`hold=f` in the timelines; seen in `shards-s6b`, `shards-final`, `shards-r2`,
  `shards-r2b`, `shards-r2c`, `shards-r2d`: once per round-2 run, on the first, second or third pickup; never in
  round 1). Swiftrunner's speed and Shadowbringer's stealth stop then (both drop their effect when the tag goes),
  and such a carrier most likely can't turn the Shard in (`BP_TeamGoalChannel_Buff.CanCharacterChannel` checks the
  tag; not confirmed) and would keep it when dying (the game drops it only from a carrier with the tag). In the
  same runs, round-2 Shards that kept the tag were turned in at both zones. Putting the tag back with
  `MOBAAbilitySystemComponent.SetTagCount` didn't stick (`shards-r2d`, removed). FangsHost's safety net returns
  the Shard to a shrine 2 s after its carrier dies or leaves. Not the cause: `BP_GE_RemoveHoldingOrb` (it would
  remove the effect too), `SetTagCount` callers in the Blueprints. Next: find what removes the tag (native or
  Blueprint, ~1.4 s after the pickup: the channel ability's end, `BP_AC_Channel`, item abilities restarting each
  round), confirm whether a tagless carrier can turn in, and check in multiplayer.

## Items that depend on it

Checked 480 rows (restore list and every live pool). Nothing misbehaves under the kill system; the affected
items just do nothing. Restored while the old system is on, parked when it is off:

- **Need carry Shards** (`_old_shards`): ShootTheMoon (Mask of Glory: back-cap branch of
  `BP_TeamGoalChannel_Buff`), RelicRunner_Garden (Swiftrunner: HoldingOrb), BubbleBobble (Shadowbringer:
  HoldingOrb), RocketFuel (Mask of Speed: `OnRelicCaptured`), Prescience (Allseer: reads the carry rule state),
  RoleGetSwole (Mask of Ascension: shard buff tags or HoldingOrb), BobAndWeave (Shardseeker: channel time on
  Shards, Capture Zones, Health Shrines).
- **Need channeled Health Shrines** (`_old_health_shrines`): EnergyDrink (Mask of Mana) and RoyalTax (Vital
  Offering) only react to `Ability.OrbHeal`, which only `BP_HealingOrb` grants; Feb's walk-over pickups don't.
- Description keys: Mask of Mana and Allseer point to missing `position_maskofmana_desc` /
  `position_allseer_desc`; the texts exist as `position_energydrink_desc` / `position_prescience_desc` (FangsBoot
  fixes them). Mikado's Power Gong (Sidekick_Skill3_AOECC, restored) has no texts in Feb at all.
- **Work today**: Kingslayer, RepeatRegicide (Captain); ShootingGallery, MoshPit, LittlePush,
  UnstoppableForce (Aspect); MeCarry_Garden; the 5 boons; all 21 heirlooms; the live Generic pool.
- Nuali's (WaterBlade, unreleased) passive is built on carried Shards (`BP_GA_WaterBlade_P`): dead under the kill
  system, works with the old one.
