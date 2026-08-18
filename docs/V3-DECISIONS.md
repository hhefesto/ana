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

## 2. RG-LRU gate parametrization implemented (2026-08-18)

**Problem** (notes §1.1, the #1 architecture bug): v2's sigmoid gates never
open — measured 2026-07-31, frac(α > 0.9) exactly 0.0000 in every GLA layer,
memory half-life ~0.8 tokens — and the temperature arm that opened them lost
on loss because open gates admit unscaled input.

**Change** (notes §6.2 attack #1, Griffin arXiv 2402.19427): `GateRgLru` in
Config — per channel, log α = c·σ(z)·log σ(Λ) with c = 8 and a learned decay
base Λ (init so α^c is uniform on [0.9, 0.999): the gates *start open* and
training may close them, inverting the v2 pathology), plus the state write
scaled by √(1 − α²), folded into the normalized key so the token the
recurrence consumes is (q̂, β·k̂, v, α) — the gate stays the transition, the
scaled write is part of the contribution, and `Attention/Linear.agda`'s
algebra (recurrent≡parallel, chunk-closed) applies unchanged.  Implemented
in the Haskell reference (recurrent form), the chunked and quadratic Futhark
kernels, and the incremental decoder; the decomposed GEMM backend refuses
v3 arms loudly until a pilot promotes one.

**Smoke measurements** (tiny-rglru, 80 steps, sequential, byte corpus):

- Loss decreases 5.581 → 5.343; two identical runs give identical
  checkpoint SHA-256 (sequential determinism holds).
- **act-stats after training: alpha_mean 0.9727, frac(α > 0.9) = 1.0000**
  (v2 shipped: 0.0000) — half-life ≈ 25 tokens versus ~0.8.
- The sigmoid path is untouched: `deploy/train-plan-gate.sh` still passes
  byte-for-byte at SIZE=tiny on the same build.

80 steps at 242K parameters is a mechanism check, not a quality verdict —
whether open gates now *pay* on loss is exactly the bpe10m pilot's question
(§4 below, `bpe10m-rglru` arm).
