import Base
import ../Sys.bend as S
import ../Units.bend as U
import ../Transcript.bend as T
import ../Spec/Form2.bend as F2

# exlaw's texts (CorpusV2/Exlaw.bend, 2026-11-13; docs/form2/KINDS.md "3. Laws"): pure: a
# declaration's types read, the probe's inputs and law, the values Bend printed, the example
# laws and the file's own, the record with its laws.  Laws at the end; every def is prefixed `ex.`.

# Bytes ---------------------------------------------------------------------------------

def ex.open(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 91)), Bool.or(U32.is_eq(c, 123), U32.is_eq(c, 60)))

def ex.close(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 41), U32.is_eq(c, 93)), Bool.or(U32.is_eq(c, 125), U32.is_eq(c, 62)))

def ex.trim(+x: List<&2, U32>) -> List<&2, U32>:
  U.trim.right(T.lead.trim(x))

# xs cut at each byte s outside brackets ( [ { < and string and char literals.
# Linear: the depth is a U32 (a Nat is unary: copying and comparing it cost
# its size) and a step builds only the branch it takes (Bool.pick builds both:
# it reversed the piece so far at every byte, 11 h on a 2.7 MB `- expected`,
# 2026-11-13).
type ExSp is Data:
  ExSp{cur: List<&2, U32>, acc: List<&2, List<&2, U32>>}

def ex.sp.put(cut: Bool, +h: U32, cur: List<&2, U32>, acc: List<&2, List<&2, U32>>) -> ExSp:
  match cut:
    case True{}:
      ExSp{Nil{}, List.reverse(&2, U32, cur) <> acc}
    case False{}:
      ExSp{h <> cur, acc}

def ex.sp.step(cut: Bool, +h: U32, st: ExSp) -> ExSp:
  match st:
    case ExSp{cur, acc}:
      ex.sp.put(cut, h, cur, acc)

def ex.sp.end(st: ExSp) -> List<&2, List<&2, U32>>:
  match st:
    case ExSp{cur, acc}:
      List.reverse(&2, List<&2, U32>, List.reverse(&2, U32, cur) <> acc)

# one bracket less, never below none
def ex.sp.out(+d: U32) -> U32:
  Bool.pick(U32, U32.is_eq(d, 0), 0, U32.sub(d, 1))

def ex.sp.go(xs: List<&2, U32>, +s: U32, st: ExSp, +d: U32, +q: U32, +esc: Bool) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      ex.sp.end(st)
    case +h <> t:
      +inq = Bool.not(U32.is_eq(q, 0))
      +shut = Bool.and(U32.is_eq(h, q), Bool.not(esc))
      +opens = Bool.or(U32.is_eq(h, 34), U32.is_eq(h, 39))
      +q2 = Bool.pick(U32, inq, Bool.pick(U32, shut, 0, q), Bool.pick(U32, opens, h, 0))
      +esc2 = Bool.and(inq, Bool.and(U32.is_eq(h, 92), Bool.not(esc)))
      +d2 = Bool.pick(U32, inq, d, Bool.pick(U32, ex.open(h), U32.add(d, 1), Bool.pick(U32, ex.close(h), ex.sp.out(d), d)))
      +cut = Bool.and(Bool.not(inq), Bool.and(U32.is_eq(d, 0), U32.is_eq(h, s)))
      ex.sp.go(t, s, ex.sp.step(cut, h, st), d2, q2, esc2)

def ex.sp(+xs: List<&2, U32>, +s: U32) -> List<&2, List<&2, U32>>:
  ex.sp.go(xs, s, ExSp{Nil{}, Nil{}}, 0, 0, False{})

