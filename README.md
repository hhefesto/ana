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
| `bend/gpu/` | GPU conformance programs, box scripts and the logs of the runs |
| `deploy/` | shell drivers: corpus extraction, mixing, planning, eval corpora, box transfers |
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
nix develop                          # bend, jq, ghc, agda (with its standard library), elan for Lean
```

## Generate

```sh
nix run .#ana-bend -- --checkpoint run/pulled-vast-52365970/step-22000.checkpoint --prompt "The history of"
```

`TEMPERATURE`, `TOP_K`, `TOP_P` and `SAMPLE_SEED` control sampling. The
checkpoint names its tokenizer by identity and the decoder finds the
matching file under `weights/` or `run/`.

## Corpora

```sh
TOKENIZER=weights/code32k.bpe PACK_TARGET=131072 PACK_GROUP=1 \
  deploy/plan-corpus.sh run/code-train-v2.jsonl RUN_DIR SIZE BATCH 2000
deploy/build-code-evals.sh weights/code32k.bpe run/eval run/code-eval-v2.jsonl
```

Every source is JSONL `{id, text}`; `jq` turns it into the NUL-framed stream
the Bend tools read. Interleave sources (`deploy/mix-corpus.sh`), never
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
