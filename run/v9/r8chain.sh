#!/usr/bin/env bash
# R8's chain (2026-11-17, docs/r8/PLAN.md): waits for the mix (ana-r8mix, run8.sh MIXONLY=1) and the de-LaTeX-ed
# prose (ana-r8prose, run/v9/theory/filler.sh into run/v9/theory8), then run8.sh whole (it resumes: the mix is
# done), and R8's CPU gate (TrainDense's reading of R8valid, as run7go.sh's).  Rents nothing: the user's
# approval first (the user, 11-17: "if there is a clear way to improve the corpus for the size of ana, I want to
# do that before spending money on training").
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
while active ana-r8mix ana-r8prose; do sleep 60; done
grep -q '^rc=0' run/v9/theory8/prose.log || { say "FAILED: the prose (run/v9/theory8/prose.log)"; exit 1; }
[ -e run/v9/mix8/bend.done ] || { say "FAILED: the mix (run/v9/run8mix.log)"; exit 1; }
say "the mix and the prose are done: run8.sh"
TICK=60 bash run/v9/run8.sh > run/v9/run8.log 2>&1 || { say "FAILED: run8.sh (run/v9/run8.log)"; exit 1; }
say "run8.sh: $(tail -n 1 run/v9/run8.log)"
VF=run/v9/vf/validfixed
if [ -x $VF ]; then
  VALID_CORPUS=run/v9/R8valid/shard-0-fp100m.corpus TOKENIZER_FILE=weights/code32k.bpe timeout 1800 $VF > run/v9/r8vf.log 2>&1
  grep -q "fixed windows of" run/v9/r8vf.log && say "validfixed: $(grep -m1 "fixed windows of" run/v9/r8vf.log)" || say "FAILED: TrainDense does not read R8valid on the CPU (run/v9/r8vf.log)"
fi
head -n 1 run/v9/R8/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: R8 is built; nothing rented"
