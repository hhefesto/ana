import Base
import ../Sys.bend as S
import ../CorpusV2/HistDrop.bend as T

# bend-corpus-v2 hist-drop (bend/CorpusV2/HistDrop.bend, 2026-11-04): which
# sessions of a listed unit go, by mode and by shape, and the whole tool on
# five sessions written here: OUT exactly the pairs that stay, ALL=1's fewer,
# and a second run the same bytes.  Each check prints `ok NAME` or `FAIL
# NAME`; any FAIL exits 1.

type HtCk is Data:
  HtCk{name: String, ok: Bool}

def ht.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "histdrop: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def ht.say(cs: List<&2, HtCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      ht.end(Nat.is_eq(bad, 0n), bad, names)
    case HtCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        ht.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def ht.pure() -> List<&2, HtCk>:
  [HtCk{"keeps-direct", Bool.not(T.hdr.drops(False{}, S.b("own:a/x.bend#f@1/mugen-direct")))},
   HtCk{"keeps-fill", Bool.not(T.hdr.drops(False{}, S.b("own:a/x.bend#f@1+2/mugen-fill")))},
   HtCk{"drops-repair", T.hdr.drops(False{}, S.b("own:a/x.bend#f@1/repair"))},
   HtCk{"drops-mugen-repair", T.hdr.drops(False{}, S.b("own:a/x.bend#f@1/mugen-repair-3"))},
   HtCk{"drops-mutate", T.hdr.drops(False{}, S.b("mut:own:a/x.bend#f@1/swap-args"))},
   HtCk{"all-drops-direct", T.hdr.drops(True{}, S.b("own:a/x.bend#f@1/mugen-direct"))}]

def ht.pair(+i: String, +t: String) -> List<&2, U32>:
  S.append(S.b(i), 0 <> S.append(S.b(t), [0]))

# f@1 listed: its direct stays, its repairs and its mutate session go; g@2 not listed: its repair stays
def ht.direct() -> List<&2, U32>:
  ht.pair("own:a/x.bend#f@1+4/mugen-direct", "d\n")

def ht.g() -> List<&2, U32>:
  ht.pair("own:a/x.bend#g@2/mugen-repair-0", "g\n")

def ht.in() -> List<&2, U32>:
  S.append(ht.direct(), S.append(ht.pair("own:a/x.bend#f@1/mugen-repair-1", "r\n"), S.append(ht.g(), S.append(ht.pair("mut:own:a/x.bend#f@1+2/swap", "m\n"), ht.pair("own:a/x.bend#f@1/repair", "q\n")))))

def ht.io(+dir: String) -> IO(List<&2, HtCk>):
  do IO<List<&2, HtCk>>:
    S.write(dir ++ "/in.nul", ht.in())
    S.write(dir ++ "/units", S.b("own:a/x.bend#f@1\n\nown:b/y.bend#h@3\n"))
    T.hdr.run(False{}, dir ++ "/in.nul", dir ++ "/out.nul", dir ++ "/units")
    +o1 : List<&2, U32> <- S.read(dir ++ "/out.nul")
    T.hdr.run(True{}, dir ++ "/in.nul", dir ++ "/all.nul", dir ++ "/units")
    +o2 : List<&2, U32> <- S.read(dir ++ "/all.nul")
    T.hdr.run(False{}, dir ++ "/in.nul", dir ++ "/out2.nul", dir ++ "/units")
    +o3 : List<&2, U32> <- S.read(dir ++ "/out2.nul")
    return [HtCk{"tool-out", S.eq(o1, S.append(ht.direct(), ht.g()))},
      HtCk{"tool-all", S.eq(o2, ht.g())},
      HtCk{"tool-same-twice", S.eq(o1, o3)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    io : List<&2, HtCk> <- ht.io(dir)
    S.rm(dir)
    ht.say(List.append(&2, HtCk, ht.pure(), io), 0n, "")
