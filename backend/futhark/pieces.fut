-- Stage-B nonlinear and elementwise library.  Every public array is flat;
-- dependent sizes document and enforce its logical shape at the C ABI.

open import "pieces-defs"

entry piece_rms_norm_fwd (rows: i64) (d: i64)
    (x: [rows*d]f32) (gain: [d]f32): [rows*d]f32 =
  piece_rms (x, gain)

entry piece_rms_norm_bwd (rows: i64) (d: i64)
    (x: [rows*d]f32) (gain: [d]f32) (output_bar: [rows*d]f32)
    : ([rows*d]f32, [d]f32) =
  let (_, bars) = vjp2 piece_rms (x, gain) output_bar in bars

entry piece_l2norm_heads_fwd (rows: i64) (d: i64)
    (h: i64) (x: [rows*d]f32): [rows*d]f32 =
  piece_l2norm_heads h x

entry piece_l2norm_heads_bwd (rows: i64) (d: i64)
    (h: i64) (x: [rows*d]f32) (output_bar: [rows*d]f32): [rows*d]f32 =
  let (_, x_bar) = vjp2 (piece_l2norm_heads h) x output_bar in x_bar

entry piece_gate_cum_fwd (groups: i64) (chunk: i64) (hd: i64)
    (gate_logits: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*hd]f32) =
  piece_gate_cum gate_logits

entry piece_gate_cum_bwd (groups: i64) (chunk: i64) (hd: i64)
    (gate_logits: [groups*chunk*hd]f32)
    (relcum_bar: [groups*chunk*hd]f32) (dec_bar: [groups*hd]f32)
    : [groups*chunk*hd]f32 =
  let (_, input_bar) = vjp2 piece_gate_cum gate_logits (relcum_bar, dec_bar)
  in input_bar

entry piece_qk_decay_fwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (relcum: [groups*chunk*hd]f32) (dec: [groups*hd]f32)
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32) =
  piece_qk_decay (q, k, relcum, dec)

entry piece_qk_decay_bwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (relcum: [groups*chunk*hd]f32) (dec: [groups*hd]f32)
    (q_scaled_bar: [groups*chunk*hd]f32)
    (k_scaled_bar: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32,
       [groups*chunk*hd]f32, [groups*hd]f32) =
  let (_, bars) = vjp2 piece_qk_decay (q, k, relcum, dec)
                       (q_scaled_bar, k_scaled_bar)
  in bars

entry piece_gla_intra_fwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (values: [groups*chunk*hd]f32) (relcum: [groups*chunk*hd]f32)
    : [groups*chunk*hd]f32 =
  piece_gla_intra (q, k, values, relcum)

entry piece_gla_intra_bwd (groups: i64) (chunk: i64) (hd: i64)
    (q: [groups*chunk*hd]f32) (k: [groups*chunk*hd]f32)
    (values: [groups*chunk*hd]f32) (relcum: [groups*chunk*hd]f32)
    (output_bar: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32,
       [groups*chunk*hd]f32, [groups*chunk*hd]f32) =
  piece_gla_intra_bars q k values relcum output_bar

entry piece_state_advance_fwd (groups: i64) (hd: i64)
    (state: [groups*hd*hd]f32) (contribution: [groups*hd*hd]f32)
    (dec: [groups*hd]f32): [groups*hd*hd]f32 =
  piece_state_advance (state, contribution, dec)

entry piece_state_advance_bwd (groups: i64) (hd: i64)
    (state: [groups*hd*hd]f32) (contribution: [groups*hd*hd]f32)
    (dec: [groups*hd]f32) (output_bar: [groups*hd*hd]f32)
    : ([groups*hd*hd]f32, [groups*hd*hd]f32, [groups*hd]f32) =
  let (_, bars) = vjp2 piece_state_advance (state, contribution, dec) output_bar
  in bars

entry piece_causal_softmax_fwd (groups: i64) (n: i64)
    (head_dim: i64) (scores: [groups*n*n]f32): [groups*n*n]f32 =
  piece_causal_softmax head_dim scores

entry piece_causal_softmax_bwd (groups: i64) (n: i64)
    (head_dim: i64) (scores: [groups*n*n]f32)
    (weights_bar: [groups*n*n]f32): [groups*n*n]f32 =
  let (_, scores_bar) = vjp2 (piece_causal_softmax head_dim) scores weights_bar
  in scores_bar

