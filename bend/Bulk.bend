import Base

# The bulk F32 ops over one store, as definitions: a matrix product (gemm,
# mm) and an einsum. They were the Bend fork's additions to Base
# (hhefesto/bend2's base.bend) until 2026-10-22, when ana moved to upstream
# Bend; the fast code is now ana's own, BulkIo.bend's effects
# (bend/effs/bulk.c), which give every output the very F32 steps these
# definitions take (tests/bulk-cpu.bend compares the bits). Pure code (the
# specs, the small tests) runs these definitions; the trainers and the
# decoders run the effects.

# gemm
# ----

# A matrix inside an F32 array: ArrayView{t, o, ld, s} denotes the batch of
# matrices (b, r, c) -> x[o + b·s + r·ld + c], transposed (r and c swapped)
# when t is not 0. ArrayView.at is that meaning, as an index.
type ArrayView is Data:
  ArrayView{t: U32, o: U32, ld: U32, s: U32}

def ArrayView.at.if(z: Bool, +o: U32, +ld: U32, r: U32, c: U32) -> U32:
  match z:
    case True{}:
      U32.add(o, U32.add(U32.mul(r, ld), c))
    case False{}:
      U32.add(o, U32.add(U32.mul(c, ld), r))

def ArrayView.at(v: ArrayView, b: U32, r: U32, c: U32) -> U32:
  match v:
    case ArrayView{t, o, ld, s}:
      ArrayView.at.if(U32.is_eq(t, 0), U32.add(o, U32.mul(b, s)), ld, r, c)

def gemm.mac(
  ra: Array<F32> & F32, rb: Array<F32> & F32, acc: F32
) -> Array<F32> & Array<F32> & F32:
  (a, x) = ra
  (b, y) = rb
  (a, b, F32.add(acc, F32.mul(x, y)))

def gemm.step(
  t: Array<F32> & Array<F32> & F32, ia: U32, ib: U32
) -> Array<F32> & Array<F32> & F32:
  (a, b, acc) = t
  gemm.mac(Array.get(F32, a, ia), Array.get(F32, b, ib), acc)

# Σ_{q < k} op(A)(i, q) · op(B)(q, j), summed in order of q
def gemm.dot(
  p: Nat, +q: U32, t: Array<F32> & Array<F32> & F32, +va: ArrayView,
  +vb: ArrayView, +bi: U32, +i: U32, +j: U32
) -> Array<F32> & Array<F32> & F32:
  match p:
    case 0n:
      t
    case 1n+r:
      gemm.dot(r, U32.inc(q), gemm.step(t,
        ArrayView.at(va, bi, i, q), ArrayView.at(vb, bi, q, j)),
        va, vb, bi, i, j)

# β = 0 ignores the old C, which may then hold anything (as in BLAS)
def gemm.blend(z: Bool, s: F32, beta: F32, old: F32) -> F32:
  match z:
    case True{}:
      s
    case False{}:
      F32.add(s, F32.mul(beta, old))

def gemm.put(
  r: Array<F32> & F32, +ci: U32, s: F32, +beta: F32
) -> Array<F32>:
  (c, old) = r
  Array.set(F32, c, ci, gemm.blend(F32.is_eq(beta, 0.0), s, beta, old))

def gemm.cell(
  c: Array<F32>, d: Array<F32> & Array<F32> & F32, +ci: U32, alpha: F32,
  beta: F32
) -> Array<F32> & Array<F32> & Array<F32>:
  (a, b, s) = d
  (gemm.put(Array.get(F32, c, ci), ci, F32.mul(alpha, s), beta), a, b)

def gemm.one(
  t: Array<F32> & Array<F32> & Array<F32>, k: Nat, va: ArrayView,
  vb: ArrayView, bi: U32, i: U32, j: U32, ci: U32, alpha: F32, beta: F32
) -> Array<F32> & Array<F32> & Array<F32>:
  (c, a, b) = t
  gemm.cell(c, gemm.dot(k, 0, (a, b, 0.0), va, vb, bi, i, j),
    ci, alpha, beta)

def gemm.row(
  n: Nat, +j: U32, t: Array<F32> & Array<F32> & Array<F32>, +k: Nat,
  +va: ArrayView, +vb: ArrayView, +vc: ArrayView, +bi: U32, +i: U32,
  +alpha: F32, +beta: F32
) -> Array<F32> & Array<F32> & Array<F32>:
  match n:
    case 0n:
      t
    case 1n+r:
      gemm.row(r, U32.inc(j), gemm.one(t, k, va, vb, bi, i, j,
        ArrayView.at(vc, bi, i, j), alpha, beta),
        k, va, vb, vc, bi, i, alpha, beta)

