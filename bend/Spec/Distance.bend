import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar
import ./Bradley.bend as Bd
import ./Nat.bend as NL

# Bradley's category made a distance (the user, 2026-11-17: "item 3 first,
# with item 1 as its checkpoint test done in log space").
#
# Bradley.bend's hom from a prefix to an extension of it is the path weight
# of the extension: the product of the model's step weights.  A LOG is a map
# from weights to costs that sends one to zero and products to sums; at the
# probability carrier it is -ln.  Through a log the category becomes a
# metric one: the cost of a prefix morphism is the sum of its steps' costs,
# identities cost zero and costs add along a chain of prefixes (the chain
# rule of Autoregressive.bend, read through the log).
#
# The trainer.  Dense/Model.bend's head charges prediction i of a window
# lse - logit[target], times the target's weight (Dense/Layout.bend
# Lay.tw), and head.windows sums them.  A window x0 x1 .. xn is read from
# zero state; x0 is input only (no start token: nothing predicts it), so
# what the trainer sums is the cost of the morphism from the one-token
# prefix [x0] to the window, NOT from the empty text.  Here it is
# `windowLoss`, over any per-step cost `ce` that is the log of the step
# weight (`ce_law`); the theorems:
#
#   log_path            the log of a path weight is the sum of its steps'
#                       costs
#   cost_identity       an identity morphism costs zero
#   cost_composition    costs add along a chain: us then vs costs the cost
#                       of us plus the cost of vs read at the state us
#                       reaches
#   window_is_distance  a window's loss with every weight 1 is the cost of
#                       the morphism [x0] -> window
#   masked_runs         with Mask.bend's 0/1 weights (0 on a tool's echo
#                       and on a given attempt) a window's loss is a sum of
#                       such costs, one per run of weight-1 targets, each
#                       measured from the prefix before that run; it is one
#                       distance only when the weight-0 targets all come
#                       first (a prompt)
#
# What is proven and what is trusted.  Everything below is proven for every
# semiring, cost monoid and log, and checked (Bend2 checks a template per
# instance) at two lawful logs on two carriers: Bool.not from (Bool, and)
# to (Bool, or) and "is zero" from (Nat, *) to (Bool, or) (-ln 0 is
# infinite: zero-ness is the part of -ln that Nat has).  At F32, -ln is a
# log only by trust: F32 is axiomatic in Bend2, and that -ln(softmax(l)[x])
# = lse(l) - l[x] is Trusted.bend's TrustedLog, not a theorem.  That the
# trainer's ops compute this windowLoss, and the decoder the same costs, is
# tested on a checkpoint in log space (tests/bradley.bend), not proven.

# A log: weights (a semiring's product) to costs (a monoid's sum)
type Log<-W: Data, -D: Data, -R: Al.Semiring<W>, -Mo: Al.Monoid<D>> is Type:
  Log{nl: W -> D,
      nl_one: {nl(Al.SR.one(W, R)) == Al.MO.zero(D, Mo) : D},
      nl_mul: @+x:W -> @+y:W -> {nl(Al.SR.mul(W, R)(x, y)) == Al.MO.add(D, Mo)(nl(x), nl(y)) : D}}

def Log.nl(-W: Data, -D: Data, -R: Al.Semiring<W>, -Mo: Al.Monoid<D>, l: Log<W, D, R, Mo>) -> W -> D:
  match l:
    case Log{f, p1, p2}:
      f

def Log.nl_one(-W: Data, -D: Data, -R: Al.Semiring<W>, -Mo: Al.Monoid<D>, l: Log<W, D, R, Mo>) ->
    {Log.nl(W, D, R, Mo, l)(Al.SR.one(W, R)) == Al.MO.zero(D, Mo) : D}:
  match l:
    case Log{f, p1, p2}:
      p1

def Log.nl_mul(-W: Data, -D: Data, -R: Al.Semiring<W>, -Mo: Al.Monoid<D>, l: Log<W, D, R, Mo>) ->
    @+x:W -> @+y:W -> {Log.nl(W, D, R, Mo, l)(Al.SR.mul(W, R)(x, y)) == Al.MO.add(D, Mo)(Log.nl(W, D, R, Mo, l)(x), Log.nl(W, D, R, Mo, l)(y)) : D}:
  match l:
    case Log{f, p1, p2}:
      p2

# Costs along a path ---------------------------------------------------------

