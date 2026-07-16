#!/usr/bin/env bash
# step-gate.sh — fail-fast GPU compatibility gate. Run BEFORE transferring the
# full corpora or starting any paid training.
#
# Runs ONE hard-capped training step on a single shard. The Futhark gradient
# kernel can compile yet fail to finish a step with the GPU pegged at 100%
# (observed 2026-07-15 on Blackwell sm_120 AND Ampere sm_86 alike — a
# kernel-level pathology at bpe10m scale, not a GPU-arch problem); the timeout
# turns that failure mode into a fast, unambiguous verdict instead of a silent
# money-burner. A pass means the kernel genuinely executes end to end.
#
# Usage:  deploy/step-gate.sh CORPUS TOKENIZER.bpe
# Env:    SIZE=bpe10m  GATE_TIMEOUT=180  FUT_CACHE=run/futhark-cuda.cache
#
# Exit: 0 = pass; 124 = step timed out (kernel too slow — destroy the instance;
#       renting a different GPU will not help);
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
FUT_REJECT_INTRA="${FUT_REJECT_INTRA:-1}" \
  timeout "$timeout_s" stdbuf -oL -eL "$trainer" train "$corpus" "$ckpt" 1 "${SIZE:-bpe10m}" || rc=$?

if [ "$rc" -eq 0 ]; then
  echo "step-gate: PASS — the kernel executes on this GPU. Benchmark next."
elif [ "$rc" -eq 124 ]; then
  echo "step-gate: FAIL — one step did not finish in ${timeout_s}s. Known cause" >&2
  echo "  (2026-07-15): the Futhark vjp gradient kernel is pathologically slow at" >&2
  echo "  bpe10m scale on EVERY tested arch (Blackwell sm_120 and Ampere sm_86 fail" >&2
  echo "  identically) — a kernel/code problem, not the GPU. Renting a different GPU" >&2
  echo "  will NOT fix it. DESTROY this instance; fix the kernel locally first" >&2
  echo "  (see HANDOFF.md). Do not transfer corpora or train here." >&2
else
  echo "step-gate: trainer failed (rc=$rc) — not a hang; see the output above." >&2
fi
exit "$rc"
