#!/usr/bin/env bash
# The Bend repair mix over every transcript stream (2026-10-28): the user's rule (11388) — real,
# first-time solutions at least 4 for every repair deduced from a correct one (ratio=4), each
# unit's own first-time transcript repeated to cover its repairs; at most 4 deduced repairs a unit
# (cap=4, the user 2026-10-29: "cap at 4 per unit"; mutate makes at most 5, so 5 is no cap; cap=1
# before).  A unit with real history repairs (hist5.sh) keeps those and none of its made-up ones.
# The nightly real-error attempts
# (run/v5/act5: ana's own wrong programs and her fixes, not deduced from a correct one) pass
# whole (free=).  A stream that is not there yet is left out, and said.
#   mix6.sh OUT [dry]     OUT e.g. run/v6/mix/bend; dry: OUT.stats and the summary only
#   MG=1: the streams mugen6.sh rendered in the mugen shape, those instead of format 2's
#   CH=1 (11-04, docs/MUGEN-SHAPE.md "Chains"): with MG=1, each stream's chains (chain6.sh) as repairs under the
#   rule, less those of units a recheck dropped or with real history repairs, and the nights in the mugen shape
#   CV: the bend-corpus-v2 to use (CH=1 needs one whose reader knows a chain's try: run/v6/mugen/chain/gcroot-bend-corpus-v2)
cd /home/hhefesto/src/ana || exit 1
OUT=${1:?usage: mix6.sh OUT [dry]}
DRY=${2:-}
# 11-03: not run/v5/clean/bend-corpus-v2 (the copy of 10-28): its repair-mix reads a mugen session as
# "other", so no copies and no cap; 0ed92bd classes them.  run/v5/gcroot-bend-corpus-v2-run5 is today's.
CV=${CV:-run/v5/gcroot-bend-corpus-v2-run5/bin/bend-corpus-v2}
args=()
# MG=1 (2026-11-03, the user 35718: "a step closer to mugen as an interface (turn wise)"): a
# stream mugen6.sh rendered in the mugen shape (run/v6/mugen/NAME/DONE) goes in that shape, the
# rest in format 2 (said); mutate's, the port's and the nights' have no mugen render
mg() { local f=$1 n
  case $f in
    run/v2/transcripts-nv/bend/transcripts.train.nul) n=v2 ;;
    run/v*/transcripts-*/bend/transcripts.train.nul) n=${f#run/v*/transcripts-}; n=${n%/bend/transcripts.train.nul} ;;
    *) echo "$f"; return ;;
  esac
  if [ "${MG:-0}" = 1 ]; then
    if [ -e run/v6/mugen/$n/DONE ]; then echo run/v6/mugen/$n/transcripts.train.nul; return; fi
    [ -s "$f" ] && echo "mix6: $n is not in the mugen shape yet (run/v6/mugen/$n/DONE): format 2" >&2
  fi
  echo "$f"; }
add() { local f; f=$(mg "$2"); if [ -s "$f" ]; then args+=("$1=$f"); else echo "mix6: not there: $f" >&2; fi; }
# first-time transcripts and their check-mutant repairs, by source
# a stream whose units got real history repairs (hist5.sh, 10-28): those repairs, and the stream
# and its mutate run less those units' made-up repairs (such a unit keeps its real repairs only)
# a stream rechecked on today's Bend (recheck6.sh, 10-28: run 2's and run 5's collection's units
# were checked on 10-04's and 10-16's Bend) less every transcript of a unit that fails today
fresh() { local r=run/v6/recheck-$1 f=$2 o; if [ -e $r/DONE ] && [ -s "$f" ]; then
  o=$r/streams/$(echo "$f" | tr '/' '_')
  if [ ! -s $o ] || [ $o -ot "$f" ] || [ $o -ot $r/stale.ids ]; then
    mkdir -p $r/streams; ALL=1 run/v5/gcroot-bend-corpus-v2-hd/bin/bend-corpus-v2 hist-drop "$f" $o.tmp $r/stale.ids >&2 && mv $o.tmp $o; fi
  echo $o; else [ -e $r/DONE ] || echo "mix6: $1 not rechecked on today's Bend ($r/DONE)" >&2; echo "$f"; fi; }
