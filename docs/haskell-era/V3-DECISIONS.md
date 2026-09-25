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

**Preliminary stance (500 steps): keep embeddings tied.**  0.095 nats on
the head-only problem did not look close to justifying ~22% of the
parameter budget.  Pre-registered flip condition: the stance flips if the
converged gap is a large multiple of the 500-step one.

**The 5000-step probe flipped it (same day).**

| arm | 500-step full_loss | 5000-step full_loss | gap to bigram floor |
|---|---|---|---|
| T tied | 7.737 | 6.744 (plateaued: EMA 6.73 by step 4400) | 1.847 |
| U untied | 7.642 | 5.380 (still falling) | 0.483 |

The untied advantage grew 14× (0.095 → 1.365 nats).  The tied arm
flattened ~1.8 nats above the bigram floor while the untied arm closed to
within 0.5 — a representational ceiling, not a training-speed difference,
and exactly the shape `TiedHead.agda`'s impossibility theorem predicts:
bigram statistics are heavily skew, and the tied head's symmetric Gram
kernel cannot express skew at any training length.

**Revised stance: tied remains the default, but untying is promoted to a
mandatory bpe10m pilot arm (§4).**  The probe isolates the head; in the
full model the trunk can supply context-dependent asymmetry, so the ~1.4
nats measured here is an upper bound on what the constraint costs
end-to-end, not an estimate of it.  The pilot that decides is a full
bpe10m training A/B (HEAD_TIE equivalent at the architecture level),
parameter-matched by shrinking elsewhere in the untied arm.

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

## 3. QK-norm and per-head sink logits implemented (2026-08-18)

Notes §6.1 items 4 and 6, both on the softmax layers: per-head RMSNorm on
q/k with zero-centered weight-decayed gains (bounds every attention logit
by construction; four independent adopters), and one learned sink logit
per head, softmaxed beside the scores with its weight dropped — exactly
the restriction-of-extended-softmax semantics proved in
`FormalTransformer/Attention/Sink.agda`, so a head can attend to nothing.
Both init neutral (gains at 1, sinks at unit mass).  Verified by the
conformance oracle's full battery over five architecture arms (sigmoid /
rglru / qknorm / sinks / v3-all): forward, vjp vs Numeric.AD,
chunked-vs-quadratic, micro-batch, incremental decode.  Note for smokes:
`tiny` has one layer and no softmax block — `small4-v3` is the smallest
config that trains these arms.

## 4. The bpe10m pilot matrix (defined 2026-08-18; execution awaits GPU)

Protocol per notes §5: matched data via the plan-TSV fingerprint, the
sequential backend for any byte-exact pair, ≥2 seeds per arm at bpe10m
scale, decisions on final validation loss against seed noise measured from
the baseline pair.  All arms train the same token budget with the same
schedule; nothing here touches the master run.

| arm | preset / setting | decides |
|---|---|---|
| A0 baseline | `bpe10m` (v3 code, v2 semantics) | the reference point and the seed-noise floor (2 seeds) |
| A1 gates | `bpe10m-rglru` | notes §6.2 #1: do open gates pay on loss? Also gate stats + prefix-matching scores |
| A2 attention | `bpe10m-qk-sink` | §6.1 items 4+6 as one arm (both are near-free stabilizers) |
| A3 optimizer | `bpe10m` + `TRAIN_OPT=muon` | Muon at our scale (community-replicated at d=768; here d=320) |
| A4 combined | `bpe10m-v3` + `TRAIN_OPT=muon` | interaction of all adopted arms |
| A5 head | `bpe10m-untied` (separate unembedding) | §1's flipped verdict: does the trunk compensate the tied head's skew deficit? Run BOTH comparisons: same-trunk (untied +2.62M params, reported per-parameter) and iso-parameter (tied with ffDim raised ~864→1319 to match), since each matching choice distorts differently |

A5 implementation (2026-08-19): `tiedHead :: Bool` in Config (arch bit 3);
the `unembedding` slice sits LAST in the layout so untying moves no
existing offset, and the Futhark projection reads from offset 0 (the
embedding) when tied — one code path, no branch.  The unembedding stays on
AdamW under Muon, like the embedding.  Verified by the six-arm conformance
battery (untied and v3-all-untied arms) and the usual smokes.

Success rules, written before the data: an arm is adopted for the v3
bpe100m run only if its final validation loss beats A0 by more than the
measured seed spread, or (A1 only) if loss is within noise while the gate
half-life and induction-head prefix-matching scores improve materially —
the mechanism the perplexity curve may hide (notes §6.3).  A2 may also be
adopted on stability grounds alone (logit tails) at equal loss.  Estimated
cost: 6 arms × ~2 runs × hours each on one rented GPU — comfortably under
$20 at 3090 rates.

