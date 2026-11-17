import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar

# Everything a prefix can become, and its probabilities sum to one
# (Bradley & Vigneaux, "The magnitude of categories of texts enriched by
# language models", Prop. 2.9; the user, 2026-11-17: "then item 2").
#
# A model gives, after a prefix, a weight to stopping (Autoregressive.bend's
# observation `out`: the end token's mass) and to each next token.  Read
# from a state, an ENDING is an extension that either finished (stopped
# with the end token: the `finished` flag that Bradley.bend's PrefixObject
# declares as `terminal`) or ran into the cutoff unfinished.  The weight of
# an ending is the product of its steps' weights, times the stop weight if
# it finished.  `ends(n, vs)` lists every ending within n more tokens over
# the vocabulary vs: stop now, or take one token of vs and then an ending
# within n - 1; at n = 0, the cutoff, the one ending is the empty one,
# unfinished.  ana's cutoff is the length her harness lets her write.
#
# A model is STOCHASTIC over vs when, at every state, its stop weight plus
# its next-token weights over vs make one.  The theorem:
#
#   sum_to_one   for a stochastic model, at every state and every cutoff,
#                the weights of all the endings sum to one: the endings'
#                weights are a probability distribution over what the
#                prefix can become (Prop. 2.9)
#
# What is assumed and what is proven.  The proof uses only the semiring
# laws and the stochastic law; it is checked at two carriers: Nat (a
# machine whose weights are 0 and 1, so stochastic means a single path)
# and Bool (or, and: "some way on" at every state).  At F32 the stochastic
# law is the softmax's sum, which holds only up to rounding: a trusted
# fact, as the semiring laws at F32 are (Trusted.bend).  That ends(n, vs)
# lists each such text exactly once is by its construction, not a theorem
# here.

type Ending<-A: Data> is Data:
  Ending{text: List<&2, A>, finished: Bool}

# x then each of es
def prepend(-A: Data, +x: A, es: List<&2, Ending<A>>) -> List<&2, Ending<A>>:
  match es:
    case Nil{}:
      Nil{}
    case Ending{t, f} <> rest:
      Ending{x <> t, f} <> prepend(A, x, rest)

# each token of xs, then each of es
def kids(-A: Data, xs: List<&2, A>, +es: List<&2, Ending<A>>) -> List<&2, Ending<A>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      List.append(&2, Ending<A>, prepend(A, x, es), kids(A, t, es))

def ends(-A: Data, n: Nat, +vs: List<&2, A>) -> List<&2, Ending<A>>:
  match n:
    case 0n:
      [Ending{Nil{}, False{}}]
    case 1n+p:
      Ending{Nil{}, True{}} <> kids(A, vs, ends(A, p, vs))

# the stop weight of an ending that finished; one at the cutoff
def stop(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, f: Bool, +q: S) -> W:
  match f:
    case True{}:
      Ar.SA.out(S, A, W, M)(q)
    case False{}:
      Al.SR.one(W, R)

def endWeight(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, e: Ending<A>) -> W:
  match e:
    case Ending{+t, f}:
      Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, t, q), stop(~S, ~A, ~W, ~R, ~M, f, Ar.run(~S, ~A, ~W, ~M, t, q)))

# the total weight of a list of endings
def mass(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, es: List<&2, Ending<A>>) -> W:
  match es:
    case Nil{}:
      Al.SR.zero(W, R)
    case +e <> t:
      Al.SR.add(W, R)(endWeight(~S, ~A, ~W, ~R, ~M, q, e), mass(~S, ~A, ~W, ~R, ~M, q, t))

# the next-token weights over xs, summed
def stepSum(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, xs: List<&2, A>) -> W:
  match xs:
    case Nil{}:
      Al.SR.zero(W, R)
    case +x <> t:
      Al.SR.add(W, R)(Ar.weight(~S, ~A, ~W, ~M, q, x), stepSum(~S, ~A, ~W, ~R, ~M, q, t))

