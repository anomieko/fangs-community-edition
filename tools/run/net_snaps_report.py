#!/usr/bin/env python3
"""Summary of tools/run/net_snaps.lua's logs (rubber-banding on the test clients).

Usage: net_snaps_report.py <dir with client*.snaps.log> [skip seconds]
Per client and in total: client frames per second; the own hero's position snaps per minute (error over 20, 50, 100
units in one frame: corrections from the server); other heroes' visible jumps per minute (over 80 units); teleports
(respawns, blinks) apart.
"""
import sys
from pathlib import Path


def load(path):
    rows = []
    for line in open(path):
        p = line.split()
        if len(p) == 10 and p[0] == 'S':
            rows.append([float(x) for x in p[1:]])
    return rows


def main():
    d = Path(sys.argv[1])
    skip = float(sys.argv[2]) if len(sys.argv) > 2 else 0.0
    tot = [0.0] * 9
    secs_all = 0
    for path in sorted(d.glob('client*.snaps.log')):
        rows = load(path)
        if not rows:
            print(f'   {path.name}: no data')
            continue
        t0 = rows[0][0]
        rows = [r for r in rows if r[0] - t0 >= skip]
        n = len(rows)
        if n == 0:
            continue
        s = [sum(r[i] for r in rows) for i in range(9)]
        mins = n / 60
        worst = max(r[8] for r in rows)
        print(f'   {path.name}: {n} s, {s[1] / n:.0f} fps; own snaps/min >20 {s[2] / mins:.1f}, >50 {s[3] / mins:.1f}, '
              f'>100 {s[4] / mins:.1f} (largest {worst:.0f}); teleports {s[5]:.0f}; '
              f'others\' jumps/min >80 {s[6] / mins:.1f}, teleports {s[7]:.0f}')
        tot = [a + b for a, b in zip(tot, s)]
        secs_all += n
    if secs_all:
        mins = secs_all / 60
        print(f'   all clients: own snaps/min >20 {tot[2] / mins:.1f}, >50 {tot[3] / mins:.1f}, >100 {tot[4] / mins:.1f}; '
              f'others\' jumps/min >80 {tot[6] / mins:.1f}; {tot[1] / secs_all:.0f} fps')


if __name__ == '__main__':
    main()
