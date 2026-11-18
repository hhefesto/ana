# R9: longer sessions, more writing from scratch (2026-11-17)

The user, 11-17, on two points of mugen's reply: "Let's rewrite the corpus so that we tackle these two points: Writing a definition from scratch
stays weak (3–13 of 67) ... Longer tasks within 2,048 tokens. For example, one session could fill several holes in
the same file in turn, with the file carried along. That needs new data collected on olimpo ... I want significant
improvement for the 2048 context window until we've reached the limit."

## Where direct fails (r5g-step106500 on the 176 tasks, form 2)

67 direct tasks, 18 solved, 9 right. Of the 49 unsolved: 28 wrote the same failing definition again after the
error (up to 6 times); about 13 never closed their write (degenerate `((((`, or more definitions after hers, until
the 512-token stretch ran out); the rest gave up or stopped. A direct session is 650-900 tokens: the window is not
what stops her.

## 1. Walks (bend/Walk.bend, `bend-walk`; run/v9/walk9.sh)

K units of one file (2-5, fewer when the session would pass the window), every check a new run of Bend 2.0.39 on
the file as it stands then, in the tree the unit was checked in:

| shape | the file | the session |
|---|---|---|
| walk-fill-K-J | every unit's body `?goal`, cut after the last | check (the first goal), then for each unit a look and its def, whose echo is the next goal, the last a pass |
| walk-add-K-J | the first K-1 holes, the last unit not there | the fills, then a look at the names the last uses and its add |
| walk-direct-K-J | none of the units (the text between them stays) | read the end, then a look and an add each, every add's check a pass; each unit's `#` comment goes into its add |

