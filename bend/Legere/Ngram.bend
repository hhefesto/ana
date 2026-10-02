import Base
import ./Semiring.bend as R

# Λ_t, the line model of tag t: a byte 4-gram, Witten-Bell smoothed.  A
# line is scored from its own start (a context of BOS markers, 256), so a
# line's weight under a tag never depends on the line before it: that is
# what makes the emission table of Legere/Spec.bend a function of lines.
#
#   P_t(b | h) = (c(h, b) + T(h) · P_t(b | h')) / (c(h) + T(h))
#
# for the last 3, 2, 1 and 0 bytes h (h' drops h's oldest byte), down to
# 1/256; c(h, b) counts b after h under tag t, c(h) all bytes after h and
# T(h) the distinct ones (Witten and Bell, 1991).  log Λ_t(line) is the sum
# of log P_t over the line's bytes, its newline included.
#
# The counts of every tag share one Array<F32> of 2^26 slots, addressed by
# an FNV-1a hash of (tag, order, context, byte); F32 counts are exact to
# 2^24.  Two keys may share a slot: a collision adds the other key's count,
# so the model is the Witten-Bell estimate over hashed counts (as Bloom-
# style language identifiers are), not over exact ones.

def depth() -> Nat:
  26n

def table() -> Array<F32>:
  Array.new(F32, depth(), 0.0)

# a table of 2^d slots (the hash wraps to any size; tests use small ones)
def table.of(+d: Nat) -> Array<F32>:
  Array.new(F32, d, 0.0)

def bos() -> U32:
  256

def fnv(+h: U32, +x: U32) -> U32:
  U32.mul(U32.xor(h, x), 16777619)

# fold the high bits into the low ones the array index keeps
def mix(+h: U32) -> U32:
  U32.mul(U32.xor(h, U32.div(h, 65536)), 2246822519)

def h0(+t: U32) -> U32:
  fnv(fnv(2166136261, t), 0)

def h1(+t: U32, +c1: U32) -> U32:
  fnv(fnv(fnv(2166136261, t), 1), c1)

def h2(+t: U32, +c1: U32, +c2: U32) -> U32:
  fnv(fnv(fnv(fnv(2166136261, t), 2), c1), c2)

def h3(+t: U32, +c1: U32, +c2: U32, +c3: U32) -> U32:
  fnv(fnv(fnv(fnv(fnv(2166136261, t), 3), c1), c2), c3)

# the slots of a context h: c(h, b), c(h), T(h)
def s.pair(+h: U32, +b: U32) -> U32:
  mix(fnv(h, b))

def s.tot(+h: U32) -> U32:
  mix(fnv(h, 300))

def s.typ(+h: U32) -> U32:
  mix(fnv(h, 301))

# Counting ------------------------------------------------------------------

def inc.fin(r: Array<F32> & F32, +i: U32, +d: F32) -> Array<F32>:
  (a, v) = r
  Array.set(F32, a, i, F32.add(v, d))

def inc(a: Array<F32>, +i: U32, +d: F32) -> Array<F32>:
  inc.fin(Array.get(F32, a, i), i, d)

# b after h once more: c(h, b) and c(h) grow by one, T(h) when b is new
def see.fin(r: Array<F32> & F32, +i: U32, +h: U32) -> Array<F32>:
  (a, +v) = r
  inc(inc(Array.set(F32, a, i, F32.add(v, 1.0)), s.tot(h), 1.0), s.typ(h), Bool.pick(F32, F32.is_eq(v, 0.0), 1.0, 0.0))

def see(a: Array<F32>, +h: U32, +b: U32) -> Array<F32>:
  +i = s.pair(h, b)
  see.fin(Array.get(F32, a, i), i, h)

def see.byte(a: Array<F32>, +t: U32, +c1: U32, +c2: U32, +c3: U32, +b: U32) -> Array<F32>:
  see(see(see(see(a, h0(t), b), h1(t, c1), b), h2(t, c1, c2), b), h3(t, c1, c2, c3), b)

def see.go(xs: List<&2, U32>, a: Array<F32>, +t: U32, +c1: U32, +c2: U32, +c3: U32) -> Array<F32>:
  match xs:
    case Nil{}:
      a
    case +b <> rest:
      see.go(rest, see.byte(a, t, c1, c2, c3, b), t, b, c1, c2)

