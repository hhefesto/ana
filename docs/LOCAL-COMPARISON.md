# Comparison With Local Language-Model Implementations

This document compares four local artifacts by following the type history of
`docs/TYPE-HISTORY.md`: at each stage of the path from language meaning to a
GPU update, it quotes the corresponding types and contrasts them.

The compared artifacts are:

- `formalTransformer` (this repository) — the canonical bias-free decoder;
  a transformer.
- `~/src/modArTransformer`, **Wikipedia lineage only** — the `wiki-nano`,
  `wiki-small`, and `wiki-base` CPU models and the GPU "Elliott-LLM"
  `pilot`/`main` presets; a transformer family. Its modular-arithmetic,
  market, Dyck, and synthetic-language variants are out of scope here.
- `~/src/conal-elliott/paper-2021-language-derivatives` — Elliott's ICFP 2021
  Agda formalization of language derivatives plus a weighted (semiring)
  extension; a language formalization, not a transformer.
- `~/src/conal-elliott/weighted-derivatives` — Haskell and Bend weighted
  language models, including `WikiBigram.hs`, a byte bigram trained on
  Wikipedia; automaton-class language models, not transformers.

The last two are included because both transformer repositories present
themselves as implementations of exactly the semantics those projects
formalize: an autoregressive model is a weighted language given by its
Brzozowski-style observations.

## Executive Summary

`formalTransformer` is the semantic and conformance baseline. It starts with
an extensional weighted language, derives an autoregressive state
presentation, keeps language residuals separate from parameter derivatives,
and relates one canonical decoder to Haskell and Futhark implementations. It
now also carries the coinductive trie presentation, the gradient-accumulation
linearity theorem, a size-typed Futhark parameter interface, micro-batched
training, and an exact-counts bigram gate — each ported from ideas proven
useful in the other repositories (see "What This Repository Adopted").

`modArTransformer`'s Wikipedia lineage is the empirically strongest local
transformer effort: a categorical-AD Agda specification with a mature Wengert
tape CPU backend and a generalized multi-layer/multi-head Futhark GPU model,
trained to measured perplexities on real Wikipedia data. Its breadth costs
semantic drift: the strongest Agda oracle covers smaller fixed shapes than the
GPU model that actually trains.

`conal-elliott/paper-2021-language-derivatives` is the most rigorous artifact
of the four at what it does: the parser type is indexed by its own semantic
denotation, so correctness needs no separate theorem.

`conal-elliott/weighted-derivatives` demonstrates the semiring thesis in
running code — parsing and backpropagation are one ν/δ program instantiated at
different semirings — and its `WikiBigram` is the ancestor of the "bigram
gate" discipline both transformer repositories now use.

## The Type History, Compared

Stage numbers follow `docs/TYPE-HISTORY.md`.

### 1–2. What A Language Is, And Its Observations

`formalTransformer` is extensional:

```agda
Language A W = List A → W

nu L = L []
delta L a = λ v → L (a ∷ v)
```

The laws (`residual-append`, determination by `nu` and `delta`) are
propositional theorems about a function type.

Elliott's `paper-2021-language-derivatives` inverts the situation. The
Automatic representation is a coinductive trie whose *fields* are the
observations, and the type is indexed by the semantic language it denotes
(`Automatic.lagda`):

```agda
record Lang (P : ◇.Lang) : Set (suc ℓ) where
  coinductive
  field
    ν : Dec (◇.ν P)
    δ : (a : A) → Lang (◇.δ P a)
```

A `Lang P` cannot exist unless it decides exactly `P`; correctness is in the
index, and the ν/δ laws hold definitionally. The `Symbolic.lagda` dual is an
inductive syntax with a transport constructor `_◂_ : (Q ⟷ P) → Lang P →
Lang Q`. The added `Weighted.lagda` generalizes decidability to any
commutative semiring: `WLang = List A → W`, which is exactly
`formalTransformer`'s `Language`.

`modArTransformer` uses the unindexed coinductive form, valued in Bradley's
interval (`Semantics/NuDelta.agda`):

```agda
record LM (V : Set) : Set where
  coinductive
  field ν : I
        δ : V → LM V
```

`formalTransformer` now holds both presentations and the proof that they
agree: `FormalTransformer/Language/Trie.agda` defines the coinductive
`Trie A W` (fields `nuT`, `deltaT`), maps `toLanguage`/`fromLanguage`, a
round trip that is propositional in one direction and a bisimulation in the
other, and soundness/completeness showing bisimulation coincides with
extensional equality. The three points of the design space are therefore:
extensional function (theorems propositional), indexed trie (theorems
definitional, index required up front), bare trie (theorems definitional per
step, equality weakens to bisimulation).

### 3. Finite Presentation By State

`formalTransformer`:

