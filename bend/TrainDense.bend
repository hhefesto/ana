import Base
import ./Num.bend as N
import ./Bytes.bend as B
import ./Config.bend as C
import ./Train.bend as Tr
import ./Train/Init.bend as I
import ./Train/Opt.bend as O
import ./Train/Data.bend as D
import ./Train/Ckpt.bend as K
import ./Dense/Layout.bend as L
import ./Dense/Op.bend as P
import ./Dense/Step.bend as S
import ./Dense/Io.bend as Io
import ./Dense/Ckpt.bend as Dk
import ./Dense/Plan.bend as Pl
import ./Corpus.bend as Cc
import ./Checkpoint.bend as Km
import ./Evaluate.bend as Ev

# train, dense: master's trainer on the Bend2 port at GPU speed. The same
# environment and log as Train.bend (the tree trainer, kept as the
# reference), plus
#   TRAIN_MICRO  windows per micro-batch (default: the batch, at most 32);
#                the batch's micro-batches accumulate one gradient
#   TRAIN_CHUNK  GLA chunk length (default 16; master used 64): the chunked form equals
#                the recurrent one at any length (Spec/Linear.bend)
# Hot start (TRAIN_INIT set): continue master's run from its FTC2 checkpoint
# on master's own data and schedule.
#   TRAIN_INIT   the checkpoint (parameters, Adam moments, Muon momentum, step)
#   PLAN         master's run plan (plan-*.tsv); RUN_DIR its shards,
#                shard-<k>-<SHARD_SIZE>.corpus (default bpe100m)
#   TRAIN_STEPS  steps to run from the checkpoint's step
#   SAVE_EVERY   save every n global steps (default 1000) and at the end, to
#                OUT-step<N>.checkpoint (FTC2: the same run at a later step)
#   TRAIN_LR, TRAIN_WARMUP, TRAIN_WD, GRAD_CLIP default to the checkpoint's
#   manifest (the schedule's total is always the manifest's)
# EVAL_EVERY / EVAL_WINDOWS validate on each shard's first validation
# windows (master's VALIDATE_EVERY / VALIDATION_WINDOWS), and once before
# the first step.
#
# The step is a program over one store (bend/Dense): on a CUDA build of the
# Bend2 fork its products run on cuBLAS and its einsums as generated
# kernels; elsewhere every op runs its reference loop.

# Batches ------------------------------------------------------------------

