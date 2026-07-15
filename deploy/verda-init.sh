#!/usr/bin/env bash
# verda-init.sh — one-shot, idempotent bring-up for a Verda GPU instance.
#
# Run this AFTER the repo has been transferred to the instance (see
# docs/../deploy/verda-fast-path.md). It is safe to re-run — e.g. after a spot
# eviction/reboot — and it never trains, so it costs only build time.
#
# What it does, fast:
#   1. Confirms an NVIDIA driver is present and reports the driver's CUDA level.
#   2. Installs Nix (multi-user) and enables flakes if not already there.
#   3. Builds formal-transformer-cuda (CUDA pinned to 12.6 in flake.nix).
#   4. Fails loudly if CUDA driver stubs leaked into the runtime RPATH.
#   5. Runs `inspect bpe10m`, which forces the dynamic loader to resolve
#      libcuda.so.1 from the host driver — proving linkage before you pay for
#      a benchmark. (Context creation / PTX acceptance is proven by the
#      benchmark step, not here.)
#
# It does NOT require the 18 GB source JSONL: training is driven per-shard by
# deploy/train-cloud.sh from the pre-built plan + corpora.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
echo "verda-init: repo at $repo_root"

# ---------------------------------------------------------------------------
# 1. GPU driver present?  Report its CUDA level (must be >= 12.6 for our PTX).
# ---------------------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null; then
  echo "verda-init: nvidia-smi missing — pick the 'Ubuntu 24.04 + CUDA 12.6'" >&2
  echo "  GPU image, not the Minimal image (which ships no driver)." >&2
  exit 1
fi
nvidia-smi
driver_cuda="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
smi_cuda="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: \([0-9.]*\).*/\1/p' | head -n1 || true)"
echo "verda-init: driver=$driver_cuda  driver-advertised CUDA=$smi_cuda  (flake emits 12.6 PTX)"
case "$smi_cuda" in
  ""|12.[0-5]|1[01].*)
    echo "verda-init: WARNING — driver advertises CUDA < 12.6; 12.6 PTX may be rejected." >&2
    echo "  If the benchmark throws a PTX/JIT error, pin the flake lower (see fast-path doc)." >&2
    ;;
  *) echo "verda-init: driver CUDA >= 12.6 — 12.6 PTX will be accepted." ;;
esac

# ---------------------------------------------------------------------------
# 2. Nix + flakes.
# ---------------------------------------------------------------------------
if ! command -v nix >/dev/null; then
  echo "verda-init: installing Nix (multi-user daemon)..."
  curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes
fi
if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
features="nix-command flakes"
NIX() { nix --extra-experimental-features "$features" "$@"; }

# ---------------------------------------------------------------------------
# 3. Build the CUDA host (most deps come from cache.nixos.org; only our small
#    derivation compiles). GPU is NOT needed to build — only to run.
# ---------------------------------------------------------------------------
echo "verda-init: building formal-transformer-cuda..."
NIX build .#formal-transformer-cuda

# ---------------------------------------------------------------------------
# 4. Stub-leak guard (same check the derivation enforces; belt and braces).
# ---------------------------------------------------------------------------
if NIX shell nixpkgs#patchelf -c \
     patchelf --print-rpath result/bin/formal-transformer-cuda | grep -q stubs; then
  echo "verda-init: CUDA driver stubs leaked into the runtime RPATH" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 5. Linkage sanity: inspect resolves libcuda.so.1 from the host driver.
# ---------------------------------------------------------------------------
NIX run .#formal-transformer-cuda -- inspect bpe10m

echo
echo "verda-init: OK — CUDA host linked and loadable."
echo "  Next: benchmark, then train. See deploy/verda-fast-path.md."
echo "  Quick benchmark (cents):"
echo "    TRAIN_BATCH=8 MICRO_BATCH=1 BENCH_STEPS=5 \\"
echo "      ./deploy/benchmark-cuda.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \\"
echo "      \$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
