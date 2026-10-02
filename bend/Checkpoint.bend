import Base
import ./Num.bend as N
import ./Bytes.bend as B
import ./Parse.bend as P
import ./Config.bend as C

# The FTC2 compact checkpoint (master: Artifact.hs, encodeCheckpointCompact):
#
#   magic "FTC2" (Word32 BE)
#   Manifest (Data.Binary, version 4)
#   parameters: Word64 count, then count big-endian f32
#   Adam step (Int64), first and second moments, Muon flag and momentum,
#   best validation loss, PRNG state
#
# Everything multi-byte is big-endian.  Data.Binary encodes Int as Int64,
# Bool and constructor tags as one byte, String as an Int64 character count
# then UTF-8 characters, and Double as decodeFloat's (Integer, Int).

type AdamW is Data:
  AdamW{lr: F32, beta1: F32, beta2: F32, eps: F32, decay: F32, warmup: Nat, total: Nat}

type Manifest is Data:
  Manifest{
    version: U32, cfg: C.Config, count: Nat, layout: String,
    layout_version: U32, adamw: AdamW, muon: Maybe<&2, F32>,
    model_id: String, tokenizer_id: String, dataset_id: String,
    clip: F32, numerics: U32}

def magic() -> U32:
  1179927346

def Load.char() -> B.Load(Char):
  do B.Load<Char>:
    +b : U32 <- B.Load.byte()
    +n : Nat = P.utf8.lead(b)
    rest : List<&2, U32> <- B.Load.bytes(n)
    return Chr{P.utf8.cont(rest, U32.and(b, P.utf8.mask(n)))}

def Load.chars(n: Nat) -> B.Load(String):
  match n:
    case 0n:
      B.Load.pure(String, SNil{})
    case 1n+p:
      do B.Load<String>:
        c : Char <- Load.char()
        t : String <- Load.chars(p)
        return SCon{c, t}

def Load.string() -> B.Load(String):
  do B.Load<String>:
    n : Nat <- B.Load.nat()
    Load.chars(n)

def Load.integer.if(small: Bool) -> B.Load(F32):
  match small:
    case True{}:
      do B.Load<F32>:
        w : U32 <- B.Load.u32be()
        return P.signed.f32(w)
    case False{}:
      do B.Load<F32>:
        s : U32 <- B.Load.byte()
        n : Nat <- B.Load.nat()
        bs : List<&2, U32> <- B.Load.bytes(n)
        return P.Parse.sign(s, P.le.f32(bs))

def Load.integer() -> B.Load(F32):
  do B.Load<F32>:
    tag : U32 <- B.Load.byte()
    Load.integer.if(U32.is_eq(tag, 0))

def Load.int.f32() -> B.Load(F32):
  do B.Load<F32>:
    w : N.U64 <- B.Load.u64be()
    return P.signed.f32(N.U64.lo(w))

def Load.double() -> B.Load(F32):
  do B.Load<F32>:
    m : F32 <- Load.integer()
    e : F32 <- Load.int.f32()
    return F32.mul(m, F32.pow(2.0, e))

def Load.muon.if(some: Bool) -> B.Load(Maybe<&2, F32>):
  match some:
    case True{}:
      do B.Load<Maybe<&2, F32>>:
        x : F32 <- Load.double()
        return Some{x}
    case False{}:
      B.Load.pure(Maybe<&2, F32>, None{})

def Load.muon() -> B.Load(Maybe<&2, F32>):
  do B.Load<Maybe<&2, F32>>:
    some : Bool <- B.Load.bool()
    Load.muon.if(some)

def Load.config() -> B.Load(C.Config):
  do B.Load<C.Config>:
    v : Nat <- B.Load.nat()
    n : Nat <- B.Load.nat()
    d : Nat <- B.Load.nat()
    f : Nat <- B.Load.nat()
    l : Nat <- B.Load.nat()
    h : Nat <- B.Load.nat()
    g : Bool <- B.Load.bool()
    q : Bool <- B.Load.bool()
    s : Bool <- B.Load.bool()
    t : Bool <- B.Load.bool()
    return C.Config{v, n, d, f, l, h, g, q, s, t}

