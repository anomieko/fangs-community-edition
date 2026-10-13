# Client: FANGS Closed Playtest — `main_v0_0_444`

> **This is the special Closed Playtest build, not the final/target client.**
> It is kept as a reference because it is a *Development* build and leaks far
> more internals (source paths, log strings, console, server code) than a
> Shipping build would. The client we ultimately decomp may be a different
> version — see `clients/` for others as they are added.

## Provenance

| Field | Value |
|---|---|
| Steam app | 1831080 — "FANGS Closed Playtest" |
| Steam depot / manifest | 1831081 / 5738023829398519305 |
| Steam build id | 12965227 |
| Retrieved | 2026-10-13 (from a team member's Steam library) |
| Game version (`MOBA/Content/Data/version.txt`) | `main_v0_0_444` |
| Exe build timestamp (manifest) | 2023-12-14T19:03:22Z |
| Developer | Hidden Leaf Games |
| Integrity | `clients/playtest-main_v0_0_444.sha256` (388 files) |

Key hashes (SHA-256):

- `MOBA/Binaries/Win64/MOBA.exe` — `019402b678b6c429c18c3416777a1cd7d58c30408ff0f5ef62d1e46c1ca80a95`
- `MOBA/Content/Paks/MOBA-WindowsNoEditor.pak` — `3ecfa985aba000f496526fca3d571d25fc5d86435c7144daa226e07f291e84d9`

## Build facts

- Unreal Engine **4.26.2**, custom source build (`++UE4+Release-4.26-CL-0`).
- **Development** configuration, built by Jenkins job `FangsDeveloperBuild`
  (`D:/JenkinsWorkspaces/FangsDeveloperBuild/`). Console, logging, GameplayDebugger,
  check()/ensure strings are present.
- Monolithic `MOBA/Binaries/Win64/MOBA.exe` (179 MB). `MOBA.pdb` is listed in
  `Manifest_DebugFiles_Win64.txt` but was **not** shipped.
- `FANGS.exe` / `MOBA.exe` at the root are UE bootstrap launchers.
- Game module `/Script/MOBA`; built on GameplayAbilities (GAS).
- ~98 original source paths embedded → `docs/recon/playtest-source-paths.txt`.
- 113 `U/A`-prefixed MOBA classes → `docs/recon/playtest-moba-classes.txt`.

## Content

- Single pak `MOBA-WindowsNoEditor.pak`: v11, 12.4 GB, 48,612 files,
  **no encryption, no compression**. Readable with `tools/pak/`.
- Cooked with unversioned package headers but **tagged** properties
  (no `.usmap` needed; open as UE 4.26).
- Maps: `LE_Arena01/02/06_Map`, `LE_Payload03/04_Map`, `LE_TrainingGround`,
  `LE_Tutorial02_Map`, `LE_MainMenu_Map`, `LE_Lobby_Map`, `LE_Loading_Map`,
  `LE_MarketingLevel`, `LE_BeautifulCorner`. (`LE_UnderWorldArena` is in
  `MapsToCook` but absent from the pak.)
- Loose: 1.3 GB of movies (`MOBA/Content/Movies`), 43 FMOD banks (`MOBA/Content/FMOD/Desktop`).

## Online services (all dead)

- AccelByte: `dev2.hiddenleaf.accelbyte.io` (namespace `fangs`, publisher `hiddenleaf`).
  Client + server (DSM) credentials are baked into `MOBA/Config/DefaultEngine.ini`
  inside the pak — **scrub before publishing anything derived from it.**
- Improbable/Zeuz IMS session manager: `session-manager.ims.improbable.io`.
- Telemetry: AWS API gateway endpoints; Nexus (`api.nexus.gg`) creator codes.
- `MOBA/Content/Data/config.json` feature flags:
  `IsAccelByteEnabled`, `IsPreviewHeroesEnabled`, `IsZeuzCustomIMSEnabled`, `IsAccelbyteChatEnabled` (all `true`).