def ex.trims(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      ex.trim(x) <> ex.trims(t)

def ex.count(+xs: List<&2, List<&2, U32>>) -> Nat:
  List.length(&2, List<&2, U32>, xs)

def ex.last(xs: List<&2, U32>, +d: U32) -> U32:
  match xs:
    case Nil{}:
      d
    case +h <> t:
      ex.last(t, h)

# x less its first and last bytes
def ex.inner(+x: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, List.drop(&2, U32, x, 1n), Nat.sub(U.len(x), 2n))

def ex.wrapped(+x: List<&2, U32>, +a: U32, +z: U32) -> Bool:
  Bool.and(Nat.is_lt(1n, U.len(x)), Bool.and(T.head.is(x, a), U32.is_eq(ex.last(x, 0), z)))

# The types --------------------------------------------------------------------------------

type ExT is Data:
  ExNat{}
  ExU32{}
  ExBool{}
  ExChar{}
  ExStr{}
  ExList{t: ExT}
  ExPair{a: ExT, b: ExT}
  ExAdt{name: List<&2, U32>}
  ExMaybe{t: ExT}
  ExFlds{a: ExT, b: ExT}
  ExFld0{}
  ExBad{}

def ex.base(+y: List<&2, U32>) -> ExT:
  Bool.pick(ExT, U.eq(y, U.b("Nat")), ExNat{}, Bool.pick(ExT, U.eq(y, U.b("U32")), ExU32{}, Bool.pick(ExT, U.eq(y, U.b("Bool")), ExBool{},
    Bool.pick(ExT, U.eq(y, U.b("Char")), ExChar{}, Bool.pick(ExT, U.eq(y, U.b("String")), ExStr{}, ExBad{})))))

# The file's own data types (2026-11-14; the user: "Laws in the request, as
# the spec"; R6's exlaw passed over 174,486 units as not data, most of them
# for a type of their own file, as HInt): a `type NAME is Data:` of the
# unit's head (field 5) without type parameters, its constructors a line
# each, `  C{f: T, g: U}` or `  C{}`.  A parameter or result of such a type
# is data; its inputs are built from the constructors (ex.gen).

type ExC is Data:
  ExC{name: List<&2, U32>, fs: List<&2, List<&2, U32>>}

type ExTy is Data:
  ExTy{name: List<&2, U32>, cs: List<&2, ExC>}

# `type NAME is Data:` (no `<`): NAME; none when the line is not one
def ex.ty.head(+l: List<&2, U32>) -> List<&2, U32>:
  +ok = Bool.and(U.prefix(l, U.b("type ")), U.suffix(l, U.b(" is Data:")))
  +n = ex.trim(List.take(&2, U32, List.drop(&2, U32, l, 5n), Nat.sub(U.len(l), 14n)))
  Bool.pick(List<&2, U32>, Bool.and(ok, Bool.and(Bool.not(U.has(n, 60)), T.f3.namehd(n))), n, Nil{})

# a field's type text: after its `:` (none: no `:`)
def ex.field.ty(+f: List<&2, U32>) -> List<&2, U32>:
  +q = ex.trim(f)
  +at = U.find(q, [58], 0n)
  Bool.pick(List<&2, U32>, Nat.is_eq(at, U.len(q)), Nil{}, ex.trim(List.drop(&2, U32, q, 1n+at)))

def ex.field.tys(fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fs:
    case Nil{}:
      Nil{}
    case +f <> t:
      ex.field.ty(f) <> ex.field.tys(t)

# an indented constructor line: [C and its fields' type texts] (none: not one)
def ex.ctor.of(+l: List<&2, U32>) -> List<&2, ExC>:
  +t = ex.trim(l)
  +at = U.find(t, [123], 0n)
  +name = List.take(&2, U32, t, at)
  +inside = ex.trim(ex.inner(List.drop(&2, U32, t, at)))
  +ok = Bool.and(Bool.and(T.head.is(l, 32), T.f3.namehd(name)), Bool.and(Nat.is_lt(at, U.len(t)), U32.is_eq(ex.last(t, 0), 125)))
  +fs = Bool.pick(List<&2, List<&2, U32>>, T.empty(inside), Nil{}, ex.field.tys(ex.sp(inside, 44)))
  Bool.pick(List<&2, ExC>, ok, [ExC{name, fs}], Nil{})

# reading the head a line at a time: the type being read (none: none), its
# constructors so far (newest first), the types read
type ExTs is Data:
  ExTs{cur: List<&2, U32>, cs: List<&2, ExC>, acc: List<&2, ExTy>}

def ExTs.cur(+s: ExTs) -> List<&2, U32>:
  match s:
    case ExTs{c, x, a}:
      c

def ex.tys.put(none: Bool, +cur: List<&2, U32>, cs: List<&2, ExC>, acc: List<&2, ExTy>) -> List<&2, ExTy>:
  match none:
    case True{}:
      acc
    case False{}:
      ExTy{cur, List.reverse(&2, ExC, cs)} <> acc

# a line's step: 1 a type's head, 2 a constructor of the type read, 3 a blank
# or comment line inside it, 0 any other (the type read ends)
def ex.tys.k(+l: List<&2, U32>, +inside: Bool, +h: List<&2, U32>, +c: List<&2, ExC>) -> Nat:
  +gap = Bool.or(U.blank(l), T.head.is(T.lead.trim(l), 35))
  Bool.pick(Nat, Bool.not(T.empty(h)), 1n, Bool.pick(Nat, Bool.and(inside, Nat.is_lt(0n, List.length(&2, ExC, c))), 2n,
    Bool.pick(Nat, Bool.and(inside, gap), 3n, 0n)))

def ex.tys.on.k(k: Nat, +h: List<&2, U32>, c: List<&2, ExC>, +cur: List<&2, U32>, cs: List<&2, ExC>, acc: List<&2, ExTy>) -> ExTs:
  match k:
    case 0n:
      ExTs{Nil{}, Nil{}, ex.tys.put(T.empty(cur), cur, cs, acc)}
    case 1n:
      ExTs{h, Nil{}, ex.tys.put(T.empty(cur), cur, cs, acc)}
    case 2n:
      ExTs{cur, List.append(&2, ExC, c, cs), acc}
    case _:
      ExTs{cur, cs, acc}

def ex.tys.on(+k: Nat, +h: List<&2, U32>, c: List<&2, ExC>, st: ExTs) -> ExTs:
  match st:
    case ExTs{+cur, cs, acc}:
      ex.tys.on.k(k, h, c, cur, cs, acc)

def ex.tys.end(st: ExTs) -> List<&2, ExTy>:
  match st:
    case ExTs{+cur, cs, acc}:
      ex.tys.put(T.empty(cur), cur, cs, acc)

def ex.tys.go(ls: List<&2, List<&2, U32>>, +st: ExTs) -> List<&2, ExTy>:
  match ls:
    case Nil{}:
      ex.tys.end(st)
    case +l <> t:
      +h = ex.ty.head(l)
      +c = ex.ctor.of(l)
      ex.tys.go(t, ex.tys.on(ex.tys.k(l, Bool.not(T.empty(ExTs.cur(st))), h, c), h, c, st))

# the head's types
def ex.tbl(+head: List<&2, U32>) -> List<&2, ExTy>:
  ex.tys.go(T.split(head, 10), ExTs{Nil{}, Nil{}, Nil{}})

# a type's constructors (none: the head has no such type)
def ex.tbl.cs(ts: List<&2, ExTy>, +n: List<&2, U32>) -> List<&2, ExC>:
  match ts:
    case Nil{}:
      Nil{}
    case ExTy{+m, cs} <> t:
      Bool.pick(List<&2, ExC>, U.eq(m, n), cs, ex.tbl.cs(t, n))

def ex.tbl.has(+ts: List<&2, ExTy>, +n: List<&2, U32>) -> Bool:
  Nat.is_lt(0n, List.length(&2, ExC, ex.tbl.cs(ts, n)))

def ex.is.bad(t: ExT) -> Bool:
  match t:
    case ExBad{}:
      True{}
    case _:
      False{}

# a name: Base's data, else a type of the head, else not data
def ex.base.in(+tb: List<&2, ExTy>, +y: List<&2, U32>) -> ExT:
  +b = ex.base(y)
  Bool.pick(ExT, Bool.and(ex.is.bad(b), ex.tbl.has(tb, y)), ExAdt{y}, b)

# a type text's form: 1 a pair (a top-level `&`), 2 parenthesized, 3 a
# `List<&2, T>`, 4 a `Maybe<&2, T>` (2026-11-14), 0 a name (or none of
# these: Bad)
def ex.kind(+y: List<&2, U32>) -> Nat:
  +pair = Nat.is_lt(1n, ex.count(ex.sp(y, 38)))
  +paren = ex.wrapped(y, 40, 41)
  +list = Bool.and(U.prefix(y, U.b("List<&2,")), U32.is_eq(ex.last(y, 0), 62))
  +maybe = Bool.and(U.prefix(y, U.b("Maybe<&2,")), U32.is_eq(ex.last(y, 0), 62))
  Bool.pick(Nat, pair, 1n, Bool.pick(Nat, paren, 2n, Bool.pick(Nat, list, 3n, Bool.pick(Nat, maybe, 4n, 0n))))

def ex.maybe.of(+y: List<&2, U32>) -> List<&2, U32>:
  ex.trim(List.take(&2, U32, List.drop(&2, U32, y, 9n), Nat.sub(U.len(y), 10n)))

def ex.pair.l(+y: List<&2, U32>) -> List<&2, U32>:
  T.field(ex.sp(y, 38), 0n)

def ex.pair.r(+y: List<&2, U32>) -> List<&2, U32>:
  T.mg.join(List.drop(&2, List<&2, U32>, ex.sp(y, 38), 1n), [38])

def ex.list.of(+y: List<&2, U32>) -> List<&2, U32>:
  ex.trim(List.take(&2, U32, List.drop(&2, U32, y, 8n), Nat.sub(U.len(y), 9n)))

# a type text (trimmed) read: k its form (ex.kind); fuel bounds the nesting;
# tb the head's types
def ex.ty(fuel: Nat, k: Nat, +tb: List<&2, ExTy>, +y: List<&2, U32>) -> ExT:
  match fuel:
    case 0n:
      ExBad{}
    case 1n+ +f:
      match k:
        case 0n:
          ex.base.in(tb, y)
        case 1n:
          +a = ex.trim(ex.pair.l(y))
          +b = ex.trim(ex.pair.r(y))
          ExPair{ex.ty(f, ex.kind(a), tb, a), ex.ty(f, ex.kind(b), tb, b)}
        case 2n:
          +z = ex.trim(ex.inner(y))
          ex.ty(f, ex.kind(z), tb, z)
        case 3n:
          +z = ex.list.of(y)
          ExList{ex.ty(f, ex.kind(z), tb, z)}
        case _:
          +z = ex.maybe.of(y)
          ExMaybe{ex.ty(f, ex.kind(z), tb, z)}

def ex.type.in(+tb: List<&2, ExTy>, +x: List<&2, U32>) -> ExT:
  +y = ex.trim(x)
  Bool.pick(ExT, U.infix(y, U.b("->")), ExBad{}, ex.ty(8n, ex.kind(y), tb, y))

def ex.type(+x: List<&2, U32>) -> ExT:
  ex.type.in(Nil{}, x)

def ex.ok(t: ExT) -> Bool:
  match t:
    case ExList{u}:
      ex.ok(u)
    case ExMaybe{u}:
      ex.ok(u)
    case ExPair{a, b}:
      Bool.and(ex.ok(a), ex.ok(b))
    case ExBad{}:
      False{}
    case _:
      True{}

def ex.oks(ts: List<&2, ExT>) -> Bool:
  match ts:
    case Nil{}:
      True{}
    case +t <> more:
      Bool.and(ex.ok(t), ex.oks(more))

# a type as a law writes it (a pair in parentheses)
def ex.tyt(t: ExT) -> List<&2, U32>:
  match t:
    case ExNat{}:
      U.b("Nat")
    case ExU32{}:
      U.b("U32")
    case ExBool{}:
      U.b("Bool")
    case ExChar{}:
      U.b("Char")
    case ExStr{}:
      U.b("String")
    case ExList{u}:
      T.cat([U.b("List<&2, "), ex.tyt(u), U.b(">")])
    case ExPair{a, b}:
      T.cat([U.b("("), ex.tyt(a), U.b(" & "), ex.tyt(b), U.b(")")])
    case ExAdt{n}:
      n
    case ExMaybe{u}:
      T.cat([U.b("Maybe<&2, "), ex.tyt(u), U.b(">")])
    case ExFlds{a, b}:
      U.b("?")
    case ExFld0{}:
      U.b("?")
    case ExBad{}:
      U.b("?")

# Inputs ----------------------------------------------------------------------------------------

def ex.nth(xs: List<&2, String>, +i: Nat) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      Bool.pick(String, Nat.is_eq(i, 0n), x, ex.nth(t, Nat.sub(i, 1n)))

def ex.pick(+xs: List<&2, String>, +i: Nat) -> List<&2, U32>:
  U.b(ex.nth(xs, Nat.mod(i, List.length(&2, String, xs))))

# the i-th input of a type: small pools (lists: empty, one, three with a
# repeat or out of order)
def ex.val(t: ExT, +i: Nat) -> List<&2, U32>:
  match t:
    case ExNat{}:
      +xs : List<&2, String> = ["0n", "1n", "2n", "3n", "5n"]
      ex.pick(xs, i)
    case ExU32{}:
      +xs : List<&2, String> = ["0", "1", "2", "7", "42"]
      ex.pick(xs, i)
    case ExBool{}:
      +xs : List<&2, String> = ["True{}", "False{}"]
      ex.pick(xs, i)
    case ExChar{}:
      +xs : List<&2, String> = ["'a'", "'z'", "'0'", "' '"]
      ex.pick(xs, i)
    case ExStr{}:
      +xs : List<&2, String> = ["\"\"", "\"ab\"", "\"hello\"", "\"a b\""]
      ex.pick(xs, i)
    case ExList{+u}:
      +k = Nat.mod(i, 4n)
      Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), U.b("[]"),
        Bool.pick(List<&2, U32>, Nat.is_eq(k, 1n), T.cat([U.b("["), ex.val(u, 1n), U.b("]")]),
          Bool.pick(List<&2, U32>, Nat.is_eq(k, 2n), T.cat([U.b("["), ex.val(u, 3n), U.b(", "), ex.val(u, 1n), U.b(", "), ex.val(u, 2n), U.b("]")]),
            T.cat([U.b("["), ex.val(u, 2n), U.b(", "), ex.val(u, 2n), U.b(", "), ex.val(u, 4n), U.b("]")]))))
    case ExPair{a, b}:
      T.cat([U.b("("), ex.val(a, i), U.b(", "), ex.val(b, 1n+i), U.b(")")])
    case ExAdt{n}:
      Nil{}
    case ExMaybe{u}:
      Nil{}
    case ExFlds{a, b}:
      Nil{}
    case ExFld0{}:
      Nil{}
    case ExBad{}:
      Nil{}

