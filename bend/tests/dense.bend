import Base
import ../Tensor.bend as T
import ../Config.bend as C
import ../Model.bend as Md
import ../Train/Grad.bend as G
import ../Train/Init.bend as I
import ../Train/Opt.bend as O
import ../Train/Ckpt.bend as K
import ../Dense/Layout.bend as L
import ../Dense/Op.bend as P
import ../Dense/Step.bend as S
import ../Dense/Io.bend as Io

# The dense program against the tree trainer (Train/Grad.bend, whose
# pullbacks the gradcheck in tests/train.bend verifies): same weights, same
# windows; the micro-batch's mean loss and every parameter's gradient must
# agree up to the F32 rounding of different summation orders.

def rnd.next(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

# a window of n+1 byte tokens (2..257), a pseudo-random walk from seed
def window(n: Nat, +s: U32) -> List<&2, U32>:
  match n:
    case 0n:
      [0]
    case 1n+p:
      U32.add(2, U32.and(U32.shrn(s, 16n), 255)) <> window(p, rnd.next(s))

def inputs(+w: List<&2, U32>) -> List<&2, U32>:
  List.take(&2, U32, w, Nat.sub(List.length(&2, U32, w), 1n))

def targets(+w: List<&2, U32>) -> List<&2, U32>:
  List.drop(&2, U32, w, 1n)

def tree.add(a: G.LossGrad, b: G.LossGrad) -> G.LossGrad:
  match a b:
    case G.LossGrad{l1, w1} G.LossGrad{l2, w2}:
      G.LossGrad{F32.add(l1, l2), O.W.add(w1, w2)}

def tree.grad(ws: List<&2, List<&2, U32>>, +dm: Md.Dims, +w: Md.Weights) -> G.LossGrad:
  match ws:
    case Nil{}:
      G.LossGrad{0.0, O.W.zero()}
    case +x <> rest:
      tree.add(G.loss_grad(dm, w, inputs(x), targets(x)), tree.grad(rest, dm, w))

def LG.loss(+g: G.LossGrad) -> F32:
  match g:
    case G.LossGrad{l, w}:
      l

def LG.w(+g: G.LossGrad) -> Md.Weights:
  match g:
    case G.LossGrad{l, w}:
      w

type Err is Data:
  Err{diff: F32, scale: F32}

def err.go(xs: List<&2, F32>, ys: List<&2, F32>, e: Err) -> Err:
  match xs ys e:
    case +x <> xt +y <> yt Err{d, s}:
      err.go(xt, yt, Err{F32.max(d, F32.abs(F32.sub(x, y))), F32.max(s, F32.abs(x))})
    case _ _ _:
      e

def Err.show(+e: Err) -> String:
  match e:
    case Err{d, s}:
      "max |diff| " ++ F32.show(d) ++ " of max |g| " ++ F32.show(s) ++ " (relative " ++ F32.show(F32.div(d, s)) ++ ")"

type DOut is Data:
  DOut{loss: F32, grads: List<&2, F32>}

def DOut.loss(+o: DOut) -> F32:
  match o:
    case DOut{l, g}:
      l

def DOut.grads(+o: DOut) -> List<&2, F32>:
  match o:
    case DOut{l, g}:
      g

def dense.fin(+l: F32, r: Array<F32> & List<&2, F32>) -> DOut:
  (s, xs) = r
  DOut{l, xs}

def dense.back(+ly: L.Lay, +m: L.Dm, r: Array<F32> & F32) -> DOut:
  (s, +l) = r
  dense.fin(l, Io.get(U32.to_nat(L.Lay.params(ly)), P.run(List.append(&2, P.Op, S.zero.grads(ly), S.bwd(m, ly, 1.0)), s), L.Lay.g(ly)))

# the forward, the mean loss, the backward, the gradients
def dense(+ly: L.Lay, +m: L.Dm, +w: List<&2, F32>, +ws: List<&2, List<&2, U32>>) -> DOut:
  dense.back(ly, m, Io.get1(P.run(S.fwd(m, ly), Io.put.windows(ws, Io.put(w, Array.new(F32, L.Lay.depth(ly), 0.0), 0),
    L.Lay.tin(ly), L.Lay.ttg(ly), L.Lay.tw(ly), L.Dm.t(m))), L.Lay.lmean(ly)))

def report(+name: String, +c: C.Config, +cc: U32, +flat: List<&2, F32>, +ws: List<&2, List<&2, U32>>, +tgrad: List<&2, F32>) -> IO(Unit):
  +m = L.Dm.of.cc(c, 2n, cc)
  +ly = L.Lay.of(c, m)
  +o = dense(ly, m, flat, ws)
  do IO<Unit>:
    IO.print(name ++ ": dense loss " ++ F32.show(DOut.loss(o)))
    IO.print(name ++ ": gradient " ++ Err.show(err.go(tgrad, DOut.grads(o), Err{0.0, 0.0})))

# small4: sigmoid gates, softmax without qk-norm or sinks
def plain(+ws: List<&2, List<&2, U32>>) -> IO(Unit):
  +c = {C.Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 4n, 4n, False{}, False{}, False{}, True{}} : C.Config}
  +dm = Md.Dims.of(c)
  +w = I.init(c)
  +tg = tree.grad(ws, dm, w)
  do IO<Unit>:
    IO.print("small4 tree loss " ++ F32.show(F32.mul(LG.loss(tg), 0.5)))
    report("small4, chunk 16", c, 16, K.Weights.flat(w), ws, K.Weights.flat(O.W.scale(0.5, LG.w(tg))))

def main() -> IO(Unit):
  +c = C.Config.small4_v3()
  +dm = Md.Dims.of(c)
  +w = I.init(c)
  +ws = {[window(63n, 7), window(63n, 12345)] : List<&2, List<&2, U32>>}
  +tg = tree.grad(ws, dm, w)
  +tl = F32.mul(LG.loss(tg), 0.5)
  +tgrad = K.Weights.flat(O.W.scale(0.5, LG.w(tg)))
  +flat = K.Weights.flat(w)
  do IO<Unit>:
    IO.print("tree loss  " ++ F32.show(tl))
    report("chunk 64 (one per window)", c, 64, flat, ws, tgrad)
    report("chunk 16 (four per window)", c, 16, flat, ws, tgrad)
    plain(ws)
