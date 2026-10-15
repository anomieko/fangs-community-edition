# Running a Fangs: Community Edition server

Target: a small x86-64 Linux VPS (tested: Hetzner, 4 vCPU / 8 GB, Debian 13). ARM servers will not
work (the game is x86 Windows code running under Wine).

## Sizing

Each running match is one headless game process: ~2.5 GB RAM (plus ~0.1 GB of Wine helpers) and, for a full
match, roughly one vCPU of a small VPS; an idle standby a few % of one. The backend itself is tiny. Load test:
`tools/run/test_perf.sh` (`docs/recon/server-performance.md`). `HOST_PORTS` sets how many game servers can run at once (one UDP port each); 8 GB RAM → 2.
One of them is normally a booted standby, so a lobby or match starts instantly.

## Signed updates

`server/deploy.sh` builds the launcher, the player files and the file list (`manifest.json`) **on your
machine**, signs the file list with `work/signing/fangsce-update.key` (Ed25519, created on the first deploy)
and uploads the result. `FangsCE.exe` has the public key built in and refuses unsigned or altered file lists,
including updates of itself. So neither someone who takes over the VPS nor someone on a player's network can
make launchers install anything; at worst they can break downloads.

- The key never goes to the server. **Back it up** (e.g. in a password manager): without it you can't ship
  updates to existing launchers; whoever has it could.
- The very first download of `FangsCE.exe` from the server is plain HTTP and not covered. The public build on
  GitHub Releases (HTTPS) avoids that, and browsers don't block it the way they block an `.exe` over HTTP:
  `launcher/release.sh` builds it (only the public key built in; check it with `strings`), publish with
  `gh release create`. Players paste an invite code on the first start: `FANGS_JOIN_CODE=$(cat work/joincode)
  server/invite.sh <public-host>` (share it privately, like the join code). The launcher then updates itself
  to the server's copy.
- `server/build-client.sh` (full client zip, `.bat` launcher packages) is not signed; deploy doesn't use it.

## Game server lifecycle

- One standby server is kept booted; a new lobby or matchmade game takes it, and the next one boots.
- A lobby everyone left before its match started stops after 20 s; a match everyone left stops after
  3 minutes (time to reconnect); a server nobody joined stops after 3 minutes.
- When all slots are busy, the server that has been empty the longest is stopped for the new game.
- A server that dies while booting is restarted (up to 3 attempts).
- Game servers run under Wine 11.18 from WineHQ (pinned in `server/Dockerfile`). Debian's Wine 10.0
  crashed them on map changes.

## First-time setup

From a machine with this repo and your game files:

```sh
# 1. Hetzner: create/rebuild with Debian 13 and get your SSH key onto root
#    (if the panel can't attach keys on rebuild, use the web console:
#     mkdir -p .ssh; curl -sL github.com/<you>.keys >> .ssh/authorized_keys)

# 2. harden: admin user with your keys + sudo, root/password logins off, firewall, fail2ban, auto-updates
scp server/harden.sh <keys-file> root@SERVER:/root/
ssh root@SERVER 'LOCK_ROOT=0 bash /root/harden.sh <admin> /root/<keys-file>'
ssh <admin>@SERVER 'sudo -n true && echo ok'          # verify BEFORE the next step
ssh <admin>@SERVER 'sudo passwd -l root && sudo rm -f /root/.ssh/authorized_keys /root/harden.sh'

# 3. deploy (uploads ~13 GB the first time; later runs only send changes)
python3 -c "import secrets; print(secrets.token_urlsafe(9))" > work/joincode   # keep it private
FANGS_JOIN_CODE=$(cat work/joincode) server/deploy.sh <admin>@SERVER clients/<build> SERVER

# 4. build the player download on the server
ssh <admin>@SERVER 'cd /opt/fangs-ce/repo/server && sudo ./build-client.sh'
# -> http://SERVER:8080/download/<join code>/FangsCE-Client.zip
```

## What is exposed

| Port | What | Notes |
|---|---|---|
| TCP 22 | SSH | key-only, admin user only, fail2ban |
| TCP 8080 | backend API + downloads | logins need the community join code |
| UDP 11032 | region ping (QoS) | echo only |
| UDP 7777+ | game servers | one per running match |

Everything else is dropped by the firewall (`/etc/nftables.conf`, table `inet fangs`).

## Security model

- **SSH**: no root login, no passwords, `AllowUsers <admin>`, fail2ban (bans grow on repeat offenders).
- **Join code**: the launcher sends `<join code>:<per-install secret>`; without the code nobody can
  get a token, create lobbies or start game servers. Rotate it by changing `FANGS_JOIN_CODE` in
  `/opt/fangs-ce/repo/server/.env` (root-only) and rebuilding the player package.
- **Names**: first login binds a name to that install's secret; nobody else can log in as you.
- **Server-only APIs** (server login, game records, other players' records) only work from the
  machine itself (the game hosts) — remote callers get 401/403.
- **Match statistics** (history, levels, wins, ratings, leaderboard) are written only by the backend, from
  the results the game servers save when a match ends; players can't set them. The main menu's
  players-online count (`/fangsapi/*/online-players`) is a number anyone can read.
- **Friends and chat**: friend requests need the exact `name#1234`; party details and invites only travel
  between friends and party members.
- **Container**: runs as an unprivileged user, read-only root filesystem, all Linux capabilities
  dropped, `no-new-privileges`, memory and process limits; game files mounted read-only. The game's
  own netcode (2020-era UE4 + Wine) is the most exposed component, which is why it is boxed in.
- **Limits**: one lobby per player; at most `HOST_PORTS` simultaneous matches (custom lobbies and
  matchmade games together; when all are busy, queued players wait).
- **Matchmaking** (PLAY): no skill matching. A match starts when it is full: 8 players queued (4 vs 4;
  parties stay together). Backend options: `--match-size` (players per game), `--match-wait N` (start after
  N seconds with whoever is queued, at least 2). Custom lobbies start whenever their owner launches.
- **Not encrypted**: game traffic and the backend API are plain HTTP/UDP, like the original game
  outside its TLS endpoints. Don't reuse a password-like secret anywhere else (the launcher
  generates random ones). Adding TLS would need a domain name.
- **Updates**: Debian security updates install automatically (`unattended-upgrades`).

## Day-to-day

```sh
ssh <admin>@SERVER
cd /opt/fangs-ce/repo/server
sudo docker compose ps                 # status
sudo docker compose logs -f --tail 50  # live backend log (one JSON line per request)
sudo docker compose restart            # restart everything (kicks players)
sudo fail2ban-client status sshd       # banned IPs
```

Deploying an update from your machine: rerun `server/deploy.sh` (fast after the first time). The live server's
SSH target and game dir are kept in `work/deploy-target` (one line, `<admin>@<host> clients/<build>`; local only,
never committed), so: `FANGS_JOIN_CODE=$(cat work/joincode) server/deploy.sh $(cat work/deploy-target)`.
Player data (names, profiles) lives in the Docker volume `fangs-data` (`/data/backend/store.json`).
