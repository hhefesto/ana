# The Bend2 port (branch `bend`)

Everything under `bend/` is Bend2 alone: the specification (ported from the Agda
modules), the decoder, the tokenizer, the trainer and the evaluator. There is
no FFI and no custom C/JS effect. The Bend2 toolchain is pinned in `flake.nix`
(input `bend2`, `github:bendlang/bend/8008146a…`, v2.0.4, the same pin as
`~/src/refl`). The Haskell, Agda and Futhark trees stay on the branch as the
reference. Nothing under `bend/` builds or calls them.

```
nix run .#ana-bend -- --prompt "The history of"      # generate (FTC2 or BTC1)
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
  template over a `Semiring` record. Bend2 checks a template only when it is
  instantiated, so every template is instantiated at the Nat and Bool
  semirings in its module. That instantiation is what the gate checks. The
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
| writing FTC2, `compact-checkpoint`, resuming from FTC2 optimizer state | `File.write` takes only UTF-8 Strings, so pure Bend2 cannot write binary. The trainer writes BTC1 instead: a hex text format with the same layout order. Resuming training from a checkpoint is not implemented. |
| DiLoCo (`Diloco.hs`), multi-GPU | Not ported. |
| GPU execution | Bend2 has a CUDA path, but this machine has no GPU. The port has only been run on the C backend (`--threads`). |
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
