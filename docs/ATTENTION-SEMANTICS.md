# A Semantics For Attention

## The Question, Answered

*Have we stated a semantics for attention?* Until this document: **no**.
Attention was one uninterpreted record field —
`causalAttention` in `FormalTransformer/Transformer/Specification.agda`,
under the module's own disclaimer "signatures only". It had shape evidence
(`Tensor (shape2 n (model c)) → Tensor (shape2 n (model c))`, causal bound
`n ≤ context c`) and an executable Futhark body, but no defining equation,
no law, and no connection to the proved
`Language`/`StateAlgebra`/`Trie` layer. `docs/DENOTATIONAL-ASSESSMENT.md`
identifies this as the repository's central deviation from denotational
design.

This document states the missing semantics, records what is now proved,
and derives the model and roadmap decisions from it.

## The Semantics

Source: Kimi Linear (arXiv:2510.26692), whose §6.1/Table 6 and Table 7
supply, respectively, a *classifying form* and a *derivational meaning*
for attention. Both translate directly into this repository's vocabulary.

### 1. Attention variants are one recurrent form

Every causal attention mechanism computes

```text
o_t = q_tᵀ · ( Σ_{j≤t}  (∏_{s=j+1..t} A_s)  k_j v_jᵀ )
```

for some family of linear transitions `A_s`. The variant IS its transition
family:

| variant | transition `A_s` | state |
|---|---|---|
| softmax attention | identity, under the exp kernel `φ(q)ᵀφ(k) = exp(qᵀk)` | the whole prefix (unbounded) |
| RoPE softmax | fixed orthogonal rotations | the whole prefix |
| vanilla linear attention | identity | one dk×dv matrix |
| RetNet-style decay | constant scalar `γ·I` | one dk×dv matrix |
| gated linear attention (GLA) | data-dependent diagonal `diag(α_t)` | one dk×dv matrix |
| delta rule / KDA | `(I − β_t k_t k_tᵀ)·diag(α_t)` | one dk×dv matrix |

Position is subsumed: RoPE is the orthogonal, data-independent special
case of the transition family, so a data-dependent family carries
positional information intrinsically and no rotation is needed where one
is present.

### 2. Linear attention's update rule is derived, not postulated

