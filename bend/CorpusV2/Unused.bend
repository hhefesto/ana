import Base
import ../Sys.bend as S
import ../Json.bend as J
import ./Keyed.bend as K
import ./Combine.bend as Cb

# unused: the records of a pool that no stream has used yet (2026-10-15, the
# run-4 plan's item 2: run 4 trains on raw code run 3 never saw).
#
#   bend-corpus-v2 unused POOL OUT SEEN...
#   bend-corpus-v2 unused POOL=OUT [POOL=OUT...] SEEN...   several pools, SEEN read once (no `=` in SEEN)
#
# Meaning.  POOL is a JSONL file, a {"id","text"} object a line.  A line's id
# is its first member's text when that member is "id" (the object led by its
# id, as bend-extract writes them, keyed-order's kor.line.id and J.doc read
# them; escapes decoded as jq decodes them); a line without one is no record
# and is passed over.  Each SEEN is a record stream as `c2.is.jsonl` tells
# them apart (CorpusV2.bend): a path ending in .jsonl is such lines, any other
# NUL pairs (id NUL text NUL), the id the pair's first field.  OUT holds the
# lines of POOL whose id is the id of no SEEN record, in POOL's own order,
# each with its newline.  The ids are compared as bytes.
#
# The refinement.  A Bend process cannot hold a million ids, so the sets live
# in files: one pass writes each SEEN record's id as hex (`HEX NL`: a hex id
# sorts as its bytes do and holds no tab or newline), and one pass each POOL
# record's (`HEX TAB LINE NL`, LINE its line's number from 0, twelve digits);
# spawned `LC_ALL=C sort` processes order both bytewise (the SEEN spool with
# -u); a merge of the two sorted spools in Bend, a line of each at a time,
# writes the LINE of every POOL record whose id the SEEN spool lacks; sort
# orders those numbers (twelve digits: bytewise is numeric); a last pass over
# POOL writes the lines so numbered.  The spools sit next to OUT (OUT.unu-*;
# SEEN's next to the first OUT) and are removed at the end; memory is a chunk
# plus the longest record.  The passes over the streams fan out to this
# program's own workers, PROCS (8) at a time (one a SEEN stream or a pool, then
# one a pool's merge and write; PROCS 1: all in this process): a stream is read
# at about 2-3.5 MB/s, so run 3's mix (6.2 GB) is the long pole, read once
# however many pools are given.
#
# The counts go to stderr, stamped UTC-6: the pool's records (and its lines
# that are none), the SEEN records read and their distinct ids, the kept and
# the dropped.  Run from anywhere; every path is the caller's.  Every def is
# prefixed `unu.`; the laws are bend/tests/unused.bend.

def unu.log(+msg: String) -> IO(Unit):
  K.kor.log("unused", msg)

