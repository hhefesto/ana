import Base
import ../Num.bend as N
import ../Tokenizer.bend as Tk

# Documents, the deterministic train/validation split, and training windows
# (master: backend/src/FormalTransformer/Data.hs).
#
#   split      document i goes to validation iff mix(seed + i) mod 10^6 is
#              below 0.1 * 10^6 (trainerSplitSeed, trainerValidationFraction)
#   windows    full non-overlapping windows of the given width over
#              BOS : tokens ++ [EOS]; shorter documents contribute none
#
# A text corpus is cut into documents at blank lines (an article or
# paragraph each), and each document is encoded with the run's tokenizer.
# trainerSplitSeed = 0x46544f50454e434c ("FTOPENCL")
def seed() -> N.U64:
  N.U64{1179930448, 1162756940}

# splitmix64's finalizer (Data.mix)
def mix(+x0: N.U64) -> N.U64:
  +x1 = N.U64.mul(N.U64.xor(x0, N.U64.shr(x0, 30n)), N.U64{3210233709, 484763065})
  +x2 = N.U64.mul(N.U64.xor(x1, N.U64.shr(x1, 27n)), N.U64{2496678331, 321982955})
  N.U64.xor(x2, N.U64.shr(x2, 31n))

# a 64-bit word mod 10^6, by long division on the two 32-bit limbs
def mod.million(+x: N.U64) -> U32:
  match x:
    case N.U64{+h, +l}:
      +hm = U32.mod(h, 1000000)
      # (hm * 2^32 + l) mod 10^6, with 2^32 mod 10^6 = 967296 = 967·1000 + 296;
      # hm·967296 overflows 32 bits, so it is reduced in two parts that fit
      +a = U32.mul(U32.mod(U32.mul(hm, 967), 1000), 1000)
      +b = U32.mod(U32.mul(hm, 296), 1000000)
      U32.mod(U32.add(U32.add(a, b), U32.mod(l, 1000000)), 1000000)

def is_validation(+i: Nat) -> Bool:
  U32.is_lt(mod.million(mix(N.U64.add(seed(), N.U64.of(U32.from_nat(i))))), 100000)

type Split is Data:
  Split{train: List<&2, List<&2, U32>>, valid: List<&2, List<&2, U32>>}

def Split.put(v: Bool, +d: List<&2, U32>, s: Split) -> Split:
  match v s:
    case True{} Split{t, w}:
      Split{t, d <> w}
    case False{} Split{t, w}:
      Split{d <> t, w}

def split.go(docs: List<&2, List<&2, U32>>, +i: Nat) -> Split:
  match docs:
    case Nil{}:
      Split{Nil{}, Nil{}}
    case +d <> rest:
      Split.put(is_validation(i), d, split.go(rest, 1n+i))

def split(docs: List<&2, List<&2, U32>>) -> Split:
  split.go(docs, 0n)

# full windows of `width` tokens, stride width (the flag: a full window
# still fits)
def windows.go(fuel: Nat, +width: Nat, +stream: List<&2, U32>, full: Bool) -> List<&2, List<&2, U32>>:
  match fuel full:
    case 1n+p True{}:
      +rest = List.drop(&2, U32, stream, width)
      List.take(&2, U32, stream, width) <> windows.go(p, width, rest, Nat.is_le(width, List.length(&2, U32, rest)))
    case _ _:
      Nil{}

def windows(+width: Nat, +doc: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +stream = List.append(&2, U32, Tk.bos() <> doc, [Tk.eos()])
  windows.go(List.length(&2, U32, stream), width, stream, Nat.is_le(width, List.length(&2, U32, stream)))

def all.windows(+width: Nat, docs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match docs:
    case Nil{}:
      Nil{}
    case +d <> rest:
      List.append(&2, List<&2, U32>, windows(width, d), all.windows(width, rest))

# Corpus text -> documents ----------------------------------------------

type Docs is Data:
  Docs{cur: List<&2, U32>, done: List<&2, List<&2, U32>>}

def Docs.flush(+cur: List<&2, U32>, +done: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match cur:
    case Nil{}:
      done
    case h <> t:
      List.reverse(&2, U32, h <> t) <> done

def is_nl(+c: U32) -> Bool:
  U32.is_eq(c, 10)

def blank.at(+xs: List<&2, U32>) -> Bool:
  match xs:
    case a <> b <> t:
      Bool.and(is_nl(a), is_nl(b))
    case _:
      False{}

# bytes -> documents cut at blank lines ("\n\n"), newest first while
# scanning (the flag says whether a blank line starts here)
def docs.go(xs: List<&2, U32>, +cur: List<&2, U32>, +done: List<&2, List<&2, U32>>, blank: Bool) -> List<&2, List<&2, U32>>:
  match xs blank:
    case Nil{} _:
      Docs.flush(cur, done)
    case a <> +t True{}:
      docs.go(t, Nil{}, Docs.flush(cur, done), blank.at(t))
    case a <> +t False{}:
      docs.go(t, a <> cur, done, blank.at(t))

def lrev(xs: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      lrev(t, h <> acc)

def documents(+text: List<&2, U32>) -> List<&2, List<&2, U32>>:
  lrev(docs.go(text, Nil{}, Nil{}, blank.at(text)), Nil{})

# every document encoded (ordinary tokens only; BOS/EOS are the windows')
def encode.all(+b: Tk.Bpe, ds: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ds:
    case Nil{}:
      Nil{}
    case +d <> rest:
      Tk.Bpe.encode(b, d) <> encode.all(b, rest)

# the byte tokenizer (lossless-byte-v1): byte b is token b + 2
def bytes.tokens(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      U32.add(h, 2) <> bytes.tokens(t)

def encode.bytes(ds: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ds:
    case Nil{}:
      Nil{}
    case d <> rest:
      bytes.tokens(d) <> encode.bytes(rest)
