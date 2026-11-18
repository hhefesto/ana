import Base
import ../Bulk.bend as B
import ../BulkIo.bend as BI
import ./Op.bend as P
import ../Spec/Derivative.bend as Dv

# Forward mode on dual numbers: the gradient gate's reference (Elliott's
# dual-numbers item, 2026-11-17).
#
# The dense trainer's gradient is reverse mode, a transformation of the
# program (Op.bend's `back`): per einsum the derivative X.d, summed over the
# indices an input does not vary with; per product two products; gathers
# transposed into scatter-adds; the whole run backwards.  This file runs the
# same forward program a second way: every cell of the store is a dual
# number, its value at i and its tangent at i + tg (the cell where reverse
# mode keeps its adjoint), and each op maps dual numbers to dual numbers:
#
#   an einsum, by Bulk.bend's einsum.ref with each point's expression
#   evaluated by Spec/Derivative.bend's `dual` over F32 (the same
#   definition the proof is about, here over a carrier that is not
#   lawful: 0·∞ is NaN), sums and maxes of dual numbers for the reduction;
#
#   a product, by (A + A'ε)(B + B'ε) = AB + (A'B + AB')ε: two more products
#   into the tangents, before the value's own.
#
# Seeding the parameters' tangents with a direction v and running the
# forward gives the loss and its exact derivative along v, ∇L·v, with no
# step size; tests/dualgrad.bend compares that with the trainer's gradient
# dotted with v.  Nothing here uses X.d, `back`, or the tree trainer: the
# reference is the forward's meaning.  A NaN or ∞ in a tangent is carried,
# not hidden.
#
# The einsums are Bend loops (einsum.ref's), slow but plain; the products
# run as the trainer's do (BulkIo.bend's effect, tested against Bulk.bend's
# mm by tests/bulk-cpu.bend).

def f32.ops() -> Dv.Ops<F32>:
  Dv.Ops{0.0, 1.0, c => c, u => U32.to_f32(u),
         x => F32.neg(x), x => F32.exp(x), x => F32.log(x), x => F32.sqrt(x), x => F32.abs(x),
         x => y => F32.add(x, y), x => y => F32.sub(x, y), x => y => F32.mul(x, y), x => y => F32.div(x, y),
         x => y => F32.is_lt(x, y), x => y => F32.is_le(x, y), x => F32.is_ne(x, 0.0)}

def DF.v(+d: Dv.Dual<F32>) -> F32:
  Dv.D.v(F32, d)

def DF.t(+d: Dv.Dual<F32>) -> F32:
  Dv.D.t(F32, d)

# an expression at one point, on dual numbers: the inputs' values and
# tangents, in order
def ex(e: B.Ex, +vs: List<&2, F32>, +ts: List<&2, F32>, +pt: List<&2, U32>) -> Dv.Dual<F32>:
  Dv.dual(~F32, ~f32.ops(), e, vs, Dv.SeedTs{ts}, pt)

# Einsum ---------------------------------------------------------------------
#
# Bulk.bend's einsum.ref, step for step, on (value, tangent) pairs: inputs
# and index views read the store as it was before the op (an index view
# reads values: an index carries no tangent), the reduction is a sum (op 0)
# or a max (Ex.max: the larger value, with its tangent; on a tie the one
# already held), and the output's value goes to its cell, its tangent to the
# cell tg on.

type Vt is Data:
  Vt{vs: List<&2, F32>, ts: List<&2, F32>}

def Vt.cons(+x: F32, +t: F32, acc: Vt) -> Vt:
  match acc:
    case Vt{vs, ts}:
      Vt{x <> vs, t <> ts}

def get2.fin(+tg: U32, +a: U32, +x: F32, acc: Vt, r: Array<F32> & F32) -> Array<F32> & Vt:
  (s, +t) = r
  (s, Vt.cons(x, t, acc))

def get2.mid(+tg: U32, +a: U32, acc: Vt, r: Array<F32> & F32) -> Array<F32> & Vt:
  (s, +x) = r
  get2.fin(tg, a, x, acc, Array.get(F32, s, U32.add(a, tg)))

