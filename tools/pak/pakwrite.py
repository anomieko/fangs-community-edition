#!/usr/bin/env python3
"""Write an unencrypted, uncompressed UE4 pak v11 (4.26), laid out like UnrealPak's: data, path hash index and
full directory index. Used for our patch pak (docs/PATCHING.md).
Usage: pakwrite.py <out.pak> <root-dir>   packs every file under <root-dir> as ../../../<path relative to root>"""
import hashlib, os, struct, sys, zlib

MOUNT = '../../../'
VERSION = 11
MAGIC = 0x5A6F12E1


def fstr(s):
    b = s.encode('ascii') + b'\0'  # pak paths are ASCII here; UE writes non-ASCII as negative-length UTF-16
    return struct.pack('<i', len(b)) + b


def fnv64(data, seed):
    """FPakFile::HashPath for v11: FNV-64 over the lowercase UTF-16 path, seed added to the offset basis."""
    h = (0xcbf29ce484222325 + seed) & 0xFFFFFFFFFFFFFFFF
    for b in data:
        h = ((h ^ b) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return h


def entry_header(size, sha1):
    """FPakEntry as serialized before each file's data: offset 0, sizes, no compression, hash, flags, block size."""
    return struct.pack('<qqqI', 0, size, size, 0) + sha1 + struct.pack('<BI', 0, 0)


def encoded_entry(offset, size):
    """FPakFile::EncodePakEntry for an uncompressed, unencrypted entry below 4 GB."""
    return struct.pack('<III', (1 << 31) | (1 << 30) | (1 << 29), offset, size)


def directory_index(files):
    """TMap<dir, TMap<file, encoded entry offset>>, with every parent directory up to the mount point ('/')."""
    dirs = {'/': {}}
    for rel, loc in files:
        d, name = (rel.rsplit('/', 1)[0] + '/', rel.rsplit('/', 1)[1]) if '/' in rel else ('/', rel)
        dirs.setdefault(d, {})[name] = loc
        while d != '/':
            d = d[:-1].rsplit('/', 1)[0] + '/' if '/' in d[:-1] else '/'
            dirs.setdefault(d, {})
    out = struct.pack('<i', len(dirs))
    for d, entries in dirs.items():
        out += fstr(d) + struct.pack('<i', len(entries))
        for name, loc in entries.items():
            out += fstr(name) + struct.pack('<i', loc)
    return out


def write_pak(out_path, root):
    rels = sorted(os.path.relpath(os.path.join(dp, f), root).replace(os.sep, '/')
                  for dp, _, fs in os.walk(root) for f in fs)
    seed = zlib.crc32(os.path.basename(out_path).lower().encode())
    encoded, files = b'', []
    with open(out_path, 'wb') as out:
        for rel in rels:
            data = open(os.path.join(root, rel), 'rb').read()
            offset = out.tell()
            out.write(entry_header(len(data), hashlib.sha1(data).digest()))
            out.write(data)
            files.append((rel, len(encoded)))
            encoded += encoded_entry(offset, len(data))

        dir_index = directory_index(files)
        phi = struct.pack('<i', len(files)) + b''.join(
            struct.pack('<Qi', fnv64(rel.lower().encode('utf-16-le'), seed), loc) for rel, loc in files)
        phi += dir_index  # the "pruned" directory index: nothing pruned
        phi_off = out.tell(); out.write(phi)
        fdi_off = out.tell(); out.write(dir_index)

        index = (fstr(MOUNT) + struct.pack('<iQ', len(files), seed)
                 + struct.pack('<Iqq', 1, phi_off, len(phi)) + hashlib.sha1(phi).digest()
                 + struct.pack('<Iqq', 1, fdi_off, len(dir_index)) + hashlib.sha1(dir_index).digest()
                 + struct.pack('<i', len(encoded)) + encoded
                 + struct.pack('<i', 0))  # no entries that need the full FPakEntry form
        index_off = out.tell(); out.write(index)
        # FPakInfo: key GUID (none), index not encrypted, magic, version, index offset/size/hash, 5 compression names
        out.write(bytes(16) + struct.pack('<BIiqq', 0, MAGIC, VERSION, index_off, len(index))
                  + hashlib.sha1(index).digest() + bytes(5 * 32))
    return len(files)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    print(f'packed {write_pak(sys.argv[1], sys.argv[2])} files into {sys.argv[1]}')
