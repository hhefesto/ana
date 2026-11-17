import Base
import ../Bulk.bend as B
import ../Dense/Ex.bend as X
import ./Nat.bend as NL

# Dense/Ex.bend's derivative is right: the third of Elliott's open items
# (the user, 2026-11-17: "Implement the three Elliott items").
#
# Every backward step the dense trainer runs on the GPU is built from X.d:
# an einsum's transpose (Dense/Op.bend) multiplies the output's tangent by
# d(ex, j).  Until now only d.const and d.index were proven
# (Spec/Dense.bend); the rest was tested, at the points tests/dense.bend
# reaches.
#
# The meaning is dual numbers.  Over any carrier R with the operations
# Bulk.bend's Ex names (Ops) and the laws X's simplifier relies on (Laws),
# `eval` is Ex.eval and `dual` evaluates an expression on dual numbers
# v + t·ε, each primitive by its rule f(x + dx·ε) = f(x) + f'(x)·dx·ε.
# Those rules are the analytic facts this file assumes, as Trusted.bend's
# are: exp' = exp, log' = 1/x, sqrt' = 1/(2·sqrt x), x·y and x/y by the
# product and quotient rules, and abs, max, min and select differentiated
# on the side the forward pass takes (lt and le are flat).  `d_right`:
#
#   for every expression e and input j,
#   eval(d(e, j)) = the tangent of dual(e) seeded at input j
#
# by induction over e: every op, the select, the constants and indices,
# and the 0/1 folding of X's constructors.  An op added to Ex must extend it.
#
# What the proof makes explicit: the folding uses 0 + x = x, x + 0 = x,
# x - 0 = x, 0 - x = -x, -0 = 0, 0·x = 0, x·0 = 0, 1·x = x, x·1 = x,
# 0/x = 0 and x/1 = x (Laws).  F32 breaks 0·x = 0 and 0/x = 0 at x = ±∞ or NaN (and
# 0/0): there the folded derivative is 0 where the unfolded one is NaN, the
# corner the NaN bugs lived in.  Bend cannot compute F32 comparisons in a
# proof, so three facts about literals (0.0 = 0.0, 1.0 ≠ 0.0, 1.0 = 1.0)
# are hypotheses; tests/dualgrad.bend checks them when it runs.  To prove
# is1 (Ex.bend) never calls a 0 one, it now also asks "not 0" (no change
# in F32).
#
# Not covered: F32 rounding and the GPU's code (cuBLAS, the generated
# kernels).  The dual-number gradient gate (Dense/Dual.bend,
# tests/dualgrad.bend) checks the assembled program numerically, with this
# file's `dual` run over F32.
#
# `bend --check-only` and Everything.bend check these templates generically
# (R, O and L abstract) and at the Nat and Bool instances at the end; a
# deliberately wrong rule in X.d (max's branches swapped, sqrt's 2 a 3, the
# quotient rule's b·b a b, the product rule's db a da) or in its folding
# fails them.  `--verdict`'s kernel has no model of templates yet, as for
# Operations.bend.

# The carrier ----------------------------------------------------------------

type Ops<-R: Data> is Type:
  Ops{zero: R, one: R, lit: F32 -> R, ix: U32 -> R,
      neg: R -> R, exp: R -> R, log: R -> R, sqrt: R -> R, abs: R -> R,
      add: R -> R -> R, sub: R -> R -> R, mul: R -> R -> R, div: R -> R -> R,
      lt: R -> R -> Bool, le: R -> R -> Bool, nz: R -> Bool}

def Nm.zero(-R: Data, o: Ops<R>) -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f0

def Nm.one(-R: Data, o: Ops<R>) -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f1

def Nm.lit(-R: Data, o: Ops<R>) -> F32 -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f2

def Nm.ix(-R: Data, o: Ops<R>) -> U32 -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f3

def Nm.neg(-R: Data, o: Ops<R>) -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f4

def Nm.exp(-R: Data, o: Ops<R>) -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f5

def Nm.log(-R: Data, o: Ops<R>) -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f6

def Nm.sqrt(-R: Data, o: Ops<R>) -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f7

def Nm.abs(-R: Data, o: Ops<R>) -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f8

def Nm.add(-R: Data, o: Ops<R>) -> R -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f9

def Nm.sub(-R: Data, o: Ops<R>) -> R -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f10

def Nm.mul(-R: Data, o: Ops<R>) -> R -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f11

def Nm.div(-R: Data, o: Ops<R>) -> R -> R -> R:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f12

def Nm.lt(-R: Data, o: Ops<R>) -> R -> R -> Bool:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f13

def Nm.le(-R: Data, o: Ops<R>) -> R -> R -> Bool:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f14

def Nm.nz(-R: Data, o: Ops<R>) -> R -> Bool:
  match o:
    case Ops{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13, f14, f15}:
      f15

# The laws the folding uses

type Laws<-R: Data, -o: Ops<R>> is Type:
  Laws{add_zero_l: @+x:R -> {Nm.add(R, o)(Nm.zero(R, o), x) == x : R},
       add_zero_r: @+x:R -> {Nm.add(R, o)(x, Nm.zero(R, o)) == x : R},
       sub_zero_l: @+x:R -> {Nm.sub(R, o)(Nm.zero(R, o), x) == Nm.neg(R, o)(x) : R},
       sub_zero_r: @+x:R -> {Nm.sub(R, o)(x, Nm.zero(R, o)) == x : R},
       neg_zero: {Nm.neg(R, o)(Nm.zero(R, o)) == Nm.zero(R, o) : R},
       mul_zero_l: @+x:R -> {Nm.mul(R, o)(Nm.zero(R, o), x) == Nm.zero(R, o) : R},
       mul_zero_r: @+x:R -> {Nm.mul(R, o)(x, Nm.zero(R, o)) == Nm.zero(R, o) : R},
       mul_one_l: @+x:R -> {Nm.mul(R, o)(Nm.one(R, o), x) == x : R},
       mul_one_r: @+x:R -> {Nm.mul(R, o)(x, Nm.one(R, o)) == x : R},
       div_zero_l: @+x:R -> {Nm.div(R, o)(Nm.zero(R, o), x) == Nm.zero(R, o) : R},
       div_one_r: @+x:R -> {Nm.div(R, o)(x, Nm.one(R, o)) == x : R},
       nz_zero: {Nm.nz(R, o)(Nm.zero(R, o)) == False{} : Bool},
       nz_one: {Nm.nz(R, o)(Nm.one(R, o)) == True{} : Bool}}

