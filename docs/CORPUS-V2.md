# Corpus v2: ana's second run

Plan written 2026-10-03, while run 1 (fp100m → e2 → waves → raw code, vast
54027515) was still training. Run 1 is the baseline; run 2 trains on the
corpus below and is judged against run 1 on one clean evaluation.

## What run 1 showed

Measured on the training transcripts (`run/transcripts-final/*/transcripts.train.nul`)
and on ana's answers to 10 held-out prompts × 5 checkpoints (`run/anatest-2026100{2,3}/`):

1. **The first `## Term` is usually wrong on purpose.** In 80–90% of
   transcripts the assistant's first Term is a mutant (a name replaced by
   another, two words swapped, a word dropped) or a hole; the right Term
   comes after the checker's error. First Term right: Haskell 16%, Lean 10%,
   Agda 11%, Nix 13%, Bend 20%. ana does what it was taught: its answers at
   the first Term are mutant-shaped (`mul-Semigroup mul-Semigroup`,
   `semigroup-Commutative-Semigroup semigroup-Commutative-Semigroup`).
2. **Holes as answers.** 12–13% of Lean and Bend transcripts open with a hole
   in the assistant's Term; after the raw stages ana answers `_` and `?goal`.
3. **ana predicts its own answers fail.** The checker turn after a first Term
   is an error 80–90% of the time, so after each of its four correct answers
   ana predicted an error. Its verdict carries no information.
4. **Unanswerable tasks.** Every Nix unit is a whole file with no Context and
   the User line `Write this Nix expression.`; ana invents a package, version
   and hash.
5. **The holdout leaked.** The 2% holdout was drawn per declaration, and the
   raw stages fed the files those declarations come from: code-train-v3 (raw
   1–9) holds every held-out Haskell, Lean, Agda and Nix file (2,044 of
   2,044) and 81 of 1,190 Bend files; the new raw mix (nr slices) holds 2,832
   of 3,234 (other versions of the same paths, and the Bend community repos).
   Held-out bpb and the 10-prompt test after raw1 are contaminated; run 1's
   final comparison of pre-raw and post-raw checkpoints is biased toward
   post-raw.
6. **Repetition.** Bend2: 126,763 transcripts from 6,283 files (20 per
   file, the "×4" rebuild) and its filler copied 4×. Haskell 5, Lean 6.5,
   Agda 8.8, Nix 1.9 per file.
7. **Phases drift.** Transcripts first, then ~18k steps of raw code: holes
   and other languages' styles (an OCaml/dune package as a Nix answer)
   appeared during the raw stages, even with ~20% transcript replay.
8. **The test measured the wrong thing.** Cutting at the first Term asks for
   the answer where the corpus taught a wrong one, and 10 prompts cannot rank
   checkpoints.

## Principles

- **The assistant's turns are its best effort.** A wrong attempt the model
  should learn to repair is given to it, never written by it.
- **Every checker turn is the checker's own output** (kept from v1).
- **Hold out by repository, before anything else.** One exclusion list, used
  by every stream: transcripts, filler, raw code, by path and by content.
- **Bounded repetition.** Every source byte's exposure per epoch is counted
  and capped.
- **One interleaved mix from step 0.** No transcript phase then raw phase.
- **No corpus change without the evaluation below, before and after.**

## Changes

### C1. Shapes (re-render only: `bend/Transcript.bend`)

`results.nul` already holds, per unit, the original's output, the hole's
goal, every mutant with its error, and the Context, so no unit is checked
again. A new label, `## Attempt`, is a term *given* to the assistant; `##
Term` is only ever the assistant's best answer.

| shape | share | given | the assistant writes | checker turns |
|---|---|---|---|---|
| direct | 50% | User, Context, Type | Term (the original) | the verdict (`[exit 0]`) |
| repair | 25% | User ("Fix `f`: this attempt fails."), Context, Type, Attempt (a mutant), the checker's error | Term (the original) | the verdict |
| fill | 10% (where a hole exists) | User, Context, Type, Attempt with the hole, the goal | Term (the filled original) | the verdict |
| verify | 5% | User ("Does this check?"), Context, Type, Attempt (the original or a mutant, 50/50) | nothing: the checker's turn is the target | the real output |
| term to type | 10% (Haskell only) | User, Context, Term | Type | as v1 |

- The verify shape makes the checker turn after a given attempt balanced
  pass/fail, so ana's own verdict becomes a usable self-check (rank sampled
  answers by its predicted `[exit 0]`).
- Shares are per unit by a hash of its id (reproducible), as in v1. A unit
  with an unused failing mutant may still give a second transcript (repair).
- Gate: every rendered checker line is byte-identical to the check's output;
  per shape, 5 transcripts per language read by eye; the share table
  measured on the rendered set; `nix flake check` with new goldens for
  Transcript.bend (the old ones change on purpose).

### C2. Nix

Drop the direct shape for Nix (whole files from nothing are unanswerable).
Nix keeps repair, fill and verify (the attempt says what the file is) and
stays in the raw stream. Later: units by top-level attribute with a User line
from `meta.description`, pname and version.

