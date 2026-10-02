# Session Handoff

This file holds everything needed to continue this work from another machine and account. It was restarted from zero on 2026-10-02 for a new path: **legere**, the Bend Jev. The previous handoff (the FP-agent transcript corpus: the checks, the Bend ×4 rebuild, the filler) is in git at `e9cce23:HANDOFF.md`. The one before it (the v3 hot start and the dense trainer) is at `41e1920:HANDOFF.md`, and master's Haskell-era trainer is at the tag `haskell-final`.

## ▶ CONTINUE HERE (2026-10-02, 12:30 UTC-6): legere reviewed; the trainer can now start ana from the fp100m plan; the box waits for a yes

**The user's direction (2026-10-02 afternoon):** legere is the next generation of ana's data path, meant to feed ana new training material continuously; ana's Bend trainer should start training on our dataset on a rented GPU box; and legere improves iteratively so each round of sessions becomes transcripts.

### What was done this afternoon

1. **legere assessed** (the review is in `docs/LEGERE.md`, "Assessment"; the verdict in short):
   - The denotational core is sound: `Spec.bend` is a real semantic function (every labelling enumerated), `Forward.bend` is held to it exactly in Bool and Nat and to 1e-4 in logp/maxp (`bend tests/legere.bend`: 11 `ok` lines, re-run today), and `roundtrip` is a proof, not a test. Spec and implementation are both Bend, as asked.
   - Three claims were tightened: "the run is a monoid homomorphism" was listed as a law but never stated or tested (it is a fold by construction; removed from the laws below); the line model `Λ_t` (hashed Witten-Bell) has no specification of its own, only the Σ_b P = 1 test; the boundary posterior (Jev's `Noul`) is computed and tested but not written to `sections.nul`.
   - The design flaw behind the known weakness: the mean-per-byte scale (fit at 0.5) throws away the block's *length* as evidence, so a 20-line Haskell block adds only 1–6 nats against a 4.5-nat entry prior. The summed form overcounts because lines in a block are not independent given the tag. The fix that keeps the meaning is a context-conditioned line model, `Λ_t(line_i | line_{i-1})`: the emission table is still a function of the text, so Spec, Forward and the tests apply unchanged. That is the next legere model, ahead of the entry-prior split.
   - The output is straightforward to convert: `segment → units → bend-check → bend-clean → bend-transcript` runs unchanged on legere's files and produced correct transcripts. The yield is the problem (10 transcripts from 3,172 docs), not the shape; see "legere's next round" below.
2. **The trainer gained a plan start** (`bend/TrainDense.bend`, `Checkpoint.bend` `Save.*`, `Dense/Plan.bend` `identity`/`batch`; `docs/BEND-PORT.md` "Plan start"). Until today a fresh run could only tokenize a text file and a hot start alone read a plan's shards: **the fp100m run could not have started.** Now `PLAN` set with `TRAIN_INIT` empty trains from fresh parameters on the plan's shards and schedule and saves FTC2 every `SAVE_EVERY` steps, which `TRAIN_INIT` continues. The micro-batch must divide the batch in every mode (a remainder used to drop its windows silently). `PRESET=fp-tiny` (fp100m's vocabulary and context, toy dimensions) exists for CPU tests.
   - **CPU round trip** (plan start 2 steps on fp100m's shard 0 saving each step, then a hot start from step 1 for one step; the step-2 lines and checkpoints must agree): **passes** (12:43 UTC-6): B's step-2 line equals A's (train_loss 10.148527, gradient_norm 2.7763617) and the step-2 checkpoints are byte-identical (sha256 `64dd2b66…`, 35.4 MB). A CPU step of fp-tiny at batch 16 × ctx 2048 takes ~890 s, so the test is a 45-minute run (`scratchpad/plan/roundtrip.sh` of this session; the recipe is in `docs/BEND-PORT.md`). The flake's `bend-dense` identity check still passes (goldens unchanged). One thing the log showed: training-time validation averages over *whole* micro-batches, so `EVAL_WINDOWS` below `TRAIN_MICRO` prints `validation_loss=0`; keep it a multiple (fp.sh uses 128 at micro 4).
3. **The box is staged, not rented** (`bend/gpu/fp-stage.sh HOST PORT`, then on the box `fp.sh gate`, `fp.sh time`, `fp.sh run`, `fp.sh eval`; `bend/gpu/fp100m-box.env` for `bend-push`). Checked today without a box: `bend TrainDense.bend -o traind.c` works on 2.0.34 (5.8 MB of C, 7 s); it compiles clean with clang under `-DBEND_CUDA=1 -DBEND_NO_SRC` against CUDA 12.8 headers and stubs, and as a CPU binary it trains; `bend-push` dry run sends the plan, the tokenizer and the 36 shards in plan order, **0.64 GB** in all. The GPU gate on the box is G2 (`tests/dense.bend` on the GPU against the tree trainer, every gradient within 1e-5); the rebased fork has never run on a GPU, so the gate comes first. Kernel strategies pin with `BEND_FT_STRAT=1` (one integer for every einsum kernel; 1 is the only value valid for every shape) when two GPU runs must agree.

### The box (2026-10-02 afternoon; the user: "Do rent box", "Keep cheap", "Only one box")

- **First box, vast 53902708** (RTX 3090, Pennsylvania, $0.245/h with an 80 GB disk): G2 gate **PASS** on the GPU (the dense program matches the tree trainer's CPU gradients to 4e-7 relative, both chunks, both shapes; the rebased fork's first GPU run); `fp.sh time 20`: **5,182 ms/step = 6,317 tok/s** at micro 4, SM 100%, 284 W, 6.9 GB on the card (the store), host RSS 4.8 GB (peak 11.3 GB). The run reached step 191 (loss 10.41 → 4.01), then the user chose a cheaper box and it was **destroyed** (its logs are in `run/pulled-vast-53902708/`). The search that picked it required ≥ 64 GB RAM and 300 Mb/s down, which hid the cheaper offers: the run needs ~12 GB of host RAM.
- **Second box, vast 53907028**, destroyed after 6 minutes unused: listed at $0.139/h, billed $0.230/h. **vast's listed `dph_total` assumes a small disk; the real price is `dph_base + storage_cost × disk_GB / 720`, and storage_cost varies 10× between hosts** ($0.867/GB-month on that one: $0.096/h for 80 GB). Price every offer at the disk you will ask for, plus `inet_up_cost` × the GB you will pull.
- **Third box, vast 53907415: RTX 5090** (California, $0.506/h with a 45 GB disk, image `nvidia/cuda:12.8.1-devel-ubuntu22.04`), the user's choice over a $0.159/h 3090: est. $2.20 (4.2 h) to $3.62 (7 h) against the 3090's $2.11 over 12.9 h. Blackwell (sm_120) has never run the fork: the einsum kernels take their architecture from the device at runtime (`comp.ts:5231`), so a CUDA ≥ 12.8 image is needed; the G2 gate decides, and on a failure the box is destroyed and the 3090 rented.
- **That 5090 never started** (vast answered `success: False` and left a stopped stub; someone else took the offer); the stub was destroyed. **Fourth box, vast 53909778: RTX 5090, South Korea, $0.488/h** with a 45 GB disk, reliability 0.998, CUDA 12.8.1 image. Measured: G2 gate **PASS on Blackwell** (gradients within 4.5e-7; the fork's first sm_120 run); `fp.sh time 20`: **1,951 ms/step = 16,781 tok/s, 2.66× the 3090**, 500 W, 99% SM, 7.2 GB on the card; its first 20 losses equal the 3090 run's to 6 digits. **The whole plan ≈ 4.8 h ≈ $2.35.** Links from here: 1.25 MB/s up, 3 MB/s down (a 1.85 GB checkpoint ≈ 10 min).
- **The run started 14:01 UTC-6** (trainer pid 1699; ends ≈ 18:50 UTC-6). `ft-fp-finish` (restarted for this box, into `run/pulled-vast-53909778/`) now pulls every 1000th checkpoint *while the run goes on* (only once the log says `saved`, since saves write in place), then scores those and the last on the held-out transcripts, pulls the last, verifies every sha256 and destroys the box.
- **16:45 UTC-6: the relay replaced the finisher.** `ft-fp-relay` runs `run/fp-relay.sh` (a copy of `bend/gpu/fp-relay.sh`; bash reads a running script, so never edit the copy in use), log `run/pulled-vast-53909778/relay.log`. It pulls fp100m's every-1000th checkpoint during the run; when fp100m ends it waits up to 30 minutes for the next plan on the box (`run/next/plan-next-b16-windows.tsv`, its shards `run/next/shard-K-next.corpus`, the marker `run/next/STAGED`, and `traind-next.c`, already built there as `traind-next` from `a8520b2`), starts `fp.sh next out/fp100m-step8803.checkpoint` (TRAIN_NEXT, lr 1e-4 after 100 warmup steps, cosine over the plan), follows it the same way, then scores every pulled checkpoint on `run/eval/transcript-fp.corpus` and `run/eval/transcript-next.corpus`, pulls the last ones, verifies the sha256 and destroys the box. Without the next plan in time it scores, pulls and destroys. Building `traind-next` on the box (clang, nice 19) did not move the trainer's 1,987 ms/step.
- **The continuation's data** (being prepared 14:30–18:00 by two agents on this machine): new Bend2 (upstream 2.0.34's new code, this repo's legere and trainer code, community repos updated since 2026-09-26) and new Haskell (GitHub repos not on Hackage), checked by the real checkers into `run/transcripts-next/{bend,haskell}/`, exact-deduplicated against the old corpus. The mix: `bend-plan-windows` over `run/transcripts-mix-next/` with `haskell-new` and `bend-new` read once and the old five languages as `:cycle` replay at about 1:1, in fp100m's proportions; the replay languages get no filler of their own.
- `vastai destroy instance ID` asks for confirmation: use `-y` (the finisher had it missing and would have aborted silently; fixed).

### The run, as approved (setting below unless the user changes it)

- **Box:** one RTX 3090 or better on vast.ai, ≥ 64 GB RAM, `--gpu 48GB`; test the link first (`bend-push link`, done by `fp-stage.sh`).
- **Setting** (`fp.sh`, overridable): `PRESET=fp100m` (115M, ctx 2048), the plan's batch 16 in micro-batches of 4 (the store is 1.77e9 floats; 8 does not fit one array), Muon at lr 3e-4, warmup 300 of 8,803 steps, weight decay 0.01, clip 1.0, tf32 (master's v3 manifest had lr 3e-4, Muon 0.95, wd 0.01, clip 1.0, tf32, warmup 100 of 358k). A save every 500 steps (18 files of 1.85 GB), validation every 250 steps on 128 shard windows.
- **Cost:** `fp.sh time` measures it; at the hot start's 7,155 tok/s (ctx 256) the 288M tokens are 11 h; ctx 2048 at micro 4 will be slower per token (attention is quadratic and the micro-batch small), so plan on 12–20 h, a few dollars at 3090 prices, plus an hour of gates.
- **Ranking checkpoints:** `fp.sh eval` gives bits per byte on `run/eval/transcript-fp.corpus` (5.6 MB of held-out transcripts); the repair-accuracy driver (200 held-out prefixes sampled and re-checked) is still unwritten and ranks them properly.
- **Open hyperparameter question:** Muon's lr is the manifest's 3e-4 as in v3; the G3 speed benchmark used 0.02. Keep 3e-4 unless the user says otherwise.

### legere's next round (so each batch of sessions becomes training data)

1. **Yield:** 10 transcripts from 3,172 docs. The losses, in order: the session converter elides long Write blocks (38 Haskell files lost: fix upstream in `~/src/llm-transcript`, export whole files); Edit calls (987 `.hs`) are diffs, not files (reconstruct by applying them to the Read'd original); project modules not on disk (check Write'd files inside their repository).
2. **The model:** the context-conditioned line model above; then the entry prior by authoring context; then compiler acceptance as a likelihood.
3. **Shape:** write the boundary posterior into `sections.nul` (Jev's second question); a `Ngram.spec` (exact counts in a `Map`) that the hashed table is held to on small corpora.
4. **The loop:** a warm start of ana on a *new* plan (`TRAIN_INIT` plus a different `PLAN`: load the parameters and moments, write a new manifest with the new plan's identity and total). The plan start shares all the code it needs; it is the next trainer change once the first run exists.

**Still for the user to decide** (unchanged): failing session code as "given code + compiler notes" transcripts; mixing Bend's new `ALL PROOFS CHECK` verdict with the 81k older `All terms check.` transcripts.

Also today, before the review: legere v1 end to end (`docs/LEGERE.md` has the numbers: 0.593 bits/line vs 1.680 on named blocks with names hidden; 0.615 vs 2.322 with nothing forced; 51,368 sections, byte-exact; 15 code sections checked, 10 transcripts), bend2 rebased onto upstream 2.0.34 (`hhefesto/bend2` `14c97234`, locked at `7b05622`; upstream solved none of the fork's needs) and the `IO.args` fix in all 15 tools (`c5302ce`).

## The goal

**What Jev is.** Jev (TypeSafe AI, "System One") is a *decision model*: evidence plus a typed question gives a typed answer with a probability, never prose. legere is ours, in Bend2. It does four things:

1. It reads raw text. The first source is the user's Claude Code sessions, `~/src/llm-transcript/corpus.jsonl`.
2. It cuts the text into sections and tags each one with ana's tags (prose, or code in `haskell agda lean bend nix`, or other), each with a posterior.
3. It checks runnable code with the real compiler.
4. It emits units that the existing pipeline (`bend-check`, `bend-clean`, `bend-transcript`, `bend-plan-windows`) turns into ana transcripts unchanged.

Decisions taken with the user on 2026-10-02:

1. **Name `legere`.** Latin for both "to read" and "to pick out, gather". Binary `bend-legere`, module `bend/Legere.bend`.
2. **Prose maps onto transcript turns.** The prose before a code block becomes `## User`, signatures `## Type`, definitions `## Term`, and the checker turn follows.
3. **First input: the sessions corpus.**

## The meaning

The meaning is written in Bend, and the fast code refines it (Elliott; Goodman; Bradley).

- **Tags:** `Prose | Code{lang} | Other{name}`.
- **Typed questions:** `classify(section) : Dist Tag`, `boundary(line) : Dist Bool` and `check(L, code) : Check`. The compiler is the decider.
- **Calibration** is a measured property, never assumed. The ideal legere is the true `P(tag | text)`, the unique minimiser of the log-score.
- **The segmenter is a weighted language over a semiring:** `D = (Σ_t s_t · (Λ_t)⁺)⁺` over lines, where `Λ_t` scores one line under tag t. The carrier chosen answers each question:
  - `Bool`: is the text well formed?
  - `Nat`: how many segmentations?
  - `LogProb`: the posteriors (by forward-backward).
  - `Viterbi`: the best segmentation itself.
- **Laws**, stated on meanings and held in `bend/tests/legere.bend` unless marked proven:
  - the round trip `flat (sections ps) == lines ps` (proven, `law roundtrip`);
  - Forward equals Spec exactly in Bool and Nat, within 1e-4 in logp and maxp (score, marginals, boundaries, posteriors, Viterbi);
  - `Bool` is `Nat`'s support (n ↦ n > 0 is a semiring homomorphism);
  - every posterior row sums to 1.
  (Forward's run over `u ++ v` is a fold by construction; no separate law is claimed.)

## Facts

**The FP-agent corpus is built.** The Bend ×4 rebuild finished on 2026-10-01 at 21:31: `run/fp100m/plan-fp100m-b16-windows.tsv`, 156,067 windows of 2,046 tokens, 8,803 global steps at batch 16, `shard-{0..35}-fp100m.corpus`. Two things remain on that path: the store split (2b) and the run itself, which needs a box (ask first); see `e9cce23:HANDOFF.md`, Phases.

**The sessions corpus** (`~/src/llm-transcript/`):
- `corpus.jsonl` holds 3,172 docs (11 MB, `{"id","text"}`) from 26 sessions. `corpus.jsonl.holdout.jsonl` holds 273 docs from 4 sessions.
- The turns are `## User` / `## Assistant`.
- Tool calls appear as `### Write — \`path\``, `### Edit — \`path\`` (followed by a ```` ```diff ```` fence) and `### Read — \`path\``.
- Command output appears under `**stdout:**` / `**stderr:**` (4,483 / 237).
- Fences: 18,112 bare, 5,045 `sh`, 1,865 `diff`, 8 `haskell`, 4 `agda`, 1 `nix`.
- Write calls by extension: 54 `.hs`, 140 `.md`, 29 `.sh`, 15 `.tel2`. Edit calls: 987 `.hs`, 78 `.nix`, 66 `.agda`.
- These cues are free labels: hide them and predict them back.

**Research** (deep-research run, 2026-10-02):
- DocJev (github.com/jerryjliu/docjev, the only verified view of Jev segmenting) asks a category `Choice` and a boundary `Noul` per page. It claims **no** calibration; a segment's score is a plain mean.
- NLoN (arXiv 1803.07292) separates prose from code per line (AUC 0.98 within one source) but does not name the language.
- Guesslang lacks Agda, Lean, Nix and Bend.
- StarCoder2's notebook format (merged same-kind blocks, text/code/output sentinels, `<empty_output>`) is the precedent for the output shape.
- APRIL (arXiv 2602.02990, Lean diagnostics with error, line, column and goal) supports compiler notes for *repair fine-tuning*. No verified evidence shows they help in pretraining, so that is an ablation for later.

## Phases

| phase | what | state |
|---|---|---|
| 0 | HANDOFF.md restarted | **done** |
| 1 | `Legere/Spec.bend` + `Semiring.bend` + brute-force reference + `tests/legere.bend` | **done** (`e1a5f10`) |
| 2 | `Ngram`, `Lines`, `Forward`; `train`, `segment`. Gate: Forward/Viterbi equal the reference; the round trip is byte-identical on all 3,172 docs | **done** |
| 3 | Calibration + `eval`. Gate: on the holdout, beat both the prior-only and the cue-rules-only baselines on log-score | **done** (0.593 vs 1.680, 0.615 vs 2.322 bits/line) |
| 4 | `units`, then the existing check/clean/render on the sessions' code. Gate: transcripts read right by eye, and `bend-plan-windows` accepts them | **done** for check and render; `notes` added; plan-windows not yet run on them (only 10 transcripts) |
| 5 | Flake: `bend-legere`, the deploy PATH, the `bend-tests` check | **done**; `Legere/Spec.bend` is in `Everything.bend` |

**ana's training path** (the fp100m run):

| step | what | state |
|---|---|---|
| T1 | the trainer starts from a plan (`PLAN`, fresh parameters, FTC2 saves) | **done** today; CPU round trip above |
| T2 | the box staged: `fp-stage.sh`, `fp.sh`, the push env; C generation and CUDA compile checked locally | **done** today |
| T3 | the box: G2 gate on the GPU, `fp.sh time`, then `fp.sh run` over the whole plan; checkpoints pulled and ranked | **needs a box: ask first** |
| T4 | the repair-accuracy eval driver (200 held-out prefixes, `bend-generate` + `bend-check`) | not written |
| T5 | warm start on a new plan, for legere's rounds | not written; designed above |

Later, not v1:
- compiler acceptance as a likelihood (top-2 check, Bayes update);
- ana itself as `Λ_t`;
- Edit-diff reconstruction;
- checking Write'd files inside their source repo;
- the compiler-notes-in-pretraining ablation (needs a box: ask first).

## Where things are

- **legere** (new): `bend/Legere.bend`, `bend/Legere/*.bend`, `bend/tests/legere.bend`, `docs/LEGERE.md`. Outputs go to `run/legere/`.
- **What legere reuses:**
  - `bend/Sys.bend`: text helpers, `run` for spawning, `env`, `slurp`, `emit`, `Rd.lines`.
  - `bend/Units.bend`: `lines` (:197); the fence logic `md.opens`/`md.go` (:255-286); the per-language declaration cutters; the unit record (:16-27).
  - `bend/Json.bend`, `bend/Nul.bend`, `bend/Clock.bend` (`say`, UTC-6).
  - `bend/Check.bend` and `bend/Check/*.bend`: the checkers.
  - `bend/Transcript.bend`: the renderer. Its User line is field 3, `doc`.
  - `bend/PlanWindows.bend`: it reads `OUT/LANG/transcripts.train.nul` and the filler `files-{hi,lo}.nul`.
- **Transcript pipeline:** `docs/TRANSCRIPT-FORMAT.md`; `nix run .#deploy -- transcripts STAGE LANG`; `nix run .#deploy -- check LANG UNITS.nul RESULTS.nul [JOBS]`.
- **Bend2:**
  - The fork is `~/src/bend2`: remote `hhefesto`, branch `ft-kernels`. Never push to `origin`.
  - The guide is `~/src/bend2/guide/GUIDE.md`; Base is `~/src/bend2/bend2/base.bend`. Base has `Map` keyed by String (:84, :3039).
  - F32 only (no F64).
- **References:**
  - `~/src/conal-elliott`: `paper-2021-language-derivatives/Weighted.lagda` is the cleanest spec of weighted ν/δ; `weighted-derivatives/haskell/WeightedDerivatives.hs`; `NOTES-bradley-vs-elliott.md`.
  - `~/src/tai-danae-bradley`: use paper 10's composition *inequality*, not paper 06's equality.
- **Flake:** `bendBinary pkgs NAME ENTRY` (`flake.nix:46-54`); packages at :67-111; the `deploy` app at :122-163; `bend-tests` at :427-470.
- **The run on a box:** `bend/gpu/fp-stage.sh` (local: C generation, scp, `bend-push`), `bend/gpu/fp.sh` (box: `build`, `gate`, `time`, `run`, `eval`), `bend/gpu/fp100m-box.env`. The trainer's modes are in `docs/BEND-PORT.md` ("Hot start", "Plan start"). The fp100m corpus is `run/fp100m/` (36 shards, 0.64 GB, plan `plan-fp100m-b16-windows.tsv`); the eval corpus `run/eval/transcript-fp.corpus`.
- **The v3 manifest's hyperparameters** (read from `run/pulled-vast-52365970/v3-bend-step28000.checkpoint` today): lr 3e-4, betas 0.9/0.999, eps 1e-8, wd 0.01, warmup 100, total 358,276, Muon 0.95, clip 1.0, tf32, batch 64.

## Bend pitfalls met

- **A Bend process evaluates on one thread.** `IO.fork` gives concurrency for effects only, so parse-heavy work fans out as processes (`SHARD/SHARDS`, `Transcripts.bend:600-612`).
- **Parsers must stay linear.** Never append to the end of an accumulator per line, and never `+`-copy an accumulator for a strict `Bool.pick`.
- **SIGTERM:** a busy Bend process, with or without forked jobs, exits on SIGTERM. Measured 2026-10-02 on both compilers; the old "ignores SIGTERM" note was probably the `sh`/`timeout` wrapper. `systemctl --user kill -s KILL` is still the sure stop for a unit.
- **`IO.print` never flushes.** Log to stderr (`Clock.say`) or run under `stdbuf -oL`.
- **Large Nat literals:** `1000n` and `70000n` compile and run on both compilers in a plain program (2026-10-02). `U32.to_nat(N)` stays the safe spelling where the old overflow was seen.
- **`IO.args` leads with the program** (Bend 2.0.32+). Every main drops it with `List.tail`.
- **Bend reserves `is` as a keyword**, so it can't name a variable.
- **A `match` and a destructuring `let` take only a parameter or a pattern variable, never a computed value.** Pass the pair to a helper that takes it as a parameter. The same rule forbids `(a, b) = x` inside a `do` block.
- **A def must come before its callers, and mutual recursion is refused.** Make a strict `Bool.pick` lazy with a flag argument the next call matches on (`Legere/Lines.bend` `count.go`).
- **`Done` is a reserved constructor name.**
- **Nix sees only git-tracked files**: `git add` a new `.bend` before any nix build.
- **Long jobs run as transient systemd user units:** `systemd-run --user --unit=ft-NAME -p MemoryMax=… -p OOMPolicy=continue`. Caps are generous guards, not throttles.

## Rules

- **Money:** rent a GPU box only once everything is staged, and ask the user before spending money. That covers boxes and the Claude Message Batches API.
- **Box hygiene:**
  - DESTROY a box, never stop it; `vastai` lives in `~/.local/share/vastai-venv`.
  - Run long jobs under `nohup` and `stdbuf -oL`, because the Bend runtime's print does not flush.
  - Check `nvidia-smi -q -d PERFORMANCE` for thermal slowdown.
  - A CUDA-built Bend program uses the GPU by default, so a CPU baseline needs `--gpu off --threads N`.
- **Git:**
  - Commits carry no Co-Authored-By. Nothing is pushed without asking.
  - `private/*` branches push only to the `private` remote. Never push to `origin` in `~/src/bend2`.
- **Logs:** every log line is stamped in Mexico City time (UTC-6), from the fork's `IO.time`.
- **Subagents:** they run on Opus 5.5 only, never another model.
- **Byte identity:** every layout or corpus-tool change is held to it, with `bend/tests/dense-identity.sh` for the trainer and `cmp` of `.corpus`, plan and results files for the tools.