def Lw.add_zero_l(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.add(R, o)(Nm.zero(R, o), x) == x : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g0

def Lw.add_zero_r(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.add(R, o)(x, Nm.zero(R, o)) == x : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g1

def Lw.sub_zero_l(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.sub(R, o)(Nm.zero(R, o), x) == Nm.neg(R, o)(x) : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g2

def Lw.sub_zero_r(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.sub(R, o)(x, Nm.zero(R, o)) == x : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g3

def Lw.neg_zero(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> {Nm.neg(R, o)(Nm.zero(R, o)) == Nm.zero(R, o) : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g4

def Lw.mul_zero_l(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.mul(R, o)(Nm.zero(R, o), x) == Nm.zero(R, o) : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g5

def Lw.mul_zero_r(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.mul(R, o)(x, Nm.zero(R, o)) == Nm.zero(R, o) : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g6

def Lw.mul_one_l(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.mul(R, o)(Nm.one(R, o), x) == x : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g7

def Lw.mul_one_r(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.mul(R, o)(x, Nm.one(R, o)) == x : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g8

def Lw.div_zero_l(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.div(R, o)(Nm.zero(R, o), x) == Nm.zero(R, o) : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g9

def Lw.div_one_r(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> @+x:R -> {Nm.div(R, o)(x, Nm.one(R, o)) == x : R}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g10

def Lw.nz_zero(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> {Nm.nz(R, o)(Nm.zero(R, o)) == False{} : Bool}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g11

def Lw.nz_one(-R: Data, -o: Ops<R>, l: Laws<R, o>) -> {Nm.nz(R, o)(Nm.one(R, o)) == True{} : Bool}:
  match l:
    case Laws{g0, g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}:
      g12

# Semantics ------------------------------------------------------------------

# a constant: 0 and 1 are the carrier's own, any other its `lit`
def k(~R: Data, ~O: Ops<R>, +c: F32) -> R:
  Bool.pick(R, F32.is_eq(c, 0.0), Nm.zero(R, O), Bool.pick(R, F32.is_eq(c, 1.0), Nm.one(R, O), Nm.lit(R, O)(c)))

def bit(~R: Data, ~O: Ops<R>, z: Bool) -> R:
  Bool.pick(R, z, Nm.one(R, O), Nm.zero(R, O))

# Bulk.bend's Ex.un and Ex.bin, op for op (max is a > b ? a : b, min
# a < b ? a : b, lt and le 1 or 0)
def un(~R: Data, ~O: Ops<R>, +op: U32, +x: R) -> R:
  Bool.pick(R, U32.is_eq(op, 0), Nm.neg(R, O)(x),
  Bool.pick(R, U32.is_eq(op, 1), Nm.exp(R, O)(x),
  Bool.pick(R, U32.is_eq(op, 2), Nm.log(R, O)(x),
  Bool.pick(R, U32.is_eq(op, 3), Nm.sqrt(R, O)(x), Nm.abs(R, O)(x)))))

def bin(~R: Data, ~O: Ops<R>, +op: U32, +a: R, +b: R) -> R:
  Bool.pick(R, U32.is_eq(op, 0), Nm.add(R, O)(a, b),
  Bool.pick(R, U32.is_eq(op, 1), Nm.sub(R, O)(a, b),
  Bool.pick(R, U32.is_eq(op, 2), Nm.mul(R, O)(a, b),
  Bool.pick(R, U32.is_eq(op, 3), Nm.div(R, O)(a, b),
  Bool.pick(R, U32.is_eq(op, 4), Bool.pick(R, Nm.lt(R, O)(b, a), a, b),
  Bool.pick(R, U32.is_eq(op, 5), Bool.pick(R, Nm.lt(R, O)(a, b), a, b),
  Bool.pick(R, U32.is_eq(op, 6), bit(~R, ~O, Nm.lt(R, O)(a, b)),
    bit(~R, ~O, Nm.le(R, O)(a, b)))))))))

def nth(~R: Data, ~O: Ops<R>, xs: List<&2, R>, +i: U32) -> R:
  match xs:
    case Nil{}:
      Nm.zero(R, O)
    case +x <> t:
      Bool.pick(R, U32.is_eq(i, 0), x, nth(~R, ~O, t, U32.sub(i, 1)))

# an expression's value (Bulk.bend's Ex.eval over the carrier)
def eval(~R: Data, ~O: Ops<R>, e: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) -> R:
  match e:
    case B.EIn{i}:
      nth(~R, ~O, vs, i)
    case B.EIx{i}:
      Nm.ix(R, O)(B.Ex.nthu(pt, i))
    case B.EK{c}:
      k(~R, ~O, c)
    case B.E1{op, a}:
      un(~R, ~O, op, eval(~R, ~O, a, vs, pt))
    case B.E2{op, a, b}:
      bin(~R, ~O, op, eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt))
    case B.ESel{c, a, b}:
      Bool.pick(R, Nm.nz(R, O)(eval(~R, ~O, c, vs, pt)), eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt))

# Dual numbers: a value and its tangent, v + t·ε with ε² = 0
type Dual<-R: Data> is Data:
  Dual{v: R, t: R}

def D.v(-R: Data, +d: Dual<R>) -> R:
  match d:
    case Dual{v, t}:
      v

def D.t(-R: Data, +d: Dual<R>) -> R:
  match d:
    case Dual{v, t}:
      t

# the inputs' tangents: input j's unit vector (one partial derivative), or
# given tangents (a derivative along a direction: the gradient gate)
type Seed<-R: Data> is Data:
  SeedAt{j: U32}
  SeedTs{ts: List<&2, R>}

def seed(~R: Data, ~O: Ops<R>, s: Seed<R>, +i: U32) -> R:
  match s:
    case SeedAt{j}:
      bit(~R, ~O, U32.is_eq(i, j))
    case SeedTs{ts}:
      nth(~R, ~O, ts, i)

# each primitive's rule on dual numbers: f(x + dx·ε) = f(x) + f'(x)·dx·ε
def un.t(~R: Data, ~O: Ops<R>, +op: U32, +x: R, +dx: R) -> R:
  Bool.pick(R, U32.is_eq(op, 0), Nm.neg(R, O)(dx),
  Bool.pick(R, U32.is_eq(op, 1), Nm.mul(R, O)(Nm.exp(R, O)(x), dx),
  Bool.pick(R, U32.is_eq(op, 2), Nm.div(R, O)(dx, x),
  Bool.pick(R, U32.is_eq(op, 3), Nm.div(R, O)(dx, Nm.mul(R, O)(k(~R, ~O, 2.0), Nm.sqrt(R, O)(x))),
    Bool.pick(R, Nm.lt(R, O)(x, Nm.zero(R, O)), Nm.neg(R, O)(dx), dx)))))

def bin.t(~R: Data, ~O: Ops<R>, +op: U32, +x: R, +dx: R, +y: R, +dy: R) -> R:
  Bool.pick(R, U32.is_eq(op, 0), Nm.add(R, O)(dx, dy),
  Bool.pick(R, U32.is_eq(op, 1), Nm.sub(R, O)(dx, dy),
  Bool.pick(R, U32.is_eq(op, 2), Nm.add(R, O)(Nm.mul(R, O)(dx, y), Nm.mul(R, O)(x, dy)),
  Bool.pick(R, U32.is_eq(op, 3), Nm.sub(R, O)(Nm.div(R, O)(dx, y), Nm.div(R, O)(Nm.mul(R, O)(x, dy), Nm.mul(R, O)(y, y))),
  Bool.pick(R, U32.is_eq(op, 4), Bool.pick(R, Nm.lt(R, O)(y, x), dx, dy),
  Bool.pick(R, U32.is_eq(op, 5), Bool.pick(R, Nm.lt(R, O)(x, y), dx, dy), Nm.zero(R, O)))))))

def un.dual(~R: Data, ~O: Ops<R>, +op: U32, +d: Dual<R>) -> Dual<R>:
  Dual{un(~R, ~O, op, D.v(R, d)), un.t(~R, ~O, op, D.v(R, d), D.t(R, d))}

def bin.dual(~R: Data, ~O: Ops<R>, +op: U32, +a: Dual<R>, +b: Dual<R>) -> Dual<R>:
  Dual{bin(~R, ~O, op, D.v(R, a), D.v(R, b)), bin.t(~R, ~O, op, D.v(R, a), D.t(R, a), D.v(R, b), D.t(R, b))}

# an expression evaluated on dual numbers (input i is vs[i] + seed(i)·ε)
def dual(~R: Data, ~O: Ops<R>, e: B.Ex, +vs: List<&2, R>, +s: Seed<R>, +pt: List<&2, U32>) -> Dual<R>:
  match e:
    case B.EIn{+i}:
      Dual{nth(~R, ~O, vs, i), seed(~R, ~O, s, i)}
    case B.EIx{i}:
      Dual{Nm.ix(R, O)(B.Ex.nthu(pt, i)), Nm.zero(R, O)}
    case B.EK{c}:
      Dual{k(~R, ~O, c), Nm.zero(R, O)}
    case B.E1{op, a}:
      un.dual(~R, ~O, op, dual(~R, ~O, a, vs, s, pt))
    case B.E2{op, a, b}:
      bin.dual(~R, ~O, op, dual(~R, ~O, a, vs, s, pt), dual(~R, ~O, b, vs, s, pt))
    case B.ESel{c, a, b}:
      Bool.pick(Dual<R>, Nm.nz(R, O)(D.v(R, dual(~R, ~O, c, vs, s, pt))), dual(~R, ~O, a, vs, s, pt), dual(~R, ~O, b, vs, s, pt))

# Dual numbers' values are the plain values ---------------------------------

def pick.v(-R: Data, z: Bool, +a: Dual<R>, +b: Dual<R>) -> {D.v(R, Bool.pick(Dual<R>, z, a, b)) == Bool.pick(R, z, D.v(R, a), D.v(R, b)) : R}:
  match z:
    case True{}:
      {==}
    case False{}:
      {==}

def pick.t(-R: Data, z: Bool, +a: Dual<R>, +b: Dual<R>) -> {D.t(R, Bool.pick(Dual<R>, z, a, b)) == Bool.pick(R, z, D.t(R, a), D.t(R, b)) : R}:
  match z:
    case True{}:
      {==}
    case False{}:
      {==}

def dual_v(~R: Data, ~O: Ops<R>, e: B.Ex, +vs: List<&2, R>, +s: Seed<R>, +pt: List<&2, U32>) ->
    {D.v(R, dual(~R, ~O, e, vs, s, pt)) == eval(~R, ~O, e, vs, pt) : R}:
  match e:
    case B.EIn{i}:
      {==}
    case B.EIx{i}:
      {==}
    case B.EK{c}:
      {==}
    case B.E1{op, +a}:
      %dual_v(~R, ~O, a, vs, s, pt) : {un(~R, ~O, op, D.v(R, dual(~R, ~O, a, vs, s, pt))) == un(~R, ~O, op, _) : R}
      {==}
    case B.E2{op, +a, +b}:
      +va = D.v(R, dual(~R, ~O, a, vs, s, pt))
      %dual_v(~R, ~O, a, vs, s, pt) : {bin(~R, ~O, op, va, D.v(R, dual(~R, ~O, b, vs, s, pt))) == bin(~R, ~O, op, _, eval(~R, ~O, b, vs, pt)) : R}
      %dual_v(~R, ~O, b, vs, s, pt) : {bin(~R, ~O, op, va, D.v(R, dual(~R, ~O, b, vs, s, pt))) == bin(~R, ~O, op, va, _) : R}
      {==}
    case B.ESel{+c, +a, +b}:
      +da = dual(~R, ~O, a, vs, s, pt)
      +db = dual(~R, ~O, b, vs, s, pt)
      +z = Nm.nz(R, O)(D.v(R, dual(~R, ~O, c, vs, s, pt)))
      %dual_v(~R, ~O, c, vs, s, pt) : {D.v(R, Bool.pick(Dual<R>, z, da, db)) == Bool.pick(R, Nm.nz(R, O)(_), eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) : R}
      %dual_v(~R, ~O, a, vs, s, pt) : {D.v(R, Bool.pick(Dual<R>, z, da, db)) == Bool.pick(R, z, _, eval(~R, ~O, b, vs, pt)) : R}
      %dual_v(~R, ~O, b, vs, s, pt) : {D.v(R, Bool.pick(Dual<R>, z, da, db)) == Bool.pick(R, z, D.v(R, da), _) : R}
      pick.v(R, z, da, db)

# Ex.bend's simplifying constructors mean what they build ------------------
#
# Each rewrite (0 + x = x, 0·x = 0, x/1 = x, ...) is one of the carrier's
# laws; 0·x = 0 and 0/x = 0 are where F32 departs from them (0·∞ and 0/0
# are NaN): the side conditions under which the derivative the GPU runs is
# the true one.

def bdisc(b: Bool) -> Type:
  match b:
    case True{}:
      Empty
    case False{}:
      Unit

def ft(h: {False{} == True{} : Bool}) -> Empty:
  %h : bdisc(_)
  Unit{}

def no(-A: Type, h: {False{} == True{} : Bool}) -> A:
  Empty.absurd(A, ft(h))

# the literals d writes: 0 and 1 (F32 comparisons do not compute in a
# proof, so the three facts about them are hypotheses)
def k0(~R: Data, ~O: Ops<R>, +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) -> {Nm.zero(R, O) == k(~R, ~O, 0.0) : R}:
  %Equal.sym(Bool, F32.is_eq(0.0, 0.0), True{}, z0) : {Nm.zero(R, O) == Bool.pick(R, _, Nm.zero(R, O), Bool.pick(R, F32.is_eq(0.0, 1.0), Nm.one(R, O), Nm.lit(R, O)(0.0))) : R}
  {==}

def k1(~R: Data, ~O: Ops<R>, +o0: {F32.is_eq(1.0, 0.0) == False{} : Bool}, +o1: {F32.is_eq(1.0, 1.0) == True{} : Bool}) -> {Nm.one(R, O) == k(~R, ~O, 1.0) : R}:
  %Equal.sym(Bool, F32.is_eq(1.0, 0.0), False{}, o0) : {Nm.one(R, O) == Bool.pick(R, _, Nm.zero(R, O), Bool.pick(R, F32.is_eq(1.0, 1.0), Nm.one(R, O), Nm.lit(R, O)(1.0))) : R}
  %Equal.sym(Bool, F32.is_eq(1.0, 1.0), True{}, o1) : {Nm.one(R, O) == Bool.pick(R, False{}, Nm.zero(R, O), Bool.pick(R, _, Nm.one(R, O), Nm.lit(R, O)(1.0))) : R}
  {==}

def nzbit(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, z: Bool) -> {z == Nm.nz(R, O)(bit(~R, ~O, z)) : Bool}:
  match z:
    case True{}:
      Equal.sym(Bool, Nm.nz(R, O)(Nm.one(R, O)), True{}, Lw.nz_one(R, O, L))
    case False{}:
      Equal.sym(Bool, Nm.nz(R, O)(Nm.zero(R, O)), False{}, Lw.nz_zero(R, O, L))

def pick.same(-A: Data, z: Bool, +x: A) -> {Bool.pick(A, z, x, x) == x : A}:
  match z:
    case True{}:
      {==}
    case False{}:
      {==}

def is0_ok(~R: Data, ~O: Ops<R>, e: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    {X.is0(e) == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, e, vs, pt) : R}:
  match e:
    case B.EK{+c}:
      h =>
        %Equal.sym(Bool, F32.is_eq(c, 0.0), True{}, h) : {Nm.zero(R, O) == Bool.pick(R, _, Nm.zero(R, O), Bool.pick(R, F32.is_eq(c, 1.0), Nm.one(R, O), Nm.lit(R, O)(c))) : R}
        {==}
    case B.EIn{i}:
      h => no({Nm.zero(R, O) == eval(~R, ~O, B.EIn{i}, vs, pt) : R}, h)
    case B.EIx{i}:
      h => no({Nm.zero(R, O) == eval(~R, ~O, B.EIx{i}, vs, pt) : R}, h)
    case B.E1{op, a}:
      h => no({Nm.zero(R, O) == eval(~R, ~O, B.E1{op, a}, vs, pt) : R}, h)
    case B.E2{op, a, b}:
      h => no({Nm.zero(R, O) == eval(~R, ~O, B.E2{op, a, b}, vs, pt) : R}, h)
    case B.ESel{c, a, b}:
      h => no({Nm.zero(R, O) == eval(~R, ~O, B.ESel{c, a, b}, vs, pt) : R}, h)

def is1.go(~R: Data, ~O: Ops<R>, z0: Bool, z1: Bool, +c: F32) ->
    {Bool.and(z1, Bool.not(z0)) == True{} : Bool} -> {Nm.one(R, O) == Bool.pick(R, z0, Nm.zero(R, O), Bool.pick(R, z1, Nm.one(R, O), Nm.lit(R, O)(c))) : R}:
  match z0 z1:
    case True{} True{}:
      h => no({Nm.one(R, O) == Nm.zero(R, O) : R}, h)
    case True{} False{}:
      h => no({Nm.one(R, O) == Nm.zero(R, O) : R}, h)
    case False{} True{}:
      h => {==}
    case False{} False{}:
      h => no({Nm.one(R, O) == Nm.lit(R, O)(c) : R}, h)

def is1_ok(~R: Data, ~O: Ops<R>, e: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    {X.is1(e) == True{} : Bool} -> {Nm.one(R, O) == eval(~R, ~O, e, vs, pt) : R}:
  match e:
    case B.EK{+c}:
      is1.go(~R, ~O, F32.is_eq(c, 0.0), F32.is_eq(c, 1.0), c)
    case B.EIn{i}:
      h => no({Nm.one(R, O) == eval(~R, ~O, B.EIn{i}, vs, pt) : R}, h)
    case B.EIx{i}:
      h => no({Nm.one(R, O) == eval(~R, ~O, B.EIx{i}, vs, pt) : R}, h)
    case B.E1{op, a}:
      h => no({Nm.one(R, O) == eval(~R, ~O, B.E1{op, a}, vs, pt) : R}, h)
    case B.E2{op, a, b}:
      h => no({Nm.one(R, O) == eval(~R, ~O, B.E2{op, a, b}, vs, pt) : R}, h)
    case B.ESel{c, a, b}:
      h => no({Nm.one(R, O) == eval(~R, ~O, B.ESel{c, a, b}, vs, pt) : R}, h)

def add.if_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, z: Bool, w: Bool, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    ({z == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, a, vs, pt) : R}) ->
    ({w == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, b, vs, pt) : R}) ->
    {Nm.add(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.add.if(z, w, a, b), vs, pt) : R}:
  match z w:
    case True{} True{}:
      ha => hb =>
        %ha({==}) : {Nm.add(R, O)(_, eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, b, vs, pt) : R}
        Lw.add_zero_l(R, O, L, eval(~R, ~O, b, vs, pt))
    case True{} False{}:
      ha => hb =>
        %ha({==}) : {Nm.add(R, O)(_, eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, b, vs, pt) : R}
        Lw.add_zero_l(R, O, L, eval(~R, ~O, b, vs, pt))
    case False{} True{}:
      ha => hb =>
        %hb({==}) : {Nm.add(R, O)(eval(~R, ~O, a, vs, pt), _) == eval(~R, ~O, a, vs, pt) : R}
        Lw.add_zero_r(R, O, L, eval(~R, ~O, a, vs, pt))
    case False{} False{}:
      ha => hb => {==}

def add_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    {Nm.add(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.add(a, b), vs, pt) : R}:
  add.if_ok(~R, ~O, ~L, X.is0(a), X.is0(b), a, b, vs, pt)(is0_ok(~R, ~O, a, vs, pt))(is0_ok(~R, ~O, b, vs, pt))

def neg.if_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, z: Bool, +a: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    ({z == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, a, vs, pt) : R}) ->
    {Nm.neg(R, O)(eval(~R, ~O, a, vs, pt)) == eval(~R, ~O, X.neg.if(z, a), vs, pt) : R}:
  match z:
    case True{}:
      ha =>
        %ha({==}) : {Nm.neg(R, O)(_) == _ : R}
        Lw.neg_zero(R, O, L)
    case False{}:
      ha => {==}

def neg_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, +a: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    {Nm.neg(R, O)(eval(~R, ~O, a, vs, pt)) == eval(~R, ~O, X.neg(a), vs, pt) : R}:
  neg.if_ok(~R, ~O, ~L, X.is0(a), a, vs, pt)(is0_ok(~R, ~O, a, vs, pt))

def sub.if_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, z: Bool, w: Bool, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    ({z == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, a, vs, pt) : R}) ->
    ({w == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, b, vs, pt) : R}) ->
    {Nm.sub(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.sub.if(z, w, a, b), vs, pt) : R}:
  match z w:
    case True{} True{}:
      ha => hb =>
        %hb({==}) : {Nm.sub(R, O)(eval(~R, ~O, a, vs, pt), _) == eval(~R, ~O, a, vs, pt) : R}
        Lw.sub_zero_r(R, O, L, eval(~R, ~O, a, vs, pt))
    case False{} True{}:
      ha => hb =>
        %hb({==}) : {Nm.sub(R, O)(eval(~R, ~O, a, vs, pt), _) == eval(~R, ~O, a, vs, pt) : R}
        Lw.sub_zero_r(R, O, L, eval(~R, ~O, a, vs, pt))
    case True{} False{}:
      ha => hb =>
        %neg_ok(~R, ~O, ~L, b, vs, pt) : {Nm.sub(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == _ : R}
        %ha({==}) : {Nm.sub(R, O)(_, eval(~R, ~O, b, vs, pt)) == Nm.neg(R, O)(eval(~R, ~O, b, vs, pt)) : R}
        Lw.sub_zero_l(R, O, L, eval(~R, ~O, b, vs, pt))
    case False{} False{}:
      ha => hb => {==}

def sub_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    {Nm.sub(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.sub(a, b), vs, pt) : R}:
  sub.if_ok(~R, ~O, ~L, X.is0(a), X.is0(b), a, b, vs, pt)(is0_ok(~R, ~O, a, vs, pt))(is0_ok(~R, ~O, b, vs, pt))

def mul.if_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, za: Bool, zb: Bool, oa: Bool, ob: Bool, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>,
    +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    ({za == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, a, vs, pt) : R}) ->
    ({zb == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, b, vs, pt) : R}) ->
    ({oa == True{} : Bool} -> {Nm.one(R, O) == eval(~R, ~O, a, vs, pt) : R}) ->
    ({ob == True{} : Bool} -> {Nm.one(R, O) == eval(~R, ~O, b, vs, pt) : R}) ->
    {Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.mul.if(Bool.or(za, zb), oa, ob, a, b), vs, pt) : R}:
  match za zb oa ob:
    case True{} _ _ _:
      ha => hb => h1 => h2 =>
        %k0(~R, ~O, z0) : {Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == _ : R}
        %ha({==}) : {Nm.mul(R, O)(_, eval(~R, ~O, b, vs, pt)) == Nm.zero(R, O) : R}
        Lw.mul_zero_l(R, O, L, eval(~R, ~O, b, vs, pt))
    case False{} True{} _ _:
      ha => hb => h1 => h2 =>
        %k0(~R, ~O, z0) : {Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == _ : R}
        %hb({==}) : {Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), _) == Nm.zero(R, O) : R}
        Lw.mul_zero_r(R, O, L, eval(~R, ~O, a, vs, pt))
    case False{} False{} True{} _:
      ha => hb => h1 => h2 =>
        %h1({==}) : {Nm.mul(R, O)(_, eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, b, vs, pt) : R}
        Lw.mul_one_l(R, O, L, eval(~R, ~O, b, vs, pt))
    case False{} False{} False{} True{}:
      ha => hb => h1 => h2 =>
        %h2({==}) : {Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), _) == eval(~R, ~O, a, vs, pt) : R}
        Lw.mul_one_r(R, O, L, eval(~R, ~O, a, vs, pt))
    case False{} False{} False{} False{}:
      ha => hb => h1 => h2 => {==}

def mul_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>,
    +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    {Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.mul(a, b), vs, pt) : R}:
  mul.if_ok(~R, ~O, ~L, X.is0(a), X.is0(b), X.is1(a), X.is1(b), a, b, vs, pt, z0)(is0_ok(~R, ~O, a, vs, pt))(is0_ok(~R, ~O, b, vs, pt))(is1_ok(~R, ~O, a, vs, pt))(is1_ok(~R, ~O, b, vs, pt))

