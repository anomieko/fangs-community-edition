"""Game server lifecycle: backend/hosts.py and its wiring in fangs_backend.make_app.

Every way a game server ends (boot failure, ready timeout, crash, the lobby ending itself, everyone gone, nobody
joined, slot reclaimed, match finished, backend shutdown) must go through HostManager.stop(): it frees the port,
collects the match result and fires on_stopped, which drops the server's lobby from the session list.
fake_host.py plays the game server (server/run-host.sh); the tests write FangsHost's status and result files.

Time is compressed, not waited for: the watcher's 2 s poll and the 0.5 s waits run every 10 ms, stop()'s 15 s
SIGTERM grace is 0.5 s, and hosts.time is a clock a test skips ahead, so grace periods (and the hard-coded 10, 20
and 90 s) pass at once and "not yet" is checked deterministically.

    python -I -m unittest discover -s backend/tests -p test_hosts.py -v
"""
import asyncio
import collections
import contextlib
import json
import os
import signal
import sys
import tempfile
import time
import unittest
import warnings
from pathlib import Path
from unittest import mock

from support import FAKE_HOST, BackendCase, fb  # support puts backend/ on sys.path
import hosts   # the module fangs_backend uses

LOBBY, ARENA = hosts.LOBBY_MAP, '/Game/Environment/Maps/LE_Arena_Map'
PORT = 17777
POLL = 0.01        # the watcher's 2 s poll
KILL_AFTER = 0.5   # stop()'s 15 s wait for a server to exit after SIGTERM


class FastAsyncio:
    """hosts.asyncio with the delays above. Counts each server's watcher polls (a test waits for the watcher's next
    look after changing something) and records every process started, so none outlives its test. With `port_gate`
    (an asyncio.Event) set up, an allocate() waiting for a port being freed waits for the test to open it."""

    def __init__(self):
        self.polls, self.procs = collections.Counter(), []
        self.port_gate, self.held = None, 0

    def __getattr__(self, name):
        return getattr(asyncio, name)

    async def sleep(self, delay, result=None):
        caller = sys._getframe(1)
        if delay >= 2:   # HostManager._watch(host) between two looks at its server
            self.polls[caller.f_locals.get('host')] += 1
        elif self.port_gate and caller.f_code.co_name == '_free_port_soon':
            self.held += 1
            await self.port_gate.wait()
        return await asyncio.sleep(min(delay, POLL), result)

    def wait_for(self, aw, timeout):
        return asyncio.wait_for(aw, KILL_AFTER if timeout == 15 else timeout)

    async def create_subprocess_exec(self, *args, **kw):
        proc = await asyncio.create_subprocess_exec(*args, **kw)
        self.procs.append(proc)
        return proc


class Clock:
    """hosts.time: real time plus what the test skipped."""

    def __init__(self):
        self.skipped = 0.0

    def time(self):
        return time.time() + self.skipped

    def advance(self, seconds):
        self.skipped += seconds


class Lifecycle:
    """Patches hosts.py (see above) and helpers to play FangsHost. Set self.inst_root before patch_hosts()."""

    def patch_hosts(self):
        # hosts.py _spawn never closes the server's stdout log file: one ResourceWarning per server started
        self.enterContext(warnings.catch_warnings())
        warnings.filterwarnings('ignore', r'unclosed file <_io.TextIOWrapper name=.*host-\d+\.stdout', ResourceWarning)
        self.aio, self.clock = FastAsyncio(), Clock()
        for name, fake in (('asyncio', self.aio), ('time', self.clock)):
            patcher = mock.patch.object(hosts, name, fake)
            patcher.start()
            self.addCleanup(patcher.stop)
        self.addAsyncCleanup(self.kill_all)
        self.inst_root.mkdir(parents=True, exist_ok=True)

    async def kill_all(self):
        """Whatever a test left: cancel HostManager's tasks (a boot retry must not start another server), then
        kill every process the test started."""
        def backend_task(t):
            code = getattr(t.get_coro(), 'cr_code', None)
            return code is not None and Path(code.co_filename).name in ('hosts.py', 'fangs_backend.py')
        for _ in range(3):
            tasks = [t for t in asyncio.all_tasks() if t is not asyncio.current_task() and backend_task(t)]
            for t in tasks:
                t.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            live = [p for p in self.aio.procs if p.returncode is None]
            for p in live:
                with contextlib.suppress(ProcessLookupError):
                    os.killpg(p.pid, signal.SIGKILL)
                await p.wait()
            if not tasks and not live:
                return

    async def until(self, cond, what, timeout=5):
        deadline = time.monotonic() + timeout
        while not cond():
            if time.monotonic() > deadline:
                self.fail(f'timed out waiting for {what}')
            await asyncio.sleep(0.005)

    async def look(self, host, times=1):
        """Waits until the watcher has looked at `host` `times` more times (a full poll after the last change)."""
        seen = self.aio.polls[host]
        await self.until(lambda: self.aio.polls[host] >= seen + times, f'{host.id} watched')

    def mode(self, mode):
        """How the next fake servers start: ready, die (exit 1 at once) or hang (never ready)."""
        (self.inst_root / 'fake_host_mode').write_text(mode)

    def win64(self, host_id=f'host-{PORT}'):
        d = self.inst_root / host_id / 'MOBA' / 'Binaries' / 'Win64'
        d.mkdir(parents=True, exist_ok=True)
        return d

    def status(self, host, players, game_map=LOBBY, launched=False, **more):
        """FangsHost's heartbeat (written to a .tmp and renamed, as FangsHost does)."""
        tmp = self.win64(host.id) / 'fangshost_status.json.tmp'
        tmp.write_text(json.dumps({'map': game_map, 'players': players, 'ready': True, 'launched': launched,
                                   'time': time.time(), **more}))
        tmp.replace(tmp.with_suffix(''))

    def result(self, host_id, result, n=1):
        """FangsHost's match result at the end of a match."""
        f = self.win64(host_id) / f'fangshost_result-{n}.json'
        f.with_suffix('.tmp').write_text(json.dumps(result))
        f.with_suffix('.tmp').replace(f)
        return f

    async def crash(self, host, code):
        """The server exits by itself with `code`. (fake_host's control file goes too: the next server on the port
        would read it.)"""
        exit_file = host.inst / 'fake_exit'
        exit_file.write_text(str(code))
        await asyncio.wait_for(host.proc.wait(), 5)
        exit_file.unlink()

    def stubborn(self):
        """A run_script whose server ignores SIGTERM: stop() has to kill it, so its port is held a while."""
        script = self.inst_root.parent / 'stubborn_host.py'
        script.write_text('#!/usr/bin/env python3\nimport runpy, signal\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\n'
                          f'runpy.run_path({str(FAKE_HOST)!r}, run_name="__main__")\n')
        script.chmod(0o755)
        return str(script)

    def events(self, event):
        return [e for e in self.logs if e.get('event') == event]

    def reasons(self):
        return [e['reason'] for e in self.events('stopping')]

    def assert_clean(self, hm, live=()):
        """Only `live` servers left, and no port held by a server that is gone."""
        self.assertEqual(set(hm.hosts.values()), set(live))
        self.assertEqual(hm._releasing, set())
        self.assertEqual((hm._booting, hm._allocating), (0, 0))
        self.assertEqual(hm.free_ports(), [p for p in hm.ports if p not in {h.port for h in live}])
        self.assertEqual({p for p in self.aio.procs if p.returncode is None}, {h.proc for h in live})


