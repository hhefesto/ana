import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ./Lib.bend as L

# combine RAW_SHARE OUT T_DIR R_DIR... [--steps N]: corpus v2's one mix
# (docs/CORPUS-V2.md, C5) as one run directory and plan (the old combine.py,
# output for output).
#
# The transcript windows' shards (T_DIR, windows.sh's) and the raw shards
# (each R_DIR, rawshards.sh's), each in its own plan's order, are
# interleaved: the next shard is raw while raw's training windows are under
# RAW_SHARE of all so far, cr < RAW_SHARE * (ct + cr + 1) (and raw has a
# shard left), else transcripts; the mix ends where the transcripts end, or
# once N global steps are planned (a pilot's own short plan, so its
# learning-rate schedule runs out with it; the steps a shard adds are its
# windows / 16, rounded up). Each shard is hard-linked into OUT as
# shard-K-fp100m.corpus (`ln -fL`: a link already there is replaced) and
# planned again at its document offset in the new order with
# bend-plan-segment (the trainer draws validation documents by global
# index), up to PROCS (8) at a time. Then OUT/plan-fp100m-b16-windows.tsv,
# master's format: a `plan 1 STEPS IDENTITY SHA DOCS SHARDS 16 fp100m
# TOKENIZER` line and a `segment K OFFSET DOCS DATASET TW VW STEPS START END`
# line a shard; and OUT/order.tsv, `K TAB raw|transcripts TAB SOURCE` a
# shard. A plan is a directory's plan-fp100m-b16-windows.tsv, else its
# plan-fp100m-b16-s2000.tsv.
#
# RAW_SHARE is a decimal (`0.3`, `.6`, `1`): the comparison is exact, in
# rationals (combine.py compared in binary floating point; the two agree on
# every decimal share at these sizes: a float product lands on the integer
# itself whenever the exact one is an integer). The identity prints it as
# Python's str(float) does for a decimal of at most 15 significant digits
# (0.30 -> 0.3, 1 -> 1.0); a share under 0.0001 (which Python prints with an
# exponent) is refused. The summary's percentage rounds half up (Python
# rounded the binary product; they can differ only at an exact .x5).
#
# Run from the repository root.

# Text ----------------------------------------------------------------------

def cb.space(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 10)), Bool.or(U32.is_eq(c, 9), U32.is_eq(c, 13)))

