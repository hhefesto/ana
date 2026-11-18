import Base
import ../Bulk.bend as B
import ./Ex.bend as X

# The dense model's instructions and their meaning. A program is a list of
# ops over one store (an Array<F32> holding parameters, activations,
# gradients and optimizer state); each op's meaning is its Bulk.bend
# definition's: mm (a matrix product) or einsum (an expression summed over
# loop indices), each a function from the store to the store. Run.bend runs
# a program fast, each op as its BulkIo.bend effect.
#
# Reverse mode is a transformation of programs (Elliott, "The simple
# essence of automatic differentiation"): every value at store index i has
# its tangent at i + tg, and each op's transpose accumulates into the
# tangents of what it read. A product's transpose is two products (the
# backward of compose is compose of the transposes); an einsum's is, per
# input, the einsum of the output tangent times the expression's derivative
# summed over the indices that input does not vary with; gather's
# transpose is scatter-add.

#
# Seq (2026-11-18) is an einsum run slice by slice along its index k: the
# einsum at k = 0, then at k = 1, ... (rev: from the last), each slice an
# einsum of its own, reading the store the slices before it wrote. So a
# linear recurrence s_{i+1} = f(s_i, ...) is one op: GLA's state across
# chunks (Model.bend), which was 127 einsums a layer at ctx 2048. Its
# meaning is its slices (Seq.slices) run in order; Run.bend runs it as one
# GPU kernel when no slice reads another lane's cells. `carry` is the input
# that reads what earlier slices wrote: its transpose runs as a Seq the
# other way (the adjoint recurrence), the others' as plain einsums over
# every slice at once, after it.
type Op is Data:
  Mm{ta: U32, tb: U32, m: U32, n: U32, k: U32, nb: U32, alpha: F32,
     ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32, beta: F32,
     co: U32, ldc: U32, sc: U32}
  Ein{es: B.Es, spec: String, grad: Bool}
  Seq{es: B.Es, k: U32, rev: U32, carry: U32, spec: String, slices: List<&2, Op>, grad: Bool}

# an einsum op, its encoding made once (every step reuses the string)
def ein(+es: B.Es, g: Bool) -> Op:
  Ein{es, B.Es.encode(es), g}

def view(off: U32, st: List<&2, U32>) -> B.View:
  B.View{off, st, B.IxNo{}}

def map1.ins(xs: List<&2, U32>) -> List<&2, B.View>:
  match xs:
    case Nil{}:
      Nil{}
    case o <> t:
      view(o, [1]) <> map1.ins(t)

# y[i] = e over n cells from `off` (a map, no reduction)
def map1(+n: U32, +out: U32, ins: List<&2, U32>, e: B.Ex, g: Bool) -> Op:
  ein(B.Es{[n], 0, 0, 0, view(out, [1]), map1.ins(ins), e}, g)

def zero(+n: U32, +off: U32) -> Op:
  map1(n, off, Nil{}, X.k(0.0), False{})

def fill(+n: U32, +off: U32, c: F32) -> Op:
  map1(n, off, Nil{}, X.k(c), False{})

# y = x W^T for x [rows × cols] and W [out × cols] (a linear layer: W's
# rows are its output channels)
def linear(+rows: U32, +cols: U32, +outs: U32, +x: U32, +ldx: U32, +w: U32,
  +y: U32, +ldy: U32) -> Op:
  Mm{0, 1, rows, outs, cols, 1, 1.0, x, ldx, 0, w, cols, 0, 0.0, y, ldy, 0}

# Slices -------------------------------------------------------------------

# xs[k], 0 past the end (a view's strides may be shorter than its loop)
def nth0(xs: List<&2, U32>, +k: Nat) -> U32:
  match xs k:
    case Nil{} _:
      0
    case x <> t 0n:
      x
    case x <> t 1n+p:
      nth0(t, p)

