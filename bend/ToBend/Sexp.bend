import Base
import ../Sys.bend as S

# Sexp: the S-expressions agda-export writes (tools/agda-export/FORMAT.md,
# "Lexical syntax"), read into a tree and printed back.  agda2bend's parser
# of Agda (Agda2Bend/Ast.bend) decodes these trees; lean2bend's exporter
# will write the same syntax.
#
#   sexp   ::= atom | string | "(" sexp* ")"
#   atom   ::= [A-Za-z0-9_.-]+          (an int is an atom of digits)
#   string ::= '"' ( [^"\\] | '\"' | '\\' )* '"'   (UTF-8, raw newlines allowed)
#
# A list is spelled with cons cells, as Lisp does, so the tree is one type
# with no list inside it: every def over it recurses on a pattern-bound
# part, which Bend's termination check sees, and no pass needs a second,
# mutually recursive def for the lists.
#
# The reader is one left-to-right scan of the bytes (structural recursion on
# the byte list) with an explicit stack of the lists still open, so its
# depth costs no recursion.  `tsx.open` and `tsx.next` stream a file one
# top-level expression at a time: a line is fed to the scan, and an
# expression is handed out once its parentheses close outside a string, so
# a module of any size is never held as one byte list.  Every def is
# prefixed `tsx.`.

type Sx is Data:
  SxAtom{s: List<&2, U32>}
  SxStr{s: List<&2, U32>}
  SxNil{}
  SxCons{h: Sx, t: Sx}

# The scan's mode: between tokens, inside an atom, inside a string, or just
# after a backslash inside a string.
type TsxM is Data:
  TsxOut{}
  TsxAtom{}
  TsxStr{}
  TsxEsc{}

# A byte's class for the scan.
type TsxC is Data:
  TsxOpen{}
  TsxClose{}
  TsxQuote{}
  TsxSpace{}
  TsxBack{}
  TsxOther{}

# The scan's state: the mode, the token so far (reversed), the elements of
# the innermost open list so far (reversed), and the enclosing open lists'
# elements (innermost first).  At top level `cur` holds the finished
# expressions, newest first.  `bad` counts a `)` with no list open.
type TsxSt is Data:
  TsxSt{m: TsxM, tok: List<&2, U32>, cur: List<&2, Sx>, stk: List<&2, List<&2, Sx>>, bad: Nat}

def tsx.st0() -> TsxSt:
  TsxSt{TsxOut{}, Nil{}, Nil{}, Nil{}, 0n}

# space, tab, newline and carriage return
def tsx.ws(+b: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(b, 32), U32.is_eq(b, 10)), Bool.or(U32.is_eq(b, 9), U32.is_eq(b, 13)))

def tsx.cls.go(open: Bool, close: Bool, quote: Bool, back: Bool, space: Bool) -> TsxC:
  match open close quote back space:
    case True{} _ _ _ _:
      TsxOpen{}
    case False{} True{} _ _ _:
      TsxClose{}
    case False{} False{} True{} _ _:
      TsxQuote{}
    case False{} False{} False{} True{} _:
      TsxBack{}
    case False{} False{} False{} False{} True{}:
      TsxSpace{}
    case False{} False{} False{} False{} False{}:
      TsxOther{}

def tsx.cls(+b: U32) -> TsxC:
  tsx.cls.go(U32.is_eq(b, 40), U32.is_eq(b, 41), U32.is_eq(b, 34), U32.is_eq(b, 92), tsx.ws(b))

# The reversed elements xs put in front of acc as a cons chain, in order:
# [c, b, a] and acc give (a b c . acc).
def tsx.chain(xs: List<&2, Sx>, acc: Sx) -> Sx:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      tsx.chain(t, SxCons{h, acc})

# `)`: the innermost list is finished and becomes an element of the list
# around it.  A `)` with nothing open is counted and dropped.
def tsx.close(cur: List<&2, Sx>, stk: List<&2, List<&2, Sx>>, +bad: Nat) -> TsxSt:
  match stk:
    case up <> rest:
      TsxSt{TsxOut{}, Nil{}, tsx.chain(cur, SxNil{}) <> up, rest, bad}
    case Nil{}:
      TsxSt{TsxOut{}, Nil{}, cur, Nil{}, 1n+bad}

