# Player downloads (launcher)

15 Oct 2026, Feb 2023 build. Players said the first download was very slow.

## What players download

290 files, 13.4 GiB (`work/dist/<host>/manifest.json`). One file is 90% of it: `MOBA-WindowsNoEditor.pak`,
12.07 GiB. Then `libcef.dll` 94 MiB, the game exe 84 MiB, three movies of 43-61 MiB; 99 files are under 1 MiB.

Until `fast-download`, the launcher fetched the files one after another over one HTTP connection, uncompressed, so
the pak came over a single TCP stream.

## Server, measured during downloads (read-only, 15 Oct ~18:20 UTC)

- Three players downloading at once, about 22, 90 and 190 Mbit/s (`ss -tin`, delivery rate). Total egress
  284 Mbit/s over 10 s. CPU 81-87% idle, disk reads ~32 MB/s (the pak doesn't fit in the page cache, so it comes from
  disk), IO pressure ~1%. The server was not the limit at that moment.
- The 22 Mbit/s player: RTT 528 ms against a minimum of 22 ms, i.e. their own line was full (a deep queue at
  their end). At that speed 12.6 GB takes ~80 minutes; only sending fewer bytes helps them.
- Kernel TCP settings were Debian's defaults: `cubic`, `fq_codel`, `tcp_wmem` max 4 MiB; BBR not loaded (the
  module ships with the cloud kernel). cubic cuts its rate by 30% on each loss, so a single stream over a long or lossy
  path stays well below the player's line.
- Not checked: the VPS network ceiling under full load, backend logs of earlier downloads (container logs need
  sudo on the server).

## The pak compresses

Most of the pak is stored neither compressed nor encrypted (it would not shrink otherwise). 25 samples of 32 MiB
spread over the file: zstd -3 to 53%, gzip -6 to 56% (single regions 25-74%). So the download roughly halves (~7 GB,
estimated from the samples; `build-manifest.py` prints the real figure). gzip is in Go's
standard library, so the launcher stays without dependencies.

## What changed (`fast-download`)

- `player/build-manifest.py`: files of 4 MiB or more are also listed as 32 MiB pieces (SHA-256, size, gzipped size);
  each piece is gzipped into `<downloads>/chunks/<sha256>.gz` (content-addressed: an unchanged piece is never
  packed or uploaded again).
- Backend: `/download/<join code>/chunks/<sha256>.gz`, sent without Content-Encoding.
- Launcher: big files come as pieces, 4 at a time over kept-open connections, written in order into `<file>.part`;
  each piece is checked against its SHA-256 from the signed file list. Resume re-checks the pieces already in the
  `.part` (also a `.part` left by an older launcher) and fetches only the rest. A piece that receives nothing for
  30 s is fetched again (3 tries). A piece the server doesn't have comes as a byte range of the whole file.
  Older launchers ignore the pieces and fetch whole files as before.
- `server/harden.sh`: BBR (`net.ipv4.tcp_congestion_control = bbr`, `fq` from the next boot on).

Test: `tools/run/test_download.sh` (fake game, real backend, signed list, Linux launcher build: fresh install,
resume with a damaged piece, server without pieces); unit tests `launcher/download_test.go`.
