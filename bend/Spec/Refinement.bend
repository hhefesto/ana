import Base
import ../Tensor.bend as T
import ../Model.bend as Md
import ./Order.bend as O
import ./Nat.bend as NL
import ../Generate.bend as G

# The executable model refines the specification.
#
# The specification's theorems are about semiring expressions; the model
# runs the same expressions on F32 trees.  What connects them is proved
# here about the EXECUTABLE definitions of bend/Model.bend and
# bend/Tensor.bend (not copies):
#
#   gla_step_refines  entry (c, j) of Model's GLA state update gla.rows is
#                     alpha_c * S[c][j] + khat_c * v[j]: Linear.bend's
#                     stepGLA entry, spelled with F32.add and F32.mul
#   zip_get, map1_get the tree combinators are pointwise on full trees
#
# F32 is axiomatic in Bend2, so the semiring laws Linear's theorems use are
# the trusted base (Trusted.bend); everything else about the executable
# step -- that the tree code computes exactly that formula at every entry --
# is proved.
def pick(l: T.V, r: T.V, right: Bool) -> T.V:
  match right:
    case True{}:
      r
    case False{}:
      l

# A path selects one leaf: one Bool per level, True meaning the right half
# (the convention of Tensor.M.pick and Model's ring buffer).
def get(path: List<&2, Bool>, +x: T.V) -> F32:
  match path x:
    case Nil{} T.VL{v}:
      v
    case b <> rest T.VN{l, r}:
      get(rest, pick(l, r, b))
    case _ _:
      0.0

def len(path: List<&2, Bool>) -> Nat:
  List.length(&2, Bool, path)

# a complete tree of depth d: no absent (VZ) subtree anywhere.  A Boolean
# test, so a witness {isFull(d, x) == True} is data and can be reused.
def isFull(+d: Nat, +x: T.V) -> Bool:
  match d x:
    case 0n T.VL{v}:
      True{}
    case 1n+p T.VN{l, r}:
      Bool.and(isFull(p, l), isFull(p, r))
    case _ _:
      False{}

def Full(+d: Nat, +x: T.V) -> Data:
  {isFull(d, x) == True{} : Bool}

law and.l:
  for +a: Bool
  for +b: Bool
  for +h: {Bool.and(a, b) == True{} : Bool}
  {a == True{} : Bool}

def and.l(a, b, h):
  match a:
    case True{}:
      {==}
    case False{}:
      Empty.absurd({False{} == True{} : Bool}, O.bool.clash(h))

law and.r:
  for +a: Bool
  for +b: Bool
  for +h: {Bool.and(a, b) == True{} : Bool}
  {b == True{} : Bool}

def and.r(a, b, h):
  match a:
    case True{}:
      h
    case False{}:
      Empty.absurd({b == True{} : Bool}, O.bool.clash(h))

law and.both:
  for +a: Bool
  for +b: Bool
  for +ha: {a == True{} : Bool}
  for +hb: {b == True{} : Bool}
  {Bool.and(a, b) == True{} : Bool}

def and.both(a, b, ha, hb):
  %Equal.sym(Bool, a, True{}, ha) : {Bool.and(_, b) == True{} : Bool}
  hb

