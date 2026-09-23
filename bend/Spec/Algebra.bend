import Base
import ./Nat.bend as NL

# Law-carrying structures (Foundation/Algebra.agda).  A structure is a
# record of operations AND their laws.
#
# How genericity works in Bend2.  A hypothesis that is a function (a law
# "for all x") is a closure, and closures are affine: a proof could use
# each semiring law once.  Templates are the abstraction Bend2 provides for
# reusable functions, so every theorem of this specification is a THEOREM
# TEMPLATE over `~r: Semiring<A>` (or Monoid<A>), whose body uses only the
# record's operations and laws, and it is instantiated -- and so checked --
# at concrete lawful carriers: Nat and Bool for every semiring theorem.
# Bend2 checks a template per instance, not generically; checking it at two
# carriers with different computational behaviour is what keeps a proof
# from leaning on one carrier's definitional arithmetic instead of the laws.

type Semiring<-A: Data> is Type:
  Semiring{
    zero: A, one: A, add: A -> A -> A, mul: A -> A -> A,
    add_assoc: @+x:A -> @+y:A -> @+z:A -> {add(add(x, y), z) == add(x, add(y, z)) : A},
    add_comm: @+x:A -> @+y:A -> {add(x, y) == add(y, x) : A},
    add_zero_l: @+x:A -> {add(zero, x) == x : A},
    mul_assoc: @+x:A -> @+y:A -> @+z:A -> {mul(mul(x, y), z) == mul(x, mul(y, z)) : A},
    mul_one_l: @+x:A -> {mul(one, x) == x : A},
    mul_one_r: @+x:A -> {mul(x, one) == x : A},
    distrib_l: @+x:A -> @+y:A -> @+z:A -> {mul(x, add(y, z)) == add(mul(x, y), mul(x, z)) : A},
    distrib_r: @+x:A -> @+y:A -> @+z:A -> {mul(add(x, y), z) == add(mul(x, z), mul(y, z)) : A},
    zero_l: @+x:A -> {mul(zero, x) == zero : A},
    zero_r: @+x:A -> {mul(x, zero) == zero : A}}

def SR.zero(-A: Data, r: Semiring<A>) -> A:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      z

def SR.one(-A: Data, r: Semiring<A>) -> A:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      o

def SR.add(-A: Data, r: Semiring<A>) -> A -> A -> A:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      a

def SR.mul(-A: Data, r: Semiring<A>) -> A -> A -> A:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      m