def Load.adamw() -> B.Load(AdamW):
  do B.Load<AdamW>:
    lr : F32 <- Load.double()
    b1 : F32 <- Load.double()
    b2 : F32 <- Load.double()
    eps : F32 <- Load.double()
    wd : F32 <- Load.double()
    warm : Nat <- B.Load.nat()
    total : Nat <- B.Load.nat()
    return AdamW{lr, b1, b2, eps, wd, warm, total}

def Load.manifest() -> B.Load(Manifest):
  do B.Load<Manifest>:
    version : U32 <- B.Load.u32be()
    cfg : C.Config <- Load.config()
    count : Nat <- B.Load.nat()
    layout : String <- Load.string()
    lv : U32 <- B.Load.u32be()
    adamw : AdamW <- Load.adamw()
    muon : Maybe<&2, F32> <- Load.muon()
    mid : String <- Load.string()
    tid : String <- Load.string()
    did : String <- Load.string()
    clip : F32 <- Load.double()
    numerics : U32 <- B.Load.byte()
    return Manifest{version, cfg, count, layout, lv, adamw, muon, mid, tid, did, clip, numerics}

def Manifest.cfg(+m: Manifest) -> C.Config:
  match m:
    case Manifest{v, c, n, l, lv, a, mu, mi, ti, di, cl, nu}:
      c

def Manifest.tokenizer_id(+m: Manifest) -> String:
  match m:
    case Manifest{v, c, n, l, lv, a, mu, mi, ti, di, cl, nu}:
      ti

def Manifest.total_steps(+m: Manifest) -> Nat:
  match m:
    case Manifest{v, c, n, l, lv, AdamW{lr, b1, b2, e, wd, w, t}, mu, mi, ti, di, cl, nu}:
      t

# What validateCheckpoint checks of the manifest, as one verdict: the empty
# string when the checkpoint is one this branch can run, else the reason.
def check(ok: Bool, why: String, rest: String) -> String:
  match ok:
    case True{}:
      rest
    case False{}:
      why

def Manifest.problem(+m: Manifest) -> String:
  match m:
    case Manifest{+v, +c, +n, +l, +lv, a, mu, +mi, ti, di, cl, nu}:
      check(U32.is_eq(v, 4), "unsupported checkpoint manifest version (this branch reads version 4)",
      check(String.eq(l, "hybrid-gla-decoder-flat-parameters"), "unsupported checkpoint model layout identity",
      check(U32.is_eq(lv, 3), "unsupported checkpoint model layout version",
      check(Nat.is_eq(n, C.Config.params(c)), "manifest parameter count does not match config",
      check(String.eq(mi, C.Config.model_id(c)), "checkpoint model identity is not supported by this host",
      "")))))

def Load.header.if(ok: Bool) -> B.Load(Manifest):
  match ok:
    case True{}:
      Load.manifest()
    case False{}:
      c => IO.die(B.Cur & Manifest, 1, "not a compact checkpoint (magic is not FTC2)")

def Load.header() -> B.Load(Manifest):
  do B.Load<Manifest>:
    +mg : U32 <- B.Load.u32be()
    m : Manifest <- Load.header.if(U32.is_eq(mg, magic()))
    return m

# Writing a manifest: the inverse of Load.manifest, in Data.Binary's
# encoding (big-endian throughout), so a run that starts fresh on a plan
# (TrainDense.bend) can save FTC2 checkpoints that Dense/Ckpt.bend loads
# back. Only what Load reads is written; a Double is decodeFloat's pair, the
# mantissa doubled until whole (a small Integer: tag 0 and an Int32) and the
# exponent the Int64 -k, which Load.double multiplies back exactly.

def Save.u32be(+x: U32) -> List<&2, U32>:
  [U32.div(x, 16777216), U32.mod(U32.div(x, 65536), 256), U32.mod(U32.div(x, 256), 256), U32.mod(x, 256)]

# an Int64 below 2^32
def Save.nat(+n: Nat) -> List<&2, U32>:
  List.append(&2, U32, [0, 0, 0, 0], Save.u32be(U32.from_nat(n)))

