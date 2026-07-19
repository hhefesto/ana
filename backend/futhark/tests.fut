-- Deterministic tiny checks.  These are entries so they can be invoked by
-- `futhark test` harnesses or generated host tests without backend-specific
-- test syntax.

open import "kernels"

-- ==
-- entry: test_parameter_count
-- input { }
-- output { true }
entry test_parameter_count: bool =
  -- v=3,d=4,f=6,L=2: both layers are GLA (softmax needs index 3), so
  -- 12 + 2*(64+72+8) + 2*16 + 4 = 336.
  n_params 3 4 6 2 == 336

-- ==
-- entry: test_finite_outputs
-- input { }
-- output { true }
entry test_finite_outputs: bool =
  let count = n_params 3 4 4 1
  let params = tabulate count (\i -> f32.i64 ((i % 11) - 5) * 0.01f32)
              :> [parameter_count 3 4 4 1]f32
  let output = logits 3 4 4 2 1 3 params [0i64, 1i64, 2i64]
  in all (\row -> all (\x -> !f32.isnan x && !f32.isinf x) row) output

-- ==
-- entry: test_adamw_decay
-- input { }
-- output { true }
entry test_adamw_decay: bool =
  let params = [2.0f32, 2.0f32]
  let zeros = [0.0f32, 0.0f32]
  let (updated, _, _) = adamw_step 1 0.1f32 0.9f32 0.999f32
                         1.0e-8f32 0.5f32 params zeros zeros zeros
                         [true, false]
  in f32.abs (updated[0] - 1.9f32) < 1.0e-6f32 &&
     updated[1] == 2.0f32

-- ==
-- entry: test_batch_mean_loss
-- input { }
-- output { true }
entry test_batch_mean_loss: bool =
  let count = n_params 3 4 4 1
  let params = tabulate count (\i -> f32.i64 ((i % 7) - 3) * 0.01f32)
              :> [parameter_count 3 4 4 1]f32
  let sample = [0i64, 1i64, 2i64]
  let single = next_token_loss 3 4 4 2 1 3 sample params
  let batched = batch_mean_loss 3 4 4 2 1 3 params [sample, sample]
  in f32.abs (single - batched) < 1.0e-6f32

-- Two accumulated micro-batches equal one full batch_loss_grad, up to f32
-- summation order (the adjoint seeds are identical by construction).
-- ==
-- entry: test_micro_accumulation
-- input { }
-- output { true }
entry test_micro_accumulation: bool =
  let params = tabulate (n_params 3 4 4 1)
                        (\i -> f32.i64 ((i % 7) - 3) * 0.01f32)
              :> [parameter_count 3 4 4 1]f32
  let chunk_a = [[0i64, 1i64, 2i64], [0i64, 2i64, 1i64]]
  let chunk_b = [[0i64, 2i64, 2i64], [0i64, 1i64, 1i64]]
  let full = chunk_a ++ chunk_b
  let (full_loss, full_grad) = batch_loss_grad 3 4 4 2 1 3 params full
  let acc0 = zero_vector (parameter_count 3 4 4 1)
  let (loss_a, acc1) = micro_batch_loss_grad 3 4 4 2 1 3 4
                         acc0 params chunk_a
  let (loss_b, acc2) = micro_batch_loss_grad 3 4 4 2 1 3 4
                         acc1 params chunk_b
  in f32.abs (full_loss - (loss_a + loss_b)) < 1.0e-6f32 &&
     all (\pair -> f32.abs (pair.0 - pair.1) < 1.0e-6f32)
         (zip full_grad acc2)

-- The chunked and quadratic GLA executions are one denotation
-- (chunk-closed): same logits for every chunk size that divides the
-- window, up to f32 reassociation.
-- ==
-- entry: test_chunk_equivalence
-- input { }
-- output { true }
entry test_chunk_equivalence: bool =
  let count = n_params 3 4 4 1
  let params = tabulate count (\i -> f32.i64 ((i % 11) - 5) * 0.01f32)
              :> [parameter_count 3 4 4 1]f32
  let tokens = [0i64, 1i64, 2i64, 1i64, 2i64, 0i64]
  let reference = logits_quadratic 3 4 4 2 1 params tokens
  let close (a: [6][3]f32) (b: [6][3]f32): bool =
    all (\pair -> all (\q -> f32.abs (q.0 - q.1) < 1.0e-5f32)
                      (zip pair.0 pair.1))
        (zip a b)
  in close (logits 3 4 4 2 1 1 params tokens) reference
     && close (logits 3 4 4 2 1 2 params tokens) reference
     && close (logits 3 4 4 2 1 3 params tokens) reference
     && close (logits 3 4 4 2 1 6 params tokens) reference
