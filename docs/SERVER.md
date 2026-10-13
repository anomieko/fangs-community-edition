# Running a Fangs: Community Edition server

Target: a small x86-64 Linux VPS (tested: Hetzner, 4 vCPU / 8 GB, Debian 13). ARM servers will not
work (the game is x86 Windows code running under Wine).

## Sizing

Each running match is one headless game process: ~3 GB RAM and up to ~1 CPU core. The backend itself
is tiny. `HOST_PORTS` sets how many matches can run at once (one UDP port each); 8 GB RAM → 2.

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
- **Container**: runs as an unprivileged user, read-only root filesystem, all Linux capabilities
  dropped, `no-new-privileges`, memory and process limits; game files mounted read-only. The game's
  own netcode (2020-era UE4 + Wine) is the most exposed component, which is why it is boxed in.
- **Limits**: one lobby per player; at most `HOST_PORTS` simultaneous matches (custom lobbies and
  matchmade games together; when all are busy, queued players wait).
- **Matchmaking** (PLAY): best effort, no ratings. A match starts when 8 players are queued or the
  first one has waited 15 s, with whoever is queued (backend options `--match-size`, `--match-wait`).
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

Deploying an update from your machine: rerun `server/deploy.sh` (fast after the first time).
Player data (names, profiles) lives in the Docker volume `fangs-data` (`/data/backend/store.json`).
