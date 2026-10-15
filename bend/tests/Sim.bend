import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ../Box/Local.bend as Lc
import ./SimDrive.bend as Sd

# bend-sim: a box in a sandbox (2026-10-14, the plan's Phase 0), for testing
# bend-ops' chain, watch and stage against a local sshd without a GPU or
# money.  One binary; the name it is run by (argv[0]'s last component) picks
# its part, so a scratch directory of links stands in for the box's tools:
#
#   traind, traind-next   the dense trainer's log lines and saves (below)
#   dense                 the G2 gate's lines (gate.log's shape); SIM_GATE_BAD=1 puts one gradient out
#   nvidia-smi            --query-gpu, -q -d PERFORMANCE and dmon, as a 5090 answered on run 3's box
#   clang (clang-19, ..)  writes -o's file (executable) and nothing else; --version
#   vastai                show user --raw, show instances --raw, destroy instance N -y over a state
#                         directory SIM_VAST_DIR (~/.sim-vast): credit (a number; credits: one a
#                         line, each `show user` takes the first, the last stays; user.json
#                         replaces the whole answer), instances (a line an instance: ID [STATUS
#                         [SSH_HOST [SSH_PORT]]]), list.fail (the listing fails), destroy.noop
#                         (a destroy answers but does not take); every call is appended to calls
#
#   ssh                   (2026-10-14, Phase 1a) ssh's options read as ssh reads them; the
#                         command words after the host, joined by spaces as ssh sends them,
#                         run by `sh -c` in the box directory SIM_BOX_HOME with the box's
#                         environment (below); exit 255 while SIM_BOX_HOME/.link-down exists,
#                         and after running a command line that holds the text of
#                         SIM_BOX_HOME/.drop-after (a connection lost once its command ran)
#   rsync                 each HOST:PATH is SIM_BOX_HOME/PATH (an absolute PATH stays), the
#                         remote shell (-e X) is dropped and the real rsync (SIM_RSYNC) copies
#                         here; exit 255 while the link is down (or SIM_BOX_HOME/.rsync-down
#                         exists: a transfer that drops while ssh still answers) and a side
#                         is remote
#   sim-rc RC OUT PROG..  PROG run to its end: its stdout and stderr into OUT, its status into
#                         RC (a program started in the background keeps its exit status)
#   notify-send           its words appended to SIM_ALERTS ($HOME/.sim-alerts); nothing shown
#   pgrep, pkill          (on the box's PATH) the real tools (from SIM_BOX_PATH) limited to
#                         the processes whose environment holds SIM_BOX=<this box>, so boxes
#                         in other sandboxes, or the machine's own processes, are never seen
#                         or signalled: -c, -x, -f, -SIG and --signal SIG; -o (here: the lowest
#                         pid) and -s SID (2026-10-15, for bend-box act-stop)
#   systemd-run, systemctl, bend-corpus-v2, deploy, bend-episode
#                         with SIM_DRIVE set (2026-10-15, Phase 4b): the run drivers' sandbox's
#                         (bend/tests/SimDrive.bend), before any part of the same name here
#
#   bend-sim links DIR    those names in DIR, linked to this binary
#   bend-sim ROLE ARGS..  one part by its name
#
# (2026-10-15, Phase 1c: the staging, feed and act paths in the sandbox, bend/Box/ScnStage.bend;
# these parts are not made by `links`, a scenario links the ones it needs.)  A call a part
# records is a line `ROLE ARGS` appended to SIM_CALLS (when set), some with ` [K=V ...]`:
#
#   scp                   scp's options read and left out, each HOST:PATH mapped as rsync maps
#                         it, the real cp copies (-r: recursively); 255 while the link is down
#   nix                   `run ..#bend -- ARGS` runs `bend ARGS`, `run .#deploy -- TOOL ARGS`
#                         `bend-TOOL ARGS` (both found on $PATH); `path-info -r P` prints P and
#                         SIM_ELAN (a store path named -elan-4.0.0); --version; anything else
#                         (copy) is recorded with NIX_SSHOPTS and succeeds
#   bend                  `bend SRC -o OUT` writes OUT, `bend-sim C of SRC` (the pinned compiler)
#   bend-push             `link ...` recorded (with TRAIN_ENV_FILE) and answered OK; anything
#                         else recorded and run by the real bend-push, SIM_PUSH
#   elan, lake            recorded with the directory they ran in; succeed
#   systemctl             recorded; `is-active` answers 3 (inactive)
#   sleep                 sleeps SIM_SLEEP_CAP (1) seconds at most: an old script's waits, short
#   deploy                (a box's gcroot) `corpus-v2 agent-act ARGS` runs the real
#                         bend-corpus-v2 (SIM_CV2) agent-act ARGS; `corpus-v2 STEP ARGS` runs
#                         this binary as bend-corpus-v2 (below), so pgrep sees that name
#   bend-corpus-v2        (on a box) `agent-eval CKPT DIR ...` recorded with the environment
#                         agent-act gives it; DIR/report.txt, DIR/episodes.eplog and
#                         DIR/agent.nul from SIM_REPORT, SIM_EPLOG and SIM_AGENT; SIM_ACT_MS
#                         (0) of sleep
#   bend-episode          (on a box) `why` and `langs` run the real one (SIM_EPISODE);
#                         `accept` and `fixed` are recorded (AGENT_RECORDS) and make DIR
#
# The box's path map: SIM_BOX_HOME/.sim-map's lines `FROM TO` (absolute paths).  ssh's
# command line has every FROM replaced by its TO, and rsync's and scp's remote paths under a
# FROM are under its TO, so a script naming the workspace, /usr/local/bin or /etc/nix by an
# absolute path (act-box.sh) acts in the sandbox, never on this machine.  SIM_BOX_HOME/
# .drop-before (Phase 1c): an ssh command line that holds its text fails with 255 BEFORE it
# runs, once (the file is removed).  SIM_BOX_HOME/.rsync-fail: the numbers (a line each) of the
# rsync calls with a remote side (counted in SIM_BOX_HOME/.rsync-calls) that fail with 255.
#
# The box's environment (ssh's commands): HOME, SIM_BOX and SIM_BOX_HOME the box
# directory, PATH its bin/ then SIM_BOX_PATH (else this PATH), and the KEY=VALUE lines of
# SIM_BOX_HOME/.sim-env (a box's own settings: SAVE, SIM_SLEEP_MS, ...); nothing else of
# the caller's.  bend-sim cannot stream a connection (Process.run collects a child's output
# and Bend has no exec), so rsync is not run through this ssh: its own part copies.
#
# The trainer also appends `start OUT from STEP` to SIM_STARTS (when set) as it starts, and
# makes its save at step SIM_UNREADABLE_AT unreadable (chmod 000), a checkpoint no pull and
# no sha256sum can read.
#
# The trainer: a stamped line on stderr (flushed: a driver need not run it
# under stdbuf) for each step, `step=I/END progress=P% lr=... ms=M tok/s=T`;
# every SIM_EVAL_EVERY (EVAL_EVERY, 0) steps a validation line; every
# SIM_SAVE_EVERY (SAVE_EVERY, 5; 0: only the last) steps and at the end
# OUT-stepI.checkpoint (SIM_CKPT_BYTES, 4096, of text that depends only on
# OUT and I) and then `saved OUT-stepI.checkpoint (1 ms)`; at the end `done at
# step END`.  It starts at TRAIN_INIT's step (`loaded TRAIN_INIT`; a missing
# file exits 1) or 0 and runs SIM_STEPS (TRAIN_STEPS, PLAN's third field, 20)
# steps, SIM_SLEEP_MS (50) each; SIM_DIE_AT=K exits 1 at step K, before its
# save.  TRAIN_INIT with EVAL_CORPUS and no PLAN scores instead (windows,
# loss, bits_per_byte, as fp.sh eval reads them).  SIM_DUMP=FILE appends the
# arguments and the sorted environment to FILE first.
#
# Every name starts with `sim.`.

# Text ------------------------------------------------------------------------------------

