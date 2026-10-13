#!/usr/bin/env python3
"""Render bpdump JSON as readable Blueprint pseudocode.

Usage: bp2txt.py <json-dir-or-file>... [-o OUTDIR]   (default: .txt next to each .json)
"""
import argparse, json, os, re

JUMPS = {'Jump', 'JumpIfNot', 'PushExecutionFlow'}


def short(path):
    """'/Script/Engine.KismetMathLibrary' -> 'KismetMathLibrary'; strip Default__ CDO prefixes."""
    if not isinstance(path, str):
        return str(path)
    s = path.rsplit('.', 1)[-1].rsplit('/', 1)[-1].rsplit(':', 1)[-1]
    return s[len('Default__'):] if s.startswith('Default__') else s


def lit(v):
    return json.dumps(v, ensure_ascii=False)


def args(e):
    return ', '.join(x(p) for p in e.get('Parameters', []))


def x(e):  # noqa: C901 - one branch per opcode is the clearest form here
    if e is None:
        return '<null>'
    if not isinstance(e, dict):
        return str(e)
    i = e.get('Inst')
    if i in ('LocalVariable', 'InstanceVariable', 'LocalOutVariable', 'DefaultVariable', 'ClassSparseDataVariable'):
        n = e.get('Variable Name', '?')
        return f'self.{n}' if i == 'InstanceVariable' else n
    if i in ('Context', 'Context_FailSilent', 'ClassContext'):
        inner = x(e.get('Expression'))
        return f"{x(e.get('Context'))}.{inner[5:] if inner.startswith('self.') else inner}"
    if i == 'InterfaceContext':
        return x(e.get('Expression'))
    if i in ('FinalFunction', 'LocalFinalFunction'):
        return f"{short(e.get('Function'))}({args(e)})"
    if i in ('VirtualFunction', 'LocalVirtualFunction'):
        return f"{e.get('Function') or e.get('FunctionName')}({args(e)})"
    if i == 'CallMath':
        return f"{short(e.get('ContextClass'))}::{short(e.get('Function'))}({args(e)})"
    if i in ('Let', 'LetObj', 'LetBool', 'LetWeakObjPtr', 'LetDelegate', 'LetMulticastDelegate'):
        return f"{x(e.get('Variable'))} = {x(e.get('Expression'))}"
    if i == 'LetValueOnPersistentFrame':
        return f"persistent.{e.get('Property Name', '?')} = {x(e.get('Expression'))}"
    if i == 'StructMemberContext':
        return f"{x(e.get('StructExpression'))}.{e.get('Property Name', '?')}"
    if i == 'ArrayGetByRef':
        return f"{x(e.get('ArrayExpression'))}[{x(e.get('IndexExpression'))}]"
    if i in ('IntConst', 'IntConstByte', 'ByteConst', 'Int64Const', 'UInt64Const', 'SkipOffsetConst'):
        return str(e.get('Value'))
    if i in ('FloatConst', 'DoubleConst'):
        return f"{e.get('Value')}f" if i == 'FloatConst' else str(e.get('Value'))
    if i in ('StringConst', 'UnicodeStringConst'):
        return lit(e.get('Value'))
    if i == 'NameConst':
        return f"Name({lit(e.get('Value'))})"
    if i == 'TextConst':
        t = e.get('TextLiteralType')
        if t == 'Empty':
            return 'Text("")'
        if t == 'StringTableEntry':
            return f"TableText({lit(e.get('TableId'))}, {lit(e.get('TableKey'))})"
        return f"Text({lit(e.get('SourceString'))})"
    if i == 'ObjectConst':
        return short(e.get('Object'))
    if i == 'SoftObjectConst':
        return f"Soft({x(e.get('Value'))})"
    if i == 'FieldPathConst':
        return f"FieldPath({x(e.get('Expression'))})"
    if i in ('IntZero',):
        return '0'
    if i in ('IntOne',):
        return '1'
    if i in ('True', 'False'):
        return i.lower()
    if i == 'Self':
        return 'self'
    if i in ('NoObject', 'NoInterface'):
        return 'nullptr'
    if i == 'VectorConst':
        return f"FVector({e.get('X')}, {e.get('Y')}, {e.get('Z')})"
    if i == 'RotationConst':
        return f"FRotator({e.get('Pitch')}, {e.get('Yaw')}, {e.get('Roll')})"
    if i == 'TransformConst':
        return 'FTransform(...)'
    if i == 'StructConst':
        props = e.get('Properties') or {}
        inner = ', '.join(x(v[0] if isinstance(v, list) and v else v) for v in props.values())
        return f"{short(e.get('Struct'))}{{{inner}}}"
    if i in ('ArrayConst', 'SetConst'):
        return '[' + ', '.join(x(v) for v in e.get('Values', [])) + ']'
    if i == 'MapConst':
        return '{' + ', '.join(f"{x(v.get('Key'))}: {x(v.get('Value'))}" if isinstance(v, dict) and 'Key' in v else x(v) for v in e.get('Values', [])) + '}'
    if i in ('SetArray', 'SetSet'):
        return f"{x(e.get('LeftSideExpression'))} = [" + ', '.join(x(v) for v in e.get('Values', [])) + ']'
    if i == 'SetMap':
        return f"{x(e.get('LeftSideExpression'))} = {{" + ', '.join(f"{x(v['Key'])}: {x(v['Value'])}" for v in e.get('Values', [])) + '}'
    if i in ('DynamicCast', 'MetaCast'):
        return f"Cast<{short(e.get('Class'))}>({x(e.get('Expression'))})"
    if i in ('ObjToInterfaceCast', 'CrossInterfaceCast'):
        return f"Cast<{short(e.get('InterfaceClass'))}>({x(e.get('Expression'))})"
    if i == 'InterfaceToObjCast':
        return f"Cast<{short(e.get('ObjectClass'))}>({x(e.get('Expression'))})"
    if i == 'PrimitiveCast':
        return f"{e.get('CastType', 'Cast')}({x(e.get('Expression'))})"
    if i == 'SwitchValue':
        cases = ', '.join(f"{x(c.get('CaseValue'))}: {x(c.get('CaseResult'))}" for c in e.get('Cases', []))
        return f"switch({x(e.get('Expression'))}) {{{cases}, default: {x(e.get('DefaultResult'))}}}"
    if i == 'InstanceDelegate':
        return f"&self.{e.get('FunctionName')}"
    if i == 'BindDelegate':
        return f"{x(e.get('Delegate'))} = Bind({x(e.get('Object'))}, {lit(e.get('FunctionName'))})"
    if i == 'AddMulticastDelegate':
        return f"{x(e.get('MulticastDelegate'))} += {x(e.get('Delegate'))}"
    if i == 'RemoveMulticastDelegate':
        return f"{x(e.get('MulticastDelegate'))} -= {x(e.get('Delegate'))}"
    if i == 'ClearMulticastDelegate':
        return f"{x(e.get('MulticastDelegate'))}.Clear()"
    if i == 'CallMulticastDelegate':
        return f"{x(e.get('Delegate'))}.Broadcast({args(e)})"
    if i == 'Return':
        return f"return {x(e.get('Expression'))}"
    if i == 'Jump':
        return f"goto L{e.get('Offset')}"
    if i == 'JumpIfNot':
        return f"if (!{x(e.get('Condition'))}) goto L{e.get('Offset')}"
    if i == 'ComputedJump':
        return f"goto ({x(e.get('OffsetExpression'))})"
    if i == 'PushExecutionFlow':
        return f"push_flow L{e.get('Offset')}"
    if i == 'PopExecutionFlow':
        return 'pop_flow'
    if i == 'PopExecutionFlowIfNot':
        return f"if (!{x(e.get('Condition'))}) pop_flow"
    if i == 'Assert':
        return f"assert({x(e.get('Expression'))})"
    if i in ('Nothing', 'EndOfScript', 'WireTracepoint', 'Tracepoint', 'Breakpoint', 'InstrumentationEvent', 'EndParmValue'):
        return ''
    rest = {k: v for k, v in e.items() if k not in ('Inst', 'StatementIndex')}
    return f"{i}{lit(rest) if rest else ''}"


