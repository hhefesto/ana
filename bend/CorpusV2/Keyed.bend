import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Json.bend as J
import ../Clock.bend as Ck

# keyed-order: a stream's records in sha256-keyed order (2026-10-15, the plan
# "all logic in Bend", Phase 4; it replaces every `shuf --random-source=<(yes
# STR)` of the run scripts, a change the user accepted).
#
#   bend-corpus-v2 keyed-order nul|lines SALT [N] IN OUT
#
# Meaning.  A record is a NUL pair (id NUL text NUL) or a line (its newline
# not counted; a last line without one is a line).  Its id is the pair's
# first field, or the line's JSON "id" member when the line is an object led
# by one (`{"id": "...", ...}`, the id decoded as json.loads would), else the
# whole line.  OUT holds IN's records ordered by (sha256(SALT ++ NUL ++ id)
# as hex, then the record's own bytes): the first N of them with N, all of
# them without.  A pair moves whole; every line in OUT ends with a newline.
# The order depends on SALT and the records only, never on IN's order, so a
# sample of N is the same sample however IN was shuffled.
#
# The refinement.  One pass writes a spool record a record, `KEY TAB` and
# the record (`KEY TAB IDLEN TAB id text NUL` for a pair: the id's length
# says where it ends; `KEY TAB line NL` for a line), spawned `LC_ALL=C sort
# [-z]` orders the spool bytewise, and a second pass strips the keys.  The
# spool and its sorted copy sit next to OUT (OUT.kor-spool, OUT.kor-sorted)
# and are removed at the end; memory is a chunk plus the longest record.
#
# Every def is prefixed `kor.`.

# Keys and spool records (pure) -------------------------------------------------

def kor.key(+salt: List<&2, U32>, +id: List<&2, U32>) -> String:
  H.sha256(List.append(&2, U32, salt, 0 <> id))

def kor.nul.rec(+key: String, +id: List<&2, U32>, +t: List<&2, U32>) -> List<&2, U32>:
  List.concat(&2, U32, [S.b(key), [9], S.b(Nat.show(S.len(id))), [9], id, t, [0]])

def kor.line.rec(+key: String, +l: List<&2, U32>) -> List<&2, U32>:
  List.concat(&2, U32, [S.b(key), [9], l, [10]])

def kor.line.id.of(p: J.Pr, +l: List<&2, U32>) -> List<&2, U32>:
  match p:
    case J.Pok{+k, +v, r}:
      Bool.pick(List<&2, U32>, S.eq(k, S.b("id")), v, l)
    case J.Pbad{}:
      l

# a line's id: its JSON "id" member when the line is an object led by one,
# else the line itself
def kor.line.id(+l: List<&2, U32>) -> List<&2, U32>:
  kor.line.id.of(J.first.at(l), l)

def kor.isd(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def kor.hd.isd(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      kor.isd(c)

# the leading digits as a number, and what follows the byte after them (the
# tab); `at` says whether xs leads with a digit (Bool.pick would evaluate
# the recursion on both branches)
def kor.digits.go(xs: List<&2, U32>, +acc: Nat, at: Bool) -> Nat & List<&2, U32>:
  match xs at:
    case Nil{} _:
      (acc, Nil{})
    case +c <> +t True{}:
      kor.digits.go(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(c, 48))), kor.hd.isd(t))
    case c <> t False{}:
      (acc, t)

def kor.digits(+xs: List<&2, U32>, +acc: Nat) -> Nat & List<&2, U32>:
  kor.digits.go(xs, acc, kor.hd.isd(xs))

# a sorted spool record back as the pair it holds (id NUL text NUL)
def kor.nul.back.of(r: Nat & List<&2, U32>) -> List<&2, U32>:
  (+n, +rest) = r
  List.concat(&2, U32, [List.take(&2, U32, rest, n), [0], List.drop(&2, U32, rest, n), [0]])

def kor.nul.back(+rec: List<&2, U32>) -> List<&2, U32>:
  kor.nul.back.of(kor.digits(List.drop(&2, U32, rec, 65n), 0n))

