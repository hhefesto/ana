#include "cublas_shim.h"

#include <cublas_v2.h>
#include <cuda_runtime_api.h>

#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

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

/* Validated shape data shared by the staged and device entries. */
struct gemm_call {
  size_t a_elements;
  size_t b_elements;
  size_t c_elements;
  int logical_a_cols; /* the contraction extent k */
  cublasOperation_t operation_a;
  cublasOperation_t operation_b;
  cublasComputeType_t compute_type;
};

/* Returns nonzero on failure with the diagnostic written. */
static int validate_gemm(
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
    struct gemm_call *call,
    char *error_message,
    size_t error_capacity) {
  int logical_a_rows;
  int logical_b_rows;
  int logical_b_cols;

  if ((trans_a != ANA_CUBLAS_NO_TRANS && trans_a != ANA_CUBLAS_TRANS) ||
      (trans_b != ANA_CUBLAS_NO_TRANS && trans_b != ANA_CUBLAS_TRANS)) {
    set_error(error_message, error_capacity, "invalid transpose code (%d, %d)",
        trans_a, trans_b);
    return 1;
  }
  if (!checked_elements(batch_count, a_rows, a_cols, &call->a_elements) ||
      !checked_elements(batch_count, b_rows, b_cols, &call->b_elements) ||
      !checked_elements(batch_count, c_rows, c_cols, &call->c_elements)) {
    set_error(error_message, error_capacity,
        "invalid or overflowing dimensions: batch=%d A=%dx%d B=%dx%d C=%dx%d",
        batch_count, a_rows, a_cols, b_rows, b_cols, c_rows, c_cols);
    return 1;
  }

  logical_a_rows = trans_a == ANA_CUBLAS_NO_TRANS ? a_rows : a_cols;
  call->logical_a_cols = trans_a == ANA_CUBLAS_NO_TRANS ? a_cols : a_rows;
  logical_b_rows = trans_b == ANA_CUBLAS_NO_TRANS ? b_rows : b_cols;
  logical_b_cols = trans_b == ANA_CUBLAS_NO_TRANS ? b_cols : b_rows;
  if (call->logical_a_cols != logical_b_rows || c_rows != logical_a_rows ||
      c_cols != logical_b_cols) {
    set_error(error_message, error_capacity,
        "GEMM dimension mismatch: op(A)=%dx%d op(B)=%dx%d C=%dx%d",
        logical_a_rows, call->logical_a_cols, logical_b_rows, logical_b_cols,
        c_rows, c_cols);
    return 1;
  }

  call->operation_a = trans_a == ANA_CUBLAS_NO_TRANS ? CUBLAS_OP_N : CUBLAS_OP_T;
  call->operation_b = trans_b == ANA_CUBLAS_NO_TRANS ? CUBLAS_OP_N : CUBLAS_OP_T;

#if defined(CUBLAS_VERSION) && CUBLAS_VERSION >= 11000
  switch (numerics) {
    case ANA_CUBLAS_FP32_IEEE:
      call->compute_type = CUBLAS_COMPUTE_32F_PEDANTIC;
      break;
    case ANA_CUBLAS_TF32_TENSOR_CORES:
      call->compute_type = CUBLAS_COMPUTE_32F_FAST_TF32;
      break;
    case ANA_CUBLAS_BF16_TENSOR_CORES:
      /* Float checkpoint storage stays unchanged; only the compute mode changes. */
      call->compute_type = CUBLAS_COMPUTE_32F_FAST_16BF;
      break;
    default:
      set_error(error_message, error_capacity, "invalid numerics code %d", numerics);
      return 1;
  }
#else
  set_error(error_message, error_capacity,
      "CUDA 11 or newer is required for explicit cuBLAS compute modes");
  return 1;
#endif
  return 0;
}

