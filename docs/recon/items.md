# Items: boons, artifacts, heirlooms (Feb 2023 build)

Findings behind the cut-content restore (`docs/ROADMAP.md`). File:line references are to the decompiled
Blueprints in `work/bp-2023-02-15/MOBA/Content/` (generated locally, not in the repo).

## Names

Items are `UMOBAItem` data assets, one row each in `DT_MOBALoot` (row name = what `AvailableAugments` and
our restore list use; `tools/re/itempaths.py` maps rows to assets). The UI groups them by tier:

| `ETier` | UI | What |
|---|---|---|
| 0 Weapons | COMBAT HEIRLOOMS | hero items |
| 1 Armor | UTILITY HEIRLOOMS | hero items |
| 2 Artifact | ARTIFACTS | map/position items, generic, `MapsAvailability` |
| 3 Flex | FLEX | slot type only |
| 4 EpicTrinket | ULTIMATE HEIRLOOMS | hero items |
| 5 Legendary | BOONS | generic active spell (`pawn.ItemActiveSpell1`) |

Hero items take effect in Blueprints: every hero ability loops over the equipped items and switches on the
item's gameplay tag (`ApplyAllItemEffects` and pre/post-cast/on-hit variants). The exe has no `Item.*` tag
strings, so "implemented" = some Blueprint other than the item/preview/loot/string-table assets reads its tag.

## What decides what players see

- **In a match** (`WB_HUD.RefreshItemStash`, WB_HUD.txt:733-779): `pawn:GetPossibleItemsSorted()` = the
  hero pawn's `PossibleItems` (sorted) + `GenericItems`, kept if in `AvailableAugments`, tier fits the slot,
  `MapsAvailability` empty or has the map, `ItemRoles` fits, owned (only checked with `EnableAugmentProgress`).
  The pools are Blueprint defaults: `BP_<Hero>_Char.PossibleItems`, `BP_PlayerChar.GenericItems` (17 in Feb
  2023: 8 boons, 8 arena artifacts, FromMyColdDeadHands; 69 in Aug 2022).
- **Out of game** the lists are bigger: BOONS and ARTIFACTS tabs use `DA_PreviewHeroCollection.GenericAugments`
  (69), HEIRLOOMS the hero preview asset's `Augments`, Loadouts every `AvailableAugments` item whose
  `OwnerClassType` equals the hero's `HeroOwnerClass` (DT_Heroes) or whose `ModifiedAbility` is Generic
  (WB_LoadOuts.txt:318-345). All filtered by `AvailableAugments` only.
- **The server doesn't check**: `UpdateEquipmentOnServer` (validate 0x141324820, impl 0x141324600 in the Feb
  exe) accepts any item. So the client pool is the only gate, and adding items to the player's own pawn
  (FangsBoot, client side) is enough.
- **Owner class leftovers**: `EItemOwnerClassType` has no value for CatSupp/BattleMonk/BigBoi (they use
  Alchemist/Siegil/Monster) nor for unreleased heroes (None). `WaterBlade_Skill3_Ult2` "Ebb & Flow" is marked
  Alchemist, so it was listed under CatSupp (Zoey). Hence `AvailableAugments` must only contain usable items.

## Verdicts

Restored (in `backend/seed/restore-feb2023.json`), each verified in a match:
- **Boons**: Generic_RespawnBeacon (Resurrect), Generic_ScanSweep (Enlighten), Generic_PoisonIvy (Venom),
  Generic_TankBuster (Courage: 4 s buff then 90 s cooldown, by design), Generic_ChannelBlocker (Fury:
  5 × 12 damage map-wide).
- **Arena artifacts** (ability granted and active on the server): Generic_Kingslayer, RepeatRegicide,
  ShootingGallery, MoshPit, EnergyDrink, RoyalTax, ShootTheMoon, UnstoppableForce, BubbleBobble,
  MeCarry_Garden, RelicRunner_Garden, RocketFuel, Prescience, RoleGetSwole, LittlePush, BobAndWeave
  (tag-only: shrine/orb/channel Blueprints read it). Available on LE_Arena02/06 and LE_Payload03/04.
  EnergyDrink and Prescience point to missing description strings (the texts exist as
  `position_energydrink_desc` / `position_prescience_desc`).

