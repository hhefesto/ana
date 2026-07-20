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