# each token's weight times the mass of es read after it, summed over xs
def childSum(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, xs: List<&2, A>, +es: List<&2, Ending<A>>) -> W:
  match xs:
    case Nil{}:
      Al.SR.zero(W, R)
    case +x <> t:
      Al.SR.add(W, R)(Al.SR.mul(W, R)(Ar.weight(~S, ~A, ~W, ~M, q, x), mass(~S, ~A, ~W, ~R, ~M, Ar.next(~S, ~A, ~W, ~M, q, x), es)),
                      childSum(~S, ~A, ~W, ~R, ~M, q, t, es))

# Lemmas ---------------------------------------------------------------------

def mass_append(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, es: List<&2, Ending<A>>, +fs: List<&2, Ending<A>>) ->
    {mass(~S, ~A, ~W, ~R, ~M, q, List.append(&2, Ending<A>, es, fs)) == Al.SR.add(W, R)(mass(~S, ~A, ~W, ~R, ~M, q, es), mass(~S, ~A, ~W, ~R, ~M, q, fs)) : W}:
  match es:
    case Nil{}:
      Equal.sym(W, Al.SR.add(W, R)(Al.SR.zero(W, R), mass(~S, ~A, ~W, ~R, ~M, q, fs)), mass(~S, ~A, ~W, ~R, ~M, q, fs),
        Al.SR.add_zero_l(W, R, mass(~S, ~A, ~W, ~R, ~M, q, fs)))
    case +e <> +t:
      +a = endWeight(~S, ~A, ~W, ~R, ~M, q, e)
      +b = mass(~S, ~A, ~W, ~R, ~M, q, t)
      +c = mass(~S, ~A, ~W, ~R, ~M, q, fs)
      %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q, List.append(&2, Ending<A>, t, fs)), Al.SR.add(W, R)(b, c), mass_append(~S, ~A, ~W, ~R, ~M, q, t, fs))
        : {Al.SR.add(W, R)(a, _) == Al.SR.add(W, R)(Al.SR.add(W, R)(a, b), c) : W}
      Equal.sym(W, Al.SR.add(W, R)(Al.SR.add(W, R)(a, b), c), Al.SR.add(W, R)(a, Al.SR.add(W, R)(b, c)), Al.SR.add_assoc(W, R, a, b, c))

# an ending after x weighs x's step weight times the ending's own weight
# read at the state after x
def endWeight_cons(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, +x: A, +t: List<&2, A>, +f: Bool) ->
    {endWeight(~S, ~A, ~W, ~R, ~M, q, Ending{x <> t, f})
      == Al.SR.mul(W, R)(Ar.weight(~S, ~A, ~W, ~M, q, x), endWeight(~S, ~A, ~W, ~R, ~M, Ar.next(~S, ~A, ~W, ~M, q, x), Ending{t, f})) : W}:
  +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
  Al.SR.mul_assoc(W, R, Ar.weight(~S, ~A, ~W, ~M, q, x), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, t, q2), stop(~S, ~A, ~W, ~R, ~M, f, Ar.run(~S, ~A, ~W, ~M, t, q2)))

