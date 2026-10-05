# ana acts, the tools answer

ana writes code and calls the real tools (ghc, lean, agda, bend, nix, and later
memo) to check it; it reads what the tool said and goes on. It never writes a
tool's answer itself: not at inference, and not as a training target.

This is the design (the user, 2026-10-05: "ana shouldn't even try to reproduce
what ghc is going to spit out. ana should call tools like ghc or bend to run
code ana produced and see if that code works well and iterate from that"), what
is built, and what is measured.

## Why ana wrote ghc's errors

Run 1 trained on every token of every transcript, the checker's turn
included. That turn is 16–37% of a transcript's bytes (Nix 16, Lean 18.5,
Agda 25, Bend 32, Haskell 37), so ana was fitted as a model of the checkers
as much as a coder, and the `verify` shape trained it on the checker's
verdict on purpose. At inference the decoder stopped only at the token
budget or EOS, so nothing ever handed control to a tool: ana wrote the
`## ghc` turn because it had to write something, and its error was made up
(the user's merge sort compiles with the real GHC 9.10.3).

## The meaning (bend/Agent/Spec.bend)

An episode is a list of turns; a turn is a text and who wrote it, its role:

| role | written by | in a format-2 transcript |
|---|---|---|
| user | the task | `## User` |
| given | the task | `## Context`, a given `## Type` or `## Term`, text before the first turn |
| attempt | the task, as wrong or partial | `## Attempt` |
| act | ana | the last `## Term` or `## Type` after any Attempt |
| call | ana | a tool's heading line: `## ghc` ... |
| echo | the tool | the fenced output after that line, through `[exit N]` |

A tool is a function of the episode so far, so the probability of an episode
under ana's parameters θ factors:

    P(τ) = Π_{act, call} π_θ(turn | prefix) · Π_{echo} [turn = tool(prefix)] · Π_{user, given, attempt} D(turn | prefix)

Only the first factor depends on θ, so the gradient of the likelihood of
ana's behaviour is a sum over ana's own turns. Training on an echo is
maximum likelihood of a model of the tool: what run 1 learned. Hence the
weight of a token is its role's: **1 on act and call, 0 on echo**. User and
given text keep 1 (real asks and real code, the raw corpus's kind of text,
as plain language modelling); an attempt is 0 (code handed over as wrong:
never a target). The same rule covers every tool, memo included.

The loop is an unfold (`ag.unfold`): ana's turns after the task; while ana's
last turn is a call, the tool's answer (always an echo: only the tool writes
one) and ana's next turns.

