import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ./Local.bend as Lc
import ./Remote.bend as Rm
import ./OnBox.bend as Ob
import ../Push.bend as Pu

# Stage: putting a run on a rented box, from this machine (2026-10-14, the
# plan's Phase 1b; bend-ops' `stage` and `dense-identity`).  Run from the
# repository root.
#
#   bend-ops stage box HOST PORT
#       bend/gpu/fp-stage.sh: the trainer and the gate program as C from the pinned
#       compiler (`bend` on PATH, or $BEND), and bend-box as C (box.c); bend-push's link
#       check; the C, fp.sh, the tokenizer and the eval corpora onto the box; bend-box built
#       there with the box's newest clang (clang-19 ... clang-14, clang, each tried by its own
#       ssh call); then the plan and its shards by bend-push, in plan order.  BOX_ENV names
#       bend-push's settings (bend/gpu/fp100m-box.env)
#   bend-ops stage push NAME RUN HOST PORT
#       bend/gpu/next-stage.sh push: RUN's shards (the plan's segment lines, built as
#       shard-K-fp100m.corpus) as run/NAME/shard-K-NAME.corpus, the eval corpus EVALC
#       (run/eval/transcript-NAME.corpus, when it is here), the plan as
#       run/NAME/plan-NAME-b16-windows.tsv.tmp; then every shard's sha256 here against every
#       run/NAME/shard-*-NAME.corpus on the box (an extra stale shard there blocks it too):
#       equal, the plan is moved into place and STAGED written last; else `shard sums differ;
#       not staged` and exit 1
#   bend-ops stage restage HOST PORT CKPT STAGE...
#       bend/gpu/fp-restage.sh: the C, fp.sh, bend-box, the tokenizer and the two transcript
#       eval corpora; CKPT as out/<its name>, checked by sha256; then each STAGE by `stage
#       push` (STAGE is NAME, with RUN run/NAME, or NAME=RUN; raw slices too)
#   bend-ops stage shards PLAN
#       the shard numbers a plan's segment lines name, in order (what `stage push` sends)
#   bend-ops dense-identity OUT_DIR [TRAINER]
#       bend/tests/dense-identity.sh: six steps of small4-v3 with AdamW and with Muon on the
#       frozen corpus, OUT_DIR/{adamw,muon}.btc and their logs without the fields that are
#       not the trajectory; sha256sum's lines (bend/tests/dense-identity.sha256 holds the
#       checkpoints')
#
# The box is reached as Remote.bend reaches it (SSH_OPTS, SSH_TRIES, RSYNC_TRIES, ...): every
# command sent is a fixed command line without control flow, and every copy is rsync with a
# partial directory and retries (the scripts used scp and `rsync --partial`).  BOX_DIR is the
# box's working directory (stage box: the env file's REMOTE_DIR; else formalTransformer).
# Every name starts with `stg.`; the pure parts are tested in bend/tests/box.bend.
#
# 2026-10-15 (Phase 1c): fp-stage.sh, next-stage.sh, fp-restage.sh and dense-identity.sh are
# unwired; `bend-ops sim stage box|push|push-drop|push-corrupt|restage|dense-identity` holds
# these subcommands to copies of them in the sandbox (bend/Box/ScnStage.bend).

# The plan's shards and their sums (pure) --------------------------------------------------------