# xs with xs[k] set to v (xs padded with 1s up to k: a loop's sizes)
def set1(xs: List<&2, U32>, +k: Nat, +v: U32) -> List<&2, U32>:
  match xs k:
    case Nil{} 0n:
      [v]
    case Nil{} 1n+p:
      1 <> set1(Nil{}, p, v)
    case x <> t 0n:
      v <> t
    case x <> t 1n+p:
      x <> set1(t, p, v)

def Ix.slice(+k: Nat, +i: U32, ix: B.Ix) -> B.Ix:
  match ix:
    case B.IxNo{}:
      B.IxNo{}
    case B.IxAt{o, +st, m}:
      B.IxAt{U32.add(o, U32.mul(i, nth0(st, k))), st, m}

# a view at slice i of index k: index k fixed at i, the rest as it was
def View.slice(+k: Nat, +i: U32, v: B.View) -> B.View:
  match v:
    case B.View{o, +st, ix}:
      B.View{U32.add(o, U32.mul(i, nth0(st, k))), st, Ix.slice(k, i, ix)}

def Views.slice(+k: Nat, +i: U32, vs: List<&2, B.View>) -> List<&2, B.View>:
  match vs:
    case Nil{}:
      Nil{}
    case v <> t:
      View.slice(k, i, v) <> Views.slice(k, i, t)

# the einsum at slice i of index k: k's size 1, every view moved to i
def Es.slice(+k: Nat, +i: U32, es: B.Es) -> B.Es:
  match es:
    case B.Es{ns, red, op, acc, out, ins, ex}:
      B.Es{set1(ns, k, 1), red, op, acc, View.slice(k, i, out), Views.slice(k, i, ins), ex}

# n slices from i on, i+1 next (rev: i-1 next)
def Seq.go(n: Nat, +es: B.Es, +k: Nat, +rev: Bool, +i: U32) -> List<&2, Op>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      ein(Es.slice(k, i, es), False{}) <> Seq.go(p, es, k, rev, Bool.pick(U32, rev, U32.sub(i, 1), U32.inc(i)))

def Es.size(+k: Nat, +es: B.Es) -> U32:
  match es:
    case B.Es{ns, red, op, acc, out, ins, ex}:
      nth0(ns, k)

# the slices of es along k, in the order they run
def Seq.slices(+es: B.Es, +k: U32, +rev: U32) -> List<&2, Op>:
  +kn = U32.to_nat(k)
  +n = Es.size(kn, es)
  +r = U32.is_eq(rev, 1)
  Seq.go(U32.to_nat(n), es, kn, r, Bool.pick(U32, r, U32.sub(n, 1), 0))

# a sequential einsum along k (rev 1: from the last slice); carry is the
# input that reads what earlier slices wrote (see Seq above)
def seq(+es: B.Es, +k: U32, +rev: U32, +carry: U32, g: Bool) -> Op:
  Seq{es, k, rev, carry, B.Es.encode(es), Seq.slices(es, k, rev), g}

# Running ------------------------------------------------------------------

# a product or an einsum (a Seq's slices are einsums, so a Seq runs them
# here: Op.run calls no run of its own list)
def Op.flat(op: Op, s: Array<F32>) -> Array<F32>:
  match op:
    case Mm{ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc}:
      B.mm(ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s)
    case Ein{es, spec, g}:
      B.einsum.prim(es, spec, s)
    case Seq{es, k, rev, c, spec, sl, g}:
      s

def run.flat(ops: List<&2, Op>, s: Array<F32>) -> Array<F32>:
  match ops:
    case Nil{}:
      s
    case op <> t:
      run.flat(t, Op.flat(op, s))

def Op.run(op: Op, s: Array<F32>) -> Array<F32>:
  match op:
    case Mm{ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc}:
      B.mm(ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s)
    case Ein{es, spec, g}:
      B.einsum.prim(es, spec, s)
    case Seq{es, k, rev, c, spec, sl, g}:
      run.flat(Seq.slices(es, k, rev), s)

def run(ops: List<&2, Op>, s: Array<F32>) -> Array<F32>:
  match ops:
    case Nil{}:
      s
    case op <> t:
      run(t, Op.run(op, s))

# Transposes ---------------------------------------------------------------

