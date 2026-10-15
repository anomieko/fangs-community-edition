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

Last updated: 2026-10-15.

## Live on the server

Current deploy: `deploy-2026-10-15-1714` (`09c27b1`); what each deploy changed: `docs/CHANGELOG.md`.
- since 14 Oct 16:07: all cosmetics owned, menu cleanup and players-online count, match history / levels /
  ratings / leaderboard, friends / parties / chat / party queue, custom-lobby joiner fix, PLAY waits for full
  4v4 games;
- since 14 Oct 18:11: cut items back in play (5 boons, 16 arena artifacts, 21 heirlooms), menus list only usable
  items, unreleased heroes as a separate group (Inventory section, hero-select toggle, notice);
- since 14 Oct 18:21: lobby creation no longer fails when an owner's retry races a booting server.
- since 14 Oct 18:55: main menu lists who is online and free game servers; currencies hidden; BladeMaster
  removed; FangsBoot lists arrive within seconds (cached); seven old-shard artifacts parked (35 items restored).
- since 14 Oct 19:03: online list one name per line with server-granted styles (rainbow anomie); smoke test
  account not counted.
- since 14 Oct 23:06 UTC: old carry Shards and channeled Health Shrines on the arena maps (`OLD_SHARDS` switch;
  see Shards below), the nine shard artifacts restored, game-server stutter fix (no object scans,
  no movies/CEF/console), launcher remembers its invite, item texts fixed.
- since 15 Oct 00:03 UTC: maps Embersong, Stormheart, Crownwatch (all three in PLAY; Arena and Payload II gone),
  custom modes 6vs6 … Duel, Solo (Battle = 3vs3; Trio and AI gone), friends fix for mutual requests, a carrier who
  leaves loses the Shard after 2 s.
- since 15 Oct 03:09 UTC: lobbies close when their match starts; a finished match's server stops.
- since 15 Oct 03:17 UTC: team and all chat in custom lobbies, hero select and matches (`docs/recon/chat.md`).
- since 15 Oct 16:37 UTC: Ranked (tile at 10 wins, parties of up to 2): skill-based teams and a rating, the game's
  draft hero select; Casual and custom games without a rating; ratings start fresh (`docs/recon/ranked.md`).
- since 15 Oct 17:14 UTC: the Feb 2023 CC changes reverted by the first patch pak (`FangsCE_P.pak`, players get it
  from the launcher): roots back to stuns, Allure charms again (with its Aug visual), Somnia's ult locks only her cast,
  no LMB lock for Rowan, tooltips say stun (`docs/recon/cc-changes.md`, `docs/PATCHING.md`).

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
2. **Server smoothness up to 12 players (6v6)** (live since `deploy-2026-10-14-2306`: FangsHost, `server/run-host.sh`,
   `backend/hosts.py`; findings and numbers in `docs/recon/server-performance.md`, load test `tools/run/test_perf.sh`).
   Cause of the ~200 ms hitches: FangsHost's 2 s / 3 s loops scanned all objects on the game thread. Locally with
   3 active players + 9 bots: before 10 frames > 50 ms in 140 s (longest 99 ms), after 0 (longest 18 ms); servers
   also skip movies, CEF and the `-log` console. Next: compare the VPS `perf` lines of the
   next real match (`frame_ms`, `slow`, `fps_min`). Open: ntsync on the VPS (capacity, needs kernel + Wine change);
   replication runs at ~20-25 Hz whatever `NetServerMaxTickRate` says, so no 60 Hz net tick from config.
   FangsBoot (players' mod) still cancels finished loops the way that sometimes stopped other loops in FangsHost:
   switch it to idling too (needs a player update; watch for menu lists that stop refreshing).
3. **Old Shard system** (live since `deploy-2026-10-14-2306`; `docs/recon/shards.md`). The round-2 bug is closed:
   a test artifact, 45 round-2 pickups in nine runs all kept the HoldingOrb tag and were turned in; the fix to the
   leave safety net is in "Done, not deployed" (branch `shards`). Next: the user's multiplayer test (not triggered
   solo: Mask of Ascension's damage, Vital Offering's missile to another Captain, back-cap respawning teammates).
