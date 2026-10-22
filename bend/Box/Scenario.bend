import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc

# Scenario: the chain and the watch against a box in a sandbox, without a
# box, a GPU or money (2026-10-14, the plan's Phase 1a verification).
#
#   bend-ops sim N DIR            scenario N (1..10) in DIR/sN-box (BOX_DRIVER ./bend-box) and, for 1, 2,
#                                 4 and 7, DIR/sN-fp (./fp.sh) and DIR/sN-old (the old scripts), each
#                                 wiped first; `ok`/`FAIL` lines, exit 1 on a FAIL
#   bend-ops sim all DIR          every scenario, one after the other
#   bend-ops sim soak DIR SECS    the chain at POLL=1 on a trainer that runs for SECS, its
#                                 resident memory (VmRSS) every 60 s
#
# What it needs: bend-sim (BEND_SIM, else on $PATH), bend-box (BEND_BOX, else on
# $PATH: the real on-box driver, run in the sandbox), the repository (SIM_REPO,
# else the current directory: bend/gpu/fp.sh for the box, and the old
# fp-chain.sh and credit-watch.sh for the comparisons), rsync and pkill on
# $PATH, and for the old credit watch bend-corpus-v2 (SIM_CV2, else on $PATH).
#
# A run's directory D holds: bin/ (ssh, rsync, notify-send, vastai: bend-sim,
# first on the chain's PATH), box/ (the box's home: bin/ with its nvidia-smi,
# pgrep and pkill; ana/ with traind, traind-next and dense linked
# to bend-sim, bend-box linked to the real one, a copy of fp.sh, run/sim/S1..S3's
# plans, run/eval's corpora, out/), vast/ (the vastai stub's state: instance
# 4242), stages, dest/ (the chain's DEST), home/, alerts (notify-send's), and
# chain.rc/chain.out, watch.rc/watch.out (each program's status and output).
# The first stage's trainer is started on the box (OUT=out/s1, its log
# train.log), then the watch and the chain, both from D with relative DEST and
# STAGES and a host of their own (root@sim-TAG); the steps act when their
# trigger comes (a chain.log line, a file on the box, a pause): append a stage,
# put a plan on the box, take the link down and up, corrupt a pulled copy,
# HOLD, CONTINUED, the credit, kill and restart the chain.  The expectations
# are then read from the files; for scenarios 1, 2, 4 and 7 the same run with
# the old scripts (BOX_DRIVER ./fp.sh semantics) is compared with both new runs: chain.log's
# event lines (stamps stripped, per-poll lines and `ssh failed; retrying`
# left out, trainer pids masked), the markers, DEST/out and the box's out/.
#
# Every name starts with `scn.`.

# Scenarios --------------------------------------------------------------------------------------

type ScnTrig is Data:
  TrNow{}
  TrLog{text: String}
  TrBox{rel: String}
  TrSleep{ms: Nat}

type ScnAct is Data:
  AcNone{}
  AcAppend{line: String}
  AcBox{rel: String, text: String}
  AcLink{down: Bool}
  AcRsync{down: Bool}
  AcCorrupt{name: String}
  AcHold{secs: Nat}
  AcFile{rel: String, text: String}
  AcCredit{text: String}
  AcKill{}
  AcStart{}

type ScnStep is Data:
  ScnStep{tr: ScnTrig, ac: ScnAct}

type ScnExp is Data:
  ExMark{name: String, there: Bool}
  ExMarkHas{name: String, text: String}
  ExRc{code: String}
  ExLog{text: String, there: Bool}
  ExOut{names: List<&2, String>}
  ExBox{names: List<&2, String>}
  ExStarts{n: Nat}
  ExAlert{text: String}
  ExListed{there: Bool}
  ExBoxFile{rel: String}

# a scenario: its number, what it shows, STAGES, the plans' steps (S1, S2, S3;
# "" for no plan), the box's .sim-env lines, the vastai stub's marker files,
# the chain's and watch's environment, whether the new chain also runs with
# BOX_DRIVER ./fp.sh and the old scripts with it (compared), its steps and expectations
type Scn is Data:
  Scn{id: String, about: String, stages: String, plans: List<&2, String>, simenv: List<&2, String>, vast: List<&2, String>,
    env: List<&2, String>, compare: Bool, steps: List<&2, ScnStep>, exps: List<&2, ScnExp>}

def scn.ck(+step: Nat) -> String:
  "s" ++ "-step" ++ Nat.show(step) ++ ".checkpoint"

def scn.cks(+name: String, steps: List<&2, Nat>) -> List<&2, String>:
  match steps:
    case Nil{}:
      Nil{}
    case +s <> t:
      (name ++ "-step" ++ Nat.show(s) ++ ".checkpoint") <> scn.cks(name, t)

def scn.at(+text: String, +ac: ScnAct) -> ScnStep:
  ScnStep{TrLog{text}, ac}

def scn.s1() -> Scn:
  Scn{"1", "happy path: a stage appended while the chain waits, its plan put on the box while the chain waits for it, an EVERY 0 stage, the scores, verify, destroy",
    "s1 traind 10\ns2 traind-next 0 run/sim/S2/plan-sim.tsv run/sim/S2 sim\n", ["30", "30", ""], Nil{}, Nil{}, Nil{}, True{},
    [scn.at("no stage 3 yet", AcAppend{"s3 traind-next 10 run/sim/S3/plan-sim.tsv run/sim/S3 sim"}),
     scn.at("stage s3: waiting up to", AcBox{"run/sim/S3/plan-sim.tsv", "plan sim 30\n"})],
    [ExRc{"0"}, ExMark{"DESTROYED", True{}}, ExMark{"REFUSED", False{}}, ExMark{"DIED", False{}},
     ExLog{"] stage s2: from out/s1-step30.checkpoint on run/sim/S2/plan-sim.tsv\n", True{}},
     ExLog{"] deleted out/s2-step60.checkpoint on the box (a raw stage's, loaded by s3)\n", True{}},
     ExLog{"] eval: out/s1-step10.checkpoint out/s1-step20.checkpoint out/s1-step30.checkpoint  out/s3-step70.checkpoint out/s3-step80.checkpoint out/s3-step90.checkpoint \n", True{}},
     ExLog{"\n== out/s3-step90.checkpoint\n", True{}}, ExLog{"\nnext:\n", True{}},
     ExLog{"] pulled: 6 checkpoints on the box, each matching its copy here; none of the 8 wanted missing\n", True{}},
     ExLog{"] destroy instance 4242\ndestroying instance 4242.\n", True{}}, ExLog{"] finished\n", True{}},
     ExOut{List.append(&2, String, scn.cks("s1", [10n, 20n, 30n]), scn.cks("s3", [70n, 80n, 90n]))},
     ExBox{List.append(&2, String, scn.cks("s1", [10n, 20n, 30n]), scn.cks("s3", [70n, 80n, 90n]))},
     ExStarts{3n}, ExListed{False{}}]}

def scn.s2() -> Scn:
  Scn{"2", "link drops: during the follow (ssh and rsync fail for 3 s), and during a pull (rsync fails for 3 s while ssh answers)",
    "s1 traind 10\n", ["40", "", ""], ["SIM_SLEEP_MS=300"], Nil{}, Nil{}, True{},
    [scn.at("] train.log running: ", AcLink{True{}}), ScnStep{TrSleep{3000n}, AcLink{False{}}},
     ScnStep{TrBox{"out/s1-step20.checkpoint"}, AcRsync{True{}}}, ScnStep{TrSleep{3000n}, AcRsync{False{}}}],
    [ExRc{"0"}, ExMark{"DESTROYED", True{}}, ExMark{"REFUSED", False{}}, ExLog{"] pulled s1-step20.checkpoint\n", True{}},
     ExLog{"could not pull", False{}},
     ExLog{"] pulled: 4 checkpoints on the box, each matching its copy here; none of the 5 wanted missing\n", True{}},
     ExOut{scn.cks("s1", [10n, 20n, 30n, 40n])}, ExBox{scn.cks("s1", [10n, 20n, 30n, 40n])}]}

