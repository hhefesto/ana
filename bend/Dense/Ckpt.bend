import Base
import ../Num.bend as N
import ../Bytes.bend as B
import ../Config.bend as C
import ../Checkpoint.bend as K
import ./Ex.bend as X
import ./Op.bend as P
import ./Layout.bend as L

# FTC2 (master's compact checkpoint, Checkpoint.bend) to and from the dense
# store. Master's parameter vector is namedLayout order with every matrix
# [out][in] row-major, which is the store's own order from 0 (Layout.bend),
# so parameters, the first moment and the second moment are flat copies of
# the file into [0, P), [m, m + P) and [v, v + P). Muon's momentum lives in
# the store's m cells of the matrices Muon owns (Step.bend); master keeps it
# in a vector of its own, so a load reads those matrices' momentum over m
# and a save splits m back into master's two vectors.
#
# A file is laid out, from the header's end h (4 bytes of magic + the
# manifest):
#
#   h        count P (u64), P f32          parameters
#   h+8+4P   step (i64), count P, P f32    Adam step, first moment
#   ...      count P, P f32                second moment
#   ...      flag (1 byte) [count P, P f32] Muon momentum when the flag is 1
#   ...      best validation loss, PRNG    kept byte for byte
#
# The header and the tail are copied verbatim into every save, so a saved
# file is a checkpoint of the same run (master's resume reads it) at a
# later step.

type Rg is Data:
  Rg{off: U32, n: U32}

def Manifest.version(+m: K.Manifest) -> U32:
  match m:
    case K.Manifest{v, c, n, l, lv, a, mu, mi, ti, di, cl, nu}:
      v

# the matrices Muon owns, in store order (Step.bend mat)
def owned.gla(+bp: L.BP, +d: U32, +ff: U32) -> List<&2, Rg>:
  +dd = U32.mul(d, d)
  +fd = U32.mul(ff, d)
  [Rg{L.BP.wq(bp), dd}, Rg{L.BP.wk(bp), dd}, Rg{L.BP.wv(bp), dd}, Rg{L.BP.wo(bp), dd}, Rg{L.BP.wa(bp), dd},
   Rg{L.BP.wg(bp), fd}, Rg{L.BP.wu(bp), fd}, Rg{L.BP.wd(bp), fd}]

def owned.sm(+bp: L.BP, +d: U32, +ff: U32) -> List<&2, Rg>:
  +dd = U32.mul(d, d)
  +fd = U32.mul(ff, d)
  [Rg{L.BP.wq(bp), dd}, Rg{L.BP.wk(bp), dd}, Rg{L.BP.wv(bp), dd}, Rg{L.BP.wo(bp), dd},
   Rg{L.BP.wg(bp), fd}, Rg{L.BP.wu(bp), fd}, Rg{L.BP.wd(bp), fd}]

def owned(bs: List<&2, L.BP>, +m: L.Dm) -> List<&2, Rg>:
  match bs:
    case Nil{}:
      Nil{}
    case +bp <> t:
      List.append(&2, Rg, Bool.pick(List<&2, Rg>, L.BP.gla(bp), owned.gla(bp, L.Dm.d(m), L.Dm.f(m)), owned.sm(bp, L.Dm.d(m), L.Dm.f(m))),
        owned(t, m))

# Offsets ------------------------------------------------------------------

type Off is Data:
  Off{par: U32, stp: U32, fm: U32, sm: U32, flag: U32}

# from the header's end h and the count p
def Off.of(+h: U32, +p: U32) -> Off:
  +b = U32.mul(4, p)
  +par = U32.add(h, 8)
  +stp = U32.add(par, b)
  +fm = U32.add(stp, 16)
  +sm = U32.add(U32.add(fm, b), 8)
  Off{par, stp, fm, sm, U32.add(sm, b)}

def Off.par(+o: Off) -> U32:
  match o:
    case Off{a, b, c, d, e}:
      a

def Off.stp(+o: Off) -> U32:
  match o:
    case Off{a, b, c, d, e}:
      b

def Off.fm(+o: Off) -> U32:
  match o:
    case Off{a, b, c, d, e}:
      c

def Off.sm(+o: Off) -> U32:
  match o:
    case Off{a, b, c, d, e}:
      d