For the linear class the recurrence `S_t = A_t·S_{t-1} + k_t v_tᵀ` is
online gradient descent on a stated objective over an associative memory
(Table 7): vanilla linear attention descends `−⟨Sᵀk_t, v_t⟩`; the delta
rule descends the reconstruction loss `½‖Sᵀk_t − v_t‖²`; gating is weight
decay on the fast weights. The objective is the denotation of the update
rule — the Elliott-shaped statement ("solve for the implementation from
the meaning") that softmax attention never had.

### 3. In this repository's terms

The linear class exactly inhabits `StateAlgebra`: the state is one dk×dv
matrix per head — a type that does not mention the prefix length — and the
transition is `step`. Softmax attention admits no such bounded state; its
honest `StateAlgebra` state is the bounded context window itself, which is
why the current generation path recomputes and why the proved KV-cache law
had no instance.

## What Is Now Proved (safe Agda, no postulates)

`FormalTransformer/Attention/Linear.agda`, over an abstract `Semiring`
(so the theorems hold for ℝ-intended carriers, tropical weights, or parse
counts alike), with `gate`, `key`, `val` as per-token data:

- `stepGLA t S i j = gate t i * S i j + key t i * val t j` — the GLA
  transition. Diagonal gating keeps every transition product diagonal,
  which is why only scalar semiring algebra is needed.
- **`recurrent≡parallel`**: `runGLA S ts i j ≡ closedGLA S ts i j` — the
  token-by-token recurrence and the parallel closed form
  `(∏ gates)·S + Σ_j (∏ gates after j)·k_j v_jᵀ` are the same function,
  pointwise. This is the semantic license for executing attention in
  parallel over a window.
- **`runGLA-++`** and **`chunk-closed`**: running a concatenation is
  running the chunks in order, and a chunk acts on the carried state
  through its own gate product and contribution only — the chunkwise
  recurrence (Kimi Linear's Appendix B, here as a checked theorem). This
  is the form tensor-core kernels implement.
- `contrib-sum`: the Σ is literal (`listSum` over token/suffix pairs).
- `Packaged`/`Machine`: the GLA machine as a `StateAlgebra` whose `State`
  is `Lift a Matrix` — fixed dk×dv, independent of prefix length; the
  generic `run` is the GLA recurrence refl per step.

`FormalTransformer/Attention/LinearTrie.agda`:

- **`cache-run`**: `advanceT (glaCache S) ts ≡ glaCache (runGLA S ts)` —
  the observation trie of the GLA machine steps incrementally to exactly
  the whole-prefix result. This is the first concrete discharge of
  PROOF-STATUS's KV-cache obligation: a denotational cache with a fixed
  finite state, obtained by composing two already-proved laws.

Explicitly not proved (recorded in PROOF-STATUS): the delta rule and any
non-diagonal (DPLR) transition need a Ring (subtraction) and
matrix-product algebra — staged as future work; softmax attention has no
bounded-state presentation, which is a fact about softmax, not a gap in
the proofs.

## What The Semantics Licenses In The Model

Decisions taken (2026-07-18): update rule staged — **GLA now** (its laws
are theorems above), **delta rule/KDA second** (after the Ring-level
algebra); composition **hybrid 3:1** — three GLA layers per softmax
layer, the ratio Kimi Linear ablated best, retaining softmax's exact
retrieval where the finite state cannot. Positional encoding follows the
semantics: the GLA gates carry position (data-dependent transitions);
softmax layers drop RoPE (NoPE), per the classification in §1.

The hybrid's honest state is the product: one dk×dv matrix per GLA head
× the bounded window for the softmax layers. Generation can therefore
step GLA layers with O(1) state per token (`cache-run` executed) and
recompute only the 1-in-4 softmax layers over the window.

### The incremental decoder (implemented)

`decode_step` (backend/futhark/model.fut, exposed by both entry programs)
feeds one token through the stack with explicit state: each GLA layer
advances its fixed [d][hd] matrix by `stepGLA`, and each softmax layer
appends to a ring-buffer KV cache of the trailing `context` positions —
NoPE means the scores are permutation-invariant in the cache, so the ring
needs no reindexing. The conformance oracle checks that feeding a sequence
token-by-token reproduces every row of the batch forward (observed
max_abs ≈ 6e-9 on the mixed 5-layer config): the proved `cache-run` law,
numerically.

Beyond the first window the decoder makes the extension choice the
semantics recommends: the GLA state is never reset — generation *is* the
`StateAlgebra` run — while softmax layers attend over the trailing window.
Training only ever sees windows started from state zero, so all
interpretations beyond one window are extrapolations; this one is the
denotationally natural extension and costs O(model) per token instead of
the previous O(window · model) full recomputation.

Compute shape: per window of length n, GLA costs O(n·d) per head where
masked softmax costs O(n²·hd) — and the measured superlinear grad axis in
`backend/futhark/bench.fut` was precisely the context axis.

## The Chunkwise Execution (implemented)

`gla_attention_chunked` (backend/futhark/model.fut) executes the training
forward in the chunkwise form licensed by `chunk-closed` — applied at TWO
levels. Within a chunk of length C, the token-level parallel closed form;
across chunks, the same theorem one level up: training windows start from
S₀ = 0, so the state carried into chunk k is
`S_before[k] = Σ_{k'<k} exp(cumdec[k−1]−cumdec[k']) ⊙ T[k']`, a masked
reduction over the (few) chunks rather than a differentiated sequential
loop — keeping the code inside the vjp-safe idioms this file's comments
document. Every decay factor is `exp` of a later-minus-earlier difference
of non-increasing prefix sums, so every exponent is ≤ 0; the K/Γ division
of the textbook GEMM form is never materialized.

The chunk length is an execution schedule, invisible in the denotation:
the conformance oracle checks chunked ≡ quadratic logits at 1e-5 (observed
~7e-9) and runs every gradient comparison at chunk 2 over 4-token windows,
exercising the cross-chunk carry; `tests.fut` checks equivalence at chunk
sizes 1, 2, 3, and 6. Host knob: `GEMM_CHUNK` (default 64, whole window
when it does not divide). Measured (multicore): the context-axis gradient
point (n=256) fell from 119.7 ms to 68.7 ms; the bpe-scale point ~8% —
attention's FLOP share at that shape; single-chunk shapes pay a few
percent of machinery overhead.

The forms `T`, `S_before`, and the inter term are matrix contractions per
(chunk, head): the shapes a BLAS/tensor-core backend consumes directly.

## Backend Roadmap (staged)

Stage B (in progress): a decomposed training step — matmuls through a
BLAS boundary (openblas locally, cuBLAS on rental hardware), the
nonlinear/elementwise pieces as per-piece Futhark entries with generated
vjps, backward host-composed by the proved pullback laws, all
conformance-gated locally against Numeric.AD and the fused sequential
oracle. Stage C (rental): cuBLAS FP32 under pedantic math first (same
numeric class), then TF32/BF16 as a NEW numeric interpretation recorded in
the checkpoint manifest (as `clipNorm` is) with stated looser tolerances.