hist() { local h=run/v6/hist-$1 m=run/v6/mugen/hist-$1; if [ -e $h/DONE ]; then
  if [ "${MG:-0}" = 1 ] && [ -e $m/DONE ] && [ -s $m/$1.train.nul ]; then add in $(fresh $1 $m/$1.train.nul); add in $m/transcripts.train.nul
  else [ "${MG:-0}" = 1 ] && echo "mix6: hist-$1 is not in the mugen shape yet ($m/DONE): format 2" >&2
    add in $(fresh $1 $h/$1.train.nul); add in $h/repairs.train.nul; fi
  else echo "mix6: no history repairs for $1 ($h/DONE)" >&2; add in $(fresh $1 $(mg $2)); fi; }
histmut() { local h=run/v6/hist-$1; if [ -e $h/DONE ]; then add in $(fresh $1 $h/mut-$1.train.nul); else add in $(fresh $1 $2); fi; }
hist v2 run/v2/transcripts-nv/bend/transcripts.train.nul
hist collect5 run/v5/transcripts-collect5/bend/transcripts.train.nul
hist own5 run/v5/transcripts-own5/bend/transcripts.train.nul
add in run/v5/transcripts-port5/bend/transcripts.train.nul
add in run/v5/transcripts-a2bm5/bend/transcripts.train.nul
add in run/v6/transcripts-col6/bend/transcripts.train.nul
# run 6's dropped files upgraded (upg6.sh: bare operators wrapped, names Base took renamed; 10-28)
add in run/v6/transcripts-upg6/bend/transcripts.train.nul
# run 2's stale files upgraded (upg2.sh: the same, and Base helpers removed since; 10-28)
add in run/v6/transcripts-upg2/bend/transcripts.train.nul
# gavel's references with their tasks' prelude.bend and LAWS.bend beside them (gav6.sh, 10-28)
add in run/v6/transcripts-gav6/bend/transcripts.train.nul
# upg6's files a removed Base helper still failed, upgraded again (upg6b.sh, 10-28)
add in run/v6/transcripts-upg6b/bend/transcripts.train.nul
# the collected repositories' other branches and pull-request heads (br6.sh, 10-28)
add in run/v6/transcripts-br6/bend/transcripts.train.nul
# run 5's collection's files whose units its check dropped, upgraded (upg5.sh, 10-28)
add in run/v6/transcripts-upg5/bend/transcripts.train.nul
# bend-gen's units own5 dropped: imports that left the corpus tree (gen5.sh, 10-28)
add in run/v6/transcripts-gen5/bend/transcripts.train.nul
# a2bm5's dropped units against agda2bend's full modules (a2bm6.sh, 10-29)
add in run/v6/transcripts-a2bm6/bend/transcripts.train.nul
# agda-categories past module 355 (agda2bend corpus1t, exports up to 20 MB; a2bm7.sh, 10-29)
add in run/v6/transcripts-a2bm7/bend/transcripts.train.nul
# a2bm6's and a2bm7's dropped units again with Bend checks at 180 s, not 60 (recheck180.sh, 10-29;
# the user: yes, recheck what the 60 s limit lost once the machine is quieter)
add in run/v6/transcripts-a2bm6t/bend/transcripts.train.nul
add in run/v6/transcripts-a2bm7t/bend/transcripts.train.nul
# agda-unimath (UniMath/agda-unimath, MIT; agda2bend corpus-um, its builtins as Bend's; a2bum.sh, 10-29)
add in run/v6/transcripts-a2bum/bend/transcripts.train.nul
# PLFA (plfa/plfa.github.io part1-3; agda2bend corpus-plfa; a2bplfa.sh, 10-29)
add in run/v6/transcripts-a2bplfa/bend/transcripts.train.nul
# PLFA's cone again with agda2bend O0-j44 (56435f2, 10-29 08:45): only the declarations a2b-s and a2bplfa lack (a2bplfa2.sh)
add in run/v6/transcripts-a2bplfa2/bend/transcripts.train.nul
# agda-algebras (ualib/agda-algebras c761767, Apache-2.0; agda2bend corpus-aa with J; a2baa.sh, 10-29)
add in run/v6/transcripts-a2baa/bend/transcripts.train.nul
# PLFA's cone a third time with agda2bend O0-j47 (5528567, 10-29 12:10): only the declarations a2b-s, a2bplfa and a2bplfa2 lack (a2bplfa3.sh)
add in run/v6/transcripts-a2bplfa3/bend/transcripts.train.nul
# agda-algebras again with agda2bend O0-j47 (5528567): only the declarations a2baa lacks (a2baa2.sh)
add in run/v6/transcripts-a2baa2/bend/transcripts.train.nul
# the standard library and agda-categories again with agda2bend O0-j47 (corpus1u): only declarations no earlier run has (a2bm8.sh)
add in run/v6/transcripts-a2bm8/bend/transcripts.train.nul
# PLFA, agda-algebras, the standard library and agda-categories again with agda2bend O0-v5747 (5747eec, 10-29 22:25:
# nested patterns of indexed families, absurd patterns by clause evaluation): only declarations no earlier run has (a2bv.sh)
add in run/v6/transcripts-a2bplfa4/bend/transcripts.train.nul
add in run/v6/transcripts-a2baa3/bend/transcripts.train.nul
add in run/v6/transcripts-a2bm9/bend/transcripts.train.nul
# agda2hs-base and agda-prelude again with O0-v5747 (last on 10-22; a2bv.sh)
add in run/v6/transcripts-a2bhs/bend/transcripts.train.nul
add in run/v6/transcripts-a2bpre/bend/transcripts.train.nul
# run 5's units dropped only for Bend's verdict on @unsafe/foreign-effect defs, checked with bend-ff
# (ff6.sh, 10-29): with FF=1 only (the user 10-30: they go into the training mix; mixgo6ff.sh sets FF=1)
if [ "${FF:-0}" = 1 ]; then
  for s in own5 port5 collect5 col6 gav6 upg6b sub6 upg6 upg2 br6 brf6 upg5 gen5; do add in run/v6/transcripts-ff-$s/bend/transcripts.train.nul; done
