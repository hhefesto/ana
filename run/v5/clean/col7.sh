#!/usr/bin/env bash
# Run 7's collection: the Bend 2 repositories GitHub's code search does not index (2026-10-28; the
# user's goal 11388: the most Bend code).  bendlib/bendlib (217 .bend files, Apache-2.0) has no
# code-search hit at all; hapsland's submodule named it.  tools/corpus-v2/survey/disc7.py lists
# the owners' other repositories (pushed since 08-20), the collected repositories' submodules and
# repository-search hits that no collection knows, and their .bend files (trees API): /tmp/bx/disc7.
# Here, when it is done: classify.py (3 files sampled, Bend 2 markers), the Bend 2 ones that are no
# fork as `repo OWNER/NAME all` in tools/corpus-v2/collect/bend-run7.cfg (run 6's settings, run 6's
# outputs as corpus, its vault known; no hub, no growth: run 6 took those today), then after the
# night run (memory: run 6's collect took 20 GB) `bend-corpus-v2 collect ... all` (vault quarter as
# every run), the history repairs (hist6.py, HIST_M=3), and as col6 in units6.sh: units, decl-new
# held/seen (every run-6 stream seen), cap, trim, history mutants, check, render:
# run/v7/transcripts-col7/bend/transcripts.train.nul, a stream of mix6.sh.
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1 GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false
say() { echo "$(date '+%F %T') $*"; }
B=/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend
D=run/v5/gcroot-deploy-982e162/bin/deploy
CV=run/v5/clean/bend-corpus-v2
H=tools/corpus-v2/hist
V=run/v7; DS=$V/disc; CFG=tools/corpus-v2/collect/bend-run7.cfg
C=$V/collect/bend; SRC=$V/collect/src/bend; T=$V/transcripts-col7
mkdir -p $V
if [ ! -e $DS/classes.done ]; then
  while ! grep -q 'DONE candidates' /tmp/bx/disc7/log.txt 2>/dev/null; do
    systemctl --user is-active -q ana-disc7 || { say "col7: disc7 ended without DONE"; exit 1; }
    sleep 120
  done
  rm -rf $DS; cp -a /tmp/bx/disc7 $DS
  { cat /tmp/bx/survey6/known2.txt; cut -f1 run/v2/raw-new3/src/PINS.tsv run/v4/collect/src/PINS.tsv run/v5/collect/src/PINS.tsv run/v6/collect/src/PINS.tsv; } |
    tr 'A-Z' 'a-z' | sort -u > $DS/known.txt
  say "col7: classify $(wc -l < $DS/repos.tsv) repositories"
  python3 -I tools/corpus-v2/survey/classify.py $DS $DS/known.txt tools/corpus-v2/survey/exclude.txt > $DS/classify.log 2>&1 || { say "classify FAILED"; exit 1; }
  tail -1 $DS/classify.log
  touch $DS/classes.done
fi
if [ ! -s $CFG ]; then
  python3 -I - $DS/classes.tsv $CFG <<'EOF'
import sys
cls, out = sys.argv[1:3]
new = []
for l in open(cls):
    f = l.rstrip('\n').split('\t')
    if len(f) < 11 or f[2] != '2' or f[6]: continue      # Bend 2, no fork
    new.append(f)
new.sort(key=lambda f: f[0].lower())
s = open('tools/corpus-v2/collect/bend-run6.cfg').read().split('\n')
keep = []
for l in s:
    w = l.split()
    if not w or w[0] in ('#',) or l.startswith('#'): continue
    if w[0] in ('repo', 'growth', 'hub', 'sibling', 'upstream'): continue
    keep.append(l)
