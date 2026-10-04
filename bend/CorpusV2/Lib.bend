import Base
import ../Sys.bend as S
import ../Json.bend as J
import ../Sha256.bend as H

# What every corpus v2 tool shares (docs/CORPUS-V2.md): where an id comes
# from, the content key, the JSON lines the v2 files are written in, and the
# holdout's exclusion lists. Text is bytes (List<&2, U32>, UTF-8) throughout.

# Bytes ----------------------------------------------------------------------
#
# Every name here starts with `v2.`: a Bend program's definitions share one
# namespace across its imports, and a same-named def silently replaces
# another module's (Units' `run` replaced Json's and hung J.doc), so this
# module imports no Units and names nothing another module names.

def v2.concat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xss:
    case Nil{}:
      Nil{}
    case xs <> more:
      List.append(&2, U32, xs, v2.concat(more))

def v2.nth(xss: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  match xss i:
    case Nil{} _:
      Nil{}
    case xs <> more 0n:
      xs
    case xs <> more 1n+k:
      v2.nth(more, k)

def v2.byte.head(xs: List<&2, U32>) -> U32:
  match xs:
    case Nil{}:
      0
    case +h <> t:
      h

# Bend evaluates both arguments of Bool.pick, so a recursion never sits in
# one: each scan carries whether the head is the byte it looks for (`at`,
# computed for the next element by the step before), as Transcript.bend's
# split.go does, and matches on it.

def v2.byte.at(xs: List<&2, U32>, +i: Nat) -> U32:
  v2.byte.head(List.drop(&2, U32, xs, i))

def v2.head.is(+xs: List<&2, U32>, +c: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      U32.is_eq(h, c)

def v2.lower.byte(+c: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), U32.add(c, 32), c)

# ASCII letters lowered (repository names are ASCII; Python's lower agrees there)
def v2.lower(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      v2.lower.byte(h) <> v2.lower(t)

# the bytes before the first c (all of xs when there is none)
def v2.before.go(xs: List<&2, U32>, +c: U32, acc: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t False{}:
      v2.before.go(t, c, h <> acc, v2.head.is(t, c))
    case _ _:
      List.reverse(&2, U32, acc)

def v2.before(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  v2.before.go(xs, c, Nil{}, v2.head.is(xs, c))

# the bytes after the first c (all of xs when there is none: Python's
# `x.split(c, 1)[-1]`)
def v2.after.go(xs: List<&2, U32>, +c: U32, all: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> t True{}:
      t
    case h <> +t False{}:
      v2.after.go(t, c, all, v2.head.is(t, c))
    case Nil{} _:
      all

def v2.after(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  v2.after.go(xs, c, xs, v2.head.is(xs, c))

def v2.has.go(xs: List<&2, U32>, +c: U32, at: Bool) -> Bool:
  match xs at:
    case h <> +t False{}:
      v2.has.go(t, c, v2.head.is(t, c))
    case Nil{} _:
      False{}
    case _ True{}:
      True{}

def v2.has(+xs: List<&2, U32>, +c: U32) -> Bool:
  v2.has.go(xs, c, v2.head.is(xs, c))

# the bytes after the first occurrence of the bytes p (all of xs when none)
def v2.after.at(+xs: List<&2, U32>, +p: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case None{}:
      xs
    case Some{+k}:
      List.drop(&2, U32, xs, Nat.add(k, S.len(p)))

def v2.after.str(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  v2.after.at(xs, p, S.find(xs, p, 0n))

# everything before the last c ("" when there is none: Python's
# `p.rsplit(c, 1)[0] if c in p else ""`)
def v2.parent(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  +r = List.reverse(&2, U32, xs)
  Bool.pick(List<&2, U32>, v2.has(xs, c), List.reverse(&2, U32, v2.after(r, c)), Nil{})

# Names ------------------------------------------------------------------------
#
# A training id names the repository or package it came from, folded so that
# forks and owner prefixes meet (tools/corpus-v2's old names.py, byte for
# byte): hackage:pkg/.. -> pkg; repo:owner__name/.. or repo:name/.. -> name;
# curated:/own:name/.. -> name; hf:<dataset>:owner/repo/.. -> repo; another
# hf:<dataset>/.. -> hf:<dataset>. Everything after `#` (a unit's
# declaration) is the file's, not the name's.

def v2.strip.git(+xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.suffix(xs, S.b(".git")), List.take(&2, U32, xs, Nat.sub(S.len(xs), 4n)), xs)

def v2.repo.hf(+rest: List<&2, U32>) -> List<&2, U32>:
  +parts = S.split(v2.after(rest, 58), 47)
  Bool.pick(List<&2, U32>, v2.has(rest, 58),
    v2.lower(Bool.pick(List<&2, U32>, Nat.is_lt(1n, List.length(&2, List<&2, U32>, parts)), v2.nth(parts, 1n), v2.nth(parts, 0n))),
    S.append(S.b("hf:"), v2.lower(v2.before(rest, 47))))

def v2.repo.of(+id: List<&2, U32>) -> List<&2, U32>:
  +i = v2.before(id, 35)
  +rest = Bool.pick(List<&2, U32>, v2.has(i, 58), v2.after(i, 58), i)
  +name = v2.before(rest, 47)
  Bool.pick(List<&2, U32>, S.prefix(i, S.b("hf:")), v2.repo.hf(List.drop(&2, U32, i, 3n)),
    v2.strip.git(v2.lower(v2.after.str(name, S.b("__")))))

def v2.path.hf(+rest: List<&2, U32>) -> List<&2, U32>:
  S.join(List.drop(&2, List<&2, U32>, S.split(v2.after(rest, 58), 47), 2n), 47)

def v2.path.of(+id: List<&2, U32>) -> List<&2, U32>:
  +i = v2.before(id, 35)
  +rest = Bool.pick(List<&2, U32>, v2.has(i, 58), v2.after(i, 58), i)
  Bool.pick(List<&2, U32>, Bool.and(S.prefix(i, S.b("hf:")), v2.has(List.drop(&2, U32, i, 3n), 58)), v2.path.hf(List.drop(&2, U32, i, 3n)),
    Bool.pick(List<&2, U32>, v2.has(rest, 47), v2.after(rest, 47), Nil{}))

# Content key ----------------------------------------------------------------
#
# "Already seen" (the old norm_hash.py): the sha256, as hex, of the text with
# CRLF as LF, every line's trailing whitespace dropped (Python's str.isspace:
# \t \n \v \f \r, 0x1C-0x1F, space, U+0085, U+00A0, U+1680, U+2000-U+200A,
# U+2028, U+2029, U+202F, U+205F, U+3000) and the leading and trailing
# newlines dropped.

def v2.crlf.at(+xs: List<&2, U32>) -> Bool:
  Bool.and(U32.is_eq(v2.byte.at(xs, 0n), 13), U32.is_eq(v2.byte.at(xs, 1n), 10))

def v2.crlf.go(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      v2.crlf.go(t, v2.crlf.at(t))
    case h <> +t False{}:
      h <> v2.crlf.go(t, v2.crlf.at(t))
    case Nil{} _:
      Nil{}

def v2.crlf(+xs: List<&2, U32>) -> List<&2, U32>:
  v2.crlf.go(xs, v2.crlf.at(xs))

# the bytes the whitespace character ending a line takes, read backwards (a its
# last byte, b and c the ones before): 0 when it is not whitespace
def v2.ws.len(+a: U32, +b: U32, +c: U32) -> Nat:
  +ascii = Bool.or(Bool.and(U32.is_le(9, a), U32.is_le(a, 13)), Bool.and(U32.is_le(28, a), U32.is_le(a, 32)))
  # U+0085, U+00A0: C2 85, C2 A0
  +two = Bool.and(U32.is_eq(b, 194), Bool.or(U32.is_eq(a, 133), U32.is_eq(a, 160)))
  # U+1680: E1 9A 80; U+2000-200A, 2028, 2029, 202F: E2 80 xx; U+205F: E2 81 9F; U+3000: E3 80 80
  +e2 = Bool.and(U32.is_eq(c, 226), Bool.or(Bool.and(U32.is_eq(b, 128), Bool.or(Bool.and(U32.is_le(128, a), U32.is_le(a, 138)),
          Bool.or(U32.is_eq(a, 168), Bool.or(U32.is_eq(a, 169), U32.is_eq(a, 175))))), Bool.and(U32.is_eq(b, 129), U32.is_eq(a, 159))))
  +three = Bool.or(Bool.and(U32.is_eq(c, 225), Bool.and(U32.is_eq(b, 154), U32.is_eq(a, 128))),
    Bool.or(e2, Bool.and(U32.is_eq(c, 227), Bool.and(U32.is_eq(b, 128), U32.is_eq(a, 128)))))
  Bool.pick(Nat, ascii, 1n, Bool.pick(Nat, two, 2n, Bool.pick(Nat, three, 3n, 0n)))

def v2.ws.n(+rv: List<&2, U32>) -> Nat:
  v2.ws.len(v2.byte.at(rv, 0n), v2.byte.at(rv, 1n), v2.byte.at(rv, 2n))

# a reversed line less its leading (so the line's trailing) whitespace: n the
# bytes the head's whitespace character takes (0: none); fuel at least the
# line's length
def v2.ws.drop(fuel: Nat, rv: List<&2, U32>, n: Nat) -> List<&2, U32>:
  match fuel n:
    case 1n+f 1n+k:
      +r = List.drop(&2, U32, rv, 1n+k)
      v2.ws.drop(f, r, v2.ws.n(r))
    case _ _:
      rv

def v2.rstrip(+line: List<&2, U32>) -> List<&2, U32>:
  +rv = List.reverse(&2, U32, line)
  List.reverse(&2, U32, v2.ws.drop(S.len(line), rv, v2.ws.n(rv)))

def v2.rstrip.all(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      v2.rstrip(l) <> v2.rstrip.all(t)

def v2.nl.drop.go(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      v2.nl.drop.go(t, v2.head.is(t, 10))
    case r _:
      r

def v2.nl.drop(+xs: List<&2, U32>) -> List<&2, U32>:
  v2.nl.drop.go(xs, v2.head.is(xs, 10))

# the normalised text the key hashes
def v2.norm(+text: List<&2, U32>) -> List<&2, U32>:
  +joined = S.join(v2.rstrip.all(S.split(v2.crlf(text), 10)), 10)
  List.reverse(&2, U32, v2.nl.drop(List.reverse(&2, U32, v2.nl.drop(joined))))

def v2.key(+text: List<&2, U32>) -> String:
  H.sha256(v2.norm(text))

# JSON lines as Python wrote them ------------------------------------------------
#
# `json.dumps({"id": i, "text": t}, ensure_ascii=False)`: `"` and `\`
# escaped, \b \f \n \r \t, every other byte below 0x20 as \u00xx (DEL and
# everything above as it stands, unlike jq's 0x7F).

def v2.py.esc(+c: U32, +rest: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_eq(c, 127), c <> rest, J.esc.byte(c, rest))

def v2.py.quote.go(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      [34]
    case +c <> t:
      v2.py.esc(c, v2.py.quote.go(t))

def v2.py.quote(xs: List<&2, U32>) -> List<&2, U32>:
  34 <> v2.py.quote.go(xs)

# the line, with its newline
def v2.py.line(id: List<&2, U32>, text: List<&2, U32>) -> List<&2, U32>:
  v2.concat([S.b("{\"id\": "), v2.py.quote(id), S.b(", \"text\": "), v2.py.quote(text), [125, 10]])

# The holdout --------------------------------------------------------------------
#
# run/v2/holdout/ (holdout.bend): units.tsv's units (a repository, a
# repository/directory, a dataset/record), exclude.paths (repository TAB path)
# and exclude.sha256 (content keys). An id is held out when its repository,
# its file's directory or its file is a unit, or its repository/path is
# listed; a file's text also when its key is listed.

type Excl is Data:
  Excl{units: Set(), paths: Set(), keys: Set()}

def v2.lines.str(ws: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> more:
      S.str(w) <> v2.lines.str(more)

def v2.firsts(ws: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> more:
      S.str(v2.before(w, 9)) <> v2.firsts(more)

def v2.ex.load(+dir: String) -> IO(Excl):
  do IO<Excl>:
    u : List<&2, U32> <- S.read(dir ++ "/units.tsv")
    p : List<&2, U32> <- S.read(dir ++ "/exclude.paths")
    k : List<&2, U32> <- S.read(dir ++ "/exclude.sha256")
    return Excl{Set.from_list(v2.firsts(List.drop(&2, List<&2, U32>, S.split.lines(u), 1n))), Set.from_list(v2.lines.str(S.split.lines(p))), Set.from_list(v2.lines.str(S.split.lines(k)))}

def v2.in.fin(r: Set() & Bool) -> Bool:
  (t, b) = r
  b

def v2.in(s: Set(), +k: String) -> Bool:
  v2.in.fin(Set.has(s, k))

def v2.ex.units(+e: Excl) -> Set():
  match e:
    case Excl{u, p, k}:
      u

def v2.ex.paths(+e: Excl) -> Set():
  match e:
    case Excl{u, p, k}:
      p

def v2.ex.keys(+e: Excl) -> Set():
  match e:
    case Excl{u, p, k}:
      k

# held out by the id alone (a unit, or a listed repository/path)
def v2.held.id(+e: Excl, +id: List<&2, U32>) -> Bool:
  +r = v2.repo.of(id)
  +p = v2.path.of(id)
  +slash = S.append(r, [47])
  Bool.or(Bool.or(v2.in(v2.ex.units(e), S.str(r)), v2.in(v2.ex.units(e), S.str(S.append(slash, v2.parent(p, 47))))),
    Bool.or(v2.in(v2.ex.units(e), S.str(S.append(slash, p))), v2.in(v2.ex.paths(e), S.str(v2.concat([r, [9], p])))))

def v2.held.key(+e: Excl, +k: String) -> Bool:
  v2.in(v2.ex.keys(e), k)
