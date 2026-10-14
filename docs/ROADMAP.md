# Roadmap and work in progress

The single place that says what is being worked on, what is done but not shipped, and what was decided.
`docs/STATUS.md` describes what exists; this file describes what is moving. Research findings go to
`docs/recon/`, not here; what each deploy changed (and how to undo it) goes to `docs/CHANGELOG.md`.

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

Current deploy: `deploy-2026-10-14-1821` (`273d2d1`); what each deploy changed: `docs/CHANGELOG.md`.
- since 14 Oct 16:07: all cosmetics owned, menu cleanup and players-online count, match history / levels /
  ratings / leaderboard, friends / parties / chat / party queue, custom-lobby joiner fix, PLAY waits for full
  4v4 games;
- since 14 Oct 18:11: cut items back in play (5 boons, 16 arena artifacts, 21 heirlooms), menus list only usable
  items, unreleased heroes as a separate group (Inventory section, hero-select toggle, notice);
- since 14 Oct 18:21: lobby creation no longer fails when an owner's retry races a booting server.

## Done, not deployed

Nothing.

## In progress

1. **Unreleased heroes.** Playable with full kits: Warlock (Withergrim), Priest (Ellis), WaterBlade (Nuali),
   Scythe, Sniper. BladeMaster is a shell (no abilities); Grappler, PetSum, VampMage are stubs.
   Showcase test: `tools/run/test_hero.sh` (fires every ability, screenshots). Plan (agreed with the user):
   - separate "Unreleased" group: own row in Inventory, release/unreleased toggle in hero select,
     disclaimer when picked; released list stays the default;
   - make them as playable as possible: bug list per hero from showcase and bot matches, runtime fixes;
   - art (splash, portraits, ability and heirloom icons): references rendered from the in-game 3D models,
     images generated outside, shipped as PNGs and loaded at runtime.
   Showcase done (findings in `docs/recon/heroes.md`): all five have animated models; Priest and Scythe
   have real effects, Sniper uses placeholder effects, Warlock and WaterBlade have few.
   Menus done (see "Done, not deployed"). Next: a bug list per hero from 2-player matches; art (PNG
   pipeline ready: `ImportFileAsTexture2D`, slots in `docs/recon/heroes.md`); premade builds (`DT_Presets` rows);
   lobby shows DT names ("Priest") under the hero grid.
   Art references done: transparent full-body and bust renders of all heroes (`tools/run/render_heroes.sh`,
   output `work/art/refs/`, local only). The game also contains official paintings of the unreleased heroes
   (`docs/recon/heroes.md`): use them for portraits/cards first; generated art for the remaining slots.
   BladeMaster dropped from the unreleased group (grey mannequin, no abilities).
2. **Shards: old carry-and-turn-in vs current kill system** (research in progress, agent). The community wants
   the old system back; some restored items (e.g. Relic Runner, Me Carry, Shardseeker) may belong to the old one.
   Questions: is the old mechanic still in the Feb build (switchable from FangsHost?) or only in Aug 2022; which
   restored and live items depend on which system. Until then the restored items stay as they are; any of them
   can be switched off with a server-only deploy (`docs/CHANGELOG.md`).
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
- Capacity: 2 game servers (RAM). Each Training session takes a whole server; when both are busy, creating a
  lobby fails. A server boots in 20-25 s but the client gives up after ~18 s, so a first try without a ready
  standby can fail (the retry then works). Idea: run Training on the player's own PC.
- PLAY needs 8 queued players; the server can lower it (`--match-size`) if the group prefers.

## Decisions

- Deploys: ask the user every time; never while people play (`server/deploy.sh` also refuses then).
- Cut content: restore everything that still works (tested in a match first); hide what doesn't, so
  everything players see is usable.
- Next deploy ships boons, artifacts and heirlooms together.
- Unreleased heroes: separated from released ones, with a disclaimer.