o = open(out, 'w')
o.write('''# Run 7's new Bend code (2026-10-28):
#
#   bend-corpus-v2 collect tools/corpus-v2/collect/bend-run7.cfg all
#
# from the repository root (run/v5/clean/col7.sh).  The Bend 2 repositories GitHub's code search
# does not index: tools/corpus-v2/survey/disc7.py's candidates (the collected repositories' owners'
# other repositories pushed since 2026-08-20, their submodules, repository search) that no
# collection knows, sampled by classify.py (Bend 2 markers), no fork: %d repositories, `repo ... all`.
# Run 6's settings otherwise; run 6's outputs are corpus, its PINS known, its vault known.
''' % len(new))
for l in keep:
    l = l.replace('run/v6/collect/', 'run/v7/collect/')
    if l.startswith('known '): l += ' run/v6/collect/src/PINS.tsv'
    if l.startswith('vault-known '): l += ' run/v6/collect/bend/vault/repos.txt'
    if l.startswith('big-known '): l += ' run/v6/collect/bend/stage/pre/big.repos'
    if l.startswith('verdicts '): continue
    o.write(l + '\n')
o.write('corpus run/v6/collect/bend/bend.jsonl run/v6/collect/bend/vault/bend.jsonl run/v6/collect/bend/holdout/bend.jsonl\n\n')
for f in new:
    o.write('repo %s all\n# %s files sampled %s, created %s, pushed %s, licence %s\n' % (f[0], f[1], f[3], f[4], f[5], f[7] or '-'))
o.close()
print('col7: %d repositories' % len(new))
EOF
  [ -s $CFG ] || { say "cfg FAILED"; exit 1; }
fi
grep -c '^repo ' $CFG | sed 's/^/col7: repo lines /'
if ! grep -q '^EXIT 0' $V/collect/collect.log 2>/dev/null; then
  # run 6's collect took 20 GB: after the night run (ana-act5-night, to 08:30)
  while systemctl --user is-active -q ana-act5-night; do sleep 120; done
  mkdir -p $V/collect/src; touch $V/collect/src/PINS.tsv
  [ -d $V/collect/keycache ] || cp -a run/v6/collect/keycache $V/collect/keycache
  say "col7: collect"
  { $CV collect $CFG all; echo "EXIT $?"; } >> $V/collect/collect.log 2>&1
  grep -q '^EXIT 0' $V/collect/collect.log || { say "collect FAILED"; tail -5 $V/collect/collect.log; exit 1; }
fi
tail -3 $C/summary.txt 2>/dev/null
[ -s $C/bend.jsonl ] || { say "col7: no train files"; exit 0; }
if ! grep -q 'ALL DONE' $V/hist/hist.log 2>/dev/null; then
  say "col7: history"
  mkdir -p $V/hist
  HIST_M=3 python3 -I $H/hist6.py $V/collect/src/PINS.tsv $V/hist $C/bend.jsonl > $V/hist/hist.log 2>&1
  grep -q 'ALL DONE' $V/hist/hist.log || { say "hist6 FAILED"; exit 1; }
  [ -e $V/hist/hist.nul ] || : > $V/hist/hist.nul
fi
mkdir -p $T
[ -e $T/col7.jsonl ] || cp $C/bend.jsonl $T/col7.jsonl
SEEN=
for h in vault holdout; do
  HJ=$C/$h/bend.jsonl; HT=$T/held/v7-$h
  [ -s $HJ ] || continue
  SEEN="$SEEN held=$HJ"
  if [ ! -e $HT/bend/units.nul ]; then
    mkdir -p $HT
    HE="CORPUS=$HJ OUT=$HT BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
    say "col7 held $h units"
    env $HE $D transcripts sources bend > $HT/sources.log 2>&1 && env $HE CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $HT/units.log 2>&1 || { say "held $h FAILED"; exit 1; }
  fi
  SEEN="$SEEN held=$HT/bend/units.nul"
done
E="CORPUS=$T/col7.jsonl OUT=$T BEND=$B BEND_SRC=$SRC MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0"
if [ ! -e $T/bend/units.all.nul ]; then
  say "col7 sources"; env $E $D transcripts sources bend > $T/sources.log 2>&1 || { say "sources FAILED"; exit 1; }
  say "col7 units"; env $E CHUNK=${UCHUNK:-6} UNIT_JOBS=4 $D transcripts units bend > $T/units.log 2>&1 || { say "units FAILED"; exit 1; }
  mv $T/bend/units.nul $T/bend/units.all.nul