# Inputs of every type, the head's own too: what ex.gen builds.  A def may
# only call itself and those above it, and a self-call must shrink its
# arguments read left to right, so: fuel first, one less at every nesting
# (a head's type, a list, a pair, a constructor's fields), then the type.
# The i-th value of a head's type: its constructor i mod k (with little fuel
# left, its first constructor without fields when it has one), its fields'
# values from i + 1 on, the fields as a balanced tree of ExFlds (so a
# constructor's last field has about as much fuel as its first).  With no
# fuel: Base's values, a list's `[]`, a head type's first constructor
# without fields.  A byte 0 in the text marks no value: such a call is not
# probed.

# the first constructor without fields, `C{}` (none: the no-value mark)
def ex.leaf(cs: List<&2, ExC>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      [0]
    case ExC{+n, fs} <> t:
      Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, fs), 0n), U.append(n, U.b("{}")), ex.leaf(t))

def ExC.name(+c: ExC) -> List<&2, U32>:
  match c:
    case ExC{n, fs}:
      n

def ExC.fs(+c: ExC) -> List<&2, List<&2, U32>>:
  match c:
    case ExC{n, fs}:
      fs

def ex.nth.c(cs: List<&2, ExC>, +i: Nat) -> ExC:
  match cs:
    case Nil{}:
      ExC{Nil{}, Nil{}}
    case +c <> t:
      Bool.pick(ExC, Nat.is_eq(i, 0n), c, ex.nth.c(t, Nat.sub(i, 1n)))