def unu.need(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      K.kor.die("unused", msg)

# Ids (pure) -------------------------------------------------------------------------------

# a path read as JSONL lines (c2.is.jsonl's rule), else as NUL pairs
def unu.is.jsonl(+path: String) -> Bool:
  S.suffix(S.b(path), S.b(".jsonl"))

# an id as lowercase hex, two digits a byte (bytewise order kept)
def unu.hex(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      J.hexc(U32.div(c, 16)) <> J.hexc(U32.mod(c, 16)) <> unu.hex(t)

# A string literal cut from the front of a text: its bytes up to and with the
# closing quote, the text after it, and whether it closed.
type UnuLit is Data:
  UnuLit{lit: List<&2, U32>, rest: List<&2, U32>, ok: Bool}

def unu.lit.put(+h: U32, r: UnuLit) -> UnuLit:
  match r:
    case UnuLit{l, t, ok}:
      UnuLit{h <> l, t, ok}

# what the head of xs is inside a literal: 2 escaped (the byte before was a
# backslash), 1 the closing quote, 0 a byte of the text
def unu.lit.st(+xs: List<&2, U32>, +esc: Bool) -> Nat:
  Bool.pick(Nat, esc, 2n, Bool.pick(Nat, S.head.is(xs, 34), 1n, 0n))

# after the opening quote; st is the head's (unu.lit.st), so the walk stops
# at the closing quote without looking past it
def unu.lit.go(xs: List<&2, U32>, st: Nat) -> UnuLit:
  match xs st:
    case Nil{} _:
      UnuLit{Nil{}, Nil{}, False{}}
    case h <> t 1n:
      UnuLit{[34], t, True{}}
    case +h <> +t 2n:
      unu.lit.put(h, unu.lit.go(t, unu.lit.st(t, False{})))
    case +h <> +t _:
      unu.lit.put(h, unu.lit.go(t, unu.lit.st(t, U32.is_eq(h, 92))))

def unu.lit.at(q: Bool, +r: List<&2, U32>) -> UnuLit:
  match q:
    case True{}:
      +t = List.drop(&2, U32, r, 1n)
      unu.lit.put(34, unu.lit.go(t, unu.lit.st(t, False{})))
    case False{}:
      UnuLit{Nil{}, Nil{}, False{}}

# the literal at the front of xs (after blanks), as J.string reads it
def unu.lit(+xs: List<&2, U32>) -> UnuLit:
  +r = J.ws.drop(xs, J.ws.head(xs))
  unu.lit.at(S.head.is(r, 34), r)

def unu.id.val(+key: Maybe<&2, List<&2, U32>>, v: UnuLit) -> Maybe<&2, List<&2, U32>>:
  match v:
    case UnuLit{+l, r, True{}}:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(Maybe.default(&2, List<&2, U32>, key, Nil{}), S.b("id")), J.string(l), None{})
    case UnuLit{l, r, False{}}:
      None{}

def unu.id.key(k: UnuLit) -> Maybe<&2, List<&2, U32>>:
  match k:
    case UnuLit{+l, +r, True{}}:
      +c = J.ws.drop(r, J.ws.head(r))
      Bool.pick(Maybe<&2, List<&2, U32>>, S.head.is(c, 58), unu.id.val(J.string(l), unu.lit(List.drop(&2, U32, c, 1n))), None{})
    case UnuLit{l, r, False{}}:
      None{}

# a JSONL line's id: the text of its first member when that is "id" (J.first.at's
# reading, touching only the bytes up to the id's closing quote)
def unu.id(+l: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  +r = J.ws.drop(l, J.ws.head(l))
  Bool.pick(Maybe<&2, List<&2, U32>>, S.head.is(r, 123), unu.id.key(unu.lit(List.drop(&2, U32, r, 1n))), None{})

# the heads of a and b: 0 a's is lower (or a ended first), 2 b's is (or b
# ended first), 1 the same byte, 3 both ended
def unu.hd.cmp(+a: List<&2, U32>, +b: List<&2, U32>) -> Nat:
  match a b:
    case Nil{} Nil{}:
      3n
    case Nil{} y <> t:
      0n
    case x <> s Nil{}:
      2n
    case +x <> s +y <> t:
      Bool.pick(Nat, U32.is_lt(x, y), 0n, Bool.pick(Nat, U32.is_lt(y, x), 2n, 1n))

def unu.cmp.go(a: List<&2, U32>, b: List<&2, U32>, c: Nat) -> Nat:
  match a b c:
    case x <> +s y <> +t 1n:
      unu.cmp.go(s, t, unu.hd.cmp(s, t))
    case _ _ 0n:
      0n
    case _ _ 2n:
      2n
    case _ _ _:
      1n

# bytewise order, as LC_ALL=C sort compares: 0 a < b, 1 a = b, 2 a > b
def unu.cmp(+a: List<&2, U32>, +b: List<&2, U32>) -> Nat:
  unu.cmp.go(a, b, unu.hd.cmp(a, b))

# a line number as twelve digits (sort's bytewise order is then numeric)
def unu.pad(+n: Nat) -> String:
  +s = Nat.show(n)
  String.repeat("0", Nat.sub(12n, String.length(s))) ++ s

def unu.seen.rec(+id: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, unu.hex(id), [10])

def unu.pool.rec(+id: List<&2, U32>, +i: Nat) -> List<&2, U32>:
  List.concat(&2, U32, [unu.hex(id), [9], S.b(unu.pad(i)), [10]])

# a sorted pool spool line: its hex id (before the tab) and its line number
def unu.tab.before(+l: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, l, Maybe.default(&2, Nat, S.find(l, [9], 0n), S.len(l)))

def unu.pool.num(+l: List<&2, U32>) -> Nat:
  K.kor.nat(List.drop(&2, U32, l, 1n+S.len(unu.tab.before(l))))

# Pass 1: the spools -------------------------------------------------------------------------
#
# One reader (S.Rd) over a stream: JSONL lines or NUL pairs; n the records
# written, skip the lines that held none, line the next line's number (POOL).
# (A walk of File.read_bytes' chunks a byte at a time, keeping only each line's
# id, was tried on run 3's mix on 2026-10-15 and was no faster: 3 MB/s against
# S.Rd's 3.5.)

type UnuSp is Type:
  UnuSp{r: S.Rd, o: File, n: Nat, skip: Nat, line: Nat, more: Bool}

def unu.sp.emit(+pool: Bool, +l: Nat, +id: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, pool, unu.pool.rec(id, l), unu.seen.rec(id))

def unu.sp.line(m: Maybe<&2, List<&2, U32>>, +pool: Bool, r: S.Rd, o: File, +n: Nat, +k: Nat, +l: Nat) -> IO(UnuSp):
  match m:
    case None{}:
      IO.pure(UnuSp, UnuSp{r, o, n, 1n+k, 1n+l, True{}})
    case Some{+id}:
      do IO<UnuSp>:
        o2 : File <- S.emit(o, unu.sp.emit(pool, l, id))
        return UnuSp{r, o2, 1n+n, k, 1n+l, True{}}

def unu.sp.pair(o: File, +n: Nat, +k: Nat, +l: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(UnuSp):
  (r, m) = x
  match m:
    case None{}:
      do IO<UnuSp>:
        S.Rd.close(r)
        File.close(o)
        IO.die(UnuSp, 1, "unused: a NUL stream ends with an id that has no text (an odd number of NUL fields)")
    case Some{t}:
      do IO<UnuSp>:
        o2 : File <- S.emit(o, unu.seen.rec(id))
        return UnuSp{r, o2, 1n+n, k, l, True{}}

def unu.sp.rec(m: Maybe<&2, List<&2, U32>>, jsonl: Bool, +pool: Bool, r: S.Rd, o: File, +n: Nat, +k: Nat, +l: Nat) -> IO(UnuSp):
  match m jsonl:
    case None{} _:
      IO.pure(UnuSp, UnuSp{r, o, n, k, l, False{}})
    case Some{+x} True{}:
      unu.sp.line(unu.id(x), pool, r, o, n, k, l)
    case Some{+id} False{}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, UnuSp, S.Rd.next(r), unu.sp.pair(o, n, k, l, id))

def unu.sp.got(+jsonl: Bool, +pool: Bool, o: File, +n: Nat, +k: Nat, +l: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(UnuSp):
  (r, m) = x
  unu.sp.rec(m, jsonl, pool, r, o, n, k, l)

def unu.sp.step(+jsonl: Bool, +pool: Bool, s: UnuSp) -> IO(UnuSp):
  match s:
    case UnuSp{r, o, +n, +k, +l, m}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, UnuSp, S.Rd.next(r), unu.sp.got(jsonl, pool, o, n, k, l))

def unu.sp.go(fuel: Nat, +jsonl: Bool, +pool: Bool, s: UnuSp) -> IO(UnuSp):
  match fuel s:
    case 1n+f UnuSp{r, o, n, k, l, True{}}:
      IO.bind(UnuSp, UnuSp, unu.sp.step(jsonl, pool, UnuSp{r, o, n, k, l, True{}}), unu.sp.go(f, jsonl, pool))
    case _ s2:
      IO.pure(UnuSp, s2)

# the counts of one stream: records spooled, lines that held none
type UnuN is Data:
  UnuN{n: Nat, skip: Nat}

def unu.sp.fin(s: UnuSp) -> IO(UnuN):
  match s:
    case UnuSp{r, o, n, k, l, m}:
      do IO<UnuN>:
        S.Rd.close(r)
        File.close(o)
        return UnuN{n, k}

# one stream's ids into the spool: the pool's written afresh ("w"), each
# SEEN stream's appended ("a")
def unu.spool(+pool: Bool, +path: String, +spool: String) -> IO(UnuN):
  +jsonl = unu.is.jsonl(path)
  do IO<UnuN>:
    r : S.Rd <- S.Rd.of(path, Bool.pick(U32, jsonl, 10, 0))
    o : File <- IO.try(File, File.open(spool, Bool.pick(String, pool, "w", "a")))
    s : UnuSp <- unu.sp.go(K.kor.fuel(), jsonl, pool, UnuSp{r, o, 0n, 0n, 0n, True{}})
    unu.sp.fin(s)

def unu.n.add(+a: UnuN, +b: UnuN) -> UnuN:
  match a b:
    case UnuN{n1, k1} UnuN{n2, k2}:
      UnuN{Nat.add(n1, n2), Nat.add(k1, k2)}

def unu.n.n(+a: UnuN) -> Nat:
  match a:
    case UnuN{n, k}:
      n

def unu.n.skip(+a: UnuN) -> Nat:
  match a:
    case UnuN{n, k}:
      k

# every SEEN stream's ids appended to one spool (made empty first by the caller)
def unu.spool.all(ps: List<&2, String>, +spool: String) -> IO(UnuN):
  match ps:
    case Nil{}:
      IO.pure(UnuN, UnuN{0n, 0n})
    case +p <> t:
      do IO<UnuN>:
        +c : UnuN <- unu.spool(False{}, p, spool)
        K.kor.log("unused", "seen: " ++ Nat.show(unu.n.n(c)) ++ " records in " ++ p)
        +rest : UnuN <- unu.spool.all(t, spool)
        return unu.n.add(c, rest)

# Pass 2: sort ---------------------------------------------------------------------------------

def unu.sort.ok(+o: S.Out) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(S.Out.status(o), 0), IO.pure(Unit, Unit{}),
    IO.die(Unit, 1, "unused: sort failed (exit " ++ U32.show(S.Out.status(o)) ++ "): " ++ S.str(S.lines.take(S.Out.text(o), 5n))))

# `LC_ALL=C sort [-u] -S 1G -T DIR -o SORTED SPOOL`: bytewise, whole lines
def unu.sort(uniq: Bool, +dir: String, +spool: String, +sorted: String) -> IO(Unit):
  u = Bool.pick(List<String>, uniq, ["-u"], Nil{})
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 2000000, "sort", List.append(&1, String, u, ["-S", "1G", "-T", dir, "-o", sorted, spool]), Nil{})
    unu.sort.ok(o)

