#!/usr/bin/env bash
# The corpora again through agda2bend 5747eec (bin/agda2bend-O0-v5747: nested patterns of indexed
# families (act.nu), the gate's act.nu alternative, Qfix after repairs, absurd patterns by clause
# evaluation; Bend 2.0.39), emitted by agda2bend's run/a2b/ev-nu/requeue.sh (unit a2b-requeue5747:
# PLFA, agda-algebras, then the standard library and agda-categories), into transcripts
# (2026-10-29 22:50; the user's goal 11388, the most Bend code).  Every module's text (a module an
# earlier run has may check more declarations now); decl-new sees every earlier a2b stream's train
# units, so only declarations no earlier run has become units.  Then a2bplfa3.sh's steps (cap,
# trim, check, render).  Waits for requeue.sh's emit of the corpus and for the stream before it.
#   a2bv.sh plfa     a2bplfa4: corpus-plfa-v5747 (after ana-a2bplfa3)
#   a2bv.sh aa       a2baa3:   corpus-aa-v5747, agda-algebras' own modules (after ana-a2baa2)
#   a2bv.sh stdlib   a2bm9:    corpus1v (after ana-a2bm8, ana-a2bplfa4, ana-a2baa3)
# mix6.sh adds run/v6/transcripts-NAME/bend/transcripts.train.nul.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
K=${1:?usage: a2bv.sh plfa|aa|stdlib}
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
A=/home/hhefesto/src/agda2bend
case $K in
  plfa)   N=a2bplfa4; C=corpus-plfa-v5747; X=export-plfa; PREV="ana-a2bplfa3" ;;
  aa)     N=a2baa3;   C=corpus-aa-v5747;   X=export-aa;   PREV="ana-a2baa2" ;;
  stdlib) N=a2bm9;    C=corpus1v;          X=export2s;    PREV="ana-a2bm8 ana-a2bplfa4 ana-a2baa3" ;;
  *) echo "a2bv.sh: $K: plfa, aa or stdlib"; exit 2 ;;
esac
U=run/v6/$N; T=run/v6/transcripts-$N; SRC=run/v5/clean/src/$N
L=$A/run/a2b/ev-nu/requeue.log
mkdir -p $U $T/bend
# requeue.sh logs "[time] KEY: exit N" when KEY's emit ends
while ! grep -q "] $K: exit" $L 2>/dev/null; do
  systemctl --user is-active -q a2b-requeue5747 || { say "$N: a2b-requeue5747 is not running and $K's emit has not ended"; exit 1; }
  sleep 300
done
for u in $PREV; do while systemctl --user is-active -q $u; do sleep 300; done; done
grep -q "] $K: exit 0" $L || { say "$N: $C did not end well: $(grep "] $K: exit" $L)"; exit 1; }
say "$N: $C ended: $(tail -n 1 $A/run/a2b/$C.log | cut -c1-200)"
if [ ! -s $U/all.jsonl ]; then
  (cd $A && run/a2b/bin/agda2bend-O0-v5747 corpus /home/hhefesto/src/ana/$U/all.jsonl run/a2b/$X run/a2b/$C) > $U/corpus.log 2>&1 || { say "$N corpus FAILED"; exit 1; }
  tail -n 1 $U/corpus.log
fi
if [ ! -s $U/raw/bend.jsonl ]; then
  python3 -I - $U/all.jsonl $U/new.jsonl $K <<'PY' || { say "$N new FAILED"; exit 1; }
import sys, json, collections
c = collections.Counter()
with open(sys.argv[2], 'w', encoding='utf-8') as o:
    for l in open(sys.argv[1], encoding='utf-8'):
        i = json.loads(l)['id']
        c['modules'] += 1
        # agda-algebras' export has the standard library modules it imports: a2bm9 has those
        if sys.argv[3] == 'aa' and not i.startswith('a2b:agda-algebras/src/'): c['not agda-algebras'] += 1; continue
        o.write(l); c['new'] += 1
print(sys.argv[3], dict(c))
PY
  run/v2/gcroot-bend-corpus-v2/bin/bend-corpus-v2 raw $U/raw $U/new.jsonl > $U/raw.log 2>&1 || { say "$N raw FAILED"; exit 1; }
  cat $U/raw/summary.txt
fi
if [ ! -s $T/$N.jsonl ] || [ ! -d $SRC ]; then
  rm -rf $SRC.tmp
  if [ $K = stdlib ]; then
    # as a2bm8.sh: a2bm8's tree (a2bm7's, a2bmf's) and corpus1v's emitted modules over it; ids the dotted path
    BASE=run/v5/clean/src/a2bm8; [ -d $BASE ] || BASE=run/v5/clean/src/a2bm7; [ -d $BASE ] || BASE=run/v5/clean/src/a2bmf
    python3 -I - $U/raw/bend.jsonl $T/$N.jsonl $BASE $SRC.tmp $A/run/a2b/$C/src <<'PY' || { say "$N tree FAILED"; exit 1; }
import sys, json, os, re, shutil, collections
inp, out, base, tree, c1t = sys.argv[1:6]
shutil.copytree(base, tree)
c = collections.Counter()
with open(out, 'w', encoding='utf-8') as o:
    for l in open(inp, encoding='utf-8'):
        r = json.loads(l)
        m = re.search(r'^# Bend 2 translation of the Agda module (\S+)', r['text'], re.M)
        if not m: c['no module line'] += 1; continue
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
print('a2bm9:', dict(c))
PY
  else
    # as a2bplfa3.sh/a2baa2.sh: the corpus copies as the tree's mods/; ids their paths there
    python3 -I - $U/raw/bend.jsonl $T/$N.jsonl $A/run/a2b/$C/corpus $SRC.tmp <<'PY' || { say "$N tree FAILED"; exit 1; }
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
print(dict(c), 'tree modules', len(where))
PY
  fi
  rm -rf $SRC; mv $SRC.tmp $SRC
fi
E="CORPUS=$T/$N.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "$N sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "$N units"; env $E CHUNK=25 UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
SEENX=; for x in run/v6/transcripts-a2bm6 run/v6/transcripts-a2bm7 run/v6/transcripts-a2bm8 run/v6/transcripts-a2bplfa run/v6/transcripts-a2bplfa2 run/v6/transcripts-a2bplfa3 run/v6/transcripts-a2bplfa4 run/v6/transcripts-a2baa run/v6/transcripts-a2baa2 run/v6/transcripts-a2baa3 run/v6/transcripts-a2bum; do
  [ $x = $T ] && continue; [ -e $x/bend/results.train.nul ] && SEENX="$SEENX seen=$x/bend/results.train.nul"; done
say "$N: seen also:$SEENX"
if [ ! -e $T/bend/units.decl.nul ]; then
  say "$N decl-new held/seen"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5/bend/results.train.nul seen=run/v5/transcripts-a2bm5/bend/results.train.nul $SEENX > $T/decl.log 2>&1 || { say "decl-new FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "$N decl-new cap"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.decl.nul $T/bend/units.nul cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  mv $T/bend/units.nul $T/bend/units.nul.full
  python3 -I run/v5/clean/trim-mutants.py $T/bend/units.nul.full $T/bend/units.nul > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
fi
say "$N check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "$N DONE"
