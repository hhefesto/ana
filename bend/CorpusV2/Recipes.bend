import Base
import ../Sys.bend as S
import ./Raw.bend as R
import ./Steps.bend as St
import ./Keyed.bend as K

# Corpus v2's recipes (2026-10-15, the plan "all logic in Bend", Phase 4): the
# tools/corpus-v2 scripts that build the run's corpora, as bend-corpus-v2
# subcommands.  Each writes what its script wrote, byte for byte; the deploy
# tools they run are found as K.kor.runner says ($DEPLOY TOOL, else bend-TOOL
# on $PATH, else `nix run .#deploy -- TOOL`).  Run from the repository root;
# logs go to stderr, stamped UTC-6.  Every def is prefixed `rcp.`.
#
#   render        (render.sh) `bend-corpus-v2 pool`'s units as format 2
#                 transcripts: each language's train and holdout results
#                 (RESULTS/LANG.PART.nul, RESULTS run/v2/results) cut into
#                 shards (split-nul: Bend 8, Haskell, Lean, Agda 3, Nix 1;
#                 holdout 1) in WORK (run/v2/render), each rendered by
#                 TRANSCRIPT_BIN (run/v2/gcroot-bend-transcript/bin/bend-transcript,
#                 TRANSCRIPT_FORMAT=2, COPIES Bend 4, the rest 2) with its log
#                 beside it, JOBS at a time (default: all of them at once, as
#                 the script started them), then joined in shard order:
#                 OUT/LANG/transcripts.PART.nul (OUT run/v2/transcripts); each
#                 language and part's units and transcripts from its logs
#                 (awk's sums of fields 2 and 5)
#   evals         (evals.sh) the bits-per-byte eval corpora, packed to 128 KB
#                 (pack --target 131072 --prefix NAME --stats) and tokenized
#                 (prepare weights/code32k.bpe): EVAL_OUT/v2-tr-LANG.corpus and
#                 EVAL_OUT/v2-tr.corpus (TRANSCRIPTS/LANG/transcripts.holdout.nul,
#                 TRANSCRIPTS run/v2/transcripts), EVAL_OUT/v2-vault-LANG.corpus
#                 (vault-sample of VAULT/LANG.jsonl, VAULT run/v2/vault;
#                 haskell, agda, lean, bend); EVAL_OUT run/eval, the work in
#                 WORK (run/v2/evals); then `ls -la` of EVAL_OUT/v2-*.corpus
#   windows       (windows.sh) format 2's train transcripts as transcript
#                 windows: NV/LANG (NV run/v2/transcripts-nv) links
#                 TRANSCRIPTS/LANG's files-hi, files-lo, results.holdout and
#                 transcripts.holdout and holds its train transcripts less the
#                 verify shape (ids ending /verify; written only when it is
#                 missing or empty), then `OUT=NV SHARD (8000) JOBS (6)
#                 TOKENIZER=weights/code32k.bpe plan-windows WINDOWS_OUT fp100m 16
#                 SPECS` (WINDOWS_OUT run/v2/T, SPECS "bend:113 haskell:45
#                 lean:25 agda:26 nix:5")
#   raw-build K   (rawshards.sh build) slice K of R/mix.jsonl (R run/v2/R; SLICE
#                 bytes, 300000000) as packed shards and a plan in RAW_OUT/K
#                 (RAW_OUT: R): `TOKENIZER=weights/code32k.bpe PACK_TARGET=131072
#                 JOBS (3) plan-corpus SLICE.jsonl DIR fp100m 16 2000`, the slice
#                 removed, the plan's first line (160 bytes of it) printed

def rcp.langs.render() -> List<&2, String>:
  ["bend", "haskell", "lean", "agda", "nix"]

def rcp.log(+tool: String, +msg: String) -> IO(Unit):
  K.kor.log(tool, msg)

# render ---------------------------------------------------------------------------------------

def rcp.copies(+l: String) -> String:
  Bool.pick(String, String.eq(l, "bend"), "4", "2")

