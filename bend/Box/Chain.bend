import Base
import ../Sys.bend as S
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./Vast.bend as Vs
import ./Alert.bend as Al
import ../Clock.bend as Ck

# Chain: a chain of runs on one box without a person present, then the
# scores, the pull and the DESTROY (2026-10-14, the plan's Phase 1a: the port
# of bend/gpu/fp-chain.sh to Bend; its log lines are fp-chain.sh's, byte for
# byte, since others grep them).
#
#   bend-ops chain HOST PORT INSTANCE DEST STAGES
#
# STAGES is a file, one stage a line, in order (# comments and blank lines
# skipped):  NAME BINARY EVERY [PLAN RUN_DIR SHARD_SIZE].  EVERY 0 marks a stage
# none of whose checkpoints are pulled (raw code): only its newest stays on the
# box, deleted once the next stage has loaded it; the chain's very last
# checkpoint is scored and pulled whatever its stage.  A stage's log is
# NAME.log on the box (the first stage's LOG0, train.log) and its saves
# out/NAME-step<N>.checkpoint.  A stage whose log is not on the box is started
# with `BOX_DRIVER again out/PREV PLAN RUN_DIR SHARD_SIZE NAME` from the last
# save of the stage before; the stage log on the box is the record that it
# started, so a start is tried again (5 times) only while the box answers that
# the log is not there, and a box that does not answer never reads as "not
# started": a dropped connection never starts a second trainer.  The first
# stage must already be running.
#
# Stages may be appended while the chain runs: at the end of the list it waits
# WAIT seconds (7200) for another line, and a stage whose PLAN is not on the box
# yet waits WAIT for it (both polled every WAIT_POLL, 60 s).  Every POLL seconds
# (120) it looks at the running stage (its log's size, the trainers named
# BINARY, the log's tail), pulls the saves whose step is a multiple of EVERY
# (once the log says `saved`), and removes on the box its other saves but the
# newest.  A stage whose log says `done at step` is done; one with no trainer
# whose log has been still for DEAD_QUIET seconds (1200) died: DEST/DIED says
# which, an alert goes out, and no later stage starts.  Then every pulled
# checkpoint and each stage's last are scored on run/eval/transcript-fp.corpus
# and run/eval/transcript-next.corpus (eval.log, eval-next.log; EXTRA_EVAL
# first): with BOX_DRIVER ./fp.sh synchronously as fp-chain.sh did, with
# ./bend-box (the default) by a detached `bend-box eval-both` whose eval.done
# the chain polls for (a dropped link no longer restarts the eval; no new
# output for EVAL_QUIET seconds, 3600, and the chain goes on without it).  The
# last checkpoints are pulled, and every checkpoint on the box is held to its
# copy here: box sha256 ⊆ local sha256.txt, and every wanted checkpoint here
# and whole.  A refusal a pull can mend is tried again VERIFY_WAIT (600 s)
# apart, 12 times, with --checksum pulls of the unmatched (alerted once); one
# it cannot, or the last try, writes DEST/REFUSED, alerts and exits 1 (the
# watch takes it from there).  Then the box is destroyed: after DEST/HOLD's
# epoch deadline if that file exists, never if DEST/CONTINUED exists.  The
# destroy counts only when a listing that reads no longer shows the instance:
# DESTROYED, `finished`, exit 0; still listed (or no listing that reads in
# LIST_TRIES tries, LIST_WAIT apart) writes REFUSED, alerts and exits 1.
#
# Restarting the chain at any point resumes it: the stage logs on the box say
# which stages started, the pulled checkpoints are here, and DEST/chain.eval
# says which scores were started (and logged): a restarted chain collects a
# detached eval's eval.done, or calls `eval-both` again, which reports the job
# still running (eval.pid) or starts it again when a reboot killed it.  A
# DEST with DESTROYED is left alone (exit 0).
#
# bend-box's eval-both (bend/Box/OnBox.bend, phase 1b) as the chain uses it:
# `env -C BOX_DIR ./bend-box eval-both CKPT...` returns at once; the job
# writes eval.log, then eval-next.log when run/eval/transcript-next.corpus is
# there, then eval.done (`[stamp] eval exit S; eval-next exit S|skipped ...`).
# The chain removes a stale eval.done first and greps `^==|bits_per_byte` from
# both logs into chain.log, `next:` between, as fp-chain.sh did.
#
# Environment: V (vastai), ALERT_CMD, POLL, WAIT, WAIT_POLL, LOG0, PULL_WAIT,
# VERIFY_WAIT, EXTRA_EVAL, BOX_DRIVER (./bend-box; ./fp.sh), BOX_DIR
# (formalTransformer: the trainer's directory, relative to the box's home or
# absolute), DEAD_QUIET, EVAL_QUIET; START_SETTLE (20 s after a start before
# its log is looked for), SETTLE (40 s after a start), HOLD_POLL (30),
# DESTROY_WAIT (10), LIST_TRIES (6), LIST_WAIT (30); Remote's SSH_OPTS,
# SSH_TRIES, SSH_RETRY_SLEEP, RSYNC_TRIES.
#
# Every name starts with `chn.`; the decisions are pure functions, tested in
# bend/tests/chain.bend on run 3's files; the loops are fuel-first.

# The configuration -----------------------------------------------------------------------

type ChnCfg is Data:
  ChnCfg{box: Rm.RmtBox, inst: String, dest: String, stages: String, dir: String, drv: String, v: String, log0: String, extra: String, ts: List<&2, Nat>}

def chn.box(+c: ChnCfg) -> Rm.RmtBox:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      b

