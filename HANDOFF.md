# Session Handoff

This file holds everything needed to continue this work from another machine and account. It was restarted from zero on 2026-09-25 for a new path. The previous handoff (the v3 hot start and the dense trainer) is in git at `41e1920:HANDOFF.md`, and master's Haskell-era trainer is at the tag `haskell-final`.

## ▶ CONTINUE HERE (2026-09-25, night): the pipeline works on samples; next is the Haskell yield, then the full CPU run

### What happened on 2026-09-25

Five commits between 12:18 and 13:59, all local, none pushed. Together they remove 161,723 lines and add 36,597.

| commit | what | verified by |
|---|---|---|
| `0908864` | `bend-pack`, `bend-prepare`, `bend-plan-segment` in Bend | `cmp` against master's Haskell tools on a 20k-file plan, the five code evals and the transcript eval; sha256 pairs in `docs/BEND-CORPUS-TOOLS.md` |
| `228bd06` | Haskell trainer, Futhark kernels, Agda spec, 22 deploy scripts and the bpe10m weights deleted; `flake.nix` 1,530 → 278 lines | tag `haskell-final` keeps them; `nix flake check` passes |
| `5633395` | fork `hhefesto/bend2` `ft-kernels` rebased onto upstream 2.0.28; the repo takes it as a flake input | the fork's tests; `bend bend/Everything.bend` |
| `41e1920` | dense store 26% smaller (the workspace was counted twice), exact size check, preset `fp100m` (ctx 2048) | `bend/tests/dense-identity.sh` goldens in the `bend-dense` check |
| `8c699dd` | the transcript pipeline: `bend-units`, `deploy/check/*.sh` + `Harness.lean`, `bend-transcript`, `docs/TRANSCRIPT-FORMAT.md` | 2,087 pilot units rebuild their files byte for byte; `bend/tests/units.bend` in `bend-tests`; two real transcripts in the doc |

The repository is now Bend 17,807 / shell 1,754 / Nix 300 / Lean 62 tracked source lines: 89% Bend. The shell is the compiler harness (Bend cannot spawn a process); the Lean file is the one program only Lean can be.

**What is proven.** Every stage of Phase 3 runs on real code with the real checkers and produces the agreed format. The trainer's memory at ctx 2048 is known exactly. The corpus tools are byte-identical to the old ones.

**What is not proven.** The pipeline has never run over the whole corpus, so the transcript counts below are estimates. No transcript has Claude prose yet. Nothing has trained at ctx 2048. The Haskell yield is 10%, which would make Haskell (88% of the source files) the smallest part of the corpus per file.

### The pilot (samples, one 16-core machine)

1,244 files → 2,087 units → 517 checked → 966 transcripts, 361,206 tokens (374 per transcript on average). Each tool is described in `docs/TRANSCRIPT-FORMAT.md`.

| language | units | kept | why the rest fails | time |
|---|---|---|---|---|
| Haskell | 716 | 72 (10%) | 88 of 103 sampled failures import a module of the unit's own package; 3 `\case` without its extension; 1 `cbits/` FFI | 42 s per 716 units |
| Lean (mathlib) | 115 | 104 (90%) | 11 elaboration errors | 9 s per unit per worker; 6 workers fit in 31 GB |
| Agda (stdlib) | 60 | 52 (87%) | 8 check errors | |
| Nix | 254 | 169 (67%) | 85 need an argument or a path | |
| Bend | 159 | 120 (75%) | 39 are bend2's evals with deliberate holes | |

Mutants that still check (so are dropped): Haskell 14 of 217, Lean 12 of 366, Agda 3 of 163, Nix 124 of 534, Bend 10 of 332.

### The route from here (suggested order, with what each step costs)

Steps 0–5 cost no money and run on this machine. Step 6 costs API money and step 9 a box; both wait for a yes.

**0. The sources** (user's request, 2026-09-25 night: Conal Elliott's code, especially the Agda; `~/src/refl`; category theory in dependent types).

What the corpus is made from today (`run/code-sources/`, extracted by `deploy/extract-code.sh` into `run/code-train-v2.jsonl`):

