#!/usr/bin/env bash
# Decompile chosen functions of a Windows exe with Ghidra headless, without a full analysis of the exe.
#
#   tools/re/decomp.sh <exe> [-depth N] <0xVA | UFunctionName>...
#
#   0xVA          any address inside a function (its start comes from .pdata)
#   UFunctionName a UFUNCTION's exec thunk, found through UHT's name tables (like natives.py)
#   -depth N      also decompile the direct callees, N levels down (a thunk's implementation is one level down)
#
# The exe is imported once, without auto-analysis, into a Ghidra project under work/re/ghidra/<exe>-<sha8>/ that
# later runs reuse; functions made for one run stay for the next. Each run writes out/<time>/: one .c per function,
# targets.json and result.json (input hash, Ghidra version, arguments, status). The exit status is non-zero unless
# every function decompiled. Ghidra keeps its settings in that folder too, not in ~/.config.
# Needs third_party/ghidra_*_PUBLIC and third_party/jdk-21* (README). One run per exe at a time (Ghidra locks the
# project). Pseudocode is Ghidra's reading of machine code, not the original source.
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
MAIN=$(dirname "$(git -C "$REPO" rev-parse --path-format=absolute --git-common-dir)")   # third_party, work
exe=$(realpath "${1:?usage: decomp.sh <exe> [-depth N] <0xVA | UFunctionName>...}"); shift
depth=0
if [ "${1:-}" = -depth ]; then depth=${2:?-depth needs a number}; shift 2; fi
[ $# -gt 0 ] || { echo "decomp.sh: no targets" >&2; exit 2; }
ghidra=${GHIDRA:-$(ls -d "$MAIN"/third_party/ghidra_*_PUBLIC 2>/dev/null | sort -V | tail -1)}
jdk=${GHIDRA_JDK:-$(ls -d "$MAIN"/third_party/jdk-21* 2>/dev/null | sort -V | tail -1)}
[ -x "$ghidra/support/analyzeHeadless" ] || { echo "decomp.sh: no Ghidra in third_party (README)" >&2; exit 2; }
[ -x "$jdk/bin/java" ] || { echo "decomp.sh: no JDK 21 in third_party (README)" >&2; exit 2; }

sha=$(sha256sum "$exe" | cut -d' ' -f1)
base="$MAIN/work/re/ghidra/$(basename "$exe" .exe)-${sha:0:8}"
out="$base/out/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$base/project" "$out"
if [ -d "$base/project/fangs.rep" ]; then mode=(-process "$(basename "$exe")"); else mode=(-import "$exe"); fi
version=$(sed -n 's/^application.version=//p' "$ghidra/Ghidra/application.properties")

set +e
JAVA_HOME="$jdk" PATH="$jdk/bin:$PATH" XDG_CONFIG_HOME="$base/home/config" XDG_CACHE_HOME="$base/home/cache" \
  timeout "${TIMEOUT:-1800}" "$ghidra/support/analyzeHeadless" "$base/project" fangs "${mode[@]}" -noanalysis \
  -scriptPath "$REPO/tools/re/ghidra" -postScript DecompileAt.java "$out" "$depth" "$@" \
  -log "$out/ghidra.log" -scriptlog "$out/script.log" < /dev/null > "$out/stdout.log" 2>&1
code=$?
set -e

python3 -I - "$out" "$exe" "$sha" "$version" "$code" "$depth" "$@" <<'PY'
import json, os, sys
out, exe, sha, version, code, depth, *targets = sys.argv[1:]
code = int(code)
t = json.load(open(os.path.join(out, 'targets.json'))) if os.path.exists(os.path.join(out, 'targets.json')) else None
ok = code == 0 and t is not None and t['failed'] == 0 and t['ok'] > 0
r = {'status': 'success' if ok else ('timeout' if code == 124 else 'failed'), 'exitCode': code, 'input': exe,
     'sha256': sha, 'ghidra': version, 'depth': int(depth), 'targets': targets,
     'functions': t['functions'] if t else None, 'note': None if t else 'targets.json missing: see stdout.log'}
json.dump(r, open(os.path.join(out, 'result.json'), 'w'), indent=1)
for f in (t or {}).get('functions', []):
    print(f"{f['status']:6} {f['label']} {f['target']} {f['file'] or f['message']}")
print(f"{r['status']}: {out}")
sys.exit(0 if ok else 1)
PY
