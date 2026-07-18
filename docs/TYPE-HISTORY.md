# Type History

This document follows the types from the mathematical meaning of language to a
running GPU update. The order matters: execution is an interpretation of the
specification, not the source of it.

It is current through the FastBPE `bpe10m` model, global segmented Wikipedia
schedule, compact artifacts, generated CUDA backend, and streaming sampled
generation used by the live July 2026 run.

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

## 11. Futhark Makes The Production Pullback Shape Visible

The full Futhark program still exposes `batch_loss_grad` and `loss_grad` to the
sequential conformance oracle. The reduced OpenCL/CUDA production program has a
single differentiated entry instead:

```futhark
entry micro_batch_loss_grad [batch] [sequence]
    (v d f h n_layers : i64)
    (effective_batch : i64)
    (accumulator : [parameter_count v d f n_layers]f32)
    (params      : [parameter_count v d f n_layers]f32)
    (tokens      : [batch][sequence]i64)
    : (f32, [parameter_count v d f n_layers]f32)
```

The parameter-count expression, rather than an unrelated existential `p`, is
part of the entry type. The returned gradient therefore has the canonical flat
model shape by construction. `effective_batch` records the denominator of the
objective, while `batch` is only the number of samples in this execution chunk.

The implementation follows section 15's additive-pullback law literally:

```futhark
loop (loss_sum, acc) = (0f32, accumulator) for b < batch do
  let (sample_loss, gradient) =
    vjp2 (next_token_loss ... tokens[b]) params
         (1f32 / f32.i64 effective_batch)
  in (loss_sum + sample_loss, map2 (+) acc gradient)
```

One `vjp2` is taken per sample. This matters operationally without changing the
denotation: a VJP around a batch-summed objective gave the GPU only the batch
axis as initial parallelism, while the per-sample VJP exposes the sequence,
model, and vocabulary axes inside each reverse sweep. Attention similarly
computes scores and softmax once per head rather than once per output component.

The Haskell side folds micro-batches into the same device accumulator:

```haskell
microLossGrad
  :: Context -> GpuConfig -> Int -> Int
  -> [[Int64]] -> F32Array
  -> IO (Float, F32Array)
```

Parameters, gradient accumulator, first moment, and second moment remain opaque
`F32Array` values on the device across the complete update. This statement is
backend-neutral: the same host boundary serves OpenCL and CUDA.

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

The manifest type now includes clipping as part of trajectory identity:

```haskell
data Manifest = Manifest
  { manifestVersion         :: Word32
  , manifestConfig          :: Config
  , manifestParameterCount  :: Int
  , manifestLayoutIdentity  :: String
  , manifestLayoutVersion   :: Word32
  , manifestOptimizerConfig :: AdamWConfig
  , manifestIdentity        :: Identity
  , manifestClipNorm        :: Double
  }
```

`Identity` is the product of model, tokenizer, and dataset interpretations. The
optimizer configuration includes the global schedule total, and `clipNorm` is
checked on resume because changing it changes every subsequent update. Loading
rejects an artifact from a different interpretation rather than hoping equal
list lengths mean equal models.

The in-memory scalar type is deliberately not the wire scalar type. Parameters
and both Adam moments are manipulated as `[Double]` by artifact code, but
checkpoint version 2 stores them as length-prefixed big-endian `f32` arrays.
Corpus tokens are `[Int]` in Haskell and big-endian `u16` on disk. Decoding
widens these compact values back into the host representations. Atomic
temporary-file-plus-rename publication ensures a checkpoint path never denotes
a partially written value.

## 13. The Training Composite

The current executable path can be read as one refinement chain:

```text
raw bytes
  → Tokenizer
  → [u16-representable ordinary token]
  → Document
  → CorpusArtifact
  → offset-stable Split Document
  → fixed [sequence] windows
  → TrainingMode / global segment sampler
  → [microbatch][sequence]i64
  → per-sample pullbacks accumulated in Gradient[p]f32
  → globally clipped Gradient[p]f32
  → AdamW(Parameters[p], FirstMoment[p], SecondMoment[p], DecayMask[p])
  → validation / bits-per-byte / bigram observations
  → compact-f32 Checkpoint
```

The semantic path is parallel:

```text
Language A W
  ← StateAlgebra A W
  ← shape-indexed transformer
  ← flat Haskell/Futhark interpretation
```

