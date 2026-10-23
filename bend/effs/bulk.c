// Bulk
// ====

// The bulk F32 ops of bend/BulkIo.bend: bk.gemm, bk.mm and bk.einsum over
// Array<F32> stores, and big-endian F32 file I/O (bk.read_f32be,
// bk.write_f32be). Their meaning is bend/Bulk.bend's definitions; this is
// the code that was the Bend fork's (hhefesto/bend2, the Ft section of its
// C runtime and its effs/file_*_f32be.c) until 2026-10-22, now ana's own,
// on upstream Bend's foreign-effect interface. An Array<F32> is one block
// of 2^c u32 cells holding the F32 bits, and an effect gets the caller's
// block itself, so every op works in place, with no copy.
//
// A GPU build (upstream maps the heap to managed memory when the program
// has a bang and finds a GPU: io_gpu) hands gemms to cuBLAS and einsums to
// NVRTC kernels on that same memory; every effect waits for the device
// before it returns, so Bend code never sees a cell still being written.

#if BEND_CUDA
#include <dlfcn.h>
static _Atomic bool ft_busy;
static void ft_sync(void);
#define FT_WAIT() do { if (ft_busy) { ft_sync(); } } while (0)
#define ft_gpu io_gpu
#else
#define FT_WAIT()
#define ft_gpu false
#endif


// Each op is a def in Bulk.bend, and that def is its meaning: gemm is C ← α·op(A)·op(B) + β·C read through
// ArrayView.at, every index wrapped into its array. ft_gemm_loop is that
// definition in C, the same sums in the same order (fp contract is off),
// and it runs on every lane. A CUDA build whose program uses a bulk op
// hands a call to cuBLAS instead when its views fit: no index wraps and no
// two C entries share a cell, so the order of the writes cannot matter.

INLINE u32 ft_at(u32 t, u32 o, u32 ld, u32 s, u32 b, u32 r, u32 c) {
  return o + b * s + (t == 0 ? r * ld + c : c * ld + r);
}

INLINE DEV u32a* ft_cell(DEV u64* H, Term a, u32 i) {
  return blk_ptr(H, blk_loc(H, a), i & (u32)((1ull << blk_cls(a)) - 1));
}

INLINE f32 ft_get(DEV u64* H, Term a, u32 i) {
  return f32_unbox((u64)*ft_cell(H, a, i));
}

OUTLINE void ft_gemm_loop(Env e, u32 ta, u32 tb, u32 m, u32 n, u32 k,
  u32 nb, f32 alpha, Term a, u32 ao, u32 lda, u32 sa, Term b, u32 bo,
  u32 ldb, u32 sb, f32 beta, Term c, u32 co, u32 ldc, u32 sc) {
  DEV u64* H = e.mem;
  for (u32 bi = 0; bi < nb; bi += 1) {
    for (u32 i = 0; i < m; i += 1) {
      for (u32 j = 0; j < n; j += 1) {
        f32 s = 0.0f;
        for (u32 q = 0; q < k; q += 1) {
          f32 x = ft_get(H, a, ft_at(ta, ao, lda, sa, bi, i, q));
          f32 y = ft_get(H, b, ft_at(tb, bo, ldb, sb, bi, q, j));
          s = s + x * y;
        }
        DEV u32a* p = ft_cell(H, c, ft_at(0, co, ldc, sc, bi, i, j));
        f32 v = alpha * s;
        if (!(beta == 0.0f)) {
          v = v + beta * f32_unbox((u64)*p);
        }
        *p = (u32)f32_rewrap(v);
      }
    }
  }
}

#if !DEVICE && BEND_CUDA

typedef int (*FtGemmEx)(void*, int, int, int, int, int, const void*,
  const void*, int, int, long long, const void*, int, int, long long,
  const void*, void*, int, int, long long, int, int, int);

// Any worker thread may reach a bulk op: each call takes the lock and makes
// the primary context current on its thread.
static struct {
  int       state; // 0 untried, 1 ready, -1 unavailable
  pthread_mutex_t mu;
  CUcontext ctx;
  void*     h;
  CUstream  st;
  int      compute;
  FtGemmEx gemm;
  int      prof;
  u64      calls, loops, ecalls;
  double   ms, flop, ems;
} FT = { .mu = PTHREAD_MUTEX_INITIALIZER, .prof = -1 };

static void ft_sync(void) {
  if (FT.state > 0) {
    pthread_mutex_lock(&FT.mu);
    if (cuCtxSetCurrent(FT.ctx) != CUDA_SUCCESS
      || cuStreamSynchronize(FT.st) != CUDA_SUCCESS) {
      err_fail("device fault");
    }
    ft_busy = false;
    pthread_mutex_unlock(&FT.mu);
  }
}

// a launch: queued, or with BEND_PROFILE finished before it is timed
static bool ft_done(void) {
  if (FT.prof > 0) {
    return cuStreamSynchronize(FT.st) == CUDA_SUCCESS;
  }
  ft_busy = true;
  return true;
}

static void ft_report(void) {
  fprintf(stderr, "bend profile: gemm %llu calls (%llu as loops), %.3f ms,"
    " %.3f GFLOP, %.1f GFLOP/s\n", (unsigned long long)FT.calls,
    (unsigned long long)FT.loops, FT.ms, FT.flop / 1e9,
    FT.ms > 0 ? FT.flop / FT.ms / 1e6 : 0.0);
  fprintf(stderr, "bend profile: einsum %llu calls, %.3f ms\n",
    (unsigned long long)FT.ecalls, FT.ems);
}

// cuBLAS by dlopen: a build needs no cuBLAS headers, and a box without the
// library runs the loop. BEND_CUBLAS names the library;
// BEND_GEMM_NUMERICS is fp32 (the default), tf32 or bf16; BEND_GEMM=loop
// keeps every call on the loop (the oracle); BEND_PROFILE=1 sums the calls
// at exit, 2 also prints each one.
static bool ft_open(void) {
  if (FT.state != 0) {
    return FT.state > 0;
  }
  FT.state = -1;
  const char* g = getenv("BEND_GEMM");
  if (g != NULL && strcmp(g, "loop") == 0) {
    return false;
  }
  const char* nm = getenv("BEND_GEMM_NUMERICS");
  FT.compute = nm == NULL || strcmp(nm, "fp32") == 0 ? 69
    : strcmp(nm, "tf32") == 0 ? 77 : strcmp(nm, "bf16") == 0 ? 75 : 0;
  if (FT.compute == 0) {
    err_fail("BEND_GEMM_NUMERICS must be fp32, tf32 or bf16");
  }
  const char* so[] = { getenv("BEND_CUBLAS"), "libcublas.so",
    "libcublas.so.13", "libcublas.so.12", "libcublas.so.11" };
  void* lib = NULL;
  for (u32 i = 0; i < 5 && lib == NULL; i += 1) {
    lib = so[i] == NULL ? NULL : dlopen(so[i], RTLD_NOW | RTLD_GLOBAL);
  }
  int (*create)(void**) = lib ? (int (*)(void**))dlsym(lib,
    "cublasCreate_v2") : NULL;
  int (*stream)(void*, CUstream) = lib ? (int (*)(void*, CUstream))dlsym(lib,
    "cublasSetStream_v2") : NULL;
  FT.gemm = lib ? (FtGemmEx)dlsym(lib, "cublasGemmStridedBatchedEx") : NULL;
  if (create == NULL || stream == NULL || FT.gemm == NULL
    || cuDevicePrimaryCtxRetain(&FT.ctx, gpu_dev) != CUDA_SUCCESS
    || cuCtxSetCurrent(FT.ctx) != CUDA_SUCCESS
    || cuStreamCreate(&FT.st, CU_STREAM_NON_BLOCKING) != CUDA_SUCCESS
    || create(&FT.h) != 0 || stream(FT.h, FT.st) != 0) {
    fprintf(stderr, "bend: cuBLAS unavailable (%s); Array.gemm runs as a"
      " loop on the CPU\n", lib ? "setup failed" : dlerror());
    return false;
  }
  FT.state = 1;
  return true;
}

// BEND_PROFILE, read before the first call is timed
static int ft_prof(void) {
  if (FT.prof < 0) {
    const char* pr = getenv("BEND_PROFILE");
    FT.prof = pr == NULL ? 0 : atoi(pr) > 1 ? 2 : 1;
    if (FT.prof) {
      atexit(ft_report);
    }
  }
  return FT.prof;
}

static double ft_now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec * 1e3 + (double)ts.tv_nsec / 1e6;
}

// a view's stored matrices lie inside its array, without wrapping
static bool ft_fits(Term a, u64 rows, u64 cols, u64 o, u64 ld, u64 s,
  u64 nb) {
  u64 top = o + (nb - 1) * s + (rows - 1) * ld + (cols - 1);
  return ld >= cols && ld <= 0x7FFFFFFF && top < (1ull << blk_cls(a))
    && top < (1ull << 32);
}

#endif

// Cpu
// ===

// The bulk ops on the cores (no CUDA build, --gpu off, or a call the GPU
// declines). ft_gemm_loop and ft_einsum_loop are the definitions in C; the
// kernels here give every output the very same F32 steps in the same order
// (a sum runs in order of its index from 0, fp contract is off, no FMA),
// only many outputs at once: SIMD lanes and threads are distinct outputs.
// They read raw pointers when no index wraps and no two outputs share a
// cell; else the definitions run. BEND_FT=loop (or BEND_GEMM=loop) keeps
// every call on the definitions (the oracle); BEND_FT=c skips the AVX2
// kernels; BEND_FT_THREADS sets the kernels' threads (default --threads);
// BEND_PROFILE=1 sums the calls at exit, 2 also prints each one.

#if !DEVICE

#if defined(__x86_64__) || defined(__i386__)
#include <immintrin.h>
#define FT_X86     1
#define FT_AVX     __attribute__((target("avx2")))
#define FT_RELAX() _mm_pause()
#else
#define FT_X86     0
#define FT_RELAX() __asm__ __volatile__("" ::: "memory")
#endif
#define FT_FORCE static inline __attribute__((always_inline))
#define FT_MAXT  256

static long cpu_count(void);