def SR.add_assoc(-A: Data, r: Semiring<A>) -> @+x:A -> @+y:A -> @+z:A -> {SR.add(A, r)(SR.add(A, r)(x, y), z) == SR.add(A, r)(x, SR.add(A, r)(y, z)) : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p1

def SR.add_comm(-A: Data, r: Semiring<A>) -> @+x:A -> @+y:A -> {SR.add(A, r)(x, y) == SR.add(A, r)(y, x) : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p2

def SR.add_zero_l(-A: Data, r: Semiring<A>) -> @+x:A -> {SR.add(A, r)(SR.zero(A, r), x) == x : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p3

def SR.mul_assoc(-A: Data, r: Semiring<A>) -> @+x:A -> @+y:A -> @+z:A -> {SR.mul(A, r)(SR.mul(A, r)(x, y), z) == SR.mul(A, r)(x, SR.mul(A, r)(y, z)) : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p4

def SR.mul_one_l(-A: Data, r: Semiring<A>) -> @+x:A -> {SR.mul(A, r)(SR.one(A, r), x) == x : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p5

def SR.mul_one_r(-A: Data, r: Semiring<A>) -> @+x:A -> {SR.mul(A, r)(x, SR.one(A, r)) == x : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p6

def SR.distrib_l(-A: Data, r: Semiring<A>) -> @+x:A -> @+y:A -> @+z:A -> {SR.mul(A, r)(x, SR.add(A, r)(y, z)) == SR.add(A, r)(SR.mul(A, r)(x, y), SR.mul(A, r)(x, z)) : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p7

def SR.distrib_r(-A: Data, r: Semiring<A>) -> @+x:A -> @+y:A -> @+z:A -> {SR.mul(A, r)(SR.add(A, r)(x, y), z) == SR.add(A, r)(SR.mul(A, r)(x, z), SR.mul(A, r)(y, z)) : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p8

def SR.zero_l(-A: Data, r: Semiring<A>) -> @+x:A -> {SR.mul(A, r)(SR.zero(A, r), x) == SR.zero(A, r) : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p9

def SR.zero_r(-A: Data, r: Semiring<A>) -> @+x:A -> {SR.mul(A, r)(x, SR.zero(A, r)) == SR.zero(A, r) : A}:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      p10

# x + 0 = x, derived (Agda's private +-identityʳ)
def SR.add_zero_r(~A: Data, ~r: Semiring<A>, +x: A) -> {SR.add(A, r)(x, SR.zero(A, r)) == x : A}:
  %SR.add_comm(A, r, SR.zero(A, r), x) : {_ == x : A}
  %SR.add_zero_l(A, r, x) : {SR.add(A, r)(SR.zero(A, r), x) == _ : A}
  {==}

# (a + b) + (c + d) = (a + c) + (b + d), the sum interchange every
# accumulation theorem reduces to
def SR.interchange(~A: Data, ~r: Semiring<A>, +a: A, +b: A, +c: A, +d: A) ->
    {SR.add(A, r)(SR.add(A, r)(a, b), SR.add(A, r)(c, d)) == SR.add(A, r)(SR.add(A, r)(a, c), SR.add(A, r)(b, d)) : A}:
  %Equal.sym(A, SR.add(A, r)(SR.add(A, r)(a, b), SR.add(A, r)(c, d)), SR.add(A, r)(a, SR.add(A, r)(b, SR.add(A, r)(c, d))), SR.add_assoc(A, r, a, b, SR.add(A, r)(c, d))) : {_ == SR.add(A, r)(SR.add(A, r)(a, c), SR.add(A, r)(b, d)) : A}
  %Equal.sym(A, SR.add(A, r)(SR.add(A, r)(a, c), SR.add(A, r)(b, d)), SR.add(A, r)(a, SR.add(A, r)(c, SR.add(A, r)(b, d))), SR.add_assoc(A, r, a, c, SR.add(A, r)(b, d))) : {SR.add(A, r)(a, SR.add(A, r)(b, SR.add(A, r)(c, d))) == _ : A}
  %SR.add_assoc(A, r, b, c, d) : {SR.add(A, r)(a, _) == SR.add(A, r)(a, SR.add(A, r)(c, SR.add(A, r)(b, d))) : A}
  %SR.add_assoc(A, r, c, b, d) : {SR.add(A, r)(a, SR.add(A, r)(SR.add(A, r)(b, c), d)) == SR.add(A, r)(a, _) : A}
  %SR.add_comm(A, r, b, c) : {SR.add(A, r)(a, SR.add(A, r)(SR.add(A, r)(b, c), d)) == SR.add(A, r)(a, SR.add(A, r)(_, d)) : A}
  {==}

# The additive monoid alone (AD.Reverse's structure: gradients add).
type Monoid<-A: Data> is Type:
  Monoid{
    zero: A, add: A -> A -> A,
    add_assoc: @+x:A -> @+y:A -> @+z:A -> {add(add(x, y), z) == add(x, add(y, z)) : A},
    add_comm: @+x:A -> @+y:A -> {add(x, y) == add(y, x) : A},
    add_zero_l: @+x:A -> {add(zero, x) == x : A}}

def MO.zero(-A: Data, r: Monoid<A>) -> A:
  match r:
    case Monoid{z, a, p1, p2, p3}:
      z

def MO.add(-A: Data, r: Monoid<A>) -> A -> A -> A:
  match r:
    case Monoid{z, a, p1, p2, p3}:
      a

def MO.add_assoc(-A: Data, r: Monoid<A>) -> @+x:A -> @+y:A -> @+z:A -> {MO.add(A, r)(MO.add(A, r)(x, y), z) == MO.add(A, r)(x, MO.add(A, r)(y, z)) : A}:
  match r:
    case Monoid{z, a, p1, p2, p3}:
      p1

def MO.add_comm(-A: Data, r: Monoid<A>) -> @+x:A -> @+y:A -> {MO.add(A, r)(x, y) == MO.add(A, r)(y, x) : A}:
  match r:
    case Monoid{z, a, p1, p2, p3}:
      p2

def MO.add_zero_l(-A: Data, r: Monoid<A>) -> @+x:A -> {MO.add(A, r)(MO.zero(A, r), x) == x : A}:
  match r:
    case Monoid{z, a, p1, p2, p3}:
      p3

def MO.interchange(~A: Data, ~r: Monoid<A>, +a: A, +b: A, +c: A, +d: A) ->
    {MO.add(A, r)(MO.add(A, r)(a, b), MO.add(A, r)(c, d)) == MO.add(A, r)(MO.add(A, r)(a, c), MO.add(A, r)(b, d)) : A}:
  %Equal.sym(A, MO.add(A, r)(MO.add(A, r)(a, b), MO.add(A, r)(c, d)), MO.add(A, r)(a, MO.add(A, r)(b, MO.add(A, r)(c, d))), MO.add_assoc(A, r, a, b, MO.add(A, r)(c, d))) : {_ == MO.add(A, r)(MO.add(A, r)(a, c), MO.add(A, r)(b, d)) : A}
  %Equal.sym(A, MO.add(A, r)(MO.add(A, r)(a, c), MO.add(A, r)(b, d)), MO.add(A, r)(a, MO.add(A, r)(c, MO.add(A, r)(b, d))), MO.add_assoc(A, r, a, c, MO.add(A, r)(b, d))) : {MO.add(A, r)(a, MO.add(A, r)(b, MO.add(A, r)(c, d))) == _ : A}
  %MO.add_assoc(A, r, b, c, d) : {MO.add(A, r)(a, _) == MO.add(A, r)(a, MO.add(A, r)(c, MO.add(A, r)(b, d))) : A}
  %MO.add_assoc(A, r, c, b, d) : {MO.add(A, r)(a, MO.add(A, r)(MO.add(A, r)(b, c), d)) == MO.add(A, r)(a, _) : A}
  %MO.add_comm(A, r, b, c) : {MO.add(A, r)(a, MO.add(A, r)(MO.add(A, r)(b, c), d)) == MO.add(A, r)(a, MO.add(A, r)(_, d)) : A}
  {==}

# A semiring's additive reduct.
def SR.monoid(-A: Data, r: Semiring<A>) -> Monoid<A>:
  match r:
    case Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      Monoid{z, a, p1, p2, p3}

# An ordered multiplicative monoid (the cost structure of Enriched/Bradley).
type Ordered<-A: Data> is Type:
  Ordered{
    unit: A, op: A -> A -> A, le: A -> A -> Type,
    le_refl: @+x:A -> le(x, x),
    le_trans: @+x:A -> @+y:A -> @+z:A -> le(x, y) -> le(y, z) -> le(x, z),
    op_assoc: @+x:A -> @+y:A -> @+z:A -> {op(op(x, y), z) == op(x, op(y, z)) : A},
    op_unit_l: @+x:A -> {op(unit, x) == x : A},
    op_unit_r: @+x:A -> {op(x, unit) == x : A},
    op_mono: @+x:A -> @+x2:A -> @+y:A -> @+y2:A -> le(x, x2) -> le(y, y2) -> le(op(x, y), op(x2, y2))}

# Instances ----------------------------------------------------------------

law Nat.add_zero_l:
  for +x: Nat
  {Nat.add(0n, x) == x : Nat}

def Nat.add_zero_l(x):
  {==}

law Nat.mul_zero_l:
  for +x: Nat
  {Nat.mul(0n, x) == 0n : Nat}

def Nat.mul_zero_l(x):
  {==}

def Nat.plus(x: Nat, y: Nat) -> Nat:
  Nat.add(x, y)

def Nat.times(x: Nat, +y: Nat) -> Nat:
  Nat.mul(x, y)

# Nat is a semiring, by the lemmas of Nat.bend.
def Nat.semiring() -> Semiring<Nat>:
  Semiring{0n, 1n, x => y => Nat.add(x, y), x => y => Nat.mul(x, y),
    NL.Nat.add_assoc, NL.Nat.add_comm, Nat.add_zero_l,
    NL.Nat.mul_assoc, NL.Nat.mul_one_l, NL.Nat.mul_one_r,
    NL.Nat.distrib_l, NL.Nat.distrib_r, Nat.mul_zero_l, NL.Nat.mul_zero_r}

def Nat.monoid() -> Monoid<Nat>:
  Monoid{0n, x => y => Nat.add(x, y), NL.Nat.add_assoc, NL.Nat.add_comm, Nat.add_zero_l}

# Bool is a semiring under (or, and): the second carrier every semiring
# theorem is checked at.  Its arithmetic computes by cases rather than by
# recursion, so a proof that went through only by unfolding Nat.add would
# fail here.
law Bool.or_assoc:
  for +x: Bool
  for +y: Bool
  for +z: Bool
  {Bool.or(Bool.or(x, y), z) == Bool.or(x, Bool.or(y, z)) : Bool}

def Bool.or_assoc(x, y, z):
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

law Bool.or_comm:
  for +x: Bool
  for +y: Bool
  {Bool.or(x, y) == Bool.or(y, x) : Bool}

def Bool.or_comm(x, y):
  match x y:
    case True{} True{}:
      {==}
    case True{} False{}:
      {==}
    case False{} True{}:
      {==}
    case False{} False{}:
      {==}

law Bool.or_false_l:
  for +x: Bool
  {Bool.or(False{}, x) == x : Bool}

def Bool.or_false_l(x):
  {==}

law Bool.and_assoc:
  for +x: Bool
  for +y: Bool
  for +z: Bool
  {Bool.and(Bool.and(x, y), z) == Bool.and(x, Bool.and(y, z)) : Bool}

def Bool.and_assoc(x, y, z):
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

law Bool.and_true_l:
  for +x: Bool
  {Bool.and(True{}, x) == x : Bool}

def Bool.and_true_l(x):
  {==}

law Bool.and_true_r:
  for +x: Bool
  {Bool.and(x, True{}) == x : Bool}

def Bool.and_true_r(x):
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

law Bool.distrib_l:
  for +x: Bool
  for +y: Bool
  for +z: Bool
  {Bool.and(x, Bool.or(y, z)) == Bool.or(Bool.and(x, y), Bool.and(x, z)) : Bool}

def Bool.distrib_l(x, y, z):
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

law Bool.distrib_r:
  for +x: Bool
  for +y: Bool
  for +z: Bool
  {Bool.and(Bool.or(x, y), z) == Bool.or(Bool.and(x, z), Bool.and(y, z)) : Bool}

def Bool.distrib_r(x, y, z):
  match x y z:
    case True{} _ True{}:
      {==}
    case True{} True{} False{}:
      {==}
    case True{} False{} False{}:
      {==}
    case False{} _ _:
      {==}

law Bool.and_false_l:
  for +x: Bool
  {Bool.and(False{}, x) == False{} : Bool}

def Bool.and_false_l(x):
  {==}

law Bool.and_false_r:
  for +x: Bool
  {Bool.and(x, False{}) == False{} : Bool}

def Bool.and_false_r(x):
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

def Bool.semiring() -> Semiring<Bool>:
  Semiring{False{}, True{}, x => y => Bool.or(x, y), x => y => Bool.and(x, y),
    Bool.or_assoc, Bool.or_comm, Bool.or_false_l,
    Bool.and_assoc, Bool.and_true_l, Bool.and_true_r,
    Bool.distrib_l, Bool.distrib_r, Bool.and_false_l, Bool.and_false_r}

def Bool.monoid() -> Monoid<Bool>:
  Monoid{False{}, x => y => Bool.or(x, y), Bool.or_assoc, Bool.or_comm, Bool.or_false_l}

# The derived lemmas at both carriers: instantiating a theorem template is
# what makes Bend2 check it.
law check.add_zero_r:
  for +x: Nat
  for +b: Bool
  {Nat.add(x, 0n) == x : Nat} & {Bool.or(b, False{}) == b : Bool}

def check.add_zero_r(x, b):
  (SR.add_zero_r(~Nat, ~Nat.semiring(), x), SR.add_zero_r(~Bool, ~Bool.semiring(), b))

law check.interchange:
  for +a: Nat
  for +b: Nat
  for +c: Nat
  for +d: Nat
  for +p: Bool
  for +q: Bool
  for +u: Bool
  for +v: Bool
  {Nat.add(Nat.add(a, b), Nat.add(c, d)) == Nat.add(Nat.add(a, c), Nat.add(b, d)) : Nat}
  & {Bool.or(Bool.or(p, q), Bool.or(u, v)) == Bool.or(Bool.or(p, u), Bool.or(q, v)) : Bool}
  & {Nat.add(Nat.add(a, b), Nat.add(c, d)) == Nat.add(Nat.add(a, c), Nat.add(b, d)) : Nat}

def check.interchange(a, b, c, d, p, q, u, v):
  (SR.interchange(~Nat, ~Nat.semiring(), a, b, c, d),
   SR.interchange(~Bool, ~Bool.semiring(), p, q, u, v),
   MO.interchange(~Nat, ~Nat.monoid(), a, b, c, d))
