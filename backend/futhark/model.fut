-- Canonical bias-free HYBRID decoder kernels using one flat f32 parameter
-- vector.  Every fourth block (index % 4 == 3) is softmax full attention
-- with no positional encoding; the rest are gated linear attention (GLA)
-- blocks whose data-dependent gates carry position.  The semantics and its
-- proofs live in FormalTransformer/Attention/Linear.agda and
-- docs/RUN-2026-07-25-WIKI-FULL.md.
--
-- Layout (Layout.namedLayout is the Haskell mirror; keep them identical):
--   embedding [v][d]; then, for each block:
--   rms_att [d], Wq/Wk/Wv/Wo [d][d],
--   (GLA blocks only: Walpha [d][d], then gate_lambda [d] under RG-LRU),
--   (softmax blocks only, when enabled: qk_gain_q/qk_gain_k [d/h],
--    sink [h]),
--   rms_ff [d], Wgate/Wup [f][d], Wdown [d][f]; finally rms_final [d].
--
-- The v3 architecture (Config.gateKind/qkNorm/headSinks) arrives packed in
-- one `arch` integer — see arch_rglru below — because it moves parameter
-- offsets and gate semantics, and an architecture flag outside the entry
-- interface would let one layout be silently read as another.
--
-- All public model entries state the exact parameter length in their
-- interface type: params must have size parameter_count arch v d f h n_layers, so
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

-- Packed v3 architecture flags, mirroring Config.archCode: bit 0 = RG-LRU
-- gates, bit 1 = qk-norm on softmax layers, bit 2 = per-head sink logits.
def arch_rglru (arch: i64): bool = arch % 2 == 1
def arch_qknorm (arch: i64): bool = (arch / 2) % 2 == 1
def arch_sinks (arch: i64): bool = (arch / 4) % 2 == 1

-- Extra parameters each block kind carries under the v3 arms.
def gla_extra (arch: i64) (d: i64): i64 =
  if arch_rglru arch then d else 0
def softmax_extra (arch: i64) (d: i64) (h: i64): i64 =
  (if arch_qknorm arch then 2*(d/h) else 0) + (if arch_sinks arch then h else 0)

def block_size (d: i64) (f: i64): i64 =
  4*d*d + 3*f*d + 2*d

-- Offset of block `layer`: every earlier block contributes the shared block
-- size, earlier GLA blocks add their gate projection (and decay base), and
-- earlier softmax blocks their enabled extras.
def block_base (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64)
               (layer: i64): i64 =
  v*d + layer*block_size d f
      + (layer - layer / 4)*(d*d + gla_extra arch d)
      + (layer / 4)*softmax_extra arch d h

def parameter_count (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64)
                    (n_layers: i64): i64 =
  block_base arch v d f h n_layers + d

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

-- Per-head L2 normalization.  The norm depends only on the head, never on the
-- output component, so it is computed once per head here and shared by that
-- head's hd components -- the same treatment causal_attention above already
-- gets, and for the same reason.
--
-- Every output element is still the same expression as the per-component
-- formulation this replaced (pure let-floating; no f32 reassociation, so the
-- forward is bit-identical), but the forward work and -- critically -- the
-- reverse-AD adjoint accumulations into the shared x slice shrink by a factor
-- of hd.  Written per element, vjp made each of a head's hd outputs accumulate
-- into all hd of its inputs, which is what compiles to lock-guarded updates on
-- GPUs; piece_l2norm_heads_bwd was 16.5% of kernel time at bpe100m.
def l2_normalize_heads [d] (h: i64) (x: [d]f32): [d]f32 =
  let hd = d / h
  let norms = tabulate h (\head ->
    let head_base = head * hd
    in f32.sqrt (1.0e-6f32 +
         f32.sum (map (\c -> x[head_base+c] * x[head_base+c]) (iota hd))))
  in tabulate d (\j -> x[j] / norms[j / hd])

-- Numerically stable log(sigmoid(z)) = -softplus(-z); the gate itself is
-- never materialized, so a saturated sigmoid cannot produce log 0.
def log_sigmoid (z: f32): f32 =
  -(f32.max (-z) 0.0f32 + f32.log1p (f32.exp (-(f32.abs z))))

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

-- Inclusive prefix sums over positions, as a regular masked reduction
-- rather than a scan (see the note on gla_attention).
def prefix_sums_2d [n] [d] (logs: [n][d]f32): [n][d]f32 =
  tabulate_2d n d (\i c ->
    f32.sum (map (\r -> if r <= i then logs[r, c] else 0.0f32) (iota n)))

