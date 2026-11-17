import Base
import ../Bytes.bend as B
import ../Parse.bend as P
import ../Tokenizer.bend as Tk

# winshow: training windows as text, to read what the trainer reads.
#
#   bend tests/winshow.bend -o OUT; OUT TOKENIZER SHARD FIRST COUNT
#
# SHARD is an FTCC corpus (Ftcc.bend; a run's shard-K-*.corpus, one document a
# window, Windows.bend).  Prints documents FIRST .. FIRST+COUNT-1 (counted from
# 0), each after a line "=== window ID (N tokens)", decoded with TOKENIZER.  An
# EOS (token 1) shows as a line "<EOS>": a window is the end of a filler file,
# then for each transcript EOS and the transcript (Windows.bend), and the
# trainer adds BOS before and EOS after, so CAPACITY + 2 tokens in all.  Ids and
# identities are ASCII here, a character a byte.

# the 8-byte big-endian count at the front of bs
def nat8.fin(r: Nat & List<&2, U32>) -> Nat:
  (n, rest) = r
  n

def nat8(bs: List<&2, U32>) -> Nat:
  nat8.fin(P.Parse.run(Nat, P.Parse.nat(), bs))

def count.fin(r: B.Cur & List<&2, U32>) -> B.Cur & Nat:
  (c, bs) = r
  (c, nat8(bs))

def count(c: B.Cur) -> IO(B.Cur & Nat):
  do IO<B.Cur & Nat>:
    r : B.Cur & List<&2, U32> <- B.Bytes.take(8n, c)
    return count.fin(r)

def str.go(r: B.Cur & Nat) -> IO(B.Cur & List<&2, U32>):
  (c, n) = r
  B.Bytes.take(n, c)

# a string's bytes
def str(c: B.Cur) -> IO(B.Cur & List<&2, U32>):
  do IO<B.Cur & List<&2, U32>>:
    r : B.Cur & Nat <- count(c)
    str.go(r)

def fst(r: B.Cur & List<&2, U32>) -> B.Cur:
  (c, bs) = r
  c

def skip.toks(r: B.Cur & Nat) -> IO(B.Cur):
  (c, n) = r
  do IO<B.Cur>:
    r2 : B.Cur & List<&2, U32> <- B.Bytes.take(Nat.mul(n, 2n), c)
    return fst(r2)

def skip.doc(r: B.Cur & List<&2, U32>) -> IO(B.Cur):
  (c, id) = r
  do IO<B.Cur>:
    r2 : B.Cur & Nat <- count(c)
    skip.toks(r2)

# past n documents
def skip(n: Nat, c: B.Cur) -> IO(B.Cur):
  match n:
    case 0n:
      do IO<B.Cur>:
        return c
    case 1n+p:
      do IO<B.Cur>:
        r : B.Cur & List<&2, U32> <- str(c)
        c2 : B.Cur <- skip.doc(r)
        skip(p, c2)

# big-endian 16-bit tokens
def toks(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case a <> b <> t:
      U32.or(U32.mul(a, 256), b) <> toks(t)
    case _:
      Nil{}

def one(+b: Tk.Bpe, +t: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_eq(t, 1), Tk.str.bytes("\n<EOS>\n"), Tk.Bpe.decode(b, t))

def dec(+b: Tk.Bpe, xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      List.append(&2, U32, one(b, h), dec(b, t))

def Dec.text(d: Tk.Dec) -> String:
  match d:
    case Tk.Dec{s, p}:
      s

def text(+xs: List<&2, U32>) -> String:
  Dec.text(Tk.utf8.decode(Nat.add(List.length(&2, U32, xs), 1n), xs, Tk.utf8.mode(xs)))

def show.text(+b: Tk.Bpe, id: List<&2, U32>, +n: Nat, r: B.Cur & List<&2, U32>) -> IO(B.Cur):
  (c, bs) = r
  do IO<B.Cur>:
    IO.print("=== window " ++ text(id) ++ " (" ++ Nat.show(n) ++ " tokens)")
    IO.print(text(dec(b, toks(bs))))
    return c

def show.toks(+b: Tk.Bpe, id: List<&2, U32>, r: B.Cur & Nat) -> IO(B.Cur):
  (c, n0) = r
  +n = n0
  do IO<B.Cur>:
    r2 : B.Cur & List<&2, U32> <- B.Bytes.take(Nat.mul(n, 2n), c)
    show.text(b, id, n, r2)

def show.doc(+b: Tk.Bpe, r: B.Cur & List<&2, U32>) -> IO(B.Cur):
  (c, id) = r
  do IO<B.Cur>:
    r2 : B.Cur & Nat <- count(c)
    show.toks(b, id, r2)

# n documents shown
def show(+b: Tk.Bpe, n: Nat, c: B.Cur) -> IO(B.Cur):
  match n:
    case 0n:
      do IO<B.Cur>:
        return c
    case 1n+p:
      do IO<B.Cur>:
        r : B.Cur & List<&2, U32> <- str(c)
        c2 : B.Cur <- show.doc(b, r)
        show(b, p, c2)

def nat.go(s: String, +acc: Nat) -> Nat:
  match s:
    case SNil{}:
      acc
    case SCon{Chr{c}, t}:
      nat.go(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(c, 48))))

def nat(s: String) -> Nat:
  nat.go(s, 0n)

# past the header: magic and version (8 bytes), the two identities, the count
def head(c: B.Cur) -> IO(B.Cur):
  do IO<B.Cur>:
    r : B.Cur & List<&2, U32> <- B.Bytes.take(8n, c)
    r2 : B.Cur & List<&2, U32> <- str(fst(r))
    r3 : B.Cur & List<&2, U32> <- str(fst(r2))
    r4 : B.Cur & List<&2, U32> <- B.Bytes.take(8n, fst(r3))
    return fst(r4)

def run(m: Maybe<&2, Tk.Bpe>, shard: String, +first: Nat, +k: Nat) -> IO(Unit):
  match m:
    case None{}:
      IO.print("winshow: the tokenizer does not parse")
    case Some{+b}:
      do IO<Unit>:
        c0 : B.Cur <- B.Bytes.open(shard)
        c1 : B.Cur <- head(c0)
        c2 : B.Cur <- skip(first, c1)
        c3 : B.Cur <- show(b, k, c2)
        B.Bytes.close(c3)

def go(argv: List<String>) -> IO(Unit):
  match argv:
    case tok <> shard <> first <> k <> rest:
      do IO<Unit>:
        xs : List<&2, U32> <- B.Bytes.read_all(tok)
        run(Tk.Bpe.parse(xs), shard, nat(first), nat(k))
    case _:
      IO.print("usage: winshow TOKENIZER SHARD FIRST COUNT")

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked
    argv : List<String> <- IO.args()
    go(List.tail(&1, String, argv))