The CPU conformance oracle checks the common Futhark formulation for layout and
parameter count, logits, mean loss, every gradient entry, one AdamW transition,
micro-batch versus full-batch gradients, and parameter-size rejection. It runs
the full program through sequential C; it does not prove the CUDA compiler,
NVRTC, or NVIDIA driver correct. This is a numeric refinement test over `f32`,
not an exact theorem over real numbers.

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

## 16. A Token ID Requires An Interpretation

An `Int` is not yet a token. It becomes one only relative to a tokenizer whose
identity is stable across corpus preparation, training, checkpointing, and
generation:

```haskell
data Tokenizer
  = ByteTokenizer
  | FastBpeTokenizer FastBpe

data FastBpe = FastBpe
  { fastBpeVocabSize :: Int
  , fastBpeMerges    :: [((Int, Int), Int)]
  , fastBpeRanks     :: Map (Int, Int) Int
  , fastBpeIdentity  :: String
  }

encodeWith :: Tokenizer -> ByteString -> [Int]
decodeWith :: Tokenizer -> [Int] -> Either String ByteString
```

The BPE token algebra reserves:

```text
0       BOS
1       EOS
2..257  literal bytes
258..   merge results
```

Merge IDs are contiguous, and each merge may refer only to bytes or earlier
merges. Pretokenization is also part of the interpretation: LF is a boundary,
and an ASCII space is prefixed to the following word. The identity therefore
contains the vocabulary size, pretokenization rule, reserved ranges, and a
SHA-256 digest of the canonical merge table:

```text
fastbpe-word-v1:bos=0:eos=1:bytes=2..257:
pretoken=ascii-space-prefix+lf-boundary:
vocab=8192:sha256=<merge-table-digest>
```

Two files that happen to contain integers of the same range are not
interchangeable unless this identity agrees. `CorpusArtifact` stores it, the
checkpoint stores it through `Identity`, and generation reloads a tokenizer
whose computed identity must match.

The current rental-scale interpretation is:

```haskell
bpe10mPreset = Config
  { vocabSize   = 8192
  , contextSize = 256
  , modelDim    = 320
  , ffDim       = 864
  , layerCount  = 6
  , headCount   = 5
  }
```

It derives `headDim = 64` and the section 9 layout derives exactly 10,059,840
parameters. These numbers are checked, not merely used as allocation hints.

## 17. Documents Become Offset-Stable Windows

The corpus preserves document boundaries and identities before it becomes a
tensor:

```haskell
data Document = Document
  { documentId     :: String
  , documentTokens :: [Int]
  }

data Split a = Split
  { training   :: [a]
  , validation :: [a]
  }

trainingSequencesFrom
  :: Word64 -> Config -> [Document] -> Either String (Split [Int64])
```

The `Word64` argument is the document's global offset, not a local shard index.
The fixed split seed is mixed with this global position, so splitting the same
dataset into different transfer batches does not change whether a document is
training or validation data.

Each document is interpreted as:

```text
BOS : documentTokens ++ [EOS]
```

and then partitioned into non-overlapping, fixed-width windows. A training
window has the runtime type `[Int64]`, but its length is validated against
`contextSize`; the Futhark call upgrades a list of them to
`[batch][sequence]i64`. Documents too short to produce a full window are
omitted rather than padded with tokens that would alter the loss.

This is where "one epoch" acquires a precise meaning: consume every resulting
training window at least once under the deterministic epoch permutation.

## 18. A Shard Is An Interval In One Global Run

The trainer distinguishes standalone targets from intervals in a previously
defined global trajectory:

```haskell
data TargetSpec
  = ExplicitSteps Int
  | EpochSteps

data TrainingMode
  = Standalone TargetSpec
  | Segment Int Int Int Word64 String String
```

The six `Segment` fields denote:

```text
global total steps
segment start step
segment end step
global document offset
global dataset identity
expected shard corpus identity
```

Thus a shard is not a fresh optimization problem. It is the half-open interval
`[start,end)` of one schedule. The host validates:

```text
0 <= start < end <= globalTotal
end - start = ceil(shardTrainingWindows / TRAIN_BATCH)
actual shard identity = planned shard identity
```

The sampler type makes resume behavior explicit:

```haskell
type Sampler = Int -> PRNGState -> ([[Int64]], PRNGState)
```

For epoch sampling, the global step selects a deterministic cyclic slice of a
hash-ordered window vector. `segmentSampler` subtracts the segment start before
applying that local permutation. No hidden iterator position is needed in the
checkpoint.

