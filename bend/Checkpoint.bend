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
