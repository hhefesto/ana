-- Canonical bias-free decoder kernels using one flat f32 parameter vector.
--
-- Layout:
--   embedding [v][d]; then, for each block:
--   rms_att [d], Wq/Wk/Wv/Wo [d][d], rms_ff [d],
--   Wgate/Wup [f][d], Wdown [d][f]; finally rms_final [d].
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

def parameter_count (v: i64) (d: i64) (f: i64) (n_layers: i64): i64 =
  v*d + n_layers*(4*d*d + 3*f*d + 2*d) + d

def block_size (d: i64) (f: i64): i64 =
  4*d*d + 3*f*d + 2*d

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

def rope [d] (h: i64) (pos: i64) (x: [d]f32): [d]f32 =
  let hd = d / h
  in tabulate d (\j ->
    let within_head = j % hd
    let head_base = j - within_head
    let pair = within_head - within_head % 2
    let exponent = f32.i64 pair / f32.i64 hd
    let angle = f32.i64 pos / (10000.0f32 ** exponent)
    let c = f32.cos angle
    let s = f32.sin angle
    in if within_head % 2 == 0
       then x[head_base+pair] * c - x[head_base+pair+1] * s
       else x[head_base+pair] * s + x[head_base+pair+1] * c)

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

def decoder_block [n] [d] [p]
    (f: i64) (h: i64) (base: i64)
    (params: [p]f32) (x: [n][d]f32): [n][d]f32 =
  let rms_att = vector base d params
  let qoff = base + d
  let koff = qoff + d*d
  let voff = koff + d*d
  let ooff = voff + d*d
  let rms_ff_off = ooff + d*d
  let gateoff = rms_ff_off + d
  let upoff = gateoff + f*d
  let downoff = upoff + f*d
  let wq = matrix qoff d d params
  let wk = matrix koff d d params
  let wv = matrix voff d d params
  let wo = matrix ooff d d params
  let normed = map (\row -> rms_norm row rms_att) x
  let q = map2 (\pos row -> rope h pos (matvec wq row)) (iota n) normed
  let k = map2 (\pos row -> rope h pos (matvec wk row)) (iota n) normed
  let values = map (matvec wv) normed
  let attended = causal_attention h q k values
  let x_att = map2 add x (map (matvec wo) attended)
  let rms_ff = vector rms_ff_off d params
  let wgate = matrix gateoff f d params
  let wup = matrix upoff f d params
  let wdown = matrix downoff d f params
  let ff_normed = map (\row -> rms_norm row rms_ff) x_att
  let ff = map (\row ->
    let gate = matvec wgate row
    let up = matvec wup row
    let hidden = map2 (\g u -> (g / (1.0f32 + f32.exp (-g))) * u)
                      gate up
    in matvec wdown hidden) ff_normed
  in map2 add x_att ff

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
  let hidden = loop state = initial for layer < n_layers do
    decoder_block f h (v*d + layer*block_size d f) checked state
  let final_gain = vector (v*d + n_layers*block_size d f) d checked
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
