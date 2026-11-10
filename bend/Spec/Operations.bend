import Base
import ./Algebra.bend as Al
import ./Weighted.bend as Wt
import ./Trie.bend as Tr
import ./Autoregressive.bend as Ar

# Elliott's language operations (Calculus.lagda's ν/δ lemmas), over a
# semiring of weights instead of Set: Elliott's ∪ is the sum, · the
# scaling, ∩ the product, ⋆ the concatenation.  The decoder uses two of
# them (Generate.bend, Agent/Loop.bend):
#
#   the sum of two scaled models is a mixture, and `mixture_residual`
#   says what decoding it after a prefix means: each model's own
#   continuation, weighted by its coefficient times its weight of the
#   prefix (the posterior);
#
#   the product of the model with `avoid(T)`, the language that crosses
#   out the one word T, is the retry after T failed its check.
#   `product_on_path` says that while the retry follows T it is the
#   model's continuation times avoid(the rest of T), `avoid_leave` that
#   once it leaves T the filter is 1 (the model alone), `avoid_self` that
#   T itself weighs 0, and `product_complement` that the product loses
#   exactly T's weight (M = M × avoid(T) + M × word(T), word(T) the one
#   word): the normalizer the decoder divides by.
#
# The codomain operations (sum, scaling, product, ∅, 𝒰) never look at the
# word, so their ν/δ laws are reflexivity, as in Elliott's Agda; they are
# stated generically, for every language.  Concatenation and the word
# filters split or compare the word, so their laws are proofs: theorem
# templates (a language used many times is a template, Spec/Trie.bend),
# checked at the instances at the end of the file.

# The codomain operations ---------------------------------------------------

def Lang.empty(-A: Data, -W: Data, R: Al.Semiring<W>) -> Wt.Language(A, W):
  s => Al.SR.zero(W, R)

def Lang.every(-A: Data, -W: Data, R: Al.Semiring<W>) -> Wt.Language(A, W):
  s => Al.SR.one(W, R)

def Lang.sum(-A: Data, -W: Data, R: Al.Semiring<W>, P: Wt.Language(A, W), Q: Wt.Language(A, W)) -> Wt.Language(A, W):
  +s => Al.SR.add(W, R)(P(s), Q(s))

def Lang.scale(-A: Data, -W: Data, R: Al.Semiring<W>, c: W, P: Wt.Language(A, W)) -> Wt.Language(A, W):
  s => Al.SR.mul(W, R)(c, P(s))

def Lang.product(-A: Data, -W: Data, R: Al.Semiring<W>, P: Wt.Language(A, W), Q: Wt.Language(A, W)) -> Wt.Language(A, W):
  +s => Al.SR.mul(W, R)(P(s), Q(s))

# 𝟏: the empty word alone
def Lang.eps.at(-A: Data, -W: Data, R: Al.Semiring<W>, s: List<&2, A>) -> W:
  match s:
    case Nil{}:
      Al.SR.one(W, R)
    case h <> t:
      Al.SR.zero(W, R)

def Lang.eps(-A: Data, -W: Data, R: Al.Semiring<W>) -> Wt.Language(A, W):
  s => Lang.eps.at(A, W, R, s)

law nu_empty:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  {Wt.nu(A, W, Lang.empty(A, W, R)) == Al.SR.zero(W, R) : W}

def nu_empty(A, W, R):
  {==}

law delta_empty:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -x: A
  for -s: List<&2, A>
  {Wt.delta(A, W, Lang.empty(A, W, R), x)(s) == Lang.empty(A, W, R)(s) : W}

def delta_empty(A, W, R, x, s):
  {==}

law nu_every:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  {Wt.nu(A, W, Lang.every(A, W, R)) == Al.SR.one(W, R) : W}

def nu_every(A, W, R):
  {==}

law delta_every:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -x: A
  for -s: List<&2, A>
  {Wt.delta(A, W, Lang.every(A, W, R), x)(s) == Lang.every(A, W, R)(s) : W}

def delta_every(A, W, R, x, s):
  {==}

law nu_eps:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  {Wt.nu(A, W, Lang.eps(A, W, R)) == Al.SR.one(W, R) : W}

def nu_eps(A, W, R):
  {==}

law delta_eps:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -x: A
  for -s: List<&2, A>
  {Wt.delta(A, W, Lang.eps(A, W, R), x)(s) == Lang.empty(A, W, R)(s) : W}

def delta_eps(A, W, R, x, s):
  {==}

law nu_sum:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -P: Wt.Language(A, W)
  for -Q: Wt.Language(A, W)
  {Wt.nu(A, W, Lang.sum(A, W, R, P, Q)) == Al.SR.add(W, R)(Wt.nu(A, W, P), Wt.nu(A, W, Q)) : W}