Every segment receives the same `globalTotal` and global dataset identity, so:

```haskell
optimizerFor globalTotal :: AdamWConfig
```

denotes one warmup/cosine schedule. Parameters, both Adam moments, global step,
PRNG, and manifest pass through shard boundaries unchanged. The TSV plan is an
external serialization of these interval obligations; it is not the training
state itself.

## 19. One Update Is A Typed State Transition

After section 15 accumulates the effective-batch gradient, clipping and AdamW
form the state transition:

```futhark
entry clip_global_norm [p]
    (max_norm : f32)
    (gradient : [p]f32)
    : (f32, [p]f32)

entry adamw_step [p]
    (step : i64)
    (learning_rate beta1 beta2 epsilon weight_decay : f32)
    (params gradient first_moment second_moment : [p]f32)
    (decay_mask : [p]bool)
    : ([p]f32, [p]f32, [p]f32)
```

Conceptually, the host executes:

```text
StepState p
  = Parameters p
  x FirstMoment p
  x SecondMoment p
  x PRNGState
  x TrainingProgress

update
  : Batch
  -> StepState p
  -> IO (StepState p)
```

The gradient norm is observed before clipping. AdamW receives the clipped
gradient, applies bias correction, and applies decoupled weight decay only where
the section 9 `Slice` layout produced `decayMask = true`. One effective batch
causes one increment of `step`, regardless of `MICRO_BATCH`.

`manifestClipNorm` records the clipping interpretation. Resume rejects a
different value because clipping is not merely an execution strategy: it
changes the mathematical update.

## 20. Validation Values Observe But Do Not Drive The State

Training progress is kept separate from optimizer state:

```haskell
data TrainingProgress = TrainingProgress
  { progressTrainLossEma           :: Maybe Float
  , progressPreviousValidationLoss :: Maybe Float
  , progressBestValidationLoss     :: Maybe Double
  }
```

The selected validation windows feed three observations of the same held-out
examples:

```text
model cross-entropy        nats per target token
bits per byte              tokenizer-independent scale
bigram cross-entropy       non-neural baseline gate
```

Bits per byte changes units without changing the model:

```text
validationNats
  * predictionCount
  / (decodedOrdinaryTargetBytes * ln 2)
```

The bigram gate is built from exact training-document counts with add-one
smoothing. It can be skipped during cloud shard startup with
`SKIP_BIGRAM_GATE=1` because it is an observation of fixed data, not an input to
AdamW. Validation cadence and sample size are likewise observational controls.
The best validation value is checkpointed, but no gradient is computed from
validation data.

## 21. CUDA Is An Interpretation Generated From Futhark

The repository does not contain handwritten CUDA C++ kernels. The build applies
another interpretation to the section 11 Futhark program:

```text
backend/futhark/kernels-opencl.fut
  -- futhark cuda --library -->
kernels.c + kernels.h + kernels.json
```

The filename `kernels-opencl.fut` is historical: it is the reduced production
entry set shared by both OpenCL and CUDA. The generated C contains embedded
kernel source, allocation and launch code, and exported `futhark_entry_*`
functions.

Haskell sees only opaque generated values:

```haskell
newtype Context   = Context   (Ptr CContext)
newtype F32Array  = F32Array  (Ptr CF32_1d)
newtype I64Array  = I64Array  (Ptr CI64_1d)
newtype BoolArray = BoolArray (Ptr CBool_1d)
```

`FutharkKernels.hs` refines these pointers into operations such as
`microBatchLossGrad`, `clipGlobalNorm`, `adamwStep`, and `lastLogits`. It owns
allocation lifetimes and synchronization; `Main.hs` owns the training
composition.

At runtime the interpretation continues:

```text
generated CUDA source
  -> CUDA 12.9 NVRTC
  -> PTX
  -> provider libcuda.so.1
  -> driver JIT for sm_120
  -> GPU execution
```

`FUT_CACHE` memoizes the NVRTC result. Nix supplies CUDA userspace libraries;
the provider supplies the kernel-coupled driver. The runtime RPATH check rejects
CUDA driver stubs.

This path uses Futhark-generated FP32 kernels. It does not currently call
cuBLAS, cuBLASLt, cuDNN, CUTLASS, WMMA, or explicit tensor-core GEMMs. Therefore
100% reported GPU activity means that some generated kernel is continuously
resident, not that every arithmetic pipeline is saturated.

The Agda development is not linked into this executable. It supplies the laws
that license interpretations and transformations; Haskell, generated C, NVRTC,
and the driver perform the run.

