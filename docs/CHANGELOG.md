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
- **Players' notes**: every deploy that reaches players also gets a notes file for players in `backend/patchnotes/`,
  written in the same commit as its "Next deploy" lines, so the server ships it (format in `backend/patchnotes.py`).
  Players read it in the game under PATCH NOTES (it opens once by itself after an update); the PDF to post comes from
  the same file (`tools/patchnotes/build_pdf.py`). Name it `<UTC date>-<HHMM>.json` for about when you deploy, with
  `"tag": "deploy-<the same>"`: that is its id for good (the game remembers it as read), even if the deploy's own tag
  ends up a few minutes off. Plain words, what players notice; no internals.

## Next deploy (not deployed yet)

Player update and server update: the patch pak grows from 8 to 9 patches (`base-blockers`) and FangsBoot changes
(the PATCH NOTES tab, `blockers.lua`), so players get both through the launcher on their next start. The game
servers also get new network settings (`server/netcode.env`).

| Change | Where | Off switch |
|---|---|---|
| PATCH NOTES tab in the main menu: the updates (newest first) and each one's notes, scrollable, in the game's rich-text styles; opens once by itself on the first start after a new update (`patchnotes_seen.txt` next to `fangsboot.log`). Backend `GET /fangsapi/prod/patch-notes` from `backend/patchnotes/` (first file: the 17 Oct notes); PDF builder `tools/patchnotes/build_pdf.py` (`cp2-patchnotes`) | FangsBoot `patchnotes.lua`, backend `patchnotes.py`, `server/Dockerfile` | revert the `require("patchnotes")` block in FangsBoot's `main.lua` |
| Zoey's ult: the Zoey player sees the landing burst again, on every skin (only her own screen missed it: a GAS prediction key made her client skip the server's cue; `docs/recon/community-build-heroes.md`). Her client now plays it locally too. Player update (pak) | pak `community-heroes.json`, first entry (branch `cp2-zoey`) | remove the `BP_GA_CatSupp_Skill3` entry from `community-heroes.json` (`"enabled": false` would also switch off Ethryn's shield, Lamblaster and Stormlense) |
| Astrada's Flame Cage in team colours (Sheepa's list): her own and her teammates' cage yellow-orange (its blue and purple waves and flashes recoloured), an enemy Astrada's cage red (ring, waves, flashes, swords, embers, flames). Player update (pak). AssetPatch: `recolor-curve`, export paths of any length | pak `community-heroes.json` (`cp2-astrada`) | the two `NS_Astrada_Shift_System_*` entries out of `community-heroes.json`, then deploy |
| Base blockers on (the community's "Mickey Mouse fountain": once out of your base you can't walk back in until you die or the round ends, as in Aug 2022). Spawn protection now checks the hero itself, not the first player's hero (Feb bug); FangsHost takes the protection off any hero who still has it outside every blocker; Stormheart's and Crownwatch's blockers get their Aug collision (it was the class sphere's, too small) and protection sphere. Tested on all three maps (`docs/recon/base-blockers.md`) | pak `base-blockers.json`, FangsHost `blockers.lua` + `modes.lua`, FangsBoot `blockers.lua` (`cp2-base`) | `ENABLED = false` in both `blockers.lua` (FangsHost and FangsBoot); the patch alone: `"enabled": false` in `base-blockers.json` |
| Game servers tick the network at 60 without the listen-server clamp (was 30, clamped): in a measured 6v6 fight at 50 ms latency, half the small position corrections and half the visible jumps of other players, with the same bandwidth and about +0.1 vCPU per match; 2-player lobbies got through hero select 4 of 4 times (`docs/recon/server-performance.md`, "Rubber-banding") | branch `cp2-netcode` | `FANGS_NET_TICK=` (empty) in `server/netcode.env`, deploy |

## deploy-2026-10-17-1223 (`8059ad4`, Feb 2023 build)

Deployed with the user's OK ("lets deploy it"), nobody playing (the script's check), not forced. Smoke test
passed. Player update and server update: players get the new pak and FangsBoot from the launcher on their next start.