def entry_points(funcs):
    """Map ubergraph offset -> [event names] from stubs like `ExecuteUbergraph_X(1234)`."""
    eps = {}
    for f in funcs:
        for st in f.get('script') or []:
            for m in re.finditer(r'"(?:Function|FunctionName)": "[^"]*ExecuteUbergraph_[^"]*", "Parameters": \[\{"Inst": "IntConst", "Value": (\d+)', json.dumps(st)):
                eps.setdefault(int(m.group(1)), []).append(f['name'])
    return eps


def render_func(f, out, eps=None):
    eps = eps if f['name'].startswith('ExecuteUbergraph_') else {}
    params = [p for p in f.get('props', []) if 'Parm' in p['flags']]
    locs = [p for p in f.get('props', []) if 'Parm' not in p['flags']]
    sig = ', '.join(f"{'out ' if 'OutParm' in p['flags'] and 'ReturnParm' not in p['flags'] else ''}{p['type']} {p['name']}" for p in params)
    out.append(f"  // flags: {f.get('flags')}")
    out.append(f"  function {f['name']}({sig}) {{")
    if f.get('script_error'):
        out.append(f"    // !! script decode error: {f['script_error']}")
    script = f.get('script') or []
    targets = set(eps)
    for st in script:
        for m in re.finditer(r'"(?:Offset)": (\d+)', json.dumps(st)):
            targets.add(int(m.group(1)))
    if locs and script:
        out.append('    // locals: ' + ', '.join(f"{p['type']} {p['name']}" for p in locs))
    for st in script:
        idx = st.get('StatementIndex')
        line = x(st)
        if idx in targets:
            out.append(f"  L{idx}:" + (f"  // ===== event: {', '.join(eps[idx])} =====" if idx in eps else ''))
        if line:
            out.append(f"    {line};")
    out.append('  }')
    out.append('')