def Off.flag(+o: Off) -> U32:
  match o:
    case Off{a, b, c, d, e}:
      e

# where the tail starts: after the momentum when there is one
def Off.tail(+o: Off, +p: U32, mom: Bool) -> U32:
  match mom:
    case True{}:
      U32.add(U32.add(Off.flag(o), 9), U32.mul(4, p))
    case False{}:
      U32.add(Off.flag(o), 1)

# Bytes --------------------------------------------------------------------

def u32.bytes(+x: U32) -> List<&2, U32>:
  [U32.div(x, 16777216), U32.mod(U32.div(x, 65536), 256), U32.mod(U32.div(x, 256), 256), U32.mod(x, 256)]

# a count or step below 2^32 as a big-endian 64-bit word
def u64.bytes(+x: U32) -> List<&2, U32>:
  List.append(&2, U32, [0, 0, 0, 0], u32.bytes(x))

def lo.of(xs: List<&2, U32>) -> U32:
  match xs:
    case a <> b <> c <> d <> e <> f <> g <> h <> t:
      N.be32(e, f, g, h)
    case _:
      0

def hi.of(xs: List<&2, U32>) -> U32:
  match xs:
    case a <> b <> c <> d <> t:
      N.be32(a, b, c, d)
    case _:
      0

def byte0(xs: List<&2, U32>) -> U32:
  match xs:
    case a <> t:
      a
    case _:
      0

# Reading ------------------------------------------------------------------

law Got:
  Type

def Got():
  File & Result<&1, &1, U32 & String, List<&2, U32>>

def at.fin(r: Got()) -> IO(File & List<&2, U32>):
  (f, e) = r
  do IO<File & List<&2, U32>>:
    xs : List<&2, U32> <- IO.pass(List<&2, U32>, e)
    return (f, xs)

def at.cons(acc: List<&2, List<&2, U32>>, r: File & List<&2, U32>) -> File & List<&2, List<&2, U32>>:
  (f, xs) = r
  (f, xs <> acc)

def at.one(+o: U32, +n: U32, st: File & List<&2, List<&2, U32>>) -> IO(File & List<&2, List<&2, U32>>):
  (f, acc) = st
  do IO<File & List<&2, List<&2, U32>>>:
    g : Got() <- File.read_at(f, o, n)
    r : File & List<&2, U32> <- at.fin(g)
    return at.cons(acc, r)

# the byte ranges' contents, newest first
def ats(rs: List<&2, Rg>, st: File & List<&2, List<&2, U32>>) -> IO(File & List<&2, List<&2, U32>>):
  match rs:
    case Nil{}:
      IO.pure(File & List<&2, List<&2, U32>>, st)
    case Rg{+o, +n} <> +rest:
      do IO<File & List<&2, List<&2, U32>>>:
        t : File & List<&2, List<&2, U32>> <- at.one(o, n, st)
        ats(rest, t)

law Put:
  Type

def Put():
  File & Array<F32> & Result<&1, &1, U32 & String, Unit>

def rd.fin(r: Put()) -> IO(File & Array<F32>):
  (f, s, e) = r
  do IO<File & Array<F32>>:
    u : Unit <- IO.pass(Unit, e)
    return (f, s)

type Rd is Data:
  Rd{off: U32, n: U32, at: U32}

def rd.one(+o: U32, +n: U32, +a: U32, fs: File & Array<F32>) -> IO(File & Array<F32>):
  (f, s) = fs
  do IO<File & Array<F32>>:
    r : Put() <- File.read_f32be(f, o, n, s, a)
    rd.fin(r)

# each (file offset, count, store index): count f32 from the file into the store
def rds(rs: List<&2, Rd>, fs: File & Array<F32>) -> IO(File & Array<F32>):
  match rs:
    case Nil{}:
      IO.pure(File & Array<F32>, fs)
    case Rd{+o, +n, +a} <> rest:
      do IO<File & Array<F32>>:
        t : File & Array<F32> <- rd.one(o, n, a, fs)
        rds(rest, t)

# the momentum of each owned matrix over its m cells
def mom.rds(rs: List<&2, Rg>, +mo: U32, +m: U32) -> List<&2, Rd>:
  match rs:
    case Nil{}:
      Nil{}
    case Rg{+o, +n} <> t:
      Rd{U32.add(mo, U32.mul(4, o)), n, U32.add(m, o)} <> mom.rds(t, mo, m)

