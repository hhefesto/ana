import Base
import ../Sys.bend as S
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./Vast.bend as Vs
import ./Alert.bend as Al

# Watch: the last line of defence under an unattended chain, for the credit
# and for the box (2026-10-14, the plan's Phase 1a: the port of
# bend/gpu/credit-watch.sh to Bend; its `credit-watch: ` lines are the
# script's, byte for byte).
#
#   bend-ops watch HOST PORT DEST [MIN]
#
# Every WATCH_POLL seconds (600), until DEST/DESTROYED:
# - Under MIN ($1.00; `vastai show user --raw`'s credit, read here, not by
#   bend-corpus-v2: CV2 is no longer used) it stops the trainers on the box
#   (pkill -x traind-next, then traind), once, so the chain sees the stage die
#   and goes on to its scores, pulls and destroy while there is credit to pay
#   for them; DEST/CREDIT_LOW says it happened (remove it after a top-up).
# - Once the chain has refused the destroy (DEST/REFUSED) GRACE seconds (3600)
#   ago, or the trainer was stopped for the credit LOW_WAIT seconds (5400) ago,
#   it checks the box itself, both sides read afresh: no trainer running, and
#   every checkpoint on the box here with the box's sha256.  Then it pulls the
#   box's logs and destroys the box (DEST/INSTANCE, written by the chain),
#   unless DEST/CONTINUED exists or DEST/HOLD's deadline is ahead; DESTROYED
#   only when a listing that reads no longer shows the instance (LIST_TRIES,
#   LIST_WAIT).  Otherwise it alerts, once an hour.
# - When the chain has written nothing to chain.log for SILENT seconds (10800)
#   and the box is not destroyed, it alerts (once an hour).
# An alert is a chain.log line, a desktop notification, and ALERT_CMD.
#
# Every name starts with `cwt.`; the decisions (cwt.due, cwt.silent,
# cwt.safe.of) are pure and tested in bend/tests/chain.bend.

type CwtCfg is Data:
  CwtCfg{box: Rm.RmtBox, dest: String, min: String, dir: String, v: String, ts: List<&2, Nat>}

def cwt.box(+c: CwtCfg) -> Rm.RmtBox:
  match c:
    case CwtCfg{b, d, m, r, v, ts}:
      b

def cwt.dest(+c: CwtCfg) -> String:
  match c:
    case CwtCfg{b, d, m, r, v, ts}:
      d

def cwt.min(+c: CwtCfg) -> String:
  match c:
    case CwtCfg{b, d, m, r, v, ts}:
      m

def cwt.dir(+c: CwtCfg) -> String:
  match c:
    case CwtCfg{b, d, m, r, v, ts}:
      r

def cwt.v(+c: CwtCfg) -> String:
  match c:
    case CwtCfg{b, d, m, r, v, ts}:
      v

def cwt.tn(+c: CwtCfg, +k: Nat) -> Nat:
  match c:
    case CwtCfg{b, d, m, r, v, ts}:
      Maybe.default(&2, Nat, List.get(&2, Nat, ts, k), 0n)

def cwt.t.names() -> List<&2, String>:
  ["GRACE", "LOW_WAIT", "SILENT", "WATCH_POLL", "DESTROY_WAIT", "LIST_TRIES", "LIST_WAIT"]

def cwt.t.defaults() -> List<&2, Nat>:
  [U32.to_nat(3600), U32.to_nat(5400), U32.to_nat(10800), U32.to_nat(600), 10n, 6n, 30n]

def cwt.grace(+c: CwtCfg) -> Nat:
  cwt.tn(c, 0n)

def cwt.lowwait(+c: CwtCfg) -> Nat:
  cwt.tn(c, 1n)

def cwt.silent.s(+c: CwtCfg) -> Nat:
  cwt.tn(c, 2n)

def cwt.poll(+c: CwtCfg) -> Nat:
  cwt.tn(c, 3n)

def cwt.dwait(+c: CwtCfg) -> Nat:
  cwt.tn(c, 4n)

def cwt.ltries(+c: CwtCfg) -> Nat:
  cwt.tn(c, 5n)

def cwt.lwait(+c: CwtCfg) -> Nat:
  cwt.tn(c, 6n)

