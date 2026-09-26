# Coding-agent transcripts: the format and how they are made

The corpus teaches a model to write functional programs and proofs against a
checker. Every transcript is one document of plain text that fits one context
window (2,048 tokens under `code32k`, less 64 of margin). Its turns are
labeled by role, and the type (or proposition) is a separate turn from the
term (or proof) that inhabits it. **Every line a checker is said to have
printed was printed by that checker** on the code shown, in the harness
described below; nothing is paraphrased.

## Turns

A turn is a line `## <label>`, a blank line, and its body. Code sits in a
fence tagged with its language (`haskell`, `agda`, `lean`, `bend`, `nix`).

| label | who | body |
|---|---|---|
| `## User` | the person | the task in prose |
| `## Context` | the checker | the types of the names the answer uses, in the checker's own printing |
| `## Type` | given, or the assistant | a flag line, `proposition` or `type`, then the signature or statement |
| `## Term` | the assistant | the program or proof |
| `## ghc`, `## agda`, `## lean`, `## bend`, `## nix` | the checker | its output verbatim (at most 40 lines; a longer one ends with `[N more lines]`), then `[exit N]`, its exit status |

The checker turn is named for the tool, because the model must learn which
tool speaks which dialect. Lean and Bend print nothing or one line on
success, so the exit line is what says the check passed. A goal display from
Agda's interaction mode is not a process, so it has no exit line.

The prose turns: the User line is the declaration's doc comment when it has
one, else a plain request (``Define `f`.``, ``Prove `f`.``, ``Write the type
signature of `f`.``, `Write this Nix expression.`). A Claude-written task
line and a one-sentence diagnosis before a repair are planned
(a Bend driver over the Message Batches API, not yet written or run); only prose will ever be
generated, never code or checker output.

### The flag line: proposition or type

Under Curry-Howard the two are one kind of thing; the flag says which reading
the source intends, and only a rule the checker enforces or the author wrote
sets it to `proposition`:

| language | `proposition` when | otherwise `type` |
|---|---|---|
| Lean | the declaration is a `theorem` or `lemma` (Lean rejects a theorem whose type is not a `Prop`) | `def`, `abbrev`, `instance` |
| Bend | the declaration is a `law`; its proof is the paired `def` | every other `def` |
| Agda | the signature's result (after its last `→`) mentions `≡ ≤ < ≈ ¬ ↔ ⊥ Dec ∈ ⊆ ∼`, or the file's id contains `Properties` (a heuristic: Agda has no Prop) | all other signatures |
| Haskell | never | every signature |
| Nix | no `## Type` turn | |

Counts on the pilot samples (units, before checking): Agda 91 propositions of
475 (the agda repository and agda2hs) and 31 of 60 (the standard library);
Lean 94 of 115 (mathlib) and 168 of 483 (lean4's tests); Bend 29 of 159.

## The task shapes

The shape comes from a hash of the unit's id:

| shape | share | given | the assistant writes | the checker turns |
|---|---|---|---|---|
| type to term | 60% | User, Context, Type | the Term | a quarter answer right the first time; the rest answer with a mutant, read the error, answer with the original, read the verdict |
| hole | 25% | User, Context, Type, a Term with a hole | the filled Term | the goal at the hole, then the verdict |
| term to type | 15% (ghc only) | User, Context, Term | the Type, with its flag | ghc's own type for the name (`-Wmissing-signatures`), then the verdict with the answer's signature |

A unit that lacks what its shape needs (a hole check; a type check, which only
ghc gives) is rendered type to term. A unit whose first transcript left a
failing mutant unused gives a second, a repair with that mutant, so one
declaration gives at most two transcripts.

Holes are each language's own: `_` in Haskell (a typed hole, with
`-fno-show-valid-hole-fits`, since the fits often name the answer) and in
Lean (the placeholder error prints the goal and its context), `?` in Agda
(the goal and context from `Cmd_goal_type_context`), `?goal` in Bend.