# a byte between tokens
def tsx.out(c: TsxC, +b: U32, cur: List<&2, Sx>, stk: List<&2, List<&2, Sx>>, +bad: Nat) -> TsxSt:
  match c:
    case TsxOpen{}:
      TsxSt{TsxOut{}, Nil{}, Nil{}, cur <> stk, bad}
    case TsxClose{}:
      tsx.close(cur, stk, bad)
    case TsxQuote{}:
      TsxSt{TsxStr{}, Nil{}, cur, stk, bad}
    case TsxSpace{}:
      TsxSt{TsxOut{}, Nil{}, cur, stk, bad}
    case TsxBack{}:
      TsxSt{TsxAtom{}, b <> Nil{}, cur, stk, bad}
    case TsxOther{}:
      TsxSt{TsxAtom{}, b <> Nil{}, cur, stk, bad}

# a byte inside an atom: a delimiter ends the atom and is then read as a
# byte between tokens
def tsx.atom(+c: TsxC, +b: U32, tok: List<&2, U32>, cur: List<&2, Sx>, stk: List<&2, List<&2, Sx>>, +bad: Nat) -> TsxSt:
  match c:
    case TsxOther{}:
      TsxSt{TsxAtom{}, b <> tok, cur, stk, bad}
    case TsxBack{}:
      TsxSt{TsxAtom{}, b <> tok, cur, stk, bad}
    case _:
      tsx.out(c, b, SxAtom{List.reverse(&2, U32, tok)} <> cur, stk, bad)

# a byte inside a string: `"` ends it, `\` escapes the next byte
def tsx.str(c: TsxC, +b: U32, tok: List<&2, U32>, cur: List<&2, Sx>, stk: List<&2, List<&2, Sx>>, +bad: Nat) -> TsxSt:
  match c:
    case TsxQuote{}:
      TsxSt{TsxOut{}, Nil{}, SxStr{List.reverse(&2, U32, tok)} <> cur, stk, bad}
    case TsxBack{}:
      TsxSt{TsxEsc{}, tok, cur, stk, bad}
    case _:
      TsxSt{TsxStr{}, b <> tok, cur, stk, bad}

def tsx.step(s: TsxSt, +b: U32) -> TsxSt:
  match s:
    case TsxSt{TsxOut{}, tok, cur, stk, bad}:
      tsx.out(tsx.cls(b), b, cur, stk, bad)
    case TsxSt{TsxAtom{}, tok, cur, stk, bad}:
      tsx.atom(tsx.cls(b), b, tok, cur, stk, bad)
    case TsxSt{TsxStr{}, tok, cur, stk, bad}:
      tsx.str(tsx.cls(b), b, tok, cur, stk, bad)
    case TsxSt{TsxEsc{}, tok, cur, stk, bad}:
      TsxSt{TsxStr{}, b <> tok, cur, stk, bad}

def tsx.scan(xs: List<&2, U32>, s: TsxSt) -> TsxSt:
  match xs:
    case Nil{}:
      s
    case h <> t:
      tsx.scan(t, tsx.step(s, h))

# The input has ended: an atom still being read is finished.
def tsx.flush(s: TsxSt) -> TsxSt:
  match s:
    case TsxSt{TsxAtom{}, tok, cur, stk, bad}:
      TsxSt{TsxOut{}, Nil{}, SxAtom{List.reverse(&2, U32, tok)} <> cur, stk, bad}
    case TsxSt{m, tok, cur, stk, bad}:
      TsxSt{m, tok, cur, stk, bad}

# Every top-level expression of xs, in order.  Input that ends inside a
# list or a string, or holds a stray `)`, gives what was finished before it.
def tsx.read.fin(s: TsxSt) -> List<&2, Sx>:
  match s:
    case TsxSt{m, tok, cur, stk, bad}:
      List.reverse(&2, Sx, cur)

def tsx.read(xs: List<&2, U32>) -> List<&2, Sx>:
  tsx.read.fin(tsx.flush(tsx.scan(xs, tsx.st0())))

# The one expression of xs, if it holds exactly one and nothing is left open.
def tsx.one.of(ok: Bool, xs: List<&2, Sx>) -> Maybe<&2, Sx>:
  match ok xs:
    case True{} x <> Nil{}:
      Some{x}
    case _ _:
      None{}

def tsx.closed(m: TsxM, stk: List<&2, List<&2, Sx>>, +bad: Nat) -> Bool:
  match m stk:
    case TsxOut{} Nil{}:
      Nat.is_eq(bad, 0n)
    case _ _:
      False{}

def tsx.one.fin(s: TsxSt) -> Maybe<&2, Sx>:
  match s:
    case TsxSt{m, tok, cur, stk, +bad}:
      tsx.one.of(tsx.closed(m, stk, bad), cur)

def tsx.one(xs: List<&2, U32>) -> Maybe<&2, Sx>:
  tsx.one.fin(tsx.flush(tsx.scan(xs, tsx.st0())))

# Printing -----------------------------------------------------------------
#
# The compact form agda-export writes: list elements joined by one space, a
# string with `"` and `\` escaped.  The exporter's compact output prints
# back byte for byte (tests/agda2bend.bend's round trip).

