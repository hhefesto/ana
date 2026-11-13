# Form 2's new session kinds for the next Bend run (2026-11-13)

## Why

ana's step-100000 checkpoint (R5g, pass 1) wrote no working merge sort or quicksort in 33 tries (msort-bend 0/9,
qsort-bend 4/9 only by calling Base's `List.sort`, msort-hs 1/9 and it reversed, qsort-hs 0/6). What in the corpus
causes it (11-13, measured on run/v9/mixg and run/v8/R5dsrc):

- **One definition a session.** Every write-a-function session cuts a single declaration out of a real file, so
  ana never writes a helper and then the function that calls it. 37% of the source files' functions (43,528 of
  118,755 in a 60 MB sample) call a helper only they use, defined above them.
- **Nothing checks the meaning.** Bend's mix has 318,968 repair sessions, but every one fixes code Bend rejects.
  Code that type-checks and computes the wrong thing passes, and that is how her wrong-but-passing answers got
  through. 13,102 of 176,688 Bend sessions (7%) mention any law at all.
- **Made-up names, mixed forms.** `Sorted.merge` and `Sorted.largest` do not exist anywhere in the corpus; she
  blends the many `Sorted.*` files. She mixes `List.length(&2, ..)` and `List.sort(~Nat, ~le, ..)` forms although
  she looked up 92% of the Base functions she called (21,445 of 23,325); only 256 of 116,196 look-ups came back
  "not found", so she never practised a look-up that fails.

A correction: on 11-13 I said none of the 33,795 direct requests has prose. That was wrong: I counted `#` lines
inside the request's code block. Form 2's requests (11-12) already give the source's `#` comment as prose: 16,958 of
33,795 (50%). What is missing is the other half of the user's choice: ana writing the comment herself.

## The user's decisions (11-13)

- Prose: "In the request, and ana also writes it as a `#` comment above her function".
- Laws: "Example laws from running the original, plus the file's own general laws when it has them".
- Functions with no comment: "Keep them, with the type and laws but no prose".
- Merge sort and quicksort: "Maybe don't keep it out at all. We can always find propositions/types that aren't in
  the corpus to test." So they stay in; the test has a seen group and a held-out group.
- No pass 2 of R5g; no keeping each best-validation checkpoint.
- "Yes do start and keep going including making the full mix. Only wait for my approval to rent a box."
- Bend only for now; the other languages' sessions stay as R5g has them.

## The kinds

Every kind is still form 2 (docs/form2/README.md): `## check`, `## look`, `## def`, `## add`, `## read`; the weights
are as today (a write with a later write is a try, weight 0; the last write and the reply weigh 1). Each echo is the
real tool's, byte for byte; where no recorded check covers a file, a checker runs (below), never a guess.

### 1. The comment (every Bend direct session whose source has one)

The file ana reads is cut before the function's `#` comment, not after it. The request keeps the prose; her `## add`
starts with the comment lines as the source has them, then the definition. The file the check sees is the source's,
so the recorded check stands. A function with no comment: the type and its laws, no prose (as today, plus laws).

### 2. Helpers first (`mugen-direct-helper-K`) and nearly empty files (`mugen-direct-scratch-K`)

When the definitions right above the function (only blank lines and comments between) are ones it calls, directly
or through each other, the file is cut before them and one `## add` writes them all, in the source's order, each with
its comment, then the function: K helpers, at most 3. When they reach back to the file's first definition (what is
left is imports, types and comments), the session is `scratch` and K may be up to 8. The add's file is the source's,
so the recorded check stands; its echo lists every name: `added: h, f, lines A-B`. Such a unit's direct session is
this one (not both). The look-ups cover the helpers' calls too.

### 3. Laws (`bend-corpus-v2 exlaw`, a new tool; then every shape of the unit)

For a Bend function whose parameters and result are Base data (Nat, U32, I32, Bool, Char, String, lists and pairs
of them) and that the checker still passes:

1. **Probe:** 3 inputs, chosen by the unit's id from small pools (`0n, 1n, 2n, 3n, 5n`, `[]`, `[3n, 1n, 2n]`,
   `"ab"`, ...), and one check of the file with `law f.probe: for d: T & T & T {(f(a), f(b), f(c)) == d : ...}`.
   Bend prints what the left side computes (`- expected : ([2n, 1n, 3n], ...)`), a value in Bend's own syntax.
   A value that is not a literal (a stuck call, a lambda) or is too long is dropped; at most 3 examples.
2. **The file's own laws:** a `law` (and its `def`) right after the function in the source, naming it, comes too.
3. **Verify:** the file with the function, its file laws and its example laws checks (`ALL PROOFS CHECK`), else
   without the file laws, else the unit gets none.
   ```
   law rev.ex1:
     {rev([3n, 1n, 2n]) == [2n, 1n, 3n] : List<&2, Nat>}

   def rev.ex1():
     {==}
   ```
4. **Law failures:** MutOps' operators that keep a program well-typed (swap-arms, swap-args, ctor-swap, lit-value,
   var-swap, drop-line) are tried with the laws in the file; a mutant the checker rejects *at a law*
   (`Location: f.exK`, `- expected : <what it computes> - observed : <what the law says>`) is kept, at most 2.
