-- Canonical bias-free HYBRID decoder kernels using one flat f32 parameter
-- vector.  Every fourth block (index % 4 == 3) is softmax full attention
-- with no positional encoding; the rest are gated linear attention (GLA)
-- blocks whose data-dependent gates carry position.  The semantics and its
-- proofs live in FormalTransformer/Attention/Linear.agda and
-- docs/ATTENTION-SEMANTICS.md.
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
-- the shared q/k slices shrink by a factor of hd (see HANDOFF.md 2026-07-16:
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
  let logs = map (map log_sigmoid) gate_logits
  in tabulate_2d n d (\i c ->
       f32.sum (map (\r -> if r <= i then logs[r, c] else 0.0f32) (iota n)))

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
    let hidden = map2 (\g u -> (g / (1.0f32 + f32.exp (-g))) * u)
                      gate up
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

def valid_tokens [n] (v: i64) (tokens: [n]i64): bool =
  all (\t -> t >= 0 && t < v) tokens

def model_logits [n] [p]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: [p]f32) (tokens: [n]i64): [n][v]f32 =
  let base_checked = assert (v > 0 && d > 0 && f > 0 && h > 0 &&
                             n_layers > 0 && n > 0) params
  let hd = d / h
  let expected = parameter_count v d f n_layers
  let checked = assert (d % h == 0 &&
                        hd % 2 == 0 && p == expected &&
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
    let s1 = gla_block f h (block_base v d f (4*g)) checked state
    let s2 = gla_block f h (block_base v d f (4*g + 1)) checked s1
    let s3 = gla_block f h (block_base v d f (4*g + 2)) checked s2
    in softmax_block f h (block_base v d f (4*g + 3)) checked s3
  let hidden = loop state = grouped for r < rest do
    gla_block f h (block_base v d f (4*groups + r)) checked state
  let final_gain = vector (block_base v d f n_layers) d checked
  let final_hidden = map (\row -> rms_norm row final_gain) hidden
  -- Tied unembedding: the embedding rows are the vocabulary projections.
  in map (\row -> map (\word -> dot word row) embedding) final_hidden

def next_token_loss [n] [p]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (tokens: [n]i64) (params: [p]f32): f32 =
  let checked_tokens = assert (n >= 2) tokens
  let scores = model_logits v d f h n_layers params checked_tokens
  let losses = map (\i ->
    let row = scores[i]
    let target = checked_tokens[i+1]
    let maximum = f32.maximum row
    let log_partition = maximum + f32.log (f32.sum (map (\z -> f32.exp (z-maximum)) row))
    in log_partition - row[target]) (iota (n-1))
  in f32.sum losses / f32.i64 (n-1)


def batch_mean_loss_def [batch] [sequence] [p]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: [p]f32) (tokens: [batch][sequence]i64): f32 =
  let checked_tokens = assert (batch > 0 && sequence >= 2) tokens
  let losses = map
    (\sample -> next_token_loss v d f h n_layers sample params)
    checked_tokens
  in f32.sum losses / f32.i64 batch