def tsx.esc.if(e: Bool, h: U32, rest: List<&2, U32>) -> List<&2, U32>:
  match e:
    case True{}:
      92 <> h <> rest
    case False{}:
      h <> rest

def tsx.esc(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      tsx.esc.if(Bool.or(U32.is_eq(h, 34), U32.is_eq(h, 92)), h, tsx.esc(t))

# x printed in front of acc.  `first` says whether x is the first element of
# the list it continues (no space before it); a cons chain is printed by
# walking its spine, so one def handles both an expression and the rest of a
# list: `open` says whether x is a whole expression (True) or the rest of a
# list already opened (False).
def tsx.put(x: Sx, open: Bool, first: Bool, acc: List<&2, U32>) -> List<&2, U32>:
  match x open:
    case SxAtom{s} True{}:
      List.append(&2, U32, s, acc)
    case SxStr{s} True{}:
      34 <> List.append(&2, U32, tsx.esc(s), 34 <> acc)
    case SxNil{} True{}:
      40 <> 41 <> acc
    case SxCons{h, t} True{}:
      40 <> tsx.put(h, True{}, True{}, tsx.put(t, False{}, False{}, acc))
    case SxNil{} False{}:
      41 <> acc
    case SxCons{h, t} False{}:
      32 <> tsx.put(h, True{}, True{}, tsx.put(t, False{}, False{}, acc))
    case SxAtom{s} False{}:
      32 <> 46 <> 32 <> List.append(&2, U32, s, 41 <> acc)
    case SxStr{s} False{}:
      32 <> 46 <> 32 <> 34 <> List.append(&2, U32, tsx.esc(s), 34 <> 41 <> acc)

def tsx.show(x: Sx) -> List<&2, U32>:
  tsx.put(x, True{}, True{}, Nil{})

# Access -------------------------------------------------------------------

# the bytes of an atom, else empty
def tsx.atom.of(x: Sx) -> List<&2, U32>:
  match x:
    case SxAtom{s}:
      s
    case _:
      Nil{}

# a list's first element's atom: (name "x") has head `name`
def tsx.head(x: Sx) -> List<&2, U32>:
  match x:
    case SxCons{h, t}:
      tsx.atom.of(h)
    case _:
      Nil{}

# the elements after the head: (name "x") has args ("x")
def tsx.args(x: Sx) -> Sx:
  match x:
    case SxCons{h, t}:
      t
    case _:
      SxNil{}

# the i-th element of a list (0 is the head), SxNil when there is none
def tsx.at(i: Nat, x: Sx) -> Sx:
  match i x:
    case 0n SxCons{h, t}:
      h
    case 1n+p SxCons{h, t}:
      tsx.at(p, t)
    case _ _:
      SxNil{}

# whether list x's first element is a list whose head atom is key
def tsx.hit(+x: Sx, +key: List<&2, U32>) -> Bool:
  S.eq(tsx.head(tsx.at(0n, x)), key)

# hit: tsx.hit(x, key), decided by the caller so the recursion stays in one def
def tsx.field.go(x: Sx, +key: List<&2, U32>, hit: Bool) -> Maybe<&2, Sx>:
  match x hit:
    case SxCons{h, t} True{}:
      Some{h}
    case SxCons{h, +t} False{}:
      tsx.field.go(t, key, tsx.hit(t, key))
    case _ _:
      None{}

# the first element of list x whose head atom is key: in
# (def Q (name "x") (kind record) ...) the field `kind` is (kind record)
def tsx.field(+x: Sx, +key: List<&2, U32>) -> Maybe<&2, Sx>:
  tsx.field.go(x, key, tsx.hit(x, key))

# the bytes of a string, else empty
def tsx.str.of(x: Sx) -> List<&2, U32>:
  match x:
    case SxStr{s}:
      s
    case _:
      Nil{}

# an atom of decimal digits as a Nat (only for small counts: de Bruijn
# indices, arities, line numbers; a NameId's hash stays bytes)
def tsx.nat.go(xs: List<&2, U32>, acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      tsx.nat.go(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))))

def tsx.nat(x: Sx) -> Nat:
  tsx.nat.go(tsx.atom.of(x), 0n)

# the number of elements of a list
def tsx.len(x: Sx) -> Nat:
  match x:
    case SxCons{h, t}:
      1n+tsx.len(t)
    case _:
      0n

# Streaming ----------------------------------------------------------------

# A file being read: its line reader and the scan's state between lines.
type TsxRd is Type:
  TsxRd{r: S.Rd, s: TsxSt}

