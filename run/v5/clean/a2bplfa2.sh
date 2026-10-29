#!/usr/bin/env bash
# PLFA again, agda2bend 56435f2 (O0-j44: forced patterns, NonZero absurdities, dotted fields at pattern variables, multi-column
# coverage, unique record constructors; Bend 2.0.39), every module of the cone, the stdlib ones too: decl-new
# drops what a2b-s (transcripts-a2bm5) and the first PLFA run (transcripts-a2bplfa) have, so only the
# declarations the newer translator gets are new units (2026-10-29 08:30).
# Was: PLFA through agda2bend (2026-10-29; the user's goal 11388, the most Bend code): plfa/plfa.github.io
# 1c39b1e (src/plfa part1-3, 25 modules; stdlib 2.1 code, all 25 check on nixpkgs' stdlib 2.3), exported
# and emitted by ~/src/agda2bend/run/a2b/ev-plfa/plfaexp.sh (unit a2b-plfa: export-plfa, whose stdlib
# modules are export3's; corpus-plfa, the 25 modules' cones, bin/agda2bend-O0-um).  As a2bum.sh:
# corpus ids a2b:plfa/src/plfa/PATH.bend (ana holds out plfa/src/plfa/stretch), less a2b-s's ids
# (the stdlib modules), raw's holdout, tree clean/src/a2bplfa (corpus-plfa's corpus copies, the
# stdlib ones included, under mods/), units/decl-new/cap/trim/check: run/v6/transcripts-a2bplfa.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
A=/home/hhefesto/src/agda2bend
U=run/v6/a2bplfa2; T=run/v6/transcripts-a2bplfa2; SRC=run/v5/clean/src/a2bplfa2
mkdir -p $U $T/bend
while systemctl --user is-active -q a2b-plfa44; do sleep 300; done
say "a2bplfa2: a2b-plfa44 ended: $(tail -2 $A/run/a2b/corpus-plfa-j44.log | cut -c1-200 | tr '\n' ' ')"
grep -q 'emit exit 0' $A/run/a2b/corpus-plfa-j44.log || { say "a2bplfa2: a2b-plfa44 did not end well"; exit 1; }
if [ ! -s $U/all.jsonl ]; then
  (cd $A && run/a2b/bin/agda2bend-O0-j44 corpus /home/hhefesto/src/ana/$U/all.jsonl run/a2b/export-plfa run/a2b/corpus-plfa-j44) > $U/corpus.log 2>&1 || { say "a2bplfa2 corpus FAILED"; exit 1; }
  tail -1 $U/corpus.log
fi
if [ ! -s $U/raw/bend.jsonl ]; then
  python3 -I - run/v5/a2b-s/bend.jsonl $U/all.jsonl $U/new.jsonl <<'PY' || { say "a2bplfa2 new FAILED"; exit 1; }
import sys, json, collections
old = {json.loads(l)['id'] for l in open(sys.argv[1], encoding='utf-8')}
c = collections.Counter()
with open(sys.argv[3], 'w', encoding='utf-8') as o:
    for l in open(sys.argv[2], encoding='utf-8'):
        i = json.loads(l)['id']
        c['modules'] += 1
        c['in a2b-s' if i in old else 'not in a2b-s'] += 1
        o.write(l); c['new'] += 1
print('a2bplfa2:', dict(c))
PY
  run/v2/gcroot-bend-corpus-v2/bin/bend-corpus-v2 raw $U/raw $U/new.jsonl > $U/raw.log 2>&1 || { say "a2bplfa2 raw FAILED"; exit 1; }
  cat $U/raw/summary.txt
fi
if [ ! -s $T/a2bplfa.jsonl ] || [ ! -d $SRC ]; then
  rm -rf $SRC.tmp
  python3 -I - $U/raw/bend.jsonl $T/a2bplfa.jsonl $A/run/a2b/corpus-plfa-j44/corpus $SRC.tmp <<'PY' || { say "a2bplfa2 tree FAILED"; exit 1; }
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
print('a2bplfa2:', dict(c), 'tree modules', len(where))
PY
  rm -rf $SRC; mv $SRC.tmp $SRC
fi
E="CORPUS=$T/a2bplfa.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "a2bplfa2 sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "a2bplfa2 units"; env $E CHUNK=25 UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
if [ ! -e $T/bend/units.decl.nul ]; then
  say "a2bplfa2 decl-new held/seen"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5/bend/results.train.nul seen=run/v5/transcripts-a2bm5/bend/results.train.nul seen=run/v6/transcripts-a2bplfa/bend/results.train.nul > $T/decl.log 2>&1 || { say "decl-new FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "a2bplfa2 decl-new cap"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.decl.nul $T/bend/units.nul cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  mv $T/bend/units.nul $T/bend/units.nul.full
  python3 -I run/v5/clean/trim-mutants.py $T/bend/units.nul.full $T/bend/units.nul > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
fi
say "a2bplfa2 check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "a2bplfa2 DONE"
