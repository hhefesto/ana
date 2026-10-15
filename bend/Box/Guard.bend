import Base
import ../Sys.bend as S
import ./Local.bend as Lc
import ./Alert.bend as Al
import ./Evals.bend as Ev
import ./RunCfg.bend as Rc
import ./Unit.bend as Un

# Guard: a run's units back after a boot (2026-10-15, the plan's Phase 4b:
# run 3's run/v3/run3/boot-guard.sh, and run 2's before it, made generic and
# driven by the run's config, tools/runs/*.cfg).
#
#   bend-ops guard CFG           unless DEST/DESTROYED exists or DEST/chain.log already says
#                                `destroy instance INSTANCE`: each unit the config names that
#                                is not active is started again (bend/Box/Unit.bend: reset-failed,
#                                its record, systemd-run) and `boot-guard: restarted NAME after
#                                a boot` goes to chain.log:
#                                  unit chain     OPS chain HOST PORT INSTANCE DEST STAGES
#                                  unit watch     OPS watch HOST PORT DEST [WATCH_MIN]
#                                  unit handover  OPS handover CFG, until STAGES has a line for
#                                                 the hand-over's stage (s2-stage, s2)
#   bend-ops guard CFG install   the persistent user unit (guard-unit's NAME.service under
#                                SYSTEMD_USER_DIR, ~/.config/systemd/user) that runs `OPS guard
#                                CFG` 60 s after each boot, then daemon-reload and enable (run
#                                3's ft-run3-guard.service, written by hand)
#   bend-ops guard CFG --dry-run the systemd-run lines a guard run would start now, nothing started
#
# A unit's memory cap, output file and environment are the config's (`unit
# ROLE NAME MEM OUT`, `env K=V...`); OPS is the config's `ops` (a gcroot of
# .#bend-ops) or this program.  Run from the repository root.  What differs
# from boot-guard.sh, on purpose: a unit that does not start is said in
# chain.log (`boot-guard: could not start NAME: ...`) and the guard exits 1
# (the script logged nothing); a unit that is activating is left alone too;
# the units run bend-ops, not the scripts, with their output appended by
# systemd (StandardOutput=append:), not by `bash -c '... >> OUT 2>&1'`.
# Every name starts with `grd.`; the decisions are tested in
# bend/tests/drive.bend.

# Decisions (pure) -------------------------------------------------------------------------------

# the box is gone, or the chain said it destroys it (`grep -q 'destroy instance N' chain.log`)
def grd.over(+gone: Bool, +log: List<&2, U32>, +inst: String) -> Bool:
  Bool.or(gone, S.infix(log, S.b("destroy instance " ++ inst)))

