# RUN 2026-07-20 — first tensor-core execution (Stage C gates)

Box: vast.ai RTX 5060 Ti (Blackwell sm_120, 16 GB), driver 570.153.02,
Max CUDA 12.8, 48-core host, Ubuntu 24.04 container. Flake repinned to
`cudaPackages_12_8` to match the driver (commit 17dac44); NVRTC 12.8 PTX
accepted at context creation (the earlier 12.9 pin was never exercised on
this driver).

## Build gate — PASSED

`nix build .#formal-transformer-gemm-cuda` via `BUILD_GEMM_CUDA=1
cloud-init.sh`; libcuda resolved through the driver-libs workaround
(`run/cloud-env.sh`). `cuda-blas-test` on the GPU:

```text
FP32 IEEE max errors: dense=1.34935430e-7, dX=8.74476447e-8, dW=1.06525255e-7, NN=1.72575040e-7, NT=2.71984865e-7, TN=1.72123881e-7; overall=2.71984865e-7
TF32 max errors: dense=1.34935430e-7, dX=8.74476447e-8, dW=7.82337207e-4, NN=1.72575040e-7, NT=2.71984865e-7, TN=1.19172957e-3; overall=1.19172957e-3
BF16 max errors: dense=1.20641773e-3, dX=6.20866936e-4, dW=7.82337207e-4, NN=1.72575040e-7, NT=2.71984865e-7, TN=1.39552022e-2; overall=1.39552022e-2
CudaBlasOps GPU runtime tests passed
```

The error growth from FP32 → TF32 → BF16 on the pullback and TN cases is
the tensor-core signature: the modes execute genuinely different GEMM
arithmetic, each within its stated tolerance (fp32 3e-6, tf32 4e-3,
bf16 3e-2).

## Training gate — PASSED

One 1-step `tiny` train per interpretation (`TRAIN_BATCH=1 MICRO_BATCH=1`,
byte corpus from repo docs). All three runs logged their numerics and
checkpointed; train losses differ at the 1e-5 level across modes (distinct
arithmetic, same trajectory shape):

| mode | logged numerics | train_loss (step 1) |
|---|---|---|
| fp32 | Fp32IEEE | 5.5538550 |
| tf32 | Tf32TensorCores | 5.5538473 |
| bf16 | Bf16TensorCores | 5.5538760 |

Checkpoints pulled to the local (CPU) machine decode and report their mode
via `inspect-checkpoint` — artifact portability holds. Same-schedule resume
of the fp32 checkpoint under `GEMM_NUMERICS=tf32` is rejected:

```text
checkpoint numerics do not match this backend
  checkpoint: Fp32IEEE
  this run:   Tf32TensorCores
```

## Performance observation (expected, not a regression)

20 `gla-small` steps, batch 1, tf32: 102.8 s wall ≈ 5.1 s/step (includes
one-time NVRTC startup). This matches the documented scope of the first
runtime — host-list staging at every boundary, per-GEMM cuBLAS resource
lifecycle, host AdamW. It establishes correctness on hardware; device
residency, persistent handles, and stream ordering are the follow-on
performance work (docs/TENSOR-CORE-RUNTIME.md "Current performance scope").

## Trajectory A/B — PASSED (device-resident runtime)

2000-step `gla-small` runs per mode on a 452 KB byte corpus of the repo
docs, `VALIDATE_EVERY=500 VALIDATION_WINDOWS=16`, on the device-resident
runtime (`traj2-*` logs):

| mode | best validation loss | final train loss |
|---|---|---|
| fp32 | 3.0732365 | 2.8068940 |
| tf32 | 3.0649530 | 2.7513282 |
| bf16 | 3.0319421 | 2.7678528 |

All three modes land in the same neighborhood; the spread is noise-level,
so TF32/BF16 checkpoints are accepted training artifacts at this scale.
`gla-small` bench (batch 1): median 62.5–63.1 ms/step, ~1000 target
tokens/s in every mode — identical across modes because at these shapes
the run is launch-bound (GEMM MFU 0.019%); the tensor-core question is
answered by `bpe10m` below.

