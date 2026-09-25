import Base
import ./Sha256.bend as H
def hit.ab(+a: U32, +b: U32, +xs: List<&2, U32>) -> Bool:
  match xs:
    case x <> y <> t:
      Bool.and(U32.is_eq(x, a), U32.is_eq(y, b))
    case _:
      False{}

def tail(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case h <> t:
      t
    case Nil{}:
      Nil{}

# replace every occurrence of (a, b), left to right, by n (fuel: length)
def merge.go(fuel: Nat, +xs: List<&2, U32>, +a: U32, +b: U32, +n: U32, hit: Bool) -> List<&2, U32>:
  match fuel xs hit:
    case 1n+p x <> +t True{}:
      +r = tail(t)
      n <> merge.go(p, r, a, b, n, hit.ab(a, b, r))
    case 1n+p x <> +t False{}:
      x <> merge.go(p, t, a, b, n, hit.ab(a, b, t))
    case _ _ _:
      xs

def merge(+xs: List<&2, U32>, +a: U32, +b: U32, +n: U32) -> List<&2, U32>:
  merge.go(List.length(&2, U32, xs), xs, a, b, n, hit.ab(a, b, xs))

type LT is Data:
  LZ{}
  LL{xs: List<&2, U32>}
  LN{l: LT, r: LT}

def bit(+i: U32, +p: Nat) -> Bool:
  U32.is_eq(U32.and(U32.shrn(i, p), 1), 1)

def LT.pick(l: LT, r: LT, right: Bool) -> LT:
  match right:
    case True{}:
      r
    case False{}:
      l

def LT.get(+d: Nat, +t: LT, +i: U32) -> List<&2, U32>:
  match d t:
    case 0n LL{xs}:
      xs
    case 1n+p LN{l, r}:
      LT.get(p, LT.pick(l, r, bit(i, p)), i)
    case _ _:
      Nil{}

def none() -> U32:
  4294967295

# a pair's key in the rank table: tokens are below 2^16
def pair.key(+a: U32, +b: U32) -> U32:
  U32.or(U32.shln(a, 16n), b)

def rank.first(es: List<&2, U32>) -> U32:
  match es:
    case e <> t:
      e
    case Nil{}:
      none()

# the merge id of (a, b), or none()
def rank(+ranks: LT, +a: U32, +b: U32) -> U32:
  rank.first(LT.get(32n, ranks, pair.key(a, b)))

def head.is(~p: @+x:U32 -> Bool, +xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      p(h)
    case Nil{}:
      False{}

def is_sp(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 32), Bool.or(U32.is_eq(c, 13), U32.is_eq(c, 9)))

def skip.sp.go(+xs: List<&2, U32>, more: Bool) -> List<&2, U32>:
  match xs more:
    case h <> +t True{}:
      skip.sp.go(t, head.is(~is_sp, t))
    case _ _:
      xs

def skip.sp(+xs: List<&2, U32>) -> List<&2, U32>:
  skip.sp.go(xs, head.is(~is_sp, xs))

type Merge is Data:
  Merge{a: U32, b: U32, new: U32}

type Row is Data:
  NoRow{}
  Row{m: Merge, rest: List<&2, U32>}

def is_digit(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57))

type Num is Data:
  Num{n: U32, rest: List<&2, U32>}

def num.go(+xs: List<&2, U32>, +acc: U32, more: Bool) -> Num:
  match xs more:
    case h <> +t True{}:
      num.go(t, U32.add(U32.mul(acc, 10), U32.sub(h, 48)), head.is(~is_digit, t))
    case _ _:
      Num{acc, xs}

def num(+xs: List<&2, U32>) -> Num:
  num.go(xs, 0, head.is(~is_digit, xs))

def is_nl(+c: U32) -> Bool:
  U32.is_eq(c, 10)

# Every scanning loop below takes the decision about its NEXT element as
# a parameter computed by the caller (`head.is`), so the recursion is a
# single self-call under a match on a parameter.

