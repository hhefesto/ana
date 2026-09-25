# The Bend2 port

Everything under `bend/` is Bend2 alone: the specification (ported from the Agda
modules), the decoder, the tokenizer, the trainer and the evaluator. There is
no FFI and no custom C/JS effect. The Bend2 toolchain is pinned in `flake.nix`
(input `bend2`, the fork `github:hhefesto/bend2/ft-kernels`, consumed as a flake:
upstream 2.0.28 plus one squashed commit with the bulk ops, the F32 file effects,
`IO.time`, and a `default` package that runs the fork's own source with Bun,
since upstream's `default` fetches the release archive; rebased 2026-09-25, the
earlier bases kept as the tags `ft-kernels-2.0.27` and `ft-kernels-2.0.4`). The
Haskell, Agda and Futhark trees this port came from are at the tag
`haskell-final`; comments citing `backend/...` or `FormalTransformer/...` refer to it.

```
nix run .#ana -- --prompt "The history of"           # generate from the newest local checkpoint (FTC2 or BTC1)
nix run .#ana-bend-train                              # train (env: CORPUS, PRESET, TRAIN_*)
nix build .#bend-evaluate                             # evaluate (env: CKPT, CORPUS, EVAL_WINDOWS)
nix build .#checks.x86_64-linux.{bend-spec,bend-tests,bend-train}
```

A local build needs `unset CC`, because `CC=gcc` breaks Bend's clang step.
Run with `bend f.bend -o out && ./out --threads 16`.

## Results against master

All figures below use the v3 bpe100m checkpoint
(`run/pulled-root-65.95.12.163-44704-checkpoints/wiki-bpe100m-v3-global.checkpoint`,
step 6000, 12 layers, GLA/softmax 3:1, RG-LRU, qk-norm, sinks). Master means
the `formal-transformer-sequential` build.

| measurement | master | bend |
|---|---|---|
| greedy, 64 tokens, 5 prompts ("The history of", "Albert Einstein was", "In mathematics, a group is", "The city of Paris", "Water is") | — | byte-identical stdout, header line included |
| per-step top probabilities (`SAMPLE_STATS=1`) | — | agree to ~1e-6 |
| tokenizer identity and prompt encodings | — | identical |
| `evaluate`, first 510 tokens of `enwik8-test-fw32k` (2 windows) | loss 2.966082 (se 0.205292), bpb 2.252185 | loss 2.9661822 (se 0.20528264), bpb 2.2522612 |
| checkpoint load (1.85 GB) | not measured | ~20 s |
| decode | ~0.15 s/token (1 core) | 0.34–0.47 s/token (16 threads) |
| evaluate, 510 predictions | 89 s (1 core) | 253 s (16 threads) |

The evaluate gap is 1.0e-4 nats. Master's evaluate runs its batch training
forward (parallel/chunked GLA). The port scores on the decode path (the
recurrent form), so the two sum in different orders.
`Spec/Linear.bend` proves the two forms equal over any semiring. This is
F32 drift, not a model difference, so F32 stays. The F64 fork is not needed at
this precision.

Training has no master-scale comparison, because retraining the 115M model is
out of scope. What it does have:

- **Gradcheck** (`bend/tests/train.bend`, run by `checks.bend-train`). The
  config is small4-v3, which has 3 GLA blocks with RG-LRU and 1 softmax block
  with qk-norm and sinks. At 16 probes covering every tensor kind, the
  hand-written pullbacks agree with central differences within F32 resolution.
  The training forward's loss (5.4779143) equals the decode path's (5.477914).
- **Loss falls.** The run used the byte tokenizer, `tiny-v3`, `README.md`,
  batch 8 and 40 steps:
  - AdamW at lr 3e-3 took validation loss from 5.547 to 4.661.
  - Muon at lr 0.02 took it from 5.547 to 4.550.

  The run took 8 s. The flake check repeats it on the Bend sources as a corpus.
- **A BTC1 checkpoint round-trips into `bend-generate`**.

## Mapping

