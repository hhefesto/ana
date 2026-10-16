import Base
import ../Sys.bend as S
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./Alert.bend as Al
import ./OnBox.bend as Ob
import ./Act.bend as Ac
import ./Evals.bend as Ev
import ./RunCfg.bend as Rc
import ./Guard.bend as Gd
import ./Chain.bend as Ch
import ../CorpusV2/AgentAct.bend as Aa

# Handover: from the first stage to the second at the boundary, unattended
# (2026-10-15, the plan's Phase 4b: run 3's run/v3/run3/s2-driver.sh made
# generic and driven by the run's config, tools/runs/*.cfg).
#
#   bend-ops handover CFG
#
# The chain (bend-ops chain) waits WAIT (2 h) at the end of STAGES for another
# stage once the boundary stage's trainer prints `done at step BOUNDARY` (it
# was started with STEPS=BOUNDARY, as run 3's S1 was).  This waits for the
# same line, then, in s2-driver.sh's order:
#   1. the act round (act-dir, in the act workspace act-ws on the box): when its
#      log's last line does not say `agent-act: done`, it is stopped with
#      `bend-box act-stop` (its whole session; ACT_PROC act-proc, ACT_STOP_WAIT
#      act-stop-wait);
#   2. its eplog is cut back to whole `EP1 LEN\n` frames (`bend-box cut-frames`,
#      the parser of s2-driver.sh), then agent-act's own tail runs: `bend-episode
#      accept CALLS CAP DIR/accepted DIR/episodes.eplog` and `AGENT_RECORDS=train
#      bend-episode fixed ...` (DIR.accept.log); each accepted directory's records
#      are counted;
#   3. `DEPLOY corpus-v2 s2 TRAINER_DIR/S2_FROM BOUNDARY TRAINER_DIR/S2_OUT DIR`
#      (S1_LOG, TRAINER_DIR, EVERY and s2-env set) builds S2 in the trainer's
#      directory, its output in act-ws/s2-log; its stage line (the last line) must
#      be `s2 traind-next EVERY S2_OUT/plan-fp100m-b16-windows.tsv S2_OUT fp100m`
#      (or the same with absolute paths), the plan must be there and stage.env
#      must have NLR= and NWARM=10;
#   4. here, `STAGE traind-next EVERY S2_OUT/plan-fp100m-b16-windows.tsv S2_OUT
#      fp100m` is appended to STAGES (relative: the chain looks for a plan
#      under its BOX_DIR), unless STAGES already has a line for STAGE.
# Any failure says so in DEST/chain.log and exits 1: the chain then scores,
# pulls and destroys after the first stage, as with no second stage.  DESTROYED
# while waiting: exit 0; DIED (the chain's: the stage died): exit 1.
#
# New, each by a config key: act-ensure yes runs `bend-ops act ensure HOST PORT
# ACT_CKPT DIR` once before the wait, while the boundary is ahead and the round
# has not finished (setup, the checkpoint, the round started unless one runs:
# run 3's act-restart.sh; a failure is logged and the wait goes on); act-pull
# yes runs `bend-ops act pull HOST PORT DIR` after the append, so the round's
# episodes are kept here before the box goes.
#
# New for run 4 (2026-10-15), each off by default (then all is as above):
# plan-base P, for a boundary stage hot-started with `bend-box again` (TRAIN_NEXT:
# its log counts global steps, the checkpoint's step P on): the wait is for `done
# at step P+BOUNDARY`, while s2 gets the plan's own BOUNDARY (its segments and
# its lr schedule count from the plan's step 0; s2-env's LR and WARM are then the
# NLR and NWARM the stage was started with, and s2's NLR check against the log's
# last lr= holds).  A log that says `done at step` at another step stops the
# hand-over (plan-base or TRAIN_STEPS wrong) instead of waiting forever.
# ctl-stage NAME and ctl-out DIR: a control stage beside S2 (run 4's CTL): s2
# also builds DIR (CTL_OUT: the same capped rest, no episodes), and NAME's line
# is appended right after S2's, in the same write: `NAME traind-next CTL_EVERY
# DIR/plan-fp100m-b16-windows.tsv DIR fp100m from=FROM` (ctl-every, default
# s2-every; ctl-from, default out/FIRST-step<P+BOUNDARY>.checkpoint, FIRST the
# first stage of STAGES: the boundary stage's last save), so the chain starts it
# from the boundary's save, not S2's (bend/Box/Chain.bend's from=); its plan,
# stage.env and FROM must be on the box before anything is appended.
#
# Every command sent is a fixed line without control flow (Remote.bend's ssh,
# retried on a dropped link); every answer is parsed here.  Log lines are
# `[stamp UTC-6] handover: ...` in DEST/chain.log and on stderr, with the box's
# outputs (s2-driver.sh's were stdout).  What differs from s2-driver.sh, on
# purpose: every setting is the config's (s2-driver.sh hard-coded run 3's
# paths, step and stage line); bend-corpus-v2 s2 replaces s2.sh (`s2:` and `s2
# failed:` for `s2.sh:` and `s2.sh failed:`); a STAGES that already has the
# stage stops it before anything runs (the script rebuilt S2 on the box, under
# the trainer reading it, before it refused to append); an act-stop that fails
# stops it (the script went on to cut and accept a round that might still be
# writing); the appended line starts on a line of its own; the accepted
# directories' records are counted by `grep -c -z` (NUL-ended records, the
# same as `tr -cd '\0' | wc -c` on whole files).  Every name starts with `hov.`;
# the decisions are tested in bend/tests/drive.bend.