def kor.line.back(+rec: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, List.drop(&2, U32, rec, 65n), [10])

# Settings ---------------------------------------------------------------------------

def kor.fuel() -> Nat:
  U32.to_nat(4294967295)

# the directory a path is in ("." for a bare name)
def kor.dir(+p: String) -> String:
  +d = S.parent(p)
  Bool.pick(String, String.eq(d, p), ".", Bool.pick(String, String.is_empty(d), "/", d))

# 0: a NUL pair a record, 1: a line, 2: neither
def kor.mode(+m: String) -> Nat:
  Bool.pick(Nat, String.eq(m, "nul"), 0n, Bool.pick(Nat, String.eq(m, "lines"), 1n, 2n))

# Pass 1: the spool -------------------------------------------------------------------

type KorSp is Type:
  KorSp{r: S.Rd, o: File, n: Nat, more: Bool, odd: Bool}

def kor.sp.pair(+salt: List<&2, U32>, o: File, +n: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(KorSp):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(KorSp, KorSp{r, o, n, False{}, True{}})
    case Some{+t}:
      do IO<KorSp>:
        o2 : File <- S.emit(o, kor.nul.rec(kor.key(salt, id), id, t))
        return KorSp{r, o2, 1n+n, True{}, False{}}

def kor.sp.rec(m: Maybe<&2, List<&2, U32>>, lines: Bool, +salt: List<&2, U32>, r: S.Rd, o: File, +n: Nat) -> IO(KorSp):
  match m lines:
    case None{} _:
      IO.pure(KorSp, KorSp{r, o, n, False{}, False{}})
    case Some{+l} True{}:
      do IO<KorSp>:
        o2 : File <- S.emit(o, kor.line.rec(kor.key(salt, kor.line.id(l)), l))
        return KorSp{r, o2, 1n+n, True{}, False{}}
    case Some{+id} False{}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, KorSp, S.Rd.next(r), kor.sp.pair(salt, o, n, id))

def kor.sp.got(lines: Bool, +salt: List<&2, U32>, o: File, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(KorSp):
  (r, m) = x
  kor.sp.rec(m, lines, salt, r, o, n)

def kor.sp.step(lines: Bool, +salt: List<&2, U32>, s: KorSp) -> IO(KorSp):
  match s:
    case KorSp{r, o, n, m, odd}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, KorSp, S.Rd.next(r), kor.sp.got(lines, salt, o, n))

def kor.sp.go(fuel: Nat, +lines: Bool, +salt: List<&2, U32>, s: KorSp) -> IO(KorSp):
  match fuel s:
    case 1n+f KorSp{r, o, n, True{}, odd}:
      IO.bind(KorSp, KorSp, kor.sp.step(lines, salt, KorSp{r, o, n, True{}, odd}), kor.sp.go(f, lines, salt))
    case _ s2:
      IO.pure(KorSp, s2)

def kor.sp.fin(+inp: String, s: KorSp) -> IO(Nat):
  match s:
    case KorSp{r, o, +n, m, odd}:
      do IO<Nat>:
        S.Rd.close(r)
        File.close(o)
        Bool.pick(IO(Nat), odd, IO.die(Nat, 1, "keyed-order: " ++ inp ++ " ends with an id that has no text (an odd number of NUL fields)"), IO.pure(Nat, n))

# the spool written; the answer is the records read
def kor.spool(+lines: Bool, +salt: List<&2, U32>, +inp: String, +spool: String) -> IO(Nat):
  do IO<Nat>:
    r : S.Rd <- S.Rd.of(inp, Bool.pick(U32, lines, 10, 0))
    o : File <- IO.try(File, File.open(spool, "w"))
    s : KorSp <- kor.sp.go(kor.fuel(), lines, salt, KorSp{r, o, 0n, True{}, False{}})
    kor.sp.fin(inp, s)

# Pass 2: the keys stripped -------------------------------------------------------------

type KorBk is Type:
  KorBk{r: S.Rd, o: File, n: Nat, more: Bool}