def nu_sum(A, W, R, P, Q):
  {==}

law delta_sum:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -P: Wt.Language(A, W)
  for -Q: Wt.Language(A, W)
  for -x: A
  for -s: List<&2, A>
  {Wt.delta(A, W, Lang.sum(A, W, R, P, Q), x)(s) == Lang.sum(A, W, R, Wt.delta(A, W, P, x), Wt.delta(A, W, Q, x))(s) : W}

def delta_sum(A, W, R, P, Q, x, s):
  {==}

law nu_scale:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -c: W
  for -P: Wt.Language(A, W)
  {Wt.nu(A, W, Lang.scale(A, W, R, c, P)) == Al.SR.mul(W, R)(c, Wt.nu(A, W, P)) : W}

def nu_scale(A, W, R, c, P):
  {==}

law delta_scale:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -c: W
  for -P: Wt.Language(A, W)
  for -x: A
  for -s: List<&2, A>
  {Wt.delta(A, W, Lang.scale(A, W, R, c, P), x)(s) == Lang.scale(A, W, R, c, Wt.delta(A, W, P, x))(s) : W}

def delta_scale(A, W, R, c, P, x, s):
  {==}

law nu_product:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -P: Wt.Language(A, W)
  for -Q: Wt.Language(A, W)
  {Wt.nu(A, W, Lang.product(A, W, R, P, Q)) == Al.SR.mul(W, R)(Wt.nu(A, W, P), Wt.nu(A, W, Q)) : W}

def nu_product(A, W, R, P, Q):
  {==}

law delta_product:
  for -A: Data
  for -W: Data
  for -R: Al.Semiring<W>
  for -P: Wt.Language(A, W)
  for -Q: Wt.Language(A, W)
  for -x: A
  for -s: List<&2, A>
  {Wt.delta(A, W, Lang.product(A, W, R, P, Q), x)(s) == Lang.product(A, W, R, Wt.delta(A, W, P, x), Wt.delta(A, W, Q, x))(s) : W}

def delta_product(A, W, R, P, Q, x, s):
  {==}

# Concatenation --------------------------------------------------------------
#
# (P ⋆ Q)(w) is the sum, over every way to cut w into u ++ v, of P(u)·Q(v).
# `Lang.splits` lists the cuts; the concatenation after P has read `pre` (its
# residual, as Spec/Trie.bend's fromLanguage keeps it) weighs a cut by
# P(pre ++ u)·Q(v), so δ of the left factor is a longer `pre`.

# a cut of a word: its left part u and its right part v
type Cut<-A: Data> is Data:
  Cut{u: List<&2, A>, v: List<&2, A>}

def Lang.splits.cons(-A: Data, +x: A, ps: List<&2, Cut<A>>) -> List<&2, Cut<A>>:
  match ps:
    case Nil{}:
      Nil{}
    case Cut{u, v} <> t:
      Cut{x <> u, v} <> Lang.splits.cons(A, x, t)

def Lang.splits(-A: Data, +w: List<&2, A>) -> List<&2, Cut<A>>:
  match w:
    case Nil{}:
      [Cut{Nil{}, Nil{}}]
    case x <> t:
      Cut{Nil{}, x <> t} <> Lang.splits.cons(A, x, Lang.splits(A, t))

def Lang.conv(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~P: List<&2, A> -> W, ~Q: List<&2, A> -> W, +pre: List<&2, A>, ps: List<&2, Cut<A>>) -> W:
  match ps:
    case Nil{}:
      Al.SR.zero(W, R)
    case Cut{u, v} <> t:
      Al.SR.add(W, R)(Al.SR.mul(W, R)(P(List.append(&2, A, pre, u)), Q(v)), Lang.conv(~A, ~W, ~R, ~P, ~Q, pre, t))

def Lang.concat.after(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~P: List<&2, A> -> W, ~Q: List<&2, A> -> W, +pre: List<&2, A>, +w: List<&2, A>) -> W:
  Lang.conv(~A, ~W, ~R, ~P, ~Q, pre, Lang.splits(A, w))

def Lang.concat(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~P: List<&2, A> -> W, ~Q: List<&2, A> -> W, +w: List<&2, A>) -> W:
  Lang.concat.after(~A, ~W, ~R, ~P, ~Q, Nil{}, w)

