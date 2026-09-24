import Base

# Array.gemm conformance. Each case prints every entry of its C; the
# meaning is base.bend's Array.gemm. Three runs compare:
#   the JS lane (bend GemmConf.bend) runs that definition itself;
#   a C build with BEND_GEMM=loop runs ft_gemm_loop: must print the same;
#   a CUDA build runs cuBLAS where the views fit: equal within the numerics'
#   tolerance (bend/gpu/g0.sh compares).
# The cases cover both transposes, offsets, padded leading dimensions,
# batch strides, alpha/beta (beta 0 over NaN-free garbage), and views that
# wrap past the array's end or overlap, which must stay on the loop.

# a pseudo-random F32 in [-0.5, 0.5) from a U32 seed (an LCG step)
def rnd.next(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

def rnd.f32(s: U32) -> F32:
  F32.sub(F32.div(U32.to_f32(U32.shrn(s, 8n)), 16777216.0), 0.5)

def fill(n: Nat, a: Array<F32>, +i: U32, +s: U32) -> Array<F32>:
  match n:
    case 0n:
      a
    case 1n+p:
      fill(p, Array.set(F32, a, i, rnd.f32(s)), U32.inc(i), rnd.next(s))

def arr(+d: Nat, +seed: U32) -> Array<F32>:
  fill(Nat.pow(2n, d), Array.new(F32, d, 0.0), 0, rnd.next(seed))

def show.c(r: Array<F32> & Array<F32> & Array<F32>) -> String:
  (c, a, b) = r
  List.show(~&1, ~F32, ~(x: F32) => F32.show(x), Array.to_list(~F32, c))

# one case: ta tb m n k batch alpha ao lda sa bo ldb sb beta co ldc sc, and
# the depths of A, B, C
def run.case(
  +name: String, ta: U32, tb: U32, m: U32, n: U32, k: U32, nb: U32,
  alpha: F32, ao: U32, lda: U32, sa: U32, bo: U32, ldb: U32, sb: U32,
  beta: F32, co: U32, ldc: U32, sc: U32, da: Nat, db: Nat, dc: Nat,
  +seed: U32
) -> String:
  name ++ " " ++ show.c(Array.gemm(ta, tb, m, n, k, nb, alpha,
    arr(da, seed), ao, lda, sa, arr(db, U32.add(seed, 1)), bo, ldb, sb,
    beta, arr(dc, U32.add(seed, 2)), co, ldc, sc))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(run.case("nn", 0, 0, 5, 7, 9, 1, 1.0, 0, 9, 0, 0, 7, 0, 0.0, 0, 7, 0, 6n, 6n, 6n, 1))
    IO.print(run.case("tn", 1, 0, 5, 7, 9, 1, 1.0, 0, 5, 0, 0, 7, 0, 0.0, 0, 7, 0, 6n, 6n, 6n, 2))
    IO.print(run.case("nt", 0, 1, 5, 7, 9, 1, 1.0, 0, 9, 0, 0, 9, 0, 0.0, 0, 7, 0, 6n, 7n, 6n, 3))
    IO.print(run.case("tt", 1, 1, 5, 7, 9, 1, 1.0, 0, 5, 0, 0, 9, 0, 0.0, 0, 7, 0, 6n, 7n, 6n, 4))
    IO.print(run.case("offsets-ld", 0, 0, 4, 6, 8, 1, 1.0, 3, 11, 0, 5, 9, 0, 0.0, 2, 10, 0, 6n, 7n, 6n, 5))
    IO.print(run.case("alpha-beta", 0, 1, 6, 6, 16, 1, 0.5, 0, 16, 0, 0, 16, 0, F32.neg(1.25), 0, 6, 0, 7n, 7n, 6n, 6))
    IO.print(run.case("batched", 0, 0, 4, 4, 8, 3, 1.0, 1, 8, 40, 0, 4, 33, 1.0, 0, 4, 16, 8n, 7n, 6n, 7))
    IO.print(run.case("batched-tt", 1, 1, 3, 5, 4, 4, 2.0, 0, 3, 12, 0, 4, 20, 0.0, 0, 5, 15, 6n, 7n, 6n, 8))
    IO.print(run.case("k-long", 1, 0, 8, 8, 200, 1, 1.0, 0, 8, 0, 0, 8, 0, 0.0, 0, 8, 0, 11n, 11n, 6n, 9))
    IO.print(run.case("wraps-a", 0, 0, 4, 4, 8, 1, 1.0, 60, 8, 0, 0, 4, 0, 0.0, 0, 4, 0, 6n, 6n, 4n, 10))
    IO.print(run.case("overlap-c", 0, 0, 4, 4, 4, 2, 1.0, 0, 4, 16, 0, 4, 16, 1.0, 0, 4, 2, 6n, 6n, 5n, 11))
    IO.print(run.case("ld-short", 0, 0, 4, 4, 4, 1, 1.0, 0, 2, 0, 0, 4, 0, 0.0, 0, 4, 0, 5n, 5n, 4n, 12))
    IO.print(run.case("beta-only", 0, 0, 4, 4, 0, 1, 1.0, 0, 4, 0, 0, 4, 0, 3.0, 0, 4, 0, 4n, 4n, 4n, 13))
