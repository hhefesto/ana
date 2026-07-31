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

# Gate on the link before spending anything. A box that accepts SSH but resets
# sustained transfers is unusable, and that has to be discovered in seconds
# rather than after an hour of billed retries. SKIP_LINK_CHECK=1 to override.
if [ "${SKIP_LINK_CHECK:-0}" != 1 ]; then
  "$repo_root/deploy/check-link.sh" "$host" "$port" || {
    echo "push-prebuilt: aborting — this box cannot carry the transfer." >&2
    exit 1
  }
fi

# Build BEFORE renting.  The flake's source is the git tree, so committing
# changes its hash and the next build starts from scratch even when the file
# contents are identical -- roughly 15 minutes, most of it Futhark's CUDA
# codegen.  That is cheap on a workstation and pure waste with an instance
# already billing, so run `nix build .#formal-transformer-cuda
# .#formal-transformer-gemm-cuda` once the tree is committed and only then rent.
# Warn before silently burning rented time.  A rebuild here is ~15 minutes,
# mostly Futhark's CUDA codegen, and it happens on any commit -- the flake's
# source is the git tree, so its hash changes even when file contents do not.
needed=$(nix build --dry-run .#formal-transformer-cuda .#formal-transformer-gemm-cuda 2>&1 \
  | grep -c "will be built" || true)
if [ "${needed:-0}" != 0 ]; then
  echo "push-prebuilt: WARNING — the local build is stale and will be rebuilt (~15 min)." >&2
  echo "  The instance is billing while this runs. Build BEFORE renting:" >&2
  echo "    nix build .#formal-transformer-cuda .#formal-transformer-gemm-cuda" >&2
  echo "  Continuing in 10 s; Ctrl-C to abort and rebuild first." >&2
  sleep 10
fi

echo "push-prebuilt: resolving local build..."
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
#
# -r is NOT redundant with -a here.  --files-from switches off the recursion
# that -a would otherwise imply, so without it rsync creates each store path as
# an empty directory and copies none of its contents -- silently, and with an
# exit status of 0.  That shipped forty empty directories to a billing box and
# read as success.
rsync -a -r --ignore-existing --info=progress2 -e "$ssh_cmd" \
  --files-from="$closure" / "$host:/"

# Acceptance test: compare the file count and byte total of each output path
# against the local original.  Checking that the *binary runs* is not usable
# here -- it legitimately fails until cloud-init resolves libcuda.so.1 -- and an
# earlier version that fell back to a reassuring message on failure is exactly
# how the empty-directory transfer went unnoticed.
echo "push-prebuilt: verifying the transfer"
for path in "$cuda" "$gemm"; do
  want=$(find "$path" | wc -l)
  want_bytes=$(du -sb "$path" | cut -f1)
  read -r got got_bytes < <($ssh_cmd "$host" \
    "find '$path' 2>/dev/null | wc -l; du -sb '$path' 2>/dev/null | cut -f1" \
    | tr -d '\r' | paste -sd' ')
  if [ "${got:-0}" != "$want" ] || [ "${got_bytes:-0}" != "$want_bytes" ]; then
    echo "push-prebuilt: FAILED — $path is ${got:-0} entries / ${got_bytes:-0} bytes" >&2
    echo "  on the box, expected $want entries / $want_bytes bytes." >&2
    exit 1
  fi
  printf 'push-prebuilt: ok %s (%s entries, %s bytes)\n' "$(basename "$path")" "$want" "$want_bytes"
done

echo "push-prebuilt: linking result/ and result-gemm/ on the box"
$ssh_cmd "$host" "mkdir -p '$remote_dir' \
  && ln -sfn '$cuda' '$remote_dir/result' \
  && ln -sfn '$gemm' '$remote_dir/result-gemm' \
  && test -x '$remote_dir/result-gemm/bin/formal-transformer-gemm-cuda' \
  && ls -l '$remote_dir/result' '$remote_dir/result-gemm'"

cat <<EOF

push-prebuilt: done. Next on the box:

  cd $remote_dir
  BUILD_GEMM_CUDA=1 ./deploy/cloud-init.sh    # skips install+build, resolves libcuda

Then the sweep, or training. Nothing here compiled on rented time.
EOF
