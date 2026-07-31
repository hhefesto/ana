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

-- Handwritten pullback of piece_l2norm_heads, in the piece_gla_intra_bars
-- style: the quantities that depend only on (row, head) are computed once and
-- shared by that head's hd components, and every output element is owned by one
-- thread.
--
-- Per head, with s = 1e-6 + sum_c x_c^2, norm = sqrt s, and u = x / norm:
--   y_j    = x_j / norm
--   dy_j/dx_i = [i=j]/norm - x_j x_i / norm^3
--   xbar_i = (obar_i - u_i * (u . obar)) / norm
-- The epsilon is additive in s and so does not change the formula: it shifts
-- norm, and norm is what the expression is written in terms of.
--
-- NOT wired into piece_l2norm_heads_bwd, which still takes vjp2 of the forward,
-- and on present evidence it should stay that way.  Measured on the C backend
-- at the bpe100m shape (rows=256, d=768, h=12, 20 reps): the superseded
-- per-element vjp is 23,652 us, vjp of the hoisted forward is 4,953 us, and
-- this closed form is 5,109 us.  Hoisting the norm (see l2_normalize_heads in
-- model.fut) recovers the entire 4.8x on its own while leaving the pullback
-- correct by construction; the handwritten form is 3% slower and carries the
-- divergence risk for nothing.
--
-- It is kept because the CPU ranking need not survive to CUDA, where the cost
-- being removed is lock-guarded atomic accumulation rather than arithmetic.
-- check_l2_bwd_closed_vs_vjp and check_l2_bwd_closed in kernel-check.fut make
-- the comparison reproducible on a real GPU; switching is one line in
-- pieces.fut if the measurement there disagrees.
def piece_l2norm_heads_bars [rows] [d]
    (h: i64) (x_flat: [rows*d]f32) (output_bar_flat: [rows*d]f32): [rows*d]f32 =
  let checked = assert (h > 0 && d > 0 && d % h == 0) x_flat
  let hd = d / h
  let x = unflatten checked :> [rows][d]f32
  let output_bar = unflatten output_bar_flat :> [rows][d]f32
  let norms = tabulate_2d rows h (\r head ->
    let base = head * hd
    in f32.sqrt (1.0e-6f32 +
         f32.sum (map (\c -> x[r, base+c] * x[r, base+c]) (iota hd))))
  -- u . obar, the only other quantity shared across a head's components.
  let projections = tabulate_2d rows h (\r head ->
    let base = head * hd
    let norm = norms[r, head]
    in f32.sum (map (\c -> (x[r, base+c] / norm) * output_bar[r, base+c])
                    (iota hd)))
  in flatten (tabulate_2d rows d (\r j ->
       let head = j / hd
       let norm = norms[r, head]
       in (output_bar[r, j] - (x[r, j] / norm) * projections[r, head]) / norm))

-- Input and relcum are [groups][chunk][hd], where groups is B*nc*h.
-- dec is the total log-decay of each group/channel.
def piece_gate_cum [groups] [chunk] [hd]
    (gate_logits: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*hd]f32) =
  let checked = assert (chunk > 0 && hd > 0) gate_logits
  let logits = unflatten (unflatten checked :> [groups*chunk][hd]f32)
               :> [groups][chunk][hd]f32
  let logs = map (map (map gate_log)) logits
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
  -- The attention weight depends only on (g, i, s), never on the output
  -- component, so it is computed once per pair and shared by that pair's hd
  -- output components (pure let-floating; no f32 reassociation).  The
  -- per-element form cost O(chunk^2 * hd^2) per group and dominated the
  -- profiled step.
  let a = tabulate_3d groups chunk chunk (\g i s ->
    if s > i then 0.0f32
    else f32.sum (map (\c -> q[g,i,c] * k[g,s,c] *
                        f32.exp (rel[g,i,c] - rel[g,s,c])) (iota hd)))
  let output = tabulate_3d groups chunk hd (\g i j ->
    f32.sum (map (\s ->
      if s > i then 0.0f32
      else a[g,i,s] * values[g,s,j]) (iota chunk)))
  in flatten (flatten output)