# the trainer's sum along xs from state q: each step charged `ce` at the
# state before it (the prediction reads the prefix, the target is the token)
def lossAlong(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>, ~ce: S -> A -> D,
              xs: List<&2, A>, +q: S) -> D:
  match xs:
    case Nil{}:
      Al.MO.zero(D, Mo)
    case +x <> t:
      Al.MO.add(D, Mo)(ce(q, x), lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, Ar.next(~S, ~A, ~W, ~M, q, x)))

# the log of a path weight is the sum of its steps' costs
def log_path(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~R: Al.Semiring<W>, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>,
             ~L: Log<W, D, R, Mo>, ~ce: S -> A -> D,
             ~ce_law: @+q:S -> @+x:A -> {Log.nl(W, D, R, Mo, L)(Ar.weight(~S, ~A, ~W, ~M, q, x)) == ce(q, x) : D},
             xs: List<&2, A>, +q: S) ->
    {Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, xs, q)) == lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, xs, q) : D}:
  match xs:
    case Nil{}:
      Log.nl_one(W, D, R, Mo, L)
    case +x <> +t:
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +w = Ar.weight(~S, ~A, ~W, ~M, q, x)
      +pt = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, t, q2)
      %log_path(~S, ~A, ~W, ~D, ~R, ~Mo, ~M, ~L, ~ce, ~ce_law, t, q2)
        : {Log.nl(W, D, R, Mo, L)(Al.SR.mul(W, R)(w, pt)) == Al.MO.add(D, Mo)(ce(q, x), _) : D}
      %ce_law(q, x) : {Log.nl(W, D, R, Mo, L)(Al.SR.mul(W, R)(w, pt)) == Al.MO.add(D, Mo)(_, Log.nl(W, D, R, Mo, L)(pt)) : D}
      Log.nl_mul(W, D, R, Mo, L, w, pt)

# an identity morphism costs zero
def cost_identity(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~R: Al.Semiring<W>, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>,
                  ~L: Log<W, D, R, Mo>, +q: S, +xs: List<&2, A>) ->
    {Log.nl(W, D, R, Mo, L)(Bd.prefixHom(~S, ~A, ~W, ~R, ~M, q, xs, xs, Bd.identityPrefix(A, xs))) == Al.MO.zero(D, Mo) : D}:
  Log.nl_one(W, D, R, Mo, L)

# costs add along a chain of prefixes: Bradley's composition, through the log
def cost_composition(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~R: Al.Semiring<W>, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>,
                     ~L: Log<W, D, R, Mo>, +q: S, +us: List<&2, A>, +vs: List<&2, A>) ->
    {Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, us, vs), q))
      == Al.MO.add(D, Mo)(Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, us, q)),
                          Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, vs, Ar.run(~S, ~A, ~W, ~M, us, q)))) : D}:
  +pu = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, us, q)
  +pv = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, vs, Ar.run(~S, ~A, ~W, ~M, us, q))
  %Equal.sym(W, Ar.pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, us, vs), q), Al.SR.mul(W, R)(pu, pv), Bd.composition_hom(~S, ~A, ~W, ~R, ~M, q, us, vs))
    : {Log.nl(W, D, R, Mo, L)(_) == Al.MO.add(D, Mo)(Log.nl(W, D, R, Mo, L)(pu), Log.nl(W, D, R, Mo, L)(pv)) : D}
  Log.nl_mul(W, D, R, Mo, L, pu, pv)

# the trainer's sums add the same way, with no log in sight
def loss_append(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>, ~ce: S -> A -> D,
                us: List<&2, A>, +vs: List<&2, A>, +q: S) ->
    {lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, us, vs), q)
      == Al.MO.add(D, Mo)(lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, us, q), lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, vs, Ar.run(~S, ~A, ~W, ~M, us, q))) : D}:
  match us:
    case Nil{}:
      Equal.sym(D, Al.MO.add(D, Mo)(Al.MO.zero(D, Mo), lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, vs, q)), lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, vs, q),
        Al.MO.add_zero_l(D, Mo, lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, vs, q)))
    case +x <> +t:
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +c = ce(q, x)
      +lt = lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, q2)
      +lv = lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, vs, Ar.run(~S, ~A, ~W, ~M, t, q2))
      %Equal.sym(D, lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, t, vs), q2), Al.MO.add(D, Mo)(lt, lv), loss_append(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, vs, q2))
        : {Al.MO.add(D, Mo)(c, _) == Al.MO.add(D, Mo)(Al.MO.add(D, Mo)(c, lt), lv) : D}
      Equal.sym(D, Al.MO.add(D, Mo)(Al.MO.add(D, Mo)(c, lt), lv), Al.MO.add(D, Mo)(c, Al.MO.add(D, Mo)(lt, lv)), Al.MO.add_assoc(D, Mo, c, lt, lv))

