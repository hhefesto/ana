import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc

# Unit: a long job as a systemd user unit, its command line recorded so it
# can be started again after a reboot (2026-10-15, the plan's Phase 4b; the
# user's rules: use the whole machine with generous caps rather than fewer
# workers, and a reboot kills transient systemd-run units: on 2026-10-05 a
# chain and its credit watch died silently for 3.5 h).
#
#   bend-ops unit start NAME [--mem X] [--out FILE] [--env K=V]... [--] CMD...
#       `systemctl --user reset-failed NAME`, then
#         systemd-run --user --unit=NAME -p MemoryMax=X -p OOMPolicy=continue
#           --working-directory=$PWD [-p StandardOutput=append:FILE
#           -p StandardError=append:FILE] [--setenv=K=V].. -- CMD..
#       (X 4G; FILE made absolute), recorded first under UNIT_STATE
#       ($HOME/.local/state/bend-ops/units): NAME.argv (the line's words, each
#       ending with a NUL) and NAME.line (the same, quoted for a shell, to read);
#       starts.log gets a stamped `start NAME`.  A unit that is active
#       (activating, reloading, deactivating) is left alone, its record too:
#       `NAME is active; not started`.
#       The command starts after `--` or at the first word that is not an option:
#       the Bend runtime takes the first `--` of a command line out of IO.args
#       (2026-10-15), so a `--` typed there never reaches this program.
#   bend-ops unit restart NAME
#       NAME's recorded line run again the same way (`restart NAME` in
#       starts.log), unless NAME is active: after a reboot the transient unit
#       is gone, its record is not
#   bend-ops unit stop NAME...     systemctl --user stop NAME... (the records stay)
#   bend-ops unit list             each recorded unit: NAME, its state (systemctl
#                                  --user is-active), its line
#
# systemd-run and systemctl are found on $PATH (in a sandbox, bend-sim's stand
# in for them).  The guard, the move and the hand-over start their units with
# unt.ensure.  A unit name is letters, digits and `-_.@:` (it names a file).
# Every name starts with `unt.`; the pure parts (the line, its quoting, the
# state) are tested in bend/tests/drive.bend.

type UntSpec is Data:
  UntSpec{name: String, mem: String, out: String, env: List<&2, String>, cmd: List<&2, String>}

def unt.s.name(+s: UntSpec) -> String:
  match s:
    case UntSpec{n, m, o, e, c}:
      n

def unt.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> unt.l1(t)

def unt.l2(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> unt.l2(t)

def unt.hd(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      x

def unt.tl(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      t

# The line (pure) ------------------------------------------------------------------------------

# P under DIR (an absolute P as it is)
def unt.abs(+dir: String, +p: String) -> String:
  Bool.pick(String, S.head.is(S.b(p), 47), p, dir ++ "/" ++ p)

def unt.out.args(+cwd: String, +o: String) -> List<&2, String>:
  +f = unt.abs(cwd, o)
  Bool.pick(List<&2, String>, String.is_empty(o), Nil{}, ["-p", "StandardOutput=append:" ++ f, "-p", "StandardError=append:" ++ f])

def unt.setenv(es: List<&2, String>) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case e <> t:
      ("--setenv=" ++ e) <> unt.setenv(t)

# the systemd-run line a unit runs as, from the directory cwd
def unt.argv(+s: UntSpec, +cwd: String) -> List<&2, String>:
  match s:
    case UntSpec{+n, +m, +o, e, c}:
      List.concat(&2, String, [["systemd-run", "--user", "--unit=" ++ n, "-p", "MemoryMax=" ++ m, "-p", "OOMPolicy=continue",
        "--working-directory=" ++ cwd], unt.out.args(cwd, o), unt.setenv(e), ["--"], c])

def unt.safe.c(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), Bool.and(U32.is_le(65, c), U32.is_le(c, 90))),
    Bool.or(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), S.infix(S.b("_@%+=:,./-"), [c])))

