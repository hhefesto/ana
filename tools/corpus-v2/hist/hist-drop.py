#!/usr/bin/env python3
# A transcript stream less the made-up repairs of the units that have a real one (2026-10-28):
# hist5.sh checks run 5's history mutants apart; the repair mix keeps one repair a unit (cap=1),
# by key, so a unit's check-mutant and mutate repairs go, and its history repair stays.
#
#   hist-drop.py IN.nul OUT.nul UNITS
#
# IN.nul: NUL pairs (transcript id, text).  UNITS: unit ids, a line each.  A transcript's unit is
# repair-mix's: its id less a leading `mut:`, less its last `/` segment (the shape), less a
# trailing `+N`.  Dropped: a transcript of a listed unit that is mutate's (`mut:`) or whose shape
# is `repair`.  The rest is copied in order.
import sys, re, collections
src, out, ul = sys.argv[1:4]
U = set(x for x in open(ul, 'rb').read().split(b'\n') if x)
c = collections.Counter()
plus = re.compile(rb'\+[0-9]+$')
with open(src, 'rb') as f, open(out, 'wb') as o:
    d = f.read().split(b'\0')
    if d and d[-1] == b'': d = d[:-1]
    assert len(d) % 2 == 0, 'odd field count'
    for i in range(0, len(d), 2):
        tid = d[i]
        m = tid.startswith(b'mut:')
        x = tid[4:] if m else tid
        u, _, shape = x.rpartition(b'/')
        u = plus.sub(b'', u)
        c['in'] += 1
        if u in U and (m or shape == b'repair'):
            c['dropped'] += 1; continue
        o.write(tid + b'\0' + d[i + 1] + b'\0')
        c['out'] += 1
for k in sorted(c): print(k, c[k])
