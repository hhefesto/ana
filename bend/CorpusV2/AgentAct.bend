import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ../Box/Local.bend as Lc

# bend-corpus-v2 agent-act CKPT DIR [K] (2026-10-15, the plan's Phase 3: all
# logic in Bend, the shell a thin shim): tools/corpus-v2/agent-act.sh, line
# for line.  ana's own episodes on train units, the turn-based training data
# (docs/AGENT.md): the act set's prompts answered through the tool loop as E5
# answers its own, but sampled, then `bend-episode accept` and `fixed`:
#
#   DEPLOY corpus-v2 agent-eval CKPT DIR 2 [K]      with the environment below
#   EPISODE accept CALLS CAP DIR/accepted DIR/episodes.eplog
#   AGENT_RECORDS=train EPISODE fixed CALLS CAP DIR/accepted DIR/episodes.eplog
#
# The environment is the script's, each `${V:-default}` (unset or empty: the
# default): DEPLOY_BIN (run/v2/gcroot-deploy-agent/bin/deploy), EPISODE_BIN
# (run/agent/gcroot-bend-episode/bin/bend-episode), PROCS (5), THREADS (2),
# FT_THREADS (2) as BEND_FT_THREADS, ACTSET (run/v2/act/prompts.nul) as
# EVALSET, TEMPERATURE (0.7), TOP_P (0.95), AGENT_SEEDS (2), AGENT_TAG
# (200000), TOKENS (256), AGENT_CALLS (4), CAP (2); agent-eval gets
# AGENT_DEPLOY=DEPLOY and AGENT_RECORDS=train too.  K (`${3:-0}`) goes to
# agent-eval only when it is not 0, and DEPLOY, EPISODE, CALLS, CAP and K are
# split into words as the script's unquoted expansions were.  agent-eval
# resumes a DIR, so a rerun goes on where it stopped.  A step that fails
# stops the rest with its exit status (set -e), and says so on stderr.
#
# Each step's output (stdout and stderr) reaches this program's stdout as it
# comes (the launcher's DIR.log, which the drivers tail): the step writes a
# file of its own under $TMPDIR (sh's `exec "$@" >> FILE 2>&1`, a redirect
# and nothing else) and this program copies the lines it adds every two
# seconds (`aac.follow`); the start and done lines are stamped in UTC-6 as
# the script's were.
#
# What differs from agent-act.sh, on purpose: the script cd'd to
# /home/hhefesto/src/formalTransformer; this runs where it is started, as
# every bend-corpus-v2 subcommand does (the repository root; `bend-ops act
# start` and `check` start it in the box's workspace).  Arguments past K are
# refused (the script ignored them).  Every name starts with `aac.`; the
# pure parts (the settings, the three command lines) are tested in
# bend/tests/act.bend.

# Settings ---------------------------------------------------------------------------------

type AacS is Data:
  AacS{deploy: String, ep: String, procs: String, threads: String, ft: String, actset: String, temp: String,
       topp: String, seeds: String, tag: String, tokens: String, calls: String, cap: String}

# ${V:-d}: v unless it is empty (an unset variable reads as empty here)
def aac.or(+v: String, +d: String) -> String:
  Bool.pick(String, String.is_empty(v), d, v)

def aac.nth(+vs: List<&2, String>, +i: Nat) -> String:
  Maybe.default(&2, String, List.get(&2, String, vs, i), "")

# the settings from the raw values, in the order aac.names lists them
def aac.settings.of(+vs: List<&2, String>) -> AacS:
  AacS{aac.or(aac.nth(vs, 0n), "run/v2/gcroot-deploy-agent/bin/deploy"), aac.or(aac.nth(vs, 1n), "run/agent/gcroot-bend-episode/bin/bend-episode"),
       aac.or(aac.nth(vs, 2n), "5"), aac.or(aac.nth(vs, 3n), "2"), aac.or(aac.nth(vs, 4n), "2"), aac.or(aac.nth(vs, 5n), "run/v2/act/prompts.nul"),
       aac.or(aac.nth(vs, 6n), "0.7"), aac.or(aac.nth(vs, 7n), "0.95"), aac.or(aac.nth(vs, 8n), "2"), aac.or(aac.nth(vs, 9n), "200000"), aac.or(aac.nth(vs, 10n), "256"),
       aac.or(aac.nth(vs, 11n), "4"), aac.or(aac.nth(vs, 12n), "2")}

