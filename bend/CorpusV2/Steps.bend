import Base
import ../Sys.bend as S
import ../Json.bend as J
import ../Sha256.bend as H
import ./Lib.bend as L

# Steps: what the chain's shell scripts once computed in inline Python
# (bend/gpu/raw-driver.sh, credit-watch.sh, raw-stage.sh, next-stage.sh;
# tools/corpus-v2/restage-ns.sh, evals.sh) and bend/gpu/insert-stage.py, as
# bend-corpus-v2 subcommands.  Each `st.<name>(args)` is one subcommand (args:
# what follows its name) and gives what the Python gave, byte for byte:
#
#   credit [MIN]                  the top-level "credit" of `vastai show user --raw` (stdin), as
#                                 Python's print showed it; with MIN, exit 0 when it is under
#                                 MIN, else 1 (2: no credit, or MIN not a number)
#   credit-ok STAGES CREDIT CUR ADD
#                                 raw-driver's guard: does CREDIT cover the queue (CUR is the
#                                 box's `NAME step=I/N`) plus ADD steps, the end and the margin
#                                 (env SECS_PER_STEP, DPH, END_COST, MARGIN); the message on
#                                 stderr, exit 0 or 1
#   split-lang SRC OUT            SRC's JSON lines by their id's extension into OUT/LANG.jsonl
#   nul-jsonl SRC DST             a NUL (id, text) file as Python's json.dumps lines
#   per N TOP                     max(1, round(100 * N / TOP))
#   specs-mixnew OUT FILE...      raw-stage mixnew's per-round specs (stdout), OUT/LANG.jsonl
#                                 made, the counts on stderr
#   specs-next REPLAY L:C...      next-stage's per-round specs
#   replay-filler D SRC NEW...    SRC's files-hi/lo.nul into D less the ids NEW's hold
#   drop-repos VAULT.tsv SRC DST  SRC's lines whose repository is not in the vault
#   insert-stage STAGES LOG AFTER LINE...
#                                 LINE into STAGES after the first AFTER there, never behind
#                                 the stage LOG says the chain last started
#   vault-sample SRC DST          evals.sh's vault eval sample (up to 5 a repository, ~2 MB)
#
# Python's floats are IEEE doubles and Bend has none (Nat, U32, F32 only), so
# the doubles are emulated exactly: a double is a sign, a mantissa of at most
# 53 bits (a bit list) and an exponent, and every operation rounds the exact
# result to the nearest double, ties to even, as the hardware does.  The
# formats are Python's: `:.Nf` and round() round the double's exact value
# ties to even; sum() of floats is Neumaier's compensated sum (Python 3.12+).
#
# Where the Python and these part, only on input the chain does not make:
# whitespace is ASCII's (str.split and the regex's \s also take Unicode
# spaces); int() and float() take no `_` and float() no inf or nan;
# split-lang prints its counts in one order (Python's set order changed run
# to run); vault-sample breaks a tie of hash and id by line (Python by text:
# the vault's ids are unique); a failure says what failed in one line on
# stderr and exits 1 (2: usage, or credit's no credit or bad MIN) where
# Python printed a traceback and exited 1.
#
# Every name starts with `st.`: a Bend program's definitions share one
# namespace across its imports.

# Basics -----------------------------------------------------------------------

def st.fuel() -> Nat:
  U32.to_nat(4294967295)

def st.b2n(b: Bool) -> Nat:
  match b:
    case True{}:
      1n
    case False{}:
      0n

def st.usage(msg: String) -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 " ++ msg)

