# Tensor Core runtime test

`formal-transformer-gemm-cuda` runs the validated decomposed model with CUDA
Futhark pieces and cuBLAS GEMMs. Checkpoint storage remains f32. The selected
GEMM interpretation is explicit and checkpointed:

```text
GEMM_NUMERICS=fp32  -> CUBLAS_COMPUTE_32F_PEDANTIC
GEMM_NUMERICS=tf32  -> CUBLAS_COMPUTE_32F_FAST_TF32
GEMM_NUMERICS=bf16  -> CUBLAS_COMPUTE_32F_FAST_16BF
```

Old checkpoints decode as `Fp32IEEE`. Resume rejects a numerics mismatch.

## Build gate

The rental driver must advertise Max CUDA 12.9 or newer.

```bash
nvidia-smi
nix build .#formal-transformer-gemm-cuda
./result/bin/cuda-blas-test
```

The smoke test covers dense forward/reverse and odd rectangular batched
`NN`, `NT`, and `TN` GEMMs in all three modes. It prints maximum errors and
must end with `CudaBlasOps GPU runtime tests passed`.

## Training gate

Use a separate checkpoint for each interpretation:

```bash
GEMM_NUMERICS=fp32 TRAIN_BATCH=1 MICRO_BATCH=1 \
  ./result/bin/formal-transformer-gemm-cuda \
  train CORPUS FP32_CHECKPOINT 1 tiny

GEMM_NUMERICS=tf32 TRAIN_BATCH=1 MICRO_BATCH=1 \
  ./result/bin/formal-transformer-gemm-cuda \
  train CORPUS TF32_CHECKPOINT 1 tiny

GEMM_NUMERICS=bf16 TRAIN_BATCH=1 MICRO_BATCH=1 \
  ./result/bin/formal-transformer-gemm-cuda \
  train CORPUS BF16_CHECKPOINT 1 tiny
```

Confirm the training log names the requested numerics and each resulting
checkpoint reports that mode with `formal-transformer inspect-checkpoint`.
Then run the planned FP32 conformance and 2,000-step trajectory comparisons
before treating TF32 or BF16 checkpoints as accepted training artifacts.

## Current performance scope

This first runtime stages lists through host memory at piece and GEMM
boundaries and creates temporary cuBLAS resources per GEMM. It is intended to
establish hardware correctness and real Tensor Core execution. Device-resident
buffers, persistent cuBLAS handles, shared-stream ordering, and graph capture
are subsequent performance work; they do not change checkpoint semantics.
