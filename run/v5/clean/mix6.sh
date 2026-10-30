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
cd /home/hhefesto/src/ana || exit 1
OUT=${1:?usage: mix6.sh OUT [dry]}
DRY=${2:-}
CV=run/v5/clean/bend-corpus-v2
args=()
add() { if [ -s "$2" ]; then args+=("$1=$2"); else echo "mix6: not there: $2" >&2; fi; }
# first-time transcripts and their check-mutant repairs, by source
# a stream whose units got real history repairs (hist5.sh, 10-28): those repairs, and the stream
# and its mutate run less those units' made-up repairs (such a unit keeps its real repairs only)
# a stream rechecked on today's Bend (recheck6.sh, 10-28: run 2's and run 5's collection's units
# were checked on 10-04's and 10-16's Bend) less every transcript of a unit that fails today
fresh() { local r=run/v6/recheck-$1 f=$2 o; if [ -e $r/DONE ] && [ -s "$f" ]; then
  o=$r/streams/$(echo "$f" | tr '/' '_')
  if [ ! -s $o ] || [ $o -ot "$f" ] || [ $o -ot $r/stale.ids ]; then
    mkdir -p $r/streams; ALL=1 python3 -I tools/corpus-v2/hist/hist-drop.py "$f" $o.tmp $r/stale.ids >&2 && mv $o.tmp $o; fi
  echo $o; else [ -e $r/DONE ] || echo "mix6: $1 not rechecked on today's Bend ($r/DONE)" >&2; echo "$f"; fi; }
hist() { local h=run/v6/hist-$1; if [ -e $h/DONE ]; then add in $(fresh $1 $h/$1.train.nul); add in $h/repairs.train.nul; else
  echo "mix6: no history repairs for $1 ($h/DONE)" >&2; add in $(fresh $1 $2); fi; }
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
# col6's dropped units again at 180 s (recheck180c.sh, 10-30: col6's check began 10-28 with the 60 s limit)
add in run/v6/transcripts-col6t/bend/transcripts.train.nul
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
# mutate's repairs (deduced from a correct unit)
histmut v2 run/v5/mut/accepted/bend-mut/transcripts.train.nul
histmut collect5 run/v5/mut-collect5/accepted/bend-mut/transcripts.train.nul
add in run/v5/mut-py2bend/accepted/bend-mut/transcripts.train.nul
histmut own5 run/v5/mut-own5/accepted/bend-mut/transcripts.train.nul
add in run/v5/port/transcripts.train.nul
# ana's own mistakes and fixes (night runs; whole)
for d in run/v5/act5/ws/night*/accepted/bend-fix run/v5/act5/ws/night*/accepted/bend-act; do
  add free $d/transcripts.train.nul
done
# wrong on purpose: units of gavel's and knot's mutants/ files that differ from every def beside
# them (tools/corpus-v2/hist/mutheld.py, 10-28: 106 of run 2's and col6's 118 such units)
add held run/v6/held-mutants.txt
add held run/v5/leak/v2train/units.decl.nul.dropped
add held run/v5/leak/port/units.decl.nul.dropped
mkdir -p "$(dirname "$OUT")"
echo "mix6: ${#args[@]} streams" >&2
exec $CV repair-mix "$OUT" "${args[@]}" derive=whole ratio=4 cap=4 ${DRY:+dry}
