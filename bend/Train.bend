import Base
import ./Num.bend as N
import ./Bytes.bend as B
import ./Tensor.bend as T
import ./Config.bend as C
import ./Model.bend as Md
import ./Tokenizer.bend as Tk
import ./Train/Grad.bend as G
import ./Train/Init.bend as I
import ./Train/Opt.bend as O
import ./Train/Data.bend as D
import ./Train/Ckpt.bend as K
# train: master's trainer (backend/gpu/Main.hs train) on the Bend2 port.
#
#   CORPUS          a text file; documents are cut at blank lines
#   TOKENIZER_FILE  a .bpe artifact; without one, the byte tokenizer
#   PRESET          tiny | tiny-v3 | small | small4 | small4-v3 | bpe10m | bpe10m-v3
#   TRAIN_STEPS, TRAIN_BATCH, TRAIN_LR, TRAIN_WD, TRAIN_WARMUP, TRAIN_OPT
#   (adamw | muon), TRAIN_MUON_BETA, GRAD_CLIP -- master's names and defaults
#   EVAL_EVERY      validation loss every n steps (0: only at the end)
#   OUT             the BTC1 checkpoint written at the end
#
# Windows are master's (full, non-overlapping, BOS/EOS framed, width =
# context); the batch walks the training windows in order, cyclically.
# The gradient of a batch is the mean of the windows' gradients (the
# micro-batch theorem of Spec/Batch.bend), clipped to GRAD_CLIP by global
# norm, then one AdamW or Muon step.
def env.or(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

def env(name: String, d: String) -> IO(String):
  do IO<String>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env.or(r, d)

def f32.or(+s: String, +d: F32) -> F32:
  Maybe.default(&2, F32, F32.read(s), d)

def f32.nat(m: Maybe<&2, U32>, d: Nat) -> Nat:
  match m:
    case Some{x}:
      U32.to_nat(x)
    case None{}:
      d

def nat.or(+s: String, +d: Nat) -> Nat:
  f32.nat(U32.read(s), d)

def preset.pick(+s: String, +name: String, +c: C.Config, +rest: C.Config) -> C.Config:
  Bool.pick(C.Config, String.eq(s, name), c, rest)

# master's presets by name (Config.sizePresets); anything else is small4-v3
def preset(+s: String) -> C.Config:
  preset.pick(s, "tiny", C.Config.tiny(),
  preset.pick(s, "tiny-v3", C.Config{U32.to_nat(258), 16n, 16n, 48n, 1n, 2n, True{}, True{}, True{}, True{}},
  preset.pick(s, "small", C.Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 2n, 4n, False{}, False{}, False{}, True{}},
  preset.pick(s, "small4", C.Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 4n, 4n, False{}, False{}, False{}, True{}},
  preset.pick(s, "bpe10m", C.Config.bpe10m(),
  preset.pick(s, "bpe10m-v3", C.Config{U32.to_nat(8192), U32.to_nat(256), U32.to_nat(320), U32.to_nat(864), 6n, 5n, True{}, True{}, True{}, True{}},
  preset.pick(s, "bpe100m", C.Config{U32.to_nat(32768), U32.to_nat(256), U32.to_nat(768), U32.to_nat(2048), 12n, 12n, False{}, False{}, False{}, True{}},
  preset.pick(s, "bpe100m-v3", C.Config.bpe100m_v3(), C.Config.small4_v3()))))))))

# the byte tokenizer as a BPE with no merges
def bytes.bpe() -> Tk.Bpe:
  Tk.Bpe{258, True{}, Nil{}, Tk.LZ{}, Tk.LZ{}}

def byte.identity() -> String:
  "lossless-byte-v1:bos=0:eos=1:bytes=2..257"

type Tok is Data:
  Tok{b: Tk.Bpe, id: String}

def tok.parsed(m: Maybe<&2, Tk.Bpe>) -> Tok:
  match m:
    case Some{+b}:
      Tok{b, Tk.Bpe.identity(b)}
    case None{}:
      Tok{bytes.bpe(), byte.identity()}