# Cutting x off every left part is P reading x first.
def conv_cons(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~P: List<&2, A> -> W, ~Q: List<&2, A> -> W, +pre: List<&2, A>, +x: A, ps: List<&2, Cut<A>>) ->
    {Lang.conv(~A, ~W, ~R, ~P, ~Q, pre, Lang.splits.cons(A, x, ps)) == Lang.conv(~A, ~W, ~R, ~P, ~Q, List.append(&2, A, pre, [x]), ps) : W}:
  match ps:
    case Nil{}:
      {==}
    case Cut{+u, +v} <> t:
      +px = List.append(&2, A, pre, [x])
      %conv_cons(~A, ~W, ~R, ~P, ~Q, pre, x, t)
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(P(List.append(&2, A, pre, x <> u)), Q(v)), Lang.conv(~A, ~W, ~R, ~P, ~Q, pre, Lang.splits.cons(A, x, t)))
           == Al.SR.add(W, R)(Al.SR.mul(W, R)(P(List.append(&2, A, px, u)), Q(v)), _) : W}
      %Tr.List.append_assoc(A, pre, [x], u)
        : {Al.SR.add(W, R)(Al.SR.mul(W, R)(P(_), Q(v)), Lang.conv(~A, ~W, ~R, ~P, ~Q, pre, Lang.splits.cons(A, x, t)))
           == Al.SR.add(W, R)(Al.SR.mul(W, R)(P(List.append(&2, A, px, u)), Q(v)), Lang.conv(~A, ~W, ~R, ~P, ~Q, pre, Lang.splits.cons(A, x, t))) : W}
      {==}

# ν⋆: ν(P ⋆ Q) = νP · νQ (after P read pre: P(pre) · νQ)
def nu_concat(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~P: List<&2, A> -> W, ~Q: List<&2, A> -> W, +pre: List<&2, A>) ->
    {Lang.concat.after(~A, ~W, ~R, ~P, ~Q, pre, Nil{}) == Al.SR.mul(W, R)(P(pre), Q(Nil{})) : W}:
  +m = Al.SR.mul(W, R)(P(List.append(&2, A, pre, Nil{})), Q(Nil{}))
  %Tr.List.append_nil(A, pre)
    : {Al.SR.add(W, R)(m, Al.SR.zero(W, R)) == Al.SR.mul(W, R)(P(_), Q(Nil{})) : W}
  Al.SR.add_zero_r(~W, ~R, m)

# δ⋆: δ(P ⋆ Q) x = νP · δQ x + δP x ⋆ Q (after P read pre: P(pre) · Q(x w),
# plus the concatenation after P read pre ++ [x])
def delta_concat(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~P: List<&2, A> -> W, ~Q: List<&2, A> -> W, +pre: List<&2, A>, +x: A, +w: List<&2, A>) ->
    {Lang.concat.after(~A, ~W, ~R, ~P, ~Q, pre, x <> w)
     == Al.SR.add(W, R)(Al.SR.mul(W, R)(P(pre), Q(x <> w)), Lang.concat.after(~A, ~W, ~R, ~P, ~Q, List.append(&2, A, pre, [x]), w)) : W}:
  +c = Lang.conv(~A, ~W, ~R, ~P, ~Q, pre, Lang.splits.cons(A, x, Lang.splits(A, w)))
  %Tr.List.append_nil(A, pre)
    : {Al.SR.add(W, R)(Al.SR.mul(W, R)(P(List.append(&2, A, pre, Nil{})), Q(x <> w)), c)
       == Al.SR.add(W, R)(Al.SR.mul(W, R)(P(_), Q(x <> w)), Lang.concat.after(~A, ~W, ~R, ~P, ~Q, List.append(&2, A, pre, [x]), w)) : W}
  %conv_cons(~A, ~W, ~R, ~P, ~Q, pre, x, Lang.splits(A, w))
    : {Al.SR.add(W, R)(Al.SR.mul(W, R)(P(List.append(&2, A, pre, Nil{})), Q(x <> w)), c)
       == Al.SR.add(W, R)(Al.SR.mul(W, R)(P(List.append(&2, A, pre, Nil{})), Q(x <> w)), _) : W}
  {==}

# The word filters -----------------------------------------------------------
#
# word(T) weighs T one and every other word zero (Elliott's ` c, for a whole
# word); avoid(T) weighs T zero and every other word one.  `same` says the
# word read so far still follows T; `eq` compares tokens.  Neither needs
# `eq` to be lawful except where T is read against itself (avoid_self,
# avoid_prefix: `refl`).

