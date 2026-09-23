import Base
import ../Tensor.bend as T
import ../Config.bend as C
import ../Model.bend as Md
import ../Train/Grad.bend as G
import ../Train/Init.bend as I

# Gradient check: central finite differences of the training loss against the
# hand-written pullback, at sampled entries of every kind of tensor, on the
# small4-v3 config (3 GLA blocks with RG-LRU gates, 1 softmax block with
# qk-norm and sinks).  Also checks the training forward's loss against the
# decode path (Model.decode, the one verified against master).
type Probe is Data:
  PEmb{r: U32, c: U32}
  PFin{c: U32}
  PBlk{j: Nat, field: Nat, r: U32, c: U32}

def Blocks.get(+j: Nat, +bs: List<&2, Md.Block>) -> Md.Block:
  match j bs:
    case 0n b <> t:
      b
    case 1n+p b <> t:
      Blocks.get(p, t)
    case _ Nil{}:
      Md.GlaB{T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.MZ{}, T.VZ{}, T.VZ{}, T.MZ{}, T.MZ{}, T.MZ{}}

def Blocks.put(+j: Nat, bs: List<&2, Md.Block>, +nb: Md.Block) -> List<&2, Md.Block>:
  match j bs:
    case 0n b <> t:
      nb <> t
    case 1n+p b <> t:
      b <> Blocks.put(p, t, nb)
    case _ Nil{}:
      Nil{}

# the entry of a matrix / vector, and the same entry moved by eps
def mat.at(+dr: Nat, +dc: Nat, +m: T.M, +r: U32, +c: U32) -> F32:
  T.V.at(dc, T.M.row(dr, m, r), c)

def mat.bump(+dr: Nat, +dc: Nat, +m: T.M, +r: U32, +c: U32, +eps: F32) -> T.M:
  Md.M.set(dr, m, r, T.V.set(dc, T.M.row(dr, m, r), c, F32.add(mat.at(dr, dc, m, r, c), eps)))

def vec.bump(+dc: Nat, +v: T.V, +c: U32, +eps: F32) -> T.V:
  T.V.set(dc, v, c, F32.add(T.V.at(dc, v, c), eps))

def blk.pick(+f: Nat, +a0: F32, +a1: F32, +a5: F32, +a6: F32, +a7: F32, +a10: F32) -> F32:
  match f:
    case 0n:
      a0
    case 1n:
      a1
    case 5n:
      a5
    case 6n:
      a6
    case 7n:
      a7
    case _:
      a10

# field 1: wq, 5: walpha (GLA) / qk_gain_q (softmax), 6: gate_lambda /
# qk_gain_k, 7: rms_ff / sink, 0: rms_att, 10: wdown (GLA) / wup (softmax)
def blk.at(+dm: Md.Dims, +b: Md.Block, +f: Nat, +r: U32, +c: U32) -> F32:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      blk.pick(f, T.V.at(Md.Dims.dd(dm), ra, c), mat.at(Md.Dims.dd(dm), Md.Dims.dd(dm), wq, r, c), mat.at(Md.Dims.dd(dm), Md.Dims.dd(dm), wa, r, c), T.V.at(Md.Dims.dd(dm), lam, c), T.V.at(Md.Dims.dd(dm), rf, c), mat.at(Md.Dims.dd(dm), Md.Dims.df(dm), wd, r, c))
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sk, rf, wg, wu, wd}:
      blk.pick(f, T.V.at(Md.Dims.dd(dm), ra, c), mat.at(Md.Dims.dd(dm), Md.Dims.dd(dm), wq, r, c), T.V.at(Md.Dims.dhd(dm), gq, c), T.V.at(Md.Dims.dhd(dm), gk, c), T.V.at(Md.Dims.dh(dm), sk, c), mat.at(Md.Dims.df(dm), Md.Dims.dd(dm), wu, r, c))

def blk.v(on: Bool, +d: Nat, +v: T.V, +c: U32, +e: F32) -> T.V:
  match on:
    case True{}:
      vec.bump(d, v, c, e)
    case False{}:
      v

def blk.m(on: Bool, +dr: Nat, +dc: Nat, +m: T.M, +r: U32, +c: U32, +e: F32) -> T.M:
  match on:
    case True{}:
      mat.bump(dr, dc, m, r, c, e)
    case False{}:
      m

def blk.bump(+dm: Md.Dims, +b: Md.Block, +f: Nat, +r: U32, +c: U32, +e: F32) -> Md.Block:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      Md.GlaB{blk.v(Nat.is_eq(f, 0n), Md.Dims.dd(dm), ra, c, e), blk.m(Nat.is_eq(f, 1n), Md.Dims.dd(dm), Md.Dims.dd(dm), wq, r, c, e), wk, wv, wo,
              blk.m(Nat.is_eq(f, 5n), Md.Dims.dd(dm), Md.Dims.dd(dm), wa, r, c, e), blk.v(Nat.is_eq(f, 6n), Md.Dims.dd(dm), lam, c, e), blk.v(Nat.is_eq(f, 7n), Md.Dims.dd(dm), rf, c, e),
              wg, wu, blk.m(Nat.is_eq(f, 10n), Md.Dims.dd(dm), Md.Dims.df(dm), wd, r, c, e)}
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sk, rf, wg, wu, wd}:
      Md.SmB{blk.v(Nat.is_eq(f, 0n), Md.Dims.dd(dm), ra, c, e), blk.m(Nat.is_eq(f, 1n), Md.Dims.dd(dm), Md.Dims.dd(dm), wq, r, c, e), wk, wv, wo,
             blk.v(Nat.is_eq(f, 5n), Md.Dims.dhd(dm), gq, c, e), blk.v(Nat.is_eq(f, 6n), Md.Dims.dhd(dm), gk, c, e),
             blk.v(Nat.is_eq(f, 7n), Md.Dims.dh(dm), sk, c, e), rf, wg,
             blk.m(Nat.is_eq(f, 10n), Md.Dims.df(dm), Md.Dims.dd(dm), wu, r, c, e), wd}

