import Base
import ../Sys.bend as S
import ./Combine.bend as C
import ./Eval.bend as Ev
import ./Agent.bend as Ea
import ../Agent/Spec.bend as A
import ../Agent/Episode.bend as E
import ./Lib.bend as L

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

# compare ------------------------------------------------------------------------
#
#   corpus-v2 compare A B
#
# Two runs of one evaluation paired by prompt, for the evaluations
# agent-stats does not read: E1 (A and B directories holding results.nul:
# id UNIT/SHAPE, joined to its check group's verdict in r.*.nul) and the
# behaviour test (directories holding verdicts.tsv, or the files
# themselves: TASK TAB VERDICT, `pass` passed). Prints each side's passes,
# the prompts both ran, among them A only and B only and the exact
# two-sided McNemar p.

type CmO is Data:
  CmO{k: String, pass: Bool}

# E1's verdicts: r.G.nul (a check group's results), ids UNIT~N (N: results.nul's
# first field), field 11 before 0x1F the decision (`0` passed), as report.txt
# reads them (Eval.bend `ev.verdicts`, `ev.pass.of`)
def cm.e1.key(+v: List<&2, U32>) -> List<&2, U32>:
  +fs = Ev.ev.split(v, 30)
  List.concat(&2, U32, [Ev.ev.nth(fs, 2n), S.b("~"), Ev.ev.nth(fs, 0n)])

def cm.e1.passed(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{v}:
      S.eq(L.v2.before(Ev.ev.nth(Ev.ev.split(v, 30), 11n), 31), [48])
    case None{}:
      False{}

def cm.e1.of(kvs: List<&2, Ev.EvKv>, +vs: List<&2, Ev.EvKv>) -> List<&2, CmO>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{k, v} <> t:
      CmO{S.str(k), cm.e1.passed(Ev.ev.kv.get(vs, cm.e1.key(v)))} <> cm.e1.of(t, vs)

def cm.read.one(n: List<&2, U32>, +p: String) -> IO(List<&2, Ev.EvKv>):
  match n:
    case Nil{}:
      IO.pure(List<&2, Ev.EvKv>, Nil{})
    case +c <> t:
      Ev.ev.nul(p ++ "/" ++ S.str(c <> t))

def cm.read.all(ns: List<&2, List<&2, U32>>, +p: String, acc: List<&2, Ev.EvKv>) -> IO(List<&2, Ev.EvKv>):
  match ns:
    case Nil{}:
      IO.pure(List<&2, Ev.EvKv>, acc)
    case n <> t:
      do IO<List<&2, Ev.EvKv>>:
        kvs : List<&2, Ev.EvKv> <- cm.read.one(n, p)
        cm.read.all(t, p, List.append(&2, Ev.EvKv, acc, kvs))

def cm.tsv.line(fs: List<&2, List<&2, U32>>) -> List<&2, CmO>:
  match fs:
    case +k <> +v <> _:
      [CmO{S.str(k), S.eq(v, S.b("pass"))}]
    case _:
      Nil{}

def cm.tsv.of(ls: List<&2, List<&2, U32>>) -> List<&2, CmO>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, CmO, cm.tsv.line(Ev.ev.split(l, 9)), cm.tsv.of(t))

def cm.load.tsv(+p: String) -> IO(List<&2, CmO>):
  do IO<List<&2, CmO>>:
    xs : List<&2, U32> <- S.read(p)
    return cm.tsv.of(S.split.lines(xs))

def cm.load.e1(+p: String) -> IO(List<&2, CmO>):
  do IO<List<&2, CmO>>:
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(p ++ "/results.nul")
    o : S.Out <- S.run(".", [], 60, "sh", ["-c", "cd \"$0\" && ls r.*.nul", p], Nil{})
    vs : List<&2, Ev.EvKv> <- cm.read.all(S.split.lines(S.Out.text(o)), p, Nil{})
    return cm.e1.of(kvs, vs)

def cm.load.pick(e1: Bool, beh: Bool, +p: String) -> IO(List<&2, CmO>):
  match e1 beh:
    case True{} _:
      cm.load.e1(p)
    case False{} True{}:
      cm.load.tsv(p ++ "/verdicts.tsv")
    case False{} False{}:
      cm.load.tsv(p)

