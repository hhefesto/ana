import Base

# Vectors and matrices as balanced binary trees.
#
# A vector of n components lives in a tree of depth ceil(log2 n) whose
# absent tail is VZ: the zero vector, so padding costs no memory and every
# reduction treats it as the additive identity.  Two vectors built at the
# same length have the same shape, which is all dot and zip require; a
# mismatch meets VZ and contributes 0.  Every combinator forks at each
# node, so the whole tensor algebra runs fork-join parallel.
#
# A matrix is a tree of rows, each row a vector (row-major, [out][in], the
# layout of master's Layout.hs and model.fut).

type V is Data:
  VZ{}
  VL{x: F32}
  VN{l: V, r: V}

type M is Data:
  MZ{}
  ML{row: V}
  MN{l: M, r: M}

# Building ---------------------------------------------------------------

def V.from.fin2(a: V, r: V & List<&2, F32>) -> V & List<&2, F32>:
  (b, rest) = r
  (VN{a, b}, rest)

def V.from.fin(l: V & List<&2, F32>, k: List<&2, F32> -> V & List<&2, F32>) -> V & List<&2, F32>:
  (a, rest) = l
  V.from.fin2(a, k(rest))

# the first 2^d components of a list as a depth-d tree, padded with VZ,
# beside the rest of the list
def V.from(+d: Nat, xs: List<&2, F32>) -> V & List<&2, F32>:
  match d xs:
    case _ Nil{}:
      (VZ{}, Nil{})
    case 0n h <> t:
      (VL{h}, t)
    case 1n+p h <> t:
      V.from.fin(V.from(p, h <> t), r => V.from(p, r))

def M.from.fin2(a: M, r: M & List<&2, V>) -> M & List<&2, V>:
  (b, rest) = r
  (MN{a, b}, rest)

def M.from.fin(l: M & List<&2, V>, k: List<&2, V> -> M & List<&2, V>) -> M & List<&2, V>:
  (a, rest) = l
  M.from.fin2(a, k(rest))

def M.from(+d: Nat, xs: List<&2, V>) -> M & List<&2, V>:
  match d xs:
    case _ Nil{}:
      (MZ{}, Nil{})
    case 0n h <> t:
      (ML{h}, t)
    case 1n+p h <> t:
      M.from.fin(M.from(p, h <> t), r => M.from(p, r))

def V.fst(r: V & List<&2, F32>) -> V:
  (v, rest) = r
  v

def V.of_list(+d: Nat, xs: List<&2, F32>) -> V:
  V.fst(V.from(d, xs))

def M.fst(r: M & List<&2, V>) -> M:
  (m, rest) = r
  m

def M.of_list(+d: Nat, xs: List<&2, V>) -> M:
  M.fst(M.from(d, xs))

def Nat.sel(b: Bool, x: Nat, y: Nat) -> Nat:
  match b:
    case True{}:
      x
    case False{}:
      y

# the bit length of x
def bits(fuel: Nat, +x: Nat) -> Nat:
  match fuel:
    case 0n:
      0n
    case 1n+p:
      Nat.sel(Nat.is_eq(x, 0n), 0n, 1n+bits(p, Nat.div(x, 2n)))

# smallest d with 2^d >= n
def depth(+n: Nat) -> Nat:
  bits(48n, Nat.sub(n, 1n))

# A constant vector of depth d holding c at the first n slots.
def V.fill(+d: Nat, +n: Nat, +c: F32) -> V:
  match d n:
    case _ 0n:
      VZ{}
    case 0n 1n+q:
      VL{c}
    case 1n+p 1n+q:
      +half = Nat.pow(2n, p)
      VN{V.fill(p, Nat.min(1n+q, half), c), V.fill(p, Nat.sub(1n+q, half), c)}

# Elementwise ------------------------------------------------------------

def V.map(~f: F32 -> F32, +a: V) -> V:
  match a:
    case VL{x}:
      VL{f(x)}
    case VN{l, r}:
      VN{V.map(~f, l), V.map(~f, r)}
    case VZ{}:
      VZ{}

