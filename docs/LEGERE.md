# legere: a Bend Jev for ana's training data

`bend-legere` reads raw text, cuts it into sections tagged with ana's tags,
gives every line and boundary a posterior, and hands the code it finds to
the existing checkers and renderer. Its first source is the user's Claude Code
sessions (`~/src/llm-transcript/corpus.jsonl`).

The name is Latin, *legere*: both "to read" and "to pick out, to gather".

## What Jev is, and what we took from it

Jev (TypeSafe AI, "System One") is a *decision model*. Evidence plus a typed
question goes in; a typed answer with a probability comes out, never prose.
The only verified view of how Jev segments text is DocJev
(github.com/jerryjliu/docjev):

- It asks two typed questions per page: a category (`Choice`) and "does a new
  document start here?" (`Noul`).
- It builds contiguous segments from the answers.
- It claims **no** calibration. A segment's score is the plain mean of its
  pages' scores.

legere keeps the typed questions and drops the unmeasured probabilities:

| Jev | legere | answer's meaning |
|---|---|---|
| classify (`Choice`) | a line's tag | `P(tag | text)`, by forward-backward |
| `Noul` (boundary) | a section starts at line i | `P(tag_{i-1} ≠ tag_i | text)` |
| check | the language's compiler | deterministic: the checker is the decider |

## The meaning (`bend/Legere/Spec.bend`)

A text is a list of lines. A labelling gives each line a tag. A section is a
maximal run of lines with one tag, so labellings and segmentations are the
same thing. A model gives weights in a semiring:

- `start` weighs the first tag;
- `trans` weighs each tag followed by the next;
- `final` weighs the end;
- an emission table weighs each line under each tag.

The text's weight is the sum, over every labelling, of the product of its
weights. That is the weighted language `(Σ_t s_t · (Λ_t)⁺)⁺` over the
alphabet of lines. It is Elliott's convolution semiring and Goodman's
semiring parsing: one meaning, and the carrier picks the question.

| carrier | question |
|---|---|
| Bool | is the text well formed? |
| Nat | how many segmentations does it have? |
| logp (log-sum-exp, +) | the marginal; with forward-backward, every posterior |
| maxp (max, +) | the best labelling: Viterbi |

Sections are never empty, so the star is a finite sum on every finite text,
in any semiring. `[0,1]` not being a closed semiring never arises.

The Spec definitions enumerate every labelling: they are exponential, the
specification. `bend/Legere/Forward.bend` computes the same values in linear
time. That is the memoized derivative: after i lines, all the rest of the
text needs is one weight per tag. `bend/tests/legere.bend` holds the two
together:

- exactly in Nat and Bool, on toy models with zero weights, for every text of
  0..6 lines;
- Bool equals Nat's support (n ↦ n > 0 is a semiring homomorphism);
- within 1e-4 in logp and maxp, with posteriors summing to 1.

`law roundtrip` is proven: concatenating the sections' lines gives the
lines back. With `Units.lines` keeping each newline, a segmentation never
loses or reorders a byte.

**Calibration is a measurement, not a claim.** The ideal legere denotes the
data's true `P(tag | text)`: the log-score is strictly proper, so that is
its unique minimiser. The model approximates it, and the gap is reported as
bits per line and ECE on held-out sessions.

## Tags

