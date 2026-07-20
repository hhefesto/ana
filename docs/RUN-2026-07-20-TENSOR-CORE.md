# RUN 2026-07-20 — first tensor-core execution (Stage C gates)

Box: vast.ai RTX 5060 Ti (Blackwell sm_120, 16 GB), driver 570.153.02,
Max CUDA 12.8, 48-core host, Ubuntu 24.04 container. Flake repinned to
`cudaPackages_12_8` to match the driver (commit 17dac44); NVRTC 12.8 PTX
accepted at context creation (the earlier 12.9 pin was never exercised on
this driver).

## Build gate — PASSED

`nix build .#formal-transformer-gemm-cuda` via `BUILD_GEMM_CUDA=1
cloud-init.sh`; libcuda resolved through the driver-libs workaround
(`run/cloud-env.sh`). `cuda-blas-test` on the GPU:

```text
FP32 IEEE max errors: dense=1.34935430e-7, dX=8.74476447e-8, dW=1.06525255e-7, NN=1.72575040e-7, NT=2.71984865e-7, TN=1.72123881e-7; overall=2.71984865e-7
TF32 max errors: dense=1.34935430e-7, dX=8.74476447e-8, dW=7.82337207e-4, NN=1.72575040e-7, NT=2.71984865e-7, TN=1.19172957e-3; overall=1.19172957e-3
BF16 max errors: dense=1.20641773e-3, dX=6.20866936e-4, dW=7.82337207e-4, NN=1.72575040e-7, NT=2.71984865e-7, TN=1.39552022e-2; overall=1.39552022e-2
CudaBlasOps GPU runtime tests passed
```

The error growth from FP32 → TF32 → BF16 on the pullback and TN cases is
the tensor-core signature: the modes execute genuinely different GEMM
arithmetic, each within its stated tolerance (fp32 3e-6, tf32 4e-3,
bf16 3e-2).

## Training gate — PASSED

One 1-step `tiny` train per interpretation (`TRAIN_BATCH=1 MICRO_BATCH=1`,
byte corpus from repo docs). All three runs logged their numerics and
checkpointed; train losses differ at the 1e-5 level across modes (distinct
arithmetic, same trajectory shape):

| mode | logged numerics | train_loss (step 1) |
|---|---|---|
| fp32 | Fp32IEEE | 5.5538550 |
| tf32 | Tf32TensorCores | 5.5538473 |
| bf16 | Bf16TensorCores | 5.5538760 |

Checkpoints pulled to the local (CPU) machine decode and report their mode
via `inspect-checkpoint` — artifact portability holds. Same-schedule resume
of the fp32 checkpoint under `GEMM_NUMERICS=tf32` is rejected:

```text
checkpoint numerics do not match this backend
  checkpoint: Fp32IEEE
  this run:   Tf32TensorCores
```

## Performance observation (expected, not a regression)

20 `gla-small` steps, batch 1, tf32: 102.8 s wall ≈ 5.1 s/step (includes
one-time NVRTC startup). This matches the documented scope of the first
runtime — host-list staging at every boundary, per-GEMM cuBLAS resource
lifecycle, host AdamW. It establishes correctness on hardware; device
residency, persistent handles, and stream ordering are the follow-on
performance work (docs/TENSOR-CORE-RUNTIME.md "Current performance scope").

## Trajectory A/B — in progress

2000-step `gla-small` runs per mode (fp32/tf32/bf16) on a 452 KB byte
corpus of the repo docs, `VALIDATE_EVERY=500 VALIDATION_WINDOWS=16`,
launched 2026-07-20 ~18:00. Results to be appended here before TF32/BF16
checkpoints are treated as accepted training artifacts.
