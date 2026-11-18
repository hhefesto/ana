import Base
import ../Bulk.bend as B
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

def v(off: U32, st: List<&2, U32>) -> B.View:
  P.view(off, st)

def op(+es: B.Es) -> P.Op:
  P.ein(es, True{})

# rms_norm: y = (x · 1/sqrt(Σx²/d + 1e-5)) · g, rows of d
def norm(+n: U32, +d: U32, +x: U32, +g: U32, +ss: U32, +y: U32) -> List<&2, P.Op>:
  [op(B.Es{[n, d], 2, 0, 0, v(ss, [1, 0]), [v(x, [d, 1])], X.mul(X.x(0), X.x(0))}),
   op(B.Es{[n, d], 0, 0, 0, v(y, [d, 1]), [v(x, [d, 1]), v(ss, [1, 0]), v(g, [0, 1])],
     X.mul(X.mul(X.x(0), X.rms_scale(X.x(1), f(d))), X.x(2))})]

# per-head L2 normalization (l2_head) of rows [n × h·hd] with stride ld
def l2(+n: U32, +h: U32, +hd: U32, +src: U32, +ld: U32, +sq: U32, +y: U32) -> List<&2, P.Op>:
  [op(B.Es{[n, h, hd], 4, 0, 0, v(sq, [h, 1, 0]), [v(src, [ld, hd, 1])], X.mul(X.x(0), X.x(0))}),
   op(B.Es{[n, h, hd], 0, 0, 0, v(y, [U32.mul(h, hd), hd, 1]), [v(src, [ld, hd, 1]), v(sq, [h, 1, 0])],
     X.div(X.x(0), X.sqrt(X.add(X.k(1.0e-6), X.x(1))))})]

# per-head RMSNorm with gains 1 + w (qk_head)
def qkn(+n: U32, +h: U32, +hd: U32, +src: U32, +ld: U32, +w: U32, +sq: U32, +y: U32) -> List<&2, P.Op>:
  [op(B.Es{[n, h, hd], 4, 0, 0, v(sq, [h, 1, 0]), [v(src, [ld, hd, 1])], X.mul(X.x(0), X.x(0))}),
   op(B.Es{[n, h, hd], 0, 0, 0, v(y, [U32.mul(h, hd), hd, 1]), [v(src, [ld, hd, 1]), v(sq, [h, 1, 0]), v(w, [0, 0, 1])],
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
     op(B.Es{[n, ff], 0, 0, 0, v(hh, [ff, 1]), [v(gu, [U32.mul(2, ff), 1]), v(U32.add(gu, ff), [U32.mul(2, ff), 1])],
       X.mul(X.silu(X.x(0)), X.x(1))}),
     P.linear(n, ff, d, hh, ff, L.BP.wd(bp), y2, d), add2(nd, xo, xa, y2)]])

# Per-head products: cuBLAS batches over one index with one stride, so the
# other batch index (the head) unrolls, one batched product per head.

# GLA within the chunk: oi[g,τ,h,:] = Σ_σ A[g,h,τ,σ] v[g,σ,h,:]
def gla.mix(n: Nat, +hh: U32, +m: L.Dm, +w: L.Wg) -> List<&2, P.Op>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +cc = L.Dm.cc(m)
      +hd = L.Dm.hd(m)
      +d = L.Dm.d(m)
      +d3 = U32.mul(3, d)
      +c2 = U32.mul(cc, cc)
      P.Mm{0, 0, cc, hd, cc, L.Dm.nc(m), 1.0,
        U32.add(L.Wg.a(w), U32.mul(hh, c2)), cc, U32.mul(L.Dm.h(m), c2),
        U32.add(L.Wg.qkv(w), U32.add(U32.mul(2, d), U32.mul(hh, hd))), d3, U32.mul(cc, d3), 0.0,
        U32.add(L.Wg.oi(w), U32.mul(hh, hd)), d, U32.mul(cc, d)} <> gla.mix(p, U32.inc(hh), m, w)

