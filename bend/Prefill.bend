import Base
import ./Tensor.bend as T
import ./Model.bend as Md

# The tree decoder's prefill (Decode.bend's meaning of feeding a prompt):
# Model.bend's `decode`, one token at a time. Spec/Refinement.bend's
# prefill_chunks law is about it, and the gate (Everything.bend) imports it
# here: Decode.bend, which runs it, also loads checkpoints and runs the
# dense engine through our own effects (BulkIo.bend), which the gate
# counts as promises. Every def is `dc.`, as Decode.bend's.

def dc.Out.sts(o: Md.Out) -> List<&2, Md.LState>:
  match o:
    case Md.Out{l, s}:
      s

# feed the prompt; answer the output after its last token
def dc.prefill(xs: List<&2, U32>, +dm: Md.Dims, +w: Md.Weights, +o: Md.Out, +pos: Nat) -> Md.Out:
  match xs:
    case Nil{}:
      o
    case t <> rest:
      dc.prefill(rest, dm, w, Md.decode(dm, w, dc.Out.sts(o), pos, t), 1n+pos)