def div.if_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, z: Bool, o: Bool, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>,
    +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    ({z == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, a, vs, pt) : R}) ->
    ({o == True{} : Bool} -> {Nm.one(R, O) == eval(~R, ~O, b, vs, pt) : R}) ->
    {Nm.div(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.div.if(z, o, a, b), vs, pt) : R}:
  match z o:
    case True{} _:
      ha => hb =>
        %k0(~R, ~O, z0) : {Nm.div(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == _ : R}
        %ha({==}) : {Nm.div(R, O)(_, eval(~R, ~O, b, vs, pt)) == Nm.zero(R, O) : R}
        Lw.div_zero_l(R, O, L, eval(~R, ~O, b, vs, pt))
    case False{} True{}:
      ha => hb =>
        %hb({==}) : {Nm.div(R, O)(eval(~R, ~O, a, vs, pt), _) == eval(~R, ~O, a, vs, pt) : R}
        Lw.div_one_r(R, O, L, eval(~R, ~O, a, vs, pt))
    case False{} False{}:
      ha => hb => {==}

def div_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>,
    +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    {Nm.div(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.div(a, b), vs, pt) : R}:
  div.if_ok(~R, ~O, ~L, X.is0(a), X.is1(b), a, b, vs, pt, z0)(is0_ok(~R, ~O, a, vs, pt))(is1_ok(~R, ~O, b, vs, pt))

def sel.if_ok(~R: Data, ~O: Ops<R>, za: Bool, zb: Bool, +c: B.Ex, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>,
    +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    ({za == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, a, vs, pt) : R}) ->
    ({zb == True{} : Bool} -> {Nm.zero(R, O) == eval(~R, ~O, b, vs, pt) : R}) ->
    {Bool.pick(R, Nm.nz(R, O)(eval(~R, ~O, c, vs, pt)), eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.sel.if(Bool.and(za, zb), c, a, b), vs, pt) : R}:
  match za zb:
    case True{} True{}:
      ha => hb =>
        +nc = Nm.nz(R, O)(eval(~R, ~O, c, vs, pt))
        %k0(~R, ~O, z0) : {Bool.pick(R, nc, eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == _ : R}
        %ha({==}) : {Bool.pick(R, nc, _, eval(~R, ~O, b, vs, pt)) == Nm.zero(R, O) : R}
        %hb({==}) : {Bool.pick(R, nc, Nm.zero(R, O), _) == Nm.zero(R, O) : R}
        pick.same(R, nc, Nm.zero(R, O))
    case True{} False{}:
      ha => hb => {==}
    case False{} _:
      ha => hb => {==}

def sel_ok(~R: Data, ~O: Ops<R>, +c: B.Ex, +a: B.Ex, +b: B.Ex, +vs: List<&2, R>, +pt: List<&2, U32>,
    +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    {Bool.pick(R, Nm.nz(R, O)(eval(~R, ~O, c, vs, pt)), eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt)) == eval(~R, ~O, X.sel(c, a, b), vs, pt) : R}:
  sel.if_ok(~R, ~O, X.is0(a), X.is0(b), c, a, b, vs, pt, z0)(is0_ok(~R, ~O, a, vs, pt))(is0_ok(~R, ~O, b, vs, pt))

# d is the dual numbers' tangent ---------------------------------------------

# an input's derivative: 1 for the input asked for, else 0
def in_ok(~R: Data, ~O: Ops<R>, z: Bool, +vs: List<&2, R>, +pt: List<&2, U32>,
    +z0: {F32.is_eq(0.0, 0.0) == True{} : Bool}, +o0: {F32.is_eq(1.0, 0.0) == False{} : Bool}, +o1: {F32.is_eq(1.0, 1.0) == True{} : Bool}) ->
    {bit(~R, ~O, z) == eval(~R, ~O, Bool.pick(B.Ex, z, X.k(1.0), X.k(0.0)), vs, pt) : R}:
  match z:
    case True{}:
      k1(~R, ~O, o0, o1)
    case False{}:
      k0(~R, ~O, z0)

# d.un, its op tests left open (z_i is "op is i")
def un_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, z0: Bool, z1: Bool, z2: Bool, z3: Bool,
    +a: B.Ex, +da: B.Ex, +x: R, +dx: R, +vs: List<&2, R>, +pt: List<&2, U32>,
    +ex: {x == eval(~R, ~O, a, vs, pt) : R}, +edx: {dx == eval(~R, ~O, da, vs, pt) : R},
    +f0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    {Bool.pick(R, z0, Nm.neg(R, O)(dx),
     Bool.pick(R, z1, Nm.mul(R, O)(Nm.exp(R, O)(x), dx),
     Bool.pick(R, z2, Nm.div(R, O)(dx, x),
     Bool.pick(R, z3, Nm.div(R, O)(dx, Nm.mul(R, O)(k(~R, ~O, 2.0), Nm.sqrt(R, O)(x))),
       Bool.pick(R, Nm.lt(R, O)(x, Nm.zero(R, O)), Nm.neg(R, O)(dx), dx)))))
     == eval(~R, ~O,
     Bool.pick(B.Ex, z0, X.neg(da),
     Bool.pick(B.Ex, z1, X.mul(X.exp(a), da),
     Bool.pick(B.Ex, z2, X.div(da, a),
     Bool.pick(B.Ex, z3, X.div(da, X.mul(X.k(2.0), X.sqrt(a))),
       X.sel(X.lt(a, X.k(0.0)), X.neg(da), da))))), vs, pt) : R}:
  match z0:
    case True{}:
      %neg_ok(~R, ~O, ~L, da, vs, pt) : {Nm.neg(R, O)(dx) == _ : R}
      %edx : {Nm.neg(R, O)(dx) == Nm.neg(R, O)(_) : R}
      {==}
    case False{}:
      match z1:
        case True{}:
          %mul_ok(~R, ~O, ~L, X.exp(a), da, vs, pt, f0) : {Nm.mul(R, O)(Nm.exp(R, O)(x), dx) == _ : R}
          %ex : {Nm.mul(R, O)(Nm.exp(R, O)(x), dx) == Nm.mul(R, O)(Nm.exp(R, O)(_), eval(~R, ~O, da, vs, pt)) : R}
          %edx : {Nm.mul(R, O)(Nm.exp(R, O)(x), dx) == Nm.mul(R, O)(Nm.exp(R, O)(x), _) : R}
          {==}
        case False{}:
          match z2:
            case True{}:
              %div_ok(~R, ~O, ~L, da, a, vs, pt, f0) : {Nm.div(R, O)(dx, x) == _ : R}
              %edx : {Nm.div(R, O)(dx, x) == Nm.div(R, O)(_, eval(~R, ~O, a, vs, pt)) : R}
              %ex : {Nm.div(R, O)(dx, x) == Nm.div(R, O)(dx, _) : R}
              {==}
            case False{}:
              match z3:
                case True{}:
                  +lhs = Nm.div(R, O)(dx, Nm.mul(R, O)(k(~R, ~O, 2.0), Nm.sqrt(R, O)(x)))
                  %div_ok(~R, ~O, ~L, da, X.mul(X.k(2.0), X.sqrt(a)), vs, pt, f0) : {lhs == _ : R}
                  %mul_ok(~R, ~O, ~L, X.k(2.0), X.sqrt(a), vs, pt, f0) : {lhs == Nm.div(R, O)(eval(~R, ~O, da, vs, pt), _) : R}
                  %edx : {lhs == Nm.div(R, O)(_, Nm.mul(R, O)(k(~R, ~O, 2.0), Nm.sqrt(R, O)(eval(~R, ~O, a, vs, pt)))) : R}
                  %ex : {lhs == Nm.div(R, O)(dx, Nm.mul(R, O)(k(~R, ~O, 2.0), Nm.sqrt(R, O)(_))) : R}
                  {==}
                case False{}:
                  +lhs = Bool.pick(R, Nm.lt(R, O)(x, Nm.zero(R, O)), Nm.neg(R, O)(dx), dx)
                  %sel_ok(~R, ~O, X.lt(a, X.k(0.0)), X.neg(da), da, vs, pt, f0) : {lhs == _ : R}
                  %neg_ok(~R, ~O, ~L, da, vs, pt) : {lhs == Bool.pick(R, Nm.nz(R, O)(bit(~R, ~O, Nm.lt(R, O)(eval(~R, ~O, a, vs, pt), k(~R, ~O, 0.0)))), _, eval(~R, ~O, da, vs, pt)) : R}
                  %k0(~R, ~O, f0) : {lhs == Bool.pick(R, Nm.nz(R, O)(bit(~R, ~O, Nm.lt(R, O)(eval(~R, ~O, a, vs, pt), _))), Nm.neg(R, O)(eval(~R, ~O, da, vs, pt)), eval(~R, ~O, da, vs, pt)) : R}
                  %nzbit(~R, ~O, ~L, Nm.lt(R, O)(eval(~R, ~O, a, vs, pt), Nm.zero(R, O))) : {lhs == Bool.pick(R, _, Nm.neg(R, O)(eval(~R, ~O, da, vs, pt)), eval(~R, ~O, da, vs, pt)) : R}
                  %ex : {lhs == Bool.pick(R, Nm.lt(R, O)(_, Nm.zero(R, O)), Nm.neg(R, O)(eval(~R, ~O, da, vs, pt)), eval(~R, ~O, da, vs, pt)) : R}
                  %edx : {lhs == Bool.pick(R, Nm.lt(R, O)(x, Nm.zero(R, O)), Nm.neg(R, O)(_), _) : R}
                  {==}

# d.bin, its op tests left open
def bin_ok(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>, z0: Bool, z1: Bool, z2: Bool, z3: Bool, z4: Bool, z5: Bool,
    +a: B.Ex, +b: B.Ex, +da: B.Ex, +db: B.Ex, +x: R, +dx: R, +y: R, +dy: R, +vs: List<&2, R>, +pt: List<&2, U32>,
    +ex: {x == eval(~R, ~O, a, vs, pt) : R}, +edx: {dx == eval(~R, ~O, da, vs, pt) : R},
    +ey: {y == eval(~R, ~O, b, vs, pt) : R}, +edy: {dy == eval(~R, ~O, db, vs, pt) : R},
    +f0: {F32.is_eq(0.0, 0.0) == True{} : Bool}) ->
    {Bool.pick(R, z0, Nm.add(R, O)(dx, dy),
     Bool.pick(R, z1, Nm.sub(R, O)(dx, dy),
     Bool.pick(R, z2, Nm.add(R, O)(Nm.mul(R, O)(dx, y), Nm.mul(R, O)(x, dy)),
     Bool.pick(R, z3, Nm.sub(R, O)(Nm.div(R, O)(dx, y), Nm.div(R, O)(Nm.mul(R, O)(x, dy), Nm.mul(R, O)(y, y))),
     Bool.pick(R, z4, Bool.pick(R, Nm.lt(R, O)(y, x), dx, dy),
     Bool.pick(R, z5, Bool.pick(R, Nm.lt(R, O)(x, y), dx, dy), Nm.zero(R, O)))))))
     == eval(~R, ~O,
     Bool.pick(B.Ex, z0, X.add(da, db),
     Bool.pick(B.Ex, z1, X.sub(da, db),
     Bool.pick(B.Ex, z2, X.add(X.mul(da, b), X.mul(a, db)),
     Bool.pick(B.Ex, z3, X.sub(X.div(da, b), X.div(X.mul(a, db), X.mul(b, b))),
     Bool.pick(B.Ex, z4, X.sel(X.lt(b, a), da, db),
     Bool.pick(B.Ex, z5, X.sel(X.lt(a, b), da, db), X.k(0.0))))))), vs, pt) : R}:
  match z0:
    case True{}:
      %add_ok(~R, ~O, ~L, da, db, vs, pt) : {Nm.add(R, O)(dx, dy) == _ : R}
      %edx : {Nm.add(R, O)(dx, dy) == Nm.add(R, O)(_, eval(~R, ~O, db, vs, pt)) : R}
      %edy : {Nm.add(R, O)(dx, dy) == Nm.add(R, O)(dx, _) : R}
      {==}
    case False{}:
      match z1:
        case True{}:
          %sub_ok(~R, ~O, ~L, da, db, vs, pt) : {Nm.sub(R, O)(dx, dy) == _ : R}
          %edx : {Nm.sub(R, O)(dx, dy) == Nm.sub(R, O)(_, eval(~R, ~O, db, vs, pt)) : R}
          %edy : {Nm.sub(R, O)(dx, dy) == Nm.sub(R, O)(dx, _) : R}
          {==}
        case False{}:
          match z2:
            case True{}:
              +lhs = Nm.add(R, O)(Nm.mul(R, O)(dx, y), Nm.mul(R, O)(x, dy))
              %add_ok(~R, ~O, ~L, X.mul(da, b), X.mul(a, db), vs, pt) : {lhs == _ : R}
              %mul_ok(~R, ~O, ~L, da, b, vs, pt, f0) : {lhs == Nm.add(R, O)(_, eval(~R, ~O, X.mul(a, db), vs, pt)) : R}
              %mul_ok(~R, ~O, ~L, a, db, vs, pt, f0) : {lhs == Nm.add(R, O)(Nm.mul(R, O)(eval(~R, ~O, da, vs, pt), eval(~R, ~O, b, vs, pt)), _) : R}
              %edx : {lhs == Nm.add(R, O)(Nm.mul(R, O)(_, eval(~R, ~O, b, vs, pt)), Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, db, vs, pt))) : R}
              %ey : {lhs == Nm.add(R, O)(Nm.mul(R, O)(dx, _), Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, db, vs, pt))) : R}
              %ex : {lhs == Nm.add(R, O)(Nm.mul(R, O)(dx, y), Nm.mul(R, O)(_, eval(~R, ~O, db, vs, pt))) : R}
              %edy : {lhs == Nm.add(R, O)(Nm.mul(R, O)(dx, y), Nm.mul(R, O)(x, _)) : R}
              {==}
            case False{}:
              match z3:
                case True{}:
                  +lhs = Nm.sub(R, O)(Nm.div(R, O)(dx, y), Nm.div(R, O)(Nm.mul(R, O)(x, dy), Nm.mul(R, O)(y, y)))
                  %sub_ok(~R, ~O, ~L, X.div(da, b), X.div(X.mul(a, db), X.mul(b, b)), vs, pt) : {lhs == _ : R}
                  %div_ok(~R, ~O, ~L, da, b, vs, pt, f0) : {lhs == Nm.sub(R, O)(_, eval(~R, ~O, X.div(X.mul(a, db), X.mul(b, b)), vs, pt)) : R}
                  %div_ok(~R, ~O, ~L, X.mul(a, db), X.mul(b, b), vs, pt, f0) : {lhs == Nm.sub(R, O)(Nm.div(R, O)(eval(~R, ~O, da, vs, pt), eval(~R, ~O, b, vs, pt)), _) : R}
                  %mul_ok(~R, ~O, ~L, a, db, vs, pt, f0) : {lhs == Nm.sub(R, O)(Nm.div(R, O)(eval(~R, ~O, da, vs, pt), eval(~R, ~O, b, vs, pt)), Nm.div(R, O)(_, eval(~R, ~O, X.mul(b, b), vs, pt))) : R}
                  %mul_ok(~R, ~O, ~L, b, b, vs, pt, f0) : {lhs == Nm.sub(R, O)(Nm.div(R, O)(eval(~R, ~O, da, vs, pt), eval(~R, ~O, b, vs, pt)), Nm.div(R, O)(Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, db, vs, pt)), _)) : R}
                  %edx : {lhs == Nm.sub(R, O)(Nm.div(R, O)(_, eval(~R, ~O, b, vs, pt)), Nm.div(R, O)(Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, db, vs, pt)), Nm.mul(R, O)(eval(~R, ~O, b, vs, pt), eval(~R, ~O, b, vs, pt)))) : R}
                  %ey : {lhs == Nm.sub(R, O)(Nm.div(R, O)(dx, _), Nm.div(R, O)(Nm.mul(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, db, vs, pt)), Nm.mul(R, O)(_, _))) : R}
                  %ex : {lhs == Nm.sub(R, O)(Nm.div(R, O)(dx, y), Nm.div(R, O)(Nm.mul(R, O)(_, eval(~R, ~O, db, vs, pt)), Nm.mul(R, O)(y, y))) : R}
                  %edy : {lhs == Nm.sub(R, O)(Nm.div(R, O)(dx, y), Nm.div(R, O)(Nm.mul(R, O)(x, _), Nm.mul(R, O)(y, y))) : R}
                  {==}
                case False{}:
                  match z4:
                    case True{}:
                      +lhs = Bool.pick(R, Nm.lt(R, O)(y, x), dx, dy)
                      %sel_ok(~R, ~O, X.lt(b, a), da, db, vs, pt, f0) : {lhs == _ : R}
                      %nzbit(~R, ~O, ~L, Nm.lt(R, O)(eval(~R, ~O, b, vs, pt), eval(~R, ~O, a, vs, pt))) : {lhs == Bool.pick(R, _, eval(~R, ~O, da, vs, pt), eval(~R, ~O, db, vs, pt)) : R}
                      %ey : {lhs == Bool.pick(R, Nm.lt(R, O)(_, eval(~R, ~O, a, vs, pt)), eval(~R, ~O, da, vs, pt), eval(~R, ~O, db, vs, pt)) : R}
                      %ex : {lhs == Bool.pick(R, Nm.lt(R, O)(y, _), eval(~R, ~O, da, vs, pt), eval(~R, ~O, db, vs, pt)) : R}
                      %edx : {lhs == Bool.pick(R, Nm.lt(R, O)(y, x), _, eval(~R, ~O, db, vs, pt)) : R}
                      %edy : {lhs == Bool.pick(R, Nm.lt(R, O)(y, x), dx, _) : R}
                      {==}
                    case False{}:
                      match z5:
                        case True{}:
                          +lhs = Bool.pick(R, Nm.lt(R, O)(x, y), dx, dy)
                          %sel_ok(~R, ~O, X.lt(a, b), da, db, vs, pt, f0) : {lhs == _ : R}
                          %nzbit(~R, ~O, ~L, Nm.lt(R, O)(eval(~R, ~O, a, vs, pt), eval(~R, ~O, b, vs, pt))) : {lhs == Bool.pick(R, _, eval(~R, ~O, da, vs, pt), eval(~R, ~O, db, vs, pt)) : R}
                          %ex : {lhs == Bool.pick(R, Nm.lt(R, O)(_, eval(~R, ~O, b, vs, pt)), eval(~R, ~O, da, vs, pt), eval(~R, ~O, db, vs, pt)) : R}
                          %ey : {lhs == Bool.pick(R, Nm.lt(R, O)(x, _), eval(~R, ~O, da, vs, pt), eval(~R, ~O, db, vs, pt)) : R}
                          %edx : {lhs == Bool.pick(R, Nm.lt(R, O)(x, y), _, eval(~R, ~O, db, vs, pt)) : R}
                          %edy : {lhs == Bool.pick(R, Nm.lt(R, O)(x, y), dx, _) : R}
                          {==}
                        case False{}:
                          k0(~R, ~O, f0)