Reading roles back from text (`ag.read`) is defined over any alphabet of U32
symbols, given its newline symbol and its heading strings: a turn starts at a
heading line (`## LABEL` and the newline) that opens the text or follows an
empty line. The same definition reads bytes (the meaning) and token ids (the
trainer's refinement).

### Laws, and where they are checked

| law | where | result |
|---|---|---|
| reading never changes the text (`render ∘ read = id`) | tests/agent.bend; every transcript | holds |
| every echo answers a call, every call is answered (or ends the episode) | tests/agent.bend; every transcript | holds |
| each shape's roles (one act, none for verify; the Term, the Type for term-to-type; one attempt for repair, fill, verify) | every transcript | holds |
| the token reading equals the byte reading (each token's role is the role of all its bytes) | every transcript, code32k | holds |
| weights are 0 exactly on attempt and echo symbols | tests/agent.bend (bytes, and a code32k window) | holds |
| `unfold` lets only the tool write an echo | tests/agent.bend | holds |

"Every transcript" is `bend-agent-laws` over corpus v2's format-2
transcripts (2026-10-05): 585,060 train (bend 311,190, haskell 115,698,
agda 67,512, lean 65,644, nix 25,016) and 5,819 holdout, 0 failures
(`run/agent/laws-all.log`).

## Training: TRAIN_MASK=kinds (bend/Mask.bend)

The dense trainer already weighed every target (`Dense/Model.bend`:
`Σ loss·w / Σ w`, the backward derived); `Dense/Io.bend` wrote ones. With
`TRAIN_MASK=kinds` (plan and hot starts) each window's weights come from
`Mask.ms.weights`: the roles read from the window's own tokens, so no shard
format changes and every built shard stays valid. A document is read as a
transcript when it opens with the User heading; raw code, filler and a
document cut by the window's start are given (weight 1). Unset, every
target weighs 1 and the run logs as before.

- The tree trainer (the gate's reference) has the weighted loss too
  (`Train/Grad.bend` `loss_grad.w`); `tests/dense.bend`'s masked case agrees
  with the dense program within 5.9e-7 relative (the unmasked cases: 5.2e-7).
- Validation and `EVAL_CORPUS` scoring stay unweighted, so their numbers
  compare with run 1's.
- A micro-batch whose weights sum to 0 would give NaN; a transcript window
  cannot (its first target after BOS is filler or EOS, weight 1).

**The verify shape is dropped** (`tools/corpus-v2/windows.sh`): its target
was the checker's own turn. 46,806 of the 585,060 train transcripts (half of
Nix's), leaving 538,254; run/v2/T is rebuilt from
`run/v2/transcripts-nv` (the old T is `run/v2/T-with-verify`). A calibrated
"will this check?" belongs to a decision model (below), never to text ana
writes.

## The loop: `ana --agent` (bend/Agent/Loop.bend)

    AGENT_TOOL="bend-agent-tool snippet" AGENT_CALLS=4 TOKENS=160 \
      ana --agent --prompt-file PROMPT

ana decodes until it ends a call line (`## ghc` after an empty line, then a
newline); the loop runs the tool command (`sh -c "$AGENT_TOOL $1"` with the
tool's name as `$1` and the episode so far on stdin) and appends the tool's
stdout verbatim as the echo, fed to the decoder as text it did not sample.
Exit 0: the check passed, the episode is solved. Exit 1: it failed, ana goes
on. Anything else: the tool broke, the episode ends. Also: EOS, a stretch's
token budget (TOKENS), or AGENT_CALLS calls. The decoder state is a value
(Decode.bend), so feeding a tool's text costs one decode per token.

- The call line's newline is fed as the newline token, so the context reads
  `## TOOL\n` then the echo; a newline is a word of its own in code32k, so
  the echo's tokens, encoded alone, are those the whole text would have.
- The decoder is a library now (`bend/Decode.bend`, every def `dc.`);
  `ana` without `--agent` writes what it wrote before (checked 2026-10-05).
- Each episode streams to stdout as one transcript; stderr ends with
  `agent: solved|eos|budget|calls|tool-error; N calls, M tokens`.

### The tools (bend/Agent/Tools.bend, `bend-agent-tool`)

`bend-agent-tool snippet TOOL < EPISODE` checks ana's answer alone: the given
Type's code and the act's code in one file `Unit.<ext>` (Haskell under
`module Unit where`; Lean joins them with `:=`), under the language's checker
(ghc -fno-code -w from run/check-cache/ghc-harness; lean; agda; bend
--check-only; nix-instantiate --eval --strict), and prints the echo with
`Transcript.bend`'s own `checker` (40 lines, `[N more lines]`, `[exit N]`): the
layout ana was trained on. The layout is Spec's `ag.echo`, which
`bend-agent-laws echo` holds to Transcript.bend's `checker` on every check of
every checked unit (the original's, the hole's, the type's, each mutant's).
Standalone: a unit whose code needs its repository's context fails on scope. The faithful tool for the
evaluation prompts is the unit's own checker (`bend-check`), with ana's term
as the unit's mutant: the way every training echo after an `## Attempt` was
made (next).

First episode (2026-10-05, nr7-step61000, temperature 0, merge sort): every
`## ghc` turn was GHC's, a parse error for `mergeSort =` then `Variable not in
scope: mergeSort'`; ana repeated its wrong answer and ended at the call
quota. The mechanism is right; this checkpoint was trained to predict
errors, not to read them.

## Next

1. **E5 on the held-out units (built 2026-10-05, bend/CorpusV2/Agent.bend).**
   `bend-corpus-v2 agent-tool TASK TOOL`: the unit with ana's term lifted
   (`ev.lift`) as its one mutant, through `bend-check LANG`; a kept mutant is a
   failure with its check, none kept a pass (the unit's own verdict). Tested on
   a held-out amazonka unit: its reference passes (`[2 of 2] Compiling Unit`,
   `[exit 0]`), a broken name fails with GHC's own error in the unit's real
   module. `bend-corpus-v2 agent-eval CKPT DIR FORMAT [K]` runs `ana --agent`
   on every EVALSET prompt and reports solved within 1..AGENT_CALLS calls
   (the outcome read from the episode's text, Spec `ag.solved`).
2. **The repair view.** Format 2's repair shape relabels a failed Term as
   `## Attempt` (and the User line says "This attempt fails. Fix it."); for a
   format-2 checkpoint the loop should rebuild that view after a failure.
   Run 1's checkpoints are format 1, where the plain append is in
   distribution.
3. **The episode log**: append-only, one record per episode, every segment
   with who wrote it; any learning rule is then a function of the log.
4. **memo as a tool** (`## memo ARGS`): memo's stdout is an echo, weight 0.
   The Bend2 memo port is under way in ~/src/OptMem (branch bend2).
5. **The cycle** (designed, not automated): act → select → render → mix →
   learn (a GPU burst, asked first) → gate on E5. See "Learning from
   episodes" below.

## Learning from episodes (to decide)

Expert iteration first (ReST-EM, rejection-sampling fine-tuning): keep the
episodes the judge passes, maximise likelihood on their act and call turns.
In a solved-after-repair episode the failed Term is an attempt (0) and the
real error an echo (0), so the successful repair is learned *conditioned on
the real error*: iterating from what the tool answered, from ana's own
mistakes, with non-negative weights (the trainer as it is). Signed weights
(GRPO, RLOO) only if that plateaus: they need several samples per task and
`Σ loss·w / Σ w` breaks when Σw can be 0 or negative. Guards: refuse escape
hatches (`sorry`, `admit`, `postulate`, `undefined`, ...); Haskell's exit 0
means it compiles, not that it is right (the user's merge sort compiled and
dropped elements); replay raw and transcripts in every burst; at most k
solutions per task; never act on the eval prompts.

## The Jev route

Every open Jev reads a decision from one forward pass (a softmax over option
logits) and calibrates it with a fitted temperature: OpenJev (label-token
logits on DiffusionGemma), Kev (a pointer head on Qwen LoRA; temperature took
its ECE from 0.103 to 0.041), Laya (a decision head on ModernBERT, trained on
proper scoring rules), NanoJev, jevlike, SemIf, Von. Ours would read ana's own
logits over label tokens (no new parameters, Bend only), one temperature
fitted by log-score on the episode log (legere's method), and answer
questions about compute, never a tool's answer: P(ana solves this task) for
the curriculum, P(another attempt helps) for when to stop, which tool. legere
(docs/LEGERE.md) reads sessions into these roles (`sh` and `memo` blocks are
calls, `**stdout:**` and memo's output echoes), the only source of memo-call
examples so far.
