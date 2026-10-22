# Fangs hosting options

Investigated 22 October 2026 for the February 2023 build. Decision pending; research only.

To reclaim the current Hetzner machine, the least disruptive option is another small x86 VPS.
For almost no hosting bill, run the existing stack on a community member's computer during play sessions.
An on-demand cloud machine is feasible in principle, but storage and networking charges can make it cost
as much as a cheap VPS. Player-hosted matches are a useful longer-term project; a fully distributed game
simulation would be a much larger undertaking.

## What needs hosting

The [architecture](../ARCHITECTURE.md) has three workloads:

| Workload | Requirements |
|---|---|
| Python backend | HTTP and persistent WebSockets; accounts, profiles, friends, matchmaking, results and ratings. Persistent `store.json`; tokens, parties and queues live in memory. |
| Match processes | Windows x86-64 game executable under Wine and UE4SS, one process per lobby/match. Public UDP 7777 onward; approximately 2.5 GB RAM plus Wine helpers per process. |
| Downloads and updates | Approximately 13 GB game install plus approximately 7 GB compressed download chunks, mods and signed manifests. Storage and download traffic remain relevant when matches are idle. |

UDP 11032 provides region ping. The Docker image includes Wine and Xvfb, uses host networking and mounts
game files separately. It needs no GPU for the headless server. The current deployment is documented as
4 vCPU / 8 GB, with a 7 GB container limit and two game slots.

A read-only live check on 22 October found one empty lobby standby, **2.513 GiB** container memory and
**20.77% of one CPU core**. `store.json` was 5,688,285 bytes; its contents were not read. This is an idle
snapshot, not a measurement of monthly utilization or loaded matches. Docker's zero network counters in
host-network mode were not treated as a bandwidth measurement.

[Earlier performance measurements](server-performance.md) put a full match around one small VPS vCPU,
with memory limiting the machine to two processes. An 8 GB replacement preserves the current capacity.
A 4 GB machine is only a candidate for one process, with standby disabled and peak memory checked.

The backend already accepts `--host-standby 0`. However, [the roadmap](../ROADMAP.md) records a 20–25 s
server boot against an approximately 18 s client lobby timeout. Removing the standby without addressing
readiness can make the first lobby request fail. Disabling standby releases resources; it does not lower
a fixed VPS bill.

## Provider comparison

Prices and limits below were checked against provider pages on 22 October 2026. Advertised starting
prices are not checkout quotes; location, term, stock, tax and renewal terms need checking before purchase.

| Option | Published terms | Fit for Fangs |
|---|---|---|
| Railway Free | $1 monthly credit, 0.5 GB RAM, 0.5 GB volume, 4 GB image limit | Cannot fit a match process. A separated backend might fit, subject to actual usage, persistence and networking changes. |
| Railway Hobby | $5 monthly minimum including $5 usage; RAM $10/GB-month | Standard hosting has no inbound UDP. A relay would add another dependency, and keeping the current 2.5 GB standby alone would use roughly $25/month of RAM charges. |
| Render Free | Web services sleep after 15 minutes without traffic; no persistent disk | Unsuitable for the current local JSON persistence, even for a separated backend. External persistence would need implementation. |
| Oracle Always Free | AMD micro instances have 1 GB RAM each; larger free A1 allocation is ARM | AMD is too small for a match. ARM does not run this x86 Wine stack as deployed; translation would be an unproven experiment. Idle free instances may be reclaimed. |
| OVHcloud VPS | Ireland page advertises VPS-2, 4 vCores / 8 GB / 75 GB, from €7.21/month excluding VAT | Promising direct replacement. Benchmark game frame times on the selected machine and confirm regional/contract pricing. |
| Another small Hetzner VPS | Published EU CX33 price €8.49/month excluding VAT and IPv4 | Useful price reference if reclaiming this particular box, rather than leaving Hetzner entirely. Check current stock/specification at order time. |
| Netcup x86 VPS | VPS 1000 G12.5: 4 vCores / 8 GB / 128 GB | Another direct replacement candidate. The listing displays several term/price variants; obtain a final quote rather than relying on an older G12 price. |
| Fly.io Machines | UDP supported; compute stops billing when stopped; persistent storage and dedicated IPv4 remain billed | Strongest candidate here for on-demand hosting, but requires a Fangs-specific startup/shutdown flow and UDP compatibility proof. |