## bpe10m — the O(v²) CE pullback hang, diagnosed and fixed

`bench bpe10m` hung in every mode: device memory pinned at 15,857 MiB
within seconds and no step ever completed. Bisect on hardware: gla-small
with `GEMM_CHUNK=16/32` (2 and 4 GLA chunks) passes, and the hang
reproduces at `TRAIN_BATCH=1 MICRO_BATCH=1` — so neither multi-chunk
state passing nor batching. A new `GEMM_TRACE=1` per-op trace showed the
driver blocked in `syncFutharkIfDirty` with exactly one non-trivial
kernel pending: `piece_ce_bwd`, while all traced entry outputs summed to
only ~850 MB — the remaining ~15 GB was entry-internal.

Root cause: `piece_ce_dlogits` computed `(softmax checked[b,i])[word]`
per output element — a full vocab-length softmax recomputed for every
one of batch*seq*vocab elements, O(batch*seq*v^2). Invisible at
conformance and gla-small dims (vocab 258); at vocab 8192 it is a ~8192x
work amplification. Fix: hoist the row softmax one level (pure
let-floating, per-element expressions unchanged — the `model.fut`
"computed once per head" policy). CPU conformance passes unchanged
(decomposed vs fused oracle max_abs 1.19e-7, vs Numeric.AD 6.5e-8).

## bpe10m bench after the fix — v1 baseline (conservative barriers)

First-ever completed bpe10m steps on the device-resident runtime,
`TRAIN_BATCH=8`, 50 measured steps:

| mode | micro | median s/step | target tok/s | MFU (peak 23.7 TF) |
|---|---|---|---|---|
| fp32 | 1 | 11.154 | 182.9 | 0.127% |
| tf32 | 1 | 11.084 | 184.1 | 0.128% |
| bf16 | 1 | 11.095 | 183.9 | 0.128% |
| fp32 | 8 | 8.386 | 243.3 | 0.169% |

Peak device memory 12,441 MiB at micro 8; ~88 W. Two facts define the
optimization target: the three numerics modes are within 0.6% of each
other (the GEMMs are effectively free — the runtime is drowning in
per-op orchestration), and micro 8 recovers only 1.33x of the
theoretical 8x op-amortization (a large fixed per-op cost that scales
with neither data nor launch count alone). For reference the fused
Futhark shader-core trainer sustained ~1,575 tok/s on an RTX 5070 —
the decomposed runtime must beat that for tensor cores to pay.

## The optimization ladder (all gated on exact loss preservation)

Every change below kept the 1-step train losses bit-identical
(gla-small 5.6614537, bpe10m 9.1370810) and passed the CPU conformance
matrix (decomposed vs fused oracle vs Numeric.AD). bpe10m batch 8
micro 8, median step:

