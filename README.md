# Fangs: Community Edition

A non-commercial community effort to keep **FANGS** playable after its official online services were
shut down. FANGS was a hero arena game built in Unreal Engine 4.26. Its backend (AccelByte) and
game-server hosting (Zeuz/Improbable) are gone. This project replaces those services so people who
built and played the game can run private custom matches again.

**Want to play?** Ask whoever runs your community's server for their launcher (`FangsCE.exe`) and an invite: see
[Playing](#playing-windows). (The green "Code" button downloads this project's source code, not the game.)

**Want to run your own server?** Everything is here except the game files, which you bring:
**[docs/SELF-HOSTING.md](docs/SELF-HOSTING.md)** (a small Linux VPS, one setup command, one deploy command).

> ## ⚠️ Disclaimer
>
> - **This is an unofficial fan project.** It is not affiliated with, endorsed by, or sponsored by
>   Hidden Leaf Games or any other owner of FANGS.
> - **We do not own FANGS.** The FANGS name, logos, game code, binaries, art, audio and all other game
>   content belong to their respective owners.
> - **No game content is included here.** This repository contains only our own replacement-service
>   code, tooling and notes. To use it you need your own legitimately obtained copy of the game.
> - **Non-commercial.** We do not sell anything, charge for access, accept payment, or monetize
>   this project in any way.
> - **No license is granted.** We cannot grant any license or rights to FANGS or its content, and
>   this repository does not come with a license.
> - **Rights holders:** if you own rights to FANGS and want anything here changed or taken down,
>   please open an issue. We will respond promptly.

## Status

Players can queue for matches (PLAY: Casual starts full 4v4 games, parties together; Ranked builds fair teams
from skill ratings) or create and join custom lobbies, pick heroes and play on a self-hosted server. Friends,
parties, chat, match history, levels and a leaderboard work; all heroes and cosmetics are unlocked.
Target game build: **15 February 2023 (Steam build 10554626)**.
See **[docs/STATUS.md](docs/STATUS.md)** and **[docs/SERVER.md](docs/SERVER.md)**. How the code fits together:
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**; backend tests: `python3 -m unittest discover -s backend/tests`.

## Playing (Windows)

You need your server's launcher and, for a public launcher build, an **invite code** (it starts with `FCE-`), both
from whoever runs your community server. Each server signs its own updates, so a launcher only works with the
server it came from. (The [FangsCE.exe on this repository's releases](https://github.com/anomieko/fangs-community-edition/releases/latest/download/FangsCE.exe)
is the original community server's.)

1. Download **FangsCE.exe** from the link your server's operator gives you. It's the only file you need: a small
   launcher that downloads the game (about 13 GB) from your server. If the browser says the file isn't commonly
   downloaded, choose **Keep**.
2. Start it. Windows may say "Windows protected your PC" because the launcher isn't code-signed: click
   **More info → Run anyway**.
3. Paste your invite code when it asks for it. When it asks where the game should go, **press Enter** for the
   suggested folder (or type another folder, like `D:\Games`). Then pick a player name.
4. The launcher downloads the game and starts it. To play next time, use the **Fangs Community Edition** shortcut
   on your desktop or in the Start menu: it updates the game and logs you in. (The game's own .exe can't log in.)

If Windows Security removes a file (often `dwmapi.dll`, the mod loader), add the install folder under
Windows Security → Virus & threat protection → Exclusions, then start the launcher again: it puts back
whatever is missing.

## How it works

| Piece | Path | Role |
|---|---|---|
| Backend | `backend/` | Python (aiohttp) service that speaks the subset of the AccelByte API the game uses: login, profiles/cloud save, store catalog, session browser (custom lobbies), lobby WebSocket (friends, parties, chat), matchmaker, leaderboard, QoS. It also launches game servers and keeps match history, levels and ratings. |
| Game servers | `server/run-host.sh` | Runs an unmodified game client headless under Wine as a dedicated lobby/match server (one per lobby). |
| UE4SS mods | `tools/ue4ss/` | Small Lua mods for [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS): `FangsBoot` (player side: skip the dead Epic login, use username login), `FangsHost` (server side: dedicated-server setup and replacements for server-only code missing from the client build), `FangsCtl` (remote control for automated tests). |
| Client config | `tools/run/config/Engine.ini.template` | User-level config that points the game at your backend. No game files are modified. |
| Patch pak | `tools/patch/` | Gameplay changes to the game's own data (e.g. ability effects and numbers) as one extra pak that the game loads after its own. It is built from your game files at deploy, never committed (`docs/PATCHING.md`). |
| Research tools | `tools/pak`, `tools/bpdump`, `tools/re` | Pak reader, Blueprint bytecode decompiler (built on [UAssetAPI](https://github.com/atenfyr/UAssetAPI)), small x64 helpers used to understand the client, and a Ghidra wrapper that decompiles chosen functions (`tools/re/decomp.sh`). |
| Setup | `tools/setup/` | `bootstrap.sh` prepares a clone for your own server (tools, game check, pinned third-party code, pak key, join code; [docs/SELF-HOSTING.md](docs/SELF-HOSTING.md)); `leakcheck.py` keeps private things out of commits (pre-commit hook and CI). |
| Notes | `docs/` | Findings about the client and the backend API it expects. |

Third-party tools (UE4SS, UAssetAPI, Ghidra and its JDK) are downloaded separately into `third_party/` and are not part of
this repository. Game installs live in `clients/` and extracted or generated data in `work/`; both are
git-ignored.

## Development

```sh
# backend
python3 -m venv backend/.venv && backend/.venv/bin/pip install aiohttp
python3 backend/seed/make_seed.py <public-host:port>
backend/.venv/bin/python backend/fangs_backend.py --port 8080 --public-ip <public-ip> \
    --game-dir <path to game install>

# research tooling
python3 -I tools/pak/paklist.py    <pak> work/pakfiles.tsv            # list pak contents
python3 -I tools/pak/pakextract.py <pak> work/extract '<regex>'        # extract files
tools/setup/bootstrap.sh                                             # tools, UE4SS + UAssetAPI (pinned), pak key
dotnet build -c Release tools/bpdump -o work/bin/bpdump
work/bin/bpdump/BpDump work/extract work/bpjson <asset.uasset | dir>...  # Blueprint -> JSON
python3 -I tools/bpdump/bp2txt.py work/bpjson -o work/bp                # JSON -> pseudocode
# native code: Ghidra 12.1.4 + Temurin JDK 21, unpacked into third_party/ (check the release SHA-256 first)
#   github.com/NationalSecurityAgency/ghidra/releases, adoptium.net (OpenJDK21U-jdk_x64_linux_hotspot_*.tar.gz)
tools/re/decomp.sh <exe> -depth 1 <UFunctionName | 0xVA>...            # decompile chosen functions

# end-to-end test on Linux (backend + 2 off-screen clients in a private network namespace;
# needs Wine, gamescope, a Vulkan GPU, and UE4SS in third_party/ue4ss/dist)
tools/run/test_lobby.sh
```

- Server: `server/` (Docker image, hardening script, deploy script) — see [docs/SERVER.md](docs/SERVER.md).
- Players (Windows): launcher `launcher/` (`FangsCE.exe`): the server's copy has the server built in
  (`server/deploy.sh`); the public one (`launcher/release.sh`, GitHub Releases) asks for an invite code
  (`server/invite.sh`).
- Players (Linux): `tools/play/local.sh <name>`.
