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

def Op.run(op: P.Op, s: Array<F32>) -> IO(Array<F32>):
  match op:
    case P.Mm{ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc}:
      BI.bk.mm(ta, tb, m, n, k, nb, al, ao, lda, sa, bo, ldb, sb, be, co, ldc, sc, s)
    case P.Ein{es, spec, g}:
      BI.bk.einsum(spec, s)

def run(ops: List<&2, P.Op>, s: Array<F32>) -> IO(Array<F32>):
  match ops:
    case Nil{}:
      IO.pure(Array<F32>, s)
    case op <> t:
      IO.bind(Array<F32>, Array<F32>, Op.run(op, s), (x: Array<F32>) => run(t, x))

# each list of ops in turn
def runs(xs: List<&2, List<&2, P.Op>>, s: Array<F32>) -> IO(Array<F32>):
  match xs:
    case Nil{}:
      IO.pure(Array<F32>, s)
    case ops <> t:
      IO.bind(Array<F32>, Array<F32>, run(ops, s), (x: Array<F32>) => runs(t, x))