static double ft_secs(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

// BEND_FT: 1 loop (the definitions), 2 c (no AVX2), 0 neither
static int ft_mode(void) {
  static _Atomic int mode = -1;
  int m = mode;
  if (m < 0) {
    const char* f = getenv("BEND_FT");
    const char* g = getenv("BEND_GEMM");
    m = (f != NULL && strcmp(f, "loop") == 0)
      || (g != NULL && strcmp(g, "loop") == 0) ? 1
      : f != NULL && strcmp(f, "c") == 0 ? 2 : 0;
    mode = m;
  }
  return m;
}

#define ft_ref() (ft_mode() == 1)

static bool ft_avx2(void) {
#if FT_X86
  static _Atomic int on = -1;
  int v = on;
  if (v < 0) {
    __builtin_cpu_init();
    v  = __builtin_cpu_supports("avx2") && ft_mode() != 2;
    on = v;
  }
  return v > 0;
#else
  return false;
#endif
}

// BEND_PROFILE on the cores (a CUDA build's GPU calls report as before)
static struct {
  pthread_mutex_t mu;
  _Atomic int     on;
  u64             calls, loops, ecalls, eloops;
  double          ms, flop, ems;
} FTS = { .mu = PTHREAD_MUTEX_INITIALIZER, .on = -1 };

static void ft_cpu_report(void) {
  fprintf(stderr, "bend profile: cpu gemm %llu calls (%llu as loops), %.3f"
    " ms, %.3f GFLOP, %.1f GFLOP/s\n", (unsigned long long)FTS.calls,
    (unsigned long long)FTS.loops, FTS.ms, FTS.flop / 1e9,
    FTS.ms > 0 ? FTS.flop / FTS.ms / 1e6 : 0.0);
  fprintf(stderr, "bend profile: cpu einsum %llu calls (%llu as loops),"
    " %.3f ms\n", (unsigned long long)FTS.ecalls,
    (unsigned long long)FTS.eloops, FTS.ems);
}

static int ft_cprof(void) {
  int on = FTS.on;
  if (on < 0) {
    pthread_mutex_lock(&FTS.mu);
    if (FTS.on < 0) {
      const char* p = getenv("BEND_PROFILE");
      FTS.on = p == NULL ? 0 : atoi(p) > 1 ? 2 : atoi(p) > 0 ? 1 : 0;
      if (FTS.on > 0) {
        atexit(ft_cpu_report);
      }
    }
    on = FTS.on;
    pthread_mutex_unlock(&FTS.mu);
  }
  return on;
}

// The kernels' threads: the caller and n - 1 workers, made at the first
// parallel call. A job is total items in chunks; a thread claims the
// next chunk by CAS on tick (job << 48 | chunks << 24 | next), and reads
// the job only once it holds a chunk, so a late thread cannot run a stale
// one. One job at a time (run, held by the caller for the whole op, also
// guards the per-thread scratch). Idle workers spin briefly, then sleep.

typedef void (*FtJob)(void* ctx, u64 lo, u64 hi, u32 tid);

static struct {
  pthread_mutex_t run;
  pthread_mutex_t mu;
  pthread_cond_t  cv;
  u32             n, up, sleep;
  _Atomic u32     gen;
  _Atomic u64     tick;
  _Atomic u64     done;
  u64             job, total, chunk;
  FtJob           fn;
  void*           ctx;
  void*           scr[FT_MAXT];
  u64             scrn[FT_MAXT];
} FTP = { .run = PTHREAD_MUTEX_INITIALIZER, .mu = PTHREAD_MUTEX_INITIALIZER,
  .cv = PTHREAD_COND_INITIALIZER };

// the threads a job may use (BEND_FT_THREADS, else --threads)
static u32 ft_threads(void) {
  if (FTP.n == 0) {
    const char* v = getenv("BEND_FT_THREADS");
    long        n = v != NULL ? atol(v) : 0;
    if (n < 1) {
      n = pool_size > 0 ? (long)pool_size : cpu_count();
    }
    FTP.n = n < 1 ? 1 : n > FT_MAXT ? FT_MAXT : (u32)n;
  }
  return FTP.n;
}

// a thread's scratch, 64-byte aligned (the caller holds FTP.run)
static void* ft_scratch(u32 tid, u64 bytes) {
  if (FTP.scrn[tid] < bytes) {
    void* p = NULL;
    free(FTP.scr[tid]);
    if (posix_memalign(&p, 64, bytes < 64 ? 64 : bytes) != 0) {
      err_fail("out of memory");
    }
    FTP.scr[tid]  = p;
    FTP.scrn[tid] = bytes;
  }
  return FTP.scr[tid];
}

static void ft_chunks(u32 tid) {
  for (;;) {
    u64 t  = atomic_load_explicit(&FTP.tick, memory_order_acquire);
    u64 nc = t >> 24 & 0xFFFFFF;
    u64 c  = t & 0xFFFFFF;
    if (c >= nc) {
      return;
    }
    if (!atomic_compare_exchange_weak_explicit(&FTP.tick, &t, t + 1,
        memory_order_acq_rel, memory_order_acquire)) {
      continue;
    }
    u64 lo = c * FTP.chunk;
    u64 hi = FTP.total - lo < FTP.chunk ? FTP.total : lo + FTP.chunk;
    FTP.fn(FTP.ctx, lo, hi, tid);
    atomic_fetch_add_explicit(&FTP.done, 1, memory_order_release);
  }
}

static void* ft_worker(void* arg) {
  u32 tid  = (u32)(uintptr_t)arg;
  u32 seen = 0;
  for (;;) {
    u32    g  = atomic_load_explicit(&FTP.gen, memory_order_acquire);
    double t0 = 0;
    for (u32 s = 1; g == seen; s += 1) {
      if ((s & 1023) == 0) {
        double now = ft_secs();
        t0 = t0 == 0 ? now : t0;
        if (now - t0 > 2e-4) {
          pthread_mutex_lock(&FTP.mu);
          FTP.sleep += 1;
          while ((g = atomic_load(&FTP.gen)) == seen) {
            pthread_cond_wait(&FTP.cv, &FTP.mu);
          }
          FTP.sleep -= 1;
          pthread_mutex_unlock(&FTP.mu);
          break;
        }
      }
      FT_RELAX();
      g = atomic_load_explicit(&FTP.gen, memory_order_acquire);
    }
    seen = g;
    ft_chunks(tid);
  }
  return NULL;
}

// runs fn over [0, total) in chunks, on every kernel thread; the caller
// holds FTP.run
static void ft_par(FtJob fn, void* ctx, u64 total, u64 chunk) {
  chunk = chunk < 1 ? 1 : chunk;
  if (total > chunk * 0xFFFFFF) {
    chunk = (total + 0xFFFFFE) / 0xFFFFFF;
  }
  u64 nc = (total + chunk - 1) / chunk;
  if (nc <= 1 || ft_threads() <= 1) {
    if (total > 0) {
      fn(ctx, 0, total, 0);
    }
    return;
  }
  if (!FTP.up) {
    FTP.up = 1;
    for (u32 w = 1; w < FTP.n; w += 1) {
      pthread_t t;
      if (pthread_create(&t, NULL, ft_worker, (void*)(uintptr_t)w) != 0) {
        FTP.n = w;
        break;
      }
      pthread_detach(t);
    }
  }
  FTP.fn    = fn;
  FTP.ctx   = ctx;
  FTP.total = total;
  FTP.chunk = chunk;
  FTP.job   = (FTP.job + 1) & 0xFFFF;
  atomic_store_explicit(&FTP.done, 0, memory_order_relaxed);
  atomic_store_explicit(&FTP.tick, FTP.job << 48 | nc << 24,
    memory_order_release);
  pthread_mutex_lock(&FTP.mu);
  atomic_fetch_add_explicit(&FTP.gen, 1, memory_order_release);
  if (FTP.sleep > 0) {
    pthread_cond_broadcast(&FTP.cv);
  }
  pthread_mutex_unlock(&FTP.mu);
  ft_chunks(0);
  for (u32 s = 1; atomic_load_explicit(&FTP.done, memory_order_acquire)
      != nc; s += 1) {
    if ((s & 4095) == 0) {
      sched_yield();
    } else {
      FT_RELAX();
    }
  }
}

// Gemm on the cores: C's columns go in panels of nr (16, or 32 for one
// row), each panel's op(B) packed as k rows of nr (zero past n; a
// row-major op(B) under at most 8 rows of C is read in place instead,
// each element being used about once), then blocks of up to 4 rows of C
// against it, each entry summed over q from 0 in one accumulator (a
// lane), α and β applied as the definition does. The units (batch,
// panel, block of mb rows) split across the threads.

typedef struct {
  const u32a* A;      // op(A)(i, q) = A[bi·sa + i·ais + q·aqs]
  const u32a* B;      // op(B)(q, j) = B[bi·sb + q·bqs + j·bjs]
  u32a*       C;      // C(i, j) = C[bi·sc + i·ldc + j]
  u64         ais, aqs, bqs, bjs, ldc, sa, sb, sc;
  u32         m, n, k, nb, nr, mb, njp, nib;
  f32         alpha, beta;
  bool        avx, direct; // direct: op(B) row-major and few rows of C
} FtG;

// a view's top index, when every index it reaches lies in its array
static bool ft_inside(Term a, u64 rows, u64 cols, u64 o, u64 ld, u64 s,
  u64 nb, u64* top) {
  u64 bs = (nb - 1) * s;
  u64 rs = (rows - 1) * ld;
  if (bs >= 1ull << 32 || rs >= 1ull << 32) {
    return false;
  }
  *top = o + bs + rs + (cols - 1);
  return *top < (1ull << blk_cls(a)) && *top < (1ull << 32);
}

// the panel of op(B) from column j0 (b points at its (0, j0))
static void ft_gpack_c(const FtG* g, f32* P, const u32a* b, u32 cols) {
  u32 nr = g->nr;
  for (u32 q = 0; q < g->k; q += 1) {
    const u32a* bq = b + q * g->bqs;
    f32*        pq = P + (u64)q * nr;
    for (u32 j = 0; j < nr; j += 1) {
      pq[j] = j < cols ? f32_unbox(bq[j * g->bjs]) : 0.0f;
    }
  }
}

FT_FORCE void ft_gk_c(const u32 R, const u32 NR, const f32* P, u64 pst,
  const u32a* a, u64 ais, u64 aqs, u32 k, f32* acc) {
  f32 s[4][32];
  for (u32 r = 0; r < R; r += 1) {
    for (u32 j = 0; j < NR; j += 1) {
      s[r][j] = 0.0f;
    }
  }
  for (u32 q = 0; q < k; q += 1) {
    const f32* pq = P + (u64)q * pst;
    for (u32 r = 0; r < R; r += 1) {
      f32 x = f32_unbox(a[r * ais + q * aqs]);
      for (u32 j = 0; j < NR; j += 1) {
        s[r][j] = s[r][j] + x * pq[j];
      }
    }
  }
  for (u32 r = 0; r < R; r += 1) {
    for (u32 j = 0; j < NR; j += 1) {
      acc[r * NR + j] = s[r][j];
    }
  }
}

static void ft_gkern_c(const FtG* g, const f32* P, u64 pst, const u32a* a, u32 R,
  f32* acc) {
  if (g->nr == 32) {
    ft_gk_c(1, 32, P, pst, a, g->ais, g->aqs, g->k, acc);
    return;
  }
  switch (R) {
    case 1:  ft_gk_c(1, 16, P, pst, a, g->ais, g->aqs, g->k, acc); break;
    case 2:  ft_gk_c(2, 16, P, pst, a, g->ais, g->aqs, g->k, acc); break;
    case 3:  ft_gk_c(3, 16, P, pst, a, g->ais, g->aqs, g->k, acc); break;
    default: ft_gk_c(4, 16, P, pst, a, g->ais, g->aqs, g->k, acc); break;
  }
}

#if FT_X86

// op(B) stored transposed (tb): 8×8 blocks transposed in registers
FT_AVX static void ft_gpack_avx(const FtG* g, f32* P, const u32a* b,
  u32 cols) {
  u32 nr = g->nr, k = g->k;
  if (g->bqs != 1 || cols != nr || k < 8) {
    ft_gpack_c(g, P, b, cols);
    return;
  }
  u64 ld = g->bjs;
  u32 k8 = k & ~7u;
  for (u32 j0 = 0; j0 < nr; j0 += 8) {
    const float* r = (const float*)(b + (u64)j0 * ld);
    for (u32 q = 0; q < k8; q += 8) {
      __m256 x0 = _mm256_loadu_ps(r + 0 * ld + q);
      __m256 x1 = _mm256_loadu_ps(r + 1 * ld + q);
      __m256 x2 = _mm256_loadu_ps(r + 2 * ld + q);
      __m256 x3 = _mm256_loadu_ps(r + 3 * ld + q);
      __m256 x4 = _mm256_loadu_ps(r + 4 * ld + q);
      __m256 x5 = _mm256_loadu_ps(r + 5 * ld + q);
      __m256 x6 = _mm256_loadu_ps(r + 6 * ld + q);
      __m256 x7 = _mm256_loadu_ps(r + 7 * ld + q);
      __m256 t0 = _mm256_unpacklo_ps(x0, x1);
      __m256 t1 = _mm256_unpackhi_ps(x0, x1);
      __m256 t2 = _mm256_unpacklo_ps(x2, x3);
      __m256 t3 = _mm256_unpackhi_ps(x2, x3);
      __m256 t4 = _mm256_unpacklo_ps(x4, x5);
      __m256 t5 = _mm256_unpackhi_ps(x4, x5);
      __m256 t6 = _mm256_unpacklo_ps(x6, x7);
      __m256 t7 = _mm256_unpackhi_ps(x6, x7);
      __m256 u0 = _mm256_shuffle_ps(t0, t2, 0x44);
      __m256 u1 = _mm256_shuffle_ps(t0, t2, 0xEE);
      __m256 u2 = _mm256_shuffle_ps(t1, t3, 0x44);
      __m256 u3 = _mm256_shuffle_ps(t1, t3, 0xEE);
      __m256 u4 = _mm256_shuffle_ps(t4, t6, 0x44);
      __m256 u5 = _mm256_shuffle_ps(t4, t6, 0xEE);
      __m256 u6 = _mm256_shuffle_ps(t5, t7, 0x44);
      __m256 u7 = _mm256_shuffle_ps(t5, t7, 0xEE);
      f32* p = P + (u64)q * nr + j0;
      _mm256_store_ps(p + 0 * nr, _mm256_permute2f128_ps(u0, u4, 0x20));
      _mm256_store_ps(p + 1 * nr, _mm256_permute2f128_ps(u1, u5, 0x20));
      _mm256_store_ps(p + 2 * nr, _mm256_permute2f128_ps(u2, u6, 0x20));
      _mm256_store_ps(p + 3 * nr, _mm256_permute2f128_ps(u3, u7, 0x20));
      _mm256_store_ps(p + 4 * nr, _mm256_permute2f128_ps(u0, u4, 0x31));
      _mm256_store_ps(p + 5 * nr, _mm256_permute2f128_ps(u1, u5, 0x31));
      _mm256_store_ps(p + 6 * nr, _mm256_permute2f128_ps(u2, u6, 0x31));
      _mm256_store_ps(p + 7 * nr, _mm256_permute2f128_ps(u3, u7, 0x31));
    }
  }
  for (u32 q = k8; q < k; q += 1) {
    for (u32 j = 0; j < nr; j += 1) {
      P[(u64)q * nr + j] = f32_unbox(b[j * ld + q]);
    }
  }
}

// R rows by NV vectors of 8 columns: s = s + x·y per lane, q ascending
FT_FORCE FT_AVX void ft_gk_avx(const u32 R, const u32 NV, const f32* P, u64 pst,
  const u32a* a, u64 ais, u64 aqs, u32 k, f32* acc) {
  __m256 s[4][4];
  for (u32 r = 0; r < R; r += 1) {
    for (u32 v = 0; v < NV; v += 1) {
      s[r][v] = _mm256_setzero_ps();
    }
  }
  for (u32 q = 0; q < k; q += 1) {
    const f32* pq = P + (u64)q * pst;
    __m256     y[4];
    for (u32 v = 0; v < NV; v += 1) {
      y[v] = _mm256_loadu_ps(pq + 8 * v);
    }
    for (u32 r = 0; r < R; r += 1) {
      __m256 x = _mm256_set1_ps(f32_unbox(a[r * ais + q * aqs]));
      for (u32 v = 0; v < NV; v += 1) {
        s[r][v] = _mm256_add_ps(s[r][v], _mm256_mul_ps(x, y[v]));
      }
    }
  }
  for (u32 r = 0; r < R; r += 1) {
    for (u32 v = 0; v < NV; v += 1) {
      _mm256_storeu_ps(acc + r * 8 * NV + 8 * v, s[r][v]);
    }
  }
}

FT_AVX static void ft_gkern_avx(const FtG* g, const f32* P, u64 pst, const u32a* a,
  u32 R, f32* acc) {
  if (g->nr == 32) {
    ft_gk_avx(1, 4, P, pst, a, g->ais, g->aqs, g->k, acc);
    return;
  }
  switch (R) {
    case 1:  ft_gk_avx(1, 2, P, pst, a, g->ais, g->aqs, g->k, acc); break;
    case 2:  ft_gk_avx(2, 2, P, pst, a, g->ais, g->aqs, g->k, acc); break;
    case 3:  ft_gk_avx(3, 2, P, pst, a, g->ais, g->aqs, g->k, acc); break;
    default: ft_gk_avx(4, 2, P, pst, a, g->ais, g->aqs, g->k, acc); break;
  }
}

#endif

// C ← α·s (+ β·C unless β is 0) over R rows and the panel's cols
static void ft_gput(const FtG* g, u32a* c, const f32* acc, u32 R,
  u32 cols) {
  for (u32 r = 0; r < R; r += 1) {
    u32a*      cr = c + r * g->ldc;
    const f32* ar = acc + r * g->nr;
    for (u32 j = 0; j < cols; j += 1) {
      f32 v = g->alpha * ar[j];
      if (!(g->beta == 0.0f)) {
        v = v + g->beta * f32_unbox(cr[j]);
      }
      cr[j] = (u32)f32_rewrap(v);
    }
  }
}

static void ft_gjob(void* ctx, u64 lo, u64 hi, u32 tid) {
  const FtG* g   = (const FtG*)ctx;
  u32        nr  = g->nr;
  f32*       P   = (f32*)ft_scratch(tid, ((u64)g->k * nr + 4 * 32) * 4);
  f32*       acc = P + (u64)g->k * nr;
  u64        per = (u64)g->njp * g->nib;
  u64        has = ~0ull;
  for (u64 u = lo; u < hi; u += 1) {
    u64 bi = u / per, w = u % per, jp = w / g->nib, ib = w % g->nib;
    u32         j0   = (u32)jp * nr;
    u32         cols = g->n - j0 < nr ? g->n - j0 : nr;
    const u32a* b    = g->B + bi * g->sb + (u64)j0 * g->bjs;
    const f32*  pan  = P;
    u64         pst  = nr;
    if (g->direct && cols == nr) {
      // op(B)'s rows are the panel's (read where they lie, unaligned)
      pan = (const f32*)b;
      pst = g->bqs;
    } else if (bi * g->njp + jp != has) {
      has = bi * g->njp + jp;
#if FT_X86
      if (g->avx) {
        ft_gpack_avx(g, P, b, cols);
      } else
#endif
      ft_gpack_c(g, P, b, cols);
    }
    u32 i0 = (u32)ib * g->mb;
    u32 i1 = g->m - i0 < g->mb ? g->m : i0 + g->mb;
    for (u32 i = i0; i < i1; i += 4) {
      u32         R = i1 - i < 4 ? i1 - i : 4;
      const u32a* a = g->A + bi * g->sa + (u64)i * g->ais;
#if FT_X86
      if (g->avx) {
        ft_gkern_avx(g, pan, pst, a, R, acc);
      } else
#endif
      ft_gkern_c(g, pan, pst, a, R, acc);
      ft_gput(g, g->C + bi * g->sc + (u64)i * g->ldc + j0, acc, R, cols);
    }
  }
}

// false when a view wraps or C's entries could share a cell (or overlap
// what A or B read): the definition runs instead
FAR bool ft_gemm_fast(Env e, u32 ta, u32 tb, u32 m, u32 n, u32 k, u32 nb,
  f32 al, Term a, u32 ao, u32 lda, u32 sa, Term b, u32 bo, u32 ldb, u32 sb,
  f32 be, Term c, u32 co, u32 ldc, u32 sc) {
  if (m == 0 || n == 0 || nb == 0) {
    return true;
  }
  u64 at = 0, bt = 0, ct = 0;
  if (!ft_inside(c, m, n, co, ldc, sc, nb, &ct)
    || (m > 1 && ldc < n)
    || (nb > 1 && (u64)sc < ((u64)m - 1) * ldc + n)) {
    return false;
  }
  if (k > 0 && (!ft_inside(a, ta ? k : m, ta ? m : k, ao, lda, sa, nb, &at)
    || !ft_inside(b, tb ? n : k, tb ? k : n, bo, ldb, sb, nb, &bt)
    || (term_loc(a) == term_loc(c) && ao <= ct && co <= at)
    || (term_loc(b) == term_loc(c) && bo <= ct && co <= bt))) {
    return false;
  }
  DEV u64* H = e.mem;
  FtG g;
  g.A     = ft_cell(H, a, ao);
  g.B     = ft_cell(H, b, bo);
  g.C     = ft_cell(H, c, co);
  g.ais   = ta ? 1 : lda;
  g.aqs   = ta ? lda : 1;
  g.bqs   = tb ? 1 : ldb;
  g.bjs   = tb ? ldb : 1;
  g.ldc   = ldc;
  g.sa    = sa;
  g.sb    = sb;
  g.sc    = sc;
  g.m     = m;
  g.n     = n;
  g.k     = k;
  g.nb    = nb;
  g.nr    = m == 1 ? 32 : 16;
  g.mb    = m < 64 ? m : 64;
  g.njp   = (n + g.nr - 1) / g.nr;
  g.nib   = (m + g.mb - 1) / g.mb;
  g.alpha = al;
  g.beta  = be;
  g.avx    = ft_avx2();
  g.direct = !tb && m <= 8;
  u64 units = (u64)nb * g.njp * g.nib;
  double work = (double)m * n * (k > 0 ? k : 1) * nb;
  pthread_mutex_lock(&FTP.run);
  u64 nt    = work < 65536.0 ? 1 : ft_threads();
  u64 chunk = nt <= 1 ? units : units / (nt * 4);
  ft_par(ft_gjob, &g, units, chunk);
  pthread_mutex_unlock(&FTP.run);
  return true;
}

static void ft_gemm_cpu(Env e, u32 ta, u32 tb, u32 m, u32 n, u32 k, u32 nb,
  f32 al, Term a, u32 ao, u32 lda, u32 sa, Term b, u32 bo, u32 ldb, u32 sb,
  f32 be, Term c, u32 co, u32 ldc, u32 sc) {
  int    prof = ft_gpu ? 0 : ft_cprof();
  double t0   = prof ? ft_secs() : 0;
  bool   fast = !ft_ref() && ft_gemm_fast(e, ta != 0, tb != 0, m, n, k, nb,
    al, a, ao, lda, sa, b, bo, ldb, sb, be, c, co, ldc, sc);
  if (!fast) {
    ft_gemm_loop(e, ta, tb, m, n, k, nb, al, a, ao, lda, sa, b, bo, ldb, sb,
      be, c, co, ldc, sc);
  }
  if (prof) {
    double ms   = (ft_secs() - t0) * 1e3;
    double flop = 2.0 * m * n * k * nb;
    pthread_mutex_lock(&FTS.mu);
    FTS.calls += 1;
    FTS.loops += !fast;
    FTS.ms    += ms;
    FTS.flop  += flop;
    pthread_mutex_unlock(&FTS.mu);
    if (prof > 1) {
      fprintf(stderr, "bend profile: cpu gemm %s %ux%ux%u x%u t%u%u %.3f ms"
        " %.1f GFLOP/s\n", fast ? "fast" : "loop", m, n, k, nb, ta != 0,
        tb != 0, ms, ms > 0 ? flop / ms / 1e6 : 0.0);
    }
  }
}

#endif

OUTLINE Term ft_gemm(Env e, u64 ta, u64 tb, u64 m, u64 n, u64 k, u64 nb,
  u64 alpha, Term a, u64 ao, u64 lda, u64 sa, Term b, u64 bo, u64 ldb,
  u64 sb, u64 beta, Term c, u64 co, u64 ldc, u64 sc) {
  u32 m_ = (u32)m, n_ = (u32)n, k_ = (u32)k, nb_ = (u32)nb;
  f32 al = f32_unbox(alpha), be = f32_unbox(beta);
#if !DEVICE && BEND_CUDA
  double t0 = ft_gpu && ft_prof() ? ft_now() : 0;
  u32 ta_ = (u32)ta != 0, tb_ = (u32)tb != 0;
  bool fast = ft_gpu && m_ > 0 && n_ > 0 && k_ > 0 && nb_ > 0
    && m_ <= 0x7FFFFFFF && n_ <= 0x7FFFFFFF && k_ <= 0x7FFFFFFF
    && ft_fits(a, ta_ ? k_ : m_, ta_ ? m_ : k_, (u32)ao, (u32)lda,
      (u32)sa, nb_)
    && ft_fits(b, tb_ ? n_ : k_, tb_ ? k_ : n_, (u32)bo, (u32)ldb,
      (u32)sb, nb_)
    && ft_fits(c, m_, n_, (u32)co, (u32)ldc, (u32)sc, nb_)
    && (nb_ == 1 || (u64)(u32)sc >= ((u64)m_ - 1) * (u32)ldc + n_);
  if (fast) {
    pthread_mutex_lock(&FT.mu);
    fast = ft_open() && cuCtxSetCurrent(FT.ctx) == CUDA_SUCCESS;
    if (!fast) {
      pthread_mutex_unlock(&FT.mu);
    }
  }
  if (fast) {
    DEV u64* H = e.mem;
    // row-major C = op(A)·op(B) is column-major Cᵀ = op(B)ᵀ·op(A)ᵀ
    int st = FT.gemm(FT.h, (int)tb_, (int)ta_, (int)n_, (int)m_, (int)k_,
      &al, (void*)ft_cell(H, b, (u32)bo), 0, (int)(u32)ldb,
      (long long)(u32)sb, (void*)ft_cell(H, a, (u32)ao), 0, (int)(u32)lda,
      (long long)(u32)sa, &be, (void*)ft_cell(H, c, (u32)co), 0,
      (int)(u32)ldc, (long long)(u32)sc, (int)nb_, FT.compute, -1);
    if (st != 0 || !ft_done()) {
      fprintf(stderr, "bend: cuBLAS gemm failed (status %d)\n", st);
      err_fail("device fault");
    }
    pthread_mutex_unlock(&FT.mu);
  } else {
    FT.loops += 1;
    FT_WAIT();
#endif
#if DEVICE
    ft_gemm_loop(e, (u32)ta, (u32)tb, m_, n_, k_, nb_, al, a, (u32)ao,
      (u32)lda, (u32)sa, b, (u32)bo, (u32)ldb, (u32)sb, be, c, (u32)co,
      (u32)ldc, (u32)sc);
#else
    ft_gemm_cpu(e, (u32)ta, (u32)tb, m_, n_, k_, nb_, al, a, (u32)ao,
      (u32)lda, (u32)sa, b, (u32)bo, (u32)ldb, (u32)sb, be, c, (u32)co,
      (u32)ldc, (u32)sc);
#endif
#if !DEVICE && BEND_CUDA
  }
  if (ft_gpu && FT.prof > 0) {
    double ms = ft_now() - t0;
    FT.calls += 1;
    FT.ms    += ms;
    FT.flop  += 2.0 * m_ * n_ * k_ * nb_;
    if (FT.prof > 1) {
      fprintf(stderr, "bend profile: gemm %s %ux%ux%u x%u %.3f ms %.1f"
        " GFLOP/s\n", fast ? "cublas" : "loop", m_, n_, k_, nb_, ms,
        2.0 * m_ * n_ * k_ * nb_ / ms / 1e6);
    }
  }
#endif
  return c;
}

// Einsum
// ======

// Array.einsum.prim runs an Es (base.bend) from its encoding. The loop is
// its definition in C: the same points, in the same order, with the same
// F32 steps (each libm call through double, as the C lane's F32 ops). A
// CUDA build with bulk ops compiles each distinct expression into a
// kernel (NVRTC, cached in memory and beside the binary) whose reductions
// run in another order: equal to the definition within rounding. As in
// the definition, every read (inputs, index views, the output's index
// view) sees the array as it was before the op, and the writes land in
// point order (acc adding to the cell as it is then). Both work on the
// array they write, so when a read may meet a write (ft_overlaps, or a
// gather or wrapped view the CPU lane cannot rule out) the points run
// one at a time with their writes held until every point is computed.
// The GPU takes only specs ft_overlaps clears (it does not scan a
// gather's or a scatter's targets: untested, no GPU here).

#define FT_MAXIN 8
#define FT_MAXEX 512

typedef struct {
  u32 off, st[6], ix, ioff, ist[6], imul;
} FtView;

typedef struct {
  u32 k;    // 0 input, 1 index, 2 const, 3 unary, 4 binary, 5 select
  u32 op;   // input/index number, or the op
  f32 c;
  int a, b, s;
} FtNode;

// ex last: a cached spec (ft_spec_get) keeps only its nex nodes
typedef struct {
  u32    n[6], red, op, acc, nin;
  FtView out, in[FT_MAXIN];
  u32    nex;
  const char* extext;
  FtNode ex[FT_MAXEX];
} FtSpec;

#if !DEVICE

static const char* ft_tok(const char** p) {
  while (**p == ' ') {
    *p += 1;
  }
  return *p;
}

static u32 ft_num(const char** p) {
  ft_tok(p);
  u64 v = 0;
  while (**p >= '0' && **p <= '9') {
    v = v * 10 + (u64)(**p - '0');
    *p += 1;
  }
  return (u32)v;
}

static void ft_view(const char** p, FtView* v) {
  v->off = ft_num(p);
  for (u32 k = 0; k < 6; k += 1) {
    v->st[k] = ft_num(p);
  }
  v->ix = ft_num(p);
  v->ioff = v->imul = 0;
  for (u32 k = 0; k < 6; k += 1) {
    v->ist[k] = 0;
  }
  if (v->ix) {
    v->ioff = ft_num(p);
    for (u32 k = 0; k < 6; k += 1) {
      v->ist[k] = ft_num(p);
    }
    v->imul = ft_num(p);
  }
}

static int ft_ex(const char** p, FtSpec* s) {
  ft_tok(p);
  if (s->nex >= FT_MAXEX) {
    err_fail("einsum: expression too large");
  }
  int     at = (int)s->nex++;
  FtNode* nd = &s->ex[at];
  char    c  = **p;
  *p += 1;
  nd->a = nd->b = nd->s = -1;
  nd->c = 0.0f;
  nd->op = ft_num(p);
  switch (c) {
    case 'i': nd->k = 0; break;
    case 'p': nd->k = 1; break;
    case 'k': nd->k = 2; nd->c = f32_unbox(nd->op); break;
    case 'u': nd->k = 3; nd->a = ft_ex(p, s); break;
    case 'b': nd->k = 4; nd->a = ft_ex(p, s); nd->b = ft_ex(p, s); break;
    case 's': {
      nd->k = 5;
      int x = ft_ex(p, s);
      int y = ft_ex(p, s);
      int z = ft_ex(p, s);
      s->ex[at].s = x;
      s->ex[at].a = y;
      s->ex[at].b = z;
      break;
    }
    default: err_fail("einsum: bad expression");
  }
  return at;
}

static void ft_parse(const char* t, FtSpec* s) {
  const char* p = t;
  if (*ft_tok(&p) != 'E') {
    err_fail("einsum: bad spec");
  }
  p += 1;
  for (u32 k = 0; k < 6; k += 1) {
    s->n[k] = ft_num(&p);
  }
  s->red = ft_num(&p) & 63;
  s->op  = ft_num(&p);
  s->acc = ft_num(&p);
  ft_view(&p, &s->out);
  s->nin = ft_num(&p);
  if (s->nin > FT_MAXIN) {
    err_fail("einsum: too many inputs");
  }
  for (u32 i = 0; i < s->nin; i += 1) {
    ft_view(&p, &s->in[i]);
  }
  s->nex = 0;
  s->extext = ft_tok(&p);
  ft_ex(&p, s);
}

static f32 ft_eval(const FtSpec* s, int at, const f32* v, const u32* pt) {
  const FtNode* nd = &s->ex[at];
  switch (nd->k) {
    case 0: return nd->op < s->nin ? v[nd->op] : 0.0f;
    case 1: return (f32)(nd->op < 6 ? pt[nd->op] : 0);
    case 2: return nd->c;
    case 3: {
      f32 x = ft_eval(s, nd->a, v, pt);
      switch (nd->op) {
        case 0: return -x;
        case 1: return (f32)exp(x);
        case 2: return (f32)log(x);
        case 3: return (f32)sqrt(x);
        default: return (f32)fabs(x);
      }
    }
    case 4: {
      f32 a = ft_eval(s, nd->a, v, pt);
      f32 b = ft_eval(s, nd->b, v, pt);
      switch (nd->op) {
        case 0: return a + b;
        case 1: return a - b;
        case 2: return a * b;
        case 3: return a / b;
        case 4: return a > b ? a : b;
        case 5: return a < b ? a : b;
        case 6: return a < b ? 1.0f : 0.0f;
        default: return a <= b ? 1.0f : 0.0f;
      }
    }
    default:
      return ft_eval(s, nd->s, v, pt) != 0.0f ? ft_eval(s, nd->a, v, pt)
        : ft_eval(s, nd->b, v, pt);
  }
}

INLINE u32 ft_vat(DEV u64* H, Term x, const FtView* v, const u32* p) {
  u32 a = v->off;
  for (u32 k = 0; k < 6; k += 1) {
    a += v->st[k] * p[k];
  }
  if (v->ix) {
    u32 i = v->ioff;
    for (u32 k = 0; k < 6; k += 1) {
      i += v->ist[k] * p[k];
    }
    a += v->imul * (u32)f32_to_u32((u64)*ft_cell(H, x, i));
  }
  return a;
}

// the flat index f as a point over the indices of sel, the last fastest
INLINE void ft_unflat(u64 f, const u32* n, u32 sel, u32* p) {
  for (int k = 5; k >= 0; k -= 1) {
    if (sel >> k & 1) {
      p[k] = (u32)(f % n[k]);
      f /= n[k];
    }
  }
}

static u64 ft_count(const u32* n, u32 sel) {
  u64 c = 1;
  for (u32 k = 0; k < 6; k += 1) {
    if (sel >> k & 1) {
      c *= n[k];
    }
  }
  return c;
}

// writes held to the end: the points' cells and values, in point order
static void* ft_alloc(u64 n);

static void ft_einsum_loop(Env e, const FtSpec* s, Term x) {
  DEV u64* H    = e.mem;
  u32    unr  = 63 & ~s->red;
  u64    nout = ft_count(s->n, unr);
  u64    nred = ft_count(s->n, s->red);
  f32    v[FT_MAXIN];
  u32*   dat  = ft_alloc(nout * sizeof(u32));
  f32*   dr   = ft_alloc(nout * sizeof(f32));
  for (u64 o = 0; o < nout; o += 1) {
    u32 p[6] = {0, 0, 0, 0, 0, 0};
    ft_unflat(o, s->n, unr, p);
    f32 r = s->op == 0 ? 0.0f : -INFINITY;
    for (u64 q = 0; q < nred; q += 1) {
      ft_unflat(q, s->n, s->red, p);
      for (u32 i = 0; i < s->nin; i += 1) {
        v[i] = ft_get(H, x, ft_vat(H, x, &s->in[i], p));
      }
      f32 t = ft_eval(s, 0, v, p);
      r = s->op == 0 ? r + t : t > r ? t : r;
    }
    for (u32 k = 0; k < 6; k += 1) {
      if (s->red >> k & 1) {
        p[k] = 0;
      }
    }
    dat[o] = ft_vat(H, x, &s->out, p);
    dr[o]  = r;
  }
  for (u64 o = 0; o < nout; o += 1) {
    DEV u32a* c = ft_cell(H, x, dat[o]);
    f32 w = s->acc ? f32_unbox((u64)*c) + dr[o] : dr[o];
    *c = (u32)f32_rewrap(w);
  }
  free(dat);
  free(dr);
}

// the lowest and highest index a direct view reaches (no wrap assumed)
static void ft_span(const FtView* v, const u32* n, u32 sel, u64* lo, u64* hi) {
  *lo = v->off;
  *hi = v->off;
  for (u32 k = 0; k < 6; k += 1) {
    if (sel >> k & 1 && n[k] > 0) {
      *hi += (u64)v->st[k] * (n[k] - 1);
    }
  }
}

static bool ft_same(const FtView* a, const FtView* b) {
  return !a->ix && !b->ix && a->off == b->off
    && memcmp(a->st, b->st, sizeof a->st) == 0;
}

// may a point read a cell another point writes? (spans as if no view
// wraps; a wrapping view, a gather's targets and a scattered output are
// ft_epar's to rule out). An input read at the very cell it writes, an
// elementwise update in place, is no overlap.
static bool ft_overlaps(const FtSpec* s) {
  if (s->out.ix) {
    return false;
  }
  u64 olo, ohi;
  ft_span(&s->out, s->n, 63 & ~s->red, &olo, &ohi);
  for (u32 i = 0; i < s->nin; i += 1) {
    const FtView* v = &s->in[i];
    u64 lo, hi;
    if (v->ix) {
      FtView iv = { v->ioff, { 0 }, 0, 0, { 0 }, 0 };
      memcpy(iv.st, v->ist, sizeof iv.st);
      ft_span(&iv, s->n, 63, &lo, &hi);
      if (lo <= ohi && olo <= hi) {
        return true;
      }
      continue;
    }
    ft_span(v, s->n, 63, &lo, &hi);
    if (lo <= ohi && olo <= hi && !(ft_same(v, &s->out) && s->red == 0)) {
      return true;
    }
  }
  return false;
}

#endif

#if !DEVICE && BEND_CUDA

// Kernels: one source per (expression, input count, reduced indices, op,
// acc, indirect output, strategy); sizes, offsets and strides are
// arguments. Strategies: 0 a thread per output (serial reduction), 1 a
// warp per output, 2 blocks over slices of each output's reduction, then a
// thread per output over the slices.

static const char* FT_KSRC = "typedef unsigned int u32;\n"
"struct V { u32 off; u32 st[6]; u32 ix; u32 ioff; u32 ist[6]; u32 imul; };\n"
"struct A { u32 n[6]; u32 nout; u32 nred; u32 m; u32 nsplit; V o; V in[NIN > 0 ? NIN : 1]; };\n"
"__device__ __forceinline__ u32 f2u(float v) { return v >= 0.0f && v < 4294967296.0f ? (u32)v : 0u; }\n"
"__device__ __forceinline__ float fmx(float a, float b) { return a > b ? a : b; }\n"
"__device__ __forceinline__ float fmn(float a, float b) { return a < b ? a : b; }\n"
"__device__ __forceinline__ float flt(float a, float b) { return a < b ? 1.0f : 0.0f; }\n"
"__device__ __forceinline__ float fle(float a, float b) { return a <= b ? 1.0f : 0.0f; }\n"
"__device__ __forceinline__ u32 at(const float* S, const V& v, const u32* p, u32 m) {\n"
"  u32 a = v.off;\n"
"  _Pragma(\"unroll\") for (int k = 0; k < 6; k++) a += v.st[k] * p[k];\n"
"  if (v.ix) { u32 i = v.ioff;\n"
"    _Pragma(\"unroll\") for (int k = 0; k < 6; k++) i += v.ist[k] * p[k];\n"
"    a += v.imul * f2u(S[i & m]); }\n"
"  return a & m;\n"
"}\n"
"__device__ __forceinline__ void unflat(u32 f, const u32* n, u32 sel, u32* p) {\n"
"  _Pragma(\"unroll\") for (int k = 5; k >= 0; k--) if (sel >> k & 1) { p[k] = f % n[k]; f /= n[k]; }\n"
"}\n"
"__device__ __forceinline__ float comb(float r, float t) { return OP == 0 ? r + t : (t > r ? t : r); }\n"
"__device__ __forceinline__ float term(const float* S, const A& a, const u32* p) {\n"
"LOADS  return EXPR;\n"
"}\n"
"__device__ __forceinline__ void put(float* S, const A& a, u32* p, float r) {\n"
"  _Pragma(\"unroll\") for (int k = 0; k < 6; k++) if (RED >> k & 1) p[k] = 0;\n"
"  u32 o = at(S, a.o, p, a.m);\n"
"  if (ACC && OIX) atomicAdd(&S[o], r); else if (ACC) S[o] = S[o] + r; else S[o] = r;\n"
"}\n"
"#define INIT (OP == 0 ? 0.0f : -__int_as_float(0x7f800000))\n"
"extern \"C\" __global__ void k0(float* S, A a) {\n"
"  for (u32 o = blockIdx.x * blockDim.x + threadIdx.x; o < a.nout; o += gridDim.x * blockDim.x) {\n"
"    u32 p[6] = {0, 0, 0, 0, 0, 0}; unflat(o, a.n, 63 & ~RED, p);\n"
"    float r = INIT;\n"
"    for (u32 q = 0; q < a.nred; q++) { unflat(q, a.n, RED, p); r = comb(r, term(S, a, p)); }\n"
"    put(S, a, p, r);\n"
"  }\n"
"}\n"
"extern \"C\" __global__ void k1(float* S, A a) {\n"
"  u32 lane = threadIdx.x & 31, w = (blockIdx.x * blockDim.x + threadIdx.x) >> 5, nw = (gridDim.x * blockDim.x) >> 5;\n"
"  for (u32 o = w; o < a.nout; o += nw) {\n"
"    u32 p[6] = {0, 0, 0, 0, 0, 0}; unflat(o, a.n, 63 & ~RED, p);\n"
"    float r = INIT;\n"
"    for (u32 q = lane; q < a.nred; q += 32) { unflat(q, a.n, RED, p); r = comb(r, term(S, a, p)); }\n"
"    _Pragma(\"unroll\") for (int s = 16; s > 0; s >>= 1) r = comb(r, __shfl_down_sync(0xffffffffu, r, s));\n"
"    if (lane == 0) put(S, a, p, r);\n"
"  }\n"
"}\n"
"extern \"C\" __global__ void k2(float* S, float* part, A a) {\n"
"  __shared__ float sh[32];\n"
"  u32 o = blockIdx.x / a.nsplit, sl = blockIdx.x % a.nsplit;\n"
"  u32 chunk = (a.nred + a.nsplit - 1) / a.nsplit, lo = sl * chunk, hi = min(a.nred, lo + chunk);\n"
"  u32 p[6] = {0, 0, 0, 0, 0, 0}; unflat(o, a.n, 63 & ~RED, p);\n"
"  float r = INIT;\n"
"  for (u32 q = lo + threadIdx.x; q < hi; q += blockDim.x) { unflat(q, a.n, RED, p); r = comb(r, term(S, a, p)); }\n"
"  _Pragma(\"unroll\") for (int s = 16; s > 0; s >>= 1) r = comb(r, __shfl_down_sync(0xffffffffu, r, s));\n"
"  if ((threadIdx.x & 31) == 0) sh[threadIdx.x >> 5] = r;\n"
"  __syncthreads();\n"
"  if (threadIdx.x < 32) {\n"
"    r = threadIdx.x < (blockDim.x >> 5) ? sh[threadIdx.x] : INIT;\n"
"    _Pragma(\"unroll\") for (int s = 16; s > 0; s >>= 1) r = comb(r, __shfl_down_sync(0xffffffffu, r, s));\n"
"    if (threadIdx.x == 0) part[blockIdx.x] = r;\n"
"  }\n"
"}\n"
"extern \"C\" __global__ void k3(float* S, const float* part, A a) {\n"
"  for (u32 o = blockIdx.x * blockDim.x + threadIdx.x; o < a.nout; o += gridDim.x * blockDim.x) {\n"
"    u32 p[6] = {0, 0, 0, 0, 0, 0}; unflat(o, a.n, 63 & ~RED, p);\n"
"    float r = INIT;\n"
"    for (u32 sl = 0; sl < a.nsplit; sl++) r = comb(r, part[o * a.nsplit + sl]);\n"
"    put(S, a, p, r);\n"
"  }\n"
"}\n";

typedef struct {
  u32    n[6], nout, nred, m, nsplit;
  FtView o, in[FT_MAXIN];
} FtArgs;

typedef struct FtKern {
  u64            key;
  CUfunction     f[4];
  struct FtKern* next;
} FtKern;

static FtKern*     FT_KERNS;
static CUdeviceptr FT_PART;
static u64         FT_PART_N;
static int         FT_ARCH;

// the expression as CUDA, into buf (returns the length written)
static u64 ft_cu(const FtSpec* s, int at, char* buf, u64 cap) {
  const FtNode* nd = &s->ex[at];
  u64 n = 0;
#define FT_P(...) n += (u64)snprintf(buf + n, n < cap ? cap - n : 0, __VA_ARGS__)
#define FT_E(i) n += ft_cu(s, (i), buf + (n < cap ? n : cap), n < cap ? cap - n : 0)
  switch (nd->k) {
    case 0: FT_P("x%u", nd->op); break;
    case 1: FT_P("((float)p[%u])", nd->op < 6 ? nd->op : 0); break;
    case 2: FT_P("__int_as_float(0x%08x)", (u32)f32_rewrap(nd->c)); break;
    case 3: {
      static const char* un[] = { "(-", "expf(", "logf(", "sqrtf(", "fabsf(" };
      FT_P("%s", un[nd->op < 5 ? nd->op : 4]);
      FT_E(nd->a);
      FT_P(")");
      break;
    }
    case 4: {
      static const char* in[] = { "+", "-", "*", "/" };
      static const char* fn[] = { "fmx(", "fmn(", "flt(", "fle(" };
      if (nd->op < 4) {
        FT_P("(");
        FT_E(nd->a);
        FT_P(" %s ", in[nd->op]);
        FT_E(nd->b);
        FT_P(")");
      } else {
        FT_P("%s", fn[nd->op < 8 ? nd->op - 4 : 3]);
        FT_E(nd->a);
        FT_P(", ");
        FT_E(nd->b);
        FT_P(")");
      }
      break;
    }
    default:
      FT_P("(");
      FT_E(nd->s);
      FT_P(" != 0.0f ? ");
      FT_E(nd->a);
      FT_P(" : ");
      FT_E(nd->b);
      FT_P(")");
  }
#undef FT_P
#undef FT_E
  return n;
}

static u64 ft_fnv(const char* p, u64 n, u64 h) {
  for (u64 i = 0; i < n; i += 1) {
    h = (h ^ (u8)p[i]) * 1099511628211ull;
  }
  return h;
}

static char* ft_source(const FtSpec* s, u64* len) {
  u64   cap = 1 << 16;
  char* src = malloc(cap);
  char* ex  = malloc(cap);
  if (src == NULL || ex == NULL) {
    err_fail("out of memory");
  }
  u64 ne = ft_cu(s, 0, ex, cap);
  if (ne >= cap) {
    err_fail("einsum: expression too large");
  }
  char loads[FT_MAXIN * 48 + 1] = { 0 };
  u64  nl = 0;
  for (u32 i = 0; i < s->nin; i += 1) {
    nl += (u64)snprintf(loads + nl, sizeof loads - nl,
      "  float x%u = S[at(S, a.in[%u], p, a.m)];\n", i, i);
  }
  u64 n = (u64)snprintf(src, cap, "#define NIN %u\n#define RED %uu\n"
    "#define OP %u\n#define ACC %u\n#define OIX %u\n#define EXPR %s\n",
    s->nin, s->red, s->op, s->acc != 0, s->out.ix != 0, ex);
  // LOADS goes in literally: splice it where the template names it
  const char* mark = "LOADS";
  const char* t    = strstr(FT_KSRC, mark);
  n += (u64)snprintf(src + n, cap - n, "%.*s%s%s", (int)(t - FT_KSRC),
    FT_KSRC, loads, t + strlen(mark));
  free(ex);
  if (n >= cap) {
    err_fail("einsum: kernel source too large");
  }
  *len = n;
  return src;
}

static void ft_dir(char* out, u64 cap) {
  const char* d = getenv("BEND_FT_CACHE");
  if (d != NULL) {
    snprintf(out, cap, "%s", d);
  } else {
    snprintf(out, cap, "%s", gpu_path());
    char* dot = strrchr(out, '.');
    if (dot != NULL) {
      snprintf(dot, cap - (u64)(dot - out), ".ftk");
    }
  }
  mkdir(out, 0755);
}

// a kernel's identity: its expression's text and the shape of its loop
static u64 ft_key(const FtSpec* s) {
  static u64 base = 0;
  if (base == 0) {
    base = ft_fnv(FT_KSRC, strlen(FT_KSRC), 14695981039346656037ull);
  }
  u64 h = ft_fnv(s->extext, strlen(s->extext), base);
  u64 f = ((u64)FT_ARCH << 32) | ((u64)s->nin << 16) | ((u64)s->red << 8)
    | ((u64)(s->op & 1) << 2) | ((u64)(s->acc != 0) << 1) | (s->out.ix != 0);
  return ft_fnv((const char*)&f, sizeof f, h);
}

static FtKern* ft_kern(const FtSpec* s) {
  u64 key = ft_key(s);
  for (FtKern* k = FT_KERNS; k != NULL; k = k->next) {
    if (k->key == key) {
      return k;
    }
  }
  u64   len = 0;
  char* src = ft_source(s, &len);
  char dir[1024];
  char path[1100];
  ft_dir(dir, sizeof dir);
  snprintf(path, sizeof path, "%s/%016llx.cubin", dir, (unsigned long long)key);
  CUmodule mod = NULL;
  FILE*    f   = fopen(path, "rb");
  if (f != NULL) {
    fseek(f, 0, SEEK_END);
    long  sz  = ftell(f);
    char* bin = sz > 0 ? malloc((u64)sz) : NULL;
    fseek(f, 0, SEEK_SET);
    if (bin == NULL || fread(bin, 1, (u64)sz, f) != (u64)sz
      || cuModuleLoadData(&mod, bin) != CUDA_SUCCESS) {
      mod = NULL;
    }
    free(bin);
    fclose(f);
  }
  if (mod == NULL) {
    char arch[40];
    snprintf(arch, sizeof arch, "--gpu-architecture=sm_%d", FT_ARCH);
    const char*  opts[] = { arch, "--fmad=false", "-std=c++14" };
    nvrtcProgram prog;
    if (nvrtcCreateProgram(&prog, src, "ft.cu", 0, NULL, NULL)
      != NVRTC_SUCCESS) {
      err_fail("einsum: cannot create the kernel program");
    }
    if (nvrtcCompileProgram(prog, 3, opts) != NVRTC_SUCCESS) {
      size_t n = 0;
      nvrtcGetProgramLogSize(prog, &n);
      char* log = calloc(n + 1, 1);
      if (log != NULL && nvrtcGetProgramLog(prog, log) == NVRTC_SUCCESS) {
        fprintf(stderr, "%s\n%s\n", src, log);
      }
      err_fail("einsum: cannot compile a kernel");
    }
    size_t bl = 0;
    nvrtcGetCUBINSize(prog, &bl);
    char* bin = malloc(bl);
    if (bin == NULL || nvrtcGetCUBIN(prog, bin) != NVRTC_SUCCESS
      || cuModuleLoadData(&mod, bin) != CUDA_SUCCESS) {
      err_fail("einsum: cannot load a kernel");
    }
    nvrtcDestroyProgram(&prog);
    f = fopen(path, "wb");
    if (f != NULL) {
      fwrite(bin, 1, bl, f);
      fclose(f);
    }
    free(bin);
  }
  free(src);
  FtKern* k = calloc(1, sizeof *k);
  if (k == NULL) {
    err_fail("out of memory");
  }
  k->key = key;
  const char* names[] = { "k0", "k1", "k2", "k3" };
  for (u32 i = 0; i < 4; i += 1) {
    if (cuModuleGetFunction(&k->f[i], mod, names[i]) != CUDA_SUCCESS) {
      err_fail("einsum: a kernel is missing");
    }
  }
  k->next  = FT_KERNS;
  FT_KERNS = k;
  return k;
}

// Strategy tuning: each (kernel, shape) tries its candidate strategies on
// its first occurrences, each timed alone, then keeps the fastest. Every
// strategy computes the same sum, so the choice is invisible but for
// rounding.
typedef struct FtTune {
  u64            key;
  u32            nout, nred, ncand, tried;
  int            cand[3], best;
  double         t[3];
  struct FtTune* next;
} FtTune;

static FtTune* FT_TUNES;

static FtTune* ft_tune(u64 key, u64 nout, u64 nred) {
  for (FtTune* t = FT_TUNES; t != NULL; t = t->next) {
    if (t->key == key && t->nout == nout && t->nred == nred) {
      return t;
    }
  }
  FtTune* t = calloc(1, sizeof *t);
  if (t == NULL) {
    err_fail("out of memory");
  }
  t->key  = key;
  t->nout = (u32)nout;
  t->nred = (u32)nred;
  t->best = -1;
  if (nred <= 1) {
    t->cand[0] = 0;
    t->ncand   = 1;
  } else if (nout >= 1024) {
    t->cand[0] = 0;
    t->cand[1] = 1;
    t->ncand   = 2;
  } else {
    t->cand[0] = 1;
    t->cand[1] = 2;
    t->ncand   = 2;
  }
  if (t->ncand == 1) {
    t->best = t->cand[0];
  }
  t->next  = FT_TUNES;
  FT_TUNES = t;
  return t;
}

static u32 ft_grid(u64 threads) {
  u64 b = (threads + 255) / 256;
  return (u32)(b < 1 ? 1 : b > (1u << 20) ? (1u << 20) : b);
}

static void ft_einsum_gpu(Env e, const FtSpec* s, Term x) {
  if (FT_ARCH == 0) {
    int cc[2] = { 0, 0 };
    cuDeviceGetAttribute(cc, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR,
      gpu_dev);
    cuDeviceGetAttribute(cc + 1, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR,
      gpu_dev);
    FT_ARCH = cc[0] * 10 + cc[1];
  }
  FtKern*  k = ft_kern(s);
  FtArgs   a;
  u32      unr  = 63 & ~s->red;
  u64      nout = ft_count(s->n, unr);
  u64      nred = ft_count(s->n, s->red);
  if (nout > 0xFFFFFFFFull || nred > 0xFFFFFFFFull) {
    err_fail("einsum: more than 2^32 points");
  }
  memcpy(a.n, s->n, sizeof a.n);
  a.nout = (u32)nout;
  a.nred = (u32)nred;
  a.m    = (u32)((1ull << blk_cls(x)) - 1);
  a.o    = s->out;
  memcpy(a.in, s->in, sizeof a.in);
  CUdeviceptr S = (CUdeviceptr)(uintptr_t)ft_cell(e.mem, x, 0);
  const char* st   = getenv("BEND_FT_STRAT");
  FtTune*     tu   = st != NULL ? NULL : ft_tune(k->key, nout, nred);
  bool        trial = tu != NULL && tu->best < 0;
  u32 strat = st != NULL ? (u32)atoi(st)
    : trial ? (u32)tu->cand[tu->tried] : (u32)tu->best;
  double t0 = 0;
  if (trial) {
    cuStreamSynchronize(FT.st);
    t0 = ft_now();
  }
  CUresult rc;
  if (strat == 2) {
    u64 want = (nred + 16383) / 16384;
    a.nsplit = (u32)(want < 1 ? 1 : want > 1024 ? 1024 : want);
    u64 np = nout * a.nsplit;
    if (np > FT_PART_N) {
      if (FT_PART != 0) {
        cuStreamSynchronize(FT.st);
        cuMemFree(FT_PART);
      }
      if (cuMemAlloc(&FT_PART, np * 4) != CUDA_SUCCESS) {
        err_fail("einsum: cannot allocate partials");
      }
      FT_PART_N = np;
    }
    void* a2[] = { &S, &FT_PART, &a };
    rc = cuLaunchKernel(k->f[2], (u32)np, 1, 1, 256, 1, 1, 0, FT.st, a2, NULL);
    if (rc == CUDA_SUCCESS) {
      rc = cuLaunchKernel(k->f[3], ft_grid(nout), 1, 1, 256, 1, 1, 0, FT.st,
        a2, NULL);
    }
  } else {
    a.nsplit = 1;
    void* a1[] = { &S, &a };
    rc = cuLaunchKernel(k->f[strat], ft_grid(strat == 1 ? nout * 32 : nout),
      1, 1, 256, 1, 1, 0, FT.st, a1, NULL);
  }
  if (rc != CUDA_SUCCESS || !ft_done()) {
    fprintf(stderr, "bend: einsum kernel failed (%d): %s\n", (int)rc,
      s->extext);
    err_fail("device fault");
  }
  if (trial) {
    cuStreamSynchronize(FT.st);
    tu->t[tu->tried] = ft_now() - t0;
    tu->tried += 1;
    if (tu->tried == tu->ncand) {
      u32 b = 0;
      for (u32 i = 1; i < tu->ncand; i += 1) {
        b = tu->t[i] < tu->t[b] ? i : b;
      }
      tu->best = tu->cand[b];
    }
  }
}

#endif

#if !DEVICE

// Einsum on the cores. Each distinct spec string is parsed and checked
// once (a table of FT_NCACHE entries by hash), and its expression compiled
// to steps over slots, each slot one F32 per element of a tile (P points
// by Q reduced points): a step is one op over the whole tile, so every
// element gets ft_eval's ops in ft_eval's order (a select computes both
// sides and keeps one; nothing has effects). Each point then reduces its Q
// values in order, as the loop does. Points run on many threads only when
// none can see another's write: a direct output reaching each cell once,
// every view inside the array (so ft_overlaps's spans are exact), and each
// gather's targets (scanned first) off the output. Else one point at a
// time, in the loop's order, each write held until all are computed (so
// every read sees the array as it was before the op).

typedef struct {
  u8  k, op; // k: 0 unary, 1 binary, 2 select
  uint16_t d, a, b, c;
} FtIns;

typedef struct {
  u64     h, len;
  char*   text;
  FtSpec* s;
  FtIns*  ins;
  f32*    cst;
  u32     nins, ncst, nslot, res, idx, refs, cost;
  bool    dead, ovl; // ovl: ft_overlaps
} FtEnt;

#define FT_NCACHE 4096
#define FT_TILE   256

static struct {
  pthread_mutex_t mu;
  FtEnt*          e[FT_NCACHE];
} FTC = { .mu = PTHREAD_MUTEX_INITIALIZER };

static u64 ft_hash(const char* p, u64 n) {
  u64 h = 14695981039346656037ull;
  for (u64 i = 0; i < n; i += 1) {
    h = (h ^ (u8)p[i]) * 1099511628211ull;
  }
  return h;
}

// operands while compiling: kind << 14 | number, the kind 0 an input, 1
// an index, 2 a constant, 3 a step's result
static uint16_t ft_kcst(FtEnt* en, f32 c) {
  u32 cb = (u32)f32_rewrap(c);
  for (u32 i = 0; i < en->ncst; i += 1) {
    if ((u32)f32_rewrap(en->cst[i]) == cb) {
      return (uint16_t)(2 << 14 | i);
    }
  }
  en->cst[en->ncst] = c;
  return (uint16_t)(2 << 14 | en->ncst++);
}

static uint16_t ft_comp(FtEnt* en, const FtSpec* s, int at) {
  const FtNode* nd = &s->ex[at];
  uint16_t a = 0, b = 0, c = 0;
  switch (nd->k) {
    case 0:
      return nd->op < s->nin ? (uint16_t)nd->op : ft_kcst(en, 0.0f);
    case 1:
      if (nd->op < 6) {
        en->idx |= 1u << nd->op;
        return (uint16_t)(1 << 14 | nd->op);
      }
      return ft_kcst(en, 0.0f);
    case 2:
      return ft_kcst(en, nd->c);
    case 3:
      a = ft_comp(en, s, nd->a);
      break;
    case 4:
      a = ft_comp(en, s, nd->a);
      b = ft_comp(en, s, nd->b);
      break;
    default:
      c = ft_comp(en, s, nd->s);
      a = ft_comp(en, s, nd->a);
      b = ft_comp(en, s, nd->b);
      break;
  }
  FtIns* in = &en->ins[en->nins];
  in->k  = nd->k == 3 ? 0 : nd->k == 4 ? 1 : 2;
  in->op = (u8)(nd->k == 3 ? (nd->op < 4 ? nd->op : 4)
    : nd->k == 4 ? (nd->op < 7 ? nd->op : 7) : 0);
  in->a  = a;
  in->b  = b;
  in->c  = c;
  in->d  = (uint16_t)(3 << 14 | en->nins);
  en->nins += 1;
  return in->d;
}

// slots: the inputs, the six indices, the constants, the steps
static uint16_t ft_slot(const FtEnt* en, uint16_t o) {
  u32 n = en->s->nin;
  switch (o >> 14) {
    case 0:  return o;
    case 1:  return (uint16_t)(n + (o & 0x3FFF));
    case 2:  return (uint16_t)(n + 6 + (o & 0x3FFF));
    default: return (uint16_t)(n + 6 + en->ncst + (o & 0x3FFF));
  }
}

static void* ft_alloc(u64 n) {
  void* p = malloc(n < 1 ? 1 : n);
  if (p == NULL) {
    err_fail("out of memory");
  }
  return p;
}

static FtEnt* ft_ent_new(const char* t, u64 len, u64 h) {
  FtSpec* full = ft_alloc(sizeof(FtSpec));
  ft_parse(t, full);
  u64    sz = __builtin_offsetof(FtSpec, ex) + (u64)full->nex * sizeof(FtNode);
  FtEnt* en = ft_alloc(sizeof(FtEnt));
  memset(en, 0, sizeof *en);
  en->ovl  = ft_overlaps(full);
  en->h    = h;
  en->len  = len;
  en->text = ft_alloc(len + 1);
  memcpy(en->text, t, len + 1);
  en->s    = ft_alloc(sz);
  memcpy(en->s, full, sz);
  en->s->extext = en->text + (full->extext - t);
  en->ins  = ft_alloc((u64)full->nex * sizeof(FtIns));
  en->cst  = ft_alloc((u64)full->nex * sizeof(f32));
  free(full);
  uint16_t r = ft_comp(en, en->s, 0);
  for (u32 i = 0; i < en->nins; i += 1) {
    FtIns* in = &en->ins[i];
    in->d = ft_slot(en, in->d);
    in->a = ft_slot(en, in->a);
    in->b = ft_slot(en, in->b);
    in->c = ft_slot(en, in->c);
  }
  en->res   = ft_slot(en, r);
  en->nslot = en->s->nin + 6 + en->ncst + en->nins;
  // rough ns per element, for when threads pay
  en->cost  = 2;
  for (u32 i = 0; i < en->s->nin; i += 1) {
    en->cost += en->s->in[i].ix ? 3 : 1;
  }
  for (u32 i = 0; i < en->nins; i += 1) {
    const FtIns* in = &en->ins[i];
    en->cost += in->k == 0 && (in->op == 1 || in->op == 2) ? 40
      : (in->k == 0 && in->op == 3) || (in->k == 1 && in->op == 3) ? 4 : 1;
  }
  return en;
}

static void ft_ent_free(FtEnt* en) {
  free(en->text);
  free(en->s);
  free(en->ins);
  free(en->cst);
  free(en);
}

// the spec's entry, held until ft_spec_put
static FtEnt* ft_spec_get(const char* t, u64 len) {
  u64     h  = ft_hash(t, len);
  FtEnt** at = &FTC.e[h & (FT_NCACHE - 1)];
  pthread_mutex_lock(&FTC.mu);
  FtEnt* en = *at;
  if (en != NULL && en->h == h && en->len == len
    && memcmp(en->text, t, len) == 0) {
    en->refs += 1;
    pthread_mutex_unlock(&FTC.mu);
    return en;
  }
  pthread_mutex_unlock(&FTC.mu);
  FtEnt* nw = ft_ent_new(t, len, h);
  nw->refs = 1;
  pthread_mutex_lock(&FTC.mu);
  FtEnt* old = *at;
  if (old != NULL && old->refs == 0) {
    ft_ent_free(old);
  } else if (old != NULL) {
    old->dead = true;
  }
  *at = nw;
  pthread_mutex_unlock(&FTC.mu);
  return nw;
}

static void ft_spec_put(FtEnt* en) {
  pthread_mutex_lock(&FTC.mu);
  en->refs -= 1;
  bool gone = en->dead && en->refs == 0;
  pthread_mutex_unlock(&FTC.mu);
  if (gone) {
    ft_ent_free(en);
  }
}

typedef struct {
  const FtSpec* s;
  const FtEnt*  en;
  u32a*         X;
  u32           mask, P, Q, pdim, rdim, gat;
  int           kp, kr; // the innermost unreduced and reduced index (or -1)
  u64           nred, olo, ohi;
  bool          scan, defer; // defer: writes to dat/dr, made after
  u32*          dat;
  f32*          dr;
  _Atomic u32   clash;
} FtE;

// a direct view's top index over the indices of sel (2^40 when past it)
static u64 ft_top(u32 off, const u32* st, const u32* n, u32 sel) {
  u64 hi = off;
  for (u32 k = 0; k < 6; k += 1) {
    if (sel >> k & 1 && n[k] > 0) {
      u64 t = (u64)st[k] * (n[k] - 1);
      if (t >= 1ull << 40) {
        return 1ull << 40;
      }
      hi += t;
    }
  }
  return hi < 1ull << 40 ? hi : 1ull << 40;
}

// may the points run in any order (a gather's targets still to scan)?
static bool ft_epar(FtE* E) {
  const FtSpec* s   = E->s;
  u64           N   = (u64)E->mask + 1;
  u32           unr = 63 & ~s->red;
  if (s->out.ix) {
    return false;
  }
  u64 ohi = ft_top(s->out.off, s->out.st, s->n, unr);
  if (ohi >= N) {
    return false;
  }
  // each output cell once: the strides, sorted, each past what the
  // smaller ones reach
  u64 st[6], cnt[6];
  u32 nd = 0;
  for (u32 k = 0; k < 6; k += 1) {
    if (unr >> k & 1 && s->n[k] > 1) {
      if (s->out.st[k] == 0) {
        return false;
      }
      u32 j = nd++;
      while (j > 0 && st[j - 1] > s->out.st[k]) {
        st[j]  = st[j - 1];
        cnt[j] = cnt[j - 1];
        j     -= 1;
      }
      st[j]  = s->out.st[k];
      cnt[j] = s->n[k];
    }
  }
  u64 reach = 0;
  for (u32 j = 0; j < nd; j += 1) {
    if (st[j] <= reach) {
      return false;
    }
    reach += st[j] * (cnt[j] - 1);
  }
  E->gat = 0;
  for (u32 i = 0; i < s->nin; i += 1) {
    const FtView* v = &s->in[i];
    if (!v->ix && ft_top(v->off, v->st, s->n, 63) >= N) {
      return false;
    }
    if (v->ix) {
      if (ft_top(v->ioff, v->ist, s->n, 63) >= N) {
        return false;
      }
      E->gat |= 1u << i;
    }
  }
  E->olo = s->out.off;
  E->ohi = ohi;
  return true;
}

// one step over the tile's ne elements (d is its own slot)
FT_FORCE void ft_estep(const FtIns* in, f32* sl, u32 T, u32 ne) {
  f32* restrict d = sl + (u64)in->d * T;
  const f32*    a = sl + (u64)in->a * T;
  const f32*    b = sl + (u64)in->b * T;
  const f32*    c = sl + (u64)in->c * T;
  if (in->k == 0) {
    switch (in->op) {
      case 0:
        for (u32 e = 0; e < ne; e += 1) d[e] = -a[e];
        break;
      case 1:
        for (u32 e = 0; e < ne; e += 1) d[e] = (f32)exp((double)a[e]);
        break;
      case 2:
        for (u32 e = 0; e < ne; e += 1) d[e] = (f32)log((double)a[e]);
        break;
      case 3:
        for (u32 e = 0; e < ne; e += 1) d[e] = (f32)sqrt((double)a[e]);
        break;
      default:
        for (u32 e = 0; e < ne; e += 1) d[e] = (f32)fabs((double)a[e]);
        break;
    }
  } else if (in->k == 1) {
    switch (in->op) {
      case 0:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] + b[e];
        break;
      case 1:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] - b[e];
        break;
      case 2:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] * b[e];
        break;
      case 3:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] / b[e];
        break;
      case 4:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] > b[e] ? a[e] : b[e];
        break;
      case 5:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] < b[e] ? a[e] : b[e];
        break;
      case 6:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] < b[e] ? 1.0f : 0.0f;
        break;
      default:
        for (u32 e = 0; e < ne; e += 1) d[e] = a[e] <= b[e] ? 1.0f : 0.0f;
        break;
    }
  } else {
    for (u32 e = 0; e < ne; e += 1) d[e] = c[e] != 0.0f ? a[e] : b[e];
  }
}

