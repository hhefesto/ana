Behaviour test: ana's answers compiled and run against expected outputs
=======================================================================

Each task is a prompt in the layout ana was trained on (format 2) that stops
at an open Term fence.  ana answers it greedily (TEMPERATURE=0, 160 tokens);
the answer is the generated text up to the first closing fence line.  It is
then put into a file with the task's tests and handed to the language's own
checker.  A checkpoint's score is the number of tasks that pass.

  haskell  30 tasks   GHC (run/check-cache/ghc-harness), compiled -O0, run
  lean     21 tasks   Lean v4.34.0-rc2 with the project's Mathlib
                      (run/harness/mathlib4), 15 definitions + 6 proofs
  agda     21 tasks   Agda 2.8.0 with standard-library-2.3, --safe,
                      15 definitions + 6 proofs

The Haskell tasks moved here from run/v2/evalruns/behaviour/ (untracked).
Their prompts, sigs, pres, tests and refs are byte-identical to the old ones,
and re-checking the old v2-step40000 and v2-step53880 outputs through this
run.sh (now `behaviour run`, below) gives the old verdicts exactly.  The old results stay in that
directory (they were generated with bend-generate; runs here use ana, and
ana's greedy answers to the Haskell tasks are byte-identical to
bend-generate's for both checkpoints).

Running
-------

The harness is `bend-corpus-v2 behaviour` (bend/CorpusV2/Behaviour.bend;
`deploy corpus-v2 behaviour ...` or `nix run .#bend-corpus-v2 -- behaviour
...`), run from the repository root:

  behaviour tasks [LANG...]          spec/LANG.tasks -> tasks/LANG/ and refs/LANG/
  behaviour tasks --check [LANG...]  writes nothing; exits 1 when a file under tasks/
                                     or refs/ is not what the spec makes, or an
                                     entry there is not in the spec
  behaviour run CKPT TAG [LANG...]   generate and check (all three languages by default)
  behaviour run REF control [LANG]   the control: the reference answers, same checks
  behaviour selftest [LANG...]       known-verdict answers (see below); exits 1 on a mismatch

  e.g. bend-corpus-v2 behaviour run run/v2/run2/out/v2-step40000.checkpoint v2-step40000 lean agda

It is the port (2026-10-14: all logic in Bend) of tasks.sh, run.sh and
selftest.sh, and writes every file they wrote byte for byte: the same
tasks/ and refs/, the same verdicts.tsv and summary.txt, the same
NAME.body/.gen/.term/.hs/.lean/.agda.  Its messages say `behaviour tasks:`
and `behaviour run:` where the scripts said `tasks.sh:` and `run.sh:`.
selftest's broken answers live in spec/selftest.mut (not in heredocs), and
its `mutated:` lists follow that file's order (selftest.sh's followed bash's
associative-array hashing).

Environment: TOKENS (160), ANA (run/gcroot-ana/bin/ana), ANA_THREADS (4),
GEN_JOBS (1 generation at a time), JOBS (3 checks at a time; 0: all at
once), CHECK_ONLY=1 (re-check the outputs already in results/TAG/LANG
without generating), REUSE=1 (generate only the missing outputs),
KEEP_BUILD=1, GHC, MATHLIB, LEAN_BIN (default ~/.elan/toolchains/<MATHLIB's
lean-toolchain>/bin), LEAN_TIMEOUT (300 s), AGDA (default: the agda behind
the nix wrapper on PATH, as bend/Check.bend finds it), AGDA_LIBS
(run/check-cache/agda/libraries), AGDA_TIMEOUT (300 s), BEHAVIOUR_DIR
(tools/corpus-v2/behaviour: where tasks, refs and results are).  A variable
set to the empty string counts as unset.  Log lines are stamped in UTC-6.

Cost: ana takes 6-30 s per task depending on the machine's load.  A Lean
check loads all of Mathlib: 20 s warm and 70 s cold on a loaded machine,
6.5 GB resident, most of it the shared mmap of the .olean files.  An Agda
check takes a few seconds; the 21 Agda checks of the control take ~25 s and
the 21 Lean checks ~65 s at JOBS=3.

