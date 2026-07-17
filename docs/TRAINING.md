# Training Contract

## Corpus

`prepare-bytes` creates a versioned byte corpus. `prepare-bpe` and
`prepare-bpe-stdin` create version-2 corpora using a strict 8192-token FastBPE
artifact. BPE identity covers pretokenization semantics and a SHA-256 digest of
the canonical merge table. Dataset fingerprints remain labeled noncryptographic
FNV-1a values.

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
The accumulated gradient is clipped on device to `GRAD_CLIP` (default 1.0)
before the single AdamW update. The clip is recorded in the checkpoint
manifest: it changes the training trajectory, so resuming with a different
`GRAD_CLIP` is rejected like any other schedule change. Version-1
checkpoints (which predate the field) decode with clip 1.0, the default
every historical run used.

Progress lines use Mexico City local time (`America/Mexico_City`) to minute
precision. Each update reports the global completed/target step, percentage,
current learning rate, raw training loss, a process-local exponential moving
average with decay 0.98, the pre-clipping gradient norm, and whether clipping
was applied. Every `VALIDATE_EVERY` steps (default 500) the line additionally
reports validation loss over the first `VALIDATION_WINDOWS` validation
windows (default 256), the change from the preceding validation, the current
segment's best validation loss, bits per byte, and the bigram-gate result.
The moving average and validation delta restart after a process restart;
optimizer and checkpoint semantics do not depend on them. Validation reads
parameters and writes nothing, so its cadence and sample size never affect
the training trajectory; a larger sample only sharpens the estimate (256
windows put the standard error near 0.01 nats, so deltas are meaningful,
where the old 8-window sample drowned them in ±0.07 noise).

In whole-dataset mode, best validation resets at a shard boundary because each
shard has a different validation sample. It remains checkpointed within a
shard so interruption and resume preserve the meaningful comparison.

The desktop-safe default batch is one sequence. `TRAIN_BATCH` can raise it after
the backend is known to stay below the GPU watchdog. `CHECKPOINT_EVERY` controls
periodic atomic snapshots and defaults to five hundred completed steps.
Snapshots are pure observations of device state, so the cadence does not
affect the trajectory either — only how much completed work a crash can lose.

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

Two further execution-only GPU knobs (like `FUT_DEVICE`/`FUT_CACHE`, they
change scheduling, never the equations): `FUT_TUNING` names a
futhark-autotune-style `NAME=VALUE` file applied to the kernel context, and
`FUT_REJECT_INTRA=1` rejects the compiler's intra-workgroup kernel versions,
whose one-workgroup-per-inner-dimension launches exceed per-kernel workgroup
limits on register-poor devices (`CL_INVALID_WORK_GROUP_SIZE` on
Polaris/rusticl) and whose fully-flattened fallback suits this model's
shapes. This is an explicit OpenCL/Polaris workaround, not a CUDA default:
an RTX A4000 showed the same low-occupancy failure with it set and unset.
CUDA deployment uses Futhark's stock schedule unless `FUT_TUNING` or another
knob is deliberately supplied.

Treat autotuning output as a hypothesis, not a result. On the RTX 5070 the
generated tuning file made six of seven production-ladder shapes slower (up to
30x); it was rejected after an independent rerun. Stock scheduling plus
`MICRO_BATCH=1` is the measured `bpe10m` configuration.

## Baseline Gate

A bigram language model is the minimal finite state algebra over the
vocabulary: its state is the previous token. `bigram-gate CORPUS
[tiny|small]` fits exact sufficient-statistics counts with add-1 (Laplace)
smoothing on the trainer's training documents and reports next-token cross
entropy on the trainer's validation windows — both the sample the trainer
logs against (its first `VALIDATION_WINDOWS` windows) and the full
validation split. The split and
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

Whole-dataset mode first plans every bounded shard, then invokes
`train-segment` with one global total and cumulative segment endpoints. The
checkpoint's Adam step and both moments cross shard boundaries unchanged.
Document splitting uses each shard's global document offset, and epoch sampling
uses a segment-local step, so physical shard boundaries do not change the
denoted document split or omit examples.

## Resume

Resume validates all of the following before creating an OpenCL context:

- artifact and layout versions;
- model configuration and parameter count;
- optimizer configuration, gradient clip, and completed step;
- model, tokenizer, and dataset identities;
- parameter and moment lengths and finiteness;
- persisted PRNG and best validation metric.

`STEPS` is a target completed step. It is never interpreted as additional work.

The sequential, multicore, OpenCL, and CUDA applications interpret the same
Futhark source and checkpoint identity. Sequential C is the safe fallback when
the OpenCL device also drives the desktop.

## Current Scaling Limits

- Corpus documents and fixed windows are materialized eagerly by the host.
- Batches have uniform lengths and no padding mask.
- Attention is quadratic in context length.
- Parameters and optimizer state are `f32`; there is no mixed precision.
- CUDA currently uses one device; multi-device gradient reduction is planned.
- Generation recomputes the context per token instead of using a KV cache.

## Generation

Decoding is an observation of the model's next-token distribution; it never
changes the checkpoint's denotation. `TEMPERATURE` (default 0.8) softmaxes
the `TOP_K` (default 40) largest logits at that temperature and samples by
inverse CDF, driven by the checkpoint's xoshiro256** PRNG state or, when
`SAMPLE_SEED` is set, a SplitMix64 expansion of that seed (a fixed seed
makes output reproducible). `TEMPERATURE=0` is the degenerate greedy
observation: the exact argmax path, deterministic, and — being a
deterministic map on a finite context window — eventually periodic, which
is why untempered greedy output loops.
