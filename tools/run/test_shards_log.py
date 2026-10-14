#!/usr/bin/env python3
"""Condense a test_shards.lua watch log (shardwatch.log) into one line per change: round, Shard state, health
shrine channels, hero hp/mana/speed and the gameplay effects added (+) or removed (-). Usage: test_shards_log.py <log>"""
import re, sys
prev = set()
for line in open(sys.argv[1]):
    m = re.match(r'(\S+)\s+([\d.]+) (.*)', line.rstrip('\n'))
    if not m: continue
    t, rest = m.group(2), m.group(3)
    ge = re.search(r'GEs \[(.*)\]', rest); ge = set(filter(None, ge.group(1).split(','))) if ge else set()
    st = re.search(r'A (\d+) B (\d+) taken (\w+) atShrine (\w+) dropped (\w+) carrier (\S+)', rest)
    sh = re.search(r'shard (\S*) ([-\d,]+) buff (\d) channeled (\w+)', rest)
    hs = re.search(r'channeled: ([^)]*)\)', rest)
    hp = re.search(r'hp (\d+)/\d+ mana (\d+)/\d+ speed (\d+)', rest)
    rd = re.search(r'rounds (\S+)', rest)
    ab = re.search(r'aspect boost A (\d+) B (\d+)', rest)
    pr = re.search(r'prismatic dead (\w+)', rest)
    ia = re.search(r'holding (\w+) count (\S+) specs \[([^\]]*)\]', rest)
    add, rem = sorted(ge - prev), sorted(prev - ge); prev = ge
    print((f"{t:>6} r{rd.group(1) if rd else '?'} " + (f"A{st.group(1)} B{st.group(2)} taken={st.group(3)[0]} shrine={st.group(4)[0]} drop={st.group(5)[0]} " if st else rest[:60] + ' ')
          + (f"shard={sh.group(1) or '-'} b{sh.group(3)} ch={sh.group(4)[0]} " if sh else '') + (f"hs[{hs.group(1)}] " if hs and hs.group(1) else '')
          + (f"aspect+{ab.group(1)}/{ab.group(2)} " if ab and ab.group(1) + ab.group(2) != '00' else '') + (f"prismatic-dead={pr.group(1)[0]} " if pr else '') + (f"hold={ia.group(1)[0]}/{ia.group(2)} specs[{ia.group(3)}] " if ia else '')
          + (f"hp{hp.group(1)} mp{hp.group(2)} sp{hp.group(3)} " if hp else '') + (f"+{add} " if add else '') + (f"-{rem}" if rem else '')).replace('BP_GE_', '').replace('BP_GA_', ''))
