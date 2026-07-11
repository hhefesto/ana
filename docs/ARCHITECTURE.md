# Architecture

## Commuting Layers

```text
weighted language semantics
          ^
          | path scoring / prefix action
abstract autoregressive state algebra
          ^
          | out and step
shape-indexed transformer specification
          ^
          | shared flat layout
Haskell Double reference <----> Futhark sequential C
                                  |
                                  | same generated program
                                  v
                            Futhark OpenCL host
```

The reverse interpretation is independent of prefix residualization:

```text
typed loss -> (primal loss, additive pullback) -> parameter gradient -> AdamW
```

## Parameter Order

Matrices are row-major. For every block the order is `rms_att`, `wq`, `wk`,
`wv`, `wo`, `rms_ff`, `wgate`, `wup`, `wdown`. Only matrix and embedding leaves
receive decoupled weight decay. RMS gains do not.

The layout is versioned as `canonical-decoder-flat-parameters`, version `1`.
Checkpoint loading rejects any other identity or parameter count.

The layout arithmetic is also part of the Futhark interface: every model
entry takes `params: [parameter_count v d f n_layers]f32`, so a mis-sized
parameter vector is rejected at the entry boundary. The formula is enforced
in four aligned places — the Agda parameter-count theorem, Haskell
`paramCount`, the layout slices, and the Futhark entry types — and the
conformance oracle ties them together.

## One Model, Two Entry-Point Programs

All Futhark definitions live in `backend/futhark/model.fut`. Two files
select entries from it: `kernels.fut` exposes the full set, including all
three differentiated entries (`loss_grad`, `batch_loss_grad`,
`micro_batch_loss_grad`) — this is what the sequential-C backend and the
conformance oracle build, so the oracle can compare the gradients against
each other and the Haskell reference. `kernels-opencl.fut` exposes only
what the trainer calls, with `micro_batch_loss_grad` as its single
differentiated entry, because rusticl compiles the entire generated OpenCL
program on the host CPU at context creation and that time grows with the
amount of vjp-generated code (measured: ~19 minutes for the full program,
~54 seconds for the reduced one, ~8 seconds with the `FUT_CACHE` program
cache). The dropped entries are recovered semantically: `batch_loss_grad`
and `loss_grad` are the single-chunk and single-sequence cases of
micro-batch accumulation, an equality the oracle checks on the sequential
backend.

## Baseline Rung

Below the transformer on the commuting diagram sits the exact-counts bigram
(`FormalTransformer.Bigram`): the minimal finite state algebra over the
vocabulary, an exact sufficient-statistics instance of the same weighted
language semantics the transformer approximates. It shares the trainer's
document split and windowing, and serves as the honest floor for validation
loss (see `docs/TRAINING.md`).

## Causality

The Haskell reference forms each attention row from keys and values at positions
`0..i`. Futhark computes a square score matrix and replaces future positions by
a large negative value before softmax. The conformance oracle checks their
observable agreement on a tiny model.

## Precision Boundary

Agda's structural theorems are exact. Haskell uses `Double`; Futhark uses `f32`.
The sequential-C oracle reports maximum absolute and relative errors and applies
component-specific tolerances. This is a tested refinement relation, not an
equality theorem over real numbers.
