import Base

# Array.einsum conformance (gate G1): a map, a row sum and max, a gather, a
# scatter-add with a repeated index and a causal contraction, printed as the
# whole array. The JS lane runs the Bend definition; a C build prints the
# same bytes on its loop (BEND_GEMM=loop) and, on small integers, on its
# generated kernels too.

def fill(xs: List<&2, F32>, a: Array<F32>, +i: U32) -> Array<F32>:
  match xs:
    case Nil{}:
      a
    case x <> t:
      fill(t, Array.set(F32, a, i, x), U32.inc(i))

def show(a: Array<F32>) -> String:
  List.show(~&1, ~F32, ~(x: F32) => F32.show(x), Array.to_list(~F32, a))

def v(off: U32, st: List<&2, U32>) -> View:
  View{off, st, IxNo{}}

# store: 0..7 x = [1..8] (2 rows of 4), 8..11 tok = [2,0,2,1], 16..27 E (4 rows of 3) = 10..21, 32.. outputs
def store() -> Array<F32>:
  fill([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 2.0, 0.0, 2.0, 1.0], fill([10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 21.0], Array.new(F32, 6n, 0.0), 16), 0)

def main() -> IO(Unit):
  # map: out[32+i] = x[i]*2 + 1
  +m = {Es{[8], 0, 0, 0, v(32, [1]), [v(0, [1])], E2{0, E2{2, EIn{0}, EK{2.0}}, EK{1.0}}} : Es}
  # row sumsq: out[40+r] = Σ_c x[r,c]^2  (dims r, c; red bit 1)
  +r = {Es{[2, 4], 2, 0, 0, v(40, [1, 0]), [v(0, [4, 1])], E2{2, EIn{0}, EIn{0}}} : Es}
  # row max
  +mx = {Es{[2, 4], 2, 1, 0, v(42, [1, 0]), [v(0, [4, 1])], EIn{0}} : Es}
  # gather: out[44 + i*3 + c] = E[16 + tok[8+i]*3 + c]
  +g = {Es{[4, 3], 0, 0, 0, v(44, [3, 1]), [View{16, [0, 1], IxAt{8, [1, 0], 3}}], EIn{0}} : Es}
  # scatter-add: E[16 + tok[i]*3 + c] += 1 (i = 0..3): rows 2 twice, 0, 1 once
  +sc = {Es{[4, 3], 0, 0, 1, View{16, [0, 1], IxAt{8, [1, 0], 3}}, Nil{}, EK{1.0}} : Es}
  # causal: out[56 + t*2 + s] = Σ_c (s <= t ? x[t,c]*x[s,c] : 0), dims t s c
  +cz = {Es{[2, 2, 4], 4, 0, 0, v(56, [2, 1, 0]), [v(0, [4, 0, 1]), v(0, [0, 4, 1])], ESel{E2{7, EIx{1}, EIx{0}}, E2{2, EIn{0}, EIn{1}}, EK{0.0}}} : Es}
  IO.print(show(Array.einsum(cz, Array.einsum(sc, Array.einsum(g, Array.einsum(mx, Array.einsum(r, Array.einsum(m, store()))))))))
