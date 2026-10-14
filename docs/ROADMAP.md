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

Current deploy: `deploy-2026-10-14-1903` (`5246bf3`); what each deploy changed: `docs/CHANGELOG.md`.
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

## Done, not deployed

- Easier download: public launcher build for GitHub Releases (HTTPS, nothing secret built in) that asks
  for an invite code (`server/invite.sh`); player steps in `README.md`. Published 14 Oct as GitHub release
  `launcher-1d34ff1` (players' link: `.../releases/latest/download/FangsCE.exe`); works with today's server (it
  updates itself to the server's copy); the server's copy remembers the invite after the next deploy.
- Mask of Mana and Vital Offering parked (they only react to channeled Health Shrines, gone from the Feb
  maps); superseded by the old Shard system below, which restores them while it is on.
- **Old Shard system back, behind one switch** (branch `shards`; `docs/recon/shards.md`): on the arena maps Shards
  are carried and turned in at a Capture Zone again (own zone: the Shard's buff; enemy zone: steal the enemy's
  buffs), channeled Health Shrines replace the walk-over pickups, Payload II's Shard works; the Prismatic Shard
  stays off. The nine artifacts made for it are restored (42 items restored). Switch: `OLD_SHARDS` in
  `backend/seed/make_seed.py` (on; off = Feb 2023 as shipped, the nine parked); sub-switch
  `OLD_SHARDS_ASPECT_SPEEDUP` (off; Shard captures speed the Aspect up). FangsBoot fixes the texts of Mask of
  Mana, Allseer, Mikado's Power Gong. Tested solo on all four arena maps with `tools/run/test_shards.sh` (switch
  on and off; server frames with it on: fps 60, slow 0 after the map load); multiplayer test by the user before
  the deploy. Not triggered solo: Mask of Ascension's damage, Vital Offering's missile to another Captain, back-cap
  respawning teammates. Open: the round-2 HoldingOrb tag loss (Known issues).

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
2. **Server smoothness up to 12 players (6v6)** (done, not deployed: FangsHost, `server/run-host.sh`,
   `backend/hosts.py`; findings and numbers in `docs/recon/server-performance.md`, load test `tools/run/test_perf.sh`).
   Cause of the ~200 ms hitches: FangsHost's 2 s / 3 s loops scanned all objects on the game thread. Locally with
   3 active players + 9 bots: before 10 frames > 50 ms in 140 s (longest 99 ms), after 0 (longest 18 ms); servers
   also skip movies, CEF and the `-log` console. Next: deploy (user's OK), then compare the VPS `perf` lines of the
   next real match (`frame_ms`, `slow`, `fps_min`). Open: ntsync on the VPS (capacity, needs kernel + Wine change);
   replication runs at ~20-25 Hz whatever `NetServerMaxTickRate` says, so no 60 Hz net tick from config.
   FangsBoot (players' mod) still cancels finished loops the way that sometimes stopped other loops in FangsHost:
   switch it to idling too (needs a player update; watch for menu lists that stop refreshing).
3. **Newer builds**: none to fetch. The newest build of either app is the Dec 2023 Closed Playtest we already
   have; it is only a little further along for the unreleased heroes (Priest animations, a Warlock bot AI);
   pieces could be ported asset by asset later (`docs/recon/heroes.md`).
4. **Wylde's remembered heirlooms** (PAllyHeal, FourLessShots, Soulblast Powder): no code reacts to them in
   any build we have (Aug 2022, Feb 2023, Dec 2023). Blocked on an older build: a pre-Aug-2022 playtest
   manifest (Steam console `download_depot 1831080 1831081 <manifest>`) to check whether their code existed.

## Known issues and small ideas

- Payload II has no Shard in the Feb build; fixed by the old Shard system (Done, not deployed).
- Courage's bonus damage is untested in matches.
- Old Shard system, open: from round 2 on a carrier now and then loses the HoldingOrb tag ~1.4 s after a pickup (the
  Shard's effect stays): Swiftrunner's speed and Shadowbringer's stealth stop, and such a carrier most likely can't
  turn the Shard in (Capture Zones check the tag). FangsHost sends the Shard back if that carrier dies or leaves.
  Cause unknown; next steps in `docs/recon/shards.md` (Tests).
- A full party match (queue → accept → server) is untested; parties live in memory (lost on a backend
  restart).
- Voice chat (Vivox) is unavailable.
- Capacity: 2 game servers (RAM). Each Training session takes a whole server; when both are busy, creating a
  lobby fails. A server boots in 20-25 s but the client gives up after ~18 s, so a first try without a ready
  standby can fail (the retry then works). Idea: run Training on the player's own PC.
- PLAY needs 8 queued players; the server can lower it (`--match-size`) if the group prefers.

## Decisions

- Deploys: ask the user every time; never while people play (`server/deploy.sh` also refuses then).
- Load tests may use the VPS's game slots when nobody plays (user, 14 Oct); no deploys/restarts from tests.
- Cut content: restore everything that still works (tested in a match first); hide what doesn't, so
  everything players see is usable.
- Next deploy ships boons, artifacts and heirlooms together.
- Unreleased heroes: separated from released ones, with a disclaimer.
- Old Shard system (carry-and-turn-in, channeled Health Shrines): in, behind one switch, on by default (user, 14 Oct);
  the user tests it in multiplayer before it is deployed.