/* Row-major C=op(A)op(B) is C^T=op(B)^T op(A)^T in column-major cuBLAS. */
static cublasStatus_t enqueue_gemm(
    cublasHandle_t handle,
    const struct gemm_call *call,
    int batch_count,
    int a_rows,
    int a_cols,
    int b_rows,
    int b_cols,
    int c_rows,
    int c_cols,
    const float *device_a,
    const float *device_b,
    float *device_c) {
  float alpha = 1.0f;
  float beta = 0.0f;

  if (batch_count == 1) {
    return cublasGemmEx(
        handle,
        call->operation_b, call->operation_a,
        c_cols, c_rows, call->logical_a_cols,
        &alpha,
        device_b, CUDA_R_32F, b_cols,
        device_a, CUDA_R_32F, a_cols,
        &beta,
        device_c, CUDA_R_32F, c_cols,
        call->compute_type,
        CUBLAS_GEMM_DEFAULT);
  }
  return cublasGemmStridedBatchedEx(
      handle,
      call->operation_b, call->operation_a,
      c_cols, c_rows, call->logical_a_cols,
      &alpha,
      device_b, CUDA_R_32F, b_cols, (long long)b_rows * b_cols,
      device_a, CUDA_R_32F, a_cols, (long long)a_rows * a_cols,
      &beta,
      device_c, CUDA_R_32F, c_cols, (long long)c_rows * c_cols,
      batch_count,
      call->compute_type,
      CUBLAS_GEMM_DEFAULT);
}

struct ana_cublas_ctx {
  cublasHandle_t handle;
  cudaStream_t stream;
  void *workspace;
};

int ana_cublas_ctx_create(
    ana_cublas_ctx **out, char *error_message, size_t error_capacity) {
  ana_cublas_ctx *ctx;
  cublasStatus_t cublas_status;
  cudaError_t cuda_status;
  const char *workspace_env;
  size_t workspace_bytes = 0;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  *out = NULL;
  ctx = calloc(1, sizeof(*ctx));
  if (ctx == NULL) {
    set_error(error_message, error_capacity, "ana_cublas_ctx allocation failed");
    return 1;
  }
  cublas_status = cublasCreate(&ctx->handle);
  if (cublas_status != CUBLAS_STATUS_SUCCESS) {
    free(ctx);
    return cublas_failure("cublasCreate", cublas_status,
        error_message, error_capacity);
  }
  /* Default (legacy-blocking) flags: the dedicated stream synchronizes with
     default-stream work, an extra safety margin under the conservative
     ownership-transfer barriers. */
  cuda_status = cudaStreamCreate(&ctx->stream);
  if (cuda_status != cudaSuccess) {
    (void)cublasDestroy(ctx->handle);
    free(ctx);
    return cuda_failure("cudaStreamCreate", cuda_status,
        error_message, error_capacity);
  }
  cublas_status = cublasSetStream(ctx->handle, ctx->stream);
  if (cublas_status != CUBLAS_STATUS_SUCCESS) {
    (void)cudaStreamDestroy(ctx->stream);
    (void)cublasDestroy(ctx->handle);
    free(ctx);
    return cublas_failure("cublasSetStream", cublas_status,
        error_message, error_capacity);
  }
  workspace_env = getenv("ANA_CUBLAS_WORKSPACE_MB");
  if (workspace_env != NULL && workspace_env[0] != '\0') {
    char *parse_end = NULL;
    long megabytes = strtol(workspace_env, &parse_end, 10);
    if (parse_end == NULL || *parse_end != '\0' || megabytes < 0) {
      ana_cublas_ctx_destroy(ctx);
      set_error(error_message, error_capacity,
          "invalid ANA_CUBLAS_WORKSPACE_MB: %s", workspace_env);
      return 1;
    }
    workspace_bytes = (size_t)megabytes * 1024u * 1024u;
  }
  if (workspace_bytes != 0) {
    cuda_status = cudaMalloc(&ctx->workspace, workspace_bytes);
    if (cuda_status != cudaSuccess) {
      ana_cublas_ctx_destroy(ctx);
      return cuda_failure("cudaMalloc(cuBLAS workspace)", cuda_status,
          error_message, error_capacity);
    }
    cublas_status = cublasSetWorkspace(ctx->handle, ctx->workspace,
        workspace_bytes);
    if (cublas_status != CUBLAS_STATUS_SUCCESS) {
      ana_cublas_ctx_destroy(ctx);
      return cublas_failure("cublasSetWorkspace", cublas_status,
          error_message, error_capacity);
    }
  }
  *out = ctx;
  return 0;
}