class Hosts(Lifecycle, unittest.IsolatedAsyncioTestCase):
    """HostManager on its own, with fake_host.py servers."""

    async def asyncSetUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.inst_root = self.tmp / 'hosts'
        self.patch_hosts()
        self.logs, self.stopped, self.results, self.order = [], [], [], []

    def manager(self, ports=1, **kw):
        """Grace periods are long unless a test sets them: nothing stops a server unless the test makes it."""
        kw = {'standby': 0, 'ready_timeout': 30, 'lobby_grace': 1000, 'idle_grace': 1000, 'unused_timeout': 1000,
              'post_match': 1000, **kw}
        hm = hosts.HostManager(game_dir=str(self.tmp / 'game'), inst_root=self.inst_root,
                               ports=range(PORT, PORT + ports), run_script=str(FAKE_HOST), backend_addr='127.0.0.1:1',
                               log=self.logs.append, data_dir=str(self.tmp), **kw)
        hm.on_stopped.append(lambda h: (self.stopped.append(h), self.order.append(('stopped', h))))
        hm.on_result.append(lambda h, r: (self.results.append((h, r)), self.order.append(('result', h))))
        self.addAsyncCleanup(hm.shutdown)
        return hm

    async def playing(self, hm, sid='lobby', players=2, **status):
        """A server allocated to `sid` that the watcher has seen with players."""
        host = await hm.allocate(sid)
        self.status(host, players, **status)
        await self.until(lambda: host.had_players, 'players seen')
        return host

    async def emptied(self, host, **status):
        self.status(host, 0, **status)
        await self.until(lambda: host.empty_since is not None, 'empty seen')

    # ------------------------------------------------------------ standby servers

    async def test_replenish_boots_the_standby_servers_once(self):
        hm = self.manager(ports=3, standby=2)
        hm.replenish()
        await self.until(lambda: len(hm._idle()) == 2 and not hm._booting, 'two standby servers')
        hm.replenish()
        self.assertEqual(len(self.events('starting')), 2)
        self.assertTrue(all(h.session_id is None for h in hm.hosts.values()))
        self.assert_clean(hm, live=hm.hosts.values())

    async def test_replenish_never_boots_more_than_the_free_slots(self):
        hm = self.manager(ports=2, standby=3)
        hm.replenish()
        self.assertEqual(hm._booting, 2)
        await self.until(lambda: len(hm._idle()) == 2 and not hm._booting, 'two standby servers')
        hm.replenish()
        self.assertEqual(len(self.events('starting')), 2)

    async def test_allocate_claims_a_ready_standby_and_boots_the_next(self):
        hm = self.manager(ports=2, standby=1)
        hm.replenish()
        await self.until(lambda: hm._idle() and not hm._booting, 'standby ready')
        standby = hm._idle()[0]
        host = await hm.allocate('lobby')
        self.assertIs(host, standby)
        self.assertEqual(host.session_id, 'lobby')
        self.assertEqual(self.events('assigned (standby)')[0]['session'], 'lobby')
        await self.until(lambda: hm._idle() and not hm._booting, 'next standby ready')
        self.assertEqual(hm._idle()[0].port, PORT + 1)

    # a bug until the review sprint fixed it: a standby claimed as soon as it is ready is never replaced
    async def test_standby_claimed_the_moment_it_is_ready_is_replaced(self):
        hm = self.manager(ports=2, standby=1)
        hm.replenish()
        await self.until(lambda: hm.hosts, 'standby starting')
        standby, claimed = next(iter(hm.hosts.values())), []
        set_ready = standby.ready.set

        def ready_and_claimed():   # a lobby waiting in allocate() takes it before its boot task has returned
            set_ready()
            claimed.append(asyncio.ensure_future(hm.allocate('lobby')))
        standby.ready.set = ready_and_claimed
        await self.until(lambda: self.events('standby ready'), 'standby boot done')
        self.assertIs(await claimed[0], standby)
        self.assertTrue(hm._booting or hm._idle(), 'no standby is booting or ready')

    async def test_allocate_waits_for_a_booting_standby_instead_of_starting_another(self):
        hm = self.manager(ports=2, standby=1)
        hm.replenish()
        host = await hm.allocate('lobby')
        assigned = self.logs.index(self.events('assigned (standby)')[0])
        self.assertEqual([e for e in self.logs[:assigned] if e.get('event') == 'starting'],
                         [{'host': host.id, 'event': 'starting', 'port': PORT}])

    async def test_concurrent_allocates_get_different_standby_servers(self):
        hm = self.manager(ports=2, standby=2)
        hm.replenish()
        await self.until(lambda: len(hm._idle()) == 2, 'two standby servers')
        a, b = await asyncio.gather(hm.allocate('a'), hm.allocate('b'))
        self.assertIsNot(a, b)
        self.assertEqual((a.session_id, b.session_id), ('a', 'b'))

    async def test_concurrent_allocates_waiting_for_one_booting_standby_get_different_servers(self):
        hm = self.manager(ports=2, standby=1)
        hm.replenish()
        a, b = await asyncio.gather(hm.allocate('a'), hm.allocate('b'))
        self.assertIsNot(a, b)
        self.assertEqual((a.session_id, b.session_id), ('a', 'b'))

    # a bug until the review sprint fixed it: a server allocate() boots for itself is claimable by another once ready
    async def test_server_booted_for_one_allocate_is_not_claimed_by_another(self):
        hm = self.manager(ports=2)
        first = asyncio.create_task(hm.allocate('a'))
        await self.until(lambda: hm.hosts, 'a server starting')
        host, other = next(iter(hm.hosts.values())), []
        set_ready = host.ready.set

        def ready_and_another_lobby():   # a second lobby asks for a server the moment this one is ready
            set_ready()
            other.append(asyncio.ensure_future(hm.allocate('b')))
        host.ready.set = ready_and_another_lobby
        a = await first
        b = await other[0]
        self.assertIsNot(a, b, f'both lobbies got {a.id} (its session: {a.session_id})')

    # a bug until the review sprint fixed it: allocate() waiting for a port being freed loses it to a new standby (H3)
    async def test_allocate_waiting_for_a_releasing_port_gets_a_server(self):
        hm = self.manager(standby=1)
        hm.run_script = self.stubborn()   # its port stays taken until stop() kills it
        a = await hm.allocate('a')   # the only slot: no room for a standby
        stopping = asyncio.create_task(hm.stop(a, 'session deleted'))
        await self.until(lambda: a.port in hm._releasing, 'a stopping')
        self.aio.port_gate = asyncio.Event()
        b = asyncio.create_task(hm.allocate('b'))
        await self.until(lambda: self.aio.held, 'b waiting for the port')
        await stopping   # the port is free, and stop() tops up the standby
        await self.until(lambda: len(self.events('starting')) == 2, 'standby starting')
        self.aio.port_gate.set()
        try:
            host = await b
        except RuntimeError as e:
            self.fail(f'allocate failed: {e}')
        self.assertEqual(host.session_id, 'b')

    async def test_allocate_hands_the_match_to_its_server(self):
        hm = self.manager()
        match = {'size': 4, 'map': 'LE_Casual', 'map_name': 'Casual'}
        host = await hm.allocate('match', match=match)
        self.assertEqual(json.loads((self.win64(host.id) / 'fangshost_match.json').read_text()), match)

    # ------------------------------------------------------------ boot failures

    async def test_server_dying_at_boot_is_retried_then_allocate_raises(self):
        self.mode('die')
        hm = self.manager(ports=2, attempts=3)
        with self.assertRaisesRegex(RuntimeError, 'game server failed to start'):
            await hm.allocate('lobby')
        self.assertEqual(len(self.events('starting')), 3)
        self.assertEqual(len(self.stopped), 3)
        self.assertTrue(all(h.session_id is None for h in self.stopped))   # never handed to the lobby
        self.assert_clean(hm)
        self.assertEqual(hm.capacity(), 2)

    async def test_server_dying_at_boot_is_replaced_by_the_next_attempt(self):
        self.mode('die')
        hm = self.manager(attempts=3)
        hm.log = lambda e: (self.logs.append(e), e.get('event') == 'stopping' and self.mode('ready'))
        host = await hm.allocate('lobby')
        self.assertEqual(len(self.events('starting')), 2)
        self.assertEqual(host.session_id, 'lobby')
        self.assert_clean(hm, live=[host])

    async def test_standby_that_fails_to_boot_is_logged_and_frees_its_slot(self):
        self.mode('die')
        hm = self.manager(standby=1, attempts=2)
        hm.replenish()
        await self.until(lambda: self.events('start failed'), 'standby given up')
        self.assertEqual(self.events('start failed')[0]['host'], 'standby')
        self.assertEqual(len(self.events('starting')), 2)
        self.assertEqual((hm.hosts, hm._releasing, hm.free_ports()), ({}, set(), [PORT]))

    # a bug until the review sprint fixed it: a standby whose boots all failed is not tried again (H3)
    async def test_standby_that_failed_to_boot_is_tried_again_later(self):
        self.mode('die')
        hm = self.manager(standby=1, attempts=2)
        hm.replenish()
        await self.until(lambda: self.events('start failed'), 'standby given up')
        self.mode('ready')   # whatever made it fail is over
        self.clock.advance(600)
        await self.until(lambda: hm._idle(), 'a standby again', timeout=2)

    # a bug until the review sprint fixed it: a server whose process can't be started keeps its port forever (H3)
    async def test_server_that_cannot_be_launched_frees_its_port(self):
        hm = self.manager()
        hm.run_script = str(self.tmp / 'missing.sh')
        with self.assertRaises((OSError, RuntimeError)):
            await hm.allocate('lobby')
        self.assert_clean(hm)

    async def test_ready_timeout_stops_the_hung_server_and_retries(self):
        self.mode('hang')
        hm = self.manager(ready_timeout=0.3, attempts=2)
        with self.assertRaisesRegex(RuntimeError, 'game server failed to start'):
            await hm.allocate('lobby')
        self.assertEqual(self.reasons(), ['ready timeout', 'ready timeout'])
        self.assertEqual([p.returncode for p in self.aio.procs], [-signal.SIGTERM] * 2)
        self.assert_clean(hm)

    # a bug until the review sprint fixed it: a ready timeout leaves _ready_or_exit's ready.wait() task pending (H3)
    async def test_ready_timeout_leaves_no_task_behind(self):
        self.mode('hang')
        hm = self.manager(ready_timeout=0.3, attempts=1)
        with self.assertRaises(RuntimeError):
            await hm.allocate('lobby')

        def waiting():
            return [t for t in asyncio.all_tasks() if t.get_coro().__qualname__ == 'Event.wait']
        await self.until(lambda: not waiting(), 'the ready waiter to end', timeout=1)

    async def test_spawn_removes_the_previous_servers_match_and_status(self):
        self.mode('hang')   # the new server writes nothing: only the old files could make it look ready
        hm = self.manager()
        old = self.win64()
        (old / 'fangshost_match.json').write_text(json.dumps({'size': 2}))
        (old / 'fangshost_status.json').write_text(json.dumps({'map': LOBBY, 'ready': True, 'players': 3}))
        booting = asyncio.create_task(hm.allocate('lobby'))
        self.addCleanup(booting.cancel)
        await self.until(lambda: self.events('starting'), 'server starting')
        self.assertFalse((old / 'fangshost_match.json').exists())
        self.assertFalse((old / 'fangshost_status.json').exists())
        host = hm.hosts[f'host-{PORT}']
        await self.look(host, 2)
        self.assertFalse(host.ready.is_set())

    # ------------------------------------------------------------ crashes and other exits

    async def test_crash_in_lobby_frees_port_and_fires_on_stopped(self):
        hm = self.manager()
        host = await self.playing(hm)
        await self.crash(host, 3)
        await self.until(lambda: self.stopped, 'on_stopped')
        self.assertEqual(self.stopped, [host])
        self.assertEqual(self.reasons(), ['process exited (3)'])
        self.assert_clean(hm)
        self.assertEqual(hm.capacity(), 1)   # what the matchmaker sees
        again = await hm.allocate('next lobby')
        self.assertEqual(again.port, PORT)

    async def test_crash_mid_match_frees_port_and_fires_on_stopped(self):
        hm = self.manager()
        host = await self.playing(hm, game_map=ARENA, launched=True)
        await self.crash(host, 3)
        await self.until(lambda: self.stopped, 'on_stopped')
        self.assertEqual((self.stopped, self.reasons()), ([host], ['process exited (3)']))
        self.assert_clean(hm)

    async def test_crashed_standby_is_replaced(self):
        hm = self.manager(ports=2, standby=1)
        hm.replenish()
        await self.until(lambda: hm._idle() and not hm._booting, 'standby ready')
        standby = hm._idle()[0]
        await self.crash(standby, 3)
        await self.until(lambda: hm._idle() and hm._idle()[0] is not standby and not hm._booting, 'new standby')
        self.assertEqual(self.reasons(), ['process exited (3)'])

    # a bug until the review sprint fixed it: a watcher that raises leaves its server running, port taken (H1). The
    # fix must not end a live match either: the server is stopped when it exits (second review, R2-3)
    async def test_server_whose_watcher_failed_is_stopped_when_it_exits(self):
        hm = self.manager()
        host = await hm.allocate('lobby')
        self.status(host, 1, hitch_ms='?')   # a heartbeat _perf can't compare: TypeError in the watcher
        await self.until(lambda: self.events('watcher failed'), 'the watcher to fail')
        await asyncio.sleep(0.05)
        self.assertTrue(hm.is_live(host))    # its player plays on
        await self.crash(host, 3)
        await self.until(lambda: not hm.is_live(host), 'the server to be stopped', timeout=1)

    async def test_allocate_that_gives_up_leaves_its_server_claimable(self):
        # a server booted for a request that was cancelled must not stay reserved for nobody (second review, R2-4)
        self.mode('hang')
        hm = self.manager()
        allocating = asyncio.create_task(hm.allocate('lobby'))
        await self.until(lambda: hm.hosts, 'the server to start')
        host = next(iter(hm.hosts.values()))
        allocating.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await allocating
        self.assertFalse(host.reserved)
        self.assertEqual(hm.capacity(), 1)

    async def test_stop_kills_a_server_that_ignores_sigterm(self):
        hm = self.manager()
        hm.run_script = self.stubborn()
        host = await hm.allocate('lobby')
        stopping = asyncio.create_task(hm.stop(host, 'test'))
        await self.until(lambda: host.port in hm._releasing, 'stop under way')
        self.assertEqual(hm.free_ports(), [])   # the port stays taken until the process is gone
        await stopping
        self.assertEqual(host.proc.returncode, -signal.SIGKILL)
        self.assertEqual(self.stopped, [host])
        self.assert_clean(hm)

    # a bug until the review sprint fixed it: stop() leaves the status file; deploy.sh counts its players (H4)
    async def test_stopped_server_leaves_no_status_behind(self):
        hm = self.manager()
        host = await self.playing(hm)
        await hm.stop(host, 'test')
        self.assertFalse((self.win64(host.id) / 'fangshost_status.json').exists())

    # ------------------------------------------------------------ match results

    async def test_result_is_handed_over_once_while_the_server_runs(self):
        hm = self.manager()
        host = await self.playing(hm, game_map=ARENA, launched=True)
        f = self.result(host.id, {'winning_team': 1})
        await self.until(lambda: self.results, 'on_result')
        await self.look(host, 2)
        await hm.stop(host, 'test')   # collects again: nothing left
        self.assertEqual(self.results, [(host, {'winning_team': 1})])
        self.assertFalse(f.exists())
        self.assertIsNotNone(host.match_over)

    async def test_result_saved_just_before_the_server_stops_is_collected_by_stop(self):
        hm = self.manager()
        host = await self.playing(hm, game_map=ARENA, launched=True)
        self.result(host.id, {'winning_team': 2})
        await hm.stop(host, 'test')   # the watcher never saw it
        self.assertEqual(self.results, [(host, {'winning_team': 2})])
        self.assertEqual(self.order, [('result', host), ('stopped', host)])   # ingested before the lobby goes

    async def test_unreadable_result_is_kept_as_bad_and_the_server_runs_on(self):
        hm = self.manager()
        host = await self.playing(hm, game_map=ARENA, launched=True)
        (self.win64(host.id) / 'fangshost_result-1.json').write_text('{"winning_tea')
        await self.until(lambda: self.events('unreadable match result'), 'unreadable result logged')
        self.assertTrue((self.win64(host.id) / 'fangshost_result-1.bad').exists())
        self.assertEqual((self.results, host.match_over), ([], None))
        await self.look(host)
        self.assertTrue(hm.is_live(host))

    async def test_failing_result_handler_does_not_stop_the_watcher(self):
        hm = self.manager()
        hm.on_result.insert(0, lambda h, r: 1 / 0)
        host = await self.playing(hm, game_map=ARENA, launched=True)
        self.result(host.id, {'winning_team': 1})
        await self.until(lambda: self.results, 'the other handler')
        self.assertIn('ZeroDivisionError', self.events('match result failed')[0]['error'])
        await self.look(host)
        self.assertTrue(hm.is_live(host))

    async def test_result_left_by_a_dead_server_is_collected_at_the_next_spawn(self):
        hm = self.manager()
        f = self.result(f'host-{PORT}', {'winning_team': 1})
        host = await hm.allocate('lobby')
        self.assertEqual([r for _, r in self.results], [{'winning_team': 1}])
        self.assertFalse(f.exists())
        await hm.stop(host, 'test')
        self.assertEqual(len(self.results), 1)

    # a bug until the review sprint fixed it: the old server's result marks the new server's match as over (H3)
    async def test_result_left_by_a_dead_server_does_not_end_the_next_servers_lobby(self):
        hm = self.manager(post_match=60)
        self.result(f'host-{PORT}', {'winning_team': 1})
        host = await hm.allocate('lobby')
        self.assertIsNone(host.match_over)   # fangs_backend.lobby_open: not listed, not joinable
        self.clock.advance(61)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host), self.reasons())

    # ------------------------------------------------------------ normal end of a match

    async def test_finished_match_stops_after_post_match(self):
        hm = self.manager(post_match=60)
        host = await self.playing(hm, game_map=ARENA, launched=True)
        self.result(host.id, {'winning_team': 1})
        await self.until(lambda: self.results, 'on_result')
        self.clock.advance(55)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))   # players are still on the end screen
        self.clock.advance(10)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['match finished'])
        self.assert_clean(hm)

    async def test_finished_match_stops_10s_after_everyone_left(self):
        hm = self.manager()
        host = await self.playing(hm, game_map=ARENA, launched=True)
        self.result(host.id, {'winning_team': 1})
        await self.until(lambda: self.results, 'on_result')
        await self.emptied(host, game_map=ARENA, launched=True)
        self.clock.advance(8)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))
        self.clock.advance(3)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['match finished'])

    # ------------------------------------------------------------ empty and unused servers

    async def test_lobby_everyone_left_stops_after_lobby_grace(self):
        hm = self.manager(lobby_grace=60)
        host = await self.playing(hm)
        await self.emptied(host)
        self.clock.advance(55)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))
        self.clock.advance(10)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['everyone left the lobby'])
        self.assert_clean(hm)

    async def test_empty_match_stops_after_idle_grace_not_lobby_grace(self):
        hm = self.manager(lobby_grace=5, idle_grace=60)
        host = await self.playing(hm, game_map=ARENA, launched=True)
        await self.emptied(host, game_map=ARENA, launched=True)
        self.clock.advance(55)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))   # time to reconnect
        self.clock.advance(10)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['match over / empty'])

    async def test_lobby_that_launched_its_match_gets_idle_grace(self):
        # players drop out for a moment on the way from the lobby to the arena
        hm = self.manager(lobby_grace=5, idle_grace=60)
        host = await self.playing(hm, launched=True)
        await self.emptied(host, launched=True)
        self.clock.advance(55)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))
        self.clock.advance(10)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['match over / empty'])

    async def test_player_back_within_grace_restarts_the_empty_clock(self):
        hm = self.manager(idle_grace=60)
        host = await self.playing(hm, game_map=ARENA, launched=True)
        await self.emptied(host, game_map=ARENA, launched=True)
        self.clock.advance(50)
        self.status(host, 1, game_map=ARENA, launched=True)
        await self.until(lambda: host.empty_since is None, 'player back')
        self.clock.advance(20)
        await self.emptied(host, game_map=ARENA, launched=True)
        self.clock.advance(55)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))
        self.assertEqual(self.reasons(), [])

    async def test_solo_session_stops_soon_after_its_player_left(self):
        # Training and Solo lobbies: nobody else to wait for (a community member: a left Training blocked a slot for 3 minutes)
        hm = self.manager(solo_grace=10)
        host = await self.playing(hm, players=1, game_map=ARENA, launched=True)
        host.solo = True
        await self.emptied(host, game_map=ARENA, launched=True)
        self.clock.advance(8)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))
        self.clock.advance(5)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['solo player left'])
        self.assert_clean(hm)

    async def test_solo_player_still_loading_the_arena_is_not_gone(self):
        # on the way from the lobby to the arena the server counts nobody until the player has loaded it
        hm = self.manager(solo_grace=10, idle_grace=60)
        host = await self.playing(hm, players=1)
        host.solo = True
        await self.emptied(host, game_map=ARENA, launched=True)
        self.clock.advance(30)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))      # idle_grace, not solo_grace: not seen on this map yet
        self.status(host, 1, game_map=ARENA, launched=True)
        await self.until(lambda: host.empty_since is None, 'player arrived')
        await self.emptied(host, game_map=ARENA, launched=True)
        self.clock.advance(11)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['solo player left'])

    async def test_server_nobody_joined_stops_after_unused_timeout(self):
        hm = self.manager(ports=2, standby=1, unused_timeout=60)
        host = await hm.allocate('lobby')
        await self.until(lambda: hm._idle() and not hm._booting, 'standby ready')
        standby = hm._idle()[0]
        self.clock.advance(55)
        await self.look(host, 2)
        self.assertTrue(hm.is_live(host))
        self.clock.advance(10)
        await self.until(lambda: self.stopped, 'stopped')
        self.assertEqual(self.reasons(), ['nobody joined'])
        await self.look(standby, 2)
        self.assertTrue(hm.is_live(standby))   # an unassigned standby waits as long as it takes

    # ------------------------------------------------------------ every slot taken

    # The clock is moved right before allocate(), with no await in between: the reclaim, not the watcher, stops it.

    async def test_full_slots_reclaim_the_longest_empty_server(self):
        hm = self.manager(ports=2, lobby_grace=20, idle_grace=180)   # production's graces
        a = await self.playing(hm, 'a')
        b = await self.playing(hm, 'b', game_map=ARENA, launched=True)
        await self.emptied(a)
        self.clock.advance(5)
        await self.emptied(b, game_map=ARENA, launched=True)
        self.clock.advance(25)
        c = await hm.allocate('c')
        self.assertEqual(self.stopped, [a])
        self.assertRegex(self.reasons()[0], r'^slot needed, empty for 3\d s$')
        self.assertEqual(c.port, a.port)
        self.assert_clean(hm, live=[b, c])

    async def test_full_slots_reclaim_an_emptied_solo_server_after_solo_grace(self):
        hm = self.manager(solo_grace=10, idle_grace=180)   # production's graces
        a = await self.playing(hm, 'a', players=1, game_map=ARENA, launched=True)
        a.solo = True
        await self.emptied(a, game_map=ARENA, launched=True)
        self.clock.advance(11)
        b = await hm.allocate('b')
        self.assertEqual(self.stopped, [a])
        self.assertEqual(b.port, a.port)

    async def test_full_slots_reclaim_a_server_nobody_came_to(self):
        hm = self.manager(unused_timeout=180)
        a = await hm.allocate('a')
        self.clock.advance(181)   # past the 90 s its players get to arrive, and unused_timeout
        b = await hm.allocate('b')
        self.assertEqual((self.stopped, self.reasons()), ([a], ['slot needed, nobody came']))
        self.assertEqual(b.port, a.port)

    async def test_full_slots_with_every_server_in_use_raise(self):
        hm = self.manager()
        a = await self.playing(hm, 'a', game_map=ARENA, launched=True)
        self.clock.advance(3600)
        with self.assertRaisesRegex(RuntimeError, 'no free game server slots'):
            await hm.allocate('b')
        self.assertEqual(self.reasons(), [])
        self.assert_clean(hm, live=[a])

    # a bug until the review sprint fixed it: a match empty 20 s (still loading) is reclaimed despite idle_grace (H5)
    async def test_full_slots_never_reclaim_a_match_within_idle_grace(self):
        hm = self.manager(lobby_grace=20, idle_grace=180)
        b = await self.playing(hm, 'b', game_map=ARENA, launched=True)
        await self.emptied(b, game_map=ARENA, launched=True)
        self.clock.advance(25)
        with self.assertRaisesRegex(RuntimeError, 'no free game server slots'):
            await hm.allocate('c')
        self.assertTrue(hm.is_live(b))

    # ------------------------------------------------------------ preset saves (the in-match preset panel)

    def loadout_file(self, host, name, text):
        f = self.win64(host.id) / name
        f.with_suffix('.tmp').write_text(text)
        f.with_suffix('.tmp').replace(f)
        return f

    async def test_preset_save_goes_to_on_loadout_once(self):
        hm = self.manager()
        saved = []
        hm.on_loadout.append(lambda h, uid, v: saved.append((h, uid, v)))
        host = await self.playing(hm)
        uid = 'a' * 32
        f = self.loadout_file(host, f'fangshost_loadout-{uid}-1.json', '{"FireMage": {"CurrentLoadoutIndex": 1}}')
        await self.until(lambda: saved, 'preset save collected')
        self.assertEqual(saved, [(host, uid, {'FireMage': {'CurrentLoadoutIndex': 1}})])
        self.assertFalse(f.exists())
        await self.look(host, 2)
        self.assertEqual(len(saved), 1)

    async def test_bad_preset_saves_are_kept_aside(self):
        hm = self.manager()
        saved = []
        hm.on_loadout.append(lambda h, uid, v: saved.append(uid))
        host = await self.playing(hm)
        bad = [self.loadout_file(host, 'fangshost_loadout-NotAPlayerId-1.json', '{}'),   # not a player id
               self.loadout_file(host, f'fangshost_loadout-{"b" * 32}-2.json', '[1, 2]'),  # not an object
               self.loadout_file(host, f'fangshost_loadout-{"c" * 32}-3.json', '{"x": "' + 'y' * 70000 + '"}')]
        await self.until(lambda: all(f.with_suffix('.bad').exists() for f in bad), 'bad saves set aside')
        self.assertEqual(saved, [])
        self.assertEqual(len(self.events('unreadable preset save')), 3)

    # ------------------------------------------------------------ backend shutdown

    async def test_shutdown_stops_everything_and_boots_no_standby(self):
        hm = self.manager(ports=3, standby=1)
        lobby = await self.playing(hm)
        await self.until(lambda: hm._idle() and not hm._booting, 'standby ready')
        standby = hm._idle()[0]
        await hm.shutdown()
        self.assertEqual(set(self.stopped), {lobby, standby})
        self.assertEqual(self.reasons(), ['backend shutdown'] * 2)
        hm.replenish()
        self.assertEqual(len(self.events('starting')), 2)
        self.assert_clean(hm)

    # a bug until the review sprint fixed it: a boot under way when the backend shuts down starts another server (H3)
    async def test_shutdown_during_a_boot_leaves_no_server_running(self):
        self.mode('hang')
        hm = self.manager(ports=2, standby=1, attempts=2)
        hm.replenish()
        await self.until(lambda: self.events('starting'), 'standby starting')
        await hm.shutdown()
        await self.until(lambda: not hm._booting or len(self.aio.procs) > 1, 'the boot to react')
        self.assertEqual(len(self.aio.procs), 1, 'a server was started after shutdown')
        self.assert_clean(hm)