**The community patch** (Sheepa's list, OK'd 16 Oct; `docs/recon/community-patchnotes.md`) and **the Fiorne restore**
(the user's, `docs/recon/fiorne.md`), merged on branch `megapatch`. Each part was tested headless against a control
run without it (`docs/recon/community-build-*.md`), and then all together on `megapatch` (17 Oct): 86/88 changed
values loaded on both clients and the server at match start and end (the other two are nested HP values `check()`
can't read; Brutus shows 1050), lobby settings and the Captain vote, Training on the island and its server freed,
unreleased picks, queue, a full match with results, and Rowan's dash with its anti-CC in mid-map (the default test
sequence puts heroes at the enemy base, whose defences kill them). 220 backend tests, ruff, `rewrite-check` 0 failed.

Player update and server update: the patch pak grows from 1 to 8 patches. FangsBoot changes too, so players get both
through the launcher on their next start. The game servers load the same pak.

Before deploying: the Ishir clip must be at `work/media/shotgun-clip/snd-shotgun_blast.mp3` in the repo that deploys
(`docs/recon/community-build-ishir.md`). `build.sh` stops if it's missing.

| Change | Where | Off switch |
|---|---|---|
| Fiorne restore: the 0 Bunny Stacks fix (the stack system sets itself up whenever it starts); her Aug 2022 damage, reach, passive (+100 % attack speed for 1.25 s, every 7 s), Space (0.3 s between dashes), RMB and E/R values; 11 heirlooms back to Aug (Earthbreaker Pommel +95); 700 HP; all four dashes stop dead; two tooltips | pak `fiorne.json` (merged from `fiorne-restore`) | `"enabled": false` in `fiorne.json` |
| Numbers and texts: Rose, Wylde (LMB 40; RMB 95, short range, 1 s; Bounty's Reward 30; Speedshine +20 %), Ethryn (LMB 40-40-50; Holy Brazier 4 s / 1 s), Brutus 1050 HP, Zoey (real LMB heal 50; RMB shield 50 / 2 s; Shieldnip 1.5 s; Mentor's Locket +75; ult tooltip 150), Rayo (Pinpoint Spotter +50 %; Blitzhead max 35, no self-damage; LMB draw 0.25 s), Belroth (Angerstone Talons +40; Craterthorns 50); Somnia's ult 4 ticks/s; green Shard heal over 0.5 s (93 % of the 50 %; a single quarter-second tick gave only 63 %); blue Shard instant; Captain wait 18 → 2 s; "Heirlooms" → "Augments"; every knock-up is a stun; Training's "[TAB]" → "[P]" | pak `community.json` (`cp-values`, merge `5f5721e`) | `"enabled": false` in `community.json` |
| Rowan and dashes: CC immunity during Rowan's Dourling Dive and Belroth's Vicious Lunge (as in Aug); Rush runs to its end when stunned; Dourling Caltrops on the dashed path, without the cube, Iron Thorns look; Rowan's passive heals 2 % of missing HP + 3 HP per second, recomputed every tick (tooltip +3); Propagator's charge bar (FangsBoot) | pak `community-rowan.json`, FangsBoot (`cp-rowan`, merge `29cc88c`) | `"enabled": false` in `community-rowan.json`; the bar: revert the FangsBoot block |
| Hero code fixes: Ethryn's shield reflects only within her body width (push zone unchanged) and looks smaller; Belroth's boulder is reflected only when it reaches the shield; a reflected Lamblaster deals one hit, not one per pellet; Stormlense rises evenly to +50 % at max range | pak `community-heroes.json` (`cp-heroes`, merge `60432e1`) | `"enabled": false` in `community-heroes.json` |
| Passives that a death, stun, channel or cast at spawn could switch off for a whole match (Wylde's ammo, Fiorne's stacks, Rowan, Somnia, Zoey; Wylde's reload) can always start. The real-game trigger isn't proven | pak `community-passives.json` (`cp-passives`, merge `ec8e710`) | `"enabled": false` in `community-passives.json` |
| Ishir's ult: Sheepa's shotgun clip when the mark pops (10 dB down), a new SoundWave asset built from the local clip | pak `community-ishir.json` (`cp-ishir`, merge `0df45ca`) | `"enabled": false` in `community-ishir.json` |
| Custom lobby settings for the owner: map, teams 1v1-6v6, Bo3-Bo9, Captain vote, shuffle; seats that no longer fit wait and are removed at start; the lobby list follows map and size. Captain vote (custom option): 8 s, never the same Captain twice; off and in Casual/Ranked no vote screen | FangsBoot `lobbyui.lua`, FangsHost `lobby.lua`, backend, pak `community-lobby.json` (`cp-lobby`, merge `5d47a22`) | `"enabled": false` in `community-lobby.json`; revert the merge for the panel |
| Unreleased heroes pickable again: FangsBoot's finished loops go idle instead of being cancelled (cancelling one killed the loop that adds the unreleased filter) | FangsBoot (`cp-unreleased`, merge `f3ae986`) | revert `12bdc1e` |
| Training and modes: TRAINING loads the floating island; a Training server stops ~12 s after its player left (was 180 s); dummies stay alive after the round starts and the augment-phase immunity is off in Training/Solo; Wylde gets a full gun in the dummy phase, Bounty's Reward stacks from dummies are removed; presets save and load (FangsHost shim + backend). A player with no saved preset for a hero now starts with its recommended build 1 equipped (the game's own default, which never ran before); Shardseeker and Wing Rush removed. Built but off: the held augment phase and F6 (`HOLD_PHASE = false` in `modes.lua`), and the base blockers (`ENABLED = false` in `blockers.lua`, both mods) | FangsHost `modes.lua`, FangsBoot `blockers.lua`, backend, seed (`cp-modes`, merges `eb760cf`, `439101c`) | revert the merges; seed: `REMOVED` in `make_seed.py` |
| AssetPatch: `set-export-prop`, `props`; the function rewriter (`insert-call`, `remove-call`, `rewrite-check`); `set-tags`, `set-name-const`, `set-branch`, `insert-copy`, `wrap-call-arg`, `insert-code`, `replace-call-arg`, `rename-prop-ref`, `soundwave-audio`, `insert-play-sound` | tools only (`assetpatch-export-prop`, `assetpatch-rewrite` and the streams) | – |

Known gaps (not in this deploy): the base blockers (in the combined run, heroes who spawn inside them got the game's spawn protection with an ability lock that only walking out removes, so teleported test heroes couldn't cast all match; a blink out of the base might do the same), the held Training augment phase and F6, Astrada's cage colours, Zoey's Hellhound ult
effect (not reproduced), reconnect, Burning Harvest, Ishir's health preview, the netcode A/B tests.

## deploy-2026-10-15-2336 (`662f8ea`, Feb 2023 build)

Deployed with the user's OK, **forced** (`FANGS_DEPLOY_FORCE=1`) with 5 players in lobbies or matches (the user's
decision); their games ended with the restart. **Not tested in a match** (the user's decision: "i trust it no need
to test"). Smoke test passed.

Player update (FangsBoot): players get it from the launcher on their next start. The server restarted too: FangsBoot is
part of the server image (`COPY tools/ue4ss`), although game servers don't run it.

| Change | Commits | Off switch |
|---|---|---|
| Somnia gets the restored boons and artifacts (5 boons, 16 arena artifacts) in her item picker, like every other hero. FangsBoot skipped her pawn because its class is `BP_BookMage_Char2_C`, not `BP_<Hero>_Char_C` (`docs/recon/items.md`) | `da231a0` | revert the commit and deploy |

## deploy-2026-10-15-2144 (`4f83b89`, Feb 2023 build)

Deployed with the user's OK, forced (`FANGS_DEPLOY_FORCE=1`) with 8 players on: nothing server-side had changed since
`deploy-2026-10-15-2104` (only `launcher/` and docs), so the image was rebuilt the same and the container kept running
(same container, start time unchanged; compose: "Running"). Smoke test passed. The server serves the new launcher
(its hash matches the signed file list).

Launcher only: players' launchers update themselves on their next start.

Then the public launcher on GitHub: release `launcher-4f83b89` (built by `launcher/release.sh` from this commit; no join
code, server address or invite in it), now "latest", so the README's download link serves it; `launcher-1d34ff1` stays.

| Change | Commits | Off switch |
|---|---|---|
| Launcher: the mod loader files (`dwmapi.dll`, `ue4ss/UE4SS.dll`, FangsBoot's `main.lua`) are checked before the game starts. If one went missing since the last start, or right after the download, it is put back and the launcher says that Windows Security (or another antivirus) removed it and how to add the game folder to the exclusions. If it is gone again 5 s after the game started, the launcher says the game can't log in ("Steam authorization") and waits for Enter instead of closing | `5328a05` | revert the commit and deploy |

## deploy-2026-10-15-2104 (`8de8382`, Feb 2023 build)

Deployed with the user's OK, **forced** (`FANGS_DEPLOY_FORCE=1`): 7 players were in lobbies and matches, and the user
chose to end them instead of waiting. **The headless game regression was skipped** (the user's decision): these changes
were checked by 210 backend unit tests, the launcher's Go tests (Linux, and the Windows ones under Wine) and
`tools/run/test_download.sh`, not by real clients. Run the regression when the user isn't playing (ROADMAP item 7).

Server + player update: players' launchers update themselves (new launcher, `FANGS.exe`) on their next start. Clients
that were open across the restart must restart the game (their tokens are gone).

Also on the server, outside `deploy.sh`: BBR (`/etc/sysctl.d/90-fangs-network.conf`,
`/etc/modules-load.d/fangs-bbr.conf`, the `server/harden.sh` lines); `bbr` is active, `default_qdisc = fq` applies from the
next reboot. Undo: remove both files, then `sysctl -w net.ipv4.tcp_congestion_control=cubic net.core.default_qdisc=fq_codel`.

Live check after the deploy: smoke test passed (game server after 32 s). 517 download pieces (8.0 GiB, the pak in 378)
are on the server; two fetched through the join-code route matched the signed file list. `FANGS.exe` is the launcher,
the server's files match the signed local build, and all are served (200). Backend log, first minutes: no errors,
tracebacks, watcher or Ranked alerts; the 401s came only from clients open across the restart.

| Change | Commits | Off switch |
|---|---|---|
| Patch pak build: no `FangsCE_P.patches` note next to the pak (it went into the players' download folder; harmless) | `1bacb1c` | none |
| `deploy.sh`: the "people are playing" check runs before anything is uploaded, and the server-code upload no longer deletes the server's `server/.env` and `server/downloads/` (a refused deploy used to leave no downloads) | `90ebe4e` | none (deploy script only) |
| Old `.bat` client retired: `server/build-client.sh` and the package scripts are gone (the user's decision; its updates were unsigned) | `a902150` | none |
| Login names are case-insensitive: "ALICE" is alice's account and needs her secret (it used to get a new entry with her user id: an account takeover). The backend logs names already stored twice at start; the first spelling keeps the account | `ea9634e` | none (security fix) |
| Custom lobbies need a login: listing and looking up lobbies needs a token (the game always sends one); only a lobby's owner or our game servers may change or delete it (deleting one used to stop its server, for anyone, without a login); only the owner can request its game server; the lobby connection refuses unknown tokens | `d940e1b` | none (security fix) |
| A new custom lobby no longer ends the owner's running match (the old server keeps playing); a second server request for a lobby gets its server again, and a server that isn't the lobby's can't remove it | `d940e1b` | none |
| Players can't write the server-kept records (wins, levels, match history) or their profile's identity (`Username`, `AccountType`) any more: `update-player-record-key` refuses them (the client only writes `Justice` there), and a CloudSave write of the profile keeps the stored identity | `792c596` | none (security fix) |
| Request log: refresh tokens and the join code in download paths are redacted; a request that fails in the backend is logged with its error (it used to be a bare 500 with no log line); a body that isn't JSON gets a 400 | `a683976` | none |
| PLAY (Casual and Ranked) works while a custom lobby or another game is running: the idle standby server counted as busy, so with 2 slots one open lobby stopped all matchmaking. Matches never outnumber the servers: a match in its accept dialog holds one, and a match that still finds none sends its players back in line with their place (they used to be dropped to the menu). A cancelled match no longer starts anyway, and a server isn't kept for a match everyone left during its boot | `09f76d1` | revert the commit |
| Social: a player who reconnects while their drop runs stays online; a kick racing a leave no longer closes the leader's connection; party mates of a player who logs in again don't hear "disconnected" last; a chat line cut at 500 characters keeps its escaping; the party-command guard in lobby chat ignores case | `0ba4b9d` | none |
| Game server lifecycle: a server is stopped even if its watcher fails; a slot is reclaimed only past the watcher's own grace (a match whose players are still loading the arena is no longer stopped after 20 s); a server booted for one lobby can't be handed to another; a standby claimed the moment it was ready is replaced, and one whose boots all failed is tried again after a minute; a stopped server leaves no heartbeat behind (deploy.sh no longer counts its players); a result left by a dead server no longer ends the next lobby on that port; no server starts during shutdown; no leaked ports or tasks | `b75b3cf` | revert the commit |
| Second review of the above: a player may still add or remove themselves in a lobby (rejoining a started custom match needs it); the lobby lookup lists the newest lobby first; a watcher error no longer ends a live match (the server is stopped when it exits); a request that gives up leaves its server claimable; a 500 also prints its full traceback | `645086d` | none |
| Match results: each player's history and levels change all at once or not at all; a record that can't be read costs only that player the match (it used to stop the update halfway, the rest of the players got nothing) | `d34da0b` | none |
| A Ranked game whose server stops without a result (crash, nobody came) releases its roster at once | `d985523` | none |
| Ranked fixes from a review: a player who quits mid-match still counts for their team (quitting can't void a lost game); a game where a matched player never joined is void; rank points no longer drop by hundreds when the rating reopens a player's uncertainty; a party member in the other mode stops the party; `--ranked-size` only 2/4/6/8 (`docs/recon/ranked.md`) | `d764f5f` | revert the commit |
| Launcher install help (players' launchers update themselves on their next start): the public launcher asks for the invite first, then where to install; an invite code pasted as the folder or name is refused; a folder with other things in it (Downloads, `D:\Games`) gets a `Fangs Community Edition` subfolder; the folder is checked (writable, enough space, not in OneDrive); a bare name is taken from the user's folder, not from wherever the launcher ran. An install made with the old question (relative, named after the invite, straight into a full folder) is found and fixed on the next start, and a full folder is never moved on a build switch. The launcher keeps a copy of itself in `%LOCALAPPDATA%\Programs\Fangs Community Edition` and makes desktop and Start menu shortcuts once; the game folder's `FANGS.exe` is now the launcher (it hands over to that copy) | `0c9c809` | revert the commit and deploy (launchers update themselves back and `FANGS.exe` is the game's again; existing shortcuts and the copy stay and keep working) |
| Faster downloads (`docs/recon/downloads.md`): files of 4 MiB or more also come as gzipped 32 MiB pieces (`chunks/` in the download folder, served at `/download/<code>/chunks/`), 4 at a time; the pak is ~7 GB to download instead of 12.6. The launcher updates itself first; older launchers ignore the pieces. The first deploy with it uploads ~7 GB of pieces. `harden.sh`: BBR for new servers | `1922bb8` | delete `server/downloads/chunks/` on the server: launchers fetch the same pieces as byte ranges of the whole files (still 4 at a time, not compressed) |
| Parties: a player left alone in a party can be invited and can make a party again (the game shows a party of one as none; it used to answer "already in a party"); an invite to someone who has since joined another party no longer holds a party slot, and a repeated invite reaches them again | `c4556f5` | none |

## deploy-2026-10-15-1714 (`09c27b1`, Feb 2023 build)

Deployed with the user's OK. Live check after the deploy: the players' file list has `FangsCE_P.pak` (1,366,002 bytes), and both game
servers' game copies have it.

Server + player update: players' launchers download `FangsCE_P.pak` (1.4 MB) the next time they start.

| Change | Commits | Off switch |
|---|---|---|
| CC revert (`docs/recon/cc-changes.md`):<br>• Back to stuns, with Aug durations: Brutus' Quakebreak Talisman Earthquake centre (1.5 s, radius 150), Ethryn's Knightseeker wall hit (0.75 s), Fiorne's Earthbreaker Pommel (1.0 s), Astrada's Flame Cage (1.0 s, cage 3 s) and Repulsing Scepter (0.5 s), Zoey's Spirit Scratch (0.9 s; its heirloom hit-extension no longer roots Zoey herself), Rowan's Dourling Dive (0.75 s).<br>• Somnia's Allure charms again (0.75 s, Glamorfume +0.05 s per stack), with its Aug charm visual.<br>• Somnia's abilities are locked only during her ult's 0.5 s cast.<br>• Rowan's Glade Slash doesn't lock abilities.<br>• Tooltips say stun. | `209d2f2`, `3fdd080` | `"enabled": false` in `tools/patch/patches/ccrevert.json`, then deploy (launchers remove the pak) |
| Patch pak support (`docs/PATCHING.md`): the deploy builds `FangsCE_P.pak` from the enabled patches into the players' download folder, and game servers load the same file (`FANGS_PAKS`). The download folder is now uploaded before the server restarts. With no patch enabled, no pak is built. | `209d2f2` | nothing to switch off; revert the commit |

## deploy-2026-10-15-1637 (`48efa57`, Feb 2023 build)

Nobody online.

Server only (no player update). Ranked ratings start fresh for everyone (750 rank points); the old ratings from casual
and custom games are no longer shown, and the leaderboard lists only players with a Ranked game.

| Change | Commits | Off switch |
|---|---|---|
| Ranked: the game's Ranked tile (10 wins, parties of up to 2) opens a skill-based queue: teams chosen and balanced by a TrueSkill-style rating (`docs/recon/ranked.md`), the game's own draft hero select (16 s per round). Only Ranked changes the rating, rank points and leaderboard; Casual and custom games have none. The server runs `--ranked-widen-speed 2` (limits widen twice as fast as the research schedule) and `--ranked-size` 8 | `6a0baa9` | `RANKED = False` in `backend/seed/make_seed.py` hides the tile; revert the commit for the old casual ratings |

## deploy-2026-10-15-0317 (`d06573a`, Feb 2023 build)

Nobody online.

Server only.

| Change | Commits | Off switch |
|---|---|---|
| Chat: team and all chat work in custom lobbies, hero select and matches (they were dropped unless the players were friends or in a party) | `1aaf6a5` | `LOBBY_CHAT = False` in `backend/social.py` |

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
