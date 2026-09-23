import Base
import ./Num.bend as N
import ./Tensor.bend as T

# Observation of the next-token law (master: backend/gpu/Main.hs pickToken).
#
# TEMPERATURE = 0 is the greedy observation, argmax with the lowest index
# winning ties.  Otherwise the logits are exponentiated at the temperature
# (peak subtracted, so the largest weight is exactly 1), restricted to the
# top-K and then to the top-p nucleus, and one index is drawn by inverse
# CDF.  The nucleus is the least mass-sorted prefix reaching p of the
# total; it is found here as a weight threshold by bisection instead of a
# sort, and the draw walks index order rather than mass order -- the same
# distribution (Language/Decoding's nucleus), a different enumeration.

type Best is Data:
  Best{v: F32, i: U32}

def Best.pick.if(later: Bool, x: F32, i: U32, y: F32, j: U32) -> Best:
  match later:
    case True{}:
      Best{y, j}
    case False{}:
      Best{x, i}

def Best.pick(a: Best, b: Best) -> Best:
  match a b:
    case Best{+x, i} Best{+y, j}:
      Best.pick.if(F32.is_gt(y, x), x, i, y, j)

def Best.i(b: Best) -> U32:
  match b:
    case Best{v, i}:
      i

def argmax.go(+d: Nat, +a: T.V, +base: U32) -> Best:
  match d a:
    case _ T.VL{x}:
      Best{x, base}
    case 1n+p T.VN{l, r}:
      x y = argmax.go(p, l, base) argmax.go(p, r, U32.add(base, U32.shln(1, p)))
      Best.pick(x, y)
    case _ _:
      Best{F32.neg(3.0e38), 0}

def argmax(+d: Nat, +a: T.V) -> U32:
  Best.i(argmax.go(d, a, 0))

# xoshiro256** ------------------------------------------------------------

type Rng is Data:
  Rng{s0: N.U64, s1: N.U64, s2: N.U64, s3: N.U64}

type Draw is Data:
  Draw{w: N.U64, rng: Rng}

def Rng.next(r: Rng) -> Draw:
  match r:
    case Rng{+s0, +s1, +s2, +s3}:
      +t = N.U64.shl(s1, 17n)
      +w = N.U64.mul(N.U64.rotl(N.U64.mul(s1, N.U64.of(5)), 7n), N.U64.of(9))
      +a = N.U64.xor(N.U64.xor(s0, s3), N.U64.xor(s1, s2))
      +b = N.U64.xor(s1, s2)
      +c = N.U64.xor(N.U64.xor(s2, s0), t)
      +e = N.U64.rotl(N.U64.xor(s3, s1), 45n)
      Draw{w, Rng{a, b, c, e}}

# SplitMix64 expansion of a seed (seededPRNG)
type Mix is Data:
  Mix{z: N.U64, s: N.U64}

def splitmix(+s: N.U64) -> Mix:
  +s2 = N.U64.add(s, N.U64{2654435769, 2135587861})
  +z1 = N.U64.mul(N.U64.xor(s2, N.U64.shr(s2, 30n)), N.U64{3210233709, 484763065})
  +z2 = N.U64.mul(N.U64.xor(z1, N.U64.shr(z1, 27n)), N.U64{2496678331, 321982955})
  Mix{N.U64.xor(z2, N.U64.shr(z2, 31n)), s2}

def Mix.z(m: Mix) -> N.U64:
  match m:
    case Mix{z, s}:
      z

def Mix.s(m: Mix) -> N.U64:
  match m:
    case Mix{z, s}:
      s

def Rng.seeded(+seed: N.U64) -> Rng:
  +m1 = splitmix(seed)
  +m2 = splitmix(Mix.s(m1))
  +m3 = splitmix(Mix.s(m2))
  +m4 = splitmix(Mix.s(m3))
  Rng{Mix.z(m1), Mix.z(m2), Mix.z(m3), Mix.z(m4)}

# Sampling ----------------------------------------------------------------

def gt.w.if(keep: Bool, +x: F32) -> F32:
  match keep:
    case True{}:
      x
    case False{}:
      0.0

def gt.w(+t: F32, +x: F32) -> F32:
  gt.w.if(F32.is_ge(x, t), x)

def count.ge(+t: F32, +x: F32) -> F32:
  gt.w.if(F32.is_ge(x, t), 1.0)

# mass of the components at or above t
def gt.w.t(t: F32, x: F32) -> F32:
  gt.w(t, x)

def mass.ge(+t: F32, +a: T.V) -> F32:
  T.V.sum(T.V.map1(~gt.w.t, t, a))

def count.ge.t(t: F32, x: F32) -> F32:
  count.ge(t, x)

def count.ge.v(+t: F32, +a: T.V) -> F32:
  T.V.sum(T.V.map1(~count.ge.t, t, a))

def avg(+a: F32, +b: F32) -> F32:
  F32.mul(0.5, F32.add(a, b))

# the largest threshold in [lo, hi] whose kept mass still reaches `need`
type Bracket is Data:
  Bracket{lo: F32, hi: F32}