- `tarballs/`: 19,418 Hackage packages (permissive licenses only; 222,708 Haskell files).
- `repos/`: mathlib4 (of which `Mathlib/CategoryTheory` is 1,109 files and 1,971 files mention it), lean4, batteries, agda-stdlib, cubical, 1lab, agda, idris2, nixpkgs.
- `own/`: 23 of the user's repositories (never held out, no license gate).

What is missing and goes in, with the license the extractor will see:

| class | repositories | license | note |
|---|---|---|---|
| own (add) | `~/src/refl` (`languages/`: 11 Agda, 3 Lean, 1 Bend), `~/src/conal-elliott` = `hhefesto/conal-notes` (16 literate Agda, 8 Agda, 2 Bend, 3 Haskell), `~/src/telomare` (92 Haskell), `~/src/list-pointed-adjoint`, `~/src/agda-hello-world` | user's | `own/` treatment |
| curated Agda, Conal | `conal/felix` (categorical linear algebra and hardware, his main Agda work), `felix-boolean`, `agda-cat-linear`, `agda-play`, `agda-puzzles`, `DependentTypesAtWork-exercises`, `equation-transfer`, `nim` | **no license file** | the gate would drop every one; a new `curated/` class takes them without the gate by the user's decision (private training use), never held out, ids `curated:NAME/path` |
| curated Haskell, Conal | `compiling-to-categories/concat` (BSD-3), `lambda-ccc`, `circat`, `linear-map-gadt`, `shaped-types`, `generic-fft`, `ftree`, `Boolean`, `reification-rules`, `reify-core`, `data-treify`, `Fran`, `talk-2012-folds-and-unfolds`; the ones already on Hackage (`vector-space`, `MemoTrie`, `TypeCompose`, `total-map`, `functor-combo`, `unamb`, `lub`, `DeepArrow`, `TV`, `NumInstances`, `type-unary`, `uniform-pair`: 116 files already in v2) come in again from git and the exact dedup keeps one copy | BSD-3 text in most (`NOASSERTION` on GitHub); `shady-*` are AGPL and stay out | `curated/`, gate kept for these (their LICENSE files pass) |
| category theory, Agda | `agda/agda-categories` (MIT), `UniMath/agda-unimath` (MIT; category theory in univalent style), `HoTT/HoTT-Agda` (MIT); `1lab` and `cubical` are already in | MIT | `repos/`; the ordinary gate |
| category theory, Haskell | `sjoerdvisscher/data-category` (BSD-3), `ekmett/categories`, `ekmett/hask` (LICENSE text decides); `constrained-categories` is GPL and stays out | | `repos/` |
| PLFA | `plfa/plfa.github.io` (`~/src/plfa` has a checkout): the book's `.lagda.md` chapters | CC-BY-4.0 | the gate's text match gains "Creative Commons Attribution"; literate Agda needs `bend-units` to treat everything outside ```` ```agda ```` fences as comment (Agda itself checks `.lagda.md` directly, so byte identity holds) |
| Lean | nothing new: `Mathlib/CategoryTheory` is the category theory in Lean, already in | | raise its share by `MAX_PER_FILE` |

- `bend-units` takes `MAX_PER_FILE` per run, so the curated and category-theory sources run with 16 instead of 4 and are represented despite being small next to Hackage.
- The extraction becomes `run/code-train-v3.jsonl` beside v2 (v2 stays for the evals' sake); `extract-code.sh` gains the `curated/` class and the CC-BY text; `docs/TRANSCRIPT-FORMAT.md` records the per-source file counts the extractor prints.
- Half a day, including the literate-Agda mask.

**1. Haskell yield** (`deploy/check/haskell.sh`; half a day).

- The corpus already holds every file of every package under ids `hackage:PKG/path`, so a package's tree is rebuilt by writing its files into a work directory. The source root of a file is its path with the module name's directories removed; the set of roots of a package is its `-i` list.
- Per package, typecheck the tree once with `ghc --make -fno-code -fwrite-interface -hidir HI -i…`, then check each unit with `-i` on the roots and `-hidir HI`, so a unit's check re-elaborates its own module only. Without that, 566K unit checks each re-typechecking their imports would multiply the 9 h.
- Extensions: the tarballs are still in `run/code-sources/tarballs`, so a package's `default-extensions:` lines can be read from its `.cabal` file and passed as `-X` flags. This is the `\case` class.
- Gate: re-run the same 716-unit sample and record the new kept rate in `docs/TRANSCRIPT-FORMAT.md`. Expected: the 10% rises to somewhere between 50% and 70% (the remaining failures are packages outside the 31 in `ghc-harness`, and CPP).

**2. The full run on this machine** (free; runs in the background under `nohup` and `stdbuf -oL`, logs in Mexico City time, outputs in `run/transcripts/<lang>.{units,results,transcripts}`).

- Order: Lean first (longest, independent of step 1), then Agda, Nix and Bend, then Haskell once step 1 lands.
- Sizes at `MAX_PER_FILE` 4: Haskell about 566K units, Lean about 60K (mathlib alone has 8,370 files), Agda about 30K, Nix about 100K, Bend about 300.
- Times here: Lean about 25 h at 6 workers (memory-bound at 3 GB each); Haskell about 9 h before step 1, to be re-measured after; the others under an hour.
- Expected transcripts after step 1: about 600K (Haskell around 500K, Lean about 100K, Agda about 25K, Nix about 60K, Bend under 1K), about 250M tokens. That is above the research's 100K–500K target, so the mix can afford to be strict.
- A rented CPU box would only shorten the wait; the output is the same. Not needed.

**3. Cleaning** (`bend/Clean.bend`, `bend-clean`; one day; runs on the units, before rendering, so every count is per unit).

- Exact dedup by sha256 of signature plus body across all units (the file-level dedup misses a function copied between packages).
- Decontamination: every 10-gram of a unit's body against the 10-grams of `run/code-eval-v2.jsonl`, the code eval corpora in `run/eval/` and the transcript holdout; any hit drops the unit.
- MinHash near-dedup last (5-gram shingles, 128 hashes from `fnv32` with salts, Jaccard 0.7), because it is the costliest and the source is already file-deduped.
- Record each rule's count in `docs/TRANSCRIPT-FORMAT.md` under Cleaning.

**4. Packing** (the decision; recommended: token-exact best-fit in the packer plus padding and a loss mask in the trainer).

- The trainer's rule (`bend/Train/Data.bend`) is whole windows only, so a 374-token document makes no window. Packing is unavoidable.
- (a) `bend-pack` into 128 KB documents works today, but about one transcript in five straddles a window edge and is cut.
- (b) Recommended: a `--tokens N` mode in `bend-pack` that counts tokens with `Tokenizer.bend` and fills each pack to at most N−2 tokens with whole transcripts (first-fit decreasing over a buffer of a few thousand documents). Packs are then 95%+ full. The trainer pads a short document to the window with EOS and masks the loss on the padding: a change in `Data.bend` and the loss, no kernel change. Cross-document attention inside a window stays; that is the common compromise and can be measured later.
- The per-token loss weights the research suggests (response 1.0, prompt 0.2–0.3, tool output 0–0.1) ride on the same mask once it exists, with a weight per token written by the corpus writer. Later, not now.
- Gate: `bend-pack` without `--tokens` stays byte-identical (the `bend-tests` check); with it, every pack decodes to whole transcripts and no pack exceeds N−2 tokens.

**5. Term→type for Lean and Agda** (small). Today only `haskell.sh` fills the type field, so term→type transcripts are Haskell only. Lean: a `#check @NAME` variant on the original in `Harness.lean`. Agda: `Cmd_infer_toplevel` on the unit's own name. Then `bend-transcript` already renders them.

