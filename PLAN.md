# PLAN — GEMM backend path (chunkwise GLA → BLAS-decomposed step → tensor cores)

Living roadmap for the current line of work on branch `attention-semantics`.
`HANDOFF.md` points here. **Continue from Stage B below.** Read alongside
`docs/ATTENTION-SEMANTICS.md` (the semantics + what is proved),
`docs/GEMM-BACKEND.md` (the normative Stage B contract, GEMM shapes, ABI,
memory audit, and test matrix), `docs/DENOTATIONAL-ASSESSMENT.md` (methodology), and
the Agda proofs under `FormalTransformer/Attention/`.

Conventions: commit per goal, **never** add a co-author line, push `master`
and `attention-semantics` as each goal lands. All work is local — the rented
GPU was destroyed 2026-07-19 and the RX 580 has no tensor cores, so Stages A
and B are verified locally and Stage C waits for a rental (user's $ call).

## Why

The hybrid GLA model trains at quality parity with softmax at small scale
(A/B in `docs/RUN-2026-07-18-GLA.md`); its projected win is execution shape,
not FLOPs. The proved `chunk-closed` theorem
(`FormalTransformer/Attention/Linear.agda`) licenses executing GLA attention
chunkwise, where the heavy work is dense GEMMs — what tensor cores consume.
Measured on the (now destroyed) RTX 5070 Ti: ~0.26 TFLOPS achieved, ~0.6% of
FP32 peak, because the fused Futhark step is FP32 map/reduce with no matrix
products.  Stage B exposes contractions to BLAS so Stage C can measure what
this model and these shapes actually gain.  There is no guaranteed speedup:
transfers, launches, small matrices, non-GEMM work, and memory remain bounds.

Design resolutions:
- **Stage A oracle, Stage B schedule**: Stage A retains its vjp-safe masked
  parallel chunk expression.  Stage B executes the licensed recurrence
  sequentially on the host, `S[0]=0`,
  `S[k+1]=exp(D[k])⊙S[k]+T[k]`, and implements the explicit reverse recurrence
  in `docs/GEMM-BACKEND.md`.  `nc=n/C` is unrestricted; no differentiated host
  loop or `nc<=4` assumption exists.
- **Never form K/Γ** (overflow): every decay factor stays `exp(cum_i −
  cum_s)`, i ≥ s ⇒ exponent ≤ 0.
- **BLAS owns contractions**: shared/output projections, softmax `QK^T` and
  `PV`, GLA `Kbar^T V` and `Qbar S`, and every corresponding matrix pullback
  cross the logical GEMM boundary.  Channel-dependent overflow-safe GLA intra
  remains a Futhark piece because it is not one ordinary dense GEMM.
- **Raw device pointers confirmed** in the generated headers (Futhark
  0.25.37): `futhark_new_raw_f32_1d(ctx, CUdeviceptr, n)` /
  `futhark_values_raw_f32_1d` — cuBLAS interop is real. The CPU stage uses
  staged copies anyway (correctness, not speed).

## Stage A — chunkwise GLA attention in Futhark — **LANDED**

`gla_attention_chunked` (`backend/futhark/model.fut`) executes the training
forward chunkwise, `chunk-closed` applied at two levels (token-level within
a chunk; chunk-level across chunks, no differentiated loop). Chunk length is
`GEMM_CHUNK` (default 64, whole window if it does not divide), threaded
through every entry program and the FFI. The quadratic form is retained as
`gla_block_quadratic` / `logits_quadratic` for the equivalence check.

Evidence (all local, all green):
- `tests.fut`: `test_chunk_equivalence` true at chunk 1, 2, 3, 6.
- conformance: `chunked vs quadratic GLA logits` ~7e-9; every gradient/AdamW
  comparison runs at chunk 2, exercising the cross-chunk carry.
- codegen gate: `nix build .#futhark-kernels .#futhark-kernels-cuda` both
  succeed (OpenCL + CUDA vjp of the one-vjp trainer program).
- quality regression: `gla-small` 5000 steps at GEMM_CHUNK=16 (4 chunks of
  16 over the 64-window) → best val **2.0671 nats**, within 0.0139 of the
  quadratic run's 2.0532 (inside the ±0.02 gate; the residual is f32
  trajectory divergence, not operator difference), beats the bigram gate at
  step 1000.
