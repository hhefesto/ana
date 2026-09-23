import Base
import ./Algebra.bend as Al
import ./Autoregressive.bend as Ar
import ./Trie.bend as Tr

# Language/AutoregressiveTrie.agda: the observation trie of a state is the
# denotational KV cache -- the state's whole observable future presented by
# nu and delta alone.  Incremental stepping equals whole-prefix evaluation,
# and the weighted trie denotes exactly the unnormalized state language.
# Depth-n renderings, as in Trie.bend.

def observationTrie(~S: Data, ~A: Data, ~W: Data, ~M: Ar.StateAlgebra<S, A, W>, n: Nat, +q: S) -> Tr.Trie(n, A, W):
  match n:
    case 0n:
      Tr.Leaf{Ar.SA.out(S, A, W, M)(q)}
    case 1n+p:
      Tr.Node{Ar.SA.out(S, A, W, M)(q), x => observationTrie(~S, ~A, ~W, ~M, p, Ar.next(~S, ~A, ~W, ~M, q, x))}

# the cache denotes the state's observation after the whole word
def observation_denotes(~S: Data, ~A: Data, ~W: Data, ~M: Ar.StateAlgebra<S, A, W>, xs: List<&2, A>, +q: S) ->
    {Tr.toLanguage(Tr.len(A, xs), A, W, xs, observationTrie(~S, ~A, ~W, ~M, Tr.len(A, xs), q)) == Ar.SA.out(S, A, W, M)(Ar.run(~S, ~A, ~W, ~M, xs, q)) : W}:
  match xs:
    case Nil{}:
      {==}
    case +x <> t:
      observation_denotes(~S, ~A, ~W, ~M, t, Ar.next(~S, ~A, ~W, ~M, q, x))

# The weighted trie carries the consumed path weight as an accumulator.
def weightedTrie(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, n: Nat, +c: W, +q: S) -> Tr.Trie(n, A, W):
  match n:
    case 0n:
      Tr.Leaf{Al.SR.mul(W, R)(c, Ar.SA.out(S, A, W, M)(q))}
    case 1n+p:
      Tr.Node{Al.SR.mul(W, R)(c, Ar.SA.out(S, A, W, M)(q)),
        +x => weightedTrie(~S, ~A, ~W, ~R, ~M, p, Al.SR.mul(W, R)(c, Ar.weight(~S, ~A, ~W, ~M, q, x)), Ar.next(~S, ~A, ~W, ~M, q, x))}

def weighted_denotes(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +xs: List<&2, A>, +c: W, +q: S) ->
    {Tr.toLanguage(Tr.len(A, xs), A, W, xs, weightedTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, xs), c, q)) == Al.SR.mul(W, R)(c, Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, xs)) : W}:
  match xs:
    case Nil{}:
      %Al.SR.mul_one_l(W, R, Ar.SA.out(S, A, W, M)(q)) : {Al.SR.mul(W, R)(c, _) == Al.SR.mul(W, R)(c, Al.SR.mul(W, R)(Al.SR.one(W, R), Ar.SA.out(S, A, W, M)(q))) : W}
      {==}
    case +x <> t:
      +wx = Ar.weight(~S, ~A, ~W, ~M, q, x)
      +q2 = Ar.next(~S, ~A, ~W, ~M, q, x)
      +p = Ar.pathWeight(~S, ~A, ~W, ~R, ~M, t, q2)
      +o = Ar.SA.out(S, A, W, M)(Ar.run(~S, ~A, ~W, ~M, t, q2))
      +cw = Al.SR.mul(W, R)(c, wx)
      %Equal.sym(W, Tr.toLanguage(Tr.len(A, t), A, W, t, weightedTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, t), cw, q2)), Al.SR.mul(W, R)(cw, Al.SR.mul(W, R)(p, o)), weighted_denotes(~S, ~A, ~W, ~R, ~M, t, cw, q2))
        : {_ == Al.SR.mul(W, R)(c, Al.SR.mul(W, R)(Al.SR.mul(W, R)(wx, p), o)) : W}
      %Equal.sym(W, Al.SR.mul(W, R)(cw, Al.SR.mul(W, R)(p, o)), Al.SR.mul(W, R)(c, Al.SR.mul(W, R)(wx, Al.SR.mul(W, R)(p, o))), Al.SR.mul_assoc(W, R, c, wx, Al.SR.mul(W, R)(p, o)))
        : {_ == Al.SR.mul(W, R)(c, Al.SR.mul(W, R)(Al.SR.mul(W, R)(wx, p), o)) : W}
      %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.mul(W, R)(wx, p), o), Al.SR.mul(W, R)(wx, Al.SR.mul(W, R)(p, o)), Al.SR.mul_assoc(W, R, wx, p, o))
        : {Al.SR.mul(W, R)(c, Al.SR.mul(W, R)(wx, Al.SR.mul(W, R)(p, o))) == Al.SR.mul(W, R)(c, _) : W}
      {==}

