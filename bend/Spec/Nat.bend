import Base

# Nat as a commutative semiring: the laws Base does not prove, by induction.
# Decoding, SpeculativeDecoding and Sink state their measures over Nat
# (weights over a common denominator), and Algebra instantiates the
# abstract Semiring at Nat to show the structure is inhabited.

law Nat.add_zero_r:
  for +x: Nat
  {Nat.add(x, 0n) == x : Nat}

def Nat.add_zero_r(x):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Nat.add_zero_r(p) : {1n+Nat.add(p, 0n) == 1n+_ : Nat}
      {==}

law Nat.add_succ_r:
  for +x: Nat
  for +y: Nat
  {Nat.add(x, 1n+y) == 1n+Nat.add(x, y) : Nat}

def Nat.add_succ_r(x, y):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Nat.add_succ_r(p, y) : {1n+Nat.add(p, 1n+y) == 1n+_ : Nat}
      {==}

law Nat.add_comm:
  for +x: Nat
  for +y: Nat
  {Nat.add(x, y) == Nat.add(y, x) : Nat}

def Nat.add_comm(x, y):
  match x:
    case 0n:
      %Nat.add_zero_r(y) : {_ == Nat.add(y, 0n) : Nat}
      {==}
    case 1n+p:
      %Equal.sym(Nat, Nat.add(y, 1n+p), 1n+Nat.add(y, p), Nat.add_succ_r(y, p)) : {1n+Nat.add(p, y) == _ : Nat}
      %Nat.add_comm(p, y) : {1n+Nat.add(p, y) == 1n+_ : Nat}
      {==}

law Nat.add_assoc:
  for +x: Nat
  for +y: Nat
  for +z: Nat
  {Nat.add(Nat.add(x, y), z) == Nat.add(x, Nat.add(y, z)) : Nat}

def Nat.add_assoc(x, y, z):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Nat.add_assoc(p, y, z) : {1n+Nat.add(Nat.add(p, y), z) == 1n+_ : Nat}
      {==}

# (a + b) + (c + d) = (a + c) + (b + d)
law Nat.interchange:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for +d: Nat
  {Nat.add(Nat.add(a, b), Nat.add(c, d)) == Nat.add(Nat.add(a, c), Nat.add(b, d)) : Nat}

def Nat.interchange(a, b, c, d):
  %Equal.sym(Nat, Nat.add(Nat.add(a, b), Nat.add(c, d)), Nat.add(a, Nat.add(b, Nat.add(c, d))), Nat.add_assoc(a, b, Nat.add(c, d))) : {_ == Nat.add(Nat.add(a, c), Nat.add(b, d)) : Nat}
  %Equal.sym(Nat, Nat.add(Nat.add(a, c), Nat.add(b, d)), Nat.add(a, Nat.add(c, Nat.add(b, d))), Nat.add_assoc(a, c, Nat.add(b, d))) : {Nat.add(a, Nat.add(b, Nat.add(c, d))) == _ : Nat}
  %Nat.add_assoc(b, c, d) : {Nat.add(a, _) == Nat.add(a, Nat.add(c, Nat.add(b, d))) : Nat}
  %Nat.add_assoc(c, b, d) : {Nat.add(a, Nat.add(Nat.add(b, c), d)) == Nat.add(a, _) : Nat}
  %Nat.add_comm(b, c) : {Nat.add(a, Nat.add(Nat.add(b, c), d)) == Nat.add(a, Nat.add(_, d)) : Nat}
  {==}

law Nat.mul_zero_r:
  for +x: Nat
  {Nat.mul(x, 0n) == 0n : Nat}

def Nat.mul_zero_r(x):
  match x:
    case 0n:
      {==}
    case 1n+p:
      Nat.mul_zero_r(p)

law Nat.mul_one_l:
  for +x: Nat
  {Nat.mul(1n, x) == x : Nat}

def Nat.mul_one_l(x):
  Nat.add_zero_r(x)

law Nat.mul_one_r:
  for +x: Nat
  {Nat.mul(x, 1n) == x : Nat}

def Nat.mul_one_r(x):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Nat.mul_one_r(p) : {1n+Nat.mul(p, 1n) == 1n+_ : Nat}
      {==}

law Nat.distrib_r:
  for +x: Nat
  for +y: Nat
  for +z: Nat
  {Nat.mul(Nat.add(x, y), z) == Nat.add(Nat.mul(x, z), Nat.mul(y, z)) : Nat}

def Nat.distrib_r(x, y, z):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Equal.sym(Nat, Nat.mul(Nat.add(p, y), z), Nat.add(Nat.mul(p, z), Nat.mul(y, z)), Nat.distrib_r(p, y, z)) : {Nat.add(z, _) == Nat.add(Nat.add(z, Nat.mul(p, z)), Nat.mul(y, z)) : Nat}
      Equal.sym(Nat, Nat.add(Nat.add(z, Nat.mul(p, z)), Nat.mul(y, z)), Nat.add(z, Nat.add(Nat.mul(p, z), Nat.mul(y, z))), Nat.add_assoc(z, Nat.mul(p, z), Nat.mul(y, z)))

