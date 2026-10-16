import Base
import ../Sys.bend as S
import ../Train/Opt.bend as O
import ./Steps.bend as St
import ./Combine.bend as Cb
import ./Keyed.bend as K

# s2: a run's second stage, built where S1 stops (2026-10-15, the plan "all
# logic in Bend", Phase 4: tools/corpus-v2/s2.sh made generic).
#
#   bend-corpus-v2 s2 S1_DIR BOUNDARY OUT ACT_DIR...
#
# OUT is the plan S2 trains on, from step BOUNDARY of S1's plan:
#   - the steady plan's segments from BOUNDARY on (OUT.rest: its segment lines,
#     and a link to each shard's file);
#   - interleaved with the act rounds' episodes: ana's own solved ones
#     (ACT_DIR/accepted/LANG-act) and its rejected Terms with the unit's fix
#     (LANG-fix), as transcript windows of SHARD episodes a shard, each
#     language PER = max(1, (n + 50) / 100) a round (OUT.ep: OUT.ep/tx/LANG-KIND
#     and OUT.ep/w, bend-plan-windows' output).  The episode windows' gaps take
#     filler from FILLER (a slice of format 2's filler, the held-out files left
#     out), its files-hi.nul in keyed order (sha256 of "s2 filler" NUL id; s2.sh
#     shuffled with `shuf --random-source=<(yes 2026)`, a change the user
#     accepted): bend-plan-windows gives each shard the next FILL files in
#     order, and the filler's own order put shards of short files together
#     (2026-10-13, shards 24, 25, 28 of 37 found no file long enough);
#   - combined (`combine SHARE OUT OUT.rest OUT.ep/w`, in this process) at
#     SHARE = int(s 10^4 + 0.9999) / 10^4, s = episode windows / all windows,
#     in exact doubles (St's StF): the digits awk's printf "%.4f" gave;
#   - OUT/stage.env: NLR, the lr S1's schedule reaches at BOUNDARY (lr.at of
#     Train/Opt.bend in F32 from LR, WARM and the plan's steps, printed as the
#     trainer prints lr=), and NWARM=10.
# The last stdout line is the stage line to append to the chain's STAGES,
# its paths relative to TRAINER_DIR (the chain looks for a stage's plan
# under its trainer's directory):
#   s2 traind-next EVERY REL/plan-fp100m-b16-windows.tsv REL fp100m
#
# NLR is checked against S1's own log (S1_LOG, else TRAINER_DIR/train.log
# when it is there): the last `lr=` it shows must be NLR's text, or s2 stops
# before any work (s2.sh only printed both).  BOUNDARY must start a segment
# of S1's plan.  Settings (run 3's): DEPLOY (run/v2/gcroot-deploy-agent/bin/deploy:
# bend-plan-windows), FILLER (run/v3/s2fill), TRANSCRIPTS (run/v2/transcripts:
# the held-out files each episode language links), LR (3e-4), WARM (300),
# EVERY (5000), SHARD (250), JOBS (8), TRAINER_DIR ($HOME/formalTransformer),
# S1_LOG.  Run from the act workspace (the repository).  Logs go to stderr,
# stamped UTC-6.  Every def is prefixed `s2s.`.
#
# Run 4's (2026-10-15), both unset by default (then all is as above):
#   - REST_STEPS N: the rest is only its leading segments whose steps ($8 of
#     each segment line) sum to at most N (s2s.cap); the share, the log
#     lines and OUT.rest are the capped rest's; a cap that holds no segment
#     stops s2 before any work;
#   - CTL_OUT DIR: also DIR, the control stage's plan: the same (capped) rest
#     alone, no episodes (`combine 0 DIR OUT.rest`), with OUT's stage.env.
# An ACT_DIR named more than once (2026-10-16; run 4's s2-acts named
# run/v4/act/r1 twice, the round's episodes twice) gives its episodes again:
# its first naming's pairs as they are, its k-th's (k >= 2) with `/eK` after
# every id (`/e2`, `/e3`, ...), and a log line `s2: LANG-KIND: ACT_DIR again
# as /eK (N episodes)` (s2s.gather).  Before, the same ids went in twice and
# bend-plan-windows' mix refused them ("duplicate ids across sources": C2's
# s2 at 06:28; r1e2 was made by hand).  Directories compare as the strings
# given (r1 and ./r1 are two); one named once is copied byte for byte.
# A hot-started S1 (bend-box again, TRAIN_NEXT) logs global steps, but its
# plan's segment starts and its lr schedule count from the plan's own step 0
# (the trainer's lr is lr.at(NLR, step - base, NWARM, total - base), base the
# checkpoint's step and total base plus the plan's steps): BOUNDARY is
# plan-relative, and NLR = lr.at(LR, BOUNDARY, WARM, the plan's steps) is the
# lr= its log shows at global step base + BOUNDARY when LR and WARM are the
# NLR and NWARM it was started with.

