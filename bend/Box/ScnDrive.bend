import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc
import ./Scenario.bend as Sc

# ScnDrive: the run drivers against a box in a sandbox, old against new
# (2026-10-15, the plan's Phase 4b verification: bend-ops guard, handover,
# move and unit, and run 3's boot-guard.sh, s2-driver.sh and move.sh).
#
#   bend-ops sim drive N DIR      scenario dN (1..9) in DIR/dN-new and, where the old driver runs
#                                 too, DIR/dN-old (each wiped first); `ok`/`FAIL` lines, exit 1 on a FAIL
#   bend-ops sim drive all DIR    every scenario, one after the other
#
# The sandbox is Scenario.bend's (its setup, launch, steps, expectations and
# tools: BEND_SIM, BEND_BOX, SIM_REPO, SIM_CV2), with bend-sim's run-driver
# parts (bend/tests/SimDrive.bend), chosen by SIM_DRIVE=1 in every process's
# environment and the boxes' .sim-env: systemd-run and systemctl over D/units,
# the act round (D/box/bin/bend-corpus-v2, in the act workspace D/box/ws), and
# in that workspace's run/v2/gcroot-deploy-agent/bin/deploy (corpus-v2 s2) and
# run/agent/gcroot-bend-episode/bin/bend-episode (accept, fixed).  The chain is
# always the new one (bend-ops chain); the old drivers are run 3's files from
# SIM_OLD_DRIVERS (run/v3/run3 under the current directory), copied with their
# machine's paths, run 3's step and hosts, the waits and the s2.sh call
# replaced by the sandbox's (sdr.reps.*); nothing under run/ is changed.
#
#   d1  hand-over: the act round still writing at the boundary (stopped, its eplog cut, 81 KB:
#       past a pipe's buffer), accept, fixed, S2 built and appended; the chain runs S2
#   d2  hand-over: the act round finished by itself; the link drops for 3 s during the wait
#   d3  hand-over: S1 dies (DIED): no S2, exit 1
#   d4  hand-over: s2 fails on the box: exit 1, STAGES untouched, the chain ends after S1
#   d5  guard: fresh (3 units started), again (none), a reboot after S2 was appended (chain and
#       watch), DESTROYED (none), `destroy instance` in chain.log (none); guard install (new only)
#   d6  move: old-stop, old-pull (an 81 KB eplog cut to whole frames), resume on a second box,
#       watch, old-check
#   d7  unit: start, start again, list, a reboot, restart, stop, a refused start (new only)
#   d8  run 4 (new only): c1 hot-started by `bend-box again` (plan-base 100); the hand-over waits
#       for global step 130, gives s2 the plan's step 30, REST_STEPS and CTL_OUT, appends c2 and
#       ctl from=out/c1-step130.checkpoint; the chain runs c2, then ctl from the same save
#   d9  run 4 with raw c1 and c2 (EVERY 0, new only): c1's boundary save stays on the box past c2's
#       start until ctl has loaded it, then goes; c2's last, which nothing loads, is pulled
#
# Old against new (d1-d6): the driver's chain.log lines and its output (stamps
# stripped; s2-driver: read as handover:, s2.sh as s2; act-stop's own line left
# out), STAGES, the exit statuses, the box's files by sha256 (the act round,
# accepted/, S2), DEST/out; for the guard the units each step started and their
# caps; for the move each step's units, trainers, pulls and files.  Every name
# starts with `sdr.`.

type SdrRep is Data:
  SdrRep{a: String, b: String}