class AppHosts(Lifecycle, BackendCase):
    """The same through the real app (make_app's wiring): what players see of a server that goes away."""

    async def asyncSetUp(self):
        await super().asyncSetUp()
        self.inst_root = self.tmp / 'hosts'
        self.patch_hosts()
        self.hm = self.app['hosts']
        self.viewer = self.auth(await self.login('viewer'))   # another player, looking at the lobby list

    async def frame(self, ws, msg_type):
        while True:
            msg = await asyncio.wait_for(ws.receive_str(), 5)
            fields = dict(line.split(': ', 1) for line in msg.split('\n') if ': ' in line)
            if fields.get('type') == msg_type:
                return fields

    async def lobby(self, name):
        """`name` creates a custom lobby and asks for its server (createDSRequest); returns its session id and
        the dsNotif."""
        token = await self.login(name)
        r = await self.client.post(f'/sessionbrowser/namespaces/{fb.NAMESPACE}/gamesession', headers=self.auth(token),
                                   json={'session_type': 'dedicated', 'game_session_setting': {'mode': 'custom'}})
        sid = (await r.json())['session_id']
        ws = await self.client.ws_connect('/lobby', protocols=('wss',), headers=self.auth(token))
        self.addAsyncCleanup(ws.close)
        await ws.send_str(fb.lobby_frame(type='createDSRequest', id='1', matchId=sid))
        return sid, await self.frame(ws, 'dsNotif')

    async def listed(self):
        r = await self.client.get(f'/sessionbrowser/namespaces/{fb.NAMESPACE}/gamesession', headers=self.viewer)
        return [s['session_id'] for s in (await r.json())['sessions']]

    async def session_status(self, sid):
        return (await self.client.get(f'/sessionbrowser/namespaces/{fb.NAMESPACE}/gamesession/{sid}',
                                      headers=self.viewer)).status

    async def gone(self, host):
        await self.until(lambda: not self.hm.is_live(host) and host.port not in self.hm._releasing, 'server gone')

    async def test_crash_in_lobby_removes_lobby_and_frees_port(self):
        sid, notif = await self.lobby('alice')
        self.assertEqual((notif['status'], notif['port']), ('BUSY', str(PORT)))
        self.assertEqual(await self.listed(), [sid])
        host = self.app['sessions'][sid]['_host']
        self.status(host, 1)
        await self.until(lambda: host.had_players, 'player seen')
        await self.crash(host, 3)
        await self.gone(host)
        self.assertEqual(self.reasons(), ['process exited (3)'])
        self.assertEqual(await self.listed(), [])
        self.assertEqual(await self.session_status(sid), 404)
        _, notif = await self.lobby('bob')   # the next lobby gets the freed port
        self.assertEqual((notif['status'], notif['port']), ('BUSY', str(PORT)))

    async def test_crash_mid_match_removes_lobby_and_frees_port(self):
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        self.status(host, 2, game_map=ARENA, launched=True)
        await self.until(lambda: host.had_players, 'players seen')
        self.assertEqual(await self.session_status(sid), 200)   # not listed while its match runs, but kept
        await self.crash(host, 3)
        await self.gone(host)
        self.assertEqual(self.reasons(), ['process exited (3)'])
        self.assertEqual(await self.session_status(sid), 404)
        self.assertEqual(self.app['sessions'], {})
        self.assertEqual(self.hm.free_ports(), [PORT, PORT + 1])

    async def test_lobby_server_ending_itself_removes_lobby(self):
        # the owner left, or nobody locked in: the game quits the server with exit code 0 (docs/recon/backend-api.md)
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        await self.crash(host, 0)
        await self.gone(host)
        self.assertEqual(self.reasons(), ['process exited (0)'])
        self.assertEqual((await self.listed(), await self.session_status(sid)), ([], 404))

    async def test_lobby_everyone_left_disappears_after_lobby_grace(self):
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        self.status(host, 1)
        await self.until(lambda: host.had_players, 'players seen')
        self.status(host, 0)
        await self.until(lambda: host.empty_since is not None, 'empty seen')
        self.clock.advance(self.hm.lobby_grace + 1)
        await self.gone(host)
        self.assertEqual(self.reasons(), ['everyone left the lobby'])
        self.assertEqual((await self.listed(), await self.session_status(sid)), ([], 404))

    async def test_finished_match_is_ingested_once_then_its_lobby_dropped(self):
        token = await self.login('alice')
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        self.status(host, 1, game_map=ARENA, launched=True)
        await self.until(lambda: host.had_players, 'players seen')
        self.result(host.id, {'results': {'MatchResults': [{'RoundResults': [
            {'UserId': token['user_id'], 'Team': 'TeamA', 'Type': 'Berserker'}], 'TotalRoundTime': 300.0}],
            'TimePlayed': 600.0, 'MapLevel': 'LE_Arena'}, 'winning_team': 1, 'game_mode': 4, 'match_time': 600})
        def ingested():
            return [e for e in self.logs if 'match' in e and 'winner' in e]
        await self.until(ingested, 'match ingested')
        self.assertIsNotNone(host.match_over)
        self.assertEqual(await self.listed(), [])
        self.status(host, 0, game_map=ARENA, launched=True)
        await self.until(lambda: host.empty_since is not None, 'empty seen')
        self.clock.advance(11)
        await self.gone(host)
        self.assertEqual(self.reasons(), ['match finished'])
        self.assertEqual(len(ingested()), 1)
        self.assertEqual(len(self.app['store'].data['player_records'][token['user_id']]['PROFILE_HISTORY_KEY']
                             ['Matches']), 1)
        self.assertEqual(await self.session_status(sid), 404)

    async def test_solo_game_is_marked_and_stopped_when_its_owner_starts_another(self):
        # TRAINING and Solo lobbies ask for max_player 1; the player's next game replaces a still running solo one
        token = await self.login('alice')
        r = await self.client.post(f'/sessionbrowser/namespaces/{fb.NAMESPACE}/gamesession', headers=self.auth(token),
                                   json={'session_type': 'dedicated',
                                         'game_session_setting': {'mode': 'custom', 'max_player': 1}})
        sid = (await r.json())['session_id']
        ws = await self.client.ws_connect('/lobby', protocols=('wss',), headers=self.auth(token))
        self.addAsyncCleanup(ws.close)
        await ws.send_str(fb.lobby_frame(type='createDSRequest', id='1', matchId=sid))
        await self.frame(ws, 'dsNotif')
        host = self.app['sessions'][sid]['_host']
        self.assertTrue(host.solo)
        self.status(host, 1, game_map=ARENA, launched=True)
        await self.until(lambda: host.had_players, 'player seen')
        await self.client.post(f'/sessionbrowser/namespaces/{fb.NAMESPACE}/gamesession', headers=self.auth(token),
                               json={'session_type': 'dedicated', 'game_session_setting': {'mode': 'custom'}})
        await self.gone(host)
        self.assertEqual(self.reasons(), ['owner created a new lobby'])

    async def test_bigger_lobby_is_not_solo_and_its_match_survives_a_new_lobby(self):
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        self.assertFalse(host.solo)
        self.status(host, 2, game_map=ARENA, launched=True)
        await self.until(lambda: host.had_players, 'players seen')
        token = await self.login('alice')
        await self.client.post(f'/sessionbrowser/namespaces/{fb.NAMESPACE}/gamesession', headers=self.auth(token),
                               json={'session_type': 'dedicated', 'game_session_setting': {'mode': 'custom'}})
        await self.look(host, 2)
        self.assertTrue(self.hm.is_live(host))

    async def test_preset_saved_in_a_match_is_stored_and_exported(self):
        token = await self.login('alice')
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        self.status(host, 1, game_map=ARENA, launched=True)
        await self.until(lambda: host.had_players, 'player seen')
        uid = token['user_id']
        f = self.win64(host.id) / f'fangshost_loadout-{uid}-1.json'
        f.write_text('{"Lancer": {"CurrentLoadoutIndex": 2, "Loadout2": {"Name": "x", "Augments": []}}}')
        records = self.app['store'].data['player_records']
        await self.until(lambda: 'PROFILE_LOADOUT_KEY' in records.get(uid, {}), 'preset stored')
        self.assertEqual(records[uid]['PROFILE_LOADOUT_KEY']['Lancer']['CurrentLoadoutIndex'], 2)
        exported = self.tmp / 'records' / 'players' / uid / 'PROFILE_LOADOUT_KEY.json'
        self.assertEqual(json.loads(exported.read_text())['Lancer']['CurrentLoadoutIndex'], 2)   # FangsHost serves this

    async def test_preset_save_for_an_unknown_player_is_ignored(self):
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        self.status(host, 1)
        await self.until(lambda: host.had_players, 'player seen')
        (self.win64(host.id) / f'fangshost_loadout-{"d" * 32}-1.json').write_text('{}')
        await self.until(lambda: self.events('preset save for an unknown player'), 'refused')
        self.assertNotIn('d' * 32, self.app['store'].data['player_records'])

    async def test_failed_boot_tells_the_owner_and_frees_the_ports(self):
        self.mode('die')
        sid, notif = await self.lobby('alice')
        self.assertEqual((notif['status'], notif['message']), ('FAILED', 'game server failed to start'))
        self.assertEqual(len(self.events('starting')), 3)
        self.assertEqual((self.hm.hosts, self.hm._releasing, self.hm.free_ports()), ({}, set(), [PORT, PORT + 1]))
        # current behavior (a question for the review): the session stays, unlisted and not joinable, until its
        # owner creates another lobby
        self.assertEqual(await self.listed(), [])
        self.assertIn(sid, self.app['sessions'])

    async def test_stopped_server_drops_its_zeuz_lobby(self):
        # the Aug 2022 client's custom lobbies (/zeuz/sessions)
        token = await self.login('alice')
        r = await self.client.post('/zeuz/sessions', headers=self.auth(token),
                                   json={'session_config': 'max_players,6,lobby_name,test'})
        sid = (await r.json())['id']

        async def listing():
            return await (await self.client.get('/zeuz/sessions.txt', headers=self.auth(token))).text()
        self.assertTrue((await listing()).startswith(sid))
        host = self.app['zeuz'][sid]['host']
        await self.crash(host, 3)
        await self.gone(host)
        self.assertEqual((self.app['zeuz'], await listing()), ({}, ''))

    async def test_backend_shutdown_stops_every_server(self):
        sid, _ = await self.lobby('alice')
        host = self.app['sessions'][sid]['_host']
        await self.client.close()   # app cleanup: HostManager.shutdown()
        await self.local.close()
        self.assertEqual(self.reasons(), ['backend shutdown'])
        self.assertEqual(host.proc.returncode, -signal.SIGTERM)
        self.assertEqual(self.hm.hosts, {})


if __name__ == '__main__':
    unittest.main()