def get2.v(+tg: U32, acc: Vt, r: Array<F32> & U32) -> Array<F32> & Vt:
  (s, +a) = r
  get2.mid(tg, a, acc, Array.get(F32, s, a))

def vals.step(+tg: U32, v: B.View, +pt: List<&2, U32>, acc: Array<F32> & Vt) -> Array<F32> & Vt:
  (s, xs) = acc
  get2.v(tg, xs, B.View.at(v, pt, s))

# the inputs' values and tangents at pt, newest first
def vals(vs: List<&2, B.View>, +tg: U32, +pt: List<&2, U32>, acc: Array<F32> & Vt) -> Array<F32> & Vt:
  match vs:
    case Nil{}:
      acc
    case v <> t:
      vals(t, tg, pt, vals.step(tg, v, pt, acc))

def comb(+op: U32, +r: Dv.Dual<F32>, +d: Dv.Dual<F32>) -> Dv.Dual<F32>:
  Bool.pick(Dv.Dual<F32>, U32.is_eq(op, 0), Dv.Dual{F32.add(DF.v(r), DF.v(d)), F32.add(DF.t(r), DF.t(d))},
    Bool.pick(Dv.Dual<F32>, F32.is_gt(DF.v(d), DF.v(r)), d, r))

def term.fin(+ex0: B.Ex, +pt: List<&2, U32>, +op: U32, +r: Dv.Dual<F32>, +vt: Vt) -> Dv.Dual<F32>:
  match vt:
    case Vt{vs, ts}:
      comb(op, r, ex(ex0, List.reverse(&2, F32, vs), List.reverse(&2, F32, ts), pt))

def term(+ex0: B.Ex, +pt: List<&2, U32>, +op: U32, +r: Dv.Dual<F32>, sv: Array<F32> & Vt) -> Array<F32> & Dv.Dual<F32>:
  (s, +vt) = sv
  (s, term.fin(ex0, pt, op, r, vt))

def red.one(+tg: U32, +pt: List<&2, U32>, +op: U32, +ins: List<&2, B.View>, +ex0: B.Ex, t: Array<F32> & Dv.Dual<F32>) -> Array<F32> & Dv.Dual<F32>:
  (s, +r) = t
  term(ex0, pt, op, r, vals(ins, tg, pt, (s, Vt{Nil{}, Nil{}})))

def red(qs: List<&2, List<&2, U32>>, +tg: U32, +p: List<&2, U32>, +op: U32, +ins: List<&2, B.View>, +ex0: B.Ex, t: Array<F32> & Dv.Dual<F32>) -> Array<F32> & Dv.Dual<F32>:
  match qs:
    case Nil{}:
      t
    case q <> rest:
      red(rest, tg, p, op, ins, ex0, red.one(tg, B.Es.add(p, q), op, ins, ex0, t))

def put.one(+acc: U32, +a: U32, +x: F32, c: Array<F32> & F32) -> Array<F32>:
  (cur, old) = c
  Array.set(F32, cur, a, Bool.pick(F32, U32.is_eq(acc, 0), x, F32.add(old, x)))

def put(+acc: U32, +tg: U32, cur: Array<F32>, +r: Dv.Dual<F32>, oa: Array<F32> & U32) -> Array<F32> & Array<F32>:
  (old, +a) = oa
  c1 = put.one(acc, a, DF.v(r), Array.get(F32, cur, a))
  (old, put.one(acc, U32.add(a, tg), DF.t(r), Array.get(F32, c1, U32.add(a, tg))))

def write(+acc: U32, +tg: U32, +out: B.View, +p: List<&2, U32>, cur: Array<F32>, t: Array<F32> & Dv.Dual<F32>) -> Array<F32> & Array<F32>:
  (old, +r) = t
  put(acc, tg, cur, r, B.View.at(out, p, old))

