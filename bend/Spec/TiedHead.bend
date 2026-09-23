import Base
import ./Algebra.bend as Al
import ./Nat.bend as NL

# Transformer/TiedHead.agda: what a tied output head can and cannot say.
#
# With the unembedding tied to the embedding table, the logit of token b
# after token a (for a context-free reading of the model) is a gated inner
# product of embedding rows, gram(E_a, g, E_b) = sum_k E_a[k] g[k] E_b[k].
# gram_sym proves the kernel symmetric and scaled_sym carries the symmetry
# through the per-row rescaling: the head weights unordered pairs, so the
# skew part of any bigram statistic (preferring a->b over b->a) is
# unrepresentable by the tied head alone.
#
# Stated over any semiring with commutative multiplication (the extra law
# is a template argument, as in the Agda module parameter).  Rows are
# lists, so the theorems hold for every pair of rows and every gain.

def gram(~C: Data, ~R: Al.Semiring<C>, ra: List<&2, C>, g: List<&2, C>, rb: List<&2, C>) -> C:
  match ra g rb:
    case a <> at k <> gt b <> bt:
      Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(a, k), b), gram(~C, ~R, at, gt, bt))
    case _ _ _:
      Al.SR.zero(C, R)

def term_sym(~C: Data, ~R: Al.Semiring<C>, ~comm: @+x:C -> @+y:C -> {Al.SR.mul(C, R)(x, y) == Al.SR.mul(C, R)(y, x) : C},
             +a: C, +k: C, +b: C) ->
    {Al.SR.mul(C, R)(Al.SR.mul(C, R)(a, k), b) == Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a) : C}:
  %comm(b, Al.SR.mul(C, R)(a, k)) : {_ == Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a) : C}
  %comm(k, a) : {Al.SR.mul(C, R)(b, _) == Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a) : C}
  Equal.sym(C, Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a), Al.SR.mul(C, R)(b, Al.SR.mul(C, R)(k, a)), Al.SR.mul_assoc(C, R, b, k, a))

# the tied kernel is symmetric
def gram_sym(~C: Data, ~R: Al.Semiring<C>, ~comm: @+x:C -> @+y:C -> {Al.SR.mul(C, R)(x, y) == Al.SR.mul(C, R)(y, x) : C},
             +ra: List<&2, C>, +g: List<&2, C>, +rb: List<&2, C>) ->
    {gram(~C, ~R, ra, g, rb) == gram(~C, ~R, rb, g, ra) : C}:
  match ra g rb:
    case +a <> at +k <> gt +b <> bt:
      %Equal.sym(C, Al.SR.mul(C, R)(Al.SR.mul(C, R)(a, k), b), Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a), term_sym(~C, ~R, ~comm, a, k, b))
        : {Al.SR.add(C, R)(_, gram(~C, ~R, at, gt, bt)) == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a), gram(~C, ~R, bt, gt, at)) : C}
      %gram_sym(~C, ~R, ~comm, at, gt, bt)
        : {Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a), gram(~C, ~R, at, gt, bt)) == Al.SR.add(C, R)(Al.SR.mul(C, R)(Al.SR.mul(C, R)(b, k), a), _) : C}
      {==}
    case Nil{} Nil{} Nil{}:
      {==}
    case Nil{} Nil{} b <> bt:
      {==}
    case Nil{} k <> gt Nil{}:
      {==}
    case Nil{} k <> gt b <> bt:
      {==}
    case a <> at Nil{} Nil{}:
      {==}
    case a <> at Nil{} b <> bt:
      {==}
    case a <> at k <> gt Nil{}:
      {==}

# symmetry survives the per-row rescaling: z(a->b) and z(b->a) are the
# same quantity in different row units
def scaled_sym(~C: Data, ~R: Al.Semiring<C>, ~comm: @+x:C -> @+y:C -> {Al.SR.mul(C, R)(x, y) == Al.SR.mul(C, R)(y, x) : C},
               +ca: C, +cb: C, +ra: List<&2, C>, +g: List<&2, C>, +rb: List<&2, C>) ->
    {Al.SR.mul(C, R)(cb, Al.SR.mul(C, R)(ca, gram(~C, ~R, ra, g, rb))) == Al.SR.mul(C, R)(ca, Al.SR.mul(C, R)(cb, gram(~C, ~R, rb, g, ra))) : C}:
  +k = gram(~C, ~R, rb, g, ra)
  %Equal.sym(C, gram(~C, ~R, ra, g, rb), k, gram_sym(~C, ~R, ~comm, ra, g, rb))
    : {Al.SR.mul(C, R)(cb, Al.SR.mul(C, R)(ca, _)) == Al.SR.mul(C, R)(ca, Al.SR.mul(C, R)(cb, k)) : C}
  %Al.SR.mul_assoc(C, R, cb, ca, k) : {_ == Al.SR.mul(C, R)(ca, Al.SR.mul(C, R)(cb, k)) : C}
  %Al.SR.mul_assoc(C, R, ca, cb, k) : {Al.SR.mul(C, R)(Al.SR.mul(C, R)(cb, ca), k) == _ : C}
  %comm(ca, cb) : {Al.SR.mul(C, R)(_, k) == Al.SR.mul(C, R)(Al.SR.mul(C, R)(ca, cb), k) : C}
  {==}

law check.tied:
  for +ca: Nat
  for +cb: Nat
  for +ra: List<&2, Nat>
  for +g: List<&2, Nat>
  for +rb: List<&2, Nat>
  for +pa: List<&2, Bool>
  for +pg: List<&2, Bool>
  for +pb: List<&2, Bool>
  {Nat.mul(cb, Nat.mul(ca, gram(~Nat, ~Al.Nat.semiring(), ra, g, rb))) == Nat.mul(ca, Nat.mul(cb, gram(~Nat, ~Al.Nat.semiring(), rb, g, ra))) : Nat}
  & {gram(~Bool, ~Al.Bool.semiring(), pa, pg, pb) == gram(~Bool, ~Al.Bool.semiring(), pb, pg, pa) : Bool}

def check.tied(ca, cb, ra, g, rb, pa, pg, pb):
  (scaled_sym(~Nat, ~Al.Nat.semiring(), ~NL.Nat.mul_comm, ca, cb, ra, g, rb),
   gram_sym(~Bool, ~Al.Bool.semiring(), ~Al.Bool.and_comm, pa, pg, pb))
