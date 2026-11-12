# The mugen shape

ana's transcripts in the shape of a session with mugen (2026-11-02, the user:
"How will we repackage the corpus for the start of a good integration of
mugen & ana?"). The same checked units as format 2 (docs/CORPUS-V2.md), so no
new verdicts: each unit's file, byte for byte, and the checker's own output on
it. Rendered by `bend-transcript` with `TRANSCRIPT_FORMAT=mugen`
(bend/Transcript.bend, "Format mugen"); tested by bend/tests/mugen.bend.

## Turns

    ## user    the ask, as the user would write it to mugen
    ## read    PATH FROM LIMIT                            a call (ana)
    ## edit    PATH, the old lines (`-` each), the new    a call (ana)
               (`+` each)
    ## shell   a command line                             a call (ana)
    ## echo    the call's answer, fenced                  the tool's: weight 0
    ## mugen   ana's reply to the user                    ana

Every heading opens a turn after an empty line, as in format 2. The echoes
are what mugen's own tools answer (mugen's bend/Tools.bend):

- **read**: the lines from FROM, LIMIT of them, then `[lines A-B of N]`.
- **edit**: the unified diff; ana's copy of mugen's differ is
  bend/Mugen/Diff.bend (keep it in step with mugen's bend/Diff.bend). An edit
  replaces whole lines, and its old text occurs once in the file (counted as
  mugen counts it: apart, anywhere, not only at line starts), so applying it
  gives the file after.
- **shell**: the output, then `(exit N)`. mugen says `(exit N in 0.4 s)`;
  the time is the one thing a corpus cannot give, so it is left out.

Checked against mugen itself: the read and both edits of
`own:hs2bend/00013/AsPatterns.bend#pushWord@260` (direct and repair-0), made
with mugen's read and edit tools on the same files, answer byte for byte what
the renderer wrote.

## The work dir and the file

The work dir is the unit's tree (BEND_SRC), the file the unit's path in it,
and its text the file as the checker checked it (bend/Check/Bend.bend: the
head, the declaration's first part, the variant; the tail left out). The
checker ran `bend Unit.bend --check-only` in the file's directory and its
output names no file, so the call is written `bend PATH --check-only` and its
echo is the checker's output as it is.

## Shapes (Bend units)

| shape | the file before | ana's calls |
|---|---|---|
| direct | the head (no declaration yet); the ask gives the signature and doc | read the last 24 lines, look the names up, edit (add it), check, reply |
| fill | the body is `?goal` | check (the goal and its context), look up, edit, check, reply |
| repair-M | the body is mutant M | check (its error), read the declaration, look up, edit, check, reply |

Every presentation a unit can give is rendered (direct, fill, each kept
mutant). Which ones go into a mix is the mix's choice (COPIES, the cap of 4 a
unit).

## Look-ups

Format 2's `## Context` (a used name's header: the file's own `def NAME(` or
`law NAME:` line, else the first line of `bend base NAME` when it opens a def,
law or type) becomes two calls:

- `grep -nE '^(def|law) (A|B)[(:]' PATH` for the names the head defines (the
  echo is grep's: `LINE:TEXT`, every matching line of the file);
- `bend base A | head -1`, or `for n in A B; do bend base $n | head -1; done`,
  for the names Base defines.

The first lines of `bend base` come from BASE, written by
`bend-transcript base RESULTS.nul BASE [BEND]` under the corpus's own Bend
(own5: run/v6/mugen/base-own5.tsv, Bend 2.0.38). They give back every unit's
Context: 11,102 of 11,102 on own5.

## The reply

`## mugen` is written from the run's facts only: which definition, which file,
what the checker said and where (`Fixed `pushWord` in P: bend check said
expected a defined name, observed SCon at line 263. It passes now.`). No code
and no checker output is ever generated.

## Sizes

`SIZES=FILE` writes a line per presentation: ID, SHAPE, its tokens, the
tokens of format 2's presentation of the same shape (direct, fill, repair with
the same mutant), and both in bytes. OUTPUT gets only those that fit the
window (tokens + BOS + EOS within WINDOW - 64), as every format.

## Measured on own5 (2026-11-02)

run/v5/transcripts-own5/bend/results.train.nul (11,102 Bend units), tokens
under weights/code32k.bpe, window 2,048 (a presentation fits at tokens + 2 <=
1,984):

