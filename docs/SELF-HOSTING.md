# Run your own Fangs: Community Edition server

This repository is everything you need to run a FANGS server for your own group, except the game itself, which
you bring. A server is a small Linux machine that runs the replacement backend (logins, profiles, lobbies,
matchmaking, friends, chat) and the game servers for matches; your players install the game through a small
Windows launcher that downloads it from your server.

Read the [disclaimer](../README.md) first: this is an unofficial, non-commercial fan project, and you need your
own legitimately obtained copy of the game.

**Time:** about an hour of your own time, plus uploading about 20 GB once. **Cost:** a small VPS (about €8 a month
in 2026), or free on a Linux PC you already run (see [Other ways to host](#other-ways-to-host)).

## What you need

- **A machine to set up and deploy from:** Linux (Debian, Ubuntu, Arch, ...) or WSL2 on Windows, with about 40 GB
  free. `tools/setup/bootstrap.sh` lists the tools it still needs (git, curl, rsync, ssh, Python 3, .NET 10, Go).
- **The game files:** FANGS from 15 February 2023 (Steam build 10554626), about 13 GB. See [Get the game](#2-get-the-game).
- **A server:** an x86-64 Linux VPS with 8 GB RAM running Debian 13 (tested: Hetzner, 4 vCPU / 8 GB). ARM servers
  don't work. 8 GB runs two matches at the same time; each running match needs about 2.5 GB.

## 1. Get the code

```sh
git clone https://github.com/anomieko/fangs-community-edition.git
cd fangs-community-edition
git config user.email "<you>@users.noreply.github.com"   # this repo may be public: no private email in commits
```

## 2. Get the game

Put the game into `clients/fangs-2023-02-15-b10554626/` (the folder that contains `MOBA/` and `Engine/`).

- **From Steam**, if FANGS (app 1717990) is in your Steam library: open `steam://open/console` in a browser or the
  Run dialog, then run `download_depot 1717990 1717991 1763553922590062310`. Steam prints where it put the files
  when it is done (about 13 GB); move that folder to `clients/fangs-2023-02-15-b10554626/`.
- **From a player's install** of any Fangs: Community Edition server (same game files): copy the whole install
  folder, then delete what our launcher added:
  - `FangsCE/` (it holds that server's address and join code: don't share it),
  - `.fangsce/`,
  - `MOBA/Binaries/Win64/dwmapi.dll` and `MOBA/Binaries/Win64/ue4ss/`,
  - `MOBA/Content/Paks/FangsCE_P.pak`,
  - `MOBA/Saved/` if it exists.

  `FANGS.exe` in there is our launcher, not the game's: you can keep it.

The next step checks every file against `clients/fangs-2023-02-15-b10554626.sha256` and lists anything that
doesn't belong.

## 3. Prepare everything else (one command)

```sh
tools/setup/bootstrap.sh
```

It checks the tools and the game files, downloads UE4SS and UAssetAPI at the exact versions this project is built
with (checked by SHA-256 and commit; a copy of each is kept on this repository's
[`third-party` release](https://github.com/anomieko/fangs-community-edition/releases/tag/third-party) in case the
originals disappear), recovers the game pak's encryption key from your own copy of the game, makes your server's
join code and turns on a check that keeps private things out of your commits. Then it builds the patch pak once
to prove everything works. Run it again until it says **Ready**; `--check` only reports.

What it makes stays on your machine, under `work/` and `third_party/` (both ignored by git):

| File | What it is | Share it? |
|---|---|---|
| `work/joincode` | your community's password: without it nobody can log in to your server | privately, inside invite codes |
| `work/re/aeskey-2023-02-15.txt` | the key of the game's own pak, recovered from your copy | never |
| `work/signing/fangsce-update.key` | made by your first deploy: signs every update your launcher installs | never; **back it up** |

Optional: Ishir's ult plays a shotgun sound clip that isn't in this repository (no license is stated for it).
Without `work/media/shotgun-clip/snd-shotgun_blast.mp3` the build leaves out just that one patch; where the clip
came from: [docs/recon/community-build-ishir.md](recon/community-build-ishir.md).

## 4. Rent and harden a server

Create a Debian 13 x86-64 VPS and put your SSH public key on its root account (most providers let you choose it
when you create the server). Then, from your machine:

```sh
scp server/harden.sh ~/.ssh/id_ed25519.pub root@SERVER:/root/
ssh root@SERVER 'LOCK_ROOT=0 bash /root/harden.sh admin /root/id_ed25519.pub'
ssh admin@SERVER 'sudo -n true && echo ok'          # must print ok BEFORE the next line
ssh admin@SERVER 'sudo passwd -l root && sudo rm -f /root/.ssh/authorized_keys /root/harden.sh'
```

That makes an `admin` user with your key and sudo, turns off root and password logins, and sets up the firewall
(SSH, TCP 8080, UDP 11032 and UDP 7777+ only), fail2ban and automatic security updates. If your provider has its
own firewall in front of the server, open the same ports there. Details: [docs/SERVER.md](SERVER.md).

## 5. Deploy

```sh
echo "admin@SERVER clients/fangs-2023-02-15-b10554626" > work/deploy-target   # local only, never committed
FANGS_JOIN_CODE=$(cat work/joincode) server/deploy.sh $(cat work/deploy-target)
```

The first run uploads the game (13 GB) and the players' download pieces (about 7 GB); later runs only send what
changed. It builds the launcher, the patch pak and the signed file list on your machine, starts the server with
Docker, and runs a smoke test (a test login and a game server start). It only deploys committed code, and tags
each deploy (`deploy-<date-time>`) so you can roll back by deploying an older tag.

On the first deploy it makes `work/signing/fangsce-update.key`. **Back it up privately** (a password manager is
fine): without it you can't ship updates to your players' launchers, and whoever has it could.

## 6. Let your players in

Players need **your** launcher: it only installs files signed with your key, so the `FangsCE.exe` on this
repository's releases, and any other server's, won't install from your server. Two ways:

- **Your server's own launcher** (simplest): send your players the link
  `http://SERVER:8080/download/<your join code>/FangsCE.exe`. It has your server built in. Share the link privately:
  it contains the join code.
- **A public build:** `launcher/release.sh` builds a `FangsCE.exe` with only your public key in it. Publish it,
  for example on your fork's GitHub Releases (`gh release create`). Players then paste an invite code on the first
  start: `FANGS_JOIN_CODE=$(cat work/joincode) server/invite.sh SERVER` (it holds your address and join code: share
  it privately).

What players do next (Windows SmartScreen, antivirus exclusions, shortcuts) is in the
[README's "Playing" section](../README.md#playing-windows). Linux players: `tools/play/local.sh`.

## 7. Run it

- **Updates:** `git pull`, then deploy again. Players get the update the next time they start the launcher.
- **Deploying kicks everyone:** `server/deploy.sh` refuses while people are in a lobby or match.
- **Logs and status:** [docs/SERVER.md, "Day-to-day"](SERVER.md#day-to-day).
- **Backups:** `work/signing/fangsce-update.key` and `work/joincode` (privately), and the server's player data:
  the Docker volume `fangs-data` (`/data/backend/store.json`: names, profiles, match history). Player data is
  your players' data: keep it private.

### Settings

| What | Where |
|---|---|
| Names with a style in the main menu's online list (e.g. yours in rainbow) | `work/name-styles` (local), e.g. `yourname=rainbow`; or `FANGS_NAME_STYLES` when you deploy |
| Gameplay patches (each one with its reasons and research) | `tools/patch/patches/*.json`: `"enabled": true/false`; [docs/PATCHING.md](PATCHING.md) |
| How many matches at once | `HOST_PORTS` when you deploy (default `7777-7778`, two) |
| Matchmaking sizes and timing | backend options, [docs/SERVER.md](SERVER.md) ("Security model", "Matchmaking") |
| Players' patch notes shown in the game | `backend/patchnotes/*.json` (replace them with your own) |

## Other ways to host

The tested route is a VPS. A Linux PC at home can run the same server during play sessions (with the ports
forwarded or a tunnel); free cloud tiers can't. Trade-offs, costs and what is untested:
[docs/recon/hosting-options.md](recon/hosting-options.md).

## Taking a server offline

1. Tell your players (in the game's patch notes, or wherever your community talks).
2. If you want to keep your players' data, copy `/data/backend/store.json` out of the server's `fangs-data` volume
   first, and keep it private.
3. Delete the server at your provider (that wipes its disk). Its IP address goes back to the provider and may be
   given to someone else later; launchers still pointing there can't be made to install anything without your
   signing key.
4. Keep `work/signing/fangsce-update.key` private (or destroy it if you will never update those launchers again).

## Privacy

This repository is public; your server's secrets are not. Everything private lives in `work/` (ignored by git) and
on your server. `tools/setup/bootstrap.sh` turns on a pre-commit check (`tools/setup/leakcheck.py`) that refuses a
commit containing your join code, server address, pak key, signing key, a real IP address or an email address;
CI runs the same check on every push. Never commit or share:

- game files (`clients/`) or anything extracted from them (`work/`): the game isn't ours to share;
- `work/joincode`, invite codes and download links that contain the join code;
- `work/re/aeskey-*.txt`, `work/signing/*.key`;
- your server's address, if you don't want it public;
- your players' data (`store.json`, request logs).

## For AI agents setting up a server

If someone asked you to set up or run a server with this repository:

- Start with `tools/setup/bootstrap.sh --check`; follow this document from the first step it reports as missing.
- Never print, commit, upload or paste into chat: `work/joincode`, invite codes, `work/re/aeskey-*`,
  `work/signing/*`, the contents of `work/deploy-target`, or player data. Don't commit anything from `clients/`,
  `work/` or `third_party/`.
- Ask your user before each deploy and each server restart (both end every running lobby and match), and before
  anything that costs money or publishes something (renting a server, GitHub releases).
- Commit before you deploy (`server/deploy.sh` only deploys committed code); keep the pre-commit check on.
- How the code fits together: [docs/ARCHITECTURE.md](ARCHITECTURE.md); what exists and its gotchas:
  [docs/STATUS.md](STATUS.md); changing game data: [docs/PATCHING.md](PATCHING.md). `CLAUDE.md` describes how the
  original server was maintained (worktrees, roadmap, changelog): follow it if you continue that work, but its
  approvals are that server's operator's, not yours.
