import Base
import ../Sys.bend as S
import ./Combine.bend as C
import ./Eval.bend as Ev
import ./Agent.bend as Ea
import ../Agent/Spec.bend as A
import ../Agent/Episode.bend as E

# The agent evaluation's statistics (docs/AGENT.md), read from an
# agent-eval DIR (agent.nul, episodes.nul, prompt.N):
#
#   corpus-v2 agent-stats DIR [DIR2]
#
#   solved within k   the episodes solved within 1..4 calls
#   after a tool      solved with 2 calls or more: ana fixed an answer after
#                     reading the checker
#   copies            among the Terms ana wrote after a failing echo, those
#                     whose code is the code of the Term before (the run 2
#                     failure: the rejected answer written again)
#   drift             among them, those under another heading than the
#                     episode's first (`## Type` after a rejected `## Term`)
#
# With DIR2 (the same prompts, another checkpoint or setting), each outcome
# paired by prompt: A only, B only, and the exact two-sided McNemar p of
# the discordant pairs (binomial, n = b + c, at 1/2).

type AsE is Data:
  AsE{i: Nat, solved: Bool, calls: Nat, terms: Nat, copies: Nat, drift: Nat}

def AsE.i(+x: AsE) -> Nat:
  match x:
    case AsE{i, s, c, t, k, d}:
      i

def AsE.solved(+x: AsE) -> Bool:
  match x:
    case AsE{i, s, c, t, k, d}:
      s

def AsE.after(+x: AsE) -> Bool:
  match x:
    case AsE{i, s, c, t, k, d}:
      Bool.and(s, Nat.is_le(2n, c))

# the episode proper's Term and Type turns (given, act or try), in order
def as.terms(e: List<&2, A.Turn>) -> List<&2, List<&2, U32>>:
  match e:
    case Nil{}:
      Nil{}
    case A.Turn{+r, +x} <> +t:
      +c = A.ag.role.code(r)
      +term = Bool.and(Bool.or(Nat.is_eq(c, 1n), Bool.or(Nat.is_eq(c, 3n), Nat.is_eq(c, 6n))),
        Bool.or(A.ag.prefix(x, A.ag.ascii("## Term\n")), A.ag.prefix(x, A.ag.ascii("## Type\n"))))
      Bool.pick(List<&2, List<&2, U32>>, term, x <> as.terms(t), as.terms(t))

# copies and drifts among the Terms after the first (each follows a failing
# echo: a pass ends the episode)
def as.pairs(ts: List<&2, List<&2, U32>>, +first: List<&2, U32>, +prev: List<&2, U32>, +k: Nat, +d: Nat) -> Nat & Nat:
  match ts:
    case Nil{}:
      (k, d)
    case +x <> t:
      +copy = A.ag.eq(A.ag.code(x), A.ag.code(prev))
      +drift = Bool.not(A.ag.eq(A.ag.line1(10, x), A.ag.line1(10, first)))
      as.pairs(t, first, x, Nat.add(k, Bool.pick(Nat, copy, 1n, 0n)), Nat.add(d, Bool.pick(Nat, drift, 1n, 0n)))

def as.mk(+i: Nat, +solved: Bool, +calls: Nat, +n: Nat, kd: Nat & Nat) -> AsE:
  (k, d) = kd
  AsE{i, solved, calls, n, k, d}

def as.of.terms(+i: Nat, +solved: Bool, +calls: Nat, ts: List<&2, List<&2, U32>>) -> AsE:
  match ts:
    case Nil{}:
      AsE{i, solved, calls, 0n, 0n, 0n}
    case +x <> +t:
      as.mk(i, solved, calls, List.length(&2, List<&2, U32>, t), as.pairs(t, x, x, 0n, 0n))

