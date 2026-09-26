import Base

# The NUL-framed document stream every corpus tool reads and writes: an id,
# a NUL byte, the text, a NUL byte, repeated.  The JSONL drivers
# (bend-transcripts, bend-plan-corpus, ...) write it from `{id, text}` lines
# with Json.bend, so these tools parse no JSON.
#
# Meaning: a list of (id, text) byte-list pairs, in stream order.  A stream
# whose last pair lacks either NUL is refused ("incomplete final pair"), as
# master's readers refused it (Main.hs readNulDocuments, Pack.nulDocuments).
# Neither side of a pair may hold a NUL, which is exactly what makes the
# framing unambiguous.

type Doc is Data:
  Doc{id: List<&2, U32>, text: List<&2, U32>}

def Doc.id(+d: Doc) -> List<&2, U32>:
  match d:
    case Doc{i, t}:
      i

def Doc.text(+d: Doc) -> List<&2, U32>:
  match d:
    case Doc{i, t}:
      t

# One field: the bytes before the next NUL, what follows it, and whether a
# NUL was found at all (False: the stream ended inside the field).
type Field is Data:
  Field{bytes: List<&2, U32>, rest: List<&2, U32>, ended: Bool}

def Field.put(h: U32, f: Field) -> Field:
  match f:
    case Field{b, r, e}:
      Field{h <> b, r, e}

def head.nul(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 0)
    case Nil{}:
      False{}

def field.go(+xs: List<&2, U32>, nul: Bool) -> Field:
  match xs nul:
    case h <> +t False{}:
      Field.put(h, field.go(t, head.nul(t)))
    case h <> t True{}:
      Field{Nil{}, t, True{}}
    case Nil{} _:
      Field{Nil{}, Nil{}, False{}}

def field(+xs: List<&2, U32>) -> Field:
  field.go(xs, head.nul(xs))

# One step of the stream: a pair and the bytes after it, the clean end, or
# a malformed tail.
type Step is Data:
  More{doc: Doc, rest: List<&2, U32>}
  End{}
  Bad{why: String}

def step.fin(ok: Bool, d: Doc, r: List<&2, U32>) -> Step:
  match ok:
    case True{}:
      More{d, r}
    case False{}:
      Bad{"incomplete final NUL-delimited id/text pair"}

def step.text(i: List<&2, U32>, e1: Bool, f: Field) -> Step:
  match f:
    case Field{t, r, e2}:
      step.fin(Bool.and(e1, e2), Doc{i, t}, r)

def step.id(f: Field) -> Step:
  match f:
    case Field{i, +r, e}:
      step.text(i, e, field(r))

def step(+xs: List<&2, U32>) -> Step:
  match xs:
    case Nil{}:
      End{}
    case h <> t:
      step.id(field(h <> t))

type Docs is Data:
  Docs{docs: List<&2, Doc>, problem: String}

def Docs.docs(+d: Docs) -> List<&2, Doc>:
  match d:
    case Docs{ds, p}:
      ds

def Docs.problem(+d: Docs) -> String:
  match d:
    case Docs{ds, p}:
      p

# Every pair costs at least two bytes (its NULs), so a stream of n bytes
# holds at most n pairs: n + 1 steps of fuel always reach End or Bad.
def docs.go(fuel: Nat, s: Step, acc: List<&2, Doc>) -> Docs:
  match fuel s:
    case 1n+p More{d, +r}:
      docs.go(p, step(r), d <> acc)
    case _ End{}:
      Docs{List.reverse(&2, Doc, acc), ""}
    case _ Bad{w}:
      Docs{Nil{}, w}
    case 0n More{d, r}:
      Docs{Nil{}, "nul: out of fuel (a bug: every pair consumes two bytes)"}

def docs(+xs: List<&2, U32>) -> Docs:
  docs.go(1n+List.length(&2, U32, xs), step(xs), Nil{})

# The stream of a list of pairs, prepended to `rest`.
def put.bytes(xs: List<&2, U32>, rest: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      rest
    case h <> t:
      h <> put.bytes(t, rest)

def put(ds: List<&2, Doc>, rest: List<&2, U32>) -> List<&2, U32>:
  match ds:
    case Nil{}:
      rest
    case Doc{i, t} <> more:
      put.bytes(i, 0 <> put.bytes(t, 0 <> put(more, rest)))

# Whole files.  File.read_bytes answers one list cell per byte, capped per
# call; a file must arrive in one read, so anything at the cap is refused
# rather than silently truncated.
def read.cap() -> U32:
  268435456

def read.check(+n: U32, +xs: List<&2, U32>, full: Bool) -> IO(List<&2, U32>):
  match full:
    case True{}:
      IO.pure(List<&2, U32>, xs)
    case False{}:
      IO.die(List<&2, U32>, 1, "nul: short read (expected " ++ U32.show(n) ++ " bytes)")

def read.got(+n: U32, fr: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(List<&2, U32>):
  (f, r) = fr
  do IO<List<&2, U32>>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, r)
    File.close(f)
    read.check(n, xs, Nat.is_eq(List.length(&2, U32, xs), U32.to_nat(n)))

def read.sized(f: File, +n: U32, small: Bool) -> IO(List<&2, U32>):
  match small:
    case True{}:
      do IO<List<&2, U32>>:
        fr : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, n)
        read.got(n, fr)
    case False{}:
      IO.die(List<&2, U32>, 1, "nul: input is " ++ U32.show(n) ++ " bytes; the cap is " ++ U32.show(read.cap()) ++ " (split it)")

def read.size(fr: File & Result<&1, &1, U32 & String, U32>) -> IO(List<&2, U32>):
  (f, r) = fr
  do IO<List<&2, U32>>:
    +n : U32 <- IO.pass(U32, r)
    read.sized(f, n, U32.is_lt(n, read.cap()))

def read(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    f : File <- IO.try(File, File.open(path, "r"))
    fr : File & Result<&1, &1, U32 & String, U32> <- File.size(f)
    read.size(fr)

def write.fin(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, e) = r
  do IO<Unit>:
    u : Unit <- IO.pass(Unit, e)
    File.close(f)

def write(path: String, xs: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "w"))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(f, xs)
    write.fin(r)
