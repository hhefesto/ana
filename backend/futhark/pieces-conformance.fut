-- One generated program containing the decomposed pieces and fused model
-- oracle.  Importing pieces (rather than linking two libraries) guarantees
-- conformance tests share one Futhark context/runtime.

open import "pieces"

entry oracle_n_params (v: i64) (d: i64) (f: i64) (n_layers: i64): i64 =
  assert (v > 0 && d > 0 && f > 0 && n_layers > 0)
  parameter_count v d f n_layers

entry oracle_logits [n]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (params: [parameter_count v d f n_layers]f32) (tokens: [n]i64)
    : [n*v]f32 =
  flatten (model_logits v d f h n_layers chunk params tokens)

entry oracle_logits_quadratic [n]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: [parameter_count v d f n_layers]f32) (tokens: [n]i64)
    : [n*v]f32 =
  flatten (model_logits_quadratic v d f h n_layers params tokens)

entry oracle_batch_loss_grad
    (batch: i64) (sequence: i64)
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (params: [parameter_count v d f n_layers]f32)
    (tokens_flat: [batch*sequence]i64)
    : (f32, [parameter_count v d f n_layers]f32) =
  let tokens = unflatten tokens_flat :> [batch][sequence]i64
  in vjp2 (\candidate ->
    batch_mean_loss_def v d f h n_layers chunk candidate tokens) params 1.0f32

entry conf_piece_ce_fwd (batch: i64) (sequence: i64) (v: i64)
    (effective_batch: i64) (logits: [batch*sequence*v]f32)
    (tokens: [batch*sequence]i64): f32 =
  piece_ce_fwd batch sequence v effective_batch logits tokens

entry conf_piece_ce_bwd (batch: i64) (sequence: i64) (v: i64)
    (effective_batch: i64) (loss_bar: f32)
    (logits: [batch*sequence*v]f32) (tokens: [batch*sequence]i64)
    : [batch*sequence*v]f32 =
  piece_ce_bwd batch sequence v effective_batch loss_bar logits tokens

entry conf_piece_embed_gather_bwd (v: i64) (d: i64) (count: i64)
    (tokens: [count]i64) (output_bar: [count*d]f32): [v*d]f32 =
  piece_embed_gather_bwd v d count tokens output_bar

entry conf_piece_embed_gather_fwd (v: i64) (d: i64) (count: i64)
    (embedding: [v*d]f32) (tokens: [count]i64): [count*d]f32 =
  piece_embed_gather_fwd v d count embedding tokens

entry conf_piece_rms_norm_fwd (rows: i64) (d: i64)
    (x: [rows*d]f32) (gain: [d]f32): [rows*d]f32 =
  piece_rms_norm_fwd rows d x gain

entry conf_piece_rms_norm_bwd (rows: i64) (d: i64)
    (x: [rows*d]f32) (gain: [d]f32) (output_bar: [rows*d]f32)
    : ([rows*d]f32, [d]f32) =
  piece_rms_norm_bwd rows d x gain output_bar

entry conf_piece_l2norm_heads_fwd (rows: i64) (d: i64)
    (h: i64) (x: [rows*d]f32): [rows*d]f32 =
  piece_l2norm_heads_fwd rows d h x

entry conf_piece_l2norm_heads_bwd (rows: i64) (d: i64)
    (h: i64) (x: [rows*d]f32) (output_bar: [rows*d]f32): [rows*d]f32 =
  piece_l2norm_heads_bwd rows d h x output_bar

entry conf_piece_silu_gate_fwd [count]
    (gate: [count]f32) (up: [count]f32): [count]f32 =
  piece_silu_gate_fwd gate up

entry conf_piece_silu_gate_bwd [count]
    (gate: [count]f32) (up: [count]f32) (output_bar: [count]f32)
    : ([count]f32, [count]f32) =
  piece_silu_gate_bwd gate up output_bar

