import Base
import ./Tokenizer.bend as Tk
import ./Sys.bend as S

# JSON strings, the one JSON value the corpus tools read and write.
#
# Meaning.  `Json.string(xs)` is the text a JSON string literal denotes,
# when xs is one (surrounding whitespace allowed), else None: the escapes
# \" \\ \/ \b \f \n \r \t and \uXXXX (a surrogate pair is one scalar, a
# lone low surrogate is U+FFFD, a high one without its low one refuses the
# string), everything else as it stands.  That is jq's
# reading (`jq -r .`), except that a raw control character inside the
# string is taken as itself where jq refuses the whole string (the bash
# harness lost Agda messages that way).  `Json.quote(xs)` is the literal
# jq -c writes for the text xs: `"` and `\` escaped, \b \f \n \r \t, every
# other byte below 0x20 and 0x7F as \u00xx, all else as it stands.

def hexd(+c: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), U32.sub(c, 48),
    Bool.pick(U32, Bool.and(U32.is_le(97, c), U32.is_le(c, 102)), U32.sub(c, 87),
      Bool.pick(U32, Bool.and(U32.is_le(65, c), U32.is_le(c, 70)), U32.sub(c, 55), 16)))

# four hex digits as a value; 65536 when they are not four hex digits
def hex4(xs: List<&2, U32>) -> U32:
  match xs:
    case +a <> +b <> +c <> +d <> t:
      +w = hexd(a)
      +x = hexd(b)
      +y = hexd(c)
      +z = hexd(d)
      Bool.pick(U32, Bool.or(Bool.or(U32.is_eq(w, 16), U32.is_eq(x, 16)), Bool.or(U32.is_eq(y, 16), U32.is_eq(z, 16))), 65536,
        U32.add(U32.add(U32.mul(w, 4096), U32.mul(x, 256)), U32.add(U32.mul(y, 16), z)))
    case _:
      65536

# a scalar's UTF-8 bytes put reversed onto a reversed accumulator
def put(+c: U32, acc: List<&2, U32>) -> List<&2, U32>:
  List.reverse.go(&2, U32, Tk.utf8.encode(c), acc)


type St is Data:
  Go{xs: List<&2, U32>, acc: List<&2, U32>, hi: U32, esc: Bool}
  End{ok: Bool, out: List<&2, U32>, rest: List<&2, U32>}

def fail() -> St:
  End{False{}, Nil{}, Nil{}}

# a high surrogate must be followed by a low one (jq refuses the string)
def unpaired(+hi: U32, st: St) -> St:
  Bool.pick(St, U32.is_eq(hi, 0), st, fail())

# a plain byte: 0 the closing quote, 1 a backslash, 2 anything else
def plain(code: Nat, +h: U32, t: List<&2, U32>, acc: List<&2, U32>, +hi: U32) -> St:
  match code:
    case 0n:
      unpaired(hi, End{True{}, List.reverse(&2, U32, acc), t})
    case 1n:
      Go{t, acc, hi, True{}}
    case _:
      unpaired(hi, Go{t, h <> acc, 0, False{}})

def plain.code(+h: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(h, 34), 0n, Bool.pick(Nat, U32.is_eq(h, 92), 1n, 2n))

# the byte a one-letter escape stands for (0: not one)
def simple(+h: U32) -> U32:
  Bool.pick(U32, Bool.or(Bool.or(U32.is_eq(h, 34), U32.is_eq(h, 92)), U32.is_eq(h, 47)), h,
    Bool.pick(U32, U32.is_eq(h, 98), 8, Bool.pick(U32, U32.is_eq(h, 102), 12,
      Bool.pick(U32, U32.is_eq(h, 110), 10, Bool.pick(U32, U32.is_eq(h, 114), 13,
        Bool.pick(U32, U32.is_eq(h, 116), 9, 0))))))

# \uXXXX: 0 not hex, 1 a high surrogate, 2 a low one after a high, 3 a low
# one alone, 4 any other scalar
def u.code(+v: U32, +hi: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(v, 65536), 0n,
    Bool.pick(Nat, Bool.and(U32.is_le(55296, v), U32.is_le(v, 56319)), 1n,
      Bool.pick(Nat, Bool.and(U32.is_le(56320, v), U32.is_le(v, 57343)), Bool.pick(Nat, U32.is_eq(hi, 0), 3n, 2n), 4n)))

def u.step(code: Nat, +v: U32, t: List<&2, U32>, acc: List<&2, U32>, +hi: U32) -> St:
  match code:
    case 0n:
      fail()
    case 1n:
      unpaired(hi, Go{t, acc, v, False{}})
    case 2n:
      Go{t, put(U32.add(65536, U32.add(U32.mul(U32.sub(hi, 55296), 1024), U32.sub(v, 56320))), acc), 0, False{}}
    case 3n:
      Go{t, put(65533, acc), 0, False{}}
    case _:
      unpaired(hi, Go{t, put(v, acc), 0, False{}})