def mass_prepend(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, +x: A, es: List<&2, Ending<A>>) ->
    {mass(~S, ~A, ~W, ~R, ~M, q, prepend(A, x, es))
      == Al.SR.mul(W, R)(Ar.weight(~S, ~A, ~W, ~M, q, x), mass(~S, ~A, ~W, ~R, ~M, Ar.next(~S, ~A, ~W, ~M, q, x), es)) : W}:
  match es:
    case Nil{}:
      Equal.sym(W, Al.SR.mul(W, R)(Ar.weight(~S, ~A, ~W, ~M, q, x), Al.SR.zero(W, R)), Al.SR.zero(W, R), Al.SR.zero_r(W, R, Ar.weight(~S, ~A, ~W, ~M, q, x)))
    case Ending{+t, +f} <> +rest:
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +w = Ar.weight(~S, ~A, ~W, ~M, q, x)
      +a = endWeight(~S, ~A, ~W, ~R, ~M, q2, Ending{t, f})
      +b = mass(~S, ~A, ~W, ~R, ~M, q2, rest)
      %Equal.sym(W, endWeight(~S, ~A, ~W, ~R, ~M, q, Ending{x <> t, f}), Al.SR.mul(W, R)(w, a), endWeight_cons(~S, ~A, ~W, ~R, ~M, q, x, t, f))
        : {Al.SR.add(W, R)(_, mass(~S, ~A, ~W, ~R, ~M, q, prepend(A, x, rest))) == Al.SR.mul(W, R)(w, Al.SR.add(W, R)(a, b)) : W}
      %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q, prepend(A, x, rest)), Al.SR.mul(W, R)(w, b), mass_prepend(~S, ~A, ~W, ~R, ~M, q, x, rest))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(w, a), _) == Al.SR.mul(W, R)(w, Al.SR.add(W, R)(a, b)) : W}
      Equal.sym(W, Al.SR.mul(W, R)(w, Al.SR.add(W, R)(a, b)), Al.SR.add(W, R)(Al.SR.mul(W, R)(w, a), Al.SR.mul(W, R)(w, b)), Al.SR.distrib_l(W, R, w, a, b))

def mass_kids(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, xs: List<&2, A>, +es: List<&2, Ending<A>>) ->
    {mass(~S, ~A, ~W, ~R, ~M, q, kids(A, xs, es)) == childSum(~S, ~A, ~W, ~R, ~M, q, xs, es) : W}:
  match xs:
    case Nil{}:
      {==}
    case +x <> +t:
      %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q, List.append(&2, Ending<A>, prepend(A, x, es), kids(A, t, es))),
          Al.SR.add(W, R)(mass(~S, ~A, ~W, ~R, ~M, q, prepend(A, x, es)), mass(~S, ~A, ~W, ~R, ~M, q, kids(A, t, es))),
          mass_append(~S, ~A, ~W, ~R, ~M, q, prepend(A, x, es), kids(A, t, es)))
        : {_ == childSum(~S, ~A, ~W, ~R, ~M, q, x <> t, es) : W}
      %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q, prepend(A, x, es)),
          Al.SR.mul(W, R)(Ar.weight(~S, ~A, ~W, ~M, q, x), mass(~S, ~A, ~W, ~R, ~M, Ar.next(~S, ~A, ~W, ~M, q, x), es)),
          mass_prepend(~S, ~A, ~W, ~R, ~M, q, x, es))
        : {Al.SR.add(W, R)(_, mass(~S, ~A, ~W, ~R, ~M, q, kids(A, t, es))) == childSum(~S, ~A, ~W, ~R, ~M, q, x <> t, es) : W}
      %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q, kids(A, t, es)), childSum(~S, ~A, ~W, ~R, ~M, q, t, es), mass_kids(~S, ~A, ~W, ~R, ~M, q, t, es))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Ar.weight(~S, ~A, ~W, ~M, q, x), mass(~S, ~A, ~W, ~R, ~M, Ar.next(~S, ~A, ~W, ~M, q, x), es)), _)
            == childSum(~S, ~A, ~W, ~R, ~M, q, x <> t, es) : W}
      {==}

# at the cutoff the one ending weighs one
def mass_cutoff(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +vs: List<&2, A>, +q: S) ->
    {mass(~S, ~A, ~W, ~R, ~M, q, ends(A, 0n, vs)) == Al.SR.one(W, R) : W}:
  %Equal.sym(W, Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.one(W, R), Al.SR.one(W, R)), Al.SR.zero(W, R)), Al.SR.mul(W, R)(Al.SR.one(W, R), Al.SR.one(W, R)),
      Al.SR.add_zero_r(~W, ~R, Al.SR.mul(W, R)(Al.SR.one(W, R), Al.SR.one(W, R))))
    : {_ == Al.SR.one(W, R) : W}
  Al.SR.mul_one_l(W, R, Al.SR.one(W, R))

