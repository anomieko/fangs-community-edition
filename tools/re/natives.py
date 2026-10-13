#!/usr/bin/env python3
"""Find the native exec thunk for a UFUNCTION name via UHT's FNameNativePtrPair tables.
Usage: natives.py <exe> <FunctionName>   -> prints thunk VA (and calls inside it)"""
import struct, sys
sys.path.insert(0, __import__('os').path.dirname(__file__))
from xref import Exe

x = Exe(sys.argv[1])
name = sys.argv[2].encode() + b'\0'
start = 0
while (off := x.data.find(name, start)) != -1:
    start = off + 1
    if x.data[off - 1] != 0:
        continue
    sva = x.off2va(off)
    p = x.data.find(struct.pack('<Q', sva))
    while p != -1:
        fn = struct.unpack_from('<Q', x.data, p + 8)[0]
        f = x.func_of(fn)
        if f and f[0] == fn:
            print(f'{sys.argv[2]}: exec thunk {fn:x}')
            for l in x.disasm(*f):
                if ' call ' in l or 'jmp ' in l:
                    print('   ', l)
        p = x.data.find(struct.pack('<Q', sva), p + 1)