def escaped(isu: Bool, +h: U32, +t: List<&2, U32>, acc: List<&2, U32>, +hi: U32) -> St:
  match isu:
    case True{}:
      +v = hex4(t)
      u.step(u.code(v, hi), v, List.drop(&2, U32, t, 4n), acc, hi)
    case False{}:
      +c = simple(h)
      Bool.pick(St, U32.is_eq(c, 0), fail(), unpaired(hi, Go{t, c <> acc, 0, False{}}))

def step(xs: List<&2, U32>, acc: List<&2, U32>, +hi: U32, esc: Bool) -> St:
  match xs esc:
    case Nil{} _:
      fail()
    case +h <> +t False{}:
      plain(plain.code(h), h, t, acc, hi)
    case +h <> +t True{}:
      escaped(U32.is_eq(h, 117), h, t, acc, hi)

def run(fuel: Nat, st: St) -> St:
  match fuel st:
    case 1n+f Go{xs, acc, +hi, esc}:
      run(f, step(xs, acc, hi, esc))
    case 0n Go{xs, acc, hi, esc}:
      fail()
    case _ End{ok, out, rest}:
      End{ok, out, rest}

def ws(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 10)), Bool.or(U32.is_eq(c, 13), U32.is_eq(c, 9)))

def ws.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      ws(h)
    case Nil{}:
      False{}