# The plans (pure) ----------------------------------------------------------------------------

def s2s.lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  S.split.lines(xs)

def s2s.is.seg(+ws: List<&2, List<&2, U32>>) -> Bool:
  S.eq(K.kor.field(ws, 0n), S.b("segment"))

# a segment line's START ($9), None for any other line
def s2s.start(+l: List<&2, U32>) -> Maybe<&2, Nat>:
  +ws = K.kor.words(l)
  +f = K.kor.field(ws, 8n)
  Bool.pick(Maybe<&2, Nat>, Bool.and(s2s.is.seg(ws), Nat.is_lt(0n, S.len(f))), Nat.read(S.str(f)), None{})

def s2s.at.is(m: Maybe<&2, Nat>, +b: Nat) -> Bool:
  match m:
    case Some{+s}:
      Nat.is_eq(s, b)
    case None{}:
      False{}

def s2s.from.is(m: Maybe<&2, Nat>, +b: Nat) -> Bool:
  match m:
    case Some{+s}:
      Nat.is_le(b, s)
    case None{}:
      False{}

# does a segment start at step b (`$1 == "segment" && $9 == b`)
def s2s.starts(ls: List<&2, List<&2, U32>>, +b: Nat) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(s2s.at.is(s2s.start(l), b), s2s.starts(t, b))

