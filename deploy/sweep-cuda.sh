#!/usr/bin/env bash
# sweep-cuda.sh — measure where the GPU's time actually goes, and how much
# memory the model needs, before committing to a multi-week rental.
#
# Runs `bench` across MICRO_BATCH x GEMM_NUMERICS while sampling nvidia-smi, and
# writes one TSV row per configuration. A configuration that runs out of memory
# is recorded as "oom" and the sweep continues — mapping that ceiling is one of
# the points of the exercise.
#
# The two columns that answer "are we using the whole GPU" are util_pct and mfu:
#
#   high util, low mfu -> the card is busy doing inefficient work (elementwise
#                         kernels, small attention GEMMs). Kernel-level problem.
#   low util           -> the card is idle waiting on the host. Overhead problem.
#
# The Wikipedia run recorded neither, which is why its "3% MFU is a consequence
# of model size" attribution was never actually tested.
#
# Each configuration sets TRAIN_BATCH = MICRO_BATCH, so every bench step is a
# single forward/backward and tokens/s compares directly across the sweep. Set
# SWEEP_TRAIN_BATCH to pin TRAIN_BATCH instead and measure gradient accumulation.
#
# usage: ./deploy/sweep-cuda.sh CORPUS [SIZE]
#
# Env:
#   MICRO_BATCHES="1 2 4 8 16 32"   micro-batch sizes to try
#   NUMERICS="tf32 bf16"            GEMM_NUMERICS values to try
#   SWEEP_TRAIN_BATCH               pin TRAIN_BATCH (default: track MICRO_BATCH)
#   BENCH_WARMUP=5 BENCH_STEPS=20   passed through to bench
#   PEAK_TF32 PEAK_BF16 PEAK_FP32   TFLOPS for the MFU column; auto-detected for
#                                   known cards, else the mfu column reads "na"
#   TOTAL_TOKENS=5864004480         run length for the cost projection
#   PRICE_PER_HOUR                  $/hr; enables the cost column
#   ORDERING_AB=1                   re-run the best config with GEMM_ORDERING=stream
#   PROFILE=1                       re-run the best config with FUT_PROFILE=1
#   OUT=run/sweep-<gpu>.tsv         where to write results
#   TRAINER                         override the binary
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 CORPUS [SIZE]" >&2
  exit 1
fi

corpus=$1
size=${2:-bpe100m}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# cloud-init.sh records the LD_LIBRARY_PATH that resolves the container's
# injected libcuda.so.1 (empty when the default loader paths already work).
if [ -f run/cloud-env.sh ]; then
  # shellcheck disable=SC1091
  . run/cloud-env.sh
fi

test -f "$corpus" || { echo "sweep-cuda: corpus not found: $corpus" >&2; exit 1; }

trainer="${TRAINER:-$repo_root/result-gemm/bin/formal-transformer-gemm-cuda}"
if [ ! -x "$trainer" ]; then
  echo "sweep-cuda: trainer not executable: $trainer" >&2
  echo "  build it with: BUILD_GEMM_CUDA=1 ./deploy/cloud-init.sh" >&2
  exit 1
fi

command -v nvidia-smi >/dev/null || {
  echo "sweep-cuda: nvidia-smi missing" >&2; exit 1; }

gpu_index=${GPU_INDEX:-0}
gpu_name="$(nvidia-smi -i "$gpu_index" --query-gpu=name --format=csv,noheader | head -n1 | sed 's/^ *//;s/ *$//')"
gpu_total_mib="$(nvidia-smi -i "$gpu_index" --query-gpu=memory.total --format=csv,noheader,nounits | head -n1 | tr -d ' ')"
gpu_slug="$(echo "$gpu_name" | tr ' ' '-' | tr -cd 'A-Za-z0-9-')"

# Dense (non-sparse) tensor-core peaks. cuBLAS here accumulates in FP32
# (CUBLAS_COMPUTE_32F_FAST_TF32 / _FAST_16BF), which on GeForce Ampere runs at
# half the FP16-accumulate rate -- hence the 3090's 71.0 rather than 142. The
# A6000 is the same GA102 die without that restriction, so it lists roughly
# twice the 3090's tensor rates despite similar FP32.
#
# These only scale the mfu column; they do not affect tokens/s or the cost
# projection. Override with PEAK_TF32/PEAK_BF16 if a datasheet disagrees.
case "$gpu_name" in
  *"RTX 4090"*)    def_tf32=82.6 ; def_bf16=165.2 ; def_fp32=82.6 ;;
  *"RTX A6000"*)   def_tf32=77.4 ; def_bf16=154.8 ; def_fp32=38.7 ;;
  *"RTX 3090"*)    def_tf32=35.6 ; def_bf16=71.0  ; def_fp32=35.6 ;;
  *"RTX 5060 Ti"*) def_tf32=23.7 ; def_bf16=47.4  ; def_fp32=23.7 ;;
  *"A100"*)        def_tf32=156.0; def_bf16=312.0 ; def_fp32=19.5 ;;
  *"H100"*)        def_tf32=494.0; def_bf16=989.0 ; def_fp32=67.0 ;;
  *)               def_tf32=""   ; def_bf16=""    ; def_fp32=""   ;;