def st.strs(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> st.strs(t)

def st.strs.back(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> st.strs.back(t)

# bytes as a String a byte a character: one String per byte string (a set or
# map key), whatever the bytes are
def st.key(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case h <> t:
      SCon{Chr{h}, st.key(t)}

# Python's whitespace (str.split, strip), ASCII: \t \n \v \f \r, \x1c-\x1f, space
def st.ws(+c: U32) -> Bool:
  Bool.or(Bool.and(U32.is_le(9, c), U32.is_le(c, 13)), Bool.and(U32.is_le(28, c), U32.is_le(c, 32)))

def st.ws.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      st.ws(h)

def st.ws.drop(xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t True{}:
      st.ws.drop(t, st.ws.head(t))
    case r _:
      r

def st.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  +a = st.ws.drop(xs, st.ws.head(xs))
  +r = List.reverse(&2, U32, a)
  List.reverse(&2, U32, st.ws.drop(r, st.ws.head(r)))

def st.ws.norm(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, st.ws(h), 32, h) <> st.ws.norm(t)

def st.keep.word(w: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match w:
    case Nil{}:
      rest
    case h <> t:
      (h <> t) <> rest

def st.words.of(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> more:
      st.keep.word(w, st.words.of(more))

# Python's s.split(): the words between runs of whitespace
def st.words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  st.words.of(S.split(st.ws.norm(xs), 32))

# Python's s.split(sep): n separators, n + 1 pieces, empty ones kept
def st.psplit(+xs: List<&2, U32>, +sep: U32) -> List<&2, List<&2, U32>>:
  S.split(List.append(&2, U32, xs, [sep]), sep)

def st.nth(xss: List<&2, List<&2, U32>>, +i: Nat) -> Maybe<&2, List<&2, U32>>:
  match xss i:
    case Nil{} _:
      None{}
    case xs <> more 0n:
      Some{xs}
    case xs <> more 1n+k:
      st.nth(more, k)

# the pieces joined by the bytes sep
def st.join.with(xss: List<&2, List<&2, U32>>, +sep: List<&2, U32>) -> List<&2, U32>:
  match xss:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      x
    case x <> more:
      L.v2.concat([x, sep, st.join.with(more, sep)])

def st.join.args(xs: List<&2, String>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      S.b(x)
    case x <> more:
      L.v2.concat([S.b(x), [32], st.join.args(more)])

# Python's s.find(p, k): where p first occurs from k on (None: -1)
def st.find.go(xs: List<&2, U32>, +p: List<&2, U32>, +k: Nat, at: Bool) -> Maybe<&2, Nat>:
  match xs at:
    case _ True{}:
      Some{k}
    case h <> +t False{}:
      st.find.go(t, p, 1n+k, S.prefix(t, p))
    case Nil{} False{}:
      None{}

def st.find(+xs: List<&2, U32>, +p: List<&2, U32>, +k: Nat) -> Maybe<&2, Nat>:
  +ys = List.drop(&2, U32, xs, k)
  st.find.go(ys, p, k, S.prefix(ys, p))

# a found position plus d, or `none` (Python's -1 plus d)
def st.at.or(m: Maybe<&2, Nat>, +d: Nat, +none: Nat) -> Nat:
  match m:
    case Some{k}:
      Nat.add(k, d)
    case None{}:
      none

# Python's xs[a:j] with j a find's answer (-1: one short of the end)
def st.slice(+xs: List<&2, U32>, +a: Nat, m: Maybe<&2, Nat>) -> List<&2, U32>:
  +b = st.at.or(m, 0n, Nat.sub(S.len(xs), 1n))
  List.take(&2, U32, List.drop(&2, U32, xs, a), Nat.sub(b, a))

# xs after its last c (all of xs when there is none: Python's rsplit(c, 1)[-1])
def st.after.last(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  List.reverse(&2, U32, L.v2.before(List.reverse(&2, U32, xs), c))

# Python's text mode reads "\r\n" and a lone "\r" as "\n"
def st.cr.lone(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 13), 10, h) <> st.cr.lone(t)

def st.cr(+xs: List<&2, U32>) -> List<&2, U32>:
  st.cr.lone(L.v2.crlf(xs))

# lines with their newlines (Python's splitlines(True) of "\n" text)
def st.lines.nl(ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> Nil{}:
      st.keep.word(p, Nil{})
    case p <> more:
      List.append(&2, U32, p, [10]) <> st.lines.nl(more)

def st.lines.keep(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  st.lines.nl(st.psplit(xs, 10))

def st.is.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def st.digit.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      st.is.digit(h)

# Bytes taken and what follows ---------------------------------------------------

type StJs is Data:
  StJs{tok: List<&2, U32>, rest: List<&2, U32>}

def st.js.put(h: U32, s: StJs) -> StJs:
  match s:
    case StJs{t, r}:
      StJs{h <> t, r}

def st.js.tok(+s: StJs) -> List<&2, U32>:
  match s:
    case StJs{t, r}:
      t

def st.js.rest(+s: StJs) -> List<&2, U32>:
  match s:
    case StJs{t, r}:
      r

# the leading digits and the rest
def st.span.go(xs: List<&2, U32>, at: Bool) -> StJs:
  match xs at:
    case h <> +t True{}:
      st.js.put(h, st.span.go(t, st.digit.head(t)))
    case r _:
      StJs{Nil{}, r}

def st.span(+xs: List<&2, U32>) -> StJs:
  st.span.go(xs, st.digit.head(xs))

# digits as a number (few: a Nat holds 48 bits)
def st.dec.go(ds: List<&2, U32>, acc: Nat) -> Nat:
  match ds:
    case Nil{}:
      acc
    case d <> t:
      st.dec.go(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(d, 48))))

def st.dec.nat(ds: List<&2, U32>) -> Nat:
  st.dec.go(ds, 0n)

# Signed integers (Python's int) ---------------------------------------------------

type StI is Data:
  StI{neg: Bool, mag: Nat}

def st.i.mk(+neg: Bool, +mag: Nat) -> StI:
  StI{Bool.and(neg, Nat.is_ne(mag, 0n)), mag}

def st.i.of(+n: Nat) -> StI:
  StI{False{}, n}

def st.i.add(a: StI, b: StI) -> StI:
  match a b:
    case StI{+an, +am} StI{+bn, +bm}:
      +same = Bool.not(Bool.xor(an, bn))
      +big = Nat.is_le(bm, am)
      st.i.mk(Bool.pick(Bool, same, an, Bool.pick(Bool, big, an, bn)),
        Bool.pick(Nat, same, Nat.add(am, bm), Bool.pick(Nat, big, Nat.sub(am, bm), Nat.sub(bm, am))))

def st.i.negate(a: StI) -> StI:
  match a:
    case StI{n, +m}:
      st.i.mk(Bool.not(n), m)

def st.i.sub(a: StI, b: StI) -> StI:
  st.i.add(a, st.i.negate(b))

def st.i.show(a: StI) -> String:
  match a:
    case StI{n, m}:
      Bool.pick(String, n, "-", "") ++ Nat.show(m)

def st.int.fin(+neg: Bool, sp: StJs) -> Maybe<&2, StI>:
  match sp:
    case StJs{+ds, +rest}:
      +n = st.dec.nat(ds)
      Bool.pick(Maybe<&2, StI>, Bool.and(Nat.is_ne(S.len(ds), 0n), Nat.is_eq(S.len(rest), 0n)), Some{st.i.mk(neg, n)}, None{})

# Python's int(s) of a decimal: whitespace around, a sign, digits
def st.int.read(+xs: List<&2, U32>) -> Maybe<&2, StI>:
  +t = st.trim(xs)
  +neg = S.head.is(t, 45)
  st.int.fin(neg, st.span(Bool.pick(List<&2, U32>, Bool.or(neg, S.head.is(t, 43)), List.drop(&2, U32, t, 1n), t)))

def st.int.m(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, StI>:
  match m:
    case Some{w}:
      st.int.read(w)
    case None{}:
      None{}

# Big naturals: bits, least significant first ----------------------------------

def st.bn.zeros(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      0 <> st.bn.zeros(p)

# xs times 2^n
def st.bn.shl(xs: List<&2, U32>, n: Nat) -> List<&2, U32>:
  List.append(&2, U32, st.bn.zeros(n), xs)

def st.bn.of.go(fuel: Nat, +n: Nat, z: Bool) -> List<&2, U32>:
  match fuel z:
    case 1n+f False{}:
      +q = Nat.div(n, 2n)
      U32.from_nat(Nat.mod(n, 2n)) <> st.bn.of.go(f, q, Nat.is_eq(q, 0n))
    case _ _:
      Nil{}

def st.bn.of(+n: Nat) -> List<&2, U32>:
  st.bn.of.go(64n, n, Nat.is_eq(n, 0n))

# a small one back (a Nat holds 48 bits)
def st.bn.nat(xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case b <> t:
      Nat.add(U32.to_nat(b), Nat.mul(st.bn.nat(t), 2n))

def st.bn.is.zero(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case b <> t:
      Bool.and(U32.is_eq(b, 0), st.bn.is.zero(t))

def st.bn.lead.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case h <> +t True{}:
      st.bn.lead.go(t, S.head.is(t, 0))
    case r _:
      r

# without its high zero bits
def st.bn.norm(+xs: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, xs)
  List.reverse(&2, U32, st.bn.lead.go(r, S.head.is(r, 0)))

def st.bn.carry(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Bool.pick(List<&2, U32>, U32.is_eq(c, 0), Nil{}, [c])
    case x <> t:
      +s = U32.add(x, c)
      U32.and(s, 1) <> st.bn.carry(t, U32.shrn(s, 1n))

def st.bn.add.go(xs: List<&2, U32>, ys: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs ys:
    case x <> xt y <> yt:
      +s = U32.add(U32.add(x, y), c)
      U32.and(s, 1) <> st.bn.add.go(xt, yt, U32.shrn(s, 1n))
    case Nil{} ys2:
      st.bn.carry(ys2, c)
    case xs2 Nil{}:
      st.bn.carry(xs2, c)

def st.bn.add(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  st.bn.add.go(xs, ys, 0)

def st.bn.borrow(xs: List<&2, U32>, +b: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      +s = U32.sub(U32.add(x, 2), b)
      U32.and(s, 1) <> st.bn.borrow(t, U32.sub(1, U32.shrn(s, 1n)))

def st.bn.sub.go(xs: List<&2, U32>, ys: List<&2, U32>, +b: U32) -> List<&2, U32>:
  match xs ys:
    case x <> xt y <> yt:
      +s = U32.sub(U32.add(x, 2), U32.add(y, b))
      U32.and(s, 1) <> st.bn.sub.go(xt, yt, U32.sub(1, U32.shrn(s, 1n)))
    case xs2 Nil{}:
      st.bn.borrow(xs2, b)
    case Nil{} ys2:
      Nil{}

# xs - ys, for xs >= ys
def st.bn.sub(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  st.bn.sub.go(xs, ys, 0)

def st.bn.cmp.bit(+x: U32, +y: U32, acc: Cmp) -> Cmp:
  Bool.pick(Cmp, U32.is_lt(x, y), LT{}, Bool.pick(Cmp, U32.is_lt(y, x), GT{}, acc))

def st.bn.cmp.go(xs: List<&2, U32>, ys: List<&2, U32>, acc: Cmp) -> Cmp:
  match xs ys:
    case +x <> xt +y <> yt:
      st.bn.cmp.go(xt, yt, st.bn.cmp.bit(x, y, acc))
    case xs2 Nil{}:
      Bool.pick(Cmp, st.bn.is.zero(xs2), acc, GT{})
    case Nil{} ys2:
      Bool.pick(Cmp, st.bn.is.zero(ys2), acc, LT{})

def st.bn.cmp(xs: List<&2, U32>, ys: List<&2, U32>) -> Cmp:
  st.bn.cmp.go(xs, ys, EQ{})

def st.bn.mul(+xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  match ys:
    case Nil{}:
      Nil{}
    case y <> t:
      st.bn.add(Bool.pick(List<&2, U32>, U32.is_eq(y, 1), xs, Nil{}), 0 <> st.bn.mul(xs, t))

def st.bn.mul10(+xs: List<&2, U32>) -> List<&2, U32>:
  st.bn.add(st.bn.shl(xs, 3n), st.bn.shl(xs, 1n))

def st.bn.pow10(k: Nat) -> List<&2, U32>:
  match k:
    case 0n:
      [1]
    case 1n+p:
      st.bn.mul10(st.bn.pow10(p))

# long division, a bit at a time from the top: quotient and remainder
type StQr is Data:
  StQr{q: List<&2, U32>, r: List<&2, U32>}

def st.bn.div.go(bits: List<&2, U32>, +d: List<&2, U32>, q: List<&2, U32>, r: List<&2, U32>) -> StQr:
  match bits:
    case Nil{}:
      StQr{q, r}
    case b <> t:
      +r1 = {b <> r : List<&2, U32>}
      +ge = Bool.not(Cmp.is_lt(st.bn.cmp(r1, d)))
      st.bn.div.go(t, d, Bool.to_u32(ge) <> q, Bool.pick(List<&2, U32>, ge, st.bn.sub(r1, d), r1))

def st.bn.divmod(+n: List<&2, U32>, +d: List<&2, U32>) -> StQr:
  st.bn.div.go(List.reverse(&2, U32, n), d, Nil{}, Nil{})

def st.bn.fst(+p: StQr) -> List<&2, U32>:
  match p:
    case StQr{q, r}:
      q

def st.bn.snd(+p: StQr) -> List<&2, U32>:
  match p:
    case StQr{q, r}:
      r

def st.bn.digit(xs: List<&2, U32>) -> Char:
  Chr{U32.add(48, U32.from_nat(st.bn.nat(xs)))}

def st.bn.show.go(fuel: Nat, +xs: List<&2, U32>, z: Bool, acc: String) -> String:
  match fuel z:
    case 1n+f False{}:
      +qr = st.bn.divmod(xs, [0, 1, 0, 1])
      +qn = st.bn.norm(st.bn.fst(qr))
      st.bn.show.go(f, qn, st.bn.is.zero(qn), SCon{st.bn.digit(st.bn.snd(qr)), acc})
    case _ _:
      acc

# in decimal
def st.bn.show(+xs: List<&2, U32>) -> String:
  +n = st.bn.norm(xs)
  Bool.pick(String, st.bn.is.zero(n), "0", st.bn.show.go(S.len(n), n, False{}, ""))

# digits (ASCII) as a big natural
def st.bn.dec(ds: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match ds:
    case Nil{}:
      acc
    case d <> t:
      st.bn.dec(t, st.bn.add(st.bn.mul10(acc), st.bn.of(U32.to_nat(U32.sub(d, 48)))))

# Doubles --------------------------------------------------------------------------
#
# (-1)^neg * m * 2^(e - bias): m at most 53 bits (none: zero).

type StF is Data:
  StF{neg: Bool, m: List<&2, U32>, e: Nat}

def st.f.bias() -> Nat:
  1100n

def st.f.neg(+x: StF) -> Bool:
  match x:
    case StF{n, m, e}:
      n

def st.f.m(+x: StF) -> List<&2, U32>:
  match x:
    case StF{n, m, e}:
      m

def st.f.e(+x: StF) -> Nat:
  match x:
    case StF{n, m, e}:
      e

def st.f.round.q(neg: Bool, +q: List<&2, U32>, exact: Bool, +e: Nat, +s: Nat, zero: Bool) -> StF:
  match zero:
    case True{}:
      StF{neg, Nil{}, st.f.bias()}
    case False{}:
      # x bits below the mantissa: the first decides, the rest and the
      # remainder break a tie, and a tie goes to the even mantissa
      +x = Nat.sub(S.len(q), 53n)
      +mant = List.drop(&2, U32, q, x)
      +top = L.v2.byte.at(q, Nat.sub(x, 1n))
      +below = Bool.and(st.bn.is.zero(List.take(&2, U32, q, Nat.sub(x, 1n))), exact)
      +up = Bool.and(U32.is_eq(top, 1), Bool.or(Bool.not(below), U32.is_eq(L.v2.byte.head(mant), 1)))
      +m2 = st.bn.norm(Bool.pick(List<&2, U32>, up, st.bn.add(mant, [1]), mant))
      +over = Nat.is_eq(S.len(m2), 54n)
      StF{neg, Bool.pick(List<&2, U32>, over, List.drop(&2, U32, m2, 1n), m2), Nat.sub(Nat.add(Nat.add(e, x), st.b2n(over)), s)}

# the double nearest num / den * 2^(e - bias), ties to even (den not zero):
# the quotient is taken to at least 55 bits, plus whether a remainder is left
def st.f.round(neg: Bool, +num: List<&2, U32>, +den: List<&2, U32>, +e: Nat) -> StF:
  +n = st.bn.norm(num)
  +d = st.bn.norm(den)
  +s = Nat.sub(Nat.add(55n, S.len(d)), S.len(n))
  +qr = st.bn.divmod(st.bn.shl(n, s), d)
  st.f.round.q(neg, st.bn.norm(st.bn.fst(qr)), st.bn.is.zero(st.bn.snd(qr)), e, s, st.bn.is.zero(n))

def st.f.zero() -> StF:
  StF{False{}, Nil{}, st.f.bias()}

def st.f.of.nat(+n: Nat) -> StF:
  st.f.round(False{}, st.bn.of(n), [1], st.f.bias())

def st.f.of.i(a: StI) -> StF:
  match a:
    case StI{n, +m}:
      st.f.round(n, st.bn.of(m), [1], st.f.bias())

# a / b of two ints (Python's true division, correctly rounded)
def st.f.ratio(+a: Nat, +b: Nat) -> StF:
  st.f.round(False{}, st.bn.of(a), st.bn.of(b), st.f.bias())

def st.f.negate(x: StF) -> StF:
  match x:
    case StF{n, m, e}:
      StF{Bool.not(n), m, e}

def st.f.mul(+a: StF, +b: StF) -> StF:
  st.f.round(Bool.xor(st.f.neg(a), st.f.neg(b)), st.bn.mul(st.f.m(a), st.f.m(b)), [1], Nat.sub(Nat.add(st.f.e(a), st.f.e(b)), st.f.bias()))

def st.f.div(+a: StF, +b: StF) -> StF:
  st.f.round(Bool.xor(st.f.neg(a), st.f.neg(b)), st.f.m(a), st.f.m(b), Nat.sub(Nat.add(st.f.e(a), st.f.bias()), st.f.e(b)))

def st.f.add(+a: StF, +b: StF) -> StF:
  +ea = st.f.e(a)
  +eb = st.f.e(b)
  +lo = Nat.min(ea, eb)
  +ma = st.bn.shl(st.f.m(a), Nat.sub(ea, lo))
  +mb = st.bn.shl(st.f.m(b), Nat.sub(eb, lo))
  +na = st.f.neg(a)
  +nb = st.f.neg(b)
  +same = Bool.not(Bool.xor(na, nb))
  +less = Cmp.is_lt(st.bn.cmp(ma, mb))
  # like signs add their magnitudes; else the larger less the smaller, with
  # its sign; an exact zero is -0 only when both were negative
  +mag = Bool.pick(List<&2, U32>, same, st.bn.add(ma, mb), Bool.pick(List<&2, U32>, less, st.bn.sub(mb, ma), st.bn.sub(ma, mb)))
  +sg = Bool.pick(Bool, same, na, Bool.pick(Bool, less, nb, na))
  st.f.round(Bool.pick(Bool, st.bn.is.zero(mag), Bool.and(na, nb), sg), mag, [1], lo)

def st.f.sub(+a: StF, b: StF) -> StF:
  st.f.add(a, st.f.negate(b))

def st.f.cmp.mag(+a: StF, +b: StF) -> Cmp:
  +ea = st.f.e(a)
  +eb = st.f.e(b)
  +lo = Nat.min(ea, eb)
  st.bn.cmp(st.bn.shl(st.f.m(a), Nat.sub(ea, lo)), st.bn.shl(st.f.m(b), Nat.sub(eb, lo)))

def st.f.is.neg(+a: StF) -> Bool:
  Bool.and(st.f.neg(a), Bool.not(st.bn.is.zero(st.f.m(a))))

def st.f.cmp(+a: StF, +b: StF) -> Cmp:
  +na = st.f.is.neg(a)
  +nb = st.f.is.neg(b)
  Bool.pick(Cmp, Bool.and(na, Bool.not(nb)), LT{},
    Bool.pick(Cmp, Bool.and(nb, Bool.not(na)), GT{},
      Bool.pick(Cmp, na, st.f.cmp.mag(b, a), st.f.cmp.mag(a, b))))

# Python 3.12+'s sum() of floats after its first (Neumaier): t = f + x, and
# c gathers what t lost; the answer is f + c when c is not zero
def st.f.sum.go(xs: List<&2, StF>, +f: StF, +c: StF) -> StF:
  match xs:
    case Nil{}:
      Bool.pick(StF, st.bn.is.zero(st.f.m(c)), f, st.f.add(f, c))
    case +x <> t:
      +s = st.f.add(f, x)
      +big = Cmp.is_ge(st.f.cmp.mag(f, x))
      +d = Bool.pick(StF, big, st.f.add(st.f.sub(f, s), x), st.f.add(st.f.sub(x, s), f))
      st.f.sum.go(t, s, st.f.add(c, d))

# sum(xs) of floats (its start, the int 0, adds nothing)
def st.f.sum(xs: List<&2, StF>) -> StF:
  match xs:
    case Nil{}:
      st.f.zero()
    case x <> t:
      st.f.sum.go(t, x, st.f.zero())

# round(|x| * 10^k) ties to even, the double's exact value
def st.f.scaled.at(+m: List<&2, U32>, big: Bool, +up: Nat, +down: Nat) -> List<&2, U32>:
  match big:
    case True{}:
      st.bn.shl(m, up)
    case False{}:
      +q = List.drop(&2, U32, m, down)
      +top = L.v2.byte.at(m, Nat.sub(down, 1n))
      +rest0 = st.bn.is.zero(List.take(&2, U32, m, Nat.sub(down, 1n)))
      +up1 = Bool.and(U32.is_eq(top, 1), Bool.or(Bool.not(rest0), U32.is_eq(L.v2.byte.head(q), 1)))
      Bool.pick(List<&2, U32>, up1, st.bn.add(q, [1]), q)

def st.f.scaled(+x: StF, +k: Nat) -> List<&2, U32>:
  +e = st.f.e(x)
  +b = st.f.bias()
  st.f.scaled.at(st.bn.mul(st.f.m(x), st.bn.pow10(k)), Nat.is_le(b, e), Nat.sub(e, b), Nat.sub(b, e))

# Python's round(x) of a double (x >= 0)
def st.f.rint(+x: StF) -> Nat:
  st.bn.nat(st.f.scaled(x, 0n))

def st.f.point(+s: String, k: Nat) -> String:
  match k:
    case 0n:
      s
    case 1n+p:
      +i = Nat.sub(String.length(s), Nat.add(p, 1n))
      String.take(s, i) ++ "." ++ String.drop(s, i)

# Python's f"{x:.{k}f}"
def st.f.fixed(+x: StF, +k: Nat) -> String:
  +ds = st.bn.show(st.f.scaled(x, k))
  +w = Nat.add(k, 1n)
  Bool.pick(String, st.f.neg(x), "-", "") ++ st.f.point(String.repeat("0", Nat.sub(w, String.length(ds))) ++ ds, k)

# Python's float(s) of a decimal: whitespace around, a sign, digits with a
# point, an exponent (no inf, nan or underscores)
type StEx is Data:
  StEx{ok: Bool, neg: Bool, ds: List<&2, U32>}

def st.f.exp.fin(+en: Bool, sp: StJs) -> StEx:
  match sp:
    case StJs{+ds, +rest}:
      StEx{Bool.and(Nat.is_ne(S.len(ds), 0n), Nat.is_eq(S.len(rest), 0n)), en, ds}

def st.f.exp.of(+r2: List<&2, U32>, has: Bool) -> StEx:
  match has:
    case False{}:
      StEx{Nat.is_eq(S.len(r2), 0n), False{}, Nil{}}
    case True{}:
      +r = List.drop(&2, U32, r2, 1n)
      +en = S.head.is(r, 45)
      st.f.exp.fin(en, st.span(Bool.pick(List<&2, U32>, Bool.or(en, S.head.is(r, 43)), List.drop(&2, U32, r, 1n), r)))

def st.f.make(+neg: Bool, +d1: List<&2, U32>, +d2: List<&2, U32>, ex: StEx) -> Maybe<&2, StF>:
  match ex:
    case StEx{ok, +en, +ds}:
      +any = Nat.is_ne(Nat.add(S.len(d1), S.len(d2)), 0n)
      +e = st.dec.nat(ds)
      +fr = S.len(d2)
      +p = Bool.pick(Nat, en, 0n, e)
      +q = Bool.pick(Nat, en, Nat.add(e, fr), fr)
      +dm = st.bn.dec(List.append(&2, U32, d1, d2), Nil{})
      +v = Bool.pick(StF, Nat.is_le(q, p), st.f.round(neg, st.bn.mul(dm, st.bn.pow10(Nat.sub(p, q))), [1], st.f.bias()),
        st.f.round(neg, dm, st.bn.pow10(Nat.sub(q, p)), st.f.bias()))
      Bool.pick(Maybe<&2, StF>, Bool.and(ok, any), Some{v}, None{})

def st.f.frac.of(+r1: List<&2, U32>, dot: Bool) -> StJs:
  match dot:
    case True{}:
      st.span(List.drop(&2, U32, r1, 1n))
    case False{}:
      StJs{Nil{}, r1}

def st.f.read.int(+neg: Bool, a: StJs) -> Maybe<&2, StF>:
  match a:
    case StJs{+d1, +r1}:
      +b = st.f.frac.of(r1, S.head.is(r1, 46))
      +r2 = st.js.rest(b)
      st.f.make(neg, d1, st.js.tok(b), st.f.exp.of(r2, Bool.or(S.head.is(r2, 101), S.head.is(r2, 69))))

def st.f.read(+xs: List<&2, U32>) -> Maybe<&2, StF>:
  +t = st.trim(xs)
  +neg = S.head.is(t, 45)
  st.f.read.int(neg, st.span(Bool.pick(List<&2, U32>, Bool.or(neg, S.head.is(t, 43)), List.drop(&2, U32, t, 1n), t)))

# UTF-8 as Python decodes it with "replace" ---------------------------------------

def st.u8.in(+c: U32, +lo: U32, +hi: U32) -> Bool:
  Bool.and(U32.is_le(lo, c), U32.is_le(c, hi))

# the bytes a sequence led by h takes (0: h leads none)
def st.u8.need(+h: U32) -> Nat:
  Bool.pick(Nat, U32.is_lt(h, 128), 1n, Bool.pick(Nat, st.u8.in(h, 194, 223), 2n,
    Bool.pick(Nat, st.u8.in(h, 224, 239), 3n, Bool.pick(Nat, st.u8.in(h, 240, 244), 4n, 0n))))

# how many of the bytes after h continue its sequence (at most need - 1); the
# second byte's range is narrower after E0, ED, F0 and F4
def st.u8.conts(+h: U32, +t: List<&2, U32>, +n: Nat) -> Nat:
  +lo = Bool.pick(U32, U32.is_eq(h, 224), 160, Bool.pick(U32, U32.is_eq(h, 240), 144, 128))
  +hi = Bool.pick(U32, U32.is_eq(h, 237), 159, Bool.pick(U32, U32.is_eq(h, 244), 143, 191))
  +c1 = Bool.and(Nat.is_le(2n, n), st.u8.in(L.v2.byte.at(t, 0n), lo, hi))
  +c2 = Bool.and(c1, Bool.and(Nat.is_le(3n, n), st.u8.in(L.v2.byte.at(t, 1n), 128, 191)))
  +c3 = Bool.and(c2, Bool.and(Nat.is_le(4n, n), st.u8.in(L.v2.byte.at(t, 2n), 128, 191)))
  Nat.add(Nat.add(st.b2n(c1), st.b2n(c2)), st.b2n(c3))

def st.u8.ascii(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      U32.is_lt(h, 128)

def st.u8.fix.go(fuel: Nat, xs: List<&2, U32>, ascii: Bool) -> List<&2, U32>:
  match fuel xs ascii:
    case 1n+f h <> +t True{}:
      h <> st.u8.fix.go(f, t, st.u8.ascii(t))
    case 1n+f +h <> +t False{}:
      +n = st.u8.need(h)
      +k = st.u8.conts(h, t, n)
      +rest = List.drop(&2, U32, t, k)
      List.append(&2, U32, Bool.pick(List<&2, U32>, Nat.is_eq(Nat.add(k, 1n), n), h <> List.take(&2, U32, t, k), [239, 191, 189]),
        st.u8.fix.go(f, rest, st.u8.ascii(rest)))
    case _ _ _:
      Nil{}

# bytes.decode("utf-8", "replace") as UTF-8 again: each maximal ill-formed
# subsequence becomes U+FFFD
def st.u8.fix(+xs: List<&2, U32>) -> List<&2, U32>:
  st.u8.fix.go(1n+S.len(xs), xs, st.u8.ascii(xs))

# characters (bytes that do not continue one)
def st.cps(xs: List<&2, U32>, acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      st.cps(t, Nat.add(acc, st.b2n(Bool.not(st.u8.in(h, 128, 191)))))

# Reading as Python's split does ------------------------------------------------
#
# A file a field at a time, a field ending at a separator byte; the stream's
# last field (what follows the last separator) is a field too, as in
# Python's data.split(sep).  Memory is a chunk plus the longest field.

type StFld is Data:
  StFld{x: List<&2, U32>, ended: Bool}

type StCut is Data:
  StCut{x: List<&2, U32>, rest: List<&2, U32>, ended: Bool}

def st.cut.put(h: U32, c: StCut) -> StCut:
  match c:
    case StCut{x, r, e}:
      StCut{h <> x, r, e}

def st.cut.go(+xs: List<&2, U32>, +sep: U32, at: Bool) -> StCut:
  match xs at:
    case h <> +t False{}:
      st.cut.put(h, st.cut.go(t, sep, S.head.is(t, sep)))
    case h <> t True{}:
      StCut{Nil{}, t, True{}}
    case Nil{} _:
      StCut{Nil{}, Nil{}, False{}}

def st.cut(+xs: List<&2, U32>, +sep: U32) -> StCut:
  st.cut.go(xs, sep, S.head.is(xs, sep))

# a file opened, or the tool stops with status 1 (as Python stopped on the
# exception), naming it
def st.open.got(+path: String, r: Result<&1, &1, U32 & String, File>) -> IO(File):
  match r:
    case Done{f}:
      IO.pure(File, f)
    case Fail{(c, m)}:
      IO.die(File, 1, path ++ ": " ++ m)

def st.open(+path: String, mode: String) -> IO(File):
  do IO<File>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, mode)
    st.open.got(path, r)

type StRd is Type:
  StRd{f: File, sep: U32, buf: List<&2, U32>, eof: Bool, done: Bool}

type StRq is Type:
  StRq{f: File, sep: U32, buf: List<&2, U32>, eof: Bool, done: Bool, more: Bool, got: Maybe<&2, StFld>}

def st.rd.open(path: String, +sep: U32) -> IO(StRd):
  do IO<StRd>:
    f : File <- st.open(path, "r")
    return StRd{f, sep, Nil{}, False{}, False{}}

def st.rd.close(r: StRd) -> IO(Unit):
  match r:
    case StRd{f, s, b, e, d}:
      File.close(f)

def st.rd.fill(+sep: U32, buf: List<&2, U32>, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(StRq):
  (f, x) = r
  do IO<StRq>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return StRq{f, sep, List.append(&2, U32, buf, xs), Nat.is_eq(List.length(&2, U32, xs), 0n), False{}, True{}, None{}}

def st.rd.cut(f: File, +sep: U32, eof: Bool, c: StCut) -> IO(StRq):
  match eof c:
    case _ StCut{x, rest, True{}}:
      IO.pure(StRq, StRq{f, sep, rest, eof, False{}, False{}, Some{StFld{x, True{}}}})
    case True{} StCut{x, rest, False{}}:
      IO.pure(StRq, StRq{f, sep, Nil{}, True{}, True{}, False{}, Some{StFld{x, False{}}}})
    case False{} StCut{x, rest, False{}}:
      do IO<StRq>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, S.chunk())
        st.rd.fill(sep, x, r)

def st.rd.try(q: StRq) -> IO(StRq):
  match q:
    case StRq{f, +sep, +buf, eof, d, m, g}:
      st.rd.cut(f, sep, eof, st.cut(buf, sep))

def st.rd.go(fuel: Nat, q: StRq) -> IO(StRd & Maybe<&2, StFld>):
  match fuel q:
    case 1n+p StRq{f, sep, buf, eof, d, True{}, g}:
      IO.bind(StRq, StRd & Maybe<&2, StFld>, st.rd.try(StRq{f, sep, buf, eof, d, True{}, g}), st.rd.go(p))
    case _ StRq{f, sep, buf, eof, d, False{}, g}:
      IO.pure(StRd & Maybe<&2, StFld>, (StRd{f, sep, buf, eof, d}, g))
    case 0n StRq{f, sep, buf, eof, d, True{}, g}:
      do IO<StRd & Maybe<&2, StFld>>:
        File.close(f)
        IO.die(StRd & Maybe<&2, StFld>, 1, "steps: a field past 4 GiB")

# the next field and whether a separator ended it; None after the last
def st.rd.next(r: StRd) -> IO(StRd & Maybe<&2, StFld>):
  match r:
    case StRd{f, sep, buf, eof, True{}}:
      IO.pure(StRd & Maybe<&2, StFld>, (StRd{f, sep, buf, eof, True{}}, None{}))
    case StRd{f, sep, buf, eof, False{}}:
      st.rd.go(4096n, StRq{f, sep, buf, eof, False{}, True{}, None{}})

def st.line.last(x: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match x:
    case Nil{}:
      None{}
    case h <> t:
      Some{h <> t}

def st.line.of(m: Maybe<&2, StFld>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case Some{StFld{x, True{}}}:
      Some{List.append(&2, U32, x, [10])}
    case Some{StFld{x, False{}}}:
      st.line.last(x)
    case None{}:
      None{}

def st.rd.line.fin(x: StRd & Maybe<&2, StFld>) -> IO(StRd & Maybe<&2, List<&2, U32>>):
  (r, m) = x
  IO.pure(StRd & Maybe<&2, List<&2, U32>>, (r, st.line.of(m)))

# the next line with its newline (a last line may lack one), as Python's
# `for line in open(path, "rb")` gives them
def st.rd.line(r: StRd) -> IO(StRd & Maybe<&2, List<&2, U32>>):
  IO.bind(StRd & Maybe<&2, StFld>, StRd & Maybe<&2, List<&2, U32>>, st.rd.next(r), x => st.rd.line.fin(x))

type StPair is Data:
  StPair{id: List<&2, U32>, text: List<&2, U32>}

def st.pair.of(id: List<&2, U32>, m: Maybe<&2, StFld>) -> Maybe<&2, StPair>:
  match m:
    case Some{StFld{t, e}}:
      Some{StPair{id, t}}
    case None{}:
      None{}

def st.rd.pair.text(id: List<&2, U32>, x: StRd & Maybe<&2, StFld>) -> IO(StRd & Maybe<&2, StPair>):
  (r, m) = x
  IO.pure(StRd & Maybe<&2, StPair>, (r, st.pair.of(id, m)))

def st.rd.pair.id(r: StRd, m: Maybe<&2, StFld>) -> IO(StRd & Maybe<&2, StPair>):
  match m:
    case Some{StFld{i, True{}}}:
      IO.bind(StRd & Maybe<&2, StFld>, StRd & Maybe<&2, StPair>, st.rd.next(r), st.rd.pair.text(i))
    case _:
      IO.pure(StRd & Maybe<&2, StPair>, (r, None{}))

def st.rd.pair.got(x: StRd & Maybe<&2, StFld>) -> IO(StRd & Maybe<&2, StPair>):
  (r, m) = x
  st.rd.pair.id(r, m)

# the next (id, text) record of a NUL file as Python read them:
# `x = data.split(b"\0"); for i in range(0, len(x) - 1, 2): x[i], x[i + 1]`
def st.rd.pair(r: StRd) -> IO(StRd & Maybe<&2, StPair>):
  IO.bind(StRd & Maybe<&2, StFld>, StRd & Maybe<&2, StPair>, st.rd.next(r), x => st.rd.pair.got(x))

# the first line of a file (as text mode reads it: up to "\n" or "\r")
def st.first.of(m: Maybe<&2, StFld>) -> List<&2, U32>:
  match m:
    case Some{StFld{x, e}}:
      L.v2.before(x, 13)
    case None{}:
      Nil{}

def st.first.fin(x: StRd & Maybe<&2, StFld>) -> IO(List<&2, U32>):
  (r, m) = x
  do IO<List<&2, U32>>:
    st.rd.close(r)
    return st.first.of(m)

def st.first.line(path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    r : StRd <- st.rd.open(path, 10)
    x : StRd & Maybe<&2, StFld> <- st.rd.next(r)
    st.first.fin(x)

# a whole file (the tool stops when it cannot be read)
def st.read.got(+path: String, m: Maybe<&2, List<&2, U32>>) -> IO(List<&2, U32>):
  match m:
    case Some{xs}:
      IO.pure(List<&2, U32>, xs)
    case None{}:
      IO.die(List<&2, U32>, 1, "steps: cannot read " ++ path)

def st.read(+path: String) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(path)
    st.read.got(path, m)

# credit --------------------------------------------------------------------------
#
# `print(json.loads(text, strict=False)['credit'])`: the vast CLI writes its
# JSON with Python's json.dumps, so the number's text is Python's repr of it
# and is printed as it stands.  The JSON is cut into tokens; the last
# "credit" member of the top-level object is the one json.loads keeps.

type StTk is Data:
  StTkS{raw: List<&2, U32>}
  StTkP{c: U32}
  StTkV{raw: List<&2, U32>}

# 0: the end, 1: a closing quote, 2: a backslash, 3: any other byte (or one
# a backslash escapes)
def st.js.code(+xs: List<&2, U32>, esc: Bool) -> Nat:
  match xs esc:
    case Nil{} _:
      0n
    case h <> t True{}:
      3n
    case +h <> t False{}:
      Bool.pick(Nat, U32.is_eq(h, 34), 1n, Bool.pick(Nat, U32.is_eq(h, 92), 2n, 3n))

# a string literal's body (xs after its opening quote) and what follows it
def st.js.str(xs: List<&2, U32>, code: Nat) -> StJs:
  match xs code:
    case h <> +t 2n:
      st.js.put(h, st.js.str(t, st.js.code(t, True{})))
    case h <> +t 3n:
      st.js.put(h, st.js.str(t, st.js.code(t, False{})))
    case h <> t 1n:
      StJs{Nil{}, t}
    case _ _:
      StJs{Nil{}, Nil{}}

def st.js.stop(+c: U32) -> Bool:
  Bool.or(Bool.or(J.ws(c), U32.is_eq(c, 34)), Bool.or(Bool.or(Bool.or(U32.is_eq(c, 123), U32.is_eq(c, 125)), Bool.or(U32.is_eq(c, 91), U32.is_eq(c, 93))),
    Bool.or(U32.is_eq(c, 58), U32.is_eq(c, 44))))

def st.js.stop.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> t:
      st.js.stop(h)

def st.js.scalar(xs: List<&2, U32>, stop: Bool) -> StJs:
  match xs stop:
    case h <> +t False{}:
      st.js.put(h, st.js.scalar(t, st.js.stop.head(t)))
    case r _:
      StJs{Nil{}, r}

# 0: the end, 1: whitespace, 2: a string, 3: punctuation, 4: a number or word
def st.js.kind(+xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +h <> t:
      Bool.pick(Nat, J.ws(h), 1n, Bool.pick(Nat, U32.is_eq(h, 34), 2n, Bool.pick(Nat, st.js.stop(h), 3n, 4n)))

def st.js.toks(fuel: Nat, xs: List<&2, U32>, kind: Nat) -> List<&2, StTk>:
  match fuel xs kind:
    case 1n+f h <> +t 1n:
      st.js.toks(f, t, st.js.kind(t))
    case 1n+f h <> +t 2n:
      +p = st.js.str(t, st.js.code(t, False{}))
      +r = st.js.rest(p)
      StTkS{st.js.tok(p)} <> st.js.toks(f, r, st.js.kind(r))
    case 1n+f h <> +t 3n:
      StTkP{h} <> st.js.toks(f, t, st.js.kind(t))
    case 1n+f +h <> +t 4n:
      +p = st.js.scalar(h <> t, False{})
      +r = st.js.rest(p)
      StTkV{st.js.tok(p)} <> st.js.toks(f, r, st.js.kind(r))
    case _ _ _:
      Nil{}

def st.js.is.credit.m(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{s}:
      S.eq(s, [99, 114, 101, 100, 105, 116])
    case None{}:
      False{}

def st.js.is.credit(+k: List<&2, U32>) -> Bool:
  st.js.is.credit.m(J.string(L.v2.concat([[34], k, [34]])))

# the value after a key, when it is a string or a scalar: `: VALUE`
def st.js.val(ts: List<&2, StTk>) -> Maybe<&2, StTk>:
  match ts:
    case StTkP{+c} <> StTkV{v} <> more:
      Bool.pick(Maybe<&2, StTk>, U32.is_eq(c, 58), Some{StTkV{v}}, None{})
    case StTkP{+c} <> StTkS{v} <> more:
      Bool.pick(Maybe<&2, StTk>, U32.is_eq(c, 58), Some{StTkS{v}}, None{})
    case _:
      None{}

def st.js.depth(+c: U32, +d: Nat) -> Nat:
  Bool.pick(Nat, Bool.or(U32.is_eq(c, 123), U32.is_eq(c, 91)), 1n+d,
    Bool.pick(Nat, Bool.or(U32.is_eq(c, 125), U32.is_eq(c, 93)), Nat.sub(d, 1n), d))

def st.js.keep(hit: Bool, m: Maybe<&2, StTk>, found: Maybe<&2, StTk>) -> Maybe<&2, StTk>:
  match hit m:
    case True{} Some{v}:
      Some{v}
    case _ _:
      found

def st.js.walk(ts: List<&2, StTk>, +depth: Nat, found: Maybe<&2, StTk>) -> Maybe<&2, StTk>:
  match ts:
    case Nil{}:
      found
    case StTkS{+k} <> +rest:
      st.js.walk(rest, depth, st.js.keep(Bool.and(Nat.is_eq(depth, 1n), st.js.is.credit(k)), st.js.val(rest), found))
    case StTkP{+c} <> rest:
      st.js.walk(rest, st.js.depth(c, depth), found)
    case StTkV{v} <> rest:
      st.js.walk(rest, depth, found)

def st.credit.num.ok(t: List<&2, U32>, r: Maybe<&2, StF>) -> Maybe<&2, List<&2, U32>>:
  match r:
    case Some{x}:
      Some{t}
    case None{}:
      None{}

# what print() shows of the value: a number as its text (json.dumps wrote
# Python's repr), a string's text, True, False, None
def st.credit.num(m: Maybe<&2, StTk>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case Some{StTkV{+t}}:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(t, S.b("true")), Some{S.b("True")},
        Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(t, S.b("false")), Some{S.b("False")},
          Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(t, S.b("null")), Some{S.b("None")}, st.credit.num.ok(t, st.f.read(t)))))
    case Some{StTkS{+t}}:
      J.string(L.v2.concat([[34], t, [34]]))
    case _:
      None{}

# the credit's number, as its text
def st.credit.tok(+json: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  st.credit.num(st.js.walk(st.js.toks(1n+S.len(json), json, st.js.kind(json)), 0n, None{}))

def st.credit.exit(below: Bool) -> IO(Unit):
  match below:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "credit: not under the minimum")

def st.credit.cmp(c: Maybe<&2, StF>, m: Maybe<&2, StF>) -> IO(Unit):
  match c m:
    case Some{+a} Some{+b}:
      st.credit.exit(Cmp.is_lt(st.f.cmp(a, b)))
    case _ _:
      IO.die(Unit, 2, "credit: MIN is not a number")

def st.credit.got(m: Maybe<&2, List<&2, U32>>, xs: List<String>) -> IO(Unit):
  match m xs:
    case None{} _:
      IO.die(Unit, 2, "credit: no top-level credit in the input")
    case Some{+tok} Nil{}:
      IO.print(S.str(tok))
    case Some{+tok} mn <> Nil{}:
      do IO<Unit>:
        IO.print(S.str(tok))
        st.credit.cmp(st.f.read(tok), st.f.read(S.b(mn)))
    case _ _:
      st.usage("credit [MIN] < vastai-user.json")

def st.credit(xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    j : List<&2, U32> <- S.read("/dev/stdin")
    st.credit.got(st.credit.tok(j), xs)

# credit-ok -------------------------------------------------------------------------
#
# raw-driver.sh's guard: the steps left on the box (CUR's step=I/N), the
# stages after CUR's in STAGES (each its plan's steps, 2200 when it has
# none) and ADD, at SECS_PER_STEP seconds a step (2.16) and DPH dollars an
# hour (0.494), plus END_COST (0.6) and MARGIN (1.0), against CREDIT.

def st.stage.skip(+ws: List<&2, List<&2, U32>>) -> Bool:
  match ws:
    case Nil{}:
      True{}
    case +w <> t:
      S.head.is(w, 35)

def st.stage.keep.if(skip: Bool, ws: List<&2, List<&2, U32>>, rest: List<&2, List<&2, List<&2, U32>>>) -> List<&2, List<&2, List<&2, U32>>>:
  match skip:
    case True{}:
      rest
    case False{}:
      ws <> rest

# the words of every line that is not blank or a comment
def st.stage.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      +ws = st.words(l)
      st.stage.keep.if(st.stage.skip(ws), ws, st.stage.lines(more))

def st.word0.is(+ws: List<&2, List<&2, U32>>, +name: List<&2, U32>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      S.eq(w, name)

def st.first.is(+ls: List<&2, List<&2, List<&2, U32>>>, +name: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +ws <> t:
      st.word0.is(ws, name)

# the lines after the first whose first word is name (none when no line is)
def st.after.go(ls: List<&2, List<&2, List<&2, U32>>>, +name: List<&2, U32>, at: Bool) -> List<&2, List<&2, List<&2, U32>>>:
  match ls at:
    case ws <> more True{}:
      more
    case ws <> +more False{}:
      st.after.go(more, name, st.first.is(more, name))
    case Nil{} _:
      Nil{}

# os.path.join(a, b)
def st.path.join(+a: List<&2, U32>, +b: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.head.is(b, 47), b,
    Bool.pick(List<&2, U32>, Bool.or(Nat.is_eq(S.len(a), 0n), S.suffix(a, [47])), S.append(a, b), L.v2.concat([a, [47], b])))

def st.ck.plan.n(m: Maybe<&2, StI>, +p: String) -> IO(StI):
  match m:
    case Some{n}:
      IO.pure(StI, n)
    case None{}:
      IO.die(StI, 1, "credit-ok: " ++ p ++ "'s first line has no step count third")

def st.ck.plan.read(+p: String, ex: Bool) -> IO(StI):
  match ex:
    case False{}:
      IO.pure(StI, st.i.of(2200n))
    case True{}:
      do IO<StI>:
        l : List<&2, U32> <- st.first.line(p)
        st.ck.plan.n(st.int.m(st.nth(st.words(l), 2n)), p)

def st.ck.plan(+p: String, has: Bool) -> IO(StI):
  match has:
    case False{}:
      IO.pure(StI, st.i.of(2200n))
    case True{}:
      do IO<StI>:
        ex : Bool <- S.exists(p)
        st.ck.plan.read(p, ex)

def st.ck.plan.path(ws: List<&2, List<&2, U32>>) -> String:
  match ws:
    case a <> b <> c <> d <> e <> more:
      S.str(st.path.join(e, S.b("plan-fp100m-b16-windows.tsv")))
    case _:
      ""

# a stage line's steps
def st.ck.steps(+ws: List<&2, List<&2, U32>>) -> IO(StI):
  st.ck.plan(st.ck.plan.path(ws), Nat.is_lt(4n, List.length(&2, List<&2, U32>, ws)))

def st.ck.left(ls: List<&2, List<&2, List<&2, U32>>>, acc: StI) -> IO(StI):
  match ls:
    case Nil{}:
      IO.pure(StI, acc)
    case ws <> more:
      do IO<StI>:
        k : StI <- st.ck.steps(ws)
        st.ck.left(more, st.i.add(acc, k))

def st.ck.exit(ok: Bool, msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.print_err(msg)
    case False{}:
      IO.die(Unit, 1, msg)

def st.ck.fin(+credit: StF, +left: StI, +name: List<&2, U32>, +add: StI, +spd: StF, +dph: StF, +end: StF, +mar: StF) -> IO(Unit):
  +need = st.f.add(st.f.add(st.f.mul(st.f.div(st.f.mul(st.f.of.i(st.i.add(left, add)), spd), st.f.of.nat(3600n)), dph), end), mar)
  st.ck.exit(Cmp.is_ge(st.f.cmp(credit, need)),
    "credit $" ++ st.f.fixed(credit, 2n) ++ "; queued " ++ st.i.show(left) ++ " steps after " ++ S.str(name) ++ " + " ++ st.i.show(add) ++ " = $" ++ st.f.fixed(need, 2n) ++ " with the end and margin")

def st.ck.env(+credit: StF, +left: StI, +name: List<&2, U32>, +add: StI, a: Maybe<&2, StF>, b: Maybe<&2, StF>, c: Maybe<&2, StF>, d: Maybe<&2, StF>) -> IO(Unit):
  match a b c d:
    case Some{spd} Some{dph} Some{end} Some{mar}:
      st.ck.fin(credit, left, name, add, spd, dph, end, mar)
    case _ _ _ _:
      IO.die(Unit, 1, "credit-ok: SECS_PER_STEP, DPH, END_COST and MARGIN must be numbers")

def st.env.f(+name: String, +d: String) -> IO(Maybe<&2, StF>):
  do IO<Maybe<&2, StF>>:
    s : String <- S.env(name, d)
    return st.f.read(S.b(s))

def st.ck.run(+credit: StF, +left0: StI, +name: List<&2, U32>, +add: StI, after: List<&2, List<&2, List<&2, U32>>>) -> IO(Unit):
  do IO<Unit>:
    left : StI <- st.ck.left(after, left0)
    a : Maybe<&2, StF> <- st.env.f("SECS_PER_STEP", "2.16")
    b : Maybe<&2, StF> <- st.env.f("DPH", "0.494")
    c : Maybe<&2, StF> <- st.env.f("END_COST", "0.6")
    d : Maybe<&2, StF> <- st.env.f("MARGIN", "1.0")
    st.ck.env(credit, left, name, add, a, b, c, d)

def st.ck.after0(+ls: List<&2, List<&2, List<&2, U32>>>, +name: List<&2, U32>) -> List<&2, List<&2, List<&2, U32>>>:
  st.after.go(ls, name, st.first.is(ls, name))

def st.ck.stages(+credit: StF, +left0: StI, +name: List<&2, U32>, +add: StI, +stages: String) -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> <- st.read(stages)
    st.ck.run(credit, left0, name, add, st.ck.after0(st.stage.lines(S.split(st.cr(xs), 10)), name))

# int(pos[1]) - int(pos[0]) of CUR's second word's `=I/N`
def st.ck.left3(a: Maybe<&2, StI>, b: Maybe<&2, StI>) -> Maybe<&2, StI>:
  match a b:
    case Some{x} Some{y}:
      Some{st.i.sub(y, x)}
    case _ _:
      None{}

def st.ck.left2(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, StI>:
  match m:
    case None{}:
      None{}
    case Some{v}:
      +pos = st.psplit(v, 47)
      st.ck.left3(st.int.m(st.nth(pos, 0n)), st.int.m(st.nth(pos, 1n)))

def st.ck.left1(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, StI>:
  match m:
    case None{}:
      None{}
    case Some{w}:
      st.ck.left2(st.nth(st.psplit(w, 61), 1n))

def st.ck.cur(+credit: StF, +add: StI, +stages: String, n: Maybe<&2, List<&2, U32>>, l: Maybe<&2, StI>) -> IO(Unit):
  match n l:
    case Some{name} Some{left}:
      st.ck.stages(credit, left, name, add, stages)
    case _ _:
      IO.die(Unit, 1, "credit-ok: CUR is not `NAME step=I/N`")

def st.ck.args(+stages: String, c: Maybe<&2, StF>, +cur: List<&2, List<&2, U32>>, a: Maybe<&2, StI>) -> IO(Unit):
  match c a:
    case Some{credit} Some{add}:
      st.ck.cur(credit, add, stages, st.nth(cur, 0n), st.ck.left1(st.nth(cur, 1n)))
    case _ _:
      IO.die(Unit, 1, "credit-ok: CREDIT is not a number or ADD not an integer")

def st.credit.ok(xs: List<String>) -> IO(Unit):
  match xs:
    case stages <> credit <> cur <> add <> Nil{}:
      st.ck.args(stages, st.f.read(S.b(credit)), st.words(S.b(cur)), st.int.read(S.b(add)))
    case _:
      st.usage("credit-ok STAGES CREDIT CUR ADD")

# nul-jsonl ------------------------------------------------------------------------
#
# raw-stage.sh's transcripts as JSONL: every (id, text) record as
# `json.dumps({"id": id.decode("utf-8", "replace"), "text": ...},
# ensure_ascii=False)` and a newline.

type StNj is Type:
  StNj{r: StRd, o: File, more: Bool}

def st.nj.rec(r: StRd, o: File, m: Maybe<&2, StPair>) -> IO(StNj):
  match m:
    case Some{StPair{i, t}}:
      do IO<StNj>:
        o2 : File <- S.emit(o, L.v2.py.line(st.u8.fix(i), st.u8.fix(t)))
        return StNj{r, o2, True{}}
    case None{}:
      IO.pure(StNj, StNj{r, o, False{}})

def st.nj.got(o: File, x: StRd & Maybe<&2, StPair>) -> IO(StNj):
  (r, m) = x
  st.nj.rec(r, o, m)

def st.nj.step(s: StNj) -> IO(StNj):
  match s:
    case StNj{r, o, m}:
      IO.bind(StRd & Maybe<&2, StPair>, StNj, st.rd.pair(r), st.nj.got(o))

def st.nj.go(fuel: Nat, s: StNj) -> IO(StNj):
  match fuel s:
    case 1n+f StNj{r, o, True{}}:
      IO.bind(StNj, StNj, st.nj.step(StNj{r, o, True{}}), st.nj.go(f))
    case _ s2:
      IO.pure(StNj, s2)

def st.nj.fin(s: StNj) -> IO(Unit):
  match s:
    case StNj{r, o, m}:
      do IO<Unit>:
        st.rd.close(r)
        File.close(o)

def st.nul.jsonl.run(src: String, dst: String) -> IO(Unit):
  do IO<Unit>:
    r : StRd <- st.rd.open(src, 0)
    o : File <- st.open(dst, "w")
    s : StNj <- st.nj.go(st.fuel(), StNj{r, o, True{}})
    st.nj.fin(s)

def st.nul.jsonl(xs: List<String>) -> IO(Unit):
  match xs:
    case src <> dst <> Nil{}:
      st.nul.jsonl.run(src, dst)
    case _:
      st.usage("nul-jsonl SRC.nul DST.jsonl")

# split-lang -------------------------------------------------------------------------
#
# raw-stage.sh mix's split: every line of SRC (JSON lines, the id first) to
# OUT/LANG.jsonl by its id's extension (hs lhs: haskell, lean, agda lagda:
# agda, nix, bend; any other: none), verbatim; then the counts.  The id is
# what Python cut: `i = line.find(b'"id":"'); line[i + 6:line.find(b'"', i + 6)]`.

def st.sl.code(+ext: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.or(S.eq(ext, [104, 115]), S.eq(ext, [108, 104, 115])), 1n,
    Bool.pick(Nat, S.eq(ext, [108, 101, 97, 110]), 2n,
      Bool.pick(Nat, Bool.or(S.eq(ext, [97, 103, 100, 97]), S.eq(ext, [108, 97, 103, 100, 97])), 3n,
        Bool.pick(Nat, S.eq(ext, [110, 105, 120]), 4n,
          Bool.pick(Nat, S.eq(ext, [98, 101, 110, 100]), 5n, 0n)))))

def st.sl.ext(+line: List<&2, U32>) -> List<&2, U32>:
  +a = st.at.or(st.find(line, [34, 105, 100, 34, 58, 34], 0n), 6n, 5n)
  +name = st.after.last(st.slice(line, a, st.find(line, [34], a)), 47)
  Bool.pick(List<&2, U32>, L.v2.has(name, 46), st.after.last(name, 46), Nil{})

type StO5 is Type:
  StO5{f1: File, f2: File, f3: File, f4: File, f5: File, n1: Nat, n2: Nat, n3: Nat, n4: Nat, n5: Nat}

def st.o5.put(code: Nat, line: List<&2, U32>, o: StO5) -> IO(StO5):
  match code o:
    case 1n StO5{f1, f2, f3, f4, f5, n1, n2, n3, n4, n5}:
      do IO<StO5>:
        g : File <- S.emit(f1, line)
        return StO5{g, f2, f3, f4, f5, 1n+n1, n2, n3, n4, n5}
    case 2n StO5{f1, f2, f3, f4, f5, n1, n2, n3, n4, n5}:
      do IO<StO5>:
        g : File <- S.emit(f2, line)
        return StO5{f1, g, f3, f4, f5, n1, 1n+n2, n3, n4, n5}
    case 3n StO5{f1, f2, f3, f4, f5, n1, n2, n3, n4, n5}:
      do IO<StO5>:
        g : File <- S.emit(f3, line)
        return StO5{f1, f2, g, f4, f5, n1, n2, 1n+n3, n4, n5}
    case 4n StO5{f1, f2, f3, f4, f5, n1, n2, n3, n4, n5}:
      do IO<StO5>:
        g : File <- S.emit(f4, line)
        return StO5{f1, f2, f3, g, f5, n1, n2, n3, 1n+n4, n5}
    case 5n StO5{f1, f2, f3, f4, f5, n1, n2, n3, n4, n5}:
      do IO<StO5>:
        g : File <- S.emit(f5, line)
        return StO5{f1, f2, f3, f4, g, n1, n2, n3, n4, 1n+n5}
    case _ o2:
      IO.pure(StO5, o2)

type StSl is Type:
  StSl{r: StRd, o: StO5, more: Bool}

def st.sl.rec(r: StRd, o: StO5, m: Maybe<&2, List<&2, U32>>) -> IO(StSl):
  match m:
    case None{}:
      IO.pure(StSl, StSl{r, o, False{}})
    case Some{+line}:
      do IO<StSl>:
        o2 : StO5 <- st.o5.put(st.sl.code(st.sl.ext(line)), line, o)
        return StSl{r, o2, True{}}

def st.sl.got(o: StO5, x: StRd & Maybe<&2, List<&2, U32>>) -> IO(StSl):
  (r, m) = x
  st.sl.rec(r, o, m)

def st.sl.step(s: StSl) -> IO(StSl):
  match s:
    case StSl{r, o, m}:
      IO.bind(StRd & Maybe<&2, List<&2, U32>>, StSl, st.rd.line(r), st.sl.got(o))

def st.sl.go(fuel: Nat, s: StSl) -> IO(StSl):
  match fuel s:
    case 1n+f StSl{r, o, True{}}:
      IO.bind(StSl, StSl, st.sl.step(StSl{r, o, True{}}), st.sl.go(f))
    case _ s2:
      IO.pure(StSl, s2)

def st.sl.fin(s: StSl) -> IO(Unit):
  match s:
    case StSl{r, StO5{f1, f2, f3, f4, f5, n1, n2, n3, n4, n5}, m}:
      do IO<Unit>:
        st.rd.close(r)
        File.close(f1)
        File.close(f2)
        File.close(f3)
        File.close(f4)
        File.close(f5)
        IO.print("{'haskell': " ++ Nat.show(n1) ++ ", 'lean': " ++ Nat.show(n2) ++ ", 'agda': " ++ Nat.show(n3) ++ ", 'nix': " ++ Nat.show(n4) ++ ", 'bend': " ++ Nat.show(n5) ++ "}")

def st.split.lang.run(src: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    f1 : File <- st.open(out ++ "/haskell.jsonl", "w")
    f2 : File <- st.open(out ++ "/lean.jsonl", "w")
    f3 : File <- st.open(out ++ "/agda.jsonl", "w")
    f4 : File <- st.open(out ++ "/nix.jsonl", "w")
    f5 : File <- st.open(out ++ "/bend.jsonl", "w")
    r : StRd <- st.rd.open(src, 10)
    s : StSl <- st.sl.go(st.fuel(), StSl{r, StO5{f1, f2, f3, f4, f5, 0n, 0n, 0n, 0n, 0n}, True{}})
    st.sl.fin(s)

def st.split.lang(xs: List<String>) -> IO(Unit):
  match xs:
    case src <> out <> Nil{}:
      st.split.lang.run(src, out)
    case _:
      st.usage("split-lang SRC.jsonl OUTDIR")

# per --------------------------------------------------------------------------------

def st.per.of(+n: Nat, +top: Nat) -> Nat:
  Nat.max(1n, st.f.rint(st.f.ratio(Nat.mul(100n, n), top)))

def st.per.zero(+n: Nat, +top: Nat, z: Bool) -> IO(Unit):
  match z:
    case True{}:
      IO.die(Unit, 1, "per: division by zero")
    case False{}:
      IO.print(Nat.show(st.per.of(n, top)))

def st.per.go(a: Maybe<&2, StI>, b: Maybe<&2, StI>) -> IO(Unit):
  match a b:
    case Some{StI{False{}, +n}} Some{StI{False{}, +top}}:
      st.per.zero(n, top, Nat.is_eq(top, 0n))
    case _ _:
      IO.die(Unit, 1, "per: N and TOP must be counts")

# raw-stage.sh's per(): max(1, round(100 * N / TOP))
def st.per(xs: List<String>) -> IO(Unit):
  match xs:
    case n <> top <> Nil{}:
      st.per.go(st.int.read(S.b(n)), st.int.read(S.b(top)))
    case _:
      st.usage("per N TOP")

# Replay weights ---------------------------------------------------------------------
#
# fp100m's languages' transcripts (haskell 79,075, lean 50,079, agda 53,663,
# nix 24,694, bend 126,763), the replay in their proportions.

type StW is Data:
  StW{l: List<&2, U32>, w: Nat}

def st.w.all() -> List<&2, StW>:
  [StW{S.b("haskell"), 79075n}, StW{S.b("lean"), 50079n}, StW{S.b("agda"), 53663n}, StW{S.b("nix"), 24694n}, StW{S.b("bend"), 126763n}]

def st.w.total(ws: List<&2, StW>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case StW{l, v} <> more:
      Nat.add(v, st.w.total(more))

# sum(w.values())
def st.w.sum() -> Nat:
  st.w.total(st.w.all())

# `max(1, round(r * v / sum(w.values())))` for each language: PRE + l + POST:p:cycle
def st.w.specs(ws: List<&2, StW>, +r: StF, +pre: List<&2, U32>, +post: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case StW{l, v} <> more:
      +p = Nat.max(1n, st.f.rint(st.f.div(st.f.mul(r, st.f.of.nat(v)), st.f.of.nat(st.w.sum()))))
      L.v2.concat([pre, l, post, [58], S.b(Nat.show(p)), S.b(":cycle")]) <> st.w.specs(more, r, pre, post)

# specs-next -------------------------------------------------------------------------
#
# next-stage.sh's per-round specs: the new languages (LABEL:COUNT) in their
# counts' ratio, 20 a round in all, and REPLAY times as many replayed.

type StLc is Data:
  StLc{l: List<&2, U32>, c: StI}

def st.lc.of(+a: List<&2, U32>, ok: Bool, m: Maybe<&2, StI>) -> Maybe<&2, StLc>:
  match ok m:
    case True{} Some{c}:
      Some{StLc{List.reverse(&2, U32, L.v2.after(List.reverse(&2, U32, a), 58)), c}}
    case _ _:
      None{}

# a.rsplit(":", 1): the label and int(count)
def st.lc.parse(+a: List<&2, U32>) -> Maybe<&2, StLc>:
  st.lc.of(a, L.v2.has(a, 58), st.int.read(st.after.last(a, 58)))

def st.lcs.put(m: Maybe<&2, StLc>, rest: Maybe<&2, List<&2, StLc>>) -> Maybe<&2, List<&2, StLc>>:
  match m rest:
    case Some{x} Some{xs}:
      Some{x <> xs}
    case _ _:
      None{}

def st.lcs(xs: List<&2, String>) -> Maybe<&2, List<&2, StLc>>:
  match xs:
    case Nil{}:
      Some{Nil{}}
    case x <> more:
      st.lcs.put(st.lc.parse(S.b(x)), st.lcs(more))

def st.lcs.total(cs: List<&2, StLc>) -> StI:
  match cs:
    case Nil{}:
      st.i.of(0n)
    case StLc{l, c} <> more:
      st.i.add(c, st.lcs.total(more))

def st.sn.new.put(+p: Nat, +l: List<&2, U32>, keep: Bool, rest: List<&2, StLc>) -> List<&2, StLc>:
  match keep:
    case True{}:
      StLc{l, st.i.of(p)} <> rest
    case False{}:
      rest

# (l, max(1, round(20 * c / tot))) for every c > 0 (a negative tot makes
# every share negative, so 1)
def st.sn.share(+c: Nat, +tot: StI) -> Nat:
  match tot:
    case StI{True{}, m}:
      1n
    case StI{False{}, +m}:
      Nat.max(1n, st.f.rint(st.f.ratio(Nat.mul(20n, c), Bool.pick(Nat, Nat.is_eq(m, 0n), 1n, m))))

def st.sn.new(cs: List<&2, StLc>, +tot: StI) -> List<&2, StLc>:
  match cs:
    case Nil{}:
      Nil{}
    case StLc{+l, StI{+n, +c}} <> more:
      st.sn.new.put(st.sn.share(c, tot), l, Bool.and(Bool.not(n), Nat.is_lt(0n, c)), st.sn.new(more, tot))

def st.lc.specs(cs: List<&2, StLc>) -> List<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      Nil{}
    case StLc{l, c} <> more:
      L.v2.concat([l, [58], S.b(st.i.show(c))]) <> st.lc.specs(more)

def st.sn.specs(+rep: StF, +cs: List<&2, StLc>) -> String:
  +new = st.sn.new(cs, st.lcs.total(cs))
  +r = st.f.mul(rep, st.f.of.i(st.lcs.total(new)))
  S.str(S.join(List.append(&2, List<&2, U32>, st.lc.specs(new), st.w.specs(st.w.all(), r, Nil{}, Nil{})), 32))

def st.sn.go(r: Maybe<&2, StF>, cs: Maybe<&2, List<&2, StLc>>) -> IO(Unit):
  match r cs:
    case Some{+rep} Some{c}:
      IO.print(st.sn.specs(rep, c))
    case _ _:
      IO.die(Unit, 1, "specs-next: REPLAY must be a number and each spec LABEL:COUNT")

def st.specs.next(xs: List<String>) -> IO(Unit):
  match xs:
    case rep <> cs:
      st.sn.go(st.f.read(S.b(rep)), st.lcs(st.strs(cs)))
    case _:
      st.usage("specs-next REPLAY LABEL:COUNT...")

# specs-mixnew -----------------------------------------------------------------------
#
# raw-stage.sh mixnew: the files grouped by language (a file's name up to its
# first `-` or `.`, in the order they first appear), each language's lines
# and bytes counted, OUT/LANG.jsonl made (a link to the absolute path of a
# lone file, else the files one after another), then per round documents in
# proportion to the languages' counts (the largest 100), and fp100m's
# transcripts cycling at about 20% of the bytes.  The specs on stdout, the
# counts (lines, MB to one place) on stderr, as Python wrote them.

type StGrp is Data:
  StGrp{l: List<&2, U32>, fs: List<&2, String>}

def st.sm.lang(+f: String) -> List<&2, U32>:
  L.v2.before(L.v2.before(st.after.last(S.b(f), 47), 45), 46)

def st.grp.is(+gs: List<&2, StGrp>, +l: List<&2, U32>) -> Bool:
  match gs:
    case Nil{}:
      False{}
    case StGrp{+k, fs} <> more:
      S.eq(k, l)

def st.sm.add(gs: List<&2, StGrp>, +l: List<&2, U32>, +f: String, at: Bool) -> List<&2, StGrp>:
  match gs at:
    case StGrp{k, fs} <> more True{}:
      StGrp{k, List.append(&2, String, fs, [f])} <> more
    case g <> +more False{}:
      g <> st.sm.add(more, l, f, st.grp.is(more, l))
    case Nil{} _:
      [StGrp{l, [f]}]

def st.sm.group(fs: List<&2, String>, +gs: List<&2, StGrp>) -> List<&2, StGrp>:
  match fs:
    case Nil{}:
      gs
    case +f <> more:
      +l = st.sm.lang(f)
      st.sm.group(more, st.sm.add(gs, l, f, st.grp.is(gs, l)))

# a file's lines (Python's `for line in open(f, "rb")`) and bytes
type StNb is Data:
  StNb{n: Nat, b: Nat}

type StC3 is Data:
  StC3{nl: Nat, len: Nat, last: U32}

def st.cnt.go(xs: List<&2, U32>, nl: Nat, len: Nat, last: U32) -> StC3:
  match xs:
    case Nil{}:
      StC3{nl, len, last}
    case +h <> t:
      st.cnt.go(t, Nat.add(nl, st.b2n(U32.is_eq(h, 10))), 1n+len, h)

type StCnt is Type:
  StCnt{f: File, nl: Nat, b: Nat, last: U32, more: Bool}

def st.cnt.add(f: File, +nl: Nat, +b: Nat, c: StC3) -> StCnt:
  match c:
    case StC3{n, +k, l}:
      StCnt{f, Nat.add(nl, n), Nat.add(b, k), l, Nat.is_ne(k, 0n)}

def st.cnt.got(nl: Nat, b: Nat, last: U32, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(StCnt):
  (f, x) = r
  do IO<StCnt>:
    xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return st.cnt.add(f, nl, b, st.cnt.go(xs, 0n, 0n, last))

def st.cnt.step(s: StCnt) -> IO(StCnt):
  match s:
    case StCnt{f, nl, b, last, m}:
      do IO<StCnt>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, S.chunk())
        st.cnt.got(nl, b, last, r)

def st.cnt.loop(fuel: Nat, s: StCnt) -> IO(StCnt):
  match fuel s:
    case 1n+p StCnt{f, nl, b, last, True{}}:
      IO.bind(StCnt, StCnt, st.cnt.step(StCnt{f, nl, b, last, True{}}), st.cnt.loop(p))
    case _ s2:
      IO.pure(StCnt, s2)

def st.cnt.fin(s: StCnt) -> IO(StNb):
  match s:
    case StCnt{f, nl, +b, last, m}:
      do IO<StNb>:
        File.close(f)
        return StNb{Nat.add(nl, st.b2n(Bool.and(Nat.is_ne(b, 0n), U32.is_ne(last, 10)))), b}

def st.cnt.file(path: String) -> IO(StNb):
  do IO<StNb>:
    f : File <- st.open(path, "r")
    s : StCnt <- st.cnt.loop(st.fuel(), StCnt{f, 0n, 0n, 10, True{}})
    st.cnt.fin(s)

def st.nb.add(a: StNb, b: StNb) -> StNb:
  match a b:
    case StNb{n, x} StNb{m, y}:
      StNb{Nat.add(n, m), Nat.add(x, y)}

def st.cnt.files(fs: List<&2, String>, acc: StNb) -> IO(StNb):
  match fs:
    case Nil{}:
      IO.pure(StNb, acc)
    case f <> more:
      do IO<StNb>:
        c : StNb <- st.cnt.file(f)
        st.cnt.files(more, st.nb.add(acc, c))

def st.sm.cat(+c: U32, dst: String) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(c, 0), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "specs-mixnew: could not write " ++ dst))

def st.sm.link(+dst: String, fs: List<&2, String>) -> IO(Unit):
  match fs:
    case +f <> Nil{}:
      do IO<Unit>:
        a : List<&2, U32> <- S.must("realpath " ++ f, "realpath", ["-ms", "--", f])
        o : List<&2, U32> <- S.must("ln " ++ dst, "ln", ["-s", "--", S.str(S.chomp(a)), dst])
        return Unit{}
    case more:
      do IO<Unit>:
        c : U32 <- S.run.log(".", [], 86400, "cat", st.strs.back(more), dst)
        st.sm.cat(c, dst)

# OUT/LANG.jsonl, anew
def st.sm.place(+dst: String, fs: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    o : List<&2, U32> <- S.must("rm " ++ dst, "rm", ["-f", "--", dst])
    st.sm.link(dst, fs)

type StSt is Data:
  StSt{l: List<&2, U32>, n: Nat, b: Nat}

def st.sm.stat(l: List<&2, U32>, c: StNb) -> StSt:
  match c:
    case StNb{n, b}:
      StSt{l, n, b}

def st.sm.stats(gs: List<&2, StGrp>, +out: String) -> IO(List<&2, StSt>):
  match gs:
    case Nil{}:
      IO.pure(List<&2, StSt>, Nil{})
    case StGrp{+l, +fs} <> more:
      do IO<List<&2, StSt>>:
        c : StNb <- st.cnt.files(fs, StNb{0n, 0n})
        st.sm.place(out ++ "/" ++ S.str(l) ++ ".jsonl", fs)
        rest : List<&2, StSt> <- st.sm.stats(more, out)
        return st.sm.stat(l, c) <> rest

def st.sm.top(ss: List<&2, StSt>) -> Nat:
  match ss:
    case Nil{}:
      0n
    case StSt{l, n, b} <> more:
      Nat.max(n, st.sm.top(more))

def st.sm.any.zero(ss: List<&2, StSt>) -> Bool:
  match ss:
    case Nil{}:
      False{}
    case StSt{l, n, b} <> more:
      Bool.or(Nat.is_eq(n, 0n), st.sm.any.zero(more))

def st.sm.per(+n: Nat, +top: Nat) -> Nat:
  Nat.max(1n, st.f.rint(st.f.ratio(Nat.mul(100n, n), top)))

# per[l] * b / n for each language (bytes of code a round)
def st.sm.code(ss: List<&2, StSt>, +top: Nat) -> List<&2, StF>:
  match ss:
    case Nil{}:
      Nil{}
    case StSt{l, +n, b} <> more:
      st.f.ratio(Nat.mul(st.sm.per(n, top), b), n) <> st.sm.code(more, top)

def st.sm.specs(ss: List<&2, StSt>, +top: Nat, +out: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case StSt{l, +n, b} <> more:
      L.v2.concat([out, [47], l, S.b(".jsonl:"), S.b(Nat.show(st.sm.per(n, top)))]) <> st.sm.specs(more, top, out)

def st.sm.counts(ss: List<&2, StSt>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case StSt{l, n, +b} <> more:
      L.v2.concat([[39], l, S.b("': ("), S.b(Nat.show(n)), S.b(", "), S.b(st.f.fixed(st.f.div(st.f.of.nat(b), st.f.of.nat(1000000n)), 1n)), [41]]) <> st.sm.counts(more)

def st.sm.out(+ss: List<&2, StSt>, +out: String) -> IO(Unit):
  +top = st.sm.top(ss)
  +code = st.f.sum(st.sm.code(ss, top))
  +tr = st.f.div(st.f.mul(st.f.ratio(1n, 4n), code), st.f.of.nat(1200n))
  +o = S.b(out)
  do IO<Unit>:
    IO.print(S.str(S.join(List.append(&2, List<&2, U32>, st.sm.specs(ss, top, o), st.w.specs(st.w.all(), tr, S.append(o, S.b("/tr-")), S.b(".jsonl"))), 32)))
    IO.print_err(S.str(L.v2.concat([[123], st.join.with(st.sm.counts(ss), [44, 32]), [125]])))

def st.sm.check(+ss: List<&2, StSt>, +out: String, bad: Bool) -> IO(Unit):
  match bad:
    case True{}:
      IO.die(Unit, 1, "specs-mixnew: division by zero (a language with no lines)")
    case False{}:
      st.sm.out(ss, out)

def st.sm.run(+out: String, gs: List<&2, StGrp>) -> IO(Unit):
  do IO<Unit>:
    +ss : List<&2, StSt> <- st.sm.stats(gs, out)
    st.sm.check(ss, out, Bool.or(Nat.is_eq(List.length(&2, StSt, ss), 0n), st.sm.any.zero(ss)))

def st.specs.mixnew(xs: List<String>) -> IO(Unit):
  match xs:
    case out <> fs:
      st.sm.run(out, st.sm.group(st.strs(fs), Nil{}))
    case _:
      st.usage("specs-mixnew OUTDIR FILE.jsonl...")

# replay-filler -----------------------------------------------------------------------
#
# next-stage.sh's REPLAY_FILLER: SRC/files-hi.nul and files-lo.nul into
# D/files-hi.nul and files-lo.nul less every record whose id a NEW
# directory's files-hi/lo.nul holds (bend-mix refuses a duplicate id).

type StIds is Type:
  StIds{r: StRd, s: Set(), more: Bool}

def st.ids.add(r: StRd, s: Set(), m: Maybe<&2, StPair>) -> StIds:
  match m:
    case Some{StPair{i, t}}:
      StIds{r, Set.add(s, st.key(i)), True{}}
    case None{}:
      StIds{r, s, False{}}

def st.ids.got(s: Set(), x: StRd & Maybe<&2, StPair>) -> IO(StIds):
  (r, m) = x
  IO.pure(StIds, st.ids.add(r, s, m))

def st.ids.step(s: StIds) -> IO(StIds):
  match s:
    case StIds{r, set, m}:
      IO.bind(StRd & Maybe<&2, StPair>, StIds, st.rd.pair(r), st.ids.got(set))

def st.ids.go(fuel: Nat, s: StIds) -> IO(StIds):
  match fuel s:
    case 1n+f StIds{r, set, True{}}:
      IO.bind(StIds, StIds, st.ids.step(StIds{r, set, True{}}), st.ids.go(f))
    case _ s2:
      IO.pure(StIds, s2)

def st.ids.fin(s: StIds) -> IO(Set()):
  match s:
    case StIds{r, set, m}:
      do IO<Set()>:
        st.rd.close(r)
        return set

def st.ids.file(path: String, s: Set(), ex: Bool) -> IO(Set()):
  match ex:
    case False{}:
      IO.pure(Set(), s)
    case True{}:
      do IO<Set()>:
        r : StRd <- st.rd.open(path, 0)
        z : StIds <- st.ids.go(st.fuel(), StIds{r, s, True{}})
        st.ids.fin(z)

def st.ids.of(+path: String, s: Set()) -> IO(Set()):
  do IO<Set()>:
    ex : Bool <- S.exists(path)
    st.ids.file(path, s, ex)

def st.taken(ds: List<&2, String>, s: Set()) -> IO(Set()):
  match ds:
    case Nil{}:
      IO.pure(Set(), s)
    case +d <> more:
      do IO<Set()>:
        s1 : Set() <- st.ids.of(d ++ "/files-hi.nul", s)
        s2 : Set() <- st.ids.of(d ++ "/files-lo.nul", s1)
        st.taken(more, s2)

type StRf is Type:
  StRf{r: StRd, o: File, s: Set(), kept: Nat, more: Bool}

def st.rf.put(r: StRd, o: File, s: Set(), +k: Nat, i: List<&2, U32>, t: List<&2, U32>, has: Bool) -> IO(StRf):
  match has:
    case True{}:
      IO.pure(StRf, StRf{r, o, s, k, True{}})
    case False{}:
      do IO<StRf>:
        o2 : File <- S.emit(o, L.v2.concat([i, [0], t, [0]]))
        return StRf{r, o2, s, 1n+k, True{}}

def st.rf.has(r: StRd, o: File, +k: Nat, +i: List<&2, U32>, t: List<&2, U32>, sh: Set() & Bool) -> IO(StRf):
  (s2, has) = sh
  st.rf.put(r, o, s2, k, i, t, has)

def st.rf.rec(r: StRd, o: File, s: Set(), +k: Nat, m: Maybe<&2, StPair>) -> IO(StRf):
  match m:
    case None{}:
      IO.pure(StRf, StRf{r, o, s, k, False{}})
    case Some{StPair{+i, t}}:
      st.rf.has(r, o, k, i, t, Set.has(s, st.key(i)))

def st.rf.got(o: File, s: Set(), +k: Nat, x: StRd & Maybe<&2, StPair>) -> IO(StRf):
  (r, m) = x
  st.rf.rec(r, o, s, k, m)

def st.rf.step(z: StRf) -> IO(StRf):
  match z:
    case StRf{r, o, s, k, m}:
      IO.bind(StRd & Maybe<&2, StPair>, StRf, st.rd.pair(r), st.rf.got(o, s, k))

def st.rf.go(fuel: Nat, z: StRf) -> IO(StRf):
  match fuel z:
    case 1n+f StRf{r, o, s, k, True{}}:
      IO.bind(StRf, StRf, st.rf.step(StRf{r, o, s, k, True{}}), st.rf.go(f))
    case _ z2:
      IO.pure(StRf, z2)

type StRo is Type:
  StRo{o: File, s: Set(), kept: Nat}

def st.rf.fin(z: StRf) -> IO(StRo):
  match z:
    case StRf{r, o, s, k, m}:
      do IO<StRo>:
        st.rd.close(r)
        return StRo{o, s, k}

def st.rf.run(path: String, o: File, s: Set(), ex: Bool) -> IO(StRo):
  match ex:
    case False{}:
      IO.pure(StRo, StRo{o, s, 0n})
    case True{}:
      do IO<StRo>:
        r : StRd <- st.rd.open(path, 0)
        z : StRf <- st.rf.go(st.fuel(), StRf{r, o, s, 0n, True{}})
        st.rf.fin(z)

def st.rf.done(+d: String, +f: String, z: StRo) -> IO(Set()):
  match z:
    case StRo{o, s, k}:
      do IO<Set()>:
        File.close(o)
        IO.print(d ++ " " ++ f ++ " " ++ Nat.show(k) ++ " files")
        return s

def st.rf.file(+d: String, +src: String, +f: String, s: Set()) -> IO(Set()):
  do IO<Set()>:
    o : File <- st.open(d ++ "/" ++ f, "w")
    ex : Bool <- S.exists(src ++ "/" ++ f)
    z : StRo <- st.rf.run(src ++ "/" ++ f, o, s, ex)
    st.rf.done(d, f, z)

def st.rf.all(+d: String, +src: String, news: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    s : Set() <- st.taken(news, Set.new())
    s1 : Set() <- st.rf.file(d, src, "files-hi.nul", s)
    s2 : Set() <- st.rf.file(d, src, "files-lo.nul", s1)
    return Unit{}

def st.replay.filler(xs: List<String>) -> IO(Unit):
  match xs:
    case d <> src <> news:
      st.rf.all(d, src, st.strs(news))
    case _:
      st.usage("replay-filler DIR SRC NEWDIR...")

# drop-repos ------------------------------------------------------------------------------
#
# restage-ns.sh's: SRC's lines (verbatim) to DST less those whose id's
# repository is in VAULT.tsv's second column (its first line a header); the
# id is what Python cut: `i = line.find(b'"id":'); i = line.find(b'"', i + 5)
# + 1; line[i:line.find(b'"', i)]`, decoded with "replace".

def st.dr.id(+line: List<&2, U32>) -> List<&2, U32>:
  +i = st.at.or(st.find(line, [34], st.at.or(st.find(line, [34, 105, 100, 34, 58], 0n), 5n, 4n)), 1n, 0n)
  st.slice(line, i, st.find(line, [34], i))

def st.dr.vault.add(m: Maybe<&2, List<&2, U32>>, rest: Maybe<&2, Set()>) -> Maybe<&2, Set()>:
  match m rest:
    case Some{r} Some{s}:
      Some{Set.add(s, st.key(r))}
    case _ _:
      None{}

# the second column of each line after the first (None: a line without one)
def st.dr.vault(ls: List<&2, List<&2, U32>>) -> Maybe<&2, Set()>:
  match ls:
    case Nil{}:
      Some{Set.new()}
    case l <> more:
      st.dr.vault.add(st.nth(st.psplit(l, 9), 1n), st.dr.vault(more))

type StDr is Type:
  StDr{r: StRd, o: File, s: Set(), n: Nat, drop: Nat, more: Bool}

def st.dr.put.if(r: StRd, o: File, s: Set(), +n: Nat, +drop: Nat, line: List<&2, U32>, has: Bool) -> IO(StDr):
  match has:
    case True{}:
      IO.pure(StDr, StDr{r, o, s, n, 1n+drop, True{}})
    case False{}:
      do IO<StDr>:
        o2 : File <- S.emit(o, line)
        return StDr{r, o2, s, 1n+n, drop, True{}}

def st.dr.put(r: StRd, o: File, +n: Nat, +drop: Nat, line: List<&2, U32>, sh: Set() & Bool) -> IO(StDr):
  (s, has) = sh
  st.dr.put.if(r, o, s, n, drop, line, has)

def st.dr.rec(r: StRd, o: File, s: Set(), +n: Nat, +drop: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(StDr):
  match m:
    case None{}:
      IO.pure(StDr, StDr{r, o, s, n, drop, False{}})
    case Some{+line}:
      st.dr.put(r, o, n, drop, line, Set.has(s, st.key(L.v2.repo.of(st.u8.fix(st.dr.id(line))))))

def st.dr.got(o: File, s: Set(), +n: Nat, +drop: Nat, x: StRd & Maybe<&2, List<&2, U32>>) -> IO(StDr):
  (r, m) = x
  st.dr.rec(r, o, s, n, drop, m)

def st.dr.step(z: StDr) -> IO(StDr):
  match z:
    case StDr{r, o, s, n, d, m}:
      IO.bind(StRd & Maybe<&2, List<&2, U32>>, StDr, st.rd.line(r), st.dr.got(o, s, n, d))

def st.dr.go(fuel: Nat, z: StDr) -> IO(StDr):
  match fuel z:
    case 1n+f StDr{r, o, s, n, d, True{}}:
      IO.bind(StDr, StDr, st.dr.step(StDr{r, o, s, n, d, True{}}), st.dr.go(f))
    case _ z2:
      IO.pure(StDr, z2)

def st.dr.fin(z: StDr) -> IO(Unit):
  match z:
    case StDr{r, o, s, n, d, m}:
      do IO<Unit>:
        st.rd.close(r)
        File.close(o)
        IO.print("kept " ++ Nat.show(n) ++ " documents, dropped " ++ Nat.show(d) ++ " from the vault")

def st.dr.run(src: String, dst: String, m: Maybe<&2, Set()>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "drop-repos: a vault line without a second column")
    case Some{s}:
      do IO<Unit>:
        r : StRd <- st.rd.open(src, 10)
        o : File <- st.open(dst, "w")
        z : StDr <- st.dr.go(st.fuel(), StDr{r, o, s, 0n, 0n, True{}})
        st.dr.fin(z)

def st.dr.all(+vault: String, src: String, dst: String) -> IO(Unit):
  do IO<Unit>:
    v : List<&2, U32> <- st.read(vault)
    st.dr.run(src, dst, st.dr.vault(List.drop(&2, List<&2, U32>, S.split(st.cr(v), 10), 1n)))

def st.drop.repos(xs: List<String>) -> IO(Unit):
  match xs:
    case vault <> src <> dst <> Nil{}:
      st.dr.all(vault, src, dst)
    case _:
      st.usage("drop-repos VAULT.tsv SRC.jsonl DST.jsonl")

# insert-stage --------------------------------------------------------------------------
#
# bend/gpu/insert-stage.py's: LINE (the arguments joined by spaces) into
# STAGES right after the stage named by the first AFTER (comma-separated)
# that is there, else at the end; never before the stage the chain last
# started (CHAINLOG's last `stage NAME: from`): the chain walks the stages by
# position, so a line behind it would be skipped.  STAGES is read as text
# mode reads it ("\r\n" and "\r" as "\n") and replaced whole.

# the line (of ls, from 0) a stage name is on: the last whose first word is
# a, blank and comment lines aside
def st.pos.hit(ws: List<&2, List<&2, U32>>, +a: List<&2, U32>, +k: Nat, found: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match ws:
    case Nil{}:
      found
    case +w <> t:
      Bool.pick(Maybe<&2, Nat>, Bool.and(Bool.not(S.head.is(w, 35)), S.eq(w, a)), Some{k}, found)

def st.pos.go(ls: List<&2, List<&2, U32>>, +a: List<&2, U32>, +k: Nat, found: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match ls:
    case Nil{}:
      found
    case l <> more:
      st.pos.go(more, a, 1n+k, st.pos.hit(st.words(l), a, k, found))

def st.pos(+ls: List<&2, List<&2, U32>>, +a: List<&2, U32>) -> Maybe<&2, Nat>:
  st.pos.go(ls, a, 0n, None{})

def st.poss(ns: List<&2, List<&2, U32>>, +ls: List<&2, List<&2, U32>>) -> List<&2, Maybe<&2, Nat>>:
  match ns:
    case Nil{}:
      Nil{}
    case a <> more:
      st.pos(ls, a) <> st.poss(more, ls)

# pos[a] + 1 of the first a there is (d when none is)
def st.first.some(ms: List<&2, Maybe<&2, Nat>>, +d: Nat) -> Nat:
  match ms:
    case Nil{}:
      d
    case Some{k} <> more:
      1n+k
    case None{} <> more:
      st.first.some(more, d)

# does any line (a comment too) start with the word name
def st.any.first(ls: List<&2, List<&2, U32>>, +name: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> more:
      Bool.or(st.word0.is(st.words(l), name), st.any.first(more, name))

def st.nonws.go(xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t False{}:
      h <> st.nonws.go(t, st.ws.head(t))
    case _ _:
      Nil{}

# the leading bytes that are not whitespace
def st.nonws(+xs: List<&2, U32>) -> List<&2, U32>:
  st.nonws.go(xs, st.ws.head(xs))

# `stage (\S+): from` at the start of xs: \S+ is the whole run of
# non-whitespace after "stage " less its last byte, which must be `:`
def st.re.here(+xs: List<&2, U32>, hit: Bool) -> Maybe<&2, List<&2, U32>>:
  match hit:
    case False{}:
      None{}
    case True{}:
      +r = List.drop(&2, U32, xs, 6n)
      +t = st.nonws(r)
      +n = S.len(t)
      Bool.pick(Maybe<&2, List<&2, U32>>,
        Bool.and(Bool.and(Nat.is_le(2n, n), U32.is_eq(L.v2.byte.at(t, Nat.sub(n, 1n)), 58)), S.prefix(List.drop(&2, U32, r, n), [32, 102, 114, 111, 109])),
        Some{List.take(&2, U32, t, Nat.sub(n, 1n))}, None{})

def st.re.keep(m: Maybe<&2, List<&2, U32>>, found: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case Some{x}:
      Some{x}
    case None{}:
      found

# the last `stage NAME: from` (matches do not overlap: none starts inside another)
def st.re.last(xs: List<&2, U32>, found: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      found
    case +h <> +t:
      +ys = {h <> t : List<&2, U32>}
      st.re.last(t, st.re.keep(st.re.here(ys, S.prefix(ys, [115, 116, 97, 103, 101, 32])), found))

def st.ins.word0(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case Some{l}:
      st.nth(st.words(l), 0n)
    case None{}:
      None{}

def st.ins.started(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case Some{x}:
      x
    case None{}:
      [63]

def st.ins.say(+name: List<&2, U32>, +i: Nat, prev: Maybe<&2, List<&2, U32>>, +started: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match prev:
    case Some{p}:
      IO.print(S.str(L.v2.concat([name, S.b(" inserted at line "), S.b(Nat.show(1n+i)), S.b(" (after "), p, S.b("); the chain last started "), st.ins.started(started)])))
    case None{}:
      IO.die(Unit, 1, "insert-stage: the line before the new one has no word")

def st.ins.write(+stages: String, +ls: List<&2, List<&2, U32>>, +line: List<&2, U32>, +name: List<&2, U32>, +i: Nat, +started: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  +nls = List.append(&2, List<&2, U32>, List.take(&2, List<&2, U32>, ls, i), line <> List.drop(&2, List<&2, U32>, ls, i))
  +k = Bool.pick(Nat, Nat.is_eq(i, 0n), Nat.sub(List.length(&2, List<&2, U32>, nls), 1n), Nat.sub(i, 1n))
  do IO<Unit>:
    S.write(stages ++ ".tmp", L.v2.concat(nls))
    S.mv(stages ++ ".tmp", stages)
    st.ins.say(name, i, st.ins.word0(st.nth(nls, k)), started)

# i: the AFTER position, moved past the stage the chain last started
def st.ins.place(+stages: String, +ls: List<&2, List<&2, U32>>, +line: List<&2, U32>, +name: List<&2, U32>, +i: Nat, +started: Maybe<&2, List<&2, U32>>, at: Maybe<&2, Nat>) -> IO(Unit):
  match at:
    case Some{k}:
      st.ins.write(stages, ls, line, name, Nat.max(i, 1n+k), started)
    case None{}:
      st.ins.write(stages, ls, line, name, i, started)

def st.ins.pos.of(+ls: List<&2, List<&2, U32>>, m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, Nat>:
  match m:
    case Some{s}:
      st.pos(ls, s)
    case None{}:
      None{}

def st.ins.log(+stages: String, +ls: List<&2, List<&2, U32>>, +line: List<&2, U32>, +name: List<&2, U32>, +i: Nat, l: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match l:
    case None{}:
      IO.die(Unit, 1, "insert-stage: cannot read the chain log")
    case Some{log}:
      +started = st.re.last(log, None{})
      st.ins.place(stages, ls, line, name, i, started, st.ins.pos.of(ls, started))

def st.ins.name(+stages: String, +after: String, +line: List<&2, U32>, +ls: List<&2, List<&2, U32>>, n: Maybe<&2, List<&2, U32>>, l: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match n:
    case None{}:
      IO.die(Unit, 1, "insert-stage: LINE has no word")
    case Some{+name}:
      Bool.pick(IO(Unit), st.any.first(ls, name), IO.die(Unit, 1, S.str(name) ++ " is already in the stages"),
        st.ins.log(stages, ls, line, name, st.first.some(st.poss(st.psplit(S.b(after), 44), ls), List.length(&2, List<&2, U32>, ls)), l))

def st.ins.got(+stages: String, +after: String, +line: List<&2, U32>, m: Maybe<&2, List<&2, U32>>, l: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "insert-stage: cannot read " ++ stages)
    case Some{xs}:
      st.ins.name(stages, after, line, st.lines.keep(st.cr(xs)), st.nth(st.words(line), 0n), l)

def st.ins.go(+stages: String, log: String, +after: String, +line: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(stages)
    l : Maybe<&2, List<&2, U32>> <- S.slurp(log)
    st.ins.got(stages, after, line, m, l)

def st.insert.stage(xs: List<String>) -> IO(Unit):
  match xs:
    case stages <> log <> after <> rest:
      st.ins.go(stages, log, after, S.append(st.join.args(st.strs(rest)), [10]))
    case _:
      st.usage("insert-stage STAGES CHAINLOG AFTER[,AFTER...] LINE...")

# vault-sample ---------------------------------------------------------------------------
#
# evals.sh's vault eval sample: SRC's documents ordered by
# sha256("corpus-v2 vault eval\0" + id) (hex, then the id), each taken
# unless its repository already gave 5 or its text is past 100,000
# characters, until the texts pass 2,000,000 characters; DST is the taken
# (id, text) pairs as NUL fields.  Two passes over SRC: the order first (ids,
# keys and lengths), then the taken texts.

type StIt is Data:
  StIt{key: List<&2, U32>, id: List<&2, U32>, n: Nat, ix: Nat}

def st.u32.cmp(+x: U32, +y: U32) -> Cmp:
  Bool.pick(Cmp, U32.is_lt(x, y), LT{}, Bool.pick(Cmp, U32.is_lt(y, x), GT{}, EQ{}))

# bytes in order (UTF-8's order is the code points')
def st.bytes.cmp(xs: List<&2, U32>, ys: List<&2, U32>, c: Cmp) -> Cmp:
  match xs ys c:
    case +x <> xt +y <> yt EQ{}:
      st.bytes.cmp(xt, yt, st.u32.cmp(x, y))
    case Nil{} Nil{} EQ{}:
      EQ{}
    case Nil{} _ EQ{}:
      LT{}
    case _ Nil{} EQ{}:
      GT{}
    case _ _ LT{}:
      LT{}
    case _ _ GT{}:
      GT{}

def st.it.le.c(c: Cmp, +x1: Nat, +x2: Nat) -> Bool:
  match c:
    case LT{}:
      True{}
    case GT{}:
      False{}
    case EQ{}:
      Nat.is_le(x1, x2)

def st.it.le(a: StIt, b: StIt) -> Bool:
  match a b:
    case StIt{k1, i1, n1, +x1} StIt{k2, i2, n2, +x2}:
      st.it.le.c(st.bytes.cmp(k1, k2, EQ{}), x1, x2)

def st.vs.item(+id: List<&2, U32>, text: List<&2, U32>, +ix: Nat) -> StIt:
  StIt{S.append(S.b(H.sha256(L.v2.concat([S.b("corpus-v2 vault eval"), [0], id]))), id), id, st.cps(text, 0n), ix}

type StVs is Type:
  StVs{r: StRd, its: List<&2, StIt>, ix: Nat, more: Bool}

def st.vs.doc(r: StRd, its: List<&2, StIt>, +ix: Nat, d: Maybe<&2, J.Doc>) -> IO(StVs):
  match d:
    case Some{J.Doc{i, t}}:
      IO.pure(StVs, StVs{r, st.vs.item(i, t, ix) <> its, 1n+ix, True{}})
    case None{}:
      do IO<StVs>:
        st.rd.close(r)
        IO.die(StVs, 1, "vault-sample: line " ++ Nat.show(1n+ix) ++ " is not a JSON {\"id\", \"text\"} document")

def st.vs.rec(r: StRd, its: List<&2, StIt>, +ix: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(StVs):
  match m:
    case None{}:
      IO.pure(StVs, StVs{r, its, ix, False{}})
    case Some{l}:
      st.vs.doc(r, its, ix, J.doc(l))

def st.vs.got(its: List<&2, StIt>, +ix: Nat, x: StRd & Maybe<&2, List<&2, U32>>) -> IO(StVs):
  (r, m) = x
  st.vs.rec(r, its, ix, m)

def st.vs.step(z: StVs) -> IO(StVs):
  match z:
    case StVs{r, its, ix, m}:
      IO.bind(StRd & Maybe<&2, List<&2, U32>>, StVs, st.rd.line(r), st.vs.got(its, ix))

def st.vs.go(fuel: Nat, z: StVs) -> IO(StVs):
  match fuel z:
    case 1n+f StVs{r, its, ix, True{}}:
      IO.bind(StVs, StVs, st.vs.step(StVs{r, its, ix, True{}}), st.vs.go(f))
    case _ z2:
      IO.pure(StVs, z2)

def st.vs.fin(z: StVs) -> IO(List<&2, StIt>):
  match z:
    case StVs{r, its, ix, m}:
      do IO<List<&2, StIt>>:
        st.rd.close(r)
        return its

# the taking: per repository counts, characters so far, the taken lines (last first)
type StSel is Data:
  StSel{per: Map<&2, Nat>, n: Nat, sel: List<&2, Nat>, done: Bool}

def st.vs.take(skip: Bool, per: Map<&2, Nat>, +r: String, +c: Nat, +n: Nat, +len: Nat, sel: List<&2, Nat>, +ix: Nat) -> StSel:
  match skip:
    case True{}:
      StSel{per, n, sel, False{}}
    case False{}:
      +n2 = Nat.add(n, len)
      StSel{Map.set(&2, Nat, per, r, 1n+c), n2, ix <> sel, Nat.is_lt(2000000n, n2)}

def st.vs.count(+r: String, +n: Nat, +len: Nat, sel: List<&2, Nat>, +ix: Nat, pc: Map<&2, Nat> & Nat) -> StSel:
  (per, +c) = pc
  st.vs.take(Bool.or(Nat.is_le(5n, c), Nat.is_lt(100000n, len)), per, r, c, n, len, sel, ix)

def st.vs.one.it(it: StIt, per: Map<&2, Nat>, +n: Nat, sel: List<&2, Nat>) -> StSel:
  match it:
    case StIt{k, id, +len, +ix}:
      +r = st.key(L.v2.repo.of(id))
      st.vs.count(r, n, len, sel, ix, Map.get(Nat, 0n, per, r))

def st.vs.one(it: StIt, s: StSel) -> StSel:
  match s:
    case StSel{per, n, sel, True{}}:
      StSel{per, n, sel, True{}}
    case StSel{per, +n, sel, False{}}:
      st.vs.one.it(it, per, n, sel)

def st.vs.pick(its: List<&2, StIt>, s: StSel) -> StSel:
  match its:
    case Nil{}:
      s
    case it <> more:
      st.vs.pick(more, st.vs.one(it, s))

# the second pass: every taken line's NUL record with its place in the order
type StRk is Data:
  StRk{k: Nat, rec: List<&2, U32>}

def st.rk.le(a: StRk, b: StRk) -> Bool:
  match a b:
    case StRk{x, r} StRk{y, q}:
      Nat.is_le(x, y)

def st.rk.cat(rs: List<&2, StRk>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case StRk{k, r} <> more:
      List.append(&2, U32, r, st.rk.cat(more))

# a line number's place in the order (none: the line is not taken)
def st.v2.none() -> Nat:
  4294967295n

def st.v2.ranks(sel: List<&2, Nat>, +k: Nat, m: Map<&2, Nat>) -> Map<&2, Nat>:
  match sel:
    case Nil{}:
      m
    case ix <> more:
      st.v2.ranks(more, 1n+k, Map.set(&2, Nat, m, Nat.show(ix), k))

type StV2 is Type:
  StV2{r: StRd, ranks: Map<&2, Nat>, got: List<&2, StRk>, ix: Nat, more: Bool}

def st.v2.rec.doc(d: Maybe<&2, J.Doc>) -> List<&2, U32>:
  match d:
    case Some{J.Doc{i, t}}:
      L.v2.concat([i, [0], t, [0]])
    case None{}:
      Nil{}

def st.v2.keep.if(r: StRd, ranks: Map<&2, Nat>, got: List<&2, StRk>, +ix: Nat, l: List<&2, U32>, +k: Nat, has: Bool) -> StV2:
  match has:
    case True{}:
      StV2{r, ranks, StRk{k, st.v2.rec.doc(J.doc(l))} <> got, 1n+ix, True{}}
    case False{}:
      StV2{r, ranks, got, 1n+ix, True{}}

def st.v2.keep(r: StRd, got: List<&2, StRk>, +ix: Nat, l: List<&2, U32>, mk: Map<&2, Nat> & Nat) -> StV2:
  (ranks, +k) = mk
  st.v2.keep.if(r, ranks, got, ix, l, k, Nat.is_ne(k, st.v2.none()))

def st.v2.rec(r: StRd, ranks: Map<&2, Nat>, got: List<&2, StRk>, +ix: Nat, m: Maybe<&2, List<&2, U32>>) -> StV2:
  match m:
    case None{}:
      StV2{r, ranks, got, ix, False{}}
    case Some{l}:
      st.v2.keep(r, got, ix, l, Map.get(Nat, st.v2.none(), ranks, Nat.show(ix)))

def st.v2.got(ranks: Map<&2, Nat>, got: List<&2, StRk>, +ix: Nat, x: StRd & Maybe<&2, List<&2, U32>>) -> IO(StV2):
  (r, m) = x
  IO.pure(StV2, st.v2.rec(r, ranks, got, ix, m))

def st.v2.step(z: StV2) -> IO(StV2):
  match z:
    case StV2{r, ranks, got, ix, m}:
      IO.bind(StRd & Maybe<&2, List<&2, U32>>, StV2, st.rd.line(r), st.v2.got(ranks, got, ix))

def st.v2.go(fuel: Nat, z: StV2) -> IO(StV2):
  match fuel z:
    case 1n+f StV2{r, w, g, ix, True{}}:
      IO.bind(StV2, StV2, st.v2.step(StV2{r, w, g, ix, True{}}), st.v2.go(f))
    case _ z2:
      IO.pure(StV2, z2)

def st.vs.done(+dst: String, +n: Nat, +repos: Nat, z: StV2) -> IO(Unit):
  match z:
    case StV2{r, w, got, ix, m}:
      do IO<Unit>:
        st.rd.close(r)
        S.write(dst, st.rk.cat(List.sort(~StRk, ~st.rk.le, got)))
        IO.print(dst ++ " " ++ Nat.show(n) ++ " bytes from " ++ Nat.show(repos) ++ " repositories")

def st.vs.write(+src: String, +dst: String, s: StSel) -> IO(Unit):
  match s:
    case StSel{per, +n, rsel, d}:
      do IO<Unit>:
        r : StRd <- st.rd.open(src, 10)
        z : StV2 <- st.v2.go(st.fuel(), StV2{r, st.v2.ranks(List.reverse(&2, Nat, rsel), 0n, Map.new(&2, Nat)), Nil{}, 0n, True{}})
        st.vs.done(dst, n, Map.size(&2, Nat, per), z)

def st.vs.run(+src: String, +dst: String) -> IO(Unit):
  do IO<Unit>:
    r : StRd <- st.rd.open(src, 10)
    z : StVs <- st.vs.go(st.fuel(), StVs{r, Nil{}, 0n, True{}})
    its : List<&2, StIt> <- st.vs.fin(z)
    st.vs.write(src, dst, st.vs.pick(List.sort(~StIt, ~st.it.le, its), StSel{Map.new(&2, Nat), 0n, Nil{}, False{}}))

def st.vault.sample(xs: List<String>) -> IO(Unit):
  match xs:
    case src <> dst <> Nil{}:
      st.vs.run(src, dst)
    case _:
      st.usage("vault-sample SRC.jsonl DST.nul")