def gemm.rows(
  m: Nat, +i: U32, t: Array<F32> & Array<F32> & Array<F32>, +n: Nat,
  +k: Nat, +va: ArrayView, +vb: ArrayView, +vc: ArrayView, +bi: U32,
  +alpha: F32, +beta: F32
) -> Array<F32> & Array<F32> & Array<F32>:
  match m:
    case 0n:
      t
    case 1n+r:
      gemm.rows(r, U32.inc(i),
        gemm.row(n, 0, t, k, va, vb, vc, bi, i, alpha, beta),
        n, k, va, vb, vc, bi, alpha, beta)

def gemm.batch(
  nb: Nat, +bi: U32, t: Array<F32> & Array<F32> & Array<F32>, +m: Nat,
  +n: Nat, +k: Nat, +va: ArrayView, +vb: ArrayView, +vc: ArrayView,
  +alpha: F32, +beta: F32
) -> Array<F32> & Array<F32> & Array<F32>:
  match nb:
    case 0n:
      t
    case 1n+r:
      gemm.batch(r, U32.inc(bi),
        gemm.rows(m, 0, t, n, k, va, vb, vc, bi, alpha, beta),
        m, n, k, va, vb, vc, alpha, beta)

# C ← α·op(A)·op(B) + β·C for each of `batch` matrices, op(A) m×k, op(B)
# k×n, C m×n, each read through its view (transpose flag, offset, leading
# dimension, batch stride; C is never transposed). Every C entry is its own
# dot product, so the order of the outer loops does not matter. Returns
# (C, A, B). This definition is the meaning; BulkIo.mm runs it fast (a C
# kernel, or cuBLAS on a GPU), checked against it.
def gemm(
  ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32, alpha: F32,
  a: Array<F32>, ao: U32, lda: U32, sa: U32,
  b: Array<F32>, bo: U32, ldb: U32, sb: U32,
  beta: F32, c: Array<F32>, co: U32, ldc: U32, sc: U32
) -> Array<F32> & Array<F32> & Array<F32>:
  gemm.batch(U32.to_nat(batch), 0, (c, a, b), U32.to_nat(m),
    U32.to_nat(n), U32.to_nat(k), ArrayView{ta, ao, lda, sa},
    ArrayView{tb, bo, ldb, sb}, ArrayView{0, co, ldc, sc}, alpha, beta)

# einsum
# ------

# Ex: a scalar expression at one point of an einsum's loop: EIn k is input
# k's value there, EIx i the loop index i (as F32), EK a constant. Unary
# ops: 0 neg, 1 exp, 2 log, 3 sqrt, 4 abs. Binary: 0 add, 1 sub, 2 mul,
# 3 div, 4 max (a > b ? a : b), 5 min (a < b ? a : b), 6 lt, 7 le (1 or 0).
# ESel c a b is a where c is not 0, else b.
type Ex is Data:
  EIn{k: U32}
  EIx{i: U32}
  EK{c: F32}
  E1{op: U32, a: Ex}
  E2{op: U32, a: Ex, b: Ex}
  ESel{c: Ex, a: Ex, b: Ex}

def Ex.max(+a: F32, +b: F32) -> F32:
  Bool.pick(F32, F32.is_gt(a, b), a, b)

def Ex.min(+a: F32, +b: F32) -> F32:
  Bool.pick(F32, F32.is_lt(a, b), a, b)

def Ex.bit(z: Bool) -> F32:
  Bool.pick(F32, z, 1.0, 0.0)

def Ex.un(+op: U32, +x: F32) -> F32:
  Bool.pick(F32, U32.is_eq(op, 0), F32.neg(x),
  Bool.pick(F32, U32.is_eq(op, 1), F32.exp(x),
  Bool.pick(F32, U32.is_eq(op, 2), F32.log(x),
  Bool.pick(F32, U32.is_eq(op, 3), F32.sqrt(x), F32.abs(x)))))

def Ex.bin(+op: U32, +a: F32, +b: F32) -> F32:
  Bool.pick(F32, U32.is_eq(op, 0), F32.add(a, b),
  Bool.pick(F32, U32.is_eq(op, 1), F32.sub(a, b),
  Bool.pick(F32, U32.is_eq(op, 2), F32.mul(a, b),
  Bool.pick(F32, U32.is_eq(op, 3), F32.div(a, b),
  Bool.pick(F32, U32.is_eq(op, 4), Ex.max(a, b),
  Bool.pick(F32, U32.is_eq(op, 5), Ex.min(a, b),
  Bool.pick(F32, U32.is_eq(op, 6), Ex.bit(F32.is_lt(a, b)),
    Ex.bit(F32.is_le(a, b)))))))))

