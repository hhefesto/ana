-- Performance ladder for the differentiated training step.
--
-- Why this exists (finding 2026-07-15): the vjp-generated
-- gradient kernel is pathologically slow at bpe10m scale on every GPU tested,
-- while the small preset hides the problem. Each `bench_grad` dataset moves
-- ONE configuration axis from the small preset (258/64/192/h4/L2/n64) toward
-- bpe10m (8192/320/864/h5/L6/n256), so the superlinear axis shows up in the
-- timings; `bench_forward` is the undifferentiated control that separates
-- forward cost from AD blow-up.
--
-- Dataset index -> axis (identical order for both entries):
--   #0 tiny preset     v=258  d=16  f=48  h=2 L=1 n=16   (fits GPU watchdogs)
--   #1 small base      v=258  d=64  f=192 h=4 L=2 n=64
--   #2 vocab axis      v=8192 d=64  f=192 h=4 L=2 n=64
--   #3 context axis    v=258  d=64  f=192 h=4 L=2 n=256
--   #4 dim axis        v=258  d=320 f=192 h=5 L=2 n=64   (hd=64 as in bpe10m)
--   #5 ff axis         v=258  d=64  f=864 h=4 L=2 n=64
--   #6 layer axis      v=258  d=64  f=192 h=4 L=6 n=64
--   #7 full bpe10m     v=8192 d=320 f=864 h=5 L=6 n=256
--
-- Run (from the repo root):
--   futhark bench --backend=multicore backend/futhark/bench.fut -r 2
--   futhark bench --backend=opencl --profile backend/futhark/bench.fut -r 2 \
--     --json run/bench-opencl.json     # then: futhark profile run/bench-opencl.json
-- On the local Polaris the ~10 s compute-ring watchdog kills long kernels:
-- use --timeout and drop dataset #6 there if it trips.

open import "model"

-- Deterministic, finite, small-magnitude pseudo-parameters. Performance of
-- the step is data-independent (dense arithmetic, no value-driven control
-- flow), so the exact values only need to keep exp/softmax finite.
entry mk_params (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64)
    (n_layers: i64): []f32 =
  let p = parameter_count arch v d f h n_layers
  in tabulate p (\i -> 0.02f32 * f32.sin (f32.i64 i))

-- Valid token windows: every id in [0, v).
entry mk_tokens (v: i64) (batch: i64) (n: i64): [][]i64 =
  tabulate_2d batch n (\b i -> (b * 7919 + i * 104729 + 12345) % v)

-- Mirrors micro_batch_loss_grad's differentiated body (one micro-batch, the
-- cloud trainer's hot path): a per-sample vjp under a sequential batch loop.
-- Summing the gradient keeps it live in the result.
entry bench_grad [batch] [sequence]
    (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: []f32) (tokens: [batch][sequence]i64): f32 =
  let p = parameter_count arch v d f h n_layers
  let candidate0 = params :> [p]f32
  let seed = 1.0f32 / f32.i64 batch
  let (loss_sum, accumulated) =
    loop (loss_sum, acc) = (0.0f32, replicate p 0.0f32) for b < batch do
      let (sample_loss, gradient) =
        vjp2 (next_token_loss arch v d f h n_layers (default_chunk sequence) tokens[b]) candidate0 seed
      in (loss_sum + sample_loss, map2 (+) acc gradient)
  in loss_sum / f32.i64 batch + f32.sum accumulated

-- ==
-- entry: bench_grad
-- script input { (0i64, 258i64, 16i64, 48i64, 2i64, 1i64, mk_params 0i64 258i64 16i64 48i64 2i64 1i64, mk_tokens 258i64 1i64 16i64) }
-- script input { (0i64, 258i64, 64i64, 192i64, 4i64, 2i64, mk_params 0i64 258i64 64i64 192i64 4i64 2i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 8192i64, 64i64, 192i64, 4i64, 2i64, mk_params 0i64 8192i64 64i64 192i64 4i64 2i64, mk_tokens 8192i64 1i64 64i64) }
-- script input { (0i64, 258i64, 64i64, 192i64, 4i64, 2i64, mk_params 0i64 258i64 64i64 192i64 4i64 2i64, mk_tokens 258i64 1i64 256i64) }
-- script input { (0i64, 258i64, 320i64, 192i64, 5i64, 2i64, mk_params 0i64 258i64 320i64 192i64 5i64 2i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 258i64, 64i64, 864i64, 4i64, 2i64, mk_params 0i64 258i64 64i64 864i64 4i64 2i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 258i64, 64i64, 192i64, 4i64, 6i64, mk_params 0i64 258i64 64i64 192i64 4i64 6i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 8192i64, 320i64, 864i64, 5i64, 6i64, mk_params 0i64 8192i64 320i64 864i64 5i64 6i64, mk_tokens 8192i64 1i64 256i64) }

-- The same loss WITHOUT differentiation: the control that isolates how much
-- of each axis's cost is the vjp transformation rather than the forward pass.
entry bench_forward [batch] [sequence]
    (arch: i64) (v: i64) (d: i64) (f: i64) (h: i64) (n_layers: i64)
    (params: []f32) (tokens: [batch][sequence]i64): f32 =
  let p = parameter_count arch v d f h n_layers
  let candidate = params :> [p]f32
  in f32.sum (map (\sample -> next_token_loss arch v d f h n_layers (default_chunk sequence) sample candidate)
                  tokens)
       / f32.i64 batch

-- ==
-- entry: bench_forward
-- script input { (0i64, 258i64, 16i64, 48i64, 2i64, 1i64, mk_params 0i64 258i64 16i64 48i64 2i64 1i64, mk_tokens 258i64 1i64 16i64) }
-- script input { (0i64, 258i64, 64i64, 192i64, 4i64, 2i64, mk_params 0i64 258i64 64i64 192i64 4i64 2i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 8192i64, 64i64, 192i64, 4i64, 2i64, mk_params 0i64 8192i64 64i64 192i64 4i64 2i64, mk_tokens 8192i64 1i64 64i64) }
-- script input { (0i64, 258i64, 64i64, 192i64, 4i64, 2i64, mk_params 0i64 258i64 64i64 192i64 4i64 2i64, mk_tokens 258i64 1i64 256i64) }
-- script input { (0i64, 258i64, 320i64, 192i64, 5i64, 2i64, mk_params 0i64 258i64 320i64 192i64 5i64 2i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 258i64, 64i64, 864i64, 4i64, 2i64, mk_params 0i64 258i64 64i64 864i64 4i64 2i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 258i64, 64i64, 192i64, 4i64, 6i64, mk_params 0i64 258i64 64i64 192i64 4i64 6i64, mk_tokens 258i64 1i64 64i64) }
-- script input { (0i64, 8192i64, 320i64, 864i64, 5i64, 6i64, mk_params 0i64 8192i64 320i64 864i64 5i64 6i64, mk_tokens 8192i64 1i64 256i64) }
