import Base
import ../Tensor.bend as T
import ../Config.bend as C
import ../Model.bend as Md
import ../Train/Init.bend as I
import ../Train/Ckpt.bend as K
import ../Dense/Io.bend as Io
import ../Dense/Decode.bend as Dd

# Model.bend's decode (the meaning) against the dense decode step
# (Dense/Decode.bend): the same weights, the same tokens, one token at a
# time from empty states; every position's logits must agree up to the F32
# rounding of different summation orders. 96 positions on ctx 64, so the
# softmax ring wraps and overwrites its oldest slots. Two configs: v3's arms
# (RG-LRU, qk-norm, sinks) and none of them (sigmoid gates, plain softmax).
# A reset (states to 0) then the same tokens again must give the same
# logits bit for bit. Every def is prefixed `td.`.

def td.rnd(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

# n+1 byte tokens (2..257), a pseudo-random walk from seed s, then 0
def td.window(n: Nat, +s: U32) -> List<&2, U32>:
  match n:
    case 0n:
      [0]
    case 1n+p:
      U32.add(2, U32.and(U32.shrn(s, 16n), 255)) <> td.window(p, td.rnd(s))

type TdErr is Data:
  TdErr{diff: F32, scale: F32}

def td.err(xs: List<&2, F32>, ys: List<&2, F32>, e: TdErr) -> TdErr:
  match xs ys e:
    case +x <> xt +y <> yt TdErr{d, s}:
      td.err(xt, yt, TdErr{F32.max(d, F32.abs(F32.sub(x, y))), F32.max(s, F32.abs(x))})
    case _ _ _:
      e

def td.errs(xss: List<&2, List<&2, F32>>, yss: List<&2, List<&2, F32>>, e: TdErr) -> TdErr:
  match xss yss:
    case xs <> xt ys <> yt:
      td.errs(xt, yt, td.err(xs, ys, e))
    case _ _:
      e

def td.show(+e: TdErr) -> String:
  match e:
    case TdErr{d, s}:
      "max |diff| " ++ F32.show(d) ++ " of max |logit| " ++ F32.show(s) ++ " (relative " ++ F32.show(F32.div(d, s)) ++ ")"

def td.same.row(xs: List<&2, F32>, ys: List<&2, F32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(U32.is_eq(F32.bits(x), F32.bits(y)), td.same.row(xt, yt))
    case _ _:
      False{}

def td.same(xss: List<&2, List<&2, F32>>, yss: List<&2, List<&2, F32>>) -> Bool:
  match xss yss:
    case Nil{} Nil{}:
      True{}
    case xs <> xt ys <> yt:
      Bool.and(td.same.row(xs, ys), td.same(xt, yt))
    case _ _:
      False{}

# The meaning: Model.bend's decode, its states threaded
def td.out.logits(o: Md.Out) -> T.V:
  match o:
    case Md.Out{l, s}:
      l

def td.out.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

def td.tree(ts: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, sts: List<&2, Md.LState>, +pos: Nat) -> List<&2, List<&2, F32>>:
  match ts:
    case Nil{}:
      Nil{}
    case t <> rest:
      +o = Md.decode(dm, w, sts, pos, t)
      T.V.to_list(td.out.logits(o)) <> td.tree(rest, dm, w, td.out.sts(o), 1n+pos)

# The refinement: the dense step, its store threaded
def td.cons(acc: List<&2, List<&2, F32>>, r: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, List<&2, F32>>:
  (s, xs) = r
  (s, xs <> acc)

def td.next(+k: Dd.Dd, +pos: Nat, +t: U32, r: Array<F32> & List<&2, List<&2, F32>>) -> Array<F32> & List<&2, List<&2, F32>>:
  (s, acc) = r
  td.cons(acc, Dd.dd.logits(k, Dd.dd.feed(k, pos, t, s)))

def td.dense(ts: List<&2, U32>, +k: Dd.Dd, +pos: Nat, r: Array<F32> & List<&2, List<&2, F32>>) -> Array<F32> & List<&2, List<&2, F32>>:
  match ts:
    case Nil{}:
      r
    case t <> rest:
      td.dense(rest, k, 1n+pos, td.next(k, pos, t, r))

def td.rows(r: Array<F32> & List<&2, List<&2, F32>>) -> List<&2, List<&2, F32>>:
  (s, acc) = r
  List.reverse(&2, List<&2, F32>, acc)

# after one run: reset the states, run again, keep both
def td.again(+k: Dd.Dd, +ts: List<&2, U32>, r: Array<F32> & List<&2, List<&2, F32>>) -> List<&2, List<&2, F32>> & List<&2, List<&2, F32>>:
  (s, acc) = r
  (List.reverse(&2, List<&2, F32>, acc), td.rows(td.dense(ts, k, 0n, (Dd.dd.reset(k, s), Nil{}))))

def td.check(+name: String, +c: C.Config, +ts: List<&2, U32>, p: List<&2, List<&2, F32>> & List<&2, List<&2, F32>>) -> IO(Unit):
  (+dense, +again) = p
  +dm = Md.Dims.of(c)
  +tree = td.tree(ts, dm, I.init(c), Md.states.zero(C.Config.layers(c), dm, 0n), 0n)
  +ctx = C.Config.ctx(c)
  do IO<Unit>:
    IO.print(name ++ " logits, positions before the ring wraps: " ++ td.show(td.errs(List.take(&2, List<&2, F32>, tree, ctx), List.take(&2, List<&2, F32>, dense, ctx), TdErr{0.0, 0.0})))
    IO.print(name ++ " logits, positions after it wraps: " ++ td.show(td.errs(List.drop(&2, List<&2, F32>, tree, ctx), List.drop(&2, List<&2, F32>, dense, ctx), TdErr{0.0, 0.0})))
    IO.print(Bool.pick(String, Bool.and(td.same(dense, again), Nat.is_eq(List.length(&2, List<&2, F32>, dense), List.length(&2, U32, ts))), "ok ", "FAIL ") ++ name ++ " reset")

def td.case(+name: String, +c: C.Config, +ts: List<&2, U32>) -> IO(Unit):
  +k = Dd.dd.of(c)
  td.check(name, c, ts, td.again(k, ts, td.dense(ts, k, 0n, (Io.put(K.Weights.flat(I.init(c)), Dd.dd.new(k), 0), Nil{}))))

def main() -> IO(Unit):
  +ts = td.window(95n, 7)
  do IO<Unit>:
    td.case("v3 arms", C.Config.small4_v3(), ts)
    td.case("no arms", {C.Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 4n, 4n, False{}, False{}, False{}, True{}} : C.Config}, ts)
