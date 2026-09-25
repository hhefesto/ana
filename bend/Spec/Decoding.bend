import Base
import ./Nat.bend as NL
import ./Order.bend as O

# Language/Decoding.agda: the sampler's denotation.  A trained model ends
# in a next-token distribution; decoding truncates it and renormalizes.
#
#   top-p (nucleus) is parameterized by a MASS TARGET and keeps at least
#   that mass by construction (nucleus_retains); top-k is parameterized by
#   a COUNT and has no distribution-independent mass floor: on the uniform
#   measure it keeps exactly the share k/v (topK_uniform).
#   min-p keeps a token iff its weight clears a fraction of the maximum:
#   the maximum always survives (minP_retains), a zero fraction keeps
#   everything (minP_conservative), and raising the fraction only sheds
#   mass (minP_antitone); min-p and top-p refine each other in neither
#   direction (the four examples at the end).
#
# Weights are Nat: an unnormalized finite measure over a common
# denominator.  Every definition branches on Base's Boolean order tests,
# exactly as executable code does, and the proofs case on those tests.
def mass(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      Nat.add(h, mass(t))

def pick(b: Bool, +x: Nat, r: List<&2, Nat>) -> List<&2, Nat>:
  match b:
    case True{}:
      [x]
    case False{}:
      x <> r

# keep elements until the kept mass (acc plus the current one) reaches the
# target; no subtraction
def nucleus(xs: List<&2, Nat>, +needed: Nat, +acc: Nat) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      pick(Nat.is_le(needed, Nat.add(acc, x)), x, nucleus(t, needed, Nat.add(acc, x)))

def topP(+needed: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  nucleus(xs, needed, 0n)

def topK(k: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  List.take(&2, Nat, xs, k)

# Order helpers ------------------------------------------------------------

law le.add_mono:
  for +c: Nat
  for +a: Nat
  for +b: Nat
  for h: O.Le(a, b)
  O.Le(Nat.add(c, a), Nat.add(c, b))

def le.add_mono(c, a, b, h):
  (+k, e) = h
  (k, Equal.trans(Nat, Nat.add(Nat.add(c, a), k), Nat.add(c, Nat.add(a, k)), Nat.add(c, b),
        NL.Nat.add_assoc(c, a, k), Equal.cong(Nat, Nat, n => Nat.add(c, n), Nat.add(a, k), b, e)))

law le.is_le:
  for +a: Nat
  for +b: Nat
  for h: O.Le(a, b)
  {Nat.is_le(a, b) == True{} : Bool}

def le.is_le(a, b, h):
  (+k, e) = h
  %e : {Nat.is_le(a, _) == True{} : Bool}
  O.is_le.of_le(a, k)

law le.of_eq:
  for +a: Nat
  for -b: Nat
  for +e: {a == b : Nat}
  O.Le(a, b)

def le.of_eq(a, b, e):
  %e : O.Le(a, _)
  NL.Le.refl(a)

# transport a bound along an equation
law le.rw:
  for -n: Nat
  for -a: Nat
  for -b: Nat
  for +e: {a == b : Nat}
  for h: O.Le(n, a)
  O.Le(n, b)

def le.rw(n, a, b, e, h):
  %e : O.Le(n, _)
  h

law le.rw_l:
  for -n: Nat
  for -a: Nat
  for -b: Nat
  for +e: {n == a : Nat}
  for h: O.Le(n, b)
  O.Le(a, b)

def le.rw_l(n, a, b, e, h):
  %e : O.Le(_, b)
  h

# a + n = a forces n = 0
law add.cancel_zero:
  for +a: Nat
  for +n: Nat
  for e: {Nat.add(a, n) == a : Nat}
  {n == 0n : Nat}

def add.cancel_zero(a, n, e):
  match a:
    case 0n:
      e
    case 1n+p:
      add.cancel_zero(p, n, Equal.cong(Nat, Nat, m => O.pred(m), 1n+Nat.add(p, n), 1n+p, e))

def is_zero(n: Nat) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+p:
      False{}

law add.zero_l_of_sum:
  for +k: Nat
  for +m: Nat
  for e: {Nat.add(k, m) == 0n : Nat}
  {k == 0n : Nat}

def add.zero_l_of_sum(k, m, e):
  match k:
    case 0n:
      {==}
    case 1n+p:
      Empty.absurd({1n+p == 0n : Nat}, O.bool.clash(Equal.cong(Nat, Bool, n => is_zero(n), 1n+Nat.add(p, m), 0n, e)))

law le.antisym:
  for +a: Nat
  for +b: Nat
  for h: O.Le(a, b)
  for g: O.Le(b, a)
  {a == b : Nat}

def le.antisym(a, b, h, g):
  (+k, e0) = h
  (+m, f) = g
  +e = {e0 : {Nat.add(a, k) == b : Nat}}
  +zero_k = add.zero_l_of_sum(k, m, add.cancel_zero(a, Nat.add(k, m),
    Equal.trans(Nat, Nat.add(a, Nat.add(k, m)), Nat.add(Nat.add(a, k), m), a,
      Equal.sym(Nat, Nat.add(Nat.add(a, k), m), Nat.add(a, Nat.add(k, m)), NL.Nat.add_assoc(a, k, m)),
      Equal.trans(Nat, Nat.add(Nat.add(a, k), m), Nat.add(b, m), a, Equal.cong(Nat, Nat, n => Nat.add(n, m), Nat.add(a, k), b, e), f))))
  %e : {a == _ : Nat}
  %Equal.sym(Nat, k, 0n, zero_k) : {a == Nat.add(a, _) : Nat}
  Equal.sym(Nat, Nat.add(a, 0n), a, NL.Nat.add_zero_r(a))

# Nucleus ----------------------------------------------------------------

def nucleus_retains.go(b: Bool, +needed: Nat, +acc: Nat, +x: Nat, r: List<&2, Nat>,
                       +hb: {Nat.is_le(needed, Nat.add(acc, x)) == b : Bool}, ih: O.Le(needed, Nat.add(Nat.add(acc, x), mass(r)))) ->
    O.Le(needed, Nat.add(acc, mass(pick(b, x, r)))):
  match b:
    case True{}:
      %Equal.sym(Nat, Nat.add(x, 0n), x, NL.Nat.add_zero_r(x)) : O.Le(needed, Nat.add(acc, _))
      O.le.of_is_le(needed, Nat.add(acc, x), hb)
    case False{}:
      %NL.Nat.add_assoc(acc, x, mass(r)) : O.Le(needed, _)
      ih

# whenever the target is reachable at all, the nucleus meets it
law nucleus_retains:
  for +xs: List<&2, Nat>
  for +needed: Nat
  for +acc: Nat
  for h: O.Le(needed, Nat.add(acc, mass(xs)))
  O.Le(needed, Nat.add(acc, mass(nucleus(xs, needed, acc))))

def nucleus_retains(xs, needed, acc, h):
  match xs:
    case Nil{}:
      h
    case +x <> t:
      h2 = le.rw(needed, Nat.add(acc, Nat.add(x, mass(t))), Nat.add(Nat.add(acc, x), mass(t)),
                  Equal.sym(Nat, Nat.add(Nat.add(acc, x), mass(t)), Nat.add(acc, Nat.add(x, mass(t))), NL.Nat.add_assoc(acc, x, mass(t))), h)
      nucleus_retains.go(Nat.is_le(needed, Nat.add(acc, x)), needed, acc, x, nucleus(t, needed, Nat.add(acc, x)), {==},
        nucleus_retains(t, needed, Nat.add(acc, x), h2))

law topP_retains:
  for +needed: Nat
  for +xs: List<&2, Nat>
  for h: O.Le(needed, mass(xs))
  O.Le(needed, mass(topP(needed, xs)))

def topP_retains(needed, xs, h):
  nucleus_retains(xs, needed, 0n, h)

def nucleus_bounded.go(b: Bool, +x: Nat, +r: List<&2, Nat>, +t: List<&2, Nat>, ih: O.Le(mass(r), mass(t))) ->
    O.Le(mass(pick(b, x, r)), Nat.add(x, mass(t))):
  match b:
    case True{}:
      %Equal.sym(Nat, Nat.add(x, 0n), x, NL.Nat.add_zero_r(x)) : O.Le(_, Nat.add(x, mass(t)))
      NL.Le.add_r(x, mass(t))
    case False{}:
      le.add_mono(x, mass(r), mass(t), ih)

# the nucleus never keeps more than there is
law nucleus_bounded:
  for +xs: List<&2, Nat>
  for +needed: Nat
  for +acc: Nat
  O.Le(mass(nucleus(xs, needed, acc)), mass(xs))

def nucleus_bounded(xs, needed, acc):
  match xs:
    case Nil{}:
      NL.Le.refl(0n)
    case +x <> t:
      nucleus_bounded.go(Nat.is_le(needed, Nat.add(acc, x)), x, nucleus(t, needed, Nat.add(acc, x)), t,
        nucleus_bounded(t, needed, Nat.add(acc, x)))

# a whole-mass target keeps the whole mass
law topP_conservative:
  for +xs: List<&2, Nat>
  {mass(topP(mass(xs), xs)) == mass(xs) : Nat}

def topP_conservative(xs):
  le.antisym(mass(topP(mass(xs), xs)), mass(xs), nucleus_bounded(xs, mass(xs), 0n), topP_retains(mass(xs), xs, NL.Le.refl(mass(xs))))

# a large enough count is the identity
law topK_all:
  for +k: Nat
  for +xs: List<&2, Nat>
  for h: O.Le(List.length(&2, Nat, xs), k)
  {topK(k, xs) == xs : List<&2, Nat>}

def topK_all(k, xs, h):
  match k xs:
    case 0n Nil{}:
      {==}
    case 1n+q Nil{}:
      {==}
    case 0n +x <> t:
      (m, e) = h
      Empty.absurd({topK(0n, x <> t) == x <> t : List<&2, Nat>}, O.bool.clash(Equal.cong(Nat, Bool, n => is_zero(n), 1n+Nat.add(List.length(&2, Nat, t), m), 0n, e)))
    case 1n+q +x <> t:
      %topK_all(q, t, O.le.pred(List.length(&2, Nat, t), q, h)) : {x <> topK(q, t) == x <> _ : List<&2, Nat>}
      {==}

law min.succ:
  for +k: Nat
  for +v: Nat
  {Nat.min(1n+k, 1n+v) == 1n+Nat.min(k, v) : Nat}

# Base's Nat.min is structural (2.0.27), so this is its successor case
def min.succ(k, v):
  {==}

# On the uniform measure (v tokens of weight u), top-k keeps exactly
# min(k, v) * u of the total v * u: the share k/v, which no floor bounds.
law topK_uniform:
  for +k: Nat
  for +v: Nat
  for +u: Nat
  {mass(topK(k, List.replicate(Nat, v, u))) == Nat.mul(Nat.min(k, v), u) : Nat}

def topK_uniform(k, v, u):
  match k v:
    case 0n 0n:
      {==}
    case 0n 1n+w:
      {==}
    case 1n+q 0n:
      {==}
    case 1n+q 1n+w:
      %Equal.sym(Nat, Nat.min(1n+q, 1n+w), 1n+Nat.min(q, w), min.succ(q, w)) : {Nat.add(u, mass(topK(q, List.replicate(Nat, w, u)))) == Nat.mul(_, u) : Nat}
      %Equal.sym(Nat, mass(topK(q, List.replicate(Nat, w, u))), Nat.mul(Nat.min(q, w), u), topK_uniform(q, w, u)) : {Nat.add(u, _) == Nat.mul(1n+Nat.min(q, w), u) : Nat}
      {==}

# min-p -------------------------------------------------------------------

def maxW(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> t:
      Nat.max(x, maxW(t))

def keep.pick(b: Bool, +x: Nat, r: List<&2, Nat>) -> List<&2, Nat>:
  match b:
    case True{}:
      x <> r
    case False{}:
      r

# keep a token iff threshold <= den * weight (division-free)
def keep(xs: List<&2, Nat>, +t: Nat, +den: Nat) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> rest:
      keep.pick(Nat.is_le(t, Nat.mul(den, x)), x, keep(rest, t, den))

# the fraction num/den of the maximum weight is the threshold
def minP(+num: Nat, +den: Nat, +xs: List<&2, Nat>) -> List<&2, Nat>:
  keep(xs, Nat.mul(num, maxW(xs)), den)

law le.trans_bool:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for +h: {Nat.is_le(a, b) == True{} : Bool}
  for +g: {Nat.is_le(b, c) == True{} : Bool}
  {Nat.is_le(a, c) == True{} : Bool}

def le.trans_bool(a, b, c, h, g):
  le.is_le(a, c, NL.Le.trans(a, b, c, O.le.of_is_le(a, b, h), O.le.of_is_le(b, c, g)))

law is_le.zero:
  for +n: Nat
  {Nat.is_le(0n, n) == True{} : Bool}

def is_le.zero(n):
  match n:
    case 0n:
      {==}
    case 1n+p:
      {==}

law mul.mono:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for h: O.Le(a, b)
  O.Le(Nat.mul(a, c), Nat.mul(b, c))

def mul.mono(a, b, c, h):
  (+k, e) = h
  (Nat.mul(k, c), Equal.trans(Nat, Nat.add(Nat.mul(a, c), Nat.mul(k, c)), Nat.mul(Nat.add(a, k), c), Nat.mul(b, c),
     Equal.sym(Nat, Nat.mul(Nat.add(a, k), c), Nat.add(Nat.mul(a, c), Nat.mul(k, c)), NL.Nat.distrib_r(a, k, c)),
     Equal.cong(Nat, Nat, n => Nat.mul(n, c), Nat.add(a, k), b, e)))

law pass.rw:
  for -t: Nat
  for -den: Nat
  for -x: Nat
  for -M: Nat
  for +e: {x == M : Nat}
  for +p: {Nat.is_le(t, Nat.mul(den, M)) == True{} : Bool}
  {Nat.is_le(t, Nat.mul(den, x)) == True{} : Bool}

def pass.rw(t, den, x, M, e, p):
  %Equal.sym(Nat, x, M, e) : {Nat.is_le(t, Nat.mul(den, _)) == True{} : Bool}
  p

def keep_max.go(s: Bool, k: Bool, +x: Nat, +m: Nat, +t: Nat, +den: Nat, +M: Nat, +r: List<&2, Nat>,
                +hk: {Nat.is_le(t, Nat.mul(den, x)) == k : Bool},
                +pass: {Nat.is_le(t, Nat.mul(den, M)) == True{} : Bool},
                +eq: {Bool.pick(Nat, s, m, x) == M : Nat},
                ih: {m == M : Nat} -> O.Le(M, mass(r))) ->
    O.Le(M, mass(keep.pick(k, x, r))):
  match s k:
    case False{} True{}:
      %eq : O.Le(_, Nat.add(x, mass(r)))
      NL.Le.add_r(x, mass(r))
    case False{} False{}:
      Empty.absurd(O.Le(M, mass(r)), O.bool.clash(Equal.trans(Bool, False{}, Nat.is_le(t, Nat.mul(den, x)), True{},
        Equal.sym(Bool, Nat.is_le(t, Nat.mul(den, x)), False{}, hk), pass.rw(t, den, x, M, eq, pass))))
    case True{} True{}:
      NL.Le.trans(M, mass(r), Nat.add(x, mass(r)), ih(eq), NL.Le.add_l(mass(r), x))
    case True{} False{}:
      ih(eq)

# Base's Nat.max is structural (2.0.27); keep_max reasons by the pick it
# equals: the larger, and the right one on a tie
def max.pick.go(s: Bool, +ap: Nat, +bp: Nat, ih: {Nat.max(ap, bp) == Bool.pick(Nat, s, bp, ap) : Nat}) ->
    {1n+Nat.max(ap, bp) == Bool.pick(Nat, s, 1n+bp, 1n+ap) : Nat}:
  match s:
    case True{}:
      Equal.cong(Nat, Nat, n => 1n+n, Nat.max(ap, bp), bp, ih)
    case False{}:
      Equal.cong(Nat, Nat, n => 1n+n, Nat.max(ap, bp), ap, ih)

law max.pick:
  for +a: Nat
  for +b: Nat
  {Nat.max(a, b) == Bool.pick(Nat, Nat.is_lt(a, b), b, a) : Nat}

def max.pick(a, b):
  match a b:
    case 0n 0n:
      {==}
    case 0n 1n+bp:
      {==}
    case 1n+ap 0n:
      {==}
    case 1n+ap 1n+bp:
      max.pick.go(Nat.is_lt(ap, bp), ap, bp, max.pick(ap, bp))

# the maximum survives filtering whenever it passes its own test
law keep_max:
  for +xs: List<&2, Nat>
  for +t: Nat
  for +den: Nat
  for +M: Nat
  for +pass: {Nat.is_le(t, Nat.mul(den, M)) == True{} : Bool}
  for +eq: {maxW(xs) == M : Nat}
  O.Le(M, mass(keep(xs, t, den)))

def keep_max(xs, t, den, M, pass, eq):
  match xs:
    case Nil{}:
      %eq : O.Le(_, 0n)
      NL.Le.refl(0n)
    case +x <> rest:
      keep_max.go(Nat.is_lt(x, maxW(rest)), Nat.is_le(t, Nat.mul(den, x)), x, maxW(rest), t, den, M, keep(rest, t, den),
        {==}, pass,
        Equal.trans(Nat, Bool.pick(Nat, Nat.is_lt(x, maxW(rest)), maxW(rest), x), Nat.max(x, maxW(rest)), M,
          Equal.sym(Nat, Nat.max(x, maxW(rest)), Bool.pick(Nat, Nat.is_lt(x, maxW(rest)), maxW(rest), x), max.pick(x, maxW(rest))), eq),
        e => keep_max(rest, t, den, M, pass, e))

# the argmax always survives min-p when num <= den, so renormalization is
# total: min-p has no empty-support case
law minP_retains:
  for +num: Nat
  for +den: Nat
  for +xs: List<&2, Nat>
  for h: O.Le(num, den)
  O.Le(maxW(xs), mass(minP(num, den, xs)))

law mul.comm_mono:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for h: O.Le(a, b)
  O.Le(Nat.mul(c, a), Nat.mul(c, b))

def mul.comm_mono(a, b, c, h):
  le.rw(Nat.mul(c, a), Nat.mul(b, c), Nat.mul(c, b), NL.Nat.mul_comm(b, c),
    le.rw_l(Nat.mul(a, c), Nat.mul(c, a), Nat.mul(b, c), NL.Nat.mul_comm(a, c), mul.mono(a, b, c, h)))

def minP_retains(num, den, xs, h):
  keep_max(xs, Nat.mul(num, maxW(xs)), den, maxW(xs),
    le.is_le(Nat.mul(num, maxW(xs)), Nat.mul(den, maxW(xs)),
      le.rw(Nat.mul(num, maxW(xs)), Nat.mul(maxW(xs), den), Nat.mul(den, maxW(xs)), NL.Nat.mul_comm(maxW(xs), den),
        le.rw_l(Nat.mul(maxW(xs), num), Nat.mul(num, maxW(xs)), Nat.mul(maxW(xs), den), NL.Nat.mul_comm(maxW(xs), num),
          mul.comm_mono(num, den, maxW(xs), h)))),
    {==})

def keep_zero.go(b: Bool, +den: Nat, +x: Nat, +rest: List<&2, Nat>,
                 +hb: {Nat.is_le(0n, Nat.mul(den, x)) == b : Bool},
                 +ih: {keep(rest, 0n, den) == rest : List<&2, Nat>}) ->
    {keep.pick(b, x, keep(rest, 0n, den)) == x <> rest : List<&2, Nat>}:
  match b:
    case True{}:
      %ih : {x <> keep(rest, 0n, den) == x <> _ : List<&2, Nat>}
      {==}
    case False{}:
      Empty.absurd({keep(rest, 0n, den) == x <> rest : List<&2, Nat>}, O.bool.clash(Equal.trans(Bool, False{}, Nat.is_le(0n, Nat.mul(den, x)), True{},
        Equal.sym(Bool, Nat.is_le(0n, Nat.mul(den, x)), False{}, hb), is_le.zero(Nat.mul(den, x)))))

law keep_zero:
  for +xs: List<&2, Nat>
  for +den: Nat
  {keep(xs, 0n, den) == xs : List<&2, Nat>}

def keep_zero(xs, den):
  match xs:
    case Nil{}:
      {==}
    case +x <> rest:
      keep_zero.go(Nat.is_le(0n, Nat.mul(den, x)), den, x, rest, {==}, keep_zero(rest, den))

# a zero fraction keeps everything
law minP_conservative:
  for +den: Nat
  for +xs: List<&2, Nat>
  {minP(0n, den, xs) == xs : List<&2, Nat>}

def minP_conservative(den, xs):
  keep_zero(xs, den)

def keep_antitone.go(k2: Bool, k: Bool, +x: Nat, +t: Nat, +t2: Nat, +den: Nat, +r2: List<&2, Nat>, +r: List<&2, Nat>,
                     +h2: {Nat.is_le(t2, Nat.mul(den, x)) == k2 : Bool},
                     +h1: {Nat.is_le(t, Nat.mul(den, x)) == k : Bool},
                     +h: {Nat.is_le(t, t2) == True{} : Bool},
                     ih: O.Le(mass(r2), mass(r))) ->
    O.Le(mass(keep.pick(k2, x, r2)), mass(keep.pick(k, x, r))):
  match k2 k:
    case True{} True{}:
      le.add_mono(x, mass(r2), mass(r), ih)
    case True{} False{}:
      Empty.absurd(O.Le(Nat.add(x, mass(r2)), mass(r)), O.bool.clash(Equal.trans(Bool, False{}, Nat.is_le(t, Nat.mul(den, x)), True{},
        Equal.sym(Bool, Nat.is_le(t, Nat.mul(den, x)), False{}, h1), le.trans_bool(t, t2, Nat.mul(den, x), h, h2))))
    case False{} True{}:
      NL.Le.trans(mass(r2), mass(r), Nat.add(x, mass(r)), ih, NL.Le.add_l(mass(r), x))
    case False{} False{}:
      ih

law keep_antitone:
  for +xs: List<&2, Nat>
  for +t: Nat
  for +t2: Nat
  for +den: Nat
  for +h: {Nat.is_le(t, t2) == True{} : Bool}
  O.Le(mass(keep(xs, t2, den)), mass(keep(xs, t, den)))

def keep_antitone(xs, t, t2, den, h):
  match xs:
    case Nil{}:
      NL.Le.refl(0n)
    case +x <> rest:
      keep_antitone.go(Nat.is_le(t2, Nat.mul(den, x)), Nat.is_le(t, Nat.mul(den, x)), x, t, t2, den,
        keep(rest, t2, den), keep(rest, t, den), {==}, {==}, h, keep_antitone(rest, t, t2, den, h))

# raising the fraction only sheds mass
law minP_antitone:
  for +num: Nat
  for +num2: Nat
  for +den: Nat
  for +xs: List<&2, Nat>
  for h: O.Le(num, num2)
  O.Le(mass(minP(num2, den, xs)), mass(minP(num, den, xs)))

def minP_antitone(num, num2, den, xs, h):
  keep_antitone(xs, Nat.mul(num, maxW(xs)), Nat.mul(num2, maxW(xs)), den,
    le.is_le(Nat.mul(num, maxW(xs)), Nat.mul(num2, maxW(xs)), mul.mono(num, num2, maxW(xs), h)))

# Neither truncation refines the other, by computation: on (5, 5, 1) a
# mass-10 nucleus drops the 1 while min-p at 1/10 keeps it; on (5, 3) a
# mass-8 nucleus keeps the 3 while min-p at 9/10 drops it.
law minP_keeps_tail:
  {minP(1n, 10n, [5n, 5n, 1n]) == [5n, 5n, 1n] : List<&2, Nat>}

def minP_keeps_tail():
  {==}

law topP_drops_tail:
  {topP(10n, [5n, 5n, 1n]) == [5n, 5n] : List<&2, Nat>}

def topP_drops_tail():
  {==}

law topP_keeps_runner_up:
  {topP(8n, [5n, 3n]) == [5n, 3n] : List<&2, Nat>}

def topP_keeps_runner_up():
  {==}

law minP_drops_runner_up:
  {minP(9n, 10n, [5n, 3n]) == [5n] : List<&2, Nat>}

def minP_drops_runner_up():
  {==}
