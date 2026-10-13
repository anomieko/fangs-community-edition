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
    def __init__(self, *, game_dir, inst_root, ports, run_script, backend_addr, log, data_dir,
                 ready_timeout=180, idle_grace=180, unused_timeout=600):
        self.game_dir, self.inst_root, self.ports = game_dir, Path(inst_root), list(ports)
        self.run_script, self.backend_addr, self.log, self.data_dir = run_script, backend_addr, log, data_dir
        self.ready_timeout, self.idle_grace, self.unused_timeout = ready_timeout, idle_grace, unused_timeout
        self.hosts = {}          # id -> Host
        self.on_stopped = []     # callbacks(host)

    def free_ports(self):
        used = {h.port for h in self.hosts.values()}
        return [p for p in self.ports if p not in used]

    async def allocate(self, session_id, extra_args=()):
        ports = self.free_ports()
        if not ports:
            raise RuntimeError('no free game server slots')
        port = ports[0]
        hid = f'host-{port}'
        host = Host(hid, port, self.inst_root / hid)
        host.session_id = session_id
        self.hosts[hid] = host
        env = dict(os.environ, FANGS_BACKEND=self.backend_addr)
        self.inst_root.mkdir(parents=True, exist_ok=True)
        logf = open(self.inst_root / f'{hid}.stdout', 'w')
        host.proc = await asyncio.create_subprocess_exec(
            self.run_script, self.game_dir, str(host.inst), str(port), f'-FangsData={self.data_dir}', *extra_args,
            stdout=logf, stderr=asyncio.subprocess.STDOUT, env=env, start_new_session=True)
        self.log({'host': hid, 'event': 'starting', 'session': session_id, 'port': port})
        asyncio.create_task(self._watch(host))
        try:
            await asyncio.wait_for(host.ready.wait(), self.ready_timeout)
        except asyncio.TimeoutError:
            await self.stop(host, 'ready timeout')
            raise RuntimeError('game server failed to start')
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
            if not host.had_players and time.time() - host.started > self.unused_timeout:
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

    async def shutdown(self):
        for h in list(self.hosts.values()):
            await self.stop(h, 'backend shutdown')
