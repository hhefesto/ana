import Base
import ../Num.bend as N
import ../Tensor.bend as T
import ../Config.bend as C
import ../Model.bend as Md
# Fresh parameters (master: backend/gpu/Main.hs newCheckpoint, INIT_KIND=hash).
#
# Every parameter is a deterministic function of its flat index (offset + 1
# in the namedLayout order): decayed slices (matrices, the embedding and the
# qk gains' neighbours) get scale * hashNoise(index), gains get 1, the RG-LRU
# decay bases get Griffin's init (sigmoid(lam)^8 uniform on [0.9, 0.999)),
# and qk-norm gains and sink logits start at 0.  hashNoise is splitmix64's
# finalizer mapped to [-1, 1), computed on exact 64-bit words, so this is
# master's hash init up to the final rounding to F32.  (Master's default
# INIT_KIND=sin evaluates sin in double precision at up to 1.5e9 radians,
# which no F32 computation reproduces.)
def scale() -> F32:
  0.02

def U64.f32(+z: N.U64) -> F32:
  match z:
    case N.U64{h, l}:
      F32.add(F32.mul(U32.to_f32(h), 4294967296.0), U32.to_f32(l))

def hashNoise(+index: Nat) -> F32:
  +z0 = N.U64.mul(N.U64.of(U32.from_nat(index)), N.U64{2654435769, 2135587861})
  +z1 = N.U64.mul(N.U64.xor(z0, N.U64.shr(z0, 30n)), N.U64{3210233709, 484763065})
  +z2 = N.U64.mul(N.U64.xor(z1, N.U64.shr(z1, 27n)), N.U64{2496678331, 321982955})
  +z3 = N.U64.xor(z2, N.U64.shr(z2, 31n))
  F32.sub(F32.div(U64.f32(z3), 9223372036854775808.0), 1.0)

def lambdaInit(+index: Nat) -> F32:
  +u = F32.add(0.9, F32.mul(0.099, F32.div(F32.add(hashNoise(index), 1.0), 2.0)))
  +a = F32.pow(u, 0.125)
  F32.log(F32.div(a, F32.sub(1.0, a)))

def noise.list(n: Nat, +off: Nat) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      F32.mul(scale(), hashNoise(1n+off)) <> noise.list(p, 1n+off)

def lambda.list(n: Nat, +off: Nat) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      lambdaInit(1n+off) <> lambda.list(p, 1n+off)

def noise.vec(+off: Nat, +n: Nat) -> T.V:
  T.V.build(T.depth(n), noise.list(n, off))

def noise.rows(r: Nat, +off: Nat, +cols: Nat) -> List<&2, T.V>:
  match r:
    case 0n:
      Nil{}
    case 1n+p:
      noise.vec(off, cols) <> noise.rows(p, Nat.add(off, cols), cols)

def noise.mat(+off: Nat, +r: Nat, +c: Nat) -> T.M:
  T.M.build(T.depth(r), noise.rows(r, off, c))

def ones(+n: Nat) -> T.V:
  T.V.fill(T.depth(n), n, 1.0)

def zeros(+n: Nat) -> T.V:
  T.V.fill(T.depth(n), n, 0.0)

def when.v(b: Bool, +v: T.V) -> T.V:
  match b:
    case True{}:
      v
    case False{}:
      T.VZ{}

def when.n(b: Bool, +n: Nat) -> Nat:
  match b:
    case True{}:
      n
    case False{}:
      0n

# parameters in one block of this kind (namedLayout)
def block.common(+c: C.Config) -> Nat:
  +d = C.Config.d(c)
  Nat.add(Nat.mul(2n, d), Nat.add(Nat.mul(4n, Nat.mul(d, d)), Nat.mul(3n, Nat.mul(C.Config.f(c), d))))

def block.size(k: C.LayerKind, +c: C.Config) -> Nat:
  match k:
    case C.Gla{}:
      Nat.add(block.common(c), Nat.add(Nat.mul(C.Config.d(c), C.Config.d(c)), when.n(C.Config.rglru(c), C.Config.d(c))))
    case C.Softmax{}:
      Nat.add(block.common(c), Nat.add(when.n(C.Config.qk(c), Nat.mul(2n, C.Config.hd(c))), when.n(C.Config.sinks(c), C.Config.heads(c))))

