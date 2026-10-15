import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc
import ../CorpusV2/Steps.bend as St
import ../Push.bend as Pu

# OnBox: bend-box, the driver on a rented GPU box (2026-10-14, the plan's
# Phase 1b: all logic in Bend, the shell a thin shim).  It is bend/gpu/fp.sh
# mode for mode, run from the box's working directory (the repository's
# layout, as `bend-ops stage box` leaves it: traind.c, traind-next.c,
# dense.c, weights/code32k.bpe, the plan and its shards, run/eval/):
#
#   bend-box build                 traind and dense from their C (once), the GPU, its clocks, the memory
#   bend-box gate                  G2: ./dense on the GPU against the tree trainer on the CPU (gate.log)
#   bend-box time [N]              N (20) steps of the real run: ms/step, tok/s, the plan's hours (time.log)
#   bend-box run                   the whole plan in the background (train.log, out/NAME-step<N>.checkpoint)
#   bend-box again CKPT PLAN RUN_DIR SHARD_SIZE NAME
#                                  continue CKPT's run on PLAN (TRAIN_NEXT; NAME.log, out/NAME-step<N>)
#   bend-box next CKPT             the same on run/next (plan-next-b16-windows.tsv, shard-K-next.corpus)
#   bend-box resume CKPT PLAN RUN_DIR SHARD_SIZE NAME STEPS
#                                  a save of NAME on its own plan and schedule, STEPS steps, appended to NAME.log
#   bend-box eval [CKPT...]        bits per byte of each checkpoint (out/*.checkpoint) on the held-out transcripts
#   bend-box eval-both [CKPT...]   eval into eval.log, then (run/eval/transcript-next.corpus there) into
#                                  eval-next.log, as a detached job; eval.done when it ends (new, for the chain)
#   bend-box probe gate|time|dmon|ctx FILE [STEPS]
#                                  one reader on a file: gate.log's verdict, time.log's summary, ...
#
# A box's shell runs it in that directory (`cd formalTransformer && ./bend-box
# gate`, or `env -C formalTransformer ./bend-box gate` as one command line
# without control flow).  `time` shows the trainer's lines as they come
# (every two seconds, as fp.sh's tee | grep -v did); the other modes print a
# program's output when it ends, as fp.sh's tail and grep pipelines did.
#
# The environment is fp.sh's: MEM (48GB), PLAN, RUN, NAME (run 1's fp100m),
# MICRO (4), MASK (kinds; set and empty: every target), LR (3e-4), WARM
# (300), STEPS (8803, run), EVAL (250), EVALW (128), SAVE (500), NLR (1e-4)
# and NWARM (5% of the plan's steps, at least 10) for again/next, ECORPUS
# (run/eval/transcript-fp.corpus) and EMASK (unset: empty) for eval; every
# program run gets LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH.
# The trainers get the settings fp.sh gave them (TRAIN_*, PLAN, RUN_DIR,
# SHARD_SIZE, TOKENIZER_FILE, PRESET, BEND_GEMM_NUMERICS, EVAL_*,
# SAVE_EVERY, OUT; BEND_PROFILE=1 for the gate).  A variable fp.sh assigned
# (MEM, PLAN, RUN, NAME, CU, CLANG, CC, TOK, time's STEPS, NWARM, and what
# RUN_DIR/stage.env sets) reaches the programs with its new value when the
# caller exported it, as bash passes an exported variable on.
#
# What differs from fp.sh, on purpose: `time` reckons the whole plan's hours
# from the plan's own step count (its first line's third field), not 8803;
# `eval-both` is new; RUN_DIR/stage.env is read as KEY=VALUE lines
# (Push.bend's reader: no `$` expansion), not sourced; a trainer starts in a
# session of its own (setsid), so it outlives the ssh session that started
# it; the gate counts a relative error that is not a number (nan, inf) as a
# miss (awk read it as 0, a pass).  The usage goes to stderr (exit 2), and
# a failed build says so on stderr (fp.sh exited 1 silently).
#
# Every name starts with `obx.`; the pure parts (the gate's verdict, the
# timing summary, the dmon table, grep's context, tail) are tested in
# bend/tests/box.bend on real logs.

# Text ------------------------------------------------------------------------------------

def obx.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> obx.l1(t)

def obx.l2(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> obx.l2(t)

def obx.cat(xss: List<&2, List<&2, String>>) -> List<&2, String>:
  List.concat(&2, String, xss)

# lines, each followed by its newline (what grep and sort print)
def obx.unlines(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, U32, l, 10 <> obx.unlines(t))

# `tail -n N`: the last N lines as they are (a last line without its
# newline stays without one)
def obx.tail(+xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  +ls = S.split.lines(xs)
  +k = List.length(&2, List<&2, U32>, ls)
  +last = List.drop(&2, List<&2, U32>, ls, Nat.sub(k, n))
  Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, last), 0n), Nil{},
    List.append(&2, U32, S.join(last, 10), Bool.pick(List<&2, U32>, S.suffix(xs, [10]), [10], Nil{})))

# `head -n N`
def obx.head(+xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  S.lines.take(xs, n)

# the lines that do not start with p (grep -v "^p")
def obx.grep.v(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = obx.grep.v(t, p)
      Bool.pick(List<&2, List<&2, U32>>, S.prefix(l, p), rest, l <> rest)

def obx.blank(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9))

def obx.words.put(+w: List<&2, U32>, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(w), 0n), ws, List.reverse(&2, U32, w) <> ws)

def obx.words.go(xs: List<&2, U32>, +cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, obx.words.put(cur, acc))
    case +c <> t:
      +sp = obx.blank(c)
      obx.words.go(t, Bool.pick(List<&2, U32>, sp, Nil{}, c <> cur), Bool.pick(List<&2, List<&2, U32>>, sp, obx.words.put(cur, acc), acc))

# a line's fields as awk's default FS cuts them (runs of spaces and tabs)
def obx.words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  obx.words.go(xs, Nil{}, Nil{})