def not(+t: U32) -> U32:
  U32.sub(1, t)

# C = alpha op(A) op(B) (beta 0): dA and dB accumulate (beta 1) from dC
def Mm.back.a(+tg: U32, +ta: U32, +tb: U32, +m: U32, +n: U32, +k: U32,
  +nb: U32, +al: F32, +ao: U32, +lda: U32, +sa: U32, +bo: U32, +ldb: U32,
  +sb: U32, +co: U32, +ldc: U32, +sc: U32, z: Bool) -> Op:
  match z:
    case True{}:
      Mm{0, not(tb), m, k, n, nb, al, U32.add(co, tg), ldc, sc, bo, ldb, sb, 1.0, U32.add(ao, tg), lda, sa}
    case False{}:
      Mm{tb, 1, k, m, n, nb, al, bo, ldb, sb, U32.add(co, tg), ldc, sc, 1.0, U32.add(ao, tg), lda, sa}

def Mm.back.b(+tg: U32, +ta: U32, +tb: U32, +m: U32, +n: U32, +k: U32,
  +nb: U32, +al: F32, +ao: U32, +lda: U32, +sa: U32, +bo: U32, +ldb: U32,
  +sb: U32, +co: U32, +ldc: U32, +sc: U32, z: Bool) -> Op:
  match z:
    case True{}:
      Mm{not(ta), 0, k, n, m, nb, al, ao, lda, sa, U32.add(co, tg), ldc, sc, 1.0, U32.add(bo, tg), ldb, sb}
    case False{}:
      Mm{1, ta, n, k, m, nb, al, U32.add(co, tg), ldc, sc, ao, lda, sa, 1.0, U32.add(bo, tg), ldb, sb}

# the loop indices a view does not vary with (a stride of 0, directly and
# through its index view): its tangent sums over them
def free.bits(st: List<&2, U32>, xs: List<&2, U32>, +bit: U32) -> U32:
  match st xs:
    case s <> st2 i <> xs2:
      U32.add(Bool.pick(U32, Bool.and(U32.is_eq(s, 0), U32.is_eq(i, 0)), bit, 0),
        free.bits(st2, xs2, U32.mul(bit, 2)))
    case _ _:
      0

def pad6(xs: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, List.append(&2, U32, xs, [0, 0, 0, 0, 0, 0]), 6n)

def Ix.st(+ix: B.Ix) -> List<&2, U32>:
  match ix:
    case B.IxNo{}:
      Nil{}
    case B.IxAt{o, st, m}:
      st

def View.free(+v: B.View) -> U32:
  match v:
    case B.View{o, st, ix}:
      free.bits(pad6(st), pad6(Ix.st(ix)), 1)

def View.shift(+tg: U32, v: B.View) -> B.View:
  match v:
    case B.View{o, st, ix}:
      B.View{U32.add(o, tg), st, ix}

# input j's transpose: its tangent += (output tangent) * d ex / d x_j,
# summed over the indices input j does not vary with
def Ein.back.es(+tg: U32, +ns: List<&2, U32>, +out: B.View, +ins: List<&2, B.View>,
  +nin: U32, +ex: B.Ex, +j: U32, +v: B.View) -> B.Es:
  B.Es{ns, View.free(v), 0, 1, View.shift(tg, v),
    List.append(&2, B.View, ins, [View.shift(tg, out)]),
    X.mul(X.x(nin), X.d(ex, j))}

def Ein.back.one(+tg: U32, +ns: List<&2, U32>, +out: B.View, +ins: List<&2, B.View>,
  +nin: U32, +ex: B.Ex, +j: U32, +v: B.View, dz: Bool) -> List<&2, Op>:
  match dz:
    case True{}:
      Nil{}
    case False{}:
      [ein(Ein.back.es(tg, ns, out, ins, nin, ex, j, v), True{})]