# Windows ------------------------------------------------------------------

# a window x0 x1 .. xn from state q0 (zero state): x0 is input only, and
# prediction i is charged at target x_{i+1}; every weight 1
def windowLoss(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>, ~ce: S -> A -> D,
               w: List<&2, A>, +q0: S) -> D:
  match w:
    case Nil{}:
      Al.MO.zero(D, Mo)
    case +x0 <> xs:
      lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, xs, Ar.next(~S, ~A, ~W, ~M, q0, x0))

# the window extends its first token
def firstPrefix(-A: Data, +x0: A, +xs: List<&2, A>) -> Bd.Prefix(A, [x0], x0 <> xs):
  (xs, {==})

# a window's loss is the cost of the morphism from its first token to it
def window_is_distance(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~R: Al.Semiring<W>, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>,
                       ~L: Log<W, D, R, Mo>, ~ce: S -> A -> D,
                       ~ce_law: @+q:S -> @+x:A -> {Log.nl(W, D, R, Mo, L)(Ar.weight(~S, ~A, ~W, ~M, q, x)) == ce(q, x) : D},
                       +q0: S, +x0: A, +xs: List<&2, A>) ->
    {windowLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, x0 <> xs, q0)
      == Log.nl(W, D, R, Mo, L)(Bd.prefixHom(~S, ~A, ~W, ~R, ~M, Ar.run(~S, ~A, ~W, ~M, [x0], q0), [x0], x0 <> xs, firstPrefix(A, x0, xs))) : D}:
  +q1 = Ar.next(~S, ~A, ~W, ~M, q0, x0)
  Equal.sym(D, Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, xs, q1)), lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, xs, q1),
    log_path(~S, ~A, ~W, ~D, ~R, ~Mo, ~M, ~L, ~ce, ~ce_law, xs, q1))

# Masked windows -------------------------------------------------------------
#
# Mask.bend weighs each target 0 or 1 (Agent/Spec.bend ag.weight), the
# trainer multiplies each prediction's loss by it: here a Bool per target.

def maskedLoss(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>, ~ce: S -> A -> D,
               xs: List<&2, A>, ms: List<&2, Bool>, +q: S) -> D:
  match xs ms:
    case +x <> t True{} <> mt:
      Al.MO.add(D, Mo)(ce(q, x), maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, mt, Ar.next(~S, ~A, ~W, ~M, q, x)))
    case +x <> t False{} <> mt:
      maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, mt, Ar.next(~S, ~A, ~W, ~M, q, x))
    case _ _:
      Al.MO.zero(D, Mo)

# weight 0 on each of xs (given), weight 1 on each (kept)
def given(-A: Data, xs: List<&2, A>) -> List<&2, Bool>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      False{} <> given(A, t)

def kept(-A: Data, xs: List<&2, A>) -> List<&2, Bool>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      True{} <> kept(A, t)

# given targets are read, not charged: the loss goes on from the state they reach
def masked_given(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>, ~ce: S -> A -> D,
                 ps: List<&2, A>, +rest: List<&2, A>, +m2: List<&2, Bool>, +q: S) ->
    {maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, rest), List.append(&2, Bool, given(A, ps), m2), q)
      == maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, Ar.run(~S, ~A, ~W, ~M, ps, q)) : D}:
  match ps:
    case Nil{}:
      {==}
    case +x <> t:
      masked_given(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, rest, m2, Ar.next(~S, ~A, ~W, ~M, q, x))