def sim.join(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      x
    case x <> t:
      x ++ " " ++ sim.join(t)

def sim.dir(+p: String) -> String:
  Bool.pick(String, S.infix(S.b(p), [47]), S.parent(p), ".")

def sim.is.digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def sim.zeros.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      sim.zeros.drop(t, U32.is_eq(Lc.lcl.at(t, 0n), 48))
    case r _:
      r

def sim.pad3(+n: Nat) -> String:
  String.repeat("0", Nat.sub(3n, String.length(Nat.show(n)))) ++ Nat.show(n)

# a fraction in thousandths, as `.ddd` without trailing zeros ("" for none)
def sim.frac(+f: Nat) -> String:
  +r = List.reverse(&2, U32, S.b(sim.pad3(f)))
  Bool.pick(String, Nat.is_eq(f, 0n), "", "." ++ S.str(List.reverse(&2, U32, sim.zeros.drop(r, U32.is_eq(Lc.lcl.at(r, 0n), 48)))))

# I * 100 / N, three decimals at most, as the trainer's progress=
def sim.pct(+i: Nat, +n: Nat) -> String:
  +x = Nat.div(Nat.mul(i, U32.to_nat(100000)), Nat.max(n, 1n))
  Nat.show(Nat.div(x, U32.to_nat(1000))) ++ sim.frac(Nat.mod(x, U32.to_nat(1000)))

# thousandths as a decimal: 533 is 0.533
def sim.milli(+m: Nat) -> String:
  Nat.show(Nat.div(m, U32.to_nat(1000))) ++ "." ++ sim.pad3(Nat.mod(m, U32.to_nat(1000)))

def sim.digits(xs: List<&2, U32>, +acc: Nat, at: Bool) -> Nat:
  match xs at:
    case +c <> +t True{}:
      sim.digits(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(c, 48))), sim.is.digit(Lc.lcl.at(t, 0n)))
    case _ _:
      acc

def sim.step.at(+xs: List<&2, U32>, m: Maybe<&2, Nat>) -> Nat:
  match m:
    case None{}:
      0n
    case Some{+k}:
      +r = List.drop(&2, U32, xs, Nat.sub(S.len(xs), k))
      sim.digits(r, 0n, sim.is.digit(Lc.lcl.at(r, 0n)))

# a checkpoint's step: the digits after its name's last "-step" (0: none)
def sim.step.of(+name: String) -> Nat:
  +xs = S.b(S.base(name))
  sim.step.at(xs, S.find(List.reverse(&2, U32, xs), S.b("pets-"), 0n))

# The environment ------------------------------------------------------------------------

# $a as a number, else $b, else d
def sim.env2(+a: String, +b: String, +d: Nat) -> IO(Nat):
  do IO<Nat>:
    +y : Nat <- S.env.nat(b, d)
    S.env.nat(a, y)

def sim.dump.text(+argv: String, +env: List<&2, U32>) -> List<&2, U32>:
  List.concat(&2, U32, [S.b("argv: " ++ argv ++ "\n"), S.join(Lc.lcl.sort(S.split(env, 0)), 10), [10, 10]])