def Lang.word.go(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, t: List<&2, A>, s: List<&2, A>, same: Bool) -> W:
  match t s same:
    case Nil{} Nil{} True{}:
      Al.SR.one(W, R)
    case Nil{} Nil{} False{}:
      Al.SR.zero(W, R)
    case Nil{} y <> ys b:
      Al.SR.zero(W, R)
    case x <> xs Nil{} b:
      Al.SR.zero(W, R)
    case x <> xs y <> ys True{}:
      Lang.word.go(~A, ~W, ~R, ~eq, xs, ys, eq(y, x))
    case x <> xs y <> ys False{}:
      Al.SR.zero(W, R)

def Lang.avoid.go(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, t: List<&2, A>, s: List<&2, A>, same: Bool) -> W:
  match t s same:
    case Nil{} Nil{} True{}:
      Al.SR.zero(W, R)
    case Nil{} Nil{} False{}:
      Al.SR.one(W, R)
    case Nil{} y <> ys b:
      Al.SR.one(W, R)
    case x <> xs Nil{} b:
      Al.SR.one(W, R)
    case x <> xs y <> ys True{}:
      Lang.avoid.go(~A, ~W, ~R, ~eq, xs, ys, eq(y, x))
    case x <> xs y <> ys False{}:
      Al.SR.one(W, R)

def Lang.word(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, t: List<&2, A>) -> Wt.Language(A, W):
  s => Lang.word.go(~A, ~W, ~R, ~eq, t, s, True{})

def Lang.avoid(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, t: List<&2, A>) -> Wt.Language(A, W):
  s => Lang.avoid.go(~A, ~W, ~R, ~eq, t, s, True{})

# ν and δ of avoid(T), the decoder's rule: ν is 0 exactly when T is empty
# (stopping where T stops); δ by T's next token is avoid(the rest of T),
# by any other token 𝒰 (the filter is spent: the model alone).
def nu_avoid(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, +t: List<&2, A>) ->
    {Wt.nu(A, W, Lang.avoid(~A, ~W, ~R, ~eq, t)) == Lang.avoid.go(~A, ~W, ~R, ~eq, t, Nil{}, True{}) : W}:
  {==}

def delta_avoid(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, +x: A, +xs: List<&2, A>, +y: A, +s: List<&2, A>) ->
    {Wt.delta(A, W, Lang.avoid(~A, ~W, ~R, ~eq, x <> xs), y)(s) == Lang.avoid.go(~A, ~W, ~R, ~eq, xs, s, eq(y, x)) : W}:
  {==}

def avoid_spent(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, t: List<&2, A>, s: List<&2, A>) ->
    {Lang.avoid.go(~A, ~W, ~R, ~eq, t, s, False{}) == Lang.every(A, W, R)(s) : W}:
  match t s:
    case Nil{} Nil{}:
      {==}
    case Nil{} y <> ys:
      {==}
    case x <> xs Nil{}:
      {==}
    case x <> xs y <> ys:
      {==}

# avoid(T) + word(T) = 𝒰: crossing T out keeps every other word whole
def complement(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, t: List<&2, A>, s: List<&2, A>, same: Bool) ->
    {Al.SR.add(W, R)(Lang.avoid.go(~A, ~W, ~R, ~eq, t, s, same), Lang.word.go(~A, ~W, ~R, ~eq, t, s, same)) == Al.SR.one(W, R) : W}:
  match t s same:
    case Nil{} Nil{} True{}:
      Al.SR.add_zero_l(W, R, Al.SR.one(W, R))
    case Nil{} Nil{} False{}:
      Al.SR.add_zero_r(~W, ~R, Al.SR.one(W, R))
    case Nil{} y <> ys b:
      Al.SR.add_zero_r(~W, ~R, Al.SR.one(W, R))
    case x <> xs Nil{} b:
      Al.SR.add_zero_r(~W, ~R, Al.SR.one(W, R))
    case x <> xs y <> ys True{}:
      complement(~A, ~W, ~R, ~eq, xs, ys, eq(y, x))
    case x <> xs y <> ys False{}:
      Al.SR.add_zero_r(~W, ~R, Al.SR.one(W, R))

# T itself is crossed out (and word(T) weighs it one)
def avoid_self(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~refl: @+x: A -> {eq(x, x) == True{} : Bool}, +t: List<&2, A>) ->
    {Lang.avoid(~A, ~W, ~R, ~eq, t)(t) == Al.SR.zero(W, R) : W}:
  match t:
    case Nil{}:
      {==}
    case +x <> xs:
      %Equal.sym(Bool, eq(x, x), True{}, refl(x)) : {Lang.avoid.go(~A, ~W, ~R, ~eq, xs, xs, _) == Al.SR.zero(W, R) : W}
      avoid_self(~A, ~W, ~R, ~eq, ~refl, xs)

