# The GEMM Backend Path

Goal: expose the model's dense contractions to an interchangeable BLAS
boundary without changing the model, objective, parameter layout, or optimizer.
Stage B is a correctness and architecture milestone, not a speedup claim.  CPU
staging copies, small GEMMs, Futhark call overhead, and non-GEMM work can make it
slower than the fused trainer.  GPU throughput is measured only in Stage C.

## Stage A - chunkwise attention (LANDED)

See `docs/ATTENTION-SEMANTICS.md`, "The Chunkwise Execution".  The training
forward now runs the GEMM-shaped chunkwise form licensed by `chunk-closed`,
conformance-gated (chunked = quadratic to about 7e-9; all gradient gates at
chunk 2), codegen-gated through the OpenCL and CUDA backends, and benchmarked
(context axis 119.7 -> 68.7 ms multicore).  The fused sequential and quadratic
oracles remain permanent test dependencies.

## Stage B - normative implementation contract

The words MUST, MUST NOT, and MAY below are normative.  A Stage B implementation
is complete only when the test matrix at the end passes.

### Notation and layouts

- `B`: microbatch size; `n`: tokens per sequence; `M=B*n`; `v`: vocabulary;
  `d`: model width; `f`: FF width; `h`: heads; `r=d/h`; `C`: chunk length;
  `nc=n/C`.  Require `B>0`, `n>=2`, `C>0`, `n%C=0`, `d%h=0`, and even `r`.
  There is no upper bound such as `nc<=4`.
- Brackets give logical row-major shape.  Batch, head, and chunk are outermost:
  token tensors `[B,n,d]`, headed tensors `[B,h,n,r]`, chunks
  `[B,h,nc,C,r]`, and states `[B,h,nc+1,r,r]`.  Flattening preserves that
  order, with the last index contiguous.  `[B,n,d]` and `[M,d]` are the same
  bytes and require no transpose.
- The checkpoint parameter vector and matrix orientation remain canonical
  layout version 2: `E[v,d]`; per block `rms_att[d]`, `Wq/Wk/Wv/Wo[d,d]`,
  `Walpha[d,d]` for GLA, `rms_ff[d]`, `Wgate/Wup[f,d]`, `Wdown[d,f]`; then
  `final_rms[d]`.  No backend-private packed layout may enter a checkpoint.
- A logical GEMM is
  `gemm(opA,opB,m,n,k,alpha,A,lda,B,ldb,beta,C,ldc)` and means
  `C[m,n] = alpha*opA(A)[m,k]*opB(B)[k,n] + beta*C[m,n]` over f32 row-major
  buffers.  `op` is `N` or `T`; leading dimensions are physical row strides.
  Aliasing an input with `C` is forbidden.  Accumulation uses `beta=1`; a new
  result uses `beta=0`.

### BLAS translations

- CBLAS calls `cblas_sgemm(CblasRowMajor, transA, transB, m,n,k,...)`
  directly.  Strided batches are a checked host loop in Stage B CPU; they MAY
  later use a vendor batch API without changing the logical interface.
- Classic cuBLAS is column-major.  It therefore reverses operands and output
  dimensions: the logical call above becomes
  `cublasSgemm(handle, transB, transA, n,m,k, alpha, B,ldb, A,lda, beta,
  C,ldc)`.  The transpose values are retained but attached to the swapped
  operands; `lda/ldb/ldc` remain the physical row strides.  This is not the
  CBLAS call convention.  The adapter MUST be conformance-tested for `NN`,
  `NT`, `TN`, non-square shapes, `beta` 0/1, and nontrivial strides before use.
- `gemmStridedBatched` has the same logical contract plus element strides and
  count.  CPU loops over batches; CUDA translates to
  `cublasSgemmStridedBatched` with the same operand reversal.  Zero strides and
  overlapping output batches are forbidden.

For every logical `Y=A*B`, reverse mode MUST also cross this BLAS boundary:
`barA += barY*B^T` and `barB += A^T*barY`.  Correct transpose flags replace
materialized transposes.  This rule includes both softmax contractions and all
GLA contractions; no Futhark VJP may silently lower a listed GEMM back to a
map/reduce matrix product.

### Complete forward GEMM inventory

All rows below are per microbatch; outer dimensions shown as "batched" use the
strided interface.