Sources: [Railway plans](https://docs.railway.com/pricing/plans),
[Railway public networking](https://docs.railway.com/networking/public-networking),
[Railway employee on inbound UDP](https://station.railway.com/questions/can-i-setup-turn-server-on-railway-db46bf40),
[Render Free](https://render.com/docs/free),
[Oracle Always Free](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm),
[OVHcloud VPS](https://www.ovhcloud.com/en-ie/vps/),
[Hetzner price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/),
[Netcup VPS](https://www.netcup.com/en/server/vps),
[Fly pricing](https://docs.fly.io/about/pricing).

Railway's sleep feature watches outbound traffic, not game-player count. WebSocket traffic and other
network activity can prevent sleep. A sleeping backend also loses its in-memory sessions on restart.
[Railway serverless documentation](https://docs.railway.com/deployments/serverless).

## On-demand cloud hosting

The simplest design to investigate keeps the backend and match processes together on one sleeping
machine. A launcher request wakes it and waits until the backend and a game host are ready before
starting the player's game. A deliberate shutdown policy waits for no connected users, active games,
queues or pending results. Downloads and casual menu visits can extend runtime beyond actual match hours.

This preserves the existing local process/files/authentication arrangement and is less invasive than
splitting the backend from match workers. It still needs launcher retries and readiness handling;
it is not achieved by merely switching on generic web-service sleep.

Fly supports public UDP with a dedicated IPv4 and requires UDP sockets to bind and reply through
`fly-global-services`, using matching internal/external ports. The current Wine/Unreal bind behavior
must be tested. Configure each game port explicitly and prove two simultaneous matches reach the
correct process. Use an HTTP/API wake path and application-aware stopping; do not assume UDP traffic
alone provides safe automatic lifecycle management.
[Fly UDP documentation](https://docs.fly.io/networking/udp-and-tcp/),
[Fly autostop/autostart](https://docs.fly.io/launch/autostop-autostart).

Illustrative Fly budget, using its published lowest-priced US region rates and a 30-day month:

| Assumed resource | One game slot | Two game slots |
|---|---:|---:|
| Performance CPU machine, 72 hours/month | 1 CPU / 4 GB: $4.50 | 2 CPU / 8 GB: $9.00 |
| 30 GB persistent volume | $4.50 | $4.50 |
| Dedicated IPv4 | $2.00 | $2.00 |
| Subtotal | $11.00 | $15.50 |

These are calculations, not tested Fangs configurations or complete bills. Add stopped root filesystem
storage, egress, any snapshots, taxes and any separate always-on backend; European compute prices differ.
The 72-hour assumption interprets 90% idle as a machine actually stopped for 90% of the month. Shared CPU
may be cheaper but needs game-performance testing. Fly has no ongoing free tier for new organizations.
[Fly pricing](https://docs.fly.io/about/pricing).

Thus, on-demand is attractive for occasional scheduled sessions, but need not beat a €7–10 VPS at
roughly 72 active hours/month. A separate always-on backend improves presence and queue continuity,
at the cost of implementing remote workers and paying for the backend too.

Another approach is recreating a VPS from a snapshot for scheduled evenings. Hetzner charges while a
server exists even when powered off, so savings require deletion and recreation, with state backed up
and the address managed. That adds operational work compared with a genuinely stopped-billing VM.
[Hetzner billing FAQ](https://docs.hetzner.com/cloud/billing/faq/).

## Hosting on a community member's computer

This is the nearest route to zero cloud compute cost. An existing Linux computer can run the same
backend plus headless match processes during play sessions. Players connect to its address. Electricity,
upload capacity and the host's availability replace the VPS bill; the host should have spare memory
in addition to its own game client. Hosting and playing on Windows would need packaging and validation
of the backend and a separate native headless process; the present server wrapper is Linux/Wine.

Connectivity choices:

- Port forwarding with a reachable public address: no relay required. Check whether the host is behind
  carrier-grade NAT and whether players can reach all required TCP and UDP ports.
- Tailscale: useful for a small private proof of concept, but every player needs the client. Its current
  Personal plan allows six users, so one free tailnet does not cover eight separately enrolled players
  in a 4v4 match. Direct paths are preferable; relayed paths add latency. Other sharing arrangements
  would need separate qualification.
- Playit: only the host runs an agent. Generic UDP is listed as free, while generic TCP and TCP+UDP
  require Premium (advertised $3/month). The complete current Fangs stack needs both HTTP and UDP, so
  do not call it entirely free. Separate tunnel addresses/ports would need configurable advertised
  endpoints; the current backend assumes one public host and the local game ports.

Sources: [Tailscale pricing](https://tailscale.com/pricing),
[Tailscale connection types](https://tailscale.com/docs/reference/connection-types),
[Playit](https://playit.gg/pricing).

One designated host can preserve everyone's profiles. Rotating the entire backend between players
would need a state handoff or separate community profiles. A small central backend with player-operated
match hosts avoids that data handoff, but requires the remote-worker work below.

## What peer-to-peer would mean here

The useful first version is **one authoritative player-operated host per match**. Other players send
their actions to it, and it runs the existing game simulation. This changes who supplies the server
computer without replacing Unreal's replication model.

There are two variants. A separate headless game process on the host's PC reuses more of the current
design, at the cost of approximately another 3 GB RAM. A listen server in the player's own visible game
could avoid that extra process, but would require more game-mod work. FangsHost already opens the map
with `listen`, but explicitly removes the local player and assumes dedicated-host behavior. Retaining
the player is a feasibility experiment, not an established working mode.

The current code is coupled to co-location in several concrete ways:

- `backend/hosts.py` launches local subprocesses and reads local heartbeat/result files.
- FangsHost reads exported player/game records from a local directory.
- `backend/fangs_backend.py` grants server authority only to loopback requests and advertises one
  global public IP with each process's local port.
- The launcher embeds or remembers the community backend address and obtains updates there.

A remote-host design therefore needs authenticated host registration, per-host addresses, record
delivery, heartbeat/result upload, ownership cleanup, and a connectivity solution. Keep the loopback
restriction until an explicit remote authentication boundary replaces it. Authenticating a player host
does not make its submitted match results honest: casual/private matches are the natural starting point;
Ranked needs a decision about trusted hosts and rating eligibility.

If a player host quits or loses connectivity, assume the match ends. Seamless host migration requires
capturing and restoring authoritative game state and has not been demonstrated. A fully distributed,
equal-peer simulation would require much deeper changes to a compiled game whose complete Unreal source
is unavailable in this project. It is not justified merely to save a small hosting bill.

## Suggested next decision

Choose a small 8 GB x86 VPS if the priority is reclaiming the current machine quickly while preserving
the player experience. OVHcloud is the strongest advertised-price alternative found here; compare its
regional checkout offer with available Hetzner and Netcup options, then validate one full match.

Choose a community-host experiment if avoiding recurring compute cost matters more than always-on
availability. Start with the whole stack on one designated Linux PC and two remote players. Prove
connectivity, hero select, a complete match, results and host shutdown before building a launcher Host button.

Choose a Fly experiment if sleeping automatically is the desired product behavior. Prove Wine startup,
UDP replies, cold-start UX and safe shutdown before estimating savings from actual billed runtime.

No provider account, VM or tunnel was created, and no live configuration was changed. Provider runtime
compatibility, player-hosted Windows support, listen-server play and host migration remain unqualified.
