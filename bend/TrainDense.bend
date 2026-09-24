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

# train, dense: master's trainer on the Bend2 port at GPU speed. The same
# environment and log as Train.bend (the tree trainer, kept as the
# reference), plus
#   TRAIN_MICRO  windows per micro-batch (default: the batch, at most 32);
#                the batch's micro-batches accumulate one gradient
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
        +steps: Nat, +out: String, +evals: Nat) -> IO(Unit):
  +sp = D.split(D.encode.all(Tr.Tok.b(tok), D.documents(text)))
  +train = D.all.windows(C.Config.ctx(c), Tr.split.train(sp))
  +vw = List.take(&2, List<&2, U32>, D.all.windows(C.Config.ctx(c), Tr.split.valid(sp)), evals)
  +nw = List.length(&2, List<&2, U32>, train)
  +m = L.Dm.of(c, Hp.mb(hp))
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
          +text: List<&2, U32>, +tb: List<&2, U32>) -> IO(Unit):
  +steps = Tr.nat.or(steps_s, 100n)
  +batch = Tr.nat.or(batch_s, 4n)
  +mb = Tr.nat.or(micro_s, Nat.min(batch, 32n))
  run(Tr.preset(pre), Tr.tok.of(tokf, tb), text,
      Hp{Tr.f32.or(lr_s, 3.0e-4), Nat.min(Tr.nat.or(warm_s, 100n), steps), steps, batch, Tr.nat.or(every_s, 0n), mb},
      String.eq(opt, "muon"), Tr.f32.or(mu_s, 0.95), Tr.f32.or(wd_s, 0.01), Tr.f32.or(clip_s, 1.0),
      steps, out, Tr.nat.or(evals_s, 16n))

def main() -> IO(Unit):
  do IO<Unit>:
    +corpus : String <- Tr.env("CORPUS", "README.md")
    +tokf : String <- Tr.env("TOKENIZER_FILE", "")
    +pre : String <- Tr.env("PRESET", "small4-v3")
    +steps_s : String <- Tr.env("TRAIN_STEPS", "100")
    +batch_s : String <- Tr.env("TRAIN_BATCH", "4")
    +micro_s : String <- Tr.env("TRAIN_MICRO", "")
    +lr_s : String <- Tr.env("TRAIN_LR", "3e-4")
    +wd_s : String <- Tr.env("TRAIN_WD", "0.01")
    +warm_s : String <- Tr.env("TRAIN_WARMUP", "100")
    +opt : String <- Tr.env("TRAIN_OPT", "adamw")
    +mu_s : String <- Tr.env("TRAIN_MUON_BETA", "0.95")
    +clip_s : String <- Tr.env("GRAD_CLIP", "1")
    +every_s : String <- Tr.env("EVAL_EVERY", "0")
    +evals_s : String <- Tr.env("EVAL_WINDOWS", "16")
    +out : String <- Tr.env("OUT", "run/bend-train.btc")
    +text : List<&2, U32> <- B.Bytes.read_all(corpus)
    +tb : List<&2, U32> <- Tr.tok.read(tokf)
    start(tokf, pre, steps_s, batch_s, micro_s, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every_s, evals_s, out, text, tb)
