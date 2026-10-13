#!/usr/bin/env python3
"""Extract files from an uncompressed UE4 pak v11 (optionally AES-encrypted).
Usage: pakextract.py <pak> <outdir> <regex | @listfile> [aes-key-hex | @keyfile]
  @listfile: text file with one exact pak path per line (e.g. MOBA/Content/Foo.uexp)."""
import os, re, struct, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from paklist import FOOTER, R, decode_entry, decrypt, load_key  # noqa: E402

ENTRY_HEADER = 8 + 8 + 8 + 4 + 20 + 1 + 4  # serialized FPakEntry before data (uncompressed)


def entries(pak, key=None):
    with open(pak, 'rb') as f:
        f.seek(-FOOTER, 2)
        ft = R(f.read(FOOTER)); ft.raw(16); enc_idx = ft.u8(); ft.raw(4 + 4)
        ioff = ft.i64(); isz = ft.i64()
        f.seek(ioff); r = R(decrypt(key if enc_idx else None, f.read(isz)))
        mount = r.fstr(); r.i32(); r.raw(8)
        if r.u32():
            r.raw(36)
        r.u32(); fdi_off = r.i64(); fdi_sz = r.i64(); r.raw(20)
        enc = r.raw(r.i32())
        f.seek(fdi_off); d = R(decrypt(key if enc_idx else None, f.read(fdi_sz)))
    for _ in range(d.i32()):
        dname = d.fstr()
        for _ in range(d.i32()):
            fname = d.fstr(); eo = d.i32()
            if eo >= 0:
                yield (mount + dname + fname).replace('../../../', ''), decode_entry(enc, eo)


def main(pak, outdir, pattern, key=None):
    key = load_key(key)
    if pattern.startswith('@'):
        with open(pattern[1:]) as fh:
            wanted = {line.strip() for line in fh if line.strip()}
        match = wanted.__contains__
    else:
        match = re.compile(pattern).search
    n = 0
    with open(pak, 'rb') as f:
        for path, (offset, size, usize, method, encd) in entries(pak, key):
            if not match(path):
                continue
            assert method == 0, path
            dst = os.path.join(outdir, path)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            f.seek(offset + ENTRY_HEADER)
            if encd:
                data = decrypt(key, f.read((size + 15) // 16 * 16))[:usize]
            else:
                data = f.read(usize)
            with open(dst, 'wb') as o:
                o.write(data)
            n += 1
    print(f'extracted {n} files')


if __name__ == '__main__':
    main(*sys.argv[1:])