void ana_cublas_ctx_destroy(ana_cublas_ctx *ctx) {
  if (ctx == NULL) {
    return;
  }
  if (ctx->workspace != NULL) {
    (void)cudaFree(ctx->workspace);
  }
  (void)cudaStreamDestroy(ctx->stream);
  (void)cublasDestroy(ctx->handle);
  free(ctx);
}

int ana_cublas_ctx_sync(
    ana_cublas_ctx *ctx, char *error_message, size_t error_capacity) {
  cudaError_t cuda_status;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  if (ctx == NULL) {
    set_error(error_message, error_capacity, "ana_cublas_ctx_sync: null context");
    return 1;
  }
  cuda_status = cudaStreamSynchronize(ctx->stream);
  if (cuda_status != cudaSuccess) {
    return cuda_failure("cudaStreamSynchronize", cuda_status,
        error_message, error_capacity);
  }
  return 0;
}

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
    size_t error_capacity) {
  struct gemm_call call;
  cublasStatus_t cublas_status;
  cudaError_t cuda_status;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  if (ctx == NULL) {
    set_error(error_message, error_capacity, "device GEMM: null context");
    return 1;
  }
  if (validate_gemm(numerics, trans_a, trans_b, batch_count,
          a_rows, a_cols, b_rows, b_cols, c_rows, c_cols,
          &call, error_message, error_capacity)) {
    return 1;
  }
  if (batch_count == 0 || c_rows == 0 || c_cols == 0) {
    return 0;
  }
  if (device_a == 0 || device_b == 0 || device_c == 0) {
    set_error(error_message, error_capacity,
        "non-empty device GEMM received a null device pointer");
    return 1;
  }
  if (call.logical_a_cols == 0) {
    cuda_status = cudaMemsetAsync((void *)(uintptr_t)device_c, 0,
        call.c_elements * sizeof(float), ctx->stream);
    if (cuda_status != cudaSuccess) {
      return cuda_failure("cudaMemsetAsync(C)", cuda_status,
          error_message, error_capacity);
    }
    return 0;
  }
  cublas_status = enqueue_gemm(ctx->handle, &call, batch_count,
      a_rows, a_cols, b_rows, b_cols, c_rows, c_cols,
      (const float *)(uintptr_t)device_a,
      (const float *)(uintptr_t)device_b,
      (float *)(uintptr_t)device_c);
  if (cublas_status != CUBLAS_STATUS_SUCCESS) {
    return cublas_failure(batch_count == 1 ? "cublasGemmEx" :
        "cublasGemmStridedBatchedEx", cublas_status,
        error_message, error_capacity);
  }
  return 0;
}

/* Staged host-pointer GEMM. With a context, its handle/stream are reused and
   only the stream is synchronized; without one (the legacy entry), a handle is
   created per call and the whole device is synchronized, preserving the
   original entry's behavior exactly. */