# the segment lines from step b on (`$1 == "segment" && $9 >= b`)
def s2s.rest(ls: List<&2, List<&2, U32>>, +b: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = s2s.rest(t, b)
      Bool.pick(List<&2, List<&2, U32>>, s2s.from.is(s2s.start(l), b), l <> r, r)

# the sum of $6 over the lines (segment lines only when seg)
def s2s.tw(ls: List<&2, List<&2, U32>>, +seg: Bool) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      +ws = K.kor.words(l)
      Nat.add(Bool.pick(Nat, Bool.or(Bool.not(seg), s2s.is.seg(ws)), K.kor.nat(K.kor.field(ws, 5n)), 0n), s2s.tw(t, seg))

# the shards' numbers ($2)
def s2s.ks(ls: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      S.str(K.kor.field(K.kor.words(l), 1n)) <> s2s.ks(t)

# the plan line's field 3 (its steps)
def s2s.steps(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      K.kor.nat(K.kor.field(K.kor.words(l), 2n))

def s2s.unlines(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, U32, l, 10 <> s2s.unlines(t))

# REST_STEPS (2026-10-15, run 4): the rest capped.  A segment line's steps are
# its own STEPS field ($8: its training windows / 16, rounded up, as combine
# and bend-plan-segment count them); the cap keeps the rest's leading
# segments while their steps sum to at most N, so the rest never runs past
# N steps, and drops the others (they stay unused for a later run).

def s2s.seg.steps(+l: List<&2, U32>) -> Nat:
  K.kor.nat(K.kor.field(K.kor.words(l), 7n))

# the sum of $8 over the lines
def s2s.steps.of(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      Nat.add(s2s.seg.steps(l), s2s.steps.of(t))

# does the first line's steps fit in n
def s2s.cap.fits(+ls: List<&2, List<&2, U32>>, +n: Nat) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Nat.is_le(s2s.seg.steps(l), n)

def s2s.cap.go(ls: List<&2, List<&2, U32>>, +n: Nat, fits: Bool) -> List<&2, List<&2, U32>>:
  match ls fits:
    case +l <> +t True{}:
      +left = Nat.sub(n, s2s.seg.steps(l))
      l <> s2s.cap.go(t, left, s2s.cap.fits(t, left))
    case _ _:
      Nil{}

# the leading lines whose steps sum to at most n
def s2s.cap(+ls: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, List<&2, U32>>:
  s2s.cap.go(ls, n, s2s.cap.fits(ls, n))

# REST_STEPS's text: unset or empty is no cap (None)
type S2Cap is Data:
  S2NoCap{}
  S2CapAt{n: Nat}
  S2CapBad{text: String}

def s2s.cap.read(m: Maybe<&2, Nat>, +v: String) -> S2Cap:
  match m:
    case Some{n}:
      S2CapAt{n}
    case None{}:
      S2CapBad{v}

def s2s.cap.of(+v: String) -> S2Cap:
  Bool.pick(S2Cap, String.is_empty(v), S2NoCap{}, s2s.cap.read(Nat.read(v), v))

# the rest as S2 takes it: all of it, or capped
def s2s.capped(+cap: S2Cap, +ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match cap:
    case S2CapAt{+n}:
      s2s.cap(ls, n)
    case _:
      ls

# Numbers (pure) -------------------------------------------------------------------------------

def s2s.per(+n: Nat) -> Nat:
  Nat.max(1n, Nat.div(Nat.add(n, 50n), 100n))

def s2s.f.or(m: Maybe<&2, St.StF>) -> St.StF:
  match m:
    case Some{x}:
      x
    case None{}:
      St.st.f.zero()

# awk's `s = r / (t + r); printf "%.4f", int(s * 10000 + 0.9999) / 10000`,
# each operation a double rounded to nearest
def s2s.share(+ew: Nat, +rw: Nat) -> String:
  +s = St.st.f.ratio(ew, Nat.add(rw, ew))
  +x = St.st.f.add(St.st.f.mul(s, St.st.f.of.nat(10000n)), s2s.f.or(St.st.f.read(S.b("0.9999"))))
  St.st.f.fixed(St.st.f.div(St.st.f.floor(x), St.st.f.of.nat(10000n)), 4n)

# the lr S1's schedule reaches at step b, as the trainer prints it
def s2s.nlr(+lr: String, +b: Nat, +warm: Nat, +total: Nat) -> String:
  F32.show(O.lr.at(Maybe.default(&2, F32, F32.read(lr), 0.0003), b, warm, total))

# grep -o 'lr=[0-9.e-]*': the value of the last match in a text
def s2s.lr.char(+c: U32) -> Bool:
  Bool.or(Bool.or(K.kor.isd(c), U32.is_eq(c, 46)), Bool.or(U32.is_eq(c, 101), U32.is_eq(c, 45)))

def s2s.lr.val(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case +c <> +t True{}:
      c <> s2s.lr.val(t, Bool.and(Nat.is_lt(0n, S.len(t)), s2s.lr.char(Maybe.default(&2, U32, List.head(&2, U32, t), 0))))
    case _ _:
      Nil{}

def s2s.lr.at(+xs: List<&2, U32>) -> Bool:
  S.prefix(xs, S.b("lr="))

def s2s.lr.scan(xs: List<&2, U32>, found: Maybe<&2, List<&2, U32>>, at: Bool) -> Maybe<&2, List<&2, U32>>:
  match xs at:
    case Nil{} _:
      found
    case +c <> +t True{}:
      +v = List.drop(&2, U32, t, 2n)
      s2s.lr.scan(t, Some{s2s.lr.val(v, Bool.and(Nat.is_lt(0n, S.len(v)), s2s.lr.char(Maybe.default(&2, U32, List.head(&2, U32, v), 0))))}, s2s.lr.at(t))
    case c <> +t False{}:
      s2s.lr.scan(t, found, s2s.lr.at(t))

def s2s.lr.last(+xs: List<&2, U32>, found: Maybe<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  s2s.lr.scan(xs, found, s2s.lr.at(xs))

# OUT relative to the trainer's directory: `${OUT#$TRAINER_DIR/}`
def s2s.rel(+out: String, +tdir: String) -> String:
  +p = S.b(tdir ++ "/")
  Bool.pick(String, S.prefix(S.b(out), p), S.str(List.drop(&2, U32, S.b(out), S.len(p))), out)

def s2s.stage(+every: String, +rel: String) -> String:
  "s2 traind-next " ++ every ++ " " ++ rel ++ "/plan-fp100m-b16-windows.tsv " ++ rel ++ " fp100m"

def s2s.abs(+pwd: String, +p: String) -> String:
  Bool.pick(String, S.head.is(S.b(p), 47), p, pwd ++ "/" ++ p)

# Settings ---------------------------------------------------------------------------------------

type S2Cfg is Data:
  S2Cfg{deploy: List<&2, String>, filler: String, tx: String, lr: String, warm: Nat, every: String, shard: String, jobs: String, tdir: String, s1log: String, pwd: String}

def s2s.cfg() -> IO(S2Cfg):
  do IO<S2Cfg>:
    +d : List<&2, String> <- K.kor.deploy(["run/v2/gcroot-deploy-agent/bin/deploy"])
    +filler : String <- S.env("FILLER", "run/v3/s2fill")
    +tx : String <- S.env("TRANSCRIPTS", "run/v2/transcripts")
    +lr : String <- S.env("LR", "3e-4")
    +warm : Nat <- S.env.nat("WARM", 300n)
    +every : String <- S.env("EVERY", "5000")
    +shard : String <- S.env("SHARD", "250")
    +jobs : String <- S.env("JOBS", "8")
    +home : String <- S.env("HOME", "")
    +tdir : String <- S.env("TRAINER_DIR", home ++ "/formalTransformer")
    +s1log : String <- S.env("S1_LOG", "")
    +pwd : String <- K.kor.pwd()
    return S2Cfg{d, filler, tx, lr, warm, every, shard, jobs, tdir, s1log, pwd}

def s2s.c.deploy(+c: S2Cfg) -> List<&2, String>:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      d

def s2s.c.filler(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      f

def s2s.c.tx(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      x

def s2s.c.lr(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      l

def s2s.c.warm(+c: S2Cfg) -> Nat:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      w

def s2s.c.every(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      e

def s2s.c.shard(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      s

def s2s.c.jobs(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      j

def s2s.c.tdir(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      t

def s2s.c.s1log(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      g

def s2s.c.pwd(+c: S2Cfg) -> String:
  match c:
    case S2Cfg{d, f, x, l, w, e, s, j, t, g, p}:
      p

# Steps ------------------------------------------------------------------------------------------

def s2s.log(+msg: String) -> IO(Unit):
  K.kor.log("s2", msg)

def s2s.die(+msg: String) -> IO(Unit):
  K.kor.die("s2", msg)

def s2s.need(ok: Bool, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      s2s.die(msg)

# the last lr= of S1's log, streamed a line at a time
type S2Lr is Type:
  S2Lr{r: S.Rd, found: Maybe<&2, List<&2, U32>>, more: Bool}

def s2s.lg.line(m: Maybe<&2, List<&2, U32>>, r: S.Rd, found: Maybe<&2, List<&2, U32>>) -> IO(S2Lr):
  match m:
    case None{}:
      IO.pure(S2Lr, S2Lr{r, found, False{}})
    case Some{+l}:
      IO.pure(S2Lr, S2Lr{r, s2s.lr.last(l, found), True{}})

def s2s.lg.got(found: Maybe<&2, List<&2, U32>>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(S2Lr):
  (r, m) = x
  s2s.lg.line(m, r, found)

def s2s.lg.step(s: S2Lr) -> IO(S2Lr):
  match s:
    case S2Lr{r, found, m}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, S2Lr, S.Rd.next(r), s2s.lg.got(found))

def s2s.lg.go(fuel: Nat, s: S2Lr) -> IO(Maybe<&2, List<&2, U32>>):
  match fuel s:
    case 1n+f S2Lr{r, found, True{}}:
      IO.bind(S2Lr, Maybe<&2, List<&2, U32>>, s2s.lg.step(S2Lr{r, found, True{}}), s2s.lg.go(f))
    case _ S2Lr{r, found, m}:
      do IO<Maybe<&2, List<&2, U32>>>:
        S.Rd.close(r)
        return found

def s2s.lr.seen(+path: String) -> IO(Maybe<&2, List<&2, U32>>):
  do IO<Maybe<&2, List<&2, U32>>>:
    r : S.Rd <- S.Rd.lines(path)
    s2s.lg.go(K.kor.fuel(), S2Lr{r, None{}, True{}})

def s2s.seen.text(m: Maybe<&2, List<&2, U32>>) -> String:
  match m:
    case Some{+v}:
      S.str(v)
    case None{}:
      "none"

def s2s.seen.is(m: Maybe<&2, List<&2, U32>>, +nlr: String) -> Bool:
  match m:
    case Some{+v}:
      S.eq(v, S.b(nlr))
    case None{}:
      False{}

def s2s.check.got(+log: String, +nlr: String, +m: Maybe<&2, List<&2, U32>>) -> IO(String):
  +seen = s2s.seen.text(m)
  do IO<String>:
    s2s.need(s2s.seen.is(m, nlr), "NLR " ++ nlr ++ " is not the lr S1's log " ++ log ++ " last shows (" ++ seen ++ "): refusing")
    s2s.log("NLR " ++ nlr ++ " is the lr " ++ log ++ " last shows")
    return seen

def s2s.check.if(there: Bool, +log: String, +nlr: String) -> IO(String):
  match there:
    case True{}:
      do IO<String>:
        m : Maybe<&2, List<&2, U32>> <- s2s.lr.seen(log)
        s2s.check.got(log, nlr, m)
    case False{}:
      do IO<String>:
        s2s.log("no S1 log at " ++ log ++ ": NLR " ++ nlr ++ " not checked")
        return "none"

# S1_LOG must exist and agree; the default log is checked when it is there
def s2s.check(+c: S2Cfg, +nlr: String) -> IO(String):
  +given = Bool.not(String.is_empty(s2s.c.s1log(c)))
  +log = Bool.pick(String, given, s2s.c.s1log(c), s2s.c.tdir(c) ++ "/train.log")
  do IO<String>:
    +there : Bool <- S.exists(log)
    s2s.need(Bool.or(there, Bool.not(given)), "S1_LOG " ++ log ++ " cannot be read: refusing")
    s2s.check.if(there, log, nlr)

# the rest of S1's plan: OUT.rest's plan and its shards' links
def s2s.links(ks: List<&2, String>, +s1: String, +rest: String) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +k <> t:
      +name = "/shard-" ++ k ++ "-fp100m.corpus"
      do IO<Unit>:
        +target : String <- K.kor.resolve(s1 ++ name)
        K.kor.ln(target, rest ++ name)
        s2s.links(t, s1, rest)

def s2s.accepted(+a: String, +lk: String) -> String:
  a ++ "/accepted/" ++ lk ++ "/transcripts.train.nul"

# An act directory named more than once (2026-10-16, run 4: `s2-acts r1 r1`,
# the round's episodes twice).  Its first naming's pairs go in as they are;
# its k-th (k >= 2) with `/eK` after every id, so no id repeats
# (bend-plan-windows' mix refuses an id two sources share).  Directories
# compare as the strings given.
type S2Act is Data:
  S2Act{dir: String, k: Nat}

# how many times a is in xs
def s2s.times(xs: List<&2, String>, +a: String) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> t:
      Nat.add(Bool.pick(Nat, String.eq(x, a), 1n, 0n), s2s.times(t, a))

# each directory with its naming's number (before: the ones named so far)
def s2s.nth.go(xs: List<&2, String>, +before: List<&2, String>) -> List<&2, S2Act>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      S2Act{x, 1n+s2s.times(before, x)} <> s2s.nth.go(t, x <> before)

def s2s.nth(+xs: List<&2, String>) -> List<&2, S2Act>:
  s2s.nth.go(xs, Nil{})

def s2s.suffix(+k: Nat) -> String:
  "/e" ++ Nat.show(k)

# A NUL file's pairs with suf after each id, streamed a field at a time
# (S.Rd: memory is a chunk plus the longest field)
type S2Rn is Type:
  S2Rn{r: S.Rd, o: File, n: Nat, more: Bool, odd: Bool}

def s2s.rn.pair(+suf: List<&2, U32>, o: File, +n: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(S2Rn):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(S2Rn, S2Rn{r, o, n, False{}, True{}})
    case Some{+t}:
      do IO<S2Rn>:
        o2 : File <- S.emit(o, List.concat(&2, U32, [id, suf, [0], t, [0]]))
        return S2Rn{r, o2, 1n+n, True{}, False{}}

def s2s.rn.id(m: Maybe<&2, List<&2, U32>>, +suf: List<&2, U32>, r: S.Rd, o: File, +n: Nat) -> IO(S2Rn):
  match m:
    case None{}:
      IO.pure(S2Rn, S2Rn{r, o, n, False{}, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, S2Rn, S.Rd.next(r), s2s.rn.pair(suf, o, n, id))

def s2s.rn.got(+suf: List<&2, U32>, o: File, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(S2Rn):
  (r, m) = x
  s2s.rn.id(m, suf, r, o, n)

def s2s.rn.step(+suf: List<&2, U32>, s: S2Rn) -> IO(S2Rn):
  match s:
    case S2Rn{r, o, n, m, odd}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, S2Rn, S.Rd.next(r), s2s.rn.got(suf, o, n))

def s2s.rn.go(fuel: Nat, +suf: List<&2, U32>, s: S2Rn) -> IO(S2Rn):
  match fuel s:
    case 1n+f S2Rn{r, o, n, True{}, odd}:
      IO.bind(S2Rn, S2Rn, s2s.rn.step(suf, S2Rn{r, o, n, True{}, odd}), s2s.rn.go(f, suf))
    case _ z:
      IO.pure(S2Rn, z)

# the output handle back, after a log line; an id without its text stops s2
def s2s.rn.fin(+src: String, +lk: String, +dir: String, +suf: String, s: S2Rn) -> IO(File):
  match s:
    case S2Rn{r, o, +n, m, odd}:
      do IO<File>:
        S.Rd.close(r)
        s2s.need(Bool.not(odd), src ++ " ends with an id that has no text (an odd number of NUL fields)")
        s2s.log(lk ++ ": " ++ dir ++ " again as " ++ suf ++ " (" ++ Nat.show(n) ++ " episodes)")
        return o

# the k-th naming's pairs (k >= 2), each id followed by /eK
def s2s.again(+src: String, +lk: String, +dir: String, +k: Nat, o: File) -> IO(File):
  +suf = s2s.suffix(k)
  do IO<File>:
    r : S.Rd <- S.Rd.open(src)
    s : S2Rn <- s2s.rn.go(K.kor.fuel(), S.b(suf), S2Rn{r, o, 0n, True{}, False{}})
    s2s.rn.fin(src, lk, dir, suf, s)

def s2s.put.k(first: Bool, +src: String, +lk: String, +dir: String, +k: Nat, o: File) -> IO(File):
  match first:
    case True{}:
      K.kor.cp.one(src, o)
    case False{}:
      s2s.again(src, lk, dir, k, o)

def s2s.put.if(there: Bool, +src: String, +lk: String, +dir: String, +k: Nat, o: File) -> IO(File):
  match there:
    case True{}:
      s2s.put.k(Nat.is_eq(k, 1n), src, lk, dir, k, o)
    case False{}:
      IO.pure(File, o)

# one naming's ACT_DIR/accepted/LANG-KIND/transcripts.train.nul into o (none
# when the directory has no such file)
def s2s.put(a: S2Act, +lk: String, o: File) -> IO(File):
  match a:
    case S2Act{+dir, +k}:
      +src = s2s.accepted(dir, lk)
      do IO<File>:
        there : Bool <- S.exists(src)
        s2s.put.if(there, src, lk, dir, k, o)

def s2s.put.all(xs: List<&2, S2Act>, +lk: String, o: File) -> IO(File):
  match xs:
    case Nil{}:
      IO.pure(File, o)
    case a <> t:
      IO.bind(File, File, s2s.put(a, lk, o), s2s.put.all(t, lk))

# every ACT_DIR's LANG-KIND pairs into dst, in the order named
def s2s.gather(+acts: List<&2, String>, +lk: String, +dst: String) -> IO(Unit):
  do IO<Unit>:
    o : File <- IO.try(File, File.open(dst, "w"))
    o2 : File <- s2s.put.all(s2s.nth(acts), lk, o)
    File.close(o2)

# one language and kind of episodes: OUT.ep/tx/LANG-KIND, its spec
def s2s.lang(+c: S2Cfg, +ep: String, +acts: List<&2, String>, +lk: String, +l: String) -> IO(List<&2, String>):
  +d = ep ++ "/tx/" ++ lk
  do IO<List<&2, String>>:
    S.mkdir(d)
    s2s.gather(acts, lk, d ++ "/transcripts.train.nul")
    S.write(d ++ "/files-hi.nul", Nil{})
    S.write(d ++ "/files-lo.nul", Nil{})
    K.kor.ln(s2s.abs(s2s.c.pwd(c), s2s.c.tx(c)) ++ "/" ++ l ++ "/results.holdout.nul", d ++ "/results.holdout.nul")
    K.kor.ln(s2s.abs(s2s.c.pwd(c), s2s.c.tx(c)) ++ "/" ++ l ++ "/transcripts.holdout.nul", d ++ "/transcripts.holdout.nul")
    +n : Nat <- K.kor.pairs(d ++ "/transcripts.train.nul")
    s2s.log(lk ++ ": " ++ Nat.show(n) ++ " episodes")
    return Bool.pick(List<&2, String>, Nat.is_eq(n, 0n), Nil{}, [lk ++ ":" ++ Nat.show(s2s.per(n))])

def s2s.langs.of(ls: List<&2, String>, +kind: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      (l ++ "-" ++ kind) <> s2s.langs.of(t, kind)

def s2s.langs() -> List<&2, String>:
  ["haskell", "agda", "lean", "nix", "bend"]

def s2s.kinds() -> List<&2, String>:
  List.append(&2, String, s2s.langs.of(s2s.langs(), "act"), s2s.langs.of(s2s.langs(), "fix"))

# LANG of LANG-KIND
def s2s.lang.of(+lk: String) -> String:
  S.str(K.kor.field(S.split(S.b(lk), 45), 0n))

def s2s.eps(lks: List<&2, String>, +c: S2Cfg, +ep: String, +acts: List<&2, String>) -> IO(List<&2, String>):
  match lks:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +lk <> t:
      do IO<List<&2, String>>:
        +a : List<&2, String> <- s2s.lang(c, ep, acts, lk, s2s.lang.of(lk))
        +b : List<&2, String> <- s2s.eps(t, c, ep, acts)
        return List.append(&2, String, a, b)

def s2s.words(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      " " ++ x ++ s2s.words(t)

def s2s.salt() -> String:
  "s2 filler"

# the filler: FILLER's files, files-hi.nul's pairs in keyed order
def s2s.filler(+c: S2Cfg, +ep: String) -> IO(Unit):
  +d = ep ++ "/tx/filler"
  +src = s2s.c.filler(c)
  +abs = s2s.abs(s2s.c.pwd(c), src)
  do IO<Unit>:
    S.mkdir(d)
    K.kor.ln(abs ++ "/files-lo.nul", d ++ "/files-lo.nul")
    K.kor.ln(abs ++ "/results.holdout.nul", d ++ "/results.holdout.nul")
    K.kor.ln(abs ++ "/transcripts.holdout.nul", d ++ "/transcripts.holdout.nul")
    K.kor.ln(abs ++ "/transcripts.train.nul", d ++ "/transcripts.train.nul")
    r : Nat & Nat <- K.kor.order(False{}, s2s.salt(), K.kor.fuel(), src ++ "/files-hi.nul", d ++ "/files-hi.nul")
    +a : Nat <- K.kor.count(src ++ "/files-hi.nul", 0)
    +b : Nat <- K.kor.count(d ++ "/files-hi.nul", 0)
    s2s.need(Nat.is_eq(a, b), "the ordered filler lost pairs")
    s2s.log("filler: " ++ Nat.show(Nat.div(b, 2n)) ++ " files of " ++ src ++ "/files-hi.nul in keyed order (\"" ++ s2s.salt() ++ "\")")

def s2s.pw(+st: U32, +log: String) -> IO(Unit):
  do IO<Unit>:
    K.kor.show.file(log)
    s2s.need(U32.is_eq(st, 0), "bend-plan-windows failed (exit " ++ U32.show(st) ++ "; " ++ log ++ ")")

def s2s.cap.ok(+cap: S2Cap) -> Bool:
  match cap:
    case S2CapBad{t}:
      False{}
    case _:
      True{}

# REST_STEPS said: what the cap kept of the rest (nothing to say without one)
def s2s.cap.say(+cap: S2Cap, +b: Nat, +rl0: List<&2, List<&2, U32>>, +rl: List<&2, List<&2, U32>>) -> IO(Unit):
  match cap:
    case S2CapAt{+n}:
      +k = List.length(&2, List<&2, U32>, rl)
      +m = List.length(&2, List<&2, U32>, rl0)
      do IO<Unit>:
        s2s.need(Nat.is_lt(0n, k), "REST_STEPS " ++ Nat.show(n) ++ " holds no segment of the rest from step " ++ Nat.show(b) ++ " (its first has "
          ++ Nat.show(s2s.steps.of(List.take(&2, List<&2, U32>, rl0, 1n))) ++ " steps)")
        s2s.log("REST_STEPS " ++ Nat.show(n) ++ ": the first " ++ Nat.show(k) ++ " of the rest's " ++ Nat.show(m) ++ " segments, " ++ Nat.show(s2s.steps.of(rl))
          ++ " of its " ++ Nat.show(s2s.steps.of(rl0)) ++ " steps; the other " ++ Nat.show(Nat.sub(m, k)) ++ " segments stay unused")
    case _:
      IO.pure(Unit, Unit{})

# CTL_OUT (2026-10-15, run 4's control stage): the same capped rest alone, no
# episodes (`combine 0 CTL_OUT OUT.rest`: the rest's shards in the rest's order,
# planned from step 0), and the stage.env S2 gets; nothing when CTL_OUT is unset
def s2s.control.go(+ctl: String, +rest: String, +env: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    S.rm(ctl)
    Cb.cb.combine(["0", ctl, rest])
    S.write(ctl ++ "/stage.env", env)
    +ct : List<&2, U32> <- S.read(ctl ++ "/plan-fp100m-b16-windows.tsv")
    s2s.log("control: " ++ Nat.show(s2s.steps(s2s.lines(ct))) ++ " steps in " ++ ctl ++ " (the rest alone, no episodes), its stage.env S2's")

def s2s.control(+ctl: String, +rest: String, +env: List<&2, U32>) -> IO(Unit):
  Bool.pick(IO(Unit), String.is_empty(ctl), IO.pure(Unit, Unit{}), s2s.control.go(ctl, rest, env))

# Main ---------------------------------------------------------------------------------------------

def s2s.run(+s1: String, +b: Nat, +out: String, +acts: List<&2, String>) -> IO(Unit):
  +p = s1 ++ "/plan-fp100m-b16-windows.tsv"
  +rest = out ++ ".rest"
  +ep = out ++ ".ep"
  do IO<Unit>:
    +c : S2Cfg <- s2s.cfg()
    +size : Nat <- S.size(p)
    s2s.need(Nat.is_lt(0n, size), "no plan " ++ p)
    +pt : List<&2, U32> <- S.read(p)
    +pl : List<&2, List<&2, U32>> = s2s.lines(pt)
    s2s.need(s2s.starts(pl, b), "step " ++ Nat.show(b) ++ " starts no segment of " ++ p)
    +capv : String <- S.env("REST_STEPS", "")
    +cap : S2Cap = s2s.cap.of(capv)
    s2s.need(s2s.cap.ok(cap), "REST_STEPS " ++ capv ++ " is not a step count")
    +ctl : String <- S.env("CTL_OUT", "")
    # the lr S1's schedule reaches at the boundary, checked against S1's log first
    +nlr : String = s2s.nlr(s2s.c.lr(c), b, s2s.c.warm(c), s2s.steps(pl))
    +seen : String <- s2s.check(c, nlr)
    # the rest of the steady plan (REST_STEPS: its leading segments only)
    +rl0 : List<&2, List<&2, U32>> = s2s.rest(pl, b)
    +rl : List<&2, List<&2, U32>> = s2s.capped(cap, rl0)
    s2s.cap.say(cap, b, rl0, rl)
    S.rm(rest)
    S.rm(ep)
    S.rm(out)
    S.mkdir(rest)
    S.mkdir(ep ++ "/tx")
    # combine reads a plan's segment lines and the shards beside it
    S.write(rest ++ "/plan-fp100m-b16-windows.tsv", s2s.unlines(rl))
    s2s.links(s2s.ks(rl), s1, rest)
    +rw : Nat = s2s.tw(rl, False{})
    s2s.log("rest of S1 from step " ++ Nat.show(b) ++ ": " ++ Nat.show(List.length(&2, List<&2, U32>, rl)) ++ " segments, " ++ Nat.show(rw) ++ " training windows")
    # the episodes: a language each, every round's together
    +specs : List<&2, String> <- s2s.eps(s2s.kinds(), c, ep, acts)
    s2s.need(Nat.is_lt(0n, List.length(&2, String, specs)), "no episodes in" ++ s2s.words(acts))
    s2s.filler(c, ep)
    +sp : List<&2, String> = List.append(&2, String, specs, ["filler:1"])
    s2s.log("plan-windows " ++ ep ++ "/w fp100m 16" ++ s2s.words(sp))
    +st : U32 <- K.kor.tool.log(s2s.c.deploy(c), ["OUT=" ++ ep ++ "/tx", "SHARD=" ++ s2s.c.shard(c), "JOBS=" ++ s2s.c.jobs(c), "TOKENIZER=weights/code32k.bpe"],
      "plan-windows", List.append(&2, String, [ep ++ "/w", "fp100m", "16"], sp), ep ++ "/plan-windows.log")
    s2s.pw(st, ep ++ "/plan-windows.log")
    +wt : List<&2, U32> <- S.read(ep ++ "/w/plan-fp100m-b16-windows.tsv")
    +wl : List<&2, List<&2, U32>> = s2s.lines(wt)
    +ew : Nat = s2s.tw(wl, True{})
    +share : String = s2s.share(ew, rw)
    s2s.log("episode windows " ++ Nat.show(ew) ++ " of " ++ Nat.show(Nat.add(ew, rw)) ++ ": share " ++ share)
    Cb.cb.combine([share, out, rest, ep ++ "/w"])
    S.write(out ++ "/stage.env", S.b("NLR=" ++ nlr ++ "\nNWARM=10\n"))
    s2s.log("stage.env: NLR " ++ nlr ++ " (S1's log last shows lr " ++ seen ++ "), NWARM 10")
    s2s.control(ctl, rest, S.b("NLR=" ++ nlr ++ "\nNWARM=10\n"))
    +ot : List<&2, U32> <- S.read(out ++ "/plan-fp100m-b16-windows.tsv")
    +ol : List<&2, List<&2, U32>> = s2s.lines(ot)
    s2s.log("S2: " ++ Nat.show(s2s.steps(ol)) ++ " steps in " ++ out ++ "; append to STAGES:")
    IO.print(s2s.stage(s2s.c.every(c), s2s.rel(out, s2s.c.tdir(c))))

def s2s.args(+s1: String, b: Maybe<&2, Nat>, +out: String, +acts: List<&2, String>) -> IO(Unit):
  match b:
    case Some{+n}:
      s2s.run(s1, n, out, acts)
    case None{}:
      IO.die(Unit, 2, "s2: BOUNDARY is not a step number")

def s2s.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +s1 <> +b <> +out <> a <> more:
      s2s.args(s1, Nat.read(b), out, K.kor.l2(a <> more))
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 s2 S1_DIR BOUNDARY OUT ACT_DIR...")
