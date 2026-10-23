# Fangs Forever feasibility and design

22 October 2026. Proposed separate edition and repository: **Fangs: Forever**. Scope chosen by the user:
custom lobbies only; their creator hosts the match inside their own visible game; no matchmaking queues.
Edgegap was excluded by the user during this investigation.

This is worth a bounded prototype. Removing queues, global rankings and dedicated match machines makes
a substantially smaller product possible. The principal unknown is whether the shipped February 2023
game can reliably combine the local player's UI and gameplay with the authoritative host role. The
existing dedicated-style host already uses Unreal's listen-server machinery, but deliberately removes
the local player. Networking services cannot resolve that game-specific uncertainty.

Recommended direction: local profiles and presets, a discoverable list of custom lobbies, relayed public
connections, and an explicit LAN/direct mode that can survive the directory's disappearance. Evaluate
Epic Online Services for managed lobby discovery and connectivity; retain an independently operable
directory/relay design as the alternative. Provider choice follows the local gameplay proof.

## Evidence and feasibility boundary

The source examined is the current Community Edition implementation at `f18e865`, targeting Steam build
10554626. No game binary was modified or executed for this investigation. These are source-derived
constraints, not a successful visible-host demonstration.

| Current behavior and evidence | Consequence for Forever |
|---|---|
| `FangsHost/scripts/main.lua`: `OpenLevel(..., "listen")`, after removing the local player; another loop removes local players after map loads | The core hosting primitive exists. Both removal paths must change, and the host must get a real profile, lobby slot, team, controller, camera and HUD. Keeping the controller alone is insufficient. |
| The same file compensates for dedicated-server-only lobby initialization and compiled-out server CloudSave callbacks | Those compatibility functions remain necessary even without an Internet backend. Client login and server-side record access must coexist in one process. |
| `ensureTravel` deliberately routes map travel through a remote controller | A visible host needs a different travel path, including a host playing alone, without duplicate travel commands. |
| Heartbeat counts exclude local controllers; lobby/match frame caps are 15/30/60 | Count the host correctly. Redesign frame limiting so the player's rendering and the host's simulation behave well together. |
| `FangsBoot` already implements custom-lobby list/create UI, names, launch controls and lobby options | Reuse UI hooks and gameplay fixes; replace allocation of a remote dedicated process with local hosting. |
| `server/run-host.sh` uses `-nullrhi -nosound` and Wine | This wrapper is inappropriate for a visible player host. Windows uses the native game process; Linux can keep its player-side Wine path. |
| `backend/hosts.py` launches processes and consumes local files; backend server authorization trusts loopback | Move minimal game-compatibility functions into a local helper. Do not expose the existing privileged backend to other players. |
| `launcher/main.go` verifies Ed25519 manifests and SHA-256 files; signature checking is conditional on a configured key | Reuse the update primitives, with a mandatory production key and a separate Forever trust root. |

Relevant source: [host mod](../../tools/ue4ss/Mods/FangsHost/scripts/main.lua),
[player mod](../../tools/ue4ss/Mods/FangsBoot/scripts/main.lua),
[custom lobby logic](../../tools/ue4ss/Mods/FangsHost/scripts/lobby.lua),
[backend](../../backend/fangs_backend.py), [launcher](../../launcher/main.go),
[player packaging](../../player/install-player-files.sh).

Host-side and client-side mod behavior must execute once in the correct role. A local authoritative
player may skip replication notifications that remote clients receive; its HUD, effects, ability
prediction and team selection need explicit checks. Minimizing the window, losing focus, pausing,
loading a map or saturating the host GPU must not silently stall everyone else's simulation.

## Player experience and discovery

The menu can be reduced to Host Lobby, Browse Lobbies, Join by Code and LAN/Direct. Hosting creates a
custom session with a map, mode, capacity and visibility. Public rooms appear in the browser; private
rooms require an invite. Host kick/ban and join controls remain local session decisions. No queue,
ranked authority, global progression or central match history is required for the proposed first release.

