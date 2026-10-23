import Base
import ../Tensor.bend as T
import ../Config.bend as C
import ../Model.bend as Md
import ../Train/Init.bend as I
import ../Train/Ckpt.bend as K
import ../Dense/Io.bend as Io
import ../Dense/Decode.bend as Dd

# Chunked prefill (Dense/Decode.bend dd.feeds: chunks of up to C tokens
# through the chunk program) against the one-token step it refines
# (dd.feed, a token at a time), its meaning here: the same weights and
# tokens must leave the layers' states and the next token's logits (the
# head on the last token's row) the same bit for bit, and greedy's pick on
# the store (dd.top, ana's after a prefill) the same token. Chunks of 16 on ctx
# 64, up to 96 tokens, so the softmax ring wraps; a chunk attends all its
# rows at once while it stays below position 64 and token by token after.
# The runs: 96 tokens from position 0 (six chunks, the fourth ending at the
# wrap), 95 (five and one of 15 past it), 40 (two and one of 8, before it),
# 50 (three, then two steps: a remainder under dd.chunk.min), and after 5
# steps: 96 (five chunks, one straddling the wrap, and one of 11) and 67
# (three and one of 14 straddling it). Two configs: v3's arms
# (RG-LRU, qk-norm, sinks) and none. The six-chunk run's logits are also
# held to Model.bend's decode (as tests/decode-dense.bend holds the step:
# within 1e-5 relative). Every def is prefixed `tp.`.

