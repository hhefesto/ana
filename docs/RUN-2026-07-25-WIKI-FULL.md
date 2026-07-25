# ana — the whole of English Wikipedia, once

A denotationally specified autoregressive transformer, written from a
mathematical specification in Agda, refined through a Haskell reference and
Futhark kernels, and trained end-to-end over every article of English
Wikipedia on a single rented consumer GPU.

This is the project's record: what was built, what was run, what came out, and
what it is worth against the state of the art. It supersedes the per-stage
documents that preceded it.

---

## 1. The model

| | |
|---|---|
| Preset | `bpe10m` — `Config {vocabSize = 8192, contextSize = 256, modelDim = 320, ffDim = 864, layerCount = 6, headCount = 5}` |
| Parameters | 10,571,840 |
| Attention | hybrid 3:1 — every 4th layer is softmax, the other five are gated linear attention (GLA) |
| Position | none in the softmax layers (NoPE); position is carried by the GLA gates |
| FFN | gated (SwiGLU-shaped): `wgate`, `wup`, `wdown` |
| Embeddings | tied (one `embedding` slice, no separate output head) |
| Head dim | 64 |
| Layout | `hybrid-gla-decoder-flat-parameters` version 2 |

**Why this shape.** The attention choice is derived, not assumed. Softmax
attention, RoPE softmax, linear attention, RetNet decay, GLA, and the delta rule
are one family, distinguished only by the state-transition operator; RoPE is the
data-*independent* special case of that operator, so a data-*dependent* family
already carries positional information and needs no rotation. The 3:1 hybrid
keeps a minority of softmax layers for the exact retrieval a finite state cannot
express. For a linear layer the recurrence `S_t = A_t·S_{t-1} + k_t v_tᵀ` is
online gradient descent on a stated objective over an associative memory —
gating is weight decay on the fast weights — so the update rule is a consequence
of a meaning rather than a postulate.

The practical payoff is decoding: GLA layers step with O(1) state per token, and
only the 1-in-4 softmax layers recompute over a bounded window.

**Parameter order.** Per block: `rms_att`, `wq`, `wk`, `wv`, `wo`, then `walpha`
for GLA blocks only, then `rms_ff`, `wgate`, `wup`, `wdown`. Matrices are
row-major. Only matrix and embedding leaves receive decoupled weight decay; RMS
gains do not. The count formula is enforced in four aligned places — an Agda
theorem, Haskell `paramCount`, the layout slices, and the Futhark entry types —
and the conformance oracle ties them together.

## 2. The data

| | |
|---|---|
| Source | English Wikipedia, `enwiki-natural-language.jsonl` (18.9 GB, one `{id, title, text}` per line) |
| Articles | 5,857,550 |
| Sharding | 1,465 shards of 4,000 articles |
| Split | 90/10 at the *document* level, per shard, by hash (`trainerValidationFraction = 0.1`) |
| Tokenizer | FastBPE, 8,192 pieces, `weights/enwiki-8k.bpe` (sha256 `756770e9…c09ea`) |
| Windows | `BOS : document ++ [EOS]`, cut into non-overlapping 256-token windows |
| Tokens seen | 1,833,157 × 8 × 256 = **3,754,305,536** (~3.75B), exactly one pass |

Non-overlapping windows mean every token is a next-token target at most once, so
consuming all windows consumes the training material exactly once. Documents
shorter than the window contribute nothing.

Physical sharding is a bounded-memory implementation detail, not 1,465 separate
runs: one checkpoint, one AdamW moment trajectory, and one cosine schedule span
the whole dataset. The schedule is anchored before step one by a plan that fixes
the dataset identity, the exact update count, the batch size, the
offset-invariant document split, and the cumulative shard endpoints:

```text
wikipedia-global-v1:sha256=989fe1b303e4ed03d9509e798b18973767619dd6c3a350af0b5bb6ea01123af7:articles=5857550:shard=4000:batch=8:size=bpe10m:tokenizer=756770e954ca1fc172f533b57e629ab7b0ef5a92c89c4e1d972a91e5c99c09ea
```

