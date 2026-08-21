-- Deterministic tiny checks.  These are entries so they can be invoked by
-- `futhark test` harnesses or generated host tests without backend-specific
-- test syntax.

open import "kernels"

-- ==
-- entry: test_parameter_count
-- input { }
-- output { true }
entry test_parameter_count: bool =
  -- arch=0 (v2 semantics), v=3,d=4,f=6,h=1,L=2: both layers are GLA
  -- (softmax needs index 3), so 12 + 2*(64+72+8) + 2*16 + 4 = 336.
  n_params 0 3 4 6 1 2 == 336

-- ==
-- entry: test_finite_outputs
-- input { }
-- output { true }
entry test_finite_outputs: bool =
  let count = n_params 0 3 4 4 2 1
  let params = tabulate count (\i -> f32.i64 ((i % 11) - 5) * 0.01f32)
              :> [parameter_count 0 3 4 4 2 1]f32
  let output = logits 0 3 4 4 2 1 3 params [0i64, 1i64, 2i64]
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
  let count = n_params 0 3 4 4 2 1
  let params = tabulate count (\i -> f32.i64 ((i % 7) - 3) * 0.01f32)
              :> [parameter_count 0 3 4 4 2 1]f32
  let sample = [0i64, 1i64, 2i64]
  let single = next_token_loss 0 3 4 4 2 1 3 sample params
  let batched = batch_mean_loss 0 3 4 4 2 1 3 params [sample, sample]
  in f32.abs (single - batched) < 1.0e-6f32

-- Two accumulated micro-batches equal one full batch_loss_grad, up to f32
-- summation order (the adjoint seeds are identical by construction).
-- ==
-- entry: test_micro_accumulation
-- input { }
-- output { true }
entry test_micro_accumulation: bool =
  let params = tabulate (n_params 0 3 4 4 2 1)
                        (\i -> f32.i64 ((i % 7) - 3) * 0.01f32)
              :> [parameter_count 0 3 4 4 2 1]f32
  let chunk_a = [[0i64, 1i64, 2i64], [0i64, 2i64, 1i64]]
  let chunk_b = [[0i64, 2i64, 2i64], [0i64, 1i64, 1i64]]
  let full = chunk_a ++ chunk_b
  let (full_loss, full_grad) = batch_loss_grad 0 3 4 4 2 1 3 params full
  let acc0 = zero_vector (parameter_count 0 3 4 4 2 1)
  let (loss_a, acc1) = micro_batch_loss_grad 0 3 4 4 2 1 3 4
                         acc0 params chunk_a
  let (loss_b, acc2) = micro_batch_loss_grad 0 3 4 4 2 1 3 4
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
  let count = n_params 0 3 4 4 2 1
  let params = tabulate count (\i -> f32.i64 ((i % 11) - 5) * 0.01f32)
              :> [parameter_count 0 3 4 4 2 1]f32
  let tokens = [0i64, 1i64, 2i64, 1i64, 2i64, 0i64]
  let reference = logits_quadratic 0 3 4 4 2 1 params tokens
  let close (a: [6][3]f32) (b: [6][3]f32): bool =
    all (\pair -> all (\q -> f32.abs (q.0 - q.1) < 1.0e-5f32)
                      (zip pair.0 pair.1))
        (zip a b)
  in close (logits 0 3 4 4 2 1 1 params tokens) reference
     && close (logits 0 3 4 4 2 1 2 params tokens) reference
     && close (logits 0 3 4 4 2 1 3 params tokens) reference
     && close (logits 0 3 4 4 2 1 6 params tokens) reference

-- The RG-LRU write scale sqrt(1 - alpha^2) is singular at alpha = 1: the
-- derivative -exp(2L)/sqrt(1 - exp(2L)) diverges, and in f32 exp(2L) rounds
-- to exactly 1 for |2L| < 6e-8, so the forward is 0 and the pullback is
-- +/-inf under a perfectly finite loss.  That is how the first v3 run died
-- at step 5,006 (2026-08-21); rglru_log_alpha_cap is why it cannot recur.
-- Both endpoints of the gate are checked, not just the singular one.
-- ==
-- entry: test_rglru_write_scale_total
-- input { }
-- output { true }
entry test_rglru_write_scale_total: bool =
  let finite (x: f32): bool = !f32.isnan x && !f32.isinf x
  let logs = [0.0f32, -1.0e-9f32, -1.0e-8f32, -1.0e-6f32, -1.0e-4f32,
              -1.0e-2f32, -1.0f32, -160.0f32]
  let fwd = map rglru_write_scale logs
  let bwd = map (\l -> vjp rglru_write_scale l 1.0f32) logs
  in all finite fwd && all finite bwd && all (\b -> b > 0.0f32) fwd

-- The same check through the composition the block actually differentiates,
-- over the whole reachable (z, lambda) corner: sigmoid(z) underflows to 0
-- below z ~ -90, and log sigmoid(lambda) rounds to 0 above lambda ~ 17.
-- ==
-- entry: test_rglru_gate_total
-- input { }
-- output { true }
entry test_rglru_gate_total: bool =
  let finite (x: f32): bool = !f32.isnan x && !f32.isinf x
  let contribution (z: f32) (lam: f32): f32 =
    rglru_write_scale (rglru_log_gate z lam)
  let zs = [-120.0f32, -80.0f32, -40.0f32, -20.0f32, 0.0f32, 20.0f32, 80.0f32]
  let lams = [-40.0f32, -1.0f32, 0.0f32, 1.0f32, 20.0f32, 60.0f32, 120.0f32]
  let pairs = flatten (map (\z -> map (\l -> (z, l)) lams) zs)
  let values = map (\p -> contribution p.0 p.1) pairs
  let dz = map (\p -> vjp (\z -> contribution z p.1) p.0 1.0f32) pairs
  let dlam = map (\p -> vjp (contribution p.0) p.1 1.0f32) pairs
  in all finite values && all finite dz && all finite dlam
