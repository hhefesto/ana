# Form 2 of ana's mugen sessions (2026-11-12; rendering again since 13:45)

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
| `## look` | the path, then names, a line each | each name the file defines: `NAME, lines A-B:` and its whole definition; a Base name `NAME, in Base:` and its first line; another language's names its checker's Context (their types) |
| `## def` | the path, then a whole definition | `ok: NAME, lines A-B`, then the check, as `## check`'s; a name the file does not define is refused (`refused: no NAME in PATH (a new definition is ## add); the nearest: N. No file was changed.`) |
| `## add` | the path, then a whole definition | `added: NAME, lines A-B`, then the check; a name the file defines already is refused |
| `## read` | the path, a line, a count | the lines, as today (kept for a direct task's context) |

The user's answers (11-12): a def of a name the file does not define is refused with the nearest name, and a new
definition is its own call, `## add` (1, recommended); the check goes into the def's own echo (mugen's call, so a write
and its verdict are one turn); repair sessions also from run 5's own failed tries (yes: the nights, `form2-night`).

- `## def` replaces a definition by its name (Spec/Form2.bend's put: a lens over the file's pieces, its laws proven and
  in the gate): nothing to copy, so no edit is refused for a misremembered line, and a unit is one definition.
- No `## shell` in her sessions (it stays in mugen for the user's own work).
- The reply starts with the verdict of the check just above it: Bend's first line (`ALL PROOFS CHECK.`, or
  `SOME PROOFS FAIL: expected ..., observed ... at line N.` for a give-up); another checker's `ghc passes (exit 0).` or
  `lean fails (exit 1): ...`; then what changed in a sentence.
- Weights as today: a write (`## def`, `## add`) with a later write is a try (0); the next write and the reply weigh 1.

## The shapes (bend/Transcript.bend "Form 2", MUGEN_ONLY=form2*)

direct, fill, repair-M, the chains, and the fixes: `fix-miss-SHAPE` (the direct ask's new name sent to `## def`, or a
fill's or repair's name misspelt, refused with the nearest; then the right call), `fix-repeat[-S]-J` (J wrong
definitions, each with its check, then the right one), `fix-giveup[-fill]-J` (J wrong definitions, then the hole put
back, and a reply with the verdict, the tries and the last error; only where the hole's check fails). Format mugen's
misses and stale edits (an edit's old text not in the file) have no counterpart. In the first 43 parts of the 11-12
fixes, those misses were 58k of 92k sessions.

On 30 units of six streams (11-12): 0 of 1,011 sessions failed bend-agent-laws; mean tokens per session against format
mugen's, the same units: Haskell direct 593 against 808, repair 626 against 779; Agda 760/951, 858/998; Lean 435/638,
553/662; own5 (Bend) direct 659/708, repair 1,273/1,160 (look shows whole definitions); a2b direct 1,590/1,978.

## In mugen

The eval tool (CorpusV2/AgentMugen.bend, AM_FORM=2) runs the calls on the task's file: `check` the checker, `look`
Spec/Form2.bend's get (Base names through `bend base`), `def` its put and the check, `add` the definition after the last
line and the check. ana-mugen (mugen-web's /ana, `agent-mugen-live`) is still format mugen's.

## The example (and_inverse_l, a repeat)

[today](and_inverse_l.today.txt) 2,409 bytes (tool output 1,435); [form 2](and_inverse_l.new.txt) 1,636 bytes (tool
output 730). Today's has the refused edit and the read after it; form 2 has neither.

## The work, once agreed

bend/Transcript.bend's renderer (the shapes in form 2), Agent/Spec.bend's reader (three new call headings), the laws
(bend-agent-laws), the eval tool (AgentMugen), ana-mugen's translation, their tests; then every stream rendered again
(fix6.sh's way: about 3 h on 8 workers), the mixes (ratio=0, cap 4) and the plan (two passes). r5-step90000 has to
relearn the calls.
