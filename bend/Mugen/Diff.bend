
import Base
import ./IMap.bend as I

# Diff: a file's change as a unified diff (Machine.ts text_diff), as the
# write and edit tools answer: the file's name as old and new, then each run
# of changes in a hunk with CONTEXT lines around it (runs that close share
# one). Lines keep their "\n", so a last one without it differs, and says so
# as git does. The lines kept are a longest common subsequence (Myers'
# greedy O((n+m)d), its rounds kept to walk back; past MAX rounds the rest
# is all changed); between two kept lines the old ones go, then the new.
#
# Every def is prefixed `df.` (a program's defs share one namespace).
#
# ana's copy of mugen's bend/Diff.bend (github:hhefesto/mugen c3275ba), so
# the corpus's edit echoes are the diffs mugen's edit tool answers byte for
# byte (Transcript.bend, format mugen). Changed: Text.bend's tx.concat is
# df.concat here. Keep it in step with mugen's.

def df.concat(xs: List<&2, String>) -> String:
  match xs:
    case []:
      ""
    case x <> t:
      x ++ df.concat(t)

def df.context() -> U32:
  3

def df.max() -> U32:
  1000

# a text's lines, each with its "\n" (the last may lack it, and then says so)
def df.lines.go(s: String, +cur: String, +acc: List<&2, String>) -> List<&2, String>:
  match s:
    case SNil{}:
      List.reverse(&2, String, Bool.pick(List<&2, String>, String.is_empty(cur), acc,
        (String.reverse(cur) ++ "\n\\ No newline at end of file") <> acc))
    case SCon{Chr{10}, t}:
      df.lines.go(t, "", String.reverse(SCon{Chr{10}, cur}) <> acc)
    case SCon{c, t}:
      df.lines.go(t, SCon{c, cur}, acc)

def df.lines(+s: String) -> List<&2, String>:
  df.lines.go(s, "", [])

# lines by index
def df.arr.go(xs: List<&2, String>, +k: U32, acc: I.im.M<String>) -> I.im.M<String>:
  match xs:
    case []:
      acc
    case x <> t:
      df.arr.go(t, (k + 1 : U32), I.im.set(String, acc, k, x))

def df.arr(xs: List<&2, String>) -> I.im.M<String>:
  df.arr.go(xs, 0, I.im.new(String))

def df.at(+a: I.im.M<String>, +k: U32) -> String:
  Maybe.default(&2, String, I.im.get(String, a, k), "")

# Myers ----------------------------------------------------------------------
#
# Diagonal k = x - y is kept as k + off (off = n + m + 1), never negative. A
# round's V maps each diagonal it reached to the furthest x on it.

def df.v(+v: I.im.M<U32>, +kk: U32) -> U32:
  Maybe.default(&2, U32, I.im.get(U32, v, kk), 0)

# a pair of indexes: a line of a, a line of b; or a run [lo, hi)
type df.P is Data:
  df.P{a: U32, b: U32}

# whether line x of a and line y of b are there and equal
def df.eq(+a: I.im.M<String>, +b: I.im.M<String>, +na: U32, +nb: U32, +x: U32, +y: U32) -> Bool:
  Bool.and(Bool.and(U32.is_lt(x, na), U32.is_lt(y, nb)), String.eq(df.at(a, x), df.at(b, y)))

# the snake from (x, y): as far as the lines match (ok: they do at (x, y))
def df.snake(n: Nat, ok: Bool, +a: I.im.M<String>, +b: I.im.M<String>, +na: U32, +nb: U32, +x: U32, +y: U32) -> U32:
  match n ok:
    case 1n+f True{}:
      df.snake(f, df.eq(a, b, na, nb, (x + 1 : U32), (y + 1 : U32)), a, b, na, nb, (x + 1 : U32), (y + 1 : U32))
    case _ _:
      x

# down (from diagonal k+1, a line of b added) or right (from k-1, one of a dropped)
def df.down(+v: I.im.M<U32>, +kk: U32, +lo: U32, +hi: U32) -> Bool:
  Bool.or(U32.is_eq(kk, lo), Bool.and(Bool.not(U32.is_eq(kk, hi)), U32.is_lt(df.v(v, (kk - 1 : U32)), df.v(v, (kk + 1 : U32)))))

