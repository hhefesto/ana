import Base
import ./Algebra.bend as Al

# Transformer/ResidualStream.agda: why residual streams are stable by
# construction, and what a widened stream must satisfy to stay so
# (Manifold-Constrained Hyper-Connections, arXiv 2512.24880).
#
#   mass_conserved      the total signal across lanes is invariant under a
#                       column-stochastic mixing step
#   compose_stochastic  column-stochastic mixes compose to one, so the
#                       conservation holds at every depth
#   singleton_rigid     at one lane the constraint forces H = 1: the plain
#                       residual connection is the only constrained mixing
#   singleton_identity  ...and its mixing step is the identity
#
# The model ships a single-lane stream, so by singleton_rigid it sits in
# the constraint manifold permanently.  A stream is a list of lane values
# and a mix a list of rows (finite lanes, as the Agda lane list); both are
# data, so every theorem holds for EVERY stream and mix; only the semiring
# is a template.
def Stream(-C: Data) -> Data:
  List<&2, C>

def mass(~C: Data, ~R: Al.Semiring<C>, xs: List<&2, C>) -> C:
  match xs:
    case Nil{}:
      Al.SR.zero(C, R)
    case h <> t:
      Al.SR.add(C, R)(h, mass(~C, ~R, t))

def dot(~C: Data, ~R: Al.Semiring<C>, us: List<&2, C>, xs: List<&2, C>) -> C:
  match us xs:
    case u <> ut x <> xt:
      Al.SR.add(C, R)(Al.SR.mul(C, R)(u, x), dot(~C, ~R, ut, xt))
    case _ _:
      Al.SR.zero(C, R)

# the mixing step: lane i receives the row-i combination of the stream
def apply(~C: Data, ~R: Al.Semiring<C>, H: List<&2, List<&2, C>>, +x: List<&2, C>) -> List<&2, C>:
  match H:
    case Nil{}:
      Nil{}
    case row <> rest:
      dot(~C, ~R, row, x) <> apply(~C, ~R, rest, x)

# vector sum; a missing lane counts as zero (so no length side conditions)
def vadd(~C: Data, ~R: Al.Semiring<C>, us: List<&2, C>, vs: List<&2, C>) -> List<&2, C>:
  match us vs:
    case u <> ut v <> vt:
      Al.SR.add(C, R)(u, v) <> vadd(~C, ~R, ut, vt)
    case Nil{} _:
      vs
    case _ Nil{}:
      us

def zeros(~C: Data, ~R: Al.Semiring<C>, n: Nat) -> List<&2, C>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      Al.SR.zero(C, R) <> zeros(~C, ~R, p)

def ones(~C: Data, ~R: Al.Semiring<C>, n: Nat) -> List<&2, C>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      Al.SR.one(C, R) <> ones(~C, ~R, p)

# column sums of an n-lane mix
def colSums(~C: Data, ~R: Al.Semiring<C>, n: Nat, H: List<&2, List<&2, C>>) -> List<&2, C>:
  match H:
    case Nil{}:
      zeros(~C, ~R, n)
    case row <> rest:
      vadd(~C, ~R, row, colSums(~C, ~R, n, rest))

def ColumnStochastic(~C: Data, ~R: Al.Semiring<C>, +n: Nat, H: List<&2, List<&2, C>>) -> Type:
  {colSums(~C, ~R, n, H) == ones(~C, ~R, n) : List<&2, C>}

# Lemmas -------------------------------------------------------------------

def dot_zeros(~C: Data, ~R: Al.Semiring<C>, +n: Nat, +xs: List<&2, C>) ->
    {dot(~C, ~R, zeros(~C, ~R, n), xs) == Al.SR.zero(C, R) : C}:
  match n xs:
    case 1n+p +x <> t:
      %Equal.sym(C, Al.SR.mul(C, R)(Al.SR.zero(C, R), x), Al.SR.zero(C, R), Al.SR.zero_l(C, R, x)) : {Al.SR.add(C, R)(_, dot(~C, ~R, zeros(~C, ~R, p), t)) == Al.SR.zero(C, R) : C}
      %Equal.sym(C, dot(~C, ~R, zeros(~C, ~R, p), t), Al.SR.zero(C, R), dot_zeros(~C, ~R, p, t)) : {Al.SR.add(C, R)(Al.SR.zero(C, R), _) == Al.SR.zero(C, R) : C}
      Al.SR.add_zero_l(C, R, Al.SR.zero(C, R))
    case 0n _:
      {==}
    case 1n+p Nil{}:
      {==}