# a constructor's fields (type texts) as one type: none ExFld0, one its own,
# more a balanced ExFlds; fuel bounds the halving
def ex.flds(fuel: Nat, +tb: List<&2, ExTy>, +fts: List<&2, List<&2, U32>>) -> ExT:
  match fuel:
    case 0n:
      ExBad{}
    case 1n+ +f:
      +n = List.length(&2, List<&2, U32>, fts)
      +h = Nat.div(n, 2n)
      Bool.pick(ExT, Nat.is_eq(n, 0n), ExFld0{}, Bool.pick(ExT, Nat.is_eq(n, 1n), ex.type.in(tb, T.field(fts, 0n)),
        ExFlds{ex.flds(f, tb, List.take(&2, List<&2, U32>, fts, h)), ex.flds(f, tb, List.drop(&2, List<&2, U32>, fts, h))}))

# the constructor a head type's i-th value takes (low: little fuel left)
def ex.ctor.at(+cs: List<&2, ExC>, +i: Nat, +low: Bool) -> ExC:
  +k = List.length(&2, ExC, cs)
  +lf = ex.leaf(cs)
  +leaf = Bool.not(U.has(lf, 0))
  Bool.pick(ExC, Bool.and(low, leaf), ExC{List.take(&2, U32, lf, Nat.sub(U.len(lf), 2n)), Nil{}}, ex.nth.c(cs, Nat.mod(i, Nat.max(k, 1n))))

def ex.gen(fuel: Nat, t: ExT, +tb: List<&2, ExTy>, +i: Nat) -> List<&2, U32>:
  match fuel:
    case 0n:
      match t:
        case ExAdt{+n}:
          ex.leaf(ex.tbl.cs(tb, n))
        case ExList{u}:
          U.b("[]")
        case ExMaybe{u}:
          U.b("None{}")
        case ExFld0{}:
          Nil{}
        case ExNat{}:
          ex.val(ExNat{}, i)
        case ExU32{}:
          ex.val(ExU32{}, i)
        case ExBool{}:
          ex.val(ExBool{}, i)
        case ExChar{}:
          ex.val(ExChar{}, i)
        case ExStr{}:
          ex.val(ExStr{}, i)
        case _:
          [0]
    case 1n+ +f:
      match t:
        case ExAdt{+n}:
          +cs = ex.tbl.cs(tb, n)
          +c = ex.ctor.at(cs, i, Nat.is_lt(f, 2n))
          Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, ExC, cs), 0n), [0],
            T.cat([ExC.name(c), U.b("{"), ex.gen(f, ex.flds(4n, tb, ExC.fs(c)), tb, 1n+i), U.b("}")]))
        case ExList{+u}:
          +k = Nat.mod(i, 4n)
          Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), U.b("[]"),
            Bool.pick(List<&2, U32>, Nat.is_eq(k, 1n), T.cat([U.b("["), ex.gen(f, u, tb, 1n), U.b("]")]),
              Bool.pick(List<&2, U32>, Nat.is_eq(k, 2n), T.cat([U.b("["), ex.gen(f, u, tb, 3n), U.b(", "), ex.gen(f, u, tb, 1n), U.b(", "), ex.gen(f, u, tb, 2n), U.b("]")]),
                T.cat([U.b("["), ex.gen(f, u, tb, 2n), U.b(", "), ex.gen(f, u, tb, 2n), U.b(", "), ex.gen(f, u, tb, 4n), U.b("]")]))))
        case ExPair{a, b}:
          T.cat([U.b("("), ex.gen(f, a, tb, i), U.b(", "), ex.gen(f, b, tb, 1n+i), U.b(")")])
        case ExMaybe{+u}:
          Bool.pick(List<&2, U32>, Nat.is_eq(Nat.mod(i, 3n), 0n), U.b("None{}"), T.cat([U.b("Some{"), ex.gen(f, u, tb, i), U.b("}")]))
        case ExFlds{a, b}:
          T.cat([ex.gen(f, a, tb, i), U.b(", "), ex.gen(f, b, tb, Nat.add(i, 3n))])
        case ExFld0{}:
          Nil{}
        case ExBad{}:
          [0]
        case ExNat{}:
          ex.val(ExNat{}, i)
        case ExU32{}:
          ex.val(ExU32{}, i)
        case ExBool{}:
          ex.val(ExBool{}, i)
        case ExChar{}:
          ex.val(ExChar{}, i)
        case ExStr{}:
          ex.val(ExStr{}, i)

