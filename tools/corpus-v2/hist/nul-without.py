#!/usr/bin/env python3
# A units/results NUL stream less some records (2026-10-28): run 2's results less its stale units
# (recheck6.sh, refill6.sh, retree6.sh: those that fail today), a seen= for upg2.sh's decl-new: a
# unit of run 2's that checks today stays, so an upgraded copy of it is not taken twice; a stale
# one's upgraded copy replaces it.
#
#   nul-without.py IN OUT CLASS JSONL...     less the records of the files JSONL's ids name
#   nul-without.py IN OUT --ids IDS...       less the records IDS name (an id a line)
#
# A record is an id, CLASS:PATH#NAME@LINE, and a body, NUL after each; a JSONL's id is repo:PATH
# (upg-corpus.py's).  Counts on stderr.
import sys, json

src, out, mode = sys.argv[1:4]
drop, ids = set(), set()
if mode == '--ids':
    for f in sys.argv[4:]:
        for l in open(f, 'rb'):
            if l.strip(): ids.add(l.rstrip(b'\n'))
    pre = None
else:
    for f in sys.argv[4:]:
        for l in open(f, 'rb'):
            drop.add(json.loads(l)['id'].split(':', 1)[1].encode())
    pre = mode.encode() + b':'
kept = gone = 0
# (id, body) pairs, NUL-separated (recheck.py's pairs)
with open(src, 'rb') as r, open(out, 'wb') as w:
    buf, uid = b'', None
    while True:
        b = r.read(1 << 24)
        if b:
            buf += b; recs = buf.split(b'\0'); buf = recs.pop()
        else:
            recs, buf = ([buf] if buf else []), b''
        for x in recs:
            if uid is None: uid = x; continue
            if (uid in ids) if pre is None else (uid.startswith(pre) and uid[len(pre):].rpartition(b'#')[0] in drop):
                gone += 1
            else:
                w.write(uid + b'\0' + x + b'\0'); kept += 1
            uid = None
        if not b: break
    assert uid is None and not buf, 'odd field count'
print('ids' if pre is None else 'files', len(ids) if pre is None else len(drop), 'records kept', kept, 'dropped', gone, file=sys.stderr)
