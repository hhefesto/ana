import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar
import ./Trie.bend as Tr
import ./AutoregressiveTrie.bend as AT
import ./Bradley.bend as Bd
import ./Terminating.bend as Tm

# Homs are determined by residuals (the user, 2026-11-17: "then item 5
# renamed to what it proves").  The site's item was "meaning through
# Yoneda: two prefixes with the same trie of continuations have the same
# homs to every extension".  With extensions only on the right, two
# different prefixes never have the same homs in Yoneda's sense, so this is
# not Yoneda; what holds is the residual (Myhill-Nerode) statement:
#
#   hom_is_residual  for a stochastic model (Terminating.bend), the hom
#                    from a prefix to an extension e of it is the total
#                    weight of the prefix's endings that extend e (within
#                    any cutoff): a hom is a prefix probability, read off
#                    the prefix's residual language
#   prefixHom_is_residual
#                    the same for Bradley.bend's prefix morphisms
#   same_residual_same_hom
#                    so two prefixes (their states q1, q2) that give the
#                    endings extending e the same weights have the same hom
#                    to e: same continuations, same homs, extension by
#                    extension
#   finished_is_trie a finished ending's weight is what the state's trie
#                    reads at its text (AutoregressiveTrie.bend's
#                    stateTrie_denotes): the residual language's finished
#                    part is the trie of continuations, which links that
#                    file to Bradley.bend
#
# The finished flag (item 2) is what makes this go: without the endings
# that reach the cutoff unfinished, the masses would not sum to one, and a
# hom would not be the mass below it.  Checked, as Terminating.bend is, at
# the Nat and Bool stochastic machines.

# every ending of es, behind e
def under(-A: Data, e: List<&2, A>, +es: List<&2, Tm.Ending<A>>) -> List<&2, Tm.Ending<A>>:
  match e:
    case Nil{}:
      es
    case +x <> t:
      Tm.prepend(A, x, under(A, t, es))

# the mass of es behind e: e's path weight times es's mass after e
def mass_under(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, e: List<&2, A>, +es: List<&2, Tm.Ending<A>>, +q: S) ->
    {Tm.mass(~S, ~A, ~W, ~R, ~M, q, under(A, e, es))
      == Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q), Tm.mass(~S, ~A, ~W, ~R, ~M, Ar.run(~S, ~A, ~W, ~M, e, q), es)) : W}:
  match e:
    case Nil{}:
      Equal.sym(W, Al.SR.mul(W, R)(Al.SR.one(W, R), Tm.mass(~S, ~A, ~W, ~R, ~M, q, es)), Tm.mass(~S, ~A, ~W, ~R, ~M, q, es),
        Al.SR.mul_one_l(W, R, Tm.mass(~S, ~A, ~W, ~R, ~M, q, es)))
    case +x <> +t:
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +w = Ar.weight(~S, ~A, ~W, ~M, q, x)
      +pt = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, t, q2)
      +mr = Tm.mass(~S, ~A, ~W, ~R, ~M, Ar.run(~S, ~A, ~W, ~M, t, q2), es)
      %Equal.sym(W, Tm.mass(~S, ~A, ~W, ~R, ~M, q, Tm.prepend(A, x, under(A, t, es))), Al.SR.mul(W, R)(w, Tm.mass(~S, ~A, ~W, ~R, ~M, q2, under(A, t, es))),
          Tm.mass_prepend(~S, ~A, ~W, ~R, ~M, q, x, under(A, t, es)))
        : {_ == Al.SR.mul(W, R)(Al.SR.mul(W, R)(w, pt), mr) : W}
      %Equal.sym(W, Tm.mass(~S, ~A, ~W, ~R, ~M, q2, under(A, t, es)), Al.SR.mul(W, R)(pt, mr), mass_under(~S, ~A, ~W, ~R, ~M, t, es, q2))
        : {Al.SR.mul(W, R)(w, _) == Al.SR.mul(W, R)(Al.SR.mul(W, R)(w, pt), mr) : W}
      Equal.sym(W, Al.SR.mul(W, R)(Al.SR.mul(W, R)(w, pt), mr), Al.SR.mul(W, R)(w, Al.SR.mul(W, R)(pt, mr)), Al.SR.mul_assoc(W, R, w, pt, mr))