Layout
------

  spec/LANG.tasks          the tasks (the only hand-edited task source)
  spec/selftest.mut        selftest's broken answers and their verdicts
  behaviour tasks          writes tasks/ and refs/ from spec/
  tasks/LANG/NAME/prompt   the prompt, byte for byte
  tasks/LANG/NAME/sig      the Type turn's code
  tasks/LANG/NAME/pre      declarations the checked file needs before the Type
  tasks/LANG/NAME/tests    the tests (empty for a proposition)
  tasks/LANG/NAME/kind     `type` or `proposition` (the Type turn's first word)
  refs/LANG/NAME           the reference answer followed by the closing fence
  Check.lean               the Lean check's driver
  tasks.sh, run.sh, selftest.sh   the shell originals of `behaviour` (unwired 2026-10-14)
  results/TAG/LANG/        verdicts.tsv (NAME<TAB>VERDICT, sorted), summary.txt,
                           NAME.out (ana's stdout: header line, prompt, answer),
                           NAME.err (ana's stderr); rebuilt by a check and not
                           tracked: NAME.body/.gen/.term (the answer), the
                           checked file (NAME.hs, NAME.lean, NAME.agda) and the
                           checker's output (NAME.ghc + NAME.run, NAME.log)

Spec format: lines starting `@@#` are comments.  `@@ task NAME KIND` starts a
task (KIND type or proposition); `@@ user`, `@@ context`, `@@ type`,
`@@ pre`, `@@ tests`, `@@ ref` start its sections, each running to the next
`@@` line, trailing blank lines dropped.  user and type are required.  A Lean
or Agda task's NAME is the name its Type declares (Lean's checks end with
`#print axioms NAME`).

Prompt layout (format 2, as in run/v2/transcripts/LANG/transcripts.*.nul):

  ## User\n\nUSER\n\n
  [## Context\n\n```LANG\nCONTEXT\n```\n\n]
  ## Type\n\nKIND\n```LANG\nTYPE\n```\n\n
  ## Term\n\n```LANG\n

with LANG haskell, lean or agda.  In the training transcripts the Type turn
holds the statement and the Term the answer:
  - Lean: Type `def f (n : ℕ) : ℕ` or `theorem t (n : ℕ) : P` (the
    declaration up to its `:=`), Term the body or proof (`by ...`); the checked
    file joins them with ` :=\n` unless the answer opens with `:=`, as
    bend/Agent/Tools.bend at.file does.
  - Agda: Type `f : ℕ → ℕ`, Term the clauses `f zero = ...` (name repeated).
  - Haskell: Type `f :: ...`, Term the equations.
USER is a plain description for a definition (the docstring layout of the
transcripts, as the Haskell tasks always had) and `Prove `NAME`.` for a
proposition (the transcripts' usual User line for one).  CONTEXT lines are
`name : type` (Agda, Lean #check style) or `name :: type` (Haskell).

How an answer is checked
------------------------

haskell  Main.hs: fixed imports (Data.List, Data.Char, Data.Maybe, Data.Ord,
         Data.Map as M), pre, the sig, the answer less any line equal to the
         sig, `tests :: [Bool]`, a main printing PASS or FAIL.  ghc -O0
         (120 s), run (10 s).
lean     NAME.lean: `import Mathlib`, pre, the Type joined to the answer,
         `section BehaviourChecks`, the tests (`#guard f x = y` lines, run by
         the evaluator), `#print axioms NAME`, `end BehaviourChecks`.
         lean --run Check.lean NAME.lean CUT (LEAN_PATH from `lake env` in
         MATHLIB): elaborates the lines up to the `section` (CUT) and stops
         with status 1 on an error there; only an answer without errors meets
         the tests (status 2 when one fails).  Lean compiles a definition
         whose termination proof failed (`def fib (n : ℕ) : ℕ := fib n`), so
         a #guard on it would never stop: run 2's first Lean run sat on two
         such answers until a 600 s timeout before Check.lean existed.
agda     Task.agda: `{-# OPTIONS --safe #-}`, `module Task where`, open
         imports of Data.Nat, Data.List, parts of Data.Bool, Data.Maybe,
         Data.Product and Relation.Binary.PropositionalEquality, pre, the
         sig, the answer less any line equal to the sig, a separating
         `open import Agda.Builtin.Unit using ()`, the tests (`_ : f x ≡ y`
         / `_ = refl` pairs, checked by normalisation).
         agda --library-file=AGDA_LIBS -l standard-library-2.3 -i . Task.agda

A proposition task has no tests: its test is the kernel accepting the proof.

Verdicts (verdicts.tsv):
  pass      compiles / type-checks and every test holds
  wrong     compiles, but a test fails
  compile   does not compile, elaborate or type-check; for a proposition,
            the proof fails (a proof task is pass, compile or refused)
  crash     haskell: the test program dies other than by a failed test;
            lean: the checker dies while running the tests (a stack overflow)
  refused   lean: the answer says sorry, admit, axiom, implemented_by, extern
            or unsafe, Lean warns "declaration uses sorry", or NAME depends
            on an axiom other than propext, Classical.choice, Quot.sound,
            Lean.ofReduceBool, Lean.trustCompiler;
            agda: postulate, a hole ({! or a lone ?), OPTIONS, BUILTIN,
            REWRITE, TERMINATING and the other unchecked pragmas, trustMe
  timeout   the checker ran out of time
  unclosed  no closing fence within the token budget
  noprompt  the output does not start with the prompt

compile against wrong: Lean's is Check.lean's status.  Agda stops at its
first error, so its verdict is read off that error's line: at or before the
separating import it is the answer's (compile), after it a test's (wrong).
Both files put a separator line after the answer (Lean's `section`, Agda's
import) so that an unfinished answer (`| 0 =>` and the fence) fails on the
separator, inside the answer's part, not on the first test.  An answer that
elaborates but makes a test fail to elaborate (a noncomputable Lean def
under #guard) counts as wrong.

Results (2026-10-07, greedy, 160 tokens)
----------------------------------------

  TAG            haskell  lean   agda
  control        30/30    21/21  21/21
  v2-step40000   15/30     3/21  10/21
  v2-step53880   17/30     3/21  10/21

Lean passes at both: myReverse (l.reverse), sumList, length_reverse_eq;
the other proofs are induction skeletons that do not check, and most
definitions are well-typed but wrong (n + 1 for double, x :: l for
insertSorted, l.map (· + 1) for dedup and everyOther).  Agda passes at
both: double, headMaybe, rev, sumList and the proofs plus-zero, not-not,
map-id, length-append; 40000 adds fib and isEven, 53880 copies and
countTrue.  Agda failures include Haskell-isms out of scope in Agda
(max, ==, n - 1) and incomplete pattern matches.

Checks of the checks
--------------------

The control (behaviour run REF control) passes 30/30, 21/21 and 21/21.
behaviour selftest gives every task its reference answer except the broken
ones of spec/selftest.mut (`@@ mut LANG NAME VERDICT`, then the answer's
lines up to the next `@@` line, trailing blank lines dropped; closed by a
fence unless VERDICT is unclosed) and expects each verdict, `pass` for the
others: well-typed but wrong answers (Haskell merge,
fib, dedup, safeHead; Lean double, fib, dedup as Mathlib's List.dedup, which
keeps the last occurrence, everyOther as a filter on odd values, isPrime as
oddness; Agda double, fib, rev, maxList) must be `wrong`; a Haskell
division by zero `crash`; ill-typed or unfinished answers, a Lean
definition that fails its termination check (`sumList l`, which must not
hang in a #guard) and failing proofs `compile`; sorry, postulate, holes
`refused`; an unclosed fence `unclosed`.  The everyOther tests gained
[2, 4, 6] when the odd-filter answer passed the first four.

Caveats
-------

- Greedy decoding: one answer per task, so a score is one sample's verdicts.
- Lean imports all of Mathlib, as the training transcripts' files did, so an
  answer may use ℕ, norm_num, linarith and Mathlib lemmas; definitions have
  no `open`s (so `fib` is ours, not Nat.fib).
- Lean keeps a repeated Type line in the answer (as at.file would, so it
  fails); Haskell and Agda drop a line equal to the sig.
- The answer is the text up to the first closing fence; ana goes on past it
  (more turns) within the 160 tokens, and that text is ignored.
- Only exact equality is tested (#guard / refl / ==), on a few inputs each.
- An Agda answer sees only the shared imports (Data.Nat, Data.List, ...):
  a name from elsewhere (max, insert) is out of scope, as it would be for
  any file whose imports the prompt does not show.
