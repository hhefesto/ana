#!/usr/bin/env bash
# cloud-init.sh — one-shot, idempotent bring-up for a rented GPU box.
#
# Works on both a bare VM (Verda: systemd present -> multi-user Nix) and a
# Docker container (vast.ai: no systemd -> single-user Nix). Run it AFTER the
# repo has been transferred (see docs/RUN-2026-07-25-WIKI-FULL.md). Safe to re-run
# after an interruption/reboot; it never trains, so it costs only build time.
#
# Steps:
#   1. Confirm an NVIDIA runtime is present; report the driver's CUDA level.
#   2. Install Nix — daemon on a VM, single-user (--no-daemon) in a container —
#      and enable flakes (plus sandbox=false in a container, where the build
#      sandbox's user namespaces may be unavailable).
#   3. Build formal-transformer-cuda (CUDA pinned to 12.8 in flake.nix for
#      Blackwell sm_120 support; keep the pin <= the driver's Max CUDA).
#   4. Fail loudly if CUDA driver stubs leaked into the runtime RPATH.
#   5. Resolve libcuda.so.1: run `inspect bpe10m`; if the loader can't find the
#      injected driver lib, locate it, set LD_LIBRARY_PATH, retry, and persist
#      the path to run/cloud-env.sh so train-cloud.sh reuses it.
#
# Does NOT need the 18 GB source JSONL: train-cloud.sh drives training per-shard
# from the pre-built plan + corpora.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

in_container() {
  [ -f /.dockerenv ] && return 0
  [ -n "${container:-}" ] && return 0
  [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d ' ')" != systemd ] && return 0
  return 1
}
if in_container; then env_kind=container; else env_kind=vm; fi
echo "cloud-init: repo at $repo_root (environment: $env_kind)"

# ---------------------------------------------------------------------------
# 1. GPU runtime present?  Report its CUDA level (must be >= 12.8 for our PTX)
#    and refuse architectures unsupported by the pinned NVRTC.
# ---------------------------------------------------------------------------
if ! command -v nvidia-smi >/dev/null; then
  echo "cloud-init: nvidia-smi missing — rent a GPU instance whose template" >&2
  echo "  exposes the NVIDIA runtime (a CUDA/Ubuntu image, not a CPU-only one)." >&2
  exit 1
fi
nvidia-smi
driver_ver="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 || true)"
smi_cuda="$(nvidia-smi 2>/dev/null | grep -oE 'CUDA (UMD )?Version: [0-9]+\.[0-9]+' | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)"
echo "cloud-init: driver=$driver_ver  advertised CUDA=$smi_cuda  (flake emits 12.8 PTX)"
case "$smi_cuda" in
  ""|12.[0-7]|1[01].*)
    echo "cloud-init: WARNING — driver advertises CUDA < 12.8; 12.8 PTX may be rejected." >&2
    echo "  Pick a host with Max CUDA >= 12.8, or pin the flake lower (see fast-path doc)." >&2
    ;;
  *) echo "cloud-init: driver CUDA >= 12.8 — 12.8 PTX will be accepted." ;;
esac

# CUDA 12.8 NVRTC targets Blackwell. Architecture remains diagnostic only: the
# low-occupancy bpe10m failure also reproduced on Ampere.
compute_cap="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ' || true)"
echo "cloud-init: GPU compute capability=${compute_cap:-unknown}"

# ---------------------------------------------------------------------------
# 2. Nix install + config (mode depends on VM vs container).
# ---------------------------------------------------------------------------
# Skipped entirely when deploy/push-prebuilt.sh has already shipped the
# binaries and their runtime closure: nothing here needs to be compiled or
# fetched, and the installer below would `rm -rf /nix` and delete the very
# closure that was just copied in.  Rented GPUs measured ~50 minutes from
# boot to first training step with this path taken; prebuilt makes it ~1.
prebuilt=0
if [ -x result/bin/formal-transformer-cuda ] \
  && { [ "${BUILD_GEMM_CUDA:-0}" != 1 ] \
    || [ -x result-gemm/bin/formal-transformer-gemm-cuda ]; }; then
  prebuilt=1
  echo "cloud-init: prebuilt binaries present — skipping Nix install and build."
fi

if [ "$prebuilt" = 0 ]; then
# The Nix installer needs curl; a minimal base image (e.g. vastai/base-image)
# may not ship it.
if ! command -v curl >/dev/null; then
  echo "cloud-init: installing curl..."
  if command -v apt-get >/dev/null; then
    apt-get update && apt-get install -y curl
  else
    echo "cloud-init: curl missing and no apt-get; install curl and re-run." >&2
    exit 1
  fi
fi
# A root single-user install fails because Nix defaults build-users-group to
# "nixbld" when run as root, and a container has no such group. Pre-seed
# /etc/nix/nix.conf with an empty build-users-group (build as root, no sandbox
# users) plus flakes and sandbox=false, before installing.
if [ "$env_kind" = container ]; then
  mkdir -p /etc/nix
  printf 'build-users-group =\nexperimental-features = nix-command flakes\nsandbox = false\n' > /etc/nix/nix.conf
fi

# Source an existing nix profile first, so a re-run detects an installed nix and
# does NOT wipe /nix.
source_nix_profile() {
  for p in "$HOME/.nix-profile/etc/profile.d/nix.sh" \
           /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh \
           "$HOME/.nix-profile/etc/profile.d/nix-daemon.sh"; do
    # shellcheck disable=SC1090
    if [ -e "$p" ]; then . "$p"; return 0; fi
  done
  return 1
}
source_nix_profile || true