def scn.s3() -> Scn:
  Scn{"3", "stage death: the second stage's trainer dies at step 47 (DEAD_QUIET 5 s): DIED, an alert, no later stage, the scores and the destroy",
    "s1 traind 10\ns2 traind-next 10 run/sim/S2/plan-sim.tsv run/sim/S2 sim\ns3 traind-next 10 run/sim/S3/plan-sim.tsv run/sim/S3 sim\n", ["30", "30", "30"],
    ["SIM_DIE_AT=47"], Nil{}, ["DEAD_QUIET=5"], False{},
    Nil{},
    [ExRc{"0"}, ExMarkHas{"DIED", "s2.log: the trainer died"}, ExAlert{"s2.log: the trainer died"}, ExLog{"] s2.log: died\n", True{}},
     ExLog{"stage s3", False{}}, ExMark{"DESTROYED", True{}},
     ExLog{"] pulled: 5 checkpoints on the box, each matching its copy here; none of the 6 wanted missing\n", True{}},
     ExOut{List.append(&2, String, scn.cks("s1", [10n, 20n, 30n]), scn.cks("s2", [40n, 45n]))}, ExStarts{2n}]}

def scn.s4() -> Scn:
  Scn{"4", "a corrupted local copy (s1-step10, same size) mended by verify's --checksum pull",
    "s1 traind 10\n", ["30", "", ""], Nil{}, Nil{}, Nil{}, True{},
    [scn.at("] pulled s1-step10.checkpoint\n", AcCorrupt{"s1-step10.checkpoint"})],
    [ExRc{"0"}, ExMark{"DESTROYED", True{}},
     ExLog{"] verify, try 1: not here with the box's sha256: s1-step10.checkpoint; again in 2 s\n", True{}},
     ExAlert{"the box is not destroyed yet: not here with the box's sha256: s1-step10.checkpoint; trying again every 0 min, 12 times"},
     ExLog{"] pulled: 3 checkpoints on the box, each matching its copy here; none of the 4 wanted missing\n", True{}},
     ExOut{scn.cks("s1", [10n, 20n, 30n])}]}

def scn.s5() -> Scn:
  Scn{"5", "a wanted checkpoint (s1-step20, unreadable on the box) never comes: REFUSED and exit 1; the watch destroys after GRACE once the box is safe",
    "s1 traind 10\n", ["30", "", ""], ["SIM_UNREADABLE_AT=20"], Nil{}, ["RSYNC_TRIES=2", "GRACE=3"], False{},
    [scn.at("credit-watch: every checkpoint on the box (2) is here with its sha256: destroy instance 4242", AcNone{}), scn.at("] credit-watch: finished", AcNone{})],
    [ExRc{"1"}, ExMarkHas{"REFUSED", " wanted but not pulled: s1-step20.checkpoint;"}, ExLog{"] could not pull s1-step20.checkpoint\n", True{}},
     ExAlert{"the box is NOT destroyed: wanted but not pulled: s1-step20.checkpoint; DEST/REFUSED written"},
     ExMark{"DESTROYED", True{}}, ExLog{"] credit-watch: finished\n", True{}}, ExListed{False{}}]}

def scn.s6() -> Scn:
  Scn{"6", "credit low: the stub's credit falls to 0.5 under MIN 1.00; the watch stops the trainer, CREDIT_LOW; the stage dies, the chain scores, pulls and destroys",
    "s1 traind 10\n", ["200", "", ""], Nil{}, Nil{}, ["DEAD_QUIET=4", "LOW_WAIT=3600"], False{},
    [scn.at("] train.log running: ", AcCredit{"0.5"})],
    [ExRc{"0"}, ExMark{"CREDIT_LOW", True{}},
     ExLog{"] credit-watch: credit $0.5 is under $1.00: stopping the trainer so the chain scores, pulls and destroys\n", True{}},
     ExMark{"DIED", True{}}, ExMark{"DESTROYED", True{}}, ExLog{"] finished\n", True{}}]}

def scn.s7() -> Scn:
  Scn{"7", "HOLD then CONTINUED: the destroy waits for HOLD's deadline (an hour ahead); CONTINUED is written: not destroyed, exit 0",
    "s1 traind 10\n", ["30", "", ""], Nil{}, Nil{}, Nil{}, True{},
    [ScnStep{TrNow{}, AcHold{U32.to_nat(3600)}}, scn.at("] pulled: ", AcNone{}), ScnStep{TrSleep{3000n}, AcFile{"dest/CONTINUED", ""}}],
    [ExRc{"0"}, ExLog{"] someone took the box over; not destroying it\n", True{}}, ExMark{"DESTROYED", False{}}, ExLog{"destroy instance", False{}},
     ExListed{True{}}]}

def scn.s8() -> Scn:
  Scn{"8", "the destroy does not take (the stub's destroy.noop): REFUSED, exit 1, no DESTROYED; the watch tries after GRACE and alerts",
    "s1 traind 10\n", ["30", "", ""], Nil{}, ["destroy.noop"], ["GRACE=2"], False{},
    [scn.at("credit-watch: ALERT: the chain refused the destroy", AcNone{})],
    [ExRc{"1"}, ExMarkHas{"REFUSED", " the destroy did not take"}, ExAlert{"instance 4242 still listed after destroy"}, ExMark{"DESTROYED", False{}},
     ExLog{"; not destroyed: instance 4242 still listed after destroy\n", True{}}, ExListed{True{}}]}

def scn.s9() -> Scn:
  Scn{"9", "the listing fails after the destroy (the stub's list.fail): never taken as destroyed, REFUSED, exit 1",
    "s1 traind 10\n", ["30", "", ""], Nil{}, ["list.fail"], Nil{}, False{},
    Nil{},
    [ExRc{"1"}, ExMarkHas{"REFUSED", " the listing failed after the destroy: vastai show instances failed (exit 1)"}, ExMark{"DESTROYED", False{}},
     ExLog{"] the listing did not read (vastai show instances failed (exit 1)); asking again in 1 s\n", True{}}, ExLog{"] finished\n", False{}},
     ExAlert{"no listing that reads after the destroy"}]}

def scn.s10() -> Scn:
  Scn{"10", "stage s2's start loses its connection after the launch (the box's .drop-after: ssh's 255, no answer); the chain killed (SIGKILL) right after that start and again while it follows s2, restarted each time: one trainer per stage, the chain resumes and finishes",
    "s1 traind 10\ns2 traind-next 10 run/sim/S2/plan-sim.tsv run/sim/S2 sim\n", ["30", "60", ""], Nil{}, Nil{}, Nil{}, False{},
    [ScnStep{TrNow{}, AcFile{"box/.drop-after", "' again '"}}, scn.at("closed by remote host", AcKill{}), ScnStep{TrSleep{2000n}, AcStart{}},
     scn.at("] s2.log running: ", AcKill{}), ScnStep{TrSleep{1000n}, AcStart{}}],
    [ExRc{"0"}, ExStarts{2n}, ExLog{"Connection to root@sim-s10-box closed by remote host. (bend-sim: .drop-after)\n", True{}},
     ExLog{"no log on the box after the start", False{}}, ExMark{"DESTROYED", True{}}, ExMark{"REFUSED", False{}},
     ExOut{List.append(&2, String, scn.cks("s1", [10n, 20n, 30n]), scn.cks("s2", [40n, 50n, 60n, 70n, 80n, 90n]))}]}