Lobby discovery and game traffic have separate jobs. A directory is a small address book containing
short-lived lobby advertisements. It does not simulate matches. A relay forwards game packets between
the host and guests. A service such as EOS can supply both functions; an independent implementation can
operate them separately.

For an independent directory, a proposed lifecycle is:

1. The launcher starts the local compatibility helper and game. Hosting establishes local readiness
   and a usable connection route before the room is marked joinable.
2. The host authenticates to the directory, registers a lobby lease and sends a heartbeat approximately
   every 30 seconds. The record expires after approximately 90 seconds without renewal. These timings
   are initial design values, not measured requirements.
3. Browser records contain lobby ID, display name, map, mode, occupancy, coarse region, joinability and
   exact compatible build/mod identifiers. Public records contain no residential IP address or relay secret.
4. Joining requests a short-lived, lobby-scoped admission ticket and connection details. Capacity is
   reserved atomically for a bounded time; the host/transport validates admission before forwarding
   game packets. Merely knowing a lobby ID does not grant membership in a private room.
5. When the match starts, the room becomes in-progress or non-joinable according to the supported game
   flow. Return-to-lobby and rematch retain the group if that flow proves reliable. Host departure
   closes the room; a crash expires its lease. Host migration is outside the initial scope.

Use unguessable, revocable invite capabilities and rate limits. Private rooms must be excluded from
public listing and search, not merely visually hidden. A private room remains known to its service
operator. Treat lobby names, counts and region claims as untrusted input; bound strings and avoid
rendering markup or executing anything received in metadata. Do not use arbitrary advertised URLs for
server-side probes. Keep peer addresses out of public ping probes in relay-only mode.

An Internet-wide browser needs a rendezvous service somewhere. Manual addresses, LAN discovery and
out-of-band invites can reduce that dependency, but do not automatically solve NAT traversal. A distributed
directory would still need bootstrap peers, moderation and anti-spam mechanisms; it offers little benefit
for the first release.

## Networking options after excluding Edgegap

| Option | Discovery and connectivity | Benefits | Qualification needed |
|---|---|---|---|
| Epic Online Services | EOS Lobbies/Sessions plus EOS P2P | Advertised free game services; managed connectivity; relay-only control is available | Own product setup, supported player identity flow, release access, Windows/Linux helper integration, latency and actual IP-hiding behavior |
| Steamworks | Steam lobbies and Steam networking/SDR | Integrated discovery, invites and relay networking | Authorized application/service access and integration. The original FANGS App ID is not evidence that this project can configure those services. |
| Independent directory and relay | Small HTTPS directory plus authenticated UDP relay | Full control, transferable operation, no required game-store account | Hosting/bandwidth costs, maintenance, abuse limits, authenticated encryption and transport implementation |
| Direct connections | Manual address/invite; optional directory | No relay bill; useful LAN and preservation mode | Reachable host or NAT traversal, inconsistent connectivity under restrictive NAT, residential IP visibility to peers |

