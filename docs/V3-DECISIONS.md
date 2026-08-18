# Version 3 decision ledger

Each ana-next (v3) design decision lands here with the measurement that
grounds it, in the order taken.  The planning basis is
`docs/ANA-NEXT-DESIGN-NOTES.md`; the protocol discipline is its §5 (A/B at
bpe10m scale, loss gaps against seed noise, sequential backend for anything
byte-exact, element-wise kernel verification, spec first where a spec is
cheap).

## 1. Tied vs untied output head (2026-08-18)

**Question** (notes §1.2): the tied head's logit kernel is a symmetric Gram
matrix (`Transformer/TiedHead.agda`), so skew bigram preferences are
unrepresentable by the head alone.  Is that constraint expensive enough to
spend ~22% of the parameter budget untying at v3 scale?

**Instrument**: `head-probe` (backend/gpu/Main.hs) — the collapsed
context-free head problem trained directly on the exact bigram statistics of
`run/wiki-bpe10m/shard-0-bpe10m.corpus` (20,240,370 pairs), production init,
schedule and AdamW, sequential binary, 500 steps × 64 contexts/step.
Entropy floors of this corpus: bigram 4.897, unigram 7.480, uniform 9.011
(nats).

| arm | setting | final full_loss | gap to bigram floor |
|---|---|---|---|
| T | tied (`HEAD_TIE=1`) | 7.737 | 2.840 |
| U | untied (`HEAD_TIE=0`) | 7.642 | 2.744 |
| M | tied + symmetry-breaking mix (`HEAD_MIX=1`) | 7.905 | 3.007 |

**Reading.** At a matched 500-step budget, untying buys 0.095 nats on the
collapsed problem — real but modest (3.4% of the tied arm's remaining gap to
the bigram floor).  Two caveats keep this from being decisive on its own:
both arms are still *above the unigram floor* at 500 steps, so the probe is
measuring early-training speed at least as much as representational
capacity, and the asymptotic handicap the Gram symmetry imposes may bind
only nearer the floor.  Arm M (a fixed per-context offset intended to break
the symmetry like a live trunk) is *worse* than plain tied at this horizon —
it behaves as input noise, not as usable asymmetry, so it is not a clean
control here.

**Stance for v3: keep embeddings tied.**  0.095 nats on the head-only
problem does not come close to justifying ~25M parameters (~22% of the
budget) that MobileLLM-style evidence says are better spent on depth.  A
10×-longer probe (HEAD_STEPS=5000, arms T and U) is running to check whether
the gap widens toward the floor or closes; the stance flips only if the
converged gap is a large multiple of the 500-step one.  (Result to be
appended below when it lands.)
