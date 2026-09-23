import Base
import ./Num.bend as N

# A byte cursor over a file.  File.read_bytes hands back one List cell per
# byte and has no seek, so the cursor keeps a buffer of bytes already read
# and its length, refilled in chunks of at least a mebibyte.  Every parser
# downstream is pure over List<&2, U32>; only `take` touches the file.
type Cur is Type:
  Cur{f: File, buf: List<&2, U32>, n: Nat}

law Chunk:
  Type

def Chunk():
  File & Result<&1, &1, U32 & String, List<&2, U32>>

def Bytes.open(path: String) -> IO(Cur):
  do IO<Cur>:
    f : File <- IO.try(File, File.open(path, "r"))
    return Cur{f, Nil{}, 0n}

def Bytes.close(c: Cur) -> IO(Unit):
  match c:
    case Cur{f, b, n}:
      File.close(f)

def List.split.put(h: U32, r: List<&2, U32> & List<&2, U32>) -> List<&2, U32> & List<&2, U32>:
  (a, b) = r
  (h <> a, b)

# the first k cells and the rest, in one pass
def List.split(+k: Nat, xs: List<&2, U32>) -> List<&2, U32> & List<&2, U32>:
  match k xs:
    case 0n _:
      (Nil{}, xs)
    case 1n+p Nil{}:
      (Nil{}, Nil{})
    case 1n+p h <> t:
      List.split.put(h, List.split(p, t))

def Bytes.chunk() -> U32:
  1048576

# the buffer extended by a fresh chunk, beside the chunk's length
def Bytes.extend(f: File, buf: List<&2, U32>, n: Nat, +xs: List<&2, U32>) -> Cur & Nat:
  +m = List.length(&2, U32, xs)
  (Cur{f, List.append(&2, U32, buf, xs), Nat.add(n, m)}, m)

def Bytes.appended(buf: List<&2, U32>, n: Nat, fr: Chunk()) -> IO(Cur & Nat):
  (f, r) = fr
  do IO<Cur & Nat>:
    xs : List<&2, U32> <- IO.pass(List<&2, U32>, r)
    return Bytes.extend(f, buf, n, xs)

def Bytes.fill.got(cm: Cur & Nat) -> IO(Cur):
  (c, m) = cm
  match m:
    case 0n:
      IO.die(Cur, 1, "bytes: unexpected end of file")
    case 1n+q:
      IO.pure(Cur, c)

def Bytes.step.if(+k: Nat, f: File, buf: List<&2, U32>, +n: Nat, short: Bool) -> IO(Cur):
  match short:
    case False{}:
      IO.pure(Cur, Cur{f, buf, n})
    case True{}:
      do IO<Cur>:
        fr : Chunk() <- File.read_bytes(f, U32.max(Bytes.chunk(), U32.from_nat(Nat.sub(k, n))))
        cm : Cur & Nat <- Bytes.appended(buf, n, fr)
        Bytes.fill.got(cm)

# one read if fewer than k bytes are buffered; an empty read is end of file
def Bytes.step(+k: Nat, c: Cur) -> IO(Cur):
  match c:
    case Cur{f, buf, +n}:
      Bytes.step.if(k, f, buf, n, Nat.is_lt(n, k))

# Read until at least k bytes are buffered.  Termination is structural in
# `fuel`; a regular file answers a full read, so one step normally suffices
# and the rest are no-ops.
def Bytes.fill(fuel: Nat, +k: Nat, c: Cur) -> IO(Cur):
  match fuel:
    case 0n:
      IO.pure(Cur, c)
    case 1n+p:
      do IO<Cur>:
        d : Cur <- Bytes.step(k, c)
        Bytes.fill(p, k, d)

def Bytes.split.fin(f: File, n: Nat, r: List<&2, U32> & List<&2, U32>) -> Cur & List<&2, U32>:
  (a, b) = r
  (Cur{f, b, n}, a)

def Bytes.split(+k: Nat, c: Cur) -> Cur & List<&2, U32>:
  match c:
    case Cur{f, buf, n}:
      Bytes.split.fin(f, Nat.sub(n, k), List.split(k, buf))

def Bytes.fuel() -> Nat:
  3n

def Bytes.buffered(+k: Nat, c: Cur) -> IO(Cur & List<&2, U32>):
  do IO<Cur & List<&2, U32>>:
    d : Cur <- Bytes.fill(Bytes.fuel(), k, c)
    return Bytes.split(k, d)

# a short read (possible at end of file) falls back to the buffered path
def Bytes.direct.check(+k: Nat, f: File, +xs: List<&2, U32>, full: Bool) -> IO(Cur & List<&2, U32>):
  match full:
    case True{}:
      IO.pure(Cur & List<&2, U32>, (Cur{f, Nil{}, 0n}, xs))
    case False{}:
      Bytes.buffered(k, Cur{f, xs, List.length(&2, U32, xs)})

