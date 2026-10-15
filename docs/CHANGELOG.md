# Changelog

What each deploy put on the server, so a problem can be traced to a change and undone.

**How it works**
- `server/deploy.sh` only deploys committed code and tags what it deployed: `deploy-<UTC date-time>` (also written
  to `/opt/fangs-ce/repo/DEPLOYED` on the server). Add an entry here for every deploy.
- **Roll back everything**: check out the previous tag and deploy it (`git checkout deploy-…`, then the usual
  `server/deploy.sh …`). Players' launchers install whatever the server's signed file list says, so they get the
  older mods back too.
- **Undo one change**: `git revert <commits>` from its entry, commit, deploy. Or use its off switch below, which
  usually needs only a server deploy (no player update).
- **Data**: player data (`store.json` in the server's `fangs-data` volume) is only ever added to. Older backend
  versions ignore keys they don't know, so rolling back keeps profiles, friends and history.

## Next deploy (not deployed yet)

Nothing yet.

## deploy-2026-10-15-0309 (`cfb453c`, Feb 2023 build)

Nobody online.

Server only.

| Change | Commits | Off switch |
|---|---|---|
| Lobbies: a custom lobby leaves the lobby list once its match starts (it stayed listed during and after the match, so players joined finished games); only its own players can rejoin a running match; a finished match's server stops 10 s after everyone left or 2 min after the end screen | `0af69d8` | `post_match` in `HostManager` (`backend/hosts.py`); revert the commit |

## deploy-2026-10-15-0003 (`ce9f713`, Feb 2023 build)

Server only (no player update). Forced (`FANGS_DEPLOY_FORCE=1`): the user chose to kick the 3 players online.

| Change | Commits | Off switch |
|---|---|---|
| Maps: custom lobbies offer Embersong, Stormheart, Crownwatch; PLAY picks from all three (Crownwatch new). Arena (`LE_Arena01_Map`, a prototype: players hang on "Waiting for players") and Payload II removed; AI custom mode hidden (it spawned no bots) | `fe80e01` | `maps` / `PLAY_MAPS` / `AvailableCustomModes` in `backend/seed/make_seed.py` |
| Custom lobby modes: 6vs6, 5vs5, 4vs4, 3vs3 (was "Battle"), 2vs2, Duel, Solo; 6vs6 preselected; Trio (2 against 1) gone. A mode only sets how many can join | `ac76b9a` | `AvailableCustomModes` in `backend/seed/make_seed.py` |
| Friends: when both players send each other a request, both games now show them as friends (before: one side kept an unanswerable request, no friend in the list, whispers "from ()") | `55a2f1b` | revert the commit |
| Old Shards: a carrier whose hero is removed without dying (a player who leaves) loses the Shard to a shrine after 2 s instead of 15-48 s (FangsHost checks the hero's pending-kill flag). The "round-2 HoldingOrb tag loss" reported with `deploy-2026-10-14-2306` was a test artifact (`docs/recon/shards.md`); no game change for it | `363bba7` | revert the commit (server only) |

## deploy-2026-10-14-2306 (`88eb27e`, Feb 2023 build)

Forced (`FANGS_DEPLOY_FORCE=1`): the user chose to kick the one player online so they could test the old Shards
while the round-2 bug below is being fixed.

Launchers update themselves on the next start. The old Shard system is server side; FangsBoot's item texts reach
players when they restart the launcher (older clients keep the missing texts). Tested solo
(`tools/run/test_shards.sh`); multiplayer on the arena maps: the user, after this deploy.

| Change | Commits | Off switch |
|---|---|---|
| Launcher: the server's `FangsCE.exe` remembers the server and join code in its settings, so a player can later switch to the public build without an invite. The public build (GitHub Releases, `launcher/release.sh`) asks for an invite code (`server/invite.sh`) and then updates itself to the server's copy | `1d34ff1` | revert the commit and deploy (the public release only needs deleting on GitHub) |
| Game servers: no more ~200 ms hitches every few seconds. FangsHost's 2 s / 3 s loops no longer scan all objects during matches (game state through the game instance, players from `PlayerArray`); finished loops idle instead of being cancelled (cancelling stopped other loops in this UE4SS build); the fps cap is re-applied after map changes; the heartbeat adds `frame_ms` (longest frame) and `slow` (frames > 50 ms). Server only (`docs/recon/server-performance.md`) | `a191a4a` | revert the commit and deploy |
| Game servers: no movies, no CEF helper and no `-log` console window (`server/run-host.sh`): ~10-20% of a core and ~0.6 GB less per server | `b8ae8c7` | revert the commit and deploy |
| Backend: the 30 s `perf` line covers all heartbeats in its 30 s (`fps_min`, longest `hitch_ms` / `frame_ms`, sum of `slow`, `windows`) instead of the last 3 s window | `329acb8` | revert the commit |
| Mask of Mana and Vital Offering parked (off and out of the menus): they only react to channeled Health Shrines, which the Feb maps replaced with walk-over pickups. Superseded while the old Shard system is on (row below): they are restored with it | `345b154` | the old Shard system's switch (`OLD_SHARDS`) |
| Old Shard system back: on the arena maps Shards are carried and turned in at a Capture Zone (own zone: the Shard's buff; enemy zone: steal the enemy's buffs, respawn dead teammates); channeled Health Shrines replace the walk-over health pickups; Payload II's Shard works; the destructible Prismatic Shard stays off. The nine artifacts made for it are restored: Mask of Glory, Swiftrunner, Mask of Speed, Shadowbringer, Allseer, Mask of Ascension, Shardseeker, Mask of Mana, Vital Offering (`345b154` parked the last two; the switch restores them). Not on: Aspect speed-up per capture (`OLD_SHARDS_ASPECT_SPEEDUP`) | `7078cae`, `472a42e`, `ba21c5a`, `17bd30a` | `OLD_SHARDS = False` in `backend/seed/make_seed.py` (server only): Feb 2023 Shards and pickups, the nine parked |
| FangsBoot: Mask of Mana and Allseer show their descriptions, Mikado's Power Gong its name and description (missing string-table entries) | `17e4bb0` | revert the commit |

## deploy-2026-10-14-1903 (`5246bf3`, Feb 2023 build)

Players need to restart the launcher for the rainbow / one-line names (others keep plain names).

| Change | Commits | Off switch |
|---|---|---|
| Online list: the deploy's smoke test account no longer counts as online | `9b971cb` | remove `smoketest` from `SERVICE_USERS` |
| Online list: one line per name; names can carry a server-granted style (`CENameStyles` in the seed): "anomie" in animated rainbow; the free servers line stays last (FangsBoot asks `server-status?v=2`; older clients get plain names) | `9b971cb` | empty `CENameStyles` in `make_seed.py` (server only) |

## deploy-2026-10-14-1855 (`478b254`, Feb 2023 build)

Players need to restart the launcher for the FangsBoot changes; the rest is server-side.

| Change | Commits | Off switch |
|---|---|---|
| FangsBoot: the lobby list's Casual → Custom correction only touches Casual (never Training or other modes) | `170d298` | revert the commit |
| Main menu shows free game servers under the players-online count ("1 OF 2 GAME SERVERS FREE"), from the new `/fangsapi/*/server-status`; refreshed every 15 s | `498b8ad` | revert the commit (old clients keep using `online-players`) |
| FangsBoot fetches its lists (restored items, unreleased heroes) as soon as the game can, retries after 5 s instead of 30 s, and caches them next to the game (`fangsboot_*.txt`): hero select no longer shows the unreleased heroes for the first ~30 s after starting | `c49e624` | revert the commit |
| Main menu: "PLAYERS ONLINE" lists the online players' names (small text below the header; names only for logged-in players), free game servers below them; realm gold and soul cores hidden | `3eaa674` | revert the commit |
| BladeMaster removed from the unreleased heroes (grey mannequin, no abilities): not owned, not listed, not playable | `3eaa674` | add it back to `unreleased` in `make_seed.py` |
| Seven restored artifacts made for the old shard system parked (off and out of the menus): Mask of Glory, Swiftrunner, Mask of Speed, Shadowbringer, Allseer, Mask of Ascension, Shardseeker | `26ce56c` | move them from `_parked_old_shards` back to `Generic` in `backend/seed/restore-feb2023.json` |

## deploy-2026-10-14-1821 (`273d2d1`, Feb 2023 build)

Backend only (no player update). Requested by the user while players hit "failed to request server".

| Change | Commits | Off switch |
|---|---|---|
| Fix "failed to request server" / lobby closing when no standby server is ready: a lobby replaced by the same owner while its server boots gives that server to the newer lobby (requests per owner run one at a time) | `31ef490` | revert the commit |

## deploy-2026-10-14-1811 (`bb679fb`, Feb 2023 build)

Commits after `deploy-2026-10-14-1607` (`90e58f7` … `bb679fb`). Players need to restart the launcher (FangsBoot).
Deployed with `FANGS_DEPLOY_FORCE=1` (one player was in a lobby; the user chose to force it).

| Change | Commits | Off switch |
|---|---|---|
| Cut items back in play: 5 boons, 16 arena artifacts, 21 heirlooms, added to each player's hero by FangsBoot from the server's list (`/fangsapi/*/restored-items`) | `90e58f7`, `bc3db40`, `dc3a1fb` | remove rows from `backend/seed/restore-feb2023.json` (empty = nothing restored), server deploy |
| Menus list only usable items (`AvailableAugments` = in-match pools + restored items), fixes "Ebb & Flow" under Zoey | `bc3db40` | `make_seed.py`: `'AvailableAugments': augments('augments-feb2023.json')` (lists everything again) |
| Unreleased heroes (Withergrim, Ellis, Nuali, Scythe, Sniper, BladeMaster) owned, in their own Inventory section, behind a toggle in custom lobbies' hero select, notice on pick | `916dbd5` | `make_seed.py`: empty `unreleased` and drop them from `AvailableHeroes` (then FangsBoot shows nothing extra) |
| FangsBoot: Battle Pass/Store redirect deferred out of its hook (hang risk) | `14a9933` | revert the commit |
| Tests and docs only (no effect on players): `tools/run/test_items.sh`, `test_unreleased.sh`, `test_hero.sh`, `docs/` | various | — |

## deploy-2026-10-14-1607 (`92ca7d5`, Feb 2023 build)

Everything since the 13 Oct 2026 server: `4156b0e` … `92ca7d5`.

- Cosmetics: all skins, stickers, avatars (sigils), banners, titles, mounts owned; sticker saves fixed (`4156b0e`).
- Main menu: no Battle Pass, Store, missions or Discord banner; players-online count; dark background where
  the menu video can't play (`4156b0e`); end-of-match video panel hidden where it can't play (`c9a6c53`).
- Profiles: match history, levels, wins, ratings, leaderboard from finished matches (`c9a6c53`).
- Friends, parties, chat, party queue (`e80bf36`, merged in `6242b7b`).
- Custom lobbies: joiners no longer timed out after 45 s; PLAY only starts full games (`5643344`).