- multicore bench: context-axis gradient point (n=256) 119.7 → 68.7 ms.

## Stage B — decomposed step with BLAS at the boundary — **NEXT (start here)**

Implement exactly `docs/GEMM-BACKEND.md`; this section is the work order, not
an alternative design.

1. Add the flat 1-D `backend/futhark/pieces.fut` production surface and a
   `pieces-conformance.fut` wrapper that imports it and adds fused-oracle
   entries.  Generate exactly the wrapper for conformance, never two Futhark
   libraries in one test executable.  Nonlinear and elementwise semantics
   remain single-sourced; CE dlogits is analytic.
2. Implement the logical row-major `Blas` API and OpenBLAS adapter first.
   Cover `NN/NT/TN`, strides, batches, and accumulation before model code.
   The future cuBLAS adapter reverses operands/dimensions for column-major; it
   does not use the CBLAS calling convention.
3. Implement host-composed block forward/tape/backward, including sequential
   GLA state and reverse equations, hybrid dispatch `layer % 4`, all
   cotangent fan-in, tied embedding gather plus unembedding, and effective-
   batch scaling exactly once.  Extract and reuse the existing training-loop
   scaffolding rather than copying it.
4. Package `futhark-pieces`, `formal-transformer-gemm-cpu`, and
   `gemm-conformance`.  Conformance links one generated library and compares
   the decomposed path with Numeric.AD and the fused oracle in separate
   contexts.
5. Pass the complete adapter/piece/recurrence/block/objective/optimizer/shape
   test matrix in the contract, including every gradient entry, uneven
   microbatch partitions, repeated tied-embedding IDs, `nc>4`, and audited
   bpe10m/gla peaks at microbatch 1 and 8.  Then run `gla-small` for 5000 steps
   with the recorded ±0.02-nat trajectory gate.

The tape formula and current f32 budgets are auditable in the contract: peak
tape plus simultaneous logits/dlogits scratch ranges from 51.58 MiB (bpe10m,
microbatch 1) to 508.75 MiB (gla, microbatch 8), excluding allocator,
workspace, staging, and persistent optimizer state.  Actual RSS is a required
measurement.  Pin `OPENBLAS_NUM_THREADS=1` for conformance.

## Stage C — rental (ready-to-run; blocked on hardware)

`formal-transformer-gemm-cuda`: `futhark cuda --library pieces.fut` + cuBLAS;
`Buffer` becomes device pointers via the verified raw-array C API, with the
contract's conservative synchronization at every Futhark/cuBLAS ownership
transfer; batched GEMMs use `cublasSgemmStridedBatched`.  Establish and test an
IEEE-f32 mode rather than inferring equality from a math-mode flag. Then
TF32/BF16 as a NEW numeric interpretation: `manifestNumerics` field (default
"fp32-ieee"), artifactVersion bump with back-compat decode, resume rejection
like `manifestClipNorm`, measured tolerances + gradient cosine ≥ 0.999 + a
2k-step loss-trajectory A/B vs fp32. Measure synchronized median/p95 step time
and GEMM-only MFU; record in a `docs/RUN-*.md`. Full detail is in
`docs/GEMM-BACKEND.md`.

## Verify the whole tree

```bash
nix develop -c agda -i . Everything.agda          # proofs
nix develop -c cabal test                          # 24 Haskell tests
nix build .#conformance && ./result/bin/conformance
nix flake check                                    # all backends + tests
WIKI_CHECKPOINT=run/gla-small.checkpoint nix run .#wiki-generate
```

## Top risks (mitigations in docs/GEMM-BACKEND.md)

- Decomposed backward drifting from fused semantics → single-sourced scalar
  defs + dual conformance (AD and fused oracle); the fused oracle stays
  forever.
- Missing cotangent fan-in in host reverse → explicit recurrence equations,
  repeated-token/tied-embedding tests, and every-entry gradient comparison.
- BLAS vs GHC/multicore thread contention → `OPENBLAS_NUM_THREADS=1`.
- `gla_intra`, transfers, or small GEMMs dominate → profile before redesign;
  Stage B makes no speed guarantee and Stage C reports the measured boundary.