// the points [lo, hi) in tiles of up to P points along the innermost
// unreduced index (kp) by up to Q reduced points along the innermost
// reduced one (kr), so each index in a tile is affine, base + pp·ps +
// qq·qs (u32, the sums ft_vat makes), and is masked unless the run cannot
// pass the array's end. Counters over the other indices carry between
// tiles: no division per point.
FT_FORCE void ft_ebody(void* ctx, u64 lo, u64 hi, u32 tid) {
  FtE*          E    = (FtE*)ctx;
  const FtSpec* s    = E->s;
  const FtEnt*  en   = E->en;
  u32a*         X    = E->X;
  u32           mask = E->mask, nin = s->nin, P = E->P, Q = E->Q;
  u32           T    = P * Q, ns = 2 * nin + 2, unr = 63 & ~s->red;
  int           kp   = E->kp, kr = E->kr;
  f32*          sl   = (f32*)ft_scratch(tid, ((u64)en->nslot * T + P) * 4);
  f32*          r    = sl + (u64)en->nslot * T;
  for (u32 c = 0; c < en->ncst; c += 1) {
    f32* d = sl + (u64)(nin + 6 + c) * T;
    for (u32 e = 0; e < T; e += 1) {
      d[e] = en->cst[c];
    }
  }
  u32 dst[6][2 * FT_MAXIN + 2], sum[2 * FT_MAXIN + 2];
  u32 ps[2 * FT_MAXIN + 2], qs[2 * FT_MAXIN + 2];
  u32 p[6] = { 0, 0, 0, 0, 0, 0 };
  ft_unflat(lo, s->n, unr, p);
  for (u32 j = 0; j < ns; j += 1) {
    const FtView* v  = j < 2 * nin ? &s->in[j / 2] : &s->out;
    bool          ix = j & 1;
    sum[j] = ix ? v->ioff : v->off;
    for (u32 k = 0; k < 6; k += 1) {
      dst[k][j] = ix ? v->ist[k] : v->st[k];
      sum[j]   += dst[k][j] * p[k];
    }
    ps[j] = kp >= 0 ? dst[kp][j] : 0;
    qs[j] = kr >= 0 ? dst[kr][j] : 0;
  }
  u32 prow = kp >= 0 ? s->n[kp] : 1;
  u32 qrow = kr >= 0 ? s->n[kr] : 1;
  f32 init = s->op == 0 ? 0.0f : -INFINITY;
  for (u64 o = lo; o < hi;) {
    u32 pin = kp >= 0 ? p[kp] : 0;
    u32 np  = hi - o < P ? (u32)(hi - o) : P;
    np      = prow - pin < np ? prow - pin : np;
    for (u32 pp = 0; pp < np; pp += 1) {
      r[pp] = init;
    }
    u32 qp[6] = { 0, 0, 0, 0, 0, 0 };
    u32 rs[2 * FT_MAXIN];
    for (u32 j = 0; j < 2 * nin; j += 1) {
      rs[j] = 0;
    }
    for (u64 q0 = 0; q0 < E->nred;) {
      u32 qin = kr >= 0 ? qp[kr] : 0;
      u32 nq  = E->nred - q0 < Q ? (u32)(E->nred - q0) : Q;
      nq      = qrow - qin < nq ? qrow - qin : nq;
      // each input at element pp·nq + qq: X at its index, masked as ft_vat
      // and ft_get mask it (an index that cannot wrap reads directly)
      for (u32 i = 0; i < nin; i += 1) {
        const FtView* v  = &s->in[i];
        f32*          d  = sl + (u64)i * T;
        u32           b  = sum[2 * i] + rs[2 * i];
        u32           bp = ps[2 * i], bq = qs[2 * i];
        if (!v->ix) {
          u64 top = (u64)b + (u64)(np - 1) * bp + (u64)(nq - 1) * bq;
          if (E->scan) {
            continue;
          } else if (top <= mask && nq == 1) {
            const u32a* xb = X + b;
            if (bp == 1) {
              for (u32 pp = 0; pp < np; pp += 1) {
                d[pp] = f32_unbox(xb[pp]);
              }
            } else {
              for (u32 pp = 0; pp < np; pp += 1) {
                d[pp] = f32_unbox(xb[(u64)pp * bp]);
              }
            }
          } else if (top <= mask) {
            for (u32 pp = 0; pp < np; pp += 1) {
              const u32a* xr = X + b + (u64)pp * bp;
              f32*        dd = d + pp * nq;
              if (bq == 1) {
                for (u32 qq = 0; qq < nq; qq += 1) {
                  dd[qq] = f32_unbox(xr[qq]);
                }
              } else {
                for (u32 qq = 0; qq < nq; qq += 1) {
                  dd[qq] = f32_unbox(xr[(u64)qq * bq]);
                }
              }
            }
          } else {
            for (u32 pp = 0; pp < np; pp += 1) {
              for (u32 qq = 0; qq < nq; qq += 1) {
                d[pp * nq + qq] = f32_unbox(X[(b + pp * bp + qq * bq) & mask]);
              }
            }
          }
          continue;
        }
        u32 c  = sum[2 * i + 1] + rs[2 * i + 1];
        u32 cp = ps[2 * i + 1], cq = qs[2 * i + 1], mul = v->imul;
        for (u32 pp = 0; pp < np; pp += 1) {
          for (u32 qq = 0; qq < nq; qq += 1) {
            u32 ix = (c + pp * cp + qq * cq) & mask;
            u32 at = (b + pp * bp + qq * bq
              + mul * (u32)f32_to_u32(X[ix])) & mask;
            if (!E->scan) {
              d[pp * nq + qq] = f32_unbox(X[at]);
            } else if (at >= E->olo && at <= E->ohi) {
              atomic_store_explicit(&E->clash, 1, memory_order_relaxed);
            }
          }
        }
      }
      if (!E->scan) {
        for (u32 k = 0; k < 6; k += 1) {
          if (!(en->idx >> k & 1)) {
            continue;
          }
          f32* d   = sl + (u64)(nin + k) * T;
          bool red = s->red >> k & 1;
          for (u32 pp = 0; pp < np; pp += 1) {
            for (u32 qq = 0; qq < nq; qq += 1) {
              d[pp * nq + qq] = (f32)(red ? ((int)k == kr ? qin + qq : qp[k])
                : (int)k == kp ? pin + pp : p[k]);
            }
          }
        }
        u32 ne = np * nq;
        for (u32 t = 0; t < en->nins; t += 1) {
          ft_estep(&en->ins[t], sl, T, ne);
        }
        const f32* tv = sl + (u64)en->res * T;
        if (nq == 1 && s->op == 0) {
          for (u32 pp = 0; pp < np; pp += 1) {
            r[pp] = r[pp] + tv[pp];
          }
        } else if (nq == 1) {
          for (u32 pp = 0; pp < np; pp += 1) {
            r[pp] = tv[pp] > r[pp] ? tv[pp] : r[pp];
          }
        } else {
          for (u32 pp = 0; pp < np; pp += 1) {
            const f32* tt = tv + pp * nq;
            f32        rr = r[pp];
            if (s->op == 0) {
              for (u32 qq = 0; qq < nq; qq += 1) {
                rr = rr + tt[qq];
              }
            } else {
              for (u32 qq = 0; qq < nq; qq += 1) {
                rr = tt[qq] > rr ? tt[qq] : rr;
              }
            }
            r[pp] = rr;
          }
        }
      }
      // the next reduced points
      q0 += nq;
      if (kr >= 0) {
        qp[kr] += nq;
        for (u32 j = 0; j < 2 * nin; j += 1) {
          rs[j] += nq * qs[j];
        }
        if (qp[kr] == qrow) {
          qp[kr] = 0;
          for (u32 j = 0; j < 2 * nin; j += 1) {
            rs[j] -= qrow * qs[j];
          }
          for (int k = kr - 1; k >= 0; k -= 1) {
            if (!(E->rdim >> k & 1)) {
              continue;
            }
            qp[k] += 1;
            for (u32 j = 0; j < 2 * nin; j += 1) {
              rs[j] += dst[k][j];
            }
            if (qp[k] < s->n[k]) {
              break;
            }
            qp[k] = 0;
            for (u32 j = 0; j < 2 * nin; j += 1) {
              rs[j] -= dst[k][j] * s->n[k];
            }
          }
        }
      }
    }
    if (!E->scan) {
      u32 ob = sum[2 * nin], obp = ps[2 * nin];
      if (E->defer) {
        u32 oc = sum[2 * nin + 1], ocp = ps[2 * nin + 1];
        for (u32 pp = 0; pp < np; pp += 1) {
          u32 at = ob + pp * obp;
          if (s->out.ix) {
            at += s->out.imul * (u32)f32_to_u32(X[(oc + pp * ocp) & mask]);
          }
          E->dat[o + pp] = at & mask;
          E->dr[o + pp]  = r[pp];
        }
      } else if (!s->out.ix && obp == 1 && (u64)ob + np - 1 <= mask) {
        u32a* c = X + ob;
        if (s->acc) {
          for (u32 pp = 0; pp < np; pp += 1) {
            c[pp] = (u32)f32_rewrap(f32_unbox(c[pp]) + r[pp]);
          }
        } else {
          for (u32 pp = 0; pp < np; pp += 1) {
            c[pp] = (u32)f32_rewrap(r[pp]);
          }
        }
      } else {
        u32 oc = sum[2 * nin + 1], ocp = ps[2 * nin + 1];
        for (u32 pp = 0; pp < np; pp += 1) {
          u32 at = ob + pp * obp;
          if (s->out.ix) {
            at += s->out.imul * (u32)f32_to_u32(X[(oc + pp * ocp) & mask]);
          }
          u32a* c = X + (at & mask);
          f32   w = s->acc ? f32_unbox(*c) + r[pp] : r[pp];
          *c = (u32)f32_rewrap(w);
        }
      }
    }
    // the next points
    o += np;
    if (kp >= 0) {
      p[kp] += np;
      for (u32 j = 0; j < ns; j += 1) {
        sum[j] += np * ps[j];
      }
      if (p[kp] == prow) {
        p[kp] = 0;
        for (u32 j = 0; j < ns; j += 1) {
          sum[j] -= prow * ps[j];
        }
        for (int k = kp - 1; k >= 0; k -= 1) {
          if (!(E->pdim >> k & 1)) {
            continue;
          }
          p[k] += 1;
          for (u32 j = 0; j < ns; j += 1) {
            sum[j] += dst[k][j];
          }
          if (p[k] < s->n[k]) {
            break;
          }
          p[k] = 0;
          for (u32 j = 0; j < ns; j += 1) {
            sum[j] -= dst[k][j] * s->n[k];
          }
        }
      }
    }
  }
}

