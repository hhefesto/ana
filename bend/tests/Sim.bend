import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ../Box/Local.bend as Lc

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
#                         directory SIM_VAST_DIR (~/.sim-vast): credit (a number; user.json
#                         replaces the whole answer), instances (a line an instance: ID [STATUS
#                         [SSH_HOST [SSH_PORT]]]), list.fail (the listing fails), destroy.noop
#                         (a destroy answers but does not take); every call is appended to calls
#
#   bend-sim links DIR    those names in DIR, linked to this binary
#   bend-sim ROLE ARGS..  one part by its name
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

def sim.save(yes: Bool, +c: SimCfg, +i: Nat) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      +name = sim.c.out(c) ++ "-step" ++ Nat.show(i) ++ ".checkpoint"
      do IO<Unit>:
        S.write(name, sim.ckpt.text(sim.c.out(c), i, sim.c.bytes(c)))
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

def sim.train.run(+c: SimCfg, +next: Bool, +mask: String, +rdir: String, +size: String) -> IO(Unit):
  +s = sim.c.start(c)
  +e = sim.c.end(c)
  do IO<Unit>:
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

def sim.vast.user(+dir: String) -> IO(Unit):
  do IO<Unit>:
    own : Bool <- S.exists(dir ++ "/user.json")
    +u : List<&2, U32> <- S.read(dir ++ "/user.json")
    +c : List<&2, U32> <- S.read(dir ++ "/credit")
    IO.print(Bool.pick(String, own, S.str(S.chomp(u)), sim.user.json(Lc.lcl.nth(Lc.lcl.words(c), 0n))))

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

# The parts by name ------------------------------------------------------------------------------

def sim.roles() -> List<&2, String>:
  ["traind", "traind-next", "dense", "nvidia-smi", "clang", "vastai"]

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
      IO.die(Unit, 2, "bend-sim: no part named " ++ r ++ " (traind, traind-next, dense, nvidia-smi, clang, vastai; bend-sim links DIR)")

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
    sim.part(argv0, S.base(argv0) <> args)

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    +xs : List<&2, String> = sim.l2(argv)
    sim.main(Maybe.default(&2, String, List.head(&2, String, xs), "bend-sim"), List.drop(&2, String, xs, 1n))