if ! command -v nix >/dev/null; then
  if [ "$env_kind" = container ]; then
    echo "cloud-init: installing single-user Nix (root container)..."
    rm -rf /nix   # clear any partial/failed install (the installer refuses if /nix exists)
    curl -L https://nixos.org/nix/install | sh -s -- --no-daemon
  else
    echo "cloud-init: installing multi-user Nix (--daemon)..."
    curl -L https://nixos.org/nix/install | sh -s -- --daemon
  fi
  source_nix_profile || true
fi
if ! command -v nix >/dev/null; then
  echo "cloud-init: Nix installed but not on PATH; open a new shell and re-run." >&2
  exit 1
fi
features="nix-command flakes"
NIX() { nix --extra-experimental-features "$features" "$@"; }

# ---------------------------------------------------------------------------
# 3. Build the CUDA host (most deps come from cache.nixos.org; only our small
#    derivation compiles). GPU is NOT needed to build — only to run, which is
#    what lets deploy/push-prebuilt.sh do this on a developer machine instead.
# ---------------------------------------------------------------------------
echo "cloud-init: building formal-transformer-cuda..."
NIX build .#formal-transformer-cuda

# Opt-in: also build the cuBLAS tensor-core trainer + its GPU smoke test
# (docs/RUN-2026-07-25-WIKI-FULL.md). Kept separate from result/ so train-cloud.sh
# defaults stay on the fused Futhark trainer until the gates pass.
if [ "${BUILD_GEMM_CUDA:-0}" = 1 ]; then
  echo "cloud-init: building formal-transformer-gemm-cuda (BUILD_GEMM_CUDA=1)..."
  NIX build .#formal-transformer-gemm-cuda -o result-gemm
fi

# ---------------------------------------------------------------------------
# 4. Stub-leak guard (same check the derivation enforces; belt and braces).
# ---------------------------------------------------------------------------
if NIX shell nixpkgs#patchelf -c \
     patchelf --print-rpath result/bin/formal-transformer-cuda | grep -q stubs; then
  echo "cloud-init: CUDA driver stubs leaked into the runtime RPATH" >&2
  exit 1
fi
fi  # end: not prebuilt

# ---------------------------------------------------------------------------
# 5. libcuda.so.1 resolution.  `inspect` execs the CUDA binary, forcing the
#    loader to resolve the driver's libcuda.so.1.  It is a NEEDED lib not
#    shipped by Nix, so it must come from the host/container driver: usually the
#    system ld.so cache already knows it; if not, find it and set LD_LIBRARY_PATH.
# ---------------------------------------------------------------------------
mkdir -p run
bin=./result/bin/formal-transformer-cuda
: > run/cloud-env.sh
if "$bin" inspect bpe10m 2>run/inspect.err; then
  echo "cloud-init: libcuda.so.1 resolved via the default loader paths."
else
  if ! grep -q 'libcuda' run/inspect.err; then
    echo "cloud-init: inspect failed for a non-libcuda reason:" >&2
    cat run/inspect.err >&2
    exit 1
  fi
  # The nvidia runtime injects libcuda.so.1 into a system lib dir that also holds
  # libc.so.6. Putting that whole dir on LD_LIBRARY_PATH shadows the Nix glibc
  # and breaks the binary (GLIBC_PRIVATE symbol errors). Instead, collect ONLY
  # the NVIDIA driver libs into a dedicated dir and point LD_LIBRARY_PATH there,
  # so libc et al. still come from the Nix closure.
  echo "cloud-init: libcuda not on the loader path — linking NVIDIA driver libs..."
  drvlibs="$repo_root/run/driver-libs"
  rm -rf "$drvlibs"; mkdir -p "$drvlibs"
  ldconfig -p 2>/dev/null | awk '/lib(cuda|nvidia)/{print $NF}' | while read -r lib; do
    [ -e "$lib" ] && ln -sf "$lib" "$drvlibs/"
  done
  if [ ! -e "$drvlibs/libcuda.so.1" ]; then
    found="$(find /usr/lib /usr/lib64 /lib -name 'libcuda.so.1' 2>/dev/null | head -n1 || true)"
    [ -n "$found" ] && ln -sf "$found" "$drvlibs/"
  fi
  if [ ! -e "$drvlibs/libcuda.so.1" ]; then
    echo "cloud-init: could not find libcuda.so.1 — is the NVIDIA runtime present?" >&2
    cat run/inspect.err >&2
    exit 1
  fi
  echo "cloud-init: linked $(ls "$drvlibs" | wc -l) driver libs into $drvlibs — retrying..."
  export LD_LIBRARY_PATH="$drvlibs${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  "$bin" inspect bpe10m
  printf 'export LD_LIBRARY_PATH="%s${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"\n' "$drvlibs" > run/cloud-env.sh
  echo "cloud-init: persisted LD_LIBRARY_PATH=$drvlibs to run/cloud-env.sh (train-cloud.sh sources it)."
fi

echo
echo "cloud-init: OK — CUDA host built and loadable (inspect printed the config above)."
echo "  Next: profile the CUDA ladder; do not train until its schedule is viable."
echo "  Profile (no corpus or tokenizer required):"
echo "    ./deploy/profile-cuda.sh ladder"
echo "  Then step gate (separate 5 min compile / 3 min execution caps):"
echo "    ./deploy/step-gate.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \\"
echo "      \$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
echo "  Benchmark (cents):"
echo "    TRAIN_BATCH=8 MICRO_BATCH=1 BENCH_STEPS=5 FUT_CACHE=run/futhark-cuda.cache \\"
echo "      ./deploy/benchmark-cuda.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \\"
echo "      \$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