# The search: round d, diagonal kk, this round's V (seeded with the last's),
# the rounds before (newest first). Answers the rounds kept (newest first),
# the last the one that reached (n, m), or [] if MAX rounds did not. go: what
# the last step found: 0 the end reached, 1 given up, 2 go on.
type df.S is Data:
  df.S{d: U32, kk: U32, v: I.im.M<U32>, hist: List<&2, I.im.M<U32>>}

def df.search(fuel: Nat, go: Nat, +a: I.im.M<String>, +b: I.im.M<String>, +na: U32, +nb: U32, +off: U32, s: df.S) -> List<&2, I.im.M<U32>>:
  match fuel go s:
    case 0n _ _:
      []
    case 1n+f 0n df.S{d, kk, v, hist}:
      v <> hist
    case 1n+f 1n _:
      []
    case 1n+f _ df.S{+d, +kk, +v, +hist}:
      +lo = (off - d : U32)
      +hi = (off + d : U32)
      +x0 = Bool.pick(U32, df.down(v, kk, lo, hi), df.v(v, (kk + 1 : U32)), (df.v(v, (kk - 1 : U32)) + 1 : U32))
      +y0 = ((x0 + off : U32) - kk : U32)
      +x = df.snake(U32.to_nat((na + nb : U32)), df.eq(a, b, na, nb, x0, y0), a, b, na, nb, x0, y0)
      +y = ((x + off : U32) - kk : U32)
      +v2 = I.im.set(U32, v, kk, x)
      +reached = Bool.and(U32.is_ge(x, na), U32.is_ge(y, nb))
      +last = U32.is_ge(kk, hi)
      +go2 = Bool.pick(Nat, reached, 0n, Bool.pick(Nat, Bool.and(last, U32.is_ge(d, df.max())), 1n, 2n))
      df.search(f, go2, a, b, na, nb, off,
        Bool.pick(df.S, reached, df.S{d, kk, v2, hist},
          Bool.pick(df.S, last, df.S{(d + 1 : U32), (off - (d + 1 : U32) : U32), v2, v2 <> hist}, df.S{d, (kk + 2 : U32), v2, hist})))

# Walking back: from (x, y) at round d, each round's snake gives its pairs
# (a line of a, a line of b kept), down to its start mx; last first.
def df.back.snake(n: Nat, more: Bool, +x: U32, +y: U32, +mx: U32, pairs: List<&2, df.P>) -> List<&2, df.P>:
  match n more:
    case 1n+f True{}:
      df.back.snake(f, U32.is_gt((x - 1 : U32), mx), (x - 1 : U32), (y - 1 : U32), mx, df.P{(x - 1 : U32), (y - 1 : U32)} <> pairs)
    case _ _:
      pairs

def df.back(hist: List<&2, I.im.M<U32>>, +x: U32, +y: U32, +d: U32, +off: U32, pairs: List<&2, df.P>) -> List<&2, df.P>:
  match hist:
    case []:
      df.back.snake(U32.to_nat(x), U32.is_gt(x, 0), x, y, 0, pairs)
    case +v <> t:
      +kk = ((x + off : U32) - y : U32)
      +dn = df.down(v, kk, (off - d : U32), (off + d : U32))
      +pk = Bool.pick(U32, dn, (kk + 1 : U32), (kk - 1 : U32))
      +px = df.v(v, pk)
      +py = ((px + off : U32) - pk : U32)
      +mx = Bool.pick(U32, dn, px, (px + 1 : U32))
      df.back(t, px, py, (d - 1 : U32), off, df.back.snake(U32.to_nat(x), U32.is_gt(x, mx), x, y, mx, pairs))

def df.walk(hist: List<&2, I.im.M<U32>>, +na: U32, +nb: U32, +off: U32) -> List<&2, df.P>:
  match hist:
    case []:
      []
    case v <> +t:
      df.back(t, na, nb, U32.from_nat(List.length(&2, I.im.M<U32>, t)), off, [])

