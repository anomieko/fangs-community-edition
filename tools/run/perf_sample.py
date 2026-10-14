#!/usr/bin/env python3
"""CPU sampler and report for FANGS game servers (tools/run/test_perf.sh).

  perf_sample.py sample <out-dir> <hosts-dir> <seconds>
      Every ~2 ms: the game thread's CPU time, run-queue wait, state and current syscall, and its wineserver's CPU
      time; every 50 ms every thread of the server. Reads /proc only (the syscall only with ptrace rights, e.g.
      from inside the test's user namespace). One <out-dir>/<host>.fast.csv / .slow.jsonl per game server.
  perf_sample.py remote <seconds>      (on the server itself, via ssh: read-only /proc counters, JSON lines on stdout)
  perf_sample.py net <out-dir> <seconds>
      Game traffic on the loopback (run inside the test's network namespace): every packet's time, ports, size.
  perf_sample.py report <out-dir> <hosts-dir> [from-seconds [to-seconds]]  (seconds after the frame log started)
      Joins that with the servers' perf_frames.log (tools/run/perf_frames.lua): fps and frame-time distribution,
      CPU per server and thread group, and for every slow frame (> 50 ms) what the game thread did meanwhile.
"""
import json, os, re, statistics, sys, time
from collections import Counter, defaultdict
from pathlib import Path

SYSCALLS = {0: 'read', 1: 'write', 3: 'close', 4: 'stat', 7: 'poll', 16: 'ioctl', 17: 'pread64', 18: 'pwrite64', 19: 'readv', 20: 'writev', 23: 'select', 24: 'sched_yield', 35: 'nanosleep',
            45: 'recvfrom', 47: 'recvmsg', 202: 'futex', 230: 'clock_nanosleep', 232: 'epoll_wait', 270: 'pselect6',
            257: 'openat', 262: 'newfstatat', 271: 'ppoll', 281: 'epoll_pwait', 449: 'futex_waitv', -1: 'blocked?'}


def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def group(name):
    """Thread name -> group for the report."""
    for prefix, g in (('GameThread', 'game'), ('RenderThread', 'render'), ('RHIThread', 'render'), ('TaskGraphThread', 'taskgraph'),
                      ('Foreground Worker', 'taskgraph'), ('Background Worker', 'taskgraph'), ('PoolThread', 'pool'),
                      ('AsyncLoading', 'loading'), ('IOThread', 'io'), ('Physics', 'physics'), ('Chaos', 'physics'),
                      ('PhysX', 'physics'), ('ue4ss', 'ue4ss'), ('Audio', 'audio')):
        if name.startswith(prefix):
            return g
    return 'other'


