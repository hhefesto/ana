-- Canonical bias-free HYBRID decoder kernels using one flat f32 parameter
-- vector.  Every fourth block (index % 4 == 3) is softmax full attention
-- with no positional encoding; the rest are gated linear attention (GLA)
-- blocks whose data-dependent gates carry position.  The semantics and its
-- proofs live in FormalTransformer/Attention/Linear.agda and
-- docs/RUN-2026-07-25-WIKI-FULL.md.
--
-- Layout:
--   embedding [v][d]; then, for each block:
--   rms_att [d], Wq/Wk/Wv/Wo [d][d],
--   (GLA blocks only: Walpha [d][d]),
--   rms_ff [d], Wgate/Wup [f][d], Wdown [d][f]; finally rms_final [d].
--
-- All public model entries state the exact parameter length in their
-- interface type: params must have size parameter_count v d f n_layers, so
-- a mis-laid-out vector is rejected at the entry boundary.  Assertions
-- cover only the constraints size types cannot express: v,d,f,h,n_layers
-- > 0, d % h == 0, an even head dimension d/h, token IDs in [0,v), and
-- sequence lengths (at least two wherever a next token is predicted).
--
-- This module holds every definition; the entry-point files select which
-- interpretations a backend exposes.  The OpenCL trainer program deliberately
-- contains a single differentiated entry, because rusticl's clBuildProgram
-- time grows with the amount of vjp-generated code.

-- Softmax blocks among 0..L-1 are the indices ≡ 3 (mod 4): L/4 of them.
def softmax_layers (n_layers: i64): i64 = n_layers / 4

def gla_layers (n_layers: i64): i64 = n_layers - n_layers / 4

def parameter_count (v: i64) (d: i64) (f: i64) (n_layers: i64): i64 =
  v*d + n_layers*(4*d*d + 3*f*d + 2*d) + (n_layers - n_layers / 4)*d*d + d

def block_size (d: i64) (f: i64): i64 =
  4*d*d + 3*f*d + 2*d

-- Offset of block `layer`: every earlier block contributes the softmax block
-- size and the earlier GLA blocks add their gate projection.
def block_base (v: i64) (d: i64) (f: i64) (layer: i64): i64 =
  v*d + layer*block_size d f + (layer - layer / 4)*d*d

def vector [p] (off: i64) (n: i64) (params: [p]f32): [n]f32 =
  take n (drop off params)

def matrix [p] (off: i64) (rows: i64) (cols: i64)
           (params: [p]f32): [rows][cols]f32 =
  unflatten (vector off (rows*cols) params)

def dot [n] (x: [n]f32) (y: [n]f32): f32 =
  f32.sum (map2 (*) x y)

def matvec [m] [n] (w: [m][n]f32) (x: [n]f32): [m]f32 =
  map (\row -> dot row x) w

def add [n] (x: [n]f32) (y: [n]f32): [n]f32 = map2 (+) x y

def rms_norm [n] (x: [n]f32) (gain: [n]f32): [n]f32 =
  let mean_square = f32.sum (map (\z -> z*z) x) / f32.i64 n
  let scale = 1.0f32 / f32.sqrt (mean_square + 1.0e-5f32)
  in map2 (\z g -> z * scale * g) x gain

def softmax [n] (x: [n]f32): [n]f32 =
  let xmax = f32.maximum x
  let ex = map (\z -> f32.exp (z - xmax)) x
  let denom = f32.sum ex
  in map (\z -> z / denom) ex

