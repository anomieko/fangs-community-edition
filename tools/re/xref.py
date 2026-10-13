#!/usr/bin/env python3
"""Lightweight x64 PE explorer for the FANGS exe (no Ghidra needed for targeted work).

  xref.py <exe> str  <text>        functions referencing a string (ASCII and UTF-16 searched)
  xref.py <exe> dis  <va|text>     disassemble the function containing a VA (or first xref of a string)
  xref.py <exe> calls <va>         list direct calls in the function containing <va>

Function bounds come from .pdata. Operands pointing at strings are annotated.
Builds a cache of all rip-relative LEA/MOV references in work/re/xref_cache.npz-like pickle on first use.
"""
import bisect, os, pickle, re, struct, sys

import capstone
import pefile


class Exe:
    def __init__(self, path):
        self.pe = pefile.PE(path, fast_load=True)
        self.data = self.pe.__data__
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.secs = [(s.Name.rstrip(b'\0').decode(), self.base + s.VirtualAddress, s.Misc_VirtualSize,
                      s.PointerToRawData, s.SizeOfRawData) for s in self.pe.sections]
        text = next(s for s in self.secs if s[0] == '.text')
        self.text_va, self.text_off, self.text_size = text[1], text[3], text[4]
        self._funcs = None
        self._refs = None
        st = os.stat(path)   # several builds share the exe name: key the cache by size + mtime too
        self.cache = os.path.join(os.path.dirname(__file__), '..', '..', 'work', 're',
                                  f'{os.path.basename(path)}.{st.st_size}.{int(st.st_mtime)}.xrefs.pickle')

    def off2va(self, off):
        for _, va, vs, ro, rs in self.secs:
            if ro <= off < ro + rs:
                return va + off - ro

    def va2off(self, va):
        for _, sva, vs, ro, rs in self.secs:
            if sva <= va < sva + rs:
                return ro + va - sva

    @property
    def funcs(self):
        if self._funcs is None:
            pd = next(s for s in self.secs if s[0] == '.pdata')
            raw = self.data[pd[3]:pd[3] + pd[2]]
            f = sorted({(self.base + b, self.base + e) for b, e, _ in struct.iter_unpack('<III', raw[:len(raw) // 12 * 12]) if b})
            self._funcs = ([x[0] for x in f], [x[1] for x in f])
        return self._funcs

    def func_of(self, va):
        starts, ends = self.funcs
        i = bisect.bisect_right(starts, va) - 1
        if i >= 0 and starts[i] <= va < ends[i]:
            # chained unwind fragments: walk back while previous fragment ends exactly here
            s = starts[i]
            while i > 0 and ends[i - 1] == s:
                i -= 1; s = starts[i]
            j = bisect.bisect_right(starts, va) - 1
            e = ends[j]
            while j + 1 < len(starts) and starts[j + 1] == e:
                j += 1; e = ends[j]
            return s, e
        return None

    @property
    def refs(self):
        """target VA -> list of instruction VAs (rip-relative lea/mov with disp32)."""
        if self._refs is None:
            if os.path.exists(self.cache):
                with open(self.cache, 'rb') as fh:
                    self._refs = pickle.load(fh)
            else:
                t = self.data[self.text_off:self.text_off + self.text_size]
                refs = {}
                # REX.W/R lea or mov with modrm mod=00 rm=101 (rip-relative)
                for m in re.finditer(rb'[\x48\x4c][\x8d\x8b][\x05\x0d\x15\x1d\x25\x2d\x35\x3d]', t):
                    p = m.start()
                    disp = struct.unpack_from('<i', t, p + 3)[0]
                    target = self.text_va + p + 7 + disp
                    refs.setdefault(target, []).append(self.text_va + p)
                self._refs = refs
                os.makedirs(os.path.dirname(self.cache), exist_ok=True)
                with open(self.cache, 'wb') as fh:
                    pickle.dump(refs, fh)
        return self._refs

    def find_string(self, text):
        hits = []
        for enc in (text.encode('utf-16-le') + b'\0\0', text.encode() + b'\0'):
            for m in re.finditer(re.escape(enc), self.data):
                if enc[1:2] == b'\0' and m.start() % 2:
                    continue
                va = self.off2va(m.start())
                if va:
                    hits.append(va)
        return hits

    def string_at(self, va):
        off = self.va2off(va)
        if off is None:
            return None
        b = self.data[off:off + 400]
        if len(b) > 3 and b[1] == 0 and 32 <= b[0] < 127:  # utf-16
            end = next((i for i in range(0, len(b) - 1, 2) if b[i] == 0 and b[i + 1] == 0), len(b))
            s = b[:end].decode('utf-16-le', 'replace')
            return 'L"' + s + '"' if len(s) >= 2 else None
        end = b.find(b'\0')
        s = b[:end]
        if len(s) >= 3 and all(32 <= c < 127 or c in (9, 10) for c in s):
            return '"' + s.decode() + '"'
        return None

    def disasm(self, start, end):
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
        md.detail = False
        off = self.va2off(start)
        out = []
        for ins in md.disasm(self.data[off:off + (end - start)], start):
            line = f'{ins.address:x}: {ins.mnemonic:7} {ins.op_str}'
            m = re.search(r'\[rip ([+-]) 0x([0-9a-f]+)\]', ins.op_str)
            if m:
                tgt = ins.address + ins.size + (1 if m.group(1) == '+' else -1) * int(m.group(2), 16)
                s = self.string_at(tgt)
                line += f'    ; {tgt:x}' + (f' {s}' if s else '')
            elif ins.mnemonic in ('call', 'jmp') and ins.op_str.startswith('0x'):
                line += '    ; sub_' + ins.op_str[2:]
            out.append(line)
        return out


def main():
    exe, cmd, arg = sys.argv[1], sys.argv[2], ' '.join(sys.argv[3:])
    x = Exe(exe)
    if cmd == 'str':
        for sva in x.find_string(arg):
            for r in x.refs.get(sva, []):
                f = x.func_of(r)
                print(f'string {sva:x} <- {r:x} in func {f[0]:x}-{f[1]:x}' if f else f'string {sva:x} <- {r:x}')
    elif cmd in ('dis', 'calls'):
        if re.fullmatch(r'(0x)?[0-9a-fA-F]{9,}', arg):
            va = int(arg, 16)
        else:
            sva = x.find_string(arg)[0]
            va = x.refs[sva][0]
        s, e = x.func_of(va)
        print(f'; func {s:x}-{e:x} ({e - s} bytes)')
        for l in x.disasm(s, e):
            if cmd == 'dis' or ' call ' in f' {l.split(": ", 1)[1][:5]} ':
                print(l)


if __name__ == '__main__':
    main()
