#!/usr/bin/env bash
# The CPU half of run7go.sh's gate, run as soon as run7.sh has R7, so a failure shows tonight and not after the
# user's approval (the user, 11-15: "be ready to train on my approval"; 21:40: "Wait for your OK in the morning").
# TrainDense's own reading of R7valid (bend/tests/validfixed.bend, as run7go.sh line 51 runs it), then R7's plan,
# the checkpoint's sum and the credit.  Waits on ana-r7chain2; a thin shim.  Nothing rented, nothing started on a box;
# run7go.sh runs the same check again before it rents.
cd /home/hhefesto/src/ana || exit 1
say() { echo "$(date '+%F %T') $*"; }
L=run/v9/run7.log; P=run/v9/R7; VC=run/v9/R7valid/shard-0-fp100m.corpus; PL=$P/plan-fp100m-b16-windows.tsv
VF=run/v9/vf/validfixed; CK=run/v9/run6/out/r6-step115000.checkpoint
SUM=17a110101bc04e716868f2d1c53e022390e6931b23b1f16ee6a03475d670f73b
ready() { grep -q "end: $P is ready" $L 2>/dev/null; }
until ready; do
  systemctl --user -q is-active ana-r7chain2 || break
  sleep 300
done
ready || { say "r7vf: run7 ended without R7 ($(tail -n 1 $L 2>/dev/null))"; exit 1; }
say "r7vf: $(tail -n 1 $L)"
[ -s $PL ] && say "r7vf: plan $(head -n 1 $PL | cut -c1-120)" || say "r7vf: FAILED: no $PL"
[ -s $VC ] || { say "r7vf: FAILED: no $VC"; exit 1; }
[ -x $VF ] || { run/v5/gcroot-bend-2.0.39/bin/bend bend/tests/validfixed.bend -o $VF > run/v9/vf/build.log 2>&1 \
  || { say "r7vf: FAILED: validfixed.bend did not build"; exit 1; }; }
VALID_CORPUS=$VC TOKENIZER_FILE=weights/code32k.bpe timeout 1800 $VF > run/v9/vf/r7valid-pre.log 2>&1
grep -q 'fixed windows of' run/v9/vf/r7valid-pre.log \
  && say "r7vf: CPU: $(grep 'fixed windows of' run/v9/vf/r7valid-pre.log | sed 's/^\[[^]]*\] //')" \
  || say "r7vf: FAILED: TrainDense does not read $VC on the CPU (run/v9/vf/r7valid-pre.log: $(tail -n 1 run/v9/vf/r7valid-pre.log))"
[ "$(sha256sum $CK | cut -c1-64)" = $SUM ] && say "r7vf: checkpoint r6-step115000 sum ok" || say "r7vf: FAILED: $CK sum"
say "r7vf: Vast credit \$$($HOME/.local/share/vastai-venv/bin/vastai show user --raw 2>/dev/null | jq -r .credit)"
