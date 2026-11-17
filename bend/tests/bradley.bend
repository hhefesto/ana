import Base
import ../Bytes.bend as By
import ../Config.bend as C
import ../Checkpoint.bend as K
import ../Train/Ckpt.bend as TK
import ../Corpus.bend as Cc
import ../Train/Init.bend as I
import ../Train/Data.bend as D
import ../Dense/Layout.bend as L
import ../Dense/Step.bend as S
import ../Dense/Io.bend as Io
import ../Dense/Run.bend as R
import ../Dense/Ckpt.bend as Dk
import ../Dense/Decode.bend as Dd
import ../Dense/Op.bend as P

# Bradley's homs on the real decoder, in log space (the user, 2026-11-17:
# "item 3 first, with item 1 as its checkpoint test done in log space").
#
# Spec/Distance.bend proves, for any model and any log, that a window's
# training loss is the cost (the -ln hom) of the morphism from its first
# token to the window, that costs add along a chain of prefixes, that an
# identity costs zero and that a 0/1-masked loss is a sum of such costs,
# one per run of weight-1 targets.  At F32 the log is -ln only by trust and
# the trainer and the decoder are two different programs, so here the same
# statements are measured on the code, never as raw probabilities (a
# window's probability is below F32's range after about a hundred tokens):
#
#   rows      the trainer's forward (Dense/Step.bend S.eval: chunked GLA,
#             the tied head, lse - logit[target] per row) charges every
#             prediction what the dense decoder (Dense/Decode.bend, ana's
#             engine, one token at a time from zero state) charges it:
#             -ln softmax(logits)[target] = max + ln sum exp(l - max) - l[t]
#   window    window_is_distance: the trainer's summed window loss (every
#             weight 1, Hd.wl) is the decoder's cost from the window's
#             first token to the window
#   prompt    prompt_is_distance: weights 0 on the first half of the
#             targets, 1 after: the trainer's loss is the decoder's cost
#             from the prompt to the window, the decoder reaching the
#             prompt by its chunked prefill (dd.feeds), not by steps
#   runs      masked_runs: weights in runs of 1s and 0s: the trainer's loss
#             is the sum of the decoder's costs over the runs of 1s
#   chain     cost_composition: cut the window at a third and at two
#             thirds; reach each cut by the chunked prefill and step from
#             there: the costs from the cut equal the one-pass costs'
#             tail, and head plus tail is the whole
#   identity  cost_identity: the empty extension costs exactly 0, and the
#             trainer's loss with every weight 0 is exactly 0.0 (so no row
#             is NaN or infinite: 0 times either is NaN)
#
# The tolerance: each row within 1e-3 absolute plus 1e-4 relative, each
# sum within 1e-4 relative of the sum of |costs| (F32 sums of 10^2 to 10^3
# rows in different orders).  The F32 numbers are printed.
#
#   bradley                      random weights, two small configs (the
#                                flake's bend-bradley check)
#   bradley CKPT CORPUS [N] [W]  an FTC2 checkpoint, N windows (default 2)
#                                of W tokens (default 512) from a compact
#                                corpus of the checkpoint's tokenizer
#
# On a checkpoint the config's ctx is cut to W: ctx sizes the trainer's
# buffers and the decoder's softmax ring and nothing else (no position
# enters the arithmetic: the mask is causal by index, and the ring does
# not wrap within W), so the model is the checkpoint's.  Every def is
# prefixed `br.`.

# Costs ---------------------------------------------------------------------

def br.max(xs: List<&2, F32>, +m: F32) -> F32:
  match xs:
    case Nil{}:
      m
    case x <> t:
      br.max(t, F32.max(m, x))

def br.sumexp(xs: List<&2, F32>, +m: F32, +acc: F32) -> F32:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      br.sumexp(t, m, F32.add(acc, F32.exp(F32.sub(x, m))))

def br.nth(xs: List<&2, F32>, n: Nat) -> F32:
  match xs n:
    case x <> t 0n:
      x
    case x <> t 1n+p:
      br.nth(t, p)
    case _ _:
      0.0

