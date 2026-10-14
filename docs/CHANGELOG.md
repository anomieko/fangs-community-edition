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

| Change | Commits | Off switch |
|---|---|---|
| Fix "failed to request server" / lobby closing when no standby server is ready: a lobby replaced by the same owner while its server boots gives that server to the newer lobby (requests per owner run one at a time) | see git log | revert the commit |

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
