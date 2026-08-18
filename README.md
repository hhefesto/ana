# ana

A denotationally specified autoregressive transformer — written from a
mathematical specification in Agda, refined through a Haskell reference and
Futhark kernels, and now training its second, 115M-parameter model on a
single rented consumer GPU.

| | |
|---|---|
| Model | 115,428,096 parameters — GLA/softmax 3:1 hybrid (9 GLA + 3 softmax layers), vocab 32,768 with tied embeddings, context 256 |
| Data | English Wikipedia interleaved with FineWeb-Edu — 9,700,651 documents, ~5.86B tokens, exactly one pass (51 tokens/parameter) |
| Plan | `run/mixed-bpe100m-s32000` — 304 shards, 358,276 updates at batch 64, one AdamW trajectory and one cosine schedule fixed before step one |
| Status | **the master run, training now** on one rented RTX 3090 ($0.172/hr) — past step 245,000 of 358,276 (~68%) as of 2026-08-18 |

This is *the master run*: `master` is its branch of record, and version 3
development happens on a separate branch (see Versions below). The run is in
progress; no final quality numbers exist yet and none are claimed. Two
samples bracket the trajectory so far. Step 16,000 (4.5% of the schedule) —
on-topic, correctly registered, and factually invented, which is the
expected order of acquisition:

> The theory of **evolution that has emerged in recent years by the term
> "Plasticizationism" was coined in the 1980s to describe the concept of
> evolution in a number of ways.**

Step 230,000 (64.2%, loss EMA 3.373 and falling monotonically) — coherent,
chronologically framed, and still wrong in the ordinary way:

> The theory of **prehistory is based on the idea that the earliest humans
> migrated through a region of Eurasia that was larger than present-day
> Europe. The pre-Han people were the first people to arrive in the area
> around the eighth century BCE. They established a trading network that
> included China, India and Australia.**

One architectural claim from earlier drafts deserves an explicit retraction.
The design story said position is carried by the GLA gates; measurement says
the gates never open at the shipped temperature — the fraction of gates above
0.9 is exactly 0.0000 in every GLA layer, and memory half-life is ~0.8 tokens,
so the GLA layers are very nearly memoryless. Two fix arms (gate temperature,
output norm) were measured on 2026-07-31 and both lost on loss, so both stay
off; the knobs are folded into the model identity with a backward-compatible
empty suffix (`backend/gpu/Main.hs`, `gateSuffix`). Long-range structure rides
on the three NoPE softmax layers. The evidence is in
`backend/src/FormalTransformer/Config.hs` and `run/gate-arms-2026-07-31/`.

## The previous run: all of English Wikipedia, once