**6. Claude prose** (`deploy/claude-batch.sh`; write it now, **ask before submitting**).

- Input: the results files. Output: `run/claude-prose/<unit id>` with one task line per kept unit and one diagnosis line per kept mutant. `bend-transcript` gets a prose directory argument and uses the line when present, and its current fallback ("Define `f`.") otherwise, so the corpus can be built with or without prose.
- Requests are cached by sha256 of the request body, so a re-run costs nothing.
- Cost: about $300 per 100K pairs on `claude-opus-5` through the Message Batches API; a cheaper model is the user's call. Suggested: a 200-pair pilot first (about $1), quality read by hand, then the decision on scale and model.

**7. Mix, holdout and shards** (free; `deploy/mix-corpus.sh`, `deploy/plan-corpus.sh`).

- Holdout: 2% of units by id hash, rendered as `run/eval/transcript-fp.corpus`; the eval projects in `code-eval-v2.jsonl` never enter.
- Mix by transcript count: Haskell 35 / Lean 25 / Agda 20 / Nix 10 / Bend 10, plus 5% raw code windows as an anchor. The user's own sessions (`~/src/llm-transcript/corpus.jsonl`) need the renderer port to Bend before they join; do that after the run starts if time is short.
- A 20K-document slice through `plan-corpus.sh` first, as the corpus-pipeline rule says; then the full plan; then `push-corpus.sh` staging.
- **Repair accuracy** eval before the run, not after: `deploy/eval-repair.sh` samples the model with `bend-generate` on 200 holdout prefixes (prompt, term, checker turn) at seed 0 and runs `deploy/check` on the sampled repair. This number ranks checkpoints.