def chn.inst(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      i

def chn.dest(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      d

def chn.stages(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      s

def chn.dir(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      r

def chn.drv(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      dv

def chn.v(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      v

def chn.log0(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      l

def chn.extra(+c: ChnCfg) -> String:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      e

def chn.tn(+c: ChnCfg, +k: Nat) -> Nat:
  match c:
    case ChnCfg{b, i, d, s, r, dv, v, l, e, ts}:
      Maybe.default(&2, Nat, List.get(&2, Nat, ts, k), 0n)

# the timings, in seconds, and their environment names (in chn.tn's order)
def chn.t.names() -> List<&2, String>:
  ["POLL", "WAIT", "WAIT_POLL", "DEAD_QUIET", "VERIFY_WAIT", "START_SETTLE", "SETTLE", "HOLD_POLL", "DESTROY_WAIT", "LIST_TRIES", "LIST_WAIT", "EVAL_QUIET"]

def chn.t.defaults() -> List<&2, Nat>:
  [120n, U32.to_nat(7200), 60n, U32.to_nat(1200), U32.to_nat(600), 20n, 40n, 30n, 10n, 6n, 30n, U32.to_nat(3600)]

def chn.poll(+c: ChnCfg) -> Nat:
  chn.tn(c, 0n)

def chn.wait(+c: ChnCfg) -> Nat:
  chn.tn(c, 1n)

def chn.wpoll(+c: ChnCfg) -> Nat:
  chn.tn(c, 2n)

def chn.dead(+c: ChnCfg) -> Nat:
  chn.tn(c, 3n)

def chn.vwait(+c: ChnCfg) -> Nat:
  chn.tn(c, 4n)

def chn.settle0(+c: ChnCfg) -> Nat:
  chn.tn(c, 5n)

def chn.settle(+c: ChnCfg) -> Nat:
  chn.tn(c, 6n)

def chn.hpoll(+c: ChnCfg) -> Nat:
  chn.tn(c, 7n)

def chn.dwait(+c: ChnCfg) -> Nat:
  chn.tn(c, 8n)

def chn.ltries(+c: ChnCfg) -> Nat:
  chn.tn(c, 9n)

def chn.lwait(+c: ChnCfg) -> Nat:
  chn.tn(c, 10n)

def chn.equiet(+c: ChnCfg) -> Nat:
  chn.tn(c, 11n)

def chn.envs(names: List<&2, String>, ds: List<&2, Nat>) -> IO(List<&2, Nat>):
  match names ds:
    case n <> nt +d <> dt:
      do IO<List<&2, Nat>>:
        +x : Nat <- S.env.nat(n, d)
        rest : List<&2, Nat> <- chn.envs(nt, dt)
        return x <> rest
    case _ _:
      IO.pure(List<&2, Nat>, Nil{})

# BOX_DRIVER: ./fp.sh scores on the box synchronously, ./bend-box detached
def chn.fp(+drv: String) -> Bool:
  String.eq(S.base(drv), "fp.sh")

def chn.drv.ok(+drv: String) -> Bool:
  Bool.or(chn.fp(drv), String.eq(S.base(drv), "bend-box"))

# Text ---------------------------------------------------------------------------------------

def chn.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.str(x) <> chn.strs(t)

def chn.bytes(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.b(x) <> chn.bytes(t)

def chn.has(xs: List<&2, String>, +x: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case y <> t:
      Bool.or(String.eq(y, x), chn.has(t, x))

# words joined, each behind a space (the shell's `"$x $f"` accumulations)
def chn.spaced(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      " " ++ x ++ chn.spaced(t)

# each word quoted for the box's shell, behind a space
def chn.qs(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      " " ++ Rm.rmt.q(x) ++ chn.qs(t)

def chn.space(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(Bool.or(U32.is_eq(c, 13), U32.is_eq(c, 11)), U32.is_eq(c, 12)))

def chn.lstrip(xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t True{}:
      chn.lstrip(t, chn.space(Lc.lcl.at(t, 0n)))
    case r _:
      r

# The stages file ------------------------------------------------------------------------------

type ChnStage is Data:
  ChnStage{name: String, bin: String, every: String, plan: String, rdir: String, ssz: String}

# a line fp-chain.sh's `grep -v '^[[:space:]]*\(#\|$\)'` keeps
def chn.stage.line(+l: List<&2, U32>) -> Bool:
  +r = chn.lstrip(l, chn.space(Lc.lcl.at(l, 0n)))
  Bool.and(Nat.is_ne(S.len(r), 0n), Bool.not(S.head.is(r, 35)))

def chn.stage.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +rest = chn.stage.lines(t)
      Bool.pick(List<&2, List<&2, U32>>, chn.stage.line(l), l <> rest, rest)

# the k-th stage line (k from 1), None past the end
def chn.stage.at(+text: List<&2, U32>, +k: Nat) -> Maybe<&2, List<&2, U32>>:
  List.get(&2, List<&2, U32>, chn.stage.lines(S.split.lines(text)), Nat.sub(k, 1n))

def chn.stage.of(+l: List<&2, U32>) -> ChnStage:
  +ws = Lc.lcl.words(l)
  ChnStage{S.str(Lc.lcl.nth(ws, 0n)), S.str(Lc.lcl.nth(ws, 1n)), S.str(Lc.lcl.nth(ws, 2n)), S.str(Lc.lcl.nth(ws, 3n)), S.str(Lc.lcl.nth(ws, 4n)),
    S.str(Lc.lcl.nth(ws, 5n))}

def chn.st.name(+s: ChnStage) -> String:
  match s:
    case ChnStage{n, b, e, p, r, z}:
      n

def chn.st.bin(+s: ChnStage) -> String:
  match s:
    case ChnStage{n, b, e, p, r, z}:
      b

def chn.st.every(+s: ChnStage) -> String:
  match s:
    case ChnStage{n, b, e, p, r, z}:
      e

def chn.st.plan(+s: ChnStage) -> String:
  match s:
    case ChnStage{n, b, e, p, r, z}:
      p

def chn.st.rdir(+s: ChnStage) -> String:
  match s:
    case ChnStage{n, b, e, p, r, z}:
      r

def chn.st.ssz(+s: ChnStage) -> String:
  match s:
    case ChnStage{n, b, e, p, r, z}:
      z

# a stage's log on the box: NAME.log, the first stage's LOG0
def chn.log.of(+k: Nat, +name: String, +log0: String) -> String:
  Bool.pick(String, Nat.is_eq(k, 1n), log0, name ++ ".log")

# Saves -------------------------------------------------------------------------------------------

# the saves to pull: those whose step is a multiple of EVERY (none for EVERY 0)
def chn.multiples(cs: List<&2, Rm.RmtCk>, +every: Nat) -> List<&2, String>:
  chn.strs(Rm.rmt.ck.files(Rm.rmt.ck.every(cs, every)))

def chn.not.mult(cs: List<&2, Rm.RmtCk>, +every: Nat) -> List<&2, Rm.RmtCk>:
  match cs:
    case Nil{}:
      Nil{}
    case +c <> t:
      +rest = chn.not.mult(t, every)
      Bool.pick(List<&2, Rm.RmtCk>, Bool.or(Nat.is_eq(every, 0n), Nat.is_ne(Nat.mod(Rm.rmt.ck.step(c), Nat.max(every, 1n)), 0n)), c <> rest, rest)

def chn.minus(xs: List<&2, String>, +ys: List<&2, String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = chn.minus(t, ys)
      Bool.pick(List<&2, String>, chn.has(ys, x), rest, x <> rest)

# the saves to remove on the box: all but the newest whose step is not a
# multiple of EVERY (EVERY 0: all but the newest); `done` were removed already
def chn.prunable(+cs: List<&2, Rm.RmtCk>, +every: Nat, +done: List<&2, String>) -> List<&2, String>:
  +n = List.length(&2, Rm.RmtCk, cs)
  chn.minus(chn.strs(Rm.rmt.ck.files(chn.not.mult(List.take(&2, Rm.RmtCk, cs, Nat.sub(n, 1n)), every))), done)

# the newest save (the log's last by step)
def chn.last(+cs: List<&2, Rm.RmtCk>) -> Maybe<&2, String>:
  +fs = chn.strs(Rm.rmt.ck.files(cs))
  List.get(&2, String, fs, Nat.sub(List.length(&2, String, fs), 1n))

def chn.cks(m: Maybe<&2, List<&2, Rm.RmtCk>>) -> List<&2, Rm.RmtCk>:
  Maybe.default(&2, List<&2, Rm.RmtCk>, m, Nil{})

# Following a stage ----------------------------------------------------------------------------------

# What one look at the box saw: whether it answered (the log there, the count
# and the tail read), the log's size and the trainer count as the box wrote
# them, the log's last 200 bytes.
type ChnObs is Data:
  ChnObs{ok: Bool, size: String, procs: String, tail: List<&2, U32>}

# the state between looks: the size seen last (fp-chain.sh's last_size, "0" at
# first) and how long the log has been still with no trainer (by POLL)
type ChnFo is Data:
  ChnFo{last: String, quiet: Nat}

type ChnPh is Data:
  ChnRunning{}
  ChnDone{}
  ChnDied{}
  ChnNoAnswer{}

type ChnFv is Data:
  ChnFv{ph: ChnPh, fo: ChnFo}

def chn.obs.size(s: Rm.RmtStat) -> Maybe<&2, String>:
  match s:
    case Rm.RmtStatYes{st}:
      Some{Nat.show(Lc.lcl.st.size(st))}
    case _:
      None{}

def chn.obs.got(m: Maybe<&2, String>, +counted: Bool, +procs: String, +tailed: Bool, +tail: List<&2, U32>) -> ChnObs:
  match m:
    case Some{s}:
      ChnObs{Bool.and(counted, tailed), s, procs, tail}
    case None{}:
      ChnObs{False{}, "", procs, tail}

# the answers to `stat`, `pgrep -c -x BIN` and `tail -c 200 LOG` on the box
def chn.obs.of(s: Rm.RmtStat, +n: Lc.LclOut, +t: Lc.LclOut) -> ChnObs:
  chn.obs.got(chn.obs.size(s), Bool.or(Lc.lcl.ok(n), U32.is_eq(Lc.lcl.status(n), 1)), S.str(Lc.lcl.nth(Lc.lcl.words(Lc.lcl.out(n)), 0n)),
    Lc.lcl.ok(t), Lc.lcl.out(t))

# fp-chain.sh's follow step: done when the tail says `done at step`; with no
# trainer, still for DEAD_QUIET (counted in POLLs) is dead; a box that did not
# answer changes nothing
def chn.follow.next(f: ChnFo, o: ChnObs, +poll: Nat, +dead: Nat) -> ChnFv:
  match f o:
    case ChnFo{+last, +quiet} ChnObs{False{}, size, procs, tail}:
      ChnFv{ChnNoAnswer{}, ChnFo{last, quiet}}
    case ChnFo{+last, +quiet} ChnObs{True{}, +size, +procs, +tail}:
      +none = Bool.or(String.is_empty(procs), String.eq(procs, "0"))
      +q = Bool.pick(Nat, none, Bool.pick(Nat, String.eq(size, last), Nat.add(quiet, poll), 0n), 0n)
      +ph = Bool.pick(ChnPh, S.infix(tail, S.b("done at step")), ChnDone{}, Bool.pick(ChnPh, Bool.and(none, Nat.is_le(dead, q)), ChnDied{}, ChnRunning{}))
      ChnFv{ph, ChnFo{size, q}}

def chn.ph.word(+p: ChnPh) -> String:
  match p:
    case ChnRunning{}:
      "running"
    case ChnDone{}:
      "done"
    case ChnDied{}:
      "died"
    case ChnNoAnswer{}:
      "unknown"

def chn.nl.space(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(U32, U32.is_eq(c, 10), 32, c) <> chn.nl.space(t)

# bash's ${tail: -100} of the tail with its newlines made spaces: its last 100
# characters, nothing when it is shorter
def chn.last100(+tail: List<&2, U32>) -> String:
  +s = S.str(chn.nl.space(tail))
  +n = String.length(s)
  Bool.pick(String, Nat.is_lt(n, 100n), "", String.drop(s, Nat.sub(n, 100n)))

# the per-poll line: `LOG STATE: SIZE bytes, N trainer(s); TAIL`
def chn.progress(+lg: String, +ph: ChnPh, +o: ChnObs) -> String:
  match o:
    case ChnObs{ok, size, procs, tail}:
      lg ++ " " ++ chn.ph.word(ph) ++ ": " ++ size ++ " bytes, " ++ procs ++ " trainer(s); " ++ chn.last100(tail)

# The scores -------------------------------------------------------------------------------------------

type ChnLog is Data:
  ChnLog{lg: String, every: Nat}

def chn.lg.log(+l: ChnLog) -> String:
  match l:
    case ChnLog{g, e}:
      g

def chn.lg.every(+l: ChnLog) -> Nat:
  match l:
    case ChnLog{g, e}:
      e

# each stage's saves, as the box listed them at the time
type ChnSaves is Data:
  ChnSaves{every: Nat, cks: List<&2, Rm.RmtCk>}

def chn.outs(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      "out/" ++ x ++ " " ++ chn.outs(t)

def chn.evals.of(ss: List<&2, ChnSaves>) -> String:
  match ss:
    case Nil{}:
      ""
    case ChnSaves{+e, +cs} <> t:
      Bool.pick(String, Nat.is_eq(e, 0n), "", " " ++ chn.outs(chn.multiples(cs, e))) ++ chn.evals.of(t)

def chn.evals.lasts(ls: List<&2, String>, +ev: String) -> String:
  match ls:
    case Nil{}:
      ev
    case +l <> t:
      chn.evals.lasts(t, Bool.pick(String, String.contains(" " ++ ev ++ " ", " out/" ++ l ++ " "), ev, ev ++ " out/" ++ l))

# fp-chain.sh's $evals, spaces and all: EXTRA_EVAL first, then each pulled
# stage's multiples of EVERY (out/NAME, each behind a space, a space before the
# stage's), then each last not already there
def chn.evals(+extra: String, +ss: List<&2, ChnSaves>, +lasts: List<&2, String>) -> String:
  Bool.pick(String, String.is_empty(extra), "", extra ++ " ") ++ chn.evals.lasts(lasts, chn.evals.of(ss))

def chn.words(+s: String) -> List<&2, String>:
  chn.strs(Lc.lcl.words(S.b(s)))

# the checkpoints to have here: each pulled stage's multiples, then the lasts
# (a name may be there twice, as fp-chain.sh counted it)
def chn.want(ss: List<&2, ChnSaves>, +lasts: List<&2, String>) -> List<&2, String>:
  match ss:
    case Nil{}:
      lasts
    case ChnSaves{+e, +cs} <> t:
      List.append(&2, String, chn.multiples(cs, e), chn.want(t, lasts))

# Verify -----------------------------------------------------------------------------------------------

# what the box and this machine hold: whether the box gave sha256s, the box's
# checkpoints not here with the same sha256, and the wanted ones missing here
type ChnVer is Data:
  ChnVer{remote: Nat, unmatched: List<&2, String>, missing: List<&2, String>}

def chn.ver.ok(+v: ChnVer) -> Bool:
  match v:
    case ChnVer{+r, u, m}:
      Bool.and(Nat.is_ne(r, 0n), Bool.and(List.is_empty(&2, String, u), List.is_empty(&2, String, m)))

# a refusal a pull can mend: no sha256 from the box, or a box checkpoint not here
def chn.ver.mend(+v: ChnVer) -> Bool:
  match v:
    case ChnVer{+r, u, m}:
      Bool.or(Nat.is_eq(r, 0n), Bool.not(List.is_empty(&2, String, u)))

def chn.ver.why(+v: ChnVer) -> String:
  match v:
    case ChnVer{+r, +u, +m}:
      Bool.pick(String, Nat.is_eq(r, 0n), " the box gave no sha256;", "")
        ++ Bool.pick(String, List.is_empty(&2, String, u), "", " not here with the box's sha256:" ++ chn.spaced(u) ++ ";")
        ++ Bool.pick(String, List.is_empty(&2, String, m), "", " wanted but not pulled:" ++ chn.spaced(m) ++ ";")

def chn.ver.unmatched(+v: ChnVer) -> List<&2, String>:
  match v:
    case ChnVer{r, u, m}:
      u

def chn.ver.remote(+v: ChnVer) -> Nat:
  match v:
    case ChnVer{r, u, m}:
      r

# the verdict: box sha256 ⊆ local sha256 (a checkpoint only here, pulled and
# then pruned on the box, has nothing to match), every wanted one here (`have`:
# here, whole, and in the local listing)
def chn.verify.of(+box: List<&2, Lc.LclSum>, +here: List<&2, Lc.LclSum>, +want: List<&2, String>, +have: List<&2, String>) -> ChnVer:
  ChnVer{List.length(&2, Lc.LclSum, box), chn.strs(Lc.lcl.sha.unmatched(box, here)), chn.minus(want, have)}

type ChnNext is Data:
  ChnPass{}
  ChnAgain{}
  ChnRefuse{}

# after try TRIES: pass, try again (a mendable refusal, fewer than 12 tries), refuse
def chn.verify.next(+v: ChnVer, +tries: Nat) -> ChnNext:
  Bool.pick(ChnNext, chn.ver.ok(v), ChnPass{}, Bool.pick(ChnNext, Bool.and(chn.ver.mend(v), Nat.is_lt(tries, 12n)), ChnAgain{}, ChnRefuse{}))

# HOLD and CONTINUED ----------------------------------------------------------------------------------

type ChnHold is Data:
  ChnHoldWait{}
  ChnHoldGo{}
  ChnHoldTaken{}

# fp-chain.sh's `while HOLD's deadline is ahead and no CONTINUED: sleep`, then
# CONTINUED means someone took the box over
def chn.hold.of(+now: Nat, hold: Maybe<&2, Nat>, +continued: Bool) -> ChnHold:
  match hold:
    case Some{+t}:
      Bool.pick(ChnHold, continued, ChnHoldTaken{}, Bool.pick(ChnHold, Nat.is_lt(now, t), ChnHoldWait{}, ChnHoldGo{}))
    case None{}:
      Bool.pick(ChnHold, continued, ChnHoldTaken{}, ChnHoldGo{})

# IO: logs, the box, files ------------------------------------------------------------------------------

def chn.logf(+c: ChnCfg) -> String:
  chn.dest(c) ++ "/chain.log"

def chn.log(+c: ChnCfg, +msg: String) -> IO(Unit):
  Al.alr.log(chn.logf(c), msg)

def chn.alert(+c: ChnCfg, +msg: String) -> IO(Unit):
  Al.alr.alert(chn.logf(c), "ana box " ++ chn.inst(c), msg)

def chn.say.err(none: Bool, +t: List<&2, U32>) -> IO(Unit):
  match none:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.print_err(S.str(t))

# text into chain.log as it is (no stamp), as fp-chain.sh's `| tee -a` put it
def chn.raw(+c: ChnCfg, +t: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    S.add(chn.logf(c), t)
    chn.say.err(Nat.is_eq(S.len(t), 0n), S.chomp(t))

def chn.sleep(+secs: Nat) -> IO(Unit):
  IO.sleep(U32.mul(Rm.rmt.secs(secs), 1000))

def chn.at(+c: ChnCfg, +rel: String) -> String:
  chn.dir(c) ++ "/" ++ rel

def chn.ssh(+c: ChnCfg, +secs: U32, +cmd: String) -> IO(Lc.LclOut):
  Rm.rmt.ssh(chn.box(c), secs, cmd)

def chn.saved(+c: ChnCfg, +lg: String) -> IO(Maybe<&2, List<&2, Rm.RmtCk>>):
  Rm.rmt.saved(chn.box(c), chn.at(c, lg))

def chn.out(+c: ChnCfg) -> String:
  chn.dest(c) ++ "/out"

def chn.have(+c: ChnCfg, +f: String) -> IO(Bool):
  Lc.lcl.have(chn.out(c), f)

# a pull the link drops resumes (rsync's partial directory), RSYNC_TRIES times
# PULL_WAIT apart; more arguments go to rsync (--checksum re-pulls a copy here
# that differs)
def chn.pull.said(ok: Bool, +c: ChnCfg, +f: String) -> IO(Bool):
  match ok:
    case True{}:
      do IO<Bool>:
        chn.log(c, "pulled " ++ f)
        return True{}
    case False{}:
      do IO<Bool>:
        chn.log(c, "could not pull " ++ f)
        return False{}

def chn.pull.one(+c: ChnCfg, +f: String, extra: List<String>) -> IO(Bool):
  do IO<Bool>:
    ok : Bool <- Rm.rmt.pull(chn.box(c), chn.at(c, "out/" ++ f), chn.out(c), extra)
    chn.pull.said(ok, c, f)

def chn.pull.if(there: Bool, +c: ChnCfg, +f: String) -> IO(Unit):
  match there:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        ok : Bool <- chn.pull.one(c, f, Nil{})
        return Unit{}

# those of fs not here yet, pulled
def chn.pull.each(+c: ChnCfg, fs: List<&2, String>) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +f <> t:
      do IO<Unit>:
        h : Bool <- chn.have(c, f)
        chn.pull.if(h, c, f)
        chn.pull.each(c, t)

def chn.pull.checksum(+c: ChnCfg, fs: List<&2, String>) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +f <> t:
      do IO<Unit>:
        ok : Bool <- chn.pull.one(c, f, ["--checksum"])
        chn.pull.checksum(c, t)

def chn.rm.paths(+c: ChnCfg, fs: List<&2, String>) -> List<&2, String>:
  match fs:
    case Nil{}:
      Nil{}
    case +f <> t:
      chn.at(c, "out/" ++ f) <> chn.rm.paths(c, t)

def chn.prune.done(ok: Bool, +done: List<&2, String>, +fs: List<&2, String>) -> List<&2, String>:
  Bool.pick(List<&2, String>, ok, List.append(&2, String, done, fs), done)

# remove FS on the box in one `rm -f`; the names removed are added to DONE
def chn.prune.do(none: Bool, +c: ChnCfg, +fs: List<&2, String>, +done: List<&2, String>) -> IO(List<&2, String>):
  match none:
    case True{}:
      IO.pure(List<&2, String>, done)
    case False{}:
      do IO<List<&2, String>>:
        +o : Lc.LclOut <- chn.ssh(c, 300, "rm -f --" ++ chn.qs(chn.rm.paths(c, fs)))
        return chn.prune.done(Lc.lcl.ok(o), done, fs)

def chn.prune(+c: ChnCfg, +cs: List<&2, Rm.RmtCk>, +every: Nat, +done: List<&2, String>) -> IO(List<&2, String>):
  +fs = chn.prunable(cs, every, done)
  chn.prune.do(List.is_empty(&2, String, fs), c, fs, done)

# a stage's saves pulled (the multiples of EVERY) and pruned on the box, from
# one listing of its log (None: the box did not answer, nothing is done)
def chn.tend.got(m: Maybe<&2, List<&2, Rm.RmtCk>>, +c: ChnCfg, +every: Nat, +done: List<&2, String>) -> IO(List<&2, String>):
  match m:
    case None{}:
      IO.pure(List<&2, String>, done)
    case Some{+cs}:
      do IO<List<&2, String>>:
        chn.pull.each(c, chn.multiples(cs, every))
        chn.prune(c, cs, every, done)

def chn.tend(+c: ChnCfg, +lg: String, +every: Nat, +done: List<&2, String>) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    m : Maybe<&2, List<&2, Rm.RmtCk>> <- chn.saved(c, lg)
    chn.tend.got(m, c, every, done)

def chn.pull.new.got(m: Maybe<&2, List<&2, Rm.RmtCk>>, +c: ChnCfg, +every: Nat) -> IO(Unit):
  chn.pull.each(c, chn.multiples(chn.cks(m), every))

# fp-chain.sh's pull_new: the multiples of EVERY not here yet
def chn.pull.new(+c: ChnCfg, +lg: String, +every: Nat) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&2, List<&2, Rm.RmtCk>> <- chn.saved(c, lg)
    chn.pull.new.got(m, c, every)

# Is PATH (relative to BOX_DIR) on the box: a box that does not answer is
# asked again, POLL apart, until it does (it never reads as "no").
type ChnK is Data:
  ChnK{s: Rm.RmtStat}

def chn.known.step(+c: ChnCfg, +rel: String) -> IO(ChnK):
  do IO<ChnK>:
    chn.log(c, "the box did not answer whether " ++ rel ++ " is there; asking again in " ++ Nat.show(chn.poll(c)) ++ " s")
    chn.sleep(chn.poll(c))
    s : Rm.RmtStat <- Rm.rmt.stat(chn.box(c), chn.at(c, rel))
    return ChnK{s}

def chn.known.go(fuel: Nat, +c: ChnCfg, +rel: String, k: ChnK) -> IO(Bool):
  match fuel k:
    case _ ChnK{Rm.RmtStatYes{st}}:
      IO.pure(Bool, True{})
    case _ ChnK{Rm.RmtStatNo{}}:
      IO.pure(Bool, False{})
    case 0n ChnK{Rm.RmtStatUnknown{}}:
      IO.pure(Bool, False{})
    case 1n+f ChnK{Rm.RmtStatUnknown{}}:
      IO.bind(ChnK, Bool, chn.known.step(c, rel), chn.known.go(f, c, rel))

def chn.known(+c: ChnCfg, +rel: String) -> IO(Bool):
  do IO<Bool>:
    s : Rm.RmtStat <- Rm.rmt.stat(chn.box(c), chn.at(c, rel))
    chn.known.go(U32.to_nat(100000), c, rel, ChnK{s})

def chn.yes(s: Rm.RmtStat) -> Bool:
  match s:
    case Rm.RmtStatYes{st}:
      True{}
    case _:
      False{}

def chn.answered(s: Rm.RmtStat) -> Bool:
  match s:
    case Rm.RmtStatUnknown{}:
      False{}
    case _:
      True{}

def chn.size(s: Rm.RmtStat) -> Nat:
  match s:
    case Rm.RmtStatYes{st}:
      Lc.lcl.st.size(st)
    case _:
      0n

def chn.need(ok: Bool, +code: U32, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, code, msg)

# Waiting for a stage line, or a plan on the box ----------------------------------------------------
#
# fp-chain.sh's wait_for: the condition, then the deadline (WAIT after the
# start), then WAIT_POLL's sleep, again.

type ChnW is Data:
  ChnW{until: Nat, got: Maybe<&2, List<&2, U32>>, more: Bool}

def chn.wait.after(found: Bool, late: Bool, +c: ChnCfg, +u: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(ChnW):
  match found late:
    case True{} _:
      IO.pure(ChnW, ChnW{u, m, False{}})
    case False{} True{}:
      IO.pure(ChnW, ChnW{u, None{}, False{}})
    case False{} False{}:
      do IO<ChnW>:
        chn.sleep(chn.wpoll(c))
        return ChnW{u, None{}, True{}}

def chn.wait.stage.step(+c: ChnCfg, +k: Nat, +u: Nat) -> IO(ChnW):
  do IO<ChnW>:
    +txt : List<&2, U32> <- S.read(chn.stages(c))
    +now : Nat <- Lc.lcl.now()
    +m : Maybe<&2, List<&2, U32>> = chn.stage.at(txt, k)
    chn.wait.after(Maybe.is_some(&2, List<&2, U32>, m), Nat.is_le(u, now), c, u, m)

def chn.wait.stage.go(fuel: Nat, +c: ChnCfg, +k: Nat, w: ChnW) -> IO(Maybe<&2, List<&2, U32>>):
  match fuel w:
    case _ ChnW{u, g, False{}}:
      IO.pure(Maybe<&2, List<&2, U32>>, g)
    case 0n ChnW{u, g, True{}}:
      IO.pure(Maybe<&2, List<&2, U32>>, None{})
    case 1n+f ChnW{+u, g, True{}}:
      IO.bind(ChnW, Maybe<&2, List<&2, U32>>, chn.wait.stage.step(c, k, u), chn.wait.stage.go(f, c, k))

# the k-th stage line once it is there, None after WAIT
def chn.wait.stage(+c: ChnCfg, +k: Nat) -> IO(Maybe<&2, List<&2, U32>>):
  do IO<Maybe<&2, List<&2, U32>>>:
    +now : Nat <- Lc.lcl.now()
    chn.wait.stage.go(U32.to_nat(4000000000), c, k, ChnW{Nat.add(now, chn.wait(c)), None{}, True{}})

def chn.wait.plan.step(+c: ChnCfg, +plan: String, +u: Nat) -> IO(ChnW):
  do IO<ChnW>:
    s : Rm.RmtStat <- Rm.rmt.stat(chn.box(c), chn.at(c, plan))
    +now : Nat <- Lc.lcl.now()
    chn.wait.after(chn.yes(s), Nat.is_le(u, now), c, u, Some{Nil{}})

def chn.wait.plan.go(fuel: Nat, +c: ChnCfg, +plan: String, w: ChnW) -> IO(Bool):
  match fuel w:
    case _ ChnW{u, g, False{}}:
      IO.pure(Bool, Maybe.is_some(&2, List<&2, U32>, g))
    case 0n ChnW{u, g, True{}}:
      IO.pure(Bool, False{})
    case 1n+f ChnW{+u, g, True{}}:
      IO.bind(ChnW, Bool, chn.wait.plan.step(c, plan, u), chn.wait.plan.go(f, c, plan))

# PLAN on the box within WAIT (a box that does not answer is "not yet")
def chn.wait.plan(+c: ChnCfg, +plan: String) -> IO(Bool):
  do IO<Bool>:
    +now : Nat <- Lc.lcl.now()
    chn.wait.plan.go(U32.to_nat(4000000000), c, plan, ChnW{Nat.add(now, chn.wait(c)), None{}, True{}})

# Following a stage -------------------------------------------------------------------------------------

type ChnF is Data:
  ChnF{ph: ChnPh, fo: ChnFo, done: List<&2, String>}

def chn.follow.seen(v: ChnFv, +c: ChnCfg, +lg: String, +every: Nat, +o: ChnObs, +done: List<&2, String>) -> IO(ChnF):
  match v:
    case ChnFv{ChnNoAnswer{}, fo}:
      do IO<ChnF>:
        chn.log(c, "ssh failed; retrying")
        return ChnF{ChnRunning{}, fo, done}
    case ChnFv{+ph, fo}:
      do IO<ChnF>:
        chn.log(c, chn.progress(lg, ph, o))
        d2 : List<&2, String> <- chn.tend(c, lg, every, done)
        return ChnF{ph, fo, d2}

# one look, every POLL: the log's size, the trainers named BIN, the log's tail
def chn.follow.poll(+c: ChnCfg, +lg: String, +bin: String, +every: Nat, fo: ChnFo, +done: List<&2, String>) -> IO(ChnF):
  do IO<ChnF>:
    chn.sleep(chn.poll(c))
    s : Rm.RmtStat <- Rm.rmt.stat(chn.box(c), chn.at(c, lg))
    +n : Lc.LclOut <- chn.ssh(c, 120, "pgrep -c -x " ++ Rm.rmt.q(bin))
    +t : Lc.LclOut <- chn.ssh(c, 120, "tail -c 200 -- " ++ Rm.rmt.q(chn.at(c, lg)))
    +o : ChnObs = chn.obs.of(s, n, t)
    chn.follow.seen(chn.follow.next(fo, o, chn.poll(c), chn.dead(c)), c, lg, every, o, done)

def chn.follow.go(fuel: Nat, +c: ChnCfg, +lg: String, +bin: String, +every: Nat, f: ChnF) -> IO(Bool):
  match fuel f:
    case _ ChnF{ChnDone{}, fo, d}:
      IO.pure(Bool, True{})
    case _ ChnF{ChnDied{}, fo, d}:
      IO.pure(Bool, False{})
    case 0n ChnF{p, fo, d}:
      IO.pure(Bool, False{})
    case 1n+k ChnF{p, fo, +d}:
      IO.bind(ChnF, Bool, chn.follow.poll(c, lg, bin, every, fo, d), chn.follow.go(k, c, lg, bin, every))

# follow a stage until its log says done (True) or it died (False)
def chn.follow(+c: ChnCfg, +lg: String, +bin: String, +every: Nat) -> IO(Bool):
  do IO<Bool>:
    +ok : Bool <- chn.follow.go(U32.to_nat(4000000000), c, lg, bin, every, ChnF{ChnRunning{}, ChnFo{"0", 0n}, Nil{}})
    chn.log(c, lg ++ ": " ++ Bool.pick(String, ok, "done", "died"))
    return ok

# Starting a stage -----------------------------------------------------------------------------------------

type ChnSp is Data:
  ChnSpTry{}
  ChnSpOk{}
  ChnSpFail{}

type ChnS is Data:
  ChnS{i: Nat, ph: ChnSp}

# `tail -1` of a text: its last line, with its newline (nothing for no line)
def chn.tail1(+t: List<&2, U32>) -> List<&2, U32>:
  +ls = S.split.lines(t)
  +n = List.length(&2, List<&2, U32>, ls)
  Bool.pick(List<&2, U32>, Nat.is_eq(n, 0n), Nil{}, List.append(&2, U32, Lc.lcl.nth(ls, Nat.sub(n, 1n)), [10]))

def chn.start.cmd(+c: ChnCfg, +prev: String, +s: ChnStage) -> String:
  "env -C " ++ Rm.rmt.q(chn.dir(c)) ++ " " ++ Rm.rmt.q(chn.drv(c)) ++ " again"
    ++ chn.qs(["out/" ++ prev, chn.st.plan(s), chn.st.rdir(s), chn.st.ssz(s), chn.st.name(s)])

def chn.start.after(yes: Bool, +c: ChnCfg, +name: String, +i: Nat) -> IO(ChnS):
  match yes:
    case True{}:
      IO.pure(ChnS, ChnS{i, ChnSpOk{}})
    case False{}:
      do IO<ChnS>:
        chn.log(c, "stage " ++ name ++ ": no log on the box after the start; trying again")
        return ChnS{1n+i, Bool.pick(ChnSp, Nat.is_lt(i, 5n), ChnSpTry{}, ChnSpFail{})}

# one start: the driver's last line into chain.log, START_SETTLE, then is the
# stage's log on the box (asked until the box answers)
def chn.start.step(+c: ChnCfg, +cmd: String, +name: String, +i: Nat) -> IO(ChnS):
  do IO<ChnS>:
    +o : Lc.LclOut <- Rm.rmt.ssh.once(chn.box(c), 600, cmd)
    chn.raw(c, chn.tail1(List.append(&2, U32, Lc.lcl.out(o), Lc.lcl.err(o))))
    chn.sleep(chn.settle0(c))
    yes : Bool <- chn.known(c, name ++ ".log")
    chn.start.after(yes, c, name, i)

def chn.start.go(fuel: Nat, +c: ChnCfg, +cmd: String, +name: String, s: ChnS) -> IO(Bool):
  match fuel s:
    case _ ChnS{i, ChnSpOk{}}:
      IO.pure(Bool, True{})
    case _ ChnS{i, ChnSpFail{}}:
      IO.pure(Bool, False{})
    case 0n ChnS{i, ChnSpTry{}}:
      IO.pure(Bool, False{})
    case 1n+f ChnS{+i, ChnSpTry{}}:
      IO.bind(ChnS, Bool, chn.start.step(c, cmd, name, i), chn.start.go(f, c, cmd, name))

# start a stage once: again only while the box says its log is not there
def chn.start(+c: ChnCfg, +prev: String, +s: ChnStage) -> IO(Bool):
  chn.start.go(10n, c, chn.start.cmd(c, prev, s), chn.st.name(s), ChnS{1n, ChnSpTry{}})

# The stages -----------------------------------------------------------------------------------------------

# the chain so far: the next stage's number, the last save of the stage before
# (its stage's name and EVERY), the stages followed, the lasts to score, the
# last EVERY, and whether to go on
type ChnRun is Data:
  ChnRun{k: Nat, prev: String, pname: String, pevery: Nat, logs: List<&2, ChnLog>, lasts: List<&2, String>, levery: Nat, more: Bool}

def chn.r.stop(r: ChnRun) -> ChnRun:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      ChnRun{k, p, pn, pe, lg, ls, le, False{}}

def chn.r.k(+r: ChnRun) -> Nat:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      k

def chn.r.prev(+r: ChnRun) -> String:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      p

def chn.r.pname(+r: ChnRun) -> String:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      pn

def chn.r.pevery(+r: ChnRun) -> Nat:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      pe

def chn.r.logs(+r: ChnRun) -> List<&2, ChnLog>:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      lg

def chn.r.lasts(+r: ChnRun) -> List<&2, String>:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      ls

def chn.r.levery(+r: ChnRun) -> Nat:
  match r:
    case ChnRun{k, p, pn, pe, lg, ls, le, m}:
      le

# the stop: a line, and the chain goes to the scores
def chn.stop(+c: ChnCfg, r: ChnRun, +msg: String) -> IO(ChnRun):
  do IO<ChnRun>:
    chn.log(c, msg)
    return chn.r.stop(r)

# a stage followed to its end: the next stage starts from its last save
def chn.stage.after(m: Maybe<&2, String>, +c: ChnCfg, +r: ChnRun, +name: String, +e: Nat, +lg: String, +logs: List<&2, ChnLog>, +ok: Bool) -> IO(ChnRun):
  match m:
    case None{}:
      chn.stop(c, ChnRun{chn.r.k(r), chn.r.prev(r), chn.r.pname(r), chn.r.pevery(r), logs, chn.r.lasts(r), chn.r.levery(r), False{}},
        lg ++ ": no save found; the chain stops here")
    case Some{+l}:
      IO.pure(ChnRun, ChnRun{chn.r.k(r), l, name, e, logs, List.append(&2, String, chn.r.lasts(r), Bool.pick(List<&2, String>, Nat.is_eq(e, 0n), Nil{}, [l])), e, ok})

def chn.died(ok: Bool, +c: ChnCfg, +lg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        +t : Nat <- Ck.ck.wall()
        S.add(chn.dest(c) ++ "/DIED", Lc.lcl.mark.line(t, lg ++ ": the trainer died"))
        chn.alert(c, lg ++ ": the trainer died (no trainer, the log still for " ++ Nat.show(chn.dead(c))
          ++ " s); DEST/DIED written, no later stage starts, the chain goes on to the scores, the pulls and the destroy")

def chn.stage.follow(+c: ChnCfg, +r: ChnRun, +s: ChnStage, +e: Nat, +lg: String) -> IO(ChnRun):
  +logs = List.append(&2, ChnLog, chn.r.logs(r), [ChnLog{lg, e}])
  do IO<ChnRun>:
    +ok : Bool <- chn.follow(c, lg, chn.st.bin(s), e)
    chn.died(ok, c, lg)
    m : Maybe<&2, List<&2, Rm.RmtCk>> <- chn.saved(c, lg)
    chn.stage.after(chn.last(chn.cks(m)), c, r, chn.st.name(s), e, lg, logs, ok)

def chn.rawdel.said(ok: Bool, +c: ChnCfg, +prev: String, +name: String) -> IO(Unit):
  match ok:
    case True{}:
      chn.log(c, "deleted out/" ++ prev ++ " on the box (a raw stage's, loaded by " ++ name ++ ")")
    case False{}:
      IO.pure(Unit, Unit{})

# a raw stage's (EVERY 0) last save has been loaded by now: it can go (only
# ever the stage before's own save)
def chn.rawdel(yes: Bool, +c: ChnCfg, +prev: String, +name: String) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        +o : Lc.LclOut <- chn.ssh(c, 120, "rm -f -- " ++ Rm.rmt.q(chn.at(c, "out/" ++ prev)))
        chn.rawdel.said(Lc.lcl.ok(o), c, prev, name)

def chn.stage.launched(ok: Bool, +c: ChnCfg, +r: ChnRun, +s: ChnStage, +e: Nat, +lg: String) -> IO(ChnRun):
  match ok:
    case False{}:
      chn.stop(c, r, "stage " ++ chn.st.name(s) ++ ": could not be started")
    case True{}:
      do IO<ChnRun>:
        chn.sleep(chn.settle(c))
        chn.rawdel(Bool.and(Nat.is_eq(chn.r.pevery(r), 0n), String.starts_with(chn.r.prev(r), chn.r.pname(r) ++ "-step")), c, chn.r.prev(r), chn.st.name(s))
        chn.stage.follow(c, r, s, e, lg)

def chn.stage.launch(+c: ChnCfg, +r: ChnRun, +s: ChnStage, +e: Nat, +lg: String) -> IO(ChnRun):
  do IO<ChnRun>:
    chn.log(c, "stage " ++ chn.st.name(s) ++ ": from out/" ++ chn.r.prev(r) ++ " on " ++ chn.st.plan(s))
    ok : Bool <- chn.start(c, chn.r.prev(r), s)
    chn.stage.launched(ok, c, r, s, e, lg)

def chn.stage.planned(ok: Bool, +c: ChnCfg, +r: ChnRun, +s: ChnStage, +e: Nat, +lg: String) -> IO(ChnRun):
  match ok:
    case True{}:
      chn.stage.launch(c, r, s, e, lg)
    case False{}:
      chn.stop(c, r, "stage " ++ chn.st.name(s) ++ ": " ++ chn.st.plan(s) ++ " never came")

def chn.stage.plan(there: Bool, +c: ChnCfg, +r: ChnRun, +s: ChnStage, +e: Nat, +lg: String) -> IO(ChnRun):
  match there:
    case True{}:
      chn.stage.launch(c, r, s, e, lg)
    case False{}:
      do IO<ChnRun>:
        chn.log(c, "stage " ++ chn.st.name(s) ++ ": waiting up to " ++ Nat.show(chn.wait(c)) ++ " s for " ++ chn.st.plan(s) ++ " on the box")
        ok : Bool <- chn.wait.plan(c, chn.st.plan(s))
        chn.stage.planned(ok, c, r, s, e, lg)

def chn.stage.start(can: Bool, +c: ChnCfg, +r: ChnRun, +s: ChnStage, +e: Nat, +lg: String) -> IO(ChnRun):
  match can:
    case False{}:
      chn.stop(c, r, "stage " ++ chn.st.name(s) ++ ": nothing to start from")
    case True{}:
      do IO<ChnRun>:
        p : Bool <- chn.known(c, chn.st.plan(s))
        chn.stage.plan(p, c, r, s, e, lg)

# its log on the box: follow it; else start the stage
def chn.stage.there(yes: Bool, +c: ChnCfg, +r: ChnRun, +s: ChnStage, +e: Nat, +lg: String) -> IO(ChnRun):
  match yes:
    case True{}:
      chn.stage.follow(c, r, s, e, lg)
    case False{}:
      chn.stage.start(Bool.and(Bool.not(String.is_empty(chn.r.prev(r))), Bool.not(String.is_empty(chn.st.plan(s)))), c, r, s, e, lg)

def chn.stage.every(m: Maybe<&2, Nat>, +c: ChnCfg, +r: ChnRun, +s: ChnStage) -> IO(ChnRun):
  match m:
    case None{}:
      chn.stop(c, r, "stage " ++ chn.st.name(s) ++ ": EVERY " ++ chn.st.every(s) ++ " is not a number; the chain stops here")
    case Some{+e}:
      +lg = chn.log.of(chn.r.k(r), chn.st.name(s), chn.log0(c))
      +r2 = {ChnRun{1n+chn.r.k(r), chn.r.prev(r), chn.r.pname(r), chn.r.pevery(r), chn.r.logs(r), chn.r.lasts(r), chn.r.levery(r), True{}} : ChnRun}
      do IO<ChnRun>:
        yes : Bool <- chn.known(c, lg)
        chn.stage.there(yes, c, r2, s, e, lg)

def chn.stage.got(+c: ChnCfg, +r: ChnRun, +s: ChnStage) -> IO(ChnRun):
  chn.stage.every(Lc.lcl.nat(S.b(chn.st.every(s))), c, r, s)

def chn.stage.waited(m: Maybe<&2, List<&2, U32>>, +c: ChnCfg, +r: ChnRun) -> IO(ChnRun):
  match m:
    case Some{+l}:
      chn.stage.got(c, r, chn.stage.of(l))
    case None{}:
      chn.stop(c, r, "no more stages")

def chn.stage.have(m: Maybe<&2, List<&2, U32>>, +c: ChnCfg, +r: ChnRun) -> IO(ChnRun):
  match m:
    case Some{+l}:
      chn.stage.got(c, r, chn.stage.of(l))
    case None{}:
      do IO<ChnRun>:
        chn.log(c, "no stage " ++ Nat.show(chn.r.k(r)) ++ " yet; waiting up to " ++ Nat.show(chn.wait(c)) ++ " s for one to be appended to " ++ chn.stages(c))
        m2 : Maybe<&2, List<&2, U32>> <- chn.wait.stage(c, chn.r.k(r))
        chn.stage.waited(m2, c, r)

# one stage: read STAGES afresh (a stage appended while the chain runs is taken up)
def chn.stage.step(+c: ChnCfg, +r: ChnRun) -> IO(ChnRun):
  do IO<ChnRun>:
    txt : List<&2, U32> <- S.read(chn.stages(c))
    chn.stage.have(chn.stage.at(txt, chn.r.k(r)), c, r)

def chn.stages.go(fuel: Nat, +c: ChnCfg, r: ChnRun) -> IO(ChnRun):
  match fuel r:
    case _ ChnRun{k, p, pn, pe, lg, ls, le, False{}}:
      IO.pure(ChnRun, ChnRun{k, p, pn, pe, lg, ls, le, False{}})
    case 0n ChnRun{k, p, pn, pe, lg, ls, le, True{}}:
      IO.pure(ChnRun, ChnRun{k, p, pn, pe, lg, ls, le, False{}})
    case 1n+f ChnRun{k, p, pn, pe, lg, ls, le, True{}}:
      IO.bind(ChnRun, ChnRun, chn.stage.step(c, ChnRun{k, p, pn, pe, lg, ls, le, True{}}), chn.stages.go(f, c))

# The scores --------------------------------------------------------------------------------------------------

def chn.saves(+c: ChnCfg, ls: List<&2, ChnLog>) -> IO(List<&2, ChnSaves>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, ChnSaves>, Nil{})
    case ChnLog{+lg, +e} <> t:
      do IO<List<&2, ChnSaves>>:
        m : Maybe<&2, List<&2, Rm.RmtCk>> <- Bool.pick(IO(Maybe<&2, List<&2, Rm.RmtCk>>), Nat.is_eq(e, 0n),
          IO.pure(Maybe<&2, List<&2, Rm.RmtCk>>, None{}), chn.saved(c, lg))
        +rest : List<&2, ChnSaves> <- chn.saves(c, t)
        return Bool.pick(List<&2, ChnSaves>, Nat.is_eq(e, 0n), rest, ChnSaves{e, chn.cks(m)} <> rest)

def chn.eval.next(there: Bool, +c: ChnCfg, +words: List<&2, String>) -> IO(Unit):
  match there:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        o : Lc.LclOut <- chn.ssh(c, 172800, "env -C " ++ Rm.rmt.q(chn.dir(c)) ++ " ECORPUS=run/eval/transcript-next.corpus " ++ Rm.rmt.q(chn.drv(c)) ++ " eval"
          ++ chn.qs(words) ++ " > " ++ Rm.rmt.q(chn.at(c, "eval-next.log")) ++ " 2>&1")
        return Unit{}

# fp.sh: both scores on the box, while the chain waits (fp-chain.sh's)
def chn.eval.fp(+c: ChnCfg, +words: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    o : Lc.LclOut <- chn.ssh(c, 172800, "env -C " ++ Rm.rmt.q(chn.dir(c)) ++ " " ++ Rm.rmt.q(chn.drv(c)) ++ " eval" ++ chn.qs(words)
      ++ " > " ++ Rm.rmt.q(chn.at(c, "eval.log")) ++ " 2>&1")
    +t : Lc.LclOut <- chn.ssh(c, 120, "test -f " ++ Rm.rmt.q(chn.at(c, "run/eval/transcript-next.corpus")))
    chn.eval.next(Lc.lcl.ok(t), c, words)

def chn.eval.both(+c: ChnCfg, +words: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    o : Lc.LclOut <- chn.ssh(c, 600, "env -C " ++ Rm.rmt.q(chn.dir(c)) ++ " " ++ Rm.rmt.q(chn.drv(c)) ++ " eval-both" ++ chn.qs(words))
    return Unit{}

# a restarted chain whose detached eval was started: its eval.done there,
# nothing to start; else `eval-both` again, which says the job still runs
# (eval.pid) or, the job gone (the box rebooted), starts it again
def chn.eval.resume(done: Bool, +c: ChnCfg, +words: List<&2, String>) -> IO(Unit):
  match done:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      chn.eval.both(c, words)

def chn.eval.begin(fp: Bool, started: Bool, +c: ChnCfg, +words: List<&2, String>, +key: List<&2, U32>) -> IO(Unit):
  match fp started:
    case True{} _:
      do IO<Unit>:
        S.write(chn.dest(c) ++ "/chain.eval", key)
        chn.eval.fp(c, words)
    case False{} True{}:
      do IO<Unit>:
        d : Bool <- chn.known(c, "eval.done")
        chn.eval.resume(d, c, words)
    case False{} False{}:
      do IO<Unit>:
        S.write(chn.dest(c) ++ "/chain.eval", key)
        r : Lc.LclOut <- chn.ssh(c, 120, "rm -f -- " ++ Rm.rmt.q(chn.at(c, "eval.done")))
        chn.eval.both(c, words)

# bend-box: the detached eval's eval.done, polled every POLL; no new output in
# eval.log and eval-next.log for EVAL_QUIET seconds and the chain goes on
type ChnE is Data:
  ChnE{size: Nat, quiet: Nat, more: Bool}

def chn.eval.quiet(late: Bool, +c: ChnCfg, +sz: Nat, +q: Nat) -> IO(ChnE):
  match late:
    case False{}:
      IO.pure(ChnE, ChnE{sz, q, True{}})
    case True{}:
      do IO<ChnE>:
        chn.log(c, "eval: no eval.done and no new output for " ++ Nat.show(q) ++ " s; going on without it")
        return ChnE{sz, q, False{}}

def chn.eval.seen(done: Bool, answered: Bool, +c: ChnCfg, +sz: Nat, +size: Nat, +quiet: Nat) -> IO(ChnE):
  match done answered:
    case True{} _:
      IO.pure(ChnE, ChnE{sz, 0n, False{}})
    case False{} False{}:
      IO.pure(ChnE, ChnE{size, quiet, True{}})
    case False{} True{}:
      +q = Bool.pick(Nat, Nat.is_eq(sz, size), Nat.add(quiet, chn.poll(c)), 0n)
      chn.eval.quiet(Nat.is_le(chn.equiet(c), q), c, sz, q)

def chn.eval.step(+c: ChnCfg, +size: Nat, +quiet: Nat) -> IO(ChnE):
  do IO<ChnE>:
    chn.sleep(chn.poll(c))
    +d : Rm.RmtStat <- Rm.rmt.stat(chn.box(c), chn.at(c, "eval.done"))
    a : Rm.RmtStat <- Rm.rmt.stat(chn.box(c), chn.at(c, "eval.log"))
    b : Rm.RmtStat <- Rm.rmt.stat(chn.box(c), chn.at(c, "eval-next.log"))
    chn.eval.seen(chn.yes(d), chn.answered(d), c, Nat.add(chn.size(a), chn.size(b)), size, quiet)

def chn.eval.go(fuel: Nat, +c: ChnCfg, e: ChnE) -> IO(Unit):
  match fuel e:
    case _ ChnE{s, q, False{}}:
      IO.pure(Unit, Unit{})
    case 0n ChnE{s, q, True{}}:
      IO.pure(Unit, Unit{})
    case 1n+f ChnE{+s, +q, True{}}:
      IO.bind(ChnE, Unit, chn.eval.step(c, s, q), chn.eval.go(f, c))

def chn.eval.wait(fp: Bool, +c: ChnCfg) -> IO(Unit):
  match fp:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      chn.eval.go(U32.to_nat(4000000000), c, ChnE{0n, 0n, True{}})

def chn.eval.grep(+c: ChnCfg, +f: String) -> IO(Lc.LclOut):
  chn.ssh(c, 300, "grep -E " ++ Rm.rmt.q("^==|bits_per_byte") ++ " -- " ++ Rm.rmt.q(chn.at(c, f)))

# the scores' lines into chain.log, as fp-chain.sh's `| tee -a` put them: the
# `==` and bits_per_byte lines of eval.log, `next:`, those of eval-next.log
def chn.eval.collect(+c: ChnCfg) -> IO(Unit):
  do IO<Unit>:
    +a : Lc.LclOut <- chn.eval.grep(c, "eval.log")
    +b : Lc.LclOut <- chn.eval.grep(c, "eval-next.log")
    chn.raw(c, Bool.pick(List<&2, U32>, U32.is_eq(Lc.lcl.status(a), 255), Nil{},
      List.concat(&2, U32, [Lc.lcl.out(a), S.b("next:\n"), Lc.lcl.out(b)])))

def chn.eval.at(logged: Bool, started: Bool, +c: ChnCfg, +words: List<&2, String>, +key: List<&2, U32>) -> IO(Unit):
  match logged:
    case True{}:
      chn.log(c, "eval: scored before a restart (DEST/chain.eval says so); not again")
    case False{}:
      do IO<Unit>:
        chn.eval.begin(chn.fp(chn.drv(c)), started, c, words, key)
        chn.eval.wait(chn.fp(chn.drv(c)), c)
        chn.eval.collect(c)
        S.add(chn.dest(c) ++ "/chain.eval", S.b("logged\n"))

# the scores: DEST/chain.eval holds the words of a started eval (and `logged`
# once its lines are in chain.log), so a restarted chain neither starts a
# detached eval twice nor logs it twice
def chn.eval(+c: ChnCfg, +words: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +st : List<&2, U32> <- S.read(chn.dest(c) ++ "/chain.eval")
    +key : List<&2, U32> = S.b(String.join(words, " ") ++ "\n")
    chn.eval.at(S.eq(st, List.append(&2, U32, key, S.b("logged\n"))), S.eq(st, key), c, words, key)

# Verify ----------------------------------------------------------------------------------------------------

def chn.sums(+rs: Rm.RmtSums) -> List<&2, Lc.LclSum>:
  match rs:
    case Rm.RmtSums{a, ss}:
      ss

def chn.box1(+b: Rm.RmtBox) -> Rm.RmtBox:
  match b:
    case Rm.RmtBox{h, p, o, t, w, rt, rw}:
      Rm.RmtBox{h, p, o, t, w, 1n, rw}

def chn.ckpts(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +rest = chn.ckpts(t)
      Bool.pick(List<&2, List<&2, U32>>, S.suffix(x, S.b(".checkpoint")), x <> rest, rest)

# those of WANT here, whole, and in the local listing
def chn.haves(+c: ChnCfg, fs: List<&2, String>, +here: List<&2, Lc.LclSum>) -> IO(List<&2, String>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +f <> t:
      do IO<List<&2, String>>:
        h : Bool <- chn.have(c, f)
        +rest : List<&2, String> <- chn.haves(c, t, here)
        return Bool.pick(List<&2, String>, Bool.and(h, Maybe.is_some(&2, List<&2, U32>, Lc.lcl.sha.of(here, S.b(f)))), f <> rest, rest)

# one verify: the box's logs and text files pulled (once), the box's sha256s
# (sha256.box.txt) against those here (sha256.txt), and the wanted ones here
def chn.verify.once(+c: ChnCfg, +want: List<&2, String>) -> IO(ChnVer):
  do IO<ChnVer>:
    ok : Bool <- Rm.rmt.pull(chn.box1(chn.box(c)), chn.dir(c) ++ "/", chn.dest(c), ["--include=*.log*", "--include=*.txt", "--exclude=*"])
    rs : Rm.RmtSums <- Rm.rmt.sums(chn.box(c), chn.at(c, "out/*.checkpoint"))
    +box : List<&2, Lc.LclSum> = chn.sums(rs)
    S.write(chn.dest(c) ++ "/sha256.box.txt", Lc.lcl.sha.text(box))
    ls : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(chn.out(c))
    +here : List<&2, Lc.LclSum> <- Lc.lcl.sums(chn.out(c), chn.ckpts(Maybe.default(&2, List<&2, List<&2, U32>>, ls, Nil{})))
    S.write(chn.dest(c) ++ "/sha256.txt", Lc.lcl.sha.text(here))
    have : List<&2, String> <- chn.haves(c, want, here)
    return chn.verify.of(box, here, want, have)

type ChnVr is Data:
  ChnVr{tries: Nat, nx: ChnNext, v: ChnVer}

def chn.alert.if(yes: Bool, +c: ChnCfg, +msg: String) -> IO(Unit):
  match yes:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      chn.alert(c, msg)

def chn.verify.then(n: ChnNext, +c: ChnCfg, +v: ChnVer, +tries: Nat) -> IO(ChnVr):
  match n:
    case ChnPass{}:
      IO.pure(ChnVr, ChnVr{tries, ChnPass{}, v})
    case ChnRefuse{}:
      IO.pure(ChnVr, ChnVr{tries, ChnRefuse{}, v})
    case ChnAgain{}:
      +why = chn.ver.why(v)
      do IO<ChnVr>:
        chn.alert.if(Nat.is_eq(tries, 1n), c, "the box is not destroyed yet:" ++ why ++ " trying again every " ++ Nat.show(Nat.div(chn.vwait(c), 60n)) ++ " min, 12 times")
        chn.log(c, "verify, try " ++ Nat.show(tries) ++ ":" ++ why ++ " again in " ++ Nat.show(chn.vwait(c)) ++ " s")
        chn.sleep(chn.vwait(c))
        chn.pull.checksum(c, chn.ver.unmatched(v))
        return ChnVr{1n+tries, ChnAgain{}, v}

def chn.verify.step(+c: ChnCfg, +want: List<&2, String>, +tries: Nat) -> IO(ChnVr):
  do IO<ChnVr>:
    +v : ChnVer <- chn.verify.once(c, want)
    chn.verify.then(chn.verify.next(v, tries), c, v, tries)

def chn.verify.go(fuel: Nat, +c: ChnCfg, +want: List<&2, String>, r: ChnVr) -> IO(ChnVr):
  match fuel r:
    case _ ChnVr{t, ChnPass{}, v}:
      IO.pure(ChnVr, ChnVr{t, ChnPass{}, v})
    case _ ChnVr{t, ChnRefuse{}, v}:
      IO.pure(ChnVr, ChnVr{t, ChnRefuse{}, v})
    case 0n ChnVr{t, ChnAgain{}, v}:
      IO.pure(ChnVr, ChnVr{t, ChnRefuse{}, v})
    case 1n+f ChnVr{+t, ChnAgain{}, v}:
      IO.bind(ChnVr, ChnVr, chn.verify.step(c, want, t), chn.verify.go(f, c, want))

# HOLD, CONTINUED, the destroy --------------------------------------------------------------------------------

type ChnHs is Data:
  ChnHs{h: ChnHold}

def chn.hold.sleep(+h: ChnHold, +c: ChnCfg) -> IO(Unit):
  match h:
    case ChnHoldWait{}:
      chn.sleep(chn.hpoll(c))
    case _:
      IO.pure(Unit, Unit{})

def chn.hold.step(+c: ChnCfg) -> IO(ChnHs):
  do IO<ChnHs>:
    xs : List<&2, U32> <- S.read(chn.dest(c) ++ "/HOLD")
    cont : Bool <- S.exists(chn.dest(c) ++ "/CONTINUED")
    +now : Nat <- Lc.lcl.now()
    +h : ChnHold = chn.hold.of(now, Lc.lcl.epoch.of(xs), cont)
    chn.hold.sleep(h, c)
    return ChnHs{h}

# wait while DEST/HOLD's deadline is ahead; True when DEST/CONTINUED is there
def chn.hold.go(fuel: Nat, +c: ChnCfg, s: ChnHs) -> IO(Bool):
  match fuel s:
    case _ ChnHs{ChnHoldGo{}}:
      IO.pure(Bool, False{})
    case _ ChnHs{ChnHoldTaken{}}:
      IO.pure(Bool, True{})
    case 0n ChnHs{ChnHoldWait{}}:
      IO.pure(Bool, False{})
    case 1n+f ChnHs{ChnHoldWait{}}:
      IO.bind(ChnHs, Bool, chn.hold.step(c), chn.hold.go(f, c))

type ChnL is Data:
  ChnL{l: Vs.VstLs}

def chn.listed.step(+c: ChnCfg, +w: String) -> IO(ChnL):
  do IO<ChnL>:
    chn.log(c, "the listing did not read (" ++ w ++ "); asking again in " ++ Nat.show(chn.lwait(c)) ++ " s")
    chn.sleep(chn.lwait(c))
    l : Vs.VstLs <- Vs.vst.listed(chn.v(c), chn.inst(c))
    return ChnL{l}

def chn.listed.go(fuel: Nat, +c: ChnCfg, s: ChnL) -> IO(Vs.VstLs):
  match fuel s:
    case _ ChnL{Vs.VstLsYes{}}:
      IO.pure(Vs.VstLs, Vs.VstLsYes{})
    case _ ChnL{Vs.VstLsNo{}}:
      IO.pure(Vs.VstLs, Vs.VstLsNo{})
    case 0n ChnL{Vs.VstLsUnknown{w}}:
      IO.pure(Vs.VstLs, Vs.VstLsUnknown{w})
    case 1n+f ChnL{Vs.VstLsUnknown{+w}}:
      IO.bind(ChnL, Vs.VstLs, chn.listed.step(c, w), chn.listed.go(f, c))

# is the instance listed: a listing that does not read is asked again,
# LIST_TRIES in all (Unknown after that: never "not listed")
def chn.listed(+c: ChnCfg) -> IO(Vs.VstLs):
  do IO<Vs.VstLs>:
    l : Vs.VstLs <- Vs.vst.listed(chn.v(c), chn.inst(c))
    chn.listed.go(Nat.sub(chn.ltries(c), 1n), c, ChnL{l})

def chn.refused(+c: ChnCfg, +why: String, +msg: String) -> IO(Unit):
  do IO<Unit>:
    Lc.lcl.mark(chn.dest(c) ++ "/REFUSED", why)
    chn.alert(c, msg)
    IO.die(Unit, 1, "chain: " ++ msg)

# DESTROYED only on a listing that reads and no longer shows the instance
def chn.destroyed(l: Vs.VstLs, +c: ChnCfg) -> IO(Unit):
  match l:
    case Vs.VstLsNo{}:
      do IO<Unit>:
        Lc.lcl.mark(chn.dest(c) ++ "/DESTROYED", "instance " ++ chn.inst(c) ++ " destroyed")
        chn.log(c, "finished")
    case Vs.VstLsYes{}:
      chn.refused(c, " the destroy did not take", "instance " ++ chn.inst(c) ++ " still listed after destroy")
    case Vs.VstLsUnknown{+w}:
      chn.refused(c, " the listing failed after the destroy: " ++ w,
        "instance " ++ chn.inst(c) ++ ": no listing that reads after the destroy (" ++ w ++ "); not taken as destroyed")

def chn.destroy(+c: ChnCfg) -> IO(Unit):
  do IO<Unit>:
    chn.log(c, "destroy instance " ++ chn.inst(c))
    +o : Lc.LclOut <- Vs.vst.destroy(chn.v(c), chn.inst(c))
    chn.raw(c, List.append(&2, U32, Lc.lcl.out(o), Lc.lcl.err(o)))
    chn.sleep(chn.dwait(c))
    l : Vs.VstLs <- chn.listed(c)
    chn.destroyed(l, c)

def chn.taken(yes: Bool, +c: ChnCfg) -> IO(Unit):
  match yes:
    case True{}:
      chn.log(c, "someone took the box over; not destroying it")
    case False{}:
      chn.destroy(c)

def chn.verified(r: ChnVr, +c: ChnCfg, +nwant: Nat) -> IO(Unit):
  match r:
    case ChnVr{t, ChnPass{}, +v}:
      do IO<Unit>:
        chn.log(c, "pulled: " ++ Nat.show(chn.ver.remote(v)) ++ " checkpoints on the box, each matching its copy here; none of the "
          ++ Nat.show(nwant) ++ " wanted missing")
        taken : Bool <- chn.hold.go(U32.to_nat(4000000000), c, ChnHs{ChnHoldWait{}})
        chn.taken(taken, c)
    case ChnVr{t, nx, +v}:
      +why = chn.ver.why(v)
      chn.refused(c, why, "the box is NOT destroyed:" ++ why ++ " DEST/REFUSED written")

def chn.pull.logs(+c: ChnCfg, ls: List<&2, ChnLog>) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case ChnLog{+lg, +e} <> t:
      do IO<Unit>:
        chn.pull.new(c, lg, e)
        chn.pull.logs(c, t)

# after the stages: scores, pulls, verify, HOLD, destroy
def chn.finish(+c: ChnCfg, r: ChnRun) -> IO(Unit):
  match r:
    case ChnRun{k, +prev, pn, pe, +logs, +lasts0, +le, m}:
      +lasts = List.append(&2, String, lasts0, Bool.pick(List<&2, String>, Bool.and(Bool.not(String.is_empty(prev)), Nat.is_eq(le, 0n)), [prev], Nil{}))
      do IO<Unit>:
        +ss : List<&2, ChnSaves> <- chn.saves(c, logs)
        +ev : String = chn.evals(chn.extra(c), ss, lasts)
        chn.log(c, "eval:" ++ ev)
        chn.eval(c, chn.words(ev))
        chn.pull.logs(c, logs)
        chn.pull.each(c, lasts)
        ss2 : List<&2, ChnSaves> <- chn.saves(c, logs)
        +want : List<&2, String> = chn.want(ss2, lasts)
        v : ChnVr <- chn.verify.go(12n, c, want, ChnVr{1n, ChnAgain{}, ChnVer{0n, Nil{}, Nil{}}})
        chn.verified(v, c, List.length(&2, String, want))

# The command ------------------------------------------------------------------------------------------------

def chn.begin(gone: Bool, +c: ChnCfg) -> IO(Unit):
  match gone:
    case True{}:
      IO.print_err("chain: " ++ chn.dest(c) ++ "/DESTROYED is there: instance " ++ chn.inst(c) ++ " was destroyed; nothing to do")
    case False{}:
      do IO<Unit>:
        S.mkdir(chn.out(c))
        S.write(chn.dest(c) ++ "/INSTANCE", S.b(chn.inst(c) ++ "\n"))
        S.rm(chn.dest(c) ++ "/REFUSED")
        r : ChnRun <- chn.stages.go(U32.to_nat(100000), c, ChnRun{1n, "", "", 1n, Nil{}, Nil{}, 1n, True{}})
        chn.finish(c, r)

def chn.usage() -> String:
  "usage: bend-ops chain HOST PORT INSTANCE DEST STAGES   (STAGES: NAME BINARY EVERY [PLAN RUN_DIR SHARD_SIZE] a line)"

def chn.run(+host: String, +port: String, +inst: String, +dest: String, +stages: String) -> IO(Unit):
  do IO<Unit>:
    b : Rm.RmtBox <- Rm.rmt.box(host, port)
    v : String <- Vs.vst.bin()
    dir : String <- S.env("BOX_DIR", "formalTransformer")
    +drv : String <- S.env("BOX_DRIVER", "./bend-box")
    log0 : String <- S.env("LOG0", "train.log")
    extra : String <- S.env("EXTRA_EVAL", "")
    ts : List<&2, Nat> <- chn.envs(chn.t.names(), chn.t.defaults())
    +c : ChnCfg = ChnCfg{b, inst, dest, stages, dir, drv, v, log0, extra, ts}
    chn.need(chn.drv.ok(drv), 2, "chain: BOX_DRIVER is ./bend-box or ./fp.sh, not " ++ drv)
    gone : Bool <- S.exists(dest ++ "/DESTROYED")
    chn.begin(gone, c)

def chn.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +host <> +port <> +inst <> +dest <> +stages <> Nil{}:
      chn.run(host, port, inst, dest, stages)
    case _:
      IO.die(Unit, 2, chn.usage())
