# ana

A denotationally specified autoregressive transformer — written from a
mathematical specification in Agda, refined through a Haskell reference and
Futhark kernels, and trained end-to-end over **every article of English
Wikipedia** on a single rented consumer GPU.

| | |
|---|---|
| Model | 10,571,840 parameters — GLA/softmax 3:1 hybrid, vocab 8192, context 256 |
| Trained on | 5,857,550 articles, ~3.75B tokens, exactly one pass |
| Cost | 92 h on one RTX 5060 Ti, roughly $10–25 |
| In-domain quality | **1.21 bits per byte** on held-out Wikipedia prose |
| External benchmark | **1.99 bits per byte** on enwik8 (GPT-2-small: 1.16) |

Both numbers matter, and they say different things. On the domain it was
trained on, a 10.6M-parameter model reaching 1.21 bpb for $20 is a genuinely
good result. On enwik8 — the benchmark GPT-2 reported, and the only
apples-to-apples comparison available — it scores 1.99 against GPT-2-small's
1.16, so **it does not reach GPT-2-small quality**. The gap is mostly domain:
enwik8 is raw MediaWiki XML, while this model saw extracted prose and its
8,192-piece tokenizer shatters markup into byte fallbacks.

Two earlier readings of this run were wrong and are worth flagging, because
both flattered it: the training log's final-decile figure of 1.107 is not the
model's quality (the log's deciles follow shard order, the dump is
article-ordered, and the last shards are the stub tail), and comparing any
in-domain figure to GPT-2's zero-shot number was never like-for-like.

The weights are in this repository. The full record of the run — architecture
rationale, results, an honest comparison against state-of-the-art training, and
what to do next — is **[`docs/RUN-2026-07-25-WIKI-FULL.md`](docs/RUN-2026-07-25-WIKI-FULL.md)**.

## Generate

```bash
./weights/assemble.sh                    # reassemble the vendored checkpoint, verify SHA-256
nix run .#wiki-generate                  # asks for a prompt
nix run .#wiki-generate -- --prompt "The theory of" --tokens 256
```

`wiki-generate` is offline by default — it makes no network call unless asked.
With no arguments it uses the last pulled checkpoint (`run/last-checkpoint`),
falling back to the newest architecture-compatible checkpoint under `run/`.
`--list` shows what is available locally. Decoding samples the next-token
distribution: `TEMPERATURE` (default 0.8), `TOP_K` (default 40), `SAMPLE_SEED`
for reproducibility, `TEMPERATURE=0` for exact greedy argmax. Each response
begins with the generating checkpoint's exact training percentage and update
count.

Sample output at temperature 0.8 — fluent, correctly-registered encyclopedic
prose, and factually empty, which is the expected profile at 10.6M parameters:

> Paris is the capital of **the Dutch East India Company (VLC) operating in the
> southern states of South Sumatra and Botswana.**

Generation runs the incremental decoder: GLA layers advance a fixed-size state
per token, and the 1-in-4 NoPE softmax layers append to a ring-buffer KV cache
(cache order does not matter without positional encodings, so the ring needs no
reindexing). Feeding a sequence token-by-token reproduces every row of the batch
forward to ~6e-9 — the proved `cache-run` law, numerically.

## Measure

Training-log validation lines are a progress signal, not a measurement: they
sample a few windows, and each shard validates against a *different* held-out
split. For a number worth quoting, score a fixed corpus offline:

```bash
formal-transformer build-eval run/eval/wiki-heldout.corpus \
  run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv run/wiki-bpe10m 40 20
nix run .#wiki-eval
```

`build-eval` does not invent a split — it replays each shard's
`splitDocumentsFrom offset trainerSplitSeed trainerValidationFraction`, the same
call the trainer makes, and collects the validation side, so the corpus is made
of documents the run genuinely never trained on. `wiki-eval` then scores **every**
full window and reports bits per byte with a standard error.

## Train

```bash
nix run .#wiki-train                       # consume the entire local dataset
WIKI_BACKEND=cuda nix run .#wiki-train     # NVIDIA CUDA
WIKI_CORPUS=my.corpus nix run .#wiki-train # single-corpus mode
```

`wiki-train` defaults to `WIKI_BACKEND=multicore` (Futhark's multicore C backend,
step-for-step identical to the sequential oracle). Backends share one checkpoint
format, so a run started on one continues on another.

Whole-dataset mode makes an atomic plan before step one, fixing the dataset
identity, exact update count, batch size, document split, and shard endpoints —
one checkpoint, one AdamW trajectory, and one cosine schedule across all 1,465
shards. Physical sharding is a bounded-memory detail, not 1,465 separate runs.

A run's schedule is anchored at creation, and `TRAIN_BATCH` is *semantic*: it
enters the plan identity, so changing it needs a new plan. `MICRO_BATCH` and the
checkpoint/validation cadences are execution-only and never affect the
trajectory. Ingestion is generic — any dataset expressible as JSONL `{id, text}`
pipes through `prepare-bpe-stdin` with no code change.

On rented hardware, `deploy/train-cloud.sh` drives training per shard from a
pre-built plan; `nix run .#wiki-generate -- --pull --host user@HOST --port N`
fetches weights into a per-host directory that can never overwrite existing ones.

## Build and verify

```bash
nix build .#formal-transformer            # CPU reference + CLI
nix build .#formal-transformer-multicore  # multicore C backend
nix build .#formal-transformer-cuda       # Futhark CUDA
nix build .#formal-transformer-gemm-cuda  # decomposed cuBLAS tensor-core trainer
nix build .#conformance                   # cross-backend numeric oracle
nix build .#gemm-conformance              # decomposed vs fused oracle vs Numeric.AD
```

Agda proofs build with `Everything.agda` under `--safe --without-K`. The
conformance oracle relates the Haskell `Double` reference, the Futhark backends,
and `Numeric.AD` under component-specific tolerances — a tested refinement
relation, not an equality theorem over the reals. What is proved, and the trusted
base that is *not*, are enumerated in the run document.

## Scope

This repository proves structural language and reverse-AD laws, and tests
numeric backend agreement. It does not prove that IEEE floating point is real
arithmetic, that Futhark's compiler is correct, that optimization converges, or
that a trained model is accurate, truthful, or safe. The trained model has had
no post-training of any kind: it cannot follow an instruction, because it has
never seen one.