| owner | logical equation | GEMM shape `(m,n,k)` | batch count |
|---|---|---:|---:|
| every block | `Q=Xa*Wq^T`, likewise `K,V` | `(M,d,d)` | 3 |
| GLA block | `G=Xa*Walpha^T` | `(M,d,d)` | 1 |
| softmax attention | `Z=Q*K^T/sqrt(r)` | `(n,n,r)` | `B*h` |
| softmax attention | `A=P*V` | `(n,r,n)` | `B*h` |
| GLA chunk contribution | `T=Kbar^T*V` | `(r,r,C)` | `B*h*nc` |
| GLA inter-chunk output | `I=Qbar*S_k` | `(C,r,r)` | `B*h*nc` |
| every block | `O=A*Wo^T` | `(M,d,d)` | 1 |
| every block | `gate=Xf*Wgate^T`, `up=Xf*Wup^T` | `(M,f,d)` | 2 |
| every block | `FF=hidden*Wdown^T` | `(M,d,f)` | 1 |
| model output | `logits=H*E^T` | `(M,v,d)` | 1 |

`Q*K^T` and `P*V` for softmax MUST use BLAS in forward and reverse.  Causal
masking, stable row softmax, and its VJP are Futhark pieces between those two
calls.  The GLA within-chunk score contains a different channel-wise factor
`exp(R[i,c]-R[s,c])` for every `(i,s,c)` and is not one ordinary GEMM.  It
remains the exact overflow-safe `gla_intra` Futhark piece; it MUST NOT form
`exp(-R)` or `K/Gamma`.  Its output reduction into `V` is part of that piece.
This boundary is intentional, not counted as BLAS FLOPs, and is a possible
Stage C profiling target.

For GLA equations below, `Q` and `K` mean the post-L2-normalization headed
values; `Q0` and `K0` denote projection outputs.  Reverse attention
cotangents pass through the head-L2 piece before reaching `Q0` and `K0`.

### Sequential GLA chunks and reverse

The decomposed backend MUST execute chunks sequentially.  Stage A's masked
parallel expression remains the denotational oracle, not the host schedule.
For each `(batch,head)` and chunk `k`, let `L[k,s,c]=log_sigmoid(gate_logit)`,
`R[k,s,c]=sum_{u<=s} L[k,u,c]`, and `D[k,c]=R[k,C-1,c]`.  Then:

```
Kbar[k,s,c] = exp(D[k,c] - R[k,s,c]) * K[k,s,c]
Qbar[k,i,c] = exp(R[k,i,c]) * Q[k,i,c]
T[k]         = Kbar[k]^T * V[k]
S[0]         = 0
I[k]         = Qbar[k] * S[k]
S[k+1,c,j]   = exp(D[k,c]) * S[k,c,j] + T[k,c,j]
A[k]         = I[k] + gla_intra(Q[k], K[k], V[k], R[k])
```

Every displayed exponential has a non-positive argument.  `T` and `I` are the
listed BLAS calls.  Prefixes, scaling, addition, and state advance are Futhark
pieces invoked by host control flow.

Reverse chunks run for `k=nc-1..0`, with `barS[nc]=0`.  First add the
`gla_intra` VJP outputs to `barQ`, `barK`, `barV`, and `barR`.  For the inter
GEMM and recurrence, where `Gd=exp(D[k])`:

```
barQbar       += barI * S[k]^T
barS[k]       += Qbar^T * barI
barT          += barS[k+1]
barD[c]       += Gd[c] * sum_j (barS[k+1,c,j] * S[k,c,j])
barS[k,c,j]   += Gd[c] * barS[k+1,c,j]
barKbar       += V * barT^T
barV          += Kbar * barT
barK          += exp(D-R) * barKbar
barD[c]       += sum_s (barKbar[s,c] * K[s,c] * exp(D[c]-R[s,c]))
barR[s,c]     -= barKbar[s,c] * K[s,c] * exp(D[c]-R[s,c])
barQ          += exp(R) * barQbar
barR          += barQbar * Q * exp(R)
```

The four matrix products in these equations are BLAS calls.  `barD` is added
to `barR[k,C-1,:]`; reverse inclusive-prefix sum then maps `barR` to `barL`,
and the `log_sigmoid` VJP maps `barL` to gate logits.  Cotangents from intra,
inter, state advance, and scaling MUST be summed before returning to Q/K/V or
the gate projection.

### Ownership and flat piece ABI

- The Haskell host owns model traversal, sequential chunk traversal, tape
  records, buffer reuse, cotangent fan-in scheduling, gradient accumulation,
  and optimizer sequencing.  It performs no model arithmetic: additions are
  piece calls or BLAS `beta=1`; host scalars only validate shapes and select
  BLAS `alpha/beta`.
- `Blas` owns exactly the GEMMs in the inventory and every one of their matrix
  pullbacks.  Weight-gradient destinations use `beta=1` when shared or tied.
