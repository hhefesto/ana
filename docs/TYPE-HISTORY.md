# Type History

This document follows the types from the mathematical meaning of language to a
running GPU update. The order matters: execution is an interpretation of the
specification, not the source of it.

## 1. Extensional Language

The first type contains no neural-network machinery:

```agda
Language : Set a → Set w → Set (a ⊔ w)
Language A W = List A → W
```

`A` is an alphabet and `W` is a space of observations. Instantiating `W`
changes the kind of language without changing its domain:

- `Bool` gives recognition.
- `ℕ` gives parse counts.
- Nonnegative weights give weighted or probabilistic languages.
- Tropical weights give costs.

The type says what a language means: it assigns an observation to every finite
word.

## 2. Elliott's Prefix Observations

Any `Language A W` has three canonical observations:

```agda
nu       : Language A W → W
residual : Language A W → List A → Language A W
delta    : Language A W → A → Language A W
```

Their definitions are:

```text
nu L          = L []
residual L u  = λ v → L (u ++ v)
delta L a     = residual L [a]
```

The key equations are proved in `Language/Weighted.agda`:

```text
residual L [] = L

residual (residual L u) v
  = residual L (u ++ v)

L w = nu (foldl delta L w)
```

This derivative is discrete residualization by a token. It is not a derivative
with respect to a real-valued parameter.

## 3. A Finite Presentation Of Language

An executable autoregressive model presents the extensional language through a
state:

```agda
record StateAlgebra (A : Set) (W : Set) where
  field
    State : Set
    out   : State → W
    step  : State → A → W × State
```

The dependent field `State` hides the implementation's representation. A state
could be a complete prefix, an automaton state, or eventually a transformer KV
cache.

`step q a` returns a product:

```text
conditional weight of a × successor state
```

Folding `step` induces:

```agda
run        : State → List A → State
pathWeight : State → List A → W
```

and Agda proves autoregressive factorization:

```text
pathWeight q (u ++ v)
  = pathWeight q u * pathWeight (run q u) v
```

This is the semantic law that incremental inference must preserve.

## 4. Normalization As Evidence

The stronger output type is a finite distribution:

```agda
record Distribution
  (R : Semiring)
  (vocabulary : List A) where
  field
    terminalWeight : Carrier
    tokenWeight    : A → Carrier
    total-mass     :
      terminalWeight
      + listSum (map tokenWeight vocabulary)
      ≡ 1#
```

A value of this type includes its mass equation. `ProperStateAlgebra` connects
the distribution's `tokenWeight` to the weight returned by `step`.

The present record does not encode non-negativity or vocabulary uniqueness;
those are listed explicitly as future refinements rather than silently assumed.

## 5. Bradley's Prefix Objects

The syntax category uses bounded prefixes as objects:

```agda
record PrefixObject (A : Set) (cutoff : ℕ) where
  field
    tokens        : List A
    within-cutoff : length tokens ≤ cutoff
    terminal      : Bool
```

A morphism requires right-extension evidence:

```agda
record Prefix (xs ys : List A) where
  field
    extension : List A
    extends   : ys ≡ xs ++ extension
```

The hom-value is the conditional path weight of `extension`. Agda proves
identity and composition only for aligned prefix chains:

```text
L(x,x) = 1
L(x,z) = L(x,y) * L(y,z)
```

No arbitrary-substring equality is claimed. Mapping probability through
`-log` gives directed surprisal, where aligned composition becomes addition.

The Haskell metric layer implements Bradley's finite-tree formula:

```text
Mag_t = terminalCount + (t - 1) * Σ_x H_t(p_x)
Mag'(1) = Σ_x ShannonEntropy(p_x)
```

## 6. Numeric Differentiation Has Another Type

Training differentiates a scalar loss with respect to parameters. The reverse
derivative type is:

```agda
Dual A B = AdditiveMap B A

D A B = Carrier A → Carrier B × Dual A B
```

Equivalently:

