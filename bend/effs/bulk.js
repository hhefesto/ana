// Bulk
// ====

// The JS twins of bulk.c: bk.gemm and bk.mm as Bulk.bend's loops (an
// Array<F32> is the host's own array of numbers, indices wrapping at its
// length; Math.fround keeps every step an F32 one), and the F32 file I/O.
// bk.einsum runs only in the C build.

function bk_at(t, o, ld, s, b, r, c) {
  return o + b * s + (t === 0 ? r * ld + c : c * ld + r);
}

function bk_loop(ta, tb, m, n, k, nb, alpha, a, ao, lda, sa, b, bo, ldb, sb,
  beta, c, co, ldc, sc) {
  const f = Math.fround;
  const al = f(alpha), be = f(beta);
  for (let bi = 0; bi < nb; bi += 1) {
    for (let i = 0; i < m; i += 1) {
      for (let j = 0; j < n; j += 1) {
        let s = 0;
        for (let q = 0; q < k; q += 1) {
          const x = a[(bk_at(ta, ao, lda, sa, bi, i, q) >>> 0) % a.length];
          const y = b[(bk_at(tb, bo, ldb, sb, bi, q, j) >>> 0) % b.length];
          s = f(s + f(x * y));
        }
        const ci = (bk_at(0, co, ldc, sc, bi, i, j) >>> 0) % c.length;
        const v = f(al * s);
        c[ci] = be === 0 ? v : f(v + f(be * c[ci]));
      }
    }
  }
}

function bk_gemm(ta, tb, m, n, k, nb, alpha, a, ao, lda, sa, b, bo, ldb, sb,
  beta, c, co, ldc, sc) {
  bk_loop(ta, tb, m, n, k, nb, alpha, a, ao, lda, sa, b, bo, ldb, sb, beta, c,
    co, ldc, sc);
  return io_tup(c, io_tup(a, b));
}

io_eff(CID(bk.gemm), bk_gemm);

// one array: A and B are read as they were before the op
function bk_mm(ta, tb, m, n, k, nb, alpha, ao, lda, sa, bo, ldb, sb, beta, co,
  ldc, sc, x) {
  const a = x.slice();
  bk_loop(ta, tb, m, n, k, nb, alpha, a, ao, lda, sa, a, bo, ldb, sb, beta, x,
    co, ldc, sc);
  return x;
}

io_eff(CID(bk.mm), bk_mm);

function bk_einsum(spec, x) {
  throw new Error("bk.einsum runs only in the C build");
}

io_eff(CID(bk.einsum), bk_einsum);

function bk_read_f32be(file, off, n, x, at) {
  const fs = require("fs");
  const k = Number(n);
  const b = Buffer.alloc(4 * k);
  let got = 0;
  try {
    while (got < 4 * k) {
      const r = fs.readSync(file, b, got, 4 * k - got, Number(off) + got);
      if (r === 0) {
        break;
      }
      got += r;
    }
  } catch (e) {
    return io_tup(file, io_tup(x, io_fail(Math.abs(e.errno ?? 5))));
  }
  for (let j = 0; j < Math.floor(got / 4); j += 1) {
    x[(Number(at) + j) % x.length] = b.readFloatBE(4 * j);
  }
  const r = got === 4 * k ? io_done({ $: CID(Unit) }) : io_fail(5);
  return io_tup(file, io_tup(x, r));
}

io_eff(CID(bk.read_f32be), bk_read_f32be);

function bk_write_f32be(file, n, x, at) {
  const fs = require("fs");
  const k = Number(n);
  const b = Buffer.alloc(4 * k);
  for (let j = 0; j < k; j += 1) {
    b.writeFloatBE(x[(Number(at) + j) % x.length], 4 * j);
  }
  try {
    let d = 0;
    while (d < b.length) {
      d += fs.writeSync(file, b, d, b.length - d, null);
    }
    return io_tup(file, io_tup(x, io_done({ $: CID(Unit) })));
  } catch (e) {
    return io_tup(file, io_tup(x, io_fail(Math.abs(e.errno ?? 5))));
  }
}

io_eff(CID(bk.write_f32be), bk_write_f32be);
