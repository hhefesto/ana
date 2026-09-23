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
      l r = V.fill(p, Nat.min(1n+q, half), c) V.fill(p, Nat.sub(1n+q, half), c)
      VN{l, r}

# Elementwise ------------------------------------------------------------

def V.map(~f: F32 -> F32, +a: V) -> V:
  match a:
    case VL{x}:
      VL{f(x)}
    case VN{l, r}:
      p q = V.map(~f, l) V.map(~f, r)
      VN{p, q}
    case VZ{}:
      VZ{}

# a map with one shared scalar argument
def V.map1(~f: F32 -> F32 -> F32, +s: F32, +a: V) -> V:
  match a:
    case VL{x}:
      VL{f(s, x)}
    case VN{l, r}:
      p q = V.map1(~f, s, l) V.map1(~f, s, r)
      VN{p, q}
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
      l r = V.zip(~f, al, bl) V.zip(~f, ar, br)
      VN{l, r}
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
      p q = V.sum(l) V.sum(r)
      F32.add(p, q)
    case VZ{}:
      0.0

def V.sumsq(+a: V) -> F32:
  match a:
    case VL{x}:
      F32.mul(x, x)
    case VN{l, r}:
      p q = V.sumsq(l) V.sumsq(r)
      F32.add(p, q)
    case VZ{}:
      0.0

# the maximum over present components (-inf-like when none are)
def V.max(+a: V) -> F32:
  match a:
    case VL{x}:
      x
    case VN{l, r}:
      p q = V.max(l) V.max(r)
      F32.max(p, q)
    case VZ{}:
      F32.neg(3.0e38)

def V.dot(+a: V, +b: V) -> F32:
  match a b:
    case VL{x} VL{y}:
      F32.mul(x, y)
    case VN{al, ar} VN{bl, br}:
      l r = V.dot(al, bl) V.dot(ar, br)
      F32.add(l, r)
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
      l r = V.add.pad(al, bl) V.add.pad(ar, br)
      VN{l, r}
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