# the tree zip is pointwise on full trees of the path's depth
def zip_get(~f: F32 -> F32 -> F32, +path: List<&2, Bool>, +a: T.V, +b: T.V, +fa: Full(len(path), a), +fb: Full(len(path), b)) ->
    {get(path, T.V.zip(~f, a, b)) == f(get(path, a), get(path, b)) : F32}:
  match path a b:
    case Nil{} T.VL{x} T.VL{y}:
      {==}
    case True{} <> +rest T.VN{+al, +ar} T.VN{+bl, +br}:
      zip_get(~f, rest, ar, br, and.r(isFull(len(rest), al), isFull(len(rest), ar), fa), and.r(isFull(len(rest), bl), isFull(len(rest), br), fb))
    case False{} <> +rest T.VN{+al, +ar} T.VN{+bl, +br}:
      zip_get(~f, rest, al, bl, and.l(isFull(len(rest), al), isFull(len(rest), ar), fa), and.l(isFull(len(rest), bl), isFull(len(rest), br), fb))
    case Nil{} T.VL{x} T.VZ{}:
      Empty.absurd({get(Nil{}, T.V.zip(~f, T.VL{x}, T.VZ{})) == f(x, 0.0) : F32}, O.bool.clash(fb))
    case Nil{} T.VL{x} T.VN{l, r}:
      Empty.absurd({get(Nil{}, T.V.zip(~f, T.VL{x}, T.VN{l, r})) == f(x, 0.0) : F32}, O.bool.clash(fb))
    case Nil{} T.VZ{} _:
      Empty.absurd({get(Nil{}, T.V.zip(~f, T.VZ{}, b)) == f(0.0, get(Nil{}, b)) : F32}, O.bool.clash(fa))
    case Nil{} T.VN{l, r} _:
      Empty.absurd({get(Nil{}, T.V.zip(~f, T.VN{l, r}, b)) == f(0.0, get(Nil{}, b)) : F32}, O.bool.clash(fa))
    case c <> rest T.VN{al, ar} T.VZ{}:
      Empty.absurd({get(c <> rest, T.V.zip(~f, T.VN{al, ar}, T.VZ{})) == f(get(c <> rest, T.VN{al, ar}), 0.0) : F32}, O.bool.clash(fb))
    case c <> rest T.VN{al, ar} T.VL{y}:
      Empty.absurd({get(c <> rest, T.V.zip(~f, T.VN{al, ar}, T.VL{y})) == f(get(c <> rest, T.VN{al, ar}), 0.0) : F32}, O.bool.clash(fb))
    case c <> rest T.VZ{} _:
      Empty.absurd({get(c <> rest, T.V.zip(~f, T.VZ{}, b)) == f(0.0, get(c <> rest, b)) : F32}, O.bool.clash(fa))
    case c <> rest T.VL{x} _:
      Empty.absurd({get(c <> rest, T.V.zip(~f, T.VL{x}, b)) == f(0.0, get(c <> rest, b)) : F32}, O.bool.clash(fa))

# a map with one shared scalar is pointwise too
def map1_get(~f: F32 -> F32 -> F32, +path: List<&2, Bool>, +s: F32, +a: T.V, +fa: Full(len(path), a)) ->
    {get(path, T.V.map1(~f, s, a)) == f(s, get(path, a)) : F32}:
  match path a:
    case Nil{} T.VL{x}:
      {==}
    case True{} <> +rest T.VN{+l, +r}:
      map1_get(~f, rest, s, r, and.r(isFull(len(rest), l), isFull(len(rest), r), fa))
    case False{} <> +rest T.VN{+l, +r}:
      map1_get(~f, rest, s, l, and.l(isFull(len(rest), l), isFull(len(rest), r), fa))
    case Nil{} T.VZ{}:
      Empty.absurd({get(Nil{}, T.V.map1(~f, s, T.VZ{})) == f(s, 0.0) : F32}, O.bool.clash(fa))
    case Nil{} T.VN{l, r}:
      Empty.absurd({get(Nil{}, T.V.map1(~f, s, T.VN{l, r})) == f(s, 0.0) : F32}, O.bool.clash(fa))
    case c <> rest T.VZ{}:
      Empty.absurd({get(c <> rest, T.V.map1(~f, s, T.VZ{})) == f(s, 0.0) : F32}, O.bool.clash(fa))
    case c <> rest T.VL{x}:
      Empty.absurd({get(c <> rest, T.V.map1(~f, s, T.VL{x})) == f(s, 0.0) : F32}, O.bool.clash(fa))

def full_map1(~f: F32 -> F32 -> F32, +d: Nat, +s: F32, +a: T.V, +fa: Full(d, a)) -> Full(d, T.V.map1(~f, s, a)):
  match d a:
    case 0n T.VL{x}:
      {==}
    case 1n+p T.VN{+l, +r}:
      and.both(isFull(p, T.V.map1(~f, s, l)), isFull(p, T.V.map1(~f, s, r)),
        full_map1(~f, p, s, l, and.l(isFull(p, l), isFull(p, r), fa)),
        full_map1(~f, p, s, r, and.r(isFull(p, l), isFull(p, r), fa)))
    case 0n T.VZ{}:
      Empty.absurd(Full(0n, T.V.map1(~f, s, T.VZ{})), O.bool.clash(fa))
    case 0n T.VN{l, r}:
      Empty.absurd(Full(0n, T.V.map1(~f, s, T.VN{l, r})), O.bool.clash(fa))
    case 1n+p T.VZ{}:
      Empty.absurd(Full(1n+p, T.V.map1(~f, s, T.VZ{})), O.bool.clash(fa))
    case 1n+p T.VL{x}:
      Empty.absurd(Full(1n+p, T.V.map1(~f, s, T.VL{x})), O.bool.clash(fa))

