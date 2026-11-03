import Base
import ../Sys.bend as S
import ../Check/Lib.bend as Cl
import ../CorpusV2/Trim.bend as T

# bend-corpus-v2 trim-mutants (bend/CorpusV2/Trim.bend, 2026-11-03): at most
# K of a unit's mutants, K in a row from the start its id picks (the POSIX
# cksum of the id and a newline, mod the mutant count; the starts below are
# `printf '%s\n' ID | cksum` mod n), wrapping.  The pure parts: a unit with K
# mutants or fewer byte for byte (empty fields too), one with more cut from
# its start (the wrap), K = 0, a record of fewer than 11 fields, the counts.
# Then the whole tool on three units written here: OUT exactly the pairs
# expected, OUT.stats every count, a second run the same bytes.  Each check
# prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.

type TtCk is Data:
  TtCk{name: String, ok: Bool}

def tt.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "trim: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def tt.say(cs: List<&2, TtCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      tt.end(Nat.is_eq(bad, 0n), bad, names)
    case TtCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        tt.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

# a unit's 11 fields: lang, kind, name, doc, sig, head, pre, body, tail, names, hole
def tt.unit() -> List<&2, List<&2, U32>>:
  [S.b("bend"), S.b("def"), S.b("f"), Nil{}, S.b("def f() -> Nat"), S.b("import Base\n"), Nil{}, S.b("  1n\n"), Nil{}, S.b("f"), S.b("?goal")]

def tt.m(+i: Nat) -> List<&2, U32>:
  S.b("  " ++ Nat.show(i) ++ "x\n")

def tt.ms(n: Nat, +i: Nat) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      tt.m(i) <> tt.ms(k, 1n+i)

def tt.rec(+n: Nat) -> List<&2, U32>:
  S.join(List.append(&2, List<&2, U32>, tt.unit(), tt.ms(n, 0n)), 30)

def tt.idg() -> List<&2, U32>:
  S.b("own:a/x.bend#g@9")

def tt.idh() -> List<&2, U32>:
  S.b("own:a/y.bend#h@3")

def tt.idf() -> List<&2, U32>:
  S.b("own:a/x.bend#f@1")

# h: 6 mutants, cksum 3377399039 mod 6 = 5: kept 5, 0, 1, 2
def tt.h.cut() -> List<&2, U32>:
  S.join(List.append(&2, List<&2, U32>, tt.unit(), [tt.m(5n), tt.m(0n), tt.m(1n), tt.m(2n)]), 30)

# g: 7 mutants, cksum 2043147997 mod 7 = 2: kept 2, 3, 4, 5
def tt.g.cut() -> List<&2, U32>:
  S.join(List.append(&2, List<&2, U32>, tt.unit(), [tt.m(2n), tt.m(3n), tt.m(4n), tt.m(5n)]), 30)

# a record ending in its separator (an empty last mutant) and one with an empty mutant inside
def tt.empties() -> List<&2, U32>:
  S.join(List.append(&2, List<&2, U32>, tt.unit(), [tt.m(0n), Nil{}, tt.m(2n), Nil{}]), 30)

def tt.short() -> List<&2, U32>:
  S.join([S.b("bend"), S.b("def"), S.b("f"), Nil{}, S.b("x")], 30)

def tt.stat.is(+st: List<&2, Cl.Stat>, +want: String) -> Bool:
  String.eq(Cl.stat.show(st), want)

def tt.pure() -> List<&2, TtCk>:
  [TtCk{"few-mutants-whole", S.eq(T.trm.rec(4n, tt.idf(), tt.rec(3n)), tt.rec(3n))},
   TtCk{"k-mutants-whole", S.eq(T.trm.rec(4n, tt.idf(), tt.rec(4n)), tt.rec(4n))},
   TtCk{"empty-fields-whole", S.eq(T.trm.rec(4n, tt.idf(), tt.empties()), tt.empties())},
   TtCk{"cut-wraps-from-start", S.eq(T.trm.rec(4n, tt.idh(), tt.rec(6n)), tt.h.cut())},
   TtCk{"cut-from-start", S.eq(T.trm.rec(4n, tt.idg(), tt.rec(7n)), tt.g.cut())},
   TtCk{"start-0-takes-first", S.eq(T.trm.rec(1n, tt.idf(), tt.rec(6n)), S.join(List.append(&2, List<&2, U32>, tt.unit(), [tt.m(0n)]), 30))},
   TtCk{"k-0-no-mutants", S.eq(T.trm.rec(0n, tt.idh(), tt.rec(2n)), S.join(tt.unit(), 30))},
   TtCk{"short-record-whole", S.eq(T.trm.rec(0n, tt.idh(), tt.short()), tt.short())},
   TtCk{"counts", tt.stat.is(T.trm.stat(4n, tt.rec(6n), T.trm.stat(4n, tt.rec(2n), Nil{})), "mutants-in 8\nmutants-out 6\nunits 2\nunits-trimmed 1\n")}]

def tt.pair(+id: List<&2, U32>, +rec: List<&2, U32>) -> List<&2, U32>:
  S.append(id, 0 <> S.append(rec, [0]))

def tt.in() -> List<&2, U32>:
  S.append(tt.pair(tt.idf(), tt.rec(3n)), S.append(tt.pair(tt.idh(), tt.rec(6n)), tt.pair(tt.idg(), tt.rec(7n))))

def tt.out() -> List<&2, U32>:
  S.append(tt.pair(tt.idf(), tt.rec(3n)), S.append(tt.pair(tt.idh(), tt.h.cut()), tt.pair(tt.idg(), tt.g.cut())))

def tt.io(+dir: String) -> IO(List<&2, TtCk>):
  do IO<List<&2, TtCk>>:
    S.write(dir ++ "/units.nul", tt.in())
    T.trm.run(dir ++ "/units.nul", dir ++ "/out.nul", 4n)
    +o1 : List<&2, U32> <- S.read(dir ++ "/out.nul")
    +st : List<&2, U32> <- S.read(dir ++ "/out.nul.stats")
    T.trm.run(dir ++ "/units.nul", dir ++ "/out2.nul", 4n)
    +o2 : List<&2, U32> <- S.read(dir ++ "/out2.nul")
    return [TtCk{"tool-out", S.eq(o1, tt.out())},
      TtCk{"tool-stats", S.eq(st, S.b("mutants-in 16\nmutants-out 11\nunits 3\nunits-trimmed 2\n"))},
      TtCk{"tool-same-twice", S.eq(o1, o2)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    io : List<&2, TtCk> <- tt.io(dir)
    S.rm(dir)
    tt.say(List.append(&2, TtCk, tt.pure(), io), 0n, "")
