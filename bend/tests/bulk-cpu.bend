import Base

# Refinement gate: the CPU kernels and the reference loops must return
# identical F32 bits, including untouched cells. Seeded shapes exercise
# transposes, tails, batching, wrapping and overlapping output views.
# Einsums cover tiled reductions, every expression operation, indirect
# reads/writes, in-place maps and dimensions with zero extent.

def bc.next(s: U32) -> U32:
  U32.add(U32.mul(s, 1664525), 1013904223)

def bc.fill(n: Nat, a: Array<F32>, +i: U32, +s: U32) -> Array<F32>:
  match n:
    case 0n:
      a
    case 1n+p:
      bc.fill(p, Array.set(F32, a, i, F32.sub(F32.div(U32.to_f32(U32.shrn(s, 8n)), 16777216.0), 0.5)), U32.inc(i), bc.next(s))

def bc.arr(+seed: U32) -> Array<F32>:
  bc.fill(16384n, Array.new(F32, 14n, 0.0), 0, seed)

def bc.bits(a: Array<F32>) -> String:
  List.show(~&1, ~F32, ~(x: F32) => U32.show(F32.bits(x)), Array.to_list(~F32, a))

def bc.got(r: Array<F32> & Array<F32> & Array<F32>) -> String:
  (c, a, b) = r
  bc.bits(c)

def bc.gemm(+s: U32, +ta: U32, +tb: U32, +m: U32, +n: U32, +k: U32, +nb: U32, +wrap: Bool) -> String:
  +la = U32.add(3, Bool.pick(U32, U32.is_eq(ta, 0), k, m))
  +lb = U32.add(5, Bool.pick(U32, U32.is_eq(tb, 0), n, k))
  +sa = U32.mul(la, Bool.pick(U32, U32.is_eq(ta, 0), m, k))
  +sb = U32.mul(lb, Bool.pick(U32, U32.is_eq(tb, 0), k, n))
  bc.got(Array.gemm(ta, tb, m, n, k, nb, 0.75,
    bc.arr(s), Bool.pick(U32, wrap, 16370, 7), la, sa,
    bc.arr(bc.next(s)), 11, lb, sb, F32.neg(0.25),
    bc.arr(bc.next(bc.next(s))), 13, U32.add(n, 2),
    Bool.pick(U32, wrap, 3, U32.mul(m, U32.add(n, 2)))))

def bc.v(o: U32, st: List<&2, U32>) -> View:
  View{o, st, IxNo{}}

def bc.expr() -> Ex:
  ESel{E2{6, EIx{1}, EK{129.0}},
    E2{0, E1{1, EIn{0}}, E2{3, E2{2, EIn{0}, EIn{1}}, E2{0, EK{1.0}, E1{4, EIn{1}}}}},
    E2{1, E1{3, E2{0, EK{1.0}, E1{4, EIn{0}}}}, E1{2, E2{0, EK{1.0}, E1{4, EIn{1}}}}}}

def bc.eins(+s: U32, +rows: U32, +cols: U32, +op: U32) -> String:
  bc.bits(Array.einsum(Es{[rows, cols], 2, op, U32.mod(s, 2),
    bc.v(14000, [1, 0]), [bc.v(0, [cols, 1]), bc.v(6000, [cols, 1])], bc.expr()}, bc.arr(s)))

def bc.cases(n: Nat, +s: U32) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        IO.print(bc.gemm(s, U32.mod(s, 2), U32.mod(U32.shrn(s, 2n), 2), U32.inc(U32.mod(s, 19)), U32.add(29, U32.mod(bc.next(s), 43)), U32.add(7, U32.mod(bc.next(bc.next(s)), 101)), 2, U32.is_eq(U32.mod(s, 7), 0)))
        IO.print(bc.eins(s, U32.add(8, U32.mod(s, 9)), U32.add(251, U32.mod(bc.next(s), 71)), U32.mod(s, 2)))
        bc.cases(p, bc.next(s))

def bc.special() -> IO(Unit):
  do IO<Unit>:
    IO.print(bc.gemm(7, 0, 1, 1, 1025, 97, 1, False{}))
    IO.print(bc.gemm(9, 1, 0, 65, 33, 0, 2, False{}))
    IO.print(bc.eins(11, 7, 0, 0))
    IO.print(bc.eins(13, 7, 0, 1))
    IO.print(bc.bits(Array.einsum(Es{[4097], 0, 0, 0, bc.v(0, [1]), [bc.v(0, [1])], E2{5, E2{4, E1{0, EIn{0}}, EK{0.25}}, EK{0.4}}}, bc.arr(19))))
    # The gather reads earlier outputs: points must remain sequential.
    IO.print(bc.bits(Array.einsum(Es{[31], 0, 0, 0, bc.v(4, [1]), [View{3, [1], IxAt{100, [0], 1}}], E2{0, EIn{0}, EK{1.0}}}, Array.set(F32, bc.arr(23), 100, 0.0))))
    # Repeated scatter destinations accumulate in point order.
    IO.print(bc.bits(Array.einsum(Es{[1025], 0, 0, 1, View{14000, [0], IxAt{12000, [0], 1}}, [bc.v(0, [1])], EIn{0}}, Array.set(F32, bc.arr(29), 12000, 0.0))))
    # Wrapped direct reads and outputs use the reference's modulo indexing.
    IO.print(bc.bits(Array.einsum(Es{[513], 0, 0, 0, bc.v(32760, [1]), [bc.v(16000, [1])], EIn{0}}, bc.arr(31))))

# Large enough to enter the parallel path, with an incomplete final tile.
# The two-dimensional output and alternating reduction axes also check
# the counters used instead of division at every element.
def bc.big(seed: U32) -> Array<F32>:
  bc.fill(131072n, Array.new(F32, 17n, 0.0), 0, seed)

def bc.parallel(+seed: U32) -> IO(Unit):
  do IO<Unit>:
    IO.print(bc.bits(Array.einsum(Es{[129, 257], 2, 0, 1,
      bc.v(120000, [1, 0]), [bc.v(0, [257, 1]), bc.v(40000, [257, 1])], bc.expr()}, bc.big(seed))))
    IO.print(bc.bits(Array.einsum(Es{[9, 17, 33, 11], 10, 1, 0,
      bc.v(120000, [33, 0, 1, 0]), [bc.v(0, [6171, 363, 11, 1])], EIn{0}}, bc.big(seed))))
    IO.print(bc.got(Array.gemm(0, 1, 1, 257, 263, 1, 0.75,
      bc.big(seed), 3, 263, 0, bc.big(seed), 7, 269, 0, F32.neg(0.25), bc.arr(seed), 5, 257, 0)))

def main() -> IO(Unit):
  do IO<Unit>:
    bc.cases(48n, 20261005)
    bc.special()
    bc.parallel(20261006)
