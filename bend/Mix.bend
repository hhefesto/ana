import Base
import ./Sys.bend as S
import ./Json.bend as J

# bend-mix: interleave N JSONL sources in fixed proportions.
#
#   bend-mix OUT.jsonl SOURCE.jsonl:PER_ROUND[:REPEATS|:cycle] ...
#
# PER_ROUND sets the ratio: with `a.jsonl:7 b.jsonl:3` each round emits 7
# documents of a then 3 of b.  The mix ends when every non-cycling source has
# run dry; a source that runs dry leaves the rounds, so the tail of the output
# is what is left, and the summary says when (RAN DRY) any non-cycling source
# ran out before 98% of the output: a curriculum that ends on an
# unrepresentative diet is invisible in the output itself.  A small source
# holds its share of a long corpus in one of two ways:
#
#   :REPEATS   read it REPEATS times over.  Use when the total share should be
#              capped (the user's-code 30x case).
#   :cycle     restart it every time it drains, until every non-cycling source
#              is exhausted.  Use when the source must hold its ratio to the
#              very end of the mix.  At least one source must NOT cycle, or the
#              mix would never end.
#
# Either way every copy gets a distinct id suffix (#r<n> / #c<n>, n the pass
# from 0), because a corpus with a duplicate id is refused thousands of steps
# into a paid run, and for the same reason the output's ids are checked for
# uniqueness across sources before the file is renamed into place
# (CHECK_IDS=0 skips it).  A repeated or cycled line is written as
# `jq -c '.id = .id + "#r" + $r'` writes it, so such a source must hold
# `{"id": ..., "text": ...}` lines (id first, as bend-extract writes them;
# blank lines are skipped as jq skips them); every other source is copied
# line for line, byte for byte.
#
# One trap this cannot solve for you: ratios apply to DOCUMENTS, and the
# trainer's unit is the WINDOW.  Sources with different document lengths give
# a window mix quite unlike the document mix, so the summary reports byte
# share as well -- a far better proxy for windows -- and the plan's
# train_windows is the only real confirmation.
#
# And one it refuses to hide: anything repeated or cycled lands on both sides
# of the trainer's position-hashed train/validation split, so it must be
# excluded from held-out eval populations (the repeated ids make that
# mechanically checkable: grep for '#r' / '#c').
#
# Everything streams: a source is read a line at a time (a repeated or cycled
# one is reopened for its next pass), the output and the ids are written as
# they go, and the duplicate check is `LC_ALL=C sort | uniq -d` over the ids.

# Bytes -------------------------------------------------------------------------

# the bytes before the first c (all of them when there is none)
def upto(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), Nil{}, h <> upto(t, c))

# the bytes after the first c (all of them when there is none: ${x#*:})
def past.go(+xs: List<&2, U32>, ys: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match ys:
    case Nil{}:
      xs
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), t, past.go(xs, t, c))