| index | tag | scored by |
|---|---|---|
| 0 | prose | line model |
| 1-5 | haskell, agda, lean, bend, nix (the checkable languages) | line model |
| 6 | shell | line model |
| 7 | diff | line model |
| 8 | output | line model |
| 9 | code (any other language) | line model |
| 10 | open (a fence's opening line) | shape |
| 11 | close (a fence's closing line) | shape |

## Cues: the labels and the evidence (`bend/Legere/Lines.bend`)

A cue is evidence written in the text:

- a fence's info string;
- a session's tool header before a fenced block:
  - `### Write — \`path.ext\``, `### Read — \`path\``: the extension names the block;
  - `### Edit — …`: a diff;
- `**stdout:**` and `**stderr:**`: output.

Fences follow CommonMark. A block opened by n backticks closes at a line of
at least n backticks and nothing else, so a ```` fence holds ``` lines.

Each line gets two labels:

- **gold:** what the cues say. Outside fences, gold is prose; inside, the
  block's tag (unknown when no cue names it); on fence lines, open and close.
  legere trains and scores on gold.
- **mask:** what the cues force in production. That is the fence lines and
  the lines of named blocks. Outside fences nothing is forced, so code with no
  fence can still be found.

A mask conditions the model on evidence: it zeroes every labelling the cue
contradicts, and the meaning is unchanged.

## The line model (`bend/Legere/Ngram.bend`)

`Λ_t(line)` is a byte 4-gram with Witten-Bell smoothing, scored from the
line's own start. A line's weight never depends on the line before it.

- **Counts:** every tag's counts share one hashed `Array<F32>` of 2^26
  slots. A collision adds another key's count. The test checks that
  Σ_b P(b | h) = 1 where there are none.
- **Training data:** the sessions' gold-labelled lines (all but the
  validation tenth), plus each checkable language's source files from
  `run/transcripts-final/LANG/files-{hi,lo}.nul`, every k-th file so the
  sample spreads over the whole file.
- **Balance:** every tag trains on at most `BUDGET` bytes (6 MB). A tag's
  session lines past the budget are sampled by line hash, so no tag's model is
  richer than another's just because its class is common.
- **Transitions:** start, transition and final weights come from the
  sessions' gold labels, add-half smoothed. A tag's next-line distribution
  and its end weight are normalized together.
- **The setting:** a line's weight is either its log-likelihood times s, or
  its mean log probability per byte times s. The lines of a section are
  scored as independent given the tag, which makes summed scores
  overconfident on long blocks. Both forms, and s, are picked on the
  validation tenth (ids whose FNV-1a is 0 mod 10) by minimising bits per
  line; the holdout file is never used to pick them.

## Stages

All stages run from the repository root, as `nix run .#deploy -- legere STAGE ...`.

| stage | what it does |
|---|---|
| `eval CORPUS HOLDOUT` | Trains on CORPUS and fits the setting on its validation tenth, then scores HOLDOUT against the baselines. |
| `segment CORPUS INPUT OUT` | Trains and fits the same way, then labels every INPUT document with every cue forced. It writes the files below. |
| `units OUT LANG` | Runs `bend-units` on `OUT/LANG/files.nul`. Each unit's `doc`, which becomes the transcript's User line, is set to its file's User line, giving `OUT/LANG/units.nul`. `bend-check`, `bend-clean` and `bend-transcript` then run unchanged. |
| `notes OUT LANG` | Compiles every code file whole, pass or fail, into `OUT/LANG/notes.nul`. A record is the file id, then `status 0x1F output` (first 40 lines). The commands are `ghc -fno-code`, `agda` (the top module renamed Snippet), `lean`, `bend --check-only`, and `nix-instantiate --eval --strict` (`NIX_PATH=` empty). |
| `explain CORPUS FILE` | Prints each line's mean log probability per byte under every tag: the evidence before the scale and the transitions. |

`segment` writes:

- `OUT/sections.nul`: one record per section. The id is `DOC#K`; the text is the tag, first line, line count, shares and the section's text, joined by 0x1E.
- `OUT/LANG/files.nul`: the code to check, with ids `own:legere/DOC-K.EXT`.
- `OUT/LANG/prose.nul`: each code file's User line, under the same ids.
- `OUT/src/legere/`: the Bend files, for `BEND_SRC`.

The environment variables:

- `LANGS` (`run/transcripts-final`): where the language source files are read.
- `BUDGET` (6000000): the most bytes any tag trains on.
- `BEND_UNITS` (`bend-units`): the units tool `units` runs.

## Measurements (2026-10-02, the sessions corpus)

**Training data:** `~/src/llm-transcript/corpus.jsonl`, 3,172 documents from 22 sessions.
- 2,845 documents train the model.
- 327 (ids FNV-1a 0 mod 10) fit the setting.
- **Held out:** `corpus.jsonl.holdout.jsonl`, 273 documents from 4 other sessions. It is never trained on or fitted to.
- Every population below is lines of those 273 documents that a cue labels.

**The setting.** Mean per-byte line scores times 0.5 had the fewest validation bits of the 17 settings tried (sum at temperatures 1..512, mean at scales 0.25..64). Summed line scores needed a temperature of 32 and still lost: they count a block's lines as independent evidence, so a long block is wildly overconfident.

**Named blocks with names hidden** (10,718 lines inside fenced blocks a cue names): the fence lines are forced, the cue is hidden, and the block's tag is predicted from content. This is the bare-fence case.

| | bits/line | accuracy | ECE |
|---|---|---|---|
| legere | **0.593** | **86.8%** | 0.067 |
| baseline p(tag \| inside a block) | 1.680 | 53.0% | |

**No fences** (19,990 labelled lines, nothing forced): prose vs code vs fences, found from content alone.

| | bits/line | accuracy | ECE | boundary F1 |
|---|---|---|---|---|
| legere | **0.615** | **84.9%** | 0.042 | 0.657 (precision 0.997, recall 0.49) |
| baseline prior p(tag) | 2.322 | 35.8% | | |

**Recall per tag** (named blocks): output 92%, diff 89%, shell 84%, prose 27%, haskell 0% of 123, code 0% of 90, nix 0% of 7. The holdout has no Agda, Lean or Bend lines.

**The known weakness: a minority language inside an unnamed block.**
- `explain` shows the line model does prefer Haskell on Haskell lines, by 0.1–0.6 nats per byte over output.
- But the entry prior comes from named blocks, and most of those are stdout (`**stdout:**` cues). "Output" is about 90 times more likely after a fence than "haskell".
- The calibrated scale (0.5) does not let a 20-line block overcome that.
- That prior is right for the population above, which is why calibration chooses it. A genuinely bare block never carries a stdout cue, so its prior is different.
- The next model splits the entry prior by the fence's authoring context: a tool's output block versus an assistant-written fence.
- Neither more training text (6 MB vs 2 MB per tag) nor balancing the tags' bytes changed this recall.

**`segment` on the whole corpus** (3,172 documents, 118 s, 0.9 GB):
- 51,368 sections.
- Every document's sections give its text back byte for byte; the round trip is proven in Spec and checked here on all 3,172.
- 15 code sections went on to the checkers: 10 Haskell, 4 Agda, 1 Nix.
- 38 more Haskell Write blocks were left out because the session converter elided their middles (`… (132 lines elided) …`).

**The checkers on those 15 sections:**

| | units | kept by `bend-check` | whole files compiling (`notes`) |
|---|---|---|---|
| Haskell | 8 | 4 (8 transcripts) | 4 of 10 |
| Agda | 5 | 0 | 1 of 4 |
| Nix | 1 | 1 (2 transcripts) | 1 of 1 |

The failing files fail for real reasons: a missing `transpose` import, project modules that are not on disk, Agda names used without imports, declarations without definitions.

## Rules

- **Haskell wrap:** a snippet with no `module` line gets `module Snippet where` after its leading pragmas. `bend-check` skips a file without one, since a Main module needs `main`.
- **Agda (`notes`):** the first `module NAME` names `Snippet`, so the module matches its file.
- **Elided code is never checked.** A section containing `… (N lines elided) …` is not the file.
- **The User line:** the last paragraph of the most recent prose section that has one. Paragraphs that are only headings, tool cues (`### Write — …`, `**stdout:**`) or `*(thought for …)*` are skipped. At most 1 KB, keeping the end.
- **What goes to the checkers:** a section whose share of one checkable language is at least 0.9.
- **What becomes a transcript:** what ana's rule keeps. `bend-check` drops a unit whose original fails, so no transcript answers with broken code. The `notes` stage keeps every compiler's output on every piece of code anyway.
