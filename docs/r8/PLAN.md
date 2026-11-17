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
