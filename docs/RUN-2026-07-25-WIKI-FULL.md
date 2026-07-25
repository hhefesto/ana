# RUN 2026-07-25 — the whole of English Wikipedia, once

The first complete pass over the full English Wikipedia dump. Every one of the
1,465 planned shards was consumed under a single anchored cosine schedule and a
single AdamW moment trajectory, finishing at global step 1,833,157 of 1,833,157.

This is the run the repository was built for. It is also the last run on rented
hardware: the box was destroyed after the artifacts below were verified local.

## Configuration

| | |
|---|---|
| Model | `bpe10m` GLA hybrid — `Config {vocabSize = 8192, contextSize = 256, modelDim = 320, ffDim = 864, layerCount = 6, headCount = 5}` |
| Attention | every 4th layer softmax, the other five gated linear attention (`isSoftmaxLayer`, `backend/src/FormalTransformer/Config.hs:84`) |
| Parameters | 10,571,840 |
| Tokenizer | FastBPE, 8,192 pieces, `weights/enwiki-8k.bpe` (sha256 `756770e9…c09ea`) |
| Corpus | 5,857,550 articles → 1,465 shards of 4,000; 90/10 document-level split (`trainerValidationFraction = 0.1`) |
| Windows | non-overlapping, 256 tokens, every token a target at most once |
| Tokens seen | 1,833,157 × 8 × 256 = **3,754,305,536** (~3.75B), exactly one pass |
| Optimizer | AdamW lr 3e-4, β 0.9/0.999, ε 1e-8, wd 0.01, warmup 100, cosine → 0 over the full 1,833,157 steps |
| Gradient clip | global norm 1.0 |
| Batch | `TRAIN_BATCH=8`, `MICRO_BATCH=8` |
| Numerics | `Tf32TensorCores` (f32 storage, TF32 cuBLAS compute) |
| Cadence | `CHECKPOINT_EVERY=2000`, `VALIDATE_EVERY=2000`, `VALIDATION_WINDOWS=8` |

Run identity, fixed before step one and carried in every checkpoint:

```text
wikipedia-global-v1:sha256=989fe1b303e4ed03d9509e798b18973767619dd6c3a350af0b5bb6ea01123af7:articles=5857550:shard=4000:batch=8:size=bpe10m:tokenizer=756770e954ca1fc172f533b57e629ab7b0ef5a92c89c4e1d972a91e5c99c09ea
```

## Execution

| | |
|---|---|
| Hardware | vast.ai RTX 5060 Ti 16 GB (Blackwell sm_120), driver 570.153.02, CUDA 12.8 |
| Runtime | decomposed cuBLAS GEMM trainer (`formal-transformer-gemm-cuda`) |
| Started | 2026-07-21 09:25 America/Mexico_City |
| Finished | 2026-07-25 05:33 America/Mexico_City |
| Wall clock | **92 h 08 min** |
| Throughput | ~11.3K tokens/s end-to-end (including per-shard corpus load and checkpoint I/O) |
| Model FLOPs | 6ND ≈ **2.38 × 10¹⁷** |
| Achieved | ~0.72 TFLOP/s ≈ **3.0% MFU** against 23.7 TFLOPS TF32 peak |
| Cost | roughly $10–25 of rental |

The 3% MFU is a consequence of model size, not of the runtime: at `modelDim`
320 the GEMMs are far too small to engage tensor cores, so the run is
launch-bound. The same runtime delivered the 61× ladder in
`docs/RUN-2026-07-20-TENSOR-CORE.md`.

## Result

Final artifact, sha256 `ae775082a0c310422020fe063459ea280b9c1d6e777b3d710c962cdc5d145018`
(126,862,993 bytes), vendored under `weights/` and reassembled by
`weights/assemble.sh`.

Held-out quality — documents never trained on — averaged per decile of the run.
The full 2,379 observations are in
`docs/data/wiki-full-2026-07-25-validation.csv`:

| decile | 10% | 20% | 30% | 40% | 50% | 60% | 70% | 80% | 90% | 100% |
|---|---|---|---|---|---|---|---|---|---|---|
| validation (nats/token) | 3.501 | 3.230 | 3.129 | 3.002 | 3.039 | 2.970 | 2.926 | 2.851 | 2.848 | **2.805** |
| bits per byte | 1.327 | 1.252 | 1.227 | 1.186 | 1.193 | 1.162 | 1.151 | 1.123 | 1.124 | **1.107** |