entry conf_piece_add_fwd [count]
    (x: [count]f32) (y: [count]f32): [count]f32 =
  piece_add_fwd x y

entry conf_piece_add_bwd [count]
    (output_bar: [count]f32): ([count]f32, [count]f32) =
  piece_add_bwd output_bar

entry conf_piece_split_heads_fwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (x: [batch*n*h*hd]f32): [batch*h*n*hd]f32 =
  piece_split_heads_fwd batch n h hd x

entry conf_piece_split_heads_bwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (output_bar: [batch*h*n*hd]f32): [batch*n*h*hd]f32 =
  piece_split_heads_bwd batch n h hd output_bar

entry conf_piece_merge_heads_fwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (x: [batch*h*n*hd]f32): [batch*n*h*hd]f32 =
  piece_merge_heads_fwd batch n h hd x

entry conf_piece_merge_heads_bwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (output_bar: [batch*n*h*hd]f32): [batch*h*n*hd]f32 =
  piece_merge_heads_bwd batch n h hd output_bar

entry conf_piece_causal_softmax_fwd (groups: i64) (n: i64)
    (head_dim: i64) (scores: [groups*n*n]f32): [groups*n*n]f32 =
  piece_causal_softmax_fwd groups n head_dim scores

entry conf_piece_causal_softmax_bwd (groups: i64) (n: i64)
    (head_dim: i64) (scores: [groups*n*n]f32)
    (weights_bar: [groups*n*n]f32): [groups*n*n]f32 =
  piece_causal_softmax_bwd groups n head_dim scores weights_bar

entry conf_piece_gate_cum_fwd (groups: i64) (chunk: i64) (hd: i64)
    (gate_logits: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*hd]f32) =
  piece_gate_cum_fwd groups chunk hd gate_logits

entry conf_piece_gate_cum_bwd (groups: i64) (chunk: i64) (hd: i64)
    (gate_logits: [groups*chunk*hd]f32)
    (relcum_bar: [groups*chunk*hd]f32) (dec_bar: [groups*hd]f32)
    : [groups*chunk*hd]f32 =
  piece_gate_cum_bwd groups chunk hd gate_logits relcum_bar dec_bar

entry conf_piece_qk_decay_fwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (relcum: [groups*chunk*hd]f32) (dec: [groups*hd]f32)
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32) =
  piece_qk_decay_fwd groups chunk hd q k relcum dec

entry conf_piece_qk_decay_bwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (relcum: [groups*chunk*hd]f32) (dec: [groups*hd]f32)
    (q_scaled_bar: [groups*chunk*hd]f32)
    (k_scaled_bar: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32,
       [groups*chunk*hd]f32, [groups*hd]f32) =
  piece_qk_decay_bwd groups chunk hd q k relcum dec q_scaled_bar k_scaled_bar

entry conf_piece_gla_intra_fwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (values: [groups*chunk*hd]f32) (relcum: [groups*chunk*hd]f32)
    : [groups*chunk*hd]f32 =
  piece_gla_intra_fwd groups chunk hd q k values relcum

entry conf_piece_gla_intra_bwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (values: [groups*chunk*hd]f32) (relcum: [groups*chunk*hd]f32)
    (output_bar: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32,
       [groups*chunk*hd]f32, [groups*chunk*hd]f32) =
  piece_gla_intra_bwd groups chunk hd q k values relcum output_bar

entry conf_piece_state_advance_fwd (groups: i64) (hd: i64)
    (state: [groups*hd*hd]f32) (contribution: [groups*hd*hd]f32)
    (dec: [groups*hd]f32): [groups*hd*hd]f32 =
  piece_state_advance_fwd groups hd state contribution dec

entry conf_piece_state_advance_bwd (groups: i64) (hd: i64)
    (state: [groups*hd*hd]f32) (contribution: [groups*hd*hd]f32)
    (dec: [groups*hd]f32) (output_bar: [groups*hd*hd]f32)
    : ([groups*hd*hd]f32, [groups*hd*hd]f32, [groups*hd]f32) =
  piece_state_advance_bwd groups hd state contribution dec output_bar