# one episode: its outcome (agent.nul) and its text (episodes.nul) past its
# header line and prompt
def as.one(+i: Nat, +r: Ea.EaR, +ep: List<&2, U32>, +prompt: List<&2, U32>) -> AsE:
  +x = Ea.ea.text(ep)
  +n = Nat.add(List.length(&2, U32, A.ag.line1(10, x)), List.length(&2, U32, prompt))
  as.of.terms(i, Ea.EaR.solved(r), Ea.EaR.calls(r), as.terms(E.ep.proper(A.ag.read.bytes(x), n)))

# episodes.nul: N, then the episode, each NUL-terminated
type AsT is Data:
  AsT{n: Nat, text: List<&2, U32>}

def as.texts(xs: List<&2, List<&2, U32>>) -> List<&2, AsT>:
  match xs:
    case +n <> +t <> more:
      AsT{C.cb.nat(n), t} <> as.texts(more)
    case _:
      Nil{}

def as.text.of(ts: List<&2, AsT>, +i: Nat) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case AsT{+n, +t} <> more:
      Bool.pick(List<&2, U32>, Nat.is_eq(n, i), t, as.text.of(more, i))

def as.read(+dir: String, ps: List<&2, Ea.EaP>, +ts: List<&2, AsT>) -> IO(List<&2, AsE>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, AsE>, Nil{})
    case Ea.EaP{+i, +r} <> more:
      do IO<List<&2, AsE>>:
        pm : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/prompt." ++ Nat.show(i))
        rest : List<&2, AsE> <- as.read(dir, more, ts)
        return as.one(i, r, as.text.of(ts, i), S.slurp.or(pm)) <> rest

def as.load(+dir: String) -> IO(List<&2, AsE>):
  do IO<List<&2, AsE>>:
    am : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/agent.nul")
    em : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/episodes.nul")
    as.read(dir, Ea.ea.prior(am), as.texts(Ev.ev.split(S.slurp.or(em), 0)))

# Counting --------------------------------------------------------------------

# an outcome: 0 solved, 1 solved after a tool answer
def as.is(+w: Nat, +x: AsE) -> Bool:
  Bool.pick(Bool, Nat.is_eq(w, 0n), AsE.solved(x), AsE.after(x))

def as.count(xs: List<&2, AsE>, +w: Nat) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> t:
      Nat.add(Bool.pick(Nat, as.is(w, x), 1n, 0n), as.count(t, w))

def as.sum(xs: List<&2, AsE>, +w: Nat) -> Nat:
  match xs:
    case Nil{}:
      0n
    case AsE{i, s, c, t, k, d} <> more:
      Nat.add(Bool.pick(Nat, Nat.is_eq(w, 0n), t, Bool.pick(Nat, Nat.is_eq(w, 1n), k, d)), as.sum(more, w))

def as.within(xs: List<&2, AsE>, +k: Nat) -> Nat:
  match xs:
    case Nil{}:
      0n
    case AsE{i, s, c, t, kk, d} <> more:
      Nat.add(Bool.pick(Nat, Bool.and(s, Nat.is_le(c, k)), 1n, 0n), as.within(more, k))

def as.report(+name: String, +xs: List<&2, AsE>) -> String:
  +n = Nat.show(List.length(&2, AsE, xs))
  name ++ ": " ++ n ++ " episodes; solved within 1, 2, 3, 4 calls: " ++ Nat.show(as.within(xs, 1n)) ++ ", " ++ Nat.show(as.within(xs, 2n))
    ++ ", " ++ Nat.show(as.within(xs, 3n)) ++ ", " ++ Nat.show(as.within(xs, 4n))
    ++ "; after a tool answer " ++ Nat.show(as.count(xs, 1n))
    ++ "\n  Terms after a failing echo: " ++ Nat.show(as.sum(xs, 0n)) ++ ", copies " ++ Nat.show(as.sum(xs, 1n))
    ++ ", drift " ++ Nat.show(as.sum(xs, 2n))

# McNemar ----------------------------------------------------------------------

