#!/usr/bin/env bash
# train-cloud-diloco.sh — launch one trainer per GPU and let them train as one
# run by periodic parameter averaging (see FormalTransformer.Diloco).
#
# Two PROCESSES, never two threads and never two contexts in one process:
# CudaBlasOps caches a single process-global cuBLAS handle with no destroy
# path, bound to whichever CUDA context ran the first GEMM, so a second context
# inside one process is a use-after-free waiting to happen.  The ranks are
# separated with CUDA_VISIBLE_DEVICES, which is also the only thing that makes
# the GEMM backend address a specific device -- it does not read FUT_DEVICE.
#
# Both ranks run the same plan and the same steps.  Rank 0 owns the checkpoint;
# the others follow it and wait at each shard boundary for it to be written,
# because the trainer reloads the checkpoint from disk for every shard.
#
# Usage:
#   TRAIN_ENV_FILE=deploy/bpe460m.env deploy/train-cloud-diloco.sh
#
# Env (beyond everything train-cloud.sh reads):
#   DILOCO_WORLD=2      ranks, one per GPU
#   DILOCO_H=30         inner steps between synchronizations
#   DILOCO_OUTER_LR=0.7 outer Nesterov step size
#   DILOCO_MOMENTUM=0.9 outer Nesterov momentum
#   DILOCO_DIR          exchange directory; keep it on tmpfs (/dev/shm)
#   GPUS="0 1"          CUDA device ids, one per rank, in rank order
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

WORLD="${DILOCO_WORLD:-2}"
GPUS="${GPUS:-$(seq -s' ' 0 $((WORLD - 1)))}"
DILOCO_DIR="${DILOCO_DIR:-/dev/shm/ana-diloco}"
read -r -a gpu_list <<< "$GPUS"

if [ "${#gpu_list[@]}" -ne "$WORLD" ]; then
  echo "train-cloud-diloco: GPUS has ${#gpu_list[@]} entries but DILOCO_WORLD=$WORLD" >&2
  exit 1
fi

# Stale exchange files from a dead run would let a rank sail past a barrier it
# should have waited at, so the directory starts empty every launch.  It holds
# one parameter vector per rank (1.85 GB each at 463M), hence tmpfs.
rm -rf "$DILOCO_DIR"
mkdir -p "$DILOCO_DIR"

# PERSISTENT=1 is required, not merely faster: the shard-boundary barrier lives
# in train-plan's loop, which is the code path PERSISTENT=1 selects.
export PERSISTENT=1
export DILOCO_WORLD DILOCO_DIR
export DILOCO_H="${DILOCO_H:-30}"
export DILOCO_OUTER_LR="${DILOCO_OUTER_LR:-0.7}"
export DILOCO_MOMENTUM="${DILOCO_MOMENTUM:-0.9}"
export DILOCO_TIMEOUT="${DILOCO_TIMEOUT:-1800}"

echo "train-cloud-diloco: world=$WORLD gpus=$GPUS dir=$DILOCO_DIR"
echo "train-cloud-diloco: H=$DILOCO_H outer_lr=$DILOCO_OUTER_LR momentum=$DILOCO_MOMENTUM"

pids=()
for rank in $(seq 0 $((WORLD - 1))); do
  log="run/train-rank$rank.log"
  # Two processes writing one Futhark kernel cache race and can corrupt it.
  CUDA_VISIBLE_DEVICES="${gpu_list[$rank]}" \
  DILOCO_RANK="$rank" \
  FUT_CACHE="run/futhark-cuda-rank$rank.cache" \
    nohup deploy/train-cloud.sh > "$log" 2>&1 &
  pid=$!
  pids+=("$pid")
  echo "$pid" > "run/diloco-rank$rank.pid"
  echo "train-cloud-diloco: rank $rank -> GPU ${gpu_list[$rank]}, pid $pid, log $log"
done

echo
echo "Watch:    tail -f run/train-rank0.log"
echo "Drift:    deploy/diloco-check.sh"
# Kill by recorded PID.  An unbracketed `pkill -f train-cloud` over ssh matches
# the shell running it and takes the session down with the trainers.
echo "Stop:     kill \$(cat run/diloco-rank*.pid)"
echo

status=0
for pid in "${pids[@]}"; do
  wait "$pid" || status=$?
done
echo "train-cloud-diloco: all ranks exited (status $status)"
exit "$status"