def dot_ones(~C: Data, ~R: Al.Semiring<C>, +xs: List<&2, C>) ->
    {dot(~C, ~R, ones(~C, ~R, List.length(&2, C, xs)), xs) == mass(~C, ~R, xs) : C}:
  match xs:
    case Nil{}:
      {==}
    case +x <> t:
      %Al.SR.mul_one_l(C, R, x) : {Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.one(C, R), x), dot(~C, ~R, ones(~C, ~R, List.length(&2, C, t)), t)) == Al.SR.add(C, R)(_, mass(~C, ~R, t)) : C}
      %dot_ones(~C, ~R, t) : {Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.one(C, R), x), dot(~C, ~R, ones(~C, ~R, List.length(&2, C, t)), t)) == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.one(C, R), x), _) : C}
      {==}

# dot distributes over a sum of rows
def dot_vadd(~C: Data, ~R: Al.Semiring<C>, +us: List<&2, C>, +vs: List<&2, C>, +xs: List<&2, C>) ->
    {dot(~C, ~R, vadd(~C, ~R, us, vs), xs) == Al.SR.add(C, R)(dot(~C, ~R, us, xs), dot(~C, ~R, vs, xs)) : C}:
  match us vs xs:
    case +u <> ut +v <> vt +x <> xt:
      +a = Al.SR.mul(C, R)(u, x)
      +b = Al.SR.mul(C, R)(v, x)
      +p = dot(~C, ~R, ut, xt)
      +q = dot(~C, ~R, vt, xt)
      %Equal.sym(C, Al.SR.mul(C, R)(Al.SR.add(C, R)(u, v), x), Al.SR.add(C, R)(a, b), Al.SR.distrib_r(C, R, u, v, x))
        : {Al.SR.add(C, R)(_, dot(~C, ~R, vadd(~C, ~R, ut, vt), xt)) == Al.SR.add(C, R)(Al.SR.add(C, R)(a, p), Al.SR.add(C, R)(b, q)) : C}
      %Equal.sym(C, dot(~C, ~R, vadd(~C, ~R, ut, vt), xt), Al.SR.add(C, R)(p, q), dot_vadd(~C, ~R, ut, vt, xt))
        : {Al.SR.add(C, R)(Al.SR.add(C, R)(a, b), _) == Al.SR.add(C, R)(Al.SR.add(C, R)(a, p), Al.SR.add(C, R)(b, q)) : C}
      Al.SR.interchange(~C, ~R, a, b, p, q)
    case Nil{} Nil{} _:
      Equal.sym(C, Al.SR.add(C, R)(Al.SR.zero(C, R), Al.SR.zero(C, R)), Al.SR.zero(C, R), Al.SR.add_zero_l(C, R, Al.SR.zero(C, R)))
    case Nil{} +v <> vt _:
      Equal.sym(C, Al.SR.add(C, R)(Al.SR.zero(C, R), dot(~C, ~R, v <> vt, xs)), dot(~C, ~R, v <> vt, xs), Al.SR.add_zero_l(C, R, dot(~C, ~R, v <> vt, xs)))
    case +u <> ut Nil{} _:
      Equal.sym(C, Al.SR.add(C, R)(dot(~C, ~R, u <> ut, xs), Al.SR.zero(C, R)), dot(~C, ~R, u <> ut, xs), Al.SR.add_zero_r(~C, ~R, dot(~C, ~R, u <> ut, xs)))
    case +u <> ut +v <> vt Nil{}:
      Equal.sym(C, Al.SR.add(C, R)(Al.SR.zero(C, R), Al.SR.zero(C, R)), Al.SR.zero(C, R), Al.SR.add_zero_l(C, R, Al.SR.zero(C, R)))