def word_self(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~refl: @+x: A -> {eq(x, x) == True{} : Bool}, +t: List<&2, A>) ->
    {Lang.word(~A, ~W, ~R, ~eq, t)(t) == Al.SR.one(W, R) : W}:
  match t:
    case Nil{}:
      {==}
    case +x <> xs:
      %Equal.sym(Bool, eq(x, x), True{}, refl(x)) : {Lang.word.go(~A, ~W, ~R, ~eq, xs, xs, _) == Al.SR.one(W, R) : W}
      word_self(~A, ~W, ~R, ~eq, ~refl, xs)

# reading the same u from T and from the word leaves avoid(T's rest)
def avoid_prefix(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~refl: @+x: A -> {eq(x, x) == True{} : Bool}, u: List<&2, A>, +rest: List<&2, A>, +v: List<&2, A>) ->
    {Lang.avoid.go(~A, ~W, ~R, ~eq, List.append(&2, A, u, rest), List.append(&2, A, u, v), True{}) == Lang.avoid.go(~A, ~W, ~R, ~eq, rest, v, True{}) : W}:
  match u:
    case Nil{}:
      {==}
    case +x <> t:
      %Equal.sym(Bool, eq(x, x), True{}, refl(x))
        : {Lang.avoid.go(~A, ~W, ~R, ~eq, List.append(&2, A, t, rest), List.append(&2, A, t, v), _) == Lang.avoid.go(~A, ~W, ~R, ~eq, rest, v, True{}) : W}
      avoid_prefix(~A, ~W, ~R, ~eq, ~refl, t, rest, v)

# leaving T at a token eq tells apart from T's: the filter is spent
def avoid_leave(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~refl: @+x: A -> {eq(x, x) == True{} : Bool},
    +u: List<&2, A>, +x: A, +rest: List<&2, A>, +y: A, +v: List<&2, A>, ne: {eq(y, x) == False{} : Bool}) ->
    {Lang.avoid.go(~A, ~W, ~R, ~eq, List.append(&2, A, u, x <> rest), List.append(&2, A, u, y <> v), True{}) == Al.SR.one(W, R) : W}:
  %Equal.sym(W, Lang.avoid.go(~A, ~W, ~R, ~eq, List.append(&2, A, u, x <> rest), List.append(&2, A, u, y <> v), True{}), Lang.avoid.go(~A, ~W, ~R, ~eq, x <> rest, y <> v, True{}),
      avoid_prefix(~A, ~W, ~R, ~eq, ~refl, u, x <> rest, y <> v))
    : {_ == Al.SR.one(W, R) : W}
  %Equal.sym(Bool, eq(y, x), False{}, ne) : {Lang.avoid.go(~A, ~W, ~R, ~eq, rest, v, _) == Al.SR.one(W, R) : W}
  avoid_spent(~A, ~W, ~R, ~eq, rest, v)

# M = M × avoid(T) + M × word(T), pointwise: the product loses exactly the
# weight M gives T, so its mass is M's mass less M(T)
def product_complement(~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~eq: A -> A -> Bool, ~M: List<&2, A> -> W, +t: List<&2, A>, +s: List<&2, A>) ->
    {Al.SR.add(W, R)(Lang.product(A, W, R, M, Lang.avoid(~A, ~W, ~R, ~eq, t))(s), Lang.product(A, W, R, M, Lang.word(~A, ~W, ~R, ~eq, t))(s)) == M(s) : W}:
  +m = M(s)
  +a = Lang.avoid.go(~A, ~W, ~R, ~eq, t, s, True{})
  +w = Lang.word.go(~A, ~W, ~R, ~eq, t, s, True{})
  %Al.SR.distrib_l(W, R, m, a, w) : {_ == m : W}
  %Equal.sym(W, Al.SR.add(W, R)(a, w), Al.SR.one(W, R), complement(~A, ~W, ~R, ~eq, t, s, True{})) : {Al.SR.mul(W, R)(m, _) == m : W}
  Al.SR.mul_one_r(W, R, m)

# The model's two operations -------------------------------------------------