def cb.blank(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(U32, cb.space(c), 32, c) <> cb.blank(t)

def cb.full(ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> more:
      +r = cb.full(more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(w), 0n), r, w <> r)

# the words of a text (Python's str.split() on ASCII text)
def cb.words(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  cb.full(S.split(cb.blank(xs), 32))

def cb.nat.or(m: Maybe<&2, Nat>) -> Nat:
  match m:
    case Some{n}:
      n
    case None{}:
      0n

def cb.nat(+w: List<&2, U32>) -> Nat:
  cb.nat.or(Nat.read(S.str(w)))

def cb.show(+n: Nat) -> List<&2, U32>:
  S.b(Nat.show(n))

# os.path.join(d, name)
def cb.join(+d: List<&2, U32>, +name: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Bool.or(Nat.is_eq(S.len(d), 0n), S.suffix(d, [47])), S.append(d, name), S.append(d, 47 <> name))

def cb.path(+d: String, +name: String) -> String:
  S.str(cb.join(S.b(d), S.b(name)))

# The share --------------------------------------------------------------------

type CbSh is Data:
  CbSh{ok: Bool, p: Nat, q: Nat, text: String}

def cb.digits(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.and(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), cb.digits(t))

def cb.zeros.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      cb.zeros.drop(t, L.v2.head.is(t, 48))
    case r _:
      r

# without leading zeros, "0" when nothing is left
def cb.unzero(+xs: List<&2, U32>) -> List<&2, U32>:
  +r = cb.zeros.drop(xs, L.v2.head.is(xs, 48))
  Bool.pick(List<&2, U32>, Nat.is_eq(S.len(r), 0n), [48], r)

def cb.share.of(+i: List<&2, U32>, +f: List<&2, U32>) -> CbSh:
  +ok = Bool.and(Bool.and(cb.digits(i), cb.digits(f)), Nat.is_lt(0n, Nat.add(S.len(i), S.len(f))))
  +p = cb.nat(cb.unzero(S.append(i, f)))
  +q = Nat.pow(10n, S.len(f))
  +text = L.v2.concat([cb.unzero(i), [46], List.reverse(&2, U32, cb.unzero(List.reverse(&2, U32, f)))])
  CbSh{ok, p, q, S.str(text)}

def cb.share(+s: String) -> CbSh:
  +xs = S.b(s)
  cb.share.of(L.v2.before(xs, 46), Bool.pick(List<&2, U32>, L.v2.has(xs, 46), L.v2.after(xs, 46), Nil{}))

# A shard of a source plan ---------------------------------------------------------

type CbIn is Data:
  CbIn{raw: Bool, src: List<&2, U32>, docs: Nat, tw: Nat}

def cb.in.raw(+s: CbIn) -> Bool:
  match s:
    case CbIn{r, x, d, t}:
      r

def cb.in.src(+s: CbIn) -> List<&2, U32>:
  match s:
    case CbIn{r, x, d, t}:
      x

def cb.in.docs(+s: CbIn) -> Nat:
  match s:
    case CbIn{r, x, d, t}:
      d

def cb.in.tw(+s: CbIn) -> Nat:
  match s:
    case CbIn{r, x, d, t}:
      t

# segment K OFFSET DOCS ID TW VW STEPS START END
def cb.seg.line(+raw: Bool, +d: List<&2, U32>, +ws: List<&2, List<&2, U32>>) -> List<&2, CbIn>:
  +src = cb.join(d, L.v2.concat([S.b("shard-"), L.v2.nth(ws, 1n), S.b("-fp100m.corpus")]))
  Bool.pick(List<&2, CbIn>, S.eq(L.v2.nth(ws, 0n), S.b("segment")), [CbIn{raw, src, cb.nat(L.v2.nth(ws, 3n)), cb.nat(L.v2.nth(ws, 5n))}], Nil{})

def cb.segs(+raw: Bool, +d: List<&2, U32>, ls: List<&2, List<&2, U32>>) -> List<&2, CbIn>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      List.append(&2, CbIn, cb.seg.line(raw, d, cb.words(l)), cb.segs(raw, d, more))

def cb.plan.pick(w: Bool, s: Bool, +d: String) -> IO(String):
  match w s:
    case True{} _:
      IO.pure(String, cb.path(d, "plan-fp100m-b16-windows.tsv"))
    case False{} True{}:
      IO.pure(String, cb.path(d, "plan-fp100m-b16-s2000.tsv"))
    case False{} False{}:
      IO.die(String, 1, "combine: no plan in " ++ d)

def cb.dir.segs(+raw: Bool, +d: String) -> IO(List<&2, CbIn>):
  do IO<List<&2, CbIn>>:
    w : Bool <- S.exists(cb.path(d, "plan-fp100m-b16-windows.tsv"))
    s : Bool <- S.exists(cb.path(d, "plan-fp100m-b16-s2000.tsv"))
    +p : String <- cb.plan.pick(w, s, d)
    +xs : List<&2, U32> <- S.read(p)
    return cb.segs(raw, S.b(d), S.split.lines(xs))

def cb.dirs.segs(ds: List<&2, String>, acc: List<&2, CbIn>) -> IO(List<&2, CbIn>):
  match ds:
    case Nil{}:
      IO.pure(List<&2, CbIn>, acc)
    case d <> more:
      do IO<List<&2, CbIn>>:
        xs : List<&2, CbIn> <- cb.dir.segs(True{}, d)
        cb.dirs.segs(more, List.append(&2, CbIn, acc, xs))

# The mix ------------------------------------------------------------------------
#
# want: raw is due (cr < p/q * (ct + cr + 1)); stop: the step cap is reached.
# starved: a transcripts shard went in while raw was due but had none left.

type CbMx is Data:
  CbMx{order: List<&2, CbIn>, starved: Bool}

def cb.mx.put(s: CbIn, w: Bool, m: CbMx) -> CbMx:
  match m:
    case CbMx{o, v}:
      CbMx{s <> o, Bool.or(w, v)}

def cb.due(+ct: Nat, +cr: Nat, +p: Nat, +q: Nat) -> Bool:
  Nat.is_lt(Nat.mul(cr, q), Nat.mul(p, Nat.add(Nat.add(ct, cr), 1n)))

def cb.ceil16(+n: Nat) -> Nat:
  Nat.div(Nat.add(n, 15n), 16n)

def cb.stop(+cap: Nat, +est: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, cap), Nat.is_ge(est, cap))

def cb.mix(fuel: Nat, stop: Bool, ts: List<&2, CbIn>, rs: List<&2, CbIn>, want: Bool, +ct: Nat, +cr: Nat, +est: Nat, +p: Nat, +q: Nat, +cap: Nat) -> CbMx:
  match fuel stop ts rs want:
    case 1n+f False{} t <> tt +r <> rr True{}:
      +cr2 = Nat.add(cr, cb.in.tw(r))
      +est2 = Nat.add(est, cb.ceil16(cb.in.tw(r)))
      cb.mx.put(r, False{}, cb.mix(f, cb.stop(cap, est2), t <> tt, rr, cb.due(ct, cr2, p, q), ct, cr2, est2, p, q, cap))
    case 1n+f False{} +t <> tt rs w:
      +ct2 = Nat.add(ct, cb.in.tw(t))
      +est2 = Nat.add(est, cb.ceil16(cb.in.tw(t)))
      cb.mx.put(t, w, cb.mix(f, cb.stop(cap, est2), tt, rs, cb.due(ct2, cr, p, q), ct2, cr, est2, p, q, cap))
    case _ _ _ _ _:
      CbMx{Nil{}, False{}}

# Processes, PROCS at a time -------------------------------------------------------
#
# A pool any corpus v2 tool can use: jobs go into a channel with room for
# all of them, PROCS forked workers each take the next and run it (`env
# K=V.. PROG ARGS..` in the repository, stderr dropped), every result goes
# into a second channel the caller reads as they finish (cb.pool.next), and
# cb.pool.close waits for the workers.

type CbJob is Data:
  CbJob{i: Nat, env: List<&2, String>, prog: String, args: List<&2, String>}

type CbRes is Data:
  CbRes{i: Nat, out: S.Out, ms: Nat}

def cb.res.i(+r: CbRes) -> Nat:
  match r:
    case CbRes{i, o, m}:
      i

def cb.res.out(+r: CbRes) -> S.Out:
  match r:
    case CbRes{i, o, m}:
      o

def cb.res.ms(+r: CbRes) -> Nat:
  match r:
    case CbRes{i, o, m}:
      m

def cb.res.le(a: CbRes, b: CbRes) -> Bool:
  match a b:
    case CbRes{i, o, m} CbRes{j, p, n}:
      Nat.is_le(i, j)

def cb.strs(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> cb.strs(more)

def cb.job.run(j: CbJob) -> IO(CbRes):
  match j:
    case CbJob{+i, env, prog, args}:
      do IO<CbRes>:
        +t0 : Nat <- IO.now()
        +o : S.Out <- S.run.quiet(".", cb.strs(env), 864000, prog, cb.strs(args), Nil{})
        +t1 : Nat <- IO.now()
        return CbRes{i, o, Nat.sub(t1, t0)}

def cb.wk.got(+res: Chan(CbRes), m: Maybe<&1, CbJob>) -> IO(Bool):
  match m:
    case None{}:
      IO.pure(Bool, False{})
    case Some{j}:
      do IO<Bool>:
        r : CbRes <- cb.job.run(j)
        ok : Result<&1, &1, CbRes, Unit> <- Chan.send(CbRes, res, r)
        return True{}

def cb.wk.step(+jobs: Chan(CbJob), +res: Chan(CbRes)) -> IO(Bool):
  do IO<Bool>:
    m : Maybe<&1, CbJob> <- Chan.recv(CbJob, jobs)
    cb.wk.got(res, m)

def cb.wk.go(fuel: Nat, +jobs: Chan(CbJob), +res: Chan(CbRes), more: Bool) -> IO(Unit):
  match fuel more:
    case 1n+f True{}:
      IO.bind(Bool, Unit, cb.wk.step(jobs, res), cb.wk.go(f, jobs, res))
    case _ _:
      IO.pure(Unit, Unit{})

def cb.big() -> Nat:
  U32.to_nat(4294967295)

def cb.fork(n: Nat, +jobs: Chan(CbJob), +res: Chan(CbRes)) -> IO(List<Chan(Unit)>):
  match n:
    case 0n:
      IO.pure(List<Chan(Unit)>, Nil{})
    case 1n+m:
      do IO<List<Chan(Unit)>>:
        ch : Chan(Unit) <- IO.fork(Unit, cb.wk.go(cb.big(), jobs, res, True{}))
        rest : List<Chan(Unit)> <- cb.fork(m, jobs, res)
        return ch <> rest

def cb.send(+jobs: Chan(CbJob), js: List<&2, CbJob>) -> IO(Unit):
  match js:
    case Nil{}:
      Chan.close(CbJob, jobs)
    case j <> more:
      do IO<Unit>:
        ok : Result<&1, &1, CbJob, Unit> <- Chan.send(CbJob, jobs, j)
        cb.send(jobs, more)

def cb.join.all(chs: List<Chan(Unit)>) -> IO(Unit):
  match chs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +ch <> more:
      do IO<Unit>:
        u : Unit <- IO.join(Unit, ch)
        cb.join.all(more)

type CbPool is Type:
  CbPool{res: Chan(CbRes), ws: List<Chan(Unit)>}

# the jobs started, PROCS (at least one) at a time
def cb.pool.open(+procs: Nat, +js: List<&2, CbJob>) -> IO(CbPool):
  +n = List.length(&2, CbJob, js)
  do IO<CbPool>:
    +jobs : Chan(CbJob) <- Chan.new(CbJob, U32.from_nat(1n+n))
    +res : Chan(CbRes) <- Chan.new(CbRes, U32.from_nat(1n+n))
    cb.send(jobs, js)
    ws : List<Chan(Unit)> <- cb.fork(Nat.max(procs, 1n), jobs, res)
    return CbPool{res, ws}

def cb.pool.got(m: Maybe<&1, CbRes>) -> IO(CbRes):
  match m:
    case Some{r}:
      IO.pure(CbRes, r)
    case None{}:
      IO.die(CbRes, 1, "pool: the results channel closed early")

# the next result to finish (one a job: ask once a job)
def cb.pool.next(+p: Chan(CbRes)) -> IO(CbRes):
  do IO<CbRes>:
    m : Maybe<&1, CbRes> <- Chan.recv(CbRes, p)
    cb.pool.got(m)

def cb.pool.close(p: CbPool) -> IO(Unit):
  match p:
    case CbPool{res, ws}:
      cb.join.all(ws)

def cb.collect(n: Nat, +res: Chan(CbRes), acc: List<&2, CbRes>) -> IO(List<&2, CbRes>):
  match n:
    case 0n:
      IO.pure(List<&2, CbRes>, acc)
    case 1n+k:
      do IO<List<&2, CbRes>>:
        r : CbRes <- cb.pool.next(res)
        cb.collect(k, res, r <> acc)

def cb.pool.res(p: CbPool) -> Chan(CbRes) & CbPool:
  match p:
    case CbPool{+res, ws}:
      (res, CbPool{res, ws})

def cb.runs.fin(+n: Nat, x: Chan(CbRes) & CbPool) -> IO(List<&2, CbRes>):
  (res, p) = x
  do IO<List<&2, CbRes>>:
    rs : List<&2, CbRes> <- cb.collect(n, res, Nil{})
    cb.pool.close(p)
    return List.sort(~CbRes, ~cb.res.le, rs)

# every job's result, in the jobs' order (by i)
def cb.runs(+procs: Nat, +js: List<&2, CbJob>) -> IO(List<&2, CbRes>):
  do IO<List<&2, CbRes>>:
    p : CbPool <- cb.pool.open(procs, js)
    cb.runs.fin(List.length(&2, CbJob, js), cb.pool.res(p))

# Output ----------------------------------------------------------------------

type CbK is Data:
  CbK{k: Nat, off: Nat, s: CbIn}

def cb.k.k(+c: CbK) -> Nat:
  match c:
    case CbK{k, o, s}:
      k

def cb.k.s(+c: CbK) -> CbIn:
  match c:
    case CbK{k, o, s}:
      s

def cb.number(xs: List<&2, CbIn>, +k: Nat, +off: Nat) -> List<&2, CbK>:
  match xs:
    case Nil{}:
      Nil{}
    case +s <> more:
      CbK{k, off, s} <> cb.number(more, 1n+k, Nat.add(off, cb.in.docs(s)))

def cb.docs(xs: List<&2, CbIn>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +s <> more:
      Nat.add(cb.in.docs(s), cb.docs(more))

def cb.count.raw(xs: List<&2, CbIn>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +s <> more:
      Nat.add(Bool.pick(Nat, cb.in.raw(s), 1n, 0n), cb.count.raw(more))

def cb.dst(+out: String, +k: Nat) -> String:
  cb.path(out, "shard-" ++ Nat.show(k) ++ "-fp100m.corpus")

def cb.link.all(+out: String, ks: List<&2, CbK>) -> IO(Unit):
  match ks:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +c <> more:
      do IO<Unit>:
        o : List<&2, U32> <- S.must("ln " ++ S.str(cb.in.src(cb.k.s(c))), "ln", ["-fL", S.str(cb.in.src(cb.k.s(c))), cb.dst(out, cb.k.k(c))])
        cb.link.all(out, more)

def cb.ps() -> String:
  "run/v2/gcroot-bend-plan-segment/bin/bend-plan-segment"

def cb.jobs(+out: String, ks: List<&2, CbK>) -> List<&2, CbJob>:
  match ks:
    case Nil{}:
      Nil{}
    case CbK{+k, off, s} <> more:
      CbJob{k, Nil{}, cb.ps(), ["--threads", "1", cb.dst(out, k), Nat.show(off), "16", "fp100m"]} <> cb.jobs(out, more)

def cb.res.ok(+rs: List<&2, CbRes>) -> Bool:
  match rs:
    case Nil{}:
      True{}
    case +r <> more:
      U32.is_eq(S.Out.status(cb.res.out(r)), 0)

def cb.bad.go(rs: List<&2, CbRes>, ok: Bool) -> Maybe<&2, CbRes>:
  match rs ok:
    case r <> +more True{}:
      cb.bad.go(more, cb.res.ok(more))
    case r <> more False{}:
      Some{r}
    case Nil{} _:
      None{}

def cb.tail(+xs: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.sub(S.len(xs), 300n))

def cb.bad(m: Maybe<&2, CbRes>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{+r}:
      IO.die(Unit, 1, "plan-segment failed on shard " ++ Nat.show(cb.res.i(r)) ++ " (exit " ++ U32.show(S.Out.status(cb.res.out(r))) ++ "): " ++ S.str(cb.tail(S.Out.text(cb.res.out(r)))))

type CbAcc is Data:
  CbAcc{segs: List<&2, List<&2, U32>>, cum: Nat, twr: Nat, twt: Nat}

# segment K OFFSET DOCS DATASET TW VW STEPS START END, from bend-plan-segment's
# `segment OFFSET DOCS DATASET TW VW STEPS`
def cb.seg.out(+k: Nat, +ws: List<&2, List<&2, U32>>, +cum: Nat, +st: Nat) -> List<&2, U32>:
  S.join([S.b("segment"), cb.show(k), L.v2.nth(ws, 1n), L.v2.nth(ws, 2n), L.v2.nth(ws, 3n), L.v2.nth(ws, 4n), L.v2.nth(ws, 5n), L.v2.nth(ws, 6n), cb.show(cum), cb.show(Nat.add(cum, st))], 32)

def cb.fold(ks: List<&2, CbK>, rs: List<&2, CbRes>, +cum: Nat, +twr: Nat, +twt: Nat, acc: List<&2, List<&2, U32>>) -> CbAcc:
  match ks rs:
    case +c <> kt +r <> rt:
      +ws = cb.words(S.Out.text(cb.res.out(r)))
      +st = cb.nat(L.v2.nth(ws, 6n))
      +tw = cb.nat(L.v2.nth(ws, 4n))
      +raw = cb.in.raw(cb.k.s(c))
      cb.fold(kt, rt, Nat.add(cum, st), Nat.add(twr, Bool.pick(Nat, raw, tw, 0n)), Nat.add(twt, Bool.pick(Nat, raw, 0n, tw)), cb.seg.out(cb.k.k(c), ws, cum, st) <> acc)
    case _ _:
      CbAcc{List.reverse(&2, List<&2, U32>, acc), cum, twr, twt}

def cb.order.tsv(ks: List<&2, CbK>) -> List<&2, U32>:
  match ks:
    case Nil{}:
      Nil{}
    case CbK{k, o, +s} <> more:
      L.v2.concat([cb.show(k), [9], S.b(Bool.pick(String, cb.in.raw(s), "raw", "transcripts")), [9], cb.in.src(s), [10], cb.order.tsv(more)])

# tenths of a percent, rounded half up, as "30.0%"
def cb.pct(+part: Nat, +all: Nat) -> String:
  +den = Nat.max(all, 1n)
  +t = Nat.div(Nat.add(Nat.mul(part, 2000n), den), Nat.mul(den, 2n))
  Nat.show(Nat.div(t, 10n)) ++ "." ++ Nat.show(Nat.mod(t, 10n)) ++ "%"

def cb.write(+out: String, +sh: String, ks: List<&2, CbK>, +nraw: Nat, +docs: Nat, +n: Nat, +ht: String, a: CbAcc) -> IO(Unit):
  match a:
    case CbAcc{+segs, +cum, +twr, +twt}:
      +hm = H.sha256(S.join(segs, 10))
      +ident = "mixed-v2:sha256=" ++ hm ++ ":raw=" ++ sh ++ ":windows=" ++ Nat.show(Nat.add(twr, twt)) ++ ":batch=16:size=fp100m:tokenizer=" ++ ht
      +head = "plan 1 " ++ Nat.show(cum) ++ " " ++ ident ++ " " ++ hm ++ " " ++ Nat.show(docs) ++ " " ++ Nat.show(n) ++ " 16 fp100m " ++ ht
      do IO<Unit>:
        S.write(cb.path(out, "plan-fp100m-b16-windows.tsv"), L.v2.concat([S.b(head), [10], S.join(segs, 10), [10]]))
        S.write(cb.path(out, "order.tsv"), cb.order.tsv(ks))
        IO.print(out ++ ": " ++ Nat.show(n) ++ " shards (" ++ Nat.show(nraw) ++ " raw), " ++ Nat.show(cum) ++ " steps, training windows: transcripts "
          ++ Nat.show(twt) ++ ", raw " ++ Nat.show(twr) ++ " (" ++ cb.pct(twr, Nat.add(twr, twt)) ++ ")")

def cb.warn(w: Bool, +nr: Nat) -> IO(Unit):
  match w:
    case True{}:
      IO.print_err("warning: raw ran out after " ++ Nat.show(nr) ++ " shards; the rest is transcripts only")
    case False{}:
      IO.pure(Unit, Unit{})

def cb.mx.order(+m: CbMx) -> List<&2, CbIn>:
  match m:
    case CbMx{o, s}:
      o

def cb.mx.starved(+m: CbMx) -> Bool:
  match m:
    case CbMx{o, s}:
      s

def cb.tok() -> String:
  "weights/code32k.bpe"

def cb.run(+sh: CbSh, +out: String, +tdir: String, rdirs: List<&2, String>, +cap: Nat) -> IO(Unit):
  match sh:
    case CbSh{ok, +p, +q, +text}:
      do IO<Unit>:
        +ts : List<&2, CbIn> <- cb.dir.segs(False{}, tdir)
        +rs : List<&2, CbIn> <- cb.dirs.segs(rdirs, Nil{})
        +nr : Nat = List.length(&2, CbIn, rs)
        +mx : CbMx = cb.mix(1n+Nat.add(List.length(&2, CbIn, ts), nr), False{}, ts, rs, cb.due(0n, 0n, p, q), 0n, 0n, 0n, p, q, cap)
        +order : List<&2, CbIn> = cb.mx.order(mx)
        cb.warn(cb.mx.starved(mx), nr)
        S.mkdir(out)
        +ks : List<&2, CbK> = cb.number(order, 0n, 0n)
        cb.link.all(out, ks)
        +procs : Nat <- S.env.nat("PROCS", 8n)
        +res : List<&2, CbRes> <- cb.runs(procs, cb.jobs(out, ks))
        cb.bad(cb.bad.go(res, cb.res.ok(res)))
        +hx : List<&2, U32> <- S.must("sha256sum " ++ cb.tok(), "sha256sum", [cb.tok()])
        cb.write(out, text, ks, cb.count.raw(order), cb.docs(order), List.length(&2, CbIn, order), S.str(List.take(&2, U32, hx, 64n)), cb.fold(ks, res, 0n, 0n, 0n, Nil{}))

# Arguments ---------------------------------------------------------------------

def cb.strs.d(xs: List<String>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> cb.strs.d(more)

type CbArgs is Data:
  CbArgs{rest: List<&2, String>, steps: Nat}

def cb.is.steps(+xs: List<&2, String>) -> Bool:
  match xs:
    case +x <> more:
      String.eq(x, "--steps")
    case Nil{}:
      False{}

# the arguments less the first `--steps N`
def cb.args.go(xs: List<&2, String>, at: Bool, seen: Bool, acc: List<&2, String>, +steps: Nat) -> CbArgs:
  match xs at seen:
    case x <> y <> +more True{} False{}:
      cb.args.go(more, cb.is.steps(more), True{}, acc, cb.nat(S.b(y)))
    case +x <> +more _ s:
      cb.args.go(more, cb.is.steps(more), s, x <> acc, steps)
    case _ _ _:
      CbArgs{List.reverse(&2, String, acc), steps}

def cb.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: combine RAW_SHARE OUT T_DIR R_DIR... [--steps N]")

def cb.go(+sh: CbSh, ok: Bool, a: CbArgs) -> IO(Unit):
  match ok a:
    case True{} CbArgs{s <> out <> t <> rdirs, +cap}:
      cb.run(sh, out, t, rdirs, cap)
    case _ _:
      cb.usage()

def cb.small(+sh: CbSh) -> Bool:
  match sh:
    case CbSh{ok, p, q, t}:
      Bool.and(Nat.is_lt(0n, p), Nat.is_lt(Nat.mul(p, 10000n), q))

def cb.sh.ok(+sh: CbSh) -> Bool:
  match sh:
    case CbSh{ok, p, q, t}:
      ok

def cb.first(+a: CbArgs) -> String:
  match a:
    case CbArgs{s <> more, n}:
      s
    case _:
      "?"

def cb.small.die(small: Bool) -> IO(Unit):
  match small:
    case True{}:
      IO.die(Unit, 2, "combine: a RAW_SHARE under 0.0001 is not supported")
    case False{}:
      IO.pure(Unit, Unit{})

def cb.combine.a(+a: CbArgs) -> IO(Unit):
  +sh = cb.share(cb.first(a))
  do IO<Unit>:
    cb.small.die(cb.small(sh))
    cb.go(sh, cb.sh.ok(sh), a)

# xs: the arguments after `combine`
def cb.combine(xs: List<String>) -> IO(Unit):
  +ys = cb.strs.d(xs)
  cb.combine.a(cb.args.go(ys, cb.is.steps(ys), False{}, Nil{}, 0n))
