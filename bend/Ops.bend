import Base
import ./Tensor.bend as T

# The model's scalar and per-head vector operations, each the same
# expression as its model.fut counterpart (backend/futhark/model.fut).

# Scalars -----------------------------------------------------------------

def log1p.if(+u: F32, +w: F32, exact: Bool) -> F32:
  match exact:
    case True{}:
      u
    case False{}:
      F32.div(F32.mul(F32.log(w), u), F32.sub(w, 1.0))

# log(1 + u) without cancellation for small u (Goldberg's trick: the
# rounding error of w = 1 + u cancels against log w / (w - 1)).
def log1p(+u: F32) -> F32:
  +w = F32.add(1.0, u)
  log1p.if(u, w, F32.is_eq(w, 1.0))

# log(sigmoid z) = -softplus(-z), stable for either sign
def log_sigmoid(+z: F32) -> F32:
  F32.neg(F32.add(F32.max(F32.neg(z), 0.0), log1p(F32.exp(F32.neg(F32.abs(z))))))

def sigmoid.if(+z: F32, pos: Bool) -> F32:
  match pos:
    case True{}:
      F32.div(1.0, F32.add(1.0, F32.exp(F32.neg(z))))
    case False{}:
      +e = F32.exp(z)
      F32.div(e, F32.add(1.0, e))

# the branch keeps exp from overflowing on either side (model.fut)
def sigmoid(+z: F32) -> F32:
  sigmoid.if(z, F32.is_ge(z, 0.0))

def silu(+z: F32) -> F32:
  F32.mul(z, sigmoid(z))

# RG-LRU (Griffin): log alpha = min(cap, 8 * sigmoid(z) * log sigmoid(lam)),
# capped below 0 so the write scale sqrt(1 - alpha^2) stays Lipschitz.
def rglru.cap() -> F32:
  F32.neg(1.0e-4)

def rglru_log_gate(+z: F32, +lam: F32) -> F32:
  F32.min(rglru.cap(), F32.mul(F32.mul(8.0, sigmoid(z)), log_sigmoid(lam)))

def rglru_write_scale(+la: F32) -> F32:
  F32.sqrt(F32.sub(1.0, F32.exp(F32.mul(2.0, F32.min(rglru.cap(), la)))))

def silu_mul(+g: F32, +u: F32) -> F32:
  F32.mul(silu(g), u)

def scale_by_write(+l: F32, +k: F32) -> F32:
  F32.mul(k, rglru_write_scale(l))

def one_plus(+w: F32) -> F32:
  F32.add(1.0, w)

# Norms -------------------------------------------------------------------

# rms_norm x gain = x * (1 / sqrt(mean(x^2) + 1e-5)) * gain
def rms_norm(+n: F32, +x: T.V, +gain: T.V) -> T.V:
  +scale = F32.div(1.0, F32.sqrt(F32.add(F32.div(T.V.sumsq(x), n), 1.0e-5)))
  T.V.mul(T.V.scale(scale, x), gain)

# per-head L2 normalization of one head's slice
def l2_head(+x: T.V) -> T.V:
  +norm = F32.sqrt(F32.add(1.0e-6, T.V.sumsq(x)))
  T.V.map1(~(n => z => F32.div(z, n)), norm, x)

# per-head RMSNorm with shared gains g = 1 + w (v3 qkNorm)
def qk_head(+hd: F32, +g: T.V, +x: T.V) -> T.V:
  +scale = F32.div(1.0, F32.sqrt(F32.add(F32.div(T.V.sumsq(x), hd), 1.0e-5)))
  T.V.mul(T.V.scale(scale, x), g)

# Heads -------------------------------------------------------------------
#
# A d-vector is a depth-D tree whose subtrees at level k = D - depth(hd)
# are exactly its heads (head dimension a power of two, so heads align with
# the tree).  These templates descend k levels and act per head.

def heads.map(~f: @+x:T.V -> T.V, +k: Nat, +a: T.V) -> T.V:
  match k a:
    case 0n _:
      f(a)
    case 1n+p T.VN{l, r}:
      x y = heads.map(~f, p, l) heads.map(~f, p, r)
      T.VN{x, y}
    case _ _:
      T.VZ{}

# per-head scalars (a depth-k vector) acting on the heads of a d-vector
def heads.with(~f: @+c:F32 -> @+x:T.V -> T.V, +k: Nat, +s: T.V, +a: T.V) -> T.V:
  match k s a:
    case 0n T.VL{c} _:
      f(c, a)
    case 1n+p T.VN{sl, sr} T.VN{l, r}:
      x y = heads.with(~f, p, sl, l) heads.with(~f, p, sr, r)
      T.VN{x, y}
    case _ _ _:
      T.VZ{}

# a per-head reduction of two d-vectors into a depth-k vector
def heads.red2(~f: @+x:T.V -> @+y:T.V -> F32, +k: Nat, +a: T.V, +b: T.V) -> T.V:
  match k a b:
    case 0n _ _:
      T.VL{f(a, b)}
    case 1n+p T.VN{al, ar} T.VN{bl, br}:
      x y = heads.red2(~f, p, al, bl) heads.red2(~f, p, ar, br)
      T.VN{x, y}
    case _ _ _:
      T.VZ{}

def l2_heads(+k: Nat, +x: T.V) -> T.V:
  heads.map(~l2_head, k, x)

def qk_heads(+k: Nat, +hd: F32, +g: T.V, +x: T.V) -> T.V:
  match k x:
    case 0n _:
      qk_head(hd, g, x)
    case 1n+p T.VN{l, r}:
      a b = qk_heads(p, hd, g, l) qk_heads(p, hd, g, r)
      T.VN{a, b}
    case _ _:
      T.VZ{}

# Affine-signature forms for the elementwise templates (T.V.map, T.V.zip
# take plain F32 -> F32 functions; the defs above reuse their arguments).
def sigmoid.t(z: F32) -> F32:
  sigmoid(z)

def rglru_log_gate.t(z: F32, lam: F32) -> F32:
  rglru_log_gate(z, lam)

def scale_by_write.t(l: F32, k: F32) -> F32:
  scale_by_write(l, k)

def silu_mul.t(g: F32, u: F32) -> F32:
  silu_mul(g, u)

def one_plus.t(w: F32) -> F32:
  one_plus(w)

def max.t(a: F32, b: F32) -> F32:
  F32.max(a, b)