def sim.dump(none: Bool, +file: String, +argv: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        +o : Lc.LclOut <- Lc.lcl.run(30, "env", ["-0"])
        S.add(file, sim.dump.text(argv, Lc.lcl.out(o)))

# The trainer ----------------------------------------------------------------------------

type SimCfg is Data:
  SimCfg{out: String, start: Nat, end: Nat, save: Nat, eval: Nat, die: Nat, sleep: Nat, bytes: Nat, lr: String}

def sim.c.out(+c: SimCfg) -> String:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      o

def sim.c.start(+c: SimCfg) -> Nat:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      s

def sim.c.end(+c: SimCfg) -> Nat:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      e

def sim.c.save(+c: SimCfg) -> Nat:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      sv

def sim.c.eval(+c: SimCfg) -> Nat:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      ev

def sim.c.die(+c: SimCfg) -> Nat:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      d

def sim.c.sleep(+c: SimCfg) -> Nat:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      sl

def sim.c.bytes(+c: SimCfg) -> Nat:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      n

def sim.c.lr(+c: SimCfg) -> String:
  match c:
    case SimCfg{o, s, e, sv, ev, d, sl, n, lr}:
      lr

def sim.ckpt.text(+out: String, +i: Nat, +n: Nat) -> List<&2, U32>:
  +line = "sim checkpoint " ++ out ++ " step " ++ Nat.show(i) ++ "\n"
  List.take(&2, U32, S.b("BTC1\n" ++ String.repeat(line, Nat.add(Nat.div(n, Nat.max(String.length(line), 1n)), 1n))), n)

def sim.chmod0(yes: Bool, +name: String) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        o : Lc.LclOut <- Lc.lcl.run(30, "chmod", ["000", name])
        return Unit{}

def sim.save(yes: Bool, +c: SimCfg, +i: Nat) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      +name = sim.c.out(c) ++ "-step" ++ Nat.show(i) ++ ".checkpoint"
      do IO<Unit>:
        S.write(name, sim.ckpt.text(sim.c.out(c), i, sim.c.bytes(c)))
        +u : Nat <- S.env.nat("SIM_UNREADABLE_AT", 0n)
        sim.chmod0(Bool.and(Nat.is_ne(u, 0n), Nat.is_eq(u, i)), name)
        Ck.log("saved " ++ name ++ " (1 ms)")

def sim.die(yes: Bool, +i: Nat) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.die(Unit, 1, "sim: the trainer dies at step " ++ Nat.show(i) ++ " (SIM_DIE_AT)")

def sim.valid(yes: Bool, +i: Nat, +left: Nat) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      Ck.log("step=" ++ Nat.show(i) ++ " validation_loss=1.25 validation_delta=na best_validation_loss=1.25 new_best=True bits_per_byte=0.55 remaining="
        ++ Nat.show(left) ++ " eta=na")

def sim.every(+e: Nat, +i: Nat) -> Bool:
  Bool.and(Nat.is_ne(e, 0n), Nat.is_eq(Nat.mod(i, Nat.max(e, 1n)), 0n))

def sim.one(+c: SimCfg, +i: Nat) -> IO(Unit):
  +e = sim.c.end(c)
  +sl = Nat.max(sim.c.sleep(c), 1n)
  do IO<Unit>:
    IO.sleep(U32.from_nat(Nat.min(sl, U32.to_nat(600000))))
    Ck.log("step=" ++ Nat.show(i) ++ "/" ++ Nat.show(e) ++ " progress=" ++ sim.pct(i, e) ++ "% lr=" ++ sim.c.lr(c)
      ++ " train_loss=0.9590317 train_loss_ema=0.9590317 gradient_norm=0.5 clipped=False ms=" ++ Nat.show(sl)
      ++ " tok/s=" ++ Nat.show(Nat.div(U32.to_nat(32736000), sl)))
    sim.valid(sim.every(sim.c.eval(c), i), i, Nat.sub(e, i))
    sim.die(Nat.is_eq(sim.c.die(c), i), i)
    sim.save(Bool.or(sim.every(sim.c.save(c), i), Nat.is_eq(i, e)), c, i)

def sim.loop(fuel: Nat, +c: SimCfg, +i: Nat) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+f:
      do IO<Unit>:
        sim.one(c, i)
        sim.loop(f, c, 1n+i)

def sim.started(none: Bool, +file: String, +out: String, +s: Nat) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      S.add(file, S.b("start " ++ out ++ " from " ++ Nat.show(s) ++ "\n"))

def sim.train.run(+c: SimCfg, +next: Bool, +mask: String, +rdir: String, +size: String) -> IO(Unit):
  +s = sim.c.start(c)
  +e = sim.c.end(c)
  do IO<Unit>:
    +starts : String <- S.env("SIM_STARTS", "")
    sim.started(String.is_empty(starts), starts, sim.c.out(c), s)
    S.mkdir(sim.dir(sim.c.out(c)))
    Ck.log(Bool.pick(String, next,
      "train (dense, next plan): from step " ++ Nat.show(s) ++ " of sim onto " ++ Nat.show(Nat.sub(e, s))
        ++ " steps of sim; the schedule restarts (warmup 10, lr " ++ sim.c.lr(c) ++ "), the optimizer state carries over",
      "train (dense, plan start): sim; " ++ Nat.show(e) ++ " global steps at batch 16"))
    Ck.log(Bool.pick(String, String.eq(mask, "kinds"), "training targets: by role (TRAIN_MASK=kinds: a tool's echo and a given attempt weigh 0)",
      "training targets: every token"))
    Ck.log("reading " ++ Bool.pick(String, String.is_empty(rdir), "run/sim", rdir) ++ "/shard-0-" ++ Bool.pick(String, String.is_empty(size), "sim", size) ++ ".corpus")
    sim.valid(Nat.is_ne(sim.c.eval(c), 0n), s, Nat.sub(e, s))
    sim.loop(Nat.sub(e, s), c, 1n+s)
    Ck.log("done at step " ++ Nat.show(e))

def sim.load.if(there: Bool, +init: String) -> IO(Unit):
  match there:
    case True{}:
      Ck.log("loaded " ++ init ++ " (1 ms)")
    case False{}:
      IO.die(Unit, 1, "sim: cannot load TRAIN_INIT " ++ init ++ ": no such file")

def sim.loaded.at(none: Bool, +init: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        there : Bool <- S.exists(init)
        sim.load.if(there, init)

def sim.loaded(+init: String) -> IO(Unit):
  sim.loaded.at(String.is_empty(init), init)

# fp.sh eval's lines: what `grep -v "^bend profile" | tail -3` keeps
def sim.eval(+init: String) -> IO(Unit):
  +m = Nat.add(500n, Nat.div(U32.to_nat(200000), Nat.add(sim.step.of(init), U32.to_nat(1000))))
  do IO<Unit>:
    Ck.log("windows: 1333  predictions: 2728651  bytes: 8103502")
    Ck.log("loss: " ++ sim.milli(Nat.mul(m, 2n)) ++ " nats/token")
    Ck.log("bits_per_byte: " ++ sim.milli(m))

def sim.plan.steps(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Lc.lcl.nat(Lc.lcl.nth(Lc.lcl.words(S.lines.first(xs)), 2n)), 20n)

def sim.train.cfg(+init: String, +plan: String) -> IO(SimCfg):
  do IO<SimCfg>:
    out : String <- S.env("OUT", "out/sim")
    +pl : List<&2, U32> <- S.read(plan)
    +steps : Nat <- sim.env2("SIM_STEPS", "TRAIN_STEPS", sim.plan.steps(pl))
    +save : Nat <- sim.env2("SIM_SAVE_EVERY", "SAVE_EVERY", 5n)
    +ev : Nat <- sim.env2("SIM_EVAL_EVERY", "EVAL_EVERY", 0n)
    +die : Nat <- S.env.nat("SIM_DIE_AT", 0n)
    +sl : Nat <- S.env.nat("SIM_SLEEP_MS", 50n)
    +n : Nat <- S.env.nat("SIM_CKPT_BYTES", 4096n)
    lr : String <- S.env("TRAIN_LR", "0.0003")
    +s : Nat = sim.step.of(init)
    return SimCfg{out, s, Nat.add(s, steps), save, ev, die, sl, n, lr}

def sim.trainer.go(score: Bool, +init: String, +plan: String) -> IO(Unit):
  match score:
    case True{}:
      do IO<Unit>:
        sim.loaded(init)
        sim.eval(init)
    case False{}:
      do IO<Unit>:
        sim.loaded(init)
        +c : SimCfg <- sim.train.cfg(init, plan)
        next : String <- S.env("TRAIN_NEXT", "")
        mask : String <- S.env("TRAIN_MASK", "")
        rdir : String <- S.env("RUN_DIR", "")
        size : String <- S.env("SHARD_SIZE", "")
        sim.train.run(c, Bool.not(String.is_empty(next)), mask, rdir, size)

def sim.trainer() -> IO(Unit):
  do IO<Unit>:
    +init : String <- S.env("TRAIN_INIT", "")
    +ec : String <- S.env("EVAL_CORPUS", "")
    +plan : String <- S.env("PLAN", "")
    sim.trainer.go(Bool.and(Bool.not(String.is_empty(init)), Bool.and(Bool.not(String.is_empty(ec)), String.is_empty(plan))), init, plan)

# The gate, the GPU and the compiler ------------------------------------------------------

def sim.say(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case x <> t:
      do IO<Unit>:
        IO.print(x)
        sim.say(t)

# run 3's gate.log (bend/gpu/fp.sh gate), the masked check's relative error
# put past 1e-5 when bad
def sim.dense(+bad: Bool) -> IO(Unit):
  sim.say(["tree loss  5.5636816",
    "chunk 64 (one per window): dense loss 5.56368",
    "chunk 64 (one per window): gradient max |diff| 2.4214387e-8 of max |g| 0.06403036 (relative 3.7817043e-7)",
    "chunk 16 (four per window): dense loss 5.563681",
    "chunk 16 (four per window): gradient max |diff| 2.3283064e-8 of max |g| 0.06403036 (relative 3.6362542e-7)",
    "masked tree loss 5.5529957, dense loss 5.5529957",
    Bool.pick(String, bad, "masked: gradient max |diff| 1.4628608e-5 of max |g| 0.07314304 (relative 2.0e-4)",
      "masked: gradient max |diff| 3.5390258e-8 of max |g| 0.07314304 (relative 4.8384993e-7)"),
    "small4 tree loss 5.570061",
    "small4, chunk 16: dense loss 5.5700607",
    "small4, chunk 16: gradient max |diff| 2.7939677e-8 of max |g| 0.06248855 (relative 4.4711675e-7)",
    "bend profile: gemm 588 calls (0 as loops), 303.202 ms, 0.966 GFLOP, 3.2 GFLOP/s",
    "bend profile: einsum 1327 calls, 21671.873 ms"])

def sim.l2(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> sim.l2(t)

def sim.has(xs: List<&2, String>, +w: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      Bool.or(String.eq(x, w), sim.has(t, w))

# run 3's eval.log head (fp.sh build's nvidia-smi lines)
def sim.smi.perf() -> List<&2, String>:
  ["    Clocks Event Reasons",
   "        Idle                                           : Not Active",
   "        Applications Clocks Setting                    : Not Active",
   "        SW Power Cap                                   : Not Active",
   "        HW Slowdown                                    : Not Active",
   "            HW Thermal Slowdown                        : Not Active",
   "            HW Power Brake Slowdown                    : Not Active",
   "        Sync Boost                                     : Not Active",
   "        SW Thermal Slowdown                            : Not Active",
   "        Display Clock Setting                          : Not Active",
   "    Clocks Event Reasons Counters",
   "        SW Power Capping                               : 5798971407 us",
   "        Sync Boost                                     : 0 us",
   "        SW Thermal Slowdown                            : 0 us",
   "        HW Thermal Slowdown                            : 0 us",
   "        HW Power Braking                               : 0 us"]

def sim.smi(+args: List<&2, String>) -> IO(Unit):
  +query = sim.has(args, "--query-gpu=name,driver_version,power.limit,memory.total")
  +dmon = sim.has(args, "dmon")
  +q = sim.has(args, "-q")
  sim.say(Bool.pick(List<&2, String>, query, ["NVIDIA GeForce RTX 5090, 580.126.09, 500.00 W, 32607 MiB"],
    Bool.pick(List<&2, String>, dmon, ["# gpu    pwr  gtemp  mtemp     sm    mem    enc    dec    jpg    ofa   mclk   pclk",
        "# Idx      W      C      C      %      %      %      %      %      %    MHz    MHz",
        "    0    480     61      -     99     71      0      0      0      0  14001   2617"],
      Bool.pick(List<&2, String>, q, sim.smi.perf(), ["NVIDIA-SMI 580.126.09 (bend-sim): GPU 0: NVIDIA GeForce RTX 5090"]))))

def sim.after.o(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case "-o" <> o <> t:
      o
    case x <> t:
      sim.after.o(t)

def sim.join2(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      x
    case x <> t:
      x ++ " " ++ sim.join2(t)

def sim.clang.out(none: Bool, +out: String, +args: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        S.write(out, S.b("bend-sim clang: " ++ args ++ "\n"))
        o : Lc.LclOut <- Lc.lcl.run(30, "chmod", ["+x", out])
        return Unit{}

def sim.clang.at(version: Bool, +args: List<&2, String>) -> IO(Unit):
  match version:
    case True{}:
      IO.print("clang version 19.1.7 (bend-sim)")
    case False{}:
      +out = sim.after.o(args)
      sim.clang.out(String.is_empty(out), out, sim.join2(args))

def sim.clang(+args: List<&2, String>) -> IO(Unit):
  sim.clang.at(sim.has(args, "--version"), args)

# vastai over a state directory --------------------------------------------------------------

def sim.inst.json(+ws: List<&2, List<&2, U32>>) -> String:
  +st = Lc.lcl.nth(ws, 1n)
  +host = Lc.lcl.nth(ws, 2n)
  +port = Lc.lcl.nth(ws, 3n)
  " {\n  \"actual_status\": \"" ++ Bool.pick(String, Nat.is_eq(S.len(st), 0n), "running", S.str(st)) ++ "\",\n"
    ++ "  \"gpu_name\": \"RTX 5090\",\n  \"id\": " ++ S.str(Lc.lcl.nth(ws, 0n)) ++ ",\n"
    ++ "  \"ssh_host\": \"" ++ Bool.pick(String, Nat.is_eq(S.len(host), 0n), "127.0.0.1", S.str(host)) ++ "\",\n"
    ++ "  \"ssh_port\": " ++ Bool.pick(String, Nat.is_eq(S.len(port), 0n), "22", S.str(port)) ++ "\n }"

def sim.insts(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +ws = Lc.lcl.words(l)
      +rest = sim.insts(t)
      Bool.pick(List<&2, String>, Nat.is_eq(List.length(&2, List<&2, U32>, ws), 0n), rest, sim.inst.json(ws) <> rest)

def sim.commas(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      x
    case x <> t:
      x ++ ",\n" ++ sim.commas(t)

# `vastai show instances --raw`: json.dumps(rows, indent=1, sort_keys=True)
def sim.list.json(+xs: List<&2, U32>) -> String:
  +objs = sim.insts(S.split.lines(xs))
  Bool.pick(String, Nat.is_eq(List.length(&2, String, objs), 0n), "[]", "[\n" ++ sim.commas(objs) ++ "\n]")

def sim.user.json(+credit: List<&2, U32>) -> String:
  "{\n \"balance\": 0,\n \"credit\": " ++ Bool.pick(String, Nat.is_eq(S.len(credit), 0n), "10.0", S.str(credit))
    ++ ",\n \"email\": \"sim@example.invalid\",\n \"id\": 100001\n}"

def sim.drop.inst(ls: List<&2, List<&2, U32>>, +inst: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = sim.drop.inst(t, inst)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(Lc.lcl.nth(Lc.lcl.words(l), 0n), inst), rest, l <> rest)

# (2026-10-15, Phase 1c) the state directory's `credits`: a credit a line, one taken by each
# `show user` (the last one stays), so a scenario's credit changes at a given call, not at a time
def sim.vast.pop(+qs: List<&2, List<&2, U32>>, +dir: String) -> IO(Unit):
  Bool.pick(IO(Unit), Nat.is_lt(1n, List.length(&2, List<&2, U32>, qs)),
    S.write(dir ++ "/credits", List.append(&2, U32, S.join(List.drop(&2, List<&2, U32>, qs, 1n), 10), [10])), IO.pure(Unit, Unit{}))

def sim.vast.user(+dir: String) -> IO(Unit):
  do IO<Unit>:
    own : Bool <- S.exists(dir ++ "/user.json")
    +u : List<&2, U32> <- S.read(dir ++ "/user.json")
    +q : List<&2, U32> <- S.read(dir ++ "/credits")
    +qs : List<&2, List<&2, U32>> = S.split.lines(q)
    sim.vast.pop(qs, dir)
    +c : List<&2, U32> <- S.read(dir ++ "/credit")
    +cr : List<&2, U32> = Bool.pick(List<&2, U32>, List.is_empty(&2, List<&2, U32>, qs), Lc.lcl.nth(Lc.lcl.words(c), 0n), Lc.lcl.nth(qs, 0n))
    IO.print(Bool.pick(String, own, S.str(S.chomp(u)), sim.user.json(cr)))

def sim.vast.list.at(fail: Bool, +dir: String) -> IO(Unit):
  match fail:
    case True{}:
      IO.die(Unit, 1, "failed to fetch instances (bend-sim: " ++ dir ++ "/list.fail)")
    case False{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- S.read(dir ++ "/instances")
        IO.print(sim.list.json(xs))

def sim.vast.list(+dir: String) -> IO(Unit):
  do IO<Unit>:
    fail : Bool <- S.exists(dir ++ "/list.fail")
    sim.vast.list.at(fail, dir)

def sim.vast.destroy(+dir: String, +inst: String) -> IO(Unit):
  do IO<Unit>:
    noop : Bool <- S.exists(dir ++ "/destroy.noop")
    +xs : List<&2, U32> <- S.read(dir ++ "/instances")
    +left : List<&2, List<&2, U32>> = Bool.pick(List<&2, List<&2, U32>>, noop, S.split.lines(xs), sim.drop.inst(S.split.lines(xs), S.b(inst)))
    S.write(dir ++ "/instances", List.append(&2, U32, S.join(left, 10),
      Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, left), 0n), Nil{}, [10])))
    IO.print("destroying instance " ++ inst ++ ".")

def sim.vast.go(+dir: String, xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "show" <> "user" <> "--raw" <> Nil{}:
      sim.vast.user(dir)
    case "show" <> "instances" <> "--raw" <> Nil{}:
      sim.vast.list(dir)
    case "destroy" <> "instance" <> +n <> "-y" <> Nil{}:
      sim.vast.destroy(dir, n)
    case _:
      IO.die(Unit, 2, "bend-sim vastai: show user --raw | show instances --raw | destroy instance N -y")

def sim.vast(+args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    home : String <- S.env("HOME", ".")
    +dir : String <- S.env("SIM_VAST_DIR", home ++ "/.sim-vast")
    S.mkdir(dir)
    S.add(dir ++ "/calls", S.b(sim.join2(args) ++ "\n"))
    sim.vast.go(dir, args)

# The link to the box: ssh and rsync (2026-10-14, Phase 1a) ------------------------------------

def sim.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> sim.l1(t)

# a part that cannot go on: its message and status
def sim.need(bad: Bool, +code: U32, +msg: String) -> IO(Unit):
  match bad:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.die(Unit, code, msg)

def sim.pass.err(none: Bool, +e: List<&2, U32>) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print_err(S.str(e))

# a child's stderr passed on (line by line), then its status: a status other
# than 0 is IO.die's, whose message (printed with its newline) is the last line
def sim.pass(ok: Bool, +code: U32, +err: List<&2, U32>) -> IO(Unit):
  match ok:
    case True{}:
      +ls = S.split.lines(err)
      sim.pass.err(Nat.is_eq(List.length(&2, List<&2, U32>, ls), 0n), S.join(ls, 10))
    case False{}:
      +ls = S.split.lines(err)
      +n = List.length(&2, List<&2, U32>, ls)
      do IO<Unit>:
        sim.pass.err(Nat.is_lt(n, 2n), S.join(List.take(&2, List<&2, U32>, ls, Nat.sub(n, 1n)), 10))
        IO.die(Unit, code, S.str(Lc.lcl.nth(ls, Nat.sub(n, 1n))))

# a child's answer passed on as this part's own: stdout, stderr, status
def sim.got(+who: String, r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(Unit):
  match r:
    case Done{(+code, (out, err))}:
      do IO<Unit>:
        IO.write(out)
        sim.pass(U32.is_eq(code, 0), code, S.b(err))
    case Fail{(code, msg)}:
      IO.die(Unit, 255, "bend-sim " ++ who ++ ": " ++ msg)

# ssh(1)'s getopt: the options that take a value (the rest of the word, or the next word)
def sim.ssh.takes(+c: U32) -> Bool:
  S.infix(S.b("BbcDEeFIiJLlmOoPpQRSWw"), [c])

# What comes next while reading ssh's words: a flag, an option whose value is
# the rest of the word or the next word, that value, the next word (an option
# cluster, `--` or the host), or no word.
type SimK is Data:
  SkFlag{}
  SkAtt{}
  SkNext{}
  SkArg{}
  SkClu{}
  SkDash{}
  SkHost{}
  SkNone{}

type SimSshP is Data:
  SimSshP{port: String, n: Bool, host: String, cmd: List<&2, String>, ok: Bool}

def sim.ssh.kw(+ws: List<&2, String>) -> SimK:
  match ws:
    case Nil{}:
      SkNone{}
    case +w <> t:
      +bs = S.b(w)
      Bool.pick(SimK, String.eq(w, "--"), SkDash{}, Bool.pick(SimK, Bool.and(S.head.is(bs, 45), Nat.is_lt(1n, S.len(bs))), SkClu{}, SkHost{}))

def sim.ssh.kc(+cs: List<&2, U32>, +ws: List<&2, String>) -> SimK:
  match cs:
    case Nil{}:
      sim.ssh.kw(ws)
    case +c <> t:
      Bool.pick(SimK, sim.ssh.takes(c), Bool.pick(SimK, Nat.is_eq(S.len(t), 0n), SkNext{}, SkAtt{}), SkFlag{})

# an option's value is the next word: SkArg, or SkNone when there is none
def sim.ssh.ka(+ws: List<&2, String>) -> SimK:
  Bool.pick(SimK, List.is_empty(&2, String, ws), SkNone{}, SkArg{})

def sim.ssh.port(+c: U32, +v: String, +port: String) -> String:
  Bool.pick(String, U32.is_eq(c, 112), v, port)

def sim.ssh.word(+ws: List<&2, String>) -> String:
  Maybe.default(&2, String, List.head(&2, String, ws), "")

def sim.ssh.rest(+ws: List<&2, String>) -> List<&2, String>:
  List.drop(&2, String, ws, 1n)

# ssh's command line read: the port (-p), -n (no stdin), the host and the command's words
def sim.ssh.go(fuel: Nat, k: SimK, +ws: List<&2, String>, +cs: List<&2, U32>, +opt: U32, +port: String, +n: Bool) -> SimSshP:
  match fuel k:
    case 0n _:
      SimSshP{port, n, "", Nil{}, False{}}
    case 1n+f SkFlag{}:
      +t = List.drop(&2, U32, cs, 1n)
      sim.ssh.go(f, sim.ssh.kc(t, ws), ws, t, opt, port, Bool.or(n, U32.is_eq(Lc.lcl.at(cs, 0n), 110)))
    case 1n+f SkAtt{}:
      sim.ssh.go(f, sim.ssh.kw(ws), ws, Nil{}, 0, sim.ssh.port(Lc.lcl.at(cs, 0n), S.str(List.drop(&2, U32, cs, 1n)), port), n)
    case 1n+f SkNext{}:
      sim.ssh.go(f, sim.ssh.ka(ws), ws, Nil{}, Lc.lcl.at(cs, 0n), port, n)
    case 1n+f SkArg{}:
      +more = sim.ssh.rest(ws)
      sim.ssh.go(f, sim.ssh.kw(more), more, Nil{}, 0, sim.ssh.port(opt, sim.ssh.word(ws), port), n)
    case 1n+f SkClu{}:
      +more = sim.ssh.rest(ws)
      +t = List.drop(&2, U32, S.b(sim.ssh.word(ws)), 1n)
      sim.ssh.go(f, sim.ssh.kc(t, more), more, t, 0, port, n)
    case 1n+f SkDash{}:
      +more = sim.ssh.rest(ws)
      SimSshP{port, n, sim.ssh.word(more), sim.ssh.rest(more), Bool.not(List.is_empty(&2, String, more))}
    case 1n+f SkHost{}:
      SimSshP{port, n, sim.ssh.word(ws), sim.ssh.rest(ws), True{}}
    case 1n+f SkNone{}:
      SimSshP{port, n, "", Nil{}, False{}}

def sim.ssh.parse(+ws: List<&2, String>) -> SimSshP:
  sim.ssh.go(U32.to_nat(1000000), sim.ssh.kw(ws), ws, Nil{}, 0, "22", False{})

def sim.envlines(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = sim.envlines(t)
      Bool.pick(List<&2, String>, Bool.and(S.infix(l, [61]), Bool.not(S.head.is(l, 35))), S.str(l) <> rest, rest)

# the environment a box command runs in (the box's own, nothing of the caller's)
def sim.box.env(+box: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +bp : String <- S.env("SIM_BOX_PATH", "")
    path : String <- S.env("PATH", "")
    +rp : String = Bool.pick(String, String.is_empty(bp), path, bp)
    xs : List<&2, U32> <- S.read(box ++ "/.sim-env")
    return List.append(&2, String, ["HOME=" ++ box, "SIM_BOX=" ++ box, "SIM_BOX_HOME=" ++ box, "SIM_BOX_PATH=" ++ rp, "USER=root",
      "PATH=" ++ box ++ "/bin:" ++ rp], sim.envlines(S.split.lines(xs)))

def sim.input(n: Bool) -> IO(String):
  match n:
    case True{}:
      IO.pure(String, "")
    case False{}:
      do IO<String>:
        xs : List<&2, U32> <- S.read("/dev/stdin")
        return S.str(xs)

# a connection that drops after its command ran (SIM_BOX_HOME/.drop-after
# holds a piece of the command lines it drops): the command's effects stay,
# its answer is lost, ssh's 255
def sim.ssh.dropped(drop: Bool, +host: String, r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(Unit):
  match drop:
    case True{}:
      IO.die(Unit, 255, "Connection to " ++ host ++ " closed by remote host. (bend-sim: .drop-after)")
    case False{}:
      sim.got("ssh", r)

# The box's path map (2026-10-15, Phase 1c; the header) ------------------------------------

type SimMp is Data:
  SimMp{from: List<&2, U32>, to: List<&2, U32>}

def sim.map.pairs(ls: List<&2, List<&2, U32>>) -> List<&2, SimMp>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +ws = Lc.lcl.words(l)
      +rest = sim.map.pairs(t)
      Bool.pick(List<&2, SimMp>, Nat.is_eq(List.length(&2, List<&2, U32>, ws), 2n), SimMp{Lc.lcl.nth(ws, 0n), Lc.lcl.nth(ws, 1n)} <> rest, rest)

def sim.map.load(+box: String) -> IO(List<&2, SimMp>):
  do IO<List<&2, SimMp>>:
    xs : List<&2, U32> <- S.read(box ++ "/.sim-map")
    return sim.map.pairs(S.split.lines(xs))

# a command line with each FROM replaced by its TO, pair by pair
def sim.map.text(ms: List<&2, SimMp>, +xs: List<&2, U32>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      xs
    case SimMp{+f, +t} <> rest:
      sim.map.text(rest, S.replace(xs, f, t))

def sim.map.under(+p: List<&2, U32>, +f: List<&2, U32>) -> Bool:
  Bool.or(S.eq(p, f), S.prefix(p, List.append(&2, U32, f, [47])))

# an absolute path under a FROM (the first that holds it) as the same path under its TO (the
# map is a few lines: Bool.pick's strict recursion is linear in them)
def sim.map.path(ms: List<&2, SimMp>, +p: List<&2, U32>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      p
    case SimMp{+f, +t} <> rest:
      Bool.pick(List<&2, U32>, sim.map.under(p, f), List.append(&2, U32, t, List.drop(&2, U32, p, S.len(f))), sim.map.path(rest, p))

# SIM_BOX_HOME/.drop-before: a command line holding its text fails before it runs, once
def sim.ssh.before(hit: Bool, +box: String, +host: String, +port: String) -> IO(Unit):
  match hit:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        S.rm(box ++ "/.drop-before")
        IO.die(Unit, 255, "ssh: connect to host port " ++ port ++ ": Connection timed out (bend-sim: .drop-before; the host left out, so old and new runs log the same line)")

def sim.ssh.at(ok: Bool, +port: String, n: Bool, +host: String, +cmd: List<&2, String>) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 255, "usage: ssh [OPTIONS] HOST COMMAND... (bend-sim)")
    case True{}:
      do IO<Unit>:
        +box : String <- S.env("SIM_BOX_HOME", "")
        sim.need(String.is_empty(box), 255, "bend-sim ssh: SIM_BOX_HOME (the box's directory) is not set")
        down : Bool <- S.exists(box ++ "/.link-down")
        sim.need(down, 255, "ssh: connect to host " ++ host ++ " port " ++ port ++ ": Connection refused (bend-sim: the link is down)")
        sim.need(List.is_empty(&2, String, cmd), 255, "bend-sim ssh: no command (a login shell is not simulated)")
        ms : List<&2, SimMp> <- sim.map.load(box)
        +line : String = S.str(sim.map.text(ms, S.b(String.join(cmd, " "))))
        +db : List<&2, U32> <- S.read(box ++ "/.drop-before")
        sim.ssh.before(Bool.and(Nat.is_ne(S.len(S.chomp(db)), 0n), S.infix(S.b(line), S.chomp(db))), box, host, port)
        input : String <- sim.input(n)
        envs : List<&2, String> <- sim.box.env(box)
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
          Process.run("env", sim.l1(List.concat(&2, String, [["-i", "-C", box], envs, ["sh", "-c", line]])), input, S.cap.bytes(), 86400000)
        +drop : List<&2, U32> <- S.read(box ++ "/.drop-after")
        sim.ssh.dropped(Bool.and(Nat.is_ne(S.len(S.chomp(drop)), 0n), S.infix(S.b(line), S.chomp(drop))), host, r)

def sim.ssh.with(p: SimSshP) -> IO(Unit):
  match p:
    case SimSshP{port, n, host, cmd, ok}:
      sim.ssh.at(ok, port, n, host, cmd)

def sim.ssh(+args: List<&2, String>) -> IO(Unit):
  sim.ssh.with(sim.ssh.parse(args))

# rsync's words, each HOST:PATH a path in the box, its remote shell left out,
# and whether a side was remote
type SimRs is Data:
  SimRs{args: List<&2, String>, remote: Bool}

# HOST:PATH (a colon before any slash, not an option)
def sim.rs.is.remote(+bs: List<&2, U32>, m: Maybe<&2, Nat>) -> Bool:
  match m:
    case None{}:
      False{}
    case Some{+k}:
      Bool.and(Bool.and(Nat.is_lt(0n, k), Bool.not(S.head.is(bs, 45))), Bool.not(S.infix(List.take(&2, U32, bs, k), [47])))

# a remote path in the box: relative to SIM_BOX_HOME, an absolute one as the path map has it
def sim.rs.path(+box: String, +ms: List<&2, SimMp>, +p: List<&2, U32>) -> String:
  Bool.pick(String, S.head.is(p, 47), S.str(sim.map.path(ms, p)), box ++ "/" ++ S.str(p))

def sim.rs.word(remote: Bool, +bs: List<&2, U32>, m: Maybe<&2, Nat>, +box: String, +ms: List<&2, SimMp>, +w: String) -> String:
  match remote m:
    case True{} Some{+k}:
      sim.rs.path(box, ms, List.drop(&2, U32, bs, 1n+k))
    case _ _:
      w

def sim.rs.put(+w: String, r: SimRs, +box: String, +ms: List<&2, SimMp>) -> SimRs:
  match r:
    case SimRs{+as, +rem}:
      +bs = S.b(w)
      +m = S.find(bs, [58], 0n)
      +isr = sim.rs.is.remote(bs, m)
      Bool.pick(SimRs, String.starts_with(w, "--rsh="), SimRs{as, rem}, SimRs{sim.rs.word(isr, bs, m, box, ms, w) <> as, Bool.or(rem, isr)})

def sim.rs.map(ws: List<&2, String>, +box: String, +ms: List<&2, SimMp>) -> SimRs:
  match ws:
    case Nil{}:
      SimRs{Nil{}, False{}}
    case "-e" <> x <> more:
      sim.rs.map(more, box, ms)
    case "--rsh" <> x <> more:
      sim.rs.map(more, box, ms)
    case +w <> more:
      sim.rs.put(w, sim.rs.map(more, box, ms), box, ms)

def sim.rs.fail(hit: Bool, +n: Nat) -> IO(Unit):
  match hit:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        IO.print_err("rsync: connection unexpectedly closed (bend-sim: .rsync-fail, call " ++ Nat.show(n) ++ ")")
        IO.die(Unit, 255, "rsync error: unexplained error (code 255) at io.c(232) [sender=3.4.4]")

def sim.rs.listed(ls: List<&2, List<&2, U32>>, +k: List<&2, U32>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(S.eq(l, k), sim.rs.listed(t, k))

# a call with a remote side counted in .rsync-calls; the numbers .rsync-fail lists fail
def sim.rs.count(rem: Bool, +box: String) -> IO(Unit):
  match rem:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- S.read(box ++ "/.rsync-calls")
        +n : Nat = Nat.add(Maybe.default(&2, Nat, Lc.lcl.nat(S.chomp(xs)), 0n), 1n)
        S.write(box ++ "/.rsync-calls", S.b(Nat.show(n) ++ "\n"))
        +fs : List<&2, U32> <- S.read(box ++ "/.rsync-fail")
        sim.rs.fail(sim.rs.listed(S.split.lines(fs), S.b(Nat.show(n))), n)

def sim.rs.down(down: Bool) -> IO(Unit):
  match down:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        IO.print_err("ssh: connect to host box port 22: Connection refused (bend-sim: the link is down)")
        IO.print_err("rsync: connection unexpectedly closed (0 bytes received so far) [Receiver]")
        IO.die(Unit, 255, "rsync error: unexplained error (code 255) at io.c(232) [Receiver=3.4.4]")

def sim.rsync.with(r: SimRs, +box: String, +real: String, +input: String) -> IO(Unit):
  match r:
    case SimRs{as, +rem}:
      do IO<Unit>:
        down : Bool <- S.exists(box ++ "/.link-down")
        rdown : Bool <- S.exists(box ++ "/.rsync-down")
        sim.rs.down(Bool.and(Bool.or(down, rdown), rem))
        sim.rs.count(rem, box)
        res : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(real, sim.l1(as), input, S.cap.bytes(), 86400000)
        sim.got("rsync", res)

def sim.rsync(+args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +box : String <- S.env("SIM_BOX_HOME", "")
    +real : String <- S.env("SIM_RSYNC", "")
    sim.need(String.is_empty(box), 255, "bend-sim rsync: SIM_BOX_HOME (the box's directory) is not set")
    sim.need(String.is_empty(real), 2, "bend-sim rsync: SIM_RSYNC (the real rsync) is not set")
    ms : List<&2, SimMp> <- sim.map.load(box)
    # `--files-from=-` (act-box.sh setup's `git ls-files -z | rsync ...`): stdin passed on
    input : String <- sim.input(Bool.not(sim.has(args, "--files-from=-")))
    sim.rsync.with(sim.rs.map(args, box, ms), box, real, input)

# scp (2026-10-15, Phase 1c: fp-stage.sh's): its options left out (those taking a value with it),
# each HOST:PATH mapped as rsync maps it, the real cp copies (-r: recursively)
def sim.scp.flag(+w: String, r: SimRs) -> SimRs:
  match r:
    case SimRs{+as, +rem}:
      SimRs{Bool.pick(List<&2, String>, String.eq(w, "-r"), "-r" <> as, as), rem}

def sim.scp.map(ws: List<&2, String>, +box: String, +ms: List<&2, SimMp>) -> SimRs:
  match ws:
    case Nil{}:
      SimRs{Nil{}, False{}}
    case "-P" <> x <> more:
      sim.scp.map(more, box, ms)
    case "-o" <> x <> more:
      sim.scp.map(more, box, ms)
    case "-i" <> x <> more:
      sim.scp.map(more, box, ms)
    case "-F" <> x <> more:
      sim.scp.map(more, box, ms)
    case "-l" <> x <> more:
      sim.scp.map(more, box, ms)
    case +w <> more:
      +r = sim.scp.map(more, box, ms)
      Bool.pick(SimRs, String.starts_with(w, "-"), sim.scp.flag(w, r), sim.rs.put(w, r, box, ms))

def sim.scp.with(r: SimRs, +box: String) -> IO(Unit):
  match r:
    case SimRs{as, +rem}:
      do IO<Unit>:
        down : Bool <- S.exists(box ++ "/.link-down")
        rdown : Bool <- S.exists(box ++ "/.rsync-down")
        sim.rs.down(Bool.and(Bool.or(down, rdown), rem))
        res : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("cp", sim.l1(as), "", S.cap.bytes(), 86400000)
        sim.got("scp", res)

def sim.scp(+args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +box : String <- S.env("SIM_BOX_HOME", "")
    sim.need(String.is_empty(box), 255, "bend-sim scp: SIM_BOX_HOME (the box's directory) is not set")
    ms : List<&2, SimMp> <- sim.map.load(box)
    sim.scp.with(sim.scp.map(args, box, ms), box)

def sim.rc.got(+rc: String, +out: String, r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(Unit):
  match r:
    case Done{(code, (o, e))}:
      do IO<Unit>:
        S.write(out, S.b(o ++ e))
        S.write(rc, S.b(U32.show(code) ++ "\n"))
    case Fail{(code, msg)}:
      do IO<Unit>:
        S.write(out, S.b("sim-rc: " ++ msg ++ "\n"))
        S.write(rc, S.b("127\n"))

def sim.rc(args: List<&2, String>) -> IO(Unit):
  match args:
    case +rc <> +out <> prog <> rest:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, sim.l1(rest), "", S.cap.bytes(), 4000000000)
        sim.rc.got(rc, out, r)
    case _:
      IO.die(Unit, 2, "usage: bend-sim sim-rc RCFILE OUTFILE PROG ARGS...")

def sim.notify(+args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    home : String <- S.env("HOME", ".")
    +f : String <- S.env("SIM_ALERTS", home ++ "/.sim-alerts")
    S.add(f, S.b("notify-send " ++ sim.join2(args) ++ "\n"))

# The box's pgrep and pkill ----------------------------------------------------------------------

type SimPg is Data:
  SimPg{count: Bool, exact: Bool, full: Bool, sig: String, pat: String}

def sim.pg.word(o: SimPg, +w: String) -> SimPg:
  match o:
    case SimPg{+c, +x, +f, +s, +p}:
      Bool.pick(SimPg, String.eq(w, "-c"), SimPg{True{}, x, f, s, p},
        Bool.pick(SimPg, String.eq(w, "-x"), SimPg{c, True{}, f, s, p},
          Bool.pick(SimPg, String.eq(w, "-f"), SimPg{c, x, True{}, s, p},
            Bool.pick(SimPg, String.starts_with(w, "-"), SimPg{c, x, f, String.drop(w, 1n), p}, SimPg{c, x, f, s, w}))))

def sim.pg.sig(o: SimPg, +s: String) -> SimPg:
  match o:
    case SimPg{c, x, f, s0, p}:
      SimPg{c, x, f, s, p}

def sim.pg.opt(ws: List<&2, String>, o: SimPg) -> SimPg:
  match ws:
    case Nil{}:
      o
    case "--signal" <> s <> more:
      sim.pg.opt(more, sim.pg.sig(o, s))
    case +w <> more:
      sim.pg.opt(more, sim.pg.word(o, w))

def sim.has.piece(ps: List<&2, List<&2, U32>>, +key: List<&2, U32>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> t:
      Bool.or(S.eq(p, key), sim.has.piece(t, key))

# the candidates whose environment holds SIM_BOX=<box>
def sim.pg.mine(ps: List<&2, List<&2, U32>>, +key: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +p <> t:
      do IO<List<&2, List<&2, U32>>>:
        env : List<&2, U32> <- S.read("/proc/" ++ S.str(p) ++ "/environ")
        +ok : Bool = sim.has.piece(S.split(env, 0), key)
        +rest : List<&2, List<&2, U32>> <- sim.pg.mine(t, key)
        return Bool.pick(List<&2, List<&2, U32>>, ok, p <> rest, rest)

def sim.pg.filter(all: Bool, +ps: List<&2, List<&2, U32>>, +key: List<&2, U32>) -> IO(List<&2, List<&2, U32>>):
  match all:
    case True{}:
      IO.pure(List<&2, List<&2, U32>>, ps)
    case False{}:
      sim.pg.mine(ps, key)

def sim.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.str(x) <> sim.strs(t)

def sim.pg.end(none: Bool) -> IO(Unit):
  match none:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      IO.die(Unit, 1, "")

def sim.pg.say(count: Bool, +ps: List<&2, List<&2, U32>>) -> IO(Unit):
  match count:
    case True{}:
      IO.print(Nat.show(List.length(&2, List<&2, U32>, ps)))
    case False{}:
      sim.say(sim.strs(ps))

def sim.pg.kill(none: Bool, +sig: String, +ps: List<&2, List<&2, U32>>, +path: String) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        o : Lc.LclOut <- Lc.lcl.run(30, "env", sim.l1(List.append(&2, String, ["PATH=" ++ path, "kill", "-" ++ sig], sim.strs(ps))))
        return Unit{}

def sim.pg.fin(kill: Bool, o: SimPg, +ps: List<&2, List<&2, U32>>, +path: String) -> IO(Unit):
  match o:
    case SimPg{c, x, f, s, p}:
      +none = Nat.is_eq(List.length(&2, List<&2, U32>, ps), 0n)
      do IO<Unit>:
        Bool.pick(IO(Unit), kill, sim.pg.kill(none, s, ps, path), sim.pg.say(c, ps))
        sim.pg.end(none)

def sim.pg.flags(o: SimPg) -> List<&2, String>:
  match o:
    case SimPg{c, x, f, s, p}:
      List.concat(&2, String, [Bool.pick(List<&2, String>, x, ["-x"], Nil{}), Bool.pick(List<&2, String>, f, ["-f"], Nil{}), ["--", p]])

# -o (the oldest: here the lowest pid of this box's) and -s SID (a session),
# taken out of the words before the rest are read (2026-10-15, Phase 4b:
# bend-box act-stop's `pgrep -o -x NAME` and `pkill -TERM -s SID`)
type SimPgX is Data:
  SimPgX{oldest: Bool, sess: String, rest: List<&2, String>}

def sim.pg.x(ws: List<&2, String>, o: SimPgX) -> SimPgX:
  match ws o:
    case Nil{} _:
      o
    case "-o" <> more SimPgX{a, s, r}:
      sim.pg.x(more, SimPgX{True{}, s, r})
    case "-s" <> +sid <> more SimPgX{a, s, r}:
      sim.pg.x(more, SimPgX{a, sid, r})
    case +w <> more SimPgX{a, s, r}:
      sim.pg.x(more, SimPgX{a, s, List.append(&2, String, r, [w])})

def sim.pg.x.rest(+x: SimPgX) -> List<&2, String>:
  match x:
    case SimPgX{a, s, r}:
      r

def sim.pg.x.flags(+x: SimPgX) -> List<&2, String>:
  match x:
    case SimPgX{a, s, r}:
      Bool.pick(List<&2, String>, String.is_empty(s), Nil{}, ["-s", s])

def sim.pg.x.oldest(+x: SimPgX) -> Bool:
  match x:
    case SimPgX{a, s, r}:
      a

def sim.pg.low(ps: List<&2, List<&2, U32>>, +best: List<&2, U32>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      best
    case +p <> t:
      +n = Maybe.default(&2, Nat, Lc.lcl.nat(p), 0n)
      +b = Maybe.default(&2, Nat, Lc.lcl.nat(best), 0n)
      sim.pg.low(t, Bool.pick(List<&2, U32>, Bool.or(Nat.is_eq(S.len(best), 0n), Nat.is_lt(n, b)), p, best))

def sim.pg.pick(oldest: Bool, +ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match oldest:
    case False{}:
      ps
    case True{}:
      Bool.pick(List<&2, List<&2, U32>>, List.is_empty(&2, List<&2, U32>, ps), Nil{}, [sim.pg.low(ps, Nil{})])

# pgrep (kill False) or pkill (True), limited to this box's processes
def sim.pg(kill: Bool, +args: List<&2, String>) -> IO(Unit):
  +x = sim.pg.x(args, SimPgX{False{}, "", Nil{}})
  +o = sim.pg.opt(sim.pg.x.rest(x), SimPg{False{}, False{}, False{}, "TERM", ""})
  do IO<Unit>:
    +box : String <- S.env("SIM_BOX", "")
    +bp : String <- S.env("SIM_BOX_PATH", "")
    path : String <- S.env("PATH", "")
    +rp : String = Bool.pick(String, String.is_empty(bp), path, bp)
    +r : Lc.LclOut <- Lc.lcl.run(60, "env", sim.l1(List.concat(&2, String, [["PATH=" ++ rp, "pgrep"], sim.pg.x.flags(x), sim.pg.flags(o)])))
    ps : List<&2, List<&2, U32>> <- sim.pg.filter(String.is_empty(box), Lc.lcl.words(Lc.lcl.out(r)), S.b("SIM_BOX=" ++ box))
    sim.pg.fin(kill, o, sim.pg.pick(sim.pg.x.oldest(x), ps), rp)

# Recorded stubs (2026-10-15, Phase 1c: the staging, feed and act paths; the header) ----------------

# ` K=V` for each of NS that is set (not empty)
def sim.envs.text(ns: List<&2, String>) -> IO(String):
  match ns:
    case Nil{}:
      IO.pure(String, "")
    case +n <> t:
      do IO<String>:
        +v : String <- S.env(n, "")
        +rest : String <- sim.envs.text(t)
        return Bool.pick(String, String.is_empty(v), "", " " ++ n ++ "=" ++ v) ++ rest

def sim.record.add(+f: String, +line: String) -> IO(Unit):
  Bool.pick(IO(Unit), String.is_empty(f), IO.pure(Unit, Unit{}), S.add(f, S.b(line ++ "\n")))

# `ROLE ARGS [K=V ...]` appended to SIM_CALLS (NS: the variables recorded with it)
def sim.record(+role: String, +args: List<&2, String>, ns: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +f : String <- S.env("SIM_CALLS", "")
    +e : String <- sim.envs.text(ns)
    sim.record.add(f, role ++ Bool.pick(String, List.is_empty(&2, String, args), "", " " ++ sim.join2(args))
      ++ Bool.pick(String, String.is_empty(e), "", " [" ++ String.drop(e, 1n) ++ "]"))

# PROG ARGS (found on $PATH), its answer passed on as this part's own
def sim.pass.run(+prog: String, +args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run(prog, sim.l1(args), "", S.cap.bytes(), 86400000)
    sim.got(prog, r)

def sim.real(+var: String, +role: String) -> IO(String):
  do IO<String>:
    +p : String <- S.env(var, "")
    sim.need(String.is_empty(p), 2, "bend-sim " ++ role ++ ": " ++ var ++ " is not set")
    return p

# the words after `nix run FLAKE`, without the `--` (Bend's runtime may have taken it already)
def sim.dashdash(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case "--" <> rest:
      rest
    case _:
      xs

def sim.nix.deploy(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case +tool <> +rest:
      sim.pass.run("bend-" ++ tool, rest)
    case Nil{}:
      IO.die(Unit, 2, "bend-sim nix: run .#deploy -- TOOL ARGS")

def sim.nix(xs: List<&2, String>, +all: List<&2, String>) -> IO(Unit):
  match xs:
    case "run" <> "..#bend" <> rest:
      sim.pass.run("bend", sim.dashdash(rest))
    case "run" <> ".#bend" <> rest:
      sim.pass.run("bend", sim.dashdash(rest))
    case "run" <> ".#deploy" <> rest:
      sim.nix.deploy(sim.dashdash(rest))
    case "path-info" <> "-r" <> +p <> Nil{}:
      do IO<Unit>:
        sim.record("nix", all, Nil{})
        +elan : String <- S.env("SIM_ELAN", "/nix/store/00000000000000000000000000000000-elan-4.0.0")
        IO.print(p)
        IO.print(elan)
    case "--version" <> Nil{}:
      IO.print("nix (Nix) 2.24.0 (bend-sim)")
    case _:
      sim.record("nix", all, ["NIX_SSHOPTS"])

def sim.bend(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case +src <> "-o" <> +out <> Nil{}:
      S.write(out, S.b("bend-sim C of " ++ src ++ "\n"))
    case _:
      IO.die(Unit, 2, "bend-sim bend: SRC -o OUT")

def sim.push(xs: List<&2, String>, +all: List<&2, String>) -> IO(Unit):
  match xs:
    case "link" <> rest:
      do IO<Unit>:
        sim.record("bend-push", all, ["TRAIN_ENV_FILE"])
        IO.print("check-link: OK — 20 MB in 0.01 s (bend-sim)")
    case _:
      do IO<Unit>:
        sim.record("bend-push", all, ["TRAIN_ENV_FILE", "SKIP_LINK_CHECK"])
        +real : String <- sim.real("SIM_PUSH", "bend-push")
        sim.pass.run(real, all)

def sim.tool(+role: String, +args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +cwd : String <- S.realpath(".")
    sim.record(role, List.append(&2, String, args, ["(in " ++ cwd ++ ")"]), Nil{})
    IO.print("bend-sim " ++ role ++ ": " ++ sim.join2(args))

def sim.systemctl(+args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    sim.record("systemctl", args, Nil{})
    Bool.pick(IO(Unit), sim.has(args, "is-active"), IO.die(Unit, 3, ""), IO.pure(Unit, Unit{}))

def sim.sleep(+args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +cap : Nat <- S.env.nat("SIM_SLEEP_CAP", 1n)
    +n : Nat = Maybe.default(&2, Nat, Lc.lcl.nat(S.b(sim.ssh.word(args))), 1n)
    IO.sleep(U32.from_nat(Nat.mul(Nat.min(n, Nat.min(cap, 3600n)), 1000n)))

def sim.deploy(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "corpus-v2" <> "agent-act" <> +rest:
      do IO<Unit>:
        +real : String <- sim.real("SIM_CV2", "deploy")
        sim.pass.run(real, "agent-act" <> rest)
    case "corpus-v2" <> +rest:
      sim.pass.run("bend-corpus-v2", rest)
    case _:
      IO.die(Unit, 2, "bend-sim deploy: corpus-v2 STEP ARGS")

# SRC's bytes (a path in the variable VAR) as DST, unless DST is there or VAR is not set
def sim.fixture(+var: String, +dst: String) -> IO(Unit):
  do IO<Unit>:
    +src : String <- S.env(var, "")
    there : Bool <- S.exists(dst)
    +xs : List<&2, U32> <- S.read(src)
    Bool.pick(IO(Unit), Bool.or(there, String.is_empty(src)), IO.pure(Unit, Unit{}), S.write(dst, xs))

def sim.agent.env() -> List<&2, String>:
  ["BEND_FT_THREADS", "EVALSET", "AGENT_DEPLOY", "AGENT_RECORDS", "TEMPERATURE", "TOP_P", "AGENT_SEEDS", "AGENT_TAG", "TOKENS",
   "AGENT_CALLS", "PROCS", "THREADS"]

def sim.cv2(xs: List<&2, String>, +all: List<&2, String>) -> IO(Unit):
  match xs:
    case "agent-eval" <> +ck <> +dir <> rest:
      do IO<Unit>:
        sim.record("bend-corpus-v2", all, sim.agent.env())
        S.mkdir(dir)
        sim.fixture("SIM_REPORT", dir ++ "/report.txt")
        sim.fixture("SIM_EPLOG", dir ++ "/episodes.eplog")
        sim.fixture("SIM_AGENT", dir ++ "/agent.nul")
        +ms : Nat <- S.env.nat("SIM_ACT_MS", 0n)
        IO.sleep(U32.from_nat(Nat.min(ms, 3600000n)))
        IO.print("bend-sim agent-eval: " ++ ck ++ " into " ++ dir)
    case _:
      sim.record("bend-corpus-v2", all, Nil{})

def sim.episode(xs: List<&2, String>, +all: List<&2, String>) -> IO(Unit):
  match xs:
    case "accept" <> +calls <> +cap <> +dir <> rest:
      do IO<Unit>:
        sim.record("bend-episode", all, ["AGENT_RECORDS"])
        S.mkdir(dir)
    case "fixed" <> +calls <> +cap <> +dir <> rest:
      do IO<Unit>:
        sim.record("bend-episode", all, ["AGENT_RECORDS"])
        S.mkdir(dir)
    case _:
      do IO<Unit>:
        +real : String <- sim.real("SIM_EPISODE", "bend-episode")
        sim.pass.run(real, all)

# The parts by name ------------------------------------------------------------------------------

def sim.roles() -> List<&2, String>:
  ["traind", "traind-next", "dense", "nvidia-smi", "clang", "vastai", "ssh", "rsync", "notify-send", "pgrep", "pkill"]

def sim.link.all(rs: List<&2, String>, +self: String, +dir: String) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case r <> t:
      do IO<Unit>:
        o : Lc.LclOut <- Lc.lcl.run(30, "ln", ["-sfn", self, dir ++ "/" ++ r])
        sim.link.all(t, self, dir)

def sim.self.of(m: Maybe<&2, String>, +argv0: String) -> String:
  Maybe.default(&2, String, m, argv0)

# where this binary is: argv[0] itself when it has a slash, else $PATH's
def sim.self.at(slash: Bool, +argv0: String) -> IO(String):
  match slash:
    case True{}:
      S.realpath(argv0)
    case False{}:
      do IO<String>:
        m : Maybe<&2, String> <- S.which(argv0)
        +p : String = sim.self.of(m, argv0)
        S.realpath(p)

def sim.self(+argv0: String) -> IO(String):
  sim.self.at(S.infix(S.b(argv0), [47]), argv0)

def sim.links(+argv0: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +self : String <- sim.self(argv0)
    S.mkdir(dir)
    sim.link.all(sim.roles(), self, dir)
    IO.print("bend-sim: " ++ String.join(sim.roles(), " ") ++ " in " ++ dir ++ " (linked to " ++ self ++ ")")

def sim.is.clang(+r: String) -> Bool:
  String.starts_with(r, "clang")

def sim.part.other(clang: Bool, +r: String, +args: List<&2, String>) -> IO(Unit):
  match clang:
    case True{}:
      sim.clang(args)
    case False{}:
      IO.die(Unit, 2, "bend-sim: no part named " ++ r ++ " (traind, traind-next, dense, nvidia-smi, clang, vastai, ssh, rsync, notify-send, pgrep, pkill, sim-rc; bend-sim links DIR)")

def sim.part(+argv0: String, xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "traind" <> args:
      sim.trainer()
    case "traind-next" <> args:
      sim.trainer()
    case "dense" <> args:
      do IO<Unit>:
        bad : String <- S.env("SIM_GATE_BAD", "")
        sim.dense(Bool.not(String.is_empty(bad)))
    case "nvidia-smi" <> +args:
      sim.smi(args)
    case "vastai" <> +args:
      sim.vast(args)
    case "ssh" <> +args:
      sim.ssh(args)
    case "rsync" <> +args:
      sim.rsync(args)
    case "notify-send" <> +args:
      sim.notify(args)
    case "pgrep" <> +args:
      sim.pg(False{}, args)
    case "pkill" <> +args:
      sim.pg(True{}, args)
    case "sim-rc" <> args:
      sim.rc(args)
    case "scp" <> +args:
      sim.scp(args)
    case "nix" <> +args:
      sim.nix(args, args)
    case "bend" <> args:
      sim.bend(args)
    case "bend-push" <> +args:
      sim.push(args, args)
    case "elan" <> +args:
      sim.tool("elan", args)
    case "lake" <> +args:
      sim.tool("lake", args)
    case "systemctl" <> +args:
      sim.systemctl(args)
    case "sleep" <> +args:
      sim.sleep(args)
    case "deploy" <> args:
      sim.deploy(args)
    case "bend-corpus-v2" <> +args:
      sim.cv2(args, args)
    case "bend-episode" <> +args:
      sim.episode(args, args)
    case "bend-sim" <> "links" <> +dir <> Nil{}:
      sim.links(argv0, dir)
    case "bend-sim" <> +more:
      sim.part(argv0, more)
    case +r <> +args:
      sim.part.other(sim.is.clang(r), r, args)
    case Nil{}:
      IO.die(Unit, 2, "bend-sim: no arguments")

def sim.main(+argv0: String, +args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +dump : String <- S.env("SIM_DUMP", "")
    sim.dump(String.is_empty(dump), dump, argv0 ++ " " ++ sim.join2(args))
    # SIM_DRIVE set: the run drivers' sandbox's parts first (bend/tests/SimDrive.bend)
    drive : String <- S.env("SIM_DRIVE", "")
    Bool.pick(IO(Unit), Bool.and(Bool.not(String.is_empty(drive)), Sd.sdf.known(S.base(argv0))), Sd.sdf.part(S.base(argv0), args), sim.part(argv0, S.base(argv0) <> args))

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    +xs : List<&2, String> = sim.l2(argv)
    sim.main(Maybe.default(&2, String, List.head(&2, String, xs), "bend-sim"), List.drop(&2, String, xs, 1n))