def sdr.patch(rs: List<&2, SdrRep>, +xs: List<&2, U32>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      xs
    case SdrRep{+a, +b} <> t:
      sdr.patch(t, S.replace(xs, S.b(a), S.b(b)))

def sdr.old.put(m: Maybe<&2, List<&2, U32>>, +dst: String, rs: List<&2, SdrRep>) -> IO(Bool):
  match m:
    case None{}:
      IO.pure(Bool, False{})
    case Some{+xs}:
      do IO<Bool>:
        S.write(dst, sdr.patch(rs, xs))
        o : Lc.LclOut <- Lc.lcl.run(30, "chmod", ["+x", dst])
        return True{}

# an old driver copied with the sandbox's paths and waits; whether it was there
def sdr.old.copy(+src: String, +dst: String, rs: List<&2, SdrRep>) -> IO(Bool):
  do IO<Bool>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(src)
    sdr.old.put(m, dst, rs)

def sdr.home() -> String:
  "/home/hhefesto/src/ana"

# run 3's old drivers name the box's trainer directory formalTransformer (its boxes had
# that name); the sandbox's box has ana/, as a new box does since 2026-10-22, so each old
# driver's copy is pointed there, like its other paths
def sdr.reps.s2(+d: String) -> List<&2, SdrRep>:
  [SdrRep{"cd " ++ sdr.home() ++ "\n", "cd " ++ d ++ "\n"}, SdrRep{"WS=" ++ sdr.home() ++ " ", "WS=" ++ d ++ "/box/ws "},
   SdrRep{"TD=/root/formalTransformer ", "TD=" ++ d ++ "/box/ana "}, SdrRep{"dest=run/v3/run3; stages=run/v3/run3.stages", "dest=dest; stages=stages"},
   SdrRep{"sleep 120", "sleep 1"}, SdrRep{"sleep 30", "sleep 1"}, SdrRep{"sleep 15", "sleep 1"},
   SdrRep{"bash tools/corpus-v2/s2.sh", "run/v2/gcroot-deploy-agent/bin/deploy corpus-v2 s2"}]

def sdr.reps.guard(+d: String) -> List<&2, SdrRep>:
  [SdrRep{"cd " ++ sdr.home() ++ "\n", "cd " ++ d ++ "\n"}, SdrRep{"dest=run/v3/run3\n", "dest=dest\n"},
   SdrRep{"'destroy instance 55567872'", "'destroy instance 4242'"}, SdrRep{"--working-directory=" ++ sdr.home(), "--working-directory=" ++ d},
   SdrRep{"run/v3/run3.stages", "stages"}]

def sdr.reps.move(+d: String) -> List<&2, SdrRep>:
  [SdrRep{"cd " ++ sdr.home() ++ "\n", "cd " ++ d ++ "\n"}, SdrRep{"WS=" ++ sdr.home() ++ "\n", "WS=" ++ d ++ "/box/ws\n"},
   SdrRep{"dest=run/v3/run3;", "dest=dest;"}, SdrRep{"S=4000; B=36696", "S=20; B=60"}, SdrRep{"sleep 15", "sleep 1"}, SdrRep{"sleep 5;", "sleep 1;"},
   SdrRep{"shard-70-fp100m.corpus", "shard-1-fp100m.corpus"}, SdrRep{"push-corpus: shard 71 ", "push-corpus: shard 2 "},
   SdrRep{"formalTransformer", "ana"}]

# old lines as the new tools say the same (form only)
def sdr.reps.lines() -> List<&2, SdrRep>:
  [SdrRep{"s2-driver: ", "handover: "}, SdrRep{"s2.sh failed: ", "s2 failed: "}, SdrRep{"from s2.sh: ", "from s2: "}, SdrRep{"handover: s2.sh: ", "handover: s2: "}]

def sdr.lines(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      x ++ "\n" ++ sdr.lines(t)

def sdr.hd(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      "true"
    case x <> t:
      x

def sdr.tl(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      t

def sdr.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.str(x) <> sdr.strs(t)

# The sandbox ---------------------------------------------------------------------------------------

def sdr.cx(+t: Sc.ScnTools, +base: String, +tag: String) -> Sc.ScnCx:
  +d = base ++ "/" ++ tag
  Sc.scn.cx(t, d, tag, False{}, "./bend-box", ["SIM_DRIVE=1", "SIM_UNITS=" ++ d ++ "/units", "UNIT_STATE=" ++ d ++ "/unitstate",
    "SYSTEMD_USER_DIR=" ++ d ++ "/home/.config/systemd/user", "WAIT=30", "H=root@sim-" ++ tag, "P=2222", "B=30"])

def sdr.ws(+c: Sc.ScnCx) -> String:
  Sc.scn.box(c) ++ "/ws"

# the links and directories the drivers need, the S1 plan (STEPS steps), the config
def sdr.extra(+c: Sc.ScnCx, +steps: String, +cfg: String) -> IO(Unit):
  +d = Sc.scn.d(c)
  +box = Sc.scn.box(c)
  +ws = sdr.ws(c)
  +sim = Sc.scn.sim(c)
  do IO<Unit>:
    Sc.scn.links(sim, d ++ "/bin", ["systemd-run", "systemctl"])
    Sc.scn.links(sim, box ++ "/bin", ["bend-corpus-v2"])
    S.mkdir(ws ++ "/run/agent/gcroot-bend-episode/bin")
    Sc.scn.links(sim, ws ++ "/run/agent/gcroot-bend-episode/bin", ["bend-episode"])
    S.mkdir(ws ++ "/run/v2/gcroot-deploy-agent/bin")
    Sc.scn.links(sim, ws ++ "/run/v2/gcroot-deploy-agent/bin", ["deploy"])
    S.mkdir(ws ++ "/run/v3/act")
    S.mkdir(Sc.scn.ft(c) ++ "/run/v3/S1")
    S.write(Sc.scn.ft(c) ++ "/run/v3/S1/plan-fp100m-b16-windows.tsv", S.b("plan sim " ++ steps ++ "\n"))
    S.mkdir(d ++ "/units")
    S.write(d ++ "/run.cfg", S.b(cfg))

# S1's trainer, as bend-box run starts it (OUT=out/s1, train.log)
def sdr.s1(+c: Sc.ScnCx, +simenv: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    pid : String <- S.background.setsid(Sc.scn.ft(c), Sc.scn.l1(List.append(&2, String, ["SIM_BOX=" ++ Sc.scn.box(c), "PLAN=run/v3/S1/plan-fp100m-b16-windows.tsv",
      "OUT=out/s1"], Sc.scn.simenv(c, simenv))), "train.log", False{}, "./traind", ["+RTS", "--gpu", "48GB", "-RTS"])
    Sc.scn.say(c, "S1's trainer started (pid " ++ pid ++ ")")

# the act round in a session of its own, as `bend-ops act start` leaves it
def sdr.act.start(+c: Sc.ScnCx, +actenv: List<&2, String>) -> IO(Unit):
  +box = Sc.scn.box(c)
  do IO<Unit>:
    pid : String <- S.background.setsid(sdr.ws(c), Sc.scn.l1(List.append(&2, String, ["SIM_BOX=" ++ box, "HOME=" ++ box, "SIM_DRIVE=1"], actenv)),
      sdr.ws(c) ++ "/run/v3/act/r1.log", False{}, box ++ "/bin/bend-corpus-v2", ["agent-act", "run/v2/run2/out/v2-step40000.checkpoint", "run/v3/act/r1"])
    Sc.scn.say(c, "act round started (pid " ++ pid ++ ")")

def sdr.kill.box(+c: Sc.ScnCx, +box: String, names: List<&2, String>) -> IO(Unit):
  match names:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        path : String <- S.env("PATH", "")
        o : Lc.LclOut <- Lc.lcl.run(30, "env", ["SIM_BOX=" ++ box, "SIM_BOX_PATH=" ++ path, Sc.scn.sim(c), "pkill", "-KILL", "-x", n])
        sdr.kill.box(c, box, t)

# a driver run to its end in D, its output into D/NAME.out and status into D/NAME.rc
def sdr.run(+c: Sc.ScnCx, +name: String, +extra: List<&2, String>, +argv: List<&2, String>) -> IO(U32):
  +d = Sc.scn.d(c)
  do IO<U32>:
    Sc.scn.say(c, name ++ ": " ++ String.join(argv, " "))
    +o : S.Out <- S.run(d, Sc.scn.l1(List.append(&2, String, Sc.scn.env(c), extra)), 900, sdr.hd(argv), Sc.scn.l1(sdr.tl(argv)), Nil{})
    S.write(d ++ "/" ++ name ++ ".out", S.Out.text(o))
    S.write(d ++ "/" ++ name ++ ".rc", S.b(U32.show(S.Out.status(o)) ++ "\n"))
    return S.Out.status(o)

def sdr.wait.text.go(fuel: Nat, +path: String, +text: String, hit: Bool) -> IO(Bool):
  match fuel hit:
    case _ True{}:
      IO.pure(Bool, True{})
    case 0n False{}:
      IO.pure(Bool, False{})
    case 1n+f False{}:
      do IO<Bool>:
        IO.sleep(200)
        xs : List<&2, U32> <- S.read(path)
        sdr.wait.text.go(f, path, text, S.infix(xs, S.b(text)))

# wait (200 ms polls, SECS at most) for a file to hold TEXT
def sdr.wait.text(+path: String, +text: String, +secs: Nat) -> IO(Bool):
  sdr.wait.text.go(Nat.mul(secs, 5n), path, text, False{})

# Expectations ---------------------------------------------------------------------------------------

type SdrExp is Data:
  DxRc{name: String, code: String}
  DxIn{rel: String, text: String, there: Bool}
  DxFile{rel: String, there: Bool}

def sdr.exp(e: SdrExp, +c: Sc.ScnCx) -> IO(Sc.ScnRes):
  match e:
    case DxRc{+n, +code}:
      do IO<Sc.ScnRes>:
        +xs : List<&2, U32> <- S.read(Sc.scn.d(c) ++ "/" ++ n ++ ".rc")
        return Sc.ScnRes{n ++ "'s exit status is " ++ code, String.eq(S.str(S.chomp(xs)), code), "it is " ++ S.str(S.chomp(xs))}
    case DxIn{+r, +t, +there}:
      do IO<Sc.ScnRes>:
        +xs : List<&2, U32> <- S.read(Sc.scn.d(c) ++ "/" ++ r)
        return Sc.ScnRes{r ++ Bool.pick(String, there, " has `", " has no `") ++ S.str(S.chomp(S.b(t))) ++ "`", Sc.scn.same(S.infix(xs, S.b(t)), there), ""}
    case DxFile{+r, +there}:
      do IO<Sc.ScnRes>:
        h : Bool <- S.exists(Sc.scn.d(c) ++ "/" ++ r)
        return Sc.ScnRes{r ++ Bool.pick(String, there, " is there", " is not there"), Sc.scn.same(h, there), ""}

def sdr.exps(es: List<&2, SdrExp>, +c: Sc.ScnCx) -> IO(List<&2, Sc.ScnRes>):
  match es:
    case Nil{}:
      IO.pure(List<&2, Sc.ScnRes>, Nil{})
    case e <> t:
      do IO<List<&2, Sc.ScnRes>>:
        r : Sc.ScnRes <- sdr.exp(e, c)
        rs : List<&2, Sc.ScnRes> <- sdr.exps(t, c)
        return r <> rs

# Old against new ------------------------------------------------------------------------------------

# an old line renamed, and the sandbox's own directory D (each run has its own) as `D`
def sdr.rename(+old: Bool, +d: String, +l: List<&2, U32>) -> List<&2, U32>:
  S.replace(Bool.pick(List<&2, U32>, old, sdr.patch(sdr.reps.lines(), l), l), S.b(d), S.b("D"))

# the lines with TAG (after the stamp), stamps out, an old line renamed
def sdr.tagged.go(ls: List<&2, List<&2, U32>>, +tag: String, +old: Bool, +d: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l0 <> t:
      +l = sdr.rename(old, d, Sc.scn.unstamp(l0))
      +rest = sdr.tagged.go(t, tag, old, d)
      Bool.pick(List<&2, String>, S.prefix(l, S.b(tag)), S.str(l) <> rest, rest)

def sdr.tagged(+xs: List<&2, U32>, +tag: String, +old: Bool, +d: String) -> List<&2, String>:
  sdr.tagged.go(S.split.lines(xs), tag, old, d)

# a driver's output lines, stamps out, renamed; left out as form only: blank lines, act-stop's
# own line and `handover: stopped` (new), and ssh's refusals while the link is down (the old
# driver passed ssh's stderr on; Remote.bend retries without printing them)
def sdr.out.skip(+l: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(S.prefix(l, S.b("act-stop: ")), Nat.is_eq(S.len(l), 0n)), Bool.or(S.eq(l, S.b("handover: stopped")), S.prefix(l, S.b("ssh: connect to host "))))

def sdr.out.go(ls: List<&2, List<&2, U32>>, +old: Bool, +d: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l0 <> t:
      +l = sdr.rename(old, d, Sc.scn.unstamp(l0))
      +rest = sdr.out.go(t, old, d)
      Bool.pick(List<&2, String>, sdr.out.skip(l), rest, S.str(l) <> rest)

def sdr.out.lines(+xs: List<&2, U32>, +old: Bool, +d: String) -> List<&2, String>:
  sdr.out.go(S.split.lines(xs), old, d)

def sdr.sha.show(m: Maybe<&2, List<&2, U32>>) -> String:
  match m:
    case Some{x}:
      S.str(List.take(&2, U32, x, 16n))
    case None{}:
      "absent"

def sdr.same(+a: Maybe<&2, List<&2, U32>>, +b: Maybe<&2, List<&2, U32>>) -> Bool:
  match a b:
    case Some{+x} Some{+y}:
      S.eq(x, y)
    case None{} None{}:
      True{}
    case _ _:
      False{}

def sdr.cmp.file(+cn: Sc.ScnCx, +co: Sc.ScnCx, +rel: String) -> IO(Sc.ScnRes):
  do IO<Sc.ScnRes>:
    +a : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(Sc.scn.d(cn) ++ "/" ++ rel)
    +b : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(Sc.scn.d(co) ++ "/" ++ rel)
    return Sc.ScnRes{rel ++ ": the same bytes (or absent in both)", sdr.same(a, b), "new " ++ sdr.sha.show(a) ++ ", old " ++ sdr.sha.show(b)}

def sdr.cmp.files(rs: List<&2, String>, +cn: Sc.ScnCx, +co: Sc.ScnCx) -> IO(List<&2, Sc.ScnRes>):
  match rs:
    case Nil{}:
      IO.pure(List<&2, Sc.ScnRes>, Nil{})
    case +r <> t:
      do IO<List<&2, Sc.ScnRes>>:
        x : Sc.ScnRes <- sdr.cmp.file(cn, co, r)
        xs : List<&2, Sc.ScnRes> <- sdr.cmp.files(t, cn, co)
        return x <> xs

def sdr.cmp.text(+what: String, +a: List<&2, U32>, +b: List<&2, U32>) -> Sc.ScnRes:
  Sc.ScnRes{what, S.eq(a, b), "new `" ++ S.str(S.chomp(a)) ++ "`, old `" ++ S.str(S.chomp(b)) ++ "`"}

def sdr.cmp.same(+what: String, +rel: String, +cn: Sc.ScnCx, +co: Sc.ScnCx) -> IO(Sc.ScnRes):
  do IO<Sc.ScnRes>:
    +a : List<&2, U32> <- S.read(Sc.scn.d(cn) ++ "/" ++ rel)
    +b : List<&2, U32> <- S.read(Sc.scn.d(co) ++ "/" ++ rel)
    return sdr.cmp.text(what, S.chomp(a), S.chomp(b))

# The hand-over (d1-d4) -----------------------------------------------------------------------------

def sdr.cfg.hand(+d: String, +tag: String) -> String:
  sdr.lines(["# the hand-over in a sandbox (bend/Box/ScnDrive.bend)", "host root@sim-" ++ tag, "port 2222", "instance 4242", "dest dest", "stages stages",
    "trainer-dir " ++ d ++ "/box/ana", "trainer-log train.log", "box-driver ./bend-box", "boundary 30", "handover-poll 1",
    "act-ws " ++ d ++ "/box/ws", "act-box-bin " ++ d ++ "/box/bin", "act-dir run/v3/act/r1", "act-stop-wait 1",
    "s2-from run/v3/S1", "s2-out run/v3/S2", "s2-log run/v3/s2.log", "s2-every 5000", "s2-stage s2"])

type SdrHand is Data:
  SdrHand{id: String, about: String, simenv: List<&2, String>, actenv: List<&2, String>, steps: List<&2, Sc.ScnStep>, exps: List<&2, Sc.ScnExp>, dexps: List<&2, SdrExp>}

def sdr.h.id(+s: SdrHand) -> String:
  match s:
    case SdrHand{i, a, se, ae, sp, ex, dx}:
      i

def sdr.driver.argv(+c: Sc.ScnCx, +old: Bool) -> List<&2, String>:
  Bool.pick(List<&2, String>, old, ["bash", Sc.scn.d(c) ++ "/old-s2-driver.sh"], [Sc.scn.self(c), "handover", Sc.scn.d(c) ++ "/run.cfg"])

def sdr.driver.pat(+c: Sc.ScnCx, +old: Bool) -> String:
  Bool.pick(String, old, "^bash " ++ Sc.scn.d(c) ++ "/old-s2-driver.sh", "^" ++ Sc.scn.self(c) ++ " handover " ++ Sc.scn.d(c) ++ "/")

def sdr.cleanup(+c: Sc.ScnCx, +old: Bool) -> IO(Unit):
  do IO<Unit>:
    Sc.scn.cleanup(c)
    Sc.scn.box.kill(c, ["bend-corpus-v2"])
    Sc.scn.quiet.kill(c, sdr.driver.pat(c, old))

def sdr.hand.one(+c: Sc.ScnCx, +old: Bool, +s: SdrHand, +olds: String) -> IO(List<&2, Sc.ScnRes>):
  match s:
    case SdrHand{+id, +about, +se, +ae, +sp, +ex, +dx}:
      +d = Sc.scn.d(c)
      do IO<List<&2, Sc.ScnRes>>:
        Sc.scn.say(c, "scenario d" ++ id ++ ": " ++ about)
        Sc.scn.setup(c, Sc.Scn{"d" ++ id, about, "s1 traind 5000\n", ["", "", ""], List.append(&2, String, se, ["SIM_DRIVE=1"]), Nil{}, Nil{}, False{}, Nil{}, Nil{}})
        sdr.extra(c, "30", sdr.cfg.hand(d, Sc.scn.tag(c)))
        +got : Bool <- sdr.old.copy(olds ++ "/s2-driver.sh", d ++ "/old-s2-driver.sh", sdr.reps.s2(d))
        sdr.s1(c, se)
        sdr.act.start(c, ae)
        Sc.scn.launch(c, "watch", Sc.scn.watch.argv(c))
        Sc.scn.launch(c, "chain", Sc.scn.chain.argv(c))
        Sc.scn.launch(c, "driver", sdr.driver.argv(c, old))
        fails : List<&2, String> <- Sc.scn.steps(sp, c)
        +ended : Bool <- Sc.scn.wait(d ++ "/chain.rc", 600n)
        +dend : Bool <- Sc.scn.wait(d ++ "/driver.rc", 120n)
        gone : Bool <- S.exists(Sc.scn.dest(c) ++ "/DESTROYED")
        w : Bool <- Bool.pick(IO(Bool), gone, Sc.scn.wait(d ++ "/watch.rc", 20n), IO.pure(Bool, True{}))
        sdr.cleanup(c, old)
        rs : List<&2, Sc.ScnRes> <- Bool.pick(IO(List<&2, Sc.ScnRes>), old, IO.pure(List<&2, Sc.ScnRes>, Nil{}), Sc.scn.exps(ex, c))
        ds : List<&2, Sc.ScnRes> <- Bool.pick(IO(List<&2, Sc.ScnRes>), old, IO.pure(List<&2, Sc.ScnRes>, Nil{}), sdr.exps(dx, c))
        Sc.scn.say(c, "done")
        return Sc.scn.tagged(Sc.scn.tag(c), List.concat(&2, Sc.ScnRes, [[Sc.ScnRes{"the chain ended by itself", ended, ""}, Sc.ScnRes{"the driver ended by itself", dend, ""},
          Sc.ScnRes{"the old driver is there (SIM_OLD_DRIVERS)", Bool.or(Bool.not(old), got), olds}], Sc.scn.fails(fails), rs, ds]))

def sdr.kinds() -> List<&2, String>:
  ["agda-act", "agda-fix", "bend-act", "bend-fix", "haskell-act", "haskell-fix", "lean-act", "lean-fix", "nix-act", "nix-fix"]

def sdr.accepted(ks: List<&2, String>) -> List<&2, String>:
  match ks:
    case Nil{}:
      Nil{}
    case k <> t:
      ("box/ws/run/v3/act/r1/accepted/" ++ k ++ "/transcripts.train.nul") <> sdr.accepted(t)

def sdr.box.files() -> List<&2, String>:
  List.append(&2, String, ["box/ws/run/v3/act/r1/episodes.eplog", "box/ws/run/v3/act/r1/episodes.eplog.whole-before-cut", "box/ws/run/v3/act/r1.accept.log",
    "box/ana/run/v3/S2/plan-fp100m-b16-windows.tsv", "box/ana/run/v3/S2/stage.env"], sdr.accepted(sdr.kinds()))

def sdr.events.write(+c: Sc.ScnCx, +xs: List<&2, String>, +ys: List<&2, String>) -> IO(Unit):
  S.write(Sc.scn.d(c) ++ "/events.txt", S.b(sdr.lines(xs) ++ "-- output --\n" ++ sdr.lines(ys)))

def sdr.cmp.hand(+cn: Sc.ScnCx, +co: Sc.ScnCx) -> IO(List<&2, Sc.ScnRes>):
  do IO<List<&2, Sc.ScnRes>>:
    +ln : List<&2, U32> <- S.read(Sc.scn.dest(cn) ++ "/chain.log")
    +lo : List<&2, U32> <- S.read(Sc.scn.dest(co) ++ "/chain.log")
    +on : List<&2, U32> <- S.read(Sc.scn.d(cn) ++ "/driver.out")
    +oo : List<&2, U32> <- S.read(Sc.scn.d(co) ++ "/driver.out")
    +en : List<&2, String> = sdr.tagged(ln, "handover: ", False{}, Sc.scn.d(cn))
    +eo : List<&2, String> = sdr.tagged(lo, "handover: ", True{}, Sc.scn.d(co))
    +un : List<&2, String> = sdr.out.lines(on, False{}, Sc.scn.d(cn))
    +uo : List<&2, String> = sdr.out.lines(oo, True{}, Sc.scn.d(co))
    sdr.events.write(cn, en, un)
    sdr.events.write(co, eo, uo)
    st : Sc.ScnRes <- sdr.cmp.same("STAGES", "stages", cn, co)
    rc : Sc.ScnRes <- sdr.cmp.same("the driver's exit status", "driver.rc", cn, co)
    m1 : Sc.ScnRes <- Sc.scn.cmp.mark(cn, co, "DESTROYED", False{})
    m2 : Sc.ScnRes <- Sc.scn.cmp.mark(cn, co, "DIED", True{})
    f1 : Sc.ScnRes <- Sc.scn.cmp.files("DEST/out", Sc.scn.dest(cn) ++ "/out", Sc.scn.dest(co) ++ "/out")
    fs : List<&2, Sc.ScnRes> <- sdr.cmp.files(sdr.box.files(), cn, co)
    return List.append(&2, Sc.ScnRes, [Sc.scn.cmp.lines("the driver's chain.log lines", en, eo), Sc.scn.cmp.lines("the driver's output", un, uo), st, rc, m1, m2, f1], fs)

def sdr.hand(+t: Sc.ScnTools, +base: String, +olds: String, +s: SdrHand) -> IO(List<&2, Sc.ScnRes>):
  +i = sdr.h.id(s)
  +cn = sdr.cx(t, base, "d" ++ i ++ "-new")
  +co = sdr.cx(t, base, "d" ++ i ++ "-old")
  do IO<List<&2, Sc.ScnRes>>:
    ch : Chan(List<&2, Sc.ScnRes>) <- IO.fork(List<&2, Sc.ScnRes>, sdr.hand.one(co, True{}, s, olds))
    rn : List<&2, Sc.ScnRes> <- sdr.hand.one(cn, False{}, s, olds)
    ro : List<&2, Sc.ScnRes> <- IO.join(List<&2, Sc.ScnRes>, ch)
    cs : List<&2, Sc.ScnRes> <- sdr.cmp.hand(cn, co)
    return List.concat(&2, Sc.ScnRes, [rn, ro, Sc.scn.tagged("d" ++ i ++ " old = new", cs)])

def sdr.stage.s2() -> String:
  "s2 traind-next 5000 run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m"

def sdr.acc.line(+n: String) -> String:
  "handover: accepted: agda-act:" ++ n ++ " agda-fix:" ++ n ++ " bend-act:" ++ n ++ " bend-fix:" ++ n ++ " haskell-act:" ++ n ++ " haskell-fix:" ++ n
    ++ " lean-act:" ++ n ++ " lean-fix:" ++ n ++ " nix-act:" ++ n ++ " nix-fix:" ++ n ++ " \n"

def sdr.d1() -> SdrHand:
  SdrHand{"1", "hand-over: the act round still writing at the boundary is stopped, its 81 KB eplog cut to whole frames; accept, fixed; S2 built, appended; the chain runs it",
    Nil{}, Nil{}, Nil{},
    [Sc.ExRc{"0"}, Sc.ExMark{"DESTROYED", True{}}, Sc.ExMark{"DIED", False{}}, Sc.ExStarts{2n},
     Sc.ExLog{"] handover: stopping act round run/v3/act/r1: 40 episodes so far\n", True{}},
     Sc.ExLog{"] " ++ sdr.acc.line("4"), True{}},
     Sc.ExLog{"] handover: appended to stages: " ++ sdr.stage.s2() ++ "\n", True{}},
     Sc.ExLog{"] stage s2: from out/s1-step30.checkpoint on run/v3/S2/plan-fp100m-b16-windows.tsv\n", True{}},
     Sc.ExLog{"] handover: S2 stage.env: NLR=1e-4 NWARM=10 \n", True{}},
     Sc.ExBoxFile{"run/v3/S2/stage.env"}, Sc.ExOut{["s1-step30.checkpoint", "s2-step60.checkpoint"]}],
    [DxRc{"driver", "0"}, DxIn{"stages", sdr.stage.s2() ++ "\n", True{}}, DxFile{"box/ws/run/v3/act/r1/episodes.eplog.whole-before-cut", True{}},
     DxIn{"driver.out", "cut run/v3/act/r1/episodes.eplog to ", True{}}, DxIn{"driver.out", "\n40 whole episodes in run/v3/act/r1/episodes.eplog\n", True{}},
     DxIn{"driver.out", "\nact round stopped\n", True{}}]}

def sdr.d2() -> SdrHand:
  SdrHand{"2", "hand-over: the act round finished by itself (20 episodes); the link drops for 3 s while the hand-over waits",
    Nil{}, ["SIM_ACT_FINISH=1", "SIM_ACT_EPISODES=20"],
    [Sc.scn.at("] train.log running: ", Sc.AcLink{True{}}), Sc.ScnStep{Sc.TrSleep{3000n}, Sc.AcLink{False{}}}],
    [Sc.ExRc{"0"}, Sc.ExMark{"DESTROYED", True{}}, Sc.ExStarts{2n},
     Sc.ExLog{"] handover: act round run/v3/act/r1 had finished by itself\n", True{}}, Sc.ExLog{"stopping act round", False{}},
     Sc.ExLog{"] " ++ sdr.acc.line("2"), True{}}, Sc.ExLog{"] handover: appended to stages: " ++ sdr.stage.s2() ++ "\n", True{}}],
    [DxRc{"driver", "0"}, DxFile{"box/ws/run/v3/act/r1/episodes.eplog.whole-before-cut", False{}},
     DxIn{"driver.out", "\n20 whole episodes in run/v3/act/r1/episodes.eplog\n", True{}}]}

def sdr.d3() -> SdrHand:
  SdrHand{"3", "hand-over: S1's trainer dies at step 17 (the chain's DIED): no S2, exit 1; the chain scores, pulls and destroys",
    ["SIM_DIE_AT=17"], Nil{}, Nil{},
    [Sc.ExRc{"0"}, Sc.ExMark{"DIED", True{}}, Sc.ExMark{"DESTROYED", True{}}, Sc.ExLog{"] handover: a stage died (", True{}}, Sc.ExLog{"stage s2:", False{}}],
    [DxRc{"driver", "1"}, DxIn{"stages", "s2 ", False{}}]}

def sdr.d4() -> SdrHand:
  SdrHand{"4", "hand-over: s2 fails on the box (run 3's bend-windows refusal): exit 1, STAGES untouched; the chain ends after S1",
    ["SIM_S2_FAIL=1"], Nil{}, Nil{},
    [Sc.ExRc{"0"}, Sc.ExMark{"DESTROYED", True{}}, Sc.ExStarts{1n}, Sc.ExLog{"] handover: s2 failed: ", True{}},
     Sc.ExLog{"does not fit a window of 2046", True{}}, Sc.ExLog{"stage s2:", False{}}],
    [DxRc{"driver", "1"}, DxIn{"stages", "s2 ", False{}}]}

# The guard (d5) ------------------------------------------------------------------------------------

def sdr.cfg.guard(+d: String, +tag: String, +self: String) -> String:
  sdr.lines(["# the guard in a sandbox (bend/Box/ScnDrive.bend)", "host root@sim-" ++ tag, "port 2222", "instance 4242", "dest dest", "stages stages",
    "ops " ++ self, "unit chain ft-fp-chain-v3 2G fp-chain.out", "unit watch ft-credit-watch-v3 2G credit-watch.out", "unit handover ft-v3-s2 2G s2-driver.out",
    "s2-stage s2", "guard-unit ft-run3-guard", "env POLL=1 WAIT=30"])

def sdr.unit.of(ws: List<&2, String>) -> String:
  match ws:
    case Nil{}:
      ""
    case +w <> t:
      Bool.pick(String, String.starts_with(w, "--unit="), String.drop(w, 7n), sdr.unit.of(t))

def sdr.mem.of(ws: List<&2, String>) -> String:
  match ws:
    case Nil{}:
      ""
    case +w <> t:
      Bool.pick(String, String.starts_with(w, "MemoryMax="), w, sdr.mem.of(t))

def sdr.words(+l: List<&2, U32>) -> List<&2, String>:
  sdr.strs(Lc.lcl.words(l))

# the units the systemd-run calls in a calls file started: `NAME MemoryMax=X` each, sorted
def sdr.started.go(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +ws = sdr.words(l)
      +rest = sdr.started.go(t)
      Bool.pick(List<&2, List<&2, U32>>, S.prefix(l, S.b("systemd-run ")), S.b(sdr.unit.of(ws) ++ " " ++ sdr.mem.of(ws)) <> rest, rest)

def sdr.started(+xs: List<&2, U32>) -> String:
  String.join(sdr.strs(Lc.lcl.sort(sdr.started.go(S.split.lines(xs)))), ", ")

def sdr.reboot.go(ns: List<&2, List<&2, U32>>, +dir: String) -> IO(Unit):
  match ns:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        Bool.pick(IO(Unit), S.suffix(n, S.b(".active")), S.rm(dir ++ "/" ++ S.str(n)), IO.pure(Unit, Unit{}))
        sdr.reboot.go(t, dir)

# a reboot: every transient unit gone
def sdr.reboot(+c: Sc.ScnCx) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(Sc.scn.d(c) ++ "/units")
    sdr.reboot.go(Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{}), Sc.scn.d(c) ++ "/units")

def sdr.guard.argv(+c: Sc.ScnCx, +old: Bool) -> List<&2, String>:
  Bool.pick(List<&2, String>, old, ["bash", Sc.scn.d(c) ++ "/old-boot-guard.sh"], [Sc.scn.self(c), "guard", Sc.scn.d(c) ++ "/run.cfg"])

# one guard run: the units it started (from the calls), its chain.log lines; the calls kept by step
def sdr.guard.step(+c: Sc.ScnCx, +old: Bool, +step: String) -> IO(String):
  +d = Sc.scn.d(c)
  do IO<String>:
    +st : U32 <- sdr.run(c, "guard-" ++ step, Nil{}, sdr.guard.argv(c, old))
    +xs : List<&2, U32> <- S.read(d ++ "/units/calls")
    S.write(d ++ "/units/calls." ++ step, xs)
    S.write(d ++ "/units/calls", Nil{})
    return step ++ ": exit " ++ U32.show(st) ++ "; started " ++ sdr.started(xs)

def sdr.guard.one(+c: Sc.ScnCx, +old: Bool, +olds: String) -> IO(List<&2, String>):
  +d = Sc.scn.d(c)
  do IO<List<&2, String>>:
    Sc.scn.setup(c, Sc.Scn{"d5", "guard", "s1 traind 5000\n", ["", "", ""], ["SIM_DRIVE=1"], Nil{}, Nil{}, False{}, Nil{}, Nil{}})
    sdr.extra(c, "30", sdr.cfg.guard(d, Sc.scn.tag(c), Sc.scn.self(c)))
    S.write(d ++ "/units/calls", Nil{})
    +got : Bool <- sdr.old.copy(olds ++ "/boot-guard.sh", d ++ "/old-boot-guard.sh", sdr.reps.guard(d))
    +a : String <- sdr.guard.step(c, old, "a-fresh")
    +b : String <- sdr.guard.step(c, old, "b-again")
    sdr.reboot(c)
    S.add(d ++ "/stages", S.b(sdr.stage.s2() ++ "\n"))
    +r : String <- sdr.guard.step(c, old, "c-reboot-after-s2")
    sdr.reboot(c)
    S.write(Sc.scn.dest(c) ++ "/DESTROYED", S.b("[2026-10-13 23:48:00 UTC-6] destroyed\n"))
    +e : String <- sdr.guard.step(c, old, "d-destroyed")
    S.rm(Sc.scn.dest(c) ++ "/DESTROYED")
    S.add(Sc.scn.dest(c) ++ "/chain.log", S.b("[2026-10-13 23:48:00 UTC-6] destroy instance 4242\n"))
    +f : String <- sdr.guard.step(c, old, "e-destroy-said")
    return [Bool.pick(String, got, "the old driver is there", "NO OLD DRIVER (SIM_OLD_DRIVERS)"), a, b, r, e, f]

def sdr.res.lines(+what: String, +xs: List<&2, String>, +want: List<&2, String>) -> Sc.ScnRes:
  Sc.ScnRes{what, Sc.scn.strs.eq(xs, want), "it is: " ++ String.join(xs, " | ")}

def sdr.guard.new(+c: Sc.ScnCx) -> IO(List<&2, Sc.ScnRes>):
  +d = Sc.scn.d(c)
  do IO<List<&2, Sc.ScnRes>>:
    +l : U32 <- sdr.run(c, "unit-list", Nil{}, [Sc.scn.self(c), "unit", "list"])
    +i : U32 <- sdr.run(c, "guard-install", Nil{}, [Sc.scn.self(c), "guard", d ++ "/run.cfg", "install"])
    +calls : List<&2, U32> <- S.read(d ++ "/units/calls")
    es : List<&2, Sc.ScnRes> <- sdr.exps([DxIn{"unitstate/ft-fp-chain-v3.line", " chain root@sim-d5-new 2222 4242 dest stages\n", True{}},
      DxIn{"unitstate/ft-fp-chain-v3.line", "systemd-run --user --unit=ft-fp-chain-v3 -p MemoryMax=2G -p OOMPolicy=continue --working-directory=" ++ d
        ++ " -p StandardOutput=append:" ++ d ++ "/fp-chain.out -p StandardError=append:" ++ d ++ "/fp-chain.out --setenv=POLL=1 --setenv=WAIT=30 -- ", True{}},
      DxIn{"unitstate/ft-v3-s2.line", " handover " ++ d ++ "/run.cfg\n", True{}}, DxIn{"unitstate/starts.log", "] start ft-credit-watch-v3\n", True{}},
      DxIn{"unit-list.out", "ft-fp-chain-v3\tinactive\tsystemd-run ", True{}}, DxIn{"unit-list.out", "ft-v3-s2\tinactive\t", True{}},
      DxRc{"guard-install", "0"}, DxIn{"home/.config/systemd/user/ft-run3-guard.service", "\nExecStart=" ++ Sc.scn.self(c) ++ " guard " ++ d ++ "/run.cfg\n", True{}},
      DxIn{"home/.config/systemd/user/ft-run3-guard.service", "\nWorkingDirectory=" ++ d ++ "\n", True{}},
      DxIn{"units/calls", "systemctl --user enable ft-run3-guard.service\n", True{}}, DxIn{"dest/chain.log", "] boot-guard: restarted ft-v3-s2 after a boot\n", True{}}], c)
    return es

def sdr.d5(+t: Sc.ScnTools, +base: String, +olds: String) -> IO(List<&2, Sc.ScnRes>):
  +cn = sdr.cx(t, base, "d5-new")
  +co = sdr.cx(t, base, "d5-old")
  do IO<List<&2, Sc.ScnRes>>:
    Sc.scn.say(cn, "scenario d5: the guard: fresh, again, a reboot after S2 was appended, DESTROYED, `destroy instance` said; install")
    +xn : List<&2, String> <- sdr.guard.one(cn, False{}, olds)
    +xo : List<&2, String> <- sdr.guard.one(co, True{}, olds)
    es : List<&2, Sc.ScnRes> <- sdr.guard.new(cn)
    +ln : List<&2, U32> <- S.read(Sc.scn.dest(cn) ++ "/chain.log")
    +lo : List<&2, U32> <- S.read(Sc.scn.dest(co) ++ "/chain.log")
    S.write(Sc.scn.d(cn) ++ "/events.txt", S.b(sdr.lines(xn)))
    S.write(Sc.scn.d(co) ++ "/events.txt", S.b(sdr.lines(xo)))
    return List.concat(&2, Sc.ScnRes, [
      [sdr.res.lines("d5-new: the units each step started", xn, ["the old driver is there", "a-fresh: exit 0; started ft-credit-watch-v3 MemoryMax=2G, ft-fp-chain-v3 MemoryMax=2G, ft-v3-s2 MemoryMax=2G",
        "b-again: exit 0; started ", "c-reboot-after-s2: exit 0; started ft-credit-watch-v3 MemoryMax=2G, ft-fp-chain-v3 MemoryMax=2G", "d-destroyed: exit 0; started ",
        "e-destroy-said: exit 0; started "])],
      Sc.scn.tagged("d5-new", es),
      [Sc.scn.cmp.lines("d5 old = new: the units each step started, their caps, the exit statuses", xn, xo),
       Sc.scn.cmp.lines("d5 old = new: the guard's chain.log lines", sdr.tagged(ln, "boot-guard: ", False{}, Sc.scn.d(cn)), sdr.tagged(lo, "boot-guard: ", True{}, Sc.scn.d(co)))]])

# The move (d6) -------------------------------------------------------------------------------------

def sdr.cfg.move(+d: String, +tag: String, +self: String) -> String:
  sdr.lines(["# the move in a sandbox (bend/Box/ScnDrive.bend): the old box D/box, the new D/newbox", "host root@sim-" ++ tag ++ "-new", "port 2222", "instance 4343",
    "old-host root@sim-" ++ tag ++ "-old", "old-port 2222", "old-instance 4242", "dest dest", "stages stages", "ops " ++ self,
    "trainer-dir ana", "trainer-log train.log", "box-driver ./bend-box", "act-ws " ++ d ++ "/box/ws", "act-dir run/v3/act/r1", "act-stop-wait 1",
    "move-name s1", "move-step 20", "move-to 60", "move-plan run/v3/S1/plan-fp100m-b16-windows.tsv", "move-run run/v3/S1", "move-shard fp100m",
    "move-need run/v3/S1/plan-fp100m-b16-windows.tsv run/v3/S1/shard-1-fp100m.corpus", "move-pushed dest/stage2.log 2", "move-gate gate.out",
    "move-save 1000", "move-trainers traind", "unit chain ft-fp-chain-v3 2G", "unit watch ft-credit-watch-v3 2G", "stop-units ft-v3-act1", "env POLL=1"])

def sdr.newbox(+c: Sc.ScnCx) -> IO(Unit):
  +nb = Sc.scn.d(c) ++ "/newbox"
  +ft = nb ++ "/ana"
  +sim = Sc.scn.sim(c)
  do IO<Unit>:
    S.mkdir(nb ++ "/bin")
    S.mkdir(ft ++ "/out")
    S.mkdir(ft ++ "/run/v3/S1")
    Sc.scn.links(sim, nb ++ "/bin", ["nvidia-smi", "pgrep", "pkill"])
    Sc.scn.links(sim, ft, ["traind", "traind-next", "dense"])
    Sc.scn.links(Sc.scn.bbox(c), ft, ["bend-box"])
    Sc.scn.copy.live(Sc.scn.repo(c) ++ "/bend/gpu/fp.sh", ft ++ "/fp.sh")
    S.write(ft ++ "/run/v3/S1/plan-fp100m-b16-windows.tsv", S.b("plan sim 60\n"))
    S.write(ft ++ "/run/v3/S1/shard-1-fp100m.corpus", S.b("sim\n"))
    S.write(ft ++ "/gate.out", S.b("G2: PASS (bend-sim)\n"))
    S.write(nb ++ "/.sim-env", S.b(sdr.lines(["SIM_SLEEP_MS=150", "SIM_STARTS=" ++ nb ++ "/.sim-starts", "NLR=1e-4", "SIM_DRIVE=1"])))
    S.write(Sc.scn.dest(c) ++ "/stage2.log", S.b("push-corpus: shard 1 landed\npush-corpus: shard 2 landed\n"))

def sdr.move.argv(+c: Sc.ScnCx, +old: Bool, +step: String) -> List<&2, String>:
  Bool.pick(List<&2, String>, old, ["bash", Sc.scn.d(c) ++ "/old-move.sh", step], [Sc.scn.self(c), "move", Sc.scn.d(c) ++ "/run.cfg", step])

def sdr.move.step(+c: Sc.ScnCx, +old: Bool, +step: String, +box: String) -> IO(String):
  do IO<String>:
    +st : U32 <- sdr.run(c, "move-" ++ step, ["SIM_BOX_HOME=" ++ box], sdr.move.argv(c, old, step))
    return step ++ ": exit " ++ U32.show(st)

def sdr.count.box(+c: Sc.ScnCx, +box: String, +name: String) -> IO(String):
  do IO<String>:
    path : String <- S.env("PATH", "")
    +o : Lc.LclOut <- Lc.lcl.run(30, "env", ["SIM_BOX=" ++ box, "SIM_BOX_PATH=" ++ path, Sc.scn.sim(c), "pgrep", "-c", "-x", name])
    return S.str(S.chomp(Lc.lcl.out(o)))

def sdr.state(+c: Sc.ScnCx, +n: String) -> IO(String):
  do IO<String>:
    a : Bool <- S.exists(Sc.scn.d(c) ++ "/units/" ++ n ++ ".active")
    return n ++ Bool.pick(String, a, " active", " inactive")

def sdr.listing(+dir: String) -> IO(String):
  do IO<String>:
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(dir)
    return String.join(sdr.strs(Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{})), " ")

# the move, step by step; what each step left (units, trainers, files) as lines to compare
def sdr.move.one(+c: Sc.ScnCx, +old: Bool, +olds: String) -> IO(List<&2, String>):
  +d = Sc.scn.d(c)
  +ob = d ++ "/box"
  +nb = d ++ "/newbox"
  do IO<List<&2, String>>:
    Sc.scn.setup(c, Sc.Scn{"d6", "move", "s1 traind 5000\n", ["", "", ""], ["SIM_SAVE_EVERY=20", "SIM_SLEEP_MS=500", "SIM_DRIVE=1"], Nil{}, Nil{}, False{}, Nil{}, Nil{}})
    sdr.extra(c, "60", sdr.cfg.move(d, Sc.scn.tag(c), Sc.scn.self(c)))
    sdr.newbox(c)
    +got : Bool <- sdr.old.copy(olds ++ "/move.sh", d ++ "/old-move.sh", sdr.reps.move(d))
    S.write(d ++ "/units/ft-fp-chain-v3.active", Nil{})
    S.write(d ++ "/units/ft-credit-watch-v3.active", Nil{})
    S.write(d ++ "/units/ft-v3-act1.active", Nil{})
    sdr.s1(c, ["SIM_SAVE_EVERY=20", "SIM_SLEEP_MS=500"])
    sdr.act.start(c, Nil{})
    +saved : Bool <- sdr.wait.text(Sc.scn.ft(c) ++ "/train.log", "saved out/s1-step20.checkpoint", 120n)
    +a : String <- sdr.move.step(c, old, "old-stop", ob)
    +a1 : String <- sdr.state(c, "ft-fp-chain-v3")
    +a2 : String <- sdr.state(c, "ft-credit-watch-v3")
    +a3 : String <- sdr.state(c, "ft-v3-act1")
    +a4 : String <- sdr.count.box(c, ob, "traind")
    +a5 : String <- sdr.count.box(c, ob, "bend-corpus-v2")
    +b : String <- sdr.move.step(c, old, "old-pull", ob)
    +b1 : String <- sdr.listing(Sc.scn.dest(c) ++ "/out")
    +b2 : String <- sdr.listing(Sc.scn.dest(c) ++ "/oldbox")
    +b3 : String <- sdr.listing(Sc.scn.dest(c) ++ "/rescue/act/r1")
    +r : String <- sdr.move.step(c, old, "resume", nb)
    +done : Bool <- sdr.wait.text(nb ++ "/ana/train.log", "done at step 60", 120n)
    +r1 : String <- sdr.listing(nb ++ "/ana/out")
    +w : String <- sdr.move.step(c, old, "watch", d)
    +w1 : String <- sdr.state(c, "ft-fp-chain-v3")
    +w2 : String <- sdr.state(c, "ft-credit-watch-v3")
    +k : String <- sdr.move.step(c, old, "old-check", ob)
    sdr.kill.box(c, ob, ["traind", "traind-next", "bend-box", "bend-corpus-v2"])
    sdr.kill.box(c, nb, ["traind", "traind-next", "bend-box"])
    return [Bool.pick(String, got, "the old driver is there", "NO OLD DRIVER (SIM_OLD_DRIVERS)"), "S1 saved step 20 on the old box: " ++ Bool.pick(String, saved, "yes", "no"),
      a, "  units: " ++ a1 ++ ", " ++ a2 ++ ", " ++ a3, "  old box: traind running " ++ a4 ++ ", bend-corpus-v2 running " ++ a5,
      b, "  DEST/out: " ++ b1, "  DEST/oldbox: " ++ b2, "  DEST/rescue/act/r1: " ++ b3,
      r, "  the new box's trainer reached step 60: " ++ Bool.pick(String, done, "yes", "no"), "  the new box's out/: " ++ r1,
      w, "  units: " ++ w1 ++ ", " ++ w2, k]

def sdr.move.files() -> List<&2, String>:
  ["dest/out/s1-step20.checkpoint", "dest/oldbox/train.log", "newbox/ana/out/s1-step60.checkpoint"]

# move.sh's old-pull dies (SIGPIPE, 141) in cut_frames before any cut, so the old run's rescued files
# are as pulled: each is the new run's copy kept before its cut (FILE.whole-before-cut)
def sdr.cmp.cut(+cn: Sc.ScnCx, +co: Sc.ScnCx, +f: String) -> IO(Sc.ScnRes):
  do IO<Sc.ScnRes>:
    +a : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(Sc.scn.d(cn) ++ "/dest/rescue/act/r1/" ++ f ++ ".whole-before-cut")
    +b : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(Sc.scn.d(co) ++ "/dest/rescue/act/r1/" ++ f)
    return Sc.ScnRes{"rescued " ++ f ++ " before the cut (new: " ++ f ++ ".whole-before-cut) = as move.sh pulled it", Bool.and(Maybe.is_some(&2, List<&2, U32>, a), sdr.same(a, b)),
      "new " ++ sdr.sha.show(a) ++ ", old " ++ sdr.sha.show(b)}

# what differs on purpose: move.sh's old-pull lines (its exit, the rescued files it did not cut)
def sdr.move.same(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = sdr.move.same(t)
      Bool.pick(List<&2, String>, Bool.or(String.starts_with(x, "old-pull: exit"), String.starts_with(x, "  DEST/rescue/act/r1:")), rest, x <> rest)

def sdr.d6(+t: Sc.ScnTools, +base: String, +olds: String) -> IO(List<&2, Sc.ScnRes>):
  +cn = sdr.cx(t, base, "d6-new")
  +co = sdr.cx(t, base, "d6-old")
  do IO<List<&2, Sc.ScnRes>>:
    Sc.scn.say(cn, "scenario d6: the move: old-stop, old-pull, resume on a second box, watch, old-check")
    ch : Chan(List<&2, String>) <- IO.fork(List<&2, String>, sdr.move.one(co, True{}, olds))
    +xn : List<&2, String> <- sdr.move.one(cn, False{}, olds)
    +xo : List<&2, String> <- IO.join(List<&2, String>, ch)
    S.write(Sc.scn.d(cn) ++ "/events.txt", S.b(sdr.lines(xn)))
    S.write(Sc.scn.d(co) ++ "/events.txt", S.b(sdr.lines(xo)))
    es : List<&2, Sc.ScnRes> <- sdr.exps([DxRc{"move-old-stop", "0"}, DxRc{"move-old-pull", "0"}, DxRc{"move-resume", "0"}, DxRc{"move-watch", "0"}, DxRc{"move-old-check", "0"},
      DxFile{"dest/rescue/act/r1/episodes.eplog.whole-before-cut", True{}}, DxFile{"dest/rescue/act/r1/agent.nul.whole-before-cut", True{}},
      DxIn{"move-old-pull.out", "\n40 whole episodes in dest/rescue/act/r1/episodes.eplog\n", True{}},
      DxIn{"move-old-pull.out", "dest/rescue/act/r1/agent.nul: 40 records\n", True{}},
      DxIn{"dest/chain.log", "] move: act round r1 pulled into dest/rescue/act/r1 (", True{}}, DxIn{"dest/chain.log", "40 records in agent.nul, 40 lines in render.txt\n", True{}},
      DxIn{"stages", "s1 traind-next 5000\n", True{}}, DxIn{"stages.4242", "s1 traind 5000\n", True{}},
      DxIn{"dest/chain.log", "] move: old box: every checkpoint is here with its sha256\n", True{}},
      DxIn{"dest/chain.log", "] move: new box: s1 resumed from s1-step20 to 60 (bend-box resume, s1.log = train.log)\n", True{}}], cn)
    fs : List<&2, Sc.ScnRes> <- sdr.cmp.files(sdr.move.files(), cn, co)
    c1 : Sc.ScnRes <- sdr.cmp.cut(cn, co, "episodes.eplog")
    c2 : Sc.ScnRes <- sdr.cmp.cut(cn, co, "agent.nul")
    c3 : Sc.ScnRes <- sdr.cmp.cut(cn, co, "episodes.nul")
    +cs : List<&2, Sc.ScnRes> = [c1, c2, c3]
    return List.concat(&2, Sc.ScnRes, [
      [sdr.res.lines("d6-new: what each step left", xn, ["the old driver is there", "S1 saved step 20 on the old box: yes", "old-stop: exit 0",
        "  units: ft-fp-chain-v3 inactive, ft-credit-watch-v3 inactive, ft-v3-act1 inactive", "  old box: traind running 0, bend-corpus-v2 running 0",
        "old-pull: exit 0", "  DEST/out: s1-step20.checkpoint", "  DEST/oldbox: train.log",
        "  DEST/rescue/act/r1: agent.nul agent.nul.whole-before-cut episodes.eplog episodes.eplog.whole-before-cut episodes.nul episodes.nul.whole-before-cut render.txt",
        "resume: exit 0", "  the new box's trainer reached step 60: yes", "  the new box's out/: s1-step20.checkpoint s1-step60.checkpoint",
        "watch: exit 0", "  units: ft-fp-chain-v3 active, ft-credit-watch-v3 active", "old-check: exit 0"])],
      Sc.scn.tagged("d6-new", es),
      [Sc.scn.cmp.lines("d6 old = new: what each step left, but old-pull's lines", sdr.move.same(xn), sdr.move.same(xo)),
       Sc.ScnRes{"d6 old: move.sh's old-pull dies of SIGPIPE (exit 141) in cut_frames on an 81 KB eplog (the bug Bend's cut fixes)", Sc.scn.has(xo, "old-pull: exit 141"), String.join(xo, " | ")}],
      Sc.scn.tagged("d6 old = new", cs),
      Sc.scn.tagged("d6 old = new", fs)])

# Run 4 (d8, d9): a hot-started first stage, the hand-over with plan-base, REST_STEPS and a control ---
#
# c1 is started as run 4's C1 is: `bend-box again` (TRAIN_NEXT) from run/base/base-step100.checkpoint
# (outside out/, so the chain's verify does not ask for it) with TRAIN_STEPS=30, so its log
# counts global steps 101..130 and ends `done at step 130`; LOG0 is c1.log.  The hand-over
# (plan-base 100, boundary 30) waits for step 130, gives s2 the plan's step 30 (bend-sim's s2
# refuses a step past its S1 plan's 30), REST_STEPS and CTL_OUT, and appends c2 and then
# ctl, which starts from=out/c1-step130.checkpoint.  The chain runs c2 from c1's last save,
# then ctl from the same save.

def sdr.cfg.run4(+d: String, +tag: String, +every2: String) -> String:
  sdr.lines(["# run 4's hand-over in a sandbox (bend/Box/ScnDrive.bend)", "host root@sim-" ++ tag, "port 2222", "instance 4242", "dest dest", "stages stages",
    "trainer-dir " ++ d ++ "/box/ana", "trainer-log c1.log", "box-driver ./bend-box", "boundary 30", "plan-base 100", "handover-poll 1",
    "act-ws " ++ d ++ "/box/ws", "act-box-bin " ++ d ++ "/box/bin", "act-dir run/v3/act/r1", "act-stop-wait 1",
    "s2-from run/v3/S1", "s2-out run/v3/S2", "s2-log run/v3/s2.log", "s2-every " ++ every2, "s2-stage c2", "s2-env REST_STEPS=20 LR=1e-4", "s2-env WARM=300",
    "ctl-stage ctl", "ctl-out run/v3/CTL", "ctl-every 10"])

# c1, as run 4's C1 starts: bend-box again from a save outside out/, TRAIN_STEPS the boundary
def sdr.c1(+c: Sc.ScnCx) -> IO(Unit):
  +ft = Sc.scn.ft(c)
  do IO<Unit>:
    S.mkdir(ft ++ "/run/base")
    S.write(ft ++ "/run/base/base-step100.checkpoint", S.b("BTC1\nsim base checkpoint, step 100\n"))
    +o : S.Out <- S.run(ft, Sc.scn.l1(List.append(&2, String, ["SIM_BOX=" ++ Sc.scn.box(c), "TRAIN_STEPS=30", "NWARM=300"], Sc.scn.simenv(c, ["SIM_DRIVE=1"]))), 120,
      "./bend-box", ["again", "run/base/base-step100.checkpoint", "run/v3/S1/plan-fp100m-b16-windows.tsv", "run/v3/S1", "fp100m", "c1"], Nil{})
    S.write(Sc.scn.d(c) ++ "/c1-start.out", S.Out.text(o))
    Sc.scn.say(c, "c1 started by bend-box again (exit " ++ U32.show(S.Out.status(o)) ++ ")")

def sdr.cx4(+t: Sc.ScnTools, +base: String, +tag: String) -> Sc.ScnCx:
  +d = base ++ "/" ++ tag
  Sc.scn.cx(t, d, tag, False{}, "./bend-box", ["SIM_DRIVE=1", "SIM_UNITS=" ++ d ++ "/units", "UNIT_STATE=" ++ d ++ "/unitstate",
    "SYSTEMD_USER_DIR=" ++ d ++ "/home/.config/systemd/user", "WAIT=30", "H=root@sim-" ++ tag, "P=2222", "B=30", "LOG0=c1.log"])

def sdr.run4(+t: Sc.ScnTools, +base: String, +id: String, +about: String, +stages: String, +every2: String, +ex: List<&2, Sc.ScnExp>, +dx: List<&2, SdrExp>) -> IO(List<&2, Sc.ScnRes>):
  +c = sdr.cx4(t, base, "d" ++ id ++ "-new")
  +d = Sc.scn.d(c)
  do IO<List<&2, Sc.ScnRes>>:
    Sc.scn.say(c, "scenario d" ++ id ++ ": " ++ about)
    Sc.scn.setup(c, Sc.Scn{"d" ++ id, about, stages, ["", "", ""], ["SIM_DRIVE=1"], Nil{}, Nil{}, False{}, Nil{}, Nil{}})
    sdr.extra(c, "30", sdr.cfg.run4(d, Sc.scn.tag(c), every2))
    sdr.c1(c)
    sdr.act.start(c, ["SIM_ACT_FINISH=1", "SIM_ACT_EPISODES=20"])
    Sc.scn.launch(c, "watch", Sc.scn.watch.argv(c))
    Sc.scn.launch(c, "chain", Sc.scn.chain.argv(c))
    Sc.scn.launch(c, "driver", sdr.driver.argv(c, False{}))
    +ended : Bool <- Sc.scn.wait(d ++ "/chain.rc", 600n)
    +dend : Bool <- Sc.scn.wait(d ++ "/driver.rc", 120n)
    gone : Bool <- S.exists(Sc.scn.dest(c) ++ "/DESTROYED")
    w : Bool <- Bool.pick(IO(Bool), gone, Sc.scn.wait(d ++ "/watch.rc", 20n), IO.pure(Bool, True{}))
    sdr.cleanup(c, False{})
    rs : List<&2, Sc.ScnRes> <- Sc.scn.exps(ex, c)
    ds : List<&2, Sc.ScnRes> <- sdr.exps(dx, c)
    Sc.scn.say(c, "done")
    return Sc.scn.tagged(Sc.scn.tag(c), List.concat(&2, Sc.ScnRes, [[Sc.ScnRes{"the chain ended by itself", ended, ""}, Sc.ScnRes{"the driver ended by itself", dend, ""}], rs, ds]))

def sdr.c2.line(+every: String) -> String:
  "c2 traind-next " ++ every ++ " run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m"

def sdr.ctl.line() -> String:
  "ctl traind-next 10 run/v3/CTL/plan-fp100m-b16-windows.tsv run/v3/CTL fp100m from=out/c1-step130.checkpoint"

# the lines both run-4 scenarios share: the wait and the boundary at global step 130, s2 at the
# plan's step 30 with REST_STEPS and the control's plan, both lines appended, both stages started
def sdr.r4.exps(+every2: String) -> List<&2, Sc.ScnExp>:
  [Sc.ExRc{"0"}, Sc.ExMark{"DESTROYED", True{}}, Sc.ExMark{"DIED", False{}}, Sc.ExMark{"REFUSED", False{}}, Sc.ExStarts{3n},
   Sc.ExLog{"/box/ana/c1.log (plan-base 100 + boundary 30)\n", True{}},
   Sc.ExLog{"] handover: waiting for S1's 'done at step 130' in ", True{}},
   Sc.ExLog{"] handover: S1 is done at step 130 (plan-base 100 + boundary 30)\n", True{}},
   Sc.ExLog{"] handover: s2: ", True{}}, Sc.ExLog{"/box/ana/run/v3/S1 30 -> ", True{}},
   Sc.ExLog{"] s2: REST_STEPS 20 (bend-sim)\n", True{}}, Sc.ExLog{"/box/ana/run/v3/S1 at step 30: 30 steps in ", True{}},
   Sc.ExLog{"/box/ana/run/v3/CTL (bend-sim)\n", True{}},
   Sc.ExLog{"] handover: control stage.env: NLR=1e-4 NWARM=10 ; ctl starts from out/c1-step130.checkpoint\n", True{}},
   Sc.ExLog{"] handover: appended to stages: " ++ sdr.c2.line(every2) ++ "\n", True{}},
   Sc.ExLog{"] handover: appended to stages: " ++ sdr.ctl.line() ++ "\n", True{}},
   Sc.ExLog{"] stage c2: from out/c1-step130.checkpoint on run/v3/S2/plan-fp100m-b16-windows.tsv\n", True{}},
   Sc.ExLog{"] stage ctl: from out/c1-step130.checkpoint on run/v3/CTL/plan-fp100m-b16-windows.tsv\n", True{}},
   Sc.ExBoxFile{"run/v3/CTL/stage.env"}]

def sdr.r4.dexps(+every2: String) -> List<&2, SdrExp>:
  [DxRc{"driver", "0"}, DxIn{"stages", "c1 traind-next", True{}}, DxIn{"stages", "\n" ++ sdr.c2.line(every2) ++ "\n" ++ sdr.ctl.line() ++ "\n", True{}},
   DxIn{"c1-start.out", "trainer pid ", True{}}, DxIn{"box/ana/c1.log", "] loaded run/base/base-step100.checkpoint (1 ms)\n", True{}},
   DxIn{"box/ana/c1.log", "] done at step 130\n", True{}},
   DxIn{"box/ana/c2.log", "] loaded out/c1-step130.checkpoint (1 ms)\n", True{}},
   DxIn{"box/ana/ctl.log", "] loaded out/c1-step130.checkpoint (1 ms)\n", True{}},
   DxIn{"box/ana/ctl.log", "] done at step 150\n", True{}},
   DxIn{"box/.sim-starts", "start out/c1 from 100\n", True{}}, DxIn{"box/.sim-starts", "start out/ctl from 130\n", True{}}]

# d8: run 4's own EVERYs (c1 and c2 pulled every 10): the boundary save is a pull and a last
def sdr.d8(+t: Sc.ScnTools, +base: String) -> IO(List<&2, Sc.ScnRes>):
  sdr.run4(t, base, "8", "run 4: c1 hot-started by bend-box again (plan-base 100); the hand-over waits for global step 130, builds c2 with REST_STEPS and the control, appends c2 and ctl from=; the chain runs both",
    "c1 traind-next 10\n", "10",
    List.concat(&2, Sc.ScnExp, [sdr.r4.exps("10"),
      [Sc.ExLog{"deleted out/c1-step130", False{}},
       Sc.ExOut{List.concat(&2, String, [Sc.scn.cks("c1", [110n, 120n, 130n]), Sc.scn.cks("c2", [140n, 150n, 160n]), Sc.scn.cks("ctl", [140n, 150n])])},
       Sc.ExLog{"] eval: out/c1-step110.checkpoint out/c1-step120.checkpoint out/c1-step130.checkpoint  out/c2-step140.checkpoint out/c2-step150.checkpoint out/c2-step160.checkpoint  out/ctl-step140.checkpoint out/ctl-step150.checkpoint \n", True{}}]]),
    sdr.r4.dexps("10"))

# d9: raw c1 and c2 (EVERY 0): c1's boundary save stays on the box past c2's start, until ctl
# has loaded it, then goes; c2's last, which nothing loads, is scored and pulled (a branch's end)
def sdr.d9(+t: Sc.ScnTools, +base: String) -> IO(List<&2, Sc.ScnRes>):
  sdr.run4(t, base, "9", "run 4 with raw c1 and c2 (EVERY 0): the boundary save c1-step130 is kept past c2's start until ctl loaded it, then deleted; c2's unloaded last is pulled",
    "c1 traind-next 0\n", "0",
    List.concat(&2, Sc.ScnExp, [sdr.r4.exps("0"),
      [Sc.ExLog{"] deleted out/c1-step130.checkpoint on the box (a raw stage's, loaded by ctl)\n", True{}},
       Sc.ExLog{"(a raw stage's, loaded by c2)", False{}},
       Sc.ExLog{"] out/c2-step160.checkpoint: no stage starts from it (ctl starts from out/c1-step130.checkpoint); it is scored and pulled at the end\n", True{}},
       Sc.ExOut{List.append(&2, String, Sc.scn.cks("c2", [160n]), Sc.scn.cks("ctl", [140n, 150n]))},
       Sc.ExBox{List.append(&2, String, Sc.scn.cks("c2", [160n]), Sc.scn.cks("ctl", [140n, 150n]))},
       Sc.ExLog{"] eval: out/ctl-step140.checkpoint out/ctl-step150.checkpoint  out/c2-step160.checkpoint\n", True{}}]]),
    sdr.r4.dexps("0"))

# unit (d7) ------------------------------------------------------------------------------------------

def sdr.d7(+t: Sc.ScnTools, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +c = sdr.cx(t, base, "d7-new")
  +d = Sc.scn.d(c)
  +u = {[Sc.scn.self(c), "unit"] : List<&2, String>}
  do IO<List<&2, Sc.ScnRes>>:
    Sc.scn.say(c, "scenario d7: unit start, start again, list, a reboot, restart, stop, a refused start")
    Sc.scn.setup(c, Sc.Scn{"d7", "unit", "", ["", "", ""], ["SIM_DRIVE=1"], Nil{}, Nil{}, False{}, Nil{}, Nil{}})
    sdr.extra(c, "30", "")
    +a : U32 <- sdr.run(c, "u-start", Nil{}, List.append(&2, String, u, ["start", "sdr-u1", "--mem", "1G", "--out", "u1.out", "--env", "A=1 2", "--", "sleep", "30"]))
    +sa : List<&2, U32> <- S.read(d ++ "/units/sdr-u1.active")
    S.write(d ++ "/start.active", sa)
    +b : U32 <- sdr.run(c, "u-again", Nil{}, List.append(&2, String, u, ["start", "sdr-u1", "--", "true"]))
    +l : U32 <- sdr.run(c, "u-list", Nil{}, List.append(&2, String, u, ["list"]))
    sdr.reboot(c)
    +l2 : U32 <- sdr.run(c, "u-list2", Nil{}, List.append(&2, String, u, ["list"]))
    +r : U32 <- sdr.run(c, "u-restart", Nil{}, List.append(&2, String, u, ["restart", "sdr-u1"]))
    +ra : List<&2, U32> <- S.read(d ++ "/units/sdr-u1.active")
    S.write(d ++ "/restart.active", ra)
    +s : U32 <- sdr.run(c, "u-stop", Nil{}, List.append(&2, String, u, ["stop", "sdr-u1"]))
    S.write(d ++ "/units/sdr-u2.refuse", Nil{})
    +f : U32 <- sdr.run(c, "u-refused", Nil{}, List.append(&2, String, u, ["start", "sdr-u2", "--", "true"]))
    +n : U32 <- sdr.run(c, "u-badname", Nil{}, List.append(&2, String, u, ["start", "../x", "--", "true"]))
    +line : String = "systemd-run --user --unit=sdr-u1 -p MemoryMax=1G -p OOMPolicy=continue --working-directory=" ++ d ++ " -p StandardOutput=append:" ++ d
      ++ "/u1.out -p StandardError=append:" ++ d ++ "/u1.out '--setenv=A=1 2' -- sleep 30"
    # (bend-sim's systemd-run, a Bend program, never sees the line's `--`: the runtime takes it out)
    es : List<&2, Sc.ScnRes> <- sdr.exps([DxRc{"u-start", "0"}, DxIn{"u-start.out", "started sdr-u1", True{}}, DxIn{"unitstate/sdr-u1.line", line ++ "\n", True{}},
      DxIn{"start.active", "--setenv=A=1 2\nsleep\n30\n", True{}},
      DxRc{"u-again", "0"}, DxIn{"u-again.out", "sdr-u1 is active; not started", True{}}, DxIn{"unitstate/sdr-u1.line", " -- sleep 30\n", True{}},
      DxIn{"u-list.out", "sdr-u1\tactive\t" ++ line ++ "\n", True{}}, DxIn{"u-list2.out", "sdr-u1\tinactive\t", True{}},
      DxRc{"u-restart", "0"}, DxIn{"u-restart.out", "restarted sdr-u1", True{}}, DxIn{"restart.active", "--unit=sdr-u1\n", True{}},
      DxIn{"unitstate/starts.log", "] restart sdr-u1\n", True{}},
      DxRc{"u-stop", "0"}, DxFile{"units/sdr-u1.active", False{}}, DxRc{"u-refused", "1"}, DxIn{"u-refused.out", "not started: systemd-run exit 1", True{}},
      DxRc{"u-badname", "2"}, DxFile{"unitstate/../x.argv", False{}}], c)
    return Sc.scn.tagged("d7-new", es)

# The command ----------------------------------------------------------------------------------------

def sdr.usage() -> String:
  "usage: bend-ops sim drive N DIR | sim drive all DIR   (N: 1..9; BEND_SIM, BEND_BOX, SIM_REPO, SIM_CV2, SIM_OLD_DRIVERS)"

def sdr.one(+id: String, +t: Sc.ScnTools, +base: String, +olds: String) -> IO(List<&2, Sc.ScnRes>):
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "1"), sdr.hand(t, base, olds, sdr.d1()),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "2"), sdr.hand(t, base, olds, sdr.d2()),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "3"), sdr.hand(t, base, olds, sdr.d3()),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "4"), sdr.hand(t, base, olds, sdr.d4()),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "5"), sdr.d5(t, base, olds),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "6"), sdr.d6(t, base, olds),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "7"), sdr.d7(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "8"), sdr.d8(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(id, "9"), sdr.d9(t, base),
    IO.die(List<&2, Sc.ScnRes>, 2, sdr.usage()))))))))))