## 3. The run

| | |
|---|---|
| Optimizer | AdamW, lr 3e-4, β 0.9/0.999, ε 1e-8, wd 0.01, warmup 100, cosine → 0 over all 1,833,157 steps |
| Gradient clip | global norm 1.0 |
| Batch | `TRAIN_BATCH=8`, `MICRO_BATCH=8` |
| Numerics | `Tf32TensorCores` (f32 storage, TF32 cuBLAS compute) |
| Hardware | vast.ai RTX 5060 Ti 16 GB (Blackwell sm_120), driver 570.153.02, CUDA 12.8 |
| Runtime | decomposed cuBLAS GEMM trainer (`formal-transformer-gemm-cuda`) |
| Started | 2026-07-21 09:25 America/Mexico_City |
| Finished | 2026-07-25 05:33 America/Mexico_City |
| Wall clock | **92 h 08 min** |
| Throughput | ~11.3K tokens/s end to end (including per-shard corpus load and checkpoint I/O) |
| Model FLOPs | 6ND ≈ **2.38 × 10¹⁷** |
| Achieved | ~0.72 TFLOP/s ≈ **3.0% MFU** against 23.7 TFLOPS TF32 peak |
| Cost | roughly $10–25 of rental |

The 3% MFU is a consequence of model size, not of the runtime: at `modelDim` 320
the GEMMs are far too small to engage tensor cores, so the run is launch-bound.
The same runtime had already been taken through a 61× optimization ladder, every
rung gated on bit-identical loss.

**53.9% of the 1,833,157 steps hit the gradient clip.** For over half the run the
update was a normalized direction rather than the scheduled one. That is a real
hyperparameter to revisit, not something to carry forward unexamined.

### What had to be fixed first

The run only became possible after a CUDA miscompilation was found. At vocab
8192 the cross-entropy pullback `piece_ce_dlogits`, written as a nested
`tabulate` whose body produced a `[v]` array, was lowered by the CUDA backend
into mis-indexed output rows: the **loss was correct and the gradient was
garbage** (cosine ≈ −0.02 against the exact closed form). It was invisible at
conformance dimensions and invisible to max-abs summary statistics. Rewriting
the pullback as hoisted per-row softmax statistics plus one flat regular
tabulate fixed it — gradient cosine 1.000000 against the exact f64 form, and the
model descended 9.14 → below 7 within 1,000 steps.

The lesson generalizes: **verify kernels element-wise against an exact
reference, never through aggregate statistics.** A separate O(v²) recompute
hazard in the same pullback (a full vocab-length softmax recomputed per output
element) had earlier presented as a hang rather than as slowness.

## 4. Results

Held-out quality — documents the run never trained on — averaged per decile:

| decile | 10% | 20% | 30% | 40% | 50% | 60% | 70% | 80% | 90% | 100% |
|---|---|---|---|---|---|---|---|---|---|---|
| validation (nats/token) | 3.501 | 3.230 | 3.129 | 3.002 | 3.039 | 2.970 | 2.926 | 2.851 | 2.848 | **2.805** |
| bits per byte | 1.327 | 1.252 | 1.227 | 1.186 | 1.193 | 1.162 | 1.151 | 1.123 | 1.124 | **1.107** |

Train loss EMA fell 9.135 → 2.986. The full 2,379 validation observations are in
`docs/data/wiki-full-2026-07-25-validation.csv`; the complete 288 MB training log
is archived at `run/train-cloud-relaunch-2026-07-25.log.gz`.

**This table shows the trend, not the quality.** Two things disqualify it as a
measurement. Each observation sampled only 8 windows (~2,000 predictions), so a
single reading swings ±0.15 bpb — which is why the final log line's
`bits_per_byte=1.5257` should never be quoted. And each shard validates against
a *different* held-out split, so the deciles are not measurements of one thing:
because the dump is article-ordered, later deciles are scoring an easier
population, not only a better model. §6 measures the model properly and lands at
**~1.21 bpb**, not 1.107.

