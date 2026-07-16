#!/usr/bin/env bash
# step-gate.sh — fail-fast GPU compatibility gate. Run BEFORE transferring the
# full corpora or starting any paid training.
#
# Runs ONE hard-capped training step on a single shard. On an incompatible GPU
# the Futhark gradient kernel can compile yet hang at execution with the GPU
# pegged at 100% (observed on Blackwell sm_120, 2026-07-15); the timeout turns
# that failure mode into a fast, unambiguous verdict instead of a silent
# money-burner. A pass means the kernel genuinely executes end to end.
#
# Usage:  deploy/step-gate.sh CORPUS TOKENIZER.bpe
# Env:    SIZE=bpe10m  GATE_TIMEOUT=180  FUT_CACHE=run/futhark-cuda.cache
#
# Exit: 0 = pass; 124 = step timed out (wrong GPU — destroy the instance);
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

trainer=result/bin/formal-transformer-cuda
[ -x "$trainer" ] || { echo "step-gate: $trainer missing — run deploy/cloud-init.sh first." >&2; exit 1; }

timeout_s="${GATE_TIMEOUT:-180}"
ckpt="$(mktemp -u /tmp/step-gate.XXXXXX.checkpoint)"
trap 'rm -f "$ckpt"' EXIT

echo "step-gate: one training step, hard-capped at ${timeout_s}s (includes NVRTC compile on a cold cache)..."
rc=0
TOKENIZER_FILE="$tokenizer" TRAIN_BATCH="${TRAIN_BATCH:-8}" MICRO_BATCH="${MICRO_BATCH:-1}" \
CHECKPOINT_EVERY=1 FUT_CACHE="${FUT_CACHE:-run/futhark-cuda.cache}" \
  timeout "$timeout_s" stdbuf -oL -eL "$trainer" train "$corpus" "$ckpt" 1 "${SIZE:-bpe10m}" || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "step-gate: PASS — the kernel executes on this GPU. Benchmark next."
elif [ "$rc" -eq 124 ]; then
  echo "step-gate: FAIL — one step did not finish in ${timeout_s}s; the kernel hangs on" >&2
  echo "  this GPU architecture. DESTROY this instance and rent Ada (RTX 40xx) or" >&2
  echo "  Ampere (RTX 30xx). Do not transfer corpora or train here." >&2
else
  echo "step-gate: trainer failed (rc=$rc) — not a hang; see the output above." >&2
fi
exit "$rc"