def sdr.many(ids: List<&2, String>, +t: Sc.ScnTools, +base: String, +olds: String) -> IO(List<&2, Sc.ScnRes>):
  match ids:
    case Nil{}:
      IO.pure(List<&2, Sc.ScnRes>, Nil{})
    case +i <> rest:
      do IO<List<&2, Sc.ScnRes>>:
        a : List<&2, Sc.ScnRes> <- sdr.one(i, t, base, olds)
        b : List<&2, Sc.ScnRes> <- sdr.many(rest, t, base, olds)
        return List.append(&2, Sc.ScnRes, a, b)

def sdr.ids(+id: String) -> List<&2, String>:
  Bool.pick(List<&2, String>, String.eq(id, "all"), ["1", "2", "3", "4", "5", "6", "7", "8", "9"], [id])

def sdr.main(+argv0: String, xs: List<String>) -> IO(Unit):
  match xs:
    case +id <> +dir <> Nil{}:
      do IO<Unit>:
        t : Sc.ScnTools <- Sc.scn.tools(argv0)
        S.mkdir(dir)
        +base : String <- S.realpath(dir)
        o0 : String <- S.env("SIM_OLD_DRIVERS", "run/v3/run3")
        +olds : String <- S.realpath(o0)
        rs : List<&2, Sc.ScnRes> <- sdr.many(sdr.ids(id), t, base, olds)
        Sc.scn.report(rs, 0n)
    case _:
      IO.die(Unit, 2, sdr.usage())
