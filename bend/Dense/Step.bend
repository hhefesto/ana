import Base
import ../Config.bend as C
import ./Ex.bend as X
import ./Op.bend as P
import ./Layout.bend as L
import ./Model.bend as M

# A training step as programs over the store. The forward writes every
# layer's input and the mean loss; the backward seeds the loss's tangent
# and runs the transposes last layer first, recomputing each layer's
# intermediates into the shared workspace before transposing it (the last
# layer's and the last head chunk's are still there). The optimizer reads
# the step's scalars (learning rate, bias corrections) from cells the host
# writes, and the clip scale from a cell the device computes from the
# gradient norm, so every program is built and encoded once.

def v(off: U32, st: List<&2, U32>) -> View:
  P.view(off, st)

def op(+es: Es) -> P.Op:
  P.ein(es, True{})

def cat(xss: List<&2, List<&2, P.Op>>) -> List<&2, P.Op>:
  List.concat(&2, P.Op, xss)

# the scalar cells after lmean and gnorm: Σ g², the clip scale, then the
# step's learning rate and the bias corrections 1 - b1^t, 1 - b2^t
def cell.gss(+ly: L.Lay) -> U32:
  U32.add(L.Lay.sc(ly), 2)

def cell.clip(+ly: L.Lay) -> U32:
  U32.add(L.Lay.sc(ly), 3)

def cell.lr(+ly: L.Lay) -> U32:
  U32.add(L.Lay.sc(ly), 4)

def cell.c1(+ly: L.Lay) -> U32:
  U32.add(L.Lay.sc(ly), 5)

def cell.c2(+ly: L.Lay) -> U32:
  U32.add(L.Lay.sc(ly), 6)

def nchunks(+m: L.Dm) -> Nat:
  U32.to_nat(U32.div(L.Dm.n(m), L.Dm.r(m)))

def Hd(+m: L.Dm, +ly: L.Lay) -> L.Hd:
  L.Hd.at(m, L.Lay.hd(ly))

# Forward ------------------------------------------------------------------

def fwd(+m: L.Dm, +ly: L.Lay) -> List<&2, P.Op>:
  +hd = Hd(m, ly)
  cat([M.embed(m, ly), cat(M.layers(L.Lay.blocks(ly), m, ly, 0)), M.head.fin(m, ly, hd),
       cat(M.head.chunks(nchunks(m), m, ly, hd, 0)), M.head.loss(m, ly, hd)])

# evaluate: the forward and each window's summed loss
def eval(+m: L.Dm, +ly: L.Lay) -> List<&2, P.Op>:
  List.append(&2, P.Op, fwd(m, ly), M.head.windows(m, Hd(m, ly)))

# Backward -----------------------------------------------------------------

def tz(+ly: L.Lay, +lo: U32, +hi: U32) -> P.Op:
  P.zero(U32.sub(hi, lo), U32.add(lo, L.Lay.g(ly)))

# one head chunk's transpose: recompute (unless its values are live), zero
# the chunk's tangents, transpose
def bwd.chunks(cs: List<&2, List<&2, P.Op>>, +ly: L.Lay, +hd: L.Hd, live: Bool) -> List<&2, P.Op>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      cat([Bool.pick(List<&2, P.Op>, live, Nil{}, c), [tz(ly, L.Hd.lg(hd), L.Hd.loss(hd))],
           P.back(L.Lay.g(ly), c, Nil{}), bwd.chunks(t, ly, hd, False{})])

def bwd.layers(ls: List<&2, List<&2, P.Op>>, +ly: L.Lay, live: Bool) -> List<&2, P.Op>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      cat([Bool.pick(List<&2, P.Op>, live, Nil{}, l), [tz(ly, L.Lay.ws(ly), L.Lay.hd(ly))],
           P.back(L.Lay.g(ly), l, Nil{}), bwd.layers(t, ly, False{})])

# the backward of a micro-batch whose loss carries weight `seed` (1/k for
# k micro-batches a step): the parameters' tangents accumulate
def bwd(+m: L.Dm, +ly: L.Lay, +seed: F32) -> List<&2, P.Op>:
  +hd = Hd(m, ly)
  +g = L.Lay.g(ly)
  cat([[tz(ly, L.Lay.x0(ly), U32.add(L.Lay.sc(ly), 16)), P.fill(1, U32.add(L.Lay.lmean(ly), g), seed)],
       P.back(g, M.head.loss(m, ly, hd), Nil{}),
       bwd.chunks(List.reverse(&2, List<&2, P.Op>, M.head.chunks(nchunks(m), m, ly, hd, 0)), ly, hd, True{}),
       P.back(g, M.head.fin(m, ly, hd), Nil{}),
       bwd.layers(List.reverse(&2, List<&2, P.Op>, M.layers(L.Lay.blocks(ly), m, ly, 0)), ly, True{}),
       P.back(g, M.embed(m, ly), Nil{})])

