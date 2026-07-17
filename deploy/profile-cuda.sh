#!/usr/bin/env bash
# Profile/autotune the production CUDA gradient entry without a corpus.
#
# Modes:
#   ladder    Profile the seven tractable one-axis configurations (default).
#   autotune  Tune the production program on the tractable ladder.
#   full      Profile bpe10m; requires ALLOW_FULL_PROFILE=1 because futhark
#             bench performs a warmup, a measured run, and a profiling run.
set -euo pipefail

mode=${1:-ladder}
case "$mode" in
  ladder|autotune|full) ;;
  *) echo "usage: $0 [ladder|autotune|full]" >&2; exit 1 ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ -f run/cloud-env.sh ]; then
  # shellcheck disable=SC1091
  . run/cloud-env.sh
fi

if ! command -v nix >/dev/null; then
  for profile in "$HOME/.nix-profile/etc/profile.d/nix.sh" \
                 /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh; do
    if [ -e "$profile" ]; then
      # shellcheck disable=SC1090
      . "$profile"
      break
    fi
  done
fi
command -v nix >/dev/null || {
  echo "profile-cuda: nix missing; run deploy/cloud-init.sh first." >&2
  exit 1
}

# The CUDA shell supplies Futhark plus link-time CUDA stubs, while runtime
# libcuda.so.1 still comes from the provider driver sourced above.
if [ "${FORMAL_TRANSFORMER_CUDA_SHELL:-0}" != 1 ]; then
  exec nix --extra-experimental-features "nix-command flakes" develop .#cuda -c \
    env FORMAL_TRANSFORMER_CUDA_SHELL=1 "$repo_root/deploy/profile-cuda.sh" "$@"
fi

command -v nvidia-smi >/dev/null || {
  echo "profile-cuda: nvidia-smi missing; this command requires an NVIDIA GPU." >&2
  exit 1
}
command -v futhark >/dev/null || {
  echo "profile-cuda: futhark missing from the CUDA development shell." >&2
  exit 1
}

out_dir=${CUDA_PROFILE_DIR:-run/cuda-profile}
mkdir -p "$out_dir"
out_dir="$(cd "$out_dir" && pwd)"
program=backend/futhark/kernels-opencl.fut
ladder_spec=backend/futhark/cuda-grad-ladder.spec
full_spec=backend/futhark/cuda-grad-full.spec
cache=${FUT_CACHE:-$repo_root/run/futhark-cuda.cache}
tuning=${CUDA_TUNING:-$out_dir/cuda-production.tuning}

profile_case() {
  local label=$1
  local spec=$2
  local timeout_s=$3
  local json="$out_dir/$label.json"
  local report="$repo_root/$label.prof"
  local -a tuning_args=(--no-tuning)
  if [ -f "$tuning" ]; then
    tuning_args+=(--pass-option="--tuning=$tuning")
    echo "profile-cuda: applying tuning file $tuning"
  fi
  rm -f "$json"
  rm -rf "$report" "${json%.json}.prof"
  futhark bench --backend=cuda --profile --json "$json" \
    --spec-file "$spec" --entry-point=micro_batch_loss_grad \
    --runs=1 --no-convergence-phase --timeout="$timeout_s" \
    --pass-option="--cache-file=$cache" "${tuning_args[@]}" "$program"
  futhark profile "$json"
  mv "$report" "$out_dir/"
  echo "profile-cuda: report: ${json%.json}.prof"
}

case "$mode" in
  ladder)
    profile_case cuda-grad-ladder "$ladder_spec" "${PROFILE_TIMEOUT:-300}"
    ;;
  autotune)
    temporary_suffix=cuda-autotune
    temporary="$program.$temporary_suffix"
    rm -f "$temporary"
    trap 'rm -f "$temporary"' EXIT
    echo "profile-cuda: autotuning the production entry on tractable shapes..."
    futhark autotune --backend=cuda --spec-file "$ladder_spec" \
      --runs=1 --timeout="${AUTOTUNE_TIMEOUT:-300}" \
      --pass-option="--cache-file=$cache" --tuning="$temporary_suffix" "$program"
    mv "$temporary" "$tuning"
    trap - EXIT
    echo "profile-cuda: production tuning file: $tuning"
    echo "profile-cuda: rerun '$0 ladder' to compare the tuned schedule."
    ;;
  full)
    if [ "${ALLOW_FULL_PROFILE:-0}" != 1 ]; then
      echo "profile-cuda: refusing the pathological full case by default." >&2
      echo "  futhark bench runs it three times; set ALLOW_FULL_PROFILE=1 after" >&2
      echo "  the ladder (and preferably autotuning) gives a viable schedule." >&2
      exit 1
    fi
    profile_case cuda-grad-bpe10m "$full_spec" "${FULL_PROFILE_TIMEOUT:-900}"
    ;;
esac