def cwt.envs(names: List<&2, String>, ds: List<&2, Nat>) -> IO(List<&2, Nat>):
  match names ds:
    case n <> nt +d <> dt:
      do IO<List<&2, Nat>>:
        +x : Nat <- S.env.nat(n, d)
        rest : List<&2, Nat> <- cwt.envs(nt, dt)
        return x <> rest
    case _ _:
      IO.pure(List<&2, Nat>, Nil{})

def cwt.f(+c: CwtCfg, +name: String) -> String:
  cwt.dest(c) ++ "/" ++ name

def cwt.sleep(+secs: Nat) -> IO(Unit):
  IO.sleep(U32.mul(Rm.rmt.secs(secs), 1000))

# Pure decisions -------------------------------------------------------------------------------

def cwt.spaced(xs: List<&2, List<&2, U32>>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      " " ++ S.str(x) ++ cwt.spaced(t)

def cwt.low.due(low: Maybe<&2, Nat>, +lowwait: Nat) -> Maybe<&2, String>:
  match low:
    case Some{+a}:
      Bool.pick(Maybe<&2, String>, Nat.is_le(lowwait, a), Some{"the box is up " ++ Nat.show(Nat.div(lowwait, 60n)) ++ " min after the trainer was stopped for the credit"}, None{})
    case None{}:
      None{}

# what makes the destroy due, if anything: REFUSED GRACE old (its text in the
# message), else CREDIT_LOW LOW_WAIT old (ages in seconds, None: no file)
def cwt.due(refused: Maybe<&2, Nat>, +text: List<&2, U32>, low: Maybe<&2, Nat>, +grace: Nat, +lowwait: Nat) -> Maybe<&2, String>:
  match refused:
    case Some{+a}:
      Bool.pick(Maybe<&2, String>, Nat.is_le(grace, a), Some{"the chain refused the destroy (" ++ S.str(S.chomp(text)) ++ " )"}, cwt.low.due(low, lowwait))
    case None{}:
      cwt.low.due(low, lowwait)

# the silence alert: nothing due, chain.log SILENT old, the last alert an hour ago
def cwt.silent(due: Bool, age: Maybe<&2, Nat>, +silent: Nat, +now: Nat, +alerted: Nat) -> Bool:
  match age:
    case Some{+a}:
      Bool.and(Bool.and(Bool.not(due), Nat.is_le(silent, a)), Nat.is_le(3600n, Nat.sub(now, alerted)))
    case None{}:
      False{}

type CwtD is Data:
  CwtD{ok: Bool, why: String}

def cwt.d.ok(+d: CwtD) -> Bool:
  match d:
    case CwtD{o, w}:
      o

def cwt.d.why(+d: CwtD) -> String:
  match d:
    case CwtD{o, w}:
      w

def cwt.zero(m: Maybe<&2, Nat>) -> Bool:
  match m:
    case Some{+n}:
      Nat.is_eq(n, 0n)
    case None{}:
      False{}

# box_safe: no trainer on the box (both counts read and 0), the box gave
# sha256s, and each of its checkpoints is here with the same sha256
def cwt.safe.of(n1: Maybe<&2, Nat>, n2: Maybe<&2, Nat>, +box: List<&2, Lc.LclSum>, +here: List<&2, Lc.LclSum>) -> CwtD:
  +bad = Lc.lcl.sha.unmatched(box, here)
  +nb = List.length(&2, Lc.LclSum, box)
  Bool.pick(CwtD, Bool.not(Bool.and(cwt.zero(n1), cwt.zero(n2))), CwtD{False{}, "a trainer runs on the box, or it did not answer"},
    Bool.pick(CwtD, Nat.is_eq(nb, 0n), CwtD{False{}, "the box gave no sha256"},
      Bool.pick(CwtD, Bool.not(List.is_empty(&2, List<&2, U32>, bad)), CwtD{False{}, "not here with the box's sha256:" ++ cwt.spaced(bad)},
        CwtD{True{}, "every checkpoint on the box (" ++ Nat.show(nb) ++ ") is here with its sha256"})))

# Logs and alerts ---------------------------------------------------------------------------------

def cwt.log(+c: CwtCfg, +msg: String) -> IO(Unit):
  Al.alr.log(cwt.f(c, "chain.log"), "credit-watch: " ++ msg)

def cwt.inst(+c: CwtCfg) -> IO(String):
  do IO<String>:
    xs : List<&2, U32> <- S.read(cwt.f(c, "INSTANCE"))
    return S.str(Lc.lcl.nth(Lc.lcl.words(xs), 0n))

def cwt.alert(+c: CwtCfg, +msg: String) -> IO(Unit):
  do IO<Unit>:
    cwt.log(c, "ALERT: " ++ msg)
    inst : String <- cwt.inst(c)
    n : Lc.LclOut <- Lc.lcl.run(30, "notify-send", ["-u", "critical", "ana box " ++ inst, msg])
    +cmd : String <- S.env("ALERT_CMD", "")
    Al.alr.cmd(Bool.not(String.is_empty(cmd)), cmd, msg)

def cwt.say.err(none: Bool, +t: List<&2, U32>) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print_err(S.str(t))

def cwt.raw(+c: CwtCfg, +t: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    S.add(cwt.f(c, "chain.log"), t)
    cwt.say.err(Nat.is_eq(S.len(t), 0n), S.chomp(t))

# The credit ---------------------------------------------------------------------------------------

def cwt.credit.got(cr: Vs.VstCr, +c: CwtCfg) -> IO(Unit):
  match cr:
    case Vs.VstCrOf{+t, True{}}:
      do IO<Unit>:
        cwt.log(c, "credit $" ++ S.str(t) ++ " is under $" ++ cwt.min(c) ++ ": stopping the trainer so the chain scores, pulls and destroys")
        a : Lc.LclOut <- Rm.rmt.ssh(cwt.box(c), 120, "pkill -x traind-next")
        b : Lc.LclOut <- Rm.rmt.ssh(cwt.box(c), 120, "pkill -x traind")
        Lc.lcl.mark(cwt.f(c, "CREDIT_LOW"), "credit $" ++ S.str(t) ++ " under $" ++ cwt.min(c) ++ ": the trainers were stopped")
    case _:
      IO.pure(Unit, Unit{})

def cwt.credit(low: Bool, +c: CwtCfg) -> IO(Unit):
  match low:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        cr : Vs.VstCr <- Vs.vst.credit(cwt.v(c), cwt.min(c))
        cwt.credit.got(cr, c)

# The destroy --------------------------------------------------------------------------------------

type CwtL is Data:
  CwtL{l: Vs.VstLs}

def cwt.listed.step(+c: CwtCfg, +inst: String, +w: String) -> IO(CwtL):
  do IO<CwtL>:
    cwt.log(c, "the listing did not read (" ++ w ++ "); asking again in " ++ Nat.show(cwt.lwait(c)) ++ " s")
    cwt.sleep(cwt.lwait(c))
    l : Vs.VstLs <- Vs.vst.listed(cwt.v(c), inst)
    return CwtL{l}

def cwt.listed.go(fuel: Nat, +c: CwtCfg, +inst: String, s: CwtL) -> IO(Vs.VstLs):
  match fuel s:
    case _ CwtL{Vs.VstLsYes{}}:
      IO.pure(Vs.VstLs, Vs.VstLsYes{})
    case _ CwtL{Vs.VstLsNo{}}:
      IO.pure(Vs.VstLs, Vs.VstLsNo{})
    case 0n CwtL{Vs.VstLsUnknown{w}}:
      IO.pure(Vs.VstLs, Vs.VstLsUnknown{w})
    case 1n+f CwtL{Vs.VstLsUnknown{+w}}:
      IO.bind(CwtL, Vs.VstLs, cwt.listed.step(c, inst, w), cwt.listed.go(f, c, inst))

def cwt.gone(l: Vs.VstLs, +c: CwtCfg, +inst: String) -> IO(CwtD):
  match l:
    case Vs.VstLsNo{}:
      do IO<CwtD>:
        Lc.lcl.mark(cwt.f(c, "DESTROYED"), "instance " ++ inst ++ " destroyed (credit-watch)")
        cwt.log(c, "finished")
        return CwtD{True{}, "destroyed"}
    case Vs.VstLsYes{}:
      IO.pure(CwtD, CwtD{False{}, "instance " ++ inst ++ " still listed after destroy"})
    case Vs.VstLsUnknown{+w}:
      IO.pure(CwtD, CwtD{False{}, "no listing that reads after the destroy (" ++ w ++ ")"})

def cwt.box1(+b: Rm.RmtBox) -> Rm.RmtBox:
  match b:
    case Rm.RmtBox{h, p, o, t, w, rt, rw}:
      Rm.RmtBox{h, p, o, t, w, 1n, rw}

def cwt.kill(+c: CwtCfg, +inst: String, +why: String) -> IO(CwtD):
  do IO<CwtD>:
    ok : Bool <- Rm.rmt.pull(cwt.box1(cwt.box(c)), cwt.dir(c) ++ "/", cwt.dest(c), ["--include=*.log*", "--include=*.txt", "--exclude=*"])
    cwt.log(c, why ++ ": destroy instance " ++ inst)
    +o : Lc.LclOut <- Vs.vst.destroy(cwt.v(c), inst)
    cwt.raw(c, List.append(&2, U32, Lc.lcl.out(o), Lc.lcl.err(o)))
    cwt.sleep(cwt.dwait(c))
    l0 : Vs.VstLs <- Vs.vst.listed(cwt.v(c), inst)
    l : Vs.VstLs <- cwt.listed.go(Nat.sub(cwt.ltries(c), 1n), c, inst, CwtL{l0})
    cwt.gone(l, c, inst)

def cwt.safe.then(+d: CwtD, +c: CwtCfg, +inst: String) -> IO(CwtD):
  match d:
    case CwtD{True{}, +w}:
      cwt.kill(c, inst, w)
    case CwtD{False{}, +w}:
      IO.pure(CwtD, CwtD{False{}, w})

def cwt.names(ss: List<&2, Lc.LclSum>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      Lc.lcl.sum.name(s) <> cwt.names(t)

def cwt.sums(+rs: Rm.RmtSums) -> List<&2, Lc.LclSum>:
  match rs:
    case Rm.RmtSums{a, ss}:
      ss

# the box can go: both sides read afresh
def cwt.safe(+c: CwtCfg, +inst: String) -> IO(CwtD):
  do IO<CwtD>:
    n1 : Maybe<&2, Nat> <- Rm.rmt.count(cwt.box(c), "traind")
    n2 : Maybe<&2, Nat> <- Rm.rmt.count(cwt.box(c), "traind-next")
    rs : Rm.RmtSums <- Rm.rmt.sums(cwt.box(c), cwt.dir(c) ++ "/out/*.checkpoint")
    +box : List<&2, Lc.LclSum> = cwt.sums(rs)
    here : List<&2, Lc.LclSum> <- Lc.lcl.sums(cwt.f(c, "out"), cwt.names(box))
    cwt.safe.then(cwt.safe.of(n1, n2, box, here), c, inst)

def cwt.hold.ahead(+now: Nat, m: Maybe<&2, Nat>) -> Bool:
  match m:
    case Some{+t}:
      Nat.is_lt(now, t)
    case None{}:
      False{}

def cwt.destroy.at(noinst: Bool, cont: Bool, held: Bool, +c: CwtCfg, +inst: String) -> IO(CwtD):
  match noinst cont held:
    case True{} _ _:
      IO.pure(CwtD, CwtD{False{}, "no DEST/INSTANCE"})
    case False{} True{} _:
      IO.pure(CwtD, CwtD{False{}, "DEST/CONTINUED: someone took the box over"})
    case False{} False{} True{}:
      IO.pure(CwtD, CwtD{False{}, "DEST/HOLD's deadline is ahead"})
    case False{} False{} False{}:
      cwt.safe(c, inst)

def cwt.destroy(+c: CwtCfg) -> IO(CwtD):
  do IO<CwtD>:
    +inst : String <- cwt.inst(c)
    cont : Bool <- S.exists(cwt.f(c, "CONTINUED"))
    xs : List<&2, U32> <- S.read(cwt.f(c, "HOLD"))
    +now : Nat <- Lc.lcl.now()
    cwt.destroy.at(String.is_empty(inst), cont, cwt.hold.ahead(now, Lc.lcl.epoch.of(xs)), c, inst)

# The loop -----------------------------------------------------------------------------------------

type CwtS is Data:
  CwtS{alerted: Nat, more: Bool}

def cwt.silence(yes: Bool, +c: CwtCfg, +now: Nat, +alerted: Nat) -> IO(Nat):
  match yes:
    case False{}:
      IO.pure(Nat, alerted)
    case True{}:
      do IO<Nat>:
        cwt.alert(c, "the chain has written nothing for " ++ Nat.show(Nat.div(cwt.silent.s(c), U32.to_nat(3600))) ++ " h and the box is not destroyed")
        return now

def cwt.failed(alert: Bool, +c: CwtCfg, +due: String, +why: String, +now: Nat, +alerted: Nat) -> IO(Nat):
  match alert:
    case False{}:
      IO.pure(Nat, alerted)
    case True{}:
      do IO<Nat>:
        cwt.alert(c, due ++ "; not destroyed: " ++ why)
        return now

def cwt.tried(+d: CwtD, +c: CwtCfg, +due: String, +now: Nat, +alerted: Nat) -> IO(Nat):
  cwt.failed(Bool.and(Bool.not(cwt.d.ok(d)), Nat.is_le(3600n, Nat.sub(now, alerted))), c, due, cwt.d.why(d), now, alerted)

def cwt.act(due: Maybe<&2, String>, +c: CwtCfg, +now: Nat, +alerted: Nat) -> IO(Nat):
  match due:
    case None{}:
      IO.pure(Nat, alerted)
    case Some{+d}:
      do IO<Nat>:
        +r : CwtD <- cwt.destroy(c)
        cwt.tried(r, c, d, now, alerted)

def cwt.rest(gone: Bool, +c: CwtCfg, +alerted: Nat) -> IO(CwtS):
  match gone:
    case True{}:
      IO.pure(CwtS, CwtS{alerted, False{}})
    case False{}:
      do IO<CwtS>:
        cwt.sleep(cwt.poll(c))
        return CwtS{alerted, True{}}

def cwt.look(+c: CwtCfg, +alerted: Nat) -> IO(CwtS):
  do IO<CwtS>:
    low0 : Bool <- S.exists(cwt.f(c, "CREDIT_LOW"))
    cwt.credit(low0, c)
    +now : Nat <- Lc.lcl.now()
    ra : Maybe<&2, Nat> <- Lc.lcl.age(cwt.f(c, "REFUSED"))
    rt : List<&2, U32> <- S.read(cwt.f(c, "REFUSED"))
    la : Maybe<&2, Nat> <- Lc.lcl.age(cwt.f(c, "CREDIT_LOW"))
    ca : Maybe<&2, Nat> <- Lc.lcl.age(cwt.f(c, "chain.log"))
    +due : Maybe<&2, String> = cwt.due(ra, rt, la, cwt.grace(c), cwt.lowwait(c))
    +a2 : Nat <- cwt.silence(cwt.silent(Maybe.is_some(&2, String, due), ca, cwt.silent.s(c), now, alerted), c, now, alerted)
    +a3 : Nat <- cwt.act(due, c, now, a2)
    gone : Bool <- S.exists(cwt.f(c, "DESTROYED"))
    cwt.rest(gone, c, a3)

def cwt.step(gone: Bool, +c: CwtCfg, +alerted: Nat) -> IO(CwtS):
  match gone:
    case True{}:
      IO.pure(CwtS, CwtS{alerted, False{}})
    case False{}:
      cwt.look(c, alerted)

def cwt.step.io(+c: CwtCfg, +alerted: Nat) -> IO(CwtS):
  do IO<CwtS>:
    gone : Bool <- S.exists(cwt.f(c, "DESTROYED"))
    cwt.step(gone, c, alerted)

def cwt.go(fuel: Nat, +c: CwtCfg, s: CwtS) -> IO(Unit):
  match fuel s:
    case _ CwtS{a, False{}}:
      IO.pure(Unit, Unit{})
    case 0n CwtS{a, True{}}:
      IO.pure(Unit, Unit{})
    case 1n+f CwtS{+a, True{}}:
      IO.bind(CwtS, Unit, cwt.step.io(c, a), cwt.go(f, c))

def cwt.usage() -> String:
  "usage: bend-ops watch HOST PORT DEST [MIN]   (MIN: 1.00)"

def cwt.run(+host: String, +port: String, +dest: String, +min: String) -> IO(Unit):
  do IO<Unit>:
    b : Rm.RmtBox <- Rm.rmt.box(host, port)
    v : String <- Vs.vst.bin()
    dir : String <- S.env("BOX_DIR", "formalTransformer")
    ts : List<&2, Nat> <- cwt.envs(cwt.t.names(), cwt.t.defaults())
    cwt.go(U32.to_nat(4000000000), CwtCfg{b, dest, min, dir, v, ts}, CwtS{0n, True{}})

def cwt.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +host <> +port <> +dest <> Nil{}:
      cwt.run(host, port, dest, "1.00")
    case +host <> +port <> +dest <> +min <> Nil{}:
      cwt.run(host, port, dest, min)
    case _:
      IO.die(Unit, 2, cwt.usage())