# Pass 3: the merge -------------------------------------------------------------------------------
#
# The pool spool's lines against the SEEN spool's, both sorted: cur is the SEEN
# id not yet passed (None past the last); every pool record whose id is not
# cur once cur is past it is kept (its line number written), else dropped.

type UnuMg is Type:
  UnuMg{p: S.Rd, s: S.Rd, cur: Maybe<&2, List<&2, U32>>, o: File, kept: Nat, dropped: Nat, more: Bool}

type UnuAd is Type:
  UnuAd{s: S.Rd, cur: Maybe<&2, List<&2, U32>>, more: Bool}

def unu.ad.next(x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(UnuAd):
  (s, m) = x
  IO.pure(UnuAd, UnuAd{s, m, True{}})

def unu.ad.cmp(c: Nat, s: S.Rd, +cur: List<&2, U32>) -> IO(UnuAd):
  match c:
    case 0n:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, UnuAd, S.Rd.next(s), unu.ad.next)
    case _:
      IO.pure(UnuAd, UnuAd{s, Some{cur}, False{}})

# SEEN read on while its id is below the pool's
def unu.ad.go(fuel: Nat, +id: List<&2, U32>, a: UnuAd) -> IO(S.Rd & Maybe<&2, List<&2, U32>>):
  match fuel a:
    case 1n+f UnuAd{s, Some{+c}, True{}}:
      IO.bind(UnuAd, S.Rd & Maybe<&2, List<&2, U32>>, unu.ad.cmp(unu.cmp(c, id), s, c), unu.ad.go(f, id))
    case _ UnuAd{s, m, g}:
      IO.pure(S.Rd & Maybe<&2, List<&2, U32>>, (s, m))

