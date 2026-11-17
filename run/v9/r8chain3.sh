#!/usr/bin/env bash
# R8's chain, third (2026-11-17 05:5x; docs/r8/PLAN.md).  The user, 11-17: "Assess the corpus", "Get more filler
# text if needed", "Category theory and algorithm text books", "Fix and prompt me when ready to train".  Waits for
# the prose cut again (ana-r8prose4: DeLatex.bend keeps a book's own macros' text; the eleven books of dl/books8)
# and the private pairs' pass (ana-r8priv), sets the first try's R8 aside (R8.v1: its packing failed on 99
# shards), then run8.sh (the filler cut into pieces, bend/NulFilter.bend) and R8's CPU gate.  Rents nothing.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
active() { local u; for u in "$@"; do systemctl --user is-active -q $u && return 0; done; return 1; }
while active ana-r8prose4 ana-r8priv; do sleep 60; done
[ -s run/v9/theory8/prose/files-hi.nul.stats ] || { say "FAILED: the prose (run/v9/theory8/prose.log)"; exit 1; }
say "prose: $(tr '\n' ' ' < run/v9/theory8/prose/files-hi.nul.stats)"
[ -e run/v9/R8.v1 ] || { [ -d run/v9/R8 ] && mv run/v9/R8 run/v9/R8.v1 && mv run/v9/R8.log run/v9/R8.v1.log; }
TICK=60 bash run/v9/run8.sh > run/v9/run8.log 2>&1 || { say "FAILED: run8.sh (run/v9/run8.log)"; exit 1; }
say "run8.sh: $(tail -n 1 run/v9/run8.log)"
VF=run/v9/vf/validfixed
VALID_CORPUS=run/v9/R8valid/shard-0-fp100m.corpus TOKENIZER_FILE=weights/code32k.bpe timeout 1800 $VF > run/v9/r8vf.log 2>&1
grep -q "fixed windows of" run/v9/r8vf.log && say "validfixed: $(grep -m1 "fixed windows of" run/v9/r8vf.log)" || say "FAILED: TrainDense does not read R8valid on the CPU (run/v9/r8vf.log)"
head -n 1 run/v9/R8/plan-fp100m-b16-windows.tsv | cut -c1-80
say "end: R8 is built; nothing rented"