def ws.drop(xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t True{}:
      ws.drop(t, ws.head(t))
    case Nil{} _:
      Nil{}
    case h <> t False{}:
      h <> t

def ws.only(+xs: List<&2, U32>) -> Bool:
  Nat.is_eq(List.length(&2, U32, ws.drop(xs, ws.head(xs))), 0n)

def string.fin(st: St) -> Maybe<&2, List<&2, U32>>:
  match st:
    case End{True{}, out, +rest}:
      Bool.pick(Maybe<&2, List<&2, U32>>, ws.only(rest), Some{out}, None{})
    case _:
      None{}

def string.at(xs: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case +h <> +t:
      Bool.pick(Maybe<&2, List<&2, U32>>, U32.is_eq(h, 34), string.fin(run(1n+List.length(&2, U32, t), Go{t, Nil{}, 0, False{}})), None{})
    case Nil{}:
      None{}

# the text of the JSON string literal xs (None: xs is not one)
def string(+xs: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  string.at(ws.drop(xs, ws.head(xs)))

# Objects --------------------------------------------------------------------

# An object of string fields (the one shape the corpus files hold):
# `{"k":"v", ...}`, whitespace allowed between tokens.  A key and its text.
type Kv is Data:
  Kv{k: List<&2, U32>, v: List<&2, U32>}

type Pr is Data:
  Pok{k: List<&2, U32>, v: List<&2, U32>, rest: List<&2, U32>}
  Pbad{}

def lit.at(xs: List<&2, U32>) -> St:
  match xs:
    case +h <> +t:
      Bool.pick(St, U32.is_eq(h, 34), run(1n+List.length(&2, U32, t), Go{t, Nil{}, 0, False{}}), fail())
    case Nil{}:
      fail()

def lit(+xs: List<&2, U32>) -> St:
  lit.at(ws.drop(xs, ws.head(xs)))

def after.colon(+xs: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  +r = ws.drop(xs, ws.head(xs))
  Bool.pick(Maybe<&2, List<&2, U32>>, S.head.is(r, 58), Some{List.drop(&2, U32, r, 1n)}, None{})

def pair.v(+k: List<&2, U32>, st: St) -> Pr:
  match st:
    case End{True{}, v, rest}:
      Pok{k, v, rest}
    case _:
      Pbad{}

def pair.c(+k: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> Pr:
  match m:
    case Some{r}:
      pair.v(k, lit(r))
    case None{}:
      Pbad{}

def pair.k(st: St) -> Pr:
  match st:
    case End{True{}, k, +rest}:
      pair.c(k, after.colon(rest))
    case _:
      Pbad{}

# `"k" : "v"` at the start of xs
def pair(+xs: List<&2, U32>) -> Pr:
  pair.k(lit(xs))

# the first field of an object line (the corpus's id)
def first.at(+xs: List<&2, U32>) -> Pr:
  +r = ws.drop(xs, ws.head(xs))
  Bool.pick(Pr, S.head.is(r, 123), pair(List.drop(&2, U32, r, 1n)), Pbad{})

type Os is Data:
  Om{xs: List<&2, U32>, acc: List<&2, Kv>, first: Bool}
  Od{ok: Bool, kvs: List<&2, Kv>}

def obj.pair(p: Pr, acc: List<&2, Kv>) -> Os:
  match p:
    case Pok{k, v, rest}:
      Om{rest, Kv{k, v} <> acc, False{}}
    case Pbad{}:
      Od{False{}, Nil{}}

# after a field: `,` then the next, or `}` then only whitespace; at the
# start: a field or `}`
def obj.step(+xs: List<&2, U32>, +acc: List<&2, Kv>, +first: Bool) -> Os:
  +r = ws.drop(xs, ws.head(xs))
  +close = S.head.is(r, 125)
  +comma = S.head.is(r, 44)
  Bool.pick(Os, close, Od{ws.only(List.drop(&2, U32, r, 1n)), List.reverse(&2, Kv, acc)},
    Bool.pick(Os, first, obj.pair(pair(r), acc),
      Bool.pick(Os, comma, obj.pair(pair(List.drop(&2, U32, r, 1n)), acc), Od{False{}, Nil{}})))

def obj.go(fuel: Nat, st: Os) -> Os:
  match fuel st:
    case 1n+f Om{xs, acc, +first}:
      obj.go(f, obj.step(xs, acc, first))
    case _ Od{ok, kvs}:
      Od{ok, kvs}
    case 0n Om{xs, acc, first}:
      Od{False{}, Nil{}}

def obj.fin(st: Os) -> Maybe<&2, List<&2, Kv>>:
  match st:
    case Od{True{}, kvs}:
      Some{kvs}
    case _:
      None{}

def obj.open(+xs: List<&2, U32>) -> Os:
  +r = ws.drop(xs, ws.head(xs))
  Bool.pick(Os, S.head.is(r, 123), Om{List.drop(&2, U32, r, 1n), Nil{}, True{}}, Od{False{}, Nil{}})

# the fields of a JSON object whose values are all strings (None: xs is not
# one)
def object(+xs: List<&2, U32>) -> Maybe<&2, List<&2, Kv>>:
  obj.fin(obj.go(1n+List.length(&2, U32, xs), obj.open(xs)))

# a field's text
def get(kvs: List<&2, Kv>, +k: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      None{}
    case Kv{+x, +v} <> more:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(x, k), Some{v}, get(more, k))

# Writing -------------------------------------------------------------------

def hexc(+n: U32) -> U32:
  Bool.pick(U32, U32.is_lt(n, 10), U32.add(n, 48), U32.add(n, 87))

def esc.byte(+c: U32, +rest: List<&2, U32>) -> List<&2, U32>:
  +s = Bool.pick(U32, U32.is_eq(c, 34), 34, Bool.pick(U32, U32.is_eq(c, 92), 92,
    Bool.pick(U32, U32.is_eq(c, 8), 98, Bool.pick(U32, U32.is_eq(c, 12), 102,
      Bool.pick(U32, U32.is_eq(c, 10), 110, Bool.pick(U32, U32.is_eq(c, 13), 114,
        Bool.pick(U32, U32.is_eq(c, 9), 116, 0)))))))
  +ctl = Bool.or(U32.is_lt(c, 32), U32.is_eq(c, 127))
  Bool.pick(List<&2, U32>, U32.is_ne(s, 0), 92 <> s <> rest,
    Bool.pick(List<&2, U32>, ctl, 92 <> 117 <> 48 <> 48 <> hexc(U32.div(c, 16)) <> hexc(U32.mod(c, 16)) <> rest, c <> rest))

def quote.go(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      [34]
    case +c <> t:
      esc.byte(c, quote.go(t))

# the JSON string literal for the text xs, as jq -c writes it
def quote(xs: List<&2, U32>) -> List<&2, U32>:
  34 <> quote.go(xs)

# Corpus lines -----------------------------------------------------------

# A corpus line, `{"id": ..., "text": ...}` with the id first, as
# extract-code.sh writes them (jq -c): None for anything else.
type Doc is Data:
  Doc{id: List<&2, U32>, text: List<&2, U32>}

def doc.text(+id: List<&2, U32>, p: Pr) -> Maybe<&2, Doc>:
  match p:
    case Pok{+k, +t, +r}:
      Bool.pick(Maybe<&2, Doc>, Bool.and(S.eq(k, S.b("text")), S.head.is(ws.drop(r, ws.head(r)), 125)), Some{Doc{id, t}}, None{})
    case Pbad{}:
      None{}

def doc.rest(+rest: List<&2, U32>) -> Pr:
  +r = ws.drop(rest, ws.head(rest))
  Bool.pick(Pr, S.head.is(r, 44), pair(List.drop(&2, U32, r, 1n)), Pbad{})

def doc.id(p: Pr) -> Maybe<&2, Doc>:
  match p:
    case Pok{+k, +v, +r}:
      Bool.pick(Maybe<&2, Doc>, S.eq(k, S.b("id")), doc.text(v, doc.rest(r)), None{})
    case Pbad{}:
      None{}

def doc(+line: List<&2, U32>) -> Maybe<&2, Doc>:
  doc.id(first.at(line))

# jq's `explode | map(select(. != 0)) | implode`: the bytes without NULs
def nonul(xs: List<&2, U32>) -> List<&2, U32>:
  List.filter(~U32, ~(c => U32.is_ne(c, 0)), xs)

# the line jq -c writes for {id, text} (no newline)
def line(id: List<&2, U32>, text: List<&2, U32>) -> List<&2, U32>:
  S.append(S.b("{\"id\":"), S.append(quote(id), S.append(S.b(",\"text\":"), S.append(quote(text), [125]))))
