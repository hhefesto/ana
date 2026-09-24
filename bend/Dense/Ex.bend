import Base

# Scalar expressions (base.bend's Ex, whose meaning is Ex.eval) built the
# way the model's scalar code computes them (Ops.bend), and their
# derivatives. Every combinator mirrors its F32 counterpart step for step,
# so an einsum of these expressions means what the tree code computes.

def x(k: U32) -> Ex:
  EIn{k}

def ix(i: U32) -> Ex:
  EIx{i}

def k(c: F32) -> Ex:
  EK{c}

# Simplifying constructors: 0 and 1 fold, so a derivative that vanishes is
# the constant 0 (and its einsum is dropped). Each rewrite is an identity
# of the reals; the F32 ones hold for every finite argument.
def is0(+e: Ex) -> Bool:
  match e:
    case EK{c}:
      F32.is_eq(c, 0.0)
    case _:
      False{}

def is1(+e: Ex) -> Bool:
  match e:
    case EK{c}:
      F32.is_eq(c, 1.0)
    case _:
      False{}

def add.if(z: Bool, w: Bool, a: Ex, b: Ex) -> Ex:
  match z w:
    case True{} _:
      b
    case False{} True{}:
      a
    case False{} False{}:
      E2{0, a, b}

def add(+a: Ex, +b: Ex) -> Ex:
  add.if(is0(a), is0(b), a, b)

def neg.if(z: Bool, a: Ex) -> Ex:
  match z:
    case True{}:
      a
    case False{}:
      E1{0, a}

def neg(+a: Ex) -> Ex:
  neg.if(is0(a), a)

def sub.if(z: Bool, w: Bool, a: Ex, b: Ex) -> Ex:
  match z w:
    case _ True{}:
      a
    case True{} False{}:
      neg(b)
    case False{} False{}:
      E2{1, a, b}

def sub(+a: Ex, +b: Ex) -> Ex:
  sub.if(is0(a), is0(b), a, b)

def mul.if(z: Bool, o1: Bool, o2: Bool, a: Ex, b: Ex) -> Ex:
  match z o1 o2:
    case True{} _ _:
      k(0.0)
    case False{} True{} _:
      b
    case False{} False{} True{}:
      a
    case False{} False{} False{}:
      E2{2, a, b}

def mul(+a: Ex, +b: Ex) -> Ex:
  mul.if(Bool.or(is0(a), is0(b)), is1(a), is1(b), a, b)

def div.if(z: Bool, o: Bool, a: Ex, b: Ex) -> Ex:
  match z o:
    case True{} _:
      k(0.0)
    case False{} True{}:
      a
    case False{} False{}:
      E2{3, a, b}

def div(+a: Ex, +b: Ex) -> Ex:
  div.if(is0(a), is1(b), a, b)

def exp(a: Ex) -> Ex:
  E1{1, a}

def log(a: Ex) -> Ex:
  E1{2, a}

def sqrt(a: Ex) -> Ex:
  E1{3, a}

def abs(a: Ex) -> Ex:
  E1{4, a}

def lt(a: Ex, b: Ex) -> Ex:
  E2{6, a, b}

def le(a: Ex, b: Ex) -> Ex:
  E2{7, a, b}

def sel.if(z: Bool, c: Ex, a: Ex, b: Ex) -> Ex:
  match z:
    case True{}:
      k(0.0)
    case False{}:
      ESel{c, a, b}

def sel(+c: Ex, +a: Ex, +b: Ex) -> Ex:
  sel.if(Bool.and(is0(a), is0(b)), c, a, b)

# F32.max a b = (a < b ? b : a), F32.min a b = (a < b ? a : b)
def max(+a: Ex, +b: Ex) -> Ex:
  sel(lt(a, b), b, a)

def min(+a: Ex, +b: Ex) -> Ex:
  sel(lt(a, b), a, b)

def eq(+a: Ex, +b: Ex) -> Ex:
  E2{2, le(a, b), le(b, a)}

def inf() -> F32:
  F32.div(1.0, 0.0)

# Ops.bend, expression for expression ------------------------------------

def log1p(+u: Ex) -> Ex:
  +w = add(k(1.0), u)
  sel(eq(w, k(1.0)), u, div(mul(log(w), u), sub(w, k(1.0))))

def log_sigmoid(+z: Ex) -> Ex:
  neg(add(max(neg(z), k(0.0)), log1p(exp(neg(abs(z))))))

def sigmoid(+z: Ex) -> Ex:
  sel(le(k(0.0), z), div(k(1.0), add(k(1.0), exp(neg(z)))),
    div(exp(z), add(k(1.0), exp(z))))

def silu(+z: Ex) -> Ex:
  mul(z, sigmoid(z))

def cap() -> F32:
  F32.neg(1.0e-4)

def rglru_log_gate(+z: Ex, +lam: Ex) -> Ex:
  min(k(cap()), mul(mul(k(8.0), sigmoid(z)), log_sigmoid(lam)))

def rglru_write_scale(+la: Ex) -> Ex:
  sqrt(sub(k(1.0), exp(mul(k(2.0), min(k(cap()), la)))))

# rms_norm's scale from the sum of squares over n: 1 / sqrt(ss / n + 1e-5)
def rms_scale(+ss: Ex, +n: F32) -> Ex:
  div(k(1.0), sqrt(add(div(ss, k(n)), k(1.0e-5))))

# Derivatives --------------------------------------------------------------
#
# d e / d (input j), as an expression: the chain rule through each op, the
# select's condition held (it is piecewise constant), lt/le and indices
# constant.

def d.un(+op: U32, +a: Ex, +da: Ex) -> Ex:
  Bool.pick(Ex, U32.is_eq(op, 0), neg(da),
  Bool.pick(Ex, U32.is_eq(op, 1), mul(exp(a), da),
  Bool.pick(Ex, U32.is_eq(op, 2), div(da, a),
  Bool.pick(Ex, U32.is_eq(op, 3), div(da, mul(k(2.0), sqrt(a))),
    sel(lt(a, k(0.0)), neg(da), da)))))

def d.bin(+op: U32, +a: Ex, +b: Ex, +da: Ex, +db: Ex) -> Ex:
  Bool.pick(Ex, U32.is_eq(op, 0), add(da, db),
  Bool.pick(Ex, U32.is_eq(op, 1), sub(da, db),
  Bool.pick(Ex, U32.is_eq(op, 2), add(mul(da, b), mul(a, db)),
  Bool.pick(Ex, U32.is_eq(op, 3), sub(div(da, b), div(mul(a, db), mul(b, b))),
  Bool.pick(Ex, U32.is_eq(op, 4), sel(lt(b, a), da, db),
  Bool.pick(Ex, U32.is_eq(op, 5), sel(lt(a, b), da, db), k(0.0)))))))

def d(e: Ex, +j: U32) -> Ex:
  match e:
    case EIn{i}:
      Bool.pick(Ex, U32.is_eq(i, j), k(1.0), k(0.0))
    case EIx{i}:
      k(0.0)
    case EK{c}:
      k(0.0)
    case E1{op, +a}:
      d.un(op, a, d(a, j))
    case E2{op, +a, +b}:
      d.bin(op, a, b, d(a, j), d(b, j))
    case ESel{c, a, b}:
      sel(c, d(a, j), d(b, j))
