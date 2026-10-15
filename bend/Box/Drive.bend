import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ../CorpusV2/Steps.bend as St
import ../CorpusV2/Keyed.bend as K
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./Vast.bend as Vs

# Drive: the stages built here and fed to a box (2026-10-15, the plan "all
# logic in Bend", Phase 4; bend-ops' `stage next`, `stage raw` and `feed`).
# Run from the repository root.  The deploy tools run as K.kor.runner finds
# them ($DEPLOY TOOL, bend-TOOL on $PATH, else `nix run .#deploy -- TOOL`);
# bend-corpus-v2's own steps run in this process when they print nothing
# that is needed back (split-lang, nul-jsonl, replay-filler, specs-next's
# arithmetic), else as `corpus-v2 STEP` (slice, specs-mixnew, credit-ok).
#
#   bend-ops stage next
#       bend/gpu/next-stage.sh build: the new transcripts (NEW: LABEL=DIR words,
#       default haskell-new=run/transcripts-next/haskell
#       bend-new=run/transcripts-next/bend) as OUT/LABEL (OUT
#       run/transcripts-mix-NAME, NAME next: links to DIR's train, filler and
#       held-out files, empty files where DIR has none) and replay of fp100m's
#       languages (FINAL/LANG, FINAL run/transcripts-final; REPLAY_FILLER=1 their
#       filler too, less the files the new ones hold), the per-round specs
#       (specs-next REPLAY (1.0) LABEL:COUNT...), plan-windows into RUN
#       (run/NAME), the new held-out transcripts packed and tokenized as EVALC
#       (run/eval/transcript-NAME.corpus); the plan's first line (200 bytes) and
#       `ls -la RUN EVALC`
#   bend-ops stage raw mix | mixnew FILE.jsonl... | build K | push K HOST PORT
#       bend/gpu/raw-stage.sh: mix splits CODE (run/code-train-v3.jsonl) by
#       language into R/src (R run/raw) and interleaves it, PER a round in
#       proportion to the counts (Haskell 100), with fp100m's transcripts as
#       JSONL cycling (tr-LANG.jsonl: 41 26 28 13 67): R/mix.jsonl; mixnew the
#       same for FILEs (specs-mixnew's specs); build slices K (SLICE bytes,
#       300000000) into run/PK (P raw) as packed shards and a plan
#       (plan-corpus ... fp100m 16 2000, JOBS 3), the plan copied as
#       plan-fp100m-b16-windows.tsv; push is `stage push PK run/PK HOST PORT`
#       with EVALC=run/eval/transcript-next.corpus
#   bend-ops feed HOST PORT STAGES [FIRST] [LAST]
#       bend/gpu/raw-driver.sh: once the mix unit (MIX_UNIT, ft-raw-mix) is not
#       active, for K in FIRST (1) .. LAST (9): build slice K unless run/PK holds
#       its plan (`stage raw build K` > run/P-buildK.log; a failure stops the
#       feed, status 0: the mix may be used up); with CREDIT_GUARD=1, wait (600 s
#       at a time) until the vast credit covers the queue plus the slice's
#       steps (credit-ok STAGES CREDIT CUR STEPS, CUR the box's newest
#       non-eval log and its last step=I/N); push it, 6 tries a minute apart
#       (`stage raw push K` >> run/P-pushK.log); append
#       `PK traind-next 0 run/PK/plan-PK-b16-windows.tsv run/PK PK` to STAGES
#
# Every name starts with `drv.`; the pure parts are tested in bend/tests/recipes.bend.

def drv.log(+tool: String, +msg: String) -> IO(Unit):
  K.kor.log(tool, msg)

def drv.die(+tool: String, +msg: String) -> IO(Unit):
  K.kor.die(tool, msg)

