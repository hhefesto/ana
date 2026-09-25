# The corpus tools in Bend

Three Bend programs replace the Haskell subcommands that built every corpus
this repository trained or evaluated on. Each writes exactly the bytes its
Haskell counterpart wrote; the comparison below was run on 2026-09-25, before
the Haskell backend was deleted (it survives at the tag `haskell-final`).

| Bend program | flake package | replaces (master) |
|---|---|---|
| `bend/Pack.bend` | `bend-pack` | `formal-transformer pack-stdin` |
| `bend/Prepare.bend` | `bend-prepare` | `formal-transformer prepare-bpe-stdin` |
| `bend/PlanSegment.bend` | `bend-plan-segment` | `formal-transformer plan-segment` |

Shared modules: `bend/Nul.bend` (the NUL-framed id/text stream, whole-file
reads and writes) and `bend/Ftcc.bend` (the FTCC v2 writer and master's
dataset fingerprint, FNV-1a 64 over the `Data.Binary` encoding of the
tokenizer identity and the documents).

## Differences in use

- **Files, not pipes.** Bend reads files; a pipe reports size 0 and reads as
  an empty stream. `deploy/plan-corpus.sh` and `deploy/build-code-evals.sh`
  write every intermediate NUL stream to disk.
- **Failures exit non-zero and write nothing.** Master's `prepare-bpe-stdin`
  printed failures and exited 0, and `plan-corpus.sh` had to inspect its
  stdout. Refusals keep master's messages, with the tool's own name as the
  prefix (`pack:`, `prepare:`, `plan-segment:`).
- **Unknown presets are refused.** `bend-plan-segment` checks the size name
  against `preset.names` in `bend/Train.bend`; `preset` itself still falls
  back to `small4-v3` for the trainers.
- **`prepare` prints `ordinary tokens: N`**, which `build-code-evals.sh` used
  to get from `inspect-corpus`.
- **One process per shard, `--threads 1`.** Measured on a 16-core machine on
  a 4,000-document code shard (23 MB): 41 s and 1.2 GB for `prepare`, 3.9 s
  and 1.7 GB for `pack`, 0.6 s for `plan-segment`. Splitting a shard's
  documents across the runtime's lanes gave 23 s wall for 41 s of CPU: this
  allocation-heavy work scales to about two cores inside one process.
  `plan-corpus.sh` runs `JOBS` shards at once (default: available memory
  over 3 GB, capped at the core count).

## The tokenizer, made fast without changing its meaning

`bend/Tokenizer.bend` was first measured at 70 KB/s on code. Two changes, both
checked byte for byte below:

1. The rank table is keyed by the whole pair (`a * 65536 + b`, a depth-32
   tree) instead of by the left operand with a linear scan over every merge
   sharing it (thousands for `code32k`'s common prefixes): 28 s to 11 s on 300
   documents.
2. `encode.word` keeps each token's pair rank beside it and recomputes only
   the ranks a merge touches; `encode.word.ref`, master's algorithm, stays in
   the file as the reference. One 82 KB file with a 7 KB space-free run went
   from 5.6 s to 1.5 s.

## The comparison

Every file compared with `cmp`; sha256 prefixes below are the Bend outputs,
equal to the Haskell ones.

**Plan, unpacked:** the first 20,000 lines of `run/code-train-v2.jsonl`
(sha256 `0c92578447d5d356`), `bpe100m-v3`, batch 64, 4,000 per shard.

| file | sha256 |
|---|---|
| plan-bpe100m-v3-b64-s4000.tsv | 4fd798e2e182e1be |
| shard-0-bpe100m-v3.corpus | cb04ed70a626cc43 |
| shard-1-bpe100m-v3.corpus | 22fe00be840d680d |
| shard-2-bpe100m-v3.corpus | 25d0349d30a283cc |
| shard-3-bpe100m-v3.corpus | 0ad1048859baf7bc |
| shard-4-bpe100m-v3.corpus | 4893e8173cd9d5d4 |

**Plan, packed and grouped:** the same slice, `PACK_TARGET=131072
PACK_GROUP=1`, `bpe460m`, batch 16, 2,000 per shard: the plan
(`738d9e07cdd820bc`), ten shards and ten pack-count sidecars, 21 files, all
equal.

**Eval corpora** rebuilt from their sources and compared with the committed
files in `run/eval/`:

| file | sha256 | source |
|---|---|---|
| code-haskell.corpus | 3acb8446ae5868fc | `deploy/build-code-evals.sh run/code32k.bpe OUT run/code-eval-v2.jsonl` |
| code-nix.corpus | 44acfaed61f51880 | same |
| code-agda.corpus | 76632f4151f9cf58 | same |
| code-lean.corpus | 25c199c241beb7dd | same |
| code-idris.corpus | 33c8b28cef26f668 | same |
| transcript-code32k.corpus | abcb6a61b090c47e | `docs/M2-RUNBOOK.md` section 4, with `bend-pack` and `bend-prepare` |

**Unit cases** (each tool against master on the same input): `pack` under
the default, `--group`, `--target 5000` with and without `--group`,
`--target 1 --prefix shard7`, `--target 300000 --group --separator ';'`, and a
stream with an empty text, a UTF-8 id and a `0xff` id byte; `prepare` on the
same stream (ids read as Latin-1 characters, so `0xff` is two bytes in the
file); `plan-segment` at offsets 0, 4000, 8000 and 12000, batches 1, 7, 16
and 64, presets `tiny`, `bpe100m-v3` and `bpe460m`, packed and unpacked; the
refusals (an incomplete final pair, an empty id, an empty stream, `--target
0`, a prefix with `/`, a value option without its value).
