import Base
import ../Sys.bend as S
import ../Clock.bend as Ck

# Local: what bend-ops reads and writes on this machine (2026-10-14, the
# plan's Phase 0: all logic in Bend, the shell a thin shim).
#
#   lcl.run SECS PROG ARGS    `timeout SECS PROG ARGS..` with no shell between: the status, stdout
#                             and stderr apart (124: the time ran out, 127: PROG did not start)
#   lcl.find DIR ARGS         `find DIR ARGS -printf '%P\0'`: the paths under DIR, sorted bytewise
#   lcl.files DIR, lcl.ls DIR every file under DIR; the entries of DIR itself
#   lcl.stat PATH             `stat -c '%s %Y'`: size and mtime (no U32 limit, unlike File.size)
#   lcl.sums DIR NAMES        `sha256sum`: each file's sha256, as LclSum{hash, name}
#   lcl.sha.parse TEXT        sha256sum's lines (`HASH  NAME`, `HASH *NAME`), names by their base
#   lcl.mark PATH LINE        a marker file: one line behind its UTC-6 stamp
#   lcl.pulled.of LOG         the checkpoints a chain log says it pulled (`[stamp] pulled NAME`)
#
# Every name starts with `lcl.`.  The pure helpers (parse, compare, sort) are
# tested on run 3's files in bend/tests/ops.bend.

# Processes -------------------------------------------------------------------------

type LclOut is Data:
  LclOut{status: U32, out: List<&2, U32>, err: List<&2, U32>}

def lcl.status(+o: LclOut) -> U32:
  match o:
    case LclOut{s, out, err}:
      s

def lcl.out(+o: LclOut) -> List<&2, U32>:
  match o:
    case LclOut{s, out, err}:
      out

def lcl.err(+o: LclOut) -> List<&2, U32>:
  match o:
    case LclOut{s, out, err}:
      err

def lcl.ok(+o: LclOut) -> Bool:
  U32.is_eq(lcl.status(o), 0)

# Process.run's failures: its own deadline (ETIMEDOUT) reads as timeout's
# 124, too much output (EFBIG) as 125, a program that did not start as 127
def lcl.fail.code(+code: U32) -> U32:
  Bool.pick(U32, U32.is_eq(code, 110), 124, Bool.pick(U32, U32.is_eq(code, 27), 125, 127))

def lcl.run.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(LclOut):
  match r:
    case Done{(code, (out, err))}:
      IO.pure(LclOut, LclOut{code, S.b(out), S.b(err)})
    case Fail{(+code, msg)}:
      IO.pure(LclOut, LclOut{lcl.fail.code(code), Nil{}, S.b(msg)})

def lcl.run(+secs: U32, prog: String, args: List<String>) -> IO(LclOut):
  do IO<LclOut>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("timeout", List.append(&1, String, [U32.show(secs), prog], args), "", S.cap.bytes(), U32.mul(U32.add(secs, 30), 1000))
    lcl.run.got(r)

# Text ---------------------------------------------------------------------------------

def lcl.blank(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 13), U32.is_eq(c, 10)))

def lcl.words.put(+w: List<&2, U32>, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(w), 0n), ws, List.reverse(&2, U32, w) <> ws)

def lcl.words.go(xs: List<&2, U32>, +cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, lcl.words.put(cur, acc))
    case +c <> t:
      +sp = lcl.blank(c)
      lcl.words.go(t, Bool.pick(List<&2, U32>, sp, Nil{}, c <> cur), Bool.pick(List<&2, List<&2, U32>>, sp, lcl.words.put(cur, acc), acc))

# the words of a text, as the shell splits them (spaces, tabs, newlines)
def lcl.words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  lcl.words.go(xs, Nil{}, Nil{})

