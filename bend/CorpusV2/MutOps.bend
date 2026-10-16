import Base
import ../Sys.bend as S

# The mutation operators of `bend-corpus-v2 mutate` (CorpusV2/Mutate.bend,
# 2026-10-16): a checked Bend unit's answer (its body, Units.bend's field 7)
# broken the way a person breaks Bend 2 code, each a pure function of the
# text.  An operator gives every mutant it can make of a body, in the order
# of the place it changes (first to last), each the body with one change.
# The laws are bend/tests/mutops.bend.
#
#   0  drop-case    a `case` arm of a match with two or more arms, deleted
#   1  swap-arms    the bodies of two neighbouring arms of a match, swapped
#   2  drop-line    a statement of a block with two or more (a do block's
#                   line, a let line), deleted with its continuation lines
#   3  swap-args    two neighbouring arguments of a call, swapped
#   4  drop-arg     an argument of a call with two or more, deleted
#   5  ctor-swap    a constructor replaced by another of its type (True and
#                   False, Some and None, Done and Fail, Nil and Con, SNil and
#                   SCon, Zero and Succ, Inl and Inr) or by another one the
#                   body's `case` lines lead with
#   6  affine       the `+` dropped from a binder its scope uses twice or more
#   7  lit-value    a numeric literal in a pattern (`case 0n:`, the `1n` of
#                   `1n+p`; in a proof: any) changed: 0 and 1 swapped, any
#                   other one plus one
#   8  lit-suffix   a Nat literal written as a U32 one (`3n` as `3`), or a U32
#                   one as a Nat one
#   9  var-swap     a use of a variable replaced by the variable bound right
#                   before it (else right after it, when that one is bound
#                   before the use): parameters, pattern and let names
#   10 misspell     a called name misspelt: its last letter dropped, its last
#                   two swapped, or its first `_` written `.` (else its first
#                   `.` written `_`)
#   11 type-swap    a type argument or annotation changed (Nat to U32, U32 to
#                   Nat, Bool and String to Nat, U64 to U32, Unit to Bool)
#   12 alias-drop   an import alias's prefix dropped from a qualified name
#                   (`S.read` as `read`, S an `import ... as S` of the head)
#
# The text is read as tokens (`mto.lex`, whose texts joined are the body
# byte for byte): blanks, names (letters, digits, `_`, and a `.` between two
# of them: `Nat.add`, `env_nat.parse`), numbers (`3`, `3n`, `1.5`), strings,
# char literals and `#` comments (opaque: no operator looks inside), and
# punctuation (one byte, or one of the two-byte operators <> <- -> => == !=
# <= >= ++ && ||).  The line operators (0, 1, 2) read the body's lines and
# their indentation.  Every def is prefixed `mto.`.

# Bytes ---------------------------------------------------------------------------------------

def mto.alpha(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), Bool.and(U32.is_le(97, c), U32.is_le(c, 122))), U32.is_eq(c, 95))

def mto.upper(+c: U32) -> Bool:
  Bool.and(U32.is_le(65, c), U32.is_le(c, 90))

def mto.lower(+c: U32) -> Bool:
  Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), U32.is_eq(c, 95))

def mto.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def mto.idch(+c: U32) -> Bool:
  Bool.or(mto.alpha(c), mto.digit(c))

def mto.blank(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 10), U32.is_eq(c, 13)))

# a lookahead: the first, second and third bytes (0 past the end)
def mto.hd(+xs: List<&2, U32>) -> U32:
  match xs:
    case h <> t:
      h
    case Nil{}:
      0

def mto.hd2(+xs: List<&2, U32>) -> U32:
  match xs:
    case h <> t:
      mto.hd(t)
    case Nil{}:
      0

def mto.hd3(+xs: List<&2, U32>) -> U32:
  match xs:
    case h <> t:
      mto.hd2(t)
    case Nil{}:
      0

