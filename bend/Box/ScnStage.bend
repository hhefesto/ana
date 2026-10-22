import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc
import ./Scenario.bend as Sc

# ScnStage: the staging, feed, act and dense-identity paths against a box in a
# sandbox, each new path against the script it replaces (2026-10-15, the
# plan's Phase 1c; the box, the stubs and the comparisons of Phase 1a,
# bend/Box/Scenario.bend, without a box, a GPU or money).
#
#   bend-ops sim stage N DIR     scenario N (a number or its name, below) in DIR/ID-new and
#                                DIR/ID-old, each wiped first; `ok`/`FAIL` lines, exit 1 on a FAIL
#   bend-ops sim stage all DIR   every scenario, one after the other
#
# The scenarios (sst.names): box (stage box / fp-stage.sh), push, push-drop (rsync's 3rd call
# fails), push-corrupt (a same-size, same-mtime wrong shard on the box) (stage push /
# next-stage.sh push), restage (stage restage / fp-restage.sh: a stage and a raw slice),
# raw-push (stage raw push / raw-stage.sh push), feed (feed / raw-driver.sh: the credit guard
# waits, a push tried again, STAGES, a slice that does not build), act-setup, act-ckpt,
# act-check, act-check-fail (a checker that errs more than it answers), act-start, act-pull
# (act MODE / act-box.sh MODE), act-ensure (act ensure / run 3's act-restart.sh), chain-start-drop
# and chain-outage (Phase 1a's chain: a start that fails before the launch, a box unreachable
# past SSH_TRIES x SSH_RETRY_SLEEP), dense-identity (dense-identity / dense-identity.sh).
# The old scripts' sleeps run through bend-sim's `sleep` (1 s at most); the new side's are
# set by its environment (FEED_WAIT, RETRY_SLEEP, ENSURE_WAIT, ...).  SIM_NEW_ONLY=1 runs the
# new side alone against its own expectations (the flake check ops-sim).
#
# A run's directory D holds bin/ (bend-sim as ssh, scp, rsync, nix, bend, bend-push, sleep,
# systemctl, notify-send and vastai, and the real bend-corpus-v2: first on PATH), box/ (the
# box's home: bin/ with its clang-19, nvidia-smi, pgrep, pkill, elan, lake, bend-corpus-v2 and
# bend-episode; formalTransformer/; for act, ws/, home/, usr/local/bin/ and etc/nix/, which
# box/.sim-map puts in place of the absolute paths), repo/ (the repository the command runs in:
# fixtures, and the old scripts as they ran before they were unwired, Sc.scn.copy.live), home/,
# vast/ (the vastai stub's state), tmp/ (TMPDIR), calls (the stubs' recorded calls here),
# box/.calls (on the box), NAME.out and NAME.rc (the command's output and exit status).  The
# command runs with `env -i` and a fixed environment (PATH D/bin first, HOME, TMPDIR, the
# stubs' settings, SSH_TRIES 3, SSH_RETRY_SLEEP 1, RSYNC_TRIES 3, PULL_WAIT 1), so the old
# and the new side see the same world.
#
# Old against new, for every scenario: the exit statuses; the box's files (relative path and
# sha256, a link's target; the box's own bin/ and the stubs' dot files left out); the calls the
# stubs recorded; the output's lines with their UTC-6 stamps taken out, the sandbox's path as
# <D> and mktemp's names as <D>/tmp/tmp.*; for some, local files too.  Every difference must be
# declared by the scenario, with its class: `deliberate` (the plan's approved changes, or the
# phase's documented ones), `fix` (the old script was wrong: it stopped where it should retry,
# ...) or `form` (the same act, other words); one not declared, or a declared one that does not
# show, is a FAIL.  Each declared difference prints as an `ok` line: the old-against-new table.
#
# What it needs: bend-sim (BEND_SIM, else on $PATH), bend-box (BEND_BOX: its links), the
# repository (SIM_REPO, else the current directory: the old scripts and the fixtures), rsync,
# bend-corpus-v2 (SIM_CV2), bend-push (SIM_PUSH, else on $PATH), bend-episode (SIM_EPISODE,
# else on $PATH) and, for dense-identity, bend-train-dense (SIM_TRAINER, else built from
# SIM_REPO's flake).
#
# Every name starts with `sst.`.

# The tools and a run -------------------------------------------------------------------------

type SstT is Data:
  SstT{sc: Sc.ScnTools, push: String, ep: String, only: Bool}

def sst.sc(+t: SstT) -> Sc.ScnTools:
  match t:
    case SstT{s, p, e, o}:
      s

def sst.pushb(+t: SstT) -> String:
  match t:
    case SstT{s, p, e, o}:
      p

def sst.epb(+t: SstT) -> String:
  match t:
    case SstT{s, p, e, o}:
      e

# SIM_NEW_ONLY=1: the new side alone, its own expectations, no old run to compare (the flake
# check ops-sim, inside the nix build sandbox)
def sst.only(+t: SstT) -> Bool:
  match t:
    case SstT{s, p, e, o}:
      o

# ScnTools' fields: 0 bend-ops, 1 bend-sim, 2 bend-box, 3 the repository, 4 PATH, 5 rsync, 6 bend-corpus-v2
def sst.tl(+s: Sc.ScnTools, +i: Nat) -> String:
  match s:
    case Sc.ScnTools{a, b, c, d, e, f, g}:
      Maybe.default(&2, String, List.get(&2, String, [a, b, c, d, e, f, g], i), "")

def sst.self(+t: SstT) -> String:
  sst.tl(sst.sc(t), 0n)

def sst.sim(+t: SstT) -> String:
  sst.tl(sst.sc(t), 1n)

def sst.bbox(+t: SstT) -> String:
  sst.tl(sst.sc(t), 2n)

def sst.repo(+t: SstT) -> String:
  sst.tl(sst.sc(t), 3n)

def sst.path(+t: SstT) -> String:
  sst.tl(sst.sc(t), 4n)

def sst.rsync(+t: SstT) -> String:
  sst.tl(sst.sc(t), 5n)

def sst.cv2(+t: SstT) -> String:
  sst.tl(sst.sc(t), 6n)

# a run: its directory, its tag (ID-new, ID-old), whether it runs the old script
type SstC is Data:
  SstC{d: String, tag: String, old: Bool, t: SstT}

def sst.d(+c: SstC) -> String:
  match c:
    case SstC{d, g, o, t}:
      d

def sst.tag(+c: SstC) -> String:
  match c:
    case SstC{d, g, o, t}:
      g

def sst.old(+c: SstC) -> Bool:
  match c:
    case SstC{d, g, o, t}:
      o

def sst.t(+c: SstC) -> SstT:
  match c:
    case SstC{d, g, o, t}:
      t

def sst.box(+c: SstC) -> String:
  sst.d(c) ++ "/box"

def sst.ft(+c: SstC) -> String:
  sst.d(c) ++ "/box/formalTransformer"

def sst.rp(+c: SstC) -> String:
  sst.d(c) ++ "/repo"

def sst.host(+id: String) -> String:
  "root@sim-" ++ id

# Phase 1a's run, for its helpers (the box's processes, killed at the end)
def sst.scx(+c: SstC) -> Sc.ScnCx:
  +t = sst.t(c)
  Sc.ScnCx{sst.d(c), sst.tag(c), sst.old(c), sst.self(t), sst.sim(t), sst.repo(t), Nil{}, "root@sim-" ++ sst.tag(c), sst.bbox(t)}

def sst.say(+c: SstC, +msg: String) -> IO(Unit):
  Ck.log("sim " ++ sst.tag(c) ++ ": " ++ msg)

def sst.l1(xs: List<&2, String>) -> List<String>:
  Sc.scn.l1(xs)

def sst.lines(xs: List<&2, String>) -> String:
  Sc.scn.lines(xs)

def sst.put(+path: String, +text: String) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(S.parent(path))
    S.write(path, S.b(text))

# n bytes of text that depend on seed only (a shard, a checkpoint)
def sst.blob(+seed: String, +n: Nat) -> String:
  +line = "sim blob " ++ seed ++ "\n"
  S.str(List.take(&2, U32, S.b(String.repeat(line, Nat.add(Nat.div(n, Nat.max(String.length(line), 1n)), 1n))), n))

def sst.run.cmd(+secs: U32, +prog: String, args: List<&2, String>) -> IO(Lc.LclOut):
  Lc.lcl.run(secs, prog, sst.l1(args))

# SRC copied to DST as it ran before it was unwired (no header), FROM replaced by TO in it
def sst.copy.sub(+src: String, +dst: String, +from: String, +to: String) -> IO(Unit):
  do IO<Unit>:
    t : List<&2, U32> <- S.read(src)
    +live : List<&2, U32> = S.join(Sc.scn.unwired.drop(S.split.lines(t)), 10)
    S.mkdir(S.parent(dst))
    S.write(dst, List.append(&2, U32, Bool.pick(List<&2, U32>, String.is_empty(from), live, S.replace(live, S.b(from), S.b(to))), [10]))
    o : Lc.LclOut <- sst.run.cmd(30, "chmod", ["+x", dst])
    return Unit{}

def sst.copy.old(+c: SstC, +rel: String) -> IO(Unit):
  sst.copy.sub(sst.repo(sst.t(c)) ++ "/" ++ rel, sst.rp(c) ++ "/" ++ rel, "", "")

