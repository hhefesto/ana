import Base
import ../Sys.bend as S
import ../CorpusV2/Steps.bend as St
import ../Box/Local.bend as Lc
import ../Box/OnBox.bend as Ob
import ../Box/Stage.bend as Sg

# bend-box's and `bend-ops stage`'s pure parts (bend/Box/OnBox.bend,
# Stage.bend; 2026-10-14) against what fp.sh's awk, grep, sort, tail and sed
# printed on the same files (fixtures/box: run 3's gate.log, the first
# 3090's gate.log with its 3 checks, run 2's time.log, the 3090's dmon.txt,
# the head of run 3's S1 plan; the .expect files are the shell pipelines'
# own output).  Each check prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.
# Run from bend/tests.

type BoxCk is Data:
  BoxCk{name: String, ok: Bool}

def box.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "box: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def box.say(cs: List<&2, BoxCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      box.end(Nat.is_eq(bad, 0n), bad, names)
    case BoxCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        box.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def box.is(+got: List<&2, U32>, +want: String) -> Bool:
  S.eq(got, S.b(want))

def box.sum(+h: String, +n: String) -> Lc.LclSum:
  Lc.LclSum{S.b(h), S.b(n)}

def box.h(+c: String) -> String:
  String.repeat(c, 64n)

def box.f(+s: String) -> St.StF:
  Ob.obx.f(s)

def box.feq(+a: St.StF, +b: St.StF) -> Bool:
  Cmp.is_eq(St.st.f.cmp(a, b))

# the gate's verdicts --------------------------------------------------------------------------

def box.gate(+run3: List<&2, U32>, +g3090: List<&2, U32>) -> List<&2, BoxCk>:
  +nan = S.replace(run3, S.b("(relative 4.8384993e-7)"), S.b("(relative nan)"))
  +none = S.replace(run3, S.b("gradient max"), S.b("gradient"))
  [BoxCk{"gate pass (run 3)", box.is(Ob.obx.gate.text(Ob.obx.gate.of(run3)), "G2: PASS\n")},
   BoxCk{"gate 3 checks (3090)", box.is(Ob.obx.gate.text(Ob.obx.gate.of(g3090)), "expected 4 gradient checks (3 plain, 1 masked), got 3\nG2: MISS\n")},
   BoxCk{"gate nan is a miss", box.is(Ob.obx.gate.text(Ob.obx.gate.of(nan)),
     "gradient differs: masked: gradient max |diff| 3.5390258e-8 of max |g| 0.07314304 (relative nan)\nG2: MISS\n")},
   BoxCk{"gate no checks", box.is(Ob.obx.gate.text(Ob.obx.gate.of(none)), "expected 4 gradient checks (3 plain, 1 masked), got \nG2: MISS\n")}]

# timing, dmon, grep's context -------------------------------------------------------------------

def box.time(+t2: List<&2, U32>, +dmon: List<&2, U32>, +dx: List<&2, U32>, +smi: List<&2, U32>, +sx: List<&2, U32>, +plan: List<&2, U32>) -> List<&2, BoxCk>:
  [BoxCk{"time 8803 (run 2)", box.is(Ob.obx.time.say(t2, 8803n),
     "steady state: 1845 ms/step over 28 steps = 17741 tok/s (16 x 2046 tokens a step); whole plan ~4.5 h\n")},
   BoxCk{"time plan steps (run 2's 53880)", box.is(Ob.obx.time.say(t2, 53880n),
     "steady state: 1845 ms/step over 28 steps = 17741 tok/s (16 x 2046 tokens a step); whole plan ~27.6 h\n")},
   BoxCk{"time two steps say nothing", box.is(Ob.obx.time.say(S.b("[t] step=1/9 ms=100\n[t] step=2/9 ms=200\n"), 8803n), "")},
   BoxCk{"time odd lines", box.is(Ob.obx.time.say(S.b("[t] step=1/9 ms=100\n[t] step=2/9 ms=200\n[t] step=3/9 a ms=1847.5 b\nstep=4/9 ms=9\n[t] step=4/9 ms=1e3 ms=7x\n[t] step=x/9 ms=5\n[t] step=5/9 ms=0.1\n[t] step=6/ ms=3"), 8803n),
     "steady state: 464 ms/step over 4 steps = 70491 tok/s (16 x 2046 tokens a step); whole plan ~1.1 h\n")},
   BoxCk{"plan steps (S1)", Nat.is_eq(Ob.obx.plan.steps(plan), U32.to_nat(56497))},
   BoxCk{"dmon (3090)", S.eq(Ob.obx.dmon.say(dmon), dx)},
   BoxCk{"grep -i -A3 | head -20", S.eq(Ob.obx.ctx(smi), sx)},
   BoxCk{"tail", Bool.and(box.is(Ob.obx.tail(S.b("a\nb\nc"), 2n), "b\nc"), Bool.and(box.is(Ob.obx.tail(S.b("a\n\n"), 1n), "\n"), box.is(Ob.obx.tail(S.b(""), 3n), "")))},
   BoxCk{"awk numbers", Bool.and(Bool.and(box.feq(Ob.obx.awk.num(S.b("1847")), box.f("1847")), box.feq(Ob.obx.awk.num(S.b("1e3x")), box.f("1000"))),
     Bool.and(Bool.and(box.feq(Ob.obx.awk.num(S.b("abc")), box.f("0")), box.feq(Ob.obx.awk.num(S.b(".5")), box.f("0.5"))), box.feq(Ob.obx.awk.num(S.b("-2.e")), box.f("-2"))))}]