def rcp.shards(+l: String, +part: String) -> Nat:
  Bool.pick(Nat, String.eq(part, "holdout"), 1n, Bool.pick(Nat, String.eq(l, "bend"), 8n,
    Bool.pick(Nat, Bool.or(String.eq(l, "haskell"), Bool.or(String.eq(l, "lean"), String.eq(l, "agda"))), 3n, 1n)))

# a render: its language, part and shard
type RcJob is Data:
  RcJob{l: String, part: String, s: Nat}

def rcp.pre(+w: String, +j: RcJob) -> String:
  match j:
    case RcJob{l, part, s}:
      w ++ "/" ++ l ++ "." ++ part ++ "." ++ Nat.show(s)

def rcp.job.l(+j: RcJob) -> String:
  match j:
    case RcJob{l, part, s}:
      l

def rcp.jobs.shards(k: Nat, +l: String, +part: String, +n: Nat) -> List<&2, RcJob>:
  match k:
    case 0n:
      Nil{}
    case 1n+(+i):
      RcJob{l, part, Nat.sub(n, 1n+i)} <> rcp.jobs.shards(i, l, part, n)

def rcp.parts() -> List<&2, String>:
  ["train", "holdout"]

def rcp.jobs.parts(ps: List<&2, String>, +l: String) -> List<&2, RcJob>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      +n = rcp.shards(l, p)
      List.append(&2, RcJob, rcp.jobs.shards(n, l, p, n), rcp.jobs.parts(t, l))

def rcp.jobs(ls: List<&2, String>) -> List<&2, RcJob>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      List.append(&2, RcJob, rcp.jobs.parts(rcp.parts(), l), rcp.jobs(t))

# A pool of processes, each `ENV PROG ARGS > LOG 2>&1`: JOBS at a time, the
# failures counted (the shape of Raw.bend's rw.pool)
type RcRun is Data:
  RcRun{env: List<&2, String>, prog: String, args: List<&2, String>, log: String}

type RcPw is Type:
  RcPw{go: Bool, bad: Nat}

def rcp.run.one(r: RcRun) -> IO(Bool):
  match r:
    case RcRun{env, prog, args, log}:
      do IO<Bool>:
        +st : U32 <- S.run.log(".", K.kor.l1(env), 2000000, prog, K.kor.l1(args), log)
        return U32.is_eq(st, 0)

def rcp.pw.got(m: Maybe<&1, RcRun>, +bad: Nat) -> IO(RcPw):
  match m:
    case None{}:
      IO.pure(RcPw, RcPw{False{}, bad})
    case Some{r}:
      do IO<RcPw>:
        +ok : Bool <- rcp.run.one(r)
        return RcPw{True{}, Nat.add(bad, Bool.pick(Nat, ok, 0n, 1n))}

def rcp.pw.step(+q: Chan(RcRun), p: RcPw) -> IO(RcPw):
  match p:
    case RcPw{g, +bad}:
      do IO<RcPw>:
        m : Maybe<&1, RcRun> <- Chan.recv(RcRun, q)
        rcp.pw.got(m, bad)

def rcp.pw.go(fuel: Nat, +q: Chan(RcRun), p: RcPw) -> IO(Nat):
  match fuel p:
    case 1n+f RcPw{True{}, bad}:
      IO.bind(RcPw, Nat, rcp.pw.step(q, RcPw{True{}, bad}), rcp.pw.go(f, q))
    case _ RcPw{g, bad}:
      IO.pure(Nat, bad)

def rcp.pw.fork(n: Nat, +q: Chan(RcRun)) -> IO(List<Chan(Nat)>):
  match n:
    case 0n:
      IO.pure(List<Chan(Nat)>, Nil{})
    case 1n+m:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, rcp.pw.go(K.kor.fuel(), q, RcPw{True{}, 0n}))
        rest : List<Chan(Nat)> <- rcp.pw.fork(m, q)
        return ch <> rest

def rcp.pw.join(chs: List<Chan(Nat)>, +bad: Nat) -> IO(Nat):
  match chs:
    case Nil{}:
      IO.pure(Nat, bad)
    case +ch <> more:
      do IO<Nat>:
        +b : Nat <- IO.join(Nat, ch)
        rcp.pw.join(more, Nat.add(bad, b))

