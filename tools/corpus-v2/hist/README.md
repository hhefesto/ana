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

## Run 2's stale files: the tree they meet, and upgraded (10-28 night)

recheck6 found 2,091 of run 2's 5,594 curated files failing Bend 2.0.39 whole.  Many are not
broken at all: recheck.py tree rebuilt run 2's repositories from its units, each file as its units
have it and the files they import as files-hi.nul had them, so a file can meet an import of
another day (Giulio2002/bend-collections' 332 meet an old native_map.bend that calls Map.get.bit,
gone from Base 09-26; run 6's copy of native_map imports map_bridge.bend instead).  1,121 of the
2,091 are byte for byte a file of run 6's collection (365 of them pass there; 652 are of
repositories run 6 never checked: bend-collections, godot-bend, bendmon-engine); 311 more are there
in another version.

- `run/v5/clean/retree6.sh` (after recheck6 and refill6): the byte-for-byte ones checked whole in
  run 6's tree (run/v6/collect/src/bend), then their failing units one by one there; the other
  versions' units one by one there (a unit is its file's head and itself, so run 6's tree only
  gives it its imports).  The verdicts replace theirs in curated/stale.ids and stale.ids
  (run/v6/recheck-v2/curated-v6).
- upgrade.py now also mends a Base helper removed since ("a defined name", observed): Nat.div.fin(x)
  becomes Pair.fst(Nat, Nat, x) and Nat.mod.fin Pair.snd (today's Nat.div and Nat.mod are exactly
  that, so a proof unfolding them still meets it; a bare Nat.div.fin becomes a lambda);
  String.eq.fin and Map.get.bit get their old def after the file's imports (below its use a def
  does not unfold there).  And an import alias a Base name shadows ("the alias TCP shadows
  TCP.recv_bytes"): the alias becomes TCP_ in that file, and its uses of the imported file's own
  names with it (bend-net's 39: they then fail on IO.bind's new type, not mended).  A line no file
  has any more (another file's run moved it) is checked again, twice at most.
- `run/v5/clean/upg2.sh`: upg6.sh for run 2's failing files with what upgrade.py mends (bare
  operators, names Base took, removed helpers; 783), less pi-bend, gavel's mutants, held
  repositories and the files run 6 has byte for byte (retree6.sh's): 259 files, 66 pass after
  upgrade.  Its corpus leaves out any file col6 or upg6 has; its decl-new's seen= is run 2's
  results less its stale units (`nul-without.py --ids`), so a unit of run 2's that checks today
  is not taken again.  run/v6/transcripts-upg2, a stream of mix6.sh.
- Bend-collections' native_map.bend and map_insert.bend can be ported by hand (a bridge law,
  Map.get.go to the old one-level route, proved by cases as the author's map_bridge.bend does;
  tried in /tmp, both then check up to map_insert's Map.ins.deep, also gone), not done: run 6's
  tree has the author's own port.

## gavel, assembled; wrong-on-purpose mutants; upg6 again (10-28)

- **gavel** (Lulzx/gavel, run 6's largest Bend 2 repository) keeps a task's `LAWS.bend` and
  `prelude.bend` in `tasks/N/T/` and its answer in `references/T/{solution,PROOF}.bend`; its harness
  puts them in one directory. Run 6's loader dropped 273 of its files for "no such file" (prelude 219,
  LAWS 53), upg6 130 more. `run/v5/clean/gav6.sh` fills each `references/T` with the task's missing
  `prelude.bend`/`LAWS.bend` (363 copies, not corpus files), upgrades the 385 files with
  `upgrade.py` (347 pass) and goes on as upg6: `run/v6/transcripts-gav6`, a stream of mix6.sh.
- **upgrade.py** wrapped `{a + b == c : Nat}` whole (`expected ')'`, upg6's 32 gavel files): a
  wrap now stops at ` == ` / ` != ` on either side.
- **mutants/**: gavel's `references/T/mutants/*.bend` and knot's
  `tests/perch-performance/cases/C/mutants/*.bend` are wrong on purpose (a law or a test is there
  to catch each) and they check, so run 2 (94 units) and col6 (17) took them as code.
  `mutheld.py` lists the units of such files whose def differs from every def beside the
  `mutants/` directory: 106 of 118, `run/v6/held-mutants.txt`, held out by mix6.sh (`held=`).
  gavel's mutants are also a source of law-failure repairs (the mutant, `bend PROOF.bend`'s
  error, the reference): not taken yet (the unit check leaves the laws out: it would need whole-file
  units, as the port's).
- **upg6b** (`run/v5/clean/upg6b.sh`): upg6 ran before `upgrade.py` mended removed Base helpers;
  its 104 files that ended "a defined name" (not gavel's, not evm-bend's: its `Word_` is a bad
  rename, the file also calls Base's `Word(n)`) again from the files as collected: 73 pass.
- Not upgradable here: jnadeau207-collab/BendCAD (206 files; `0xFF`, `u64` and `f64` literal suffixes: Bend's
  literals are decimal only and Base has no U64/F64), pi-bend (a patched Bend with a native
  `F64{high, low}`: 31 of 40 sampled stop there, 4 pass), WanShi and avikj/math (older syntax).

## Other branches, pull requests, forks, submodules (10-28 night)

The collection clones a repository's default branch at its pin, sparse (`*.bend`), without
submodules.  `git ls-remote` on run 6's 298 GitHub repositories: 4,641 branches (133 repositories
with more than one), 12,383 pull-request heads (bendlang/bend 1,155).
- **br6.py** (`run/v5/clean/br6.sh`, out run/v6/br6): a bare partial clone (commits and trees) of
  each repository with every branch (`refs/b/`) and pull-request head (`refs/p/`); a head the pin
  has is skipped; a head's .bend file whose blob no commit of the pin's history has, nor a head
  taken before (branches, then pull requests newest first), is taken, at most 3 versions a path,
  never under `mutants/`; no vault or holdout repository's (33 skipped).  A taken file goes to
  `br/tree/SLUG~KEY/PATH` (KEY `b-BRANCH`, `pNUMBER`) with what it imports as that head has it.
  7,735 files from 265 repositories (ericfode/knot 2,625: its compiler-test campaign branches;
  bendlang/bend 1,417: #1207, a self-hosted Bend, alone 771; dearlordylord/bendvy 834; HOLON 713).
  **br6-filter.py** then drops what collect's list step would (the configs' exclude prefixes, runs
  3-6, vendored directories, `*_generated*`, big files; a held corpus's path): 6,830 kept.
  upgrade.py, a corpus, collect's raw gate (`bend-corpus-v2 raw`: copies, held-out keys, filler,
  long lines, generated markers), history mutants, units, decl-new held/seen (every run-6 stream),
  cap, trim, check, render: run/v6/transcripts-br6, a stream of mix6.sh.
- **Forks** (`run/v5/clean/brf6.sh`, out run/v6/brf6): run/v6/forks7.tsv, each repository's forks
  pushed since Bend 2 (08-25) and after their creation (253; bendlang/bend 149, Backplane 34).
  br6.py with `BR_FORKS` fetches their branches into br6's clones (`refs/f/OWNER/`) and takes what
  neither the pin's history nor any branch or pull-request head has: 4,483 files after the filter
  (rom1504's selfhost_bootstrap 2,276; s1onique 350; IlyaGulya's selfhost_integration 257).
- **Submodules** (`subfill.py`, `run/v5/clean/sub6.sh`, out run/v6/sub6): 75 of run 6's loader's
  "no such file" files miss a submodule's file (aivv73/bend-voxel 41, bendvy-ecs-examples 16,
  hapsland 14, bend-evm 3, bend-zcash-blake2b 1).  Each such repository is copied with its
  submodules' .bend/.c files put in at the gitlinks' commits (bend-vulkan, bend-ui-test, bendlib,
  bend-frontend, bend-collections: context, not corpus); the 75 go on as gav6.
- Not fixable: Emerging-Patterns' pull requests import hub package versions the hub never had
  (404: `0xa17f0215...`, `0x65bf91e1...`); the other "no such file" rows are files no commit has
  (gitignored builds, fixtures generated by tests).
- `upg-corpus.py corpus` no longer checks again a file whose upgrade.py run ended `pass`
  (UPG_RECHECK=1 does): at load 45 the check twice was hours.