J = 1 in 35 of 100 (when the unit has a kept mutant): one write is first the mutant, its check a new run, then the
right one.  A walk is kept only when the checks say what the session says (each fill's check the next unit's hole,
the wrong write's check a failure that is not a hole, the last a pass) and the reader reads J tries and one act.
A direct walk whose checks differ (a definition between the units uses one of them) is tried again as an add walk.

Pilot (own5, 60 units): 18 runs, 17 walks kept, 78 checks; bend-agent-laws 0 failed.

## 2. The reader (Agent/Spec.bend "Walks"; Mask.bend; Agent/Laws.bend v2)

Before: a write with any later write in its session was a try (weight 0), which would zero every step of a walk
but the last.  Now a write is a try when a later write is about the same definition: always, unless both are form
2's def/add, neither's first line is a line of the other, each has two lines or more the other lacks, and the first
was not refused.  Lines are cut at every symbol holding a newline (over code32k, `\n` and `\n` with the next line's
indent are tokens: Mask.bend's Ids gets nls).  `bend-agent-laws v2` holds the new reader to the old one on every
session before the walks, over bytes and tokens: 2,000 of R8's first sessions, 0 failed; all of R8's mix (1,114,861 sessions, 16 shards, done 11-17 10:15): 0 failed.

walk9's first run (12 workers) was killed for memory at 13:00 after 24 of 222 parts (7,056 walks kept,
8.5M tokens); restarted 15:49 with 6 workers under MemoryHigh=18G, MemoryMax=20G, MemorySwapMax=2G.

## 3. Still to do

- R9's mix: R8's mix (its cap 3 a declaration, give-ups out) with at most one repair-kind session a declaration
  (mugen's point the user took up: "Fewer repair sessions per unit may help a little"), and the walks as a stream of their own,
  valid-split as the others, private lines out (r8priv).
- agent-mugen-eval: a walk task (several holes, solved when every one is filled and the check passes), so point 2
  is measured, not only trained.
- Not corpus: the eval loop's repeat avoidance (retry_avoid) on the 28 repeats.

## 4. R9 merged into R8 (2026-11-18)

The user, 11-18: "I want any benefit R9 would have brought to be merged into R8. So when we decide to actually stop
training it should be with the best possibility of a good result for ana's bend generation."  One corpus, R8's with
R9's changes, built by `run/v9/run9.sh` (unit ana-r9mix, log run/v9/run9.log) into run/v9/R9; R8 (run/v9/R8) stays as
it was.

| # | Change | Where | State |
|---|---|---|---|
| 1 | At most one repair-kind session a declaration, Bend only | bend/R8.bend `R8_REPAIR` (r8.repair, r8.decide9; unset: R8's pass byte for byte), tests/r8.bend (31 ok) | run9.sh step 1 |
| 2 | walk9's walks as a stream of their own, `walk` | run9.sh step 2: valid split by file (39,220 in, 38,909 train, 311 held out), private out (1), ids twice out (7), hash order: 38,901 | done |
| 2b | Only walks the trainer reads as the bytes say | bend-agent-laws on all 38,901 (4 shards): 10 fail `agree` (a token's role differs from one of its bytes'), left out | run9.sh step 2b |
| 3 | The v2 reader (a write is a try only when a later write names the same definition) | Agent/Spec.bend, Mask.bend (df4cde0): the trainer's, so no corpus change | in master |
| 4 | Repeat avoidance for form 2's writes: a `## def`/`## add` write is a term, and a look between two writes no longer clears the failed term to avoid | Agent/Loop.bend (al.write.at, al.k.step, al.k.term), tests/agentmugen.bend `avoid` (two mutants fail it) | the 176 tasks with RETRY_AVOID=1 on r5g-step106500: run/v9/ev/r5g-step106500.f2.avoid |

Repair-kind: a tag ending in `repair`, or a chain's or a repeat's (mugen-chain*, mugen-fix-repeat*); a fix's miss
(-miss-direct, -miss-fill) is not (its one try is an edit mugen refused).  Bend only: the other four languages'
declarations are whole files (no `@` in their ids), and the limit cut Nix from 32,376 sessions to 12,435 and Lean by
8,382 on the first try; their sessions stay R8's.

The validation set stays R8's (run/v9/R8valid), so the losses compare with R8's runs; the held-out walks
(run/v9/mix9/walk.valid.nul, 311) are for the several-hole eval, still to do.

## 5. The trainer's speed (2026-11-18)

The user, 11-18: "Work on speed without renting, fix the slowest parts in bend (it should all be bend). After fixing,
you can rent for 30 minutes and confirm your fix really works. Be honest on what's the best speed you can optimize and
try to reach it. Add bend laws where appropriate."

Run 9's setting (fp100m, batch 16, micro-batch 4, ctx 2048, chunk 16, Muon, tf32), from fresh parameters on R9's
first windows, steady state over 12-18 steps; rented RTX 5090s, every one capped at 400 W (29.7 min in all, $0.47;
run/v9/speed, bend/gpu/speed.sh):

| Trainer | ms a step | tok/s | |
|---|---|---|---|
| before (2e7c9dc) | 2,352 / 2,421 | 13,900 | two boxes; SM busy 68-70% |
| + ops queued, one wait a program; state across chunks one Seq; chunk state and cross-chunk read as products | 1,135 | 28,800 | generic kernels |
| + fixed-shape einsum kernels | 901 | 36,300 | |
| + memset for fills; B (the running sum of log α) one Seq | 862 | 38,000 | TRAIN_CHUNK=32: 847 |
| + GLA's products batched over every head (head-major) | 839 | 39,000 | TRAIN_CHUNK=32: 823 |
| + kernel and tuning found once a spec | 858 | 38,200 | the box where before took 2,421: 2.82 times |

Same binary, another 400 W box: 1,040 ms (`BEND_GEMM_NUMERICS=bf16` there: 1,025). Checks: tests/dense.bend on the
GPU (every gradient against the tree trainer, the worst 4.4e-7 relative); the first 14 steps' losses before and after
agree to 1e-6 relative and the gradient norms to 3e-5 (GPU rounding); on the CPU, tests/seq.bend (a Seq and its
slices, forward and transposes, and the new GLA forward against the old, bit for bit; two mutants fail it),
tests/dense.bend, tests/dualgrad.bend, decode, prefill and layout as before. Spec/Lanes.bend proves (BendTT
`--verdict`) that running a Seq lane by lane, as the kernel does, leaves every lane where the slices in order do.

What a step ran (bend-perf, per step): ops 33,543 → 9,747 (each a launch and, before, a wait); einsum terms 259 G →
93 G; matrix products 33.9 TFLOP either way. Profiled with every op timed alone (step 3): products 507 ms (the big
ones at about 90 TFLOP/s, near tf32's peak), einsums 358 ms, of which zeroing tangents 44, the softmax layers' t×t
maps about 70, copies about 50; GPU busy only 51-80% of the time, so the host (Bend's loop issuing ~9,700 effects a
step) now bounds the step as much as the GPU does.

The dense-identity goldens (bend/tests/dense-identity.sha256, six steps on the CPU) no longer match byte for byte: the
backward sums some terms in another order (the forward is bit for bit). The old trainer still gives them; the new one
prints the same losses to the last digit shown.

Honest ceiling at tf32 for this program: products ~0.45-0.5 s and einsums ~0.2 s at the memory's speed, so ~0.65-0.7 s
a step once the host overhead is gone; bf16 matters only after that. What would get there, by size of the win:

1. One CUDA graph a program (capture the forward and backward once, replay each micro-batch): the host's ~9,700
   effects a step out of the loop. Likely the largest; bulk.c (C), the program list unchanged.
2. Muon batched over same-shape matrices: the update is 2,926 of the 9,747 ops (Step.bend, Bend).
3. Fused softmax attention for the 3 softmax layers (151 GB of t×t traffic a step), and fusing consecutive maps
   (310 GB of n·d-sized passes): Bend program rewrites with laws, plus kernels.
4. bf16 products, once 1-3 make the products the bottleneck again.

Run 9 at this pace: 31,949 steps × ~0.86 s ≈ 7.6 h (about 9 h with validations), ~$5-6 at $0.59-0.67/h, against
~28 h and ~$17-19 before. run/v9/run9go.sh's cost check uses PACE=1.0 s.
