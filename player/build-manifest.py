#!/usr/bin/env python3
"""Build manifest.json for the launcher (FangsCE.exe): every file of the game install plus our player files.

  build-manifest.py <game dir> <downloads dir> <build label>

<downloads>/overlay holds the player files (UE4SS + FangsBoot, FangsCE/Engine.ini; see build-client.sh);
they win over game files with the same path. If <downloads>/FangsCE.exe exists, its hash is listed so
launchers update themselves. SHA-256s are cached in <downloads>/.hashcache.json by (size, mtime).
The backend serves exactly the files listed here (/download/<join code>/files/<path>).
"""
import hashlib, json, os, sys
from pathlib import Path

SKIP_DIRS = {'MOBA/Saved'}          # per-user data, never shipped
EXES = ('MOBA/Binaries/Win64/MOBA-Win64-Shipping.exe', 'MOBA/Binaries/Win64/MOBA.exe')


def walk(root):
    for dirpath, dirnames, filenames in os.walk(root):
        rel_dir = Path(dirpath).relative_to(root).as_posix()
        dirnames[:] = [d for d in dirnames if (f'{rel_dir}/{d}' if rel_dir != '.' else d) not in SKIP_DIRS]
        for name in filenames:
            p = Path(dirpath) / name
            yield p.relative_to(root).as_posix(), p


def main(game, downloads, build):
    game, downloads = Path(game), Path(downloads)
    cache_path = downloads / '.hashcache.json'
    cache = json.loads(cache_path.read_text()) if cache_path.exists() else {}

    def sha(path):
        st = path.stat()
        key, stamp = str(path.resolve()), [st.st_size, st.st_mtime_ns]
        if cache.get(key, [None])[:2] == stamp:
            return cache[key][2]
        h = hashlib.sha256()
        with open(path, 'rb') as f:
            for block in iter(lambda: f.read(1 << 22), b''):
                h.update(block)
        cache[key] = stamp + [h.hexdigest()]
        return cache[key][2]

    files = {}
    for root in (game, downloads / 'overlay'):          # overlay last: our player files win
        for rel, path in walk(root):
            if rel.endswith(('.part', '.tmp')):
                continue
            files[rel] = {'path': rel, 'size': path.stat().st_size, 'sha256': sha(path)}
    exe = next((e for e in EXES if e in files), None)
    if not exe:
        sys.exit(f'no game exe found in {game}')
    manifest = {'build': build, 'exe': exe, 'engine_ini': 'FangsCE/Engine.ini',
                'files': sorted(files.values(), key=lambda f: f['path'])}
    launcher = downloads / 'FangsCE.exe'
    if launcher.exists():
        manifest['launcher'] = {'path': 'FangsCE.exe', 'size': launcher.stat().st_size, 'sha256': sha(launcher)}
    cache_path.write_text(json.dumps(cache))
    tmp = downloads / 'manifest.json.tmp'
    tmp.write_text(json.dumps(manifest, indent=1))
    tmp.replace(downloads / 'manifest.json')
    total = sum(f['size'] for f in manifest['files'])
    print(f"manifest: {len(manifest['files'])} files, {total / 2**30:.1f} GiB, build {build}")


if __name__ == '__main__':
    main(*sys.argv[1:4])
