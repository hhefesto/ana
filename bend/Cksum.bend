import Base

# POSIX cksum: the CRC-32 (polynomial 0x04C11DB7, most significant bit
# first, register starting at 0) of the bytes followed by their length as
# little-endian bytes (only as many as it needs), complemented.  It is what
# `cksum` prints first; the checkers use it to pick a unit's first mutant
# (`cksum <<< "$UNIT_ID"`, so the id with a newline).

def poly() -> U32:
  79764919

def crc.bit(n: Nat, +c: U32) -> U32:
  match n:
    case 0n:
      c
    case 1n+k:
      crc.bit(k, Bool.pick(U32, U32.is_eq(U32.and(c, 2147483648), 0), U32.shln(c, 1n), U32.xor(U32.shln(c, 1n), poly())))

def crc.byte(+c: U32, +b: U32) -> U32:
  crc.bit(8n, U32.xor(c, U32.shln(b, 24n)))

def crc.bytes(xs: List<&2, U32>, +c: U32) -> U32:
  match xs:
    case Nil{}:
      c
    case +b <> t:
      crc.bytes(t, crc.byte(c, b))

# the length's bytes, least significant first, none for 0
def len.bytes(fuel: Nat, +n: Nat) -> List<&2, U32>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+f:
      Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), Nil{}, U32.from_nat(Nat.mod(n, 256n)) <> len.bytes(f, Nat.div(n, 256n)))

def cksum(+xs: List<&2, U32>) -> U32:
  U32.xor(crc.bytes(len.bytes(8n, List.length(&2, U32, xs)), crc.bytes(xs, 0)), 4294967295)
