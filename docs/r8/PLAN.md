# R8: R7's corpus, fixed before any more GPU money (2026-11-17)

The user, 11-16: "if there is a clear way to improve the corpus for the size of ana, I want to do that before
spending money on training. give me your recommendation given this"; "fillers shouldn't be latex, it should be
regular English prose. That is one item we need to fix before starting to train". 11-17: "Do start the rebuild
with your recommendations. Add the edgar code too. The filler should be De-LaTeX-ed."

Why: on the 176-task Bend test, *right* stayed at 46, 46, 46, 45, 36 (r5-step90000, r5g-step100000,
r5g-step106500, r6-step110000, r6-step113000; run/v9/ev) while training went on. What R7 (as built 11-16) trains
on, measured 11-16 (read-only, /tmp/corpusq): 2.22 B tokens in 1,086,240 windows; 24% of them filler, and the
filler 73.6% LaTeX prose (arXiv 70.2%; 68.8% of the arXiv pieces' lines with a backslash); 1.76 sessions a
window; 1,916,913 sessions over 388,357 declarations (4.9 each); 30,097 sessions (1.6%) end in a give-up.

Nothing is rented: the GPU waits for the user's approval, as R7's did.

## The changes

| # | Change | Where | State |
|---|---|---|---|
| 1 | The theory prose de-LaTeX-ed | bend/DeLatex.bend (dl.doc, dl.score), bend/TheoryCut.bend (PROSE_MIN 950), tests/delatex.bend (20 ok) | running: run/v9/theory8 (ana-r8prose) |
| 2 | Less filler: whole sessions packed by best fit with a look ahead | bend/Windows.bend (WINDOW_FILL 950, WINDOW_LOOK 64; PLAN.order) | built (run/v9/gcroot-r8-windows) |
| 3 | At most 3 sessions a declaration, its last place for a kind it has not had | bend/R8.bend (bend-r8, R8_CAP 3), tests/r8.bend (14 ok) | built (run/v9/gcroot-r8) |
| 4 | The give-up endings out (mugen-fix-giveup-N) | bend/R8.bend (R8_GIVEUP drop) | built |
| 5 | El cubo de Edgar (col10c: 5,730 sessions before the cap) | run8.sh EXTRA | in the mix (ana-r8mix) |
| - | Trim the echoes (weight 0) | - | not done: measured 11-17, see below |

1. **De-LaTeX.** R7's bend-theory-cut changed nothing inside a line. Now each document is read by
   DeLatex.bend first: a LaTeX document from its `\begin{document}` to `\end{document}` or its bibliography;
   comments and nLab's layout go; formatting commands go and their arguments stay; pointers (`\cite`, `\ref`,
   `\label`, `\footnote`, `\url`, ...) go with their arguments; ~150 symbols become Unicode (`\to` →, `\mathbb{N}`
   ℕ); inline math stays only as a short formula (under 40 bytes, every command known); display math, code fences
   and the environments of dl.envs go. A line with anything else left (an unknown macro, `\frac`, a long formula)
   spoils its paragraph: the whole paragraph goes, as its sentences lean on what went ("Observe that" with its
   equation gone). A piece is kept only if 950 permille of its bytes are plain prose (letters, digits, blanks,
   `.,;:'"()-!?`). On pp2-000 (20 MB of arXiv): 4.3 MB kept before the score, 1,653 of 2,072 pieces at 970 or
   more. A piece between 950 and 970 reads as English with a few symbols (sampled).