| version | change | s/step | tok/s |
|---|---|---|---|
| v1 | conservative barriers, full traversal | 8.386 | 243 |
| v2 | forward-only layer stack (the forward pass had run every block's pullback against a zero cotangent and discarded it) | 4.196 | 486 |
| v3 | handwritten `piece_gla_intra_bwd` (replaces vjp; the AD kernel was 194 ms/call, 93% of GPU time), zero-cotangent elimination inside sub-blocks (4x -> 1x intra_bwd per layer), eager gradient-assembly frees (62 x 42 MB chain) | 0.210 | 9,698 |
| v3 tf32 | — | 0.202 | 10,110 |
| v3 bf16 | — | 0.202 | 10,112 |

Peak memory fell 12,441 -> 3,863 MiB; power rose 88 -> 124 W; micro 16
(batch 16) scales linearly at 10,377 tok/s. tf32/bf16 now measurably
beat fp32 (~4%) — the first end-to-end tensor-core visibility. Overall:
55x from v1, and ~6.4x the fused shader-core trainer on a weaker card.

Negative result, kept for the record: `GEMM_ORDERING=stream` (cuBLAS on
the legacy default stream of the shared CUDA context, host dirty-flag
barriers elided) is loss-exact but performance-neutral at every scale —
the conservative host barriers were never the bottleneck. The env switch
remains for experiments; conservative stays the default.

Diagnosis instrumentation added along the way, both env-gated and free
when off: `GEMM_TRACE=1` (per-op stderr trace naming the blocked barrier
and requested sizes) and `FUT_PROFILE=1` (Futhark per-kernel duration
report at context teardown). The v3 profile puts the next targets at
`piece_gla_intra_fwd` (82 ms/step, same per-element recompute pattern in
the forward — hoisted in v4), the 608 per-step `replicate_f32` zero
fills backing GEMM outputs (~43 ms), and `piece_ce_bwd` (18 ms).

## v4 and the training launch

Hoisting the intra-forward weight matrix (same let-floating, loss-exact):

| version | mode | s/step | tok/s | MFU |
|---|---|---|---|---|
| v4 | fp32 | 0.146 | 13,945 | 5.30% |
| v4 | tf32 | 0.138 | 14,770 | 5.61% |

61x over v1, ~9.4x the fused shader-core trainer. With the gates green,
the whole-Wikipedia bpe10m run launched 2026-07-20 23:47 (box time) via
`deploy/train-cloud.sh`: `Tf32TensorCores`, batch 8 / micro 8,
global_total = 1,833,157 updates, checkpoint/validate every 2000 steps,
~2.9-day full pass at the measured rate. First minutes: ~7 steps/s
matching the bench, train-loss EMA descending through the clipped
warmup transient, 102 W / 3.9 GB steady.

Remaining MFU levers, in profile order: the per-GEMM `replicate_f32`
zero fills, `piece_ce_bwd` throughput, `l2norm_heads_bwd` (still vjp),
data-movement fusion (split/merge/gather/put), micro 16/32 (linear
scaling headroom, 12 GB free), and larger presets where d and ffDim
give the tensor cores real GEMM shapes.

## The training run diverged — and the runtime is exonerated

The launched run's loss rose monotonically once warmup ended (9.13 at
step 100, EMA 12.95 by step 1000, 23.6 by step 1700), with small, flat
gradient norms (~0.35-0.45 after an initial 2.9-4.1). The run was
stopped and the cause hunted to ground. Every runtime layer was
verified independently:

- **Forward**: 1-step losses bit-exact across all binary versions and
  ordering modes (gla-small 5.6614537, bpe10m 9.1370810).
- **Backward algebra**: manual `piece_gla_intra_bars` vs `vjp2` at full
  production dims on CPU — max diff 1.8e-4 against magnitudes ~675
  (~3e-7 relative, pure f32 reduction order). `backend/futhark/
  intra-check.fut`.
- **CUDA kernels at production dims**: `backend/futhark/kernel-check.fut`
  compiled with `futhark c` (local) and `futhark cuda` (box) from
  identical in-program inputs — ce_bwd (vocab 8192), causal_softmax_bwd
  (n 256), embed_scatter, gate_cum_bwd, l2norm_bwd, intra_bars all agree
  (max-abs statistics match exactly).
- **Lineage independence**: v2 (vjp backward) and v4 (manual backward)
  produce the SAME divergence curve step-for-step at 300 steps — the
  trajectory is robust to 1e-7 gradient perturbation, i.e. systematic.
- **Multi-chunk**: gla-small trained at GEMM_CHUNK=16 (4 chunks)
  converges identically to single-chunk.
- **Optimizer/machinery**: gla-small descends 5.66 -> 3.57 in 300 steps
  under the identical code path.

Schedule sweep on real shard-0 data (300 steps, TRAIN_LR/TRAIN_WD env
overrides added to `optimizerFor`): 3e-4 diverges hard (EMA 10.67);
1e-4 is the only stable setting (EMA 9.21) but a 1000-step run rises
again (EMA 9.44); 3e-5 noisy-flat; wd=0 reduces divergence at 3e-4
(9.51 vs 10.67) but nothing descends below the 9.13 init.

**Conclusion: the bpe10m hybrid preset (vocab 8192, d 320, 6 layers,
n 256) anti-learns under every tested schedule, while the identical
machinery trains gla-small cleanly. This is a model-scale property,
observable for the first time because nothing could previously train
bpe10m faster than minutes per step.** Leads for the model track: the
gradient-norm collapse from ~4 to ~0.35 within 50 steps (init scaling
at d=320 vs 64? gate saturation?), and weight decay's outsized role in
the divergence rate. The trainer, corpus, plan, and 14.7K tok/s
pipeline are ready to relaunch the moment the model is fixed.