### Generations

Temperature 0.8, top-k 40, from the final checkpoint:

> The theory of relativity **of identification in the world is part of a single
> study by Soho and Stefan Rodman in 1983. / Background. / In addition to their
> first work in the field, Rodman, the author and researcher of the theory and
> evolution of the theory that identity is an important part of society's
> development, is not only a work but a major part of this study.**

> Paris is the capital of **the Dutch East India Company (VLC) operating in the
> southern states of South Sumatra and Botswana.**

> The Second World War began in **July and ended on 11 November 1942, when it
> fled to São José do Sul, where it was still under the control of the
> Lieutenant-Colonel.**

The register, grammar, and section structure of Wikipedia are learned. The facts
are not. That is the expected profile at 10.6M parameters: the model can
represent the *shape* of encyclopedic prose but cannot store the content of 5.9M
articles. Factual recall is a capacity problem, not a training defect.

## 5. How this compares to state-of-the-art training

**Scale.** 2.38 × 10¹⁷ FLOPs is ~1/1,300,000 of GPT-3 (3.1 × 10²³) and
~1/160,000,000 of Llama 3.1 405B (~3.8 × 10²⁵) — about eight orders of magnitude
below a frontier run. One consumer GPU for four days against tens of thousands of
accelerators for months; ~$20 against $10M–$1B+.

**The recipe is current, not dated.** 355 tokens/parameter is ~18× past the
Chinchilla-optimal 20:1 — deliberate, and the right call for a small model you
intend to actually run (Llama 3 sits near 1,875:1). The GLA/softmax hybrid is a
2024-25 architecture. And the run is more auditable than most published ones: an
anchored schedule, a dataset fingerprint inside the checkpoint identity, atomic
checkpoints, and kernels checked against an Agda specification and a
`Numeric.AD` oracle.

**Where it falls short of SOTA practice.** 256-token context against today's
8K–1M. No data engineering — no dedup, quality filtering, or mixture design. No
post-training at all: this is a raw base model, and it cannot follow an
instruction because it has never seen one.

**Against GPT-2-small, measured rather than argued.** On enwik8 — the benchmark
GPT-2 actually reported — this model scores **1.994 ± 0.019 bpb** against
GPT-2-small's **1.16** (§6). That is roughly 70% worse in bits, and it is the
only apples-to-apples comparison available. The project's stated objective of
GPT-2-small quality is **not met**.

The in-domain figure (~1.21 bpb on held-out Wikipedia prose) is the real
achievement, and should be quoted as what it is: strong for 10.6M parameters, on
the one domain the model was trained on, for about $20. It is not evidence about
GPT-2. An earlier reading of this run put the in-domain figure at 1.107 and
concluded the model was *ahead* of GPT-2-small; that was wrong twice over — the
1.107 was population-biased, and the comparison was never like-for-like.

**The Wikipedia-only ceiling is structural.** One language, one register, no
instructions, no dialogue, no code, no reasoning chains. And the data is now
spent: ~3.75B tokens is roughly 0.02–0.03% of a frontier mix and has been
consumed exactly once, so scaling further means finding more data, not more
epochs.

## 6. Measuring a checkpoint

In-run validation lines are unsuitable for a quality claim: they sample a few
windows, and in whole-dataset mode each shard validates against a *different*
held-out split, so no two observations are of the same thing.

For a number worth quoting, score a **fixed** corpus offline:

```bash
formal-transformer build-eval run/eval/wiki-heldout.corpus \
  run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv run/wiki-bpe10m 40 20
nix run .#wiki-eval
```

`build-eval` does not invent a split. It replays each shard's
`splitDocumentsFrom offset trainerSplitSeed trainerValidationFraction` — the same
call the trainer makes — and collects the validation side, so the corpus consists
of documents the run genuinely never trained on. Taking every `STRIDE`-th shard
spreads the sample across the whole dataset rather than a biased prefix.

