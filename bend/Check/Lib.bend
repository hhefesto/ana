import Base
import ../Sys.bend as S

# The part of the checker harness every language shares (bend/Check.bend
# runs it; bend/Check/<Lang>.bend are the languages).
#
# UNITS.nul is what bend-units wrote: NUL-framed (id, record) pairs, the
# record's fields joined by the byte 0x1E (bend/Units.bend lists them:
# 0 lang, 1 kind, 2 name, 3 doc, 4 sig, 5 head, 6 pre, 7 body, 8 tail,
# 9 names, 10 hole, 11.. mutants).  RESULTS.nul holds one pair per kept
# unit, in the order of UNITS.nul, the record's fields joined by 0x1E:
#
#   0..10  the unit's fields 0..10
#   11     the original's check
#   12     the Context: `name : type` lines as the checker printed them
#   13     the hole's check (empty: no hole)
#   14     the checker's type for the declaration's name (empty: none)
#   15..   pairs: a mutant, then its check (only mutants the checker rejects)
#
# A check is the checker's exit status (`-` for an interactive session,
# which has none), the byte 0x1F, and its output with the work directory's
# path removed (so files read `Unit.hs`, not /tmp/...), capped at CAP_LINES
# lines.  Every decision is counted in RESULTS.nul.stats.

def FS() -> U32:
  30

def US() -> U32:
  31