# What the loader learned beside the store: the header and tail bytes (for
# saves), the completed step, whether momentum was read, and the manifest.
type Src is Data:
  Src{head: List<&2, U32>, tail: List<&2, U32>, step: Nat, mom: Bool, man: K.Manifest}

def Src.step(+s: Src) -> Nat:
  match s:
    case Src{h, t, st, mo, ma}:
      st

def Src.head(+s: Src) -> List<&2, U32>:
  match s:
    case Src{h, t, st, mo, ma}:
      h

def Src.tail(+s: Src) -> List<&2, U32>:
  match s:
    case Src{h, t, st, mo, ma}:
      t

def Src.mom(+s: Src) -> Bool:
  match s:
    case Src{h, t, st, mo, ma}:
      mo

def Src.man(+s: Src) -> K.Manifest:
  match s:
    case Src{h, t, st, mo, ma}:
      ma

def Src.lr(+s: Src) -> F32:
  match s:
    case Src{h, t, st, mo, K.Manifest{v, c, n, l, lv, K.AdamW{lr, b1, b2, e, wd, w, tot}, mu, mi, ti, di, cl, nu}}:
      lr

def Src.warm(+s: Src) -> Nat:
  match s:
    case Src{h, t, st, mo, K.Manifest{v, c, n, l, lv, K.AdamW{lr, b1, b2, e, wd, w, tot}, mu, mi, ti, di, cl, nu}}:
      w

def Src.total(+s: Src) -> Nat:
  match s:
    case Src{h, t, st, mo, K.Manifest{v, c, n, l, lv, K.AdamW{lr, b1, b2, e, wd, w, tot}, mu, mi, ti, di, cl, nu}}:
      tot

def Src.wd(+s: Src) -> F32:
  match s:
    case Src{h, t, st, mo, K.Manifest{v, c, n, l, lv, K.AdamW{lr, b1, b2, e, wd, w, tot}, mu, mi, ti, di, cl, nu}}:
      wd

def Src.mu(+s: Src) -> F32:
  match s:
    case Src{h, t, st, mo, K.Manifest{v, c, n, l, lv, a, mu, mi, ti, di, cl, nu}}:
      Maybe.default(&2, F32, mu, 0.95)

def Src.clip(+s: Src) -> F32:
  match s:
    case Src{h, t, st, mo, K.Manifest{v, c, n, l, lv, a, mu, mi, ti, di, cl, nu}}:
      cl

def fail.if.go(+why: String, ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "checkpoint: " ++ why)

# stop with the reason unless it is empty
def fail.if(+why: String) -> IO(Unit):
  fail.if.go(why, String.is_empty(why))

# every count field must be P; empty when they are
def counts.problem(+p: U32, +cs: List<&2, U32>) -> String:
  match cs:
    case Nil{}:
      ""
    case +c <> t:
      K.check(U32.is_eq(c, p), "checkpoint vector length is not the parameter count", counts.problem(p, t))

def fin.src(+sp: Src, r: File & Array<F32>) -> IO(Array<F32> & Src):
  (f, s) = r
  do IO<Array<F32> & Src>:
    u : Unit <- File.close(f)
    return (s, sp)

# the arrays, once the small fields are known
def load.arrays(+path: String, +ly: L.Lay, +m: L.Dm, +o: Off, +p: U32, +sp: Src, s: Array<F32>) -> IO(Array<F32> & Src):
  +mz = L.Lay.m(ly)
  +mom = Bool.pick(List<&2, Rd>, Src.mom(sp), mom.rds(owned(L.Lay.blocks(ly), m), U32.add(Off.flag(o), 9), mz), Nil{})
  do IO<Array<F32> & Src>:
    f : File <- IO.try(File, File.open(path, "r"))
    r : File & Array<F32> <- rds(List.append(&2, Rd,
      [Rd{Off.par(o), p, 0}, Rd{Off.fm(o), p, mz}, Rd{Off.sm(o), p, L.Lay.v(ly)}], mom), (f, s))
    fin.src(sp, r)