fi
# the collected repositories' submodules filled in (sub6.sh, 10-28)
add in run/v6/transcripts-sub6/bend/transcripts.train.nul
# the collected repositories' forks' branches (brf6.sh, 10-28)
add in run/v6/transcripts-brf6/bend/transcripts.train.nul
# run 7: the Bend 2 repositories code search does not index (col7.sh, 10-28; after the night run)
add in run/v7/transcripts-col7/bend/transcripts.train.nul
# run 8: runs 6-7's repositories' growth, BendHub, Bend's upstream, 20 new Bend 2 repositories (col8.sh, col8b.sh, 11-02/03)
add in run/v8/transcripts-col8/bend/transcripts.train.nul
# our own repositories at 11-04's HEAD: what own5 did not have, bend-frp and mugen-web whole (own9.sh)
add in run/v8/transcripts-own9/bend/transcripts.train.nul
# agda-unimath again with agda2bend 7adf6f3 -O2 (umemit12): only declarations no earlier run has (a2bum12.sh, 11-03)
add in run/v6/transcripts-a2bum12/bend/transcripts.train.nul
# the 5747eec emits a2bv.sh never took (PLFA, agda-algebras, agda2hs-base, agda-prelude), against their src/ trees (a2bsrc.sh, 11-03)
for s in a2bplfa5 a2baa4 a2bhs2 a2bpre2; do add in run/v6/transcripts-$s/bend/transcripts.train.nul; done
# R5C=1 (run/v8/run5c.sh, 11-04): the last plan's streams, kept out of R5b's mix: 11-04's emits (a2bsrc.sh) and run 9's collection
if [ "${R5C:-0}" = 1 ]; then
  for s in a2bplfa16 a2bstd15 a2bum16; do add in run/v6/transcripts-$s/bend/transcripts.train.nul; done
  add in run/v8/transcripts-col9/bend/transcripts.train.nul