fi
if [ ! -e $T/bend/units.decl.nul ]; then
  for x in col6:units6 upg6:upg6 upg2:upg2 gav6:gav6 upg6b:upg6b br6:br6 sub6:sub6 brf6:brf6; do
    while [ ! -s run/v6/transcripts-${x%%:*}/bend/units.decl.nul ] && systemctl --user is-active -q ana-${x#*:}; do sleep 60; done
  done
  for x in run/v5/transcripts-port5 run/v5/transcripts-a2bm5; do [ -e $x/bend/results.train.nul ] && SEEN="$SEEN seen=$x/bend/results.train.nul"; done
  for x in col6 upg6 upg2 gav6 upg6b br6 sub6 brf6; do [ -s run/v6/transcripts-$x/bend/units.decl.nul ] && SEEN="$SEEN seen=run/v6/transcripts-$x/bend/units.decl.nul"; done
  for h in run/v6/transcripts-col6/held/v6-vault run/v6/transcripts-col6/held/v6-holdout; do [ -e $h/bend/units.nul ] && SEEN="$SEEN held=$h/bend/units.nul"; done
  say "col7 decl-new held/seen"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.all.nul $T/bend/units.decl.nul $(cat run/v5/leak/held.args) held=run/v6/collect/bend/vault/bend.jsonl held=run/v6/collect/bend/holdout/bend.jsonl seen=run/v2/results/bend.train.nul seen=run/transcripts-py2bend/bend/results.train.nul seen=run/v5/transcripts-collect5/bend/results.train.nul seen=run/v5/transcripts-own5/bend/results.train.nul $SEEN > $T/decl.log 2>&1 || { say "decl FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul ]; then
  say "col7 decl-new cap"
  run/v5/gcroot-bend-corpus-v2-decl2/bin/bend-corpus-v2 decl-new $T/bend/units.decl.nul $T/bend/units.nul cap=:64 > $T/cap.log 2>&1 || { say "cap FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.full ]; then
  mv $T/bend/units.nul $T/bend/units.nul.full
  python3 -I run/v5/clean/trim-mutants.py $T/bend/units.nul.full $T/bend/units.nul > $T/trim.log 2>&1 || { say "trim FAILED"; exit 1; }
fi
if [ ! -e $T/bend/units.nul.prehist ]; then
  python3 -I $H/hist-merge.py $T/bend/units.nul $V/hist/hist.nul $T/bend/units.nul.h > $T/hist-merge.log 2>&1 || { say "hist-merge FAILED"; exit 1; }
  grep -v similarity $T/hist-merge.log
  mv $T/bend/units.nul $T/bend/units.nul.prehist; mv $T/bend/units.nul.h $T/bend/units.nul; mv $T/bend/units.nul.h.hist $T/bend/units.nul.hist
fi
if [ ! -e $T/bend/results.nul.prepick ]; then
  say "col7 check"
  env $E CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 $D transcripts check bend > $T/check.log 2>&1 || { say "check FAILED"; exit 1; }
  python3 -I $H/hist-pick.py $T/bend/results.nul $T/bend/units.nul.hist $T/bend/results.nul.p > $T/hist-pick.log 2>&1 || { say "hist-pick FAILED"; exit 1; }
  mv $T/bend/results.nul $T/bend/results.nul.prepick; mv $T/bend/results.nul.p $T/bend/results.nul; mv $T/bend/results.nul.p.hist-ids $T/bend/results.hist-ids
  cat $T/hist-pick.log
fi
say "col7 check+render"
env $E TRANSCRIPT_FORMAT=2 COPIES=4 CHECK_PROCS=${CHECK_PROCS:-6} CHECK_JOBS=1 CHUNK=25 UNIT_JOBS=4 $D transcripts all bend > $T/all.log 2>&1 || { say "all FAILED"; exit 1; }
say "col7 DONE"