## 5. Cross-architecture warm start: v2 weights may seed v3 arms (2026-08-20)

The v2 read-only migration originally stopped at sampling: v3 could decode
the master run's checkpoints but deliberately could not train from them.
That restriction is now removed (user decision, 2026-08-20).  TRAIN_INIT
accepts a source checkpoint of a DIFFERENT architecture over the same core
dimensions — in particular a v2-era checkpoint, which decodes through the
migration as arms-off v3 — and `transferParameters`
(FormalTransformer.Layout) builds the new run's initial parameters:

- a slice transfers when its name and shape mean the same thing in both
  layouts (embedding, wq/wk/wv/wo, FFN matrices, norms — the bulk of the
  parameters);
- `walpha` does NOT transfer across gate kinds: the same projection feeds a
  different gate formula under RG-LRU, so its trained values are noise
  there;
- an untied run's `unembedding` seeds from a tied source's embedding, which
  computes exactly the function the tied head was trained to;
- new arm slices (`gate_lambda`, `qk_gain_q/k`, `sink`) keep their fresh
  init, which is open or neutral by construction.

Everything else about the new run is fresh: identity, schedule, optimizer
moments, step, PRNG.  Resume (`validateResume`) is unchanged — a checkpoint
still cannot silently CONTINUE as a different run; warm start mints a new
one.  The live bpe100m master run is untouched: its checkpoints are only
ever read.

The §4 pilot matrix is unaffected: pilot arms still train from scratch
(warm-started arms would not be comparable to A0), and its success rules
stand as pre-registered.  Warm start exists for what comes after — carrying
the master run's learned weights into whichever architecture the pilots
adopt, instead of paying for the trunk twice.

Verified 2026-08-20: unit test "cross-architecture warm start transfers by
slice" (provenance of every slice kind, identity on same architecture,
core-dim mismatch rejected); the migration test still passes; sequential
smoke — tiny arms-off base warm-started into tiny-rglru (11 slices
transferred, walpha + gate_lambda fresh) and tiny-untied (13 transferred
including the seeded unembedding, 0 fresh), both training with falling
loss; train-plan-gate.sh stays byte-exact.

## 6. The §4 pilot matrix is skipped; v3 goes straight to bpe100m (2026-08-20)

**User decision, recorded as a protocol deviation**: the pre-registered
bpe10m pilot matrix will not run.  The v2 master run is interrupted at step
~336K/358,276 (93.9%, train-loss EMA 3.376; the final LR-decay steps are
foregone), its checkpoint is pulled as the final v2 artifact, and the box
is repurposed for a **warm-started v3 bpe100m run**:

- **Preset `bpe100m-v3`**: bpe100m dimensions with RG-LRU gates, qk-norm
  and sinks; the head stays tied.  115,435,428 parameters — the arms add
  7,332 (nine per-channel `gate_lambda` rows plus, per softmax layer, two
  head-dim qk gains and one sink per head).
- **Warm start** (§5): `TRAIN_INIT` from the pulled v2 checkpoint.  Every
  matrix transfers except the nine GLA `walpha` projections (gate kind
  changed, so their trained values are noise under RG-LRU); the arm slices
  start fresh (open/neutral by construction).
- **Optimizer: Muon** (`TRAIN_OPT=muon`, hidden matrices only) — adopted
  without its A3 pilot, stacking a second unpiloted change on the run.
- **Backend**: the Futhark CUDA trainer (`formal-transformer-cuda`); the
  decomposed GEMM backend still refuses v3 arms (§2).  Its bpe100m
  throughput on the 3090 is unmeasured, so the launch carries an explicit
  **measure-first gate**: tok/s over the first checkpoints projects the
  full-run wall time and cost, reported before the run is left unattended.

What this loses, stated plainly: no arm-by-arm attribution (a regression
against A0 cannot be localized to gates vs qk/sinks vs Muon vs the warm
start), and §4's success rules never fire.  The warm start itself is the
§5 machinery working as intended.  If the combined run underperforms the
v2 baseline, the pilots remain the pre-registered fallback.

## 7. The v3 arms are ported to the decomposed GEMM backend (2026-08-20)

The §6 launch attempt measured the plain Futhark CUDA trainer at
~82 s/step ≈ 200 tok/s at bpe100m on the 3090 — ~57× slower than the
GEMM trainer and ~340 days for the plan — so the run was stopped after
13 steps (no v3 checkpoint had been written; the warm start relaunches
cleanly) and the arms were ported to the decomposed GEMM backend
instead.