# The theorem: for every expression e and input j, d(e, j) evaluates to the
# tangent of e on dual numbers seeded at input j.  By induction over e: the
# chain rule at each op, the simplifier sound by the carrier's laws, a
# select's condition held, constants, indices, lt and le flat.
def d_right(~R: Data, ~O: Ops<R>, ~L: Laws<R, O>,
    +f0: {F32.is_eq(0.0, 0.0) == True{} : Bool}, +o0: {F32.is_eq(1.0, 0.0) == False{} : Bool}, +o1: {F32.is_eq(1.0, 1.0) == True{} : Bool},
    e: B.Ex, +j: U32, +vs: List<&2, R>, +pt: List<&2, U32>) ->
    {D.t(R, dual(~R, ~O, e, vs, SeedAt{j}, pt)) == eval(~R, ~O, X.d(e, j), vs, pt) : R}:
  match e:
    case B.EIn{+i}:
      in_ok(~R, ~O, U32.is_eq(i, j), vs, pt, f0, o0, o1)
    case B.EIx{i}:
      k0(~R, ~O, f0)
    case B.EK{c}:
      k0(~R, ~O, f0)
    case B.E1{+op, +a}:
      +dd = dual(~R, ~O, a, vs, SeedAt{j}, pt)
      un_ok(~R, ~O, ~L, U32.is_eq(op, 0), U32.is_eq(op, 1), U32.is_eq(op, 2), U32.is_eq(op, 3),
        a, X.d(a, j), D.v(R, dd), D.t(R, dd), vs, pt,
        dual_v(~R, ~O, a, vs, SeedAt{j}, pt), d_right(~R, ~O, ~L, f0, o0, o1, a, j, vs, pt), f0)
    case B.E2{+op, +a, +b}:
      +da = dual(~R, ~O, a, vs, SeedAt{j}, pt)
      +db = dual(~R, ~O, b, vs, SeedAt{j}, pt)
      bin_ok(~R, ~O, ~L, U32.is_eq(op, 0), U32.is_eq(op, 1), U32.is_eq(op, 2), U32.is_eq(op, 3), U32.is_eq(op, 4), U32.is_eq(op, 5),
        a, b, X.d(a, j), X.d(b, j), D.v(R, da), D.t(R, da), D.v(R, db), D.t(R, db), vs, pt,
        dual_v(~R, ~O, a, vs, SeedAt{j}, pt), d_right(~R, ~O, ~L, f0, o0, o1, a, j, vs, pt),
        dual_v(~R, ~O, b, vs, SeedAt{j}, pt), d_right(~R, ~O, ~L, f0, o0, o1, b, j, vs, pt), f0)
    case B.ESel{+c, +a, +b}:
      +da = dual(~R, ~O, a, vs, SeedAt{j}, pt)
      +db = dual(~R, ~O, b, vs, SeedAt{j}, pt)
      +z = Nm.nz(R, O)(D.v(R, dual(~R, ~O, c, vs, SeedAt{j}, pt)))
      +lhs = D.t(R, Bool.pick(Dual<R>, z, da, db))
      %sel_ok(~R, ~O, c, X.d(a, j), X.d(b, j), vs, pt, f0) : {lhs == _ : R}
      %dual_v(~R, ~O, c, vs, SeedAt{j}, pt) : {lhs == Bool.pick(R, Nm.nz(R, O)(_), eval(~R, ~O, X.d(a, j), vs, pt), eval(~R, ~O, X.d(b, j), vs, pt)) : R}
      %d_right(~R, ~O, ~L, f0, o0, o1, a, j, vs, pt) : {lhs == Bool.pick(R, z, _, eval(~R, ~O, X.d(b, j), vs, pt)) : R}
      %d_right(~R, ~O, ~L, f0, o0, o1, b, j, vs, pt) : {lhs == Bool.pick(R, z, D.t(R, da), _) : R}
      pick.t(R, z, da, db)

