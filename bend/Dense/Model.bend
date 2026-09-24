import Base
import ../Config.bend as C
import ./Ex.bend as X
import ./Op.bend as P
import ./Layout.bend as L

# The hybrid decoder's training forward as a program over the store, in
# master's decomposed order: a micro-batch of b windows (n = b·t tokens)
# flows through every layer at once; projections are matrix products;
# everything else is an einsum of Ops.bend's expressions. GLA runs in its
# chunked form (chunks of cc positions): within a chunk, the decayed
# products q_τ·k_σ·exp(B_τ − B_σ) (B the running sum of log α); across
# chunks, the state recurrence. Spec/Linear.bend proves the chunked form
# equal to the recurrent one that Model.bend decodes with.

def f(+n: U32) -> F32:
  U32.to_f32(n)

def v(off: U32, st: List<&2, U32>) -> View:
  P.view(off, st)

def op(+es: Es) -> P.Op:
  P.ein(es, True{})

# rms_norm: y = (x · 1/sqrt(Σx²/d + 1e-5)) · g, rows of d
def norm(+n: U32, +d: U32, +x: U32, +g: U32, +ss: U32, +y: U32) -> List<&2, P.Op>:
  [op(Es{[n, d], 2, 0, 0, v(ss, [1, 0]), [v(x, [d, 1])], X.mul(X.x(0), X.x(0))}),
   op(Es{[n, d], 0, 0, 0, v(y, [d, 1]), [v(x, [d, 1]), v(ss, [1, 0]), v(g, [0, 1])],
     X.mul(X.mul(X.x(0), X.rms_scale(X.x(1), f(d))), X.x(2))})]

# per-head L2 normalization (l2_head) of rows [n × h·hd] with stride ld
def l2(+n: U32, +h: U32, +hd: U32, +src: U32, +ld: U32, +sq: U32, +y: U32) -> List<&2, P.Op>:
  [op(Es{[n, h, hd], 4, 0, 0, v(sq, [h, 1, 0]), [v(src, [ld, hd, 1])], X.mul(X.x(0), X.x(0))}),
   op(Es{[n, h, hd], 0, 0, 0, v(y, [U32.mul(h, hd), hd, 1]), [v(src, [ld, hd, 1]), v(sq, [h, 1, 0])],
     X.div(X.x(0), X.sqrt(X.add(X.k(1.0e-6), X.x(1))))})]

# per-head RMSNorm with gains 1 + w (qk_head)
def qkn(+n: U32, +h: U32, +hd: U32, +src: U32, +ld: U32, +w: U32, +sq: U32, +y: U32) -> List<&2, P.Op>:
  [op(Es{[n, h, hd], 4, 0, 0, v(sq, [h, 1, 0]), [v(src, [ld, hd, 1])], X.mul(X.x(0), X.x(0))}),
   op(Es{[n, h, hd], 0, 0, 0, v(y, [U32.mul(h, hd), hd, 1]), [v(src, [ld, hd, 1]), v(sq, [h, 1, 0]), v(w, [0, 0, 1])],
     X.mul(X.mul(X.x(0), X.rms_scale(X.x(1), f(hd))), X.add(X.k(1.0), X.x(2)))})]

def add2(+cells: U32, +y: U32, +a: U32, +b: U32) -> P.Op:
  P.map1(cells, y, [a, b], X.add(X.x(0), X.x(1)), True{})

# The block's tail: x + Wo att, then the gated MLP on its RMSNorm
def tail(+m: L.Dm, +bp: L.BP, +x: U32, +xo: U32, +att: U32, +y1: U32, +xa: U32,
  +ss2: U32, +nrm2: U32, +gu: U32, +hh: U32, +y2: U32) -> List<&2, P.Op>:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +ff = L.Dm.f(m)
  +nd = U32.mul(n, d)
  List.concat(&2, P.Op, [
    [P.linear(n, d, d, att, d, L.BP.wo(bp), y1, d), add2(nd, xa, x, y1)],
    norm(n, d, xa, L.BP.rf(bp), ss2, nrm2),
    [P.linear(n, d, U32.mul(2, ff), nrm2, d, L.BP.wg(bp), gu, U32.mul(2, ff)),
     op(Es{[n, ff], 0, 0, 0, v(hh, [ff, 1]), [v(gu, [U32.mul(2, ff), 1]), v(U32.add(gu, ff), [U32.mul(2, ff), 1])],
       X.mul(X.silu(X.x(0)), X.x(1))}),
     P.linear(n, ff, d, hh, ff, L.BP.wd(bp), y2, d), add2(nd, xo, xa, y2)]])