def tok.of.if(empty: Bool, +xs: List<&2, U32>) -> Tok:
  match empty:
    case True{}:
      Tok{bytes.bpe(), byte.identity()}
    case False{}:
      tok.parsed(Tk.Bpe.parse(xs))

def tok.of(+path: String, +xs: List<&2, U32>) -> Tok:
  tok.of.if(String.is_empty(path), xs)

def Tok.b(+t: Tok) -> Tk.Bpe:
  match t:
    case Tok{b, i}:
      b

def Tok.id(+t: Tok) -> String:
  match t:
    case Tok{b, i}:
      i

# Batches ----------------------------------------------------------------

def inputs(+w: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, w, Nat.sub(List.length(&2, U32, w), 1n))

def targets(+w: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, w, 1n)

type Acc is Data:
  Acc{loss: F32, grad: Md.Weights}

def Acc.add(+g: G.LossGrad, a: Acc) -> Acc:
  match g a:
    case G.LossGrad{l, w} Acc{l2, w2}:
      Acc{F32.add(l, l2), O.W.add(w, w2)}

def batch.grad(ws: List<&2, List<&2, U32>>, +dm: Md.Dims, +w: Md.Weights) -> Acc:
  match ws:
    case Nil{}:
      Acc{0.0, O.W.zero()}
    case +x <> rest:
      Acc.add(G.loss_grad(dm, w, inputs(x), targets(x)), batch.grad(rest, dm, w))

def batch.at(+ws: List<&2, List<&2, U32>>, +n: Nat, +step: Nat, +b: Nat) -> List<&2, List<&2, U32>>:
  List.take(&2, List<&2, U32>, List.append(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, ws, Nat.mod(Nat.mul(step, b), n)), ws), b)

def few(+ws: List<&2, List<&2, U32>>) -> Bool:
  Nat.is_le(List.length(&2, List<&2, U32>, ws), 1n)

def Acc.merge(a: Acc, b: Acc) -> Acc:
  match a b:
    case Acc{l1, w1} Acc{l2, w2}:
      Acc{F32.add(l1, l2), O.W.add(w1, w2)}

# the batch gradient as a balanced fork over windows: the halves are
# independent (Spec/Batch.bend: the mean gradient is the sum of the
# windows' gradients, scaled), so each runs as its own task -- on CPU
# threads, or on GPU lanes under `!`
def batch.fork(k: Nat, one: Bool, +ws: List<&2, List<&2, U32>>, +dm: Md.Dims, +w: Md.Weights) -> Acc:
  match k one:
    case 1n+(+p) False{}:
      +h = Nat.div(List.length(&2, List<&2, U32>, ws), 2n)
      +l = List.take(&2, List<&2, U32>, ws, h)
      +r = List.drop(&2, List<&2, U32>, ws, h)
      a b = batch.fork(p, few(l), l, dm, w) batch.fork(p, few(r), r, dm, w)
      Acc.merge(a, b)
    case _ _:
      batch.grad(ws, dm, w)

def eval.loss(ws: List<&2, List<&2, U32>>, +dm: Md.Dims, +w: Md.Weights) -> F32:
  match ws:
    case Nil{}:
      0.0
    case +x <> rest:
      F32.add(G.loss(dm, w, inputs(x), targets(x)), eval.loss(rest, dm, w))

type Hp is Data:
  Hp{lr: F32, wd: F32, warm: Nat, total: Nat, muon: Bool, mu: F32, clip: F32, batch: Nat, every: Nat}

def Acc.loss(+a: Acc) -> F32:
  match a:
    case Acc{l, g}:
      l

def Acc.grad(+a: Acc) -> Md.Weights:
  match a:
    case Acc{l, g}:
      g

def report.eval(on: Bool, +dm: Md.Dims, +w: Md.Weights, +valid: List<&2, List<&2, U32>>, +step: Nat) -> IO(Unit):
  match on:
    case True{}:
      +n = F32.from_nat(List.length(&2, List<&2, U32>, valid))
      IO.print("step " ++ Nat.show(step) ++ " validation loss " ++ F32.show(F32.div(eval.loss(valid, dm, w), n)))
    case False{}:
      IO.pure(Unit, Unit{})

