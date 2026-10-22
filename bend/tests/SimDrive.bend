import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ../Box/Local.bend as Lc

# SimDrive: bend-sim's parts for the run drivers' sandbox (2026-10-15, the
# plan's Phase 4b: bend-ops guard, handover, move and unit against a box in a
# sandbox, bend/Box/ScnDrive.bend).  With SIM_DRIVE set, bend/tests/Sim.bend
# hands these names to sdf.part before its own parts (Phase 1c's stubs of the
# same names serve the staging sandbox, bend/Box/ScnStage.bend):
#
#   systemd-run     --user --unit=NAME [-p X].. [--working-directory=D] [--setenv=K=V].. [--] CMD..:
#                   nothing is run; SIM_UNITS/NAME.active (the words, one a line) says the unit
#                   is active.  A unit that is active, or failed (NAME.failed), or refused
#                   (NAME.refuse) is not started: exit 1, as systemd refuses a loaded unit
#   systemctl       --user is-active [-q] NAME.. (active, failed, inactive; exit 3 unless all
#                   are active), reset-failed NAME.., stop NAME.., daemon-reload, enable NAME
#                   SIM_UNITS ($HOME/.sim-units); every call of both is appended to SIM_UNITS/calls
#   bend-corpus-v2  agent-act CKPT DIR: an act round in DIR: SIM_ACT_EPISODES (40) episodes, one each
#                   SIM_ACT_MS (50) ms, each an `EP1 LEN\n` frame in DIR/episodes.eplog (a payload
#                   of `ID 4 2`, lang=, kind= (act, fix) and SIM_ACT_PAD (2000) bytes), a line of
#                   DIR/render.txt and a NUL pair in DIR/agent.nul and DIR/episodes.nul; then, with
#                   SIM_ACT_FINISH set, `agent-act: done`, else half a frame and one field of a
#                   pair (a round killed inside an append) and a wait (an hour) to be stopped
#   deploy          corpus-v2 s2 S1 BOUNDARY OUT ACT..: OUT/plan-fp100m-b16-windows.tsv (`plan sim
#                   SIM_S2_STEPS`, 30) and OUT/stage.env (NLR, NWARM=10), the episodes counted
#                   on stderr, the stage line on stdout (`s2 traind-next EVERY REL/plan... REL
#                   fp100m`, REL OUT under TRAINER_DIR, else $HOME/ana); with
#                   SIM_S2_FAIL set, run 3's bend-windows refusal and exit 1; a BOUNDARY past
#                   S1's plan (`plan sim N`) refused as s2 refuses a step that starts no
#                   segment; REST_STEPS logged, and CTL_OUT (2026-10-15, run 4) built as
#                   OUT is (`plan sim SIM_CTL_STEPS`, 20, and stage.env).  corpus-v2
#                   agent-act CKPT DIR: the act round above
#   bend-episode    accept|fixed CALLS CAP OUT EPLOG: EPLOG's whole frames, those of kind act
#                   (accept) or fix (fixed) as `ID NUL TEXT NUL` records in OUT/LANG-KIND/
#                   transcripts.train.nul, a directory for each of the five languages
#
# Every name starts with `sdf.`.

def sdf.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> sdf.l1(t)

def sdf.join(xs: List<&2, String>) -> String:
  String.join(xs, " ")

def sdf.langs() -> List<&2, String>:
  ["haskell", "agda", "lean", "nix", "bend"]

# systemd ------------------------------------------------------------------------------------------

def sdf.units() -> IO(String):
  do IO<String>:
    +h : String <- S.env("HOME", ".")
    +d : String <- S.env("SIM_UNITS", h ++ "/.sim-units")
    S.mkdir(d)
    return d

def sdf.call(+dir: String, +what: String, +args: List<&2, String>) -> IO(Unit):
  S.add(dir ++ "/calls", S.b(what ++ " " ++ sdf.join(args) ++ "\n"))

# a unit's name without .service
def sdf.unit.name(+n: String) -> String:
  +xs = S.b(n)
  S.str(Bool.pick(List<&2, U32>, S.suffix(xs, S.b(".service")), List.take(&2, U32, xs, Nat.sub(S.len(xs), 8n)), xs))