# -ln softmax(xs)[t], the trainer head's formula: (max + ln sum) - x[t]
def br.cost(+t: U32, +xs: List<&2, F32>) -> F32:
  +m = br.max(xs, F32.neg(F32.div(1.0, 0.0)))
  F32.sub(F32.add(m, F32.log(br.sumexp(xs, m, 0.0))), br.nth(xs, U32.to_nat(t)))

def br.sum(xs: List<&2, F32>, +acc: F32) -> F32:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      br.sum(t, F32.add(acc, x))

def br.abssum(xs: List<&2, F32>, +acc: F32) -> F32:
  match xs:
    case Nil{}:
      acc
    case x <> t:
      br.abssum(t, F32.add(acc, F32.abs(x)))

# the costs at kept targets (weight 1.0) only
def br.kept(xs: List<&2, F32>, ws: List<&2, F32>, +acc: F32) -> F32:
  match xs ws:
    case x <> t w <> wt:
      br.kept(t, wt, F32.add(acc, F32.mul(x, w)))
    case _ _:
      acc

# The decoder ------------------------------------------------------------------

def br.after(+k: Dd.Dd, +pos: Nat, +t: U32, acc: List<&2, F32>, r: Array<F32> & List<&2, F32>) -> IO(Array<F32> & List<&2, F32>):
  (s, +lg) = r
  IO.bind(Array<F32>, Array<F32> & List<&2, F32>, Dd.dd.feed(k, pos, t, s),
    (x: Array<F32>) => IO.pure(Array<F32> & List<&2, F32>, (x, br.cost(t, lg) <> acc)))

def br.step(+k: Dd.Dd, +pos: Nat, +t: U32, r: Array<F32> & List<&2, F32>) -> IO(Array<F32> & List<&2, F32>):
  (s, acc) = r
  IO.bind(Array<F32> & List<&2, F32>, Array<F32> & List<&2, F32>, Dd.dd.logits(k, s),
    (x: Array<F32> & List<&2, F32>) => br.after(k, pos, t, acc, x))

# the costs of ts's tokens (newest first), the first at position pos, from
# a store that has read the pos tokens before it
def br.walk(ts: List<&2, U32>, +k: Dd.Dd, +pos: Nat, r: Array<F32> & List<&2, F32>) -> IO(Array<F32> & List<&2, F32>):
  match ts:
    case Nil{}:
      IO.pure(Array<F32> & List<&2, F32>, r)
    case t <> rest:
      IO.bind(Array<F32> & List<&2, F32>, Array<F32> & List<&2, F32>, br.step(k, pos, t, r),
        (x: Array<F32> & List<&2, F32>) => br.walk(rest, k, 1n+pos, x))