def outer.one(+tg: U32, +p: List<&2, U32>, +qs: List<&2, List<&2, U32>>, +op: U32, +acc: U32, +out: B.View, +ins: List<&2, B.View>, +ex0: B.Ex,
  oc: Array<F32> & Array<F32>) -> Array<F32> & Array<F32>:
  (old, cur) = oc
  write(acc, tg, out, p, cur, red(qs, tg, p, op, ins, ex0, (old, Dv.Dual{B.Es.init(op), 0.0})))

def outer(ps: List<&2, List<&2, U32>>, +tg: U32, +qs: List<&2, List<&2, U32>>, +op: U32, +acc: U32, +out: B.View, +ins: List<&2, B.View>, +ex0: B.Ex,
  oc: Array<F32> & Array<F32>) -> Array<F32> & Array<F32>:
  match ps:
    case Nil{}:
      oc
    case +p <> rest:
      outer(rest, tg, qs, op, acc, out, ins, ex0, outer.one(tg, p, qs, op, acc, out, ins, ex0, oc))

def fin(oc: Array<F32> & Array<F32>) -> Array<F32>:
  (old, cur) = oc
  cur

# an einsum on dual numbers (tangents tg cells on)
def einsum(es: B.Es, +tg: U32, x: Array<F32>) -> Array<F32>:
  match es:
    case B.Es{+ns, +red0, op, acc, out, ins, ex0}:
      fin(outer(B.Es.pts(ns, U32.xor(red0, 63)), tg, B.Es.pts(ns, red0), op, acc, out, ins, ex0, Array.clone(F32, x)))

# Product ----------------------------------------------------------------------

# C = al·op(A)op(B) + be·C on dual numbers: C' = al·(op(A')op(B) +
# op(A)op(B')) + be·C', then C itself (the tangents read the old values)
def mm(+tg: U32, +ta: U32, +tb: U32, +m: U32, +n: U32, +k: U32, +nb: U32, +al: F32,
  +ao: U32, +lda: U32, +sa: U32, +bo: U32, +ldb: U32, +sb: U32, +be: F32, +co: U32, +ldc: U32, +sc: U32, s: Array<F32>) -> IO(Array<F32>):
  do IO<Array<F32>>:
    s1 : Array<F32> <- BI.bk.mm(ta, tb, m, n, k, nb, al, U32.add(ao, tg), lda, sa, bo, ldb, sb, be, U32.add(co, tg), ldc, sc, s)
    s2 : Array<F32> <- BI.bk.mm(ta, tb, m, n, k, nb, al, ao, lda, sa, U32.add(bo, tg), ldb, sb, 1.0, U32.add(co, tg), ldc, sc, s1)
    BI.bk.mm(ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s2)

# Programs ---------------------------------------------------------------------

# a Seq's slices (einsums, P.Seq.slices) in order, on dual numbers
def seq.one(op: P.Op, +tg: U32, s: Array<F32>) -> Array<F32>:
  match op:
    case P.Ein{es, spec, g}:
      einsum(es, tg, s)
    case _:
      s

def seq.slices(ops: List<&2, P.Op>, +tg: U32, s: Array<F32>) -> Array<F32>:
  match ops:
    case Nil{}:
      s
    case op <> t:
      seq.slices(t, tg, seq.one(op, tg, s))


def Op.run(+tg: U32, op: P.Op, s: Array<F32>) -> IO(Array<F32>):
  match op:
    case P.Mm{ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc}:
      mm(tg, ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s)
    case P.Ein{es, spec, g}:
      IO.pure(Array<F32>, einsum(es, tg, s))
    case P.Seq{es, k, rev, c, spec, sl, g}:
      IO.pure(Array<F32>, seq.slices(P.Seq.slices(es, k, rev), tg, s))

# a program on dual numbers: every cell i's tangent at i + tg
def run(ops: List<&2, P.Op>, +tg: U32, s: Array<F32>) -> IO(Array<F32>):
  match ops:
    case Nil{}:
      IO.pure(Array<F32>, s)
    case op <> t:
      IO.bind(Array<F32>, Array<F32>, Op.run(tg, op, s), (x: Array<F32>) => run(t, tg, x))
