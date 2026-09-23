import Base
import ./Num.bend as N

# A pure parser over a byte list: the value beside the unread rest.  It is
# a monad in Base's sense (Parse.pure, Parse.bind), so decoders read as
# `do Parse<T>:` blocks.  Parsing never fails here; the decoded artifact is
# validated afterwards (magic, versions, identities), which is where the
# host's decoder failed too.

law Parse:
  for -A: Type
  Type

def Parse(A):
  List<&2, U32> -> A & List<&2, U32>

def Parse.pure(-A: Type, x: A) -> Parse(A):
  xs => (x, xs)

law Parse.laws.pure:
  for -A: Type
  for x: A
  for xs: List<&2, U32>
  {Parse.pure(A, x)(xs) == (x, xs) : A & List<&2, U32>}

def Parse.laws.pure(A, x, xs):
  {==}

def Parse.go(-A: Type, -B: Type, r: A & List<&2, U32>, f: A -> Parse(B)) -> B & List<&2, U32>:
  (a, rest) = r
  f(a, rest)

def Parse.bind(-A: Type, -B: Type, m: Parse(A), f: A -> Parse(B)) -> Parse(B):
  xs => Parse.go(A, B, m(xs), f)

def Parse.run(-A: Type, p: Parse(A), xs: List<&2, U32>) -> A & List<&2, U32>:
  p(xs)

def Parse.byte.go(xs: List<&2, U32>) -> U32 & List<&2, U32>:
  match xs:
    case Nil{}:
      (0, Nil{})
    case h <> t:
      (h, t)

def Parse.byte() -> Parse(U32):
  xs => Parse.byte.go(xs)

def Parse.u32be() -> Parse(U32):
  do Parse<U32>:
    a : U32 <- Parse.byte()
    b : U32 <- Parse.byte()
    c : U32 <- Parse.byte()
    d : U32 <- Parse.byte()
    return N.be32(a, b, c, d)

def Parse.u64be() -> Parse(N.U64):
  do Parse<N.U64>:
    h : U32 <- Parse.u32be()
    l : U32 <- Parse.u32be()
    return N.U64{h, l}

# An Int64 or Word64 known to be a small nonnegative count: its low word.
def Parse.nat() -> Parse(Nat):
  do Parse<Nat>:
    h : U32 <- Parse.u32be()
    l : U32 <- Parse.u32be()
    return U32.to_nat(l)

# a two's-complement Int32 low word as an F32
def signed.f32.if(+x: U32, neg: Bool) -> F32:
  match neg:
    case True{}:
      F32.neg(U32.to_f32(U32.add(U32.not(x), 1)))
    case False{}:
      U32.to_f32(x)

def signed.f32(+x: U32) -> F32:
  signed.f32.if(x, U32.is_ge(x, 2147483648))

def Parse.int.f32() -> Parse(F32):
  do Parse<F32>:
    h : U32 <- Parse.u32be()
    l : U32 <- Parse.u32be()
    return signed.f32(l)

def Parse.bool() -> Parse(Bool):
  do Parse<Bool>:
    b : U32 <- Parse.byte()
    return U32.is_ne(b, 0)

# n bytes, raw
def Parse.bytes(n: Nat) -> Parse(List<&2, U32>):
  match n:
    case 0n:
      Parse.pure(List<&2, U32>, Nil{})
    case 1n+p:
      do Parse<List<&2, U32>>:
        b : U32 <- Parse.byte()
        t : List<&2, U32> <- Parse.bytes(p)
        return b <> t

# One UTF-8 scalar (Data.Binary's Char encoding).  The continuation count
# comes from the lead byte; a malformed lead reads as itself.
def utf8.lead.go(+b: U32, one: Bool, two: Bool, three: Bool) -> Nat:
  match one two three:
    case True{} _ _:
      0n
    case False{} True{} _:
      1n
    case False{} False{} True{}:
      2n
    case False{} False{} False{}:
      3n

def utf8.lead(+b: U32) -> Nat:
  utf8.lead.go(b, U32.is_lt(b, 128), U32.is_lt(b, 224), U32.is_lt(b, 240))

def utf8.mask.go2(n: Nat) -> U32:
  match n:
    case 0n:
      15
    case 1n+p:
      7

def utf8.mask.go(n: Nat) -> U32:
  match n:
    case 0n:
      31
    case 1n+p:
      utf8.mask.go2(p)

def utf8.mask(n: Nat) -> U32:
  match n:
    case 0n:
      127
    case 1n+p:
      utf8.mask.go(p)

def utf8.cont(bs: List<&2, U32>, acc: U32) -> U32:
  match bs:
    case Nil{}:
      acc
    case h <> t:
      utf8.cont(t, U32.or(U32.shln(acc, 6n), U32.and(h, 63)))

def Parse.char() -> Parse(Char):
  do Parse<Char>:
    +b : U32 <- Parse.byte()
    +n : Nat = utf8.lead(b)
    rest : List<&2, U32> <- Parse.bytes(n)
    return Chr{utf8.cont(rest, U32.and(b, utf8.mask(n)))}

def Parse.chars(n: Nat) -> Parse(String):
  match n:
    case 0n:
      Parse.pure(String, SNil{})
    case 1n+p:
      do Parse<String>:
        c : Char <- Parse.char()
        t : String <- Parse.chars(p)
        return SCon{c, t}

# Data.Binary String: an Int64 character count, then the characters
def Parse.string() -> Parse(String):
  do Parse<String>:
    n : Nat <- Parse.nat()
    Parse.chars(n)

# little-endian byte list as an F32 magnitude
def le.f32(bs: List<&2, U32>) -> F32:
  match bs:
    case Nil{}:
      0.0
    case h <> t:
      F32.add(U32.to_f32(h), F32.mul(256.0, le.f32(t)))

def Parse.sign.if(pos: Bool, m: F32) -> F32:
  match pos:
    case True{}:
      m
    case False{}:
      F32.neg(m)

def Parse.sign(+s: U32, m: F32) -> F32:
  Parse.sign.if(U32.is_eq(s, 1), m)

def Parse.integer.if(small: Bool) -> Parse(F32):
  match small:
    case True{}:
      do Parse<F32>:
        w : U32 <- Parse.u32be()
        return signed.f32(w)
    case False{}:
      do Parse<F32>:
        s : U32 <- Parse.byte()
        n : Nat <- Parse.nat()
        bs : List<&2, U32> <- Parse.bytes(n)
        return Parse.sign(s, le.f32(bs))

# Data.Binary Integer: tag 0 is an Int32, tag 1 a sign byte and a
# little-endian magnitude
def Parse.integer() -> Parse(F32):
  do Parse<F32>:
    tag : U32 <- Parse.byte()
    Parse.integer.if(U32.is_eq(tag, 0))

# Data.Binary Double is decodeFloat: (mantissa :: Integer, exponent :: Int).
# Read to the nearest F32, which is what every consumer here needs.
def Parse.double() -> Parse(F32):
  do Parse<F32>:
    m : F32 <- Parse.integer()
    e : F32 <- Parse.int.f32()
    return F32.mul(m, F32.pow(2.0, e))

def Parse.maybe.if(some: Bool, p: Parse(F32)) -> Parse(Maybe<&2, F32>):
  match some:
    case True{}:
      do Parse<Maybe<&2, F32>>:
        x : F32 <- p
        return Some{x}
    case False{}:
      Parse.pure(Maybe<&2, F32>, None{})

def Parse.maybe.double() -> Parse(Maybe<&2, F32>):
  do Parse<Maybe<&2, F32>>:
    some : Bool <- Parse.bool()
    Parse.maybe.if(some, Parse.double())
