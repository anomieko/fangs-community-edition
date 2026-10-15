#!/usr/bin/env python3
"""Stands in for server/run-host.sh in the backend tests: fake_host.py <game dir> <instance dir> <port> [-FangsData=..].

Reports the lobby map as loaded and ready, the way FangsHost does (fangshost_status.json), then waits until it is
killed. The test steers it with files:
- <instances>/fake_host_mode (read at start): "ready" (default), "die" (exit 1 at once), "hang" (never ready);
- <instance>/fake_exit: the server exits with the code written in it (a crash: non-zero).
Status changes (players, map) and match results are files the test writes itself, as FangsHost would."""
import json
import sys
import time
from pathlib import Path

inst = Path(sys.argv[2])
win64 = inst / 'MOBA' / 'Binaries' / 'Win64'
win64.mkdir(parents=True, exist_ok=True)
mode_file = inst.parent / 'fake_host_mode'
mode = mode_file.read_text().strip() if mode_file.exists() else 'ready'
if mode == 'die':
    sys.exit(1)
if mode == 'ready':
    tmp = win64 / 'fangshost_status.json.tmp'
    tmp.write_text(json.dumps({'map': '/Game/Environment/Maps/LE_Lobby_Map', 'ready': True, 'players': 0,
                               'time': time.time()}))
    tmp.replace(win64 / 'fangshost_status.json')
while True:
    exit_file = inst / 'fake_exit'
    if exit_file.exists():
        sys.exit(int(exit_file.read_text().strip() or 1))
    time.sleep(0.1)