2. **Packing.** R7's plan was next fit in order. With WINDOW_FILL=F a window opens with the next session and then
   takes, while one fits, the largest of the next 64 left that keeps it within F permille of the window; the gap
   is filler as before. `plan` writes PLAN.order, `build` reads the sessions in that order. On R7's shard 13
   (8,000 sessions, its own filler; /tmp/pw13): next fit 4,455 windows, filler 23.9%, 1.80 sessions a window
   (WINDOW_FILL unset: byte for byte R7's part-000013.plan); F=1000 3,631 windows, 6.6%, 2.20; **F=950 3,857
   windows, 12.1%, 2.07** (chosen: the prose stays a tenth of the tokens); F≤900 ran the shard's filler out.
   Built with the permutation: 3,857 windows of 2,046 tokens, every session once (winshow reads them back).
3. **The cap.** A session's declaration: its id less `mut:`, up to its first `@` (`repo:FILE#DECL`). The mix's
   order is a hash's, so the first ones read are a draw. On R7's Bend mix (1,530,072 sessions, 320,485
   declarations; awk, read-only) the rule keeps 59.8%. The mix itself now runs with CAP=2 repairs a unit (R7: 4).
4. **Give-ups.** 20,877 of R7's Bend mix are mugen-fix-giveup-N. A trade-off: they taught her to say she could
   not do it rather than claim a pass; R8_GIVEUP=keep brings them back.
5. **Edgar.** run/v9/f6c (col10c's render, 11-16): 3,751 main, 524 chains, 1,455 fixes; its authors' laws all
   timed out (PROOF.bend past 240 s), so no authors'-law asks.

**Not done: trimming the echoes.** Measured on R7's mix (400 MB, /tmp/corpusq/rep.awk): echo blocks repeated
whole in one session are 0.1% of the bytes; `defs that depend on` lists 1.7% (1.4% past 120 bytes). The 8-12%
the 11-16 recommendation guessed is not there, and a trimmed echo would differ from what the live checker prints
at inference. Left as it is.

## The chain (olimpo, CPU)

- ana-r8mix: `MIXONLY=1 run/v9/run8.sh` (run/v9/run8mix.log): f5's streams, col10, col10b, col10c, mugen's chats,
  prove, sorts, CAP=2, into run/v9/mix8.
- ana-r8prose: `run/v9/theory/filler.sh 6` with PROSE_OUT=run/v9/theory8/prose and the new bend-theory-cut
  (run/v9/theory8/prose.log); its in/ links to R7's documents.
- ana-r8chain: run/v9/r8chain.sh (run/v9/r8chain.log): waits for both, then run8.sh whole: bend-r8 on each
  language's mix (run/v9/mix8/LANG.r8), the filler (Bend's files K=3, the prose), plan-windows with WINDOW_FILL=950
  into run/v9/R8, R8valid (the give-ups out, no cap), then TrainDense's reading of R8valid on the CPU.

## 11-17, second try: the assessment and its fixes

The user, 11-17: "Assess the corpus"; "Get more filler text if needed"; "Category theory and algorithm text
books"; "Fix and prompt me when ready to train". The first try's packing failed on 99 of 140 shards ("no unused
document of at least N tokens"): best fit spends a whole filler document on a window's gap (100-500 tokens), and
shard 0 had 4,194 documents for ~3,900 windows though it held 14 times the tokens it needed.

**The assessment** (read-only, /tmp/r8assess/mix.awk, filler.awk, on the first try's run/v9/R8.v1/mix.nul and
filler.nul):

- Sessions: 1,114,877 (R7 1,916,913), 2.60 GB, mean ~884 tokens (70% under 1,024; 0.7%, 8,083, over a window and
  left out by the planner). Bend 917,253; Agda 99,786; Haskell 38,767; Nix 32,386; Lean 26,678. El cubo de Edgar
  2,433. 390,980 declarations, 351,448 of them with exactly 3 sessions (the cap). Echo blocks 54.3% of the bytes
  (weight 0). Endings: ALL PROOFS CHECK 866,156; SOME PROOFS FAIL 50,969 (4.6%: the file's other defs lean on
  @unsafe or foreign code; the user, 11-12: keep @unsafe); the other languages' checker passes 197,617; 91 with
  give-up words left. Near-duplicates (same length, head and tail) 9,912 (0.9%).
- **Private lines: 10 sessions of the user's own code** (four Nix files of the user's own configurations, two of
  them secrets lists) held the user's address, a service account's or a key's comment, and 8 filler files more (the user, 11-15: "secrets, emails and netsem out").
  The 12 key-like hits are a PEM parser's strings (repo:ozeron__grounds/crypto/pem.bend). netsem: none.
- Filler: 587,052 documents, 3.32 GB: code 2.89 GB (hackage 839 MB, repo 1,006 MB, curated 527 MB), prose 435 MB
  (arXiv 394 MB of it). LaTeX left in the prose: 0.00 commands and 0.01 `$` a KB. But the de-LaTeX lost most of the
  books: Milewski's CTFP and the HoTT book kept 16% of their bytes (2.37 MB in, 0.37 MB out), in broken fragments,
  as a book's own macros (`\newterm{..}`, `\cat{C}`, `\Hom`) and accents (`Andr\'{e}`) spoilt whole paragraphs, and
  `\section{Acknowledgments}` (papers' last section, books' first) cut away the rest of the document: Spivak's book
  kept 17 KB of 752 KB. The planner's rounds gave the prose 11 of 212 files (5% of shard 0's filler tokens), in
  file order: shard 1's prose all the Stacks project's, shard 7's all the 1lab's.

