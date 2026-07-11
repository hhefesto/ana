# Training Contract

## Corpus

`prepare-bytes` creates a versioned binary corpus with one document per input
file. It records the fixed tokenizer identity and a deterministic labeled FNV-1a
fingerprint. The fingerprint is not cryptographic.

The GPU host assigns whole documents to train or validation before constructing
windows. Every window remains within one document. Streams are

```text
BOS : document-bytes ++ [EOS]
```

and only full fixed-width, non-overlapping windows (stride = width) are
retained: every token is a next-token target at most once, so consuming
all windows consumes the training material exactly once. Short documents
are therefore omitted by the GPU trainer.

## Objective

For each fixed-width sequence, every position except the last predicts its next
token. Batch loss is the mean of per-sequence mean cross-entropies. Futhark
computes the gradient through `vjp2`; no model-wide backward pass is maintained
by hand.

## Update

AdamW uses bias-corrected first and second moments. Decoupled weight decay is
selected by the canonical layout mask. The learning rate has linear warmup and
cosine decay to the checkpointed total target step.

The desktop-safe default batch is one sequence. `TRAIN_BATCH` can raise it after
the backend is known to stay below the GPU watchdog. `CHECKPOINT_EVERY` controls
periodic atomic snapshots and defaults to ten completed steps.

`MICRO_BATCH` (default: `TRAIN_BATCH`) processes each effective batch as
chunks of at most that many sequences. Each chunk's adjoints are seeded with
one over the effective batch inside the kernel, so accumulated chunks equal
the full-batch gradient up to f32 summation order; the linearity theorem
behind this is `batch-pullback` in `FormalTransformer/AD/Batch.agda`, and
the conformance oracle checks the equality on the tiny model. One AdamW
update still happens per effective batch, so step counting, the schedule,
and checkpoint semantics are unchanged. Validation likewise evaluates in
`MICRO_BATCH`-sized chunks with a count-weighted average. The practical
purpose is the display-GPU watchdog: each kernel launch stays near the
known-safe single-chunk cost while the effective batch grows.

## Baseline Gate

A bigram language model is the minimal finite state algebra over the
vocabulary: its state is the previous token. `bigram-gate CORPUS
[tiny|small]` fits exact sufficient-statistics counts with add-1 (Laplace)
smoothing on the trainer's training documents and reports next-token cross
entropy on the trainer's validation windows — both the eight-window sample
the trainer logs against and the full validation split. The split and
windowing logic is shared with the GPU host (`trainerWindowSplit` in
`FormalTransformer.Data`), so the gate scores exactly the windows the
trainer validates on. The trainer prints the gate at startup and marks each
validation line `beats-gate` or `behind-gate`. A trained model that loses to
the bigram has not yet paid for its attention.

The target total is part of the optimizer schedule. A checkpoint cannot be
silently resumed with a different target because that would change earlier
schedule semantics. Start a deliberately new run if the schedule changes.

`STEPS` may be the literal `epoch`: the target becomes
`ceil(training windows / TRAIN_BATCH)` and batches walk the training
windows in a deterministic full-coverage order (windows sorted by an index
hash, sliced cyclically by step) instead of PRNG sampling. Finishing an
epoch run therefore means every training window has been consumed at least
once; the final slice may wrap. Because the target depends on the corpus
and `TRAIN_BATCH`, resuming an epoch run requires the same corpus and the
same `TRAIN_BATCH`, or resume validation rejects the optimizer schedule.
The epoch order is a pure function of the step, so resume needs no
additional state.

## Resume

Resume validates all of the following before creating an OpenCL context:

- artifact and layout versions;
- model configuration and parameter count;
- optimizer configuration and completed step;
- model, tokenizer, and dataset identities;
- parameter and moment lengths and finiteness;
- persisted PRNG and best validation metric.

`STEPS` is a target completed step. It is never interpreted as additional work.

The `formal-transformer-sequential` and `formal-transformer-gpu` applications
interpret the same Futhark source and checkpoint identity. Sequential C is the
safe fallback when the OpenCL device also drives the desktop.

## Current Scaling Limits

- Corpus documents and fixed windows are materialized eagerly by the host.
- Batches have uniform lengths and no padding mask.
- Attention is quadratic in context length.
- Parameters and optimizer state are `f32`; there is no mixed precision.
- Validation samples at most eight windows every ten steps.
- Generation is greedy and recomputes the context instead of using a KV cache.