esac
peak_tf32=${PEAK_TF32:-$def_tf32}
peak_bf16=${PEAK_BF16:-$def_bf16}
peak_fp32=${PEAK_FP32:-$def_fp32}

micro_batches=${MICRO_BATCHES:-"1 2 4 8 16 32"}
numerics_list=${NUMERICS:-"tf32 bf16"}
warmup=${BENCH_WARMUP:-5}
steps=${BENCH_STEPS:-20}
total_tokens=${TOTAL_TOKENS:-5864004480}
price=${PRICE_PER_HOUR:-}
out=${OUT:-run/sweep-$gpu_slug.tsv}
logdir=${LOGDIR:-run/sweep-logs}
fut_cache=${FUT_CACHE:-run/futhark-cuda.cache}

mkdir -p "$logdir" "$(dirname "$out")"

echo "sweep-cuda: gpu=$gpu_name (${gpu_total_mib} MiB) size=$size corpus=$corpus"
echo "sweep-cuda: peaks tf32=${peak_tf32:-na} bf16=${peak_bf16:-na} fp32=${peak_fp32:-na} TFLOPS"
echo "sweep-cuda: micro=[$micro_batches] numerics=[$numerics_list] warmup=$warmup steps=$steps"
echo "sweep-cuda: writing $out"
echo

printf 'gpu\tsize\tnumerics\ttrain_batch\tmicro\tvariant\tstatus\tmedian_s\tp95_s\ttokens_per_s\tgemm_tflops\tmfu_pct\tpeak_mib\tutil_pct\tdays\tcost_usd\n' > "$out"

# --- nvidia-smi sampling -----------------------------------------------------
# Sampled at 200 ms into a file; the run's peak memory and mean utilization come
# from that. memory.used is whole-GPU, so a baseline taken while idle is
# subtracted to keep other processes (there should be none) out of the number.
sampler_pid=""
start_sampler() {
  local file=$1
  : > "$file"
  ( while true; do
      nvidia-smi -i "$gpu_index" \
        --query-gpu=utilization.gpu,memory.used \
        --format=csv,noheader,nounits 2>/dev/null \
        | head -n1 | tr -d ' ' >> "$file"
      sleep 0.2
    done ) &
  sampler_pid=$!
}
stop_sampler() {
  [ -n "$sampler_pid" ] || return 0
  kill "$sampler_pid" 2>/dev/null || true
  wait "$sampler_pid" 2>/dev/null || true
  sampler_pid=""
}
trap 'stop_sampler; exit 130' INT TERM

idle_mib="$(nvidia-smi -i "$gpu_index" --query-gpu=memory.used --format=csv,noheader,nounits | head -n1 | tr -d ' ')"
echo "sweep-cuda: idle memory baseline ${idle_mib} MiB"
echo

best_tokens=0; best_micro=""; best_numerics=""