type SOut is Data:
  SOut{loss: F32, norm: F32, w: Md.Weights, st: O.State}

# one whole optimizer step, pure: the batch gradient, the mean, the clip and
# the AdamW / Muon update.  The loop runs it with `!`, so under --gpu the
# step executes on the device.
def step.pure(+hp: Hp, +c: C.Config, +dm: Md.Dims, +bw: List<&2, List<&2, U32>>, +w: Md.Weights, +st: O.State) -> SOut:
  match hp:
    case Hp{+lr, +wd, +warm, +total, +muon, +mu, +clip, +b, +every}:
      +acc = batch.fork(b, few(bw), bw, dm, w)
      +inv = F32.div(1.0, F32.from_nat(b))
      +g = O.W.scale(inv, Acc.grad(acc))
      +norm = F32.sqrt(O.W.sumsq(g))
      +sc = O.clip.scale(norm, clip)
      +s = O.W.step(muon, lr, 0.9, 0.999, 1.0e-8, wd, mu, warm, total, C.Config.d(c), C.Config.f(c), w, O.W.scale(sc, g), st)
      SOut{F32.mul(Acc.loss(acc), inv), norm, O.Stepped.w(s), O.Stepped.st(s)}

def Hp.total(+hp: Hp) -> Nat:
  match hp:
    case Hp{lr, wd, warm, total, muon, mu, clip, b, every}:
      total

def Hp.every(+hp: Hp) -> Nat:
  match hp:
    case Hp{lr, wd, warm, total, muon, mu, clip, b, every}:
      every

def Hp.lr_at(+hp: Hp, +step: Nat) -> F32:
  match hp:
    case Hp{lr, wd, warm, total, muon, mu, clip, b, every}:
      O.lr.at(lr, step, warm, total)

def Hp.batch(+hp: Hp) -> Nat:
  match hp:
    case Hp{lr, wd, warm, total, muon, mu, clip, b, every}:
      b

def SOut.loss(+o: SOut) -> F32:
  match o:
    case SOut{l, n, w, s}:
      l

def SOut.norm(+o: SOut) -> F32:
  match o:
    case SOut{l, n, w, s}:
      n

def SOut.w(+o: SOut) -> Md.Weights:
  match o:
    case SOut{l, n, w, s}:
      w

def SOut.st(+o: SOut) -> O.State:
  match o:
    case SOut{l, n, w, s}:
      s

def loop(n: Nat, +hp: Hp, +dm: Md.Dims, +c: C.Config, +ws: List<&2, List<&2, U32>>, +nw: Nat,
         +valid: List<&2, List<&2, U32>>, +w: Md.Weights, +st: O.State, +step: Nat) -> IO(Md.Weights):
  match n:
    case 0n:
      IO.pure(Md.Weights, w)
    case 1n+p:
      +step2 = {1n+step : Nat}
      +every = Hp.every(hp)
      do IO<Md.Weights>:
        +t0 : Nat <- IO.now()
        +so : SOut <- IO.pure(SOut, step.pure!(hp, c, dm, batch.at(ws, nw, step, Hp.batch(hp)), w, st))
        +t1 : Nat <- IO.now()
        IO.print("step " ++ Nat.show(step2) ++ " loss " ++ F32.show(SOut.loss(so)) ++ " grad_norm " ++ F32.show(SOut.norm(so))
          ++ " lr " ++ F32.show(Hp.lr_at(hp, step2)) ++ " ms " ++ Nat.show(Nat.sub(t1, t0)))
        report.eval(Bool.or(Nat.is_eq(step2, Hp.total(hp)), Bool.and(Nat.is_lt(0n, every), Nat.is_eq(Nat.mod(step2, Nat.max(every, 1n)), 0n))), dm, SOut.w(so), valid, step2)
        loop(p, hp, dm, c, ws, nw, valid, SOut.w(so), SOut.st(so), step2)