static void ft_ejob_c(void* ctx, u64 lo, u64 hi, u32 tid) {
  ft_ebody(ctx, lo, hi, tid);
}

#if FT_X86
FT_AVX static void ft_ejob_avx(void* ctx, u64 lo, u64 hi, u32 tid) {
  ft_ebody(ctx, lo, hi, tid);
}
#endif

FAR void ft_einsum_cpu(Env e, FtEnt* en, Term x) {
  const FtSpec* s    = en->s;
  int           prof = ft_gpu ? 0 : ft_cprof();
  double        t0   = prof ? ft_secs() : 0;
  u32           unr  = 63 & ~s->red;
  u64           nout = ft_count(s->n, unr);
  u64           nred = ft_count(s->n, s->red);
  int           how  = 0;
  if (ft_ref()) {
    ft_einsum_loop(e, s, x);
  } else if (nout > 0) {
    FtE E  = { .s = s, .en = en, .nred = nred, .kp = -1, .kr = -1 };
    E.X    = ft_cell(e.mem, x, 0);
    E.mask = (u32)((1ull << blk_cls(x)) - 1);
    for (u32 k = 0; k < 6; k += 1) {
      if (s->n[k] > 1 && s->red >> k & 1) {
        E.rdim |= 1u << k;
        E.kr    = (int)k;
      } else if (s->n[k] > 1) {
        E.pdim |= 1u << k;
        E.kp    = (int)k;
      }
    }
    FtJob job = ft_ejob_c;
#if FT_X86
    job = ft_avx2() ? ft_ejob_avx : ft_ejob_c;
#endif
    u32  qrow = E.kr >= 0 ? s->n[E.kr] : 1;
    bool par  = !en->ovl && ft_epar(&E);
    // threads only past about 30 µs of work (en->cost per element)
    double work = (double)nout * (double)(nred == 0 ? 1 : nred) * en->cost;
    pthread_mutex_lock(&FTP.run);
    u64 nt = work < 32768.0 ? 1 : ft_threads();
    E.Q    = qrow < FT_TILE ? qrow : FT_TILE;
    E.P    = FT_TILE / E.Q;
    u64 ch = nout / (nt * 8) > E.P ? nout / (nt * 8) : E.P;
    ch     = nt <= 1 ? nout : (ch + E.P - 1) / E.P * E.P;
    if (par && E.gat != 0) {
      E.scan = true;
      ft_par(job, &E, nout, ch);
      E.scan = false;
      par    = atomic_load(&E.clash) == 0;
    }
    if (!par) {
      E.P     = 1;
      ch      = nout;
      E.defer = true;
      E.dat   = ft_alloc(nout * sizeof(u32));
      E.dr    = ft_alloc(nout * sizeof(f32));
    }
    ft_par(job, &E, nout, ch);
    pthread_mutex_unlock(&FTP.run);
    // the held writes, in point order, on the cells as they are by then
    if (E.defer) {
      for (u64 o = 0; o < nout; o += 1) {
        u32a* c = E.X + E.dat[o];
        f32   w = s->acc ? f32_unbox(*c) + E.dr[o] : E.dr[o];
        *c = (u32)f32_rewrap(w);
      }
      free(E.dat);
      free(E.dr);
    }
    how = par ? 2 : 1;
  }
  if (prof) {
    double ms = (ft_secs() - t0) * 1e3;
    pthread_mutex_lock(&FTS.mu);
    FTS.ecalls += 1;
    FTS.eloops += how == 0;
    FTS.ems    += ms;
    pthread_mutex_unlock(&FTS.mu);
    if (prof > 1) {
      fprintf(stderr, "bend profile: cpu einsum %s %llux%llu %.3f ms %.60s\n",
        how == 2 ? "par" : how == 1 ? "serial" : "loop",
        (unsigned long long)nout, (unsigned long long)nred, ms, s->extext);
    }
  }
}