def tp.rnd(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

# n+1 byte tokens (2..257), a pseudo-random walk from seed s, then 0
def tp.window(n: Nat, +s: U32) -> List<&2, U32>:
  match n:
    case 0n:
      [0]
    case 1n+p:
      U32.add(2, U32.and(U32.shrn(s, 16n), 255)) <> tp.window(p, tp.rnd(s))

type TpErr is Data:
  TpErr{diff: F32, scale: F32}

def tp.err(xs: List<&2, F32>, ys: List<&2, F32>, e: TpErr) -> TpErr:
  match xs ys e:
    case +x <> xt +y <> yt TpErr{d, s}:
      tp.err(xt, yt, TpErr{F32.max(d, F32.abs(F32.sub(x, y))), F32.max(s, F32.abs(x))})
    case _ _ _:
      e

def tp.show(+e: TpErr) -> String:
  match e:
    case TpErr{d, s}:
      "max |diff| " ++ F32.show(d) ++ " of max |x| " ++ F32.show(s) ++ " (relative " ++ F32.show(F32.div(d, s)) ++ ")"

# the same bits, the same length
def tp.same(xs: List<&2, F32>, ys: List<&2, F32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(U32.is_eq(F32.bits(x), F32.bits(y)), tp.same(xt, yt))
    case _ _:
      False{}

# What a run leaves: the layers' states [st0, stn), the logits, and
# greedy's pick on the store (dd.top: what ana picks after a prefill)
type TpOut is Data:
  TpOut{st: List<&2, F32>, lg: List<&2, F32>, top: U32}

def tp.lg(+o: TpOut) -> List<&2, F32>:
  match o:
    case TpOut{st, lg, top}:
      lg

def tp.out.top(sts: List<&2, F32>, lg: List<&2, F32>, r: Array<F32> & U32) -> TpOut:
  (s, t) = r
  TpOut{sts, lg, t}

def tp.out.fin(+k: Dd.Dd, sts: List<&2, F32>, r: Array<F32> & List<&2, F32>) -> IO(TpOut):
  (s, lg) = r
  IO.bind(Array<F32> & U32, TpOut, Dd.dd.top(k, s), (x: Array<F32> & U32) => IO.pure(TpOut, tp.out.top(sts, lg, x)))

def tp.out.got(+k: Dd.Dd, r: Array<F32> & List<&2, F32>) -> IO(TpOut):
  (s, sts) = r
  IO.bind(Array<F32> & List<&2, F32>, TpOut, Dd.dd.logits(k, s), (x: Array<F32> & List<&2, F32>) => tp.out.fin(k, sts, x))

def tp.out(+k: Dd.Dd, s: Array<F32>) -> IO(TpOut):
  tp.out.got(k, Io.get(U32.to_nat(U32.sub(Dd.dd.stn(k), Dd.dd.st0(k))), s, Dd.dd.st0(k)))

# a fresh store holding the weights
def tp.fresh(+k: Dd.Dd, +ws: List<&2, F32>) -> Array<F32>:
  Io.put(ws, Dd.dd.new(k), 0)

# tokens one at a time from pos (the step)
def tp.each(ts: List<&2, U32>, +k: Dd.Dd, +pos: Nat, s: Array<F32>) -> IO(Array<F32>):
  match ts:
    case Nil{}:
      IO.pure(Array<F32>, s)
    case t <> rest:
      IO.bind(Array<F32>, Array<F32>, Dd.dd.feed(k, pos, t, s), (x: Array<F32>) => tp.each(rest, k, 1n+pos, x))

# the meaning: every token through the step
def tp.ref(+k: Dd.Dd, +ws: List<&2, F32>, +ts: List<&2, U32>) -> IO(TpOut):
  IO.bind(Array<F32>, TpOut, tp.each(ts, k, 0n, tp.fresh(k, ws)), (x: Array<F32>) => tp.out(k, x))

# the refinement: the first pre tokens through the step, the rest by dd.feeds
def tp.chunked(+k: Dd.Dd, +ws: List<&2, F32>, +pre: Nat, +ts: List<&2, U32>) -> IO(TpOut):
  do IO<TpOut>:
    s1 : Array<F32> <- tp.each(List.take(&2, U32, ts, pre), k, 0n, tp.fresh(k, ws))
    s2 : Array<F32> <- Dd.dd.feeds(k, List.drop(&2, U32, ts, pre), pre, s1)
    tp.out(k, s2)

# The tally the verdict reads: exact laws checked and failed, logit
# comparisons against Model.bend made and failed (each within 1e-5
# relative, the F32 its line shows; a NaN fails)
type TpT is Data:
  TpT{ex: Nat, exbad: Nat, lg: Nat, lgbad: Nat}

def tp.add(a: TpT, b: TpT) -> TpT:
  match a b:
    case TpT{e1, eb1, l1, lb1} TpT{e2, eb2, l2, lb2}:
      TpT{Nat.add(e1, e2), Nat.add(eb1, eb2), Nat.add(l1, l2), Nat.add(lb1, lb2)}

def tp.bad(b: Bool) -> Nat:
  Bool.pick(Nat, b, 0n, 1n)

def tp.ok(+e: TpErr) -> Bool:
  match e:
    case TpErr{d, s}:
      F32.is_le(F32.div(d, s), 1.0e-5)

def tp.check(+name: String, a: TpOut, b: TpOut) -> IO(TpT):
  match a b:
    case TpOut{+sa, +la, +ta} TpOut{+sb, +lb, +tb}:
      +ok = Bool.and(Bool.and(tp.same(sa, sb), tp.same(la, lb)), U32.is_eq(ta, tb))
      do IO<TpT>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ name
          ++ ": states " ++ tp.show(tp.err(sa, sb, TpErr{0.0, 0.0})) ++ "; logits " ++ tp.show(tp.err(la, lb, TpErr{0.0, 0.0}))
          ++ "; pick " ++ U32.show(ta) ++ " and " ++ U32.show(tb))
        return TpT{1n, tp.bad(ok), 0n, 0n}

# Model.bend's decode: the logits after every token
def tp.o.logits(o: Md.Out) -> T.V:
  match o:
    case Md.Out{l, s}:
      l

def tp.o.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

def tp.tree(ts: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, o: Md.Out, +pos: Nat) -> Md.Out:
  match ts:
    case Nil{}:
      o
    case t <> rest:
      tp.tree(rest, dm, w, Md.decode(dm, w, tp.o.sts(o), pos, t), 1n+pos)

# the first n tokens: pre steps, then chunks, against n steps
def tp.run(+name: String, +k: Dd.Dd, +ws: List<&2, F32>, +pre: Nat, +n: Nat, +ts: List<&2, U32>) -> IO(TpT):
  +xs = List.take(&2, U32, ts, n)
  do IO<TpT>:
    a : TpOut <- tp.ref(k, ws, xs)
    b : TpOut <- tp.chunked(k, ws, pre, xs)
    tp.check(name, a, b)

def tp.case(+name: String, +c: C.Config, +ts: List<&2, U32>) -> IO(TpT):
  +k = Dd.dd.of.n(c, 16)
  +ws = K.Weights.flat(I.init(c))
  +dm = Md.Dims.of(c)
  +tree = T.V.to_list(tp.o.logits(tp.tree(ts, dm, I.init(c), {Md.Out{T.VZ{}, Md.states.zero(C.Config.layers(c), dm, 0n)} : Md.Out}, 0n)))
  do IO<TpT>:
    +whole : TpOut <- tp.chunked(k, ws, 0n, ts)
    +e : TpErr = tp.err(tree, tp.lg(whole), TpErr{0.0, 0.0})
    ref : TpOut <- tp.ref(k, ws, ts)
    r1 : TpT <- tp.check(name ++ " 96 from 0: 6 chunks", ref, whole)
    r2 : TpT <- tp.run(name ++ " 95 from 0: 5 chunks and one of 15", k, ws, 0n, 95n, ts)
    r3 : TpT <- tp.run(name ++ " 40 from 0: 2 chunks and one of 8", k, ws, 0n, 40n, ts)
    r4 : TpT <- tp.run(name ++ " 50 from 0: 3 chunks and 2 steps", k, ws, 0n, 50n, ts)
    r5 : TpT <- tp.run(name ++ " 96 from 5: 5 steps, 5 chunks (one across the wrap) and one of 11", k, ws, 5n, 96n, ts)
    r6 : TpT <- tp.run(name ++ " 67 from 5: 5 steps, 3 chunks and one of 14 across the wrap", k, ws, 5n, 67n, ts)
    IO.print(Bool.pick(String, tp.ok(e), "", "FAIL ") ++ name ++ " chunked logits against Model.bend decode: " ++ tp.show(e))
    return tp.add(tp.add(tp.add(r1, r2), tp.add(r3, r4)), tp.add(tp.add(r5, r6), TpT{0n, 0n, 1n, tp.bad(tp.ok(e))}))

def tp.verdict.if(ok: Bool, msg: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("ok 12 runs bit for bit, 2 logit comparisons within 1e-5 relative")
    case False{}:
      IO.die(Unit, 1, msg)

# The verdict (the flake's bend-prefill-dense check is this exit status):
# the 12 runs (6 a config) bit for bit, and both configs' chunked logits
# within 1e-5 relative of Model.bend's decode
def tp.verdict(t: TpT) -> IO(Unit):
  match t:
    case TpT{+ex, +exbad, +lg, +lgbad}:
      tp.verdict.if(Bool.and(Bool.and(Nat.is_eq(ex, 12n), Nat.is_eq(exbad, 0n)), Bool.and(Nat.is_eq(lg, 2n), Nat.is_eq(lgbad, 0n))),
        "prefill-dense: " ++ Nat.show(exbad) ++ " of " ++ Nat.show(ex) ++ " runs differ (12 expected), "
          ++ Nat.show(lgbad) ++ " of " ++ Nat.show(lg) ++ " logit comparisons past 1e-5 relative (2 expected)")

def main() -> IO(Unit):
  +ts = tp.window(95n, 7)
  do IO<Unit>:
    a : TpT <- tp.case("v3 arms", C.Config.small4_v3(), ts)
    b : TpT <- tp.case("no arms", {C.Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 4n, 4n, False{}, False{}, False{}, True{}} : C.Config}, ts)
    tp.verdict(tp.add(a, b))
