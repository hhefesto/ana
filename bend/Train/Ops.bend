import Base
import ../Tensor.bend as T
import ../Ops.bend as O

# Pullbacks of the model's elementwise and per-head pieces (master:
# backend/futhark/pieces-defs.fut, where most are hand-written too).  Each
# `*.bwd` takes the forward's inputs and the output cotangent and answers the
# input cotangents; parameter cotangents come back through small records.

# RMSNorm ----------------------------------------------------------------
#
# y = x * s * g with s = 1 / sqrt(mean(x^2) + 1e-5).  With a = dy * g:
#   dg = dy * x * s,   dx = s * a - x * (s^3 / n) * sum(a * x)
def rms.scale(+n: F32, +x: T.V) -> F32:
  F32.div(1.0, F32.sqrt(F32.add(F32.div(T.V.sumsq(x), n), 1.0e-5)))

type RmsGrad is Data:
  RmsGrad{dx: T.V, dg: T.V}

def rms.bwd(+n: F32, +x: T.V, +g: T.V, +dy: T.V) -> RmsGrad:
  +s = rms.scale(n, x)
  +a = T.V.mul(dy, g)
  +c = F32.div(F32.mul(F32.mul(F32.mul(s, s), s), T.V.dot(a, x)), n)
  RmsGrad{T.V.sub(T.V.scale(s, a), T.V.scale(c, x)), T.V.scale(s, T.V.mul(dy, x))}

def RmsGrad.dx(r: RmsGrad) -> T.V:
  match r:
    case RmsGrad{x, g}:
      x

def RmsGrad.dg(r: RmsGrad) -> T.V:
  match r:
    case RmsGrad{x, g}:
      g

# Per-head L2 normalization: y = x / N, N = sqrt(1e-6 + sum x^2) per head:
#   dx = (dy - y * sum(y * dy)) / N
def l2.head.bwd(+x: T.V, +dy: T.V) -> T.V:
  +nrm = F32.sqrt(F32.add(1.0e-6, T.V.sumsq(x)))
  +y = T.V.map1(~(n => z => F32.div(z, n)), nrm, x)
  T.V.scale(F32.div(1.0, nrm), T.V.sub(dy, T.V.scale(T.V.dot(y, dy), y)))

def l2.heads.bwd(+k: Nat, +x: T.V, +dy: T.V) -> T.V:
  match k x dy:
    case 0n _ _:
      l2.head.bwd(x, dy)
    case 1n+p T.VN{xl, xr} T.VN{dl, dr}:
      T.VN{l2.heads.bwd(p, xl, dl), l2.heads.bwd(p, xr, dr)}
    case _ _ _:
      T.VZ{}

def qk.heads.bwd.join(a: RmsGrad, b: RmsGrad) -> RmsGrad:
  match a b:
    case RmsGrad{xa, ga} RmsGrad{xb, gb}:
      RmsGrad{T.VN{xa, xb}, T.V.add.pad(ga, gb)}

# Gates ------------------------------------------------------------------
#
# sigmoid gate: alpha = sigmoid(z), dz = dalpha * alpha * (1 - alpha)
#
# RG-LRU: raw = 8 sigmoid(z) logsigmoid(lam), la = min(cap, raw),
# alpha = exp(la), scale = sqrt(1 - exp(2 la)), khat = kh0 * scale:
#   dkh0 = dkhat * scale
#   dla = dalpha * alpha - dkhat * kh0 * exp(2 la) / scale
#   draw = dla when raw < cap, else 0 (min's pullback goes to the chosen side)
#   dz = draw * 8 logsigmoid(lam) sigmoid(z) (1 - sigmoid(z))
#   dlam = draw * 8 sigmoid(z) (1 - sigmoid(lam))

# Per-head RMSNorm with shared gains g = 1 + w (qkNorm): the RMSNorm
# pullback per head, the gain cotangents summed over heads.
def qk.heads.bwd(+k: Nat, +hd: F32, +g: T.V, +x: T.V, +dy: T.V) -> RmsGrad:
  match k x dy:
    case 0n _ _:
      rms.bwd(hd, x, g, dy)
    case 1n+p T.VN{xl, xr} T.VN{dl, dr}:
      qk.heads.bwd.join(qk.heads.bwd(p, hd, g, xl, dl), qk.heads.bwd(p, hd, g, xr, dr))
    case _ _ _:
      RmsGrad{T.VZ{}, T.VZ{}}

type GateGrad is Data:
  GateGrad{dz: F32, dlam: F32, dk: F32}

def pass.if(ok: Bool, +x: F32) -> F32:
  match ok:
    case True{}:
      x
    case False{}:
      0.0

