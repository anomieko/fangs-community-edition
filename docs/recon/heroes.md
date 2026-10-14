# Unreleased heroes (Feb 2023 build)

`DT_Heroes` rows beyond the 15 released heroes. Names from the heroes' own string tables (Dec 2023 build).
Played with `tools/run/test_hero.sh` (an unreleased hero is added to that test's own seed).

| Row | Name | DT_Heroes Enabled | State in a match |
|---|---|---|---|
| Warlock | Withergrim, "The Wandering Plague" | yes | full kit (LMB, RMB, passive, 4 skills); one skill is a borrowed Astrada ability (`BP_GA_Warlock_AstradaE_Skill2`); placeholder portrait; 29 heirlooms in its pool |
| Priest | Ellis, "The Lantern in the Dark" | yes | full kit, portrait, 23 heirlooms |
| WaterBlade | Nuali | yes | full kit (8 abilities), portrait, 27 heirlooms |
| Scythe | (none yet) | yes | full kit (7 abilities); no hero pool, uses the full 74-item generic list |
| Sniper | (none yet) | yes | full kit (8 abilities), 12 heirlooms |
| BladeMaster | — | yes | shell: spawns, no abilities |
| Grappler, PetSum, VampMage | — | no | stubs |

- All of them have `HeroOwnerClass` None (see `docs/recon/items.md`, owner classes).
- The pre-round "premade build" cards show placeholder text for them.
- Size of their content (files in the pak): Priest 589, Warlock 551, WaterBlade 409 (a released hero like
  Lancer has 859); Sniper 148, Scythe 113, the stubs 4-64.

## In a match (showcase, `tools/run/test_hero.sh`, 2026-10-14)

All five with kits have a textured, animated model and move/dash with their abilities. Visual effects:
- **Priest (Ellis)**: spectral wings; big swirl effect on his ultimate (Skill4); dash works. Most finished.
- **Scythe**: winged passive form, red-black cleave (RMB), slash streaks (Skill4), scythe swing (LMB). Good.
- **Sniper**: models and projectiles fine, but several abilities draw flat yellow blobs: placeholder effects.
- **Warlock (Withergrim)**: Nether Realm form (glowing pink); otherwise few effects. Skill2 is Astrada's.
- **WaterBlade (Nuali)**: dash works; Skill1 shows a golden rune circle (likely borrowed); few other effects.
Some abilities didn't activate in the solo test (cooldowns/costs or needing a target): Warlock RMB and
Skill3, Priest passive and Skill3, WaterBlade Skill3 (wall) and ammo, Scythe Skill3 (storm), Sniper Skill3.
