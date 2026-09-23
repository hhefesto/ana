import Base
import ../Tensor.bend as T
import ../Model.bend as Md
# Optimizers over the weight trees (master: backend/futhark/model.fut
# clip_global_norm_def, adamw_step_def, muon_step_def; Optimizer.hs for the
# schedule).  Parameters, gradients, moments and momentum are all Md.Weights
# of one shape, so every step is a structural map.
#
# Decay: every matrix and the qk-norm gains decay (Layout.hs); norm gains,
# gate_lambda and sinks do not.  Muon owns the blocks' 2-D matrices;
# everything else (embedding, vectors) stays on AdamW.
type Hyp is Data:
  Hyp{lr: F32, b1: F32, b2: F32, eps: F32, wd: F32, c1: F32, c2: F32, mu: F32}

def lr.at.if(warm: Bool, flat: Bool, +base: F32, +step: Nat, +warmup: Nat, +total: Nat) -> F32:
  match warm flat:
    case True{} _:
      F32.div(F32.mul(base, F32.from_nat(step)), F32.from_nat(warmup))
    case False{} True{}:
      base
    case False{} False{}:
      +span = Nat.sub(total, warmup)
      +progress = F32.div(F32.from_nat(Nat.min(span, Nat.sub(step, warmup))), F32.from_nat(span))
      F32.mul(F32.mul(base, 0.5), F32.add(1.0, F32.cos(F32.mul(F32.pi(), progress))))

# linear warmup to `base`, then cosine to zero at `total` (learningRate)
def lr.at(+base: F32, +step: Nat, +warmup: Nat, +total: Nat) -> F32:
  lr.at.if(Bool.and(Nat.is_lt(0n, warmup), Nat.is_le(step, warmup)), Nat.is_le(total, warmup), base, step, warmup, total)

def Hyp.at(+lr: F32, +b1: F32, +b2: F32, +eps: F32, +wd: F32, +mu: F32, +step: Nat) -> Hyp:
  Hyp{lr, b1, b2, eps, wd, F32.sub(1.0, F32.pow(b1, F32.from_nat(step))), F32.sub(1.0, F32.pow(b2, F32.from_nat(step))), mu}

# AdamW on one tree ---------------------------------------------------------

type AV is Data:
  AV{p: T.V, m: T.V, v: T.V}

def AV.join(a: AV, b: AV) -> AV:
  match a b:
    case AV{p1, m1, v1} AV{p2, m2, v2}:
      AV{T.VN{p1, p2}, T.VN{m1, m2}, T.VN{v1, v2}}

def adam.decay(on: Bool, +wd: F32, +p: F32) -> F32:
  match on:
    case True{}:
      F32.mul(wd, p)
    case False{}:
      0.0

def adam.one(+h: Hyp, decay: Bool, +p: F32, +g: F32, +m: F32, +v: F32) -> AV:
  match h:
    case Hyp{+lr, +b1, +b2, +eps, +wd, +c1, +c2, mu}:
      +m2 = F32.add(F32.mul(b1, m), F32.mul(F32.sub(1.0, b1), g))
      +v2 = F32.add(F32.mul(b2, v), F32.mul(F32.mul(F32.sub(1.0, b2), g), g))
      +adaptive = F32.div(F32.div(m2, c1), F32.add(F32.sqrt(F32.div(v2, c2)), eps))
      AV{T.VL{F32.sub(p, F32.mul(lr, F32.add(adaptive, adam.decay(decay, wd, p))))}, T.VL{m2}, T.VL{v2}}

def leaf.or0(+x: T.V) -> F32:
  match x:
    case T.VL{a}:
      a
    case _:
      0.0

def kid.l(+x: T.V) -> T.V:
  match x:
    case T.VN{l, r}:
      l
    case _:
      T.VZ{}

def kid.r(+x: T.V) -> T.V:
  match x:
    case T.VN{l, r}:
      r
    case _:
      T.VZ{}

