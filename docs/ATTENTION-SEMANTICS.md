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

Compute shape: per window of length n, GLA costs O(n·d) per head where
masked softmax costs O(n²·hd) — and the measured superlinear grad axis in
`backend/futhark/bench.fut` was precisely the context axis.

## Backend Roadmap (deferred, conditional)

The chunkwise theorem (`chunk-closed`) is GEMM-shaped: per-chunk products
of gate-scaled query/key blocks against the carried state. If and when a
backend change is made for tensor cores, it must implement exactly that
form; candidates are cuBLAS/CUTLASS at the FFI boundary or a generated
kernel route. Mixed precision (f16/bf16/tf32) is a change of numeric
interpretation, to be recorded in the checkpoint manifest (as `clipNorm`
is) and gated by the conformance oracle at stated tolerances. No backend
work is licensed until the GLA hybrid model itself is landed and measured.
