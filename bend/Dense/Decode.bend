import Base
import ../Config.bend as C
import ../Checkpoint.bend as K
import ./Ex.bend as X
import ./Op.bend as P
import ./Layout.bend as L
import ./Model.bend as M
import ./Ckpt.bend as Dk
import ./Io.bend as Io

# The decode step on the dense store: Model.bend's `decode` (the meaning:
# one token at a position, the layers' recurrent states in, the logits and
# the new states out), refined to bulk ops over one Array<F32> the way the
# dense trainer refines the training forward. tests/decode-dense.bend holds
# it to Model.bend's decode, logit for logit, past the softmax ring's wrap.
#
# The store: the parameters [0, P) exactly where the trainer keeps them
# (Layout.bend's namedLayout order, so an FTC2 checkpoint's parameter vector
# loads verbatim), then each layer's state (GLA: its h·hd·hd matrix S;
# softmax: its K and V rings of ctx slots of d), then one token's workspace
# (the trainer's GLA workspace at n = 1, shared by every layer, and the
# cells below), the head's cells, the logits and greedy's two pick cells;
# then a chunk's workspace and cells, the same at n = C.
#
# Everything that depends on the position goes through cells: the
# embedding gathers the row the token cell names, the K/V writes scatter
# into the slot the slot cell names, and attention masks slots past the
# live one. So the programs are built once and every token reuses them.
# Slots never written hold 0, so a masked slot adds exactly -inf to a max
# and 0 to a sum, as an empty slot (MZ) does in Model.bend's sm.attend.
#
# Prefill reads a prompt C tokens at a time (`dd.feeds`), through programs
# the same definitions build at n = C instead of n = 1. What acts on a
# token alone (the norms, every projection, the gates, the MLP) runs on the
# C rows at once, the projections as matrix products of m = C (a gemm sums
# each output in q order, so a row's bits do not depend on m). The
# recurrence runs token by token, in order, inside the layer: GLA's
# S' = αS + k̂vᵀ and its readout, and softmax's ring writes, the n = 1
# step's own ops pointed at row i and token i's cells. Softmax's attention
# runs for every row at once while the chunk stays before the ring's wrap
# (its writes then overwrite nothing a row reads, and each row masks the
# slots of the rows after it), else token by token after its write. So a
# chunk leaves the store as its tokens through `dd.feed` do, bit for bit
# (tests/prefill-dense.bend holds it). A chunk may hold fewer than C
# tokens: the per-token stages run for its tokens only, the rest of the C
# rows compute what nothing reads (a remainder under dd.chunk.min goes
# through `dd.feed` instead).
#
# Every def is prefixed `dd.` (one namespace across a program's imports).

# A layer's program in stages: `pre` on every row at once; `toks`, token
# i's part of the recurrence (the runtime runs the first r, in order);
# `mid` on every row after them (softmax's attention, before the wrap);
# `wtoks`, token i's whole recurrence (softmax: its write and attention);
# `post` on every row at once. The one-token step is pre, wtoks, post.
type DdLy is Data:
  DdLy{pre: List<&2, P.Op>, toks: List<&2, List<&2, P.Op>>, mid: List<&2, P.Op>, wtoks: List<&2, List<&2, P.Op>>,
       post: List<&2, P.Op>}

# A chunk's program: its size n, its cells (n tokens, slots, live slots,
# and the last token's row), the embedding, the layers, and the copy of
# the last token's residual row to the step's (where `head` reads it)
type DdCh is Data:
  DdCh{n: U32, tok: U32, slot: U32, npos: U32, last: U32, embed: List<&2, P.Op>, lys: List<&2, DdLy>, copy: List<&2, P.Op>}

type Dd is Data:
  Dd{c: C.Config, p: U32, st0: U32, stn: U32, tok: U32, slot: U32, npos: U32, lg: U32, v: U32, ctx: U32,
     depth: Nat, feed: List<&2, P.Op>, head: List<&2, P.Op>, top: U32, pick: List<&2, P.Op>, ch: DdCh}

def dd.c(+d: Dd) -> C.Config:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h, tp, pk, ch}:
      c

def dd.p(+d: Dd) -> U32:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h, tp, pk, ch}:
      p

def dd.st0(+d: Dd) -> U32:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h, tp, pk, ch}:
      a

def dd.stn(+d: Dd) -> U32:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h, tp, pk, ch}:
      b

def dd.depth(+d: Dd) -> Nat:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h, tp, pk, ch}:
      dp

def dd.vocab(+d: Dd) -> U32:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h, tp, pk, ch}:
      v

def dd.ch(+d: Dd) -> DdCh:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h, tp, pk, ch}:
      ch

def dd.ch.n(+r: DdCh) -> U32:
  match r:
    case DdCh{n, tok, slot, npos, last, em, ls, cp}:
      n

# the chunk size C (a prompt goes through `dd.feeds` C tokens at a time)
def dd.cn(+d: Dd) -> Nat:
  U32.to_nat(dd.ch.n(dd.ch(d)))