def unu.same(m: Maybe<&2, List<&2, U32>>, +id: List<&2, U32>) -> Bool:
  match m:
    case Some{+c}:
      S.eq(c, id)
    case None{}:
      False{}

def unu.mg.dec(hit: Bool, p: S.Rd, s: S.Rd, m: Maybe<&2, List<&2, U32>>, o: File, +k: Nat, +d: Nat, +num: Nat) -> IO(UnuMg):
  match hit:
    case True{}:
      IO.pure(UnuMg, UnuMg{p, s, m, o, k, 1n+d, True{}})
    case False{}:
      do IO<UnuMg>:
        o2 : File <- S.emit(o, S.b(unu.pad(num) ++ "\n"))
        return UnuMg{p, s, m, o2, 1n+k, d, True{}}

def unu.mg.at(p: S.Rd, o: File, +k: Nat, +d: Nat, +id: List<&2, U32>, +num: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(UnuMg):
  (s, +m) = x
  unu.mg.dec(unu.same(m, id), p, s, m, o, k, d, num)

def unu.mg.rec(m: Maybe<&2, List<&2, U32>>, p: S.Rd, s: S.Rd, cur: Maybe<&2, List<&2, U32>>, o: File, +k: Nat, +d: Nat) -> IO(UnuMg):
  match m:
    case None{}:
      IO.pure(UnuMg, UnuMg{p, s, cur, o, k, d, False{}})
    case Some{+l}:
      +id = unu.tab.before(l)
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, UnuMg, unu.ad.go(K.kor.fuel(), id, UnuAd{s, cur, True{}}), unu.mg.at(p, o, k, d, id, unu.pool.num(l)))

def unu.mg.got(s: S.Rd, cur: Maybe<&2, List<&2, U32>>, o: File, +k: Nat, +d: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(UnuMg):
  (p, m) = x
  unu.mg.rec(m, p, s, cur, o, k, d)

def unu.mg.step(g: UnuMg) -> IO(UnuMg):
  match g:
    case UnuMg{p, s, cur, o, +k, +d, m}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, UnuMg, S.Rd.next(p), unu.mg.got(s, cur, o, k, d))

def unu.mg.go(fuel: Nat, g: UnuMg) -> IO(UnuMg):
  match fuel g:
    case 1n+f UnuMg{p, s, c, o, k, d, True{}}:
      IO.bind(UnuMg, UnuMg, unu.mg.step(UnuMg{p, s, c, o, k, d, True{}}), unu.mg.go(f))
    case _ g2:
      IO.pure(UnuMg, g2)

# kept and dropped
def unu.mg.fin(g: UnuMg) -> IO(Nat & Nat):
  match g:
    case UnuMg{p, s, c, o, k, d, m}:
      do IO<Nat & Nat>:
        S.Rd.close(p)
        S.Rd.close(s)
        File.close(o)
        return (k, d)

def unu.merge.at(p: S.Rd, o: File, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Nat & Nat):
  (s, m) = x
  IO.bind(UnuMg, Nat & Nat, unu.mg.go(K.kor.fuel(), UnuMg{p, s, m, o, 0n, 0n, True{}}), unu.mg.fin)

def unu.merge(+pool: String, +seen: String, +out: String) -> IO(Nat & Nat):
  do IO<Nat & Nat>:
    p : S.Rd <- S.Rd.lines(pool)
    s : S.Rd <- S.Rd.lines(seen)
    o : File <- IO.try(File, File.open(out, "w"))
    IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, Nat & Nat, S.Rd.next(s), unu.merge.at(p, o))

# Pass 5: POOL's kept lines, in its order -------------------------------------------------------

type UnuWr is Type:
  UnuWr{r: S.Rd, k: S.Rd, next: Maybe<&2, Nat>, o: File, line: Nat, n: Nat, more: Bool}

def unu.next.of(x: S.Rd & Maybe<&2, List<&2, U32>>) -> S.Rd & Maybe<&2, Nat>:
  (k, m) = x
  match m:
    case Some{+l}:
      (k, Some{K.kor.nat(l)})
    case None{}:
      (k, None{})

def unu.next(k: S.Rd) -> IO(S.Rd & Maybe<&2, Nat>):
  do IO<S.Rd & Maybe<&2, Nat>>:
    x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(k)
    return unu.next.of(x)

def unu.wr.next(r: S.Rd, o: File, +i: Nat, +n: Nat, y: S.Rd & Maybe<&2, Nat>) -> IO(UnuWr):
  (k, nx) = y
  IO.pure(UnuWr, UnuWr{r, k, nx, o, 1n+i, 1n+n, True{}})

def unu.wr.hit(hit: Bool, r: S.Rd, k: S.Rd, nx: Maybe<&2, Nat>, o: File, +i: Nat, +n: Nat, +l: List<&2, U32>) -> IO(UnuWr):
  match hit:
    case False{}:
      IO.pure(UnuWr, UnuWr{r, k, nx, o, 1n+i, n, True{}})
    case True{}:
      do IO<UnuWr>:
        o2 : File <- S.emit(o, List.append(&2, U32, l, [10]))
        IO.bind(S.Rd & Maybe<&2, Nat>, UnuWr, unu.next(k), unu.wr.next(r, o2, i, n))

