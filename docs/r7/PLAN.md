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
| 1 | New sessions, not replays; at most 2-3 copies of a code file | not built. FILLER_COPIES ≤ 3 leaves most windows without a filler file (978k windows, about 65k distinct Bend files), so it needs 7's prose as filler. New code needs new sources (open question) |
| 2 | Laws in the request | fill and repair asks state the unit's laws (Transcript.bend `f3.ask.laws`); exlaw now probes the head's own data types and Base's `Maybe` (ExlawText.bend): on own5's first 300 units 179 get laws, against 61 |
| 3 | Sessions from law mutants | follows 2: 68 law mutants on those 300 units, against 17 |
| 4 | Look before retrying | built (Transcript.bend `f3.relook`): on own5's first 60 units, 63 of 121 retries after a failed write look first (0 before); every echo is agent-mugen's (f3-roundtrip.zsh) |
| 5 | Two definitions a session, nearly empty files, sorts with fuel | helpers and scratch exist (above); a fuel sort kind is not built |
| 6 | More proofs, induction with the rewrite step | not built |
| 7 | Prose | the source's `#` comment is already in the ask and her add (form 2's kinds); theory filler (run/v9/theory, 5.8 GB downloaded, 850 MB of sources) not cleaned yet |
| 8 | A fixed validation set | the trainer reads one (TrainDense.bend `VALID_CORPUS`, checked, not run); the set itself not built |

## The pipeline (olimpo, CPU)

1. `run/v9/f4.sh law`: exlaw again on f3's 818 exlaw outputs (units with laws pass through).
2. `run/v9/f4.sh work` with the new bend-transcript, `join`.
3. The mix (Bend only), the filler (≤ 3 copies plus theory prose), the fixed validation set, plan-windows.
4. A sample for the user, then the user's call on renting.
