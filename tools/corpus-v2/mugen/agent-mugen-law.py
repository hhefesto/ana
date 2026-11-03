#!/usr/bin/env python3
# Scratch law for agent-mugen (2026-11-03): for every call of a rendered mugen
# transcript, the tool given the transcript up to that call's `## echo` line
# prints the transcript's own echo, and exits 0 only on the last check.
# usage: agent-mugen-law.py CV2 RESULTS.nul MUGEN.nul SRC N [SHAPES]
# (2026-11-03, gen5: CV2 a bend-corpus-v2 with agent-mugen, RESULTS
# run/v6/transcripts-gen5/bend/results.train.nul, MUGEN
# run/v6/mugen/gen5/transcripts.train.nul, SRC realpath run/v6/gen5/tree)
import os, random, subprocess, sys, re

cv2, results, mugen, src, n = sys.argv[1:6]
shapes = sys.argv[6].split(',') if len(sys.argv) > 6 else ['direct', 'fill', 'repair-0']
n = int(n)
bend = '/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend'

def recs(p):
    d = open(p, 'rb').read().split(b'\0')
    return [(d[i], d[i + 1]) for i in range(0, len(d) - 1, 2)]

res = dict(recs(results))
ms = [(i, t) for i, t in recs(mugen) if i.rsplit(b'/mugen-', 1)[1].decode() in shapes]
random.seed(7)
random.shuffle(ms)
ms = ms[:n]
heads = [b'\n\n## read\n', b'\n\n## edit\n', b'\n\n## shell\n', b'\n\n## mugen\n']
work = os.environ.get('LAW_WORK', '/tmp/agent-mugen-law')
os.makedirs(work, exist_ok=True)
calls = ok = bad = 0
for k, (mid, text) in enumerate(ms):
    uid, shape = mid.rsplit(b'/mugen-', 1)
    rec = res.get(uid)
    if rec is None:
        print('NO RECORD', mid.decode()); bad += 1; continue
    task = f'{work}/task.{k}.nul'
    open(task, 'wb').write(uid + b'\0' + src.encode() + b'\x1e' + shape + b'\x1e' + rec + b'\0')
    wdir = f'{work}/w{k}'
    pos = 0
    while True:
        j = text.find(b'\n\n## echo\n', pos)
        if j < 0: break
        pe = j + len(b'\n\n## echo\n')
        ends = [text.find(h, pe) for h in heads]
        ends = [e for e in ends if e >= 0]
        end = min(ends) + 2 if ends else len(text)
        want = text[pe:end]
        last = not any(text.find(h, pe) >= 0 for h in heads[:3])
        p = subprocess.run([cv2, 'agent-mugen', task, 'echo'], input=text[:pe], capture_output=True,
                           env=dict(os.environ, BEND=bend, AGENT_WORK=wdir, BEND_NO_TELEMETRY='1'))
        calls += 1
        code_ok = (p.returncode == 0) == last and p.returncode in (0, 1)
        if p.stdout == want and code_ok:
            ok += 1
        else:
            bad += 1
            if bad <= 6:
                print('MISMATCH', mid.decode(), 'call at', pe, 'exit', p.returncode, 'last', last)
                print('--- want'); print(want.decode(errors='replace')[:800])
                print('--- got'); print(p.stdout.decode(errors='replace')[:800]); print(p.stderr.decode(errors='replace')[-400:])
        pos = pe
print(f'transcripts {len(ms)} calls {calls} same {ok} differ {bad}')