# The setting --------------------------------------------------------------------------------------

type HovCx is Data:
  HovCx{b: Rm.RmtBox, ac: Ac.AcbCx, kvs: List<&2, Ev.EvKv>, cfg: String, self: String}

def hov.box(+c: HovCx) -> Rm.RmtBox:
  match c:
    case HovCx{b, a, k, f, s}:
      b

def hov.ac(+c: HovCx) -> Ac.AcbCx:
  match c:
    case HovCx{b, a, k, f, s}:
      a

def hov.kvs(+c: HovCx) -> List<&2, Ev.EvKv>:
  match c:
    case HovCx{b, a, k, f, s}:
      k

def hov.self(+c: HovCx) -> String:
  match c:
    case HovCx{b, a, k, f, s}:
      s

def hov.k(+c: HovCx, +key: String, +d: String) -> String:
  Rc.rcf.get(hov.kvs(c), key, d)

def hov.dest(+c: HovCx) -> String:
  hov.k(c, "dest", "")

def hov.stages(+c: HovCx) -> String:
  hov.k(c, "stages", "")

def hov.td(+c: HovCx) -> String:
  hov.k(c, "trainer-dir", "")

# the boundary stage's log on the box
def hov.tlog(+c: HovCx) -> String:
  Rc.rcf.at(hov.td(c), hov.k(c, "trainer-log", "train.log"))

# bend-box on the box
def hov.drv(+c: HovCx) -> String:
  Rc.rcf.at(hov.td(c), hov.k(c, "box-driver", "./bend-box"))

def hov.bnd(+c: HovCx) -> String:
  hov.k(c, "boundary", "")

def hov.act(+c: HovCx) -> String:
  hov.k(c, "act-dir", "")

def hov.ws(+c: HovCx) -> String:
  Ac.acb.ws(hov.ac(c))

# a path in the act workspace
def hov.w(+c: HovCx, +p: String) -> String:
  Rc.rcf.at(hov.ws(c), p)

def hov.every(+c: HovCx) -> String:
  hov.k(c, "s2-every", "5000")

def hov.stage(+c: HovCx) -> String:
  hov.k(c, "s2-stage", "s2")

def hov.s2rel(+c: HovCx) -> String:
  hov.k(c, "s2-out", "")

def hov.s1(+c: HovCx) -> String:
  Rc.rcf.at(hov.td(c), hov.k(c, "s2-from", ""))

def hov.s2(+c: HovCx) -> String:
  Rc.rcf.at(hov.td(c), hov.s2rel(c))

def hov.s2log(+c: HovCx) -> String:
  hov.w(c, hov.k(c, "s2-log", "run/v3/s2.log"))

# plan-base (2026-10-15, run 4): the step the boundary stage's plan starts at,
# 0 for a stage started on its plan from scratch; a stage hot-started with
# `bend-box again` (TRAIN_NEXT) logs global steps, the checkpoint's step plus
# its plan's, so its log says `done at step PLAN-BASE+BOUNDARY`
def hov.base(+c: HovCx) -> Nat:
  Rc.rcf.nat(hov.kvs(c), "plan-base", 0n)

# the control stage (run 4): ctl-stage NAME (none: no control), built by s2 in
# ctl-out (CTL_OUT) beside S2 and appended after it, starting from ctl-from
def hov.ctl.stage(+c: HovCx) -> String:
  hov.k(c, "ctl-stage", "")

def hov.ctl.on(+c: HovCx) -> Bool:
  Bool.not(String.is_empty(hov.ctl.stage(c)))

def hov.ctl.rel(+c: HovCx) -> String:
  hov.k(c, "ctl-out", "")

def hov.ctl(+c: HovCx) -> String:
  Rc.rcf.at(hov.td(c), hov.ctl.rel(c))

def hov.ctl.every(+c: HovCx) -> String:
  hov.k(c, "ctl-every", hov.every(c))

# the act workspace on the box and here, as bend/Box/Act.bend's environment names it
def hov.ac.of(+kvs: List<&2, Ev.EvKv>, +home: String) -> Ac.AcbCx:
  Ac.AcbCx{Rc.rcf.get(kvs, "act-ws", "/home/hhefesto/src/formalTransformer"), Rc.rcf.get(kvs, "act-home", home),
    Rc.rcf.get(kvs, "act-box-bin", "/usr/local/bin"), Rc.rcf.get(kvs, "act-deploy", "run/v2/gcroot-deploy-agent/bin/deploy"),
    Rc.rcf.get(kvs, "act-episode", "run/agent/gcroot-bend-episode/bin/bend-episode")}