def load.tail(+path: String, +ly: L.Lay, +m: L.Dm, +o: Off, +p: U32, +head: List<&2, U32>, +step: Nat, +mo: Bool,
              +man: K.Manifest, r: File & List<&2, List<&2, U32>>, s: Array<F32>) -> IO(Array<F32> & Src):
  (f, +xss) = r
  do IO<Array<F32> & Src>:
    u : Unit <- File.close(f)
    load.arrays(path, ly, m, o, p, Src{head, List.concat(&2, U32, List.reverse(&2, List<&2, U32>, xss)), step, mo, man}, s)

# (newest first) flag + momentum count; the v count; step + count; head:
# header + count
def load.small(xss: List<&2, List<&2, U32>>, +path: String, +ly: L.Lay, +m: L.Dm, +o: Off, +p: U32, +man: K.Manifest,
               f: File, s: Array<F32>) -> IO(Array<F32> & Src):
  match xss:
    case +fl <> +vc <> +mid <> +hd <> t:
      +mo = Bool.and(U32.is_eq(Manifest.version(man), 4), U32.is_eq(byte0(fl), 1))
      +cs = List.append(&2, U32, [lo.of(List.drop(&2, U32, hd, Nat.sub(List.length(&2, U32, hd), 8n))),
             lo.of(List.drop(&2, U32, mid, 8n)), lo.of(vc)],
             Bool.pick(List<&2, U32>, mo, [lo.of(List.drop(&2, U32, fl, 1n))], Nil{}))
      do IO<Array<F32> & Src>:
        u : Unit <- fail.if(counts.problem(p, cs))
        t2 : File & List<&2, List<&2, U32>> <- ats([Rg{Off.tail(o, p, mo), 4096}], (f, Nil{}))
        load.tail(path, ly, m, o, p, List.take(&2, U32, hd, Nat.sub(List.length(&2, U32, hd), 8n)),
          U32.to_nat(lo.of(mid)), mo, man, t2, s)
    case _:
      IO.die(Array<F32> & Src, 1, "checkpoint: short read")

def load.small0(+path: String, +ly: L.Lay, +m: L.Dm, +o: Off, +p: U32, +man: K.Manifest,
                r: File & List<&2, List<&2, U32>>, s: Array<F32>) -> IO(Array<F32> & Src):
  (f, xss) = r
  load.small(xss, path, ly, m, o, p, man, f, s)

def tok.problem(empty: Bool, +got: String, +want: String) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      K.check(String.eq(got, want), "checkpoint tokenizer identity is not TOKENIZER_FILE's", "")

# the store with the checkpoint's parameters and optimizer state, and what
# a save of the same run needs; man and h (the header's end) from `header`,
# tok the run's tokenizer identity (empty: not checked)
def load(+path: String, +man: K.Manifest, +h: Nat, +tok: String, +ly: L.Lay, +m: L.Dm, s: Array<F32>) -> IO(Array<F32> & Src):
  +p = L.Lay.params(ly)
  +hu = U32.from_nat(h)
  +o = Off.of(hu, p)
  do IO<Array<F32> & Src>:
    u1 : Unit <- fail.if(Bool.pick(String, U32.is_eq(Manifest.version(man), 4), K.Manifest.problem(man), ""))
    u2 : Unit <- fail.if(K.check(Nat.is_eq(C.Config.params(K.Manifest.cfg(man)), U32.to_nat(p)),
      "checkpoint parameter count is not the store's", ""))
    u3 : Unit <- fail.if(tok.problem(String.is_empty(tok), K.Manifest.tokenizer_id(man), tok))
    f : File <- IO.try(File, File.open(path, "r"))
    r : File & List<&2, List<&2, U32>> <- ats([Rg{0, U32.add(hu, 8)}, Rg{Off.stp(o), 16}, Rg{U32.sub(Off.sm(o), 8), 8},
      Rg{Off.flag(o), 9}], (f, Nil{}))
    load.small0(path, ly, m, o, p, man, r, s)

# Headers of both manifest versions. Version 3 (the v2-era runs: master's
# bpe100m final) has a six-field Config, no Muon field and no momentum flag
# in the body; master reads it as the arms-off Config (sigmoid gate, no qk
# norm, no sinks, tied head). Such a checkpoint is evaluated, not trained.