```text
D A B = A → B × (B →+ A)
```

The function returns a primal value and a pullback. Composition sends primal
values forward and cotangents backward:

```text
A → B → C
C →+ B →+ A
```

Agda proves identity, composition, pairing, and pullback accumulation. Analytic
facts for exponential and reciprocal square root are fields of
`TrustedAnalytic`; they are visible assumptions, not global postulates.

## 7. Shape Evidence In Configuration

The formal model configuration carries dimensions and their constraints:

```agda
record Config where
  field
    vocab context model ff heads layers headDim : ℕ
    vocab-at-least-three : 3 ≤ vocab
    context-at-least-two : 2 ≤ context
    model-positive       : 0 < model
    ff-positive          : 0 < ff
    heads-positive       : 0 < heads
    layers-positive      : 0 < layers
    model-head-shape     : model ≡ heads * headDim
    headDim-even         : 2 ∣ headDim
```

The last two fields make head splitting and RoPE pairs legal by construction.

Haskell uses the erased runtime counterpart:

```haskell
data Config = Config
  { vocabSize   :: Int
  , contextSize :: Int
  , modelDim    :: Int
  , ffDim       :: Int
  , layerCount  :: Int
  , headCount   :: Int
  }
```

`validateConfig` dynamically checks the propositions that Agda stores as proof
fields.

## 8. Shape-Indexed Tensor Vocabulary

The transformer specification abstracts over a tensor family:

```agda
Tensor : List ℕ → Set
```

Examples include:

```text
Tensor [d]       hidden vector
Tensor [v,d]     token embedding
Tensor [n,d]     sequence of hidden vectors
Tensor [d,d]     attention projection
Tensor [f,d]     feed-forward expansion
```

One layer has typed query, key, value, output, gate, up, down, and RMS gain
fields. A model contains:

```agda
tokenEmbedding : Tensor [vocab, model]
blocks         : Vec LayerParameters layers
finalNorm      : Tensor [model]
```

`Vec ... layers` makes the number of blocks part of the type. The embedding is
also the unembedding matrix, so it is counted only once.

## 9. The Canonical Flat Interpretation

The Haskell and Futhark implementations interpret the structured parameters as
one row-major vector:

```text
embedding [v,d]
for each block:
  rms_att [d]
  Wq, Wk, Wv, Wo [d,d]
  rms_ff [d]
  Wgate, Wup [f,d]
  Wdown [d,f]
final_rms [d]
```

Its length is:

```text
v*d + layers*(4*d*d + 3*f*d + 2*d) + d
```

Haskell's `Slice` records the name, offset, length, and AdamW decay decision for
each leaf. The layout identity and version are checkpointed.

## 10. One Haskell Term, Multiple Scalars

The reference model is polymorphic:

```haskell
fullSequenceLogitsGeneric
  :: (Floating a, Ord a)
  => Config
  -> [a]
  -> [Int]
  -> Either String [[a]]
```

With `a ~ Double`, this is ordinary reference inference. With Numeric.AD's
reverse scalar, the same term computes pullbacks. There is no separately
maintained model-wide backward pass.

## 11. Futhark Makes Batch And Parameter Shapes Visible

The GPU training entry has the array type:

```futhark
batch_loss_grad
  (params : [p]f32)
  (tokens : [batch][sequence]i64)
  : (f32, [p]f32)
```

The scalar result is mean next-token cross-entropy. The gradient has exactly the
same flat shape as the parameters. Internally:

```futhark
vjp2 loss params 1f32
```

constructs the reverse derivative from the forward loss.

AdamW consumes five equally sized arrays:

```text
parameters[p]
gradient[p]
firstMoment[p]
secondMoment[p]
decayMask[p]
```

and returns updated parameters and moments. The OpenCL host keeps these arrays
device-resident across steps.

## 12. Artifact Types Preserve Run Identity

A corpus carries:

