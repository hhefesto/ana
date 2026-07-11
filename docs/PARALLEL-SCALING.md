# Parallel Training And Scaling Plan

This document identifies where this repository's own laws license
divide-and-conquer, and lays out a concrete plan for scaling from the
current machine (a display-attached RX 580) to one larger GPU and then to
multiple devices. The organizing principle is the repository's discipline:
**parallelize exactly where a proved equation says the decomposition
preserves meaning**, and record every residual divergence (in practice,
only f32 summation order).

## 1. Where Linearity Licenses Parallelism

### 1.1 The gradient is additive in the batch (proved)

`FormalTransformer/AD/Batch.agda` proves `batch-pullback`:

```text
gradient of (Σᵢ lossᵢ) = Σᵢ (gradient of lossᵢ)   -- one shared cotangent
```

This single theorem licenses data parallelism at every scale:

- **One device, sequential chunks** — the `MICRO_BATCH` accumulation already
  implemented: chunks of the effective batch are processed one after
  another, gradients summed on device, one AdamW step per effective batch.
- **Many devices, simultaneous chunks** — the same sum computed by replicas
  in parallel followed by a reduction. Nothing about the theorem cares
  *when* or *where* each summand is computed.

Because the per-sequence adjoint seed (`1/effective_batch`) is applied
inside `micro_batch_loss_grad`, every decomposition of the same effective
batch computes identical per-sequence contributions; decompositions differ
only in f32 summation order. The conformance oracle checks this equality on
the tiny model (loss bitwise equal, gradient max_abs ≈ 1.5e-8).

### 1.2 Gradient reduction is a monoid fold (proved)

The parameter space is an `AdditiveMonoid` with `+-assoc` and `+-comm`
(`Foundation/Algebra.agda`). Summing shard gradients is therefore
reduction-order independent *in the semantics*: a ring all-reduce, a tree
reduce, and a sequential fold all denote the same vector. Over f32 they
differ by reassociation only — the same tolerated divergence already
recorded in `docs/PROOF-STATUS.md`. This is what makes "all-reduce" safe to
adopt: it is the distributed interpretation of an already-proved fold.

### 1.3 Validation decomposes as a weighted mean (implemented)

Batch validation loss is a mean of per-window means, so for equal-width
chunks:

```text
mean(all windows) = Σ_chunks (|chunk| · mean(chunk)) / |all windows|
```

`chunkedMeanLoss` in the GPU host already evaluates validation this way.
Sharding validation windows across devices is the same equation with chunks
evaluated concurrently.

### 1.4 Bigram-gate counting is a commutative-monoid fold (implemented)

`trainBigram` folds pair counts over document streams with `(+)` under
`Map.fromListWith`. Counts from disjoint document subsets merge by
pointwise integer addition — exact, order-independent, no floating point.
The gate is embarrassingly map-reduce parallel over documents, with *no*
divergence at all.

### 1.5 Layer composition is the chain rule (proved)

`composeD` sends primal values forward and cotangents backward. Partitioning
blocks across devices ("pipeline parallelism") is the distributed
interpretation of `composeD`: device k holds blocks [k·L/K, (k+1)·L/K),
forwards activations, and returns cotangents. Correctness is the already
proved `composition-chain`; utilization requires keeping the pipeline full,
which is exactly what micro-batches provide (chunk j+1 enters stage 1 while
chunk j occupies stage 2). This is the natural *second* axis of parallelism
once a single model no longer fits one device.

### 1.6 Inference parallelism through the state algebra

- **Across prompts:** distinct generation requests share only the read-only
  parameter vector; they parallelize trivially (one context per stream, or
  batched `last_logits`).
- **Within a prompt:** the observation-trie law
  (`observation-run`, `Language/AutoregressiveTrie.agda`) proves that
  incremental stepping equals whole-prefix evaluation for every
  `StateAlgebra`. Operationally this is the KV-cache license, and it is
  also the *migration* license: a generation state can be checkpointed,
  shipped to another machine, and resumed, and the law says the produced
  language is unchanged. Any future serving layer should speak only the
  `out`/`step` interface so the state representation stays swappable.

### 1.7 What is deliberately NOT parallelized

- **Across optimizer steps.** AdamW is a fold over steps; step t+1 depends
  on the moments after step t. No law here licenses running steps
  concurrently, so the plan never does. ("Async SGD" changes the meaning of
  a step; it is out of scope by design.)