# The theorem ----------------------------------------------------------------
#
# `vs` is the vocabulary and `total` the stochastic law, both templates: a
# law used at every state of an induction cannot be a hypothesis (closures
# are affine, Algebra.bend), so a model supplies it as a top-level proof.

# one step up from the cutoff: stop, or a token and then the endings below,
# given that the tokens' weights times their endings' masses are their
# weights (h, the induction below)
def mass_succ(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~vs: List<&2, A>,
              ~total: @+q:S -> {Al.SR.add(W, R)(Ar.SA.out(S, A, W, M)(q), stepSum(~S, ~A, ~W, ~R, ~M, q, vs)) == Al.SR.one(W, R) : W},
              +p: Nat, +q: S,
              h: {childSum(~S, ~A, ~W, ~R, ~M, q, vs, ends(A, p, vs)) == stepSum(~S, ~A, ~W, ~R, ~M, q, vs) : W}) ->
    {mass(~S, ~A, ~W, ~R, ~M, q, ends(A, 1n+p, vs)) == Al.SR.one(W, R) : W}:
  +o = Ar.SA.out(S, A, W, M)(q)
  +e = ends(A, p, vs)
  %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q, kids(A, vs, e)), childSum(~S, ~A, ~W, ~R, ~M, q, vs, e), mass_kids(~S, ~A, ~W, ~R, ~M, q, vs, e))
    : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.one(W, R), o), _) == Al.SR.one(W, R) : W}
  %Equal.sym(W, childSum(~S, ~A, ~W, ~R, ~M, q, vs, e), stepSum(~S, ~A, ~W, ~R, ~M, q, vs), h)
    : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.one(W, R), o), _) == Al.SR.one(W, R) : W}
  %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.one(W, R), o), o, Al.SR.mul_one_l(W, R, o))
    : {Al.SR.add(W, R)(_, stepSum(~S, ~A, ~W, ~R, ~M, q, vs)) == Al.SR.one(W, R) : W}
  total(q)

# the induction, on the cutoff first and then on the tokens: each token's
# weight times the mass of its endings is its weight, as those masses are one
def inner(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~vs: List<&2, A>,
          ~total: @+q:S -> {Al.SR.add(W, R)(Ar.SA.out(S, A, W, M)(q), stepSum(~S, ~A, ~W, ~R, ~M, q, vs)) == Al.SR.one(W, R) : W},
          +n: Nat, xs: List<&2, A>, +q: S) ->
    {childSum(~S, ~A, ~W, ~R, ~M, q, xs, ends(A, n, vs)) == stepSum(~S, ~A, ~W, ~R, ~M, q, xs) : W}:
  match n xs:
    case _ Nil{}:
      {==}
    case 0n +x <> +t:
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +w = Ar.weight(~S, ~A, ~W, ~M, q, x)
      %Equal.sym(W, childSum(~S, ~A, ~W, ~R, ~M, q, t, ends(A, 0n, vs)), stepSum(~S, ~A, ~W, ~R, ~M, q, t), inner(~S, ~A, ~W, ~R, ~M, ~vs, ~total, n, t, q))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(w, mass(~S, ~A, ~W, ~R, ~M, q2, ends(A, 0n, vs))), _) == Al.SR.add(W, R)(w, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) : W}
      %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q2, ends(A, 0n, vs)), Al.SR.one(W, R), mass_cutoff(~S, ~A, ~W, ~R, ~M, vs, q2))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(w, _), stepSum(~S, ~A, ~W, ~R, ~M, q, t)) == Al.SR.add(W, R)(w, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) : W}
      %Equal.sym(W, Al.SR.mul(W, R)(w, Al.SR.one(W, R)), w, Al.SR.mul_one_r(W, R, w))
        : {Al.SR.add(W, R)(_, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) == Al.SR.add(W, R)(w, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) : W}
      {==}
    case 1n+p +x <> +t:
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +w = Ar.weight(~S, ~A, ~W, ~M, q, x)
      %Equal.sym(W, childSum(~S, ~A, ~W, ~R, ~M, q, t, ends(A, 1n+p, vs)), stepSum(~S, ~A, ~W, ~R, ~M, q, t), inner(~S, ~A, ~W, ~R, ~M, ~vs, ~total, n, t, q))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(w, mass(~S, ~A, ~W, ~R, ~M, q2, ends(A, 1n+p, vs))), _) == Al.SR.add(W, R)(w, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) : W}
      %Equal.sym(W, mass(~S, ~A, ~W, ~R, ~M, q2, ends(A, 1n+p, vs)), Al.SR.one(W, R),
          mass_succ(~S, ~A, ~W, ~R, ~M, ~vs, ~total, p, q2, inner(~S, ~A, ~W, ~R, ~M, ~vs, ~total, p, vs, q2)))
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(w, _), stepSum(~S, ~A, ~W, ~R, ~M, q, t)) == Al.SR.add(W, R)(w, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) : W}
      %Equal.sym(W, Al.SR.mul(W, R)(w, Al.SR.one(W, R)), w, Al.SR.mul_one_r(W, R, w))
        : {Al.SR.add(W, R)(_, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) == Al.SR.add(W, R)(w, stepSum(~S, ~A, ~W, ~R, ~M, q, t)) : W}
      {==}

