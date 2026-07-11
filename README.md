# formalTransformer

`formalTransformer` is a specification-first decoder language model. It keeps
three questions separate:

1. What language does an autoregressive model denote?
2. What tensor function does the transformer compute?
3. Does each executable backend implement that function and its derivative?

The design follows Conal Elliott's denotational and compositional approach.
Elliott's prefix derivative describes how a language changes after consuming a
token; reverse automatic differentiation describes how the loss changes after
perturbing parameters. They are deliberately not identified with one another.

Tai-Danae Bradley's enrichment is derived from conditional continuation
probabilities. It supplies prefix hom-values, directed surprisal, magnitude, and
entropy metrics. It does not define attention or backpropagation.

## Canonical Model

The single parameter layout shared by Agda, Haskell, and Futhark is:

```text
token embedding [v,d]
for each block:
  attention RMS gain [d]
  Wq, Wk, Wv, Wo [d,d]
  feed-forward RMS gain [d]
  Wgate, Wup [f,d]
  Wdown [d,f]
final RMS gain [d]
```

The decoder uses pre-RMSNorm, RoPE, causal multi-head attention, SwiGLU,
residual connections, and tied embedding/unembedding weights. It has no biases,
dropout, or learned positional table. The exact count is

```text
v*d + layers*(4*d*d + 3*f*d + 2*d) + d
```

## Components

- `FormalTransformer/`: safe Agda definitions and structural proofs.
- `backend/src/`: list-backed `Double` reference implementation and artifacts.
- `backend/futhark/`: flat-array `f32` model, VJP, and AdamW kernels.
- `backend/gpu/`: device-resident OpenCL trainer and generator.
- `backend/conformance/`: Haskell/Futhark sequential-C numeric oracle.
- `docs/PROOF-STATUS.md`: exact statement of what is proved or tested.
- `docs/TYPE-HISTORY.md`: the type-level path from languages to GPU training.
- `docs/LOCAL-COMPARISON.md`: type-history comparison with the other local
  language-model projects.
- `docs/PARALLEL-SCALING.md`: where linearity licenses parallelism, and the
  plan for scaling beyond this machine.
- `docs/CLOUD-TRAINING.md`: budgeted CUDA deployment and rental procedure.
- `docs/RUN-2026-07-10.md`: first live training report and GPU reset diagnosis.

## Verification

```bash
nix flake check
```

This typechecks all safe Agda modules, builds and tests the Haskell reference,
typechecks Futhark, compile-links the OpenCL host without running it, and runs a
CPU-only Haskell/Futhark conformance oracle.

Useful individual commands:

```bash
nix build .#conformance
nix build .#formal-transformer-gpu
nix develop -c agda -i . Everything.agda
nix develop -c cabal test
nix develop -c futhark check backend/futhark/kernels.fut
```

## Data And CPU Reference

The initial tokenizer is deliberately small and total: BOS `0`, EOS `1`, and
bytes `2..257`. Each input file becomes one document, so document splitting
happens before windows are produced.

```bash
nix run . -- prepare-bytes corpus.bin article-1.txt article-2.txt article-3.txt
nix run . -- inspect-corpus corpus.bin
nix run . -- inspect
nix run . -- gradcheck
nix run . -- train-smoke
nix run . -- bigram-gate corpus.bin small
```

`bigram-gate` reports the exact-counts bigram baseline on the trainer's own
validation windows; a trained model should beat this number (see
`docs/TRAINING.md`).

## One-Command Wikipedia Training And Generation

Two flake apps run the whole Wikipedia loop with no arguments:

```bash
nix run .#wiki-train      # start or resume training
nix run .#wiki-generate   # generate text from the latest weights
```

`wiki-train` with no arguments consumes the **entire local Wikipedia
dataset** (`~/datasets/wikipedia-en/enwiki-natural-language.jsonl`, one
article per line; override with `WIKI_DATA`). Before step one it makes an
atomic plan over bounded article shards. The plan fixes the complete dataset
identity, exact update count, batch size, offset-invariant document split,
and cumulative shard endpoints. Training then uses one checkpoint, one AdamW
state, and one cosine schedule across every shard. Physical sharding is a
bounded-memory implementation detail, not 1,465 fresh optimizer runs.

