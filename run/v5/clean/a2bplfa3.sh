#!/usr/bin/env bash
# PLFA a third time, agda2bend 5528567 (O0-j47: split order as Agda's (∸), String as Bend's String, cubical clauses left out, suc injectivity under a2b_pred,
# projections of constructor values reduced, mutual with-functions (filter) and recursion on a later
# parameter (foldl) made Bend-recursive, RawApplicative, absurd clashes of any constructors; Bend 2.0.39):
# decl-new drops what a2b-s, a2bplfa and a2bplfa2 have, so only the declarations j47 newly gets are units
# (2026-10-29 12:00; the user's goal 11388).  Waits for a2b-plfa47 and for ana-a2bplfa2 (its results).
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
A=/home/hhefesto/src/agda2bend
U=run/v6/a2bplfa3; T=run/v6/transcripts-a2bplfa3; SRC=run/v5/clean/src/a2bplfa3
mkdir -p $U $T/bend
SEEN2=; [ -e run/v6/transcripts-a2bplfa2/bend/results.train.nul ] && SEEN2=seen=run/v6/transcripts-a2bplfa2/bend/results.train.nul
while systemctl --user is-active -q a2b-plfa47 || systemctl --user is-active -q ana-a2bplfa2; do sleep 300; done
SEEN2=; [ -e run/v6/transcripts-a2bplfa2/bend/results.train.nul ] && SEEN2=seen=run/v6/transcripts-a2bplfa2/bend/results.train.nul
say "a2bplfa3: seen a2bplfa2: ${SEEN2:-none}"
say "a2bplfa3: a2b-plfa47 ended: $(tail -2 $A/run/a2b/corpus-plfa-j47.log | cut -c1-200 | tr '\n' ' ')"
grep -q 'emit exit 0' $A/run/a2b/corpus-plfa-j47.log || { say "a2bplfa3: a2b-plfa47 did not end well"; exit 1; }
if [ ! -s $U/all.jsonl ]; then
  (cd $A && run/a2b/bin/agda2bend-O0-j47 corpus /home/hhefesto/src/ana/$U/all.jsonl run/a2b/export-plfa run/a2b/corpus-plfa-j47) > $U/corpus.log 2>&1 || { say "a2bplfa3 corpus FAILED"; exit 1; }
  tail -1 $U/corpus.log
fi
if [ ! -s $U/raw/bend.jsonl ]; then
  python3 -I - run/v5/a2b-s/bend.jsonl $U/all.jsonl $U/new.jsonl <<'PY' || { say "a2bplfa3 new FAILED"; exit 1; }
import sys, json, collections
old = {json.loads(l)['id'] for l in open(sys.argv[1], encoding='utf-8')}
c = collections.Counter()
with open(sys.argv[3], 'w', encoding='utf-8') as o:
    for l in open(sys.argv[2], encoding='utf-8'):
        i = json.loads(l)['id']
        c['modules'] += 1
        c['in a2b-s' if i in old else 'not in a2b-s'] += 1
        o.write(l); c['new'] += 1
print('a2bplfa3:', dict(c))
PY
  run/v2/gcroot-bend-corpus-v2/bin/bend-corpus-v2 raw $U/raw $U/new.jsonl > $U/raw.log 2>&1 || { say "a2bplfa3 raw FAILED"; exit 1; }
  cat $U/raw/summary.txt
fi
if [ ! -s $T/a2bplfa.jsonl ] || [ ! -d $SRC ]; then
  rm -rf $SRC.tmp
  python3 -I - $U/raw/bend.jsonl $T/a2bplfa.jsonl $A/run/a2b/corpus-plfa-j47/corpus $SRC.tmp <<'PY' || { say "a2bplfa3 tree FAILED"; exit 1; }
import sys, json, os, re, shutil, collections
inp, out, cp, tree = sys.argv[1:5]
hdr = re.compile(r'^# Bend 2 translation of the Agda module (\S+)', re.M)
shutil.copytree(cp, os.path.join(tree, 'mods'))
where = {}
for dp, _, fs in os.walk(cp):
    for f in fs:
        if f.endswith('.bend'):
            p = os.path.join(dp, f)
            m = hdr.search(open(p, encoding='utf-8').read(400))
            if m: where[m.group(1)] = os.path.relpath(p, cp)
c = collections.Counter()
with open(out, 'w', encoding='utf-8') as o:
    for l in open(inp, encoding='utf-8'):
        r = json.loads(l)
        m = hdr.search(r['text'])
        if not m or m.group(1) not in where: c['no corpus copy'] += 1; continue
        rel = where[m.group(1)]
        q = os.path.join(tree, 'mods', rel)
        if open(q, encoding='utf-8').read() != r['text']:
            open(q, 'w', encoding='utf-8').write(r['text']); c['tree text replaced'] += 1
        o.write(json.dumps({'id': 'a2b:mods/' + rel, 'text': r['text']}, ensure_ascii=False) + '\n'); c['units file'] += 1
print('a2bplfa3:', dict(c), 'tree modules', len(where))
PY
  rm -rf $SRC; mv $SRC.tmp $SRC
fi
E="CORPUS=$T/a2bplfa.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "a2bplfa3 sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "a2bplfa3 units"; env $E CHUNK=25 UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
if [ ! -e $T/bend/units.decl.nul ]; then
  say "a2bplfa3 decl-new held/seen"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5/bend/results.train.nul seen=run/v5/transcripts-a2bm5/bend/results.train.nul seen=run/v6/transcripts-a2bplfa/bend/results.train.nul $SEEN2 > $T/decl.log 2>&1 || { say "decl-new FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "a2bplfa3 decl-new cap"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.decl.nul $T/bend/units.nul cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  mv $T/bend/units.nul $T/bend/units.nul.full
  python3 -I run/v5/clean/trim-mutants.py $T/bend/units.nul.full $T/bend/units.nul > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
fi
say "a2bplfa3 check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "a2bplfa3 DONE"