# GLA ----------------------------------------------------------------------

def gla.gate(g: Bool, +m: L.Dm, +bp: L.BP, +w: L.Wg) -> List<&2, P.Op>:
  match g:
    case True{}:
      +n = L.Dm.n(m)
      +d = L.Dm.d(m)
      [op(Es{[n, d], 0, 0, 0, v(L.Wg.la(w), [d, 1]), [v(L.Wg.z(w), [d, 1]), v(L.BP.lam(bp), [0, 1])],
         X.rglru_log_gate(X.x(0), X.x(1))}),
       op(Es{[n, d], 0, 0, 0, v(L.Wg.kh(w), [d, 1]), [v(L.Wg.kh0(w), [d, 1]), v(L.Wg.la(w), [d, 1])],
         X.mul(X.x(0), X.rglru_write_scale(X.x(1)))})]
    case False{}:
      +n = L.Dm.n(m)
      +d = L.Dm.d(m)
      [op(Es{[n, d], 0, 0, 0, v(L.Wg.la(w), [d, 1]), [v(L.Wg.z(w), [d, 1])], X.log_sigmoid(X.x(0))})]

# the key after the gate: khat (RG-LRU's write-scaled key) or k^ itself
def gla.key(g: Bool, +w: L.Wg) -> U32:
  Bool.pick(U32, g, L.Wg.kh(w), L.Wg.kh0(w))

# the state entering chunk jj of every window, from the one before
def gla.scan(n: Nat, +m: L.Dm, +w: L.Wg, +jj: U32) -> List<&2, P.Op>:
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
      op(Es{[L.Dm.b(m), h, hd, hd], 0, 0, 0, v(U32.add(L.Wg.sin(w), U32.mul(jj, bx)), [x2, U32.mul(hd, hd), hd, 1]),
        [v(last, [U32.mul(L.Dm.t(m), d), hd, 1, 0]),
         v(U32.add(L.Wg.sin(w), U32.mul(prev, bx)), [x2, U32.mul(hd, hd), hd, 1]),
         v(U32.add(L.Wg.u(w), U32.mul(prev, bx)), [x2, U32.mul(hd, hd), hd, 1])],
        X.add(X.mul(X.exp(X.x(0)), X.x(1)), X.x(2))}) <> gla.scan(p, m, w, U32.inc(jj))

