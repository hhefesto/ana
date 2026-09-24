import Base
import ../Dense/Op.bend as P
import ../Dense/Ex.bend as X

# The dense layer's structural laws.
#
# Reverse mode (Dense/Op.bend) is a transformation of programs, and the
# law that makes it one is Elliott's: the transpose of a composite is the
# composite of the transposes, in the opposite order. `back` builds the
# transpose of a program onto the ops already built (an accumulator), so
# the transpose of xs ++ ys is ys's transpose followed by xs's.
#
# The numeric content -- each op's runtime (cuBLAS, generated kernels, the
# loops) agreeing with its base.bend definition, and each einsum's transpose
# being its derivative's -- is F32 and so is tested, not proven: the
# conformance programs (bend/gpu) and tests/dense.bend (the derived backward
# against the gradchecked tree pullbacks), as the pullbacks' correctness
# rests on the gradcheck.

def back.append(+tg: U32, xs: List<&2, P.Op>, +ys: List<&2, P.Op>, +acc: List<&2, P.Op>) ->
  {P.back(tg, List.append(&2, P.Op, xs, ys), acc) == P.back(tg, ys, P.back(tg, xs, acc)) : List<&2, P.Op>}:
  match xs:
    case Nil{}:
      {==}
    case +x <> t:
      back.append(tg, t, ys, List.append(&2, P.Op, P.Op.back(tg, x), acc))

# the empty program is its own transpose
def back.nil(+tg: U32, +acc: List<&2, P.Op>) -> {P.back(tg, Nil{}, acc) == acc : List<&2, P.Op>}:
  {==}

# a constant's derivative vanishes, so no einsum transposes into it
def d.const(+c: F32, +j: U32) -> {X.d(EK{c}, j) == X.k(0.0) : Ex}:
  {==}

# a loop index's too: masks and positions carry no gradient
def d.index(+i: U32, +j: U32) -> {X.d(EIx{i}, j) == X.k(0.0) : Ex}:
  {==}
