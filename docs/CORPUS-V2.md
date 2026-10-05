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
9. **Letting ana go on does not rescue it.** Given 300 tokens, raw9-37000
   writes its own predicted error and a second Term: still 1/10 (the same
   Lean proof); the second Term repeats the first or is another wrong guess
   (after a hole: `GLenum . fromIntegral`). On these prompts knowledge is the
   limit as much as the format: C1 should remove holes and make the verdict
   informative, not by itself raise pass@1. The evaluation, not the 10
   prompts, decides.

10. **2026-10-04, nr7-step61000: 0/10.** It takes the right names from the
    Context and the right outer structure (Lean: one rewrite too many; Bend:
    the right helper, wrong arguments; Agda: both lemmas, applied instead of
    paired), and still answers with mutant shapes, holes, clause loops and the
    same invented Nix package for both Nix prompts.

## Same data, presented to reduce the errors (the user, 2026-10-04)

Run 2 trains on the units, files and raw code run 1 was fed; only how they
are presented changes:

| run 1's error | the presentation that answers it |
|---|---|
| a wrong first Term (mutant-shaped answers) | a mutant is only ever a given `## Attempt`; the Term is always the original (C1) |
| holes as answers | the hole is a given Attempt with its goal (fill); the Term fills it (C1) |
| its verdict predicts failure | after a Term the verdict is the original's; `verify` judges given attempts, half passing (C1) |
| a direct ask read as a repair | each shape opens with its own User line, so after an ask and its Type comes the Term (C1) |
| invented Nix packages | Nix is never asked from nothing: repair and verify only (C2) |
| loops and memorised copies | no transcript twice: Bend's 4 identical copies become 4 different presentations; filler once (C4) |
| drift in the raw phase | one mix of transcripts and raw code from step 0 (C5) |
| a contaminated test | the repository holdout and the vault (C3) |

**Tools (2026-10-04): Bend only.** The user: "ana and all my projects are
Functional Programming, no python is allowed." Corpus v2 was first built with
Python scripts; every one is ported to `bend-corpus-v2` (`bend/CorpusV2.bend`
and `bend/CorpusV2/`: Lib, Holdout, Pool, Raw, Combine, Eval, Steps; `nix run
.#deploy -- corpus-v2 SUBCOMMAND`), each proven byte-identical to the Python on
the outputs in `run/v2/` (holdout, vault, units, filler, raw, plans, prompts,
reports), and the Python is deleted. The port found one stale output:
`run/v2/raw/bend.jsonl` was written before filler.py's one-version-a-path fix,
so 153 Bend files were in neither the filler nor the raw stream (rebuilt).

**Raw only from here (the user, 2026-10-05):** "Let's stop the checked
transcripts. Let's just feed it raw code. The checked transcripts we already
have should be kept, but new additions to our corpus should be raw /
un-checked." The additions go through `bend-corpus-v2 raw` (C6's filters, the
holdout by id and path) into `run/v2/raw-*/` and the one mix (C5): the Lean
proof sets STP and NuminaMath-LEAN (`run/v2/raw-hf/lean.jsonl`, 688,251
files, 498 MB) and The Stack v1's deduplicated Agda, Haskell, Lean and Nix
(`run/v2/raw-stack/`: Haskell 370,236 files / 1,577 MB, Nix 109,107 / 245 MB,
Agda 6,801 / 36 MB, Lean 7,659 / 27 MB after the filters).