class Server:
    def __init__(self, pid, host, out):
        self.pid, self.host = pid, host
        env = (read(f'/proc/{pid}/environ') or '').split('\0')
        prefix = next((e[11:] for e in env if e.startswith('WINEPREFIX=')), None)
        self.gt = next((t for t in os.listdir(f'/proc/{pid}/task') if (read(f'/proc/{pid}/task/{t}/comm') or '').strip() == 'GameThread'), str(pid))
        self.ws = None
        for p in filter(str.isdigit, os.listdir('/proc')):
            if (read(f'/proc/{p}/comm') or '').strip() == 'wineserver':
                penv = (read(f'/proc/{p}/environ') or '').split('\0')
                if prefix and f'WINEPREFIX={prefix}' in penv:
                    self.ws = p
        self.fds = {}
        self.gt_sched = self._open(f'/proc/{pid}/task/{self.gt}/schedstat')
        self.gt_stat = self._open(f'/proc/{pid}/task/{self.gt}/stat')
        self.gt_sys = self._open(f'/proc/{pid}/task/{self.gt}/syscall')
        self.ws_sched = self._open(f'/proc/{self.ws}/schedstat') if self.ws else None
        self.fast = open(out / f'{host}.fast.csv', 'a')
        self.slow = open(out / f'{host}.slow.jsonl', 'a')
        self.names, self.threads, self.last = {}, {}, {}
        self.slow.write(json.dumps({'start': time.time(), 'pid': pid, 'gt': self.gt, 'wineserver': self.ws}) + '\n')
        self.refresh_threads()

    @staticmethod
    def _open(path):
        try:
            fd = os.open(path, os.O_RDONLY)
            os.pread(fd, 512, 0)
            return fd
        except OSError:
            return None

    def refresh_threads(self):
        try:
            tids = os.listdir(f'/proc/{self.pid}/task')
        except OSError:
            return False
        for t in tids:
            name = (read(f'/proc/{self.pid}/task/{t}/comm') or '?').strip()
            if self.names.get(t) != name:
                self.names[t] = name
                self.slow.write(json.dumps({'t': time.time(), 'name': t, 'is': name}) + '\n')
            if t not in self.threads:
                fd = self._open(f'/proc/{self.pid}/task/{t}/schedstat')
                if fd is not None:
                    self.threads[t] = fd
        for t in list(self.threads):
            if t not in tids:
                os.close(self.threads.pop(t))
        return True

    def sample_fast(self, now):
        try:
            gt = os.pread(self.gt_sched, 128, 0).split()
            st = os.pread(self.gt_stat, 512, 0)
        except OSError:
            return False
        state = st[st.rfind(b')') + 2:st.rfind(b')') + 3].decode()
        sc = ''
        if self.gt_sys is not None and state != 'R':
            try:
                sc = os.pread(self.gt_sys, 64, 0).split(b' ', 1)[0].decode()
            except OSError:
                sc = ''
        ws = os.pread(self.ws_sched, 128, 0).split()[0].decode() if self.ws_sched is not None else '0'
        self.fast.write(f'{now:.4f},{gt[0].decode()},{gt[1].decode()},{state},{sc},{ws}\n')
        return True

    def ctx(self):
        """Voluntary context switches of the game thread and of its wineserver (each blocking Wine call is one)."""
        out = []
        for path in (f'/proc/{self.pid}/task/{self.gt}/status', f'/proc/{self.ws}/status' if self.ws else None):
            v = read(path) if path else None
            m = re.search(r'^voluntary_ctxt_switches:\s+(\d+)', v or '', re.M)
            out.append(int(m.group(1)) if m else 0)
        return out

    def sample_slow(self, now):
        cur, d = {}, {}
        for t, fd in self.threads.items():
            try:
                cur[t] = int(os.pread(fd, 128, 0).split()[0])
            except (OSError, IndexError, ValueError):
                continue
            delta = cur[t] - self.last.get(t, cur[t])
            if delta:
                d[t] = delta // 1000
        self.last = cur
        self.slow.write(json.dumps({'t': round(now, 4), 'd': d, 'ctx': self.ctx()}) + '\n')


def find_servers(hosts_dir):
    found = {}
    for p in filter(str.isdigit, os.listdir('/proc')):
        cmd = read(f'/proc/{p}/cmdline') or ''
        # the game process itself (argv[0] is the exe under Wine), not xvfb-run/taskset/bash around it
        if '-FangsHost' not in cmd or not cmd.split('\0', 1)[0].endswith(('MOBA-Win64-Shipping.exe', 'MOBA.exe')):
            continue
        try:
            cwd = os.readlink(f'/proc/{p}/cwd')
        except OSError:
            continue
        if cwd.startswith(hosts_dir):
            m = re.search(r'-port=(\d+)', cmd)
            found[p] = f'host-{m.group(1)}' if m else f'pid-{p}'
    return found


def sample(out, hosts_dir, secs):
    out.mkdir(parents=True, exist_ok=True)
    hosts_dir = os.path.realpath(hosts_dir)
    end = time.time() + secs
    servers, next_scan, next_slow = {}, 0, 0
    while time.time() < end:
        now = time.time()
        if now >= next_scan:
            next_scan = now + 1.0
            for pid, host in find_servers(hosts_dir).items():
                if pid not in servers:
                    try:
                        servers[pid] = Server(pid, host, out)
                    except (OSError, FileNotFoundError):
                        pass
            for pid, s in list(servers.items()):
                if not s.refresh_threads():
                    del servers[pid]
        for pid, s in list(servers.items()):
            if not s.sample_fast(now):
                del servers[pid]
        if now >= next_slow:
            next_slow = now + 0.05
            for s in servers.values():
                s.sample_slow(now)
        time.sleep(0.002)
    for s in servers.values():
        s.fast.close(); s.slow.close()


def net(out, secs, ports=range(7777, 7787)):
    """UDP on the loopback of the test's network namespace (run it inside, e.g. with nsenter): one line per game
    packet, <out>/net.csv: time, source port, destination port, payload bytes."""
    import socket, struct
    out.mkdir(parents=True, exist_ok=True)
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0003))
    s.bind(('lo', 0))
    s.settimeout(0.5)
    ports = set(ports)
    end = time.time() + secs
    with open(out / 'net.csv', 'a') as f:
        while time.time() < end:
            try:
                pkt, addr = s.recvfrom(65535)
            except socket.timeout:
                continue
            if addr[2] == socket.PACKET_OUTGOING or len(pkt) < 42 or pkt[12:14] != b'\x08\x00' or pkt[23] != 17:
                continue
            ihl = (pkt[14] & 15) * 4
            sport, dport, ulen = struct.unpack('!HHH', pkt[14 + ihl:14 + ihl + 6])
            if sport in ports or dport in ports:
                f.write(f'{time.time():.4f},{sport},{dport},{ulen - 8}\n')


