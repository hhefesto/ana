import Base
import ../Spec/Algebra.bend as Al

# The carriers legere computes in.  The meaning of a segmenter is one
# weighted language (Legere/Spec.bend); the carrier chosen answers the
# question asked of it (Goodman's semiring parsing):
#
#   bool  is the text well formed (some segmentation has nonzero weight)
#   nat   how many segmentations it has
#   logp  the total weight in log space: log-sum-exp is the sum, + the
#         product; with probabilities it is the marginal likelihood, and
#         forward-backward in it gives the posteriors
#   maxp  the best segmentation's weight in log space (max-plus, Viterbi)
#
# Bool and Nat are lawful: they are the record of Spec/Algebra.bend with
# its laws forgotten, so every theorem proven there holds for them.  logp
# and maxp approximate the nonnegative reals (in log space) in F32, whose
# addition is not associative: they are held to the lawful carriers by
# tests within a tolerance, never by proof.

type Sr<-W: Data> is Type:
  Sr{zero: W, one: W, add: W -> W -> W, mul: W -> W -> W}

def Sr.zero(-W: Data, r: Sr<W>) -> W:
  match r:
    case Sr{z, o, a, m}:
      z

def Sr.one(-W: Data, r: Sr<W>) -> W:
  match r:
    case Sr{z, o, a, m}:
      o

def Sr.add(-W: Data, r: Sr<W>) -> W -> W -> W:
  match r:
    case Sr{z, o, a, m}:
      a

def Sr.mul(-W: Data, r: Sr<W>) -> W -> W -> W:
  match r:
    case Sr{z, o, a, m}:
      m

# a lawful semiring, its laws forgotten
def Sr.of(-W: Data, r: Al.Semiring<W>) -> Sr<W>:
  match r:
    case Al.Semiring{z, o, a, m, p1, p2, p3, p4, p5, p6, p7, p8, p9, p10}:
      Sr{z, o, a, m}

def bool() -> Sr<Bool>:
  Sr.of(Bool, Al.Bool.semiring())

def nat() -> Sr<Nat>:
  Sr.of(Nat, Al.Nat.semiring())

# log 0
def ninf() -> F32:
  F32.log(0.0)

def is_ninf(+x: F32) -> Bool:
  F32.is_eq(x, ninf())

def lse.pick(+a: F32, +b: F32, +m: F32, z: Bool) -> F32:
  match z:
    case True{}:
      m
    case False{}:
      F32.add(m, F32.log(F32.add(F32.exp(F32.sub(a, m)), F32.exp(F32.sub(b, m)))))

# log(e^a + e^b), exact at log 0 (where the plain formula is -inf - -inf)
def lse(+a: F32, +b: F32) -> F32:
  +m = F32.max(a, b)
  lse.pick(a, b, m, is_ninf(m))

def logp() -> Sr<F32>:
  Sr{ninf(), 0.0, a => b => lse(a, b), a => b => F32.add(a, b)}

def maxp() -> Sr<F32>:
  Sr{ninf(), 0.0, a => b => F32.max(a, b), a => b => F32.add(a, b)}

# The operations as templates, so a definition over any carrier reads as
# arithmetic: zero(~W, ~S), add(~W, ~S, a, b), ...
def zero(~W: Data, ~S: Sr<W>) -> W:
  Sr.zero(W, S)

def one(~W: Data, ~S: Sr<W>) -> W:
  Sr.one(W, S)

def add(~W: Data, ~S: Sr<W>, a: W, b: W) -> W:
  Sr.add(W, S)(a, b)

def mul(~W: Data, ~S: Sr<W>, a: W, b: W) -> W:
  Sr.mul(W, S)(a, b)

# the sum of a row
def sum(~W: Data, ~S: Sr<W>, xs: List<&2, W>) -> W:
  match xs:
    case Nil{}:
      zero(~W, ~S)
    case x <> t:
      add(~W, ~S, x, sum(~W, ~S, t))

# the i-th entry of a row, zero past its end
def at(~W: Data, ~S: Sr<W>, xs: List<&2, W>, i: Nat) -> W:
  match xs i:
    case Nil{} _:
      zero(~W, ~S)
    case x <> t 0n:
      x
    case x <> t 1n+p:
      at(~W, ~S, t, p)

# the i-th row of a table, empty past its end
def at.row(-W: Data, xss: List<&2, List<&2, W>>, i: Nat) -> List<&2, W>:
  match xss i:
    case Nil{} _:
      Nil{}
    case x <> t 0n:
      x
    case x <> t 1n+p:
      at.row(W, t, p)
