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
# The mix: per round NEWH haskell-new and NEWB bend-new transcripts, and
# replay in fp100m's proportions (haskell 79,075 : lean 50,079 : agda 53,663 :
# nix 24,694 : bend 126,763), REPLAY (default 1.0) times as many as the new
# ones. bend-plan-segment reads the size as a model preset, so the shards
# are built as fp100m (run/next/shard-K-fp100m.corpus, plan-fp100m-b16-windows.tsv)
# and renamed on the box to shard-K-next.corpus / plan-next-b16-windows.tsv;
# the trainer finds shards by name and checks each one's identity inside.
set -euo pipefail
OUT=${OUT:-run/transcripts-mix-next}
RUN=${RUN:-run/next}

counts() { echo $(( $(tr -cd '\0' < "$1" | wc -c) / 2 )); }

build() {
  rm -rf "$OUT"; mkdir -p "$OUT" "$RUN"
  for l in haskell bend; do
    d="$OUT/$l-new"; mkdir -p "$d"
    for f in transcripts.train.nul files-hi.nul files-lo.nul results.holdout.nul; do
      if [ -f "run/transcripts-next/$l/$f" ]; then ln -s "$PWD/run/transcripts-next/$l/$f" "$d/$f"; else : > "$d/$f"; fi
    done
  done
  for l in haskell lean agda nix bend; do
    d="$OUT/$l"; mkdir -p "$d"
    ln -s "$PWD/run/transcripts-final/$l/transcripts.train.nul" "$d/transcripts.train.nul"
    ln -s "$PWD/run/transcripts-final/$l/results.holdout.nul" "$d/results.holdout.nul"
    : > "$d/files-hi.nul"; : > "$d/files-lo.nul"
  done
  hn=$(counts "$OUT/haskell-new/transcripts.train.nul"); bn=$(counts "$OUT/bend-new/transcripts.train.nul")
  # per round: new transcripts in their sizes' ratio, 20 a round at most
  read -r ph pb rh rl ra rn rb < <(python3 - "$hn" "$bn" "${REPLAY:-1.0}" <<'EOF'
import sys
hn, bn, rep = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
tot = hn + bn
ph = max(1, round(20 * hn / tot)) if hn else 0
pb = max(1, round(20 * bn / tot)) if bn else 0
w = {"h": 79075, "l": 50079, "a": 53663, "n": 24694, "b": 126763}
s = sum(w.values()); r = rep * (ph + pb)
print(ph, pb, *[max(1, round(r * w[k] / s)) for k in "hlanb"])
EOF
)
  specs=""
  [ "$ph" -gt 0 ] && specs="$specs haskell-new:$ph"
  [ "$pb" -gt 0 ] && specs="$specs bend-new:$pb"
  specs="$specs haskell:$rh:cycle lean:$rl:cycle agda:$ra:cycle nix:$rn:cycle bend:$rb:cycle"
  echo "new transcripts: haskell $hn, bend $bn; per round:$specs"
  OUT="$OUT" nix run .#deploy -- plan-windows "$RUN" fp100m 16 $specs
  # the held-out new transcripts as an eval corpus (M2-RUNBOOK section 4)
  cat run/transcripts-next/haskell/transcripts.holdout.nul run/transcripts-next/bend/transcripts.holdout.nul > "$RUN/holdout.nul" 2>/dev/null || true
  nix run .#deploy -- pack "$RUN/holdout.nul" "$RUN/holdout.packed.nul" --target 131072 --prefix transcript-next --stats
  nix run .#deploy -- prepare weights/code32k.bpe "$RUN/holdout.packed.nul" ${EVALC:-run/eval/transcript-next.corpus}
  head -1 "$RUN/plan-fp100m-b16-windows.tsv" | cut -c1-200
  ls -la "$RUN" ${EVALC:-run/eval/transcript-next.corpus}
}

push() {
  host="${1:?usage: next-stage.sh push HOST PORT}"; port="${2:?}"
  ssh="ssh -o StrictHostKeyChecking=no -p $port $host"
  $ssh "mkdir -p formalTransformer/run/next formalTransformer/run/eval"
  rsync -a --partial -e "ssh -o StrictHostKeyChecking=no -p $port" ${EVALC:-run/eval/transcript-next.corpus} "$host:formalTransformer/run/eval/"
  for k in $(awk '$1 == "segment" { print $2 }' "$RUN/plan-fp100m-b16-windows.tsv"); do
    rsync -a --partial -e "ssh -o StrictHostKeyChecking=no -p $port" "$RUN/shard-$k-fp100m.corpus" "$host:formalTransformer/run/next/shard-$k-next.corpus"
    echo "shard $k landed"
  done
  rsync -a -e "ssh -o StrictHostKeyChecking=no -p $port" "$RUN/plan-fp100m-b16-windows.tsv" "$host:formalTransformer/run/next/plan-next-b16-windows.tsv"
  # every byte checked before the marker
  local_sums=$(cd "$RUN" && for k in $(awk '$1 == "segment" { print $2 }' plan-fp100m-b16-windows.tsv); do echo "$(sha256sum < shard-$k-fp100m.corpus | cut -d' ' -f1) shard-$k-next.corpus"; done)
  box_sums=$($ssh "cd formalTransformer/run/next && for f in shard-*-next.corpus; do echo \"\$(sha256sum < \$f | cut -d' ' -f1) \$f\"; done")
  if [ "$(echo "$local_sums" | sort)" = "$(echo "$box_sums" | sort)" ]; then
    $ssh "touch formalTransformer/run/next/STAGED"; echo "STAGED: every shard matches"
  else
    echo "shard sums differ; not staged"; exit 1
  fi
}

case "${1:-}" in
  build) build ;;
  push) shift; push "$@" ;;
  *) sed -n 2,17p "$0"; exit 2 ;;
esac
