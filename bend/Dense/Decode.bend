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
# (the trainer's GLA workspace at n = 1, shared by every layer), then the
# position's cells (token, ring slot, last live slot) and the logits.
#
# Everything that depends on the position goes through those cells: the
# embedding gathers the row the token cell names, the K/V writes scatter
# into the slot the slot cell names, and attention masks slots past the
# live one. So the programs are built once and every token reuses them.
# Slots never written hold 0, so a masked slot adds exactly -inf to a max
# and 0 to a sum, as an empty slot (MZ) does in Model.bend's sm.attend.
#
# Every def is prefixed `dd.` (one namespace across a program's imports).

type Dd is Data:
  Dd{c: C.Config, p: U32, st0: U32, stn: U32, tok: U32, slot: U32, npos: U32, lg: U32, v: U32, ctx: U32,
     depth: Nat, feed: List<&2, P.Op>, head: List<&2, P.Op>}

def dd.c(+d: Dd) -> C.Config:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h}:
      c

def dd.p(+d: Dd) -> U32:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h}:
      p

def dd.depth(+d: Dd) -> Nat:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h}:
      dp

def dd.vocab(+d: Dd) -> U32:
  match d:
    case Dd{c, p, a, b, t, s, n, lg, v, x, dp, f, h}:
      v

# Layout ----------------------------------------------------------------------

def dd.v(off: U32, st: List<&2, U32>) -> View:
  P.view(off, st)

def dd.ein(+es: Es) -> P.Op:
  P.ein(es, False{})

# one token at a time: n = 1 row, the trainer's shapes otherwise
def dd.dm(+c: C.Config) -> L.Dm:
  +d = L.u(C.Config.d(c))
  +h = L.u(C.Config.heads(c))
  L.Dm{1, L.u(C.Config.ctx(c)), d, L.u(C.Config.f(c)), h, U32.div(d, h), L.u(C.Config.vocab(c)), L.u(C.Config.layers(c)),
       1, 1, 1, 1, 1, C.Config.rglru(c), C.Config.qk(c), C.Config.sinks(c)}

# a layer's state size: S per GLA layer, K and V rings per softmax layer
def dd.st.size(+bp: L.BP, +m: L.Dm) -> U32:
  Bool.pick(U32, L.BP.gla(bp), U32.mul(L.Dm.h(m), U32.mul(L.Dm.hd(m), L.Dm.hd(m))), U32.mul(2, U32.mul(L.Dm.t(m), L.Dm.d(m))))

def dd.st.end(bs: List<&2, L.BP>, +m: L.Dm, +o: U32) -> U32:
  match bs:
    case Nil{}:
      o
    case +bp <> t:
      dd.st.end(t, m, U32.add(o, dd.st.size(bp, m)))

# The extra cells a token needs beyond the trainer's GLA workspace (Wg at
# n = 1): softmax's scores, maxima, exponentials and sums, the gate's
# alpha, the residual stream, the head's input and the position's cells.
type Dx is Data:
  Dx{al: U32, s: U32, m1: U32, mm: U32, e: U32, se: U32, den: U32, x: U32, ssf: U32, fv: U32, tok: U32, slot: U32, npos: U32, lg: U32, end: U32}

def dd.dx(+m: L.Dm, +o: U32) -> Dx:
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hc = U32.mul(h, L.Dm.t(m))
  +al = o
  +s = U32.add(al, d)
  +m1 = U32.add(s, hc)
  +mm = U32.add(m1, h)
  +e = U32.add(mm, h)
  +se = U32.add(e, hc)
  +den = U32.add(se, h)
  +x = U32.add(den, h)
  +ssf = U32.add(x, d)
  +fv = U32.add(ssf, 1)
  +tok = U32.add(fv, d)
  +lg = L.align(U32.add(tok, 3))
  Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, U32.add(tok, 1), U32.add(tok, 2), lg, U32.add(lg, L.Dm.v(m))}