5. **Form mix-ups:** a new operator, `form`: a Base call's `&2`/`~` argument dropped or added
   (`List.length(&2, Nat, xs)` as `List.length(xs)`, `List.sort(~Nat, ~le, xs)` as `List.sort(Nat, le, xs)`); a
   rejected one is kept as an ordinary mutant (its error is Bend's), at most 1.

The unit's record then holds the laws in field 14 (Bend's type field, always empty for Bend), and the new mutants
after the old ones. Every shape renders them:

- **direct:** the request shows the signature and the law statements; her add writes the comment, the function,
  then the laws with their proofs; the check runs on all of it.
- **direct with a law failure (`mugen-fix-repeat-J`):** her first add is a law mutant (a try, weight 0), the check
  fails at the law, she `## def`s the function right (weight 1).
- **repair (`mugen-repair-M`) of a law mutant:** "`f` in PATH fails bend check. Fix it.", the check shows the law's
  expected/observed, a look, a def, the pass. ana's reply says which law and what it computed.
- **fill, chain, fix:** the file holds the laws after the function; the recorded checks stand (Bend stops at the
  first error, and the laws come after the function: tested 11-13).

### 4. Look-ups (`mugen-direct-miss`, about 1 in 8 direct sessions that call Base)

Before writing, she looks up a near name that does not exist (a Base name she calls with a sibling namespace or a
plural/singular change, checked against Base's names and the file's), gets `NAME: not in PATH or Base`, and looks up
the real one; then writes. Every Base name the written code calls is looked up first (the 8% that were not, now are),
so its form (`&2`, `~`) is on screen when she writes it.

### 5. Fuel

Not a kind of its own: functions with a fuel argument come in through 2 and 3 (their `go` helpers right above them).
Counted in the render's stats.

## The tool ana is evaluated with (CorpusV2/AgentMugen.bend, AM_FORM=2)

- `## add` of several definitions: `added: NAME1, NAME2, lines A-B` (one name: as today).
- A task whose record has laws is solved when the check passes and the file holds the laws' statements.

## The test (run/eval/r6)

- **Seen:** merge sort and quicksort in Bend and Haskell (the 11-13 tasks), greedy and 8 samples each, scored by
  running the result on fixed lists. They are in the corpus (2,363 and 585 sessions), so this says whether the new
  kinds help where she has seen the answer.
- **Held out:** 20 Bend tasks (a function or a law, with prose and example laws) whose names and types are in no
  session or filler file of the mix; checked before use, swapped out if a later corpus has them.
- Scored: solved (the check passes with the laws), and for functions, the hidden laws (more inputs) pass.

## The pipeline (olimpo, CPU; nothing rented)

1. `exlaw` over every Bend stream but agda2bend's (whose functions are proofs): run/v9/f3/law/NAME/results.nul.
2. Render every Bend stream again in form 2 with the kinds (f2.sh's way, run/v9/f3), the other languages and the
   nights reused from run/v9/f2; bend-agent-laws 0 failed on every part.
3. Mix (ratio=0, cap 4 a unit, no copies, as R5g) and plan-windows into run/v9/R6.
4. A sample for the user, the test set ready, then the user's call on renting.

## Status (11-13, afternoon)

- **Renderer** (bend/Transcript.bend "Form 2's kinds"): Bend direct asks go through the cut (`f3.view`): the comment
  written by her, helper-K and scratch-K, the laws' statements in the ask and in her add, every Base name looked up, the
  near-name miss (1 in 8, tag `-miss`). Fill and repair files hold the laws after the function; a repair whose check
  fails at a law says so in the reply (`f3.why.on`). Other languages render as in R5g (`f2.direct.other`). Bend checks
  it (`ALL PROOFS CHECK`); bend-agent-laws: 0 failed on own5's first 40 units (239 sessions).
- **The tool** (CorpusV2/AgentMugen.bend): `## add` of several definitions echoes every name (`added: select, scan,
  scan.ex1, scan.ex2, scan.ex3, lines 7-42`) and is refused if the file holds any; new shape `direct-cut` (the cut file,
  `f3.ask.direct`, solved when it defines the name and holds the laws' statements); fill and repair start from the file
  with its laws.
- **Byte for byte:** tools/runs/f3-roundtrip.zsh replays every echo of a session through `agent-mugen` (Bend run on the
  file in the unit's tree). 22 sessions of own5 (direct, helper-1/3, scratch-1/3, -miss, chains, fixes, fills, repairs,
  a form mutant), with and without laws: every echo identical.
- **exlaw** (CorpusV2/Exlaw.bend, pure texts and their 12 laws in CorpusV2/ExlawText.bend, `--verdict` passes): on
  own5's first 40 units, 7 got laws (16 examples), 31 not data (own types such as `Z`), 2 no examples; 0 law mutants
  (the well-typed operators rarely keep a program well-typed there), 1 form mutant. Its source trees: BEND_SRC, a list.
- Not done yet: the full exlaw and render (run/v9/f3.sh), the mix (R6), the sample for the user, the held-out test.