# Instances ------------------------------------------------------------------
#
# The theorems are templates over any lawful carrier; checked here at Nat
# (truncated subtraction, neg 0, division as product: the laws ask for no
# more) and at Bool (or, and), whose arithmetic computes by cases.  F32 is
# not one (0·∞ is NaN, not 0): Dense/Dual.bend runs the same `dual` over
# F32 as a test, the gradient gate.

def nat.ops() -> Ops<Nat>:
  Ops{0n, 1n, c => 2n, u => U32.to_nat(u),
      x => 0n, x => 1n+x, x => x, x => x, x => x,
      x => y => Nat.add(x, y), x => y => Nat.sub(x, y), x => y => Nat.mul(x, y), x => y => Nat.mul(x, y),
      x => y => Nat.is_lt(x, y), x => y => Nat.is_le(x, y), x => Bool.not(Nat.is_eq(x, 0n))}

def nat.sub_zero_r(+x: Nat) -> {Nat.sub(x, 0n) == x : Nat}:
  match x:
    case 0n:
      {==}
    case 1n+p:
      {==}

def nat.laws() -> Laws<Nat, nat.ops()>:
  Laws{x => {==}, x => NL.Nat.add_zero_r(x), x => {==}, x => nat.sub_zero_r(x), {==},
       x => {==}, x => NL.Nat.mul_zero_r(x), x => NL.Nat.mul_one_l(x), x => NL.Nat.mul_one_r(x),
       x => {==}, x => NL.Nat.mul_one_r(x), {==}, {==}}

