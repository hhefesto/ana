import Base
import ../Config.bend as C
import ../Train/Init.bend as I
import ../Train/Ckpt.bend as K
import ../Dense/Layout.bend as L
import ../Dense/Op.bend as P
import ../Dense/Run.bend as R
import ../Dense/Step.bend as S
import ../Dense/Io.bend as Io
import ../Dense/Dual.bend as D

# The dual-number gradient gate (Elliott's dual-numbers item, 2026-11-17).
#
# The dense trainer's gradient (reverse mode, Dense/Op.bend's `back`, the
# program the GPU runs) against the forward run on dual numbers
# (Dense/Dual.bend, whose einsums evaluate Spec/Derivative.bend's `dual`):
# for a direction v over the parameters, the dual run's loss tangent is
# ∇L·v exactly (up to F32 rounding, with no step size), and it must equal
# the trainer's gradient dotted with v.  The directions are random signs
# (±1), one over every parameter and one over each group: the embedding,
# each block, the final norm.  The windows and config are tests/dense.bend's
# (small4-v3: 3 GLA blocks with RG-LRU gates, a softmax block with qk-norm
# and sinks; two windows of 63 predictions).
#
# Unlike tests/train.bend's finite differences (eps 0.01 in F32, three or
# four digits, sixteen entries) this sees every parameter at once and
# resolves the derivative to F32's rounding, and unlike tests/dense.bend
# it leans on neither the tree trainer nor X.d.  A tangent that is NaN or
# ∞ fails.  A mutant (the gradient's group scaled by 1.01) must fail too,
# or the tolerance is too loose to mean anything.

