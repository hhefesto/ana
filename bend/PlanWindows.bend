import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./Clock.bend as Ck

# bend-plan-windows: the transcript corpus as training shards and a run
# plan: the languages' train transcripts interleaved, packed whole into
# one-context windows (bend-windows), the gap in each window the end of a
# code file.
#
#   bend-plan-windows RUN_DIR SIZE BATCH LANG:PER[:cycle] ...
#
# LANG's transcripts are $OUT/LANG/transcripts.train.nul (OUT: run/transcripts,
# what bend-transcripts wrote).  The mix is bend-mix's: each round takes
# PER transcripts of every language in the order given; a language that
# runs dry drops out, or with :cycle starts again (ids suffixed #c<n>);
# the mix ends when every language without :cycle has run dry.  The filler
# is the same languages' source files (files-hi.nul, then files-lo.nul),
# interleaved the same way without cycling, minus every file a holdout unit
# was cut from (results.holdout.nul), so no held-out unit's code is trained
# on.
#
# The mix is cut into shards of SHARD transcripts (20000).  Shard k:
# bend-prepare tokenizes its transcripts and filler slice k (FILL files,
# default an equal share: all the filler files over the shards, rounded up;
# the windows take the best-fitting filler files, and SHARD / 2 ran one
# Nix shard dry), bend-windows plans and builds its windows (CAPACITY
# tokens each, 2046: a context of 2048 less BOS and EOS), and the windows,
# ids w<k>-<n>, are RUN_DIR/shard-k-SIZE.corpus, one document each.  Shards
# are built JOBS at a time (4).  Then bend-plan-segment plans every shard
# at its offset (the windows before it) and RUN_DIR/plan-SIZE-bBATCH-windows.tsv
# is written in master's format: `plan 1 STEPS IDENTITY ...` then one
# `segment` line per shard.  What exists is kept: a rerun resumes.
#
# Environment: OUT, TOKENIZER (weights/code32k.bpe), CAPACITY, SHARD, FILL,
# JOBS, and the tools BEND_MIX, BEND_PREPARE, BEND_WINDOWS,
# BEND_PLAN_SEGMENT (default: bend-mix, bend-prepare, bend-windows,
# bend-plan-segment on PATH).

def say(+msg: String) -> IO(Unit):
  Ck.log("plan-windows: " ++ msg)

def big() -> Nat:
  1000000000n

def forever() -> U32:
  2000000

def pad6(+i: Nat) -> String:
  +s = Nat.show(i)
  String.concat(List.replicate(String, Nat.sub(6n, String.length(s)), "0")) ++ s

# Languages ------------------------------------------------------------------

# LANG:PER[:cycle]
type Spec is Data:
  Spec{lang: String, per: String, rest: String}

def upto(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), Nil{}, h <> upto(t, c))

def after(xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, c), t, after(t, c))

def spec(+s: String) -> Spec:
  +xs = S.b(s)
  +r = after(xs, 58)
  Spec{S.str(upto(xs, 58)), S.str(upto(r, 58)), S.str(after(r, 58))}

def specs(xs: List<String>) -> List<&2, Spec>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      spec(x) <> specs(more)

# Conversions: NUL pairs to JSON lines (bend-mix's input) and back -------------

type Cv is Type:
  Cv{rd: S.Rd, out: File, excl: Set(), n: Nat, go: Bool}