# Layout ----------------------------------------------------------------------

def dd.v(off: U32, st: List<&2, U32>) -> View:
  P.view(off, st)

def dd.ein(+es: Es) -> P.Op:
  P.ein(es, False{})

# n tokens at a time (n = 1: the step; n = C: a chunk), the trainer's
# shapes otherwise
def dd.dm.n(+c: C.Config, +n: U32) -> L.Dm:
  +d = L.u(C.Config.d(c))
  +h = L.u(C.Config.heads(c))
  L.Dm{n, L.u(C.Config.ctx(c)), d, L.u(C.Config.f(c)), h, U32.div(d, h), L.u(C.Config.vocab(c)), L.u(C.Config.layers(c)),
       1, 1, 1, 1, 1, C.Config.rglru(c), C.Config.qk(c), C.Config.sinks(c)}

def dd.dm(+c: C.Config) -> L.Dm:
  dd.dm.n(c, 1)

# a layer's state size: S per GLA layer, K and V rings per softmax layer
def dd.st.size(+bp: L.BP, +m: L.Dm) -> U32:
  Bool.pick(U32, L.BP.gla(bp), U32.mul(L.Dm.h(m), U32.mul(L.Dm.hd(m), L.Dm.hd(m))), U32.mul(2, U32.mul(L.Dm.t(m), L.Dm.d(m))))

def dd.st.end(bs: List<&2, L.BP>, +m: L.Dm, +o: U32) -> U32:
  match bs:
    case Nil{}:
      o
    case +bp <> t:
      dd.st.end(t, m, U32.add(o, dd.st.size(bp, m)))

# The cells n tokens need beyond the trainer's GLA workspace (Wg at n):
# softmax's scores, maxima, exponentials and sums per row, the gates'
# alpha, the residual rows, and the tokens' cells (token, ring slot, last
# live slot; the last token's row)
type Dx is Data:
  Dx{al: U32, s: U32, m1: U32, mm: U32, e: U32, se: U32, den: U32, x: U32, tok: U32, slot: U32, npos: U32, last: U32, end: U32}

def dd.dx(+m: L.Dm, +o: U32) -> Dx:
  +n = L.Dm.n(m)
  +nd = U32.mul(n, L.Dm.d(m))
  +nh = U32.mul(n, L.Dm.h(m))
  +nhc = U32.mul(nh, L.Dm.t(m))
  +al = o
  +s = U32.add(al, nd)
  +m1 = U32.add(s, nhc)
  +mm = U32.add(m1, nh)
  +e = U32.add(mm, nh)
  +se = U32.add(e, nhc)
  +den = U32.add(se, nh)
  +x = U32.add(den, nh)
  +tok = U32.add(x, nd)
  +slot = U32.add(tok, n)
  +npos = U32.add(slot, n)
  +last = U32.add(npos, n)
  Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, U32.inc(last)}