- **Across the autoregressive dependency at generation time.** Token t+1
  conditions on token t. (Speculative decoding — a draft model proposing,
  the canonical model verifying — is semantics-preserving because
  verification re-scores exactly; it is listed as future work, not planned
  concretely.)

## 2. The Scaling Tiers

### Tier 0b — this machine's CPU cores (implemented)

`formal-transformer-multicore` compiles the same full kernel program with
`futhark multicore`: every kernel runs data-parallel across all host
cores, losses are step-for-step identical to the sequential backend, and
checkpoints stay interchangeable. This is the default `wiki-train`
backend. On the OpenCL side, note that amdgpu's watchdog is per ring: a
single-value `amdgpu.lockup_timeout` raises only non-compute rings, while
rusticl submits to the compute ring — use the four-value form to actually
lift the limit for training kernels.

### Tier 0 — this machine (RX 580, display-attached) — DONE

The constraint is the ~10 s AMD compute-ring watchdog that killed the first
OpenCL attempt (`docs/RUN-2026-07-10.md`). The remedy is already merged:

```bash
TRAIN_BATCH=8 MICRO_BATCH=1 nix run .#formal-transformer-gpu -- \
  train corpus.bin model.checkpoint 1000 small
```

Effective batch 8, one sequence per kernel launch — each launch stays near
the known-safe single-sequence cost while the gradient quality is that of
the full batch. The sequential-C host remains the fallback trainer and
accepts the same variables; checkpoints are interchangeable between hosts.
Raise `MICRO_BATCH` only after timing shows a chunk finishes well inside
the watchdog on the actual device.

### Tier 1 — one larger GPU (single dedicated device)

Goal: larger presets and contexts, same semantics, no code changes to the
training contract.

1. **Backend.** The OpenCL host runs unchanged on any conformant OpenCL
   implementation (ROCm or rusticl for AMD, NVIDIA's OpenCL for green
   hardware). For better schedulers, Futhark also compiles the same
   `kernels.fut` to CUDA (`futhark cuda`) and HIP (`futhark hip`); adding
   flake packages `formal-transformer-cuda`/`-hip` mirrors the existing
   OpenCL derivation with only the compile line changed. The generated C
   API is identical, so `FutharkKernels.hs` and both hosts need no edits.
   The conformance oracle must be run once against each new backend before
   it is trusted (it executes at build time in the `conformance` check).
2. **Headless device = no watchdog pressure.** On a compute-only device,
   raise `MICRO_BATCH` toward `TRAIN_BATCH` until profiling shows launch
   overhead is amortized; the accumulated result is equation-equal either
   way, so this is purely a throughput knob.
3. **Bigger presets.** Add presets beyond `small` in
   `FormalTransformer.Config` (values only — the layout formula, checkpoint
   manifest, and Futhark size types scale automatically because the
   parameter count is computed, never hard-coded). Every new preset gets
   its bigram gate for free (`bigram-gate corpus.bin PRESET`).
4. **Measured, not assumed.** Before adopting performance rewrites (e.g.
   the matmul-shaped forward worth a measured 1.8× in modArTransformer),
   require the same evidence used there: same-seed identical loss, plus
   this repository's conformance oracle.
5. **Roadmap item with a contract:** mixed precision (f16 storage/compute
   with f32 accumulation) changes the numeric refinement, not the
   semantics; it must arrive with new recorded tolerances and an updated
   `PROOF-STATUS.md`, never silently.

### Tier 2 — multiple GPUs, one host (data parallel)

The design falls out of §1.1–1.2. A step becomes:

```text
1. Sample the effective batch B with the SINGLE checkpointed PRNG stream.
2. Partition it deterministically into K shards (device k takes chunk k).
3. Each device runs micro_batch_loss_grad over its shard
   (adjoint seed 1/B — unchanged; the kernel already takes effective_batch).
4. Reduce: gradient = Σ_k shard_gradient_k        (monoid fold, §1.2)
5. ONE AdamW update; broadcast updated parameters (or update on every
   replica identically — bitwise-equal inputs give bitwise-equal replicas).
```

What this preserves, by construction:

- **A step still means one effective batch.** `STEPS`, the schedule, and
  checkpoint resume semantics are untouched.