# moments may be absent (VZ) on the first step: they read as zero; so may a
# gradient piece that received no cotangent
def adam.v(+h: Hyp, +decay: Bool, +p: T.V, +g: T.V, +m: T.V, +v: T.V) -> AV:
  match p:
    case T.VL{x}:
      adam.one(h, decay, x, leaf.or0(g), leaf.or0(m), leaf.or0(v))
    case T.VN{pl, pr}:
      AV.join(adam.v(h, decay, pl, kid.l(g), kid.l(m), kid.l(v)), adam.v(h, decay, pr, kid.r(g), kid.r(m), kid.r(v)))
    case T.VZ{}:
      AV{T.VZ{}, T.VZ{}, T.VZ{}}

type AM is Data:
  AM{p: T.M, m: T.M, v: T.M}

def AM.join(a: AM, b: AM) -> AM:
  match a b:
    case AM{p1, m1, v1} AM{p2, m2, v2}:
      AM{T.MN{p1, p2}, T.MN{m1, m2}, T.MN{v1, v2}}

def AM.leaf(a: AV) -> AM:
  match a:
    case AV{p, m, v}:
      AM{T.ML{p}, T.ML{m}, T.ML{v}}

def mrow(+x: T.M) -> T.V:
  match x:
    case T.ML{r}:
      r
    case _:
      T.VZ{}

def mkid.l(+x: T.M) -> T.M:
  match x:
    case T.MN{l, r}:
      l
    case _:
      T.MZ{}

def mkid.r(+x: T.M) -> T.M:
  match x:
    case T.MN{l, r}:
      r
    case _:
      T.MZ{}

def adam.m(+h: Hyp, +p: T.M, +g: T.M, +m: T.M, +v: T.M) -> AM:
  match p:
    case T.ML{row}:
      AM.leaf(adam.v(h, True{}, row, mrow(g), mrow(m), mrow(v)))
    case T.MN{pl, pr}:
      a b = adam.m(h, pl, mkid.l(g), mkid.l(m), mkid.l(v)) adam.m(h, pr, mkid.r(g), mkid.r(m), mkid.r(v))
      AM.join(a, b)
    case T.MZ{}:
      AM{T.MZ{}, T.MZ{}, T.MZ{}}

# Muon on one hidden matrix ----------------------------------------------
#
# momentum' = beta mu + g; X = NS5(g + beta momentum'); the update is
# 0.2 sqrt(max(r, c)) X plus decoupled decay.  NS5 iterates the quintic
# X <- a X + (b A + c A^2) X with A = X X^T on the Frobenius-normalized
# input, or X <- a X + X (b A + c A^2) with A = X^T X when rows > cols (the
# transpose's iteration, without forming the transpose).

def M.smul(+s: F32, +m: T.M) -> T.M:
  match m:
    case T.ML{r}:
      T.ML{T.V.scale(s, r)}
    case T.MN{l, r}:
      a b = M.smul(s, l) M.smul(s, r)
      T.MN{a, b}
    case T.MZ{}:
      T.MZ{}

# rows of X X^T: row i is X x_i
def gram.rows(+x: T.M, +m: T.M) -> T.M:
  match m:
    case T.ML{r}:
      T.ML{T.M.matvec(x, r)}
    case T.MN{l, r}:
      a b = gram.rows(x, l) gram.rows(x, r)
      T.MN{a, b}
    case T.MZ{}:
      T.MZ{}

# rows of B X: row i is B_i^T X
def left.mul(+b: T.M, +x: T.M) -> T.M:
  match b:
    case T.ML{r}:
      T.ML{T.M.vecmat(r, x)}
    case T.MN{l, r}:
      a c = left.mul(l, x) left.mul(r, x)
      T.MN{a, c}
    case T.MZ{}:
      T.MZ{}

# rows of X B for symmetric B: row i is x_i^T B
def right.mul(+x: T.M, +b: T.M) -> T.M:
  match x:
    case T.ML{r}:
      T.ML{T.M.vecmat(r, b)}
    case T.MN{l, r}:
      a c = right.mul(l, b) right.mul(r, b)
      T.MN{a, c}
    case T.MZ{}:
      T.MZ{}

# X^T X as the sum of the rows' outer products
def gram.cols(+x: T.M) -> T.M:
  match x:
    case T.ML{r}:
      T.M.outer(r, r)
    case T.MN{l, r}:
      a b = gram.cols(l) gram.cols(r)
      T.M.add(a, b)
    case T.MZ{}:
      T.MZ{}