def scn.all() -> List<&2, Scn>:
  [scn.s1(), scn.s2(), scn.s3(), scn.s4(), scn.s5(), scn.s6(), scn.s7(), scn.s8(), scn.s9(), scn.s10()]

def scn.find(ss: List<&2, Scn>, +id: String) -> Maybe<&2, Scn>:
  match ss:
    case Nil{}:
      None{}
    case Scn{+i, a, st, p, se, v, e, c, sp, ex} <> t:
      Bool.pick(Maybe<&2, Scn>, String.eq(i, id), Some{Scn{i, a, st, p, se, v, e, c, sp, ex}}, scn.find(t, id))

# A run -----------------------------------------------------------------------------------------------

# a run: its directory, tag (sN-new, sN-old, sN-box), whether it is the old
# scripts, the binaries and the repository, the environment the chain and the
# watch get, the host name, the driver
type ScnCx is Data:
  ScnCx{d: String, tag: String, old: Bool, self: String, sim: String, repo: String, env: List<&2, String>, host: String, bbox: String}

def scn.d(+c: ScnCx) -> String:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      d

def scn.tag(+c: ScnCx) -> String:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      t

def scn.old(+c: ScnCx) -> Bool:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      o

def scn.self(+c: ScnCx) -> String:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      s

def scn.sim(+c: ScnCx) -> String:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      m

def scn.repo(+c: ScnCx) -> String:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      r

def scn.env(+c: ScnCx) -> List<&2, String>:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      e

def scn.host(+c: ScnCx) -> String:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      h

def scn.bbox(+c: ScnCx) -> String:
  match c:
    case ScnCx{d, t, o, s, m, r, e, h, bb}:
      bb

def scn.box(+c: ScnCx) -> String:
  scn.d(c) ++ "/box"

def scn.ft(+c: ScnCx) -> String:
  scn.d(c) ++ "/box/ana"

def scn.dest(+c: ScnCx) -> String:
  scn.d(c) ++ "/dest"

def scn.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> scn.l1(t)

def scn.say(+c: ScnCx, +msg: String) -> IO(Unit):
  Ck.log("sim " ++ scn.tag(c) ++ ": " ++ msg)

def scn.sleep(+ms: Nat) -> IO(Unit):
  IO.sleep(U32.from_nat(Nat.min(ms, U32.to_nat(4000000000))))

def scn.run(+secs: U32, prog: String, args: List<String>) -> IO(Lc.LclOut):
  Lc.lcl.run(secs, prog, args)

def scn.links(+self: String, +dir: String, names: List<&2, String>) -> IO(Unit):
  match names:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        o : Lc.LclOut <- scn.run(30, "ln", ["-sfn", self, dir ++ "/" ++ n])
        scn.links(self, dir, t)

def scn.plans(+ft: String, ps: List<&2, String>, +i: Nat) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> t:
      +dir = ft ++ "/run/sim/S" ++ Nat.show(i)
      do IO<Unit>:
        S.mkdir(dir)
        Bool.pick(IO(Unit), String.is_empty(p), IO.pure(Unit, Unit{}), S.write(dir ++ "/plan-sim.tsv", S.b("plan sim " ++ p ++ "\n")))
        scn.plans(ft, t, 1n+i)

def scn.marks(+dir: String, ns: List<&2, String>) -> IO(Unit):
  match ns:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        S.write(dir ++ "/" ++ n, Nil{})
        scn.marks(dir, t)