def at(+dm: Md.Dims, +w: Md.Weights, +p: Probe) -> F32:
  match w p:
    case Md.Weights{e, bs, f, u} PEmb{r, c}:
      mat.at(Md.Dims.dv(dm), Md.Dims.dd(dm), e, r, c)
    case Md.Weights{e, bs, f, u} PFin{c}:
      T.V.at(Md.Dims.dd(dm), f, c)
    case Md.Weights{e, +bs, f, u} PBlk{j, fl, r, c}:
      blk.at(dm, Blocks.get(j, bs), fl, r, c)

def bump(+dm: Md.Dims, +w: Md.Weights, +p: Probe, +eps: F32) -> Md.Weights:
  match w p:
    case Md.Weights{e, bs, f, u} PEmb{r, c}:
      Md.Weights{mat.bump(Md.Dims.dv(dm), Md.Dims.dd(dm), e, r, c, eps), bs, f, u}
    case Md.Weights{e, bs, f, u} PFin{c}:
      Md.Weights{e, bs, vec.bump(Md.Dims.dd(dm), f, c, eps), u}
    case Md.Weights{e, +bs, f, u} PBlk{+j, fl, r, c}:
      Md.Weights{e, Blocks.put(j, bs, blk.bump(dm, Blocks.get(j, bs), fl, r, c, eps)), f, u}

def LG.grad(+g: G.LossGrad) -> Md.Weights:
  match g:
    case G.LossGrad{l, w}:
      w

def LG.loss(+g: G.LossGrad) -> F32:
  match g:
    case G.LossGrad{l, w}:
      l

def show.probe(+p: Probe) -> String:
  match p:
    case PEmb{r, c}:
      "emb[" ++ U32.show(r) ++ "][" ++ U32.show(c) ++ "]"
    case PFin{c}:
      "final_rms[" ++ U32.show(c) ++ "]"
    case PBlk{j, f, r, c}:
      "block" ++ Nat.show(j) ++ ".field" ++ Nat.show(f) ++ "[" ++ U32.show(r) ++ "][" ++ U32.show(c) ++ "]"

def check.one(+dm: Md.Dims, +w: Md.Weights, +g: Md.Weights, +xs: List<&2, U32>, +ys: List<&2, U32>, +p: Probe) -> String:
  +eps = {0.01 : F32}
  +lp = G.loss(dm, bump(dm, w, p, eps), xs, ys)
  +lm = G.loss(dm, bump(dm, w, p, F32.neg(eps)), xs, ys)
  +num = F32.div(F32.sub(lp, lm), F32.mul(2.0, eps))
  +ana = at(dm, g, p)
  show.probe(p) ++ " analytic=" ++ F32.show(ana) ++ " numeric=" ++ F32.show(num)

def checks(ps: List<&2, Probe>, +dm: Md.Dims, +w: Md.Weights, +g: Md.Weights, +xs: List<&2, U32>, +ys: List<&2, U32>) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> rest:
      do IO<Unit>:
        IO.print(check.one(dm, w, g, xs, ys, p))
        checks(rest, dm, w, g, xs, ys)

# the decode path's mean loss over the same window
def Out.logits(o: Md.Out) -> T.V:
  match o:
    case Md.Out{l, s}:
      l

def Out.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

def dec.loss(xs: List<&2, U32>, ys: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, +sts: List<&2, Md.LState>, +pos: Nat, +acc: F32) -> F32:
  match xs ys:
    case +x <> xt +y <> yt:
      +o = Md.decode(dm, w, sts, pos, x)
      dec.loss(xt, yt, dm, w, Out.sts(o), 1n+pos,
        F32.add(acc, F32.sub(G.lse(Out.logits(o)), T.V.at(Md.Dims.dv(dm), Out.logits(o), y))))
    case _ _:
      acc

def main() -> IO(Unit):
  +c = C.Config.small4_v3()
  +dm = Md.Dims.of(c)
  +w = I.init(c)
  +xs = {[72, 101, 108, 108, 111, 32, 119, 111] : List<&2, U32>}
  +ys = {[101, 108, 108, 111, 32, 119, 111, 114] : List<&2, U32>}
  +lg = G.loss_grad(dm, w, xs, ys)
  +g = LG.grad(lg)
  do IO<Unit>:
    IO.print("train loss " ++ F32.show(LG.loss(lg)))
    IO.print("decode loss " ++ F32.show(F32.div(dec.loss(xs, ys, dm, w, Md.states.zero(C.Config.layers(c), dm, 0n), 0n, 0.0), 8.0)))
    checks([PEmb{72, 3}, PEmb{108, 10}, PEmb{114, 5}, PFin{7},
            PBlk{0n, 0n, 0, 5}, PBlk{0n, 1n, 3, 9}, PBlk{1n, 5n, 7, 2}, PBlk{2n, 6n, 0, 11}, PBlk{1n, 7n, 0, 4}, PBlk{2n, 10n, 5, 17},
            PBlk{3n, 0n, 0, 6}, PBlk{3n, 1n, 2, 8}, PBlk{3n, 5n, 0, 3}, PBlk{3n, 6n, 0, 9}, PBlk{3n, 7n, 0, 1}, PBlk{3n, 10n, 40, 5}],
      dm, w, g, xs, ys)