# the parameters' tangents to zero (a step's start)
def zero.grads(+ly: L.Lay) -> List<&2, P.Op>:
  [tz(ly, 0, L.Lay.params(ly))]

# Clip ----------------------------------------------------------------------

# gnorm = sqrt(Σ g²); clip = clip.scale(gnorm, max) (Train/Opt.bend: a
# non-finite norm scales to 0)
def clip(+ly: L.Lay, +max: F32) -> List<&2, P.Op>:
  # Σ g² in two levels (1024-wide partial sums, then theirs) over the
  # tangents up to the 2 MB boundary (zeros past the parameters)
  +rows = U32.div(L.align(L.Lay.params(ly)), 1024)
  +part = L.Lay.ws(ly)
  [P.ein(Es{[rows, 1024], 2, 0, 0, v(part, [1, 0]), [v(L.Lay.g(ly), [1024, 1])], X.mul(X.x(0), X.x(0))}, False{}),
   P.ein(Es{[rows], 1, 0, 0, v(cell.gss(ly), [0]), [v(part, [1])], X.x(0)}, False{}),
   P.map1(1, L.Lay.gnorm(ly), [cell.gss(ly)], X.sqrt(X.x(0)), False{}),
   P.map1(1, cell.clip(ly), [L.Lay.gnorm(ly)],
     X.sel(X.eq(X.x(0), X.x(0)),
       X.sel(X.lt(X.k(max), X.x(0)), X.div(X.k(max), X.add(X.x(0), X.k(1.0e-12))), X.k(1.0)), X.k(0.0)), False{})]

# AdamW ----------------------------------------------------------------------

type Hy is Data:
  Hy{b1: F32, b2: F32, eps: F32, wd: F32, mu: F32}

def Hy.b1(+h: Hy) -> F32:
  match h:
    case Hy{a, b, c, d, e}:
      a

def Hy.b2(+h: Hy) -> F32:
  match h:
    case Hy{a, b, c, d, e}:
      b

def Hy.eps(+h: Hy) -> F32:
  match h:
    case Hy{a, b, c, d, e}:
      c

def Hy.wd(+h: Hy) -> F32:
  match h:
    case Hy{a, b, c, d, e}:
      d

def Hy.mu(+h: Hy) -> F32:
  match h:
    case Hy{a, b, c, d, e}:
      e

def bcast(+c: U32) -> View:
  v(c, [0])

# m, v, p of the n parameters at off, in place (Train/Opt.bend adam.one on
# the clipped gradient s·g)
def adam(+ly: L.Lay, +h: Hy, +off: U32, +n: U32, decay: Bool) -> List<&2, P.Op>:
  +p = v(off, [1])
  +gv = v(U32.add(off, L.Lay.g(ly)), [1])
  +mv = v(U32.add(off, L.Lay.m(ly)), [1])
  +vv = v(U32.add(off, L.Lay.v(ly)), [1])
  +gs = X.mul(X.x(2), X.x(1))
  +b1 = Hy.b1(h)
  +b2 = Hy.b2(h)
  [P.ein(Es{[n], 0, 0, 0, mv, [mv, gv, bcast(cell.clip(ly))],
     X.add(X.mul(X.k(b1), X.x(0)), X.mul(X.k(F32.sub(1.0, b1)), gs))}, False{}),
   P.ein(Es{[n], 0, 0, 0, vv, [vv, gv, bcast(cell.clip(ly))],
     X.add(X.mul(X.k(b2), X.x(0)), X.mul(X.mul(X.k(F32.sub(1.0, b2)), gs), gs))}, False{}),
   P.ein(Es{[n], 0, 0, 0, p, [p, mv, vv, bcast(cell.lr(ly)), bcast(cell.c1(ly)), bcast(cell.c2(ly))],
     X.sub(X.x(0), X.mul(X.x(3), X.add(X.div(X.div(X.x(1), X.x(4)), X.add(X.sqrt(X.div(X.x(2), X.x(5))), X.k(Hy.eps(h)))),
       Bool.pick(Ex, decay, X.mul(X.k(Hy.wd(h)), X.x(0)), X.k(0.0)))))}, False{})]

# Muon -----------------------------------------------------------------------
#
# momentum' = mu·momentum + s·g; X = NS5(s·g + mu·momentum'), each iteration
# X <- 3.4445 X + P X with P = -4.775 A + 2.0315 A A, A = X X^T (rows <=
# cols; otherwise X <- 3.4445 X + X P, A = X^T X); the update is
# 0.2 sqrt(max(r, c)) X plus decoupled decay. Scratch lives in the layer
# workspace (free once the backward is done).

