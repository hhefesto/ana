import Base
import ./Nat.bend as NL
import ./Order.bend as O
import ./Decoding.bend as D

# Language/SpeculativeDecoding.agda: exactness of speculative decoding,
# division-free.  A draft proposes x ~ q, the target accepts with
# probability min(1, p(x)/q(x)) and on rejection resamples from the
# residual (p - min(p, q)) / (1 - alpha).  Unnormalized, the accept branch
# delivers min(p, q) at x and the reject branch p monus q, and exactness is
# the pointwise identity min(p, q) + (p monus q) = p, unconditional in Nat.
#
#   exact             the merged accept/residual measure is p, pointwise
#   mass_exact        acceptance mass + residual mass = target mass
#   residual_balanced with equal totals the two one-sided residuals have
#                     equal mass: the total-variation distance
#
# Measures over the same vocabulary are length-indexed vectors, so target
# and draft share their index by type.
type VNil is Data:
  VNil{}

type VCons<-T: Data> is Data:
  VCons{h: Nat, t: T}

def Vec(n: Nat) -> Data:
  match n:
    case 0n:
      VNil
    case 1n+p:
      VCons<Vec(p)>

def vmass(n: Nat, v: Vec(n)) -> Nat:
  match n v:
    case 0n VNil{}:
      0n
    case 1n+p VCons{h, t}:
      Nat.add(h, vmass(p, t))

def accepted(n: Nat, p: Vec(n), q: Vec(n)) -> Vec(n):
  match n p q:
    case 0n VNil{} VNil{}:
      VNil{}
    case 1n+k VCons{x, ps} VCons{y, qs}:
      VCons{Nat.min(x, y), accepted(k, ps, qs)}

def residual(n: Nat, p: Vec(n), q: Vec(n)) -> Vec(n):
  match n p q:
    case 0n VNil{} VNil{}:
      VNil{}
    case 1n+k VCons{x, ps} VCons{y, qs}:
      VCons{Nat.sub(x, y), residual(k, ps, qs)}

def vadd(n: Nat, p: Vec(n), q: Vec(n)) -> Vec(n):
  match n p q:
    case 0n VNil{} VNil{}:
      VNil{}
    case 1n+k VCons{x, ps} VCons{y, qs}:
      VCons{Nat.add(x, y), vadd(k, ps, qs)}

law min.succ:
  for +k: Nat
  for +v: Nat
  {Nat.min(1n+k, 1n+v) == 1n+Nat.min(k, v) : Nat}

def min.succ(k, v):
  D.min.succ(k, v)

# the one-token core: min(m, k) + (m monus k) = m
law min_monus:
  for +m: Nat
  for +k: Nat
  {Nat.add(Nat.min(m, k), Nat.sub(m, k)) == m : Nat}

def min_monus(m, k):
  match m k:
    case 0n 0n:
      {==}
    case 0n 1n+q:
      {==}
    case 1n+p 0n:
      {==}
    case 1n+p 1n+q:
      %Equal.sym(Nat, Nat.min(1n+p, 1n+q), 1n+Nat.min(p, q), min.succ(p, q)) : {Nat.add(_, Nat.sub(p, q)) == 1n+p : Nat}
      %min_monus(p, q) : {1n+Nat.add(Nat.min(p, q), Nat.sub(p, q)) == 1n+_ : Nat}
      {==}

# exactness: accepted and residual mass reconstitute the target pointwise
law exact:
  for +n: Nat
  for +p: Vec(n)
  for +q: Vec(n)
  {vadd(n, accepted(n, p, q), residual(n, p, q)) == p : Vec(n)}

def exact(n, p, q):
  match n p q:
    case 0n VNil{} VNil{}:
      {==}
    case 1n+k VCons{+x, +ps} VCons{+y, +qs}:
      %exact(k, ps, qs) : {VCons{Nat.add(Nat.min(x, y), Nat.sub(x, y)), vadd(k, accepted(k, ps, qs), residual(k, ps, qs))} == VCons{x, _} : Vec(1n+k)}
      %min_monus(x, y) : {VCons{Nat.add(Nat.min(x, y), Nat.sub(x, y)), vadd(k, accepted(k, ps, qs), residual(k, ps, qs))} == VCons{_, vadd(k, accepted(k, ps, qs), residual(k, ps, qs))} : Vec(1n+k)}
      {==}

law interchange:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for +d: Nat
  {Nat.add(Nat.add(a, b), Nat.add(c, d)) == Nat.add(Nat.add(a, c), Nat.add(b, d)) : Nat}

def interchange(a, b, c, d):
  NL.Nat.interchange(a, b, c, d)

# totals: acceptance rate plus rejection rate is one
law mass_exact:
  for +n: Nat
  for +p: Vec(n)
  for +q: Vec(n)
  {Nat.add(vmass(n, accepted(n, p, q)), vmass(n, residual(n, p, q))) == vmass(n, p) : Nat}

