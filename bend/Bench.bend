import Base
import ./Tensor.bend as T
import ./Config.bend as C
import ./Model.bend as Md
# Decode-step throughput at a preset's shapes with synthetic weights: the
# per-token cost without the checkpoint read.  PRESET=tiny|small4|bpe10m|bpe100m,
# STEPS=n; run the built binary with --threads N.
def hashf(+s: U32) -> F32:
  +a = U32.mul(U32.xor(s, U32.shrn(s, 15n)), 2654435761)
  F32.mul(F32.sub(F32.div(U32.to_f32(U32.and(a, 65535)), 65536.0), 0.5), 0.1)

def vgen.list(+n: Nat, +s: U32) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      hashf(U32.add(U32.mul(s, 7919), U32.from_nat(p))) <> vgen.list(p, s)

# depth-first construction: nodes allocated in traversal order
def vdfs(+d: Nat, +n: Nat, +s: U32) -> T.V:
  match d n:
    case _ 0n:
      T.VZ{}
    case 0n 1n+q:
      T.VL{hashf(s)}
    case 1n+p 1n+q:
      +half = Nat.pow(2n, p)
      l = vdfs(p, Nat.min(1n+q, half), U32.mul(s, 2))
      r = vdfs(p, Nat.sub(1n+q, half), U32.inc(U32.mul(s, 2)))
      T.VN{l, r}

def vgen(+n: Nat, +s: U32) -> T.V:
  vdfs(T.depth(n), n, s)

def mgen.rows(+r: Nat, +c: Nat, +s: U32) -> List<&2, T.V>:
  match r:
    case 0n:
      Nil{}
    case 1n+p:
      vgen(c, U32.add(U32.mul(s, 31), U32.from_nat(p))) <> mgen.rows(p, c, s)

def mgen(+r: Nat, +c: Nat, +s: U32) -> T.M:
  T.M.build(T.depth(r), mgen.rows(r, c, s))

def block.gla(+d: Nat, +f: Nat, +s: U32) -> Md.Block:
  Md.GlaB{vgen(d, s), mgen(d, d, U32.add(s, 1)), mgen(d, d, U32.add(s, 2)), mgen(d, d, U32.add(s, 3)), mgen(d, d, U32.add(s, 4)),
          mgen(d, d, U32.add(s, 5)), vgen(d, U32.add(s, 6)), vgen(d, U32.add(s, 7)), mgen(f, d, U32.add(s, 8)), mgen(f, d, U32.add(s, 9)), mgen(d, f, U32.add(s, 10))}

def block.sm(+d: Nat, +f: Nat, +hd: Nat, +h: Nat, +s: U32) -> Md.Block:
  Md.SmB{vgen(d, s), mgen(d, d, U32.add(s, 1)), mgen(d, d, U32.add(s, 2)), mgen(d, d, U32.add(s, 3)), mgen(d, d, U32.add(s, 4)),
         vgen(hd, U32.add(s, 5)), vgen(hd, U32.add(s, 6)), vgen(h, U32.add(s, 7)), vgen(d, U32.add(s, 8)),
         mgen(f, d, U32.add(s, 9)), mgen(f, d, U32.add(s, 10)), mgen(d, f, U32.add(s, 11))}

def block(k: C.LayerKind, +c: C.Config, +s: U32) -> Md.Block:
  match k:
    case C.Gla{}:
      block.gla(C.Config.d(c), C.Config.f(c), s)
    case C.Softmax{}:
      block.sm(C.Config.d(c), C.Config.f(c), C.Config.hd(c), C.Config.heads(c), s)

def blocks(n: Nat, +c: C.Config, +i: Nat) -> List<&2, Md.Block>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      block(C.kind_of(i), c, U32.mul(U32.from_nat(i), 100)) <> blocks(p, c, 1n+i)

def weights(+c: C.Config) -> Md.Weights:
  Md.Weights{mgen(C.Config.vocab(c), C.Config.d(c), 7), blocks(C.Config.layers(c), c, 0n), vgen(C.Config.d(c), 9), T.MZ{}}

def Out.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

def Out.logits(o: Md.Out) -> T.V:
  match o:
    case Md.Out{l, s}:
      l

def steps(n: Nat, +dm: Md.Dims, +w: Md.Weights, +o: Md.Out, +pos: Nat) -> F32:
  match n:
    case 0n:
      T.V.sum(Out.logits(o))
    case 1n+p:
      steps(p, dm, w, Md.decode(dm, w, Out.sts(o), pos, U32.from_nat(Nat.mod(pos, 100n))), 1n+pos)

def preset.if(t: Bool, s4: Bool, b10: Bool) -> C.Config:
  match t s4 b10:
    case True{} _ _:
      C.Config.tiny()
    case False{} True{} _:
      C.Config.small4_v3()
    case False{} False{} True{}:
      C.Config.bpe10m()
    case False{} False{} False{}:
      C.Config.bpe100m_v3()

