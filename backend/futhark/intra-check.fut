-- Standalone check: manual piece_gla_intra_bars vs vjp2 of the forward, at
-- configurable dims. Deterministic pseudo-random inputs; prints the max
-- absolute difference per cotangent. Not part of any build.
import "pieces-defs"

def gen (n: i64) (offset: i64) (scale: f32): [n]f32 =
  tabulate n (\i -> scale * f32.sin (f32.i64 (i * 7 + offset * 13 + 1)))

def maxdiff [m] (a: [m]f32) (b: [m]f32): f32 =
  f32.maximum (map2 (\x y -> f32.abs (x - y)) a b)

entry compare (groups: i64) (chunk: i64) (hd: i64)
    : (f32, f32, f32, f32, f32) =
  let q = gen (groups * chunk * hd) 1 1.0f32
  let k = gen (groups * chunk * hd) 2 1.0f32
  let v = gen (groups * chunk * hd) 3 1.0f32
  let rel = gen (groups * chunk * hd) 4 0.05f32
  let obar = gen (groups * chunk * hd) 5 1.0f32
  let (_, (q1, k1, v1, r1)) =
    vjp2 piece_gla_intra (q, k, v, rel) obar
  let (q2, k2, v2, r2) = piece_gla_intra_bars q k v rel obar
  in (maxdiff q1 q2, maxdiff k1 k2, maxdiff v1 v2, maxdiff r1 r2,
      f32.maximum (map f32.abs r1))