# drop through the next newline
def skip.line.go(xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> t True{}:
      t
    case h <> +t False{}:
      skip.line.go(t, head.is(~is_nl, t))
    case Nil{} _:
      Nil{}

def skip.line(+xs: List<&2, U32>) -> List<&2, U32>:
  skip.line.go(xs, head.is(~is_nl, xs))

def Num.n(r: Num) -> U32:
  match r:
    case Num{n, rest}:
      n

def Num.rest(r: Num) -> List<&2, U32>:
  match r:
    case Num{n, rest}:
      rest

# one "a b new" row, or NoRow at the end of the file
def row.go(xs: List<&2, U32>) -> Row:
  match xs:
    case Nil{}:
      NoRow{}
    case h <> t:
      +ra = num(h <> t)
      +rb = num(skip.sp(Num.rest(ra)))
      +rc = num(skip.sp(Num.rest(rb)))
      Row{Merge{Num.n(ra), Num.n(rb), Num.n(rc)}, skip.line(Num.rest(rc))}

def row(+xs: List<&2, U32>) -> Row:
  row.go(skip.sp(xs))

# The fast BPE tokenizer (master: backend/src/FormalTransformer/Tokenizer.hs).
#
# Tokens: 0 = BOS, 1 = EOS, 2..257 the 256 bytes, then one token per merge
# in id order (merge id is rank).  A .bpe artifact is text: a header
# "BPE <vocab> [v2]", then one "a b new" row per merge.
def bos() -> U32:
  0

def eos() -> U32:
  1

# Index trees ------------------------------------------------------------
#
# A binary tree over U32 keys holding a list at each key: the decode
# table (depth 16; key: merge id, list: [a, b]) and the rank table (depth
# 32; key: the pair a * 65536 + b, list: the merge ids of that pair, the
# latest first).  Keying ranks by the whole pair makes a lookup 32 steps;
# keying by the left operand alone made it a scan over every merge sharing
# that operand, thousands for a code vocabulary's common prefixes.

type LP is Data:
  LP{go: LT, keep: LT}

def LT.kids(t: LT) -> LP:
  match t:
    case LN{l, r}:
      LP{l, r}
    case _:
      LP{LZ{}, LZ{}}

def LT.split(p: LP, right: Bool) -> LP:
  match p right:
    case LP{l, r} True{}:
      LP{r, l}
    case LP{l, r} False{}:
      LP{l, r}

def LT.join(right: Bool, go: LT, keep: LT) -> LT:
  match right:
    case True{}:
      LN{keep, go}
    case False{}:
      LN{go, keep}

def LP.go(p: LP) -> LT:
  match p:
    case LP{g, k}:
      g

def LP.keep(p: LP) -> LT:
  match p:
    case LP{g, k}:
      k

def LT.leaf(t: LT) -> List<&2, U32>:
  match t:
    case LL{xs}:
      xs
    case _:
      Nil{}

# prepend x to the list at key i
def LT.push(+d: Nat, +t: LT, +i: U32, +x: U32) -> LT:
  match d:
    case 0n:
      LL{x <> LT.leaf(t)}
    case 1n+p:
      +right = bit(i, p)
      +sp = LT.split(LT.kids(t), right)
      LT.join(right, LT.push(p, LP.go(sp), i, x), LP.keep(sp))

# Artifact ---------------------------------------------------------------

type Bpe is Data:
  Bpe{vocab: U32, v2: Bool, merges: List<&2, Merge>, dec: LT, ranks: LT}

def rows(fuel: Nat, r: Row) -> List<&2, Merge>:
  match fuel r:
    case 1n+p Row{m, rest}:
      m <> rows(p, row(rest))
    case _ _:
      Nil{}

def is_v(+c: U32) -> Bool:
  U32.is_eq(c, 118)

def is_2(+c: U32) -> Bool:
  U32.is_eq(c, 50)

# "v2" after the vocabulary in the header
def header.v2(+xs: List<&2, U32>) -> Bool:
  +ys = skip.sp(xs)
  Bool.and(head.is(~is_v, ys), head.is(~is_2, tail(ys)))

def build(ms: List<&2, Merge>, +dec: LT, +ranks: LT) -> LT & LT:
  match ms:
    case Nil{}:
      (dec, ranks)
    case Merge{+a, +b, +n} <> t:
      build(t, LT.push(16n, LT.push(16n, dec, n, b), n, a),
               LT.push(32n, ranks, pair.key(a, b), n))

# Merge ids must be contiguous from 258, as parseFastBpe requires.
def contiguous(ms: List<&2, Merge>, +next: U32) -> Bool:
  match ms:
    case Nil{}:
      True{}
    case Merge{a, b, n} <> t:
      Bool.and(U32.is_eq(n, next), contiguous(t, U32.inc(next)))

def Bpe.parse.tables(v: U32, v2: Bool, ms: List<&2, Merge>, t: LT & LT) -> Maybe<&2, Bpe>:
  (dec, ranks) = t
  Some{Bpe{v, v2, ms, dec, ranks}}

def Bpe.parse.fin(ok: Bool, +v: U32, v2: Bool, +ms: List<&2, Merge>) -> Maybe<&2, Bpe>:
  match ok:
    case True{}:
      Bpe.parse.tables(v, v2, ms, build(ms, LZ{}, LZ{}))
    case False{}:
      None{}

def is_B(+c: U32) -> Bool:
  U32.is_eq(c, 66)

def Bpe.parse.go(ok: Bool, +xs: List<&2, U32>) -> Maybe<&2, Bpe>:
  match ok:
    case True{}:
      +hv = num(skip.sp(List.drop(&2, U32, xs, 3n)))
      +v2 = header.v2(Num.rest(hv))
      +ms = rows(U32.to_nat(65536), row(skip.line(Num.rest(hv))))
      Bpe.parse.fin(Bool.and(contiguous(ms, 258), U32.is_eq(U32.add(258, U32.from_nat(List.length(&2, Merge, ms))), Num.n(hv))), Num.n(hv), v2, ms)
    case False{}:
      None{}

def Bpe.parse(+xs: List<&2, U32>) -> Maybe<&2, Bpe>:
  Bpe.parse.go(head.is(~is_B, xs), xs)

def Bpe.vocab(+b: Bpe) -> U32:
  match b:
    case Bpe{v, r, m, d, k}:
      v

def Bpe.v2(+b: Bpe) -> Bool:
  match b:
    case Bpe{v, r, m, d, k}:
      r

# Identity ---------------------------------------------------------------

def str.bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      c <> str.bytes(t)

def canon.rows(ms: List<&2, Merge>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      Nil{}
    case Merge{a, b, n} <> t:
      List.append(&2, U32, str.bytes(U32.show(a) ++ " " ++ U32.show(b) ++ " " ++ U32.show(n) ++ "\n"), canon.rows(t))

def rule.name(v2: Bool) -> String:
  match v2:
    case True{}:
      "ascii-space-run+lf-prefix-v2"
    case False{}:
      "ascii-space-prefix+lf-boundary"

# fastBpeIdentity: the rule is named, the digest is over the merges alone
def Bpe.identity(+b: Bpe) -> String:
  match b:
    case Bpe{+v, r, m, d, k}:
      +canon = List.append(&2, U32, str.bytes("fastbpe-word-v1\nvocab " ++ U32.show(v) ++ "\n"), canon.rows(m))
      "fastbpe-word-v1:bos=0:eos=1:bytes=2..257:pretoken=" ++ rule.name(r)
        ++ ":vocab=" ++ U32.show(v) ++ ":sha256=" ++ H.sha256(canon)

# Pretokenization ----------------------------------------------------------

def ordinary(+b: U32) -> Bool:
  Bool.and(U32.is_ne(b, 32), U32.is_ne(b, 10))

type Span is Data:
  Span{word: List<&2, U32>, rest: List<&2, U32>}

def Span.put(h: U32, s: Span) -> Span:
  match s:
    case Span{w, r}:
      Span{h <> w, r}

def is_ord(+c: U32) -> Bool:
  ordinary(c)

def is_space(+c: U32) -> Bool:
  U32.is_eq(c, 32)

# the longest prefix of ordinary bytes
def span.ord.go(+xs: List<&2, U32>, more: Bool) -> Span:
  match xs more:
    case h <> +t True{}:
      Span.put(h, span.ord.go(t, head.is(~is_ord, t)))
    case _ _:
      Span{Nil{}, xs}

def span.ord(+xs: List<&2, U32>) -> Span:
  span.ord.go(xs, head.is(~is_ord, xs))

def span.sp.go(+xs: List<&2, U32>, more: Bool) -> Span:
  match xs more:
    case h <> +t True{}:
      Span.put(h, span.sp.go(t, head.is(~is_space, t)))
    case _ _:
      Span{Nil{}, xs}

def span.sp(+xs: List<&2, U32>) -> Span:
  span.sp.go(xs, head.is(~is_space, xs))

def Span.word(s: Span) -> List<&2, U32>:
  match s:
    case Span{w, r}:
      w

def Span.rest(s: Span) -> List<&2, U32>:
  match s:
    case Span{w, r}:
      r

def v1.first.if(nl: Bool, sp: Bool, +h: U32, t: List<&2, U32>) -> Span:
  match nl sp:
    case True{} _:
      Span{[10], t}
    case False{} True{}:
      Span.put(32, span.ord(t))
    case False{} False{}:
      span.ord(h <> t)

type Words is Data:
  Words{ws: List<&2, List<&2, U32>>, rest: List<&2, U32>}

def v2.content(+rest: List<&2, U32>) -> Bool:
  match rest:
    case h <> t:
      ordinary(h)
    case Nil{}:
      False{}

def nonempty(w: List<&2, U32>, ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match w:
    case Nil{}:
      ws
    case h <> t:
      (h <> t) <> ws

def last.drop(+xs: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, xs, Nat.sub(List.length(&2, U32, xs), 1n))

def last.keep(+xs: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.sub(List.length(&2, U32, xs), 1n))

def v2.ws.if(content: Bool, +lead: List<&2, U32>, +spaces: List<&2, U32>, +rest: List<&2, U32>) -> Words:
  match content:
    case True{}:
      +o = span.ord(rest)
      Words{nonempty(List.append(&2, U32, lead, last.drop(spaces)), [List.append(&2, U32, last.keep(spaces), Span.word(o))]), Span.rest(o)}
    case False{}:
      Words{[List.append(&2, U32, lead, spaces)], rest}

# V2's first words: whitespace runs stay whole, except that a run before
# content hands its last space to the following word
def v2.ws(+lead: List<&2, U32>, rest0: List<&2, U32>) -> Words:
  +sp = span.sp(rest0)
  +rest = Span.rest(sp)
  +spaces = Span.word(sp)
  v2.ws.if(v2.content(rest), lead, spaces, rest)

def v2.first.if(nl: Bool, sp: Bool, +h: U32, t: List<&2, U32>) -> Words:
  match nl sp:
    case True{} _:
      v2.ws([10], t)
    case False{} True{}:
      v2.ws(Nil{}, h <> t)
    case False{} False{}:
      +o = span.ord(h <> t)
      Words{[Span.word(o)], Span.rest(o)}

def v2.first(+h: U32, t: List<&2, U32>) -> Words:
  v2.first.if(U32.is_eq(h, 10), U32.is_eq(h, 32), h, t)

# V1's first word: a newline alone, a space plus the ordinary run after it,
# or an ordinary run
def v1.first(+h: U32, t: List<&2, U32>) -> Span:
  v1.first.if(U32.is_eq(h, 10), U32.is_eq(h, 32), h, t)

def first(v2: Bool, +h: U32, t: List<&2, U32>) -> Words:
  match v2:
    case True{}:
      v2.first(h, t)
    case False{}:
      +s = v1.first(h, t)
      Words{[Span.word(s)], Span.rest(s)}

def Words.rest(w: Words) -> List<&2, U32>:
  match w:
    case Words{ws, r}:
      r

def Words.ws(w: Words) -> List<&2, List<&2, U32>>:
  match w:
    case Words{ws, r}:
      ws

# the words of a byte string; fuel is its length (each round consumes at
# least one byte)
def pretokenize(fuel: Nat, +v2: Bool, xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match fuel xs:
    case 1n+p h <> t:
      +w = first(v2, h, t)
      List.append(&2, List<&2, U32>, Words.ws(w), pretokenize(p, v2, Words.rest(w)))
    case _ _:
      Nil{}

# Encoding ---------------------------------------------------------------

# the lowest-ranked adjacent pair's merge id (none() when nothing merges)
def best(+ranks: LT, xs: List<&2, U32>, +acc: U32) -> U32:
  match xs:
    case +a <> +b <> t:
      best(ranks, b <> t, U32.min(acc, rank(ranks, a, b)))
    case _:
      acc

def pair.of(+dec: LT, +n: U32) -> List<&2, U32>:
  LT.get(16n, dec, n)

def merge.ab(+ab: List<&2, U32>, +xs: List<&2, U32>, +n: U32) -> List<&2, U32>:
  match ab:
    case a <> b <> t:
      merge(xs, a, b, n)
    case _:
      xs

def merge.id(+dec: LT, +xs: List<&2, U32>, +n: U32) -> List<&2, U32>:
  merge.ab(pair.of(dec, n), xs, n)

def encode.word.go(fuel: Nat, +dec: LT, +ranks: LT, +xs: List<&2, U32>, +n: U32, done: Bool) -> List<&2, U32>:
  match fuel done:
    case 1n+p False{}:
      +ys = merge.id(dec, xs, n)
      +m = best(ranks, ys, none())
      encode.word.go(p, dec, ranks, ys, m, U32.is_eq(m, none()))
    case _ _:
      xs

# The reference: master's encodeWord.  While some adjacent pair has a
# merge, take the lowest merge id among them and replace that pair's every
# occurrence, left to right without overlap, by the merged token (a merge's
# id is its token).  It looks every pair up again on every merge, so a
# word of L bytes costs O(L^2) lookups of 32 steps.
def encode.word.ref(fuel: Nat, +dec: LT, +ranks: LT, +xs: List<&2, U32>) -> List<&2, U32>:
  +n = best(ranks, xs, none())
  encode.word.go(fuel, dec, ranks, xs, n, U32.is_eq(n, none()))

# The same function, faster.  Each token carries the merge id of the pair
# it starts (none() for the last), so finding the lowest is a scan without
# lookups, and a merge sweep recomputes only the ids a merge touched: the
# merged token's own, and its left neighbour's.  The sweep takes the same
# decisions as the reference's (a token starts a merge iff its pair's id is
# the chosen one, and a merged pair is skipped whole), and a merge only
# creates pairs whose ids exceed the chosen one (a merge's operands precede
# it), so every round picks what the reference picks.
type Sym is Data:
  Sym{t: U32, r: U32}

def syms(+ranks: LT, xs: List<&2, U32>) -> List<&2, Sym>:
  match xs:
    case +a <> +b <> t:
      Sym{a, rank(ranks, a, b)} <> syms(ranks, b <> t)
    case a <> t:
      [Sym{a, none()}]
    case Nil{}:
      Nil{}

def sym.min(ss: List<&2, Sym>, +acc: U32) -> U32:
  match ss:
    case Nil{}:
      acc
    case Sym{t, r} <> more:
      sym.min(more, U32.min(acc, r))

def sym.head.t(+ss: List<&2, Sym>) -> U32:
  match ss:
    case Sym{t, r} <> more:
      t
    case Nil{}:
      none()

def sym.hit(+ss: List<&2, Sym>, +m: U32) -> Bool:
  match ss:
    case Sym{t, r} <> more:
      U32.is_eq(r, m)
    case Nil{}:
      False{}

def sym.toks(ss: List<&2, Sym>) -> List<&2, U32>:
  match ss:
    case Nil{}:
      Nil{}
    case Sym{t, r} <> more:
      t <> sym.toks(more)

# a swept tail, and whether its head was just merged (so the token before
# it starts a new pair)
type Sw is Data:
  Sw{ss: List<&2, Sym>, fresh: Bool}

def sw.merged(+ranks: LT, +n: U32, w: Sw) -> Sw:
  match w:
    case Sw{+ss, f}:
      Sw{Sym{n, rank(ranks, n, sym.head.t(ss))} <> ss, True{}}

def sw.kept.r(+ranks: LT, +a: U32, +ra: U32, +b: U32, fresh: Bool) -> U32:
  match fresh:
    case True{}:
      rank(ranks, a, b)
    case False{}:
      ra

def sw.kept(+ranks: LT, +a: U32, +ra: U32, w: Sw) -> Sw:
  match w:
    case Sw{+ss, f}:
      Sw{Sym{a, sw.kept.r(ranks, a, ra, sym.head.t(ss), f)} <> ss, False{}}

def sweep(+ranks: LT, +m: U32, ss: List<&2, Sym>, hit: Bool) -> Sw:
  match ss hit:
    case Sym{a, ra} <> Sym{b, rb} <> +rest True{}:
      sw.merged(ranks, m, sweep(ranks, m, rest, sym.hit(rest, m)))
    case Sym{+a, +ra} <> +more _:
      sw.kept(ranks, a, ra, sweep(ranks, m, more, sym.hit(more, m)))
    case Nil{} _:
      Sw{Nil{}, False{}}

def Sw.ss(w: Sw) -> List<&2, Sym>:
  match w:
    case Sw{ss, f}:
      ss

def encode.syms(fuel: Nat, +ranks: LT, +ss: List<&2, Sym>, +m: U32, done: Bool) -> List<&2, U32>:
  match fuel done:
    case 1n+p False{}:
      +next = Sw.ss(sweep(ranks, m, ss, sym.hit(ss, m)))
      +m2 = sym.min(next, none())
      encode.syms(p, ranks, next, m2, U32.is_eq(m2, none()))
    case _ _:
      sym.toks(ss)

def encode.word(fuel: Nat, +dec: LT, +ranks: LT, +xs: List<&2, U32>) -> List<&2, U32>:
  +ss = syms(ranks, xs)
  +m = sym.min(ss, none())
  encode.syms(fuel, ranks, ss, m, U32.is_eq(m, none()))

def byte.ids(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      U32.add(h, 2) <> byte.ids(t)

def encode.words(ws: List<&2, List<&2, U32>>, +dec: LT, +ranks: LT) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      List.append(&2, U32, encode.word(List.length(&2, U32, w), dec, ranks, byte.ids(w)), encode.words(t, dec, ranks))

def Bpe.encode(+b: Bpe, +bytes: List<&2, U32>) -> List<&2, U32>:
  match b:
    case Bpe{v, r, m, +dec, +ranks}:
      encode.words(pretokenize(Nat.add(List.length(&2, U32, bytes), 1n), r, bytes), dec, ranks)

# Decoding ---------------------------------------------------------------

def expand.byte(ok: Bool, +t: U32) -> List<&2, U32>:
  match ok:
    case True{}:
      [U32.sub(t, 2)]
    case False{}:
      Nil{}

def nth(+xs: List<&2, U32>, +i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, xs, i), 0)

# the bytes of one token (depth bounded by fuel; merges only refer to
# earlier tokens, so the expansion is finite)
def expand(+fuel: Nat, +dec: LT, +t: U32, byte: Bool) -> List<&2, U32>:
  match fuel byte:
    case _ True{}:
      expand.byte(U32.is_ge(t, 2), t)
    case 1n+p False{}:
      +ab = pair.of(dec, t)
      +a = nth(ab, 0n)
      +b = nth(ab, 1n)
      List.append(&2, U32, expand(p, dec, a, U32.is_lt(a, 258)), expand(p, dec, b, U32.is_lt(b, 258)))
    case 0n False{}:
      Nil{}

def Bpe.decode(+b: Bpe, +t: U32) -> List<&2, U32>:
  match b:
    case Bpe{v, r, m, +dec, k}:
      expand(64n, dec, t, U32.is_lt(t, 258))

# UTF-8 -------------------------------------------------------------------

def utf8.encode.if(one: Bool, two: Bool, three: Bool, +c: U32) -> List<&2, U32>:
  match one two three:
    case True{} _ _:
      [c]
    case False{} True{} _:
      [U32.or(192, U32.shrn(c, 6n)), U32.or(128, U32.and(c, 63))]
    case False{} False{} True{}:
      [U32.or(224, U32.shrn(c, 12n)), U32.or(128, U32.and(U32.shrn(c, 6n), 63)), U32.or(128, U32.and(c, 63))]
    case False{} False{} False{}:
      [U32.or(240, U32.shrn(c, 18n)), U32.or(128, U32.and(U32.shrn(c, 12n), 63)), U32.or(128, U32.and(U32.shrn(c, 6n), 63)), U32.or(128, U32.and(c, 63))]

# a Char as its UTF-8 bytes (env prompts arrive as scalars)
def utf8.encode(+c: U32) -> List<&2, U32>:
  utf8.encode.if(U32.is_lt(c, 128), U32.is_lt(c, 2048), U32.is_lt(c, 65536), c)

def utf8.bytes(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      List.append(&2, U32, utf8.encode(c), utf8.bytes(t))

# Complete scalars from a byte stream, and the incomplete tail to carry
# into the next token.  A byte that cannot start a scalar decodes as
# U+FFFD (the host writes raw bytes; a String can only carry scalars).
type Dec is Data:
  Dec{text: String, pending: List<&2, U32>}

def Dec.put(c: Char, d: Dec) -> Dec:
  match d:
    case Dec{s, p}:
      Dec{SCon{c, s}, p}

def cont.count.if(a: Bool, b: Bool, c: Bool, d: Bool, e: Bool) -> Nat:
  match a b c d e:
    case True{} _ _ _ _:
      0n
    case False{} True{} _ _ _:
      9n
    case False{} False{} True{} _ _:
      1n
    case False{} False{} False{} True{} _:
      2n
    case False{} False{} False{} False{} True{}:
      3n
    case _ _ _ _ _:
      9n

def cont.count(+b: U32) -> Nat:
  cont.count.if(U32.is_lt(b, 128), U32.is_lt(b, 192), U32.is_lt(b, 224), U32.is_lt(b, 240), U32.is_lt(b, 248))

def Nat.sel.u32(b: Bool, x: U32, y: U32) -> U32:
  match b:
    case True{}:
      x
    case False{}:
      y

def lead.mask(+n: Nat) -> U32:
  Nat.sel.u32(Nat.is_eq(n, 0n), 127, Nat.sel.u32(Nat.is_eq(n, 1n), 31, Nat.sel.u32(Nat.is_eq(n, 2n), 15, 7)))

def conts(xs: List<&2, U32>, acc: U32) -> U32:
  match xs:
    case Nil{}:
      acc
    case h <> t:
      conts(t, U32.or(U32.shln(acc, 6n), U32.and(h, 63)))

def Nat.sel(b: Bool, x: Nat, y: Nat) -> Nat:
  match b:
    case True{}:
      x
    case False{}:
      y

def utf8.mode.go(+h: U32, +t: List<&2, U32>) -> Nat:
  +n = cont.count(h)
  Nat.sel(Nat.is_eq(n, 9n), 0n, Nat.sel(Nat.is_le(n, List.length(&2, U32, t)), 1n, 2n))

# 0: a byte that cannot start a scalar, 1: a complete scalar, 2: an
# incomplete tail (or the end)
def utf8.mode(+xs: List<&2, U32>) -> Nat:
  match xs:
    case h <> t:
      utf8.mode.go(h, t)
    case Nil{}:
      2n

def utf8.decode(fuel: Nat, +xs: List<&2, U32>, mode: Nat) -> Dec:
  match fuel xs mode:
    case 1n+p h <> +t 0n:
      Dec.put(Chr{65533}, utf8.decode(p, t, utf8.mode(t)))
    case 1n+p +h <> +t 1n:
      +n = cont.count(h)
      +rest = List.drop(&2, U32, t, n)
      Dec.put(Chr{conts(List.take(&2, U32, t, n), U32.and(h, lead.mask(n)))}, utf8.decode(p, rest, utf8.mode(rest)))
    case _ _ _:
      Dec{SNil{}, xs}
