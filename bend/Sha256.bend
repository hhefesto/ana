import Base
import ./Num.bend as N

# SHA-256 (FIPS 180-4) over a byte list.  The tokenizer identity is a
# digest over the canonical merge list, so this is what lets generate
# refuse a .bpe artifact that is not the one the checkpoint was trained
# with -- the same check master makes with cryptohash-sha256.

type H8 is Data:
  H8{a: U32, b: U32, c: U32, d: U32, e: U32, f: U32, g: U32, h: U32}

def K() -> List<&2, U32>:
  [1116352408, 1899447441, 3049323471, 3921009573, 961987163, 1508970993, 2453635748, 2870763221, 3624381080, 310598401, 607225278, 1426881987, 1925078388, 2162078206, 2614888103, 3248222580, 3835390401, 4022224774, 264347078, 604807628, 770255983, 1249150122, 1555081692, 1996064986, 2554220882, 2821834349, 2952996808, 3210313671, 3336571891, 3584528711, 113926993, 338241895, 666307205, 773529912, 1294757372, 1396182291, 1695183700, 1986661051, 2177026350, 2456956037, 2730485921, 2820302411, 3259730800, 3345764771, 3516065817, 3600352804, 4094571909, 275423344, 430227734, 506948616, 659060556, 883997877, 958139571, 1322822218, 1537002063, 1747873779, 1955562222, 2024104815, 2227730452, 2361852424, 2428436474, 2756734187, 3204031479, 3329325298]

def H0() -> H8:
  H8{1779033703, 3144134277, 1013904242, 2773480762, 1359893119, 2600822924, 528734635, 1541459225}

def rotr(+x: U32, +n: Nat) -> U32:
  U32.or(U32.shrn(x, n), U32.shln(x, Nat.sub(32n, n)))

def s0(+x: U32) -> U32:
  U32.xor(U32.xor(rotr(x, 7n), rotr(x, 18n)), U32.shrn(x, 3n))

def s1(+x: U32) -> U32:
  U32.xor(U32.xor(rotr(x, 17n), rotr(x, 19n)), U32.shrn(x, 10n))

def S0(+x: U32) -> U32:
  U32.xor(U32.xor(rotr(x, 2n), rotr(x, 13n)), rotr(x, 22n))

def S1(+x: U32) -> U32:
  U32.xor(U32.xor(rotr(x, 6n), rotr(x, 11n)), rotr(x, 25n))

def get(+xs: List<&2, U32>, +i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, xs, i), 0)

# the 64-word message schedule from the 16 block words, as a sliding
# window of the last sixteen
def sched(n: Nat, +win: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +w = U32.add(U32.add(s1(get(win, 14n)), get(win, 9n)), U32.add(s0(get(win, 1n)), get(win, 0n)))
      w <> sched(p, List.append(&2, U32, List.drop(&2, U32, win, 1n), [w]))

def round(+s: H8, +k: U32, +w: U32) -> H8:
  match s:
    case H8{+a, +b, +c, d, +e, +f, +g, h}:
      +t1 = U32.add(U32.add(U32.add(h, S1(e)), U32.add(U32.xor(U32.and(e, f), U32.and(U32.not(e), g)), k)), w)
      +t2 = U32.add(S0(a), U32.xor(U32.xor(U32.and(a, b), U32.and(a, c)), U32.and(b, c)))
      H8{U32.add(t1, t2), a, b, c, U32.add(d, t1), e, f, g}

def rounds(ks: List<&2, U32>, ws: List<&2, U32>, +s: H8) -> H8:
  match ks ws:
    case k <> kt w <> wt:
      rounds(kt, wt, round(s, k, w))
    case _ _:
      s

def H8.add(x: H8, y: H8) -> H8:
  match x y:
    case H8{a, b, c, d, e, f, g, h} H8{p, q, r, s, t, u, v, w}:
      H8{U32.add(a, p), U32.add(b, q), U32.add(c, r), U32.add(d, s),
         U32.add(e, t), U32.add(f, u), U32.add(g, v), U32.add(h, w)}

def words(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case a <> b <> c <> d <> t:
      N.be32(a, b, c, d) <> words(t)
    case _:
      Nil{}

def block(+s: H8, +ws: List<&2, U32>) -> H8:
  H8.add(s, rounds(K(), List.append(&2, U32, ws, sched(48n, ws)), s))

type Split is Data:
  Split{head: List<&2, U32>, rest: List<&2, U32>}

def split64.put(h: U32, r: Split) -> Split:
  match r:
    case Split{a, b}:
      Split{h <> a, b}

def split64(n: Nat, xs: List<&2, U32>) -> Split:
  match n xs:
    case 0n _:
      Split{Nil{}, xs}
    case 1n+p h <> t:
      split64.put(h, split64(p, t))
    case 1n+p Nil{}:
      Split{Nil{}, Nil{}}

# blocks of a padded message; `fuel` bounds the block count
def blocks(fuel: Nat, +s: H8, sp: Split) -> H8:
  match fuel sp:
    case 1n+p Split{h <> ht, rest}:
      blocks(p, block(s, words(h <> ht)), split64(64n, rest))
    case _ _:
      s

def zeros(n: Nat) -> List<&2, U32>:
  List.replicate(U32, n, 0)

def len.bytes(+bits: N.U64) -> List<&2, U32>:
  match bits:
    case N.U64{+h, +l}:
      [U32.shrn(h, 24n), U32.and(U32.shrn(h, 16n), 255), U32.and(U32.shrn(h, 8n), 255), U32.and(h, 255),
       U32.shrn(l, 24n), U32.and(U32.shrn(l, 16n), 255), U32.and(U32.shrn(l, 8n), 255), U32.and(l, 255)]

# message ++ 0x80 ++ zeros ++ 64-bit bit length, to a multiple of 64
def pad(+xs: List<&2, U32>) -> List<&2, U32>:
  +n = List.length(&2, U32, xs)
  +z = Nat.mod(Nat.sub(Nat.add(64n, 55n), Nat.mod(n, 64n)), 64n)
  List.append(&2, U32, xs, 128 <> List.append(&2, U32, zeros(z), len.bytes(N.U64.mul(N.U64.of(U32.from_nat(n)), N.U64.of(8)))))

def H8.hex(s: H8) -> String:
  match s:
    case H8{a, b, c, d, e, f, g, h}:
      N.U32.hex(a) ++ N.U32.hex(b) ++ N.U32.hex(c) ++ N.U32.hex(d)
        ++ N.U32.hex(e) ++ N.U32.hex(f) ++ N.U32.hex(g) ++ N.U32.hex(h)

def sha256(+xs: List<&2, U32>) -> String:
  +padded = pad(xs)
  H8.hex(blocks(Nat.add(Nat.div(List.length(&2, U32, padded), 64n), 1n), H0(), split64(64n, padded)))