# The lines to match: only those both texts have (a line only one has is
# never kept, so a file rewritten whole needs no search), each with its index
# in its text; then their common head and tail kept at once, the search run
# only between (Machine.ts lines_diff, lines_match).

type df.F is Data:
  df.F{lines: List<&2, String>, idx: List<&2, U32>}

def df.has.of(p: Map<&2, Unit> & Bool) -> Bool:
  match p:
    case (m, b):
      b

def df.has(+m: Map<&2, Unit>, +x: String) -> Bool:
  df.has.of(Map.has(&2, Unit, m, x))

def df.set(xs: List<&2, String>, acc: Map<&2, Unit>) -> Map<&2, Unit>:
  match xs:
    case []:
      acc
    case x <> t:
      df.set(t, Map.set(&2, Unit, acc, x, Unit{}))

def df.keep.on(b: Bool, +x: String, +k: U32, f: df.F) -> df.F:
  match b f:
    case True{} df.F{ls, ix}:
      df.F{x <> ls, k <> ix}
    case False{} _:
      f

def df.keep(xs: List<&2, String>, +other: Map<&2, Unit>, +k: U32) -> df.F:
  match xs:
    case []:
      df.F{[], []}
    case +x <> t:
      df.keep.on(df.has(other, x), x, k, df.keep(t, other, (k + 1 : U32)))

# the common head's length
def df.head.n(a: List<&2, String>, b: List<&2, String>, +n: U32) -> U32:
  match a b:
    case +x <> ta +y <> tb:
      Bool.pick(U32, String.eq(x, y), df.head.n(ta, tb, (n + 1 : U32)), n)
    case _ _:
      n

def df.u32.at(+m: I.im.M<U32>, +k: U32) -> U32:
  Maybe.default(&2, U32, I.im.get(U32, m, k), 0)

def df.u32.arr(xs: List<&2, U32>, +k: U32, acc: I.im.M<U32>) -> I.im.M<U32>:
  match xs:
    case []:
      acc
    case x <> t:
      df.u32.arr(t, (k + 1 : U32), I.im.set(U32, acc, k, x))

# the pairs (k, k) for the n k up to `top`, shifted by (da, db), through the
# indexes (built from the top down)
def df.diag(n: Nat, +top: U32, +da: U32, +db: U32, +xa: I.im.M<U32>, +xb: I.im.M<U32>, acc: List<&2, df.P>) -> List<&2, df.P>:
  match n:
    case 0n:
      acc
    case 1n+f:
      df.diag(f, (top - 1 : U32), da, db, xa, xb, df.P{df.u32.at(xa, (top + da : U32)), df.u32.at(xb, (top + db : U32))} <> acc)

def df.map(ps: List<&2, df.P>, +h: U32, +xa: I.im.M<U32>, +xb: I.im.M<U32>) -> List<&2, df.P>:
  match ps:
    case []:
      []
    case df.P{+p, +q} <> t:
      df.P{df.u32.at(xa, (p + h : U32)), df.u32.at(xb, (q + h : U32))} <> df.map(t, h, xa, xb)

def df.mid(+fa: List<&2, String>, +fb: List<&2, String>, +h: U32, +t: U32) -> df.F & df.F:
  +na = U32.from_nat(List.length(&2, String, fa))
  +nb = U32.from_nat(List.length(&2, String, fb))
  (df.F{List.take(&2, String, List.drop(&2, String, fa, U32.to_nat(h)), U32.to_nat(((na - h : U32) - t : U32))), []},
    df.F{List.take(&2, String, List.drop(&2, String, fb, U32.to_nat(h)), U32.to_nat(((nb - h : U32) - t : U32))), []})

def df.lines.of(f: df.F) -> List<&2, String>:
  match f:
    case df.F{ls, ix}:
      ls

def df.idx.of(f: df.F) -> List<&2, U32>:
  match f:
    case df.F{ls, ix}:
      ix

