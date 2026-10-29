#!/usr/bin/env python3
# Hand hist6.py's history mutants to the check (2026-10-28; the user's goal: the most Bend code,
# error-then-fix cases included, at least 4 solutions per error case).
#
#   hist-merge.py UNITS.nul HIST.nul... OUT.nul [MINSIM]
#
# UNITS.nul: bend-units' NUL pairs (id, record), fields joined by 0x1E, 11.. mutants (as
# trim-mutants.py leaves them: one).  HIST.nul: hist6.py's (id, "sha256(body) 0x1E old body 0x1E
# commit 0x1E time").  A unit whose id has a history mutant, for the same body (the sha256), whose
# old body is like the body (difflib ratio of their bytes >= MINSIM, 0.3: a rewrite is no fix; of
# their lines it was 0 for a one-line body's one-token fix)
# gets it as its first mutant, before its others: the check keeps a mutant it rejects, and
# hist-pick.py then keeps the history one alone where the check kept it (a real past error, fixed
# by today's body), the unit's others where it did not (the old body checks today: no error).
# OUT.nul.hist: the history mutants given, a line each: id TAB sha256(old body) (hist6.py's
# HIST_M: a unit may have more than one, newest first; hist-pick.py keeps the first the check kept).
# HIST_ONLY=1: OUT.nul holds only the units given one, with it alone (a stream already checked and
# rendered, run 5's collect5: its history repairs checked apart, hist5.sh).  HIST_IDS=FILE: only
# the units whose id is a line of FILE are given one (its train units).
import sys, os, hashlib, difflib, collections
ONLYH = os.environ.get('HIST_ONLY') == '1'
IDS = set(open(os.environ['HIST_IDS'], 'rb').read().split(b'\n')) if os.environ.get('HIST_IDS') else None
args = sys.argv[1:]
minsim = 0.3
try:
    minsim = float(args[-1]); args = args[:-1]
except ValueError:
    pass
src, hists, out = args[0], args[1:-1], args[-1]
H = {}   # id -> [(sha, old body)], newest first (hist6.py HIST_M: up to M a unit)
for h in hists:
    d = open(h, 'rb').read().split(b'\0')
    for i in range(0, len(d) - 1, 2):
        sha, old, c, t = d[i + 1].split(b'\x1e')
        v = H.setdefault(d[i], [])
        if (sha, old) not in v: v.append((sha, old))
d = open(src, 'rb').read().split(b'\0')
if d and d[-1] == b'': d = d[:-1]
assert len(d) % 2 == 0, 'odd field count'
c = collections.Counter()
c['history units'] = len(H)
c['history mutants'] = sum(map(len, H.values()))
with open(out, 'wb') as f, open(out + '.hist', 'w') as g:
    for i in range(0, len(d), 2):
        uid, rec = d[i], d[i + 1]
        fs = rec.split(b'\x1e')
        c['units'] += 1
        hs = H.get(uid) or []
        if IDS is not None and uid not in IDS: hs = []
        give = []   # the unit's history mutants, newest first, before its others
        for sha, old in hs:
            if hashlib.sha256(fs[7]).hexdigest().encode() != sha: c['history: body differs'] += 1
            elif old in fs[11:] or old in give: c['history: already a mutant'] += 1
            else:
                r = difflib.SequenceMatcher(None, old, fs[7], autojunk=False).ratio()
                c['history: similarity %.1f' % (int(r * 10) / 10)] += 1
                if r < minsim: c['history: unlike'] += 1
                else:
                    give.append(old)
                    g.write(uid.decode('utf-8', 'surrogateescape') + '\t' + hashlib.sha256(old).hexdigest() + '\n')
                    c['history: given'] += 1
        if give:
            c['history units given'] += 1
            if len(give) > 1: c['history: given beyond the newest'] += len(give) - 1
            fs = fs[:11] + give + fs[11:]
        if ONLYH:
            if give: f.write(uid + b'\0' + b'\x1e'.join(fs[:11 + len(give)]) + b'\0')
        else: f.write(uid + b'\0' + b'\x1e'.join(fs) + b'\0')
for k in sorted(c): print(k, c[k])