**The fixes**:

| # | Fix | Where |
|---|---|---|
| 6 | A book's own macros keep their argument (`\newterm{objects}` objects, `$\cat{C}$` C); an unknown command in math reads as its name (`$\Hom(A,B)$` Hom(A,B)); accents go (`Andr\'{e}` Andre); `\section{Acknowledgments}` no longer ends a document; book environments (snip, Haskell, scope, ...) go | bend/DeLatex.bend, tests/delatex.bend (28 ok), tests/dlshow.bend |
| 7 | Eleven category theory and algorithm books (below) | run/v9/theory/dl/books8, filler.sh |
| 8 | Every filler text cut into pieces of at most 4 KB (prose 1 KB, about a mean gap), at a line break | bend/NulFilter.bend (bend-nul-filter, NF_MAXB), run8.sh |
| 9 | Private pairs out: a needle of a file outside git, or the user's own code (`own:`) naming a secret or holding an address | bend/NulFilter.bend (NF_PRIVATE), run/v9/r8priv.sh, run8.sh (sessions, filler, validation) |
| 10 | Each filler list in a hash order of its ids, so every shard's prose is a draw | run8.sh (shuf1) |

The books (credits in run/v9/theory8/prose/credits.tsv): Fong and Spivak, Seven Sketches in Compositionality (CC BY
4.0); Leinster, Basic Category Theory (CC BY-NC-SA 4.0); Perrone, Notes on Category Theory (arXiv's licence);
Spivak, Category Theory for Scientists (CC BY 3.0); Niu and Spivak, Polynomial Functors (CC BY 4.0); Adámek,
Herrlich and Strecker, The Joy of Cats (GNU FDL); Erickson, Algorithms (CC BY 4.0); Morin, Open Data Structures
(CC BY); Liu, Elementary Algorithms (GNU FDL); Laaksonen, Competitive Programmer's Handbook (CC BY-NC-SA 4.0);
Downey, Think Data Structures (MIT). 8.8 MB in, 3.45 MB of prose out (Erickson 885 KB, The Joy of Cats 498 KB,
AlgoXY 347 KB, Seven Sketches 347 KB, CPH 280 KB, Spivak 258 KB, Poly 236 KB, ODS 216 KB, Think DS 184 KB, Leinster
176 KB; Perrone 29 KB: its paragraphs hold display math). Not taken: Category Theory Illustrated (no licence),
Barak's Introduction to TCS (no derivatives).

The prose with the fixes: 635 MB (was 435 MB), 308,867 pieces; cut at 1 KB, 730,895. The CTFP and HoTT book test:
0.98 MB out of 2.37 MB (was 0.37 MB). Shard 0 on the first try's filler cut at 4 KB (/tmp/r8fix): 11,045
documents, WINDOW_FILL 950 packs it: 3,905 windows, filler 12.0%.

**R8 as built (11-17 07:17, run/v9/R8):** 548,813 windows of 2,046 tokens (1.12 B tokens; R7 1,086,240 and 2.22 B),
30,933 steps at batch 16 (R7 61,237), 140 shards, every one packed at WINDOW_FILL 950: 1,114,861 sessions, 2.03 a
window, filler 11.9% of the tokens (R7 24%). The filler's tokens: prose 37.4% (of it the eleven books 0.2%,
304,214 tokens), Haskell 31.1%, Bend 24.4%, Nix 3.7%, Lean 2.0%, Agda 1.4%. By shard: Bend's files last to about
shard 56 (shards 0-20: Bend 54-66%, prose 15-16%), then prose and Haskell (shards 60 and 100: prose 50-53%); the
last shard's filler is all Haskell. The user's needles: none in R8's mix, filler or validation set. R8valid: 16,629
sessions (468 give-ups out), 1,017 held-out files; TrainDense reads it on the CPU: "validation: 64 fixed windows of
run/v9/R8valid/shard-0-fp100m.corpus". El cubo de Edgar: 2,433 sessions in.

Renting waits for the user: run/v9/run8go.sh (RENT_OK=yes; from r6-step115000; tools/runs/run8.cfg,
bend/gpu/r8-box.env, run/v9/run8.stages), as run7go.sh. At R6's pace (2.75 s a step) 30,933 steps are about 23.6 h:
about $13 at the cheapest offer of 11-17 07:20 ($0.535/h), within the $22.44 credit.