def kor.bk.got(lines: Bool, o: File, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(KorBk):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(KorBk, KorBk{r, o, n, False{}})
    case Some{+rec}:
      do IO<KorBk>:
        o2 : File <- S.emit(o, Bool.pick(List<&2, U32>, lines, kor.line.back(rec), kor.nul.back(rec)))
        return KorBk{r, o2, 1n+n, True{}}

def kor.bk.step(lines: Bool, s: KorBk) -> IO(KorBk):
  match s:
    case KorBk{r, o, n, m}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, KorBk, S.Rd.next(r), kor.bk.got(lines, o, n))

# at most `left` records
def kor.bk.go(left: Nat, +lines: Bool, s: KorBk) -> IO(KorBk):
  match left s:
    case 1n+f KorBk{r, o, n, True{}}:
      IO.bind(KorBk, KorBk, kor.bk.step(lines, KorBk{r, o, n, True{}}), kor.bk.go(f, lines))
    case _ s2:
      IO.pure(KorBk, s2)

def kor.bk.fin(s: KorBk) -> IO(Nat):
  match s:
    case KorBk{r, o, n, m}:
      do IO<Nat>:
        S.Rd.close(r)
        File.close(o)
        return n

def kor.back(+lines: Bool, +sorted: String, +out: String, +take: Nat) -> IO(Nat):
  do IO<Nat>:
    r : S.Rd <- S.Rd.of(sorted, Bool.pick(U32, lines, 10, 0))
    o : File <- IO.try(File, File.open(out, "w"))
    s : KorBk <- kor.bk.go(take, lines, KorBk{r, o, 0n, True{}})
    kor.bk.fin(s)

# The order --------------------------------------------------------------------------------

def kor.sort.ok(+o: S.Out) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(S.Out.status(o), 0), IO.pure(Unit, Unit{}),
    IO.die(Unit, 1, "keyed-order: sort failed (exit " ++ U32.show(S.Out.status(o)) ++ "): " ++ S.str(S.lines.take(S.Out.text(o), 5n))))

# `LC_ALL=C sort [-z] -S 1G -T DIR -o SORTED SPOOL`: bytewise, whole records
def kor.sort(lines: Bool, +dir: String, +spool: String, +sorted: String) -> IO(Unit):
  z = Bool.pick(List<String>, lines, Nil{}, ["-z"])
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 2000000, "sort", List.append(&1, String, z, ["-S", "1G", "-T", dir, "-o", sorted, spool]), Nil{})
    kor.sort.ok(o)

# IN's records into OUT in keyed order, the first `take` of them; the
# answer is (records read, records written)
def kor.order(+lines: Bool, +salt: String, +take: Nat, +inp: String, +out: String) -> IO(Nat & Nat):
  +spool = out ++ ".kor-spool"
  +sorted = out ++ ".kor-sorted"
  do IO<Nat & Nat>:
    +n : Nat <- kor.spool(lines, S.b(salt), inp, spool)
    kor.sort(lines, kor.dir(out), spool, sorted)
    S.rm(spool)
    +w : Nat <- kor.back(lines, sorted, out, take)
    S.rm(sorted)
    return (n, w)

# Main -------------------------------------------------------------------------------------

def kor.say(r: Nat & Nat, +inp: String, +out: String) -> IO(Unit):
  (+n, +w) = r
  Ck.log("keyed-order: " ++ Nat.show(w) ++ " of " ++ Nat.show(n) ++ " records of " ++ inp ++ " into " ++ out)

def kor.run(mode: Nat, +salt: String, take: Maybe<&2, Nat>, +inp: String, +out: String) -> IO(Unit):
  match mode take:
    case 2n _:
      IO.die(Unit, 2, "keyed-order: the mode is nul or lines")
    case _ None{}:
      IO.die(Unit, 2, "keyed-order: N is not a number")
    case m Some{+k}:
      do IO<Unit>:
        r : Nat & Nat <- kor.order(Nat.is_eq(m, 1n), salt, k, inp, out)
        kor.say(r, inp, out)

