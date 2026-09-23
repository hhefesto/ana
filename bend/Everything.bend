import Base

# The gate: `bend Everything.bend` checks every specification module and the
# implementation modules they are stated over, and prints "All terms
# check." only when every law in them is proven (the trainer included:
# its pullbacks, optimizers, init, data and checkpoint modules).  Master's
# `agda -i . Everything.agda` is its counterpart.

import ./Spec/Nat.bend as SNat
import ./Spec/Order.bend as SOrder
import ./Spec/Algebra.bend as SAlgebra
import ./Spec/Fold.bend as SFold
import ./Spec/Weighted.bend as SWeighted
import ./Spec/Autoregressive.bend as SAutoregressive
import ./Spec/Trie.bend as STrie
import ./Spec/AutoregressiveTrie.bend as SAutoregressiveTrie
import ./Spec/Decoding.bend as SDecoding
import ./Spec/SpeculativeDecoding.bend as SSpeculative
import ./Spec/Linear.bend as SLinear
import ./Spec/Sink.bend as SSink
import ./Spec/LinearTrie.bend as SLinearTrie
import ./Spec/Bradley.bend as SBradley
import ./Spec/Reverse.bend as SReverse
import ./Spec/Batch.bend as SBatch
import ./Spec/Trusted.bend as STrusted
import ./Spec/Transformer.bend as STransformer
import ./Spec/TiedHead.bend as STiedHead
import ./Spec/ResidualStream.bend as SResidual
import ./Spec/Refinement.bend as SRefinement
import ./Generate.bend as Generate
import ./Train.bend as Train
import ./Evaluate.bend as Evaluate