# a map with one shared scalar argument
def V.map1(~f: F32 -> F32 -> F32, +s: F32, +a: V) -> V:
  match a:
    case VL{x}:
      VL{f(s, x)}
    case VN{l, r}:
      VN{V.map1(~f, s, l), V.map1(~f, s, r)}
    case VZ{}:
      VZ{}

# Zip over two same-shaped vectors.  VZ is absent on both sides by
# construction; f must send absent pairs to absent (every f here is a
# product or a sum, and the unused branch is never reached).
def V.zip(~f: F32 -> F32 -> F32, +a: V, +b: V) -> V:
  match a b:
    case VL{x} VL{y}:
      VL{f(x, y)}
    case VN{al, ar} VN{bl, br}:
      VN{V.zip(~f, al, bl), V.zip(~f, ar, br)}
    case _ _:
      VZ{}

def V.add(+a: V, +b: V) -> V:
  V.zip(~F32.add, a, b)

def V.mul(+a: V, +b: V) -> V:
  V.zip(~F32.mul, a, b)

def V.scale(+s: F32, +a: V) -> V:
  V.map1(~F32.mul, s, a)

# Reductions -------------------------------------------------------------

def V.sum(+a: V) -> F32:
  match a:
    case VL{x}:
      x
    case VN{l, r}:
      F32.add(V.sum(l), V.sum(r))
    case VZ{}:
      0.0

def V.sumsq(+a: V) -> F32:
  match a:
    case VL{x}:
      F32.mul(x, x)
    case VN{l, r}:
      F32.add(V.sumsq(l), V.sumsq(r))
    case VZ{}:
      0.0

# the maximum over present components (-inf-like when none are)
def V.max(+a: V) -> F32:
  match a:
    case VL{x}:
      x
    case VN{l, r}:
      F32.max(V.max(l), V.max(r))
    case VZ{}:
      F32.neg(3.0e38)

def V.dot(+a: V, +b: V) -> F32:
  match a b:
    case VL{x} VL{y}:
      F32.mul(x, y)
    case VN{al, ar} VN{bl, br}:
      F32.add(V.dot(al, bl), V.dot(ar, br))
    case _ _:
      0.0

# Matrices ---------------------------------------------------------------

def M.matvec(+m: M, +x: V) -> V:
  match m:
    case ML{row}:
      VL{V.dot(row, x)}
    case MN{l, r}:
      a b = M.matvec(l, x) M.matvec(r, x)
      VN{a, b}
    case MZ{}:
      VZ{}

# sum of two same-shaped vectors where either side may be wholly absent
def V.add.pad(+a: V, +b: V) -> V:
  match a b:
    case VZ{} _:
      b
    case _ VZ{}:
      a
    case VL{x} VL{y}:
      VL{F32.add(x, y)}
    case VN{al, ar} VN{bl, br}:
      VN{V.add.pad(al, bl), V.add.pad(ar, br)}
    case _ _:
      VZ{}

# x^T m: the combination of m's rows weighted by x's components
def M.vecmat(+x: V, +m: M) -> V:
  match x m:
    case VL{s} ML{row}:
      V.scale(s, row)
    case VN{xl, xr} MN{ml, mr}:
      a b = M.vecmat(xl, ml) M.vecmat(xr, mr)
      V.add.pad(a, b)
    case _ _:
      VZ{}

# Indexing ---------------------------------------------------------------

def bit(+i: U32, +p: Nat) -> Bool:
  U32.is_eq(U32.and(U32.shrn(i, p), 1), 1)

def M.pick(l: M, r: M, right: Bool) -> M:
  match right:
    case True{}:
      r
    case False{}:
      l

# row i of a depth-d matrix
def M.row(+d: Nat, +m: M, +i: U32) -> V:
  match d m:
    case 0n ML{row}:
      row
    case 1n+p MN{l, r}:
      M.row(p, M.pick(l, r, bit(i, p)), i)
    case _ _:
      VZ{}

# components in index order, absent tail dropped
def V.to_list.go(+a: V, acc: List<&2, F32>) -> List<&2, F32>:
  match a:
    case VL{x}:
      x <> acc
    case VN{l, r}:
      V.to_list.go(l, V.to_list.go(r, acc))
    case VZ{}:
      acc

def V.to_list(+a: V) -> List<&2, F32>:
  V.to_list.go(a, Nil{})