def kor.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +m <> +salt <> +inp <> +out <> Nil{}:
      kor.run(kor.mode(m), salt, Some{kor.fuel()}, inp, out)
    case +m <> +salt <> +n <> +inp <> +out <> Nil{}:
      kor.run(kor.mode(m), salt, Nat.read(n), inp, out)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 keyed-order nul|lines SALT [N] IN OUT")

# The recipes' shared steps -----------------------------------------------------------------
#
# What bend/CorpusV2/{S2,ActSet,Steady,Recipes}.bend and bend/Box/Evals.bend
# take from the shell they replace: awk's fields, `tr -cd '\0' | wc -c`,
# `cat A B > C`, `ln -sfn`, $PWD, a stamped log line, and the deploy tool a
# recipe runs (`$DEPLOY TOOL ARGS`).

# a line's fields as awk's default FS cuts them (runs of blanks)
def kor.blank(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 10), U32.is_eq(c, 13)))

def kor.words.put(+w: List<&2, U32>, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(w), 0n), ws, List.reverse(&2, U32, w) <> ws)

def kor.words.go(xs: List<&2, U32>, +cur: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, kor.words.put(cur, acc))
    case +c <> t:
      +sp = kor.blank(c)
      kor.words.go(t, Bool.pick(List<&2, U32>, sp, Nil{}, c <> cur), Bool.pick(List<&2, List<&2, U32>>, sp, kor.words.put(cur, acc), acc))

def kor.words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  kor.words.go(xs, Nil{}, Nil{})

