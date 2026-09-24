import Base
import ./Num.bend as N
import ./Bytes.bend as B
import ./Parse.bend as P
import ./Tensor.bend as T
import ./Config.bend as C
import ./Checkpoint.bend as K
import ./Model.bend as Md
import ./Tokenizer.bend as Tk
import ./Generate.bend as Gen
import ./Train/Grad.bend as G
import ./Train/Data.bend as D
import ./Corpus.bend as Cc

# evaluate: master's `formal-transformer evaluate CKPT CORPUS` (Main.hs
# evaluate) on the Bend2 decoder.
#
#   CKPT          an FTC2 checkpoint
#   CORPUS        a compact corpus artifact (FTCC, written by prepare /
#                 build-eval); its tokenizer identity must be the checkpoint's
#   EVAL_WINDOWS  score the first n full windows only (default: all)
#
# Every document is cut into master's full windows (BOS : tokens ++ [EOS],
# width = context, stride width); each window is scored from zero state,
# as master's batch loss does, by the decode path verified against master.
# The standard error is over per-window means (master's is over chunks of
# MICRO_BATCH windows, so the two agree in the mean, not in the error).

# Scoring ------------------------------------------------------------------

# the summed CE of one window, predicting token i+1 from tokens 0..i
def window.go(xs: List<&2, U32>, ys: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, +sts: List<&2, Md.LState>, +pos: Nat, +acc: F32) -> F32:
  match xs ys:
    case +x <> xt +y <> yt:
      +o = Md.decode(dm, w, sts, pos, x)
      window.go(xt, yt, dm, w, Gen.Out.sts(o), 1n+pos,
        F32.add(acc, F32.sub(G.lse(Gen.Out.logits(o)), T.V.at(Md.Dims.dv(dm), Gen.Out.logits(o), y))))
    case _ _:
      acc

def window.mean(+dm: Md.Dims, +w: Md.Weights, +layers: Nat, +win: List<&2, U32>) -> F32:
  +n = Nat.sub(List.length(&2, U32, win), 1n)
  F32.div(window.go(List.take(&2, U32, win, n), List.drop(&2, U32, win, 1n), dm, w, Md.states.zero(layers, dm, 0n), 0n, 0.0), F32.from_nat(n))

type Acc is Data:
  Acc{n: Nat, sum: F32, sq: F32}

def Acc.put(+m: F32, a: Acc) -> Acc:
  match a:
    case Acc{n, s, q}:
      Acc{1n+n, F32.add(s, m), F32.add(q, F32.mul(m, m))}

def Acc.n(+a: Acc) -> Nat:
  match a:
    case Acc{n, s, q}:
      n

def score(ws: List<&2, List<&2, U32>>, +dm: Md.Dims, +w: Md.Weights, +layers: Nat, +a: Acc) -> IO(Acc):
  match ws:
    case Nil{}:
      IO.pure(Acc, a)
    case +x <> rest:
      +m = window.mean(dm, w, layers, x)
      do IO<Acc>:
        IO.print_err("evaluate: window " ++ Nat.show(Acc.n(a)) ++ " loss " ++ F32.show(m))
        score(rest, dm, w, layers, Acc.put(m, a))

def target.bytes.one(ordinary: Bool, +b: Tk.Bpe, +y: U32) -> Nat:
  match ordinary:
    case True{}:
      List.length(&2, U32, Tk.Bpe.decode(b, y))
    case False{}:
      0n

# the bytes the ordinary targets decode to
def target.bytes(+b: Tk.Bpe, ys: List<&2, U32>) -> Nat:
  match ys:
    case Nil{}:
      0n
    case +y <> t:
      Nat.add(target.bytes.one(U32.is_ge(y, 2), b, y), target.bytes(b, t))

