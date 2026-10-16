import Base
import ../Sys.bend as S
import ../CorpusV2/Raw.bend as R

# The raw slicer (bend/CorpusV2/Raw.bend, `slice SRC DST K SIZE`; raw-build's
# first step) run for real on a small file written here: slice K keeps the
# lines that start in [(K-1) SIZE, K SIZE), and the last slice only whole
# 2,000s of lines.  Slice K >= 2 reads through a FIFO that a background `dd`
# fills; under Bend 2.0.37's Process.run the old `tail` writer held the
# start's pipes while it blocked opening the FIFO, and every slice past the
# first timed out (2026-10-15, run 4's build).  Two sizes: one whose second
# slice starts exactly at a line's first byte, one three bytes past it.  Each
# check prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.  Run from
# bend/tests.

type SlCk is Data:
  SlCk{name: String, ok: Bool}

def slt.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "slice: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def slt.say(cs: List<&2, SlCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      slt.end(Nat.is_eq(bad, 0n), bad, names)
    case SlCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        slt.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

# line i: its number and 0..18 x's, so the lines differ in length
def slt.line(+i: Nat) -> List<&2, U32>:
  List.concat(&2, U32, [S.b("line-" ++ Nat.show(i) ++ " "), List.replicate(U32, Nat.mul(Nat.mod(i, 7n), 3n), 120), [10]])

def slt.lines(k: Nat, +i: Nat) -> List<&2, List<&2, U32>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      slt.line(i) <> slt.lines(p, 1n+i)

# where line k starts: the bytes of the lines before it
def slt.at(ls: List<&2, List<&2, U32>>, k: Nat) -> Nat:
  match ls k:
    case _ 0n:
      0n
    case Nil{} _:
      0n
    case +l <> t 1n+p:
      Nat.add(S.len(l), slt.at(t, p))

# the meaning: the lines (from byte pos on) that start in [lo, hi)
def slt.keep(ls: List<&2, List<&2, U32>>, +pos: Nat, +lo: Nat, +hi: Nat) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = slt.keep(t, Nat.add(pos, S.len(l)), lo, hi)
      Bool.pick(List<&2, U32>, Bool.and(Nat.is_le(lo, pos), Nat.is_lt(pos, hi)), List.append(&2, U32, l, rest), rest)

def slt.cut(+dir: String, +name: String, +k: Nat, +size: Nat) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    R.rw.slice.n("bend-corpus-v2", dir ++ "/mix.jsonl", dir ++ "/" ++ name, Some{k}, Some{size})
    S.read(dir ++ "/" ++ name)

# slices 1, 2 and 3 of the 50 lines at SIZE, about 20 lines (the file is under 3 SIZE: slice 3 is the last)
def slt.sizes(+dir: String, +ls: List<&2, List<&2, U32>>, +size: Nat, +tag: String) -> IO(List<&2, SlCk>):
  do IO<List<&2, SlCk>>:
    +s1 : List<&2, U32> <- slt.cut(dir, tag ++ "-1", 1n, size)
    +s2 : List<&2, U32> <- slt.cut(dir, tag ++ "-2", 2n, size)
    +s3 : List<&2, U32> <- slt.cut(dir, tag ++ "-3", 3n, size)
    return [SlCk{tag ++ ": slice 1 is the lines starting before SIZE", S.eq(s1, slt.keep(ls, 0n, 0n, size))},
      SlCk{tag ++ ": slice 2 (through the FIFO) is the lines starting in [SIZE, 2 SIZE)", S.eq(s2, slt.keep(ls, 0n, size, Nat.mul(2n, size)))},
      SlCk{tag ++ ": slices 1 and 2 are the file up to the first line starting at 2 SIZE or past it", S.eq(List.append(&2, U32, s1, s2), slt.keep(ls, 0n, 0n, Nat.mul(2n, size)))},
      SlCk{tag ++ ": slice 3, the last, keeps whole 2,000s of lines: none of its few", List.is_empty(&2, U32, s3)}]

def main() -> IO(Unit):
  +ls = slt.lines(50n, 0n)
  +at = slt.at(ls, 20n)
  do IO<Unit>:
    +dir : String <- S.mktemp()
    S.write(dir ++ "/mix.jsonl", List.concat(&2, U32, ls))
    a : List<&2, SlCk> <- slt.sizes(dir, ls, at, "a line's start")
    b : List<&2, SlCk> <- slt.sizes(dir, ls, Nat.add(at, 3n), "mid-line")
    S.rm(dir)
    slt.say(List.append(&2, SlCk, a, b), 0n, "")
