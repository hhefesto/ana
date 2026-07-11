#!/usr/bin/env bash
set -euo pipefail

if ! command -v nvidia-smi >/dev/null; then
  echo "bootstrap: nvidia-smi is unavailable; select an NVIDIA GPU VM image" >&2
  exit 1
fi

nvidia-smi

if ! command -v nix >/dev/null; then
  curl -L https://nixos.org/nix/install | sh -s -- --daemon
fi

if [ -e /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
  # shellcheck disable=SC1091
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

features="nix-command flakes"
nix --extra-experimental-features "$features" build .#formal-transformer-cuda

if nix --extra-experimental-features "$features" shell nixpkgs#patchelf -c \
    patchelf --print-rpath result/bin/formal-transformer-cuda | grep -q stubs; then
  echo "bootstrap: CUDA linker stubs leaked into the executable RPATH" >&2
  exit 1
fi

nix --extra-experimental-features "$features" run \
  .#formal-transformer-cuda -- inspect bpe10m

echo "bootstrap: Nix CUDA host linked successfully; run a training smoke test next"