- One source, `backend/futhark/pieces.fut`, imports scalar definitions from
  `model.fut` and owns RMS norm, head L2 norm, log-gates/prefixes, safe GLA
  scaling, `gla_intra`, state scale/add, causal mask/softmax, residual adds,
  SwiGLU, cross-entropy/dlogits, embedding gather/scatter-add, head
  split/merge, clipping, AdamW, and zeroing.  Differentiable pieces expose a
  forward entry and a VJP-derived backward entry; CE dlogits is analytic.
- Every public piece array is a flat one-dimensional Futhark array (`[N]f32`,
  `[N]i64`, or `[N]bool`).  Shape scalars precede arrays.  Names are
  `piece_<op>_fwd` and `piece_<op>_bwd`; forward returns flat outputs, and
  backward accepts the same primal inputs, any explicitly documented forward
  output needed by the VJP, then flat output cotangents, and returns one flat
  cotangent per differentiable input in argument order.  No public piece uses
  rank-polymorphic or multidimensional arrays.  The host validates products,
  lengths, and overflow before FFI calls.
- Buffers are row-major and non-aliasing unless an entry argument is explicitly
  unique.  CPU Stage B stores canonical host buffers and stages flat arrays to
  the generated library.  Piece-local temporaries die when the call returns.

The residual path fans `barXout` into both the skip and transformed branch.
Projection, normalization, attention, and FF contributions are accumulated,
never assigned over.  The tied embedding has exactly two fan-in paths:
`barE += barLogits^T*H` from unembedding (BLAS), and scatter-add of the input
hidden cotangents into rows selected by every token occurrence.  Repeated token
IDs and the same row appearing in both paths MUST sum.  The parameter gradient
uses the canonical flat offsets and has exactly `parameter_count` entries.

### Objective and optimizer scaling

For sequence `b`, `ell_b` is mean next-token CE over its `n-1` targets.  For an
effective batch `E`, the optimized objective is `sum_b ell_b/E`.  Every
microbatch sequence is therefore seeded with `1/E`, independent of microbatch
size.  A microbatch returns `sum ell_b/E` and adds its already-scaled gradient
to an accumulator zeroed once per effective batch.  The final short chunk is
allowed, but all chunks together MUST contain exactly `E` sequences.  Clip
once after all chunks and call AdamW once.  Do not divide again in host code,
per piece, per token, or before AdamW.

### Tape lifetime and memory audit

Forward retains only values needed by reverse.  Per block the conservative
tape is eight `[M,d]` arrays (`X`, attention-normalized X, Q, K, V, attended,
post-attention X, FF-normalized X) and three `[M,f]` arrays (gate, up, hidden).
A GLA block additionally retains gate logits `[M,d]` and all `S[0..nc]`
states; a softmax block retains raw scores `[B,h,n,n]`.  Head-normalized Q/K,
probabilities, safe scaled Q/K, T, gate prefixes, and piece internals are
recomputed during that block's reverse and are call-local.  The model retains
final block output and final-normalized hidden (two `[M,d]`).  A block tape is
released immediately after its reverse finishes.  At CE, logits must remain
live while the non-aliasing dlogits output is made, so semantic peak output
scratch is two `[M,v]` buffers; logits is released immediately afterward.

Thus, with `G` GLA and `S` softmax blocks, persistent tape elements are:

```
L*(8*M*d + 3*M*f) + G*M*d
  + G*B*h*(nc+1)*r*r + S*B*h*n*n + 2*M*d
```

At `C=64`, f32 only, the current presets give:

| preset | `(L,G,S)` | microbatch | tape | `2*[M,v]` CE scratch | tape peak |
|---|---:|---:|---:|---:|---:|
| bpe10m | `(6,5,1)` | 1 | 35.58 MiB | 16.00 MiB | 51.58 MiB |
| bpe10m | `(6,5,1)` | 8 | 284.63 MiB | 128.00 MiB | 412.63 MiB |
| gla | `(8,6,2)` | 1 | 47.59 MiB | 16.00 MiB | 63.59 MiB |
| gla | `(8,6,2)` | 8 | 380.75 MiB | 128.00 MiB | 508.75 MiB |

The audit uses `v/n/d/f/h=8192/256/320/864/5`.  It excludes BLAS workspace,
allocator padding, Futhark call-local copies, token IDs, and library runtime
state.  Parameters + gradient + two Adam moments add 161.31 MiB for bpe10m
(`10,571,840` parameters) or 200.71 MiB for gla (`13,153,600` parameters),
before a decay mask or backend duplicate.  The corresponding minimum semantic
totals are 212.89/573.94 MiB for bpe10m at microbatch 1/8 and 264.30/709.46
MiB for gla.  Implementations MUST report actual peak RSS/device allocation
for microbatch 1 and 8; these formulas are an auditable budget, not a claim
that a particular allocator reaches it.