def gate_prefix_sums [n] [d] (gate_logits: [n][d]f32): [n][d]f32 =
  prefix_sums_2d (map (map log_sigmoid) gate_logits)

-- The RG-LRU log-gate (Griffin, arXiv 2402.19427; Config.GateRgLru): per
-- channel, log alpha = c · sigmoid(z) · log sigmoid(Λ) with c = 8, and the
-- state write scaled by sqrt(1 − alpha²) = sqrt(1 − exp(2·log alpha)) so an
-- open gate does not let fresh input swamp held state.  The scale is folded
-- into the (already per-head-normalized) key: the token the recurrence
-- consumes is (q̂, β·k̂, v, alpha), so the gate stays the transition and the
-- scaled write is part of the contribution — Attention/Linear.agda's
-- algebra, and every kernel below it, applies unchanged.
def rglru_log_gate (z: f32) (lam: f32): f32 =
  8.0f32 * (1.0f32 / (1.0f32 + f32.exp (-z))) * log_sigmoid lam

def rglru_write_scale (log_alpha: f32): f32 =
  f32.sqrt (1.0f32 - f32.exp (2.0f32 * log_alpha))

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

-- Per-head RMSNorm with shared zero-centered gains (v3 qkNorm): the same
-- normalization formula as rms_norm, per hd-slice, with gain = 1 + w.
def qk_normalize [d] (h: i64) (w: []f32) (x: [d]f32): [d]f32 =
  let hd = d / h
  let scales = tabulate h (\head ->
    let base = head * hd
    let ms = f32.sum (map (\c -> x[base+c] * x[base+c]) (iota hd)) / f32.i64 hd
    in 1.0f32 / f32.sqrt (ms + 1.0e-5f32))
  in tabulate d (\j -> x[j] * scales[j / hd] * (1.0f32 + w[j % hd]))

-- Softmax attention with a learned per-head sink logit: the softmax runs
-- over scores ++ [sink] and the sink's weight is dropped — exactly the
-- restriction-of-extended-softmax semantics proved in
-- FormalTransformer/Attention/Sink.agda, so token weights form a
-- subdistribution and a head can attend to nothing.
def causal_attention_sink [n] [d]
    (h: i64) (sinks: [h]f32)
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
           let scores = tabulate (n+1) (\j ->
             if j == n then sinks[head]
             else if j <= i
             then dot qh[i] kh[j] * inv_scale
             else -1.0e30f32)
           let weights = softmax scores
           in tabulate hd (\within_head ->
                f32.sum (map2 (*) (take n weights)
                  (map (\j -> vh[j, within_head]) (iota n)))))
           (iota n))
  in tabulate n (\i ->
       flatten (map (\head -> per_head[head, i]) (iota h)) :> [d]f32)