# One row of the executable GLA update is the spec's entry formula at every
# column: V.add(V.scale(a, row), V.scale(k, v)) at j is a*row[j] + k*v[j].
def gla_row_refines(+pj: List<&2, Bool>, +a: F32, +row: T.V, +k: F32, +v: T.V, +frow: Full(len(pj), row), +fv: Full(len(pj), v)) ->
    {get(pj, T.V.add(T.V.scale(a, row), T.V.scale(k, v))) == F32.add(F32.mul(a, get(pj, row)), F32.mul(k, get(pj, v))) : F32}:
  %Equal.sym(F32, get(pj, T.V.add(T.V.scale(a, row), T.V.scale(k, v))),
      F32.add(get(pj, T.V.scale(a, row)), get(pj, T.V.scale(k, v))),
      zip_get(~F32.add, pj, T.V.scale(a, row), T.V.scale(k, v), full_map1(~F32.mul, len(pj), a, row, frow), full_map1(~F32.mul, len(pj), k, v, fv)))
    : {_ == F32.add(F32.mul(a, get(pj, row)), F32.mul(k, get(pj, v))) : F32}
  %Equal.sym(F32, get(pj, T.V.scale(a, row)), F32.mul(a, get(pj, row)), map1_get(~F32.mul, pj, a, row, frow))
    : {F32.add(_, get(pj, T.V.scale(k, v))) == F32.add(F32.mul(a, get(pj, row)), F32.mul(k, get(pj, v))) : F32}
  %Equal.sym(F32, get(pj, T.V.scale(k, v)), F32.mul(k, get(pj, v)), map1_get(~F32.mul, pj, k, v, fv))
    : {F32.add(F32.mul(a, get(pj, row)), _) == F32.add(F32.mul(a, get(pj, row)), F32.mul(k, get(pj, v))) : F32}
  {==}

# Matrices ------------------------------------------------------------------

def mpick(l: T.M, r: T.M, right: Bool) -> T.M:
  match right:
    case True{}:
      r
    case False{}:
      l

def mget(+path: List<&2, Bool>, +m: T.M) -> T.V:
  match path m:
    case Nil{} T.ML{row}:
      row
    case b <> +rest T.MN{l, r}:
      mget(rest, mpick(l, r, b))
    case _ _:
      T.VZ{}

def isFullM(+d: Nat, +m: T.M) -> Bool:
  match d m:
    case 0n T.ML{row}:
      True{}
    case 1n+p T.MN{l, r}:
      Bool.and(isFullM(p, l), isFullM(p, r))
    case _ _:
      False{}