# count a line under tag t
def see.line(a: Array<F32>, +l: List<&2, U32>, +t: Nat) -> Array<F32>:
  see.go(l, a, U32.from_nat(t), bos(), bos(), bos())

# Scoring -------------------------------------------------------------------

# With exact counts T(h) ≥ 1 wherever c(h) ≥ 1; a hash collision can give
# c(h) a count with T(h) still 0, and P(b | h) would be 0 for every unseen
# b.  T(h) is taken as at least 1 there, which changes no exact count's
# estimate.
def wb(+cb: F32, +ch: F32, +th0: F32, +p: F32) -> F32:
  +th = Bool.pick(F32, F32.is_lt(0.0, ch), F32.max(th0, 1.0), th0)
  +d = F32.add(ch, th)
  Bool.pick(F32, F32.is_eq(d, 0.0), p, F32.div(F32.add(cb, F32.mul(th, p)), d))

def look.k(r: Array<F32> & F32, +cb: F32, +ch: F32, +p: F32) -> Array<F32> & F32:
  (a, +th) = r
  (a, wb(cb, ch, th, p))

def look.j(r: Array<F32> & F32, +k: U32, +cb: F32, +p: F32) -> Array<F32> & F32:
  (a, ch) = r
  look.k(Array.get(F32, a, k), cb, ch, p)

def look.i(r: Array<F32> & F32, +j: U32, +k: U32, +p: F32) -> Array<F32> & F32:
  (a, cb) = r
  look.j(Array.get(F32, a, j), k, cb, p)

# P(b | h) given P(b | h') = p
def look(a: Array<F32>, +h: U32, +b: U32, +p: F32) -> Array<F32> & F32:
  look.i(Array.get(F32, a, s.pair(h, b)), s.tot(h), s.typ(h), p)

def look.up(r: Array<F32> & F32, +h: U32, +b: U32) -> Array<F32> & F32:
  (a, p) = r
  look(a, h, b, p)

def prob(a: Array<F32>, +t: U32, +c1: U32, +c2: U32, +c3: U32, +b: U32) -> Array<F32> & F32:
  look.up(look.up(look.up(look(a, h0(t), b, 0.00390625), h1(t, c1), b), h2(t, c1, c2), b), h3(t, c1, c2, c3), b)

def ll.acc(q: Array<F32> & F32, +s: F32) -> Array<F32> & F32:
  (a, p) = q
  (a, F32.add(s, F32.log(p)))

def ll.step(r: Array<F32> & F32, +t: U32, +c1: U32, +c2: U32, +c3: U32, +b: U32) -> Array<F32> & F32:
  (a, s) = r
  ll.acc(prob(a, t, c1, c2, c3, b), s)

def ll.go(xs: List<&2, U32>, r: Array<F32> & F32, +t: U32, +c1: U32, +c2: U32, +c3: U32) -> Array<F32> & F32:
  match xs:
    case Nil{}:
      r
    case +b <> rest:
      ll.go(rest, ll.step(r, t, c1, c2, c3, b), t, b, c1, c2)

# log Λ_t(l)
def ll(a: Array<F32>, +l: List<&2, U32>, +t: Nat) -> Array<F32> & F32:
  ll.go(l, (a, 0.0), U32.from_nat(t), bos(), bos(), bos())

def row.cons(q: Array<F32> & F32, acc: List<&2, F32>) -> Array<F32> & List<&2, F32>:
  (a, s) = q
  (a, s <> acc)

def row.add(r: Array<F32> & List<&2, F32>, +l: List<&2, U32>, +t: Nat) -> Array<F32> & List<&2, F32>:
  (a, acc) = r
  row.cons(ll(a, l, t), acc)

def row.go(ts: List<&2, Nat>, +l: List<&2, U32>, r: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, F32>:
  match ts:
    case Nil{}:
      r
    case +t <> rest:
      row.go(rest, l, row.add(r, l, t))

# log Λ_t(l) for the scored tags 0..n-1, NEWEST FIRST (tag n-1 at the head)
def row.rev(a: Array<F32>, +l: List<&2, U32>, +n: Nat) -> Array<F32> & List<&2, F32>:
  row.go(List.range(n), l, (a, Nil{}))