`evaluate CHECKPOINT CORPUS` then scores **every** full window — no sampling —
and reports loss, bits per byte, and perplexity with a standard error. It
deliberately does not re-split the corpus (that would silently score 90% of an
already-held-out set). The checkpoint's manifest supplies the config, so the
command is self-describing, and a corpus whose tokenizer identity disagrees is
rejected rather than scored against the wrong vocabulary.

### What the fixed measurement found

Running this against the final checkpoint changed the headline number, and the
reason is worth stating plainly.

| held-out population | `build-eval` arguments | bits per byte | windows |
|---|---|---|---|
| **corpus-wide**, whole documents | `20 300` (every 300th shard) | **1.214 ± 0.024** | 730 |
| final 10 shards only | `10 1` over a 10-segment plan | 1.156 ± 0.041 | 146 |
| *training log, final decile* | *n/a — in-run sampling* | *1.107* | *8 per observation* |

(The standard errors above are already tight enough to separate the rows; the
`40 20` invocation shown earlier builds a 2,960-document, 8,789-window set that
narrows the corpus-wide figure further at ~10× the CPU cost.)

The training log's 1.107 is **not** Wikipedia-wide quality. The log's deciles are
ordered by training step, training step follows shard order, and the dump is
article-ordered — so the final decile is dominated by the stub tail of
Wikipedia. Held-out documents from the last shards average ~488 tokens against
~1,991 for a corpus-wide sample: a 4× length difference, and short stubs are
much easier to model.

Restricting the fixed measurement to that same late population reproduces the
log (1.156 ± 0.041 against 1.107, a 1.2σ difference), which is what confirms the
split reconstruction is correct rather than buggy. Widening it to the whole
corpus gives **~1.21 bpb**. That is the number for this model.

The correction is not small enough to ignore: it moves the model from *slightly
ahead of* GPT-2-small's 1.16 to *slightly behind* it — and that comparison was
already tilted in this project's favour, since 1.21 is in-distribution and
GPT-2's 1.16 is zero-shot on a different corpus. A generous reading and a strict
reading now agree that this model does not reach GPT-2-small.

This is the entire reason step 1 came before scaling: the instrument disagreed
with the headline by more than the improvement any single next step would buy.

### The external benchmark: enwik8

The in-domain number still cannot be compared to a published model, because
every figure above is measured on the corpus family the model trained on. So
score the benchmark GPT-2 actually reported — enwik8's conventional test split,
the last 5 MB of the 100 MB file (md5 `a1fa5ffd…bb36a`), scored whole:

| model | parameters | enwik8 BPB |
|---|---|---|
| this model | 10.6M | **1.994 ± 0.019** (7,339 windows, 1,871,445 predictions) |
| GPT-2 small | 117M | 1.16 |
| GPT-2 large | 762M | 0.97 |

**It is not close.** Against the one measurement that is actually comparable,
this model is at 1.99 where GPT-2-small is at 1.16 — not slightly behind, but
roughly 70% worse in bits.

The gap is mostly domain, not merely scale. enwik8 is raw MediaWiki *XML*:
templates, link syntax, and tags. This model was trained on extracted natural
language, and its 8,192-piece tokenizer was learned on that same clean text, so
markup shatters into byte fallbacks — enwik8 tokenizes at 2.66 bytes/token here
against 3.98 on Wikipedia prose. GPT-2 saw markup-rich WebText and a 50,257-piece
vocabulary. So the comparison is unflattering for a reason that would partly
survive scaling: **the corpus, not just the parameter count, is the limit.**

Read together, the three figures tell the honest story:

- **1.21 bpb** on held-out Wikipedia prose — genuinely good for 10.6M parameters
- **1.16 bpb** — GPT-2-small, on a benchmark this model scores 1.99 on
- **1.99 bpb** on that benchmark — what the model is worth outside its
  distribution