# Row c of Model.gla.rows(S, alpha, khat, v) -- the executable per-head GLA
# state update -- is alpha_c * S_c + khat_c * v.
def gla_rows_row(+pc: List<&2, Bool>, +S: T.M, +alpha: T.V, +khat: T.V, +v: T.V,
                 +fS: {isFullM(len(pc), S) == True{} : Bool}, +fa: Full(len(pc), alpha), +fk: Full(len(pc), khat)) ->
    {mget(pc, Md.gla.rows(S, alpha, khat, v)) == T.V.add(T.V.scale(get(pc, alpha), mget(pc, S)), T.V.scale(get(pc, khat), v)) : T.V}:
  match pc S alpha khat:
    case Nil{} T.ML{row} T.VL{a} T.VL{k}:
      {==}
    case True{} <> +rest T.MN{+sl, +sr} T.VN{+al, +ar} T.VN{+kl, +kr}:
      +n = len(rest)
      gla_rows_row(rest, sr, ar, kr, v, and.r(isFullM(n, sl), isFullM(n, sr), fS), and.r(isFull(n, al), isFull(n, ar), fa), and.r(isFull(n, kl), isFull(n, kr), fk))
    case False{} <> +rest T.MN{+sl, +sr} T.VN{+al, +ar} T.VN{+kl, +kr}:
      +n = len(rest)
      gla_rows_row(rest, sl, al, kl, v, and.l(isFullM(n, sl), isFullM(n, sr), fS), and.l(isFull(n, al), isFull(n, ar), fa), and.l(isFull(n, kl), isFull(n, kr), fk))
    case Nil{} T.ML{row} T.VL{a} T.VZ{}:
      Empty.absurd({mget(Nil{}, Md.gla.rows(T.ML{row}, T.VL{a}, T.VZ{}, v)) == T.V.add(T.V.scale(get(Nil{}, T.VL{a}), mget(Nil{}, T.ML{row})), T.V.scale(get(Nil{}, T.VZ{}), v)) : T.V}, O.bool.clash(fk))
    case Nil{} T.ML{row} T.VL{a} T.VN{kl, kr}:
      Empty.absurd({mget(Nil{}, Md.gla.rows(T.ML{row}, T.VL{a}, T.VN{kl, kr}, v)) == T.V.add(T.V.scale(get(Nil{}, T.VL{a}), mget(Nil{}, T.ML{row})), T.V.scale(get(Nil{}, T.VN{kl, kr}), v)) : T.V}, O.bool.clash(fk))
    case Nil{} T.ML{row} T.VZ{} _:
      Empty.absurd({mget(Nil{}, Md.gla.rows(T.ML{row}, T.VZ{}, khat, v)) == T.V.add(T.V.scale(get(Nil{}, T.VZ{}), mget(Nil{}, T.ML{row})), T.V.scale(get(Nil{}, khat), v)) : T.V}, O.bool.clash(fa))
    case Nil{} T.ML{row} T.VN{al, ar} _:
      Empty.absurd({mget(Nil{}, Md.gla.rows(T.ML{row}, T.VN{al, ar}, khat, v)) == T.V.add(T.V.scale(get(Nil{}, T.VN{al, ar}), mget(Nil{}, T.ML{row})), T.V.scale(get(Nil{}, khat), v)) : T.V}, O.bool.clash(fa))
    case Nil{} T.MZ{} _ _:
      Empty.absurd({mget(Nil{}, Md.gla.rows(T.MZ{}, alpha, khat, v)) == T.V.add(T.V.scale(get(Nil{}, alpha), mget(Nil{}, T.MZ{})), T.V.scale(get(Nil{}, khat), v)) : T.V}, O.bool.clash(fS))
    case Nil{} T.MN{sl, sr} _ _:
      Empty.absurd({mget(Nil{}, Md.gla.rows(T.MN{sl, sr}, alpha, khat, v)) == T.V.add(T.V.scale(get(Nil{}, alpha), mget(Nil{}, T.MN{sl, sr})), T.V.scale(get(Nil{}, khat), v)) : T.V}, O.bool.clash(fS))
    case c <> rest T.MN{sl, sr} T.VN{al, ar} T.VZ{}:
      Empty.absurd({mget(c <> rest, Md.gla.rows(T.MN{sl, sr}, T.VN{al, ar}, T.VZ{}, v)) == T.V.add(T.V.scale(get(c <> rest, T.VN{al, ar}), mget(c <> rest, T.MN{sl, sr})), T.V.scale(get(c <> rest, T.VZ{}), v)) : T.V}, O.bool.clash(fk))
    case c <> rest T.MN{sl, sr} T.VN{al, ar} T.VL{k}:
      Empty.absurd({mget(c <> rest, Md.gla.rows(T.MN{sl, sr}, T.VN{al, ar}, T.VL{k}, v)) == T.V.add(T.V.scale(get(c <> rest, T.VN{al, ar}), mget(c <> rest, T.MN{sl, sr})), T.V.scale(get(c <> rest, T.VL{k}), v)) : T.V}, O.bool.clash(fk))
    case c <> rest T.MN{sl, sr} T.VZ{} _:
      Empty.absurd({mget(c <> rest, Md.gla.rows(T.MN{sl, sr}, T.VZ{}, khat, v)) == T.V.add(T.V.scale(get(c <> rest, T.VZ{}), mget(c <> rest, T.MN{sl, sr})), T.V.scale(get(c <> rest, khat), v)) : T.V}, O.bool.clash(fa))
    case c <> rest T.MN{sl, sr} T.VL{a} _:
      Empty.absurd({mget(c <> rest, Md.gla.rows(T.MN{sl, sr}, T.VL{a}, khat, v)) == T.V.add(T.V.scale(get(c <> rest, T.VL{a}), mget(c <> rest, T.MN{sl, sr})), T.V.scale(get(c <> rest, khat), v)) : T.V}, O.bool.clash(fa))
    case c <> rest T.MZ{} _ _:
      Empty.absurd({mget(c <> rest, Md.gla.rows(T.MZ{}, alpha, khat, v)) == T.V.add(T.V.scale(get(c <> rest, alpha), mget(c <> rest, T.MZ{})), T.V.scale(get(c <> rest, khat), v)) : T.V}, O.bool.clash(fS))
    case c <> rest T.ML{row} _ _:
      Empty.absurd({mget(c <> rest, Md.gla.rows(T.ML{row}, alpha, khat, v)) == T.V.add(T.V.scale(get(c <> rest, alpha), mget(c <> rest, T.ML{row})), T.V.scale(get(c <> rest, khat), v)) : T.V}, O.bool.clash(fS))