def aac.names() -> List<&2, String>:
  ["DEPLOY_BIN", "EPISODE_BIN", "PROCS", "THREADS", "FT_THREADS", "ACTSET", "TEMPERATURE", "TOP_P", "AGENT_SEEDS",
   "AGENT_TAG", "TOKENS", "AGENT_CALLS", "CAP"]

def aac.gets(ns: List<&2, String>) -> IO(List<&2, String>):
  match ns:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case n <> t:
      do IO<List<&2, String>>:
        v : String <- S.env(n, "")
        rest : List<&2, String> <- aac.gets(t)
        return v <> rest

def aac.settings() -> IO(AacS):
  do IO<AacS>:
    vs : List<&2, String> <- aac.gets(aac.names())
    return aac.settings.of(vs)

# The command lines ------------------------------------------------------------------------

def aac.strs(ws: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> t:
      S.str(w) <> aac.strs(t)

def aac.l1(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      x <> aac.l1(t)

# an unquoted expansion's words (the shell's split on blanks)
def aac.words(+s: String) -> List<&2, String>:
  aac.strs(Lc.lcl.words(S.b(s)))

# agent-eval's environment, in the script's order
def aac.eval.env(+s: AacS) -> List<&2, String>:
  match s:
    case AacS{d, e, +p, +th, +ft, +as, +te, +tp, +se, +tg, +to, +ca, cp}:
      ["BEND_FT_THREADS=" ++ ft, "EVALSET=" ++ as, "AGENT_DEPLOY=" ++ d, "AGENT_RECORDS=train", "TEMPERATURE=" ++ te,
       "TOP_P=" ++ tp, "AGENT_SEEDS=" ++ se, "AGENT_TAG=" ++ tg, "TOKENS=" ++ to, "AGENT_CALLS=" ++ ca, "PROCS=" ++ p,
       "THREADS=" ++ th]

# `$( [ "$k" != 0 ] && echo "$k" )`: K's words unless K is 0
def aac.k(+k: String) -> List<&2, String>:
  Bool.pick(List<&2, String>, String.eq(k, "0"), Nil{}, aac.words(k))

# DEPLOY corpus-v2 agent-eval CKPT DIR 2 [K] (the program first)
def aac.eval.argv(+s: AacS, +ckpt: String, +dir: String, +k: String) -> List<&2, String>:
  match s:
    case AacS{+d, e, p, th, ft, as, te, tp, se, tg, to, ca, cp}:
      List.concat(&2, String, [aac.words(d), ["corpus-v2", "agent-eval", ckpt, dir, "2"], aac.k(k)])

# EPISODE MODE CALLS CAP DIR/accepted DIR/episodes.eplog (accept, fixed)
def aac.ep.argv(+s: AacS, +mode: String, +dir: String) -> List<&2, String>:
  match s:
    case AacS{d, +e, p, th, ft, as, te, tp, se, tg, to, +ca, +cp}:
      List.concat(&2, String, [aac.words(e), [mode], aac.words(ca), aac.words(cp), [dir ++ "/accepted", dir ++ "/episodes.eplog"]])

def aac.procs(+s: AacS) -> String:
  match s:
    case AacS{d, e, +p, th, ft, as, te, tp, se, tg, to, ca, cp}:
      p

def aac.threads(+s: AacS) -> String:
  match s:
    case AacS{d, e, p, +th, ft, as, te, tp, se, tg, to, ca, cp}:
      th

# Following a program's output ---------------------------------------------------------------
#
# `aac.follow(ENV, PROG ARGS)`: PROG runs as `sh -c 'exec "$@" >> "$0" 2>&1'
# FILE env ENV.. PROG ARGS..` (FILE in a fresh $TMPDIR directory, removed at
# the end) in a forked IO; this process reads what FILE gains through one
# open handle every two seconds and writes its whole lines to stdout (a
# line cut by a read waits for its end, so a UTF-8 character is never
# split), the rest when PROG ends.  The answer is PROG's exit status (sh's:
# 127 when it does not start).  The runtime flushes stdout whenever it
# waits, so the lines reach a log file within the two seconds.

def aac.chunk() -> U32:
  8388608

def aac.ms() -> U32:
  4000000000

def aac.sh.args(+file: String, env: List<&2, String>, +prog: String, args: List<&2, String>) -> List<String>:
  aac.l1(List.concat(&2, String, [["-c", "exec \"$@\" >> \"$0\" 2>&1", file, "env"], env, [prog], args]))

def aac.st(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> U32:
  match r:
    case Done{(code, oe)}:
      code
    case Fail{e}:
      127

def aac.spawn(+file: String, env: List<&2, String>, +prog: String, args: List<&2, String>) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <- Process.run("sh", aac.sh.args(file, env, prog, args), "", S.cap.bytes(), aac.ms())
    return aac.st(r)

# what a read added: the handle, the bytes so far, whether to read on
type AacD is Type:
  AacD{f: File, acc: List<&2, U32>, more: Bool}

def aac.d.res(g: File, x: Result<&1, &1, U32 & String, List<&2, U32>>, +acc: List<&2, U32>) -> IO(AacD):
  match x:
    case Fail{e}:
      IO.pure(AacD, AacD{g, acc, False{}})
    case Done{+xs}:
      IO.pure(AacD, AacD{g, List.append(&2, U32, acc, xs), Bool.not(List.is_empty(&2, U32, xs))})

def aac.d.got(+acc: List<&2, U32>, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(AacD):
  (g, x) = r
  aac.d.res(g, x, acc)

def aac.d.step(s: AacD) -> IO(AacD):
  match s:
    case AacD{f, +acc, m}:
      do IO<AacD>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, aac.chunk())
        aac.d.got(acc, r)

def aac.d.go(fuel: Nat, s: AacD) -> IO(AacD):
  match fuel s:
    case 1n+p AacD{f, acc, True{}}:
      IO.bind(AacD, AacD, aac.d.step(AacD{f, acc, True{}}), aac.d.go(p))
    case _ AacD{f, acc, m}:
      IO.pure(AacD, AacD{f, acc, m})

# xs reversed: (the bytes up to and with the last newline, what follows it)
def aac.cut.go(rs: List<&2, U32>, +part: List<&2, U32>, at: Bool) -> List<&2, U32> & List<&2, U32>:
  match rs at:
    case Nil{} _:
      (Nil{}, part)
    case h <> t True{}:
      (List.reverse(&2, U32, h <> t), part)
    case h <> +t False{}:
      aac.cut.go(t, h <> part, S.head.is(t, 10))

# the whole lines of xs (each with its newline) and the part line after them
def aac.cut(+xs: List<&2, U32>) -> List<&2, U32> & List<&2, U32>:
  +rs = List.reverse(&2, U32, xs)
  aac.cut.go(rs, Nil{}, S.head.is(rs, 10))

def aac.put(+xs: List<&2, U32>) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case h <> t:
      IO.write(S.str(h <> t))

def aac.show.cut(r: List<&2, U32> & List<&2, U32>) -> IO(List<&2, U32>):
  (whole, +part) = r
  do IO<List<&2, U32>>:
    aac.put(whole)
    return part

# the new bytes after part: the whole lines out (all of it at the end), the
# rest kept
def aac.show(fin: Bool, +xs: List<&2, U32>) -> IO(List<&2, U32>):
  match fin:
    case True{}:
      do IO<List<&2, U32>>:
        aac.put(xs)
        return Nil{}
    case False{}:
      aac.show.cut(aac.cut(xs))

type AacF is Type:
  AacF{f: File, part: List<&2, U32>}

def aac.f.got(fin: Bool, +part: List<&2, U32>, d: AacD) -> IO(AacF):
  match d:
    case AacD{g, +acc, m}:
      do IO<AacF>:
        +rest : List<&2, U32> <- aac.show(fin, List.append(&2, U32, part, acc))
        return AacF{g, rest}

def aac.f.step(fin: Bool, t: AacF) -> IO(AacF):
  match t:
    case AacF{f, +part}:
      IO.bind(AacD, AacF, aac.d.go(4096n, AacD{f, Nil{}, True{}}), aac.f.got(fin, part))

def aac.f.close(t: AacF) -> IO(Unit):
  match t:
    case AacF{f, p}:
      File.close(f)

def aac.f.end(t: AacF, +st: U32) -> IO(U32):
  do IO<U32>:
    u : AacF <- aac.f.step(True{}, t)
    aac.f.close(u)
    return st

def aac.f.go(fuel: Nat, +ch: Chan(U32), t: AacF, p: Poll<&1, &1, Maybe<&1, U32>, Unit>) -> IO(U32):
  match fuel p:
    case _ Ready{m}:
      aac.f.end(t, Maybe.default(&1, U32, m, 1))
    case 0n Wait{u}:
      do IO<U32>:
        +st : U32 <- IO.join(U32, ch)
        aac.f.end(t, st)
    case 1n+k Wait{u}:
      do IO<U32>:
        t2 : AacF <- aac.f.step(False{}, t)
        q : Poll<&1, &1, Maybe<&1, U32>, Unit> <- Chan.try_recv(U32, ch, 2000)
        aac.f.go(k, ch, t2, q)

def aac.follow(env: List<&2, String>, +prog: String, args: List<&2, String>) -> IO(U32):
  do IO<U32>:
    +tmp : String <- S.mktemp()
    +file : String = tmp ++ "/out"
    S.write(file, Nil{})
    f : File <- IO.try(File, File.open(file, "r"))
    +ch : Chan(U32) <- IO.fork(U32, aac.spawn(file, env, prog, args))
    q : Poll<&1, &1, Maybe<&1, U32>, Unit> <- Chan.try_recv(U32, ch, 2000)
    +st : U32 <- aac.f.go(U32.to_nat(4000000000), ch, AacF{f, Nil{}}, q)
    S.rm(tmp)
    return st

# argv (the program first) followed
def aac.run(env: List<&2, String>, argv: List<&2, String>) -> IO(U32):
  match argv:
    case Nil{}:
      IO.pure(U32, 127)
    case +p <> args:
      aac.follow(env, p, args)

# Main ---------------------------------------------------------------------------------------

def aac.log(+msg: String) -> IO(Unit):
  Ck.say("agent-act: " ++ msg)

def aac.must.if(ok: Bool, +st: U32, +what: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, st, "agent-act: " ++ what ++ " exited " ++ U32.show(st))

# set -e: a step that fails stops the rest with its status
def aac.must(+st: U32, +what: String) -> IO(Unit):
  aac.must.if(U32.is_eq(st, 0), st, what)

def aac.act(+ckpt: String, +dir: String, +k: String) -> IO(Unit):
  do IO<Unit>:
    +s : AacS <- aac.settings()
    aac.log("start: " ++ ckpt ++ " into " ++ dir ++ ", " ++ aac.procs(s) ++ " processes x " ++ aac.threads(s) ++ " threads")
    +a : U32 <- aac.run(aac.eval.env(s), aac.eval.argv(s, ckpt, dir, k))
    aac.must(a, "agent-eval")
    +b : U32 <- aac.run(Nil{}, aac.ep.argv(s, "accept", dir))
    aac.must(b, "bend-episode accept")
    +c : U32 <- aac.run(["AGENT_RECORDS=train"], aac.ep.argv(s, "fixed", dir))
    aac.must(c, "bend-episode fixed")
    aac.log("done")

def aac.usage() -> String:
  "usage: bend-corpus-v2 agent-act CKPT DIR [K]"

def aac.go.if(missing: Bool, +ckpt: String, +dir: String, +k: String) -> IO(Unit):
  match missing:
    case True{}:
      IO.die(Unit, 2, aac.usage())
    case False{}:
      aac.act(ckpt, dir, aac.or(k, "0"))

# ${1:?usage} ${2:?} ${3:-0}
def aac.go(+ckpt: String, +dir: String, +k: String) -> IO(Unit):
  aac.go.if(Bool.or(String.is_empty(ckpt), String.is_empty(dir)), ckpt, dir, k)

# xs: the arguments after `agent-act`
def aac.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +c <> +d <> Nil{}:
      aac.go(c, d, "0")
    case +c <> +d <> +k <> Nil{}:
      aac.go(c, d, k)
    case _:
      IO.die(Unit, 2, aac.usage())