def unt.safe(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(unt.safe.c(c), unt.safe(t))

# a word as a shell reads it back: as it is when it needs no quotes, else in
# single quotes (a ' inside as '\'')
def unt.q(+w: String) -> String:
  +xs = S.b(w)
  Bool.pick(String, Bool.and(Nat.is_lt(0n, S.len(xs)), unt.safe(xs)), w, "'" ++ S.str(S.replace(xs, [39], S.b("'\\''"))) ++ "'")

def unt.line(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> Nil{}:
      unt.q(x)
    case x <> t:
      unt.q(x) ++ " " ++ unt.line(t)

# the record's bytes: each word with a NUL after it
def unt.rec.bytes(xs: List<&2, String>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      List.append(&2, U32, S.b(x), 0 <> unt.rec.bytes(t))

def unt.rec.words(ps: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> t:
      S.str(p) <> unt.rec.words(t)

# a record read back
def unt.rec.of(+xs: List<&2, U32>) -> List<&2, String>:
  unt.rec.words(S.split(xs, 0))

# `systemctl is-active`'s word (its first line), `unknown` when it printed none
def unt.state.of(+o: Lc.LclOut) -> String:
  +w = Lc.lcl.nth(Lc.lcl.words(Lc.lcl.out(o)), 0n)
  Bool.pick(String, Nat.is_eq(S.len(w), 0n), "unknown", S.str(w))

# a unit in one of these states is running (or about to): it is not started again
def unt.busy(+st: String) -> Bool:
  Bool.or(Bool.or(String.eq(st, "active"), String.eq(st, "activating")), Bool.or(String.eq(st, "reloading"), String.eq(st, "deactivating")))

def unt.name.c(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), Bool.and(U32.is_le(65, c), U32.is_le(c, 90))),
    Bool.or(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), S.infix(S.b("-_.@:"), [c])))

def unt.name.all(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(unt.name.c(c), unt.name.all(t))

def unt.name.ok(+n: String) -> Bool:
  +xs = S.b(n)
  Bool.and(Nat.is_lt(0n, S.len(xs)), Bool.and(unt.name.all(xs), Bool.not(S.head.is(xs, 46))))

# The machine ----------------------------------------------------------------------------------

def unt.dir() -> IO(String):
  do IO<String>:
    +h : String <- S.env("HOME", "")
    +d : String <- S.env("UNIT_STATE", "")
    return Bool.pick(String, String.is_empty(d), h ++ "/.local/state/bend-ops/units", d)

def unt.ctl(+args: List<&2, String>) -> IO(Lc.LclOut):
  Lc.lcl.run(120, "systemctl", unt.l1("--user" <> args))

def unt.state(+name: String) -> IO(String):
  do IO<String>:
    +o : Lc.LclOut <- unt.ctl(["is-active", name])
    return unt.state.of(o)

def unt.err(+xs: List<&2, U32>) -> IO(Unit):
  Bool.pick(IO(Unit), Nat.is_eq(S.len(xs), 0n), IO.pure(Unit, Unit{}), IO.print_err(S.str(S.chomp(xs))))

def unt.mark(+dir: String, +what: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.time()
    S.add(dir ++ "/starts.log", S.b(Ck.stamp(t) ++ " " ++ what ++ "\n"))

def unt.record(+dir: String, +name: String, +argv: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    S.write(dir ++ "/" ++ name ++ ".argv", unt.rec.bytes(argv))
    S.write(dir ++ "/" ++ name ++ ".line", S.b(unt.line(argv) ++ "\n"))

def unt.record.if(yes: Bool, +dir: String, +name: String, +argv: List<&2, String>) -> IO(Unit):
  match yes:
    case True{}:
      unt.record(dir, name, argv)
    case False{}:
      IO.pure(Unit, Unit{})

# what an attempt to start a unit came to
type UntRes is Data:
  UntActive{state: String}
  UntStarted{}
  UntFailed{why: String}

def unt.ran(ok: Bool, +o: Lc.LclOut, +dir: String, +what: String) -> IO(UntRes):
  match ok:
    case True{}:
      do IO<UntRes>:
        unt.mark(dir, what)
        return UntStarted{}
    case False{}:
      IO.pure(UntRes, UntFailed{"systemd-run exit " ++ U32.show(Lc.lcl.status(o)) ++ ": " ++ S.str(S.chomp(Lc.lcl.err(o)))})

def unt.go(busy: Bool, +st: String, +name: String, +argv: List<&2, String>, +dir: String, +what: String, +rec: Bool) -> IO(UntRes):
  match busy:
    case True{}:
      IO.pure(UntRes, UntActive{st})
    case False{}:
      do IO<UntRes>:
        r : Lc.LclOut <- unt.ctl(["reset-failed", name])
        unt.record.if(rec, dir, name, argv)
        +o : Lc.LclOut <- Lc.lcl.run(120, unt.hd(argv), unt.l1(unt.tl(argv)))
        unt.err(Lc.lcl.err(o))
        unt.ran(Lc.lcl.ok(o), o, dir, what ++ " " ++ name)

# a unit started unless it is active: its record written first, then its line run
def unt.ensure(+s: UntSpec, +cwd: String) -> IO(UntRes):
  +name = unt.s.name(s)
  do IO<UntRes>:
    +dir : String <- unt.dir()
    S.mkdir(dir)
    +st : String <- unt.state(name)
    unt.go(unt.busy(st), st, name, unt.argv(s, cwd), dir, "start", True{})

def unt.rec.got(m: Maybe<&2, List<&2, U32>>, +name: String) -> IO(List<&2, String>):
  match m:
    case Some{+xs}:
      IO.pure(List<&2, String>, unt.rec.of(xs))
    case None{}:
      IO.die(List<&2, String>, 1, "unit: no recorded unit " ++ name)

# a recorded unit started again, unless it is active
def unt.again(+name: String) -> IO(UntRes):
  do IO<UntRes>:
    +dir : String <- unt.dir()
    m : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/" ++ name ++ ".argv")
    +argv : List<&2, String> <- unt.rec.got(m, name)
    +st : String <- unt.state(name)
    unt.go(unt.busy(st), st, name, argv, dir, "restart", False{})

def unt.stop(+names: List<&2, String>) -> IO(Lc.LclOut):
  unt.ctl("stop" <> names)

# The command ----------------------------------------------------------------------------------

def unt.say(r: UntRes, +name: String, +verb: String) -> IO(Unit):
  match r:
    case UntActive{+st}:
      IO.print_err(name ++ " is " ++ st ++ "; not " ++ verb)
    case UntStarted{}:
      IO.print_err(verb ++ " " ++ name)
    case UntFailed{+w}:
      IO.die(Unit, 1, "unit: " ++ name ++ " not " ++ verb ++ ": " ++ w)

type UntOpt is Data:
  UntOpt{mem: String, out: String, env: List<&2, String>, cmd: List<&2, String>}

def unt.opt.mem(o: UntOpt, +m: String) -> UntOpt:
  match o:
    case UntOpt{a, b, c, d}:
      UntOpt{m, b, c, d}

def unt.opt.out(o: UntOpt, +f: String) -> UntOpt:
  match o:
    case UntOpt{a, b, c, d}:
      UntOpt{a, f, c, d}

def unt.opt.env(o: UntOpt, +e: String) -> UntOpt:
  match o:
    case UntOpt{a, b, c, d}:
      UntOpt{a, b, List.append(&2, String, c, [e]), d}

def unt.opt.cmd(o: UntOpt, xs: List<&2, String>) -> UntOpt:
  match o:
    case UntOpt{a, b, c, d}:
      UntOpt{a, b, c, xs}

# start's options, then the command: after `--`, or from the first word that is not an
# option (the Bend runtime takes the first `--` of a command line out of IO.args, so
# `unit start NAME -- CMD` reaches here without it); None: an option without its value
def unt.opts(xs: List<&2, String>, o: UntOpt) -> Maybe<&2, UntOpt>:
  match xs:
    case "--mem" <> +m <> t:
      unt.opts(t, unt.opt.mem(o, m))
    case "--out" <> +f <> t:
      unt.opts(t, unt.opt.out(o, f))
    case "--env" <> +e <> t:
      unt.opts(t, unt.opt.env(o, e))
    case "--mem" <> Nil{}:
      None{}
    case "--out" <> Nil{}:
      None{}
    case "--env" <> Nil{}:
      None{}
    case "--" <> t:
      Some{unt.opt.cmd(o, t)}
    case +w <> +t:
      Some{unt.opt.cmd(o, w <> t)}
    case Nil{}:
      Some{unt.opt.cmd(o, Nil{})}

def unt.usage() -> String:
  "usage: bend-ops unit start NAME [--mem X] [--out FILE] [--env K=V]... [--] CMD... | restart NAME | stop NAME... | list   (UNIT_STATE)"

def unt.name.need(+n: String) -> IO(Unit):
  Bool.pick(IO(Unit), unt.name.ok(n), IO.pure(Unit, Unit{}), IO.die(Unit, 2, "unit: not a unit name: " ++ n))

def unt.start.run(+name: String, +o: UntOpt) -> IO(Unit):
  match o:
    case UntOpt{+mem, +out, +env, +cmd}:
      do IO<Unit>:
        +cwd : String <- S.realpath(".")
        r : UntRes <- unt.ensure(UntSpec{name, mem, out, env, cmd}, cwd)
        unt.say(r, name, "started")

def unt.cmd.empty(+o: UntOpt) -> Bool:
  match o:
    case UntOpt{a, b, c, d}:
      List.is_empty(&2, String, d)

def unt.start.got(m: Maybe<&2, UntOpt>, +name: String) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 2, unt.usage())
    case Some{+o}:
      Bool.pick(IO(Unit), unt.cmd.empty(o), IO.die(Unit, 2, unt.usage()), unt.start.run(name, o))

def unt.list.one(+dir: String, +n: List<&2, U32>) -> IO(Unit):
  +name = S.str(List.take(&2, U32, n, Nat.sub(S.len(n), 5n)))
  do IO<Unit>:
    +st : String <- unt.state(name)
    l : List<&2, U32> <- S.read(dir ++ "/" ++ name ++ ".line")
    IO.print(name ++ "\t" ++ st ++ "\t" ++ S.str(S.chomp(l)))

def unt.list.go(ns: List<&2, List<&2, U32>>, +dir: String) -> IO(Unit):
  match ns:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +n <> t:
      do IO<Unit>:
        Bool.pick(IO(Unit), S.suffix(n, S.b(".argv")), unt.list.one(dir, n), IO.pure(Unit, Unit{}))
        unt.list.go(t, dir)

def unt.list() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- unt.dir()
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(dir)
    unt.list.go(Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{}), dir)

def unt.go.args(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "start" <> +name <> rest:
      do IO<Unit>:
        unt.name.need(name)
        unt.start.got(unt.opts(rest, UntOpt{"4G", "", Nil{}, Nil{}}), name)
    case "restart" <> +name <> Nil{}:
      do IO<Unit>:
        unt.name.need(name)
        r : UntRes <- unt.again(name)
        unt.say(r, name, "restarted")
    case "stop" <> +n <> +ns:
      do IO<Unit>:
        +o : Lc.LclOut <- unt.stop(n <> ns)
        unt.err(List.append(&2, U32, Lc.lcl.out(o), Lc.lcl.err(o)))
        Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "unit: systemctl stop exit " ++ U32.show(Lc.lcl.status(o))))
    case "list" <> Nil{}:
      unt.list()
    case _:
      IO.die(Unit, 2, unt.usage())

def unt.main(xs: List<String>) -> IO(Unit):
  unt.go.args(unt.l2(xs))