**8. Phase 2b, the store split** (independent; about 400 lines in the fork, 300 here; do it while the checkers run).

- Fork: `View`/`IxAt` gain an array slot, `Array.einsum4` and `Array.mm4` over four arrays, overlap checks per slot, GPU address codegen by slot. Conformance: `einsum4` with every view on slot 0 equals `einsum`.
- Repo: `Layout.bend` (a `Lay` per array, fits check per array), `Op.bend` (store record, slots on `View`/`Mm`, per-slot tangent map), `Model.bend` view sites, `Step`, `Ckpt` (touches `st` only; file format unchanged), `TrainDense`, the tests and `Spec/Dense.bend`.
- Gate: CPU identity against the `dense-identity.sh` goldens at `41e1920`; the 6-step sha in `bend-dense`.
- Without it the run fits micro 5 in one array; with it micro 12 on a 3090. It is worth doing but it does not block the run.

**9. Phase 2c and 4, the box** (**ask first**; rent only once shards, cubin and the hot-start script are staged).

- One hour on a 3090: ms/step and tok/s at ctx 2048 for micro 4, 8, 12, 16 (12 and 16 only after step 8), `nvidia-smi` memory at each.
- The run: `fp100m`, cold start, `code32k`, one epoch over the mix. At the measured 9,600 tok/s (ctx 256; attention adds about 8% at 2048) a 250M-token epoch is about 8 h on a 3090, a few dollars. Checkpoints ranked by repair accuracy.

How to check a Bend file: run `bend FILE.bend` with the flake's `bend` (`nix build .#bend`). `bend Everything.bend` prints `All terms check.`. The Lean toolchain is the one mathlib pins, under `~/.elan/toolchains`; `lean.sh` finds it by itself. The mathlib checkout with its cache is `run/harness/mathlib4`. The pilot's intermediate files are in this session's scratchpad only and can be regenerated in minutes.

## The goal

The goal is training data for a **functional-programming coding agent** in Haskell, Lean, Agda, Nix and Bend, with bash only for running those. The repository itself is Bend: 17,807 of 19,923 tracked source lines are Bend (89%), with the rest in shell 1,754 (the compiler harness), Nix 300 and Lean 62.

Decisions taken with the user on 2026-09-25 (plan: `~/.claude/plans/assess-and-start-the-snug-eich.md`):

1. **Delete the Haskell, Agda and Futhark code, and port the missing corpus tools to Bend.** Done.
2. **Data: real code checked by real compilers, plus Claude-written prose** (the task line and a one-sentence repair diagnosis). Code and compiler output are never generated.
3. **Cold start under `code32k`.** The embedding is tied to the vocabulary, so no v3 weights carry over.
4. **Lean from the start.**
5. **Context 2048, after the store split.**
6. **Types/propositions and terms/proofs are separate turns.**
   - `## Type` carries a flag line, `proposition` or `type`, then the fence. `## Term` holds the program or proof.
   - `## Context` holds `name : type` lines printed by the checker. Holes show goal states.
   - There are three task shapes: type→term 60%, hole 25%, term→type 15%.
   - Agda's flag comes from a heuristic, and the rule is recorded.

## Facts

