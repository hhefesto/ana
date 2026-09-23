import Base
import ./Algebra.bend as Al
import ./Weighted.bend as Wt

# Language/Autoregressive.agda: the model as a coalgebra.  A state algebra
# observes a state (`out`) and steps it on a token, emitting that step's
# weight; the language it denotes weighs a word by the product of the step
# weights times the final observation.  Normalization is separate.
#
# Theorem templates over the semiring and the state algebra, checked at the
# instances at the end of the file.  The structural ones (run_append) are
# also instantiated at the real decoder in Spec/Refinement.bend.

type WS<-W: Data, -S: Data> is Data:
  WS{w: W, s: S}

def WS.w(-W: Data, -S: Data, p: WS<W, S>) -> W:
  match p:
    case WS{w, s}:
      w

def WS.s(-W: Data, -S: Data, p: WS<W, S>) -> S:
  match p:
    case WS{w, s}:
      s

type StateAlgebra<-S: Data, -A: Data, -W: Data> is Type:
  StateAlgebra{out: S -> W, step: S -> A -> WS<W, S>}

def SA.out(-S: Data, -A: Data, -W: Data, m: StateAlgebra<S, A, W>) -> S -> W:
  match m:
    case StateAlgebra{o, st}:
      o

def SA.step(-S: Data, -A: Data, -W: Data, m: StateAlgebra<S, A, W>) -> S -> A -> WS<W, S>:
  match m:
    case StateAlgebra{o, st}:
      st

def next(~S: Data, ~A: Data, ~W: Data, ~M: StateAlgebra<S, A, W>, +q: S, +x: A) -> S:
  WS.s(W, S, SA.step(S, A, W, M)(q, x))

def weight(~S: Data, ~A: Data, ~W: Data, ~M: StateAlgebra<S, A, W>, +q: S, +x: A) -> W:
  WS.w(W, S, SA.step(S, A, W, M)(q, x))

def run(~S: Data, ~A: Data, ~W: Data, ~M: StateAlgebra<S, A, W>, xs: List<&2, A>, +q: S) -> S:
  match xs:
    case Nil{}:
      q
    case +x <> t:
      run(~S, ~A, ~W, ~M, t, next(~S, ~A, ~W, ~M, q, x))

def pathWeight(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: StateAlgebra<S, A, W>, xs: List<&2, A>, +q: S) -> W:
  match xs:
    case Nil{}:
      Al.SR.one(W, R)
    case +x <> t:
      Al.SR.mul(W, R)(weight(~S, ~A, ~W, ~M, q, x), pathWeight(~S, ~A, ~W, ~R, ~M, t, next(~S, ~A, ~W, ~M, q, x)))

def unnormalized(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: StateAlgebra<S, A, W>, +q: S, +xs: List<&2, A>) -> W:
  Al.SR.mul(W, R)(pathWeight(~S, ~A, ~W, ~R, ~M, xs, q), SA.out(S, A, W, M)(run(~S, ~A, ~W, ~M, xs, q)))

# run over a concatenation is running the pieces in order
def run_append(~S: Data, ~A: Data, ~W: Data, ~M: StateAlgebra<S, A, W>, xs: List<&2, A>, +q: S, +ys: List<&2, A>) ->
    {run(~S, ~A, ~W, ~M, List.append(&2, A, xs, ys), q) == run(~S, ~A, ~W, ~M, ys, run(~S, ~A, ~W, ~M, xs, q)) : S}:
  match xs:
    case Nil{}:
      {==}
    case +x <> t:
      run_append(~S, ~A, ~W, ~M, t, next(~S, ~A, ~W, ~M, q, x), ys)

# path weights factor at every cut
def factorization(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: StateAlgebra<S, A, W>, +xs: List<&2, A>, +q: S, +ys: List<&2, A>) ->
    {pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, xs, ys), q) == Al.SR.mul(W, R)(pathWeight(~S, ~A, ~W, ~R, ~M, xs, q), pathWeight(~S, ~A, ~W, ~R, ~M, ys, run(~S, ~A, ~W, ~M, xs, q))) : W}:
  match xs:
    case Nil{}:
      %Al.SR.mul_one_l(W, R, pathWeight(~S, ~A, ~W, ~R, ~M, ys, q)) : {_ == Al.SR.mul(W, R)(Al.SR.one(W, R), pathWeight(~S, ~A, ~W, ~R, ~M, ys, q)) : W}
      {==}
    case +x <> t:
      +q2 = next(~S, ~A, ~W, ~M, q, x)
      +wx = weight(~S, ~A, ~W, ~M, q, x)
      +pt = pathWeight(~S, ~A, ~W, ~R, ~M, t, q2)
      +py = pathWeight(~S, ~A, ~W, ~R, ~M, ys, run(~S, ~A, ~W, ~M, t, q2))
      %Equal.sym(W, pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, t, ys), q2), Al.SR.mul(W, R)(pt, py), factorization(~S, ~A, ~W, ~R, ~M, t, q2, ys))
        : {Al.SR.mul(W, R)(wx, _) == Al.SR.mul(W, R)(Al.SR.mul(W, R)(wx, pt), py) : W}
      %Equal.sym(W, Al.SR.mul(W, R)(Al.SR.mul(W, R)(wx, pt), py), Al.SR.mul(W, R)(wx, Al.SR.mul(W, R)(pt, py)), Al.SR.mul_assoc(W, R, wx, pt, py)) : {Al.SR.mul(W, R)(wx, Al.SR.mul(W, R)(pt, py)) == _ : W}
      {==}