entry piece_silu_gate_fwd [count]
    (gate: [count]f32) (up: [count]f32): [count]f32 =
  piece_silu_gate (gate, up)

entry piece_silu_gate_bwd [count]
    (gate: [count]f32) (up: [count]f32) (output_bar: [count]f32)
    : ([count]f32, [count]f32) =
  let (_, bars) = vjp2 piece_silu_gate (gate, up) output_bar in bars

entry piece_ce_fwd (batch: i64) (sequence: i64) (v: i64)
    (effective_batch: i64) (logits: [batch*sequence*v]f32)
    (tokens: [batch*sequence]i64): f32 =
  piece_ce_loss effective_batch logits tokens

entry piece_ce_bwd (batch: i64) (sequence: i64) (v: i64)
    (effective_batch: i64) (loss_bar: f32)
    (logits: [batch*sequence*v]f32) (tokens: [batch*sequence]i64)
    : [batch*sequence*v]f32 =
  piece_ce_dlogits effective_batch loss_bar logits tokens

entry piece_embed_gather_fwd (v: i64) (d: i64) (count: i64)
    (embedding: [v*d]f32) (tokens: [count]i64): [count*d]f32 =
  piece_embed_gather embedding tokens

entry piece_embed_gather_bwd (v: i64) (d: i64) (count: i64)
    (tokens: [count]i64) (output_bar: [count*d]f32): [v*d]f32 =
  piece_embed_scatter tokens output_bar

entry piece_split_heads_fwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (x: [batch*n*h*hd]f32): [batch*h*n*hd]f32 =
  piece_split_heads x

entry piece_split_heads_bwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (output_bar: [batch*h*n*hd]f32): [batch*n*h*hd]f32 =
  piece_merge_heads output_bar

entry piece_merge_heads_fwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (x: [batch*h*n*hd]f32): [batch*n*h*hd]f32 =
  piece_merge_heads x

entry piece_merge_heads_bwd (batch: i64) (n: i64) (h: i64) (hd: i64)
    (output_bar: [batch*n*h*hd]f32): [batch*h*n*hd]f32 =
  piece_split_heads output_bar

entry piece_add_fwd [count]
    (x: [count]f32) (y: [count]f32): [count]f32 = piece_add (x, y)

entry piece_add_bwd [count]
    (output_bar: [count]f32): ([count]f32, [count]f32) =
  (output_bar, output_bar)

entry piece_accumulate [count]
    (accumulator: [count]f32) (addition: [count]f32): [count]f32 =
  map2 (+) accumulator addition

entry piece_read_slice (n: i64) (offset: i64) (count: i64)
    (source: [n]f32): [count]f32 =
  piece_slice_read offset count source

entry piece_write_slice (n: i64) (m: i64) (offset: i64)
    (destination: [n]f32) (source: [m]f32): [n]f32 =
  piece_slice_write offset destination source

entry piece_gather_chunk (groups: i64) (chunk_count: i64) (elements: i64)
    (chunk_index: i64) (values: [groups*chunk_count*elements]f32)
    : [groups*elements]f32 =
  piece_chunk_gather chunk_index values

entry piece_put_chunk (groups: i64) (chunk_count: i64) (elements: i64)
    (chunk_index: i64) (destination: [groups*chunk_count*elements]f32)
    (source: [groups*elements]f32): [groups*chunk_count*elements]f32 =
  piece_chunk_put chunk_index destination source

entry zero_vector (count: i64): [count]f32 = zero_vector_def count

entry clip_global_norm [p] (max_norm: f32) (gradient: [p]f32)
    : (f32, [p]f32) = clip_global_norm_def max_norm gradient

entry adamw_step [p]
    (step: i64) (learning_rate: f32) (beta1: f32) (beta2: f32)
    (epsilon: f32) (weight_decay: f32)
    (params: [p]f32) (gradient: [p]f32)
    (first_moment: [p]f32) (second_moment: [p]f32)
    (decay_mask: [p]bool): ([p]f32, [p]f32, [p]f32) =
  adamw_step_def step learning_rate beta1 beta2 epsilon weight_decay
                 params gradient first_moment second_moment decay_mask
