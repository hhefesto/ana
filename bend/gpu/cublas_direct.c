// The G0 baseline: cuBLAS called directly on the shapes GemmBench.bend
// runs through Bend, row-major as ft_gemm calls it (Cᵀ = op(B)ᵀ·op(A)ᵀ),
// each call synchronized as ft_gemm v0 does, timed on the host wall clock.
//   cublas_direct M N K BATCH TA TB REPS NUMERICS(fp32|tf32|bf16) MEM(dev|managed)
// prints one line per call: "call i ms".
#include <cublas_v2.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1e3 + ts.tv_nsec / 1e6;
}

static float* buf(size_t n, int managed) {
  float* p = NULL;
  if ((managed ? cudaMallocManaged((void**)&p, n * 4, cudaMemAttachGlobal)
      : cudaMalloc((void**)&p, n * 4)) != cudaSuccess) {
    fprintf(stderr, "alloc failed\n");
    exit(1);
  }
  float* h = malloc(n * 4);
  for (size_t i = 0; i < n; i++) h[i] = 0.125f;
  cudaMemcpy(p, h, n * 4, cudaMemcpyDefault);
  free(h);
  return p;
}

int main(int argc, char** argv) {
  if (argc < 10) {
    fprintf(stderr, "usage: M N K BATCH TA TB REPS NUMERICS MEM\n");
    return 2;
  }
  int m = atoi(argv[1]), n = atoi(argv[2]), k = atoi(argv[3]);
  int nb = atoi(argv[4]), ta = atoi(argv[5]), tb = atoi(argv[6]);
  int reps = atoi(argv[7]);
  cublasComputeType_t ct = strcmp(argv[8], "tf32") == 0 ? CUBLAS_COMPUTE_32F_FAST_TF32
    : strcmp(argv[8], "bf16") == 0 ? CUBLAS_COMPUTE_32F_FAST_16BF : CUBLAS_COMPUTE_32F_PEDANTIC;
  int managed = strcmp(argv[9], "managed") == 0;
  float* a = buf((size_t)nb * m * k, managed);
  float* b = buf((size_t)nb * k * n, managed);
  float* c = buf((size_t)nb * m * n, managed);
  cublasHandle_t h;
  cudaStream_t st;
  cublasCreate(&h);
  cudaStreamCreateWithFlags(&st, cudaStreamNonBlocking);
  cublasSetStream(h, st);
  float al = 1.0f, be = 0.0f;
  int lda = ta ? m : k, ldb = tb ? k : n;
  for (int i = 0; i < reps; i++) {
    double t0 = now();
    cublasStatus_t s = cublasGemmStridedBatchedEx(h,
      tb ? CUBLAS_OP_T : CUBLAS_OP_N, ta ? CUBLAS_OP_T : CUBLAS_OP_N,
      n, m, k, &al, b, CUDA_R_32F, ldb, (long long)k * n,
      a, CUDA_R_32F, lda, (long long)m * k, &be, c, CUDA_R_32F, n,
      (long long)m * n, nb, ct, CUBLAS_GEMM_DEFAULT);
    cudaStreamSynchronize(st);
    printf("call %d %.3f ms%s\n", i, now() - t0, s ? " FAILED" : "");
  }
  float last;
  cudaMemcpy(&last, c + (size_t)nb * m * n - 1, 4, cudaMemcpyDefault);
  printf("C[last] = %g\n", last);
  return 0;
}