## 22. Generation Chooses An Observation Of The Language

The checkpoint denotes logits, and normalization denotes a next-token
distribution. Generation still needs an observation policy:

```haskell
pickToken
  :: Float
  -> Int
  -> [Float]
  -> PRNGState
  -> (Int, PRNGState)
```

The first two arguments are temperature and `TOP_K`. At temperature zero the
observation is exact argmax and leaves the PRNG unchanged. Otherwise the host
sorts logits, retains the top K, temperature-scales and normalizes their
weights, then uses inverse-CDF sampling. A supplied `SAMPLE_SEED` is expanded by
SplitMix64; otherwise generation begins from the checkpoint's xoshiro256**
state.

The loop separates token selection from effects:

```haskell
generateLoop
  :: Context
  -> GpuConfig
  -> Config
  -> F32Array
  -> ([Float] -> PRNGState -> (Int, PRNGState))
  -> (Int -> IO ())
  -> Int
  -> PRNGState
  -> [Int]
  -> [Int]
  -> IO [Int]
```

The callback `(Int -> IO ())` is the streaming observation. Each selected token
is independently expanded by `decodeWith`, written, and flushed. This changes
when bytes become visible, not which tokens are selected. EOS terminates the
observation; BOS changes state but is not emitted.

There is not yet a KV-cache state implementing section 3's `StateAlgebra`.
`lastLogits` recomputes from the trailing bounded context each time. The proved
observation-trie law states what a future incremental implementation must
preserve.

Before the prompt, `wiki-generate` reports provenance derived from the same
checkpoint value:

```text
=== Wikipedia corpus training: 1.691% complete (31000/1833157 updates) ===
```

The numerator is `adamStep checkpointOptimizer`; the denominator is
`totalSteps manifestOptimizerConfig`. The response is therefore labeled by the
exact stage of the global Wikipedia interpretation that generated it.

## 23. Agda States What Each Interpretation Must Preserve

The Agda tree is the specification and proof layer that runs alongside the
executable chain. `Everything.agda` imports the complete checked surface under:

```agda
{-# OPTIONS --safe --without-K --guardedness #-}
```

`--safe` prevents hidden postulates from entering these modules. `--without-K`
avoids uniqueness-of-identity-proofs assumptions, and `--guardedness` checks the
coinductive trie definitions. The Nix `agda` check type-checks this root module.

The proof path follows the same types as the program.

### 23.1 Extensional language laws

`FormalTransformer.Language.Weighted` starts with section 1's function type and
proves:

```agda
residual-empty  : residual L [] ≡ L
residual-append : residual (residual L xs) ys ≡ residual L (xs ++ ys)
determination   : scoreByFold L xs ≡ L xs
```

These proofs say that consuming a prompt incrementally is extensionally the
same operation as applying the language to the whole prompt. They are the
semantic target for prompt handling and any future cached decoder.

### 23.2 Autoregressive factorization

`FormalTransformer.Language.Autoregressive` interprets a `StateAlgebra` as a
weighted language and proves:

```agda
factorization :
  pathWeight q (xs ++ ys)
    ≡ pathWeight q xs * pathWeight (run q xs) ys

residual-continuation :
  residual (unnormalized q) xs ys
    ≡ pathWeight q xs * unnormalized (run q xs) ys
```

This is the theorem behind the executable autoregressive loop: the probability
of a continuation depends on the state reached by its prefix, while the weight
already consumed factors out. Section 22's recomputing implementation is one
interpretation; a KV cache may replace it only if it preserves this equation.

### 23.3 Prefix composition and Bradley enrichment

`FormalTransformer.Enriched.Bradley` requires explicit right-extension evidence
for a morphism and proves:

```agda
identity-hom    : prefixHom q id ≡ 1#
composition-hom : prefixHom q (p ; r)
  ≡ prefixHom q p * prefixHom (run q extension-p) r
```

This rules out the stronger and false claim that arbitrary substring weights
compose. The Haskell magnitude and entropy observations operate on finite prefix
trees whose arrows have exactly this directed meaning.

### 23.4 Reverse derivatives compose as pullbacks

`FormalTransformer.AD.Reverse` does not identify a derivative with an untyped
function. An `AdditiveMap` carries proofs that it preserves zero and addition:

```agda
record AdditiveMap A B where
  field
    apply          : Carrier A → Carrier B
    preserves-zero : apply zero ≡ zero
    preserves-+    : apply (x + y) ≡ apply x + apply y
```