def Ex.nth(xs: List<&2, F32>, +i: U32) -> F32:
  match xs:
    case Nil{}:
      0.0
    case +x <> t:
      Bool.pick(F32, U32.is_eq(i, 0), x, Ex.nth(t, U32.sub(i, 1)))

def Ex.nthu(xs: List<&2, U32>, +i: U32) -> U32:
  match xs:
    case Nil{}:
      0
    case +x <> t:
      Bool.pick(U32, U32.is_eq(i, 0), x, Ex.nthu(t, U32.sub(i, 1)))

# the meaning of an expression, given the inputs' values and the point
def Ex.eval(e: Ex, +vs: List<&2, F32>, +pt: List<&2, U32>) -> F32:
  match e:
    case EIn{k}:
      Ex.nth(vs, k)
    case EIx{i}:
      U32.to_f32(Ex.nthu(pt, i))
    case EK{c}:
      c
    case E1{op, a}:
      Ex.un(op, Ex.eval(a, vs, pt))
    case E2{op, a, b}:
      Ex.bin(op, Ex.eval(a, vs, pt), Ex.eval(b, vs, pt))
    case ESel{c, a, b}:
      Bool.pick(F32, F32.is_ne(Ex.eval(c, vs, pt), 0.0), Ex.eval(a, vs, pt),
        Ex.eval(b, vs, pt))

# A view: the array index off + Σ st_i·p_i at the loop point p, plus, when
# indirect, mul times the index stored (as F32) at its own view's place.
# Indices wrap into the array, as Array.get's do.
type Ix is Data:
  IxNo{}
  IxAt{off: U32, st: List<&2, U32>, mul: U32}

type View is Data:
  View{off: U32, st: List<&2, U32>, ix: Ix}

def View.dot(st: List<&2, U32>, pt: List<&2, U32>) -> U32:
  match st pt:
    case s <> st2 p <> pt2:
      U32.add(U32.mul(s, p), View.dot(st2, pt2))
    case _ _:
      0

def View.at.fin(+a: U32, +mul: U32, r: Array<F32> & F32) -> Array<F32> & U32:
  (s, x) = r
  (s, U32.add(a, U32.mul(mul, F32.to_u32(x))))

def View.at.ix(ix: Ix, +pt: List<&2, U32>, +a: U32, s: Array<F32>) ->
  Array<F32> & U32:
  match ix:
    case IxNo{}:
      (s, a)
    case IxAt{off, st, mul}:
      View.at.fin(a, mul, Array.get(F32, s, U32.add(off, View.dot(st, pt))))

def View.at(v: View, +pt: List<&2, U32>, s: Array<F32>) -> Array<F32> & U32:
  match v:
    case View{off, st, ix}:
      View.at.ix(ix, pt, U32.add(off, View.dot(st, pt)), s)

# An einsum: over the loop points p < ns (up to six indices), the output
# at p (the reduced indices, bits of red, at 0) becomes the reduction (op
# 0 sum, 1 max) of ex over the reduced points, plus the output's value when
# acc is not 0. Inputs and index views read the array as it was before the
# op; points and reduced points go in lexicographic order.
type Es is Data:
  Es{ns: List<&2, U32>, red: U32, op: U32, acc: U32, out: View,
     ins: List<&2, View>, ex: Ex}

def Es.upto(n: Nat, +i: U32) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      i <> Es.upto(p, U32.inc(i))