def gla(+m: L.Dm, +bp: L.BP, +x: U32, +xo: U32, +w: L.Wg) -> List<&2, P.Op>:
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
  +kh = gla.key(L.Dm.rglru(m), w)
  List.concat(&2, P.Op, [
    norm(n, d, x, L.BP.ra(bp), L.Wg.ss(w), L.Wg.nrm(w)),
    [P.linear(n, d, d3, L.Wg.nrm(w), d, L.BP.wq(bp), L.Wg.qkv(w), d3),
     P.linear(n, d, d, L.Wg.nrm(w), d, L.BP.wa(bp), L.Wg.z(w), d)],
    l2(n, h, hd, L.Wg.qkv(w), d3, L.Wg.sq(w), L.Wg.qh(w)),
    l2(n, h, hd, U32.add(L.Wg.qkv(w), d), d3, L.Wg.sk(w), L.Wg.kh0(w)),
    gla.gate(L.Dm.rglru(m), m, bp, w),
    # B: the running sum of log α within each chunk
    [op(Es{[L.Dm.nc(m), cc, d, cc], 8, 0, 0, v(L.Wg.bc(w), [ccd, d, 1, 0]), [v(L.Wg.la(w), [ccd, 0, 1, d])],
       X.sel(X.le(X.ix(3), X.ix(1)), X.x(0), X.k(0.0))}),
     # A[g,h,τ,σ] = Σ_c q·k·exp(B_τ − B_σ), σ ≤ τ
     op(Es{[L.Dm.nc(m), h, cc, cc, hd], 16, 0, 0, v(L.Wg.a(w), [U32.mul(h, U32.mul(cc, cc)), U32.mul(cc, cc), cc, 1, 0]),
       [v(L.Wg.qh(w), [ccd, hd, d, 0, 1]), v(kh, [ccd, hd, 0, d, 1]),
        v(L.Wg.bc(w), [ccd, hd, d, 0, 1]), v(L.Wg.bc(w), [ccd, hd, 0, d, 1])],
       X.sel(X.le(X.ix(3), X.ix(2)), X.mul(X.mul(X.x(0), X.x(1)), X.exp(X.sub(X.x(2), X.x(3)))), X.k(0.0))}),
     # within the chunk: Σ_σ A v_σ
     op(Es{[L.Dm.nc(m), h, cc, hd, cc], 16, 0, 0, v(L.Wg.oi(w), [ccd, hd, d, 1, 0]),
       [v(L.Wg.a(w), [U32.mul(h, U32.mul(cc, cc)), U32.mul(cc, cc), cc, 0, 1]), v(vv, [U32.mul(cc, d3), hd, 0, 1, d3])],
       X.mul(X.x(0), X.x(1))}),
     # each chunk's own state: Σ_σ k_σ exp(B_last − B_σ) v_σ^T
     op(Es{[L.Dm.b(m), L.Dm.j(m), h, hd, hd, cc], 32, 0, 0,
       v(L.Wg.u(w), [x2, U32.mul(L.Dm.b(m), x2), hh2, hd, 1, 0]),
       [v(kh, [td, ccd, hd, 1, 0, d]), v(U32.add(L.Wg.bc(w), U32.mul(U32.sub(cc, 1), d)), [td, ccd, hd, 1, 0, 0]),
        v(L.Wg.bc(w), [td, ccd, hd, 1, 0, d]), v(vv, [U32.mul(t, d3), U32.mul(cc, d3), hd, 0, 1, d3])],
       X.mul(X.mul(X.x(0), X.exp(X.sub(X.x(1), X.x(2)))), X.x(3))}),
     P.zero(U32.mul(L.Dm.b(m), x2), L.Wg.sin(w))],
    gla.scan(U32.to_nat(U32.sub(L.Dm.j(m), 1)), m, w, 1),
    # across chunks: q_τ exp(B_τ) · S (the state entering the chunk)
    [op(Es{[L.Dm.b(m), L.Dm.j(m), cc, h, hd, hd], 32, 0, 0, v(L.Wg.oe(w), [td, ccd, d, hd, 1, 0]),
       [v(L.Wg.qh(w), [td, ccd, d, hd, 0, 1]), v(L.Wg.bc(w), [td, ccd, d, hd, 0, 1]),
        v(L.Wg.sin(w), [x2, U32.mul(L.Dm.b(m), x2), 0, hh2, 1, hd])],
       X.mul(X.mul(X.x(0), X.exp(X.x(1))), X.x(2))}),
     add2(nd, L.Wg.o(w), L.Wg.oi(w), L.Wg.oe(w))],
    tail(m, bp, x, xo, L.Wg.o(w), L.Wg.y1(w), L.Wg.xa(w), L.Wg.ss2(w), L.Wg.nrm2(w), L.Wg.gu(w), L.Wg.hh(w), L.Wg.y2(w))])

# Softmax attention with qk-norm and sinks ------------------------------------

def sm.qk(q: Bool, +n: U32, +h: U32, +hd: U32, +src: U32, +ld: U32, +w: U32, +sq: U32, +y: U32) -> List<&2, P.Op>:
  match q:
    case True{}:
      qkn(n, h, hd, src, ld, w, sq, y)
    case False{}:
      Nil{}

def sm.max(s: Bool, +m: L.Dm, +bp: L.BP, +w: L.Ws) -> List<&2, P.Op>:
  match s:
    case True{}:
      +ht = U32.mul(L.Dm.h(m), L.Dm.t(m))
      [P.ein(Es{[L.Dm.b(m), L.Dm.h(m), L.Dm.t(m)], 0, 0, 0, v(L.Ws.m(w), [ht, L.Dm.t(m), 1]),
         [v(L.Ws.m1(w), [ht, L.Dm.t(m), 1]), v(L.BP.sink(bp), [0, 1, 0])], X.max(X.x(0), X.x(1))}, False{})]
    case False{}:
      Nil{}

def sm.den(s: Bool, +m: L.Dm, +bp: L.BP, +w: L.Ws, +mo: U32) -> List<&2, P.Op>:
  match s:
    case True{}:
      +ht = U32.mul(L.Dm.h(m), L.Dm.t(m))
      [op(Es{[L.Dm.b(m), L.Dm.h(m), L.Dm.t(m)], 0, 0, 0, v(L.Ws.den(w), [ht, L.Dm.t(m), 1]),
         [v(L.Ws.se(w), [ht, L.Dm.t(m), 1]), v(L.BP.sink(bp), [0, 1, 0]), v(mo, [ht, L.Dm.t(m), 1])],
         X.add(X.x(0), X.exp(X.sub(X.x(1), X.x(2))))})]
    case False{}:
      Nil{}

