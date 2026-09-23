import Base
import ../Tensor.bend as T
import ../Ops.bend as O
import ../Model.bend as Md
import ./Ops.bend as G
# Training: the forward over a window with a tape, and its pullback.
#
# The forward is layer-major (every position through a block, then the
# next block), computing exactly the decode step's expressions, so its loss
# is the decoder's (checked in tests/train.bend).  The backward runs the
# blocks in reverse; inside a GLA block the recurrence runs backward through
# time.  Gradients are carried in the model's own weight records (a Block
# of cotangents has the Block's shape), so the optimizer maps one tree onto
# another.
type TailRec is Data:
  TailRec{xa: T.V, fn: T.V, g: T.V, u: T.V, h: T.V, y: T.V}

def TailRec.xa(+r: TailRec) -> T.V:
  match r:
    case TailRec{f0, f1, f2, f3, f4, f5}:
      f0

def TailRec.fn(+r: TailRec) -> T.V:
  match r:
    case TailRec{f0, f1, f2, f3, f4, f5}:
      f1

def TailRec.g(+r: TailRec) -> T.V:
  match r:
    case TailRec{f0, f1, f2, f3, f4, f5}:
      f2

def TailRec.u(+r: TailRec) -> T.V:
  match r:
    case TailRec{f0, f1, f2, f3, f4, f5}:
      f3

def TailRec.h(+r: TailRec) -> T.V:
  match r:
    case TailRec{f0, f1, f2, f3, f4, f5}:
      f4

def TailRec.y(+r: TailRec) -> T.V:
  match r:
    case TailRec{f0, f1, f2, f3, f4, f5}:
      f5

type GRec is Data:
  GRec{x: T.V, nrm: T.V, q: T.V, k: T.V, v: T.V, z: T.V, qh: T.V, kh0: T.V, alpha: T.V, khat: T.V, sp: Md.HM, sn: Md.HM, o: T.V, tl: TailRec}