def Es.cons(+v: U32, ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> t:
      (v <> p) <> Es.cons(v, t)

def Es.cross(vs: List<&2, U32>, +rest: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  match vs:
    case Nil{}:
      Nil{}
    case v <> t:
      List.append(&2, List<&2, U32>, Es.cons(v, rest), Es.cross(t, rest))

# the points over the indices whose bit of sel is set, the others at 0
def Es.pts(ns: List<&2, U32>, +sel: U32) -> List<&2, List<&2, U32>>:
  match ns:
    case Nil{}:
      [Nil{}]
    case +n <> t:
      Es.cross(Es.upto(U32.to_nat(Bool.pick(U32, U32.is_eq(U32.and(sel, 1), 1), n, 1)), 0),
        Es.pts(t, U32.shr(sel)))

def Es.add(p: List<&2, U32>, q: List<&2, U32>) -> List<&2, U32>:
  match p q:
    case a <> pt b <> qt:
      U32.add(a, b) <> Es.add(pt, qt)
    case _ _:
      Nil{}

def Es.vals.c(xs: List<&2, F32>, r: Array<F32> & F32) ->
  Array<F32> & List<&2, F32>:
  (s, x) = r
  (s, x <> xs)

def Es.vals.b(xs: List<&2, F32>, r: Array<F32> & U32) ->
  Array<F32> & List<&2, F32>:
  (s, a) = r
  Es.vals.c(xs, Array.get(F32, s, a))

def Es.vals.step(v: View, +pt: List<&2, U32>, acc: Array<F32> & List<&2, F32>)
  -> Array<F32> & List<&2, F32>:
  (s, xs) = acc
  Es.vals.b(xs, View.at(v, pt, s))

# the inputs' values at pt, newest first
def Es.vals(vs: List<&2, View>, +pt: List<&2, U32>,
  acc: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, F32>:
  match vs:
    case Nil{}:
      acc
    case v <> t:
      Es.vals(t, pt, Es.vals.step(v, pt, acc))

def Es.comb(+op: U32, +r: F32, +v: F32) -> F32:
  Bool.pick(F32, U32.is_eq(op, 0), F32.add(r, v), Ex.max(v, r))

def Es.term(+ex: Ex, +pt: List<&2, U32>, +op: U32, +r: F32,
  sv: Array<F32> & List<&2, F32>) -> Array<F32> & F32:
  (s, xs) = sv
  (s, Es.comb(op, r, Ex.eval(ex, List.reverse(&2, F32, xs), pt)))

def Es.red.one(+pt: List<&2, U32>, +op: U32, +ins: List<&2, View>, +ex: Ex,
  t: Array<F32> & F32) -> Array<F32> & F32:
  (s, r) = t
  Es.term(ex, pt, op, r, Es.vals(ins, pt, (s, Nil{})))

def Es.red(qs: List<&2, List<&2, U32>>, +p: List<&2, U32>, +op: U32,
  +ins: List<&2, View>, +ex: Ex, t: Array<F32> & F32) -> Array<F32> & F32:
  match qs:
    case Nil{}:
      t
    case q <> rest:
      Es.red(rest, p, op, ins, ex, Es.red.one(Es.add(p, q), op, ins, ex, t))

def Es.put.fin(+acc: U32, +a: U32, +r: F32, c: Array<F32> & F32) ->
  Array<F32>:
  (cur, old) = c
  Array.set(F32, cur, a, Bool.pick(F32, U32.is_eq(acc, 0), r, F32.add(old, r)))

def Es.put(+acc: U32, cur: Array<F32>, +r: F32, oa: Array<F32> & U32) ->
  Array<F32> & Array<F32>:
  (old, +a) = oa
  (old, Es.put.fin(acc, a, r, Array.get(F32, cur, a)))

def Es.write(+acc: U32, +out: View, +p: List<&2, U32>, cur: Array<F32>,
  t: Array<F32> & F32) -> Array<F32> & Array<F32>:
  (old, r) = t
  Es.put(acc, cur, r, View.at(out, p, old))

def Es.init(+op: U32) -> F32:
  Bool.pick(F32, U32.is_eq(op, 0), 0.0, F32.neg(F32.div(1.0, 0.0)))

def Es.outer.one(+p: List<&2, U32>, +qs: List<&2, List<&2, U32>>, +op: U32,
  +acc: U32, +out: View, +ins: List<&2, View>, +ex: Ex,
  oc: Array<F32> & Array<F32>) -> Array<F32> & Array<F32>:
  (old, cur) = oc
  Es.write(acc, out, p, cur, Es.red(qs, p, op, ins, ex, (old, Es.init(op))))

def Es.outer(ps: List<&2, List<&2, U32>>, +qs: List<&2, List<&2, U32>>,
  +op: U32, +acc: U32, +out: View, +ins: List<&2, View>, +ex: Ex,
  oc: Array<F32> & Array<F32>) -> Array<F32> & Array<F32>:
  match ps:
    case Nil{}:
      oc
    case +p <> rest:
      Es.outer(rest, qs, op, acc, out, ins, ex, Es.outer.one(p, qs, op, acc,
        out, ins, ex, oc))

def Es.fin(oc: Array<F32> & Array<F32>) -> Array<F32>:
  (old, cur) = oc
  cur

# the meaning of an einsum
def einsum.ref(es: Es, x: Array<F32>) -> Array<F32>:
  match es:
    case Es{+ns, +red, op, acc, out, ins, ex}:
      Es.fin(Es.outer(Es.pts(ns, U32.xor(red, 63)), Es.pts(ns, red), op, acc,
        out, ins, ex, Array.clone(F32, x)))

# Es.encode: the spec as the runtime reads it, space-separated: "E", six
# sizes, red, op, acc, the output view, the input count, the input views,
# then ex in prefix (iK input, pI index, kBITS constant, uOP a, bOP a b,
# s c a b). A view is off, six strides, then 0, or 1 and its index view's
# off, six strides and mul.
def Es.pad(n: Nat, xs: List<&2, U32>, +z: U32) -> List<&2, U32>:
  match n xs:
    case 0n _:
      Nil{}
    case 1n+p x <> t:
      x <> Es.pad(p, t, z)
    case 1n+p Nil{}:
      z <> Es.pad(p, Nil{}, z)

def Es.nums(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      " " ++ U32.show(x) ++ Es.nums(t)

def Ix.encode(ix: Ix) -> String:
  match ix:
    case IxNo{}:
      " 0"
    case IxAt{off, st, mul}:
      " 1 " ++ U32.show(off) ++ Es.nums(Es.pad(6n, st, 0)) ++ " "
        ++ U32.show(mul)

def View.encode(v: View) -> String:
  match v:
    case View{off, st, ix}:
      " " ++ U32.show(off) ++ Es.nums(Es.pad(6n, st, 0)) ++ Ix.encode(ix)

def Es.views(vs: List<&2, View>) -> String:
  match vs:
    case Nil{}:
      ""
    case v <> t:
      View.encode(v) ++ Es.views(t)

def Ex.encode(e: Ex) -> String:
  match e:
    case EIn{k}:
      " i" ++ U32.show(k)
    case EIx{i}:
      " p" ++ U32.show(i)
    case EK{c}:
      " k" ++ U32.show(F32.bits(c))
    case E1{op, a}:
      " u" ++ U32.show(op) ++ Ex.encode(a)
    case E2{op, a, b}:
      " b" ++ U32.show(op) ++ Ex.encode(a) ++ Ex.encode(b)
    case ESel{c, a, b}:
      " s" ++ Ex.encode(c) ++ Ex.encode(a) ++ Ex.encode(b)

def Es.encode(es: Es) -> String:
  match es:
    case Es{ns, red, op, acc, out, +ins, ex}:
      "E" ++ Es.nums(Es.pad(6n, ns, 1)) ++ Es.nums([red, op, acc])
        ++ View.encode(out) ++ " "
        ++ Nat.show(List.length(&2, View, ins)) ++ Es.views(ins)
        ++ Ex.encode(ex)

# The op: its meaning is einsum.ref; BulkIo.einsum runs the encoded spec
# (the loop in the same order, or a generated CUDA kernel).
def einsum.prim(es: Es, spec: String, x: Array<F32>) -> Array<F32>:
  einsum.ref(es, x)

def einsum(+es: Es, x: Array<F32>) -> Array<F32>:
  einsum.prim(es, Es.encode(es), x)

# mm: gemm with A, B and C in one array (read as it was before
# the op): C's rectangle must not overlap A's or B's.
def mm.fin(r: Array<F32> & Array<F32> & Array<F32>) -> Array<F32>:
  (c, a, b) = r
  c

def mm.two(
  ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32, alpha: F32,
  ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32,
  beta: F32, co: U32, ldc: U32, sc: U32, a: Array<F32>,
  bc: Array<F32> & Array<F32>
) -> Array<F32>:
  (b, c) = bc
  mm.fin(gemm(ta, tb, m, n, k, batch, alpha, a, ao, lda, sa, b,
    bo, ldb, sb, beta, c, co, ldc, sc))

def mm.one(
  ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32, alpha: F32,
  ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32,
  beta: F32, co: U32, ldc: U32, sc: U32, ax: Array<F32> & Array<F32>
) -> Array<F32>:
  (a, x) = ax
  mm.two(ta, tb, m, n, k, batch, alpha, ao, lda, sa, bo, ldb, sb,
    beta, co, ldc, sc, a, Array.clone(F32, x))

def mm(
  ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32, alpha: F32,
  ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32,
  beta: F32, co: U32, ldc: U32, sc: U32, x: Array<F32>
) -> Array<F32>:
  mm.one(ta, tb, m, n, k, batch, alpha, ao, lda, sa, bo, ldb, sb, beta,
    co, ldc, sc, Array.clone(F32, x))

