import Base
import ./Ex.bend as X

# The dense model's instructions and their meaning. A program is a list of
# ops over one store (an Array<F32> holding parameters, activations,
# gradients and optimizer state); each op's meaning is its base.bend
# primitive's: Array.mm (a matrix product) or Array.einsum (an expression
# summed over loop indices), each a function from the store to the store.
#
# Reverse mode is a transformation of programs (Elliott, "The simple
# essence of automatic differentiation"): every value at store index i has
# its tangent at i + tg, and each op's transpose accumulates into the
# tangents of what it read. A product's transpose is two products (the
# backward of compose is compose of the transposes); an einsum's is, per
# input, the einsum of the output tangent times the expression's derivative
# summed over the indices that input does not vary with; gather's
# transpose is scatter-add.

type Op is Data:
  Mm{ta: U32, tb: U32, m: U32, n: U32, k: U32, nb: U32, alpha: F32,
     ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32, beta: F32,
     co: U32, ldc: U32, sc: U32}
  Ein{es: Es, spec: String, grad: Bool}

# an einsum op, its encoding made once (every step reuses the string)
def ein(+es: Es, g: Bool) -> Op:
  Ein{es, Es.encode(es), g}

def view(off: U32, st: List<&2, U32>) -> View:
  View{off, st, IxNo{}}

def map1.ins(xs: List<&2, U32>) -> List<&2, View>:
  match xs:
    case Nil{}:
      Nil{}
    case o <> t:
      view(o, [1]) <> map1.ins(t)

# y[i] = e over n cells from `off` (a map, no reduction)
def map1(+n: U32, +out: U32, ins: List<&2, U32>, e: Ex, g: Bool) -> Op:
  ein(Es{[n], 0, 0, 0, view(out, [1]), map1.ins(ins), e}, g)

def zero(+n: U32, +off: U32) -> Op:
  map1(n, off, Nil{}, X.k(0.0), False{})

def fill(+n: U32, +off: U32, c: F32) -> Op:
  map1(n, off, Nil{}, X.k(c), False{})

# y = x W^T for x [rows × cols] and W [out × cols] (a linear layer: W's
# rows are its output channels)
def linear(+rows: U32, +cols: U32, +outs: U32, +x: U32, +ldx: U32, +w: U32,
  +y: U32, +ldy: U32) -> Op:
  Mm{0, 1, rows, outs, cols, 1, 1.0, x, ldx, 0, w, cols, 0, 0.0, y, ldy, 0}

# Running ------------------------------------------------------------------

def Op.run(op: Op, s: Array<F32>) -> Array<F32>:
  match op:
    case Mm{ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc}:
      Array.mm(ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s)
    case Ein{es, spec, g}:
      Array.einsum.prim(es, spec, s)

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

def Ix.st(+ix: Ix) -> List<&2, U32>:
  match ix:
    case IxNo{}:
      Nil{}
    case IxAt{o, st, m}:
      st

def View.free(+v: View) -> U32:
  match v:
    case View{o, st, ix}:
      free.bits(pad6(st), pad6(Ix.st(ix)), 1)

def View.shift(+tg: U32, v: View) -> View:
  match v:
    case View{o, st, ix}:
      View{U32.add(o, tg), st, ix}

# input j's transpose: its tangent += (output tangent) * d ex / d x_j,
# summed over the indices input j does not vary with
def Ein.back.one(+tg: U32, +ns: List<&2, U32>, +out: View, +ins: List<&2, View>,
  +nin: U32, +ex: Ex, +j: U32, +v: View, dz: Bool) -> List<&2, Op>:
  match dz:
    case True{}:
      Nil{}
    case False{}:
      [ein(Es{ns, View.free(v), 0, 1, View.shift(tg, v),
        List.append(&2, View, ins, [View.shift(tg, out)]),
        X.mul(X.x(nin), X.d(ex, j))}, True{})]

def Ein.back.go(vs: List<&2, View>, +tg: U32, +ns: List<&2, U32>, +out: View,
  +ins: List<&2, View>, +nin: U32, +ex: Ex, +j: U32) -> List<&2, Op>:
  match vs:
    case Nil{}:
      Nil{}
    case +v <> t:
      List.append(&2, Op, Ein.back.one(tg, ns, out, ins, nin, ex, j, v, X.is0(X.d(ex, j))),
        Ein.back.go(t, tg, ns, out, ins, nin, ex, U32.inc(j)))

def Ein.back(+tg: U32, es: Es, g: Bool) -> List<&2, Op>:
  match es g:
    case Es{ns, red, op, acc, out, +ins, ex} True{}:
      Ein.back.go(ins, tg, ns, out, ins, U32.from_nat(List.length(&2, View, ins)), ex, 0)
    case _ False{}:
      Nil{}

def Op.back(+tg: U32, op: Op) -> List<&2, Op>:
  match op:
    case Mm{+ta, +tb, +m, +n, +k, +nb, +al, +ao, +lda, +sa, +bo, +ldb, +sb, be, +co, +ldc, +sc}:
      [Mm.back.a(tg, ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, co, ldc, sc, U32.is_eq(ta, 0)),
       Mm.back.b(tg, ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, co, ldc, sc, U32.is_eq(tb, 0))]
    case Ein{es, spec, g}:
      Ein.back(tg, es, g)

# the program's transpose: the ops' transposes, last op first
def back(+tg: U32, ops: List<&2, Op>, acc: List<&2, Op>) -> List<&2, Op>:
  match ops:
    case Nil{}:
      acc
    case op <> t:
      back(tg, t, List.append(&2, Op, Op.back(tg, op), acc))