type Sc is Data:
  Sc{x: U32, a: U32, aa: U32, pp: U32, px: U32, nx: U32}

def Sc.x(+s: Sc) -> U32:
  match s:
    case Sc{a, b, c, d, e, f}:
      a

def Sc.a(+s: Sc) -> U32:
  match s:
    case Sc{a, b, c, d, e, f}:
      b

def Sc.aa(+s: Sc) -> U32:
  match s:
    case Sc{a, b, c, d, e, f}:
      c

def Sc.pp(+s: Sc) -> U32:
  match s:
    case Sc{a, b, c, d, e, f}:
      d

def Sc.px(+s: Sc) -> U32:
  match s:
    case Sc{a, b, c, d, e, f}:
      e

def Sc.nx(+s: Sc) -> U32:
  match s:
    case Sc{a, b, c, d, e, f}:
      f

def Sc.at(+ly: L.Lay, +r: U32, +c: U32) -> Sc:
  +k = U32.min(r, c)
  +x = L.Lay.ws(ly)
  +a = U32.add(x, U32.mul(r, c))
  +aa = U32.add(a, U32.mul(k, k))
  +pp = U32.add(aa, U32.mul(k, k))
  +px = U32.add(pp, U32.mul(k, k))
  Sc{x, a, aa, pp, px, U32.add(px, U32.mul(r, c))}

# one NS iteration on X [r × c], k = min(r, c)
def ns.pick(wide: Bool, +s: Sc, +r: U32, +c: U32, +x: U32, ap: List<&2, P.Op>, upd: List<&2, P.Op>) -> List<&2, P.Op>:
  match wide:
    case True{}:
      cat([[P.Mm{0, 1, r, r, c, 1, 1.0, x, c, 0, x, c, 0, 0.0, Sc.a(s), r, 0},
            P.Mm{0, 1, r, r, r, 1, 1.0, Sc.a(s), r, 0, Sc.a(s), r, 0, 0.0, Sc.aa(s), r, 0}], ap,
           [P.Mm{0, 0, r, c, r, 1, 1.0, Sc.pp(s), r, 0, x, c, 0, 0.0, Sc.px(s), c, 0}], upd])
    case False{}:
      cat([[P.Mm{1, 0, c, c, r, 1, 1.0, x, c, 0, x, c, 0, 0.0, Sc.a(s), c, 0},
            P.Mm{0, 1, c, c, c, 1, 1.0, Sc.a(s), c, 0, Sc.a(s), c, 0, 0.0, Sc.aa(s), c, 0}], ap,
           [P.Mm{0, 0, r, c, c, 1, 1.0, x, c, 0, Sc.pp(s), c, 0, 0.0, Sc.px(s), c, 0}], upd])

def ns.step(+wide: Bool, +s: Sc, +r: U32, +c: U32) -> List<&2, P.Op>:
  +k = U32.min(r, c)
  +x = Sc.x(s)
  ns.pick(wide, s, r, c, x,
    [P.map1(U32.mul(k, k), Sc.pp(s), [Sc.a(s), Sc.aa(s)],
       X.add(X.mul(X.k(F32.neg(4.775)), X.x(0)), X.mul(X.k(2.0315), X.x(1))), False{})],
    [P.map1(U32.mul(r, c), x, [x, Sc.px(s)], X.add(X.mul(X.k(3.4445), X.x(0)), X.x(1)), False{})])

def ns.iter(n: Nat, +wide: Bool, +s: Sc, +r: U32, +c: U32) -> List<&2, P.Op>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      List.append(&2, P.Op, ns.step(wide, s, r, c), ns.iter(p, wide, s, r, c))

def muon(+ly: L.Lay, +h: Hy, +off: U32, +r: U32, +c: U32) -> List<&2, P.Op>:
  +n = U32.mul(r, c)
  +s = Sc.at(ly, r, c)
  +p = v(off, [1])
  +gv = v(U32.add(off, L.Lay.g(ly)), [1])
  +mv = v(U32.add(off, L.Lay.m(ly)), [1])
  +mu = Hy.mu(h)
  +gs = X.mul(X.x(2), X.x(1))
  +sc = F32.mul(0.2, F32.sqrt(U32.to_f32(U32.max(r, c))))
  cat([[P.ein(Es{[n], 0, 0, 0, mv, [mv, gv, bcast(cell.clip(ly))], X.add(X.mul(X.k(mu), X.x(0)), gs)}, False{}),
        P.ein(Es{[n], 0, 0, 0, v(Sc.x(s), [1]), [mv, gv, bcast(cell.clip(ly))], X.add(gs, X.mul(X.k(mu), X.x(0)))}, False{}),
        P.ein(Es{[n], 1, 0, 0, v(Sc.nx(s), [0]), [v(Sc.x(s), [1])], X.mul(X.x(0), X.x(0))}, False{}),
        P.ein(Es{[n], 0, 0, 0, v(Sc.x(s), [1]), [v(Sc.x(s), [1]), bcast(Sc.nx(s))],
          X.mul(X.div(X.k(1.0), X.add(X.sqrt(X.x(1)), X.k(1.0e-7))), X.x(0))}, False{})],
       ns.iter(5n, U32.is_le(r, c), s, r, c),
       [P.ein(Es{[n], 0, 0, 0, p, [p, v(Sc.x(s), [1]), bcast(cell.lr(ly))],
          X.add(X.x(0), X.mul(X.neg(X.x(2)), X.add(X.mul(X.k(sc), X.x(1)), X.mul(X.k(Hy.wd(h)), X.x(0)))))}, False{})]])