def past(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  past.go(xs, xs, c)

def digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      Bool.and(Bool.and(U32.is_le(48, h), U32.is_le(h, 57)), digits(t))

# a non-empty run of digits
def count(+xs: List<&2, U32>) -> Bool:
  Bool.and(Nat.is_lt(0n, S.len(xs)), digits(xs))

def nat.of(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

# whitespace only (ok: so far), stopping at the first other byte
def blank.go(xs: List<&2, U32>, ok: Bool) -> Bool:
  match xs ok:
    case _ False{}:
      False{}
    case Nil{} True{}:
      True{}
    case +h <> t True{}:
      blank.go(t, J.ws(h))

def blank(xs: List<&2, U32>) -> Bool:
  blank.go(xs, True{})

# Numbers as awk prints them -------------------------------------------------------

def spaces(n: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+k:
      " " ++ spaces(k)

# printf's %-Ns and %Ns (widths in bytes: LC_ALL=C)
def pad.r(+s: String, +w: Nat) -> String:
  s ++ spaces(Nat.sub(w, S.len(S.b(s))))

def pad.l(+s: String, +w: Nat) -> String:
  spaces(Nat.sub(w, S.len(S.b(s)))) ++ s

# floor(log2(m / 20)) for m >= 20: e with 20 * 2^e <= m < 40 * 2^e (p is
# 20 * 2^e; stop: m < 2p)
def exp.hi(fuel: Nat, +m: Nat, +e: Nat, +p: Nat, stop: Bool) -> Nat:
  match fuel stop:
    case _ True{}:
      e
    case 0n False{}:
      e
    case 1n+f False{}:
      exp.hi(f, m, 1n+e, Nat.mul(2n, p), Nat.is_lt(m, Nat.mul(4n, p)))

# -floor(log2(m / 20)) for 0 < m < 20: d with 20 <= m * 2^d < 40 (x is
# m * 2^d; stop: 20 <= x)
def exp.lo(fuel: Nat, +x: Nat, +d: Nat, stop: Bool) -> Nat:
  match fuel stop:
    case _ True{}:
      d
    case 0n False{}:
      d
    case 1n+f False{}:
      exp.lo(f, Nat.mul(2n, x), 1n+d, Nat.is_le(20n, Nat.mul(2n, x)))

# 2^s mod 5 by s mod 4
def pow2.mod5(k: Nat) -> Nat:
  match k:
    case 0n:
      1n
    case 1n:
      2n
    case 2n:
      4n
    case _:
      3n

# Is the double nearest m/20 (m odd, 5 not dividing m) above m/20?  The
# double is round(m * 2^s / 20) / 2^s, with s = 52 - floor(log2(m/20)); no
# tie is possible, and m * 2^s mod 20 is 0 mod 4 (s >= 2) and a = m * 2^s
# mod 5, so it is 16, 12, 8, 4 for a = 1, 2, 3, 4: above the half for 1, 2.
def above(+m: Nat) -> Bool:
  +s4 = Bool.pick(Nat, Nat.is_le(20n, m), Nat.mod(Nat.sub(4n, Nat.mod(exp.hi(64n, m, 0n, 20n, Nat.is_lt(m, 40n)), 4n)), 4n), Nat.mod(exp.lo(64n, m, 0n, Nat.is_le(20n, m)), 4n))
  +a = Nat.mod(Nat.mul(Nat.mod(m, 5n), pow2.mod5(s4)), 5n)
  Bool.or(Nat.is_eq(a, 1n), Nat.is_eq(a, 2n))

# 10 * 100a/b = q + 1/2 exactly: 100a/b is m/20, m = 2q + 1.  When 5 divides
# m the double is m/20 itself and C rounds the tie to even; otherwise the
# double lies on one side of it.
def tie(+q: Nat) -> Nat:
  +m = {1n+Nat.mul(2n, q) : Nat}
  Bool.pick(Nat, Nat.is_eq(Nat.mod(m, 5n), 0n), Nat.add(q, Nat.mod(q, 2n)), Bool.pick(Nat, above(m), 1n+q, q))

# awk's printf "%.1f" of 100 * a / b (0 for b = 0), in tenths: C prints the
# exact double quotient rounded to nearest; a quotient off a tenths midpoint
# is at least 1/(20b) from it, far more than the double's error, so only an
# exact midpoint needs the double itself (tie)
def tenths(+a: Nat, +b: Nat) -> Nat:
  +n = Nat.mul(1000n, a)
  +q = Nat.div(n, Nat.max(b, 1n))
  +r2 = Nat.mul(2n, Nat.mod(n, Nat.max(b, 1n)))
  Bool.pick(Nat, Nat.is_eq(b, 0n), 0n, Bool.pick(Nat, Nat.is_lt(r2, b), q, Bool.pick(Nat, Nat.is_lt(b, r2), 1n+q, tie(q))))

def pct(+a: Nat, +b: Nat) -> String:
  +t = tenths(a, b)
  Nat.show(Nat.div(t, 10n)) ++ "." ++ Nat.show(Nat.mod(t, 10n))

# The sources ---------------------------------------------------------------------

# A source's description and counters: kind 0 plain, 1 read reps times, 2
# cycling; the pass being read and the lines it gave; whether it is still in
# the rounds; documents and bytes (line and newline) emitted; the output's
# document count when it ran dry.
type Sd is Data:
  Sd{path: String, label: String, per: Nat, kind: Nat, reps: Nat, pass: Nat, got: Nat, live: Bool, emitted: Nat, bytes: Nat, dry: Maybe<&2, Nat>}

type Src is Type:
  Src{rd: Maybe<&1, S.Rd>, d: Sd}

def Sd.path(+d: Sd) -> String:
  match d:
    case Sd{p, l, e, k, r, a, g, v, m, b, y}:
      p

def Sd.kind(+d: Sd) -> Nat:
  match d:
    case Sd{p, l, e, k, r, a, g, v, m, b, y}:
      k

def Sd.live(+d: Sd) -> Bool:
  match d:
    case Sd{p, l, e, k, r, a, g, v, m, b, y}:
      v

def Sd.per(+d: Sd) -> Nat:
  match d:
    case Sd{p, l, e, k, r, a, g, v, m, b, y}:
      e

# the next pass: its number, no lines yet
def Sd.next(d: Sd) -> Sd:
  match d:
    case Sd{p, l, e, k, r, +a, g, v, m, b, y}:
      Sd{p, l, e, k, r, 1n+a, 0n, v, m, b, y}

def Sd.took(d: Sd) -> Sd:
  match d:
    case Sd{p, l, e, k, r, a, g, v, m, b, y}:
      Sd{p, l, e, k, r, a, 1n+g, v, m, b, y}

# reopen when a pass ends: a cycling source that gave lines, a repeated one
# with passes left
def Sd.again(+d: Sd) -> Bool:
  match d:
    case Sd{p, l, e, k, +r, +a, +g, v, m, b, y}:
      Bool.or(Bool.and(Nat.is_eq(k, 2n), Nat.is_lt(0n, g)), Bool.and(Nat.is_eq(k, 1n), Nat.is_lt(1n+a, r)))

def Sd.emit(+n: Nat, d: Sd) -> Sd:
  match d:
    case Sd{p, l, e, k, r, a, g, v, +m, +b, y}:
      Sd{p, l, e, k, r, a, g, v, 1n+m, Nat.add(b, n), y}

def Sd.dried(+total: Nat, d: Sd) -> Sd:
  match d:
    case Sd{p, l, e, k, r, a, g, v, m, b, y}:
      Sd{p, l, e, k, r, a, g, False{}, m, b, Some{total}}

# the suffix of a repeated or cycled copy's ids
def Sd.suffix(+d: Sd) -> String:
  match d:
    case Sd{p, l, e, k, r, +a, g, v, m, b, y}:
      Bool.pick(String, Nat.is_eq(k, 2n), "#c", "#r") ++ Nat.show(a)

# The next line of a source: a pass that ends reopens the file when the source
# goes on (Sd.again), and a repeated or cycled source skips blank lines.
type Nx is Type:
  Nx{rd: Maybe<&1, S.Rd>, d: Sd, got: Maybe<&2, List<&2, U32>>, go: Bool}

def nx.end(again: Bool, d: Sd) -> IO(Nx):
  match again:
    case True{}:
      +d2 = Sd.next(d)
      do IO<Nx>:
        r : S.Rd <- S.Rd.lines(Sd.path(d2))
        return Nx{Some{r}, d2, None{}, True{}}
    case False{}:
      IO.pure(Nx, Nx{None{}, d, None{}, False{}})

def nx.line(skip: Bool, r: S.Rd, d: Sd, +l: List<&2, U32>) -> IO(Nx):
  match skip:
    case True{}:
      IO.pure(Nx, Nx{Some{r}, d, None{}, True{}})
    case False{}:
      IO.pure(Nx, Nx{Some{r}, Sd.took(d), Some{l}, False{}})

def nx.got(+d: Sd, r: S.Rd, m: Maybe<&2, List<&2, U32>>) -> IO(Nx):
  match m:
    case Some{+l}:
      nx.line(Bool.and(Nat.is_lt(0n, Sd.kind(d)), blank(l)), r, d, l)
    case None{}:
      do IO<Nx>:
        S.Rd.close(r)
        nx.end(Sd.again(d), d)

def nx.pair(+d: Sd, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Nx):
  (rd, m) = r
  nx.got(d, rd, m)

def nx.read(rd: Maybe<&1, S.Rd>, +d: Sd) -> IO(Nx):
  match rd:
    case None{}:
      IO.pure(Nx, Nx{None{}, d, None{}, False{}})
    case Some{r}:
      do IO<Nx>:
        x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(r)
        nx.pair(d, x)

def nx.step(x: Nx) -> IO(Nx):
  match x:
    case Nx{rd, +d, g, go}:
      nx.read(rd, d)

def nx.go(fuel: Nat, x: Nx) -> IO(Nx):
  match fuel x:
    case 1n+p Nx{rd, d, g, True{}}:
      IO.bind(Nx, Nx, nx.step(Nx{rd, d, g, True{}}), nx.go(p))
    case _ Nx{rd, d, g, go}:
      IO.pure(Nx, Nx{rd, d, g, go})

def big() -> Nat:
  1000000000n

# The output ------------------------------------------------------------------------

# the output and the ids file, whether ids are kept, documents out, the
# non-cycling sources still live, and the cycling source that ran dry
type Mo is Type:
  Mo{o: File, ids: File, check: Bool, total: Nat, alive: Nat, failed: Maybe<&2, String>}

def id.any(m: Maybe<&2, List<&2, J.Kv>>) -> List<&2, U32>:
  match m:
    case Some{kvs}:
      S.append(Maybe.default(&2, List<&2, U32>, J.get(kvs, S.b("id")), S.b("null")), [10])
    case None{}:
      S.b("null\n")

# the first field is the id (as bend-extract writes it), else the whole
# object is read for it
def id.key(first: Bool, +v: List<&2, U32>, +l: List<&2, U32>) -> List<&2, U32>:
  match first:
    case True{}:
      S.append(v, [10])
    case False{}:
      id.any(J.object(l))

def id.first(skip: Bool, p: J.Pr, +l: List<&2, U32>) -> List<&2, U32>:
  match skip p:
    case True{} _:
      Nil{}
    case False{} J.Pok{+k, +v, r}:
      id.key(S.eq(k, S.b("id")), v, l)
    case False{} J.Pbad{}:
      id.any(J.object(l))

# a plain line's id, as `jq -r .id` prints it (none for a blank line)
def id.plain(+l: List<&2, U32>) -> List<&2, U32>:
  id.first(blank(l), J.first.at(l), l)

def id.if(check: Bool, +l: List<&2, U32>) -> List<&2, U32>:
  match check:
    case True{}:
      id.plain(l)
    case False{}:
      Nil{}

# A line out: the bytes written, the id line (with its newline) for the check,
# or a line that is no {id, text} document
type Ln is Data:
  Out{bytes: List<&2, U32>, id: List<&2, U32>}
  Bad{}

def ln.copy(m: Maybe<&2, J.Doc>, +sfx: String) -> Ln:
  match m:
    case Some{J.Doc{id, t}}:
      +nid = S.append(id, S.b(sfx))
      Out{S.append(J.line(nid, t), [10]), S.append(nid, [10])}
    case None{}:
      Bad{}

def ln.by(plain: Bool, +check: Bool, +d: Sd, +l: List<&2, U32>) -> Ln:
  match plain:
    case True{}:
      Out{S.append(l, [10]), id.if(check, l)}
    case False{}:
      ln.copy(J.doc(l), Sd.suffix(d))

def ln.of(+check: Bool, +d: Sd, +l: List<&2, U32>) -> Ln:
  ln.by(Nat.is_eq(Sd.kind(d), 0n), check, d, l)

def put.line(ln: Ln, +d: Sd, mo: Mo) -> IO(Mo & Sd):
  match ln mo:
    case Out{+b, i} Mo{o, ids, c, +t, a, f}:
      do IO<Mo & Sd>:
        o2 : File <- S.emit(o, b)
        i2 : File <- S.emit(ids, i)
        return (Mo{o2, i2, c, 1n+t, a, f}, Sd.emit(S.len(b), d))
    case Bad{} Mo{o, ids, c, +t, a, f}:
      IO.pure(Mo & Sd, (Mo{o, ids, c, t, a, Some{"mix-corpus: " ++ Sd.path(d) ++ ": a line that is not an {\"id\", \"text\"} object"}}, Sd.dried(t, d)))

def Sd.label(+d: Sd) -> String:
  match d:
    case Sd{p, l, e, k, r, a, g, v, m, b, y}:
      l

# a source runs dry: out of the rounds; a cycling one means its feeder died
def none(f: Maybe<&2, String>) -> Bool:
  match f:
    case None{}:
      True{}
    case Some{w}:
      False{}

def put.dry(cyc: Bool, +d: Sd, mo: Mo) -> Mo:
  match cyc mo:
    case True{} Mo{o, ids, c, t, a, f}:
      Mo{o, ids, c, t, a, Some{"mix-corpus: cycling source " ++ Sd.label(d) ++ " ran dry -- its feeder died"}}
    case False{} Mo{o, ids, c, t, +a, f}:
      Mo{o, ids, c, t, Nat.sub(a, 1n), f}

def tn.mk(rd: Maybe<&1, S.Rd>, +left: Nat, d: Sd, mo: Mo) -> Tn:
  match mo:
    case Mo{o, ids, c, t, a, +f}:
      Tn{rd, d, Mo{o, ids, c, t, a, f}, left, Bool.and(Nat.is_lt(0n, left), none(f))}

# A turn: up to PER_ROUND documents of one source --------------------------------

type Tn is Type:
  Tn{rd: Maybe<&1, S.Rd>, d: Sd, mo: Mo, left: Nat, go: Bool}

def tn.put(rd: Maybe<&1, S.Rd>, +left: Nat, r: Mo & Sd) -> Tn:
  (mo, d) = r
  tn.mk(rd, left, d, mo)

def tn.got(rd: Maybe<&1, S.Rd>, +d: Sd, +left: Nat, m: Maybe<&2, List<&2, U32>>, mo: Mo) -> IO(Tn):
  match m mo:
    case Some{+l} Mo{o, ids, +c, t, a, f}:
      do IO<Tn>:
        r : Mo & Sd <- put.line(ln.of(c, d, l), d, Mo{o, ids, c, t, a, f})
        return tn.put(rd, Nat.sub(left, 1n), r)
    case None{} Mo{o, ids, c, +t, a, f}:
      IO.pure(Tn, Tn{rd, Sd.dried(t, d), put.dry(Nat.is_eq(Sd.kind(d), 2n), d, Mo{o, ids, c, t, a, f}), 0n, False{}})

def tn.next(mo: Mo, +left: Nat, x: Nx) -> IO(Tn):
  match x:
    case Nx{rd, +d, g, go}:
      tn.got(rd, d, left, g, mo)

def tn.step(t: Tn) -> IO(Tn):
  match t:
    case Tn{rd, d, mo, +left, go}:
      do IO<Tn>:
        x : Nx <- nx.go(big(), Nx{rd, d, None{}, True{}})
        tn.next(mo, left, x)

def tn.go(fuel: Nat, t: Tn) -> IO(Tn):
  match fuel t:
    case 1n+p Tn{rd, d, mo, left, True{}}:
      IO.bind(Tn, Tn, tn.step(Tn{rd, d, mo, left, True{}}), tn.go(p))
    case _ Tn{rd, d, mo, left, go}:
      IO.pure(Tn, Tn{rd, d, mo, left, go})

type Tr is Type:
  Tr{src: Src, mo: Mo}

def tn.fin(t: Tn) -> Tr:
  match t:
    case Tn{rd, d, mo, left, go}:
      Tr{Src{rd, d}, mo}

def turn.go(run: Bool, rd: Maybe<&1, S.Rd>, +d: Sd, mo: Mo) -> IO(Tr):
  match run:
    case True{}:
      do IO<Tr>:
        t : Tn <- tn.go(1n+Sd.per(d), Tn{rd, d, mo, Sd.per(d), True{}})
        return tn.fin(t)
    case False{}:
      IO.pure(Tr, Tr{Src{rd, d}, mo})

# a live source's turn; a dry one (or any, once a cycling source has died)
# is passed over
def turn(s: Src, mo: Mo) -> IO(Tr):
  match s mo:
    case Src{rd, +d} Mo{o, ids, c, t, a, +f}:
      turn.go(Bool.and(Sd.live(d), none(f)), rd, d, Mo{o, ids, c, t, a, f})

# A round: every source's turn, in order ---------------------------------------

def rev(xs: List<Src>, acc: List<Src>) -> List<Src>:
  match xs:
    case Nil{}:
      acc
    case x <> more:
      rev(more, x <> acc)

type Rr is Type:
  Rr{srcs: List<Src>, mo: Mo}

def round.go(more: List<Src>, done: List<Src>, r: Tr) -> IO(Rr):
  match more r:
    case Nil{} Tr{s, mo}:
      IO.pure(Rr, Rr{rev(s <> done, Nil{}), mo})
    case s2 <> rest Tr{s, mo}:
      IO.bind(Tr, Rr, turn(s2, mo), round.go(rest, s <> done))

def round(srcs: List<Src>, mo: Mo) -> IO(Rr):
  match srcs:
    case Nil{}:
      IO.pure(Rr, Rr{Nil{}, mo})
    case s <> rest:
      IO.bind(Tr, Rr, turn(s, mo), round.go(rest, Nil{}))

type Ms is Type:
  Ms{srcs: List<Src>, mo: Mo, go: Bool}

def ms.of(r: Rr) -> Ms:
  match r:
    case Rr{srcs, Mo{o, ids, c, t, +a, +f}}:
      Ms{srcs, Mo{o, ids, c, t, a, f}, Bool.and(Nat.is_lt(0n, a), none(f))}

def ms.step(m: Ms) -> IO(Ms):
  match m:
    case Ms{srcs, mo, g}:
      do IO<Ms>:
        r : Rr <- round(srcs, mo)
        return ms.of(r)

def mix.go(fuel: Nat, m: Ms) -> IO(Ms):
  match fuel m:
    case 1n+p Ms{srcs, mo, True{}}:
      IO.bind(Ms, Ms, ms.step(Ms{srcs, mo, True{}}), mix.go(p))
    case _ Ms{srcs, mo, g}:
      IO.pure(Ms, Ms{srcs, mo, g})

# The end: summary, duplicate check, rename -------------------------------------

# every reader closed, the descriptions kept
def close.all(ss: List<Src>, acc: List<&2, Sd>) -> IO(List<&2, Sd>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, Sd>, List.reverse(&2, Sd, acc))
    case Src{None{}, d} <> more:
      close.all(more, d <> acc)
    case Src{Some{r}, d} <> more:
      do IO<List<&2, Sd>>:
        S.Rd.close(r)
        close.all(more, d <> acc)

def bytes.all(ds: List<&2, Sd>) -> Nat:
  match ds:
    case Nil{}:
      0n
    case Sd{p, l, e, k, r, a, g, v, m, +b, y} <> more:
      Nat.add(b, bytes.all(more))

def dry.said(+k: Nat, y: Maybe<&2, Nat>, +total: Nat) -> String:
  match y:
    case Some{+x}:
      Bool.pick(String, Bool.and(Bool.not(Nat.is_eq(k, 2n)), Nat.is_lt(Nat.mul(50n, x), Nat.mul(49n, total))),
        "  -- RAN DRY at " ++ pct(x, total) ++ "% of the output", "")
    case None{}:
      ""

def summary(ds: List<&2, Sd>, +total: Nat, +all: Nat) -> IO(Unit):
  match ds:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Sd{p, +l, e, +k, r, a, g, v, +m, +b, y} <> more:
      do IO<Unit>:
        IO.print_err("  " ++ pad.r(l, 40n) ++ " " ++ pad.l(Nat.show(m), 9n) ++ " docs (" ++ pad.l(pct(m, total), 5n) ++ "%)  "
          ++ pad.l(pct(b, all), 6n) ++ "% of bytes" ++ dry.said(k, y, total))
        summary(more, total, all)

# the first three duplicates, indented (sed 's/^/  /;3q')
def dups.said(ls: List<&2, List<&2, U32>>, n: Nat) -> String:
  match ls n:
    case Nil{} _:
      ""
    case _ 0n:
      ""
    case l <> more 1n+k:
      "\n  " ++ S.str(l) ++ dups.said(more, k)

def dups.if(some: Bool, +dups: List<&2, U32>, +work: String) -> IO(Unit):
  match some:
    case True{}:
      do IO<Unit>:
        S.rm(work)
        IO.die(Unit, 1, "mix-corpus: duplicate ids across sources, refusing:" ++ dups.said(S.split.lines(dups), 3n))
    case False{}:
      IO.pure(Unit, Unit{})

def check.ids(check: Bool, +work: String) -> IO(Unit):
  match check:
    case True{}:
      do IO<Unit>:
        o : S.Out <- S.run(".", ["LC_ALL=C"], 2000000, "sh", ["-c", "sort -T \"$1\" \"$1/ids\" | uniq -d", "sh", work], Nil{})
        +t : List<&2, U32> = S.Out.text(o)
        dups.if(Nat.is_lt(0n, S.len(t)), t, work)
    case False{}:
      IO.pure(Unit, Unit{})

def fail.if(f: Maybe<&2, String>, +work: String) -> IO(Unit):
  match f:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{+w}:
      do IO<Unit>:
        S.rm(work)
        IO.die(Unit, 1, w)

def finish(m: Ms, +out: String, +work: String) -> IO(Unit):
  match m:
    case Ms{srcs, Mo{o, ids, +c, +t, a, f}, g}:
      do IO<Unit>:
        File.close(o)
        File.close(ids)
        +ds : List<&2, Sd> <- close.all(srcs, Nil{})
        fail.if(f, work)
        IO.print_err("mix-corpus: " ++ Nat.show(t) ++ " documents")
        summary(ds, t, bytes.all(ds))
        check.ids(c, work)
        S.rm(work)
        S.mv(out ++ ".tmp", out)
        du : S.Out <- S.run(".", [], 600, "du", ["-h", out], Nil{})
        IO.print_err("mix-corpus: wrote " ++ out ++ " (" ++ S.str(upto(S.Out.text(du), 9)) ++ ")")

# The specs ---------------------------------------------------------------------------

# the documents of a pass: its non-blank lines
type Cc is Type:
  Cc{rd: S.Rd, n: Nat, go: Bool}

def cc.got(rd: S.Rd, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> Cc:
  match m:
    case None{}:
      Cc{rd, n, False{}}
    case Some{l}:
      Cc{rd, Bool.pick(Nat, blank(l), n, 1n+n), True{}}

def cc.pair(+n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> Cc:
  (rd, m) = r
  cc.got(rd, n, m)

def cc.step(c: Cc) -> IO(Cc):
  match c:
    case Cc{rd, +n, g}:
      do IO<Cc>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return cc.pair(n, r)

def cc.go(fuel: Nat, c: Cc) -> IO(Nat):
  match fuel c:
    case 1n+p Cc{rd, n, True{}}:
      IO.bind(Cc, Nat, cc.step(Cc{rd, n, True{}}), cc.go(p))
    case _ Cc{rd, n, g}:
      do IO<Nat>:
        S.Rd.close(rd)
        return n

def docs.of(+path: String) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.lines(path)
    cc.go(big(), Cc{rd, 0n, True{}})

# kind 0 plain, 1 repeated, 2 cycling (3: REPEATS is neither a count nor cycle)
def kind.of(+rep: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.eq(rep, S.b("cycle")), 2n, Bool.pick(Nat, count(rep), Bool.pick(Nat, Nat.is_le(nat.of(rep), 1n), 0n, 1n), 3n))

def need(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, msg)

def said.rep(k: Nat, +path: String, +rep: String, +reps: Nat) -> IO(Unit):
  match k:
    case 1n:
      do IO<Unit>:
        +n : Nat <- docs.of(path)
        IO.print_err("mix-corpus: " ++ path ++ " repeated " ++ rep ++ "x (" ++ Nat.show(Nat.mul(reps, n)) ++ " documents)")
    case _:
      IO.pure(Unit, Unit{})

# a spec, checked as the bash checked it, in order; a repeated source's
# document count said as its expansion said it
def spec(+s: String) -> IO(Sd):
  +sb = S.b(s)
  +path = S.str(upto(sb, 58))
  +rest = past(sb, 58)
  +per = upto(rest, 58)
  +rep = Bool.pick(List<&2, U32>, S.eq(rest, per), S.b("1"), past(rest, 58))
  +k = kind.of(rep)
  do IO<Sd>:
    +there : Bool <- S.exists(path)
    need(there, "mix-corpus: no such source: " ++ path)
    need(count(per), "mix-corpus: PER_ROUND must be a positive integer: " ++ s)
    need(Nat.is_lt(0n, nat.of(per)), "mix-corpus: PER_ROUND must be positive: " ++ s)
    need(Bool.not(Nat.is_eq(k, 3n)), "mix-corpus: REPEATS must be a count or cycle: " ++ s)
    said.rep(k, path, S.str(rep), nat.of(rep))
    return Sd{path, s, nat.of(per), k, nat.of(rep), 0n, 0n, True{}, 0n, 0n, None{}}

def specs(xs: List<String>, acc: List<&2, Sd>) -> IO(List<&2, Sd>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, Sd>, List.reverse(&2, Sd, acc))
    case +x <> more:
      do IO<List<&2, Sd>>:
        +d : Sd <- spec(x)
        specs(more, d <> acc)

def open.all(ds: List<&2, Sd>) -> IO(List<Src>):
  match ds:
    case Nil{}:
      IO.pure(List<Src>, Nil{})
    case +d <> more:
      do IO<List<Src>>:
        r : S.Rd <- S.Rd.lines(Sd.path(d))
        rest : List<Src> <- open.all(more)
        return Src{Some{r}, d} <> rest

def anchors(ds: List<&2, Sd>) -> Nat:
  match ds:
    case Nil{}:
      0n
    case +d <> more:
      Nat.add(Bool.pick(Nat, Nat.is_eq(Sd.kind(d), 2n), 0n, 1n), anchors(more))

def mix(+out: String, xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    +ds : List<&2, Sd> <- specs(xs, Nil{})
    +alive : Nat = anchors(ds)
    need(Nat.is_lt(0n, alive), "mix-corpus: every source cycles; the mix would never end")
    +work : String <- S.mktemp()
    +ck : String <- S.env("CHECK_IDS", "1")
    +check : Bool = String.eq(Bool.pick(String, String.is_empty(ck), "1", ck), "1")
    o : File <- IO.try(File, File.open(out ++ ".tmp", "w"))
    ids : File <- IO.try(File, File.open(Bool.pick(String, check, work ++ "/ids", "/dev/null"), "w"))
    srcs : List<Src> <- open.all(ds)
    m : Ms <- mix.go(big(), Ms{srcs, Mo{o, ids, check, 0n, alive, None{}}, True{}})
    finish(m, out, work)

def args.go(xs: List<String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.die(Unit, 1, "usage: bend-mix OUT.jsonl SOURCE:PER[:REPEATS|:cycle] ...")
    case +o <> Nil{}:
      IO.die(Unit, 1, "mix-corpus: need at least one source")
    case +o <> more:
      mix(o, more)

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args.go(xs)