def poly(+a: T.M) -> T.M:
  T.M.add(M.smul(F32.neg(4.775), a), M.smul(2.0315, gram.rows(a, a)))

def ns.step(wide: Bool, +x: T.M) -> T.M:
  match wide:
    case True{}:
      T.M.add(M.smul(3.4445, x), left.mul(poly(gram.rows(x, x)), x))
    case False{}:
      T.M.add(M.smul(3.4445, x), right.mul(x, poly(gram.cols(x))))

def ns5.go(n: Nat, +wide: Bool, +x: T.M) -> T.M:
  match n:
    case 0n:
      x
    case 1n+p:
      ns5.go(p, wide, ns.step(wide, x))

def ns5(+wide: Bool, +m: T.M) -> T.M:
  ns5.go(5n, wide, M.smul(F32.div(1.0, F32.add(F32.sqrt(T.M.sumsq(m)), 1.0e-7)), m))

type MU is Data:
  MU{p: T.M, mom: T.M}

def muon.m(+h: Hyp, +rows: Nat, +cols: Nat, +p: T.M, +g: T.M, +mom: T.M) -> MU:
  match h:
    case Hyp{+lr, b1, b2, eps, +wd, c1, c2, +mu}:
      +mom2 = T.M.add(M.smul(mu, mom), g)
      +o = ns5(Nat.is_le(rows, cols), T.M.add(g, M.smul(mu, mom2)))
      +sc = F32.mul(0.2, F32.sqrt(F32.from_nat(Nat.max(rows, cols))))
      MU{T.M.add(p, M.smul(F32.neg(lr), T.M.add(M.smul(sc, o), M.smul(wd, p)))), mom2}

# Whole models --------------------------------------------------------------
#
# The optimizer state: Adam moments and Muon momentum, each a Md.Weights of
# the parameters' shape (absent pieces read as zero).

type State is Data:
  State{step: Nat, m: Md.Weights, v: Md.Weights, mom: Md.Weights}

def W.zero() -> Md.Weights:
  Md.Weights{T.MZ{}, Nil{}, T.VZ{}, T.MZ{}}

def State.fresh() -> State:
  State{0n, W.zero(), W.zero(), W.zero()}

def blk.sumsq(+b: Md.Block) -> F32:
  match b:
    case Md.GlaB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11}:
      F32.add(F32.add(F32.add(T.V.sumsq(a1), T.M.sumsq(a2)), F32.add(T.M.sumsq(a3), T.M.sumsq(a4))),
        F32.add(F32.add(F32.add(T.M.sumsq(a5), T.M.sumsq(a6)), F32.add(T.V.sumsq(a7), T.V.sumsq(a8))),
          F32.add(T.M.sumsq(a9), F32.add(T.M.sumsq(a10), T.M.sumsq(a11)))))
    case Md.SmB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12}:
      F32.add(F32.add(F32.add(T.V.sumsq(a1), T.M.sumsq(a2)), F32.add(T.M.sumsq(a3), T.M.sumsq(a4))),
        F32.add(F32.add(F32.add(T.M.sumsq(a5), T.V.sumsq(a6)), F32.add(T.V.sumsq(a7), T.V.sumsq(a8))),
          F32.add(T.V.sumsq(a9), F32.add(T.M.sumsq(a10), F32.add(T.M.sumsq(a11), T.M.sumsq(a12))))))

def blks.sumsq(bs: List<&2, Md.Block>) -> F32:
  match bs:
    case Nil{}:
      0.0
    case +b <> t:
      F32.add(blk.sumsq(b), blks.sumsq(t))

def W.sumsq(+w: Md.Weights) -> F32:
  match w:
    case Md.Weights{e, bs, f, u}:
      F32.add(F32.add(T.M.sumsq(e), blks.sumsq(bs)), F32.add(T.V.sumsq(f), T.M.sumsq(u)))