def all.bytes(+b: Tk.Bpe, ws: List<&2, List<&2, U32>>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case +x <> t:
      Nat.add(target.bytes(b, List.drop(&2, U32, x, 1n)), all.bytes(b, t))

def all.predictions(ws: List<&2, List<&2, U32>>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case +x <> t:
      Nat.add(Nat.sub(List.length(&2, U32, x), 1n), all.predictions(t))

def report(+a: Acc, +scale: F32) -> IO(Unit):
  match a:
    case Acc{+n, +s, +q}:
      +k = F32.from_nat(n)
      +mean = F32.div(s, k)
      # sample variance of the window means, and the mean's standard error
      +var = F32.div(F32.sub(q, F32.mul(k, F32.mul(mean, mean))), F32.from_nat(Nat.max(Nat.sub(n, 1n), 1n)))
      +se = F32.sqrt(F32.div(F32.max(var, 0.0), k))
      do IO<Unit>:
        IO.print("loss: " ++ F32.show(mean) ++ " nats/token (standard error " ++ F32.show(se) ++ ")")
        IO.print("bits_per_byte: " ++ F32.show(F32.mul(mean, scale)) ++ " (standard error " ++ F32.show(F32.mul(se, scale)) ++ ")")
        IO.print("perplexity: " ++ F32.show(F32.exp(mean)))

def limit.if(all: Bool, +n: Nat, +ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match all:
    case True{}:
      ws
    case False{}:
      List.take(&2, List<&2, U32>, ws, n)

def go(+m: K.Manifest, +b: Tk.Bpe, rw: B.Cur & Gen.Run, +cp: String, +cpath: String, +co: Cc.Corpus, +limit: String) -> IO(Unit):
  (cur, +run) = rw
  +c = K.Manifest.cfg(m)
  +dm = Md.Dims.of(c)
  +w = Gen.Run.w(run)
  +ds = Cc.Corpus.docs(co)
  +all = D.all.windows(C.Config.ctx(c), ds)
  +ws = limit.if(String.is_empty(limit), Gen.nat.or(U32.read(limit), 0n), all)
  +preds = all.predictions(ws)
  +scale = F32.div(F32.from_nat(preds), F32.mul(F32.from_nat(all.bytes(b, ws)), F32.log(2.0)))
  do IO<Unit>:
    B.Bytes.close(cur)
    IO.print_err("evaluate: " ++ Nat.show(List.length(&2, List<&2, U32>, ws)) ++ " of " ++ Nat.show(List.length(&2, List<&2, U32>, all)) ++ " windows")
    +a : Acc <- score(ws, dm, w, C.Config.layers(c), Acc{0n, 0.0, 0.0})
    IO.print("=== evaluation: " ++ cp ++ " on " ++ cpath ++ " ===")
    IO.print("checkpoint step: " ++ Nat.show(Gen.Run.step(run)) ++ "/" ++ Nat.show(K.Manifest.total_steps(m))
      ++ " (" ++ Gen.pct(Gen.Run.step(run), K.Manifest.total_steps(m)) ++ "% of the scheduled run)")
    IO.print("config: " ++ C.Config.show(c))
    IO.print("dataset fingerprint: " ++ Cc.Corpus.dataset(co))
    IO.print("documents: " ++ Nat.show(List.length(&2, List<&2, U32>, ds)) ++ "  windows: " ++ Nat.show(Acc.n(a)) ++ "  predictions: " ++ Nat.show(preds))
    report(a, scale)

def after(r: B.Cur & K.Manifest, +cp: String, +cpath: String, +co: Cc.Corpus, +limit: String) -> IO(Unit):
  (cur, +m) = r
  do IO<Unit>:
    Gen.problem(K.Manifest.problem(m))
    Gen.problem(Cc.Corpus.problem(co, K.Manifest.tokenizer_id(m)))
    b : Tk.Bpe <- Gen.tok.of("", K.Manifest.tokenizer_id(m))
    rw : B.Cur & Gen.Run <- Gen.Load.run(K.Manifest.cfg(m))(cur)
    go(m, b, rw, cp, cpath, co, limit)

def main() -> IO(Unit):
  do IO<Unit>:
    +cp : String <- Gen.env("CKPT", "run/last-checkpoint")
    +cpath : String <- Gen.env("CORPUS", "run/eval/enwik8-test-fw32k.corpus")
    +limit : String <- Gen.env("EVAL_WINDOWS", "")
    +xs : List<&2, U32> <- B.Bytes.read_all(cpath)
    c : B.Cur <- B.Bytes.open(cp)
    r : B.Cur & K.Manifest <- K.Load.header()(c)
    after(r, cp, cpath, Cc.corpus(xs), limit)