def unu.is.at(+m: Maybe<&2, Nat>, +i: Nat) -> Bool:
  match m:
    case Some{+j}:
      Nat.is_eq(j, i)
    case None{}:
      False{}

def unu.wr.got(k: S.Rd, +nx: Maybe<&2, Nat>, o: File, +i: Nat, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(UnuWr):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(UnuWr, UnuWr{r, k, nx, o, i, n, False{}})
    case Some{+l}:
      unu.wr.hit(unu.is.at(nx, i), r, k, nx, o, i, n, l)

def unu.wr.step(w: UnuWr) -> IO(UnuWr):
  match w:
    case UnuWr{r, k, nx, o, +i, +n, m}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, UnuWr, S.Rd.next(r), unu.wr.got(k, nx, o, i, n))

# while there is a kept number left
def unu.wr.go(fuel: Nat, w: UnuWr) -> IO(UnuWr):
  match fuel w:
    case 1n+f UnuWr{r, k, Some{+j}, o, i, n, True{}}:
      IO.bind(UnuWr, UnuWr, unu.wr.step(UnuWr{r, k, Some{j}, o, i, n, True{}}), unu.wr.go(f))
    case _ w2:
      IO.pure(UnuWr, w2)

def unu.wr.fin(w: UnuWr) -> IO(Nat):
  match w:
    case UnuWr{r, k, nx, o, i, n, m}:
      do IO<Nat>:
        S.Rd.close(r)
        S.Rd.close(k)
        File.close(o)
        return n

def unu.write.at(r: S.Rd, o: File, y: S.Rd & Maybe<&2, Nat>) -> IO(Nat):
  (k, nx) = y
  IO.bind(UnuWr, Nat, unu.wr.go(K.kor.fuel(), UnuWr{r, k, nx, o, 0n, 0n, True{}}), unu.wr.fin)

def unu.write(+pool: String, +kept: String, +out: String) -> IO(Nat):
  do IO<Nat>:
    r : S.Rd <- S.Rd.lines(pool)
    k : S.Rd <- S.Rd.lines(kept)
    o : File <- IO.try(File, File.open(out, "w"))
    IO.bind(S.Rd & Maybe<&2, Nat>, Nat, unu.next(k), unu.write.at(r, o))


# One pool against the sorted SEEN spool -----------------------------------------------------------
#
# POOL's spool (OUT.unu-pool, pass 1) sorted, merged with SEEN's sorted spool,
# the kept numbers sorted, POOL's kept lines written: the kept and the dropped.

def unu.finish.got(+pool: String, +out: String, r: Nat & Nat) -> IO(Nat & Nat):
  (+kept, +dropped) = r
  +ks = out ++ ".unu-kept"
  do IO<Nat & Nat>:
    unu.sort(False{}, K.kor.dir(out), ks, ks ++ ".sorted")
    S.rm(ks)
    +w : Nat <- unu.write(pool, ks ++ ".sorted", out)
    S.rm(ks ++ ".sorted")
    unu.need(Nat.is_eq(w, kept), "wrote " ++ Nat.show(w) ++ " lines of " ++ pool ++ ", but the merge kept " ++ Nat.show(kept))
    return (kept, dropped)

def unu.finish(+pool: String, +out: String, +seen: String) -> IO(Nat & Nat):
  +ps = out ++ ".unu-pool"
  do IO<Nat & Nat>:
    unu.sort(False{}, K.kor.dir(out), ps, ps ++ ".sorted")
    S.rm(ps)
    r : Nat & Nat <- unu.merge(ps ++ ".sorted", seen, out ++ ".unu-kept")
    S.rm(ps ++ ".sorted")
    unu.finish.got(pool, out, r)

# Several pools, one SEEN ----------------------------------------------------------------------------
#
#   bend-corpus-v2 unused POOL=OUT [POOL=OUT...] SEEN...   (the words with `=` are pairs)
#
# Each POOL's unused records into its OUT, as `unused POOL OUT SEEN...` would
# write them, with SEEN read once (2026-10-15: run 4 takes four pools against
# run 3's mix and filler; the mix alone took 56-68 min a read).  With PROCS (8)
# above 1 the work fans out to this program's own workers, PROCS at a time:
# every SEEN stream and every POOL spooled at once (`unused-spool`), then,
# SEEN's spools sorted together, every pool finished at once (`unused-finish`);
# PROCS 1 does it all in this process.  SEEN's spools sit next to the first
# OUT (OUT.unu-seen.K, OUT.unu-seen.sorted).
#
#   bend-corpus-v2 unused-spool pool|seen PATH SPOOL   one stream's ids into SPOOL; prints `RECORDS NONE`
#   bend-corpus-v2 unused-finish POOL OUT SEEN_SORTED  one pool finished; prints `KEPT DROPPED`

type UnuPair is Data:
  UnuPair{pool: String, out: String}

def unu.p.pool(+p: UnuPair) -> String:
  match p:
    case UnuPair{a, b}:
      a

def unu.p.out(+p: UnuPair) -> String:
  match p:
    case UnuPair{a, b}:
      b