# The mixture c1·M1 + c2·M2 after a prefix u is the mixture of the two
# continuations, each coefficient times its model's weight of u: the
# posterior.  The decoder keeps the two path weights and mixes the next-token
# distributions by them.
def mixture_residual(~S1: Data, ~S2: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M1: Ar.StateAlgebra<S1, A, W>, ~M2: Ar.StateAlgebra<S2, A, W>,
    +c1: W, +c2: W, +q1: S1, +q2: S2, +u: List<&2, A>, +v: List<&2, A>) ->
    {Lang.sum(A, W, R, Lang.scale(A, W, R, c1, Ar.denotes(~S1, ~A, ~W, ~R, ~M1, q1)), Lang.scale(A, W, R, c2, Ar.denotes(~S2, ~A, ~W, ~R, ~M2, q2)))(List.append(&2, A, u, v))
     == Lang.sum(A, W, R,
          Lang.scale(A, W, R, Al.SR.mul(W, R)(c1, Ar.pathWeight(~S1, ~A, ~W, ~R, ~M1, u, q1)), Ar.denotes(~S1, ~A, ~W, ~R, ~M1, Ar.run(~S1, ~A, ~W, ~M1, u, q1))),
          Lang.scale(A, W, R, Al.SR.mul(W, R)(c2, Ar.pathWeight(~S2, ~A, ~W, ~R, ~M2, u, q2)), Ar.denotes(~S2, ~A, ~W, ~R, ~M2, Ar.run(~S2, ~A, ~W, ~M2, u, q2))))(v) : W}:
  +p1 = Ar.pathWeight(~S1, ~A, ~W, ~R, ~M1, u, q1)
  +p2 = Ar.pathWeight(~S2, ~A, ~W, ~R, ~M2, u, q2)
  +n1 = Ar.unnormalized(~S1, ~A, ~W, ~R, ~M1, Ar.run(~S1, ~A, ~W, ~M1, u, q1), v)
  +n2 = Ar.unnormalized(~S2, ~A, ~W, ~R, ~M2, Ar.run(~S2, ~A, ~W, ~M2, u, q2), v)
  +rhs = Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.mul(W, R)(c1, p1), n1), Al.SR.mul(W, R)(Al.SR.mul(W, R)(c2, p2), n2))
  %Equal.sym(W, Ar.unnormalized(~S1, ~A, ~W, ~R, ~M1, q1, List.append(&2, A, u, v)), Al.SR.mul(W, R)(p1, n1), Ar.residual_continuation(~S1, ~A, ~W, ~R, ~M1, q1, u, v))
    : {Al.SR.add(W, R)(Al.SR.mul(W, R)(c1, _), Al.SR.mul(W, R)(c2, Ar.unnormalized(~S2, ~A, ~W, ~R, ~M2, q2, List.append(&2, A, u, v)))) == rhs : W}
  %Equal.sym(W, Ar.unnormalized(~S2, ~A, ~W, ~R, ~M2, q2, List.append(&2, A, u, v)), Al.SR.mul(W, R)(p2, n2), Ar.residual_continuation(~S2, ~A, ~W, ~R, ~M2, q2, u, v))
    : {Al.SR.add(W, R)(Al.SR.mul(W, R)(c1, Al.SR.mul(W, R)(p1, n1)), Al.SR.mul(W, R)(c2, _)) == rhs : W}
  %Al.SR.mul_assoc(W, R, c1, p1, n1) : {Al.SR.add(W, R)(_, Al.SR.mul(W, R)(c2, Al.SR.mul(W, R)(p2, n2))) == rhs : W}
  %Al.SR.mul_assoc(W, R, c2, p2, n2) : {Al.SR.add(W, R)(Al.SR.mul(W, R)(Al.SR.mul(W, R)(c1, p1), n1), _) == rhs : W}
  {==}

# The retry: the model times avoid(T), after it followed T for u, is the
# path weight of u times the model's continuation times avoid(T's rest).
def product_on_path(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, ~eq: A -> A -> Bool, ~refl: @+x: A -> {eq(x, x) == True{} : Bool},
    +q: S, +u: List<&2, A>, +rest: List<&2, A>, +v: List<&2, A>) ->
    {Lang.product(A, W, R, Ar.denotes(~S, ~A, ~W, ~R, ~M, q), Lang.avoid(~A, ~W, ~R, ~eq, List.append(&2, A, u, rest)))(List.append(&2, A, u, v))
     == Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, u, q), Lang.product(A, W, R, Ar.denotes(~S, ~A, ~W, ~R, ~M, Ar.run(~S, ~A, ~W, ~M, u, q)), Lang.avoid(~A, ~W, ~R, ~eq, rest))(v)) : W}:
  +p = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, u, q)
  +n = Ar.unnormalized(~S, ~A, ~W, ~R, ~M, Ar.run(~S, ~A, ~W, ~M, u, q), v)
  +f = Lang.avoid.go(~A, ~W, ~R, ~eq, rest, v, True{})
  %Equal.sym(W, Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, List.append(&2, A, u, v)), Al.SR.mul(W, R)(p, n), Ar.residual_continuation(~S, ~A, ~W, ~R, ~M, q, u, v))
    : {Al.SR.mul(W, R)(_, Lang.avoid.go(~A, ~W, ~R, ~eq, List.append(&2, A, u, rest), List.append(&2, A, u, v), True{})) == Al.SR.mul(W, R)(p, Al.SR.mul(W, R)(n, f)) : W}
  %Equal.sym(W, Lang.avoid.go(~A, ~W, ~R, ~eq, List.append(&2, A, u, rest), List.append(&2, A, u, v), True{}), f, avoid_prefix(~A, ~W, ~R, ~eq, ~refl, u, rest, v))
    : {Al.SR.mul(W, R)(Al.SR.mul(W, R)(p, n), _) == Al.SR.mul(W, R)(p, Al.SR.mul(W, R)(n, f)) : W}
  Al.SR.mul_assoc(W, R, p, n, f)