def M.is_z(+m: M) -> Bool:
  match m:
    case MZ{}:
      True{}
    case _:
      False{}

def V.is_z(+a: V) -> Bool:
  match a:
    case VZ{}:
      True{}
    case _:
      False{}

def V.pick(l: V, r: V, right: Bool) -> V:
  match right:
    case True{}:
      r
    case False{}:
      l

# component i of a depth-d vector (0 where absent)
def V.at(+d: Nat, +a: V, +i: U32) -> F32:
  match d a:
    case 0n VL{x}:
      x
    case 1n+p VN{l, r}:
      V.at(p, V.pick(l, r, bit(i, p)), i)
    case _ _:
      0.0

# sum of exp(x - m) over present components
def V.sum_exp(+m: F32, +a: V) -> F32:
  match a:
    case VL{x}:
      F32.exp(F32.sub(x, m))
    case VN{l, r}:
      F32.add(V.sum_exp(m, l), V.sum_exp(m, r))
    case VZ{}:
      0.0

# Building by pairing rounds ---------------------------------------------
#
# The left-packed depth-d tree of a list, built bottom-up: leaves, then d
# rounds pairing neighbours (a lone last element pairs with VZ).  The same
# canonical shape as V.from, with no closures and linear work per round.

def V.leaves(xs: List<&2, F32>) -> List<&2, V>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      VL{h} <> V.leaves(t)

def V.pairs(vs: List<&2, V>) -> List<&2, V>:
  match vs:
    case a <> b <> t:
      VN{a, b} <> V.pairs(t)
    case a <> Nil{}:
      [VN{a, VZ{}}]
    case Nil{}:
      Nil{}

def V.first(vs: List<&2, V>) -> V:
  match vs:
    case h <> t:
      h
    case Nil{}:
      VZ{}

def V.rounds(d: Nat, vs: List<&2, V>) -> V:
  match d:
    case 0n:
      V.first(vs)
    case 1n+p:
      V.rounds(p, V.pairs(vs))

def V.build(d: Nat, xs: List<&2, F32>) -> V:
  V.rounds(d, V.leaves(xs))

def M.pairs(ms: List<&2, M>) -> List<&2, M>:
  match ms:
    case a <> b <> t:
      MN{a, b} <> M.pairs(t)
    case a <> Nil{}:
      [MN{a, MZ{}}]
    case Nil{}:
      Nil{}

def M.first(ms: List<&2, M>) -> M:
  match ms:
    case h <> t:
      h
    case Nil{}:
      MZ{}

def M.rounds(d: Nat, ms: List<&2, M>) -> M:
  match d:
    case 0n:
      M.first(ms)
    case 1n+p:
      M.rounds(p, M.pairs(ms))

def M.leaves(rs: List<&2, V>) -> List<&2, M>:
  match rs:
    case Nil{}:
      Nil{}
    case h <> t:
      ML{h} <> M.leaves(t)

def M.build(d: Nat, rs: List<&2, V>) -> M:
  M.rounds(d, M.leaves(rs))

# Gradient algebra ---------------------------------------------------------

def V.sub(+a: V, +b: V) -> V:
  V.zip(~F32.sub, a, b)

# the zero vector of the same shape
def V.zero_like(+a: V) -> V:
  match a:
    case VL{x}:
      VL{0.0}
    case VN{l, r}:
      VN{V.zero_like(l), V.zero_like(r)}
    case VZ{}:
      VZ{}

def M.zero_like(+m: M) -> M:
  match m:
    case ML{row}:
      ML{V.zero_like(row)}
    case MN{l, r}:
      MN{M.zero_like(l), M.zero_like(r)}
    case MZ{}:
      MZ{}

# dy x^T: the gradient of W in y = W x, laid out like W (rows follow dy)
def M.outer(+dy: V, +x: V) -> M:
  match dy:
    case VL{a}:
      ML{V.scale(a, x)}
    case VN{l, r}:
      a b = M.outer(l, x) M.outer(r, x)
      MN{a, b}
    case VZ{}:
      MZ{}

def M.add(+a: M, +b: M) -> M:
  match a b:
    case MZ{} _:
      b
    case _ MZ{}:
      a
    case ML{x} ML{y}:
      ML{V.add.pad(x, y)}
    case MN{al, ar} MN{bl, br}:
      l r = M.add(al, bl) M.add(ar, br)
      MN{l, r}
    case _ _:
      MZ{}