def block.gla(+c: C.Config, +base: Nat) -> Md.Block:
  +d = C.Config.d(c)
  +f = C.Config.f(c)
  +dd = Nat.mul(d, d)
  +o = Nat.add(base, d)
  +after = Nat.add(Nat.add(o, Nat.mul(5n, dd)), when.n(C.Config.rglru(c), d))
  Md.GlaB{ones(d), noise.mat(o, d, d), noise.mat(Nat.add(o, dd), d, d), noise.mat(Nat.add(o, Nat.mul(2n, dd)), d, d),
          noise.mat(Nat.add(o, Nat.mul(3n, dd)), d, d), noise.mat(Nat.add(o, Nat.mul(4n, dd)), d, d),
          when.v(C.Config.rglru(c), T.V.build(T.depth(d), lambda.list(d, Nat.add(o, Nat.mul(5n, dd))))),
          ones(d), noise.mat(Nat.add(after, d), f, d), noise.mat(Nat.add(Nat.add(after, d), Nat.mul(f, d)), f, d),
          noise.mat(Nat.add(Nat.add(after, d), Nat.mul(2n, Nat.mul(f, d))), d, f)}

def block.sm(+c: C.Config, +base: Nat) -> Md.Block:
  +d = C.Config.d(c)
  +f = C.Config.f(c)
  +dd = Nat.mul(d, d)
  +hd = C.Config.hd(c)
  +o = Nat.add(base, d)
  +after = Nat.add(Nat.add(o, Nat.mul(4n, dd)), Nat.add(when.n(C.Config.qk(c), Nat.mul(2n, hd)), when.n(C.Config.sinks(c), C.Config.heads(c))))
  Md.SmB{ones(d), noise.mat(o, d, d), noise.mat(Nat.add(o, dd), d, d), noise.mat(Nat.add(o, Nat.mul(2n, dd)), d, d),
         noise.mat(Nat.add(o, Nat.mul(3n, dd)), d, d),
         when.v(C.Config.qk(c), zeros(hd)), when.v(C.Config.qk(c), zeros(hd)), when.v(C.Config.sinks(c), zeros(C.Config.heads(c))),
         ones(d), noise.mat(Nat.add(after, d), f, d), noise.mat(Nat.add(Nat.add(after, d), Nat.mul(f, d)), f, d),
         noise.mat(Nat.add(Nat.add(after, d), Nat.mul(2n, Nat.mul(f, d))), d, f)}

def block.init(k: C.LayerKind, +c: C.Config, +base: Nat) -> Md.Block:
  match k:
    case C.Gla{}:
      block.gla(c, base)
    case C.Softmax{}:
      block.sm(c, base)

def blocks(n: Nat, +c: C.Config, +i: Nat, +base: Nat) -> List<&2, Md.Block>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      block.init(C.kind_of(i), c, base) <> blocks(p, c, 1n+i, Nat.add(base, block.size(C.kind_of(i), c)))

def stack.size(n: Nat, +c: C.Config, +i: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      Nat.add(block.size(C.kind_of(i), c), stack.size(p, c, 1n+i))

def untied.emb(b: Bool, +off: Nat, +c: C.Config) -> T.M:
  match b:
    case True{}:
      noise.mat(off, C.Config.vocab(c), C.Config.d(c))
    case False{}:
      T.MZ{}

def init(+c: C.Config) -> Md.Weights:
  +vd = Nat.mul(C.Config.vocab(c), C.Config.d(c))
  +top = Nat.add(vd, stack.size(C.Config.layers(c), c, 0n))
  Md.Weights{noise.mat(0n, C.Config.vocab(c), C.Config.d(c)), blocks(C.Config.layers(c), c, 0n, vd), ones(C.Config.d(c)),
             untied.emb(Bool.not(C.Config.tied(c)), Nat.add(top, C.Config.d(c)), c)}