```bash
nix run .#wiki-train                       # consume all of Wikipedia
WIKI_SHARD_ARTICLES=16000 nix run .#wiki-train
TRAIN_BATCH=8 nix run .#wiki-train
WIKI_BACKEND=opencl nix run .#wiki-train   # GPU (see below)
WIKI_BACKEND=cuda nix run .#wiki-train     # NVIDIA CUDA
WIKI_SIZE=bpe10m WIKI_PLAN_ONLY=1 WIKI_KEEP_CORPORA=1 nix run .#wiki-train
WIKI_CORPUS=my.corpus nix run .#wiki-train # single-corpus mode
```

With `WIKI_CORPUS` set, the old single-corpus behavior applies:
one run into `WIKI_CHECKPOINT` (default `run/wiki-small.checkpoint`)
toward `WIKI_STEPS` (default `epoch`).

Contract notes: a run's schedule is anchored at creation. Whole-dataset mode
includes `TRAIN_BATCH` in its global plan identity; single-corpus epoch mode
anchors the same value through its total step count. `MICRO_BATCH` and
checkpoint cadence may change on resume.

`wiki-train` defaults to `WIKI_BACKEND=multicore`: Futhark's multicore C
backend runs every kernel data-parallel across all CPU cores, produces
step-for-step identical losses to the sequential backend, and shares the
same checkpoint format as every other backend. `WIKI_BACKEND=sequential`
keeps the single-core oracle backend.

`WIKI_BACKEND=cuda` uses the Nix-built Futhark CUDA host. It links the CUDA
runtime and NVRTC from pinned Nixpkgs while resolving `libcuda.so.1` from the
machine's NVIDIA driver. See `docs/CLOUD-TRAINING.md` before renting hardware.

`WIKI_BACKEND=opencl` opts into the GPU: measured on the display-attached
RX 580, the OpenCL program builds on the host CPU (about a minute cold;
seconds afterward via the `FUT_CACHE` program cache the app sets up
automatically), the `tiny` preset then trains on the GPU, but the `small`
preset's gradient kernel is soft-reset after ~10 s by the amdgpu
*compute-ring* watchdog. Note a single-value `amdgpu.lockup_timeout`
kernel parameter raises only the non-compute rings; the four-value form
(`amdgpu.lockup_timeout=60000,60000,60000,60000`) covers the compute ring
rusticl submits to — after a rebuild and reboot with that setting, OpenCL
becomes viable for `small` on this machine (see
`docs/PARALLEL-SCALING.md`).

`wiki-generate` picks the newest available weights automatically: an
explicit `WIKI_CHECKPOINT` if set, else `run/wiki-small.checkpoint` (what
`wiki-train` writes), else the committed `run/wiki-small-1000.checkpoint`.
`WIKI_PROMPT` and `WIKI_TOKENS` override the prompt and budget:

```bash
WIKI_PROMPT="The theory of" WIKI_TOKENS=256 nix run .#wiki-generate
```

It generates on the sequential-C backend, which is safe on a display GPU;
checkpoints are interchangeable between backends. Both apps resolve their
paths relative to the current directory, so run them from the repository
root.

## GPU Training And Generation

The `inspect` command does not initialize OpenCL. `train` and `generate` do.

```bash
nix run .#formal-transformer-gpu -- inspect tiny
nix run .#formal-transformer-gpu -- train corpus.bin model.checkpoint 100 tiny
nix run .#formal-transformer-gpu -- generate model.checkpoint "A formal language" 128
nix run .#formal-transformer-cuda -- inspect bpe10m
```

`STEPS` is the target completed step, not an additional step count. Optimizer
and schedule configuration are checkpointed and must match exactly on resume.
The trainer defaults to `TRAIN_BATCH=1` and writes an atomic snapshot every ten
steps; both values can be changed through `TRAIN_BATCH` and `CHECKPOINT_EVERY`.
`MICRO_BATCH` (default: `TRAIN_BATCH`) splits each effective batch into
watchdog-sized accumulation chunks without changing what a step means (see
`docs/TRAINING.md`).
`GRAD_CLIP` defaults to global norm 1.0. Checkpoints and corpus documents use
packed `f32` and `u16` wire arrays while legacy artifacts remain readable.

### Continuing Training

