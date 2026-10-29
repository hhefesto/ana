#!/usr/bin/env python3
# Today's compiler on an older stream's units (2026-10-28; the user's goal: the most Bend code, and
# true tool outputs in it).  Run 2's units were checked on 10-04's Bend, run 5's collection's on
# 10-16's; under Bend 2.0.39 a sample of run 2's fails 31% (148 of 480): Base renamed its helpers
# (Map.get.bit, Nat.div.fin, String.eq.fin; List.find.put went in 2.0.38, #1730), Base's new
# types clash with a file's own (Text, Ready), @unsafe/foreign defs no longer check.  Their
# transcripts say ALL PROOFS CHECK where today's Bend says otherwise.
#
#   recheck.py tree UNITS.nul FILES.nul SRC
#     run 2's trees: FILES.nul's (CLASS:PATH, text) pairs written to SRC/CLASS/PATH, then each
#     unit's own file over it (its fields 5..8, head, header, body and tail, are its file: run 2's
#     files-hi.nul is a day newer than its units, 475 of 480 alike)
#   recheck.py files UNITS.nul SRC OUT [CLASS]
#     each file that holds a unit of UNITS.nul (CLASS: only that class's), checked whole with
#     --check-only in SRC (the class's tree; --check-only writes nothing): OUT/files.tsv (path,
#     ok|fail|timeout, the error's first lines); a file that checks has every unit checking (a
#     unit is the file's head and the unit: a prefix).  OUT/bend/units.nul: the other files'
#     units, their fields 0..10 (no mutants), for `deploy transcripts check bend`.
#   recheck.py stale UNITS.nul OUT
#     after that check (OUT/bend/results.nul: the units that check): OUT/stale.ids, the units
#     that fail today, a line each; their counts by repository in OUT/stale.tsv.
#
# env BEND (the bend), PROCS (4), TIMEOUT (120 s).
import sys, os, subprocess, collections, concurrent.futures as cf

BEND = os.environ.get('BEND', '/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend')
PROCS = int(os.environ.get('PROCS', '4'))
TIMEOUT = int(os.environ.get('TIMEOUT', '120'))

def pairs(path):
    d = open(path, 'rb').read().split(b'\0')
    if d and d[-1] == b'': d = d[:-1]
    assert len(d) % 2 == 0, 'odd field count: ' + path
    return d

def fileof(uid):
    # CLASS:PATH#NAME@LINE -> (CLASS, PATH)
    cls, _, rest = uid.partition(b':')
    return cls, rest.rpartition(b'#')[0]