def drv.need(ok: Bool, +tool: String, +msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      drv.die(tool, msg)

def drv.abs(+pwd: String, +p: String) -> String:
  Bool.pick(String, S.head.is(S.b(p), 47), p, pwd ++ "/" ++ p)

# Pure parts ------------------------------------------------------------------------------------

# LABEL=DIR: the label (before the first =) and the directory (after it)
def drv.lab(+e: String) -> String:
  S.str(K.kor.field(S.split(S.b(e), 61), 0n))

def drv.dir(+e: String) -> String:
  S.str(List.drop(&2, U32, S.b(e), 1n+S.len(S.b(drv.lab(e)))))

# a plan's steps: its first line's field 3
def drv.plan.steps(+xs: List<&2, U32>) -> Nat:
  K.kor.nat(K.kor.field(K.kor.words(S.lines.first(xs)), 2n))

# the stage line raw-driver appended
def drv.stage.line(+name: String) -> String:
  name ++ " traind-next 0 run/" ++ name ++ "/plan-" ++ name ++ "-b16-windows.tsv run/" ++ name ++ " " ++ name

# `ls -t DIR | grep -v "^eval"` and its first *.log: the newest trainer log
def drv.newest(ls: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      None{}
    case +l <> t:
      Bool.pick(Maybe<&2, List<&2, U32>>, Bool.and(S.suffix(l, S.b(".log")), Bool.not(S.prefix(l, S.b("eval")))), Some{l}, drv.newest(t))

# `grep -o "step=[0-9]*/[0-9]*" LOG | tail -1` read from grep -o's lines
def drv.last.line(ls: List<&2, List<&2, U32>>, +acc: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      acc
    case +l <> t:
      drv.last.line(t, Bool.pick(List<&2, U32>, Nat.is_eq(S.len(l), 0n), acc, l))

# raw-driver's CUR: `NAME step=I/N` (NAME the log less .log)
def drv.cur(+log: List<&2, U32>, +grep: List<&2, U32>) -> String:
  S.str(List.take(&2, U32, log, Nat.sub(S.len(log), 4n))) ++ " " ++ S.str(drv.last.line(S.split.lines(grep), Nil{}))

# raw-stage mix's specs: SRC:PER for the five languages (Haskell 100, the
# rest per(N, Haskell's)), then the transcripts cycling
def drv.mix.specs(+r: String, +hs: Nat, +le: Nat, +ag: Nat, +nx: Nat, +be: Nat) -> List<&2, String>:
  [r ++ "/src/haskell.jsonl:100", r ++ "/src/lean.jsonl:" ++ Nat.show(St.st.per.of(le, hs)), r ++ "/src/agda.jsonl:" ++ Nat.show(St.st.per.of(ag, hs)),
   r ++ "/src/nix.jsonl:" ++ Nat.show(St.st.per.of(nx, hs)), r ++ "/src/bend.jsonl:" ++ Nat.show(St.st.per.of(be, hs)),
   r ++ "/src/tr-haskell.jsonl:41:cycle", r ++ "/src/tr-lean.jsonl:26:cycle", r ++ "/src/tr-agda.jsonl:28:cycle",
   r ++ "/src/tr-nix.jsonl:13:cycle", r ++ "/src/tr-bend.jsonl:67:cycle"]

def drv.specs.of(r: Maybe<&2, St.StF>, cs: Maybe<&2, List<&2, St.StLc>>) -> Maybe<&2, String>:
  match r cs:
    case Some{+rep} Some{c}:
      Some{St.st.sn.specs(rep, c)}
    case _ _:
      None{}

# next-stage's specs: specs-next REPLAY LABEL:COUNT...
def drv.specs.next(+rep: String, cs: List<&2, String>) -> Maybe<&2, String>:
  drv.specs.of(St.st.f.read(S.b(rep)), St.st.lcs(cs))

# Shared steps ----------------------------------------------------------------------------------

def drv.l1(xs: List<&2, String>) -> List<String>:
  K.kor.l1(xs)

# `ls -la ARGS` printed
def drv.ls(args: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +o : Lc.LclOut <- Lc.lcl.run(600, "ls", drv.l1("-la" <> args))
    IO.write(S.str(Lc.lcl.out(o)))

# `wc -l < F`
def drv.lines(+f: String) -> IO(Nat):
  do IO<Nat>:
    +o : Lc.LclOut <- Lc.lcl.run(86400, "wc", ["-l", f])
    return K.kor.nat(K.kor.field(K.kor.words(Lc.lcl.out(o)), 0n))

# the first line of a file, its first n bytes, printed
def drv.head(+f: String, +n: Nat) -> IO(Unit):
  do IO<Unit>:
    +xs : List<&2, U32> <- S.read(f)
    IO.print(S.str(List.take(&2, U32, S.lines.first(xs), n)))

# ENV.. PROG ARGS: status, stdout and stderr apart (OnBox's obx.run)
def drv.run(env: List<&2, String>, +prog: String, args: List<&2, String>) -> IO(Lc.LclOut):
  do IO<Lc.LclOut>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("env", drv.l1(List.append(&2, String, env, prog <> args)), "", S.cap.bytes(), 4000000000)
    Lc.lcl.run.got(r)

# a bend-corpus-v2 step as its own process
def drv.cv2(env: List<&2, String>, args: List<&2, String>) -> IO(Lc.LclOut):
  do IO<Lc.LclOut>:
    +r : List<&2, String> <- K.kor.runner("corpus-v2")
    +a : List<&2, String> = List.append(&2, String, r, args)
    drv.run(env, K.kor.hd(a), K.kor.tl(a))

def drv.err(+o: Lc.LclOut) -> IO(Unit):
  K.kor.show(Lc.lcl.err(o))

def drv.cv2.must(env: List<&2, String>, +what: String, args: List<&2, String>) -> IO(List<&2, U32>):
  do IO<List<&2, U32>>:
    +o : Lc.LclOut <- drv.cv2(env, args)
    drv.err(o)
    Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}), IO.die(Unit, 1, what ++ " failed (exit " ++ U32.show(Lc.lcl.status(o)) ++ ")"))
    return Lc.lcl.out(o)

# stage next -----------------------------------------------------------------------------------

def drv.new.files() -> List<&2, String>:
  ["transcripts.train.nul", "files-hi.nul", "files-lo.nul", "results.holdout.nul"]

def drv.link.or.empty(fs: List<&2, String>, +pwd: String, +dir: String, +d: String) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +f <> t:
      do IO<Unit>:
        there : Bool <- S.exists(dir ++ "/" ++ f)
        Bool.pick(IO(Unit), there, K.kor.ln(drv.abs(pwd, dir ++ "/" ++ f), d ++ "/" ++ f), S.write(d ++ "/" ++ f, Nil{}))
        drv.link.or.empty(t, pwd, dir, d)

# the new languages: OUT/LABEL each, and LABEL:COUNT a language
def drv.news(es: List<&2, String>, +pwd: String, +out: String) -> IO(List<&2, String>):
  match es:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case +e <> t:
      +d = out ++ "/" ++ drv.lab(e)
      do IO<List<&2, String>>:
        S.mkdir(d)
        drv.link.or.empty(drv.new.files(), pwd, drv.dir(e), d)
        +c : Nat <- K.kor.pairs(d ++ "/transcripts.train.nul")
        +rest : List<&2, String> <- drv.news(t, pwd, out)
        return (drv.lab(e) ++ ":" ++ Nat.show(c)) <> rest

def drv.dirs(es: List<&2, String>) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> t:
      drv.dir(e) <> drv.dirs(t)

def drv.replay.filler(on: Bool, +d: String, +src: String, +news: List<&2, String>) -> IO(Unit):
  match on:
    case True{}:
      St.st.replay.filler(drv.l1(d <> src <> news))
    case False{}:
      do IO<Unit>:
        S.write(d ++ "/files-hi.nul", Nil{})
        S.write(d ++ "/files-lo.nul", Nil{})

def drv.replays(ls: List<&2, String>, +pwd: String, +out: String, +final: String, +rf: Bool, +news: List<&2, String>) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      +d = out ++ "/" ++ l
      do IO<Unit>:
        S.mkdir(d)
        K.kor.ln(drv.abs(pwd, final ++ "/" ++ l ++ "/transcripts.train.nul"), d ++ "/transcripts.train.nul")
        K.kor.ln(drv.abs(pwd, final ++ "/" ++ l ++ "/results.holdout.nul"), d ++ "/results.holdout.nul")
        drv.replay.filler(rf, d, final ++ "/" ++ l, news)
        drv.replays(t, pwd, out, final, rf, news)

def drv.holdouts(ds: List<&2, String>) -> List<&2, String>:
  match ds:
    case Nil{}:
      Nil{}
    case +d <> t:
      (d ++ "/transcripts.holdout.nul") <> drv.holdouts(t)

def drv.specs.got(m: Maybe<&2, String>) -> IO(String):
  match m:
    case Some{s}:
      IO.pure(String, s)
    case None{}:
      IO.die(String, 1, "stage next: specs-next: REPLAY must be a number and each spec LABEL:COUNT")

def drv.words(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      " " ++ x ++ drv.words(t)

def drv.next() -> IO(Unit):
  do IO<Unit>:
    +name : String <- S.env("NAME", "next")
    +out : String <- S.env("OUT", "run/transcripts-mix-" ++ name)
    +run : String <- S.env("RUN", "run/" ++ name)
    +newv : String <- S.env("NEW", "haskell-new=run/transcripts-next/haskell bend-new=run/transcripts-next/bend")
    +evalc : String <- S.env("EVALC", "run/eval/transcript-" ++ name ++ ".corpus")
    +rep : String <- S.env("REPLAY", "1.0")
    +rf : String <- S.env("REPLAY_FILLER", "0")
    +final : String <- S.env("FINAL", "run/transcripts-final")
    +pwd : String <- K.kor.pwd()
    +es : List<&2, String> = K.kor.strs(K.kor.words(S.b(newv)))
    S.rm(out)
    S.mkdir(out)
    S.mkdir(run)
    +counts : List<&2, String> <- drv.news(es, pwd, out)
    drv.replays(["haskell", "lean", "agda", "nix", "bend"], pwd, out, final, String.eq(rf, "1"), drv.dirs(es))
    # per round: the new languages in their sizes' ratio, 20 a round in all,
    # and REPLAY (1.0) times as many replayed in fp100m's proportions
    +specs : String <- drv.specs.got(drv.specs.next(rep, counts))
    IO.print("new transcripts:" ++ drv.words(counts) ++ "; per round: " ++ specs)
    K.kor.tool(["OUT=" ++ out], "plan-windows", List.append(&2, String, [run, "fp100m", "16"], K.kor.strs(K.kor.words(S.b(specs)))))
    # the held-out new transcripts as an eval corpus (M2-RUNBOOK section 4)
    +hs : List<&2, String> <- K.kor.existing(drv.holdouts(drv.dirs(es)))
    K.kor.cat(hs, run ++ "/holdout.nul")
    K.kor.tool([], "pack", [run ++ "/holdout.nul", run ++ "/holdout.packed.nul", "--target", "131072", "--prefix", "transcript-" ++ name, "--stats"])
    K.kor.tool([], "prepare", ["weights/code32k.bpe", run ++ "/holdout.packed.nul", evalc])
    drv.head(run ++ "/plan-fp100m-b16-windows.tsv", 200n)
    drv.ls([run, evalc])

# stage raw -----------------------------------------------------------------------------------

def drv.tr.jsonl(ls: List<&2, String>, +final: String, +r: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        St.st.nul.jsonl(drv.l1([final ++ "/" ++ l ++ "/transcripts.train.nul", r ++ "/src/tr-" ++ l ++ ".jsonl"]))
        drv.tr.jsonl(t, final, r)

def drv.langs5() -> List<&2, String>:
  ["haskell", "lean", "agda", "nix", "bend"]

def drv.raw.mix(+r: String, +final: String) -> IO(Unit):
  do IO<Unit>:
    +code : String <- S.env("CODE", "run/code-train-v3.jsonl")
    S.mkdir(r ++ "/src")
    St.st.split.lang(drv.l1([code, r ++ "/src"]))
    # fp100m's transcripts as JSONL, for the replay
    drv.tr.jsonl(drv.langs5(), final, r)
    +hs : Nat <- drv.lines(r ++ "/src/haskell.jsonl")
    drv.need(Nat.is_lt(0n, hs), "raw-stage", r ++ "/src/haskell.jsonl is empty")
    +le : Nat <- drv.lines(r ++ "/src/lean.jsonl")
    +ag : Nat <- drv.lines(r ++ "/src/agda.jsonl")
    +nx : Nat <- drv.lines(r ++ "/src/nix.jsonl")
    +be : Nat <- drv.lines(r ++ "/src/bend.jsonl")
    # transcripts: about 20% of the bytes; code documents average ~7 KB, transcripts ~1.2 KB
    K.kor.tool([], "mix", (r ++ "/mix.jsonl") <> drv.mix.specs(r, hs, le, ag, nx, be))
    drv.ls([r ++ "/mix.jsonl"])

def drv.raw.mixnew(+r: String, +final: String, fs: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(r ++ "/src")
    drv.tr.jsonl(drv.langs5(), final, r)
    +out : List<&2, U32> <- drv.cv2.must([], "specs-mixnew", List.append(&2, String, ["specs-mixnew", r ++ "/src"], fs))
    +specs : String = S.str(S.chomp(out))
    IO.print("per round: " ++ specs)
    K.kor.tool([], "mix", (r ++ "/mix.jsonl") <> K.kor.strs(K.kor.words(S.b(specs))))
    drv.ls([r ++ "/mix.jsonl"])

def drv.raw.build(+r: String, +p: String, +k: String) -> IO(Unit):
  +d = "run/" ++ p ++ k
  do IO<Unit>:
    +slice : String <- S.env("SLICE", "300000000")
    +jobs : String <- S.env("JOBS", "3")
    S.mkdir(d)
    # slice k: the k-th SLICE bytes of the mix, cut at line ends (the last
    # slice keeps whole 2000-document parts only)
    o : List<&2, U32> <- drv.cv2.must([], "slice", ["slice", r ++ "/mix.jsonl", d ++ "/slice.jsonl", k, slice])
    IO.write(S.str(o))
    +size : Nat <- S.size(d ++ "/slice.jsonl")
    drv.need(Nat.is_lt(0n, size), "raw-stage", "slice " ++ k ++ " is empty")
    K.kor.tool(["TOKENIZER=weights/code32k.bpe", "PACK_TARGET=131072", "JOBS=" ++ jobs], "plan-corpus", [d ++ "/slice.jsonl", d, "fp100m", "16", "2000"])
    K.kor.cat([d ++ "/plan-fp100m-b16-s2000.tsv"], d ++ "/plan-fp100m-b16-windows.tsv")
    drv.head(d ++ "/plan-fp100m-b16-windows.tsv", 160n)
    S.rm(d ++ "/slice.jsonl")

# bend-ops itself (the head of IO.args), for a step run as its own process
def drv.self() -> IO(String):
  K.kor.self()

# `stage push PK run/PK HOST PORT` with EVALC=run/eval/transcript-next.corpus
def drv.raw.push(+p: String, +k: String, +host: String, +port: String) -> IO(Unit):
  do IO<Unit>:
    +self : String <- drv.self()
    +o : Lc.LclOut <- drv.run(["EVALC=run/eval/transcript-next.corpus"], self, ["stage", "push", p ++ k, "run/" ++ p ++ k, host, port])
    IO.write(S.str(Lc.lcl.out(o)))
    drv.err(o)
    Bool.pick(IO(Unit), Lc.lcl.ok(o), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "stage raw push " ++ k ++ " failed"))

def drv.raw.go(xs: List<&2, String>, +r: String, +p: String, +final: String) -> IO(Unit):
  match xs:
    case "mix" <> Nil{}:
      drv.raw.mix(r, final)
    case "mixnew" <> fs:
      drv.raw.mixnew(r, final, fs)
    case "build" <> +k <> Nil{}:
      drv.raw.build(r, p, k)
    case "push" <> +k <> +host <> +port <> Nil{}:
      drv.raw.push(p, k, host, port)
    case _:
      IO.die(Unit, 2, "usage: bend-ops stage raw mix | mixnew FILE.jsonl... | build K | push K HOST PORT   (R, P, SLICE, JOBS, CODE, FINAL)")

def drv.raw(xs: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +r : String <- S.env("R", "run/raw")
    +p : String <- S.env("P", "raw")
    +final : String <- S.env("FINAL", "run/transcripts-final")
    drv.raw.go(xs, r, p, final)

# feed ------------------------------------------------------------------------------------------

def drv.flog(+msg: String) -> IO(Unit):
  drv.log("raw-driver", msg)

# lines of a program's stderr, each logged
def drv.flog.lines(ls: List<&2, List<&2, U32>>) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        Bool.pick(IO(Unit), Nat.is_eq(S.len(l), 0n), IO.pure(Unit, Unit{}), drv.flog(S.str(l)))
        drv.flog.lines(t)

# the box's newest trainer log and its last step: CUR (None: the box did not answer)
def drv.cur.step(+b: Rm.RmtBox, +dir: String, +log: List<&2, U32>) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    +o : Lc.LclOut <- Rm.rmt.ssh(b, 120, "grep -o 'step=[0-9]*/[0-9]*' " ++ Rm.rmt.q(dir ++ "/" ++ S.str(log)))
    return Bool.pick(Maybe<&2, String>, U32.is_lt(Lc.lcl.status(o), 2), Some{drv.cur(log, Lc.lcl.out(o))}, None{})

def drv.cur.of(m: Maybe<&2, List<&2, U32>>, +b: Rm.RmtBox, +dir: String) -> IO(Maybe<&2, String>):
  match m:
    case Some{+log}:
      drv.cur.step(b, dir, log)
    case None{}:
      IO.pure(Maybe<&2, String>, None{})

def drv.cur.box(+b: Rm.RmtBox) -> IO(Maybe<&2, String>):
  do IO<Maybe<&2, String>>:
    +dir : String <- S.env("BOX_DIR", "formalTransformer")
    +o : Lc.LclOut <- Rm.rmt.ssh(b, 120, "ls -t " ++ Rm.rmt.q(dir))
    drv.cur.of(Bool.pick(Maybe<&2, List<&2, U32>>, Lc.lcl.ok(o), drv.newest(S.split.lines(Lc.lcl.out(o))), None{}), b, dir)

def drv.ok.got(+o: Lc.LclOut) -> IO(Bool):
  do IO<Bool>:
    drv.flog.lines(S.split.lines(Lc.lcl.err(o)))
    return Lc.lcl.ok(o)

def drv.ok.cur(m: Maybe<&2, String>, tok: Maybe<&2, List<&2, U32>>, +stages: String, +n: Nat) -> IO(Bool):
  match m tok:
    case Some{+cur} Some{+credit}:
      do IO<Bool>:
        +o : Lc.LclOut <- drv.cv2([], ["credit-ok", stages, S.str(credit), cur, Nat.show(n)])
        drv.ok.got(o)
    case _ _:
      IO.pure(Bool, False{})

# raw-driver's credit_ok: does the credit cover the queue plus n steps
def drv.credit.ok(+b: Rm.RmtBox, +stages: String, +n: Nat) -> IO(Bool):
  do IO<Bool>:
    +v : String <- Vs.vst.bin()
    +u : Lc.LclOut <- Vs.vst.run(v, ["show", "user", "--raw"])
    +cur : Maybe<&2, String> <- drv.cur.box(b)
    drv.ok.cur(cur, Bool.pick(Maybe<&2, List<&2, U32>>, Lc.lcl.ok(u), St.st.credit.tok(Lc.lcl.out(u)), None{}), stages, n)

def drv.guard(fuel: Nat, ok: Bool, +b: Rm.RmtBox, +stages: String, +k: String, +n: Nat) -> IO(Unit):
  match fuel ok:
    case _ True{}:
      IO.pure(Unit, Unit{})
    case 0n False{}:
      IO.die(Unit, 1, "raw-driver: gave up waiting for the credit")
    case 1n+f False{}:
      do IO<Unit>:
        drv.flog("slice " ++ k ++ " (" ++ Nat.show(n) ++ " steps) waits: the credit does not cover it (top up, or it stays out)")
        IO.sleep(600000)
        ok2 : Bool <- drv.credit.ok(b, stages, n)
        drv.guard(f, ok2, b, stages, k, n)

def drv.guard.if(on: Bool, +b: Rm.RmtBox, +stages: String, +k: String, +n: Nat) -> IO(Unit):
  match on:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      do IO<Unit>:
        ok : Bool <- drv.credit.ok(b, stages, n)
        drv.guard(K.kor.fuel(), ok, b, stages, k, n)

def drv.st.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> U32:
  match r:
    case Done{(code, oe)}:
      code
    case Fail{e}:
      127

# `ENV.. PROG ARGS >> LOG 2>&1` (OnBox's obx.to: a redirect and nothing else); the status
def drv.to(+log: String, env: List<&2, String>, +prog: String, args: List<&2, String>) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, U32 & (String & String)> <-
      Process.run("sh", drv.l1(List.append(&2, String, ["-c", "exec \"$@\" >> \"$0\" 2>&1", log, "env"], List.append(&2, String, env, prog <> args))),
        "", S.cap.bytes(), 4000000000)
    return drv.st.got(r)

# the box's link drops now and then: a push resumes (rsync --partial-dir) up to 6 times
def drv.push.again(t: Nat, ok: Bool, +i: Nat, +self: String, +p: String, +k: String, +host: String, +port: String) -> IO(Bool):
  match t ok:
    case _ True{}:
      IO.pure(Bool, True{})
    case 0n False{}:
      do IO<Bool>:
        drv.flog("slice " ++ k ++ " push try " ++ Nat.show(i) ++ " failed; again in a minute")
        IO.sleep(60000)
        return False{}
    case 1n+(+u) False{}:
      do IO<Bool>:
        drv.flog("slice " ++ k ++ " push try " ++ Nat.show(i) ++ " failed; again in a minute")
        IO.sleep(60000)
        +st : U32 <- drv.to("run/" ++ p ++ "-push" ++ k ++ ".log", ["EVALC=run/eval/transcript-next.corpus"], self, ["stage", "push", p ++ k, "run/" ++ p ++ k, host, port])
        drv.push.again(u, U32.is_eq(st, 0), 1n+i, self, p, k, host, port)

def drv.push.try(+self: String, +p: String, +k: String, +host: String, +port: String) -> IO(Bool):
  do IO<Bool>:
    +st : U32 <- drv.to("run/" ++ p ++ "-push" ++ k ++ ".log", ["EVALC=run/eval/transcript-next.corpus"], self, ["stage", "push", p ++ k, "run/" ++ p ++ k, host, port])
    drv.push.again(5n, U32.is_eq(st, 0), 1n, self, p, k, host, port)

def drv.mix.active(+unit: String) -> IO(Bool):
  do IO<Bool>:
    +o : Lc.LclOut <- Lc.lcl.run(60, "systemctl", ["--user", "is-active", "-q", unit])
    return Lc.lcl.ok(o)

# `while systemctl --user is-active -q UNIT; do sleep 30; done`
def drv.mix.wait(fuel: Nat, active: Bool, +unit: String) -> IO(Unit):
  match fuel active:
    case 1n+f True{}:
      do IO<Unit>:
        IO.sleep(30000)
        a : Bool <- drv.mix.active(unit)
        drv.mix.wait(f, a, unit)
    case _ _:
      IO.pure(Unit, Unit{})

def drv.feed.slice(+b: Rm.RmtBox, +stages: String, +p: String, +k: String, +guard: Bool, +host: String, +port: String) -> IO(Unit):
  +plan = "run/" ++ p ++ k ++ "/plan-fp100m-b16-windows.tsv"
  do IO<Unit>:
    +pl : List<&2, U32> <- S.read(plan)
    +n : Nat = drv.plan.steps(pl)
    drv.guard.if(guard, b, stages, k, n)
    drv.flog("pushing slice " ++ k)
    +self : String <- drv.self()
    +ok : Bool <- drv.push.try(self, p, k, host, port)
    drv.need(ok, "raw-driver", "slice " ++ k ++ " did not push after 6 tries; stopping")
    S.add(stages, S.b(drv.stage.line(p ++ k) ++ "\n"))
    drv.flog("slice " ++ k ++ " staged and appended (" ++ Nat.show(n) ++ " steps)")

# 0: built (or there), 1: the build failed (the feed stops)
def drv.feed.build(have: Bool, +p: String, +k: String) -> IO(Bool):
  match have:
    case True{}:
      IO.pure(Bool, True{})
    case False{}:
      do IO<Bool>:
        drv.flog("building slice " ++ k)
        +self : String <- drv.self()
        +st : U32 <- S.run.log(".", [], 2000000, self, ["stage", "raw", "build", k], "run/" ++ p ++ "-build" ++ k ++ ".log")
        return U32.is_eq(st, 0)

def drv.feed.k(go: Bool, +b: Rm.RmtBox, +stages: String, +p: String, +k: String, +guard: Bool, +host: String, +port: String) -> IO(Bool):
  match go:
    case False{}:
      do IO<Bool>:
        drv.flog("slice " ++ k ++ " did not build (the mix may be used up); stopping")
        return False{}
    case True{}:
      do IO<Bool>:
        drv.feed.slice(b, stages, p, k, guard, host, port)
        return True{}

def drv.feed.go(ks: List<&2, Nat>, more: Bool, +b: Rm.RmtBox, +stages: String, +p: String, +guard: Bool, +host: String, +port: String) -> IO(Unit):
  match ks more:
    case Nil{} _:
      IO.pure(Unit, Unit{})
    case _ False{}:
      IO.pure(Unit, Unit{})
    case +k <> t True{}:
      +kn = Nat.show(k)
      do IO<Unit>:
        have : Bool <- S.exists("run/" ++ p ++ kn ++ "/plan-fp100m-b16-windows.tsv")
        built : Bool <- drv.feed.build(have, p, kn)
        go : Bool <- drv.feed.k(built, b, stages, p, kn, guard, host, port)
        drv.feed.go(t, go, b, stages, p, guard, host, port)

# FIRST .. LAST
def drv.range(n: Nat, +k: Nat) -> List<&2, Nat>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      k <> drv.range(m, 1n+k)

def drv.feed(+host: String, +port: String, +stages: String, +first: Nat, +last: Nat) -> IO(Unit):
  do IO<Unit>:
    +p : String <- S.env("P", "raw")
    +g : String <- S.env("CREDIT_GUARD", "0")
    +unit : String <- S.env("MIX_UNIT", "ft-raw-mix")
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    # slice 1 is built by the mix unit
    a : Bool <- drv.mix.active(unit)
    drv.mix.wait(K.kor.fuel(), a, unit)
    drv.feed.go(drv.range(Nat.sub(1n+last, first), first), True{}, b, stages, p, String.eq(g, "1"), host, port)

def drv.nat.or(m: Maybe<&2, Nat>, +d: Nat) -> Nat:
  Maybe.default(&2, Nat, m, d)

def drv.feed.main(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case +h <> +p <> +s <> Nil{}:
      drv.feed(h, p, s, 1n, 9n)
    case +h <> +p <> +s <> +f <> Nil{}:
      drv.feed(h, p, s, drv.nat.or(Nat.read(f), 1n), 9n)
    case +h <> +p <> +s <> +f <> +l <> Nil{}:
      drv.feed(h, p, s, drv.nat.or(Nat.read(f), 1n), drv.nat.or(Nat.read(l), 9n))
    case _:
      IO.die(Unit, 2, "usage: bend-ops feed HOST PORT STAGES [FIRST] [LAST]   (P, CREDIT_GUARD, MIX_UNIT, SECS_PER_STEP, DPH, END_COST, MARGIN, V)")

# bend-ops' entries (IO.args' list)
def drv.feed.args(xs: List<String>) -> IO(Unit):
  drv.feed.main(K.kor.l2(xs))

def drv.raw.main(xs: List<String>) -> IO(Unit):
  drv.raw(K.kor.l2(xs))
