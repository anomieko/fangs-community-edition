# Fangs: Community Edition

A non-commercial community effort to keep **FANGS** playable after its official online services were
shut down. FANGS was a hero arena game built in Unreal Engine 4.26. Its backend (AccelByte) and
game-server hosting (Zeuz/Improbable) are gone. This project replaces those services so people who
built and played the game can run private custom matches again.

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

Players can create and join custom lobbies, pick heroes and play matches on a self-hosted server.
Target game build: **15 February 2023 (Steam build 10554626)**. Matchmaking is intentionally not
supported (custom lobbies only) and all content is unlocked.
See **[docs/STATUS.md](docs/STATUS.md)** and **[docs/SERVER.md](docs/SERVER.md)**.

## How it works

| Piece | Path | Role |
|---|---|---|
| Backend | `backend/` | Python (aiohttp) service that speaks the subset of the AccelByte API the game uses: login, profiles/cloud save, session browser (custom lobbies), lobby WebSocket, QoS. It also launches game servers. |
| Game servers | `server/run-host.sh` | Runs an unmodified game client headless under Wine as a dedicated lobby/match server (one per lobby). |
| UE4SS mods | `tools/ue4ss/` | Small Lua mods for [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS): `FangsBoot` (player side: skip the dead Epic login, use username login), `FangsHost` (server side: dedicated-server setup and replacements for server-only code missing from the client build), `FangsCtl` (remote control for automated tests). |
| Client config | `tools/run/config/Engine.ini.template` | User-level config that points the game at your backend. No game files are modified. |
| Research tools | `tools/pak`, `tools/bpdump`, `tools/re` | Pak reader, Blueprint bytecode decompiler (built on [UAssetAPI](https://github.com/atenfyr/UAssetAPI)), and small x64 helpers used to understand the client. |
| Notes | `docs/` | Findings about the client and the backend API it expects. |

Third-party tools (UE4SS, UAssetAPI) are downloaded separately into `third_party/` and are not part of
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
git clone --depth 1 https://github.com/atenfyr/UAssetAPI third_party/UAssetAPI
dotnet build -c Release tools/bpdump -o work/bin/bpdump
work/bin/bpdump/BpDump work/extract work/bpjson <asset.uasset | dir>...  # Blueprint -> JSON
python3 -I tools/bpdump/bp2txt.py work/bpjson -o work/bp                # JSON -> pseudocode

# end-to-end test on Linux (backend + 2 off-screen clients in a private network namespace;
# needs Wine, gamescope, a Vulkan GPU, and UE4SS in third_party/ue4ss/dist)
tools/run/test_lobby.sh
```

- Server: `server/` (Docker image, hardening script, deploy script) — see [docs/SERVER.md](docs/SERVER.md).
- Players (Windows): `player/build-full-client.sh` / `player/build-package.sh` → launcher `FangsCE.bat`.
- Players (Linux): `tools/play/local.sh <name>`.