# the Int64 -k, two's complement
def Save.neg(+k: Nat) -> List<&2, U32>:
  match k:
    case 0n:
      [0, 0, 0, 0, 0, 0, 0, 0]
    case 1n+p:
      List.append(&2, U32, [255, 255, 255, 255], Save.u32be(U32.add(U32.sub(4294967295, U32.from_nat(k)), 1)))

def Save.bool(b: Bool) -> List<&2, U32>:
  match b:
    case True{}:
      [1]
    case False{}:
      [0]

# a code point in UTF-8
def Save.cp(+c: U32) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, U32.is_lt(c, 128), [c],
  Bool.pick(List<&2, U32>, U32.is_lt(c, 2048), [U32.add(192, U32.div(c, 64)), U32.add(128, U32.mod(c, 64))],
  Bool.pick(List<&2, U32>, U32.is_lt(c, 65536),
    [U32.add(224, U32.div(c, 4096)), U32.add(128, U32.mod(U32.div(c, 64), 64)), U32.add(128, U32.mod(c, 64))],
    [U32.add(240, U32.div(c, 262144)), U32.add(128, U32.mod(U32.div(c, 4096), 64)), U32.add(128, U32.mod(U32.div(c, 64), 64)), U32.add(128, U32.mod(c, 64))])))

def Save.chars(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      List.append(&2, U32, Save.cp(c), Save.chars(t))

# an Int64 character count, then the characters
def Save.string(+s: String) -> List<&2, U32>:
  List.append(&2, U32, Save.nat(String.length(s)), Save.chars(s))

# the mantissa as an Int32 and the exponent -k
def Save.dbl.fin(+m: F32, +k: Nat) -> List<&2, U32>:
  +a = U32.from_nat(F32.to_nat(F32.abs(m)))
  List.append(&2, U32, 0 <> Save.u32be(Bool.pick(U32, F32.is_lt(m, 0.0), U32.add(U32.sub(4294967295, a), 1), a)), Save.neg(k))

# double m until it is whole (whole: it already is)
def Save.dbl.go(fuel: Nat, whole: Bool, +m: F32, +k: Nat) -> List<&2, U32>:
  match fuel whole:
    case 1n+f False{}:
      +m2 = F32.mul(m, 2.0)
      Save.dbl.go(f, F32.is_eq(F32.floor(m2), m2), m2, 1n+k)
    case _ _:
      Save.dbl.fin(m, k)

def Save.double(+x: F32) -> List<&2, U32>:
  Save.dbl.go(U32.to_nat(200), F32.is_eq(F32.floor(x), x), x, 0n)

def Save.config(+c: C.Config) -> List<&2, U32>:
  List.concat(&2, U32, [Save.nat(C.Config.vocab(c)), Save.nat(C.Config.ctx(c)), Save.nat(C.Config.d(c)), Save.nat(C.Config.f(c)),
    Save.nat(C.Config.layers(c)), Save.nat(C.Config.heads(c)), Save.bool(C.Config.rglru(c)), Save.bool(C.Config.qk(c)),
    Save.bool(C.Config.sinks(c)), Save.bool(C.Config.tied(c))])

def Save.adamw(a: AdamW) -> List<&2, U32>:
  match a:
    case AdamW{lr, b1, b2, e, wd, w, t}:
      List.concat(&2, U32, [Save.double(lr), Save.double(b1), Save.double(b2), Save.double(e), Save.double(wd), Save.nat(w), Save.nat(t)])

def Save.muon(m: Maybe<&2, F32>) -> List<&2, U32>:
  match m:
    case Some{x}:
      1 <> Save.double(x)
    case None{}:
      [0]

def Save.manifest(m: Manifest) -> List<&2, U32>:
  match m:
    case Manifest{v, c, n, l, lv, a, mu, mi, ti, di, cl, nu}:
      List.concat(&2, U32, [Save.u32be(v), Save.config(c), Save.nat(n), Save.string(l), Save.u32be(lv), Save.adamw(a),
        Save.muon(mu), Save.string(mi), Save.string(ti), Save.string(di), Save.double(cl), [nu]])

# a file's head (the magic and the manifest), which Dense/Ckpt.bend copies
# into every save
def Save.header(m: Manifest) -> List<&2, U32>:
  List.append(&2, U32, Save.u32be(magic()), Save.manifest(m))