law Nat.mul_assoc:
  for +x: Nat
  for +y: Nat
  for +z: Nat
  {Nat.mul(Nat.mul(x, y), z) == Nat.mul(x, Nat.mul(y, z)) : Nat}

def Nat.mul_assoc(x, y, z):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Equal.sym(Nat, Nat.mul(Nat.add(y, Nat.mul(p, y)), z), Nat.add(Nat.mul(y, z), Nat.mul(Nat.mul(p, y), z)), Nat.distrib_r(y, Nat.mul(p, y), z)) : {_ == Nat.add(Nat.mul(y, z), Nat.mul(p, Nat.mul(y, z))) : Nat}
      %Nat.mul_assoc(p, y, z) : {Nat.add(Nat.mul(y, z), Nat.mul(Nat.mul(p, y), z)) == Nat.add(Nat.mul(y, z), _) : Nat}
      {==}

law Nat.distrib_l:
  for +x: Nat
  for +y: Nat
  for +z: Nat
  {Nat.mul(x, Nat.add(y, z)) == Nat.add(Nat.mul(x, y), Nat.mul(x, z)) : Nat}

def Nat.distrib_l(x, y, z):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Equal.sym(Nat, Nat.mul(p, Nat.add(y, z)), Nat.add(Nat.mul(p, y), Nat.mul(p, z)), Nat.distrib_l(p, y, z)) : {Nat.add(Nat.add(y, z), _) == Nat.add(Nat.add(y, Nat.mul(p, y)), Nat.add(z, Nat.mul(p, z))) : Nat}
      Nat.interchange(y, z, Nat.mul(p, y), Nat.mul(p, z))

law Nat.mul_succ_r:
  for +x: Nat
  for +y: Nat
  {Nat.mul(x, 1n+y) == Nat.add(x, Nat.mul(x, y)) : Nat}

def Nat.mul_succ_r(x, y):
  match x:
    case 0n:
      {==}
    case 1n+p:
      %Equal.sym(Nat, Nat.mul(p, 1n+y), Nat.add(p, Nat.mul(p, y)), Nat.mul_succ_r(p, y)) : {1n+Nat.add(y, _) == 1n+Nat.add(p, Nat.add(y, Nat.mul(p, y))) : Nat}
      %Nat.add_assoc(y, p, Nat.mul(p, y)) : {1n+_ == 1n+Nat.add(p, Nat.add(y, Nat.mul(p, y))) : Nat}
      %Nat.add_assoc(p, y, Nat.mul(p, y)) : {1n+Nat.add(Nat.add(y, p), Nat.mul(p, y)) == 1n+_ : Nat}
      %Nat.add_comm(y, p) : {1n+Nat.add(Nat.add(y, p), Nat.mul(p, y)) == 1n+Nat.add(_, Nat.mul(p, y)) : Nat}
      {==}

law Nat.mul_comm:
  for +x: Nat
  for +y: Nat
  {Nat.mul(x, y) == Nat.mul(y, x) : Nat}

def Nat.mul_comm(x, y):
  match x:
    case 0n:
      %Nat.mul_zero_r(y) : {_ == Nat.mul(y, 0n) : Nat}
      {==}
    case 1n+p:
      %Equal.sym(Nat, Nat.mul(y, 1n+p), Nat.add(y, Nat.mul(y, p)), Nat.mul_succ_r(y, p)) : {Nat.add(y, Nat.mul(p, y)) == _ : Nat}
      %Nat.mul_comm(p, y) : {Nat.add(y, Nat.mul(p, y)) == Nat.add(y, _) : Nat}
      {==}

# Order ------------------------------------------------------------------
#
# x <= y as a type: a witness k with x + k = y.

def Le(x: Nat, y: Nat) -> Type:
  Exists(Nat, k => {Nat.add(x, k) == y : Nat})

law Le.refl:
  for +x: Nat
  Le(x, x)

def Le.refl(x):
  (0n, Nat.add_zero_r(x))

law Le.zero:
  for +x: Nat
  Le(0n, x)

def Le.zero(x):
  (x, {==})

law Le.add_r:
  for +x: Nat
  for +y: Nat
  Le(x, Nat.add(x, y))

def Le.add_r(x, y):
  (y, {==})

law Le.add_l:
  for +x: Nat
  for +y: Nat
  Le(x, Nat.add(y, x))

def Le.add_l(x, y):
  (y, Nat.add_comm(x, y))

law Le.trans:
  for +x: Nat
  for +y: Nat
  for +z: Nat
  for a: Le(x, y)
  for b: Le(y, z)
  Le(x, z)

def Le.trans(x, y, z, a, b):
  (+k, e) = a
  (+m, f) = b
  (Nat.add(k, m),
   Equal.trans(Nat, Nat.add(x, Nat.add(k, m)), Nat.add(Nat.add(x, k), m), z,
     Equal.sym(Nat, Nat.add(Nat.add(x, k), m), Nat.add(x, Nat.add(k, m)), Nat.add_assoc(x, k, m)),
     Equal.trans(Nat, Nat.add(Nat.add(x, k), m), Nat.add(y, m), z,
       Equal.cong(Nat, Nat, u => Nat.add(u, m), Nat.add(x, k), y, e), f)))
