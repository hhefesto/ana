#include "cublas_shim.h"

#include <cublas_v2.h>
#include <cuda_runtime_api.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

static void set_error(char *message, size_t capacity, const char *format, ...) {
  va_list arguments;

  if (message == NULL || capacity == 0) {
    return;
  }
  va_start(arguments, format);
  (void)vsnprintf(message, capacity, format, arguments);
  va_end(arguments);
  message[capacity - 1] = '\0';
}

static const char *cublas_status_name(cublasStatus_t status) {
  switch (status) {
    case CUBLAS_STATUS_SUCCESS: return "CUBLAS_STATUS_SUCCESS";
    case CUBLAS_STATUS_NOT_INITIALIZED: return "CUBLAS_STATUS_NOT_INITIALIZED";
    case CUBLAS_STATUS_ALLOC_FAILED: return "CUBLAS_STATUS_ALLOC_FAILED";
    case CUBLAS_STATUS_INVALID_VALUE: return "CUBLAS_STATUS_INVALID_VALUE";
    case CUBLAS_STATUS_ARCH_MISMATCH: return "CUBLAS_STATUS_ARCH_MISMATCH";
    case CUBLAS_STATUS_MAPPING_ERROR: return "CUBLAS_STATUS_MAPPING_ERROR";
    case CUBLAS_STATUS_EXECUTION_FAILED: return "CUBLAS_STATUS_EXECUTION_FAILED";
    case CUBLAS_STATUS_INTERNAL_ERROR: return "CUBLAS_STATUS_INTERNAL_ERROR";
    case CUBLAS_STATUS_NOT_SUPPORTED: return "CUBLAS_STATUS_NOT_SUPPORTED";
#ifdef CUBLAS_STATUS_LICENSE_ERROR
    case CUBLAS_STATUS_LICENSE_ERROR: return "CUBLAS_STATUS_LICENSE_ERROR";
#endif
    default: return "unknown cuBLAS status";
  }
}

static int checked_elements(
    int batch_count, int rows, int cols, size_t *elements) {
  size_t batch;
  size_t row_count;
  size_t col_count;

  if (batch_count < 0 || rows < 0 || cols < 0) {
    return 0;
  }
  batch = (size_t)batch_count;
  row_count = (size_t)rows;
  col_count = (size_t)cols;
  if (row_count != 0 && col_count > SIZE_MAX / row_count) {
    return 0;
  }
  *elements = row_count * col_count;
  if (*elements != 0 && batch > SIZE_MAX / *elements) {
    return 0;
  }
  *elements *= batch;
  return *elements <= SIZE_MAX / sizeof(float);
}

static int cuda_failure(
    const char *stage, cudaError_t status, char *message, size_t capacity) {
  set_error(message, capacity, "%s failed: %s (%d)", stage,
      cudaGetErrorString(status), (int)status);
  return 1;
}

