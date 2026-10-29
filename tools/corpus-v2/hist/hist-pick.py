#!/usr/bin/env python3
# After the check: a unit given a history mutant (hist-merge.py) keeps that one alone when the
# check kept it (it rejected the old body: a real past error, today's body its fix), and its other
# kept mutants when the check did not (2026-10-28).  The repair mix keeps one repair a unit
# (cap=1); without this it would pick between the history one and a made-up one by key.
#
#   hist-pick.py RESULTS.nul UNITS.nul.hist OUT.nul
#
# RESULTS.nul: bend-check's NUL pairs (id, record): fields 0..10 the unit's, 11 the check, 12 the
# context, 13 the hole's check, 14 empty, 15.. (mutant, check) pairs of the kept mutants.
# OUT.nul.hist-ids: the ids whose history mutant was kept, a line each.
import sys, hashlib, collections
src, hl, out = sys.argv[1:4]
H = {}   # id -> [sha256 of a history mutant given], newest first (hist-merge.py's order)
for ln in open(hl, encoding='utf-8', errors='surrogateescape'):
    i, s = ln.rstrip('\n').split('\t')
    H.setdefault(i.encode('utf-8', 'surrogateescape'), []).append(s.encode())
d = open(src, 'rb').read().split(b'\0')
if d and d[-1] == b'': d = d[:-1]
assert len(d) % 2 == 0, 'odd field count'
c = collections.Counter()
with open(out, 'wb') as f, open(out + '.hist-ids', 'wb') as g:
    for i in range(0, len(d), 2):
        uid, rec = d[i], d[i + 1]
        fs = rec.split(b'\x1e')
        c['results'] += 1
        s = H.get(uid)
        if s is not None:
            c['history units'] += 1
            ps = [(fs[k], fs[k + 1]) for k in range(15, len(fs) - 1, 2)]
            ks = {hashlib.sha256(p[0]).hexdigest().encode(): p for p in ps}
            hp = [ks[x] for x in s if x in ks]   # the newest history mutant the check kept
            if hp:
                c['history kept (a real error)'] += 1
                if ks.get(s[0]) is not hp[0]: c['history kept: an older one (the newest checks)'] += 1
                fs = fs[:15] + list(hp[0]); g.write(uid + b'\n')
            else:
                c['history not kept (old body checks or timed out)'] += 1
        f.write(uid + b'\0' + b'\x1e'.join(fs) + b'\0')
c['history ids given'] = len(H)
for k in sorted(c): print(k, c[k])
