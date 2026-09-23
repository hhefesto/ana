import Base
import ./Nat.bend as NL
import ./Order.bend as O
import ../Config.bend as C

# Transformer/Config.agda and Transformer/Specification.agda, stated
# directly over the IMPLEMENTATION's Config record (bend/Config.bend): the
# configuration the loader reads from a checkpoint is the one these laws
# are about, not a parallel copy.
#
#   Valid            the Agda record's side conditions on a Config
#   params_arms_off  the implementation's parameter count equals the
#                    specification's formula when every v3 arm is off
#                    (tied head, sigmoid gates, no qk-norm, no sinks)
#   kinds_bpe100m    the hybrid rule: of 12 layers, indices 3, 7, 11 are
#                    softmax, the rest GLA
#   LayerFor, ModelParameters
#                    each block's parameter record is determined by its
#                    index's kind, so a gate projection cannot be
#                    allocated for a softmax layer or omitted from a GLA one

def Even(n: Nat) -> Type:
  Exists(Nat, k => {n == Nat.mul(2n, k) : Nat})

def Valid(+c: C.Config) -> Type:
  Pair(O.Le(3n, C.Config.vocab(c)),
  Pair(O.Le(2n, C.Config.ctx(c)),
  Pair(O.Le(1n, C.Config.d(c)),
  Pair(O.Le(1n, C.Config.f(c)),
  Pair(O.Le(1n, C.Config.heads(c)),
  Pair(O.Le(1n, C.Config.layers(c)),
  Pair({C.Config.d(c) == Nat.mul(C.Config.heads(c), C.Config.hd(c)) : Nat},
       Even(C.Config.hd(c)))))))))

# Agda's paramCount, with its own association:
#   vocab*model + layers*(4*model*model + 3*ff*model + 2*model)
#     + glaLayers(layers)*(model*model) + model
def glaLayers(+l: Nat) -> Nat:
  Nat.sub(l, Nat.div(l, 4n))

def specCount(+v: Nat, +d: Nat, +f: Nat, +l: Nat) -> Nat:
  Nat.add(Nat.add(Nat.add(Nat.mul(v, d),
    Nat.mul(l, Nat.add(Nat.add(Nat.mul(Nat.mul(4n, d), d), Nat.mul(Nat.mul(3n, f), d)), Nat.mul(2n, d)))),
    Nat.mul(glaLayers(l), Nat.mul(d, d))), d)

def armsOff(+v: Nat, +n: Nat, +d: Nat, +f: Nat, +l: Nat, +h: Nat) -> C.Config:
  C.Config{v, n, d, f, l, h, False{}, False{}, False{}, True{}}

law params_arms_off:
  for +v: Nat
  for +n: Nat
  for +d: Nat
  for +f: Nat
  for +l: Nat
  for +h: Nat
  {C.Config.params(armsOff(v, n, d, f, l, h)) == specCount(v, d, f, l) : Nat}

def params_arms_off(v, n, d, f, l, h):
  +vd = Nat.mul(v, d)
  +dd = Nat.mul(d, d)
  +x4 = Nat.mul(4n, dd)
  +x3 = Nat.mul(3n, Nat.mul(f, d))
  +x2 = Nat.mul(2n, d)
  +g = Nat.mul(glaLayers(l), dd)
  # the implementation nests to the right and ends in d + 0
  %Equal.sym(Nat, Nat.add(d, 0n), d, NL.Nat.add_zero_r(d)) : {Nat.add(vd, Nat.add(Nat.mul(l, Nat.add(x4, Nat.add(x3, x2))), Nat.add(g, _))) == specCount(v, d, f, l) : Nat}
  # 4*(d*d) = (4*d)*d and 3*(f*d) = (3*f)*d
  %NL.Nat.mul_assoc(4n, d, d) : {Nat.add(vd, Nat.add(Nat.mul(l, Nat.add(_, Nat.add(x3, x2))), Nat.add(g, d))) == specCount(v, d, f, l) : Nat}
  %NL.Nat.mul_assoc(3n, f, d) : {Nat.add(vd, Nat.add(Nat.mul(l, Nat.add(Nat.mul(Nat.mul(4n, d), d), Nat.add(_, x2))), Nat.add(g, d))) == specCount(v, d, f, l) : Nat}
  # reassociate the block sum and the three outer sums
  %NL.Nat.add_assoc(Nat.mul(Nat.mul(4n, d), d), Nat.mul(Nat.mul(3n, f), d), x2)
    : {Nat.add(vd, Nat.add(Nat.mul(l, _), Nat.add(g, d))) == specCount(v, d, f, l) : Nat}
  +blk = Nat.mul(l, Nat.add(Nat.add(Nat.mul(Nat.mul(4n, d), d), Nat.mul(Nat.mul(3n, f), d)), x2))
  %NL.Nat.add_assoc(blk, g, d) : {Nat.add(vd, _) == specCount(v, d, f, l) : Nat}
  %NL.Nat.add_assoc(vd, Nat.add(blk, g), d) : {_ == specCount(v, d, f, l) : Nat}
  %NL.Nat.add_assoc(vd, blk, g) : {Nat.add(_, d) == specCount(v, d, f, l) : Nat}
  {==}

