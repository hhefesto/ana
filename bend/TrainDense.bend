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
import ./Tokenizer.bend as Tk

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
# the first step. The log lines carry master's fields (step=, lr=,
# train_loss=, train_loss_ema=, gradient_norm=, clipped=, validation_loss=,
# validation_delta=, best_validation_loss=, new_best=, bits_per_byte=)
# plus ms=, tok/s=, remaining= and eta=, each line behind a Mexico City
# timestamp.
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

# The run's hyperparameters: the schedule (lr, warmup, total), the batch and
# micro-batch, the validation period, the clip norm, tokens per step (for
# throughput) and Adam's betas and epsilon
type Hp is Data:
  Hp{lr: F32, warm: Nat, total: Nat, batch: Nat, every: Nat, mb: Nat, clip: F32, toks: Nat, b1: F32, b2: F32, eps: F32}

def Hp.lr(+h: Hp) -> F32:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      a

def Hp.warm(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      b

def Hp.total(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      c

def Hp.batch(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      d

def Hp.every(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      e

def Hp.mb(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      f

def Hp.clip(+h: Hp) -> F32:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      g

def Hp.toks(+h: Hp) -> Nat:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      h

def Hp.b1(+h: Hp) -> F32:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      i

def Hp.b2(+h: Hp) -> F32:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      j

def Hp.eps(+h: Hp) -> F32:
  match h:
    case Hp{a, b, c, d, e, f, g, h, i, j, k}:
      k

# the step's scalars: learning rate, 1 - b1^t, 1 - b2^t
def hyper(+hp: Hp, +ly: L.Lay, +lr: F32, +step: Nat, s: Array<F32>) -> Array<F32>:
  Io.put([lr, F32.sub(1.0, F32.pow(Hp.b1(hp), F32.from_nat(step))), F32.sub(1.0, F32.pow(Hp.b2(hp), F32.from_nat(step)))], s, S.cell.lr(ly))

def step.fin(+rn: Run, +hp: Hp, +lr: F32, +step: Nat, +k: F32, r: Array<F32> & F32) -> Array<F32> & F32 & F32:
  (s, l) = r
  +ly = Run.ly(rn)
  Out.fin(F32.div(l, k), Io.get1(P.run(Run.upd(rn), hyper(hp, ly, lr, step, s)), L.Lay.gnorm(ly)))

# one optimizer step: zero the gradients, accumulate the micro-batches,
# clip and update
def train.step(+rn: Run, +hp: Hp, bw: List<&2, List<&2, U32>>, +lr: F32, +step: Nat, s: Array<F32>) -> Array<F32> & F32 & F32:
  +ms = micros(Hp.mb(hp), bw)
  +k = F32.from_nat(List.length(&2, List<&2, List<&2, U32>>, ms))
  step.fin(rn, hp, lr, step, k, micro.go(ms, rn, (P.run(S.zero.grads(Run.ly(rn)), s), 0.0)))

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

# Clock --------------------------------------------------------------------

# Every line is stamped in the user's local time, Mexico City: UTC-6 with
# no daylight saving (since 2022). IO.time is the wall clock in ms.

def pad2(+x: U32) -> String:
  Bool.pick(String, U32.is_lt(x, 10), "0", "") ++ U32.show(x)

# days since 1970-01-01 as y-m-d (Hinnant's civil_from_days; every
# intermediate is nonnegative, so U32 subtraction is exact)
def civil(+z0: U32) -> String:
  +z = U32.add(z0, 719468)
  +era = U32.div(z, 146097)
  +doe = U32.sub(z, U32.mul(era, 146097))
  +yoe = U32.div(U32.sub(U32.add(doe, U32.div(doe, 36524)), U32.add(U32.div(doe, 1460), U32.div(doe, 146096))), 365)
  +doy = U32.sub(doe, U32.sub(U32.add(U32.mul(365, yoe), U32.div(yoe, 4)), U32.div(yoe, 100)))
  +mp = U32.div(U32.add(U32.mul(5, doy), 2), 153)
  +d = U32.add(U32.sub(doy, U32.div(U32.add(U32.mul(153, mp), 2), 5)), 1)
  +m = Bool.pick(U32, U32.is_lt(mp, 10), U32.add(mp, 3), U32.sub(mp, 9))
  +y = U32.add(U32.add(yoe, U32.mul(era, 400)), Bool.pick(U32, U32.is_le(m, 2), 1, 0))
  U32.show(y) ++ "-" ++ pad2(m) ++ "-" ++ pad2(d)

# "[YYYY-MM-DD HH:MM:SS CDMX]" for a wall-clock reading in ms
def stamp(+ms: Nat) -> String:
  +t = U32.sub(U32.from_nat(Nat.div(ms, U32.to_nat(1000))), 21600)
  +s = U32.mod(t, 86400)
  "[" ++ civil(U32.div(t, 86400)) ++ " " ++ pad2(U32.div(s, 3600)) ++ ":" ++ pad2(U32.div(U32.mod(s, 3600), 60))
    ++ ":" ++ pad2(U32.mod(s, 60)) ++ " CDMX]"

# print a log line behind its timestamp
def say(+line: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- IO.time()
    IO.print(stamp(t) ++ " " ++ line)

# Progress -----------------------------------------------------------------

# What the log carries between steps: the training-loss EMA (master's
# decay 0.98, seeded by the first loss), the steps and milliseconds run so
# far, and the previous and best validation losses (seen: there is one).
type St is Data:
  St{ema: F32, n: Nat, ms: Nat, prev: F32, seen: Bool, best: F32}

def St.init() -> St:
  St{0.0, 0n, 0n, 0.0, False{}, 0.0}

def St.ema(+st: St) -> F32:
  match st:
    case St{e, n, ms, p, sn, b}:
      e

def ema.next(first: Bool, +ema: F32, +l: F32) -> F32:
  match first:
    case True{}:
      l
    case False{}:
      F32.add(F32.mul(0.98, ema), F32.mul(0.02, l))

# after a step of dt ms with loss l
def St.step(+l: F32, +dt: Nat, st: St) -> St:
  match st:
    case St{ema, +n, ms, p, sn, b}:
      St{ema.next(Nat.is_eq(n, 0n), ema, l), 1n+n, Nat.add(ms, dt), p, sn, b}

# a/b as a percentage, three decimals
def pct(+a: Nat, +b: Nat) -> String:
  F32.show(F32.div(F32.round(F32.mul(100000.0, F32.div(F32.from_nat(a), F32.from_nat(Nat.max(b, 1n))))), 1000.0))

# (large Nat literals expand at compile time, so the constants below are U32)

def hm(+ms: Nat) -> String:
  +s = Nat.div(ms, U32.to_nat(1000))
  Nat.show(Nat.div(s, U32.to_nat(3600))) ++ "h" ++ Nat.show(Nat.div(Nat.mod(s, U32.to_nat(3600)), U32.to_nat(60))) ++ "m"

# master's step line (backend/gpu/Main.hs logTraining) plus the step's
# time and throughput
def step.line(+hp: Hp, +step: Nat, +lr: F32, +l: F32, +g: F32, +dt: Nat, st: St) -> String & St:
  +st2 = St.step(l, dt, st)
  ("step=" ++ Nat.show(step) ++ "/" ++ Nat.show(Hp.total(hp)) ++ " progress=" ++ pct(step, Hp.total(hp)) ++ "%"
    ++ " lr=" ++ F32.show(lr) ++ " train_loss=" ++ F32.show(l) ++ " train_loss_ema=" ++ F32.show(St.ema(st2))
    ++ " gradient_norm=" ++ F32.show(g) ++ " clipped=" ++ Bool.show(F32.is_gt(g, Hp.clip(hp)))
    ++ " ms=" ++ Nat.show(dt) ++ " tok/s=" ++ Nat.show(Nat.div(Nat.mul(Hp.toks(hp), U32.to_nat(1000)), Nat.max(dt, 1n))), st2)

def delta.text(seen: Bool, +prev: F32, +l: F32) -> String:
  match seen:
    case True{}:
      F32.show(F32.sub(l, prev))
    case False{}:
      "na"

def eta.text(none: Bool, +ms: Nat) -> String:
  match none:
    case True{}:
      "na"
    case False{}:
      hm(ms)

# master's validation fields, bits per byte over the validation windows
# (scale), and the time `left` steps take at the mean step time so far
def valid.line(+step: Nat, +l: F32, +scale: F32, +left: Nat, st: St) -> String & St:
  match st:
    case St{ema, +n, +ms, +prev, +seen, +best}:
      +best2 = Bool.pick(F32, Bool.and(seen, F32.is_le(best, l)), best, l)
      ("step=" ++ Nat.show(step) ++ " validation_loss=" ++ F32.show(l) ++ " validation_delta=" ++ delta.text(seen, prev, l)
        ++ " best_validation_loss=" ++ F32.show(best2) ++ " new_best=" ++ Bool.show(Bool.or(Bool.not(seen), F32.is_lt(l, best)))
        ++ " bits_per_byte=" ++ F32.show(F32.mul(l, scale)) ++ " remaining=" ++ Nat.show(left)
        ++ " eta=" ++ eta.text(Nat.is_eq(n, 0n), Nat.mul(Nat.div(ms, Nat.max(n, 1n)), left)), St{ema, n, ms, l, True{}, best2})

def print.st(r: String & St, s: Array<F32>) -> IO(Array<F32> & St):
  (line, st) = r
  do IO<Array<F32> & St>:
    say(line)
    return (s, st)

def loop.print.lg(+hp: Hp, +step2: Nat, +lr: F32, +t0: Nat, s: Array<F32>, lg: F32 & F32, st: St) -> IO(Array<F32> & St):
  (+l, +g) = lg
  do IO<Array<F32> & St>:
    +t1 : Nat <- IO.now()
    print.st(step.line(hp, step2, lr, l, g, Nat.sub(t1, t0), st), s)

def loop.print(+hp: Hp, +step2: Nat, +lr: F32, +t0: Nat, st: St, r: Array<F32> & F32 & F32) -> IO(Array<F32> & St):
  (s, lg) = r
  loop.print.lg(hp, step2, lr, t0, s, lg, st)

def report.valid.print(+step: Nat, +scale: F32, +left: Nat, st: St, r: Array<F32> & F32) -> IO(Array<F32> & St):
  (s, +l) = r
  print.st(valid.line(step, l, scale, left, st), s)

def report.valid(on: Bool, +rn: Run, +hp: Hp, +vw: List<&2, List<&2, U32>>, +step: Nat, +scale: F32, +left: Nat,
                 st: St, s: Array<F32>) -> IO(Array<F32> & St):
  match on:
    case True{}:
      report.valid.print(step, scale, left, st, valid(rn, Hp.mb(hp), vw, s))
    case False{}:
      IO.pure(Array<F32> & St, (s, st))

def report.valid.r(on: Bool, +rn: Run, +hp: Hp, +vw: List<&2, List<&2, U32>>, +step: Nat, +scale: F32, +left: Nat,
                   r: Array<F32> & St) -> IO(Array<F32> & St):
  (s, st) = r
  report.valid(on, rn, hp, vw, step, scale, left, st, s)

# bits per byte of a mean loss over these windows: predictions / (bytes the
# ordinary targets decode to . ln 2) (master's bitsPerByteScale)
def bpb.scale(+b: Tk.Bpe, +ws: List<&2, List<&2, U32>>) -> F32:
  F32.div(F32.from_nat(Ev.all.predictions(ws)), F32.mul(F32.from_nat(Nat.max(Ev.all.bytes(b, ws), 1n)), F32.log(2.0)))

# The loop -----------------------------------------------------------------

def loop(n: Nat, +rn: Run, +hp: Hp, +ws: List<&2, List<&2, U32>>, +nw: Nat, +vw: List<&2, List<&2, U32>>,
         +scale: F32, +step: Nat, r: Array<F32> & St) -> IO(Array<F32> & St):
  match n:
    case 0n:
      IO.pure(Array<F32> & St, r)
    case 1n+p:
      (s, st) = r
      +step2 = {1n+step : Nat}
      +lr = O.lr.at(Hp.lr(hp), step2, Hp.warm(hp), Hp.total(hp))
      +every = Hp.every(hp)
      do IO<Array<F32> & St>:
        +t0 : Nat <- IO.now()
        r2 : Array<F32> & St <- loop.print(hp, step2, lr, t0, st, train.step(rn, hp, Tr.batch.at(ws, nw, step, Hp.batch(hp)), lr, step2, s))
        r3 : Array<F32> & St <- report.valid.r(Bool.or(Nat.is_eq(step2, Hp.total(hp)),
          Bool.and(Nat.is_lt(0n, every), Nat.is_eq(Nat.mod(step2, Nat.max(every, 1n)), 0n))), rn, hp, vw, step2, scale,
          Nat.sub(Hp.total(hp), step2), r2)
        loop(p, rn, hp, ws, nw, vw, scale, step2, r3)

def params.fin(r: Array<F32> & List<&2, F32>) -> List<&2, F32>:
  (s, xs) = r
  xs

def finish.save(+c: C.Config, +tok: Tr.Tok, +steps: Nat, +out: String, +rn: Run, s: Array<F32>) -> IO(Unit):
  do IO<Unit>:
    save(out, c, Tr.Tok.id(tok), steps, params.fin(Io.get(U32.to_nat(L.Lay.params(Run.ly(rn))), s, 0)))
    say("wrote " ++ out)

# OUT empty: no checkpoint
def finish.if(skip: Bool, +c: C.Config, +tok: Tr.Tok, +steps: Nat, +out: String, +rn: Run, s: Array<F32>) -> IO(Unit):
  match skip:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      finish.save(c, tok, steps, out, rn, s)

def finish(+c: C.Config, +tok: Tr.Tok, +steps: Nat, +out: String, +rn: Run, r: Array<F32> & St) -> IO(Unit):
  (s, st) = r
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
            S.update(muon, ly, S.Hy{Hp.b1(hp), Hp.b2(hp), Hp.eps(hp), wd, mu}, m, clip)} : Run}
  +scale = bpb.scale(Tr.Tok.b(tok), vw)
  do IO<Unit>:
    say("train (dense): " ++ C.Config.model_id(c))
    say("tokenizer " ++ Tr.Tok.id(tok) ++ "; " ++ Nat.show(nw) ++ " training windows, " ++ Nat.show(List.length(&2, List<&2, U32>, vw))
      ++ " validation windows; micro-batch " ++ Nat.show(Hp.mb(hp)) ++ ", store " ++ U32.show(L.Lay.total(ly)) ++ " floats")
    r0 : Array<F32> & St <- report.valid(True{}, rn, hp, vw, 0n, scale, steps, St.init(),
      Io.put(K.Weights.flat(I.init(c)), Array.new(F32, L.Lay.depth(ly), 0.0), 0))
    r1 : Array<F32> & St <- loop(steps, rn, hp, train, Nat.max(nw, 1n), vw, scale, 0n, r0)
    finish(c, tok, steps, out, rn, r1)

def start(+tokf: String, +pre: String, +steps_s: String, +batch_s: String, +micro_s: String, +lr_s: String, +wd_s: String,
          +warm_s: String, +opt: String, +mu_s: String, +clip_s: String, +every_s: String, +evals_s: String, +out: String,
          +chunk_s: String, +text: List<&2, U32>, +tb: List<&2, U32>) -> IO(Unit):
  +steps = Tr.nat.or(steps_s, 100n)
  +batch = Tr.nat.or(batch_s, 4n)
  +mb = Tr.nat.or(micro_s, Nat.min(batch, 32n))
  +c = Tr.preset(pre)
  +clip = Tr.f32.or(clip_s, 1.0)
  run(c, Tr.tok.of(tokf, tb), text,
      Hp{Tr.f32.or(lr_s, 3.0e-4), Nat.min(Tr.nat.or(warm_s, 100n), steps), steps, batch, Tr.nat.or(every_s, 0n), mb,
         clip, Nat.mul(batch, C.Config.ctx(c)), 0.9, 0.999, 1.0e-8},
      String.eq(opt, "muon"), Tr.f32.or(mu_s, 0.95), Tr.f32.or(wd_s, 0.01), clip,
      steps, out, Tr.nat.or(evals_s, 16n), Tr.nat.or(chunk_s, 16n))

# Hot start ----------------------------------------------------------------

type Hs is Data:
  Hs{src: Dk.Src, out: String, every: Nat, stop: Nat, dir: String, size: String, evals: Nat, tok: Tr.Tok, ctx: Nat}

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

def Hs.tok(+h: Hs) -> Tr.Tok:
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
    say("saved " ++ path ++ " (" ++ Nat.show(Nat.sub(t1, t0)) ++ " ms)")
    return s2

def hot.save.if(on: Bool, +hs: Hs, +rn: Run, +muon: Bool, +step: Nat, s: Array<F32>) -> IO(Array<F32>):
  match on:
    case True{}:
      hot.save(hs, rn, muon, step, s)
    case False{}:
      IO.pure(Array<F32>, s)

def hot.save.r(on: Bool, +hs: Hs, +rn: Run, +muon: Bool, +step: Nat, r: Array<F32> & St) -> IO(Array<F32> & St):
  (s, st) = r
  do IO<Array<F32> & St>:
    s2 : Array<F32> <- hot.save.if(on, hs, rn, muon, step, s)
    return (s2, st)

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
             +vw: List<&2, List<&2, U32>>, +scale: F32, +step: Nat, br: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>,
             r: Array<F32> & St) -> IO(Array<F32> & St):
  match n:
    case 0n:
      IO.pure(Array<F32> & St, r)
    case 1n+p:
      (bw, rest) = br
      (s, st) = r
      +step2 = {1n+step : Nat}
      +lr = O.lr.at(Hp.lr(hp), step2, Hp.warm(hp), Hp.total(hp))
      do IO<Array<F32> & St>:
        +t0 : Nat <- IO.now()
        r2 : Array<F32> & St <- loop.print(hp, step2, lr, t0, st, train.step(rn, hp, bw, lr, step2, s))
        r3 : Array<F32> & St <- report.valid.r(every.at(Hp.every(hp), step2), rn, hp, vw, step2, scale, Nat.sub(Hs.stop(hs), step2), r2)
        r4 : Array<F32> & St <- hot.save.r(Bool.or(every.at(Hs.every(hs), step2), Nat.is_eq(step2, Hs.stop(hs))), hs, rn, muon, step2, r3)
        loop.hot(p, rn, hp, hs, muon, head, vw, scale, step2, batch.next(Hp.batch(hp), head, rest), r4)

def seg.check(ok: Bool, +why: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      Dk.fail.if(why)

def seg.fin(r: Array<F32> & St, +step: Nat) -> Array<F32> & St & Nat:
  (s, st) = r
  {(s, st, step) : Array<F32> & St & Nat}

# one segment's shard: its epoch windows, checked against the plan's count
# as master checks it, then the segment's steps up to the stop
def seg.train(+seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, +co: Cc.Corpus, +step: Nat,
              r: Array<F32> & St) -> IO(Array<F32> & St & Nat):
  (s, st) = r
  +ctx = Hs.ctx(hs)
  +docs = Cc.Corpus.docs(co)
  +ws = Pl.epoch(ctx, Pl.Seg.offset(seg), docs)
  +nw = List.length(&2, List<&2, U32>, ws)
  +vw = Pl.valid(ctx, Pl.Seg.offset(seg), Hs.evals(hs), docs)
  +n = Nat.sub(Nat.min(Pl.Seg.end(seg), Hs.stop(hs)), step)
  +scale = bpb.scale(Tr.Tok.b(Hs.tok(hs)), vw)
  do IO<Array<F32> & St & Nat>:
    u0 : Unit <- Dk.fail.if(Cc.Corpus.problem(co, Tr.Tok.id(Hs.tok(hs))))
    u1 : Unit <- seg.check(String.eq(Cc.Corpus.dataset(co), Pl.Seg.id(seg)), "segment corpus identity does not match the run plan")
    u2 : Unit <- seg.check(Nat.is_eq(nw, Pl.Seg.tw(seg)), "segment training windows (" ++ Nat.show(nw) ++ ") differ from the plan's")
    say("shard " ++ Nat.show(Pl.Seg.index(seg)) ++ ": " ++ Nat.show(nw) ++ " training windows, global "
      ++ Nat.show(Pl.Seg.start(seg)) ++ ".." ++ Nat.show(Pl.Seg.end(seg)) ++ "; running " ++ Nat.show(step) ++ ".." ++ Nat.show(Nat.add(step, n)))
    r1 : Array<F32> & St <- report.valid(first, rn, hp, vw, step, scale, n, st, s)
    r2 : Array<F32> & St <- loop.hot(n, rn, hp, hs, muon, List.take(&2, List<&2, U32>, ws, Hp.batch(hp)), vw, scale, step,
      batch.next(Hp.batch(hp), List.take(&2, List<&2, U32>, ws, Hp.batch(hp)),
        List.drop(&2, List<&2, U32>, ws, Nat.mod(Nat.mul(Nat.sub(step, Pl.Seg.start(seg)), Hp.batch(hp)), Nat.max(nw, 1n)))), r1)
    return seg.fin(r2, Nat.add(step, n))

def shard.path(+hs: Hs, +seg: Pl.Seg) -> String:
  Hs.dir(hs) ++ "/shard-" ++ Nat.show(Pl.Seg.index(seg)) ++ "-" ++ Hs.size(hs) ++ ".corpus"

def seg.read(+seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, +t0: Nat, +co: Cc.Corpus, +step: Nat,
             r: Array<F32> & St) -> IO(Array<F32> & St & Nat):
  do IO<Array<F32> & St & Nat>:
    +t1 : Nat <- IO.now()
    say("parsed (" ++ Nat.show(Nat.sub(t1, t0)) ++ " ms)")
    seg.train(seg, rn, hp, hs, muon, first, co, step, r)

def seg.run.if(go: Bool, +seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, +step: Nat,
               r: Array<F32> & St) -> IO(Array<F32> & St & Nat):
  match go:
    case False{}:
      IO.pure(Array<F32> & St & Nat, seg.fin(r, step))
    case True{}:
      do IO<Array<F32> & St & Nat>:
        +t0 : Nat <- IO.now()
        say("reading " ++ shard.path(hs, seg))
        +xs : List<&2, U32> <- B.Bytes.read_all(shard.path(hs, seg))
        seg.read(seg, rn, hp, hs, muon, first, t0, Cc.corpus(xs), step, r)

def seg.run.at(+step: Nat, +seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, r: Array<F32> & St) -> IO(Array<F32> & St & Nat):
  seg.run.if(Nat.is_lt(step, Hs.stop(hs)), seg, rn, hp, hs, muon, first, step, r)

def seg.run(+seg: Pl.Seg, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, r: Array<F32> & St & Nat) -> IO(Array<F32> & St & Nat):
  (s, st, step) = r
  seg.run.at(step, seg, rn, hp, hs, muon, first, {(s, st) : Array<F32> & St})

def segs.go(ss: List<&2, Pl.Seg>, +rn: Run, +hp: Hp, +hs: Hs, +muon: Bool, +first: Bool, r: Array<F32> & St & Nat) -> IO(Array<F32> & St & Nat):
  match ss:
    case Nil{}:
      IO.pure(Array<F32> & St & Nat, r)
    case +seg <> t:
      do IO<Array<F32> & St & Nat>:
        r2 : Array<F32> & St & Nat <- seg.run(seg, rn, hp, hs, muon, first, r)
        segs.go(t, rn, hp, hs, muon, False{}, r2)

def hot.fin(r: Array<F32> & St & Nat) -> IO(Unit):
  (s, st, step) = r
  say("done at step " ++ Nat.show(step))

def run.hot(+c: C.Config, +tok: Tr.Tok, +plan: List<&2, U32>, +hp: Hp, +muon: Bool, +mu: F32, +clip: F32, +wd: F32,
            +hs: Hs, +chunk: Nat, s: Array<F32>) -> IO(Unit):
  +m = L.Dm.of.cc(c, Hp.mb(hp), U32.from_nat(chunk))
  +ly = L.Lay.of(c, m)
  +rn = {Run{m, ly, S.fwd(m, ly), S.bwd(m, ly, F32.div(1.0, F32.from_nat(Nat.div(Hp.batch(hp), Hp.mb(hp))))),
            S.update(muon, ly, S.Hy{Hp.b1(hp), Hp.b2(hp), Hp.eps(hp), wd, mu}, m, clip)} : Run}
  +step0 = Dk.Src.step(Hs.src(hs))
  +ss = Pl.remaining(Pl.parse(plan), step0)
  do IO<Unit>:
    say("train (dense, hot start): " ++ C.Config.model_id(c) ++ " from step " ++ Nat.show(step0) ++ " to " ++ Nat.show(Hs.stop(hs))
      ++ " of " ++ Nat.show(Hp.total(hp)) ++ "; lr " ++ F32.show(Hp.lr(hp)) ++ ", warmup " ++ Nat.show(Hp.warm(hp))
      ++ ", " ++ Bool.pick(String, muon, "Muon", "AdamW") ++ ", clip " ++ F32.show(clip)
      ++ ", micro-batch " ++ Nat.show(Hp.mb(hp)) ++ ", " ++ Nat.show(List.length(&2, Pl.Seg, ss)) ++ " segments left")
    r : Array<F32> & St & Nat <- segs.go(ss, rn, hp, hs, muon, True{}, {(s, St.init(), step0) : Array<F32> & St & Nat})
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
        say("windows: " ++ Nat.show(n) ++ "  predictions: " ++ Nat.show(preds) ++ "  bytes: " ++ Nat.show(bytes))
        say("loss: " ++ F32.show(loss) ++ " nats/token")
        say("bits_per_byte: " ++ F32.show(F32.mul(loss, scale)))

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
    say("evaluate (dense): step " ++ Nat.show(Dk.Src.step(src)) ++ " on " ++ path ++ " (" ++ Cc.Corpus.dataset(co) ++ ")")
    eval.fin(scale, List.length(&2, List<&2, U32>, ws), preds, bytes, eval.go(micros(mb, pad.to(mb, ws)), rn, (s, Ea{0.0, 0n})))

# TRAIN_OPT unset: the checkpoint's optimizer (Muon when it carries momentum)
def start.hot.go(+c: C.Config, +tok: Tr.Tok, +plan: List<&2, U32>, +steps: Nat, +batch: Nat, +mb: Nat, +lr_s: String,
                 +wd_s: String, +warm_s: String, +opt: String, +mu_s: String, +clip_s: String, +every: Nat, +evals: Nat,
                 +out: String, +save: Nat, +dir: String, +size: String, +chunk: Nat, r: Array<F32> & Dk.Src) -> IO(Unit):
  (s, +src) = r
  +stop = Nat.min(Nat.add(Dk.Src.step(src), steps), Dk.Src.total(src))
  +clip = Tr.f32.or(clip_s, Dk.Src.clip(src))
  do IO<Unit>:
    u : Unit <- Dk.fail.if(Bool.pick(String, U32.is_eq(Dk.Manifest.version(Dk.Src.man(src)), 4), "",
      "training continues version-4 checkpoints only (this one can be evaluated)"))
    run.hot(c, tok, plan,
      Hp{Tr.f32.or(lr_s, Dk.Src.lr(src)), Tr.nat.or(warm_s, Dk.Src.warm(src)), Dk.Src.total(src), batch, every, mb,
         clip, Nat.mul(batch, C.Config.ctx(c)), Dk.Src.b1(src), Dk.Src.b2(src), Dk.Src.eps(src)},
      Bool.or(String.eq(opt, "muon"), Bool.and(String.is_empty(opt), Dk.Src.mom(src))),
      Tr.f32.or(mu_s, Dk.Src.mu(src)), clip, Tr.f32.or(wd_s, Dk.Src.wd(src)),
      Hs{src, out, save, stop, dir, size, evals, tok, C.Config.ctx(c)}, chunk, s)

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
    say("loaded " ++ init ++ " (" ++ Nat.show(Nat.sub(t1, t0)) ++ " ms)")
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