def df.search.mid(+ma: List<&2, String>, +mb: List<&2, String>) -> List<&2, df.P>:
  +a = df.arr(ma)
  +b = df.arr(mb)
  +na = U32.from_nat(List.length(&2, String, ma))
  +nb = U32.from_nat(List.length(&2, String, mb))
  +off = ((na + nb : U32) + 1 : U32)
  Bool.pick(List<&2, df.P>, Bool.or(U32.is_eq(na, 0), U32.is_eq(nb, 0)), [],
    df.walk(df.search(U32.to_nat(4294967295), 2n, a, b, na, nb, off, df.S{0, off, I.im.set(U32, I.im.new(U32), (off + 1 : U32), 0), []}), na, nb, off))

def df.mid.pairs(p: df.F & df.F) -> List<&2, df.P>:
  match p:
    case (a, b):
      df.search.mid(df.lines.of(a), df.lines.of(b))

# the pairs kept, in order
def df.pairs(+la: List<&2, String>, +lb: List<&2, String>) -> List<&2, df.P>:
  +fa = df.keep(la, df.set(lb, Map.new(&2, Unit)), 0)
  +fb = df.keep(lb, df.set(la, Map.new(&2, Unit)), 0)
  +sa = df.lines.of(fa)
  +sb = df.lines.of(fb)
  +xa = df.u32.arr(df.idx.of(fa), 0, I.im.new(U32))
  +xb = df.u32.arr(df.idx.of(fb), 0, I.im.new(U32))
  +na = U32.from_nat(List.length(&2, String, sa))
  +nb = U32.from_nat(List.length(&2, String, sb))
  +h = df.head.n(sa, sb, 0)
  +t = U32.min(df.head.n(List.reverse(&2, String, sa), List.reverse(&2, String, sb), 0), U32.min((na - h : U32), (nb - h : U32)))
  List.concat(&2, df.P, [df.diag(U32.to_nat(h), (h - 1 : U32), 0, 0, xa, xb, []), df.map(df.mid.pairs(df.mid(sa, sb, h, t)), h, xa, xb),
    df.diag(U32.to_nat(t), (t - 1 : U32), (na - t : U32), (nb - t : U32), xa, xb, [])])

# The script ------------------------------------------------------------------
#
# An op: a line kept (" "), dropped ("-") or added ("+"), its text, and where
# it stands in the old and the new text before it.

type df.Op is Data:
  df.Op{s: String, x: String, i: U32, j: U32}

def df.run(n: Nat, +s: String, +xs: I.im.M<String>, +k: U32, +i: U32, +j: U32, +di: U32, +dj: U32, acc: List<&2, df.Op>) -> List<&2, df.Op>:
  match n:
    case 0n:
      acc
    case 1n+f:
      df.run(f, s, xs, (k + 1 : U32), (i + di : U32), (j + dj : U32), di, dj, df.Op{s, df.at(xs, k), i, j} <> acc)

# the ops, newest first: in each gap before a pair (p, q) the old lines from
# i dropped, then the new from j added, then the pair kept
def df.ops(ps: List<&2, df.P>, +a: I.im.M<String>, +b: I.im.M<String>, +na: U32, +nb: U32, +i: U32, +j: U32, acc: List<&2, df.Op>) -> List<&2, df.Op>:
  match ps:
    case []:
      +dels = df.run(U32.to_nat((na - i : U32)), "-", a, i, i, j, 1, 0, acc)
      df.run(U32.to_nat((nb - j : U32)), "+", b, j, na, j, 0, 1, dels)
    case df.P{+p, +q} <> t:
      +dels = df.run(U32.to_nat((p - i : U32)), "-", a, i, i, j, 1, 0, acc)
      +adds = df.run(U32.to_nat((q - j : U32)), "+", b, j, p, j, 0, 1, dels)
      df.ops(t, a, b, na, nb, (p + 1 : U32), (q + 1 : U32), df.Op{" ", df.at(a, p), p, q} <> adds)

# Hunks -------------------------------------------------------------------------

def df.op.s(o: df.Op) -> String:
  match o:
    case df.Op{s, x, i, j}:
      s

