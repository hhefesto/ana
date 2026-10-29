#!/usr/bin/env bash
# agda-algebras through agda2bend (2026-10-29; the user's goal 11388, the most Bend code): ualib/agda-algebras
# c761767 (universal algebra, 341 modules, Apache-2.0; its LICENSE-data grants machine-extracted corpora under
# Apache-2.0 or CC0, ML training named), exported by ~/src/agda2bend/run/a2b/ev-aa/aaexp.sh (export-aa, whose
# stdlib modules are export3's; 340 modules, AlternatingGroup5.Tables over the size limit) and emitted by
# ev-aa/aaemit.sh (unit a2b-aaemit: corpus-aa, bin/agda2bend-O0-j4, agda2bend with J).  As a2baa.sh:
# corpus ids a2b:agda-algebras/src/PATH.bend (ana holds none of it out), less a2b-s's ids (the stdlib
# modules), raw's holdout, tree clean/src/a2baa (corpus-aa's corpus copies, the stdlib ones included,
# under mods/), units/decl-new/cap/trim/check: run/v6/transcripts-a2baa.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
A=/home/hhefesto/src/agda2bend
U=run/v6/a2baa; T=run/v6/transcripts-a2baa; SRC=run/v5/clean/src/a2baa
mkdir -p $U $T/bend
while systemctl --user is-active -q a2b-aaemit; do sleep 300; done
say "a2baa: a2b-aaemit ended: $(tail -2 $A/run/a2b/ev-aa/aaemit.log | cut -c1-200 | tr '\n' ' ')"
grep -q 'emit exit 0' $A/run/a2b/ev-aa/aaemit.log || { say "a2baa: a2b-aaemit did not end well"; exit 1; }
if [ ! -s $U/all.jsonl ]; then
  (cd $A && run/a2b/bin/agda2bend-O0-j4 corpus /home/hhefesto/src/ana/$U/all.jsonl run/a2b/export-aa run/a2b/corpus-aa) > $U/corpus.log 2>&1 || { say "a2baa corpus FAILED"; exit 1; }
  tail -1 $U/corpus.log
fi
if [ ! -s $U/raw/bend.jsonl ]; then
  python3 -I - run/v5/a2b-s/bend.jsonl $U/all.jsonl $U/new.jsonl <<'PY' || { say "a2baa new FAILED"; exit 1; }
import sys, json, collections
old = {json.loads(l)['id'] for l in open(sys.argv[1], encoding='utf-8')}
c = collections.Counter()
with open(sys.argv[3], 'w', encoding='utf-8') as o:
    for l in open(sys.argv[2], encoding='utf-8'):
        i = json.loads(l)['id']
        c['modules'] += 1
        if i in old: c['in a2b-s'] += 1; continue
        if not i.startswith('a2b:agda-algebras/src/'): c['not agda-algebras ' + i] += 1; continue
        o.write(l); c['new'] += 1
print('a2baa:', dict(c))
PY
  run/v2/gcroot-bend-corpus-v2/bin/bend-corpus-v2 raw $U/raw $U/new.jsonl > $U/raw.log 2>&1 || { say "a2baa raw FAILED"; exit 1; }
  cat $U/raw/summary.txt
fi
if [ ! -s $T/a2baa.jsonl ] || [ ! -d $SRC ]; then
  rm -rf $SRC.tmp
  python3 -I - $U/raw/bend.jsonl $T/a2baa.jsonl $A/run/a2b/corpus-aa/corpus $SRC.tmp <<'PY' || { say "a2baa tree FAILED"; exit 1; }
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
print('a2baa:', dict(c), 'tree modules', len(where))
PY
  rm -rf $SRC; mv $SRC.tmp $SRC
fi
E="CORPUS=$T/a2baa.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "a2baa sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "a2baa units"; env $E CHUNK=25 UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
if [ ! -e $T/bend/units.decl.nul ]; then
  say "a2baa decl-new held/seen"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5 seen=run/v5/transcripts-a2bm5/bend/results.train.nul > $T/decl.log 2>&1 || { say "decl-new FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "a2baa decl-new cap"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.decl.nul $T/bend/units.nul cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  mv $T/bend/units.nul $T/bend/units.nul.full
  python3 -I run/v5/clean/trim-mutants.py $T/bend/units.nul.full $T/bend/units.nul > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
fi
say "a2baa check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "a2baa DONE"
