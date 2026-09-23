import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar
import ./Order.bend as O
import ./Trie.bend as Tr

# Enriched/Bradley.agda: Bradley's enriched-category reading of language.
# Objects are token prefixes inside a finite cutoff that record whether
# they terminate; a morphism xs -> ys is the evidence that xs is a prefix
# of ys (its extension); the hom-weight of a morphism is the path weight
# of the extension, and composition of morphisms multiplies hom-weights --
# which is the factorization law of Autoregressive.bend.

# xs is a prefix of ys: an extension with ys = xs ++ ext
def Prefix(-A: Data, xs: List<&2, A>, ys: List<&2, A>) -> Type:
  Exists(List<&2, A>, ext => {ys == List.append(&2, A, xs, ext) : List<&2, A>})

law identityPrefix:
  for -A: Data
  for +xs: List<&2, A>
  Prefix(A, xs, xs)

def identityPrefix(A, xs):
  (Nil{}, Equal.sym(List<&2, A>, List.append(&2, A, xs, Nil{}), xs, Tr.List.append_nil(A, xs)))

law composePrefix:
  for -A: Data
  for +xs: List<&2, A>
  for -ys: List<&2, A>
  for -zs: List<&2, A>
  for p: Prefix(A, xs, ys)
  for q: Prefix(A, ys, zs)
  Prefix(A, xs, zs)

def composePrefix(A, xs, ys, zs, p, q):
  (+us, e) = p
  (+vs, f) = q
  (List.append(&2, A, us, vs),
   Equal.trans(List<&2, A>, zs, List.append(&2, A, ys, vs), List.append(&2, A, xs, List.append(&2, A, us, vs)), f,
     Equal.trans(List<&2, A>, List.append(&2, A, ys, vs), List.append(&2, A, List.append(&2, A, xs, us), vs), List.append(&2, A, xs, List.append(&2, A, us, vs)),
       Equal.cong(List<&2, A>, List<&2, A>, l => List.append(&2, A, l, vs), ys, List.append(&2, A, xs, us), e),
       Tr.List.append_assoc(A, xs, us, vs))))

def ext(-A: Data, -xs: List<&2, A>, -ys: List<&2, A>, p: Prefix(A, xs, ys)) -> List<&2, A>:
  (e, pf) = p
  e

# Objects inhabit a finite cutoff and record whether they terminate.
type PrefixObject<-A: Data> is Type:
  PrefixObject{cutoff: Nat, tokens: List<&2, A>, within: O.Le(List.length(&2, A, tokens), cutoff), terminal: Bool}

# the hom-weight of a prefix morphism: the path weight of its extension
def prefixHom(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>,
              +q: S, -xs: List<&2, A>, -ys: List<&2, A>, p: Prefix(A, xs, ys)) -> W:
  Ar.pathWeight(~S, ~A, ~W, ~R, ~M, ext(A, xs, ys, p), q)

# identities weigh one
def identity_hom(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +q: S, +xs: List<&2, A>) ->
    {prefixHom(~S, ~A, ~W, ~R, ~M, q, xs, xs, identityPrefix(A, xs)) == Al.SR.one(W, R) : W}:
  {==}

# composition multiplies hom-weights, the second read at the state the
# first extension reaches
def composition_hom(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>,
                    +q: S, +us: List<&2, A>, +vs: List<&2, A>) ->
    {Ar.pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, us, vs), q)
      == Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, us, q), Ar.pathWeight(~S, ~A, ~W, ~R, ~M, vs, Ar.run(~S, ~A, ~W, ~M, us, q))) : W}:
  Ar.factorization(~S, ~A, ~W, ~R, ~M, us, q, vs)

law check.bradley:
  for +q: Nat
  for +xs: List<&2, Nat>
  for +us: List<&2, Nat>
  for +vs: List<&2, Nat>
  for +b: Bool
  for +bs: List<&2, Bool>
  for +cs: List<&2, Bool>
  {prefixHom(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), q, xs, xs, identityPrefix(Nat, xs)) == 1n : Nat}
  & {Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), List.append(&2, Nat, us, vs), q)
      == Nat.mul(Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), us, q), Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), vs, Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), us, q))) : Nat}
  & {Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), List.append(&2, Bool, bs, cs), b)
      == Bool.and(Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), bs, b), Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), cs, Ar.run(~Bool, ~Bool, ~Bool, ~Ar.flip(), bs, b))) : Bool}

def check.bradley(q, xs, us, vs, b, bs, cs):
  (identity_hom(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), q, xs),
   composition_hom(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), q, us, vs),
   composition_hom(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), b, bs, cs))
