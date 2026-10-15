import Base
import ../Sys.bend as S
import ../Box/Local.bend as Lc
import ../Box/Remote.bend as Rm
import ../Box/Evals.bend as Ev
import ../Box/RunCfg.bend as Rc
import ../Box/Unit.bend as Un
import ../Box/Guard.bend as Gd
import ../Box/Handover.bend as Hv
import ../Box/Move.bend as Mv

# The run drivers' pure parts (2026-10-15, the plan's Phase 4b: bend/Box/
# RunCfg, Unit, Guard, Handover and Move, from run 3's boot-guard.sh,
# s2-driver.sh and move.sh) against run 3's own files in fixtures/drive: its
# STAGES before and after the move (run3.stages.55552041, run3.stages), the
# hand-over's output (s2-driver.out: the accepted counts and its log line),
# the old box's log around the save resumed from (train-old.tail), the new
# box's push log (stage2.head), and fixtures/ops/chain.log's destroy line.
# Each check prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.  Run from
# bend/tests.

type DrvCk is Data:
  DrvCk{name: String, ok: Bool}

def drv.t.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "drive: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def drv.t.say(cs: List<&2, DrvCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      drv.t.end(Nat.is_eq(bad, 0n), bad, names)
    case DrvCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        drv.t.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def drv.t.strs.eq(xs: List<&2, String>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(String.eq(x, y), drv.t.strs.eq(xt, yt))
    case _ _:
      False{}

def drv.t.is(+got: List<&2, U32>, +want: String) -> Bool:
  S.eq(got, S.b(want))

# The config ----------------------------------------------------------------------------------------

def drv.t.cfg.text() -> String:
  "# a run\nhost root@154.12.38.116\nport 21869\nport 2222\n\nunit chain ft-fp-chain-v3 2G run/v3/run3/fp-chain.out\nunit watch ft-credit-watch-v3\n"
    ++ "env POLL=120 WAIT=7200\nenv SSH_TRIES=10\nboundary 36696\nact-pull yes\nact-ensure maybe\nbig 1234567890123\nempty\nstop-units u1 u2 # the act ssh\n"

def drv.t.unit.is(m: Maybe<&2, Rc.RcfUnit>, +n: String, +mem: String, +out: String) -> Bool:
  match m:
    case Some{+u}:
      Bool.and(Bool.and(String.eq(Rc.rcf.u.name(u), n), String.eq(Rc.rcf.u.mem(u), mem)), String.eq(Rc.rcf.u.out(u), out))
    case None{}:
      False{}

def drv.t.none(m: Maybe<&2, Rc.RcfUnit>) -> Bool:
  match m:
    case Some{u}:
      False{}
    case None{}:
      True{}

def drv.t.cfg() -> List<&2, DrvCk>:
  +k = Rc.rcf.of(S.b(drv.t.cfg.text()))
  [DrvCk{"config: a key's last line wins", String.eq(Rc.rcf.get(k, "port", ""), "2222")},
   DrvCk{"config: a missing key is its default", String.eq(Rc.rcf.get(k, "instance", "none"), "none")},
   DrvCk{"config: a key with no word is its default", String.eq(Rc.rcf.get(k, "empty", "d"), "d")},
   DrvCk{"config: an inline comment ends a line's words", drv.t.strs.eq(Rc.rcf.every(k, "stop-units"), ["u1", "u2"])},
   DrvCk{"config: env gathers every line", drv.t.strs.eq(Rc.rcf.every(k, "env"), ["POLL=120", "WAIT=7200", "SSH_TRIES=10"])},
   DrvCk{"config: unit chain NAME MEM OUT", drv.t.unit.is(Rc.rcf.unit(k, "chain"), "ft-fp-chain-v3", "2G", "run/v3/run3/fp-chain.out")},
   DrvCk{"config: a unit's MEM defaults to 4G, OUT to none", drv.t.unit.is(Rc.rcf.unit(k, "watch"), "ft-credit-watch-v3", "4G", "")},
   DrvCk{"config: no unit line, no unit", drv.t.none(Rc.rcf.unit(k, "handover"))},
   DrvCk{"config: numbers, and 13 digits are not one", Bool.and(Nat.is_eq(Rc.rcf.nat(k, "boundary", 0n), U32.to_nat(36696)), Nat.is_eq(Rc.rcf.nat(k, "big", 7n), 7n))},
   DrvCk{"config: yes, and anything else is the default", Bool.and(Rc.rcf.yes(k, "act-pull", False{}), Bool.not(Rc.rcf.yes(k, "act-ensure", False{})))},
   DrvCk{"config: the keys a step lacks", drv.t.strs.eq(Rc.rcf.missing(k, ["host", "dest", "boundary", "stages"]), ["dest", "stages"])},
   DrvCk{"config: a path under a directory", Bool.and(Bool.and(String.eq(Rc.rcf.at("/root/formalTransformer", "./bend-box"), "/root/formalTransformer/bend-box"),
     String.eq(Rc.rcf.at("/root/formalTransformer", "/abs/x"), "/abs/x")), String.eq(Rc.rcf.at("/r", "run/v3/S2"), "/r/run/v3/S2"))}]

# Units ---------------------------------------------------------------------------------------------

def drv.t.spec() -> Un.UntSpec:
  Un.UntSpec{"ft-fp-chain-v3", "2G", "run/v3/run3/fp-chain.out", ["POLL=120", "A=it's 1"],
    ["/r/run/gcroot-bend-ops/bin/bend-ops", "chain", "root@154.12.38.116", "21869", "55567872", "run/v3/run3", "run/v3/run3.stages"]}

def drv.t.opt.is(m: Maybe<&2, Un.UntOpt>, +mem: String, +out: String, +env: List<&2, String>, +cmd: List<&2, String>) -> Bool:
  match m:
    case Some{Un.UntOpt{+a, +b, +c, +d}}:
      Bool.and(Bool.and(String.eq(a, mem), String.eq(b, out)), Bool.and(drv.t.strs.eq(c, env), drv.t.strs.eq(d, cmd)))
    case _:
      False{}

def drv.t.opt.none(m: Maybe<&2, Un.UntOpt>) -> Bool:
  match m:
    case None{}:
      True{}
    case _:
      False{}

def drv.t.units() -> List<&2, DrvCk>:
  +argv = Un.unt.argv(drv.t.spec(), "/r")
  [DrvCk{"unit: the systemd-run line", drv.t.strs.eq(argv, ["systemd-run", "--user", "--unit=ft-fp-chain-v3", "-p", "MemoryMax=2G", "-p", "OOMPolicy=continue",
     "--working-directory=/r", "-p", "StandardOutput=append:/r/run/v3/run3/fp-chain.out", "-p", "StandardError=append:/r/run/v3/run3/fp-chain.out",
     "--setenv=POLL=120", "--setenv=A=it's 1", "--", "/r/run/gcroot-bend-ops/bin/bend-ops", "chain", "root@154.12.38.116", "21869", "55567872", "run/v3/run3", "run/v3/run3.stages"])},
   DrvCk{"unit: start's options, the command from the first other word (the runtime eats `--`)", drv.t.opt.is(Un.unt.opts(["--mem", "1G", "--env", "A=1", "--env", "B=2", "sleep", "5"], Un.UntOpt{"4G", "", Nil{}, Nil{}}), "1G", "", ["A=1", "B=2"], ["sleep", "5"])},
   DrvCk{"unit: or after a `--` that reached it; an option without its value refused", Bool.and(drv.t.opt.is(Un.unt.opts(["--out", "o", "--", "--mem"], Un.UntOpt{"4G", "", Nil{}, Nil{}}), "4G", "o", Nil{}, ["--mem"]),
     drv.t.opt.none(Un.unt.opts(["--mem"], Un.UntOpt{"4G", "", Nil{}, Nil{}})))},
   DrvCk{"unit: no OUT, no output properties", drv.t.strs.eq(Un.unt.argv(Un.UntSpec{"u", "4G", "", Nil{}, ["true"]}, "/r"),
     ["systemd-run", "--user", "--unit=u", "-p", "MemoryMax=4G", "-p", "OOMPolicy=continue", "--working-directory=/r", "--", "true"])},
   DrvCk{"unit: the line quoted for a shell", String.eq(Un.unt.line(["a", "it's 1", "", "x=y/z:1"]), "a 'it'\\''s 1' '' x=y/z:1")},
   DrvCk{"unit: the record reads back", drv.t.strs.eq(Un.unt.rec.of(Un.unt.rec.bytes(argv)), argv)},
   DrvCk{"unit: an empty word survives the record", drv.t.strs.eq(Un.unt.rec.of(Un.unt.rec.bytes(["a", "", "b"])), ["a", "", "b"])},
   DrvCk{"unit: is-active's word", Bool.and(String.eq(Un.unt.state.of(Lc.LclOut{0, S.b("active\n"), Nil{}}), "active"),
     String.eq(Un.unt.state.of(Lc.LclOut{4, Nil{}, S.b("Failed to connect to bus")}), "unknown"))},
   DrvCk{"unit: active and activating are busy, failed and inactive are not", Bool.and(Bool.and(Un.unt.busy("active"), Un.unt.busy("activating")),
     Bool.and(Bool.not(Un.unt.busy("failed")), Bool.not(Un.unt.busy("inactive"))))},
   DrvCk{"unit: names", Bool.and(Bool.and(Un.unt.name.ok("ft-fp-chain-v3"), Un.unt.name.ok("a_b.c@d:1")),
     Bool.and(Bool.and(Bool.not(Un.unt.name.ok("../x")), Bool.not(Un.unt.name.ok(""))), Bool.not(Un.unt.name.ok(".hidden"))))}]

# The guard -----------------------------------------------------------------------------------------

def drv.t.names(ss: List<&2, Un.UntSpec>) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      Un.unt.s.name(s) <> drv.t.names(t)

def drv.t.cmd(ss: List<&2, Un.UntSpec>) -> List<&2, String>:
  match ss:
    case Nil{}:
      Nil{}
    case Un.UntSpec{n, m, o, e, c} <> t:
      c

def drv.t.guard.cfg() -> List<&2, Ev.EvKv>:
  Rc.rcf.of(S.b("host root@154.12.38.116\nport 21869\ninstance 55567872\ndest run/v3/run3\nstages run/v3/run3.stages\nwatch-min 1.00\n"
    ++ "unit chain ft-fp-chain-v3 2G\nunit watch ft-credit-watch-v3 2G\nunit handover ft-v3-s2 2G\n"))

def drv.t.guard(+log: List<&2, U32>, +before: List<&2, U32>, +after: List<&2, U32>) -> List<&2, DrvCk>:
  +k = drv.t.guard.cfg()
  [DrvCk{"guard: run 3's chain.log says the destroy", Gd.grd.over(False{}, log, "55567872")},
   DrvCk{"guard: another instance's destroy is not this one's", Bool.not(Gd.grd.over(False{}, log, "55552041"))},
   DrvCk{"guard: DESTROYED alone", Gd.grd.over(True{}, Nil{}, "1")},
   DrvCk{"guard: run 3's STAGES before S2 has no s2", Bool.and(Bool.not(Gd.grd.has.stage(before, "s2")), Gd.grd.has.stage(before, "s1"))},
   DrvCk{"guard: after it, s2 (a commented s2 line is not one)", Bool.and(Gd.grd.has.stage(after, "s2"), Bool.not(Gd.grd.has.stage(S.b("#   s2 traind-next 5000\n"), "s2")))},
   DrvCk{"guard: before S2: chain, watch, hand-over", drv.t.strs.eq(drv.t.names(Gd.grd.specs(k, "/o", "/r/run3.cfg", before)), ["ft-fp-chain-v3", "ft-credit-watch-v3", "ft-v3-s2"])},
   DrvCk{"guard: after S2: chain and watch", drv.t.strs.eq(drv.t.names(Gd.grd.specs(k, "/o", "/r/run3.cfg", after)), ["ft-fp-chain-v3", "ft-credit-watch-v3"])},
   DrvCk{"guard: the chain's command line", drv.t.strs.eq(drv.t.cmd(Gd.grd.chain(k, "/o")), ["/o", "chain", "root@154.12.38.116", "21869", "55567872", "run/v3/run3", "run/v3/run3.stages"])},
   DrvCk{"guard: the watch's, with MIN", drv.t.strs.eq(drv.t.cmd(Gd.grd.watch(k, "/o")), ["/o", "watch", "root@154.12.38.116", "21869", "run/v3/run3", "1.00"])},
   DrvCk{"guard: the hand-over's", drv.t.strs.eq(drv.t.cmd(Gd.grd.handover(k, "/o", "/r/run3.cfg")), ["/o", "handover", "/r/run3.cfg"])},
   DrvCk{"guard: the persistent unit", S.infix(S.b(Gd.grd.service("/r/c.cfg", "/r", "/o")), S.b("\nType=oneshot\nExecStartPre=/usr/bin/env sleep 60\nWorkingDirectory=/r\nExecStart=/o guard /r/c.cfg\n"))}]

# The hand-over -------------------------------------------------------------------------------------

def drv.t.out.lines(ls: List<&2, List<&2, U32>>, +keep: Bool) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +ws = Lc.lcl.words(l)
      +hit = Bool.and(Nat.is_eq(List.length(&2, List<&2, U32>, ws), 2n), Bool.and(S.infix(Lc.lcl.nth(ws, 0n), [45]), Rc.rcf.digits(Lc.lcl.nth(ws, 1n))))
      +rest = drv.t.out.lines(t, keep)
      Bool.pick(List<&2, List<&2, U32>>, hit, l <> rest, rest)

# the `NAME COUNT` lines of s2-driver.out (its loop over accepted/*/)
def drv.t.counts(+out: List<&2, U32>) -> List<&2, List<&2, U32>>:
  drv.t.out.lines(S.split.lines(out), True{})

def drv.t.names.of(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Lc.lcl.nth(Lc.lcl.words(l), 0n) <> drv.t.names.of(t)

# what `grep -H -c -z '' -- NAME/transcripts.train.nul...` printed for those counts (NULs: twice the records)
def drv.t.grep.of(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +ws = Lc.lcl.words(l)
      List.concat(&2, U32, [Lc.lcl.nth(ws, 0n), S.b("/transcripts.train.nul:" ++ Nat.show(Nat.mul(2n, Maybe.default(&2, Nat, Lc.lcl.nat(Lc.lcl.nth(ws, 1n)), 0n))) ++ "\n"), drv.t.grep.of(t)])

def drv.t.unlines(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      List.concat(&2, U32, [l, [10], drv.t.unlines(t)])

def drv.t.hand(+out: List<&2, U32>) -> List<&2, DrvCk>:
  +ls = drv.t.counts(out)
  +ns = Lc.lcl.sort(drv.t.names.of(ls))
  +cs = Hv.hov.counts.of(ns, drv.t.grep.of(ls))
  +run3 = {"s2 traind-next 5000 run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m" : String}
  +tail = S.b("[2026-10-13 05:19:22 UTC-6] s2: plan-windows run/v3/S2.ep/w fp100m 16 ...\n\n  shard 0: bend-windows failed (exit 1): windows: a transcript of 2158 tokens does not fit a window of 2046\n\n")
  [DrvCk{"handover: s2-driver.out's ten accepted directories", Nat.is_eq(List.length(&2, List<&2, U32>, ls), 10n)},
   DrvCk{"handover: their counts as s2-driver.out printed them", S.eq(Hv.hov.counts.lines(cs), drv.t.unlines(ls))},
   DrvCk{"handover: run 3's `accepted:` line", S.infix(out, S.b("] s2-driver: accepted: " ++ Hv.hov.counts.line(cs) ++ "\n"))},
   DrvCk{"handover: a directory grep did not count is 0", String.eq(Hv.hov.counts.line(Hv.hov.counts.of([S.b("x-act")], S.b("y-act/transcripts.train.nul:4\n"))), "x-act:0 ")},
   DrvCk{"handover: run 3's stage line, relative or absolute", Bool.and(Bool.and(Hv.hov.line.ok(run3, "5000", "run/v3/S2", "/root/formalTransformer/run/v3/S2"),
     Hv.hov.line.ok("s2 traind-next 5000 /root/formalTransformer/run/v3/S2/plan-fp100m-b16-windows.tsv /root/formalTransformer/run/v3/S2 fp100m", "5000", "run/v3/S2", "/root/formalTransformer/run/v3/S2")),
     Bool.not(Hv.hov.line.ok("s2 traind-next 1000 run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m", "5000", "run/v3/S2", "/x")))},
   DrvCk{"handover: the appended line", String.eq(Hv.hov.stage.line("s2", "5000", "run/v3/S2"), run3)},
   DrvCk{"handover: run 3's stage.env passes, one without NWARM=10 does not", Bool.and(Hv.hov.env.ok(S.b("NLR=8.288989e-05\nNWARM=10\n")),
     Bool.and(Bool.not(Hv.hov.env.ok(S.b("NLR=8.288989e-05\nNWARM=9\n"))), Bool.not(Hv.hov.env.ok(S.b("NWARM=10\n")))))},
   DrvCk{"handover: stage.env as one line", String.eq(Hv.hov.spaced(S.b("NLR=8.288989e-05\nNWARM=10\n")), "NLR=8.288989e-05 NWARM=10 ")},
   DrvCk{"handover: run 3's `s2.sh failed:` text from s2.log's last 3 lines", String.eq(Hv.hov.joined(Hv.hov.last.n(S.split.lines(tail), 3n)),
     "   shard 0: bend-windows failed (exit 1): windows: a transcript of 2158 tokens does not fit a window of 2046  ")},
   DrvCk{"handover: s2.log's lines logged as `read -r` read them", drv.t.strs.eq(Hv.hov.lines.say([S.b("  a b "), S.b("\tc")]), ["  a b", "  c"])},
   DrvCk{"handover: the act round's last line", Bool.and(Hv.hov.act.done.of(S.b("[2026-10-13 05:01:09 UTC-6] agent-act: done\n")),
     Bool.not(Hv.hov.act.done.of(S.b("[2026-10-12 08:58:59 UTC-6] 9408 haskell repair unsolved, 0 calls, 3.9 s\n"))))},
   DrvCk{"handover: grep -c's count, else 0", Bool.and(String.eq(Hv.hov.count.text(Lc.LclOut{0, S.b("9408\n"), Nil{}}), "9408"),
     String.eq(Hv.hov.count.text(Lc.LclOut{2, Nil{}, S.b("grep: x: No such file or directory")}), "0"))},
   DrvCk{"handover: the appended line starts a line of its own", Bool.and(S.eq(Hv.hov.append.text(S.b("s1 traind 5000"), "s2 x"), S.b("\ns2 x\n")),
     Bool.and(S.eq(Hv.hov.append.text(S.b("s1 traind 5000\n"), "s2 x"), S.b("s2 x\n")), S.eq(Hv.hov.append.text(Nil{}, "s2 x"), S.b("s2 x\n"))))}]

# The move ------------------------------------------------------------------------------------------

def drv.t.move(+old: List<&2, U32>, +push: List<&2, U32>, +before: List<&2, U32>, +after: List<&2, U32>) -> List<&2, DrvCk>:
  +fixed = Mv.mov.stages.fix(before, "s1")
  [DrvCk{"move: the old box's log records s1-step4000", Mv.mov.saved.has(Some{Rm.rmt.saved.of(old)}, "s1-step4000.checkpoint")},
   DrvCk{"move: not s1-step5000, and a box that did not answer records nothing", Bool.and(Bool.not(Mv.mov.saved.has(Some{Rm.rmt.saved.of(old)}, "s1-step5000.checkpoint")),
     Bool.not(Mv.mov.saved.has(None{}, "s1-step4000.checkpoint")))},
   DrvCk{"move: the new box's push log passed shards 70 and 71, not 73", Bool.and(Bool.and(Mv.mov.pushed(push, "71"), Mv.mov.pushed(push, "70")), Bool.not(Mv.mov.pushed(push, "73")))},
   DrvCk{"move: shard 7 is not shard 71", Bool.not(Mv.mov.pushed(push, "7"))},
   DrvCk{"move: STAGES' s1 line names traind-next, as run 3's was edited by hand", S.infix(fixed, S.b("\ns1 traind-next 5000\n"))},
   DrvCk{"move: the rest of STAGES unchanged", S.eq(S.replace(fixed, S.b("\ns1 traind-next 5000\n"), S.b("\ns1 traind 5000\n")), before)},
   DrvCk{"move: run 3's edited STAGES left as it is", S.eq(Mv.mov.stages.fix(after, "s1"), after)},
   DrvCk{"move: the cut log's name, as run 3's", String.eq(Mv.mov.to.name("train.log", "4000"), "train-to-4000.log")},
   DrvCk{"move: tail -2 | cut -c1-120", S.eq(Mv.mov.cut120([List.replicate(U32, 130n, 97), S.b("b")]), List.concat(&2, U32, [List.replicate(U32, 120n, 97), [10, 98, 10]]))}]

# the old log cut at the save, as sed '/saved out\/s1-step4000.checkpoint/q' cut it
def drv.t.upto(+old: List<&2, U32>) -> IO(List<&2, DrvCk>):
  do IO<List<&2, DrvCk>>:
    found : Bool <- Mv.mov.upto("fixtures/drive/train-old.tail", "saved out/s1-step4000.checkpoint", "drive-cut.tmp")
    +got : List<&2, U32> <- S.read("drive-cut.tmp")
    no : Bool <- Mv.mov.upto("fixtures/drive/train-old.tail", "saved out/s1-step5000.checkpoint", "drive-cut.tmp")
    S.rm("drive-cut.tmp")
    +want : List<&2, U32> = List.append(&2, U32, S.join(List.take(&2, List<&2, U32>, S.split.lines(old), 4n), 10), [10])
    return [DrvCk{"move: the old log up to and with the save line", Bool.and(found, S.eq(got, want))}, DrvCk{"move: a log without the save says so", Bool.not(no)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +log : List<&2, U32> <- S.read("fixtures/ops/chain.log")
    +before : List<&2, U32> <- S.read("fixtures/drive/run3.stages.55552041")
    +after : List<&2, U32> <- S.read("fixtures/drive/run3.stages")
    +out : List<&2, U32> <- S.read("fixtures/drive/s2-driver.out")
    +old : List<&2, U32> <- S.read("fixtures/drive/train-old.tail")
    +push : List<&2, U32> <- S.read("fixtures/drive/stage2.head")
    up : List<&2, DrvCk> <- drv.t.upto(old)
    drv.t.say(List.concat(&2, DrvCk, [drv.t.cfg(), drv.t.units(), drv.t.guard(log, before, after), drv.t.hand(out), drv.t.move(old, push, before, after), up]), 0n, "")