The first trained model — 10,571,840 parameters, vocab 8,192 — consumed all
5,857,550 articles of English Wikipedia in one pass: 92 h on a rented RTX
5060 Ti, roughly $10–25. It reached **1.21 bits per byte** on held-out
Wikipedia prose and **1.99 bpb** on enwik8 against GPT-2-small's 1.16, so it
does not reach GPT-2-small quality; the gap is mostly the 8,192-piece
tokenizer shattering enwik8's raw MediaWiki markup into byte fallbacks — the
finding that motivated the current 32k tokenizer. Two flattering misreadings
of that run (the shard-ordered 1.107 final decile, and comparing in-domain
numbers to GPT-2's zero-shot benchmark) are dissected in the full record:
**[`docs/RUN-2026-07-25-WIKI-FULL.md`](docs/RUN-2026-07-25-WIKI-FULL.md)**.

Its weights are vendored in this repository, and `run/` is gitignored — from
a fresh clone, the vendored checkpoint is the one path that works immediately:

```bash
./weights/assemble.sh                    # reassemble the vendored checkpoint, verify SHA-256
nix run .#ana -- --prompt "The theory of" --tokens 256
```

## Generate

`ana` is offline by default — it makes no network call unless asked.
With no arguments it uses the last pulled checkpoint (`run/last-checkpoint`),
falling back to the newest architecture-compatible checkpoint under `run/`;
`--list` shows what is available locally. Decoding samples the next-token
distribution: `TEMPERATURE` (default 0.8), nucleus sampling via `TOP_P`
(default 0.95), `TOP_K` (off by default — top-p retains ≥ p of the mass by
construction, while a fixed k has no such floor; both proved in
`FormalTransformer/Language/Decoding.agda`), `SAMPLE_SEED` for
reproducibility, `TEMPERATURE=0` for exact greedy argmax. Trailing
whitespace is stripped from prompts before encoding (a space attaches to the
*following* word under this BPE, so a trailing space puts the prompt
off-manifold). Each response begins with the generating checkpoint's exact
training percentage and update count.

The tokenizer is discovered from the checkpoint: every checkpoint records its
tokenizer's identity (a hash over the merge list), and `ana` scans `run/*.bpe`
and `weights/*.bpe` for the artifact that matches. `--tokenizer` remains as an
override and still fails closed on an identity mismatch.

```bash
# pull the live run's newest checkpoint and sample it (CPU is fine)
nix run .#ana -- --pull --host root@HOST --port N \
  --remote-checkpoint /root/formalTransformer/run/wiki-bpe100m-global.checkpoint

# sample an already-pulled bpe100m checkpoint offline
nix run .#ana -- --prompt "The theory of"
```

`--pull` fetches into a per-host directory that can never overwrite existing
weights (`--user`, `--key`, `--checkpoint` are also available; see `--help`).

Generation runs the incremental decoder: GLA layers advance a fixed-size state
per token, and the softmax layers append to a ring-buffer KV cache (cache
order does not matter without positional encodings, so the ring needs no
reindexing). Feeding a sequence token-by-token reproduces every row of the
batch forward to ~6e-9 — the proved `cache-run` law, numerically.

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
one checkpoint, one AdamW trajectory, and one cosine schedule across every
shard (304 in the current plan). Physical sharding is a bounded-memory detail,
not 304 separate runs.

A run's schedule is anchored at creation, and `TRAIN_BATCH` is *semantic*: it
enters the plan identity, so changing it needs a new plan. `MICRO_BATCH` and the
checkpoint/validation cadences are execution-only and never affect the
trajectory. Ingestion is generic — any dataset expressible as JSONL `{id, text}`
pipes through `prepare-bpe-stdin` with no code change. The mixed corpus itself
is built by `deploy/build-mixed-corpus.sh` (Wikipedia interleaved with
FineWeb-Edu via duckdb — interleaved, never concatenated, to avoid a
curriculum effect) and sharded by `deploy/plan-corpus.sh`, a linear-time
planner that replaced a quadratic rescan.

**On rented hardware the production path is the persistent trainer**: with
`PERSISTENT=1` (pinned in `deploy/bpe100m.env`), `deploy/train-cloud.sh` runs
`train-plan` — one process and one CUDA context across the whole plan, with
fdatasync'd checkpoints — instead of one process per shard.
`deploy/train-plan-gate.sh` proves the two modes agree byte for byte. A run's
full settings live in a tracked env file (`deploy/bpe100m.env`: size, run dir,
tokenizer, checkpoint path, batch sizes, `GEMM_NUMERICS=tf32`,
`GEMM_ORDERING=stream`), so a box is launched with
`TRAIN_ENV_FILE=deploy/bpe100m.env deploy/start-cloud-training.sh` and nothing
is decided ad hoc. `deploy/push-corpus.sh` streams shards in plan order
(`--partial-dir`, so a truncated transfer is never admitted),
`deploy/check-link.sh` gates on sustained transfer speed, and
`nix run .#watch-training` follows the remote log with SSH reconnect.

**Build locally, never on the rented box.** The CUDA hosts need a GPU to run but
not to build, so `deploy/push-prebuilt.sh user@HOST PORT` compiles here and
rsyncs the runtime closure into the box's `/nix/store`; `cloud-init.sh` then
detects the binaries and skips its install and build. Compiling on the instance
instead cost ~50 minutes of paid GPU time every time. Before a long run,
`deploy/sweep-cuda.sh` records throughput, peak memory, GPU utilization, and
projected cost per completed run — on a 5090 the production configuration
measured 14,576 tok/s at 13.5% MFU and 54% utilization, and the sweep is why
`MICRO_BATCH=64` is pinned. See §8 of the run document for what to ask for
when renting.

## Build and verify

```bash
nix build .#formal-transformer            # CPU reference + CLI
nix build .#formal-transformer-multicore  # multicore C backend
nix build .#formal-transformer-cuda       # Futhark CUDA
nix build .#formal-transformer-gemm-cuda  # decomposed cuBLAS tensor-core trainer
nix build .#conformance                   # cross-backend numeric oracle
nix build .#gemm-conformance              # decomposed vs fused oracle vs Numeric.AD
```

Agda proofs build with `Everything.agda` under `--safe --without-K`. Beyond
the language and reverse-AD laws, the specification now covers decoding
(`Language/Decoding.agda`: top-p mass retention by construction, top-k's
lack of any distribution-independent floor), the tied output head
(`Transformer/TiedHead.agda`: the tied logit kernel is a symmetric Gram
matrix, so skew bigram preferences are unrepresentable by the head alone),
and residual-stream mixing (`Transformer/ResidualStream.agda`: mass
conservation under column-stochastic mixes, and n = 1 rigidity). The
conformance oracle relates the Haskell `Double` reference, the Futhark backends,
and `Numeric.AD` under component-specific tolerances — a tested refinement
relation, not an equality theorem over the reals. `formal-transformer
compare-checkpoint` diffs two checkpoints element-wise. What is proved, and the
trusted base that is *not*, are enumerated in the run document.

## Versions

A version number here is a **model generation**, because that is the
boundary that actually matters in this project: every architecture change is
a new model identity (checkpoint-incompatible), so changes batch at run
boundaries. MAJOR = a model generation; MINOR = a landed milestone inside it
(a completed run's results, a measurement campaign, a batch of spec
modules); PATCH = tooling and documentation fixes. Each tag is annotated,
and the annotation records the facts that tie the git state to the weights:
model config, parameter count, corpus plan, tokenizer identity, checkpoint
SHA-256, headline numbers.

| tag | generation |
|---|---|
| `v1.0.0` | before-the-wikipedia-run: the 10.5M-parameter first model — all of English Wikipedia in one pass, 1.21 bpb held-out (`docs/RUN-2026-07-25-WIKI-FULL.md`) |
| `v2.0.0` | the-wikipedia-run: the 115M hybrid and everything around it — the 32k tokenizer, the mixed corpus, the cloud training path, the decoding/tied-head/residual-stream specs. The master run is this generation; its final results will land as `v2.1.0`. |
| *(v3, in progress)* | ana-next, developed on the `ana-next` branch (cabal version 3.0.0 there; `master` stays 2.0.0 to match the running model). Planning basis: [`docs/ANA-NEXT-DESIGN-NOTES.md`](docs/ANA-NEXT-DESIGN-NOTES.md); decisions taken: [`docs/V3-DECISIONS.md`](docs/V3-DECISIONS.md). |

Version 3 carries no backward compatibility: its architecture lives in
`Config` (gate parametrization, qk-norm, head sinks), the layout version is
3, and the model identity prefix is `…-v3`. The `ana-next` binary neither
mints nor loads v2 checkpoints — the master run keeps being pulled and
sampled with the `master` branch's 2.0.0 binary.

## Scope

This repository proves structural language and reverse-AD laws, and tests
numeric backend agreement. It does not prove that IEEE floating point is real
arithmetic, that Futhark's compiler is correct, that optimization converges, or
that a trained model is accurate, truthful, or safe. The trained models have had
no post-training of any kind: they cannot follow an instruction, because they
have never seen one.