**A tool's output carries no loss (2026-10-05, docs/AGENT.md).** ana is never
trained to write a checker's turn: with `TRAIN_MASK=kinds` a target's weight
is its role's (0 on a tool's echo and on a given `## Attempt`), read from the
window's own tokens, so the transcripts are kept as they are and every
checker turn is still the checker's own output, as context. The `verify`
shape, whose target was the checker's verdict, is dropped from the transcript
windows (46,806 of 585,060 train transcripts). This replaces C1's "its verdict
predicts failure" answer and E4's calibration target below: a calibrated
"will this check?" belongs to a decision model, never to ana's text.

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
- **Built 2026-10-04** (commit 79ca7e1): `TRANSCRIPT_FORMAT=2` in
  `bend/Transcript.bend` (format 1 stays the default and re-renders w4's Bend
  byte for byte). User lines: the ask (doc or `Define`/`Prove`), the ask then
  "This attempt fails. Fix it." (repair), the ask then "Fill the hole."
  (fill), "Does this check?" (verify). A unit gives COPIES presentations
  (Bend 4, the rest 2), its first by the shares above, then the first it can
  give and has not given of: direct, repair m, fill, term to type, repair m1,
  its verify, the other verify, repair m2. `bend/tests/transcript.bend` (in
  `bend-tests`): each shape's turns, the direct shape byte for byte, every
  Term the original, distinct presentations, Nix never direct.
  Rendered (`tools/corpus-v2/render.sh` from `bend-corpus-v2 pool`'s units, train):
  Bend 300,759 transcripts from 80,748 units (263 MB), Haskell 115,698 from
  57,858 (123 MB), Agda 67,512 from 33,770 (66 MB), Lean 65,644 from 32,856
  (82 MB), Nix 25,016 from 12,572 (36 MB); no text twice.
  Added 2026-10-05 (`tools/corpus-v2/py2bend.sh`; the user: "Translate them
  to bend and add them to the corpus, then delete"): `own:py2bend`, the Bend
  translations of the project's 58 one-off Python scripts (24,436 lines; the
  Python is deleted), not held out (its unit scores 764): 3,086 units, every
  one checked, 2,743 after clean (23 exact and 320 near duplicates), 10,431
  transcripts appended to Bend's train (now 311,190), its files to the
  filler. `windows.sh` interleaves `bend:124` (was 120) so the five
  languages still run dry together (~2,510 rounds each). Measured on 600
  units a language at COPIES 2: every unit gives a direct transcript and most
  a repair; fill and verify 3–5% each; verify passes 41–54% (Nix 300/600).

### C2. Nix

Drop the direct shape for Nix (whole files from nothing are unanswerable).
Nix keeps repair, fill and verify (the attempt says what the file is) and
stays in the raw stream. Later: units by top-level attribute with a User line
from `meta.description`, pname and version. Built: Nix has no holes, so its
first presentation is repair 80, verify 20; its second the other.

### C3. Holdout by repository, one exclusion list (`run/v2/holdout/`)

- **Split** (built: `bend-corpus-v2 holdout`): 2.0% of holdout units by
  sha256("corpus-v2 holdout\0" + unit) mod 1000 < 20, a rule so later sources
  split the same way. A unit is a repository / Hackage package (folded:
  `owner__repo` → `repo`, `v2.repo.of` in `bend/CorpusV2/Lib.bend`); a repository with more than
  300 files is split by each file's own directory (its full parent path:
  `Mathlib/RingTheory/Ideal`, a nixpkgs package's directory; two components
  held out all of `Mathlib/RingTheory` at once), so a giant library is never
  all in or all out and a module family stays together; a dataset of
  one-file records (`hf:goedel-workbook`, ...) by record. Every unit, filler
  file and raw file from them is out of training; `bend-corpus-v2 exclude IN OUT`
  filters any JSONL or NUL stream.