The first number is the achievement. The third is the ceiling. Any claim that
this run "reaches GPT-2-small quality" is false, and the earlier 1.107 reading
made that false claim look supported.

## 7. Using the trained model

The weights are vendored in this repository, split into sub-50 MB parts because
GitHub rejects files over 100 MB:

```bash
./weights/assemble.sh        # reassembles run/wiki-bpe10m-global.checkpoint, verifies SHA-256
nix run .#wiki-generate      # asks for a prompt
nix run .#wiki-generate -- --prompt "The theory of" --tokens 256
```

`wiki-generate` is offline by default: with no arguments it uses the last pulled
checkpoint (`run/last-checkpoint`), falling back to the newest compatible
checkpoint under `run/`. Decoding samples the next-token distribution —
`TEMPERATURE` (default 0.8), `TOP_K` (default 40), `SAMPLE_SEED` for
reproducibility, `TEMPERATURE=0` for exact greedy argmax. Each response begins
with the generating checkpoint's exact training percentage and update count.

Generation runs the incremental decoder: each GLA layer advances a fixed
`[d][hd]` state, each NoPE softmax layer appends to a ring-buffer KV cache of the
trailing window (NoPE means cache order does not matter, so the ring needs no
reindexing). Feeding a sequence token-by-token reproduces every row of the batch
forward to ~6e-9 — the proved `cache-run` law, numerically.

To pull weights from a training box, everything needed is an argument:

```bash
nix run .#wiki-generate -- --pull --host user@10.0.0.5 --port 56861 --key ~/.ssh/id
```

A pull lands in `run/pulled-HOST-PORT-checkpoints/`, never on top of an existing
checkpoint, so one box's weights can never overwrite another's or a finished
run's.

## 8. Training again

```bash
nix run .#wiki-train                       # consume the entire local dataset
WIKI_BACKEND=cuda nix run .#wiki-train     # NVIDIA CUDA
TRAIN_BATCH=8 nix run .#wiki-train
WIKI_CORPUS=my.corpus nix run .#wiki-train # single-corpus mode
```

`wiki-train` defaults to `WIKI_BACKEND=multicore`. Backends share one checkpoint
format, so a run started on one continues on another. On rented hardware,
`deploy/train-cloud.sh` drives `train-segment` per shard directly from a
pre-built plan, bypassing the 18 GB source JSONL.

**Contract notes.** A run's schedule is anchored at creation, and `TRAIN_BATCH`
is *semantic* — it enters the plan identity, so changing it requires a new plan.
`MICRO_BATCH`, checkpoint cadence, and validation cadence are execution-only:
they never affect the trajectory. Each micro-chunk's adjoints are seeded with
one over the effective batch inside the kernel, so accumulated chunks equal the
full-batch gradient up to f32 summation order — the `batch-pullback` theorem,
checked by the conformance oracle.

Ingestion is generic: any dataset expressible as JSONL `{id, text}` can be piped
through `prepare-bpe-stdin`. The corpus format stores tokens as `Word16`, so
vocabulary is capped at 65,535.

### Building a corpus and a tokenizer

```bash
# 1. assemble sources, interleaved
deploy/build-mixed-corpus.sh run/mixed-corpus.jsonl WIKI.jsonl run/c4 3 4
# 2. learn a tokenizer from a sample of it
formal-transformer learn-bpe run/mix-32k.bpe 32768 3 < sample.nul
# 3. shard and plan in one pass
TOKENIZER=run/mix-32k.bpe deploy/plan-corpus.sh \
  run/mixed-corpus.jsonl run/mixed-bpe100m bpe100m 64 4000
```

Three things about this pipeline are easy to get wrong and were:

**Interleave, never concatenate.** The trainer consumes shards in file order
under one cosine schedule, so concatenating sources makes the run a curriculum —
all encyclopedia first, all web text last. This run is the cautionary case: the
Wikipedia dump is article-ordered, its final shards are the stub tail, and
reading the log's last decile as "quality" overstated it by ~0.1 bpb (§6).
Interleaving makes every shard, held-out split, and loss-curve point a
representative sample.

