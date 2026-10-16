import Base
import ../Sys.bend as S
import ../Json.bend as J
import ../CorpusV2/Unused.bend as U

# bend-corpus-v2 unused (bend/CorpusV2/Unused.bend, 2026-10-15): a pool's
# records that no stream has used, on small fixtures written here.  The pure
# parts against their meaning: a line's id is J.first.at's "id" text, hex keeps
# the bytewise order sort uses, the twelve-digit numbers sort as numbers.  The
# whole tool (spools, `LC_ALL=C sort`, the merge, the last pass) against the
# set difference spelled out: a JSONL and a NUL SEEN stream, an id twice in
# the pool, ids that differ in one escaped byte, a newline inside an id, a
# line that is no record, a last line without its newline.  Each check prints
# `ok NAME` or `FAIL NAME`; any FAIL exits 1.  Run from bend/tests.

type UnCk is Data:
  UnCk{name: String, ok: Bool}

def ut.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "unused: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def ut.say(cs: List<&2, UnCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      ut.end(Nat.is_eq(bad, 0n), bad, names)
    case UnCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        ut.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def ut.id.is(m: Maybe<&2, List<&2, U32>>, +want: String) -> Bool:
  match m:
    case Some{+x}:
      S.eq(x, S.b(want))
    case None{}:
      False{}

def ut.none(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{x}:
      False{}
    case None{}:
      True{}

# J.first.at's reading of a line's id: the first member's text when it is "id"
def ut.j.of(p: J.Pr) -> Maybe<&2, List<&2, U32>>:
  match p:
    case J.Pok{+k, +v, r}:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.eq(k, S.b("id")), Some{v}, None{})
    case J.Pbad{}:
      None{}

def ut.same(+a: Maybe<&2, List<&2, U32>>, +b: Maybe<&2, List<&2, U32>>) -> Bool:
  match a b:
    case Some{+x} Some{+y}:
      S.eq(x, y)
    case None{} None{}:
      True{}
    case _ _:
      False{}

def ut.agree(ls: List<&2, String>) -> Bool:
  match ls:
    case Nil{}:
      True{}
    case +l <> t:
      Bool.and(ut.same(U.unu.id(S.b(l)), ut.j.of(J.first.at(S.b(l)))), ut.agree(t))

# the lines J.first.at and unu.id must read alike
def ut.lines() -> List<&2, String>:
  ["{\"id\": \"x/\\u0041.hs\", \"text\": \"1\"}", "{\"id\":\"a\\\"b\",\"text\":\"\"}", "  {  \"id\"  :  \"sp\" , \"text\": \"x\"}", "{\"text\": \"t\", \"id\": \"b\"}",
   "plain line", "", "{\"id\": 5, \"text\": \"t\"}", "{\"id\": \"open", "{\"\\u0069d\": \"esc-key\", \"text\": \"\"}", "{\"id\": \"tab\\there\\nnl\", \"text\": \"y\"}",
   "{\"id\": \"\\ud83d\\ude00\", \"text\": \"pair\"}", "[\"id\", \"x\"]", "{\"id\" \"x\"}"]

# bytewise order is kept by hex (sort's -u and the merge compare the hex)
type UtP is Data:
  UtP{a: List<&2, U32>, b: List<&2, U32>}

