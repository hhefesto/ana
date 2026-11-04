import Base
import ../Sys.bend as S
import ../PlanWindows.bend as P

# bend-plan-windows' direct road (2026-11-03): NUL pairs interleaved with no JSON,
# FILLER_COPIES, the holdout's files left out, and a part written as it is read.  A
# language's rounds are bend-mix's.  The real check of the bytes was on run 5's
# rehearsal: 1.28 GB through both roads, cmp the same.  Each check prints `ok NAME` or
# `FAIL NAME`; any FAIL exits 1.

type PwCk is Data:
  PwCk{name: String, ok: Bool}

def pw.end(ok: Bool, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "planwin: failed:" ++ names)

def pw.say(cs: List<&2, PwCk>, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      pw.end(String.is_empty(names), names)
    case PwCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        pw.say(t, Bool.pick(String, ok, names, names ++ " " ++ n))

def pw.nul(fs: List<String>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      Nil{}
    case +f <> more:
      S.append(S.b(f), 0 <> pw.nul(more))

def pw.is(+name: String, +got: List<&2, U32>, fs: List<String>) -> PwCk:
  PwCk{name, S.eq(got, pw.nul(fs))}

def pw.tree(+d: String) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(d ++ "/a")
    S.mkdir(d ++ "/b")
    S.write(d ++ "/a/transcripts.train.nul", pw.nul(["a1", "x", "a2", "y", "a3", "z"]))
    S.write(d ++ "/b/transcripts.train.nul", pw.nul(["b1", "p", "b2", "q", "b3", "r", "b4", "s"]))
    S.write(d ++ "/a/files-hi.nul", pw.nul(["f1", "one", "f2", "two"]))
    S.write(d ++ "/a/files-lo.nul", pw.nul(["f3", "three"]))
    S.write(d ++ "/a/results.holdout.nul", pw.nul(["f2#u@1", "unit"]))
    S.write(d ++ "/b/files-hi.nul", pw.nul(["g1", "gee"]))
    S.write(d ++ "/b/files-lo.nul", Nil{})
    S.write(d ++ "/b/results.holdout.nul", Nil{})

def pw.mix(+d: String) -> IO(List<&2, PwCk>):
  +ss = P.specs(["a:2", "b:1"])
  do IO<List<&2, PwCk>>:
    tr : List<P.NmS> <- P.nm.open.tr(d, ss)
    P.nm.mix(d, "mix", tr)
    +m : List<&2, U32> <- S.read(d ++ "/mix.nul")
    one : List<P.NmS> <- P.nm.open.fl("", d, ss)
    P.nm.mix(d, "filler", one)
    +f1 : List<&2, U32> <- S.read(d ++ "/filler.nul")
    three : List<P.NmS> <- P.nm.open.fl("a:3", d, ss)
    P.nm.mix(d, "filler", three)
    +f3 : List<&2, U32> <- S.read(d ++ "/filler.nul")
    +c3 : Nat <- P.count.of(d ++ "/filler.nul")
    S.rm(d ++ "/filler.nul.count")
    +c4 : Nat <- P.count.of(d ++ "/filler.nul")
    return [pw.is("rounds: a's two then b's one; a language dry leaves them", m, ["a1", "x", "a2", "y", "b1", "p", "a3", "z", "b2", "q", "b3", "r", "b4", "s"]),
            pw.is("filler: hi then lo, a holdout's file left out", f1, ["f1", "one", "f3", "three", "g1", "gee"]),
            pw.is("FILLER_COPIES: a's files 3 times, #c1 and #c2 after the first", f3, ["f1", "one", "f3", "three", "g1", "gee", "f1#c1", "one", "f3#c1", "three", "f1#c2", "one", "f3#c2", "three"]),
            PwCk{"the count the mix wrote", Nat.is_eq(c3, 7n)},
            PwCk{"the count read, without it", Nat.is_eq(c4, 7n)}]

def pw.part(+d: String, +k: Nat) -> IO(List<&2, U32>):
  S.read(P.sp.path(d ++ "/p", k))

def pw.split(+d: String) -> IO(List<&2, PwCk>):
  do IO<List<&2, PwCk>>:
    S.write(d ++ "/in.nul", pw.nul(["a", "1", "b", "2", "c", "3"]))
    +k3 : Nat <- P.split(d ++ "/in.nul", 2n, d ++ "/p")
    +p0 : List<&2, U32> <- pw.part(d, 0n)
    +p1 : List<&2, U32> <- pw.part(d, 1n)
    +k1 : Nat <- P.split(d ++ "/in.nul", 3n, d ++ "/q")
    +gone : Bool <- S.exists(P.sp.path(d ++ "/q", 1n))
    return [PwCk{"split: 3 pairs by 2 are 2 parts", Nat.is_eq(k3, 2n)},
            pw.is("split: the first part", p0, ["a", "1", "b", "2"]),
            pw.is("split: the last, short", p1, ["c", "3"]),
            PwCk{"split: an exact fit is 1 part", Nat.is_eq(k1, 1n)},
            PwCk{"split: no empty part left behind", Bool.not(gone)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +d : String <- S.mktemp()
    pw.tree(d)
    a : List<&2, PwCk> <- pw.mix(d)
    b : List<&2, PwCk> <- pw.split(d)
    S.rm(d)
    pw.say(List.append(&2, PwCk, a, b), "")
