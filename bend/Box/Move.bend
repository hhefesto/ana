import Base
import ../Sys.bend as S
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./Alert.bend as Al
import ./ActBox.bend as Ab
import ./Act.bend as Ac
import ./Evals.bend as Ev
import ./RunCfg.bend as Rc
import ./Unit.bend as Un
import ./Guard.bend as Gd
import ./Handover.bend as Hv
import ../CorpusV2/AgentAct.bend as Aa

# Move: a run from one box to another mid-stage (2026-10-15, the plan's Phase
# 4b: run 3's run/v3/run3/move.sh, 2026-10-12, when vast 55552041 reached its
# contract's end, made generic and driven by the run's config).  Edit the
# config first: old-host/old-port/old-instance the box left, host/port/instance
# the new one.  Each step is run by hand, in order:
#
#   bend-ops move CFG old-stop   the old box: its log must say `saved out/NAME-stepS.checkpoint`
#                                (move-name, move-step), else nothing is touched; then the local
#                                chain and watch units (and stop-units) stopped, the act round
#                                stopped (bend-box act-stop), the trainers (move-trainers) killed
#   bend-ops move CFG old-pull   NAME-stepS here (sha256 checked against the old box), the old
#                                box's top-level logs into DEST/oldbox, the act round (act-dir and
#                                its log) into DEST/rescue/act, cut here to whole records (bend-box's
#                                cut-frames and cut-pairs, in this process)
#   bend-ops move CFG restage    `bend-ops stage restage HOST PORT DEST/out/NAME-stepS.checkpoint
#                                [move-restage...]` for a new box not staged by `stage box`
#   bend-ops move CFG resume     the new box: the files move-need there, the push log move-pushed
#                                past its shard, G2 PASS in move-gate; NAME-stepS sent (sha256
#                                checked), the old log up to that save as NAME.log, hard-linked as
#                                trainer-log (which must not be there), then `bend-box resume
#                                out/NAME-stepS PLAN RUN SHARD NAME TO-S` (SAVE=move-save); STAGES'
#                                NAME line names traind-next (resume's trainer), the old file kept
#                                as STAGES.OLD_INSTANCE
#   bend-ops move CFG watch      the chain and the credit watch units on the new box (bend/Box/Unit),
#                                and the hand-over unit stopped and started again (it read the old
#                                box from the config) until its stage is in STAGES
#   bend-ops move CFG act        `bend-ops act ensure HOST PORT ACT_CKPT DIR DEST/rescue/act/DIR's`:
#                                the act round resumed on the new box (run 3's act-restart.sh)
#   bend-ops move CFG old-check  every checkpoint on the old box here with its sha256 (then destroy
#                                the old box by hand)
#
# Log lines are `[stamp UTC-6] move: ...` in DEST/chain.log and on stderr.
# What differs from move.sh, on purpose: old-stop checks the save before it
# stops anything (the script stopped the chain, the watch and the act round
# first, then refused, leaving a billing box unguarded); the cuts are Bend's
# (the script's cut_frames died of SIGPIPE under `set -o pipefail` once the
# eplog passed the pipe's buffer: `tail -c +OFF F | head -c 40`); resume
# refuses, saying why, when trainer-log is on the new box (the script's
# `[ ! -e train.log ] && ...` failed silently), uses bend-box resume, and
# rewrites STAGES (by hand in run 3); watch restarts the hand-over (by hand in
# run 3); act is `act ensure` (act-restart.sh: setup and the checkpoint
# retried, the round's agent.nul checked by sha256, started only when none
# runs); a step that fails says so in chain.log.  Every name starts with
# `mov.`; the decisions are tested in bend/tests/drive.bend.

type MovCx is Data:
  MovCx{h: Hv.HovCx, old: Rm.RmtBox}

def mov.h(+c: MovCx) -> Hv.HovCx:
  match c:
    case MovCx{h, o}:
      h

def mov.old(+c: MovCx) -> Rm.RmtBox:
  match c:
    case MovCx{h, o}:
      o

def mov.k(+c: MovCx, +key: String, +d: String) -> String:
  Hv.hov.k(mov.h(c), key, d)

