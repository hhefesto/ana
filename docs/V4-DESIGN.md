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

## The baseline v4 has to beat

Measured 2026-08-21 on the CPU `multicore` backend -- `evaluate` is the same
`backend/gpu/Main.hs` that backend compiles, so it needs no GPU, running at
~7.8 s/window. Population: 32 slices of 8 KB spread evenly across the last
5,000,000 bytes of enwik8, 305 windows, 77,775 predictions, both models scored
on identical windows.

| model | trained | enwik8 bpb |
|---|---|---|
| v2 final (step 336,872) | 94% of its schedule | **1.337 ± 0.043** |
| v3 final (step 8,000) | 2.2% of its schedule | 1.450 ± 0.043 |
| GPT-2-small | — | 1.16 |
| v1 (10.6M, 8k vocab) | — | 1.994 |

**The gap to the objective is 0.18 bpb, not the 0.83 the project notes carried.**
Retiring the 8k tokenizer for 32k pieces did almost all of the work; the 1.994
figure belongs to the 8k era and should not be quoted for anything after it.

That v3 reached 1.450 at 2.2% of its schedule, against v2's 1.337 at 94%, says
the v3 architecture was on a much better trajectory when the run was stopped by
decision.

This is a spread sample rather than the full test split, so it carries a
±0.043 standard error; the exact figure costs about a minute on a GPU and
should be taken at the next rental. The paired v2-vs-v3 difference is much
tighter than the absolute numbers, because both ran the identical windows.

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

**Measured 2026-08-21, and it clears its gate by a wide margin.** Two 32,768-piece
tokenizers were learned from one identical 200 MB sample (91 MB of Wikipedia and
FineWeb prose sampled at stride 401, 109 MB of Haskell, Nix and Agda from local
repositories), differing only in `BPE_PRETOKEN`. Held-out sets are disjoint from
both: 2,500 unseen documents of prose, and every 16th source file of code.

| held-out set | bytes/token v1 | bytes/token v2 | change | gate |
|---|---|---|---|---|
| code (Haskell/Nix/Agda) | 2.750 | **3.835** | **+39.5%** | >= 30% |
| Wikipedia prose | 4.4873 | 4.4856 | **-0.04%** | <= 1% regression |

Code costs 28% fewer tokens for the same bytes, and prose is unchanged to
within a twentieth of a percent -- the shared 32,768-piece budget did not have
to be bought from English after all. The effect is visible before any merge is
learned: the same sample yields 40.6M pretokenized words under v1 and 30.2M
under v2, because a run of spaces stops being one word per space.

One claim from the plan is corrected here: "prose is unchanged" holds for
MID-LINE prose only.  V2 deliberately folds trailing whitespace ("x  \n" is
four v1 words but three v2 words), and real Wikipedia text contains trailing
spaces and whitespace-only lines, so the plan's word-stream-equality gate is
unsatisfiable as written and the bytes/token gate above is the measurement
that stands.  The divergence cases are pinned by tests
(`testPretokenV2Edges`); `decode . encode = id` holds under both rules
(`testFastBpeV2RoundTrip`).

### A generation-time caveat the qualitative suite must fix first

`generate` strips trailing whitespace from the prompt (`gpu/Main.hs`,
`dropWhileEnd isSpace`) under a comment that was true under v1 -- "a dangling
space becomes a standalone token that never occurs in encoded training text"
-- and is false under v2, where trailing runs and `"\n<indent>"` words are
ordinary in-distribution tokens.  Worse, `isSpace` also strips `\n` and
`\t`, so a code prompt ending `"f x =\n    "` -- exactly the shape the v2
tokenizer exists to serve -- is silently truncated to `"f x ="`.  Not a
training-path issue; fix before running the Milestone 4 coding-prompt suite.

## Sequencing constraints

- **Measure the v2/v3 baselines before adding any `Config` field.** `modelId` is
  `show cfg`, so a new field changes the identity of every preset and locks out
  the existing checkpoints. Adding a preset is safe; adding the RoPE arm is not.
- **`contextSize` left `Layout.core`.** No slice in the layout depends on it —
  there is no positional embedding — so refusing a warm start across contexts
  forbade a transfer that is sound by construction. It stays in `Config`, and
  hence in `modelId`, so the runs remain distinct identities.


## The code corpus

The Stack was dropped in favour of the canonical sources directly. Its
snapshots are from 2022 and pre-date the Lean 4 ecosystem entirely; its Haskell
is a subset of Hackage and its Nix a subset of nixpkgs; and the two things it
pre-computes for us, permissive-license filtering and near-duplicate removal,
are cheap to do explicitly. Nothing in this pipeline needs an account or a
token.

Acquired: 19,418 of 19,426 Hackage packages at their latest version (the 8
absent are spam Hackage has pulled), mathlib4 / lean4 / batteries,
agda-stdlib / cubical / agda, idris2, nixpkgs, and 23 of the user's own
repositories. After the license gate and content-hash deduplication:

| | files | MB | share |
|---|---|---|---|
| Haskell (`.hs`, `.lhs`) | 222,708 | 1,579 | 88% |
| Lean | 16,238 | 143 | 8% |
| Nix | 25,605 | 59 | 3% |
| Agda | 7,856 | 19 | 1% |
| Idris | 2,637 | 7 | 0.4% |

299,966 files became 279,452 unique (6.8% duplicates), of which 270,054 train
and 9,398 are held out. 2,641 of 19,450 sources were dropped on license.