def mass_exact(n, p, q):
  match n p q:
    case 0n VNil{} VNil{}:
      {==}
    case 1n+k VCons{+x, +ps} VCons{+y, +qs}:
      +a = Nat.min(x, y)
      +r = Nat.sub(x, y)
      +ma = vmass(k, accepted(k, ps, qs))
      +mr = vmass(k, residual(k, ps, qs))
      %Equal.sym(Nat, Nat.add(Nat.add(a, ma), Nat.add(r, mr)), Nat.add(Nat.add(a, r), Nat.add(ma, mr)), interchange(a, ma, r, mr)) : {_ == Nat.add(x, vmass(k, ps)) : Nat}
      %Equal.sym(Nat, Nat.add(a, r), x, min_monus(x, y)) : {Nat.add(_, Nat.add(ma, mr)) == Nat.add(x, vmass(k, ps)) : Nat}
      %mass_exact(k, ps, qs) : {Nat.add(x, Nat.add(ma, mr)) == Nat.add(x, _) : Nat}
      {==}

law min_comm:
  for +a: Nat
  for +b: Nat
  {Nat.min(a, b) == Nat.min(b, a) : Nat}

def min_comm(a, b):
  match a b:
    case 0n 0n:
      {==}
    case 0n 1n+q:
      {==}
    case 1n+p 0n:
      {==}
    case 1n+p 1n+q:
      %Equal.sym(Nat, Nat.min(1n+p, 1n+q), 1n+Nat.min(p, q), min.succ(p, q)) : {_ == Nat.min(1n+q, 1n+p) : Nat}
      %Equal.sym(Nat, Nat.min(1n+q, 1n+p), 1n+Nat.min(q, p), min.succ(q, p)) : {1n+Nat.min(p, q) == _ : Nat}
      %min_comm(p, q) : {1n+Nat.min(p, q) == 1n+_ : Nat}
      {==}

law accepted_comm:
  for +n: Nat
  for +p: Vec(n)
  for +q: Vec(n)
  {accepted(n, p, q) == accepted(n, q, p) : Vec(n)}

def accepted_comm(n, p, q):
  match n p q:
    case 0n VNil{} VNil{}:
      {==}
    case 1n+k VCons{+x, +ps} VCons{+y, +qs}:
      %accepted_comm(k, ps, qs) : {VCons{Nat.min(x, y), accepted(k, ps, qs)} == VCons{Nat.min(y, x), _} : Vec(1n+k)}
      %min_comm(x, y) : {VCons{Nat.min(x, y), accepted(k, ps, qs)} == VCons{_, accepted(k, ps, qs)} : Vec(1n+k)}
      {==}

law add_cancel:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for e: {Nat.add(a, b) == Nat.add(a, c) : Nat}
  {b == c : Nat}

def add_cancel(a, b, c, e):
  match a:
    case 0n:
      e
    case 1n+p:
      add_cancel(p, b, c, Equal.cong(Nat, Nat, m => O.pred(m), 1n+Nat.add(p, b), 1n+Nat.add(p, c), e))

# With equal totals the two one-sided residuals carry the same mass: the
# total-variation distance, so the acceptance rate is 1 - TV(p, q).
law residual_balanced:
  for +n: Nat
  for +p: Vec(n)
  for +q: Vec(n)
  for +h: {vmass(n, p) == vmass(n, q) : Nat}
  {vmass(n, residual(n, p, q)) == vmass(n, residual(n, q, p)) : Nat}

def residual_balanced.go(+n: Nat, +p: Vec(n), +q: Vec(n)) ->
    {Nat.add(vmass(n, accepted(n, p, q)), vmass(n, residual(n, q, p))) == vmass(n, q) : Nat}:
  %accepted_comm(n, q, p) : {Nat.add(vmass(n, _), vmass(n, residual(n, q, p))) == vmass(n, q) : Nat}
  mass_exact(n, q, p)

def residual_balanced(n, p, q, h):
  add_cancel(vmass(n, accepted(n, p, q)), vmass(n, residual(n, p, q)), vmass(n, residual(n, q, p)),
    Equal.trans(Nat, Nat.add(vmass(n, accepted(n, p, q)), vmass(n, residual(n, p, q))), vmass(n, p),
      Nat.add(vmass(n, accepted(n, p, q)), vmass(n, residual(n, q, p))),
      mass_exact(n, p, q),
      Equal.trans(Nat, vmass(n, p), vmass(n, q), Nat.add(vmass(n, accepted(n, p, q)), vmass(n, residual(n, q, p))), h,
        Equal.sym(Nat, Nat.add(vmass(n, accepted(n, p, q)), vmass(n, residual(n, q, p))), vmass(n, q),
          residual_balanced.go(n, p, q)))))
