-- Definitions for the flat Stage-B BLAS boundary.  Matrices are represented
-- by one-dimensional row-major buffers at every entry boundary.

open import "model"

def piece_rms [rows] [d]
    (inputs: ([rows*d]f32, [d]f32)): [rows*d]f32 =
  let (x, gain) = inputs
  let checked = assert (d > 0) x
  in flatten (map (\row -> rms_norm row gain)
              (unflatten checked :> [rows][d]f32))

def piece_l2norm_heads [rows] [d]
    (h: i64) (x: [rows*d]f32): [rows*d]f32 =
  let checked = assert (h > 0 && d > 0 && d % h == 0) x
  in flatten (map (l2_normalize_heads h)
              (unflatten checked :> [rows][d]f32))

-- Input and relcum are [groups][chunk][hd], where groups is B*nc*h.
-- dec is the total log-decay of each group/channel.
def piece_gate_cum [groups] [chunk] [hd]
    (gate_logits: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*hd]f32) =
  let checked = assert (chunk > 0 && hd > 0) gate_logits
  let logits = unflatten (unflatten checked :> [groups*chunk][hd]f32)
               :> [groups][chunk][hd]f32
  let logs = map (map (map log_sigmoid)) logits
  let relcum = map (\group ->
    tabulate_2d chunk hd (\i c ->
      f32.sum (map (\r -> if r <= i then group[r,c] else 0.0f32)
                   (iota chunk)))) logs
  let dec = map (\group -> group[chunk-1]) relcum
  in (flatten (flatten relcum), flatten dec)

def piece_qk_decay [groups] [chunk] [hd]
    (inputs: ([groups*chunk*hd]f32, [groups*chunk*hd]f32,
              [groups*chunk*hd]f32, [groups*hd]f32))
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32) =
  let (q_flat, k_flat, rel_flat, dec_flat) = inputs
  let q = unflatten (unflatten q_flat :> [groups*chunk][hd]f32)
          :> [groups][chunk][hd]f32
  let k = unflatten (unflatten k_flat :> [groups*chunk][hd]f32)
          :> [groups][chunk][hd]f32
  let rel = unflatten (unflatten rel_flat :> [groups*chunk][hd]f32)
            :> [groups][chunk][hd]f32
  let dec = unflatten dec_flat :> [groups][hd]f32
  let q_scaled = tabulate_3d groups chunk hd
    (\g i c -> q[g,i,c] * f32.exp rel[g,i,c])
  let k_scaled = tabulate_3d groups chunk hd
    (\g i c -> k[g,i,c] * f32.exp (dec[g,c] - rel[g,i,c]))
  in (flatten (flatten q_scaled), flatten (flatten k_scaled))

-- Chunk-local causal GLA term.  Inter-chunk Q*S and K^T*V contractions stay
-- at the BLAS boundary and are deliberately absent here.
def piece_gla_intra [groups] [chunk] [hd]
    (inputs: ([groups*chunk*hd]f32, [groups*chunk*hd]f32,
              [groups*chunk*hd]f32, [groups*chunk*hd]f32))
    : [groups*chunk*hd]f32 =
  let (q_flat, k_flat, v_flat, rel_flat) = inputs
  let q = unflatten (unflatten q_flat :> [groups*chunk][hd]f32)
          :> [groups][chunk][hd]f32
  let k = unflatten (unflatten k_flat :> [groups*chunk][hd]f32)
          :> [groups][chunk][hd]f32
  let values = unflatten (unflatten v_flat :> [groups*chunk][hd]f32)
               :> [groups][chunk][hd]f32
  let rel = unflatten (unflatten rel_flat :> [groups*chunk][hd]f32)
            :> [groups][chunk][hd]f32
  let output = tabulate_3d groups chunk hd (\g i j ->
    f32.sum (map (\s ->
      if s > i then 0.0f32
      else f32.sum (map (\c -> q[g,i,c] * k[g,s,c] *
                          f32.exp (rel[g,i,c] - rel[g,s,c])) (iota hd))
           * values[g,s,j]) (iota chunk)))
  in flatten (flatten output)

-- Advance exactly one chunk.  The host invokes this in forward chunk order
-- (and its pullback in reverse order); no differentiated loop is hidden here.
def piece_state_advance [groups] [hd]
    (inputs: ([groups*hd*hd]f32, [groups*hd*hd]f32, [groups*hd]f32))
    : [groups*hd*hd]f32 =
  let (state_flat, contribution_flat, dec_flat) = inputs
  let state = unflatten (unflatten state_flat :> [groups*hd][hd]f32)
              :> [groups][hd][hd]f32
  let contribution =
    unflatten (unflatten contribution_flat :> [groups*hd][hd]f32)
    :> [groups][hd][hd]f32
  let dec = unflatten dec_flat :> [groups][hd]f32
  in flatten (flatten (tabulate_3d groups hd hd
       (\g c j -> f32.exp dec[g,c] * state[g,c,j] + contribution[g,c,j])))