# a call's arguments: parameter j of call k at base + k + 2j
def ex.args(ps: List<&2, ExT>, +i: Nat) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      ex.val(p, i) <> ex.args(more, Nat.add(i, 2n))

def ex.call(+name: List<&2, U32>, +ps: List<&2, ExT>, +i: Nat) -> List<&2, U32>:
  T.cat([name, U.b("("), T.mg.join(ex.args(ps, i), U.b(", ")), U.b(")")])

def ex.calls.go(k: Nat, +name: List<&2, U32>, +ps: List<&2, ExT>, +i: Nat) -> List<&2, List<&2, U32>>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      ex.call(name, ps, i) <> ex.calls.go(j, name, ps, 1n+i)

# the calls probed (no parameters: one), each once
def ex.calls(+name: List<&2, U32>, +ps: List<&2, ExT>, +base: Nat) -> List<&2, List<&2, U32>>:
  +k = Bool.pick(Nat, Nat.is_eq(List.length(&2, ExT, ps), 0n), 1n, 3n)
  T.f3.dedupe(ex.calls.go(k, name, ps, base), Nil{})

# the same through ex.gen (the head's types tb, FUEL 3), a call with no
# value for some argument left out
def ex.args.in(ps: List<&2, ExT>, +tb: List<&2, ExTy>, +i: Nat) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      ex.gen(6n, p, tb, i) <> ex.args.in(more, tb, Nat.add(i, 2n))

def ex.call.in(+tb: List<&2, ExTy>, +name: List<&2, U32>, +ps: List<&2, ExT>, +i: Nat) -> List<&2, U32>:
  +x = T.cat([name, U.b("("), T.mg.join(ex.args.in(ps, tb, i), U.b(", ")), U.b(")")])
  Bool.pick(List<&2, U32>, U.has(x, 0), Nil{}, x)

def ex.calls.in.go(k: Nat, +tb: List<&2, ExTy>, +name: List<&2, U32>, +ps: List<&2, ExT>, +i: Nat) -> List<&2, List<&2, U32>>:
  match k:
    case 0n:
      Nil{}
    case 1n+j:
      +c = ex.call.in(tb, name, ps, i)
      T.mg.keep.on(Bool.not(T.empty(c)), c, ex.calls.in.go(j, tb, name, ps, 1n+i))

def ex.calls.in(+tb: List<&2, ExTy>, +name: List<&2, U32>, +ps: List<&2, ExT>, +base: Nat) -> List<&2, List<&2, U32>>:
  +k = Bool.pick(Nat, Nat.is_eq(List.length(&2, ExT, ps), 0n), 1n, 3n)
  T.f3.dedupe(ex.calls.in.go(k, tb, name, ps, base), Nil{})

# The declaration -------------------------------------------------------------------------------

# the index of the `)` that closes xs's first byte `(`
def ex.close.at(xs: List<&2, U32>, +d: Nat, +i: Nat) -> Nat:
  match xs:
    case Nil{}:
      i
    case +h <> t:
      +d2 = Bool.pick(Nat, U32.is_eq(h, 40), 1n+d, Bool.pick(Nat, U32.is_eq(h, 41), Nat.sub(d, 1n), d))
      Bool.pick(Nat, Bool.and(U32.is_eq(h, 41), Nat.is_eq(d2, 0n)), i, ex.close.at(t, d2, 1n+i))

# a parameter's type (none: Bad): `x: T` or `+x: T`; `-A: Type` and `~x` are not data
def ex.param(+tb: List<&2, ExTy>, +p: List<&2, U32>) -> ExT:
  +q = ex.trim(p)
  +bad = Bool.or(T.head.is(q, 45), T.head.is(q, 126))
  +at = U.find(q, [58], 0n)
  Bool.pick(ExT, Bool.or(bad, Nat.is_eq(at, U.len(q))), ExBad{}, ex.type.in(tb, List.drop(&2, U32, q, 1n+at)))

def ex.params.of(ps: List<&2, List<&2, U32>>, +tb: List<&2, ExTy>) -> List<&2, ExT>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      ex.param(tb, p) <> ex.params.of(more, tb)

# a declaration's parameters and result
type ExSig is Data:
  ExSig{ps: List<&2, ExT>, r: ExT}

def ExSig.ps(+s: ExSig) -> List<&2, ExT>:
  match s:
    case ExSig{p, r}:
      p

def ExSig.r(+s: ExSig) -> ExT:
  match s:
    case ExSig{p, r}:
      r

def ex.sig.ok(+s: ExSig) -> Bool:
  Bool.and(ex.oks(ExSig.ps(s)), ex.ok(ExSig.r(s)))

# `def NAME(PARAMS) -> RESULT:` (its first line; field 6)
def ex.sig(+fs: List<&2, List<&2, U32>>) -> ExSig:
  +name = T.field(fs, 2n)
  +l = S.chomp(S.lines.first(T.field(fs, 6n)))
  +rest = List.drop(&2, U32, l, Nat.add(4n, U.len(name)))
  +shape = Bool.and(U.prefix(l, T.cat([U.b("def "), name, U.b("(")])), S.suffix(l, U.b(":")))
  +c = ex.close.at(rest, 0n, 0n)
  +inside = ex.trim(ex.inner(List.take(&2, U32, rest, 1n+c)))
  +after = ex.trim(List.drop(&2, U32, rest, 1n+c))
  +arrow = U.prefix(after, U.b("->"))
  +res = List.take(&2, U32, List.drop(&2, U32, after, 2n), Nat.sub(U.len(after), 3n))
  +tb = ex.tbl(T.field(fs, 5n))
  +ps = Bool.pick(List<&2, ExT>, T.empty(inside), Nil{}, ex.params.of(ex.sp(inside, 44), tb))
  Bool.pick(ExSig, Bool.and(shape, arrow), ExSig{ps, ex.type.in(tb, res)}, ExSig{[ExBad{}], ExBad{}})