# POOL=OUT: the text before the first `=`, and after it
def unu.pair.of(+w: String) -> UnuPair:
  +xs = S.b(w)
  +k = Maybe.default(&2, Nat, S.find(xs, [61], 0n), S.len(xs))
  UnuPair{S.str(List.take(&2, U32, xs, k)), S.str(List.drop(&2, U32, xs, 1n+k))}

def unu.pair.ok(+p: UnuPair) -> Bool:
  Bool.and(Bool.and(Bool.not(String.is_empty(unu.p.pool(p))), Bool.not(String.is_empty(unu.p.out(p)))), unu.is.jsonl(unu.p.pool(p)))

def unu.pairs.ok(ps: List<&2, UnuPair>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case +p <> t:
      Bool.and(unu.pair.ok(p), unu.pairs.ok(t))

# the leading words with `=` as POOL=OUT pairs, the rest SEEN (sep: there is a rest);
# no separator word: the Bend runtime takes a `--` out of a program's arguments
type UnuArgs is Data:
  UnuArgs{pairs: List<&2, UnuPair>, seen: List<&2, String>, sep: Bool}

def unu.args.put(+p: UnuPair, a: UnuArgs) -> UnuArgs:
  match a:
    case UnuArgs{ps, s, sep}:
      UnuArgs{p <> ps, s, sep}

def unu.args(xs: List<&2, String>) -> UnuArgs:
  match xs:
    case Nil{}:
      UnuArgs{Nil{}, Nil{}, False{}}
    case +x <> +t:
      Bool.pick(UnuArgs, S.infix(S.b(x), [61]), unu.args.put(unu.pair.of(x), unu.args(t)), UnuArgs{Nil{}, x <> t, True{}})

def unu.outs(ps: List<&2, UnuPair>) -> String:
  match ps:
    case Nil{}:
      ""
    case +p <> t:
      " " ++ unu.p.out(p) ++ unu.outs(t)

# The workers' answers -------------------------------------------------------------------------------

# the last line's two numbers (a worker's answer)
def unu.two(+o: S.Out) -> Nat & Nat:
  +ws = K.kor.words(Maybe.default(&2, List<&2, U32>, List.last(&2, List<&2, U32>, S.split.lines(S.Out.text(o))), Nil{}))
  (K.kor.nat(K.kor.field(ws, 0n)), K.kor.nat(K.kor.field(ws, 1n)))

def unu.job.ok(+r: Cb.CbRes) -> Bool:
  U32.is_eq(S.Out.status(Cb.cb.res.out(r)), 0)

def unu.jobs.ok(rs: List<&2, Cb.CbRes>) -> Bool:
  match rs:
    case Nil{}:
      True{}
    case +r <> t:
      Bool.and(unu.job.ok(r), unu.jobs.ok(t))

def unu.jobs.bad(rs: List<&2, Cb.CbRes>, +what: List<&2, String>) -> String:
  match rs:
    case Nil{}:
      ""
    case +r <> t:
      +w = Maybe.default(&2, String, List.get(&2, String, what, Cb.cb.res.i(r)), "?")
      Bool.pick(String, unu.job.ok(r), "", " [" ++ w ++ ": exit " ++ U32.show(S.Out.status(Cb.cb.res.out(r))) ++ "]") ++ unu.jobs.bad(t, what)

def unu.jobs.need(+rs: List<&2, Cb.CbRes>, +what: List<&2, String>) -> IO(Unit):
  unu.need(unu.jobs.ok(rs), "a worker failed (run it alone to see why):" ++ unu.jobs.bad(rs, what))

# The spools ----------------------------------------------------------------------------------------

# SEEN stream i's spool, next to the first OUT
def unu.seen.spool(+out: String, +i: Nat) -> String:
  out ++ ".unu-seen." ++ Nat.show(i)

def unu.seen.spools(ss: List<&2, String>, +out: String, +i: Nat) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case s <> t:
      unu.seen.spool(out, i) <> unu.seen.spools(t, out, 1n+i)

def unu.say.seen(ss: List<&2, String>, ns: List<&2, UnuN>) -> IO(Unit):
  match ss ns:
    case +s <> st +n <> nt:
      do IO<Unit>:
        unu.log("seen: " ++ Nat.show(unu.n.n(n)) ++ " records in " ++ s)
        unu.say.seen(st, nt)
    case _ _:
      IO.pure(Unit, Unit{})

def unu.say.pool(ps: List<&2, UnuPair>, ns: List<&2, UnuN>) -> IO(Unit):
  match ps ns:
    case +p <> pt +n <> nt:
      do IO<Unit>:
        unu.log("pool: " ++ Nat.show(unu.n.n(n)) ++ " records in " ++ unu.p.pool(p) ++ "; lines without one: " ++ Nat.show(unu.n.skip(n)))
        unu.say.pool(pt, nt)
    case _ _:
      IO.pure(Unit, Unit{})

def unu.n.sum(ns: List<&2, UnuN>) -> UnuN:
  match ns:
    case Nil{}:
      UnuN{0n, 0n}
    case +n <> t:
      unu.n.add(n, unu.n.sum(t))

# in this process: each SEEN stream into its spool, then each pool into its own
def unu.spool.seen.here(ss: List<&2, String>, +out: String, +i: Nat) -> IO(List<&2, UnuN>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, UnuN>, Nil{})
    case +s <> t:
      do IO<List<&2, UnuN>>:
        S.rm(unu.seen.spool(out, i))
        +c : UnuN <- unu.spool(False{}, s, unu.seen.spool(out, i))
        rest : List<&2, UnuN> <- unu.spool.seen.here(t, out, 1n+i)
        return c <> rest

def unu.spool.pools.here(ps: List<&2, UnuPair>) -> IO(List<&2, UnuN>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, UnuN>, Nil{})
    case +p <> t:
      do IO<List<&2, UnuN>>:
        +c : UnuN <- unu.spool(True{}, unu.p.pool(p), unu.p.out(p) ++ ".unu-pool")
        rest : List<&2, UnuN> <- unu.spool.pools.here(t)
        return c <> rest

# the workers' jobs: `unused-spool seen S SPOOL` a SEEN stream, `unused-spool pool P
# OUT.unu-pool` a pool, `unused-finish P OUT SEEN_SORTED` a pool's end
def unu.jobs.seen(ss: List<&2, String>, +self: String, +out: String, +i: Nat) -> List<&2, Cb.CbJob>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      Cb.CbJob{i, Nil{}, self, ["unused-spool", "seen", s, unu.seen.spool(out, i)]} <> unu.jobs.seen(t, self, out, 1n+i)

def unu.jobs.pool(ps: List<&2, UnuPair>, +self: String, +i: Nat) -> List<&2, Cb.CbJob>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      Cb.CbJob{i, Nil{}, self, ["unused-spool", "pool", unu.p.pool(p), unu.p.out(p) ++ ".unu-pool"]} <> unu.jobs.pool(t, self, 1n+i)

def unu.jobs.finish(ps: List<&2, UnuPair>, +self: String, +seen: String, +i: Nat) -> List<&2, Cb.CbJob>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      Cb.CbJob{i, Nil{}, self, ["unused-finish", unu.p.pool(p), unu.p.out(p), seen]} <> unu.jobs.finish(t, self, seen, 1n+i)

def unu.what.seen(ss: List<&2, String>) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      ("unused-spool seen " ++ s) <> unu.what.seen(t)

def unu.what.pool(ps: List<&2, UnuPair>, +verb: String) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      (verb ++ " " ++ unu.p.pool(p)) <> unu.what.pool(t, verb)

def unu.res.put(x: Nat & Nat, rest: List<&2, UnuN>) -> List<&2, UnuN>:
  (a, b) = x
  UnuN{a, b} <> rest

# each worker's answer as counts, in the jobs' order
def unu.res.n(rs: List<&2, Cb.CbRes>) -> List<&2, UnuN>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      unu.res.put(unu.two(Cb.cb.res.out(r)), unu.res.n(t))

# the first n, and the rest
def unu.take.n(+xs: List<&2, UnuN>, +n: Nat) -> List<&2, UnuN>:
  List.take(&2, UnuN, xs, n)

def unu.drop.n(+xs: List<&2, UnuN>, +n: Nat) -> List<&2, UnuN>:
  List.drop(&2, UnuN, xs, n)

# Main ---------------------------------------------------------------------------------------------

# every SEEN spool sorted together, duplicates out (`LC_ALL=C sort -u ... -o SORTED SPOOL...`)
def unu.sort.seen(+dir: String, +spools: List<&2, String>, +sorted: String) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 2000000, "sort", K.kor.l1(List.append(&2, String, ["-u", "-S", "1G", "-T", dir, "-o", sorted], spools)), Nil{})
    unu.sort.ok(o)

