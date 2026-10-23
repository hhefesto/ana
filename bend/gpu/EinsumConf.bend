import Base
import ../Bulk.bend as B
import ../BulkIo.bend as BI

# einsum conformance (gate G1): a map, a row sum and max, a gather, a
# scatter-add with a repeated index and a causal contraction, printed as the
# whole array. The JS lane (`bend EinsumConf.bend ref`) runs Bulk.bend's
# definition; a C build of the effects prints the same bytes on its loop
# (BEND_GEMM=loop) and, on small integers, on its
# generated kernels too.

def fill(xs: List<&2, F32>, a: Array<F32>, +i: U32) -> Array<F32>:
  match xs:
    case Nil{}:
      a
    case x <> t:
      fill(t, Array.set(F32, a, i, x), U32.inc(i))

def show(a: Array<F32>) -> String:
  List.show(~&1, ~F32, ~(x: F32) => F32.show(x), Array.to_list(~F32, a))

def v(off: U32, st: List<&2, U32>) -> B.View:
  B.View{off, st, B.IxNo{}}

# store: 0..7 x = [1..8] (2 rows of 4), 8..11 tok = [2,0,2,1], 16..27 E (4 rows of 3) = 10..21, 32.. outputs
def store() -> Array<F32>:
  fill([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 2.0, 0.0, 2.0, 1.0], fill([10.0, 11.0, 12.0, 13.0, 14.0, 15.0, 16.0, 17.0, 18.0, 19.0, 20.0, 21.0], Array.new(F32, 6n, 0.0), 16), 0)

def main() -> IO(Unit):
  # map: out[32+i] = x[i]*2 + 1
  +m = {B.Es{[8], 0, 0, 0, v(32, [1]), [v(0, [1])], B.E2{0, B.E2{2, B.EIn{0}, B.EK{2.0}}, B.EK{1.0}}} : B.Es}
  # row sumsq: out[40+r] = Σ_c x[r,c]^2  (dims r, c; red bit 1)
  +r = {B.Es{[2, 4], 2, 0, 0, v(40, [1, 0]), [v(0, [4, 1])], B.E2{2, B.EIn{0}, B.EIn{0}}} : B.Es}
  # row max
  +mx = {B.Es{[2, 4], 2, 1, 0, v(42, [1, 0]), [v(0, [4, 1])], B.EIn{0}} : B.Es}
  # gather: out[44 + i*3 + c] = E[16 + tok[8+i]*3 + c]
  +g = {B.Es{[4, 3], 0, 0, 0, v(44, [3, 1]), [B.View{16, [0, 1], B.IxAt{8, [1, 0], 3}}], B.EIn{0}} : B.Es}
  # scatter-add: E[16 + tok[i]*3 + c] += 1 (i = 0..3): rows 2 twice, 0, 1 once
  +sc = {B.Es{[4, 3], 0, 0, 1, B.View{16, [0, 1], B.IxAt{8, [1, 0], 3}}, Nil{}, B.EK{1.0}} : B.Es}
  # causal: out[56 + t*2 + s] = Σ_c (s <= t ? x[t,c]*x[s,c] : 0), dims t s c
  +cz = {B.Es{[2, 2, 4], 4, 0, 0, v(56, [2, 1, 0]), [v(0, [4, 0, 1]), v(0, [0, 4, 1])], B.ESel{B.E2{7, B.EIx{1}, B.EIx{0}}, B.E2{2, B.EIn{0}, B.EIn{1}}, B.EK{0.0}}} : B.Es}
  do IO<Unit>:
    +by : Bool <- BI.ref()
    x1 : Array<F32> <- BI.einsum.by(by, m, store())
    x2 : Array<F32> <- BI.einsum.by(by, r, x1)
    x3 : Array<F32> <- BI.einsum.by(by, mx, x2)
    x4 : Array<F32> <- BI.einsum.by(by, g, x3)
    x5 : Array<F32> <- BI.einsum.by(by, sc, x4)
    x6 : Array<F32> <- BI.einsum.by(by, cz, x5)
    IO.print(show(x6))