def Load.config6() -> B.Load(C.Config):
  do B.Load<C.Config>:
    v : Nat <- B.Load.nat()
    n : Nat <- B.Load.nat()
    d : Nat <- B.Load.nat()
    f : Nat <- B.Load.nat()
    l : Nat <- B.Load.nat()
    h : Nat <- B.Load.nat()
    return C.Config{v, n, d, f, l, h, False{}, False{}, False{}, True{}}

def Load.v3(+version: U32) -> B.Load(K.Manifest):
  do B.Load<K.Manifest>:
    cfg : C.Config <- Load.config6()
    count : Nat <- B.Load.nat()
    layout : String <- K.Load.string()
    lv : U32 <- B.Load.u32be()
    adamw : K.AdamW <- K.Load.adamw()
    mid : String <- K.Load.string()
    tid : String <- K.Load.string()
    did : String <- K.Load.string()
    clip : F32 <- K.Load.double()
    numerics : U32 <- B.Load.byte()
    return K.Manifest{version, cfg, count, layout, lv, adamw, None{}, mid, tid, did, clip, numerics}

def Load.v4(+version: U32) -> B.Load(K.Manifest):
  do B.Load<K.Manifest>:
    cfg : C.Config <- K.Load.config()
    count : Nat <- B.Load.nat()
    layout : String <- K.Load.string()
    lv : U32 <- B.Load.u32be()
    adamw : K.AdamW <- K.Load.adamw()
    muon : Maybe<&2, F32> <- K.Load.muon()
    mid : String <- K.Load.string()
    tid : String <- K.Load.string()
    did : String <- K.Load.string()
    clip : F32 <- K.Load.double()
    numerics : U32 <- B.Load.byte()
    return K.Manifest{version, cfg, count, layout, lv, adamw, muon, mid, tid, did, clip, numerics}

def Load.pick(v4: Bool, +version: U32) -> B.Load(K.Manifest):
  match v4:
    case True{}:
      Load.v4(version)
    case False{}:
      Load.v3(version)

def Load.header.go(magic: Bool) -> B.Load(K.Manifest):
  match magic:
    case True{}:
      do B.Load<K.Manifest>:
        +version : U32 <- B.Load.u32be()
        Load.pick(U32.is_eq(version, 4), version)
    case False{}:
      c => IO.die(B.Cur & K.Manifest, 1, "not a compact checkpoint (magic is not FTC2)")

def Load.header() -> B.Load(K.Manifest):
  do B.Load<K.Manifest>:
    +mg : U32 <- B.Load.u32be()
    Load.header.go(U32.is_eq(mg, K.magic()))

def header.pos(+man: K.Manifest, cp: B.Cur & Nat) -> IO(K.Manifest & Nat):
  (cur, +h) = cp
  do IO<K.Manifest & Nat>:
    u : Unit <- B.Bytes.close(cur)
    return (man, h)

def header.fin(r: B.Cur & K.Manifest) -> IO(K.Manifest & Nat):
  (cur, +man) = r
  header.pos(man, B.Bytes.pos(cur))

# the manifest and where the header ends
def header(+path: String) -> IO(K.Manifest & Nat):
  do IO<K.Manifest & Nat>:
    cur : B.Cur <- B.Bytes.open(path)
    r : B.Cur & K.Manifest <- Load.header()(cur)
    header.fin(r)

# Writing ------------------------------------------------------------------

# a save is a sequence of pieces: bytes, a run of the store, or a program
# over the store (to stage a vector in scratch cells before it is written)
type Pc is Data:
  PB{xs: List<&2, U32>}
  PA{n: U32, at: U32}
  PO{ops: List<&2, P.Op>}