static int staged_gemm(
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
    size_t error_capacity) {
  struct gemm_call call;
  cublasHandle_t handle = NULL;
  int own_handle = 0;
  float *device_a = NULL;
  float *device_b = NULL;
  float *device_c = NULL;
  size_t a_bytes;
  size_t b_bytes;
  size_t c_bytes;
  cublasStatus_t cublas_status;
  cudaError_t cuda_status;
  int result = 1;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  if (validate_gemm(numerics, trans_a, trans_b, batch_count,
          a_rows, a_cols, b_rows, b_cols, c_rows, c_cols,
          &call, error_message, error_capacity)) {
    return 1;
  }
  if (batch_count == 0 || c_rows == 0 || c_cols == 0) {
    return 0;
  }
  if (call.logical_a_cols == 0) {
    for (size_t index = 0; index < call.c_elements; ++index) {
      c[index] = 0.0f;
    }
    return 0;
  }
  if (a == NULL || b == NULL || c == NULL) {
    set_error(error_message, error_capacity,
        "non-empty GEMM received a null host pointer");
    return 1;
  }

  a_bytes = call.a_elements * sizeof(float);
  b_bytes = call.b_elements * sizeof(float);
  c_bytes = call.c_elements * sizeof(float);

  if (ctx != NULL) {
    handle = ctx->handle;
  } else {
    cublas_status = cublasCreate(&handle);
    if (cublas_status != CUBLAS_STATUS_SUCCESS) {
      return cublas_failure("cublasCreate", cublas_status,
          error_message, error_capacity);
    }
    own_handle = 1;
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

  cublas_status = enqueue_gemm(handle, &call, batch_count,
      a_rows, a_cols, b_rows, b_cols, c_rows, c_cols,
      device_a, device_b, device_c);
  if (cublas_status != CUBLAS_STATUS_SUCCESS) {
    cublas_failure(batch_count == 1 ? "cublasGemmEx" :
        "cublasGemmStridedBatchedEx", cublas_status,
        error_message, error_capacity);
    goto cleanup;
  }
  if (ctx != NULL) {
    cuda_status = cudaStreamSynchronize(ctx->stream);
  } else {
    cuda_status = cudaDeviceSynchronize();
  }
  if (cuda_status != cudaSuccess) {
    cuda_failure(ctx != NULL ? "cudaStreamSynchronize" : "cudaDeviceSynchronize",
        cuda_status, error_message, error_capacity);
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
  if (own_handle && handle != NULL) (void)cublasDestroy(handle);
  return result;
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
  return staged_gemm(NULL, numerics, trans_a, trans_b, batch_count,
      a_rows, a_cols, b_rows, b_cols, c_rows, c_cols, a, b, c,
      error_message, error_capacity);
}

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
    size_t error_capacity) {
  if (ctx == NULL) {
    set_error(error_message, error_capacity, "staged ctx GEMM: null context");
    return 1;
  }
  return staged_gemm(ctx, numerics, trans_a, trans_b, batch_count,
      a_rows, a_cols, b_rows, b_cols, c_rows, c_cols, a, b, c,
      error_message, error_capacity);
}

size_t ana_cuda_deviceptr_size(void) {
  return sizeof(void *);
}

int ana_cuda_malloc(
    uint64_t *out, size_t bytes, char *error_message, size_t error_capacity) {
  void *pointer = NULL;
  cudaError_t cuda_status;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  cuda_status = cudaMalloc(&pointer, bytes);
  if (cuda_status != cudaSuccess) {
    *out = 0;
    return cuda_failure("cudaMalloc", cuda_status, error_message, error_capacity);
  }
  *out = (uint64_t)(uintptr_t)pointer;
  return 0;
}

int ana_cuda_free(
    uint64_t device_pointer, char *error_message, size_t error_capacity) {
  cudaError_t cuda_status;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  cuda_status = cudaFree((void *)(uintptr_t)device_pointer);
  if (cuda_status != cudaSuccess) {
    return cuda_failure("cudaFree", cuda_status, error_message, error_capacity);
  }
  return 0;
}

int ana_cuda_memcpy_h2d(
    uint64_t device_destination, const void *host_source, size_t bytes,
    char *error_message, size_t error_capacity) {
  cudaError_t cuda_status;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  cuda_status = cudaMemcpy((void *)(uintptr_t)device_destination, host_source,
      bytes, cudaMemcpyHostToDevice);
  if (cuda_status != cudaSuccess) {
    return cuda_failure("cudaMemcpy(host-to-device)", cuda_status,
        error_message, error_capacity);
  }
  return 0;
}

int ana_cuda_memcpy_d2h(
    void *host_destination, uint64_t device_source, size_t bytes,
    char *error_message, size_t error_capacity) {
  cudaError_t cuda_status;

  if (error_message != NULL && error_capacity != 0) {
    error_message[0] = '\0';
  }
  cuda_status = cudaMemcpy(host_destination, (void *)(uintptr_t)device_source,
      bytes, cudaMemcpyDeviceToHost);
  if (cuda_status != cudaSuccess) {
    return cuda_failure("cudaMemcpy(device-to-host)", cuda_status,
        error_message, error_capacity);
  }
  return 0;
}