# softmax scores s[w,h,t,t'] = q[w,t,h,:]·k[w,t',h,:]
def sm.scores(n: Nat, +hh: U32, +m: L.Dm, +w: L.Ws, +qo: U32, +ko: U32, +ld: U32) -> List<&2, P.Op>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +t = L.Dm.t(m)
      +hd = L.Dm.hd(m)
      +tt = U32.mul(t, t)
      P.Mm{0, 1, t, t, hd, L.Dm.b(m), 1.0,
        U32.add(qo, U32.mul(hh, hd)), ld, U32.mul(t, ld), U32.add(ko, U32.mul(hh, hd)), ld, U32.mul(t, ld), 0.0,
        U32.add(L.Ws.s(w), U32.mul(hh, tt)), t, U32.mul(L.Dm.h(m), tt)} <> sm.scores(p, U32.inc(hh), m, w, qo, ko, ld)

# softmax values mix[w,t,h,:] = Σ_t' e[w,h,t,t'] v[w,t',h,:]
def sm.mix(n: Nat, +hh: U32, +m: L.Dm, +w: L.Ws) -> List<&2, P.Op>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      +t = L.Dm.t(m)
      +hd = L.Dm.hd(m)
      +d = L.Dm.d(m)
      +d3 = U32.mul(3, d)
      +tt = U32.mul(t, t)
      P.Mm{0, 0, t, hd, t, L.Dm.b(m), 1.0,
        U32.add(L.Ws.e(w), U32.mul(hh, tt)), t, U32.mul(L.Dm.h(m), tt),
        U32.add(L.Ws.qkv(w), U32.add(U32.mul(2, d), U32.mul(hh, hd))), d3, U32.mul(t, d3), 0.0,
        U32.add(L.Ws.mix(w), U32.mul(hh, hd)), d, U32.mul(t, d)} <> sm.mix(p, U32.inc(hh), m, w)

def gla.gate(g: Bool, +m: L.Dm, +bp: L.BP, +w: L.Wg) -> List<&2, P.Op>:
  match g:
    case True{}:
      +n = L.Dm.n(m)
      +d = L.Dm.d(m)
      [op(B.Es{[n, d], 0, 0, 0, v(L.Wg.la(w), [d, 1]), [v(L.Wg.z(w), [d, 1]), v(L.BP.lam(bp), [0, 1])],
         X.rglru_log_gate(X.x(0), X.x(1))}),
       op(B.Es{[n, d], 0, 0, 0, v(L.Wg.kh(w), [d, 1]), [v(L.Wg.kh0(w), [d, 1]), v(L.Wg.la(w), [d, 1])],
         X.mul(X.x(0), X.rglru_write_scale(X.x(1)))})]
    case False{}:
      +n = L.Dm.n(m)
      +d = L.Dm.d(m)
      [op(B.Es{[n, d], 0, 0, 0, v(L.Wg.la(w), [d, 1]), [v(L.Wg.z(w), [d, 1])], X.log_sigmoid(X.x(0))})]

# the key after the gate: khat (RG-LRU's write-scaled key) or k^ itself
def gla.key(g: Bool, +w: L.Wg) -> U32:
  Bool.pick(U32, g, L.Wg.kh(w), L.Wg.kh0(w))

# GLA's products batch over every head and chunk at once (2026-11-18): the
# values v (a copy, vh), the scores A, the decayed key KE and query QE, the
# chunk states u (each chunk's own) and sin (the state entering the chunk),
# and the two halves of the output oi and oe all lie head-major, head h's
# block of chunk g = b·J + jj at (h·NC + g)·(its size), so one strided
# batched product covers the H·NC blocks (run 9's profile: 4,700 small
# products a step as one per head, 101 ms). Before that day u and sin lay
# chunk-major and the chunk state and the read across chunks were einsums
# with exp inside the sum, 64 and 16 times per value (40 of a micro-batch's
# 64 G terms), and the state across chunks one einsum a chunk.