def mov.kvs(+c: MovCx) -> List<&2, Ev.EvKv>:
  Hv.hov.kvs(mov.h(c))

def mov.dest(+c: MovCx) -> String:
  Hv.hov.dest(mov.h(c))

def mov.td(+c: MovCx) -> String:
  Hv.hov.td(mov.h(c))

def mov.name(+c: MovCx) -> String:
  mov.k(c, "move-name", "")

def mov.step(+c: MovCx) -> String:
  mov.k(c, "move-step", "")

# the save resumed from
def mov.ck(+c: MovCx) -> String:
  mov.name(c) ++ "-step" ++ mov.step(c) ++ ".checkpoint"

def mov.log0(+c: MovCx) -> String:
  mov.k(c, "trainer-log", "train.log")

def mov.log(+c: MovCx, +msg: String) -> IO(Unit):
  Al.alr.log(mov.dest(c) ++ "/chain.log", "move: " ++ msg)

def mov.fail(+c: MovCx, +msg: String) -> IO(Unit):
  do IO<Unit>:
    mov.log(c, msg)
    IO.die(Unit, 1, "move: stopped")

def mov.need(ok: Bool, +c: MovCx, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      mov.fail(c, msg)

def mov.cx(+cfg: String, keys: List<&2, String>) -> IO(MovCx):
  do IO<MovCx>:
    +kvs : List<&2, Ev.EvKv> <- Rc.rcf.read(cfg)
    Rc.rcf.need(kvs, List.append(&2, String, ["dest", "trainer-dir"], keys), cfg)
    +h : Hv.HovCx <- Hv.hov.cx.of(kvs, cfg)
    +o : Rm.RmtBox <- Rm.rmt.box(Rc.rcf.get(kvs, "old-host", ""), Rc.rcf.get(kvs, "old-port", ""))
    return MovCx{h, o}

# Decisions (pure) ---------------------------------------------------------------------------------

def mov.ck.in(cs: List<&2, Rm.RmtCk>, +file: List<&2, U32>) -> Bool:
  match cs:
    case Nil{}:
      False{}
    case +k <> t:
      Bool.or(S.eq(Rm.rmt.ck.file(k), file), mov.ck.in(t, file))

# does the log the box answered with record this save (`grep -q 'saved out/F' LOG`)
def mov.saved.has(m: Maybe<&2, List<&2, Rm.RmtCk>>, +file: String) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{cs}:
      mov.ck.in(cs, S.b(file))

# the push log shows shard K sent (`grep -q "^push-corpus: shard K "`)
def mov.pushed(+log: List<&2, U32>, +k: String) -> Bool:
  Gd.grd.has.lines(S.split.lines(log), S.b("push-corpus: shard " ++ k ++ " "))

# NAME's STAGES line naming traind-next (resume's trainer); the rest of the line kept
def mov.fix.rest(+l: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  +rest = List.drop(&2, U32, l, S.len(p))
  +bin = Ac.acb.before(rest, 32)
  List.concat(&2, U32, [p, S.b("traind-next"), List.drop(&2, U32, rest, S.len(bin))])

def mov.fix.line(+l: List<&2, U32>, +name: String) -> List<&2, U32>:
  +p = S.b(name ++ " ")
  Bool.pick(List<&2, U32>, S.prefix(l, p), mov.fix.rest(l, p), l)

def mov.fix.lines(ls: List<&2, List<&2, U32>>, +name: String) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      mov.fix.line(l, name) <> mov.fix.lines(t, name)

# STAGES with NAME's line naming traind-next (the text as it was when nothing changes)
def mov.stages.fix(+xs: List<&2, U32>, +name: String) -> List<&2, U32>:
  +ys = S.join(mov.fix.lines(S.split.lines(xs), name), 10)
  Bool.pick(List<&2, U32>, S.suffix(xs, [10]), List.append(&2, U32, ys, [10]), ys)

# `tail -2 | cut -c1-120`: each line's first 120 bytes
def mov.cut120(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      List.concat(&2, U32, [List.take(&2, U32, l, 120n), [10], mov.cut120(t)])

# the name of the old log cut at the save: train.log, 4000 -> train-to-4000.log
def mov.to.name(+log0: String, +step: String) -> String:
  +b = S.b(S.base(log0))
  S.str(Bool.pick(List<&2, U32>, S.suffix(b, S.b(".log")), List.take(&2, U32, b, Nat.sub(S.len(b), 4n)), b)) ++ "-to-" ++ step ++ ".log"

# The old log up to the save -------------------------------------------------------------------------

# a copy of each line, up to and with the first that holds key (`sed '/key/q'`)
type MovCut is Type:
  MovCut{r: S.Rd, o: File, more: Bool, found: Bool}

def mov.cut.got(+key: List<&2, U32>, o: File, +found: Bool, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(MovCut):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(MovCut, MovCut{r, o, False{}, found})
    case Some{+l}:
      +hit = S.infix(l, key)
      do IO<MovCut>:
        o2 : File <- S.emit(o, List.append(&2, U32, l, [10]))
        return MovCut{r, o2, Bool.not(hit), hit}

def mov.cut.step(+key: List<&2, U32>, s: MovCut) -> IO(MovCut):
  match s:
    case MovCut{r, o, m, +f}:
      do IO<MovCut>:
        x : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(r)
        mov.cut.got(key, o, f, x)

def mov.cut.go(fuel: Nat, +key: List<&2, U32>, s: MovCut) -> IO(MovCut):
  match fuel s:
    case 1n+k MovCut{r, o, True{}, f}:
      IO.bind(MovCut, MovCut, mov.cut.step(key, MovCut{r, o, True{}, f}), mov.cut.go(k, key))
    case _ MovCut{r, o, m, f}:
      IO.pure(MovCut, MovCut{r, o, m, f})

def mov.cut.fin(s: MovCut) -> IO(Bool):
  match s:
    case MovCut{r, o, m, +f}:
      do IO<Bool>:
        S.Rd.close(r)
        File.close(o)
        return f

# SRC's lines up to and with the first holding key, into DST; whether one did
def mov.upto(+src: String, +key: String, +dst: String) -> IO(Bool):
  do IO<Bool>:
    r : S.Rd <- S.Rd.lines(src)
    o : File <- IO.try(File, File.open(dst, "w"))
    s : MovCut <- mov.cut.go(U32.to_nat(4000000000), S.b(key), MovCut{r, o, True{}, False{}})
    mov.cut.fin(s)

# old-stop ---------------------------------------------------------------------------------------------

def mov.unit.names(+kvs: List<&2, Ev.EvKv>) -> List<&2, String>:
  List.concat(&2, String, [Gd.grd.spec.names(Rc.rcf.unit(kvs, "chain")), Gd.grd.spec.names(Rc.rcf.unit(kvs, "watch")), Rc.rcf.every(kvs, "stop-units")])

def mov.trainers(+c: MovCx) -> String:
  String.join(Rc.rcf.words.or(mov.kvs(c), "move-trainers", ["traind", "traind-next"]), "|")

def mov.units.stop(ns: List<&2, String>, +c: MovCx) -> IO(Unit):
  match ns:
    case Nil{}:
      mov.log(c, "old box: no local unit to stop")
    case +n <> +t:
      do IO<Unit>:
        +o : Lc.LclOut <- Un.unt.stop(n <> t)
        Hv.hov.pass(o)
        mov.log(c, "old box: stopped the local units " ++ String.join(n <> t, " "))

def mov.left(+o: Lc.LclOut) -> IO(Unit):
  Bool.pick(IO(Unit), Lc.lcl.ok(o), Hv.hov.show(Lc.lcl.out(o)), IO.print_err("trainer stopped"))

def mov.stop.run(+c: MovCx) -> IO(Unit):
  +b = mov.old(c)
  +td = mov.td(c)
  do IO<Unit>:
    mov.units.stop(mov.unit.names(mov.kvs(c)), c)
    +s : Lc.LclOut <- Rm.rmt.ssh(b, 3600, "env -C " ++ Rm.rmt.q(td) ++ " ACT_PROC=" ++ Rm.rmt.q(mov.k(c, "act-proc", "bend-corpus-v2")) ++ " ACT_STOP_WAIT="
      ++ Rm.rmt.q(mov.k(c, "act-stop-wait", "15")) ++ " " ++ Rm.rmt.q(mov.k(c, "box-driver", "./bend-box")) ++ " act-stop")
    Hv.hov.pass(s)
    +k : Lc.LclOut <- Rm.rmt.ssh(b, 120, "pkill -x " ++ Rm.rmt.q(mov.trainers(c)))
    IO.sleep(5000)
    +p : Lc.LclOut <- Rm.rmt.ssh(b, 120, "pgrep -x " ++ Rm.rmt.q(mov.trainers(c)))
    mov.left(p)
    +t : Lc.LclOut <- Rm.rmt.ssh(b, 120, "tail -n 2 -- " ++ Rm.rmt.q(Rc.rcf.at(td, mov.log0(c))))
    Hv.hov.show(mov.cut120(S.split.lines(Lc.lcl.out(t))))

def mov.old.stop(+c: MovCx) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&2, List<&2, Rm.RmtCk>> <- Rm.rmt.saved(mov.old(c), Rc.rcf.at(mov.td(c), mov.log0(c)))
    mov.need(mov.saved.has(m, mov.ck(c)), c, "old box: " ++ mov.name(c) ++ "-step" ++ mov.step(c) ++ " not saved yet")
    mov.stop.run(c)

# old-pull ---------------------------------------------------------------------------------------------

def mov.same(+here: Maybe<&2, List<&2, U32>>, +box: Rm.RmtSums, +name: String) -> Bool:
  Ac.acb.same(here, Lc.lcl.sha.of(Ac.acb.sums.of(box), S.b(name)))

def mov.hex16(m: Maybe<&2, List<&2, U32>>) -> String:
  S.str(List.take(&2, U32, Maybe.default(&2, List<&2, U32>, m, Nil{}), 16n))

def mov.rsync(+b: Rm.RmtBox, extra: List<&2, String>, srcs: List<&2, String>, +dst: String) -> IO(Bool):
  Rm.rmt.rsync(b, Rc.rcf.l1(List.concat(&2, String, [["-a"], extra, ["--partial-dir=.partial", "-e", Rm.rmt.rsh(b)], srcs, [dst]])))

def mov.first.word(+o: Lc.LclOut) -> String:
  S.str(Lc.lcl.nth(Lc.lcl.words(Lc.lcl.out(o)), 0n))

def mov.pairs(+o: Lc.LclOut) -> String:
  Nat.show(Nat.div(Maybe.default(&2, Nat, Lc.lcl.nat(Lc.lcl.nth(Lc.lcl.words(Lc.lcl.out(o)), 0n)), 0n), 2n))

def mov.rescued(+c: MovCx, +a: String) -> IO(Unit):
  do IO<Unit>:
    Ab.abx.cut.frames(a ++ "/episodes.eplog")
    Ab.abx.cut.pairs(a ++ "/agent.nul")
    Ab.abx.cut.pairs(a ++ "/episodes.nul")
    +du : Lc.LclOut <- Lc.lcl.run(600, "du", ["-sh", a])
    +n : Lc.LclOut <- Lc.lcl.run(600, "grep", ["-c", "-z", "", "--", a ++ "/agent.nul"])
    +r : Lc.LclOut <- Lc.lcl.run(600, "grep", ["-c", ".", "--", a ++ "/render.txt"])
    mov.log(c, "act round " ++ S.base(a) ++ " pulled into " ++ a ++ " (" ++ mov.first.word(du) ++ "): " ++ mov.pairs(n) ++ " records in agent.nul, "
      ++ Hv.hov.count.text(r) ++ " lines in render.txt")

def mov.old.pull(+c: MovCx) -> IO(Unit):
  +b = mov.old(c)
  +d = mov.dest(c)
  +td = mov.td(c)
  +ck = mov.ck(c)
  +act = mov.k(c, "act-dir", "")
  +ws = Hv.hov.ws(mov.h(c))
  do IO<Unit>:
    S.mkdir(d ++ "/oldbox")
    S.mkdir(d ++ "/out")
    S.mkdir(d ++ "/rescue/act")
    ok : Bool <- Rm.rmt.pull(b, td ++ "/out/" ++ ck, d ++ "/out", Nil{})
    mov.need(ok, c, "could not pull " ++ ck ++ " from the old box")
    +here : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(d ++ "/out/" ++ ck)
    +box : Rm.RmtSums <- Rm.rmt.sums(b, Rm.rmt.q(td ++ "/out/" ++ ck))
    mov.need(mov.same(here, box, ck), c, mov.name(c) ++ "-step" ++ mov.step(c) ++ ": sha256 differs")
    mov.log(c, "pulled " ++ ck ++ ", sha256 " ++ mov.hex16(here) ++ " matches the old box")
    l : Bool <- mov.rsync(b, ["--include=*.log*", "--include=*.txt", "--include=*.out", "--exclude=*"], [Rm.rmt.remote(b, td ++ "/")], d ++ "/oldbox/")
    mov.need(l, c, "could not pull the old box's logs")
    r : Bool <- mov.rsync(b, ["--delete"], [Rm.rmt.remote(b, Rc.rcf.at(ws, act)), Rm.rmt.remote(b, Rc.rcf.at(ws, act ++ ".log"))], d ++ "/rescue/act/")
    mov.need(r, c, "could not pull act round " ++ act ++ " from the old box")
    mov.rescued(c, d ++ "/rescue/act/" ++ S.base(act))

# restage ----------------------------------------------------------------------------------------------

def mov.restage(+c: MovCx) -> IO(Unit):
  +h = mov.h(c)
  do IO<Unit>:
    +st : U32 <- Aa.aac.follow(["BOX_DIR=" ++ mov.td(c)], Hv.hov.self(h), List.append(&2, String, ["stage", "restage", mov.k(c, "host", ""), mov.k(c, "port", ""),
      mov.dest(c) ++ "/out/" ++ mov.ck(c)], Rc.rcf.words(mov.kvs(c), "move-restage")))
    mov.need(U32.is_eq(st, 0), c, "new box: stage restage failed (exit " ++ U32.show(st) ++ ")")
    mov.log(c, "new box: restaged with " ++ mov.ck(c))

# resume -----------------------------------------------------------------------------------------------

def mov.needs(ns: List<&2, String>, +b: Rm.RmtBox, +td: String) -> IO(Bool):
  match ns:
    case Nil{}:
      IO.pure(Bool, True{})
    case +n <> t:
      do IO<Bool>:
        +st : Rm.RmtStat <- Rm.rmt.stat(b, Rc.rcf.at(td, n))
        +rest : Bool <- mov.needs(t, b, td)
        return Bool.and(Hv.hov.nonempty(st), rest)

def mov.pushed.of(ws: List<&2, String>) -> IO(Bool):
  match ws:
    case Nil{}:
      IO.pure(Bool, True{})
    case +f <> t:
      do IO<Bool>:
        +xs : List<&2, U32> <- S.read(f)
        return mov.pushed(xs, Rc.rcf.first(t, ""))

# move-pushed LOG K: the push log shows shard K sent (no key: nothing to wait for)
def mov.pushed.ok(+c: MovCx) -> IO(Bool):
  mov.pushed.of(Rc.rcf.words(mov.kvs(c), "move-pushed"))

def mov.log.free(+st: Rm.RmtStat, +c: MovCx) -> IO(Unit):
  match st:
    case Rm.RmtStatNo{}:
      IO.pure(Unit, Unit{})
    case Rm.RmtStatYes{s}:
      mov.fail(c, "new box: " ++ mov.log0(c) ++ " is there already; not resumed")
    case Rm.RmtStatUnknown{}:
      mov.fail(c, "new box: did not answer; not resumed")

def mov.stages.write(changed: Bool, +c: MovCx, +old: List<&2, U32>, +new: List<&2, U32>) -> IO(Unit):
  match changed:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      +f = mov.k(c, "stages", "")
      do IO<Unit>:
        S.write(f ++ "." ++ mov.k(c, "old-instance", "before-move"), old)
        S.write(f, new)
        mov.log(c, f ++ ": " ++ mov.name(c) ++ " runs traind-next now (the old file kept as " ++ f ++ "." ++ mov.k(c, "old-instance", "before-move") ++ ")")

def mov.resume.run(+c: MovCx) -> IO(Unit):
  +b = Hv.hov.box(mov.h(c))
  +td = mov.td(c)
  +d = mov.dest(c)
  +ck = mov.ck(c)
  +name = mov.name(c)
  +cut = d ++ "/oldbox/" ++ mov.to.name(mov.log0(c), mov.step(c))
  +steps = Nat.sub(Rc.rcf.nat(mov.kvs(c), "move-to", Rc.rcf.nat(mov.kvs(c), "boundary", 0n)), Rc.rcf.nat(mov.kvs(c), "move-step", 0n))
  do IO<Unit>:
    g : Lc.LclOut <- Rm.rmt.ssh(b, 120, "grep -q -F -e 'G2: PASS' -- " ++ Rm.rmt.q(Rc.rcf.at(td, mov.k(c, "move-gate", "gate.log"))))
    mov.need(Lc.lcl.ok(g), c, "new box: no G2 PASS")
    ok : Bool <- Rm.rmt.push(b, d ++ "/out/" ++ ck, td ++ "/out/", Nil{})
    mov.need(ok, c, "new box: " ++ ck ++ " did not land")
    +here : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(d ++ "/out/" ++ ck)
    +box : Rm.RmtSums <- Rm.rmt.sums(b, Rm.rmt.q(td ++ "/out/" ++ ck))
    mov.need(mov.same(here, box, ck), c, "new box: " ++ name ++ "-step" ++ mov.step(c) ++ " sha256 differs")
    there : Bool <- S.exists(d ++ "/oldbox/" ++ mov.log0(c))
    mov.need(there, c, "no " ++ d ++ "/oldbox/" ++ mov.log0(c) ++ " (old-pull first)")
    found : Bool <- mov.upto(d ++ "/oldbox/" ++ mov.log0(c), "saved out/" ++ ck, cut)
    mov.need(found, c, "the old box's " ++ mov.log0(c) ++ " has no `saved out/" ++ ck ++ "`")
    p : Bool <- Rm.rmt.push(b, cut, td ++ "/" ++ name ++ ".log", Nil{})
    mov.need(p, c, "new box: the old log did not land")
    +st : Rm.RmtStat <- Rm.rmt.stat(b, Rc.rcf.at(td, mov.log0(c)))
    mov.log.free(st, c)
    l : Lc.LclOut <- Rm.rmt.ssh(b, 120, "ln -- " ++ Rm.rmt.q(td ++ "/" ++ name ++ ".log") ++ " " ++ Rm.rmt.q(Rc.rcf.at(td, mov.log0(c))))
    mov.need(Lc.lcl.ok(l), c, "new box: ln " ++ name ++ ".log " ++ mov.log0(c) ++ " failed")
    +r : Lc.LclOut <- Rm.rmt.ssh(b, 600, "env -C " ++ Rm.rmt.q(td) ++ " SAVE=" ++ Rm.rmt.q(mov.k(c, "move-save", "1000")) ++ " " ++ Rm.rmt.q(mov.k(c, "box-driver", "./bend-box"))
      ++ " resume " ++ Rm.rmt.q("out/" ++ ck) ++ " " ++ Rm.rmt.q(mov.k(c, "move-plan", "")) ++ " " ++ Rm.rmt.q(mov.k(c, "move-run", "")) ++ " "
      ++ Rm.rmt.q(mov.k(c, "move-shard", "fp100m")) ++ " " ++ Rm.rmt.q(name) ++ " " ++ Nat.show(steps))
    Hv.hov.pass(r)
    mov.need(Lc.lcl.ok(r), c, "new box: bend-box resume failed (exit " ++ U32.show(Lc.lcl.status(r)) ++ ")")
    +sx : List<&2, U32> <- S.read(mov.k(c, "stages", ""))
    +fixed : List<&2, U32> = mov.stages.fix(sx, name)
    mov.stages.write(Bool.not(S.eq(sx, fixed)), c, sx, fixed)
    mov.log(c, "new box: " ++ name ++ " resumed from " ++ name ++ "-step" ++ mov.step(c) ++ " to " ++ Nat.show(Nat.add(Rc.rcf.nat(mov.kvs(c), "move-step", 0n), steps))
      ++ " (bend-box resume, " ++ name ++ ".log = " ++ mov.log0(c) ++ ")")

def mov.resume(+c: MovCx) -> IO(Unit):
  do IO<Unit>:
    a : Bool <- mov.needs(Rc.rcf.every(mov.kvs(c), "move-need"), Hv.hov.box(mov.h(c)), mov.td(c))
    p : Bool <- mov.pushed.ok(c)
    mov.need(Bool.and(a, p), c, "new box: " ++ String.join(Rc.rcf.every(mov.kvs(c), "move-need"), " ") ++ " or the shards before them not there yet")
    mov.resume.run(c)

# watch ------------------------------------------------------------------------------------------------

def mov.started(r: Un.UntRes, +c: MovCx, +name: String) -> IO(Unit):
  match r:
    case Un.UntStarted{}:
      IO.pure(Unit, Unit{})
    case Un.UntActive{+st}:
      mov.fail(c, name ++ " is " ++ st ++ " (on the old box?); not started: `move CFG old-stop` first")
    case Un.UntFailed{+w}:
      mov.fail(c, name ++ " did not start: " ++ w)

def mov.start(ss: List<&2, Un.UntSpec>, +c: MovCx, +cwd: String) -> IO(Unit):
  match ss:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +s <> t:
      do IO<Unit>:
        r : Un.UntRes <- Un.unt.ensure(s, cwd)
        mov.started(r, c, Un.unt.s.name(s))
        mov.start(t, c, cwd)

def mov.hand(ss: List<&2, Un.UntSpec>, +c: MovCx, +cwd: String) -> IO(Unit):
  match ss:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +s <> t:
      do IO<Unit>:
        o : Lc.LclOut <- Un.unt.stop([Un.unt.s.name(s)])
        mov.start([s], c, cwd)
        mov.log(c, "hand-over unit " ++ Un.unt.s.name(s) ++ " started again for the new box")

def mov.watch(+c: MovCx, +cfg: String) -> IO(Unit):
  +kvs = mov.kvs(c)
  do IO<Unit>:
    +cwd : String <- S.realpath(".")
    +ops : String <- Rc.rcf.ops(kvs, cwd)
    +st : List<&2, U32> <- S.read(mov.k(c, "stages", ""))
    mov.start(List.append(&2, Un.UntSpec, Gd.grd.chain(kvs, ops), Gd.grd.watch(kvs, ops)), c, cwd)
    mov.log(c, "chain and credit watch on vast " ++ mov.k(c, "instance", ""))
    mov.hand(Bool.pick(List<&2, Un.UntSpec>, Gd.grd.has.stage(st, Gd.grd.stage(kvs)), Nil{}, Gd.grd.handover(kvs, ops, Rc.rcf.at(cwd, cfg))), c, cwd)

# act --------------------------------------------------------------------------------------------------

def mov.act(+c: MovCx) -> IO(Unit):
  +h = mov.h(c)
  +act = mov.k(c, "act-dir", "")
  do IO<Unit>:
    +st : U32 <- Aa.aac.follow(Hv.hov.act.env(h), Hv.hov.self(h), ["act", "ensure", mov.k(c, "host", ""), mov.k(c, "port", ""), mov.k(c, "act-ckpt", ""), act,
      mov.dest(c) ++ "/rescue/act/" ++ S.base(act)])
    mov.need(U32.is_eq(st, 0), c, "act ensure failed (exit " ++ U32.show(st) ++ "); act round not restarted")
    mov.log(c, "new box: act round " ++ act ++ " resumed")

# old-check --------------------------------------------------------------------------------------------

def mov.here.lines(ss: List<&2, Lc.LclSum>, +here: List<&2, Lc.LclSum>) -> List<&2, U32>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      List.concat(&2, U32, [S.b(Bool.pick(String, Lc.lcl.sha.has(here, s), "here: ", "NOT HERE: ")), Lc.lcl.sum.name(s), [10], mov.here.lines(t, here)])

def mov.names(ss: List<&2, Lc.LclSum>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      Lc.lcl.sum.name(s) <> mov.names(t)

def mov.spaced(xs: List<&2, List<&2, U32>>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      " " ++ S.str(x) ++ mov.spaced(t)

def mov.check.fin(+c: MovCx, +box: List<&2, Lc.LclSum>, +here: List<&2, Lc.LclSum>) -> IO(Unit):
  +bad = Lc.lcl.sha.unmatched(box, here)
  Bool.pick(IO(Unit), Nat.is_eq(List.length(&2, Lc.LclSum, box), 0n), mov.fail(c, "old box: no checkpoint there"),
    Bool.pick(IO(Unit), List.is_empty(&2, List<&2, U32>, bad), mov.log(c, "old box: every checkpoint is here with its sha256"),
      mov.fail(c, "old box: not here with its sha256:" ++ mov.spaced(bad))))

def mov.answered(+r: Rm.RmtSums) -> Bool:
  match r:
    case Rm.RmtSums{a, s}:
      a

def mov.old.check(+c: MovCx) -> IO(Unit):
  +d = mov.dest(c) ++ "/out"
  do IO<Unit>:
    +r : Rm.RmtSums <- Rm.rmt.sums(mov.old(c), Rm.rmt.q(mov.td(c)) ++ "/out/*.checkpoint")
    mov.need(mov.answered(r), c, "old box: did not answer")
    +box : List<&2, Lc.LclSum> = Ac.acb.sums.of(r)
    IO.print_err(S.str(S.chomp(Lc.lcl.sha.text(box))))
    +here : List<&2, Lc.LclSum> <- Lc.lcl.sums(d, mov.names(box))
    Hv.hov.show(mov.here.lines(box, here))
    mov.check.fin(c, box, here)

# Main -------------------------------------------------------------------------------------------------

def mov.usage() -> String:
  "usage: bend-ops move CFG old-stop|old-pull|restage|resume|watch|act|old-check   (tools/runs/TEMPLATE.cfg)"

def mov.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +cfg <> "old-stop" <> Nil{}:
      do IO<Unit>:
        +c : MovCx <- mov.cx(cfg, ["old-host", "old-port", "move-name", "move-step"])
        mov.old.stop(c)
    case +cfg <> "old-pull" <> Nil{}:
      do IO<Unit>:
        +c : MovCx <- mov.cx(cfg, ["old-host", "old-port", "move-name", "move-step", "act-dir"])
        mov.old.pull(c)
    case +cfg <> "restage" <> Nil{}:
      do IO<Unit>:
        +c : MovCx <- mov.cx(cfg, ["host", "port", "move-name", "move-step"])
        mov.restage(c)
    case +cfg <> "resume" <> Nil{}:
      do IO<Unit>:
        +c : MovCx <- mov.cx(cfg, ["host", "port", "stages", "move-name", "move-step", "move-plan", "move-run"])
        mov.resume(c)
    case +cfg <> "watch" <> Nil{}:
      do IO<Unit>:
        +c : MovCx <- mov.cx(cfg, ["host", "port", "instance", "stages"])
        mov.watch(c, cfg)
    case +cfg <> "act" <> Nil{}:
      do IO<Unit>:
        +c : MovCx <- mov.cx(cfg, ["host", "port", "act-dir", "act-ckpt"])
        mov.act(c)
    case +cfg <> "old-check" <> Nil{}:
      do IO<Unit>:
        +c : MovCx <- mov.cx(cfg, ["old-host", "old-port"])
        mov.old.check(c)
    case _:
      IO.die(Unit, 2, mov.usage())