# what `bend-ops act ...` gets: the same workspace, act-env, and chain.log for its lines
def hov.act.env(+c: HovCx) -> List<&2, String>:
  +a = hov.ac(c)
  List.append(&2, String, ["ACT_WS=" ++ Ac.acb.ws(a), "ACT_HOME=" ++ Ac.acb.home(a), "ACT_BOX_BIN=" ++ Ac.acb.bin(a), "ACT_DEPLOY=" ++ Ac.acb.dep(a),
    "ACT_EPISODE=" ++ Ac.acb.ep(a), "ACT_LOG=" ++ hov.dest(c) ++ "/chain.log"], Rc.rcf.every(hov.kvs(c), "act-env"))

def hov.cx.of(+kvs: List<&2, Ev.EvKv>, +cfg: String) -> IO(HovCx):
  do IO<HovCx>:
    +home : String <- S.env("HOME", "")
    +b : Rm.RmtBox <- Rm.rmt.box(Rc.rcf.get(kvs, "host", ""), Rc.rcf.get(kvs, "port", ""))
    +self : String <- Rc.rcf.self()
    return HovCx{b, hov.ac.of(kvs, home), kvs, cfg, self}

def hov.keys() -> List<&2, String>:
  ["host", "port", "dest", "stages", "trainer-dir", "boundary", "act-dir", "s2-from", "s2-out"]

# a key that must be a step number when it is there (plan-base 56,725 must not read as 0)
def hov.nat.ok(+kvs: List<&2, Ev.EvKv>, +key: String) -> Bool:
  +v = Rc.rcf.get(kvs, key, "")
  Bool.or(String.is_empty(v), Maybe.is_some(&2, Nat, Rc.rcf.nat.of(v)))

def hov.cx(+cfg: String) -> IO(HovCx):
  do IO<HovCx>:
    +kvs : List<&2, Ev.EvKv> <- Rc.rcf.read(cfg)
    Rc.rcf.need(kvs, hov.keys(), cfg)
    Rc.rcf.need(kvs, Bool.pick(List<&2, String>, String.is_empty(Rc.rcf.get(kvs, "ctl-stage", "")), Nil{}, ["ctl-out"]), cfg)
    Bool.pick(IO(Unit), Bool.and(hov.nat.ok(kvs, "plan-base"), hov.nat.ok(kvs, "boundary")), IO.pure(Unit, Unit{}),
      IO.die(Unit, 2, cfg ++ ": plan-base and boundary are step numbers"))
    hov.cx.of(kvs, cfg)

# Decisions (pure) ---------------------------------------------------------------------------------

def hov.q(+s: String) -> String:
  Rm.rmt.q(s)

# a stage line s2 may print: its paths relative to the trainer's directory, or absolute
def hov.want(+every: String, +out: String) -> String:
  "s2 traind-next " ++ every ++ " " ++ out ++ "/plan-fp100m-b16-windows.tsv " ++ out ++ " fp100m"

# the line appended to STAGES (relative: the chain looks for a plan under its BOX_DIR)
def hov.stage.line(+stage: String, +every: String, +rel: String) -> String:
  stage ++ " traind-next " ++ every ++ " " ++ rel ++ "/plan-fp100m-b16-windows.tsv " ++ rel ++ " fp100m"

# the step the boundary stage's log says it is done at: plan-base + boundary,
# the boundary's own text when plan-base is 0
def hov.done.step(+base: Nat, +bnd: String) -> String:
  Bool.pick(String, Nat.is_eq(base, 0n), bnd, Nat.show(Nat.add(base, Maybe.default(&2, Nat, Rc.rcf.nat.of(bnd), 0n))))

# the control stage's line: S2's form, then where it starts (the chain's from=)
def hov.ctl.line(+stage: String, +every: String, +rel: String, +from: String) -> String:
  hov.stage.line(stage, every, rel) ++ " from=" ++ from

# the boundary stage's last save, as bend-box again names it (out/NAME-step<N>):
# NAME the first stage's in STAGES, N the step its log says it is done at
def hov.ctl.from.of(+first: String, +g: String) -> String:
  "out/" ++ first ++ "-step" ++ g ++ ".checkpoint"

def hov.first.stage(+stages: List<&2, U32>) -> String:
  Ch.chn.st.name(Ch.chn.stage.of(Maybe.default(&2, List<&2, U32>, Ch.chn.stage.at(stages, 1n), Nil{})))

def hov.line.ok(+line: String, +every: String, +rel: String, +abs: String) -> Bool:
  Bool.or(String.eq(line, hov.want(every, rel)), String.eq(line, hov.want(every, abs)))

