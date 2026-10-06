import Base
import ../Tensor.bend as T
import ../Config.bend as C
import ../Model.bend as Md
import ../Train/Init.bend as I
import ../Train/Ckpt.bend as K
import ../Dense/Io.bend as Io
import ../Dense/Decode.bend as Dd
import ../Dense/Op.bend as P
import ../Sample.bend as S

# Model.bend's decode (the meaning) against the dense decode step
# (Dense/Decode.bend): the same weights, the same tokens, one token at a
# time from empty states; every position's logits must agree up to the F32
# rounding of different summation orders. 96 positions on ctx 64, so the
# softmax ring wraps and overwrites its oldest slots. Two configs: v3's arms
# (RG-LRU, qk-norm, sinks) and none of them (sigmoid gates, plain softmax).
# A reset (states to 0) then the same tokens again must give the same
# logits bit for bit. Greedy's pick on the store (Dd.dd.top) must be
# Sample.bend's argmax of the same store's logits at every position, ties
# to the least index. Every def is prefixed `td.`.

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

# Greedy's pick on the store (Dd.dd.top) is Sample.bend's argmax of the
# logits the same store answers, at every position: the law is exact (one
# set of logits, two ways to pick), so a near tie cannot excuse a miss
def td.top.and(+ok: Bool, r: Array<F32> & Bool) -> Array<F32> & Bool:
  (s, b) = r
  (s, Bool.and(ok, b))

def td.top.cmp(+want: U32, r: Array<F32> & U32) -> Array<F32> & Bool:
  (s, got) = r
  (s, U32.is_eq(want, got))

def td.top.one(+k: Dd.Dd, +dv: Nat, r: Array<F32> & List<&2, F32>) -> Array<F32> & Bool:
  (s, xs) = r
  td.top.cmp(S.argmax(dv, T.V.of_list(dv, xs)), Dd.dd.top(k, s))

def td.top.step(+k: Dd.Dd, +dv: Nat, +pos: Nat, +t: U32, r: Array<F32> & Bool) -> Array<F32> & Bool:
  (s, ok) = r
  td.top.and(ok, td.top.one(k, dv, Dd.dd.logits(k, Dd.dd.feed(k, pos, t, s))))

def td.tops(ts: List<&2, U32>, +k: Dd.Dd, +dv: Nat, +pos: Nat, r: Array<F32> & Bool) -> Array<F32> & Bool:
  match ts:
    case Nil{}:
      r
    case t <> rest:
      td.tops(rest, k, dv, 1n+pos, td.top.step(k, dv, pos, t, r))

def td.top.line(+name: String, r: Array<F32> & Bool) -> IO(Unit):
  (s, ok) = r
  IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ name ++ " greedy pick on the store")

# ties go to the least index, as Sample.bend's argmax: dd.pick over 4 cells
def td.tie.got(r: Array<F32> & F32) -> U32:
  (s, y) = r
  U32.sub(4, F32.to_u32(y))

def td.tie(+xs: List<&2, F32>) -> Bool:
  U32.is_eq(td.tie.got(Array.get(F32, P.run(Dd.dd.pick(4, 0, 4), Io.put(xs, Array.new(F32, 3n, 0.0), 0)), 5)), S.argmax(2n, T.V.of_list(2n, xs)))

def td.ties() -> Bool:
  Bool.and(Bool.and(td.tie([1.0, 3.0, 3.0, 2.0]), td.tie([0.0, 0.0, 0.0, 0.0])),
    Bool.and(Bool.and(td.tie([F32.neg(1.0), F32.neg(5.0), F32.neg(1.0), F32.neg(2.0)]), td.tie([2.0, 1.0, 0.0, 7.0])), td.tie([F32.neg(0.0), 0.0, F32.neg(3.0), 0.0])))

def td.case(+name: String, +c: C.Config, +ts: List<&2, U32>) -> IO(Unit):
  +k = Dd.dd.of(c)
  +w = K.Weights.flat(I.init(c))
  do IO<Unit>:
    td.check(name, c, ts, td.again(k, ts, td.dense(ts, k, 0n, (Io.put(w, Dd.dd.new(k), 0), Nil{}))))
    td.top.line(name, td.tops(ts, k, Md.Dims.dv(Md.Dims.of(c)), 0n, (Io.put(w, Dd.dd.new(k), 0), True{})))

def main() -> IO(Unit):
  +ts = td.window(95n, 7)
  do IO<Unit>:
    td.case("v3 arms", C.Config.small4_v3(), ts)
    td.case("no arms", {C.Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 4n, 4n, False{}, False{}, False{}, True{}} : C.Config}, ts)
    IO.print(Bool.pick(String, td.ties(), "ok ", "FAIL ") ++ "greedy pick ties go to the least index")