**`wiki-train`'s planner is quadratic.** It extracts each shard with
`awk 'NR>b{exit} NR>=a' "$data"`, rescanning from line 1 every time. At 18.9 GB
and 1,465 shards that survived only because the file fits in page cache — and it
is the likely explanation for corpus preparation appearing to take three days
when tokenizing itself takes 2.3 hours. At 37 GB it would read tens of terabytes.
`plan-corpus.sh` splits once instead; the plan format is unchanged.

**Two silent failure modes.** jq's `input_line_number` is not a record counter —
it repeats a value at record 11243 of C4 shard 0, and a duplicate document id
invalidates a whole corpus artifact, but only when that shard is prepared,
thousands of shards later. And `prepare-bpe-stdin` reports failures on stdout
while still exiting 0, so discarding its output turns a rejected shard into a
misleading "corpus file not found" much further downstream.

### Learning a tokenizer

`learn-bpe VOCABULARY [MIN_FREQUENCY]` trains from the word-frequency table, so
its cost is set by the number of distinct words rather than corpus size, and the
corpus is streamed without being retained. It calls the same `pretokenize` the
encoder calls, so trainer and encoder agree on what a word is by construction —
an external trainer with its own pretokenization would emit merges the encoder
can never apply, and that failure would be silent.

`MIN_FREQUENCY` matters on web text: the unfiltered table reached 15.6 GB
resident on a 370 MB Wikipedia+C4 sample and was still climbing, because URLs,
hashes and typos dominate the *distinct*-word count while carrying weight 1
against merges whose weights run to millions. At frequency ≥ 3 that sample keeps
449,829 of 1,818,202 words and trains in under four minutes.

### GEMM numerics

`formal-transformer-gemm-cuda` selects the GEMM interpretation explicitly, and it
is recorded in the checkpoint manifest (resume rejects a mismatch; pre-v3
checkpoints decode as `Fp32IEEE`):

```text
GEMM_NUMERICS=fp32  -> CUBLAS_COMPUTE_32F_PEDANTIC
GEMM_NUMERICS=tf32  -> CUBLAS_COMPUTE_32F_FAST_TF32
GEMM_NUMERICS=bf16  -> CUBLAS_COMPUTE_32F_FAST_16BF
```

The rental driver must advertise Max CUDA at or above the flake's pinned toolkit
(currently 12.8). Gates before trusting a new card: `inspect` (context creation
and parameter count), `cuda-blas-test` (all three numerics), then `bench` with
`BENCH_PEAK_TFLOPS` for a measured MFU.

## 9. How it is verified

The claim is a *tested refinement relation*, not total verification. Agda's
theorems are exact and structural; Haskell uses `Double`, Futhark uses `f32`, and
a conformance oracle relates them under component-specific tolerances.

**Proved in safe Agda** (`--safe --without-K`, plus `--guardedness` for the
coinductive trie modules): left-fold composition over append; weighted-language
residual laws and determination by `nu`/`delta`; state-run composition and
autoregressive path factorization; finite one-step mass under `Distribution`;
reverse-derivative identity, composition, chain, and pairing equations; the
parameter-count formula; the coinductive trie/extensional correspondence with
bisimulation soundness and completeness; `addD`/`batchD` primal-sum and
pullback-accumulation with the mean-loss corollary; and for GLA over an abstract
semiring — `recurrent≡parallel`, the chunk boundary law `runGLA-++`, the
chunkwise recurrence `chunk-closed` that licenses chunked execution of the same
meaning, the packaging of GLA as a `StateAlgebra` whose state is one dk×dv matrix
independent of prefix length, and `cache-run`, the first concrete discharge of
the abstract KV-cache law by a model-shaped state.