## A Haskell transcript (type to term, one repair)

Produced by the pipeline from `hackage:aasam/lib/Util.hs` (ghc 9.10.3); the
mutant dropped one word:

````
## User

Define `tup`.

## Type

type
```haskell
tup :: a -> b -> (a, b)
```

## Term

```haskell
tup a b = (, b)
```

## ghc

```
[1 of 1] Compiling Unit             ( Unit.hs, nothing )
Unit.hs:18:11: error: [GHC-83865]
    • Couldn't match expected type: (a, b)
                  with actual type: t0 -> (t0, b)
    • In the expression: (, b)
      In an equation for ‘tup’: tup a b = (, b)
    • Relevant bindings include
        b :: b (bound at Unit.hs:18:7)
        a :: a (bound at Unit.hs:18:5)
        tup :: a -> b -> (a, b) (bound at Unit.hs:18:1)
   |
18 | tup a b = (, b)
   |           ^^^^^
[exit 1]
```

## Term

```haskell
tup a b = (a, b)
```

## ghc

```
[1 of 1] Compiling Unit             ( Unit.hs, nothing )
[exit 0]
```
````

## A Haskell transcript (term to type)

````
## User

Write the type signature of `unwrapOr`.

## Context

```haskell
Just :: a -> Maybe a
```

## Term

```haskell
unwrapOr _ (Just x) = x
unwrapOr y _ = y
```

## ghc

```
Unit.hs:13:1: warning: [GHC-38417] [-Wmissing-signatures]
    Top-level binding with no type signature:
      unwrapOr :: a -> Maybe a -> a
   |
13 | unwrapOr _ (Just x) = x
   | ^^^^^^^^
[exit 0]
```

## Type

type
```haskell
unwrapOr :: a -> Maybe a -> a
```

## ghc

```
[1 of 1] Compiling Unit             ( Unit.hs, nothing )
[exit 0]
```
````

## How transcripts are made

```
source files ──► bend-units ──► units.nul ──► bend-check LANG ──► results.nul
 (NUL stream)    (Units.bend)                 (the real checker)
                                                              │
                                                              ▼
                                         bend-transcript ──► transcripts.nul ──► packing ──► bend-prepare
                                         (Transcript.bend)
```

`bend-transcripts STAGE LANG` (`bend/Transcripts.bend`) runs the stages for
one language from the code corpus: `sources` (the language's files as a
NUL stream, split by how many units a file may give), `units`, `check`,
`render`, or `all`; outputs and a UTC-6 log in `run/transcripts/LANG/`.

1. **Units** (`bend-units LANG IN.nul OUT.nul [MAX_PER_FILE]`). Each source
   file is cut into declarations by the column-0 layout every one of these
   languages uses: Haskell `f :: T` and its equations, Agda `f : T` and its
   clauses, Lean `theorem|lemma|def|abbrev|instance` split at its first
   top-level `:=`, a Bend `law` with the `def` proving it or a typed `def`,
   a whole Nix file. A body is at most 40 lines and 3,000 bytes; at most
   MAX_PER_FILE units (default 4) come from a file, spread evenly over it.
   A unit carries the file around the body (head ++ declaration ++ body ++
   tail is the file, byte for byte; checked on all 2,087 pilot units), its
   doc comment, the names its body uses, a hole variant, and up to four
   mutants: a name the body uses replaced by another (twice), two adjacent
   words swapped, a word dropped. Words in comments and string literals are
   never touched, nor a line's first word (an equation's own name).
   Positions come from a hash of the unit's id, so the corpus is
   reproducible.