# A residual of the denoted language is the reached continuation, scaled by
# the consumed path's weight.
def residual_continuation(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: StateAlgebra<S, A, W>, +q: S, +xs: List<&2, A>, +ys: List<&2, A>) ->
    {unnormalized(~S, ~A, ~W, ~R, ~M, q, List.append(&2, A, xs, ys)) == Al.SR.mul(W, R)(pathWeight(~S, ~A, ~W, ~R, ~M, xs, q), unnormalized(~S, ~A, ~W, ~R, ~M, run(~S, ~A, ~W, ~M, xs, q), ys)) : W}:
  +p = pathWeight(~S, ~A, ~W, ~R, ~M, xs, q)
  +q2 = run(~S, ~A, ~W, ~M, xs, q)
  +p2 = pathWeight(~S, ~A, ~W, ~R, ~M, ys, q2)
  +o = SA.out(S, A, W, M)(run(~S, ~A, ~W, ~M, ys, q2))
  %Equal.sym(S, run(~S, ~A, ~W, ~M, List.append(&2, A, xs, ys), q), run(~S, ~A, ~W, ~M, ys, q2), run_append(~S, ~A, ~W, ~M, xs, q, ys))
    : {Al.SR.mul(W, R)(pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, xs, ys), q), SA.out(S, A, W, M)(_)) == Al.SR.mul(W, R)(p, Al.SR.mul(W, R)(p2, o)) : W}
  %Equal.sym(W, pathWeight(~S, ~A, ~W, ~R, ~M, List.append(&2, A, xs, ys), q), Al.SR.mul(W, R)(p, p2), factorization(~S, ~A, ~W, ~R, ~M, xs, q, ys))
    : {Al.SR.mul(W, R)(_, o) == Al.SR.mul(W, R)(p, Al.SR.mul(W, R)(p2, o)) : W}
  Al.SR.mul_assoc(W, R, p, p2, o)

# The denoted language, as a Weighted language.
def denotes(~S: Data, ~A: Data, ~W: Data, ~R: Al.Semiring<W>, ~M: StateAlgebra<S, A, W>, +q: S) -> Wt.Language(A, W):
  xs => unnormalized(~S, ~A, ~W, ~R, ~M, q, xs)

# A finite next-token distribution: its mass law ranges exactly over the
# supplied vocabulary list, and the terminal weight is the EOS mass.
def listSum(~W: Data, ~R: Al.Semiring<W>, xs: List<&2, W>) -> W:
  match xs:
    case Nil{}:
      Al.SR.zero(W, R)
    case h <> t:
      Al.SR.add(W, R)(h, listSum(~W, ~R, t))

def weights(~A: Data, ~W: Data, ~f: A -> W, xs: List<&2, A>) -> List<&2, W>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      f(h) <> weights(~A, ~W, ~f, t)

# Instances ----------------------------------------------------------------
#
# A counting machine over Nat: the state is the running token sum, each
# step weighs its token plus one, and the observation is the state.

def count.out(q: Nat) -> Nat:
  q

def count.step(+q: Nat, +x: Nat) -> WS<Nat, Nat>:
  WS{1n+x, Nat.add(q, x)}

def count() -> StateAlgebra<Nat, Nat, Nat>:
  StateAlgebra{q => count.out(q), q => x => count.step(q, x)}

# The same shape over Bool: a parity-like machine whose weights are Bool.
def flip.step(+q: Bool, +x: Bool) -> WS<Bool, Bool>:
  WS{Bool.or(q, x), Bool.xor(q, x)}

def flip() -> StateAlgebra<Bool, Bool, Bool>:
  StateAlgebra{q => q, q => x => flip.step(q, x)}

law check.residual_continuation:
  for +q: Nat
  for +xs: List<&2, Nat>
  for +ys: List<&2, Nat>
  for +b: Bool
  for +us: List<&2, Bool>
  for +vs: List<&2, Bool>
  {unnormalized(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~count(), q, List.append(&2, Nat, xs, ys)) == Nat.mul(pathWeight(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~count(), xs, q), unnormalized(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~count(), run(~Nat, ~Nat, ~Nat, ~count(), xs, q), ys)) : Nat}
  & {unnormalized(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~flip(), b, List.append(&2, Bool, us, vs)) == Bool.and(pathWeight(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~flip(), us, b), unnormalized(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~flip(), run(~Bool, ~Bool, ~Bool, ~flip(), us, b), vs)) : Bool}

def check.residual_continuation(q, xs, ys, b, us, vs):
  (residual_continuation(~Nat, ~Nat, ~Nat, ~Al.Nat.semiring(), ~count(), q, xs, ys),
   residual_continuation(~Bool, ~Bool, ~Bool, ~Al.Bool.semiring(), ~flip(), b, us, vs))