# field i (0-based; awk's $(i+1)), empty past the last
def kor.field(xs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  Maybe.default(&2, List<&2, U32>, List.get(&2, List<&2, U32>, xs, i), Nil{})

def kor.nat.or(m: Maybe<&2, Nat>) -> Nat:
  Maybe.default(&2, Nat, m, 0n)

# a decimal as a number (0 when it is not one, as awk's `+ 0`)
def kor.nat(+xs: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Nat.is_eq(S.len(xs), 0n), 0n, kor.nat.or(Nat.read(S.str(xs))))

# `[stamp UTC-6] TOOL: MSG` on stderr (flushed a line at a time)
def kor.log(+tool: String, +msg: String) -> IO(Unit):
  Ck.log(tool ++ ": " ++ msg)

def kor.die(+tool: String, +msg: String) -> IO(Unit):
  do IO<Unit>:
    kor.log(tool, msg)
    IO.die(Unit, 1, tool ++ ": " ++ msg)

# bytes c in a file, a chunk at a time (`tr -cd '\0' < F | wc -c`); 0 when
# it cannot be opened
type KorCn is Type:
  KorCn{f: File, c: U32, n: Nat, go: Bool}

def kor.cnt(xs: List<&2, U32>, +c: U32, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      kor.cnt(t, c, Bool.pick(Nat, U32.is_eq(h, c), 1n+acc, acc))

def kor.cn.got(+c: U32, +n: Nat, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(KorCn):
  (f, x) = r
  do IO<KorCn>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return KorCn{f, c, kor.cnt(xs, c, n), Bool.not(Nat.is_eq(S.len(xs), 0n))}

def kor.cn.step(s: KorCn) -> IO(KorCn):
  match s:
    case KorCn{f, +c, +n, g}:
      do IO<KorCn>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, S.chunk())
        kor.cn.got(c, n, r)

def kor.cn.go(fuel: Nat, s: KorCn) -> IO(Nat):
  match fuel s:
    case 1n+p KorCn{f, c, n, True{}}:
      IO.bind(KorCn, Nat, kor.cn.step(KorCn{f, c, n, True{}}), kor.cn.go(p))
    case _ KorCn{f, c, n, g}:
      do IO<Nat>:
        File.close(f)
        return n

def kor.count.opened(+c: U32, r: Result<&1, &1, U32 & String, File>) -> IO(Nat):
  match r:
    case Fail{e}:
      IO.pure(Nat, 0n)
    case Done{f}:
      kor.cn.go(kor.fuel(), KorCn{f, c, 0n, True{}})

def kor.count(+path: String, +c: U32) -> IO(Nat):
  do IO<Nat>:
    r : Result<&1, &1, U32 & String, File> <- File.open(path, "r")
    kor.count.opened(c, r)

# a NUL file's (id, text) pairs
def kor.pairs(+path: String) -> IO(Nat):
  do IO<Nat>:
    +n : Nat <- kor.count(path, 0)
    return Nat.div(n, 2n)

# `cat SRC... > DST` (`>> DST` when append), a chunk at a time; a source
# that cannot be opened stops the tool
type KorCp is Type:
  KorCp{f: File, o: File, go: Bool}

def kor.cp.got(o: File, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(KorCp):
  (f, x) = r
  do IO<KorCp>:
    +xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    o2 : File <- S.emit(o, xs)
    return KorCp{f, o2, Bool.not(Nat.is_eq(S.len(xs), 0n))}

def kor.cp.step(s: KorCp) -> IO(KorCp):
  match s:
    case KorCp{f, o, g}:
      do IO<KorCp>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, S.chunk())
        kor.cp.got(o, r)

def kor.cp.go(fuel: Nat, s: KorCp) -> IO(File):
  match fuel s:
    case 1n+p KorCp{f, o, True{}}:
      IO.bind(KorCp, File, kor.cp.step(KorCp{f, o, True{}}), kor.cp.go(p))
    case _ KorCp{f, o, g}:
      do IO<File>:
        File.close(f)
        return o

def kor.cp.one(+src: String, o: File) -> IO(File):
  do IO<File>:
    f : File <- IO.try(File, File.open(src, "r"))
    kor.cp.go(kor.fuel(), KorCp{f, o, True{}})

def kor.cp.all(srcs: List<&2, String>, o: File) -> IO(File):
  match srcs:
    case Nil{}:
      IO.pure(File, o)
    case +s <> t:
      IO.bind(File, File, kor.cp.one(s, o), kor.cp.all(t))

def kor.cat.to(srcs: List<&2, String>, +dst: String, append: Bool) -> IO(Unit):
  do IO<Unit>:
    o : File <- IO.try(File, File.open(dst, Bool.pick(String, append, "a", "w")))
    o2 : File <- kor.cp.all(srcs, o)
    File.close(o2)

def kor.cat(srcs: List<&2, String>, +dst: String) -> IO(Unit):
  kor.cat.to(srcs, dst, False{})

# the files of a list that exist
def kor.existing(ps: List<&2, String>) -> IO(List<&2, String>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +p <> t:
      do IO<List<&2, String>>:
        ok : Bool <- S.exists(p)
        +rest : List<&2, String> <- kor.existing(t)
        return Bool.pick(List<&2, String>, ok, p <> rest, rest)

# `ln -sfn TARGET LINK`
def kor.ln(+target: String, +link: String) -> IO(Unit):
  do IO<Unit>:
    o : List<&2, U32> <- S.must("ln -sfn " ++ link, "ln", ["-sfn", target, link])
    return Unit{}

# $PWD (the directory the shell started us in), else realpath .
def kor.pwd() -> IO(String):
  do IO<String>:
    +p : String <- S.env("PWD", "")
    r : String <- S.realpath(".")
    return Bool.pick(String, String.is_empty(p), r, p)

# `readlink -f P`
def kor.resolve(+p: String) -> IO(String):
  do IO<String>:
    o : List<&2, U32> <- S.must("readlink -f " ++ p, "readlink", ["-f", p])
    return S.str(S.chomp(o))

def kor.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> kor.l1(t)

def kor.l2(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> kor.l2(t)

def kor.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      S.str(x) <> kor.strs(t)

# The deploy tool: `$DEPLOY TOOL ARGS..` ($DEPLOY a command line: its
# words), d when DEPLOY is unset or empty
def kor.deploy.of(+v: String, +d: List<&2, String>) -> List<&2, String>:
  Bool.pick(List<&2, String>, String.is_empty(v), d, kor.strs(kor.words(S.b(v))))

def kor.deploy(+d: List<&2, String>) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    v : String <- S.env("DEPLOY", "")
    return kor.deploy.of(v, d)

def kor.hd(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      "true"
    case x <> t:
      x

def kor.tl(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      t

# `ENV.. $D TOOL ARGS > LOG 2>&1`: its exit status
def kor.tool.log(+d: List<&2, String>, env: List<String>, +tool: String, args: List<&2, String>, +log: String) -> IO(U32):
  S.run.log(".", env, 2000000, kor.hd(d), kor.l1(List.append(&2, String, kor.tl(d), tool <> args)), log)

# `ENV.. $D TOOL ARGS 2>&1`: its status and output
def kor.tool.run(+d: List<&2, String>, env: List<String>, +tool: String, args: List<&2, String>) -> IO(S.Out):
  S.run(".", env, 2000000, kor.hd(d), kor.l1(List.append(&2, String, kor.tl(d), tool <> args)), Nil{})

# The command line a deploy tool runs as: `$DEPLOY TOOL` when DEPLOY is set
# (a command line: its words), else bend-TOOL when it is on $PATH (`nix run
# .#deploy -- corpus-v2 ...` puts every tool there), else `nix run .#deploy
# -- TOOL` (the scripts' own default)
def kor.runner.of(+v: String, m: Maybe<&2, String>, +tool: String) -> List<&2, String>:
  match m:
    case Some{p}:
      Bool.pick(List<&2, String>, String.is_empty(v), [p], List.append(&2, String, kor.strs(kor.words(S.b(v))), [tool]))
    case None{}:
      Bool.pick(List<&2, String>, String.is_empty(v), ["nix", "run", ".#deploy", "--", tool], List.append(&2, String, kor.strs(kor.words(S.b(v))), [tool]))

def kor.runner(+tool: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +v : String <- S.env("DEPLOY", "")
    m : Maybe<&2, String> <- S.which("bend-" ++ tool)
    return kor.runner.of(v, m, tool)

# `ENV.. ARGV > LOG 2>&1`: its exit status
def kor.exec.log(+argv: List<&2, String>, env: List<String>, +log: String) -> IO(U32):
  S.run.log(".", env, 2000000, kor.hd(argv), kor.l1(kor.tl(argv)), log)

# `ENV.. ARGV 2>&1`: its status and output
def kor.exec(+argv: List<&2, String>, env: List<String>) -> IO(S.Out):
  S.run(".", env, 2000000, kor.hd(argv), kor.l1(kor.tl(argv)), Nil{})

# text on stderr as it is (a last line without its newline gains one)
def kor.show(+xs: List<&2, U32>) -> IO(Unit):
  Bool.pick(IO(Unit), Nat.is_eq(S.len(xs), 0n), IO.pure(Unit, Unit{}), IO.print_err(S.str(S.chomp(xs))))

def kor.show.file(+path: String) -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> <- S.read(path)
    kor.show(xs)

# a deploy tool run (kor.runner), its output on stderr; it must succeed
def kor.tool.must.if(ok: Bool, +o: S.Out, +what: String) -> IO(Unit):
  match ok:
    case True{}:
      kor.show(S.Out.text(o))
    case False{}:
      do IO<Unit>:
        kor.show(S.Out.text(o))
        IO.die(Unit, 1, what ++ " failed (exit " ++ U32.show(S.Out.status(o)) ++ ")")

def kor.tool(env: List<String>, +tool: String, args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +r : List<&2, String> <- kor.runner(tool)
    +o : S.Out <- kor.exec(List.append(&2, String, r, args), env)
    kor.tool.must.if(U32.is_eq(S.Out.status(o), 0), o, tool)

# the program as invoked (the head of IO.args): what a recipe re-runs for
# one of this binary's own subcommands
def kor.self.of(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      "bend-corpus-v2"
    case h <> t:
      h

def kor.self() -> IO(String):
  do IO<String>:
    argv : List<String> <- IO.args()
    return kor.self.of(argv)
