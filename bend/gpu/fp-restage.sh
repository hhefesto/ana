#!/usr/bin/env bash
# Stage the chain's remaining stages on a new box (the old one could not come
# back: vast stopped it when the credit ran out, and another renter took its
# GPU). From the repository root, once the box answers ssh:
#   bend/gpu/fp-restage.sh HOST PORT CKPT STAGE...
# puts on the box, in this order: the trainer as C (traind.c and
# traind-next.c, one program since TrainDense.bend has TRAIN_NEXT; dense.c for
# the gate), fp.sh, the tokenizer and the eval corpora; CKPT (a local
# checkpoint) as out/<its name>, to resume from; then each STAGE's shards and
# plan in the chain's order (rawK by raw-stage.sh push, any other NAME by
# next-stage.sh push), each plan last after its shards' sha256.
set -euo pipefail
host="${1:?usage: fp-restage.sh HOST PORT CKPT STAGE...}"
port="${2:?}"
ckpt="${3:?}"
shift 3
ssh="ssh -o StrictHostKeyChecking=no -p $port $host"
rs="rsync -a --partial -e 'ssh -o StrictHostKeyChecking=no -p $port'"
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] $*"; }
S=$(mktemp -d)
(cd bend && nix run ..#bend -- TrainDense.bend -o "$S/traind.c" && nix run ..#bend -- tests/dense.bend -o "$S/dense.c")
cp "$S/traind.c" "$S/traind-next.c"
$ssh "mkdir -p formalTransformer/weights formalTransformer/run/eval formalTransformer/out"
eval "$rs" "$S/traind.c" "$S/traind-next.c" "$S/dense.c" bend/gpu/fp.sh "$host:formalTransformer/"
eval "$rs" weights/code32k.bpe "$host:formalTransformer/weights/"
eval "$rs" run/eval/transcript-fp.corpus run/eval/transcript-next.corpus "$host:formalTransformer/run/eval/"
rm -rf "$S"
log "C, fp.sh, tokenizer, eval corpora landed"
eval "$rs" "$ckpt" "$host:formalTransformer/out/"
c=$(basename "$ckpt")
if [ "$(sha256sum < "$ckpt" | cut -d' ' -f1)" = "$($ssh "sha256sum < formalTransformer/out/$c" | cut -d' ' -f1)" ]; then log "out/$c landed, sha256 matches"
else log "out/$c differs from $ckpt"; exit 1; fi
for s in "$@"; do
  case "$s" in
    raw[0-9]*) bend/gpu/raw-stage.sh push "${s#raw}" "$host" "$port" ;;
    *) NAME="$s" bend/gpu/next-stage.sh push "$host" "$port" ;;
  esac
  log "stage $s staged"
done
log "restaged"