- **Built 2026-10-03 23:40** (`run/v2/holdout/`: `units.tsv`, `exclude.paths`,
  `exclude.sha256`, `summary.txt`; tools in `tools/corpus-v2/`): 3,977 split
  units and the 450 vault repositories; 55,253 paths, 56,169 content keys
  (every version's). Held out, distinct files (the vault included): Agda 7.3%,
  Lean 4.7%, Haskell 3.0%, Nix 2.6%, Bend 0.6% (Bend's code sits in a few big
  repositories). Checked: the Agda vault is dropped whole; a 30,000-file
  sample of code-train-v3 loses 1.94% (579 by unit, 3 copies by content); of
  v1's 1,050 Lean holdout transcripts only 39 are in v2's holdout, so v2
  renders its own.
- **Exclusion everywhere:** `exclude.paths` (repo/path, all versions) and
  `exclude.sha256` (`v2.key` keys, `bend/CorpusV2/Lib.bend`) filter transcripts,
  filler, code-train-v3, raw-new and every later delivery (legere's too).
- **The vault** (built 2026-10-03 23:27, `bend-corpus-v2 vault`): 150
  repositories per language with ≥ 3 files that no training stream of run 1
  holds (`run/v2/holdout/stream-index.json`: code-train-v3, every raw-new
  delivery, every wave's transcripts and filler), chosen by sha256 of the name:
  Agda from mix 2's agda-2f (5,670 files, 40 MB; taken out of mix 2 and
  ns1–ns4 rebuilt before any trained, `tools/corpus-v2/restage-ns.sh`), Lean from the
  undelivered pool (13,930 files, 170 MB), Haskell from the leftover HF pool
  (5,322 files, 16 MB). Files in `run/v2/vault/LANG.jsonl`, names in
  `run/v2/holdout/vault.tsv`. Bend has no untrained source: its vault takes
  new repositories as they appear. Run 1 can be scored clean on the vault.

### C4. Repetition budget

- Transcripts per source file ≤ 8 (Bend now 20): `MAX_PER_FILE` and the
  second-transcript rule.
- Filler: one copy (Bend's ×4 goes); a window short of filler takes raw code
  of the same language instead.
- Raw code: one pass per epoch; near-duplicates (MinHash, the clean stage's
  settings) across code-train-v3 and raw-new.
- Report per language: tokens, distinct source files, exposures per file.
- **Built 2026-10-04:** the units (`bend-corpus-v2 pool`): every unit
  run 1's transcripts came from (final, next, w1–w4, train and holdout), its
  record from whichever wave's results hold it, one per declaration (807 Bend
  duplicates dropped), split by the repository holdout: train Haskell 57,858,
  Agda 33,770, Lean 32,856, Nix 12,572, Bend 80,748; holdout 1,175, 332, 857,
  398, 84 (Bend's code sits in few repositories). No identical transcript:
  Bend's ×4 is four different presentations (above), not four copies. The
  filler (`bend-corpus-v2 filler`): the waves' source files once (17,056 Agda and 47,222
  Bend copies dropped), held-out files out. The raw code (`bend-corpus-v2 raw`):
  code-train-v3 and every raw-new delivery (mix 1 and mix 2), each file once,
  held-out and filler files out, the C6 filters, shuffled by id hash: Haskell
  1.84 GB, Lean 1.24 GB, Agda 517 MB (Bend and Nix files are nearly all
  filler already: 2.3 MB and 0.9 MB left).

### C5. One mix

Transcripts and raw code interleaved by `bend-mix` from step 0 at a fixed
token ratio, languages by tokens (start: Haskell 35, Lean 25, Agda 15, Bend
15, Nix 10). The transcript:raw ratio is not guessed: two 1,000-step pilots
from the same fresh start (30% and 60% raw), judged by E1–E3 below (~$1.30 on a
5090).

The raw mix (2026-10-05) is run/v2/raw's languages plus every run/v2/raw-*
 file, each weighted by its document count against run/v2/raw's Haskell
(`tools/corpus-v2/rawshards.sh mix`). Its sources must not share an id:
`run/v2/dedupe-ids.sh` drops a Stack v1 file whose repository path is already
in run/v2/raw (1,104: older versions of files the pool has; identical content
was dropped at the build) or earlier in the Stack (6), and renames the 15
NuminaMath problems with a second human proof `ID#2`.

### C6. Raw quality (the 2026-10-03 agents' filters, made shared)

Generated files (headers, gen/ dirs, bindings), data tables, lines > 2,000
characters, vendored copies and backups, Lean 3, Bend files the Bend2 parser
rejects, per-repository caps (8 MB Haskell, 15 MB Lean, 10 MB Agda), the two
synthetic Agda repos, Hackage files' other versions. One script,
`bend-corpus-v2 raw`'s filters, over every raw source.

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
`bend-corpus-v2 check` does (the Term is the body dedented) and
sets `BEND_SRC` per class tree.

**Built 2026-10-04** (CPU generation is ~2.5 min an answer, so the set is
smaller than 200 a language for now): `bend-corpus-v2 evalset` cuts 280
prompts from the held-out format 2 transcripts, 40 direct and 20 repair per
language (Nix: 40 repair): the direct prompt is the same text in format 1 and
2, so both runs answer one question; a repair prompt has a format 1 version
for run 1 (the ask alone, the mutant under `## Term`). `bend-corpus-v2 gen CKPT
DIR FORMAT` answers (greedy, 100 tokens, bend-generate on the CPU) and
`bend-corpus-v2 check DIR` lifts each answer into its held-out unit and runs the
real checker (Bend per source tree). E3: `tools/corpus-v2/evals.sh` builds
`run/eval/v2-tr-LANG.corpus` (held-out format 2 transcripts) and
`run/eval/v2-vault-LANG.corpus` (~2 MB of each vault language, up to 5 files a
repository); run 1's fp100m-8803, w1-19080, w3-40731 and last checkpoint are
scored on them on box 2 before it is destroyed (`box-baseline.sh`).
**Run 1's E3 baseline (2026-10-04 13:14–13:23, box 2, bits per byte):**

| corpus | fp100m-8803 | w1-19080 | w3-40731 | nr9-67717 |
|---|---|---|---|---|
| v2-tr Agda | 0.446 | 0.410 | 0.344 | 0.265 |
| v2-tr Bend | 0.397 | 0.389 | 0.322 | 0.223 |
| v2-tr Haskell | 0.394 | 0.378 | 0.331 | 0.243 |
| v2-tr Lean | 0.478 | 0.442 | 0.391 | 0.311 |
| v2-tr Nix | 0.497 | 0.474 | 0.403 | 0.347 |
| vault Agda | 1.443 | 1.402 | 1.129 | 0.852 |
| vault Haskell | 1.057 | 1.070 | 0.799 | 0.720 |
| vault Lean | 1.146 | 1.147 | 0.913 | 0.675 |

Only the vault is clean for run 1: its raw stages fed the held-out units'
files (finding 5), so its v2-tr numbers are optimistic. On the vault the raw
stages cut bits per byte by 30–40% (w1 → nr9): run 1's code knowledge comes
mostly from raw code. nr9-step67717 itself was lost with the box (a failed
pull); its numbers above were taken on the box.

**Run 1's E1/E2 baseline (2026-10-05, `bend-corpus-v2 gen/check`, CPU,
greedy, 100 tokens, format 1 prompts).** Only units held out by BOTH v1's
per-declaration split and v2's repository split are fair to run 1: about 98% of
v2's holdout units were in run 1's training transcripts. There are 59 such
units, 99 prompts (`evalset --both`; control 99/99):

| checkpoint | direct | repair | all |
|---|---|---|---|
| fp100m-8803 (transcripts only) | 5/50 | 9/49 | 14/99 |
| w1-19080 (all transcript waves) | 4/50 | 14/49 | 18/99 |

By language, w1: Agda direct 1/4 repair 3/3, Bend 0/4 and 2/2, Haskell 3/17
and 7/14, Lean 0/25 and 2/21, Nix repair 0/9 (it never closes the fence
within 100 tokens: a whole file). Repair is ana's strength; direct answering is
what format 2 targets. The post-raw checkpoints are not fair on these units
(the raw stages fed v1's held-out files).

E4 (verdict calibration) is not built: it needs the probability of `[exit 0]`
after a verify prompt, which the trainer's eval does not print.

## Order

| # | step | where | cost | status |
|---|---|---|---|---|
| 0 | take the vault out of mix 2 (before ns1 is built) | local | – | done 10-03 |
| 1 | holdout split + exclusion list | local | hours | done 10-03 |
| 2 | evaluation driver (E1–E4) + run 1 baselines | local CPU (generation) or the box | hours | E1–E3 built 10-04; baselines running |
| 3 | Transcript.bend shapes (C1, C2) + goldens; re-render every wave (final, next, w1–w4) | local | a day | done 10-04 |
| 4 | repetition budget, filters, mix (C4–C6) | local | hours | built 10-04 |
| 5 | pilots (C5) | one 5090 | ~$1.30 | ask first |
| 6 | run 2 from scratch, fp100m (115M), same trainer | one 5090 | ~$3–5 at the v2 size, ask first | |
| 7 | yield work (C7), legere feed | local | ongoing | |

**From scratch, not a continuation:** run 1 learned the mutant-first habit
over ~50k steps; a fresh start on v2 gives a clean comparison with run 1 on
the same evaluation. A continuation from run 1's last checkpoint is the
cheaper fallback, judged on the same evaluation.
