# Session Handoff

This file holds everything needed to continue this work from another machine and account. It was restarted from zero on 2026-10-02 for a new path: **legere**, the Bend Jev. The previous handoff (the FP-agent transcript corpus: the checks, the Bend ×4 rebuild, the filler) is in git at `e9cce23:HANDOFF.md`. The one before it (the v3 hot start and the dense trainer) is at `41e1920:HANDOFF.md`, and master's Haskell-era trainer is at the tag `haskell-final`.

## ▶ CONTINUE HERE (2026-10-02, 11:30 UTC-6): legere v1 runs end to end; the next model splits the entry prior

`nix run .#deploy -- legere STAGE ...` is the tool. `docs/LEGERE.md` has the design, the stages, the measurements and the rules. On the sessions:

- **`eval`** (holdout: 273 docs, 4 sessions):
  - lines inside named blocks, names hidden: **0.593 bits/line, 86.8%** against p(tag | inside) at 1.680 bits and 53.0%;
  - every labelled line, nothing forced: **0.615 bits/line, 84.9%, ECE 0.042** against the prior at 2.322 bits and 35.8%.

  Phase 3's gate holds by a wide margin.
- **`segment`:**
  - 51,368 sections; all 3,172 docs give their text back byte for byte (Phase 2's gate).
  - 15 code sections went to the checkers. 38 more Haskell Write blocks were dropped because the session converter elided their middles.
- **`units` → `bend-check` → `bend-transcript`:**
  - Haskell: 8 units, 4 kept, 8 transcripts.
  - Agda: 5 units, 0 kept.
  - Nix: 1 unit, 1 kept, 2 transcripts.

  They read right by eye: the User line is the prose before the code, then Context, Type and Term, and GHC's real `[exit 0]` or its error in a repair.
- **`notes`:** every code file compiled whole, pass or fail. Haskell 4 of 10, Agda 1 of 4, Nix 1 of 1, each with the compiler's own words.

**Known weakness.** A minority language inside an *unnamed* block loses to "output". Recall on named blocks with names hidden is haskell 0 of 123 and code 0 of 90.
- The line model does prefer Haskell, by 0.1–0.6 nats per byte (`explain`).
- But the entry prior comes from stdout-dominated named blocks.
- The next step is an entry prior split by authoring context: a tool block versus an assistant fence. In production, named blocks are forced by their cues, so this only matters for bare fences.

**For the user to decide:**
1. Should failing session code become transcripts, as a "given code + compiler notes" shape? The existing rule drops it, so that no `## Term` answers with broken code. `notes.nul` keeps it either way.
2. Should the Bend verdict lines be mixed? Bend checks made from now on say `ALL PROOFS CHECK`; the 81k older Bend transcripts say `All terms check.`.

Done today, besides legere:
- **bend2 updated:** `hhefesto/bend2` `ft-kernels` = upstream 2.0.34+24 plus one port commit `14c97234`; the old head is the tag `ft-kernels-2.0.28`. It is locked at `7b05622`.
- **`IO.args` fixed in all 15 tools** (`c5302ce`). Since 2.0.32 it leads with the program; the fix is held to identity.

Upstream gave none of the fork's needs, as memory `project-bend2-fork-remotes` records.

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
| 1 | `Legere/Spec.bend` + `Semiring.bend` + brute-force reference + `tests/legere.bend` | **done** (`e1a5f10`) |
| 2 | `Ngram`, `Lines`, `Forward`; `train`, `segment`. Gate: Forward/Viterbi equal the reference; the round trip is byte-identical on all 3,172 docs | **done** |
| 3 | Calibration + `eval`. Gate: on the holdout, beat both the prior-only and the cue-rules-only baselines on log-score | **done** (0.593 vs 1.680, 0.615 vs 2.322 bits/line) |
| 4 | `units`, then the existing check/clean/render on the sessions' code. Gate: transcripts read right by eye, and `bend-plan-windows` accepts them | **done** for check and render; `notes` added; plan-windows not yet run on them (only 10 transcripts) |
| 5 | Flake: `bend-legere`, the deploy PATH, the `bend-tests` check | **done**; `Legere/Spec.bend` is in `Everything.bend` |

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