# the values, head-major: vh[h, r, :] = v[r, h, :]
def gla.vh(+m: L.Dm, +w: L.Wg) -> P.Op:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +hd = L.Dm.hd(m)
  op(B.Es{[n, L.Dm.h(m), hd], 0, 0, 0, v(L.Wg.vh(w), [hd, U32.mul(n, hd), 1]),
    [v(U32.add(L.Wg.qkv(w), U32.mul(2, d)), [U32.mul(3, d), hd, 1])], X.x(0)})

# within the chunk, oi[h, g·cc+τ, :] = Σ_σ A[h, g, τ, σ] vh[h, g·cc+σ, :]
def gla.mixh(+m: L.Dm, +w: L.Wg) -> P.Op:
  +cc = L.Dm.cc(m)
  +hd = L.Dm.hd(m)
  P.Mm{0, 0, cc, hd, cc, U32.mul(L.Dm.h(m), L.Dm.nc(m)), 1.0,
    L.Wg.a(w), cc, U32.mul(cc, cc), L.Wg.vh(w), hd, U32.mul(cc, hd), 0.0,
    L.Wg.oi(w), hd, U32.mul(cc, hd)}

# each chunk's own state: u[h, g, :, :] = KE[h, chunk g]^T vh[h, chunk g]
def gla.state(+m: L.Dm, +w: L.Wg) -> P.Op:
  +cc = L.Dm.cc(m)
  +hd = L.Dm.hd(m)
  P.Mm{1, 0, hd, hd, cc, U32.mul(L.Dm.h(m), L.Dm.nc(m)), 1.0,
    L.Wg.ke(w), hd, U32.mul(cc, hd), L.Wg.vh(w), hd, U32.mul(cc, hd), 0.0,
    L.Wg.u(w), hd, U32.mul(hd, hd)}

# the read across chunks: oe[h, chunk g] = QE[h, chunk g] sin[h, g]
def gla.ext(+m: L.Dm, +w: L.Wg) -> P.Op:
  +cc = L.Dm.cc(m)
  +hd = L.Dm.hd(m)
  P.Mm{0, 0, cc, hd, hd, U32.mul(L.Dm.h(m), L.Dm.nc(m)), 1.0,
    L.Wg.qe(w), hd, U32.mul(cc, hd), L.Wg.sin(w), hd, U32.mul(hd, hd), 0.0,
    L.Wg.oe(w), hd, U32.mul(cc, hd)}

# the state entering chunk jj+1 of every window, from the one entering jj:
# S_{jj+1} = exp(B_last of jj) ⊙ S_jj + u_jj, for jj from 0 to J-2, one
# Seq along jj (it was J-1 einsums, one a chunk); the state is carried in
# input 1, so the backward runs the adjoint recurrence the other way; a
# window of one chunk has no state to carry, and no op (as before)
def gla.scan.op(+m: L.Dm, +w: L.Wg) -> P.Op:
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +d = L.Dm.d(m)
  +cc = L.Dm.cc(m)
  +hh2 = U32.mul(hd, hd)
  +st = {[hh2, U32.mul(L.Dm.j(m), hh2), U32.mul(L.Dm.nc(m), hh2), hd, 1] : List<&2, U32>}
  P.seq(B.Es{[U32.sub(L.Dm.j(m), 1), L.Dm.b(m), h, hd, hd], 0, 0, 0, v(U32.add(L.Wg.sin(w), hh2), st),
    [v(U32.add(L.Wg.bc(w), U32.mul(U32.sub(cc, 1), d)), [U32.mul(cc, d), U32.mul(L.Dm.t(m), d), hd, 1, 0]),
     v(L.Wg.sin(w), st),
     v(L.Wg.u(w), st)],
    X.add(X.mul(X.exp(X.x(0)), X.x(1)), X.x(2))}, 0, 0, 1, True{})

def gla.scan(+m: L.Dm, +w: L.Wg) -> List<&2, P.Op>:
  Bool.pick(List<&2, P.Op>, U32.is_lt(1, L.Dm.j(m)), [gla.scan.op(m, w)], Nil{})