def unu.rm.all(ps: List<&2, String>) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> t:
      do IO<Unit>:
        S.rm(p)
        unu.rm.all(t)

def unu.say.done(ps: List<&2, UnuPair>, ns: List<&2, UnuN>, ks: List<&2, UnuN>, +sn: Nat) -> IO(Unit):
  match ps ns ks:
    case +p <> pt +n <> nt +k <> kt:
      do IO<Unit>:
        unu.log("pool " ++ Nat.show(unu.n.n(n)) ++ ", seen " ++ Nat.show(sn) ++ ", kept " ++ Nat.show(unu.n.n(k)) ++ ", dropped " ++ Nat.show(unu.n.skip(k)) ++ " -> " ++ unu.p.out(p))
        unu.say.done(pt, nt, kt, sn)
    case _ _ _:
      IO.pure(Unit, Unit{})

# PROCS 1: each pool finished in this process
def unu.finish.here(ps: List<&2, UnuPair>, +seen: String) -> IO(List<&2, UnuN>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, UnuN>, Nil{})
    case +p <> t:
      do IO<List<&2, UnuN>>:
        r : Nat & Nat <- unu.finish(unu.p.pool(p), unu.p.out(p), seen)
        rest : List<&2, UnuN> <- unu.finish.here(t, seen)
        return unu.res.put(r, rest)

def unu.phase1.here(+ps: List<&2, UnuPair>, +seen: List<&2, String>, +out1: String) -> IO(List<&2, UnuN>):
  do IO<List<&2, UnuN>>:
    a : List<&2, UnuN> <- unu.spool.seen.here(seen, out1, 0n)
    b : List<&2, UnuN> <- unu.spool.pools.here(ps)
    return List.append(&2, UnuN, a, b)

# the jobs run by this program's workers, PROCS at a time; their answers, in the jobs' order
def unu.work(+procs: Nat, +js: List<&2, Cb.CbJob>, +what: List<&2, String>) -> IO(List<&2, UnuN>):
  do IO<List<&2, UnuN>>:
    +rs : List<&2, Cb.CbRes> <- Cb.cb.runs(procs, js)
    unu.jobs.need(rs, what)
    return unu.res.n(rs)

