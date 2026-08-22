# v4: 463M parameters, two GPUs, a code-aware corpus

The v3 run ended by decision on 2026-08-21 at step 8,019/358,276. This is the
design record for its successor: four times the parameters, two rented GPUs,
context 1024, and a corpus that contains the languages the user actually writes
(Haskell, Agda, Lean, Nix) alongside English prose.

Two goals, and they pull in different directions on a fixed vocabulary budget:
beat GPT-2-small's **1.16 bpb on enwik8**, and be qualitatively useful as a
coding agent. Where they conflict, both are measured rather than traded
silently.

## Decisions

| | choice | why not the alternative |
|---|---|---|
| Two-GPU | DiLoCo periodic averaging, H=30 | A per-step NCCL all-reduce is exact, but it needs Haskell NCCL bindings and device-pointer plumbing. Averaging needs neither: the gradient already makes a full host round trip here. arXiv:2503.09799 swept exactly the M=2 case; arXiv:2505.23725 covers Muon as the inner optimizer. |
| Size | d=1280, ff=3456, 20 layers, 20 heads | 463,084,260 parameters, 4.012× the v3 rung. `ffDim` is 3456 rather than the 3413 that would hit exactly 4.00× because 3456 = 27·128 tiles cleanly. |
| Context | 1024, gated on an ablation | Softmax layers are NoPE. If the ablation says the extra context is not being used, RoPE gets ported (user decision) rather than falling back. |
| Vocabulary | stays 32,768 | Corpus tokens are `Word16`, so 65,535 is the hard cap; a wider vocabulary also grows the logits activation, already the largest per-sample term at context 1024. |
| Budget | ~1 epoch, Chinchilla scale | The cosine schedule is derived from the plan's total steps, so run length is decided before the corpus is planned and cannot be extended later. |

**Two GPUs give throughput, not memory.** Data parallelism replicates the model
per device, so 463M plus Muon state has to fit on one card. That, not the GPU
count, is what fixes the model size.

## Measurements taken while designing this

**Document packing roughly doubles the usable corpus at context 1024.**
The trainer cuts documents into non-overlapping windows and discards the
remainder, so a document shorter than one window contributes nothing at all.
Measured **exactly, over all 9,700,651 documents** of `run/mixed-corpus.jsonl`
(36.38 GB of text, mean 3,750 B/document) at the 4.709 bytes/token this corpus
and tokenizer actually achieve:

| | ctx 256 | ctx 512 | ctx 1024 |
|---|---|---|---|
| documents yielding no window at all | 32.5% | 56.1% | **79.7%** |
| bytes surviving `fullWindows` | 84.3% | 71.1% | **51.6%** |

Confirmed end to end rather than by simulation: planning the same 24,191
documents through `plan-corpus.sh` with and without `PACK_TARGET=131072`
gives

| | ctx 256 | ctx 1024 |
|---|---|---|
| train windows, unpacked | 57,409 | 8,710 |
| train windows, packed 128 KB | 67,818 | 16,732 |
| gain | **1.18x** | **1.92x** |

At context 1024 that is the difference between ~4.0B and ~7.6B usable tokens
on this corpus — the whole distance between well under Chinchilla scale for
463M and roughly at it once Phase B is added. Packing is a required component,
not an optimization.

The same applies retroactively: at context 256, where v2 and v3 trained, 32.5%
of documents never produced a single window and ~16% of bytes were never seen.

**Two sampling errors were made getting to this number, and both are worth
recording because they are the same mistake in different clothes.** The first
estimate sampled the head of the file and put the context-1024 loss at 24.5%;
Wikipedia is article-ordered with a stub tail, so the head runs 2.2x larger
than the corpus mean. The correction sampled every 25th document — but
`mixed-corpus.jsonl` is a 3:2 wiki/FineWeb **interleave with period 5**, and 25
is divisible by 5, so it locked onto one phase of the cycle and returned 99%
FineWeb against the true 60/40 split. A stride must be coprime with any period
in the data; 401 gives 60.4% wiki, matching the interleave. The safest move,
taken here, is not to sample at all: one `jq` pass over 36 GB costs minutes and
removes the question.

**No existing eval corpus could measure the v2/v3 models.** `evaluate` gates on
the corpus's tokenizer identity matching the checkpoint's, and:

| corpus | vocabulary | tokenizer |
|---|---|---|
| `wiki-heldout`, `wiki-heldout-late`, `enwik8-test` | 8,192 | the bpe10m-era tokenizer |
| `enwik8-test-32k` | 32,768 | `enwiki-c4-32k.bpe`, **superseded** |
| what v2 and v3 actually trained on | 32,768 | `enwiki-fineweb-32k.bpe` (`sha256=60b05337…`) |