# The fields of a record: the pieces between 0x1E bytes, every separator
# counted (n separators, n + 1 fields), then padded with empty fields to 11
# (a unit with an empty hole and no mutants ends in its separator; the bash
# harness lost that field and, under `set -u`, the worker with it).
def fields.step(sep: Bool, h: U32, r: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match sep r:
    case True{} _:
      Nil{} <> r
    case False{} Nil{}:
      [[h]]
    case False{} x <> more:
      (h <> x) <> more

def fields.exact(xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      [Nil{}]
    case +h <> t:
      fields.step(U32.is_eq(h, 30), h, fields.exact(t))

def pad(n: Nat, fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match n fs:
    case 0n _:
      fs
    case 1n+k Nil{}:
      Nil{} <> pad(k, Nil{})
    case 1n+k x <> more:
      x <> pad(k, more)

def fields(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  pad(11n, fields.exact(xs))

# A unit: its position in UNITS.nul, its id and its fields.
type U is Data:
  U{i: Nat, id: List<&2, U32>, f: List<&2, List<&2, U32>>}

def U.i(+u: U) -> Nat:
  match u:
    case U{i, d, f}:
      i

def U.id(+u: U) -> List<&2, U32>:
  match u:
    case U{i, d, f}:
      d

def U.f(+u: U) -> List<&2, List<&2, U32>>:
  match u:
    case U{i, d, f}:
      f

def nth(fs: List<&2, List<&2, U32>>, k: Nat) -> List<&2, U32>:
  match fs k:
    case x <> more 0n:
      x
    case x <> more 1n+j:
      nth(more, j)
    case Nil{} _:
      Nil{}

def U.at(+u: U, +k: Nat) -> List<&2, U32>:
  nth(U.f(u), k)

# the mutants: fields 11..
def U.mutants(+u: U) -> List<&2, List<&2, U32>>:
  List.drop(&2, List<&2, U32>, U.f(u), 11n)

# the names field (9), split on whitespace
def space(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 10)), U32.is_eq(c, 9))

def space.head(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      space(h)
    case Nil{}:
      False{}

def word.put(h: U32, r: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match r:
    case Nil{}:
      [[h]]
    case w <> more:
      (h <> w) <> more

def words.go(xs: List<&2, U32>, mid: Bool, sp: Bool) -> List<&2, List<&2, U32>>:
  match xs mid sp:
    case Nil{} True{} _:
      [Nil{}]
    case Nil{} False{} _:
      Nil{}
    case h <> +t True{} True{}:
      Nil{} <> words.go(t, False{}, space.head(t))
    case h <> +t False{} True{}:
      words.go(t, False{}, space.head(t))
    case h <> +t _ False{}:
      word.put(h, words.go(t, True{}, space.head(t)))

def words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  words.go(xs, False{}, space.head(xs))

# Checks and records ---------------------------------------------------------

# "<status>\x1F<output>"
def check(+status: String, out: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, S.b(status), 31 <> out)

def head.us(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 31)
    case Nil{}:
      False{}

def check.status.go(xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> check.status.go(t, head.us(t))
    case _ _:
      Nil{}

# a check's status: the bytes before its 0x1F
def check.status(+xs: List<&2, U32>) -> List<&2, U32>:
  check.status.go(xs, head.us(xs))

# its output: the bytes after the first 0x1F
def check.text(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 31), t, check.text(t))

# the result record: the unit's fields 0..10, then the checks
def result(+u: U, checks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  S.join(List.append(&2, List<&2, U32>, List.take(&2, List<&2, U32>, U.f(u), 11n), checks), 30)

# The kept mutants as (mutant, check) fields in order, and the stats keys.
type Mu is Data:
  Mu{checks: List<&2, List<&2, U32>>, keys: List<&2, String>}

def mu.at(ok: Bool, late: Bool, m: List<&2, U32>, c: List<&2, U32>, r: Mu) -> Mu:
  match ok late r:
    case True{} _ Mu{cs, ks}:
      Mu{cs, "mutant_checks" <> ks}
    case False{} True{} Mu{cs, ks}:
      Mu{cs, "mutant_timeout" <> ks}
    case False{} False{} Mu{cs, ks}:
      Mu{m <> c <> cs, "mutant_kept" <> ks}

# The batch checkers' rule: a mutant that checks (0) or times out (124) is
# not kept; any other status keeps it, with its check.
def mu.rule(+e: U32, m: List<&2, U32>, c: List<&2, U32>, r: Mu) -> Mu:
  mu.at(U32.is_eq(e, 0), U32.is_eq(e, 124), m, c, r)

# the position of the last p in xs (None: absent)
def last.at(xs: List<&2, U32>, +p: List<&2, U32>, +k: Nat, best: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match xs:
    case Nil{}:
      best
    case +h <> +t:
      last.at(t, p, 1n+k, Bool.pick(Maybe<&2, Nat>, S.prefix(h <> t, p), Some{k}, best))

def before.at(+xs: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case Some{k}:
      List.take(&2, U32, xs, k)
    case None{}:
      xs

# xs up to the last p (all of xs when p is absent)
def before.last(+xs: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  before.at(xs, last.at(xs, p, 0n, None{}))

# A hole's check and its stats keys.
type Hk is Data:
  Hk{check: List<&2, U32>, keys: List<&2, String>}

# Stats ---------------------------------------------------------------------

type Stat is Data:
  Stat{key: String, n: Nat}

def stat.bump(+key: String, +k: Nat, st: List<&2, Stat>) -> List<&2, Stat>:
  match st:
    case Nil{}:
      [Stat{key, k}]
    case Stat{+x, +m} <> +more:
      Bool.pick(List<&2, Stat>, String.eq(x, key), Stat{x, Nat.add(m, k)} <> more, Stat{x, m} <> stat.bump(key, k, more))

# count every key of ks once
def stat.all(ks: List<&2, String>, st: List<&2, Stat>) -> List<&2, Stat>:
  match ks:
    case Nil{}:
      st
    case +k <> more:
      stat.all(more, stat.bump(k, 1n, st))

def stat.merge(a: List<&2, Stat>, st: List<&2, Stat>) -> List<&2, Stat>:
  match a:
    case Nil{}:
      st
    case Stat{+k, +n} <> more:
      stat.merge(more, stat.bump(k, n, st))

def cmp.le(c: Cmp) -> Bool:
  match c:
    case GT{}:
      False{}
    case _:
      True{}

def cmp.le.of(r: (String & String) & Cmp) -> Bool:
  (ab, c) = r
  cmp.le(c)

def stat.le(a: Stat, c: Stat) -> Bool:
  match a c:
    case Stat{x, m} Stat{y, n}:
      cmp.le.of(String.cmp(x, y))

def stat.lines(st: List<&2, Stat>) -> String:
  match st:
    case Nil{}:
      ""
    case Stat{k, n} <> more:
      k ++ " " ++ Nat.show(n) ++ "\n" ++ stat.lines(more)

# `key count` lines, keys in byte order
def stat.show(+st: List<&2, Stat>) -> String:
  stat.lines(List.sort(~Stat, ~stat.le, st))

# What checking a unit gives: its result record when it is kept, and the
# stats keys it counts.
type Got is Data:
  Kept{rec: List<&2, U32>, keys: List<&2, String>}
  Dropped{keys: List<&2, String>}

# one more stats key on a unit's outcome
def Got.key(+k: String, g: Got) -> Got:
  match g:
    case Kept{r, ks}:
      Kept{r, k <> ks}
    case Dropped{ks}:
      Dropped{k <> ks}

# several stats keys more
def Got.keys(ks: List<&2, String>, g: Got) -> Got:
  match g:
    case Kept{r, xs}:
      Kept{r, List.append(&2, String, ks, xs)}
    case Dropped{xs}:
      Dropped{List.append(&2, String, ks, xs)}

# a mutant verdict put in front of the rest's
def mu.put(cs: List<&2, List<&2, U32>>, ks: List<&2, String>, r: Mu) -> Mu:
  match r:
    case Mu{rc, rk}:
      Mu{List.append(&2, List<&2, U32>, cs, rc), List.append(&2, String, ks, rk)}