# why a unit gets no laws before any check (none: it may)
def ex.skip(+fs: List<&2, List<&2, U32>>, +s: ExSig) -> List<&2, U32>:
  +bend = S.eq(T.field(fs, 0n), S.b("bend"))
  +pass = S.prefix(T.field(fs, 11n), [48, 31])
  +prop = S.eq(T.field(fs, 1n), S.b("proposition"))
  +had = T.f3.laws(fs)
  Bool.pick(List<&2, U32>, Bool.not(bend), U.b("skip.not-bend"),
    Bool.pick(List<&2, U32>, Bool.not(pass), U.b("skip.check-fails"),
      Bool.pick(List<&2, U32>, prop, U.b("skip.proposition"),
        Bool.pick(List<&2, U32>, Bool.not(T.empty(had)), U.b("skip.has-laws"),
          Bool.pick(List<&2, U32>, Bool.not(ex.sig.ok(s)), U.b("skip.not-data"), Nil{})))))

# The laws -------------------------------------------------------------------------------------

def ex.probe.name(+name: List<&2, U32>) -> List<&2, U32>:
  U.append(name, U.b(".exlaw_probe"))

# R & R & R for n calls (n 1: R)
def ex.rs(n: Nat, +r: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+ +k:
      Bool.pick(List<&2, U32>, Nat.is_eq(k, 0n), r, T.cat([r, U.b(" & "), ex.rs(k, r)]))

def ex.tuple(+cs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(ex.count(cs), 1n), T.field(cs, 0n), T.cat([U.b("("), T.mg.join(cs, U.b(", ")), U.b(")")]))

def ex.probe(+name: List<&2, U32>, +cs: List<&2, List<&2, U32>>, +r: ExT) -> List<&2, U32>:
  +pn = ex.probe.name(name)
  +rt = ex.rs(ex.count(cs), ex.tyt(r))
  T.cat([U.b("\nlaw "), pn, U.b(":\n  for d: "), rt, U.b("\n  {"), ex.tuple(cs), U.b(" == d : "), rt, U.b("}\n\ndef "), pn, U.b("(d):\n  {==}\n")])

# a value a law may state: one line, at most 160 bytes, and outside its
# string and char literals only digits, brackets, commas, blanks, signs and
# the letters of `n`, `True{}`, `False{}`
def ex.litch(+c: U32) -> Bool:
  +ok : List<&2, U32> = U.b("0123456789n[](){}, -+.TrueFals")
  U.has(ok, c)

def ex.lit.go(xs: List<&2, U32>, +q: U32, +esc: Bool) -> Bool:
  match xs:
    case Nil{}:
      U32.is_eq(q, 0)
    case +h <> t:
      +inq = Bool.not(U32.is_eq(q, 0))
      +shut = Bool.and(U32.is_eq(h, q), Bool.not(esc))
      +opens = Bool.or(U32.is_eq(h, 34), U32.is_eq(h, 39))
      +ok = Bool.or(inq, Bool.or(opens, ex.litch(h)))
      +q2 = Bool.pick(U32, inq, Bool.pick(U32, shut, 0, q), Bool.pick(U32, opens, h, 0))
      +esc2 = Bool.and(inq, Bool.and(U32.is_eq(h, 92), Bool.not(esc)))
      Bool.and(Bool.and(ok, Bool.not(U32.is_eq(h, 10))), ex.lit.go(t, q2, esc2))

def ex.lit.old(+v: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Bool.not(T.empty(v)), Nat.is_le(U.len(v), 160n)), ex.lit.go(v, 0, False{}))

# (2026-11-14, the head's own types) a constructor's name before its `{`:
# outside string and char literals, a name (a letter or `_` first, then
# letters, digits, `_` and `.`) not right after a digit must end at a `{`
# (`Circle{3n}`, `True{}`), a letter right after a digit is a Nat's `n`, and
# the other bytes are as before: digits, brackets, commas, blanks, signs and
# `.`; so a stuck call (`f(1n)`), a variable or a lambda is still no value.
def ex.alpha(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 95), Bool.or(Bool.and(U32.is_lt(96, c), U32.is_lt(c, 123)), Bool.and(U32.is_lt(64, c), U32.is_lt(c, 91))))

def ex.digit(+c: U32) -> Bool:
  Bool.and(U32.is_lt(47, c), U32.is_lt(c, 58))

def ex.punct(+c: U32) -> Bool:
  +ok : List<&2, U32> = U.b("[](){}, -+.")
  U.has(ok, c)

# q the open quote (0: none), esc after a backslash in one, nm inside a name,
# pd the byte before was a digit
def ex.lit.go2(xs: List<&2, U32>, +q: U32, +esc: Bool, +nm: Bool, +pd: Bool) -> Bool:
  match xs:
    case Nil{}:
      Bool.and(U32.is_eq(q, 0), Bool.not(nm))
    case +h <> t:
      +inq = Bool.not(U32.is_eq(q, 0))
      +shut = Bool.and(U32.is_eq(h, q), Bool.not(esc))
      +opens = Bool.or(U32.is_eq(h, 34), U32.is_eq(h, 39))
      +namech = Bool.or(ex.alpha(h), Bool.or(ex.digit(h), U32.is_eq(h, 46)))
      +starts = Bool.and(ex.alpha(h), Bool.not(pd))
      +natn = Bool.and(pd, U32.is_eq(h, 110))
      +nm2 = Bool.and(Bool.not(inq), Bool.or(Bool.and(nm, namech), Bool.and(Bool.not(nm), starts)))
      +ends = Bool.and(nm, Bool.not(namech))
      +ok = Bool.or(inq, Bool.or(nm2, Bool.or(natn, Bool.and(Bool.or(opens, Bool.or(ex.digit(h), ex.punct(h))), Bool.or(Bool.not(ends), U32.is_eq(h, 123))))))
      +q2 = Bool.pick(U32, inq, Bool.pick(U32, shut, 0, q), Bool.pick(U32, opens, h, 0))
      +esc2 = Bool.and(inq, Bool.and(U32.is_eq(h, 92), Bool.not(esc)))
      Bool.and(Bool.and(ok, Bool.not(U32.is_eq(h, 10))), ex.lit.go2(t, q2, esc2, nm2, Bool.and(Bool.not(inq), ex.digit(h))))

def ex.lit(+v: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Bool.not(T.empty(v)), Nat.is_le(U.len(v), 160n)), ex.lit.go2(v, 0, False{}, False{}, False{}))