def cm.load(+p: String) -> IO(List<&2, CmO>):
  do IO<List<&2, CmO>>:
    e1 : Bool <- S.exists(p ++ "/results.nul")
    beh : Bool <- S.exists(p ++ "/verdicts.tsv")
    cm.load.pick(e1, beh, p)

def cm.keys(os: List<&2, CmO>, s: Set()) -> Set():
  match os:
    case Nil{}:
      s
    case CmO{k, o} <> t:
      cm.keys(t, Set.add(s, k))

def cm.pass.add(o: Bool, k: String, s: Set()) -> Set():
  match o:
    case True{}:
      Set.add(s, k)
    case False{}:
      s

def cm.passes(os: List<&2, CmO>, s: Set()) -> Set():
  match os:
    case Nil{}:
      s
    case CmO{k, o} <> t:
      cm.passes(t, cm.pass.add(o, k, s))

def cm.count(os: List<&2, CmO>) -> Nat:
  match os:
    case Nil{}:
      0n
    case CmO{k, o} <> t:
      Nat.add(Bool.pick(Nat, o, 1n, 0n), cm.count(t))

def cm.b(+x: Bool) -> Nat:
  Bool.pick(Nat, x, 1n, 0n)

# the paired counts: both ran, both passed, A only, B only
type CmP is Data:
  CmP{n: Nat, both: Nat, a: Nat, b: Nat}

def cm.pair.one(+ran: Bool, +o: Bool, +p: Bool, c: CmP) -> CmP:
  match c:
    case CmP{n, both, a, b}:
      CmP{Nat.add(n, cm.b(ran)), Nat.add(both, cm.b(Bool.and(ran, Bool.and(o, p)))),
        Nat.add(a, cm.b(Bool.and(ran, Bool.and(o, Bool.not(p))))), Nat.add(b, cm.b(Bool.and(ran, Bool.and(p, Bool.not(o)))))}

# the pairing's state: B's prompts, B's passes, the counts
type CmS is Type:
  CmS{ks: Set(), ps: Set(), c: CmP}

# Set.has hands the set back with its answer
def cm.step.passed(+ran: Bool, +o: Bool, ks: Set(), r: Set() & Bool, c: CmP) -> CmS:
  (ps, p) = r
  CmS{ks, ps, cm.pair.one(ran, o, p, c)}

def cm.step.ran(+k: String, +o: Bool, r: Set() & Bool, ps: Set(), c: CmP) -> CmS:
  (ks, ran) = r
  cm.step.passed(ran, o, ks, Set.has(ps, k), c)

def cm.pair(os: List<&2, CmO>, st: CmS) -> CmP:
  match os st:
    case Nil{} CmS{ks, ps, c}:
      c
    case CmO{+k, +o} <> t CmS{ks, ps, c}:
      cm.pair(t, cm.step.ran(k, o, Set.has(ks, k), ps, c))

def cm.show(+a: String, +b: String, +xs: List<&2, CmO>, +ys: List<&2, CmO>, c: CmP) -> String:
  match c:
    case CmP{n, both, +x, +y}:
      String.join(["A " ++ a ++ ": " ++ Nat.show(cm.count(xs)) ++ "/" ++ Nat.show(List.length(&2, CmO, xs)) ++ " passed",
        "B " ++ b ++ ": " ++ Nat.show(cm.count(ys)) ++ "/" ++ Nat.show(List.length(&2, CmO, ys)) ++ " passed",
        "paired by prompt: " ++ Nat.show(n) ++ " in both, both passed " ++ Nat.show(both) ++ ", A only " ++ Nat.show(x)
          ++ ", B only " ++ Nat.show(y) ++ ", exact two-sided McNemar p = " ++ F32.show(as.mcnemar(x, y))], "\n")

def cm.compare(xs: List<String>) -> IO(Unit):
  match xs:
    case +a <> +b <> Nil{}:
      do IO<Unit>:
        +os : List<&2, CmO> <- cm.load(a)
        +ps : List<&2, CmO> <- cm.load(b)
        IO.print(cm.show(a, b, os, ps, cm.pair(os, CmS{cm.keys(ps, Set.new()), cm.passes(ps, Set.new()), CmP{0n, 0n, 0n, 0n}})))
    case _:
      IO.die(Unit, 2, "usage: compare A B (E1 directories, behaviour directories or verdicts.tsv files)")