#endif

OUTLINE Term ft_einsum(Env e, Term spec, Term x) {
#if DEVICE
  term_sink(e, spec);
  err_post(e.mem, ERR_TAGS);
  return x;
#else
  u64     n  = 0;
  char*   t  = io_cbuf(e, spec, &n, CID(SCon));
  FtEnt*  en = ft_spec_get(t, n);
  FtSpec* s  = en->s;
  free(t);
#if BEND_CUDA
  double t0 = ft_gpu && ft_prof() ? ft_now() : 0;
  bool   fast = false;
  if (ft_gpu && !en->ovl) {
    pthread_mutex_lock(&FT.mu);
    fast = ft_open() && cuCtxSetCurrent(FT.ctx) == CUDA_SUCCESS;
    if (fast) {
      ft_einsum_gpu(e, s, x);
    }
    pthread_mutex_unlock(&FT.mu);
  }
  if (!fast) {
    FT_WAIT();
    ft_einsum_cpu(e, en, x);
  }
  // BEND_FT_DUMP=dir writes each kernel's source there (to check offline)
  const char* dump = getenv("BEND_FT_DUMP");
  if (dump != NULL) {
    u64   len = 0;
    char* src = ft_source(s, &len);
    char  path[1100];
    snprintf(path, sizeof path, "%s/%016llx.cu", dump,
      (unsigned long long)ft_fnv(src, len, 14695981039346656037ull));
    FILE* f = fopen(path, "w");
    if (f != NULL) {
      fwrite(src, 1, len, f);
      fclose(f);
    }
    free(src);
  }
  if (ft_gpu && FT.prof > 0) {
    double ms = ft_now() - t0;
    FT.ecalls += 1;
    FT.ems    += ms;
    if (FT.prof > 1) {
      fprintf(stderr, "bend profile: einsum %s %.3f ms %.60s\n",
        fast ? "kernel" : "loop", ms, s->extext);
    }
  }
#else
  (void)s;
  ft_einsum_cpu(e, en, x);
#endif
  ft_spec_put(en);
  return x;
#endif
}