# kept targets are charged as the unmasked loss is
def masked_kept(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>, ~ce: S -> A -> D,
                cs: List<&2, A>, +rest: List<&2, A>, +m2: List<&2, Bool>, +q: S) ->
    {maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, cs, rest), List.append(&2, Bool, kept(A, cs), m2), q)
      == Al.MO.add(D, Mo)(lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q), maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, Ar.run(~S, ~A, ~W, ~M, cs, q))) : D}:
  match cs:
    case Nil{}:
      Equal.sym(D, Al.MO.add(D, Mo)(Al.MO.zero(D, Mo), maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, q)), maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, q),
        Al.MO.add_zero_l(D, Mo, maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, q)))
    case +x <> +t:
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +c = ce(q, x)
      +lt = lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, q2)
      +mr = maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, Ar.run(~S, ~A, ~W, ~M, t, q2))
      %Equal.sym(D, maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, t, rest), List.append(&2, Bool, kept(A, t), m2), q2), Al.MO.add(D, Mo)(lt, mr),
          masked_kept(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, rest, m2, q2))
        : {Al.MO.add(D, Mo)(c, _) == Al.MO.add(D, Mo)(Al.MO.add(D, Mo)(c, lt), mr) : D}
      Equal.sym(D, Al.MO.add(D, Mo)(Al.MO.add(D, Mo)(c, lt), mr), Al.MO.add(D, Mo)(c, Al.MO.add(D, Mo)(lt, mr)), Al.MO.add_assoc(D, Mo, c, lt, mr))

# A masked loss is a sum of distances, one per run of kept targets: a
# given run ps, then a kept run cs, then the rest of the window, costs
# cs's distance from the prefix ending in ps (read at the state ps
# reaches), plus the rest's masked loss from the state ps ++ cs reaches.
def masked_runs(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~R: Al.Semiring<W>, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>,
                ~L: Log<W, D, R, Mo>, ~ce: S -> A -> D,
                ~ce_law: @+q:S -> @+x:A -> {Log.nl(W, D, R, Mo, L)(Ar.weight(~S, ~A, ~W, ~M, q, x)) == ce(q, x) : D},
                +ps: List<&2, A>, +cs: List<&2, A>, +rest: List<&2, A>, +m2: List<&2, Bool>, +q: S) ->
    {maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, List.append(&2, A, cs, rest)),
                List.append(&2, Bool, given(A, ps), List.append(&2, Bool, kept(A, cs), m2)), q)
      == Al.MO.add(D, Mo)(Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, cs, Ar.run(~S, ~A, ~W, ~M, ps, q))),
                          maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, Ar.run(~S, ~A, ~W, ~M, List.append(&2, A, ps, cs), q))) : D}:
  +q2 = Ar.run(~S, ~A, ~W, ~M, ps, q)
  +mr = maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, Ar.run(~S, ~A, ~W, ~M, cs, q2))
  %Equal.sym(S, Ar.run(~S, ~A, ~W, ~M, List.append(&2, A, ps, cs), q), Ar.run(~S, ~A, ~W, ~M, cs, q2), Ar.run_append(~S, ~A, ~W, ~M, ps, q, cs))
    : {maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, List.append(&2, A, cs, rest)), List.append(&2, Bool, given(A, ps), List.append(&2, Bool, kept(A, cs), m2)), q)
        == Al.MO.add(D, Mo)(Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, cs, q2)), maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, rest, m2, _)) : D}
  %Equal.sym(D, Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, cs, q2)), lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q2),
      log_path(~S, ~A, ~W, ~D, ~R, ~Mo, ~M, ~L, ~ce, ~ce_law, cs, q2))
    : {maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, List.append(&2, A, cs, rest)), List.append(&2, Bool, given(A, ps), List.append(&2, Bool, kept(A, cs), m2)), q)
        == Al.MO.add(D, Mo)(_, mr) : D}
  Equal.trans(D,
    maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, List.append(&2, A, cs, rest)), List.append(&2, Bool, given(A, ps), List.append(&2, Bool, kept(A, cs), m2)), q),
    maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, cs, rest), List.append(&2, Bool, kept(A, cs), m2), q2),
    Al.MO.add(D, Mo)(lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q2), mr),
    masked_given(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, ps, List.append(&2, A, cs, rest), List.append(&2, Bool, kept(A, cs), m2), q),
    masked_kept(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, rest, m2, q2))

# every target kept: the masked loss is the plain one
def masked_all(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>, ~ce: S -> A -> D,
               cs: List<&2, A>, +q: S) ->
    {maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, kept(A, cs), q) == lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q) : D}:
  match cs:
    case Nil{}:
      {==}
    case +x <> +t:
      %masked_all(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, Ar.next(~S, ~A, ~W, ~M, q, x))
        : {Al.MO.add(D, Mo)(ce(q, x), maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, t, kept(A, t), Ar.next(~S, ~A, ~W, ~M, q, x))) == Al.MO.add(D, Mo)(ce(q, x), _) : D}
      {==}