# Instances ------------------------------------------------------------------
#
# Tokens are Nat (U32 in the decoder), compared by tok.eq; the languages are
# Spec/Trie.bend's (sum.nat, len.nat, any.bool) and the machines
# Spec/Autoregressive.bend's (count over Nat) and `seen` here (over Bool
# weights: has a 0 token been read).

def tok.eq(a: Nat, b: Nat) -> Bool:
  match a b:
    case 0n 0n:
      True{}
    case 1n+p 1n+q:
      tok.eq(p, q)
    case _ _:
      False{}

law tok.eq_refl:
  for +x: Nat
  {tok.eq(x, x) == True{} : Bool}

def tok.eq_refl(x):
  match x:
    case 0n:
      {==}
    case 1n+p:
      tok.eq_refl(p)

# a Bool-weighted language over Nat tokens: whether a 0 token occurs
def has.zero(xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(tok.eq(h, 0n), has.zero(t))

def seen.step(+q: Bool, +x: Nat) -> Ar.WS<Bool, Bool>:
  Ar.WS{True{}, Bool.or(q, tok.eq(x, 0n))}

def seen() -> Ar.StateAlgebra<Bool, Nat, Bool>:
  Ar.StateAlgebra{q => q, q => x => seen.step(q, x)}

law check.concat:
  for +pre: List<&2, Nat>
  for +x: Nat
  for +w: List<&2, Nat>
  {Lang.concat.after(~Nat, ~Nat, ~Al.Nat.semiring(), ~Tr.sum.nat, ~Tr.len.nat, pre, x <> w)
   == Nat.add(Nat.mul(Tr.sum.nat(pre), Tr.len.nat(x <> w)), Lang.concat.after(~Nat, ~Nat, ~Al.Nat.semiring(), ~Tr.sum.nat, ~Tr.len.nat, List.append(&2, Nat, pre, [x]), w)) : Nat}
  & {Lang.concat.after(~Nat, ~Nat, ~Al.Nat.semiring(), ~Tr.sum.nat, ~Tr.len.nat, pre, Nil{}) == Nat.mul(Tr.sum.nat(pre), Tr.len.nat(Nil{})) : Nat}

def check.concat(pre, x, w):
  (delta_concat(~Nat, ~Nat, ~Al.Nat.semiring(), ~Tr.sum.nat, ~Tr.len.nat, pre, x, w),
   nu_concat(~Nat, ~Nat, ~Al.Nat.semiring(), ~Tr.sum.nat, ~Tr.len.nat, pre))

law check.filters:
  for +t: List<&2, Nat>
  for +s: List<&2, Nat>
  {Al.SR.add(Nat, Al.Nat.semiring())(Lang.product(Nat, Nat, Al.Nat.semiring(), Tr.sum.nat, Lang.avoid(~Nat, ~Nat, ~Al.Nat.semiring(), ~tok.eq, t))(s), Lang.product(Nat, Nat, Al.Nat.semiring(), Tr.sum.nat, Lang.word(~Nat, ~Nat, ~Al.Nat.semiring(), ~tok.eq, t))(s)) == Tr.sum.nat(s) : Nat}
  & {Al.SR.add(Bool, Al.Bool.semiring())(Lang.product(Nat, Bool, Al.Bool.semiring(), has.zero, Lang.avoid(~Nat, ~Bool, ~Al.Bool.semiring(), ~tok.eq, t))(s), Lang.product(Nat, Bool, Al.Bool.semiring(), has.zero, Lang.word(~Nat, ~Bool, ~Al.Bool.semiring(), ~tok.eq, t))(s)) == has.zero(s) : Bool}
  & {Lang.avoid(~Nat, ~Nat, ~Al.Nat.semiring(), ~tok.eq, t)(t) == 0n : Nat}
  & {Lang.word(~Nat, ~Bool, ~Al.Bool.semiring(), ~tok.eq, t)(t) == True{} : Bool}

def check.filters(t, s):
  (product_complement(~Nat, ~Nat, ~Al.Nat.semiring(), ~tok.eq, ~Tr.sum.nat, t, s),
   (product_complement(~Nat, ~Bool, ~Al.Bool.semiring(), ~tok.eq, ~has.zero, t, s),
    (avoid_self(~Nat, ~Nat, ~Al.Nat.semiring(), ~tok.eq, ~tok.eq_refl, t),
     word_self(~Nat, ~Bool, ~Al.Bool.semiring(), ~tok.eq, ~tok.eq_refl, t))))

law check.mixture:
  for +c1: Nat
  for +c2: Nat
  for +q1: Nat
  for +q2: Nat
  for +u: List<&2, Nat>
  for +v: List<&2, Nat>
  for +b1: Bool
  for +b2: Bool
  for +us: List<&2, Bool>
  for +vs: List<&2, Bool>
  {Lang.sum(Nat, Nat, Al.Nat.semiring(), Lang.scale(Nat, Nat, Al.Nat.semiring(), c1, Ar.denotes(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), q1)), Lang.scale(Nat, Nat, Al.Nat.semiring(), c2, Ar.denotes(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), q2)))(List.append(&2, Nat, u, v))
   == Lang.sum(Nat, Nat, Al.Nat.semiring(),
        Lang.scale(Nat, Nat, Al.Nat.semiring(), Nat.mul(c1, Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), u, q1)), Ar.denotes(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), u, q1))),
        Lang.scale(Nat, Nat, Al.Nat.semiring(), Nat.mul(c2, Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), u, q2)), Ar.denotes(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), u, q2))))(v) : Nat}
  & {Lang.sum(Bool, Bool, Al.Bool.semiring(), Lang.scale(Bool, Bool, Al.Bool.semiring(), b1, Ar.denotes(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b1)), Lang.scale(Bool, Bool, Al.Bool.semiring(), b2, Ar.denotes(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b2)))(List.append(&2, Bool, us, vs))
   == Lang.sum(Bool, Bool, Al.Bool.semiring(),
        Lang.scale(Bool, Bool, Al.Bool.semiring(), Bool.and(b1, Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), us, b1)), Ar.denotes(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), Ar.run(~Bool, ~Bool, ~Bool, ~Ar.flip(), us, b1))),
        Lang.scale(Bool, Bool, Al.Bool.semiring(), Bool.and(b2, Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), us, b2)), Ar.denotes(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), Ar.run(~Bool, ~Bool, ~Bool, ~Ar.flip(), us, b2))))(vs) : Bool}