```agda
record StateAlgebra (A : Set) (W : Set) where
  field
    State : Set
    out   : State → W
    step  : State → A → W × State
```

`step` emits the transition weight together with the successor. Path
factorization is proved once for every instance.

`modArTransformer`'s `StateAlgebra` (init/step/out) has a weightless `step`;
weights live in the `LM` trie that `run : S → LM V` produces. Its
`NuDeltaLaws.agda` proves `run (stepAll s u) ≡ 𝒟 (run s) u` definitionally —
the statement that a KV cache means whole-prefix evaluation.

That law now exists here as well, adapted to the weighted `step`:
`FormalTransformer/Language/AutoregressiveTrie.agda` defines the observation
trie (the denotational KV cache) with `observation-run` proved refl per step,
and a weighted trie carrying the path-weight accumulator, whose denotation is
proved equal to the existing `unnormalized` language and whose run
homomorphism agrees with `residual-continuation`.

`weighted-derivatives/WikiBigram.hs` is the minimal nontrivial instance of
the same shape: the state is the previous byte. That minimality is what makes
it a useful gate — it is the best model expressible with one token of state.

### 4. Normalization Evidence

`formalTransformer`'s `Distribution` carries `total-mass ≡ 1#` as a field;
`modArTransformer`'s `Dist` record likewise makes properness a field, so an
improper distribution does not typecheck. The bigram models need no such
evidence type: their rows are exact counts normalized arithmetically, which
is why an exact-counts baseline is trustworthy without a proof layer.

### 5. Bradley's Enrichment

`formalTransformer` proves identity and aligned-prefix composition for
bounded `PrefixObject`/`Prefix` chains and implements magnitude and entropy
metrics in Haskell. `modArTransformer` has the larger Bradley development
(`Semantics/{Copresheaf,Enriched,Interval,Magnitude}.agda`) and uses it for
meaning probes. The synthesis sentence is in
`conal-elliott/NOTES-bradley-vs-elliott.md`: *a transformer is Bradley's
object presented in Elliott's Automatic representation* — which is precisely
the pair of modules this repository now has (Bradley.agda + Trie.agda).

### 6. Reverse AD

The two transformer repositories independently encode the same construction
from Elliott's "The Simple Essence of Automatic Differentiation".

`formalTransformer` (`AD/Reverse.agda`):

```agda
Dual A B = AdditiveMap B A
D A B = Carrier A → Carrier B × Dual A B
```

`modArTransformer` (`Cat/Dual.agda`, `Cat/D.agda`):

```agda
record Dual (A B : Set) : Set where
  field unDual : AddFun B A
record D (A B : Set) : Set where
  field runD : A → B × Dual A B
```

The difference is style, not substance: modArTransformer is point-free
(layers are composites of `_∘D_`, `_▵D_`, `exlD`), formalTransformer states
the identity/composition/pairing laws as named propositional theorems and
confines analytic facts to `TrustedAnalytic` fields.

`weighted-derivatives/RAD.hs` closes the circle: reverse AD is a closed
semiring, so Brzozowski differentiation by a token and backpropagation by a
parameter are the same program at different semirings. Its Bend port shows
the classical Wengert "tape" is literally defunctionalized `Cont`/`Dual`.

`formalTransformer` now also has the micro-batch consequence of linearity as
a theorem (`AD/Batch.agda`): `batch-pullback` states that the pullback of a
summed loss is the sum of per-microbatch pullbacks of one shared cotangent —
the semantic license for gradient accumulation, distinct from `pairing-chain`
where two different cotangents flow back from a pair.

### 7–8. Shape Evidence And Tensors

`formalTransformer` keeps dimensions in a record with proof fields
(`model ≡ heads * headDim`, `2 ∣ headDim`) and abstracts tensors as
signatures `Tensor : List ℕ → Set`. `modArTransformer` keeps dimensions in
the type indices themselves:

```agda
ℝMat m n = Vec (ℝVec n) m

SeqTransformerParams p n dM dF dK =
  ℝMat (suc p) dM × ℝMat n dM × SeqBlockParams dM dF dK × LinParams (suc p) dM
```

