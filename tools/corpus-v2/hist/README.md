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