def GRec.x(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f0

def GRec.nrm(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f1

def GRec.q(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f2

def GRec.k(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f3

def GRec.v(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f4

def GRec.z(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f5

def GRec.qh(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f6

def GRec.kh0(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f7

def GRec.alpha(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f8

def GRec.khat(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f9

def GRec.sp(+r: GRec) -> Md.HM:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f10

def GRec.sn(+r: GRec) -> Md.HM:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f11

def GRec.o(+r: GRec) -> T.V:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f12

def GRec.tl(+r: GRec) -> TailRec:
  match r:
    case GRec{f0, f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12, f13}:
      f13

type SRec is Data:
  SRec{x: T.V, nrm: T.V, q: T.V, k: T.V, v: T.V, qa: T.V, ka: T.V, o: T.V, tl: TailRec}

def SRec.x(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f0

def SRec.nrm(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f1

def SRec.q(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f2

def SRec.k(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f3

def SRec.v(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f4

def SRec.qa(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f5

def SRec.ka(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f6

def SRec.o(+r: SRec) -> T.V:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f7

def SRec.tl(+r: SRec) -> TailRec:
  match r:
    case SRec{f0, f1, f2, f3, f4, f5, f6, f7, f8}:
      f8

type TailGrad is Data:
  TailGrad{dout: T.V, dx: T.V, dwo: T.M, drf: T.V, dwg: T.M, dwu: T.M, dwd: T.M}

def TailGrad.dout(+r: TailGrad) -> T.V:
  match r:
    case TailGrad{f0, f1, f2, f3, f4, f5, f6}:
      f0

def TailGrad.dx(+r: TailGrad) -> T.V:
  match r:
    case TailGrad{f0, f1, f2, f3, f4, f5, f6}:
      f1

def TailGrad.dwo(+r: TailGrad) -> T.M:
  match r:
    case TailGrad{f0, f1, f2, f3, f4, f5, f6}:
      f2

def TailGrad.drf(+r: TailGrad) -> T.V:
  match r:
    case TailGrad{f0, f1, f2, f3, f4, f5, f6}:
      f3

def TailGrad.dwg(+r: TailGrad) -> T.M:
  match r:
    case TailGrad{f0, f1, f2, f3, f4, f5, f6}:
      f4

def TailGrad.dwu(+r: TailGrad) -> T.M:
  match r:
    case TailGrad{f0, f1, f2, f3, f4, f5, f6}:
      f5

def TailGrad.dwd(+r: TailGrad) -> T.M:
  match r:
    case TailGrad{f0, f1, f2, f3, f4, f5, f6}:
      f6

# Block gradients -----------------------------------------------------------
#
# A block of cotangents is a Md.Block; absent pieces are VZ / MZ (zero).

def Blk.zero(k: Md.LState) -> Md.Block:
  match k:
    case Md.GlaS{s}:
      Md.GlaB{T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.VZ{}, T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}}
    case Md.SmS{a, b}:
      Md.SmB{T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.VZ{}, T.VZ{}, T.VZ{}, T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}}

def Blk.add(+a: Md.Block, +b: Md.Block) -> Md.Block:
  match a b:
    case Md.GlaB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11} Md.GlaB{b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11}:
      Md.GlaB{T.V.add.pad(a1, b1), T.M.add(a2, b2), T.M.add(a3, b3), T.M.add(a4, b4), T.M.add(a5, b5), T.M.add(a6, b6),
              T.V.add.pad(a7, b7), T.V.add.pad(a8, b8), T.M.add(a9, b9), T.M.add(a10, b10), T.M.add(a11, b11)}
    case Md.SmB{a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11, a12} Md.SmB{b1, b2, b3, b4, b5, b6, b7, b8, b9, b10, b11, b12}:
      Md.SmB{T.V.add.pad(a1, b1), T.M.add(a2, b2), T.M.add(a3, b3), T.M.add(a4, b4), T.M.add(a5, b5), T.V.add.pad(a6, b6),
             T.V.add.pad(a7, b7), T.V.add.pad(a8, b8), T.V.add.pad(a9, b9), T.M.add(a10, b10), T.M.add(a11, b11), T.M.add(a12, b12)}
    case _ _:
      a

# The SwiGLU tail --------------------------------------------------------

def tail.fwd(+n: F32, +x: T.V, +att: T.V, +wo: T.M, +rf: T.V, +wg: T.M, +wu: T.M, +wd: T.M) -> TailRec:
  +xa = T.V.add(x, T.M.matvec(wo, att))
  +fn = O.rms_norm(n, xa, rf)
  +g = T.M.matvec(wg, fn)
  +u = T.M.matvec(wu, fn)
  +h = T.V.zip(~O.silu_mul.t, g, u)
  TailRec{xa, fn, g, u, h, T.V.add(xa, T.M.matvec(wd, h))}

def tail.bwd(+n: F32, +att: T.V, +wo: T.M, +rf: T.V, +wg: T.M, +wu: T.M, +wd: T.M, +tr: TailRec, +dy: T.V) -> TailGrad:
  +dh = T.M.vecmat(dy, wd)
  +dg = G.swiglu.dg.v(TailRec.g(tr), TailRec.u(tr), dh)
  +du = G.swiglu.du.v(TailRec.g(tr), dh)
  +dfn = T.V.add.pad(T.M.vecmat(dg, wg), T.M.vecmat(du, wu))
  +rg = G.rms.bwd(n, TailRec.xa(tr), rf, dfn)
  +dxa = T.V.add.pad(dy, G.RmsGrad.dx(rg))
  TailGrad{T.M.vecmat(dxa, wo), dxa, T.M.outer(dxa, att), G.RmsGrad.dg(rg),
           T.M.outer(dg, TailRec.fn(tr)), T.M.outer(du, TailRec.fn(tr)), T.M.outer(dy, TailRec.h(tr))}

# GLA block ----------------------------------------------------------------

def Gate.alpha(+g: Md.Gate) -> T.V:
  match g:
    case Md.Gate{a, k}:
      a

def Gate.khat(+g: Md.Gate) -> T.V:
  match g:
    case Md.Gate{a, k}:
      k

def gla.pos(+dm: Md.Dims, +b: Md.Block, +x: T.V, +s: Md.HM) -> GRec:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      +n = F32.from_nat(Md.Dims.d(dm))
      +k = Md.Dims.k(dm)
      +nrm = O.rms_norm(n, x, ra)
      +q = T.M.matvec(wq, nrm)
      +kv = T.M.matvec(wk, nrm)
      +v = T.M.matvec(wv, nrm)
      +z = T.M.matvec(wa, nrm)
      +qh = O.l2_heads(k, q)
      +kh0 = O.l2_heads(k, kv)
      +gt = Md.gla.gate(Md.Dims.rglru(dm), z, lam, kh0)
      +sn = Md.gla.state(k, s, Gate.alpha(gt), Gate.khat(gt), v)
      +o = Md.gla.out(k, sn, qh)
      GRec{x, nrm, q, kv, v, z, qh, kh0, Gate.alpha(gt), Gate.khat(gt), s, sn, o, tail.fwd(n, x, o, wo, rf, wg, wu, wd)}
    case _:
      GRec{x, x, x, x, x, x, x, x, x, x, s, s, x, TailRec{x, x, x, x, x, x}}

def gla.fwd(xs: List<&2, T.V>, +dm: Md.Dims, +b: Md.Block, +s: Md.HM) -> List<&2, GRec>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> rest:
      +r = gla.pos(dm, b, x, s)
      r <> gla.fwd(rest, dm, b, GRec.sn(r))

# per position after the recurrence pullback
type RGrad is Data:
  RGrad{dqh: T.V, dalpha: T.V, dkhat: T.V, dv: T.V}

# backward through time: records and output cotangents in REVERSE order,
# dS the cotangent of the state the later positions saw
def gla.rec.bwd(rs: List<&2, GRec>, dos: List<&2, T.V>, +k: Nat, +dS: Md.HM) -> List<&2, RGrad>:
  match rs dos:
    case +r <> rrest +d <> drest:
      +dSi = Md.HM.outer_add(k, dS, GRec.qh(r), d)
      RGrad{Md.HM.matvec(k, GRec.sn(r), d), Md.HM.rowdots(k, dSi, GRec.sp(r)), Md.HM.matvec(k, dSi, GRec.v(r)), Md.HM.vecmat(k, GRec.khat(r), dSi)}
        <> gla.rec.bwd(rrest, drest, k, Md.HM.scale_rows(k, GRec.alpha(r), dSi))
    case _ _:
      Nil{}

type PosGrad is Data:
  PosGrad{dx: T.V, blk: Md.Block}

def lam.grad(g: Bool, +d: T.V) -> T.V:
  match g:
    case True{}:
      d
    case False{}:
      T.VZ{}

def gla.gg.dz(+g: G.GateGradV) -> T.V:
  match g:
    case G.GateGradV{a, b, c}:
      a

def gla.gg.dlam(+g: G.GateGradV) -> T.V:
  match g:
    case G.GateGradV{a, b, c}:
      b

def gla.gg.dk(+g: G.GateGradV) -> T.V:
  match g:
    case G.GateGradV{a, b, c}:
      c

# the front of a GLA position: gate, head norms, projections, RMSNorm
def gla.front.bwd(+dm: Md.Dims, +b: Md.Block, +r: GRec, +rg: RGrad, +tg: TailGrad) -> PosGrad:
  match b rg tg:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd} RGrad{+dqh, +dal, +dkh, +dv} TailGrad{dout, dxt, dwo, drf, dwg, dwu, dwd}:
      +n = F32.from_nat(Md.Dims.d(dm))
      +k = Md.Dims.k(dm)
      +gg = G.gate.bwd.v(Md.Dims.rglru(dm), GRec.z(r), lam, GRec.kh0(r), dal, dkh)
      +dz = gla.gg.dz(gg)
      +dq = G.l2.heads.bwd(k, GRec.q(r), dqh)
      +dk = G.l2.heads.bwd(k, GRec.k(r), gla.gg.dk(gg))
      +dnrm = T.V.add.pad(T.V.add.pad(T.M.vecmat(dq, wq), T.M.vecmat(dk, wk)), T.V.add.pad(T.M.vecmat(dv, wv), T.M.vecmat(dz, wa)))
      +rm = G.rms.bwd(n, GRec.x(r), ra, dnrm)
      +nrm = GRec.nrm(r)
      PosGrad{T.V.add.pad(dxt, G.RmsGrad.dx(rm)),
        Md.GlaB{G.RmsGrad.dg(rm), T.M.outer(dq, nrm), T.M.outer(dk, nrm), T.M.outer(dv, nrm), dwo, T.M.outer(dz, nrm),
                lam.grad(Md.Dims.rglru(dm), gla.gg.dlam(gg)), drf, dwg, dwu, dwd}}
    case _ _ _:
      PosGrad{T.VZ{}, b}

# Lists -------------------------------------------------------------------

def rev.go(xs: List<&2, T.V>, acc: List<&2, T.V>) -> List<&2, T.V>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rev.go(t, h <> acc)

def rev(xs: List<&2, T.V>) -> List<&2, T.V>:
  rev.go(xs, Nil{})

def grev.go(xs: List<&2, GRec>, acc: List<&2, GRec>) -> List<&2, GRec>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      grev.go(t, h <> acc)

def rgrev.go(xs: List<&2, RGrad>, acc: List<&2, RGrad>) -> List<&2, RGrad>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      rgrev.go(t, h <> acc)

# elementwise sum of two vector lists; a missing entry is zero
def ladd(xs: List<&2, T.V>, ys: List<&2, T.V>) -> List<&2, T.V>:
  match xs ys:
    case x <> xt y <> yt:
      T.V.add.pad(x, y) <> ladd(xt, yt)
    case Nil{} _:
      ys
    case _ Nil{}:
      xs

type BlockOut is Data:
  BlockOut{dxs: List<&2, T.V>, grad: Md.Block}

def BlockOut.cons(+dx: T.V, +g: Md.Block, r: BlockOut) -> BlockOut:
  match r:
    case BlockOut{dxs, acc}:
      BlockOut{dx <> dxs, Blk.add(g, acc)}

def PosGrad.dx(+p: PosGrad) -> T.V:
  match p:
    case PosGrad{d, b}:
      d

def PosGrad.blk(+p: PosGrad) -> Md.Block:
  match p:
    case PosGrad{d, b}:
      b

# GLA block pullback -------------------------------------------------------

def gla.tail.one(+n: F32, +b: Md.Block, +r: GRec, +dy: T.V) -> TailGrad:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      tail.bwd(n, GRec.o(r), wo, rf, wg, wu, wd, GRec.tl(r), dy)
    case _:
      TailGrad{dy, dy, T.MZ{}, T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}}

def gla.tails(rs: List<&2, GRec>, dys: List<&2, T.V>, +n: F32, +b: Md.Block) -> List<&2, TailGrad>:
  match rs dys:
    case +r <> rt +d <> dt:
      gla.tail.one(n, b, r, d) <> gla.tails(rt, dt, n, b)
    case _ _:
      Nil{}

def douts(ts: List<&2, TailGrad>) -> List<&2, T.V>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> rest:
      TailGrad.dout(t) <> douts(rest)

def gla.fronts(rs: List<&2, GRec>, gs: List<&2, RGrad>, ts: List<&2, TailGrad>, +dm: Md.Dims, +b: Md.Block, +zero: Md.Block) -> BlockOut:
  match rs gs ts:
    case +r <> rt +g <> gt +t <> tt:
      +p = gla.front.bwd(dm, b, r, g, t)
      BlockOut.cons(PosGrad.dx(p), PosGrad.blk(p), gla.fronts(rt, gt, tt, dm, b, zero))
    case _ _ _:
      BlockOut{Nil{}, zero}

def gla.bwd(+dm: Md.Dims, +b: Md.Block, +rs: List<&2, GRec>, +dys: List<&2, T.V>) -> BlockOut:
  +ts = gla.tails(rs, dys, F32.from_nat(Md.Dims.d(dm)), b)
  +rg = rgrev.go(gla.rec.bwd(grev.go(rs, Nil{}), rev(douts(ts)), Md.Dims.k(dm), Md.HZ{}), Nil{})
  gla.fronts(rs, rg, ts, dm, b, Blk.zero(Md.GlaS{Md.HZ{}}))

# Softmax block ------------------------------------------------------------
#
# Causal attention over the window, with per-head sink logits whose weight is
# dropped from the value sum.  Keys and values of the prefix are carried
# most-recent-first; sums over them do not depend on the order.

def att.scores(+k: Nat, +sc: F32, +qa: T.V, ks: List<&2, T.V>) -> List<&2, T.V>:
  match ks:
    case Nil{}:
      Nil{}
    case +kj <> rest:
      T.V.scale(sc, O.heads.red2(~Md.head_dot, k, qa, kj)) <> att.scores(k, sc, qa, rest)

def att.max(ss: List<&2, T.V>) -> T.V:
  match ss:
    case Nil{}:
      T.VZ{}
    case +s <> rest:
      Md.V.maxpad(s, att.max(rest))

def att.exps(+m: T.V, ss: List<&2, T.V>) -> List<&2, T.V>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> rest:
      Md.V.sub_exp(m, s) <> att.exps(m, rest)

def vsum(xs: List<&2, T.V>) -> T.V:
  match xs:
    case Nil{}:
      T.VZ{}
    case +x <> rest:
      T.V.add.pad(x, vsum(rest))

def recip(x: F32) -> F32:
  F32.div(1.0, x)

def att.weights(+inv: T.V, es: List<&2, T.V>) -> List<&2, T.V>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> rest:
      T.V.mul(e, inv) <> att.weights(inv, rest)

def att.mix(+k: Nat, ws: List<&2, T.V>, vs: List<&2, T.V>) -> T.V:
  match ws vs:
    case +w <> wt +v <> vt:
      T.V.add.pad(O.heads.with(~Md.head_scale, k, w, v), att.mix(k, wt, vt))
    case _ _:
      T.VZ{}

type Att is Data:
  Att{ws: List<&2, T.V>, wsink: T.V}

def att.probs(+k: Nat, +sc: F32, +qa: T.V, +ks: List<&2, T.V>, +sink: T.V) -> Att:
  +ss = att.scores(k, sc, qa, ks)
  +m = Md.V.maxpad(att.max(ss), sink)
  +es = att.exps(m, ss)
  +es0 = Md.sm.sink_exp(m, sink)
  +inv = T.V.map(~recip, T.V.add.pad(vsum(es), es0))
  Att{att.weights(inv, es), T.V.mul(es0, inv)}

def Att.ws(+a: Att) -> List<&2, T.V>:
  match a:
    case Att{w, s}:
      w

def Att.wsink(+a: Att) -> T.V:
  match a:
    case Att{w, s}:
      s

def sm.pos(+dm: Md.Dims, +b: Md.Block, +x: T.V, +ks: List<&2, T.V>, +vs: List<&2, T.V>) -> SRec:
  match b:
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sink, rf, wg, wu, wd}:
      +n = F32.from_nat(Md.Dims.d(dm))
      +k = Md.Dims.k(dm)
      +hd = Md.Dims.hd(dm)
      +nrm = O.rms_norm(n, x, ra)
      +q = T.M.matvec(wq, nrm)
      +kv = T.M.matvec(wk, nrm)
      +v = T.M.matvec(wv, nrm)
      +qa = Md.qk.apply(Md.Dims.qk(dm), k, hd, gq, q)
      +ka = Md.qk.apply(Md.Dims.qk(dm), k, hd, gk, kv)
      +o = att.mix(k, Att.ws(att.probs(k, Md.inv_sqrt(hd), qa, ka <> ks, sink)), v <> vs)
      SRec{x, nrm, q, kv, v, qa, ka, o, tail.fwd(n, x, o, wo, rf, wg, wu, wd)}
    case _:
      SRec{x, x, x, x, x, x, x, x, TailRec{x, x, x, x, x, x}}

def sm.fwd(xs: List<&2, T.V>, +dm: Md.Dims, +b: Md.Block, +ks: List<&2, T.V>, +vs: List<&2, T.V>) -> List<&2, SRec>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> rest:
      +r = sm.pos(dm, b, x, ks, vs)
      r <> sm.fwd(rest, dm, b, SRec.ka(r) <> ks, SRec.v(r) <> vs)

# the attention pullback at one position
type AttG is Data:
  AttG{dqa: T.V, dsink: T.V, dks: List<&2, T.V>, dvs: List<&2, T.V>}

def att.dws(+k: Nat, +d: T.V, vs: List<&2, T.V>) -> List<&2, T.V>:
  match vs:
    case Nil{}:
      Nil{}
    case +v <> rest:
      O.heads.red2(~Md.head_dot, k, d, v) <> att.dws(k, d, rest)

def att.dss(ws: List<&2, T.V>, dws: List<&2, T.V>, +c: T.V) -> List<&2, T.V>:
  match ws dws:
    case +w <> wt +dw <> dt:
      T.V.mul(w, T.V.sub(dw, c)) <> att.dss(wt, dt, c)
    case _ _:
      Nil{}

def att.prods(ws: List<&2, T.V>, dws: List<&2, T.V>) -> T.V:
  match ws dws:
    case +w <> wt +dw <> dt:
      T.V.add.pad(T.V.mul(w, dw), att.prods(wt, dt))
    case _ _:
      T.VZ{}

def att.scaled(+k: Nat, +sc: F32, ds: List<&2, T.V>, +x: T.V) -> List<&2, T.V>:
  match ds:
    case Nil{}:
      Nil{}
    case +d <> rest:
      O.heads.with(~Md.head_scale, k, T.V.scale(sc, d), x) <> att.scaled(k, sc, rest, x)

def att.scaled.w(+sc: F32, ds: List<&2, T.V>) -> List<&2, T.V>:
  match ds:
    case Nil{}:
      Nil{}
    case +d <> rest:
      T.V.scale(sc, d) <> att.scaled.w(sc, rest)

def att.bwd(+k: Nat, +sc: F32, +qa: T.V, +ks: List<&2, T.V>, +vs: List<&2, T.V>, +sink: T.V, +d: T.V) -> AttG:
  +a = att.probs(k, sc, qa, ks, sink)
  +ws = Att.ws(a)
  +dws = att.dws(k, d, vs)
  +c = att.prods(ws, dws)
  +ds = att.dss(ws, dws, c)
  AttG{att.mix(k, att.scaled.w(sc, ds), ks), T.V.scale(F32.neg(1.0), T.V.mul(Att.wsink(a), c)),
       att.scaled(k, sc, ds, qa), att.scaled(k, 1.0, ws, d)}

type AttPos is Data:
  AttPos{dqa: T.V, dsink: T.V}

type AttAll is Data:
  AttAll{per: List<&2, AttPos>, dK: List<&2, T.V>, dV: List<&2, T.V>}

def AttAll.cons(+p: AttPos, r: AttAll) -> AttAll:
  match r:
    case AttAll{ps, a, b}:
      AttAll{p <> ps, a, b}

def AttG.dqa(+g: AttG) -> T.V:
  match g:
    case AttG{a, b, c, d}:
      a

def AttG.dsink(+g: AttG) -> T.V:
  match g:
    case AttG{a, b, c, d}:
      b

def AttG.dks(+g: AttG) -> List<&2, T.V>:
  match g:
    case AttG{a, b, c, d}:
      c

def AttG.dvs(+g: AttG) -> List<&2, T.V>:
  match g:
    case AttG{a, b, c, d}:
      d

def sm.att.all(rs: List<&2, SRec>, dos: List<&2, T.V>, +k: Nat, +sc: F32, +sink: T.V,
               +ks: List<&2, T.V>, +vs: List<&2, T.V>, +dK: List<&2, T.V>, +dV: List<&2, T.V>) -> AttAll:
  match rs dos:
    case +r <> rt +d <> dt:
      +ks2 = {SRec.ka(r) <> ks : List<&2, T.V>}
      +vs2 = {SRec.v(r) <> vs : List<&2, T.V>}
      +g = att.bwd(k, sc, SRec.qa(r), ks2, vs2, sink, d)
      AttAll.cons(AttPos{AttG.dqa(g), AttG.dsink(g)},
        sm.att.all(rt, dt, k, sc, sink, ks2, vs2, ladd(dK, rev(AttG.dks(g))), ladd(dV, rev(AttG.dvs(g)))))
    case _ _:
      AttAll{Nil{}, dK, dV}

type QkG is Data:
  QkG{dx: T.V, dg: T.V}

def qk.bwd(on: Bool, +k: Nat, +hd: Nat, +g: T.V, +x: T.V, +dy: T.V) -> QkG:
  match on:
    case True{}:
      +r = G.qk.heads.bwd(k, F32.from_nat(hd), T.V.map(~O.one_plus.t, g), x, dy)
      QkG{G.RmsGrad.dx(r), G.RmsGrad.dg(r)}
    case False{}:
      QkG{dy, T.VZ{}}

def QkG.dx(+g: QkG) -> T.V:
  match g:
    case QkG{a, b}:
      a

def QkG.dg(+g: QkG) -> T.V:
  match g:
    case QkG{a, b}:
      b

def sink.grad(on: Bool, +d: T.V) -> T.V:
  match on:
    case True{}:
      d
    case False{}:
      T.VZ{}

def sm.front.bwd(+dm: Md.Dims, +b: Md.Block, +r: SRec, +ap: AttPos, +dka: T.V, +dv: T.V, +tg: TailGrad) -> PosGrad:
  match b ap tg:
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sink, rf, wg, wu, wd} AttPos{+dqa, +dsink} TailGrad{dout, dxt, dwo, drf, dwg, dwu, dwd}:
      +n = F32.from_nat(Md.Dims.d(dm))
      +k = Md.Dims.k(dm)
      +hd = Md.Dims.hd(dm)
      +qg = qk.bwd(Md.Dims.qk(dm), k, hd, gq, SRec.q(r), dqa)
      +kg = qk.bwd(Md.Dims.qk(dm), k, hd, gk, SRec.k(r), dka)
      +dq = QkG.dx(qg)
      +dk = QkG.dx(kg)
      +dnrm = T.V.add.pad(T.V.add.pad(T.M.vecmat(dq, wq), T.M.vecmat(dk, wk)), T.M.vecmat(dv, wv))
      +rm = G.rms.bwd(n, SRec.x(r), ra, dnrm)
      +nrm = SRec.nrm(r)
      PosGrad{T.V.add.pad(dxt, G.RmsGrad.dx(rm)),
        Md.SmB{G.RmsGrad.dg(rm), T.M.outer(dq, nrm), T.M.outer(dk, nrm), T.M.outer(dv, nrm), dwo, QkG.dg(qg), QkG.dg(kg),
               sink.grad(Md.Dims.sinks(dm), dsink), drf, dwg, dwu, dwd}}
    case _ _ _:
      PosGrad{T.VZ{}, b}

def sm.tail.one(+n: F32, +b: Md.Block, +r: SRec, +dy: T.V) -> TailGrad:
  match b:
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sink, rf, wg, wu, wd}:
      tail.bwd(n, SRec.o(r), wo, rf, wg, wu, wd, SRec.tl(r), dy)
    case _:
      TailGrad{dy, dy, T.MZ{}, T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}}

def sm.tails(rs: List<&2, SRec>, dys: List<&2, T.V>, +n: F32, +b: Md.Block) -> List<&2, TailGrad>:
  match rs dys:
    case +r <> rt +d <> dt:
      sm.tail.one(n, b, r, d) <> sm.tails(rt, dt, n, b)
    case _ _:
      Nil{}

def vhead(+xs: List<&2, T.V>) -> T.V:
  match xs:
    case h <> t:
      h
    case Nil{}:
      T.VZ{}

def vtail(+xs: List<&2, T.V>) -> List<&2, T.V>:
  match xs:
    case h <> t:
      t
    case Nil{}:
      Nil{}

def sm.fronts(rs: List<&2, SRec>, ps: List<&2, AttPos>, +dK: List<&2, T.V>, +dV: List<&2, T.V>, ts: List<&2, TailGrad>,
              +dm: Md.Dims, +b: Md.Block, +zero: Md.Block) -> BlockOut:
  match rs ps ts:
    case +r <> rt +p <> pt +t <> tt:
      +pg = sm.front.bwd(dm, b, r, p, vhead(dK), vhead(dV), t)
      BlockOut.cons(PosGrad.dx(pg), PosGrad.blk(pg), sm.fronts(rt, pt, vtail(dK), vtail(dV), tt, dm, b, zero))
    case _ _ _:
      BlockOut{Nil{}, zero}

def Block.sink(+b: Md.Block) -> T.V:
  match b:
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sink, rf, wg, wu, wd}:
      sink
    case _:
      T.VZ{}

def AttAll.per(+a: AttAll) -> List<&2, AttPos>:
  match a:
    case AttAll{p, k, v}:
      p

def AttAll.dK(+a: AttAll) -> List<&2, T.V>:
  match a:
    case AttAll{p, k, v}:
      k

def AttAll.dV(+a: AttAll) -> List<&2, T.V>:
  match a:
    case AttAll{p, k, v}:
      v

def sm.bwd(+dm: Md.Dims, +b: Md.Block, +rs: List<&2, SRec>, +dys: List<&2, T.V>) -> BlockOut:
  +ts = sm.tails(rs, dys, F32.from_nat(Md.Dims.d(dm)), b)
  +all = sm.att.all(rs, douts(ts), Md.Dims.k(dm), Md.inv_sqrt(Md.Dims.hd(dm)), Block.sink(b), Nil{}, Nil{}, Nil{}, Nil{})
  sm.fronts(rs, AttAll.per(all), AttAll.dK(all), AttAll.dV(all), ts, dm, b, Blk.zero(Md.SmS{T.MZ{}, T.MZ{}}))

# The model ------------------------------------------------------------------

type Tape is Data:
  TG{recs: List<&2, GRec>}
  TS{recs: List<&2, SRec>}

def gys(rs: List<&2, GRec>) -> List<&2, T.V>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      TailRec.y(GRec.tl(r)) <> gys(t)

def sys(rs: List<&2, SRec>) -> List<&2, T.V>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      TailRec.y(SRec.tl(r)) <> sys(t)

def Tape.ys(+t: Tape) -> List<&2, T.V>:
  match t:
    case TG{rs}:
      gys(rs)
    case TS{rs}:
      sys(rs)

def block.fwd(+dm: Md.Dims, +b: Md.Block, +xs: List<&2, T.V>) -> Tape:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      TG{gla.fwd(xs, dm, b, Md.HM.zero(Md.Dims.k(dm), Md.Dims.dhd(dm), Md.Dims.hd(dm), Md.Dims.h(dm)))}
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sink, rf, wg, wu, wd}:
      TS{sm.fwd(xs, dm, b, Nil{}, Nil{})}

type Fwd is Data:
  Fwd{tapes: List<&2, Tape>, top: List<&2, T.V>}

def Fwd.cons(+t: Tape, r: Fwd) -> Fwd:
  match r:
    case Fwd{ts, top}:
      Fwd{t <> ts, top}

def stack.fwd(bs: List<&2, Md.Block>, +dm: Md.Dims, +xs: List<&2, T.V>) -> Fwd:
  match bs:
    case Nil{}:
      Fwd{Nil{}, xs}
    case +b <> rest:
      +t = block.fwd(dm, b, xs)
      Fwd.cons(t, stack.fwd(rest, dm, Tape.ys(t)))

def embed(ts: List<&2, U32>, +dv: Nat, +emb: T.M) -> List<&2, T.V>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> rest:
      T.M.row(dv, emb, t) <> embed(rest, dv, emb)

# Cross-entropy ------------------------------------------------------------

def lse(+l: T.V) -> F32:
  +m = T.V.max(l)
  F32.add(m, F32.log(T.V.sum_exp(m, l)))

def exp.minus(+c: F32, +x: F32) -> F32:
  F32.exp(F32.sub(x, c))

def exp.minus.t(c: F32, x: F32) -> F32:
  exp.minus(c, x)

# the loss at a position and d(loss)/d(logits), scaled by 1/n
type CeOut is Data:
  CeOut{loss: F32, dl: T.V}

def CeOut.loss(+c: CeOut) -> F32:
  match c:
    case CeOut{a, b}:
      a

def CeOut.dl(+c: CeOut) -> T.V:
  match c:
    case CeOut{a, b}:
      b

type Head is Data:
  Head{loss: F32, dxs: List<&2, T.V>, dE: T.M, dfin: T.V}

def Head.cons(+l: F32, +dx: T.V, +de: T.M, +df: T.V, h: Head) -> Head:
  match h:
    case Head{a, b, c, d}:
      Head{F32.add(l, a), dx <> b, T.M.add(de, c), T.V.add.pad(df, d)}

def ce(+dv: Nat, +l: T.V, +target: U32, +inv_n: F32) -> CeOut:
  +z = lse(l)
  +p = T.V.map1(~exp.minus.t, z, l)
  CeOut{F32.sub(z, T.V.at(dv, l, target)), T.V.scale(inv_n, T.V.set(dv, p, target, F32.sub(T.V.at(dv, p, target), 1.0)))}

# the tied head at every position: final RMSNorm, logits, CE, pullbacks
def head.fb(xs: List<&2, T.V>, ts: List<&2, U32>, +dm: Md.Dims, +emb: T.M, +fin: T.V, +inv_n: F32) -> Head:
  match xs ts:
    case +x <> xt +t <> tt:
      +n = F32.from_nat(Md.Dims.d(dm))
      +xf = O.rms_norm(n, x, fin)
      +c = ce(Md.Dims.dv(dm), T.M.matvec(emb, xf), t, inv_n)
      +rg = G.rms.bwd(n, x, fin, T.M.vecmat(CeOut.dl(c), emb))
      Head.cons(CeOut.loss(c), G.RmsGrad.dx(rg), T.M.outer(CeOut.dl(c), xf), G.RmsGrad.dg(rg), head.fb(xt, tt, dm, emb, fin, inv_n))
    case _ _:
      Head{0.0, Nil{}, T.MZ{}, T.VZ{}}

def Head.loss(+h: Head) -> F32:
  match h:
    case Head{a, b, c, d}:
      a

def Fwd.top(+f: Fwd) -> List<&2, T.V>:
  match f:
    case Fwd{t, x}:
      x

# the loss alone (no tape kept)
def loss(+dm: Md.Dims, +w: Md.Weights, +inputs: List<&2, U32>, +targets: List<&2, U32>) -> F32:
  match w:
    case Md.Weights{+emb, +bs, +fin, un}:
      +inv_n = F32.div(1.0, F32.from_nat(List.length(&2, U32, inputs)))
      F32.mul(Head.loss(head.fb(Fwd.top(stack.fwd(bs, dm, embed(inputs, Md.Dims.dv(dm), emb))), targets, dm, emb, fin, inv_n)), inv_n)

# The block stack's pullback: later blocks first, their input cotangents
# become this block's output cotangents.
type Back is Data:
  Back{dxs: List<&2, T.V>, grads: List<&2, Md.Block>}

def Back.push(+g: Md.Block, +dxs: List<&2, T.V>, r: Back) -> Back:
  match r:
    case Back{d, gs}:
      Back{dxs, g <> gs}

def Back.dxs(+r: Back) -> List<&2, T.V>:
  match r:
    case Back{d, g}:
      d

def BlockOut.dxs(+r: BlockOut) -> List<&2, T.V>:
  match r:
    case BlockOut{d, g}:
      d

def BlockOut.grad(+r: BlockOut) -> Md.Block:
  match r:
    case BlockOut{d, g}:
      g

def block.bwd(+dm: Md.Dims, +b: Md.Block, +t: Tape, +dys: List<&2, T.V>) -> BlockOut:
  match t:
    case TG{rs}:
      gla.bwd(dm, b, rs, dys)
    case TS{rs}:
      sm.bwd(dm, b, rs, dys)

def stack.bwd(bs: List<&2, Md.Block>, ts: List<&2, Tape>, +dm: Md.Dims, +dtop: List<&2, T.V>) -> Back:
  match bs ts:
    case +b <> bt +t <> tt:
      +later = stack.bwd(bt, tt, dm, dtop)
      +out = block.bwd(dm, b, t, Back.dxs(later))
      Back.push(BlockOut.grad(out), BlockOut.dxs(out), later)
    case _ _:
      Back{dtop, Nil{}}

def embed.bwd(ts: List<&2, U32>, dxs: List<&2, T.V>, +dv: Nat, +acc: T.M) -> T.M:
  match ts dxs:
    case +t <> tt +d <> dt:
      embed.bwd(tt, dt, dv, T.M.add_row(dv, acc, t, d))
    case _ _:
      acc

# loss and gradient of one window: inputs ts, targets ts shifted by one
type LossGrad is Data:
  LossGrad{loss: F32, grad: Md.Weights}

def Head.dxs(+h: Head) -> List<&2, T.V>:
  match h:
    case Head{a, b, c, d}:
      b

def Head.dE(+h: Head) -> T.M:
  match h:
    case Head{a, b, c, d}:
      c

def Head.dfin(+h: Head) -> T.V:
  match h:
    case Head{a, b, c, d}:
      d

def Fwd.tapes(+f: Fwd) -> List<&2, Tape>:
  match f:
    case Fwd{t, x}:
      t

def Back.grads(+r: Back) -> List<&2, Md.Block>:
  match r:
    case Back{d, g}:
      g

def loss_grad(+dm: Md.Dims, +w: Md.Weights, +inputs: List<&2, U32>, +targets: List<&2, U32>) -> LossGrad:
  match w:
    case Md.Weights{+emb, +bs, +fin, un}:
      +inv_n = F32.div(1.0, F32.from_nat(List.length(&2, U32, inputs)))
      +f = stack.fwd(bs, dm, embed(inputs, Md.Dims.dv(dm), emb))
      +h = head.fb(Fwd.top(f), targets, dm, emb, fin, inv_n)
      +back = stack.bwd(bs, Fwd.tapes(f), dm, Head.dxs(h))
      LossGrad{F32.mul(Head.loss(h), inv_n),
        Md.Weights{embed.bwd(inputs, Back.dxs(back), Md.Dims.dv(dm), Head.dE(h)), Back.grads(back), Head.dfin(h), T.MZ{}}}
