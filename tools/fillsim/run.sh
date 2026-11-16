#!/usr/bin/env bash
# FillSim's inputs and runs, as of 11-15 23:2x (the check before R7's plan-windows; FillSim.hs says what it replays).
# A thin shim: the byte lengths of every filler file (gawk), FillSim built with GHC, then R7's filler at the measured
# bytes per token and at 35% more, with run7.sh's prose PER before (787) and after (54), and R6's as the control.
# Bytes per token, bend-prepare with weights/code32k.bpe on every 19th Bend file, 290th prose piece, 8th/41st Haskell
# file (about 3,000 each): Bend 2.55, prose 2.73, Haskell 3.58 (files-hi) and 3.98 (files-lo); Lean, Agda, Nix taken
# as Haskell's 3.9.
#   tools/fillsim/run.sh [DIR]      (DIR: /tmp/bx/fillsim)
cd /home/hhefesto/src/ana || exit 1
D=${1:-/tmp/bx/fillsim}; mkdir -p $D/r6
len() { LC_ALL=C gawk 'BEGIN{RS="\0"} NR%2==0 {print length($0)}' "$@"; }
len run/v8/R5dsrc/bend/files-hi.nul > $D/bend.len
len run/v9/theory/prose/files-hi.nul > $D/prose.len
for l in haskell agda lean nix; do len run/v2/transcripts/$l/files-hi.nul run/v2/transcripts/$l/files-lo.nul > $D/$l.len; done
ln -sfn $PWD/run/v9/R6/parts $D/plans
for l in bend haskell lean agda nix; do ln -sfn ../$l.len $D/r6/$l.len; done; : > $D/r6/prose.len; ln -sfn $PWD/run/v9/R6/parts $D/r6/plans
nix shell nixpkgs#ghc -c ghc -O2 -o $D/fillsim tools/fillsim/FillSim.hs -outputdir $D/o > $D/build.log 2>&1 || { echo "build failed ($D/build.log)"; exit 1; }
m() { echo "157,2.55 9,3.9 6,3.9 23,3.9 5,3.9 $1,2.73"; }; s() { echo "157,3.45 9,5.3 6,5.3 23,5.3 5,5.3 $1,3.7"; }
echo "R6 (control, K=24, no prose): $($D/fillsim $D/r6 224 24 $(m 0) | tail -n 1)"
for pp in 787 54; do
  echo "R7 prose PER $pp, measured: $($D/fillsim $D 224 3 $(m $pp) | tail -n 1)"
  echo "R7 prose PER $pp, 35% more bytes a token, 228 shards: $($D/fillsim $D 228 3 $(s $pp) | tail -n 1)"
done