def grd.has.lines(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(S.prefix(l, p), grd.has.lines(t, p))

# STAGES has a line for stage NAME (`grep -q '^NAME ' STAGES`)
def grd.has.stage(+stages: List<&2, U32>, +name: String) -> Bool:
  grd.has.lines(S.split.lines(stages), S.b(name ++ " "))

def grd.spec(m: Maybe<&2, Rc.RcfUnit>, +env: List<&2, String>, +cmd: List<&2, String>) -> List<&2, Un.UntSpec>:
  match m:
    case None{}:
      Nil{}
    case Some{+u}:
      [Un.UntSpec{Rc.rcf.u.name(u), Rc.rcf.u.mem(u), Rc.rcf.u.out(u), env, cmd}]

def grd.min(+v: String) -> List<&2, String>:
  Bool.pick(List<&2, String>, String.is_empty(v), Nil{}, [v])

# the chain's, the watch's and the hand-over's units and command lines
def grd.chain(+kvs: List<&2, Ev.EvKv>, +ops: String) -> List<&2, Un.UntSpec>:
  grd.spec(Rc.rcf.unit(kvs, "chain"), Rc.rcf.every(kvs, "env"),
    [ops, "chain", Rc.rcf.get(kvs, "host", ""), Rc.rcf.get(kvs, "port", ""), Rc.rcf.get(kvs, "instance", ""), Rc.rcf.get(kvs, "dest", ""), Rc.rcf.get(kvs, "stages", "")])

def grd.watch(+kvs: List<&2, Ev.EvKv>, +ops: String) -> List<&2, Un.UntSpec>:
  grd.spec(Rc.rcf.unit(kvs, "watch"), Rc.rcf.every(kvs, "env"),
    List.append(&2, String, [ops, "watch", Rc.rcf.get(kvs, "host", ""), Rc.rcf.get(kvs, "port", ""), Rc.rcf.get(kvs, "dest", "")], grd.min(Rc.rcf.get(kvs, "watch-min", ""))))

def grd.handover(+kvs: List<&2, Ev.EvKv>, +ops: String, +cfg: String) -> List<&2, Un.UntSpec>:
  grd.spec(Rc.rcf.unit(kvs, "handover"), Rc.rcf.every(kvs, "env"), [ops, "handover", cfg])

def grd.stage(+kvs: List<&2, Ev.EvKv>) -> String:
  Rc.rcf.get(kvs, "s2-stage", "s2")

# what the guard keeps up: the chain, the watch, and the hand-over until its stage is in STAGES
def grd.specs(+kvs: List<&2, Ev.EvKv>, +ops: String, +cfg: String, +stages: List<&2, U32>) -> List<&2, Un.UntSpec>:
  List.concat(&2, Un.UntSpec, [grd.chain(kvs, ops), grd.watch(kvs, ops),
    Bool.pick(List<&2, Un.UntSpec>, grd.has.stage(stages, grd.stage(kvs)), Nil{}, grd.handover(kvs, ops, cfg))])

# the persistent unit's file
def grd.service(+cfg: String, +cwd: String, +ops: String) -> String:
  "[Unit]\nDescription=bend-ops guard " ++ cfg ++ ": the run's units back after a boot\nAfter=default.target network-online.target\n\n"
    ++ "[Service]\nType=oneshot\nExecStartPre=/usr/bin/env sleep 60\nWorkingDirectory=" ++ cwd ++ "\nExecStart=" ++ ops ++ " guard " ++ cfg ++ "\n\n"
    ++ "[Install]\nWantedBy=default.target\n"

# Running ----------------------------------------------------------------------------------------

def grd.log(+dest: String, +msg: String) -> IO(Unit):
  Al.alr.log(dest ++ "/chain.log", "boot-guard: " ++ msg)

def grd.said(r: Un.UntRes, +name: String, +dest: String) -> IO(Nat):
  match r:
    case Un.UntActive{st}:
      IO.pure(Nat, 0n)
    case Un.UntStarted{}:
      do IO<Nat>:
        grd.log(dest, "restarted " ++ name ++ " after a boot")
        return 0n
    case Un.UntFailed{+w}:
      do IO<Nat>:
        grd.log(dest, "could not start " ++ name ++ ": " ++ w)
        return 1n

# each unit started unless it is active; how many did not start
def grd.start(ss: List<&2, Un.UntSpec>, +cwd: String, +dest: String) -> IO(Nat):
  match ss:
    case Nil{}:
      IO.pure(Nat, 0n)
    case +s <> t:
      do IO<Nat>:
        r : Un.UntRes <- Un.unt.ensure(s, cwd)
        +k : Nat <- grd.said(r, Un.unt.s.name(s), dest)
        +rest : Nat <- grd.start(t, cwd, dest)
        return Nat.add(k, rest)

def grd.fin(+bad: Nat) -> IO(Unit):
  Bool.pick(IO(Unit), Nat.is_eq(bad, 0n), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "boot-guard: " ++ Nat.show(bad) ++ " unit(s) did not start"))

def grd.go(over: Bool, +kvs: List<&2, Ev.EvKv>, +cfg: String) -> IO(Unit):
  match over:
    case True{}:
      IO.print_err("boot-guard: " ++ Rc.rcf.get(kvs, "dest", "") ++ ": the box is destroyed; nothing to do")
    case False{}:
      do IO<Unit>:
        +cwd : String <- S.realpath(".")
        +ops : String <- Rc.rcf.ops(kvs, cwd)
        +st : List<&2, U32> <- S.read(Rc.rcf.get(kvs, "stages", ""))
        +bad : Nat <- grd.start(grd.specs(kvs, ops, Rc.rcf.at(cwd, cfg), st), cwd, Rc.rcf.get(kvs, "dest", ""))
        grd.fin(bad)

def grd.run(+cfg: String) -> IO(Unit):
  do IO<Unit>:
    +kvs : List<&2, Ev.EvKv> <- Rc.rcf.read(cfg)
    Rc.rcf.need(kvs, ["host", "port", "instance", "dest", "stages"], cfg)
    +dest : String = Rc.rcf.get(kvs, "dest", "")
    +gone : Bool <- S.exists(dest ++ "/DESTROYED")
    +log : List<&2, U32> <- S.read(dest ++ "/chain.log")
    grd.go(grd.over(gone, log, Rc.rcf.get(kvs, "instance", "")), kvs, cfg)