# the total output is the column sums weighing the input
def mass_apply(~C: Data, ~R: Al.Semiring<C>, +n: Nat, H: List<&2, List<&2, C>>, +x: List<&2, C>) ->
    {mass(~C, ~R, apply(~C, ~R, H, x)) == dot(~C, ~R, colSums(~C, ~R, n, H), x) : C}:
  match H:
    case Nil{}:
      Equal.sym(C, dot(~C, ~R, zeros(~C, ~R, n), x), Al.SR.zero(C, R), dot_zeros(~C, ~R, n, x))
    case +row <> +rest:
      %Equal.sym(C, dot(~C, ~R, vadd(~C, ~R, row, colSums(~C, ~R, n, rest)), x), Al.SR.add(C, R)(dot(~C, ~R, row, x), dot(~C, ~R, colSums(~C, ~R, n, rest), x)), dot_vadd(~C, ~R, row, colSums(~C, ~R, n, rest), x))
        : {Al.SR.add(C, R)(dot(~C, ~R, row, x), mass(~C, ~R, apply(~C, ~R, rest, x))) == _ : C}
      %mass_apply(~C, ~R, n, rest, x)
        : {Al.SR.add(C, R)(dot(~C, ~R, row, x), mass(~C, ~R, apply(~C, ~R, rest, x))) == Al.SR.add(C, R)(dot(~C, ~R, row, x), _) : C}
      {==}

# Theorems ---------------------------------------------------------------

# a column-stochastic mixing step conserves the total signal
def mass_conserved(~C: Data, ~R: Al.Semiring<C>, +H: List<&2, List<&2, C>>, +x: List<&2, C>,
                   +stochastic: {colSums(~C, ~R, List.length(&2, C, x), H) == ones(~C, ~R, List.length(&2, C, x)) : List<&2, C>}) ->
    {mass(~C, ~R, apply(~C, ~R, H, x)) == mass(~C, ~R, x) : C}:
  %Equal.sym(C, mass(~C, ~R, apply(~C, ~R, H, x)), dot(~C, ~R, colSums(~C, ~R, List.length(&2, C, x), H), x), mass_apply(~C, ~R, List.length(&2, C, x), H, x)) : {_ == mass(~C, ~R, x) : C}
  %Equal.sym(List<&2, C>, colSums(~C, ~R, List.length(&2, C, x), H), ones(~C, ~R, List.length(&2, C, x)), stochastic) : {dot(~C, ~R, _, x) == mass(~C, ~R, x) : C}
  dot_ones(~C, ~R, x)

# Conservation composes: mixing by G then H conserves whenever each does,
# at any depth (the paper's compositional-closure argument, stated for the
# property it exists to protect).
def compose_conserves(~C: Data, ~R: Al.Semiring<C>, +H: List<&2, List<&2, C>>, +G: List<&2, List<&2, C>>, +x: List<&2, C>,
                      +sG: {colSums(~C, ~R, List.length(&2, C, x), G) == ones(~C, ~R, List.length(&2, C, x)) : List<&2, C>},
                      +sH: {colSums(~C, ~R, List.length(&2, C, apply(~C, ~R, G, x)), H) == ones(~C, ~R, List.length(&2, C, apply(~C, ~R, G, x))) : List<&2, C>}) ->
    {mass(~C, ~R, apply(~C, ~R, H, apply(~C, ~R, G, x))) == mass(~C, ~R, x) : C}:
  Equal.trans(C, mass(~C, ~R, apply(~C, ~R, H, apply(~C, ~R, G, x))), mass(~C, ~R, apply(~C, ~R, G, x)), mass(~C, ~R, x),
    mass_conserved(~C, ~R, H, apply(~C, ~R, G, x), sH), mass_conserved(~C, ~R, G, x, sG))

def head.or(~C: Data, ~R: Al.Semiring<C>, xs: List<&2, C>) -> C:
  match xs:
    case h <> t:
      h
    case Nil{}:
      Al.SR.zero(C, R)

# at one lane the constraint forces the mix to be 1
def singleton_rigid(~C: Data, ~R: Al.Semiring<C>, +h: C,
                    +stochastic: {colSums(~C, ~R, 1n, [[h]]) == ones(~C, ~R, 1n) : List<&2, C>}) ->
    {h == Al.SR.one(C, R) : C}:
  %Al.SR.add_zero_r(~C, ~R, h) : {_ == Al.SR.one(C, R) : C}
  Equal.cong(List<&2, C>, C, xs => head.or(~C, ~R, xs), colSums(~C, ~R, 1n, [[h]]), ones(~C, ~R, 1n), stochastic)