def sst.copies(+c: SstC, rs: List<&2, String>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> t:
      do IO<Unit>:
        sst.copy.old(c, r)
        sst.copies(c, t)

# The sandbox ---------------------------------------------------------------------------------

def sst.base(+c: SstC, +boxenv: List<&2, String>) -> IO(Unit):
  +d = sst.d(c)
  +t = sst.t(c)
  do IO<Unit>:
    S.rm(d)
    S.mkdir(d ++ "/bin")
    S.mkdir(sst.box(c) ++ "/bin")
    S.mkdir(sst.ft(c))
    S.mkdir(sst.rp(c))
    S.mkdir(d ++ "/home")
    S.mkdir(d ++ "/vast")
    S.mkdir(d ++ "/tmp")
    Sc.scn.links(sst.sim(t), d ++ "/bin", ["ssh", "scp", "rsync", "nix", "bend", "bend-push", "sleep", "systemctl", "notify-send", "vastai"])
    Sc.scn.links(sst.cv2(t), d ++ "/bin", ["bend-corpus-v2"])
    Sc.scn.links(sst.sim(t), sst.box(c) ++ "/bin", ["clang-19", "nvidia-smi", "pgrep", "pkill", "elan", "lake", "bend-corpus-v2", "bend-episode"])
    # TZDIR: a box's scripts stamp with `TZ=Etc/GMT+6 date`, whose zone NixOS keeps there
    +tz : String <- S.env("TZDIR", "/etc/zoneinfo")
    S.write(sst.box(c) ++ "/.sim-env", S.b(sst.lines(List.append(&2, String, ["SIM_CALLS=" ++ sst.box(c) ++ "/.calls", "TZDIR=" ++ tz], boxenv))))
    S.write(d ++ "/vast/instances", S.b("4242 running\n"))
    S.write(d ++ "/vast/credit", S.b("10.0\n"))

# the environment a command runs in (`env -i`: nothing else of ours)
def sst.env(+c: SstC, +extra: List<&2, String>) -> List<&2, String>:
  +d = sst.d(c)
  +t = sst.t(c)
  List.append(&2, String, ["PATH=" ++ d ++ "/bin:" ++ sst.path(t), "HOME=" ++ d ++ "/home", "USER=sim", "LOGNAME=sim", "TMPDIR=" ++ d ++ "/tmp",
    "SIM_BOX_HOME=" ++ sst.box(c), "SIM_BOX_PATH=" ++ sst.path(t), "SIM_RSYNC=" ++ sst.rsync(t), "SIM_CALLS=" ++ d ++ "/calls",
    "SIM_PUSH=" ++ sst.pushb(t), "SIM_VAST_DIR=" ++ d ++ "/vast", "SIM_ALERTS=" ++ d ++ "/alerts", "SIM_SLEEP_CAP=1", "V=" ++ d ++ "/bin/vastai",
    "CV2=" ++ sst.cv2(t), "SSH_OPTS=", "SSH_TRIES=3", "SSH_RETRY_SLEEP=1", "RSYNC_TRIES=3", "PULL_WAIT=1"], extra)

# ARGV in D/repo, to its end (SECS at most): D/NAME.out (stdout, then stderr) and D/NAME.rc
def sst.run(+c: SstC, +name: String, +extra: List<&2, String>, +argv: List<&2, String>, +secs: U32) -> IO(U32):
  +d = sst.d(c)
  do IO<U32>:
    sst.say(c, name ++ ": " ++ String.join(argv, " "))
    # TZDIR: where `TZ=Etc/GMT+6 date` (the old scripts' stamps) finds its zone on NixOS
    +tz : String <- S.env("TZDIR", "/etc/zoneinfo")
    +o : Lc.LclOut <- sst.run.cmd(secs, "env", List.concat(&2, String, [["-i", "-C", sst.rp(c), "TZDIR=" ++ tz], sst.env(c, extra), argv]))
    S.write(d ++ "/" ++ name ++ ".out", List.append(&2, U32, Lc.lcl.out(o), Lc.lcl.err(o)))
    S.write(d ++ "/" ++ name ++ ".rc", S.b(U32.show(Lc.lcl.status(o)) ++ "\n"))
    sst.say(c, name ++ " ended with status " ++ U32.show(Lc.lcl.status(o)))
    return Lc.lcl.status(o)

# the box's processes a run left (a detached act round, ...)
def sst.cleanup(+c: SstC) -> IO(Unit):
  Sc.scn.box.kill(sst.scx(c), ["bend-corpus-v2", "deploy", "bash", "sh", "sleep"])

# Text: normalised lines ----------------------------------------------------------------------

def sst.tmp.mask(fuel: Nat, +xs: List<&2, U32>, +p: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match fuel m:
    case 0n _:
      xs
    case _ None{}:
      xs
    case 1n+f Some{+k}:
      +rest = List.drop(&2, U32, xs, Nat.add(Nat.add(k, S.len(p)), 10n))
      List.concat(&2, U32, [List.take(&2, U32, xs, Nat.add(k, S.len(p))), [42], sst.tmp.mask(f, rest, p, S.find(rest, p, 0n))])

# the sandbox's path as <D>, mktemp's tmp.XXXXXXXXXX under it as tmp.*
def sst.norm(+d: String, +xs: List<&2, U32>) -> List<&2, U32>:
  +ys = S.replace(xs, S.b(d), S.b("<D>"))
  +p = S.b("<D>/tmp/tmp.")
  sst.tmp.mask(1n+S.len(ys), ys, p, S.find(ys, p, 0n))

def sst.ignored(ps: List<&2, String>, +l: List<&2, U32>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> t:
      Bool.or(S.infix(l, S.b(p)), sst.ignored(t, l))

def sst.keep(ls: List<&2, List<&2, U32>>, +d: String, +ign: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l0 <> t:
      +l = sst.norm(d, Sc.scn.unstamp(l0))
      +rest = sst.keep(t, d, ign)
      Bool.pick(List<&2, String>, Bool.or(Nat.is_eq(S.len(l), 0n), sst.ignored(ign, l)), rest, S.str(l) <> rest)

# a file's lines, normalised, those holding one of IGN left out
def sst.text(+c: SstC, +path: String, +ign: List<&2, String>) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    xs : List<&2, U32> <- S.read(path)
    return sst.keep(S.split.lines(xs), sst.d(c), ign)

# The box's files: `PATH  SHA256`, `PATH -> TARGET` or `PATH/`, sorted -----------------------

# the box's own bin/ and tmp/, and the stubs' dot files at its top, are not the box's state
def sst.skip(+p: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(Nat.is_eq(S.len(p), 0n), Bool.and(S.head.is(p, 46), Bool.not(S.infix(p, [47])))),
    Bool.or(Bool.or(S.eq(p, S.b("bin")), S.prefix(p, S.b("bin/"))), Bool.or(S.eq(p, S.b("tmp")), S.prefix(p, S.b("tmp/")))))

# a tree's entries: files to hash, logs (*.log: stamped lines, compared by their text with the
# stamps out), and the lines already made (links, directories, ...)
type SstE is Data:
  SstE{files: List<&2, List<&2, U32>>, logs: List<&2, List<&2, U32>>, rest: List<&2, String>}

def sst.ent.add(+e: List<&2, U32>, +d: String, acc: SstE) -> SstE:
  match acc:
    case SstE{+files, +logs, +rest}:
      +fs = S.split(e, 9)
      +ty = Lc.lcl.nth(fs, 0n)
      +p = Lc.lcl.nth(fs, 1n)
      Bool.pick(SstE, Bool.or(sst.skip(p), Bool.or(S.eq(p, S.b(".git")), S.prefix(p, S.b(".git/")))), SstE{files, logs, rest},
        Bool.pick(SstE, S.suffix(p, S.b("check-cache/agda/libraries")), SstE{files, logs, (S.str(p) ++ "  (it names the sandbox's path: not hashed)") <> rest},
        Bool.pick(SstE, Bool.and(S.eq(ty, S.b("f")), S.suffix(p, S.b(".log"))), SstE{files, p <> logs, rest},
        Bool.pick(SstE, S.eq(ty, S.b("f")), SstE{p <> files, logs, rest},
          Bool.pick(SstE, S.eq(ty, S.b("l")), SstE{files, logs, (S.str(p) ++ " -> " ++ S.str(sst.norm(d, Lc.lcl.nth(fs, 2n)))) <> rest},
            SstE{files, logs, (S.str(p) ++ "/") <> rest})))))

# each log as `PATH  log: LINE | LINE ...` (stamps out, the sandbox as <D>)
def sst.logs(ls: List<&2, List<&2, U32>>, +dir: String, +d: String) -> IO(List<&2, String>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +l <> t:
      do IO<List<&2, String>>:
        xs : List<&2, U32> <- S.read(dir ++ "/" ++ S.str(l))
        +rest : List<&2, String> <- sst.logs(t, dir, d)
        return (S.str(l) ++ "  log: " ++ String.join(sst.keep(S.split.lines(xs), d, Nil{}), " | ")) <> rest

def sst.entries(es: List<&2, List<&2, U32>>, +d: String, acc: SstE) -> SstE:
  match es:
    case Nil{}:
      acc
    case +e <> t:
      sst.entries(t, d, sst.ent.add(e, d, acc))

def sst.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.str(x) <> sst.strs(t)

def sst.sort(+xs: List<&2, String>) -> List<&2, String>:
  sst.strs(Lc.lcl.sort(Sc.scn.bytes(xs)))

def sst.sum.lines(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = sst.sum.lines(t)
      Bool.pick(List<&2, String>, Nat.is_lt(66n, S.len(l)), (S.str(List.drop(&2, U32, l, 66n)) ++ "  " ++ S.str(List.take(&2, U32, l, 64n))) <> rest, rest)

def sst.sums(+dir: String, fs: List<&2, List<&2, U32>>) -> IO(List<&2, String>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +f <> t:
      do IO<List<&2, String>>:
        +o : Lc.LclOut <- sst.run.cmd(600, "env", List.append(&2, String, ["-C", dir, "sha256sum", "--"], sst.strs(f <> t)))
        return sst.sum.lines(S.split.lines(Lc.lcl.out(o)))

def sst.tree.of(e: SstE, +dir: String, +d: String) -> IO(List<&2, String>):
  match e:
    case SstE{+files, +logs, +rest}:
      do IO<List<&2, String>>:
        +ss : List<&2, String> <- sst.sums(dir, files)
        +ls : List<&2, String> <- sst.logs(logs, dir, d)
        return sst.sort(List.concat(&2, String, [ss, ls, rest]))

# every file, link and directory under DIR (D the sandbox, shown as <D> in a link or a log)
def sst.tree(+dir: String, +d: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +o : Lc.LclOut <- sst.run.cmd(600, "find", [dir, "-mindepth", "1", "-printf", "%y\\t%P\\t%l\\0"])
    sst.tree.of(sst.entries(S.split(Lc.lcl.out(o), 0), d, SstE{Nil{}, Nil{}, Nil{}}), dir, d)

# Old against new ---------------------------------------------------------------------------------
#
# A declared difference: the comparison it belongs to (status, box, calls, box calls, vast,
# lines, local), its side (only in the new run's, or only in the old's), a piece of the lines
# it explains, and its class with why.

type SstDf is Data:
  SstDf{what: String, nw: Bool, pat: String, cls: String}

def sst.dnew(+what: String, +pat: String, +cls: String) -> SstDf:
  SstDf{what, True{}, pat, cls}

def sst.dold(+what: String, +pat: String, +cls: String) -> SstDf:
  SstDf{what, False{}, pat, cls}

def sst.dl(+xs: List<&2, SstDf>) -> List<&2, SstDf>:
  xs

def sst.df.hit(+d: SstDf, +what: String, +nw: Bool, +l: String) -> Bool:
  match d:
    case SstDf{w, n, p, k}:
      Bool.and(Bool.and(String.eq(w, what), Sc.scn.same(n, nw)), S.infix(S.b(l), S.b(p)))

def sst.explained(ds: List<&2, SstDf>, +what: String, +nw: Bool, +l: String) -> Bool:
  match ds:
    case Nil{}:
      False{}
    case +d <> t:
      Bool.or(sst.df.hit(d, what, nw, l), sst.explained(t, what, nw, l))

def sst.unexplained(ls: List<&2, String>, +ds: List<&2, SstDf>, +what: String, +nw: Bool) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = sst.unexplained(t, ds, what, nw)
      Bool.pick(List<&2, String>, sst.explained(ds, what, nw, l), rest, l <> rest)

def sst.matching(ls: List<&2, String>, +pat: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = sst.matching(t, pat)
      Bool.pick(List<&2, String>, S.infix(S.b(l), S.b(pat)), l <> rest, rest)

def sst.side(+nw: Bool) -> String:
  Bool.pick(String, nw, "only new", "only old")

def sst.first(+xs: List<&2, String>) -> String:
  Maybe.default(&2, String, List.head(&2, String, xs), "")

def sst.df.one(+id: String, +w: String, +n: Bool, +k: String, +hits: List<&2, String>) -> Sc.ScnRes:
  +c = List.length(&2, String, hits)
  Sc.ScnRes{id ++ " " ++ w ++ ": " ++ sst.side(n) ++ " [" ++ k ++ "]: " ++ Nat.show(c) ++ " line(s), e.g. `" ++ sst.first(hits) ++ "`", Nat.is_lt(0n, c),
    "declared, but no such line"}

def sst.df.res(+id: String, +what: String, d: SstDf, +on: List<&2, String>, +oo: List<&2, String>) -> List<&2, Sc.ScnRes>:
  match d:
    case SstDf{+w, +n, +p, +k}:
      Bool.pick(List<&2, Sc.ScnRes>, String.eq(w, what), [sst.df.one(id, w, n, k, sst.matching(Bool.pick(List<&2, String>, n, on, oo), p))], Nil{})

def sst.dfs.res(ds: List<&2, SstDf>, +id: String, +what: String, +on: List<&2, String>, +oo: List<&2, String>) -> List<&2, Sc.ScnRes>:
  match ds:
    case Nil{}:
      Nil{}
    case +d <> t:
      List.append(&2, Sc.ScnRes, sst.df.res(id, what, d, on, oo), sst.dfs.res(t, id, what, on, oo))

def sst.fails(ls: List<&2, String>, +id: String, +what: String, +nw: Bool) -> List<&2, Sc.ScnRes>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Sc.ScnRes{id ++ " " ++ what ++ ": " ++ sst.side(nw) ++ " `" ++ l ++ "`", False{}, "a difference no declared class explains"} <> sst.fails(t, id, what, nw)

# N (new) against O (old), as multisets: every difference declared, every declaration seen
def sst.cmp(+id: String, +what: String, +n: List<&2, String>, +o: List<&2, String>, +ds: List<&2, SstDf>) -> List<&2, Sc.ScnRes>:
  +on = Sc.scn.minus(n, o)
  +oo = Sc.scn.minus(o, n)
  +un = sst.unexplained(on, ds, what, True{})
  +uo = sst.unexplained(oo, ds, what, False{})
  List.concat(&2, Sc.ScnRes, [[Sc.ScnRes{id ++ " " ++ what ++ ": old = new but for the declared differences (" ++ Nat.show(List.length(&2, String, n)) ++ " new, "
    ++ Nat.show(List.length(&2, String, o)) ++ " old)", Bool.and(List.is_empty(&2, String, un), List.is_empty(&2, String, uo)), ""}],
    sst.dfs.res(ds, id, what, on, oo), sst.fails(un, id, what, True{}), sst.fails(uo, id, what, False{})])

# what a side left: its status, the box's files, the stubs' calls (here, on the box, vastai's),
# its output's lines, the repository's files
type SstR is Data:
  SstR{rc: String, box: List<&2, String>, calls: List<&2, String>, bcalls: List<&2, String>, vast: List<&2, String>, out: List<&2, String>, loc: List<&2, String>}

def sst.result(+c: SstC, +name: String, +ign: List<&2, String>) -> IO(SstR):
  +d = sst.d(c)
  do IO<SstR>:
    +rc : List<&2, U32> <- S.read(d ++ "/" ++ name ++ ".rc")
    +bx : List<&2, String> <- sst.tree(sst.box(c), d)
    +cl : List<&2, String> <- sst.text(c, d ++ "/calls", Nil{})
    +bc : List<&2, String> <- sst.text(c, sst.box(c) ++ "/.calls", Nil{})
    +vc : List<&2, String> <- sst.text(c, d ++ "/vast/calls", Nil{})
    +out : List<&2, String> <- sst.text(c, d ++ "/" ++ name ++ ".out", ign)
    +loc : List<&2, String> <- sst.tree(sst.rp(c), d)
    return SstR{"exit " ++ S.str(S.chomp(rc)), bx, cl, bc, vc, out, loc}

def sst.compare(+id: String, n: SstR, o: SstR, +ds: List<&2, SstDf>) -> List<&2, Sc.ScnRes>:
  match n o:
    case SstR{+r1, +b1, +c1, +x1, +v1, +l1, +p1} SstR{+r2, +b2, +c2, +x2, +v2, +l2, +p2}:
      List.concat(&2, Sc.ScnRes, [sst.cmp(id, "status", [r1], [r2], ds), sst.cmp(id, "box", b1, b2, ds), sst.cmp(id, "calls", c1, c2, ds),
        sst.cmp(id, "box calls", x1, x2, ds), sst.cmp(id, "vast", v1, v2, ds), sst.cmp(id, "lines", l1, l2, ds), sst.cmp(id, "local", p1, p2, ds)])

def sst.rc(+r: SstR) -> String:
  match r:
    case SstR{rc, b, c, x, v, l, p}:
      rc

def sst.boxof(+r: SstR) -> List<&2, String>:
  match r:
    case SstR{rc, b, c, x, v, l, p}:
      b

def sst.locof(+r: SstR) -> List<&2, String>:
  match r:
    case SstR{rc, b, c, x, v, l, p}:
      p

def sst.outof(+r: SstR) -> List<&2, String>:
  match r:
    case SstR{rc, b, c, x, v, l, p}:
      l

def sst.bcallsof(+r: SstR) -> List<&2, String>:
  match r:
    case SstR{rc, b, c, x, v, l, p}:
      x

def sst.ex(+id: String, +what: String, +ok: Bool) -> Sc.ScnRes:
  Sc.ScnRes{id ++ ": " ++ what, ok, ""}

# a line of XS that holds P
def sst.any(xs: List<&2, String>, +p: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +x <> t:
      Bool.or(S.infix(S.b(x), S.b(p)), sst.any(t, p))

def sst.cx(+t: SstT, +base: String, +id: String, +old: Bool) -> SstC:
  +tag = id ++ Bool.pick(String, old, "-old", "-new")
  SstC{base ++ "/" ++ tag, tag, old, t}

# Waiting for what a command left running (a detached act round): a file under D holding a text
def sst.wait.step(+path: String, +text: String) -> IO(Sc.ScnW):
  do IO<Sc.ScnW>:
    xs : List<&2, U32> <- S.read(path)
    Sc.scn.trig.rest(S.infix(xs, S.b(text)))

def sst.wait.go(fuel: Nat, +path: String, +text: String, w: Sc.ScnW) -> IO(Bool):
  match fuel w:
    case _ Sc.ScnW{True{}}:
      IO.pure(Bool, True{})
    case 0n Sc.ScnW{False{}}:
      IO.pure(Bool, False{})
    case 1n+f Sc.ScnW{False{}}:
      IO.bind(Sc.ScnW, Bool, sst.wait.step(path, text), sst.wait.go(f, path, text))

# D/REL holds TEXT, SECS at most (no REL: nothing to wait for)
def sst.wait(+c: SstC, +rel: String, +text: String, +secs: Nat) -> IO(Unit):
  do IO<Unit>:
    ok : Bool <- Bool.pick(IO(Bool), String.is_empty(rel), IO.pure(Bool, True{}), sst.wait.go(Nat.mul(secs, 5n), sst.d(c) ++ "/" ++ rel, text, Sc.ScnW{False{}}))
    Bool.pick(IO(Unit), ok, IO.pure(Unit, Unit{}), sst.say(c, "waited " ++ Nat.show(secs) ++ " s for `" ++ text ++ "` in " ++ rel ++ "; it did not come"))

# the two runs of a scenario whose fixtures are in place: the new command, then the old, each to
# its end (SECS at most) and, when WREL is given, until D/WREL holds WTEXT (what they left running
# has finished); the box's leftovers killed; what each left
def sst.both.w(+cn: SstC, +co: SstC, +ne: List<&2, String>, +na: List<&2, String>, +oe: List<&2, String>, +oa: List<&2, String>,
    +ign: List<&2, String>, +secs: U32, +wrel: String, +wtext: String) -> IO(SstR & SstR):
  +only = sst.only(sst.t(cn))
  do IO<SstR & SstR>:
    a : U32 <- sst.run(cn, "cmd", ne, na, secs)
    sst.wait(cn, wrel, wtext, 120n)
    b : U32 <- Bool.pick(IO(U32), only, IO.pure(U32, 0), sst.run(co, "cmd", oe, oa, secs))
    Bool.pick(IO(Unit), only, IO.pure(Unit, Unit{}), sst.wait(co, wrel, wtext, 120n))
    sst.cleanup(cn)
    sst.cleanup(co)
    +rn : SstR <- sst.result(cn, "cmd", ign)
    +ro : SstR <- sst.result(co, "cmd", ign)
    return (rn, ro)

def sst.both(+cn: SstC, +co: SstC, +ne: List<&2, String>, +na: List<&2, String>, +oe: List<&2, String>, +oa: List<&2, String>,
    +ign: List<&2, String>, +secs: U32) -> IO(SstR & SstR):
  sst.both.w(cn, co, ne, na, oe, oa, ign, secs, "", "")

# Fixtures ----------------------------------------------------------------------------------------

def sst.segs(n: Nat, +k: Nat) -> String:
  match n:
    case 0n:
      ""
    case 1n+m:
      "segment " ++ Nat.show(k) ++ " " ++ Nat.show(Nat.mul(k, 10n)) ++ " 10 fnv1a64-token-documents-v1:0 1 1 1 " ++ Nat.show(k) ++ " " ++ Nat.show(1n+k) ++ "\n"
        ++ sst.segs(m, 1n+k)

def sst.shards(n: Nat, +k: Nat, +dir: String, +seed: String) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+m:
      do IO<Unit>:
        sst.put(dir ++ "/shard-" ++ Nat.show(k) ++ "-fp100m.corpus", sst.blob(seed ++ "-" ++ Nat.show(k), Nat.add(3000n, Nat.mul(k, 7n))))
        sst.shards(m, 1n+k, dir, seed)

# a run directory as next-stage.sh build and raw-stage.sh build leave it: the plan (STEPS steps,
# N segments) as plan-fp100m-b16-windows.tsv, and shard-K-fp100m.corpus
def sst.fx.run(+c: SstC, +rel: String, +n: Nat, +steps: Nat) -> IO(Unit):
  do IO<Unit>:
    sst.put(sst.rp(c) ++ "/" ++ rel ++ "/plan-fp100m-b16-windows.tsv", "plan 1 " ++ Nat.show(steps) ++ " sim:size=fp100m:batch=16\n" ++ sst.segs(n, 0n))
    sst.shards(n, 0n, sst.rp(c) ++ "/" ++ rel, rel)

def sst.scripts() -> List<&2, String>:
  ["bend/gpu/fp.sh", "bend/gpu/fp-stage.sh", "bend/gpu/fp-restage.sh", "bend/gpu/next-stage.sh", "bend/gpu/raw-stage.sh", "bend/gpu/raw-driver.sh"]

# the repository for the staging scenarios: the old scripts, the sources the compiler stub reads,
# bend-push's settings, the tokenizer, the eval corpora, fp100m's plan and shards
def sst.fx.stage(+c: SstC, +boxenv: List<&2, String>) -> IO(Unit):
  +r = sst.rp(c)
  do IO<Unit>:
    sst.base(c, boxenv)
    sst.copies(c, sst.scripts())
    sst.put(r ++ "/bend/TrainDense.bend", "sim\n")
    sst.put(r ++ "/bend/tests/dense.bend", "sim\n")
    sst.put(r ++ "/bend/Box/BoxMain.bend", "sim\n")
    sst.put(r ++ "/bend/gpu/fp100m-box.env", "RUN_DIR=run/fp100m\nSIZE=fp100m\nTRAIN_BATCH=16\nPLAN=run/fp100m/plan-fp100m-b16-windows.tsv\nTOKENIZER_FILE=weights/code32k.bpe\nREMOTE_DIR=formalTransformer\n")
    sst.put(r ++ "/weights/code32k.bpe", sst.blob("tokenizer", 2000n))
    sst.put(r ++ "/run/eval/transcript-fp.corpus", sst.blob("transcript-fp", 1500n))
    sst.put(r ++ "/run/eval/transcript-next.corpus", sst.blob("transcript-next", 1600n))
    sst.put(r ++ "/run/eval/v2-heldout.corpus", sst.blob("v2-heldout", 1700n))
    sst.put(r ++ "/run/eval/v2-vault.corpus", sst.blob("v2-vault", 1800n))
    sst.fx.run(c, "run/fp100m", 3n, 30n)

# lines that are not events: `ls -la`'s, rsync's progress
def sst.noise() -> List<&2, String>:
  ["-rw-r--r--", "-rwxr-xr-x", "drwx", "total ", "xfr#", "kB/s", "MB/s"]

def sst.self.of(+c: SstC) -> String:
  sst.self(sst.t(c))

def sst.has(+xs: List<&2, String>, +x: String) -> Bool:
  Sc.scn.has(xs, x)

# Staging ----------------------------------------------------------------------------------------

# What a scenario expects of a side (new, or old), beyond old = new: its status, a line (with
# a piece) in the box's files, its output, the repository's files, there or not; or a verdict
# found before.
type SstX is Data:
  SxRc{nw: Bool, rc: String}
  SxBox{nw: Bool, pat: String, there: Bool}
  SxOut{nw: Bool, pat: String, there: Bool}
  SxLoc{nw: Bool, pat: String, there: Bool}
  SxOk{what: String, ok: Bool}

def sst.x.side(+nw: Bool) -> String:
  Bool.pick(String, nw, "new", "old")

def sst.x.has(+nw: Bool, +what: String, +there: Bool, +p: String, +xs: List<&2, String>) -> Sc.ScnRes:
  Sc.ScnRes{sst.x.side(nw) ++ ": " ++ what ++ Bool.pick(String, there, " has `", " has no `") ++ p ++ "`", Sc.scn.same(sst.any(xs, p), there), ""}

def sst.x.one(x: SstX, +n: SstR, +o: SstR) -> Sc.ScnRes:
  match x:
    case SxRc{+nw, +rc}:
      +got = sst.rc(Bool.pick(SstR, nw, n, o))
      Sc.ScnRes{sst.x.side(nw) ++ ": " ++ rc, String.eq(got, rc), "it is " ++ got}
    case SxBox{+nw, +p, +there}:
      sst.x.has(nw, "the box", there, p, sst.boxof(Bool.pick(SstR, nw, n, o)))
    case SxOut{+nw, +p, +there}:
      sst.x.has(nw, "the output", there, p, sst.outof(Bool.pick(SstR, nw, n, o)))
    case SxLoc{+nw, +p, +there}:
      sst.x.has(nw, "the repository", there, p, sst.locof(Bool.pick(SstR, nw, n, o)))
    case SxOk{+w, +ok}:
      Sc.ScnRes{w, ok, ""}

def sst.xs(xs: List<&2, SstX>, +n: SstR, +o: SstR) -> List<&2, Sc.ScnRes>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      sst.x.one(x, n, o) <> sst.xs(t, n, o)

# an expectation of the new side (SxOk's are the new run's)
def sst.x.new(x: SstX) -> Bool:
  match x:
    case SxRc{nw, rc}:
      nw
    case SxBox{nw, p, h}:
      nw
    case SxOut{nw, p, h}:
      nw
    case SxLoc{nw, p, h}:
      nw
    case SxOk{w, ok}:
      True{}

def sst.xs.new(xs: List<&2, SstX>) -> List<&2, SstX>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = sst.xs.new(t)
      Bool.pick(List<&2, SstX>, sst.x.new(x), x <> rest, rest)

def sst.fin.all(+id: String, +ds: List<&2, SstDf>, xs: List<&2, SstX>, r: SstR & SstR) -> List<&2, Sc.ScnRes>:
  match r:
    case (+n, +o):
      List.append(&2, Sc.ScnRes, sst.compare(id, n, o, ds), Sc.scn.tagged(id, sst.xs(xs, n, o)))

def sst.fin.new(+id: String, xs: List<&2, SstX>, r: SstR & SstR) -> List<&2, Sc.ScnRes>:
  match r:
    case (+n, +o):
      Sc.scn.tagged(id ++ " (new only)", sst.xs(sst.xs.new(xs), n, n))

# old against new, then the expectations, each tagged with the scenario (SIM_NEW_ONLY: the new
# side's expectations alone)
def sst.fin.by(only: Bool, +id: String, +ds: List<&2, SstDf>, +xs: List<&2, SstX>, r: SstR & SstR) -> List<&2, Sc.ScnRes>:
  match only:
    case True{}:
      sst.fin.new(id, xs, r)
    case False{}:
      sst.fin.all(id, ds, xs, r)

def sst.fin(+c: SstC, +id: String, +ds: List<&2, SstDf>, +xs: List<&2, SstX>, r: SstR & SstR) -> List<&2, Sc.ScnRes>:
  sst.fin.by(sst.only(sst.t(c)), id, ds, xs, r)

def sst.ds.box() -> List<&2, SstDf>:
  [sst.dnew("box", "formalTransformer/box.c  ", "deliberate: the plan's Phase 1b, `stage box` emits bend-box as C (box.c) for the box"),
   sst.dnew("box", "formalTransformer/bend-box  ", "deliberate: bend-box, built there with the box's newest clang (clang-19 down to 14), replaces fp.sh"),
   sst.dnew("lines", "bend-box built on the box with clang-19", "deliberate: bend-box built on the box (Phase 1b)")]

# (a) bend-ops stage box against fp-stage.sh
def sst.s.box(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"box" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  +ds = List.append(&2, SstDf, sst.ds.box(),
    [sst.dold("lines", "== scp", "form: the step's header (the copies are rsync with a partial directory and retries, not scp)"),
     sst.dnew("lines", "== to the box (formalTransformer)", "form: the same step's header"),
     sst.dold("lines", "./fp.sh gate && ./fp.sh time && ./fp.sh run", "deliberate: the next steps name bend-box, the driver that replaces fp.sh (Phase 1b)"),
     sst.dnew("lines", "./bend-box gate && ./bend-box time && ./bend-box run", "deliberate: the same")])
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.stage(cn, Nil{})
    sst.fx.stage(co, Nil{})
    r : SstR & SstR <- sst.both(cn, co, Nil{}, [sst.self(t), "stage", "box", h, "2222"], Nil{}, ["bash", "bend/gpu/fp-stage.sh", h, "2222"], sst.noise(), 900)
    return sst.fin(cn, id, ds, [SxRc{True{}, "exit 0"}, SxBox{True{}, "formalTransformer/run/fp100m/shard-2-fp100m.corpus  ", True{}},
      SxBox{True{}, "formalTransformer/run/fp100m/plan-fp100m-b16-windows.tsv  ", True{}}, SxBox{True{}, "formalTransformer/bend-box  ", True{}}], r)

def sst.fx.push(+c: SstC, +boxenv: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    sst.fx.stage(c, boxenv)
    sst.fx.run(c, "run/s9", 3n, 30n)
    sst.put(sst.rp(c) ++ "/run/eval/transcript-s9.corpus", sst.blob("transcript-s9", 1400n))

def sst.push.new(+c: SstC, +h: String) -> List<&2, String>:
  [sst.self.of(c), "stage", "push", "s9", "run/s9", h, "2222"]

def sst.push.old(+h: String) -> List<&2, String>:
  ["bash", "bend/gpu/next-stage.sh", "push", h, "2222"]

# (b) bend-ops stage push against next-stage.sh push: the shards, the sha256 gate, the plan last, STAGED
def sst.s.push(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"push" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.push(cn, Nil{})
    sst.fx.push(co, Nil{})
    r : SstR & SstR <- sst.both(cn, co, Nil{}, sst.push.new(cn, h), ["NAME=s9", "RUN=run/s9"], sst.push.old(h), sst.noise(), 600)
    return sst.fin(cn, id, Nil{}, [SxRc{True{}, "exit 0"}, SxBox{True{}, "formalTransformer/run/s9/STAGED  ", True{}},
      SxBox{True{}, "formalTransformer/run/s9/plan-s9-b16-windows.tsv  ", True{}}, SxBox{True{}, "formalTransformer/run/s9/shard-2-s9.corpus  ", True{}},
      SxBox{True{}, "formalTransformer/run/eval/transcript-s9.corpus  ", True{}}, SxOut{True{}, "STAGED: every shard matches", True{}}], r)

# (b) the link drops in the middle of the push: the copy of shard 1 (rsync's third call) fails
def sst.s.push.drop(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"push-drop" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  +fix = {"fix: a copy the link drops is tried again (RSYNC_TRIES, a partial directory), where next-stage.sh push stopped at the first failed rsync (set -e) and left the stage unstaged" : String}
  +ds = sst.dl([sst.dnew("status", "exit 0", fix), sst.dold("status", "exit 255", fix), sst.dnew("box", "formalTransformer/run/s9/", fix),
    sst.dnew("lines", " landed", fix), sst.dnew("lines", "STAGED: every shard matches", fix), sst.dold("lines", ".rsync-fail", fix), sst.dold("lines", "rsync error", fix)])
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.push(cn, Nil{})
    sst.fx.push(co, Nil{})
    S.write(sst.box(cn) ++ "/.rsync-fail", S.b("3\n"))
    S.write(sst.box(co) ++ "/.rsync-fail", S.b("3\n"))
    r : SstR & SstR <- sst.both(cn, co, Nil{}, sst.push.new(cn, h), ["NAME=s9", "RUN=run/s9"], sst.push.old(h), sst.noise(), 600)
    return sst.fin(cn, id, ds, [SxRc{True{}, "exit 0"}, SxBox{True{}, "formalTransformer/run/s9/STAGED  ", True{}},
      SxBox{True{}, "formalTransformer/run/s9/shard-2-s9.corpus  ", True{}}, SxBox{False{}, "formalTransformer/run/s9/STAGED  ", False{}}], r)

# a shard on the box that is not the local one but looks it (same size and mtime: rsync -a's
# quick check passes it over), so only the sha256 gate can see it
def sst.fx.corrupt(+c: SstC) -> IO(Unit):
  +local = sst.rp(c) ++ "/run/s9/shard-1-fp100m.corpus"
  +there = sst.ft(c) ++ "/run/s9/shard-1-s9.corpus"
  do IO<Unit>:
    n : Nat <- S.size(local)
    sst.put(there, sst.blob("corrupted", n))
    o : Lc.LclOut <- sst.run.cmd(30, "touch", ["-r", local, there])
    return Unit{}

# (b) a corrupted shard on the box: shard sums differ, not staged, exit 1
def sst.s.push.bad(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"push-corrupt" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  +ds = sst.dl([sst.dnew("lines", "stage push: s9 not staged", "form: the refusal also on stderr, as the tool's exit message")])
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.push(cn, Nil{})
    sst.fx.push(co, Nil{})
    sst.fx.corrupt(cn)
    sst.fx.corrupt(co)
    r : SstR & SstR <- sst.both(cn, co, Nil{}, sst.push.new(cn, h), ["NAME=s9", "RUN=run/s9"], sst.push.old(h), sst.noise(), 600)
    return sst.fin(cn, id, ds, [SxRc{True{}, "exit 1"}, SxRc{False{}, "exit 1"}, SxOut{True{}, "shard sums differ; not staged", True{}},
      SxBox{True{}, "run/s9/STAGED  ", False{}}, SxBox{True{}, "run/s9/plan-s9-b16-windows.tsv  ", False{}}], r)

# (c) bend-ops stage restage against fp-restage.sh: a stage NAME and a raw slice
def sst.s.restage(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"restage" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  +ck = {"ckpt/s1-step30.checkpoint" : String}
  +ds = List.append(&2, SstDf, sst.ds.box(),
    [sst.dold("lines", "C, fp.sh, tokenizer, eval corpora landed", "deliberate: the same step, now with bend-box"),
     sst.dnew("lines", "C, fp.sh, bend-box, tokenizer, eval corpora landed", "deliberate: the same step, now with bend-box"),
     sst.dnew("lines", "no run/eval/transcript-raw3.corpus here; no eval corpus sent", "form: a raw slice's eval corpus was transcript-next.corpus, which the restage has already sent")])
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.push(cn, Nil{})
    sst.fx.push(co, Nil{})
    sst.fx.run(cn, "run/raw3", 2n, 20n)
    sst.fx.run(co, "run/raw3", 2n, 20n)
    sst.put(sst.rp(cn) ++ "/" ++ ck, sst.blob("checkpoint", 5000n))
    sst.put(sst.rp(co) ++ "/" ++ ck, sst.blob("checkpoint", 5000n))
    r : SstR & SstR <- sst.both(cn, co, Nil{}, [sst.self(t), "stage", "restage", h, "2222", ck, "s9", "raw3"], Nil{},
      ["bash", "bend/gpu/fp-restage.sh", h, "2222", ck, "s9", "raw3"], sst.noise(), 900)
    return sst.fin(cn, id, ds, [SxRc{True{}, "exit 0"}, SxBox{True{}, "formalTransformer/out/s1-step30.checkpoint  ", True{}},
      SxBox{True{}, "run/s9/STAGED  ", True{}}, SxBox{True{}, "run/raw3/STAGED  ", True{}}, SxOut{True{}, "restaged", True{}}], r)

# (d) bend-ops stage raw push against raw-stage.sh push
def sst.s.rawpush(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"raw-push" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.stage(cn, Nil{})
    sst.fx.stage(co, Nil{})
    sst.fx.run(cn, "run/raw3", 2n, 20n)
    sst.fx.run(co, "run/raw3", 2n, 20n)
    r : SstR & SstR <- sst.both(cn, co, Nil{}, [sst.self(t), "stage", "raw", "push", "3", h, "2222"], Nil{}, ["bash", "bend/gpu/raw-stage.sh", "push", "3", h, "2222"],
      sst.noise(), 600)
    return sst.fin(cn, id, Nil{}, [SxRc{True{}, "exit 0"}, SxBox{True{}, "formalTransformer/run/raw3/STAGED  ", True{}},
      SxBox{True{}, "formalTransformer/run/eval/transcript-next.corpus  ", True{}}], r)

# The feed --------------------------------------------------------------------------------------

# raw1 and raw2 built (100 steps each), slice 3 not (no mix: its build fails); STAGES holds the
# running stage; the box's newest trainer log says step 5/100; vastai's credit is 10, then 0.5
# twice (slice 2 waits), then 10; rsync's 7th call (slice 2's first shard) fails; old raw-driver
# finds vastai under $HOME
def sst.fx.feed(+c: SstC) -> IO(Unit):
  do IO<Unit>:
    sst.fx.stage(c, Nil{})
    sst.fx.run(c, "run/raw1", 3n, 100n)
    sst.fx.run(c, "run/raw2", 3n, 100n)
    sst.put(sst.rp(c) ++ "/stages", "s1 traind 10\n")
    sst.put(sst.ft(c) ++ "/s1.log", "[2026-10-15 00:00:00 UTC-6] step=4/100 progress=4% lr=0.0003\n[2026-10-15 00:00:01 UTC-6] step=5/100 progress=5% lr=0.0003\n")
    sst.put(sst.ft(c) ++ "/eval.log", "[2026-10-15 00:00:00 UTC-6] step=9/9 loss: 1.0\n")
    S.write(sst.d(c) ++ "/vast/credits", S.b("10.0\n0.5\n0.5\n10.0\n"))
    S.write(sst.box(c) ++ "/.rsync-fail", S.b("7\n"))
    S.mkdir(sst.d(c) ++ "/home/.local/share/vastai-venv/bin")
    Sc.scn.links(sst.sim(sst.t(c)), sst.d(c) ++ "/home/.local/share/vastai-venv/bin", ["vastai"])

# (e) bend-ops feed against raw-driver.sh: the credit guard (enough, then not: it waits), a push
# that fails once and is tried again, STAGES appended, a slice that does not build (stop, exit 0)
def sst.s.feed(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"feed" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  +ds = sst.dl([sst.dnew("local", "run/raw-build3.log  ", "form: the failed build's log holds each tool's own words"),
    sst.dold("local", "run/raw-build3.log  ", "form: the same log"),
    sst.dnew("local", "run/raw-push2.log  ", "form: the push log of the try that failed holds each tool's own words"),
    sst.dold("local", "run/raw-push2.log  ", "form: the same log")])
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.feed(cn)
    sst.fx.feed(co)
    r : SstR & SstR <- sst.both(cn, co, ["CREDIT_GUARD=1", "FEED_WAIT=1", "FEED_PUSH_WAIT=1", "MIX_POLL=1", "RSYNC_TRIES=1"],
      [sst.self(t), "feed", h, "2222", "stages", "1", "3"], ["CREDIT_GUARD=1"], ["bash", "bend/gpu/raw-driver.sh", h, "2222", "stages", "1", "3"], sst.noise(), 900)
    st : List<&2, U32> <- S.read(sst.rp(cn) ++ "/stages")
    return sst.fin(cn, id, ds, [SxRc{True{}, "exit 0"},
      SxOk{"new: STAGES gained raw1 and raw2", S.eq(st, S.b("s1 traind 10\nraw1 traind-next 0 run/raw1/plan-raw1-b16-windows.tsv run/raw1 raw1\nraw2 traind-next 0 run/raw2/plan-raw2-b16-windows.tsv run/raw2 raw2\n"))},
      SxOut{True{}, "raw-driver: slice 2 (100 steps) waits: the credit does not cover it", True{}},
      SxOut{True{}, "raw-driver: slice 2 push try 1 failed; again in a minute", True{}},
      SxOut{True{}, "raw-driver: slice 3 did not build (the mix may be used up); stopping", True{}},
      SxBox{True{}, "run/raw1/STAGED  ", True{}}, SxBox{True{}, "run/raw2/STAGED  ", True{}}], r)

# The act round (f) -----------------------------------------------------------------------------
#
# act-box.sh names the workspace by its absolute path (it cd's to
# /home/hhefesto/src/ana, here and on the box), and bend-ops act by ACT_WS (the same
# path by default) on both sides.  In the sandbox the workspace here is D/repo (ACT_WS for the new
# side; the old scripts' copies cd to their own repository, `cd "$(dirname "$0")/../.."`, in
# place of that path, the one line changed), and the box's path map (box/.sim-map) puts D/repo,
# D/home (HOME, the box's too), /usr/local/bin (the box's nix) and /etc/nix under box/ on the
# box: ws/, home/, usr/local/bin/, etc/nix/.  A copy still naming the real repository stops the
# scenario before it runs.  The tools are a store of their own, D/store, whose gcroots in the
# workspace point at it: nix (the static nix: bend-sim, copied to the box as the box's nix), the
# deploy (bend-sim as `deploy`: agent-act runs the real bend-corpus-v2 agent-act, agent-eval is
# recorded with its environment and leaves the report, the episodes log and agent.nul from
# fixtures), bend-episode (accept and fixed recorded; why and langs the real one).  `nix copy`,
# `nix path-info`, elan and lake are recorded and succeed.  The records, prompts, source trees,
# checker caches and Mathlib are a few small files each, in the shapes setup selects.

def sst.real.repo() -> String:
  "/home/hhefesto/src/ana"

def sst.cd.own() -> String:
  "cd \"$(dirname \"$0\")/../..\""

# a copy of an old act script with its `cd` to the real repository made a `cd` to its own
def sst.copy.act(+c: SstC, +rel: String) -> IO(Unit):
  sst.copy.sub(sst.repo(sst.t(c)) ++ "/" ++ rel, sst.rp(c) ++ "/" ++ rel, "cd " ++ sst.real.repo(), sst.cd.own())

def sst.ln(+target: String, +path: String) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(S.parent(path))
    o : Lc.LclOut <- sst.run.cmd(30, "ln", ["-sfn", target, path])
    return Unit{}

def sst.lns(+d: String, ps: List<&2, String>) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> t:
      do IO<Unit>:
        sst.ln(d ++ "/store/" ++ S.base(p), d ++ "/repo/" ++ p)
        sst.lns(d, t)

def sst.nul(xs: List<&2, String>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      List.concat(&2, U32, [S.b(x), [0], sst.nul(t)])

def sst.putn(+path: String, +xs: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(S.parent(path))
    S.write(path, sst.nul(xs))

# the store and the workspace's gcroots (each named after its store entry)
def sst.fx.store(+c: SstC) -> IO(Unit):
  +d = sst.d(c)
  +sim = sst.sim(sst.t(c))
  do IO<Unit>:
    sst.ln(sim, d ++ "/store/gcroot-nix-static/bin/nix")
    sst.ln(sim, d ++ "/store/gcroot-deploy-agent/bin/deploy")
    sst.ln(sim, d ++ "/store/gcroot-bend-episode/bin/bend-episode")
    sst.put(d ++ "/store/gcroot-bend-generate-agent/bin/bend-generate", "sim\n")
    sst.put(d ++ "/store/gcroot-ana/bin/ana", "sim\n")
    sst.put(d ++ "/store/gcroot-bend-plan-segment/bin/bend-plan-segment", "sim\n")
    sst.put(d ++ "/store/ghc-harness/bin/ghc", "sim\n")
    sst.lns(d, ["run/v3/gcroot-nix-static", "run/v2/gcroot-deploy-agent", "run/gcroot-bend-generate-agent", "run/agent/gcroot-bend-episode", "run/gcroot-ana",
      "run/v2/gcroot-bend-plan-segment", "run/check-cache/ghc-harness"])

# the box's side of the act world: its path map, its directories, the stubs' settings
def sst.act.boxenv(+c: SstC, +eplog: String, +report: String) -> List<&2, String>:
  +t = sst.t(c)
  ["SIM_CV2=" ++ sst.cv2(t), "SIM_EPISODE=" ++ sst.epb(t), "SIM_EPLOG=" ++ sst.repo(t) ++ "/" ++ eplog, "SIM_REPORT=" ++ sst.repo(t) ++ "/" ++ report,
   "SIM_AGENT=" ++ sst.d(c) ++ "/fx/agent.nul", "SIM_ACT_MS=1500"]

def sst.fx.actbase(+c: SstC, +eplog: String, +report: String) -> IO(Unit):
  +d = sst.d(c)
  +b = sst.box(c)
  do IO<Unit>:
    sst.base(c, sst.act.boxenv(c, eplog, report))
    Sc.scn.links(sst.sim(sst.t(c)), b ++ "/bin", ["nix"])
    S.mkdir(b ++ "/ws")
    S.mkdir(b ++ "/home")
    S.mkdir(b ++ "/usr/local/bin")
    S.write(b ++ "/.sim-map", S.b(sst.lines([d ++ "/repo " ++ b ++ "/ws", d ++ "/home " ++ b ++ "/home", "/usr/local/bin " ++ b ++ "/usr/local/bin",
      "/etc/nix " ++ b ++ "/etc/nix"])))
    sst.putn(d ++ "/fx/agent.nul", ["repo:alpha/src/A.hs#f@1/direct", "episode a", "own:o1/x.agda#h@3/direct", "episode b", "repo:beta/z.nix#n@5/direct", "episode c"])

# the workspace (D/repo): the old scripts (git-tracked, with a README), the tools' gcroots, the act
# set and the evaluation's prompts, the train and held-out records, S2's filler, the held-out
# transcripts, the source trees and caches setup selects (and one it does not), Mathlib, the checkpoint
def sst.fx.act(+c: SstC, +eplog: String, +report: String) -> IO(Unit):
  +r = sst.rp(c)
  do IO<Unit>:
    sst.fx.actbase(c, eplog, report)
    sst.copy.act(c, "bend/gpu/act-box.sh")
    sst.copy.act(c, "tools/corpus-v2/agent-act.sh")
    sst.put(r ++ "/README.md", "the act sandbox's workspace\n")
    g1 : Lc.LclOut <- sst.run.cmd(60, "git", ["-C", r, "init", "-q"])
    g2 : Lc.LclOut <- sst.run.cmd(60, "git", ["-C", r, "add", "README.md", "bend", "tools"])
    sst.fx.store(c)
    sst.putn(r ++ "/run/v2/act/prompts.nul", ["repo:alpha/src/A.hs#f@1/direct", "prompt 1", "hackage:pkgx/src/B.hs#g@2/repair", "prompt 2",
      "own:o1/x.agda#h@3/direct", "prompt 3", "curated:c1/y.lean#k@4/direct", "prompt 4"])
    sst.putn(r ++ "/run/v2/evalset/prompts.nul", ["repo:beta/z.nix#n@5/direct", "prompt 5"])
    sst.putn(r ++ "/run/v2/results/haskell.train.nul", ["repo:alpha/src/A.hs#f@1", "record 1", "repo:other/Q.hs#q@9", "record q", "hackage:pkgx/src/B.hs#g@2", "record 2"])
    sst.putn(r ++ "/run/v2/results/agda.train.nul", ["own:o1/x.agda#h@3", "record 3"])
    sst.putn(r ++ "/run/v2/results/lean.train.nul", ["curated:c1/y.lean#k@4", "record 4"])
    sst.putn(r ++ "/run/v2/results/nix.train.nul", ["repo:beta/z.nix#n@5", "record 5"])
    sst.putn(r ++ "/run/v2/results/bend.train.nul", ["repo:zzz/m.bend#b@6", "record 6"])
    sst.putn(r ++ "/run/v2/results/haskell.holdout.nul", ["repo:gamma/H.hs#x@7", "held-out record"])
    sst.putn(r ++ "/run/v3/s2fill/fill.nul", ["filler", "text"])
    sst.putn(r ++ "/run/v2/transcripts/haskell/transcripts.holdout.nul", ["t1", "transcript"])
    sst.putn(r ++ "/run/v2/transcripts/haskell/results.holdout.nul", ["r1", "result"])
    sst.putn(r ++ "/run/v2/transcripts/agda/transcripts.holdout.nul", ["t2", "transcript"])
    sst.put(r ++ "/run/code-sources/repos/alpha/src/A.hs", "f = 1\n")
    sst.put(r ++ "/run/code-sources/repos/beta/z.nix", "{ }\n")
    sst.put(r ++ "/run/code-sources/repos/gamma/H.hs", "x = 7\n")
    sst.put(r ++ "/run/code-sources/repos/agdalib/agdalib.agda-lib", "name: agdalib\n")
    sst.put(r ++ "/run/code-sources/repos/unused/u.hs", "u = 0\n")
    sst.put(r ++ "/run/check-cache/agda/libraries", r ++ "/run/code-sources/repos/agdalib/agdalib.agda-lib\n")
    sst.put(r ++ "/run/code-sources/own/o1/x.agda", "h = 3\n")
    sst.put(r ++ "/run/code-sources-next/c1/y.lean", "def k := 4\n")
    sst.ln("../../code-sources-next/c1", r ++ "/run/code-sources/curated/c1")
    sst.put(r ++ "/run/check-cache/hs/hi/A.hi", "hi\n")
    sst.put(r ++ "/run/check-cache/hs/info/A.info", "info\n")
    sst.put(r ++ "/run/check-cache/hs/cabal-dirs/a/x", "cabal\n")
    sst.put(r ++ "/run/check-cache/hs/src/pkgx-1.0/B.hs", "g = 2\n")
    sst.put(r ++ "/run/code-sources/tarballs/pkgx-1.0.tar.gz", "tarball\n")
    sst.put(r ++ "/run/harness/mathlib4/lean-toolchain", "leanprover/lean4:v4.9.0\n")
    sst.put(r ++ "/run/harness/mathlib4/Mathlib.lean", "import Mathlib.Basic\n")
    sst.put(r ++ "/run/harness/mathlib4/.lake/build/cache.olean", "built\n")
    sst.put(r ++ "/run/v2/run2/out/v2-step40000.checkpoint", sst.blob("v2-step40000", 6000n))

# what setup leaves on the box, put there directly (check, start and pull start from it)
def sst.fx.actbox(+c: SstC) -> IO(Unit):
  +d = sst.d(c)
  +w = sst.box(c) ++ "/ws"
  do IO<Unit>:
    sst.ln(d ++ "/store/gcroot-deploy-agent", w ++ "/run/v2/gcroot-deploy-agent")
    sst.ln(d ++ "/store/gcroot-bend-episode", w ++ "/run/agent/gcroot-bend-episode")
    xs : List<&2, U32> <- S.read(sst.rp(c) ++ "/tools/corpus-v2/agent-act.sh")
    S.mkdir(w ++ "/tools/corpus-v2")
    S.write(w ++ "/tools/corpus-v2/agent-act.sh", xs)
    o : Lc.LclOut <- sst.run.cmd(30, "chmod", ["+x", w ++ "/tools/corpus-v2/agent-act.sh"])
    ck : List<&2, U32> <- S.read(sst.rp(c) ++ "/run/v2/run2/out/v2-step40000.checkpoint")
    S.mkdir(w ++ "/run/v2/run2/out")
    S.write(w ++ "/run/v2/run2/out/v2-step40000.checkpoint", ck)

# the old copies must not name the real repository (else the scenario would act on it)
def sst.guard.text(+xs: List<&2, U32>) -> Bool:
  Bool.not(S.infix(xs, S.b(sst.real.repo())))

def sst.guard(+c: SstC, ps: List<&2, String>) -> IO(Bool):
  match ps:
    case Nil{}:
      IO.pure(Bool, True{})
    case +p <> t:
      do IO<Bool>:
        xs : List<&2, U32> <- S.read(sst.rp(c) ++ "/" ++ p)
        rest : Bool <- sst.guard(c, t)
        return Bool.and(sst.guard.text(xs), rest)

def sst.act.ck() -> String:
  "run/v2/run2/out/v2-step40000.checkpoint"

def sst.act.env(+c: SstC) -> List<&2, String>:
  ["ACT_WS=" ++ sst.rp(c)]

def sst.act.new(+c: SstC, +mode: String, +h: String, +rest: List<&2, String>) -> List<&2, String>:
  List.append(&2, String, [sst.self.of(c), "act", mode, h, "2222"], rest)

def sst.act.old(+mode: String, +h: String, +rest: List<&2, String>) -> List<&2, String>:
  List.append(&2, String, ["bash", "bend/gpu/act-box.sh", mode, h, "2222"], rest)

def sst.refused(+id: String) -> List<&2, Sc.ScnRes>:
  [Sc.ScnRes{id ++ ": an old script's copy still names " ++ sst.real.repo() ++ "; not run", False{}, ""}]

# a scenario's two runs once its copies are known not to name the real repository
def sst.act.go(ok: Bool, +id: String, +cn: SstC, +co: SstC, +ne: List<&2, String>, +na: List<&2, String>, +oe: List<&2, String>, +oa: List<&2, String>,
    +wrel: String, +wtext: String, +ds: List<&2, SstDf>, +xs: List<&2, SstX>) -> IO(List<&2, Sc.ScnRes>):
  match ok:
    case False{}:
      IO.pure(List<&2, Sc.ScnRes>, sst.refused(id))
    case True{}:
      do IO<List<&2, Sc.ScnRes>>:
        r : SstR & SstR <- sst.both.w(cn, co, ne, na, oe, oa, sst.noise(), 1800, wrel, wtext)
        return sst.fin(cn, id, ds, xs, r)

def sst.act.run(+id: String, +cn: SstC, +co: SstC, +ne: List<&2, String>, +na: List<&2, String>, +oe: List<&2, String>, +oa: List<&2, String>,
    +wrel: String, +wtext: String, +ds: List<&2, SstDf>, +xs: List<&2, SstX>) -> IO(List<&2, Sc.ScnRes>):
  do IO<List<&2, Sc.ScnRes>>:
    a : Bool <- sst.guard(cn, ["bend/gpu/act-box.sh", "tools/corpus-v2/agent-act.sh"])
    b : Bool <- sst.guard(co, ["bend/gpu/act-box.sh", "tools/corpus-v2/agent-act.sh", "../act-restart.sh"])
    sst.act.go(Bool.and(a, b), id, cn, co, ne, na, oe, oa, wrel, wtext, ds, xs)

def sst.ds.act() -> List<&2, SstDf>:
  Nil{}

# start's: the round's line names PROCS and THREADS; the box's `echo started` is gone (the start
# is one detached command, `nohup setsid -f`, with no shell list to report from)
def sst.ds.start() -> List<&2, SstDf>:
  [sst.dnew("lines", " processes x 2 threads", "form: the round's line also says PROCS and THREADS"),
   sst.dold("lines", "on the box (log run/v3/act/", "form: the same line without them"),
   sst.dold("lines", "started", "form: the box's `& echo started`; the new start is one detached command (nohup setsid -f), no shell list")]

# ensure against run 3's act-restart.sh: setup and ckpt run as this program's own subcommands,
# their output passed on (act-restart.sh sent setup's to DEST/actsetup2.log); the act-box lines
# also go to ACT_LOG (chain.log); the resumed round is any local DIR, its log DIR.log-resumed and
# its agent.nul checked by sha256 (act-restart's: r1, r1.log-55552041, a NUL count; Phase 3);
# PROCS from the box's cores (act-restart's 21 was that box's (46 - 4) / 2)
def sst.ds.ensure() -> List<&2, SstDf>:
  +f = {"form: setup's own output, passed on to stdout as each subcommand's is; act-restart.sh wrote it to DEST/actsetup2.log" : String}
  +p = {"deliberate: PROCS from the box's cores and quota (here 16: 6); act-restart.sh had 21 written in, its box's (46 - 4) / 2" : String}
  +r = {"deliberate (Phase 3, Act.bend): the resumed round is any local DIR; its log is DIR.log-resumed (act-restart: r1.log-55552041) and its agent.nul is checked by sha256 (act-restart: a NUL count)" : String}
  [sst.dnew("lines", "nix (Nix) 2.24.0 (bend-sim)", f), sst.dnew("lines", "act-box: nix copy: ", f), sst.dnew("lines", "bend-sim deploy: corpus-v2 STEP ARGS", f),
   sst.dnew("lines", "act-box: tracked files", f), sst.dnew("lines", "act-box: act set, records", f), sst.dnew("lines", "act-box: source trees", f),
   sst.dnew("lines", " trees, ", f), sst.dnew("lines", "act-box: Mathlib: ", f), sst.dnew("lines", "bend-sim elan: ", f), sst.dnew("lines", "bend-sim lake: ", f),
   sst.dnew("lines", "act-box: setup done in ", f),
   sst.dnew("lines", "act-box: act setup done", "form: the same line under the tool's tag"), sst.dold("lines", "act-restart: act setup done", "form: the same line"),
   sst.dnew("lines", "agent.nul's sha256 matches", r), sst.dnew("box", "ws/run/v3/act/r1.log-resumed", r), sst.dold("box", "ws/run/v3/act/r1.log-55552041", r),
   sst.dnew("lines", "act-box: the box: ", p), sst.dnew("box calls", "PROCS=6 ", p), sst.dold("box calls", "PROCS=21 ", p),
   sst.dnew("box", "ws/run/v3/act/r1.log  log: agent-act: start: ", p), sst.dold("box", "ws/run/v3/act/r1.log  log: agent-act: start: ", p),
   sst.dnew("lines", " processes x 2 threads", "form: start's line (PROCS, THREADS)"), sst.dold("lines", "started", "form: the box's `& echo started`"),
   sst.dnew("lines", "act-box: act round run/v3/act/r1: ", "form: the closing status line: bend-corpus-v2 processes (here the real agent-act and the stub's agent-eval) and the log's last line"),
   sst.dold("lines", "act-restart: act round r1 on vast 55567872: ", "form: the same status line (its pgrep counted the stub's agent-eval only: agent-act.sh is bash)"),
   sst.dnew("calls", "-o StrictHostKeyChecking=no]", "deliberate: Remote's ssh options reach nix copy's NIX_SSHOPTS (as in act-setup)"),
   sst.dold("calls", "-o ServerAliveInterval=30]", "deliberate: the same nix copy, the script's NIX_SSHOPTS"),
   sst.dnew("local", "run/v3/run3/chain.log  log: ", "form: ACT_LOG (chain.log) gets every act-box line; act-restart.sh's got its own two"),
   sst.dold("local", "run/v3/run3/chain.log  log: ", "form: the same log"), sst.dold("local", "run/v3/run3/actsetup2.log  log: ", f)]

# pull's `ls -la DIR DIR/accepted` names the directories by the workspace's path now
def sst.ds.pull() -> List<&2, SstDf>:
  [sst.dnew("lines", "<D>/repo/run/v3/act/r9", "form: `ls -la`'s headers name the round by its path in the workspace (ACT_WS), the script's by the relative path"),
   sst.dold("lines", "run/v3/act/r9", "form: the same headers, relative")]

# a refusal's exit message on stderr, after the same logged reason
def sst.ds.stopped() -> List<&2, SstDf>:
  [sst.dnew("lines", "act-box: stopped", "form: the tool's exit message on stderr, after the reason the log line gives as the script's did")]

# PROCS from the box's cores: the line saying what they were read from
def sst.ds.cores() -> List<&2, SstDf>:
  [sst.dnew("lines", "act-box: the box: ", "deliberate: the plan's `PROCS respects the CPU quota`; the line says the cores PROCS came from (nproc, cgroup cpu.max)")]

# setup's two differences (Phase 3 documented the second)
def sst.ds.act.setup() -> List<&2, SstDf>:
  [sst.dnew("calls", "-o StrictHostKeyChecking=no]", "deliberate: Remote's ssh options (Phase 0: StrictHostKeyChecking=no, then SSH_OPTS) reach nix copy's NIX_SSHOPTS too; the script's had none there (its own ssh used accept-new)"),
   sst.dold("calls", "-o ServerAliveInterval=30]", "deliberate: the same nix copy, the script's NIX_SSHOPTS"),
   sst.dold("lines", "bytes/sec", "form: the trees' rsync printed its stats (--info=stats1); setup's copies print none now (Act.bend, Phase 3)")]

# (f) act setup against act-box.sh setup
def sst.s.act.setup(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"act-setup" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.act(cn, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.act(co, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.act.run(id, cn, co, sst.act.env(cn), sst.act.new(cn, "setup", h, Nil{}), Nil{}, sst.act.old("setup", h, Nil{}), "", "", sst.ds.act.setup(),
      [SxRc{True{}, "exit 0"}, SxOut{True{}, "act-box: setup done in", True{}}, SxBox{True{}, "ws/run/v2/results/haskell.train.nul  ", True{}},
       SxBox{True{}, "ws/run/code-sources-next/c1/y.lean  ", True{}}, SxBox{True{}, "ws/run/code-sources/repos/unused/", False{}},
       SxBox{True{}, "ws/run/harness/mathlib4/.lake", False{}}, SxBox{True{}, "usr/local/bin/nix-daemon -> nix", True{}}, SxBox{True{}, "etc/nix/nix.conf  ", True{}}])

# (f) act ckpt against act-box.sh ckpt
def sst.s.act.ckpt(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"act-ckpt" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.act(cn, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.act(co, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.act.run(id, cn, co, sst.act.env(cn), sst.act.new(cn, "ckpt", h, [sst.act.ck()]), Nil{}, sst.act.old("ckpt", h, [sst.act.ck()]), "", "", sst.ds.act(),
      [SxRc{True{}, "exit 0"}, SxBox{True{}, "ws/run/v2/run2/out/v2-step40000.checkpoint  ", True{}},
       SxOut{True{}, "act-box: run/v2/run2/out/v2-step40000.checkpoint on the box, sha256 matches", True{}}])

# (f) act check against act-box.sh check: EPLOG's languages and REPORT decide; EXPECT the verdict line
def sst.s.act.check(+t: SstT, +base: String, +id: String, +eplog: String, +report: String, +rc: String, +verdict: String) -> IO(List<&2, Sc.ScnRes>):
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.act(cn, eplog, report)
    sst.fx.act(co, eplog, report)
    sst.fx.actbox(cn)
    sst.fx.actbox(co)
    sst.act.run(id, cn, co, sst.act.env(cn), sst.act.new(cn, "check", h, [sst.act.ck()]), Nil{}, sst.act.old("check", h, [sst.act.ck()]), "", "", List.append(&2, SstDf, sst.ds.cores(), Bool.pick(List<&2, SstDf>, String.eq(rc, "exit 1"), sst.ds.stopped(), Nil{})),
      [SxRc{True{}, rc}, SxRc{False{}, rc}, SxOut{True{}, verdict, True{}}, SxOut{False{}, verdict, True{}}])

# (f) act start against act-box.sh act: agent-act detached on the box, run here to its end
def sst.s.act.start(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"act-start" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.act(cn, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.act(co, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.actbox(cn)
    sst.fx.actbox(co)
    sst.act.run(id, cn, co, sst.act.env(cn), sst.act.new(cn, "start", h, [sst.act.ck(), "run/v3/act/r9"]), Nil{},
      sst.act.old("act", h, [sst.act.ck(), "run/v3/act/r9"]), "box/ws/run/v3/act/r9.log", "agent-act: done", List.append(&2, SstDf, sst.ds.cores(), sst.ds.start()),
      [SxRc{True{}, "exit 0"}, SxBox{True{}, "ws/run/v3/act/r9/episodes.eplog  ", True{}}, SxBox{True{}, "ws/run/v3/act/r9/accepted/", True{}}])

# (f) act pull against act-box.sh pull
def sst.fx.r9(+c: SstC) -> IO(Unit):
  +w = sst.box(c) ++ "/ws/run/v3/act"
  do IO<Unit>:
    sst.putn(w ++ "/r9/accepted/haskell-act/transcripts.train.nul", ["repo:alpha/src/A.hs#f@1", "accepted episode"])
    sst.putn(w ++ "/r9/accepted/nix-fix/transcripts.train.nul", ["repo:beta/z.nix#n@5", "fixed episode"])
    sst.putn(w ++ "/r9/agent.nul", ["repo:alpha/src/A.hs#f@1/direct", "episode a"])
    sst.put(w ++ "/r9/episodes.eplog", "EP1 4\nsim\n")
    sst.put(w ++ "/r9/report.txt", "render law 1/1\n")
    sst.put(w ++ "/r9/prompt.0", "not pulled\n")
    sst.put(w ++ "/r9.log", "[2026-10-15 00:00:00 UTC-6] agent-act: done\n")

def sst.s.act.pull(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"act-pull" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    sst.fx.act(cn, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.act(co, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.r9(cn)
    sst.fx.r9(co)
    sst.act.run(id, cn, co, sst.act.env(cn), sst.act.new(cn, "pull", h, ["run/v3/act/r9"]), Nil{}, sst.act.old("pull", h, ["run/v3/act/r9"]), "", "", sst.ds.pull(),
      [SxRc{True{}, "exit 0"}, SxLoc{True{}, "run/v3/act/r9/accepted/nix-fix/transcripts.train.nul  ", True{}}, SxLoc{True{}, "run/v3/act/r9.log  ", True{}},
       SxLoc{True{}, "run/v3/act/r9/prompt.0", False{}}])

# (f) act ensure against run 3's act-restart.sh (read only: SIM_ACT_RESTART, else
# SIM_REPO/run/v3/run3/act-restart.sh), its copy made to this sandbox: the box (NH, NP), the
# workspace, the box's HOME, and the resumed round's record count (3, act-restart's 9408)
def sst.restart.src() -> IO(String):
  do IO<String>:
    +repo : String <- S.env("SIM_REPO", ".")
    S.env("SIM_ACT_RESTART", repo ++ "/run/v3/run3/act-restart.sh")

def sst.restart.copy(+c: SstC, +src: String, +h: String) -> IO(Bool):
  do IO<Bool>:
    there : Bool <- S.exists(src)
    t : List<&2, U32> <- S.read(src)
    +a : List<&2, U32> = S.replace(S.replace(t, S.b(sst.real.repo()), S.b(sst.rp(c))), S.b("HOME=/home/hhefesto "), S.b("HOME=" ++ sst.d(c) ++ "/home "))
    +b : List<&2, U32> = S.replace(S.replace(S.replace(a, S.b("root@154.12.38.116"), S.b(h)), S.b("NP=21869"), S.b("NP=2222")), S.b("9408"), S.b("3"))
    S.write(sst.d(c) ++ "/act-restart.sh", b)
    return there

def sst.fx.rescue(+c: SstC) -> IO(Unit):
  +r = sst.rp(c) ++ "/run/v3/run3/rescue/act"
  do IO<Unit>:
    sst.putn(r ++ "/r1/agent.nul", ["repo:alpha/src/A.hs#f@1/direct", "episode a", "own:o1/x.agda#h@3/direct", "episode b", "repo:beta/z.nix#n@5/direct", "episode c"])
    sst.put(r ++ "/r1/episodes.eplog", "EP1 4\nsim\n")
    sst.put(r ++ "/r1/agent.nul.whole-before-cut", "the uncut file\n")
    sst.put(r ++ "/r1.log", "[2026-10-12 00:00:00 UTC-6] agent-act: start\n")

def sst.ensure.go(there: Bool, +id: String, +cn: SstC, +co: SstC, +h: String, +src: String) -> IO(List<&2, Sc.ScnRes>):
  match there:
    case False{}:
      IO.pure(List<&2, Sc.ScnRes>, [Sc.ScnRes{id ++ ": no act-restart.sh to compare with (" ++ src ++ "; SIM_ACT_RESTART)", False{}, ""}])
    case True{}:
      sst.act.run(id, cn, co, List.append(&2, String, sst.act.env(cn), ["ACT_LOG=run/v3/run3/chain.log", "TRIES=2", "RETRY_SLEEP=1", "ENSURE_WAIT=1"]),
        sst.act.new(cn, "ensure", h, [sst.act.ck(), "run/v3/act/r1", "run/v3/run3/rescue/act/r1"]), ["TRIES=2"], ["bash", sst.d(co) ++ "/act-restart.sh"],
        "box/ws/run/v3/act/r1.log", "agent-act: done", sst.ds.ensure(),
        [SxRc{True{}, "exit 0"}, SxBox{True{}, "ws/run/v3/act/r1/agent.nul  ", True{}}, SxBox{True{}, "ws/run/v3/act/r1/accepted/", True{}},
         SxBox{True{}, "whole-before-cut", False{}}])

def sst.s.act.ensure(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"act-ensure" : String}
  +h = sst.host(id)
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    +src : String <- sst.restart.src()
    sst.fx.act(cn, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.act(co, "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt")
    sst.fx.rescue(cn)
    sst.fx.rescue(co)
    there : Bool <- sst.restart.copy(co, src, h)
    sst.ensure.go(there, id, cn, co, h, src)

# The chain's two gaps (g) --------------------------------------------------------------------
#
# Phase 1a's scenarios (bend/Box/Scenario.bend), run as they are, the old fp-chain.sh beside:
#
# chain-start-drop: stage s2's start fails BEFORE the launch (ssh's 255 and no command run:
# .drop-before, once).  fp-chain.sh's start_stage looked for s2.log 20 s later, found none and
# started it again (5 tries); bend-ops chain asks the box (until it answers) whether the log is
# there, and starts again only on a `no`.  The right behaviour, kept: one more start, one
# trainer per stage, the chain goes on.
#
# chain-outage: the box does not answer (ssh and rsync) for 8 s while the chain follows s1, longer
# than SSH_TRIES 2 x SSH_RETRY_SLEEP 1 s and than DEAD_QUIET 6 s.  fp-chain.sh's follow logged `ssh
# failed; retrying` and polled again (its rsh had tried 10 times, 30 s apart); bend-ops chain
# does the same once Remote's tries are spent: a box that does not answer is never a stage that
# died, the poll comes again, and a save is pulled when the link is back.  The right behaviour,
# kept: no DIED, every save pulled, the box destroyed.

def sst.scn.c1() -> Sc.Scn:
  Sc.Scn{"c1", "stage s2's start fails before the launch (.drop-before, once): the box says s2.log is not there, the start is tried again; one trainer per stage",
    "s1 traind 10\ns2 traind-next 10 run/sim/S2/plan-sim.tsv run/sim/S2 sim\n", ["30", "30", ""], Nil{}, Nil{}, Nil{}, True{},
    [Sc.ScnStep{Sc.TrNow{}, Sc.AcFile{"box/.drop-before", " again "}}],
    [Sc.ExRc{"0"}, Sc.ExStarts{2n}, Sc.ExLog{"] stage s2: no log on the box after the start; trying again\n", True{}}, Sc.ExLog{"(bend-sim: .drop-before;", True{}},
     Sc.ExMark{"DESTROYED", True{}}, Sc.ExMark{"REFUSED", False{}}, Sc.ExMark{"DIED", False{}},
     Sc.ExOut{List.append(&2, String, Sc.scn.cks("s1", [10n, 20n, 30n]), Sc.scn.cks("s2", [40n, 50n, 60n]))}]}

def sst.scn.c2() -> Sc.Scn:
  Sc.Scn{"c2", "the box unreachable (ssh and rsync) for 8 s while s1 runs, longer than SSH_TRIES 2 x SSH_RETRY_SLEEP 1 s and DEAD_QUIET 6 s: no death read, every save pulled, destroyed",
    "s1 traind 10\n", ["40", "", ""], ["SIM_SLEEP_MS=300"], Nil{}, ["SSH_TRIES=2", "DEAD_QUIET=6"], True{},
    [Sc.scn.at("] train.log running: ", Sc.AcLink{True{}}), Sc.ScnStep{Sc.TrSleep{8000n}, Sc.AcLink{False{}}}],
    [Sc.ExRc{"0"}, Sc.ExLog{"] ssh failed; retrying\n", True{}}, Sc.ExMark{"DIED", False{}}, Sc.ExLog{"could not pull", False{}},
     Sc.ExMark{"DESTROYED", True{}}, Sc.ExMark{"REFUSED", False{}}, Sc.ExOut{Sc.scn.cks("s1", [10n, 20n, 30n, 40n])}]}

def sst.s.chain(+t: SstT, +base: String, +s: Sc.Scn) -> IO(List<&2, Sc.ScnRes>):
  Sc.scn.one(sst.sc(t), base, s)

# dense-identity (h) ------------------------------------------------------------------------------
#
# Phase 1b found its checkpoints equal to bend/tests/dense-identity.sha256.  Here the old script and
# bend-ops dense-identity run the same trainer (SIM_TRAINER, else SIM_REPO's flake's
# bend-train-dense, built) on the CPU (--gpu off: no GPU needed): their OUT directories, byte for
# byte, and what they print.

# the store path is nix's stdout alone: its stderr carries warnings such as
# "Git tree ... has uncommitted changes", which S.must's combined text put into
# the path (2026-10-15)
def sst.trainer.built(+o: Lc.LclOut) -> IO(String):
  Bool.pick(IO(String), Lc.lcl.ok(o),
    IO.pure(String, S.str(S.chomp(Lc.lcl.out(o))) ++ "/bin/bend-train-dense"),
    IO.die(String, 1, "sim stage: nix build bend-train-dense failed: " ++ S.str(Lc.lcl.err(o))))

def sst.trainer.got(+given: String, +repo: String) -> IO(String):
  Bool.pick(IO(String), String.is_empty(given),
    IO.bind(Lc.LclOut, String, Lc.lcl.run(7200, "nix", ["build", "--no-link", "--print-out-paths", repo ++ "#bend-train-dense"]),
      (o => sst.trainer.built(o))),
    IO.pure(String, given))

def sst.fx.ident(+c: SstC) -> IO(Unit):
  +doc = {"docs/haskell-era/RUN-2026-07-25-WIKI-FULL.md" : String}
  do IO<Unit>:
    sst.base(c, Nil{})
    sst.copy.old(c, "bend/tests/dense-identity.sh")
    xs : List<&2, U32> <- S.read(sst.repo(sst.t(c)) ++ "/" ++ doc)
    S.mkdir(S.parent(sst.rp(c) ++ "/" ++ doc))
    S.write(sst.rp(c) ++ "/" ++ doc, xs)

def sst.btc.sums(+xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = sst.btc.sums(t)
      Bool.pick(List<&2, String>, Bool.and(S.prefix(S.b(x), S.b("out/")), S.infix(S.b(x), S.b(".btc  "))), x <> rest, rest)

# dense-identity.sha256's `HASH  NAME` lines as the tree shows them: `out/NAME  HASH`
def sst.ident.want(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = sst.ident.want(t)
      Bool.pick(List<&2, String>, Nat.is_lt(66n, S.len(l)), ("out/" ++ S.str(List.drop(&2, U32, l, 66n)) ++ "  " ++ S.str(List.take(&2, U32, l, 64n))) <> rest, rest)

# each of dense-identity.sha256's checkpoints in the new run's out/
def sst.ident.xs(ls: List<&2, String>) -> List<&2, SstX>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      SxLoc{True{}, l, True{}} <> sst.ident.xs(t)

def sst.s.ident(+t: SstT, +base: String) -> IO(List<&2, Sc.ScnRes>):
  +id = {"dense-identity" : String}
  +cn = sst.cx(t, base, id, False{})
  +co = sst.cx(t, base, id, True{})
  do IO<List<&2, Sc.ScnRes>>:
    +g : String <- S.env("SIM_TRAINER", "")
    +tr : String <- sst.trainer.got(g, sst.repo(t))
    sst.fx.ident(cn)
    sst.fx.ident(co)
    r : SstR & SstR <- sst.both(cn, co, Nil{}, [sst.self(t), "dense-identity", "out", tr], Nil{}, ["bash", "bend/tests/dense-identity.sh", "out", tr], Nil{}, 3600)
    +want : List<&2, U32> <- S.read(sst.repo(t) ++ "/bend/tests/dense-identity.sha256")
    return sst.fin(cn, id, Nil{}, List.append(&2, SstX, [SxRc{True{}, "exit 0"}, SxOk{"dense-identity.sha256 names two checkpoints", Nat.is_eq(List.length(&2, String, sst.ident.want(S.split.lines(want))), 2n)}],
      sst.ident.xs(sst.ident.want(S.split.lines(want)))), r)

# The command -------------------------------------------------------------------------------------

def sst.names() -> List<&2, String>:
  ["box", "push", "push-drop", "push-corrupt", "restage", "raw-push", "feed", "act-setup", "act-ckpt", "act-check", "act-check-fail", "act-start",
   "act-pull", "act-ensure", "chain-start-drop", "chain-outage", "dense-identity"]

def sst.usage() -> String:
  "usage: bend-ops sim stage N|NAME|all DIR   (NAME: " ++ String.join(sst.names(), ", ") ++ "; N its number from 1)"

def sst.pick(+t: SstT, +base: String, +name: String) -> IO(List<&2, Sc.ScnRes>):
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "box"), sst.s.box(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "push"), sst.s.push(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "push-drop"), sst.s.push.drop(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "push-corrupt"), sst.s.push.bad(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "restage"), sst.s.restage(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "raw-push"), sst.s.rawpush(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "feed"), sst.s.feed(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "act-setup"), sst.s.act.setup(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "act-ckpt"), sst.s.act.ckpt(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "act-check"),
    sst.s.act.check(t, base, "act-check", "bend/tests/fixtures/act/pilot-head.eplog", "bend/tests/fixtures/act/pilot-report.txt", "exit 0", "act-box: check: passed"),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "act-check-fail"),
    sst.s.act.check(t, base, "act-check-fail", "bend/tests/fixtures/act/r1-head.eplog", "bend/tests/fixtures/act/check.txt", "exit 1",
      "act-box: check: the checker failed more than it answered for lang=haskell"),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "act-start"), sst.s.act.start(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "act-pull"), sst.s.act.pull(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "act-ensure"), sst.s.act.ensure(t, base),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "chain-start-drop"), sst.s.chain(t, base, sst.scn.c1()),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "chain-outage"), sst.s.chain(t, base, sst.scn.c2()),
  Bool.pick(IO(List<&2, Sc.ScnRes>), String.eq(name, "dense-identity"), sst.s.ident(t, base),
    IO.die(List<&2, Sc.ScnRes>, 2, "sim stage: no scenario " ++ name ++ "; " ++ sst.usage()))))))))))))))))))

# N (1, 2, ...) as its name; a name as it is
def sst.name.of(+id: String) -> String:
  Bool.pick(String, Maybe.is_some(&2, Nat, Nat.read(id)),
    Maybe.default(&2, String, List.get(&2, String, sst.names(), Nat.sub(Maybe.default(&2, Nat, Nat.read(id), 1n), 1n)), id), id)

def sst.many(+t: SstT, +base: String, ns: List<&2, String>) -> IO(List<&2, Sc.ScnRes>):
  match ns:
    case Nil{}:
      IO.pure(List<&2, Sc.ScnRes>, Nil{})
    case +n <> rest:
      do IO<List<&2, Sc.ScnRes>>:
        a : List<&2, Sc.ScnRes> <- sst.pick(t, base, n)
        b : List<&2, Sc.ScnRes> <- sst.many(t, base, rest)
        return List.append(&2, Sc.ScnRes, a, b)

def sst.opt.which(+given: String, +name: String) -> IO(String):
  Sc.scn.opt.which(given, name)

def sst.tools(+argv0: String) -> IO(SstT):
  do IO<SstT>:
    sc : Sc.ScnTools <- Sc.scn.tools(argv0)
    p0 : String <- S.env("SIM_PUSH", "")
    p : String <- sst.opt.which(p0, "bend-push")
    e0 : String <- S.env("SIM_EPISODE", "")
    e : String <- sst.opt.which(e0, "bend-episode")
    o : String <- S.env("SIM_NEW_ONLY", "")
    return SstT{sc, p, e, String.eq(o, "1")}

def sst.main(+argv0: String, xs: List<String>) -> IO(Unit):
  match xs:
    case "all" <> +dir <> Nil{}:
      do IO<Unit>:
        t : SstT <- sst.tools(argv0)
        S.mkdir(dir)
        base : String <- S.realpath(dir)
        rs : List<&2, Sc.ScnRes> <- sst.many(t, base, sst.names())
        Sc.scn.report(rs, 0n)
    case +id <> +dir <> Nil{}:
      do IO<Unit>:
        t : SstT <- sst.tools(argv0)
        S.mkdir(dir)
        base : String <- S.realpath(dir)
        rs : List<&2, Sc.ScnRes> <- sst.many(t, base, [sst.name.of(id)])
        Sc.scn.report(rs, 0n)
    case _:
      IO.die(Unit, 2, sst.usage())