def blk.scale(+s: F32, +b: Md.Block) -> Md.Block:
  match b:
    case Md.GlaB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11}:
      Md.GlaB{T.V.scale(s, a1), M.smul(s, a2), M.smul(s, a3), M.smul(s, a4), M.smul(s, a5), M.smul(s, a6),
              T.V.scale(s, a7), T.V.scale(s, a8), M.smul(s, a9), M.smul(s, a10), M.smul(s, a11)}
    case Md.SmB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12}:
      Md.SmB{T.V.scale(s, a1), M.smul(s, a2), M.smul(s, a3), M.smul(s, a4), M.smul(s, a5), T.V.scale(s, a6),
             T.V.scale(s, a7), T.V.scale(s, a8), T.V.scale(s, a9), M.smul(s, a10), M.smul(s, a11), M.smul(s, a12)}

def blks.scale(+s: F32, bs: List<&2, Md.Block>) -> List<&2, Md.Block>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      blk.scale(s, b) <> blks.scale(s, t)

def W.scale(+s: F32, +w: Md.Weights) -> Md.Weights:
  match w:
    case Md.Weights{e, bs, f, u}:
      Md.Weights{M.smul(s, e), blks.scale(s, bs), T.V.scale(s, f), M.smul(s, u)}

def clip.scale.if(over: Bool, finite: Bool, +norm: F32, +max_norm: F32) -> F32:
  match over finite:
    case _ False{}:
      0.0
    case True{} True{}:
      F32.div(max_norm, F32.add(norm, 1.0e-12))
    case False{} True{}:
      1.0

# the global-norm clip: the norm, and the scale that brings it to max_norm
# (clip_global_norm_def; a non-finite norm clips to zero rather than
# passing NaN through, the fault master recorded at v3 step 5,006)
def clip.scale(+norm: F32, +max_norm: F32) -> F32:
  clip.scale.if(F32.is_gt(norm, max_norm), F32.is_eq(norm, norm), norm, max_norm)

# One step on a block: its matrices by Muon (when on) or AdamW, its vectors
# by AdamW.  qk gains decay; norm gains, gate_lambda and sinks do not.
type BS is Data:
  BS{p: Md.Block, m: Md.Block, v: Md.Block, mom: Md.Block}

def AV.p(+a: AV) -> T.V:
  match a:
    case AV{p, m, v}:
      p

def AV.m(+a: AV) -> T.V:
  match a:
    case AV{p, m, v}:
      m

def AV.v(+a: AV) -> T.V:
  match a:
    case AV{p, m, v}:
      v

def AM.p(+a: AM) -> T.M:
  match a:
    case AM{p, m, v}:
      p

def AM.m(+a: AM) -> T.M:
  match a:
    case AM{p, m, v}:
      m

def AM.v(+a: AM) -> T.M:
  match a:
    case AM{p, m, v}:
      v

def MU.p(+a: MU) -> T.M:
  match a:
    case MU{p, mom}:
      p

def MU.mom(+a: MU) -> T.M:
  match a:
    case MU{p, mom}:
      mom

# a matrix by Muon or AdamW, packed as (p, m, v, mom)
type Mat4 is Data:
  Mat4{p: T.M, m: T.M, v: T.M, mom: T.M}

def mat.step(muon: Bool, +h: Hyp, +rows: Nat, +cols: Nat, +p: T.M, +g: T.M, +m: T.M, +v: T.M, +mom: T.M) -> Mat4:
  match muon:
    case True{}:
      +r = muon.m(h, rows, cols, p, g, mom)
      Mat4{MU.p(r), T.MZ{}, T.MZ{}, MU.mom(r)}
    case False{}:
      +r = adam.m(h, p, g, m, v)
      Mat4{AM.p(r), AM.m(r), AM.v(r), T.MZ{}}

def Mat4.p(+a: Mat4) -> T.M:
  match a:
    case Mat4{p, m, v, u}:
      p

def Mat4.m(+a: Mat4) -> T.M:
  match a:
    case Mat4{p, m, v, u}:
      m

def Mat4.v(+a: Mat4) -> T.M:
  match a:
    case Mat4{p, m, v, u}:
      v

def Mat4.mom(+a: Mat4) -> T.M:
  match a:
    case Mat4{p, m, v, u}:
      u