| master | bend |
|---|---|
| `Everything.agda` | `Everything.bend`: gates every Spec module and every implementation module ("All terms check.") |
| `Foundation/Algebra`, `Fold` | `Spec/Algebra`, `Spec/Fold` (plus `Spec/Nat`, `Spec/Order` for the lemmas the Agda stdlib supplied) |
| `Language/Weighted`, `Autoregressive`, `Decoding`, `SpeculativeDecoding`, `Trie`, `AutoregressiveTrie` | `Spec/` modules with the same names. Tries are depth-indexed, where Agda used coinduction |
| `Attention/Linear`, `LinearTrie`, `Sink` | `Spec/Linear` (recurrent ≡ parallel, chunk-closed), `Spec/LinearTrie`, `Spec/Sink` |
| `Enriched/Bradley` | `Spec/Bradley`: finite prefixes |
| `AD/Reverse`, `Batch`, `Trusted` | `Spec/Reverse`, `Spec/Batch` (micro-batch gradient theorem), `Spec/Trusted` |
| `Transformer/Config`, `Specification`, `TiedHead`, `ResidualStream` | `Spec/Transformer` (parameter count proven over the implementation's `Config.params`), `Spec/TiedHead`, `Spec/ResidualStream` |
| — | `Spec/Refinement`: ties the spec to the executable code (`gla_step_refines` over `Model.gla.rows`, `prefill_chunks` over `Generate.prefill`) |
| `Config.hs`, `Layout.hs` | `Config.bend`: presets, model identity, parameter count, layout |
| `Artifact.hs` (FTC2 read, FTCC read) | `Checkpoint.bend`, `Bytes.bend`, `Parse.bend`, `Evaluate.bend` |
| `Tokenizer.hs` (encode/decode/identity) | `Tokenizer.bend`, `Sha256.bend` |
| `model.fut` forward, `decode_step` | `Tensor.bend`, `Ops.bend`, `Model.bend` |
| `pieces-defs.fut` pullbacks | `Train/Ops.bend`, `Train/Grad.bend` |
| `Optimizer.hs`, `model.fut` AdamW/Muon | `Train/Opt.bend`: AdamW, Muon (NS5 quintic), warmup + cosine, clip |
| init (`INIT_KIND=hash`) | `Train/Init.bend` |
| `Data.hs` (split, windows) | `Train/Data.bend` |
| `Main.hs generate`, `pickToken`, SplitMix64/xoshiro256** | `Generate.bend`, `Sample.bend`, `Num.bend` (U64 as two U32s) |
| `Main.hs train` | `Train.bend` (same `TRAIN_*` names and defaults) |
| `Main.hs evaluate` | `Evaluate.bend` |
| `Main.hs bench` | `Bench.bend` (decode benchmark on synthetic weights) |

## What the proofs cover, and what they trust

- **Generic laws over a semiring.** Each is written once as a theorem
  template over a `Semiring` record. Since Bend 2.0.27 a template body is
  checked once, at its definition, against opaque parameters (2.0.4 checked
  only instances, and three template proofs written in the wrong rewrite
  direction went unnoticed until the rebase: `Trie.sound`,
  `ResidualStream.dot_zeros`, and `Decoding.keep_max` after `Nat.max` became
  structural). Every template is still instantiated at the Nat and Bool
  semirings in its module, so the gate also runs them. The
  structural laws (folds, tries, decoding truncations, linear attention's
  recurrent/parallel/chunked equality, the batch theorem) are fully generic.
- **F32 is axiomatic.** Bend2's F32 has no algebraic laws, which is correct:
  float addition is not associative. The trusted base is therefore
  assumptions, not theorems:
  - the semiring laws of `Spec/Algebra.bend`, read at F32;
  - the derivative facts for exp and rsqrt, which are fields of the
    `TrustedAnalytic` record in `Spec/Trusted.bend`.

  `AD/Trusted.agda` plays the same role on master.
- **Refinement.** The theorems in `Spec/Refinement.bend` are stated over the
  running code (`Model.gla.rows`, `Generate.prefill`), not over a copy of it.
  So a change to the implementation that breaks them fails the gate.
- **Pullbacks are tested, not proven.** Their correctness rests on the
  gradcheck, as master's rests on `gradcheck` and `pieces-conformance`.

## Not ported, and why

| master | status |
|---|---|
| `learn-bpe`, `prepare-*`, `pack-stdin`, `plan-segment`, `build-eval`, `train-plan`/`train-segment` shards | Not ported. The port reads the artifacts these tools write (`.bpe`, FTCC). `Train.bend` tokenizes a text corpus in memory instead of reading packed shards. |
| writing FTC2, `compact-checkpoint`, resuming from FTC2 optimizer state | The dense trainer does both through the fork's byte effects (`Dense/Ckpt.bend`, hot start below). The tree trainer still writes BTC1. |
| DiLoCo (`Diloco.hs`), multi-GPU | Not ported. |
| GPU execution | The trainer runs each optimizer step under `!` and has been measured on an RTX 3060 (see below). Generate and evaluate still run on the CPU only. |
| diagnostics: `act-stats`, `head-probe`, `head-path-probe`, `grad-compare`, `logits`, `inspect-*`, `bigram-gate` | Not ported. The closest equivalent is `SAMPLE_STATS=1` in generate. |

## Performance notes

- The tensors are balanced binary trees with one F32 per leaf. At 115M
  parameters that is about 1.9 GB of nodes, and every decode step walks all of
  them. That traffic, plus reference-count writes, explains most of the
  2–3× decode gap to master's single-core C.
- The only parallel fork is over matrix rows in `M.matvec`. Forking per node
  in vector ops cost more than it saved.
- Streaming the checkpoint row by row (`Load` over `File.read_bytes` with a
  direct-read fast path) loads in about 20 s. A chunked parallel loader was
  slower (74 s) and was dropped.
- The obvious next step, not done, is leaves holding blocks of floats (for
  example 16 or 64 per leaf). That would cut node count and refcount traffic
  by the block size.

## Training on a GPU: the dense trainer (2026-09-24)

### Where the tree trainer stood

`Train.bend` keeps its tensors as trees, one F32 per heap node, and runs a step under `!`. On an RTX 3060 (2026-09-23) that reached about 66 MFLOP/s, 0.0005% of peak. It remains the reference implementation.

### The dense trainer

`TrainDense.bend` (flake app `bend-train-dense`) runs master's step at GPU speed. It needs a CUDA build made with the Bend2 fork (`github:hhefesto/bend2`, branch `ft-kernels`: upstream 2.0.28 plus one squashed port commit), which the flake uses.

**Bulk ops in Base.** The fork adds three bulk ops to `base.bend`:
- `Array.gemm` and `Array.mm`, matrix products;
- `Array.einsum`, which sums a scalar expression `Ex` over up to six loop indices.

`einsum`'s views can be indirect, so the same op expresses a gather and, with accumulation, a scatter-add.

**Meaning and runtime.** Each op's `base.bend` definition is its meaning, and the JS lane runs that definition directly. Compiled code runs a runtime implementation instead:
- On the CPU, a C loop computes the same sums in the same order. It is bit-identical to the definition on the conformance programs in `bend/gpu`.
- On a CUDA build, products go to cuBLAS (loaded with dlopen).
- Each distinct expression becomes a CUDA kernel, compiled by NVRTC and cached next to the binary. Its reduction strategy is chosen by timing the candidates on first use.
- Ops queue on one stream. The host waits only before it touches array cells itself.

**The step as data.** The step is a list of ops over one store: parameters, activations, tangents and optimizer state. The pieces live in `bend/Dense/`:
- `Layout`: parameters in namedLayout order.
- `Model`: master's decomposed order.
  - Chunked GLA with a default chunk of 16. `Spec/Linear.bend` proves the chunked form equal to the recurrent one at any chunk length.
  - Softmax attention with qk-norm and sinks.
  - The tied head, computed in row chunks.
- `Step`: the forward pass, then the backward with per-layer recompute, then clip, AdamW and Muon.

**Reverse mode is derived** (`Dense/Op.bend`: Elliott's "simple essence"):
- a product's transpose is two products;
- an einsum's transpose multiplies the output tangent by the symbolic derivative of `Ex`;
- gather's transpose is scatter-add.

`Spec/Dense.bend` proves the transform's structural law: the transpose of `xs ++ ys` is `ys`'s transpose followed by `xs`'s.

### Correctness (`checks.bend-dense`, `tests/dense.bend`)

**Against the tree trainer's gradchecked pullbacks.** Same weights and windows through both:

| config | loss | gradients |
|---|---|---|
| small4-v3 | agrees to 1e-7 | every gradient within 5.2e-7 relative |
| small4-v3, four GLA chunks per window | agrees to 1e-7 | within 5.2e-7 relative |
| small4 (sigmoid gates, plain softmax) | agrees to 1e-7 | within 5.1e-7 relative |

**Training trajectories.** Six steps each of AdamW and Muon on small4-v3 match `Train.bend` to about 1e-7 in the loss, the gradient norm and the validation loss.

**On the GPU (RTX 3090):**
- the einsum kernels print the same bytes as the loop;
- the dense program on the GPU matches the tree trainer on the CPU within 4.3e-7.

### Speed: bpe100m-v3 on a vast RTX 3090 (logs in `bend/gpu/g3-rtx3090-2026-09-24/`)

Settings: batch 64 windows × 256 tokens, two micro-batches of 32, Muon, tf32. A single Bend array holds at most 2³¹ floats, so micro-batch 64 does not fit in one store.

| | ms/step | tok/s |
|---|---|---|
| master (`formal-transformer-gemm-cuda`, v3 run, a vast 3090, micro 64, 2026-08-21) | 4,110 | 3,985 |
| dense Bend, first cut (generic kernels, a warp per output, sync per op, profiled) | 3,895 | 4,207 |
| + per-kernel strategy tuning, lazy sync | 2,477 | 6,615 |
| + attention's pure products on cuBLAS | 1,998 | 8,200 |
| + GLA chunk 16 (the default) | **1,702** | **9,626** |

**Utilization.** cuBLAS work is 16.8 TFLOP a step at 26 TFLOP/s. That is 27.6% MFU by master's formula (cuBLAS FLOPs ÷ 35.6 TFLOPS TF32 peak). The card drew a median 304 W of its 315 W limit.

**Loss check.** A 30-step AdamW run (lr 3e-4) takes the validation loss from 10.35 to 5.59.

**Caveat: not a same-box A/B.** Master's figure is its logged production run, on a different vast 3090.

### Hot start: continuing master's run (2026-09-24)

With `TRAIN_INIT=<ftc2>` the dense trainer continues master's run instead of starting from `Train/Init.bend`:

- **`Dense/Ckpt.bend`** reads FTC2 straight into the store. Master's parameter vector is namedLayout order with every matrix `[out][in]`, which is the store's own order, so parameters, the first and the second moment are flat copies (`File.read_f32be`, a fork effect). Muon's momentum lives in the store's `m` cells of the matrices Muon owns, so a load reads it over them and a save splits `m` back into master's two vectors, staging them in the gradient cells. The header and tail are copied verbatim, so a saved file is a checkpoint of the same run that master's resume reads. Load→save is byte-identical on master's v3 step-8000 checkpoint (`tests/hot.bend`, run by hand against a real checkpoint). Offsets are U32: files must stay under 4 GB.
- **`Dense/Plan.bend`** parses master's plan and reproduces its data order: the shard's documents split by global index (`Train/Data.bend`, seed `FTOPENCL`), full windows, and the epoch permutation `splitmix(index + 0x45504f4348)`, consumed in order.
- **The schedule** (lr, warmup, total, betas, weight decay, clip, Muon) comes from the manifest; the step counter is global, so bias correction and the cosine continue where master stopped.
- **Dense evaluate** (`EVAL_CORPUS`) is master's `evaluate` on the dense forward: every full window of every document, bpb = loss · predictions / (bytes · ln 2).
- **The log** carries master's fields plus `ms=`, `tok/s=`, `remaining=` and `eta=`.

Measured on a vast RTX 3090 (instance 52365970): validation at step 8000 is 3.627147 against master's 3.6271493 on the same windows, and the 19 steps master itself ran after that checkpoint (8001–8019, `run/train-cloud-v3-final.log`) agree with the Bend run's to ~5e-6 in the loss and ~1e-5 in the gradient norm, so the continuation is master's trainer step for step; 2,290 ms/step = 7,155 tok/s, 1.8× master's v3 run on a 3090. The 1,702 ms above was another card: the same cold benchmark on this one ran at 2,180 ms/step, so the hot path costs ~5% over it and the rest is the card (thermally limited; logs in `bend/gpu/hot-rtx3090-2026-09-24/`). The run went 8000 → 28000 in 12.7 h. enwik8 test split (6,184 windows): v3 step 8000 1.4903 bpb → best 1.4462 at step 22000, 1.4516 at 28000.

### What the dense path does not do yet

- **Generate** still runs the tree decoder on the CPU. That decoder is byte-identical to master.
- **Saves write in place** (no rename effect in the runtime), so a crash mid-save leaves a short file under the final name.
- **Precision:** `BEND_GEMM_NUMERICS=tf32` also applies to the attention products.
