#!/usr/bin/env python3
"""Find the AES-256 pak key embedded in a UE4 game executable and verify it against the pak index.

UE 4.26 provides the key through a small callback that writes 32 bytes, usually as eight
`mov dword ptr [rcx+N], imm32` instructions. We collect those candidates and accept the one that
decrypts the pak index to a sane mount point. For your own copy of the game, for preservation and
interoperability. Usage: findkey.py <game.exe> <pak>   (needs pefile, and pycryptodome or cryptography)"""
import re, struct, sys

try:
    from Crypto.Cipher import AES

    def ecb_decrypt(key, data):
        return AES.new(key, AES.MODE_ECB).decrypt(data)
except ImportError:  # pycryptodome missing: use the 'cryptography' package
    from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

    def ecb_decrypt(key, data):
        d = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
        return d.update(data) + d.finalize()

FOOTER = 16 + 1 + 4 + 4 + 8 + 8 + 20 + 5 * 32


def candidates(exe):
    data = open(exe, 'rb').read()
    # mov dword ptr [rcx], imm32 ; mov dword ptr [rcx+4], imm32 ; ... [rcx+0x1c]
    rx = re.compile(rb'\xc7\x01(.{4})' + b''.join(rb'\xc7\x41' + bytes([o]) + rb'(.{4})' for o in range(4, 32, 4)), re.S)
    for m in rx.finditer(data):
        yield b''.join(m.groups())
    # fallback: same with other base registers [rdx]/[r8]... (C7 02 / C7 42 ..)
    for reg in (0x02, 0x00, 0x03, 0x06, 0x07):
        rx = re.compile(bytes([0xc7, reg]) + rb'(.{4})' + b''.join(bytes([0xc7, 0x40 | reg, o]) + rb'(.{4})' for o in range(4, 32, 4)), re.S)
        for m in rx.finditer(data):
            yield b''.join(m.groups())


def index_head(pak):
    with open(pak, 'rb') as f:
        f.seek(-FOOTER, 2)
        ft = f.read(FOOTER)
        ioff, isz = struct.unpack_from('<qq', ft, 16 + 1 + 4 + 4)
        f.seek(ioff)
        return f.read(64)


def plausible(block):
    n = struct.unpack_from('<i', block, 0)[0]
    return 0 < n < 256 and block[4:13] == b'../../../'


def data_windows(exe, step):
    """Every `step`-aligned 32-byte window in the exe's non-code sections (key stored as data)."""
    import pefile
    pe = pefile.PE(exe, fast_load=True)
    for sec in pe.sections:
        if sec.Characteristics & 0x20000000:   # executable
            continue
        raw = sec.get_data()
        for i in range(0, len(raw) - 32, step):
            yield raw[i:i + 32]


def main(exe, pak):
    head = index_head(pak)
    seen = set()
    import itertools
    for key in itertools.chain(candidates(exe), data_windows(exe, 4), data_windows(exe, 1)):
        if key in seen or key.count(0) > 8:   # real keys are high-entropy
            continue
        if len(seen) < 100000:
            seen.add(key)
        if plausible(ecb_decrypt(key, head[:32])):
            print('0x' + key.hex().upper())
            return 0
    print(f'no key found among {len(seen)} candidates', file=sys.stderr)
    return 1


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