Training resumes from a checkpoint file automatically: if `CHECKPOINT` exists,
the trainer validates it exactly (model configuration, parameter count, layout
identity, optimizer schedule, model/tokenizer/dataset identities, PRNG, best
validation loss) and continues from its completed step. Because `STEPS` is a
*target*, re-running the same command is idempotent, and raising the target
continues the run:

```bash
# First 100 steps (creates model.checkpoint):
nix run .#formal-transformer-sequential -- train corpus.bin model.checkpoint 100 small

# Continue the same run to step 300 — same corpus, same size, higher target:
nix run .#formal-transformer-sequential -- train corpus.bin model.checkpoint 300 small
```

Rules the trainer enforces on resume:

- The corpus, model size, and checkpoint must be the ones the run started
  with; any identity mismatch is rejected rather than silently retrained.
- The optimizer schedule is anchored to the *original* total target inside
  the checkpoint. Continuing past that target requires starting a new run
  (new checkpoint file), because changing the target would silently change
  the meaning of the earlier warmup/decay schedule.
- `TRAIN_BATCH`, `MICRO_BATCH`, and `CHECKPOINT_EVERY` are launch mechanics,
  not identity; they may differ between sessions of the same run.
- A snapshot is written atomically every `CHECKPOINT_EVERY` steps and at the
  target, so an interrupted run loses at most `CHECKPOINT_EVERY - 1` steps.

The sequential and OpenCL hosts write identical checkpoint formats, so a run
started on one backend continues on the other.

### Running With The Latest Weights

Generation always reads a checkpoint file; the latest weights are simply the
checkpoint most recently written by training (the same path you trained
into):

```bash
nix run .#formal-transformer-sequential -- generate model.checkpoint "A formal language" 128
# or, when OpenCL is stable on your device:
nix run .#formal-transformer-gpu -- generate model.checkpoint "A formal language" 128
```

The generator validates the checkpoint's model and tokenizer identities
before creating a context, decodes greedily, and stops at EOS or the token
budget. To generate from an earlier point of the run, keep dated copies of
the checkpoint file; the artifact is self-describing, so any copy remains
loadable as long as identities match.

The current GPU host recomputes the bounded prefix during generation. A true KV
cache, padding masks, large-corpus streaming, mixed precision, and distributed
training remain future refinement layers (see `docs/PARALLEL-SCALING.md` for
the scaling plan).

The same host can be linked to Futhark's sequential-C backend when OpenCL shares
a display GPU or is unstable:

```bash
nix run .#formal-transformer-sequential -- train corpus.bin model.checkpoint 100 tiny
```

Sequential and OpenCL checkpoints share the same model identity and flat layout.

## Common Errors

Every command needs its input artifacts to exist already; the tools tell you
which command produces a missing artifact. The dependency order is:

```text
text files --prepare-bytes--> CORPUS --train--> CHECKPOINT --generate--> text
```

- `corpus file not found: corpus.bin` — `train`, `inspect-corpus`, and
  `bigram-gate` consume a *prepared corpus*, not raw text. Create one first:
  `nix run . -- prepare-bytes corpus.bin article-1.txt article-2.txt`. The
  literal `corpus.bin` in the usage examples is a placeholder for whatever
  path you chose there.
- `checkpoint file not found: model.checkpoint` — `generate` needs a trained
  checkpoint; run `train` first with the same path. (`train` itself treats a
  missing checkpoint as a fresh run, so this error never appears there.)
- `corpus/checkpoint decode failed` — the path exists but is not an artifact
  written by `prepare-bytes`/`train`; most often a raw text file was passed
  where a prepared corpus belongs.
- `checkpoint ... identity mismatch` / `does not match requested model size`
  — resume validation refuses to continue a run under a different corpus,
  model size, or optimizer schedule than it started with. Use the original
  arguments, or start a new checkpoint file (see "Continuing Training").
- `checkpoint has already passed target STEPS` — `STEPS` is a target
  completed step, not an increment; give a larger target or keep the
  finished checkpoint.
- `MICRO_BATCH must not exceed TRAIN_BATCH` — the micro-batch is an
  accumulation chunk of the effective batch (`docs/TRAINING.md`).

## Scope

The repository proves structural language and reverse-AD laws and tests numeric
backend agreement. It does not prove that IEEE floating point is real arithmetic,
that Futhark's compiler is correct, that optimization converges, or that a
trained model is accurate, truthful, or safe.
