import Base
import ../Sys.bend as S
import ./Local.bend as Lc

# Remote: the box, over ssh and rsync (2026-10-14, the plan's Phase 0).
#
#   rmt.box HOST PORT         the box and how it is reached: SSH_OPTS (more ssh options, split on
#                             blanks, e.g. `-i KEY -o UserKnownHostsFile=/dev/null` for a sandbox),
#                             SSH_TRIES (10) and SSH_RETRY_SLEEP (30 s); RSYNC_TRIES (10), PULL_WAIT (60 s)
#   rmt.ssh BOX SECS CMD      one fixed command line on the box; a connection that fails (ssh's exit
#                             255) is tried again, SSH_TRIES times SSH_RETRY_SLEEP apart (fp-chain.sh's
#                             rsh: the link drops for minutes, and a drop must never read as "no saves"
#                             or "no plan"); the banner a vast box prints is taken out of the answer
#   rmt.pull BOX SRC DIR ARGS  rsync -a ARGS --partial-dir=.partial HOST:SRC DIR/, RSYNC_TRIES times
#   rmt.push BOX SRC DST ARGS  PULL_WAIT apart (a dropped transfer resumes from its partial file)
#   rmt.sums BOX GLOB         `sha256sum GLOB` on the box: its checkpoints and their sha256
#   rmt.saved.of LOG          the checkpoints a trainer's log says it saved, as fp-chain.sh's saved()
#
# The commands sent are fixed command lines with no control flow (no `&&`,
# `;`, `|` or `if`): what they answer is parsed here, in Bend.  Every name
# starts with `rmt.`; the pure helpers are tested in bend/tests/ops.bend.

type RmtBox is Data:
  RmtBox{host: String, port: String, opts: List<&2, String>, tries: Nat, wait: Nat, rtries: Nat, rwait: Nat}

def rmt.host(+b: RmtBox) -> String:
  match b:
    case RmtBox{h, p, o, t, w, rt, rw}:
      h

def rmt.port(+b: RmtBox) -> String:
  match b:
    case RmtBox{h, p, o, t, w, rt, rw}:
      p

def rmt.opts(+b: RmtBox) -> List<&2, String>:
  match b:
    case RmtBox{h, p, o, t, w, rt, rw}:
      o

def rmt.tries(+b: RmtBox) -> Nat:
  match b:
    case RmtBox{h, p, o, t, w, rt, rw}:
      t

def rmt.wait(+b: RmtBox) -> Nat:
  match b:
    case RmtBox{h, p, o, t, w, rt, rw}:
      w

def rmt.rtries(+b: RmtBox) -> Nat:
  match b:
    case RmtBox{h, p, o, t, w, rt, rw}:
      rt

def rmt.rwait(+b: RmtBox) -> Nat:
  match b:
    case RmtBox{h, p, o, t, w, rt, rw}:
      rw

def rmt.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.str(x) <> rmt.strs(t)

def rmt.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> rmt.l1(t)

def rmt.box(+host: String, +port: String) -> IO(RmtBox):
  do IO<RmtBox>:
    opts : String <- S.env("SSH_OPTS", "")
    +t : Nat <- S.env.nat("SSH_TRIES", 10n)
    +w : Nat <- S.env.nat("SSH_RETRY_SLEEP", 30n)
    +rt : Nat <- S.env.nat("RSYNC_TRIES", 10n)
    +rw : Nat <- S.env.nat("PULL_WAIT", 60n)
    return RmtBox{host, port, rmt.strs(Lc.lcl.words(S.b(opts))), Nat.max(t, 1n), w, Nat.max(rt, 1n), rw}

# Words for the box's shell ------------------------------------------------------------

# a word quoted for the remote shell: 'x', a ' inside as '\''
def rmt.q(+s: String) -> String:
  "'" ++ S.str(S.replace(S.b(s), [39], S.b("'\\''"))) ++ "'"

# The vast banner: a vast box's shell greets every login ("Welcome to
# vast.ai ...", "Have fun!"), on stdout, and the scripts took it out with
# `grep -v "Welcome to vast.ai\|Have fun"`.
def rmt.banner(+l: List<&2, U32>) -> Bool:
  Bool.or(S.infix(l, S.b("Welcome to vast.ai")), S.infix(l, S.b("Have fun")))

def rmt.unbanner.go(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = rmt.unbanner.go(t)
      Bool.pick(List<&2, List<&2, U32>>, rmt.banner(l), rest, l <> rest)

# the text without the banner's lines (a final newline stays)
def rmt.unbanner(+xs: List<&2, U32>) -> List<&2, U32>:
  +ls = rmt.unbanner.go(S.split.lines(xs))
  Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, ls), 0n), Nil{},
    List.append(&2, U32, S.join(ls, 10), Bool.pick(List<&2, U32>, S.suffix(xs, [10]), [10], Nil{})))