# a hom is the mass of the endings below it
def hom_is_residual(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~vs: List<&2, A>,
                    ~total: @+q:S -> {Al.SR.add(W, R)(Ar.SA.out(S, A, W, M)(q), Tm.stepSum(~S, ~A, ~W, ~R, ~M, q, vs)) == Al.SR.one(W, R) : W},
                    +n: Nat, +e: List<&2, A>, +q: S) ->
    {Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q) == Tm.mass(~S, ~A, ~W, ~R, ~M, q, under(A, e, Tm.ends(A, n, vs))) : W}:
  +pe = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q)
  +qe = Ar.run(~S, ~A, ~W, ~M, e, q)
  +me = Tm.mass(~S, ~A, ~W, ~R, ~M, qe, Tm.ends(A, n, vs))
  %Equal.sym(W, Tm.mass(~S, ~A, ~W, ~R, ~M, q, under(A, e, Tm.ends(A, n, vs))), Al.SR.mul(W, R)(pe, me), mass_under(~S, ~A, ~W, ~R, ~M, e, Tm.ends(A, n, vs), q))
    : {pe == _ : W}
  %Equal.sym(W, me, Al.SR.one(W, R), Tm.sum_to_one(~S, ~A, ~W, ~R, ~M, ~vs, ~total, n, qe)) : {pe == Al.SR.mul(W, R)(pe, _) : W}
  Equal.sym(W, Al.SR.mul(W, R)(pe, Al.SR.one(W, R)), pe, Al.SR.mul_one_r(W, R, pe))

# Bradley's prefix morphisms: the hom of xs -> ys, read at q (the state xs
# reaches), is the mass of q's endings that pass through ys
def prefixHom_is_residual(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~vs: List<&2, A>,
                          ~total: @+q:S -> {Al.SR.add(W, R)(Ar.SA.out(S, A, W, M)(q), Tm.stepSum(~S, ~A, ~W, ~R, ~M, q, vs)) == Al.SR.one(W, R) : W},
                          +n: Nat, +q: S, +xs: List<&2, A>, +ext: List<&2, A>) ->
    {Bd.prefixHom(~S, ~A, ~W, ~R, ~M, q, xs, List.append(&2, A, xs, ext), (ext, {==}))
      == Tm.mass(~S, ~A, ~W, ~R, ~M, q, under(A, ext, Tm.ends(A, n, vs))) : W}:
  hom_is_residual(~S, ~A, ~W, ~R, ~M, ~vs, ~total, n, ext, q)

# the weights of a list of endings, one by one
def weightsOf(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, es: List<&2, Tm.Ending<A>>) -> List<&2, W>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> t:
      Tm.endWeight(~S, ~A, ~W, ~R, ~M, q, e) <> weightsOf(~S, ~A, ~W, ~R, ~M, q, t)

def mass_weights(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, es: List<&2, Tm.Ending<A>>) ->
    {Tm.mass(~S, ~A, ~W, ~R, ~M, q, es) == Ar.listSum(~W, ~R, weightsOf(~S, ~A, ~W, ~R, ~M, q, es)) : W}:
  match es:
    case Nil{}:
      {==}
    case +e <> +t:
      %mass_weights(~S, ~A, ~W, ~R, ~M, q, t)
        : {Al.SR.add(W, R)(Tm.endWeight(~S, ~A, ~W, ~R, ~M, q, e), Tm.mass(~S, ~A, ~W, ~R, ~M, q, t))
            == Al.SR.add(W, R)(Tm.endWeight(~S, ~A, ~W, ~R, ~M, q, e), _) : W}
      {==}