def check(src, rel):
    src = os.path.abspath(src)
    p = os.path.normpath(os.path.join(src, os.fsdecode(rel)))
    if not p.startswith(os.path.abspath(src) + '/'): return rel, 'fail', 'outside the tree'
    if not os.path.isfile(p): return rel, 'fail', 'missing'
    env = dict(os.environ, BEND_NO_TELEMETRY='1')
    try:
        r = subprocess.run([BEND, os.path.basename(p), '--check-only'], cwd=os.path.dirname(p),
                           capture_output=True, timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return rel, 'timeout', ''
    out = (r.stdout + r.stderr).decode('utf-8', 'replace')
    lines = out.splitlines()
    ok = r.returncode == 0 and lines[:1] == ['ALL PROOFS CHECK']
    return rel, 'ok' if ok else 'fail', ' | '.join(lines[:4])[:300].replace('\t', ' ')

def files(units, src, out, cls=None):
    d = pairs(units)
    os.makedirs(out + '/bend', exist_ok=True)
    want = collections.OrderedDict()
    for i in range(0, len(d), 2):
        c, rel = fileof(d[i])
        if cls is not None and c != cls.encode(): continue
        want.setdefault(rel, []).append(i)
    done = {}
    tsv = out + '/files.tsv'
    if os.path.exists(tsv):   # resume
        for l in open(tsv, 'rb'):
            f = l.rstrip(b'\n').split(b'\t')
            if len(f) >= 2: done[f[0]] = f[1].decode()
    todo = [r for r in want if r not in done]
    print('files', len(want), 'done before', len(done), 'to check', len(todo), flush=True)
    with open(tsv, 'ab') as t, cf.ThreadPoolExecutor(PROCS) as ex:
        n = 0
        for rel, st, msg in ex.map(lambda r: check(src, r), todo):
            t.write(rel + b'\t' + st.encode() + b'\t' + msg.encode() + b'\n'); t.flush()
            done[rel] = st; n += 1
            if n % 500 == 0: print('checked', n, 'of', len(todo), flush=True)
    c = collections.Counter(done[r] for r in want)
    nu = collections.Counter()
    with open(out + '/bend/units.nul', 'wb') as o:
        for rel, ix in want.items():
            nu[done[rel]] += len(ix)
            if done[rel] == 'ok': continue
            for i in ix:
                fs = d[i + 1].split(b'\x1e')
                o.write(d[i] + b'\0' + b'\x1e'.join(fs[:11]) + b'\0')
    for k in sorted(c): print('files', k, c[k], 'units', nu[k])

def tree(units, fl, src):
    src = os.path.abspath(src)
    c = collections.Counter()
    def put(cls, rel, text):
        p = os.path.normpath(os.path.join(src, os.fsdecode(cls), os.fsdecode(rel)))
        assert p.startswith(os.path.abspath(src) + '/'), p
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if os.path.exists(p) and open(p, 'rb').read() == text: return False
        open(p, 'wb').write(text); return True
    f = pairs(fl)
    for i in range(0, len(f), 2):
        cls, _, rel = f[i].partition(b':')
        put(cls, rel, f[i + 1]); c['files'] += 1
    del f
    d = pairs(units)
    seen = {}
    for i in range(0, len(d), 2):
        cls, rel = fileof(d[i])
        fs = d[i + 1].split(b'\x1e')
        text = fs[5] + fs[6] + fs[7] + fs[8]
        k = (cls, rel)
        if k in seen:
            if seen[k] != text: c['units: a second text of a file (left)'] += 1
            continue
        seen[k] = text
        c['units: file rewritten' if put(cls, rel, text) else 'units: file alike'] += 1
    for k in sorted(c): print(k, c[k])

def stale(units, out):
    d = pairs(units)
    t = {}
    for l in open(out + '/files.tsv', 'rb'):
        f = l.rstrip(b'\n').split(b'\t')
        if len(f) >= 2: t[f[0]] = f[1]
    r = pairs(out + '/bend/results.nul')
    kept = set(r[0::2])
    asked = set(pairs(out + '/bend/units.nul')[0::2])
    c, by = collections.Counter(), collections.Counter()
    with open(out + '/stale.ids', 'wb') as o:
        for i in range(0, len(d), 2):
            u = d[i]
            cls, rel = fileof(u)
            st = t.get(rel)
            if st is None: c['not looked at'] += 1; continue
            if st == b'ok': c['fresh: file checks'] += 1; continue
            if u in kept: c['fresh: unit checks'] += 1; continue
            if u not in asked: c['not asked'] += 1; continue
            c['stale'] += 1; by[rel.split(b'/')[0]] += 1
            o.write(u + b'\n')
    with open(out + '/stale.tsv', 'wb') as o:
        for k, v in by.most_common(): o.write(k + b'\t' + str(v).encode() + b'\n')
    for k in sorted(c): print(k, c[k])

if __name__ == '__main__':
    a = sys.argv[1:]
    if a[:1] == ['tree'] and len(a) == 4: tree(a[1], a[2], a[3])
    elif a[:1] == ['files'] and len(a) in (4, 5): files(a[1], a[2], a[3], a[4] if len(a) == 5 else None)
    elif a[:1] == ['stale'] and len(a) == 3: stale(a[1], a[2])
    else: sys.exit('usage: recheck.py tree UNITS.nul FILES.nul SRC | files UNITS.nul SRC OUT [CLASS] | stale UNITS.nul OUT')
