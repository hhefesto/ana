import Base
import ./Semiring.bend as R
import ./Spec.bend as Sp

# Legere/Spec.bend's values in time linear in the text: forward-backward
# over the lines, in any semiring.  This is the memoized derivative of the
# weighted language (Elliott): after i lines, everything the rest of the
# text needs is one weight per tag (alpha), so 𝒟 is a k-vector and δ is a
# step on it.  Each value here equals its Spec counterpart wherever the
# carrier's laws hold (Bool, Nat), and within the numerics in F32 (logp,
# maxp); bend/tests/legere.bend checks both against the enumeration.

# the columns of a k-column table: cols[u][t] = xss[t][u]
def heads(~W: Data, ~S: R.Sr<W>, xss: List<&2, List<&2, W>>) -> List<&2, W>:
  match xss:
    case Nil{}:
      Nil{}
    case xs <> rest:
      R.at(~W, ~S, xs, 0n) <> heads(~W, ~S, rest)

def tails(-W: Data, xss: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  match xss:
    case Nil{}:
      Nil{}
    case xs <> rest:
      List.tail(&2, W, xs) <> tails(W, rest)

def cols(~W: Data, ~S: R.Sr<W>, k: Nat, +xss: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      heads(~W, ~S, xss) <> cols(~W, ~S, p, tails(W, xss))

# x ⊙ y and x · y
def had(~W: Data, ~S: R.Sr<W>, xs: List<&2, W>, ys: List<&2, W>) -> List<&2, W>:
  match xs ys:
    case x <> xt y <> yt:
      R.mul(~W, ~S, x, y) <> had(~W, ~S, xt, yt)
    case _ _:
      Nil{}

def dot(~W: Data, ~S: R.Sr<W>, xs: List<&2, W>, ys: List<&2, W>) -> W:
  match xs ys:
    case x <> xt y <> yt:
      R.add(~W, ~S, R.mul(~W, ~S, x, y), dot(~W, ~S, xt, yt))
    case _ _:
      R.zero(~W, ~S)

# one line: alpha'[u] = (Σ_t alpha[t] · trans[t][u]) · e[u]
def step(~W: Data, ~S: R.Sr<W>, cs: List<&2, List<&2, W>>, r: List<&2, W>, +alpha: List<&2, W>) -> List<&2, W>:
  match cs r:
    case c <> ct x <> rt:
      R.mul(~W, ~S, dot(~W, ~S, alpha, c), x) <> step(~W, ~S, ct, rt, alpha)
    case _ _:
      Nil{}

def alphas.go(~W: Data, ~S: R.Sr<W>, rows: List<&2, List<&2, W>>, +cs: List<&2, List<&2, W>>, +a: List<&2, W>, acc: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  match rows:
    case Nil{}:
      a <> acc
    case r <> rs:
      alphas.go(~W, ~S, rs, cs, step(~W, ~S, cs, r, a), a <> acc)

# alpha_i for every line, NEWEST FIRST: alpha_i[u] is the weight of the
# first i+1 lines over the labellings that give line i the tag u
def alphas(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, em: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  match em:
    case Nil{}:
      Nil{}
    case r <> rs:
      alphas.go(~W, ~S, rs, cols(~W, ~S, Sp.Hmm.k(W, h), Sp.Hmm.trans(W, h)), had(~W, ~S, Sp.Hmm.start(W, h), r), Nil{})

def score.of(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, al: List<&2, List<&2, W>>) -> W:
  match al:
    case Nil{}:
      R.one(~W, ~S)
    case a <> rest:
      dot(~W, ~S, a, Sp.Hmm.final(W, h))

# ⟦M⟧ (Sp.score)
def score(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, em: List<&2, List<&2, W>>) -> W:
  score.of(~W, ~S, h, alphas(~W, ~S, h, em))

# one line back: beta[t] = Σ_u trans[t][u] · (e ⊙ beta')[u]
def bstep(~W: Data, ~S: R.Sr<W>, trans: List<&2, List<&2, W>>, +v: List<&2, W>) -> List<&2, W>:
  match trans:
    case Nil{}:
      Nil{}
    case tr <> rest:
      dot(~W, ~S, tr, v) <> bstep(~W, ~S, rest, v)

def betas.go(~W: Data, ~S: R.Sr<W>, rrows: List<&2, List<&2, W>>, +trans: List<&2, List<&2, W>>, +b: List<&2, W>, acc: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  match rrows:
    case Nil{}:
      b <> acc
    case r <> rs:
      betas.go(~W, ~S, rs, trans, bstep(~W, ~S, trans, had(~W, ~S, r, b)), b <> acc)

# beta_i for every line, OLDEST FIRST: beta_i[t] is the weight of the
# lines after i (with final) given that line i has tag t.  The rows it
# walks are e_{n-1} .. e_1 (e_0 is never needed).
def betas(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, +em: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  match em:
    case Nil{}:
      Nil{}
    case r <> rs:
      betas.go(~W, ~S, List.reverse(&2, List<&2, W>, rs), Sp.Hmm.trans(W, h), Sp.Hmm.final(W, h), Nil{})

def zip.had(~W: Data, ~S: R.Sr<W>, al: List<&2, List<&2, W>>, bl: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  match al bl:
    case a <> at b <> bt:
      had(~W, ~S, a, b) <> zip.had(~W, ~S, at, bt)
    case _ _:
      Nil{}

# marginals[i][u] = Sp.marginal(i, u): alpha_i ⊙ beta_i
def marginals(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, +em: List<&2, List<&2, W>>) -> List<&2, List<&2, W>>:
  zip.had(~W, ~S, List.reverse(&2, List<&2, W>, alphas(~W, ~S, h, em)), betas(~W, ~S, h, em))

# Σ_{t ≠ u} alpha[t] · c[t]
def dot.skip(~W: Data, ~S: R.Sr<W>, xs: List<&2, W>, ys: List<&2, W>, +u: Nat, +j: Nat) -> W:
  match xs ys:
    case x <> xt y <> yt:
      R.add(~W, ~S, Bool.pick(W, Nat.is_eq(u, j), R.zero(~W, ~S), R.mul(~W, ~S, x, y)), dot.skip(~W, ~S, xt, yt, u, 1n+j))
    case _ _:
      R.zero(~W, ~S)

# Σ_u (Σ_{t≠u} alpha[t] · trans[t][u]) · e[u] · beta[u]
def bnd(~W: Data, ~S: R.Sr<W>, cs: List<&2, List<&2, W>>, r: List<&2, W>, b: List<&2, W>, +alpha: List<&2, W>, +u: Nat) -> W:
  match cs r b:
    case c <> ct x <> rt y <> bt:
      R.add(~W, ~S, R.mul(~W, ~S, R.mul(~W, ~S, dot.skip(~W, ~S, alpha, c, u, 0n), x), y), bnd(~W, ~S, ct, rt, bt, alpha, 1n+u))
    case _ _ _:
      R.zero(~W, ~S)

def bounds.go(~W: Data, ~S: R.Sr<W>, al: List<&2, List<&2, W>>, es: List<&2, List<&2, W>>, bl: List<&2, List<&2, W>>, +cs: List<&2, List<&2, W>>) -> List<&2, W>:
  match al es bl:
    case a <> at e <> et b <> bt:
      bnd(~W, ~S, cs, e, b, a, 0n) <> bounds.go(~W, ~S, at, et, bt, cs)
    case _ _ _:
      Nil{}

# boundaries[j] = Sp.boundary(j+1): the weight of a section starting at
# each line after the first
def boundaries(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, +em: List<&2, List<&2, W>>) -> List<&2, W>:
  bounds.go(~W, ~S, List.reverse(&2, List<&2, W>, alphas(~W, ~S, h, em)), List.tail(&2, List<&2, W>, em),
    List.tail(&2, List<&2, W>, betas(~W, ~S, h, em)), cols(~W, ~S, Sp.Hmm.k(W, h), Sp.Hmm.trans(W, h)))

# Posteriors, in logp: the marginals over ⟦M⟧ (log space: a difference)
def over(xs: List<&2, F32>, +z: F32) -> List<&2, F32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      F32.sub(x, z) <> over(t, z)

def over.rows(xss: List<&2, List<&2, F32>>, +z: F32) -> List<&2, List<&2, F32>>:
  match xss:
    case Nil{}:
      Nil{}
    case xs <> t:
      over(xs, z) <> over.rows(t, z)

# log P(line i has tag u | text), one row per line
def posteriors(+h: Sp.Hmm<F32>, +em: List<&2, List<&2, F32>>) -> List<&2, List<&2, F32>>:
  over.rows(marginals(~F32, ~R.logp(), h, em), score(~F32, ~R.logp(), h, em))

# log P(a section starts at line j+1 | text)
def bposteriors(+h: Sp.Hmm<F32>, +em: List<&2, List<&2, F32>>) -> List<&2, F32>:
  over(boundaries(~F32, ~R.logp(), h, em), score(~F32, ~R.logp(), h, em))

# Viterbi, in maxp: the best labelling (Sp.best's) with backpointers.
# the best of x[t] + y[t] and its first index (strict >, as Sp.best)
def amax(xs: List<&2, F32>, ys: List<&2, F32>, +j: Nat, +bv: F32, +bi: Nat) -> F32 & Nat:
  match xs ys:
    case x <> xt y <> yt:
      +v = F32.add(x, y)
      +gt = F32.is_gt(v, bv)
      amax(xt, yt, 1n+j, Bool.pick(F32, gt, v, bv), Bool.pick(Nat, gt, j, bi))
    case _ _:
      (bv, bi)

# one line: the best alpha'[u] and the tag t it came from
def vstep.cons(+x: F32, mi: F32 & Nat, rest: List<&2, F32> & List<&2, Nat>) -> List<&2, F32> & List<&2, Nat>:
  (m, i) = mi
  (vs, ix) = rest
  (F32.add(m, x) <> vs, i <> ix)

def vstep(cs: List<&2, List<&2, F32>>, r: List<&2, F32>, +alpha: List<&2, F32>) -> List<&2, F32> & List<&2, Nat>:
  match cs r:
    case c <> ct x <> rt:
      vstep.cons(x, amax(alpha, c, 0n, R.ninf(), 0n), vstep(ct, rt, alpha))
    case _ _:
      (Nil{}, Nil{})

def vit.push2(q: List<&2, F32> & List<&2, Nat>, bps: List<&2, List<&2, Nat>>) -> List<&2, F32> & List<&2, List<&2, Nat>>:
  (a2, bp) = q
  (a2, bp <> bps)

def vit.push(+cs: List<&2, List<&2, F32>>, r: List<&2, F32>, p: List<&2, F32> & List<&2, List<&2, Nat>>) -> List<&2, F32> & List<&2, List<&2, Nat>>:
  (a, bps) = p
  vit.push2(vstep(cs, r, a), bps)

# alpha after the last line, and the backpointers of lines 1.., newest first
def vit.go(rows: List<&2, List<&2, F32>>, +cs: List<&2, List<&2, F32>>, p: List<&2, F32> & List<&2, List<&2, Nat>>) -> List<&2, F32> & List<&2, List<&2, Nat>>:
  match rows:
    case Nil{}:
      p
    case r <> rs:
      vit.go(rs, cs, vit.push(cs, r, p))

def nat.at(xs: List<&2, Nat>, i: Nat) -> Nat:
  match xs i:
    case Nil{} _:
      0n
    case x <> t 0n:
      x
    case x <> t 1n+p:
      nat.at(t, p)

# follow the backpointers (newest first) from the last line's tag
def back(bps: List<&2, List<&2, Nat>>, +t: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match bps:
    case Nil{}:
      t <> acc
    case bp <> rest:
      back(rest, nat.at(bp, t), t <> acc)

def viterbi.fin(q: F32 & Nat, bps: List<&2, List<&2, Nat>>) -> F32 & List<&2, Nat>:
  (s, last) = q
  (s, back(bps, last, Nil{}))

def viterbi.end(+h: Sp.Hmm<F32>, r: List<&2, F32> & List<&2, List<&2, Nat>>) -> F32 & List<&2, Nat>:
  (a, bps) = r
  viterbi.fin(amax(a, Sp.Hmm.final(F32, h), 0n, R.ninf(), 0n), bps)

# the best labelling and its weight (Sp.best)
def viterbi(+h: Sp.Hmm<F32>, em: List<&2, List<&2, F32>>) -> F32 & List<&2, Nat>:
  match em:
    case Nil{}:
      (0.0, Nil{})
    case r <> rs:
      viterbi.end(h, vit.go(rs, cols(~F32, ~R.maxp(), Sp.Hmm.k(F32, h), Sp.Hmm.trans(F32, h)), (had(~F32, ~R.maxp(), Sp.Hmm.start(F32, h), r), Nil{})))