def blk.zero_like(+b: Md.Block) -> Md.Block:
  match b:
    case Md.GlaB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11}:
      Md.GlaB{T.V.zero_like(a1), T.M.zero_like(a2), T.M.zero_like(a3), T.M.zero_like(a4), T.M.zero_like(a5), T.M.zero_like(a6),
              T.V.zero_like(a7), T.V.zero_like(a8), T.M.zero_like(a9), T.M.zero_like(a10), T.M.zero_like(a11)}
    case Md.SmB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12}:
      Md.SmB{T.V.zero_like(a1), T.M.zero_like(a2), T.M.zero_like(a3), T.M.zero_like(a4), T.M.zero_like(a5), T.V.zero_like(a6),
             T.V.zero_like(a7), T.V.zero_like(a8), T.V.zero_like(a9), T.M.zero_like(a10), T.M.zero_like(a11), T.M.zero_like(a12)}

def blks.zero_like(bs: List<&2, Md.Block>) -> List<&2, Md.Block>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      blk.zero_like(b) <> blks.zero_like(t)

def W.zero_like(+w: Md.Weights) -> Md.Weights:
  match w:
    case Md.Weights{e, bs, f, u}:
      Md.Weights{T.M.zero_like(e), blks.zero_like(bs), T.V.zero_like(f), T.M.zero_like(u)}

def State.init(+w: Md.Weights) -> State:
  State{0n, W.zero_like(w), W.zero_like(w), W.zero_like(w)}

def blk.add(+a: Md.Block, +b: Md.Block) -> Md.Block:
  match a b:
    case Md.GlaB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11} Md.GlaB{b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11}:
      Md.GlaB{T.V.add.pad(a1, b1), T.M.add(a2, b2), T.M.add(a3, b3), T.M.add(a4, b4), T.M.add(a5, b5), T.M.add(a6, b6),
              T.V.add.pad(a7, b7), T.V.add.pad(a8, b8), T.M.add(a9, b9), T.M.add(a10, b10), T.M.add(a11, b11)}
    case Md.SmB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12} Md.SmB{b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12}:
      Md.SmB{T.V.add.pad(a1, b1), T.M.add(a2, b2), T.M.add(a3, b3), T.M.add(a4, b4), T.M.add(a5, b5), T.V.add.pad(a6, b6),
             T.V.add.pad(a7, b7), T.V.add.pad(a8, b8), T.V.add.pad(a9, b9), T.M.add(a10, b10), T.M.add(a11, b11), T.M.add(a12, b12)}
    case _ _:
      a

def blks.add(xs: List<&2, Md.Block>, ys: List<&2, Md.Block>) -> List<&2, Md.Block>:
  match xs ys:
    case +x <> xt +y <> yt:
      blk.add(x, y) <> blks.add(xt, yt)
    case Nil{} _:
      ys
    case _ Nil{}:
      xs

# gradient sums (a batch of windows)
def W.add(+a: Md.Weights, +b: Md.Weights) -> Md.Weights:
  match a b:
    case Md.Weights{e1, bs1, f1, u1} Md.Weights{e2, bs2, f2, u2}:
      Md.Weights{T.M.add(e1, e2), blks.add(bs1, bs2), T.V.add.pad(f1, f2), T.M.add(u1, u2)}

# the four trees of one parameter (param, grad, m, v) stepped by AdamW
def vstep(+h: Hyp, +decay: Bool, +p: T.V, +g: T.V, +m: T.V, +v: T.V) -> AV:
  adam.v(h, decay, p, g, m, v)

type Q4 is Data:
  Q4{p: Md.Block, m: Md.Block, v: Md.Block, mom: Md.Block}

def Q4.p(+q: Q4) -> Md.Block:
  match q:
    case Q4{p, m, v, u}:
      p

def Q4.m(+q: Q4) -> Md.Block:
  match q:
    case Q4{p, m, v, u}:
      m

def Q4.v(+q: Q4) -> Md.Block:
  match q:
    case Q4{p, m, v, u}:
      v

def Q4.mom(+q: Q4) -> Md.Block:
  match q:
    case Q4{p, m, v, u}:
      u