# Σ_{i=0..m} C(n, i) / 2^n, the terms built up as t_{i+1} = t_i (n - i) / (i + 1)
def as.tail(m: Nat, +n: Nat, +i: Nat, +t: F32, +acc: F32) -> F32:
  match m:
    case 0n:
      F32.add(acc, t)
    case 1n+p:
      as.tail(p, n, 1n+i, F32.div(F32.mul(t, F32.from_nat(Nat.sub(n, i))), F32.from_nat(1n+i)), F32.add(acc, t))

def as.half.pow(n: Nat, +x: F32) -> F32:
  match n:
    case 0n:
      x
    case 1n+p:
      as.half.pow(p, F32.mul(x, 0.5))

# the exact two-sided McNemar p for b and c discordant pairs
def as.mcnemar(+b: Nat, +c: Nat) -> F32:
  +n = Nat.add(b, c)
  F32.min(1.0, F32.mul(2.0, as.tail(Nat.min(b, c), n, 0n, as.half.pow(n, 1.0), 0.0)))

def as.find(ys: List<&2, AsE>, +i: Nat) -> Maybe<&2, AsE>:
  match ys:
    case Nil{}:
      None{}
    case +y <> t:
      Bool.pick(Maybe<&2, AsE>, Nat.is_eq(AsE.i(y), i), Some{y}, as.find(t, i))

def as.disc.one(+o: Bool, m: Maybe<&2, AsE>, +w: Nat, +b: Nat, +c: Nat) -> Nat & Nat:
  match m:
    case Some{+y}:
      +p = as.is(w, y)
      (Nat.add(b, Bool.pick(Nat, Bool.and(o, Bool.not(p)), 1n, 0n)), Nat.add(c, Bool.pick(Nat, Bool.and(p, Bool.not(o)), 1n, 0n)))
    case None{}:
      (b, c)

def as.disc.pair(+o: Bool, m: Maybe<&2, AsE>, +w: Nat, bc: Nat & Nat) -> Nat & Nat:
  (b, c) = bc
  as.disc.one(o, m, w, b, c)

# the prompts where f holds in A only (b) and in B only (c)
def as.disc(xs: List<&2, AsE>, +ys: List<&2, AsE>, +w: Nat, bc: Nat & Nat) -> Nat & Nat:
  match xs:
    case Nil{}:
      bc
    case +x <> t:
      as.disc(t, ys, w, as.disc.pair(as.is(w, x), as.find(ys, AsE.i(x)), w, bc))

def as.paired.of(+what: String, bc: Nat & Nat) -> String:
  (+b, +c) = bc
  "  " ++ what ++ ": A only " ++ Nat.show(b) ++ ", B only " ++ Nat.show(c) ++ ", exact two-sided McNemar p = " ++ F32.show(as.mcnemar(b, c))

def as.paired(+what: String, +xs: List<&2, AsE>, +ys: List<&2, AsE>, +w: Nat) -> String:
  as.paired.of(what, as.disc(xs, ys, w, (0n, 0n)))

def as.two(+a: String, +b: String, +xs: List<&2, AsE>, +ys: List<&2, AsE>) -> String:
  String.join([as.report("A " ++ a, xs), as.report("B " ++ b, ys), "paired by prompt:",
    as.paired("solved", xs, ys, 0n), as.paired("solved after a tool answer", xs, ys, 1n)], "\n")

def as.stats(xs: List<String>) -> IO(Unit):
  match xs:
    case +a <> Nil{}:
      do IO<Unit>:
        es : List<&2, AsE> <- as.load(a)
        IO.print(as.report(a, es))
    case +a <> +b <> Nil{}:
      do IO<Unit>:
        es : List<&2, AsE> <- as.load(a)
        fs : List<&2, AsE> <- as.load(b)
        IO.print(as.two(a, b, es, fs))
    case _:
      IO.die(Unit, 2, "usage: agent-stats DIR [DIR2]")
