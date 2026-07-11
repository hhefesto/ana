# Mathematical Specification

## Autoregressive Denotation

For tokens `A`, weights `W`, and states `S`, a model exposes a terminal weight
and a token transition carrying both conditional weight and successor state:

```text
out  : S -> W
step : S -> A -> W * S
```

The weight of a path and reached state are folds. The central factorization is

```text
pathWeight q (u ++ v)
  = pathWeight q u * pathWeight (run q u) v.
```

`Distribution` strengthens an output with the finite mass equation

```text
terminalWeight + sum(tokenWeight vocabulary) = 1.
```

Non-negativity requires an ordered carrier and is not currently part of that
Agda record.

## Language Derivatives

A weighted language is an extensional function `List A -> W`.

```text
nu L                  = L []
residual L u v        = L (u ++ v)
delta L a             = residual L [a]
scoreByFold L w       = nu (foldl delta L w)
```

The Agda modules prove empty residual, residual composition, and determination
by `nu` and `delta`. This derivative consumes a discrete prefix. It is not the
calculus derivative of the model parameters.

For an autoregressive model's complete-string weight, residualization is
unnormalized:

```text
residual (language q) u v
  = pathWeight q u * language (run q u) v.
```

The reached state's continuation language is the normalized behavioral object;
the scalar prefix mass is retained separately.

## Bradley Enrichment

Objects are bounded token prefixes with an explicit terminal marker. A morphism
exists when evidence gives an aligned right extension. Its hom-value is the
conditional path weight of that extension.

Identity and aligned composition follow from path factorization:

```text
L(x,x) = 1
L(x,y) * L(y,z) = L(x,z)
```

No equality is claimed for arbitrary substring relationships. Under `-log`, an
aligned composition becomes additive directed surprisal.

For a finite prefix tree, the executable metric layer implements

```text
Mag_t = terminalCount + (t - 1) * sum_x H_t(p_x)
d/dt Mag_t | t=1 = sum_x ShannonEntropy(p_x).
```

## Transformer

`Transformer.Specification` states shape-indexed operations and parameter
records for the canonical decoder. The Haskell and Futhark interpreters use the
same row-major flat layout. Causal attention computes each position only from
its prefix, and tied unembedding takes dot products with token-embedding rows.

## Reverse Automatic Differentiation

An augmented reverse derivative returns a primal result and an additive
pullback:

```text
D A B = A -> B * (B ->+ A)
```

Composition reverses pullbacks, and pairing sums cotangents. Agda proves the
identity, composition, chain, and pairing equations. Analytic derivative facts
for `exp` and reciprocal square root are explicit fields of `TrustedAnalytic`.

## Training

Futhark defines mean next-token cross-entropy and obtains its full flat gradient
with `vjp2`. AdamW is a separate state transition with bias correction and a
layout-derived decay mask. Checkpoints include parameters, both moments,
completed step, optimizer/schedule configuration, PRNG state, best validation
loss, model layout identity, tokenizer identity, and dataset identity.
