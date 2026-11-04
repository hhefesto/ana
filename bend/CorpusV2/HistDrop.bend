import Base
import ../Sys.bend as S
import ../Check/Lib.bend as Cl
import ./Lib.bend as L
import ./Pool.bend as P
import ./Ratio.bend as R

# hist-drop: a transcript stream less some units' sessions (2026-11-04;
# tools/corpus-v2/hist/hist-drop.py in Bend, the user, 11-03: "always use bend
# instead of python whenever possible"; the same bytes, checked on own5's
# mugen stream both ways).
#
#   bend-corpus-v2 hist-drop IN.nul OUT.nul UNITS       ALL=1: every session of a listed unit
#
# IN.nul: NUL pairs (session id, text).  UNITS: unit ids, a line each.  A
# session's unit is repair-mix's (R.rto.unit: its id less a leading `mut:`,
# less its last `/` segment, less a trailing `+N`).  Dropped: a session of a
# listed unit that is mutate's (`mut:`) or whose shape is a repair (`repair`,
# format mugen's `mugen-repair-M`): such a unit keeps its real repairs alone
# (hist5.sh, mugen6.sh).  ALL=1 drops all of a listed unit's (recheck: today's
# Bend rejects the unit, so none of its tool outputs is true).  The rest goes
# to OUT in order, byte for byte.  An id with no text after it is an error.

# does this session of a listed unit go
def hdr.drops(+all: Bool, +id: List<&2, U32>) -> Bool:
  +x = R.rto.seg(id)
  Bool.or(all, Bool.or(S.prefix(id, S.b("mut:")), Bool.or(S.eq(x, S.b("repair")), S.prefix(x, S.b("mugen-repair-")))))

type HdrSt is Type:
  HdrSt{r: S.Rd, o: File, u: Set(), st: List<&2, Cl.Stat>, more: Bool}

def hdr.put(drop: Bool, r: S.Rd, o: File, u: Set(), st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(HdrSt):
  match drop:
    case True{}:
      IO.pure(HdrSt, HdrSt{r, o, u, Cl.stat.bump("dropped", 1n, st), True{}})
    case False{}:
      do IO<HdrSt>:
        o2 : File <- P.po.emit3(o, S.append(id, [0]), t)
        return HdrSt{r, o2, u, Cl.stat.bump("out", 1n, st), True{}}

def hdr.has(+all: Bool, r: S.Rd, o: File, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>, x: Set() & Bool) -> IO(HdrSt):
  (u, b) = x
  hdr.put(Bool.and(b, hdr.drops(all, id)), r, o, u, Cl.stat.bump("in", 1n, st), id, t)

def hdr.text(+all: Bool, o: File, u: Set(), st: List<&2, Cl.Stat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(HdrSt):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(HdrSt, HdrSt{r, o, u, Cl.stat.bump("odd", 1n, st), False{}})
    case Some{+t}:
      hdr.has(all, r, o, st, id, t, Set.has(u, S.str(R.rto.unit(id))))

def hdr.id(+all: Bool, r: S.Rd, o: File, u: Set(), st: List<&2, Cl.Stat>, m: Maybe<&2, List<&2, U32>>) -> IO(HdrSt):
  match m:
    case None{}:
      IO.pure(HdrSt, HdrSt{r, o, u, st, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, HdrSt, S.Rd.next(r), hdr.text(all, o, u, st, id))

def hdr.got(+all: Bool, o: File, u: Set(), st: List<&2, Cl.Stat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(HdrSt):
  (r, m) = x
  hdr.id(all, r, o, u, st, m)

def hdr.step(+all: Bool, s: HdrSt) -> IO(HdrSt):
  match s:
    case HdrSt{r, o, u, st, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, HdrSt, S.Rd.next(r), hdr.got(all, o, u, st))

def hdr.go(fuel: Nat, +all: Bool, s: HdrSt) -> IO(HdrSt):
  match fuel s:
    case 1n+f HdrSt{r, o, u, st, True{}}:
      IO.bind(HdrSt, HdrSt, hdr.step(all, HdrSt{r, o, u, st, True{}}), hdr.go(f, all))
    case _ HdrSt{r, o, u, st, g}:
      IO.pure(HdrSt, HdrSt{r, o, u, st, g})

def hdr.fin(s: HdrSt) -> IO(List<&2, Cl.Stat>):
  match s:
    case HdrSt{r, o, u, +st, g}:
      do IO<List<&2, Cl.Stat>>:
        S.Rd.close(r)
        File.close(o)
        return st

def hdr.odd(+st: String) -> Bool:
  S.infix(S.b(st), S.b("odd "))

def hdr.end(odd: Bool, +st: String) -> IO(Unit):
  match odd:
    case True{}:
      IO.die(Unit, 1, "hist-drop: an id with no text")
    case False{}:
      IO.print(S.str(S.chomp(S.b(st))))

def hdr.run(+all: Bool, +in: String, +out: String, +units: String) -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> <- S.read(units)
    r : S.Rd <- S.Rd.open(in)
    o : File <- IO.try(File, File.open(out, "w"))
    s : HdrSt <- hdr.go(U32.to_nat(4294967295), all, HdrSt{r, o, Set.from_list(L.v2.lines.str(S.split(xs, 10))), Nil{}, True{}})
    +st : List<&2, Cl.Stat> <- hdr.fin(s)
    hdr.end(hdr.odd(Cl.stat.show(st)), Cl.stat.show(st))

def hdr.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +i <> +o <> +u <> Nil{}:
      do IO<Unit>:
        +a : String <- S.env("ALL", "")
        hdr.run(S.eq(S.b(a), S.b("1")), i, o, u)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 hist-drop IN.nul OUT.nul UNITS   (ALL=1: every session of a listed unit)")
