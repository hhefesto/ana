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
