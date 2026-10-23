import Base
import ../BulkIo.bend as BI

# gemm timing (gate G0; BulkIo.bk.gemm since 2026-10-22, the fork's Array.gemm
# before): REPS calls of one shape, the arrays filled
# on the host once (0.125 everywhere, so every C entry is exactly k/64),
# timed by the runtime (BEND_PROFILE=2 prints each call; the first carries
# the arrays' migration to the GPU). g0.sh (unwired 2026-10-14, G0 done) ran it next to a direct cuBLAS
# call on the same shapes.
#   M N K BATCH  op(A) M×K, op(B) K×N, BATCH of them (default 1)
#   TA TB        transpose flags (default 0)
#   REPS         calls (default 20)

def num.or(m: Maybe<&2, U32>, d: U32) -> U32:
  Maybe.default(&2, U32, m, d)

def env.or(r: Result<&1, &1, U32 & String, String>, d: U32) -> U32:
  match r:
    case Done{v}:
      num.or(U32.read(v), d)
    case Fail{e}:
      d

def env(name: String, d: U32) -> IO(U32):
  do IO<U32>:
    r : Result<&1, &1, U32 & String, String> <- IO.get_env(name)
    return env.or(r, d)

# the least d with 2^d >= t, while x = 2^d < t (fuel bounds the search)
def depth(fuel: Nat, z: Bool, +t: Nat, +x: Nat, +d: Nat) -> Nat:
  match fuel z:
    case 1n+p True{}:
      depth(p, Nat.is_lt(Nat.mul(x, 2n), t), t, Nat.mul(x, 2n), 1n+d)
    case _ _:
      d

def mk(+n: U32) -> Array<F32>:
  Array.new(F32, depth(32n, Nat.is_lt(1n, U32.to_nat(n)), U32.to_nat(n), 1n, 0n), 0.125)

type G is Data:
  G{ta: U32, tb: U32, m: U32, n: U32, k: U32, nb: U32}

# the leading dimension of a stored r×c operand, transposed when t is 1
def G.ld.if(z: Bool, r: U32, c: U32) -> U32:
  match z:
    case True{}:
      c
    case False{}:
      r

def G.ld(t: U32, r: U32, c: U32) -> U32:
  G.ld.if(U32.is_eq(t, 0), r, c)

def G.call(+g: G, a: Array<F32>, b: Array<F32>, c: Array<F32>) -> IO(Array<F32> & Array<F32> & Array<F32>):
  match g:
    case G{+ta, +tb, +m, +n, +k, +nb}:
      BI.bk.gemm(ta, tb, m, n, k, nb, 1.0,
        a, 0, G.ld(ta, m, k), U32.mul(m, k),
        b, 0, G.ld(tb, k, n), U32.mul(k, n),
        0.0, c, 0, n, U32.mul(m, n))

def reps.one(+g: G, t: Array<F32> & Array<F32> & Array<F32>) -> IO(Array<F32> & Array<F32> & Array<F32>):
  (c, a, b) = t
  G.call(g, a, b, c)

def reps(n: Nat, +g: G, t: Array<F32> & Array<F32> & Array<F32>) -> IO(Array<F32> & Array<F32> & Array<F32>):
  match n:
    case 0n:
      IO.pure(Array<F32> & Array<F32> & Array<F32>, t)
    case 1n+p:
      IO.bind(Array<F32> & Array<F32> & Array<F32>, Array<F32> & Array<F32> & Array<F32>, reps.one(g, t),
        (x: Array<F32> & Array<F32> & Array<F32>) => reps(p, g, x))

def show.fin(r: Array<F32> & F32) -> F32:
  (c, x) = r
  x

def show(+last: U32, t: Array<F32> & Array<F32> & Array<F32>) -> String:
  (c, a, b) = t
  "C[last] = " ++ F32.show(show.fin(Array.get(F32, c, last)))

def run(+g: G, +r: U32) -> IO(String):
  match g:
    case G{ta, tb, +m, +n, +k, +nb}:
      IO.bind(Array<F32> & Array<F32> & Array<F32>, String,
        reps(U32.to_nat(r), g, (mk(U32.mul(nb, U32.mul(m, n))),
          mk(U32.mul(nb, U32.mul(m, k))), mk(U32.mul(nb, U32.mul(k, n))))),
        (x: Array<F32> & Array<F32> & Array<F32>) => IO.pure(String, show(U32.sub(U32.mul(nb, U32.mul(m, n)), 1), x)))

def main() -> IO(Unit):
  do IO<Unit>:
    m : U32 <- env("M", 256)
    n : U32 <- env("N", 256)
    k : U32 <- env("K", 256)
    nb : U32 <- env("BATCH", 1)
    ta : U32 <- env("TA", 0)
    tb : U32 <- env("TB", 0)
    r : U32 <- env("REPS", 20)
    out : String <- run(G{ta, tb, m, n, k, nb}, r)
    IO.print(out)