def grd.ctl.ok(+o: Lc.LclOut, +what: String) -> IO(Unit):
  do IO<Unit>:
    Un.unt.err(List.append(&2, U32, Lc.lcl.out(o), Lc.lcl.err(o)))
    Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "boot-guard: systemctl --user " ++ what ++ " exit " ++ U32.show(Lc.lcl.status(o))))

def grd.install(+kvs: List<&2, Ev.EvKv>, +cfg: String) -> IO(Unit):
  +name = Rc.rcf.get(kvs, "guard-unit", "")
  do IO<Unit>:
    Rc.rcf.need(kvs, ["guard-unit"], cfg)
    Un.unt.name.need(name)
    +cwd : String <- S.realpath(".")
    +ops : String <- Rc.rcf.ops(kvs, cwd)
    +home : String <- S.env("HOME", "")
    +d0 : String <- S.env("SYSTEMD_USER_DIR", "")
    +dir : String = Rc.rcf.or(d0, home ++ "/.config/systemd/user")
    +f : String = dir ++ "/" ++ name ++ ".service"
    S.mkdir(dir)
    S.write(f, S.b(grd.service(Rc.rcf.at(cwd, cfg), cwd, ops)))
    +r : Lc.LclOut <- Un.unt.ctl(["daemon-reload"])
    grd.ctl.ok(r, "daemon-reload")
    +e : Lc.LclOut <- Un.unt.ctl(["enable", name ++ ".service"])
    grd.ctl.ok(e, "enable")
    IO.print_err("boot-guard: " ++ f ++ " written and enabled: `" ++ ops ++ " guard " ++ Rc.rcf.at(cwd, cfg) ++ "` 60 s after each boot")


# a configured unit's name, as a list (none: empty)
def grd.spec.names(m: Maybe<&2, Rc.RcfUnit>) -> List<&2, String>:
  match m:
    case None{}:
      Nil{}
    case Some{+u}:
      [Rc.rcf.u.name(u)]

# --dry-run: what a guard run would start now, as lines, nothing started
def grd.dry.lines(ss: List<&2, Un.UntSpec>, +cwd: String) -> IO(Unit):
  match ss:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +s <> t:
      do IO<Unit>:
        IO.print(Un.unt.line(Un.unt.argv(s, cwd)))
        grd.dry.lines(t, cwd)

def grd.dry.go(over: Bool, +kvs: List<&2, Ev.EvKv>, +cfg: String) -> IO(Unit):
  match over:
    case True{}:
      IO.print("# the box is destroyed: nothing would start")
    case False{}:
      do IO<Unit>:
        +cwd : String <- S.realpath(".")
        +o : String = Rc.rcf.get(kvs, "ops", "")
        +self : String <- Rc.rcf.self()
        +st : List<&2, U32> <- S.read(Rc.rcf.get(kvs, "stages", ""))
        IO.print("# each line runs when its unit is not active (ops " ++ Bool.pick(String, String.is_empty(o), self, Rc.rcf.at(cwd, o)) ++ ")")
        grd.dry.lines(grd.specs(kvs, Bool.pick(String, String.is_empty(o), self, Rc.rcf.at(cwd, o)), Rc.rcf.at(cwd, cfg), st), cwd)

def grd.dry(+cfg: String) -> IO(Unit):
  do IO<Unit>:
    +kvs : List<&2, Ev.EvKv> <- Rc.rcf.read(cfg)
    Rc.rcf.need(kvs, ["host", "port", "instance", "dest", "stages"], cfg)
    +dest : String = Rc.rcf.get(kvs, "dest", "")
    +gone : Bool <- S.exists(dest ++ "/DESTROYED")
    +log : List<&2, U32> <- S.read(dest ++ "/chain.log")
    grd.dry.go(grd.over(gone, log, Rc.rcf.get(kvs, "instance", "")), kvs, cfg)

def grd.usage() -> String:
  "usage: bend-ops guard CFG [install|--dry-run]   (tools/runs/TEMPLATE.cfg; UNIT_STATE, SYSTEMD_USER_DIR)"

def grd.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +cfg <> Nil{}:
      grd.run(cfg)
    case +cfg <> "--dry-run" <> Nil{}:
      grd.dry(cfg)
    case +cfg <> "install" <> Nil{}:
      do IO<Unit>:
        +kvs : List<&2, Ev.EvKv> <- Rc.rcf.read(cfg)
        grd.install(kvs, cfg)
    case _:
      IO.die(Unit, 2, grd.usage())