def ut.hex.order(ps: List<&2, UtP>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case UtP{+a, +b} <> t:
      Bool.and(Nat.is_eq(U.unu.cmp(U.unu.hex(a), U.unu.hex(b)), U.unu.cmp(a, b)), ut.hex.order(t))

def ut.two.is(x: Nat & Nat) -> Bool:
  (+a, +b) = x
  Bool.and(Nat.is_eq(a, 12n), Nat.is_eq(b, 34n))

def ut.args.is(a: U.UnuArgs) -> Bool:
  match a:
    case U.UnuArgs{+ps, +ss, sep}:
      +p2 = Maybe.default(&2, U.UnuPair, List.get(&2, U.UnuPair, ps, 1n), U.UnuPair{"", ""})
      two = U.unu.two(S.Out{0, S.b("log\n12 34\n")})
      Bool.and(Bool.and(Bool.and(sep, Nat.is_eq(List.length(&2, U.UnuPair, ps), 2n)), Bool.and(String.eq(U.unu.p.pool(p2), "b.jsonl"), String.eq(U.unu.p.out(p2), "o/b=2"))),
        Bool.and(Bool.and(Nat.is_eq(List.length(&2, String, ss), 2n), U.unu.pairs.ok(ps)), ut.two.is(two)))

def ut.pure() -> List<&2, UnCk>:
  [UnCk{"id: the first member's text, escapes decoded", Bool.and(ut.id.is(U.unu.id(S.b("{\"id\": \"x/\\u0041.hs\", \"text\": \"1\"}")), "x/A.hs"),
     ut.id.is(U.unu.id(S.b("{\"id\":\"a\\\"b\",\"text\":\"\"}")), "a\"b"))},
   UnCk{"id: none for a line that is no record (not first, not a string, no object)", Bool.and(Bool.and(ut.none(U.unu.id(S.b("{\"text\": \"t\", \"id\": \"b\"}"))),
     ut.none(U.unu.id(S.b("{\"id\": 5}")))), Bool.and(ut.none(U.unu.id(S.b("plain line"))), ut.none(U.unu.id(Nil{}))))},
   UnCk{"id: J.first.at's reading on every fixture line", ut.agree(ut.lines())},
   UnCk{"cmp: bytewise (prefix first, high bytes last)", Bool.and(Bool.and(Nat.is_eq(U.unu.cmp(S.b("ab"), S.b("abc")), 0n), Nat.is_eq(U.unu.cmp(S.b("b"), S.b("abc")), 2n)),
     Bool.and(Nat.is_eq(U.unu.cmp(S.b("x"), S.b("x")), 1n), Nat.is_eq(U.unu.cmp([200], [127, 1]), 2n)))},
   UnCk{"hex: two lowercase digits a byte", S.eq(U.unu.hex([0, 9, 10, 255, 65]), S.b("00090aff41"))},
   UnCk{"hex keeps the bytewise order", ut.hex.order([UtP{S.b("ab"), S.b("abc")}, UtP{S.b("abc"), S.b("ab")}, UtP{[9], [10]}, UtP{[255], [16, 0]}, UtP{S.b("x\ny"), S.b("x\ty")}, UtP{Nil{}, [0]},
     UtP{S.b("same"), S.b("same")}])},
   UnCk{"line numbers: twelve digits (bytewise is numeric)", Bool.and(String.eq(U.unu.pad(0n), "000000000000"), Bool.and(String.eq(U.unu.pad(370235n), "000000370235"),
     Nat.is_eq(U.unu.cmp(S.b(U.unu.pad(9n)), S.b(U.unu.pad(10n))), 0n)))},
   UnCk{"spool lines", Bool.and(S.eq(U.unu.pool.rec(S.b("a\tb"), 7n), S.b("610962\t000000000007\n")),
     Bool.and(S.eq(U.unu.seen.rec(S.b("a\tb")), S.b("610962\n")), Nat.is_eq(U.unu.pool.num(S.b("610962\t000000000007")), 7n)))},
   UnCk{"a path read as JSONL (c2.is.jsonl's rule)", Bool.and(U.unu.is.jsonl("run/v3/R/mix.jsonl"), Bool.not(U.unu.is.jsonl("run/v3/T/filler.nul")))},
   UnCk{"args: the leading POOL=OUT words are pairs (OUT may hold =), the rest SEEN; a worker's answer", ut.args.is(U.unu.args(["a.jsonl=o/a", "b.jsonl=o/b=2", "s.jsonl", "f.nul"]))}]

# The tool on files --------------------------------------------------------------------------

def ut.rec(+id: String, +t: String) -> String:
  "{\"id\": \"" ++ id ++ "\", \"text\": \"" ++ t ++ "\"}"

# POOL: a twice (once used), b, c (an escape away from c's used twin), a line
# that is no record, d with a newline in its id (used in the NUL stream), ünï
# (unused), e (used in the second JSONL), f last without its newline
def ut.pool() -> String:
  ut.rec("a", "1") ++ "\n" ++ ut.rec("b", "2") ++ "\n" ++ ut.rec("c\\u0041", "3") ++ "\nnot json\n" ++ ut.rec("d\\nx", "4") ++ "\n" ++ ut.rec("a", "5") ++ "\n"
    ++ ut.rec("ünï", "6") ++ "\n" ++ ut.rec("e", "7") ++ "\n" ++ ut.rec("f", "8")

def ut.seen1() -> String:
  ut.rec("a", "used") ++ "\n" ++ ut.rec("cB", "a twin") ++ "\n" ++ ut.rec("zz", "") ++ "\n"

def ut.seen2() -> String:
  "d\nx\u{0}text\u{0}a\u{0}again\u{0}q\u{0}\u{0}"

def ut.seen3() -> String:
  ut.rec("e", "") ++ "\n"

def ut.want() -> String:
  ut.rec("b", "2") ++ "\n" ++ ut.rec("c\\u0041", "3") ++ "\n" ++ ut.rec("ünï", "6") ++ "\n" ++ ut.rec("f", "8") ++ "\n"

def ut.all() -> String:
  ut.rec("a", "1") ++ "\n" ++ ut.rec("b", "2") ++ "\n" ++ ut.rec("c\\u0041", "3") ++ "\n" ++ ut.rec("d\\nx", "4") ++ "\n" ++ ut.rec("a", "5") ++ "\n"
    ++ ut.rec("ünï", "6") ++ "\n" ++ ut.rec("e", "7") ++ "\n" ++ ut.rec("f", "8") ++ "\n"

# a second pool: one record SEEN has (a), one it does not (g)
def ut.pool2() -> String:
  ut.rec("g", "9") ++ "\n" ++ ut.rec("a", "10") ++ "\n"

# the tool in this process (PROCS 1: the test runs interpreted, with no
# bend-corpus-v2 to spawn as workers)
def ut.run(+ps: List<&2, U.UnuPair>, +seen: List<&2, String>) -> IO(Unit):
  U.unu.run(1n, "bend-corpus-v2", ps, seen)

def ut.io(+dir: String) -> IO(List<&2, UnCk>):
  +seen = {[dir ++ "/s1.jsonl", dir ++ "/s2.nul", dir ++ "/s3.jsonl"] : List<&2, String>}
  do IO<List<&2, UnCk>>:
    S.write(dir ++ "/pool.jsonl", S.b(ut.pool()))
    S.write(dir ++ "/pool2.jsonl", S.b(ut.pool2()))
    S.write(dir ++ "/s1.jsonl", S.b(ut.seen1()))
    S.write(dir ++ "/s2.nul", S.b(ut.seen2()))
    S.write(dir ++ "/s3.jsonl", S.b(ut.seen3()))
    S.write(dir ++ "/empty.jsonl", Nil{})
    ut.run([U.UnuPair{dir ++ "/pool.jsonl", dir ++ "/out.jsonl"}], seen)
    +o : List<&2, U32> <- S.read(dir ++ "/out.jsonl")
    ut.run([U.UnuPair{dir ++ "/pool.jsonl", dir ++ "/all.jsonl"}], [dir ++ "/empty.jsonl"])
    +a : List<&2, U32> <- S.read(dir ++ "/all.jsonl")
    ut.run([U.UnuPair{dir ++ "/pool.jsonl", dir ++ "/none.jsonl"}], [dir ++ "/pool.jsonl"])
    +n : List<&2, U32> <- S.read(dir ++ "/none.jsonl")
    ut.run([U.UnuPair{dir ++ "/pool.jsonl", dir ++ "/m1.jsonl"}, U.UnuPair{dir ++ "/pool2.jsonl", dir ++ "/m2.jsonl"}], seen)
    +m1 : List<&2, U32> <- S.read(dir ++ "/m1.jsonl")
    +m2 : List<&2, U32> <- S.read(dir ++ "/m2.jsonl")
    s1 : Bool <- S.exists(dir ++ "/out.jsonl.unu-pool.sorted")
    s2 : Bool <- S.exists(dir ++ "/out.jsonl.unu-seen.sorted")
    s3 : Bool <- S.exists(dir ++ "/m1.jsonl.unu-seen.0")
    return [UnCk{"tool: POOL less SEEN (a JSONL and a NUL stream), in POOL's order, each line with its newline", S.eq(o, S.b(ut.want()))},
      UnCk{"tool: an empty SEEN keeps every record, and only records", S.eq(a, S.b(ut.all()))},
      UnCk{"tool: POOL against itself keeps nothing", Nat.is_eq(S.len(n), 0n)},
      UnCk{"tool: two pools in one call, SEEN read once, each as it would be alone", Bool.and(S.eq(m1, o), S.eq(m2, S.b(ut.rec("g", "9") ++ "\n")))},
      UnCk{"tool: the spools are gone", Bool.not(Bool.or(Bool.or(s1, s2), s3))}]

def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    io : List<&2, UnCk> <- ut.io(dir)
    S.rm(dir)
    ut.say(List.append(&2, UnCk, ut.pure(), io), 0n, "")
