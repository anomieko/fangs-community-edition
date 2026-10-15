#!/usr/bin/env python3
"""Minimal UE4 pak v11 (4.26) index reader. Usage: paklist.py <pak> <out.tsv> [aes-key-hex | @keyfile]
Encrypted indexes/files need the AES-256 key (tools/pak/findkey*.py); keys are never committed."""
import struct, sys


def load_key(arg):
    if not arg:
        return None
    if arg.startswith('@'):
        arg = open(arg[1:]).read().strip()
    return bytes.fromhex(arg[2:] if arg.lower().startswith('0x') else arg)


def decrypt(key, data):
    if key is None:
        return data
    data = data[:len(data) // 16 * 16]
    try:
        from Crypto.Cipher import AES
        return AES.new(key, AES.MODE_ECB).decrypt(data)
    except ImportError:  # pycryptodome missing: use the 'cryptography' package
        from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
        d = Cipher(algorithms.AES(key), modes.ECB()).decryptor()
        return d.update(data) + d.finalize()

FOOTER = 16 + 1 + 4 + 4 + 8 + 8 + 20 + 5 * 32


class R:
    def __init__(self, b):
        self.b, self.p = b, 0

    def u8(self):
        v = self.b[self.p]; self.p += 1; return v

    def i32(self):
        v = struct.unpack_from('<i', self.b, self.p)[0]; self.p += 4; return v

    def u32(self):
        v = struct.unpack_from('<I', self.b, self.p)[0]; self.p += 4; return v

    def i64(self):
        v = struct.unpack_from('<q', self.b, self.p)[0]; self.p += 8; return v

    def raw(self, n):
        v = self.b[self.p:self.p + n]; self.p += n; return v

    def fstr(self):
        n = self.i32()
        if n == 0:
            return ''
        if n > 0:
            return self.raw(n)[:-1].decode('latin-1')
        return self.raw(-n * 2)[:-2].decode('utf-16-le')


def decode_entry(b, off):
    r = R(b); r.p = off
    v = r.u32()
    bs = r.u32() if (v & 0x3f) == 0x3f else (v & 0x3f) << 11
    method = (v >> 23) & 0x3f
    offset = r.u32() if v & (1 << 31) else r.i64()
    usize = r.u32() if v & (1 << 30) else r.i64()
    size = (r.u32() if v & (1 << 29) else r.i64()) if method else usize
    enc = bool(v & (1 << 22))
    return offset, size, usize, method, enc


def main(pak, out, key=None):
    key = load_key(key)
    with open(pak, 'rb') as f:
        f.seek(-FOOTER, 2)
        ft = R(f.read(FOOTER))
        guid = ft.raw(16); enc_idx = ft.u8(); magic = ft.u32(); ver = ft.i32()
        ioff = ft.i64(); isz = ft.i64(); ft.raw(20)
        methods = [ft.raw(32).split(b'\0')[0].decode() for _ in range(5)]
        assert magic == 0x5A6F12E1, hex(magic)
        print(f'version={ver} encrypted_index={enc_idx} key_guid={guid.hex()} methods={methods}')
        if enc_idx and key is None:
            sys.exit('pak index is encrypted: pass the AES key')
        f.seek(ioff); r = R(decrypt(key if enc_idx else None, f.read(isz)))
        mount = r.fstr(); n = r.i32(); r.raw(8)
        if r.u32():
            r.raw(8 + 8 + 20)
        has_full = r.u32()
        assert has_full, 'no full directory index'
        fdi_off = r.i64(); fdi_sz = r.i64(); r.raw(20)
        enc_entries = r.raw(r.i32())
        print(f'mount={mount} entries={n}')
        f.seek(fdi_off); d = R(decrypt(key if enc_idx else None, f.read(fdi_sz)))

    totals = {'enc': 0, 'comp': 0}
    with open(out, 'w') as o:
        for _ in range(d.i32()):
            dname = d.fstr()
            for _ in range(d.i32()):
                fname = d.fstr(); eo = d.i32()
                if eo < 0:
                    o.write(f'{dname}{fname}\t?\t?\t?\t?\n'); continue
                offset, size, usize, method, enc = decode_entry(enc_entries, eo)
                totals['enc'] += enc; totals['comp'] += method != 0
                o.write(f'{mount}{dname}{fname}\t{usize}\t{size}\t{method}\t{int(enc)}\n')
    print(totals)


if __name__ == '__main__':
    main(*sys.argv[1:])