**Context window.** Every trained checkpoint so far has ctx 256 (v1, v2, v3 and the Bend continuation to 28k). The architecture does not fix the context: the softmax layers have no positional embedding and the GLA layers are recurrent, so ctx is a cost choice. The new preset `fp100m` (`bend/Config.bend`, `bend/Train.bend`) is the 115M `bpe100m-v3` layout with ctx 2048 and vocab 32768.

**How much code fits.** Bytes per token under `code32k`: Haskell 4.06, Nix 3.80, Lean 3.59, Agda 3.16. So:

- **256 tokens** hold about 1 KB of Haskell or about 800 B of Agda: one function.
- **2048 tokens** hold about 8 KB: a small module plus its compiler output and a repair.

**Memory.** Exact, from `Lay.floats` at `bend/Dense/Layout.bend` (bpe100m layout, chunk 16):

| ctx | floats/window | max micro in one 2³¹ array | 3090 (24 GB) after the split | 5090 (32 GB) |
|---|---|---|---|---|
| 256 | 19M | 64 | ~250 | ~330 |
| 1024 | 104M | 15 | ~50 | ~70 |
| 2048 | 309M | **5** (8.2 GB) | **12 safe (17 GB), 16 tight (22 GB)** | ~20 |
| 4096 | 1,020M | 1 | ~5 | ~7 |

The binding limit today is the single `Array<F32>` store (2³¹ floats), not the card. `TrainDense` now refuses a store over 2³¹ with a message that names `TRAIN_MICRO`, where before `Lay.of`'s U32 sums wrapped silently. At ctx 2048 the two `[b,h,t,t]` score buffers are most of the workspace; they are the next wall.

**Data on disk** (nothing needs re-collecting):

