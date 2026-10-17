# Game-server performance (Feb 2023 build, Shipping, Wine 11.18): what makes matches stutter

Measured 14 Oct 2026 with `tools/run/test_perf.sh` (local, headless) and read-only snapshots of the VPS. Numbers are
for the Feb 2023 build's Embersong arena.

## How to measure

`tools/run/test_perf.sh` starts a backend and game servers like the VPS (own Wine prefix per server, a standby next to
the match, no ntsync, servers pinned to 4 CPUs) and plays a custom match: `CLIENTS` GPU headless clients (`ACTIVE=1`:
they walk and fire abilities like players) plus `BOTS` AI heroes, spawned on the game server through the game's own
`GS_MOBA_Battle.SpawnBot` (each released hero has a behaviour tree). It records:
- `tools/run/perf_frames.lua` (loaded into each server by FangsCtl): fps and longest frame per second, every frame > 40 ms;
- `tools/run/perf_sample.py`: the game thread's CPU, run-queue wait, state and syscall every ~2 ms, all threads every
  50 ms, context switches, and the game traffic on the test's loopback (packet gaps per client);
- object-lookup costs, cvars, net driver settings, memory per server.

The game's own "AI" custom mode spawns no bots on our servers: it reads `EditorTestClients` from the
`BP_PC_MOBA_PlayerController` defaults, which hold one non-AI entry. `DebugSpawnBot` (a server RPC) returns early in
Shipping builds.

## Findings

**1. FangsHost's object scans caused the recurring hitches.** The heartbeat (every 3 s) and the local-player safety net
(every 2 s) each ran `FindFirstOf("GameStateBase")` + `FindAllOf("PlayerController")`. Each call walks every UObject on
the game thread. Measured in the arena on a fast desktop: 6.5 ms per call with 1 hero, 8 ms with 2, 11 ms with 8-12, and
17 ms with 3 real players + 9 bots. Slow frames came exactly every 2.03 s and ~3 s. On the VPS (VM, EPYC Rome, small
caches) the same walk is several times slower: the live perf lines (2 players: ~40 fps, 180-250 ms "hitches" in nearly
every sampled 3 s window, in the lobby too) fit 2 scans of ~50-100 ms each per loop run, and both loops coinciding
every 6 s. Fix: the game state comes through the game instance's world (`gi:GetWorld().GameState`), players are
counted from `GameState.PlayerArray`, and the safety net scans only twice per map.

**2. Game servers decoded a movie all match long.** Something on the server keeps a media player running. Locally that
cost 10-20% of a core per server (GStreamer `multiqueue`, Wine threadpool, NVDEC), on the VPS `FMediaTicker` + 3
threads ~3%. One 256 ms frame had the game thread blocked in a Wine wait while those threads ran. Fix: the instance
view has no `.mp4`s.

**3. Helper processes cost memory.** Per server on the VPS (anonymous memory): game 2.4 GB, `conhost.exe` 330 MB (from
`-log`, a console window), CEF GPU process 267 MB (`UnrealCEFSubProcess.exe`; `-nocef` does not stop it in this build),
`explorer.exe` 46 MB. The VPS container has 7 GB for everything, so the page cache gets squeezed with 2 servers. Fix:
no `-log`, no CEF helper in the instance view.

**4. Not the cause:**
- Garbage collection: `gc.TimeBetweenPurgingPendingKillObjects` = 61.1 s. Three forced full GCs
  (`KismetSystemLibrary.CollectGarbage`) in a 12-hero match produced no frame > 18 ms. No periodic GC spikes in any run.
- CPU contention: the game thread waited for a CPU 0.3-1.5% of the time.
- Per-connection cost: 3 real, active clients + 9 bots cost the same CPU as 1 client + 11 bots (local).

