# Roadmap and work in progress

The single place that says what is being worked on, what is done but not shipped, and what was decided.
`docs/STATUS.md` describes what exists; this file describes what is moving. Research findings go to
`docs/recon/`, not here.

**How to keep it (humans and agents alike):**
- Read it before starting work; update it in the same commit as the change that moves an item.
- Every item has a state: *planned*, *in progress*, *blocked (on what)*, *done, not deployed*, *live*.
- Write the next concrete step and where the evidence is (test script, file, commit). A finding that only
  lives in a chat or an agent transcript is lost: put it in `docs/recon/`.
- When work runs in parallel (several agents), list each stream here with what it owns, so nobody
  duplicates it and the results get merged back.
- Nothing secret here (no join code, keys, server credentials): this repo is public.

Last updated: 2026-10-14.

## Live on the server

Deployed 2026-10-14 (commit `92ca7d5`): all cosmetics owned, menu cleanup and players-online count, match
history / levels / ratings / leaderboard, friends / parties / chat / party queue, custom-lobby joiner fix,
PLAY waits for full 4v4 games.

## Done, not deployed

Ships with the next deploy. Decision: one deploy once heirlooms are tested too (see Decisions).

- **Cut items back in play** (`90e58f7` + follow-up): restore list `backend/seed/restore-feb2023.json`,
  served by `/fangsapi/*/restored-items`, applied by FangsBoot. Restored: 5 boons, 16 arena artifacts
  (all verified in matches; see `docs/recon/items.md`).
- **Menus list only usable items**: `AvailableAugments` = in-match pools + restored items (367 of 539).
  Fixes cut items showing in Inventory/Loadouts, e.g. WaterBlade's "Ebb & Flow" under CatSupp (Zoey).

## In progress

1. **Heirlooms (hero-specific cut items).** 21 candidates whose effect code exists in the Feb build:
   15 for released heroes, 6 for unreleased ones. List and evidence: `docs/recon/items.md`.
   Next: equip each in a match (procedure in `docs/recon/items.md`), verify, add passing ones to the
   restore list.
2. **Unreleased heroes.** Playable with full kits: Warlock (Withergrim), Priest (Ellis), WaterBlade (Nuali),
   Scythe, Sniper. BladeMaster is a shell (no abilities); Grappler, PetSum, VampMage are stubs.
   Showcase test: `tools/run/test_hero.sh` (fires every ability, screenshots). Plan (agreed with the user):
   - separate "Unreleased" group: own row in Inventory, release/unreleased toggle in hero select,
     disclaimer when picked; released list stays the default;
   - make them as playable as possible: bug list per hero from showcase and bot matches, runtime fixes;
   - art (splash, portraits, ability and heirloom icons): references rendered from the in-game 3D models,
     images generated outside, shipped as PNGs and loaded at runtime.
   Showcase done (findings in `docs/recon/heroes.md`): all five have animated models; Priest and Scythe
   have real effects, Sniper uses placeholder effects, Warlock and WaterBlade have few.
   Next: UI integration research (in progress, agent), then a bug list per hero from bot/2-player matches.
3. **Newer builds**: none to fetch. The newest build of either app is the Dec 2023 Closed Playtest we already
   have; it is only a little further along for the unreleased heroes (Priest animations, a Warlock bot AI);
   pieces could be ported asset by asset later (`docs/recon/heroes.md`).
4. **Wylde's remembered heirlooms** (PAllyHeal, FourLessShots, Soulblast Powder): no code reacts to them in
   any build we have (Aug 2022, Feb 2023, Dec 2023). Blocked on an older build: a pre-Aug-2022 playtest
   manifest (Steam console `download_depot 1831080 1831081 <manifest>`) to check whether their code existed.

## Known issues and small ideas

- Restored artifacts Energy Drink and Prescience point to missing description strings (could be set at
  runtime). Courage's bonus damage and the artifacts' objective effects are untested in matches.
- A full party match (queue → accept → server) is untested; parties live in memory (lost on a backend
  restart).
- Voice chat (Vivox) is unavailable.
- PLAY needs 8 queued players; the server can lower it (`--match-size`) if the group prefers.

## Decisions

- Deploys: ask the user every time; never while people play (`server/deploy.sh` also refuses then).
- Cut content: restore everything that still works (tested in a match first); hide what doesn't, so
  everything players see is usable.
- Next deploy ships boons, artifacts and heirlooms together.
- Unreleased heroes: separated from released ones, with a disclaimer.