# Prop. 2.9: what a prefix can become, within any cutoff, weighs one in all
def sum_to_one(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~vs: List<&2, A>,
               ~total: @+q:S -> {Al.SR.add(W, R)(Ar.SA.out(S, A, W, M)(q), stepSum(~S, ~A, ~W, ~R, ~M, q, vs)) == Al.SR.one(W, R) : W},
               +n: Nat, +q: S) ->
    {mass(~S, ~A, ~W, ~R, ~M, q, ends(A, n, vs)) == Al.SR.one(W, R) : W}:
  match n:
    case 0n:
      mass_cutoff(~S, ~A, ~W, ~R, ~M, vs, q)
    case 1n+p:
      mass_succ(~S, ~A, ~W, ~R, ~M, ~vs, ~total, p, q, inner(~S, ~A, ~W, ~R, ~M, ~vs, ~total, p, vs, q))

# Instances ----------------------------------------------------------------
#
# Nat: a machine on states Bool over the one token 0: from False it takes
# the token with weight 1 and reaches True, where it stops with weight 1.
# Stochastic: at each state exactly one of stop and the token weighs 1.

def det.out(q: Bool) -> Nat:
  match q:
    case True{}:
      1n
    case False{}:
      0n

def det.w(q: Bool) -> Nat:
  match q:
    case True{}:
      0n
    case False{}:
      1n

def det.step(+q: Bool, +x: Nat) -> Ar.WS<Nat, Bool>:
  Ar.WS{det.w(q), True{}}

def det() -> Ar.StateAlgebra<Bool, Nat, Nat>:
  Ar.StateAlgebra{q => det.out(q), q => x => det.step(q, x)}

law det.total:
  for +q: Bool
  {Nat.add(det.out(q), stepSum(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~det(), q, [0n])) == 1n : Nat}

def det.total(q):
  match q:
    case True{}:
      {==}
    case False{}:
      {==}

# Bool: Autoregressive.bend's flip (stop weight q, step weight q or x) over
# both tokens: from every state some way on weighs True.
law flip.total:
  for +q: Bool
  {Bool.or(q, stepSum(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), q, [False{}, True{}])) == True{} : Bool}

def flip.total(q):
  match q:
    case True{}:
      {==}
    case False{}:
      {==}

law check.sum_to_one:
  for +n: Nat
  for +q: Bool
  for +b: Bool
  {mass(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~det(), q, ends(Nat, n, [0n])) == 1n : Nat}
  & {mass(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b, ends(Bool, n, [False{}, True{}])) == True{} : Bool}

def check.sum_to_one(n, q, b):
  (sum_to_one(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~det(), ~[0n], ~(q => det.total(q)), n, q),
   sum_to_one(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), ~[False{}, True{}], ~(q => flip.total(q)), n, b))
