#!/usr/bin/env bash
# UNWIRED 2026-10-15: replaced by `bend-ops stage box HOST PORT` (bend/Box/Stage.bend; `bend-ops sim stage box` runs a copy of this script without these two lines against it in the sandbox: the same box files, calls and lines but bend-box built there, the plan's Phase 1b); kept for reference
exit 2
# Stage the fp100m run on a rented box (bend/gpu/fp.sh runs it there):
# the trainer and the gate program as C (built on the box with its clang
# and CUDA), fp.sh, the tokenizer and the held-out transcripts by scp, then
# the plan and the shards by bend-push (plan order, 0.64 GB). traind-next.c is
# traind.c (one program since TrainDense.bend has TRAIN_NEXT: `fp.sh again`
# builds it, run 3's S2). The eval corpora are run 1's held-out transcripts and
# corpus v2's (run/eval/v2-*.corpus: format 2's held-out transcripts and the
# vault, for `ECORPUS=... fp.sh eval`). Run from the repository root, once the
# box answers ssh:
#   bend/gpu/fp-stage.sh [user@]host port
# BOX_ENV names bend-push's settings (default bend/gpu/fp100m-box.env, run 1;
# bend/gpu/v2-box.env is run 2).
# The box's working directory is ~/ana (bend-push's REMOTE_DIR).
set -euo pipefail
host="${1:?usage: fp-stage.sh [user@]host port}"
port="${2:?usage: fp-stage.sh [user@]host port}"
S=$(mktemp -d)
echo "== C from the pinned compiler"
(cd bend && nix run ..#bend -- TrainDense.bend -o "$S/traind.c" && nix run ..#bend -- tests/dense.bend -o "$S/dense.c")
ls -la "$S"
echo "== link check"
TRAIN_ENV_FILE=${BOX_ENV:-bend/gpu/fp100m-box.env} nix run .#deploy -- push link "$host" "$port"
echo "== scp"
ssh -p "$port" "$host" "mkdir -p ana/weights ana/run/eval ana/run/fp100m ana/out"
cp "$S/traind.c" "$S/traind-next.c"
scp -P "$port" "$S/traind.c" "$S/traind-next.c" "$S/dense.c" bend/gpu/fp.sh "$host:ana/"
scp -P "$port" weights/code32k.bpe "$host:ana/weights/"
scp -P "$port" run/eval/transcript-fp.corpus run/eval/transcript-next.corpus run/eval/v2-*.corpus "$host:ana/run/eval/"
echo "== the corpus, in plan order"
TRAIN_ENV_FILE=${BOX_ENV:-bend/gpu/fp100m-box.env} SKIP_LINK_CHECK=1 nix run .#deploy -- push "$host" "$port"
echo "staged; on the box: cd ana && ./fp.sh gate && ./fp.sh time && ./fp.sh run"
rm -rf "$S"