# A Seq's transposes: the carried input's first, as a Seq along the same
# index the other way (the adjoint recurrence: slice i's tangent takes
# slice i+1's, final by then), then every other input's, each a plain
# einsum over all the slices at once (they only read: each of their
# tangent cells gets the same terms, slice by slice or at once; checked
# bit for bit against the slices' own transposes by tests/seq.bend)
# vs[k] (a view of nothing past the end)
def nthv(vs: List<&2, B.View>, +k: Nat) -> B.View:
  match vs k:
    case Nil{} _:
      B.View{0, Nil{}, B.IxNo{}}
    case v <> t 0n:
      v
    case v <> t 1n+p:
      nthv(t, p)

def Seq.back.carry(+tg: U32, +ns: List<&2, U32>, +out: B.View, +ins: List<&2, B.View>,
  +nin: U32, +ex: B.Ex, +k: U32, +rev: U32, +c: U32) -> List<&2, Op>:
  [seq(Ein.back.es(tg, ns, out, ins, nin, ex, c, nthv(ins, U32.to_nat(c))), k, not(rev), nin, True{})]

def Seq.back.rest(vs: List<&2, B.View>, +tg: U32, +ns: List<&2, U32>, +out: B.View, +ins: List<&2, B.View>,
  +nin: U32, +ex: B.Ex, +c: U32, +j: U32) -> List<&2, Op>:
  match vs:
    case Nil{}:
      Nil{}
    case +v <> t:
      List.append(&2, Op,
        Ein.back.one(tg, ns, out, ins, nin, ex, j, v, Bool.or(U32.is_eq(j, c), X.is0(X.d(ex, j)))),
        Seq.back.rest(t, tg, ns, out, ins, nin, ex, c, U32.inc(j)))

def Seq.back(+tg: U32, es: B.Es, +k: U32, +rev: U32, +c: U32, g: Bool) -> List<&2, Op>:
  match es g:
    case B.Es{+ns, red, op, acc, +out, +ins, +ex} True{}:
      +nin = U32.from_nat(List.length(&2, B.View, ins))
      List.append(&2, Op, Seq.back.carry(tg, ns, out, ins, nin, ex, k, rev, c),
        Seq.back.rest(ins, tg, ns, out, ins, nin, ex, c, 0))
    case _ False{}:
      Nil{}

def Ein.back.go(vs: List<&2, B.View>, +tg: U32, +ns: List<&2, U32>, +out: B.View,
  +ins: List<&2, B.View>, +nin: U32, +ex: B.Ex, +j: U32) -> List<&2, Op>:
  match vs:
    case Nil{}:
      Nil{}
    case +v <> t:
      List.append(&2, Op, Ein.back.one(tg, ns, out, ins, nin, ex, j, v, X.is0(X.d(ex, j))),
        Ein.back.go(t, tg, ns, out, ins, nin, ex, U32.inc(j)))

def Ein.back(+tg: U32, es: B.Es, g: Bool) -> List<&2, Op>:
  match es g:
    case B.Es{ns, red, op, acc, out, +ins, ex} True{}:
      Ein.back.go(ins, tg, ns, out, ins, U32.from_nat(List.length(&2, B.View, ins)), ex, 0)
    case _ False{}:
      Nil{}

def Op.back(+tg: U32, op: Op) -> List<&2, Op>:
  match op:
    case Mm{+ta, +tb, +m, +n, +k, +nb, +al, +ao, +lda, +sa, +bo, +ldb, +sb, be, +co, +ldc, +sc}:
      [Mm.back.a(tg, ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, co, ldc, sc, U32.is_eq(ta, 0)),
       Mm.back.b(tg, ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, co, ldc, sc, U32.is_eq(tb, 0))]
    case Ein{es, spec, g}:
      Ein.back(tg, es, g)
    case Seq{es, +k, +rev, +c, spec, sl, g}:
      Seq.back(tg, es, k, rev, c, g)

# the program's transpose: the ops' transposes, last op first
def back(+tg: U32, ops: List<&2, Op>, acc: List<&2, Op>) -> List<&2, Op>:
  match ops:
    case Nil{}:
      acc
    case op <> t:
      back(tg, t, List.append(&2, Op, Op.back(tg, op), acc))