def stateTrie(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, n: Nat, +q: S) -> Tr.Trie(n, A, W):
  weightedTrie(~S, ~A, ~W, ~R, ~M, n, Al.SR.one(W, R), q)

# the state trie denotes the unnormalized language
def stateTrie_denotes(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +xs: List<&2, A>, +q: S) ->
    {Tr.toLanguage(Tr.len(A, xs), A, W, xs, stateTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, xs), q)) == Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, xs) : W}:
  %Equal.sym(W, Tr.toLanguage(Tr.len(A, xs), A, W, xs, weightedTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, xs), Al.SR.one(W, R), q)), Al.SR.mul(W, R)(Al.SR.one(W, R), Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, xs)), weighted_denotes(~S, ~A, ~W, ~R, ~M, xs, Al.SR.one(W, R), q))
    : {_ == Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, xs) : W}
  Al.SR.mul_one_l(W, R, Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, xs))

# Agreement with the residual law: reading xs ++ ys off the state trie is
# the consumed weight times the continuation's trie reading of ys.
def trie_residual(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: Ar.StateAlgebra<S, A, W>, +xs: List<&2, A>, +ys: List<&2, A>, +q: S) ->
    {Tr.toLanguage(Tr.len(A, List.append(&2, A, xs, ys)), A, W, List.append(&2, A, xs, ys), stateTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, List.append(&2, A, xs, ys)), q))
      == Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, xs, q), Ar.unnormalized(~S, ~A, ~W, ~R, ~M, Ar.run(~S, ~A, ~W, ~M, xs, q), ys)) : W}:
  %Equal.sym(W, Tr.toLanguage(Tr.len(A, List.append(&2, A, xs, ys)), A, W, List.append(&2, A, xs, ys), stateTrie(~S, ~A, ~W, ~R, ~M, Tr.len(A, List.append(&2, A, xs, ys)), q)), Ar.unnormalized(~S, ~A, ~W, ~R, ~M, q, List.append(&2, A, xs, ys)), stateTrie_denotes(~S, ~A, ~W, ~R, ~M, List.append(&2, A, xs, ys), q))
    : {_ == Al.SR.mul(W, R)(Ar.pathWeight(~S, ~A, ~W, ~R, ~M, xs, q), Ar.unnormalized(~S, ~A, ~W, ~R, ~M, Ar.run(~S, ~A, ~W, ~M, xs, q), ys)) : W}
  Ar.residual_continuation(~S, ~A, ~W, ~R, ~M, q, xs, ys)

# Instances ----------------------------------------------------------------

law check.trie:
  for +xs: List<&2, Nat>
  for +ys: List<&2, Nat>
  for +q: Nat
  for +us: List<&2, Bool>
  for +vs: List<&2, Bool>
  for +b: Bool
  {Tr.toLanguage(Tr.len(Nat, xs), Nat, Nat, xs, observationTrie(~Nat, ~Nat, ~Nat, ~Ar.count(), Tr.len(Nat, xs), q)) == Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), xs, q) : Nat}
  & {Tr.toLanguage(Tr.len(Nat, List.append(&2, Nat, xs, ys)), Nat, Nat, List.append(&2, Nat, xs, ys), stateTrie(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), Tr.len(Nat, List.append(&2, Nat, xs, ys)), q))
      == Nat.mul(Ar.pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), xs, q), Ar.unnormalized(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), Ar.run(~Nat, ~Nat, ~Nat, ~Ar.count(), xs, q), ys)) : Nat}
  & {Tr.toLanguage(Tr.len(Bool, List.append(&2, Bool, us, vs)), Bool, Bool, List.append(&2, Bool, us, vs), stateTrie(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), Tr.len(Bool, List.append(&2, Bool, us, vs)), b))
      == Bool.and(Ar.pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), us, b), Ar.unnormalized(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), Ar.run(~Bool, ~Bool, ~Bool, ~Ar.flip(), us, b), vs)) : Bool}

def check.trie(xs, ys, q, us, vs, b):
  (observation_denotes(~Nat, ~Nat, ~Nat, ~Ar.count(), xs, q),
   trie_residual(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~Ar.count(), xs, ys, q),
   trie_residual(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~Ar.flip(), us, vs, b))