4. **Newer builds**: none to fetch. The newest build of either app is the Dec 2023 Closed Playtest we already
   have; it is only a little further along for the unreleased heroes (Priest animations, a Warlock bot AI);
   pieces could be ported asset by asset later (`docs/recon/heroes.md`).
5. **Wylde's remembered heirlooms** (PAllyHeal, FourLessShots, Soulblast Powder): no code reacts to them in
   any build we have (Aug 2022, Feb 2023, Dec 2023). Blocked on an older build: a pre-Aug-2022 playtest
   manifest (Steam console `download_depot 1831080 1831081 <manifest>`) to check whether their code existed.
6. **Revert the Feb 2023 CC changes**: **live** since `deploy-2026-10-15-1714` (see Live above). Tested in matches
   against a control without the pak (`tools/run/test_patch.sh`). Not seen in a match yet: Earthquake's centre (the
   Quakebreak Talisman augment), Ethryn, Fiorne, Astrada, Zoey. Next: players' feedback. Off switch:
   `"enabled": false` in `tools/patch/patches/ccrevert.json` and a deploy.

## Known issues and small ideas

- Underworld (`LE_UnderWorldArena`, own "stocks" mode: team lives, random spawns; Aug 2022 + Feb 2023 paks) and
  Arena (`LE_Arena01_Map`, prototype) load on the server, but players stay on the loading screen ("Waiting for
  players"; `RUN=... MAP=... tools/run/test_match.sh`). Off in the seed; Underworld worth a look (user wants it).
- VS AI (custom "AI" mode) hidden: the game spawns its bots from `EditorTestClients` (one non-AI entry in the shipped
  game). Could come back with FangsHost filling empty slots via `GS_MOBA_Battle.SpawnBot` (bots ignore Shards).
- Test scripts other than `tools/run/test_shards.sh` share `work/run/records` (the backend's records next to
  `--data`): parallel runs with different seeds can switch each other's server-side settings. Give each run its own
  data folder as `test_shards.sh` does.
- Payload II has no Shard in the Feb build; fixed by the old Shard system (live, `OLD_SHARDS`).
- Courage's bonus damage is untested in matches.
- A full party match (queue → accept → server) is untested; parties live in memory (lost on a backend
  restart).
- Voice chat (Vivox) is unavailable.
- Capacity: 2 game servers (RAM). Each Training session takes a whole server; when both are busy, creating a
  lobby fails. A server boots in 20-25 s but the client gives up after ~18 s, so a first try without a ready
  standby can fail (the retry then works). Idea: run Training on the player's own PC.
- PLAY needs 8 queued players; the server can lower it (`--match-size`) if the group prefers. Ranked likewise
  (`--ranked-size`, even), and it waits for a fair game: a player far above everyone queued can wait indefinitely.

## Decisions

- Ranked uses skill ratings; Casual stays quick matches without a rating, since the population is small (user,
  15 Oct). Custom lobbies have no rating either. The server runs `--ranked-widen-speed 2` (user, 15 Oct).

- Deploys: ask the user every time; never while people play (`server/deploy.sh` also refuses then).
- Load tests may use the VPS's game slots when nobody plays (user, 14 Oct); no deploys/restarts from tests.
- Cut content: restore everything that still works (tested in a match first); hide what doesn't, so
  everything players see is usable.
- Next deploy ships boons, artifacts and heirlooms together.
- Unreleased heroes: separated from released ones, with a disclaimer.
- Old Shard system (carry-and-turn-in, channeled Health Shrines): in, behind one switch, on by default (user, 14 Oct);
  the user tests it in multiplayer before it is deployed.
- Gameplay changes to the game's own data are permanent and go into the patch pak, the same file for players and
  servers (`docs/PATCHING.md`). Runtime hooks are not used for them (user, 15 Oct).
- CC revert scope (user, 15 Oct):
  - Reverted: the stun/charm → root conversions and Somnia's ult lock (plus Rowan's LMB lock, which the developers
    removed again by Dec).
  - Not reverted for now: the other CC duration changes.
  - The user tests it locally before it is enabled and deployed.
