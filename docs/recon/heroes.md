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