# ssh ----------------------------------------------------------------------------------

def rmt.ssh.base(+b: RmtBox) -> List<&2, String>:
  List.append(&2, String, ["-n", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=30", "-o", "LogLevel=ERROR",
    "-o", "ServerAliveInterval=30", "-p", rmt.port(b)], rmt.opts(b))

def rmt.ssh.args(+b: RmtBox, +cmd: String) -> List<String>:
  rmt.l1(List.append(&2, String, rmt.ssh.base(b), [rmt.host(b), cmd]))

# again after a try that ended with status st: only a failed connection
# (255), and only while tries are left
def rmt.again(+st: U32, +attempt: Nat, +tries: Nat) -> Bool:
  Bool.and(U32.is_eq(st, 255), Nat.is_lt(attempt, tries))

def rmt.clean(+o: Lc.LclOut) -> Lc.LclOut:
  Lc.LclOut{Lc.lcl.status(o), rmt.unbanner(Lc.lcl.out(o)), rmt.unbanner(Lc.lcl.err(o))}

def rmt.ssh.once(+b: RmtBox, +secs: U32, +cmd: String) -> IO(Lc.LclOut):
  do IO<Lc.LclOut>:
    +o : Lc.LclOut <- Lc.lcl.run(secs, "ssh", rmt.ssh.args(b, cmd))
    return rmt.clean(o)

type RmtTry is Data:
  RmtTry{attempt: Nat, more: Bool, o: Lc.LclOut}

def rmt.secs(+n: Nat) -> U32:
  U32.from_nat(Nat.min(n, U32.to_nat(4000000)))

def rmt.ssh.step(+b: RmtBox, +secs: U32, +cmd: String, t: RmtTry) -> IO(RmtTry):
  match t:
    case RmtTry{+n, m, o}:
      do IO<RmtTry>:
        IO.sleep(U32.mul(rmt.secs(rmt.wait(b)), 1000))
        +o2 : Lc.LclOut <- rmt.ssh.once(b, secs, cmd)
        return RmtTry{1n+n, rmt.again(Lc.lcl.status(o2), 1n+n, rmt.tries(b)), o2}

def rmt.ssh.go(fuel: Nat, +b: RmtBox, +secs: U32, +cmd: String, t: RmtTry) -> IO(Lc.LclOut):
  match fuel t:
    case 1n+f RmtTry{n, True{}, o}:
      IO.bind(RmtTry, Lc.LclOut, rmt.ssh.step(b, secs, cmd, RmtTry{n, True{}, o}), rmt.ssh.go(f, b, secs, cmd))
    case _ RmtTry{n, m, o}:
      IO.pure(Lc.LclOut, o)

# CMD on the box, its answer (status, stdout and stderr without the banner):
# 255 after SSH_TRIES failed connections, 124 when SECS ran out
def rmt.ssh(+b: RmtBox, +secs: U32, +cmd: String) -> IO(Lc.LclOut):
  do IO<Lc.LclOut>:
    +o : Lc.LclOut <- rmt.ssh.once(b, secs, cmd)
    rmt.ssh.go(rmt.tries(b), b, secs, cmd, RmtTry{1n, rmt.again(Lc.lcl.status(o), 1n, rmt.tries(b)), o})

# rsync ----------------------------------------------------------------------------------

# rsync's remote shell: the ssh above, as one string
def rmt.rsh(+b: RmtBox) -> String:
  String.join(List.append(&2, String, ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=30", "-o", "LogLevel=ERROR",
    "-p", rmt.port(b)], rmt.opts(b)), " ")

def rmt.rsync.args(+b: RmtBox, extra: List<String>, +src: String, +dst: String) -> List<String>:
  List.append(&1, String, "-a" <> extra, ["--partial-dir=.partial", "-e", rmt.rsh(b), src, dst])

def rmt.remote(+b: RmtBox, +path: String) -> String:
  rmt.host(b) ++ ":" ++ path

type RmtRs is Data:
  RmtRs{attempt: Nat, ok: Bool}

def rmt.rs.once(+args: List<&2, String>) -> IO(Bool):
  do IO<Bool>:
    +o : Lc.LclOut <- Lc.lcl.run(21600, "rsync", rmt.l1(args))
    return Lc.lcl.ok(o)

def rmt.rs.step(+b: RmtBox, +args: List<&2, String>, r: RmtRs) -> IO(RmtRs):
  match r:
    case RmtRs{+n, ok}:
      do IO<RmtRs>:
        IO.sleep(U32.mul(rmt.secs(rmt.rwait(b)), 1000))
        ok2 : Bool <- rmt.rs.once(args)
        return RmtRs{1n+n, ok2}

