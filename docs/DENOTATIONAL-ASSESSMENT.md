# Denotational Design Assessment

How faithfully does this repository follow Conal Elliott's denotational
design methodology? Written 2026-07-18 against the primary sources in
`~/src/conal-elliott` (the ICFP 2021 language-derivatives paper and its Agda
code, *The Simple Essence of Automatic Differentiation*, *Compiling to
Categories*, *Denotational Design with Type Class Morphisms*, *Timely
Computation*, the `weighted-derivatives` engine, and the two NOTES studies
comparing Elliott with Bradley).

## The Standard Being Applied

Elliott's methodology, distilled from those sources:

1. **Meaning first.** Define the mathematical denotation before any
   implementation. Never design an implementation and justify it after.
2. **Implementations are homomorphisms.** "The instance's meaning is the
   meaning's instance": an implementation is correct when it commutes with
   the meaning function. In the strongest form the implementation is
   *indexed by* its denotation, so correctness is typing, not a theorem
   proved afterwards (`Symbolic.lagda`/`Automatic.lagda`: the parser has
   type `Decidable P` for the semantic `P`; no separate soundness proof
   exists because none is needed).
3. **The two canonical observations.** A language-like object is fully
   determined by `ν` (observe now) and `δ` (residual after one token) — a
   proved determination theorem, not a definition.
4. **Linearity and semiring algebra carry the payoff.** Timing matrices,
   Jacobians, and language derivatives are all linear algebra over the
   right (semi)ring; performance transformations are reassociations
   licensed by algebra (RAD = left-association of the same composition).
5. **Honest trust boundaries.** What is not proved is stated, visibly, as
   an assumption with a name — not buried.

## Scorecard

### Language / StateAlgebra / Trie layer — strong adherence

`FormalTransformer/Language/Weighted.agda` begins exactly where Elliott
begins: the extensional `Language A W = List A → W` with `nu`, `residual`,
`delta`, and the proved determination theorem (`scoreByFold L xs ≡ L xs`) —
this is `Calculus.lagda`'s `ν∘𝒟` law, correctly instantiated at a weighted
codomain (the move Elliott's own code anticipates by being
codomain-polymorphic, and which `Weighted.lagda` in the paper repo now also
makes). `Autoregressive.agda` presents the language through a
`StateAlgebra` and proves `factorization` and `residual-continuation`;
`Trie.agda`/`AutoregressiveTrie.agda` are Elliott's `Automatic`
representation — the denotation-indexed coinductive trie — with the
`observation-run` law (incremental stepping equals whole-prefix evaluation)
proved refl per step. Bisimulation is proved sound *and complete* for
extensional equality, matching the honesty of Elliott's own equality
discipline for codata.

This layer is not merely inspired by the methodology; it is the
methodology, including the ports' selection criterion recorded in
`HANDOFF.md` ("only ideas with clear denotational-semantics foundations").

### AD layer — strong adherence

`AD/Reverse.agda` defines the reverse derivative as a value paired with a
typed pullback (`D A B = Carrier A → Carrier B × AdditiveMap B A`), with
identity/composition/pairing laws proved — *The Simple Essence of AD*'s
`D⁺` and its `Dual`/left-association reading, at the abstract additive
level. `AD/Batch.agda` proves that the pullback of a summed loss is the sum
of pullbacks, and the production Futhark kernel implements that law
*literally* (one `vjp2` per sample, accumulated with `map2 (+)` — see
`docs/TYPE-HISTORY.md` §11/§15). This is a genuine instance of "derive the
implementation from the algebra": the per-sample restructuring that fixed
the GPU pathology changed the schedule, not the denotation, and the
equality was both proved abstractly and oracle-checked bit-exactly.

`AD/Trusted.agda` packages the analytic facts for `exp` and `rsqrt` as
named record fields rather than postulates — precisely the "visible
assumption" discipline (compare `TrustedAnalytic` with the paper's
explicitly flagged uses of K in its plumbing).

### Configuration / shape layer — good adherence