def rcp.pw.send(rs: List<&2, RcRun>, +q: Chan(RcRun)) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case r <> more:
      do IO<Unit>:
        ok : Result<&1, &1, RcRun, Unit> <- Chan.send(RcRun, q, r)
        rcp.pw.send(more, q)

# the runs, `jobs` at a time; the answer is how many failed
def rcp.pool(+rs: List<&2, RcRun>, +jobs: Nat) -> IO(Nat):
  +n = Nat.max(1n, Nat.min(jobs, List.length(&2, RcRun, rs)))
  do IO<Nat>:
    +q : Chan(RcRun) <- Chan.new(RcRun, U32.from_nat(1n+List.length(&2, RcRun, rs)))
    rcp.pw.send(rs, q)
    Chan.close(RcRun, q)
    chs : List<Chan(Nat)> <- rcp.pw.fork(n, q)
    rcp.pw.join(chs, 0n)

def rcp.renders(js: List<&2, RcJob>, +t: String, +w: String) -> List<&2, RcRun>:
  match js:
    case Nil{}:
      Nil{}
    case +j <> more:
      +pre = rcp.pre(w, j)
      RcRun{["TRANSCRIPT_FORMAT=2", "COPIES=" ++ rcp.copies(rcp.job.l(j))], t, ["weights/code32k.bpe", pre ++ ".in.nul", pre ++ ".out.nul"], pre ++ ".log"}
        <> rcp.renders(more, t, w)

