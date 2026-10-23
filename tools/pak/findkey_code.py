#!/usr/bin/env python3
"""Second-stage AES key search: rebuild 32-byte keys from runs of immediate operands in code
(mov r64, imm64 / mov [mem], imm32 / mov [mem], r64 after imm64 loads) and test them against the
pak index. Usage: findkey_code.py <exe> <pak>"""
import itertools, re, struct, sys
import pefile
sys.path.insert(0, __import__('os').path.dirname(__file__))
from findkey import ecb_decrypt, index_head, plausible

exe, pak = sys.argv[1], sys.argv[2]
head = index_head(pak)[:16]
pe = pefile.PE(exe, fast_load=True)
text = next(s for s in pe.sections if s.Name.startswith(b'.text')).get_data()

imm64 = [(m.start(), m.group(1)) for m in re.finditer(rb'[\x48\x49][\xb8-\xbf](.{8})', text, re.S)]
# mov dword [reg+disp8], imm32  (C7 4x/44 24 disp8) and [reg+disp32]
imm32 = [(m.start(), m.group(2)) for m in re.finditer(rb'\xc7(?:[\x40-\x47]|\x44\x24)(.)(.{4})', text, re.S)]
imm32 += [(m.start(), m.group(2)) for m in re.finditer(rb'\xc7(?:[\x80-\x87]|\x84\x24)(.{4})(.{4})', text, re.S)]
imm32.sort()

tested = 0
def test(key):
    global tested
    tested += 1
    if plausible(ecb_decrypt(key, head + b'\0' * 16)[:32]) or \
       plausible(ecb_decrypt(key, head)[:16] + b'\0' * 16):
        print('0x' + key.hex().upper()); sys.exit(0)

def groups(items, n, span):
    for i in range(len(items) - n + 1):
        win = items[i:i + n]
        if win[-1][0] - win[0][0] <= span:
            yield [v for _, v in win]

for vals in groups(imm64, 4, 120):
    for perm in ([0, 1, 2, 3], [3, 2, 1, 0]):
        test(b''.join(vals[k] for k in perm))
for vals in groups(imm32, 8, 160):
    test(b''.join(vals))
print(f'no key found ({tested} candidates; {len(imm64)} imm64, {len(imm32)} imm32)', file=sys.stderr)
sys.exit(1)
