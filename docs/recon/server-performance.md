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