def split.train(+s: D.Split) -> List<&2, List<&2, U32>>:
  match s:
    case D.Split{t, v}:
      t

def split.valid(+s: D.Split) -> List<&2, List<&2, U32>>:
  match s:
    case D.Split{t, v}:
      v

def run(+c: C.Config, +tok: Tok, +text: List<&2, U32>, +hp: Hp, +steps: Nat, +out: String, +evals: Nat) -> IO(Unit):
  +dm = Md.Dims.of(c)
  +sp = D.split(D.encode.all(Tok.b(tok), D.documents(text)))
  +train = D.all.windows(C.Config.ctx(c), split.train(sp))
  +valid = List.take(&2, List<&2, U32>, D.all.windows(C.Config.ctx(c), split.valid(sp)), evals)
  +nw = List.length(&2, List<&2, U32>, train)
  +w0 = I.init(c)
  do IO<Unit>:
    IO.print("train: " ++ C.Config.model_id(c))
    IO.print("tokenizer " ++ Tok.id(tok) ++ "; " ++ Nat.show(nw) ++ " training windows, " ++ Nat.show(List.length(&2, List<&2, U32>, valid)) ++ " validation windows")
    report.eval(True{}, dm, w0, valid, 0n)
    +w : Md.Weights <- loop(steps, hp, dm, c, train, Nat.max(nw, 1n), valid, w0, O.State.init(w0), 0n)
    K.save(out, c, Tok.id(tok), steps, w)
    IO.print("wrote " ++ out)

def tok.read.if(empty: Bool, +path: String) -> IO(List<&2, U32>):
  match empty:
    case True{}:
      IO.pure(List<&2, U32>, Nil{})
    case False{}:
      B.Bytes.read_all(path)

def tok.read(+path: String) -> IO(List<&2, U32>):
  tok.read.if(String.is_empty(path), path)

def start(+corpus: String, +tokf: String, +pre: String, +steps_s: String, +batch_s: String, +lr_s: String, +wd_s: String,
          +warm_s: String, +opt: String, +mu_s: String, +clip_s: String, +every_s: String, +evals_s: String, +out: String,
          +text: List<&2, U32>, +tb: List<&2, U32>) -> IO(Unit):
  +steps = nat.or(steps_s, 100n)
  run(preset(pre), tok.of(tokf, tb), text,
      Hp{f32.or(lr_s, 3.0e-4), f32.or(wd_s, 0.01), Nat.min(nat.or(warm_s, 100n), steps), steps, String.eq(opt, "muon"),
         f32.or(mu_s, 0.95), f32.or(clip_s, 1.0), nat.or(batch_s, 4n), nat.or(every_s, 0n)},
      steps, out, nat.or(evals_s, 16n))

def main() -> IO(Unit):
  do IO<Unit>:
    +corpus : String <- env("CORPUS", "README.md")
    +tokf : String <- env("TOKENIZER_FILE", "")
    +pre : String <- env("PRESET", "small4-v3")
    +steps_s : String <- env("TRAIN_STEPS", "100")
    +batch_s : String <- env("TRAIN_BATCH", "4")
    +lr_s : String <- env("TRAIN_LR", "3e-4")
    +wd_s : String <- env("TRAIN_WD", "0.01")
    +warm_s : String <- env("TRAIN_WARMUP", "100")
    +opt : String <- env("TRAIN_OPT", "adamw")
    +mu_s : String <- env("TRAIN_MUON_BETA", "0.95")
    +clip_s : String <- env("GRAD_CLIP", "1")
    +every_s : String <- env("EVAL_EVERY", "0")
    +evals_s : String <- env("EVAL_WINDOWS", "16")
    +out : String <- env("OUT", "run/bend-train.btc")
    +text : List<&2, U32> <- B.Bytes.read_all(corpus)
    +tb : List<&2, U32> <- tok.read(tokf)
    start(corpus, tokf, pre, steps_s, batch_s, lr_s, wd_s, warm_s, opt, mu_s, clip_s, every_s, evals_s, out, text, tb)
