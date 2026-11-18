import Base
import ../Bulk.bend as B
import ../Config.bend as C
import ../Train/Init.bend as I
import ../Train/Ckpt.bend as K
import ../Dense/Ex.bend as X
import ../Dense/Op.bend as P
import ../Dense/Run.bend as R
import ../Dense/Layout.bend as L
import ../Dense/Model.bend as M
import ../Dense/Step.bend as S
import ../Dense/Io.bend as Io

# The trainer's speed work of 2026-11-18 (the user: "Work on speed without
# renting, fix the slowest parts in bend ... Add bend laws where
# appropriate"), checked on the CPU, where every op runs its definition:
#
# seq   a Seq (Dense/Op.bend) against the einsums it stands for, one a
#       slice: the same forward, and its transposes (the carried input's
#       as a Seq the other way, the others' at once over every slice)
#       against the slices' own transposes run last slice first. Every
#       cell of the store, values and tangents, bit for bit.
# gla   the GLA layer as it is now (the chunk state and the read across
#       chunks as a decayed key or query times a product per head, the
#       state across chunks one Seq, the states window-major) against the
#       layer as it was (old.gla below, verbatim but for the names: both
#       of those as einsums with exp inside the sum, the state one einsum
#       a chunk, chunk-major): the forward, every layer's output and the
#       loss, bit for bit, at chunk 16 (four a window) and 64 (one).
#
# The gradients of the new layer are tests/dense.bend's (the tree trainer,
# within 1e-5) and tests/dualgrad.bend's (forward mode); the GPU's kernels
# are bulk.c's, checked on a GPU box by the same programs (fp.sh gate).

# Bits ---------------------------------------------------------------------

def rnd.next(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

# n values in (-0.5, 0.5), a pseudo-random walk from seed s
def rnd(n: Nat, +s: U32) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      F32.sub(F32.div(U32.to_f32(U32.shrn(s, 8n)), 16777216.0), 0.5) <> rnd(p, rnd.next(s))

# the first index where two lists of F32 differ in their bits (n when none)
def first.diff(xs: List<&2, F32>, ys: List<&2, F32>, +i: Nat) -> Nat:
  match xs ys:
    case +x <> xt +y <> yt:
      Bool.pick(Nat, U32.is_eq(F32.bits(x), F32.bits(y)), first.diff(xt, yt, 1n+i), i)
    case Nil{} Nil{}:
      i
    case _ _:
      i

def same(+name: String, +n: Nat, xs: List<&2, F32>, ys: List<&2, F32>) -> IO(Bool):
  +at = first.diff(xs, ys, 0n)
  +ok = Nat.is_eq(at, n)
  do IO<Bool>:
    IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ name ++ Bool.pick(String, ok,
      ": " ++ Nat.show(n) ++ " cells, bit for bit", ": first differing cell " ++ Nat.show(at) ++ " of " ++ Nat.show(n)))
    return ok

def snap.fin(r: Array<F32> & List<&2, F32>) -> List<&2, F32>:
  (x, xs) = r
  xs

def snap(+n: Nat, +at: U32, s: Array<F32>) -> List<&2, F32>:
  snap.fin(Io.get(n, s, at))

def snap2.fin(+k: Nat, +at2: U32, r: Array<F32> & List<&2, F32>) -> List<&2, F32> & List<&2, F32>:
  (s, xs) = r
  (xs, snap(k, at2, s))

# n cells from at, then k cells from at2
def snap2(+n: Nat, +at: U32, +k: Nat, +at2: U32, s: Array<F32>) -> List<&2, F32> & List<&2, F32>:
  snap2.fin(k, at2, Io.get(n, s, at))

# seq ------------------------------------------------------------------------
#
# s_{k+1} = exp(a_k) ⊙ s_k + u_k over k < 5, lanes [3 × 4], the decay a
# shared by the lane's last index (as GLA's B_last is by the value's):
# s at 0 (6 slices of 12 cells), a at 100 ([5 × 3]), u at 200 ([5 × 12]);
# tangents tg = 512 on, the output's seeded at random as a later op would.