with type-level arithmetic in the shapes (Wo takes `dK + dK` columns; vocab
is `suc p`, hence never zero), mirrored in Haskell by
`DataKinds`/`KnownNat` phantom types (`Transformer.hs`'s `ParamsSeq`). The
trade: index-level dims make mis-shaped *construction* impossible but fix
shapes at compile time; proof-bearing records keep runtime-chosen shapes and
demand the proofs explicitly.

### 9. The Flat Layout

Both transformer repositories interpret structured parameters as one
row-major f32 vector, and both now state the layout arithmetic in the
Futhark interface type rather than a comment:

```futhark
-- formalTransformer (ported this session, following modArTransformer):
entry batch_loss_grad [batch] [sequence]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: [parameter_count v d f n_layers]f32)
    (tokens: [batch][sequence]i64)
    : (f32, [parameter_count v d f n_layers]f32)
```

A mis-laid-out vector is rejected at the boundary. `formalTransformer`
additionally versions the layout (`canonical-decoder-flat-parameters`, v1)
and records per-leaf `Slice` metadata with the AdamW decay decision;
`modArTransformer` fixes leaf order through its `Cat/Serialize.agda`
instances shared by Agda, Haskell, and Futhark.

### 10–11. Executable AD, Three Ways

`formalTransformer` uses one polymorphic Haskell term for both `Double`
inference and Numeric.AD reverse differentiation, and `vjp2` in Futhark; no
model-wide backward pass exists anywhere. `modArTransformer` holds the same
"derived-only gradients" line across three runtimes — Agda chain rule,
Haskell Wengert tape, Futhark `vjp` — and its `WIKI-LLM-STATUS.md` records a
valuable negative result: compiling the network with ConCat's `toCcc` blows
up super-linearly at NN scale (minutes and gigabytes for a 3-token
softmax-CE), while the runtime tape sequences the identical adjoints with
sharing (~27× faster than naive continuation form). The lesson: derive
gradients semantically, but *execute* them through a representation with
sharing (`vjp2` here plays that role).

`modArTransformer` also measured a matmul-shaped rewrite of its forward pass
worth 1.8× wall-clock at same-seed-identical loss — evidence that
semantics-preserving performance work pays; this repository has not yet
needed it at its current scale.

### 12. Artifacts And Run Identity

`formalTransformer` checkpoints model dimensions, parameter count, layout
identity and version, optimizer schedule, model/tokenizer/dataset
identities, PRNG state, both moments, step, and best validation loss;
`STEPS` is a target completed step and resume validates everything.
`modArTransformer`'s FCKPT stores θ, Adam moments, and step with atomic
writes and `.best` tracking, and its tokenizer artifact travels with the
checkpoint family, but it lacks dataset identity, PRNG state, and schedule
binding. The conal-elliott projects have no artifact layer.

The training-relevant tokenizers also differ: `formalTransformer`'s total
byte tokenizer (BOS 0, EOS 1, bytes 2..257) versus `modArTransformer`'s
FastBPE (word-pretokenized incremental BPE, 8192 vocab, trained in ~50 s on
10 MB; Word16 token files at ~3.82 bytes/token). FastBPE is the strongest
not-yet-ported capability; see the roadmap below.

### 13. Architecture And Measured Results

The canonical decoders differ block by block:

| Component | formalTransformer | modArTransformer (wiki) |
|---|---|---|
| Positions | RoPE (no parameters) | learned absolute table |
| Norm | pre-RMSNorm (gain only) | post-LayerNorm (γ, β, ε=1e-5) |
| Projections | bias-free Wq/Wk/Wv/Wo | affine with biases |
| Feed-forward | SwiGLU | ReLU |
| Unembedding | tied to embedding | separate affine |
| Parameter count | `v·d + L·(4d² + 3fd + 2d) + d` | larger per width (biases, positions, separate unembedding) |

modArTransformer Wikipedia measurements (from `ELLIOTT-LLM.md` and
`WIKI-LLM-STATUS.md`; unigram baseline 5.45 nats / ppl 217):

- CPU `wiki-nano` (~47k params): val CE 5.18 nats, ppl 179.
- CPU `wiki-small` (~120k): 4.76 nats, ppl 116.
- Exact-counts BPE bigram gate: **4.0673 nats, ppl 58.4 — beating both CPU
  transformers**, the observation that created the gate discipline.
- GPU `pilot` (~2.5M, v8192 n128 dM128 dF512 dK32 L2 H4, 200 MB corpus):
  crossed its bigram gate at step 400; val 5.2437 nats / ppl 189.4 at step
  5400. Grammatical wiki-register prose, heavy proper-noun hallucination.
- GPU `main` (~7.43M, v8192 n256 dM256 dF1024 dK64 L4 H4, 1 GB corpus,
  bigram gate 6.6450): val ≈ 4.70 at step 3000 — a mid-run snapshot dated
  2026-07-09, not a completed run.

formalTransformer's current presets are 7.5K (`tiny`) and 123K (`small`)
parameters; the sequential-C backend has completed 1,000 real updates of the
123,328-parameter model with exact checkpoints (`docs/RUN-2026-07-10.md`).
The scales are not yet comparable; the contracts are the point.

## Comparison Table

| Area | formalTransformer | modArTransformer (wiki) | paper-2021-language-derivatives | weighted-derivatives |
|---|---|---|---|---|
| Kind | transformer | transformer family | language formalization | bigram/automaton LMs |
| Language type | `List A → W` + coinductive `Trie A W` | coinductive `LM V` (ν : I) | `Lang P` indexed by denotation | `WLang`, semiring engine |
| ν/δ laws | propositional + refl-per-step trie | definitional per step | definitional, indexed | by construction (Haskell) |
| State presentation | `StateAlgebra` with weighted step; observation/weighted tries | `StateAlgebra` + `run : S → LM V` | n/a | previous-token state |
| Reverse AD | `D A B = A → B × Dual A B`, named laws, `AD/Batch` linearity | `D (Dual AddFun)`, point-free | n/a | AD as closed semiring |
| Shape discipline | proof-bearing `Config` + abstract `Tensor` | index-level dims, `Vec`/`KnownNat` | index = denotation | none needed |
| Flat layout | versioned identity + `Slice` + size-typed Futhark entries | `Cat/Serialize` leaf order + size-typed entries | n/a | n/a |
| Backends | Haskell Double / Futhark vjp2 (sequential C + OpenCL) | hmatrix tape / Futhark vjp (OpenCL) | Agda only | Haskell, Bend/HVM2 |
| Conformance | every tiny-model logit/loss/gradient/AdamW entry + micro-batch + size rejection | Agda↔Haskell ~1e-16; GPU grad-cosine 1.0 at small shapes | intrinsic | demos |
| Artifact identity | full manifest + PRNG + schedule | FCKPT (θ, m, v, step) + .best | none | none |
| Tokenizer | total byte (258) | FastBPE 8192 | n/a | raw bytes |
| Baseline gate | exact-counts bigram (ported) | exact-counts bigram | n/a | WikiBigram (origin) |
| Wikipedia results | not yet at scale | ppl 189 (pilot), ≈4.70 nats mid-run (main) | n/a | byte-bigram baseline |

## What This Repository Adopted (And Why)

Selection criterion: only ideas with a clear denotational justification.

1. **Coinductive ν/δ trie + run homomorphism**
   (`Language/Trie.agda`, `Language/AutoregressiveTrie.agda`). Elliott's
   Automatic representation; the observation trie is the denotational KV
   cache, and `observation-run` is the abstract statement that incremental
   decoding equals whole-prefix evaluation, proved refl per step for every
   `StateAlgebra`.
2. **Gradient-accumulation linearity** (`AD/Batch.agda`). `batch-pullback`
   proves D(Σfᵢ) = ΣDfᵢ at the level of pullbacks; `addD` factors through
   the already-proved `pairD`/`plusD`, so it is a consequence, not a new
   assumption.
3. **Size-typed Futhark parameter entries** (`backend/futhark/kernels.fut`).
   The layout formula `parameter_count v d f n_layers` moved from a runtime
   assert into the entry interface types; the conformance oracle now checks
   that a mis-sized vector is rejected. The formula is enforced in four
   aligned places: the Agda count theorem, Haskell `paramCount`, the layout
   slices, and the Futhark types.
4. **Micro-batch gradient accumulation** (`micro_batch_loss_grad`,
   `MICRO_BATCH` in the GPU host). Each chunk's adjoints are seeded with
   1/effective-batch inside the kernel, so accumulated chunks equal the
   full-batch gradient up to f32 summation order (measured max_abs ≈ 1.5e-8
   on the tiny model; loss bitwise equal). One AdamW step per effective
   batch; checkpoint semantics unchanged. This is also the watchdog-safe
   launch shape for the display-attached RX 580 (`docs/RUN-2026-07-10.md`).
5. **Exact-counts bigram gate** (`FormalTransformer/Bigram.hs`,
   `bigram-gate` CLI, trainer startup print). A bigram is the minimal finite
   `StateAlgebra`; its add-1-smoothed exact fit on the trainer's own
   training documents, evaluated on the trainer's own validation windows
   (the split logic is now shared in `Data.hs` by construction), is the
   honest floor a transformer must beat. modArTransformer's CPU models lost
   to theirs; that is the kind of fact one wants surfaced automatically.

Roadmap (measured elsewhere, not yet ported):

- **FastBPE tokenizer** as a second tokenizer identity carried through
  `CorpusArtifact` and checkpoints (modArTransformer: 8192 vocab, Word16
  token files). Denotationally neutral but a large artifact-identity change.
- **Matmul-shaped forward rewrite** (measured 1.8× there) once profile
  evidence justifies it at this repository's scales.
- **ConCat lesson** as a standing constraint: derive gradients semantically,
  execute them through representations with sharing; do not compile the
  category naively.

## Practical Recommendation

Unchanged in spirit: use `formalTransformer` to define what the model,
language, derivative, optimizer, and artifacts mean; use
`modArTransformer`'s Wikipedia lineage as evidence and a source of measured
techniques; use the conal-elliott projects as the semantic ground truth both
transformer efforts answer to. Port one measured capability at a time and
require it to preserve the existing parameter, corpus, checkpoint, and
conformance contracts — as was done for the five adoptions above.
