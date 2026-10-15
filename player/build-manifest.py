#!/usr/bin/env python3
"""Build manifest.json for the launcher (FangsCE.exe): every file of the game install plus our player files.

  build-manifest.py <game dir> <downloads dir> <build label>

<downloads>/overlay holds the player files (UE4SS + FangsBoot, FangsCE/Engine.ini; see server/deploy.sh);
they win over game files with the same path. If <downloads>/FangsCE.exe exists, its hash is listed so
launchers update themselves. SHA-256s are cached in <downloads>/.hashcache.json by (size, mtime).
The backend serves exactly the files listed here (/download/<join code>/files/<path>).

Files of CHUNK_MIN or more are also listed as CHUNK-sized pieces, each gzipped into <downloads>/chunks/<SHA-256 of
the unpacked piece>.gz (the backend serves /download/<join code>/chunks/<name>). The launcher fetches several pieces
at once and checks every piece against its SHA-256, so a big file arrives faster and roughly half as big (the game's
pak is not compressed). Launchers before this ignore the pieces and fetch the whole file. Pieces no file lists any
more are removed, so rsync --delete drops them on the server too.
"""
import gzip, hashlib, json, os, sys, threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SKIP_DIRS = {'MOBA/Saved'}          # per-user data, never shipped
EXES = ('MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe', 'MOBA/Binaries/Win64/MOBA.exe')
CHUNK = 32 << 20
CHUNK_MIN = 4 << 20


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = Path(dirpath).relative_to(root).as_posix()
        dirnames[:] = [d for d in dirnames if (f'{rel_dir}/{d}' if rel_dir != '.' else d) not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            yield p.relative_to(root).as_posix(), p


def chunk(path, offset, size, out_dir):
    """Hash one piece of a file and write its gzip next to the others (unless it is there already)."""
    with open(path, 'rb') as f:
        f.seek(offset)
        data = f.read(size)
    sha = hashlib.sha256(data).hexdigest()
    out = out_dir / f'{sha}.gz'
    if not out.exists():
        tmp = out.with_name(f'{sha}.{threading.get_ident()}.tmp')   # two equal pieces may be packed at once
        tmp.write_bytes(gzip.compress(data, compresslevel=6, mtime=0))
        tmp.replace(out)
    return {'sha256': sha, 'size': len(data), 'csize': out.stat().st_size}


def main(game, downloads, build):
    game, downloads = Path(game), Path(downloads)
    cache_path = downloads / '.hashcache.json'
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}
    chunk_dir = downloads / 'chunks'
    chunk_dir.mkdir(exist_ok=True)
    pool = ThreadPoolExecutor(min(8, os.cpu_count() or 1))   # zlib and hashlib release the GIL

    def stamp(path):
        st = path.stat()
        return str(path.resolve()), [st.st_size, st.st_mtime_ns]

    def sha(path):
        key, st = stamp(path)
        if cache.get(key, [None])[:2] == st:
            return cache[key][2]
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for block in iter(lambda: f.read(1 << 22), b''):
                h.update(block)
        cache[key] = st + [h.hexdigest()]
        return cache[key][2]

    def chunks(path, size):
        key, st = stamp(path)
        key = 'chunks:' + key
        hit = cache.get(key)
        if hit and hit[:2] == st and all((chunk_dir / f"{c['sha256']}.gz").exists() for c in hit[2]):
            return hit[2]
        found = list(pool.map(lambda off: chunk(path, off, min(CHUNK, size - off), chunk_dir), range(0, size, CHUNK)))
        cache[key] = st + [found]
        return found

    files = {}
    for root in (game, downloads / 'overlay'):          # overlay last: our player files win
        for rel, path in walk(root):
            if rel.endswith(('.part', '.tmp')):
                continue
            files[rel] = {'path': rel, 'size': path.stat().st_size, 'sha256': sha(path), 'src': path}
    exe = next((e for e in EXES if e in files), None)
    if not exe:
        sys.exit(f'no game exe found in {game}')
    for f in files.values():
        src = f.pop('src')
        if f['size'] >= CHUNK_MIN:
            f['chunks'] = chunks(src, f['size'])
    pool.shutdown()
    manifest = {'build': build, 'exe': exe, 'engine_ini': 'FangsCE/Engine.ini',
                'files': sorted(files.values(), key=lambda f: f['path'])}
    launcher = downloads / 'FangsCE.exe'
    if launcher.exists():
        manifest['launcher'] = {'path': 'FangsCE.exe', 'size': launcher.stat().st_size, 'sha256': sha(launcher)}
    listed = {f"{c['sha256']}.gz" for f in manifest['files'] for c in f.get('chunks', [])}
    for p in chunk_dir.iterdir():
        if p.name not in listed:
            p.unlink()
    cache_path.write_text(json.dumps(cache))
    tmp = downloads / 'manifest.json.tmp'
    tmp.write_text(json.dumps(manifest, indent=1))
    tmp.replace(downloads / 'manifest.json')
    total = sum(f['size'] for f in manifest['files'])
    download = sum(sum(c['csize'] for c in f['chunks']) if 'chunks' in f else f['size'] for f in manifest['files'])
    print(f"manifest: {len(manifest['files'])} files, {total / 2**30:.1f} GiB ({download / 2**30:.1f} GiB to download), "
          f"build {build}")


if __name__ == '__main__':
    main(*sys.argv[1:4])