- **PRNG identity.** Sampling stays on one stream *before* sharding, so the
  checkpointed `PRNGState` reproduces the run for any K, including K=1.
  A K-GPU run and a single-GPU run of the same seed differ only by f32
  reassociation — testable on the tiny model, and the conformance oracle's
  micro-batch check is exactly this test with sequential shards.
- **Checkpoint format unchanged.** K, like `MICRO_BATCH`, is launch
  mechanics, not identity.

Implementation sketch (in order of increasing engineering):

- **Phase A (host-mediated reduce, K contexts in one process):** create K
  Futhark contexts (one per device via `futhark_context_config_set_device`
  — one new FFI import), spawn K Haskell threads, download each shard
  gradient (p floats), sum on the host in Double, upload once, one
  `adamw_step`. Bus cost 2·K·p floats per step; perfectly adequate for the
  ~10⁵–10⁷ parameter range this repo targets next, and it maximizes
  numerical transparency (host-visible gradients).
- **Phase B (device-resident reduce):** peer-to-peer or staged `map2 (+)`
  reduction on one device; adopt only when Phase A profiling shows the bus
  is the bottleneck.
- **Conformance extension:** K=2 sharded step vs K=1 step on the tiny
  model, same tolerances as the existing micro-batch check.

### Tier 3 — multiple hosts

Same equations, bigger reduce:

- **Gradient all-reduce over the network.** Still §1.2's monoid fold; use
  any deterministic reduction topology (ring/tree). Fix the reduction order
  per run so results are reproducible bit-for-bit given the same cluster
  shape, and record the topology in the run log.
- **Data distribution is already solved by the artifact layer.** The
  document split is a pure hash per document (`splitDocuments` — seed,
  fraction, index), so every node computes the same split independently;
  the corpus fingerprint in `CorpusArtifact` guarantees all nodes train on
  the same dataset or refuse to start. Shard *documents* to nodes
  deterministically; window construction remains node-local.
- **One writer.** The rank-0 node samples the batch schedule (or all nodes
  run the same PRNG — equivalent), performs/validates the checkpoint
  writes, and owns the atomic-rename discipline; the checkpoint remains a
  single self-describing artifact any node (or this laptop) can resume.
- **Failure model.** Because a step is atomic and checkpoints are exact,
  node failure costs at most the steps since the last snapshot; there is no
  partially-applied distributed state to reconcile.

### Beyond data parallel (when a model stops fitting one device)

Two lawful axes, in adoption order:

1. **Pipeline parallel (composeD, §1.5).** Partition blocks across devices;
   micro-batches keep stages busy. Requires activation/cotangent transfer
   entries in `kernels.fut` (per-block forward and backward-slice entries)
   and a layout-aware partitioner. The layout stays v1 — devices hold
   *slices* of the same flat vector, and `Slice` metadata already names
   every leaf's offset and length.
2. **Tensor parallel (distributivity).** Splitting a matmul by rows/columns
   is licensed by the semiring distributivity laws; it cuts *within* leaves,
   so it needs a sharding annotation per leaf on top of `Slice`. This is
   the only tier that touches layout metadata; version it (layout v2) and
   let checkpoint validation reject mixed interpretations, exactly as the
   existing contract demands.

## 3. Parallel Inference Serving (shorter horizon)

- **Today:** run N independent `generate` processes against the same
  checkpoint file; the artifact is read-only and self-describing.
- **Next:** a batched `last_logits` over a `[batch][sequence]` token array
  (the entry is a 20-line generalization of the existing one) serves many
  streams per launch.
- **Then:** a KV cache as a `StateAlgebra` implementation, obligated to the
  `observation-run` law; once it exists, prompt prefill (parallel over
  positions) and decode (sequential) separate cleanly, and states migrate
  between machines under the law of §1.6.

## 4. Verification Obligations Per Tier

| Tier | New check | Kind |
|---|---|---|
| 0 | micro-batch ≡ full batch (tiny model) | in oracle, passing |
| 1 | oracle green on the new Futhark backend; same-seed loss for perf rewrites | build-time |
| 2 | K=2 shard step ≡ K=1 step (tiny model); PRNG replay across K | oracle extension |
| 3 | fixed reduction topology recorded; cross-node fingerprint agreement | run-time validation |
| pipeline/tensor | per-block conformance vs whole-model; layout v2 roundtrip | oracle extension |

The standing rule, restated once: every scaling mechanism must name the
equation that makes it meaning-preserving, and every residual divergence
must be f32 summation order, measured and recorded.