- `run/code-train-v2.jsonl`: 1.87 GB, 270,054 files. Haskell 88%, Lean 8%, Nix 3%, Agda 1%. Its sources are in `run/code-sources/` (Hackage tarballs, the cloned `repos/`, the user's `own/`); the additions in route step 0 make `code-train-v3.jsonl`.
- `run/code-eval-v2.jsonl`: whole-project holdouts.
- The tokenizers `weights/code32k.bpe` and `weights/enwiki-fineweb-32k.bpe` (sha256 in `weights/SHA256SUMS`).
- The eval corpora in `run/eval/`.
- The user's own Claude Code sessions: `~/src/llm-transcript/corpus.jsonl`.

**Research** (for the data recipe, summarized in `docs/TRANSCRIPT-FORMAT.md`):

- Keep only checker-verified output; verified data does not collapse a model the way unverified self-generated data does.
- Mutation-repair in the APRIL style.
- Near-duplicates: MinHash on 5-grams at Jaccard 0.7. Contamination: 10-gram overlap with the evals.
- Loss weights: response 1.0, prompt 0.2–0.3, tool output 0–0.1.
- Best-fit packing without cross-document attention.
- Size: 100K–500K verified transcripts.
- No public Agda dataset exists.

## Phases

| phase | what | state |
|---|---|---|
| 0 | Bend-only repo: `backend/`, `FormalTransformer/`, the Futhark kernels, 22 deploy scripts and the bpe10m weights deleted (all in `haskell-final`); `flake.nix` 1,530 → 278 lines | **done** (`228bd06`) |
| 1 | Corpus tools in Bend (`bend-pack`, `bend-prepare`, `bend-plan-segment`), byte-identical to master's on a 20k-file plan, the five code evals and the transcript eval (`docs/BEND-CORPUS-TOOLS.md`) | **done** (`0908864`) |
| — | Fork `hhefesto/bend2` `ft-kernels` rebased onto upstream 2.0.28; its flake's `default` builds from source; the repo takes it as a flake input | **done** (`5633395`) |
| 2a | Dense store: the workspace counted once (the old layout counted it twice, 26% of the store), exact size check, `fp100m`, byte-identity harness `bend/tests/dense-identity.sh` with goldens in the `bend-dense` check | **done** (`41e1920`) |
| 2b | Four-array store split (st, act, ws, gws) so ctx 2048 runs at micro 12–16: a fork `einsum4`/`mm4` with array slots, then Layout/Op/Model/Step/Ckpt; the gate is CPU identity against the goldens | not started |
| 2c | GPU identity plus one hour on a 3090 timing ctx 2048 at micro 4/8/12/16 | **needs a box: ask first** |
| 3 | Transcript corpus: units → checker → prose → transcripts → pack/prepare | **pipeline works on samples** (`8c699dd`); route steps 1–7 above: Haskell yield, full CPU run, cleaning, packing, Lean/Agda term→type, prose (ask), mix + holdout + repair eval |
| 4 | The run: `fp100m`, cold start, `code32k`, one epoch over the mix; checkpoints ranked by repair accuracy on 200 held-out prefixes, not by bpb | **needs a box: ask first** |

Phase 2b and Phase 3 are independent. The run can start at micro 5 without 2b.

## Where things are

- **Trainers:**
  - `bend/Train.bend` is the tree trainer. `bend/TrainDense.bend` is the dense GPU trainer.
  - `bend/Dense/*` holds the dense trainer's modules. `bend/Spec/*` holds the laws (`bend bend/Everything.bend`).
- **Corpus tools:**
  - `bend/{Nul,Ftcc,Pack,Prepare,PlanSegment,Tokenizer,Corpus}.bend`.
  - `deploy/plan-corpus.sh` runs one process per shard, with `--threads 1`: the runtime scales allocation-heavy work to only about 2 cores in one process.
  - `deploy/build-code-evals.sh` builds the code eval corpora.
  - `deploy/mix-corpus.sh` interleaves sources.
- **Transcript tools:** `bend/Units.bend` (`bend-units`), `deploy/check/*.sh` with `deploy/check/Harness.lean` (Lean), and `bend/Transcript.bend` (`bend-transcript`). The Lean driver is the one non-Bend program the harness needs, because only Lean itself can keep an elaborated environment in memory.
- **Flake:**
  - Packages: `bend`, `bend-train`, `bend-train-dense`, `bend-evaluate`, `bend-generate`, `bend-pack`, `bend-prepare`, `bend-plan-segment`, `bend-units`, `bend-transcript`, `ghc-harness`, `ana`.
  - Apps: `ana` (also the default app; `ana-bend` is an alias) is the Haskell-era `ana` on the Bend decoder: no flags means the newest local checkpoint by write time under `run/` (today `run/pulled-vast-52365970/v3-bend-step28000.checkpoint`), `--list`, `--checkpoint`, `--tokens`, `--pull --host` as before; `ana-bend-train`; `bend`.
  - Checks: `bend-spec`, `bend-tests`, `bend-train`, `bend-dense`. All pass at `41e1920`.
- **Fork:** `~/src/bend2`. Remote `origin` is upstream `bendlang/bend`, so never push there; the fork is remote `hhefesto`, branch `ft-kernels` = upstream 2.0.28 + one squashed commit `1b877d3f`. Old heads are tagged `ft-kernels-2.0.27` and `ft-kernels-2.0.4`. The rebase recipe is in memory `project-bend2-fork-remotes`.
- **Docs:**
  - `docs/TRANSCRIPT-FORMAT.md`: the transcript format and pipeline.
  - `docs/BEND-CORPUS-TOOLS.md`: the byte-identity record.
  - `docs/BEND-PORT.md`: the dense trainer and GPU work.
  - `docs/haskell-era/`: everything older.

## Rules

- **Money:** rent a GPU box only once everything is staged, and ask the user before spending money. That covers boxes and the Claude Message Batches API.
- **Box hygiene:**
  - DESTROY a box, never stop it; `vastai` lives in `~/.local/share/vastai-venv`.
  - Run long jobs under `nohup` and `stdbuf -oL`, because the Bend runtime's print does not flush.
  - Check `nvidia-smi -q -d PERFORMANCE` for thermal slowdown.
  - A CUDA-built Bend program uses the GPU by default, so a CPU baseline needs `--gpu off --threads N`.
- **Git:**
  - Commits carry no Co-Authored-By. Nothing is pushed without asking.
  - `private/*` branches push only to the `private` remote. Never push to `origin` in `~/src/bend2`.
- **Logs:** every log line is stamped in Mexico City time (UTC-6), from the fork's `IO.time`.
- **Subagents:** they run on Opus 5.5 only, never another model.
- **Byte identity:** every layout or corpus-tool change is held to it, with `bend/tests/dense-identity.sh` for the trainer and `cmp` of `.corpus` and plan files for the tools.