def rnd.next(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

# tests/dense.bend's windows: n+1 byte tokens (2..257) from a seed
def window(n: Nat, +s: U32) -> List<&2, U32>:
  match n:
    case 0n:
      [0]
    case 1n+p:
      U32.add(2, U32.and(U32.shrn(s, 16n), 255)) <> window(p, rnd.next(s))

# a direction: ±1 on [lo, hi), 0 elsewhere, over n parameters
def dir(n: Nat, +i: U32, +lo: U32, +hi: U32, +s: U32) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +inside = Bool.and(U32.is_le(lo, i), U32.is_lt(i, hi))
      +sign = Bool.pick(F32, U32.is_eq(U32.and(U32.shrn(s, 20n), 1), 0), 1.0, F32.neg(1.0))
      Bool.pick(F32, inside, sign, 0.0) <> dir(p, U32.inc(i), lo, hi, rnd.next(s))

type Dot is Data:
  Dot{dot: F32, scale: F32}

# Σ g·v and Σ |g·v|; f scales g on [lo, hi) (1 but for the mutant)
def dot(gs: List<&2, F32>, vs: List<&2, F32>, +i: U32, +lo: U32, +hi: U32, +f: F32, +acc: Dot) -> Dot:
  match gs vs acc:
    case +g <> gt +v <> vt Dot{d, sc}:
      +gi = Bool.pick(F32, Bool.and(U32.is_le(lo, i), U32.is_lt(i, hi)), F32.mul(f, g), g)
      +x = F32.mul(gi, v)
      dot(gt, vt, U32.inc(i), lo, hi, f, Dot{F32.add(d, x), F32.add(sc, F32.abs(x))})
    case _ _ _:
      acc

# within F32's rounding: |jvp - g·v| <= 1e-3 |g·v| + 1e-5 Σ|g·v|, and finite
def close(+jvp: F32, +e: Dot) -> Bool:
  match e:
    case Dot{d, sc}:
      +err = F32.abs(F32.sub(jvp, d))
      Bool.and(F32.is_eq(err, err), F32.is_le(err, F32.add(F32.mul(1.0e-3, F32.abs(d)), F32.mul(1.0e-5, sc))))

def rel(+jvp: F32, +e: Dot) -> F32:
  match e:
    case Dot{d, sc}:
      F32.div(F32.abs(F32.sub(jvp, d)), F32.max(F32.abs(d), 1.0e-30))

def Dot.d(+e: Dot) -> F32:
  match e:
    case Dot{d, sc}:
      d

type Group is Data:
  Group{name: String, lo: U32, hi: U32, seed: U32}

def next.ra(+bs: List<&2, L.BP>, +fin: U32) -> U32:
  match bs:
    case Nil{}:
      fin
    case b <> t:
      L.BP.ra(b)

def groups.blocks(bs: List<&2, L.BP>, +fin: U32, +j: Nat) -> List<&2, Group>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> +t:
      +hi = next.ra(t, fin)
      Group{"block " ++ Nat.show(j), L.BP.ra(b), hi, U32.add(101, U32.from_nat(j))} <> groups.blocks(t, fin, 1n+j)

def groups(+ly: L.Lay, +m: L.Dm) -> List<&2, Group>:
  +e = U32.mul(L.Dm.v(m), L.Dm.d(m))
  Group{"every parameter", 0, L.Lay.params(ly), 7} <>
  (Group{"embedding", 0, e, 11} <>
   List.append(&2, Group, groups.blocks(L.Lay.blocks(ly), L.Lay.fin(ly), 0n),
     [Group{"final norm", L.Lay.fin(ly), L.Lay.params(ly), 13}]))

# the base store: the parameters and the windows (tests/dense.bend's)
def store(+ly: L.Lay, +m: L.Dm, +w: List<&2, F32>, +ws: List<&2, List<&2, U32>>) -> Array<F32>:
  Io.put.windows(ws, Io.put(w, Array.new(F32, L.Lay.depth(ly), 0.0), 0),
    L.Lay.tin(ly), L.Lay.ttg(ly), L.Lay.tw(ly), L.Dm.t(m))

def snd(r: Array<F32> & List<&2, F32>) -> List<&2, F32>:
  (s, xs) = r
  xs

# the trainer's gradient: its forward, then its backward (seed 1: the mean
# loss's gradient), the parameters' tangents read
def grad(+ly: L.Lay, +m: L.Dm, s: Array<F32>) -> IO(List<&2, F32>):
  do IO<List<&2, F32>>:
    s1 : Array<F32> <- R.run(S.fwd(m, ly), s)
    s2 : Array<F32> <- R.run(List.append(&2, P.Op, S.zero.grads(ly), S.bwd(m, ly, 1.0)), s1)
    return snd(Io.get(U32.to_nat(L.Lay.params(ly)), s2, L.Lay.g(ly)))

# the loss and its tangent along v, on dual numbers
type LT is Data:
  LossT{l: F32, t: F32}

def LT.l(+r: LT) -> F32:
  match r:
    case LossT{l, t}:
      l

def LT.t(+r: LT) -> F32:
  match r:
    case LossT{l, t}:
      t

def read.fin(+l: F32, r: Array<F32> & F32) -> LT:
  (s, t) = r
  LossT{l, t}

def read(+a: U32, +tg: U32, r: Array<F32> & F32) -> LT:
  (s, +l) = r
  read.fin(l, Array.get(F32, s, U32.add(a, tg)))

def jvp(+ly: L.Lay, +m: L.Dm, s: Array<F32>, +v: List<&2, F32>) -> IO(LT):
  +tg = L.Lay.g(ly)
  do IO<LT>:
    s1 : Array<F32> <- D.run(S.fwd(m, ly), tg, Io.put(v, s, tg))
    return read(L.Lay.lmean(ly), tg, Array.get(F32, s1, L.Lay.lmean(ly)))

def line(+ok: Bool, +name: String, +l: F32, +j: F32, +e: Dot) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name ++ ": loss " ++ F32.show(l) ++ ", dual ∇L·v " ++ F32.show(j)
    ++ ", trainer g·v " ++ F32.show(Dot.d(e)) ++ " (relative " ++ F32.show(rel(j, e)) ++ ")"

# one direction: the dual run, the comparison and the mutant, printed; the
# number of failures (0, 1 or 2)
def one.fin(+name: String, +lo: U32, +hi: U32, +v: List<&2, F32>, +gs: List<&2, F32>, +r: LT) -> IO(Nat):
  +l = LT.l(r)
  +j = LT.t(r)
  +e = dot(gs, v, 0, lo, hi, 1.0, Dot{0.0, 0.0})
  +mut = dot(gs, v, 0, lo, hi, 1.01, Dot{0.0, 0.0})
  +ok = close(j, e)
  +caught = Bool.not(close(j, mut))
  do IO<Nat>:
    IO.print(line(ok, name, l, j, e))
    IO.print(Bool.pick(String, caught, "  ok the mutant (this group's gradient times 1.01) fails: relative ", "  FAIL the mutant passes: relative ") ++ F32.show(rel(j, mut)))
    return Nat.add(Bool.pick(Nat, ok, 0n, 1n), Bool.pick(Nat, caught, 0n, 1n))

def one(+name: String, +lo: U32, +hi: U32, +v: List<&2, F32>, +ly: L.Lay, +m: L.Dm, s: Array<F32>, +gs: List<&2, F32>) -> IO(Nat):
  IO.bind(LT, Nat, jvp(ly, m, s, v), (r: LT) => one.fin(name, lo, hi, v, gs, r))

# each group's direction in turn, on a copy of the base store
def checks(gs0: List<&2, Group>, +ly: L.Lay, +m: L.Dm, bb: Array<F32> & Array<F32>, +gs: List<&2, F32>, +bad: Nat) -> IO(Nat):
  match gs0:
    case Nil{}:
      IO.pure(Nat, bad)
    case Group{+name, +lo, +hi, +seed} <> rest:
      (b1, b2) = bb
      IO.bind(Nat, Nat, one(name, lo, hi, dir(U32.to_nat(L.Lay.params(ly)), 0, lo, hi, seed), ly, m, b1, gs),
        (k: Nat) => checks(rest, ly, m, Array.clone(F32, b2), gs, Nat.add(bad, k)))


# what Spec/Derivative.bend's proof takes as hypotheses, checked here
def literals() -> Bool:
  Bool.and(F32.is_eq(0.0, 0.0), Bool.and(Bool.not(F32.is_eq(1.0, 0.0)), F32.is_eq(1.0, 1.0)))

def verdict.if(ok: Bool, +bad: Nat, +n: Nat) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("ok the trainer's gradient is the dual numbers' along " ++ Nat.show(n) ++ " directions, and every mutant fails")
    case False{}:
      IO.die(Unit, 1, "dualgrad: " ++ Nat.show(bad) ++ " failure(s) over " ++ Nat.show(n) ++ " directions (each checked against the trainer and its mutant)"
        ++ Bool.pick(String, literals(), "", "; the F32 literal facts Spec/Derivative.bend assumes do not hold"))

def verdict(+bad: Nat, +n: Nat) -> IO(Unit):
  verdict.if(Bool.and(Nat.is_eq(bad, 0n), literals()), bad, n)

def main() -> IO(Unit):
  +c = C.Config.small4_v3()
  +w = K.Weights.flat(I.init(c))
  +ws = {[window(63n, 7), window(63n, 12345)] : List<&2, List<&2, U32>>}
  +m = L.Dm.of.cc(c, 2n, 16)
  +ly = L.Lay.of(c, m)
  +gs0 = groups(ly, m)
  do IO<Unit>:
    gs : List<&2, F32> <- grad(ly, m, store(ly, m, w, ws))
    IO.print("parameters " ++ U32.show(L.Lay.params(ly)) ++ ", directions " ++ Nat.show(List.length(&2, Group, gs0)))
    bad : Nat <- checks(gs0, ly, m, Array.clone(F32, store(ly, m, w, ws)), gs, 0n)
    verdict(bad, List.length(&2, Group, gs0))