# ...and its mixing step is the identity
def singleton_identity(~C: Data, ~R: Al.Semiring<C>, +h: C, +x: C,
                       +stochastic: {colSums(~C, ~R, 1n, [[h]]) == ones(~C, ~R, 1n) : List<&2, C>}) ->
    {apply(~C, ~R, [[h]], [x]) == [x] : List<&2, C>}:
  %Equal.sym(C, h, Al.SR.one(C, R), singleton_rigid(~C, ~R, h, stochastic)) : {[Al.SR.add(C, R)(Al.SR.mul(C, R)(_, x), Al.SR.zero(C, R))] == [x] : List<&2, C>}
  %Al.SR.mul_one_l(C, R, x) : {[Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.one(C, R), x), Al.SR.zero(C, R))] == [_] : List<&2, C>}
  %Al.SR.add_zero_r(~C, ~R, Al.SR.mul(C, R)(Al.SR.one(C, R), x)) : {[Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.one(C, R), x), Al.SR.zero(C, R))] == [_] : List<&2, C>}
  {==}

# Instances ----------------------------------------------------------------

law check.residual:
  for +H: List<&2, List<&2, Nat>>
  for +x: List<&2, Nat>
  for +s: {colSums(~Nat, ~Al.Nat.semiring(), List.length(&2, Nat, x), H) == ones(~Nat, ~Al.Nat.semiring(), List.length(&2, Nat, x)) : List<&2, Nat>}
  for +B: List<&2, List<&2, Bool>>
  for +y: List<&2, Bool>
  for +t: {colSums(~Bool, ~Al.Bool.semiring(), List.length(&2, Bool, y), B) == ones(~Bool, ~Al.Bool.semiring(), List.length(&2, Bool, y)) : List<&2, Bool>}
  {mass(~Nat, ~Al.Nat.semiring(), apply(~Nat, ~Al.Nat.semiring(), H, x)) == mass(~Nat, ~Al.Nat.semiring(), x) : Nat}
  & {mass(~Bool, ~Al.Bool.semiring(), apply(~Bool, ~Al.Bool.semiring(), B, y)) == mass(~Bool, ~Al.Bool.semiring(), y) : Bool}

def check.residual(H, x, s, B, y, t):
  (mass_conserved(~Nat, ~Al.Nat.semiring(), H, x, s), mass_conserved(~Bool, ~Al.Bool.semiring(), B, y, t))

law check.singleton:
  for +h: Nat
  for +x: Nat
  for +s: {colSums(~Nat, ~Al.Nat.semiring(), 1n, [[h]]) == ones(~Nat, ~Al.Nat.semiring(), 1n) : List<&2, Nat>}
  {apply(~Nat, ~Al.Nat.semiring(), [[h]], [x]) == [x] : List<&2, Nat>}

def check.singleton(h, x, s):
  singleton_identity(~Nat, ~Al.Nat.semiring(), h, x, s)

law check.compose:
  for +H: List<&2, List<&2, Bool>>
  for +G: List<&2, List<&2, Bool>>
  for +x: List<&2, Bool>
  for +sG: {colSums(~Bool, ~Al.Bool.semiring(), List.length(&2, Bool, x), G) == ones(~Bool, ~Al.Bool.semiring(), List.length(&2, Bool, x)) : List<&2, Bool>}
  for +sH: {colSums(~Bool, ~Al.Bool.semiring(), List.length(&2, Bool, apply(~Bool, ~Al.Bool.semiring(), G, x)), H) == ones(~Bool, ~Al.Bool.semiring(), List.length(&2, Bool, apply(~Bool, ~Al.Bool.semiring(), G, x))) : List<&2, Bool>}
  {mass(~Bool, ~Al.Bool.semiring(), apply(~Bool, ~Al.Bool.semiring(), H, apply(~Bool, ~Al.Bool.semiring(), G, x))) == mass(~Bool, ~Al.Bool.semiring(), x) : Bool}

def check.compose(H, G, x, sG, sH):
  compose_conserves(~Bool, ~Al.Bool.semiring(), H, G, x, sG, sH)