def blk.step(+muon: Bool, +h: Hyp, +d: Nat, +f: Nat, +p: Md.Block, +g: Md.Block, +m: Md.Block, +v: Md.Block, +u: Md.Block) -> Q4:
  match p g m v u:
    case Md.GlaB{p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11} Md.GlaB{g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11}
         Md.GlaB{m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11} Md.GlaB{v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11}
         Md.GlaB{u1, u2, u3, u4, u5, u6, u7, u8, u9, u10, u11}:
      +a1 = vstep(h, False{}, p1, g1, m1, v1)
      +a7 = vstep(h, False{}, p7, g7, m7, v7)
      +a8 = vstep(h, False{}, p8, g8, m8, v8)
      +b2 = mat.step(muon, h, d, d, p2, g2, m2, v2, u2)
      +b3 = mat.step(muon, h, d, d, p3, g3, m3, v3, u3)
      +b4 = mat.step(muon, h, d, d, p4, g4, m4, v4, u4)
      +b5 = mat.step(muon, h, d, d, p5, g5, m5, v5, u5)
      +b6 = mat.step(muon, h, d, d, p6, g6, m6, v6, u6)
      +b9 = mat.step(muon, h, f, d, p9, g9, m9, v9, u9)
      +b10 = mat.step(muon, h, f, d, p10, g10, m10, v10, u10)
      +b11 = mat.step(muon, h, d, f, p11, g11, m11, v11, u11)
      Q4{Md.GlaB{AV.p(a1), Mat4.p(b2), Mat4.p(b3), Mat4.p(b4), Mat4.p(b5), Mat4.p(b6), AV.p(a7), AV.p(a8), Mat4.p(b9), Mat4.p(b10), Mat4.p(b11)},
         Md.GlaB{AV.m(a1), Mat4.m(b2), Mat4.m(b3), Mat4.m(b4), Mat4.m(b5), Mat4.m(b6), AV.m(a7), AV.m(a8), Mat4.m(b9), Mat4.m(b10), Mat4.m(b11)},
         Md.GlaB{AV.v(a1), Mat4.v(b2), Mat4.v(b3), Mat4.v(b4), Mat4.v(b5), Mat4.v(b6), AV.v(a7), AV.v(a8), Mat4.v(b9), Mat4.v(b10), Mat4.v(b11)},
         Md.GlaB{u1, Mat4.mom(b2), Mat4.mom(b3), Mat4.mom(b4), Mat4.mom(b5), Mat4.mom(b6), u7, u8, Mat4.mom(b9), Mat4.mom(b10), Mat4.mom(b11)}}
    case Md.SmB{p1, p2, p3, p4, p5, p6, p7, p8, p9, p10, p11, p12} Md.SmB{g1, g2, g3, g4, g5, g6, g7, g8, g9, g10, g11, g12}
         Md.SmB{m1, m2, m3, m4, m5, m6, m7, m8, m9, m10, m11, m12} Md.SmB{v1, v2, v3, v4, v5, v6, v7, v8, v9, v10, v11, v12}
         Md.SmB{u1, u2, u3, u4, u5, u6, u7, u8, u9, u10, u11, u12}:
      +a1 = vstep(h, False{}, p1, g1, m1, v1)
      +a6 = vstep(h, True{}, p6, g6, m6, v6)
      +a7 = vstep(h, True{}, p7, g7, m7, v7)
      +a8 = vstep(h, False{}, p8, g8, m8, v8)
      +a9 = vstep(h, False{}, p9, g9, m9, v9)
      +b2 = mat.step(muon, h, d, d, p2, g2, m2, v2, u2)
      +b3 = mat.step(muon, h, d, d, p3, g3, m3, v3, u3)
      +b4 = mat.step(muon, h, d, d, p4, g4, m4, v4, u4)
      +b5 = mat.step(muon, h, d, d, p5, g5, m5, v5, u5)
      +b10 = mat.step(muon, h, f, d, p10, g10, m10, v10, u10)
      +b11 = mat.step(muon, h, f, d, p11, g11, m11, v11, u11)
      +b12 = mat.step(muon, h, d, f, p12, g12, m12, v12, u12)
      Q4{Md.SmB{AV.p(a1), Mat4.p(b2), Mat4.p(b3), Mat4.p(b4), Mat4.p(b5), AV.p(a6), AV.p(a7), AV.p(a8), AV.p(a9), Mat4.p(b10), Mat4.p(b11), Mat4.p(b12)},
         Md.SmB{AV.m(a1), Mat4.m(b2), Mat4.m(b3), Mat4.m(b4), Mat4.m(b5), AV.m(a6), AV.m(a7), AV.m(a8), AV.m(a9), Mat4.m(b10), Mat4.m(b11), Mat4.m(b12)},
         Md.SmB{AV.v(a1), Mat4.v(b2), Mat4.v(b3), Mat4.v(b4), Mat4.v(b5), AV.v(a6), AV.v(a7), AV.v(a8), AV.v(a9), Mat4.v(b10), Mat4.v(b11), Mat4.v(b12)},
         Md.SmB{u1, Mat4.mom(b2), Mat4.mom(b3), Mat4.mom(b4), Mat4.mom(b5), u6, u7, u8, u9, Mat4.mom(b10), Mat4.mom(b11), Mat4.mom(b12)}}
    case _ _ _ _ _:
      Q4{p, m, v, u}

