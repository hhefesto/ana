import Base
import ./Tensor.bend as T
import ./Ops.bend as O
import ./Config.bend as C
import ./Bytes.bend as B

# The hybrid decoder: weights, their loader, and the incremental decode step
# (master: backend/futhark/model.fut decode_step_def, Layout.hs namedLayout).
#
# A d-vector is a depth-D tree (D = depth d), and when the head dimension
# is a power of two its subtrees k = D - depth(hd) levels down are exactly
# the heads, so every per-head operation is a descent of k levels.

type Block is Data:
  GlaB{rms_att: T.V, wq: T.M, wk: T.M, wv: T.M, wo: T.M, walpha: T.M,
       lam: T.V, rms_ff: T.V, wgate: T.M, wup: T.M, wdown: T.M}
  SmB{rms_att: T.V, wq: T.M, wk: T.M, wv: T.M, wo: T.M, gq: T.V, gk: T.V,
      sink: T.V, rms_ff: T.V, wgate: T.M, wup: T.M, wdown: T.M}

type Weights is Data:
  Weights{emb: T.M, blocks: List<&2, Block>, final: T.V, unemb: T.M}

# Per-head matrices: the GLA state of one layer is a [hd][hd] matrix per
# head, laid out on the same k-level head tree as a d-vector.
type HM is Data:
  HZ{}
  HL{m: T.M}
  HN{l: HM, r: HM}

# One layer's decode state: the GLA recurrent state, or the softmax
# layer's ring-buffer K/V cache (ctx slots of d-vectors, MZ where empty).
type LState is Data:
  GlaS{s: HM}
  SmS{k: T.M, v: T.M}

# Shapes, derived once from the config.
type Dims is Data:
  Dims{d: Nat, f: Nat, hd: Nat, k: Nat, dd: Nat, df: Nat, dhd: Nat, dc: Nat,
       dv: Nat, h: Nat, dh: Nat, ctx: Nat, rglru: Bool, qk: Bool, sinks: Bool}

def Dims.of(+c: C.Config) -> Dims:
  +d = C.Config.d(c)
  +hd = C.Config.hd(c)
  +dd = T.depth(d)
  +dhd = T.depth(hd)
  +h = C.Config.heads(c)
  +ctx = C.Config.ctx(c)
  Dims{d, C.Config.f(c), hd, Nat.sub(dd, dhd), dd, T.depth(C.Config.f(c)), dhd,
       T.depth(ctx), T.depth(C.Config.vocab(c)), h, T.depth(h), ctx,
       C.Config.rglru(c), C.Config.qk(c), C.Config.sinks(c)}