def dd.dx.al(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      al

def dd.dx.s(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      s

def dd.dx.m1(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      m1

def dd.dx.mm(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      mm

def dd.dx.e(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      e

def dd.dx.se(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      se

def dd.dx.den(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      den

def dd.dx.x(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      x

def dd.dx.tok(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      tok

def dd.dx.slot(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      slot

def dd.dx.npos(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      npos

def dd.dx.last(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      last

def dd.dx.end(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, tok, slot, npos, last, end}:
      end

# The programs ----------------------------------------------------------------
#
# Each is built for m's n token rows; row i reads its own rows and token
# i's cells (tok + i, slot + i, npos + i).

# GLA (Model.bend block.gla, gla.gate, gla.state, gla.out): alpha and the
# key from the gate (RG-LRU: exp of the log gate, the write-scaled key;
# else sigmoid(z) and k^ itself), every row
def dd.gate(g: Bool, +m: L.Dm, +bp: L.BP, +w: L.Wg, +al: U32) -> List<&2, P.Op>:
  match g:
    case True{}:
      List.append(&2, P.Op, M.gla.gate(True{}, m, bp, w), [P.map1(U32.mul(L.Dm.n(m), L.Dm.d(m)), al, [L.Wg.la(w)], X.exp(X.x(0)), False{})])
    case False{}:
      [P.map1(U32.mul(L.Dm.n(m), L.Dm.d(m)), al, [L.Wg.z(w)], X.sigmoid(X.x(0)), False{})]

# token i: S' = diag(alpha) S + khat v^T per head (in place: each cell
# reads only itself), then o = q^T S' (no 1/sqrt(hd)), one product batched
# over heads
def dd.gla.tok(+m: L.Dm, +w: L.Wg, +al: U32, +sst: U32, +i: U32) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +hh2 = U32.mul(hd, hd)
  +r = U32.mul(i, d)
  +kh = U32.add(M.gla.key(L.Dm.rglru(m), w), r)
  +vv = U32.add(L.Wg.qkv(w), U32.add(U32.mul(2, d), U32.mul(i, U32.mul(3, d))))
  [dd.ein(Es{[h, hd, hd], 0, 0, 0, dd.v(sst, [hh2, hd, 1]),
     [dd.v(sst, [hh2, hd, 1]), dd.v(U32.add(al, r), [hd, 1, 0]), dd.v(kh, [hd, 1, 0]), dd.v(vv, [hd, 0, 1])],
     X.add(X.mul(X.x(1), X.x(0)), X.mul(X.x(2), X.x(3)))}),
   P.Mm{0, 0, 1, hd, hd, h, 1.0, U32.add(L.Wg.qh(w), r), hd, hd, sst, hd, hh2, 0.0, U32.add(L.Wg.o(w), r), hd, hd}]

def dd.gla.toks(k: Nat, +i: U32, +m: L.Dm, +w: L.Wg, +al: U32, +sst: U32) -> List<&2, List<&2, P.Op>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      dd.gla.tok(m, w, al, sst, i) <> dd.gla.toks(p, U32.inc(i), m, w, al, sst)

def dd.gla(+m: L.Dm, +bp: L.BP, +w: L.Wg, +dx: Dx, +sst: U32) -> DdLy:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +d3 = U32.mul(3, d)
  +x = dd.dx.x(dx)
  +al = dd.dx.al(dx)
  +toks = dd.gla.toks(U32.to_nat(n), 0, m, w, al, sst)
  DdLy{List.concat(&2, P.Op, [
         M.norm(n, d, x, L.BP.ra(bp), L.Wg.ss(w), L.Wg.nrm(w)),
         [P.linear(n, d, d3, L.Wg.nrm(w), d, L.BP.wq(bp), L.Wg.qkv(w), d3),
          P.linear(n, d, d, L.Wg.nrm(w), d, L.BP.wa(bp), L.Wg.z(w), d)],
         M.l2(n, h, hd, L.Wg.qkv(w), d3, L.Wg.sq(w), L.Wg.qh(w)),
         M.l2(n, h, hd, U32.add(L.Wg.qkv(w), d), d3, L.Wg.sk(w), L.Wg.kh0(w)),
         dd.gate(L.Dm.rglru(m), m, bp, w, al)]),
       toks, Nil{}, toks,
       M.tail(m, bp, x, x, L.Wg.o(w), L.Wg.y1(w), L.Wg.xa(w), L.Wg.ss2(w), L.Wg.nrm2(w), L.Wg.gu(w), L.Wg.hh(w), L.Wg.y2(w))}

# Softmax over the ring (Model.bend block.sm, sm.attend): token i writes
# its k (after qk-norm) and v into its slot
def dd.sm.write(+m: L.Dm, +w: L.Wg, +kc: U32, +slot: U32, +i: U32) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  +d3 = U32.mul(3, d)
  +q = L.Dm.qk(m)
  +ko = U32.add(Bool.pick(U32, q, L.Wg.kh0(w), U32.add(L.Wg.qkv(w), d)), U32.mul(i, Bool.pick(U32, q, d, d3)))
  +vo = U32.add(L.Wg.qkv(w), U32.add(U32.mul(2, d), U32.mul(i, d3)))
  +sl = U32.add(slot, i)
  [dd.ein(Es{[d], 0, 0, 0, View{kc, [1], IxAt{sl, [0], d}}, [dd.v(ko, [1])], X.x(0)}),
   dd.ein(Es{[d], 0, 0, 0, View{U32.add(kc, U32.mul(L.Dm.t(m), d)), [1], IxAt{sl, [0], d}}, [dd.v(vo, [1])], X.x(0)})]

def dd.sm.max(s: Bool, +h: U32, +bp: L.BP, +dx: Dx) -> List<&2, P.Op>:
  match s:
    case True{}:
      [dd.ein(Es{[h], 0, 0, 0, dd.v(dd.dx.mm(dx), [1]), [dd.v(dd.dx.m1(dx), [1]), dd.v(L.BP.sink(bp), [1])], X.max(X.x(0), X.x(1))})]
    case False{}:
      Nil{}

def dd.sm.den(s: Bool, +h: U32, +bp: L.BP, +dx: Dx, +mo: U32) -> List<&2, P.Op>:
  match s:
    case True{}:
      [dd.ein(Es{[h], 0, 0, 0, dd.v(dd.dx.den(dx), [1]), [dd.v(dd.dx.se(dx), [1]), dd.v(L.BP.sink(bp), [1]), dd.v(mo, [1])],
         X.add(X.x(0), X.exp(X.sub(X.x(1), X.x(2))))})]
    case False{}:
      Nil{}

# token i attends (dx's first row of softmax cells): score every slot,
# mask those past its live one, the sink in the max and in the
# denominator, then the values' mix
def dd.sm.attend(+m: L.Dm, +bp: L.BP, +w: L.Wg, +dx: Dx, +kc: U32, +npos: U32, +i: U32) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +t = L.Dm.t(m)
  +q = L.Dm.qk(m)
  +sk = L.Dm.sinks(m)
  +vc = U32.add(kc, U32.mul(t, d))
  +qo = U32.add(Bool.pick(U32, q, L.Wg.qh(w), L.Wg.qkv(w)), U32.mul(i, Bool.pick(U32, q, d, U32.mul(3, d))))
  +r = U32.mul(i, d)
  +np = U32.add(npos, i)
  +mo = Bool.pick(U32, sk, dd.dx.mm(dx), dd.dx.m1(dx))
  +deno = Bool.pick(U32, sk, dd.dx.den(dx), dd.dx.se(dx))
  +sc = F32.div(1.0, F32.sqrt(U32.to_f32(hd)))
  +live = X.le(X.ix(1), X.x(1))
  +s = dd.dx.s(dx)
  +e = dd.dx.e(dx)
  List.concat(&2, P.Op, [
    # s[h, t'] = q_h · K[t']_h, every slot, one product batched over heads
    [P.Mm{0, 1, 1, t, hd, h, 1.0, qo, hd, hd, kc, d, hd, 0.0, s, t, t},
     dd.ein(Es{[h, t], 2, 1, 0, dd.v(dd.dx.m1(dx), [1, 0]), [dd.v(s, [t, 1]), dd.v(np, [0, 0])],
       X.sel(live, X.mul(X.k(sc), X.x(0)), X.k(F32.neg(X.inf())))})],
    dd.sm.max(sk, h, bp, dx),
    [dd.ein(Es{[h, t], 0, 0, 0, dd.v(e, [t, 1]), [dd.v(s, [t, 1]), dd.v(np, [0, 0]), dd.v(mo, [1, 0])],
       X.sel(live, X.exp(X.sub(X.mul(X.k(sc), X.x(0)), X.x(2))), X.k(0.0))}),
     dd.ein(Es{[h, t], 2, 0, 0, dd.v(dd.dx.se(dx), [1, 0]), [dd.v(e, [t, 1])], X.x(0)})],
    dd.sm.den(sk, h, bp, dx, mo),
    [P.Mm{0, 0, 1, hd, t, h, 1.0, e, t, t, vc, d, hd, 0.0, U32.add(L.Wg.oi(w), r), hd, hd},
     dd.ein(Es{[h, hd], 0, 0, 0, dd.v(U32.add(L.Wg.o(w), r), [hd, 1]), [dd.v(U32.add(L.Wg.oi(w), r), [hd, 1]), dd.v(deno, [1, 0])],
       X.mul(X.div(X.k(1.0), X.x(1)), X.x(0))})]])

def dd.sm.writes(k: Nat, +i: U32, +m: L.Dm, +w: L.Wg, +kc: U32, +slot: U32) -> List<&2, List<&2, P.Op>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      dd.sm.write(m, w, kc, slot, i) <> dd.sm.writes(p, U32.inc(i), m, w, kc, slot)

# token i's whole recurrence: its write, then its attention
def dd.sm.toks(k: Nat, +i: U32, +m: L.Dm, +bp: L.BP, +w: L.Wg, +dx: Dx, +kc: U32) -> List<&2, List<&2, P.Op>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      List.append(&2, P.Op, dd.sm.write(m, w, kc, dd.dx.slot(dx), i), dd.sm.attend(m, bp, w, dx, kc, dd.dx.npos(dx), i))
        <> dd.sm.toks(p, U32.inc(i), m, bp, w, dx, kc)

def dd.sm.rows.max(s: Bool, +n: U32, +h: U32, +bp: L.BP, +dx: Dx) -> List<&2, P.Op>:
  match s:
    case True{}:
      [dd.ein(Es{[n, h], 0, 0, 0, dd.v(dd.dx.mm(dx), [h, 1]), [dd.v(dd.dx.m1(dx), [h, 1]), dd.v(L.BP.sink(bp), [0, 1])], X.max(X.x(0), X.x(1))})]
    case False{}:
      Nil{}

def dd.sm.rows.den(s: Bool, +n: U32, +h: U32, +bp: L.BP, +dx: Dx, +mo: U32) -> List<&2, P.Op>:
  match s:
    case True{}:
      [dd.ein(Es{[n, h], 0, 0, 0, dd.v(dd.dx.den(dx), [h, 1]), [dd.v(dd.dx.se(dx), [h, 1]), dd.v(L.BP.sink(bp), [0, 1]), dd.v(mo, [h, 1])],
         X.add(X.x(0), X.exp(X.sub(X.x(1), X.x(2))))})]
    case False{}:
      Nil{}

# every row attends at once (row i: dd.sm.attend's ops at token i, the
# products at m = n), after every row's write: right while no write has
# wrapped, since row i then masks the slots the rows after it wrote. The
# scores, exponentials and mixes lie head-major ([h, n, t], [h, n, hd]),
# each head's product one block, as the CPU gemm wants its batches
def dd.sm.rows(+m: L.Dm, +bp: L.BP, +w: L.Wg, +dx: Dx, +kc: U32) -> List<&2, P.Op>:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +t = L.Dm.t(m)
  +nt = U32.mul(n, t)
  +nhd = U32.mul(n, hd)
  +q = L.Dm.qk(m)
  +sk = L.Dm.sinks(m)
  +qo = Bool.pick(U32, q, L.Wg.qh(w), L.Wg.qkv(w))
  +mo = Bool.pick(U32, sk, dd.dx.mm(dx), dd.dx.m1(dx))
  +deno = Bool.pick(U32, sk, dd.dx.den(dx), dd.dx.se(dx))
  +sc = F32.div(1.0, F32.sqrt(U32.to_f32(hd)))
  +live = X.le(X.ix(2), X.x(1))
  +s = dd.dx.s(dx)
  +e = dd.dx.e(dx)
  +np = dd.dx.npos(dx)
  List.concat(&2, P.Op, [
    [P.Mm{0, 1, n, t, hd, h, 1.0, qo, Bool.pick(U32, q, d, U32.mul(3, d)), hd, kc, d, hd, 0.0, s, t, nt},
     dd.ein(Es{[n, h, t], 4, 1, 0, dd.v(dd.dx.m1(dx), [h, 1, 0]), [dd.v(s, [t, nt, 1]), dd.v(np, [1, 0, 0])],
       X.sel(live, X.mul(X.k(sc), X.x(0)), X.k(F32.neg(X.inf())))})],
    dd.sm.rows.max(sk, n, h, bp, dx),
    [dd.ein(Es{[n, h, t], 0, 0, 0, dd.v(e, [t, nt, 1]), [dd.v(s, [t, nt, 1]), dd.v(np, [1, 0, 0]), dd.v(mo, [h, 1, 0])],
       X.sel(live, X.exp(X.sub(X.mul(X.k(sc), X.x(0)), X.x(2))), X.k(0.0))}),
     dd.ein(Es{[n, h, t], 4, 0, 0, dd.v(dd.dx.se(dx), [h, 1, 0]), [dd.v(e, [t, nt, 1])], X.x(0)})],
    dd.sm.rows.den(sk, n, h, bp, dx, mo),
    [P.Mm{0, 0, n, hd, t, h, 1.0, e, t, nt, U32.add(kc, U32.mul(t, d)), d, hd, 0.0, L.Wg.oi(w), hd, nhd},
     dd.ein(Es{[n, h, hd], 0, 0, 0, dd.v(L.Wg.o(w), [d, hd, 1]), [dd.v(L.Wg.oi(w), [hd, nhd, 1]), dd.v(deno, [h, 1, 0])],
       X.mul(X.div(X.k(1.0), X.x(1)), X.x(0))})]])

def dd.sm(+m: L.Dm, +bp: L.BP, +w: L.Wg, +dx: Dx, +kc: U32) -> DdLy:
  +n = L.Dm.n(m)
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +d3 = U32.mul(3, d)
  +q = L.Dm.qk(m)
  +x = dd.dx.x(dx)
  +k = U32.to_nat(n)
  DdLy{List.concat(&2, P.Op, [
         M.norm(n, d, x, L.BP.ra(bp), L.Wg.ss(w), L.Wg.nrm(w)),
         [P.linear(n, d, d3, L.Wg.nrm(w), d, L.BP.wq(bp), L.Wg.qkv(w), d3)],
         M.sm.qk(q, n, h, hd, L.Wg.qkv(w), d3, L.BP.gq(bp), L.Wg.sq(w), L.Wg.qh(w)),
         M.sm.qk(q, n, h, hd, U32.add(L.Wg.qkv(w), d), d3, L.BP.gk(bp), L.Wg.sk(w), L.Wg.kh0(w))]),
       dd.sm.writes(k, 0, m, w, kc, dd.dx.slot(dx)), dd.sm.rows(m, bp, w, dx, kc), dd.sm.toks(k, 0, m, bp, w, dx, kc),
       M.tail(m, bp, x, x, L.Wg.o(w), L.Wg.y1(w), L.Wg.xa(w), L.Wg.ss2(w), L.Wg.nrm2(w), L.Wg.gu(w), L.Wg.hh(w), L.Wg.y2(w))}

def dd.layer.k(g: Bool, +m: L.Dm, +bp: L.BP, +w: L.Wg, +dx: Dx, +o: U32) -> DdLy:
  match g:
    case True{}:
      dd.gla(m, bp, w, dx, o)
    case False{}:
      dd.sm(m, bp, w, dx, o)

def dd.layer(+m: L.Dm, +bp: L.BP, +w: L.Wg, +dx: Dx, +o: U32) -> DdLy:
  dd.layer.k(L.BP.gla(bp), m, bp, w, dx, o)

# every layer at m's n rows, the states from o
def dd.lys(bs: List<&2, L.BP>, +m: L.Dm, +w: L.Wg, +dx: Dx, +o: U32) -> List<&2, DdLy>:
  match bs:
    case Nil{}:
      Nil{}
    case +bp <> t:
      dd.layer(m, bp, w, dx, o) <> dd.lys(t, m, w, dx, U32.add(o, dd.st.size(bp, m)))

# the embedding: row i gathers the row of E the token cell tok + i names
def dd.embed(+m: L.Dm, +dx: Dx) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  [dd.ein(Es{[L.Dm.n(m), d], 0, 0, 0, dd.v(dd.dx.x(dx), [d, 1]), [View{0, [0, 1], IxAt{dd.dx.tok(dx), [1, 0], d}}], X.x(0)})]

# a layer as one program, token by token in between (the step's)
def dd.flat(ly: DdLy) -> List<&2, P.Op>:
  match ly:
    case DdLy{pre, toks, mid, wtoks, post}:
      List.append(&2, P.Op, pre, List.append(&2, P.Op, List.concat(&2, P.Op, wtoks), post))

def dd.flats(lys: List<&2, DdLy>) -> List<&2, List<&2, P.Op>>:
  match lys:
    case Nil{}:
      Nil{}
    case ly <> t:
      dd.flat(ly) <> dd.flats(t)

# Greedy's pick on the store (Sample.bend's argmax: the first of the
# largest logits), so the v logits never become a Bend value: the cell top
# gets their max m, the cell top+1 the max over i of v - i where l_i >= m
# (0 elsewhere), so v minus it is the least i holding m. Every v - i is an
# integer below 2^24, exact in F32. No l_i >= m (m NaN) leaves 0 there:
# dd.top answers v, and the caller falls back to the logits.
def dd.pick(+v: U32, +lg: U32, +top: U32) -> List<&2, P.Op>:
  [dd.ein(Es{[v], 1, 1, 0, dd.v(top, [0]), [dd.v(lg, [1])], X.x(0)}),
   dd.ein(Es{[v], 1, 1, 0, dd.v(U32.add(top, 1), [0]), [dd.v(lg, [1]), dd.v(top, [0])],
     X.sel(X.le(X.x(1), X.x(0)), X.sub(X.k(U32.to_f32(v)), X.ix(0)), X.k(0.0))})]

# The decoder for a config and a chunk size cn (at least 1): the layout and
# its programs. `feed` takes the token, slot and live cells to the residual
# stream after the last layer (states advanced); `head` turns it into the
# logits (Model.bend decode.fin: the tied embedding over the final
# RMSNorm); `pick` takes them to greedy's token in the two cells at `top`.
# The chunk's stages are feed's at n = cn.
def dd.of.n(+c: C.Config, +cn: U32) -> Dd:
  +m = dd.dm(c)
  +cm = dd.dm.n(c, cn)
  +d = L.Dm.d(m)
  +v = L.Dm.v(m)
  +e0 = U32.mul(v, d)
  +bs = L.BP.list(C.Config.layers(c), c, 0n, e0)
  +fin = L.blocks.end(C.Config.layers(c), c, 0n, e0)
  +p = U32.add(fin, d)
  +st0 = L.align(p)
  +stn = dd.st.end(bs, m, st0)
  +w = L.Wg.at(m, stn)
  +dx = dd.dx(m, L.Wg.end(w))
  +x = dd.dx.x(dx)
  +ssf = dd.dx.end(dx)
  +fv = U32.add(ssf, 1)
  +lg = L.align(U32.add(fv, d))
  +top = U32.add(lg, v)
  +wc = L.Wg.at(cm, U32.add(top, 2))
  +cx = dd.dx(cm, L.Wg.end(wc))
  +total = dd.dx.end(cx)
  +feed = List.concat(&2, P.Op, dd.embed(m, dx) <> dd.flats(dd.lys(bs, m, w, dx, st0)))
  +head = List.append(&2, P.Op, M.norm(1, d, x, fin, ssf, fv), [P.linear(1, d, v, fv, d, 0, lg, v)])
  +copy = {[dd.ein(Es{[d], 0, 0, 0, dd.v(x, [1]), [View{dd.dx.x(cx), [1], IxAt{dd.dx.last(cx), [0], d}}], X.x(0)})] : List<&2, P.Op>}
  Dd{c, p, st0, stn, dd.dx.tok(dx), dd.dx.slot(dx), dd.dx.npos(dx), lg, v, L.Dm.t(m),
     L.depth(31n, U32.is_lt(2, total), total, 0n, 1), feed, head, top, dd.pick(v, lg, top),
     DdCh{cn, dd.dx.tok(cx), dd.dx.slot(cx), dd.dx.npos(cx), dd.dx.last(cx), dd.embed(cm, cx), dd.lys(bs, cm, wc, cx, st0), copy}}

# the chunk size ana prefills with (ANA_PREFILL_CHUNK overrides it): on
# nr7-step61000 (115M, ctx 2048, 8 kernel threads) 64 read a 669-token
# prompt fastest of 16, 32, 64 and 128; 128 also doubles the store to 2^28
def dd.chunk.default() -> U32:
  64

def dd.of(+c: C.Config) -> Dd:
  dd.of.n(c, dd.chunk.default())

# Running ---------------------------------------------------------------------

def dd.new(+k: Dd) -> Array<F32>:
  Array.new(F32, dd.depth(k), 0.0)

# every layer's state back to 0 (a fresh episode on loaded weights)
def dd.reset(+k: Dd, s: Array<F32>) -> Array<F32>:
  match k:
    case Dd{c, p, +st0, stn, tok, slot, npos, lg, v, ctx, dp, f, h, tp, pk, ch}:
      P.run([P.zero(U32.sub(stn, st0), st0)], s)

# a token's cells at a position: the token, its ring slot (pos mod ctx)
# and the last live slot (min(pos, ctx - 1))
def dd.at(+ctx: U32, +pos: Nat, +t: U32, +tok: U32, +slot: U32, +npos: U32, s: Array<F32>) -> Array<F32>:
  +slot1 = U32.from_nat(Nat.mod(pos, U32.to_nat(ctx)))
  +live = U32.from_nat(Nat.min(pos, U32.to_nat(U32.sub(ctx, 1))))
  Array.set(F32, Array.set(F32, Array.set(F32, s, tok, U32.to_f32(t)), slot, U32.to_f32(slot1)), npos, U32.to_f32(live))

# one token at a position: its cells, then every layer (no logits)
def dd.feed(+k: Dd, +pos: Nat, +t: U32, s: Array<F32>) -> Array<F32>:
  match k:
    case Dd{c, p, st0, stn, +tok, +slot, +npos, lg, v, +ctx, dp, f, h, tp, pk, ch}:
      P.run(f, dd.at(ctx, pos, t, tok, slot, npos, s))

# tokens from pos: token i's cells at tok + i, slot + i, npos + i
def dd.cells(ts: List<&2, U32>, +ctx: U32, +pos: Nat, +tok: U32, +slot: U32, +npos: U32, s: Array<F32>) -> Array<F32>:
  match ts:
    case Nil{}:
      s
    case t <> rest:
      dd.cells(rest, ctx, 1n+pos, U32.inc(tok), U32.inc(slot), U32.inc(npos), dd.at(ctx, pos, t, tok, slot, npos, s))

def dd.toks.run(ts: List<&2, List<&2, P.Op>>, s: Array<F32>) -> Array<F32>:
  match ts:
    case Nil{}:
      s
    case ops <> rest:
      dd.toks.run(rest, P.run(ops, s))

# a layer for r tokens: before the wrap, the writes then every row's
# attention; else each token's write and attention in turn
def dd.ly.run(fresh: Bool, ly: DdLy, +r: Nat, s: Array<F32>) -> Array<F32>:
  match fresh ly:
    case True{} DdLy{pre, toks, mid, wtoks, post}:
      P.run(post, P.run(mid, dd.toks.run(List.take(&2, List<&2, P.Op>, toks, r), P.run(pre, s))))
    case False{} DdLy{pre, toks, mid, wtoks, post}:
      P.run(post, dd.toks.run(List.take(&2, List<&2, P.Op>, wtoks, r), P.run(pre, s)))

def dd.lys.run(lys: List<&2, DdLy>, +fresh: Bool, +r: Nat, s: Array<F32>) -> Array<F32>:
  match lys:
    case Nil{}:
      s
    case ly <> t:
      dd.lys.run(t, fresh, r, dd.ly.run(fresh, ly, r, s))

def dd.chunk.run(+fresh: Bool, ch: DdCh, +ctx: U32, +pos: Nat, +ts: List<&2, U32>, s: Array<F32>) -> Array<F32>:
  match ch:
    case DdCh{n, +tok, +slot, +npos, last, embed, lys, copy}:
      +r = List.length(&2, U32, ts)
      P.run(copy, dd.lys.run(lys, fresh, r, P.run(embed,
        Array.set(F32, dd.cells(ts, ctx, pos, tok, slot, npos, s), last, U32.to_f32(U32.from_nat(Nat.sub(r, 1n)))))))

# 1 to C tokens from a position: as many dd.feed's (the chunk program; its
# attention batched while every position stays below ctx)
def dd.chunk(+k: Dd, +pos: Nat, +ts: List<&2, U32>, s: Array<F32>) -> Array<F32>:
  match k:
    case Dd{c, p, st0, stn, tok, slot, npos, lg, v, +ctx, dp, f, h, tp, pk, ch}:
      dd.chunk.run(Nat.is_le(Nat.add(pos, List.length(&2, U32, ts)), U32.to_nat(ctx)), ch, ctx, pos, ts, s)

# tokens one at a time from a position
def dd.feed.each(xs: List<&2, U32>, +k: Dd, +pos: Nat, s: Array<F32>) -> Array<F32>:
  match xs:
    case Nil{}:
      s
    case t <> rest:
      dd.feed.each(rest, k, 1n+pos, dd.feed(k, pos, t, s))

# A partial chunk costs about what a whole one does (every stage but the
# recurrence runs on all C rows), so fewer tokens than this go one at a
# time: on nr7-step61000 a chunk of 64 took the time of 7 steps with 8
# kernel threads (under E5's load) and of 9 with one
def dd.chunk.min() -> Nat:
  8n

def dd.feeds.rest(chunk: Bool, +k: Dd, +xs: List<&2, U32>, +pos: Nat, s: Array<F32>) -> Array<F32>:
  match chunk:
    case True{}:
      dd.chunk(k, pos, xs, s)
    case False{}:
      dd.feed.each(xs, k, pos, s)

# q chunks of n tokens, then the rest: a partial chunk, or one at a time
def dd.feeds.go(q: Nat, +k: Dd, +n: Nat, +xs: List<&2, U32>, +pos: Nat, s: Array<F32>) -> Array<F32>:
  match q:
    case 0n:
      dd.feeds.rest(Nat.is_le(dd.chunk.min(), List.length(&2, U32, xs)), k, xs, pos, s)
    case 1n+r:
      dd.feeds.go(r, k, n, List.drop(&2, U32, xs, n), Nat.add(pos, n), dd.chunk(k, pos, List.take(&2, U32, xs, n), s))

# tokens from a position, a chunk at a time: the store their dd.feed's
# leave, bit for bit (head then reads the last token's logits)
def dd.feeds(+k: Dd, +xs: List<&2, U32>, +pos: Nat, s: Array<F32>) -> Array<F32>:
  +n = dd.cn(k)
  dd.feeds.go(Nat.div(List.length(&2, U32, xs), n), k, n, xs, pos, s)

# the logits after the tokens fed so far
def dd.logits(+k: Dd, s: Array<F32>) -> Array<F32> & List<&2, F32>:
  match k:
    case Dd{c, p, st0, stn, tok, slot, npos, lg, v, ctx, dp, f, h, tp, pk, ch}:
      Io.get(U32.to_nat(v), P.run(h, s), lg)

def dd.top.of(+v: U32, r: Array<F32> & F32) -> Array<F32> & U32:
  (s, y) = r
  (s, U32.sub(v, F32.to_u32(y)))

# greedy's pick after the tokens fed so far (dd.pick): the head, then the
# argmax on the store; v when no logit is the max (NaN)
def dd.top(+k: Dd, s: Array<F32>) -> Array<F32> & U32:
  match k:
    case Dd{c, p, st0, stn, tok, slot, npos, lg, +v, ctx, dp, f, h, +tp, pk, ch}:
      dd.top.of(v, Array.get(F32, P.run(pk, P.run(h, s)), U32.add(tp, 1)))

# Loading ---------------------------------------------------------------------

def dd.load.close(+step: Nat, r: File & Array<F32>) -> IO(Array<F32> & Nat):
  (f, s) = r
  do IO<Array<F32> & Nat>:
    u : Unit <- File.close(f)
    return (s, step)

# (newest first) the step's 16 bytes, the parameter count's 8
def dd.load.small(xss: List<&2, List<&2, U32>>, +p: U32, +o: Dk.Off, f: File, s: Array<F32>) -> IO(Array<F32> & Nat):
  match xss:
    case +mid <> +cnt <> t:
      do IO<Array<F32> & Nat>:
        u : Unit <- Dk.fail.if(K.check(U32.is_eq(Dk.lo.of(cnt), p), "checkpoint parameter vector length is not the parameter count", ""))
        r : File & Array<F32> <- Dk.rds([Dk.Rd{Dk.Off.par(o), p, 0}], (f, s))
        dd.load.close(U32.to_nat(Dk.lo.of(mid)), r)
    case _:
      IO.die(Array<F32> & Nat, 1, "checkpoint: short read")

def dd.load.got(+p: U32, +o: Dk.Off, r: File & List<&2, List<&2, U32>>, s: Array<F32>) -> IO(Array<F32> & Nat):
  (f, xss) = r
  dd.load.small(xss, p, o, f, s)

# An FTC2 checkpoint's parameters into a fresh store, and the step it was
# saved at; man and h (the header's end) from Dense/Ckpt.bend `header`.
# Only the parameter vector is read (the optimizer's state is not), so the
# file may pass Dk.load's 2^28-parameter guard while 8 + 4P stays 32-bit.
def dd.load(+path: String, +man: K.Manifest, +h: Nat, +k: Dd) -> IO(Array<F32> & Nat):
  +p = dd.p(k)
  +hu = U32.from_nat(h)
  +o = Dk.Off.of(hu, p)
  do IO<Array<F32> & Nat>:
    u1 : Unit <- Dk.fail.if(K.Manifest.problem(man))
    u2 : Unit <- Dk.fail.if(K.check(Nat.is_eq(C.Config.params(K.Manifest.cfg(man)), U32.to_nat(p)), "checkpoint parameter count is not the store's", ""))
    u3 : Unit <- Dk.fail.if(K.check(C.Config.tied(K.Manifest.cfg(man)), "the dense decoder needs a tied head", ""))
    f : File <- IO.try(File, File.open(path, "r"))
    r : File & List<&2, List<&2, U32>> <- Dk.ats([Dk.Rg{hu, 8}, Dk.Rg{Dk.Off.stp(o), 16}], (f, Nil{}))
    dd.load.got(p, o, r, dd.new(k))