static int cublas_failure(
    const char *stage, cublasStatus_t status, char *message, size_t capacity) {
  set_error(message, capacity, "%s failed: %s (%d)", stage,
      cublas_status_name(status), (int)status);
  return 1;
}

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
    size_t error_capacity) {
  cublasHandle_t handle = NULL;
  float *device_a = NULL;
  float *device_b = NULL;
  float *device_c = NULL;
  size_t a_elements = 0;
  size_t b_elements = 0;
  size_t c_elements = 0;
  size_t a_bytes;
  size_t b_bytes;
  size_t c_bytes;
  int logical_a_rows;
  int logical_a_cols;
  int logical_b_rows;
  int logical_b_cols;
  cublasOperation_t operation_a;
  cublasOperation_t operation_b;
  cublasComputeType_t compute_type;
  cublasStatus_t cublas_status;
  cudaError_t cuda_status;
  float alpha = 1.0f;
  float beta = 0.0f;
  int result = 1;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  if ((trans_a != ANA_CUBLAS_NO_TRANS && trans_a != ANA_CUBLAS_TRANS) ||
      (trans_b != ANA_CUBLAS_NO_TRANS && trans_b != ANA_CUBLAS_TRANS)) {
    set_error(error_message, error_capacity, "invalid transpose code (%d, %d)",
        trans_a, trans_b);
    return 1;
  }
  if (!checked_elements(batch_count, a_rows, a_cols, &a_elements) ||
      !checked_elements(batch_count, b_rows, b_cols, &b_elements) ||
      !checked_elements(batch_count, c_rows, c_cols, &c_elements)) {
    set_error(error_message, error_capacity,
        "invalid or overflowing dimensions: batch=%d A=%dx%d B=%dx%d C=%dx%d",
        batch_count, a_rows, a_cols, b_rows, b_cols, c_rows, c_cols);
    return 1;
  }

  logical_a_rows = trans_a == ANA_CUBLAS_NO_TRANS ? a_rows : a_cols;
  logical_a_cols = trans_a == ANA_CUBLAS_NO_TRANS ? a_cols : a_rows;
  logical_b_rows = trans_b == ANA_CUBLAS_NO_TRANS ? b_rows : b_cols;
  logical_b_cols = trans_b == ANA_CUBLAS_NO_TRANS ? b_cols : b_rows;
  if (logical_a_cols != logical_b_rows || c_rows != logical_a_rows ||
      c_cols != logical_b_cols) {
    set_error(error_message, error_capacity,
        "GEMM dimension mismatch: op(A)=%dx%d op(B)=%dx%d C=%dx%d",
        logical_a_rows, logical_a_cols, logical_b_rows, logical_b_cols,
        c_rows, c_cols);
    return 1;
  }
  if (batch_count == 0 || c_rows == 0 || c_cols == 0) {
    return 0;
  }
  if (logical_a_cols == 0) {
    for (size_t index = 0; index < c_elements; ++index) {
      c[index] = 0.0f;
    }
    return 0;
  }
  if (a == NULL || b == NULL || c == NULL) {
    set_error(error_message, error_capacity, "non-empty GEMM received a null host pointer");
    return 1;
  }

#if defined(CUBLAS_VERSION) && CUBLAS_VERSION >= 11000
  switch (numerics) {
    case ANA_CUBLAS_FP32_IEEE:
      compute_type = CUBLAS_COMPUTE_32F_PEDANTIC;
      break;
    case ANA_CUBLAS_TF32_TENSOR_CORES:
      compute_type = CUBLAS_COMPUTE_32F_FAST_TF32;
      break;
    case ANA_CUBLAS_BF16_TENSOR_CORES:
      /* Float checkpoint storage stays unchanged; only the compute mode changes. */
      compute_type = CUBLAS_COMPUTE_32F_FAST_16BF;
      break;
    default:
      set_error(error_message, error_capacity, "invalid numerics code %d", numerics);
      return 1;
  }
#else
  (void)compute_type;
  set_error(error_message, error_capacity,
      "CUDA 11 or newer is required for explicit cuBLAS compute modes");
  return 1;
#endif

  a_bytes = a_elements * sizeof(float);
  b_bytes = b_elements * sizeof(float);
  c_bytes = c_elements * sizeof(float);

  cublas_status = cublasCreate(&handle);
  if (cublas_status != CUBLAS_STATUS_SUCCESS) {
    return cublas_failure("cublasCreate", cublas_status,
        error_message, error_capacity);
  }
  cuda_status = cudaMalloc((void **)&device_a, a_bytes);
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaMalloc(A)", cuda_status, error_message, error_capacity);
    goto cleanup;
  }
  cuda_status = cudaMalloc((void **)&device_b, b_bytes);
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaMalloc(B)", cuda_status, error_message, error_capacity);
    goto cleanup;
  }
  cuda_status = cudaMalloc((void **)&device_c, c_bytes);
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaMalloc(C)", cuda_status, error_message, error_capacity);
    goto cleanup;
  }
  cuda_status = cudaMemcpy(device_a, a, a_bytes, cudaMemcpyHostToDevice);
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaMemcpy(A host-to-device)", cuda_status,
        error_message, error_capacity);
    goto cleanup;
  }
  cuda_status = cudaMemcpy(device_b, b, b_bytes, cudaMemcpyHostToDevice);
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaMemcpy(B host-to-device)", cuda_status,
        error_message, error_capacity);
    goto cleanup;
  }
  cuda_status = cudaMemset(device_c, 0, c_bytes);
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaMemset(C)", cuda_status, error_message, error_capacity);
    goto cleanup;
  }

  operation_a = trans_a == ANA_CUBLAS_NO_TRANS ? CUBLAS_OP_N : CUBLAS_OP_T;
  operation_b = trans_b == ANA_CUBLAS_NO_TRANS ? CUBLAS_OP_N : CUBLAS_OP_T;

  /* Row-major C=op(A)op(B) is C^T=op(B)^T op(A)^T in column-major cuBLAS. */
  if (batch_count == 1) {
    cublas_status = cublasGemmEx(
        handle,
        operation_b, operation_a,
        c_cols, c_rows, logical_a_cols,
        &alpha,
        device_b, CUDA_R_32F, b_cols,
        device_a, CUDA_R_32F, a_cols,
        &beta,
        device_c, CUDA_R_32F, c_cols,
        compute_type,
        CUBLAS_GEMM_DEFAULT);
  } else {
    cublas_status = cublasGemmStridedBatchedEx(
        handle,
        operation_b, operation_a,
        c_cols, c_rows, logical_a_cols,
        &alpha,
        device_b, CUDA_R_32F, b_cols, (long long)b_rows * b_cols,
        device_a, CUDA_R_32F, a_cols, (long long)a_rows * a_cols,
        &beta,
        device_c, CUDA_R_32F, c_cols, (long long)c_rows * c_cols,
        batch_count,
        compute_type,
        CUBLAS_GEMM_DEFAULT);
  }
  if (cublas_status != CUBLAS_STATUS_SUCCESS) {
    cublas_failure(batch_count == 1 ? "cublasGemmEx" :
        "cublasGemmStridedBatchedEx", cublas_status,
        error_message, error_capacity);
    goto cleanup;
  }
  cuda_status = cudaDeviceSynchronize();
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaDeviceSynchronize", cuda_status,
        error_message, error_capacity);
    goto cleanup;
  }
  cuda_status = cudaMemcpy(c, device_c, c_bytes, cudaMemcpyDeviceToHost);
  if (cuda_status != cudaSuccess) {
    cuda_failure("cudaMemcpy(C device-to-host)", cuda_status,
        error_message, error_capacity);
    goto cleanup;
  }
  result = 0;

cleanup:
  if (device_c != NULL) (void)cudaFree(device_c);
  if (device_b != NULL) (void)cudaFree(device_b);
  if (device_a != NULL) (void)cudaFree(device_a);
  if (handle != NULL) (void)cublasDestroy(handle);
  return result;
}
