import Base

# Numeric substrate.  Bend2 has U32, F32 and Nat only; the host's 64-bit
# words (the xoshiro256** sampler state, SplitMix64 seeding, Data.Binary
# Int64 fields) are pairs of U32 limbs, most significant first.

type U64 is Data:
  U64{hi: U32, lo: U32}

# The two U32 fields of an F32 and a U32 are the same 32-bit word, so a
# reinterpretation is a constructor swap: the checkpoint's big-endian f32
# payload decodes to exactly the bits Data.Binary.getFloatbe produced.
def F32.from_bits(u: U32) -> F32:
  match u:
    case U32{w}:
      F32{w}

def b2u(b: Bool) -> U32:
  match b:
    case False{}:
      0
    case True{}:
      1

# a big-endian word from four bytes
def be32(a: U32, b: U32, c: U32, d: U32) -> U32:
  U32.or(U32.or(U32.mul(a, 16777216), U32.mul(b, 65536)),
         U32.or(U32.mul(c, 256), d))

def U64.zero() -> U64:
  U64{0, 0}

def U64.of(x: U32) -> U64:
  U64{0, x}

def U64.xor(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, al} U64{bh, bl}:
      U64{U32.xor(ah, bh), U32.xor(al, bl)}

def U64.add(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, al} U64{bh, +bl}:
      +lo = U32.add(al, bl)
      U64{U32.add(U32.add(ah, bh), b2u(U32.is_lt(lo, bl))), lo}

# The full 64-bit product of two U32 words, by 16-bit halves.
def U32.mul_wide(+a: U32, +b: U32) -> U64:
  +al = U32.and(a, 65535)
  +ah = U32.shrn(a, 16n)
  +bl = U32.and(b, 65535)
  +bh = U32.shrn(b, 16n)
  +ll = U32.mul(al, bl)
  +lh = U32.mul(al, bh)
  +hl = U32.mul(ah, bl)
  hh = U32.mul(ah, bh)
  +mid = U32.add(U32.add(U32.shrn(ll, 16n), U32.and(lh, 65535)), U32.and(hl, 65535))
  lo = U32.or(U32.and(ll, 65535), U32.shln(mid, 16n))
  hi = U32.add(U32.add(hh, U32.shrn(lh, 16n)), U32.add(U32.shrn(hl, 16n), U32.shrn(mid, 16n)))
  U64{hi, lo}

# the low 64 bits of a 64x64 product
def U64.mul.fin(w: U64, cross: U32) -> U64:
  match w:
    case U64{h, l}:
      U64{U32.add(h, cross), l}

def U64.mul(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, +al} U64{bh, +bl}:
      U64.mul.fin(U32.mul_wide(al, bl), U32.add(U32.mul(ah, bl), U32.mul(al, bh)))

def U64.shl.go(h: U32, +l: U32, +k: Nat, small: Bool) -> U64:
  match small:
    case True{}:
      U64{U32.or(U32.shln(h, k), U32.shrn(l, Nat.sub(32n, k))), U32.shln(l, k)}
    case False{}:
      U64{U32.shln(l, Nat.sub(k, 32n)), 0}

def U64.shl(a: U64, +k: Nat) -> U64:
  match a:
    case U64{h, +l}:
      U64.shl.go(h, l, k, Nat.is_lt(k, 32n))

def U64.shr.go(+h: U32, l: U32, +k: Nat, small: Bool) -> U64:
  match small:
    case True{}:
      U64{U32.shrn(h, k), U32.or(U32.shrn(l, k), U32.shln(h, Nat.sub(32n, k)))}
    case False{}:
      U64{0, U32.shrn(h, Nat.sub(k, 32n))}

def U64.shr(a: U64, +k: Nat) -> U64:
  match a:
    case U64{+h, l}:
      U64.shr.go(h, l, k, Nat.is_lt(k, 32n))

def U64.or(a: U64, b: U64) -> U64:
  match a b:
    case U64{ah, al} U64{bh, bl}:
      U64{U32.or(ah, bh), U32.or(al, bl)}

def U64.rotl(+a: U64, +k: Nat) -> U64:
  U64.or(U64.shl(a, k), U64.shr(a, Nat.sub(64n, k)))

def U64.lo(a: U64) -> U32:
  match a:
    case U64{h, l}:
      l

def U64.lo_nat(a: U64) -> Nat:
  match a:
    case U64{h, l}:
      U32.to_nat(l)

def U64.is_eq(a: U64, b: U64) -> Bool:
  match a b:
    case U64{ah, al} U64{bh, bl}:
      Bool.and(U32.is_eq(ah, bh), U32.is_eq(al, bl))

def hex.digit.go(+x: U32, small: Bool) -> Char:
  match small:
    case True{}:
      Chr{U32.add(x, 48)}
    case False{}:
      Chr{U32.add(x, 87)}

def hex.digit(+x: U32) -> Char:
  hex.digit.go(x, U32.is_lt(x, 10))

def U32.hex.go(n: Nat, +x: U32, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      U32.hex.go(p, U32.shrn(x, 4n), SCon{hex.digit(U32.and(x, 15)), acc})

# eight lowercase hex digits
def U32.hex(+x: U32) -> String:
  U32.hex.go(8n, x, "")

def U64.hex(a: U64) -> String:
  match a:
    case U64{h, l}:
      U32.hex(h) ++ U32.hex(l)

# Decimal parse of a U64 (SAMPLE_SEED): digits only, None on anything else
# or on an empty string.  Overflow wraps, as a Word64 read of an in-range
# literal never does.
def U64.read.digit(ok: Bool, +c: U32, acc: Maybe<&2, U64>) -> Maybe<&2, U64>:
  match ok:
    case True{}:
      Maybe.map(&2, U64, U64, x => U64.add(U64.mul(x, U64.of(10)), U64.of(U32.sub(c, 48))), acc)
    case False{}:
      None{}

def U64.read.go(s: String, acc: Maybe<&2, U64>) -> Maybe<&2, U64>:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{+c}, t}:
      U64.read.go(t, U64.read.digit(Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57)), c, acc))

def U64.read(s: String) -> Maybe<&2, U64>:
  match s:
    case SNil{}:
      None{}
    case SCon{c, t}:
      U64.read.go(SCon{c, t}, Some{U64.zero()})

# a non-digit poisons the accumulator into None at the end
# The high 24 bits of a word as an F32 in [0, 1): the F32 reading of the
# host's high-53-bits Double.
def U64.unit(a: U64) -> F32:
  match a:
    case U64{h, l}:
      F32.div(U32.to_f32(U32.shrn(h, 8n)), 16777216.0)