# concrete counts the checker can evaluate (Bend2's checker Nats are
# unary, so the 115M presets are checked at load time instead: the loader
# refuses a manifest whose count is not Config.params of its config)
law params_tiny:
  {C.Config.params(C.Config.tiny()) == U32.to_nat(7760) : Nat}

def params_tiny():
  {==}

# the hybrid rule at the production depth
law kinds_bpe100m:
  {[C.kind_of(0n), C.kind_of(1n), C.kind_of(2n), C.kind_of(3n), C.kind_of(4n), C.kind_of(5n),
    C.kind_of(6n), C.kind_of(7n), C.kind_of(8n), C.kind_of(9n), C.kind_of(10n), C.kind_of(11n)]
    == [C.Gla{}, C.Gla{}, C.Gla{}, C.Softmax{}, C.Gla{}, C.Gla{}, C.Gla{}, C.Softmax{}, C.Gla{}, C.Gla{}, C.Gla{}, C.Softmax{}] : List<&2, C.LayerKind>}

def kinds_bpe100m():
  {==}

law gla_softmax_split:
  Pair({C.Config.gla_layers(C.Config.small4_v3()) == 3n : Nat}, {C.Config.softmax_layers(C.Config.small4_v3()) == 1n : Nat})

def gla_softmax_split():
  ({==}, {==})

# Shapes and parameter records ---------------------------------------------
#
# A tensor representation is a family of types indexed by shape.

def Shape() -> Data:
  List<&2, Nat>

def Tensors() -> Type:
  List<&2, Nat> -> Type

type GlaLayer<-T: List<&2, Nat> -> Type, -d: Nat, -f: Nat> is Type:
  GlaLayer{query: T([d, d]), key: T([d, d]), value: T([d, d]), output: T([d, d]), gate_proj: T([d, d]),
           gate: T([f, d]), up: T([f, d]), down: T([d, f]), attn_norm: T([d]), ff_norm: T([d])}

type SoftmaxLayer<-T: List<&2, Nat> -> Type, -d: Nat, -f: Nat> is Type:
  SoftmaxLayer{query: T([d, d]), key: T([d, d]), value: T([d, d]), output: T([d, d]),
               gate: T([f, d]), up: T([f, d]), down: T([d, f]), attn_norm: T([d]), ff_norm: T([d])}

# the record a layer of this kind carries
def LayerFor(k: C.LayerKind, -T: List<&2, Nat> -> Type, -d: Nat, -f: Nat) -> Type:
  match k:
    case C.Gla{}:
      GlaLayer<T, d, f>
    case C.Softmax{}:
      SoftmaxLayer<T, d, f>

# The model's parameters: blocks indexed by position, each block's type
# fixed by the hybrid rule at its index.  The token table is also the
# unembedding (tied); it is not counted twice.
type ModelParameters<-T: List<&2, Nat> -> Type, -v: Nat, -d: Nat, -f: Nat> is Type:
  ModelParameters{embedding: T([v, d]), blocks: @i: Nat -> LayerFor(C.kind_of(i), T, d, f), final_norm: T([d])}

# The primitives an implementation supplies, as signatures (the GLA one must
# satisfy Linear.bend's recurrent_parallel; Refinement.bend checks the
# executable model's step against Linear's stepGLA).
type TensorPrimitives<-T: List<&2, Nat> -> Type, -S: Data, -v: Nat, -n: Nat, -d: Nat, -f: Nat> is Type:
  TensorPrimitives{
    pre_rms_norm: T([d]) -> T([d]) -> T([d]),
    causal_attention: T([d, d]) -> T([d, d]) -> T([d, d]) -> T([d, d]) -> T([n, d]) -> T([n, d]),
    gla_attention: T([d, d]) -> T([d, d]) -> T([d, d]) -> T([d, d]) -> T([d, d]) -> T([n, d]) -> T([n, d]),
    swiglu: T([f, d]) -> T([f, d]) -> T([d, f]) -> T([d]) -> T([d]),
    tied_unembedding: T([v, d]) -> T([d]) -> T([v]),
    cross_entropy: T([v]) -> Nat -> S}
