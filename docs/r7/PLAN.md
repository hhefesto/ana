# R7: the next Bend corpus (2026-11-14)

The user, 11-14: "stop the training, pull the latest weights and work on these" (the eight changes below, from
mugen's assessment of R6), and "We'll only concentrate in bend at the time being, we'll add the other languages
later." Renting a box still waits for the user's approval. The user, 11-15 21:40, on what happens when R7 is ready
(about 05:00): "Wait for your OK in the morning": nothing is rented, nothing starts, until the user's OK.

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
  Since 11-15 20:5x (336e3f8) col10's clean and render (f6.sh) go first, while col10b's decl-new (from 20:21) and
  check go on: col10b's decl-new has seen col10's units, so col10 no longer waits behind it.  The time, from R6's
  run6.log (join 22:53, mix to 01:04, plan-windows to 02:38) and f4's authors' laws (about 3 h for 26,550 jobs):
  run7.sh alone is about 3.5-4 h; with col10's f6 (exlaw, authors' laws, render) before it, R7 is ready some
  6-8 h after run 10's check ends, not 1-2 h as said at 20:47.
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
- Rebalanced again (11-15 21:29, run/v9/col10tail2.sh, ana-col10tail2): of col10tail's 7 shards, 0, 1 and 6 ended
  by 21:20 (about 4 s a unit), and shard 2 held bendJVM's big files (runtime/scheduler, runtime/binary64,
  java/threads, java/strings): about 80 s a unit and up to 12.7 GB a check (so one at a time on olimpo), about 5 h
  alone. A part.0 holds only the kept units: "3,994/8,450 at 21:04" (11-15 notes) counted kept units, not decided
  ones. bendJVM so far: 67 of 254 decided units kept, 64 of them runtime/threads.bend; java/natives 0 of 48. Its 290
  undecided units are held back from R7 (run/v9/col10tail2/e/deferred.ids, for a later check, R8), not dropped
  from the collection. check-salvage now takes `=` for a shard that finished (bend/CheckSalvage.bend; the 20:01
  salvage made again gives the same files; with `=` its decided ids match the hash's shard). Kept so far 14,434
  (9,374 + the finished shards' 2,610 + 2,450 salvaged); the other 1,827 on 8 processes, then ana-r7chain2.
  It ended 22:01: 15,971 of 16,261 kept (290 deferred); clean 22:06: train 15,120 (near_dup 850, contaminated 1);
  f6 (col10's render) from 22:06, 51 chunks (25 by 22:47: 2,512 laws verified, 5 failed, 0 chunk failures).
- col10b's check on 8 processes, not 6 (11-15 22:5x, 12 at first; run/v9/col10bfast.sh, ana-col10bfast): col10b's decl-new
  (from 20:21, 1 CPU, half col10's speed under a load of 25) is the chain's longest wait, then its check; by the
  time the check starts f6, the dry mix and decl-new are done and olimpo (8 cores, 16 threads) idle but for it.
  col10b.sh (ana-col10b) is held (SIGSTOP) at its decl-new, which goes on; when decl-new ends (status 0 and
  units.decl.nul there) col10bfast runs col10b.sh again with CHECK_PROCS=8 (MemoryMax 24G; each step skips what
  is done: the cap, trim, check, clean), then col10b.sh goes on, finds them done and says "col10b DONE" for
  ana-r7chain2. If anything fails, col10b.sh goes on anyway and redoes what is missing (col10bfast's outputs are
  moved aside, none deleted; ana-col10b's MemoryMax raised 8 to 14, then 20 GB for that). About 30 min sooner.
  11-15 23:22, 12 -> 8: the check's memory grows with its processes (each runs UNIT_JOBS=4 bend checks): col10tail2's
  8 peaked at 19.1 GB with 2.6 GB swapped, col10tail's at its 20 GB cap with 9.4 GB swapped (journal), so 12 would
  need ~30 GB of olimpo's 31 and swap, and 8 x 4 = 32 jobs already fill its 16 threads. ana-col10bfast restarted
  (before decl-new ended: nothing of col10b's made yet, nothing moved), env CHECK_PROCS=8, MemoryMax 24G.
  11-15 23:4x, the handoff as planned: decl-new ended 23:44 (12,059 of 12,544 kept: dup 288, seen 177, held 20);
  col10bfast's col10b.sh: cap 2,082 out, 9,977 units, trim 0 (27,598 mutants), check from 23:49:45 on 8 processes
  (held col10b.sh still stopped, its decl-new reaped when it goes on). Rate 70 units a minute while f6's render
  shares olimpo (load 26-30): the check ends about 01:50-02:15. Then f6b (col10b's render; col10's f6 took 2 h for
  15,120 units: exlaw 76 min, authors' laws 3, base 8, render ~37), about 1.3 h, then mugen's chats and run7.sh
  (3.5-4 h): R7 ready about 07:00-07:30 (06:45-08:00), not 06:30. f6's render: 4 parts at a time, ~1 GB in all,
  its laws ~0.1 GB: no memory risk next to the check.
- The filler would have run out in a shard (found 11-15 23:2x, fixed in run7.sh before it ran): bend-windows fills
  each window's gap with the end of the shortest unused filler file long enough (bend/Windows.bend) and refuses a
  shard it can't serve. run7.sh's prose PER (787) made the prose run dry with Bend's 3 copies, after ~1,100 rounds;
  the last ~30 of 224 slices were then only Haskell's, Lean's and Nix's files. tools/fillsim/FillSim.hs (Haskell)
  replays the best fit on R6's real gaps (run/v9/R6/parts/*.plan) with bytes per token measured by bend-prepare
  (Bend 2.55, prose 2.73, Haskell 3.6-4.0): R6's own filler 0 of 224 refused (control); R7's with PER 787, 1 refused
  (shard 198, 87 gaps), 5 with 35% fewer tokens a file. Now the prose runs dry with the last code language (PER 54
  for these counts): 0 refused, also at 35% fewer tokens and 228 shards. Same 867,775 prose pieces, spread over
  every slice; the sessions, K=3 and the code files unchanged. tools/fillsim/run.sh redoes it (40 s).
  R7valid's filler, the same way: the 400 held-out Bend files (valid split K 2 of 256 of the filler's 57,693) x41
  against 8,540 gaps (R6's shards 0-1, for ~15,750 held-out sessions): 0 unserved, also at 35% fewer tokens.
- The dry mix (ana-mix7dry, mix6.sh dry with run7.sh's settings, f5's streams, prove and sorts; 20:18-23:12): rc 0,
  out-copy 0 (run7.sh dies on a copy), 1,404,698 Bend sessions (first 387,253, other 387,090, repairs 626,043, free
  4,312; drop-cap 176,915, ids twice dropped 7,878), as mix7t's 1,398,254 at 17:57, with today's streams. f5's
  retry in run7.sh has nothing to do (its 142 law jobs all DONE, no claims to drop) and the join 98 of 98.
  Its 11 "mix6: not there" streams (11-16 00:1x): the same 10 run/v6 ones R6's mix (run/v9/mixh/bend.log) went
  without (upg5, ff-upg5 never made; a2baa2, a2baa3, a2bhs, a2bm8, a2bplfa4, a2bpre empty dirs; ff-gav6, ff-gen5
  0 units), so R7 loses nothing R6 had.  The 11th, f5's a2bgh51 chains (run/v9/f5/mugen/chain/a2bgh51), is DONE
  but empty (0 bytes), as f3's was for R6: its 14 units give no chains, and are in the mix as
  f5's mugen stream (24 transcripts) and its fixes (8), per the dry mix's log.  (822842a said it had been repaired and would be taken: wrong, corrected here.)
- The sample in the morning: run/v9/r7sample-wait.sh (ana-r7sample) runs r7sample.sh once run7.sh has the mix
  (run/v9/mix7/bend), into run/v9/R7sample.md, and counts lines that look private (want 0).
- Ready to rent, checked 11-15 22:5x (nothing rented): the checkpoint run/v9/run6/out/r6-step115000.checkpoint is
  there (sha256 17a110101bc04e71...); run/v9/vf/validfixed built; Vast: credit $22.44, 0 instances; RTX 5090
  offers that fit run7go.sh's query, not in China, from $0.575/h (Taiwan), then $0.66 (Japan), $0.73 (Texas).
  Again 11-15 23:3x: credit $22.44, 0 instances; from $0.537/h (California), $0.575 (Taiwan), $0.60 (South Korea).
  At R6's 55,127 steps and 2.5 s a step (38 h) that is about $20.6 at the cheapest, only $2 under the credit.
- The credit, again 11-16 00:1x: 2.5 s a step was too low, and R7 is bigger than R6.  R6's own log (run/v9/run6/r6.log,
  11-14 05:36-15:28): 13,000 steps in 9 h 52 min, 2.73 s a step with its validations (2.54 s in its first 2,000,
  2.97 s at the slowest).  R7's mix is R6's plus col10 and col10b: Bend's dry mix 3,270 MB out (R6's 3,160 MB), the
  other four 945 MB (the same), col10's render 249 MB (f6 joined 00:09: 69,289 main, 9,519 chains, 26,287 fixes;
  374 held out), col10b's about 150 MB (its 9,977 units at col10's 16.5 KB a trained unit; a guess until f6b):
  about 4,610 MB against R6's 4,105 MB, so about 62,000 steps if steps go as bytes (the plan's first line is the
  real count).  At 2.75 s a step that is about 47 h, $26.4-28.5 at the cheapest offers now (they moved from
  $0.561 to $0.601/h in ten minutes; credit $22.44, 0 instances): less the credit watch's $1.00 floor and about an
  hour of setup and gate, the credit covers about 45,000-49,000 steps, 73-79% of R7, and the credit watch ends it
  there (saves every 5,000 steps), before the plan's end (its learning rate's decay).  About $8 more covers all
  of it; $10 leaves a margin for a slower box.  run/v9/run7go.sh (ignored by git, as run/ is) now prints this from
  the plan's real count (2.75 s a step, the cheapest offer then, the share the credit covers) before it rents.
- f5's join (15:13): 98 of 98 streams, 286 splits; 2,099,453 Bend sessions for training before the mix's cap,
  15,666 held out (39 MB) for R7valid.
- mugen's chats (CorpusV2/MugenLog.bend, run/v9/mlog): 654 turns with Bend calls give only 18 sessions that fit
  the 2,048-token window (93 too long, 9 private, 7 with another file's edit; 127 pieces end in a passing check).
  /tmp/bx/chk.zsh now counts as a check (+1). A small stream: the window is the limit.  11-15 20:4x (17ddb64): a
  piece too long for the window is kept shorter instead of dropped (its echoes cut to 12 lines, else its last try
  alone): 57 sessions on the 10:51 raw.nul (12 cut, 27 last try; 49 still too long, 9 private, 7 another file's
  edit); a scan of the output finds no LAN address, email, password, sudo, netsem or /home/hhefesto.
  r7chain2's mlog step runs run/v9/mlog/ml, built from bend/tests/mugenlog.bend (the mugenlog step alone: 16 s,
  213 MB, against the full bend-corpus-v2's 15 min, 17 GB).  Tried ahead, 11-15 23:26, as r7chain2 will run it
  (export.sh then ml, into /tmp/bx/mlogtest): rc=0 both, 75 s; 688 turns with Bend calls, 66 sessions kept (16 with
  echoes cut, 30 as their last try; 9 private, 61 too long, 7 another file's edit left out). Its scan: no LAN
  address, email, password, sudo, netsem, /home/hhefesto, API key or private key; "hhefesto" only as a file's owner
  in `ls -l` lines, and the long strings are test hashes and /nix/store names.
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