Train loss EMA fell 9.135 → 2.986. Final held-out ≈ **1.107 bpb**, ≈16.5
perplexity per token, ~3.66 bytes per BPE token.

**Do not quote the last log line's `bits_per_byte=1.5257`.** Each observation
samples only `VALIDATION_WINDOWS=8` windows (~2,000 predictions), so a single
reading swings ±0.15 bpb; the final step happened to draw a hard sample. The
decile means above are the figures with standing. Raising
`VALIDATION_WINDOWS` is the cheapest measurement improvement available.

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

The register, grammar, and section structure of Wikipedia are learned. The
facts are not. That is the expected profile at 10.6M parameters: the model can
represent the *shape* of encyclopedic prose but cannot store the content of
5.9M articles. Factual recall is a capacity problem, not a training defect.

## How this compares to state-of-the-art training

**Scale.** 2.38 × 10¹⁷ FLOPs is ~1/1,300,000 of GPT-3 (3.1 × 10²³) and
~1/160,000,000 of Llama 3.1 405B (~3.8 × 10²⁵) — about eight orders of
magnitude below a frontier run. One consumer GPU for four days against tens of
thousands of accelerators for months.

**The recipe is current, not dated.** 355 tokens/parameter is ~18× past the
Chinchilla-optimal 20:1 — deliberate, and the right call for a small model you
intend to actually run (Llama 3 sits near 1,875:1). The GLA/softmax hybrid is a
2024-25 architecture, not a 2019 vanilla transformer. And the run is more
auditable than most published ones: an anchored schedule, a dataset fingerprint
inside the checkpoint identity, atomic checkpoints, and kernels checked against
an Agda specification and a `Numeric.AD` oracle.

**Where it falls short of SOTA practice.** 256-token context against today's
8K–1M. No standard eval harness, so no directly citable comparison. No data
engineering — no dedup, quality filtering, or mixture design. No post-training
at all: this is a raw base model, and it cannot follow an instruction because
it has never seen one.

**Against GPT-2-small, carefully.** 1.107 bpb held out is in the neighbourhood
of GPT-2-small's reported 1.16 BPB on enwik8, from a model 11× smaller. But
GPT-2's number is zero-shot on a different corpus, while this is measured
in-distribution on held-out documents of the corpus family it trained on, and
on cleaned text rather than enwik8's markup. The supportable claim is
*GPT-2-small-like bits-per-byte on the one domain it was trained on* — not
GPT-2-small quality. On code, dialogue, or news it would be far worse.

**The Wikipedia-only ceiling is structural.** One language, one register, no
instructions, no dialogue, no code, no reasoning chains. And the data is now
spent: ~3.75B tokens is roughly 0.02–0.03% of a frontier mix and has been
consumed exactly once, so scaling further means finding more data, not more
epochs.

## Next steps, in value order

1. **Measure properly.** A standard harness and a large fixed validation set,
   so quality claims become citable. `VALIDATION_WINDOWS=8` is the current
   bottleneck on knowing anything precisely.
2. **Scale parameters, not epochs.** The data is spent; ~100M parameters on the
   same 3.75B tokens stays near compute-optimal and is roughly where factual
   recall begins to appear.
3. **Broaden the corpus.** Books, web, and code are what unlock anything beyond
   encyclopedic register.
4. **Longer context.** 256 tokens under-uses the GLA architecture's main
   advantage — O(1)-state decoding only pays when the context is long.

## Artifacts and teardown

Everything needed to reproduce or continue is local:

| artifact | path |
|---|---|
| final weights | `run/wiki-bpe10m-global.checkpoint` (read-only) |
| verified backup | `run/wiki-bpe10m-global.100pct-2026-07-25.checkpoint` (read-only) |
| vendored, in git | `weights/wiki-bpe10m-global.checkpoint.part-0{0,1,2}` + `weights/SHA256SUMS` |
| full training log | `run/train-cloud-relaunch-2026-07-25.log.gz` (43 MB; 301,570,426 bytes, 1,841,400 lines) |
| validation curve | `docs/data/wiki-full-2026-07-25-validation.csv` |
| corpus shards | `run/wiki-bpe10m/shard-*-bpe10m.corpus` (1,465, 9.3 GB) + `.done` markers |
| plan | `run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv` |
| source dump | `~/datasets/wikipedia-en/enwiki-natural-language.jsonl` (18.9 GB) |

All three checkpoint copies were confirmed at sha256 `ae775082…5018` before the
rented box was destroyed. `wiki-generate` no longer contacts any box unless
asked, so nothing in the repository depends on that host existing.