**The trusted base**, stated rather than hidden: the Agda kernel and standard
library; law instances supplied to the algebraic records; analytic derivative
witnesses via `TrustedAnalytic`; Haskell `Double`, `Numeric.AD`, `binary`, and
the RTS; Futhark's `vjp2`, compiler, and generated runtimes; the numeric
tolerance relation itself; filesystem atomic-rename semantics; and the
non-cryptographic dataset fingerprint, which detects accidental mismatch and is
not a security boundary.

**Below the transformer** sits the exact-counts bigram — the minimal finite state
algebra over the vocabulary, an exact sufficient-statistics instance of the same
weighted-language semantics — sharing the trainer's split and windowing, as the
honest floor for validation loss.

## 10. Artifacts

| artifact | path |
|---|---|
| final weights | `run/wiki-bpe10m-global.checkpoint` (read-only) |
| verified backup | `run/wiki-bpe10m-global.100pct-2026-07-25.checkpoint` (read-only) |
| vendored, in git | `weights/wiki-bpe10m-global.checkpoint.part-0{0,1,2}` + `weights/SHA256SUMS` |
| tokenizer | `weights/enwiki-8k.bpe` |
| full training log | `run/train-cloud-relaunch-2026-07-25.log.gz` (43 MB; 301,570,426 bytes, 1,841,400 lines) |
| validation curve | `docs/data/wiki-full-2026-07-25-validation.csv` |
| evaluation corpora | `run/eval/wiki-heldout.corpus`, `run/eval/enwik8-test.corpus` |
| corpus shards | `run/wiki-bpe10m/shard-*-bpe10m.corpus` (1,465, 9.3 GB) + `.done` markers |
| plan | `run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv` |
| source dump | `~/datasets/wikipedia-en/enwiki-natural-language.jsonl` (18.9 GB) |

Every checkpoint copy is sha256
`ae775082a0c310422020fe063459ea280b9c1d6e777b3d710c962cdc5d145018`. All were
verified before the rented box was destroyed, and nothing in the repository
depends on that host existing.

## 11. Next steps

1. **Measure properly** — **done** (§6). A fixed held-out set, an `evaluate`
   command that samples nothing, standard errors on every figure, and one
   external benchmark. Everything below is now judgeable; nothing below was
   before.

   Its first result reorders the rest. The in-domain/external gap (1.21 vs
   1.99) is far larger than anything one scaling step buys, and most of it is
   corpus and tokenizer, not parameter count — a 10.6M model at 3.98
   bytes/token on prose drops to 2.66 on markup. So **step 3 is now at least as
   urgent as step 2**, and running step 2 alone would produce a bigger model
   with the same ceiling.
2. **Scale parameters, not epochs** — preset landed as `bpe100m`,
   `Config 32768 256 768 2048 12 12`, 115,428,096 parameters. The vocabulary
   moved from 8192 to 32,768 (25.2M of the budget, embeddings being tied),
   which is what takes it to GPT-2-small scale and stops markup shattering. On the same 3.75B
   tokens that is ~39 tokens/param, still a good regime, and ~2.17 × 10¹⁸ FLOPs
   — hours on an A100/H100, gated on a measured `bench` MFU. Batch should rise to
   ~64 (semantic: needs a new plan), warmup from 100 to ~2,000 steps, and the
   gradient clip revisited given the 53.9% clip rate.
3. **Broaden the corpus.** Ingestion is already generic; the real work is a
   retrained, larger tokenizer (16k–32k), which changes the checkpoint identity
   and so means a fresh run. Bits per byte stays comparable across tokenizers,
   which is why it is the metric of record.
4. **Longer context**, with a caveat that must be tested first. The softmax
   layers are NoPE, and the decoder exploits the resulting permutation
   invariance over the cache. At 256 tokens this works. At 1024 those layers may
   lose the position-sensitive retrieval they exist to provide, so ablate
   NoPE-vs-RoPE at `gla-small` scale (four arms, ~2,000 steps, hours) before
   baking the choice into an expensive run. If NoPE holds at 1024 that is a
   result worth publishing; if not, adding RoPE to the softmax layers is a
   contained change plus a `modelId` bump.