EOS explicitly offers P2P, sessions and lobbies as multiplayer services. Its `ForceRelays` setting is
documented to hide peer IP addresses, while the default allows direct attempts first. A privacy-oriented
release must deliberately choose and verify relay-only behavior. Free service availability is not a
completed production integration, and the player authentication flow remains an open design item.
[EOS multiplayer](https://onlineservices.epicgames.com/multiplayer?lang=en-US),
[Epic's service overview](https://onlineservices.epicgames.com/en-US/news/introduction-to-epic-online-services-eos?lang=en-US),
[EOS relay control](https://dev.epicgames.com/docs/en-US/api-ref/enums/eos-e-relay-control).

Steam documents a lobby as an entity on its backend and supports connecting players to a nominated
player host. SDR is available through Steam networking APIs subject to platform requirements. Valve's
open-source GameNetworkingSockets includes encryption and NAT traversal, but does **not** grant access
to Steam's hosted relay network or authentication. It is a possible transport component, not a complete
free hosting service.
[Steam lobbies](https://partner.steamgames.com/doc/features/multiplayer/matchmaking),
[Steam Datagram Relay](https://partner.steamgames.com/doc/features/multiplayer/steamdatagramrelay),
[GameNetworkingSockets](https://github.com/ValveSoftware/GameNetworkingSockets).

For the independent option, a small directory could fit a free service tier. Cloudflare currently makes
SQLite-backed Durable Objects available on Workers Free, with request, duration and storage limits;
exceeding free limits causes failures. This is a directory candidate, not a UDP game relay. Actual usage,
rate limiting and failure behavior must be checked before claiming a zero-cost service.
[Cloudflare pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/).

Keep a small provider boundary for lobby operations and packet transport so another community can
replace a vanished service. Implement one provider first; no multi-provider federation is required.

## Adapting a compiled Unreal game to a relay

The project does not contain the complete Unreal source needed to rebuild its network driver. A
candidate approach is a local UDP adapter in the launcher helper:

```text
Guest game <-> guest helper <-> relay <-> host helper <-> host's visible game
                  |                         |
                  +---- lobby discovery ----+
```

Each game talks to a local endpoint. Helpers wrap the datagrams in the selected provider transport.
On the host side, each guest needs a distinct local socket/address mapping so Unreal sees separate
connections. The host's own player remains local to the same game instance.

This is a design hypothesis. Verify Unreal's handshake, source-address validation, NAT rebinding,
packet sizes, fragment reassembly, loss, connection timeouts, map travel and rejoin. Preserve datagram
semantics; do not blindly put all gameplay through an ordered reliable stream. Bind the game and local
control APIs to loopback where supported, and prove remote traffic cannot bypass the admission adapter.
If safe binding or distinct guest mappings cannot be achieved, evaluate a socket-level mod rather than
claiming the adapter works.

The helper also answers the small subset of local AccelByte-style API calls the game still expects.
Local settings, cosmetics, presets and any personal history stay on disk. Share only the validated
profile fields needed for the current lobby with its host. Removing the queue does not itself remove
the game's dependencies on profile and configuration callbacks.

## Privacy and safety

Recommended public default: relay-only sessions, authenticated encryption between each guest and the
host, and no silent switch to direct connections. Direct mode should state its IP-sharing consequence
before connecting. Invite-only does not itself hide IP addresses.

| Party | Information it needs or may observe |
|---|---|
| Other players in a relayed room | Chosen name, public player identity if used, selected profile/cosmetics, chat and gameplay; no residential IP through the intended transport |
| Host | All authoritative gameplay and the current lobby's shared data; it can change rules, cheat or end the match |
| Directory operator | Connection IP, lobby membership/metadata and admission activity; retain only what is needed for bounded abuse handling |
| Relay operator | Public network addresses, timing, packet sizes and routing identifiers; payload confidentiality requires authenticated encryption whose keys stay at endpoints |
| Update host | Update requests and the requesting network address; it must not decide which code is trusted |

The encryption requirement is separate from relay routing. Do not infer end-to-end encryption from a
provider's IP-hiding claim; validate its SDK behavior or use a reviewed transport library with authenticated
peer keys. The peer-key distribution mechanism is itself a trust boundary. A malicious host still receives
the plaintext gameplay it must simulate, and admitted peers still reach the old game's network parser.
A relay therefore does not establish that the game is safe against malicious packets or host cheating.

Use install-generated identities or a deliberately selected platform identity, not Windows account or
computer names. The existing FangsBoot name override already prevents the game's default computer-name
display; preserve it across map changes. A pseudonymous identity supports blocking, but a user who can
generate another identity can evade a ban; do not promise strong global bans without a stronger identity
system. Keep logs free of invite secrets, session tokens and long-lived credentials.

The local helper should expose a narrow authenticated API over loopback or a restricted IPC channel.
Loopback alone does not authorize a caller. It should not accept arbitrary file paths, shell commands,
Lua code or URLs from lobbies. Rate-limit admission and packets, bind tickets to lobby/peer/build/expiry,
and revoke access on kick. Keep privileged service credentials server-side, with allocation limits to
prevent callers spending an operator's relay budget. Platform SDK client credentials need the provider's
intended restricted client policy; they are not administrator secrets.

The shipping package should omit development control mods. Current CE player packaging already ships
only FangsBoot; do not accidentally copy the broader development mod list into Forever. Run without
administrator privileges. A local helper does not sandbox the injected mod or the game itself.

## Updates and coexistence with Community Edition

Updates must remain independent of whoever hosts a match. A lobby may report a required compatible
version, but cannot provide executable code, Lua, DLLs, patch paks or a new trusted signing key. Users
obtain approved content through the Forever updater and choose to update before joining.

Reuse CE's signed manifest and content hashes, with a separate Forever signing key, mandatory signature
checks, safe relative paths, HTTPS distribution and a pinned bootstrap trust root. Add explicit manifest
versioning and downgrade protection for automatic updates. Keep signing authority separate from the
directory and relay; mirror compromise should not allow code installation. A malicious legitimate signer
remains inside the trust boundary. Key rotation and a documented recovery procedure are required.

Advertise and validate the exact base-game build, network protocol and mod/patch set. Display incompatible
rooms clearly; do not auto-install a host's files to resolve the mismatch. Apply updates while the game is
closed, preserve a working version and keep settings exportable. A known installed version should remain
usable for compatible LAN/direct sessions when an update server is offline. Online services can reject
obsolete clients without making the local executable depend on a permanent activation service.

Use a separate repository, launcher identity, settings directory, instance data, release channel and
signing key. The current launcher writes to `%LOCALAPPDATA%\MOBA\Saved\Config\WindowsNoEditor`; simply
using another installation folder does not isolate the editions. Prove configuration/save isolation
before promising that CE and Forever can coexist. Never let their updaters manage the same writable tree.

Publish replacement code, tooling and manifests as appropriate; keep proprietary base-game files,
production player data and credentials out of the new repository. Reuse a locally supplied compatible
game installation where possible. Base-game acquisition and any necessary distribution hosting remain
separate decisions; removing match hosting does not solve them automatically.

## What BAPBAP establishes

BAPBAP's developer stated on 12 March 2025 that the team moved toward a party-game experience because
maintaining matchmaking servers was difficult, and directed players to lobby-based play and a server
browser. This is a close precedent for the proposed product scope. That statement does not establish
BAPBAP's relay vendor, packet encryption, host migration or update security. No BAPBAP binary or traffic
was inspected here.
[Developer statement](https://steamcommunity.com/app/2226280/discussions/0/592891465952180938/).

## Proof sequence and remaining decisions

First prove the visible host with a second local client, isolated from CE data and live play. Both must
enter a custom lobby, select teams and heroes, load an arena, move/cast/deal damage, finish a round and
return or rematch. Check the host's HUD and effects explicitly. Then validate on native Windows and with
two real remote players; load-test the intended capacity only after the basic flow works.

Next prove transport: distinct guests, connection failure recovery, map travel, latency/loss and
restrictive NAT. In relay-only mode, packet inspection must establish that neither player contacts the
other's public address, including discovery, QoS probes and reconnects. Check selected SDK encryption
and key authentication separately. Measure the host's game frame time while rendering and hosting.

Then prove lifecycle and trust boundaries: expired/replayed tickets, private-room listing exclusion,
kick/rejoin behavior, version mismatches, host exit, directory/relay outages, modified updates and safe
configuration coexistence. Directory ownership reassignment is not migration of the running game state.

Outstanding decisions are the connectivity provider and supported identity flow, public versus
invite-only rollout order, target room size, admission/moderation policy, and base-game acquisition.
The separate repository is the intended implementation destination; it was not created during this
research-only pass. No provider account was configured and no production/gameplay files were changed.

The first go/no-go result should be a complete match played by a visible host and a guest. A lobby
browser or provider SDK demo alone would not establish the feasibility of Fangs: Forever.
