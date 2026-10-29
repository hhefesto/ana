#!/usr/bin/env bash
# The standard library and agda-categories (export2s, 703 modules) again through agda2bend 5528567
# (bin/agda2bend-O0-j47: split order as Agda's, String, cubical clauses left out, suc injectivity,
# constructor projections reduced, mutual with-functions, foldl-style recursion, RawApplicative, absurd
# clashes; Bend 2.0.39) into corpus1u (unit a2b-corpus1u, 2026-10-29 12:25; the user's goal 11388).
# As a2bm7.sh, but every module's text (no id filter: a module a2b-s or a2bm7 has may check more
# declarations now) and corpus1u's modules over the tree's; decl-new sees a2bm5's, a2bm7's and the
# PLFA/agda-algebras runs' train units, so only declarations no earlier run has become units.
# Waits for a2b-corpus1u and ana-a2bm7.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
A=/home/hhefesto/src/agda2bend
U=run/v6/a2b8; T=run/v6/transcripts-a2bm8; SRC=run/v5/clean/src/a2bm8
mkdir -p $U $T/bend
while systemctl --user is-active -q a2b-corpus1u || systemctl --user is-active -q ana-a2bm7; do sleep 300; done
grep -q "^exit 0" $A/run/a2b/corpus1u.log || { say "a2bm8: corpus1u did not end well: $(tail -1 $A/run/a2b/corpus1u.log)"; exit 1; }
say "a2bm8: corpus1u ended: $(tail -2 $A/run/a2b/corpus1u.log | cut -c1-200 | tr '\n' ' ')"
if [ ! -s $U/all.jsonl ]; then
  (cd $A && run/a2b/bin/agda2bend-O0-j47 corpus /home/hhefesto/src/ana/$U/all.jsonl run/a2b/export2s run/a2b/corpus1u) > $U/corpus.log 2>&1 || { say "a2bm8 corpus FAILED"; exit 1; }
fi
if [ ! -s $U/raw/bend.jsonl ]; then
  cp $U/all.jsonl $U/new.jsonl; echo "a2bm8: corpus1u modules $(wc -l < $U/new.jsonl)"
  run/v2/gcroot-bend-corpus-v2/bin/bend-corpus-v2 raw $U/raw $U/new.jsonl > $U/raw.log 2>&1 || { say "a2bm8 raw FAILED"; exit 1; }
  cat $U/raw/summary.txt
fi
if [ ! -s $T/a2bm8.jsonl ] || [ ! -d $SRC ]; then
  rm -rf $SRC.tmp
  BASE=run/v5/clean/src/a2bm7; [ -d $BASE ] || BASE=run/v5/clean/src/a2bmf
  python3 -I - $U/raw/bend.jsonl $T/a2bm8.jsonl $BASE $SRC.tmp $A/run/a2b/corpus1u/src <<'PY' || { say "a2bm8 tree FAILED"; exit 1; }
import sys, json, os, re, shutil, collections
inp, out, base, tree, c1t = sys.argv[1:6]
shutil.copytree(base, tree)
c = collections.Counter()
with open(out, 'w', encoding='utf-8') as o:
    for l in open(inp, encoding='utf-8'):
        r = json.loads(l)
        m = re.search(r'^# Bend 2 translation of the Agda module (\S+)', r['text'], re.M)
        if not m: c['no module line'] += 1; continue
        # a2bm5's ids: the module's dotted path (Construction/0-Groupoid.bend), while agda2bend's
        # file takes Bend names (n0_Groupoid.bend): the text goes at the id's path too, as a2bm's tree
        rel = m.group(1).replace('.', '/') + '.bend'
        q = os.path.join(tree, 'mods', rel)
        if not os.path.exists(os.path.join(c1t, rel)):
            os.makedirs(os.path.dirname(q), exist_ok=True); open(q, 'w', encoding='utf-8').write(r['text']); c['tree id path'] += 1
        o.write(json.dumps({'id': 'a2b:mods/' + rel, 'text': r['text']}, ensure_ascii=False) + '\n'); c['units file'] += 1
for dp, _, fs in os.walk(c1t):
    for f in fs:
        if not f.endswith('.bend'): continue
        rel = os.path.relpath(os.path.join(dp, f), c1t); q = os.path.join(tree, 'mods', rel)
        c['tree replaced' if os.path.exists(q) else 'tree added'] += 1
        os.makedirs(os.path.dirname(q), exist_ok=True); shutil.copyfile(os.path.join(dp, f), q)
print('a2bm8:', dict(c))
PY
  rm -rf $SRC; mv $SRC.tmp $SRC
fi
E="CORPUS=$T/a2bm8.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "a2bm8 sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "a2bm8 units"; env $E CHUNK=25 UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
SEENX=; for x in run/v6/transcripts-a2bm6 run/v6/transcripts-a2bm7 run/v6/transcripts-a2bplfa run/v6/transcripts-a2bplfa2 run/v6/transcripts-a2bplfa3 run/v6/transcripts-a2baa run/v6/transcripts-a2baa2 run/v6/transcripts-a2bum; do [ -e $x/bend/results.train.nul ] && SEENX="$SEENX seen=$x/bend/results.train.nul"; done
say "a2bm8: seen also:$SEENX"
if [ ! -e $T/bend/units.decl.nul ]; then
  say "a2bm8 decl-new held/seen"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5/bend/results.train.nul seen=run/v5/transcripts-a2bm5/bend/results.train.nul $SEENX > $T/decl.log 2>&1 || { say "decl-new FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "a2bm8 decl-new cap"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.decl.nul $T/bend/units.nul cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  mv $T/bend/units.nul $T/bend/units.nul.full
  python3 -I run/v5/clean/trim-mutants.py $T/bend/units.nul.full $T/bend/units.nul > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
fi
say "a2bm8 check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "a2bm8 DONE"
