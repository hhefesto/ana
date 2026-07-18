#!/usr/bin/env bash
# step-gate.sh — fail-fast GPU compatibility gate. Run BEFORE transferring the
# full corpora or starting any paid training.
#
# Warms the Futhark context under its own timeout, then runs ONE hard-capped
# training step on a single shard. This separates cold NVRTC compilation from
# the low-occupancy execution failure observed on Ampere at bpe10m scale.
#
# Usage:  deploy/step-gate.sh CORPUS TOKENIZER.bpe
# Env:    SIZE=bpe10m  COMPILE_TIMEOUT=300  GATE_TIMEOUT=180
#         GATE_VALIDATION_WINDOWS=1
#         FUT_CACHE=run/futhark-cuda.cache  FUT_TUNING=path
#
# Exit: 0 = pass; 124 = context compilation or the step timed out;
#       anything else = the trainer itself failed (see its output).
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 CORPUS TOKENIZER.bpe" >&2
  exit 1
fi
corpus=$1
tokenizer=$2

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
if [ -f run/cloud-env.sh ]; then
  # shellcheck disable=SC1091
  . run/cloud-env.sh
fi

trainer="${TRAINER:-result/bin/formal-transformer-cuda}"
[ -x "$trainer" ] || { echo "step-gate: $trainer missing — run deploy/cloud-init.sh first." >&2; exit 1; }

timeout_s="${GATE_TIMEOUT:-180}"
compile_timeout_s="${COMPILE_TIMEOUT:-300}"
size="${SIZE:-bpe10m}"
cache="${FUT_CACHE:-run/futhark-cuda.cache}"
mkdir -p "$(dirname "$cache")"
ckpt="$(mktemp /tmp/step-gate.XXXXXX.checkpoint)"
rm -f "$ckpt"
trap 'rm -f "$ckpt"' EXIT

echo "step-gate: warming CUDA context, hard-capped at ${compile_timeout_s}s..."
rc=0
FUT_CACHE="$cache" timeout "$compile_timeout_s" stdbuf -oL -eL \
  "$trainer" warm-context "$size" || rc=$?

if [ "$rc" -eq 124 ]; then
  echo "step-gate: context compilation exceeded ${compile_timeout_s}s." >&2
  echo "  Preserve the host details and cache; this is not a step-performance verdict." >&2
  exit "$rc"
elif [ "$rc" -ne 0 ]; then
  echo "step-gate: context warm-up failed (rc=$rc); see the output above." >&2
  exit "$rc"
fi

echo "step-gate: one warm-cache training step, hard-capped at ${timeout_s}s..."
TOKENIZER_FILE="$tokenizer" TRAIN_BATCH="${TRAIN_BATCH:-8}" MICRO_BATCH="${MICRO_BATCH:-1}" \
CHECKPOINT_EVERY=1 VALIDATION_WINDOWS="${GATE_VALIDATION_WINDOWS:-1}" FUT_CACHE="$cache" \
  timeout "$timeout_s" stdbuf -oL -eL "$trainer" train "$corpus" "$ckpt" 1 "$size" || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "step-gate: PASS — the kernel executes on this GPU. Benchmark next."
elif [ "$rc" -eq 124 ]; then
  echo "step-gate: FAIL — the warm-cache step exceeded ${timeout_s}s." >&2
  echo "  Do not transfer corpora or start training. Run deploy/profile-cuda.sh" >&2
  echo "  ladder and preserve its report; this is a scheduling/occupancy verdict," >&2
  echo "  not evidence that a different GPU architecture will or will not help." >&2
else
  echo "step-gate: trainer failed (rc=$rc) — not a hang; see the output above." >&2
fi
exit "$rc"
