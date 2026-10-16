"""Pool of headless FANGS game hosts (dedicated lobby servers) launched via server/run-host.sh.

Each host serves one custom lobby or one matchmade game: it starts on the lobby map, players pick
heroes, and the server travels to the arena. When the match is over (everyone gone) the host is
stopped and its port freed. Hosts report map/player-count through FangsHost's status file.
"""
import asyncio, json, os, re, signal, time
from pathlib import Path

READY_LINE = 'IpNetDriver listening on port {port}'
LOBBY_MAP = '/Game/Environment/Maps/LE_Lobby_Map'


class NoFreeSlot(RuntimeError):
    """Every game server slot is taken (and none could be reclaimed): try again when one frees up."""


class Host:
    def __init__(self, hid, port, inst):
        self.id, self.port, self.inst = hid, port, Path(inst)
        self.proc = None
        self.session_id = None
        self.started = time.time()
        self.ready = asyncio.Event()
        self.had_players = False
        self.empty_since = None
        self.perf_logged = 0.0
        self.perf = None         # FangsHost heartbeats since the last perf line (see HostManager._perf)
        self.match_over = None   # when its match's result arrived: no longer listed or joinable, stopped soon after
        self.reserved = False    # booted by allocate() for its own request: never handed to another one as idle
        self.peak_players = 0    # most players connected at once (a Ranked result: did every matched player join?)
        self.solo = False        # a 1-player session (Training, a Solo lobby): nobody else to wait for once its player left
        self.players_map = None  # the map its players were last seen on (a player still loading a new map isn't gone)

    @property
    def log_path(self):
        return self.inst / 'MOBA' / 'Saved' / 'Logs' / 'MOBA.log'

    @property
    def status(self):
        try:
            return json.loads((self.inst / 'MOBA' / 'Binaries' / 'Win64' / 'fangshost_status.json').read_text())
        except (OSError, ValueError):
            return {}