def sm(+m: L.Dm, +bp: L.BP, +x: U32, +xo: U32, +w: L.Ws) -> List<&2, P.Op>:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +t = L.Dm.t(m)
  +b = L.Dm.b(m)
  +d3 = U32.mul(3, d)
  +q = L.Dm.qk(m)
  +sk = L.Dm.sinks(m)
  +qo = Bool.pick(U32, q, L.Ws.qa(w), L.Ws.qkv(w))
  +ko = Bool.pick(U32, q, L.Ws.ka(w), U32.add(L.Ws.qkv(w), d))
  +ld = Bool.pick(U32, q, d, d3)
  +mo = Bool.pick(U32, sk, L.Ws.m(w), L.Ws.m1(w))
  +deno = Bool.pick(U32, sk, L.Ws.den(w), L.Ws.se(w))
  +ht = U32.mul(h, t)
  +htt = U32.mul(ht, t)
  +tt = U32.mul(t, t)
  +sc = F32.div(1.0, F32.sqrt(f(hd)))
  +causal = X.le(X.ix(3), X.ix(2))
  List.concat(&2, P.Op, [
    norm(n, d, x, L.BP.ra(bp), L.Ws.ss(w), L.Ws.nrm(w)),
    [P.linear(n, d, d3, L.Ws.nrm(w), d, L.BP.wq(bp), L.Ws.qkv(w), d3)],
    sm.qk(q, n, h, hd, L.Ws.qkv(w), d3, L.BP.gq(bp), L.Ws.sq(w), L.Ws.qa(w)),
    sm.qk(q, n, h, hd, U32.add(L.Ws.qkv(w), d), d3, L.BP.gk(bp), L.Ws.sk(w), L.Ws.ka(w)),
    # q·k per head, t' ≤ t (scaled by 1/sqrt(hd) where it is used)
    [op(Es{[b, h, t, t, hd], 16, 0, 0, v(L.Ws.s(w), [htt, tt, t, 1, 0]),
       [v(qo, [U32.mul(t, ld), hd, ld, 0, 1]), v(ko, [U32.mul(t, ld), hd, 0, ld, 1])],
       X.sel(causal, X.mul(X.x(0), X.x(1)), X.k(0.0))}),
     # the row maximum: a constant of the softmax, so no gradient flows
     P.ein(Es{[b, h, t, t], 8, 1, 0, v(L.Ws.m1(w), [ht, t, 1, 0]), [v(L.Ws.s(w), [htt, tt, t, 1])],
       X.sel(causal, X.mul(X.k(sc), X.x(0)), X.k(F32.neg(X.inf())))}, False{})],
    sm.max(sk, m, bp, w),
    [op(Es{[b, h, t, t], 0, 0, 0, v(L.Ws.e(w), [htt, tt, t, 1]), [v(L.Ws.s(w), [htt, tt, t, 1]), v(mo, [ht, t, 1, 0])],
       X.sel(causal, X.exp(X.sub(X.mul(X.k(sc), X.x(0)), X.x(1))), X.k(0.0))}),
     op(Es{[b, h, t, t], 8, 0, 0, v(L.Ws.se(w), [ht, t, 1, 0]), [v(L.Ws.e(w), [htt, tt, t, 1])], X.x(0)})],
    sm.den(sk, m, bp, w, mo),
    [op(Es{[b, h, t, hd, t], 16, 0, 0, v(L.Ws.mix(w), [U32.mul(t, d), hd, d, 1, 0]),
       [v(L.Ws.e(w), [htt, tt, t, 0, 1]), v(U32.add(L.Ws.qkv(w), U32.mul(2, d)), [U32.mul(t, d3), hd, 0, 1, d3])],
       X.mul(X.x(0), X.x(1))}),
     op(Es{[b, h, t, hd], 0, 0, 0, v(L.Ws.att(w), [U32.mul(t, d), hd, d, 1]),
       [v(L.Ws.mix(w), [U32.mul(t, d), hd, d, 1]), v(deno, [ht, t, 1, 0])],
       X.mul(X.div(X.k(1.0), X.x(1)), X.x(0))})],
    tail(m, bp, x, xo, L.Ws.att(w), L.Ws.y1(w), L.Ws.xa(w), L.Ws.ss2(w), L.Ws.nrm2(w), L.Ws.gu(w), L.Ws.hh(w), L.Ws.y2(w))])

# Embedding and head -------------------------------------------------------

# x0[n, :] = E[token n, :] (a gather: its transpose scatters into dE)
def embed(+m: L.Dm, +ly: L.Lay) -> List<&2, P.Op>:
  [op(Es{[L.Dm.n(m), L.Dm.d(m)], 0, 0, 0, v(L.Lay.x0(ly), [L.Dm.d(m), 1]),
    [View{0, [0, 1], IxAt{L.Lay.tin(ly), [1, 0], L.Dm.d(m)}}], X.x(0)})]