# rows scaled by the components of s
def M.scale_rows(+s: V, +m: M) -> M:
  match s m:
    case VL{a} ML{row}:
      ML{V.scale(a, row)}
    case VN{sl, sr} MN{ml, mr}:
      MN{M.scale_rows(sl, ml), M.scale_rows(sr, mr)}
    case _ _:
      MZ{}

# dot of corresponding rows
def M.rowdots(+a: M, +b: M) -> V:
  match a b:
    case ML{x} ML{y}:
      VL{V.dot(x, y)}
    case MN{al, ar} MN{bl, br}:
      VN{M.rowdots(al, bl), M.rowdots(ar, br)}
    case _ _:
      VZ{}

# the sum of squares of every entry (for the global gradient norm)
def M.sumsq(+m: M) -> F32:
  match m:
    case ML{row}:
      V.sumsq(row)
    case MN{l, r}:
      a b = M.sumsq(l) M.sumsq(r)
      F32.add(a, b)
    case MZ{}:
      0.0

def M.map(~f: F32 -> F32, +m: M) -> M:
  match m:
    case ML{row}:
      ML{V.map(~f, row)}
    case MN{l, r}:
      a b = M.map(~f, l) M.map(~f, r)
      MN{a, b}
    case MZ{}:
      MZ{}

def M.zip(~f: F32 -> F32 -> F32, +a: M, +b: M) -> M:
  match a b:
    case ML{x} ML{y}:
      ML{V.zip(~f, x, y)}
    case MN{al, ar} MN{bl, br}:
      l r = M.zip(~f, al, bl) M.zip(~f, ar, br)
      MN{l, r}
    case _ _:
      MZ{}

type VP is Data:
  VP{go: V, keep: V}

def VP.of(l: V, r: V, right: Bool) -> VP:
  match right:
    case True{}:
      VP{r, l}
    case False{}:
      VP{l, r}

def VP.go(p: VP) -> V:
  match p:
    case VP{g, k}:
      g

def VP.keep(p: VP) -> V:
  match p:
    case VP{g, k}:
      k

def VP.join(right: Bool, g: V, k: V) -> V:
  match right:
    case True{}:
      VN{k, g}
    case False{}:
      VN{g, k}

# replace component i of a depth-d vector
def V.set(+d: Nat, +a: V, +i: U32, +x: F32) -> V:
  match d a:
    case 0n VL{y}:
      VL{x}
    case 1n+p VN{l, r}:
      +right = bit(i, p)
      +sp = VP.of(l, r, right)
      VP.join(right, V.set(p, VP.go(sp), i, x), VP.keep(sp))
    case _ _:
      a

type MP2 is Data:
  MP2{go: M, keep: M}

def MP2.of(l: M, r: M, right: Bool) -> MP2:
  match right:
    case True{}:
      MP2{r, l}
    case False{}:
      MP2{l, r}

def MP2.go(p: MP2) -> M:
  match p:
    case MP2{g, k}:
      g

def MP2.keep(p: MP2) -> M:
  match p:
    case MP2{g, k}:
      k

def MP2.join(right: Bool, g: M, k: M) -> M:
  match right:
    case True{}:
      MN{k, g}
    case False{}:
      MN{g, k}

def M.kids2(m: M) -> MP2:
  match m:
    case MN{l, r}:
      MP2{l, r}
    case _:
      MP2{MZ{}, MZ{}}

def M.leafrow(m: M) -> V:
  match m:
    case ML{r}:
      r
    case _:
      VZ{}

# row i of a depth-d matrix increased by `row` (absent rows start at zero):
# the embedding cotangent of a token lookup
def M.add_row(+d: Nat, +m: M, +i: U32, +row: V) -> M:
  match d:
    case 0n:
      ML{V.add.pad(M.leafrow(m), row)}
    case 1n+p:
      +right = bit(i, p)
      +sp = MP2.of(MP2.go(M.kids2(m)), MP2.keep(M.kids2(m)), right)
      MP2.join(right, M.add_row(p, MP2.go(sp), i, row), MP2.keep(sp))