`identityD`, `composeD`, and `pairD` then prove the primal and pullback laws for
identity, composition, and fanout. In particular, `pairing-chain` proves that
cotangents from two uses of a parameter add at the shared input. This is the
abstract law used by reverse-mode AD before Futhark chooses arrays and `f32` as
its concrete carriers.

`FormalTransformer.AD.Batch` specializes that additivity to training:

```agda
addD-factor-pullback : addD factors through pairD and plusD
batch-pullback       : pullback (sum fs) = sum (map pullback fs)
mean-pullback        : the scaled sum has the scaled summed pullback
```

Those are the proofs that license sections 11 and 15. They establish equality
in an additive model; they deliberately permit the production implementation's
small `f32` differences caused by a different summation order.

### 23.5 Shape proofs precede allocation

`FormalTransformer.Transformer.Config` stores the obligations needed by the
model:

```agda
model-head-shape : model ≡ heads * headDim
headDim-even     : 2 ∣ headDim
```

`FormalTransformer.Transformer.Specification` then uses `Fin`, `Vec`, and
shape-indexed `Tensor` values so an attention position cannot exceed the context,
a target cannot exceed the vocabulary, the model has exactly `layers` blocks,
and RoPE receives even-sized heads. The tied embedding/unembedding table appears
once in `ModelParameters`, matching section 9's flat parameter count.

The specification explicitly labels its tensor primitives as signatures only.
It proves that well-typed implementations have legal shapes; it does not prove
that the Haskell list program or generated Futhark kernels implement every
primitive correctly. Runtime `validateConfig`, layout checks, and the sequential
conformance oracle are the refinement bridge at that boundary.

### 23.6 Coinduction specifies a future KV cache

`FormalTransformer.Language.Trie` proves that extensional languages and
coinductive tries agree:

```agda
to-from   : toLanguage (fromLanguage L) xs ≡ L xs
≈-sound   : s ≈ t → toLanguage s xs ≡ toLanguage t xs
≈-complete: (∀ xs → toLanguage s xs ≡ toLanguage t xs) → s ≈ t
```

`FormalTransformer.Language.AutoregressiveTrie` connects that result to the
running state machine:

```agda
observation-run :
  advanceT (observationTrie q) xs ≡ observationTrie (run q xs)

trie-residual :
  toLanguage (advanceT (stateTrie q) xs) ys
    ≡ residual (unnormalized q) xs ys
```

These theorems make the trie the denotational type of an incremental decoder.
The current `lastLogits` path does not use a KV cache, but the proof already
states the observational equivalence a cache implementation must satisfy.

### 23.7 The explicit trust boundary

`FormalTransformer.AD.Trusted` packages the analytic derivatives of `exp` and
reciprocal square root as fields of `TrustedAnalytic`. They are visible backend
obligations, not global Agda postulates. The proof layer also does not currently
formalize FastBPE, compact binary encoding, the global TSV plan, AdamW, IEEE-754
rounding, Futhark compilation, NVRTC, PTX, or the NVIDIA driver.

The overall assurance argument is therefore layered rather than overstated:

```text
Agda proofs
  establish semantic, algebraic, coinductive, and shape laws

Haskell reference + runtime validation
  choose concrete finite representations and reject identity mismatches

sequential Futhark conformance
  compares logits, loss, gradients, accumulation, and one AdamW update in f32

generated CUDA execution
  runs the same checked entry interface on the GPU
```

The first layer is theorem-checked. The second and third are executable
refinement evidence. The final compiler and hardware path remains in the
trusted computing base.

## 24. One Checkpoint Crosses All Executable Interpretations

The final operational boundary is intentionally backend-independent:

```text
Checkpoint
  -> sequential-C generation
  -> multicore-C generation or training
  -> OpenCL training
  -> CUDA training
  -> Checkpoint
```

The checkpoint does not claim which backend produced it. Its manifest claims
the model, tokenizer, dataset, layout, optimizer schedule, clipping rule, and
parameter count. Backend choice is an implementation decision provided those
claims are interpreted faithfully.

The live Wikipedia run is thus one value evolving through the section 19 state
transition over 1,465 section 18 intervals. CUDA currently computes the
transition; an atomic compact checkpoint carries it off the rented machine; the
local sequential host observes the same value through section 22 generation.
The type history closes where it began: execution is an interpretation of a
language, not its definition.