def bisect.pick(up: Bool, lo: F32, mid: F32, hi: F32) -> Bracket:
  match up:
    case True{}:
      Bracket{mid, hi}
    case False{}:
      Bracket{lo, mid}

def bisect.mass(n: Nat, +need: F32, +a: T.V, b: Bracket) -> F32:
  match n b:
    case 0n Bracket{lo, hi}:
      lo
    case 1n+p Bracket{+lo, +hi}:
      +mid = avg(lo, hi)
      bisect.mass(p, need, a, bisect.pick(F32.is_ge(mass.ge(mid, a), need), lo, mid, hi))

def bisect.count(n: Nat, +need: F32, +a: T.V, b: Bracket) -> F32:
  match n b:
    case 0n Bracket{lo, hi}:
      lo
    case 1n+p Bracket{+lo, +hi}:
      +mid = avg(lo, hi)
      bisect.count(p, need, a, bisect.pick(F32.is_ge(count.ge.v(mid, a), need), lo, mid, hi))

def V.pick(l: T.V, r: T.V, left: Bool) -> T.V:
  match left:
    case True{}:
      l
    case False{}:
      r

def F32.sel(b: Bool, x: F32, y: F32) -> F32:
  match b:
    case True{}:
      x
    case False{}:
      y

def U32.sel(b: Bool, x: U32, y: U32) -> U32:
  match b:
    case True{}:
      x
    case False{}:
      y

# inverse CDF over index order: the first index whose running mass
# exceeds u (the last present one when rounding leaves u past the total)
def draw.go(+d: Nat, +a: T.V, +u: F32, +base: U32) -> U32:
  match d a:
    case _ T.VL{x}:
      base
    case 1n+p T.VN{+l, +r}:
      +ml = T.V.sum(l)
      +left = Bool.or(F32.is_lt(u, ml), T.V.is_z(r))
      draw.go(p, V.pick(l, r, left), F32.sel(left, u, F32.sub(u, ml)), U32.sel(left, base, U32.add(base, U32.shln(1, p))))
    case _ _:
      base

def exp.t(+peak: F32, +temp: F32, +x: F32) -> F32:
  F32.exp(F32.div(F32.sub(x, peak), temp))

def exp.at(+peak: F32, +temp: F32, +a: T.V) -> T.V:
  match a:
    case T.VL{x}:
      T.VL{exp.t(peak, temp, x)}
    case T.VN{l, r}:
      p q = exp.at(peak, temp, l) exp.at(peak, temp, r)
      T.VN{p, q}
    case T.VZ{}:
      T.VZ{}

type Pick is Data:
  Pick{token: U32, rng: Rng}

def pick.draw(+d: Nat, +w: T.V, dr: Draw) -> Pick:
  match dr:
    case Draw{wd, r}:
      Pick{draw.go(d, w, F32.mul(N.U64.unit(wd), T.V.sum(w)), 0), r}

# below the threshold a logit is sent to a weight of exactly 0
def floor.if(keep: Bool, x: F32) -> F32:
  match keep:
    case True{}:
      x
    case False{}:
      F32.neg(3.0e38)

def floor.go(+t: F32, +x: F32) -> F32:
  floor.if(F32.is_ge(x, t), x)

def floor.t(t: F32, x: F32) -> F32:
  floor.go(t, x)

# The weights after top-K (a logit threshold keeping at least K entries)
# and top-p (a weight threshold keeping at least p of the mass).
def sample.topk(on: Bool, +topk: Nat, +peak: F32, +logits: T.V) -> T.V:
  match on:
    case True{}:
      +t = bisect.count(40n, F32.from_nat(topk), logits, Bracket{F32.sub(peak, 100.0), peak})
      T.V.map1(~floor.t, t, logits)
    case False{}:
      logits

def sample.topp(on: Bool, +topp: F32, +w: T.V) -> T.V:
  match on:
    case True{}:
      +t = bisect.mass(40n, F32.mul(topp, T.V.sum(w)), w, Bracket{0.0, 1.0})
      T.V.map1(~gt.w.t, t, w)
    case False{}:
      w

def sample.weights(+temp: F32, +topk: Nat, +topp: F32, +vocab: Nat, +logits: T.V) -> T.V:
  +peak = T.V.max(logits)
  +kept = sample.topk(Nat.is_lt(topk, vocab), topk, peak, logits)
  +w = exp.at(peak, temp, kept)
  sample.topp(F32.is_lt(topp, 1.0), topp, w)

def pick.if(greedy: Bool, +d: Nat, +temp: F32, +topk: Nat, +topp: F32, +vocab: Nat, +logits: T.V, r: Rng) -> Pick:
  match greedy:
    case True{}:
      Pick{argmax(d, logits), r}
    case False{}:
      pick.draw(d, sample.weights(temp, topk, topp, vocab, logits), Rng.next(r))

def pick(+d: Nat, +temp: F32, +topk: Nat, +topp: F32, +vocab: Nat, +logits: T.V, r: Rng) -> Pick:
  pick.if(F32.is_le(temp, 0.0), d, temp, topk, topp, vocab, logits, r)