# the values the probe's check printed, one a call (none: it printed none, or
# not as many)
def ex.values(+out: List<&2, U32>, +n: Nat) -> List<&2, List<&2, U32>>:
  +v = ex.trim(U.strip(T.mg.find(T.split(out, 10), U.b("- expected : ")), U.b("- expected : ")))
  +vs = Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(n, 1n), [v], Bool.pick(List<&2, List<&2, U32>>, ex.wrapped(v, 40, 41), ex.trims(ex.sp(ex.inner(v), 44)), Nil{}))
  Bool.pick(List<&2, List<&2, U32>>, Bool.and(Bool.not(T.empty(v)), Nat.is_eq(ex.count(vs), n)), vs, Nil{})

# an example law: `law NAME.exK: {CALL == V : R}`, its proof `{==}`
def ex.law(+name: List<&2, U32>, +k: Nat, +c: List<&2, U32>, +v: List<&2, U32>, +r: List<&2, U32>) -> List<&2, U32>:
  +ln = T.cat([name, U.b(".ex"), T.mg.n(k)])
  T.cat([U.b("law "), ln, U.b(":\n  {"), c, U.b(" == "), v, U.b(" : "), r, U.b("}\n\ndef "), ln, U.b("():\n  {==}\n")])

# the examples: each call with its value, the literals only, numbered from 1
def ex.examples(cs: List<&2, List<&2, U32>>, +vs: List<&2, List<&2, U32>>, +i: Nat, +name: List<&2, U32>, +r: List<&2, U32>, +k: Nat) -> List<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> ct:
      +v = T.field(vs, i)
      +ok = ex.lit(v)
      +rest = ex.examples(ct, vs, 1n+i, name, r, Bool.pick(Nat, ok, 1n+k, k))
      Bool.pick(List<&2, List<&2, U32>>, ok, ex.law(name, k, c, v, r) <> rest, rest)