// Array.mm: the gemm with A, B and C in one array
OUTLINE Term ft_mm(Env e, u64 ta, u64 tb, u64 m, u64 n, u64 k, u64 nb,
  u64 alpha, u64 ao, u64 lda, u64 sa, u64 bo, u64 ldb, u64 sb, u64 beta,
  u64 co, u64 ldc, u64 sc, Term x) {
#if !DEVICE
  // C's rectangle against A's and B's (no wrap assumed)
  u64 cm = (u32)m, cn = (u32)n, ck = (u32)k, cb = (u32)nb;
  if (cm > 0 && cn > 0 && ck > 0 && cb > 0) {
    u64 clo = (u32)co, chi = clo + (cb - 1) * (u32)sc + (cm - 1) * (u32)ldc
      + cn - 1;
    u64 ar = (u32)ta ? ck : cm, ac = (u32)ta ? cm : ck;
    u64 br = (u32)tb ? cn : ck, bc = (u32)tb ? ck : cn;
    u64 alo = (u32)ao, ahi = alo + (cb - 1) * (u32)sa + (ar - 1) * (u32)lda
      + ac - 1;
    u64 blo = (u32)bo, bhi = blo + (cb - 1) * (u32)sb + (br - 1) * (u32)ldb
      + bc - 1;
    if ((alo <= chi && clo <= ahi) || (blo <= chi && clo <= bhi)) {
      err_fail("Array.mm: C overlaps A or B");
    }
  }
#endif
  return ft_gemm(e, ta, tb, m, n, k, nb, alpha, x, ao, lda, sa, x, bo, ldb,
    sb, beta, x, co, ldc, sc);
}