-- Handwritten pullback of piece_gla_intra.  The vjp of the per-element
-- forward recomputed the (i, s) attention weight for every output component
-- and dominated the whole bpe10m step (~194 ms per call, 48x the forward);
-- here the weight matrix A[i,s] and its cotangent are computed once per
-- group (they depend only on (g, i, s)) and each input cotangent is the
-- standard O(chunk^2*hd) contraction.
--   A[i,s]    = mask(s<=i) sum_c q[i,c] k[s,c] e^(rel[i,c]-rel[s,c])
--   O[i,j]    = sum_{s<=i} A[i,s] v[s,j]
--   vbar[s,j] = sum_{i>=s} A[i,s] obar[i,j]
--   Abar[i,s] = mask(s<=i) sum_j obar[i,j] v[s,j]
--   qbar[i,c] = sum_{s<=i} Abar[i,s] k[s,c] e^(rel[i,c]-rel[s,c])
--   kbar[s,c] = sum_{i>=s} Abar[i,s] q[i,c] e^(rel[i,c]-rel[s,c])
--   relbar[i,c] = sum_{s<=i} Abar[i,s] W[i,s,c] - sum_{p>=i} Abar[p,i] W[p,i,c]
--     where W[i,s,c] = q[i,c] k[s,c] e^(rel[i,c]-rel[s,c])
def piece_gla_intra_bars [groups] [chunk] [hd]
    (q_flat: [groups*chunk*hd]f32) (k_flat: [groups*chunk*hd]f32)
    (v_flat: [groups*chunk*hd]f32) (rel_flat: [groups*chunk*hd]f32)
    (output_bar_flat: [groups*chunk*hd]f32)
    : ([groups*chunk*hd]f32, [groups*chunk*hd]f32,
       [groups*chunk*hd]f32, [groups*chunk*hd]f32) =
  let q = unflatten (unflatten q_flat :> [groups*chunk][hd]f32)
          :> [groups][chunk][hd]f32
  let k = unflatten (unflatten k_flat :> [groups*chunk][hd]f32)
          :> [groups][chunk][hd]f32
  let values = unflatten (unflatten v_flat :> [groups*chunk][hd]f32)
               :> [groups][chunk][hd]f32
  let rel = unflatten (unflatten rel_flat :> [groups*chunk][hd]f32)
            :> [groups][chunk][hd]f32
  let output_bar =
    unflatten (unflatten output_bar_flat :> [groups*chunk][hd]f32)
    :> [groups][chunk][hd]f32
  let weight = \g i s c -> q[g,i,c] * k[g,s,c] * f32.exp (rel[g,i,c] - rel[g,s,c])
  let a = tabulate_3d groups chunk chunk (\g i s ->
    if s > i then 0.0f32
    else f32.sum (map (\c -> weight g i s c) (iota hd)))
  let a_bar = tabulate_3d groups chunk chunk (\g i s ->
    if s > i then 0.0f32
    else f32.sum (map (\j -> output_bar[g,i,j] * values[g,s,j]) (iota hd)))
  let q_bar = tabulate_3d groups chunk hd (\g i c ->
    f32.sum (map (\s ->
      if s > i then 0.0f32
      else a_bar[g,i,s] * k[g,s,c] * f32.exp (rel[g,i,c] - rel[g,s,c]))
      (iota chunk)))
  let k_bar = tabulate_3d groups chunk hd (\g s c ->
    f32.sum (map (\i ->
      if i < s then 0.0f32
      else a_bar[g,i,s] * q[g,i,c] * f32.exp (rel[g,i,c] - rel[g,s,c]))
      (iota chunk)))
  let v_bar = tabulate_3d groups chunk hd (\g s j ->
    f32.sum (map (\i ->
      if i < s then 0.0f32
      else a[g,i,s] * output_bar[g,i,j]) (iota chunk)))
  let rel_bar = tabulate_3d groups chunk hd (\g i c ->
    f32.sum (map (\s ->
      if s > i then 0.0f32
      else a_bar[g,i,s] * weight g i s c) (iota chunk))
    - f32.sum (map (\p ->
        if p < i then 0.0f32
        else a_bar[g,p,i] * weight g p i c) (iota chunk)))
  in (flatten (flatten q_bar), flatten (flatten k_bar),
      flatten (flatten v_bar), flatten (flatten rel_bar))

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
  let checked = assert (batch > 0 && sequence >= 2 && v > 0 &&
                        effective_batch >= batch && valid_tokens v tokens)
                       logits_flat
  let denom = f32.i64 effective_batch * f32.i64 (sequence-1)
  -- Row-invariant softmax statistics hoisted into flat per-row arrays (same
  -- expressions and reduction order as piece_ce_loss, so values are
  -- unchanged), then the pullback as ONE flat regular tabulate over
  -- elements.  The previous tabulate_2d whose body produced a [v] array was
  -- mis-lowered by the CUDA codegen at production dims: piece_ce_bwd
  -- returned mis-indexed rows (the sequence-1 guard rows came back
  -- nonzero) while the identical source compiled correctly on the C
  -- backend — see the head-path-probe in backend/gemm/GemmKernels.hs.
  -- Flat index math over elements is the shape every other piece uses.
  let rows = unflatten checked :> [batch*sequence][v]f32
  let row_max = map f32.maximum rows
  let row_sum = map2 (\row m -> f32.sum (map (\z -> f32.exp (z - m)) row))
                     rows row_max
  in tabulate (batch*sequence*v) (\idx ->
       let r = idx / v
       let word = idx % v
       let i = r % sequence
       in if i == sequence - 1 then 0.0f32
          else
            let p = f32.exp (checked[idx] - row_max[r]) / row_sum[r]
            let hit = if word == tokens[r+1] then 1.0f32 else 0.0f32
            in loss_bar * (p - hit) / denom)