def tg() -> U32:
  512

def scan.es() -> B.Es:
  B.Es{[5, 3, 4], 0, 0, 0, P.view(12, [12, 4, 1]),
    [P.view(100, [3, 1, 0]), P.view(0, [12, 4, 1]), P.view(200, [12, 4, 1])],
    X.add(X.mul(X.exp(X.x(0)), X.x(1)), X.x(2))}

# the slices with their transposes on (Seq.slices makes them without)
def grad.on(ops: List<&2, P.Op>) -> List<&2, P.Op>:
  match ops:
    case Nil{}:
      Nil{}
    case P.Ein{es, spec, g} <> t:
      P.Ein{es, spec, True{}} <> grad.on(t)
    case op <> t:
      op <> grad.on(t)

def store0() -> Array<F32>:
  Io.put(rnd(1024n, 99), Array.new(F32, 10n, 0.0), 0)

def run.both(+ops: List<&2, P.Op>, s: Array<F32>) -> IO(Array<F32>):
  do IO<Array<F32>>:
    s1 : Array<F32> <- R.run(ops, s)
    R.run(P.back(tg(), ops, Nil{}), s1)

def seq.check() -> IO(Bool):
  +es = scan.es()
  do IO<Bool>:
    a : Array<F32> <- run.both([P.seq(es, 0, 0, 1, True{})], store0())
    b : Array<F32> <- run.both(grad.on(P.Seq.slices(es, 0, 0)), store0())
    same("seq: a Seq and its slices, forward and transposes", 1024n, snap(1024n, 0, a), snap(1024n, 0, b))

# gla ------------------------------------------------------------------------
#
# The layer as it was until 2026-11-18 (Dense/Model.bend at 2e7c9dc), its
# einsums verbatim; the states u and sin chunk-major (chunk jj of window b
# at (jj·b + b)·h·hd²), sin's first chunk zeroed as one block.

def old.op(+es: B.Es) -> P.Op:
  P.ein(es, True{})

def old.v(off: U32, st: List<&2, U32>) -> B.View:
  P.view(off, st)

def old.gla.scan(n: Nat, +m: L.Dm, +w: L.Wg, +jj: U32) -> List<&2, P.Op>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +h = L.Dm.h(m)
      +hd = L.Dm.hd(m)
      +d = L.Dm.d(m)
      +x2 = U32.mul(h, U32.mul(hd, hd))
      +bx = U32.mul(L.Dm.b(m), x2)
      +cc = L.Dm.cc(m)
      +prev = U32.sub(jj, 1)
      +last = U32.add(L.Wg.bc(w), U32.mul(U32.add(U32.mul(prev, cc), U32.sub(cc, 1)), d))
      old.op(B.Es{[L.Dm.b(m), h, hd, hd], 0, 0, 0, old.v(U32.add(L.Wg.sin(w), U32.mul(jj, bx)), [x2, U32.mul(hd, hd), hd, 1]),
        [old.v(last, [U32.mul(L.Dm.t(m), d), hd, 1, 0]),
         old.v(U32.add(L.Wg.sin(w), U32.mul(prev, bx)), [x2, U32.mul(hd, hd), hd, 1]),
         old.v(U32.add(L.Wg.u(w), U32.mul(prev, bx)), [x2, U32.mul(hd, hd), hd, 1])],
        X.add(X.mul(X.exp(X.x(0)), X.x(1)), X.x(2))}) <> old.gla.scan(p, m, w, U32.inc(jj))