The port adds five pieces (RG-LRU log-gate against the decay base, the
√(1−α²) write scale on the normalized key, gate-cum over log-space
gates, per-head qk-RMSNorm with shared gains, and the sink-slot causal
softmax) with vjp2 pullbacks, carries the arm weights through the
decomposed traversal as layout-driven fields, and un-stubs the Muon
device step by exposing the SAME muon_step_def the fused backends run.
The untied head remains refused (the head path is tied by
construction).

Verified 2026-08-20, per the element-wise discipline: every new piece
against Numeric.AD; a five-arm tied battery (sigmoid / rglru / qknorm /
sinks / v3-tied) in which the decomposed traversal reproduces the fused
oracle AND Numeric.AD on every gradient element (max-abs ~1e-7 at f32);
the Muon step against Optimizer.muonStep per arm; and a fixed a latent
argument-order bug — the conformance FFI had never been updated for the
arch-word entries of commit 24c4ac4.  One fused-oracle golden per arm
ships with gemm-conformance for raw-probe's on-device replay
(`raw-probe e2e GOLDEN <arm>`).  deploy/bpe100m-v3.env now points at
result-gemm with micro-batch 64 and tf32/stream, the settings of the
measured production baseline.

## 8. The RG-LRU gate is capped at alpha = 0.9999 (2026-08-21)

The first v3 run died at step 6,000 on `checkpoint Muon momentum
contains non-finite numbers`.  That message is `validateCheckpoint`
refusing a NaN snapshot on **save** — the last correct thing in the
chain, not the fault, and the reason the step-4,940 checkpoint survived
intact.

The fault is §2's write scale, `beta(L) = sqrt(1 - exp(2L))`, at
alpha = 1.  It is not Lipschitz there: `dbeta/dL = -exp(2L)/sqrt(1 -
exp(2L))` diverges as `L -> 0`.  f32 makes it worse than the maths —
`exp(2L)` rounds to exactly 1.0 for `|2L| < 6e-8`, so the radicand is
exactly 0, the forward value is a clean 0, and the pullback is a literal
1/0.  Measured through the production composition `kc *
rglru_write_scale (rglru_log_gate z lam)`: at z = -20, lambda = +1 the
value is 0.0 and `d/dz` is +inf; at log alpha = -1e-7 the pullback is
already -2365.

The log shows exactly that shape.  Step 5,006 has a **finite**
`train_loss=3.4358122` and `gradient_norm=NaN`.  Nothing downstream
stopped it: `clip_global_norm` rescales only when `norm > max_norm`, and
`NaN > max_norm` is False, so the clip was the identity on a NaN
gradient (`clipped=false` in the log), the Muon/AdamW step applied it,
and every parameter was NaN one step later.  994 further steps trained
on nothing.

Decision: cap `log alpha <= -1e-4`, i.e. `alpha <= 0.9999`, in all three
implementations of the denotation — `backend/futhark/model.fut`,
`backend/src/FormalTransformer/Model.hs`, and
`backend/gemm/GemmConformance.hs`.  This is a real restriction of the
model class and a small one: at alpha = 0.9999 the state still survives
the whole 256-token window at 97.5% (half-life 6,931 tokens, 27x the
context), while `|dbeta/d log alpha|` is bounded by 71.  It binds only
where the old code returned 0 with an infinite gradient — i.e. only
where training was already undefined.

Two further copies of the same fault were found while fixing it and are
now stable branches, with no change to the denotation: written
`1/(1 + exp(-z))`, sigmoid overflows `exp(-z)` to inf below z = -89 and
its pullback becomes `inf/inf^2 = NaN` under a forward value of 0; silu
had it too.

The trainer no longer applies a non-finite update at all.  It skips such
a step, logs `skipped=true`, and stops only after 20 consecutive skips —
so the next singularity we have not found costs one step, not a run.
`tests.fut` gains `test_rglru_write_scale_total` and
`test_rglru_gate_total`, which assert value AND pullback are finite
across the whole reachable (z, lambda) corner; both fail on the old
`model.fut`.

The pre-launch gates of §7 did not catch this because their probe inputs
never came near alpha = 1 — and alpha -> 1 is precisely what §2 adopted
RG-LRU to make reachable.  The rule this leaves: **a finite loss is not
evidence of a finite gradient.**  Test pullbacks at the singular
arguments of the forward, not at the comfortable ones.

Verified in production: the run resumed from the intact step-4,940
checkpoint, whose stored PRNG state replays the same batches, so step
5,006 is a direct A/B.  It now reads `train_loss=3.4358063
gradient_norm=0.3495149` — the loss agreeing to six significant figures
with the pre-fix run, the gradient finite.
