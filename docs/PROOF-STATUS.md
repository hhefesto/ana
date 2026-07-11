# Proof Status

## Proved In Safe Agda

- Left-fold composition over list append.
- Empty and composed weighted-language residual laws.
- Determination of a weighted language by `nu` and repeated `delta`.
- State-run composition and autoregressive path factorization.
- The relation between an unnormalized residual and reached continuation state.
- Finite one-step mass equality when supplied by `Distribution`.
- Identity and aligned-prefix composition for bounded Bradley objects.
- Additive-map identity/composition and product pullback summation.
- Reverse derivative identity, composition, primal chain, pullback chain, and
  pairing equations.
- Parameter-count formula and shape-bearing configuration constraints.
- Coinductive trie/extensional correspondence: `toLanguage ∘ fromLanguage`
  pointwise; `fromLanguage ∘ toLanguage` up to bisimulation; bisimulation
  soundness and completeness against `toLanguage`, so trie bisimulation
  coincides with extensional language equality.
- Trie advance composition over append (reusing `foldl-++`).
- Observation-trie run homomorphism for every `StateAlgebra`: incremental
  stepping equals whole-prefix evaluation, refl per step.
- Weighted-trie denotation equals the existing `unnormalized` language; its
  run homomorphism and agreement with `residual-continuation`.
- Pointwise sum of additive maps; `addD`/`batchD` primal-sum and
  pullback-accumulation equations; factorization of `addD` through the
  proved `pairD` and `plusD`; the mean-loss pullback corollary.

All modules imported by `Everything.agda` use `--safe --without-K`. The two
coinductive trie modules and `Everything.agda` additionally enable
`--guardedness`, which Agda permits under `--safe`; sized types remain
disabled. There are no global postulates.

## Explicit Assumptions

- `TrustedAnalytic` receives derivative validity for exponential and reciprocal
  square root as record fields.
- Algebraic structures receive semiring, additive-monoid, and order laws as
  fields; a typeclass or record name alone is not treated as a proof.
- `Distribution` currently proves total finite mass but does not encode
  non-negativity or uniqueness of the supplied vocabulary enumeration.
- Tensor primitive signatures specify shapes but do not yet carry proofs that a
  concrete array backend preserves every operation.
- Equality between coinductive tries is bisimulation `_≈_`, never
  propositional equality between trie values.
- `meanD` receives its 1/n scaling as an additive map assumed self-dual;
  this is true of multiplication by a fixed scalar but is supplied, not
  proved.
- `--guardedness` is infective: any future module importing the trie modules
  must declare it.
- f32 summation order is the tolerated divergence between micro-batch
  accumulation and a full-batch gradient.

## Tested Refinements

- Haskell parameter layout is contiguous and has the formal parameter count.
- Causal prefix logits are invariant under adding future tokens.
- Haskell reverse AD agrees with finite differences on a tiny complete model.
- AdamW agrees with its one-step equation.
- Data preparation inserts BOS/EOS and splits documents before windows.
- Byte tokenization and corpus/checkpoint serialization roundtrip exactly.
- Haskell and Futhark sequential-C agree on every tiny-model logit, mean loss,
  all gradient entries, AdamW parameters, and both moments within recorded
  `f32` tolerances.
- Micro-batch accumulation equals the full-batch gradient on the tiny model
  within f32 reassociation (loss bitwise equal; gradient max_abs ≈ 1.5e-8),
  and matches the Haskell reference at the ordinary gradient tolerances.
- The size-typed Futhark interface rejects a mis-sized parameter vector.
- The bigram gate's counting, smoothing, and window cross-entropy are exact
  on hand-computed cases, agree with the `WeightedLanguage` fold semantics,
  and share the trainer's split and windowing by construction.
- Futhark OpenCL source and GPU host compile-link successfully.
- The sequential-C host completed 1,000 real updates of the 123,328-parameter
  `small` model with periodic exact checkpoints.

## Not Proved

- Correctness of GHC, MAlonzo, Futhark, OpenCL drivers, or hardware.
- A real-number error bound for `Double` or `f32` execution.
- Full Yoneda completion or the magnitude closed form in Agda.
- Correctness of a concrete backend KV cache; none is implemented yet. The
  abstract law — incremental stepping equals whole-prefix evaluation — is now
  proved for every `StateAlgebra` through the observation trie, so a future
  cache must only exhibit its state as a `StateAlgebra` implementation.
- Eventual EOS termination for unconstrained generation.
- Optimizer convergence, generalization, factuality, capability, or safety.

The first OpenCL smoke attempt coincided with an AMD compute-ring timeout and
display reset. The kernel attributed the timed-out context to Brave, while the
training context reported itself innocent. OpenCL training is therefore not yet
accepted as stable on the display-attached RX 580. The sequential-C interpreter
is the current safe training backend.