# B_τ = B_{τ-1} + la_τ for τ from 1 to cc-1 in every chunk, one Seq along τ
# (it was an einsum over σ ≤ τ, cc terms a cell, the zeros past τ added:
# the same sums in the same order, the -0.0 aside, which only exp reads);
# B carried in input 0, so its transpose is the suffix sum of the tangents
def gla.cum(+m: L.Dm, +w: L.Wg) -> List<&2, P.Op>:
  +cc = L.Dm.cc(m)
  +d = L.Dm.d(m)
  +ccd = U32.mul(cc, d)
  Bool.pick(List<&2, P.Op>, U32.is_lt(1, cc),
    [P.seq(B.Es{[U32.sub(cc, 1), L.Dm.nc(m), d], 0, 0, 0, v(U32.add(L.Wg.bc(w), d), [d, ccd, 1]),
      [v(L.Wg.bc(w), [d, ccd, 1]), v(U32.add(L.Wg.la(w), d), [d, ccd, 1])], X.add(X.x(0), X.x(1))}, 0, 0, 0, True{})],
    Nil{})

def gla(+m: L.Dm, +bp: L.BP, +x: U32, +xo: U32, +w: L.Wg) -> List<&2, P.Op>:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +cc = L.Dm.cc(m)
  +d3 = U32.mul(3, d)
  +nd = U32.mul(n, d)
  +ccd = U32.mul(cc, d)
  +nhd = U32.mul(n, hd)
  +chd = U32.mul(cc, hd)
  +hh2 = U32.mul(hd, hd)
  +kh = gla.key(L.Dm.rglru(m), w)
  List.concat(&2, P.Op, [
    norm(n, d, x, L.BP.ra(bp), L.Wg.ss(w), L.Wg.nrm(w)),
    [P.linear(n, d, d3, L.Wg.nrm(w), d, L.BP.wq(bp), L.Wg.qkv(w), d3),
     P.linear(n, d, d, L.Wg.nrm(w), d, L.BP.wa(bp), L.Wg.z(w), d)],
    l2(n, h, hd, L.Wg.qkv(w), d3, L.Wg.sq(w), L.Wg.qh(w)),
    l2(n, h, hd, U32.add(L.Wg.qkv(w), d), d3, L.Wg.sk(w), L.Wg.kh0(w)),
    gla.gate(L.Dm.rglru(m), m, bp, w),
    # B: the running sum of log α within each chunk, B_0 = 0 + la_0, then
    # one Seq along τ (gla.cum)
    [op(B.Es{[L.Dm.nc(m), d], 0, 0, 0, v(L.Wg.bc(w), [ccd, 1]), [v(L.Wg.la(w), [ccd, 1])], X.add(X.k(0.0), X.x(0))})],
    gla.cum(m, w),
    # A[h,g,τ,σ] = Σ_c q·k·exp(B_τ − B_σ), σ ≤ τ (head-major)
    [op(B.Es{[L.Dm.nc(m), h, cc, cc, hd], 16, 0, 0, v(L.Wg.a(w), [U32.mul(cc, cc), U32.mul(L.Dm.nc(m), U32.mul(cc, cc)), cc, 1, 0]),
       [v(L.Wg.qh(w), [ccd, hd, d, 0, 1]), v(kh, [ccd, hd, 0, d, 1]),
        v(L.Wg.bc(w), [ccd, hd, d, 0, 1]), v(L.Wg.bc(w), [ccd, hd, 0, d, 1])],
       X.sel(X.le(X.ix(3), X.ix(2)), X.mul(X.mul(X.x(0), X.x(1)), X.exp(X.sub(X.x(2), X.x(3)))), X.k(0.0))}),
     # each chunk's own state is Σ_σ k_σ exp(B_last − B_σ) v_σ^T: the key
     # decayed to the chunk's end, KE (each term's first two factors, in
     # the order the einsum took them), head-major, then one product
     op(B.Es{[L.Dm.nc(m), cc, h, hd], 0, 0, 0, v(L.Wg.ke(w), [chd, hd, nhd, 1]),
       [v(kh, [ccd, d, hd, 1]), v(U32.add(L.Wg.bc(w), U32.mul(U32.sub(cc, 1), d)), [ccd, 0, hd, 1]), v(L.Wg.bc(w), [ccd, d, hd, 1])],
       X.mul(X.x(0), X.exp(X.sub(X.x(1), X.x(2))))}),
     # the read across chunks is q_τ exp(B_τ) · S: its query QE, head-major,
     # then one product
     op(B.Es{[n, h, hd], 0, 0, 0, v(L.Wg.qe(w), [hd, nhd, 1]), [v(L.Wg.qh(w), [d, hd, 1]), v(L.Wg.bc(w), [d, hd, 1])],
       X.mul(X.x(0), X.exp(X.x(1)))}),
     # the state entering each window's first chunk: 0
     P.ein(B.Es{[h, L.Dm.b(m), hh2], 0, 0, 0, v(L.Wg.sin(w), [U32.mul(L.Dm.nc(m), hh2), U32.mul(L.Dm.j(m), hh2), 1]), Nil{}, X.k(0.0)}, False{}),
     gla.vh(m, w),
     # within the chunk: Σ_σ A v_σ
     gla.mixh(m, w),
     gla.state(m, w)],
    gla.scan(m, w),
    [gla.ext(m, w),
     # the output, row-major again: o = oi + oe
     op(B.Es{[n, h, hd], 0, 0, 0, v(L.Wg.o(w), [d, hd, 1]), [v(L.Wg.oi(w), [hd, nhd, 1]), v(L.Wg.oe(w), [hd, nhd, 1])],
       X.add(X.x(0), X.x(1))})],
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
      [P.ein(B.Es{[L.Dm.b(m), L.Dm.h(m), L.Dm.t(m)], 0, 0, 0, v(L.Ws.m(w), [ht, L.Dm.t(m), 1]),
         [v(L.Ws.m1(w), [ht, L.Dm.t(m), 1]), v(L.BP.sink(bp), [0, 1, 0])], X.max(X.x(0), X.x(1))}, False{})]
    case False{}:
      Nil{}

def sm.den(s: Bool, +m: L.Dm, +bp: L.BP, +w: L.Ws, +mo: U32) -> List<&2, P.Op>:
  match s:
    case True{}:
      +ht = U32.mul(L.Dm.h(m), L.Dm.t(m))
      [op(B.Es{[L.Dm.b(m), L.Dm.h(m), L.Dm.t(m)], 0, 0, 0, v(L.Ws.den(w), [ht, L.Dm.t(m), 1]),
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
    # q·k per head, every (t, t'), scaled by 1/sqrt(hd) where it is used:
    # every use selects t' ≤ t (and its derivative is 0 elsewhere), so the
    # entries above the diagonal carry no meaning
    sm.scores(U32.to_nat(h), 0, m, w, qo, ko, ld),
    [# the row maximum: a constant of the softmax, so no gradient flows
     P.ein(B.Es{[b, h, t, t], 8, 1, 0, v(L.Ws.m1(w), [ht, t, 1, 0]), [v(L.Ws.s(w), [htt, tt, t, 1])],
       X.sel(causal, X.mul(X.k(sc), X.x(0)), X.k(F32.neg(X.inf())))}, False{})],
    sm.max(sk, m, bp, w),
    [op(B.Es{[b, h, t, t], 0, 0, 0, v(L.Ws.e(w), [htt, tt, t, 1]), [v(L.Ws.s(w), [htt, tt, t, 1]), v(mo, [ht, t, 1, 0])],
       X.sel(causal, X.exp(X.sub(X.mul(X.k(sc), X.x(0)), X.x(1))), X.k(0.0))}),
     op(B.Es{[b, h, t, t], 8, 0, 0, v(L.Ws.se(w), [ht, t, 1, 0]), [v(L.Ws.e(w), [htt, tt, t, 1])], X.x(0)})],
    sm.den(sk, m, bp, w, mo),
    sm.mix(U32.to_nat(h), 0, m, w),
    [op(B.Es{[b, h, t, hd], 0, 0, 0, v(L.Ws.att(w), [U32.mul(t, d), hd, d, 1]),
       [v(L.Ws.mix(w), [U32.mul(t, d), hd, d, 1]), v(deno, [ht, t, 1, 0])],
       X.mul(X.div(X.k(1.0), X.x(1)), X.x(0))})],
    tail(m, bp, x, xo, L.Ws.att(w), L.Ws.y1(w), L.Ws.xa(w), L.Ws.ss2(w), L.Ws.nrm2(w), L.Ws.gu(w), L.Ws.hh(w), L.Ws.y2(w))])

# Embedding and head -------------------------------------------------------

# x0[n, :] = E[token n, :] (a gather: its transpose scatters into dE)
def embed(+m: L.Dm, +ly: L.Lay) -> List<&2, P.Op>:
  [op(B.Es{[L.Dm.n(m), L.Dm.d(m)], 0, 0, 0, v(L.Lay.x0(ly), [L.Dm.d(m), 1]),
    [B.View{0, [0, 1], B.IxAt{L.Lay.tin(ly), [1, 0], L.Dm.d(m)}}], X.x(0)})]

def head.fin(+m: L.Dm, +ly: L.Lay, +hd: L.Hd) -> List<&2, P.Op>:
  norm(L.Dm.n(m), L.Dm.d(m), L.Lay.x(ly, m, L.Dm.l(m)), L.Lay.fin(ly), L.Hd.ssf(hd), L.Hd.fin(hd))

# rows r0 .. r0+r of the tied head: logits, their max, Σ exp, and each
# row's loss lse − logit[target]
def head.chunk(+m: L.Dm, +ly: L.Lay, +hd: L.Hd, +r0: U32) -> List<&2, P.Op>:
  +r = L.Dm.r(m)
  +d = L.Dm.d(m)
  +vo = L.Dm.v(m)
  [P.linear(r, d, vo, U32.add(L.Hd.fin(hd), U32.mul(r0, d)), d, 0, L.Hd.lg(hd), vo),
   P.ein(B.Es{[r, vo], 2, 1, 0, v(L.Hd.hm(hd), [1, 0]), [v(L.Hd.lg(hd), [vo, 1])], X.x(0)}, False{}),
   op(B.Es{[r, vo], 2, 0, 0, v(L.Hd.hse(hd), [1, 0]), [v(L.Hd.lg(hd), [vo, 1]), v(L.Hd.hm(hd), [1, 0])],
     X.exp(X.sub(X.x(0), X.x(1)))}),
   op(B.Es{[r], 0, 0, 0, v(U32.add(L.Hd.loss(hd), r0), [1]),
     [v(L.Hd.hm(hd), [1]), v(L.Hd.hse(hd), [1]), B.View{L.Hd.lg(hd), [vo], B.IxAt{U32.add(L.Lay.ttg(ly), r0), [1], 1}},
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
  [op(B.Es{[L.Dm.n(m)], 1, 0, 0, v(L.Hd.ltot(hd), [0]), [v(L.Hd.loss(hd), [1])], X.x(0)}),
   P.ein(B.Es{[L.Dm.n(m)], 1, 0, 0, v(L.Hd.wsum(hd), [0]), [v(L.Lay.tw(ly), [1])], X.x(0)}, False{}),
   P.map1(1, L.Lay.lmean(ly), [L.Hd.ltot(hd), L.Hd.wsum(hd)], X.div(X.x(0), X.x(1)), True{})]

# each window's summed loss (evaluate)
def head.windows(+m: L.Dm, +hd: L.Hd) -> List<&2, P.Op>:
  [P.ein(B.Es{[L.Dm.b(m), L.Dm.t(m)], 2, 0, 0, v(L.Hd.wl(hd), [1, 0]), [v(L.Hd.loss(hd), [L.Dm.t(m), 1])], X.x(0)}, False{})]

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
