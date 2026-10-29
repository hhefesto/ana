# History repairs: real errors from the repositories' git histories

2026-10-28, for the user's goal (11388): the most Bend code, error-then-fix cases included, at
least four first-time solutions for every repair.

A repair transcript so far started from a made-up mistake: a correct unit with one of
MutOps.bend's operators applied (misspell, var-swap, drop-line, ...).  The collected
repositories' histories hold real ones: a declaration's body as an earlier commit had it, put back
into today's file, that today's check rejects, is an error somebody (most Bend 2 code is written
by agents) made, and today's body is its fix.

- `hist6.py PINS.tsv OUTDIR CORPUS...` mines them: for each wanted file (the training corpora's;
  vault and holdout files are never given) its versions older than the corpus text, cut into
  units with bend-units; a unit's newest older body that differs beyond whitespace is its history
  mutant.  `HIST_LOCAL=1` reads local repositories (the user's own: ana, telomare, mugen,
  agda2bend, bend2), `HIST_CLASS` sets the id class (run 2's `curated:`).
- `hist-merge.py` gives a unit its history mutant (same body by sha256, byte similarity >= 0.3),
  first; `HIST_ONLY=1` keeps only those units, with it alone.
- `hist-pick.py`, after the check: a unit whose history mutant the check rejected keeps that one
  alone (the mix keeps one repair a unit, cap=1, by key); otherwise its made-up ones.
- `hist-drop.py`: a stream less the made-up repairs (check-mutant `/repair`, mutate's `mut:`) of
  units that got a history repair checked apart.

Memory: bend-units grows with all it is given (28 MB at once took 26 GB and, run in mugen's
shell, killed mugen's tmux pane twice, 10-28); hist6.py calls it a file at a time (1.7 GB peak,
a 100 KB file) and runs as a systemd unit with a MemoryMax.

Runs (run/, not in git): `run/v5/clean/units6.sh col6` (run 6's collection: merge before the
check, pick after), `run/v5/clean/hist5.sh own5 collect5 v2` (streams checked before: their
history repairs checked apart, `run/v6/hist-NAME/{repairs,NAME,mut-NAME}.train.nul`),
`run/v5/clean/hist6x.sh` (run 2's corpus), `run/v5/clean/mix6.sh` (uses them when
`run/v6/hist-NAME/DONE` is there).

First numbers (10-28): zw3rk/birc's 30 sampled candidates: 12 rejected by today's check, 7 still
checking, 11 whose today's file did not check alone.  own: ana 667 history mutants of 7245
units, telomare 357/1672, mugen 56/859, agda2bend 83/637.

## BendHub's version histories (10-28 evening)

`hubhist.py SRC OUTDIR CORPUS...` makes a git repository per named BendHub package of a
collection, a commit per older version (fetched from the hub, checked against its manifest), the
pinned version last; `hist6.py` with `HIST_LOCAL=1 HIST_HUB=1` mines them like any repository.
Run 6: 46 packages, 255 older versions, 6,300 units, 334 history mutants
(`run/v5/clean/hubhist6.sh`, joined to `run/v6/hist/hist.nul` before col6's merge; the git ones
are `hist.nul.git`).

## Today's Bend on the older streams (10-28 evening)

Run 2's units were checked on 10-04's Bend, run 5's collection's on 10-16's.  Under 2.0.39 a sample
of 480 of run 2's curated train units fails 148 (31%): Base renamed helpers (Map.get.bit,
Nat.div.fin, String.eq.fin; List.find.put became List.find.if in 2.0.38, #1730), Base's new
names clash with a file's own (Text, Ready, Wait, Window, ...), @unsafe and foreign defs no longer
check.  Their transcripts say ALL PROOFS CHECK where today's Bend does not.  own5 (2.0.38, 10-28):
299 of 300 sampled fine.

- `recheck.py tree|files|stale`: run 2's tree (its files-hi.nul, then each unit's own file over
  it), each file with a unit checked whole (a file that checks has every unit checking: 312 of
  313 in the sample), the other files' units checked one by one, the units that fail today
  (`stale.ids`).
- `hist-drop.py` with `ALL=1`: every transcript of a listed unit out.
- `run/v5/clean/recheck6.sh v2 collect5`, then `mix6.sh` leaves the stale units out (`fresh`).

## Run 6's dropped files, upgraded (10-28 evening)

Run 6's loader dropped 6,152 files: 1,978 for a bare operator (an error since Bend 2.0.16, 09-19;
until then one meant Nat, and the error says to write `(a + b : Nat)`), ~1,100 for a name Base took
since (`duplicate declaration`: Text, Ready, Wait, Pair, Word, Window, ...), 1,547 for missing files
(gavel's mutants' prelude.bend, submodules).

- `upgrade.py SRC LIST OUT`: wraps the operator's expression where the error points (in the file
  or a file it imports, found by the line the error shows), renames a name Base took to NAME_ in
  the file declaring it and every file reaching it (code only, not strings or comments), checks
  again; rounds for files whose imports were upgraded meanwhile.  40 sampled files (not pi-bend's):
  14 pass, 11 check but for a def's own error.  pi-bend's 1,255 are left out (written for a Bend
  with a native F64 constructor: 0 of 12 passed), so are gavel's mutants/ (wrong on purpose).
- `upg-corpus.py corpus|git|filter`: the upgraded files (pass or checked, not a vault or holdout
  repository's) as a corpus; a git history per repository (as collected, then upgraded) for
  hist6.py, so a unit's collected body is its history mutant; the mutants that differ by a rename
  alone are dropped, the rest get the renames (their error is the bare operator its author wrote).
- `run/v5/clean/upg6.sh`: list, upgrade, corpus, history mutants, then as units6.sh (units,
  decl-new held/seen, cap, trim, merge, check, hist-pick, render): run/v6/transcripts-upg6, a
  stream of mix6.sh.  First 125 of its 1,463 files: 58 pass.

## More than one older body a unit (HIST_M, 10-28)

hist6.py gave a unit its newest older body alone; where that one checks today the unit had no
history repair, though an older one might not.  `HIST_M=3` gives up to three, newest first, each
differing from today's and from the ones before it; hist-merge.py hands them all to the check,
hist-pick.py keeps the newest the check rejected.  On birc and hapsland 271 of 999 history units
have more than one (1,368 bodies).  Run 6's git and BendHub histories again with it:
run/v5/clean/hist6m.sh (run/v6/hist-m3; it takes run/v6/hist/hist.nul's place if col6 has not
merged that yet).

Run 2's tree (recheck.py tree) lacked 54 files run 2's files import: 185 files failed "no such
file".  31 copied from run 5's and 6's collections, 18 fetched at the pins, 5 gone;
run/v5/clean/refill6.sh checks those 185 again after recheck6 and puts their verdicts in.
