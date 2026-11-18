import Base
import ./Bulk.bend as B
import ./Config.bend as C
import ./Dense/Op.bend as P
import ./Dense/Layout.bend as L
import ./Dense/Step.bend as S
import ./Train.bend as Tr

# bend-perf: the census of one training step's programs (2026-11-18, the
# user: "Work on speed without renting, fix the slowest parts in bend").
# The step is a fixed list of ops (Dense/Step.bend), so its work is known
# before any GPU runs it: for every op, one tab-separated line
#   phase  i  kind  nout  nred  nin  nodes  exps  cells  extra  key  spec
# kind mm: nout = m·n·nb outputs, nred = k, flops 2·m·n·k·nb in extra,
# cells the floats A, B and C span (C twice when β ≠ 0); kind ein: nout
# outputs, nred reduced points each, nin inputs, the expression's nodes and
# exp/log/sqrt calls, cells the floats the views span (an input or index
# view's distinct cells, the output's once, twice when accumulating),
# extra the launches it takes, key the expression's encoding with its
# loop shape (ops sharing a key share a generated kernel), spec its encoding (an einsum's, BulkIo.bend's bk.einsum argument; none for a product).
#   bend-perf [PRESET] [MICRO] [CHUNK]   (fp100m 4 16: run 9's setting)

def prod.sel(ns: List<&2, U32>, +sel: U32, +want: U32) -> U32:
  match ns:
    case Nil{}:
      1
    case +n <> t:
      U32.mul(Bool.pick(U32, U32.is_eq(U32.and(sel, 1), want), n, 1), prod.sel(t, U32.shr(sel), want))

def nout(+ns: List<&2, U32>, +red: U32) -> U32:
  prod.sel(ns, red, 0)

def nred(+ns: List<&2, U32>, +red: U32) -> U32:
  prod.sel(ns, red, 1)

# the distinct cells a direct view spans: the product of the sizes it
# strides over (a stride of 0 reads one cell for every value of its index)
def span(ns: List<&2, U32>, st: List<&2, U32>) -> U32:
  match ns st:
    case +n <> nt s <> stt:
      U32.mul(Bool.pick(U32, U32.is_eq(s, 0), 1, n), span(nt, stt))
    case _ _:
      1

def View.cells(+ns: List<&2, U32>, v: B.View) -> U32:
  match v:
    case B.View{o, st, ix}:
      span(ns, st)

def ins.cells(+ns: List<&2, U32>, vs: List<&2, B.View>) -> U32:
  match vs:
    case Nil{}:
      0
    case v <> t:
      U32.add(View.cells(ns, v), ins.cells(ns, t))

def Ex.nodes(e: B.Ex) -> U32:
  match e:
    case B.EIn{k}:
      1
    case B.EIx{i}:
      1
    case B.EK{c}:
      1
    case B.E1{op, a}:
      U32.inc(Ex.nodes(a))
    case B.E2{op, a, b}:
      U32.inc(U32.add(Ex.nodes(a), Ex.nodes(b)))
    case B.ESel{c, a, b}:
      U32.inc(U32.add(Ex.nodes(c), U32.add(Ex.nodes(a), Ex.nodes(b))))

# exp, log and sqrt: the calls a term pays for on the special-function unit
def Ex.exps(e: B.Ex) -> U32:
  match e:
    case B.EIn{k}:
      0
    case B.EIx{i}:
      0
    case B.EK{c}:
      0
    case B.E1{+op, a}:
      U32.add(Bool.pick(U32, Bool.and(U32.is_le(1, op), U32.is_le(op, 3)), 1, 0), Ex.exps(a))
    case B.E2{op, a, b}:
      U32.add(Ex.exps(a), Ex.exps(b))
    case B.ESel{c, a, b}:
      U32.add(Ex.exps(c), U32.add(Ex.exps(a), Ex.exps(b)))

def tab(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      x
    case x <> t:
      x ++ "\t" ++ tab(t)

def acc.of(+a: U32) -> U32:
  Bool.pick(U32, U32.is_eq(a, 0), 1, 2)

def es.line(+ph: String, +i: Nat, +kind: String, +spec: String, es: B.Es) -> String:
  match es:
    case B.Es{+ns, +red, op2, +acc, +out, +ins, +ex}:
      +nex = Ex.nodes(ex)
      +nx = Ex.exps(ex)
      +nin = U32.from_nat(List.length(&2, B.View, ins))
      +cells = U32.add(ins.cells(ns, ins), U32.mul(acc.of(acc), View.cells(ns, out)))
      tab([ph, Nat.show(i), kind, U32.show(nout(ns, red)), U32.show(nred(ns, red)), U32.show(nin),
           U32.show(nex), U32.show(nx), U32.show(cells), "1",
           kind ++ B.Es.nums(ns) ++ " r" ++ U32.show(red) ++ " a" ++ U32.show(acc) ++ B.Ex.encode(ex), spec])

def line(+ph: String, +i: Nat, op: P.Op) -> String:
  match op:
    case P.Mm{+ta, +tb, +m, +n, +k, +nb, al, ao, lda, sa, bo, ldb, sb, +be, co, ldc, sc}:
      +cells = U32.mul(nb, U32.add(U32.add(U32.mul(m, k), U32.mul(k, n)),
        U32.mul(U32.mul(m, n), Bool.pick(U32, F32.is_eq(be, 0.0), 1, 2))))
      tab([ph, Nat.show(i), "mm", Nat.show(Nat.mul(Nat.mul(U32.to_nat(m), U32.to_nat(n)), U32.to_nat(nb))),
           U32.show(k), "2", "0", "0", Nat.show(U32.to_nat(cells)),
           Nat.show(Nat.mul(2n, Nat.mul(Nat.mul(U32.to_nat(m), U32.to_nat(n)), Nat.mul(U32.to_nat(k), U32.to_nat(nb))))),
           "mm " ++ U32.show(ta) ++ U32.show(tb) ++ " " ++ U32.show(m) ++ "x" ++ U32.show(n) ++ "x" ++ U32.show(k) ++ "x" ++ U32.show(nb)])
    case P.Ein{es, spec, g}:
      es.line(ph, i, "ein", spec, es)
    case P.Seq{es, k, rev, c, spec, sl, g}:
      es.line(ph, i, "seq", spec, es)

def lines(ops: List<&2, P.Op>, +ph: String, +i: Nat) -> IO(Unit):
  match ops:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case op <> t:
      do IO<Unit>:
        IO.print(line(ph, i, op))
        lines(t, ph, 1n+i)

def nat.of(+s: String, +d: Nat) -> Nat:
  Tr.nat.or(s, d)

def census(+c: C.Config, +mb: Nat, +cc: Nat) -> IO(Unit):
  +m = L.Dm.of.cc(c, mb, U32.from_nat(cc))
  +ly = L.Lay.of(c, m)
  +h = {S.Hy{0.9, 0.95, 1.0e-8, 0.01, 0.95} : S.Hy}
  +k = F32.div(1.0, F32.from_nat(Nat.max(mb, 1n)))
  do IO<Unit>:
    lines(S.zero.grads(ly), "zero", 0n)
    lines(S.fwd(m, ly), "fwd", 0n)
    lines(S.bwd(m, ly, k), "bwd", 0n)
    lines(S.update(True{}, ly, h, m, 1.0), "upd", 0n)

def census.args(xs: List<String>) -> IO(Unit):
  match xs:
    case _ <> mb <> cc <> _:
      census(C.Config.fp100m(), nat.of(mb, 4n), nat.of(cc, 16n))
    case _:
      census(C.Config.fp100m(), 4n, 16n)

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    census.args(xs)