# A prompt: given targets first, then kept ones to the window's end.  Then
# the masked loss is one distance: from the prompt to the window.
def prompt_is_distance(~S: Data, ~A: Data, ~W: Data, ~D: Data, ~R: Al.Semiring<W>, ~Mo: Al.Monoid<D>, ~M: Ar.StateAlgebra<S, A, W>,
                       ~L: Log<W, D, R, Mo>, ~ce: S -> A -> D,
                       ~ce_law: @+q:S -> @+x:A -> {Log.nl(W, D, R, Mo, L)(Ar.weight(~S, ~A, ~W, ~M, q, x)) == ce(q, x) : D},
                       +ps: List<&2, A>, +cs: List<&2, A>, +q: S) ->
    {maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, cs), List.append(&2, Bool, given(A, ps), kept(A, cs)), q)
      == Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, cs, Ar.run(~S, ~A, ~W, ~M, ps, q))) : D}:
  +q2 = Ar.run(~S, ~A, ~W, ~M, ps, q)
  Equal.trans(D,
    maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, cs), List.append(&2, Bool, given(A, ps), kept(A, cs)), q),
    lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q2),
    Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, cs, q2)),
    Equal.trans(D,
      maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, List.append(&2, A, ps, cs), List.append(&2, Bool, given(A, ps), kept(A, cs)), q),
      maskedLoss(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, kept(A, cs), q2),
      lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q2),
      masked_given(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, ps, cs, kept(A, cs), q),
      masked_all(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q2)),
    Equal.sym(D, Log.nl(W, D, R, Mo, L)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, cs, q2)), lossAlong(~S, ~A, ~W, ~D, ~Mo, ~M, ~ce, cs, q2),
      log_path(~S, ~A, ~W, ~D, ~R, ~Mo, ~M, ~L, ~ce, ~ce_law, cs, q2)))

# Instances ----------------------------------------------------------------
#
# Two lawful logs on two carriers.  Bool.not takes (Bool, and, True) to
# (Bool, or, False): De Morgan.  "Is zero" takes (Nat, *, 1) to (Bool, or,
# False): a product is zero when a factor is, the part of -ln (whose value
# at 0 is infinite) that Nat can say.

law not.mul:
  for +x: Bool
  for +y: Bool
  {Bool.not(Bool.and(x, y)) == Bool.or(Bool.not(x), Bool.not(y)) : Bool}

def not.mul(x, y):
  match x:
    case True{}:
      {==}
    case False{}:
      {==}

def notLog() -> Log<Bool, Bool, Al.Bool.semiring(), Al.Bool.monoid()>:
  Log{x => Bool.not(x), {==}, not.mul}

def nz(n: Nat) -> Bool:
  match n:
    case 0n:
      True{}
    case 1n+p:
      False{}

law nz.mul:
  for +x: Nat
  for +y: Nat
  {nz(Nat.mul(x, y)) == Bool.or(nz(x), nz(y)) : Bool}

def nz.mul(x, y):
  match x y:
    case 0n _:
      {==}
    case 1n+p 0n:
      %Equal.sym(Nat, Nat.mul(p, 0n), 0n, NL.Nat.mul_zero_r(p)) : {nz(_) == True{} : Bool}
      {==}
    case 1n+p 1n+r:
      {==}

def nzLog() -> Log<Nat, Bool, Al.Nat.semiring(), Al.Bool.monoid()>:
  Log{x => nz(x), {==}, nz.mul}

# flip's step weight is q or x; its cost, written directly, is De Morgan's
def flip.ce(+q: Bool, +x: Bool) -> Bool:
  Bool.and(Bool.not(q), Bool.not(x))

law flip.ce_law:
  for +q: Bool
  for +x: Bool
  {Bool.not(Ar.weight(~Bool, ~Bool, ~Bool, ~Ar.flip(), q, x)) == flip.ce(q, x) : Bool}

def flip.ce_law(q, x):
  match q:
    case True{}:
      {==}
    case False{}:
      {==}

# count's step weight is 1 + x, never zero
def count.ce(+q: Nat, +x: Nat) -> Bool:
  False{}

law count.ce_law:
  for +q: Nat
  for +x: Nat
  {nz(Ar.weight(~Nat, ~Nat, ~Nat, ~Ar.count(), q, x)) == count.ce(q, x) : Bool}