### One-library conformance topology

Production generates `pieces.fut`.  Conformance instead generates exactly one
program, `pieces-conformance.fut`, which imports `pieces.fut` and adds the fused
model-oracle entries.  That one generated library is the only Futhark library
linked into `gemm-conformance`; decomposed pieces and fused oracle share its
context/runtime (separate contexts MAY be used for error isolation).  Do not
also link generated `pieces.fut` or `kernels.fut`, and do not duplicate scalar
definitions.  Stage C generates the production CUDA library from `pieces.fut`
and the CUDA conformance library from `pieces-conformance.fut`, then runs the
same test driver through a backend adapter.

Required tests:

| level | cases | gate |
|---|---|---|
| BLAS adapter | `NN/NT/TN`, odd rectangular sizes, strides, batch, beta 0/1 | elementwise reference |
| each piece | forward plus VJP/finite-difference spot checks, repeated IDs | stated f32 tolerance |
| GLA recurrence | `C=1,2,n`, `nc>4`, forward vs Stage A masked form, reverse finite differences | no missing fan-in |
| block | pure GLA, pure softmax, and 3:1 hybrid; QK/PV pullbacks included | fused oracle |
| objective | full batch and partitions including `1+...`, uneven final microbatch, repeated tokens | loss and every gradient entry |
| optimizer | global clip norm and one AdamW step | fused oracle |
| end to end | tiny hybrid vs Numeric.AD and fused oracle; logits, loss, every gradient | AD `2e-3/2e-2`, fused `1e-4/1e-3` abs/rel |
| shape smoke | bpe10m and gla, microbatch 1 and 8 | lengths, finite values, measured peak |
| trajectory | gla-small, 5000 steps | best validation within 0.02 nats of recorded gate |

The fused oracle is retained permanently.  A sampled gradient or loss-only
comparison does not satisfy the end-to-end gate.

### Synchronization and threading

- CPU: a generated Futhark call must have returned before its staged output is
  read or passed to CBLAS.  CBLAS must return before that buffer is staged into
  Futhark.  Keep one owner per mutable buffer.  Conformance sets
  `OPENBLAS_NUM_THREADS=1` and a fixed RTS capability count; performance runs
  record both BLAS and RTS thread counts.
- CUDA: until common-stream ordering is implemented and tested, use a
  conservative barrier at every ownership transfer.  Call
  `futhark_context_sync` before cuBLAS reads/writes a Futhark raw allocation,
  and synchronize the cuBLAS stream before Futhark reuses it or before host
  access/free.  A raw wrapper and its Futhark owner stay live through both
  barriers.  Host code never dereferences a device pointer.  Errors from either
  runtime are checked at the boundary where they can be attributed.
- No timing interval may include pending work from before its start or omit
  work queued before its end.  Warmup, synchronization policy, thread counts,
  numerics mode, and BLAS versions are recorded with results.

## Stage C - rental intent

Build `formal-transformer-gemm-cuda` from `futhark cuda --library pieces.fut`
plus cuBLAS, using the verified Futhark 0.25.37 raw-array API
`futhark_new_raw_f32_1d` / `futhark_values_raw_f32_1d` and the synchronization
contract above.  Run the complete conformance matrix before training.

IEEE-f32 is the first CUDA target.  TF32/BF16 is a new numeric interpretation,
not an invisible optimization: add `manifestNumerics` (default `fp32-ieee`),
bump the artifact version with older checkpoints decoded as `fp32-ieee`, and
reject resume on mismatch like `manifestClipNorm`.  Establish tolerances from
measurements; the proposed acceptance suite includes logits/gradient error,
gradient cosine at least 0.999, and a 2000-step loss-trajectory A/B against
f32.  A math-mode flag alone is not evidence of equal arithmetic.

Report median/p95 step time over 100 post-warmup synchronized steps and MFU
from the GEMMs actually executed, separated by active numerics.  Compare with
the fused trainer and publish the raw shape/FLOP table in `docs/RUN-*.md`.
Speedup is not guaranteed: it is bounded by GEMM share, transfer and launch
overhead, attainable efficiency at these shapes, softmax's quadratic matrices,
the non-GEMM GLA intra piece, optimizer work, and memory capacity/bandwidth.