**The 6.8% dedup rate contradicts the plan's "tens of percent" expectation,
and the verdict is that the expectation was wrong, not the hashing**: Hackage
sdists ship their own source, and the heavy vendoring lives in build products
(`dist-newstyle`, generated C) that the extension filter never admits.  A rate
near zero would still mean broken hashing.

**Known license-gate limitation, accepted:** the gate is per package or
repository -- a permissively-licensed package's verdict is applied to every
source file in its tree, so a file individually under a different license
inside a permissive package is not caught.  Dual-licensed repos shipping only
`LICENSE-MIT`/`LICENSE-APACHE` (no bare `LICENSE`) are dropped conservatively.

**Haskell dominates at 88%, far more than the plan assumed.** Phase B's
per-language balance is therefore a job for `mix-corpus.sh`'s repeat counts
rather than something the corpus provides for free.

**1lab is excluded and that is correct** — it is AGPL-3.0. It would have been a
large, high-quality Agda source, and losing it is why Agda is only 1%.

### Evaluation holdout

Held out whole, never by document position: the trainer's split is a hash of
position, and code vendors heavily enough that the same file lands on both
sides of one.

| language | held out | MB | ~windows at ctx 1024 |
|---|---|---|---|
| Haskell | 2% of Hackage packages | 28.5 | 7,300 |
| Nix | `nixpkgs/nixos` | 9.1 | 2,340 |
| Agda | `cubical` | 8.5 | 2,195 |
| Lean | `batteries` | 1.35 | 347 |
| Idris | `idris2/tests` | 0.90 | 231 |

Haskell, Agda and Lean are held out as **whole projects**, which tests
generalization across projects. Nix and Idris each come from a single
repository, so their holdout is a **subtree of the project the model trained
on** — a weaker claim, and one to state whenever those two numbers are quoted.

A flat 2% produced a holdout that was 100% Haskell: 2% of Hackage's 19,418
packages is a healthy eval, while 2% of the eight repositories the other four
languages share rounds to zero.

**2026-08-28 re-extraction (`run/code-train-v2.jsonl` / `run/code-eval-v2.jsonl`):**
ids gained a source namespace (`hackage:`/`repo:`/`own:`) because the original
pull's bare names collided -- the Hackage PACKAGE `cubical` matched the
HOLDOUT_GROUPS entry meant for the Agda REPOSITORY `cubical`, putting 7
Haskell and 2 Nix files of an unrelated package into the Agda repo's holdout
(and hence into `code-haskell`/`code-nix` eval populations built before this
date).  The percent bucket still hashes the bare name, so the sampled Haskell
holdout is the same population; the per-language eval corpora are rebuilt from
the -v2 holdout.  The tokenizer is unaffected (it never sees ids).

A sixth eval population exists for Milestone 4: the Claude-Code transcript
holdout (`run/eval/transcript-code32k.corpus`, 273 scrubbed documents from 4
whole sessions, packed to 128 KB; source `~/src/llm-transcript/`).

One correction to note beside the Idris row: by BYTES the holdout is the
0.90 MB shown, but by DOCUMENTS it is two thirds of the language (664 train
vs 1,311 held-out files) -- the training-side Idris population is the smaller
one, and per-document Idris claims should say so.


## The code-aware tokenizer

`run/code32k.bpe`, learned under the v2 pretokenization rule from a 514 MB
sample: 293 MB English, 124 Haskell, 59 Lean, 42 Nix, 10 Agda, 6 Idris. Agda
and Idris are taken whole because that is all that remains in training after
the holdout -- the plan assumed 100 MB of Agda, Lean and Idris together would
be available and there is only 75. Agda still lands at roughly twice its corpus
share, Lean at 1.4x. 4,184,043 distinct words, 944,411 clearing frequency 3,
32,510 merges, 15 minutes.

Bytes per token on held-out sets, against the tokenizer v2 and v3 trained on:

| held-out | old 32k | code32k | change |
|---|---|---|---|
| Haskell | 2.260 | **4.058** | +79.5% |
| Nix | 2.001 | **3.801** | +89.9% |
| Agda | 1.772 | **3.155** | +78.0% |
| Lean | 2.274 | **3.590** | +57.9% |
| Idris | 1.994 | **2.964** | +48.7% |
| Wikipedia prose | 4.721 | 4.550 | **-3.6%** |
| enwik8 | 3.190 | **3.516** | +10.2% |

**Two changes are folded together here**, and the §0.3 gate separates them. That
gate held the corpus fixed and varied only the rule: +39.5% on code, -0.04% on
prose. So of the +79.5% on Haskell, roughly half is the pretokenization rule and
half is having code in the tokenizer's training sample -- and the entire -3.6%
prose cost belongs to the corpus mix, not the rule.

That -3.6% is the shared-vocabulary tension the plan predicted, and it is real:
prose now needs 3.8% more tokens for the same bytes. It is priced against code
improving by half to nearly double.

**Agda was the risk and it cleared.** Its notation is 3-byte UTF-8, and at 1% of
the corpus there was a real chance those glyphs never earned single pieces and
stayed as three byte-tokens each. At 1.772 bytes/token the old tokenizer was
close to exactly that failure; 3.155 says the oversample worked.

**enwik8 improved 10.2%, which was not an aim.** It is raw MediaWiki markup, and
a tokenizer that has seen indentation and punctuation-dense text handles markup
better than one trained on extracted prose. This bears directly on the
GPT-2-small comparison: the same model now spends 10% fewer tokens per byte on
the benchmark corpus.
