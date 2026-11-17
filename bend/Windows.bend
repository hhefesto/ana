import Base
import ./Bytes.bend as B
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns
import ./Corpus.bend as Cc
import ./Ftcc.bend as Fc
import ./Sys.bend as S

# windows: whole transcripts packed into training documents of exactly one
# context each, the space they leave filled with the end of a code file.
#
#   bend-windows lengths CORPUS
#   bend-windows plan TRANSCRIPT_LENGTHS FILLER_LENGTHS CAPACITY PLAN
#   bend-windows build TRANSCRIPTS FILLER PLAN OUTPUT CAPACITY PREFIX
#
# Meaning.  The trainer cuts a document of n tokens into the windows of
# BOS : tokens ++ [EOS] and drops the remainder, so a document of exactly
# CAPACITY = ctx - 2 tokens is one window, nothing dropped.  A window
# document here is the last f tokens of a filler document (raw code: a
# file's end, which EOS truly follows), then, for each of its transcripts
# in order, EOS (token 1) and the transcript's tokens:
#
#   window = drop(len(filler) - f, filler) ++ concat [1 : t | t <- ts]
#
# so no transcript is ever cut, each transcript starts right after an EOS
# (as a conversation starts), and the trainer's final EOS ends the last.
#
# `lengths` writes CORPUS.lengths: each document's token count, one per
# line.  `plan` reads two such files and writes PLAN, one line per window,
# `f i k`: the window takes the next k transcripts in TRANSCRIPTS' order
# and, when f > 0, the last f tokens of filler document i (counted from 0
# in FILLER; every filler document is used at most once).  A window whose
# length is not CAPACITY, a plan that runs past the transcripts, or a
# filler document missing or shorter than f is refused (exit 1, nothing
# written).
# The output is FTCC v2 with TRANSCRIPTS' tokenizer identity and master's
# dataset fingerprint (Ftcc.bend); window ids are PREFIX-00000000,
# PREFIX-00000001, ...
#
# The plan is next fit in order for the transcripts: a window takes
# transcripts while the next one (with its EOS) still fits.  In order, not
# first-fit decreasing: a window's transcripts are neighbours in
# TRANSCRIPTS (units of one file, one package), and every window is full
# anyway, the gap being real code.  The gap, f = CAPACITY - used, is filled
# best fit: the end of the shortest unused filler document at least f
# tokens long (the first in FILLER of equal lengths).  Taking the next long
# enough document instead skips the short ones for good: on Nix and Bend
# shards of 5,000 transcripts and 2,500 filler files, next fit ran out of
# filler after 841 to 1,120 of 1,116 to 1,473 windows, best fit served them
# all.  A transcript that does not fit an empty window (bend-transcript
# drops those past WINDOW - 64) or a filler corpus that runs out is refused
# (exit 1, nothing written).

type Plan is Data:
  Plan{f: Nat, i: Nat, k: Nat}

# The plan: every natural number in the text, in threes ---------------------

def digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