def rcp.split.all(ls: List<&2, String>, +res: String, +w: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        R.rw.split.nul([res ++ "/" ++ l ++ ".train.nul", w ++ "/" ++ l ++ ".train", Nat.show(rcp.shards(l, "train"))])
        R.rw.split.nul([res ++ "/" ++ l ++ ".holdout.nul", w ++ "/" ++ l ++ ".holdout", "1"])
        rcp.split.all(t, res, w)

def rcp.fst(r: Nat & Nat) -> Nat:
  (a, b) = r
  a

def rcp.snd(r: Nat & Nat) -> Nat:
  (a, b) = r
  b

def rcp.fst.l(r: Nat & List<&2, U32>) -> Nat:
  (a, b) = r
  a

# awk '{u += $2; t += $5}' over a log's lines: each field's leading number
def rcp.lead(+xs: List<&2, U32>) -> Nat:
  rcp.fst.l(K.kor.digits(xs, 0n))

type RcUt is Data:
  RcUt{u: Nat, t: Nat}

def rcp.ut.u(+r: RcUt) -> Nat:
  match r:
    case RcUt{u, t}:
      u

def rcp.ut.t(+r: RcUt) -> Nat:
  match r:
    case RcUt{u, t}:
      t

def rcp.sums(ls: List<&2, List<&2, U32>>, +u: Nat, +t: Nat) -> RcUt:
  match ls:
    case Nil{}:
      RcUt{u, t}
    case +l <> more:
      +ws = K.kor.words(l)
      rcp.sums(more, Nat.add(u, rcp.lead(K.kor.field(ws, 1n))), Nat.add(t, rcp.lead(K.kor.field(ws, 4n))))

def rcp.logs(k: Nat, +pre: String, +n: Nat, +u: Nat, +t: Nat) -> IO(RcUt):
  match k:
    case 0n:
      IO.pure(RcUt, RcUt{u, t})
    case 1n+(+i):
      do IO<RcUt>:
        +xs : List<&2, U32> <- S.read(pre ++ "." ++ Nat.show(Nat.sub(n, 1n+i)) ++ ".log")
        +r : RcUt = rcp.sums(S.split.lines(xs), u, t)
        rcp.logs(i, pre, n, rcp.ut.u(r), rcp.ut.t(r))

def rcp.outs(k: Nat, +pre: String, +n: Nat) -> List<&2, String>:
  match k:
    case 0n:
      Nil{}
    case 1n+(+i):
      (pre ++ "." ++ Nat.show(Nat.sub(n, 1n+i)) ++ ".out.nul") <> rcp.outs(i, pre, n)

def rcp.join.part(+l: String, +part: String, +w: String, +o: String) -> IO(Unit):
  +n = rcp.shards(l, part)
  +pre = w ++ "/" ++ l ++ "." ++ part
  do IO<Unit>:
    K.kor.cat(rcp.outs(n, pre, n), o ++ "/" ++ l ++ "/transcripts." ++ part ++ ".nul")
    +r : RcUt <- rcp.logs(n, pre, n, 0n, 0n)
    rcp.log("render", l ++ " " ++ part ++ ": " ++ Nat.show(rcp.ut.u(r)) ++ " units, " ++ Nat.show(rcp.ut.t(r)) ++ " transcripts")

def rcp.join.all(ls: List<&2, String>, +w: String, +o: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        S.mkdir(o ++ "/" ++ l)
        rcp.join.part(l, "train", w, o)
        rcp.join.part(l, "holdout", w, o)
        rcp.join.all(t, w, o)

def rcp.render.run() -> IO(Unit):
  do IO<Unit>:
    +t : String <- S.env("TRANSCRIPT_BIN", "run/v2/gcroot-bend-transcript/bin/bend-transcript")
    +res : String <- S.env("RESULTS", "run/v2/results")
    +w : String <- S.env("WORK", "run/v2/render")
    +o : String <- S.env("OUT", "run/v2/transcripts")
    S.mkdir(w)
    rcp.split.all(rcp.langs.render(), res, w)
    +rs : List<&2, RcRun> = rcp.renders(rcp.jobs(rcp.langs.render()), t, w)
    +jobs : Nat <- S.env.nat("JOBS", List.length(&2, RcRun, rs))
    rcp.log("render", Nat.show(List.length(&2, RcRun, rs)) ++ " renders, " ++ Nat.show(jobs) ++ " at a time")
    +bad : Nat <- rcp.pool(rs, jobs)
    Bool.pick(IO(Unit), Nat.is_eq(bad, 0n), IO.pure(Unit, Unit{}), K.kor.die("render", Nat.show(bad) ++ " render(s) failed (their logs are in " ++ w ++ ")"))
    rcp.join.all(rcp.langs.render(), w, o)
    rcp.log("render", "done")

def rcp.render(xs: List<String>) -> IO(Unit):
  match xs:
    case Nil{}:
      rcp.render.run()
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 render   (RESULTS, WORK, OUT, TRANSCRIPT_BIN, JOBS)")

# evals ----------------------------------------------------------------------------------------

def rcp.corpus(+w: String, +e: String, +name: String, +nul: String) -> IO(Unit):
  do IO<Unit>:
    K.kor.tool([], "pack", [nul, w ++ "/" ++ name ++ ".packed.nul", "--target", "131072", "--prefix", name, "--stats"])
    K.kor.tool([], "prepare", ["weights/code32k.bpe", w ++ "/" ++ name ++ ".packed.nul", e ++ "/" ++ name ++ ".corpus"])

def rcp.ev.tr(ls: List<&2, String>, +w: String, +e: String, +tx: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      +src = tx ++ "/" ++ l ++ "/transcripts.holdout.nul"
      do IO<Unit>:
        rcp.corpus(w, e, "v2-tr-" ++ l, src)
        K.kor.cat.to([src], w ++ "/v2-tr.nul", True{})
        rcp.ev.tr(t, w, e, tx)

def rcp.ev.vault(ls: List<&2, String>, +w: String, +e: String, +vault: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        # the vault's files in sha256("corpus-v2 vault eval\0" + id) order, up to 5 a
        # repository and none past 100,000 characters, until 2,000,000 characters
        St.st.vault.sample([vault ++ "/" ++ l ++ ".jsonl", w ++ "/vault-" ++ l ++ ".nul"])
        rcp.corpus(w, e, "v2-vault-" ++ l, w ++ "/vault-" ++ l ++ ".nul")
        rcp.ev.vault(t, w, e, vault)

def rcp.glob.keep(ns: List<&2, List<&2, U32>>, +dir: String) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +r = rcp.glob.keep(t, dir)
      Bool.pick(List<&2, String>, Bool.and(S.prefix(n, S.b("v2-")), S.suffix(n, S.b(".corpus"))), (dir ++ "/" ++ S.str(n)) <> r, r)

def rcp.evals.run() -> IO(Unit):
  do IO<Unit>:
    +w : String <- S.env("WORK", "run/v2/evals")
    +e : String <- S.env("EVAL_OUT", "run/eval")
    +tx : String <- S.env("TRANSCRIPTS", "run/v2/transcripts")
    +vault : String <- S.env("VAULT", "run/v2/vault")
    S.mkdir(w)
    S.mkdir(e)
    S.write(w ++ "/v2-tr.nul", Nil{})
    rcp.ev.tr(["haskell", "agda", "lean", "nix", "bend"], w, e, tx)
    rcp.corpus(w, e, "v2-tr", w ++ "/v2-tr.nul")
    rcp.ev.vault(["haskell", "agda", "lean", "bend"], w, e, vault)
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 600, "find", [e, "-mindepth", "1", "-maxdepth", "1", "-printf", "%P\\0"], Nil{})
    +fs : List<&2, String> = rcp.glob.keep(S.split(S.Out.text(o), 0), e)
    +ls : S.Out <- S.run(".", ["LC_ALL=C"], 600, "ls", "-la" <> K.kor.l1(fs), Nil{})
    IO.write(S.str(S.Out.text(ls)))

def rcp.evals(xs: List<String>) -> IO(Unit):
  match xs:
    case Nil{}:
      rcp.evals.run()
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 evals   (WORK, EVAL_OUT, TRANSCRIPTS, VAULT, DEPLOY)")

# windows -------------------------------------------------------------------------------------

# a NUL file's pairs less those whose id ends /verify
type RcNv is Type:
  RcNv{r: St.StRd, o: File, kept: Nat, more: Bool}

def rcp.nv.keep(drop: Bool, r: St.StRd, o: File, +kept: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(RcNv):
  match drop:
    case True{}:
      IO.pure(RcNv, RcNv{r, o, kept, True{}})
    case False{}:
      do IO<RcNv>:
        o2 : File <- S.emit(o, List.concat(&2, U32, [id, [0], t, [0]]))
        return RcNv{r, o2, 1n+kept, True{}}

def rcp.nv.rec(m: Maybe<&2, St.StPair>, r: St.StRd, o: File, +kept: Nat) -> IO(RcNv):
  match m:
    case None{}:
      IO.pure(RcNv, RcNv{r, o, kept, False{}})
    case Some{St.StPair{+id, +t}}:
      rcp.nv.keep(S.suffix(id, S.b("/verify")), r, o, kept, id, t)

def rcp.nv.got(o: File, +kept: Nat, x: St.StRd & Maybe<&2, St.StPair>) -> IO(RcNv):
  (r, m) = x
  rcp.nv.rec(m, r, o, kept)

def rcp.nv.step(s: RcNv) -> IO(RcNv):
  match s:
    case RcNv{r, o, kept, m}:
      IO.bind(St.StRd & Maybe<&2, St.StPair>, RcNv, St.st.rd.pair(r), rcp.nv.got(o, kept))

def rcp.nv.go(fuel: Nat, s: RcNv) -> IO(Nat):
  match fuel s:
    case 1n+f RcNv{r, o, kept, True{}}:
      IO.bind(RcNv, Nat, rcp.nv.step(RcNv{r, o, kept, True{}}), rcp.nv.go(f))
    case _ RcNv{r, o, kept, m}:
      do IO<Nat>:
        St.st.rd.close(r)
        File.close(o)
        return kept

def rcp.noverify(+src: String, +dst: String) -> IO(Nat):
  do IO<Nat>:
    r : St.StRd <- St.st.rd.open(src, 0)
    o : File <- IO.try(File, File.open(dst, "w"))
    rcp.nv.go(K.kor.fuel(), RcNv{r, o, 0n, True{}})

def rcp.nv.if(have: Bool, +src: String, +dst: String, +l: String) -> IO(Unit):
  match have:
    case True{}:
      rcp.log("windows", l ++ ": " ++ dst ++ " is there; kept")
    case False{}:
      do IO<Unit>:
        +n : Nat <- rcp.noverify(src, dst)
        rcp.log("windows", l ++ ": " ++ Nat.show(n) ++ " train transcripts without the verify shape")

def rcp.nv.links(fs: List<&2, String>, +from: String, +to: String) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +f <> t:
      do IO<Unit>:
        K.kor.ln(from ++ "/" ++ f, to ++ "/" ++ f)
        rcp.nv.links(t, from, to)

def rcp.nv.langs(ls: List<&2, String>, +src: String, +nv: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> t:
      do IO<Unit>:
        S.mkdir(nv ++ "/" ++ l)
        rcp.nv.links(["files-hi.nul", "files-lo.nul", "results.holdout.nul", "transcripts.holdout.nul"], src ++ "/" ++ l, nv ++ "/" ++ l)
        +size : Nat <- S.size(nv ++ "/" ++ l ++ "/transcripts.train.nul")
        rcp.nv.if(Nat.is_lt(0n, size), src ++ "/" ++ l ++ "/transcripts.train.nul", nv ++ "/" ++ l ++ "/transcripts.train.nul", l)
        rcp.nv.langs(t, src, nv)

def rcp.abs(+pwd: String, +p: String) -> String:
  Bool.pick(String, S.head.is(S.b(p), 47), p, pwd ++ "/" ++ p)

def rcp.windows.run() -> IO(Unit):
  do IO<Unit>:
    +pwd : String <- K.kor.pwd()
    +src : String <- S.env("TRANSCRIPTS", "run/v2/transcripts")
    +nv : String <- S.env("NV", "run/v2/transcripts-nv")
    +t : String <- S.env("WINDOWS_OUT", "run/v2/T")
    +specs : String <- S.env("SPECS", "bend:113 haskell:45 lean:25 agda:26 nix:5")
    +shard : String <- S.env("SHARD", "8000")
    +jobs : String <- S.env("JOBS", "6")
    rcp.nv.langs(rcp.langs.render(), rcp.abs(pwd, src), nv)
    # PER ∝ each language's count (bend 283,924, haskell 112,213, lean 63,984, agda 65,689, nix 12,444)
    K.kor.tool(["OUT=" ++ nv, "SHARD=" ++ shard, "JOBS=" ++ jobs, "TOKENIZER=weights/code32k.bpe"], "plan-windows",
      List.append(&2, String, [t, "fp100m", "16"], K.kor.strs(K.kor.words(S.b(specs)))))

def rcp.windows(xs: List<String>) -> IO(Unit):
  match xs:
    case Nil{}:
      rcp.windows.run()
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 windows   (TRANSCRIPTS, NV, WINDOWS_OUT, SPECS, SHARD, JOBS, DEPLOY)")

# raw-build -----------------------------------------------------------------------------------

def rcp.raw.build.k(+k: String) -> IO(Unit):
  do IO<Unit>:
    +r : String <- S.env("R", "run/v2/R")
    +out : String <- S.env("RAW_OUT", r)
    +slice : String <- S.env("SLICE", "300000000")
    +jobs : String <- S.env("JOBS", "3")
    +d : String = out ++ "/" ++ k
    S.mkdir(d)
    R.rw.slice([r ++ "/mix.jsonl", d ++ "/slice.jsonl", k, slice])
    +size : Nat <- S.size(d ++ "/slice.jsonl")
    Bool.pick(IO(Unit), Nat.is_lt(0n, size), IO.pure(Unit, Unit{}), K.kor.die("raw-build", "slice " ++ k ++ " is empty"))
    K.kor.tool(["TOKENIZER=weights/code32k.bpe", "PACK_TARGET=131072", "JOBS=" ++ jobs], "plan-corpus", [d ++ "/slice.jsonl", d, "fp100m", "16", "2000"])
    S.rm(d ++ "/slice.jsonl")
    +p : List<&2, U32> <- S.read(d ++ "/plan-fp100m-b16-s2000.tsv")
    IO.print(S.str(List.take(&2, U32, S.lines.first(p), 160n)))

def rcp.raw.build(xs: List<String>) -> IO(Unit):
  match xs:
    case +k <> Nil{}:
      rcp.raw.build.k(k)
    case _:
      IO.die(Unit, 2, "usage: bend-corpus-v2 raw-build K   (R, RAW_OUT, SLICE, JOBS, DEPLOY)")