-- Scores and softmax depend only on (head, i), never on the output component,
-- so they are computed once per head here and shared by that head's hd output
-- components. Every output element is still the same expression as the
-- per-component formulation (pure let-floating; no f32 reassociation), but the
-- forward work and — critically — the reverse-AD adjoint accumulations into
-- the shared q/k slices shrink by a factor of hd (measured 2026-07-16:
-- those accumulations compile to lock-guarded updates on GPUs).
def causal_attention [n] [d]
    (h: i64)
    (q: [n][d]f32) (k: [n][d]f32) (v: [n][d]f32): [n][d]f32 =
  let hd = d / h
  let inv_scale = 1.0f32 / f32.sqrt (f32.i64 hd)
  let per_head =
    tabulate h (\head ->
      let head_base = head * hd
      let qh = map (\row -> take hd (drop head_base row)) q
      let kh = map (\row -> take hd (drop head_base row)) k
      let vh = map (\row -> take hd (drop head_base row)) v
      in map (\i ->
           let scores = map (\j ->
             if j <= i
             then dot qh[i] kh[j] * inv_scale
             else -1.0e30f32) (iota n)
           let weights = softmax scores
           in tabulate hd (\within_head ->
                f32.sum (map2 (*) weights
                  (map (\j -> vh[j, within_head]) (iota n)))))
           (iota n))
  in tabulate n (\i ->
       flatten (map (\head -> per_head[head, i]) (iota h)) :> [d]f32)

-- Per-head L2 normalization written per element (like RoPE used to be):
-- each output element recomputes its head's norm, so the definition stays a
-- flat tabulate and allocates nothing inside nested parallel constructs.
def l2_normalize_heads [d] (h: i64) (x: [d]f32): [d]f32 =
  let hd = d / h
  in tabulate d (\j ->
       let head_base = (j / hd) * hd
       let norm = f32.sqrt (1.0e-6f32 +
         f32.sum (map (\c -> x[head_base+c] * x[head_base+c]) (iota hd)))
       in x[j] / norm)

-- Numerically stable log(sigmoid(z)) = -softplus(-z); the gate itself is
-- never materialized, so a saturated sigmoid cannot produce log 0.
def log_sigmoid (z: f32): f32 =
  -(f32.max (-z) 0.0f32 + f32.log1p (f32.exp (-(f32.abs z))))

-- GLA fix arms, mirrored by gateTemperature/glaOutputNorm in
-- FormalTransformer.Config (flip both languages together).  The gate is
-- alpha = sigmoid(z)^(1/tau), i.e. log-gate log_sigmoid(z)/tau: tau = 1 is
-- the historical bit pattern (x/1 is exact); tau = 16 puts the init near
-- alpha ≈ 0.958 so long memory spans keep live gradients.  gla_out_norm
-- applies the q/k per-head L2 normalization to the attended output before
-- Wo, bounding the readout once the gates open.
def gate_temperature: f32 = 1.0f32
def gla_out_norm: bool = false

def gate_log (z: f32): f32 = log_sigmoid z / gate_temperature

-- Canonical scalar used by fused blocks and the decomposed SwiGLU piece.
def silu (z: f32): f32 = z / (1.0f32 + f32.exp (-z))

-- Gated linear attention in the PARALLEL closed form licensed by the proved
-- recurrent≡parallel theorem (FormalTransformer/Attention/Linear.agda): per
-- head and channel c, the coefficient of token s at position i is
-- ∏_{r=s+1..i} alpha_r[c] = exp(cum[i][c] - cum[s][c]) with cum the prefix
-- sum of log-gates; i >= s makes every exponent <= 0, so no overflow.  The
-- prefix sums arrive precomputed (`cum`), and queries/keys arrive already
-- L2-normalized per head: computing either inside the head tabulate makes
-- the OpenCL/CUDA codegen (of the vjp or of the batch-mapped forward)
-- produce irregular or nested allocations, so gla_block computes both once
-- and this definition only slices.  The Haskell reference computes the
-- recurrent form; the conformance oracle checks their agreement.
def gla_attention [n] [d]
    (h: i64)
    (q: [n][d]f32) (k: [n][d]f32) (v: [n][d]f32)
    (cum: [n][d]f32): [n][d]f32 =
  let hd = d / h
  let per_head =
    tabulate h (\head ->
      let head_base = head * hd
      let qh = map (\row -> take hd (drop head_base row)) q
      let kh = map (\row -> take hd (drop head_base row)) k
      let vh = map (\row -> take hd (drop head_base row)) v
      let ch = map (\row -> take hd (drop head_base row)) cum
      let scores = tabulate_2d n n (\i s ->
        if s > i then 0.0f32
        else f32.sum (map3 (\qc kc decay -> qc * kc * f32.exp decay)
                           qh[i] kh[s] (map2 (-) ch[i] ch[s])))
      in map (\i ->
           tabulate hd (\j ->
             f32.sum (map (\s -> scores[i, s] * vh[s, j]) (iota n))))
           (iota n))
  in tabulate n (\i ->
       flatten (map (\head -> per_head[head, i]) (iota h)) :> [d]f32)

