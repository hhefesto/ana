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
  an empty stream. `bend-plan-corpus` and `bend-code-evals` (once
  `deploy/plan-corpus.sh` and `deploy/build-code-evals.sh`) write every
  intermediate NUL stream to disk.
- **Failures exit non-zero and write nothing.** Master's `prepare-bpe-stdin`
  printed failures and exited 0, and the planner had to inspect its
  stdout. Refusals keep master's messages, with the tool's own name as the
  prefix (`pack:`, `prepare:`, `plan-segment:`).
- **Unknown presets are refused.** `bend-plan-segment` checks the size name
  against `preset.names` in `bend/Train.bend`; `preset` itself still falls
  back to `small4-v3` for the trainers.
- **`prepare` prints `ordinary tokens: N`**, which the code-evals driver used
  to get from `inspect-corpus`.
- **One process per shard, `--threads 1`.** Measured on a 16-core machine on
  a 4,000-document code shard (23 MB): 41 s and 1.2 GB for `prepare`, 3.9 s
  and 1.7 GB for `pack`, 0.6 s for `plan-segment`. Splitting a shard's
  documents across the runtime's lanes gave 23 s wall for 41 s of CPU: this
  allocation-heavy work scales to about two cores inside one process.
  `bend-plan-corpus` runs `JOBS` shards at once (default: available memory
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

## The drivers and the checkers (2026-09-25, evening)

The shell in `deploy/` became Bend programs, each gated byte-identical
against its script before the script was deleted (the scripts are in
`159d8e4`). They run programs through `Sys.run` in `bend/Sys.bend`: the
fork's `Process.run` under `sh -c 'cd "$1" && shift && exec "$@" 2>&1'`
with coreutils `timeout`, so a working directory, an environment, the
timeout's status 124 with the output so far, and stderr merged in write
order are as the shell had them.

| tool | replaces | gate | result |
|---|---|---|---|
| `bend-check nix` | `check/nix.sh` | 300 units (+12 with a trailing empty field), 1 worker vs 4 | identical records and stats (after the fixes below); 40 s vs 2m12s |
| `bend-check bend` | `check/bend.sh` | 112 units | identical; 1m28s vs 5m10s |
| `bend-check lean` | `check/lean.sh` | 41 mathlib units | identical; 2m vs 5m |
| `bend-check haskell` | `check/haskell.sh` | 138 units of 8 packages (Hackage, repos, curated, own) | identical, input order included; 2m33s vs 1m59s (4 workers vs 1, batch GHCi) |
| `bend-check agda` | `check/agda.sh` | 69 units, after the library precompile, `FTUnit*` cleared before each side (below) | identical, 455,831 bytes; 20m33s vs 23m7s, one worker each, under load |
| `bend-check agda-libs` | `check/agda-libs.sh` | a copy of the libraries, a stub agda | identical trees and sessions |
| `bend-transcripts` | `transcripts.sh` | sources of all five languages; units of Nix and Bend | identical |
| `bend-extract` | `extract-code.sh` | 80 tarballs, 8 repos, own, curated; holdout on | identical against the script with sorted listings (the port's order fix) |
| `bend-plan-corpus` | `plan-corpus.sh` | 20,000 documents, unpacked and packed, resume | parts, corpora, sidecars and plans identical |
| `bend-code-evals` | `build-code-evals.sh` | a 309-line holdout slice with NULs | the five corpora identical |
| `bend-mix` | `mix-corpus.sh` | plain, repeated, cycled, dry, duplicate ids, usage errors | identical output and summary |
| `bend-push` | `push-corpus.sh`, `check-link.sh` | stub ssh and rsync, 16 cases | identical output and commands |

Fixes the port carries (each one visible in its gate): a record's trailing
empty field is kept (the shell's `readarray` dropped it and `set -u` then
killed the worker); an Agda message with a raw control character is
decoded instead of lost; results come in input order; the work directory's
parent is stripped from messages as well as the directory; extraction
lists sources and files in byte order; an empty `:cycle` source stops the
mix instead of hanging. Found in the shell while gating and fixed in
`159d8e4` so the reference was right: the keys files read whole by gawk,
CRs in a Windows `.cabal`, a dead GHCi killing its worker through SIGPIPE.

Agda's bytes depend on the state of the libraries' interfaces: a unit is
checked inside its library as `FTUnit<k>.agda`, and its interface stays in
the library's `_build`, so a second run of the same unit finds it up to
date and prints nothing for it, and a library module another run built
is no longer printed as checked. The gate therefore clears the `FTUnit*`
files before each side and runs after the library precompile has ended.