**5. Wine synchronisation (ntsync):** the VPS kernel (Debian 6.12 cloud) has no `/dev/ntsync`, and the WineHQ trixie
build of 11.18 is compiled without ntsync (its forky build has it). So every Wine wait or signal is a wineserver round
trip. A pipe round trip between two processes takes 26.7 µs on the VPS vs 2.1 µs locally. The game thread blocks
~35 times per frame on an idle server (VPS and local alike) and ~40-50 times per frame in a 12-hero match (~2400-3000/s;
wineserver ~5000 wakeups/s). With ntsync (local A/B): 9 per frame, wineserver ~1000/s. Frame times locally are the same
either way. On the VPS ntsync would save roughly 1-1.5 ms per frame of game-thread waiting and ~15-20% of a vCPU of
wineserver time per match. It helps capacity, not the hitches. Needs the trixie-backports kernel (7.x), `/dev/ntsync`
passed into the container (readable by its user) and a Wine built with ntsync (e.g. WineHQ's forky packages).

**6. Replication cadence:** the server sends each client a packet every ~40-50 ms (20-25 Hz; gaps alternate 33/50 ms
at 60 fps), whatever `NetServerMaxTickRate` (30/32/62), `NetClientTicksPerSecond` (200) or the heroes'
`NetUpdateFrequency` (100 by default, tried 60). No replication graph. At a 90 fps cap the gaps are more regular (median
42 ms, max 48) for +45% server CPU. `net.UseAdaptiveNetUpdateFrequency` is 0; `net.IsPushModelEnabled` reads 0 on the
server although DefaultEngine.ini's `[SystemSettings]` sets it to 1.
Not the bandwidth cap: in the 14 Oct `test_perf.sh` reports (`work/logs/perf-*-report.txt`) every client gets
22-27 packets/s whether it receives 3.1 or 12.1 kB/s; a saturated connection would sit at its byte limit instead.
Next: read the send gate in the exe (`tools/re/decomp.sh`; `docs/recon/battlerite-kit.md`).

**7. UE4SS (this build):** cancelling a `LoopInGameThreadWithDelay` loop (`CancelDelayedAction`) now and then stopped
another loop of the same mod for good. A 10 ms loop died on most servers that booted while another was running.
FangsHost no longer cancels its loops. FangsBoot (players) still uses the same pattern.

**8. Loading a map resets `t.MaxFPS`** (the arena runs at 60): FangsHost re-applies its cap after every map change. Before,
a match cap equal to the lobby cap (e.g. `FANGS_TICKRATE=30`) never applied.

Tick concurrency cvars exist in this build (`tick.AllowAsyncTickDispatch` 0, `tick.AllowAsyncTickCleanup` 0,
`tick.AllowConcurrentTickQueue` 1, `tick.AllowAsyncComponentTicks` 1, `net.MaxConnectionsToTickPerServerFrame` 0) but
were not changed: the fixes already meet the 50 ms target, and more cross-thread handoffs mean more wineserver round
trips on the VPS.

## Results (local, 9950X3D, servers pinned to 4 CPUs, no ntsync)

| Match | Before: frames > 33 / > 50 ms, longest | After | Server CPU before → after (match + standby, % of a core) |
|---|---|---|---|
| 1 player | 41 / 0 in 110 s, 46 ms | 1 / 0, 34 ms | 45 + 27 → 24 + 7 |
| 1 player + 1 bot | 36 / 0, 43 ms | 0 / 0, 25 ms | 41 + 21 → 24 + 6 |
| 1 player + 7 bots | 88 / 1, 84 ms | 1 / 1, 66 ms (a sleep overshoot) | 42 + 21 → 28 + 6 |
| 1 player + 11 bots | 109 / 2, 256 ms | 1 / 0, 34 ms | 41 + 18 → 31 + 6 |
| 3 active players + 9 bots | 103 / 10, 99 ms | 1 / 1, 67 ms (a sleep overshoot) | 51 + 28 → 30 + 6 |

The median of "longest frame in each second" went from 31-43 ms to 17 ms (one frame at 60 fps) in every case. The
remaining rare 50-70 ms frame (about once per 2 minutes) is the game thread oversleeping in a Sleep (`pselect6`), not
work.

Final check with the changed files as they are (no test overrides), 3 active players + 9 bots for 170 s: 0 frames > 33 ms, longest
18 ms, 60.0 fps; match 31% of a core, standby 5%; each client got a packet at least every 53-67 ms.

## Capacity (VPS: 4 vCPUs, 7 GB for the container)

- Two full 12-hero matches (1 active player + 11 bots each) plus two idle standbys on the same 2 local CPUs: both at
  60 fps, longest frame 22 ms (plus one 69 ms sleep overshoot), game threads waited for a CPU 1-2% of the time,
  ~70% of the 2 CPUs used. Per thread a VPS vCPU is roughly 2-3x slower (idle standby: game thread 9.3% there vs
  ~5% here), and without ntsync it pays ~27 µs per wineserver round trip. Estimate: a full match ≈ 0.7-1 vCPU, a
  game-thread frame ≈ 10-15 ms of the 16.7 ms budget. One full match + standby fits easily; two matches fit by CPU.
- Memory decides the count: a game server holds ~2.5 GB (VPS: 2.4 GB idle) plus ~0.1 GB of Wine helpers after the
  fixes (before: +0.6 GB for conhost and CEF). 7 GB fit two servers (one match + standby, or two matches and no
  standby), not three.
- A 60 Hz net tick isn't available from config (finding 6). The server already runs 60 fps; a 90 fps cap makes the
  ~25 Hz replication more regular for +45% CPU, worth trying only with one match per VPS.

## Results on the VPS (first full evening, 15 Oct 2026 00:00-02:40 UTC, `deploy-2026-10-15-0003`)

From the backend's `perf` lines (one per 30 s per server with players): seven matches, 4 to 8 players (2v2, 3v3, one
4v4 on Crownwatch), at most two servers busy at once (a match plus the next lobby).
- The first 30 s window of every match holds the map load: one frame of 2.6-4.9 s, `fps_min` 0-24. Not a stutter
  players see in the match (they are on the loading screen).