entry conf_piece_read_slice (n: i64) (offset: i64) (count: i64)
    (source: [n]f32): [count]f32 =
  piece_read_slice n offset count source

entry conf_piece_write_slice (n: i64) (m: i64) (offset: i64)
    (destination: [n]f32) (source: [m]f32): [n]f32 =
  piece_write_slice n m offset destination source

entry conf_piece_gather_chunk (groups: i64) (chunk_count: i64) (elements: i64)
    (chunk_index: i64) (values: [groups*chunk_count*elements]f32)
    : [groups*elements]f32 =
  piece_gather_chunk groups chunk_count elements chunk_index values

entry conf_piece_put_chunk (groups: i64) (chunk_count: i64) (elements: i64)
    (chunk_index: i64) (destination: [groups*chunk_count*elements]f32)
    (source: [groups*elements]f32): [groups*chunk_count*elements]f32 =
  piece_put_chunk groups chunk_count elements chunk_index destination source

-- ==
-- entry: test_piece_head_permutations
-- input { }
-- output { true }
entry test_piece_head_permutations: bool =
  let x = map f32.i64 (iota (1*3*2*4))
  let split = piece_split_heads_fwd 1 3 2 4 x
  let merged = piece_merge_heads_fwd 1 3 2 4 split
  let pulled = piece_split_heads_bwd 1 3 2 4 split
  in all (\i -> merged[i] == x[i] && pulled[i] == x[i]) (iota (1*3*2*4))

-- ==
-- entry: test_piece_causal_softmax
-- input { }
-- output { true }
entry test_piece_causal_softmax: bool =
  let weights = piece_causal_softmax_fwd 1 2 2
                  (replicate (1*2*2) 0.0f32)
  in weights[0] == 1.0f32 && weights[1] == 0.0f32 &&
     weights[2] == 0.5f32 && weights[3] == 0.5f32

-- ==
-- entry: test_piece_ce_effective_batch
-- input { }
-- output { true }
entry test_piece_ce_effective_batch: bool =
  let logits = replicate (1*3*2) 0.0f32
  let token_data = [0i64, 1i64, 0i64]
  let tokens = tabulate (1*3) (\i -> token_data[i])
  let loss1 = piece_ce_fwd 1 3 2 1 logits tokens
  let loss2 = piece_ce_fwd 1 3 2 2 logits tokens
  let grad = piece_ce_bwd 1 3 2 1 1.0f32 logits tokens
  in f32.abs (loss1 - 2.0f32*loss2) < 1.0e-6f32 &&
     grad[0] == 0.25f32 && grad[1] == -0.25f32 &&
     grad[2] == -0.25f32 && grad[3] == 0.25f32 &&
     grad[4] == 0.0f32 && grad[5] == 0.0f32

-- Hoisting the per-head norm out of l2_normalize_heads is pure let-floating, so
-- the forward is required to be EXACTLY unchanged.  This pins that against a
-- frozen copy of the per-element form at a shape with several heads.
def l2_normalize_heads_per_element [d] (h: i64) (x: [d]f32): [d]f32 =
  let hd = d / h
  in tabulate d (\j ->
       let head_base = (j / hd) * hd
       let norm = f32.sqrt (1.0e-6f32 +
         f32.sum (map (\c -> x[head_base+c] * x[head_base+c]) (iota hd)))
       in x[j] / norm)

-- ==
-- entry: test_piece_l2norm_heads_hoist_is_exact
-- input { }
-- output { true }
entry test_piece_l2norm_heads_hoist_is_exact: bool =
  let rows = 5i64
  let d = 24i64
  let h = 4i64
  let x = tabulate (rows*d) (\i -> f32.sin (f32.i64 (i * 11 + 1)))
  let hoisted = piece_l2norm_heads_fwd rows d h x
  let reference = flatten (map (l2_normalize_heads_per_element h)
                               (unflatten x :> [rows][d]f32))
  in all (\i -> hoisted[i] == reference[i]) (iota (rows*d))

