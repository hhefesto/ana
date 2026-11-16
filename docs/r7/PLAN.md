# R7: the next Bend corpus (2026-11-14)

The user, 11-14: "stop the training, pull the latest weights and work on these" (the eight changes below, from
mugen's assessment of R6), and "We'll only concentrate in bend at the time being, we'll add the other languages
later." Renting a box still waits for the user's approval.

## R6 stopped

- `pkill -x traind-next` on Vast 60621379 at 15:28 (UTC-6), right after `saved out/r6-step119500.checkpoint`
  (step 119,502 of 161,627). The chain (bend-ops chain) saw the trainer die at 15:51, scored the pulled checkpoints,
  pulled r6-step119500 (sha256 546cfeae...), held every checkpoint on the box to its copy here, and destroyed the
  instance at 16:11 (run/v9/run6/DESTROYED). ft-run6-guard disabled (a boot would restart the chain against no box).
- bits per byte, the chain's scores (transcript-fp / transcript-next): r6-110000 0.712 / 0.703, r6-115000 0.705 /
  0.693, r6-119500 0.719 / 0.714. The best validation reading (0.9424 at step 107,000) was never saved.

## Three numbers in the 11-14 assessment were wrong

- **The filler is 23.5% of the trained tokens, not 72%.** R6's 978,145 windows hold 471,263,828 filler tokens
  (run/v9/R6/parts/*.plan, the `f` column) of 2,001,284,670. The 72% was of the plan's input bytes (filler.nul 14 GB
  against the mixes), and a window takes only the end of one filler file. What is true: each Bend file is in the
  filler 24 times (FILLER_COPIES=bend:24, run6.log), so the same file ends come back.
- **Helpers were in R6:** 68,044 `mugen-direct-helper-K` and 15,300 `mugen-direct-scratch-K` sessions (5,759 and
  1,188 more with `-miss`), 6.4% of R6's 1,403,306 Bend sessions. R6 trained on them for only 13,000 steps; R5g,
  where it started, had none.
- **Law failures were in R6:** about 24,000 sessions show a check failing at a law (`Location: f.exK`), from
  exlaw's 13,194 law mutants (repairs 9,784, the rest fixes and chains).

## The eight changes, and where each stands

| # | Change | State |
|---|---|---|
| 1 | New sessions, not replays; at most 2-3 copies of a code file | built, running (11-15): run7.sh's filler takes each Bend file K=3 times (run7.sh), the prose filling the rest (7). New code: run 10's collection (run/v9/col10.sh, ana-col10: run 9's repositories' growth, BendHub, upstream, the 26 licensed new repositories; its gate at 12,500 of 32,096 files at 13:27) and run 10b (run/v9/col10b.sh, ana-col10b: the 16 unlicensed ones, the user, 11-15: "Include them"), each then rendered with laws by f6.sh; the authors'-law asks (f5), the prove units (6), the sorts (5), mugen's chats |
| 2 | Laws in the request | fill and repair asks state the unit's laws (Transcript.bend `f3.ask.laws`); exlaw now probes the head's own data types and Base's `Maybe` (ExlawText.bend): on own5's first 300 units 179 get laws, against 61 |
| 3 | Sessions from law mutants | follows 2: 68 law mutants on those 300 units, against 17 |
| 4 | Look before retrying | built (Transcript.bend `f3.relook`): on own5's first 60 units, 63 of 121 retries after a failed write look first (0 before); every echo is agent-mugen's (f3-roundtrip.zsh) |
| 5 | Two definitions a session, nearly empty files, sorts with fuel | helpers and scratch exist (above). Sorts with fuel: built (bend/Sorts.bend, `bend-sorts`; run/v9/f8.sh, ana-f8): small files written from nothing, merge sort (by turns, by halves), quicksort, insertion sort on Nat, U32, a Card, a Task, either order, recursing on fuel where the parts aren't structurally smaller, laws on fixed inputs from a reference sort. 64 files: all check; reversing each file's first law's expected list fails all 64; 406 units, 179 after clean, 1,304 sessions (806 first-time, 141 chains, 357 fixes). The full run: 512 files, 3,243 units |
| 6 | More proofs, induction with the rewrite step | built, running (run/v9/f7.sh, ana-f7): `bend-corpus-v2 authlaw prove` makes a unit of each authors' law that checks for every input (f4/authlaw.pass), its proof the hole, its mutants the proof's own steps changed; 5,401 units from the 10 roots, 4,379 with a rewrite step (`%`) or a match. Then decl-new, the cap, trim, the check, clean and f6.sh's render (EXLAW=0 AUTHLAW=0: the law is the statement) |
| 7 | Prose | the source's `#` comment is already in the ask and her add (form 2's kinds); the theory prose cleaned (run/v9/theory/filler.sh, bend-theory-cut, 11-15 11:37): 867,775 pieces, 2.32 GB from 45,737 documents (arXiv, nLab; credits.tsv) |
| 8 | A fixed validation set | the trainer reads one (TrainDense.bend `VALID_CORPUS`, checked, not run); the split by file key (CorpusV2/Valid.bend, ValidText.bend, VALID_K 2 of 256) in every join; run7.sh writes the set as run/v9/R7valid |

## The authors' laws (collector A, 11-14/15)

`bend-corpus-v2 authlaw` (`bend/CorpusV2/AuthLaw.bend`, `AuthLawText.bend`), the step `run/v9/f4.sh authlaw`,
its output in `run/v9/f4/authlaw`. The run there is the one made on 11-14 in /tmp/bx/authlaw with the same code
before it moved here (the unit ids are f3's), reused. The moved code gives the same records on the 254 jobs of 3
repositories, and on 90 of the 92 jobs of 3 of f3's parts run through `f4.sh authlaw` (the other 2: a timeout then,
a pass now).

- 97,057 laws in 5,647 LAWS.bend files; 26,550 (unit, law) jobs on 9,692 units.
- 19,105 pass `--check-only`: 13,888 laws stated for every input, 5,217 that check fixed inputs; 6,939 units have
  a passing law, 5,517 one for every input. None is a `--verdict`: Lean isn't on olimpo.
- The rest: error 4,062 (the repository's check file rejected before any law), too-big 1,868, timeout 481, and
  1,034 others (no proof, open, undecided, failing, holes, `@unsafe`, missing, not run).
- The user, 11-15: a law that names several functions goes to "Every function it names, as now"; the laws that
  check fixed inputs: "Yes, ranked below laws that hold for every input" (`al.ranked`, `al.rank`); a law that
  passes only after other failing laws or helpers were taken out of its proof file counts: "Yes: the law's own
  proof checks, and the record says what was removed"; of the lawres prototype's guessed laws, "No, keep only laws
  proven for every input" (its 18 compared with a reference only at the test inputs are not kept).
- The ask that shows the law as the spec (Transcript.bend's authors'-law ask, the user, 11-15: "Yes"): built; f5
  re-renders every part with it (run/v9/f5, ana-f5-r*): 6,780 units get 14,515 laws; 148 records left out, a
  held-out file's (the fixed validation split, by file). The laws' comments: as the source has them.
- Lost on 11-09, found 11-15: run/v2's raw files (raw, raw-hf, raw-stack, raw-new3) and run/v4/collect were
  deleted with that day's cleanup. What still needs them: run 10's collection (its corpus files, for the dedup and
  the contamination check: their keys are in the key cache, and Collect.bend now keeps a gone file's cached keys;
  the vault lists, their names now from those keys, run/v9/col10fix/vault-v2v4.repos) and decl-new's held list
  (run/v5/leak/held.args.note: the same records stay held, as units). The big-repository lists of run 3 and run 4
  are gone for good: a repository they split by directory and no later collection listed is split by its size now.

## The pipeline (olimpo, CPU)

1. `run/v9/f4.sh law`: exlaw again on f3's 818 exlaw outputs (units with laws pass through). Done 11-14 23:02,
   0 failed. `run/v9/f4.sh authlaw`: the authors' laws (above).
2. `run/v9/f4.sh work` with the new bend-transcript, `join`.
3. The mix, the filler (≤ 3 copies plus theory prose), the fixed validation set, plan-windows. The mix keeps
   R5g's Haskell, Agda, Lean and Nix sessions, as R6 did (the user, 11-15: "Keep them, as R6 did").
   mugen's own transcripts go in too (the user, 11-14: "Add mugen's transcripts to the corpus (should have a lot
   of bend code)"; 11-15: "Add laws where you can"). They aren't built yet. mugen's main chat has 1,238 turns,
   and 538 of them write, edit or check Bend (7,313 tool calls). The agents' chats are more.
4. A sample for the user, then the user's call on renting.

## Ready to train (11-15, the user: "be ready to train on my approval")

- The chain: run/v9/r7chain2.sh (ana-r7chain2): run 10's and 10b's collections, their renders (f6.sh), the
  prove units (f7) and the sorts (f8) waited for, mugen's chats again, the prose, then run7.sh (the mix, the
  filler, plan-windows, R7valid). It ends at "end: run/v9/R7 is ready" in run/v9/run7.log; it rents nothing.
- Run 10's check, rebalanced (11-15 20:01, run/v9/col10tail.sh, ana-col10tail; as run/v8/col9-finish2.sh): its 6
  processes shard by file, and shard 1 held the slow files (gildrb-site's lexer, about a minute a unit): 1,234 of its
  3,612 decided in 2 h against 1,864-2,492 for the others, so it would have ended 2-3 h after them. The chain was
  frozen, the six part.0 copied, the chain stopped; check-salvage: 9,374 kept, 12,588 of 21,038 decided; the other
  8,450 on 7 processes (prime to 6, so shard 1's files spread), TIMEOUT 180 as before, the salvaged results in
  front; then ana-r7chain2 again (col10.sh goes on from clean). The stopped shards' stats are lost ("kept" and
  "recovered-from-killed-shards" stand for them), as col9's were. A count of mine before this read a part.0's NUL
  fields as pairs: they are triples (position, id, record), so "11,273 done at 19:39" was half again too many.
  Its freeze then stop failed ("Cannot perform operation on frozen unit"): thawed and stopped by hand at 20:01; a
  next use thaws first.
- f5's join (15:13): 98 of 98 streams, 286 splits; 2,099,453 Bend sessions for training before the mix's cap,
  15,666 held out (39 MB) for R7valid.
- mugen's chats (CorpusV2/MugenLog.bend, run/v9/mlog): 654 turns with Bend calls give only 18 sessions that fit
  the 2,048-token window (93 too long, 9 private, 7 with another file's edit; 127 pieces end in a passing check).
  /tmp/bx/chk.zsh now counts as a check (+1). A small stream: the window is the limit.  11-15 20:4x (17ddb64): a
  piece too long for the window is kept shorter instead of dropped (its echoes cut to 12 lines, else its last try
  alone): 57 sessions on the 10:51 raw.nul (12 cut, 27 last try; 49 still too long, 9 private, 7 another file's
  edit); a scan of the output finds no LAN address, email, password, sudo, netsem or /home/hhefesto.
  r7chain2's mlog step runs run/v9/mlog/ml, built from bend/tests/mugenlog.bend (the mugenlog step alone: 16 s,
  213 MB, against the full bend-corpus-v2's 15 min, 17 GB).
- The launcher, run only after the user's approval: `RENT_OK=yes C=CHECKPOINT run/v9/run7go.sh` (as run6go.sh;
  tools/runs/run7.cfg, run/v9/run7.stages, bend/gpu/r7-box.env). It copies R7valid to the box and starts r7
  with VALID_CORPUS; TrainDense's fixed validation has never run on a GPU, so it stops (and destroys the box)
  if r7.log has no "fixed windows of" line within 20 minutes. Without RENT_OK=yes it rents nothing.
- TrainDense's reading of VALID_CORPUS, tried on the CPU (11-15 19:53): bend/tests/validfixed.bend calls its
  `valid.fixed` as the trainer does (compiled: `bend bend/tests/validfixed.bend -o ...`; the interpreter overflows
  its stack). On r7t's R7valid it prints "validation: 64 fixed windows of ...", as on R6's shard 0; with the byte
  tokenizer it refuses ("corpus tokenizer identity does not match"). A file that isn't a corpus (mix.nul) crashes
  it (memory fault) before the FTCC message: run7go.sh's 20-minute check catches that. The GPU part is the run's.
  run7go.sh now runs it (run/v9/vf/validfixed) on the real R7valid before it rents: no line, nothing rented.
- The checkpoint, the user, 11-15: "R6's step 115,000, its best chain score": r6-step115000 (run/v9/run6/out,
  sha256 17a110101bc04e71..., the box's sum), run7go.sh's default now.  Before that answer: the user's calls: the
  checkpoint r7 starts from (default r5g-step106500, where R6 started; or r6-step115000,
  R6's best chain score), and the credit.  R6's plan was 55,127 steps (R6/plan-fp100m-b16-windows.tsv: from
  106,500 to 161,627; the 11-15 note's "161,627 steps, about $107" counted the start's steps too): about 38 h at
  2.5 s a step, $36 at most at $0.95/h, $25 at R5g's $0.656/h.  R7's count is its plan's first line, known when
  run7.sh ends; run7go.sh prints the hours and the most it costs before it rents.
- The sample: run/v9/r7sample.sh writes run/v9/R7sample.md from the Bend mix, each kind's sessions.
- run7.sh's later stages, tried small (run/v9/r7t.sh, 11-15 15:46): 920 sessions, Bend's 2,981 files x 3 (19 of
  3,000 held out), 3,000 prose pieces as a language of its own (prose:44 a round), the other four's files: rc=0,
  1 shard, 411 windows; R7valid 150 sessions and their 19 held-out files x 9, 111 windows. Not the GPU: that is
  run7go.sh's 20-minute check.
- Run 10's collect (ana-col10) stopped at keys at 15:38 (run/v2/raw/lean.jsonl, deleted 11-09), as run 10b's
  had; r7chain2 went on from keys at 15:39 with run/v9/col10fix's bend-corpus-v2 (the files' cached keys).
  A note: an a2bgh session's key is its path without the repository (`mods/...`), so it is held out by path.
- A look at f5's sessions (r7sample.sh on 7 streams, 11-15 16:0x): of 11,087 authors'-law asks, 131 import one
  alias twice and 85 give one law twice (the same law from two copies of a file, e.g. aivv73__bend-voxel's
  material_palette_lookup with `./material.bend` and `../../material.bend`): about 1%, left as they are. mugen's
  chats had a LAN address (192.168.3.6) in their shell lines; the user, 11-15: "Yes" (remove it): MugenLog.bend
  writes it as `delfos` (8aeaa53, pushed); the remade run/v9/mlog/mlog.nul has 0 hits, and r7chain2's mlog step
  uses the same bend-corpus-v2 (col10fix/gcroot-cv2).
- Vast credit, 11-15 19:40: $22.44, no box: under an R6-sized run ($25-36, above).  The credit watch stops the
  trainer when the credit runs low (bend/gpu/credit-watch.sh), and the chain has pulled a save every 5,000 steps:
  a short credit ends r7 early; the saves are kept.