def Dims.d(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x0

def Dims.f(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x1

def Dims.hd(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x2

def Dims.k(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x3

def Dims.dd(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x4

def Dims.df(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x5

def Dims.dhd(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x6

def Dims.dc(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x7

def Dims.dv(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x8

def Dims.h(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x9

def Dims.dh(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x10

def Dims.ctx(+dm: Dims) -> Nat:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x11

def Dims.rglru(+dm: Dims) -> Bool:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x12

def Dims.qk(+dm: Dims) -> Bool:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x13

def Dims.sinks(+dm: Dims) -> Bool:
  match dm:
    case Dims{x0, x1, x2, x3, x4, x5, x6, x7, x8, x9, x10, x11, x12, x13, x14}:
      x14

# Loading ------------------------------------------------------------------
#
# The parameter vector is read slice by slice in namedLayout order, each
# slice straight into its tree; no flat copy of the parameters exists.

def Load.vec(+n: Nat) -> B.Load(T.V):
  do B.Load<T.V>:
    xs : List<&2, F32> <- B.Load.f32s(n)
    return T.V.build(T.depth(n), xs)

# Rows are read a chunk at a time (up to 64 rows), split into per-row byte
# lists, arranged as a tree, and decoded to vectors in parallel -- the file
# read is sequential, the decode is fork-join.

type RowSplit is Data:
  RowSplit{head: List<&2, U32>, rest: List<&2, U32>}

def RowSplit.put(h: U32, r: RowSplit) -> RowSplit:
  match r:
    case RowSplit{a, b}:
      RowSplit{h <> a, b}

def RowSplit.of(+k: Nat, xs: List<&2, U32>) -> RowSplit:
  match k xs:
    case 0n _:
      RowSplit{Nil{}, xs}
    case 1n+p h <> t:
      RowSplit.put(h, RowSplit.of(p, t))
    case 1n+p Nil{}:
      RowSplit{Nil{}, Nil{}}

def RowSplit.head(r: RowSplit) -> List<&2, U32>:
  match r:
    case RowSplit{a, b}:
      a

def RowSplit.rest(r: RowSplit) -> List<&2, U32>:
  match r:
    case RowSplit{a, b}:
      b

def rows.split(k: Nat, +w: Nat, xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      +sp = RowSplit.of(w, xs)
      RowSplit.head(sp) <> rows.split(p, w, RowSplit.rest(sp))

# a tree of row byte lists, the shape of the matrix chunk
type BT is Data:
  BZ{}
  BL{xs: List<&2, U32>}
  BN{l: BT, r: BT}

def BT.leaves(rs: List<&2, List<&2, U32>>) -> List<&2, BT>:
  match rs:
    case Nil{}:
      Nil{}
    case h <> t:
      BL{h} <> BT.leaves(t)

def BT.pairs(bs: List<&2, BT>) -> List<&2, BT>:
  match bs:
    case a <> b <> t:
      BN{a, b} <> BT.pairs(t)
    case a <> Nil{}:
      [BN{a, BZ{}}]
    case Nil{}:
      Nil{}

def BT.first(bs: List<&2, BT>) -> BT:
  match bs:
    case h <> t:
      h
    case Nil{}:
      BZ{}

def BT.rounds(d: Nat, bs: List<&2, BT>) -> BT:
  match d:
    case 0n:
      BT.first(bs)
    case 1n+p:
      BT.rounds(p, BT.pairs(bs))

# decode every row of the chunk in parallel
def BT.decode(+dc: Nat, t: BT) -> T.M:
  match t:
    case BL{xs}:
      T.ML{T.V.build(dc, B.Bytes.f32s(xs))}
    case BN{l, r}:
      a b = BT.decode(dc, l) BT.decode(dc, r)
      T.MN{a, b}
    case BZ{}:
      T.MZ{}

def Load.chunks(n: Nat, +left: Nat, +k: Nat, +kc: Nat, +c: Nat) -> B.Load(List<&2, T.M>):
  match n:
    case 0n:
      B.Load.pure(List<&2, T.M>, Nil{})
    case 1n+p:
      +here = Nat.min(k, left)
      do B.Load<List<&2, T.M>>:
        bytes : List<&2, U32> <- B.Load.bytes(Nat.mul(here, Nat.mul(4n, c)))
        +m : T.M = BT.decode(T.depth(c), BT.rounds(kc, BT.leaves(rows.split(here, Nat.mul(4n, c), bytes))))
        rest : List<&2, T.M> <- Load.chunks(p, Nat.sub(left, here), k, kc, c)
        return m <> rest

def Load.row(+cols: Nat, +dc: Nat) -> B.Load(T.V):
  do B.Load<T.V>:
    xs : List<&2, F32> <- B.Load.f32s(cols)
    return T.V.build(dc, xs)

def Load.rows(r: Nat, +cols: Nat, +dc: Nat) -> B.Load(List<&2, T.V>):
  match r:
    case 0n:
      B.Load.pure(List<&2, T.V>, Nil{})
    case 1n+p:
      do B.Load<List<&2, T.V>>:
        row : T.V <- Load.row(cols, dc)
        rest : List<&2, T.V> <- Load.rows(p, cols, dc)
        return row <> rest

def Load.mat(+r: Nat, +c: Nat) -> B.Load(T.M):
  do B.Load<T.M>:
    rows : List<&2, T.V> <- Load.rows(r, c, T.depth(c))
    return T.M.build(T.depth(r), rows)

def Load.maybe_vec(b: Bool, +n: Nat) -> B.Load(T.V):
  match b:
    case True{}:
      Load.vec(n)
    case False{}:
      B.Load.pure(T.V, T.VZ{})

def Load.block.gla(+c: C.Config) -> B.Load(Block):
  +d = C.Config.d(c)
  +f = C.Config.f(c)
  do B.Load<Block>:
    ra : T.V <- Load.vec(d)
    wq : T.M <- Load.mat(d, d)
    wk : T.M <- Load.mat(d, d)
    wv : T.M <- Load.mat(d, d)
    wo : T.M <- Load.mat(d, d)
    wa : T.M <- Load.mat(d, d)
    lam : T.V <- Load.maybe_vec(C.Config.rglru(c), d)
    rf : T.V <- Load.vec(d)
    wg : T.M <- Load.mat(f, d)
    wu : T.M <- Load.mat(f, d)
    wd : T.M <- Load.mat(d, f)
    return GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}

def Load.block.sm(+c: C.Config) -> B.Load(Block):
  +d = C.Config.d(c)
  +f = C.Config.f(c)
  +hd = C.Config.hd(c)
  do B.Load<Block>:
    ra : T.V <- Load.vec(d)
    wq : T.M <- Load.mat(d, d)
    wk : T.M <- Load.mat(d, d)
    wv : T.M <- Load.mat(d, d)
    wo : T.M <- Load.mat(d, d)
    gq : T.V <- Load.maybe_vec(C.Config.qk(c), hd)
    gk : T.V <- Load.maybe_vec(C.Config.qk(c), hd)
    sk : T.V <- Load.maybe_vec(C.Config.sinks(c), C.Config.heads(c))
    rf : T.V <- Load.vec(d)
    wg : T.M <- Load.mat(f, d)
    wu : T.M <- Load.mat(f, d)
    wd : T.M <- Load.mat(d, f)
    return SmB{ra, wq, wk, wv, wo, gq, gk, sk, rf, wg, wu, wd}

def Load.block(+c: C.Config, k: C.LayerKind) -> B.Load(Block):
  match k:
    case C.Gla{}:
      Load.block.gla(c)
    case C.Softmax{}:
      Load.block.sm(c)

# blocks i .. i+n-1
def Load.blocks(n: Nat, +c: C.Config, +i: Nat) -> B.Load(List<&2, Block>):
  match n:
    case 0n:
      B.Load.pure(List<&2, Block>, Nil{})
    case 1n+p:
      do B.Load<List<&2, Block>>:
        b : Block <- Load.block(c, C.kind_of(i))
        rest : List<&2, Block> <- Load.blocks(p, c, 1n+i)
        return b <> rest

def Load.unemb(untied: Bool, +c: C.Config) -> B.Load(T.M):
  match untied:
    case True{}:
      Load.mat(C.Config.vocab(c), C.Config.d(c))
    case False{}:
      B.Load.pure(T.M, T.MZ{})

# After the manifest: the Word64 parameter count, then the parameters.
def Load.weights(+c: C.Config) -> B.Load(Weights):
  do B.Load<Weights>:
    n : Nat <- B.Load.nat()
    emb : T.M <- Load.mat(C.Config.vocab(c), C.Config.d(c))
    blocks : List<&2, Block> <- Load.blocks(C.Config.layers(c), c, 0n)
    fin : T.V <- Load.vec(C.Config.d(c))
    un : T.M <- Load.unemb(Bool.not(C.Config.tied(c)), c)
    return Weights{emb, blocks, fin, un}

# State ------------------------------------------------------------------

def HM.zero(+k: Nat, +dhd: Nat, +hd: Nat, +heads: Nat) -> HM:
  match k heads:
    case _ 0n:
      HZ{}
    case 0n 1n+q:
      HL{T.M.of_list(dhd, List.replicate(T.V, hd, T.V.fill(dhd, hd, 0.0)))}
    case 1n+p 1n+q:
      +half = Nat.pow(2n, p)
      l r = HM.zero(p, dhd, hd, Nat.min(1n+q, half)) HM.zero(p, dhd, hd, Nat.sub(1n+q, half))
      HN{l, r}

def LState.zero(kind: C.LayerKind, +dm: Dims) -> LState:
  match kind:
    case C.Gla{}:
      GlaS{HM.zero(Dims.k(dm), Dims.dhd(dm), Dims.hd(dm), Dims.h(dm))}
    case C.Softmax{}:
      SmS{T.MZ{}, T.MZ{}}

def states.zero(n: Nat, +dm: Dims, +i: Nat) -> List<&2, LState>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      LState.zero(C.kind_of(i), dm) <> states.zero(p, dm, 1n+i)

# GLA ------------------------------------------------------------------
#
# S' = diag(alpha) S + (beta k^) v^T per head, o = q^T S'
# (the recurrent form; Attention/Linear's stepGLA).

# one head: rows c of S decay by alpha_c and gain khat_c * v
def gla.rows(+s: T.M, +alpha: T.V, +khat: T.V, +v: T.V) -> T.M:
  match s alpha khat:
    case T.ML{row} T.VL{a} T.VL{kc}:
      T.ML{T.V.add(T.V.scale(a, row), T.V.scale(kc, v))}
    case T.MN{sl, sr} T.VN{al, ar} T.VN{kl, kr}:
      x y = gla.rows(sl, al, kl, v) gla.rows(sr, ar, kr, v)
      T.MN{x, y}
    case _ _ _:
      T.MZ{}

def gla.state(+k: Nat, +s: HM, +alpha: T.V, +khat: T.V, +v: T.V) -> HM:
  match k s alpha khat v:
    case 0n HL{m} _ _ _:
      HL{gla.rows(m, alpha, khat, v)}
    case 1n+p HN{sl, sr} T.VN{al, ar} T.VN{kl, kr} T.VN{vl, vr}:
      x y = gla.state(p, sl, al, kl, vl) gla.state(p, sr, ar, kr, vr)
      HN{x, y}
    case _ _ _ _ _:
      HZ{}

def gla.out(+k: Nat, +s: HM, +q: T.V) -> T.V:
  match k s q:
    case 0n HL{m} _:
      T.M.vecmat(q, m)
    case 1n+p HN{sl, sr} T.VN{ql, qr}:
      x y = gla.out(p, sl, ql) gla.out(p, sr, qr)
      T.VN{x, y}
    case _ _ _:
      T.VZ{}

# the gate and scaled key: (alpha, beta k^)
type Gate is Data:
  Gate{alpha: T.V, khat: T.V}

def gla.gate(g: Bool, +z: T.V, +lam: T.V, +khat0: T.V) -> Gate:
  match g:
    case True{}:
      +la = T.V.zip(~O.rglru_log_gate.t, z, lam)
      Gate{T.V.map(~F32.exp, la), T.V.zip(~O.scale_by_write.t, la, khat0)}
    case False{}:
      Gate{T.V.map(~O.sigmoid.t, z), khat0}

# Softmax attention over the ring buffer ---------------------------------

type MP is Data:
  MP{go: T.M, keep: T.M}

# the subtree on the path, beside the one left alone
def M.split(l: T.M, r: T.M, right: Bool) -> MP:
  match right:
    case True{}:
      MP{r, l}
    case False{}:
      MP{l, r}

def M.join(right: Bool, go: T.M, keep: T.M) -> T.M:
  match right:
    case True{}:
      T.MN{keep, go}
    case False{}:
      T.MN{go, keep}

def M.kids(m: T.M) -> MP:
  match m:
    case T.MN{l, r}:
      MP{l, r}
    case _:
      MP{T.MZ{}, T.MZ{}}

def MP.go(p: MP) -> T.M:
  match p:
    case MP{g, k}:
      g

def MP.keep(p: MP) -> T.M:
  match p:
    case MP{g, k}:
      k

def M.set.step(+p: MP, +right: Bool) -> MP:
  match p:
    case MP{l, r}:
      M.split(l, r, right)

# row i of a depth-d matrix replaced (slots grow from MZ as needed)
def M.set(+d: Nat, +m: T.M, +i: U32, +row: T.V) -> T.M:
  match d:
    case 0n:
      T.ML{row}
    case 1n+p:
      +right = T.bit(i, p)
      +sp = M.set.step(M.kids(m), right)
      M.join(right, M.set(p, MP.go(sp), i, row), MP.keep(sp))

def inv_sqrt(+hd: Nat) -> F32:
  F32.div(1.0, F32.sqrt(F32.from_nat(hd)))

def head_dot(+a: T.V, +b: T.V) -> F32:
  T.V.dot(a, b)

# per slot, the per-head scores q_h . k_h / sqrt(hd): a tree over slots of
# depth-k head vectors, MZ where the slot is empty
def sm.scores(+k: Nat, +sc: F32, +q: T.V, +cache: T.M) -> T.M:
  match cache:
    case T.ML{row}:
      T.ML{T.V.scale(sc, O.heads.red2(~head_dot, k, q, row))}
    case T.MN{l, r}:
      x y = sm.scores(k, sc, q, l) sm.scores(k, sc, q, r)
      T.MN{x, y}
    case T.MZ{}:
      T.MZ{}

def V.maxpad(+a: T.V, +b: T.V) -> T.V:
  match a b:
    case T.VZ{} _:
      b
    case _ T.VZ{}:
      a
    case _ _:
      T.V.zip(~O.max.t, a, b)

# per-head maximum over slots
def sm.max(+s: T.M) -> T.V:
  match s:
    case T.ML{row}:
      row
    case T.MN{l, r}:
      x y = sm.max(l) sm.max(r)
      V.maxpad(x, y)
    case T.MZ{}:
      T.VZ{}

def sub_exp(+m: F32, +x: F32) -> F32:
  F32.exp(F32.sub(x, m))

def V.sub_exp(+m: T.V, +x: T.V) -> T.V:
  T.V.zip(~(a => b => F32.exp(F32.sub(b, a))), m, x)

# per slot, exp(score - max)
def sm.exps(+m: T.V, +s: T.M) -> T.M:
  match s:
    case T.ML{row}:
      T.ML{V.sub_exp(m, row)}
    case T.MN{l, r}:
      x y = sm.exps(m, l) sm.exps(m, r)
      T.MN{x, y}
    case T.MZ{}:
      T.MZ{}

def sm.sum(+s: T.M) -> T.V:
  match s:
    case T.ML{row}:
      row
    case T.MN{l, r}:
      x y = sm.sum(l) sm.sum(r)
      T.V.add.pad(x, y)
    case T.MZ{}:
      T.VZ{}

def head_scale(+c: F32, +x: T.V) -> T.V:
  T.V.scale(c, x)

# sum over slots of per-head weights times the cached values
def sm.mix(+k: Nat, +w: T.M, +vc: T.M) -> T.V:
  match w vc:
    case T.ML{wr} T.ML{vr}:
      O.heads.with(~head_scale, k, wr, vr)
    case T.MN{wl, wr} T.MN{vl, vr}:
      x y = sm.mix(k, wl, vl) sm.mix(k, wr, vr)
      T.V.add.pad(x, y)
    case _ _:
      T.VZ{}

def V.div(+a: T.V, +b: T.V) -> T.V:
  T.V.zip(~F32.div, a, b)

# attention of one query over the cache, with per-head sink logits whose
# weight is dropped from the value sum (Attention/Sink)
def sm.sink_exp(+m: T.V, +sink: T.V) -> T.V:
  match sink:
    case T.VZ{}:
      T.VZ{}
    case _:
      V.sub_exp(m, sink)

def sm.attend(+k: Nat, +sc: F32, +q: T.V, +kc: T.M, +vc: T.M, +sink: T.V) -> T.V:
  +s = sm.scores(k, sc, q, kc)
  +m = V.maxpad(sm.max(s), sink)
  +e = sm.exps(m, s)
  +denom = T.V.add.pad(sm.sum(e), sm.sink_exp(m, sink))
  O.heads.with(~head_scale, k, T.V.map(~(x => F32.div(1.0, x)), denom), sm.mix(k, e, vc))

def gain_or(qk: Bool, +g: T.V) -> T.V:
  match qk:
    case True{}:
      T.V.map(~O.one_plus.t, g)
    case False{}:
      T.VZ{}

def qk.apply(qk: Bool, +k: Nat, +hd: Nat, +g: T.V, +x: T.V) -> T.V:
  match qk:
    case True{}:
      O.qk_heads(k, F32.from_nat(hd), T.V.map(~O.one_plus.t, g), x)
    case False{}:
      x

# Blocks -------------------------------------------------------------------

def tail(+dm: Dims, +x: T.V, +att: T.V, +wo: T.M, +rf: T.V, +wg: T.M, +wu: T.M, +wd: T.M) -> T.V:
  +xa = T.V.add(x, T.M.matvec(wo, att))
  +nrm = O.rms_norm(F32.from_nat(Dims.d(dm)), xa, rf)
  gu gv = T.M.matvec(wg, nrm) T.M.matvec(wu, nrm)
  T.V.add(xa, T.M.matvec(wd, T.V.zip(~O.silu_mul.t, gu, gv)))

# A layer's step: the new residual stream and the new state.
type Step is Data:
  Step{x: T.V, st: LState}

def block.gla.fin(+dm: Dims, +x: T.V, +wo: T.M, +rf: T.V, +wg: T.M, +wu: T.M, +wd: T.M,
                  +k: Nat, +s: HM, +qh: T.V, +vv: T.V, gt: Gate) -> Step:
  match gt:
    case Gate{+alpha, +khat}:
      +s2 = gla.state(k, s, alpha, khat, vv)
      Step{tail(dm, x, gla.out(k, s2, qh), wo, rf, wg, wu, wd), GlaS{s2}}

def block.gla(+dm: Dims, +x: T.V, +b: Block, +s: HM) -> Step:
  match b:
    case GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      +k = Dims.k(dm)
      +g = Dims.rglru(dm)
      +nrm = O.rms_norm(F32.from_nat(Dims.d(dm)), x, ra)
      qv kv = T.M.matvec(wq, nrm) T.M.matvec(wk, nrm)
      vv zv = T.M.matvec(wv, nrm) T.M.matvec(wa, nrm)
      +qh = O.l2_heads(k, qv)
      block.gla.fin(dm, x, wo, rf, wg, wu, wd, k, s, qh, vv, gla.gate(g, zv, lam, O.l2_heads(k, kv)))
    case _:
      Step{x, GlaS{s}}

def block.sm(+dm: Dims, +x: T.V, +b: Block, +kc: T.M, +vc: T.M, +slot: U32) -> Step:
  match b:
    case SmB{ra, wq, wk, wv, wo, gq, gk, sink, rf, wg, wu, wd}:
      +hd = Dims.hd(dm)
      +k = Dims.k(dm)
      +dc = Dims.dc(dm)
      +q = Dims.qk(dm)
      +nrm = O.rms_norm(F32.from_nat(Dims.d(dm)), x, ra)
      qv kv = T.M.matvec(wq, nrm) T.M.matvec(wk, nrm)
      +vv = T.M.matvec(wv, nrm)
      +qa = qk.apply(q, k, hd, gq, qv)
      +ks = qk.apply(q, k, hd, gk, kv)
      +kc2 = M.set(dc, kc, slot, ks)
      +vc2 = M.set(dc, vc, slot, vv)
      +att = sm.attend(k, inv_sqrt(hd), qa, kc2, vc2, sink)
      Step{tail(dm, x, att, wo, rf, wg, wu, wd), SmS{kc2, vc2}}
    case _:
      Step{x, SmS{kc, vc}}

def block(+dm: Dims, +x: T.V, +b: Block, +st: LState, +slot: U32) -> Step:
  match st:
    case GlaS{s}:
      block.gla(dm, x, b, s)
    case SmS{kc, vc}:
      block.sm(dm, x, b, kc, vc, slot)

# The stack: thread the residual stream through every block, collecting the
# new states in order.
type Run is Data:
  Run{x: T.V, sts: List<&2, LState>}

def Run.cons(st: LState, r: Run) -> Run:
  match r:
    case Run{x, sts}:
      Run{x, st <> sts}

def Step.x(+s: Step) -> T.V:
  match s:
    case Step{x, st}:
      x

def Step.st(+s: Step) -> LState:
  match s:
    case Step{x, st}:
      st

def stack(bs: List<&2, Block>, sts: List<&2, LState>, +dm: Dims, +x: T.V, +slot: U32) -> Run:
  match bs sts:
    case b <> bt st <> stt:
      +stp = block(dm, x, b, st, slot)
      Run.cons(Step.st(stp), stack(bt, stt, dm, Step.x(stp), slot))
    case _ _:
      Run{x, Nil{}}

# Decode ------------------------------------------------------------------

type Out is Data:
  Out{logits: T.V, sts: List<&2, LState>}

def head.m(tied: Bool, +emb: T.M, +un: T.M) -> T.M:
  match tied:
    case True{}:
      emb
    case False{}:
      un

# One decode step at `position` for `token`: the next-token logits and
# the advanced states (decode_step_def).
def decode.fin(+dm: Dims, +w: Weights, r: Run) -> Out:
  match w r:
    case Weights{+emb, bs, fin, +un} Run{x, sts}:
      Out{T.M.matvec(head.m(T.M.is_z(un), emb, un), O.rms_norm(F32.from_nat(Dims.d(dm)), x, fin)), sts}

def decode(+dm: Dims, +w: Weights, sts: List<&2, LState>, +position: Nat, +token: U32) -> Out:
  match w:
    case Weights{+emb, +bs, fin, un}:
      +x0 = T.M.row(Dims.dv(dm), emb, token)
      decode.fin(dm, Weights{emb, bs, fin, un}, stack(bs, sts, dm, x0, U32.from_nat(Nat.mod(position, Dims.ctx(dm)))))

def Weights.emb(+w: Weights) -> T.M:
  match w:
    case Weights{e, b, f, u}:
      e

# Per-head matrix algebra for the GLA pullback -----------------------------

# dS + q do^T per head
def HM.outer_add(+k: Nat, +s: HM, +q: T.V, +d: T.V) -> HM:
  match k s q d:
    case 0n HL{m} _ _:
      HL{T.M.add(m, T.M.outer(q, d))}
    case 0n HZ{} _ _:
      HL{T.M.outer(q, d)}
    case 1n+p HN{sl, sr} T.VN{ql, qr} T.VN{dl, dr}:
      HN{HM.outer_add(p, sl, ql, dl), HM.outer_add(p, sr, qr, dr)}
    case 1n+p HZ{} T.VN{ql, qr} T.VN{dl, dr}:
      HN{HM.outer_add(p, HZ{}, ql, dl), HM.outer_add(p, HZ{}, qr, dr)}
    case _ _ _ _:
      HZ{}

# S x per head (rows of S against the head slice of x)
def HM.matvec(+k: Nat, +s: HM, +x: T.V) -> T.V:
  match k s x:
    case 0n HL{m} _:
      T.M.matvec(m, x)
    case 1n+p HN{sl, sr} T.VN{xl, xr}:
      T.VN{HM.matvec(p, sl, xl), HM.matvec(p, sr, xr)}
    case _ _ _:
      T.VZ{}

# x^T S per head
def HM.vecmat(+k: Nat, +x: T.V, +s: HM) -> T.V:
  match k x s:
    case 0n _ HL{m}:
      T.M.vecmat(x, m)
    case 1n+p T.VN{xl, xr} HN{sl, sr}:
      T.VN{HM.vecmat(p, xl, sl), HM.vecmat(p, xr, sr)}
    case _ _ _:
      T.VZ{}

def HM.rowdots(+k: Nat, +a: HM, +b: HM) -> T.V:
  match k a b:
    case 0n HL{x} HL{y}:
      T.M.rowdots(x, y)
    case 1n+p HN{al, ar} HN{bl, br}:
      T.VN{HM.rowdots(p, al, bl), HM.rowdots(p, ar, br)}
    case _ _ _:
      T.VZ{}

def HM.scale_rows(+k: Nat, +s: T.V, +a: HM) -> HM:
  match k s a:
    case 0n _ HL{m}:
      HL{T.M.scale_rows(s, m)}
    case 1n+p T.VN{sl, sr} HN{al, ar}:
      HN{HM.scale_rows(p, sl, al), HM.scale_rows(p, sr, ar)}
    case _ _ _:
      HZ{}