def sdf.run.unit(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      Bool.pick(String, String.starts_with(x, "--unit="), String.drop(x, 7n), sdf.run.unit(t))

def sdf.run.lines(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      x ++ "\n" ++ sdf.run.lines(t)

def sdf.run.go(busy: Bool, +dir: String, +name: String, +args: List<&2, String>) -> IO(Unit):
  match busy:
    case True{}:
      IO.die(Unit, 1, "Failed to start transient service unit: Unit " ++ name ++ ".service was already loaded or has a fragment file. (bend-sim)")
    case False{}:
      do IO<Unit>:
        S.write(dir ++ "/" ++ name ++ ".active", S.b(sdf.run.lines(args)))
        IO.print_err("Running as unit: " ++ name ++ ".service; invocation ID: bend-sim")

def sdf.systemd.run(+args: List<&2, String>) -> IO(Unit):
  +name = sdf.run.unit(args)
  do IO<Unit>:
    +dir : String <- sdf.units()
    sdf.call(dir, "systemd-run", args)
    a : Bool <- S.exists(dir ++ "/" ++ name ++ ".active")
    f : Bool <- S.exists(dir ++ "/" ++ name ++ ".failed")
    r : Bool <- S.exists(dir ++ "/" ++ name ++ ".refuse")
    Bool.pick(IO(Unit), String.is_empty(name), IO.die(Unit, 1, "bend-sim systemd-run: no --unit="), sdf.run.go(Bool.or(Bool.or(a, f), r), dir, name, args))

def sdf.state(+dir: String, +name: String) -> IO(String):
  do IO<String>:
    a : Bool <- S.exists(dir ++ "/" ++ name ++ ".active")
    f : Bool <- S.exists(dir ++ "/" ++ name ++ ".failed")
    return Bool.pick(String, a, "active", Bool.pick(String, f, "failed", "inactive"))

def sdf.is.active(ns: List<&2, String>, +dir: String, +quiet: Bool, +all: Bool) -> IO(Unit):
  match ns:
    case Nil{}:
      Bool.pick(IO(Unit), all, IO.pure(Unit, Unit{}), IO.die(Unit, 3, ""))
    case +n <> t:
      do IO<Unit>:
        +st : String <- sdf.state(dir, sdf.unit.name(n))
        Bool.pick(IO(Unit), quiet, IO.pure(Unit, Unit{}), IO.print(st))
        sdf.is.active(t, dir, quiet, Bool.and(all, String.eq(st, "active")))

def sdf.rm.each(ns: List<&2, String>, +dir: String, +suf: String) -> IO(Unit):
  match ns:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        S.rm(dir ++ "/" ++ sdf.unit.name(n) ++ suf)
        sdf.rm.each(t, dir, suf)

def sdf.ctl.go(xs: List<&2, String>, +dir: String) -> IO(Unit):
  match xs:
    case "--user" <> t:
      sdf.ctl.go(t, dir)
    case "is-active" <> "-q" <> ns:
      sdf.is.active(ns, dir, True{}, True{})
    case "is-active" <> "--quiet" <> ns:
      sdf.is.active(ns, dir, True{}, True{})
    case "is-active" <> ns:
      sdf.is.active(ns, dir, False{}, True{})
    case "reset-failed" <> ns:
      sdf.rm.each(ns, dir, ".failed")
    case "stop" <> ns:
      sdf.rm.each(ns, dir, ".active")
    case "daemon-reload" <> Nil{}:
      IO.pure(Unit, Unit{})
    case "enable" <> n <> Nil{}:
      IO.pure(Unit, Unit{})
    case _:
      IO.die(Unit, 1, "bend-sim systemctl: not simulated")

def sdf.systemctl(+args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +dir : String <- sdf.units()
    sdf.call(dir, "systemctl", args)
    sdf.ctl.go(args, dir)

# The act round ------------------------------------------------------------------------------------

def sdf.nth(+xs: List<&2, String>, +i: Nat) -> String:
  Maybe.default(&2, String, List.get(&2, String, xs, Nat.mod(i, List.length(&2, String, xs))), "")

def sdf.payload(+i: Nat, +pad: Nat) -> List<&2, U32>:
  List.concat(&2, U32, [S.b(Nat.show(i) ++ " 4 2\nlang=" ++ sdf.nth(sdf.langs(), i) ++ "\nkind=" ++ Bool.pick(String, Nat.is_eq(Nat.mod(i, 2n), 0n), "act", "fix") ++ "\n"),
    List.replicate(U32, pad, 120), [10]])

def sdf.frame(+p: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, S.b("EP1 " ++ Nat.show(S.len(p)) ++ "\n"), p)

def sdf.pair(+i: Nat) -> List<&2, U32>:
  S.b("act/" ++ Nat.show(i) ++ "\u{0}lang=" ++ sdf.nth(sdf.langs(), i) ++ " solved=" ++ Bool.pick(String, Nat.is_eq(Nat.mod(i, 2n), 0n), "1", "0") ++ "\u{0}")

def sdf.episode(+dir: String, +i: Nat, +pad: Nat, +ms: Nat) -> IO(Unit):
  do IO<Unit>:
    S.add(dir ++ "/episodes.eplog", sdf.frame(sdf.payload(i, pad)))
    S.add(dir ++ "/render.txt", S.b(Nat.show(i) ++ " ok\n"))
    S.add(dir ++ "/agent.nul", sdf.pair(i))
    S.add(dir ++ "/episodes.nul", sdf.pair(i))
    IO.sleep(U32.from_nat(Nat.min(ms, 60000n)))

def sdf.episodes(n: Nat, +dir: String, +i: Nat, +pad: Nat, +ms: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      do IO<Unit>:
        sdf.episode(dir, i, pad, ms)
        sdf.episodes(k, dir, 1n+i, pad, ms)

def sdf.wait(n: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      do IO<Unit>:
        IO.sleep(1000)
        sdf.wait(k)

# a round killed inside an append: half a frame, one field of a pair, then a wait to be stopped
def sdf.cut.short(+dir: String, +i: Nat, +pad: Nat) -> IO(Unit):
  +f = sdf.frame(sdf.payload(i, pad))
  do IO<Unit>:
    S.add(dir ++ "/episodes.eplog", List.take(&2, U32, f, Nat.div(S.len(f), 2n)))
    S.add(dir ++ "/agent.nul", S.b("act/" ++ Nat.show(i) ++ "\u{0}"))
    S.add(dir ++ "/episodes.nul", S.b("act/" ++ Nat.show(i) ++ "\u{0}"))
    sdf.wait(3600n)

def sdf.act(+ck: String, +dir: String) -> IO(Unit):
  do IO<Unit>:
    +n : Nat <- S.env.nat("SIM_ACT_EPISODES", 40n)
    +pad : Nat <- S.env.nat("SIM_ACT_PAD", 2000n)
    +ms : Nat <- S.env.nat("SIM_ACT_MS", 50n)
    fin : String <- S.env("SIM_ACT_FINISH", "")
    S.mkdir(dir)
    Ck.log("agent-act: start: " ++ ck ++ " into " ++ dir ++ " (bend-sim)")
    sdf.episodes(n, dir, 1n, pad, ms)
    Bool.pick(IO(Unit), String.is_empty(fin), sdf.cut.short(dir, 1n+n, pad), Ck.log("agent-act: done"))

# bend-episode -------------------------------------------------------------------------------------

def sdf.nl(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, S.find(xs, [10], 0n), 0n)

def sdf.len(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Lc.lcl.nat(List.drop(&2, U32, List.take(&2, U32, xs, sdf.nl(xs)), 4n)), 0n)

# does xs start with a whole `EP1 LEN\n` frame
def sdf.whole(+xs: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(S.prefix(xs, S.b("EP1 ")), Nat.is_lt(0n, sdf.nl(xs))), Nat.is_le(sdf.len(xs), S.len(List.drop(&2, U32, xs, 1n+sdf.nl(xs)))))

# the payloads of the whole frames, in order (a cut frame ends the walk)
def sdf.frames(fuel: Nat, +xs: List<&2, U32>, ok: Bool) -> List<&2, List<&2, U32>>:
  match fuel ok:
    case 1n+k True{}:
      +rest = List.drop(&2, U32, xs, 1n+sdf.nl(xs))
      +next = List.drop(&2, U32, rest, sdf.len(xs))
      List.take(&2, U32, rest, sdf.len(xs)) <> sdf.frames(k, next, sdf.whole(next))
    case _ _:
      Nil{}

def sdf.field.go(ls: List<&2, List<&2, U32>>, +key: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Bool.pick(List<&2, U32>, S.prefix(l, key), List.drop(&2, U32, l, S.len(key)), sdf.field.go(t, key))

def sdf.field(+p: List<&2, U32>, +key: String) -> List<&2, U32>:
  sdf.field.go(S.split.lines(p), S.b(key))

# a frame's record: its first line's first word as the id, its first line as the text
def sdf.record(+p: List<&2, U32>) -> List<&2, U32>:
  +l = S.lines.first(p)
  List.concat(&2, U32, [S.b("ep-"), Lc.lcl.nth(Lc.lcl.words(l), 0n), [0], l, [0]])

def sdf.pick(ps: List<&2, List<&2, U32>>, +lang: String, +kind: String) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      +hit = Bool.and(S.eq(sdf.field(p, "lang="), S.b(lang)), S.eq(sdf.field(p, "kind="), S.b(kind)))
      List.append(&2, U32, Bool.pick(List<&2, U32>, hit, sdf.record(p), Nil{}), sdf.pick(t, lang, kind))

def sdf.nuls(xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +c <> t:
      Nat.add(Bool.pick(Nat, U32.is_eq(c, 0), 1n, 0n), sdf.nuls(t))

def sdf.ep.langs(ls: List<&2, String>, +ps: List<&2, List<&2, U32>>, +out: String, +kind: String) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, 0n)
    case +l <> t:
      +recs = sdf.pick(ps, l, kind)
      +n = Nat.div(sdf.nuls(recs), 2n)
      +d = out ++ "/" ++ l ++ "-" ++ kind
      do IO<Nat>:
        S.mkdir(d)
        S.write(d ++ "/transcripts.train.nul", recs)
        IO.print(Bool.pick(String, String.eq(kind, "fix"), "fixed: " ++ l ++ " " ++ Nat.show(n) ++ " into " ++ d ++ "/transcripts.train.nul; episodes by reason: ok " ++ Nat.show(n),
          "accept: " ++ l ++ " " ++ Nat.show(n) ++ " into " ++ d ++ "/transcripts.train.nul"))
        +rest : Nat <- sdf.ep.langs(t, ps, out, kind)
        return Nat.add(n, rest)

def sdf.episode.tool(+mode: String, +out: String, +eplog: String) -> IO(Unit):
  +kind = Bool.pick(String, String.eq(mode, "fixed"), "fix", "act")
  do IO<Unit>:
    +xs : List<&2, U32> <- S.read(eplog)
    +ps : List<&2, List<&2, U32>> = sdf.frames(1n+S.len(xs), xs, sdf.whole(xs))
    S.mkdir(out)
    +n : Nat <- sdf.ep.langs(sdf.langs(), ps, out, kind)
    IO.print(mode ++ ": " ++ Nat.show(List.length(&2, List<&2, U32>, ps)) ++ " episodes; " ++ Nat.show(n) ++ " " ++ Bool.pick(String, String.eq(kind, "fix"), "fixed", "accepted")
      ++ " episodes (at most the cap a unit) into " ++ out ++ "/LANG-" ++ kind)

# s2 -----------------------------------------------------------------------------------------------

def sdf.rel(+out: String, +tdir: String) -> String:
  +p = S.b(tdir ++ "/")
  Bool.pick(String, S.prefix(S.b(out), p), S.str(List.drop(&2, U32, S.b(out), S.len(p))), out)

def sdf.s2.count(ds: List<&2, List<&2, U32>>, +acc: String) -> IO(Unit):
  match ds:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +d <> t:
      do IO<Unit>:
        xs : List<&2, U32> <- S.read(acc ++ "/" ++ S.str(d) ++ "/transcripts.train.nul")
        Ck.log("s2: " ++ S.str(d) ++ ": " ++ Nat.show(Nat.div(sdf.nuls(xs), 2n)) ++ " episodes")
        sdf.s2.count(t, acc)

def sdf.s2.acts(as: List<&2, String>) -> IO(Unit):
  match as:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +a <> t:
      do IO<Unit>:
        m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(a ++ "/accepted")
        sdf.s2.count(Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{}), a ++ "/accepted")
        sdf.s2.acts(t)

# REST_STEPS said; CTL_OUT's plan (`plan sim SIM_CTL_STEPS`, 20) and stage.env when it is set
def sdf.s2.ctl(+ctl: String, +rest: String) -> IO(Unit):
  do IO<Unit>:
    Bool.pick(IO(Unit), String.is_empty(rest), IO.pure(Unit, Unit{}), Ck.log("s2: REST_STEPS " ++ rest ++ " (bend-sim)"))
    +steps : Nat <- S.env.nat("SIM_CTL_STEPS", 20n)
    Bool.pick(IO(Unit), String.is_empty(ctl), IO.pure(Unit, Unit{}), S.rm(ctl))
    Bool.pick(IO(Unit), String.is_empty(ctl), IO.pure(Unit, Unit{}), S.mkdir(ctl))
    Bool.pick(IO(Unit), String.is_empty(ctl), IO.pure(Unit, Unit{}), S.write(ctl ++ "/plan-fp100m-b16-windows.tsv", S.b("plan sim " ++ Nat.show(steps) ++ "\n")))
    Bool.pick(IO(Unit), String.is_empty(ctl), IO.pure(Unit, Unit{}), S.write(ctl ++ "/stage.env", S.b("NLR=1e-4\nNWARM=10\n")))
    Bool.pick(IO(Unit), String.is_empty(ctl), IO.pure(Unit, Unit{}), Ck.log("s2: control: " ++ Nat.show(steps) ++ " steps in " ++ ctl ++ " (bend-sim)"))

def sdf.s2.build(+s1: String, +b: String, +out: String, +acts: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +steps : Nat <- S.env.nat("SIM_S2_STEPS", 30n)
    +every : String <- S.env("EVERY", "5000")
    +home : String <- S.env("HOME", "")
    +tdir : String <- S.env("TRAINER_DIR", home ++ "/ana")
    +rest : String <- S.env("REST_STEPS", "")
    +ctl : String <- S.env("CTL_OUT", "")
    S.rm(out)
    S.mkdir(out)
    sdf.s2.acts(acts)
    S.write(out ++ "/plan-fp100m-b16-windows.tsv", S.b("plan sim " ++ Nat.show(steps) ++ "\n"))
    S.write(out ++ "/stage.env", S.b("NLR=1e-4\nNWARM=10\n"))
    sdf.s2.ctl(ctl, rest)
    Ck.log("s2: S2 from " ++ s1 ++ " at step " ++ b ++ ": " ++ Nat.show(steps) ++ " steps in " ++ out ++ "; append to STAGES: (bend-sim)")
    IO.print("s2 traind-next " ++ every ++ " " ++ sdf.rel(out, tdir) ++ "/plan-fp100m-b16-windows.tsv " ++ sdf.rel(out, tdir) ++ " fp100m")

# BOUNDARY must be a step of S1's plan (`plan sim N`: at most N), as s2's must start one of its
# segments: a hot-started S1's global step (plan-base + BOUNDARY) is refused, as s2 refuses it
def sdf.s2(+s1: String, +b: String, +out: String, +acts: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +n : Nat <- S.size(s1 ++ "/plan-fp100m-b16-windows.tsv")
    +pl : List<&2, U32> <- S.read(s1 ++ "/plan-fp100m-b16-windows.tsv")
    +total : Nat = Maybe.default(&2, Nat, Lc.lcl.nat(Lc.lcl.nth(Lc.lcl.words(S.lines.first(pl)), 2n)), 0n)
    +bn : Nat = Maybe.default(&2, Nat, Lc.lcl.nat(S.b(b)), U32.to_nat(4000000000))
    fail : String <- S.env("SIM_S2_FAIL", "")
    Bool.pick(IO(Unit), Nat.is_eq(n, 0n), IO.die(Unit, 1, "s2: no plan " ++ s1 ++ "/plan-fp100m-b16-windows.tsv"),
      Bool.pick(IO(Unit), Nat.is_lt(total, bn), IO.die(Unit, 1, "s2: step " ++ b ++ " starts no segment of " ++ s1 ++ "/plan-fp100m-b16-windows.tsv (bend-sim: its plan has " ++ Nat.show(total) ++ " steps)"),
        Bool.pick(IO(Unit), String.is_empty(fail), sdf.s2.build(s1, b, out, acts),
          IO.die(Unit, 1, "s2: plan-windows: \n  shard 0: bend-windows failed (exit 1): windows: a transcript of 2158 tokens does not fit a window of 2046\n"))))

# The parts ----------------------------------------------------------------------------------------

def sdf.known(+r: String) -> Bool:
  Bool.or(Bool.or(Bool.or(String.eq(r, "systemd-run"), String.eq(r, "systemctl")), Bool.or(String.eq(r, "bend-corpus-v2"), String.eq(r, "deploy"))), String.eq(r, "bend-episode"))

def sdf.part(+r: String, +args: List<&2, String>) -> IO(Unit):
  match r args:
    case "systemd-run" a:
      sdf.systemd.run(a)
    case "systemctl" a:
      sdf.systemctl(a)
    case "bend-corpus-v2" "agent-act" <> +ck <> +dir <> more:
      sdf.act(ck, dir)
    case "deploy" "corpus-v2" <> "agent-act" <> +ck <> +dir <> more:
      sdf.act(ck, dir)
    case "deploy" "corpus-v2" <> "s2" <> +s1 <> +b <> +out <> +acts:
      sdf.s2(s1, b, out, acts)
    case "bend-episode" +mode <> c <> k <> +out <> +eplog <> Nil{}:
      sdf.episode.tool(mode, out, eplog)
    case _ _:
      IO.die(Unit, 2, "bend-sim (SIM_DRIVE): " ++ r ++ " " ++ sdf.join(args) ++ ": not simulated")
