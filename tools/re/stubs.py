#!/usr/bin/env python3
"""List UFUNCTIONs of a class whose native implementation is an empty stub (compiled out of this build,
e.g. bodies wrapped in #if UE_SERVER). Usage: stubs.py <exe> <UHT header .h>"""
import collections, os, re, struct, sys
sys.path.insert(0, os.path.dirname(__file__))
import capstone
from xref import Exe

x = Exe(sys.argv[1])
names = sorted(set(re.findall(r'UFUNCTION\([^)]*\)\s*\n\s*(?:static\s+)?[\w<>:,\s\*&]+?\b(\w+)\(', open(sys.argv[2]).read())))
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)

def calls_in(f):
    out = []
    for l in x.disasm(*f):
        m = re.search(r': call +0x([0-9a-f]+)', l)
        if m:
            out.append(int(m.group(1), 16))
    return out

cands = {}
for name in names:
    for m in re.finditer(re.escape(name.encode() + b'\0'), x.data):
        if x.data[m.start() - 1] != 0:
            continue
        sva = x.off2va(m.start())
        p = x.data.find(struct.pack('<Q', sva))
        while p != -1:
            fn = struct.unpack_from('<Q', x.data, p + 8)[0]
            f = x.func_of(fn)
            if f and f[0] == fn:
                cands.setdefault(name, []).append(calls_in(f))
            p = x.data.find(struct.pack('<Q', sva), p + 1)
freq = collections.Counter(t for lst in cands.values() for calls in lst for t in set(calls))
for name in names:
    best = None
    for calls in cands.get(name, []):
        uniq = [t for t in calls if freq[t] <= 2]
        if uniq:
            best = uniq[0]
    if best is None:
        print(f'  ?   {name}'); continue
    ins = list(md.disasm(x.data[x.va2off(best):x.va2off(best) + 16], best))
    stub = bool(ins) and ins[0].mnemonic == 'ret'
    print(f"{'STUB' if stub else '    '} {name:45} impl={best:x}")