// Effects
// =======

// Each wrapper is its def in BulkIo.bend: the arguments in order, the
// arrays handed back (bk.gemm's as (C, A, B)), after the device is done.

#ifdef CID(bk.gemm)

Term bk_gemm_run(Env e, Term* f, IoWork* w) {
  Term c = ft_gemm(e, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8],
    f[9], f[10], f[11], f[12], f[13], f[14], f[15], f[16], f[17], f[18],
    f[19]);
  FT_WAIT();
  return io_tup(e, c, io_tup(e, f[7], f[11]));
}

static void __attribute__((constructor)) bk_gemm_use(void) {
  io_eff(CID(bk.gemm), bk_gemm_run);
}

#endif

#ifdef CID(bk.mm)

Term bk_mm_run(Env e, Term* f, IoWork* w) {
  Term x = ft_mm(e, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8],
    f[9], f[10], f[11], f[12], f[13], f[14], f[15], f[16], f[17]);
  FT_WAIT();
  return x;
}

static void __attribute__((constructor)) bk_mm_use(void) {
  io_eff(CID(bk.mm), bk_mm_run);
}

#endif

#ifdef CID(bk.einsum)

Term bk_einsum_run(Env e, Term* f, IoWork* w) {
  Term x = ft_einsum(e, f[0], f[1]);
  FT_WAIT();
  return x;
}