def check.mixture(c1, c2, q1, q2, u, v, b1, b2, us, vs):
  (mixture_residual(~Nat, ~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), ~Ar.count(), c1, c2, q1, q2, u, v),
   mixture_residual(~Bool, ~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), ~Ar.flip(), b1, b2, b1, b2, us, vs))

law check.retry:
  for +q: Nat
  for +b: Bool
  for +u: List<&2, Nat>
  for +rest: List<&2, Nat>
  for +v: List<&2, Nat>
  {Lang.product(Nat, Nat, Al.Nat.semiring(), Ar.denotes(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), q), Lang.avoid(~Nat, ~Nat, ~Al.Nat.semiring(), ~tok.eq, List.append(&2, Nat, u, rest)))(List.append(&2, Nat, u, v))
   == Nat.mul(Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), u, q), Lang.product(Nat, Nat, Al.Nat.semiring(), Ar.denotes(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), u, q)), Lang.avoid(~Nat, ~Nat, ~Al.Nat.semiring(), ~tok.eq, rest))(v)) : Nat}
  & {Lang.product(Nat, Bool, Al.Bool.semiring(), Ar.denotes(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~seen(), b), Lang.avoid(~Nat, ~Bool, ~Al.Bool.semiring(), ~tok.eq, List.append(&2, Nat, u, rest)))(List.append(&2, Nat, u, v))
   == Bool.and(Ar.pathWeight(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~seen(), u, b), Lang.product(Nat, Bool, Al.Bool.semiring(), Ar.denotes(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~seen(), Ar.run(~Bool, ~Nat, ~Bool, ~seen(), u, b)), Lang.avoid(~Nat, ~Bool, ~Al.Bool.semiring(), ~tok.eq, rest))(v)) : Bool}

def check.retry(q, b, u, rest, v):
  (product_on_path(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), ~tok.eq, ~tok.eq_refl, q, u, rest, v),
   product_on_path(~Bool, ~Nat, ~Bool, ~Al.Bool.semiring(), ~seen(), ~tok.eq, ~tok.eq_refl, b, u, rest, v))