def mto.len(+xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

def mto.cat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  List.concat(&2, U32, xss)

def mto.empty(+xs: List<&2, U32>) -> Bool:
  List.is_empty(&2, U32, xs)

def mto.all.blank(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(mto.blank(h), mto.all.blank(t))

def mto.all.digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(mto.digit(h), mto.all.digits(t))

def mto.has(xs: List<&2, U32>, +c: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(U32.is_eq(h, c), mto.has(t, c))

# xs with its first c replaced by d (xs when it has none; at: xs leads with c)
def mto.sub.go(xs: List<&2, U32>, +c: U32, +d: U32, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> t True{}:
      d <> t
    case h <> +t False{}:
      h <> mto.sub.go(t, c, d, U32.is_eq(mto.hd(t), c))
    case Nil{} _:
      Nil{}

def mto.sub(+c: U32, +d: U32, +xs: List<&2, U32>) -> List<&2, U32>:
  mto.sub.go(xs, c, d, U32.is_eq(mto.hd(xs), c))

# a list of texts' first (empty when none)
def mto.lhd(+xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case x <> t:
      x
    case Nil{}:
      Nil{}

# Byte strings as a small set (a list) -------------------------------------------------------------

def mto.mem(xs: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(S.eq(h, x), mto.mem(t, x))

def mto.add(+xs: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, mto.mem(xs, x), xs, List.append(&2, List<&2, U32>, xs, [x]))

# the texts less those equal to x, each once, in order
def mto.uniq.go(xs: List<&2, List<&2, U32>>, +x: List<&2, U32>, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +y <> t:
      +keep = Bool.and(Bool.not(S.eq(y, x)), Bool.not(mto.mem(seen, y)))
      +rest = mto.uniq.go(t, x, Bool.pick(List<&2, List<&2, U32>>, keep, y <> seen, seen))
      Bool.pick(List<&2, List<&2, U32>>, keep, y <> rest, rest)

def mto.uniq(+xs: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> List<&2, List<&2, U32>>:
  mto.uniq.go(xs, x, Nil{})

def mto.nonempty(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = mto.nonempty(t)
      Bool.pick(List<&2, List<&2, U32>>, mto.empty(x), rest, x <> rest)

# A table: the value of the first pair whose key is x (empty when none)
type MtoPr is Data:
  MtoPr{a: List<&2, U32>, b: List<&2, U32>}

def mto.pr.hit(+ps: List<&2, MtoPr>, +x: List<&2, U32>) -> Bool:
  match ps:
    case MtoPr{+a, b} <> t:
      S.eq(a, x)
    case Nil{}:
      False{}

def mto.look.go(ps: List<&2, MtoPr>, +x: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match ps at:
    case MtoPr{a, b} <> t True{}:
      b
    case p <> +t False{}:
      mto.look.go(t, x, mto.pr.hit(t, x))
    case Nil{} _:
      Nil{}

def mto.look(+ps: List<&2, MtoPr>, +x: List<&2, U32>) -> List<&2, U32>:
  mto.look.go(ps, x, mto.pr.hit(ps, x))

def mto.pr(+a: String, +b: String) -> MtoPr:
  MtoPr{S.b(a), S.b(b)}

# Tokens ----------------------------------------------------------------------------------------
#
# Kinds: 0 blank, 1 name, 2 number, 3 string, 4 comment, 5 punctuation,
# 6 char literal; 9 none (a token past either end).

type MtoTk is Data:
  MtoTk{k: Nat, t: List<&2, U32>}

def mto.tk.k(+x: MtoTk) -> Nat:
  match x:
    case MtoTk{k, t}:
      k

def mto.tk.t(+x: MtoTk) -> List<&2, U32>:
  match x:
    case MtoTk{k, t}:
      t

def mto.none() -> MtoTk:
  MtoTk{9n, Nil{}}

def mto.tk.is(+x: MtoTk, +k: Nat, +s: String) -> Bool:
  Bool.and(Nat.is_eq(mto.tk.k(x), k), S.eq(mto.tk.t(x), S.b(s)))

def mto.punct(+x: MtoTk, +s: String) -> Bool:
  mto.tk.is(x, 5n, s)

def mto.is.blank(+x: MtoTk) -> Bool:
  Nat.is_eq(mto.tk.k(x), 0n)

def mto.is.name(+x: MtoTk) -> Bool:
  Nat.is_eq(mto.tk.k(x), 1n)

# the two-byte operators
def mto.op2(+a: U32, +b: U32) -> Bool:
  +lt = U32.is_eq(a, 60)
  +gt = U32.is_eq(b, 62)
  +eq = U32.is_eq(b, 61)
  Bool.or(Bool.or(Bool.or(Bool.and(lt, gt), Bool.and(lt, U32.is_eq(b, 45))), Bool.or(Bool.and(U32.is_eq(a, 45), gt), Bool.and(U32.is_eq(a, 61), gt))),
    Bool.or(Bool.or(Bool.and(U32.is_eq(a, 61), eq), Bool.and(U32.is_eq(a, 33), eq)), Bool.or(Bool.or(Bool.and(lt, eq), Bool.and(U32.is_eq(a, 62), eq)),
      Bool.or(Bool.and(U32.is_eq(a, 43), U32.is_eq(b, 43)), Bool.or(Bool.and(U32.is_eq(a, 38), U32.is_eq(b, 38)), Bool.and(U32.is_eq(a, 124), U32.is_eq(b, 124)))))))

# whether byte h goes on with the token of kind k (sub its state, p its last
# byte so far, n the byte after h)
def mto.cont(+k: Nat, +sub: Nat, +p: U32, +h: U32, +n: U32) -> Bool:
  match k:
    case 0n:
      mto.blank(h)
    case 1n:
      Bool.or(mto.idch(h), Bool.and(Bool.and(U32.is_eq(h, 46), mto.idch(p)), mto.alpha(n)))
    case 2n:
      Bool.or(mto.idch(h), Bool.and(Bool.and(U32.is_eq(h, 46), mto.digit(p)), mto.digit(n)))
    case 3n:
      Bool.or(Nat.is_eq(sub, 1n), Bool.and(Nat.is_eq(sub, 0n), Bool.not(U32.is_eq(h, 10))))
    case 4n:
      Bool.not(U32.is_eq(h, 10))
    case 5n:
      Nat.is_eq(sub, 1n)
    case 6n:
      Nat.is_lt(0n, sub)
    case _:
      False{}

# the state after h went on with the token: a string's 0 inside, 1 after a
# backslash, 2 closed; a char literal's bytes still to take
def mto.sub.cont(+k: Nat, +sub: Nat, +h: U32) -> Nat:
  match k:
    case 3n:
      Bool.pick(Nat, Nat.is_eq(sub, 1n), 0n, Bool.pick(Nat, U32.is_eq(h, 92), 1n, Bool.pick(Nat, U32.is_eq(h, 34), 2n, 0n)))
    case 6n:
      Nat.sub(sub, 1n)
    case _:
      0n

# 'x' or '\x' (n, n2, n3: the bytes after the quote)
def mto.charlit(+n: U32, +n2: U32, +n3: U32) -> Bool:
  Bool.or(Bool.and(Bool.and(Bool.not(U32.is_eq(n, 92)), Bool.not(U32.is_eq(n, 39))), Bool.and(Bool.not(U32.is_eq(n, 10)), U32.is_eq(n2, 39))),
    Bool.and(U32.is_eq(n, 92), U32.is_eq(n3, 39)))

# the kind of the token h starts (n, n2, n3: the bytes after it)
def mto.start.k(+h: U32, +n: U32, +n2: U32, +n3: U32) -> Nat:
  Bool.pick(Nat, mto.blank(h), 0n, Bool.pick(Nat, mto.alpha(h), 1n, Bool.pick(Nat, mto.digit(h), 2n,
    Bool.pick(Nat, U32.is_eq(h, 34), 3n, Bool.pick(Nat, U32.is_eq(h, 35), 4n, Bool.pick(Nat, Bool.and(U32.is_eq(h, 39), mto.charlit(n, n2, n3)), 6n, 5n))))))

def mto.start.sub(+k: Nat, +h: U32, +n: U32) -> Nat:
  match k:
    case 5n:
      Bool.pick(Nat, mto.op2(h, n), 1n, 0n)
    case 6n:
      Bool.pick(Nat, U32.is_eq(n, 92), 3n, 2n)
    case _:
      0n

# the token so far (its bytes newest first) onto the tokens (newest first)
def mto.close(+k: Nat, +cur: List<&2, U32>, acc: List<&2, MtoTk>) -> List<&2, MtoTk>:
  match cur:
    case Nil{}:
      acc
    case h <> t:
      MtoTk{k, List.reverse(&2, U32, h <> t)} <> acc

# a byte at a time: it goes on with the token (k, sub, cur) or starts one
def mto.lex.go(xs: List<&2, U32>, +cur: List<&2, U32>, +k: Nat, +sub: Nat, +acc: List<&2, MtoTk>) -> List<&2, MtoTk>:
  match xs:
    case Nil{}:
      List.reverse(&2, MtoTk, mto.close(k, cur, acc))
    case +h <> +t:
      +c = mto.cont(k, sub, mto.hd(cur), h, mto.hd(t))
      +k2 = mto.start.k(h, mto.hd(t), mto.hd2(t), mto.hd3(t))
      mto.lex.go(t, Bool.pick(List<&2, U32>, c, h <> cur, [h]), Bool.pick(Nat, c, k, k2),
        Bool.pick(Nat, c, mto.sub.cont(k, sub, h), mto.start.sub(k2, h, mto.hd(t))), Bool.pick(List<&2, MtoTk>, c, acc, mto.close(k, cur, acc)))

def mto.lex(+xs: List<&2, U32>) -> List<&2, MtoTk>:
  mto.lex.go(xs, Nil{}, 7n, 0n, Nil{})

def mto.unlex(ts: List<&2, MtoTk>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case MtoTk{k, t} <> more:
      S.append(t, mto.unlex(more))

# the tokens with token i's text replaced by r, rendered
def mto.with(ts: List<&2, MtoTk>, i: Nat, +r: List<&2, U32>) -> List<&2, U32>:
  match ts i:
    case Nil{} _:
      Nil{}
    case MtoTk{k, t} <> more 0n:
      S.append(r, mto.unlex(more))
    case MtoTk{k, t} <> more 1n+j:
      S.append(t, mto.with(more, j, r))

# tokens [a, b) rendered, and from a on
def mto.slice(+ts: List<&2, MtoTk>, +a: Nat, +b: Nat) -> List<&2, U32>:
  mto.unlex(List.take(&2, MtoTk, List.drop(&2, MtoTk, ts, a), Nat.sub(b, a)))

def mto.from(+ts: List<&2, MtoTk>, +a: Nat) -> List<&2, U32>:
  mto.unlex(List.drop(&2, MtoTk, ts, a))

def mto.renders(rs: List<&2, List<&2, U32>>, +ts: List<&2, MtoTk>, +i: Nat) -> List<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      mto.with(ts, i, r) <> mto.renders(t, ts, i)

# Each token with its neighbours: i its place, p the token just before, ps
# the last non-blank one before, c itself, n the token just after (a blank
# run is one token)

type MtoZ is Data:
  MtoZ{i: Nat, p: MtoTk, ps: MtoTk, c: MtoTk, n: MtoTk}

def mto.z.i(+z: MtoZ) -> Nat:
  match z:
    case MtoZ{i, p, ps, c, n}:
      i

def mto.z.p(+z: MtoZ) -> MtoTk:
  match z:
    case MtoZ{i, p, ps, c, n}:
      p

def mto.z.ps(+z: MtoZ) -> MtoTk:
  match z:
    case MtoZ{i, p, ps, c, n}:
      ps

def mto.z.c(+z: MtoZ) -> MtoTk:
  match z:
    case MtoZ{i, p, ps, c, n}:
      c

def mto.z.n(+z: MtoZ) -> MtoTk:
  match z:
    case MtoZ{i, p, ps, c, n}:
      n

def mto.first(+ts: List<&2, MtoTk>) -> MtoTk:
  match ts:
    case x <> t:
      x
    case Nil{}:
      mto.none()

def mto.zip.go(ts: List<&2, MtoTk>, +i: Nat, +p: MtoTk, +ps: MtoTk) -> List<&2, MtoZ>:
  match ts:
    case Nil{}:
      Nil{}
    case +c <> +t:
      MtoZ{i, p, ps, c, mto.first(t)} <> mto.zip.go(t, 1n+i, c, Bool.pick(MtoTk, mto.is.blank(c), ps, c))

def mto.zip(+ts: List<&2, MtoTk>) -> List<&2, MtoZ>:
  mto.zip.go(ts, 0n, mto.none(), mto.none())

# Names -------------------------------------------------------------------------------------------

def mto.last.seg.go(xs: List<&2, U32>, +cur: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, cur)
    case +h <> t:
      mto.last.seg.go(t, Bool.pick(List<&2, U32>, U32.is_eq(h, 46), Nil{}, h <> cur))

# a name's last segment (after its last `.`)
def mto.last.seg(+x: List<&2, U32>) -> List<&2, U32>:
  mto.last.seg.go(x, Nil{})

def mto.kw(+x: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(Bool.or(S.eq(x, S.b("match")), S.eq(x, S.b("case"))), Bool.or(S.eq(x, S.b("def")), S.eq(x, S.b("law")))),
    Bool.or(Bool.or(Bool.or(S.eq(x, S.b("for")), S.eq(x, S.b("do"))), Bool.or(S.eq(x, S.b("return")), S.eq(x, S.b("if")))),
      Bool.or(Bool.or(Bool.or(S.eq(x, S.b("else")), S.eq(x, S.b("with"))), Bool.or(S.eq(x, S.b("type")), S.eq(x, S.b("is")))),
        Bool.or(Bool.or(S.eq(x, S.b("as")), S.eq(x, S.b("import"))), Bool.or(S.eq(x, S.b("fork")), S.eq(x, S.b("_")))))))

# a variable's name: lowercase first, no `.`, no keyword
def mto.var.name(+x: MtoTk) -> Bool:
  +t = mto.tk.t(x)
  Bool.and(Bool.and(mto.is.name(x), mto.lower(mto.hd(t))), Bool.and(Bool.not(mto.has(t, 46)), Bool.not(mto.kw(t))))

# how many name tokens are x
def mto.count.name(zs: List<&2, MtoZ>, +x: List<&2, U32>) -> Nat:
  match zs:
    case Nil{}:
      0n
    case MtoZ{i, p, ps, +c, n} <> t:
      Nat.add(Bool.pick(Nat, Bool.and(mto.is.name(c), S.eq(mto.tk.t(c), x)), 1n, 0n), mto.count.name(t, x))

# a call's head: a name with `(` right after it
def mto.is.call(+z: MtoZ) -> Bool:
  Bool.and(mto.is.name(mto.z.c(z)), mto.punct(mto.z.n(z), "("))

# Lines -------------------------------------------------------------------------------------------

# the lines, each with its newline (the last may lack one): joined, the text
def mto.lines.go(xs: List<&2, U32>, +cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, mto.empty(cur), acc, List.reverse(&2, U32, cur) <> acc))
    case +h <> t:
      +nl = U32.is_eq(h, 10)
      mto.lines.go(t, Bool.pick(List<&2, U32>, nl, Nil{}, h <> cur), Bool.pick(List<&2, List<&2, U32>>, nl, List.reverse(&2, U32, h <> cur) <> acc, acc))

def mto.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  mto.lines.go(xs, Nil{}, Nil{})

def mto.indent.go(xs: List<&2, U32>, +n: Nat, sp: Bool) -> Nat:
  match xs sp:
    case h <> +t True{}:
      mto.indent.go(t, 1n+n, U32.is_eq(mto.hd(t), 32))
    case _ _:
      n

# the spaces a line starts with
def mto.indent(+l: List<&2, U32>) -> Nat:
  mto.indent.go(l, 0n, U32.is_eq(mto.hd(l), 32))

def mto.trim.left(+xs: List<&2, U32>, go: Bool) -> List<&2, U32>:
  match xs go:
    case h <> +t True{}:
      mto.trim.left(t, mto.blank(mto.hd(t)))
    case _ _:
      xs

# the line without its indentation and its line end
def mto.text(+l: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, l)
  +rt = List.reverse(&2, U32, mto.trim.left(r, mto.blank(mto.hd(r))))
  mto.trim.left(rt, mto.blank(mto.hd(rt)))

def mto.is.case(+l: List<&2, U32>) -> Bool:
  S.prefix(mto.text(l), S.b("case "))

# a block's header: a line whose text ends with `:` (do, case, match, def ...)
def mto.is.header(+l: List<&2, U32>) -> Bool:
  U32.is_eq(mto.hd(List.reverse(&2, U32, mto.text(l))), 58)

# does the line end what a line at indent d holds (not blank, indent d or less)
def mto.stops(+l: List<&2, U32>, +d: Nat) -> Bool:
  Bool.and(Bool.not(mto.all.blank(l)), Nat.is_le(mto.indent(l), d))

def mto.end.of.go(ls: List<&2, List<&2, U32>>, +d: Nat, +j: Nat, stop: Bool) -> Nat:
  match ls stop:
    case _ True{}:
      j
    case Nil{} False{}:
      j
    case l <> +t False{}:
      mto.end.of.go(t, d, 1n+j, mto.stops(mto.lhd(t), d))

# the end of what a line at indent d holds among lines ls (ls's first at
# index j): the index of the first that stops it, else the end
def mto.end.of(+ls: List<&2, List<&2, U32>>, +d: Nat, +j: Nat) -> Nat:
  mto.end.of.go(ls, d, j, mto.stops(mto.lhd(ls), d))

# a span of lines [s, e), at indent d
type MtoBk is Data:
  MtoBk{s: Nat, e: Nat, d: Nat}

def mto.bk.s(+b: MtoBk) -> Nat:
  match b:
    case MtoBk{s, e, d}:
      s

def mto.bk.e(+b: MtoBk) -> Nat:
  match b:
    case MtoBk{s, e, d}:
      e

def mto.bk.d(+b: MtoBk) -> Nat:
  match b:
    case MtoBk{s, e, d}:
      d

def mto.bk.first(+bs: List<&2, MtoBk>) -> MtoBk:
  match bs:
    case b <> t:
      b
    case Nil{}:
      MtoBk{0n, 0n, 0n}

def mto.join(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  List.concat(&2, U32, xs)

def mto.lslice(+ls: List<&2, List<&2, U32>>, +a: Nat, +b: Nat) -> List<&2, U32>:
  mto.join(List.take(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, ls, a), Nat.sub(b, a)))

def mto.lfrom(+ls: List<&2, List<&2, U32>>, +a: Nat) -> List<&2, U32>:
  mto.join(List.drop(&2, List<&2, U32>, ls, a))

# the text less lines [s, e)
def mto.cut(+ls: List<&2, List<&2, U32>>, +b: MtoBk) -> List<&2, U32>:
  S.append(mto.lslice(ls, 0n, mto.bk.s(b)), mto.lfrom(ls, mto.bk.e(b)))

def mto.cuts(+ls: List<&2, List<&2, U32>>, bs: List<&2, MtoBk>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      mto.cut(ls, b) <> mto.cuts(ls, t)

# 0, 1. Arms ----------------------------------------------------------------------------------------

# every `case` line's arm: the line and the lines under it
def mto.arms.go(ls: List<&2, List<&2, U32>>, +j: Nat) -> List<&2, MtoBk>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> +t:
      +rest = mto.arms.go(t, 1n+j)
      Bool.pick(List<&2, MtoBk>, mto.is.case(l), MtoBk{j, mto.end.of(t, mto.indent(l), 1n+j), mto.indent(l)} <> rest, rest)

def mto.arms(+ls: List<&2, List<&2, U32>>) -> List<&2, MtoBk>:
  mto.arms.go(ls, 0n)

# whether arm b follows arm a in its match
def mto.next.arm(+a: MtoBk, +b: MtoBk) -> Bool:
  Bool.and(Nat.is_eq(mto.bk.e(a), mto.bk.s(b)), Nat.is_eq(mto.bk.d(a), mto.bk.d(b)))

# the arms with a neighbour in their match (prev: there is an arm before,
# last)
def mto.sib.go(as: List<&2, MtoBk>, +prev: Bool, +last: MtoBk) -> List<&2, MtoBk>:
  match as:
    case Nil{}:
      Nil{}
    case +a <> +t:
      +before = Bool.and(prev, mto.next.arm(last, a))
      +after = mto.next.arm(a, mto.bk.first(t))
      +rest = mto.sib.go(t, True{}, a)
      Bool.pick(List<&2, MtoBk>, Bool.or(before, after), a <> rest, rest)

def mto.op.drop.case(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ls = mto.lines(body)
  mto.cuts(ls, mto.sib.go(mto.arms(ls), False{}, MtoBk{0n, 0n, 0n}))

# arms a and b (b right after a) with their bodies swapped
def mto.swap.two(+ls: List<&2, List<&2, U32>>, +a: MtoBk, +b: MtoBk) -> List<&2, U32>:
  +sa = mto.bk.s(a)
  +sb = mto.bk.s(b)
  mto.cat([mto.lslice(ls, 0n, 1n+sa), mto.lslice(ls, 1n+sb, mto.bk.e(b)), mto.lslice(ls, sb, 1n+sb), mto.lslice(ls, 1n+sa, sb), mto.lfrom(ls, mto.bk.e(b))])

def mto.swap.arms.of(+ls: List<&2, List<&2, U32>>, as: List<&2, MtoBk>) -> List<&2, List<&2, U32>>:
  match as:
    case Nil{}:
      Nil{}
    case +a <> +t:
      +b = mto.bk.first(t)
      +ok = Bool.and(mto.next.arm(a, b), Bool.not(S.eq(mto.lslice(ls, 1n+mto.bk.s(a), mto.bk.e(a)), mto.lslice(ls, 1n+mto.bk.s(b), mto.bk.e(b)))))
      +rest = mto.swap.arms.of(ls, t)
      Bool.pick(List<&2, List<&2, U32>>, ok, mto.swap.two(ls, a, b) <> rest, rest)

def mto.op.swap.arms(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ls = mto.lines(body)
  mto.swap.arms.of(ls, mto.arms(ls))

# 2. Statements ---------------------------------------------------------------------------------------
#
# A block: the lines under a header (a line ending with `:`), or the whole
# body; its statements are its lines at the indent of its first non-blank
# line, each with the deeper lines after it.

# the statements among lines ls (ls's first at index j) at indent s, before index e
def mto.stmts.go(ls: List<&2, List<&2, U32>>, +j: Nat, +s: Nat, +e: Nat) -> List<&2, MtoBk>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> +t:
      +rest = mto.stmts.go(t, 1n+j, s, e)
      +at = Bool.and(Bool.and(Nat.is_lt(j, e), Bool.not(mto.all.blank(l))), Nat.is_eq(mto.indent(l), s))
      Bool.pick(List<&2, MtoBk>, at, MtoBk{j, Nat.min(mto.end.of(t, s, 1n+j), e), s} <> rest, rest)

def mto.first.indent.go(ls: List<&2, List<&2, U32>>, blank: Bool) -> Nat:
  match ls blank:
    case l <> +t True{}:
      mto.first.indent.go(t, mto.all.blank(mto.lhd(t)))
    case +l <> t False{}:
      mto.indent(l)
    case Nil{} _:
      0n

# the first non-blank line's indent (0 when none)
def mto.first.indent(+ls: List<&2, List<&2, U32>>) -> Nat:
  mto.first.indent.go(ls, mto.all.blank(mto.lhd(ls)))

# the statements of the block under the header l at index j
def mto.block(+ls: List<&2, List<&2, U32>>, +j: Nat, +l: List<&2, U32>) -> List<&2, MtoBk>:
  +after = List.drop(&2, List<&2, U32>, ls, 1n+j)
  +e = mto.end.of(after, mto.indent(l), 1n+j)
  +s = mto.first.indent(List.take(&2, List<&2, U32>, after, Nat.sub(e, 1n+j)))
  Bool.pick(List<&2, MtoBk>, Nat.is_lt(mto.indent(l), s), mto.stmts.go(after, 1n+j, s, e), Nil{})

# a statement that is not a match's arm
def mto.not.arm(+b: MtoBk, +ls: List<&2, List<&2, U32>>) -> Bool:
  Bool.not(mto.is.case(mto.lhd(List.drop(&2, List<&2, U32>, ls, mto.bk.s(b)))))

def mto.keep.stmts(bs: List<&2, MtoBk>, +ls: List<&2, List<&2, U32>>) -> List<&2, MtoBk>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      +rest = mto.keep.stmts(t, ls)
      Bool.pick(List<&2, MtoBk>, mto.not.arm(b, ls), b <> rest, rest)

# a block's statements when it has two or more
def mto.two(+bs: List<&2, MtoBk>) -> List<&2, MtoBk>:
  Bool.pick(List<&2, MtoBk>, Nat.is_lt(1n, List.length(&2, MtoBk, bs)), bs, Nil{})

def mto.blocks.go(xs: List<&2, List<&2, U32>>, +ls: List<&2, List<&2, U32>>, +j: Nat) -> List<&2, MtoBk>:
  match xs:
    case Nil{}:
      Nil{}
    case +l <> t:
      +here = Bool.pick(List<&2, MtoBk>, mto.is.header(l), mto.keep.stmts(mto.two(mto.block(ls, j, l)), ls), Nil{})
      List.append(&2, MtoBk, here, mto.blocks.go(t, ls, 1n+j))

def mto.op.drop.line(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ls = mto.lines(body)
  +n = List.length(&2, List<&2, U32>, ls)
  +top = mto.keep.stmts(mto.two(mto.stmts.go(ls, 0n, mto.first.indent(ls), n)), ls)
  mto.cuts(ls, List.append(&2, MtoBk, top, mto.blocks.go(ls, ls, 0n)))

# 3, 4. Calls ------------------------------------------------------------------------------------------
#
# A call: a name, then `(` right after it.  Its arguments are the token runs
# between `(` and the matching `)` split at the commas outside any bracket
# (`<` right after a name opens a type's arguments: `List<&2, U32>`); an
# argument's core is its run without the blanks around it, tokens [s, e).

type MtoArg is Data:
  MtoArg{s: Nat, e: Nat}

def mto.arg.s(+a: MtoArg) -> Nat:
  match a:
    case MtoArg{s, e}:
      s

def mto.arg.e(+a: MtoArg) -> Nat:
  match a:
    case MtoArg{s, e}:
      e

def mto.arg.first(+as: List<&2, MtoArg>) -> MtoArg:
  match as:
    case a <> t:
      a
    case Nil{}:
      MtoArg{0n, 0n}

def mto.opener(+x: MtoTk) -> Bool:
  Bool.or(Bool.or(mto.punct(x, "("), mto.punct(x, "[")), mto.punct(x, "{"))

def mto.closer(+x: MtoTk) -> Bool:
  Bool.or(Bool.or(mto.punct(x, ")"), mto.punct(x, "]")), mto.punct(x, "}"))

# an argument's core so far: its first non-blank token (0: none yet) and the
# end of its last
def mto.core.s(+cs: Nat, +i: Nat, +x: MtoTk) -> Nat:
  Bool.pick(Nat, Bool.and(Nat.is_eq(cs, 0n), Bool.not(mto.is.blank(x))), i, cs)

def mto.core.e(+ce: Nat, +i: Nat, +x: MtoTk) -> Nat:
  Bool.pick(Nat, mto.is.blank(x), ce, 1n+i)

# the cores of the arguments from token i on (d: bracket depth, a: angle
# depth, pn: the token before is a name; cs, ce: this argument's core so
# far; stop: the call closed at the token before); None when the call does
# not close or an argument is empty
def mto.args.go(ts: List<&2, MtoTk>, +i: Nat, +d: Nat, +a: Nat, +pn: Bool, +cs: Nat, +ce: Nat, +acc: List<&2, MtoArg>, +bad: Bool, stop: Bool) -> Maybe<&2, List<&2, MtoArg>>:
  match ts stop:
    case _ True{}:
      Bool.pick(Maybe<&2, List<&2, MtoArg>>, bad, None{}, Some{List.reverse(&2, MtoArg, acc)})
    case Nil{} False{}:
      None{}
    case +x <> t False{}:
      +top = Bool.and(Nat.is_eq(d, 0n), Nat.is_eq(a, 0n))
      +end = Bool.and(mto.closer(x), Nat.is_eq(d, 0n))
      +comma = Bool.and(mto.punct(x, ","), top)
      +split = Bool.or(end, comma)
      +lt = Bool.and(mto.punct(x, "<"), pn)
      +gt = Bool.and(mto.punct(x, ">"), Nat.is_lt(0n, a))
      +d2 = Bool.pick(Nat, mto.opener(x), 1n+d, Bool.pick(Nat, mto.closer(x), Nat.sub(d, 1n), d))
      +a2 = Bool.pick(Nat, lt, 1n+a, Bool.pick(Nat, gt, Nat.sub(a, 1n), a))
      mto.args.go(t, 1n+i, d2, a2, mto.is.name(x), Bool.pick(Nat, split, 0n, mto.core.s(cs, i, x)), Bool.pick(Nat, split, 0n, mto.core.e(ce, i, x)),
        Bool.pick(List<&2, MtoArg>, split, MtoArg{cs, ce} <> acc, acc), Bool.or(bad, Bool.and(split, Nat.is_eq(cs, 0n))), end)

# the arguments of the call whose name is token i (`(` is token i + 1)
def mto.args(+ts: List<&2, MtoTk>, +i: Nat) -> Maybe<&2, List<&2, MtoArg>>:
  mto.args.go(List.drop(&2, MtoTk, ts, Nat.add(i, 2n)), Nat.add(i, 2n), 0n, 0n, False{}, 0n, 0n, Nil{}, False{}, False{})

def mto.calls.put(m: Maybe<&2, List<&2, MtoArg>>, rest: List<&2, List<&2, MtoArg>>) -> List<&2, List<&2, MtoArg>>:
  match m:
    case Some{xs}:
      xs <> rest
    case None{}:
      rest

# every call's arguments (a call that closes, with no empty argument)
def mto.calls(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>) -> List<&2, List<&2, MtoArg>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> t:
      +rest = mto.calls(t, ts)
      Bool.pick(List<&2, List<&2, MtoArg>>, mto.is.call(z), mto.calls.put(mto.args(ts, mto.z.i(z)), rest), rest)

def mto.swap.args.of(as: List<&2, MtoArg>, +ts: List<&2, MtoTk>) -> List<&2, List<&2, U32>>:
  match as:
    case Nil{}:
      Nil{}
    case +a <> +t:
      +b = mto.arg.first(t)
      +ca = mto.slice(ts, mto.arg.s(a), mto.arg.e(a))
      +cb = mto.slice(ts, mto.arg.s(b), mto.arg.e(b))
      +ok = Bool.and(Nat.is_lt(0n, mto.arg.e(b)), Bool.not(S.eq(ca, cb)))
      +m = mto.cat([mto.slice(ts, 0n, mto.arg.s(a)), cb, mto.slice(ts, mto.arg.e(a), mto.arg.s(b)), ca, mto.from(ts, mto.arg.e(b))])
      +rest = mto.swap.args.of(t, ts)
      Bool.pick(List<&2, List<&2, U32>>, ok, m <> rest, rest)

def mto.each.swap(cs: List<&2, List<&2, MtoArg>>, +ts: List<&2, MtoTk>) -> List<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      Nil{}
    case as <> t:
      List.append(&2, List<&2, U32>, mto.swap.args.of(as, ts), mto.each.swap(t, ts))

def mto.op.swap.args(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.each.swap(mto.calls(mto.zip(ts), ts), ts)

# each argument dropped: up to the next one's core, or (the last) from the
# end of the one before (prev)
def mto.drop.args.of(as: List<&2, MtoArg>, +ts: List<&2, MtoTk>, +prev: MtoArg) -> List<&2, List<&2, U32>>:
  match as:
    case Nil{}:
      Nil{}
    case +a <> +t:
      +last = List.is_empty(&2, MtoArg, t)
      +nx = mto.arg.first(t)
      +m = Bool.pick(List<&2, U32>, last, S.append(mto.slice(ts, 0n, mto.arg.e(prev)), mto.from(ts, mto.arg.e(a))),
        S.append(mto.slice(ts, 0n, mto.arg.s(a)), mto.from(ts, mto.arg.s(nx))))
      m <> mto.drop.args.of(t, ts, a)

def mto.each.drop(cs: List<&2, List<&2, MtoArg>>, +ts: List<&2, MtoTk>) -> List<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      Nil{}
    case +as <> t:
      +two = Nat.is_lt(1n, List.length(&2, MtoArg, as))
      List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, two, mto.drop.args.of(as, ts, MtoArg{0n, 0n}), Nil{}), mto.each.drop(t, ts))

def mto.op.drop.arg(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.each.drop(mto.calls(mto.zip(ts), ts), ts)

# 5. Constructors ------------------------------------------------------------------------------------

def mto.siblings() -> List<&2, MtoPr>:
  [mto.pr("True", "False"), mto.pr("False", "True"), mto.pr("Some", "None"), mto.pr("None", "Some"), mto.pr("Done", "Fail"), mto.pr("Fail", "Done"),
   mto.pr("Nil", "Con"), mto.pr("Con", "Nil"), mto.pr("SNil", "SCon"), mto.pr("SCon", "SNil"), mto.pr("Zero", "Succ"), mto.pr("Succ", "Zero"),
   mto.pr("Inl", "Inr"), mto.pr("Inr", "Inl")]

# a constructor: a name whose last segment is capitalised, right before `{`
def mto.is.ctor(+z: MtoZ) -> Bool:
  +c = mto.z.c(z)
  Bool.and(Bool.and(mto.is.name(c), mto.upper(mto.hd(mto.last.seg(mto.tk.t(c))))), mto.punct(mto.z.n(z), "{"))

# the constructors the body's `case` patterns lead with
def mto.case.ctors(zs: List<&2, MtoZ>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      acc
    case +z <> t:
      +hit = Bool.and(mto.is.ctor(z), mto.tk.is(mto.z.ps(z), 1n, "case"))
      mto.case.ctors(t, Bool.pick(List<&2, List<&2, U32>>, hit, mto.add(acc, mto.tk.t(mto.z.c(z))), acc))

# the name x with its last segment replaced by r
def mto.reseg(+x: List<&2, U32>, +r: List<&2, U32>) -> List<&2, U32>:
  S.append(List.take(&2, U32, x, Nat.sub(mto.len(x), mto.len(mto.last.seg(x)))), r)

# what constructor x may become: its pair's other, and (when the body's
# `case` lines lead with it) the others they lead with
def mto.ctor.reps(+x: List<&2, U32>, +cc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  +sib = mto.look(mto.siblings(), mto.last.seg(x))
  +own = Bool.pick(List<&2, List<&2, U32>>, mto.empty(sib), Nil{}, [mto.reseg(x, sib)])
  +theirs = Bool.pick(List<&2, List<&2, U32>>, mto.mem(cc, x), cc, Nil{})
  mto.uniq(List.append(&2, List<&2, U32>, own, theirs), x)

def mto.ctor.go(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>, +cc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> t:
      +rest = mto.ctor.go(t, ts, cc)
      +here = Bool.pick(List<&2, List<&2, U32>>, mto.is.ctor(z), mto.renders(mto.ctor.reps(mto.tk.t(mto.z.c(z)), cc), ts, mto.z.i(z)), Nil{})
      List.append(&2, List<&2, U32>, here, rest)

def mto.op.ctor.swap(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  +zs = mto.zip(ts)
  mto.ctor.go(zs, ts, mto.case.ctors(zs, Nil{}))

# 6. Affine binders --------------------------------------------------------------------------------------
#
# A binder's `+`: a `+` right before a variable's name, where no value ends
# before it: at a line's start, after `(`, `,`, `{`, `=`, `case` ...; not the
# `+` of `1n+p` or of `a +b` (a name, a number, a string or a closing
# bracket ends a value).

def mto.value.end(+x: MtoTk) -> Bool:
  +k = mto.tk.k(x)
  Bool.or(Bool.or(Bool.and(Nat.is_eq(k, 1n), Bool.not(mto.kw(mto.tk.t(x)))), Nat.is_eq(k, 2n)), Bool.or(Nat.is_eq(k, 3n), mto.closer(x)))

def mto.line.start(+x: MtoTk) -> Bool:
  Bool.or(Nat.is_eq(mto.tk.k(x), 9n), Bool.and(mto.is.blank(x), mto.has(mto.tk.t(x), 10)))

def mto.is.binder(+z: MtoZ) -> Bool:
  +p = mto.z.p(z)
  +lead = Bool.or(mto.line.start(p), Bool.not(mto.value.end(Bool.pick(MtoTk, mto.is.blank(p), mto.z.ps(z), p))))
  Bool.and(Bool.and(mto.punct(mto.z.c(z), "+"), mto.var.name(mto.z.n(z))), lead)

def mto.affine.go(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> +t:
      +rest = mto.affine.go(t, ts)
      +hit = Bool.and(mto.is.binder(z), Nat.is_le(3n, mto.count.name(t, mto.tk.t(mto.z.n(z)))))
      Bool.pick(List<&2, List<&2, U32>>, hit, mto.with(ts, mto.z.i(z), Nil{}) <> rest, rest)

def mto.op.affine(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.affine.go(mto.zip(ts), ts)

# 7, 8. Literals ----------------------------------------------------------------------------------------

# a plain literal's digits and whether it is a Nat's (`3n`)
type MtoLit is Data:
  MtoLit{ds: List<&2, U32>, nat: Bool}

def mto.lit.of(+t: List<&2, U32>) -> Maybe<&2, MtoLit>:
  +r = List.reverse(&2, U32, t)
  +n = U32.is_eq(mto.hd(r), 110)
  +ds = Bool.pick(List<&2, U32>, n, List.reverse(&2, U32, List.drop(&2, U32, r, 1n)), t)
  Bool.pick(Maybe<&2, MtoLit>, Bool.and(mto.all.digits(ds), Bool.not(mto.empty(ds))), Some{MtoLit{ds, n}}, None{})

def mto.dec.go(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      mto.dec.go(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))))

def mto.nsuf(+nat: Bool) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, nat, [110], Nil{})

# 0 and 1 swapped, any other plus one (at most nine digits; empty: none)
def mto.lit.value(m: Maybe<&2, MtoLit>) -> List<&2, U32>:
  match m:
    case Some{MtoLit{+ds, +nat}}:
      +v = mto.dec.go(ds, 0n)
      +w = Bool.pick(Nat, Nat.is_eq(v, 0n), 1n, Bool.pick(Nat, Nat.is_eq(v, 1n), 0n, 1n+v))
      Bool.pick(List<&2, U32>, Nat.is_lt(9n, mto.len(ds)), Nil{}, S.append(S.b(Nat.show(w)), mto.nsuf(nat)))
    case None{}:
      Nil{}

def mto.lit.suffix(m: Maybe<&2, MtoLit>) -> List<&2, U32>:
  match m:
    case Some{MtoLit{ds, +nat}}:
      S.append(ds, mto.nsuf(Bool.not(nat)))
    case None{}:
      Nil{}

# a pattern's literal: after `case`, or leading a `1n+p`; in a proof, any
def mto.lit.at(+z: MtoZ, +prop: Bool) -> Bool:
  Bool.or(prop, Bool.or(mto.tk.is(mto.z.ps(z), 1n, "case"), mto.punct(mto.z.n(z), "+")))

def mto.lit.go(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>, +value: Bool, +prop: Bool) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> t:
      +rest = mto.lit.go(t, ts, value, prop)
      +m = mto.lit.of(mto.tk.t(mto.z.c(z)))
      +r = Bool.pick(List<&2, U32>, value, mto.lit.value(m), mto.lit.suffix(m))
      +num = Nat.is_eq(mto.tk.k(mto.z.c(z)), 2n)
      +hit = Bool.and(Bool.and(num, Bool.not(mto.empty(r))), Bool.or(Bool.not(value), mto.lit.at(z, prop)))
      Bool.pick(List<&2, List<&2, U32>>, hit, mto.with(ts, mto.z.i(z), r) <> rest, rest)

def mto.op.lit.value(+body: List<&2, U32>, +prop: Bool) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.lit.go(mto.zip(ts), ts, True{}, prop)

def mto.op.lit.suffix(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.lit.go(mto.zip(ts), ts, False{}, False{})

# 9. Variables -------------------------------------------------------------------------------------------
#
# The variables: names of variable shape (`mto.var.name`) never called (no
# `(` right after them anywhere), read in the order of the declaration's
# header (its pre: the parameters) then its body.  A variable's first
# occurrence binds it; every later one is a use.

def mto.called(zs: List<&2, MtoZ>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      acc
    case +z <> t:
      mto.called(t, Bool.pick(List<&2, List<&2, U32>>, mto.is.call(z), mto.add(acc, mto.tk.t(mto.z.c(z))), acc))

def mto.is.var(+x: MtoTk, +called: List<&2, List<&2, U32>>) -> Bool:
  Bool.and(mto.var.name(x), Bool.not(mto.mem(called, mto.tk.t(x))))

def mto.lhd.is(+xs: List<&2, List<&2, U32>>, +v: List<&2, U32>) -> Bool:
  match xs:
    case +h <> t:
      S.eq(h, v)
    case Nil{}:
      False{}

# in the variables bound so far (in order): the one bound right before v,
# else (v the first) the one right after it (empty: none)
def mto.before.go(xs: List<&2, List<&2, U32>>, +v: List<&2, U32>, +best: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      Bool.pick(List<&2, U32>, mto.empty(best), mto.lhd(t), best)
    case +h <> +t False{}:
      mto.before.go(t, v, h, mto.lhd.is(t, v))
    case Nil{} _:
      Nil{}

def mto.before(+xs: List<&2, List<&2, U32>>, +v: List<&2, U32>) -> List<&2, U32>:
  mto.before.go(xs, v, Nil{}, mto.lhd.is(xs, v))

# the body's uses (tokens from off on), each with its replacement
def mto.var.go(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>, +off: Nat, +called: List<&2, List<&2, U32>>, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> t:
      +c = mto.z.c(z)
      +x = mto.tk.t(c)
      +isv = mto.is.var(c, called)
      +w = mto.before(seen, x)
      +hit = Bool.and(Bool.and(isv, mto.mem(seen, x)), Bool.and(Bool.not(mto.empty(w)), Nat.is_le(off, mto.z.i(z))))
      +rest = mto.var.go(t, ts, off, called, Bool.pick(List<&2, List<&2, U32>>, isv, mto.add(seen, x), seen))
      Bool.pick(List<&2, List<&2, U32>>, hit, mto.with(List.drop(&2, MtoTk, ts, off), Nat.sub(mto.z.i(z), off), w) <> rest, rest)

def mto.op.var.swap(+pre: List<&2, U32>, +body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +tp = mto.lex(pre)
  +ts = List.append(&2, MtoTk, tp, mto.lex(body))
  +zs = mto.zip(ts)
  mto.var.go(zs, ts, List.length(&2, MtoTk, tp), mto.called(zs, Nil{}), Nil{})

# 10. Misspellings ----------------------------------------------------------------------------------------

# the last letter dropped (a last segment of two letters or more)
def mto.ms.drop(+x: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_lt(1n, mto.len(mto.last.seg(x))), List.take(&2, U32, x, Nat.sub(mto.len(x), 1n)), Nil{})

# the last two letters swapped (both letters, and different)
def mto.ms.swap(+x: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, x)
  +a = mto.hd(r)
  +b = mto.hd2(r)
  +ok = Bool.and(Bool.and(mto.alpha(a), mto.alpha(b)), Bool.not(U32.is_eq(a, b)))
  Bool.pick(List<&2, U32>, ok, List.reverse(&2, U32, b <> a <> List.drop(&2, U32, r, 2n)), Nil{})

# the first `_` written `.`, else the first `.` written `_`
def mto.ms.sep(+x: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, mto.has(x, 95), mto.sub(95, 46, x), Bool.pick(List<&2, U32>, mto.has(x, 46), mto.sub(46, 95, x), Nil{}))

def mto.misspell.go(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> t:
      +rest = mto.misspell.go(t, ts)
      +x = mto.tk.t(mto.z.c(z))
      +vs = mto.nonempty([mto.ms.drop(x), mto.ms.swap(x), mto.ms.sep(x)])
      +here = Bool.pick(List<&2, List<&2, U32>>, mto.is.call(z), mto.renders(vs, ts, mto.z.i(z)), Nil{})
      List.append(&2, List<&2, U32>, here, rest)

def mto.op.misspell(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.misspell.go(mto.zip(ts), ts)

# 11. Types ----------------------------------------------------------------------------------------------

def mto.types() -> List<&2, MtoPr>:
  [mto.pr("Nat", "U32"), mto.pr("U32", "Nat"), mto.pr("Bool", "Nat"), mto.pr("String", "Nat"), mto.pr("U64", "U32"), mto.pr("Unit", "Bool")]

# a type's name, not a constructor's or a call's
def mto.is.type(+z: MtoZ) -> Bool:
  +c = mto.z.c(z)
  +n = mto.z.n(z)
  Bool.and(Bool.and(mto.is.name(c), Bool.not(mto.empty(mto.look(mto.types(), mto.tk.t(c))))), Bool.not(Bool.or(mto.punct(n, "{"), mto.punct(n, "("))))

def mto.type.go(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> t:
      +rest = mto.type.go(t, ts)
      Bool.pick(List<&2, List<&2, U32>>, mto.is.type(z), mto.with(ts, mto.z.i(z), mto.look(mto.types(), mto.tk.t(mto.z.c(z)))) <> rest, rest)

def mto.op.type.swap(+body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.type.go(mto.zip(ts), ts)

# 12. Import aliases --------------------------------------------------------------------------------------

def mto.nth(+xs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  mto.lhd(List.drop(&2, List<&2, U32>, xs, i))

# the alias of an `import PATH as A` line (empty: none)
def mto.alias.of(+l: List<&2, U32>) -> List<&2, U32>:
  +ws = S.split(mto.text(l), 32)
  +n = List.length(&2, List<&2, U32>, ws)
  +ok = Bool.and(Bool.and(S.eq(mto.nth(ws, 0n), S.b("import")), Nat.is_le(4n, n)), S.eq(mto.nth(ws, Nat.sub(n, 2n)), S.b("as")))
  Bool.pick(List<&2, U32>, ok, mto.nth(ws, Nat.sub(n, 1n)), Nil{})

def mto.aliases(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +a = mto.alias.of(l)
      +rest = mto.aliases(t)
      Bool.pick(List<&2, List<&2, U32>>, mto.empty(a), rest, a <> rest)

def mto.qual.hit(+as: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> Bool:
  match as:
    case +a <> t:
      S.prefix(x, S.append(a, [46]))
    case Nil{}:
      False{}

def mto.qual.go(as: List<&2, List<&2, U32>>, +x: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match as at:
    case a <> t True{}:
      a
    case a <> +t False{}:
      mto.qual.go(t, x, mto.qual.hit(t, x))
    case Nil{} _:
      Nil{}

# the alias x is qualified by (empty: none)
def mto.qual.by(+as: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> List<&2, U32>:
  mto.qual.go(as, x, mto.qual.hit(as, x))

def mto.alias.go(zs: List<&2, MtoZ>, +ts: List<&2, MtoTk>, +as: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match zs:
    case Nil{}:
      Nil{}
    case +z <> t:
      +rest = mto.alias.go(t, ts, as)
      +c = mto.z.c(z)
      +a = mto.qual.by(as, mto.tk.t(c))
      +hit = Bool.and(mto.is.name(c), Bool.not(mto.empty(a)))
      Bool.pick(List<&2, List<&2, U32>>, hit, mto.with(ts, mto.z.i(z), List.drop(&2, U32, mto.tk.t(c), 1n+mto.len(a))) <> rest, rest)

def mto.op.alias.drop(+head: List<&2, U32>, +body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ts = mto.lex(body)
  mto.alias.go(mto.zip(ts), ts, mto.aliases(mto.lines(head)))

# The operators together -----------------------------------------------------------------------------------

# what the operators read of a unit: the file before the declaration (its
# imports), the declaration's header, the body; whether it is a proof
type MtoU is Data:
  MtoU{head: List<&2, U32>, pre: List<&2, U32>, body: List<&2, U32>, prop: Bool}

def mto.u.head(+u: MtoU) -> List<&2, U32>:
  match u:
    case MtoU{h, p, b, r}:
      h

def mto.u.pre(+u: MtoU) -> List<&2, U32>:
  match u:
    case MtoU{h, p, b, r}:
      p

def mto.u.body(+u: MtoU) -> List<&2, U32>:
  match u:
    case MtoU{h, p, b, r}:
      b

def mto.u.prop(+u: MtoU) -> Bool:
  match u:
    case MtoU{h, p, b, r}:
      r

def mto.ops() -> List<&2, String>:
  ["drop-case", "swap-arms", "drop-line", "swap-args", "drop-arg", "ctor-swap", "affine", "lit-value", "lit-suffix", "var-swap", "misspell", "type-swap", "alias-drop"]

def mto.op.count() -> Nat:
  13n

def mto.op.name.go(xs: List<&2, String>, i: Nat) -> String:
  match xs i:
    case x <> t 0n:
      x
    case x <> t 1n+j:
      mto.op.name.go(t, j)
    case Nil{} _:
      "?"

def mto.op.name(+o: Nat) -> String:
  mto.op.name.go(mto.ops(), o)

# operator o's mutants of the unit, in the order of the place each changes
def mto.op(o: Nat, +u: MtoU) -> List<&2, List<&2, U32>>:
  match o:
    case 0n:
      mto.op.drop.case(mto.u.body(u))
    case 1n:
      mto.op.swap.arms(mto.u.body(u))
    case 2n:
      mto.op.drop.line(mto.u.body(u))
    case 3n:
      mto.op.swap.args(mto.u.body(u))
    case 4n:
      mto.op.drop.arg(mto.u.body(u))
    case 5n:
      mto.op.ctor.swap(mto.u.body(u))
    case 6n:
      mto.op.affine(mto.u.body(u))
    case 7n:
      mto.op.lit.value(mto.u.body(u), mto.u.prop(u))
    case 8n:
      mto.op.lit.suffix(mto.u.body(u))
    case 9n:
      mto.op.var.swap(mto.u.pre(u), mto.u.body(u))
    case 10n:
      mto.op.misspell(mto.u.body(u))
    case 11n:
      mto.op.type.swap(mto.u.body(u))
    case _:
      mto.op.alias.drop(mto.u.head(u), mto.u.body(u))

# A unit's tries ------------------------------------------------------------------------------------------
#
# Operator o's k-th mutant of a unit is its mutants' (r + k) mod n-th, r
# read from the unit's key (64 hex digits: sha256 of the salt, NUL, the id):
# digits 4o .. 4o + 3 as a number.  A unit tries the operators in turn,
# starting at operator s (digits 52 .. 55, mod 13): each one's 0th mutant,
# then each one's 1st, ... at most `cap` an operator, a text once (the first
# operator to give it keeps it), never the body.

type MtoTry is Data:
  MtoTry{op: Nat, k: Nat, text: List<&2, U32>}

def mto.try.op(+t: MtoTry) -> Nat:
  match t:
    case MtoTry{o, k, x}:
      o

def mto.try.k(+t: MtoTry) -> Nat:
  match t:
    case MtoTry{o, k, x}:
      k

def mto.try.text(+t: MtoTry) -> List<&2, U32>:
  match t:
    case MtoTry{o, k, x}:
      x

def mto.hexd(+c: U32) -> Nat:
  Bool.pick(Nat, mto.digit(c), U32.to_nat(U32.sub(c, 48)), Bool.pick(Nat, Bool.and(U32.is_le(97, c), U32.is_le(c, 102)), U32.to_nat(U32.sub(c, 87)), 0n))

def mto.hex.go(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      mto.hex.go(t, Nat.add(Nat.mul(acc, 16n), mto.hexd(h)))

# four hex digits of the key from place i, as a number
def mto.key.at(+key: List<&2, U32>, +i: Nat) -> Nat:
  mto.hex.go(List.take(&2, U32, List.drop(&2, U32, key, i), 4n), 0n)

def mto.rotate(+xs: List<&2, List<&2, U32>>, +r: Nat) -> List<&2, List<&2, U32>>:
  +n = List.length(&2, List<&2, U32>, xs)
  +k = Nat.mod(r, Nat.max(n, 1n))
  List.append(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, xs, k), List.take(&2, List<&2, U32>, xs, k))

def mto.tag(xs: List<&2, List<&2, U32>>, +o: Nat, +k: Nat) -> List<&2, MtoTry>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      MtoTry{o, k, x} <> mto.tag(t, o, 1n+k)

# operator o's tries: the first cap of its mutants from its rotation
def mto.op.tries(+o: Nat, +key: List<&2, U32>, +cap: Nat, +u: MtoU) -> List<&2, MtoTry>:
  mto.tag(List.take(&2, List<&2, U32>, mto.rotate(mto.op(o, u), mto.key.at(key, Nat.mul(4n, o))), cap), o, 0n)

# n operators in turn from s
def mto.order(n: Nat, +s: Nat, +m: Nat) -> List<&2, Nat>:
  match n:
    case 0n:
      Nil{}
    case 1n+j:
      Nat.mod(s, m) <> mto.order(j, 1n+s, m)

def mto.all.tries(os: List<&2, Nat>, +key: List<&2, U32>, +cap: Nat, +u: MtoU) -> List<&2, List<&2, MtoTry>>:
  match os:
    case Nil{}:
      Nil{}
    case +o <> t:
      mto.op.tries(o, key, cap, u) <> mto.all.tries(t, key, cap, u)

def mto.heads(ls: List<&2, List<&2, MtoTry>>) -> List<&2, MtoTry>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      List.append(&2, MtoTry, List.take(&2, MtoTry, l, 1n), mto.heads(t))

def mto.tails(ls: List<&2, List<&2, MtoTry>>) -> List<&2, List<&2, MtoTry>>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      List.drop(&2, MtoTry, l, 1n) <> mto.tails(t)

# each list's first, then each one's second, ... (fuel rounds)
def mto.rr(fuel: Nat, +ls: List<&2, List<&2, MtoTry>>) -> List<&2, MtoTry>:
  match fuel:
    case 0n:
      Nil{}
    case 1n+f:
      List.append(&2, MtoTry, mto.heads(ls), mto.rr(f, mto.tails(ls)))

def mto.try.uniq(xs: List<&2, MtoTry>, +body: List<&2, U32>, +seen: List<&2, List<&2, U32>>) -> List<&2, MtoTry>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +tx = mto.try.text(x)
      +keep = Bool.and(Bool.not(S.eq(tx, body)), Bool.not(mto.mem(seen, tx)))
      +rest = mto.try.uniq(t, body, Bool.pick(List<&2, List<&2, U32>>, keep, tx <> seen, seen))
      Bool.pick(List<&2, MtoTry>, keep, x <> rest, rest)

# a unit's tries, in the order they are checked
def mto.tries(+key: List<&2, U32>, +cap: Nat, +u: MtoU) -> List<&2, MtoTry>:
  +m = mto.op.count()
  +ls = mto.all.tries(mto.order(m, mto.key.at(key, 52n), m), key, cap, u)
  mto.try.uniq(mto.rr(cap, ls), mto.u.body(u), Nil{})
