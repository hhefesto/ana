import Base
import ./Nat.bend as NL

# The order on Nat, two ways: Le (a witness k with x + k = y, good for
# arithmetic) and Base's Boolean tests (Nat.is_le, Nat.is_lt, which the
# executable code branches on).  The lemmas here connect them, so a spec can
# reason with witnesses about definitions that compute with Booleans.

def Le(x: Nat, y: Nat) -> Type:
  NL.Le(x, y)

def pred(n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      p

law le.succ:
  for +x: Nat
  for +y: Nat
  for h: Le(x, y)
  Le(1n+x, 1n+y)

def le.succ(x, y, h):
  (k, e) = h
  (k, Equal.cong(Nat, Nat, n => 1n+n, Nat.add(x, k), y, e))

law le.pred:
  for +x: Nat
  for +y: Nat
  for h: Le(1n+x, 1n+y)
  Le(x, y)

def le.pred(x, y, h):
  (k, e) = h
  (k, Equal.cong(Nat, Nat, n => pred(n), 1n+Nat.add(x, k), 1n+y, e))

def disc(b: Bool) -> Type:
  match b:
    case True{}:
      Unit
    case False{}:
      Empty

# False = True refutes anything
law bool.clash:
  for e: {False{} == True{} : Bool}
  Empty

def bool.clash(e):
  %Equal.sym(Bool, False{}, True{}, e) : disc(_)
  Unit{}

law bool.clash2:
  for e: {True{} == False{} : Bool}
  Empty

def bool.clash2(e):
  %e : disc(_)
  Unit{}

# Base's test, read as a witness
law le.of_is_le:
  for +x: Nat
  for +y: Nat
  for +h: {Nat.is_le(x, y) == True{} : Bool}
  Le(x, y)

def le.of_is_le(x, y, h):
  match x y:
    case 0n _:
      NL.Le.zero(y)
    case 1n+p 0n:
      Empty.absurd(Le(1n+p, 0n), bool.clash(h))
    case 1n+p 1n+q:
      le.succ(p, q, le.of_is_le(p, q, h))

law is_le.of_le:
  for +x: Nat
  for +k: Nat
  {Nat.is_le(x, Nat.add(x, k)) == True{} : Bool}

def is_le.of_le(x, k):
  match x:
    case 0n:
      match k:
        case 0n:
          {==}
        case 1n+q:
          {==}
    case 1n+p:
      is_le.of_le(p, k)