def cv.emit(out: Bool, rd: S.Rd, o: File, excl: Set(), +n: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(Cv):
  match out:
    case True{}:
      IO.pure(Cv, Cv{rd, o, excl, n, True{}})
    case False{}:
      do IO<Cv>:
        o2 : File <- S.emit(o, S.append(J.line(id, t), [10]))
        return Cv{rd, o2, excl, 1n+n, True{}}

def cv.keep(r: Set() & Bool, rd: S.Rd, o: File, +n: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(Cv):
  (excl, out) = r
  cv.emit(out, rd, o, excl, n, id, t)

def cv.text(rd: S.Rd, o: File, excl: Set(), +n: Nat, +id: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> IO(Cv):
  match m:
    case None{}:
      do IO<Cv>:
        S.Rd.close(rd)
        File.close(o)
        IO.die(Cv, 1, "plan-windows: a NUL stream ends after an id")
    case Some{+t}:
      cv.keep(Set.has(excl, S.str(id)), rd, o, n, id, t)

def cv.text.pair(o: File, excl: Set(), +n: Nat, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Cv):
  (rd, m) = r
  cv.text(rd, o, excl, n, id, m)

def cv.id(rd: S.Rd, o: File, excl: Set(), +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Cv):
  match m:
    case None{}:
      IO.pure(Cv, Cv{rd, o, excl, n, False{}})
    case Some{+id}:
      do IO<Cv>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        cv.text.pair(o, excl, n, id, r)

def cv.id.pair(o: File, excl: Set(), +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Cv):
  (rd, m) = r
  cv.id(rd, o, excl, n, m)

def cv.step(c: Cv) -> IO(Cv):
  match c:
    case Cv{rd, o, excl, +n, g}:
      do IO<Cv>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        cv.id.pair(o, excl, n, r)

def cv.go(fuel: Nat, c: Cv) -> IO(Nat):
  match fuel c:
    case 1n+f Cv{rd, o, excl, n, True{}}:
      IO.bind(Cv, Nat, cv.step(Cv{rd, o, excl, n, True{}}), cv.go(f))
    case _ Cv{rd, o, excl, n, g}:
      do IO<Nat>:
        S.Rd.close(rd)
        File.close(o)
        return n

# the pairs of a NUL file as JSON lines at the end of out (mode "w" or "a"),
# every pair whose id is in excl left out; the lines written
def to.jsonl(+inp: String, +out: String, +mode: String, excl: Set()) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.open(inp)
    o : File <- IO.try(File, File.open(out, mode))
    cv.go(big(), Cv{rd, o, excl, 0n, True{}})

type Cj is Type:
  Cj{rd: S.Rd, out: File, n: Nat, go: Bool}

def cj.doc(rd: S.Rd, o: File, +n: Nat, d: Maybe<&2, J.Doc>) -> IO(Cj):
  match d:
    case None{}:
      do IO<Cj>:
        S.Rd.close(rd)
        File.close(o)
        IO.die(Cj, 1, "plan-windows: the mix has a line that is not an {\"id\", \"text\"} object")
    case Some{J.Doc{id, t}}:
      do IO<Cj>:
        o2 : File <- S.emit(o, S.append(id, 0 <> S.append(t, [0])))
        return Cj{rd, o2, 1n+n, True{}}

def cj.line(rd: S.Rd, o: File, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Cj):
  match m:
    case None{}:
      IO.pure(Cj, Cj{rd, o, n, False{}})
    case Some{+l}:
      cj.doc(rd, o, n, J.doc(l))

def cj.pair(o: File, +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Cj):
  (rd, m) = r
  cj.line(rd, o, n, m)

def cj.step(c: Cj) -> IO(Cj):
  match c:
    case Cj{rd, o, +n, g}:
      do IO<Cj>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        cj.pair(o, n, r)

def cj.go(fuel: Nat, c: Cj) -> IO(Nat):
  match fuel c:
    case 1n+f Cj{rd, o, n, True{}}:
      IO.bind(Cj, Nat, cj.step(Cj{rd, o, n, True{}}), cj.go(f))
    case _ Cj{rd, o, n, g}:
      do IO<Nat>:
        S.Rd.close(rd)
        File.close(o)
        return n

def to.nul(+inp: String, +out: String) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.lines(inp)
    o : File <- IO.try(File, File.open(out, "w"))
    cj.go(big(), Cj{rd, o, 0n, True{}})

# The file ids the holdout units were cut from (`FILE#name@line`) -------------

type Hx is Type:
  Hx{rd: S.Rd, s: Set(), odd: Bool, go: Bool}

def hx.got(rd: S.Rd, s: Set(), odd: Bool, m: Maybe<&2, List<&2, U32>>) -> Hx:
  match odd m:
    case _ None{}:
      Hx{rd, s, False{}, False{}}
    case False{} Some{id}:
      Hx{rd, Set.add(s, S.str(upto(id, 35))), True{}, True{}}
    case True{} Some{rec}:
      Hx{rd, s, False{}, True{}}

def hx.pair(s: Set(), odd: Bool, r: S.Rd & Maybe<&2, List<&2, U32>>) -> Hx:
  (rd, m) = r
  hx.got(rd, s, odd, m)

def hx.step(h: Hx) -> IO(Hx):
  match h:
    case Hx{rd, s, odd, g}:
      do IO<Hx>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return hx.pair(s, odd, r)

def hx.go(fuel: Nat, h: Hx) -> IO(Set()):
  match fuel h:
    case 1n+f Hx{rd, s, odd, True{}}:
      IO.bind(Hx, Set(), hx.step(Hx{rd, s, odd, True{}}), hx.go(f))
    case _ Hx{rd, s, odd, g}:
      do IO<Set()>:
        S.Rd.close(rd)
        return s

def held(+path: String) -> IO(Set()):
  do IO<Set()>:
    rd : S.Rd <- S.Rd.open(path)
    hx.go(big(), Hx{rd, Set.new(), False{}, True{}})

# The mixes ------------------------------------------------------------------

# each language's transcripts as JSON lines, and its mix argument
def mix.tr.srcs(+out: String, +src: String, ss: List<&2, Spec>) -> IO(List<String>):
  match ss:
    case Nil{}:
      IO.pure(List<String>, Nil{})
    case Spec{+l, +per, +rest} <> more:
      +j = src ++ "/" ++ l ++ ".transcripts.jsonl"
      do IO<List<String>>:
        +n : Nat <- to.jsonl(out ++ "/" ++ l ++ "/transcripts.train.nul", j, "w", Set.new())
        say(l ++ ": " ++ Nat.show(n) ++ " train transcripts")
        xs : List<String> <- mix.tr.srcs(out, src, more)
        return (j ++ ":" ++ per ++ Bool.pick(String, String.is_empty(rest), "", ":" ++ rest)) <> xs

# each language's source files, the holdout's files left out, as JSON lines
def mix.fl.srcs(+out: String, +src: String, ss: List<&2, Spec>) -> IO(List<String>):
  match ss:
    case Nil{}:
      IO.pure(List<String>, Nil{})
    case Spec{+l, +per, +rest} <> more:
      +j = src ++ "/" ++ l ++ ".files.jsonl"
      do IO<List<String>>:
        +ex : Set() <- held(out ++ "/" ++ l ++ "/results.holdout.nul")
        +a : Nat <- to.jsonl(out ++ "/" ++ l ++ "/files-hi.nul", j, "w", ex)
        +b : Nat <- to.jsonl(out ++ "/" ++ l ++ "/files-lo.nul", j, "a", ex)
        say(l ++ ": " ++ Nat.show(Nat.add(a, b)) ++ " filler files (" ++ Nat.show(Set.size(ex)) ++ " holdout files left out)")
        xs : List<String> <- mix.fl.srcs(out, src, more)
        return (j ++ ":" ++ per) <> xs

def ran(+st: U32, +what: String, +log: String) -> IO(Unit):
  Bool.pick(IO(Unit), U32.is_eq(st, 0), IO.pure(Unit, Unit{}),
    IO.die(Unit, 1, "plan-windows: " ++ what ++ " failed (exit " ++ U32.show(st) ++ "), see " ++ log))

# JSON lines through bend-mix, then back to NUL pairs
def mixed(+dir: String, +name: String, +bm: String, args: List<String>) -> IO(Unit):
  +j = dir ++ "/" ++ name ++ ".jsonl"
  do IO<Unit>:
    +st : U32 <- S.run.log(".", [], forever(), bm, j <> args, dir ++ "/" ++ name ++ ".mix.log")
    ran(st, "bend-mix (" ++ name ++ ")", dir ++ "/" ++ name ++ ".mix.log")
    +n : Nat <- to.nul(j, dir ++ "/" ++ name ++ ".nul.tmp")
    S.mv(dir ++ "/" ++ name ++ ".nul.tmp", dir ++ "/" ++ name ++ ".nul")
    S.rm(j)
    say(name ++ ": " ++ Nat.show(n) ++ " documents")

def mix.if(done: Bool, +dir: String, +out: String, +bm: String, +ss: List<&2, Spec>) -> IO(Unit):
  match done:
    case True{}:
      say("the mixes exist")
    case False{}:
      do IO<Unit>:
        S.mkdir(dir ++ "/src")
        tr : List<String> <- mix.tr.srcs(out, dir ++ "/src", ss)
        mixed(dir, "mix", bm, tr)
        fl : List<String> <- mix.fl.srcs(out, dir ++ "/src", ss)
        mixed(dir, "filler", bm, fl)
        S.rm(dir ++ "/src")

# Parts: the pairs of a NUL file cut into files of n pairs ---------------------

type Sp is Type:
  Sp{rd: S.Rd, k: Nat, i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>, go: Bool}

def nul.all(fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      Nil{}
    case f <> more:
      List.append(&2, U32, f, 0 <> nul.all(more))

def sp.flush(+pre: String, +k: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>) -> IO(List<&2, String>):
  +path = pre ++ "-" ++ pad6(k) ++ ".nul"
  do IO<List<&2, String>>:
    S.write(path, nul.all(List.reverse(&2, List<&2, U32>, acc)))
    return path <> paths

def sp.put(full: Bool, +pre: String, rd: S.Rd, +k: Nat, +i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>) -> IO(Sp):
  match full:
    case True{}:
      do IO<Sp>:
        ps : List<&2, String> <- sp.flush(pre, k, acc, paths)
        return Sp{rd, 1n+k, 0n, Nil{}, ps, True{}}
    case False{}:
      IO.pure(Sp, Sp{rd, k, i, acc, paths, True{}})

def sp.end(+pre: String, rd: S.Rd, +k: Nat, i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>) -> IO(Sp):
  match i:
    case 0n:
      IO.pure(Sp, Sp{rd, k, 0n, Nil{}, paths, False{}})
    case 1n+j:
      do IO<Sp>:
        ps : List<&2, String> <- sp.flush(pre, k, acc, paths)
        return Sp{rd, 1n+k, 0n, Nil{}, ps, False{}}

def sp.got(+n: Nat, +pre: String, rd: S.Rd, +k: Nat, +i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>, m: Maybe<&2, List<&2, U32>>) -> IO(Sp):
  match m:
    case None{}:
      sp.end(pre, rd, k, i, acc, paths)
    case Some{f}:
      sp.put(Nat.is_eq(1n+i, Nat.mul(2n, n)), pre, rd, k, 1n+i, f <> acc, paths)

def sp.pair(+n: Nat, +pre: String, +k: Nat, +i: Nat, acc: List<&2, List<&2, U32>>, paths: List<&2, String>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Sp):
  (rd, m) = r
  sp.got(n, pre, rd, k, i, acc, paths, m)

def sp.step(+n: Nat, +pre: String, s: Sp) -> IO(Sp):
  match s:
    case Sp{rd, +k, +i, acc, paths, g}:
      do IO<Sp>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        sp.pair(n, pre, k, i, acc, paths, r)

def sp.go(fuel: Nat, +n: Nat, +pre: String, s: Sp) -> IO(Nat):
  match fuel s:
    case 1n+p Sp{rd, k, i, acc, paths, True{}}:
      IO.bind(Sp, Nat, sp.step(n, pre, Sp{rd, k, i, acc, paths, True{}}), sp.go(p, n, pre))
    case _ Sp{rd, k, i, acc, paths, g}:
      do IO<Nat>:
        S.Rd.close(rd)
        return k

# the files written (named pre-000000.nul, ...)
def split(+path: String, +n: Nat, +pre: String) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.open(path)
    sp.go(big(), n, pre, Sp{rd, 0n, 0n, Nil{}, Nil{}, True{}})

type Pt is Data:
  Pt{shards: Nat, fills: Nat}

# the records of a NUL-framed id/text file
type Cn is Type:
  Cn{rd: S.Rd, n: Nat, go: Bool}

def cn.got(rd: S.Rd, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> Cn:
  match m:
    case None{}:
      Cn{rd, n, False{}}
    case Some{x}:
      Cn{rd, 1n+n, True{}}

def cn.pair(+n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> Cn:
  (rd, m) = r
  cn.got(rd, n, m)

def cn.step(s: Cn) -> IO(Cn):
  match s:
    case Cn{rd, +n, g}:
      do IO<Cn>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return cn.pair(n, r)

def cn.go(fuel: Nat, s: Cn) -> IO(Nat):
  match fuel s:
    case 1n+p Cn{rd, n, True{}}:
      IO.bind(Cn, Nat, cn.step(Cn{rd, n, True{}}), cn.go(p))
    case _ Cn{rd, n, g}:
      do IO<Nat>:
        S.Rd.close(rd)
        return Nat.div(n, 2n)

def count(+path: String) -> IO(Nat):
  do IO<Nat>:
    rd : S.Rd <- S.Rd.open(path)
    cn.go(big(), Cn{rd, 0n, True{}})

# FILL, or (0) the total over k shards rounded up
def share(+fill: Nat, +total: Nat, +k: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(fill, 0n),
    Bool.pick(Nat, Nat.is_eq(k, 0n), Nat.add(total, 1n), Nat.div(Nat.add(total, Nat.sub(k, 1n)), k)), fill)

def nth(xs: List<&2, List<&2, U32>>, n: Nat) -> List<&2, U32>:
  match xs n:
    case x <> more 0n:
      x
    case x <> more 1n+k:
      nth(more, k)
    case Nil{} _:
      Nil{}

def nat.of(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

def parts.if(done: Bool, +dir: String, +shard: Nat, +fill: Nat) -> IO(Pt):
  match done:
    case True{}:
      do IO<Pt>:
        xs : List<&2, U32> <- S.read(dir ++ "/parts/done")
        +ws : List<&2, List<&2, U32>> = S.split(S.chomp(xs), 32)
        return Pt{nat.of(nth(ws, 0n)), nat.of(nth(ws, 1n))}
    case False{}:
      do IO<Pt>:
        S.mkdir(dir ++ "/parts")
        +k : Nat <- split(dir ++ "/mix.nul", shard, dir ++ "/parts/part")
        +total : Nat <- count(dir ++ "/filler.nul")
        +each : Nat = share(fill, total, k)
        +f : Nat <- split(dir ++ "/filler.nul", each, dir ++ "/parts/fill")
        S.write(dir ++ "/parts/done", S.b(Nat.show(k) ++ " " ++ Nat.show(f) ++ "\n"))
        say(Nat.show(k) ++ " shards of " ++ Nat.show(shard) ++ " transcripts, " ++ Nat.show(f) ++ " filler slices of " ++ Nat.show(each) ++ " of " ++ Nat.show(total) ++ " files")
        return Pt{k, f}

# A shard: commands run in order, the first failure ending it ------------------

type Cf is Data:
  Cf{dir: String, size: String, tok: String, cap: String, prep: String, win: String}

def Cf.shard(+c: Cf, +k: Nat) -> String:
  match c:
    case Cf{d, z, t, p, r, w}:
      d ++ "/shard-" ++ Nat.show(k) ++ "-" ++ z ++ ".corpus"

type Rn is Type:
  Rn{cmds: List<List<String>>, err: String, go: Bool}

def rn.out(+c: String, o: S.Out, more: List<List<String>>) -> Rn:
  match o:
    case S.Out{+st, +t}:
      Bool.pick(Rn, U32.is_eq(st, 0), Rn{more, "", True{}},
        Rn{Nil{}, c ++ " failed (exit " ++ U32.show(st) ++ "): " ++ S.str(S.lines.take(t, 12n)), False{}})

def rn.step(r: Rn) -> IO(Rn):
  match r:
    case Rn{Nil{}, e, g}:
      IO.pure(Rn, Rn{Nil{}, e, False{}})
    case Rn{(+p <> args) <> more, e, g}:
      do IO<Rn>:
        o : S.Out <- S.run(".", [], forever(), p, args, Nil{})
        return rn.out(p, o, more)
    case Rn{Nil{} <> more, e, g}:
      IO.pure(Rn, Rn{more, e, True{}})

def rn.go(fuel: Nat, r: Rn) -> IO(String):
  match fuel r:
    case 1n+f Rn{cmds, e, True{}}:
      IO.bind(Rn, String, rn.step(Rn{cmds, e, True{}}), rn.go(f))
    case _ Rn{cmds, e, g}:
      IO.pure(String, e)

def cmds(+c: Cf, +k: Nat) -> List<List<String>>:
  match c:
    case Cf{+d, +z, +t, +cap, +prep, +win}:
      +p = d ++ "/parts/part-" ++ pad6(k)
      +f = d ++ "/parts/fill-" ++ pad6(k)
      +out = Cf.shard(Cf{d, z, t, cap, prep, win}, k)
      [[prep, "--threads", "1", t, p ++ ".nul", p ++ ".corpus"],
       [win, "lengths", p ++ ".corpus"],
       [prep, "--threads", "1", t, f ++ ".nul", f ++ ".corpus"],
       [win, "lengths", f ++ ".corpus"],
       [win, "plan", p ++ ".corpus.lengths", f ++ ".corpus.lengths", cap, p ++ ".plan"],
       [win, "build", p ++ ".corpus", f ++ ".corpus", p ++ ".plan", out ++ ".tmp", cap, "w" ++ pad6(k)],
       ["mv", out ++ ".tmp", out],
       ["rm", "-f", p ++ ".corpus", f ++ ".corpus", p ++ ".corpus.lengths", f ++ ".corpus.lengths"]]

def say.if(yes: Bool, +msg: String) -> IO(Unit):
  match yes:
    case True{}:
      say(msg)
    case False{}:
      IO.pure(Unit, Unit{})

def job.if(there: Bool, +c: Cf, +k: Nat) -> IO(String):
  match there:
    case True{}:
      IO.pure(String, "")
    case False{}:
      do IO<String>:
        +e : String <- rn.go(64n, Rn{cmds(c, k), "", True{}})
        say.if(String.is_empty(e), "shard " ++ Nat.show(k) ++ " built")
        return Bool.pick(String, String.is_empty(e), "", "shard " ++ Nat.show(k) ++ ": " ++ e)

def job(+c: Cf, +k: Nat) -> IO(String):
  do IO<String>:
    +there : Bool <- S.exists(Cf.shard(c, k))
    job.if(there, c, k)

# The pool: JOBS workers take shard numbers from a channel --------------------

type Wk is Type:
  Wk{errs: List<&2, String>, go: Bool}

def wk.got(+c: Cf, m: Maybe<&1, Nat>, +errs: List<&2, String>) -> IO(Wk):
  match m:
    case None{}:
      IO.pure(Wk, Wk{errs, False{}})
    case Some{+k}:
      do IO<Wk>:
        +e : String <- job(c, k)
        return Wk{Bool.pick(List<&2, String>, String.is_empty(e), errs, e <> errs), True{}}

def wk.step(+c: Cf, +q: Chan(Nat), w: Wk) -> IO(Wk):
  match w:
    case Wk{errs, g}:
      do IO<Wk>:
        m : Maybe<&1, Nat> <- Chan.recv(Nat, q)
        wk.got(c, m, errs)

def wk.go(fuel: Nat, +c: Cf, +q: Chan(Nat), w: Wk) -> IO(List<&2, String>):
  match fuel w:
    case 1n+f Wk{errs, True{}}:
      IO.bind(Wk, List<&2, String>, wk.step(c, q, Wk{errs, True{}}), wk.go(f, c, q))
    case _ Wk{errs, g}:
      IO.pure(List<&2, String>, errs)

def forks(n: Nat, +c: Cf, +q: Chan(Nat)) -> IO(List<Chan(List<&2, String>)>):
  match n:
    case 0n:
      IO.pure(List<Chan(List<&2, String>)>, Nil{})
    case 1n+m:
      do IO<List<Chan(List<&2, String>)>>:
        ch : Chan(List<&2, String>) <- IO.fork(List<&2, String>, wk.go(big(), c, q, Wk{Nil{}, True{}}))
        rest : List<Chan(List<&2, String>)> <- forks(m, c, q)
        return ch <> rest

def joins(chs: List<Chan(List<&2, String>)>, errs: List<&2, String>) -> IO(List<&2, String>):
  match chs:
    case Nil{}:
      IO.pure(List<&2, String>, errs)
    case +ch <> more:
      do IO<List<&2, String>>:
        e : List<&2, String> <- IO.join(List<&2, String>, ch)
        joins(more, List.append(&2, String, e, errs))

def sends(n: Nat, +k: Nat, +q: Chan(Nat)) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+m:
      do IO<Unit>:
        ok : Bool <- Chan.send(Nat, q, k)
        sends(m, 1n+k, q)

def lines(es: List<&2, String>) -> String:
  match es:
    case Nil{}:
      ""
    case e <> more:
      "\n  " ++ e ++ lines(more)

def errs.none(es: List<&2, String>) -> IO(Unit):
  match es:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case e <> more:
      IO.die(Unit, 1, "plan-windows: shards failed:" ++ lines(e <> more))

def build(+c: Cf, +shards: Nat, +jobs: Nat) -> IO(Unit):
  do IO<Unit>:
    say("building " ++ Nat.show(shards) ++ " shards, " ++ Nat.show(jobs) ++ " at a time")
    +q : Chan(Nat) <- Chan.new(Nat, U32.from_nat(jobs))
    chs : List<Chan(List<&2, String>)> <- forks(jobs, c, q)
    sends(shards, 0n, q)
    Chan.close(Nat, q)
    es : List<&2, String> <- joins(chs, Nil{})
    errs.none(es)

# The plan: every shard planned at its offset, in order -------------------------

type Pl is Data:
  Pl{k: Nat, off: Nat, cum: Nat, segs: List<&2, List<&2, U32>>}

def seg.out(+k: Nat, +off: Nat, +cum: Nat, segs: List<&2, List<&2, U32>>, o: S.Out) -> IO(Pl):
  match o:
    case S.Out{+st, +t}:
      +ws = S.split(S.lines.first(t), 32)
      +docs = nat.of(nth(ws, 2n))
      +steps = nat.of(nth(ws, 6n))
      +line = S.b("segment " ++ Nat.show(k) ++ " " ++ Nat.show(off) ++ " " ++ S.str(nth(ws, 2n)) ++ " " ++ S.str(nth(ws, 3n)) ++ " "
        ++ S.str(nth(ws, 4n)) ++ " " ++ S.str(nth(ws, 5n)) ++ " " ++ S.str(nth(ws, 6n)) ++ " " ++ Nat.show(cum) ++ " " ++ Nat.show(Nat.add(cum, steps)) ++ "\n")
      +ok = Bool.and(U32.is_eq(st, 0), Bool.and(S.eq(nth(ws, 0n), S.b("segment")), S.eq(nth(ws, 1n), S.b(Nat.show(off)))))
      Bool.pick(IO(Pl), ok, IO.pure(Pl, Pl{1n+k, Nat.add(off, docs), Nat.add(cum, steps), line <> segs}),
        IO.die(Pl, 1, "plan-windows: plan-segment failed for shard " ++ Nat.show(k) ++ " (exit " ++ U32.show(st) ++ "): " ++ S.str(S.chomp(t))))

def Cf.size(+c: Cf) -> String:
  match c:
    case Cf{d, z, t, p, r, w}:
      z

def seg.step(+c: Cf, +ps: String, +batch: String, p: Pl) -> IO(Pl):
  match p:
    case Pl{+k, +off, +cum, segs}:
      do IO<Pl>:
        o : S.Out <- S.run(".", [], forever(), ps, ["--threads", "1", Cf.shard(c, k), Nat.show(off), batch, Cf.size(c)], Nil{})
        seg.out(k, off, cum, segs, o)

def seg.go(n: Nat, +c: Cf, +ps: String, +batch: String, p: Pl) -> IO(Pl):
  match n:
    case 0n:
      IO.pure(Pl, p)
    case 1n+m:
      IO.bind(Pl, Pl, seg.step(c, ps, batch, p), seg.go(m, c, ps, batch))

def sha(+path: String) -> IO(String):
  do IO<String>:
    xs : List<&2, U32> <- S.must("sha256sum " ++ path, "sha256sum", [path])
    return S.str(upto(xs, 32))

# the header's fields after the step total, given the windows planned
def ids(+hm: String, +ht: String, +shard: Nat, +batch: String, +size: String, +cap: String, +n: Nat) -> String:
  "windows-v1:sha256=" ++ hm ++ ":windows=" ++ Nat.show(n) ++ ":shard=" ++ Nat.show(shard) ++ ":batch=" ++ batch ++ ":size=" ++ size
    ++ ":capacity=" ++ cap ++ ":tokenizer=" ++ ht ++ " " ++ hm ++ " " ++ Nat.show(n) ++ " " ++ Nat.show(shard) ++ " " ++ batch ++ " " ++ size ++ " " ++ ht

def plan.write(+plan: String, +hm: String, +ht: String, +shard: Nat, +batch: String, +size: String, +cap: String, +shards: Nat, p: Pl) -> IO(Unit):
  match p:
    case Pl{k, +off, +cum, segs}:
      do IO<Unit>:
        S.write(plan ++ ".tmp", S.append(S.b("plan 1 " ++ Nat.show(cum) ++ " " ++ ids(hm, ht, shard, batch, size, cap, off) ++ "\n"), List.concat(&2, U32, List.reverse(&2, List<&2, U32>, segs))))
        S.mv(plan ++ ".tmp", plan)
        say("wrote " ++ plan ++ ": " ++ Nat.show(off) ++ " windows, " ++ Nat.show(cum) ++ " global steps over " ++ Nat.show(shards) ++ " shards")

def plan.make(c: Cf, +plan: String, +ps: String, +batch: String, +shard: Nat, +shards: Nat) -> IO(Unit):
  match c:
    case Cf{+d, +z, +t, +cap, +prep, +win}:
      do IO<Unit>:
        +hm : String <- sha(d ++ "/mix.nul")
        +ht : String <- sha(t)
        p : Pl <- seg.go(shards, Cf{d, z, t, cap, prep, win}, ps, batch, Pl{0n, 0n, 0n, Nil{}})
        plan.write(plan, hm, ht, shard, batch, z, cap, shards, p)

def plan.if(there: Bool, +c: Cf, +plan: String, +ps: String, +batch: String, +shard: Nat, +shards: Nat) -> IO(Unit):
  match there:
    case True{}:
      say("plan already exists: " ++ plan)
    case False{}:
      plan.make(c, plan, ps, batch, shard, shards)

# The driver --------------------------------------------------------------------

def fills.ok(+pt: Pt) -> IO(Unit):
  match pt:
    case Pt{k, f}:
      Bool.pick(IO(Unit), Nat.is_le(k, f), IO.pure(Unit, Unit{}),
        IO.die(Unit, 1, "plan-windows: " ++ Nat.show(k) ++ " shards but " ++ Nat.show(f) ++ " filler slices: lower FILL (or unset it)"))

def Pt.shards(+pt: Pt) -> Nat:
  match pt:
    case Pt{k, f}:
      k

def run(+dir: String, +size: String, +batch: String, ss: List<&2, Spec>) -> IO(Unit):
  do IO<Unit>:
    +out : String <- S.env("OUT", "run/transcripts")
    +tok : String <- S.env("TOKENIZER", "weights/code32k.bpe")
    +cap : Nat <- S.env.nat("CAPACITY", 2046n)
    +shard : Nat <- S.env.nat("SHARD", 20000n)
    +fill : Nat <- S.env.nat("FILL", 0n)
    +jobs : Nat <- S.env.nat("JOBS", 4n)
    +bm : String <- S.env("BEND_MIX", "bend-mix")
    +bp : String <- S.env("BEND_PREPARE", "bend-prepare")
    +bw : String <- S.env("BEND_WINDOWS", "bend-windows")
    +bs : String <- S.env("BEND_PLAN_SEGMENT", "bend-plan-segment")
    S.mkdir(dir)
    +have : Bool <- S.exists(dir ++ "/filler.nul")
    mix.if(have, dir, out, bm, ss)
    +pd : Bool <- S.exists(dir ++ "/parts/done")
    +pt : Pt <- parts.if(pd, dir, shard, fill)
    fills.ok(pt)
    +c : Cf = Cf{dir, size, tok, Nat.show(cap), bp, bw}
    build(c, Pt.shards(pt), jobs)
    +plan : String = dir ++ "/plan-" ++ size ++ "-b" ++ batch ++ "-windows.tsv"
    +there : Bool <- S.exists(plan)
    plan.if(there, c, plan, bs, batch, shard, Pt.shards(pt))

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-plan-windows RUN_DIR SIZE BATCH LANG:PER[:cycle] ...")

def args.go(xs: List<String>) -> IO(Unit):
  match xs:
    case +d <> +z <> +b <> +s <> more:
      run(d, z, b, specs(s <> more))
    case _:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args.go(xs)