def old.gla(+m: L.Dm, +bp: L.BP, +x: U32, +xo: U32, +w: L.Wg) -> List<&2, P.Op>:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +cc = L.Dm.cc(m)
  +t = L.Dm.t(m)
  +d3 = U32.mul(3, d)
  +nd = U32.mul(n, d)
  +ccd = U32.mul(cc, d)
  +td = U32.mul(t, d)
  +hh2 = U32.mul(hd, hd)
  +x2 = U32.mul(h, hh2)
  +vv = U32.add(L.Wg.qkv(w), U32.mul(2, d))
  +kh = M.gla.key(L.Dm.rglru(m), w)
  List.concat(&2, P.Op, [
    M.norm(n, d, x, L.BP.ra(bp), L.Wg.ss(w), L.Wg.nrm(w)),
    [P.linear(n, d, d3, L.Wg.nrm(w), d, L.BP.wq(bp), L.Wg.qkv(w), d3),
     P.linear(n, d, d, L.Wg.nrm(w), d, L.BP.wa(bp), L.Wg.z(w), d)],
    M.l2(n, h, hd, L.Wg.qkv(w), d3, L.Wg.sq(w), L.Wg.qh(w)),
    M.l2(n, h, hd, U32.add(L.Wg.qkv(w), d), d3, L.Wg.sk(w), L.Wg.kh0(w)),
    M.gla.gate(L.Dm.rglru(m), m, bp, w),
    [old.op(B.Es{[L.Dm.nc(m), cc, d, cc], 8, 0, 0, old.v(L.Wg.bc(w), [ccd, d, 1, 0]), [old.v(L.Wg.la(w), [ccd, 0, 1, d])],
       X.sel(X.le(X.ix(3), X.ix(1)), X.x(0), X.k(0.0))}),
     old.op(B.Es{[L.Dm.nc(m), h, cc, cc, hd], 16, 0, 0, old.v(L.Wg.a(w), [U32.mul(h, U32.mul(cc, cc)), U32.mul(cc, cc), cc, 1, 0]),
       [old.v(L.Wg.qh(w), [ccd, hd, d, 0, 1]), old.v(kh, [ccd, hd, 0, d, 1]),
        old.v(L.Wg.bc(w), [ccd, hd, d, 0, 1]), old.v(L.Wg.bc(w), [ccd, hd, 0, d, 1])],
       X.sel(X.le(X.ix(3), X.ix(2)), X.mul(X.mul(X.x(0), X.x(1)), X.exp(X.sub(X.x(2), X.x(3)))), X.k(0.0))}),
     old.op(B.Es{[L.Dm.b(m), L.Dm.j(m), h, hd, hd, cc], 32, 0, 0,
       old.v(L.Wg.u(w), [x2, U32.mul(L.Dm.b(m), x2), hh2, hd, 1, 0]),
       [old.v(kh, [td, ccd, hd, 1, 0, d]), old.v(U32.add(L.Wg.bc(w), U32.mul(U32.sub(cc, 1), d)), [td, ccd, hd, 1, 0, 0]),
        old.v(L.Wg.bc(w), [td, ccd, hd, 1, 0, d]), old.v(vv, [U32.mul(t, d3), U32.mul(cc, d3), hd, 0, 1, d3])],
       X.mul(X.mul(X.x(0), X.exp(X.sub(X.x(1), X.x(2)))), X.x(3))}),
     P.zero(U32.mul(L.Dm.b(m), x2), L.Wg.sin(w))],
    M.gla.mix(U32.to_nat(h), 0, m, w),
    old.gla.scan(U32.to_nat(U32.sub(L.Dm.j(m), 1)), m, w, 1),
    [old.op(B.Es{[L.Dm.b(m), L.Dm.j(m), cc, h, hd, hd], 32, 0, 0, old.v(L.Wg.oe(w), [td, ccd, d, hd, 1, 0]),
       [old.v(L.Wg.qh(w), [td, ccd, d, hd, 0, 1]), old.v(L.Wg.bc(w), [td, ccd, d, hd, 0, 1]),
        old.v(L.Wg.sin(w), [x2, U32.mul(L.Dm.b(m), x2), 0, hh2, 1, hd])],
       X.mul(X.mul(X.x(0), X.exp(X.x(1))), X.x(2))}),
     M.add2(nd, L.Wg.o(w), L.Wg.oi(w), L.Wg.oe(w))],
    M.tail(m, bp, x, xo, L.Wg.o(w), L.Wg.y1(w), L.Wg.xa(w), L.Wg.ss2(w), L.Wg.nrm2(w), L.Wg.gu(w), L.Wg.hh(w), L.Wg.y2(w))])