def scn.lines(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      x ++ "\n" ++ scn.lines(t)

def scn.simenv(+c: ScnCx, +extra: List<&2, String>) -> List<&2, String>:
  List.append(&2, String, ["SAVE=5", "SIM_SLEEP_MS=150", "SIM_STARTS=" ++ scn.box(c) ++ "/.sim-starts", "NLR=1e-4"], extra)

# a script as it ran before it was unwired: the `# UNWIRED DATE: why` line
# and the `exit 2` after the shebang left out, so the comparisons with the
# old scripts (fp.sh, fp-chain.sh, credit-watch.sh) still run once they are
# unwired (2026-10-15)
def scn.unwired.drop(+ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case +sb <> +u <> +x <> +rest:
      Bool.pick(List<&2, List<&2, U32>>, S.prefix(u, S.b("# UNWIRED ")), sb <> rest, sb <> u <> x <> rest)
    case _:
      ls

# SRC copied to DST without its unwired header (above), executable
def scn.copy.live(+src: String, +dst: String) -> IO(Unit):
  do IO<Unit>:
    t : List<&2, U32> <- S.read(src)
    S.write(dst, List.append(&2, U32, S.join(scn.unwired.drop(S.split.lines(t)), 10), [10]))
    cm : Lc.LclOut <- scn.run(30, "chmod", ["+x", dst])
    IO.pure(Unit, Unit{})

# the sandbox: the links, the box, the stub's state, STAGES
def scn.setup(+c: ScnCx, s: Scn) -> IO(Unit):
  match s:
    case Scn{i, a, +stages, plans, +simenv, vast, e, cm, sp, ex}:
      +d = scn.d(c)
      +ft = scn.ft(c)
      do IO<Unit>:
        S.rm(d)
        S.mkdir(d ++ "/bin")
        S.mkdir(scn.box(c) ++ "/bin")
        S.mkdir(ft ++ "/out")
        S.mkdir(ft ++ "/run/eval")
        S.mkdir(d ++ "/vast")
        S.mkdir(d ++ "/home")
        S.mkdir(scn.dest(c))
        scn.links(scn.sim(c), d ++ "/bin", ["ssh", "rsync", "notify-send", "vastai"])
        scn.links(scn.sim(c), scn.box(c) ++ "/bin", ["nvidia-smi", "pgrep", "pkill"])
        scn.links(scn.sim(c), ft, ["traind", "traind-next", "dense"])
        scn.links(scn.bbox(c), ft, ["bend-box"])
        scn.copy.live(scn.repo(c) ++ "/bend/gpu/fp.sh", ft ++ "/fp.sh")
        scn.copy.live(scn.repo(c) ++ "/bend/gpu/fp-chain.sh", d ++ "/old-fp-chain.sh")
        scn.copy.live(scn.repo(c) ++ "/bend/gpu/credit-watch.sh", d ++ "/old-credit-watch.sh")
        scn.plans(ft, plans, 1n)
        S.write(ft ++ "/run/eval/transcript-fp.corpus", S.b("sim\n"))
        S.write(ft ++ "/run/eval/transcript-next.corpus", S.b("sim\n"))
        S.write(scn.box(c) ++ "/.sim-env", S.b(scn.lines(scn.simenv(c, simenv))))
        S.write(d ++ "/vast/instances", S.b("4242 running\n"))
        S.write(d ++ "/vast/credit", S.b("10.0\n"))
        scn.marks(d ++ "/vast", vast)
        S.write(d ++ "/stages", S.b(stages))

# the first stage's trainer, as fp.sh run starts it (OUT=out/s1, train.log)
def scn.stage1(+c: ScnCx, +simenv: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    pid : String <- S.background.setsid(scn.ft(c), scn.l1(List.append(&2, String, ["SIM_BOX=" ++ scn.box(c), "PLAN=run/sim/S1/plan-sim.tsv",
      "OUT=out/s1", "SAVE_EVERY=5"], scn.simenv(c, simenv))), "train.log", False{}, "./traind", ["--gpu", "48GB"])
    scn.say(c, "stage s1's trainer started (pid " ++ pid ++ ")")

def scn.chain.argv(+c: ScnCx) -> List<&2, String>:
  Bool.pick(List<&2, String>, scn.old(c), ["bash", scn.d(c) ++ "/old-fp-chain.sh", scn.host(c), "2222", "4242", "dest", "stages"],
    [scn.self(c), "chain", scn.host(c), "2222", "4242", "dest", "stages"])

def scn.watch.argv(+c: ScnCx) -> List<&2, String>:
  Bool.pick(List<&2, String>, scn.old(c), ["bash", scn.d(c) ++ "/old-credit-watch.sh", scn.host(c), "2222", "dest", "1.00"],
    [scn.self(c), "watch", scn.host(c), "2222", "dest", "1.00"])

# the pattern pkill -f finds a run's chain or watch by (anchored: never the
# sim-rc that waits on it, nor another sandbox's)
def scn.pat(+c: ScnCx, +watch: Bool) -> String:
  Bool.pick(String, scn.old(c),
    "^bash " ++ scn.d(c) ++ "/old-" ++ Bool.pick(String, watch, "credit-watch.sh", "fp-chain.sh") ++ " " ++ scn.host(c) ++ " ",
    "^" ++ scn.self(c) ++ Bool.pick(String, watch, " watch ", " chain ") ++ scn.host(c) ++ " ")

# PROG in the background, through bend-sim's sim-rc: D/NAME.rc and D/NAME.out at its end
def scn.launch(+c: ScnCx, +name: String, +argv: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    S.rm(scn.d(c) ++ "/" ++ name ++ ".rc")
    pid : String <- S.background.setsid(scn.d(c), scn.l1(scn.env(c)), scn.d(c) ++ "/" ++ name ++ ".launch", False{}, scn.sim(c),
      scn.l1(List.append(&2, String, ["sim-rc", scn.d(c) ++ "/" ++ name ++ ".rc", scn.d(c) ++ "/" ++ name ++ ".out"], argv)))
    scn.say(c, name ++ " started: " ++ String.join(argv, " "))

def scn.kill(+c: ScnCx, +watch: Bool) -> IO(Unit):
  do IO<Unit>:
    o : Lc.LclOut <- scn.run(30, "pkill", ["-KILL", "-f", "--", scn.pat(c, watch)])
    scn.say(c, Bool.pick(String, watch, "watch", "chain") ++ " killed (SIGKILL)")

# Steps -----------------------------------------------------------------------------------------------

def scn.trig.hit(tr: ScnTrig, +c: ScnCx) -> IO(Bool):
  match tr:
    case TrNow{}:
      IO.pure(Bool, True{})
    case TrLog{+t}:
      do IO<Bool>:
        xs : List<&2, U32> <- S.read(scn.dest(c) ++ "/chain.log")
        return S.infix(xs, S.b(t))
    case TrBox{+r}:
      S.exists(scn.ft(c) ++ "/" ++ r)
    case TrSleep{+ms}:
      do IO<Bool>:
        scn.sleep(ms)
        return True{}

type ScnW is Data:
  ScnW{hit: Bool}

def scn.trig.rest(hit: Bool) -> IO(ScnW):
  match hit:
    case True{}:
      IO.pure(ScnW, ScnW{True{}})
    case False{}:
      do IO<ScnW>:
        IO.sleep(200)
        return ScnW{False{}}

def scn.trig.step(+tr: ScnTrig, +c: ScnCx) -> IO(ScnW):
  do IO<ScnW>:
    h : Bool <- scn.trig.hit(tr, c)
    scn.trig.rest(h)

def scn.trig.go(fuel: Nat, +tr: ScnTrig, +c: ScnCx, w: ScnW) -> IO(Bool):
  match fuel w:
    case _ ScnW{True{}}:
      IO.pure(Bool, True{})
    case 0n ScnW{False{}}:
      IO.pure(Bool, False{})
    case 1n+f ScnW{False{}}:
      IO.bind(ScnW, Bool, scn.trig.step(tr, c), scn.trig.go(f, tr, c))

def scn.trig.show(+tr: ScnTrig) -> String:
  match tr:
    case TrNow{}:
      "now"
    case TrLog{t}:
      "chain.log has `" ++ t ++ "`"
    case TrBox{r}:
      "the box has " ++ r
    case TrSleep{ms}:
      Nat.show(ms) ++ " ms later"

def scn.act(a: ScnAct, +c: ScnCx) -> IO(Unit):
  match a:
    case AcNone{}:
      IO.pure(Unit, Unit{})
    case AcAppend{+l}:
      do IO<Unit>:
        S.add(scn.d(c) ++ "/stages", S.b(l ++ "\n"))
        scn.say(c, "appended to STAGES: " ++ l)
    case AcBox{+r, +t}:
      do IO<Unit>:
        S.mkdir(S.parent(scn.ft(c) ++ "/" ++ r))
        S.write(scn.ft(c) ++ "/" ++ r, S.b(t))
        scn.say(c, "put on the box: " ++ r)
    case AcLink{down}:
      Bool.pick(IO(Unit), down, S.write(scn.box(c) ++ "/.link-down", Nil{}), S.rm(scn.box(c) ++ "/.link-down"))
    case AcRsync{down}:
      Bool.pick(IO(Unit), down, S.write(scn.box(c) ++ "/.rsync-down", Nil{}), S.rm(scn.box(c) ++ "/.rsync-down"))
    case AcCorrupt{+n}:
      do IO<Unit>:
        xs : List<&2, U32> <- S.read(scn.dest(c) ++ "/out/" ++ n)
        S.write(scn.dest(c) ++ "/out/" ++ n, List.replicate(U32, S.len(xs), 88))
        scn.say(c, "corrupted dest/out/" ++ n)
    case AcHold{+secs}:
      do IO<Unit>:
        +now : Nat <- Lc.lcl.now()
        S.write(scn.dest(c) ++ "/HOLD", S.b(Nat.show(Nat.add(now, secs)) ++ "\n"))
    case AcFile{+r, +t}:
      S.write(scn.d(c) ++ "/" ++ r, S.b(t))
    case AcCredit{+t}:
      S.write(scn.d(c) ++ "/vast/credit", S.b(t ++ "\n"))
    case AcKill{}:
      scn.kill(c, False{})
    case AcStart{}:
      scn.launch(c, "chain", scn.chain.argv(c))

def scn.step.done(hit: Bool, a: ScnAct, +c: ScnCx, +what: String) -> IO(List<&2, String>):
  match hit:
    case True{}:
      do IO<List<&2, String>>:
        scn.act(a, c)
        return Nil{}
    case False{}:
      do IO<List<&2, String>>:
        scn.say(c, "a step's trigger never came: " ++ what)
        return ["the trigger never came: " ++ what]

def scn.step(st: ScnStep, +c: ScnCx) -> IO(List<&2, String>):
  match st:
    case ScnStep{+tr, a}:
      do IO<List<&2, String>>:
        hit : Bool <- scn.trig.go(U32.to_nat(6000), tr, c, ScnW{False{}})
        scn.step.done(hit, a, c, scn.trig.show(tr))

def scn.steps(ss: List<&2, ScnStep>, +c: ScnCx) -> IO(List<&2, String>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case s <> t:
      do IO<List<&2, String>>:
        a : List<&2, String> <- scn.step(s, c)
        b : List<&2, String> <- scn.steps(t, c)
        return List.append(&2, String, a, b)

def scn.wait.step(+path: String) -> IO(ScnW):
  do IO<ScnW>:
    h : Bool <- S.exists(path)
    scn.trig.rest(h)

# wait (200 ms polls) for a file, FUEL polls at most
def scn.wait.go(fuel: Nat, +path: String, w: ScnW) -> IO(Bool):
  match fuel w:
    case _ ScnW{True{}}:
      IO.pure(Bool, True{})
    case 0n ScnW{False{}}:
      IO.pure(Bool, False{})
    case 1n+f ScnW{False{}}:
      IO.bind(ScnW, Bool, scn.wait.step(path), scn.wait.go(f, path))

def scn.wait(+path: String, +secs: Nat) -> IO(Bool):
  scn.wait.go(Nat.mul(secs, 5n), path, ScnW{False{}})

# The expectations ------------------------------------------------------------------------------------

type ScnRes is Data:
  ScnRes{name: String, ok: Bool, detail: String}

def scn.same(+a: Bool, +b: Bool) -> Bool:
  Bool.not(Bool.xor(a, b))

def scn.ckpts(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = scn.ckpts(t)
      Bool.pick(List<&2, String>, S.suffix(x, S.b(".checkpoint")), S.str(x) <> rest, rest)

def scn.strs.eq(xs: List<&2, String>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(String.eq(x, y), scn.strs.eq(xt, yt))
    case _ _:
      False{}

# the checkpoints in DIR, sorted bytewise
def scn.listing(+dir: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(dir)
    return scn.ckpts(Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{}))

def scn.files.res(+what: String, +want: List<&2, String>, +got: List<&2, String>) -> ScnRes:
  ScnRes{what ++ " holds " ++ String.join(want, " "), scn.strs.eq(want, got), "it holds " ++ String.join(got, " ")}

def scn.exp(e: ScnExp, +c: ScnCx) -> IO(ScnRes):
  match e:
    case ExMark{+n, +there}:
      do IO<ScnRes>:
        h : Bool <- S.exists(scn.dest(c) ++ "/" ++ n)
        return ScnRes{"DEST/" ++ n ++ Bool.pick(String, there, " written", " not written"), scn.same(h, there), ""}
    case ExMarkHas{+n, +t}:
      do IO<ScnRes>:
        +xs : List<&2, U32> <- S.read(scn.dest(c) ++ "/" ++ n)
        return ScnRes{"DEST/" ++ n ++ " says `" ++ t ++ "`", S.infix(xs, S.b(t)), "it says: " ++ S.str(S.chomp(xs))}
    case ExRc{+code}:
      do IO<ScnRes>:
        +xs : List<&2, U32> <- S.read(scn.d(c) ++ "/chain.rc")
        return ScnRes{"the chain's exit status is " ++ code, String.eq(S.str(S.chomp(xs)), code), "it is " ++ S.str(S.chomp(xs))}
    case ExLog{+t, +there}:
      do IO<ScnRes>:
        xs : List<&2, U32> <- S.read(scn.dest(c) ++ "/chain.log")
        return ScnRes{Bool.pick(String, there, "chain.log has `", "chain.log has no `") ++ S.str(S.chomp(S.b(t))) ++ "`", scn.same(S.infix(xs, S.b(t)), there), ""}
    case ExOut{+ns}:
      do IO<ScnRes>:
        +got : List<&2, String> <- scn.listing(scn.dest(c) ++ "/out")
        return scn.files.res("DEST/out", ns, got)
    case ExBox{+ns}:
      do IO<ScnRes>:
        +got : List<&2, String> <- scn.listing(scn.ft(c) ++ "/out")
        return scn.files.res("the box's out/", ns, got)
    case ExStarts{+n}:
      do IO<ScnRes>:
        xs : List<&2, U32> <- S.read(scn.box(c) ++ "/.sim-starts")
        +k : Nat = List.length(&2, List<&2, U32>, S.split.lines(xs))
        return ScnRes{"trainers started: " ++ Nat.show(n), Nat.is_eq(k, n), "started: " ++ Nat.show(k)}
    case ExAlert{+t}:
      do IO<ScnRes>:
        xs : List<&2, U32> <- S.read(scn.d(c) ++ "/alerts")
        return ScnRes{"a desktop alert says `" ++ t ++ "`", S.infix(xs, S.b(t)), ""}
    case ExListed{+there}:
      do IO<ScnRes>:
        xs : List<&2, U32> <- S.read(scn.d(c) ++ "/vast/instances")
        return ScnRes{"instance 4242 " ++ Bool.pick(String, there, "still listed", "no longer listed"), scn.same(S.infix(xs, S.b("4242")), there), ""}
    case ExBoxFile{+r}:
      do IO<ScnRes>:
        h : Bool <- S.exists(scn.ft(c) ++ "/" ++ r)
        return ScnRes{"the box has " ++ r, h, ""}

def scn.exps(es: List<&2, ScnExp>, +c: ScnCx) -> IO(List<&2, ScnRes>):
  match es:
    case Nil{}:
      IO.pure(List<&2, ScnRes>, Nil{})
    case e <> t:
      do IO<List<&2, ScnRes>>:
        r : ScnRes <- scn.exp(e, c)
        rs : List<&2, ScnRes> <- scn.exps(t, c)
        return r <> rs

# Old against new --------------------------------------------------------------------------------------

def scn.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

# "[YYYY-MM-DD HH:MM:SS" (20 bytes), a stamp before " UTC-6] "
def scn.stamp.head(+x: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Nat.is_eq(S.len(x), 20n), U32.is_eq(Lc.lcl.at(x, 0n), 91)),
    Bool.and(Bool.and(U32.is_eq(Lc.lcl.at(x, 5n), 45), U32.is_eq(Lc.lcl.at(x, 8n), 45)),
      Bool.and(Bool.and(U32.is_eq(Lc.lcl.at(x, 11n), 32), U32.is_eq(Lc.lcl.at(x, 14n), 58)), Bool.and(U32.is_eq(Lc.lcl.at(x, 17n), 58), scn.digit(Lc.lcl.at(x, 19n))))))

# a piece followed by " UTC-6] ": without its stamp head, or with the separator back
def scn.unstamp.piece(+p: List<&2, U32>) -> List<&2, U32>:
  +n = S.len(p)
  Bool.pick(List<&2, U32>, Bool.and(Nat.is_le(20n, n), scn.stamp.head(List.drop(&2, U32, p, Nat.sub(n, 20n)))), List.take(&2, U32, p, Nat.sub(n, 20n)),
    List.append(&2, U32, p, S.b(" UTC-6] ")))

def scn.unstamp.join(ps: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> Nil{}:
      p
    case +p <> t:
      List.append(&2, U32, scn.unstamp.piece(p), scn.unstamp.join(t))

# a line without the UTC-6 stamps in it
def scn.unstamp(+l: List<&2, U32>) -> List<&2, U32>:
  scn.unstamp.join(S.split.str(l, S.b(" UTC-6] ")))

# an event line: not a per-poll line, not `ssh failed; retrying`, not empty
def scn.event(+l: List<&2, U32>) -> Bool:
  Bool.not(Bool.or(Bool.or(Bool.and(S.infix(l, S.b(" trainer(s); ")), S.infix(l, S.b(" bytes, "))), S.eq(l, S.b("ssh failed; retrying"))),
    Nat.is_eq(S.len(l), 0n)))

# `trainer pid N; ...` with the pid masked
def scn.mask(+l: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.prefix(l, S.b("trainer pid ")),
    List.append(&2, U32, S.b("trainer pid *"), List.drop(&2, U32, l, Maybe.default(&2, Nat, S.find(l, [59], 0n), S.len(l)))), l)

def scn.events.go(ls: List<&2, List<&2, U32>>, +watch: Bool) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case l0 <> t:
      +l = scn.mask(scn.unstamp(l0))
      +rest = scn.events.go(t, watch)
      Bool.pick(List<&2, String>, Bool.and(scn.event(l), scn.same(S.prefix(l, S.b("credit-watch: ")), watch)), S.str(l) <> rest, rest)

# chain.log's event lines, the chain's (watch False) or the watch's
def scn.events(+xs: List<&2, U32>, +watch: Bool) -> List<&2, String>:
  scn.events.go(S.split.lines(xs), watch)

def scn.drop1(xs: List<&2, String>, +x: String) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +y <> +t:
      Bool.pick(List<&2, String>, String.eq(x, y), t, y <> scn.drop1(t, x))

def scn.has(xs: List<&2, String>, +x: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case y <> t:
      Bool.or(String.eq(x, y), scn.has(t, x))

# is the head of XS in YS
def scn.has.head(+ys: List<&2, String>, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      scn.has(ys, x)

def scn.minus.go(xs: List<&2, String>, +ys: List<&2, String>, hit: Bool) -> List<&2, String>:
  match xs hit:
    case Nil{} _:
      Nil{}
    case +x <> +t True{}:
      +ys2 = scn.drop1(ys, x)
      scn.minus.go(t, ys2, scn.has.head(ys2, t))
    case +x <> +t False{}:
      x <> scn.minus.go(t, ys, scn.has.head(ys, t))

# the lines of A not in B (as multisets)
def scn.minus(+xs: List<&2, String>, +ys: List<&2, String>) -> List<&2, String>:
  scn.minus.go(xs, ys, scn.has.head(ys, xs))

def scn.join.bar(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      "`" ++ x ++ "`"
    case x <> t:
      "`" ++ x ++ "` | " ++ scn.join.bar(t)

def scn.cmp.lines(+what: String, +a: List<&2, String>, +b: List<&2, String>) -> ScnRes:
  +na = scn.minus(a, b)
  +nb = scn.minus(b, a)
  ScnRes{what ++ " (" ++ Nat.show(List.length(&2, String, a)) ++ " new, " ++ Nat.show(List.length(&2, String, b)) ++ " old)", scn.strs.eq(a, b),
    Bool.pick(String, Bool.and(List.is_empty(&2, String, na), List.is_empty(&2, String, nb)), "the same lines in another order",
      "only new: " ++ scn.join.bar(na) ++ "; only old: " ++ scn.join.bar(nb))}

def scn.unstamp.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      scn.unstamp(l) <> scn.unstamp.lines(t)

# a marker's text, its stamps taken out (old markers had none, or `date`'s)
def scn.mark.text(+xs: List<&2, U32>) -> String:
  S.str(S.chomp(S.join(scn.unstamp.lines(S.split.lines(xs)), 10)))

def scn.cmp.mark(+cn: ScnCx, +co: ScnCx, +name: String, +text: Bool) -> IO(ScnRes):
  do IO<ScnRes>:
    +hn : Bool <- S.exists(scn.dest(cn) ++ "/" ++ name)
    +ho : Bool <- S.exists(scn.dest(co) ++ "/" ++ name)
    xn : List<&2, U32> <- S.read(scn.dest(cn) ++ "/" ++ name)
    xo : List<&2, U32> <- S.read(scn.dest(co) ++ "/" ++ name)
    +tn : String = scn.mark.text(xn)
    +to : String = scn.mark.text(xo)
    return ScnRes{"DEST/" ++ name ++ Bool.pick(String, text, ": in both or neither, the same text (stamps out)", ": in both or neither"), Bool.and(scn.same(hn, ho), Bool.or(Bool.not(text), String.eq(tn, to))),
      "new: " ++ Bool.pick(String, hn, "`" ++ tn ++ "`", "absent") ++ ", old: " ++ Bool.pick(String, ho, "`" ++ to ++ "`", "absent")}

def scn.bytes(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.b(x) <> scn.bytes(t)

def scn.sums(+dir: String) -> IO(String):
  do IO<String>:
    ns : List<&2, String> <- scn.listing(dir)
    ss : List<&2, Lc.LclSum> <- Lc.lcl.sums(dir, scn.bytes(ns))
    return S.str(Lc.lcl.sha.text(ss))

def scn.cmp.files(+what: String, +a: String, +b: String) -> IO(ScnRes):
  do IO<ScnRes>:
    +x : String <- scn.sums(a)
    +y : String <- scn.sums(b)
    return ScnRes{what ++ ": the same names and sha256", String.eq(x, y), "new:\n" ++ x ++ "old:\n" ++ y}

def scn.write.events(+c: ScnCx, +xs: List<&2, String>, +ws: List<&2, String>) -> IO(Unit):
  S.write(scn.d(c) ++ "/events.txt", S.b(scn.lines(xs) ++ "-- credit-watch --\n" ++ scn.lines(ws)))

# old against new: the event lines, the markers, DEST/out and the box's out/
def scn.compare(+cn: ScnCx, +co: ScnCx) -> IO(List<&2, ScnRes>):
  do IO<List<&2, ScnRes>>:
    +ln : List<&2, U32> <- S.read(scn.dest(cn) ++ "/chain.log")
    +lo : List<&2, U32> <- S.read(scn.dest(co) ++ "/chain.log")
    +en : List<&2, String> = scn.events(ln, False{})
    +eo : List<&2, String> = scn.events(lo, False{})
    +wn : List<&2, String> = scn.events(ln, True{})
    +wo : List<&2, String> = scn.events(lo, True{})
    scn.write.events(cn, en, wn)
    scn.write.events(co, eo, wo)
    m1 : ScnRes <- scn.cmp.mark(cn, co, "DESTROYED", False{})
    m2 : ScnRes <- scn.cmp.mark(cn, co, "REFUSED", True{})
    m3 : ScnRes <- scn.cmp.mark(cn, co, "DIED", True{})
    m4 : ScnRes <- scn.cmp.mark(cn, co, "CREDIT_LOW", False{})
    m5 : ScnRes <- scn.cmp.mark(cn, co, "CONTINUED", False{})
    m6 : ScnRes <- scn.cmp.mark(cn, co, "INSTANCE", True{})
    f1 : ScnRes <- scn.cmp.files("DEST/out", scn.dest(cn) ++ "/out", scn.dest(co) ++ "/out")
    f2 : ScnRes <- scn.cmp.files("the box's out/", scn.ft(cn) ++ "/out", scn.ft(co) ++ "/out")
    return [scn.cmp.lines("old = new: chain.log's event lines", en, eo), scn.cmp.lines("old = new: the watch's lines", wn, wo), m1, m2, m3, m4, m5, m6, f1, f2]

# Running a scenario ------------------------------------------------------------------------------------

# what the runs need: this binary, bend-sim, the repository, PATH, the real
# rsync, bend-corpus-v2 (the old watch's CV2)
type ScnTools is Data:
  ScnTools{self: String, sim: String, box: String, repo: String, path: String, rsync: String, cv2: String}

def scn.cx(+t: ScnTools, +d: String, +tag: String, +old: Bool, +drv: String, +extra: List<&2, String>) -> ScnCx:
  match t:
    case ScnTools{+self, +sim, +bbox, +repo, +path, +rsync, +cv2}:
      ScnCx{d, tag, old, self, sim, repo,
        List.append(&2, String, ["PATH=" ++ d ++ "/bin:" ++ path, "HOME=" ++ d ++ "/home", "SIM_BOX_HOME=" ++ d ++ "/box", "SIM_BOX_PATH=" ++ path,
          "SIM_RSYNC=" ++ rsync, "SIM_VAST_DIR=" ++ d ++ "/vast", "SIM_ALERTS=" ++ d ++ "/alerts", "V=" ++ d ++ "/bin/vastai", "CV2=" ++ cv2,
          "ALERT_CMD=", "BOX_DRIVER=" ++ drv, "BOX_DIR=ana", "LOG0=train.log", "EXTRA_EVAL=", "POLL=1", "WAIT=8", "WAIT_POLL=1",
          "START_SETTLE=1", "SETTLE=1", "PULL_WAIT=1", "VERIFY_WAIT=2", "SSH_TRIES=10", "SSH_RETRY_SLEEP=1", "RSYNC_TRIES=10", "DESTROY_WAIT=1",
          "LIST_TRIES=3", "LIST_WAIT=1", "HOLD_POLL=1", "DEAD_QUIET=6", "EVAL_QUIET=30", "WATCH_POLL=1", "GRACE=3600", "LOW_WAIT=3600",
          "SILENT=36000", "SSH_OPTS="], extra), "root@sim-" ++ tag, bbox}

def scn.quiet.kill(+c: ScnCx, +pat: String) -> IO(Unit):
  do IO<Unit>:
    o : Lc.LclOut <- scn.run(30, "pkill", ["-KILL", "-f", "--", pat])
    return Unit{}

def scn.box.kill(+c: ScnCx, names: List<&2, String>) -> IO(Unit):
  match names:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        path : String <- S.env("PATH", "")
        o : Lc.LclOut <- scn.run(30, "env", ["SIM_BOX=" ++ scn.box(c), "SIM_BOX_PATH=" ++ path, scn.sim(c), "pkill", "-KILL", "-x", n])
        scn.box.kill(c, t)

# everything a run started: its chain, its watch, the box's trainers and eval jobs
def scn.cleanup(+c: ScnCx) -> IO(Unit):
  do IO<Unit>:
    scn.quiet.kill(c, scn.pat(c, False{}))
    scn.quiet.kill(c, scn.pat(c, True{}))
    scn.box.kill(c, ["traind", "traind-next", "bend-box"])

def scn.fails(xs: List<&2, String>) -> List<&2, ScnRes>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      ScnRes{"a step: " ++ x, False{}, ""} <> scn.fails(t)

def scn.tagged(+tag: String, rs: List<&2, ScnRes>) -> List<&2, ScnRes>:
  match rs:
    case Nil{}:
      Nil{}
    case ScnRes{n, o, d} <> t:
      ScnRes{tag ++ ": " ++ n, o, d} <> scn.tagged(tag, t)

def scn.setup.of(+c: ScnCx, s: Scn) -> IO(Unit):
  scn.setup(c, s)

def scn.run.one(+c: ScnCx, s: Scn) -> IO(List<&2, ScnRes>):
  match s:
    case Scn{+i, +a, +st, +pl, +se, +v, +e, +cm, +sp, +ex}:
      do IO<List<&2, ScnRes>>:
        scn.say(c, "scenario " ++ i ++ ": " ++ a)
        scn.setup(c, Scn{i, a, st, pl, se, v, e, cm, sp, ex})
        scn.stage1(c, se)
        scn.launch(c, "watch", scn.watch.argv(c))
        scn.launch(c, "chain", scn.chain.argv(c))
        fails : List<&2, String> <- scn.steps(sp, c)
        +ended : Bool <- scn.wait(scn.d(c) ++ "/chain.rc", Bool.pick(Nat, scn.old(c), U32.to_nat(2400), U32.to_nat(900)))
        gone : Bool <- S.exists(scn.dest(c) ++ "/DESTROYED")
        w : Bool <- Bool.pick(IO(Bool), gone, scn.wait(scn.d(c) ++ "/watch.rc", 20n), IO.pure(Bool, True{}))
        scn.cleanup(c)
        rs : List<&2, ScnRes> <- Bool.pick(IO(List<&2, ScnRes>), scn.old(c), IO.pure(List<&2, ScnRes>, Nil{}), scn.exps(ex, c))
        scn.say(c, "done")
        return scn.tagged(scn.tag(c), List.concat(&2, ScnRes, [[ScnRes{"the chain ended by itself", ended, ""}], scn.fails(fails), rs]))

def scn.s.id(+s: Scn) -> String:
  match s:
    case Scn{i, a, st, pl, se, v, e, cm, sp, ex}:
      i

def scn.s.env(+s: Scn) -> List<&2, String>:
  match s:
    case Scn{i, a, st, pl, se, v, e, cm, sp, ex}:
      e

def scn.s.compare(+s: Scn) -> Bool:
  match s:
    case Scn{i, a, st, pl, se, v, e, cm, sp, ex}:
      cm

# a scenario's runs: the new chain with BOX_DRIVER ./bend-box (sN-box); when
# compared, also with ./fp.sh (sN-fp) and the old scripts (sN-old, at the
# same time), each new run then compared with the old
def scn.one(+t: ScnTools, +base: String, +s: Scn) -> IO(List<&2, ScnRes>):
  +i = scn.s.id(s)
  +cm = scn.s.compare(s)
  +cb = scn.cx(t, base ++ "/s" ++ i ++ "-box", "s" ++ i ++ "-box", False{}, "./bend-box", scn.s.env(s))
  +cf = scn.cx(t, base ++ "/s" ++ i ++ "-fp", "s" ++ i ++ "-fp", False{}, "./fp.sh", scn.s.env(s))
  +co = scn.cx(t, base ++ "/s" ++ i ++ "-old", "s" ++ i ++ "-old", True{}, "./fp.sh", scn.s.env(s))
  do IO<List<&2, ScnRes>>:
    ch : Chan(List<&2, ScnRes>) <- IO.fork(List<&2, ScnRes>, Bool.pick(IO(List<&2, ScnRes>), cm, scn.run.one(co, s), IO.pure(List<&2, ScnRes>, Nil{})))
    rb : List<&2, ScnRes> <- scn.run.one(cb, s)
    rf : List<&2, ScnRes> <- Bool.pick(IO(List<&2, ScnRes>), cm, scn.run.one(cf, s), IO.pure(List<&2, ScnRes>, Nil{}))
    ro : List<&2, ScnRes> <- IO.join(List<&2, ScnRes>, ch)
    c1 : List<&2, ScnRes> <- Bool.pick(IO(List<&2, ScnRes>), cm, scn.compare(cf, co), IO.pure(List<&2, ScnRes>, Nil{}))
    c2 : List<&2, ScnRes> <- Bool.pick(IO(List<&2, ScnRes>), cm, scn.compare(cb, co), IO.pure(List<&2, ScnRes>, Nil{}))
    return List.concat(&2, ScnRes, [rb, rf, ro, scn.tagged("s" ++ i ++ " fp.sh", c1), scn.tagged("s" ++ i ++ " bend-box", c2)])

def scn.many(+t: ScnTools, +base: String, ss: List<&2, Scn>) -> IO(List<&2, ScnRes>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, ScnRes>, Nil{})
    case s <> rest:
      do IO<List<&2, ScnRes>>:
        a : List<&2, ScnRes> <- scn.one(t, base, s)
        b : List<&2, ScnRes> <- scn.many(t, base, rest)
        return List.append(&2, ScnRes, a, b)

def scn.report(rs: List<&2, ScnRes>, +bad: Nat) -> IO(Unit):
  match rs:
    case Nil{}:
      Bool.pick(IO(Unit), Nat.is_eq(bad, 0n), IO.print("sim: every check passed"), IO.die(Unit, 1, "sim: " ++ Nat.show(bad) ++ " check(s) failed"))
    case ScnRes{+n, +ok, +d} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n ++ Bool.pick(String, Bool.or(ok, String.is_empty(d)), "", " -- " ++ d))
        scn.report(t, Bool.pick(Nat, ok, bad, 1n+bad))

# The soak ----------------------------------------------------------------------------------------------

def scn.rss.lines(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      Bool.pick(Nat, S.prefix(l, S.b("VmRSS:")), Maybe.default(&2, Nat, Lc.lcl.nat(Lc.lcl.nth(Lc.lcl.words(l), 1n)), 0n), scn.rss.lines(t))

# /proc/PID/status's VmRSS, in kB (0: none)
def scn.rss.of(+xs: List<&2, U32>) -> Nat:
  scn.rss.lines(S.split.lines(xs))

def scn.count.has(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      Nat.add(Bool.pick(Nat, S.infix(l, p), 1n, 0n), scn.count.has(t, p))

type ScnSoak is Data:
  ScnSoak{t: Nat, rss: List<&2, Nat>}

def scn.soak.step(+c: ScnCx, +t0: Nat, +rs: List<&2, Nat>) -> IO(ScnSoak):
  do IO<ScnSoak>:
    IO.sleep(60000)
    +o : Lc.LclOut <- scn.run(30, "pgrep", ["-o", "-f", "--", scn.pat(c, False{})])
    +pid : String = S.str(Lc.lcl.nth(Lc.lcl.words(Lc.lcl.out(o)), 0n))
    st : List<&2, U32> <- S.read("/proc/" ++ pid ++ "/status")
    +rss : Nat = scn.rss.of(st)
    lg : List<&2, U32> <- S.read(scn.dest(c) ++ "/chain.log")
    +now : Nat <- Lc.lcl.now()
    +polls : Nat = scn.count.has(S.split.lines(lg), S.b(" trainer(s); "))
    +line : String = Nat.show(Nat.sub(now, t0)) ++ "\t" ++ pid ++ "\t" ++ Nat.show(rss) ++ "\t" ++ Nat.show(polls)
    S.add(scn.d(c) ++ "/soak.tsv", S.b(line ++ "\n"))
    scn.say(c, "soak: t=" ++ Nat.show(Nat.sub(now, t0)) ++ " s, chain pid " ++ pid ++ ", VmRSS " ++ Nat.show(rss) ++ " kB, " ++ Nat.show(polls) ++ " polls logged")
    return ScnSoak{1n+List.length(&2, Nat, rs), List.append(&2, Nat, rs, [rss])}

def scn.soak.go(fuel: Nat, +c: ScnCx, +t0: Nat, s: ScnSoak) -> IO(List<&2, Nat>):
  match fuel s:
    case 0n ScnSoak{k, rs}:
      IO.pure(List<&2, Nat>, rs)
    case 1n+f ScnSoak{k, +rs}:
      IO.bind(ScnSoak, List<&2, Nat>, scn.soak.step(c, t0, rs), scn.soak.go(f, c, t0))

def scn.sum(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> t:
      Nat.add(x, scn.sum(t))

def scn.avg(+xs: List<&2, Nat>) -> Nat:
  Nat.div(scn.sum(xs), Nat.max(List.length(&2, Nat, xs), 1n))

def scn.nats(xs: List<&2, Nat>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      " " ++ Nat.show(x) ++ scn.nats(t)

# bounded: the last third's mean within a quarter (and 2 MB) of the first third's
def scn.soak.verdict(+rs: List<&2, Nat>) -> ScnRes:
  +n = List.length(&2, Nat, rs)
  +k = Nat.max(Nat.div(n, 3n), 1n)
  +a = scn.avg(List.take(&2, Nat, rs, k))
  +b = scn.avg(List.drop(&2, Nat, rs, Nat.sub(n, k)))
  ScnRes{"soak: VmRSS bounded (first third's mean " ++ Nat.show(a) ++ " kB, last third's " ++ Nat.show(b) ++ " kB; samples:" ++ scn.nats(rs) ++ ")",
    Bool.and(Nat.is_lt(1n, n), Nat.is_le(b, Nat.add(Nat.add(a, Nat.div(a, 4n)), U32.to_nat(2048)))), ""}

def scn.soak(+t: ScnTools, +base: String, +secs: Nat) -> IO(Unit):
  +s = {Scn{"soak", "the chain at POLL=1 against a trainer of a step a second for " ++ Nat.show(secs) ++ " s: its VmRSS every 60 s",
    "s1 traind 300\n", ["1000000", "", ""], ["SIM_SLEEP_MS=1000", "SIM_SAVE_EVERY=60"], Nil{}, ["POLL=1"], False{}, Nil{}, Nil{}} : Scn}
  +c = scn.cx(t, base ++ "/soak", "soak", False{}, "./bend-box", ["POLL=1"])
  do IO<Unit>:
    scn.setup(c, s)
    scn.stage1(c, ["SIM_SLEEP_MS=1000", "SIM_SAVE_EVERY=60"])
    scn.launch(c, "chain", scn.chain.argv(c))
    +t0 : Nat <- Lc.lcl.now()
    S.write(scn.d(c) ++ "/soak.tsv", S.b("seconds\tpid\tvmrss_kb\tpolls\n"))
    rs : List<&2, Nat> <- scn.soak.go(Nat.div(secs, 60n), c, t0, ScnSoak{0n, Nil{}})
    scn.cleanup(c)
    scn.report([scn.soak.verdict(rs)], 0n)

# The command -------------------------------------------------------------------------------------------

def scn.usage() -> String:
  "usage: bend-ops sim N DIR | sim all DIR | sim soak DIR SECONDS   (N: 1..10; BEND_SIM, BEND_BOX, SIM_REPO, SIM_CV2)"

def scn.need(m: Maybe<&2, String>, +what: String) -> IO(String):
  match m:
    case Some{p}:
      IO.pure(String, p)
    case None{}:
      IO.die(String, 2, "sim: no " ++ what ++ " on $PATH")

def scn.or.which(+given: String, +name: String) -> IO(String):
  Bool.pick(IO(String), String.is_empty(given), IO.bind(Maybe<&2, String>, String, S.which(name), (m => scn.need(m, name))), IO.pure(String, given))

def scn.opt.which(+given: String, +name: String) -> IO(String):
  Bool.pick(IO(String), String.is_empty(given), IO.bind(Maybe<&2, String>, String, S.which(name), (m => IO.pure(String, Maybe.default(&2, String, m, "")))), IO.pure(String, given))

def scn.tools(+argv0: String) -> IO(ScnTools):
  do IO<ScnTools>:
    self : String <- S.realpath(argv0)
    sim0 : String <- S.env("BEND_SIM", "")
    sim1 : String <- scn.or.which(sim0, "bend-sim")
    sim : String <- S.realpath(sim1)
    box0 : String <- S.env("BEND_BOX", "")
    box1 : String <- scn.or.which(box0, "bend-box")
    box : String <- S.realpath(box1)
    repo0 : String <- S.env("SIM_REPO", ".")
    repo : String <- S.realpath(repo0)
    path : String <- S.env("PATH", "")
    rsync : String <- scn.or.which("", "rsync")
    cv20 : String <- S.env("SIM_CV2", "")
    cv2 : String <- scn.opt.which(cv20, "bend-corpus-v2")
    return ScnTools{self, sim, box, repo, path, rsync, cv2}

def scn.pick(m: Maybe<&2, Scn>, +id: String) -> IO(List<&2, Scn>):
  match m:
    case Some{s}:
      IO.pure(List<&2, Scn>, [s])
    case None{}:
      IO.die(List<&2, Scn>, 2, "sim: no scenario " ++ id ++ "; " ++ scn.usage())

def scn.main(+argv0: String, xs: List<String>) -> IO(Unit):
  match xs:
    case "soak" <> +dir <> +secs <> Nil{}:
      do IO<Unit>:
        t : ScnTools <- scn.tools(argv0)
        S.mkdir(dir)
        base : String <- S.realpath(dir)
        scn.soak(t, base, Maybe.default(&2, Nat, Nat.read(secs), U32.to_nat(3600)))
    case "all" <> +dir <> Nil{}:
      do IO<Unit>:
        t : ScnTools <- scn.tools(argv0)
        S.mkdir(dir)
        base : String <- S.realpath(dir)
        rs : List<&2, ScnRes> <- scn.many(t, base, scn.all())
        scn.report(rs, 0n)
    case +id <> +dir <> Nil{}:
      do IO<Unit>:
        ss : List<&2, Scn> <- scn.pick(scn.find(scn.all(), id), id)
        t : ScnTools <- scn.tools(argv0)
        S.mkdir(dir)
        base : String <- S.realpath(dir)
        rs : List<&2, ScnRes> <- scn.many(t, base, ss)
        scn.report(rs, 0n)
    case _:
      IO.die(Unit, 2, scn.usage())
