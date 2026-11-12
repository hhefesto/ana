# Form 2 of ana's mugen sessions (a draft, 2026-11-12; nothing re-rendered)

The user, 11-12: "I do want ana to learn to do mugen dynamics, but I also want it to do it in the easiest way for ana
to learn"; then "Design it now and show you one session in the new form before anything is re-rendered".

## Why (today's form, 11-12)

- 38,086 sampled fix sessions, 3.2 KB on average: 62% of the bytes are tool output (weight 0, but they fill the
  2,048-token window): re-reads 25.6%, edit diffs 22.7%, checks 13.5%.
- Of the 124 tasks r5-step120000 failed: 58 ended in a false "passes", 45 repeated the same call, 33 had an edit that
  did not apply (an `edit` must copy the old lines exactly).
- Every R5d session but 2 ended in a pass, so "It passes now" came last whatever the check said.
- Look-ups were shell (`grep -nE '^(def|law) (A|B)[(:]'`, `bend base N | head -1`), easy to mistype.

## The calls

Headings stay `## user`, `## echo`, `## mugen` and ana's calls; the checker's output stays word for word.

| call | ana writes | the echo |
|---|---|---|
| `## check` | the path | the checker's output as it is, and `(exit N)` (bend `--check-only`, ghc `-fno-code`, agda, lean) |
| `## look` | the path, then names | each name's whole definition in the file, after `NAME, lines A-B:`; a library name, its signature |
| `## def` | the path, then whole definitions | `ok: NAME, lines A-B` for each (a name not in the file goes after the last one replaced: `added: NAME, lines A-B`) |
| `## read` | the path, a line, a count | the lines, as today (kept for a direct task's context) |

- `## def` replaces a definition by its name: nothing to copy, so no edit is ever refused, and a unit is one definition.
  Haskell: the name's signature and equations; Agda: its signature and clauses; Lean: the declaration up to the next
  one at the top level; Bend: `def`/`law` up to the next.
- No `## shell` in her sessions (it stays in mugen for the user's own work).
- The reply starts with the last check's verdict line, copied from just above it (`ALL PROOFS CHECK.`, or
  `SOME PROOFS FAIL: <its first error line>.` for a give-up), then what changed in a sentence.
- Weights as today: a `## def` with a later `## def` is a try (0); her check after it, the next def and the reply weigh 1.

## The shapes

direct, fill, repair, a repeat (a wrong def, the check's error, the right def) and a give-up (the defs that failed,
the file put back, the verdict and the last error) carry over. The miss (an edit refused for a misremembered line) has
no counterpart: no edit can be refused. In the first 43 parts of the 11-12 fixes, misses were 58k of 92k sessions.

## In mugen

ana-mugen translates her calls into mugen's tools: `check` a shell command, `look` a read of the range, `def` an edit
whose old text is the file's current definition. The user sees the usual view.

## The example (and_inverse_l, a repeat)

[today](and_inverse_l.today.txt) 2,409 bytes (tool output 1,435); [form 2](and_inverse_l.new.txt) 1,636 bytes (tool
output 730). Today's has the refused edit and the read after it; form 2 has neither.

## The work, once agreed

bend/Transcript.bend's renderer (the shapes in form 2), Agent/Spec.bend's reader (three new call headings), the laws
(bend-agent-laws), the eval tool (AgentMugen), ana-mugen's translation, their tests; then every stream rendered again
(fix6.sh's way: about 3 h on 8 workers), the mixes (ratio=0, cap 4) and the plan (two passes). r5-step90000 has to
relearn the calls.