def dd.dx.al(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      al

def dd.dx.s(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      s

def dd.dx.m1(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      m1

def dd.dx.mm(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      mm

def dd.dx.e(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      e

def dd.dx.se(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      se

def dd.dx.den(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      den

def dd.dx.x(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      x

def dd.dx.ssf(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      ssf

def dd.dx.fv(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      fv

def dd.dx.tok(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      tok

def dd.dx.slot(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      slot

def dd.dx.npos(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      npos

def dd.dx.lg(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      lg

def dd.dx.end(+r: Dx) -> U32:
  match r:
    case Dx{al, s, m1, mm, e, se, den, x, ssf, fv, tok, slot, npos, lg, end}:
      end

# The programs ----------------------------------------------------------------

# GLA (Model.bend block.gla, gla.gate, gla.state, gla.out): alpha and the
# key from the gate (RG-LRU: exp of the log gate, the write-scaled key;
# else sigmoid(z) and k^ itself)
def dd.gate(g: Bool, +m: L.Dm, +bp: L.BP, +w: L.Wg, +al: U32) -> List<&2, P.Op>:
  match g:
    case True{}:
      List.append(&2, P.Op, M.gla.gate(True{}, m, bp, w), [P.map1(L.Dm.d(m), al, [L.Wg.la(w)], X.exp(X.x(0)), False{})])
    case False{}:
      [P.map1(L.Dm.d(m), al, [L.Wg.z(w)], X.sigmoid(X.x(0)), False{})]

# S' = diag(alpha) S + khat v^T per head (in place: each cell reads only
# itself), then o = q^T S' (no 1/sqrt(hd)), one product batched over heads
def dd.gla(+m: L.Dm, +bp: L.BP, +x: U32, +w: L.Wg, +dx: Dx, +sst: U32) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +d3 = U32.mul(3, d)
  +hh2 = U32.mul(hd, hd)
  +al = dd.dx.al(dx)
  +kh = M.gla.key(L.Dm.rglru(m), w)
  List.concat(&2, P.Op, [
    M.norm(1, d, x, L.BP.ra(bp), L.Wg.ss(w), L.Wg.nrm(w)),
    [P.linear(1, d, d3, L.Wg.nrm(w), d, L.BP.wq(bp), L.Wg.qkv(w), d3),
     P.linear(1, d, d, L.Wg.nrm(w), d, L.BP.wa(bp), L.Wg.z(w), d)],
    M.l2(1, h, hd, L.Wg.qkv(w), d3, L.Wg.sq(w), L.Wg.qh(w)),
    M.l2(1, h, hd, U32.add(L.Wg.qkv(w), d), d3, L.Wg.sk(w), L.Wg.kh0(w)),
    dd.gate(L.Dm.rglru(m), m, bp, w, al),
    [dd.ein(Es{[h, hd, hd], 0, 0, 0, dd.v(sst, [hh2, hd, 1]),
       [dd.v(sst, [hh2, hd, 1]), dd.v(al, [hd, 1, 0]), dd.v(kh, [hd, 1, 0]), dd.v(U32.add(L.Wg.qkv(w), U32.mul(2, d)), [hd, 0, 1])],
       X.add(X.mul(X.x(1), X.x(0)), X.mul(X.x(2), X.x(3)))}),
     P.Mm{0, 0, 1, hd, hd, h, 1.0, L.Wg.qh(w), hd, hd, sst, hd, hh2, 0.0, L.Wg.o(w), hd, hd}],
    M.tail(m, bp, x, x, L.Wg.o(w), L.Wg.y1(w), L.Wg.xa(w), L.Wg.ss2(w), L.Wg.nrm2(w), L.Wg.gu(w), L.Wg.hh(w), L.Wg.y2(w))])

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

# Softmax over the ring (Model.bend block.sm, sm.attend): write k (after
# qk-norm) and v into the slot, score every slot, mask those past the live
# one, the sink in the max and in the denominator, then the values' mix
def dd.sm(+m: L.Dm, +bp: L.BP, +x: U32, +w: L.Wg, +dx: Dx, +kc: U32) -> List<&2, P.Op>:
  +d = L.Dm.d(m)
  +h = L.Dm.h(m)
  +hd = L.Dm.hd(m)
  +t = L.Dm.t(m)
  +d3 = U32.mul(3, d)
  +q = L.Dm.qk(m)
  +sk = L.Dm.sinks(m)
  +vc = U32.add(kc, U32.mul(t, d))
  +qo = Bool.pick(U32, q, L.Wg.qh(w), L.Wg.qkv(w))
  +ko = Bool.pick(U32, q, L.Wg.kh0(w), U32.add(L.Wg.qkv(w), d))
  +mo = Bool.pick(U32, sk, dd.dx.mm(dx), dd.dx.m1(dx))
  +deno = Bool.pick(U32, sk, dd.dx.den(dx), dd.dx.se(dx))
  +sc = F32.div(1.0, F32.sqrt(U32.to_f32(hd)))
  +live = X.le(X.ix(1), X.x(1))
  +s = dd.dx.s(dx)
  +e = dd.dx.e(dx)
  List.concat(&2, P.Op, [
    M.norm(1, d, x, L.BP.ra(bp), L.Wg.ss(w), L.Wg.nrm(w)),
    [P.linear(1, d, d3, L.Wg.nrm(w), d, L.BP.wq(bp), L.Wg.qkv(w), d3)],
    M.sm.qk(q, 1, h, hd, L.Wg.qkv(w), d3, L.BP.gq(bp), L.Wg.sq(w), L.Wg.qh(w)),
    M.sm.qk(q, 1, h, hd, U32.add(L.Wg.qkv(w), d), d3, L.BP.gk(bp), L.Wg.sk(w), L.Wg.kh0(w)),
    [dd.ein(Es{[d], 0, 0, 0, View{kc, [1], IxAt{dd.dx.slot(dx), [0], d}}, [dd.v(ko, [1])], X.x(0)}),
     dd.ein(Es{[d], 0, 0, 0, View{vc, [1], IxAt{dd.dx.slot(dx), [0], d}}, [dd.v(U32.add(L.Wg.qkv(w), U32.mul(2, d)), [1])], X.x(0)}),
     # s[h, t'] = q_h · K[t']_h, every slot, one product batched over heads
     P.Mm{0, 1, 1, t, hd, h, 1.0, qo, hd, hd, kc, d, hd, 0.0, s, t, t},
     dd.ein(Es{[h, t], 2, 1, 0, dd.v(dd.dx.m1(dx), [1, 0]), [dd.v(s, [t, 1]), dd.v(dd.dx.npos(dx), [0, 0])],
       X.sel(live, X.mul(X.k(sc), X.x(0)), X.k(F32.neg(X.inf())))})],
    dd.sm.max(sk, h, bp, dx),
    [dd.ein(Es{[h, t], 0, 0, 0, dd.v(e, [t, 1]), [dd.v(s, [t, 1]), dd.v(dd.dx.npos(dx), [0, 0]), dd.v(mo, [1, 0])],
       X.sel(live, X.exp(X.sub(X.mul(X.k(sc), X.x(0)), X.x(2))), X.k(0.0))}),
     dd.ein(Es{[h, t], 2, 0, 0, dd.v(dd.dx.se(dx), [1, 0]), [dd.v(e, [t, 1])], X.x(0)})],
    dd.sm.den(sk, h, bp, dx, mo),
    [P.Mm{0, 0, 1, hd, t, h, 1.0, e, t, t, vc, d, hd, 0.0, L.Wg.oi(w), hd, hd},
     dd.ein(Es{[h, hd], 0, 0, 0, dd.v(L.Wg.o(w), [hd, 1]), [dd.v(L.Wg.oi(w), [hd, 1]), dd.v(deno, [1, 0])],
       X.mul(X.div(X.k(1.0), X.x(1)), X.x(0))})],
    M.tail(m, bp, x, x, L.Wg.o(w), L.Wg.y1(w), L.Wg.xa(w), L.Wg.ss2(w), L.Wg.nrm2(w), L.Wg.gu(w), L.Wg.hh(w), L.Wg.y2(w))])

def dd.layer.k(g: Bool, +m: L.Dm, +bp: L.BP, +x: U32, +w: L.Wg, +dx: Dx, +o: U32) -> List<&2, P.Op>:
  match g:
    case True{}:
      dd.gla(m, bp, x, w, dx, o)
    case False{}:
      dd.sm(m, bp, x, w, dx, o)

def dd.layer(+m: L.Dm, +bp: L.BP, +x: U32, +w: L.Wg, +dx: Dx, +o: U32) -> List<&2, P.Op>:
  dd.layer.k(L.BP.gla(bp), m, bp, x, w, dx, o)

def dd.layers(bs: List<&2, L.BP>, +m: L.Dm, +x: U32, +w: L.Wg, +dx: Dx, +o: U32) -> List<&2, List<&2, P.Op>>:
  match bs:
    case Nil{}:
      Nil{}
    case +bp <> t:
      dd.layer(m, bp, x, w, dx, o) <> dd.layers(t, m, x, w, dx, U32.add(o, dd.st.size(bp, m)))

# The decoder for a config: the layout and its two programs. `feed` takes
# the token, slot and live cells to the residual stream after the last
# layer (states advanced); `head` turns it into the logits (Model.bend
# decode.fin: the tied embedding over the final RMSNorm).
def dd.of(+c: C.Config) -> Dd:
  +m = dd.dm(c)
  +d = L.Dm.d(m)
  +e0 = U32.mul(L.Dm.v(m), d)
  +bs = L.BP.list(C.Config.layers(c), c, 0n, e0)
  +fin = L.blocks.end(C.Config.layers(c), c, 0n, e0)
  +p = U32.add(fin, d)
  +st0 = L.align(p)
  +stn = dd.st.end(bs, m, st0)
  +w = L.Wg.at(m, stn)
  +dx = dd.dx(m, L.Wg.end(w))
  +x = dd.dx.x(dx)
  +total = dd.dx.end(dx)
  +feed = List.concat(&2, P.Op, List.append(&2, List<&2, P.Op>,
    [[dd.ein(Es{[1, d], 0, 0, 0, dd.v(x, [d, 1]), [View{0, [0, 1], IxAt{dd.dx.tok(dx), [0, 0], d}}], X.x(0)})]],
    dd.layers(bs, m, x, w, dx, st0)))
  +head = List.append(&2, P.Op, M.norm(1, d, x, fin, dd.dx.ssf(dx), dd.dx.fv(dx)),
    [P.linear(1, d, L.Dm.v(m), dd.dx.fv(dx), d, 0, dd.dx.lg(dx), L.Dm.v(m))])
  Dd{c, p, st0, stn, dd.dx.tok(dx), dd.dx.slot(dx), dd.dx.npos(dx), dd.dx.lg(dx), L.Dm.v(m), L.Dm.t(m),
     L.depth(31n, U32.is_lt(2, total), total, 0n, 1), feed, head}

# Running ---------------------------------------------------------------------

def dd.new(+k: Dd) -> Array<F32>:
  Array.new(F32, dd.depth(k), 0.0)

# every layer's state back to 0 (a fresh episode on loaded weights)
def dd.reset(+k: Dd, s: Array<F32>) -> Array<F32>:
  match k:
    case Dd{c, p, +st0, stn, +tok, +slot, +npos, lg, v, +ctx, dp, f, h}:
      P.run([P.zero(U32.sub(stn, st0), st0)], s)

# one token at a position: its cells, then every layer (no logits)
def dd.feed(+k: Dd, +pos: Nat, +t: U32, s: Array<F32>) -> Array<F32>:
  match k:
    case Dd{c, p, +st0, stn, +tok, +slot, +npos, lg, v, +ctx, dp, f, h}:
      +slot1 = U32.from_nat(Nat.mod(pos, U32.to_nat(ctx)))
      +live = U32.from_nat(Nat.min(pos, U32.to_nat(U32.sub(ctx, 1))))
      P.run(f, Array.set(F32, Array.set(F32, Array.set(F32, s, tok, U32.to_f32(t)), slot, U32.to_f32(slot1)), npos, U32.to_f32(live)))

# the logits after the tokens fed so far
def dd.logits(+k: Dd, s: Array<F32>) -> Array<F32> & List<&2, F32>:
  match k:
    case Dd{c, p, +st0, stn, +tok, +slot, +npos, lg, v, +ctx, dp, f, h}:
      Io.get(U32.to_nat(v), P.run(h, s), lg)

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
