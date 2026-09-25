# Milestone 2 runbook — code corpus, tokenizer, evaluations (local, free)

Everything below runs on the workstation.  M1 got a runbook because it bills
by the hour; M2 gets one because `run/code-train-v2.jsonl` and `run/code32k.bpe`
are the inputs to a ~$250-350 run and must be reproducible and auditable from
the repo.  These are the invocations that produced the artifacts on disk.

**2026-09-25:** the `formal-transformer` commands below are the Haskell CLI,
kept at the tag `haskell-final` (with the deleted `deploy/build-tokenizer-sample.sh`).
`pack-stdin`, `prepare-bpe-stdin` and `plan-segment` have Bend replacements that
write the same bytes (`docs/BEND-CORPUS-TOOLS.md`); section 4 now uses them and
reproduces the per-language and transcript corpora in `run/eval/` exactly.
`learn-bpe` and `prepare-bpe` (whole files as documents, with a fingerprint over
the source bytes) have none: `code32k.bpe` is fixed (a copy is vendored as
`weights/code32k.bpe`) and `enwik8-test-code32k.corpus` stays as built.

## 1. Acquisition (`run/code-sources/`)

- **Hackage** (`tarballs/`, 19,418 of 19,426 packages; the 8 absent are pulled
  spam): package list from `index.tar.gz`, latest version of each package —
  versions must start with a digit, or `preferred-versions` index metadata
  wins the `sort -V` and 1,429 packages vanish — fetched one tarball each over
  plain HTTP (`fetch-one.sh`, unauthenticated).
- **Repositories** (`repos/`): `git clone --depth 1` of mathlib4, batteries,
  lean4, agda-stdlib, cubical, agda, idris2; nixpkgs symlinked from `~/src`.
  1lab was cloned and is dropped by the license gate (AGPL-3.0).
- **The user's own code** (`own/`): 23 repositories from `github.com/hhefesto`
  and local `~/src` copies.  Never license-gated, never held out.

## 2. Extraction

```
HOLDOUT_OUT=run/code-eval-v2.jsonl HOLDOUT_PERCENT=2 \
  deploy/extract-code.sh run/code-train-v2.jsonl
```

Ids are `namespace:group/path` (`hackage:`/`repo:`/`own:`); the percent bucket
hashes the bare name, so the sampled 2% matches the pre-namespacing pull.
`HOLDOUT_GROUPS` defaults to the named non-Haskell holdout
(`repo:cubical repo:batteries repo:nixpkgs/nixos repo:idris2/tests`) — a
percentage alone holds out zero non-Haskell projects, because those languages
live in about eight repositories.

The original 2026-08-22 pull (`run/code-train.jsonl` / `run/code-eval.jsonl`,
bare un-namespaced ids) is superseded by the `-v2` files: same sources, same
license gate, but the Hackage package `cubical` no longer collides with the
Agda repository `cubical` in the holdout (that collision put 7 Haskell and 2
Nix files into the wrong eval populations).

## 3. Tokenizer (`run/code32k.bpe` — TRAINED AND FIXED, do not retrain)

Retraining would change the identity string and orphan every corpus that
records it.  For the record, it was produced by:

```
deploy/build-tokenizer-sample.sh run/code32k-sample.nul \
  run/mixed-corpus.jsonl:300 \
  'run/code-train.jsonl:130:\.(hs|lhs)$' \
  'run/code-train.jsonl:55:\.nix$' \
  'run/code-train.jsonl:20:\.(agda|lagda)$' \
  'run/code-train.jsonl:60:\.lean$' \
  'run/code-train.jsonl:8:\.(idr|ipkg)$'
formal-transformer learn-bpe run/code32k.bpe 32768 3 < run/code32k-sample.nul
```

(BPE_PRETOKEN defaulted to v2.)  The sample was drawn from the original
extraction; the tokenizer does not depend on document ids, so the -v2
re-extraction does not invalidate it.  Two hashes, not interchangeable: file
sha256 `1e2238ce…` (what plan headers record) vs the identity-string digest
`d663505817ea2e60…` (canonical merge list only, pretoken rule excluded).

## 4. Evaluation corpora (`run/eval/`)

```
# per-language, from the held-out repositories, packed exactly as training:
deploy/build-code-evals.sh run/code32k.bpe run/eval run/code-eval-v2.jsonl

# enwik8 under the code tokenizer: the last 5 MB as ONE document:
tail -c 5000000 run/eval/enwik8 > /tmp/enwik8-test.txt
formal-transformer prepare-bpe run/code32k.bpe \
  run/eval/enwik8-test-code32k.corpus /tmp/enwik8-test.txt

# the Claude-Code transcript holdout (273 docs, 4 whole sessions, scrubbed):
jq --raw-output0 '.id, .text' < ~/src/llm-transcript/corpus.jsonl.holdout.jsonl > /tmp/tr.nul
bend-pack /tmp/tr.nul /tmp/tr.packed.nul --target 131072 --prefix transcript --stats
bend-prepare run/code32k.bpe /tmp/tr.packed.nul run/eval/transcript-code32k.corpus
```

Holdout strength varies and must be quoted with the number: Haskell, Agda and
Lean hold out WHOLE projects; Nix (`nixpkgs/nixos`) and Idris
(`idris2/tests`) hold out a subtree of the project trained on — a weaker
claim.  By documents the Idris holdout is two thirds of the language (664
train / 1,311 eval files); by bytes it is the ~0.9 MB of 7 MB the design doc
records.

## 5. What waits on Milestone 1

`TRAIN_BATCH` from the M1 sweep gates Phase A planning (§2.3 of the plan) and
the wiki-heldout rebuild against code32k.  The Phase B mix (code anneal) is a
decision, not a blocker — see `deploy/mix-corpus.sh` for `:cycle` vs
`:REPEATS`, and remember: anything repeated or cycled is excluded from eval
populations, the transcript corpus and the user's own repos are never cut,
and PACK_GROUP requires group-contiguous input, so per-source packing happens
BEFORE mixing.
