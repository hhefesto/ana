-- Reduced entry-point set for the OpenCL trainer.  rusticl compiles the
-- whole generated program with clBuildProgram on the host CPU, and that
-- time grows with the amount of vjp-generated code, so this program keeps
-- exactly ONE differentiated entry: micro_batch_loss_grad.  batch_loss_grad
-- and loss_grad are recovered semantically as the single-chunk and
-- single-sequence cases (linearity: D(sum f_i) = sum (D f_i)); the
-- conformance oracle checks that equality against the full kernels.fut on
-- the sequential backend.

open import "model"


entry n_params (v: i64) (d: i64) (f: i64) (n_layers: i64): i64 =
  assert (v > 0 && d > 0 && f > 0 && n_layers > 0)
  parameter_count v d f n_layers

entry logits [n]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (params: [parameter_count v d f n_layers]f32)
    (tokens: [n]i64): [n][v]f32 =
  model_logits v d f h n_layers chunk params tokens

entry last_logits [n]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (params: [parameter_count v d f n_layers]f32)
    (tokens: [n]i64): [v]f32 =
  last (model_logits v d f h n_layers chunk params tokens)

-- Conformance-oriented full-prefix inference.  Causality means row i is the
-- same result as running last_logits on tokens[:i+1].  A shape-safe true KV
-- Mean next-token cross-entropy over a nonempty minibatch.  Every sequence
-- has the same statically known length and contributes equally to the mean.
entry batch_mean_loss [batch] [sequence]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (params: [parameter_count v d f n_layers]f32)
    (tokens: [batch][sequence]i64): f32 =
  batch_mean_loss_def v d f h n_layers chunk params tokens


entry zero_vector (count: i64): [count]f32 =
  replicate (assert (count >= 0) count) 0.0f32


-- Data constructors for profiling this exact production program.  They are
-- deliberately nondifferentiated and do not enlarge the vjp-generated code.
-- Keeping them here lets futhark-autotune emit parameter names that the CUDA
-- trainer itself accepts (names from the separate bench.fut program are not
-- guaranteed to be portable).
entry benchmark_params (v: i64) (d: i64) (f: i64) (n_layers: i64)
    : [parameter_count v d f n_layers]f32 =
  replicate (parameter_count v d f n_layers) 0.0f32

entry benchmark_tokens (batch: i64) (sequence: i64): [batch][sequence]i64 =
  replicate batch (replicate sequence 0i64)


-- One micro-batch of gradient accumulation, justified by linearity of the
-- reverse derivative: D(sum f_i) = sum (D f_i).  The partial objective of a
-- chunk is sum_{s in chunk} mean-CE(s) / effective_batch, so every
-- per-sequence adjoint is seeded with the same 1/effective_batch as
-- batch_loss_grad on the whole effective batch.  Summing the returned
-- partial losses and gradients over a partition of the effective batch
-- therefore equals the full-batch result up to f32 summation order only.
--
-- The differentiation is applied per sample, inside a sequential loop over
-- the chunk, rather than to the batch-summed objective.  The two are equal
-- by the same linearity (the seed 1/effective_batch is exactly the adjoint
-- the division hands each sample), but the generated code is radically
-- different: a vjp under a map over the batch compiles to ONE kernel whose
-- only parallel dimension is the batch, so a micro-batch of 1 runs the
-- whole reverse sweep on a single GPU thread (measured 2026-07-16: >17 min
-- per step on an RTX 3090 at bpe10m scale).  A per-sample vjp distributes
-- into a few hundred kernels parallel over sequence/dim/vocab, and the
-- samples pay a sequential loop that costs nothing when each sweep already
-- fills the GPU.  See HANDOFF.md.
entry micro_batch_loss_grad [batch] [sequence]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (chunk: i64)
    (effective_batch: i64)
    (accumulator: [parameter_count v d f n_layers]f32)
    (params: [parameter_count v d f n_layers]f32)
    (tokens: [batch][sequence]i64)
    : (f32, [parameter_count v d f n_layers]f32) =
  let checked = assert (batch > 0 && sequence >= 2 &&
                        effective_batch >= batch) tokens
  let seed = 1.0f32 / f32.i64 effective_batch
  let (loss_sum, accumulated) =
    loop (loss_sum, acc) = (0.0f32, accumulator) for b < batch do
      let (sample_loss, gradient) =
        vjp2 (next_token_loss v d f h n_layers chunk checked[b]) params seed
      in (loss_sum + sample_loss, map2 (+) acc gradient)
  in (loss_sum / f32.i64 effective_batch, accumulated)

entry clip_global_norm [p] (max_norm: f32) (gradient: [p]f32)
    : (f32, [p]f32) =
  let checked = assert (max_norm > 0.0f32) gradient
  let norm = f32.sqrt (f32.sum (map (\g -> g*g) checked))
  let scale = if norm > max_norm then max_norm/(norm + 1.0e-12f32) else 1.0f32
  in (norm, map (*scale) checked)


-- One AdamW update.  decay_mask[i] selects decoupled weight decay for
-- params[i]; moments never include the decay term.  step is one-based.
entry adamw_step [p]
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

-- Incremental decoding: the proved cache-run law executed with fixed-size
-- per-layer state (GLA matrices and a NoPE softmax ring-buffer KV cache).
-- Nondifferentiated, so it does not enlarge the vjp-generated code.
entry decode_step [gs] [ks]
    (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64) (ctx: i64)
    (params: [parameter_count v d f n_layers]f32)
    (position: i64) (token: i64)
    (gla_state: *[gs]f32) (k_cache: *[ks]f32) (v_cache: *[ks]f32)
    : ([v]f32, *[gs]f32, *[ks]f32, *[ks]f32) =
  decode_step_def v d f h n_layers ctx params position token
                  gla_state k_cache v_cache