def net_report(out, a=None, b=None):
    path = out / 'net.csv'
    if not path.exists():
        return
    flows = defaultdict(list)
    for line in open(path):
        t, sp, dp, n = line.split(',')
        t = float(t)
        if (a is None or t >= a) and (b is None or t <= b):
            flows[(int(sp), int(dp))].append((t, int(n)))
    for (sp, dp), pk in sorted(flows.items()):
        if sp < 7777 or sp > 7786 or len(pk) < 50:
            continue                                   # server -> client only
        span = pk[-1][0] - pk[0][0]
        gaps = [(y[0] - x[0]) * 1000 for x, y in zip(pk, pk[1:])]
        print(f'   net {sp}->{dp}: {len(pk) / span:.1f} packets/s, {sum(n for _, n in pk) / span / 1000:.1f} kB/s; gaps between packets: '
              f'median {statistics.median(gaps):.0f} ms, p99 {pct(gaps, 99):.0f}, longest {max(gaps):.0f}; >50 ms {sum(g > 50 for g in gaps)}, '
              f'>100 ms {sum(g > 100 for g in gaps)}, >200 ms {sum(g > 200 for g in gaps)}')


def remote(secs):
    """Run ON the server (ssh host python3 - remote <secs> < perf_sample.py): reads only /proc (comm, stat, schedstat
    of the game processes and wineservers, /proc/stat). Every second one JSON line on stdout: per game process its CPU
    (% of a core), its game thread's CPU, run-queue wait and share of 5 ms samples it was running; wineservers' CPU;
    the machine's user/system/steal/idle shares."""
    def procs(comm):
        return [p for p in filter(str.isdigit, os.listdir('/proc')) if (read(f'/proc/{p}/comm') or '').strip() == comm]

    def cpu_of(pid):
        tot = 0
        try:
            for t in os.listdir(f'/proc/{pid}/task'):
                v = read(f'/proc/{pid}/task/{t}/schedstat')
                if v:
                    tot += int(v.split()[0])
        except OSError:
            pass
        return tot

    def machine():
        v = [int(x) for x in read('/proc/stat').split('\n', 1)[0].split()[1:]]
        return {'user': v[0] + v[1], 'system': v[2] + v[5] + v[6], 'idle': v[3] + v[4], 'steal': v[7]}

    end, last, lastm, running = time.time() + secs, {}, machine(), defaultdict(lambda: [0, 0])
    nxt = time.time() + 1
    while time.time() < end:
        games = procs('GameThread')
        for g in games:                                   # 5 ms state samples of each game thread
            st = read(f'/proc/{g}/stat') or ''
            state = st[st.rfind(')') + 2:st.rfind(')') + 3]
            running[g][0] += state == 'R'; running[g][1] += 1
        if time.time() >= nxt:
            nxt += 1
            now = {}
            for g in games:
                gt = (read(f'/proc/{g}/schedstat') or '0 0 0').split()
                now[g] = (cpu_of(g), int(gt[0]), int(gt[1]))
            ws = {w: cpu_of(w) for w in procs('wineserver')}
            m = machine()
            dm = {k: m[k] - lastm[k] for k in m}; tot = max(1, sum(dm.values()))
            line = {'t': round(time.time(), 2), 'machine': {k: round(v / tot * 100, 1) for k, v in dm.items()}, 'games': {}, 'wineservers': {}}
            for g, (c, r, w) in now.items():
                if g in last:
                    c0, r0, w0 = last[g]
                    n = running[g]
                    line['games'][g] = {'cpu': round((c - c0) / 1e7, 1), 'gt': round((r - r0) / 1e7, 1), 'gt_wait': round((w - w0) / 1e7, 1),
                                        'gt_running': round(n[0] / max(1, n[1]) * 100)}
            for w, c in ws.items():
                if ('ws', w) in last:
                    line['wineservers'][w] = round((c - last[('ws', w)]) / 1e7, 1)
            last = {**now, **{('ws', w): c for w, c in ws.items()}}
            lastm, running = m, defaultdict(lambda: [0, 0])
            print(json.dumps(line), flush=True)
        time.sleep(0.005)


# ------------------------------------------------------------------------------------------------- report
def pct(xs, p):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(p / 100 * len(xs)))] if xs else 0