2. **Checking** (`bend-check LANG UNITS RESULTS [JOBS]`, formats in
   `bend/Check/Lib.bend`, each checker in `bend/Check/<Lang>.bend`). The real checker runs on the original, the hole
   and each mutant; a unit whose original fails is dropped (usually an
   import the harness lacks), and a mutant that still checks is dropped.
   The same run asks the checker for the types of the names the body uses
   (ghci `:type`, Agda `Cmd_infer_toplevel`, Lean `#check`, Bend `bend base`
   or the file's own `def` line); a name it cannot type (a local) is left
   out. Lean goes through `deploy/check/Harness.lean`, which elaborates a
   file's head once and every variant from the state it left, printing what
   `lean` prints for head ++ variant.
3. **Transcripts** (`bend-transcript TOKENIZER RESULTS OUT [WINDOW]`) picks
   the shapes, renders the turns, and drops any transcript whose tokens
   (plus BOS and EOS) pass the window less 64; none is cut.

## The pilot (2026-09-25, one 16-core machine)

| sample | files | units | kept | mutant errors | holes | Context | transcripts | check time |
|---|---|---|---|---|---|---|---|---|
| Haskell (first 300 Hackage files) | 300 | 716 | 72 (10%) | 203 | 56 | 59 | 143 | 42 s, 16 jobs |
| Lean (60 mathlib files) | 60 | 115 | 104 (90%) | 354 | 104 | 103 | 204 | 180 s, 6 jobs |
| Agda (50 standard-library files) | 50 | 60 | 52 (87%) | 160 | 37 | 41 | 104 | 130 s, 12 jobs |
| Nix (first 300 files) | 300 | 254 | 169 (67%) | 410 | – | – | 299 | 7 s, 16 jobs |
| Bend (bend/Spec, two tools, bend2's evals) | 44 | 159 | 120 (75%) | 322 | 120 | 65 | 216 | 60 s, 16 jobs |

The 966 transcripts hold 361,206 `code32k` tokens (374 each on average;
none passed the window). Units cost 1.5 MB/s of source in one process.

**Where units are lost.** Haskell: 88 of 103 sampled failures import a
module of their own package (the harness has one file, not the package); the
lever is to rebuild each package's source tree and pass `-i`. Lean holds
about 9 s per unit per worker (the Mathlib import and the file's head), so a
worker is ~3 GB and a 31 GB machine runs 6. Bend: bend2's evals are tasks
with deliberate TODOs and fail by design.

## Cleaning

Done in the steps above: only reproduced checker output (the original must
check, a mutant must fail, the output shown is the output produced); no word
of a comment or a string is mutated; transcripts past the window are dropped,
not cut; at most two transcripts per declaration.

`bend-clean` (`bend-transcripts clean LANG`) then drops, per language and
before rendering, in this order, each count in `results.train.nul.stats`:

- **Exact duplicates**: a unit whose signature and body are an earlier
  unit's (vendored copies across packages become one unit).
- **Contamination**: a unit sharing a 10-gram of whitespace words with a
  text of `run/code-eval-v2.jsonl`, the whole-project holdout (the units
  come from `code-train-v3.jsonl`, which holds none of those projects, so
  this catches copies).
- **Near duplicates**: MinHash over 5-word shingles (128 hashes, 32 bands
  of 4); a candidate pair whose signatures agree in 90 of 128 places
  (Jaccard about 0.7) drops the later unit.
- **Holdout**: 2% of the rest by a hash of the unit id goes to
  `results.holdout.nul`, rendered apart as `transcripts.holdout.nul`.

Bend, the first language through it: 4,643 kept units → 918 exact
duplicates, 161 near duplicates, 9 contaminated (generic runs such as a
long `f0, f1, … f9` field list), 3,494 train, 61 holdout.

Still to build:
- **Mix** by transcript count with `bend-mix`: Haskell 35, Lean
  25, Agda 20, Nix 10, Bend 10, plus 5% raw code as an anchor; interleave,
  never concatenate.
- **Packing.** The trainer drops any document shorter than a window, and a
  transcript averages ~374 tokens: transcripts are packed whole into
  one-context windows, EOS between them, the gap filled with the end of a
  code file (`bend-windows lengths`, `plan`, `build`; next fit in order, so
  a window holds neighbouring units).
