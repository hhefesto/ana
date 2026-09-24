#!/usr/bin/env bash
# Gate G0 on a GPU box: Array.gemm from Bend against cuBLAS called directly.
# Expects in the working directory: bench.c conf.c (bend X.bend -o X.c from
# the ft-kernels fork), cublas_direct.c, conf.loop.txt is written here.
# Needs clang-19 and /usr/local/cuda. Prints a summary; exits 1 on a miss.
set -u
CU=/usr/local/cuda
CC="clang-19 -DBEND_CUDA=1 -I$CU/include -L$CU/lib64 -std=c11 -O3"
export LD_LIBRARY_PATH=$CU/lib64:${LD_LIBRARY_PATH:-}
$CC bench.c -lpthread -lm -o bench -lcuda -lnvrtc || exit 1
$CC conf.c -lpthread -lm -o conf -lcuda -lnvrtc || exit 1
clang-19 -O2 -I$CU/include -L$CU/lib64 cublas_direct.c -o cublas_direct -lcublas -lcudart || exit 1
nvidia-smi --query-gpu=name,driver_version,power.limit --format=csv,noheader
ok=1

echo "== conformance: cuBLAS against the loop (the loop equals the Bend definition bit for bit; checked locally)"
BEND_GEMM=loop ./conf > conf.loop.txt
for nm in fp32 tf32; do
  BEND_GEMM_NUMERICS=$nm BEND_PROFILE=2 ./conf > conf.$nm.txt 2> conf.$nm.prof
  tol=$([ $nm = fp32 ] && echo 1e-5 || echo 4e-3)
  # per case: max |gpu - loop| / max(1, max |loop|)
  paste -d'\n' conf.loop.txt conf.$nm.txt | awk -v tol=$tol -v nm=$nm '
    NR % 2 == 1 { name = $1; gsub(/[\[\],]/, " "); n = split($0, L, " "); next }
    { gsub(/[\[\],]/, " "); split($0, G, " "); mx = 1; e = 0
      for (i = 2; i <= n; i++) { d = G[i] - L[i]; if (d < 0) d = -d; if (d > e) e = d
        v = L[i] < 0 ? -L[i] : L[i]; if (v > mx) mx = v }
      r = e / mx; bad = r > tol
      printf "%-5s %-11s max err %.3g %s\n", nm, name, r, bad ? "MISS" : "ok"; if (bad) exit 1 }' || ok=0
  echo "   paths: $(grep -c 'gemm cublas' conf.$nm.prof) cublas, $(grep -c 'gemm loop' conf.$nm.prof) loop (wraps/overlaps/short ld/k=0 must be loop: 4)"
done

echo "== timing: median over calls 2..REPS (call 1 migrates the arrays)"
med() { sort -n | awk '{a[NR]=$1} END {print (NR%2 ? a[(NR+1)/2] : (a[NR/2]+a[NR/2+1])/2)}'; }
REPS=21
row() { # name M N K BATCH TA TB
  for nm in fp32 tf32; do
    b=$(M=$2 N=$3 K=$4 BATCH=$5 TA=$6 TB=$7 REPS=$REPS BEND_GEMM_NUMERICS=$nm BEND_PROFILE=2 ./bench 2>&1 >bench.out | grep 'gemm cublas' | tail -n +2 | awk '{print $(NF-3)}' | med)
    d=$(./cublas_direct $2 $3 $4 $5 $6 $7 $REPS $nm dev | grep '^call' | tail -n +2 | awk '{print $3}' | med)
    mg=$(./cublas_direct $2 $3 $4 $5 $6 $7 $REPS $nm managed | grep '^call' | tail -n +2 | awk '{print $3}' | med)
    fl=$(awk -v m=$2 -v n=$3 -v k=$4 -v b=$5 'BEGIN{print 2*m*n*k*b}')
    r=$(awk -v b="$b" -v d="$d" 'BEGIN{printf "%.3f", b/d}')
    printf "%-18s %-5s bend %8.3f ms  direct %8.3f ms  direct-managed %8.3f ms  bend/direct %s  %6.1f TFLOP/s  %s\n" \
      "$1" $nm "$b" "$d" "$mg" "$r" "$(awk -v f=$fl -v t=$b 'BEGIN{print f/t/1e9}')" "$(cat bench.out)"
    awk -v r=$r 'BEGIN{exit !(r > 1.05)}' && ok=0
  done
}
nvidia-smi dmon -s put -d 1 > dmon.txt 2>&1 &
DM=$!
row "16384x768.768x2048" 16384 2048 768 1 0 0
row "16384x768.768x32768" 16384 32768 768 1 0 1
row "batched 64^3 x3072" 64 64 64 3072 0 0
kill $DM
echo "== nvidia-smi dmon (power W, sm %, mem %, rxpci/txpci MB/s):"; cat dmon.txt
[ $ok = 1 ] && echo "G0: PASS" || { echo "G0: MISS"; exit 1; }