Nothing matched. This is why the 32k models' enwik8 number was never recorded —
there was no corpus it could be measured on, and the 1.99 bpb figure in the
project notes belongs to the 8k era. Rebuilt against the training tokenizer:

- `run/eval/enwik8-test-fw32k.corpus` — the last 5,000,000 bytes of enwik8,
  1,583,148 tokens (3.16 bytes/token).
- `run/eval/wiki-heldout-fw32k.corpus` — 960 documents, 871,385 tokens, built by
  `build-eval` replaying the trainer's own split, so it is genuinely held out.

bpb is bits per *byte*, so these numbers stay comparable across tokenizer
changes and against GPT-2-small. That is what makes the whole comparison valid.

## The two-process protocol

Each rank trains normally on a disjoint half of every global batch for H inner
steps; then the ranks average parameters and take one outer Nesterov step on
the pseudo-gradient `theta_prev - theta_averaged`. Only parameters cross
between ranks — the inner optimizer moments stay local.

The invariant everything leans on: **both ranks compute bit-identical outer
state.** They sum in a fixed rank order (never "mine then theirs") from values
exactly representable as f32, so the average, the momentum and the new
parameters agree to the bit forever. Hence the momentum is never exchanged, and
hence a digest comparison across ranks is a real check rather than a
coincidence — `deploy/diloco-check.sh` is the standing alarm.

Consequences that are easy to get wrong:

- **One rank writes checkpoints.** Two saves at 463M would want ~35 GB of host
  memory each at the same instant. The parameters are identical at every
  synchronization anyway; the follower re-reads rank 0's file.
- **Shard boundaries are a barrier.** `trainInContext` reloads the checkpoint
  from disk for every shard, so the follower must wait for rank 0 to finish
  renaming it into place. The segment's last step always synchronizes, so the
  parameters behind that file are already the ones both ranks hold.
- **Two processes, never two threads.** `CudaBlasOps` caches one
  process-global cuBLAS handle with no destroy path. Ranks are separated with
  `CUDA_VISIBLE_DEVICES`, which is also the only thing that makes the GEMM
  backend address a specific device — it does not read `FUT_DEVICE`. Each rank
  also needs its own `FUT_CACHE`.
- **A missing peer stops the run.** Continuing alone would halve the effective
  batch and quietly change the experiment.

`TRAIN_BATCH` stays **global**: it is in the plan identity and sets the
segment's step count, so it has to mean the same thing at any world size. What
changes is how much of each batch a rank computes.

### The regression test that makes this safe

At outer lr 1 with no momentum the outer step returns the averaged parameters
unchanged, so with a single rank it is the identity. A run with the machinery
switched on that way therefore has to produce a byte-identical checkpoint to a
run without it — which exercises download, average, outer step and upload all
at once. Verified on the sequential (byte-exact) backend: both runs give
`sha256 10e794f8…`. Two ranks at H=1 then agreed on all 95 outer digests while
the loss fell 5.619 → 5.258, a peer timeout stopped the run with a clear message
and wrote no checkpoint, and the drift monitor caught an injected mismatch.

## Pretokenization is now a property of the artifact

The v1 rule splits words on space and newline and makes every space beyond the
first in a run its own one-byte word, so a four-space indent is four tokens and
no merge can ever shorten it. The v2 rule keeps a run of spaces together
(newline-prefixed when one precedes it), handing only the run's last space to
the following word — so indentation becomes one learnable piece while ordinary
prose cuts exactly where it did before.

The rule travels in the `.bpe` header and in the identity string rather than
being compiled in. Merges learned under one rule are meaningless under another,
and the failure would be silent; and an artifact written before the field
existed reads as v1, which is what keeps every corpus and checkpoint produced
so far loadable. A v1 artifact is written by omitting the field, so its bytes
and its sha256 — which live run plans record by value — do not move.

`BPE_PRETOKEN=v1` reproduces a pre-2026-08 tokenizer exactly; new ones default
to v2.

## Sequencing constraints

- **Measure the v2/v3 baselines before adding any `Config` field.** `modelId` is
  `show cfg`, so a new field changes the identity of every preset and locks out
  the existing checkpoints. Adding a preset is safe; adding the RoPE arm is not.
- **`contextSize` left `Layout.core`.** No slice in the layout depends on it —
  there is no positional embedding — so refusing a warm start across contexts
  forbade a transfer that is sound by construction. It stays in `Config`, and
  hence in `modelId`, so the runs remain distinct identities.