def count.ce_law(q, x):
  {==}

law check.distance:
  for +b: Bool
  for +bs: List<&2, Bool>
  for +cs: List<&2, Bool>
  for +q: Nat
  for +x0: Nat
  for +xs: List<&2, Nat>
  for +ps: List<&2, Nat>
  for +ks: List<&2, Nat>
  for +rest: List<&2, Nat>
  for +m2: List<&2, Bool>
  {Bool.not(Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), bs, b))
      == lossAlong(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.monoid(), ~Ar.flip(), ~(q => x => flip.ce(q, x)), bs, b) : Bool}
  & {Bool.not(Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), List.append(&2, Bool, bs, cs), b))
      == Bool.or(Bool.not(Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), bs, b)),
                 Bool.not(Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), cs, Ar.run(~Bool, ~Bool, ~Bool, ~Ar.flip(), bs, b)))) : Bool}
  & {nz(Bd.prefixHom(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), q, xs, xs, Bd.identityPrefix(Nat, xs))) == False{} : Bool}
  & {windowLoss(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Bool.monoid(), ~Ar.count(), ~(q => x => count.ce(q, x)), x0 <> xs, q)
      == nz(Bd.prefixHom(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), [x0], q), [x0], x0 <> xs, firstPrefix(Nat, x0, xs))) : Bool}
  & {maskedLoss(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Bool.monoid(), ~Ar.count(), ~(q => x => count.ce(q, x)), List.append(&2, Nat, ps, List.append(&2, Nat, ks, rest)),
                List.append(&2, Bool, given(Nat, ps), List.append(&2, Bool, kept(Nat, ks), m2)), q)
      == Bool.or(nz(Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), ks, Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), ps, q))),
                 maskedLoss(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Bool.monoid(), ~Ar.count(), ~(q => x => count.ce(q, x)), rest, m2, Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), List.append(&2, Nat, ps, ks), q))) : Bool}
  & {maskedLoss(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Bool.monoid(), ~Ar.count(), ~(q => x => count.ce(q, x)), List.append(&2, Nat, ps, ks), List.append(&2, Bool, given(Nat, ps), kept(Nat, ks)), q)
      == nz(Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), ks, Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), ps, q))) : Bool}

def check.distance(b, bs, cs, q, x0, xs, ps, ks, rest, m2):
  (log_path(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Al.Bool.monoid(), ~Ar.flip(), ~notLog(), ~(q => x => flip.ce(q, x)), ~(q => x => flip.ce_law(q, x)), bs, b),
   cost_composition(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Al.Bool.monoid(), ~Ar.flip(), ~notLog(), b, bs, cs),
   cost_identity(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Nat.semiring(), ~Al.Bool.monoid(), ~Ar.count(), ~nzLog(), q, xs),
   window_is_distance(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Nat.semiring(), ~Al.Bool.monoid(), ~Ar.count(), ~nzLog(), ~(q => x => count.ce(q, x)), ~(q => x => count.ce_law(q, x)), q, x0, xs),
   masked_runs(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Nat.semiring(), ~Al.Bool.monoid(), ~Ar.count(), ~nzLog(), ~(q => x => count.ce(q, x)), ~(q => x => count.ce_law(q, x)), ps, ks, rest, m2, q),
   prompt_is_distance(~Nat, ~Nat, ~Nat, ~Bool, ~Al.Nat.semiring(), ~Al.Bool.monoid(), ~Ar.count(), ~nzLog(), ~(q => x => count.ce(q, x)), ~(q => x => count.ce_law(q, x)), ps, ks, q))

law check.loss_append:
  for +bs: List<&2, Bool>
  for +cs: List<&2, Bool>
  for +b: Bool
  {lossAlong(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.monoid(), ~Ar.flip(), ~(q => x => flip.ce(q, x)), List.append(&2, Bool, bs, cs), b)
    == Bool.or(lossAlong(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.monoid(), ~Ar.flip(), ~(q => x => flip.ce(q, x)), bs, b),
               lossAlong(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.monoid(), ~Ar.flip(), ~(q => x => flip.ce(q, x)), cs, Ar.run(~Bool, ~Bool, ~Bool, ~Ar.flip(), bs, b))) : Bool}

def check.loss_append(bs, cs, b):
  loss_append(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.monoid(), ~Ar.flip(), ~(q => x => flip.ce(q, x)), bs, cs, b)