-- The handwritten closed-form pullback against the AD-generated one.  Different
-- float expressions, so the bound is relative rather than exact.
-- ==
-- entry: test_piece_l2norm_heads_closed_matches_vjp
-- input { }
-- output { true }
entry test_piece_l2norm_heads_closed_matches_vjp: bool =
  let rows = 5i64
  let d = 24i64
  let h = 4i64
  let x = tabulate (rows*d) (\i -> f32.sin (f32.i64 (i * 11 + 1)))
  let output_bar = tabulate (rows*d) (\i -> f32.cos (f32.i64 (i * 7 + 3)))
  let from_vjp = piece_l2norm_heads_bwd rows d h x output_bar
  let closed = piece_l2norm_heads_bars h x output_bar
  in all (\i -> f32.abs (closed[i] - from_vjp[i])
                  <= 1.0e-5f32 * (1.0f32 + f32.abs from_vjp[i]))
         (iota (rows*d))

-- The superseded output-owned form of the embedding pullback, frozen here as
-- the reference the grouped implementation must reproduce.  Theta(v*d*count),
-- which is exactly why it is no longer what piece_embed_scatter does.
def piece_embed_scatter_reference [count] (v: i64) (d: i64)
    (tokens: [count]i64) (output_bar_flat: [count*d]f32): [v*d]f32 =
  let output_bar = unflatten output_bar_flat :> [count][d]f32
  in tabulate (v*d) (\idx ->
       let word = idx / d
       let c = idx % d
       in f32.sum (map (\i -> if tokens[i] == word then output_bar[i,c]
                              else 0.0f32) (iota count)))

-- The grouped scatter-add must agree with the frozen reference element-wise, at
-- dimensions where the vocabulary is not trivially covered and tokens repeat
-- heavily: v=64, d=8, count=256, so every word carries four positions on
-- average and words 32..63 carry none at all.  The two sum in different orders,
-- so the bound is a relative one rather than exact equality; the small-integer
-- exactness case is the test below.
-- ==
-- entry: test_piece_embedding_scatter_matches_reference
-- input { }
-- output { true }
entry test_piece_embedding_scatter_matches_reference: bool =
  let v = 64i64
  let d = 8i64
  let count = 256i64
  -- Deterministic, duplicate-heavy, and deliberately non-uniform: token 0
  -- appears far more often than any other, so one segment is long.
  let tokens = tabulate count (\i -> if i % 5 == 0 then 0i64 else (i * 7 + 3) % 32)
  let bar = tabulate (count*d) (\i -> f32.sin (f32.i64 (i * 13 + 1)))
  let actual = piece_embed_gather_bwd v d count tokens bar
  let expected = piece_embed_scatter_reference v d tokens bar
  in all (\i -> f32.abs (actual[i] - expected[i])
                  <= 1.0e-5f32 * (1.0f32 + f32.abs expected[i]))
         (iota (v*d))

-- Duplicate token IDs must scatter-add, not overwrite.
-- ==
-- entry: test_piece_embedding_scatter
-- input { }
-- output { true }
entry test_piece_embedding_scatter: bool =
  let bar_data = [1.0f32, 2.0f32, 3.0f32, 4.0f32, 5.0f32, 6.0f32]
  let scattered = piece_embed_gather_bwd 3 2 3 [1i64, 1i64, 0i64]
    (tabulate (3*2) (\i -> bar_data[i]))
  in scattered[0] == 5.0f32 && scattered[1] == 6.0f32 &&
     scattered[2] == 4.0f32 && scattered[3] == 6.0f32 &&
     scattered[4] == 0.0f32 && scattered[5] == 0.0f32
