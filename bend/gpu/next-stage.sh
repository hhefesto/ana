#!/usr/bin/env bash
# Build and stage the next plan: the new transcripts (run/transcripts-next/
# LANG, one pass) mixed with replay of fp100m's languages (run/transcripts-final/
# LANG, cycled), as windows, shards and a plan; the held-out new transcripts
# as an eval corpus; then everything onto the box under the names fp.sh next
# and fp-relay.sh expect, and the STAGED marker last. Run from the repository
# root:
#   bend/gpu/next-stage.sh build              the mix, the shards and plan, the eval corpus (local)
#   bend/gpu/next-stage.sh push HOST PORT     to the box
#
# NEW lists the new languages as LABEL=DIR (default: haskell-new=
# run/transcripts-next/haskell bend-new=run/transcripts-next/bend); NAME
# (next) names the stage: the box gets run/NAME/plan-NAME-b16-windows.tsv and
# run/NAME/shard-K-NAME.corpus, and the eval corpus is run/eval/transcript-NAME.corpus.
# A wave: NAME=w1 RUN=run/w1 OUT=run/transcripts-mix-w1 NEW="agda-w1=run/transcripts-w1/agda ...".
#
# The mix: per round NEWH haskell-new and NEWB bend-new transcripts, and
# replay in fp100m's proportions (haskell 79,075 : lean 50,079 : agda 53,663 :
# nix 24,694 : bend 126,763), REPLAY (default 1.0) times as many as the new
# ones. bend-plan-segment reads the size as a model preset, so the shards
# are built as fp100m (run/next/shard-K-fp100m.corpus, plan-fp100m-b16-windows.tsv)
# and renamed on the box to shard-K-next.corpus / plan-next-b16-windows.tsv;
# the trainer finds shards by name and checks each one's identity inside.
set -euo pipefail
NAME=${NAME:-next}
OUT=${OUT:-run/transcripts-mix-$NAME}
RUN=${RUN:-run/$NAME}
NEW=${NEW:-haskell-new=run/transcripts-next/haskell bend-new=run/transcripts-next/bend}
EVALC=${EVALC:-run/eval/transcript-$NAME.corpus}
CV2=${CV2:-nix run .#deploy -- corpus-v2}

counts() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }

build() {
  rm -rf "$OUT"; mkdir -p "$OUT" "$RUN"
  specs=""; total=0; counts_list=""
  for e in $NEW; do
    lab=${e%%=*}; dir=${e#*=}; d="$OUT/$lab"; mkdir -p "$d"
    for f in transcripts.train.nul files-hi.nul files-lo.nul results.holdout.nul; do
      if [ -f "$dir/$f" ]; then ln -s "$PWD/$dir/$f" "$d/$f"; else : > "$d/$f"; fi
    done
    c=$(counts "$d/transcripts.train.nul"); counts_list="$counts_list $lab:$c"; total=$((total + c))
  done
  for l in haskell lean agda nix bend; do
    d="$OUT/$l"; mkdir -p "$d"
    ln -s "$PWD/run/transcripts-final/$l/transcripts.train.nul" "$d/transcripts.train.nul"
    ln -s "$PWD/run/transcripts-final/$l/results.holdout.nul" "$d/results.holdout.nul"
    # REPLAY_FILLER=1: the replayed languages' source files fill windows too
    # (with FILL capping a shard's filler files), for a wave whose own filler
    # is too small for its windows
    if [ "${REPLAY_FILLER:-0}" = 1 ]; then
      # less every file the new languages' filler already holds (bend-mix refuses a duplicate id)
      $CV2 replay-filler "$d" "run/transcripts-final/$l" $(for e in $NEW; do echo "${e#*=}"; done)
    else : > "$d/files-hi.nul"; : > "$d/files-lo.nul"; fi
  done
  # per round: the new languages in their sizes' ratio, 20 a round in all,
  # and REPLAY (1.0) times as many replayed in fp100m's proportions
  specs=$($CV2 specs-next "${REPLAY:-1.0}" $counts_list)
  echo "new transcripts:$counts_list; per round: $specs"
  OUT="$OUT" nix run .#deploy -- plan-windows "$RUN" fp100m 16 $specs
  # the held-out new transcripts as an eval corpus (M2-RUNBOOK section 4)
  : > "$RUN/holdout.nul"
  for e in $NEW; do dir=${e#*=}; [ -f "$dir/transcripts.holdout.nul" ] && cat "$dir/transcripts.holdout.nul" >> "$RUN/holdout.nul"; done
  nix run .#deploy -- pack "$RUN/holdout.nul" "$RUN/holdout.packed.nul" --target 131072 --prefix "transcript-$NAME" --stats
  nix run .#deploy -- prepare weights/code32k.bpe "$RUN/holdout.packed.nul" "$EVALC"
  head -1 "$RUN/plan-fp100m-b16-windows.tsv" | cut -c1-200
  ls -la "$RUN" "$EVALC"
}

push() {
  host="${1:?usage: next-stage.sh push HOST PORT}"; port="${2:?}"
  ssh="ssh -o StrictHostKeyChecking=no -p $port $host"
  $ssh "mkdir -p formalTransformer/run/$NAME formalTransformer/run/eval"
  rsync -a --partial -e "ssh -o StrictHostKeyChecking=no -p $port" "$EVALC" "$host:formalTransformer/run/eval/"
  for k in $(awk '$1 == "segment" { print $2 }' "$RUN/plan-fp100m-b16-windows.tsv"); do
    rsync -a --partial -e "ssh -o StrictHostKeyChecking=no -p $port" "$RUN/shard-$k-fp100m.corpus" "$host:formalTransformer/run/$NAME/shard-$k-$NAME.corpus"
    echo "shard $k landed"
  done
  rsync -a -e "ssh -o StrictHostKeyChecking=no -p $port" "$RUN/plan-fp100m-b16-windows.tsv" "$host:formalTransformer/run/$NAME/plan-$NAME-b16-windows.tsv.tmp"
  # every byte checked before the marker
  local_sums=$(cd "$RUN" && for k in $(awk '$1 == "segment" { print $2 }' plan-fp100m-b16-windows.tsv); do echo "$(sha256sum < shard-$k-fp100m.corpus | cut -d' ' -f1) shard-$k-$NAME.corpus"; done)
  box_sums=$($ssh "cd formalTransformer/run/$NAME && for f in shard-*-$NAME.corpus; do echo \"\$(sha256sum < \$f | cut -d' ' -f1) \$f\"; done")
  if [ "$(echo "$local_sums" | sort)" = "$(echo "$box_sums" | sort)" ]; then
    # the plan appears last, so a chain waiting for it starts on whole shards
    $ssh "cd formalTransformer/run/$NAME && mv plan-$NAME-b16-windows.tsv.tmp plan-$NAME-b16-windows.tsv && touch STAGED"; echo "STAGED: every shard matches"
  else
    echo "shard sums differ; not staged"; exit 1
  fi
}

case "${1:-}" in
  build) build ;;
  push) shift; push "$@" ;;
  *) sed -n 2,17p "$0"; exit 2 ;;
esac
