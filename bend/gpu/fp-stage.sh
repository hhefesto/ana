#!/usr/bin/env bash
# Stage the fp100m run on a rented box (bend/gpu/fp.sh runs it there):
# the trainer and the gate program as C (built on the box with its clang
# and CUDA), fp.sh, the tokenizer and the held-out transcripts by scp, then
# the plan and the shards by bend-push (plan order, 0.64 GB). Run from the
# repository root, once the box answers ssh:
#   bend/gpu/fp-stage.sh [user@]host port
# The box's working directory is ~/formalTransformer (bend-push's REMOTE_DIR).
set -euo pipefail
host="${1:?usage: fp-stage.sh [user@]host port}"
port="${2:?usage: fp-stage.sh [user@]host port}"
S=$(mktemp -d)
echo "== C from the pinned compiler"
(cd bend && nix run ..#bend -- TrainDense.bend -o "$S/traind.c" && nix run ..#bend -- tests/dense.bend -o "$S/dense.c")
ls -la "$S"
echo "== link check"
TRAIN_ENV_FILE=bend/gpu/fp100m-box.env nix run .#deploy -- push link "$host" "$port"
echo "== scp"
ssh -p "$port" "$host" "mkdir -p formalTransformer/weights formalTransformer/run/eval formalTransformer/run/fp100m formalTransformer/out"
scp -P "$port" "$S/traind.c" "$S/dense.c" bend/gpu/fp.sh "$host:formalTransformer/"
scp -P "$port" weights/code32k.bpe "$host:formalTransformer/weights/"
scp -P "$port" run/eval/transcript-fp.corpus "$host:formalTransformer/run/eval/"
echo "== the corpus, in plan order"
TRAIN_ENV_FILE=bend/gpu/fp100m-box.env SKIP_LINK_CHECK=1 nix run .#deploy -- push "$host" "$port"
echo "staged; on the box: cd formalTransformer && ./fp.sh gate && ./fp.sh time && ./fp.sh run"
rm -rf "$S"