def head.fin(+m: L.Dm, +ly: L.Lay, +hd: L.Hd) -> List<&2, P.Op>:
  norm(L.Dm.n(m), L.Dm.d(m), L.Lay.x(ly, m, L.Dm.l(m)), L.Lay.fin(ly), L.Hd.ssf(hd), L.Hd.fin(hd))

# rows r0 .. r0+r of the tied head: logits, their max, Σ exp, and each
# row's loss lse − logit[target]
def head.chunk(+m: L.Dm, +ly: L.Lay, +hd: L.Hd, +r0: U32) -> List<&2, P.Op>:
  +r = L.Dm.r(m)
  +d = L.Dm.d(m)
  +vo = L.Dm.v(m)
  [P.linear(r, d, vo, U32.add(L.Hd.fin(hd), U32.mul(r0, d)), d, 0, L.Hd.lg(hd), vo),
   P.ein(Es{[r, vo], 2, 1, 0, v(L.Hd.hm(hd), [1, 0]), [v(L.Hd.lg(hd), [vo, 1])], X.x(0)}, False{}),
   op(Es{[r, vo], 2, 0, 0, v(L.Hd.hse(hd), [1, 0]), [v(L.Hd.lg(hd), [vo, 1]), v(L.Hd.hm(hd), [1, 0])],
     X.exp(X.sub(X.x(0), X.x(1)))}),
   op(Es{[r], 0, 0, 0, v(U32.add(L.Hd.loss(hd), r0), [1]),
     [v(L.Hd.hm(hd), [1]), v(L.Hd.hse(hd), [1]), View{L.Hd.lg(hd), [vo], IxAt{U32.add(L.Lay.ttg(ly), r0), [1], 1}},
      v(U32.add(L.Lay.tw(ly), r0), [1])],
     X.mul(X.sub(X.add(X.x(0), X.log(X.x(1))), X.x(2)), X.x(3))})]

def head.chunks(k: Nat, +m: L.Dm, +ly: L.Lay, +hd: L.Hd, +r0: U32) -> List<&2, List<&2, P.Op>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      head.chunk(m, ly, hd, r0) <> head.chunks(p, m, ly, hd, U32.add(r0, L.Dm.r(m)))

# the mean loss over the micro-batch's predictions (its weights' sum)
def head.loss(+m: L.Dm, +ly: L.Lay, +hd: L.Hd) -> List<&2, P.Op>:
  [op(Es{[L.Dm.n(m)], 1, 0, 0, v(L.Hd.ltot(hd), [0]), [v(L.Hd.loss(hd), [1])], X.x(0)}),
   P.ein(Es{[L.Dm.n(m)], 1, 0, 0, v(L.Hd.wsum(hd), [0]), [v(L.Lay.tw(ly), [1])], X.x(0)}, False{}),
   P.map1(1, L.Lay.lmean(ly), [L.Hd.ltot(hd), L.Hd.wsum(hd)], X.div(X.x(0), X.x(1)), True{})]

# each window's summed loss (evaluate)
def head.windows(+m: L.Dm, +hd: L.Hd) -> List<&2, P.Op>:
  [P.ein(Es{[L.Dm.b(m), L.Dm.t(m)], 2, 0, 0, v(L.Hd.wl(hd), [1, 0]), [v(L.Hd.loss(hd), [L.Dm.t(m), 1])], X.x(0)}, False{})]

def layer.k(g: Bool, +m: L.Dm, +ly: L.Lay, +bp: L.BP, +i: U32) -> List<&2, P.Op>:
  match g:
    case True{}:
      gla(m, bp, L.Lay.x(ly, m, i), L.Lay.x(ly, m, U32.inc(i)), L.Wg.at(m, L.Lay.ws(ly)))
    case False{}:
      sm(m, bp, L.Lay.x(ly, m, i), L.Lay.x(ly, m, U32.inc(i)), L.Ws.at(m, L.Lay.ws(ly)))

# layer i's ops, from x_i to x_{i+1}
def layer(+m: L.Dm, +ly: L.Lay, +bp: L.BP, +i: U32) -> List<&2, P.Op>:
  layer.k(L.BP.gla(bp), m, ly, bp, i)

def layers(bs: List<&2, L.BP>, +m: L.Dm, +ly: L.Lay, +i: U32) -> List<&2, List<&2, P.Op>>:
  match bs:
    case Nil{}:
      Nil{}
    case bp <> t:
      layer(m, ly, bp, i) <> layers(t, m, ly, U32.inc(i))