# the file's own laws: the `law` pieces right after the declaration that use
# NAME, each with its proof's `def` (the source's text, gaps left out)
def ex.flaws.go(ds: List<&2, F2.Piece<List<&2, U32>, List<&2, U32>>>, +name: List<&2, U32>, +taken: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ds:
    case Nil{}:
      Nil{}
    case F2.Piece{+nm, +b, g} <> t:
      +x = U.concat(b)
      +islaw = Bool.and(U.prefix(x, U.b("law ")), T.f3.uses(x, name))
      +proof = Bool.and(U.prefix(x, U.b("def ")), T.f3.in(taken, nm))
      Bool.pick(List<&2, List<&2, U32>>, Bool.or(islaw, proof), U.append(T.mg.chomp(x), U.b("\n")) <> ex.flaws.go(t, name, nm <> taken), Nil{})

def ex.flaws.d(+d: F2.Doc<List<&2, U32>, List<&2, U32>>, +name: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match d:
    case F2.Doc{+p, +g, ds}:
      ex.flaws.go(ds, name, Nil{})

def ex.flaws(+fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  ex.flaws.d(T.f2.bdoc(T.field(fs, 8n)), T.field(fs, 2n))

# a law text: a blank line, then each law and its proof, a blank line between
def ex.laws.text(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(ex.count(ls), 0n), Nil{}, U.append(U.b("\n"), T.mg.join(ls, U.b("\n"))))

# The record -----------------------------------------------------------------------------------

# the unit's record with its laws in field 14 and the new mutants (body,
# check) after its old ones
def ex.with(+fs: List<&2, List<&2, U32>>, +laws: List<&2, U32>, +news: List<&2, List<&2, U32>>) -> List<&2, U32>:
  T.mg.join(List.concat(&2, List<&2, U32>, [List.take(&2, List<&2, U32>, fs, 14n), [laws], List.drop(&2, List<&2, U32>, fs, 15n), news]), [30])

# the line `Location: NAME` names
def ex.at(+out: List<&2, U32>) -> List<&2, U32>:
  ex.trim(U.strip(T.mg.find(T.split(out, 10), U.b("Location: ")), U.b("Location: ")))

# a law mutant: rejected (exit 1) at one of the laws lns
def ex.at.law(+st: U32, +ck: List<&2, U32>, +lns: List<&2, List<&2, U32>>) -> Bool:
  Bool.and(U32.is_eq(st, 1), T.f3.in(lns, ex.at(T.check.out(T.check.of(ck)))))

# the operators that keep a program well-typed: swap-arms, drop-line,
# swap-args, ctor-swap, lit-value, var-swap
def ex.typed.op(+o: Nat) -> Bool:
  Bool.or(Bool.or(Bool.or(Nat.is_eq(o, 1n), Nat.is_eq(o, 2n)), Bool.or(Nat.is_eq(o, 3n), Nat.is_eq(o, 5n))), Bool.or(Nat.is_eq(o, 7n), Nat.is_eq(o, 9n)))

# the form mix-up of a body (none: it has no `(&2, ` and no `(~`)
def ex.form.of(+body: List<&2, U32>) -> List<&2, U32>:
  +a = S.replace.first(body, U.b("(&2, "), U.b("("))
  +b = S.replace.first(body, U.b("(~"), U.b("("))
  Bool.pick(List<&2, U32>, Bool.not(S.eq(a, body)), a, Bool.pick(List<&2, U32>, Bool.not(S.eq(b, body)), b, Nil{}))

def ex.reps(n: Nat, +k: String) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+j:
      k <> ex.reps(j, k)


# Laws ------------------------------------------------------------------------------------------
#
# On small texts written here: a type read and written back, what is not
# data, a declaration's parameters, the probe's law, the values Bend printed
# cut at the top-level commas (not the ones in a string), what a law may
# state, the calls each once, the laws in field 14.

def ex.fs.of(+decl: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +e : List<&2, U32> = Nil{}
  [U.b("bend"), U.b("type"), U.b("f"), e, e, e, decl, e, e, e, e, U.b("0\u{1F}ALL PROOFS CHECK"), e, e, e]

law ex.type.list:
  {ex.tyt(ex.type(U.b("List<&2, Nat>"))) == U.b("List<&2, Nat>") : List<&2, U32>}

def ex.type.list():
  {==}

law ex.type.pairs:
  {ex.tyt(ex.type(U.b(" (Nat & Bool) & List<&2, String & Char> "))) == U.b("((Nat & Bool) & List<&2, (String & Char)>)") : List<&2, U32>}

def ex.type.pairs():
  {==}

law ex.type.not.data:
  {(ex.ok(ex.type(U.b("Z"))), ex.ok(ex.type(U.b("Nat -> Nat"))), ex.ok(ex.type(U.b("List<&2, Tree<Nat>>")))) == (False{}, False{}, False{}) : Bool & Bool & Bool}

def ex.type.not.data():
  {==}

law ex.sig.data:
  {ex.sig.ok(ex.sig(ex.fs.of(U.b("def f(a: Nat, +b: List<&2, U32>) -> Bool:\n")))) == True{} : Bool}

def ex.sig.data():
  {==}

law ex.sig.none:
  {ex.sig.ok(ex.sig(ex.fs.of(U.b("def f() -> String:\n")))) == True{} : Bool}

def ex.sig.none():
  {==}

law ex.sig.poly:
  {ex.sig.ok(ex.sig(ex.fs.of(U.b("def f(-A: Type, xs: List<&2, A>) -> Nat:\n")))) == False{} : Bool}

def ex.sig.poly():
  {==}

law ex.probe.two:
  {ex.probe(U.b("f"), [U.b("f(1n)"), U.b("f(2n)")], ExNat{}) == U.b("\nlaw f.exlaw_probe:\n  for d: Nat & Nat\n  {(f(1n), f(2n)) == d : Nat & Nat}\n\ndef f.exlaw_probe(d):\n  {==}\n") : List<&2, U32>}

def ex.probe.two():
  {==}

law ex.values.three:
  {ex.values(U.b("SOME PROOFS FAIL\nError:\n- expected : ([1n, 2n], \"a, b\", ',')\n- observed : d\n"), 3n) == [U.b("[1n, 2n]"), U.b("\"a, b\""), U.b("','")] : List<&2, List<&2, U32>>}

def ex.values.three():
  {==}

law ex.values.short:
  {ex.values(U.b("- expected : (1n, 2n)\n"), 3n) == [] : List<&2, List<&2, U32>>}

def ex.values.short():
  {==}

law ex.lit.which:
  {(ex.lit(U.b("[True{}, False{}]")), ex.lit(U.b("\"x => y\"")), ex.lit(U.b("x => x")), ex.lit(U.b("Nat.add(1n)"))) == (True{}, True{}, False{}, False{}) : Bool & Bool & Bool & Bool}

def ex.lit.which():
  {==}

law ex.calls.once:
  {ex.calls(U.b("f"), [ExBool{}], 0n) == [U.b("f(True{})"), U.b("f(False{})")] : List<&2, List<&2, U32>>}

def ex.calls.once():
  {==}

law ex.with.field14:
  {T.field(T.split(ex.with(ex.fs.of(U.b("def f() -> Nat:\n")), U.b("\nlaw f.ex1:\n"), [U.b("m"), U.b("1")]), 30), 14n) == U.b("\nlaw f.ex1:\n") : List<&2, U32>}

def ex.with.field14():
  {==}

law ex.sp.nested:
  {ex.sp(U.b("f(a, [b, c]), d, \"e, f\", ')'"), 44) == [U.b("f(a, [b, c])"), U.b(" d"), U.b(" \"e, f\""), U.b(" ')'")] : List<&2, List<&2, U32>>}

def ex.sp.nested():
  {==}

law ex.sp.unbalanced:
  {ex.sp(U.b("a), b"), 44) == [U.b("a)"), U.b(" b")] : List<&2, List<&2, U32>>}

def ex.sp.unbalanced():
  {==}

# The head's own types (2026-11-14): a head with a sum and a recursive type

def ex.head.eg() -> List<&2, U32>:
  U.b("import Base\n\ntype Shape is Data:\n  Circle{r: Nat}\n  Rect{w: Nat, h: U32}\n  Dot{}\n\n# a tree\ntype Tree is Data:\n  Leaf{}\n  Node{l: Tree, v: Nat, r: Tree}\n\ndef area(s: Shape) -> Nat:\n  0n\n")

def ex.fs.head(+head: List<&2, U32>, +decl: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +e : List<&2, U32> = Nil{}
  [U.b("bend"), U.b("type"), U.b("f"), e, e, head, decl, e, e, e, e, U.b("0\u{1F}ALL PROOFS CHECK"), e, e, e]

law ex.tbl.reads:
  {List.length(&2, ExTy, ex.tbl(ex.head.eg())) == 2n : Nat}

def ex.tbl.reads():
  {==}

law ex.sig.own:
  {(ex.sig.ok(ex.sig(ex.fs.head(ex.head.eg(), U.b("def f(s: Shape, t: Tree) -> List<&2, Shape>:\n")))), ex.sig.ok(ex.sig(ex.fs.head(ex.head.eg(), U.b("def f(z: Z) -> Nat:\n"))))) == (True{}, False{}) : Bool & Bool}

def ex.sig.own():
  {==}

law ex.calls.own:
  {ex.calls.in(ex.tbl(ex.head.eg()), U.b("f"), [ExAdt{U.b("Shape")}], 0n) == [U.b("f(Circle{1n})"), U.b("f(Rect{2n, 0})"), U.b("f(Dot{})")] : List<&2, List<&2, U32>>}

def ex.calls.own():
  {==}

law ex.lit.ctors:
  {(ex.lit(U.b("Node{Leaf{}, 3n, Leaf{}}")), ex.lit(U.b("[Circle{2n}, Dot{}]")), ex.lit(U.b("f(Circle{2n})")), ex.lit(U.b("Circle")), ex.lit(U.b("(+1, \"a\", 'b')"))) == (True{}, True{}, False{}, False{}, True{}) : Bool & Bool & Bool & Bool & Bool}

def ex.lit.ctors():
  {==}

law ex.maybe.reads:
  {(ex.tyt(ex.type(U.b("Maybe<&2, List<&2, Nat>>"))), ex.calls.in(Nil{}, U.b("g"), [ExMaybe{ExNat{}}], 0n)) == (U.b("Maybe<&2, List<&2, Nat>>"), [U.b("g(None{})"), U.b("g(Some{1n})"), U.b("g(Some{2n})")]) : List<&2, U32> & List<&2, List<&2, U32>>}

def ex.maybe.reads():
  {==}