- After that: 58-60 fps throughout, typical longest gap (`hitch_ms`) 12-15 ms, 0 slow frames in most windows.
  About one single frame of 75-240 ms every 1-3 minutes (one per window, the rest of the window clean), in 6- and
  8-player matches alike. The 8-player match was no worse than the 6-player ones.
- Lobbies run at their 15/30 fps cap (`slow` ~45 per window there is the 66 ms frames of the 15 fps lobby cap, not
  hitches).
- Idle (one standby, nobody on): the container uses ~20% of one vCPU.
- Open: the remaining 75-240 ms single frames (locally the worst was a 67 ms sleep overshoot); they could be GC or the
  wineserver without ntsync.

## Rubber-banding: the netcode settings measured (17 Oct 2026)

The community's complaints (`docs/recon/community-patchnotes.md`): players teleport in big team fights, worst on
Crownwatch; tigga rubber-bands as Tufts at about 30 ms ping, wired. This measures what players see, with the live patch
pak (`deploy-2026-10-17-1223`, all 8 patches) on clients and servers.

**How** (`tools/run/test_perf.sh`, new options; branch `cp2-netcode`):
- `SNAPS=1` loads `tools/run/net_snaps.lua` on every test client. Every frame it compares each hero's position with
  where its velocity said it would be. On the own hero (a predicted actor), a jump is a correction from the server:
  rubber-banding as the player feels it. On other heroes' meshes (after the game's smoothing), a jump is another
  player teleporting on this screen. `tools/run/net_snaps_report.py` sums it up per minute.
