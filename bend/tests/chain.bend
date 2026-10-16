import Base
import ../Sys.bend as S
import ../Box/Local.bend as Lc
import ../Box/Remote.bend as Rm
import ../Box/Chain.bend as Ch
import ../Box/Watch.bend as Wt
import ../Box/Scenario.bend as Sc
import ./Sim.bend as Sm

# bend-ops chain and watch (bend/Box/Chain.bend, Watch.bend, 2026-10-14): their
# decisions on run 3's files (fixtures/ops: chain.log's lines, s2.log's end, the
# sha256 listings) and on small cases; the sandbox's own pieces (bend-sim's ssh
# reading, the scenarios' stamp stripping and event lines).  Each check prints
# `ok NAME` or `FAIL NAME`; any FAIL exits 1.  Run from bend/tests.

type TCk is Data:
  TCk{name: String, ok: Bool}

def t.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "chain: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def t.say(cs: List<&2, TCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      t.end(Nat.is_eq(bad, 0n), bad, names)
    case TCk{+n, +ok} <> rest:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        t.say(rest, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

# Helpers --------------------------------------------------------------------------------------

def t.strs.eq(xs: List<&2, String>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(String.eq(x, y), t.strs.eq(xt, yt))
    case _ _:
      False{}

# saves NAME-step<FROM + k*STEP> for k in 0..n-1, then extra
def t.cks(n: Nat, +name: String, +at: Nat, +step: Nat) -> List<&2, Rm.RmtCk>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      Rm.RmtCk{at, S.b(name ++ "-step" ++ Nat.show(at) ++ ".checkpoint")} <> t.cks(k, name, Nat.add(at, step), step)

def t.ck(+name: String, +step: Nat) -> Rm.RmtCk:
  Rm.RmtCk{step, S.b(name ++ "-step" ++ Nat.show(step) ++ ".checkpoint")}

def t.n(+x: U32) -> Nat:
  U32.to_nat(x)

# run 3's two stages: s1 saved every 500 to 36500, then 36696; s2 every 500 from 37000 to 56500, then 56725
def t.run3() -> List<&2, Ch.ChnSaves>:
  [Ch.ChnSaves{t.n(5000), List.append(&2, Rm.RmtCk, t.cks(73n, "s1", 500n, 500n), [t.ck("s1", t.n(36696))])},
   Ch.ChnSaves{t.n(5000), List.append(&2, Rm.RmtCk, t.cks(40n, "s2", t.n(37000), 500n), [t.ck("s2", t.n(56725))])}]

def t.line(+text: List<&2, U32>, +k: Nat) -> List<&2, U32>:
  Lc.lcl.nth(S.split.lines(text), k)

# a chain.log line without its leading stamp
def t.body(+l: List<&2, U32>) -> String:
  S.str(List.drop(&2, U32, l, 28n))

def t.fv.ph(v: Ch.ChnFv) -> String:
  match v:
    case Ch.ChnFv{ph, fo}:
      Ch.chn.ph.word(ph)

def t.fv.quiet(v: Ch.ChnFv) -> Nat:
  match v:
    case Ch.ChnFv{ph, Ch.ChnFo{l, q}}:
      q

def t.fv.last(v: Ch.ChnFv) -> String:
  match v:
    case Ch.ChnFv{ph, Ch.ChnFo{l, q}}:
      l

def t.obs(+ok: Bool, +size: String, +procs: String, +tail: String) -> Ch.ChnObs:
  Ch.ChnObs{ok, size, procs, S.b(tail)}

def t.next.is(n: Ch.ChnNext, +want: Nat) -> Bool:
  match n:
    case Ch.ChnPass{}:
      Nat.is_eq(want, 0n)
    case Ch.ChnAgain{}:
      Nat.is_eq(want, 1n)
    case Ch.ChnRefuse{}:
      Nat.is_eq(want, 2n)

def t.hold.is(h: Ch.ChnHold, +want: Nat) -> Bool:
  match h:
    case Ch.ChnHoldWait{}:
      Nat.is_eq(want, 0n)
    case Ch.ChnHoldGo{}:
      Nat.is_eq(want, 1n)
    case Ch.ChnHoldTaken{}:
      Nat.is_eq(want, 2n)

def t.maybe.is(m: Maybe<&2, String>, +want: String) -> Bool:
  match m:
    case Some{s}:
      String.eq(s, want)
    case None{}:
      String.is_empty(want)

def t.d.is(d: Wt.CwtD, +ok: Bool, +why: String) -> Bool:
  match d:
    case Wt.CwtD{o, w}:
      Bool.and(Bool.not(Bool.xor(o, ok)), String.eq(w, why))

def t.ssh.is(p: Sm.SimSshP, +port: String, +n: Bool, +host: String, +cmd: List<&2, String>, +ok: Bool) -> Bool:
  match p:
    case Sm.SimSshP{po, nn, h, c, o}:
      Bool.and(Bool.and(Bool.and(String.eq(po, port), Bool.not(Bool.xor(nn, n))), Bool.and(String.eq(h, host), t.strs.eq(c, cmd))), Bool.not(Bool.xor(o, ok)))

def t.ssh.bad(p: Sm.SimSshP) -> Bool:
  match p:
    case Sm.SimSshP{po, nn, h, c, o}:
      Bool.not(o)

def t.flip(ss: List<&2, Lc.LclSum>, +k: Nat) -> List<&2, Lc.LclSum>:
  match ss:
    case Nil{}:
      Nil{}
    case Lc.LclSum{+h, n} <> rest:
      Lc.LclSum{Bool.pick(List<&2, U32>, Nat.is_eq(k, 1n), 48 <> List.drop(&2, U32, h, 1n), h), n} <> t.flip(rest, Nat.sub(k, 1n))

def t.names(ss: List<&2, Lc.LclSum>) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> rest:
      S.str(Lc.lcl.sum.name(s)) <> t.names(rest)

# Checks ---------------------------------------------------------------------------------------

def t.stages() -> String:
  "# run 3's stages\n\n  s1 traind 5000\n\t# a comment\ns2 traind-next 5000 run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m\n   \nraw7 traind-next 0 run/raw7/plan.tsv run/raw7 raw7\n"

def t.pure(+chain: List<&2, U32>, +s2: List<&2, U32>, +box: List<&2, U32>, +here: List<&2, U32>) -> List<&2, TCk>:
  +st = S.b(t.stages())
  +s2st = Ch.chn.stage.of(Maybe.default(&2, List<&2, U32>, Ch.chn.stage.at(st, 2n), Nil{}))
  +ss = t.run3()
  +lasts = {["s1-step36696.checkpoint", "s2-step56725.checkpoint"] : List<&2, String>}
  +want = Ch.chn.want(ss, lasts)
  +bs = Lc.lcl.sha.parse(box)
  +hs = Lc.lcl.sha.parse(here)
  +s2cks = Rm.rmt.saved.of(s2)
  +tail = List.drop(&2, U32, s2, Nat.sub(S.len(s2), 200n))
  +fo = {Ch.ChnFo{"0", 0n} : Ch.ChnFo}
  +v1 = Ch.chn.follow.next(fo, t.obs(True{}, "100", "1", "step=1"), 120n, t.n(1200))
  +v2 = Ch.chn.follow.next(Ch.ChnFo{"100", 0n}, t.obs(True{}, "100", "0", "x"), 120n, t.n(1200))
  +v3 = Ch.chn.follow.next(Ch.ChnFo{"100", t.n(1080)}, t.obs(True{}, "100", "0", "x"), 120n, t.n(1200))
  +v4 = Ch.chn.follow.next(Ch.ChnFo{"100", t.n(1080)}, t.obs(True{}, "120", "0", "x"), 120n, t.n(1200))
  +v5 = Ch.chn.follow.next(Ch.ChnFo{"100", 600n}, t.obs(True{}, "100", "", "x [stamp] done at step 9 "), 120n, t.n(1200))
  +v6 = Ch.chn.follow.next(Ch.ChnFo{"100", 600n}, t.obs(False{}, "", "", ""), 120n, t.n(1200))
  +ok = Ch.chn.verify.of(bs, hs, want, want)
  +flip = Ch.chn.verify.of(t.flip(bs, 4n), hs, want, want)
  +miss = Ch.chn.verify.of(bs, hs, want, List.drop(&2, String, want, 1n))
  +none = Ch.chn.verify.of(Nil{}, hs, want, want)
  [TCk{"stages: comments and blank lines skipped", Bool.and(String.eq(Ch.chn.st.name(s2st), "s2"), String.eq(Ch.chn.st.plan(s2st), "run/v3/S2/plan-fp100m-b16-windows.tsv"))},
   TCk{"stages: fields", Bool.and(Bool.and(String.eq(Ch.chn.st.bin(s2st), "traind-next"), String.eq(Ch.chn.st.every(s2st), "5000")),
     Bool.and(String.eq(Ch.chn.st.rdir(s2st), "run/v3/S2"), String.eq(Ch.chn.st.ssz(s2st), "fp100m")))},
   TCk{"stages: the first, the third, none past the end", Bool.and(Bool.and(S.eq(Maybe.default(&2, List<&2, U32>, Ch.chn.stage.at(st, 1n), Nil{}), S.b("  s1 traind 5000")),
     String.eq(Ch.chn.st.name(Ch.chn.stage.of(Maybe.default(&2, List<&2, U32>, Ch.chn.stage.at(st, 3n), Nil{}))), "raw7")),
     Bool.not(Maybe.is_some(&2, List<&2, U32>, Ch.chn.stage.at(st, 4n))))},
   TCk{"stage logs: LOG0 for the first, NAME.log after", Bool.and(String.eq(Ch.chn.log.of(1n, "s1", "train.log"), "train.log"), String.eq(Ch.chn.log.of(2n, "s2", "train.log"), "s2.log"))},
   TCk{"pull: multiples of EVERY (s2.log, 500)", t.strs.eq(Ch.chn.multiples(s2cks, 500n), ["s2-step37000.checkpoint", "s2-step37500.checkpoint"])},
   TCk{"pull: none for EVERY 0", List.is_empty(&2, String, Ch.chn.multiples(s2cks, 0n))},
   TCk{"prune: all but the newest, not multiples (EVERY 1000)", t.strs.eq(Ch.chn.prunable(s2cks, t.n(1000), Nil{}), ["s2-step37500.checkpoint"])},
   TCk{"prune: EVERY 0 keeps only the newest", t.strs.eq(Ch.chn.prunable(s2cks, 0n, Nil{}), ["s2-step37000.checkpoint", "s2-step37500.checkpoint"])},
   TCk{"prune: those removed before are not sent again", t.strs.eq(Ch.chn.prunable(s2cks, 0n, ["s2-step37000.checkpoint"]), ["s2-step37500.checkpoint"])},
   TCk{"last save", Bool.and(t.maybe.is(Ch.chn.last(s2cks), "s2-step56725.checkpoint"), t.maybe.is(Ch.chn.last(Nil{}), ""))},
   TCk{"follow: a trainer runs", Bool.and(String.eq(t.fv.ph(v1), "running"), Bool.and(Nat.is_eq(t.fv.quiet(v1), 0n), String.eq(t.fv.last(v1), "100")))},
   TCk{"follow: no trainer, the log still: quiet grows by POLL", Bool.and(String.eq(t.fv.ph(v2), "running"), Nat.is_eq(t.fv.quiet(v2), 120n))},
   TCk{"follow: still for DEAD_QUIET: died", Bool.and(String.eq(t.fv.ph(v3), "died"), Nat.is_eq(t.fv.quiet(v3), t.n(1200)))},
   TCk{"follow: the log grew: quiet 0", Bool.and(String.eq(t.fv.ph(v4), "running"), Nat.is_eq(t.fv.quiet(v4), 0n))},
   TCk{"follow: done at step", String.eq(t.fv.ph(v5), "done")},
   TCk{"follow: no answer changes nothing", Bool.and(String.eq(t.fv.ph(v6), "unknown"), Bool.and(Nat.is_eq(t.fv.quiet(v6), 600n), String.eq(t.fv.last(v6), "100")))},
   TCk{"progress line (run 3's s2.log done, byte for byte)", String.eq(Ch.chn.progress("s2.log", Ch.ChnDone{}, Ch.ChnObs{True{}, "3768631", "0", tail}),
     t.body(t.line(chain, 23n)))},
   TCk{"progress tail: bash's ${tail: -100} is empty under 100", Bool.and(String.eq(Ch.chn.last100(S.b("short\n")), ""),
     String.eq(Ch.chn.last100(S.b(String.repeat("a", 99n) ++ "\n")), String.repeat("a", 99n) ++ " "))},
   TCk{"eval line (run 3's, byte for byte)", String.eq("eval:" ++ Ch.chn.evals("", ss, lasts), t.body(t.line(chain, 27n)))},
   TCk{"eval line: EXTRA_EVAL first", String.starts_with(Ch.chn.evals("out/a.checkpoint out/b.checkpoint", ss, lasts), "out/a.checkpoint out/b.checkpoint  out/s1-step5000.checkpoint ")},
   TCk{"eval line: a last already there is not added", String.eq(Ch.chn.evals("", [Ch.ChnSaves{10n, [t.ck("a", 10n), t.ck("a", 20n)]}], ["a-step20.checkpoint"]),
     " out/a-step10.checkpoint out/a-step20.checkpoint ")},
   TCk{"eval line: an EVERY 0 stage adds nothing", String.eq(Ch.chn.evals("", [Ch.ChnSaves{0n, [t.ck("r", 10n)]}], ["r-step10.checkpoint"]), " out/r-step10.checkpoint")},
   TCk{"want: run 3's 13", Bool.and(Nat.is_eq(List.length(&2, String, want), 13n), String.eq(Maybe.default(&2, String, List.get(&2, String, want, 7n), ""), "s2-step40000.checkpoint"))},
   TCk{"verify: run 3 passes", Bool.and(Ch.chn.ver.ok(ok), t.next.is(Ch.chn.verify.next(ok, 1n), 0n))},
   TCk{"verify: one differs: mend (try 1), refuse at 12", Bool.and(Bool.and(t.next.is(Ch.chn.verify.next(flip, 1n), 1n), t.next.is(Ch.chn.verify.next(flip, 12n), 2n)),
     String.eq(Ch.chn.ver.why(flip), " not here with the box's sha256: s1-step25000.checkpoint;"))},
   TCk{"verify: a wanted one missing cannot be mended", Bool.and(t.next.is(Ch.chn.verify.next(miss, 1n), 2n),
     String.eq(Ch.chn.ver.why(miss), " wanted but not pulled: s1-step5000.checkpoint;"))},
   TCk{"verify: no sha256 from the box: mend", Bool.and(t.next.is(Ch.chn.verify.next(none, 1n), 1n), String.eq(Ch.chn.ver.why(none), " the box gave no sha256;"))},
   TCk{"verify: box ⊆ here (two only here)", Nat.is_eq(List.length(&2, String, Ch.chn.ver.unmatched(ok)), 0n)},
   TCk{"hold", Bool.and(Bool.and(t.hold.is(Ch.chn.hold.of(10n, Some{20n}, False{}), 0n), t.hold.is(Ch.chn.hold.of(20n, Some{20n}, False{}), 1n)),
     Bool.and(Bool.and(t.hold.is(Ch.chn.hold.of(10n, Some{20n}, True{}), 2n), t.hold.is(Ch.chn.hold.of(10n, None{}, True{}), 2n)), t.hold.is(Ch.chn.hold.of(10n, None{}, False{}), 1n)))},
   TCk{"tail -1", Bool.and(Bool.and(S.eq(Ch.chn.tail1(S.b("a\ntrainer pid 7; tail -f s2.log\n")), S.b("trainer pid 7; tail -f s2.log\n")), S.eq(Ch.chn.tail1(Nil{}), Nil{})),
     S.eq(Ch.chn.tail1(S.b("x")), S.b("x\n")))},
   TCk{"driver", Bool.and(Bool.and(Ch.chn.fp("./fp.sh"), Bool.not(Ch.chn.fp("./bend-box"))), Bool.and(Ch.chn.drv.ok("./bend-box"), Bool.not(Ch.chn.drv.ok("./x.sh"))))},
   TCk{"watch: REFUSED GRACE old is due, with its text", t.maybe.is(Wt.cwt.due(Some{t.n(3600)}, S.b("[2026-10-14 18:00:00 UTC-6]  wanted but not pulled: a;\n"), None{}, t.n(3600), t.n(5400)),
     "the chain refused the destroy ([2026-10-14 18:00:00 UTC-6]  wanted but not pulled: a; )")},
   TCk{"watch: REFUSED too young, CREDIT_LOW old enough", t.maybe.is(Wt.cwt.due(Some{10n}, Nil{}, Some{t.n(5400)}, t.n(3600), t.n(5400)),
     "the box is up 90 min after the trainer was stopped for the credit")},
   TCk{"watch: nothing due", Bool.and(t.maybe.is(Wt.cwt.due(None{}, Nil{}, Some{10n}, t.n(3600), t.n(5400)), ""), t.maybe.is(Wt.cwt.due(None{}, Nil{}, None{}, t.n(3600), t.n(5400)), ""))},
   TCk{"watch: the silence alert, once an hour", Bool.and(Bool.and(Wt.cwt.silent(False{}, Some{t.n(10800)}, t.n(10800), t.n(20000), 0n), Bool.not(Wt.cwt.silent(False{}, Some{t.n(10800)}, t.n(10800), t.n(20000), t.n(19000)))),
     Bool.and(Bool.not(Wt.cwt.silent(True{}, Some{t.n(10800)}, t.n(10800), t.n(20000), 0n)), Bool.not(Wt.cwt.silent(False{}, Some{10n}, t.n(10800), t.n(20000), 0n))))},
   TCk{"watch: box safe (run 3)", t.d.is(Wt.cwt.safe.of(Some{0n}, Some{0n}, bs, hs), True{}, "every checkpoint on the box (13) is here with its sha256")},
   TCk{"watch: a trainer runs, or the box did not answer", Bool.and(t.d.is(Wt.cwt.safe.of(Some{1n}, Some{0n}, bs, hs), False{}, "a trainer runs on the box, or it did not answer"),
     t.d.is(Wt.cwt.safe.of(Some{0n}, None{}, bs, hs), False{}, "a trainer runs on the box, or it did not answer"))},
   TCk{"watch: no sha256, or one not here", Bool.and(t.d.is(Wt.cwt.safe.of(Some{0n}, Some{0n}, Nil{}, hs), False{}, "the box gave no sha256"),
     t.d.is(Wt.cwt.safe.of(Some{0n}, Some{0n}, t.flip(bs, 1n), hs), False{}, "not here with the box's sha256: s1-step10000.checkpoint"))},
   TCk{"sim ssh: options, host, command words", t.ssh.is(Sm.sim.ssh.parse(["-n", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=30", "-p", "2222", "root@h", "cd", "x", "&&", "ls -l"]),
     "2222", True{}, "root@h", ["cd", "x", "&&", "ls -l"], True{})},
   TCk{"sim ssh: clusters and attached values", t.ssh.is(Sm.sim.ssh.parse(["-nTp22", "-oX=y", "-i", "k", "-l", "root", "h", "-v", "a"]), "22", True{}, "h", ["-v", "a"], True{})},
   TCk{"sim ssh: -- and no -n", t.ssh.is(Sm.sim.ssh.parse(["-q", "-J", "j", "--", "-h", "true"]), "22", False{}, "-h", ["true"], True{})},
   TCk{"sim ssh: a value missing, no host", Bool.and(t.ssh.bad(Sm.sim.ssh.parse(["-p"])), t.ssh.bad(Sm.sim.ssh.parse(["-n", "-T"])))},
   TCk{"sim: stamps stripped", S.eq(Sc.scn.unstamp(S.b("[2026-10-13 23:48:35 UTC-6] pulled x [2026-10-13 05:01:46 UTC-6] done at step 9 UTC-6] y")),
     S.b("pulled x done at step 9 UTC-6] y"))},
   TCk{"sim: event lines (no per-poll lines, pids masked, the watch's apart)", Bool.and(t.strs.eq(Sc.scn.events(S.b(
     "[2026-10-13 05:09:10 UTC-6] train.log running: 5 bytes, 1 trainer(s); x\n[2026-10-13 05:09:10 UTC-6] train.log: done\ntrainer pid 2034640; tail -f s2.log\n[2026-10-13 05:09:11 UTC-6] ssh failed; retrying\n[2026-10-13 05:09:12 UTC-6] credit-watch: credit $0.5 is under $1.00\n"), False{}),
     ["train.log: done", "trainer pid *; tail -f s2.log"]),
     t.strs.eq(Sc.scn.events(S.b("[2026-10-13 05:09:12 UTC-6] credit-watch: finished\nx\n"), True{}), ["credit-watch: finished"]))},
   TCk{"sim: multiset difference", t.strs.eq(Sc.scn.minus(["a", "b", "a", "c"], ["a", "c"]), ["b", "a"])}]

# from= (2026-10-15, run 4's control stage) ------------------------------------------------------

# run 4's chain: c1 hot-started (EVERY 1000), c2 appended by the hand-over, ctl from c1's boundary save
def t.run4() -> String:
  "c1 traind-next 1000\nc2 traind-next 1000 run/v4/C2/plan-fp100m-b16-windows.tsv run/v4/C2 fp100m\n"
    ++ "ctl traind-next 1000 run/v4/CTL/plan-fp100m-b16-windows.tsv run/v4/CTL fp100m from=out/c1-step68005.checkpoint\n"
    ++ "# a comment\nabs traind-next 0 from=/root/elsewhere/x-step5.checkpoint p r z\n"

# the same with raw stages (EVERY 0) and a save from= names twice
def t.raw4() -> String:
  "c1 traind-next 0\nc2 traind-next 0 p2 r2 z\nctl traind-next 0 p3 r3 z from=out/c1-step130.checkpoint\nagain traind-next 0 p4 r4 z from=out/c1-step130.checkpoint\n"

def t.after.is(+a: Ch.ChnAfter, +del: String, +why: String, +last: String) -> Bool:
  Bool.and(Bool.and(t.maybe.is(Ch.chn.after.del(a), del), String.eq(Ch.chn.after.why(a), why)), t.maybe.is(Ch.chn.after.last(a), last))

def t.from() -> List<&2, TCk>:
  +r4 = S.b(t.run4())
  +ls = Ch.chn.stage.lines(S.split.lines(r4))
  +ctl = Ch.chn.stage.of(Maybe.default(&2, List<&2, U32>, Ch.chn.stage.at(r4, 3n), Nil{}))
  +mid = Ch.chn.stage.of(S.b("ctl traind-next 1000 from=out/a-step5.checkpoint p r z"))
  +raw = S.b(t.raw4())
  +rls = Ch.chn.stage.lines(S.split.lines(raw))
  +run3 = S.b(t.stages())
  [TCk{"from=: a stage line's fields keep their places, from= last", Bool.and(Bool.and(String.eq(Ch.chn.st.name(ctl), "ctl"), String.eq(Ch.chn.st.every(ctl), "1000")),
     Bool.and(Bool.and(String.eq(Ch.chn.st.plan(ctl), "run/v4/CTL/plan-fp100m-b16-windows.tsv"), String.eq(Ch.chn.st.ssz(ctl), "fp100m")),
       String.eq(Ch.chn.st.from(ctl), "out/c1-step68005.checkpoint")))},
   TCk{"from=: anywhere after the name, the other words keep their order", Bool.and(Bool.and(String.eq(Ch.chn.st.plan(mid), "p"), String.eq(Ch.chn.st.ssz(mid), "z")),
     String.eq(Ch.chn.st.from(mid), "out/a-step5.checkpoint"))},
   TCk{"from=: a line without one reads as before and starts from out/PREV", Bool.and(String.is_empty(Ch.chn.st.from(Ch.chn.stage.of(Maybe.default(&2, List<&2, U32>, Ch.chn.stage.at(run3, 2n), Nil{})))),
     String.eq(Ch.chn.st.src(Ch.chn.stage.of(Maybe.default(&2, List<&2, U32>, Ch.chn.stage.at(run3, 2n), Nil{})), "s1-step36696.checkpoint"), "out/s1-step36696.checkpoint"))},
   TCk{"from=: a stage starts from its from=, not the stage before's last", String.eq(Ch.chn.st.src(ctl, "c2-step74005.checkpoint"), "out/c1-step68005.checkpoint")},
   TCk{"from=: the saves STAGES keeps (under out/ only), from the k-th line on", Bool.and(Bool.and(t.strs.eq(Ch.chn.keep.of(r4, 1n), ["c1-step68005.checkpoint"]),
     t.strs.eq(Ch.chn.keep.of(r4, 3n), ["c1-step68005.checkpoint"])), Bool.and(List.is_empty(&2, String, Ch.chn.keep.of(r4, 4n)), List.is_empty(&2, String, Ch.chn.keep.of(run3, 1n))))},
   TCk{"from=: the prune never takes a save a line starts from (60500 stays, 68005 goes)", t.strs.eq(Ch.chn.minus(Ch.chn.prunable([t.ck("c1", 60500n), t.ck("c1", 68005n), t.ck("c1", t.n(68500))], t.n(1000), Nil{}),
     Ch.chn.keep.of(S.b("c1 traind-next 1000\nx traind-next 0 p r z from=out/c1-step60500.checkpoint\n"), 1n)), ["c1-step68005.checkpoint"])},
   TCk{"from=: a save's stage and step", Bool.and(Bool.and(String.eq(Ch.chn.save.stage("c1-step68005.checkpoint"), "c1"), String.eq(Ch.chn.save.stage("a-step2-step10.checkpoint"), "a-step2")),
     Bool.and(Nat.is_eq(Rm.rmt.ck.step(Maybe.default(&2, Rm.RmtCk, Ch.chn.save.ck("a-step2-step10.checkpoint"), Rm.RmtCk{0n, Nil{}})), 10n),
       Bool.and(Bool.not(Maybe.is_some(&2, Rm.RmtCk, Ch.chn.save.ck("notes.txt"))), Bool.not(Maybe.is_some(&2, String, Ch.chn.save.of("/root/x-step5.checkpoint"))))))},
   TCk{"after: no from=, a raw stage's last goes once loaded (fp-chain.sh's rule)", Bool.and(t.after.is(Ch.chn.after("", "c1-step130.checkpoint", "c1", 0n, rls, Nil{}, Nil{}), "c1-step130.checkpoint", "a raw stage's", ""),
     t.after.is(Ch.chn.after("", "c1-step130.checkpoint", "c1", t.n(1000), rls, Nil{}, Nil{}), "", "a raw stage's", ""))},
   TCk{"after: no from=, a raw stage's last a later line names stays", t.after.is(Ch.chn.after("", "c1-step130.checkpoint", "c1", 0n, rls, Ch.chn.keep.of(raw, 2n), Nil{}), "", "a raw stage's", "")},
   TCk{"after: the from= save of a raw stage goes once its last user loaded it, not before", Bool.and(t.after.is(Ch.chn.after("out/c1-step130.checkpoint", "c2-step160.checkpoint", "c2", 0n, rls,
     Ch.chn.keep.of(raw, 4n), Nil{}), "", "a raw stage's", "c2-step160.checkpoint"), t.after.is(Ch.chn.after("out/c1-step130.checkpoint", "ctl-step160.checkpoint", "ctl", 0n, rls, Ch.chn.keep.of(raw, 5n), Nil{}),
       "c1-step130.checkpoint", "a raw stage's", "ctl-step160.checkpoint"))},
   TCk{"after: a from= save the chain pulls stays (a multiple of its EVERY, or a last)", Bool.and(t.after.is(Ch.chn.after("out/c1-step68000.checkpoint", "c2-step74005.checkpoint", "c2", t.n(1000), ls,
     Nil{}, Nil{}), "", "between its stage's pulls", ""), t.after.is(Ch.chn.after("out/c1-step68005.checkpoint", "c2-step74005.checkpoint", "c2", t.n(1000), ls, Nil{}, ["c1-step68005.checkpoint"]),
       "", "between its stage's pulls", ""))},
   TCk{"after: a from= save between its stage's pulls, no last, goes once loaded", t.after.is(Ch.chn.after("out/c1-step60500.checkpoint", "c2-step74005.checkpoint", "c2", t.n(1000), ls, Nil{}, Nil{}),
     "c1-step60500.checkpoint", "between its stage's pulls", "")},
   TCk{"after: a path outside out/, or a stage STAGES does not name, stays", Bool.and(t.after.is(Ch.chn.after("/root/elsewhere/x-step5.checkpoint", "", "", 0n, ls, Nil{}, Nil{}), "", "", ""),
     t.after.is(Ch.chn.after("out/zz-step5.checkpoint", "c2-step9.checkpoint", "c2", t.n(1000), ls, Nil{}, Nil{}), "", "between its stage's pulls", ""))},
   TCk{"after: the stage before's raw last that no stage loads is a last (a branch's end), once", Bool.and(t.after.is(Ch.chn.after("out/c1-step130.checkpoint", "c2-step160.checkpoint", "c2", 0n, rls,
     Nil{}, Nil{}), "c1-step130.checkpoint", "a raw stage's", "c2-step160.checkpoint"), t.after.is(Ch.chn.after("out/c1-step130.checkpoint", "c2-step160.checkpoint", "c2", 0n, rls, Nil{},
       ["c2-step160.checkpoint"]), "c1-step130.checkpoint", "a raw stage's", ""))}]

def main() -> IO(Unit):
  do IO<Unit>:
    +chain : List<&2, U32> <- S.read("fixtures/ops/chain.log")
    +s2 : List<&2, U32> <- S.read("fixtures/ops/s2.log")
    +box : List<&2, U32> <- S.read("fixtures/ops/sha256.box.txt")
    +here : List<&2, U32> <- S.read("fixtures/ops/sha256.txt")
    t.say(List.append(&2, TCk, t.pure(chain, s2, box, here), t.from()), 0n, "")