# same continuations, same homs: two states whose endings behind e weigh
# the same, ending by ending, have the same hom to e
def same_residual_same_hom(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~vs: List<&2, A>,
                           ~total: @+q:S -> {Al.SR.add(W, R)(Ar.SA.out(S, A, W, M)(q), Tm.stepSum(~S, ~A, ~W, ~R, ~M, q, vs)) == Al.SR.one(W, R) : W},
                           +n: Nat, +e: List<&2, A>, +q1: S, +q2: S,
                           h: {weightsOf(~S, ~A, ~W, ~R, ~M, q1, under(A, e, Tm.ends(A, n, vs))) == weightsOf(~S, ~A, ~W, ~R, ~M, q2, under(A, e, Tm.ends(A, n, vs))) : List<&2, W>}) ->
    {Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q1) == Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q2) : W}:
  +es = under(A, e, Tm.ends(A, n, vs))
  %Equal.sym(W, Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q1), Tm.mass(~S, ~A, ~W, ~R, ~M, q1, es), hom_is_residual(~S, ~A, ~W, ~R, ~M, ~vs, ~total, n, e, q1))
    : {_ == Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q2) : W}
  %Equal.sym(W, Ar.pathWeight(~S, ~A, ~W, ~R, ~M, e, q2), Tm.mass(~S, ~A, ~W, ~R, ~M, q2, es), hom_is_residual(~S, ~A, ~W, ~R, ~M, ~vs, ~total, n, e, q2))
    : {Tm.mass(~S, ~A, ~W, ~R, ~M, q1, es) == _ : W}
  %Equal.sym(W, Tm.mass(~S, ~A, ~W, ~R, ~M, q1, es), Ar.listSum(~W, ~R, weightsOf(~S, ~A, ~W, ~R, ~M, q1, es)), mass_weights(~S, ~A, ~W, ~R, ~M, q1, es))
    : {_ == Tm.mass(~S, ~A, ~W, ~R, ~M, q2, es) : W}
  %Equal.sym(W, Tm.mass(~S, ~A, ~W, ~R, ~M, q2, es), Ar.listSum(~W, ~R, weightsOf(~S, ~A, ~W, ~R, ~M, q2, es)), mass_weights(~S, ~A, ~W, ~R, ~M, q2, es))
    : {Ar.listSum(~W, ~R, weightsOf(~S, ~A, ~W, ~R, ~M, q1, es)) == _ : W}
  %h : {Ar.listSum(~W, ~R, weightsOf(~S, ~A, ~W, ~R, ~M, q1, es)) == Ar.listSum(~W, ~R, _) : W}
  {==}

# a finished ending weighs what the state's trie reads at its text
def finished_is_trie(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, +t: List<&2, A>) ->
    {Tm.endWeight(~S, ~A, ~W, ~R, ~M, q, Tm.Ending{t, True{}})
      == Tr.toLanguage(Tr.len(A, t), A, W, t, AT.stateTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, t), q)) : W}:
  Equal.sym(W, Tr.toLanguage(Tr.len(A, t), A, W, t, AT.stateTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, t), q)), Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, t),
    AT.stateTrie_denotes(~S, ~A, ~W, ~R, ~M, t, q))

# Instances ----------------------------------------------------------------

law check.residual:
  for +n: Nat
  for +e: List<&2, Nat>
  for +q: Bool
  for +bs: List<&2, Bool>
  for +b: Bool
  for +xs: List<&2, Bool>
  for +b1: Bool
  for +b2: Bool
  for +h: {weightsOf(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b1, under(Bool, bs, Tm.ends(Bool, n, [False{}, True{}])))
           == weightsOf(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b2, under(Bool, bs, Tm.ends(Bool, n, [False{}, True{}]))) : List<&2, Bool>}
  {Ar.pathWeight(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Tm.det(), e, q) == Tm.mass(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Tm.det(), q, under(Nat, e, Tm.ends(Nat, n, [0n]))) : Nat}
  & {Bd.prefixHom(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b, xs, List.append(&2, Bool, xs, bs), (bs, {==}))
      == Tm.mass(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b, under(Bool, bs, Tm.ends(Bool, n, [False{}, True{}]))) : Bool}
  & {Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), bs, b1) == Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), bs, b2) : Bool}
  & {Tm.endWeight(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Tm.det(), q, Tm.Ending{e, True{}})
      == Tr.toLanguage(Tr.len(Nat, e), Nat, Nat, e, AT.stateTrie(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Tm.det(), Tr.len(Nat, e), q)) : Nat}

def check.residual(n, e, q, bs, b, xs, b1, b2, h):
  (hom_is_residual(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Tm.det(), ~[0n], ~(q => Tm.det.total(q)), n, e, q),
   prefixHom_is_residual(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), ~[False{}, True{}], ~(q => Tm.flip.total(q)), n, b, xs, bs),
   same_residual_same_hom(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), ~[False{}, True{}], ~(q => Tm.flip.total(q)), n, bs, b1, b2, h),
   finished_is_trie(~Bool, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Tm.det(), q, e))