-- The v3 softmax-block variants.  Separate definitions per enabled arm —
-- never a branch inside one — so the differentiated layer loops keep a
-- single tape shape (the codegen rule at model_logits).  Extras sit
-- between Wo and rms_ff in Layout.namedLayout order: qk_gain_q [hd],
-- qk_gain_k [hd], then sink [h].
def softmax_block_qk [n] [d] [p]
    (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (_, q0, k0, values) = attention_inputs base params x
  let ooff = base + d + 3*d*d
  let hd = d / h
  let wq_g = vector (ooff + d*d) hd params
  let wk_g = vector (ooff + d*d + hd) hd params
  let q = map (qk_normalize h wq_g) q0
  let k = map (qk_normalize h wk_g) k0
  let attended = causal_attention h q k values
  in block_tail f ooff (ooff + d*d + 2*hd) params x attended

def softmax_block_sink [n] [d] [p]
    (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (_, q, k, values) = attention_inputs base params x
  let ooff = base + d + 3*d*d
  let sinks = vector (ooff + d*d) h params
  let attended = causal_attention_sink h sinks q k values
  in block_tail f ooff (ooff + d*d + h) params x attended

def softmax_block_qk_sink [n] [d] [p]
    (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (_, q0, k0, values) = attention_inputs base params x
  let ooff = base + d + 3*d*d
  let hd = d / h
  let wq_g = vector (ooff + d*d) hd params
  let wk_g = vector (ooff + d*d + hd) hd params
  let sinks = vector (ooff + d*d + 2*hd) h params
  let q = map (qk_normalize h wq_g) q0
  let k = map (qk_normalize h wk_g) k0
  let attended = causal_attention_sink h sinks q k values
  in block_tail f ooff (ooff + d*d + 2*hd + h) params x attended

-- One grouped layer stack over a pair of block functions.  The functions
-- are ordinary (defunctionalized) parameters applied inside the loops —
-- every instantiation below passes complete definitions, so each
-- instantiated stack has one tape shape.  Selection among instantiations
-- happens in model_logits, outside every differentiated loop, and each
-- branch there returns an array (functions are never branch results,
-- which Futhark forbids).
def run_stack [n] [d] [p]
    (arch: i64) (v: i64) (f: i64) (h: i64) (n_layers: i64)
    (gla_blk: i64 -> [p]f32 -> [n][d]f32 -> [n][d]f32)
    (smax_blk: i64 -> [p]f32 -> [n][d]f32 -> [n][d]f32)
    (checked: [p]f32) (initial: [n][d]f32): [n][d]f32 =
  let groups = n_layers / 4
  let rest = n_layers % 4
  let grouped = loop state = initial for g < groups do
    let s1 = gla_blk (block_base arch v d f h (4*g)) checked state
    let s2 = gla_blk (block_base arch v d f h (4*g + 1)) checked s1
    let s3 = gla_blk (block_base arch v d f h (4*g + 2)) checked s2
    in smax_blk (block_base arch v d f h (4*g + 3)) checked s3
  in loop state = grouped for r < rest do
    gla_blk (block_base arch v d f h (4*groups + r)) checked state

def gla_block [n] [d] [p]
    (chunk: i64) (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (normed, q, k, values) = attention_inputs base params x
  let q_unit = map (l2_normalize_heads h) q
  let k_unit = map (l2_normalize_heads h) k
  let ooff = base + d + 3*d*d
  let walpha = matrix (ooff + d*d) d d params
  let gate_logits = map (matvec walpha) normed
  let logs = map (map log_sigmoid) gate_logits
  let attended = gla_attention_chunked chunk h q_unit k_unit values logs
  in block_tail f ooff (ooff + 2*d*d) params x attended

-- The RG-LRU GLA block (Config.GateRgLru): gate_lambda follows walpha, the
-- log-gate is rglru_log_gate, and the write scale multiplies the normalized
-- key channel-wise.  A separate definition rather than a branch inside
-- gla_block, so the differentiated layer loops stay branch-free (the
-- codegen rule at model_logits).
def gla_block_rglru [n] [d] [p]
    (chunk: i64) (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (normed, q, k, values) = attention_inputs base params x
  let q_unit = map (l2_normalize_heads h) q
  let k_unit0 = map (l2_normalize_heads h) k
  let ooff = base + d + 3*d*d
  let walpha = matrix (ooff + d*d) d d params
  let lambda = vector (ooff + 2*d*d) d params
  let gate_logits = map (matvec walpha) normed
  let logs = map (\row -> map2 (\z lam -> rglru_log_gate z lam) row lambda)
                 gate_logits
  let k_unit = map2 (\lrow krow ->
                 map2 (\l kc -> kc * rglru_write_scale l) lrow krow)
               logs k_unit0
  let attended = gla_attention_chunked chunk h q_unit k_unit values logs
  in block_tail f ooff (ooff + 2*d*d + d) params x attended

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
  let attended = gla_attention h q_unit k_unit values cum
  in block_tail f ooff (ooff + 2*d*d) params x attended

def gla_block_quadratic_rglru [n] [d] [p]
    (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let (normed, q, k, values) = attention_inputs base params x
  let q_unit = map (l2_normalize_heads h) q
  let k_unit0 = map (l2_normalize_heads h) k
  let ooff = base + d + 3*d*d
  let walpha = matrix (ooff + d*d) d d params
  let lambda = vector (ooff + 2*d*d) d params
  let gate_logits = map (matvec walpha) normed
  let logs = map (\row -> map2 (\z lam -> rglru_log_gate z lam) row lambda)
                 gate_logits
  let k_unit = map2 (\lrow krow ->
                 map2 (\l kc -> kc * rglru_write_scale l) lrow krow)
               logs k_unit0
  let cum = prefix_sums_2d logs
  let attended = gla_attention h q_unit k_unit values cum
  in block_tail f ooff (ooff + 2*d*d + d) params x attended

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
    (arch: i64)
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (ctx: i64)
    (params: [p]f32)
    (position: i64) (token: i64)
    (gla_state: *[gs]f32) (k_cache: *[ks]f32) (v_cache: *[ks]f32)
    : ([v]f32, *[gs]f32, *[ks]f32, *[ks]f32) =
  let hd = d / h
  let checked = assert (gs == gla_layers n_layers * d * hd &&
                        ks == softmax_layers n_layers * ctx * d &&
                        p == parameter_count arch v d f h n_layers &&
                        position >= 0 && token >= 0 && token < v && ctx > 0)
                       params
  let embedding = matrix 0 v d checked
  let inv_scale = 1.0f32 / f32.sqrt (f32.i64 hd)
  let (x_final, gla_out, k_out, v_out) =
    loop (x, gstate, kc, vc) =
        (copy (embedding[token] :> [d]f32), gla_state, k_cache, v_cache)
    for layer < n_layers do
      let base = block_base arch v d f h layer
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
         then -- NoPE softmax attention over the ring-buffer cache.  Under
              -- qkNorm the key is normalized BEFORE caching (its normalized
              -- value never changes, matching the batch forward) and the
              -- query per step; under headSinks the score vector carries one
              -- extra slot whose weight is dropped from the value sum
              -- (Attention/Sink.agda).  With sinks off that slot's logit is
              -- -1e30, whose exp underflows to exactly 0, so the v2 weights
              -- are reproduced bit for bit through the single code path.
           let si = layer / 4
           let slot = position % ctx
           let koff = si*ctx*d + slot*d
           let (q_att, k_store) =
             if arch_qknorm arch
             then let wq_g = vector (ooff + d*d) hd checked
                  let wk_g = vector (ooff + d*d + hd) hd checked
                  in (qk_normalize h wq_g q, qk_normalize h wk_g k)
             else (q, k)
           let sink_off = ooff + d*d + (if arch_qknorm arch then 2*hd else 0)
           let kc = scatter kc (map (+ koff) (iota d)) k_store
           let vc = scatter vc (map (+ koff) (iota d)) vvec
           let m = i64.min (position + 1) ctx
           let per_head = tabulate h (\head ->
             let scores = tabulate (ctx+1) (\e ->
               if e == ctx
               then (if arch_sinks arch
                     then checked[sink_off + head]
                     else -1.0e30f32)
               else if e < m
               then inv_scale * f32.sum (map (\c ->
                      q_att[head*hd+c] * kc[si*ctx*d + e*d + head*hd + c])
                      (iota hd))
               else -1.0e30f32)
             let weights = softmax scores
             in tabulate hd (\j ->
                  f32.sum (map (\e -> weights[e] * vc[si*ctx*d + e*d + head*hd + j])
                               (iota ctx))))
           let attended = tabulate d (\og -> per_head[og / hd, og % hd])
           let x' = block_tail_single f ooff
                      (ooff + d*d + softmax_extra arch d h) checked x attended
           in (x', gstate, kc, vc)
         else -- GLA: S' = diag(alpha)·S + (β·k̂) vᵀ, o = q̂ᵀ S'.
           let gi = layer - layer / 4
           let qhat = l2_normalize_heads h q
           let khat0 = l2_normalize_heads h k
           let walpha = matrix (ooff + d*d) d d checked
           -- Sigmoid gates materialize sigmoid directly (the bit pattern
           -- exp . log_sigmoid does not reproduce); RG-LRU gates live in
           -- log space and scale the key write.  This loop is never
           -- differentiated, so the branch is harmless here.
           let (alpha, khat) =
             if arch_rglru arch
             then let lambda = vector (ooff + 2*d*d) d checked
                  let logalpha = map2 rglru_log_gate (matvec walpha normed) lambda
                  in (map f32.exp logalpha,
                      map2 (\l kc -> kc * rglru_write_scale l) logalpha khat0)
             else (map sigmoid (matvec walpha normed), khat0)
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
           let x' = block_tail_single f ooff
                      (ooff + 2*d*d + gla_extra arch d) checked x attended0
           in (x', gstate, kc, vc)
  let final_gain = vector (block_base arch v d f h n_layers) d checked
  let final_hidden = rms_norm x_final final_gain
  in (map (\word -> dot word final_hidden) embedding, gla_out, k_out, v_out)

def valid_tokens [n] (v: i64) (tokens: [n]i64): bool =
  all (\t -> t >= 0 && t < v) tokens

def model_logits [n] [p]
    (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (chunk: i64)
    (params: [p]f32) (tokens: [n]i64): [n][v]f32 =
  let base_checked = assert (v > 0 && d > 0 && f > 0 && h > 0 &&
                             n_layers > 0 && n > 0) params
  let hd = d / h
  let expected = parameter_count arch v d f h n_layers
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
  -- resulting irregular allocation.  The v3 arms obey the same rule: the
  -- arch word selects one fully-applied run_stack instantiation here,
  -- outside every loop, and each instantiation is branch-free inside.
  let stack gb sb = run_stack arch v f h n_layers gb sb checked initial
  let hidden =
    if arch_rglru arch
    then (if arch_qknorm arch
          then (if arch_sinks arch
                then stack (gla_block_rglru chunk f h) (softmax_block_qk_sink f h)
                else stack (gla_block_rglru chunk f h) (softmax_block_qk f h))
          else (if arch_sinks arch
                then stack (gla_block_rglru chunk f h) (softmax_block_sink f h)
                else stack (gla_block_rglru chunk f h) (softmax_block f h)))
    else (if arch_qknorm arch
          then (if arch_sinks arch
                then stack (gla_block chunk f h) (softmax_block_qk_sink f h)
                else stack (gla_block chunk f h) (softmax_block_qk f h))
          else (if arch_sinks arch
                then stack (gla_block chunk f h) (softmax_block_sink f h)
                else stack (gla_block chunk f h) (softmax_block f h)))
  let final_gain = vector (block_base arch v d f h n_layers) d checked
  let final_hidden = map (\row -> rms_norm row final_gain) hidden
  -- Tied unembedding: the embedding rows are the vocabulary projections.
  in map (\row -> map (\word -> dot word row) embedding) final_hidden

-- Forward-only twin of model_logits through the quadratic GLA form; never
-- differentiated, exists for the chunked≡quadratic conformance entry.
def model_logits_quadratic [n] [p]
    (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: [p]f32) (tokens: [n]i64): [n][v]f32 =
  let checked = assert (v > 0 && d > 0 && f > 0 && h > 0 &&
                        n_layers > 0 && n > 0 && d % h == 0 &&
                        (d / h) % 2 == 0 &&
                        p == parameter_count arch v d f h n_layers &&
                        valid_tokens v tokens) params
  let embedding = matrix 0 v d checked
  let initial: [n][d]f32 = map (\token -> embedding[token]) tokens
  let stack gb sb = run_stack arch v f h n_layers gb sb checked initial
  let hidden =
    if arch_rglru arch
    then (if arch_qknorm arch
          then (if arch_sinks arch
                then stack (gla_block_quadratic_rglru f h) (softmax_block_qk_sink f h)
                else stack (gla_block_quadratic_rglru f h) (softmax_block_qk f h))
          else (if arch_sinks arch
                then stack (gla_block_quadratic_rglru f h) (softmax_block_sink f h)
                else stack (gla_block_quadratic_rglru f h) (softmax_block f h)))
    else (if arch_qknorm arch
          then (if arch_sinks arch
                then stack (gla_block_quadratic f h) (softmax_block_qk_sink f h)
                else stack (gla_block_quadratic f h) (softmax_block_qk f h))
          else (if arch_sinks arch
                then stack (gla_block_quadratic f h) (softmax_block_sink f h)
                else stack (gla_block_quadratic f h) (softmax_block f h)))
  let final_gain = vector (block_base arch v d f h n_layers) d checked
  let final_hidden = map (\row -> rms_norm row final_gain) hidden
  in map (\row -> map (\word -> dot word row) embedding) final_hidden

def next_token_loss [n] [p]
    (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (chunk: i64)
    (tokens: [n]i64) (params: [p]f32): f32 =
  let checked_tokens = assert (n >= 2) tokens
  let scores = model_logits arch v d f h n_layers chunk params checked_tokens
  let losses = map (\i ->
    let row = scores[i]
    let target = checked_tokens[i+1]
    let maximum = f32.maximum row
    let log_partition = maximum + f32.log (f32.sum (map (\z -> f32.exp (z-maximum)) row))
    in log_partition - row[target]) (iota (n-1))
  in f32.sum losses / f32.i64 (n-1)


def batch_mean_loss_def [batch] [sequence] [p]
    (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (chunk: i64)
    (params: [p]f32) (tokens: [batch][sequence]i64): f32 =
  let checked_tokens = assert (batch > 0 && sequence >= 2) tokens
  let losses = map
    (\sample -> next_token_loss arch v d f h n_layers chunk sample params)
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

def matmul [a] [b] [cc] (x: [a][b]f32) (y: [b][cc]f32): [a][cc]f32 =
  let yt = transpose y
  in map (\xr -> map (\yc -> f32.sum (map2 (*) xr yc)) yt) x

-- Five Newton-Schulz iterations of the Muon quintic X ← aX + (bA + cA²)X,
-- A = XXᵀ, coefficients (3.4445, −4.7750, 2.0315), on the
-- Frobenius-normalized input; iterate on the transpose when rows > cols
-- so the Gram matrix is the small side.  Never differentiated.
def ns5_core [r] [c] (m0: [r][c]f32): [r][c]f32 =
  let fro = f32.sqrt (f32.sum (map (\row -> f32.sum (map (\x -> x*x) row)) m0))
  let x0 = map (map (/ (fro + 1.0e-7f32))) m0
  in loop x = x0 for _i < 5i64 do
    let a = matmul x (transpose x)
    let b = map2 (map2 (\p q -> -4.7750f32 * p + 2.0315f32 * q))
                 a (matmul a a)
    let bx = matmul b x
    in map2 (map2 (\xe be -> 3.4445f32 * xe + be)) x bx

def ns5 [r] [c] (m: [r][c]f32): [r][c]f32 =
  if r <= c then ns5_core m
  else transpose (ns5_core (transpose m))

-- One combined Muon/AdamW update (FormalTransformer.Optimizer.muonStep is
-- the Double-precision reference).  muon_mask marks the parameters owned
-- by the k Muon slices (the 2-D hidden matrices, described by
-- slice_off/rows/cols); they take the Nesterov Newton-Schulz update with
-- Moonshot's RMS matching 0.2·sqrt(max(r,c)) and decoupled weight decay,
-- everything else takes exactly the adamw_step_def formula.  Momentum and
-- the Adam moments are masked to their owners so the state stays
-- canonical (zeros elsewhere).
def muon_step_def [p] [k]
    (step: i64) (learning_rate: f32) (beta1: f32) (beta2: f32)
    (epsilon: f32) (weight_decay: f32) (muon_beta: f32)
    (params: [p]f32) (gradient: [p]f32)
    (momentum: [p]f32) (first_moment: [p]f32) (second_moment: [p]f32)
    (decay_mask: [p]bool) (muon_mask: [p]bool)
    (slice_off: [k]i64) (slice_rows: [k]i64) (slice_cols: [k]i64)
    : ([p]f32, [p]f32, [p]f32, [p]f32) =
  let checked = assert (step > 0 && learning_rate >= 0.0f32 &&
                        beta1 >= 0.0f32 && beta1 < 1.0f32 &&
                        beta2 >= 0.0f32 && beta2 < 1.0f32 &&
                        epsilon > 0.0f32 && weight_decay >= 0.0f32 &&
                        muon_beta >= 0.0f32 && muon_beta < 1.0f32) params
  let momentum' = map3 (\mu g on -> if on then muon_beta*mu + g else 0.0f32)
                       momentum gradient muon_mask
  let m = map3 (\old g on -> if on then 0.0f32
                             else beta1*old + (1.0f32-beta1)*g)
               first_moment gradient muon_mask
  let second = map3 (\old g on -> if on then 0.0f32
                                  else beta2*old + (1.0f32-beta2)*g*g)
                    second_moment gradient muon_mask
  let m_correction = 1.0f32 - beta1 ** f32.i64 step
  let v_correction = 1.0f32 - beta2 ** f32.i64 step
  let adam_updated = map5 (\param mi vi use_decay on ->
    if on then param
    else
      let adaptive = (mi/m_correction) /
                     (f32.sqrt (vi/v_correction) + epsilon)
      let decay = if use_decay then weight_decay*param else 0.0f32
      in param - learning_rate*(adaptive + decay))
    checked m second decay_mask muon_mask
  let updated = loop acc = copy adam_updated for i < k do
    let off = slice_off[i]
    let r = slice_rows[i]
    let c = slice_cols[i]
    let count = r * c
    let ns_in = tabulate count (\j ->
      gradient[off+j] + muon_beta * momentum'[off+j])
    let o = flatten (ns5 (unflatten (ns_in :> [r*c]f32)))
    let scale = 0.2f32 * f32.sqrt (f32.max (f32.i64 r) (f32.i64 c))
    let upd = tabulate count (\j ->
      let pj = acc[off+j]
      let decay = if decay_mask[off+j] then weight_decay*pj else 0.0f32
      in pj - learning_rate*(scale * o[j] + decay))
    in scatter acc (map (+ off) (iota count)) upd
  in (updated, momentum', m, second)
