"""Pool of headless FANGS game hosts (dedicated lobby servers) launched via server/run-host.sh.

Each host serves one custom lobby or one matchmade game: it starts on the lobby map, players pick
heroes, and the server travels to the arena. When the match is over (everyone gone) the host is
stopped and its port freed. Hosts report map/player-count through FangsHost's status file.
"""
import asyncio, json, os, signal, time
from pathlib import Path

READY_LINE = 'IpNetDriver listening on port {port}'
LOBBY_MAP = '/Game/Environment/Maps/LE_Lobby_Map'


class Host:
    def __init__(self, hid, port, inst):
        self.id, self.port, self.inst = hid, port, Path(inst)
        self.proc = None
        self.session_id = None
        self.started = time.time()
        self.ready = asyncio.Event()
        self.had_players = False
        self.empty_since = None

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
    and restarts a server that dies while booting (a few % of starts under Wine die early)."""

    def __init__(self, *, game_dir, inst_root, ports, run_script, backend_addr, log, data_dir,
                 ready_timeout=180, idle_grace=180, unused_timeout=180, standby=1, attempts=3):
        self.game_dir, self.inst_root, self.ports = game_dir, Path(inst_root), list(ports)
        self.run_script, self.backend_addr, self.log, self.data_dir = run_script, backend_addr, log, data_dir
        self.ready_timeout, self.idle_grace, self.unused_timeout = ready_timeout, idle_grace, unused_timeout
        self.standby, self.attempts = standby, attempts
        self.hosts = {}          # id -> Host
        self.on_stopped = []     # callbacks(host)
        self._booting = 0        # standby servers being started
        self._closing = False

    def free_ports(self):
        used = {h.port for h in self.hosts.values()}
        return [p for p in self.ports if p not in used]

    def _idle(self):
        return [h for h in self.hosts.values() if h.session_id is None and h.ready.is_set()]

    async def allocate(self, session_id, match=None):
        """A ready game server for `session_id` (a standby one if available, else a new one). `match`:
        {'size', 'map', 'map_name'} for matchmade games, handed to FangsHost via fangshost_match.json."""
        idle = self._idle()
        if idle:
            host = idle[0]
            self.log({'host': host.id, 'event': 'assigned (standby)', 'session': session_id})
        else:
            host = await self._start()
        host.session_id, host.started = session_id, time.time()
        if match:
            (host.inst / 'MOBA' / 'Binaries' / 'Win64' / 'fangshost_match.json').write_text(json.dumps(match))
        self.replenish()
        return host

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
            await self._start(standby=True)
        except Exception as e:  # noqa: BLE001 - logged; the next replenish tries again
            self.log({'host': 'standby', 'event': 'start failed', 'error': str(e)})
        finally:
            self._booting -= 1

    async def _start(self, standby=False):
        ports = self.free_ports()
        if not ports:
            raise RuntimeError('no free game server slots')
        port = ports[0]
        for attempt in range(1, self.attempts + 1):
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
            if not self.free_ports() or port not in self.free_ports():
                break
        raise RuntimeError('game server failed to start')

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
        (host.inst / 'MOBA' / 'Binaries' / 'Win64' / 'fangshost_match.json').unlink(missing_ok=True)
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
            st = host.status
            players = st.get('players', 0)
            if players:
                host.had_players, host.empty_since = True, None
            elif host.empty_since is None:
                host.empty_since = time.time()
            idle = time.time() - (host.empty_since or time.time())
            if host.had_players and idle > self.idle_grace:
                await self.stop(host, 'match over / empty'); return
            if host.session_id is not None and not host.had_players and time.time() - host.started > self.unused_timeout:
                await self.stop(host, 'nobody joined'); return
        await self.stop(host, f'process exited ({host.proc.returncode})')

    async def stop(self, host, reason):
        if self.hosts.pop(host.id, None) is None:
            return
        self.log({'host': host.id, 'event': 'stopping', 'reason': reason})
        if host.proc and host.proc.returncode is None:
            try:
                os.killpg(host.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                await asyncio.wait_for(host.proc.wait(), 15)
            except asyncio.TimeoutError:
                os.killpg(host.proc.pid, signal.SIGKILL)
        for cb in self.on_stopped:
            cb(host)
        self.replenish()

    async def shutdown(self):
        self._closing = True
        for h in list(self.hosts.values()):
            await self.stop(h, 'backend shutdown')