def render(d):
    out = [f"// {d.get('asset')}"]
    funcs = d.get('functions', [])
    eps = entry_points(funcs)
    for c in d.get('classes', []):
        kind = c.get('kind', 'class')
        ifs = [i for i in c.get('interfaces', []) if i]
        out.append(f"{'struct' if kind != 'class' and kind != 'ClassExport' else 'class'} {c['name']} : {c.get('super')}{' implements ' + ', '.join(ifs) if ifs else ''} {{")
        for p in c.get('props', []):
            rep = f" [RepNotify={p['repnotify']}]" if p.get('repnotify') else ''
            net = ' [Replicated]' if 'Net' in p['flags'] else ''
            out.append(f"  {p['type']} {p['name']};{net}{rep}")
        out.append('')
        if c is d['classes'][0]:
            for f in funcs:
                render_func(f, out, eps)
        out.append('}')
        out.append('')
    if not d.get('classes'):
        for f in funcs:
            render_func(f, out, eps)
    return '\n'.join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('inputs', nargs='+')
    ap.add_argument('-o', '--outdir')
    a = ap.parse_args()
    files = []
    for inp in a.inputs:
        if os.path.isdir(inp):
            for root, _, fs in os.walk(inp):
                files += [(os.path.join(root, f), os.path.relpath(os.path.join(root, f), inp)) for f in fs if f.endswith('.json')]
        else:
            files.append((inp, os.path.basename(inp)))
    for path, rel in files:
        with open(path) as fh:
            txt = render(json.load(fh))
        dst = os.path.join(a.outdir, rel) if a.outdir else path
        dst = dst[:-5] + '.txt'
        os.makedirs(os.path.dirname(dst) or '.', exist_ok=True)
        with open(dst, 'w') as fh:
            fh.write(txt)
    print(f'rendered {len(files)} files')


if __name__ == '__main__':
    main()
