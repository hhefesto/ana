# Session Handoff

This file holds everything needed to continue this work from another machine and account. It was restarted from zero on 2026-10-02 for a new path: **legere**, the Bend Jev. The previous handoff (the FP-agent transcript corpus: the checks, the Bend ×4 rebuild, the filler) is in git at `e9cce23:HANDOFF.md`. The one before it (the v3 hot start and the dense trainer) is at `41e1920:HANDOFF.md`, and master's Haskell-era trainer is at the tag `haskell-final`.

## ▶ CONTINUE HERE (2026-10-02, 09:49 UTC-6): Phase 1, the meaning

The plan is `~/.claude/plans/do-research-on-jev-binary-stearns.md`. Phase 0 (this file) is done. Next is Phase 1:
- `bend/Legere/Spec.bend` and `bend/Legere/Semiring.bend`;
- the brute-force reference segmenter;
- `bend/tests/legere.bend`.

Nothing is running.

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
- **Laws** are stated on meanings:
  - the round trip `concat sections == text` holds byte for byte;
  - `Bool` agrees with `Nat` on whether a text has any segmentation;
  - the Viterbi score equals the max over the enumeration;
  - every posterior sums to 1;
  - the run is a monoid homomorphism.

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
| 1 | `Legere/Spec.bend` + `Semiring.bend` + brute-force reference + `tests/legere.bend` | next |
| 2 | `Ngram`, `Lines`, `Forward`; `train`, `segment`. Gate: Forward/Viterbi equal the reference; the round trip is byte-identical on all 3,172 docs | |
| 3 | Calibration + `eval`. Gate: on the holdout, beat both the prior-only and the cue-rules-only baselines on log-score | |
| 4 | `units`, then the existing check/clean/render on the sessions' code. Gate: transcripts read right by eye, and `bend-plan-windows` accepts them | |
| 5 | Flake: `bend-legere`, the deploy PATH, the `bend-tests` check | |

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

## Bend pitfalls met

- **A Bend process evaluates on one thread.** `IO.fork` gives concurrency for effects only, so parse-heavy work fans out as processes (`SHARD/SHARDS`, `Transcripts.bend:600-612`).
- **Parsers must stay linear.** Never append to the end of an accumulator per line, and never `+`-copy an accumulator for a strict `Bool.pick`.
- **A busy Bend process ignores SIGTERM**: use `kill -9`.
- **`IO.print` never flushes.** Log to stderr (`Clock.say`) or run under `stdbuf -oL`.
- **Large Nat literals (1000n+) overflow the compiler**: write `U32.to_nat(1000)`.
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
