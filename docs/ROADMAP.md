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

Last updated: 2026-10-16.

## Live on the server

Current deploy: `deploy-2026-10-15-2336` (`662f8ea`); what each deploy changed: `docs/CHANGELOG.md`.
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
- since 15 Oct 21:04 UTC (forced with 7 players on, headless regression skipped: the user's decisions): the review
  sprint's fixes (login names case-insensitive, lobby login and ownership checks, protected records, PLAY next to a
  running lobby or game, game-server lifecycle, social and match-result fixes), Ranked review fixes, a party of one is
  no party, launcher install help (invite first, checked folder, shortcuts, `FANGS.exe` starts the launcher), faster
  downloads (gzipped 32 MiB pieces, 4 at a time) and BBR on the VPS.
- since 15 Oct 21:44 UTC: the launcher puts back mod loader files an antivirus removed and tells the player how to add
  the exclusion (no more silent "Steam authorization"); the public launcher on GitHub is `launcher-4f83b89` (invite
  first, the install checks and this one).
- since 15 Oct 23:36 UTC (forced with 5 players on, no match test: the user's decisions): Somnia's item picker has the
  restored boons and artifacts like every other hero (FangsBoot skipped her pawn, `BP_BookMage_Char2_C`;
  `docs/recon/items.md`). To confirm in play: a Somnia player's `fangsboot.log` says
  `restored items: 21 added to BP_BookMage_Char2_C`.

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
   also skip movies, CEF and the `-log` console. On the VPS (seven 4-8 player matches, 15 Oct): 58-60 fps,
   typical gaps 12-15 ms, one single 75-240 ms frame every 1-3 minutes (`docs/recon/server-performance.md`).
   Next: find what those single frames are (GC? wineserver?), and a 6v6 when enough people are on. Open: ntsync on the VPS (capacity, needs kernel + Wine change);
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
7. **Review sprint** (external backend review on 16 Oct): branch `review`, worktree `../fangs-review` (owns
   `docs/review/`, `backend/tests/` and the review's fixes). Plan and rules: `docs/review/SPRINT.md`. Ledger (every
   finding, its state and the test that pins it): `docs/review/FINDINGS.md`. Lifecycle matrix:
   `docs/review/LIFECYCLE.md`. Architecture: `docs/ARCHITECTURE.md`.
   Done on the branch (not merged, not deployed): 8 independent reviews; 20 findings fixed (ledger rows), code ones
   each with a test that failed first; a second review of the fixes themselves (5 corrections). 199 backend unit tests run on production's
   Python and aiohttp; CI runs them with ruff. The `deploy.sh` fix is already on `main` (`90ebe4e`, user's OK).
   Merged into `main` and pushed on 15 Oct (user's request); the party-of-one fix and the test-data
   guards (no test touches `backend/data` or `work/hosts`) merged last, after `ranked-fixes`, `install-ux`, `fast-download`. Live
   since `deploy-2026-10-15-2104` (forced; the headless regression was skipped, both the user's decisions). Next: that
   regression as an after-the-fact check, from a worktree and never while the user plays (`pgrep -af
   '[M]OBA-Win64-Shipping.exe'`): test_lobby, test_queue, test_social, test_chat, test_ranked, `NOSHOW=1 RUN=rankedns`
   test_ranked, test_match, test_download; then tomorrow's external review.
8. **Players' install trouble** (user, 15 Oct): players installed into Downloads and it didn't work, pasted their
   invite code as the install folder (the old launcher asked for the folder first and took any answer as it was, so
   the game went into a folder named after the code, relative to wherever the launcher ran), and didn't know
   `FangsCE.exe` is how they start the game. Live since `deploy-2026-10-15-2104`:
   invite asked first, then the folder (after the self-update, so the server's launcher asks); an invite code is
   refused as a folder or name; a full folder gets a `Fangs Community Edition` subfolder; writable, free space and
   OneDrive checks; a bare name is taken from the user's folder; an install from the old question is found and fixed
   on the next start; a folder with other things in it is never moved on a build switch; the launcher copies itself
   to `%LOCALAPPDATA%\Programs\Fangs Community Edition` and makes desktop and Start menu shortcuts once; the game
   folder's `FANGS.exe` is a copy of the launcher that hands over to that copy (`server/deploy.sh`).
   The GitHub release is `launcher-4f83b89` (15 Oct, after `deploy-2026-10-15-2144`), so newcomers get the invite-first
   order from the start. Open: a player who starts `MOBA-Win64-Shipping.exe` (e.g. pinned to the taskbar while the game ran) still
   gets no login; FangsBoot could start the launcher instead.
   Live since `deploy-2026-10-15-2144`: the launcher checks the mod loader files before and 5 s after starting the
   game, puts back what an antivirus removed and tells the player how to add the exclusion, instead of leaving them at
   "Steam authorization" (a new player's report, 15 Oct; it resolved on the player's side, cause not confirmed).

9. **The community patch list** (a community member's list, 16 Oct, about 60 items: general, artifacts, custom lobby, training,
   optimization, 12 heroes). State: researched, nothing built. `docs/recon/community-patchnotes.md` has every item with
   its cause in the Feb build, the plan, the size and the open question.
   - Questions out (16 Oct): 42 to a community member as a fillable PDF (Q1-Q42, listed in the recon file). The "Michael Mouse
     fountain" was cleared up through swagnaros: block re-entering the base, as in Aug (the base blockers).
   - Blocked on a community member's answers for most hero, lobby and training choices.
   - Ready without answers (the community's numbers match the Feb build):
     - patch-pak values: Rose's Puzzlebox, Wylde's LMB, Bounty's Reward, Speedshine, Holy Brazier, Mentor's Locket,
       Blitzhead Arrows, Angerstone Talons, Craterthorns;
     - backend: the short grace for Training servers.
   - Next:
     - `tools/patch/patches/balance.json` with those values, and `test_patch.sh` runs;
     - AssetPatch `set-export-prop` (Brutus' HP, Ethryn's shield, Belroth's boulder, Astrada's cage colour, the
       Caltrops box);
     - A/B tests of the Dec netcode settings, never while people play.
   - Needs the user's call: several items need new logic the pak can't express (Rowan's heal, Wylde's ammo in the
     dummy phase, Fiorne's stacks, the training phase and timer, Bo5+, team shuffle, the base blockers). Do them through
     FangsHost/FangsBoot, against the 15 Oct "pak, not hooks" decision, or through a heavier AssetPatch op?

## Known issues and small ideas

- Ranked (and probably Casual): with a no-show, the others' lobby screen gives up after ~45 s ("Failed to Connect to
  Match.") just as FangsHost would start without the missing player (seen in `NOSHOW=1 tools/run/test_ranked.sh`).
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

- Next deploy (user, 15 Oct, through the coordinating session fangs-4a): merge into `main` in this order:
  `ranked-fixes` → `install-ux` → `fast-download` → the review sprint's party fix. Then ONE headless regression covering all
  four (test_lobby, test_queue, test_social, test_chat, test_ranked, NOSHOW=1 test_ranked, test_match, test_download,
  one after another, never while the user plays on the dev machine), then ONE deploy with the user's OK at the time,
  nobody playing, after the 16 Oct external review. BBR on the VPS goes in with that deploy, not before. The
  party-of-one fix is part of this deploy.
- Casual (PLAY) starts only full games (8 players); the early start stays off (`--match-wait` 0) (user, 15 Oct).
- Trio custom mode removed (`ac76b9a`): the user's call (15 Oct).
- The old `.bat` client (FangsCE.bat, unsigned updates over HTTP) is retired; `FangsCE.exe` is the only installer
  (user, 15 Oct).
- `tools/pak/findkey*.py` and `docs/recon/playtest-source-paths.txt` stay in the repo (user, 15 Oct).
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
