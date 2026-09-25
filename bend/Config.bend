import Base

# The architecture (master: backend/src/FormalTransformer/Config.hs).  Every
# architecture choice lives here, so the model identity is `show` of this
# record and nothing outside it can change what a checkpoint means.

type Config is Data:
  Config{
    vocab: Nat, ctx: Nat, d: Nat, f: Nat, layers: Nat, heads: Nat,
    rglru: Bool, qk: Bool, sinks: Bool, tied: Bool}

def Config.vocab(+c: Config) -> Nat:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      v

def Config.ctx(+c: Config) -> Nat:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      n

def Config.d(+c: Config) -> Nat:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      d

def Config.f(+c: Config) -> Nat:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      f

def Config.layers(+c: Config) -> Nat:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      l

def Config.heads(+c: Config) -> Nat:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      h

def Config.rglru(+c: Config) -> Bool:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      g

def Config.qk(+c: Config) -> Bool:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      q

def Config.sinks(+c: Config) -> Bool:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      s

def Config.tied(+c: Config) -> Bool:
  match c:
    case Config{v, n, d, f, l, h, g, q, s, t}:
      t

def Config.hd(+c: Config) -> Nat:
  Nat.div(Config.d(c), Config.heads(c))


# The hybrid rule (Transformer/Specification): layer i is softmax exactly
# when i mod 4 = 3, so a stack of L layers holds L/4 softmax layers.
type LayerKind is Data:
  Gla{}
  Softmax{}

def kind_of.if(b: Bool) -> LayerKind:
  match b:
    case True{}:
      Softmax{}
    case False{}:
      Gla{}

def kind_of(+i: Nat) -> LayerKind:
  kind_of.if(Nat.is_eq(Nat.mod(i, 4n), 3n))

def Config.softmax_layers(+c: Config) -> Nat:
  Nat.div(Config.layers(c), 4n)

def Config.gla_layers(+c: Config) -> Nat:
  Nat.sub(Config.layers(c), Config.softmax_layers(c))

def when(b: Bool, n: Nat) -> Nat:
  match b:
    case True{}:
      n
    case False{}:
      0n

# Config.paramCount, term for term.
def Config.params(+c: Config) -> Nat:
  +d = Config.d(c)
  +f = Config.f(c)
  +v = Config.vocab(c)
  Nat.add(Nat.mul(v, d),
  Nat.add(Nat.mul(Config.layers(c), Nat.add(Nat.mul(4n, Nat.mul(d, d)), Nat.add(Nat.mul(3n, Nat.mul(f, d)), Nat.mul(2n, d)))),
  Nat.add(Nat.mul(Config.gla_layers(c), Nat.mul(d, d)),
  Nat.add(when(Config.rglru(c), Nat.mul(Config.gla_layers(c), d)),
  Nat.add(when(Config.qk(c), Nat.mul(Config.softmax_layers(c), Nat.mul(2n, Config.hd(c)))),
  Nat.add(when(Config.sinks(c), Nat.mul(Config.softmax_layers(c), Config.heads(c))),
  Nat.add(d, when(Bool.not(Config.tied(c)), Nat.mul(v, d)))))))))

def Config.gate.show(g: Bool) -> String:
  match g:
    case True{}:
      "GateRgLru"
    case False{}:
      "GateSigmoid"

# Haskell's derived Show for Config, byte for byte: the identity string
# a checkpoint is stamped with.
def Config.show(+c: Config) -> String:
  "Config {vocabSize = " ++ Nat.show(Config.vocab(c))
    ++ ", contextSize = " ++ Nat.show(Config.ctx(c))
    ++ ", modelDim = " ++ Nat.show(Config.d(c))
    ++ ", ffDim = " ++ Nat.show(Config.f(c))
    ++ ", layerCount = " ++ Nat.show(Config.layers(c))
    ++ ", headCount = " ++ Nat.show(Config.heads(c))
    ++ ", gateKind = " ++ Config.gate.show(Config.rglru(c))
    ++ ", qkNorm = " ++ Bool.show(Config.qk(c))
    ++ ", headSinks = " ++ Bool.show(Config.sinks(c))
    ++ ", tiedHead = " ++ Bool.show(Config.tied(c)) ++ "}"

def Config.model_id(+c: Config) -> String:
  "formal-transformer-futhark-hybrid-gla-v3:" ++ Config.show(c)

# Presets (a subset of Config.sizePresets: the ones this branch runs).
def Config.tiny() -> Config:
  Config{U32.to_nat(258), 16n, 16n, 48n, 1n, 2n, False{}, False{}, False{}, True{}}

def Config.small4_v3() -> Config:
  Config{U32.to_nat(258), 64n, 64n, U32.to_nat(192), 4n, 4n, True{}, True{}, True{}, True{}}

def Config.bpe10m() -> Config:
  Config{U32.to_nat(8192), U32.to_nat(256), U32.to_nat(320), U32.to_nat(864), 6n, 5n, False{}, False{}, False{}, True{}}

def Config.bpe100m_v3() -> Config:
  Config{U32.to_nat(32768), U32.to_nat(256), U32.to_nat(768), U32.to_nat(2048), 12n, 12n, True{}, True{}, True{}, True{}}

# master's v4 preset (Config.hs bpe460mPreset): 4x bpe100m-v3 at context 1024
def Config.bpe460m() -> Config:
  Config{U32.to_nat(32768), U32.to_nat(1024), U32.to_nat(1280), U32.to_nat(3456), 20n, 20n, True{}, True{}, True{}, True{}}