**Parked** (`_parked_old_shards` in the restore list, 2026-10-14): seven of those artifacts are about the old shard
system (capture/carry a Shard, turn it in at a Capture Zone, channel Shards); our build kills Shards instead,
so they stay off until the old system is back: Generic_ShootTheMoon (Mask of Glory: capturing a Shard at the
enemy Capture Zone), Generic_RelicRunner_Garden (Swiftrunner: speed while carrying a Shard), Generic_RocketFuel
(Mask of Speed: capturing a Shard), Generic_BubbleBobble (Shadowbringer: stealth after channeling a Shard),
Generic_Prescience (Allseer: announced Shard, enemy channeling it), Generic_RoleGetSwole (Mask of Ascension: Shard
effects on the target), Generic_BobAndWeave (Shardseeker: channel Shards and shrines faster).
Also parked (`_parked_old_health_shrines`, 2026-10-14): Generic_EnergyDrink (Mask of Mana) and Generic_RoyalTax
(Vital Offering) only react to channeled Health Shrines, which Feb replaced with walk-over pickups on every map
but Payload II. The other seven are about Captains or the Aspect (Generic_MeCarry_Garden is "Vigorcloak":
+heals/shields). Details and how to bring the old system back: `docs/recon/shards.md`.

Heirlooms (effect code present in Feb), restored too: each was equipped through its slot in a match
(`tools/run/test_items.sh`), the game server had it equipped and the hero's abilities still fired. Whether each
effect has the intended numbers is not checked; confirm in play.
- Were playable in Aug 2022 or Dec 2023: FireMageDoubleRangeLMB (Flareshot Monocle), WallOfIgnition
  (Soulflame's Blessing), CircleOfPower (Igniter's Mark), SurgingWinds (Trailblazers),
  Backstab_Passive_StealthSpeed (Anticipation), BigBoi_Skill1_AllyHeal (Vital Seeds),
  CatSupp_PassiveTotoAOEHPS (Somnia's Gift), Gunslinger_LRMB8Bullets (Ammo Sprite), BloodthirstySpear
  (Lancer, Hiari Charm).
- Never in a pool we have: BigBoi_P_BrushHeal (Outrage), LancerItem19 ("Item 19"), DuelistZone (Lancer,
  artifact tier), LowHPShieldIncrease (ShieldGirl, Crownsguard Commendation), Sidekick_P_WallPin (Kunai
  Feathers), Sidekick_Skill3_AOECC (Mikado's Power Gong, no name string), RowenTanglerootGauntlets
  (WoodenSword); unreleased heroes: Priest_Skill3_AttackSpeed, Scythe_P_FlameAura, Scythe_RMB_FreeFire,
  Scythe_Skill2_Heal, Scythe_Skill2_MoreDamage.

Not restorable:
- No code reacts to them in Aug 2022, Feb 2023 or Dec 2023: 9 Gunslinger heirlooms incl. PAllyHeal,
  PFourLessShots, LRMBHealSHieldBuff ("Soulblast Powder"); CatSupp PassiveHealForHeal, Skill2KnockbackStun;
  WoodenSword VigourvineHilt and two UNUSED_ items; WaterBlade_Skill3_Ult2; Backstab Skill2PassiveReset,
  Skill2PullEnemy (no Feb row).
- 30 artifacts for maps not in the pak (Conquest, GemMine, Arena04/07/09); Beartrap, SpringPad (no rows);
  FromMyColdDeadHands (Arena04/09 only).

## Testing an item in a match

Client Lua (game thread, FangsCtl), after the map loaded and `gs:IsAtItemSelection()`:

```lua
local pc = <local player controller>; local pawn, ps = pc.Pawn, pc.PlayerState
local hud = pc.WB_HUDGamplayRef; local pre = hud.PreRoundSelection
-- slots: PlayerItem1 artifact, 2 combat heirloom, 3 utility heirloom, 4 flex (0-2), 5 ultimate heirloom,
-- 6 boon, 7-8 captain-only flex; HeroEquipment index = slot - 1
local slot = pre.PlayerItem6
hud.SelectedSlot = slot; hud.CurrentTierFilter = 5; hud:RefreshItemStash()   -- what the picker offers
slot:SetItem(StaticFindObject("<package>.<ITEM_name>"), true)                 -- -> ps:UpdateEquipmentOnServer
ps:ReportetFinishedItemSelectOnServer(false); pc:PlayerLockedIn()             -- lock in
```

Server checks (FangsCtl on the game server): the item in `BP_PlayerState_MOBA_Hero_C.HeroEquipment`; boons in
`pawn.ItemActiveSpell1`; passive items: instances of the granted ability with `bIsActive`; effects:
`ASC:GetGameplayEffectCount(<GE class>, nil, true)`, spawned actors, health. Tag-only heirlooms need an effect
check against a second player (`tools/run/test_join.sh` seats players on opposite teams with END=1).
The picker shows at most 4 items per category (`WB_AugmentCategory` icons 1-4).