def rmt.rs.go(fuel: Nat, +b: RmtBox, +args: List<&2, String>, r: RmtRs) -> IO(Bool):
  match fuel r:
    case 1n+f RmtRs{n, False{}}:
      IO.bind(RmtRs, Bool, rmt.rs.step(b, args, RmtRs{n, False{}}), rmt.rs.go(f, b, args))
    case _ RmtRs{n, ok}:
      IO.pure(Bool, ok)

def rmt.l2(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> rmt.l2(t)

# rsync with these arguments until it succeeds, RSYNC_TRIES times at most
def rmt.rsync(+b: RmtBox, args: List<String>) -> IO(Bool):
  +a = rmt.l2(args)
  do IO<Bool>:
    ok : Bool <- rmt.rs.once(a)
    rmt.rs.go(Nat.sub(rmt.rtries(b), 1n), b, a, RmtRs{1n, ok})

# the box's SRC into the directory DIR here (ARGS first: `--checksum`
# re-pulls a copy here that differs); whether it arrived
def rmt.pull(+b: RmtBox, +src: String, +dir: String, extra: List<String>) -> IO(Bool):
  rmt.rsync(b, rmt.rsync.args(b, extra, rmt.remote(b, src), dir ++ "/"))

# SRC here to DST on the box
def rmt.push(+b: RmtBox, +src: String, +dst: String, extra: List<String>) -> IO(Bool):
  rmt.rsync(b, rmt.rsync.args(b, extra, src, rmt.remote(b, dst)))

# What the box holds -------------------------------------------------------------------------

type RmtSums is Data:
  RmtSums{answered: Bool, sums: List<&2, Lc.LclSum>}

def rmt.sums.of(+o: Lc.LclOut) -> RmtSums:
  RmtSums{U32.is_ne(Lc.lcl.status(o), 255), Lc.lcl.sha.parse(Lc.lcl.out(o))}

# `sha256sum GLOB` on the box (GLOB e.g. ana/out/*.checkpoint):
# whether the box answered, and each file's sha256 by its name
def rmt.sums(+b: RmtBox, +glob: String) -> IO(RmtSums):
  do IO<RmtSums>:
    +o : Lc.LclOut <- rmt.ssh(b, 86400, "sha256sum " ++ glob)
    return rmt.sums.of(o)

# Is PATH there: Some size and mtime, None when it is not; the answer of a
# box that did not answer is Unknown.
type RmtStat is Data:
  RmtStatYes{st: Lc.LclSt}
  RmtStatNo{}
  RmtStatUnknown{}

def rmt.stat.got(+o: Lc.LclOut, m: Maybe<&2, Lc.LclSt>) -> RmtStat:
  match m:
    case Some{s}:
      RmtStatYes{s}
    case None{}:
      Bool.pick(RmtStat, U32.is_eq(Lc.lcl.status(o), 1), RmtStatNo{}, RmtStatUnknown{})

def rmt.stat.of(+o: Lc.LclOut) -> RmtStat:
  rmt.stat.got(o, Lc.lcl.stat.of(o))

def rmt.stat(+b: RmtBox, +path: String) -> IO(RmtStat):
  do IO<RmtStat>:
    +o : Lc.LclOut <- rmt.ssh(b, 120, "stat -c '%s %Y' -- " ++ rmt.q(path))
    return rmt.stat.of(o)

# how many processes on the box are named exactly by REGEX (pgrep -c -x):
# None when the box did not answer
def rmt.count.of(+o: Lc.LclOut) -> Maybe<&2, Nat>:
  Bool.pick(Maybe<&2, Nat>, Bool.or(Lc.lcl.ok(o), U32.is_eq(Lc.lcl.status(o), 1)), Lc.lcl.nat(Lc.lcl.nth(Lc.lcl.words(Lc.lcl.out(o)), 0n)), None{})

def rmt.count(+b: RmtBox, +regex: String) -> IO(Maybe<&2, Nat>):
  do IO<Maybe<&2, Nat>>:
    +o : Lc.LclOut <- rmt.ssh(b, 120, "pgrep -c -x " ++ rmt.q(regex))
    return rmt.count.of(o)

# A trainer's saves ------------------------------------------------------------------------
#
# fp-chain.sh's saved(): `grep -o 'saved out/[^ ]*\.checkpoint' LOG | sed -n
# 's#^saved out/\(.*-step\([0-9]*\)\.checkpoint\)$#\2 \1#p' | sort -n`: each
# `saved out/NAME-stepN.checkpoint` in a log, as (N, NAME-stepN.checkpoint),
# by step (a tie by name).  The text may be the log itself or grep's lines:
# after each `saved out/`, the run of non-blank bytes up to its last
# `.checkpoint` (grep's greedy [^ ]*), whose name must end in `-step` and
# digits (sed's pattern; no digits read as step 0, as sort -n reads them).

type RmtCk is Data:
  RmtCk{step: Nat, file: List<&2, U32>}

def rmt.ck.step(+c: RmtCk) -> Nat:
  match c:
    case RmtCk{s, f}:
      s

def rmt.ck.file(+c: RmtCk) -> List<&2, U32>:
  match c:
    case RmtCk{s, f}:
      f

def rmt.ck.le(a: RmtCk, b: RmtCk) -> Bool:
  match a b:
    case RmtCk{+s, +f} RmtCk{+t, +g}:
      Bool.or(Nat.is_lt(s, t), Bool.and(Nat.is_eq(s, t), Lc.lcl.le(f, g)))

def rmt.word.go(xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t False{}:
      h <> rmt.word.go(t, S.head.is(t, 32))
    case _ _:
      Nil{}

# the bytes up to the first space
def rmt.word(+xs: List<&2, U32>) -> List<&2, U32>:
  rmt.word.go(xs, S.head.is(xs, 32))

def rmt.ck.base(+w: List<&2, U32>, m: Maybe<&2, Nat>) -> Maybe<&2, List<&2, U32>>:
  match m:
    case None{}:
      None{}
    case Some{+k}:
      Some{List.take(&2, U32, w, Nat.sub(S.len(w), Nat.add(k, 11n)))}

# w up to (not with) its last ".checkpoint"
def rmt.upto.ck(+w: List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  rmt.ck.base(w, S.find(List.reverse(&2, U32, w), S.b("tniopkcehc."), 0n))

# the digits at the end of xs (acc: those since the last other byte, newest first)
def rmt.digits.end(xs: List<&2, U32>, +acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      List.reverse(&2, U32, acc)
    case +c <> t:
      rmt.digits.end(t, Bool.pick(List<&2, U32>, Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), c <> acc, Nil{}))

def rmt.ck.of(+base: List<&2, U32>) -> Maybe<&2, RmtCk>:
  +ds = rmt.digits.end(base, Nil{})
  +head = List.take(&2, U32, base, Nat.sub(S.len(base), S.len(ds)))
  Bool.pick(Maybe<&2, RmtCk>, S.suffix(head, S.b("-step")),
    Some{RmtCk{Maybe.default(&2, Nat, Lc.lcl.nat(ds), 0n), List.append(&2, U32, base, S.b(".checkpoint"))}}, None{})

def rmt.ck.from(m: Maybe<&2, List<&2, U32>>) -> Maybe<&2, RmtCk>:
  match m:
    case None{}:
      None{}
    case Some{+b}:
      rmt.ck.of(b)

def rmt.ck.put(m: Maybe<&2, RmtCk>, rest: List<&2, RmtCk>) -> List<&2, RmtCk>:
  match m:
    case Some{c}:
      c <> rest
    case None{}:
      rest

def rmt.saved.pieces(ps: List<&2, List<&2, U32>>) -> List<&2, RmtCk>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      rmt.ck.put(rmt.ck.from(rmt.upto.ck(rmt.word(p))), rmt.saved.pieces(t))

def rmt.saved.lines(ls: List<&2, List<&2, U32>>) -> List<&2, RmtCk>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, RmtCk, rmt.saved.pieces(List.drop(&2, List<&2, U32>, S.split.str(l, S.b("saved out/")), 1n)), rmt.saved.lines(t))

def rmt.saved.of(+xs: List<&2, U32>) -> List<&2, RmtCk>:
  List.sort(~RmtCk, ~rmt.ck.le, rmt.saved.lines(S.split.lines(xs)))

# the saves whose step is a multiple of EVERY (EVERY 0: none, a raw stage's)
def rmt.ck.every(cs: List<&2, RmtCk>, +every: Nat) -> List<&2, RmtCk>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      +rest = rmt.ck.every(t, every)
      Bool.pick(List<&2, RmtCk>, Bool.and(Nat.is_ne(every, 0n), Nat.is_eq(Nat.mod(rmt.ck.step(c), every), 0n)), c <> rest, rest)

def rmt.ck.files(cs: List<&2, RmtCk>) -> List<&2, List<&2, U32>>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      rmt.ck.file(c) <> rmt.ck.files(t)

def rmt.saved.got(+o: Lc.LclOut) -> Maybe<&2, List<&2, RmtCk>>:
  Bool.pick(Maybe<&2, List<&2, RmtCk>>, U32.is_eq(Lc.lcl.status(o), 255), None{}, Some{rmt.saved.of(Lc.lcl.out(o))})

# the saves LOG (a path on the box) records; None when the box did not answer
def rmt.saved(+b: RmtBox, +log: String) -> IO(Maybe<&2, List<&2, RmtCk>>):
  do IO<Maybe<&2, List<&2, RmtCk>>>:
    +o : Lc.LclOut <- rmt.ssh(b, 300, "grep -o 'saved out/[^ ]*\\.checkpoint' -- " ++ rmt.q(log))
    return rmt.saved.got(o)