# phase 1: the spools (counts: SEEN's streams', then the pools')
def unu.phase1(+procs: Nat, +self: String, +ps: List<&2, UnuPair>, +seen: List<&2, String>, +out1: String) -> IO(List<&2, UnuN>):
  +js = List.append(&2, Cb.CbJob, unu.jobs.seen(seen, self, out1, 0n), unu.jobs.pool(ps, self, List.length(&2, String, seen)))
  +what = List.append(&2, String, unu.what.seen(seen), unu.what.pool(ps, "unused-spool pool"))
  Bool.pick(IO(List<&2, UnuN>), Nat.is_le(procs, 1n), unu.phase1.here(ps, seen, out1), unu.work(procs, js, what))

# phase 2: each pool against SEEN's sorted spool (kept, dropped)
def unu.phase2(+procs: Nat, +self: String, +ps: List<&2, UnuPair>, +sorted: String) -> IO(List<&2, UnuN>):
  Bool.pick(IO(List<&2, UnuN>), Nat.is_le(procs, 1n), unu.finish.here(ps, sorted), unu.work(procs, unu.jobs.finish(ps, self, sorted, 0n), unu.what.pool(ps, "unused-finish")))

def unu.out1(ps: List<&2, UnuPair>) -> String:
  match ps:
    case Nil{}:
      "unused"
    case +p <> t:
      unu.p.out(p)

def unu.run(+procs: Nat, +self: String, +ps: List<&2, UnuPair>, +seen: List<&2, String>) -> IO(Unit):
  +out1 = unu.out1(ps)
  +m = List.length(&2, String, seen)
  +spools = unu.seen.spools(seen, out1, 0n)
  +sorted = out1 ++ ".unu-seen.sorted"
  do IO<Unit>:
    unu.need(unu.pairs.ok(ps), "every POOL is a .jsonl file with an OUT (POOL=OUT)")
    unu.log(Nat.show(List.length(&2, UnuPair, ps)) ++ " pool(s) against " ++ Nat.show(m) ++ " SEEN stream(s), PROCS " ++ Nat.show(procs) ++ "; into" ++ unu.outs(ps))
    +ns : List<&2, UnuN> <- unu.phase1(procs, self, ps, seen, out1)
    unu.say.seen(seen, unu.take.n(ns, m))
    unu.say.pool(ps, unu.drop.n(ns, m))
    unu.sort.seen(K.kor.dir(out1), spools, sorted)
    unu.rm.all(spools)
    +distinct : Nat <- K.kor.count(sorted, 10)
    +sn : Nat = unu.n.n(unu.n.sum(unu.take.n(ns, m)))
    unu.log("seen: " ++ Nat.show(sn) ++ " records, " ++ Nat.show(distinct) ++ " distinct ids")
    +ks : List<&2, UnuN> <- unu.phase2(procs, self, ps, sorted)
    S.rm(sorted)
    unu.say.done(ps, unu.drop.n(ns, m), ks, sn)

def unu.go(+ps: List<&2, UnuPair>, +seen: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +procs : Nat <- S.env.nat("PROCS", 8n)
    +self : String <- K.kor.self()
    unu.run(procs, self, ps, seen)

def unu.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 unused POOL OUT SEEN... | unused POOL=OUT [POOL=OUT...] SEEN...   (POOL .jsonl; SEEN .jsonl lines or NUL pairs, no `=` in its path; PROCS)")

def unu.go.args(a: UnuArgs) -> IO(Unit):
  match a:
    case UnuArgs{+ps, +ss, True{}}:
      Bool.pick(IO(Unit), Bool.or(List.is_empty(&2, UnuPair, ps), List.is_empty(&2, String, ss)), unu.usage(), unu.go(ps, ss))
    case UnuArgs{ps, ss, False{}}:
      unu.usage()

def unu.main.one(ys: List<&2, String>) -> IO(Unit):
  match ys:
    case +pool <> +out <> +s <> more:
      unu.go([UnuPair{pool, out}], s <> more)
    case _:
      unu.usage()

# `unused POOL OUT SEEN...`, or (a first word with `=`) `unused POOL=OUT... SEEN...`
def unu.main(xs: List<String>) -> IO(Unit):
  +ys = K.kor.l2(xs)
  +first = Maybe.default(&2, String, List.head(&2, String, ys), "")
  Bool.pick(IO(Unit), S.infix(S.b(first), [61]), unu.go.args(unu.args(ys)), unu.main.one(ys))

# the workers
def unu.spool.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +mode <> +path <> +spool <> Nil{}:
      do IO<Unit>:
        +c : UnuN <- unu.spool(String.eq(mode, "pool"), path, spool)
        IO.print(Nat.show(unu.n.n(c)) ++ " " ++ Nat.show(unu.n.skip(c)))
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 unused-spool pool|seen PATH SPOOL")

def unu.finish.say(r: Nat & Nat) -> IO(Unit):
  (+k, +d) = r
  IO.print(Nat.show(k) ++ " " ++ Nat.show(d))

def unu.finish.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +pool <> +out <> +seen <> Nil{}:
      do IO<Unit>:
        r : Nat & Nat <- unu.finish(pool, out, seen)
        unu.finish.say(r)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 unused-finish POOL OUT SEEN_SORTED")
