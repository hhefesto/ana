# Session Handoff

Everything needed to continue this work from another machine and account.
State as of 2026-07-10, on branch `master` (repo not yet committed — the
whole tree is staged; see "First Actions" below).

## What This Session Did

The session had one driving request, then three additions:

1. **Rewrite `docs/LOCAL-COMPARISON.md`** as a stage-by-stage *type-history*
   comparison (mirroring `docs/TYPE-HISTORY.md`): `meum-transformer` removed;
   `modArTransformer` restricted to its **Wikipedia lineage only**
   (CPU `wiki-nano`/`wiki-small`, GPU "Elliott-LLM" `pilot`/`main`); the
   projects under `~/src/conal-elliott` added as comparison columns.
   Important discovery: **`~/src/conal-elliott` contains no transformers** —
   it holds Elliott's papers, `paper-2021-language-derivatives` (Agda,
   denotation-indexed coinductive `Lang P`), and `weighted-derivatives`
   (Haskell/Bend bigram + semiring ν/δ engine, incl. `WikiBigram.hs`). The
   user chose to include these as labeled non-transformer columns.
2. **Port modArTransformer ideas into formalTransformer.** Selection
   criterion set by the user: *only ideas with clear denotational-semantics
   foundations ("anything Conal Elliott would approve of")*. Five ports
   landed (all verified; see below). FastBPE and the matmul-shaped forward
   rewrite were deliberately left as documented roadmap.
3. **README**: new "Continuing Training" and "Running With The Latest
   Weights" sections (user request mid-session).
4. **`docs/PARALLEL-SCALING.md`**: where linearity licenses parallelism +
   tiered plan from the RX 580 to larger/multiple GPUs (user request
   mid-session).
5. **Friendly artifact errors** (user request): missing/unreadable/mis-typed
   corpus and checkpoint files now produce two-line actionable messages
   instead of raw GHC IOExceptions; README gained a "Common Errors" section.
6. **Zero-argument flake apps** (user request): `nix run .#wiki-train`
   and `nix run .#wiki-generate`, documented in README under "One-Command
   Wikipedia Training And Generation". After the GPU investigation (item 7)
   wiki-train defaults to the **sequential backend** with
   `WIKI_BACKEND=opencl` as the GPU opt-in, and after item 8 its default
   target is **`epoch`**.
