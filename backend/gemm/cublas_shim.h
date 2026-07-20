#ifndef ANA_CUBLAS_SHIM_H
#define ANA_CUBLAS_SHIM_H

#include <stddef.h>

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

#ifdef __cplusplus
}
#endif

#endif