def lcl.nth(xs: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, U32>:
  Maybe.default(&2, List<&2, U32>, List.get(&2, List<&2, U32>, xs, n), Nil{})

def lcl.nat(+xs: List<&2, U32>) -> Maybe<&2, Nat>:
  Bool.pick(Maybe<&2, Nat>, Nat.is_eq(S.len(xs), 0n), None{}, Nat.read(S.str(xs)))

# bytewise order (an empty list first), as `LC_ALL=C sort` puts lines
def lcl.hd(+xs: List<&2, U32>) -> U32:
  match xs:
    case Nil{}:
      0
    case +h <> t:
      U32.add(h, 1)

def lcl.le.go(a: List<&2, U32>, b: List<&2, U32>, lt: Bool, gt: Bool) -> Bool:
  match a b lt gt:
    case Nil{} _ _ _:
      True{}
    case _ Nil{} _ _:
      False{}
    case _ _ True{} _:
      True{}
    case _ _ False{} True{}:
      False{}
    case x <> +xt y <> +yt False{} False{}:
      lcl.le.go(xt, yt, U32.is_lt(lcl.hd(xt), lcl.hd(yt)), U32.is_lt(lcl.hd(yt), lcl.hd(xt)))

def lcl.le(+a: List<&2, U32>, +b: List<&2, U32>) -> Bool:
  lcl.le.go(a, b, U32.is_lt(lcl.hd(a), lcl.hd(b)), U32.is_lt(lcl.hd(b), lcl.hd(a)))

def lcl.le.of(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  +x = a
  +y = b
  lcl.le(x, y)

def lcl.sort(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  List.sort(~List<&2, U32>, ~lcl.le.of, xs)

# Listing ------------------------------------------------------------------------------

def lcl.find.got(+o: LclOut) -> Maybe<&2, List<&2, List<&2, U32>>>:
  Bool.pick(Maybe<&2, List<&2, List<&2, U32>>>, lcl.ok(o), Some{lcl.sort(S.split(lcl.out(o), 0))}, None{})

# the paths `find DIR ARGS..` prints, relative to DIR, sorted bytewise
# (None: find failed, e.g. DIR is missing)
def lcl.find(+dir: String, args: List<String>) -> IO(Maybe<&2, List<&2, List<&2, U32>>>):
  do IO<Maybe<&2, List<&2, List<&2, U32>>>>:
    +o : LclOut <- lcl.run(600, "find", List.append(&1, String, dir <> args, ["-printf", "%P\\0"]))
    return lcl.find.got(o)

# every file under DIR (paths relative to it)
def lcl.files(+dir: String) -> IO(Maybe<&2, List<&2, List<&2, U32>>>):
  lcl.find(dir, ["-type", "f"])

# the entries of DIR itself
def lcl.ls(+dir: String) -> IO(Maybe<&2, List<&2, List<&2, U32>>>):
  lcl.find(dir, ["-mindepth", "1", "-maxdepth", "1"])

# Files ---------------------------------------------------------------------------------

type LclSt is Data:
  LclSt{size: Nat, mtime: Nat}

def lcl.st.size(+s: LclSt) -> Nat:
  match s:
    case LclSt{z, m}:
      z

def lcl.st.mtime(+s: LclSt) -> Nat:
  match s:
    case LclSt{z, m}:
      m

def lcl.stat.of2(a: Maybe<&2, Nat>, b: Maybe<&2, Nat>) -> Maybe<&2, LclSt>:
  match a b:
    case Some{z} Some{m}:
      Some{LclSt{z, m}}
    case _ _:
      None{}

# `stat -c '%s %Y'`'s answer: size and mtime
def lcl.stat.of(+o: LclOut) -> Maybe<&2, LclSt>:
  +ws = lcl.words(lcl.out(o))
  Bool.pick(Maybe<&2, LclSt>, Bool.and(lcl.ok(o), Nat.is_eq(List.length(&2, List<&2, U32>, ws), 2n)),
    lcl.stat.of2(lcl.nat(lcl.nth(ws, 0n)), lcl.nat(lcl.nth(ws, 1n))), None{})

def lcl.stat(+path: String) -> IO(Maybe<&2, LclSt>):
  do IO<Maybe<&2, LclSt>>:
    +o : LclOut <- lcl.run(60, "stat", ["-c", "%s %Y", "--", path])
    return lcl.stat.of(o)

def lcl.now() -> IO(Nat):
  do IO<Nat>:
    +t : Nat <- IO.time()
    return Nat.div(t, U32.to_nat(1000))

def lcl.age.of(+now: Nat, m: Maybe<&2, LclSt>) -> Maybe<&2, Nat>:
  match m:
    case Some{+s}:
      Some{Nat.sub(now, lcl.st.mtime(s))}
    case None{}:
      None{}

# seconds since PATH last changed (None: it is not there)
def lcl.age(+path: String) -> IO(Maybe<&2, Nat>):
  do IO<Maybe<&2, Nat>>:
    m : Maybe<&2, LclSt> <- lcl.stat(path)
    +now : Nat <- lcl.now()
    return lcl.age.of(now, m)

# a pulled file is here and whole: DIR/NAME, and no rsync partial of it
# (--partial-dir=.partial keeps one there until the transfer ends)
def lcl.have(+dir: String, +name: String) -> IO(Bool):
  do IO<Bool>:
    a : Bool <- S.exists(dir ++ "/" ++ name)
    p : Bool <- S.exists(dir ++ "/.partial/" ++ name)
    return Bool.and(a, Bool.not(p))

# Markers -------------------------------------------------------------------------------
#
# A marker is a small file whose presence is the state (DESTROYED, REFUSED,
# CREDIT_LOW, HOLD, CONTINUED, ...): one line, stamped in UTC-6.

def lcl.mark.line(+ms: Nat, +line: String) -> List<&2, U32>:
  S.b(Ck.stamp(ms) ++ " " ++ line ++ "\n")

def lcl.mark(+path: String, +line: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.time()
    S.write(path, lcl.mark.line(t, line))

def lcl.marked(+path: String) -> IO(Bool):
  S.exists(path)

def lcl.unmark(+path: String) -> IO(Unit):
  S.rm(path)

# a marker holding an epoch (HOLD: the time before which nothing is destroyed)
def lcl.epoch.of(+xs: List<&2, U32>) -> Maybe<&2, Nat>:
  lcl.nat(lcl.nth(lcl.words(xs), 0n))

def lcl.epoch(+path: String) -> IO(Maybe<&2, Nat>):
  do IO<Maybe<&2, Nat>>:
    xs : List<&2, U32> <- S.read(path)
    return lcl.epoch.of(xs)

# Checksums -----------------------------------------------------------------------------

type LclSum is Data:
  LclSum{hash: List<&2, U32>, name: List<&2, U32>}

def lcl.sum.hash(+s: LclSum) -> List<&2, U32>:
  match s:
    case LclSum{h, n}:
      h

def lcl.sum.name(+s: LclSum) -> List<&2, U32>:
  match s:
    case LclSum{h, n}:
      n

def lcl.hex(+c: U32) -> Bool:
  Bool.or(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), Bool.and(U32.is_le(97, c), U32.is_le(c, 102)))

def lcl.hex.all(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(lcl.hex(c), lcl.hex.all(t))

def lcl.at(+xs: List<&2, U32>, +i: Nat) -> U32:
  Maybe.default(&2, U32, List.get(&2, U32, xs, i), 0)

# one line of sha256sum: 64 hex digits, a space, a space or `*`, the name
# (its last component: a listing made with paths compares with one made in
# the directory)
def lcl.sha.line.of(+l: List<&2, U32>) -> Maybe<&2, LclSum>:
  +h = List.take(&2, U32, l, 64n)
  +name = S.base.go(List.drop(&2, U32, l, 66n), Nil{})
  +sep = lcl.at(l, 65n)
  +ok = Bool.and(Bool.and(Nat.is_eq(S.len(h), 64n), lcl.hex.all(h)),
    Bool.and(Bool.and(U32.is_eq(lcl.at(l, 64n), 32), Bool.or(U32.is_eq(sep, 32), U32.is_eq(sep, 42))), Nat.is_ne(S.len(name), 0n)))
  Bool.pick(Maybe<&2, LclSum>, ok, Some{LclSum{h, name}}, None{})

def lcl.sha.put(m: Maybe<&2, LclSum>, rest: List<&2, LclSum>) -> List<&2, LclSum>:
  match m:
    case Some{s}:
      s <> rest
    case None{}:
      rest

def lcl.sha.lines(ls: List<&2, List<&2, U32>>) -> List<&2, LclSum>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      lcl.sha.put(lcl.sha.line.of(l), lcl.sha.lines(t))

# sha256sum's output, a sum a line (other lines, a banner, an error, are passed over)
def lcl.sha.parse(+xs: List<&2, U32>) -> List<&2, LclSum>:
  lcl.sha.lines(S.split.lines(xs))

def lcl.sha.line(+s: LclSum) -> List<&2, U32>:
  List.concat(&2, U32, [lcl.sum.hash(s), [32, 32], lcl.sum.name(s), [10]])

# the listing back as sha256sum writes it (sha256.txt, sha256.box.txt)
def lcl.sha.text(ss: List<&2, LclSum>) -> List<&2, U32>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      List.append(&2, U32, lcl.sha.line(s), lcl.sha.text(t))

def lcl.sum.eq(+a: LclSum, +b: LclSum) -> Bool:
  Bool.and(S.eq(lcl.sum.hash(a), lcl.sum.hash(b)), S.eq(lcl.sum.name(a), lcl.sum.name(b)))

def lcl.sha.has(ss: List<&2, LclSum>, +s: LclSum) -> Bool:
  match ss:
    case Nil{}:
      False{}
    case +x <> t:
      Bool.or(lcl.sum.eq(x, s), lcl.sha.has(t, s))

# the names in `box` without the same line in `here` (a copy missing here,
# or one whose sha256 differs): fp-chain's `grep -vxF -f sha256.txt`
def lcl.sha.unmatched(box: List<&2, LclSum>, +here: List<&2, LclSum>) -> List<&2, List<&2, U32>>:
  match box:
    case Nil{}:
      Nil{}
    case +s <> t:
      +rest = lcl.sha.unmatched(t, here)
      Bool.pick(List<&2, List<&2, U32>>, lcl.sha.has(here, s), rest, lcl.sum.name(s) <> rest)

def lcl.sha.find(ss: List<&2, LclSum>, +name: List<&2, U32>, found: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      found
    case +s <> t:
      lcl.sha.find(t, name, Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(lcl.sum.name(s), name), Some{lcl.sum.hash(s)}, found))

# the sha256 a listing gives a name (its last line for it)
def lcl.sha.of(ss: List<&2, LclSum>, +name: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  lcl.sha.find(ss, name, None{})

def lcl.paths(+dir: String, ns: List<&2, List<&2, U32>>) -> List<String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      (dir ++ "/" ++ S.str(n)) <> lcl.paths(dir, t)

# the sha256 of each of DIR's NAMES that is there (one that is not is left out)
def lcl.sums(+dir: String, +names: List<&2, List<&2, U32>>) -> IO(List<&2, LclSum>):
  match names:
    case Nil{}:
      IO.pure(List<&2, LclSum>, Nil{})
    case +n <> t:
      do IO<List<&2, LclSum>>:
        +o : LclOut <- lcl.run(86400, "sha256sum", "--" <> lcl.paths(dir, n <> t))
        return lcl.sha.parse(lcl.out(o))

def lcl.sha256.of(ss: List<&2, LclSum>) -> Maybe<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      None{}
    case s <> t:
      Some{lcl.sum.hash(s)}

# one file's sha256 (None: it cannot be read)
def lcl.sha256(+path: String) -> IO(Maybe<&2, List<&2, U32>>):
  do IO<Maybe<&2, List<&2, U32>>>:
    +o : LclOut <- lcl.run(86400, "sha256sum", ["--", path])
    return lcl.sha256.of(lcl.sha.parse(lcl.out(o)))

# The chain's log -----------------------------------------------------------------------

def lcl.pulled.at(+l: List<&2, U32>, m: Maybe<&2, Nat>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      None{}
    case Some{+k}:
      +name = List.drop(&2, U32, l, Nat.add(k, 9n))
      Bool.pick(Maybe<&2, List<&2, U32>>, Bool.and(Bool.and(S.head.is(l, 91), Nat.is_ne(S.len(name), 0n)),
        Bool.not(S.infix(name, [32]))), Some{name}, None{})

def lcl.pulled.put(m: Maybe<&2, List<&2, U32>>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match m:
    case Some{n}:
      n <> rest
    case None{}:
      rest

def lcl.pulled.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      lcl.pulled.put(lcl.pulled.at(l, S.find(l, S.b("] pulled "), 0n)), lcl.pulled.lines(t))

# the names a chain log says it pulled, in order: its `[stamp] pulled NAME`
# lines (not `pulled: N checkpoints ...`, nor another tool's `move: pulled`)
def lcl.pulled.of(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  lcl.pulled.lines(S.split.lines(xs))