run_one() {
  local numerics=$1 micro=$2 label=$3 variant=$4
  shift 4
  local train_batch=${SWEEP_TRAIN_BATCH:-$micro}
  local log="$logdir/$label.log"
  local samples="$logdir/$label.samples"
  local peak

  case "$numerics" in
    tf32) peak=$peak_tf32 ;;
    bf16) peak=$peak_bf16 ;;
    fp32) peak=$peak_fp32 ;;
    *)    peak="" ;;
  esac

  printf '  %-28s ' "$label"

  start_sampler "$samples"
  local status=ok
  if ! env TRAIN_BATCH="$train_batch" MICRO_BATCH="$micro" \
        GEMM_NUMERICS="$numerics" \
        BENCH_WARMUP="$warmup" BENCH_STEPS="$steps" \
        ${peak:+BENCH_PEAK_TFLOPS="$peak"} \
        FUT_CACHE="$fut_cache" \
        "$@" \
        "$trainer" bench "$corpus" "$size" > "$log" 2>&1; then
    if grep -qiE 'out of memory|OUT_OF_MEMORY|cudaErrorMemoryAllocation' "$log"; then
      status=oom
    else
      status=fail
    fi
  fi
  stop_sampler

  # Peak memory above the idle baseline, and mean utilization while running.
  local peak_mib util_pct
  if [ -s "$samples" ]; then
    peak_mib="$(awk -F, -v base="$idle_mib" \
      '$2!=""{d=$2-base; if(d>m) m=d} END{printf "%d", (m>0?m:0)}' "$samples")"
    util_pct="$(awk -F, '$1!=""{s+=$1; n++} END{if(n) printf "%.1f", s/n; else printf "na"}' "$samples")"
  else
    peak_mib=na; util_pct=na
  fi

  local median p95 tokens gemm mfu days cost
  median=na; p95=na; tokens=na; gemm=na; mfu=na; days=na; cost=na
  if [ "$status" = ok ]; then
    median="$(sed -n 's/.*bench steps=[0-9]* median=\([0-9.]*\)s.*/\1/p' "$log" | tail -n1)"
    p95="$(sed -n 's/.*p95=\([0-9.]*\)s.*/\1/p' "$log" | tail -n1)"
    tokens="$(sed -n 's/.*target_tokens_per_second=\([0-9.]*\).*/\1/p' "$log" | tail -n1)"
    gemm="$(sed -n 's/.*gemm_tflops=\([0-9.]*\).*/\1/p' "$log" | tail -n1)"
    mfu="$(sed -n 's/.*mfu=\([0-9.]*\)%.*/\1/p' "$log" | tail -n1)"
    : "${median:=na}" "${p95:=na}" "${tokens:=na}" "${gemm:=na}" "${mfu:=na}"
    if [ "$tokens" != na ] && [ "$tokens" != 0 ]; then
      days="$(awk -v t="$total_tokens" -v r="$tokens" 'BEGIN{printf "%.2f", t/r/86400}')"
      if [ -n "$price" ]; then
        cost="$(awk -v t="$total_tokens" -v r="$tokens" -v p="$price" \
          'BEGIN{printf "%.2f", t/r/3600*p}')"
      fi
      # Track the throughput winner for the follow-up A/B and profile runs.
      # Only base rows compete; a follow-up must not redefine the winner.
      if [ "$variant" = base ] \
        && awk -v a="$tokens" -v b="$best_tokens" 'BEGIN{exit !(a>b)}'; then
        best_tokens=$tokens; best_micro=$micro; best_numerics=$numerics
      fi
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$gpu_name" "$size" "$numerics" "$train_batch" "$micro" "$variant" "$status" \
    "$median" "$p95" "$tokens" "$gemm" "$mfu" "$peak_mib" "$util_pct" \
    "$days" "$cost" >> "$out"

  case "$status" in
    ok)   printf 'ok    %8s tok/s  %6s%% mfu  %6s%% util  %6s MiB\n' \
            "$tokens" "$mfu" "$util_pct" "$peak_mib" ;;
    oom)  printf 'OOM   (peak %s MiB against %s MiB)\n' "$peak_mib" "$gpu_total_mib" ;;
    *)    printf 'FAIL  see %s\n' "$log" ;;
  esac
}

# --- the sweep ---------------------------------------------------------------
for numerics in $numerics_list; do
  echo "numerics=$numerics"
  for micro in $micro_batches; do
    run_one "$numerics" "$micro" "$size-$numerics-m$micro" base
  done
  echo
done

# --- follow-ups at the throughput winner ------------------------------------
if [ -n "$best_micro" ]; then
  echo "sweep-cuda: best throughput at numerics=$best_numerics micro=$best_micro ($best_tokens tok/s)"
  echo

  if [ "${ORDERING_AB:-1}" = 1 ]; then
    echo "GEMM_ORDERING=stream A/B"
    run_one "$best_numerics" "$best_micro" \
      "$size-$best_numerics-m$best_micro-stream" stream GEMM_ORDERING=stream
    echo
  fi

  if [ "${PROFILE:-1}" = 1 ]; then
    echo "FUT_PROFILE=1 (per-kernel totals at teardown; see the log)"
    run_one "$best_numerics" "$best_micro" \
      "$size-$best_numerics-m$best_micro-profile" profile FUT_PROFILE=1
    echo "  per-kernel report: $logdir/$size-$best_numerics-m$best_micro-profile.log"
    echo
  fi
else
  echo "sweep-cuda: no configuration completed — check $logdir" >&2
fi

echo "sweep-cuda: done"
echo
column -t -s "$(printf '\t')" "$out" 2>/dev/null || cat "$out"
echo
echo "results: $out    logs: $logdir"