### C3. Holdout by repository, one exclusion list (`run/v2/holdout/`)

- **Split:** 2% of repositories / Hackage packages by a hash of the
  repository name (forks and owner prefixes folded: `owner__repo` → `repo`).
  Every unit, filler file and raw file from them is out of training.
- **Exclusion everywhere:** `exclude.paths` (repo/path, all versions) and
  `exclude.sha256` (`run/raw-new/norm_hash.py` keys) filter transcripts,
  filler, code-train-v3, raw-new and every later delivery (legere's too).
- **A vault** for the evaluation: ~150 repositories per language that no
  stream of run 1 or run 2 ever held, so run 1 can be scored clean. Today's
  candidates: `run/raw-new/agda-2f.jsonl` (mix 2, not yet trained), the ~2 GB
  of Lean not delivered (`run/raw-new/.rawla/stage`), the Haskell pool
  `run/raw-new/work/pool/hf-ghcode.jsonl.gz`; Bend has no untrained source
  left (take new repos as they appear). Take the vault out of mix 2 before
  its first slice is built.

### C4. Repetition budget

- Transcripts per source file ≤ 8 (Bend now 20): `MAX_PER_FILE` and the
  second-transcript rule.
- Filler: one copy (Bend's ×4 goes); a window short of filler takes raw code
  of the same language instead.
- Raw code: one pass per epoch; near-duplicates (MinHash, the clean stage's
  settings) across code-train-v3 and raw-new.
- Report per language: tokens, distinct source files, exposures per file.

### C5. One mix

Transcripts and raw code interleaved by `bend-mix` from step 0 at a fixed
token ratio, languages by tokens (start: Haskell 35, Lean 25, Agda 15, Bend
15, Nix 10). The transcript:raw ratio is not guessed: two 1,000-step pilots
from the same fresh start (30% and 60% raw), judged by E1–E3 below (~$1.30 on a
5090).

### C6. Raw quality (the 2026-10-03 agents' filters, made shared)

Generated files (headers, gen/ dirs, bindings), data tables, lines > 2,000
characters, vendored copies and backups, Lean 3, Bend files the Bend2 parser
rejects, per-repository caps (8 MB Haskell, 15 MB Lean, 10 MB Agda), the two
synthetic Agda repos, Hackage files' other versions. One script,
`run/v2/filter.py`, over every raw source.

### C7. Yield (more checked units)

- **Haskell:** 88% of failures import a module of the unit's own package;
  check each unit inside its package's source tree (`-i`); expect several
  times v1's 79k transcripts from the same Hackage files.
- **Bend2:** 46% of community originals fail the 2.0.34 loader (Base name
  clashes, typed arithmetic); upstream 2.0.35 (bendlang/bend) addresses the
  name clashes. A 2.0.35 checker is separate from the trainer's fork.
- **legere:** session code with its real compiler errors is natural repair
  data (a failing attempt and its fix); legere's units go through the same
  shapes and exclusion list.

### C8. Prose (optional, costs money)

v1's User line is the doc comment or `Define f.`. A Claude-written task line
per unit (Message Batches API, prose only) is still planned; ask before
spending.

## Evaluation (written before any v2 data)

On the vault and the repository holdout, per language, for run 1's
checkpoints (fp100m-8803, e2-18125, w1-19080, the last) and run 2's:

- **E1 direct pass@1** (greedy, the answer at `## Term`), and pass@k with
  sampling ranked by ana's own predicted verdict.
- **E2 repair@1:** the given attempt and the real checker's error, then the
  Term.
- **E3 bits per byte** on held-out transcripts (v2 format) and raw files.
- **E4 verdict calibration:** P(`[exit 0]`) against the real verdict.

200 prompts per language minimum; the driver re-indents answers as
`run/anatest-20261003/check2.py` does (the Term is the body dedented) and
sets `BEND_SRC` per class tree.

## Order

| # | step | where | cost |
|---|---|---|---|
| 0 | take the vault out of mix 2 (before ns1 is built) | local | – |
| 1 | holdout split + exclusion list | local | hours |
| 2 | evaluation driver (E1–E4) + run 1 baselines | local CPU (generation) or the box | hours |
| 3 | Transcript.bend shapes (C1, C2) + goldens; re-render every wave (final, next, w1–w4) | local | a day |
| 4 | repetition budget, filters, mix (C4–C6) | local | hours |
| 5 | pilots (C5) | one 5090 | ~$1.30 |
| 6 | run 2 from scratch, fp100m (115M), same trainer | one 5090 | ~$10–15, ask first |
| 7 | yield work (C7), legere feed | local | ongoing |

**From scratch, not a continuation:** run 1 learned the mutant-first habit
over ~50k steps; a fresh start on v2 gives a clean comparison with run 1 on
the same evaluation. A continuation from run 1's last checkpoint is the
cheaper fallback, judged on the same evaluation.
