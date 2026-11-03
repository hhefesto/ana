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

## Not yet

- Other languages (their checker's command, file and look-ups).
- ana as a mugen back end: mugen runs ana's calls with the same tools it
  gives Claude, and feeds the echoes back, until ana writes `## mugen`.