7. **GPU stall investigation** (user request: "wiki-train shows no GPU use,
   one CPU at 100%"). Three findings, all measured on the RX 580/rusticl:
   (a) rusticl compiles the entire generated OpenCL program on the host CPU
   at context creation — that was the 100%-CPU phase; the full three-vjp
   program takes **~19 minutes**. Fixed by splitting
   `backend/futhark/model.fut` (all definitions) from two entry files:
   `kernels.fut` (full set — sequential/conformance) and
   `kernels-opencl.fut` (trainer set, ONE vjp entry:
   `micro_batch_loss_grad`) → **~54 s cold**; plus Futhark's program cache
   wired as `FUT_CACHE` (set automatically by wiki-train) → **~8 s warm**.
   `batchLossGrad`/`lossGrad` FFI are CPP-`#ifndef OPENCL_BACKEND` guarded.
   (b) With that fixed the GPU *does* engage (gpu_busy 100%), and the tiny
   preset trains on the GPU, but (c) the **small-preset vjp kernel exceeds
   the ~10 s amdgpu display watchdog in a single launch** (even at
   MICRO_BATCH=1) → "CS cancelled, context lost" soft reset. Micro-batching
   cannot fix this — it bounds sequences per launch, not the length of the
   one fused gradient kernel. Hence sequential default; OpenCL is right for
   tiny, headless GPUs, or after a kernel-splitting/matmul rewrite
   (roadmap; see ARCHITECTURE "One Model, Two Entry-Point Programs").
8. **Epoch target semantics** (user request: finishing training must mean
   the whole training set was consumed). `STEPS` now accepts literal
   `epoch`: target = ceil(trainWindows/TRAIN_BATCH), and batches walk a
   deterministic full-coverage permutation (index-hash order, cyclic
   slices, pure function of the step — resume needs no new state; the
   checkpointed PRNG is simply carried through). wiki-train's default.
   Epoch resume requires the same corpus and TRAIN_BATCH (schedule anchor).
   Verified end-to-end: 2261-window corpus → "epoch target: 2261/8 = 283
   steps" → ran to completion → re-run idempotent. Documented in
   TRAINING.md and README.

## The Five Ports (all merged and verified)

| Port | Files | Verification |
|---|---|---|
| Coinductive ν/δ trie + bisimulation + run homomorphism (the abstract KV-cache law, refl per step) | `FormalTransformer/Language/Trie.agda`, `FormalTransformer/Language/AutoregressiveTrie.agda` | `agda -i . Everything.agda` passes; modules are `--safe --without-K --guardedness` |
| Gradient-accumulation linearity D(Σfᵢ)=ΣDfᵢ (`batch-pullback`; `addD` factors through proved `pairD`/`plusD`) | `FormalTransformer/AD/Batch.agda` | same |
| Size-typed Futhark entries: `params: [parameter_count v d f n_layers]f32` on all six model entries | `backend/futhark/kernels.fut`, coercions in `backend/futhark/tests.fut` | `futhark check` both files; oracle's negative test |
| Micro-batch gradient accumulation (`MICRO_BATCH` env; adjoint seed 1/effective-batch inside the kernel; one AdamW step per effective batch; chunked validation) | `kernels.fut` (`zero_vector`, `micro_batch_loss_grad`), `backend/gpu/FutharkKernels.hs`, `backend/gpu/Main.hs` | oracle: loss bitwise equal, gradient max_abs≈1.5e-8; manual 6-step run at MICRO_BATCH=4/2/1 identical to f32 reassociation |
| Exact-counts bigram gate (minimal finite StateAlgebra; add-1 smoothing; scores the trainer's exact validation windows) | `backend/src/FormalTransformer/Bigram.hs`, `bigram-gate` CLI in `backend/app/Main.hs`, gate print in `backend/gpu/Main.hs`, shared split in `backend/src/FormalTransformer/Data.hs` (`trainerWindowSplit`), presets moved to `FormalTransformer.Config` (`tinyPreset`/`smallPreset`) | 4 new tests in `backend/test/Main.hs` (20/20 pass); CLI run on `data/wiki-sample.corpus` |

Supporting changes: `Everything.agda` (+`--guardedness`, +3 imports),
`formal-transformer.cabal` (+`containers`, +`FormalTransformer.Bigram`,
+`directory` for the CLI), `backend/conformance/Main.hs` (micro-batch
equality + mis-size rejection, each in its own context). Late user request:
`loadCorpus`/`loadCheckpoint` (`Artifact.hs`) now return actionable
messages for missing/unreadable/mis-typed files instead of raw GHC
IOExceptions (strict read keeps IO failures out of the lazy decoder);
`prepare-bytes` checks its inputs; README gained a "Common Errors" section
with the artifact dependency chain. Doc updates: `PROOF-STATUS.md` (new proved
bullets, guardedness note, new assumptions), `TYPE-HISTORY.md` (new §14
trie, §15 batch linearity), `TRAINING.md` (`MICRO_BATCH` + "Baseline Gate"
section), `ARCHITECTURE.md` (layout-in-type + baseline rung), `README.md`.

## Headline Empirical Finding

`bigram-gate data/wiki-sample.corpus small` → **2.4812 nats (sample) /
2.5736 nats (full validation)**. The trained `small` checkpoint from
`docs/RUN-2026-07-10.md` plateaued at **~2.91** validation — i.e. **the
current trained transformer is behind the bigram baseline**, exactly the
situation this gate was ported to expose (modArTransformer's CPU wiki
models had the same experience). Next training run should watch the
`beats-gate`/`behind-gate` suffix the trainer now prints.

## Verification Status At Handoff

- `nix develop -c agda -i . Everything.agda` — PASS (all 13 modules).
- `nix develop -c cabal test` — PASS (20/20, incl. 4 new).
- `futhark check` on `kernels.fut` and `tests.fut` — PASS; all 4 `tests.fut`
  entries evaluate `true` in `futhark repl` (incl. `test_micro_accumulation`).
- `nix build .#conformance` — PASS; results include
  `micro-batch loss vs full batch: max_abs=0.0`,
  `micro-batch gradient vs full batch: max_abs≈1.49e-8`,
  `size-typed interface rejects mis-sized parameters: exact`.
- `nix build .#formal-transformer-gpu` and `.#formal-transformer-sequential`
  — PASS.
- `nix flake check` — PASS ("all checks passed!": agda, haskell + tests,
  futhark, gpu-host, sequential-host, conformance).
- Manual MICRO_BATCH=4/2/1 equality run — PASS (identical through step 5,
  7th-decimal f32 divergence at step 6).
- Error-message paths exercised — missing corpus on `train`, missing
  checkpoint on `generate`, missing inputs on `prepare-bytes`: all print
  the two-line suggestion, exit 1, no backtrace.
- Flake apps smoke-tested — `wiki-train` (2-step run, **OpenCL context
  created and trained without a device reset** on this RX 580, though the
  work was tiny) and `wiki-generate` (fell back to the 1000-step
  checkpoint and generated). Notably the OpenCL host resumed a
  sequential-written checkpoint — cross-backend resume works in practice.

## First Actions On The New Machine

```bash
git clone <repo> && cd formalTransformer   # or rsync the working tree
git status        # this session left ALL changes staged but NOT committed
nix flake check   # complete verification in one command
nix develop -c cabal test
nix run . -- bigram-gate data/wiki-sample.corpus small
```

Nothing in the repo depends on this machine except: (a) the OpenCL trainer
was only ever exercised on a display-attached RX 580, where the first run
tripped the AMD watchdog (`docs/RUN-2026-07-10.md`) — the sequential-C host
is the accepted trainer; (b) `MICRO_BATCH` exists specifically to make
OpenCL launches watchdog-sized (`TRAIN_BATCH=8 MICRO_BATCH=1` is the
intended first retry on that GPU).

## Key Decisions Made (and their reasons)

1. **Denotational selection criterion** for ports (user decision) — FastBPE
   and perf rewrites postponed as roadmap in `LOCAL-COMPARISON.md`.
2. **`--guardedness` under `--safe`** — legal in Agda 2.8.0 (only
   guardedness+sized-types+safe is rejected). Infective: it lives on the two
   trie modules and `Everything.agda` only; documented in PROOF-STATUS.
3. **Two tries, not one** — this repo's `StateAlgebra.step` emits a
   transition weight (modAr's doesn't), so there is an *observation* trie
   (pure port, refl laws) and a *weighted* trie threading a path-weight
   accumulator (an accumulator because a corecursive call under `_*_` would
   not be guarded).
4. **Micro-batch division placement** — the kernel divides each chunk by the
   *effective* batch (passed in), making per-sequence contributions bitwise
   identical to full-batch and the only divergence f32 summation order.
   Accumulation is on-device (`map2 (+)`), not host-side.
5. **Gate/trainer window identity by construction** — split constants and
   windowing moved into `FormalTransformer.Data` (`trainerSplitSeed =
   0x46544f50454e434c`, fraction 0.1, `fullWindows`, `trainerWindowSplit`);
   both the gate and the GPU host now call the same function.
6. **No checkpoint/manifest schema changes anywhere** — `MICRO_BATCH`, like
   `TRAIN_BATCH`, is launch mechanics; presets kept identical values when
   moved (`modelId` strings unchanged), so existing checkpoints
   (`run/wiki-small-1000.checkpoint`) still resume.

## External Repo Facts (for continuing the comparison)

- `~/src/modArTransformer` — Wikipedia lineage: CPU `backend/wiki/Main.hs`
  (`wiki-nano` v512/n32/dM32/dF128/dK16 ≈47k params, val 5.18 nats;
  `wiki-small` ≈120k, 4.76 nats), GPU `backend/futhark/kernels.fut` +
  `TrainGpu.hs` (`pilot` ≈2.5M: val 5.2437 at step 5400 on 200 MB; `main`
  ≈7.43M: ≈4.70 at step 3000 on 1 GB — a MID-RUN snapshot dated 2026-07-09).
  Their BPE bigram gate: 4.0673 nats, beat both CPU models. Docs:
  `ELLIOTT-LLM.md`, `WIKI-LLM-STATUS.md` (ConCat post-mortem),
  `TRAINING-GUIDE.md` (Lesson 10 = semantics-preserving perf discipline).
  Large artifacts live OUTSIDE that repo in `~/datasets/wikipedia-en/`.
- `~/src/conal-elliott` — theory + baselines only:
  `paper-2021-language-derivatives/Automatic.lagda` (denotation-indexed
  `Lang P`), `Weighted.lagda`; `weighted-derivatives/haskell/{RAD,
  WeightedDerivatives,WikiBigram}.hs`, Bend ports;
  `NOTES-bradley-vs-elliott.md` ("a transformer is Bradley's object in
  Elliott's Automatic representation"), `NOTES-language-derivatives.md`.

## Late Additions (same session, after the GPU investigation)

- **Multicore CPU backend**: `formal-transformer-multicore` flake package
  (`futhark multicore`, same host, full kernel program, `-lpthread`).
  Losses are step-for-step IDENTICAL to sequential (verified: step 1
  = 5.7314467 on both). Now `wiki-train`'s default backend
  (`WIKI_BACKEND=multicore|sequential|opencl`); CPU backends default
  `MICRO_BATCH=TRAIN_BATCH`, OpenCL keeps `MICRO_BATCH=1`.
- **Watchdog root cause found**: olimpo's NixOS config already had
  `amdgpu.lockup_timeout=60000` ACTIVE in the running kernel — but a
  single value covers only non-compute rings, and rusticl submits to the
  COMPUTE ring (~10 s default), which is why the small-preset kernel died
  at ~11 s. Fixed declaratively in
  `~/src/etc-nixos-configuration/olimpo.nix` with the four-value form
  `amdgpu.lockup_timeout=60000,60000,60000,60000` — **needs
  `nixos-rebuild boot` (or switch) + reboot**, then `WIKI_BACKEND=opencl`
  should handle the small preset on the display GPU.
- **The user's own 5000-step sequential run COMPLETED and BEAT THE BIGRAM
  GATE**: `run/wiki-small-5000.checkpoint` (renamed from
  wiki-small.checkpoint), adamStep 5000/5000, **best validation 1.9468
  nats** vs gate 2.4812 — the first trained model in this repo to pay for
  its attention. `wiki-generate` falls back to it after the in-progress
  epoch checkpoint.
- **A detached epoch training run is running** on the multicore backend:
  `nohup nix run .#wiki-train > run/wiki-train.log` (corpus
  data/wiki-sample.corpus, small preset, TRAIN_BATCH=4, epoch target
  52,852 steps, checkpoint run/wiki-small.checkpoint, snapshots every 10
  steps). If it is not running (machine rebooted, etc.), the same command
  resumes it from the last snapshot. Note the first relaunch died on
  resume validation against the user's 5000-target checkpoint at the same
  path — that is why the rename happened, and validateResume now prints
  both optimizer configs and the remedy.

## Whole-Wikipedia Mode (final state of wiki-train)

The user's requirement: no-argument `wiki-train` must only stop when ALL
possible training material is used. Implemented as a resumable shard loop
over `~/datasets/wikipedia-en/enwiki-natural-language.jsonl` (6M+ articles,
18.9 GB; `{"id","title","text"}` per line):

- `prepare-stdin` CLI command: NUL-delimited id/text pairs → corpus
  artifact (fed by `awk` line-range + `jq -j '.id," ",.text," "'`).
- `TRAIN_INIT=path` env in the trainer: warm-starts a NEW run's parameters
  from a compatible checkpoint (config must match; schedule/moments/PRNG
  fresh).
- Non-overlapping windows (`fullWindows` stride = width): an epoch consumes
  each token as a prediction target exactly once. This changed window
  counts everywhere (gate, validation, epoch targets); tests updated.
- `wiki-train` loop: per shard — prepare corpus, epoch-train warm-started
  from `run/wiki-latest.checkpoint`, `cp` to latest, `touch
  run/wiki/shard-K.done`, delete shard corpus+checkpoint. Verified
  end-to-end on 60 real articles / 3 shards including the "entire dataset
  has been consumed" terminal state and idempotent re-run.
- The **sample-epoch run completed with val 1.1868 nats (beats gate
  2.4812)**; its weights seeded `run/wiki-latest.checkpoint` so the
  whole-Wikipedia trajectory continues from it. Log: `run/wiki-train.log`
  (previous logs kept beside it).
- Honest scale note: ~1,560 shards at roughly 15 h/shard on the multicore
  CPU backend ≈ years for the full dump. The command's semantics are now
  correct (stops only at exhaustion) and everything is resumable; making
  it *fast* is the GPU/scale roadmap (watchdog reboot → `WIKI_BACKEND=
  opencl`, kernel rewrite, Tier 1/2 hardware in PARALLEL-SCALING.md).

## Open Threads (in rough priority order)

1. Commit the staged tree (nothing was committed this session).
2. Run the full epoch: `nix run .#wiki-train` (sequential backend, 52,852
   steps for wiki-sample/small at TRAIN_BATCH=4 — roughly a day of CPU; it
   checkpoints every 10 steps and resumes, so it can run in sessions).
   This is also the "train past the bigram gate (2.48/2.57 nats)" attempt.
3. To get the small preset onto the GPU, the vjp kernel itself must be
   split into shorter launches (per-block/per-position stages or the
   matmul-shaped rewrite) — micro-batching cannot shorten the one fused
   gradient kernel. Until then OpenCL is for `tiny` or headless GPUs
   (`WIKI_BACKEND=opencl`).
4. Roadmap ports when justified: FastBPE (needs a second tokenizer identity
   through `CorpusArtifact`/checkpoints), matmul-shaped forward (needs
   profile evidence + same-seed-identical-loss proof), KV cache as a
   `StateAlgebra` obligated to `observation-run`.
5. Tier 2 of `PARALLEL-SCALING.md` when hardware arrives: K-context data
   parallelism; the conformance extension (K=2 vs K=1) is specified there.

## Session Working Notes

- The flake copies only *git-tracked* files: `git add` new files before any
  `nix build`, or the build fails with "Could not find module".
- Futhark size-expression gotcha: a `let`-bound alias of
  `parameter_count ...` does NOT unify with the size expression at call
  sites; write the expression inline (see `tests.fut`).
- The user's plan file for this session (design + rationale):
  `~/.claude/plans/there-are-two-strong-quiet-biscuit.md` — machine-local;
  its substance is reproduced in the docs and this handoff.

## Review Findings (2026-07-11, generation quality → GPT-2 gap)

New information only (a read-only review; no code changed). Driving
question: why does `nix run .#wiki-generate` emit "the state and the
state and ..." forever, and what separates this model from GPT-2 level.

1. **`wiki-generate` never sees training progress mid-shard.** It prefers
   `run/wiki-latest.checkpoint`, but the whole-dataset loop only copies
   `run/wiki/shard-K.checkpoint` to latest AFTER the shard's full epoch
   (flake.nix). Verified: during shard 0's ~16 h epoch, latest was frozen
   at the sample-epoch weights (step 52,852, mtime 02:24) while training
   sat at step ~141k (shard-0.checkpoint mtime 09:44; files differ). So
   repeated generation runs during training are bit-identical by
   construction. To generate with live weights:
   `WIKI_CHECKPOINT=run/wiki/shard-0.checkpoint nix run .#wiki-generate`.
2. **The repetition is a decoding property, not (only) undertraining.**
   `generate` is pure greedy argmax over raw logits
   (`backend/gpu/Main.hs:327`); no temperature, top-k/top-p, or repetition
   penalty; no RNG is consulted anywhere in the generation path. With the
   finite 64-byte window, greedy decoding is a deterministic map
   (last-64 window → next byte) on a finite state space, so every orbit is
   *eventually periodic*: unbounded greedy output MUST end in a cycle, and
   a short high-probability phrase that fits inside the window is a fixed
   attractor. (GPT-2 itself degenerates under pure greedy — Holtzman et
   al. 2019.) Denotationally: the checkpoint denotes a conditional
   probability measure over byte streams (exactly the weighted-trie
   semantics in `FormalTransformer/Language/Weighted.agda`); argmax
   observes only the mode, which is not a faithful observation of that
   measure — sampling from it is. Temperature/top-k belong to the
   *observation*, not the model. Fix site: `argmax logits` at
   `backend/gpu/Main.hs:327`; the xoshiro PRNG (`nextWord`/`PRNGState`)
   already lives in that file and is threaded through checkpoints.
3. **Live run status at review time.** Shard 0 of 1465, step ~141.7k of
   317,935 (~45%), ~5.4 steps/s ≈ 1.4k tokens/s on the multicore backend
   (~7.3 h elapsed); train ≈ 1.4–1.6, validation 1.5644 nats/byte vs gate
   2.5842 — `beats-gate` on every validation line (14k+), zero
   `behind-gate`. (Logged validation is the 8-window sample; the full
   split gate is 2.5264.)
4. **Units for any GPT-2 comparison: bits per byte.** This repo logs
   nats/byte-token; GPT-2 results are perplexity over BPE tokens. The
   tokenizer-independent unit is bits/byte: current validation 1.5644
   nats = **2.26 bpb**; bigram gate 2.5842 nats = 3.73 bpb; GPT-2 small
   (117M) zero-shot on enwik8 = **1.16 bpb**; GPT-2 1.5B = 0.93 bpb.
   "GPT-2 level" therefore means roughly **halving current bits/byte**.
   Recommended: log bpb alongside nats, and port the gate discipline
   upward — run actual GPT-2 (released weights) on this trainer's exact
   validation windows as a **"GPT-2 gate"**, making the objective a
   measured rung instead of vibes.
5. **Gap inventory vs GPT-2 small (124M).** ~1000× parameters (123,328 →
   124M; 12 layers × d768 × 12 heads vs 2 × 64 × 4); ~60× effective
   context (64 bytes ≈ 12 words vs 1024 BPE tokens ≈ 770 words); vocab
   258 bytes vs 50,257 BPE; ~2000× tokens/step (256 vs ~500k); data 40 GB
   WebText vs one 4000-article shard at a time. The *architecture recipe*
   is NOT the gap — RoPE + RMSNorm + SwiGLU + pre-norm + tied embedding
   is the modern (post-GPT-2, better) stack. Missing training-dynamics
   pieces that matter only at scale: gradient clipping (GPT-2 clips
   global norm at 1.0; none here), much larger effective batch. Dropout
   is correctly absent for a single-epoch regime.
6. **The shard loop is not a semantics-preserving implementation of
   whole-corpus training** (the Conal-style objection). Each shard runs a
   fresh AdamW instance: cosine decays 3e-4 → 0 *within* the shard, then
   `TRAIN_INIT` warm-starts weights but resets step/moments/schedule. The
   "whole-dataset" trajectory is 1465 concatenated cosine sawteeth, not
   one optimization over the dataset; late shards will keep re-shocking
   the weights with fresh warmups. Denotational fix: anchor ONE schedule
   (and Adam state) to the full dataset and make sharding pure streaming
   — an implementation detail invisible in the training semantics.
7. **Compute reality.** GPT-2-level needs ≈ 6·N·D ≈ 7×10^18 FLOPs at the
   Chinchilla-ish lower bound (N=124M, D=10B tokens; real replications
   use 30–100B). The RX 580 (~6 TFLOPS peak f32, display watchdog,
   kernels not yet matmul-shaped): months-to-a-year even fully engaged.
   The multicore CPU at today's 1.4k tok/s on a 123K model: not in this
   decade at 124M. A rented A100/H100 trains 124M×10B in hours-to-days.
   Conclusion: GPT-2 level requires rented compute or the Tier-1/2
   hardware of PARALLEL-SCALING.md; the RX 580 alone cannot get there.
8. **Artifact-layer scaling blockers.** Checkpoints serialize params +
   both Adam moments as `binary` `[Double]` (~25 bytes per parameter on
   disk: 9.25 MB at 123K params → ≈25 GB at 124M), and
   `CHECKPOINT_EVERY=10` writes one every ~2 s. The format must become
   raw f32 arrays (and checkpoint cadence time-based) before real
   scale-up. Generation stays O(n²) per token until the KV cache port
   (the observation-run law it must satisfy is already proved).
9. **Recommended order** (each step keeps the oracle/proof discipline):
   (a) sampling — temperature + top-k at the argmax site, seeded from the
   checkpoint PRNG (hours; fixes the visible symptom); (b) bpb logging +
   the GPT-2 gate (makes progress measurable in GPT-2 units); (c) one
   continuous schedule + optimizer state across shards; (d) FastBPE
   (vocab ~8k) + context ≥256 + ~10M params on the GPU path — needs the
   watchdog reboot, then the kernel-split/matmul-shaped rewrite with the
   same-seed-identical-loss proof, then the KV cache; (e) only then the
    GPT-2-small config (12L/d768/n1024, 124M) on rented or new hardware.

## Continuation: Rental-Ready Intermediate (2026-07-11)

- Created root commit `2fb4a08` after `nix flake check` passed all seven checks.
- Found and eliminated two concurrent writers to `run/wiki/shard-0.checkpoint`;
  the canonical CPU trajectory was resumed as one process from the immutable
  root commit.
- Added strict FastBPE loading and semantic SHA-256 identity for the existing
  `enwiki-8k.bpe`, compact `u16` corpus artifacts, BPE prompt generation, and
  preset `Config 8192 256 320 864 6 5` (10,059,840 parameters).
- Replaced parameter-only shard warm starts with a planned `train-segment`
  protocol: one global checkpoint, AdamW state, schedule, and dataset identity;
  global-offset split and segment-local epoch order.
- Added compact `f32` checkpoints with legacy decoding, on-device gradient norm
  clipping, and tokenizer-aware bits-per-byte validation logging.
- Added the Nix `formal-transformer-cuda` package/app. CUDA 12.9 runtime and
  NVRTC come from Nix; `libcuda.so.1` comes from the provider driver; the build
  verifies no linker stub remains in runtime RPATH.
- Selected one Verda spot RTX 6000 Ada as the first benchmark target under a
  USD 50 cap. See `docs/CLOUD-TRAINING.md` and `deploy/`.