def br.costs(r: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, F32>:
  (s, acc) = r
  (s, List.reverse(&2, F32, acc))

# the one-pass costs of a window's predictions: x0 stepped from zero state,
# then every later token charged at the state before it
def br.pass(+k: Dd.Dd, +w: List<&2, U32>, s: Array<F32>) -> IO(Array<F32> & List<&2, F32>):
  match w:
    case Nil{}:
      IO.pure(Array<F32> & List<&2, F32>, (s, Nil{}))
    case +x0 <> +xs:
      do IO<Array<F32> & List<&2, F32>>:
        s0 : Array<F32> <- Dd.dd.reset(k, s)
        s1 : Array<F32> <- Dd.dd.feed(k, 0n, x0, s0)
        r : Array<F32> & List<&2, F32> <- br.walk(xs, k, 1n, (s1, Nil{}))
        return br.costs(r)

# the costs from a cut: the window's first `cut` tokens read by the chunked
# prefill, then the rest stepped
def br.from(+k: Dd.Dd, +cut: Nat, +w: List<&2, U32>, s: Array<F32>) -> IO(Array<F32> & List<&2, F32>):
  do IO<Array<F32> & List<&2, F32>>:
    s0 : Array<F32> <- Dd.dd.reset(k, s)
    s1 : Array<F32> <- Dd.dd.feeds(k, List.take(&2, U32, w, cut), 0n, s0)
    r : Array<F32> & List<&2, F32> <- br.walk(List.drop(&2, U32, w, cut), k, cut, (s1, Nil{}))
    return br.costs(r)

# The trainer -------------------------------------------------------------------

def br.ones(n: Nat) -> List<&2, F32>:
  List.replicate(F32, n, 1.0)

def br.zeros(n: Nat) -> List<&2, F32>:
  List.replicate(F32, n, 0.0)

# runs of 1s and 0s: i's weight is 1 when (i mod 23) < 13
def br.runs.go(n: Nat, +i: Nat) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      Bool.pick(F32, Nat.is_lt(Nat.mod(i, 23n), 13n), 1.0, 0.0) <> br.runs.go(p, 1n+i)

def br.prompt(+k: Nat, +n: Nat) -> List<&2, F32>:
  List.append(&2, F32, br.zeros(k), br.ones(Nat.sub(n, k)))

# a window's four weightings: all 1, a prompt (the first half given), runs,
# all 0
def br.masks(+n: Nat) -> List<&2, List<&2, F32>>:
  [br.ones(n), br.prompt(Nat.div(n, 2n), n), br.runs.go(n, 0n), br.zeros(n)]

# the forward with each window's summed loss, over four copies of a window
# (one micro-batch); each copy's rows and its sum
def br.rows(+n: Nat, +t: U32, +xs: List<&2, F32>) -> List<&2, List<&2, F32>>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +tn = U32.to_nat(t)
      List.take(&2, F32, xs, tn) <> br.rows(p, t, List.drop(&2, F32, xs, tn))

# what the trainer said: each copy's rows (weighted) and its sum
type BrTr is Data:
  BrTr{rows: List<&2, List<&2, F32>>, wl: List<&2, F32>}

def br.train.wl(+m: L.Dm, +rows: List<&2, F32>, r: Array<F32> & List<&2, F32>) -> Array<F32> & BrTr:
  (s, +wl) = r
  (s, BrTr{br.rows(U32.to_nat(L.Dm.b(m)), L.Dm.t(m), rows), wl})

def br.train.rows(+m: L.Dm, +hd: L.Hd, r: Array<F32> & List<&2, F32>) -> Array<F32> & BrTr:
  (s, +rows) = r
  br.train.wl(m, rows, Io.get(U32.to_nat(L.Dm.b(m)), s, L.Hd.wl(hd)))

def br.train.fin(+m: L.Dm, +ly: L.Lay, s: Array<F32>) -> Array<F32> & BrTr:
  +hd = S.Hd(m, ly)
  br.train.rows(m, hd, Io.get(U32.to_nat(L.Dm.n(m)), s, L.Hd.loss(hd)))

def br.train(+m: L.Dm, +ly: L.Lay, +ops: List<&2, P.Op>, +w: List<&2, U32>, +wts: List<&2, List<&2, F32>>, s: Array<F32>)
    -> IO(Array<F32> & BrTr):
  +ws = List.replicate(List<&2, U32>, 4n, w)
  IO.bind(Array<F32>, Array<F32> & BrTr,
    R.run(ops, Io.put.windows.w(ws, wts, s, L.Lay.tin(ly), L.Lay.ttg(ly), L.Lay.tw(ly), L.Dm.t(m))),
    (x: Array<F32>) => IO.pure(Array<F32> & BrTr, br.train.fin(m, ly, x)))

# Checks --------------------------------------------------------------------

# the tally: checks made, checks failed
type BrT is Data:
  BrT{n: Nat, bad: Nat}

def br.add(a: BrT, b: BrT) -> BrT:
  match a b:
    case BrT{n1, b1} BrT{n2, b2}:
      BrT{Nat.add(n1, n2), Nat.add(b1, b2)}

def br.one(ok: Bool) -> BrT:
  BrT{1n, Bool.pick(Nat, ok, 0n, 1n)}

def br.mark(ok: Bool) -> String:
  Bool.pick(String, ok, "ok   ", "FAIL ")

# rows past 1e-3 + 1e-4 |y| (a NaN is past), and the largest |x - y|
def br.rowbad(xs: List<&2, F32>, ys: List<&2, F32>, +acc: Nat) -> Nat:
  match xs ys:
    case +x <> xt +y <> yt:
      +ok = F32.is_le(F32.abs(F32.sub(x, y)), F32.add(1.0e-3, F32.mul(1.0e-4, F32.abs(y))))
      br.rowbad(xt, yt, Nat.add(acc, Bool.pick(Nat, ok, 0n, 1n)))
    case _ _:
      acc

def br.rowmax(xs: List<&2, F32>, ys: List<&2, F32>, +acc: F32) -> F32:
  match xs ys:
    case +x <> xt +y <> yt:
      br.rowmax(xt, yt, F32.max(acc, F32.abs(F32.sub(x, y))))
    case _ _:
      acc

def br.rows.check(+name: String, +xs: List<&2, F32>, +ys: List<&2, F32>) -> IO(BrT):
  +nx = List.length(&2, F32, xs)
  +bad = br.rowbad(xs, ys, 0n)
  +ok = Bool.and(Nat.is_eq(bad, 0n), Nat.is_eq(nx, List.length(&2, F32, ys)))
  do IO<BrT>:
    IO.print(br.mark(ok) ++ name ++ ": " ++ Nat.show(nx) ++ " rows, " ++ Nat.show(bad) ++ " past tolerance, max |diff| "
      ++ F32.show(br.rowmax(xs, ys, 0.0)))
    return br.one(ok)

# two sums within 1e-4 of the scale (the sum of |costs|)
def br.sum.check(+name: String, +a: F32, +b: F32, +scale: F32) -> IO(BrT):
  +d = F32.abs(F32.sub(a, b))
  +ok = F32.is_le(d, F32.mul(1.0e-4, F32.max(scale, 1.0)))
  do IO<BrT>:
    IO.print(br.mark(ok) ++ name ++ ": " ++ F32.show(a) ++ " vs " ++ F32.show(b) ++ " (|diff| " ++ F32.show(d)
      ++ ", relative " ++ F32.show(F32.div(d, F32.max(scale, 1.0))) ++ ")")
    return br.one(ok)

def br.nth.l(xs: List<&2, List<&2, F32>>, n: Nat) -> List<&2, F32>:
  match xs n:
    case x <> t 0n:
      x
    case x <> t 1n+p:
      br.nth.l(t, p)
    case _ _:
      Nil{}

# One window ---------------------------------------------------------------

# the chain at one cut: costs from the cut (prefill, then steps) against the
# one-pass tail, and head plus tail against the whole
def br.cut.check(+name: String, +cut: Nat, +a: List<&2, F32>, +fr: List<&2, F32>, +scale: F32) -> IO(BrT):
  +tail = List.drop(&2, F32, a, Nat.sub(cut, 1n))
  +head = List.take(&2, F32, a, Nat.sub(cut, 1n))
  do IO<BrT>:
    x : BrT <- br.rows.check(name ++ " cut " ++ Nat.show(cut) ++ ", costs from the prefilled cut vs the one-pass tail", fr, tail)
    y : BrT <- br.sum.check(name ++ " cut " ++ Nat.show(cut) ++ ", head + tail vs the whole",
      F32.add(br.sum(head, 0.0), br.sum(fr, 0.0)), br.sum(a, 0.0), scale)
    return br.add(x, y)

def br.window.checks(+name: String, +n: Nat, +a: List<&2, F32>, +rows: List<&2, List<&2, F32>>, +wl: List<&2, F32>,
                     +f1: List<&2, F32>, +f2: List<&2, F32>, +f3: List<&2, F32>, +c1: Nat, +c2: Nat, +c3: Nat) -> IO(BrT):
  +scale = br.abssum(a, 0.0)
  +ms = br.masks(n)
  +z = br.nth(wl, 3n)
  +zok = U32.is_eq(F32.bits(z), 0)
  do IO<BrT>:
    IO.print("  " ++ name ++ ": " ++ Nat.show(n) ++ " predictions, decoder cost " ++ F32.show(br.sum(a, 0.0))
      ++ " (" ++ F32.show(F32.div(br.sum(a, 0.0), F32.from_nat(Nat.max(n, 1n)))) ++ " a token)")
    r : BrT <- br.rows.check(name ++ " rows, trainer vs decoder", List.take(&2, F32, br.nth.l(rows, 0n), n), a)
    w : BrT <- br.sum.check(name ++ " window_is_distance, trainer window loss vs decoder cost from the first token",
      br.nth(wl, 0n), br.sum(a, 0.0), scale)
    p : BrT <- br.sum.check(name ++ " prompt_is_distance, trainer prompt-masked loss vs decoder cost from the prefilled prompt",
      br.nth(wl, 1n), br.sum(f2, 0.0), scale)
    q : BrT <- br.sum.check(name ++ " masked_runs, trainer run-masked loss vs decoder costs over the kept runs",
      br.nth(wl, 2n), br.kept(a, br.nth.l(ms, 2n), 0.0), scale)
    c : BrT <- br.cut.check(name ++ " cost_composition", c1, a, f1, scale)
    d : BrT <- br.cut.check(name ++ " cost_composition", c2, a, f2, scale)
    e : BrT <- br.cut.check(name ++ " cost_composition", c3, a, f3, scale)
    IO.print(br.mark(zok) ++ name ++ " cost_identity, trainer loss with every weight 0: " ++ F32.show(z) ++ " (bits must be 0)")
    return br.add(br.add(br.add(r, w), br.add(p, q)), br.add(br.add(c, d), br.add(e, br.one(zok))))

type BrE is Data:
  BrE{m: L.Dm, ly: L.Lay, ops: List<&2, P.Op>, k: Dd.Dd}

def br.E.m(+e: BrE) -> L.Dm:
  match e:
    case BrE{m, ly, o, k}:
      m

def br.E.ly(+e: BrE) -> L.Lay:
  match e:
    case BrE{m, ly, o, k}:
      ly

def br.E.ops(+e: BrE) -> List<&2, P.Op>:
  match e:
    case BrE{m, ly, o, k}:
      o

def br.E.k(+e: BrE) -> Dd.Dd:
  match e:
    case BrE{m, ly, o, k}:
      k

def br.E.of(+c: C.Config) -> BrE:
  +m = L.Dm.of.cc(c, 4n, 16)
  +ly = L.Lay.of(c, m)
  BrE{m, ly, S.eval(m, ly), Dd.dd.of(c)}

# the decoder's costs: one pass, then from each cut
type BrD is Data:
  BrD{a: List<&2, F32>, f1: List<&2, F32>, f2: List<&2, F32>, f3: List<&2, F32>}

def br.D.a(+d: BrD) -> List<&2, F32>:
  match d:
    case BrD{a, f1, f2, f3}:
      a

def br.D.f1(+d: BrD) -> List<&2, F32>:
  match d:
    case BrD{a, f1, f2, f3}:
      f1

def br.D.f2(+d: BrD) -> List<&2, F32>:
  match d:
    case BrD{a, f1, f2, f3}:
      f2

def br.D.f3(+d: BrD) -> List<&2, F32>:
  match d:
    case BrD{a, f1, f2, f3}:
      f3

def br.Tr.rows(+r: BrTr) -> List<&2, List<&2, F32>>:
  match r:
    case BrTr{rows, wl}:
      rows

def br.Tr.wl(+r: BrTr) -> List<&2, F32>:
  match r:
    case BrTr{rows, wl}:
      wl

def br.dec.f3(+a: List<&2, F32>, +f1: List<&2, F32>, +f2: List<&2, F32>, r: Array<F32> & List<&2, F32>) -> Array<F32> & BrD:
  (s, +f3) = r
  (s, BrD{a, f1, f2, f3})

def br.dec.f2(+k: Dd.Dd, +w: List<&2, U32>, +c3: Nat, +a: List<&2, F32>, +f1: List<&2, F32>, r: Array<F32> & List<&2, F32>) -> IO(Array<F32> & BrD):
  (s, +f2) = r
  IO.bind(Array<F32> & List<&2, F32>, Array<F32> & BrD, br.from(k, c3, w, s),
    (x: Array<F32> & List<&2, F32>) => IO.pure(Array<F32> & BrD, br.dec.f3(a, f1, f2, x)))

def br.dec.f1(+k: Dd.Dd, +w: List<&2, U32>, +c2: Nat, +c3: Nat, +a: List<&2, F32>, r: Array<F32> & List<&2, F32>) -> IO(Array<F32> & BrD):
  (s, +f1) = r
  IO.bind(Array<F32> & List<&2, F32>, Array<F32> & BrD, br.from(k, c2, w, s),
    (x: Array<F32> & List<&2, F32>) => br.dec.f2(k, w, c3, a, f1, x))

def br.dec.a(+k: Dd.Dd, +w: List<&2, U32>, +c1: Nat, +c2: Nat, +c3: Nat, r: Array<F32> & List<&2, F32>) -> IO(Array<F32> & BrD):
  (s, +a) = r
  IO.bind(Array<F32> & List<&2, F32>, Array<F32> & BrD, br.from(k, c1, w, s),
    (x: Array<F32> & List<&2, F32>) => br.dec.f1(k, w, c2, c3, a, x))

def br.dec(+k: Dd.Dd, +w: List<&2, U32>, +c1: Nat, +c2: Nat, +c3: Nat, s: Array<F32>) -> IO(Array<F32> & BrD):
  IO.bind(Array<F32> & List<&2, F32>, Array<F32> & BrD, br.pass(k, w, s),
    (x: Array<F32> & List<&2, F32>) => br.dec.a(k, w, c1, c2, c3, x))

def br.window.c(+name: String, +n: Nat, +c1: Nat, +c2: Nat, +c3: Nat, ts: Array<F32>, +tr: BrTr, y: Array<F32> & BrD) -> IO(Array<F32> & Array<F32> & BrT):
  (ds, +dr) = y
  IO.bind(BrT, Array<F32> & Array<F32> & BrT,
    br.window.checks(name, n, br.D.a(dr), br.Tr.rows(tr), br.Tr.wl(tr), br.D.f1(dr), br.D.f2(dr), br.D.f3(dr), c1, c2, c3),
    (t: BrT) => IO.pure(Array<F32> & Array<F32> & BrT, (ts, ds, t)))

def br.window.d(+name: String, +k: Dd.Dd, +w: List<&2, U32>, ds: Array<F32>, x: Array<F32> & BrTr) -> IO(Array<F32> & Array<F32> & BrT):
  (ts, +tr) = x
  +n = Nat.sub(List.length(&2, U32, w), 1n)
  +c1 = Nat.max(1n, Nat.div(n, 3n))
  +c2 = Nat.add(1n, Nat.div(n, 2n))
  +c3 = Nat.max(1n, Nat.div(Nat.mul(2n, n), 3n))
  IO.bind(Array<F32> & BrD, Array<F32> & Array<F32> & BrT, br.dec(k, w, c1, c2, c3, ds),
    (y: Array<F32> & BrD) => br.window.c(name, n, c1, c2, c3, ts, tr, y))

# one window on both stores: the trainer's and the decoder's
def br.window(+name: String, +e: BrE, +w: List<&2, U32>, st: Array<F32> & Array<F32>) -> IO(Array<F32> & Array<F32> & BrT):
  (ts, ds) = st
  IO.bind(Array<F32> & BrTr, Array<F32> & Array<F32> & BrT,
    br.train(br.E.m(e), br.E.ly(e), br.E.ops(e), w, br.masks(Nat.sub(List.length(&2, U32, w), 1n)), ts),
    (x: Array<F32> & BrTr) => br.window.d(name, br.E.k(e), w, ds, x))

def br.tally(+a: BrT, r: Array<F32> & Array<F32> & BrT) -> Array<F32> & Array<F32> & BrT:
  (ts, db) = r
  (ds, b) = db
  (ts, ds, br.add(a, b))

def br.windows(ws: List<&2, List<&2, U32>>, +name: String, +i: Nat, +e: BrE, r: Array<F32> & Array<F32> & BrT) -> IO(Array<F32> & Array<F32> & BrT):
  match ws:
    case Nil{}:
      IO.pure(Array<F32> & Array<F32> & BrT, r)
    case +w <> rest:
      (ts, dt) = r
      (ds, t) = dt
      IO.bind(Array<F32> & Array<F32> & BrT, Array<F32> & Array<F32> & BrT,
        br.window(name ++ " window " ++ Nat.show(i), e, w, {(ts, ds) : Array<F32> & Array<F32>}),
        (x: Array<F32> & Array<F32> & BrT) => br.windows(rest, name, 1n+i, e, br.tally(t, x)))

def br.done(r: Array<F32> & Array<F32> & BrT) -> BrT:
  (ts, dt) = r
  (ds, t) = dt
  t

# where the parameters come from: a config's random init, or an FTC2
# checkpoint's parameter vector (at h, the header's end; p of them)
type BrSrc is Data:
  Rand{c: C.Config}
  Ckpt{path: String, h: Nat, p: U32}

def br.close(r: File & Array<F32>) -> IO(Array<F32>):
  (f, s) = r
  do IO<Array<F32>>:
    u : Unit <- File.close(f)
    return s

# the parameters into a store at 0, where the trainer and the decoder keep them
def br.params(+src: BrSrc, s: Array<F32>) -> IO(Array<F32>):
  match src:
    case Rand{+c}:
      IO.pure(Array<F32>, Io.put(TK.Weights.flat(I.init(c)), s, 0))
    case Ckpt{+path, +h, +p}:
      +o = Dk.Off.of(U32.from_nat(h), p)
      do IO<Array<F32>>:
        f : File <- IO.try(File, File.open(path, "r"))
        r : File & Array<F32> <- Dk.rds([Dk.Rd{Dk.Off.par(o), p, 0}], (f, s))
        br.close(r)

# a config's run: both stores hold the same parameters
def br.run(+name: String, +c: C.Config, +ws: List<&2, List<&2, U32>>, +src: BrSrc) -> IO(BrT):
  +e = br.E.of(c)
  do IO<BrT>:
    IO.print(name ++ ": " ++ C.Config.show(c) ++ "; trainer store " ++ U32.show(L.Lay.total(br.E.ly(e))) ++ " floats, "
      ++ Nat.show(List.length(&2, List<&2, U32>, ws)) ++ " windows")
    ts : Array<F32> <- br.params(src, Array.new(F32, L.Lay.depth(br.E.ly(e)), 0.0))
    ds : Array<F32> <- br.params(src, Dd.dd.new(br.E.k(e)))
    r : Array<F32> & Array<F32> & BrT <- br.windows(ws, name, 0n, e, (ts, ds, BrT{0n, 0n}))
    return br.done(r)

# Runs ----------------------------------------------------------------------

def br.rnd(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

# n byte tokens (2..257), a pseudo-random walk from seed s
def br.window.rnd(n: Nat, +s: U32) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      U32.add(2, U32.and(U32.shrn(s, 16n), 255)) <> br.window.rnd(p, br.rnd(s))

def br.no.arms() -> C.Config:
  C.Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 4n, 4n, False{}, False{}, False{}, True{}}

def br.verdict.if(ok: Bool, +what: String, +n: Nat, +bad: Nat) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("ok   bradley (" ++ what ++ "): all " ++ Nat.show(n) ++ " checks within tolerance")
    case False{}:
      IO.die(Unit, 1, "bradley (" ++ what ++ "): " ++ Nat.show(bad) ++ " of " ++ Nat.show(n) ++ " checks failed")

def br.verdict(+what: String, t: BrT) -> IO(Unit):
  match t:
    case BrT{+n, +bad}:
      br.verdict.if(Nat.is_eq(bad, 0n), what, n, bad)

# random weights: v3's arms and none of them, two windows of ctx (64) each
def br.ci() -> IO(Unit):
  +ws = {[br.window.rnd(64n, 7), br.window.rnd(64n, 11)] : List<&2, List<&2, U32>>}
  do IO<Unit>:
    a : BrT <- br.run("v3 arms", C.Config.small4_v3(), ws, Rand{C.Config.small4_v3()})
    b : BrT <- br.run("no arms", br.no.arms(), ws, Rand{br.no.arms()})
    br.verdict("random weights", br.add(a, b))

# the checkpoint's config with ctx cut to w
def br.with.ctx(+c: C.Config, +w: Nat) -> C.Config:
  match c:
    case C.Config{v, n, d, f, l, h, g, q, s, t}:
      C.Config{v, w, d, f, l, h, g, q, s, t}

def br.full(+w: Nat, ws: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +x <> t:
      List.filter.put(List<&2, U32>, x, br.full(w, t), Nat.is_eq(List.length(&2, U32, x), w))

def br.fail.go(ok: Bool, +why: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "bradley: " ++ why)

def br.fail.if(+why: String) -> IO(Unit):
  br.fail.go(String.is_empty(why), why)

def br.ckpt.go(+path: String, +cpath: String, +n: Nat, +w: Nat, mh: K.Manifest & Nat) -> IO(Unit):
  (+man, +h) = mh
  +c0 = K.Manifest.cfg(man)
  +c = br.with.ctx(c0, w)
  +p = U32.from_nat(C.Config.params(c))
  do IO<Unit>:
    br.fail.if(K.Manifest.problem(man))
    br.fail.if(Bool.pick(String, C.Config.tied(c0), "", "the dense decoder needs a tied head"))
    br.fail.if(Bool.pick(String, Nat.is_le(w, C.Config.ctx(c0)), "", "W is past the checkpoint's context"))
    +xs : List<&2, U32> <- By.Bytes.read_all(cpath)
    +co : Cc.Corpus = Cc.corpus(xs)
    br.fail.if(Cc.Corpus.problem(co, K.Manifest.tokenizer_id(man)))
    +ws : List<&2, List<&2, U32>> = List.take(&2, List<&2, U32>, br.full(w, D.all.windows(w, List.take(&2, List<&2, U32>, Cc.Corpus.docs(co), 4000n))), n)
    IO.print("checkpoint " ++ path ++ " (" ++ C.Config.show(c0) ++ "), its ctx cut to " ++ Nat.show(w) ++ "; " ++ Nat.show(List.length(&2, List<&2, U32>, ws))
      ++ " windows from " ++ cpath)
    t : BrT <- br.run("checkpoint", c, ws, Ckpt{path, h, p})
    br.verdict("checkpoint", t)

def br.nat.of(m: Maybe<&2, U32>, +d: Nat) -> Nat:
  match m:
    case Some{x}:
      U32.to_nat(x)
    case None{}:
      d

def br.nat.or(+s: String, +d: Nat) -> Nat:
  br.nat.of(U32.read(s), d)

def br.opt(xs: List<String>) -> String & List<String>:
  match xs:
    case Nil{}:
      ("", Nil{})
    case x <> t:
      (x, t)

def br.go.w(+path: String, +cpath: String, +ns: String, r: String & List<String>) -> IO(Unit):
  (+wsz, rest) = r
  +n = br.nat.or(ns, 2n)
  +w = br.nat.or(wsz, 512n)
  IO.bind(K.Manifest & Nat, Unit, Dk.header(path), (mh: K.Manifest & Nat) => br.ckpt.go(path, cpath, n, w, mh))

def br.go.n(+path: String, +cpath: String, r: String & List<String>) -> IO(Unit):
  (+ns, more) = r
  br.go.w(path, cpath, ns, br.opt(more))

def br.main(args: List<String>) -> IO(Unit):
  match args:
    case Nil{}:
      br.ci()
    case +path <> rest:
      match rest:
        case +cpath <> more:
          br.go.n(path, cpath, br.opt(more))
        case Nil{}:
          IO.die(Unit, 1, "usage: bradley [CKPT CORPUS [N] [W]]")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    br.main(List.tail(&1, String, argv))