def df.hunk.add(+k: U32, hs: List<&2, df.P>) -> List<&2, df.P>:
  match hs:
    case df.P{+lo, +hi} <> +t:
      Bool.pick(List<&2, df.P>, U32.is_le((k - hi : U32), (2 * df.context() : U32)), df.P{lo, (k + 1 : U32)} <> t, df.P{k, (k + 1 : U32)} <> df.P{lo, hi} <> t)
    case []:
      [df.P{k, (k + 1 : U32)}]

# the runs of changes, as [lo, hi) over the ops, those 2*CONTEXT or less apart
# joined; ops oldest first, k their index
def df.hunks(os: List<&2, df.Op>, +k: U32, +hs: List<&2, df.P>) -> List<&2, df.P>:
  match os:
    case []:
      List.reverse(&2, df.P, hs)
    case +o <> t:
      df.hunks(t, (k + 1 : U32), Bool.pick(List<&2, df.P>, String.eq(df.op.s(o), " "), hs, df.hunk.add(k, hs)))

def df.chomp(+x: String) -> String:
  Bool.pick(String, String.ends_with(x, "\n"), String.reverse(String.drop(String.reverse(x), 1n)), x)

def df.count(os: List<&2, df.Op>, +not: String) -> U32:
  match os:
    case []:
      0
    case +o <> t:
      (Bool.pick(U32, String.eq(df.op.s(o), not), 0, 1) + df.count(t, not) : U32)

def df.body(os: List<&2, df.Op>) -> List<&2, String>:
  match os:
    case []:
      []
    case df.Op{s, +x, i, j} <> t:
      ("\n" ++ s ++ df.chomp(x)) <> df.body(t)

def df.first(os: List<&2, df.Op>) -> df.P:
  match os:
    case []:
      df.P{0, 0}
    case df.Op{s, x, i, j} <> t:
      df.P{i, j}

def df.head(+run: List<&2, df.Op>, pos: df.P) -> String:
  match pos:
    case df.P{+i, +j}:
      +olds = df.count(run, "+")
      +news = df.count(run, "-")
      "\n@@ -" ++ U32.show((i + Bool.pick(U32, U32.is_eq(olds, 0), 0, 1) : U32)) ++ "," ++ U32.show(olds) ++ " +" ++ U32.show((j + Bool.pick(U32, U32.is_eq(news, 0), 0, 1) : U32)) ++ "," ++ U32.show(news) ++ " @@"

def df.slice(+os: List<&2, df.Op>, +a: U32, +b: U32) -> List<&2, df.Op>:
  List.take(&2, df.Op, List.drop(&2, df.Op, os, U32.to_nat(a)), U32.to_nat((b - a : U32)))

def df.render(hs: List<&2, df.P>, +os: List<&2, df.Op>, +n: U32) -> List<&2, String>:
  match hs:
    case []:
      []
    case df.P{+lo, +hi} <> t:
      +a = Bool.pick(U32, U32.is_lt(lo, df.context()), 0, (lo - df.context() : U32))
      +b = U32.min((hi + df.context() : U32), n)
      +run = df.slice(os, a, b)
      (df.head(run, df.first(run)) ++ df.concat(df.body(run))) <> df.render(t, os, n)

# a file's change, `file` its name as shown (not yet clipped)
def df.diff(+file: String, +was: String, +now: String) -> String:
  +la = df.lines(was)
  +lb = df.lines(now)
  +a = df.arr(la)
  +b = df.arr(lb)
  +na = U32.from_nat(List.length(&2, String, la))
  +nb = U32.from_nat(List.length(&2, String, lb))
  +os = List.reverse(&2, df.Op, df.ops(df.pairs(la, lb), a, b, na, nb, 0, 0, []))
  +hs = df.hunks(os, 0, [])
  Bool.pick(String, List.is_empty(&2, df.P, hs), file ++ " is unchanged.",
    "--- " ++ file ++ "\n+++ " ++ file ++ df.concat(df.render(hs, os, U32.from_nat(List.length(&2, df.Op, os)))))