def obx.field(xs: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, U32>:
  Maybe.default(&2, List<&2, U32>, List.get(&2, List<&2, U32>, xs, n), Nil{})

def obx.last(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Maybe.default(&2, List<&2, U32>, List.last(&2, List<&2, U32>, xs), Nil{})

def obx.lower(+c: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), U32.add(c, 32), c)

def obx.lower.all(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      obx.lower(c) <> obx.lower.all(t)

def obx.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def obx.digit.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      obx.digit(c)

def obx.lead.go(xs: List<&2, U32>, +n: Nat, at: Bool) -> Nat:
  match xs at:
    case h <> +t True{}:
      obx.lead.go(t, 1n+n, obx.digit.head(t))
    case _ _:
      n

# how many digits xs starts with
def obx.lead(+xs: List<&2, U32>) -> Nat:
  obx.lead.go(xs, 0n, obx.digit.head(xs))

def obx.f(+s: String) -> St.StF:
  Maybe.default(&2, St.StF, St.st.f.read(S.b(s)), St.st.f.zero())

def obx.num.of(m: Maybe<&2, St.StF>) -> St.StF:
  Maybe.default(&2, St.StF, m, St.st.f.zero())

def obx.sign(+xs: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.or(S.head.is(xs, 43), S.head.is(xs, 45)), 1n, 0n)

# the exponent part's length at the head of xs: [eE][+-]?digits, or 0
def obx.exp.len(+xs: List<&2, U32>) -> Nat:
  +r = List.drop(&2, U32, xs, 1n)
  +s = obx.sign(r)
  +d = obx.lead(List.drop(&2, U32, r, s))
  Bool.pick(Nat, Bool.and(Bool.or(S.head.is(xs, 101), S.head.is(xs, 69)), Nat.is_lt(0n, d)), Nat.add(Nat.add(1n, s), d), 0n)

# What awk reads as a number from a field (`$i + 0`): the longest prefix
# of the form [+-]digits[.digits][e[+-]digits] with a digit before the
# exponent, to the nearest double; 0 when there is none
def obx.awk.num(+xs: List<&2, U32>) -> St.StF:
  +s = obx.sign(xs)
  +a = List.drop(&2, U32, xs, s)
  +d1 = obx.lead(a)
  +b = List.drop(&2, U32, a, d1)
  +dot = S.head.is(b, 46)
  +d2 = Bool.pick(Nat, dot, obx.lead(List.drop(&2, U32, b, 1n)), 0n)
  +m = Nat.add(Nat.add(s, d1), Bool.pick(Nat, dot, Nat.add(1n, d2), 0n))
  +e = obx.exp.len(List.drop(&2, U32, xs, m))
  Bool.pick(St.StF, Nat.is_eq(Nat.add(d1, d2), 0n), St.st.f.zero(), obx.num.of(St.st.f.read(List.take(&2, U32, xs, Nat.add(m, e)))))

# The gate's verdict ------------------------------------------------------------------------
#
# fp.sh gate's awk over gate.log: every line holding "gradient max" is a
# check, its last field (parentheses removed) the relative error, which must
# be at most 1e-5; exactly 4 checks (3 plain, 1 masked).  A failing check
# prints `gradient differs: LINE`, a count other than 4 `expected 4 gradient
# checks (3 plain, 1 masked), got K` (awk printed an unset K as nothing).

type ObxGate is Data:
  ObxGate{k: Nat, bad: List<&2, List<&2, U32>>}

def obx.gate.k(+g: ObxGate) -> Nat:
  match g:
    case ObxGate{k, b}:
      k

def obx.gate.bad(+g: ObxGate) -> List<&2, List<&2, U32>>:
  match g:
    case ObxGate{k, b}:
      b

def obx.paren(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 41))

def obx.unparen(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      +rest = obx.unparen(t)
      Bool.pick(List<&2, U32>, obx.paren(c), rest, c <> rest)

def obx.gate.le(m: Maybe<&2, St.StF>) -> Bool:
  match m:
    case Some{+x}:
      Bool.not(Cmp.is_gt(St.st.f.cmp(x, obx.f("1e-5"))))
    case None{}:
      False{}

# a check passes: its relative error is a number at most 1e-5
def obx.gate.ok(+l: List<&2, U32>) -> Bool:
  obx.gate.le(St.st.f.read(obx.unparen(obx.last(obx.words(l)))))

def obx.gate.go(ls: List<&2, List<&2, U32>>, +k: Nat) -> ObxGate:
  match ls:
    case Nil{}:
      ObxGate{k, Nil{}}
    case +l <> t:
      +hit = S.infix(l, S.b("gradient max"))
      +rest = obx.gate.go(t, Bool.pick(Nat, hit, 1n+k, k))
      +bad = Bool.and(hit, Bool.not(obx.gate.ok(l)))
      ObxGate{obx.gate.k(rest), Bool.pick(List<&2, List<&2, U32>>, bad, l <> obx.gate.bad(rest), obx.gate.bad(rest))}

def obx.gate.of(+log: List<&2, U32>) -> ObxGate:
  obx.gate.go(S.split.lines(log), 0n)

def obx.gate.pass(+g: ObxGate) -> Bool:
  Bool.and(Nat.is_eq(obx.gate.k(g), 4n), Nat.is_eq(List.length(&2, List<&2, U32>, obx.gate.bad(g)), 0n))

def obx.gate.lines(bs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      List.concat(&2, U32, [S.b("gradient differs: "), b, [10], obx.gate.lines(t)])

# what the awk printed, then the verdict line
def obx.gate.text(+g: ObxGate) -> List<&2, U32>:
  +k = obx.gate.k(g)
  List.concat(&2, U32, [obx.gate.lines(obx.gate.bad(g)),
    Bool.pick(List<&2, U32>, Nat.is_eq(k, 4n), Nil{},
      S.b("expected 4 gradient checks (3 plain, 1 masked), got " ++ Bool.pick(String, Nat.is_eq(k, 0n), "", Nat.show(k)) ++ "\n")),
    S.b(Bool.pick(String, obx.gate.pass(g), "G2: PASS\n", "G2: MISS\n"))])

# The timing summary ---------------------------------------------------------------------------
#
# fp.sh time's awk over time.log: a line matching / step=[0-9]+\/.* ms=/ is
# a step; its last field starting with ms= gives the step's time (the text
# up to a second =, read as a number); the first two steps are passed over
# and the rest summed.  The summary, when a step is left:
#   steady state: %.0f ms/step over %d steps = %.0f tok/s (16 x 2046 tokens a step); whole plan ~%.1f h
# with ms/k, k, 32736 / (ms/k/1000) and P * ms/k / 3.6e6 in doubles, P the
# plan's step count (fp.sh: 8803, run 1's).

type ObxT is Data:
  ObxT{n: Nat, k: Nat, ms: St.StF, s: St.StF}

def obx.step.at(+xs: List<&2, U32>) -> Bool:
  +r = List.drop(&2, U32, xs, 6n)
  +d = obx.lead(r)
  +a = List.drop(&2, U32, r, d)
  Bool.and(Nat.is_lt(0n, d), Bool.and(S.head.is(a, 47), S.infix(List.drop(&2, U32, a, 1n), S.b(" ms="))))

def obx.step.if(p: Bool, +xs: List<&2, U32>) -> Bool:
  match p:
    case True{}:
      obx.step.at(xs)
    case False{}:
      False{}

def obx.step.here(+xs: List<&2, U32>) -> Bool:
  obx.step.if(S.prefix(xs, S.b(" step=")), xs)

def obx.step.go(xs: List<&2, U32>, found: Bool) -> Bool:
  match xs found:
    case _ True{}:
      True{}
    case Nil{} False{}:
      False{}
    case h <> +t False{}:
      obx.step.go(t, obx.step.here(t))

# does a line match / step=[0-9]+\/.* ms=/
def obx.step.line(+xs: List<&2, U32>) -> Bool:
  obx.step.go(xs, obx.step.here(xs))

def obx.upto.eq(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(c, 61), Nil{}, c <> obx.upto.eq(t))

# the last field starting with ms=: split($i, a, "="); a[2] + 0
def obx.ms.of(ws: List<&2, List<&2, U32>>, +cur: St.StF) -> St.StF:
  match ws:
    case Nil{}:
      cur
    case +w <> t:
      obx.ms.of(t, Bool.pick(St.StF, S.prefix(w, S.b("ms=")), obx.awk.num(obx.upto.eq(List.drop(&2, U32, w, 3n))), cur))

def obx.time.line(hit: Bool, +l: List<&2, U32>, t: ObxT) -> ObxT:
  match hit t:
    case False{} _:
      t
    case True{} ObxT{+n, +k, +ms, +s}:
      +s2 = obx.ms.of(obx.words(l), s)
      +n2 = Nat.add(n, 1n)
      +more = Nat.is_lt(2n, n2)
      ObxT{n2, Bool.pick(Nat, more, 1n+k, k), Bool.pick(St.StF, more, St.st.f.add(ms, s2), ms), s2}

def obx.time.go(ls: List<&2, List<&2, U32>>, t: ObxT) -> ObxT:
  match ls:
    case Nil{}:
      t
    case +l <> rest:
      obx.time.go(rest, obx.time.line(obx.step.line(l), l, t))

def obx.time.of(+log: List<&2, U32>) -> ObxT:
  obx.time.go(S.split.lines(log), ObxT{0n, 0n, St.st.f.zero(), St.st.f.zero()})

def obx.time.k(+t: ObxT) -> Nat:
  match t:
    case ObxT{n, k, ms, s}:
      k

def obx.time.ms(+t: ObxT) -> St.StF:
  match t:
    case ObxT{n, k, ms, s}:
      ms

def obx.time.at(+k: Nat, +ms: St.StF, +plan: Nat) -> List<&2, U32>:
  +kf = St.st.f.of.nat(k)
  +a = St.st.f.div(ms, kf)
  +tok = St.st.f.div(St.st.f.of.nat(32736n), St.st.f.div(a, St.st.f.of.nat(1000n)))
  +h = St.st.f.div(St.st.f.div(St.st.f.mul(St.st.f.of.nat(plan), ms), kf), obx.f("3.6e6"))
  S.b("steady state: " ++ St.st.f.fixed(a, 0n) ++ " ms/step over " ++ Nat.show(k) ++ " steps = " ++ St.st.f.fixed(tok, 0n)
    ++ " tok/s (16 x 2046 tokens a step); whole plan ~" ++ St.st.f.fixed(h, 1n) ++ " h\n")

def obx.time.fin(none: Bool, +k: Nat, +ms: St.StF, +plan: Nat) -> List<&2, U32>:
  match none:
    case True{}:
      Nil{}
    case False{}:
      obx.time.at(k, ms, plan)

# the summary line for a timing log and the plan's step count (nothing
# when no step is left after the first two)
def obx.time.say(+log: List<&2, U32>, +plan: Nat) -> List<&2, U32>:
  +t = obx.time.of(log)
  obx.time.fin(Nat.is_eq(obx.time.k(t), 0n), obx.time.k(t), obx.time.ms(t), plan)

# a plan's step count: its first line's third field (none: 8803, fp.sh's)
def obx.plan.steps(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Lc.lcl.nat(obx.field(obx.words(S.lines.first(xs)), 2n)), 8803n)

# The dmon table -------------------------------------------------------------------------------
#
# `head -2 dmon.txt; grep -v "^#" dmon.txt | sort -k2 -n | tail -3`: the
# two header lines, then the three rows of the highest power.  sort's key is
# the line from its second field on, read as a number (blanks, a minus,
# digits, a point and digits; none is 0); a tie goes by the whole line,
# bytewise (sort in the C locale).

type ObxRow is Data:
  ObxRow{v: St.StF, l: List<&2, U32>}

def obx.skip.go(xs: List<&2, U32>, +blank: Bool, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      obx.skip.go(t, blank, Bool.pick(Bool, blank, obx.blank(Lc.lcl.at(t, 0n)), Bool.and(Nat.is_lt(0n, S.len(t)), Bool.not(obx.blank(Lc.lcl.at(t, 0n))))))
    case r _:
      r

def obx.skip.blanks(+xs: List<&2, U32>) -> List<&2, U32>:
  obx.skip.go(xs, True{}, obx.blank(Lc.lcl.at(xs, 0n)))

def obx.skip.word(+xs: List<&2, U32>) -> List<&2, U32>:
  obx.skip.go(xs, False{}, Bool.and(Nat.is_lt(0n, S.len(xs)), Bool.not(obx.blank(Lc.lcl.at(xs, 0n)))))

# sort -n's number at the head of a key
def obx.sort.num(+key: List<&2, U32>) -> St.StF:
  +a = obx.skip.blanks(key)
  +neg = Bool.pick(Nat, S.head.is(a, 45), 1n, 0n)
  +b = List.drop(&2, U32, a, neg)
  +d1 = obx.lead(b)
  +c = List.drop(&2, U32, b, d1)
  +dot = S.head.is(c, 46)
  +d2 = Bool.pick(Nat, dot, obx.lead(List.drop(&2, U32, c, 1n)), 0n)
  +len = Nat.add(Nat.add(neg, d1), Bool.pick(Nat, dot, Nat.add(1n, d2), 0n))
  Bool.pick(St.StF, Nat.is_eq(Nat.add(d1, d2), 0n), St.st.f.zero(), obx.num.of(St.st.f.read(List.take(&2, U32, a, len))))

# the key of -k2: the line after its first field (the blanks before the second kept)
def obx.sort.key(+l: List<&2, U32>) -> List<&2, U32>:
  obx.skip.word(obx.skip.blanks(l))

def obx.rows(ls: List<&2, List<&2, U32>>) -> List<&2, ObxRow>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      ObxRow{obx.sort.num(obx.sort.key(l)), l} <> obx.rows(t)

def obx.row.le(a: ObxRow, b: ObxRow) -> Bool:
  match a b:
    case ObxRow{+x, +l} ObxRow{+y, +m}:
      +c = St.st.f.cmp(x, y)
      Bool.or(Cmp.is_lt(c), Bool.and(Cmp.is_eq(c), Lc.lcl.le(l, m)))

def obx.row.lines(rs: List<&2, ObxRow>) -> List<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Nil{}
    case ObxRow{x, l} <> t:
      l <> obx.row.lines(t)

# the lines sorted as `sort -k2 -n` puts them
def obx.sort.k2n(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  obx.row.lines(List.sort(~ObxRow, ~obx.row.le, obx.rows(ls)))

def obx.last.n(+ls: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, List<&2, U32>>:
  +k = List.length(&2, List<&2, U32>, ls)
  List.drop(&2, List<&2, U32>, ls, Nat.sub(k, n))

def obx.dmon.say(+xs: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, obx.head(xs, 2n), obx.unlines(obx.last.n(obx.sort.k2n(obx.grep.v(S.split.lines(xs), [35])), 3n)))

# grep -i -A3 ---------------------------------------------------------------------------------
#
# `nvidia-smi -q -d PERFORMANCE | grep -i -A3 "clocks event reasons\|slowdown"
# | head -20`: each line naming the clocks' event reasons or a slowdown and
# the three after it, "--" between groups that are apart, the first 20.

def obx.ctx.hit(+l: List<&2, U32>) -> Bool:
  +x = obx.lower.all(l)
  Bool.or(S.infix(x, S.b("clocks event reasons")), S.infix(x, S.b("slowdown")))

def obx.ctx.go(ls: List<&2, List<&2, U32>>, +left: Nat, +started: Bool, +gap: Bool) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +hit = obx.ctx.hit(l)
      +show = Bool.or(hit, Nat.is_lt(0n, left))
      +rest = obx.ctx.go(t, Bool.pick(Nat, hit, 3n, Nat.sub(left, 1n)), Bool.or(started, show), Bool.not(show))
      +sep = Bool.and(show, Bool.and(started, gap))
      Bool.pick(List<&2, List<&2, U32>>, show,
        List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, sep, [S.b("--"), l], [l]), rest), rest)

def obx.ctx(+xs: List<&2, U32>) -> List<&2, U32>:
  obx.head(obx.unlines(obx.ctx.go(S.split.lines(xs), 0n, False{}, False{})), 20n)

# Processes ------------------------------------------------------------------------------------

def obx.get.got(r: Result<&1, &1, U32 & String, String>) -> Maybe<&2, String>:
  match r:
    case Done{v}:
      Some{v}
    case Fail{e}:
      None{}

# $NAME: None when it is unset (not when it is set and empty)
def obx.get(name: String) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return obx.get.got(r)

# ${V:-d}: the value unless it is unset or empty
def obx.or(m: Maybe<&2, String>, +d: String) -> String:
  match m:
    case Some{+v}:
      Bool.pick(String, String.is_empty(v), d, v)
    case None{}:
      d

# ${V-d}: the value unless it is unset
def obx.dash(m: Maybe<&2, String>, +d: String) -> String:
  Maybe.default(&2, String, m, d)

def obx.ms() -> U32:
  4000000000

# PROG ARGS with ENV (K=V each) on top of this process's environment:
# its status, stdout and stderr apart (127: it did not start)
def obx.run(env: List<&2, String>, prog: String, args: List<&2, String>) -> IO(Lc.LclOut):
  do IO<Lc.LclOut>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("env", obx.l1(List.append(&2, String, env, prog <> args)), "", S.cap.bytes(), obx.ms())
    Lc.lcl.run.got(r)

# text on stderr as the program wrote it (IO.print_err adds the newline
# back; a last line without one gains one)
def obx.err.if(none: Bool, +xs: List<&2, U32>) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print_err(S.str(Bool.pick(List<&2, U32>, S.suffix(xs, [10]), List.take(&2, U32, xs, Nat.sub(S.len(xs), 1n)), xs)))

def obx.err(+xs: List<&2, U32>) -> IO(Unit):
  obx.err.if(Nat.is_eq(S.len(xs), 0n), xs)

def obx.out(+xs: List<&2, U32>) -> IO(Unit):
  IO.write(S.str(xs))

# a program's output passed on: stdout, then stderr
def obx.pass(+o: Lc.LclOut) -> IO(Unit):
  do IO<Unit>:
    obx.out(Lc.lcl.out(o))
    obx.err(Lc.lcl.err(o))

def obx.st.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> U32:
  match r:
    case Done{(code, oe)}:
      code
    case Fail{e}:
      127

def obx.redir(append: Bool) -> String:
  Bool.pick(String, append, "exec \"$@\" >> \"$0\" 2>&1", "exec \"$@\" > \"$0\" 2>&1")

# PROG ARGS with ENV, stdout and stderr into the file LOG (appended to when
# append): `sh -c 'exec "$@" > "$0" 2>&1' LOG env ENV PROG ARGS`, a
# redirect and nothing else; the exit status
def obx.to(+log: String, append: Bool, env: List<&2, String>, prog: String, args: List<&2, String>) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", obx.l1(List.append(&2, String, ["-c", obx.redir(append), log, "env"], List.append(&2, String, env, prog <> args))),
        "", S.cap.bytes(), obx.ms())
    return obx.st.got(r)

# the same with stderr into stdout, the text back (`PROG 2>&1 | ...`)
def obx.merged(env: List<&2, String>, prog: String, args: List<&2, String>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    +o : Lc.LclOut <- obx.run(List.append(&2, String, ["sh", "-c", "exec \"$@\" 2>&1", "sh", "env"], env), prog, args)
    return Lc.lcl.out(o)

# Following a log while its program runs ---------------------------------------------------------
#
# `PROG | tee LOG | grep -v "^P"` (time) or `PROG` on the terminal (stage's
# bend-push): the program writes LOG (obx.to) while this process prints what
# it adds every two seconds, whole lines only when it filters, and the rest
# once the program ends.  Its exit status is the answer.

type ObxTl is Data:
  ObxTl{off: Nat, part: List<&2, U32>}

# the complete lines of xs, and what follows its last newline
def obx.cut.go(xs: List<&2, U32>, +cur: List<&2, U32>, +done: List<&2, U32>) -> List<&2, U32> & List<&2, U32>:
  match xs:
    case Nil{}:
      (List.reverse(&2, U32, done), List.reverse(&2, U32, cur))
    case +c <> t:
      +nl = U32.is_eq(c, 10)
      obx.cut.go(t, Bool.pick(List<&2, U32>, nl, Nil{}, c <> cur), Bool.pick(List<&2, U32>, nl, List.append(&2, U32, c <> cur, done), done))

# what to print of new bytes: raw (no filter), or the whole lines that do
# not start with p (each with its newline), the part line kept back; at the
# end the part line too
def obx.show.raw(+data: List<&2, U32>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    obx.out(data)
    return Nil{}

def obx.show.lines(fin: Bool, +p: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +part: List<&2, U32>) -> IO(List<&2, U32>):
  match fin:
    case False{}:
      do IO<List<&2, U32>>:
        obx.out(obx.unlines(ls))
        return part
    case True{}:
      do IO<List<&2, U32>>:
        obx.out(obx.unlines(List.append(&2, List<&2, U32>, ls, obx.grep.v(S.split.lines(part), p))))
        return Nil{}

def obx.show.cut(fin: Bool, +p: List<&2, U32>, r: List<&2, U32> & List<&2, U32>) -> IO(List<&2, U32>):
  (whole, part) = r
  obx.show.lines(fin, p, obx.grep.v(S.split.lines(whole), p), part)

def obx.show(fin: Bool, f: Maybe<&2, List<&2, U32>>, +data: List<&2, U32>) -> IO(List<&2, U32>):
  match f:
    case None{}:
      obx.show.raw(data)
    case Some{+p}:
      obx.show.cut(fin, p, obx.cut.go(data, Nil{}, Nil{}))

def obx.size.if(append: Bool, +log: String) -> IO(Nat):
  match append:
    case True{}:
      S.size(log)
    case False{}:
      IO.pure(Nat, 0n)

def obx.tl.step(fin: Bool, +log: String, f: Maybe<&2, List<&2, U32>>, t: ObxTl) -> IO(ObxTl):
  match t:
    case ObxTl{+off, +part}:
      do IO<ObxTl>:
        +xs : List<&2, U32> <- S.read(log)
        +n : Nat = S.len(xs)
        +new : List<&2, U32> = List.drop(&2, U32, xs, off)
        +rest : List<&2, U32> <- obx.show(fin, f, List.append(&2, U32, part, new))
        return ObxTl{Nat.max(n, off), rest}

def obx.fl.got(fuel: Nat, +ch: Chan(U32), +log: String, +f: Maybe<&2, List<&2, U32>>, t: ObxTl, p: Poll<&1, &1, Maybe<&1, U32>, Unit>) -> IO(U32):
  match fuel p:
    case _ Ready{m}:
      do IO<U32>:
        u : ObxTl <- obx.tl.step(True{}, log, f, t)
        return Maybe.default(&1, U32, m, 1)
    case 0n Wait{u}:
      do IO<U32>:
        t2 : ObxTl <- obx.tl.step(False{}, log, f, t)
        +st : U32 <- IO.join(U32, ch)
        u3 : ObxTl <- obx.tl.step(True{}, log, f, t2)
        return st
    case 1n+k Wait{u}:
      do IO<U32>:
        t2 : ObxTl <- obx.tl.step(False{}, log, f, t)
        q : Poll<&1, &1, Maybe<&1, U32>, Unit> <- Chan.try_recv(U32, ch, 2000)
        obx.fl.got(k, ch, log, f, t2, q)

# PROG ARGS with ENV into LOG (appended to when append), followed: f is
# None to print every byte, Some P to print the lines not starting with P
def obx.follow(+log: String, +append: Bool, env: List<&2, String>, prog: String, args: List<&2, String>, f: Maybe<&2, List<&2, U32>>) -> IO(U32):
  do IO<U32>:
    +off : Nat <- obx.size.if(append, log)
    +ch : Chan(U32) <- IO.fork(U32, obx.to(log, append, env, prog, args))
    q : Poll<&1, &1, Maybe<&1, U32>, Unit> <- Chan.try_recv(U32, ch, 2000)
    obx.fl.got(U32.to_nat(2000000), ch, log, f, ObxTl{off, Nil{}}, q)

# The setting ----------------------------------------------------------------------------------

def obx.cu() -> String:
  "/usr/local/cuda"

def obx.tok() -> String:
  "weights/code32k.bpe"

def obx.clangs() -> List<&2, String>:
  ["clang-19", "clang-18", "clang-17", "clang-16", "clang-15", "clang-14", "clang"]

# the first of clang-19 ... clang-14, clang on $PATH (fp.sh's `command -v` loop)
def obx.clang.go(cs: List<&2, String>, found: Maybe<&2, String>) -> IO(Maybe<&2, String>):
  match cs found:
    case _ Some{p}:
      IO.pure(Maybe<&2, String>, Some{p})
    case Nil{} None{}:
      IO.pure(Maybe<&2, String>, None{})
    case +c <> t None{}:
      do IO<Maybe<&2, String>>:
        m : Maybe<&2, String> <- S.which(c)
        obx.clang.go(t, m)

def obx.over.got(m: Maybe<&2, String>, +kv: String) -> List<&2, String>:
  match m:
    case Some{v}:
      [kv]
    case None{}:
      Nil{}

# NAME=VALUE when the caller exported NAME (a variable fp.sh assigned reaches
# its programs with the new value only then)
def obx.over(+name: String, +value: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    m : Maybe<&2, String> <- obx.get(name)
    return obx.over.got(m, name ++ "=" ++ value)

def obx.env.or(+name: String, +d: String) -> IO(String):
  do IO<String>:
    m : Maybe<&2, String> <- obx.get(name)
    return obx.or(m, d)

type ObxCx is Data:
  ObxCx{clang: Maybe<&2, String>, base: List<&2, String>, mem: String, plan: String, run: String, name: String}

def obx.cx.clang(+c: ObxCx) -> Maybe<&2, String>:
  match c:
    case ObxCx{cl, b, m, p, r, n}:
      cl

def obx.cx.base(+c: ObxCx) -> List<&2, String>:
  match c:
    case ObxCx{cl, b, m, p, r, n}:
      b

def obx.cx.mem(+c: ObxCx) -> String:
  match c:
    case ObxCx{cl, b, m, p, r, n}:
      m

def obx.cx.plan(+c: ObxCx) -> String:
  match c:
    case ObxCx{cl, b, m, p, r, n}:
      p

def obx.cx.run(+c: ObxCx) -> String:
  match c:
    case ObxCx{cl, b, m, p, r, n}:
      r

def obx.cx.name(+c: ObxCx) -> String:
  match c:
    case ObxCx{cl, b, m, p, r, n}:
      n

# fp.sh's top: CU, CLANG, CC, LD_LIBRARY_PATH (exported), MEM, PLAN, RUN,
# NAME, TOK; base is what every program it runs gets on top of the
# environment
def obx.cx() -> IO(ObxCx):
  do IO<ObxCx>:
    +clang : Maybe<&2, String> <- obx.clang.go(obx.clangs(), None{})
    +cl : String = Maybe.default(&2, String, clang, "")
    ld : Maybe<&2, String> <- obx.get("LD_LIBRARY_PATH")
    +mem : String <- obx.env.or("MEM", "48GB")
    +plan : String <- obx.env.or("PLAN", "run/fp100m/plan-fp100m-b16-windows.tsv")
    +run : String <- obx.env.or("RUN", "run/fp100m")
    +name : String <- obx.env.or("NAME", "fp100m")
    o1 : List<&2, String> <- obx.over("CU", obx.cu())
    o2 : List<&2, String> <- obx.over("CLANG", cl)
    o3 : List<&2, String> <- obx.over("CC", cl ++ " -DBEND_CUDA=1 -DBEND_NO_SRC -I/usr/local/cuda/include -L/usr/local/cuda/lib64 -std=c11 -O2")
    o4 : List<&2, String> <- obx.over("MEM", mem)
    o5 : List<&2, String> <- obx.over("PLAN", plan)
    o6 : List<&2, String> <- obx.over("RUN", run)
    o7 : List<&2, String> <- obx.over("NAME", name)
    o8 : List<&2, String> <- obx.over("TOK", obx.tok())
    return ObxCx{clang, obx.cat([o1, o2, o3, ["LD_LIBRARY_PATH=" ++ obx.cu() ++ "/lib64:" ++ obx.or(ld, "")], o4, o5, o6, o7, o8]), mem, plan, run, name}

def obx.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      S.str(x) <> obx.strs(t)

# `--gpu $MEM`, unquoted: MEM's words
def obx.gpu(+mem: String) -> List<&2, String>:
  "--gpu" <> obx.strs(obx.words(S.b(mem)))

# Building ---------------------------------------------------------------------------------------

def obx.exe(+p: String) -> IO(Bool):
  do IO<Bool>:
    +o : Lc.LclOut <- Lc.lcl.run(60, "test", ["-x", p])
    return Lc.lcl.ok(o)

def obx.cc.flags(+p: String) -> List<&2, String>:
  ["-DBEND_CUDA=1", "-DBEND_NO_SRC", "-I/usr/local/cuda/include", "-L/usr/local/cuda/lib64", "-std=c11", "-O2",
   p ++ ".c", "-lpthread", "-lm", "-o", p, "-lcuda", "-lnvrtc"]

def obx.cc.done(ok: Bool, +c: String, +p: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "bend-box: " ++ c ++ " failed to build " ++ p)

def obx.cc.with(m: Maybe<&2, String>, +base: List<&2, String>, +p: String) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "bend-box: no clang on $PATH (clang-19 ... clang-14, clang) to build " ++ p)
    case Some{+c}:
      do IO<Unit>:
        +o : Lc.LclOut <- obx.run(base, c, obx.cc.flags(p))
        obx.pass(o)
        obx.cc.done(Lc.lcl.ok(o), c, p)

def obx.cc.if(have: Bool, +cx: ObxCx, +p: String) -> IO(Unit):
  match have:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      obx.cc.with(obx.cx.clang(cx), obx.cx.base(cx), p)

# P from P.c unless P is there and executable (fp.sh: `[ -x P ] || $CC ...`)
def obx.compile(+cx: ObxCx, +p: String) -> IO(Unit):
  do IO<Unit>:
    x : Bool <- obx.exe(p)
    obx.cc.if(x, cx, p)

# build: traind and dense, then the GPU, its clocks' event reasons and the memory
def obx.build(+cx: ObxCx) -> IO(Unit):
  +base = obx.cx.base(cx)
  do IO<Unit>:
    S.mkdir("out")
    obx.compile(cx, "traind")
    obx.compile(cx, "dense")
    +q : Lc.LclOut <- obx.run(base, "nvidia-smi", ["--query-gpu=name,driver_version,power.limit,memory.total", "--format=csv,noheader"])
    obx.pass(q)
    +p : Lc.LclOut <- obx.run(base, "nvidia-smi", ["-q", "-d", "PERFORMANCE"])
    obx.out(obx.ctx(Lc.lcl.out(p)))
    obx.err(Lc.lcl.err(p))
    +f : Lc.LclOut <- obx.run(base, "free", ["-g"])
    obx.out(obx.head(Lc.lcl.out(f), 2n))
    obx.err(Lc.lcl.err(f))

# The modes ---------------------------------------------------------------------------------------

def obx.gate.run(+cx: ObxCx) -> IO(Unit):
  do IO<Unit>:
    obx.build(cx)
    IO.print("== G2: the dense program on the GPU against the tree trainer on the CPU (every gradient within 1e-5 relative)")
    st : U32 <- obx.to("gate.log", False{}, List.append(&2, String, obx.cx.base(cx), ["BEND_PROFILE=1"]), "./dense", obx.gpu(obx.cx.mem(cx)))
    +log : List<&2, U32> <- S.read("gate.log")
    obx.out(obx.tail(log, 12n))
    obx.out(obx.gate.text(obx.gate.of(log)))

# fp.sh's $common and $setting: the run's plan and shape, and its optimizer
def obx.cs(+cx: ObxCx) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +micro : String <- obx.env.or("MICRO", "4")
    m : Maybe<&2, String> <- obx.get("MASK")
    +lr : String <- obx.env.or("LR", "3e-4")
    +warm : String <- obx.env.or("WARM", "300")
    return ["PLAN=" ++ obx.cx.plan(cx), "RUN_DIR=" ++ obx.cx.run(cx), "SHARD_SIZE=fp100m", "TOKENIZER_FILE=" ++ obx.tok(), "PRESET=fp100m",
      "TRAIN_BATCH=16", "TRAIN_MICRO=" ++ micro, "TRAIN_CHUNK=16", "BEND_GEMM_NUMERICS=tf32", "TRAIN_MASK=" ++ obx.dash(m, "kinds"),
      "TRAIN_OPT=muon", "TRAIN_LR=" ++ lr, "TRAIN_WARMUP=" ++ warm, "TRAIN_WD=0.01", "GRAD_CLIP=1.0"]

def obx.timing(n: List<&2, U32>) -> Bool:
  +x = n
  Bool.and(S.prefix(x, S.b("timing-step")), S.suffix(x, S.b(".checkpoint")))

def obx.rm.list(ns: List<&2, List<&2, U32>>) -> IO(Unit):
  match ns:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        o : Lc.LclOut <- Lc.lcl.run(60, "rm", ["-f", "--", "out/" ++ S.str(n)])
        obx.rm.list(t)

# rm -f out/timing-step*.checkpoint
def obx.rm.timing() -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls("out")
    obx.rm.list(List.filter(~List<&2, U32>, ~obx.timing, Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{})))

def obx.time.run(+cx: ObxCx, +steps: String) -> IO(Unit):
  do IO<Unit>:
    obx.build(cx)
    +micro : String <- obx.env.or("MICRO", "4")
    IO.print("== timing: " ++ steps ++ " steps of fp100m at micro " ++ micro)
    ov : List<&2, String> <- obx.over("STEPS", steps)
    +base : List<&2, String> = List.append(&2, String, obx.cx.base(cx), ov)
    +dm : String <- S.background(".", obx.l1(base), "dmon.txt", False{}, "nvidia-smi", ["dmon", "-s", "pucm", "-d", "2"])
    cs : List<&2, String> <- obx.cs(cx)
    st : U32 <- obx.follow("time.log", False{}, obx.cat([base, cs, ["TRAIN_STEPS=" ++ steps, "EVAL_WINDOWS=0", "SAVE_EVERY=0", "OUT=out/timing"]]),
      "stdbuf", List.append(&2, String, ["-oL", "./traind"], obx.gpu(obx.cx.mem(cx))), Some{S.b("bend profile")})
    k : Lc.LclOut <- Lc.lcl.run(30, "kill", [dm])
    +log : List<&2, U32> <- S.read("time.log")
    +pl : List<&2, U32> <- S.read(obx.cx.plan(cx))
    obx.out(obx.time.say(log, obx.plan.steps(pl)))
    IO.print("== dmon (power W, sm %, mem %)")
    +d : List<&2, U32> <- S.read("dmon.txt")
    obx.out(obx.dmon.say(d))
    obx.rm.timing()

def obx.run.mode(+cx: ObxCx) -> IO(Unit):
  +base = obx.cx.base(cx)
  do IO<Unit>:
    obx.build(cx)
    S.mkdir("out")
    dm : String <- S.background.setsid(".", obx.l1(base), "dmon.txt", False{}, "nvidia-smi", ["dmon", "-s", "pucm", "-d", "30"])
    cs : List<&2, String> <- obx.cs(cx)
    +steps : String <- obx.env.or("STEPS", "8803")
    +ev : String <- obx.env.or("EVAL", "250")
    +evw : String <- obx.env.or("EVALW", "128")
    +save : String <- obx.env.or("SAVE", "500")
    +pid : String <- S.background.setsid(".", obx.l1(obx.cat([base, cs, ["TRAIN_STEPS=" ++ steps, "EVAL_EVERY=" ++ ev, "EVAL_WINDOWS=" ++ evw,
      "SAVE_EVERY=" ++ save, "OUT=out/" ++ obx.cx.name(cx)]])), "train.log", False{}, "stdbuf", obx.l1(List.append(&2, String, ["-oL", "./traind"], obx.gpu(obx.cx.mem(cx)))))
    IO.print("trainer pid " ++ pid ++ "; tail -f train.log")

# A stage's own settings: RUN_DIR/stage.env as KEY=VALUE lines (run 3's S2:
# NLR, NWARM), read with bend-push's reader rather than sourced
def obx.kvs.of(m: Maybe<&2, List<&2, U32>>) -> List<&2, Pu.Kv>:
  match m:
    case Some{+xs}:
      Pu.env.kvs(S.split.lines(xs), Nil{})
    case None{}:
      Nil{}

def obx.kvs(+path: String) -> IO(List<&2, Pu.Kv>):
  do IO<List<&2, Pu.Kv>>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(path)
    return obx.kvs.of(m)

def obx.var.got(m: Maybe<&2, List<&2, U32>>, +name: String) -> IO(Maybe<&2, String>):
  match m:
    case Some{+v}:
      IO.pure(Maybe<&2, String>, Some{S.str(v)})
    case None{}:
      obx.get(name)

# a shell variable after the stage file was read: the file's, else the environment's
def obx.var(+kvs: List<&2, Pu.Kv>, +name: String) -> IO(Maybe<&2, String>):
  obx.var.got(Pu.kv.get(kvs, S.b(name)), name)

def obx.kv.pick(m: Maybe<&2, String>, ld: Bool, +kv: String) -> List<&2, String>:
  Bool.pick(List<&2, String>, Bool.or(ld, Maybe.is_some(&2, String, m)), [kv], Nil{})

def obx.kv.over(+kv: Pu.Kv) -> IO(List<&2, String>):
  match kv:
    case Pu.Kv{+k, +v}:
      do IO<List<&2, String>>:
        m : Maybe<&2, String> <- obx.get(S.str(k))
        return obx.kv.pick(m, S.eq(k, S.b("LD_LIBRARY_PATH")), S.str(k) ++ "=" ++ S.str(v))

def obx.kvs.over(kvs: List<&2, Pu.Kv>) -> IO(List<&2, String>):
  match kvs:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +kv <> t:
      do IO<List<&2, String>>:
        a : List<&2, String> <- obx.kv.over(kv)
        b : List<&2, String> <- obx.kvs.over(t)
        return List.append(&2, String, a, b)

def obx.nsteps.got(m: Maybe<&2, List<&2, U32>>, +plan: String) -> IO(Nat):
  match m:
    case Some{+xs}:
      IO.pure(Nat, Maybe.default(&2, Nat, Lc.lcl.nat(obx.field(obx.words(S.lines.first(xs)), 2n)), 0n))
    case None{}:
      do IO<Nat>:
        IO.print_err("head: cannot open '" ++ plan ++ "' for reading: No such file or directory")
        return 0n

# the plan's step count (`head -1 PLAN | awk '{ print $3 }'`; none: 0)
def obx.nsteps(+plan: String) -> IO(Nat):
  do IO<Nat>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(plan)
    obx.nsteps.got(m, plan)

# again/next: CKPT's run goes on on PLAN (TRAIN_NEXT), NAME.log, out/NAME-step<N>
def obx.cont(+cx: ObxCx, +ckpt: String, +plan: String, +rdir: String, +ssz: String, +name: String) -> IO(Unit):
  do IO<Unit>:
    S.mkdir("out")
    +kvs : List<&2, Pu.Kv> <- obx.kvs(rdir ++ "/stage.env")
    +nsteps : Nat <- obx.nsteps(plan)
    mem : Maybe<&2, String> <- obx.var(kvs, "MEM")
    tok : Maybe<&2, String> <- obx.var(kvs, "TOK")
    nw : Maybe<&2, String> <- obx.var(kvs, "NWARM")
    +nwarm : String = obx.or(nw, Nat.show(Nat.max(Nat.div(nsteps, 20n), 10n)))
    stov : List<&2, String> <- obx.kvs.over(List.reverse(&2, Pu.Kv, kvs))
    ovw : List<&2, String> <- obx.over("NWARM", nwarm)
    mask : Maybe<&2, String> <- obx.var(kvs, "MASK")
    micro : Maybe<&2, String> <- obx.var(kvs, "MICRO")
    nlr : Maybe<&2, String> <- obx.var(kvs, "NLR")
    ev : Maybe<&2, String> <- obx.var(kvs, "EVAL")
    evw : Maybe<&2, String> <- obx.var(kvs, "EVALW")
    save : Maybe<&2, String> <- obx.var(kvs, "SAVE")
    +env : List<&2, String> = obx.cat([obx.cx.base(cx), stov, ovw, ["TRAIN_INIT=" ++ ckpt, "TRAIN_NEXT=1", "PLAN=" ++ plan, "RUN_DIR=" ++ rdir,
      "SHARD_SIZE=" ++ ssz, "TRAIN_MASK=" ++ obx.dash(mask, "kinds"), "TOKENIZER_FILE=" ++ obx.dash(tok, obx.tok()), "TRAIN_BATCH=16",
      "TRAIN_MICRO=" ++ obx.or(micro, "4"), "TRAIN_CHUNK=16", "BEND_GEMM_NUMERICS=tf32", "TRAIN_LR=" ++ obx.or(nlr, "1e-4"),
      "TRAIN_WARMUP=" ++ nwarm, "EVAL_EVERY=" ++ obx.or(ev, "250"), "EVAL_WINDOWS=" ++ obx.or(evw, "128"), "SAVE_EVERY=" ++ obx.or(save, "500"),
      "OUT=out/" ++ name]])
    +pid : String <- S.background.setsid(".", obx.l1(env), name ++ ".log", False{}, "stdbuf",
      obx.l1(List.append(&2, String, ["-oL", "./traind-next"], obx.gpu(obx.dash(mem, obx.cx.mem(cx))))))
    IO.print("trainer pid " ++ pid ++ "; tail -f " ++ name ++ ".log")

def obx.need.if(empty: Bool, +v: String, +usage: String) -> IO(String):
  match empty:
    case True{}:
      IO.die(String, 2, "bend-box: usage: " ++ usage)
    case False{}:
      IO.pure(String, v)

# ${N:?usage}: the argument, or the usage and exit 2 when it is missing or empty
def obx.need(m: Maybe<&2, String>, +usage: String) -> IO(String):
  match m:
    case Some{+v}:
      obx.need.if(String.is_empty(v), v, usage)
    case None{}:
      IO.die(String, 2, "bend-box: usage: " ++ usage)

def obx.arg(+xs: List<&2, String>, +i: Nat) -> Maybe<&2, String>:
  List.get(&2, String, xs, i)

def obx.u.next() -> String:
  "bend-box next CKPT | bend-box again CKPT PLAN RUN_DIR SHARD_SIZE NAME"

def obx.u.resume() -> String:
  "bend-box resume CKPT PLAN RUN_DIR SHARD_SIZE NAME STEPS"

def obx.next(+cx: ObxCx, +t: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    obx.compile(cx, "traind-next")
    +ckpt : String <- obx.need(obx.arg(t, 0n), obx.u.next())
    obx.cont(cx, ckpt, "run/next/plan-next-b16-windows.tsv", "run/next", "next", "next")

def obx.again(+cx: ObxCx, +t: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    obx.compile(cx, "traind-next")
    +ckpt : String <- obx.need(obx.arg(t, 0n), obx.u.next())
    +plan : String <- obx.need(obx.arg(t, 1n), obx.u.next())
    +rdir : String <- obx.need(obx.arg(t, 2n), obx.u.next())
    +ssz : String <- obx.need(obx.arg(t, 3n), obx.u.next())
    +name : String <- obx.need(obx.arg(t, 4n), obx.u.next())
    obx.cont(cx, ckpt, plan, rdir, ssz, name)

# resume: a save of NAME on its own plan and schedule (a plain hot start),
# STEPS steps, appended to NAME.log
def obx.resume(+cx: ObxCx, +t: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    obx.compile(cx, "traind-next")
    +ckpt : String <- obx.need(obx.arg(t, 0n), obx.u.resume())
    +plan : String <- obx.need(obx.arg(t, 1n), obx.u.resume())
    +rdir : String <- obx.need(obx.arg(t, 2n), obx.u.resume())
    +ssz : String <- obx.need(obx.arg(t, 3n), obx.u.resume())
    +name : String <- obx.need(obx.arg(t, 4n), obx.u.resume())
    +steps : String <- obx.need(obx.arg(t, 5n), obx.u.resume())
    S.mkdir("out")
    mask : Maybe<&2, String> <- obx.get("MASK")
    +micro : String <- obx.env.or("MICRO", "4")
    +ev : String <- obx.env.or("EVAL", "250")
    +evw : String <- obx.env.or("EVALW", "128")
    +save : String <- obx.env.or("SAVE", "500")
    +env : List<&2, String> = List.append(&2, String, obx.cx.base(cx), ["TRAIN_INIT=" ++ ckpt, "PLAN=" ++ plan, "RUN_DIR=" ++ rdir,
      "SHARD_SIZE=" ++ ssz, "TRAIN_STEPS=" ++ steps, "TRAIN_MASK=" ++ obx.dash(mask, "kinds"), "TOKENIZER_FILE=" ++ obx.tok(), "TRAIN_BATCH=16",
      "TRAIN_MICRO=" ++ micro, "TRAIN_CHUNK=16", "BEND_GEMM_NUMERICS=tf32", "EVAL_EVERY=" ++ ev, "EVAL_WINDOWS=" ++ evw, "SAVE_EVERY=" ++ save,
      "OUT=out/" ++ name])
    +pid : String <- S.background.setsid(".", obx.l1(env), name ++ ".log", True{}, "stdbuf",
      obx.l1(List.append(&2, String, ["-oL", "./traind-next"], obx.gpu(obx.cx.mem(cx)))))
    IO.print("trainer pid " ++ pid ++ "; tail -f " ++ name ++ ".log")

# eval -------------------------------------------------------------------------------------------

def obx.ckpt.name(n: List<&2, U32>) -> Bool:
  +x = n
  Bool.and(S.suffix(x, S.b(".checkpoint")), Bool.not(S.head.is(x, 46)))

def obx.outs(ns: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      ("out/" ++ S.str(n)) <> obx.outs(t)

def obx.glob.or(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      ["out/*.checkpoint"]
    case x <> t:
      x <> t

# `out/*.checkpoint` as the shell expands it (bytewise; no match: the pattern)
def obx.glob() -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls("out")
    return obx.glob.or(obx.outs(List.filter(~List<&2, U32>, ~obx.ckpt.name, Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{}))))

def obx.nonempty(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = obx.nonempty(t)
      Bool.pick(List<&2, String>, String.is_empty(x), rest, x <> rest)

def obx.ckpts.got(xs: List<&2, String>) -> IO(List<&2, String>):
  match xs:
    case Nil{}:
      obx.glob()
    case x <> t:
      IO.pure(List<&2, String>, x <> t)

def obx.eval.one(+env: List<&2, String>, +mem: String, +c: String) -> IO(Unit):
  do IO<Unit>:
    IO.print("== " ++ c)
    +o : List<&2, U32> <- obx.merged(List.append(&2, String, ["TRAIN_INIT=" ++ c], env), "./traind", obx.gpu(mem))
    obx.out(obx.tail(obx.unlines(obx.grep.v(S.split.lines(o), S.b("bend profile"))), 3n))

def obx.eval.all(cs: List<&2, String>, +env: List<&2, String>, +mem: String) -> IO(Unit):
  match cs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +c <> t:
      do IO<Unit>:
        obx.eval.one(env, mem, c)
        obx.eval.all(t, env, mem)

def obx.eval(+cx: ObxCx, +t: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    obx.build(cx)
    cs : List<&2, String> <- obx.ckpts.got(obx.nonempty(t))
    +ec : String <- obx.env.or("ECORPUS", "run/eval/transcript-fp.corpus")
    em : Maybe<&2, String> <- obx.get("EMASK")
    +micro : String <- obx.env.or("MICRO", "4")
    obx.eval.all(cs, List.append(&2, String, obx.cx.base(cx), ["EVAL_CORPUS=" ++ ec, "EVAL_MASK=" ++ obx.dash(em, ""),
      "TOKENIZER_FILE=" ++ obx.tok(), "TRAIN_MICRO=" ++ micro, "TRAIN_CHUNK=16", "BEND_GEMM_NUMERICS=tf32"]), obx.cx.mem(cx))

# eval-both: the chain's scores as a job of their own (2026-10-14).  The job
# runs `bend-box eval CKPT...` into eval.log, then, when
# run/eval/transcript-next.corpus is there, the same with
# ECORPUS=run/eval/transcript-next.corpus into eval-next.log, and last
# writes eval.done (stamped: each eval's exit status).  It is started in a
# session of its own and the call returns at once, so a dropped link
# neither stops it nor starts it again; a call while it runs (eval.pid)
# says so and starts nothing.

def obx.self.at(slash: Bool, +argv0: String) -> IO(String):
  match slash:
    case True{}:
      S.realpath(argv0)
    case False{}:
      do IO<String>:
        m : Maybe<&2, String> <- S.which(argv0)
        S.realpath(Maybe.default(&2, String, m, argv0))

# where this binary is: argv[0] itself when it has a slash, else $PATH's
def obx.self(+argv0: String) -> IO(String):
  obx.self.at(S.infix(S.b(argv0), [47]), argv0)

def obx.alive.if(some: Bool, +pid: String) -> IO(Bool):
  match some:
    case False{}:
      IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        +xs : List<&2, U32> <- S.read("/proc/" ++ pid ++ "/cmdline")
        return S.infix(xs, S.b("eval-job"))

def obx.both.start(running: Bool, +pid: String, +argv0: String, +t: List<&2, String>) -> IO(Unit):
  match running:
    case True{}:
      IO.print("eval-both: running (pid " ++ pid ++ "); eval.done when it ends")
    case False{}:
      do IO<Unit>:
        S.rm("eval.done")
        +self : String <- obx.self(argv0)
        +p : String <- S.background.setsid(".", [], "eval-both.log", False{}, self, obx.l1("eval-job" <> t))
        S.write("eval.pid", S.b(p ++ "\n"))
        IO.print("eval-both pid " ++ p ++ ": eval.log, then eval-next.log, eval.done at the end")

def obx.eval.both(+argv0: String, +t: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +p : List<&2, U32> <- S.read("eval.pid")
    +pid : String = S.str(S.chomp(p))
    alive : Bool <- obx.alive.if(Bool.not(String.is_empty(pid)), pid)
    obx.both.start(alive, pid, argv0, t)

def obx.next.if(there: Bool, +self: String, +t: List<&2, String>) -> IO(String):
  match there:
    case False{}:
      IO.pure(String, "skipped (no run/eval/transcript-next.corpus)")
    case True{}:
      do IO<String>:
        +st : U32 <- obx.to("eval-next.log", False{}, ["ECORPUS=run/eval/transcript-next.corpus"], self, "eval" <> t)
        return "exit " ++ U32.show(st)

def obx.eval.job(+argv0: String, +t: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +self : String <- obx.self(argv0)
    +st : U32 <- obx.to("eval.log", False{}, [], self, "eval" <> t)
    there : Bool <- S.exists("run/eval/transcript-next.corpus")
    +nx : String <- obx.next.if(there, self, t)
    Lc.lcl.mark("eval.done", "eval exit " ++ U32.show(st) ++ "; eval-next " ++ nx)
    S.rm("eval.pid")

# Main -------------------------------------------------------------------------------------------

def obx.usage() -> String:
  "usage: bend-box build | gate | time [STEPS] | run | eval [CKPT...] | eval-both [CKPT...]\n"
    ++ "       bend-box next CKPT | again CKPT PLAN RUN_DIR SHARD_SIZE NAME | resume CKPT PLAN RUN_DIR SHARD_SIZE NAME STEPS\n"
    ++ "  (bend/Box/OnBox.bend: fp.sh's modes and environment; run it in the box's working directory)"

# bend-box probe gate|time|dmon|ctx FILE [STEPS]: one of the readers above on
# a file, for a person checking a log by hand (gate.log's verdict, time.log's
# summary for a plan of STEPS steps (8803), dmon.txt's table, the clocks'
# event reasons in `nvidia-smi -q -d PERFORMANCE` output)
def obx.probe.steps(m: Maybe<&2, String>) -> Nat:
  match m:
    case Some{+s}:
      Maybe.default(&2, Nat, Lc.lcl.nat(S.b(s)), 8803n)
    case None{}:
      8803n

def obx.probe(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "gate" <> +f <> Nil{}:
      do IO<Unit>:
        +log : List<&2, U32> <- S.read(f)
        obx.out(obx.gate.text(obx.gate.of(log)))
    case "time" <> +f <> +t:
      do IO<Unit>:
        +log : List<&2, U32> <- S.read(f)
        obx.out(obx.time.say(log, obx.probe.steps(List.head(&2, String, t))))
    case "dmon" <> +f <> Nil{}:
      do IO<Unit>:
        +d : List<&2, U32> <- S.read(f)
        obx.out(obx.dmon.say(d))
    case "ctx" <> +f <> Nil{}:
      do IO<Unit>:
        +d : List<&2, U32> <- S.read(f)
        obx.out(obx.ctx(d))
    case _:
      IO.die(Unit, 2, "usage: bend-box probe gate LOG | time LOG [PLAN_STEPS] | dmon FILE | ctx FILE")

def obx.mode(+cx: ObxCx, +argv0: String, xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "probe" <> t:
      obx.probe(t)
    case "build" <> t:
      obx.build(cx)
    case "gate" <> t:
      obx.gate.run(cx)
    case "time" <> +t:
      obx.time.run(cx, obx.or(obx.arg(t, 0n), "20"))
    case "run" <> t:
      obx.run.mode(cx)
    case "next" <> +t:
      obx.next(cx, t)
    case "again" <> +t:
      obx.again(cx, t)
    case "resume" <> +t:
      obx.resume(cx, t)
    case "eval" <> +t:
      obx.eval(cx, t)
    case "eval-both" <> +t:
      obx.eval.both(argv0, t)
    case "eval-job" <> +t:
      obx.eval.job(argv0, t)
    case _:
      IO.die(Unit, 2, obx.usage())

def obx.main(+argv0: String, xs: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +cx : ObxCx <- obx.cx()
    obx.mode(cx, argv0, xs)