def piece_embed_gather [v] [d] [count]
    (embedding_flat: [v*d]f32) (tokens: [count]i64): [count*d]f32 =
  let embedding = unflatten embedding_flat :> [v][d]f32
  let checked = assert (v > 0 && valid_tokens v tokens) tokens
  in flatten (map (\token -> embedding[token]) checked)

-- Segmented inclusive scan.  There is no futhark.pkg in this repo, so
-- github.com/diku-dk/segmented is unavailable and the operator is spelled out.
-- It is associative: the flag disjunction is, and the value branch takes the
-- right operand whenever the right segment has already started.
def segmented_scan_add [n] (flags: [n]bool) (values: [n]f32): [n]f32 =
  let combine (f1, x1) (f2, x2) = (f1 || f2, if f2 then x2 else x1 + x2)
  in map (.1) (scan combine (false, 0.0f32) (zip flags values))

-- The pullback of the embedding gather: a scatter-add, since duplicate token
-- IDs must accumulate rather than overwrite.
--
-- The obvious output-owned form -- tabulate (v*d) with an inner sum over every
-- token -- is Theta(v*d*count), which at bpe100m is 4.1e11 element visits for
-- 1.26e7 useful adds, one launch of ~129 ms, 12.5% of kernel time.  It is
-- written that way because it is race-free: each output belongs to one thread.
--
-- This form keeps that property and drops the vocabulary factor.  Positions are
-- grouped by token with a stable counting sort, then each word's contributions
-- are summed by one segmented scan and placed by a scatter at distinct indices.
--
-- Deliberately NOT reduce_by_index over f32: its CUDA lowering accumulates with
-- atomics, which makes the sum order vary run to run.  A 4.7-day training run
-- has to be reproducible, so the only reduce_by_index here is over i64, where
-- addition is exactly associative and commutative and the order cannot matter.
--
-- The sum order within a word differs from the superseded form (a flat reduce
-- over all `count` slots, most of them zero), so this is not bit-identical to
-- it; conf_piece_embed_scatter_reference in pieces-conformance.fut pins the
-- agreement element-wise.
def piece_embed_scatter [v] [d] [count]
    (tokens: [count]i64) (output_bar_flat: [count*d]f32): [v*d]f32 =
  let output_bar = unflatten output_bar_flat :> [count][d]f32
  let checked = assert (v > 0 && valid_tokens v tokens) tokens
  -- How many positions carry each word, and where that word's run begins.
  let counts = reduce_by_index (replicate v 0i64) (+) 0i64 checked
                 (replicate count 1i64)
  let inclusive = scan (+) 0i64 counts
  let starts = map2 (-) inclusive counts
  -- Rank of position i among the earlier positions carrying the same token.
  -- Theta(count^2) and fully regular: no atomics, no irregular nesting, and
  -- ~1500x below the cost this replaces.  A radix sort would make it
  -- Theta(count log count) if `count` ever grows past a batch of windows.
  let ranks = tabulate count (\i ->
    i64.sum (map (\j -> if j < i && checked[j] == checked[i] then 1i64 else 0i64)
                 (iota count)))
  let destination = map2 (\token rank -> starts[token] + rank) checked ranks
  -- Every destination is distinct, so this scatter is deterministic.
  let order = scatter (replicate count 0i64) destination (iota count)
  let sorted_tokens = map (\position -> checked[position]) order
  let flags = tabulate count (\r -> r == 0 || sorted_tokens[r] != sorted_tokens[r-1])
  let summed = tabulate d (\c ->
    segmented_scan_add flags (map (\position -> output_bar[position, c]) order))
  in tabulate (v*d) (\idx ->
       let word = idx / d
       let c = idx % d
       let n = counts[word]
       in if n == 0 then 0.0f32 else summed[c, starts[word] + n - 1])

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