-- Inclusive prefix sums of the log-gates over positions, as a regular
-- masked reduction rather than a scan (see the note on gla_attention).
def gate_prefix_sums [n] [d] (gate_logits: [n][d]f32): [n][d]f32 =
  let logs = map (map gate_log) gate_logits
  in tabulate_2d n d (\i c ->
       f32.sum (map (\r -> if r <= i then logs[r, c] else 0.0f32) (iota n)))

-- The production chunk length: a pure execution-schedule choice, invisible
-- in the denotation by chunk-closed.  Whole window when 64 does not divide.
def default_chunk (n: i64): i64 = if n % 64 == 0 then 64 else n

-- Chunkwise GLA, the executed reading of chunk-closed
-- (FormalTransformer/Attention/Linear.agda) applied at two levels: within a
-- chunk the token-level parallel closed form, and across chunks the SAME
-- theorem one level up — training windows start from S0 = 0, so the carried
-- state before chunk kk is the decayed sum of earlier chunk contributions,
-- a masked reduction over the (few) chunks rather than a differentiated
-- sequential loop.  Every decay factor is exp of a difference of
-- non-increasing prefix sums with the later index first, so every exponent
-- is <= 0 and nothing overflows; K/Gamma division is never formed.  This is
-- the GEMM-shaped form: T, S_before, and the inter term are matrix products
-- per (chunk, head); a BLAS backend implements exactly these contractions.
-- Only regular tabulates and masked reductions appear (the codegen lessons
-- of this file: no scan, no in-place, no branch under the differentiated
-- loop, no per-row allocation inside nested parallel constructs).
def gla_attention_chunked [n] [d]
    (chunk: i64) (h: i64)
    (q: [n][d]f32) (k: [n][d]f32) (v: [n][d]f32)
    (logs: [n][d]f32): [n][d]f32 =
  let nc = assert (chunk > 0 && n % chunk == 0) (n / chunk)
  let hd = d / h
  let qc = unflatten (q :> [(nc*chunk)][d]f32)
  let kc = unflatten (k :> [(nc*chunk)][d]f32)
  let vc = unflatten (v :> [(nc*chunk)][d]f32)
  let lc = unflatten (logs :> [(nc*chunk)][d]f32)
  let per_head =
    tabulate h (\head ->
      let head_base = head * hd
      let slice3 (a: [nc][chunk][d]f32): [nc][chunk][hd]f32 =
        map (map (\row -> take hd (drop head_base row))) a
      let qh = slice3 qc
      let kh = slice3 kc
      let vh = slice3 vc
      let lh = slice3 lc
      -- chunk-local inclusive prefix sums of the log-gates
      let relcum = map (\lk ->
        tabulate_2d chunk hd (\i c ->
          f32.sum (map (\r -> if r <= i then lk[r, c] else 0.0f32)
                       (iota chunk)))) lh
      -- total log-decay of each chunk, and its prefix sums over chunks
      let dec = tabulate_2d nc hd (\kk c -> relcum[kk, chunk-1, c])
      let cumdec = tabulate_2d nc hd (\kk c ->
        f32.sum (map (\k' -> if k' <= kk then dec[k', c] else 0.0f32)
                     (iota nc)))
      -- chunk contribution T[kk] = sum_s exp(dec - relcum_s) k_s v_s^T
      let t = tabulate_3d nc hd hd (\kk c j ->
        f32.sum (map (\s ->
          f32.exp (dec[kk, c] - relcum[kk, s, c]) * kh[kk, s, c] * vh[kk, s, j])
          (iota chunk)))
      -- state before chunk kk: chunk-closed one level up, S0 = 0
      let s_before = tabulate_3d nc hd hd (\kk c j ->
        f32.sum (map (\k' ->
          if k' < kk
          then f32.exp (cumdec[kk-1, c] - cumdec[k', c]) * t[k', c, j]
          else 0.0f32) (iota nc)))
      -- chunk-local masked scores, exactly the whole-window formula at C
      let scores = map (\kk ->
        tabulate_2d chunk chunk (\i s ->
          if s > i then 0.0f32
          else f32.sum (map (\c ->
                 qh[kk, i, c] * kh[kk, s, c]
                 * f32.exp (relcum[kk, i, c] - relcum[kk, s, c]))
                 (iota hd)))) (iota nc)
      in tabulate_3d nc chunk hd (\kk i j ->
           let inter = f32.sum (map (\c ->
                 qh[kk, i, c] * f32.exp (relcum[kk, i, c]) * s_before[kk, c, j])
                 (iota hd))
           let intra = f32.sum (map (\s ->
                 scores[kk][i, s] * vh[kk, s, j]) (iota chunk))
           in inter + intra))
  in tabulate n (\i ->
       flatten (map (\head -> per_head[head, i / chunk, i % chunk]) (iota h))
       :> [d]f32)

-- Shared attention-input projections: rms_att then Wq/Wk/Wv, no positional
-- encoding on either block kind.
def attention_inputs [n] [d] [p]
    (base: i64) (params: [p]f32) (x: [n][d]f32)
    : ([n][d]f32, [n][d]f32, [n][d]f32, [n][d]f32) =
  let rms_att = vector base d params
  let wq = matrix (base + d) d d params
  let wk = matrix (base + d + d*d) d d params
  let wv = matrix (base + d + 2*d*d) d d params
  let normed = map (\row -> rms_norm row rms_att) x
  in (normed,
      map (matvec wq) normed,
      map (matvec wk) normed,
      map (matvec wv) normed)

-- Output projection, residual, and SwiGLU shared by both block kinds.
-- `tail_base` is the offset of Wo; rms_ff follows at `tail_base + d*d +
-- alpha_len` where alpha_len is d*d for GLA blocks and 0 for softmax blocks.
def block_tail [n] [d] [p]
    (f: i64) (ooff: i64) (rms_ff_off: i64)
    (params: [p]f32) (x: [n][d]f32) (attended: [n][d]f32): [n][d]f32 =
  let wo = matrix ooff d d params
  let x_att = map2 add x (map (matvec wo) attended)
  let rms_ff = vector rms_ff_off d params
  let wgate = matrix (rms_ff_off + d) f d params
  let wup = matrix (rms_ff_off + d + f*d) f d params
  let wdown = matrix (rms_ff_off + d + 2*f*d) d f params
  let ff_normed = map (\row -> rms_norm row rms_ff) x_att
  let ff = map (\row ->
    let gate = matvec wgate row
    let up = matvec wup row
    let hidden = map2 (\g u -> silu g * u) gate up
    in matvec wdown hidden) ff_normed
  in map2 add x_att ff

def softmax_block [n] [d] [p]
    (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (_, q, k, values) = attention_inputs base params x
  let attended = causal_attention h q k values
  let ooff = base + d + 3*d*d
  in block_tail f ooff (ooff + d*d) params x attended

def gla_block [n] [d] [p]
    (chunk: i64) (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (normed, q, k, values) = attention_inputs base params x
  let q_unit = map (l2_normalize_heads h) q
  let k_unit = map (l2_normalize_heads h) k
  let ooff = base + d + 3*d*d
  let walpha = matrix (ooff + d*d) d d params
  let gate_logits = map (matvec walpha) normed
  let logs = map (map gate_log) gate_logits
  let attended0 = gla_attention_chunked chunk h q_unit k_unit values logs
  let attended = if gla_out_norm
                 then map (l2_normalize_heads h) attended0
                 else attended0
  in block_tail f ooff (ooff + 2*d*d) params x attended

-- The whole-window quadratic form, retained (forward only, no vjp entry)
-- so the conformance oracle can compare the two executions of the one
-- denotation at same-precision tolerances.
def gla_block_quadratic [n] [d] [p]
    (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (normed, q, k, values) = attention_inputs base params x
  let q_unit = map (l2_normalize_heads h) q
  let k_unit = map (l2_normalize_heads h) k
  let ooff = base + d + 3*d*d
  let walpha = matrix (ooff + d*d) d d params
  let gate_logits = map (matvec walpha) normed
  let cum = gate_prefix_sums gate_logits
  let attended0 = gla_attention h q_unit k_unit values cum
  let attended = if gla_out_norm
                 then map (l2_normalize_heads h) attended0
                 else attended0
  in block_tail f ooff (ooff + 2*d*d) params x attended

def sigmoid (z: f32): f32 = 1.0f32 / (1.0f32 + f32.exp (-z))

-- Output projection, residual, and SwiGLU for a single position.
def block_tail_single [d] [p]
    (f: i64) (ooff: i64) (rms_ff_off: i64)
    (params: [p]f32) (x: [d]f32) (attended: [d]f32): [d]f32 =
  let wo = matrix ooff d d params
  let x_att = add x (matvec wo attended)
  let rms_ff = vector rms_ff_off d params
  let wgate = matrix (rms_ff_off + d) f d params
  let wup = matrix (rms_ff_off + d + f*d) f d params
  let wdown = matrix (rms_ff_off + d + 2*f*d) d f params
  let nrm = rms_norm x_att rms_ff
  let gate = matvec wgate nrm
  let up = matvec wup nrm
  let hidden = map2 (\g u -> silu g * u) gate up
  in add x_att (matvec wdown hidden)

-- One incremental decoding step of the hybrid model: the proved cache-run
-- law executed.  Each GLA layer carries a fixed [d][hd] state advanced by
-- stepGLA (the recurrent form; the state type never mentions the prefix
-- length), and each NoPE softmax layer keeps a ring-buffer KV cache of the
-- last `ctx` positions — without positional encodings the scores do not
-- depend on cache order, so the ring needs no reindexing.  Within the
-- first `ctx` tokens the incremental logits extensionally equal the batch
-- forward's final row (recurrent≡parallel plus causality); beyond that the
-- GLA state is simply never reset — the StateAlgebra run — while softmax
-- attends to the trailing window.
def decode_step_def [p] [gs] [ks]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (ctx: i64)
    (params: [p]f32)
    (position: i64) (token: i64)
    (gla_state: *[gs]f32) (k_cache: *[ks]f32) (v_cache: *[ks]f32)
    : ([v]f32, *[gs]f32, *[ks]f32, *[ks]f32) =
  let hd = d / h
  let checked = assert (gs == gla_layers n_layers * d * hd &&
                        ks == softmax_layers n_layers * ctx * d &&
                        p == parameter_count v d f n_layers &&
                        position >= 0 && token >= 0 && token < v && ctx > 0)
                       params
  let embedding = matrix 0 v d checked
  let inv_scale = 1.0f32 / f32.sqrt (f32.i64 hd)
  let (x_final, gla_out, k_out, v_out) =
    loop (x, gstate, kc, vc) =
        (copy (embedding[token] :> [d]f32), gla_state, k_cache, v_cache)
    for layer < n_layers do
      let base = block_base v d f layer
      let rms_att = vector base d checked
      let wq = matrix (base + d) d d checked
      let wk = matrix (base + d + d*d) d d checked
      let wv = matrix (base + d + 2*d*d) d d checked
      let ooff = base + d + 3*d*d
      let normed = rms_norm x rms_att
      let q = matvec wq normed
      let k = matvec wk normed
      let vvec = matvec wv normed
      in if layer % 4 == 3
         then -- NoPE softmax attention over the ring-buffer cache.
           let si = layer / 4
           let slot = position % ctx
           let koff = si*ctx*d + slot*d
           let kc = scatter kc (map (+ koff) (iota d)) k
           let vc = scatter vc (map (+ koff) (iota d)) vvec
           let m = i64.min (position + 1) ctx
           let per_head = tabulate h (\head ->
             let scores = tabulate ctx (\e ->
               if e < m
               then inv_scale * f32.sum (map (\c ->
                      q[head*hd+c] * kc[si*ctx*d + e*d + head*hd + c])
                      (iota hd))
               else -1.0e30f32)
             let weights = softmax scores
             in tabulate hd (\j ->
                  f32.sum (map (\e -> weights[e] * vc[si*ctx*d + e*d + head*hd + j])
                               (iota ctx))))
           let attended = tabulate d (\og -> per_head[og / hd, og % hd])
           let x' = block_tail_single f ooff (ooff + d*d) checked x attended
           in (x', gstate, kc, vc)
         else -- GLA: S' = diag(alpha)·S + k̂ vᵀ, o = q̂ᵀ S'.
           let gi = layer - layer / 4
           let qhat = l2_normalize_heads h q
           let khat = l2_normalize_heads h k
           let walpha = matrix (ooff + d*d) d d checked
           -- alpha = sigmoid(z)^(1/tau); the tau == 1 branch keeps the
           -- historical sigmoid bit pattern (exp∘log_sigmoid does not).
           let alpha = if gate_temperature == 1.0f32
                       then map sigmoid (matvec walpha normed)
                       else map (\z -> f32.exp (gate_log z)) (matvec walpha normed)
           let goff = gi*d*hd
           let s_new = tabulate (d*hd) (\idx ->
             let cg = idx / hd
             let j = idx % hd
             in alpha[cg] * gstate[goff + idx] + khat[cg] * vvec[(cg / hd)*hd + j])
           let gstate = scatter gstate (map (+ goff) (iota (d*hd))) s_new
           let attended0 = tabulate d (\og ->
             let head = og / hd
             let j = og % hd
             in f32.sum (map (\c -> qhat[head*hd+c] * s_new[(head*hd+c)*hd + j])
                             (iota hd)))
           let attended = if gla_out_norm
                          then l2_normalize_heads h attended0
                          else attended0
           let x' = block_tail_single f ooff (ooff + 2*d*d) checked x attended
           in (x', gstate, kc, vc)
  let final_gain = vector (block_base v d f n_layers) d checked
  let final_hidden = rms_norm x_final final_gain
  in (map (\word -> dot word final_hidden) embedding, gla_out, k_out, v_out)

def valid_tokens [n] (v: i64) (tokens: [n]i64): bool =
  all (\t -> t >= 0 && t < v) tokens

def model_logits [n] [p]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (params: [p]f32) (tokens: [n]i64): [n][v]f32 =
  let base_checked = assert (v > 0 && d > 0 && f > 0 && h > 0 &&
                             n_layers > 0 && n > 0) params
  let hd = d / h
  let expected = parameter_count v d f n_layers
  let checked = assert (d % h == 0 &&
                        hd % 2 == 0 && p == expected &&
                        chunk > 0 && n % chunk == 0 &&
                        valid_tokens v tokens) base_checked
  let embedding = matrix 0 v d checked
  let initial: [n][d]f32 = map (\token -> embedding[token]) tokens
  -- The hybrid rule is periodic, so the layer loop runs in branch-free
  -- groups of four (three GLA then one softmax) plus a GLA-only remainder:
  -- a data-independent `if` inside the differentiated loop gives the two
  -- arms different tape shapes and the GPU codegen of the vjp rejects the
  -- resulting irregular allocation.
  let groups = n_layers / 4
  let rest = n_layers % 4
  let grouped = loop state = initial for g < groups do
    let s1 = gla_block chunk f h (block_base v d f (4*g)) checked state
    let s2 = gla_block chunk f h (block_base v d f (4*g + 1)) checked s1
    let s3 = gla_block chunk f h (block_base v d f (4*g + 2)) checked s2
    in softmax_block f h (block_base v d f (4*g + 3)) checked s3
  let hidden = loop state = grouped for r < rest do
    gla_block chunk f h (block_base v d f (4*groups + r)) checked state
  let final_gain = vector (block_base v d f n_layers) d checked
  let final_hidden = map (\row -> rms_norm row final_gain) hidden
  -- Tied unembedding: the embedding rows are the vocabulary projections.
  in map (\row -> map (\word -> dot word row) embedding) final_hidden

-- Forward-only twin of model_logits through the quadratic GLA form; never
-- differentiated, exists for the chunked≡quadratic conformance entry.
def model_logits_quadratic [n] [p]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: [p]f32) (tokens: [n]i64): [n][v]f32 =
  let checked = assert (v > 0 && d > 0 && f > 0 && h > 0 &&
                        n_layers > 0 && n > 0 && d % h == 0 &&
                        (d / h) % 2 == 0 &&
                        p == parameter_count v d f n_layers &&
                        valid_tokens v tokens) params
  let embedding = matrix 0 v d checked
  let initial: [n][d]f32 = map (\token -> embedding[token]) tokens
  let groups = n_layers / 4
  let rest = n_layers % 4
  let grouped = loop state = initial for g < groups do
    let s1 = gla_block_quadratic f h (block_base v d f (4*g)) checked state
    let s2 = gla_block_quadratic f h (block_base v d f (4*g + 1)) checked s1
    let s3 = gla_block_quadratic f h (block_base v d f (4*g + 2)) checked s2
    in softmax_block f h (block_base v d f (4*g + 3)) checked s3
  let hidden = loop state = grouped for r < rest do
    gla_block_quadratic f h (block_base v d f (4*groups + r)) checked state
  let final_gain = vector (block_base v d f n_layers) d checked
  let final_hidden = map (\row -> rms_norm row final_gain) hidden
  in map (\row -> map (\word -> dot word row) embedding) final_hidden

def next_token_loss [n] [p]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (tokens: [n]i64) (params: [p]f32): f32 =
  let checked_tokens = assert (n >= 2) tokens
  let scores = model_logits v d f h n_layers chunk params checked_tokens
  let losses = map (\i ->
    let row = scores[i]
    let target = checked_tokens[i+1]
    let maximum = f32.maximum row
    let log_partition = maximum + f32.log (f32.sum (map (\z -> f32.exp (z-maximum)) row))
    in log_partition - row[target]) (iota (n-1))
  in f32.sum losses / f32.i64 (n-1)


def batch_mean_loss_def [batch] [sequence] [p]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (params: [p]f32) (tokens: [batch][sequence]i64): f32 =
  let checked_tokens = assert (batch > 0 && sequence >= 2) tokens
  let losses = map
    (\sample -> next_token_loss v d f h n_layers chunk sample params)
    checked_tokens
  in f32.sum losses / f32.i64 batch

-- Optimizer primitives are definitions rather than entries so every Futhark
-- entry-point program can expose the same implementation without importing
-- another generated runtime.
def zero_vector_def (count: i64): [count]f32 =
  replicate (assert (count >= 0) count) 0.0f32

def clip_global_norm_def [p] (max_norm: f32) (gradient: [p]f32)
    : (f32, [p]f32) =
  let checked = assert (max_norm > 0.0f32) gradient
  let norm = f32.sqrt (f32.sum (map (\g -> g*g) checked))
  let scale = if norm > max_norm then max_norm/(norm + 1.0e-12f32) else 1.0f32
  in (norm, map (*scale) checked)

def adamw_step_def [p]
    (step: i64) (learning_rate: f32) (beta1: f32) (beta2: f32)
    (epsilon: f32) (weight_decay: f32)
    (params: [p]f32) (gradient: [p]f32)
    (first_moment: [p]f32) (second_moment: [p]f32)
    (decay_mask: [p]bool): ([p]f32, [p]f32, [p]f32) =
  let checked = assert (step > 0 && learning_rate >= 0.0f32 &&
                        beta1 >= 0.0f32 && beta1 < 1.0f32 &&
                        beta2 >= 0.0f32 && beta2 < 1.0f32 &&
                        epsilon > 0.0f32 && weight_decay >= 0.0f32) params
  let m = map2 (\old g -> beta1*old + (1.0f32-beta1)*g)
               first_moment gradient
  let second = map2 (\old g -> beta2*old + (1.0f32-beta2)*g*g)
                    second_moment gradient
  let m_correction = 1.0f32 - beta1 ** f32.i64 step
  let v_correction = 1.0f32 - beta2 ** f32.i64 step
  let updated = map (\(param, mi, vi, grad_decay, use_decay) ->
    let adaptive = (mi/m_correction) /
                   (f32.sqrt (vi/v_correction) + epsilon)
    let decay = if use_decay then weight_decay*grad_decay else 0.0f32
    in param - learning_rate*(adaptive + decay))
    (zip5 checked m second checked decay_mask)
  in (updated, m, second)