```haskell
data CorpusArtifact = CorpusArtifact
  { corpusVersion           :: Word32
  , corpusTokenizerIdentity :: String
  , corpusDatasetIdentity   :: String
  , corpusDocuments         :: [Document]
  }
```

A checkpoint carries:

```haskell
data Checkpoint = Checkpoint
  { checkpointManifest           :: Manifest
  , checkpointParameters         :: [Double]
  , checkpointOptimizer          :: AdamWState
  , checkpointBestValidationLoss :: Maybe Double
  , checkpointPRNG               :: PRNGState
  }
```

The manifest includes model dimensions, parameter count, layout identity,
optimizer schedule, and model/tokenizer/dataset identities. Loading rejects an
artifact from a different interpretation rather than hoping equal list lengths
mean equal models.

## 13. The Training Composite

The complete executable path can be read through its types:

```text
raw bytes
  → Document
  → CorpusArtifact
  → Split Document
  → [batch][sequence] token IDs
  → Parameters[p] → Scalar loss
  → Parameters[p] × Gradient[p]
  → AdamWState[p]
  → Checkpoint
```

The semantic path is parallel:

```text
Language A W
  ← StateAlgebra A W
  ← shape-indexed transformer
  ← flat Haskell/Futhark interpretation
```

The CPU conformance oracle checks the final implementation edge for layout,
logits, mean loss, every gradient entry, and one AdamW transition. This is a
numeric refinement test over `f32`; it is not presented as an exact theorem over
real numbers.

## 14. The Coinductive Trie Is The Same Language

Elliott's Automatic representation presents a weighted language by its two
canonical observations, taken as fields rather than derived functions:

```agda
record Trie (A : Set) (W : Set) where
  coinductive
  field
    nuT    : W
    deltaT : A → Trie A W
```

`toLanguage` and `fromLanguage` mediate between the trie and section 1's
extensional `Language A W`. One round trip is a pointwise propositional
theorem; the other is a bisimulation:

```agda
record _≈_ (s t : Trie A W) where
  coinductive
  field
    nu-≈    : nuT s ≡ nuT t
    delta-≈ : ∀ x → deltaT s x ≈ deltaT t x
```

Bisimulation is proved sound and complete for extensional equality, so
nothing is lost by the weaker notion; it is the honest equality for
coinductive values under `--safe`.

The payoff is the state algebra. For every `StateAlgebra` of section 3, the
observation trie

```agda
nuT    (observationTrie q)   = out q
deltaT (observationTrie q) x = observationTrie (proj₂ (step q x))
```

is the denotational KV cache: the entire observable future of a state. Its
law

```text
advanceT (observationTrie q) xs ≡ observationTrie (run q xs)
```

— incremental stepping equals whole-prefix evaluation — is proved refl per
step. A weighted variant threads the consumed path weight as an accumulator
(keeping every corecursive call guarded) and provably denotes section 3's
`unnormalized` language, agreeing with the residual-continuation law.

## 15. Gradient Accumulation Is Additivity Of Pullbacks

Section 6's `pairD` accumulates two different cotangents flowing back from a
pair of outputs. Micro-batched training needs a different statement: one
shared cotangent flowing back through a sum of losses.

```agda
addD f g x = (f₁ x + g₁ x , f* +M g*)

batchD : List (D A B) → D A B
```

`addD` is not a new assumption — it factors through the proved `pairD` and
the reverse derivative of addition, whose pullback is the diagonal. The
micro-batch theorem is

```text
apply (proj₂ (batchD fs x)) db
  ≡ listSum (map (λ f → apply (proj₂ (f x)) db) fs)
```

the gradient of a summed loss is the sum of per-microbatch gradients of the
same cotangent. The mean version composes with a scaling supplied as a
self-dual additive map (true of multiplication by 1/n; supplied, not
proved). This theorem is the semantic license for the GPU host's
`MICRO_BATCH` gradient accumulation: chunked accumulation may differ from a
full-batch gradient only by f32 summation order, which the conformance
oracle checks on the tiny model.