def unit.fin(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(File):
  (f, e) = r
  do IO<File>:
    u : Unit <- IO.pass(Unit, e)
    return f

def wr.fin(r: Put()) -> IO(File & Array<F32>):
  rd.fin(r)

def wr.bytes(+xs: List<&2, U32>, fs: File & Array<F32>) -> IO(File & Array<F32>):
  (f, s) = fs
  do IO<File & Array<F32>>:
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(f, xs)
    g : File <- unit.fin(r)
    return (g, s)

def wr.arr(+n: U32, +a: U32, fs: File & Array<F32>) -> IO(File & Array<F32>):
  (f, s) = fs
  do IO<File & Array<F32>>:
    r : Put() <- File.write_f32be(f, n, s, a)
    wr.fin(r)

def wr.ops(ops: List<&2, P.Op>, fs: File & Array<F32>) -> File & Array<F32>:
  (f, s) = fs
  (f, P.run(ops, s))

def wr.one(pc: Pc, fs: File & Array<F32>) -> IO(File & Array<F32>):
  match pc:
    case PB{xs}:
      wr.bytes(xs, fs)
    case PA{n, a}:
      wr.arr(n, a, fs)
    case PO{ops}:
      IO.pure(File & Array<F32>, wr.ops(ops, fs))

def wr(ps: List<&2, Pc>, fs: File & Array<F32>) -> IO(File & Array<F32>):
  match ps:
    case Nil{}:
      IO.pure(File & Array<F32>, fs)
    case pc <> rest:
      do IO<File & Array<F32>>:
        t : File & Array<F32> <- wr.one(pc, fs)
        wr(rest, t)

def zeros(rs: List<&2, Rg>, +base: U32) -> List<&2, P.Op>:
  match rs:
    case Nil{}:
      Nil{}
    case Rg{+o, +n} <> t:
      P.zero(n, U32.add(base, o)) <> zeros(t, base)

def copies(rs: List<&2, Rg>, +dst: U32, +src: U32) -> List<&2, P.Op>:
  match rs:
    case Nil{}:
      Nil{}
    case Rg{+o, +n} <> t:
      P.map1(n, U32.add(dst, o), [U32.add(src, o)], X.x(0), False{}) <> copies(t, dst, src)

# The pieces of a save. Under Muon the store's m holds the first moment on
# the vectors and momentum on the owned matrices; the gradient cells (free
# between steps: each step zeroes them first) stage master's two vectors.
def pieces.pre(+sp: Src, +step: U32, +p: U32) -> List<&2, Pc>:
  [PB{List.append(&2, U32, Src.head(sp), u64.bytes(p))}, PA{p, 0},
   PB{List.append(&2, U32, u64.bytes(step), u64.bytes(p))}]

def pieces.post(+ly: L.Lay, +p: U32) -> List<&2, Pc>:
  [PB{u64.bytes(p)}, PA{p, L.Lay.v(ly)}]

def pieces.muon(+sp: Src, +step: U32, +ly: L.Lay, +m: L.Dm) -> List<&2, Pc>:
  +p = L.Lay.params(ly)
  +g = L.Lay.g(ly)
  +mz = L.Lay.m(ly)
  +rs = owned(L.Lay.blocks(ly), m)
  List.concat(&2, Pc, [pieces.pre(sp, step, p),
    [PO{P.map1(p, g, [mz], X.x(0), False{}) <> zeros(rs, g)}, PA{p, g}], pieces.post(ly, p),
    [PB{List.append(&2, U32, [1], u64.bytes(p))}, PO{P.zero(p, g) <> copies(rs, g, mz)}, PA{p, g},
     PB{Src.tail(sp)}]])

def pieces.adam(+sp: Src, +step: U32, +ly: L.Lay) -> List<&2, Pc>:
  +p = L.Lay.params(ly)
  List.concat(&2, Pc, [pieces.pre(sp, step, p), [PA{p, L.Lay.m(ly)}], pieces.post(ly, p), [PB{0 <> Src.tail(sp)}]])

def pieces(muon: Bool, +sp: Src, +step: U32, +ly: L.Lay, +m: L.Dm) -> List<&2, Pc>:
  match muon:
    case True{}:
      pieces.muon(sp, step, ly, m)
    case False{}:
      pieces.adam(sp, step, ly)

def save.fin(r: File & Array<F32>) -> IO(Array<F32>):
  (f, s) = r
  do IO<Array<F32>>:
    u : Unit <- File.close(f)
    return s

# the store as a checkpoint of the loaded run at `step`
def save(+path: String, +sp: Src, +step: Nat, +ly: L.Lay, +m: L.Dm, +muon: Bool, s: Array<F32>) -> IO(Array<F32>):
  do IO<Array<F32>>:
    f : File <- IO.try(File, File.open(path, "w"))
    r : File & Array<F32> <- wr(pieces(muon, sp, U32.from_nat(step), ly, m), (f, s))
    save.fin(r)