def tsx.open(path: String) -> IO(TsxRd):
  do IO<TsxRd>:
    r : S.Rd <- S.Rd.lines(path)
    return TsxRd{r, tsx.st0()}

def tsx.shut(t: TsxRd) -> IO(Unit):
  match t:
    case TsxRd{r, s}:
      S.Rd.close(r)

def tsx.take.last.put(h: Sx, r: Maybe<&2, Sx> & List<&2, Sx>) -> Maybe<&2, Sx> & List<&2, Sx>:
  (m, rest) = r
  (m, h <> rest)

# The last element of h <> t, taken out: the oldest finished top-level
# expression, since they sit newest first.
def tsx.take.last.cons(t: List<&2, Sx>, h: Sx) -> Maybe<&2, Sx> & List<&2, Sx>:
  match t:
    case Nil{}:
      (Some{h}, Nil{})
    case h2 <> t2:
      tsx.take.last.put(h, tsx.take.last.cons(t2, h2))

def tsx.take.last(xs: List<&2, Sx>) -> Maybe<&2, Sx> & List<&2, Sx>:
  match xs:
    case Nil{}:
      (None{}, Nil{})
    case h <> t:
      tsx.take.last.cons(t, h)

def tsx.ready.put(r: Maybe<&2, Sx> & List<&2, Sx>, tok: List<&2, U32>, bad: Nat) -> Maybe<&2, Sx> & TsxSt:
  (m, rest) = r
  (m, TsxSt{TsxOut{}, tok, rest, Nil{}, bad})

# Hand out a finished expression if one is ready at top level.
def tsx.ready(s: TsxSt) -> Maybe<&2, Sx> & TsxSt:
  match s:
    case TsxSt{TsxOut{}, tok, cur, Nil{}, bad}:
      tsx.ready.put(tsx.take.last(cur), tok, bad)
    case TsxSt{m, tok, cur, stk, bad}:
      (None{}, TsxSt{m, tok, cur, stk, bad})

# One more line through the scan (its newline included: it may sit inside
# a string), or the end of the file: an atom still open is finished.
def tsx.feed(s: TsxSt, m: Maybe<&2, List<&2, U32>>) -> TsxSt & Bool:
  match m:
    case Some{line}:
      (tsx.scan(List.append(&2, U32, line, 10 <> Nil{}), s), False{})
    case None{}:
      (tsx.flush(s), True{})

# a read in progress: the line reader, the scan, whether the file ended,
# and the expression handed out, if any
type TsxNx is Type:
  TsxNx{r: S.Rd, s: TsxSt, eof: Bool, got: Maybe<&2, Sx>}

def tsx.next.mk(r: S.Rd, eof: Bool, y: Maybe<&2, Sx> & TsxSt) -> TsxNx:
  (m, s2) = y
  TsxNx{r, s2, eof, m}

def tsx.next.chk(r: S.Rd, x: TsxSt & Bool) -> TsxNx:
  (s, eof) = x
  tsx.next.mk(r, eof, tsx.ready(s))

def tsx.next.got(x: S.Rd & Maybe<&2, List<&2, U32>>, s: TsxSt) -> IO(TsxNx):
  (r, m) = x
  IO.pure(TsxNx, tsx.next.chk(r, tsx.feed(s, m)))

def tsx.next.line(r: S.Rd, s: TsxSt) -> IO(TsxNx):
  do IO<TsxNx>:
    x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(r)
    tsx.next.got(x, s)

# Lines are fed until an expression is ready or the file ends.  The fuel
# bounds the lines one expression may span (a string may hold newlines).
def tsx.next.go(fuel: Nat, n: TsxNx) -> IO(TsxRd & Maybe<&2, Sx>):
  match fuel n:
    case _ TsxNx{r, s, eof, Some{x}}:
      IO.pure(TsxRd & Maybe<&2, Sx>, (TsxRd{r, s}, Some{x}))
    case _ TsxNx{r, s, True{}, None{}}:
      IO.pure(TsxRd & Maybe<&2, Sx>, (TsxRd{r, s}, None{}))
    case 0n TsxNx{r, s, False{}, None{}}:
      IO.pure(TsxRd & Maybe<&2, Sx>, (TsxRd{r, s}, None{}))
    case 1n+p TsxNx{r, s, False{}, None{}}:
      IO.bind(TsxNx, TsxRd & Maybe<&2, Sx>, tsx.next.line(r, s), tsx.next.go(p))

# the next top-level expression of the file, or None at its end
def tsx.next(t: TsxRd) -> IO(TsxRd & Maybe<&2, Sx>):
  match t:
    case TsxRd{r, s}:
      tsx.next.go(1000000n, tsx.next.chk(r, (s, False{})))