def hov.has.prefix(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(S.prefix(l, p), hov.has.prefix(t, p))

# stage.env as s2-driver.sh checked it: `grep -q '^NLR='` and `grep -q '^NWARM=10'`
def hov.env.ok(+xs: List<&2, U32>) -> Bool:
  +ls = S.split.lines(xs)
  Bool.and(hov.has.prefix(ls, S.b("NLR=")), hov.has.prefix(ls, S.b("NWARM=10")))

# `tr '\n' ' '`
def hov.spaced(+xs: List<&2, U32>) -> String:
  S.str(S.replace(xs, [10], [32]))

# each line followed by a space (`tail -3 | tr '\n' ' '` of these lines)
def hov.joined(ls: List<&2, List<&2, U32>>) -> String:
  match ls:
    case Nil{}:
      ""
    case l <> t:
      S.str(l) ++ " " ++ hov.joined(t)

def hov.last.n(+ls: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, List<&2, U32>>:
  List.drop(&2, List<&2, U32>, ls, Nat.sub(List.length(&2, List<&2, U32>, ls), n))

def hov.last(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Maybe.default(&2, List<&2, U32>, List.last(&2, List<&2, U32>, ls), Nil{})

# the act round's log's last line says it finished
def hov.act.done.of(+last: List<&2, U32>) -> Bool:
  S.infix(last, S.b("agent-act: done"))

# `grep -c . F 2>/dev/null || echo 0`'s number (its first word, else 0)
def hov.count.text(+o: Lc.LclOut) -> String:
  +w = Lc.lcl.nth(Lc.lcl.words(Lc.lcl.out(o)), 0n)
  Bool.pick(String, Bool.and(Nat.is_lt(0n, S.len(w)), Rc.rcf.digits(w)), S.str(w), "0")

# an accepted directory and its records (NULs / 2)
type HovN is Data:
  HovN{name: List<&2, U32>, n: Nat}

def hov.cnt.at(m: Maybe<&2, List<&2, U32>>) -> Nat:
  match m:
    case None{}:
      0n
    case Some{+x}:
      Nat.div(Maybe.default(&2, Nat, Rc.rcf.nat.of(S.str(x)), 0n), 2n)

# the rest of the first line that starts with p (a short list: the one walk is cheap)
def hov.cnt.find(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      None{}
    case +l <> t:
      Bool.pick(Maybe<&2, List<&2, U32>>, S.prefix(l, p), Some{List.drop(&2, U32, l, S.len(p))}, hov.cnt.find(t, p))

# each directory's count from `grep -H -c -z '' -- NAME/transcripts.train.nul...` (run in
# accepted/): its `NAME/transcripts.train.nul:N` line, N NUL-ended records; none: 0
def hov.counts.of(ns: List<&2, List<&2, U32>>, +out: List<&2, U32>) -> List<&2, HovN>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      HovN{n, hov.cnt.at(hov.cnt.find(S.split.lines(out), List.append(&2, U32, n, S.b("/transcripts.train.nul:"))))} <> hov.counts.of(t, out)

# `NAME COUNT` lines, as s2-driver.sh's loop printed them
def hov.counts.lines(cs: List<&2, HovN>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case HovN{n, k} <> t:
      List.concat(&2, U32, [n, [32], S.b(Nat.show(k)), [10], hov.counts.lines(t)])

# `accepted: NAME:COUNT ...`'s list (each followed by a space)
def hov.counts.line(cs: List<&2, HovN>) -> String:
  match cs:
    case Nil{}:
      ""
    case HovN{n, k} <> t:
      S.str(n) ++ ":" ++ Nat.show(k) ++ " " ++ hov.counts.line(t)

def hov.files(ns: List<&2, List<&2, U32>>) -> String:
  match ns:
    case Nil{}:
      ""
    case n <> t:
      " " ++ Rm.rmt.q(S.str(n) ++ "/transcripts.train.nul") ++ hov.files(t)

# `read -r`'s line: the blanks around it gone
def hov.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  Ac.acb.trim(xs)

def hov.lines.say(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      ("  " ++ S.str(hov.trim(l))) <> hov.lines.say(t)

def hov.nonempty(+st: Rm.RmtStat) -> Bool:
  match st:
    case Rm.RmtStatYes{+s}:
      Nat.is_lt(0n, Lc.lcl.st.size(s))
    case _:
      False{}

# The text to append to STAGES: on a line of its own
def hov.append.text(+stages: List<&2, U32>, +line: String) -> List<&2, U32>:
  +nl = Bool.and(Nat.is_lt(0n, S.len(stages)), Bool.not(S.suffix(stages, [10])))
  S.b(Bool.pick(String, nl, "\n", "") ++ line ++ "\n")

# Logs and the box -----------------------------------------------------------------------------------

def hov.log(+c: HovCx, +msg: String) -> IO(Unit):
  Al.alr.log(hov.dest(c) ++ "/chain.log", "handover: " ++ msg)

def hov.fail(+c: HovCx, +msg: String) -> IO(Unit):
  do IO<Unit>:
    hov.log(c, msg)
    IO.die(Unit, 1, "handover: stopped")

def hov.need(ok: Bool, +c: HovCx, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      hov.fail(c, msg)

# a box command's output on stderr (s2-driver.sh's stdout), as it came
def hov.show(+xs: List<&2, U32>) -> IO(Unit):
  Ob.obx.err(xs)

def hov.pass(+o: Lc.LclOut) -> IO(Unit):
  do IO<Unit>:
    hov.show(Lc.lcl.out(o))
    hov.show(Lc.lcl.err(o))

def hov.ssh(+c: HovCx, +secs: U32, +cmd: String) -> IO(Lc.LclOut):
  Rm.rmt.ssh(hov.box(c), secs, cmd)

def hov.says(ls: List<&2, String>, +c: HovCx) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        hov.log(c, l)
        hov.says(t, c)

# The wait -------------------------------------------------------------------------------------------

type HovW is Data:
  HovWait{}
  HovDone{}
  HovGone{}
  HovDied{text: String}
  HovOff{text: String}

def hov.waiting(+w: HovW) -> Bool:
  match w:
    case HovWait{}:
      True{}
    case _:
      False{}

def hov.has.line(ls: List<&2, List<&2, U32>>, +x: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(S.eq(l, x), hov.has.line(t, x))

# `grep -o 'done at step [0-9]*' LOG`'s answer: the boundary's line (done), another
# (the stage ended at a step that is not plan-base + boundary: its last such line),
# none, or no answer (wait)
def hov.done.of(+o: Lc.LclOut, +g: String) -> HovW:
  +ls = S.split.lines(Lc.lcl.out(o))
  Bool.pick(HovW, Bool.not(Lc.lcl.ok(o)), HovWait{}, Bool.pick(HovW, hov.has.line(ls, S.b("done at step " ++ g)), HovDone{},
    Bool.pick(HovW, List.is_empty(&2, List<&2, U32>, ls), HovWait{}, HovOff{S.str(hov.last(ls))})))

# where the boundary stage's log says it is done: plan-base + boundary
def hov.g(+c: HovCx) -> String:
  hov.done.step(hov.base(c), hov.bnd(c))

def hov.probe(+c: HovCx) -> IO(HovW):
  do IO<HovW>:
    +o : Lc.LclOut <- hov.ssh(c, 300, "grep -o -e " ++ hov.q("done at step [0-9]*") ++ " -- " ++ hov.q(hov.tlog(c)))
    return hov.done.of(o, hov.g(c))

# DESTROYED, then DIED (the chain's markers), then the boundary's line on the box
def hov.check(gone: Bool, died: Bool, +dt: List<&2, U32>, +c: HovCx) -> IO(HovW):
  match gone died:
    case True{} _:
      IO.pure(HovW, HovGone{})
    case False{} True{}:
      IO.pure(HovW, HovDied{S.str(S.chomp(dt))})
    case False{} False{}:
      hov.probe(c)

def hov.look(+c: HovCx) -> IO(HovW):
  do IO<HovW>:
    gone : Bool <- S.exists(hov.dest(c) ++ "/DESTROYED")
    died : Bool <- S.exists(hov.dest(c) ++ "/DIED")
    +dt : List<&2, U32> <- S.read(hov.dest(c) ++ "/DIED")
    hov.check(gone, died, dt, c)

def hov.wait.step(+c: HovCx) -> IO(HovW):
  do IO<HovW>:
    IO.sleep(U32.mul(Rm.rmt.secs(Rc.rcf.nat(hov.kvs(c), "handover-poll", 120n)), 1000))
    hov.look(c)

def hov.wait.go(fuel: Nat, +c: HovCx, w: HovW) -> IO(HovW):
  match fuel w:
    case 1n+f HovWait{}:
      IO.bind(HovW, HovW, hov.wait.step(c), hov.wait.go(f, c))
    case 0n HovWait{}:
      IO.pure(HovW, HovWait{})
    case _ HovDone{}:
      IO.pure(HovW, HovDone{})
    case _ HovGone{}:
      IO.pure(HovW, HovGone{})
    case _ HovDied{t}:
      IO.pure(HovW, HovDied{t})
    case _ HovOff{t}:
      IO.pure(HovW, HovOff{t})

# The act round ----------------------------------------------------------------------------------------

def hov.act.done(+c: HovCx) -> IO(Bool):
  do IO<Bool>:
    +t : Lc.LclOut <- hov.ssh(c, 120, "tail -n 1 -- " ++ hov.q(hov.w(c, hov.act(c) ++ ".log")))
    return hov.act.done.of(Lc.lcl.out(t))

def hov.stopped(ok: Bool, +c: HovCx, +o: Lc.LclOut) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      hov.fail(c, "the act round did not stop (bend-box act-stop exit " ++ U32.show(Lc.lcl.status(o)) ++ ")")

def hov.stop.if(done: Bool, +c: HovCx) -> IO(Unit):
  match done:
    case True{}:
      hov.log(c, "act round " ++ hov.act(c) ++ " had finished by itself")
    case False{}:
      do IO<Unit>:
        +n : Lc.LclOut <- hov.ssh(c, 300, "grep -c . -- " ++ hov.q(hov.w(c, hov.act(c) ++ "/render.txt")))
        hov.log(c, "stopping act round " ++ hov.act(c) ++ ": " ++ hov.count.text(n) ++ " episodes so far")
        +s : Lc.LclOut <- hov.ssh(c, 3600, "env -C " ++ hov.q(hov.td(c)) ++ " ACT_PROC=" ++ hov.q(hov.k(c, "act-proc", "bend-corpus-v2")) ++ " ACT_STOP_WAIT="
          ++ hov.q(hov.k(c, "act-stop-wait", "15")) ++ " " ++ hov.q(hov.k(c, "box-driver", "./bend-box")) ++ " act-stop")
        hov.pass(s)
        hov.stopped(Lc.lcl.ok(s), c, s)

def hov.ens.got(+st: U32, +c: HovCx) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(st, 0), hov.log(c, "act round " ++ hov.act(c) ++ " ensured"),
    hov.log(c, "act ensure failed (exit " ++ U32.show(st) ++ "); waiting for the boundary anyway"))

def hov.ens.go(done: Bool, +c: HovCx) -> IO(Unit):
  match done:
    case True{}:
      hov.log(c, "act round " ++ hov.act(c) ++ " has finished; not ensured")
    case False{}:
      do IO<Unit>:
        hov.log(c, "act round " ++ hov.act(c) ++ ": bend-ops act ensure")
        +st : U32 <- Aa.aac.follow(hov.act.env(c), hov.self(c), ["act", "ensure", hov.k(c, "host", ""), hov.k(c, "port", ""),
          hov.k(c, "act-ckpt", ""), hov.act(c)])
        hov.ens.got(st, c)

# act-ensure yes, and the boundary still ahead: the round set up and started unless it runs
def hov.ensure.if(go: Bool, +c: HovCx) -> IO(Unit):
  match go:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        d : Bool <- hov.act.done(c)
        hov.ens.go(d, c)

# Accept and fixed -------------------------------------------------------------------------------------

def hov.acc.fail(+c: HovCx) -> IO(Unit):
  hov.fail(c, "accept/fixed failed on the box")

def hov.acc.ok(ok: Bool, +c: HovCx, +o: Lc.LclOut) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        hov.show(Lc.lcl.err(o))
        hov.acc.fail(c)

def hov.eplog.need(ok: Bool, +c: HovCx) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        IO.print_err("no episodes in " ++ hov.act(c) ++ "/episodes.eplog")
        hov.acc.fail(c)

def hov.counts.ask(+c: HovCx, ns: List<&2, List<&2, U32>>) -> IO(Lc.LclOut):
  match ns:
    case Nil{}:
      IO.pure(Lc.LclOut, Lc.LclOut{0, Nil{}, Nil{}})
    case +n <> t:
      hov.ssh(c, 600, "env -C " ++ hov.q(hov.w(c, hov.act(c) ++ "/accepted")) ++ " grep -H -c -z '' --" ++ hov.files(n <> t))

def hov.ep(+c: HovCx, env: List<&2, String>, +mode: String, +redir: String) -> String:
  +a = hov.act(c)
  Ac.acb.rw(hov.ac(c), env, Ac.acb.ep(hov.ac(c)), [mode, hov.k(c, "act-calls", "4"), hov.k(c, "act-cap", "2"), a ++ "/accepted", a ++ "/episodes.eplog"])
    ++ redir ++ hov.q(hov.w(c, a ++ ".accept.log")) ++ " 2>&1"

# the eplog cut to whole frames, then agent-act's tail: accept, fixed
def hov.accept(+c: HovCx) -> IO(Unit):
  +a = hov.act(c)
  do IO<Unit>:
    +st : Rm.RmtStat <- Rm.rmt.stat(hov.box(c), hov.w(c, a ++ "/episodes.eplog"))
    hov.eplog.need(hov.nonempty(st), c)
    +k : Lc.LclOut <- hov.ssh(c, 3600, "env -C " ++ hov.q(hov.ws(c)) ++ " " ++ hov.q(hov.drv(c)) ++ " cut-frames " ++ hov.q(a ++ "/episodes.eplog"))
    hov.pass(k)
    hov.acc.ok(Lc.lcl.ok(k), c, k)
    +r : Lc.LclOut <- hov.ssh(c, 600, "rm -rf -- " ++ hov.q(hov.w(c, a ++ "/accepted")))
    hov.acc.ok(Lc.lcl.ok(r), c, r)
    +p : Lc.LclOut <- hov.ssh(c, 21600, hov.ep(c, Nil{}, "accept", " > "))
    hov.acc.ok(Lc.lcl.ok(p), c, p)
    +f : Lc.LclOut <- hov.ssh(c, 21600, hov.ep(c, ["AGENT_RECORDS=train"], "fixed", " >> "))
    hov.acc.ok(Lc.lcl.ok(f), c, f)
    +t : Lc.LclOut <- hov.ssh(c, 120, "tail -n 4 -- " ++ hov.q(hov.w(c, a ++ ".accept.log")))
    hov.show(Lc.lcl.out(t))
    +d : Lc.LclOut <- hov.ssh(c, 300, "find " ++ hov.q(hov.w(c, a ++ "/accepted")) ++ " -mindepth 1 -maxdepth 1 -type d -printf '%f\\n'")
    +ns : List<&2, List<&2, U32>> = Lc.lcl.sort(S.split.lines(Lc.lcl.out(d)))
    +g : Lc.LclOut <- hov.counts.ask(c, ns)
    +cs : List<&2, HovN> = hov.counts.of(ns, Lc.lcl.out(g))
    hov.show(hov.counts.lines(cs))
    hov.log(c, "accepted: " ++ hov.counts.line(cs))

# S2 ---------------------------------------------------------------------------------------------------

# with a control stage, s2 builds its plan too (CTL_OUT)
def hov.s2.cmd(+c: HovCx) -> String:
  +ctl = Bool.pick(List<&2, String>, hov.ctl.on(c), ["CTL_OUT=" ++ hov.ctl(c)], Nil{})
  Ac.acb.rw(hov.ac(c), List.concat(&2, String, [["S1_LOG=" ++ hov.tlog(c), "TRAINER_DIR=" ++ hov.td(c), "EVERY=" ++ hov.every(c)], ctl, Rc.rcf.every(hov.kvs(c), "s2-env")]),
    Ac.acb.dep(hov.ac(c)), ["corpus-v2", "s2", hov.s1(c), hov.bnd(c), hov.s2(c), hov.act(c)]) ++ " > " ++ hov.q(hov.s2log(c)) ++ " 2>&1"

def hov.env.got(ok: Bool, +c: HovCx, +env: List<&2, U32>) -> IO(Unit):
  match ok:
    case False{}:
      hov.fail(c, "S2's plan or stage.env is missing on the box")
    case True{}:
      hov.log(c, "S2 stage.env: " ++ hov.spaced(env))

def hov.say.if(yes: Bool, +c: HovCx, +msg: String) -> IO(Unit):
  match yes:
    case True{}:
      hov.log(c, msg)
    case False{}:
      IO.pure(Unit, Unit{})

# STAGES gets S2's line, then (with a control stage) the control's, in one write
def hov.append.go(has: Bool, +c: HovCx, +st: List<&2, U32>, +line: String, +ctl: String, +which: String) -> IO(Unit):
  match has:
    case True{}:
      hov.fail(c, "a stage " ++ which ++ " is already in " ++ hov.stages(c) ++ "; not appending")
    case False{}:
      do IO<Unit>:
        S.add(hov.stages(c), hov.append.text(st, Bool.pick(String, String.is_empty(ctl), line, line ++ "\n" ++ ctl)))
        hov.log(c, "appended to " ++ hov.stages(c) ++ ": " ++ line)
        hov.say.if(Bool.not(String.is_empty(ctl)), c, "appended to " ++ hov.stages(c) ++ ": " ++ ctl)

def hov.append(+c: HovCx, +from: String) -> IO(Unit):
  +line = hov.stage.line(hov.stage(c), hov.every(c), hov.s2rel(c))
  +ctl = Bool.pick(String, hov.ctl.on(c), hov.ctl.line(hov.ctl.stage(c), hov.ctl.every(c), hov.ctl.rel(c), from), "")
  do IO<Unit>:
    +st : List<&2, U32> <- S.read(hov.stages(c))
    +s2has : Bool = Gd.grd.has.stage(st, hov.stage(c))
    +ctlhas : Bool = Bool.and(hov.ctl.on(c), Gd.grd.has.stage(st, hov.ctl.stage(c)))
    hov.append.go(Bool.or(s2has, ctlhas), c, st, line, ctl, Bool.pick(String, s2has, hov.stage(c), hov.ctl.stage(c)))

def hov.ctl.got(ok: Bool, +c: HovCx, +env: List<&2, U32>, +from: String) -> IO(Unit):
  match ok:
    case False{}:
      hov.fail(c, "the control stage's plan or stage.env (" ++ hov.ctl(c) ++ "), or " ++ from ++ ", is missing on the box")
    case True{}:
      hov.log(c, "control stage.env: " ++ hov.spaced(env) ++ "; " ++ hov.ctl.stage(c) ++ " starts from " ++ from)

# a control stage: its plan and stage.env, and the save it starts from, on the box
def hov.ctl.check(on: Bool, +c: HovCx, +from: String) -> IO(Unit):
  match on:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        +ps : Rm.RmtStat <- Rm.rmt.stat(hov.box(c), hov.ctl(c) ++ "/plan-fp100m-b16-windows.tsv")
        +e : Lc.LclOut <- hov.ssh(c, 120, "cat -- " ++ hov.q(hov.ctl(c) ++ "/stage.env"))
        +fs : Rm.RmtStat <- Rm.rmt.stat(hov.box(c), Rc.rcf.at(hov.td(c), from))
        hov.ctl.got(Bool.and(Bool.and(hov.nonempty(ps), hov.nonempty(fs)), Bool.and(Lc.lcl.ok(e), hov.env.ok(Lc.lcl.out(e)))), c, Lc.lcl.out(e), from)

def hov.s2.ok(+c: HovCx, +ls: List<&2, List<&2, U32>>) -> IO(Unit):
  +line = S.str(hov.last(ls))
  do IO<Unit>:
    hov.says(hov.lines.say(ls), c)
    hov.need(hov.line.ok(line, hov.every(c), hov.s2rel(c), hov.s2(c)), c, "unexpected stage line from s2: '" ++ line ++ "'")
    +ps : Rm.RmtStat <- Rm.rmt.stat(hov.box(c), hov.s2(c) ++ "/plan-fp100m-b16-windows.tsv")
    +e : Lc.LclOut <- hov.ssh(c, 120, "cat -- " ++ hov.q(hov.s2(c) ++ "/stage.env"))
    hov.env.got(Bool.and(Bool.and(hov.nonempty(ps), Lc.lcl.ok(e)), hov.env.ok(Lc.lcl.out(e))), c, Lc.lcl.out(e))
    +st : List<&2, U32> <- S.read(hov.stages(c))
    +from : String = hov.k(c, "ctl-from", hov.ctl.from.of(hov.first.stage(st), hov.g(c)))
    hov.ctl.check(hov.ctl.on(c), c, from)
    hov.append(c, from)

def hov.s2.got(ok: Bool, +c: HovCx, +t: List<&2, U32>) -> IO(Unit):
  match ok:
    case False{}:
      hov.fail(c, "s2 failed: " ++ hov.joined(hov.last.n(S.split.lines(t), 3n)))
    case True{}:
      hov.s2.ok(c, S.split.lines(t))

def hov.s2.run(+c: HovCx) -> IO(Unit):
  do IO<Unit>:
    hov.log(c, "s2: " ++ hov.s1(c) ++ " " ++ hov.bnd(c) ++ " -> " ++ hov.s2(c))
    +o : Lc.LclOut <- hov.ssh(c, 21600, hov.s2.cmd(c))
    +t : Lc.LclOut <- hov.ssh(c, 120, "tail -n 8 -- " ++ hov.q(hov.s2log(c)))
    hov.s2.got(Lc.lcl.ok(o), c, Lc.lcl.out(t))

# The pull ---------------------------------------------------------------------------------------------

def hov.pull.got(+st: U32, +c: HovCx) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(st, 0), hov.log(c, "act round " ++ hov.act(c) ++ " pulled here"),
    hov.fail(c, "the act round's pull failed (bend-ops act pull exit " ++ U32.show(st) ++ ")"))

def hov.pull.if(yes: Bool, +c: HovCx) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        hov.log(c, "pulling act round " ++ hov.act(c) ++ " here (bend-ops act pull)")
        +st : U32 <- Aa.aac.follow(hov.act.env(c), hov.self(c), ["act", "pull", hov.k(c, "host", ""), hov.k(c, "port", ""), hov.act(c)])
        hov.pull.got(st, c)

# Main -------------------------------------------------------------------------------------------------

# a hot-started boundary stage: the plan's step its global step stands for (nothing when plan-base is 0)
def hov.base.say(+c: HovCx) -> String:
  Bool.pick(String, Nat.is_eq(hov.base(c), 0n), "", " (plan-base " ++ Nat.show(hov.base(c)) ++ " + boundary " ++ hov.bnd(c) ++ ")")

def hov.boundary(+c: HovCx) -> IO(Unit):
  do IO<Unit>:
    hov.log(c, "S1 is done at step " ++ hov.g(c) ++ hov.base.say(c))
    d : Bool <- hov.act.done(c)
    hov.stop.if(d, c)
    hov.accept(c)
    hov.s2.run(c)
    hov.pull.if(Rc.rcf.yes(hov.kvs(c), "act-pull", False{}), c)

def hov.after(w: HovW, +c: HovCx) -> IO(Unit):
  match w:
    case HovGone{}:
      hov.log(c, "the box is destroyed; nothing to do")
    case HovDied{+t}:
      hov.fail(c, "a stage died (" ++ t ++ "); no S2")
    case HovWait{}:
      hov.fail(c, "gave up waiting for the boundary")
    case HovOff{+t}:
      hov.fail(c, "S1's log says '" ++ t ++ "', not 'done at step " ++ hov.g(c) ++ "'" ++ hov.base.say(c) ++ ": no S2 (is plan-base or TRAIN_STEPS wrong?)")
    case HovDone{}:
      hov.boundary(c)

def hov.wait(+c: HovCx) -> IO(Unit):
  do IO<Unit>:
    hov.log(c, "waiting for S1's 'done at step " ++ hov.g(c) ++ "' in " ++ hov.tlog(c) ++ hov.base.say(c))
    +w0 : HovW <- hov.look(c)
    hov.ensure.if(Bool.and(hov.waiting(w0), Rc.rcf.yes(hov.kvs(c), "act-ensure", False{})), c)
    w : HovW <- hov.wait.go(U32.to_nat(100000000), c, w0)
    hov.after(w, c)

def hov.go(has: Bool, +c: HovCx) -> IO(Unit):
  match has:
    case True{}:
      hov.log(c, "a stage " ++ hov.stage(c) ++ " is already in " ++ hov.stages(c) ++ "; nothing to do")
    case False{}:
      hov.wait(c)

def hov.run(+cfg: String) -> IO(Unit):
  do IO<Unit>:
    +c : HovCx <- hov.cx(cfg)
    +st : List<&2, U32> <- S.read(hov.stages(c))
    hov.go(Gd.grd.has.stage(st, hov.stage(c)), c)

def hov.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +cfg <> Nil{}:
      hov.run(cfg)
    case _:
      IO.die(Unit, 2, "usage: bend-ops handover CFG   (tools/runs/TEMPLATE.cfg)")