-- Pure data movement for the device-resident host traversal: parameter-slice
-- reads/writes against the flat vector and per-chunk gather/scatter in the
-- grouped [groups][chunk_count][elements] layout.  No VJPs: these never carry
-- derivatives of their own.

def piece_slice_read [n] (offset: i64) (count: i64)
    (source: [n]f32): [count]f32 =
  let checked = assert (offset >= 0 && count >= 0 && offset + count <= n) source
  in tabulate count (\index -> checked[offset + index])

def piece_slice_write [n] [m] (offset: i64)
    (destination: [n]f32) (source: [m]f32): [n]f32 =
  let checked = assert (offset >= 0 && offset + m <= n) destination
  in tabulate n (\index ->
    if index >= offset && index < offset + m
    then source[index - offset]
    else checked[index])

def piece_chunk_gather [groups] [chunk_count] [elements] (chunk_index: i64)
    (values: [groups*chunk_count*elements]f32): [groups*elements]f32 =
  let checked = assert (chunk_index >= 0 && chunk_index < chunk_count) values
  in tabulate (groups*elements) (\index ->
    let element = index % elements
    let group = index / elements
    in checked[(group*chunk_count + chunk_index)*elements + element])

def piece_chunk_put [groups] [chunk_count] [elements] (chunk_index: i64)
    (destination: [groups*chunk_count*elements]f32)
    (source: [groups*elements]f32): [groups*chunk_count*elements]f32 =
  let checked = assert (chunk_index >= 0 && chunk_index < chunk_count) destination
  in tabulate (groups*chunk_count*elements) (\index ->
    let element = index % elements
    let rest = index / elements
    let position = rest % chunk_count
    let group = rest / chunk_count
    in if position == chunk_index
       then source[group*elements + element]
       else checked[index])