# An exact read straight from the file, used once the buffer is drained:
# the list read_bytes answers is the result, with no split or append.
def Bytes.direct.fin(+k: Nat, fr: Chunk()) -> IO(Cur & List<&2, U32>):
  (f, r) = fr
  do IO<Cur & List<&2, U32>>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, r)
    Bytes.direct.check(k, f, xs, Nat.is_eq(List.length(&2, U32, xs), k))

def Bytes.take.if(empty: Bool, +k: Nat, f: File, buf: List<&2, U32>, +n: Nat) -> IO(Cur & List<&2, U32>):
  match empty:
    case True{}:
      do IO<Cur & List<&2, U32>>:
        fr : Chunk() <- File.read_bytes(f, U32.from_nat(k))
        Bytes.direct.fin(k, fr)
    case False{}:
      Bytes.buffered(k, Cur{f, buf, n})

# the next k bytes
def Bytes.take(+k: Nat, c: Cur) -> IO(Cur & List<&2, U32>):
  match c:
    case Cur{f, buf, +n}:
      Bytes.take.if(Nat.is_eq(n, 0n), k, f, buf, n)

# Pure decoders over a byte list.  Each answers the value beside the rest.

def Bytes.u32be(xs: List<&2, U32>) -> U32:
  match xs:
    case a <> b <> c <> d <> t:
      N.be32(a, b, c, d)
    case _:
      0

def Bytes.u64be(xs: List<&2, U32>) -> N.U64:
  match xs:
    case a <> b <> c <> d <> e <> f <> g <> h <> t:
      N.U64{N.be32(a, b, c, d), N.be32(e, f, g, h)}
    case _:
      N.U64.zero()

# big-endian f32 words, as many as the list holds
def Bytes.f32s(xs: List<&2, U32>) -> List<&2, F32>:
  match xs:
    case a <> b <> c <> d <> t:
      N.F32.from_bits(N.be32(a, b, c, d)) <> Bytes.f32s(t)
    case _:
      Nil{}

def Bytes.to_string(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, Bytes.to_string(t)}

# The loader monad: IO threading the cursor, so a checkpoint reader is a
# `do Load<T>:` block over fixed-width reads instead of a chain of pair
# destructurings.

law Load:
  for -A: Type
  Type

def Load(A):
  Cur -> IO(Cur & A)

def Load.pure(-A: Type, x: A) -> Load(A):
  c => IO.pure(Cur & A, (c, x))

def Load.go(-A: Type, -B: Type, r: Cur & A, f: A -> Load(B)) -> IO(Cur & B):
  (c, a) = r
  f(a, c)

def Load.bind(-A: Type, -B: Type, m: Load(A), f: A -> Load(B)) -> Load(B):
  c => IO.bind(Cur & A, Cur & B, m(c), r => Load.go(A, B, r, f))

def Load.io(-A: Type, m: IO(A)) -> Load(A):
  c => IO.bind(A, Cur & A, m, x => IO.pure(Cur & A, (c, x)))

def Load.bytes(+k: Nat) -> Load(List<&2, U32>):
  c => Bytes.take(k, c)

def Load.byte() -> Load(U32):
  do Load<U32>:
    xs : List<&2, U32> <- Load.bytes(1n)
    return Bytes.u32be(0 <> 0 <> 0 <> xs)

def Load.u32be() -> Load(U32):
  do Load<U32>:
    xs : List<&2, U32> <- Load.bytes(4n)
    return Bytes.u32be(xs)

def Load.u64be() -> Load(N.U64):
  do Load<N.U64>:
    xs : List<&2, U32> <- Load.bytes(8n)
    return Bytes.u64be(xs)

# an Int64/Word64 count: its low word
def Load.nat() -> Load(Nat):
  do Load<Nat>:
    w : N.U64 <- Load.u64be()
    return N.U64.lo_nat(w)

def Load.bool() -> Load(Bool):
  do Load<Bool>:
    b : U32 <- Load.byte()
    return U32.is_ne(b, 0)

# big-endian f32 values
def Load.f32s(+n: Nat) -> Load(List<&2, F32>):
  do Load<List<&2, F32>>:
    xs : List<&2, U32> <- Load.bytes(Nat.mul(4n, n))
    return Bytes.f32s(xs)

def Bytes.all.fin(fr: Chunk()) -> IO(List<&2, U32>):
  (f, r) = fr
  do IO<List<&2, U32>>:
    xs : List<&2, U32> <- IO.pass(List<&2, U32>, r)
    File.close(f)
    return xs

# a whole (small) file's bytes
def Bytes.read_all(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    f : File <- IO.try(File, File.open(path, "r"))
    fr : Chunk() <- File.read_bytes(f, 268435456)
    Bytes.all.fin(fr)