# The GLA refinement.  Entry (c, j) of the executable state update equals
# Linear.bend's stepGLA entry gate*S + key*val at F32:
#   (gla.rows S alpha khat v)[c][j] = alpha[c] * S[c][j] + khat[c] * v[j]
law gla_step_refines:
  for +pc: List<&2, Bool>
  for +pj: List<&2, Bool>
  for +S: T.M
  for +alpha: T.V
  for +khat: T.V
  for +v: T.V
  for +fS: {isFullM(len(pc), S) == True{} : Bool}
  for +fa: Full(len(pc), alpha)
  for +fk: Full(len(pc), khat)
  for +frow: Full(len(pj), mget(pc, S))
  for +fv: Full(len(pj), v)
  {get(pj, mget(pc, Md.gla.rows(S, alpha, khat, v)))
    == F32.add(F32.mul(get(pc, alpha), get(pj, mget(pc, S))), F32.mul(get(pc, khat), get(pj, v))) : F32}

def gla_step_refines(pc, pj, S, alpha, khat, v, fS, fa, fk, frow, fv):
  %Equal.sym(T.V, mget(pc, Md.gla.rows(S, alpha, khat, v)), T.V.add(T.V.scale(get(pc, alpha), mget(pc, S)), T.V.scale(get(pc, khat), v)),
      gla_rows_row(pc, S, alpha, khat, v, fS, fa, fk))
    : {get(pj, _) == F32.add(F32.mul(get(pc, alpha), get(pj, mget(pc, S))), F32.mul(get(pc, khat), get(pj, v))) : F32}
  gla_row_refines(pj, get(pc, alpha), mget(pc, S), get(pc, khat), v, frow, fv)

# The KV-cache law on the real decoder.  Feeding a prompt in two chunks --
# prefill the first, keep the reached state (GLA states and ring-buffer
# caches), continue with the second -- is feeding it at once.  This is the
# state-algebra run_append (Autoregressive.bend) for Generate's prefill over
# Model.decode, with the actual weights and the actual cache state.
law prefill_chunks:
  for +xs: List<&2, U32>
  for +ys: List<&2, U32>
  for +dm: Md.Dims
  for +w: Md.Weights
  for +o: Md.Out
  for +pos: Nat
  {G.prefill(List.append(&2, U32, xs, ys), dm, w, o, pos)
    == G.prefill(ys, dm, w, G.prefill(xs, dm, w, o, pos), Nat.add(pos, List.length(&2, U32, xs))) : Md.Out}

def prefill_chunks(xs, ys, dm, w, o, pos):
  match xs:
    case Nil{}:
      %Equal.sym(Nat, Nat.add(pos, 0n), pos, NL.Nat.add_zero_r(pos)) : {G.prefill(ys, dm, w, o, pos) == G.prefill(ys, dm, w, o, _) : Md.Out}
      {==}
    case +t <> +rest:
      %Equal.sym(Nat, Nat.add(pos, 1n+List.length(&2, U32, rest)), 1n+Nat.add(pos, List.length(&2, U32, rest)), NL.Nat.add_succ_r(pos, List.length(&2, U32, rest)))
        : {G.prefill(List.append(&2, U32, rest, ys), dm, w, Md.decode(dm, w, G.Out.sts(o), pos, t), 1n+pos)
            == G.prefill(ys, dm, w, G.prefill(rest, dm, w, Md.decode(dm, w, G.Out.sts(o), pos, t), 1n+pos), _) : Md.Out}
      prefill_chunks(rest, ys, dm, w, Md.decode(dm, w, G.Out.sts(o), pos, t), 1n+pos)
