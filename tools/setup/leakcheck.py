#!/usr/bin/env python3
"""Keeps private things out of this public repository (docs/SELF-HOSTING.md, "Privacy").

  leakcheck.py            every tracked file (CI): real IPv4 addresses, email addresses, private keys
  leakcheck.py --staged   the lines a commit adds (the pre-commit hook tools/setup/hooks/pre-commit), checked for the
                          same and for this machine's own secrets: the join code (work/joincode), the server address
                          (work/deploy-target), the pak's AES key (work/re/aeskey-*.txt), the update signing key
                          (work/signing/*.key)

Exit 1 when something is found. A finding names the file and line, never the secret itself.
Allowed: loopback, private and documentation addresses (127.0.0.1, 10.x, 192.168.x, 203.0.113.x, ...), and the email
addresses commits and tests use on purpose (users.noreply.github.com, noreply@anthropic.com, example.com).
"""
import ipaddress
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SKIP = re.compile(r'\.sha256$|^clients/|^backend/seed/game_records\.json$')   # hash lists; the generated seed
IPV4 = re.compile(r'(?<![\w.])(\d{1,3}(?:\.\d{1,3}){3})(?![\w]|\.\d)')
EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}')
OK_EMAIL = re.compile(r'@(users\.noreply\.github\.com|anthropic\.com|example\.(com|org|net))$|^git@github\.com$', re.I)
PRIVATE_KEY = re.compile(r'-----BEGIN [A-Z ]*PRIVATE KEY-----')
NOT_ADDRESSES = {'21.0.12.1'}   # version numbers that look like addresses (Temurin JDK 21.0.12.1)


def public_ip(text):
    if text in NOT_ADDRESSES:
        return False
    try:
        ip = ipaddress.IPv4Address(text)
    except ValueError:   # 999.1.2.3 and the like: a version number, not an address
        return False
    doc = any(ip in ipaddress.IPv4Network(n) for n in ('192.0.2.0/24', '198.51.100.0/24', '203.0.113.0/24'))
    return not (ip.is_private or ip.is_loopback or ip.is_link_local or ip.is_multicast or ip.is_unspecified
                or ip.is_reserved or doc)


def local_secrets():
    """(label, value) for this machine's own secrets that exist; nothing when run elsewhere (CI)."""
    out = []
    def text(p):
        try:
            return p.read_text(errors='replace').strip()
        except OSError:
            return ''
    if code := text(REPO / 'work/joincode'):
        out.append(('the join code (work/joincode)', code))
    if target := text(REPO / 'work/deploy-target'):
        host = target.split()[0].rsplit('@', 1)[-1]
        if host:
            out.append(('the server address (work/deploy-target)', host))
    for p in sorted((REPO / 'work/re').glob('aeskey-*.txt')):
        if key := text(p):
            out.append((f'the pak key ({p.relative_to(REPO)})', key))
            out.append((f'the pak key ({p.relative_to(REPO)})', key.removeprefix('0x').lower()))
    for p in sorted((REPO / 'work/signing').glob('*.key')):
        if key := text(p):
            out.append((f'the signing key ({p.relative_to(REPO)})', key))
    return [(label, value) for label, value in out if len(value) >= 6]


def check_line(where, line, secrets):
    found = []
    for m in IPV4.finditer(line):
        if public_ip(m.group(1)):
            found.append(f'{where}: an IP address that is not private or a documentation example')
    for m in EMAIL.finditer(line):
        if not OK_EMAIL.search(m.group(0)):
            found.append(f'{where}: an email address')
    if PRIVATE_KEY.search(line):
        found.append(f'{where}: a private key')
    low = line.lower()
    for label, value in secrets:
        if value.lower() in low:
            found.append(f'{where}: {label}')
    return found


def tracked():
    files = subprocess.run(['git', '-C', str(REPO), 'ls-files', '-z'], capture_output=True, check=True).stdout
    for name in files.decode().split('\0'):
        p = REPO / name
        if not name or SKIP.search(name) or p.is_symlink() or not p.is_file():
            continue
        data = p.read_bytes()
        if b'\0' in data[:8192]:   # binary
            continue
        for n, line in enumerate(data.decode(errors='replace').splitlines(), 1):
            yield f'{name}:{n}', line


def staged():
    diff = subprocess.run(['git', '-C', str(REPO), 'diff', '--cached', '-U0', '--no-color', '--no-ext-diff'],
                          capture_output=True, check=True).stdout.decode(errors='replace')
    name, n = None, 0
    for line in diff.splitlines():
        if line.startswith('+++ '):
            name = line[6:] if line.startswith('+++ b/') else None
        elif line.startswith('@@'):
            n = int(re.match(r'@@ -\S+ \+(\d+)', line).group(1))
        elif line.startswith('+') and name:
            if not SKIP.search(name):
                yield f'{name}:{n}', line[1:]
            n += 1


def main():
    is_staged = '--staged' in sys.argv[1:]
    secrets = local_secrets() if is_staged else []
    found = [f for where, line in (staged() if is_staged else tracked()) for f in check_line(where, line, secrets)]
    for f in found:
        print('leakcheck:', f, file=sys.stderr)
    if found:
        print('leakcheck: not committed. Remove these (an allowed example: 203.0.113.10, name@example.com); '
              'if one is fine to publish, commit with --no-verify.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