def old.layer.k(g: Bool, +m: L.Dm, +ly: L.Lay, +bp: L.BP, +i: U32) -> List<&2, P.Op>:
  match g:
    case True{}:
      old.gla(m, bp, L.Lay.x(ly, m, i), L.Lay.x(ly, m, U32.inc(i)), L.Wg.at(m, L.Lay.ws(ly)))
    case False{}:
      M.layer.k(False{}, m, ly, bp, i)

def old.layers(bs: List<&2, L.BP>, +m: L.Dm, +ly: L.Lay, +i: U32) -> List<&2, List<&2, P.Op>>:
  match bs:
    case Nil{}:
      Nil{}
    case +bp <> t:
      old.layer.k(L.BP.gla(bp), m, ly, bp, i) <> old.layers(t, m, ly, U32.inc(i))

def old.fwd(+m: L.Dm, +ly: L.Lay) -> List<&2, P.Op>:
  +hd = S.Hd(m, ly)
  S.cat([M.embed(m, ly), S.cat(old.layers(L.Lay.blocks(ly), m, ly, 0)), M.head.fin(m, ly, hd),
         S.cat(M.head.chunks(S.nchunks(m), m, ly, hd, 0)), M.head.loss(m, ly, hd)])

def window(n: Nat, +s: U32) -> List<&2, U32>:
  match n:
    case 0n:
      [0]
    case 1n+p:
      U32.add(2, U32.and(U32.shrn(s, 16n), 255)) <> window(p, rnd.next(s))

def gla.store(+c: C.Config, +ly: L.Lay, +m: L.Dm) -> Array<F32>:
  Io.put.windows([window(63n, 7), window(63n, 12345)], Io.put(K.Weights.flat(I.init(c)), Array.new(F32, L.Lay.depth(ly), 0.0), 0),
    L.Lay.tin(ly), L.Lay.ttg(ly), L.Lay.tw(ly), L.Dm.t(m))

def gla.same(+name: String, +xs: Nat, a: List<&2, F32> & List<&2, F32>, b: List<&2, F32> & List<&2, F32>) -> IO(Bool):
  (ax, al) = a
  (bx, bl) = b
  do IO<Bool>:
    ok1 : Bool <- same("gla " ++ name ++ ": every layer's output", xs, ax, bx)
    ok2 : Bool <- same("gla " ++ name ++ ": the mean loss", 1n, al, bl)
    return Bool.and(ok1, ok2)

# every layer's output and the scalars (the mean loss first), new and old
def gla.check(+c: C.Config, +cc: U32, +name: String) -> IO(Bool):
  +m = L.Dm.of.cc(c, 2n, cc)
  +ly = L.Lay.of(c, m)
  +xs = U32.to_nat(U32.mul(U32.add(L.Dm.l(m), 1), U32.mul(L.Dm.n(m), L.Dm.d(m))))
  do IO<Bool>:
    a : Array<F32> <- R.run(S.fwd(m, ly), gla.store(c, ly, m))
    b : Array<F32> <- R.run(old.fwd(m, ly), gla.store(c, ly, m))
    gla.same(name, xs, snap2(xs, L.Lay.x0(ly), 1n, L.Lay.lmean(ly), a), snap2(xs, L.Lay.x0(ly), 1n, L.Lay.lmean(ly), b))

def all(xs: List<&2, Bool>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case x <> t:
      Bool.and(x, all(t))

def verdict.if(ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.print("ok seq and gla, bit for bit")
    case False{}:
      IO.die(Unit, 1, "seq: a check differs (see FAIL above)")

def verdict(+oks: List<&2, Bool>) -> IO(Unit):
  verdict.if(all(oks))

def main() -> IO(Unit):
  do IO<Unit>:
    r1 : Bool <- seq.check()
    r2 : Bool <- gla.check(C.Config.small4_v3(), 16, "chunk 16 (four a window)")
    r3 : Bool <- gla.check(C.Config.small4_v3(), 64, "chunk 64 (one a window)")
    verdict([r1, r2, r3])