class HostManager:
    """Starts game servers on demand, keeps `standby` booted idle servers so lobbies/matches start at once,
    and restarts a server that dies while booting (a few % of starts under Wine die early).

    Servers are stopped when nobody needs them: a lobby everyone left (before its match started) after
    `lobby_grace`, a match everyone left after `idle_grace` (time to reconnect), a solo session (Training, a Solo
    lobby) its player left after `solo_grace`, a server nobody joined after `unused_timeout`. When every slot is taken,
    the longest-empty server is stopped for a new one."""

    def __init__(self, *, game_dir, inst_root, ports, run_script, backend_addr, log, data_dir,
                 ready_timeout=180, idle_grace=180, lobby_grace=20, solo_grace=10, unused_timeout=180, post_match=120,
                 standby=1, attempts=3):
        self.game_dir, self.inst_root, self.ports = game_dir, Path(inst_root), list(ports)
        self.run_script, self.backend_addr, self.log, self.data_dir = run_script, backend_addr, log, data_dir
        self.ready_timeout, self.idle_grace, self.unused_timeout = ready_timeout, idle_grace, unused_timeout
        self.lobby_grace, self.solo_grace, self.post_match = lobby_grace, solo_grace, post_match
        self.standby, self.attempts = standby, attempts
        self.standby_retry = 60  # seconds before a standby whose boots all failed is tried again
        self.hosts = {}          # id -> Host
        self.on_stopped = []     # callbacks(host)
        self.on_result = []      # callbacks(host, result): a finished match (FangsHost's fangshost_result-*.json)
        self.on_loadout = []     # callbacks(host, user_id, loadouts): a preset saved in a match (fangshost_loadout-*.json)
        self._booting = 0        # standby servers being started
        self._allocating = 0     # allocate() calls still waiting for their server
        self._releasing = set()  # ports of stopped servers whose process hasn't exited yet
        self._closing = False
        self._tasks = set()      # background tasks (asyncio keeps only weak references to them)

    def _background(self, coro):
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    def free_ports(self):
        used = {h.port for h in self.hosts.values()} | self._releasing
        return [p for p in self.ports if p not in used]

    def is_live(self, host):
        # Host ids are per port and get reused, so compare objects, not ids.
        return self.hosts.get(host.id) is host

    def _idle(self):
        return [h for h in self.hosts.values() if h.session_id is None and h.ready.is_set() and not h.reserved]

    def capacity(self):
        """How many more games could get a server now: free ports, servers nobody has claimed (an idle or booting
        standby), and empty servers allocate() would reclaim, less the allocate() calls already waiting for one.
        The matchmaker forms a match only while this is above the matches it has not started yet."""
        now = time.time()
        unclaimed = sum(1 for h in self.hosts.values() if h.session_id is None)
        reclaimable = sum(1 for h in self.hosts.values() if (t := self.empty_for(h, now)) is not None and t > 0)
        return max(0, len(self.free_ports()) + unclaimed + reclaimable - self._allocating)

    async def allocate(self, session_id, match=None):
        """A ready game server for `session_id` (a standby one if available, else a new one). `match`:
        {'size', 'map', 'map_name'} for matchmade games, handed to FangsHost via fangshost_match.json.
        Raises NoFreeSlot when every slot is taken, RuntimeError when the server failed to start."""
        self._allocating += 1
        try:
            host = await self._claim_idle(session_id)
            if host is None:
                if not self.free_ports():
                    await self._reclaim()
                try:
                    host = await self._start()
                except NoFreeSlot:   # the port we waited for went to the standby stop() tops up: wait for that one
                    if (host := await self._claim_idle(session_id)) is None:
                        raise
        finally:
            self._allocating -= 1
        host.session_id, host.started, host.reserved, host.peak_players = session_id, time.time(), False, 0
        host.solo, host.players_map = False, None
        if match:
            (host.inst / 'MOBA' / 'Binaries' / 'Win64' / 'fangshost_match.json').write_text(json.dumps(match))
        self.replenish()
        return host

    async def _claim_idle(self, session_id):
        """An idle booted server, waiting for a standby that is still booting rather than starting
        another one next to it."""
        deadline = time.time() + self.ready_timeout
        while True:
            idle = self._idle()
            if idle:
                host = idle[0]
                host.session_id = session_id          # claim it before anything else can
                self.log({'host': host.id, 'event': 'assigned (standby)', 'session': session_id})
                return host
            if not self._booting or time.time() > deadline:
                return None
            await asyncio.sleep(0.5)

    def grace(self, host, st):
        """How long an emptied server waits for its players: a solo session whose player was seen on this map and
        left `solo_grace`, a lobby `lobby_grace`, a match `idle_grace` (players are empty for a while when they load
        the arena or reconnect)."""
        if host.solo and host.players_map == st.get('map'):
            return self.solo_grace
        in_lobby = st.get('map', '').endswith('LE_Lobby_Map') and not st.get('launched')
        return self.lobby_grace if in_lobby else self.idle_grace

    def empty_for(self, host, now=None):
        """Seconds an assigned server has been empty past its grace (None if it has players or isn't assigned): the
        same graces as _watch. A new server gets 90 s for its players to arrive."""
        now = now or time.time()
        st = host.status
        if host.session_id is None or not host.ready.is_set() or st.get('players', 0):
            return None
        if not host.had_players:
            return now - host.started - 90
        return now - (host.empty_since or now) - self.grace(host, st)

    async def _reclaim(self):
        """Every slot is taken: stop the server that has been empty the longest past its grace, if any."""
        now = time.time()
        empty = [(t, h) for h in self.hosts.values() if (t := self.empty_for(h, now)) is not None and t > 0]
        if empty:
            _, host = max(empty, key=lambda e: e[0])
            await self.stop(host, f'slot needed, empty for {now - (host.empty_since or now):.0f} s' if host.had_players
                            else 'slot needed, nobody came')

    def replenish(self):
        """Top up the idle standby servers (in the background)."""
        if self._closing:
            return
        missing = self.standby - len(self._idle()) - self._booting
        for _ in range(max(0, min(missing, len(self.free_ports())))):
            self._booting += 1
            self._background(self._boot_standby())

    async def _boot_standby(self):
        try:
            if self.free_ports():                      # a lobby may have taken the slot meanwhile
                await self._start(standby=True)
        except Exception as e:  # noqa: BLE001 - logged, and tried again after standby_retry
            self.log({'host': 'standby', 'event': 'start failed', 'error': str(e)})
            if not self._closing:
                self._background(self._retry_standby())
            return
        finally:
            self._booting -= 1
        self.replenish()   # it may have been claimed the moment it was ready, while replenish still counted it booting

    async def _retry_standby(self):
        await asyncio.sleep(self.standby_retry)
        self.replenish()

    async def _start(self, standby=False):
        for attempt in range(1, self.attempts + 1):
            if self._closing:
                raise RuntimeError('backend shutting down')
            ports = await self._free_port_soon()
            if not ports:
                raise NoFreeSlot('no free game server slots')
            port = ports[0]
            host = await self._spawn(port, reserved=not standby)
            try:
                await asyncio.wait_for(self._ready_or_exit(host), self.ready_timeout)
            except asyncio.TimeoutError:
                await self.stop(host, 'ready timeout')
            except asyncio.CancelledError:   # the request gave up: its server becomes a standby, not a slot nobody claims
                host.reserved = False
                raise
            else:
                if host.ready.is_set():
                    if standby:
                        self.log({'host': host.id, 'event': 'standby ready', 'port': port})
                    return host
                await self.stop(host, f'died while starting (attempt {attempt})')
        raise RuntimeError('game server failed to start')

    async def _free_port_soon(self, wait=30):
        """Free ports; when there are none but a stopped server is still shutting down, wait for its port."""
        deadline = time.time() + wait
        while not self.free_ports() and self._releasing and time.time() < deadline:
            await asyncio.sleep(0.5)
        return self.free_ports()

    def collect_results(self, host):
        """Hands every match result FangsHost saved in this server's directory to on_result once, then deletes it
        (one that can't be read is kept as .bad)."""
        for f in sorted((host.inst / 'MOBA' / 'Binaries' / 'Win64').glob('fangshost_result-*.json')):
            try:
                result = json.loads(f.read_text())
            except (OSError, ValueError) as e:
                self.log({'host': host.id, 'event': 'unreadable match result', 'file': f.name, 'error': str(e)})
                f.rename(f.with_suffix('.bad'))
                continue
            f.unlink(missing_ok=True)
            host.match_over = host.match_over or time.time()
            for cb in self.on_result:
                try:
                    cb(host, result)
                except Exception as e:   # one bad result must not stop the server's watcher
                    self.log({'host': host.id, 'event': 'match result failed', 'error': repr(e)})

    LOADOUT_FILE = re.compile(r'^fangshost_loadout-([0-9a-f]{32})-\d+\.json$')

    def collect_loadouts(self, host, limit=65536):
        """Hands every preset save FangsHost wrote (the in-match preset panel: one JSON object per file, the player's id
        in the name) to on_loadout once, then deletes it. Too big, not an object or a strange name: kept as .bad."""
        for f in sorted((host.inst / 'MOBA' / 'Binaries' / 'Win64').glob('fangshost_loadout-*.json')):
            m = self.LOADOUT_FILE.match(f.name)
            try:
                if not m or f.stat().st_size > limit:
                    raise ValueError('name or size')
                value = json.loads(f.read_text())
                if not isinstance(value, dict):
                    raise ValueError('not an object')
            except (OSError, ValueError) as e:
                self.log({'host': host.id, 'event': 'unreadable preset save', 'file': f.name, 'error': str(e)})
                f.rename(f.with_suffix('.bad'))
                continue
            f.unlink(missing_ok=True)
            for cb in self.on_loadout:
                try:
                    cb(host, m.group(1), value)
                except Exception as e:   # one bad save must not stop the server's watcher
                    self.log({'host': host.id, 'event': 'preset save failed', 'error': repr(e)})

    async def _ready_or_exit(self, host):
        waiter = asyncio.create_task(host.ready.wait())
        exited = asyncio.create_task(host.proc.wait())
        try:
            await asyncio.wait({waiter, exited}, return_when=asyncio.FIRST_COMPLETED)
        finally:   # also when the ready timeout cancels us
            for t in (waiter, exited):
                t.cancel()

    async def _spawn(self, port, reserved=False):
        hid = f'host-{port}'
        host = Host(hid, port, self.inst_root / hid)
        host.reserved = reserved
        self.hosts[hid] = host
        for stale in ('fangshost_match.json', 'fangshost_status.json'):   # left by the previous server here
            (host.inst / 'MOBA' / 'Binaries' / 'Win64' / stale).unlink(missing_ok=True)
        self.collect_results(host)   # a match a previous server here finished just before it died
        host.match_over = None       # (that match was the old server's, not this one's)
        env = dict(os.environ, FANGS_BACKEND=self.backend_addr)
        try:
            self.inst_root.mkdir(parents=True, exist_ok=True)
            with open(self.inst_root / f'{hid}.stdout', 'w') as logf:   # the server keeps its own copy of the fd
                host.proc = await asyncio.create_subprocess_exec(
                    self.run_script, self.game_dir, str(host.inst), str(port), f'-FangsData={self.data_dir}',
                    stdout=logf, stderr=asyncio.subprocess.STDOUT, env=env, start_new_session=True)
        except BaseException:   # not launched: the slot is free again
            del self.hosts[hid]
            raise
        self.log({'host': hid, 'event': 'starting', 'port': port})
        self._background(self._watch(host))
        return host

    async def _watch(self, host):
        """Decides when a running server ends. If something goes wrong in here, the server isn't left unwatched for
        good, nor is a live match ended for it: it is stopped (like any other ending) once its process exits."""
        try:
            await self._watch_until_stopped(host)
        except Exception as e:  # noqa: BLE001 - logged; stop() still follows
            self.log({'host': host.id, 'event': 'watcher failed', 'error': repr(e)})
            await host.proc.wait()
            await self.stop(host, 'watcher failed')

    async def _watch_until_stopped(self, host):
        needle = READY_LINE.format(port=host.port)
        while host.proc.returncode is None:
            await asyncio.sleep(2)
            if not self.is_live(host):
                return                                   # stopped elsewhere
            if not host.ready.is_set():
                # Ready = listening on the lobby map (Development builds log the listen line; Shipping builds
                # barely log, FangsHost's heartbeat reports the map) and FangsHost reports the lobby config loaded.
                try:
                    logged = needle in host.log_path.read_text(errors='replace')
                except OSError:
                    logged = False
                st = host.status
                if (logged or st.get('map', '').endswith('LE_Lobby_Map')) and st.get('ready'):
                    host.ready.set()
                    self.log({'host': host.id, 'event': 'ready', 'port': host.port})
                continue
            self.collect_results(host)
            self.collect_loadouts(host)
            st = host.status
            players = st.get('players', 0)
            host.peak_players = max(host.peak_players, players)
            if players:
                self._perf(host, st)
                host.had_players, host.empty_since, host.players_map = True, None, st.get('map')
            elif host.empty_since is None:
                host.empty_since = time.time()
            idle = time.time() - (host.empty_since or time.time())
            in_lobby = st.get('map', '').endswith('LE_Lobby_Map') and not st.get('launched')
            if host.had_players and idle > self.grace(host, st):
                reason = ('solo player left' if host.solo and host.players_map == st.get('map')
                          else 'everyone left the lobby' if in_lobby else 'match over / empty')
                await self.stop(host, reason); return
            # a finished match: the end screen gets `post_match` seconds, then its server goes (players still on it
            # return to the menu), sooner once everyone left; it is no longer listed or joinable (fangs_backend)
            if host.match_over and (time.time() - host.match_over > self.post_match or (host.had_players and idle > 10)):
                await self.stop(host, 'match finished'); return
            if host.session_id is not None and not host.had_players and time.time() - host.started > self.unused_timeout:
                await self.stop(host, 'nobody joined'); return
        await self.stop(host, f'process exited ({host.proc.returncode})')

    def _perf(self, host, st):
        """How busy servers are doing: one line per 30 s while players are on, over all of FangsHost's 3 s heartbeats
        in it: fps (lowest window), hitch_ms / frame_ms (longest gap / frame), slow (frames over 50 ms)."""
        p = host.perf
        if p is None or p['map'] != st.get('map'):
            p = host.perf = {'map': st.get('map'), 'time': p and p['time'], 'n': 0, 'fps': None, 'hitch_ms': 0, 'frame_ms': 0, 'slow': 0}
        if st.get('time') != p['time']:          # a new heartbeat (the file is read every 2 s, written every 3 s)
            p['time'], p['n'] = st.get('time'), p['n'] + 1
            p['fps'] = min(p['fps'], st.get('fps') or 0) if p['fps'] is not None else st.get('fps')
            for k in ('hitch_ms', 'frame_ms'):
                p[k] = max(p[k], st.get(k) or 0)
            p['slow'] += st.get('slow') or 0
        if time.time() - host.perf_logged >= 30:
            host.perf_logged = time.time()
            self.log({'host': host.id, 'perf': {'map': p['map'], 'players': st.get('players'), 'fps_cap': st.get('fps_cap'),
                      'fps': st.get('fps'), 'fps_min': p['fps'], 'hitch_ms': p['hitch_ms'], 'frame_ms': p['frame_ms'],
                      'slow': p['slow'], 'windows': p['n']}})
            host.perf = {**p, 'n': 0, 'fps': None, 'hitch_ms': 0, 'frame_ms': 0, 'slow': 0}

    async def stop(self, host, reason):
        if not self.is_live(host):
            return
        del self.hosts[host.id]
        self.log({'host': host.id, 'event': 'stopping', 'reason': reason})
        # Port and instance dir stay taken until the process is gone: a new server there would fail
        # to bind the port (or share files with the dying one).
        self._releasing.add(host.port)
        try:
            if host.proc and host.proc.returncode is None:
                try:
                    os.killpg(host.proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    await asyncio.wait_for(host.proc.wait(), 15)
                except asyncio.TimeoutError:
                    try:
                        os.killpg(host.proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    await host.proc.wait()
        finally:
            self._releasing.discard(host.port)
        # the heartbeat of a stopped server must not count as players (deploy.sh's busy check reads these files)
        (host.inst / 'MOBA' / 'Binaries' / 'Win64' / 'fangshost_status.json').unlink(missing_ok=True)
        self.collect_results(host)
        self.collect_loadouts(host)
        for cb in self.on_stopped:
            cb(host)
        self.replenish()

    async def shutdown(self):
        self._closing = True
        for h in list(self.hosts.values()):
            await self.stop(h, 'backend shutdown')
