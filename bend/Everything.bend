import Base

# The gate: `bend Everything.bend` checks every specification module and the
# implementation modules they are stated over, and prints "All terms
# check." only when every law in them is proven (the trainer included:
# its pullbacks, optimizers, init, data and checkpoint modules).  Master's
# `agda -i . Everything.agda` is its counterpart.
#
# TrainDense.bend is not imported (2026-10-15): it logs through Clock.bend,
# whose wall clock ck.wall is our own effect (bend/effs/wall.c), and the
# gate counts a foreign def outside Base as a promise, like @unsafe (bend2
# main.ts book_promises: SOME PROOFS FAIL).  The modules only it brought in
# (Dense/Step, Dense/Plan, Mask) are imported here instead, so every law
# stays in the gate; TrainDense itself has no laws and is type-checked
# wherever it is compiled (bend-train-dense, the bend-dense check).
#
# Generate.bend and Evaluate.bend are not imported either (2026-10-22): the
# dense engine they run (Decode.bend, Dense/Decode.bend, Dense/Ckpt.bend)
# does its bulk F32 ops and checkpoint I/O through our own effects
# (BulkIo.bend, bend/effs/bulk.c) since ana left the Bend fork, whose
# compiler had them built in. Neither has laws; the tree decoder's prefill
# that Spec/Refinement.bend states a law about moved to Prefill.bend, and
# the pure modules only they brought in (Parse, with its laws; Checkpoint,
# Corpus, Sample, Dense/Io) are imported here. Dense/Ckpt.bend's two laws
# (Got and Put, the types of its file reads and writes) left with it.

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
import ./Train.bend as Train
import ./Parse.bend as Parse
import ./Checkpoint.bend as Checkpoint
import ./Corpus.bend as Corpus
import ./Sample.bend as Sample
import ./Dense/Io.bend as DIo
import ./Spec/Dense.bend as SDense
import ./Dense/Step.bend as DStep
import ./Dense/Plan.bend as DPlan
import ./Mask.bend as Mask
import ./Legere/Spec.bend as SLegere
import ./Agent/Episode.bend as AEpisode