def rglru.bwd(+z: F32, +lam: F32, +kh0: F32, +dalpha: F32, +dkhat: F32) -> GateGrad:
  +sz = O.sigmoid(z)
  +sl = O.sigmoid(lam)
  +ls = O.log_sigmoid(lam)
  +raw = F32.mul(F32.mul(8.0, sz), ls)
  +la = F32.min(O.rglru.cap(), raw)
  +alpha = F32.exp(la)
  +e2 = F32.exp(F32.mul(2.0, la))
  +scale = F32.sqrt(F32.sub(1.0, e2))
  +dla = F32.sub(F32.mul(dalpha, alpha), F32.div(F32.mul(F32.mul(dkhat, kh0), e2), scale))
  +draw = pass.if(F32.is_lt(raw, O.rglru.cap()), dla)
  GateGrad{F32.mul(draw, F32.mul(F32.mul(8.0, ls), F32.mul(sz, F32.sub(1.0, sz)))),
           F32.mul(draw, F32.mul(F32.mul(8.0, sz), F32.sub(1.0, sl))),
           F32.mul(dkhat, scale)}

def sigmoid.bwd(+z: F32, +dalpha: F32, +dkhat: F32) -> GateGrad:
  +a = O.sigmoid(z)
  GateGrad{F32.mul(dalpha, F32.mul(a, F32.sub(1.0, a))), 0.0, dkhat}

def gate.bwd(g: Bool, +z: F32, +lam: F32, +kh0: F32, +dalpha: F32, +dkhat: F32) -> GateGrad:
  match g:
    case True{}:
      rglru.bwd(z, lam, kh0, dalpha, dkhat)
    case False{}:
      sigmoid.bwd(z, dalpha, dkhat)

# the gate pullback over whole vectors, answering (dz, dlam, dkh0)
type GateGradV is Data:
  GateGradV{dz: T.V, dlam: T.V, dk: T.V}

def GateGradV.join(a: GateGradV, b: GateGradV) -> GateGradV:
  match a b:
    case GateGradV{z1, l1, k1} GateGradV{z2, l2, k2}:
      GateGradV{T.VN{z1, z2}, T.VN{l1, l2}, T.VN{k1, k2}}

def GateGradV.leaf(r: GateGrad) -> GateGradV:
  match r:
    case GateGrad{a, b, c}:
      GateGradV{T.VL{a}, T.VL{b}, T.VL{c}}

# lam is VZ when the gate is sigmoid; the zero stands in for it
def lam.at(+lam: T.V) -> F32:
  match lam:
    case T.VL{x}:
      x
    case _:
      0.0

def lam.l(+lam: T.V) -> T.V:
  match lam:
    case T.VN{l, r}:
      l
    case _:
      T.VZ{}

def lam.r(+lam: T.V) -> T.V:
  match lam:
    case T.VN{l, r}:
      r
    case _:
      T.VZ{}

def gate.bwd.v(+g: Bool, +z: T.V, +lam: T.V, +kh0: T.V, +da: T.V, +dk: T.V) -> GateGradV:
  match z kh0 da dk:
    case T.VL{zz} T.VL{kk} T.VL{a} T.VL{b}:
      GateGradV.leaf(gate.bwd(g, zz, lam.at(lam), kk, a, b))
    case T.VN{zl, zr} T.VN{kl, kr} T.VN{al, ar} T.VN{bl, br}:
      GateGradV.join(gate.bwd.v(g, zl, lam.l(lam), kl, al, bl), gate.bwd.v(g, zr, lam.r(lam), kr, ar, br))
    case _ _ _ _:
      GateGradV{T.VZ{}, T.VZ{}, T.VZ{}}

# SwiGLU -----------------------------------------------------------------
#
# h = silu(g) * u, silu'(g) = sigmoid(g) (1 + g (1 - sigmoid(g)))

def silu.d(+g: F32) -> F32:
  +s = O.sigmoid(g)
  F32.mul(s, F32.add(1.0, F32.mul(g, F32.sub(1.0, s))))

def swiglu.dg(+g: F32, +u: F32, +dh: F32) -> F32:
  F32.mul(F32.mul(dh, u), silu.d(g))

def swiglu.du(+g: F32, +dh: F32) -> F32:
  F32.mul(dh, O.silu(g))

def swiglu.dg.v(+g: T.V, +u: T.V, +dh: T.V) -> T.V:
  match g u dh:
    case T.VL{a} T.VL{b} T.VL{c}:
      T.VL{swiglu.dg(a, b, c)}
    case T.VN{gl, gr} T.VN{ul, ur} T.VN{dl, dr}:
      T.VN{swiglu.dg.v(gl, ul, dl), swiglu.dg.v(gr, ur, dr)}
    case _ _ _:
      T.VZ{}

def swiglu.du.v(+g: T.V, +dh: T.V) -> T.V:
  match g dh:
    case T.VL{a} T.VL{c}:
      T.VL{swiglu.du(a, c)}
    case T.VN{gl, gr} T.VN{dl, dr}:
      T.VN{swiglu.du.v(gl, dl), swiglu.du.v(gr, dr)}
    case _ _:
      T.VZ{}