fi
# mutate's repairs (deduced from a correct unit).  MG=1 (11-03): left out.  They are format 2's text
# (mutate has no mugen render), and the mugen renders hold every check-mutant, 2.4 repairs a unit on
# own5, already past what the budget takes.
if [ "${MG:-0}" = 1 ]; then echo "mix6: MG=1: mutate's format 2 repairs left out" >&2; else
histmut v2 run/v5/mut/accepted/bend-mut/transcripts.train.nul
histmut collect5 run/v5/mut-collect5/accepted/bend-mut/transcripts.train.nul
add in run/v5/mut-py2bend/accepted/bend-mut/transcripts.train.nul
histmut own5 run/v5/mut-own5/accepted/bend-mut/transcripts.train.nul
fi
add in run/v5/port/transcripts.train.nul
# ana's own mistakes and fixes (night runs; whole)
if [ "${CH:-0}" = 1 ] && [ -e run/v6/mugen/chain/night/DONE ]; then add free run/v6/mugen/chain/night/transcripts.train.nul
else
for d in run/v5/act5/ws/night*/accepted/bend-fix run/v5/act5/ws/night*/accepted/bend-act; do
  add free $d/transcripts.train.nul
done
fi
# the chains of the mugen streams in the mix (CH=1).  A unit with real history repairs keeps those and none
# of its made-up ones, so a history stream's chains go less hist5's units (ALL=1: a chain is all made up).
if [ "${CH:-0}" = 1 ]; then
  C=run/v6/mugen/chain
  chain_of() { local n=$1 f=$C/$1/transcripts.train.nul o=$C/$1/kept.train.nul
    [ -e $C/$n/DONE ] || { echo "mix6: no chains for $n ($C/$n/DONE)" >&2; return; }
    if [ -e run/v6/hist-$n/DONE ] && [ -s run/v6/hist-$n/units.kept ]; then
      if [ ! -s $o ] || [ $o -ot $f ]; then ALL=1 run/v5/gcroot-bend-corpus-v2-hd/bin/bend-corpus-v2 hist-drop $f $o.tmp run/v6/hist-$n/units.kept >&2 && mv $o.tmp $o; fi
      f=$o
    fi
    add in "$(fresh $n $f)"; }
  chains=()
  for a in "${args[@]}"; do
    case $a in
      in=run/v6/mugen/*/transcripts.train.nul) n=${a#in=run/v6/mugen/}; chains+=("${n%/transcripts.train.nul}") ;;
      in=run/v6/recheck-*/streams/run_v6_mugen_hist-*) n=${a#in=run/v6/recheck-}; chains+=("${n%%/*}") ;;
    esac
  done
  case " ${chains[*]} " in *" own5 "*) ;; *) [ -e run/v6/hist-own5/DONE ] && chains+=(own5) ;; esac
  for n in "${chains[@]}"; do case $n in hist-*) ;; *) chain_of "$n" ;; esac; done
fi
# wrong on purpose: units of gavel's and knot's mutants/ files that differ from every def beside
# them (tools/corpus-v2/hist/mutheld.py, 10-28: 106 of run 2's and col6's 118 such units)
add held run/v6/held-mutants.txt
add held run/v5/leak/v2train/units.decl.nul.dropped
add held run/v5/leak/port/units.decl.nul.dropped
mkdir -p "$(dirname "$OUT")"
echo "mix6: ${#args[@]} streams" >&2
# SHARE (11-03): repair-mix's share=, the percent of units that keep repairs (what the run's hours take)
exec $CV repair-mix "$OUT" "${args[@]}" derive=whole ratio=4 cap=4 ${SHARE:+share=$SHARE} ${DRY:+dry}