`Transformer/Config.agda` carries shape obligations as proof fields
(`model ≡ heads * headDim`, `2 ∣ headDim`), and `paramCount` is a proved
formula that the Haskell `Slice` layout and the size-typed Futhark entries
must reproduce (`[parameter_count v d f n_layers]f32` in the entry type).
Proofs precede allocation. This is correctness-by-construction at the
shape level, though not yet at the value level.

### The transformer itself — the break in the chain

`Transformer/Specification.agda` declares `TensorPrimitives` as
**signatures only** (its own comment, line 20). `causalAttention` is an
uninterpreted record field: no defining equation, no derivative, no law —
only shapes and the causal bound `n ≤ context c`. There is no softmax and
no matmul anywhere in the Agda layer. Most significantly, **no statement —
proved or even conjectured — connects the transformer specification to the
`StateAlgebra`/`Language` layer.** Nothing says a transformer denotes a
weighted language. The semantic chain runs

```text
Language ← StateAlgebra ← observation trie      (all proved)
                ↑
                ✗  no bridge
                ↑
shape-typed transformer ← flat interpretation    (shapes only)
```

Judged by Elliott's standard this is the central deviation: the model's
core computation has types but no meaning. Attention is exactly where
"implementation first, justification after" re-entered the project — the
softmax form was inherited from the field, not derived from a stated
denotation. The repository is honest about the gap
(`docs/PROOF-STATUS.md`: tensor signatures "do not yet carry proofs"; no
verified KV cache exists, only the abstract law a future one must satisfy),
but honesty about a gap does not close it.

Two further consequences of the missing attention semantics:

- The proved KV-cache law (`observation-run`) has no instance: the
  generation path recomputes from the trailing window because nothing
  exhibits a transformer state as a `StateAlgebra` (PROOF-STATUS "Not
  Proved"). The theorem is waiting for a model whose attention *has* a
  finite-state semantics.
- RoPE, softmax temperature, and the causal mask live only in executable
  code; none of their algebraic content (rotation = orthogonal transition,
  temperature = observation of the distribution, mask = prefix restriction)
  is available to reasoning.

### Optimizer, tokenizer, artifacts — unformalized, honestly labeled

AdamW, clipping, FastBPE, compact encodings, and the global schedule are
runtime-validated rather than proved (`manifestClipNorm` checked on resume;
tokenizer identity strings; layout versions). This is "poor man's
denotational discipline": identity of interpretation is *checked* where it
cannot yet be *typed*. Elliott-compatible in spirit — the checks encode
exactly the statement "a checkpoint denotes a value only relative to an
interpretation" — but the interpretations themselves are informal.

### The spec→implementation bridge — tested refinement, not homomorphism

The conformance oracle compares Haskell reference and sequential-C Futhark
on logits, loss, every gradient entry, and an AdamW step, at recorded f32
tolerances; `docs/ARCHITECTURE.md` calls this "a tested refinement
relation, not an equality theorem", which is accurate. Elliott's strongest
form (implementation indexed by denotation, correctness = typing) is not
attempted across the Haskell/Futhark boundary, and realistically cannot be
while the backends are generated C consumed over FFI. The layered argument
in `TYPE-HISTORY.md` §23.7 states the trusted computing base plainly. This
is the right *honest* posture, one rung below the methodology's ideal.

## Verdict

| Layer | Adherence |
|---|---|
| Language / StateAlgebra / trie | Strong — Elliott's own constructions, proved |
| Reverse AD / batching | Strong — algebra licenses the production kernel |
| Shape / configuration | Good — proofs precede allocation |
| **Attention / transformer core** | **Gap — types without meaning, no bridge to the semantic layer** |
| Optimizer / tokenizer / artifacts | Informal, honestly labeled, identity-checked |
| Backend bridge | Tested refinement, correctly not overclaimed |

The single largest deviation from denotational design is that **attention
has no stated denotation**. Every proved law in the repository flows
*around* the model: the semantics knows the model only as an opaque
`StateAlgebra` that nothing implements, and the implementation knows the
semantics only through shape types. Closing this gap — stating what
attention *means*, then letting that meaning select and license the
implementation — is the highest-leverage next step, and is addressed in
`docs/ATTENTION-SEMANTICS.md`.
