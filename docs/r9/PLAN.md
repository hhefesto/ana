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
