import Base
import ./Bulk.bend as B

# The bulk F32 ops, fast: our own effects (bend/effs/bulk.c and bulk.js).
# Each one's meaning is its Bulk.bend definition (bk.gemm is B.gemm, bk.mm
# B.mm, bk.einsum B.einsum.prim), and the C code gives every output the
# same F32 steps in the same order (tests/bulk-cpu.bend checks the bits).
# They were the Bend fork's (hhefesto/bend2) built-in Array.gemm, Array.mm,
# Array.einsum.prim and File.read_f32be / write_f32be until 2026-10-22;
# as effects they run on upstream Bend, in IO. A def outside Base with a
# foreign body is a promise to the proof gate, so Everything.bend does not
# import this file. An array goes to the C code without a copy: the effect
# works on the caller's own block.

# C ← α·op(A)·op(B) + β·C over `batch` matrices (B.gemm), as (C, A, B)
def bk.gemm(
  ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32, alpha: F32,
  a: Array<F32>, ao: U32, lda: U32, sa: U32,
  b: Array<F32>, bo: U32, ldb: U32, sb: U32,
  beta: F32, c: Array<F32>, co: U32, ldc: U32, sc: U32
) -> IO(Array<F32> & Array<F32> & Array<F32>):
  import "./effs/bulk.c"
  import "./effs/bulk.js"

# the same with A, B and C in one array (B.mm): C's rectangle must not
# overlap A's or B's
def bk.mm(
  ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32, alpha: F32,
  ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32,
  beta: F32, co: U32, ldc: U32, sc: U32, x: Array<F32>
) -> IO(Array<F32>):
  import "./effs/bulk.c"
  import "./effs/bulk.js"

# an einsum from its encoding, B.Es.encode(es) (B.einsum.prim)
def bk.einsum(spec: String, x: Array<F32>) -> IO(Array<F32>):
  import "./effs/bulk.c"
  import "./effs/bulk.js"

def einsum(+es: B.Es, x: Array<F32>) -> IO(Array<F32>):
  bk.einsum(B.Es.encode(es), x)

# Big-endian F32 file I/O. read_f32be(f, off, n, x, at) is bytes
# [off, off+4n) of f read as n big-endian F32, set into x at at, at+1, ...
# (Array.set's wrapping indices); f's position does not move.
# write_f32be(f, n, x, at) writes x[at .. at+n-1] the same way at f's
# position. Each is File.read_at / File.write_bytes folded with Array.set /
# Array.get, with no F32 a Bend term on the way.
def bk.read_f32be(file: File, off: U32, n: U32, x: Array<F32>, at: U32) ->
  IO(File & Array<F32> & Result<&1, &1, U32 & String, Unit>):
  import "./effs/bulk.c"
  import "./effs/bulk.js"

def bk.write_f32be(file: File, n: U32, x: Array<F32>, at: U32) ->
  IO(File & Array<F32> & Result<&1, &1, U32 & String, Unit>):
  import "./effs/bulk.c"
  import "./effs/bulk.js"

# Each op either way: as its Bulk.bend definition (by is True: pure Bend)
# or as the effect. The conformance programs run both and compare the
# bits; `ref` among a program's arguments picks the definitions.
def gemm.by(
  by: Bool, ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32,
  alpha: F32, a: Array<F32>, ao: U32, lda: U32, sa: U32,
  b: Array<F32>, bo: U32, ldb: U32, sb: U32,
  beta: F32, c: Array<F32>, co: U32, ldc: U32, sc: U32
) -> IO(Array<F32> & Array<F32> & Array<F32>):
  match by:
    case True{}:
      IO.pure(Array<F32> & Array<F32> & Array<F32>, B.gemm(ta, tb, m, n, k,
        batch, alpha, a, ao, lda, sa, b, bo, ldb, sb, beta, c, co, ldc, sc))
    case False{}:
      bk.gemm(ta, tb, m, n, k, batch, alpha, a, ao, lda, sa, b, bo, ldb, sb,
        beta, c, co, ldc, sc)

def mm.by(
  by: Bool, ta: U32, tb: U32, m: U32, n: U32, k: U32, batch: U32,
  alpha: F32, ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32,
  beta: F32, co: U32, ldc: U32, sc: U32, x: Array<F32>
) -> IO(Array<F32>):
  match by:
    case True{}:
      IO.pure(Array<F32>, B.mm(ta, tb, m, n, k, batch, alpha, ao, lda, sa,
        bo, ldb, sb, beta, co, ldc, sc, x))
    case False{}:
      bk.mm(ta, tb, m, n, k, batch, alpha, ao, lda, sa, bo, ldb, sb, beta,
        co, ldc, sc, x)

def einsum.by(by: Bool, +es: B.Es, x: Array<F32>) -> IO(Array<F32>):
  match by:
    case True{}:
      IO.pure(Array<F32>, B.einsum(es, x))
    case False{}:
      einsum(es, x)

def ref.in(xs: List<String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      Bool.or(String.eq(x, "ref"), ref.in(t))

# the program's arguments name `ref`
def ref() -> IO(Bool):
  do IO<Bool>:
    xs : List<String> <- IO.args()
    return ref.in(xs)