def load_frames(path):
    secs, frames = [], []
    for line in open(path, errors='replace'):
        p = line.split()
        if p and p[0] == 'S' and len(p) >= 12:
            secs.append({'clock': float(p[1]), 'time': int(p[2]), 'frames': int(p[3]), 'fps': float(p[4]), 'max_frame': float(p[5]),
                         'max_gap': float(p[6]), 'n33': int(p[7]), 'n50': int(p[8]), 'n100': int(p[9]), 'n200': int(p[10]), 'runs': int(p[11])})
        elif p and p[0] == 'F' and len(p) >= 5:
            frames.append({'clock': float(p[1]), 'ms': float(p[2]), 'gap': float(p[3]), 'frame': int(p[4])})
    return secs, frames


def report(out, hosts_dir, skip=0.0, length=None):
    for log in sorted(Path(hosts_dir).glob('host-*/MOBA/Binaries/Win64/perf_frames.log')):
        host = log.parts[-5]
        secs, frames = load_frames(log)
        if not secs:
            continue
        # os.clock() -> Unix time: os.time() is the floor of the true time, so max(time - clock) converges on the offset
        off = max(s['time'] - s['clock'] for s in secs)
        fast = []
        fpath = out / f'{host}.fast.csv'
        if fpath.exists():
            for line in open(fpath):
                p = line.rstrip('\n').split(',')
                if len(p) == 6:
                    fast.append((float(p[0]), int(p[1]), int(p[2]), p[3], p[4], int(p[5])))
        names, slow, ctxs = {}, [], []
        spath = out / f'{host}.slow.jsonl'
        if spath.exists():
            for line in open(spath):
                d = json.loads(line)
                if 'name' in d:
                    names[d['name']] = d['is']
                elif 'd' in d:
                    slow.append((d['t'], d['d']))
                    if 'ctx' in d:
                        ctxs.append((d['t'], d['ctx']))
        # only the match: seconds with a high frame cap (the arena) - S lines carry fps; use the window given by skip
        t0 = secs[0]['clock'] + skip
        t1 = secs[0]['clock'] + length if length else float('inf')     # the measured window (later: probes)
        win = [s for s in secs if t0 <= s['clock'] <= t1]
        fr = [f for f in frames if t0 <= f['clock'] <= t1]
        print(f'== {host}: {len(win)} s measured (from {time.strftime("%H:%M:%S", time.localtime(win[0]["clock"] + off)) if win else "-"})')
        if not win:
            continue
        fps = [s['fps'] for s in win]
        idle = statistics.median(fps) < 20      # an empty server (15 fps cap): every frame is 66 ms by design
        print(f'   fps: median {statistics.median(fps):.1f}, p5 {pct(fps, 5):.1f}, min {min(fps):.1f}' + (' (idle server: frame stats skipped)' if idle else ''))
        if idle:
            fr = []
        n = sum(s['frames'] for s in win)
        c = {k: sum(s[k] for s in win) for k in ('n33', 'n50', 'n100', 'n200')}
        if not idle: print(f'   frames: {n}; >33 ms {c["n33"]}, >50 ms {c["n50"]}, >100 ms {c["n100"]}, >200 ms {c["n200"]} '
              f'({c["n50"] / max(1, len(win)) * 60:.1f} frames >50 ms per minute); longest {max(s["max_frame"] for s in win):.0f} ms')
        mf = [s['max_frame'] for s in win]
        if not idle: print(f'   longest frame per second: median {statistics.median(mf):.0f} ms, p90 {pct(mf, 90):.0f}, p99 {pct(mf, 99):.0f}')
        # CPU per server and thread group over the window
        a, b = win[0]['clock'] + off, win[-1]['clock'] + off
        span = max(1e-6, b - a)
        groups, threads = defaultdict(int), defaultdict(int)
        ts = [t for t, _ in slow if a <= t <= b]
        span = max(1e-6, ts[-1] - ts[0]) if len(ts) > 1 else span     # what the sampler covered
        for t, d in slow:
            if a < t <= b:
                for tid, us in d.items():
                    groups[group(names.get(tid, '?'))] += us
                    threads[f'{names.get(tid, "?")}/{tid}'] += us
        total = sum(groups.values())
        fw = [x for x in fast if a <= x[0] <= b]
        fspan = max(1e-6, fw[-1][0] - fw[0][0]) if len(fw) > 1 else 1
        ws = (fw[-1][5] - fw[0][5]) / 1e9 / fspan * 100 if len(fw) > 1 else 0
        gtrun = (fw[-1][1] - fw[0][1]) / 1e9 / fspan * 100 if len(fw) > 1 else 0
        gtwait = (fw[-1][2] - fw[0][2]) / 1e9 / fspan * 100 if len(fw) > 1 else 0
        print(f'   CPU: server {total / 1e6 / span * 100:.0f}% of a core (game thread {gtrun:.0f}%, waiting for a CPU {gtwait:.1f}%), '
              f'wineserver {ws:.0f}%; by group: ' + ', '.join(f'{g} {us / 1e6 / span * 100:.0f}%' for g, us in sorted(groups.items(), key=lambda x: -x[1])))
        cw = [c for c in ctxs if a <= c[0] <= b]
        if len(cw) > 1:
            dt = cw[-1][0] - cw[0][0]
            gt_cs = (cw[-1][1][0] - cw[0][1][0]) / dt
            fps_avg = sum(s['frames'] for s in win) / max(1e-6, win[-1]['clock'] - win[0]['clock'])
            print(f'   blocking calls: game thread {gt_cs:.0f} context switches/s ({gt_cs / max(1, fps_avg):.0f} per frame), '
                  f'wineserver {(cw[-1][1][1] - cw[0][1][1]) / dt:.0f}/s')
        print('   busiest threads: ' + ', '.join(f'{k} {us / 1e6 / span * 100:.1f}%' for k, us in sorted(threads.items(), key=lambda x: -x[1])[:8]))
        if not idle:
            net_report(out, a, b)
        # slow frames: what the game thread did
        if fr and fw:
            rows = []
            for f in fr:
                if f['ms'] < 50:
                    continue
                e = f['clock'] + off; s0 = e - f['ms'] / 1000
                xs = [x for x in fw if s0 <= x[0] <= e]
                if len(xs) < 2:
                    continue
                run = (xs[-1][1] - xs[0][1]) / 1e6; wait = (xs[-1][2] - xs[0][2]) / 1e6; wsr = (xs[-1][5] - xs[0][5]) / 1e6
                blocked = Counter(SYSCALLS.get(int(x[4]), x[4]) if x[4].lstrip('-').isdigit() else (x[4] or x[3]) for x in xs if x[3] != 'R')
                top = defaultdict(int)
                for t, d in slow:
                    if s0 <= t <= e + 0.05:
                        for tid, us in d.items():
                            top[names.get(tid, tid)] += us
                busiest = ', '.join(f'{k} {v / 1000:.0f}' for k, v in sorted(top.items(), key=lambda kv: -kv[1])[:4])
                rows.append((f, run, wait, wsr, blocked, busiest, len(xs)))
            if rows:
                print(f'   slow frames (>50 ms): game thread running / waiting for a CPU / wineserver running (ms), where it blocked (samples), busiest threads (ms):')
                for f, run, wait, wsr, blocked, busiest, k in rows[:40]:
                    ts = time.strftime('%H:%M:%S', time.localtime(f['clock'] + off))
                    print(f'     {ts} {f["ms"]:4.0f} ms (gap {f["gap"]:3.0f}): run {run:4.0f} wait {wait:3.0f} ws {wsr:4.0f} | '
                          + ' '.join(f'{k}:{v}' for k, v in blocked.most_common(3)) + f' | {busiest}')
                if len(rows) > 40:
                    print(f'     ... {len(rows) - 40} more')
                tot = len(rows)
                cpu_bound = sum(1 for r in rows if r[1] > 0.7 * r[0]['ms'])
                starved = sum(1 for r in rows if r[2] > 0.3 * r[0]['ms'])
                print(f'   of {tot} slow frames: {cpu_bound} game thread busy >70% of the frame, {starved} waited for a CPU >30%')
            ints = [b2['clock'] - b1['clock'] for b1, b2 in zip([f for f in fr if f['ms'] >= 100], [f for f in fr if f['ms'] >= 100][1:])]
            if ints:
                print(f'   time between frames >100 ms: median {statistics.median(ints):.1f} s (min {min(ints):.1f}, max {max(ints):.1f})')


if __name__ == '__main__':
    if sys.argv[1] == 'sample':
        sample(Path(sys.argv[2]), sys.argv[3], float(sys.argv[4]))
    elif sys.argv[1] == 'remote':
        remote(float(sys.argv[2]))
    elif sys.argv[1] == 'net':
        net(Path(sys.argv[2]), float(sys.argv[3]))
    else:
        report(Path(sys.argv[2]), sys.argv[3], float(sys.argv[4]) if len(sys.argv) > 4 else 0.0,
               float(sys.argv[5]) if len(sys.argv) > 5 else None)
