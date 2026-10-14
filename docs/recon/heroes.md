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

## Newer builds

The newest FANGS build is the one we have as reference: the Closed Playtest `main_v0_0_444` (app 1831080,
build 12965227, 20 Dec 2023, manifest 5738023829398519305; public branch per the Steam client's app cache,
2026-10-14). The main app's last public build is 11250319 (20 May 2023, depot 1717991 manifest
8969676660192098141): older than that playtest and after the Feb 2023 cuts.

Unreleased heroes, Feb 2023 → Dec 2023 (pak file lists): Priest +30 files (new RMB animations for him and his
angel avatar, changed Skill4 animations and VFX pack); Warlock gains a bot behaviour tree
(`AI/Characters/Warlock/BT_Warlock_BehaviorTree`); WaterBlade, Scythe, Sniper, PetSum, VampMage: same files,
ability Blueprints recooked/changed (19-47 files). So Dec 2023 is only a little further along. Taking pieces
from it means loading Dec assets in the Feb game (mod pak), asset by asset: data-only assets (animations,
behaviour trees, effects) are candidates; ability Blueprints depend on native code that may have changed.

## Menus and art for unreleased heroes (Feb 2023 build)

Prototyped in UE4SS Lua on test clients (2026-10-14). Hook rule found then: **never call a Blueprint function
inside a Blueprint-function hook callback** (the game thread hung twice); read/set properties there and defer
calls with `ExecuteInGameThreadWithDelay(1, fn)`.

- `gi.bUsePreviewHeroes` is true: menus need the hero's preview asset (`DA_PreviewHeroCollection`, 22 heroes,
  includes Priest, WaterBlade, Sniper, Warlock, Scythe; BladeMaster has none).
- **Inventory** (`WB_Heroes.InitHeroSelection`): one `WB_HeroButton` per `AvailableHeroes` entry that has a preview
  asset, `bEnabled` and a preview `HeroSelectIcon` (only WaterBlade's has one); others are skipped silently.
  A separate section = own title/note/WrapBox added to `HeroesScrollBox`, the Blueprint's unreleased cards moved
  into it, own `WB_HeroButton` cards for the skipped ones (click: hook the card's CharacterBtn handler, then
  deferred `SetupHeroInfo` + `ShowMoreDetails`).
- **Hero select** (`WB_LobbyHeroSelect.SetupHeroSelect`): 30 fixed buttons filled from `gi.HeroDetailMap`; icon
  from DT_Heroes `HeroSelectIcon`. A toggle = a 4th `WB_FilterClassButton_C` added to `FilterBtnPanel` after
  Construct (its click handler hooked); regroup the buttons in a deferred call after `SetupHeroSelect`.
- **Disclaimer**: a fresh `WB_Confirm_C` (not `Show Confirmation`: its shared dialog keeps other callers' OK
  handlers). `CancelLabel=""` hides Cancel; it blocks input until OK.
- **Premade builds** come only from DataTable `DT_Presets` (15 rows, none for unreleased heroes); rows can be added
  at runtime with UE4SS `dt:AddRow`.
- **Art slots** (DT_Heroes columns, read via `gi.HeroDetailMap`): `HeroSelectIcon` 256² (hero select, history),
  `SmallHeroPortrait` 512² (HUD, kill feed), `HeroWheelBkg` 256×128, `HeroTeamBar` 512×128 (loading screen),
  `HeroOverlay` 2048² full body (pre-round, end of match), `HeroImage` 256², `AnnouncerPortrit` 512²; preview
  asset `HeroSelectIcon` 256² (inventory card) and `HeroOverlay` 2048² (overview page); skin `LobbyIcon`
  2048×1024. Unreleased heroes have few of these (BladeMaster's row reuses Rowan's art); ability icons are
  borrowed except WaterBlade's; heirloom icons: Priest and WaterBlade mostly own, Warlock/Scythe borrowed,
  Sniper none. No skin rows, so the skin carousels are empty.
- **Our own art at runtime**: `KismetRenderingLibrary:ImportFileAsTexture2D(gi, path)` loads a PNG (sRGB, no mips;
  keep a reference, reload when invalid) for `SetBrushFromTexture`/brush properties. Ship PNGs with FangsBoot.
- **Risk**: a lobby pick is saved as the player's hero; with a hero that has no preview asset the main menu needs
  a released hero set back.
