"""Pool of headless FANGS game hosts (dedicated lobby servers) launched via server/run-host.sh.

Each host serves one custom lobby or one matchmade game: it starts on the lobby map, players pick
heroes, and the server travels to the arena. When the match is over (everyone gone) the host is
stopped and its port freed. Hosts report map/player-count through FangsHost's status file.
"""
import asyncio, json, os, signal, time
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
    `lobby_grace`, a match everyone left after `idle_grace` (time to reconnect), a server nobody joined after
    `unused_timeout`. When every slot is taken, the longest-empty server is stopped for a new one."""

    def __init__(self, *, game_dir, inst_root, ports, run_script, backend_addr, log, data_dir,
                 ready_timeout=180, idle_grace=180, lobby_grace=20, unused_timeout=180, post_match=120, standby=1,
                 attempts=3):
        self.game_dir, self.inst_root, self.ports = game_dir, Path(inst_root), list(ports)
        self.run_script, self.backend_addr, self.log, self.data_dir = run_script, backend_addr, log, data_dir
        self.ready_timeout, self.idle_grace, self.unused_timeout = ready_timeout, idle_grace, unused_timeout
        self.lobby_grace, self.post_match = lobby_grace, post_match
        self.standby, self.attempts = standby, attempts
        self.hosts = {}          # id -> Host
        self.on_stopped = []     # callbacks(host)
        self.on_result = []      # callbacks(host, result): a finished match (FangsHost's fangshost_result-*.json)
        self._booting = 0        # standby servers being started
        self._allocating = 0     # allocate() calls still waiting for their server
        self._releasing = set()  # ports of stopped servers whose process hasn't exited yet
        self._closing = False

    def free_ports(self):
        used = {h.port for h in self.hosts.values()} | self._releasing
        return [p for p in self.ports if p not in used]

    def is_live(self, host):
        # Host ids are per port and get reused, so compare objects, not ids.
        return self.hosts.get(host.id) is host

    def _idle(self):
        return [h for h in self.hosts.values() if h.session_id is None and h.ready.is_set()]

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
                host = await self._start()
        finally:
            self._allocating -= 1
        host.session_id, host.started = session_id, time.time()
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

    def empty_for(self, host, now=None):
        """Seconds an assigned server has been without players (None if it has players or isn't assigned).
        A new server gets 90 s for its players to arrive."""
        now = now or time.time()
        if host.session_id is None or not host.ready.is_set() or host.status.get('players', 0):
            return None
        # players drop out for a few seconds on the way from lobby to arena: give a server that had players
        # 20 s before it counts as empty, a new one 90 s for its players to arrive
        return now - (host.empty_since or now) - 20 if host.had_players else now - host.started - 90

    async def _reclaim(self):
        """Every slot is taken: stop the server that has been empty the longest, if any."""
        now = time.time()
        empty = [(t, h) for h in self.hosts.values() if (t := self.empty_for(h, now)) is not None and t > 0]
        if empty:
            t, host = max(empty, key=lambda e: e[0])
            await self.stop(host, f'slot needed, empty for {t + 20:.0f} s' if host.had_players else 'slot needed, nobody came')

    def replenish(self):
        """Top up the idle standby servers (in the background)."""
        if self._closing:
            return
        missing = self.standby - len(self._idle()) - self._booting
        for _ in range(max(0, min(missing, len(self.free_ports())))):
            self._booting += 1
            asyncio.create_task(self._boot_standby())

    async def _boot_standby(self):
        try:
            if self.free_ports():                      # a lobby may have taken the slot meanwhile
                await self._start(standby=True)
        except Exception as e:  # noqa: BLE001 - logged; the next replenish tries again
            self.log({'host': 'standby', 'event': 'start failed', 'error': str(e)})
        finally:
            self._booting -= 1

    async def _start(self, standby=False):
        for attempt in range(1, self.attempts + 1):
            ports = await self._free_port_soon()
            if not ports:
                raise NoFreeSlot('no free game server slots')
            port = ports[0]
            host = await self._spawn(port)
            try:
                await asyncio.wait_for(self._ready_or_exit(host), self.ready_timeout)
            except asyncio.TimeoutError:
                await self.stop(host, 'ready timeout')
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

    async def _ready_or_exit(self, host):
        waiter = asyncio.create_task(host.ready.wait())
        exited = asyncio.create_task(host.proc.wait())
        await asyncio.wait({waiter, exited}, return_when=asyncio.FIRST_COMPLETED)
        for t in (waiter, exited):
            t.cancel()

    async def _spawn(self, port):
        hid = f'host-{port}'
        host = Host(hid, port, self.inst_root / hid)
        self.hosts[hid] = host
        for stale in ('fangshost_match.json', 'fangshost_status.json'):   # left by the previous server here
            (host.inst / 'MOBA' / 'Binaries' / 'Win64' / stale).unlink(missing_ok=True)
        self.collect_results(host)   # a match a previous server here finished just before it died
        env = dict(os.environ, FANGS_BACKEND=self.backend_addr)
        self.inst_root.mkdir(parents=True, exist_ok=True)
        logf = open(self.inst_root / f'{hid}.stdout', 'w')
        host.proc = await asyncio.create_subprocess_exec(
            self.run_script, self.game_dir, str(host.inst), str(port), f'-FangsData={self.data_dir}',
            stdout=logf, stderr=asyncio.subprocess.STDOUT, env=env, start_new_session=True)
        self.log({'host': hid, 'event': 'starting', 'port': port})
        asyncio.create_task(self._watch(host))
        return host

    async def _watch(self, host):
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
            st = host.status
            players = st.get('players', 0)
            if players:
                self._perf(host, st)
                host.had_players, host.empty_since = True, None
            elif host.empty_since is None:
                host.empty_since = time.time()
            idle = time.time() - (host.empty_since or time.time())
            in_lobby = st.get('map', '').endswith('LE_Lobby_Map') and not st.get('launched')
            if host.had_players and idle > (self.lobby_grace if in_lobby else self.idle_grace):
                await self.stop(host, 'everyone left the lobby' if in_lobby else 'match over / empty'); return
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
        self.collect_results(host)
        for cb in self.on_stopped:
            cb(host)
        self.replenish()

    async def shutdown(self):
        self._closing = True
        for h in list(self.hosts.values()):
            await self.stop(h, 'backend shutdown')