# The whole update ---------------------------------------------------------

def mat(mu: Bool, +ly: L.Lay, +h: Hy, +off: U32, +r: U32, +c: U32) -> List<&2, P.Op>:
  match mu:
    case True{}:
      muon(ly, h, off, r, c)
    case False{}:
      adam(ly, h, off, U32.mul(r, c), True{})

def blk.gla(+mu: Bool, +ly: L.Lay, +h: Hy, +m: L.Dm, +bp: L.BP) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  +ff = L.Dm.f(m)
  cat([adam(ly, h, L.BP.ra(bp), d, False{}),
       mat(mu, ly, h, L.BP.wq(bp), d, d), mat(mu, ly, h, L.BP.wk(bp), d, d), mat(mu, ly, h, L.BP.wv(bp), d, d),
       mat(mu, ly, h, L.BP.wo(bp), d, d), mat(mu, ly, h, L.BP.wa(bp), d, d),
       Bool.pick(List<&2, P.Op>, L.Dm.rglru(m), adam(ly, h, L.BP.lam(bp), d, False{}), Nil{}),
       adam(ly, h, L.BP.rf(bp), d, False{}),
       mat(mu, ly, h, L.BP.wg(bp), ff, d), mat(mu, ly, h, L.BP.wu(bp), ff, d), mat(mu, ly, h, L.BP.wd(bp), d, ff)])

def blk.sm(+mu: Bool, +ly: L.Lay, +h: Hy, +m: L.Dm, +bp: L.BP) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  +ff = L.Dm.f(m)
  +q = L.Dm.qk(m)
  cat([adam(ly, h, L.BP.ra(bp), d, False{}),
       mat(mu, ly, h, L.BP.wq(bp), d, d), mat(mu, ly, h, L.BP.wk(bp), d, d), mat(mu, ly, h, L.BP.wv(bp), d, d),
       mat(mu, ly, h, L.BP.wo(bp), d, d),
       Bool.pick(List<&2, P.Op>, q, adam(ly, h, L.BP.gq(bp), L.Dm.hd(m), True{}), Nil{}),
       Bool.pick(List<&2, P.Op>, q, adam(ly, h, L.BP.gk(bp), L.Dm.hd(m), True{}), Nil{}),
       Bool.pick(List<&2, P.Op>, L.Dm.sinks(m), adam(ly, h, L.BP.sink(bp), L.Dm.h(m), False{}), Nil{}),
       adam(ly, h, L.BP.rf(bp), d, False{}),
       mat(mu, ly, h, L.BP.wg(bp), ff, d), mat(mu, ly, h, L.BP.wu(bp), ff, d), mat(mu, ly, h, L.BP.wd(bp), d, ff)])

def blk(+mu: Bool, +ly: L.Lay, +h: Hy, +m: L.Dm, +bp: L.BP) -> List<&2, P.Op>:
  Bool.pick(List<&2, P.Op>, L.BP.gla(bp), blk.gla(mu, ly, h, m, bp), blk.sm(mu, ly, h, m, bp))

def blks(bs: List<&2, L.BP>, +mu: Bool, +ly: L.Lay, +h: Hy, +m: L.Dm) -> List<&2, P.Op>:
  match bs:
    case Nil{}:
      Nil{}
    case bp <> t:
      List.append(&2, P.Op, blk(mu, ly, h, m, bp), blks(t, mu, ly, h, m))

# clip, then every parameter: the embedding and the vectors by AdamW (the
# embedding decays), the blocks' matrices by Muon or AdamW (Train/Opt.bend)
def update(+mu: Bool, +ly: L.Lay, +h: Hy, +m: L.Dm, +max: F32) -> List<&2, P.Op>:
  cat([clip(ly, max), adam(ly, h, 0, U32.mul(L.Dm.v(m), L.Dm.d(m)), True{}),
       blks(L.Lay.blocks(ly), mu, ly, h, m), adam(ly, h, L.Lay.fin(ly), L.Dm.d(m), False{})])