def bool.ops() -> Ops<Bool>:
  Ops{False{}, True{}, c => True{}, u => U32.is_eq(u, 0),
      x => x, x => Bool.not(x), x => x, x => x, x => x,
      x => y => Bool.or(x, y), x => y => Bool.or(x, y), x => y => Bool.and(x, y), x => y => Bool.and(x, y),
      x => y => Bool.and(Bool.not(x), y), x => y => Bool.or(Bool.not(x), y), x => x}

def bool.or_false_r(x: Bool) -> {Bool.or(x, False{}) == x : Bool}:
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

def bool.and_false_r(x: Bool) -> {Bool.and(x, False{}) == False{} : Bool}:
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

def bool.and_true_r(x: Bool) -> {Bool.and(x, True{}) == x : Bool}:
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

def bool.laws() -> Laws<Bool, bool.ops()>:
  Laws{x => {==}, x => bool.or_false_r(x), x => {==}, x => bool.or_false_r(x), {==},
       x => {==}, x => bool.and_false_r(x), x => {==}, x => bool.and_true_r(x),
       x => {==}, x => bool.and_true_r(x), {==}, {==}}

law check.d:
  for +f0: {F32.is_eq(0.0, 0.0) == True{} : Bool}
  for +o0: {F32.is_eq(1.0, 0.0) == False{} : Bool}
  for +o1: {F32.is_eq(1.0, 1.0) == True{} : Bool}
  for +e: B.Ex
  for +j: U32
  for +vs: List<&2, Nat>
  for +ws: List<&2, Bool>
  for +pt: List<&2, U32>
  {D.t(Nat, dual(~Nat, ~nat.ops(), e, vs, SeedAt{j}, pt)) == eval(~Nat, ~nat.ops(), X.d(e, j), vs, pt) : Nat}
  & {D.t(Bool, dual(~Bool, ~bool.ops(), e, ws, SeedAt{j}, pt)) == eval(~Bool, ~bool.ops(), X.d(e, j), ws, pt) : Bool}

def check.d(f0, o0, o1, e, j, vs, ws, pt):
  (d_right(~Nat, ~nat.ops(), ~nat.laws(), f0, o0, o1, e, j, vs, pt),
   d_right(~Bool, ~bool.ops(), ~bool.laws(), f0, o0, o1, e, j, ws, pt))

law check.dual_v:
  for +e: B.Ex
  for +vs: List<&2, Nat>
  for +s: Seed<Nat>
  for +ws: List<&2, Bool>
  for +sb: Seed<Bool>
  for +pt: List<&2, U32>
  {D.v(Nat, dual(~Nat, ~nat.ops(), e, vs, s, pt)) == eval(~Nat, ~nat.ops(), e, vs, pt) : Nat}
  & {D.v(Bool, dual(~Bool, ~bool.ops(), e, ws, sb, pt)) == eval(~Bool, ~bool.ops(), e, ws, pt) : Bool}

def check.dual_v(e, vs, s, ws, sb, pt):
  (dual_v(~Nat, ~nat.ops(), e, vs, s, pt), dual_v(~Bool, ~bool.ops(), e, ws, sb, pt))
