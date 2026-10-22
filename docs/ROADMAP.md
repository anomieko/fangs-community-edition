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

Last updated: 2026-10-18.

## Live on the server

Current deploy: `deploy-2026-10-21-0241` (`e6c9721`); what each deploy changed: `docs/CHANGELOG.md`.
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

- since 17 Oct 12:23 UTC: the community patch (a community member's list) and the Fiorne restore: 8 patches in the pak, the lobby
  settings and Captain vote, Training on the island, presets, the unreleased-heroes fix, passives that never started
  (`docs/CHANGELOG.md` has every change and its off switch). Base blockers and the held Training phase are built
  but off.
- since 17 Oct 20:43 UTC (forced: the user's call): the base change (once out, no way back in until death or the
  round's end), net tick 60 (less rubber-banding), Tufts' Wing Dive lined up with the server, the PATCH NOTES tab,
  Astrada's cage in team colours, Zoey sees her own ult's landing (`docs/CHANGELOG.md`).
- since 17 Oct 23:47 UTC: base walls (a white ring at each base's border and a fire wall across its exit, as in Aug
  2022), no base turrets (patch `base-turrets`), the main menu crash fix (`settled` in FangsBoot).
- since 21 Oct 02:41 UTC: the always-on safety net (Fiorne's Bunny Stacks, Wylde's reload), the Captain vote and
  stuck-lobby fixes, Fiorne's damage nerf, Ethryn's six heirloom nerfs, Rowan's heal back and the Sourblossom fix.

## Done, not deployed

Nothing right now. Open: Wylde's E (Lamblaster) holding back LMB/RMB (`Ability.Skill4` in their
blocked tags until the recoil hop ends); `tools/run/test_wylde.sh` can't get Lamblaster to cast on the server yet.

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
   FangsBoot's finished loops go idle too now (on `megapatch`): cancelling one had killed the loop that adds the
   unreleased-heroes filter.
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

9. **Fiorne restore** (user, 16 Oct: "she's my favourite champion, but she's not really playable in this patch"; plan
   approved; rebalanced the same day to 700 HP, the Aug passive cooldown and a smaller Earthbreaker Pommel, the
   user's choice after a roster comparison). Research and evidence: `docs/recon/fiorne.md`. **Live** since `deploy-2026-10-17-1223`:
   `tools/patch/patches/fiorne.json`.
   - What it does: the Bunny Stacks fix (the stack system sets itself up whenever it starts), Aug 2022 numbers for LMB,
     passive (7 s cooldown), Space, RMB, E, R and 11 heirlooms (Earthbreaker Pommel +95; Feb's move speed and buffed
     heirlooms kept), 700 base HP, all four dashes stop dead, two tooltips. **Live** since `deploy-2026-10-17-1223`.
   - Tested with and without the pak (`tools/run/test_fiorne.sh`): 700/700 HP; Space dashes 0.6 s apart 3 of 3 (1 of
     3); dash end 2750 → 0 within 50 ms; after a mid-round restart of the stack system the stacks refill. In the
     combined run she starts with her recommended build (presets now load): Wanderer's Travelpack gives 5 stacks and a
     longer Space cooldown, as its tooltip says.
   - Next: players' feedback. a community member (Q40): once broken, her stacks stayed broken all match; `community-passives`
     covers the "never started" case too.
10. **The community patch list** (a community member's list, 16 Oct): researched (`docs/recon/community-patchnotes.md`), answered
   (42 questions), proposed and OK'd by a community member (second PDF), built in eight streams (`docs/recon/community-build-*.md`)
   and merged on `megapatch`. **Live** since `deploy-2026-10-17-1223`. In it: numbers and texts, knock-ups as
   stuns, Rowan, the CC-immune dashes, Ethryn's shield, Lamblaster, Stormlense, passives that never started, Ishir's
   sound, the lobby settings and Captain vote, Training on the island, the Training server grace, presets, Wylde's
   dummy-phase ammo, the artifacts, and the unreleased-heroes filter fix.
   Follow-ups (a community member's order where he gave one):
   1. reconnect to custom games (the game has it built in; about 2 days; `docs/recon/community-build-lobby.md`), after
      the big patch (user, 17 Oct);
   2. the base blockers: fixed and on, live since `deploy-2026-10-17-2043` (`docs/recon/base-blockers.md`); the walls
      that show the border and no base laser are done, not deployed (above).
      Feb's spawn protection went to every hero while the first player stood in a base (patch `base-blockers`, plus a
      FangsHost safety net), and Stormheart's and Crownwatch's blockers were too small. Tested headless on all three
      maps (walking, teleport, death, round change). Abilities inside the base in the augment phase stay as the game has
      them (locked in round 1 only; user, 17 Oct);
   3. the held Training augment phase and F6: built, off (`HOLD_PHASE`); a lock-in still sets a game-state flag
      (`docs/recon/community-build-modes.md`);
   4. Burning Harvest (Rowan), Ishir's health preview, Training on the player's PC, less laggy dummies, the Loadouts
      tab, DPS numbers, spectating;
   5. Astrada's cage colours and Zoey's ult effect: live since `deploy-2026-10-17-2043` (the cage effects' own
      colour curves recoloured; only the Zoey player missed her burst, on every skin);
   6. netcode: net tick 60 and Tufts' sync change live since `deploy-2026-10-17-2043`; still open: the Dec 2023
      settings and Crownwatch's rendering.
   Players' feedback decides the numbers; each is one line in its patch file.

## Known issues and small ideas

- **Alternative hosting investigated (22 Oct); decision pending.** Current idle snapshot: 2.513 GiB,
  20.77% of one CPU core, no players. Free web tiers cannot run the current game stack. Compare a small
  x86 VPS, on-demand Fly hosting and a community member's PC in [hosting options](recon/hosting-options.md).
  Next: select a direction, then qualify it with a complete match; no migration or live changes made.

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
- Proper patches over hooks (user, 16 Oct: "making proper patches is the proper way"): new game logic goes into the
  patch pak through AssetPatch's function rewriter; FangsHost/FangsBoot are for sessions, lobby and UI.
- The community list (16 Oct): a community member answers, then a "now → after" proposal for his OK, then build (user). a community member
  OK'd it the same day, with his changes (`docs/recon/community-patchnotes.md`, "a community member's OK").
- Fiorne (user, 16 Oct): the restore plan, rebalanced to 700 HP, the Aug passive cooldown (7 s) and Earthbreaker
  Pommel +95 after a roster comparison.
- Ishir's ult sound (user, 16 Oct): ship a community member's clip as he asked ("a community member's clip anyway is fine"); it is never committed.
- Reconnect comes after the big patch is deployed (user, 17 Oct).
- Fiorne's damage nerfed about halfway back towards Feb (user, 21 Oct: "she became a monster", OK'd the numbers in
  `docs/recon/fiorne.md`, "Damage nerf"); 700 HP and her mobility stay.
- The base in the augment phase stays as the game has it (user, 17 Oct: "keep as is"): abilities are locked inside
  the base in round 1's augment phase, not in later rounds' (`docs/recon/base-blockers.md`).
- No base laser (user, 17 Oct: "since you cant re-enter base its not needed"), and the base's border visible as in the
  old version ("a wall spawned you couldnt get into").
- Tufts' Wing Dive ships with the sync change on (user, 17 Oct: "on"): his screen dashes at once and the server
  follows. Players' feedback decides whether it stays; off switch `"enabled": false` in `tufts-sync.json`.
- Kept dummies and no augment-phase immunity in a custom lobby launched alone are intended, as a community member asked: the
  user first called it a bug, then "apparently thats intended" (17 Oct). The change limiting it to TRAINING is unshipped
  (branch `dropped-cp2-solo`).
- Gameplay changes to the game's own data are permanent and go into the patch pak, the same file for players and
  servers (`docs/PATCHING.md`). Runtime hooks are not used for them (user, 15 Oct).
- CC revert scope (user, 15 Oct):
  - Reverted: the stun/charm → root conversions and Somnia's ult lock (plus Rowan's LMB lock, which the developers
    removed again by Dec).
  - Not reverted for now: the other CC duration changes.
  - The user tests it locally before it is enabled and deployed.