-- Raw QK scores enter as [groups][n][n].  This piece performs only scale,
-- causal masking, and softmax; PV remains a host BLAS contraction.
def piece_causal_softmax [groups] [n]
    (head_dim: i64) (scores_flat: [groups*n*n]f32): [groups*n*n]f32 =
  let checked = assert (n > 0 && head_dim > 0) scores_flat
  let scores = unflatten (unflatten checked :> [groups*n][n]f32)
               :> [groups][n][n]f32
  let scale = 1.0f32 / f32.sqrt (f32.i64 head_dim)
  in flatten (flatten (tabulate_2d groups n (\g i ->
       softmax (tabulate n (\j ->
         if j <= i then scores[g,i,j] * scale else -1.0e30f32)))))

def piece_silu_gate [count]
    (inputs: ([count]f32, [count]f32)): [count]f32 =
  let (gate, up) = inputs
  in map2 (\g u -> silu g * u) gate up

-- Partial mean CE for a micro-batch.  Both loss and dlogits are divided by
-- effective_batch, while each sequence is independently averaged over its
-- predicted positions, exactly matching micro_batch_loss_grad.
def piece_ce_loss [batch] [sequence] [v]
    (effective_batch: i64) (logits_flat: [batch*sequence*v]f32)
    (tokens: [batch*sequence]i64): f32 =
  let logits = unflatten (unflatten logits_flat :> [batch*sequence][v]f32)
               :> [batch][sequence][v]f32
  let tok = unflatten tokens :> [batch][sequence]i64
  let checked = assert (batch > 0 && sequence >= 2 && v > 0 &&
                        effective_batch >= batch && valid_tokens v tokens) logits
  let losses = tabulate_2d batch (sequence-1) (\b i ->
    let row = checked[b,i]
    let maximum = f32.maximum row
    let log_partition = maximum +
      f32.log (f32.sum (map (\z -> f32.exp (z-maximum)) row))
    in log_partition - row[tok[b,i+1]])
  in f32.sum (flatten losses) /
     (f32.i64 effective_batch * f32.i64 (sequence-1))

def piece_ce_dlogits [batch] [sequence] [v]
    (effective_batch: i64) (loss_bar: f32)
    (logits_flat: [batch*sequence*v]f32) (tokens: [batch*sequence]i64)
    : [batch*sequence*v]f32 =
  let logits = unflatten (unflatten logits_flat :> [batch*sequence][v]f32)
               :> [batch][sequence][v]f32
  let tok = unflatten tokens :> [batch][sequence]i64
  let checked = assert (batch > 0 && sequence >= 2 && v > 0 &&
                        effective_batch >= batch && valid_tokens v tokens) logits
  let denom = f32.i64 effective_batch * f32.i64 (sequence-1)
  in flatten (flatten (tabulate_3d batch sequence v (\b i word ->
       if i == sequence-1 then 0.0f32
       else loss_bar * ((softmax checked[b,i])[word] -
                        (if word == tok[b,i+1] then 1.0f32 else 0.0f32)) / denom)))

def piece_embed_gather [v] [d] [count]
    (embedding_flat: [v*d]f32) (tokens: [count]i64): [count*d]f32 =
  let embedding = unflatten embedding_flat :> [v][d]f32
  let checked = assert (v > 0 && valid_tokens v tokens) tokens
  in flatten (map (\token -> embedding[token]) checked)

def piece_embed_scatter [v] [d] [count]
    (tokens: [count]i64) (output_bar_flat: [count*d]f32): [v*d]f32 =
  let output_bar = unflatten output_bar_flat :> [count][d]f32
  let checked = assert (v > 0 && valid_tokens v tokens) tokens
  in tabulate (v*d) (\idx ->
       let word = idx / d
       let c = idx % d
       in f32.sum (map (\i -> if checked[i] == word then output_bar[i,c]
                              else 0.0f32) (iota count)))

-- [batch][n][h*hd] <-> [batch][h][n][hd], exact inverse permutations.
def piece_split_heads [batch] [n] [h] [hd]
    (x: [batch*n*h*hd]f32): [batch*h*n*hd]f32 =
  let checked = assert (h > 0 && hd > 0) x
  in tabulate (batch*h*n*hd) (\idx ->
    let c = idx % hd
    let q = idx / hd
    let i = q % n
    let q = q / n
    let head = q % h
    let b = q / h
    in checked[(b*n+i)*(h*hd) + head*hd+c])

def piece_merge_heads [batch] [n] [h] [hd]
    (x: [batch*h*n*hd]f32): [batch*n*h*hd]f32 =
  let checked = assert (h > 0 && hd > 0) x
  in tabulate (batch*n*h*hd) (\idx ->
    let c = idx % (h*hd)
    let q = idx / (h*hd)
    let i = q % n
    let b = q / n
    in checked[((b*h + c/hd)*n + i)*hd + c%hd])

def piece_add [count]
    (inputs: ([count]f32, [count]f32)): [count]f32 =
  let (x, y) = inputs in map2 (+) x y