# stage push's shards and sums -------------------------------------------------------------------

def box.nth(xs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  Lc.lcl.nth(xs, i)

def box.stage(+plan: List<&2, U32>, +raw: List<&2, U32>, +rx: List<&2, U32>) -> List<&2, BoxCk>:
  +ks = Sg.stg.segments(plan)
  +here = Sg.stg.rename([box.sum(box.h("a"), "shard-0-fp100m.corpus"), box.sum(box.h("b"), "shard-1-fp100m.corpus"), box.sum(box.h("c"), "shard-10-fp100m.corpus")], "s2")
  # the box's `sha256sum DIR/shard-*-s2.corpus`, in the glob's order
  +box = Lc.lcl.sha.parse(S.b(box.h("a") ++ "  formalTransformer/run/s2/shard-0-s2.corpus\n" ++ box.h("b") ++ "  formalTransformer/run/s2/shard-1-s2.corpus\n"
    ++ box.h("c") ++ "  formalTransformer/run/s2/shard-10-s2.corpus\n"))
  +bad = Lc.lcl.sha.parse(S.b(box.h("a") ++ "  formalTransformer/run/s2/shard-0-s2.corpus\n" ++ box.h("d") ++ "  formalTransformer/run/s2/shard-1-s2.corpus\n"
    ++ box.h("c") ++ "  formalTransformer/run/s2/shard-10-s2.corpus\n"))
  +stale = List.append(&2, Lc.LclSum, box, [box.sum(box.h("e"), "shard-2-s2.corpus")])
  +short = List.take(&2, Lc.LclSum, box, 2n)
  [BoxCk{"segments (S1's head)", Bool.and(Nat.is_eq(List.length(&2, List<&2, U32>, ks), 29n), Bool.and(box.is(box.nth(ks, 0n), "0"), box.is(box.nth(ks, 28n), "28")))},
   BoxCk{"shard names", box.is(S.join(Sg.stg.shards(List.take(&2, List<&2, U32>, ks, 2n), "s2"), 32), "shard-0-s2.corpus shard-1-s2.corpus")},
   BoxCk{"sums match (glob order)", Sg.stg.same(here, List.reverse(&2, Lc.LclSum, box))},
   BoxCk{"a corrupted shard blocks", Bool.not(Sg.stg.same(here, bad))},
   BoxCk{"a stale extra shard blocks", Bool.not(Sg.stg.same(here, stale))},
   BoxCk{"a missing shard blocks", Bool.not(Sg.stg.same(here, short))},
   BoxCk{"stage words", Bool.and(Bool.and(String.eq(Sg.stg.stage.name("s2"), "s2"), String.eq(Sg.stg.stage.run("s2"), "run/s2")),
     Bool.and(String.eq(Sg.stg.stage.name("s2=run/v3/S2"), "s2"), String.eq(Sg.stg.stage.run("s2=run/v3/S2"), "run/v3/S2")))},
   BoxCk{"dense-identity's sed", S.eq(Sg.stg.norm(raw), rx)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +run3 : List<&2, U32> <- S.read("fixtures/box/gate-run3.log")
    +g3090 : List<&2, U32> <- S.read("fixtures/box/gate-3090.log")
    +t2 : List<&2, U32> <- S.read("fixtures/box/time-run2.log")
    +dmon : List<&2, U32> <- S.read("fixtures/box/dmon-3090.txt")
    +dx : List<&2, U32> <- S.read("fixtures/box/dmon-3090.expect")
    +smi : List<&2, U32> <- S.read("fixtures/box/smi-perf.txt")
    +sx : List<&2, U32> <- S.read("fixtures/box/smi-perf.expect")
    +plan : List<&2, U32> <- S.read("fixtures/box/plan-s1-head.tsv")
    +raw : List<&2, U32> <- S.read("fixtures/box/ident-raw.log")
    +rx : List<&2, U32> <- S.read("fixtures/box/ident-raw.expect")
    box.say(List.concat(&2, BoxCk, [box.gate(run3, g3090), box.time(t2, dmon, dx, smi, sx, plan), box.stage(plan, raw, rx)]), 0n, "")