static void __attribute__((constructor)) bk_einsum_use(void) {
  io_eff(CID(bk.einsum), bk_einsum_run);
}

#endif

#ifdef CID(bk.read_f32be)

// n big-endian f32 at byte off of the file, into x[at], x[at+1], ...
// (indices wrap, as Array.set's do), read with pread so the file's own
// position stays; the array is written in place, so no F32 is ever a
// Bend term on the way. A short read is EIO; the cells past it keep
// their values.
Term bk_read_f32be_run(Env e, Term* f, IoWork* w) {
  int  fd  = (int)io_hand_v(f[0]);
  u64  off = (u64)(u32)f[1];
  u64  n   = (u64)(u32)f[2];
  Term x   = f[3];
  u32  at  = (u32)f[4];
  u32  code = 0;
  FT_WAIT();
  enum { CH = 1 << 20 };
  uint8_t* b = io_mem(malloc(4 * (size_t)CH));
  for (u64 i = 0; i < n && code == 0;) {
    u64     k = n - i < CH ? n - i : CH;
    ssize_t r = pread(fd, b, 4 * k, (off_t)(off + 4 * i));
    if (r < 0) {
      code = (u32)errno;
    } else if ((u64)r != 4 * k) {
      code = EIO;
    } else {
      for (u64 j = 0; j < k; j += 1) {
        const uint8_t* p = b + 4 * j;
        *ft_cell(e.mem, x, at + (u32)(i + j)) = ((u32)p[0] << 24)
          | ((u32)p[1] << 16) | ((u32)p[2] << 8) | (u32)p[3];
      }
      i += k;
    }
  }
  free(b);
  Term r = code != 0 ? io_fail(e, code, NULL)
    : io_done(e, term_pak(CID(Unit), 0));
  return io_tup(e, io_hand(io_hand_v(f[0])), io_tup(e, x, r));
}

static void __attribute__((constructor)) bk_read_f32be_use(void) {
  io_eff(CID(bk.read_f32be), bk_read_f32be_run);
}

#endif

#ifdef CID(bk.write_f32be)

// x[at], ..., x[at+n-1] (indices wrap) as big-endian f32, written at the
// file's position, the array handed back unchanged.
Term bk_write_f32be_run(Env e, Term* f, IoWork* w) {
  int  fd = (int)io_hand_v(f[0]);
  u64  n  = (u64)(u32)f[1];
  Term x  = f[2];
  u32  at = (u32)f[3];
  u32  code = 0;
  FT_WAIT();
  enum { CH = 1 << 20 };
  uint8_t* b = io_mem(malloc(4 * (size_t)CH));
  for (u64 i = 0; i < n && code == 0;) {
    u64 k = n - i < CH ? n - i : CH;
    for (u64 j = 0; j < k; j += 1) {
      u32      v = (u32)*ft_cell(e.mem, x, at + (u32)(i + j));
      uint8_t* p = b + 4 * j;
      p[0] = (uint8_t)(v >> 24);
      p[1] = (uint8_t)(v >> 16);
      p[2] = (uint8_t)(v >> 8);
      p[3] = (uint8_t)v;
    }
    for (u64 d = 0; d < 4 * k && code == 0;) {
      ssize_t r = write(fd, b + d, 4 * k - d);
      if (r < 0) {
        code = (u32)errno;
      } else {
        d += (u64)r;
      }
    }
    i += k;
  }
  free(b);
  Term r = code != 0 ? io_fail(e, code, NULL)
    : io_done(e, term_pak(CID(Unit), 0));
  return io_tup(e, io_hand(io_hand_v(f[0])), io_tup(e, x, r));
}

static void __attribute__((constructor)) bk_write_f32be_use(void) {
  io_eff(CID(bk.write_f32be), bk_write_f32be_run);
}

#endif
