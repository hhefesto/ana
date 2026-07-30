#!/usr/bin/env bash
# push-prebuilt.sh — compile here, ship the result, so rented GPU time is spent
# training rather than building.
#
# The CUDA hosts need a GPU to *run* but not to *build* — nvcc, cuBLAS and NVRTC
# all come from the Nix closure, and the driver is only touched at runtime. So
# the whole compile can happen on a developer machine and the box receives
# finished binaries plus the runtime closure they link against.
#
# Every instance measured so far spent ~50 minutes installing Nix and compiling
# before the GPU did any work at all, on hardware billed by the hour. This
# replaces that with one rsync.
#
# Nix is NOT required on the target: the binaries reference absolute
# /nix/store/... paths, so copying those paths in is enough for the dynamic
# loader. cloud-init.sh detects the result symlinks and skips its install and
# build steps entirely.
#
# The transfer is small -- the runtime closure of both hosts measures 1.22 GB
# over 40 store paths, against the tens of GB of GHC and CUDA toolkit that
# building would have to fetch.
#
# usage: ./deploy/push-prebuilt.sh [user@]host [port]
#
# Env:
#   REMOTE_DIR   repo directory on the box (default formalTransformer)
#   SKIP_BUILD=1 assume the local build is current
set -euo pipefail

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "usage: $0 [user@]host [port]" >&2
  exit 1
fi

host=$1
port=${2:-22}
remote_dir=${REMOTE_DIR:-formalTransformer}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

ssh_cmd="ssh -p $port"

if [ "${SKIP_BUILD:-0}" != 1 ]; then
  echo "push-prebuilt: building both CUDA hosts locally (no GPU needed)..."
fi
cuda=$(nix build --no-link --print-out-paths .#formal-transformer-cuda | tail -1)
gemm=$(nix build --no-link --print-out-paths .#formal-transformer-gemm-cuda | tail -1)
test -n "$cuda" && test -n "$gemm" || { echo "push-prebuilt: build produced no output paths" >&2; exit 1; }
echo "push-prebuilt: cuda=$cuda"
echo "push-prebuilt: gemm=$gemm"

# The runtime closure -- what the loader needs -- not the (far larger) build
# closure with GHC and the CUDA toolkit in it.
closure=$(mktemp)
trap 'rm -f "$closure"' EXIT
nix-store -qR "$cuda" "$gemm" | sort -u > "$closure"
count=$(wc -l < "$closure")
bytes=$(du -sc --files0-from=<(tr '\n' '\0' < "$closure") 2>/dev/null | tail -1 | cut -f1)
printf 'push-prebuilt: %d store paths, %.2f GB\n' "$count" "$(echo "$bytes" | awk '{print $1/1048576}')"

echo "push-prebuilt: copying the closure into $host:/nix/store ..."
# Store paths are immutable and content-addressed by their hash, so anything
# already present is byte-identical -- skip it rather than re-send or try to
# overwrite a read-only tree.
rsync -a --ignore-existing --info=progress2 -e "$ssh_cmd" \
  --files-from="$closure" / "$host:/"

echo "push-prebuilt: linking result/ and result-gemm/ on the box"
$ssh_cmd "$host" "mkdir -p '$remote_dir' \
  && ln -sfn '$cuda' '$remote_dir/result' \
  && ln -sfn '$gemm' '$remote_dir/result-gemm' \
  && ls -l '$remote_dir/result' '$remote_dir/result-gemm' \
  && '$remote_dir/result-gemm/bin/formal-transformer-gemm-cuda' inspect bpe100m >/dev/null 2>&1 \
     && echo 'push-prebuilt: binary runs on the box' \
     || echo 'push-prebuilt: binary present but did not run yet (cloud-init resolves libcuda.so.1)'"

cat <<EOF

push-prebuilt: done. Next on the box:

  cd $remote_dir
  BUILD_GEMM_CUDA=1 ./deploy/cloud-init.sh    # skips install+build, resolves libcuda

Then the sweep, or training. Nothing here compiled on rented time.
EOF