# k micro-batches of mb windows each
def micros.go(k: Nat, +mb: Nat, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      List.take(&2, List<&2, U32>, ws, mb) <> micros.go(p, mb, List.drop(&2, List<&2, U32>, ws, mb))

def micros(+mb: Nat, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  micros.go(Nat.div(List.length(&2, List<&2, U32>, ws), Nat.max(mb, 1n)), mb, ws)

type Run is Data:
  Run{m: L.Dm, ly: L.Lay, fwd: List<&2, P.Op>, bwd: List<&2, P.Op>, upd: List<&2, P.Op>}

def Run.m(+r: Run) -> L.Dm:
  match r:
    case Run{m, ly, f, b, u}:
      m

def Run.ly(+r: Run) -> L.Lay:
  match r:
    case Run{m, ly, f, b, u}:
      ly

def Run.fwd(+r: Run) -> List<&2, P.Op>:
  match r:
    case Run{m, ly, f, b, u}:
      f

def Run.bwd(+r: Run) -> List<&2, P.Op>:
  match r:
    case Run{m, ly, f, b, u}:
      b

def Run.upd(+r: Run) -> List<&2, P.Op>:
  match r:
    case Run{m, ly, f, b, u}:
      u

def SL.add(+l0: F32, r: Array<F32> & F32) -> Array<F32> & F32:
  (s, l) = r
  (s, F32.add(l0, l))

def micro.back(+rn: Run, +l0: F32, r: Array<F32> & F32) -> Array<F32> & F32:
  (s, +l) = r
  (P.run(Run.bwd(rn), s), F32.add(l0, l))

def put(mw: List<&2, List<&2, U32>>, +rn: Run, s: Array<F32>) -> Array<F32>:
  Io.put.windows(mw, s, L.Lay.tin(Run.ly(rn)), L.Lay.ttg(Run.ly(rn)), L.Lay.tw(Run.ly(rn)), L.Dm.t(Run.m(rn)))

def micro.one(mw: List<&2, List<&2, U32>>, +rn: Run, r: Array<F32> & F32) -> Array<F32> & F32:
  (s, l0) = r
  micro.back(rn, l0, Io.get1(P.run(Run.fwd(rn), put(mw, rn, s)), L.Lay.lmean(Run.ly(rn))))

# forward then backward over each micro-batch; the losses summed
def micro.go(ms: List<&2, List<&2, List<&2, U32>>>, +rn: Run, r: Array<F32> & F32) -> Array<F32> & F32:
  match ms:
    case Nil{}:
      r
    case mw <> t:
      micro.go(t, rn, micro.one(mw, rn, r))

def Out.fin(+loss: F32, r: Array<F32> & F32) -> Array<F32> & F32 & F32:
  (s, n) = r
  (s, loss, n)

# the step's scalars: learning rate, 1 - b1^t, 1 - b2^t
def hyper(+ly: L.Lay, +lr: F32, +step: Nat, s: Array<F32>) -> Array<F32>:
  Io.put([lr, F32.sub(1.0, F32.pow(0.9, F32.from_nat(step))), F32.sub(1.0, F32.pow(0.999, F32.from_nat(step)))], s, S.cell.lr(ly))

def step.fin(+rn: Run, +lr: F32, +step: Nat, +k: F32, r: Array<F32> & F32) -> Array<F32> & F32 & F32:
  (s, l) = r
  +ly = Run.ly(rn)
  Out.fin(F32.div(l, k), Io.get1(P.run(Run.upd(rn), hyper(ly, lr, step, s)), L.Lay.gnorm(ly)))

# one optimizer step: zero the gradients, accumulate the micro-batches,
# clip and update
def train.step(+rn: Run, +mb: Nat, bw: List<&2, List<&2, U32>>, +lr: F32, +step: Nat, s: Array<F32>) -> Array<F32> & F32 & F32:
  +ms = micros(mb, bw)
  +k = F32.from_nat(List.length(&2, List<&2, List<&2, U32>>, ms))
  step.fin(rn, lr, step, k, micro.go(ms, rn, (P.run(S.zero.grads(Run.ly(rn)), s), 0.0)))

def valid.one(mw: List<&2, List<&2, U32>>, +rn: Run, r: Array<F32> & F32) -> Array<F32> & F32:
  (s, l0) = r
  SL.add(l0, Io.get1(P.run(Run.fwd(rn), put(mw, rn, s)), L.Lay.lmean(Run.ly(rn))))

# validation: the mean loss over whole micro-batches of the windows
def valid.go(ms: List<&2, List<&2, List<&2, U32>>>, +rn: Run, r: Array<F32> & F32) -> Array<F32> & F32:
  match ms:
    case Nil{}:
      r
    case mw <> t:
      valid.go(t, rn, valid.one(mw, rn, r))

def whole(+mb: Nat, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  micros(mb, List.take(&2, List<&2, U32>, ws, Nat.mul(mb, Nat.div(List.length(&2, List<&2, U32>, ws), mb))))

def valid.fin(+k: Nat, r: Array<F32> & F32) -> Array<F32> & F32:
  (s, l) = r
  (s, F32.div(l, F32.from_nat(Nat.max(k, 1n))))

def valid(+rn: Run, +mb: Nat, +ws: List<&2, List<&2, U32>>, s: Array<F32>) -> Array<F32> & F32:
  +ms = whole(mb, ws)
  valid.fin(List.length(&2, List<&2, List<&2, U32>>, ms), valid.go(ms, rn, (s, 0.0)))

# Saving -------------------------------------------------------------------

def render(+c: C.Config, +tok: String, +step: Nat, +xs: List<&2, F32>) -> String:
  "BTC1\n" ++ K.Config.line(c) ++ "\n" ++ tok ++ "\n" ++ Nat.show(step) ++ "\n" ++ Nat.show(List.length(&2, F32, xs))
    ++ K.hex.lines(xs, 0n)

def save(+path: String, +c: C.Config, +tok: String, +step: Nat, +xs: List<&2, F32>) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "w"))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write(f, render(c, tok, step, xs))
    K.save.fin(r)

# The loop -----------------------------------------------------------------

type Hp is Data:
  Hp{lr: F32, warm: Nat, total: Nat, batch: Nat, every: Nat, mb: Nat}

def Hp.lr(+h: Hp) -> F32:
  match h:
    case Hp{a, b, c, d, e, f}:
      a

def Hp.warm(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f}:
      b

def Hp.total(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f}:
      c

def Hp.batch(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f}:
      d

def Hp.every(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f}:
      e

def Hp.mb(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f}:
      f

def report.valid.print(+step: Nat, r: Array<F32> & F32) -> IO(Array<F32>):
  (s, +l) = r
  do IO<Array<F32>>:
    IO.print("step " ++ Nat.show(step) ++ " validation loss " ++ F32.show(l))
    return s

def report.valid(on: Bool, +rn: Run, +hp: Hp, +vw: List<&2, List<&2, U32>>, +step: Nat, s: Array<F32>) -> IO(Array<F32>):
  match on:
    case True{}:
      report.valid.print(step, valid(rn, Hp.mb(hp), vw, s))
    case False{}:
      IO.pure(Array<F32>, s)

def loop.print.lg(+step2: Nat, +lr: F32, +t0: Nat, s: Array<F32>, lg: F32 & F32) -> IO(Array<F32>):
  (+l, +g) = lg
  do IO<Array<F32>>:
    +t1 : Nat <- IO.now()
    IO.print("step " ++ Nat.show(step2) ++ " loss " ++ F32.show(l) ++ " grad_norm " ++ F32.show(g)
      ++ " lr " ++ F32.show(lr) ++ " ms " ++ Nat.show(Nat.sub(t1, t0)))
    return s

def loop.print(+step2: Nat, +lr: F32, +t0: Nat, r: Array<F32> & F32 & F32) -> IO(Array<F32>):
  (s, lg) = r
  loop.print.lg(step2, lr, t0, s, lg)

def loop(n: Nat, +rn: Run, +hp: Hp, +ws: List<&2, List<&2, U32>>, +nw: Nat, +vw: List<&2, List<&2, U32>>,
         +step: Nat, s: Array<F32>) -> IO(Array<F32>):
  match n:
    case 0n:
      IO.pure(Array<F32>, s)
    case 1n+p:
      +step2 = {1n+step : Nat}
      +lr = O.lr.at(Hp.lr(hp), step2, Hp.warm(hp), Hp.total(hp))
      +every = Hp.every(hp)
      do IO<Array<F32>>:
        +t0 : Nat <- IO.now()
        s2 : Array<F32> <- loop.print(step2, lr, t0, train.step(rn, Hp.mb(hp), Tr.batch.at(ws, nw, step, Hp.batch(hp)), lr, step2, s))
        s3 : Array<F32> <- report.valid(Bool.or(Nat.is_eq(step2, Hp.total(hp)),
          Bool.and(Nat.is_lt(0n, every), Nat.is_eq(Nat.mod(step2, Nat.max(every, 1n)), 0n))), rn, hp, vw, step2, s2)
        loop(p, rn, hp, ws, nw, vw, step2, s3)

def params.fin(r: Array<F32> & List<&2, F32>) -> List<&2, F32>:
  (s, xs) = r
  xs

def finish.save(+c: C.Config, +tok: Tr.Tok, +steps: Nat, +out: String, +rn: Run, s: Array<F32>) -> IO(Unit):
  do IO<Unit>:
    save(out, c, Tr.Tok.id(tok), steps, params.fin(Io.get(U32.to_nat(L.Lay.params(Run.ly(rn))), s, 0)))
    IO.print("wrote " ++ out)

# OUT empty: no checkpoint
def finish.if(skip: Bool, +c: C.Config, +tok: Tr.Tok, +steps: Nat, +out: String, +rn: Run, s: Array<F32>) -> IO(Unit):
  match skip:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      finish.save(c, tok, steps, out, rn, s)

def finish(+c: C.Config, +tok: Tr.Tok, +steps: Nat, +out: String, +rn: Run, s: Array<F32>) -> IO(Unit):
  finish.if(String.is_empty(out), c, tok, steps, out, rn, s)

def run(+c: C.Config, +tok: Tr.Tok, +text: List<&2, U32>, +hp: Hp, +muon: Bool, +mu: F32, +wd: F32, +clip: F32,
        +steps: Nat, +out: String, +evals: Nat, +chunk: Nat) -> IO(Unit):
  +sp = D.split(D.encode.all(Tr.Tok.b(tok), D.documents(text)))
  +train = D.all.windows(C.Config.ctx(c), Tr.split.train(sp))
  +vw = List.take(&2, List<&2, U32>, D.all.windows(C.Config.ctx(c), Tr.split.valid(sp)), evals)
  +nw = List.length(&2, List<&2, U32>, train)
  +m = L.Dm.of.cc(c, Hp.mb(hp), U32.from_nat(chunk))
  +ly = L.Lay.of(c, m)
  +rn = {Run{m, ly, S.fwd(m, ly), S.bwd(m, ly, F32.div(1.0, F32.from_nat(Nat.div(Hp.batch(hp), Hp.mb(hp))))),
            S.update(muon, ly, S.Hy{0.9, 0.999, 1.0e-8, wd, mu}, m, clip)} : Run}
  do IO<Unit>:
    IO.print("train (dense): " ++ C.Config.model_id(c))
    IO.print("tokenizer " ++ Tr.Tok.id(tok) ++ "; " ++ Nat.show(nw) ++ " training windows, " ++ Nat.show(List.length(&2, List<&2, U32>, vw))
      ++ " validation windows; micro-batch " ++ Nat.show(Hp.mb(hp)) ++ ", store " ++ U32.show(L.Lay.total(ly)) ++ " floats")
    s0 : Array<F32> <- report.valid(True{}, rn, hp, vw, 0n, Io.put(K.Weights.flat(I.init(c)), Array.new(F32, L.Lay.depth(ly), 0.0), 0))
    s1 : Array<F32> <- loop(steps, rn, hp, train, Nat.max(nw, 1n), vw, 0n, s0)
    finish(c, tok, steps, out, rn, s1)

def start(+tokf: String, +pre: String, +steps_s: String, +batch_s: String, +micro_s: String, +lr_s: String, +wd_s: String,
          +warm_s: String, +opt: String, +mu_s: String, +clip_s: String, +every_s: String, +evals_s: String, +out: String,
          +chunk_s: String, +text: List<&2, U32>, +tb: List<&2, U32>) -> IO(Unit):
  +steps = Tr.nat.or(steps_s, 100n)
  +batch = Tr.nat.or(batch_s, 4n)
  +mb = Tr.nat.or(micro_s, Nat.min(batch, 32n))
  run(Tr.preset(pre), Tr.tok.of(tokf, tb), text,
      Hp{Tr.f32.or(lr_s, 3.0e-4), Nat.min(Tr.nat.or(warm_s, 100n), steps), steps, batch, Tr.nat.or(every_s, 0n), mb},
      String.eq(opt, "muon"), Tr.f32.or(mu_s, 0.95), Tr.f32.or(wd_s, 0.01), Tr.f32.or(clip_s, 1.0),
      steps, out, Tr.nat.or(evals_s, 16n), Tr.nat.or(chunk_s, 16n))

# Hot start ----------------------------------------------------------------

type Hs is Data:
  Hs{src: Dk.Src, out: String, every: Nat, stop: Nat, dir: String, size: String, evals: Nat, tok: String, ctx: Nat}

def Hs.src(+h: Hs) -> Dk.Src:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      a

def Hs.out(+h: Hs) -> String:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      b

def Hs.every(+h: Hs) -> Nat:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      c

def Hs.stop(+h: Hs) -> Nat:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      d

def Hs.dir(+h: Hs) -> String:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      e

def Hs.size(+h: Hs) -> String:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      f

def Hs.evals(+h: Hs) -> Nat:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      g

def Hs.tok(+h: Hs) -> String:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      t

def Hs.ctx(+h: Hs) -> Nat:
  match h:
    case Hs{a, b, c, d, e, f, g, t, x}:
      x

def hot.path(+hs: Hs, +step: Nat) -> String:
  Hs.out(hs) ++ "-step" ++ Nat.show(step) ++ ".checkpoint"

def hot.save(+hs: Hs, +rn: Run, +muon: Bool, +step: Nat, s: Array<F32>) -> IO(Array<F32>):
  +path = hot.path(hs, step)
  do IO<Array<F32>>:
    +t0 : Nat <- IO.now()
    s2 : Array<F32> <- Dk.save(path, Hs.src(hs), step, Run.ly(rn), Run.m(rn), muon, s)
    +t1 : Nat <- IO.now()
    IO.print("saved " ++ path ++ " (" ++ Nat.show(Nat.sub(t1, t0)) ++ " ms)")
    return s2

def hot.save.if(on: Bool, +hs: Hs, +rn: Run, +muon: Bool, +step: Nat, s: Array<F32>) -> IO(Array<F32>):
  match on:
    case True{}:
      hot.save(hs, rn, muon, step, s)
    case False{}:
      IO.pure(Array<F32>, s)

def every.at(+every: Nat, +step: Nat) -> Bool:
  Bool.and(Nat.is_lt(0n, every), Nat.is_eq(Nat.mod(step, Nat.max(every, 1n)), 0n))

def ws.put(+w: List<&2, U32>, r: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  (a, b) = r
  (w <> a, b)

# the first k windows and the rest, in one pass
def ws.split(k: Nat, xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  match k xs:
    case 0n _:
      (Nil{}, xs)
    case 1n+p Nil{}:
      (Nil{}, Nil{})
    case 1n+p +w <> t:
      ws.put(w, ws.split(p, t))

def batch.fill(short: Bool, +need: Nat, +head: List<&2, List<&2, U32>>, bt: List<&2, List<&2, U32>>,
               rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  match short:
    case False{}:
      (bt, rest)
    case True{}:
      (List.append(&2, List<&2, U32>, bt, List.take(&2, List<&2, U32>, head, need)), Nil{})

def batch.fin(+b: Nat, +head: List<&2, List<&2, U32>>, r: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  (+bt, rest) = r
  +k = List.length(&2, List<&2, U32>, bt)
  batch.fill(Nat.is_lt(k, b), Nat.sub(b, k), head, bt, rest)

# The next batch in epoch order: master's positions ((s - start - 1)·b + i)
# mod n are consecutive, so the windows are consumed in order; only the
# segment's last batch runs off the end and wraps to the first windows.
def batch.next(+b: Nat, +head: List<&2, List<&2, U32>>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  batch.fin(b, head, ws.split(b, rest))

# n steps of one segment: br is this step's batch and the segment's windows
# after it, head the segment's first windows (for the final wrap)
def loop.hot(n: Nat, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +head: List<&2, List<&2, U32>>,
             +vw: List<&2, List<&2, U32>>, +step: Nat, br: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>,
             s: Array<F32>) -> IO(Array<F32>):
  match n:
    case 0n:
      IO.pure(Array<F32>, s)
    case 1n+p:
      (bw, rest) = br
      +step2 = {1n+step : Nat}
      +lr = O.lr.at(Hp.lr(hp), step2, Hp.warm(hp), Hp.total(hp))
      do IO<Array<F32>>:
        +t0 : Nat <- IO.now()
        s2 : Array<F32> <- loop.print(step2, lr, t0, train.step(rn, Hp.mb(hp), bw, lr, step2, s))
        s3 : Array<F32> <- report.valid(every.at(Hp.every(hp), step2), rn, hp, vw, step2, s2)
        s4 : Array<F32> <- hot.save.if(Bool.or(every.at(Hs.every(hs), step2), Nat.is_eq(step2, Hs.stop(hs))), hs, rn, muon, step2, s3)
        loop.hot(p, rn, hp, hs, muon, head, vw, step2, batch.next(Hp.batch(hp), head, rest), s4)

def seg.check(ok: Bool, +why: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      Dk.fail.if(why)

# one segment's shard: its epoch windows, checked against the plan's count
# as master checks it, then the segment's steps up to the stop
def seg.train(+seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, +co: Cc.Corpus, +step: Nat,
              s: Array<F32>) -> IO(Array<F32> & Nat):
  +ctx = Hs.ctx(hs)
  +docs = Cc.Corpus.docs(co)
  +ws = Pl.epoch(ctx, Pl.Seg.offset(seg), docs)
  +nw = List.length(&2, List<&2, U32>, ws)
  +vw = Pl.valid(ctx, Pl.Seg.offset(seg), Hs.evals(hs), docs)
  +n = Nat.sub(Nat.min(Pl.Seg.end(seg), Hs.stop(hs)), step)
  do IO<Array<F32> & Nat>:
    u0 : Unit <- Dk.fail.if(Cc.Corpus.problem(co, Hs.tok(hs)))
    u1 : Unit <- seg.check(String.eq(Cc.Corpus.dataset(co), Pl.Seg.id(seg)), "segment corpus identity does not match the run plan")
    u2 : Unit <- seg.check(Nat.is_eq(nw, Pl.Seg.tw(seg)), "segment training windows (" ++ Nat.show(nw) ++ ") differ from the plan's")
    IO.print("shard " ++ Nat.show(Pl.Seg.index(seg)) ++ ": " ++ Nat.show(nw) ++ " training windows, global "
      ++ Nat.show(Pl.Seg.start(seg)) ++ ".." ++ Nat.show(Pl.Seg.end(seg)) ++ "; running " ++ Nat.show(step) ++ ".." ++ Nat.show(Nat.add(step, n)))
    s1 : Array<F32> <- report.valid(first, rn, hp, vw, step, s)
    s2 : Array<F32> <- loop.hot(n, rn, hp, hs, muon, List.take(&2, List<&2, U32>, ws, Hp.batch(hp)), vw, step,
      batch.next(Hp.batch(hp), List.take(&2, List<&2, U32>, ws, Hp.batch(hp)),
        List.drop(&2, List<&2, U32>, ws, Nat.mod(Nat.mul(Nat.sub(step, Pl.Seg.start(seg)), Hp.batch(hp)), Nat.max(nw, 1n)))), s1)
    return (s2, Nat.add(step, n))

def shard.path(+hs: Hs, +seg: Pl.Seg) -> String:
  Hs.dir(hs) ++ "/shard-" ++ Nat.show(Pl.Seg.index(seg)) ++ "-" ++ Hs.size(hs) ++ ".corpus"

def seg.read(+seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, +t0: Nat, +co: Cc.Corpus, +step: Nat,
             s: Array<F32>) -> IO(Array<F32> & Nat):
  do IO<Array<F32> & Nat>:
    +t1 : Nat <- IO.now()
    IO.print("parsed (" ++ Nat.show(Nat.sub(t1, t0)) ++ " ms)")
    seg.train(seg, rn, hp, hs, muon, first, co, step, s)

def seg.run.if(go: Bool, +seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, +step: Nat,
               s: Array<F32>) -> IO(Array<F32> & Nat):
  match go:
    case False{}:
      IO.pure(Array<F32> & Nat, (s, step))
    case True{}:
      do IO<Array<F32> & Nat>:
        +t0 : Nat <- IO.now()
        IO.print("reading " ++ shard.path(hs, seg))
        +xs : List<&2, U32> <- B.Bytes.read_all(shard.path(hs, seg))
        seg.read(seg, rn, hp, hs, muon, first, t0, Cc.corpus(xs), step, s)

def seg.run(+seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, r: Array<F32> & Nat) -> IO(Array<F32> & Nat):
  (s, +step) = r
  seg.run.if(Nat.is_lt(step, Hs.stop(hs)), seg, rn, hp, hs, muon, first, step, s)

def segs.go(ss: List<&2, Pl.Seg>, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, r: Array<F32> & Nat) -> IO(Array<F32> & Nat):
  match ss:
    case Nil{}:
      IO.pure(Array<F32> & Nat, r)
    case +seg <> t:
      do IO<Array<F32> & Nat>:
        r2 : Array<F32> & Nat <- seg.run(seg, rn, hp, hs, muon, first, r)
        segs.go(t, rn, hp, hs, muon, False{}, r2)

def hot.fin(r: Array<F32> & Nat) -> IO(Unit):
  (s, +step) = r
  IO.print("done at step " ++ Nat.show(step))

def run.hot(+c: C.Config, +tok: Tr.Tok, +plan: List<&2, U32>, +hp: Hp, +muon: Bool, +mu: F32, +clip: F32, +wd: F32,
            +hs: Hs, +chunk: Nat, s: Array<F32>) -> IO(Unit):
  +m = L.Dm.of.cc(c, Hp.mb(hp), U32.from_nat(chunk))
  +ly = L.Lay.of(c, m)
  +rn = {Run{m, ly, S.fwd(m, ly), S.bwd(m, ly, F32.div(1.0, F32.from_nat(Nat.div(Hp.batch(hp), Hp.mb(hp))))),
            S.update(muon, ly, S.Hy{0.9, 0.999, 1.0e-8, wd, mu}, m, clip)} : Run}
  +step0 = Dk.Src.step(Hs.src(hs))
  +ss = Pl.remaining(Pl.parse(plan), step0)
  do IO<Unit>:
    IO.print("train (dense, hot start): " ++ C.Config.model_id(c) ++ " from step " ++ Nat.show(step0) ++ " to " ++ Nat.show(Hs.stop(hs))
      ++ " of " ++ Nat.show(Hp.total(hp)) ++ "; lr " ++ F32.show(Hp.lr(hp)) ++ ", warmup " ++ Nat.show(Hp.warm(hp))
      ++ ", micro-batch " ++ Nat.show(Hp.mb(hp)) ++ ", " ++ Nat.show(List.length(&2, Pl.Seg, ss)) ++ " segments left")
    r : Array<F32> & Nat <- segs.go(ss, rn, hp, hs, muon, True{}, (s, step0))
    hot.fin(r)

# Evaluate (EVAL_CORPUS set): master's `evaluate` on the dense forward. Every
# document's full windows (no split) are scored; the loss is the mean over
# windows (all full, so the mean over predictions), and bits per byte scale
# it by predictions / (bytes the ordinary targets decode to · ln 2).

def pad.to(+mb: Nat, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  +n = List.length(&2, List<&2, U32>, ws)
  List.append(&2, List<&2, U32>, ws, List.replicate(List<&2, U32>, Nat.mod(Nat.sub(mb, Nat.mod(n, mb)), mb), [0]))

def real(ws: List<&2, List<&2, U32>>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case +w <> t:
      Nat.add(Bool.pick(Nat, Nat.is_lt(1n, List.length(&2, U32, w)), 1n, 0n), real(t))

type Ea is Data:
  Ea{sum: F32, n: Nat}

def Ea.add(+k: Nat, +l: F32, a: Ea) -> Ea:
  match a:
    case Ea{+sum, +n}:
      Ea{F32.add(sum, F32.mul(l, F32.from_nat(k))), Nat.add(n, k)}

def eval.add(+k: Nat, +a: Ea, r: Array<F32> & F32) -> Array<F32> & Ea:
  (s, +l) = r
  (s, Ea.add(k, l, a))

def eval.one(+mw: List<&2, List<&2, U32>>, +rn: Run, r: Array<F32> & Ea) -> Array<F32> & Ea:
  (s, +a) = r
  +k = real(mw)
  eval.add(k, a, Io.get1(P.run(Run.fwd(rn), put(mw, rn, s)), L.Lay.lmean(Run.ly(rn))))

def eval.go(ms: List<&2, List<&2, List<&2, U32>>>, +rn: Run, r: Array<F32> & Ea) -> Array<F32> & Ea:
  match ms:
    case Nil{}:
      r
    case mw <> t:
      eval.go(t, rn, eval.one(mw, rn, r))

def eval.print(+scale: F32, +preds: Nat, +bytes: Nat, a: Ea) -> IO(Unit):
  match a:
    case Ea{+sum, +n}:
      +loss = F32.div(sum, F32.from_nat(Nat.max(n, 1n)))
      do IO<Unit>:
        IO.print("windows: " ++ Nat.show(n) ++ "  predictions: " ++ Nat.show(preds) ++ "  bytes: " ++ Nat.show(bytes))
        IO.print("loss: " ++ F32.show(loss) ++ " nats/token")
        IO.print("bits_per_byte: " ++ F32.show(F32.mul(loss, scale)))

def eval.fin(+scale: F32, +nw: Nat, +preds: Nat, +bytes: Nat, r: Array<F32> & Ea) -> IO(Unit):
  (s, a) = r
  eval.print(scale, preds, bytes, a)

def eval.run(+c: C.Config, +tok: Tr.Tok, +mb: Nat, +chunk: Nat, +path: String, +limit: Nat, +xs: List<&2, U32>,
             r: Array<F32> & Dk.Src) -> IO(Unit):
  (s, +src) = r
  +m = L.Dm.of.cc(c, mb, U32.from_nat(chunk))
  +ly = L.Lay.of(c, m)
  +rn = {Run{m, ly, S.fwd(m, ly), Nil{}, Nil{}} : Run}
  +co = Cc.corpus(xs)
  +all = D.all.windows(C.Config.ctx(c), Cc.Corpus.docs(co))
  +ws = Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(limit, 0n), all, List.take(&2, List<&2, U32>, all, limit))
  +preds = Ev.all.predictions(ws)
  +bytes = Ev.all.bytes(Tr.Tok.b(tok), ws)
  +scale = F32.div(F32.from_nat(preds), F32.mul(F32.from_nat(bytes), F32.log(2.0)))
  do IO<Unit>:
    u : Unit <- Dk.fail.if(Cc.Corpus.problem(co, Tr.Tok.id(tok)))
    IO.print("evaluate (dense): step " ++ Nat.show(Dk.Src.step(src)) ++ " on " ++ path ++ " (" ++ Cc.Corpus.dataset(co) ++ ")")
    eval.fin(scale, List.length(&2, List<&2, U32>, ws), preds, bytes, eval.go(micros(mb, pad.to(mb, ws)), rn, (s, Ea{0.0, 0n})))

# TRAIN_OPT unset: the checkpoint's optimizer (Muon when it carries momentum)
def start.hot.go(+c: C.Config, +tok: Tr.Tok, +plan: List<&2, U32>, +steps: Nat, +batch: Nat, +mb: Nat, +lr_s: String,
                 +wd_s: String, +warm_s: String, +opt: String, +mu_s: String, +clip_s: String, +every: Nat, +evals: Nat,
                 +out: String, +save: Nat, +dir: String, +size: String, +chunk: Nat, r: Array<F32> & Dk.Src) -> IO(Unit):
  (s, +src) = r
  +stop = Nat.min(Nat.add(Dk.Src.step(src), steps), Dk.Src.total(src))
  do IO<Unit>:
    u : Unit <- Dk.fail.if(Bool.pick(String, U32.is_eq(Dk.Manifest.version(Dk.Src.man(src)), 4), "",
      "training continues version-4 checkpoints only (this one can be evaluated)"))
    run.hot(c, tok, plan,
      Hp{Tr.f32.or(lr_s, Dk.Src.lr(src)), Tr.nat.or(warm_s, Dk.Src.warm(src)), Dk.Src.total(src), batch, every, mb},
      Bool.or(String.eq(opt, "muon"), Bool.and(String.is_empty(opt), Dk.Src.mom(src))),
      Tr.f32.or(mu_s, Dk.Src.mu(src)), Tr.f32.or(clip_s, Dk.Src.clip(src)), Tr.f32.or(wd_s, Dk.Src.wd(src)),
      Hs{src, out, save, stop, dir, size, evals, Tr.Tok.id(tok), C.Config.ctx(c)}, chunk, s)

def start.hot.pick(train: Bool, +c: C.Config, +tok: Tr.Tok, +plan: List<&2, U32>, +steps: Nat, +batch: Nat, +mb: Nat,
                   +lr_s: String, +wd_s: String, +warm_s: String, +opt: String, +mu_s: String, +clip_s: String,
                   +every: Nat, +evals_s: String, +out: String, +save: Nat, +dir: String, +size: String, +chunk: Nat,
                   +evc: String, +xs: List<&2, U32>, r: Array<F32> & Dk.Src) -> IO(Unit):
  match train:
    case True{}:
      start.hot.go(c, tok, plan, steps, batch, mb, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every,
        Tr.nat.or(evals_s, 256n), out, save, dir, size, chunk, r)
    case False{}:
      eval.run(c, tok, mb, chunk, evc, Tr.nat.or(evals_s, 0n), xs, r)

def start.hot.man(+init: String, +tokf: String, +steps_s: String, +batch_s: String, +micro_s: String,
                  +lr_s: String, +wd_s: String, +warm_s: String, +opt: String, +mu_s: String, +clip_s: String,
                  +every_s: String, +evals_s: String, +out: String, +save_s: String, +dir: String, +size: String,
                  +chunk_s: String, +plan: List<&2, U32>, +tb: List<&2, U32>, +evc: String, +xs: List<&2, U32>,
                  +t0: Nat, mh: Km.Manifest & Nat) -> IO(Unit):
  (+man, +h) = mh
  +c = Km.Manifest.cfg(man)
  +tok = Tr.tok.of(tokf, tb)
  +batch = Tr.nat.or(batch_s, 64n)
  +mb = Tr.nat.or(micro_s, Nat.min(batch, 32n))
  +chunk = Tr.nat.or(chunk_s, 16n)
  +m = L.Dm.of.cc(c, mb, U32.from_nat(chunk))
  +ly = L.Lay.of(c, m)
  do IO<Unit>:
    r : Array<F32> & Dk.Src <- Dk.load(init, man, h, Tr.Tok.id(tok), ly, m, Array.new(F32, L.Lay.depth(ly), 0.0))
    +t1 : Nat <- IO.now()
    IO.print("loaded " ++ init ++ " (" ++ Nat.show(Nat.sub(t1, t0)) ++ " ms)")
    start.hot.pick(String.is_empty(evc), c, tok, plan, Tr.nat.or(steps_s, 100n), batch, mb, lr_s, wd_s, warm_s, opt,
      mu_s, clip_s, Tr.nat.or(every_s, 0n), evals_s, out, Tr.nat.or(save_s, 1000n), dir, size, chunk, evc, xs, r)

# the model is the checkpoint's (its manifest's Config; PRESET is not read)
def start.hot(+init: String, +tokf: String, +steps_s: String, +batch_s: String, +micro_s: String,
              +lr_s: String, +wd_s: String, +warm_s: String, +opt: String, +mu_s: String, +clip_s: String,
              +every_s: String, +evals_s: String, +out: String, +save_s: String, +dir: String, +size: String,
              +chunk_s: String, +plan: List<&2, U32>, +tb: List<&2, U32>, +evc: String, +xs: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    mh : Km.Manifest & Nat <- Dk.header(init)
    start.hot.man(init, tokf, steps_s, batch_s, micro_s, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every_s, evals_s,
      out, save_s, dir, size, chunk_s, plan, tb, evc, xs, t0, mh)

def or.str(empty: Bool, +s: String, +d: String) -> String:
  match empty:
    case True{}:
      d
    case False{}:
      s

# EVAL_CORPUS set: evaluate the checkpoint on it (no plan is read)
def main.hot.data(ev: Bool, +plan_p: String, +evc: String) -> IO(List<&2, U32>):
  match ev:
    case True{}:
      B.Bytes.read_all(evc)
    case False{}:
      B.Bytes.read_all(plan_p)

def main.hot(+init: String, +tokf: String, +pre: String, +steps_s: String, +batch_s: String, +micro_s: String,
             +lr_s: String, +wd_s: String, +warm_s: String, +opt: String, +mu_s: String, +clip_s: String,
             +every_s: String, +evals_s: String, +out: String, +chunk_s: String) -> IO(Unit):
  do IO<Unit>:
    +plan_p : String <- Tr.env("PLAN", "run/mixed-bpe100m-s32000/plan-bpe100m-b64-s32000.tsv")
    +dir : String <- Tr.env("RUN_DIR", "run/mixed-bpe100m-s32000")
    +size : String <- Tr.env("SHARD_SIZE", "bpe100m")
    +save_s : String <- Tr.env("SAVE_EVERY", "1000")
    +evc : String <- Tr.env("EVAL_CORPUS", "")
    +data : List<&2, U32> <- main.hot.data(Bool.not(String.is_empty(evc)), plan_p, evc)
    +tb : List<&2, U32> <- Tr.tok.read(tokf)
    start.hot(init, tokf, steps_s, batch_s, micro_s, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every_s, evals_s,
      out, save_s, dir, size, chunk_s, data, tb, evc, data)

def main.cold(+corpus: String, +tokf: String, +pre: String, +steps_s: String, +batch_s: String, +micro_s: String,
              +lr_s: String, +wd_s: String, +warm_s: String, +opt: String, +mu_s: String, +clip_s: String,
              +every_s: String, +evals_s: String, +out: String, +chunk_s: String) -> IO(Unit):
  do IO<Unit>:
    +text : List<&2, U32> <- B.Bytes.read_all(corpus)
    +tb : List<&2, U32> <- Tr.tok.read(tokf)
    start(tokf, pre, steps_s, batch_s, micro_s, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every_s, evals_s, out, chunk_s, text, tb)

def main.pick(hot: Bool, +init: String, +corpus: String, +tokf: String, +pre: String, +steps_s: String, +batch_s: String,
              +micro_s: String, +lr_s: String, +wd_s: String, +warm_s: String, +opt: String, +mu_s: String,
              +clip_s: String, +every_s: String, +evals_s: String, +out: String, +chunk_s: String) -> IO(Unit):
  match hot:
    case True{}:
      main.hot(init, tokf, pre, steps_s, batch_s, micro_s, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every_s, evals_s,
        or.str(String.is_empty(out), out, "run/bend-hot"), chunk_s)
    case False{}:
      main.cold(corpus, tokf, pre, steps_s, batch_s, micro_s, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every_s, evals_s,
        or.str(String.is_empty(out), out, "run/bend-train.btc"), chunk_s)

def main() -> IO(Unit):
  do IO<Unit>:
    +init : String <- Tr.env("TRAIN_INIT", "")
    +corpus : String <- Tr.env("CORPUS", "README.md")
    +tokf : String <- Tr.env("TOKENIZER_FILE", "")
    +pre : String <- Tr.env("PRESET", "small4-v3")
    +steps_s : String <- Tr.env("TRAIN_STEPS", "100")
    +batch_s : String <- Tr.env("TRAIN_BATCH", "")
    +micro_s : String <- Tr.env("TRAIN_MICRO", "")
    +lr_s : String <- Tr.env("TRAIN_LR", "")
    +wd_s : String <- Tr.env("TRAIN_WD", "")
    +warm_s : String <- Tr.env("TRAIN_WARMUP", "")
    +opt : String <- Tr.env("TRAIN_OPT", "")
    +mu_s : String <- Tr.env("TRAIN_MUON_BETA", "")
    +clip_s : String <- Tr.env("GRAD_CLIP", "")
    +every_s : String <- Tr.env("EVAL_EVERY", "")
    +evals_s : String <- Tr.env("EVAL_WINDOWS", "")
    +out : String <- Tr.env("OUT", "")
    +chunk_s : String <- Tr.env("TRAIN_CHUNK", "")
    main.pick(Bool.not(String.is_empty(init)), init, corpus, tokf, pre, steps_s, batch_s, micro_s, lr_s, wd_s, warm_s, opt,
      mu_s, clip_s, every_s, evals_s, out, chunk_s)
