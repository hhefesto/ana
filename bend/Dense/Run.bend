import Base
import ../BulkIo.bend as BI
import ./Op.bend as P

# The dense model's programs run fast: each op as its BulkIo.bend effect
# (bend/effs/bulk.c), whose meaning is Op.bend's P.Op.run, the same F32
# bits. The trainers and the decoders run their programs here, in IO; the
# specs reason about P.run. (Until 2026-10-22 P.run itself was fast: the
# Bend fork compiled its base.bend primitives to the C kernels.)

# The GPU. Upstream's runtime maps the heap to the GPU's managed memory, the
# memory bend/effs/bulk.c's cuBLAS calls and kernels work on (its ft_gpu is
# io_gpu), only in a program with a bang. With `#define BANGS 0` in its C,
# `+RTS --gpu 48GB` is ignored without a word and the program trains on the
# CPU. The fork's FTOPS did this for a program with bulk ops; upstream has no
# such thing, and from 97ca093 (2026-10-22) until this bang the trainer could
# not have reached a GPU. So a program meant for a GPU starts with gpu.on():
# one call, one lane, and a GPU that cannot run it stops the program at its
# start. `bend-ops stage box` refuses a C with no bang (Box/Stage.bend).
def gpu.one(x: U32) -> U32:
  x

def gpu.on() -> IO(Unit):
  do IO<Unit>:
    y : U32 <- IO.pure(U32, gpu.one!(0))
    IO.pure(Unit, Unit{})

# Ops queued (BulkIo.bend's bk.mm.q, bk.einsum.q, bk.einsum.seq.q): on a
# GPU each returns before the device is done, so only run.q chains them,
# and only run answers their store, after bk.sync. Until 2026-11-18 every op
# waited for the device (run 6: 33,600 ops a step, each a launch, a wait
# and a return through the IO loop, the GPU idle in between: SM busy
# 60-87%).

# a product or an einsum, queued (a Seq's slices are einsums)
def Op.flat.q(op: P.Op, s: Array<F32>) -> IO(Array<F32>):
  match op:
    case P.Mm{ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc}:
      BI.bk.mm.q(ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s)
    case P.Ein{es, spec, g}:
      BI.bk.einsum.q(spec, s)
    case P.Seq{es, k, rev, c, spec, sl, g}:
      IO.pure(Array<F32>, s)

def run.flat.q(ops: List<&2, P.Op>, s: Array<F32>) -> IO(Array<F32>):
  match ops:
    case Nil{}:
      IO.pure(Array<F32>, s)
    case op <> t:
      IO.bind(Array<F32>, Array<F32>, Op.flat.q(op, s), (x: Array<F32>) => run.flat.q(t, x))

# a Seq: one GPU kernel (answer 1), or else its slices, one einsum each
def seq.if(done: Bool, sl: List<&2, P.Op>, x: Array<F32>) -> IO(Array<F32>):
  match done:
    case True{}:
      IO.pure(Array<F32>, x)
    case False{}:
      run.flat.q(sl, x)

def seq.fin(sl: List<&2, P.Op>, r: Array<F32> & U32) -> IO(Array<F32>):
  (x, +ok) = r
  seq.if(U32.is_eq(ok, 1), sl, x)

# one op, queued
def Op.q(op: P.Op, s: Array<F32>) -> IO(Array<F32>):
  match op:
    case P.Mm{ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc}:
      BI.bk.mm.q(ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s)
    case P.Ein{es, spec, g}:
      BI.bk.einsum.q(spec, s)
    case P.Seq{es, k, rev, c, spec, sl, g}:
      IO.bind(Array<F32> & U32, Array<F32>, BI.bk.einsum.seq.q(spec, k, rev, s), (r: Array<F32> & U32) => seq.fin(sl, r))

def run.q(ops: List<&2, P.Op>, s: Array<F32>) -> IO(Array<F32>):
  match ops:
    case Nil{}:
      IO.pure(Array<F32>, s)
    case op <> t:
      IO.bind(Array<F32>, Array<F32>, Op.q(op, s), (x: Array<F32>) => run.q(t, x))

# the program, every op queued, then one wait: the store it answers is done
def run(ops: List<&2, P.Op>, s: Array<F32>) -> IO(Array<F32>):
  IO.bind(Array<F32>, Array<F32>, run.q(ops, s), (x: Array<F32>) => BI.bk.sync(x))

# each list of ops in turn
def runs(xs: List<&2, List<&2, P.Op>>, s: Array<F32>) -> IO(Array<F32>):
  match xs:
    case Nil{}:
      IO.pure(Array<F32>, s)
    case ops <> t:
      IO.bind(Array<F32>, Array<F32>, run(ops, s), (x: Array<F32>) => runs(t, x))
