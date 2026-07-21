-- Cross-backend numeric check: each entry computes a suspect pullback at
-- production dims from deterministic in-program inputs and returns
-- (sum, max_abs, mean_abs). Running the same entry under `futhark c` and
-- `futhark cuda` must agree to f32 tolerance; a CUDA-only miscompilation
-- shows up as a gross mismatch. Not part of any build.
import "pieces-defs"

def gen (n: i64) (offset: i64) (scale: f32): [n]f32 =
  tabulate n (\i -> scale * f32.sin (f32.i64 (i * 7 + offset * 13 + 1)))

def gentok (n: i64) (v: i64): [n]i64 =
  tabulate n (\i -> (i * 2654435761) % v)

def summary [m] (a: [m]f32): (f32, f32, f32) =
  ( f32.sum a
  , f32.maximum (map f32.abs a)
  , f32.sum (map f32.abs a) / f32.i64 m )

entry check_ce_bwd (batch: i64) (sequence: i64) (v: i64)
    : (f32, f32, f32) =
  let logits = gen (batch*sequence*v) 1 2.0f32
  let tokens = gentok (batch*sequence) v
  in summary (piece_ce_dlogits batch 1.0f32 logits tokens)

entry check_softmax_bwd (groups: i64) (n: i64) (head_dim: i64)
    : (f32, f32, f32) =
  let scores = gen (groups*n*n) 2 1.0f32
  let weights_bar = gen (groups*n*n) 3 1.0f32
  let (_, scores_bar) =
    vjp2 (piece_causal_softmax head_dim) scores weights_bar
  in summary scores_bar

entry check_embed_bwd (v: i64) (d: i64) (count: i64)
    : (f32, f32, f32) =
  let tokens = gentok count v
  let output_bar = gen (count*d) 4 1.0f32
  in summary (piece_embed_scatter tokens output_bar : [v*d]f32)

entry check_gate_cum_bwd (groups: i64) (chunk: i64) (hd: i64)
    : (f32, f32, f32) =
  let gate_logits = gen (groups*chunk*hd) 5 1.0f32
  let relcum_bar = gen (groups*chunk*hd) 6 1.0f32
  let dec_bar = gen (groups*hd) 7 1.0f32
  let (_, input_bar) =
    vjp2 piece_gate_cum gate_logits (relcum_bar, dec_bar)
  in summary input_bar

entry check_l2_bwd (rows: i64) (d: i64) (h: i64)
    : (f32, f32, f32) =
  let x = gen (rows*d) 8 1.0f32
  let output_bar = gen (rows*d) 9 1.0f32
  let (_, x_bar) = vjp2 (piece_l2norm_heads h) x output_bar
  in summary x_bar

entry check_intra_bwd (groups: i64) (chunk: i64) (hd: i64)
    : (f32, f32, f32) =
  let q = gen (groups*chunk*hd) 1 1.0f32
  let k = gen (groups*chunk*hd) 2 1.0f32
  let v = gen (groups*chunk*hd) 3 1.0f32
  let rel = gen (groups*chunk*hd) 4 0.05f32
  let obar = gen (groups*chunk*hd) 5 1.0f32
  let (qb, kb, vb, rb) = piece_gla_intra_bars q k v rel obar
  let (s1, m1, a1) = summary qb
  let (s2, m2, a2) = summary kb
  let (s3, m3, a3) = summary vb
  let (s4, m4, a4) = summary rb
  in (s1+s2+s3+s4, f32.maximum [m1,m2,m3,m4], (a1+a2+a3+a4)/4.0f32)