| shape | presentations | median | mean | p90 | p99 | format 2 median | format 2 mean | fit | format 2 fit |
|---|---|---|---|---|---|---|---|---|---|
| direct | 11,102 | 849 | 889 | 1,177 | 1,729 | 171 | 193 | 99.5% | 100.0% |
| fill | 11,102 | 569 | 608 | 832 | 1,316 | 299 | 322 | 99.9% | 100.0% |
| repair | 26,680 | 691 | 747 | 1,017 | 1,485 | 370 | 425 | 99.8% | 99.9% |
| all | 48,884 | 698 | 748 | 1,044 | 1,539 | 313 | 349 | 99.8% | 99.9% |

11,096 of the 11,102 units give at least one presentation that fits; 48,767
fit, 36.0M tokens. A session is about 2.2 times format 2's (direct 5 times:
the read of the file's last 24 lines, the look-ups and the diff replace a
bare Term). Where the tokens go (fitting presentations):

| turn | share | per presentation |
|---|---|---|
| echo of edit (the diff) | 20.0% | 147 |
| echo of read | 18.5% | 136 |
| echo of the check | 16.8% | 124 |
| edit (ana's) | 10.7% | 79 |
| user | 8.0% | 59 |
| echo of the look-ups | 7.1% | 52 |
| mugen (ana's reply) | 6.8% | 50 |
| shell: the check (ana's) | 5.8% | 43 |
| shell: the look-ups (ana's) | 4.3% | 32 |
| read (ana's) | 2.0% | 14 |

Echoes are 62% of the tokens (weight 0); ana's own turns 30%; the user's 8%.

## How training reads it (2026-11-03)

Agent/Spec.bend's reader (the trainer's masks, Mask.bend) knows the six
headings: `user` is the user (weight 1); `read`, `edit` and `shell` are
ana's calls (1); `## echo` is the tool's turn, but its heading line goes
with the call before it, since ana writes it and stops there (mugen runs
the call and writes the rest); the rest of the echo weighs 0; `mugen` is
ana's answer (1). A document opening with `## user` is a transcript, as one
opening with `## User` is. bend/tests/agent.bend holds the roles, the
weights and a code32k window with a mugen session in it.
`bend-agent-laws` on all 48,767 of own5's presentations (run/v6/mugen/own5):
roundtrip, calls, shape (one act, the `## mugen` reply, no attempt, no try,
the user first), tokens and agree all hold, 0 failed.

## Chains (2026-11-04)

Every session the first render made has one edit, so ana never saw a failed
fix followed by another try. The rehearsal's checkpoint showed it (run/v6's
r5-step72729 on the 176 episodes, /tmp/bx/am/ev3): after a failed check on her
own edit she ran the same check again 158 times of 195, and 89 episodes ran out
of calls.

`MUGEN_ONLY=chain` renders one more session a unit, its own stream
(`run/v6/mugen/chain/NAME`, chain6.sh), with no new checker runs:

| shape | starts as | then |
|---|---|---|
| `mugen-chain-J` | direct | J wrong edits, each followed by its check's recorded error, then the fix and the pass |
| `mugen-chain-fill-J` | fill | the same |
| `mugen-chain-repair-J` | repair (mutant m handed over) | the same, the tries from mutant m + 1 |

J is format chain's choice (1, 2 or 3 by the unit's hash, 55/30/15, at most the
mutants there are). 30 in 100 units with two mutants or more start from a
repair (Nix: all, it is never asked directly); half the rest with a hole start
from the fill. A mutant that repeats the body before it gives no chain.

**Weights (the user, 10-22: "I don't want ana to train on answering wrong on the
first try, I want ana to learn how to correct her mistakes if they occur"):**
Agent/Spec.bend's reader takes an `edit` with a later `edit` in its session as
a try, weight 0, as it takes a Term the tool rejected. Her check after it, and
the fix, weigh 1. `edit` got its own heading class for that (9, `ag.is.call`
covers it); a session with one edit reads as before (own9's first 2,763
sessions pass the laws, no try in them). repair-mix classes a chain as a repair
by those roles, so the 4:1 rule and the cap count it.

**Her own mistakes (`MUGEN_ONLY=night`, `NIGHT=FILE`):** run/v5/act5's night
transcripts, the only ones with her real failed attempts, were format 2. On
own5's results they render as direct sessions with her Terms as the edits,
`mugen-night-fixed-J` and `mugen-night-episode-J`, J her wrong edits after a
repeat of the Term before is left out (she repeated herself in most). The
bytes of each check are the recorded ones, the Terms back under the def's
indent. 5,645 transcripts, 4,628 fit the window.

## Fixes (2026-11-12)

What run 5's checkpoints did wrong on the 176 tasks, and R5d's sessions never
showed. Of R5d's first 583,180 sessions, 45 had an edit mugen refused, 2 did
not end in a pass, and 97% made one edit; at r5-step120000, of the 124 tasks
she failed, 58 ended in a false "passes", 45 sent the same call again and 33
had an edit that did not apply. The user (11-12): "add sessions where an edit
fails and is retried; add sessions where the check fails more than once
before it's fixed; add sessions that end with an honest 'couldn't do it,
here's the error'; filter out solutions that pass the check but are wrong".

`MUGEN_ONLY=fix` renders up to three more sessions a unit, its own stream
(`run/v8/fix/NAME`, run/v8/fix6.sh), with no new checker runs:

| shape | starts as | then |
|---|---|---|
| `mugen-fix-miss-direct`, `-fill`, `-repair-M` | the shape | the fix, sent first with its first line that is not blank as she might misremember it (two spaces more indent, or a character short in its middle), refused (`Edit 1 (P): old was not found. No file was changed.`); a read of those lines, two more each side; the fix and its pass |
| `mugen-fix-stale-J`, `-fill-J`, `-repair-J` | the shape | J wrong edits, each with its recorded check; the fix sent first as though the last of them had not been made (its old text the one before it: the edit she sent again on the 176 tasks), refused; a read of the declaration as it is; the fix and its pass |
| `mugen-fix-giveup-J`, `-fill-J` | direct or fill | J wrong edits (2 or 3), each with its recorded check; an edit that puts the file back as it was; the reply: `I could not get NAME in P to pass in J tries: bend check said WHAT at line N. I put P back as it was.` |

One of each a unit where it has what it needs, chosen by the unit's hash: the
miss from the direct ask, the fill or a repair (a third each); the stale fix
after 1, 2 or 3 tries (30/40/30; from the direct ask only after 2 or more, as
after one the head it edits is still there); the give-up for half the units
with two mutants or more. A refused edit is a session only when its old text
is nowhere in the file. Nix gives misses and stale fixes from a repair only.

**Weights.** Every wrong or refused edit has a later edit, so Agent/Spec.bend's
reader takes it as a try (weight 0), as a chain's. The give-up's last edit is
the one that puts the file back, so no wrong program is trained, and it never
starts from a repair (putting the file back would write the mutant). Her read
after a refusal, and her reply after the last failed check, weigh 1.

**The rule.** repair-mix classes `mugen-fix-miss-direct` as first-time (its
one try is an edit mugen refused: no wrong program was ever in the file),
`-fill` as a fill and `-repair-M` as a repair; the stale fixes and the
give-ups by their roles, repairs.

**The nights.** Her last Term passed the check, which is not to say it was
right: `own:hs2bend/00289/Problem033.bend#gcdLoop` looked up `Nat.mod`, never
used it, and passed with a loop that returns `a`. Her last Term now stands
only when it is the unit's original, spaces aside; else the original takes
its place after her wrong Terms, and a night with no wrong Term before it
gives nothing (it would be the direct session again). No test can show her
other Term right; the original is right by what the corpus is.

bend-agent-laws: one try for a miss, J + 1 for a stale fix after J, J for a
give-up. tests/mugen.bend holds the miss (both typos), the stale fix, the
give-up and the nights' rule.

## ana in the loop: agent-mugen and its evaluation (2026-11-03)

`ana --agent` (Agent/Loop.bend) calls its tool when ana ends a line `## echo`
after an empty line, as it does on a format-2 tool's heading; the tool's name
is then `echo`. `bend-corpus-v2 agent-mugen TASK echo < EPISODE`
(bend/CorpusV2/AgentMugen.bend) is mugen for a held-out unit: it starts
from the file the shape gives (direct: the head; fill: `?goal` for the body;
repair-M: mutant M), replays ana's earlier edits, runs her last call and
prints its echo as the renderer writes one. read, edit and the grep
look-up run on the file; `bend PATH --check-only` runs Bend on it in the
unit's tree (the repository copied once under AGENT_WORK, the file as
Unit.bend beside the original, as bend-check writes a variant); `bend base`
runs Bend; any other command is refused (exit 127 in its echo). A failed
edit answers with mugen's own refusal (`Edit 1 (P): old was not found. No
file was changed.`). Exit 0, solved: the call was the check, it passed,
and the file still opens with the unit's head and declaration with a body
after them.

Held to the renderer: given each of gen5's sessions up to a call's `## echo`,
the tool prints the session's own echo, byte for byte, and exits 0 only on
the last check (tools/corpus-v2/mugen/agent-mugen-law.py: 31 calls of 6 sessions, direct, fill and
repair; then 266 calls of a sample of 60 sessions, all the same). bend/tests/agentmugen.bend
holds the read, edit and grep echoes, the refusals, the look-up parsing,
`done`, the reference session and the loop's call on `## echo`.

`bend-corpus-v2 agent-mugen-eval CKPT DIR [K]` runs ana on the units every
run held out (AGENT_RESULTS, run/v2/results/bend.holdout.nul: 84 Bend units)
in each shape a unit has. Each task's reference session (the ask, the edit
to the unit's own body, the check) goes through the tool first, and a task
it does not solve under today's Bend is left out (stale); `selftest` in place
of CKPT stops there (2026-11-03: of the 84 units' 223 tasks, 176 pass
their reference session under Bend 2.0.39 and 47 are stale; /tmp/bx/am/st84).
Then each task is an episode (TEMPERATURE 0, TOKENS 512
a stretch, AGENT_CALLS 8, AGENT_BIN the agent loop's bend-generate). The
report: solved, by shape.

Run 4's c2-step72491 has never seen this shape: on the first unit it writes
format 2's `## bend` heading, or Nix, and solves none (0/2; /tmp/bx/am/ev1).
On 112 of gen5's sessions (40 units) it scores 0.718 bits a byte against
0.552 on the same units' format-2 transcripts (every target weighed: a packed
corpus's windows past a document's first read as given text, so EVAL_MASK
does not apply there). Two training steps from it on 300 mugen sessions (149
windows, batch 1, CPU, TRAIN_MASK=kinds) run and save: gradient
norm 11.6 and 13.9, clipped, validation 1.715 (0.886 bits a byte) before the
first.

## The other languages (2026-11-03)

`bend-transcript` renders every language's unit in this shape. Run 5 spends
about a fifth of its tokens on them, so ana learns the same calls on Haskell,
Agda, Lean and Nix instead of format 2's. The file, the shapes and the turns
are Bend's. What changes:

| | check | look-ups | hole |
|---|---|---|---|
| Haskell | `ghc -fno-code -w PATH` | `ana-type PATH NAME...` (GHCi's `:type`) | `_`, its check's output |
| Agda | `agda PATH` | `ana-type` (Cmd_infer_toplevel) | `?`, `ana-goal PATH` (Cmd_goal_type_context) |
| Lean | `lake env lean PATH` | `ana-type` (`#check`) | `_`, its check's output |
| Nix | `nix-instantiate --eval --strict PATH` | none | none, and no direct shape (docs/CORPUS-V2.md C2) |

Each echo is the unit's recorded output with the checker's `Unit.EXT` written
as the file's path, and this machine's `/home/.../run/` left out; a variant's
recorded status `-` is written `(exit 1)`. `ana-type` asks for every name the
body uses, and a name the checker cannot type is left out, as in the
Context. The reply names the checker: `ghc said [GHC-58481] parse error on
input ':' at line 229`. Bend's sessions stay byte for byte (cmp on 300 of own5's
units). bend-agent-laws holds on the first 200 units of each: 668 Haskell,
946 Agda, 913 Lean, 505 Nix presentations, 0 failed. tests/mugen.bend `other`.

Lean's source records split a theorem at its first `:=`, which for a statement
with a `let` is inside the statement: 38 of 199 direct prompts stopped at
`let x : R`, and those units' fill sessions had their hole in the statement.
The sessions keep what the records hold; `bend-lean-statement`
(bend/LeanStatement.bend) goes over them before repair-mix, giving such a prompt
the whole statement and leaving out its fill, so the eval corpora still hold the
cut ones. A prompt that could pass the renderer's size whole goes with its fill
(2 of the 38). The other languages' prompts hold the whole signature (all of the
sample's: 200 Haskell, 196 Agda, 300 Bend).

## Not yet

- `ana-type` and `ana-goal` for the other languages in `agent-mugen`, the
  evaluation's tool (the evaluation is Bend's only). `agent-mugen-live` has
  them, and each language's check (bend/Look.bend; tests/agentmugen.bend `live`).
- ana as a mugen back end: mugen runs ana's calls with the same tools it
  gives Claude, and feeds the echoes back, until ana writes `## mugen`.
  agent-mugen is that loop's other half, for the evaluation.
