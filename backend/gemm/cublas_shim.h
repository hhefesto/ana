#ifndef ANA_CUBLAS_SHIM_H
#define ANA_CUBLAS_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum ana_cublas_numerics {
  ANA_CUBLAS_FP32_IEEE = 0,
  ANA_CUBLAS_TF32_TENSOR_CORES = 1,
  ANA_CUBLAS_BF16_TENSOR_CORES = 2
};

enum ana_cublas_transpose {
  ANA_CUBLAS_NO_TRANS = 0,
  ANA_CUBLAS_TRANS = 1
};

/*
 * All matrices are packed row-major Float arrays. Each batch contains aRows *
 * aCols, bRows * bCols, and cRows * cCols elements respectively. The function
 * stages them through device memory and computes C = op(A) op(B).
 *
 * Returns zero on success. On failure, returns nonzero and writes a terminated
 * diagnostic to error_message when its capacity is nonzero.
 */
int ana_cublas_gemm_strided_batched(
    int numerics,
    int trans_a,
    int trans_b,
    int batch_count,
    int a_rows,
    int a_cols,
    int b_rows,
    int b_cols,
    int c_rows,
    int c_cols,
    const float *a,
    const float *b,
    float *c,
    char *error_message,
    size_t error_capacity);

/*
 * Persistent cuBLAS state: one handle bound to one dedicated stream, plus an
 * optional user workspace (ANA_CUBLAS_WORKSPACE_MB) so cuBLAS stops allocating
 * per call. The stream is created with default (legacy-blocking) flags so it
 * synchronizes with default-stream work. Every entry below returns zero on
 * success and writes a diagnostic on failure, like the staged entry above.
 */
typedef struct ana_cublas_ctx ana_cublas_ctx;

int ana_cublas_ctx_create(
    ana_cublas_ctx **out, char *error_message, size_t error_capacity);
void ana_cublas_ctx_destroy(ana_cublas_ctx *ctx);
int ana_cublas_ctx_sync(
    ana_cublas_ctx *ctx, char *error_message, size_t error_capacity);

/*
 * Same row-major contract as ana_cublas_gemm_strided_batched, but A, B, and C
 * are already device pointers (CUdeviceptr as uint64_t) and the GEMM is only
 * ENQUEUED on the context stream: no staging, no allocation, and no
 * synchronization happen here. The caller owns ordering: device inputs must be
 * ready before the call, and ana_cublas_ctx_sync must complete before C is
 * read, reused, or freed.
 */
int ana_cublas_gemm_strided_batched_device(
    ana_cublas_ctx *ctx,
    int numerics,
    int trans_a,
    int trans_b,
    int batch_count,
    int a_rows,
    int a_cols,
    int b_rows,
    int b_cols,
    int c_rows,
    int c_cols,
    uint64_t device_a,
    uint64_t device_b,
    uint64_t device_c,
    char *error_message,
    size_t error_capacity);

/*
 * Staged host-pointer GEMM through the persistent context: same semantics as
 * ana_cublas_gemm_strided_batched but reusing the context handle, stream, and
 * workspace instead of creating them per call.
 */
int ana_cublas_gemm_strided_batched_ctx(
    ana_cublas_ctx *ctx,
    int numerics,
    int trans_a,
    int trans_b,
    int batch_count,
    int a_rows,
    int a_cols,
    int b_rows,
    int b_cols,
    int c_rows,
    int c_cols,
    const float *a,
    const float *b,
    float *c,
    char *error_message,
    size_t error_capacity);

/* Interop probes and test helpers (device memory owned by the caller). */
size_t ana_cuda_deviceptr_size(void);
int ana_cuda_malloc(
    uint64_t *out, size_t bytes, char *error_message, size_t error_capacity);
int ana_cuda_free(
    uint64_t device_pointer, char *error_message, size_t error_capacity);
int ana_cuda_memcpy_h2d(
    uint64_t device_destination, const void *host_source, size_t bytes,
    char *error_message, size_t error_capacity);
int ana_cuda_memcpy_d2h(
    void *host_destination, uint64_t device_source, size_t bytes,
    char *error_message, size_t error_capacity);

#ifdef __cplusplus
}
#endif

#endif