## 2026-07-21: Root cause found — piece_ce_bwd was mis-compiled on CUDA

The "model-scale property" conclusion above was WRONG, and so was the
runtime exoneration. The divergence was a runtime bug after all — one
crafted to slip through every check above.

**The bug.** The CUDA compilation of `piece_ce_dlogits`
(`backend/futhark/pieces-defs.fut`) — then a `tabulate_2d batch sequence`
whose body produced a `[v]` array — was mis-lowered at production dims
(vocab 8192, n 256, rows 2048): the kernel returned mis-indexed rows.
Element-wise, its output had cosine ≈ −1e-4 against the softmax-CE
pullback of its own input logits, and even the `i == sequence-1` guard
rows (which must be exactly zero) came back nonzero. The forward loss is
a separate, correctly-compiled entry, so every run reported correct
losses while stepping on garbage: AdamW normalized the garbage per
coordinate to lr-scale updates — the smooth monotone rise. The identical
source compiles correctly on the C backend (CPU dumps match the exact
f64 gradient to cos 1.000000).

**Why every earlier check passed.**
- The bpe10m "bit-exact" references are LOSSES; the loss path was fine.
- Gradient conformance ran at vocab 5 / d 4 (gemm-conformance) — the
  mis-lowering does not trigger there, nor at gla-small dims.
- The kernel-check "ce_bwd at vocab 8192 agrees" compared max-abs
  STATISTICS — permutation-invariant, blind to row scrambling — and
  compiled its own instance of the definition rather than exercising the
  production pieces library entry.
- Lineage independence (v2 vs v4 same curve) held because both lineages
  shared the one broken kernel.

**The evidence chain** (tools now in-tree):
1. FREEZE_TRUNK + INIT_ZERO_OUT makes the trunk exactly identity both
   directions, so the model reduces to embedding → rms → tied logits,
   whose gradient has an exact closed form. In-runtime this probe ROSE
   11.80 → 12.72 val over 1000 steps; the same problem in exact f64
   (`head-probe`) descends ~4 nats in 500. tf32 vs fp32 reruns were
   identical to 7-8 digits — numerics exonerated.
2. `DUMP_GRAD_VECTOR=path` (train env) dumps the raw step-1 gradient +
   batch; `grad-compare` (sequential binary) recomputes the exact f64
   gradient for that batch: CUDA cos = −0.019 (garbage, plausible norm);
   CPU fused backend cos = 1.000000 on the identical batch.
3. `head-path-probe` (gemm-cuda binary) isolates each head-path op at
   production dims against host references: dense fwd/bwd and rms bwd
   and embed scatter/gather all exact; `piece_ce_bwd` alone garbage.

**The fix.** `piece_ce_dlogits` rewritten as hoisted per-row softmax
statistics (same expressions and reduction order as the forward) plus a
single flat regular `tabulate` over `batch*sequence*v` with index math —
the shape every other piece uses. Values are bit-identical on CPU; the
CPU gemm-conformance suite stays green.

**Verification after the fix** (box, 5060 Ti):
- `head-path-probe`: ce_bwd cos 0.99999999999999, max-abs-diff 4e-11,
  guard rows exactly zero.
- Step-1 gradient vs exact f64: cos = 1.000000, norm ratio 1.0000 (tf32).
- Frozen-trunk probe: 11.80 → 7.40 val in 1000 steps (beats the unigram
  floor 7.48; previously rose to 12.72).
- Full hybrid, era-matched (sin 0.02, lr 3e-4, b8, tf32): 9.14 init →
  7.72 val @ step 200 → 7.43 @ 400, descending — the first real bpe10m
  learning on this runtime. The GLA hybrid attention is exonerated.

Lesson recorded: verify kernels ELEMENT-WISE at production dims through
the production library entries; permutation-invariant statistics (max-abs)
cannot see index scrambling.