- `FIGHT=1` puts all 12 heroes in a ring in the middle of the map, and the active clients keep walking back to it: a
  6v6 team fight (3 GPU clients walking and casting, `ACTIVE=1`, plus 9 of the game's bots). `MAP=` picks the arena.
- `NETEM="delay 25ms 5ms loss 0.5%"` (`tools/run/headless.sh`): latency on the test namespace's loopback only, about
  50 ms round trip with jitter and loss (never on the host).
- `DASH=1` (`tools/run/net_dash.lua`): the client charges and releases Space every 2.5 s (Tufts' Wing Dive).
- The settings under test:
  - server `FANGS_NET_TICK`, `FANGS_POS_ERROR`, `FANGS_NET_RATE` (`server/run-host.sh`);
  - clients `CLIENT_NET_RATE` and `CLIENT_ENGINE_INI` (`tools/run/headless.sh`).

  The server's own read-back confirms what it got (`netdriver: tick=… clamp=… rate=…`).
- 120 s per run on Embersong unless noted; servers pinned to 4 CPUs without ntsync, as on the VPS.

**Results** (per minute, all clients together; "others" = other heroes' visible jumps over 80 units):

| Run | Setting | Own snaps >20 | >50 | >100 | Others >80 | Packets/s per client, median gap | Server CPU (match) |
|---|---|---|---|---|---|---|---|
| nc-a, nc-a2 | live (tick 30, clamp, 40000) | 29.4 / 23.4 | 3.6 / 4.5 | 2.4 / 2.9 | 32.0 / 29.2 | 26, 40 ms | 31 / 26 % |
| nc-b, nc-b2 | `FANGS_NET_TICK=60` (60/60, no clamp) | **12.8 / 12.3** | 4.8 / 3.6 | 3.4 / 2.6 | **15.6 / 15.5** | 57, 17 ms | 33 / 32 % |
| nc-c | tick 60 + rate caps 100000 both ends | 15.0 | 3.4 | 2.7 | 12.2 | 58, 17 ms | 30 % |
| nc-d3, nc-d3b | `FANGS_POS_ERROR=3.0` | 17.2 / 16.1 | 3.0 / 3.7 | 2.8 / 3.2 | 33.2 / 34.3 | 26, 40 ms | 30 / 33 % |
| nc-bd | tick 60 + `FANGS_POS_ERROR=3.0` | 13.2 | 3.6 | 2.6 | 20.8 | 58, 17 ms | 34 % |
| nc-d85 | `FANGS_POS_ERROR=8.5` (Aug's) | 28.9 | **13.5** | **10.9** | 33.1 | 26, 43 ms | 30 % |
| nc-cw0 / nc-cw1 | Crownwatch, live / + `r.AllowOcclusionQueries=1` on the clients | 15.0 / 19.3 | 3.3 / 3.0 | 2.3 / 2.1 | 32.5 / 29.1 | 26, 40 ms | 25 / 28 % |
| nc-e0 / nc-e1 | Tufts dashing (1 client, 3 bots), live / + patch `tufts-sync` | 62.5 / **29.0** | 17.5 / **6.7** | 0.6 / 0.6 | – | 23, 46 ms | 24 / 28 % |

What it shows:
- **Net tick 60 without the clamp halves the small corrections and other players' jumps.** Two runs each, the same
  both times. The server sends each client a packet every 17 ms instead of every 40 ms. The bandwidth doesn't grow (13
  kB/s per client either way, far under the 40000 cap). The 20-25 Hz replication of finding 6 above was the
  listen-server clamp to `MaxNetTickRate` 30.
- **The large corrections (over 50 and 100 units, about 3-4 a minute) don't change with any setting.** In a fight they
  come from the server's own displacements: knockbacks, CC, dashes the client predicted differently. Fixing those means
  per-ability work, e.g. the Tufts sync change below.
- **`MAXPOSITIONERRORSQUARED` 3.0** cuts small snaps by about a third alone, but adds nothing on top of tick 60. **8.5**
  made large snaps 3-4 times more frequent in its single run. Neither is switched on.
- **Higher rate caps** change nothing: no client gets near 40000 bytes/s in a 6v6. They stay as they are (100000 once
  dropped players in hero select).
- **Tufts' Wing Dive with the sync change** (`tools/patch/patches/tufts-sync.json`: the dash's two
  `WaitNetSync(OnlyClientWait)` become `OnlyServerWait`, so the player's screen dashes at once and the server follows)
  more than halves his snaps while dashing at 50 ms latency.
- **Crownwatch:** server and corrections look like Embersong's. The client frame rate can't be judged here: the
  headless clients run capped at 60 fps (gamescope) and stayed there either way, so the occlusion setting's effect on
  players' PCs is still unmeasured.
- **Lobbies with tick 60:** `tools/run/test_lobby.sh` 6 times with `FANGS_NET_TICK=60`, 6 normal exits. In the 4
  runs whose logs were kept (`work/logs/nc-lobby-*.result`, local), both players got through hero select into the
  arena every time: no hero-select drop like the one a 100000 rate cap caused.

**Capacity:** tick 60 costs the match server about 3-5 % of a core more on this machine (26-31 % → 32-34 %). With the
VPS estimate above (a full match 0.7-1 vCPU), that's about +0.1 vCPU per match. Two matches plus a standby still fit
the 4 vCPUs; memory is unchanged.

**Switched on:** `FANGS_NET_TICK=60` in `server/netcode.env`. It's committed and the deploy uploads it, and
docker-compose hands it to every game server. Off switch: empty the value and deploy. Server only, no player update.

**Prepared, off:** `FANGS_POS_ERROR`, `FANGS_NET_RATE` (`server/netcode.env`). The occlusion setting would go into
the players' `FangsCE/Engine.ini` (from `tools/run/config/Engine.ini.template`).

**Switched on for the next deploy: Tufts' sync change** (`tufts-sync.json`; user, 17 Oct: "on"). Before it went on,
`tools/run/test_tufts.sh` checked the dash itself: every patch of the deploy, about 50 ms latency (`NETEM`), bob as
Tufts; four dashes from the middle of Embersong, each measured every frame on his own client and on the game server
(`dash.log`): charged and tapped into open ground, charged into alice 500 ahead, charged again.

| Run | Dash starts on his screen | Distance, open ground | Fast bursts | Dash into alice |
|---|---|---|---|---|
| tf-off3, without | 0.29-0.30 s after the press | 536-585 | 1 per dash | 28.8 damage and a stun |
| tf-on, with | 0.30 s | 526-575 | 1 per dash | 28.8 damage and a stun |

- The dash is unchanged: no lost or double dash, the same distance, top speed (2000) and hit. Client and server agree
  on where each open dash ends.
- It doesn't start sooner on the player's screen. Wing Dive has a fixed 0.3 s wind-up (an 80 ms tap and a 500 ms hold
  dash alike), and the start doesn't move with the latency, so the sync points probably sit inside the wind-up. What
  changes is which side waits there: the server waits for the client's signal, so its copy of the dash lines up with
  the client's moves. The 120 s dashing runs above (nc-e0/nc-e1) saw that as fewer snaps; four dashes per run are too
  few to show it (largest frame jump 28-141 units either way).
- Lobby flake on the way: in one of these runs (tf-off2), as in `dp-patch` and `base-all2`, the test's lock-in found no
  hero select 16 s after the launch and the match never started. `test_patch.sh` now tries the lock-in three times
  over 20 s, says how many lobby controllers and hero select screens the client has, and probes the server's lobby
  state (`LOBBY_PROBE`), so the next stuck run shows where it stops. The real LAUNCH button's path
  (`test_lobbyui.sh`) hasn't stuck.