type BL4 is Data:
  BL4{p: List<&2, Md.Block>, m: List<&2, Md.Block>, v: List<&2, Md.Block>, mom: List<&2, Md.Block>}

def BL4.cons(+q: Q4, r: BL4) -> BL4:
  match r:
    case BL4{a, b, c, d}:
      BL4{Q4.p(q) <> a, Q4.m(q) <> b, Q4.v(q) <> c, Q4.mom(q) <> d}

def blks.step(ps: List<&2, Md.Block>, gs: List<&2, Md.Block>, ms: List<&2, Md.Block>, vs: List<&2, Md.Block>, us: List<&2, Md.Block>,
              +muon: Bool, +h: Hyp, +d: Nat, +f: Nat) -> BL4:
  match ps gs ms vs us:
    case +p <> pt +g <> gt +m <> mt +v <> vt +u <> ut:
      BL4.cons(blk.step(muon, h, d, f, p, g, m, v, u), blks.step(pt, gt, mt, vt, ut, muon, h, d, f))
    case _ _ _ _ _:
      BL4{Nil{}, Nil{}, Nil{}, Nil{}}

type Stepped is Data:
  Stepped{w: Md.Weights, st: State}

def Stepped.w(+s: Stepped) -> Md.Weights:
  match s:
    case Stepped{w, t}:
      w

def Stepped.st(+s: Stepped) -> State:
  match s:
    case Stepped{w, t}:
      t

def BL4.p(+r: BL4) -> List<&2, Md.Block>:
  match r:
    case BL4{a, b, c, d}:
      a

def BL4.m(+r: BL4) -> List<&2, Md.Block>:
  match r:
    case BL4{a, b, c, d}:
      b

def BL4.v(+r: BL4) -> List<&2, Md.Block>:
  match r:
    case BL4{a, b, c, d}:
      c

def BL4.mom(+r: BL4) -> List<&2, Md.Block>:
  match r:
    case BL4{a, b, c, d}:
      d

# one optimizer step on the whole model: gradient already clipped
def W.step(+muon: Bool, +base_lr: F32, +b1: F32, +b2: F32, +eps: F32, +wd: F32, +mu: F32, +warmup: Nat, +total: Nat,
           +d: Nat, +f: Nat, +w: Md.Weights, +g: Md.Weights, +st: State) -> Stepped:
  match w g st:
    case Md.Weights{pe, pbs, pf, pu} Md.Weights{ge, gbs, gf, gu}
         State{+n, Md.Weights{me, mbs, mf, mu2}, Md.Weights{ve, vbs, vf, vu}, Md.Weights{ue, ubs, uf, uu}}:
      +step = {1n+n : Nat}
      +h = Hyp.at(lr.at(base_lr, step, warmup, total), b1, b2, eps, wd, mu, step)
      +e = adam.m(h, pe, ge, me, ve)
      +fin = adam.v(h, False{}, pf, gf, mf, vf)
      +bs = blks.step(pbs, gbs, mbs, vbs, ubs, muon, h, d, f)
      Stepped{Md.Weights{AM.p(e), BL4.p(bs), AV.p(fin), pu},
              State{step, Md.Weights{AM.m(e), BL4.m(bs), AV.m(fin), mu2}, Md.Weights{AM.v(e), BL4.v(bs), AV.v(fin), vu},
                    Md.Weights{ue, BL4.mom(bs), uf, uu}}}