def stg.seg.of(+ws: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  +k = Ob.obx.field(ws, 1n)
  Bool.pick(Maybe<&2, List<&2, U32>>, Bool.and(S.eq(Ob.obx.field(ws, 0n), S.b("segment")), Nat.is_lt(0n, S.len(k))), Some{k}, None{})

def stg.seg.put(m: Maybe<&2, List<&2, U32>>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match m:
    case Some{k}:
      k <> rest
    case None{}:
      rest

def stg.segs(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      stg.seg.put(stg.seg.of(Ob.obx.words(l)), stg.segs(t))

# `awk '$1 == "segment" { print $2 }' PLAN`, as the shell's for loop took
# its words: each segment line's second field
def stg.segments(+plan: List<&2, U32>) -> List<&2, List<&2, U32>>:
  stg.segs(S.split.lines(plan))

def stg.shard(+k: List<&2, U32>, +size: String) -> String:
  "shard-" ++ S.str(k) ++ "-" ++ size ++ ".corpus"

def stg.shards(ks: List<&2, List<&2, U32>>, +size: String) -> List<&2, List<&2, U32>>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> t:
      S.b(stg.shard(k, size)) <> stg.shards(t, size)

# a local shard's sum under the name it has on the box: shard-K-fp100m.corpus
# is shard-K-NAME.corpus there
def stg.rename(ss: List<&2, Lc.LclSum>, +name: String) -> List<&2, Lc.LclSum>:
  match ss:
    case Nil{}:
      Nil{}
    case Lc.LclSum{+h, +n} <> t:
      +suf = S.b("-fp100m.corpus")
      +base = Bool.pick(List<&2, U32>, S.suffix(n, suf), List.take(&2, U32, n, Nat.sub(S.len(n), S.len(suf))), n)
      Lc.LclSum{h, List.append(&2, U32, base, S.b("-" ++ name ++ ".corpus"))} <> stg.rename(t, name)

def stg.sum.lines(ss: List<&2, Lc.LclSum>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      Nil{}
    case Lc.LclSum{+h, +n} <> t:
      List.concat(&2, U32, [h, [32], n]) <> stg.sum.lines(t)

def stg.lines.eq(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(S.eq(x, y), stg.lines.eq(xt, yt))
    case _ _:
      False{}

# next-stage.sh's test: the sorted `HASH NAME` lines here equal the box's
# (a shard missing there, a corrupted one, or an extra stale one fails it)
def stg.same(+here: List<&2, Lc.LclSum>, +box: List<&2, Lc.LclSum>) -> Bool:
  stg.lines.eq(Lc.lcl.sort(stg.sum.lines(here)), Lc.lcl.sort(stg.sum.lines(box)))

# Settings and the box ---------------------------------------------------------------------------

def stg.dir.got(+env: String, +d: String) -> String:
  Bool.pick(String, String.is_empty(env), d, env)

# BOX_DIR, else d
def stg.dir(+d: String) -> IO(String):
  do IO<String>:
    e : String <- S.env("BOX_DIR", "")
    return stg.dir.got(e, d)

def stg.p(+dir: String, +path: String) -> String:
  Rm.rmt.q(dir ++ "/" ++ path)

def stg.words(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      " " ++ x ++ stg.words(t)

def stg.quoted(+dir: String, ps: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      stg.p(dir, p) <> stg.quoted(dir, t)

def stg.ok(ok: Bool, +what: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "stage: " ++ what ++ " failed")

def stg.ssh.if(ok: Bool, +o: Lc.LclOut, +what: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "stage: " ++ what ++ " failed (exit " ++ U32.show(Lc.lcl.status(o)) ++ "): " ++ S.str(Lc.lcl.err(o)) ++ S.str(Lc.lcl.out(o)))

def stg.ssh.ok(+o: Lc.LclOut, +what: String) -> IO(Unit):
  stg.ssh.if(Lc.lcl.ok(o), o, what)

# `mkdir -p` of these paths under the box's directory
def stg.mkdirs(+b: Rm.RmtBox, +dir: String, ps: List<&2, String>) -> IO(Unit):
  +cmd = "mkdir -p" ++ stg.words(stg.quoted(dir, ps))
  do IO<Unit>:
    +o : Lc.LclOut <- Rm.rmt.ssh(b, 300, cmd)
    stg.ssh.ok(o, cmd)

def stg.l1(xs: List<&2, String>) -> List<String>:
  Ob.obx.l1(xs)

# local files to DST on the box (rsync -a, a partial directory, retried)
def stg.send(+b: Rm.RmtBox, srcs: List<&2, String>, +dst: String) -> IO(Unit):
  args = stg.l1(List.append(&2, String, ["-a", "--partial-dir=.partial", "-e", Rm.rmt.rsh(b)], List.append(&2, String, srcs, [Rm.rmt.remote(b, dst)])))
  do IO<Unit>:
    ok : Bool <- Rm.rmt.rsync(b, args)
    stg.ok(ok, "rsync to " ++ dst)

def stg.log(+msg: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- Ck.ck.wall()
    IO.print(Ck.stamp(t) ++ " " ++ msg)

# The C ------------------------------------------------------------------------------------------

def stg.emit1(+bend: String, +src: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run("bend", [], 3600, bend, [src, "-o", out], Nil{})
    Ob.obx.out(S.Out.text(o))
    stg.ok(U32.is_eq(S.Out.status(o), 0), "bend " ++ src ++ " -o " ++ out)

# traind.c (TrainDense.bend, which has TRAIN_NEXT, so also traind-next.c),
# dense.c (the gate) and box.c (bend-box) into tmp
def stg.emit(+tmp: String) -> IO(Unit):
  do IO<Unit>:
    +bend : String <- S.env("BEND", "bend")
    stg.emit1(bend, "TrainDense.bend", tmp ++ "/traind.c")
    stg.emit1(bend, "tests/dense.bend", tmp ++ "/dense.c")
    stg.emit1(bend, "Box/BoxMain.bend", tmp ++ "/box.c")
    o : List<&2, U32> <- S.must("cp traind.c", "cp", [tmp ++ "/traind.c", tmp ++ "/traind-next.c"])
    return Unit{}

def stg.c.files(+tmp: String) -> List<&2, String>:
  [tmp ++ "/traind.c", tmp ++ "/traind-next.c", tmp ++ "/dense.c", tmp ++ "/box.c", "bend/gpu/fp.sh"]

def stg.clang.got(cs: List<&2, String>, found: Maybe<&2, String>, +b: Rm.RmtBox) -> IO(Maybe<&2, String>):
  match cs found:
    case _ Some{c}:
      IO.pure(Maybe<&2, String>, Some{c})
    case Nil{} None{}:
      IO.pure(Maybe<&2, String>, None{})
    case +c <> t None{}:
      do IO<Maybe<&2, String>>:
        +o : Lc.LclOut <- Rm.rmt.ssh(b, 120, c ++ " --version")
        stg.clang.got(t, Bool.pick(Maybe<&2, String>, Lc.lcl.ok(o), Some{c}, None{}), b)

def stg.cc(m: Maybe<&2, String>, +b: Rm.RmtBox, +dir: String) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 1, "stage: the box has no clang (clang-19 ... clang-14, clang) to build bend-box")
    case Some{+c}:
      +cmd = c ++ " -std=c11 -O3 " ++ stg.p(dir, "box.c") ++ " -lpthread -lm -o " ++ stg.p(dir, "bend-box")
      do IO<Unit>:
        +o : Lc.LclOut <- Rm.rmt.ssh(b, 3600, cmd)
        stg.ssh.ok(o, cmd)
        stg.log("bend-box built on the box with " ++ c)

# bend-box from box.c on the box, with its newest clang (each tried by its own ssh call)
def stg.bend.box(+b: Rm.RmtBox, +dir: String) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&2, String> <- stg.clang.got(Ob.obx.clangs(), None{}, b)
    stg.cc(m, b, dir)

# box -------------------------------------------------------------------------------------------

def stg.v2.corpora(ns: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +rest = stg.v2.corpora(t)
      Bool.pick(List<&2, String>, Bool.and(S.prefix(n, S.b("v2-")), S.suffix(n, S.b(".corpus"))), ("run/eval/" ++ S.str(n)) <> rest, rest)

def stg.box(+host: String, +port: String) -> IO(Unit):
  do IO<Unit>:
    +envf : String <- S.env("BOX_ENV", "bend/gpu/fp100m-box.env")
    +ef : List<&2, U32> <- S.read(envf)
    +rd : String <- Pu.setting(Pu.env.kvs(S.split.lines(ef), Nil{}), "REMOTE_DIR", "formalTransformer")
    +dir : String <- stg.dir(rd)
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    +tmp : String <- S.mktemp()
    IO.print("== C from the pinned compiler")
    stg.emit(tmp)
    +ls : Lc.LclOut <- Lc.lcl.run(60, "ls", ["-la", tmp])
    Ob.obx.out(Lc.lcl.out(ls))
    IO.print("== link check")
    +lk : Lc.LclOut <- Ob.obx.run(["TRAIN_ENV_FILE=" ++ envf], "bend-push", ["link", host, port])
    Ob.obx.pass(lk)
    stg.ok(Lc.lcl.ok(lk), "bend-push link")
    IO.print("== to the box (" ++ dir ++ ")")
    stg.mkdirs(b, dir, ["weights", "run/eval", "run/fp100m", "out"])
    stg.send(b, stg.c.files(tmp), dir ++ "/")
    stg.send(b, ["weights/code32k.bpe"], dir ++ "/weights/")
    m : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls("run/eval")
    stg.send(b, List.append(&2, String, ["run/eval/transcript-fp.corpus", "run/eval/transcript-next.corpus"],
      stg.v2.corpora(Maybe.default(&2, List<&2, List<&2, U32>>, m, Nil{}))), dir ++ "/run/eval/")
    stg.bend.box(b, dir)
    IO.print("== the corpus, in plan order")
    +st : U32 <- Ob.obx.follow(tmp ++ "/push.log", False{}, ["TRAIN_ENV_FILE=" ++ envf, "SKIP_LINK_CHECK=1"], "bend-push", [host, port], None{})
    stg.ok(U32.is_eq(st, 0), "bend-push")
    IO.print("staged; on the box: cd " ++ dir ++ " && ./bend-box gate && ./bend-box time && ./bend-box run")
    S.rm(tmp)

# push ------------------------------------------------------------------------------------------

def stg.shards.send(ks: List<&2, List<&2, U32>>, +b: Rm.RmtBox, +dir: String, +name: String, +run: String) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +k <> t:
      do IO<Unit>:
        stg.send(b, [run ++ "/" ++ stg.shard(k, "fp100m")], dir ++ "/run/" ++ name ++ "/" ++ stg.shard(k, name))
        IO.print("shard " ++ S.str(k) ++ " landed")
        stg.shards.send(t, b, dir, name, run)

def stg.evalc.send(there: Bool, +b: Rm.RmtBox, +evalc: String, +dir: String) -> IO(Unit):
  match there:
    case True{}:
      stg.send(b, [evalc], dir ++ "/run/eval/")
    case False{}:
      IO.print("no " ++ evalc ++ " here; no eval corpus sent")

def stg.plan.got(m: Maybe<&2, List<&2, U32>>, +plan: String) -> IO(List<&2, U32>):
  match m:
    case Some{xs}:
      IO.pure(List<&2, U32>, xs)
    case None{}:
      IO.die(List<&2, U32>, 1, "stage push: cannot read " ++ plan)

# the plan moved into place, then the STAGED marker (a chain waiting for
# the plan starts on whole shards)
def stg.mark(+b: Rm.RmtBox, +at: String, +name: String) -> IO(Unit):
  +mv = "mv -f " ++ Rm.rmt.q(at ++ "plan-" ++ name ++ "-b16-windows.tsv.tmp") ++ " " ++ Rm.rmt.q(at ++ "plan-" ++ name ++ "-b16-windows.tsv")
  +touch = "touch " ++ Rm.rmt.q(at ++ "STAGED")
  do IO<Unit>:
    +o : Lc.LclOut <- Rm.rmt.ssh(b, 300, mv)
    stg.ssh.ok(o, mv)
    +p : Lc.LclOut <- Rm.rmt.ssh(b, 300, touch)
    stg.ssh.ok(p, touch)
    IO.print("STAGED: every shard matches")

def stg.staged(same: Bool, +b: Rm.RmtBox, +dir: String, +name: String) -> IO(Unit):
  match same:
    case True{}:
      stg.mark(b, dir ++ "/run/" ++ name ++ "/", name)
    case False{}:
      do IO<Unit>:
        IO.print("shard sums differ; not staged")
        IO.die(Unit, 1, "stage push: " ++ name ++ " not staged")

def stg.sums.of(+r: Rm.RmtSums) -> List<&2, Lc.LclSum>:
  match r:
    case Rm.RmtSums{a, s}:
      s

def stg.sums.answered(+r: Rm.RmtSums) -> Bool:
  match r:
    case Rm.RmtSums{a, s}:
      a

def stg.push(+name: String, +run: String, +host: String, +port: String) -> IO(Unit):
  +plan = run ++ "/plan-fp100m-b16-windows.tsv"
  do IO<Unit>:
    +dir : String <- stg.dir("formalTransformer")
    +evalc : String <- S.env("EVALC", "run/eval/transcript-" ++ name ++ ".corpus")
    m : Maybe<&2, List<&2, U32>> <- S.slurp(plan)
    +pl : List<&2, U32> <- stg.plan.got(m, plan)
    +ks : List<&2, List<&2, U32>> = stg.segments(pl)
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    stg.mkdirs(b, dir, ["run/" ++ name, "run/eval"])
    there : Bool <- S.exists(evalc)
    stg.evalc.send(there, b, evalc, dir)
    stg.shards.send(ks, b, dir, name, run)
    stg.send(b, [plan], dir ++ "/run/" ++ name ++ "/plan-" ++ name ++ "-b16-windows.tsv.tmp")
    # every byte checked before the marker
    +here : List<&2, Lc.LclSum> <- Lc.lcl.sums(run, stg.shards(ks, "fp100m"))
    +box : Rm.RmtSums <- Rm.rmt.sums(b, Rm.rmt.q(dir ++ "/run/" ++ name) ++ "/shard-*-" ++ Rm.rmt.q(name) ++ ".corpus")
    stg.staged(Bool.and(stg.sums.answered(box), stg.same(stg.rename(here, name), stg.sums.of(box))), b, dir, name)

# restage ---------------------------------------------------------------------------------------

def stg.ck.same(+here: Maybe<&2, List<&2, U32>>, +there: Maybe<&2, List<&2, U32>>) -> Bool:
  match here there:
    case Some{+a} Some{+b}:
      S.eq(a, b)
    case _ _:
      False{}

def stg.ck.say(same: Bool, +c: String, +ckpt: String) -> IO(Unit):
  match same:
    case True{}:
      stg.log("out/" ++ c ++ " landed, sha256 matches")
    case False{}:
      do IO<Unit>:
        stg.log("out/" ++ c ++ " differs from " ++ ckpt)
        IO.die(Unit, 1, "stage restage: out/" ++ c ++ " differs from " ++ ckpt)

# a STAGE word, NAME or NAME=RUN: its name, and its run directory (run/NAME)
def stg.stage.name(+s: String) -> String:
  S.str(Pu.upto(S.b(s), 61))

def stg.stage.run(+s: String) -> String:
  +xs = S.b(s)
  Bool.pick(String, S.infix(xs, [61]), S.str(List.drop(&2, U32, xs, Nat.add(S.len(Pu.upto(xs, 61)), 1n))), "run/" ++ s)

def stg.stage.push(+s: String, +host: String, +port: String) -> IO(Unit):
  stg.push(stg.stage.name(s), stg.stage.run(s), host, port)

def stg.stages(ss: List<&2, String>, +host: String, +port: String) -> IO(Unit):
  match ss:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +s <> t:
      do IO<Unit>:
        stg.stage.push(s, host, port)
        stg.log("stage " ++ s ++ " staged")
        stg.stages(t, host, port)

def stg.restage(+host: String, +port: String, +ckpt: String, +ss: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +dir : String <- stg.dir("formalTransformer")
    +b : Rm.RmtBox <- Rm.rmt.box(host, port)
    +tmp : String <- S.mktemp()
    stg.emit(tmp)
    stg.mkdirs(b, dir, ["weights", "run/eval", "out"])
    stg.send(b, stg.c.files(tmp), dir ++ "/")
    stg.send(b, ["weights/code32k.bpe"], dir ++ "/weights/")
    stg.send(b, ["run/eval/transcript-fp.corpus", "run/eval/transcript-next.corpus"], dir ++ "/run/eval/")
    S.rm(tmp)
    stg.bend.box(b, dir)
    stg.log("C, fp.sh, bend-box, tokenizer, eval corpora landed")
    stg.send(b, [ckpt], dir ++ "/out/")
    +c : String = S.base(ckpt)
    here : Maybe<&2, List<&2, U32>> <- Lc.lcl.sha256(ckpt)
    +box : Rm.RmtSums <- Rm.rmt.sums(b, stg.p(dir, "out/" ++ c))
    stg.ck.say(stg.ck.same(here, Lc.lcl.sha.of(stg.sums.of(box), S.b(c))), c, ckpt)
    stg.stages(ss, host, port)
    stg.log("restaged")

# dense-identity ----------------------------------------------------------------------------------
#
# The log's fields that are not the trajectory, removed as the script's sed did:
#   s/^\[[^]]*\] //   s/ (ms|tok\/s|remaining|eta)=[^ ]*//g   s/, store [0-9]+ floats//

def stg.stamp.cut(+l: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case Some{+k}:
      Bool.pick(List<&2, U32>, Bool.and(S.head.is(l, 91), U32.is_eq(Lc.lcl.at(l, Nat.add(k, 1n)), 32)), List.drop(&2, U32, l, Nat.add(k, 2n)), l)
    case None{}:
      l

# s/^\[[^]]*\] //
def stg.unstamp(+l: List<&2, U32>) -> List<&2, U32>:
  stg.stamp.cut(l, S.find(l, [93], 0n))

def stg.field.at(+xs: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.prefix(xs, S.b(" ms=")), 4n, Bool.pick(Nat, S.prefix(xs, S.b(" tok/s=")), 7n,
    Bool.pick(Nat, S.prefix(xs, S.b(" remaining=")), 11n, Bool.pick(Nat, S.prefix(xs, S.b(" eta=")), 5n, 0n))))

def stg.nonsp(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      stg.nonsp(t, Bool.and(Nat.is_lt(0n, S.len(t)), U32.is_ne(Lc.lcl.at(t, 0n), 32)))
    case r _:
      r

def stg.drop.field(+xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  +r = List.drop(&2, U32, xs, n)
  stg.nonsp(r, Bool.and(Nat.is_lt(0n, S.len(r)), U32.is_ne(Lc.lcl.at(r, 0n), 32)))

def stg.unfield.go(fuel: Nat, xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  match fuel xs n:
    case 0n _ _:
      xs
    case _ Nil{} _:
      Nil{}
    case 1n+f +h <> +t 0n:
      h <> stg.unfield.go(f, t, stg.field.at(t))
    case 1n+f +h <> +t 1n+k:
      +r = stg.drop.field(h <> t, 1n+k)
      stg.unfield.go(f, r, stg.field.at(r))

# s/ (ms|tok\/s|remaining|eta)=[^ ]*//g
def stg.unfield(+xs: List<&2, U32>) -> List<&2, U32>:
  stg.unfield.go(1n+S.len(xs), xs, stg.field.at(xs))

# s/, store [0-9]+ floats//: the leftmost match
def stg.store.at(+xs: List<&2, U32>) -> Nat:
  +r = List.drop(&2, U32, xs, 8n)
  +d = Ob.obx.lead(r)
  Bool.pick(Nat, Bool.and(S.prefix(xs, S.b(", store ")), Bool.and(Nat.is_lt(0n, d), S.prefix(List.drop(&2, U32, r, d), S.b(" floats")))),
    Nat.add(Nat.add(8n, d), 7n), 0n)

def stg.unstore.go(xs: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  match xs n:
    case Nil{} _:
      Nil{}
    case +h <> +t 0n:
      h <> stg.unstore.go(t, stg.store.at(t))
    case +h <> +t 1n+k:
      List.drop(&2, U32, h <> t, 1n+k)

def stg.unstore(+xs: List<&2, U32>) -> List<&2, U32>:
  stg.unstore.go(xs, stg.store.at(xs))

def stg.norm.lines(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      stg.unstore(stg.unfield(stg.unstamp(l))) <> stg.norm.lines(t)

# the raw log without the fields that are not the trajectory (sed's lines:
# a last line without its newline stays without one)
def stg.norm(+xs: List<&2, U32>) -> List<&2, U32>:
  +ls = stg.norm.lines(S.split.lines(xs))
  Bool.pick(List<&2, U32>, S.suffix(xs, [10]), Ob.obx.unlines(ls), S.join(ls, 10))

def stg.trainer.got(m: Maybe<&2, String>) -> IO(String):
  match m:
    case Some{+t}:
      Ob.obx.self(t)
    case None{}:
      do IO<String>:
        o : List<&2, U32> <- S.must("nix build .#bend-train-dense", "nix", ["build", "--no-link", "--print-out-paths", ".#bend-train-dense"])
        return S.str(S.chomp(o)) ++ "/bin/bend-train-dense"

def stg.ident.one(+out: String, +corpus: String, +tr: String, +opt: String) -> IO(Unit):
  do IO<Unit>:
    +st : U32 <- S.run.log(out, ["CORPUS=" ++ corpus, "PRESET=small4-v3", "TRAIN_STEPS=6", "TRAIN_BATCH=8", "TRAIN_MICRO=4", "TRAIN_LR=3e-3",
      "TRAIN_WARMUP=2", "TRAIN_OPT=" ++ opt, "EVAL_EVERY=3", "OUT=" ++ opt ++ ".btc"], 86400, tr, ["--gpu", "off", "--threads", "4"], opt ++ ".raw.log")
    stg.ok(U32.is_eq(st, 0), "bend-train-dense " ++ opt ++ " (exit " ++ U32.show(st) ++ ")")
    +raw : List<&2, U32> <- S.read(out ++ "/" ++ opt ++ ".raw.log")
    S.write(out ++ "/" ++ opt ++ ".log", stg.norm(raw))
    S.rm(out ++ "/" ++ opt ++ ".raw.log")

def stg.ext(ns: List<&2, List<&2, U32>>, +ext: String, +out: String) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      +rest = stg.ext(t, ext, out)
      Bool.pick(List<&2, String>, Bool.and(S.suffix(n, S.b(ext)), Bool.not(S.head.is(n, 46))), (out ++ "/" ++ S.str(n)) <> rest, rest)

def stg.ident(+out: String, m: Maybe<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +tr : String <- stg.trainer.got(m)
    +repo : String <- S.realpath(".")
    S.mkdir(out)
    stg.ident.one(out, repo ++ "/docs/haskell-era/RUN-2026-07-25-WIKI-FULL.md", tr, "adamw")
    stg.ident.one(out, repo ++ "/docs/haskell-era/RUN-2026-07-25-WIKI-FULL.md", tr, "muon")
    ns : Maybe<&2, List<&2, List<&2, U32>>> <- Lc.lcl.ls(out)
    +names : List<&2, List<&2, U32>> = Maybe.default(&2, List<&2, List<&2, U32>>, ns, Nil{})
    +o : Lc.LclOut <- Lc.lcl.run(86400, "sha256sum", stg.l1(List.append(&2, String, stg.ext(names, ".btc", out), stg.ext(names, ".log", out))))
    Ob.obx.pass(o)

def stg.ident.go(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case +out <> Nil{}:
      stg.ident(out, None{})
    case +out <> +tr <> Nil{}:
      stg.ident(out, Some{tr})
    case _:
      IO.die(Unit, 2, "usage: bend-ops dense-identity OUT_DIR [TRAINER]")

def stg.ident.main(xs: List<String>) -> IO(Unit):
  stg.ident.go(Ob.obx.l2(xs))

# Main ------------------------------------------------------------------------------------------

def stg.shards.say(ks: List<&2, List<&2, U32>>) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +k <> t:
      do IO<Unit>:
        IO.print(S.str(k))
        stg.shards.say(t)

def stg.usage() -> String:
  "usage: bend-ops stage box HOST PORT | push NAME RUN HOST PORT | restage HOST PORT CKPT STAGE... | shards PLAN"

def stg.go(xs: List<&2, String>) -> IO(Unit):
  match xs:
    case "box" <> +host <> +port <> Nil{}:
      stg.box(host, port)
    case "push" <> +name <> +run <> +host <> +port <> Nil{}:
      stg.push(name, run, host, port)
    case "restage" <> +host <> +port <> +ckpt <> +ss:
      stg.restage(host, port, ckpt, ss)
    case "shards" <> +plan <> Nil{}:
      do IO<Unit>:
        +pl : List<&2, U32> <- S.read(plan)
        stg.shards.say(stg.segments(pl))
    case _:
      IO.die(Unit, 2, stg.usage())

def stg.main(xs: List<String>) -> IO(Unit):
  stg.go(Ob.obx.l2(xs))