# the numbers of xs, newest first; cur is the number being read (none: 0n
# and not reading)
def nums.go(xs: List<&2, U32>, +cur: Nat, +reading: Bool, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Bool.pick(List<&2, Nat>, reading, cur <> acc, acc)
    case +c <> t:
      +d = digit(c)
      +v = Nat.add(Nat.mul(cur, 10n), U32.to_nat(U32.sub(c, 48)))
      nums.go(t, Bool.pick(Nat, d, v, 0n), d, Bool.pick(List<&2, Nat>, Bool.and(reading, Bool.not(d)), cur <> acc, acc))

def plans(ns: List<&2, Nat>) -> List<&2, Plan>:
  match ns:
    case f <> s <> k <> t:
      Plan{f, s, k} <> plans(t)
    case _:
      Nil{}

def plan.read(+xs: List<&2, U32>) -> List<&2, Plan>:
  plans(List.reverse(&2, Nat, nums.go(xs, 0n, False{}, Nil{})))

# Windows ----------------------------------------------------------------

def pad8(+n: Nat) -> String:
  +s = Nat.show(n)
  String.concat(List.replicate(String, Nat.sub(8n, String.length(s)), "0")) ++ s

def id.of(+prefix: String, +i: Nat) -> List<&2, U32>:
  Tk.str.bytes(prefix ++ "-" ++ pad8(i))

def eos.join(ts: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case t <> more:
      1 <> List.append(&2, U32, t, eos.join(more))

def last(+xs: List<&2, U32>, +f: Nat) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.sub(List.length(&2, U32, xs), f))

# The build: one pass over the plan, the state carrying what is left of both
# corpora, the windows so far (newest first) and the first problem met (after
# which nothing more is built)
type St is Data:
  St{fs: Map<&2, List<&2, U32>>, ts: List<&2, List<&2, U32>>, problem: String, docs: List<&2, Fc.Doc>}

# the filler documents by their index (Nat.show) in FILLER
def fmap(ds: List<&2, List<&2, U32>>, +j: Nat, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ds:
    case Nil{}:
      m
    case d <> more:
      fmap(more, 1n+j, Map.set(&2, List<&2, U32>, m, Nat.show(j), d))

def filler.cut(+f: Nat, +x: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  Bool.pick(Maybe<&2, List<&2, U32>>, Nat.is_le(f, List.length(&2, U32, x)), Some{last(x, f)}, None{})

def filler.got(+f: Nat, r: Map<&2, List<&2, U32>> & List<&2, U32>) -> Maybe<&2, List<&2, U32>> & Map<&2, List<&2, U32>>:
  (m, x) = r
  (filler.cut(f, x), m)

# the filler of a window: f = 0 takes none; otherwise document i's last f
# tokens (a missing document reads as empty, so too short)
def filler.take(+f: Nat, +i: Nat, fs: Map<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>> & Map<&2, List<&2, U32>>:
  match f:
    case 0n:
      (Some{Nil{}}, fs)
    case 1n+p:
      filler.got(1n+p, Map.get(List<&2, U32>, Nil{}, fs, Nat.show(i)))

def St.check(ok: Bool, +toks: List<&2, U32>, fs: Map<&2, List<&2, U32>>, ts: List<&2, List<&2, U32>>, docs: List<&2, Fc.Doc>, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match ok:
    case False{}:
      St{fs, ts, "windows: window " ++ Nat.show(i) ++ " holds " ++ Nat.show(List.length(&2, U32, toks)) ++ " tokens, not " ++ Nat.show(cap) ++ " (or the transcripts ran out)", docs}
    case True{}:
      St{fs, ts, "", Fc.Doc{id.of(prefix, i), toks} <> docs}

def St.fill(fl: Maybe<&2, List<&2, U32>>, fs: Map<&2, List<&2, U32>>, +ts: List<&2, List<&2, U32>>, docs: List<&2, Fc.Doc>, +k: Nat, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match fl:
    case None{}:
      St{fs, ts, "windows: window " ++ Nat.show(i) ++ ": its filler document is missing or too short", docs}
    case Some{+pre}:
      +mine = List.take(&2, List<&2, U32>, ts, k)
      +toks = List.append(&2, U32, pre, eos.join(mine))
      St.check(Bool.and(Nat.is_eq(List.length(&2, List<&2, U32>, mine), k), Nat.is_eq(List.length(&2, U32, toks), cap)), toks, fs, List.drop(&2, List<&2, U32>, ts, k), docs, cap, prefix, i)

def St.take(r: Maybe<&2, List<&2, U32>> & Map<&2, List<&2, U32>>, +ts: List<&2, List<&2, U32>>, docs: List<&2, Fc.Doc>, +k: Nat, +cap: Nat, +prefix: String, +i: Nat) -> St:
  (fl, rest) = r
  St.fill(fl, rest, ts, docs, k, cap, prefix, i)

def St.step.ok(ok: Bool, fs: Map<&2, List<&2, U32>>, +ts: List<&2, List<&2, U32>>, +prob: String, docs: List<&2, Fc.Doc>, p: Plan, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match ok p:
    case False{} _:
      St{fs, ts, prob, docs}
    case True{} Plan{+f, +j, +k}:
      St.take(filler.take(f, j, fs), ts, docs, k, cap, prefix, i)

def St.step(st: St, p: Plan, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match st:
    case St{fs, ts, +prob, docs}:
      St.step.ok(String.is_empty(prob), fs, ts, prob, docs, p, cap, prefix, i)

def build.go(ps: List<&2, Plan>, st: St, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match ps:
    case Nil{}:
      st
    case p <> more:
      build.go(more, St.step(st, p, cap, prefix, i), cap, prefix, 1n+i)

# The plan -----------------------------------------------------------------

# does the first transcript still fit after used tokens (itself and its EOS)
def fits(+ts: List<&2, Nat>, +used: Nat, +cap: Nat) -> Bool:
  match ts:
    case Nil{}:
      False{}
    case +t <> more:
      Nat.is_le(Nat.add(used, 1n+t), cap)

# the transcripts one window takes: how many, their tokens, the rest
type Fit is Data:
  Fit{k: Nat, used: Nat, rest: List<&2, Nat>}

def fit(ts: List<&2, Nat>, +used: Nat, +k: Nat, +cap: Nat, ok: Bool) -> Fit:
  match ts ok:
    case +t <> +more True{}:
      +u = Nat.add(used, 1n+t)
      fit(more, u, 1n+k, cap, fits(more, u, cap))
    case _ False{}:
      Fit{k, used, ts}
    case Nil{} True{}:
      Fit{k, used, Nil{}}

# The filler pool: for each length b = 0 .. top (top = CAPACITY + 1 holds
# every document longer than CAPACITY) the unused documents of that length,
# first first.
type Fd is Data:
  Fd{len: Nat, i: Nat}

def fd.le(a: Fd, c: Fd) -> Bool:
  match a c:
    case Fd{+x, i} Fd{+y, j}:
      Bool.or(Nat.is_lt(x, y), Bool.and(Nat.is_eq(x, y), Nat.is_le(i, j)))

def fds(ls: List<&2, Nat>, +top: Nat, +i: Nat) -> List<&2, Fd>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      Fd{Bool.pick(Nat, Nat.is_le(l, top), l, top), i} <> fds(more, top, 1n+i)

# bucketing the sorted documents: b the bucket being filled, cur its
# indices (newest first), acc the buckets closed (newest first)
type Bk is Data:
  Bk{b: Nat, cur: List<&2, Nat>, acc: List<&2, List<&2, Nat>>, xs: List<&2, Fd>, go: Bool}

def bk.close(+b: Nat, +cur: List<&2, Nat>, acc: List<&2, List<&2, Nat>>, xs: List<&2, Fd>, +go: Bool) -> Bk:
  Bk{1n+b, Nil{}, List.reverse(&2, Nat, cur) <> acc, xs, go}

# the next document joins bucket b when its length is b; otherwise (it is
# longer: the list is sorted) bucket b closes
def bk.step(+top: Nat, st: Bk) -> Bk:
  match st:
    case Bk{+b, +cur, +acc, xs, g}:
      match xs:
        case Nil{}:
          bk.close(b, cur, acc, Nil{}, Nat.is_lt(b, top))
        case Fd{+l, +i} <> +more:
          Bool.pick(Bk, Nat.is_eq(l, b), Bk{b, i <> cur, acc, more, True{}}, bk.close(b, cur, acc, Fd{l, i} <> more, True{}))

def bk.go(fuel: Nat, +top: Nat, st: Bk) -> Bk:
  match fuel st:
    case 1n+p Bk{b, cur, acc, xs, True{}}:
      bk.go(p, top, bk.step(top, Bk{b, cur, acc, xs, True{}}))
    case _ other:
      other

def bk.of(st: Bk) -> List<&2, List<&2, Nat>>:
  match st:
    case Bk{b, cur, acc, xs, g}:
      List.reverse(&2, List<&2, Nat>, acc)

def buckets(+ls: List<&2, Nat>, +top: Nat) -> List<&2, List<&2, Nat>>:
  +n = List.length(&2, Nat, ls)
  bk.of(bk.go(Nat.add(Nat.add(n, top), 2n), top, Bk{0n, Nil{}, Nil{}, List.sort(~Fd, ~fd.le, fds(ls, top, 0n)), True{}}))

# buckets 0 .. f-1 and f ..
type Cut is Data:
  Cut{pre: List<&2, List<&2, Nat>>, post: List<&2, List<&2, Nat>>}

def cut.cons(+b: List<&2, Nat>, c: Cut) -> Cut:
  match c:
    case Cut{pre, post}:
      Cut{b <> pre, post}

def cut(f: Nat, bs: List<&2, List<&2, Nat>>) -> Cut:
  match f bs:
    case 0n other:
      Cut{Nil{}, other}
    case 1n+p b <> more:
      cut.cons(b, cut(p, more))
    case _ Nil{}:
      Cut{Nil{}, Nil{}}

# the first document of the first non-empty bucket, and the buckets without it
type Pop is Data:
  Pop{got: Maybe<&2, Nat>, bs: List<&2, List<&2, Nat>>}

def pop.cons(+b: List<&2, Nat>, p: Pop) -> Pop:
  match p:
    case Pop{m, bs}:
      Pop{m, b <> bs}

def pop.first(bs: List<&2, List<&2, Nat>>) -> Pop:
  match bs:
    case Nil{}:
      Pop{None{}, Nil{}}
    case b <> more:
      match b:
        case Nil{}:
          pop.cons(Nil{}, pop.first(more))
        case x <> xt:
          Pop{Some{x}, xt <> more}

# the planner's state: what is left of the transcripts, the filler pool, the
# plan so far (newest first), the filler tokens used, the windows planned
type Pst is Data:
  Pgo{ts: List<&2, Nat>, bs: List<&2, List<&2, Nat>>, acc: List<&2, Plan>, fill: Nat, n: Nat}
  Pdone{acc: List<&2, Plan>, fill: Nat, n: Nat}
  Perr{why: String}

def step.pop(+f: Nat, +k: Nat, rest: List<&2, Nat>, acc: List<&2, Plan>, +fill: Nat, +n: Nat, pre: List<&2, List<&2, Nat>>, p: Pop) -> Pst:
  match p:
    case Pop{Some{i}, post}:
      Pgo{rest, List.append(&2, List<&2, Nat>, pre, post), Plan{f, i, k} <> acc, Nat.add(fill, f), 1n+n}
    case Pop{None{}, post}:
      Perr{"windows: the filler corpus has no unused document of at least " ++ Nat.show(f) ++ " tokens for window " ++ Nat.show(n)}

def step.cut(+f: Nat, +k: Nat, rest: List<&2, Nat>, acc: List<&2, Plan>, +fill: Nat, +n: Nat, c: Cut) -> Pst:
  match c:
    case Cut{pre, post}:
      step.pop(f, k, rest, acc, fill, n, pre, pop.first(post))

def step.fill(f: Nat, +k: Nat, rest: List<&2, Nat>, bs: List<&2, List<&2, Nat>>, acc: List<&2, Plan>, +fill: Nat, +n: Nat) -> Pst:
  match f:
    case 0n:
      Pgo{rest, bs, Plan{0n, 0n, k} <> acc, fill, 1n+n}
    case 1n+(+g):
      step.cut(1n+g, k, rest, acc, fill, n, cut(1n+g, bs))

def step.fit(empty: Bool, r: Fit, bs: List<&2, List<&2, Nat>>, acc: List<&2, Plan>, +fill: Nat, +n: Nat, +cap: Nat, +head: Nat) -> Pst:
  match empty r:
    case True{} _:
      Pdone{acc, fill, n}
    case False{} Fit{0n, used, rest}:
      Perr{"windows: a transcript of " ++ Nat.show(head) ++ " tokens does not fit a window of " ++ Nat.show(cap)}
    case False{} Fit{1n+j, used, rest}:
      step.fill(Nat.sub(cap, used), 1n+j, rest, bs, acc, fill, n)

def first(ns: List<&2, Nat>) -> Nat:
  match ns:
    case Nil{}:
      0n
    case x <> more:
      x

def step(st: Pst, +cap: Nat) -> Pst:
  match st:
    case Pgo{+ts, bs, acc, +fill, +n}:
      step.fit(Nat.is_eq(List.length(&2, Nat, ts), 0n), fit(ts, 0n, 0n, cap, fits(ts, 0n, cap)), bs, acc, fill, n, cap, first(ts))
    case Pdone{acc, fill, n}:
      Pdone{acc, fill, n}
    case Perr{w}:
      Perr{w}

def plan.go(fuel: Nat, st: Pst, +cap: Nat) -> Pst:
  match fuel st:
    case 1n+p Pgo{ts, bs, acc, fill, n}:
      plan.go(p, step(Pgo{ts, bs, acc, fill, n}, cap), cap)
    case _ other:
      other

def plan.bytes(ps: List<&2, Plan>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case Plan{f, s, k} <> more:
      List.append(&2, U32, Tk.str.bytes(Nat.show(f) ++ " " ++ Nat.show(s) ++ " " ++ Nat.show(k) ++ "\n"), plan.bytes(more))

def plan.write(st: Pst, +ntr: Nat, +cap: Nat, +out: String) -> IO(Unit):
  match st:
    case Pdone{acc, +fill, +n}:
      do IO<Unit>:
        Ns.write(out, plan.bytes(List.reverse(&2, Plan, acc)))
        IO.print("windows: " ++ Nat.show(n) ++ " windows of " ++ Nat.show(cap) ++ " tokens for " ++ Nat.show(ntr) ++ " transcripts; filler " ++ Nat.show(fill) ++ " tokens of " ++ Nat.show(Nat.mul(n, cap)) ++ " to " ++ out)
    case Perr{w}:
      IO.die(Unit, 1, w)
    case Pgo{ts, bs, acc, fill, n}:
      IO.die(Unit, 1, "windows: the plan did not finish")

# The packing (R8, 2026-11-17, docs/r8/PLAN.md) --------------------------------
#
# With WINDOW_FILL = F (permille, 1..1000) the plan is not next fit in order but
# best fit with a look ahead: a window opens with the first transcript left and
# then, while one fits, takes the largest of the next WINDOW_LOOK (64)
# transcripts left that keeps its transcripts (each with its EOS) within
# F * CAPACITY / 1000 tokens; the gap left is filler as before (best fit).  The
# transcripts so go out of TRANSCRIPTS' order: `plan` writes PLAN.order (the
# index of each transcript in the windows' order, a line each) and `build`,
# under the same WINDOW_FILL, reads TRANSCRIPTS in that order.  R7 (the user,
# 11-16: "aren't sessions too short?"): next fit in order left 23.9% of a window
# filler, 1.76 transcripts a window; the order a mix writes is a hash's (repair-mix),
# so nothing is lost by taking them out of it.  Unset (0): R7's plan, the same bytes.

type Bin is Data:
  Bin{k: Nat, used: Nat}

type Pkr is Data:
  Pkr{order: List<&2, Nat>, bins: List<&2, Bin>}

def pk.fds(ts: List<&2, Nat>, +i: Nat) -> List<&2, Fd>:
  match ts:
    case Nil{}:
      Nil{}
    case +l <> more:
      Fd{l, i} <> pk.fds(more, 1n+i)

def fd.len(+e: Fd) -> Nat:
  match e:
    case Fd{l, i}:
      l

def fd.i(+e: Fd) -> Nat:
  match e:
    case Fd{l, i}:
      i

# 1 + the place among the first lim transcripts of the largest that fits room
# (1 + its tokens <= room), the first of equal ones; 0 when none fits
def pk.best(ws: List<&2, Fd>, +lim: Nat, +room: Nat, +at: Nat, +bl: Nat, +bp: Nat) -> Nat:
  match ws lim:
    case Nil{} _:
      bp
    case _ 0n:
      bp
    case Fd{+l, i} <> more 1n+m:
      +ok = Bool.and(Nat.is_le(1n+l, room), Nat.is_lt(bl, 1n+l))
      pk.best(more, m, room, 1n+at, Bool.pick(Nat, ok, 1n+l, bl), Bool.pick(Nat, ok, 1n+at, bp))

def pk.at(ws: List<&2, Fd>, p: Nat) -> Fd:
  match ws p:
    case Nil{} _:
      Fd{0n, 0n}
    case x <> t 0n:
      x
    case x <> t 1n+q:
      pk.at(t, q)

def pk.without(ws: List<&2, Fd>, p: Nat) -> List<&2, Fd>:
  match ws p:
    case Nil{} _:
      Nil{}
    case x <> t 0n:
      t
    case x <> t 1n+q:
      x <> pk.without(t, q)

def pk.room(+tgt: Nat, +used: Nat) -> Nat:
  Nat.sub(tgt, used)

# the walk: ps the transcripts left (in order), the window open (k taken, used
# tokens) or not, p its next pick (pk.best, computed for it)
def pk.go(fuel: Nat, ps: List<&2, Fd>, open: Bool, p: Nat, order: List<&2, Nat>, bins: List<&2, Bin>, +k: Nat, +used: Nat, +tgt: Nat, +lim: Nat) -> Pkr:
  match fuel ps open p:
    case 0n _ _ _:
      Pkr{order, bins}
    case 1n+f Nil{} False{} _:
      Pkr{order, bins}
    case 1n+f Nil{} True{} _:
      Pkr{order, Bin{k, used} <> bins}
    case 1n+f Fd{+l, +i} <> +t False{} _:
      pk.go(f, t, True{}, pk.best(t, lim, pk.room(tgt, 1n+l), 0n, 0n, 0n), i <> order, bins, 1n, 1n+l, tgt, lim)
    case 1n+f +x <> +t True{} 0n:
      pk.go(f, x <> t, False{}, 0n, order, Bin{k, used} <> bins, 0n, 0n, tgt, lim)
    case 1n+f +x <> +t True{} 1n+(+q):
      +e = pk.at(x <> t, q)
      +u = Nat.add(used, 1n+fd.len(e))
      +rest = pk.without(x <> t, q)
      pk.go(f, rest, True{}, pk.best(rest, lim, pk.room(tgt, u), 0n, 0n, 0n), fd.i(e) <> order, bins, 1n+k, u, tgt, lim)

def pk.rev(r: Pkr) -> Pkr:
  match r:
    case Pkr{o, b}:
      Pkr{List.reverse(&2, Nat, o), List.reverse(&2, Bin, b)}

def pk.run(+ts: List<&2, Nat>, +tgt: Nat, +lim: Nat) -> Pkr:
  +n = List.length(&2, Nat, ts)
  pk.rev(pk.go(Nat.add(Nat.mul(2n, n), 2n), pk.fds(ts, 0n), False{}, 0n, Nil{}, Nil{}, 0n, 0n, tgt, lim))

# the windows' plan from the bins, the filler as step.fill takes it
type Qst is Data:
  Qgo{bins: List<&2, Bin>, bs: List<&2, List<&2, Nat>>, acc: List<&2, Plan>, fill: Nat, n: Nat}
  Qdone{acc: List<&2, Plan>, fill: Nat, n: Nat}
  Qerr{why: String}

def qstep.pop(+f: Nat, +k: Nat, rest: List<&2, Bin>, acc: List<&2, Plan>, +fill: Nat, +n: Nat, pre: List<&2, List<&2, Nat>>, p: Pop) -> Qst:
  match p:
    case Pop{Some{i}, post}:
      Qgo{rest, List.append(&2, List<&2, Nat>, pre, post), Plan{f, i, k} <> acc, Nat.add(fill, f), 1n+n}
    case Pop{None{}, post}:
      Qerr{"windows: the filler corpus has no unused document of at least " ++ Nat.show(f) ++ " tokens for window " ++ Nat.show(n)}

def qstep.cut(+f: Nat, +k: Nat, rest: List<&2, Bin>, acc: List<&2, Plan>, +fill: Nat, +n: Nat, c: Cut) -> Qst:
  match c:
    case Cut{pre, post}:
      qstep.pop(f, k, rest, acc, fill, n, pre, pop.first(post))

def qstep.fill(f: Nat, +k: Nat, rest: List<&2, Bin>, bs: List<&2, List<&2, Nat>>, acc: List<&2, Plan>, +fill: Nat, +n: Nat) -> Qst:
  match f:
    case 0n:
      Qgo{rest, bs, Plan{0n, 0n, k} <> acc, fill, 1n+n}
    case 1n+(+g):
      qstep.cut(1n+g, k, rest, acc, fill, n, cut(1n+g, bs))

def qstep.bin(ok: Bool, +k: Nat, +used: Nat, rest: List<&2, Bin>, bs: List<&2, List<&2, Nat>>, acc: List<&2, Plan>, +fill: Nat, +n: Nat, +cap: Nat) -> Qst:
  match ok:
    case False{}:
      Qerr{"windows: a transcript of " ++ Nat.show(Nat.sub(used, 1n)) ++ " tokens does not fit a window of " ++ Nat.show(cap)}
    case True{}:
      qstep.fill(Nat.sub(cap, used), k, rest, bs, acc, fill, n)

def qstep(st: Qst, +cap: Nat) -> Qst:
  match st:
    case Qgo{bins, bs, acc, +fill, +n}:
      match bins:
        case Nil{}:
          Qdone{acc, fill, n}
        case Bin{+k, +used} <> more:
          qstep.bin(Nat.is_le(used, cap), k, used, more, bs, acc, fill, n, cap)
    case Qdone{acc, fill, n}:
      Qdone{acc, fill, n}
    case Qerr{w}:
      Qerr{w}

def qplan.go(fuel: Nat, st: Qst, +cap: Nat) -> Qst:
  match fuel st:
    case 1n+p Qgo{bins, bs, acc, fill, n}:
      qplan.go(p, qstep(Qgo{bins, bs, acc, fill, n}, cap), cap)
    case _ other:
      other

def order.bytes(os: List<&2, Nat>) -> List<&2, U32>:
  match os:
    case Nil{}:
      Nil{}
    case +o <> more:
      List.append(&2, U32, Tk.str.bytes(Nat.show(o) ++ "\n"), order.bytes(more))

def qplan.write(st: Qst, +order: List<&2, Nat>, +ntr: Nat, +cap: Nat, +out: String) -> IO(Unit):
  match st:
    case Qdone{acc, +fill, +n}:
      do IO<Unit>:
        Ns.write(out ++ ".order", order.bytes(order))
        Ns.write(out, plan.bytes(List.reverse(&2, Plan, acc)))
        IO.print("windows: " ++ Nat.show(n) ++ " windows of " ++ Nat.show(cap) ++ " tokens for " ++ Nat.show(ntr) ++ " transcripts (packed, WINDOW_FILL); filler " ++ Nat.show(fill) ++ " tokens of " ++ Nat.show(Nat.mul(n, cap)) ++ " to " ++ out)
    case Qerr{w}:
      IO.die(Unit, 1, w)
    case Qgo{bins, bs, acc, fill, n}:
      IO.die(Unit, 1, "windows: the plan did not finish")

def qplan.of(r: Pkr, +n: Nat, +fls: List<&2, Nat>, +cap: Nat, +out: String) -> IO(Unit):
  match r:
    case Pkr{+o, b}:
      qplan.write(qplan.go(Nat.add(n, 2n), Qgo{b, buckets(fls, 1n+cap), Nil{}, 0n, 0n}, cap), o, n, cap, out)

def qplan(+ts: List<&2, Nat>, +fls: List<&2, Nat>, +cap: Nat, +fl: Nat, +lim: Nat, +out: String) -> IO(Unit):
  qplan.of(pk.run(ts, Nat.div(Nat.mul(cap, fl), 1000n), lim), List.length(&2, Nat, ts), fls, cap, out)

# TRANSCRIPTS' documents in PLAN.order's order (y: the map and the document of order's head)
def perm.next(+os: List<&2, Nat>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>> & List<&2, U32>:
  match os:
    case Nil{}:
      (m, Nil{})
    case +j <> t:
      Map.get(List<&2, U32>, Nil{}, m, Nat.show(j))

def perm.go(os: List<&2, Nat>, y: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, List<&2, U32>>:
  match os:
    case Nil{}:
      Nil{}
    case j <> +t:
      (m, d) = y
      d <> perm.go(t, perm.next(t, m))

def perm(+os: List<&2, Nat>, ds: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  perm.go(os, perm.next(os, fmap(ds, 0n, Map.new(&2, List<&2, U32>))))


def nums(+xs: List<&2, U32>) -> List<&2, Nat>:
  List.reverse(&2, Nat, nums.go(xs, 0n, False{}, Nil{}))

# R7's next fit in order (WINDOW_FILL unset or 0), else the packing above
def plan.pick(r7: Bool, +ts: List<&2, Nat>, +fls: List<&2, Nat>, +cap: Nat, +fl: Nat, +lim: Nat, +out: String) -> IO(Unit):
  match r7:
    case True{}:
      +n = List.length(&2, Nat, ts)
      plan.write(plan.go(1n+n, Pgo{ts, buckets(fls, 1n+cap), Nil{}, 0n, 0n}, cap), n, cap, out)
    case False{}:
      qplan(ts, fls, cap, fl, lim, out)

def plan(+tp: String, +fp: String, +cap: Nat, +out: String) -> IO(Unit):
  do IO<Unit>:
    +tx : List<&2, U32> <- Ns.read(tp)
    +fx : List<&2, U32> <- Ns.read(fp)
    +fl : Nat <- S.env.nat("WINDOW_FILL", 0n)
    lim : Nat <- S.env.nat("WINDOW_LOOK", 64n)
    plan.pick(Nat.is_eq(fl, 0n), nums(tx), nums(fx), cap, fl, lim, out)

def plan.cap(+t: String, +f: String, m: Maybe<&2, Nat>, +o: String) -> IO(Unit):
  match m:
    case Some{+c}:
      plan(t, f, c, o)
    case None{}:
      IO.die(Unit, 2, "windows: CAPACITY must be a natural number")

# Main -------------------------------------------------------------------

def lengths.show(ds: List<&2, List<&2, U32>>) -> String:
  match ds:
    case Nil{}:
      ""
    case d <> more:
      Nat.show(List.length(&2, U32, d)) ++ "\n" ++ lengths.show(more)

def lengths(+path: String) -> IO(Unit):
  do IO<Unit>:
    +xs : List<&2, U32> <- Ns.read(path)
    +c : Cc.Corpus <- IO.pure(Cc.Corpus, Cc.corpus(xs))
    Ns.write(path ++ ".lengths", Tk.str.bytes(lengths.show(Cc.Corpus.docs(c))))

def tok.of(+c: Cc.Corpus) -> String:
  match c:
    case Cc.Corpus{m, v, t, d, x}:
      t

def write.if(ok: Bool, +ds: List<&2, Fc.Doc>, +tok: String, +out: String, +p: String) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, p)
    case True{}:
      +tb = Tk.str.bytes(tok)
      +dataset = Fc.dataset(tb, ds)
      do IO<Unit>:
        Ns.write(out, Fc.bytes(tb, Tk.str.bytes(dataset), ds))
        IO.print("windows: " ++ Nat.show(List.length(&2, Fc.Doc, ds)) ++ " windows written to " ++ out)
        IO.print("dataset fingerprint: " ++ dataset)

def write(st: St, +tok: String, +out: String) -> IO(Unit):
  match st:
    case St{fs, ts, +p, ds}:
      write.if(String.is_empty(p), List.reverse(&2, Fc.Doc, ds), tok, out, p)

# the transcripts as the plan takes them: in order (R7), or in PLAN.order's (WINDOW_FILL)
def build.order(r7: Bool, +pp: String) -> IO(List<&2, U32>):
  match r7:
    case True{}:
      IO.pure(List<&2, U32>, Nil{})
    case False{}:
      Ns.read(pp ++ ".order")

def build.docs(r7: Bool, +os: List<&2, Nat>, ds: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match r7:
    case True{}:
      ds
    case False{}:
      perm(os, ds)

def build(+tp: String, +fp: String, +pp: String, +out: String, +cap: Nat, +prefix: String) -> IO(Unit):
  do IO<Unit>:
    +tx : List<&2, U32> <- Ns.read(tp)
    +fx : List<&2, U32> <- Ns.read(fp)
    +px : List<&2, U32> <- Ns.read(pp)
    +tc : Cc.Corpus <- IO.pure(Cc.Corpus, Cc.corpus(tx))
    +fc : Cc.Corpus <- IO.pure(Cc.Corpus, Cc.corpus(fx))
    +fl : Nat <- S.env.nat("WINDOW_FILL", 0n)
    +ox : List<&2, U32> <- build.order(Nat.is_eq(fl, 0n), pp)
    write(build.go(plan.read(px), St{fmap(Cc.Corpus.docs(fc), 0n, Map.new(&2, List<&2, U32>)), build.docs(Nat.is_eq(fl, 0n), nums(ox), Cc.Corpus.docs(tc)), "", Nil{}}, cap, prefix, 0n), tok.of(tc), out)

def build.cap(+t: String, +f: String, +p: String, +o: String, m: Maybe<&2, Nat>, +pre: String) -> IO(Unit):
  match m:
    case Some{+c}:
      build(t, f, p, o, c, pre)
    case None{}:
      IO.die(Unit, 2, "windows: CAPACITY must be a natural number")

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-windows lengths CORPUS | bend-windows plan TRANSCRIPT_LENGTHS FILLER_LENGTHS CAPACITY PLAN | bend-windows build TRANSCRIPTS FILLER PLAN OUTPUT CAPACITY PREFIX")

def args.go(ls: Bool, bd: Bool, pl: Bool, rest: List<String>) -> IO(Unit):
  match ls bd pl rest:
    case True{} _ _ p <> Nil{}:
      lengths(p)
    case False{} True{} _ t <> f <> p <> o <> c <> pre <> Nil{}:
      build.cap(t, f, p, o, Nat.read(c), pre)
    case False{} False{} True{} t <> f <> c <> o <> Nil{}:
      plan.cap(t, f, Nat.read(c), o)
    case _ _ _ _:
      usage()

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case +m <> rest:
      args.go(String.eq(m, "lengths"), String.eq(m, "build"), String.eq(m, "plan"), rest)
    case Nil{}:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked (Bend 2.0.32)
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    args(xs)
