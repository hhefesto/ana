# Session Handoff

This file holds everything needed to continue this work from another machine and account. It was restarted from zero on 2026-09-25 for a new path. The previous handoff (the v3 hot start and the dense trainer) is in git at `41e1920:HANDOFF.md`, and master's Haskell-era trainer is at the tag `haskell-final`.

## ▶ CONTINUE HERE (2026-09-25, evening): Phase 3, the transcript pipeline works end to end

**Built.** Each tool is described in `docs/TRANSCRIPT-FORMAT.md`, which also has two real transcripts and the pilot table.

- **`bend/Units.bend`** (`bend-units LANG IN.nul OUT.nul [MAX_PER_FILE]`) cuts source files into declaration units.
  - Each unit holds the signature, the body, the file around it, the doc comment, the names the body uses, a hole and up to four mutants. Mutants never touch comments, strings or a line's first word.
  - Every unit rebuilds its file byte for byte: checked on 2,087 pilot units, and by `bend/tests/units.bend` in the `bend-tests` check.
- **`deploy/check/{haskell,lean,agda,nix,bend}.sh`** (shared code in `lib.sh`) run the real checker on each unit's original, hole and mutants, and ask it for the Context types.
  - A unit is kept only when its original checks; a mutant only when it fails.
  - `deploy/check/Harness.lean` elaborates a Lean file's head once and every variant from that state, which makes mathlib affordable.
  - The flake's `ghc-harness` is GHC 9.10 with 31 common Hackage packages.
- **`bend/Transcript.bend`** (`bend-transcript TOKENIZER RESULTS OUT [WINDOW]`) renders the turns and the shapes.
  - Shapes: type→term 60 (a quarter right the first time, the rest repair), hole 25, term→type 15 (ghc only).
  - It drops any transcript over the window; nothing is cut.

**The pilot** (samples, one 16-core machine): 1,244 files → 2,087 units → 517 checked → 966 transcripts, 361,206 tokens (374 per transcript on average).

| language | kept | time |
|---|---|---|
| Haskell | 10% | 42 s per 716 units |
| Lean (mathlib) | 90% | 9 s per unit per worker; 6 workers fit in 31 GB |
| Agda (stdlib) | 87% | |
| Nix | 67% | |
| Bend | 75% | |

**Next, in order:**

1. **Haskell yield.** 85% of the failures import a module of the unit's own package. Rebuilding each package's tree from the corpus and passing `-i` is the lever.
2. **Cleaning:** exact dedup by body hash, then a 10-gram decontamination against the evals, then MinHash near-dedup. Record each count in the doc.
3. **Packing.** The trainer makes no window from a document shorter than ctx, and transcripts average about 374 tokens. The choice:
   - (a) `bend-pack` into large documents, so windows cut across transcripts. This works today.
   - (b) Token-exact best-fit packing, with padding or loss masking added to the trainer. The research favours this.
4. **The full run** over `run/code-train-v2.jsonl` (with `bend-units` at `MAX_PER_FILE` 4):
   - Haskell: about 566K units, about 9 h here.
   - Lean: about 60K units, about 25 h at 6 workers.
   - A bigger CPU box would shorten it, and it costs money, so **ask first**.
5. **`deploy/claude-batch.sh`** writes the task lines and repair diagnoses. Write it, but **ask before running it** (it costs money).
6. Phase 2b, the store split. It is independent of all of the above.

How to check a Bend file: run `bend FILE.bend` with the flake's `bend` (`nix build .#bend`). `bend Everything.bend` prints `All terms check.`. The Lean toolchain is the one mathlib pins, under `~/.elan/toolchains`; `lean.sh` finds it by itself. The mathlib checkout with its cache is `run/harness/mathlib4`.

## The goal

The goal is training data for a **functional-programming coding agent** in Haskell, Lean, Agda, Nix and Bend, with bash only for running those. The repository itself is Bend: 16,320 of 17,945 tracked source lines are Bend (91%), with the rest in shell 1,279, Nix 278 and C 68.

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

- `run/code-train-v2.jsonl`: 1.87 GB, 270,054 files. Haskell 88%, Lean 8%, Nix 3%, Agda 1%.
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
| 3 | Transcript corpus: units → checker → prose → transcripts → pack/prepare | **pipeline works on samples** (above); full run, cleaning, packing, prose to do |
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
  - Packages: `bend`, `bend-train`, `bend-train-dense`, `bend-evaluate`, `bend-generate`, `bend-pack`, `bend-prepare`, `bend-plan-segment`, `bend-units`, `bend-transcript`, `ghc-harness`, `ana-bend`.
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