def preset(+s: String) -> C.Config:
  preset.if(String.eq(s, "tiny"), String.eq(s, "small4"), String.eq(s, "bpe10m"))

def env.or(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

def msum(+m: T.M) -> F32:
  match m:
    case T.ML{r}:
      T.V.sum(r)
    case T.MN{l, r}:
      a b = msum(l) msum(r)
      F32.add(a, b)
    case T.MZ{}:
      0.0

def bsum(+b: Md.Block) -> F32:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      F32.add(F32.add(F32.add(msum(wq), msum(wk)), F32.add(msum(wv), msum(wo))), F32.add(F32.add(msum(wa), msum(wg)), F32.add(msum(wu), msum(wd))))
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sk, rf, wg, wu, wd}:
      F32.add(F32.add(F32.add(msum(wq), msum(wk)), F32.add(msum(wv), msum(wo))), F32.add(msum(wg), F32.add(msum(wu), msum(wd))))

def bssum(bs: List<&2, Md.Block>) -> F32:
  match bs:
    case Nil{}:
      0.0
    case b <> t:
      F32.add(bsum(b), bssum(t))

def wsum(+w: Md.Weights) -> F32:
  match w:
    case Md.Weights{e, bs, f, u}:
      F32.add(msum(e), bssum(bs))

def bmv(+b: Md.Block, +x: T.V, +xf: T.V) -> F32:
  match b:
    case Md.GlaB{ra, wq, wk, wv, wo, wa, lam, rf, wg, wu, wd}:
      F32.add(F32.add(F32.add(T.V.sum(T.M.matvec(wq, x)), T.V.sum(T.M.matvec(wk, x))), F32.add(T.V.sum(T.M.matvec(wv, x)), T.V.sum(T.M.matvec(wo, x)))),
        F32.add(F32.add(T.V.sum(T.M.matvec(wa, x)), T.V.sum(T.M.matvec(wg, x))), F32.add(T.V.sum(T.M.matvec(wu, x)), T.V.sum(T.M.matvec(wd, xf)))))
    case Md.SmB{ra, wq, wk, wv, wo, gq, gk, sk, rf, wg, wu, wd}:
      F32.add(F32.add(F32.add(T.V.sum(T.M.matvec(wq, x)), T.V.sum(T.M.matvec(wk, x))), F32.add(T.V.sum(T.M.matvec(wv, x)), T.V.sum(T.M.matvec(wo, x)))),
        F32.add(T.V.sum(T.M.matvec(wg, x)), F32.add(T.V.sum(T.M.matvec(wu, x)), T.V.sum(T.M.matvec(wd, xf)))))

def bsmv(bs: List<&2, Md.Block>, +x: T.V, +xf: T.V) -> F32:
  match bs:
    case Nil{}:
      0.0
    case b <> t:
      F32.add(bmv(b, x, xf), bsmv(t, x, xf))

def wmv(+w: Md.Weights, +x: T.V, +xf: T.V) -> F32:
  match w:
    case Md.Weights{e, bs, f, u}:
      F32.add(T.V.sum(T.M.matvec(e, x)), bsmv(bs, x, xf))

def mvsteps(n: Nat, +w: Md.Weights, +x: T.V, +xf: T.V, acc: F32) -> F32:
  match n:
    case 0n:
      acc
    case 1n+p:
      mvsteps(p, w, x, xf, F32.add(acc, wmv(w, x, xf)))

def run(+c: C.Config, +n: Nat) -> IO(Unit):
  +dm = Md.Dims.of(c)
  +w = weights(c)
  +o0 = {Md.Out{T.VZ{}, Md.states.zero(C.Config.layers(c), dm, 0n)} : Md.Out}
  do IO<Unit>:
    +t0 : Nat <- IO.now()
    IO.print("weights built: " ++ F32.show(wsum(w)))
    +t1 : Nat <- IO.now()
    IO.print("checksum " ++ F32.show(steps(n, dm, w, o0, 0n)))
    +t2 : Nat <- IO.now()
    IO.print("build " ++ Nat.show(Nat.sub(t1, t0)) ++ " ms; " ++ Nat.show(n) ++ " steps " ++ Nat.show(Nat.sub(t2, t1)) ++ " ms")
    IO.print("mv checksum " ++ F32.show(mvsteps(n, w, vgen(C.Config.d(c), 5), vgen(C.Config.f(c), 6), 0.0)))
    +t3 : Nat <- IO.now()
    IO.print(Nat.show(n) ++ " matvec-only passes " ++ Nat.show(Nat.sub(t3, t2)) ++ " ms")

def main() -> IO(Unit):
  do IO<Unit>:
    pr : Result<&1, &1, U32 & String, String> <- IO.get_env("PRESET")
    st : Result<&1, &1, U32 & String, String> <- IO.get_env("STEPS")
    run(preset(env.or(pr, "bpe100m")), U32.to_nat(Maybe.default(&2, U32, U32.read(env.or(st, "8")), 8)))
