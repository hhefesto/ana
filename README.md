# ana

A denotationally specified autoregressive transformer, written in
[Bend](https://github.com/bendlang/bend): its specification, its trainer, its
decoder and the tools that build its corpora. The new path (2026-09-25) is
the data: a corpus for a coding agent in functional languages (Haskell,
Agda, Lean, Bend, Nix), where every compiler message the model reads was
produced by the compiler.

`HANDOFF.md` is the live record: what is being built, the decisions taken,
and the gates each phase must pass.

## Why `ana`

Short for **anamorphism**, an unfold: the categorical dual of a fold. A fold
consumes a structure down to a value; an unfold grows one from a seed, for
as long as you keep asking. That is what autoregressive generation is: from
a state, emit a token and a next state, with no predetermined end.
`bend/Spec/Autoregressive.bend` states the model as that coalgebra, and
sampling is its unfold into the trie of continuations (`bend/Spec/Trie.bend`).

## Layout

| path | what |
|---|---|
| `bend/Spec/` | the specification: every law about the model, proven (`bend bend/Everything.bend` prints `All terms check.`) |
| `bend/Model.bend`, `bend/Train*.bend`, `bend/Dense/` | the model, the tree trainer, and the dense GPU trainer (reverse mode derived as a program transformation over bulk ops) |
| `bend/Generate.bend`, `bend/Evaluate.bend` | the decoder and the bits-per-byte scorer |
| `bend/Tokenizer.bend` | byte-level BPE (encode, decode, identity) |
| `bend/Pack.bend`, `bend/Prepare.bend`, `bend/PlanSegment.bend` | the corpus tools, byte-identical to the Haskell ones they replaced (`docs/BEND-CORPUS-TOOLS.md`) |
| `bend/Extract.bend`, `PlanCorpus`, `CodeEvals`, `Mix`, `Push` | the corpus drivers: extraction, shards and plan, eval corpora, mixing, box transfers (they run programs through `bend/Sys.bend`) |
| `bend/Units.bend`, `Check.bend` + `Check/`, `Transcript.bend`, `Transcripts.bend`, `Windows.bend` | the transcript corpus: units, the real checkers, rendering, the stages, one-context windows (`docs/TRANSCRIPT-FORMAT.md`) |
| `bend/gpu/` | GPU conformance programs, box scripts and the logs of the runs |
| `deploy/check/` | `Harness.lean` (the Lean checker's driver, the one program only Lean can be) and the harness GHC's package list |
| `weights/` | the two tokenizers: `enwiki-fineweb-32k.bpe` (v2/v3) and `code32k.bpe` (code) |
| `references/` | the papers the specification formalizes |

The Haskell reference, the Futhark kernels and the Agda specification this
port came from are at the tag `haskell-final`; comments that cite
`backend/...` or `FormalTransformer/...` paths refer to that tag.
`docs/haskell-era/` keeps their design records and run reports.

## Build and verify

```sh
nix flake check                      # the Bend spec, unit tests, trainer and dense-trainer checks
nix run .#bend -- bend/Everything.bend
nix develop                          # bend, ghc, agda (with its standard library), elan for Lean
nix run .#deploy -- TOOL ARGS        # a corpus tool (bend-TOOL) with those toolchains on PATH
```

## Generate

```sh
nix run .#ana -- --prompt "The history of"      # the newest local checkpoint
nix run .#ana -- --list                          # every local checkpoint, newest first
nix run .#ana -- --checkpoint run/pulled-vast-52365970/v3-bend-step22000.checkpoint "The history of"
```

`TEMPERATURE`, `TOP_K`, `TOP_P` and `SAMPLE_SEED` control sampling. The
checkpoint names its tokenizer by identity and the decoder finds the
matching file under `weights/` or `run/`.

## Corpora

```sh
nix run .#deploy -- extract run/code-train-v3.jsonl
TOKENIZER=weights/code32k.bpe PACK_TARGET=131072 PACK_GROUP=1 \
  nix run .#deploy -- plan-corpus run/code-train-v2.jsonl RUN_DIR fp100m BATCH 2000
nix run .#deploy -- code-evals weights/code32k.bpe run/eval run/code-eval-v2.jsonl
nix run .#deploy -- transcripts all haskell      # sources, units, check, render
```

Every source is JSONL `{id, text}`; the drivers turn it into the NUL-framed
stream the Bend tools read. Interleave sources (`deploy mix`), never
concatenate them: the trainer reads shards in order under one schedule.

## Versions

| | model | context | data | result |
|---|---|---|---|---|
| v1 | 10.6M, GLA/softmax hybrid | 256 | English Wikipedia | one full pass, 1,833,157 steps; 1.21 bpb held-out, corpus-wide (checkpoint in `weights/` at tag `haskell-final`) |
| v2 | 115M, GLA/softmax 3:1 | 256 | Wikipedia + FineWeb-Edu | stopped at 94.1%; enwik8 1.3728 bpb |
| v3 | 115M, RG-LRU gates, qk-norm, sinks | 256 | same | 8,000 steps on master, continued to 28,000 on the Bend dense trainer; enwik8 best 1.4462 bpb at 22,000 |
| next | 115M, cold start, `code32k` | 2048 | the FP coding-agent corpus | planned; see `HANDOFF.md` |

## Scope

The trained models have had no post-training, so they cannot follow
instructions. The coding-agent corpus is the first data built to teach it.
