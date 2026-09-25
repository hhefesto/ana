# ana-next: design notes for future versions

Started 2026-08-16, while the bpe100m run continues to completion unchanged.
This document collects (1) what this project has already measured and proved,
(2) what the major labs have published that is applicable at our scale, and
(3) a concrete roadmap for making the formal specification stronger. Nothing
here touches the current run.

**Status (2026-08-18): this document is the planning basis for version 3.**
Version 3 development proceeds on the `ana-next` branch, while `master`
tracks the running v2 model (the master run). See README "Versions".

**Standing constraints for any future version:** Haskell + Futhark backend;
denotational-specification-first (Agda, `--safe --without-K`); single consumer
GPU budget (RTX 3090/5090 class); ~100M–1B parameters; every architecture
change is a new model identity (checkpoint-incompatible), so changes batch at
run boundaries.

---

## 1. Lessons already banked (measured in this project — highest-trust tier)

These are our own measurements; they outrank any paper claim below.
When the master run (bpe100m) completes, its final evaluation and generation
results belong in this section (they land on master as v2.1.0).

### 1.1 The GLA gates never open (the #1 architecture bug to fix)

Measured 2026-07-31: at the shipped gate temperature, `frac(alpha > 0.9)` is
exactly 0.0000 — the gated-linear-attention layers have a memory half-life of
~0.8 tokens, i.e. they are functioning as (expensive) local mixers, not as
recurrent memory. `tau = 16` opens the gates but *loses on loss*, so the fix
is not a knob turn: the gate parametrization itself needs redesign. This is
the single most valuable thing to get right in ana-next, and it is exactly
where the published GLA-successor work (Kimi Delta Attention, Qwen3-Next's
Gated DeltaNet, Google's Griffin/RecurrentGemma) should be mined — see
§3.3, §3.7 and the ranked attack plan in §6.2.
A falling clip rate hid an 8× worse gradient tail during diagnosis: watch
tails, not means.

### 1.2 The tied output head cannot represent skew bigrams (untying decision)

`FormalTransformer/Transformer/TiedHead.agda` proves the tied head's logit
kernel is a per-row-rescaled symmetric Gram matrix: preferring a→b over b→a
is *unrepresentable* by the head alone and must come from the trunk. This is
a standing structural suspect for repetition (hypothesis H2). For ana-next:
run the `head-probe HEAD_TIE=0/1` A/B (CPU, minutes) before deciding; untying
at vocab 32768 × dim 768 costs ~25M params (~22% of a 115M model), so the
honest alternatives are (a) untie and shrink elsewhere, (b) keep tying and
accept the constraint as spec'd, (c) shrink the vocabulary (see §1.6).

### 1.3 Decoding is now specified — keep building there

`FormalTransformer/Language/Decoding.agda` proves: top-p retains ≥ p of the
mass by construction; top-k has *no* distribution-independent retention floor
(exactly k/v on the uniform measure) — the formal version of the measured
step-92,000 "regression" that was entirely a `TOP_K=40` artifact. Defaults are
now `TEMPERATURE=0.8 TOP_P=0.95`, top-k off. Also measured: prompts ending in
whitespace go off-manifold under our BPE (space attaches to the *following*
word), and the failure gets *worse* as the model sharpens — the decoder now
strips trailing whitespace; keep prompt normalization in the spec's scope.
The 240-draw trend sweep protocol (≥8 seeds/arm, medians, slope vs. the
~0.047 seed-noise floor, untruncated arm D as the model's own law) is the
reusable instrument for any future "is it getting worse" question.

### 1.4 The backend's weak axis is memory traffic, not FLOPs

Measured: the arena never frees intra-step (~20 GB at bpe100m micro 8); three
Futhark kernels are 35% of kernel time with **no cuBLAS GEMM in the top
kernels**; 3% MFU on the 3090, 13.5% on the 5090 at micro 64 + stream; bf16
buys nothing on the 5090. Boxed-list checkpoint save peaked ~28 GB and was
fixed with unboxed vectors (8.8 GB, byte-identical format). Consequences for
ana-next: (a) any architecture that multiplies residual/KV memory traffic is
guilty until fused (this killed mHC adoption, §2.1); (b) kernel fusion +
arena lifetime work likely buys more wall-clock than any architecture change;
(c) `hoist before hand-writing a pullback` — let-floating the per-head norm
gave 4.8× with a bit-identical forward, while the handwritten closed form was
slower.

### 1.5 Correctness discipline that must carry forward

- The bpe10m divergence was a *miscompiled CE pullback* at vocab 8192 with
  correct loss and garbage gradient: **verify kernels element-wise against
  the spec, never via max-abs statistics.**
- The multicore backend is non-reproducible (identical runs, different
  checkpoint hashes); the sequential backend is the byte-exact oracle.
- Plan-TSV fingerprints give a bit-exact regression test for any corpus or
  tokenizer change.
- Always state the population with any bpb figure (the 1.107 headline was
  population-biased; corpus-wide ~1.21, enwik8 1.99).
- Interleave corpora, never concatenate; watch for short-but-valid corpora
  and quadratic planners (both bitten us).

### 1.6 Sizing facts at our scale

Vocab 32768 with tied embeddings is ~22% of a 115M model's parameters; the
context is 256; tokenizer throughput is 7.33 MB/s parallel with the boxed
`[Int]` allocation (not BPE merges) as the bottleneck. The three open
questions this document set out to answer from the literature — depth-vs-width
at sub-1B, vocabulary scaling at small model size, and whether context should
grow before parameters — all got answers: **deeper-and-thinner** (§3.5, §3.2),
**our vocabulary is if anything too large** (§3.13), and **context should not
grow yet** (every long-context technique surveyed pays only above ~16K, §3.1).

---

## 2. Techniques already researched in this project

### 2.1 mHC / Hyper-Connections (DeepSeek, arXiv 2512.24880) — spec'd, not adopted

Full findings: `docs/PAPER-2512.24880-FINDINGS.md`. Verdict: widened residual
streams (n = 4 lanes with doubly-stochastic per-layer mixing) are not adopted
— wrong depth (benefit scales with layer count; we have 12), wrong cost
profile (≈7× residual read amplification against our measured weak axis),
and the instability it fixes cannot arise at n = 1. The stability algebra
*was* adopted into the spec: `FormalTransformer/Transformer/
ResidualStream.agda` proves mass conservation under column-stochastic mixing,
closure under composition, and n = 1 rigidity (the plain residual is the
unique manifold-constrained mix). Revisit-gates for adoption: fresh run AND
≥2× depth or ≥300M params AND arena/fusion work landed AND a bpe10m-scale
A/B beats seed noise.

### 2.2 GLM-5.3 (Z.ai) — architecture lineage noted, nothing adoptable yet

Researched 2026-08-14 (see §9 of `docs/PAPER-2604.07242-FINDINGS.md`):
GLM-5.3 is the same 744B/40B-active base as 5.2; all gains are post-training
(SAO RL, environment scaling, slime async RL). Architecture lineage — MoE
256/8+1, MLA, DSA sparse attention (top-2048 indexer), IndexShare (a
`full,shared,shared,shared` layer cycle justified by measured 70–100%
adjacent-layer index overlap), MTP — targets 1M-token serving at 744B and is
inapplicable at context 256 / 115M dense. Two durable notes: their 1-in-4
global-attention cycle structurally rhymes with our 3:1 `kindOf` hybrid rule
(independent convergence on sparse-global/dense-local interleaving), and the
one theorem-shaped import is **speculative-decoding unbiasedness** (§4.2).

### 2.3 arXiv 2604.07242 (categorical tensor frameworks) — verified, not adopted

`docs/PAPER-2604.07242-FINDINGS.md`: sound but PyTorch-only, no
differentiation story, no empirical results; nothing to adopt. Its value was
calibrational: our Agda spec already covers ground (AD, autoregressive mass
laws) that the categorical-frameworks literature has not reached.

---

## 3. Lab-by-lab research (2026-08-16 sweep)

Four parallel primary-source passes: DeepSeek + GLM; Kimi + Qwen; Meta +
OpenAI + Google + Mistral; cross-lab theory + optimizers + Anthropic. Every
number below is **author-reported unless explicitly marked replicated** — the
distinction matters more than usual here, because almost all frontier
evidence comes from scales 100–10,000× ours, and the sections are written to
say plainly when a result does not transfer down.

### 3.1 DeepSeek

**Engram (arXiv 2601.07372) — the standout candidate of the entire sweep for
our scale.** A "conditional memory" module beside the transformer: hash the
last N tokens (multi-head hashing into large embedding tables), retrieve, gate
contextually, sum over several N. O(1) lookup per token; **capacity scales
with table size — cheap host RAM — not with FLOPs**. Author-reported:
Engram-27B beats iso-param and iso-FLOP MoE baselines on knowledge, reasoning,
code and math. It did *not* ship in V4 and is unreplicated.

Why it is interesting *here* specifically: it is the one frontier technique
whose mechanism is **scale-independent and memory-bound rather than
compute-bound**. A hashed 4/5-gram table beside a 115M trunk trained on
Wikipedia is exactly "offload memorization, keep the trunk for computation" —
it works at context 256, costs almost no FLOPs, and is a **pure gather in
Futhark**. Our trunk is memorization-starved in a way a 27B trunk is not, so
the effect could plausibly be *larger* at our scale, not smaller. Risk is
honest: unreplicated, shown only at 27B, and it trades VRAM/RAM for quality
in a project whose weak axis is memory. Worth an experiment slot, and it has
excellent constructive spec content (§4.2).

**Multi-Token Prediction (V3, arXiv 2412.19437).** Not parallel heads: a
*sequential* extra block taking `RMSNorm(h_t) ∥ RMSNorm(Emb(x_{t+1}))`,
sharing embedding and output head, predicting token t+2; loss weight λ = 0.3
early then 0.1. Independently adopted by GLM-4.5, GLM-5 (three MTP layers
**sharing parameters** — the memory-friendly variant to copy), and V4. Two
payoffs: a densified auxiliary training signal, and a self-speculative draft
head. Cost at our scale ≈ one extra block (~8% params). **Nobody has
published this at 115M dense**, and older multi-token work put gains at ≥3B —
so it is an open question and a genuine contribution opportunity, but keep
expectations calibrated. Note this cuts against §3.4's "skip MTP" for the
*decoding* use; the *auxiliary-loss* use is the interesting one for us.

**MLA (arXiv 2405.04434)** — cache a shared low-rank latent instead of
per-head K/V, with a small "decoupled RoPE" key because RoPE sits between the
two matrices and blocks absorption. Best-validated technique in the survey by
adoption (V2/V3, Kimi K2, GLM-5). **Not for us**: at context 256 the KV cache
is irrelevant, and at 4096 plain GQA gets most of the win with far less
machinery; at 100M the low-rank bottleneck (~dim 96–128) is untested and
plausibly capacity-limiting. Its *formal* content is excellent and is queued
(§4.2) — the absorption-exactness theorem is our "hoist before hand-writing"
lemma class exactly, and the negative RoPE lemma explains why the design
looks the way it does.

**DSA / lightning indexer (V3.2, arXiv 2512.02556), NSA, IndexShare, CSA/HCA
(V4)** — all long-context machinery, all N/A below ~16–32K context. Skip. Two
transferable non-obvious bits: (i) DSA's **dense warm-up** (freeze the model,
train a cheap auxiliary predictor by KL against the true internal attention
distribution) generalizes to a pattern we could use — e.g. distilling our
softmax layers' attention pattern into a GLA gate *initializer*, which is a
plausible attack on the gates-never-open problem from a third direction;
(ii) GLM measured **70–100% overlap between adjacent layers' selected
supports**, and the analogous cheap diagnostic on ana — how redundant are
adjacent softmax layers' attention patterns? — would directly inform whether
our 3:1 substitution is justified layer-by-layer.

**Aux-loss-free MoE routing (arXiv 2408.15664)**: bias-based top-k selection
where the bias steers *selection only* and the output gate keeps the original
affinity; `b_i ← b_i − γ·sign(load_i − avg)`. The most-replicated routing
technique of this era (V3, GLM-4.5, K2, V4). Only relevant if ana grows a MoE
arm — and a "tiny-MoE ana" (8 experts, top-2, ~200–400M total at ~115M
active) on one GPU is a reasonable future direction, with this as the right
router (no interference gradient, one hyperparameter, host-side scalar update).

**GRPO (arXiv 2402.03300)** — PPO with the critic deleted; group-relative
advantage. The one RL algorithm that fits a single consumer GPU (no critic
halves memory), and genuinely replicated down to 0.5–3B in the open. If ana
ever does RL on verifiable synthetic tasks (arithmetic, copying, retrieval
within context), this is the choice. **A real ana advantage surfaced here:**
both DeepSeek and Z.ai treat "π_infer ≠ π_train as *executed programs*" as a
first-class problem (V3.2's off-policy masking, GLM's IcePop mismatch
clipping). Our byte-exact sequential backend makes that problem vanish by
construction — worth stating explicitly as a project strength.

**FP8 training** — E4M3 with tile-wise (1×128) activation and block-wise
(128×128) weight scaling, plus two-level accumulation promoting partials to
FP32 every 128 elements. **Skip**: the 3090 has no FP8 tensor cores, Futhark
has no FP8 path, and our own 5090 measurement showed bf16 buys nothing
because we are shape/launch-bound, not FLOP-bound. The fine-grained-scaling
*idea* only returns if we quantize checkpoints for CPU inference on olimpo
(block-wise INT8 would be the sane target).

**DualPipe / EPLB** — multi-node problems we don't have. One amusing note:
DualPipe's correctness condition ("a schedule is correct iff it linearizes
the same dependency DAG") is literally our multicore-nondeterminism issue in
specification form.

**mHC update:** the V4 report (arXiv 2606.19348) shows **mHC shipped in
production** (1.6T/49B Pro, Sinkhorn-Knopp 20 iterations), alongside Muon and
`sqrt(softplus)` routing with hash routing in early blocks. That upgrades
mHC's status from "author-reported at 27B" to "deployed at frontier scale"
and should be reflected in `docs/PAPER-2512.24880-FINDINGS.md`. It does not
change our non-adoption verdict — the reasons were scale, cost profile and
n = 1 rigidity, none of which V4 touches. Also of note: **V4 dropped MLA
entirely**, replacing head-axis compression with sequence-axis compression.

### 3.2 Z.ai / GLM

**Architecture, GLM-4.5 (arXiv 2508.06471) → GLM-5 (arXiv 2602.15763).**
Two explicitly stated design findings matter to us. First, **deeper, not
wider**: they cut hidden dim and expert count and added layers versus
DeepSeek-V3's wide/shallow shape, reporting "deeper models exhibited better
reasoning capacity." This is the same direction MobileLLM found at 125M
(§3.5) — a rare case of a frontier claim corroborated at *our* scale, and
together they make the deep-thin re-shape arm the best-supported structural
experiment in this document. Second, **more heads don't lower loss but help
reasoning** (2.5× head count, unchanged training loss, better MMLU/BBH) —
at 115M the benchmark deltas involved would drown in seed noise, so this is
noted and *not* actionable for us (our 162-draw lesson applies directly).

Also: **QK-Norm** to "stabilize attention logit range" (a third independent
lab landing on it — see §3.4, §3.7), partial RoPE, sigmoid gates with
loss-free routing, param-shared 3-deep MTP, and **Muon on everything except
embeddings/biases/RMSNorm weights**. GLM-5 added **"Muon Split"** —
orthogonalize the MLA sub-matrices independently rather than the fused
projection — which is directly relevant the moment we run Muon over GLA's
factored projections: apply Newton-Schulz per *logical* matrix, not per fused
buffer. GLM-5 also retrofitted DSA with **47× less adaptation data than
DeepSeek used** (20B tokens vs 943.7B) and it still worked, which is the most
useful transfer datapoint in their report even though DSA itself is N/A here.

**TITO (Token-in-Token-out)** — their RL gateway never re-tokenizes
trajectories, preserving exact action-level correspondence. This is a
principle we already follow (plan-TSV fingerprints are the same idea), and it
has clean formal content: `encode ∘ decode ≢ id` for BPE in general, with
equality holding exactly on canonical (greedy-merge-normal-form) token
sequences. That characterization appears not to be formalized publicly and is
queued in §4.2.

**Z.ai's small models — the informative negative.** GLM-4-9B-0414 was
explicitly *not* given the agentic training of its siblings; GLM-Edge (1.5B/4B)
is barely documented; after that "small" means small-*activation* MoE
(GLM-4.5-Air 106B/12B keeps the flagship's 96 heads, just fewer layers and
experts). Both major Chinese labs have effectively abandoned the sub-10B
**dense** regime to Qwen. Consequence for us: for dense models at ana's size,
MobileLLM and Qwen3-small are the only serious public evidence — the frontier
labs are not producing datapoints in our regime, which is precisely why our
own bpe10m A/B pilots are the deciding instrument.

**slime / SAO**: infrastructure and RL at a scale we don't have. The one
durable lesson is architectural — rollout logic decoupled behind a data-buffer
interface with rewards as pure functions over token trajectories is the right
shape for any future Haskell RL loop. SAO (single rollout + value model)
inverts GRPO's tradeoff only when episodes are long relative to compute;
**GRPO stays right for ana**, where 8 rollouts of a 115M model are trivial and
a value model would double memory.

### 3.3 Moonshot / Kimi

**Muon optimizer — the highest-value single item found in this sweep.** For
each 2-D hidden weight matrix (embeddings/head/norms stay on AdamW): Nesterov
momentum, then 5 Newton-Schulz iterations of the odd quintic
`X ← aX + bX(XᵀX) + cX(XᵀX)²`, coefficients (3.4445, −4.7750, 2.0315), which
pushes the momentum's singular values toward 1 while preserving singular
vectors — steepest descent under the spectral norm. Moonshot's additions:
AdamW-style weight decay (their bf16-overflow fix, only bites >1B) and a
`0.2·√max(n,m)` update-RMS rescale so AdamW learning rates carry over
unchanged. Evidence is unusually strong *at our exact scale*: the NanoGPT
speedrun record (124M, d = 768 — ana's dim) improved 35% and the technique
held through 12 subsequent records by 7 researchers — community-replicated;
Moonshot's scaling-law fit (399M–1.5B) claims compute-optimal-AdamW loss at
~52% of the FLOPs; production-validated through Moonlight, K2 (15.5T tokens),
Kimi Linear. Overhead ~0.7% FLOPs at d = 768. **Verdict: adopt in ana-next,
gated only by the standard bpe10m A/B.** Futhark surface is small (the NS
iteration is 2–3 GEMMs × 5); apply per logical matrix (Q, K, V, gate
projections separately), keep embeddings/head on Adam; f32 makes the bf16
caveats moot.

**MuonClip / QK-Clip** (K2 report): Muon empirically drives attention-logit
explosion; the fix rescales `W_q, W_k` per head by `√γ_h`,
`γ_h = min(1, τ/S_max^h)`, τ = 100, and self-deactivates after ~30% of
training. K2 reports zero loss spikes over 15.5T tokens. At 115M this is
insurance, not a need — and QK-Norm (§3.4) *prevents* what QK-Clip *treats*.
Verdict: if we adopt Muon, log per-head max logits (one reduction over a
matrix we already materialize) and keep QK-Clip in the pocket; prefer QK-Norm
as the primary defense.

**Kimi Delta Attention (KDA) / Kimi Linear — the direct upgrade path for our
GLA layers.** KDA = Gated DeltaNet with the scalar forget gate replaced by a
channel-wise gate — i.e. exactly our GLA's `Diag(α_t)` fine-grained decay,
*plus* the delta rule:

```
S_t = (I − β_t k_t k_tᵀ) Diag(α_t) S_{t−1} + β_t k_t v_tᵀ ;  o_t = S_tᵀ q_t
```

with α_t a low-rank-projected channel gate, β_t ∈ [0,1] a scalar per-head
write strength, a sigmoid output gate, and short convs on q/k/v (both
ablated as helping: output gate 5.65 vs 5.67 val PPL; conv removal hurts
5.67→5.70). Hybrid layout is **3:1 KDA-to-full-attention — our exact ratio**
— with the full-attention layers using **NoPE** (no positional encoding; all
recency delegated to the gates), which matched RoPE at short context and beat
it at 128k (RULER 84.3 vs 78.8). Validated in a controlled 1.4T-token
comparison at 48B/3B-active vs full-MLA and Gated-DeltaNet hybrids (beats
both on MMLU-Pro/BBH); critically for us, the synthetic ablations (MQAR,
palindrome, stack) ran at **256–2048 tokens — our context regime** — and
attribute the recall wins specifically to the channel-wise gate. Kernels are
public in `flash-linear-attention` (`fla/ops/kda`). 3:1 ablated as optimal
(7:1 degrades 5.70→5.82).

Why this matters for §1.1: our measured pathology is gates that never open
(half-life ~0.8 tokens) because decay is the *only* forgetting mechanism —
the gate must close hard to avoid interference. The delta rule moves erasure
into the Householder-like `(I − β k kᵀ)` term (erase what this key retrieves,
then rewrite), so the decay gate can afford to stay open. That is a concrete,
testable hypothesis for why tau = 16 lost on loss. **Verdict: KDA-style
delta rule + output gate + short conv on our existing channel-wise GLA is the
#1 architecture candidate for ana-next**, gated by a bpe10m A/B and by the
Futhark cost of the chunkwise kernel (harder than plain GLA; the key-tied
DPLR structure cuts the chunk matmuls 4→2 and the fla Triton source is a
reference).

Also noted from K2: doubling attention heads bought only 0.5–1.2%
validation loss for +83% inference FLOPs at long context — supports *not*
increasing head count when scaling. K1.5/K2.5: RL recipe and multimodal work,
nothing at our scale.

### 3.4 Qwen

**Qwen3 dense smalls (0.6B/1.7B) — the closest public analogs to ana.**
Design facts: **QK-Norm** (per-head RMSNorm on queries and keys before RoPE,
replacing Qwen2's QKV biases, "to ensure stable training" — bounds logits by
construction; now near-universal: Qwen3, OLMo-2, Gemma-3); no biases
anywhere; pre-RMSNorm + SwiGLU + RoPE; **notably deep-and-thin** (0.6B =
28 layers × hidden 1024 vs our 12 × 768); GQA 16/8 even at 0.6B; tied
embeddings at all small sizes; BBPE vocab 151,669 even at 0.6B (a far larger
vocab-to-model ratio than ours — evidence our 32768 is already generous and
should not grow). Strong-to-weak distillation reportedly beats their own RL
at 1/10 the GPU-hours for smalls, but logit-KL needs tokenizer alignment
ours would break — sequence-level only, poor fit.

**Qwen3-Next / Qwen3.5 — independent convergence on our hybrid shape.**
Layout: 3:1 Gated-DeltaNet-to-full-attention (same ratio as ana and as Kimi
Linear — now a two-lab consensus, though contested: MiniMax retreated to
full attention, K2.5/GLM-5 stayed on MLA). The full-attention layers use
fewer, fatter heads (GQA 16/2, head dim 256), **partial RoPE (25% of head
dim)**, and a **sigmoid per-head output gate** (arXiv 2505.06708: removes
attention sinks and massive activations). **Zero-centered, weight-decayed
norm gains** (gain = 1 + w, w decayed to 0) after observing QK-Norm gain
drift in Qwen3 — a nearly-free stability fix portable to any scale. MTP head
for speculative decoding (skip at 115M — wrong cost profile on one GPU).
The hybrid survived into Qwen3.5 (Feb 2026, 397B-A17B) — the strongest
"not a one-off" signal short of external replication.

**GSPO** (RL, sequence-level importance ratios): not applicable until ana has
an RL phase, but noted: its robustness argument — sequence-level ratios
tolerate small per-token probability perturbations — is directly relevant to
our measured multicore nondeterminism, and its math is finite-support and
fully constructive (spec candidate, §4.2).

**Qwen verdicts for ana-next:** adopt QK-Norm (near-free, validated at 0.6B);
adopt zero-centered weight-decayed norm gains (near-free); test the sigmoid
attention-output gate (cheap, two-lab ablated); test deep-and-thin (18–24
layers at width 512–640 at fixed params) in the bpe10m pilot; keep vocab at
32768; keep embeddings tied unless the §1.2 A/B says otherwise; test NoPE on
the softmax layers (pairs with the GLA layers carrying recency); defer MoE,
MLA, MTP, GSPO, long-context tricks.

### 3.5 Meta

**MobileLLM (arXiv 2402.14905) — the single most actionable paper for our
scale**, because its whole design space is 125M/350M models. Four stacked
findings, all measured at our size: (1) **deep-and-thin wins** — across 19
models at fixed params, 30–42-layer thin models beat 12-layer wide ones on 8
zero-shot tasks; their 125M is **30 layers × dim 576** against our 12 × 768,
which puts ana squarely in the wide-shallow corner they argue against;
(2) **embedding tying** saves 11.8% of params for −0.2 accuracy, and
reinvesting in depth nets +0.4 — and at *our* vocab/dim the tying share is far
bigger (≈22%), so the lever is proportionally stronger for us than for them;
(3) GQA as width reduction is ~free at 125M; (4) **immediate block-wise layer
sharing** (run each block twice with shared weights) gives +0.7/+0.8 avg for
zero extra parameters, and immediate repetition beats repeat-all-over on
hardware because the weights are already in cache. Corroborated in spirit by
SmolLM2 and Qwen3-small converging on deep-thin + tied embeddings.
**Caveats before we act:** their 125M ate 1T tokens (≈8,000 tokens/param), so
gains bundle a data budget we may not match; and 30 thin layers means more,
smaller GEMMs — our MFU problem is kernel-efficiency-bound, so deep-thin
could make occupancy *worse*. Measure with the 5090 harness before committing.
Layer sharing is nearly free in Futhark (same kernel, same weights, twice) and
shrinks checkpoints — relevant to our memory-wall history.

**Llama 3 recipe** — two transferable facts. The **annealing probe**: to value
a candidate dataset, take a half-trained checkpoint and anneal LR to 0 over a
short run on 30% candidate / 70% default; the validation delta prices the
dataset for a few GPU-hours instead of a full retrain. That scales down
cleanly and composes with our plan-TSV fingerprints — adopt it as the corpus
A/B instrument. And **end-of-training LR anneal with quality upsampling** is
free to implement. Their scaling work also confirms the over-training posture
(8B trained to ~1,875 tokens/param, far past compute-optimal, because
inference cost dominates).

**Byte Latent Transformer (arXiv 2412.09871)** — architecturally the most
interesting thing in the sweep and economically wrong for us. Entropy-based
byte patching (boundary where next-byte entropy exceeds a threshold) with a
local encoder/decoder around a latent transformer over patches; patch size
becomes a compute dial that a fixed BPE vocab does not have. But the
BPE-crossover is ~150–400B training bytes, and the scheme needs a separate
100M-param entropy model — nearly ana's entire budget — and *adds* a neural
stage where our measured tokenizer cost is boxed-`[Int]` allocation, not
merges. **Skip the architecture; steal two cheap things**: hash n-gram
embeddings (n = 3–5) layered onto our BPE token embeddings for spelling
robustness, and entropy-based segmentation as an *analysis tool* over our own
corpus (we already have per-token CE) to find where BPE mis-allocates compute.
Its formal content is excellent and is queued in §4.2.

### 3.6 OpenAI (gpt-oss)

Architecture facts are verifiable from public weights: strict alternation of
one **banded sliding-window layer (window 128 — remarkably small)** with one
fully dense layer; GQA; **learned per-head attention-sink logits**; MXFP4 for
expert weights; YaRN to 131k; o200k_harmony tokenizer at 201,088 tokens.

**The one item to take now is the sink logit**: a learned scalar added to the
softmax denominator per head, equivalently a softmax over `scores ++ [sink]`
where the sink carries no value vector. Heads gain the ability to attend to
*nothing*, so total token attention mass is ≤ 1 instead of forced to 1. It is
one scalar per head, a one-line change to our softmax kernel, works at any
scale, and directly targets a small model's habit of dumping attention mass on
token 0. It also has the cleanest new spec statement in the whole sweep (§4.2).
The precedent (StreamingLLM) is independently replicated; OpenAI published no
ablation of their own.

Their window-128-with-every-other-layer-dense point is a useful calibration:
the analogy gpt-oss(window):gpt-oss(dense) ≈ ana(GLA):ana(softmax) suggests
that if we grow context, the softmax layers can have *small* support rather
than us needing more GLA layers. MXFP4 is serving-only and irrelevant while
models fit in VRAM.

**Data budget (Kaplan → Chinchilla → replications).** Chinchilla's ~20
tokens/param is the well-replicated result; Kaplan's contrary scaling is
attributed to un-tuned LR schedules and excluding embedding parameters — and
that exclusion matters *most* at our scale, where embeddings dominate.
Chinchilla-optimal for 115M is ~2.3B tokens; we are already past it, which is
correct. The governing rule for ana-next: **train until loss-per-GPU-hour
flattens, not to a token target**, with data quality as the binding constraint
(MobileLLM kept gaining to 1T tokens at 125M).

### 3.7 Google (Gemma 3 / Griffin)

**Griffin / RecurrentGemma (arXiv 2402.19427, 2404.07839) — our
architecture's closest published relative, and a cheap candidate fix for
§1.1.** The RG-LRU recurrence is entirely element-wise:

```
r_t = σ(W_a x_t + b_a) ;  i_t = σ(W_x x_t + b_x)
a_t = a^(c·r_t)  with a = σ(Λ) learned, c = 8
h_t = a_t ⊙ h_{t−1} + √(1 − a_t²) ⊙ (i_t ⊙ x_t)
```

Two details bear directly on our measured pathology (gates never open,
half-life ~0.8 tokens, and τ = 16 opened them but lost on loss). First, the
**c = 8 exponent** reshapes the gate's response curve so moderate
pre-activations already yield near-1 decay — long memory without driving the
gate pre-activation to extremes, which is a different intervention from our τ
sweep. Second, **√(1 − a_t²) couples input magnitude to decay**, so channels
that hold long memory are not swamped by fresh input — plausibly *why* their
gates can afford to open, and precisely the failure mode our τ = 16 arm would
have hit (open gates + unscaled input = interference, which shows up as worse
loss). They also put a **width-4 Conv1D before the recurrence** (cheap in
Futhark, gives the recurrence local n-gram context), and use **2:1
recurrence-to-attention where the attention is *local* (window 1024/2048)**,
not full.

Evidence is the strongest replication story for any linear-recurrence hybrid:
clean power-law scaling 100M→14B, Griffin-14B ≈ Llama-2 with ~7× fewer
tokens, and **RecurrentGemma-2B at 44.6 avg over 25 benchmarks vs Gemma-2B's
45.0** — parity in a *released, downloadable* model of the same family. Caveat:
parity is at 2B/2T tokens; at 115M the attention baseline is relatively
stronger (small models lean harder on exact-copy heads).

**This gives us two independent, complementary attacks on the gate problem,
and they differ enormously in cost:** the RG-LRU reparametrization is a
*formula change* in the existing GLA kernel (no new kernel, no new
algorithm), while KDA (§3.3) is a new chunkwise kernel. Try Griffin's
reparametrization first on that basis alone.

**Gemma 3 (arXiv 2503.19786)** — the ratio ablation is the valuable part:
varying local:global from 1:1 to **7:1 has minimal perplexity impact**, and
5:1 with window 1024 cuts KV overhead at 32K from ~60% to <15%. Since our GLA
layers are the "cheap layer" — with fixed-size state, even cheaper than a
1024 window — this is direct support for testing **5:1 and 7:1 GLA:softmax
arms**. Gemma 3 also **replaced Gemma 2's tanh logit soft-capping with
QK-norm** (cheaper, stabler, kernel-compatible) — a third independent lab
landing on QK-norm, reinforcing §3.4. Their 1B is 30% embedding parameters
with tying, mirroring our situation exactly. Gemma 3n's MatFormer/per-layer
embeddings solve a device-serving problem we don't have.

### 3.8 Mistral

Mistral 7B shipped sliding-window attention (window 4096, every layer) with a
rolling-buffer KV cache indexed `i mod w`; **Ministral 3B/8B** later moved to
*interleaved* 1 full : 3 windowed layers. Notably, Mistral **removed SWA in
v0.2/Small 3**, preferring dense attention for simpler fast kernels — an
honest counter-datapoint, as is Mistral Small 3's deliberately *wide-shallow*
shape (optimized for serving latency, not quality-per-param, which is the
opposite objective from MobileLLM's).

The durable lesson is the meta-fact, not any single design: **every lab
converged on "a few full-attention layers plus many cheap layers"** — Mistral
1:3, gpt-oss 1:1 at window 128, Gemma 1:5 at window 1024, Llama 4 1:3 chunked,
Griffin 1:2 recurrent, Kimi Linear and Qwen3-Next both 1:3 linear. Our 1:3
softmax:GLA already sits in this family, which is real (if indirect)
validation of the `kindOf` rule. The implementable nugget is the rolling-buffer
cache if we add windowed layers at context 4096.

### 3.9 Anthropic (transformer circuits)

**The mechanistic prediction that ties our own measurements together.**
The circuits framework reads a transformer as algebra on the residual stream:
each head factors into a QK circuit (where to attend) and an OV circuit (what
to move), and for attention-only models the logits decompose *exactly* into a
sum over paths. Two consequences bear on ana:

1. **One layer = bigram table + rank-factored skip-trigrams.** A one-layer
   attention-only model's logits are exactly `W_U W_E + Σ_h A^h ⊗ (W_U W_OV^h
   W_E)`. Because each head's contribution factorizes as
   `A(src,dst) · OV(src)`, a one-layer model **provably cannot express
   arbitrary trigram statistics** and must share OV outputs across all
   QK-matched sources. That is the same *shape* of impossibility result as our
   `TiedHead.agda` symmetry theorem, stated in the same vocabulary, and it is
   the natural next expressivity theorem for our spec.
2. **Induction heads need composition across two attention layers**, and
   in-context learning appears in a sharp phase change when they form (the
   "induction bump", widely reproduced). **A GLA layer whose state half-life is
   ~0.8 tokens is structurally incapable of induction** — prefix-matching over
   a repeated `[A][B]…[A]` needs content-addressed lookup far back, which a
   near-instantly-decaying state cannot provide. So in our 3:1 hybrid, the
   *three softmax layers carry all induction capacity*, and they must sit at
   depths that can compose (a previous-token head feeding a prefix-matching
   head). This yields two concrete, cheap actions for ana-next: **measure the
   induction bump and per-head prefix-matching scores** as a health metric, and
   **treat softmax-layer placement as a design variable**, not an artifact of
   `kindOf`'s arithmetic. It also gives an independent reason to fix the gates
   (§1.1): a longer half-life would let GLA layers participate rather than
   forcing all in-context machinery through three layers.

**Superposition** (toy models): at 768 dims with far more features than
dimensions, expect near-total polysemanticity — so "feature = direction, not
neuron" is the right spec stance, and per-neuron interpretation is a wrong
target. Mostly out of scope formally (the interesting results are
optimization-landscape and near-orthogonality arguments).

### 3.10 Cross-lab training science (optimizers, parametrization, schedules)

**muP / muTransfer** — the abc-parametrization makes optimal hyperparameters
width-independent, so you tune on a narrow proxy and transfer. Practical rules
for Adam: hidden matrices get init variance and LR ∝ 1/fan_in, embeddings stay
Θ(1), the readout gets a 1/n multiplier, and **attention logits scale by 1/d
rather than 1/√d**. Evidence: GPT-3 6.7B tuned via a 40M proxy at 7% of
pretraining cost; **independently replicated by Cerebras-GPT at 111M–2.7B**
(0.43% better Pile loss). For us this is the cheapest quality lever in the
whole document: sweep LR at width 128–192 for a few GPU-hours, transfer to
768. Caveat: transfer is across *width*; depth transfer is less settled, which
matters if we also pursue the deep-thin re-shape — do the width sweep at the
chosen depth.

**WSD schedules (warmup → long constant plateau → short decay) + branch-decay
+ checkpoint souping — the best-fit training-practice item here.** MiniCPM
and Hägele et al. report WSD matching or beating cosine, with the loss
dropping sharply *during* decay, and — the key operational trick — you can
**branch a decay off any plateau checkpoint** to get a scaling-law point from
a single run. MiniCPM also found high-quality data injected *strictly in the
decay phase* beats adding it afterward; OLMo 2 averages ("soups") checkpoints
from different data orders. We already checkpoint every 2000 steps, so this
converts our existing run mechanics into a measurement instrument almost for
free, and it composes with Llama 3's annealing probe (§3.5) as the corpus A/B
method. Note our own constraint: souping across data orders is natural on the
multicore backend, but any byte-exact test must stay on the sequential one.

**Optimizers**: Muon is covered in §3.3 and is now corroborated by three
independent labs plus the community speedrun; the extra detail worth keeping
is Moonshot's **RMS matching** (`0.2·√max(fan_in,fan_out)`) which is what lets
AdamW learning rates carry over unchanged, and GLM's **Muon-Split** (§3.2),
which says to orthogonalize per *logical* matrix — directly relevant to GLA's
factored projections. SOAP/Shampoo: affordable at 115M but Muon dominates on
simplicity; skip unless batches grow. Schedule-free AdamW won AlgoPerf's
self-tuning track and is attractive for open-ended runs, but WSD gives the
same anytime property *plus* the mid-training hooks we want.

### 3.11 Decoding and sampling theory

**min-p** — keep tokens with `p(x) ≥ p_base · p_max`, so the truncation
threshold scales with the model's own confidence: aggressive when peaked,
permissive when flat. This is a better-behaved truncation than fixed top-k for
exactly our situation (a small model with often-flat distributions over vocab
32768 — the measured `TOP_K=40` artifact of §1.3). Honest caveat: the ICLR
paper's headline quality gains **failed to replicate** in a follow-up study
("Min-p, Max Exaggeration"), so adopt it for its *structural* property, not
its claimed win. It is a day's work on top of `Decoding.agda` and comes with
three clean theorems (§4.2).

**Speculative decoding's exactness theorem** — the accept-reject scheme
(accept draft token with probability `min(1, p/q)`, else resample from the
normalized residual `(p − min(p,q))/(1−α)`) produces **exactly** the target
distribution, with acceptance rate `α = 1 − TV(p,q)`. The proof is two lines
of finite algebra. Notably `q` is universally quantified — the theorem doesn't
care where the draft came from (MTP head, smaller checkpoint, even an n-gram
model), which is what makes it worth formalizing once. One caveat to record in
the spec: the papers note exactness holds only "within hardware numerics", so
the Agda statement is the exact-arithmetic one with the float gap isolated as
an explicit assumption — the same discipline as our log-space gates.

**Attention sinks, formally**: `softmax₁(x)_i = e^{x_i}/(1 + Σ e^{x_j})` is
*exactly* softmax over `V ⊎ {∗}` with the adjoined element's logit fixed at 0,
restricted back to V. So softmax₁ outputs are **subdistributions with explicit
deficiency `1/(1+Z)`**, and adjoining ∗ restores our `total-mass ≡ 1#` law —
the sink is precisely where conserved mass goes. StreamingLLM pretrained
**160M-param models** showing a single dedicated learnable sink token suffices,
which is direct evidence at our scale. This also connects to §1.1 from a third
angle: sinks are the softmax-side mechanism for "do nothing", and our GLA
gates currently cannot express that either.

### 3.12 Prior art in formal verification (how this project is positioned)

Worth recording plainly: **there is no published Agda formalization of
attention, decoding, or language-model training, and nothing anywhere on
formalized sampling-exactness theorems.** The neighbours are:

- **Certigrad** (Lean, ICML 2017) — machine-checked proof that backprop on
  stochastic computation graphs yields unbiased gradient estimates; the
  classic end-to-end verified-training artifact.
- **TorchLean** (Lean 4, arXiv 2602.22631, 2026) — typed tensors, verified
  reverse-mode AD, semantic layers for attention/FlashAttention and SSMs, both
  exact and finite-precision tensor semantics. CUDA kernels stay outside the
  proofs at the FFI boundary — **exactly the gap our Futhark backend has**, and
  the closest prior art to what we are doing.
- **Compact Proofs of Model Performance** (Gross et al.) — computer-assisted
  accuracy bounds for 1-layer Max-of-K transformers; the interesting finding is
  that shorter proofs correlate with better mechanistic understanding.
- **CHAD / verified reverse-mode AD** (Vákár et al., POPL 2022 line) —
  denotational correctness proofs for reverse-mode AD, partially mechanized in
  Coq; the direct comparison for our `AD/Reverse.agda`.

The practical consequence: our decoding module already occupies genuinely
unclaimed ground, and the speculative-decoding exactness theorem (§4.2) would
be, as far as this survey found, a first.

### 3.13 Data and tokenizer science

**Vocabulary scaling sharpens §1.6 into an actual recommendation.** Tao et al.
(NeurIPS 2024) fit optimal vocabulary across 33M–3B and find optimal vocab
grows *slower* than model size, with most public models **over-vocab'd at the
small end**. At ~100M non-embedding parameters their fits put compute-optimal
vocabulary well below 32K — so ana's 32768 (≈22% of parameters in
embedding+unembedding) is vocab-heavy, and **16K is the scaling-law direction
for the output side**. This has to be traded against our own bpb-vs-throughput
measurements, and against the fact that changing vocabulary invalidates every
tokenizer fingerprint and corpus plan — so it belongs to a fresh run, not a
retrofit.

**Over-Tokenized Transformers** (ICML 2025) is the interesting counterpoint:
**decouple input vocabulary from output vocabulary**. Scaling the *input*
n-gram embedding table gives a log-linear loss improvement at ~zero FLOP cost
(a 400M model with a 12.8M-entry input vocab ≈ a 1B baseline, author-reported).
That is the same insight as Engram (§3.1) from a different direction — pay
memory, not compute, for capacity — and the two should be evaluated as one
family. Our constraint is real though: at 24 GB, memory *is* our binding axis
(the boxed-list wall), so any table size must be budgeted against the arena.

**FineWeb-Edu**'s durable contribution for us is methodological: every
filtering stage was ablated with fixed-compute proxy runs. Combined with WSD
branch-decay and the Llama 3 annealing probe, that is a complete, affordable
corpus-evaluation protocol we can run on one GPU.

**BPE theory** gives our tokenizer work a formal anchor: BPE is greedy
maximization of a compression utility (Zouhar et al.), the underlying optimal
pair-encoding problem is **APX-complete**, and BPE's worst-case compression is
within 0.333–0.625 of optimal (Kozma & Voderholzer) — the first unconditional
guarantees. For the spec, the useful pair is that `decode ∘ encode ≡ id` holds
(each merge is a concatenation homomorphism) while **`encode ∘ decode ≠ id`**
in general — encoding is a retraction, not an isomorphism, with equality
exactly on canonical tokenizations. That negative result is the formal root of
both spurious-tokenization bugs and GLM's TITO principle (§3.2).

---

## 4. Formal specification roadmap

Ranked by (value to the model we actually run) ÷ (Agda machinery required).
Everything must stay `--safe --without-K`; prefer semiring/list-level
statements; anything needing real analysis or order-completeness is out of
scope by policy (noted per item).

### 4.0 The organizing idea: one algebra of causal weighting schemes

The strongest structural suggestion out of the whole lab sweep is that
**every layer type any lab ships is an instance of one thing**: a causal
weighting scheme over the prefix. Softmax attention (exp kernel, full
support), windowed/chunked attention (support restriction), sink-augmented
attention (support extended by a ⊤ that carries no value), and gated linear
recurrence (full support, geometric product weights) all live in that single
algebra. `Attention/Linear.agda` already opens with exactly this framing —
"attention variants are one recurrent form … classified by the transition
family A_s" — so the move is to make the classification explicit and put the
other three instances beside GLA. The payoff is that hybrid ratios,
interleaving/receptive-field invariants, and the KV-state-size claims all
become statements *inside* one language, provable constructively with `exp`
abstracted as an arbitrary positive-valued function — no real analysis.

### 4.1 Done (this project)

- Autoregressive factorization with a finite mass law (`Distribution`,
  `total-mass ≡ 1#`).
- **GLA: chunkwise-parallel ≡ recurrent, already proved.**
  `Attention/Linear.agda` has `recurrent≡parallel` (the recurrent fold and
  the decayed-sum closed form are one function, pointwise, no funext),
  `runGLA-++`, `gateProd-++`, and `chunk-closed` (a chunk acts on the
  previous state through its own gate product and contribution alone). This
  is the theorem both research passes independently nominated as the prime
  target — we have it for the diagonal case, over a bare `Semiring`, and it
  is the semantic license for any chunked Futhark kernel.
- Linear attention as a fold / state algebra (`StateAlgebra`, `Packaged`,
  `Machine`), including `run-closed` tying the generic run to the closed form.
- Reverse-mode AD (the spec that caught the CE-pullback miscompile).
- Decoding: top-k/top-p as distribution transformers; mass-retention and
  no-floor theorems (`Language/Decoding.agda`).
- Tied-head Gram symmetry (`Transformer/TiedHead.agda`).
- Stochastic residual mixing: mass conservation, closure, n = 1 rigidity
  (`Transformer/ResidualStream.agda`).

### 4.2 Next candidates, tiered

**Tier 1 — do these next; each is small, constructive, and load-bearing.**

**(a) Speculative-decoding exactness.** Given finite `p` (target) and `q`
(draft) over the vocabulary: sample `x ~ q`, accept with probability
`min(1, p(x)/q(x))`, else resample from `(p − min(p,q))/(1−α)` where
`α = Σ min(p,q)`. Theorem: the result is distributed exactly as `p`. The proof
is two lines of finite algebra —
`q(x)·min(1,p(x)/q(x)) + (1−α)·r(x) = min(p(x),q(x)) + (p(x) − min(p(x),q(x)))
= p(x)` — and the division-free formulation states it as the measure
decomposition `p = min(p,q) + (p−q)⁺`, `q = min(p,q) + (q−p)⁺`, with the
theorem as a pushforward equality. Everything lives in the existing
`Distribution` record over ℚ. Corollary worth having: acceptance rate
`α = 1 − TV(p,q)`. Record the float gap as an explicit assumption. **This is
the highest value-per-effort item in the document, and per §3.12 it would be
the first formalization of a sampling-exactness theorem anywhere.**

**(b) min-p as a distribution transformer.** Keep `{x : p(x) ≥ p_base·p_max}`,
renormalize. Three theorems, all direct extensions of `Decoding.agda`:
*nonemptiness* — the argmax always survives (since `p_base ≤ 1`), so
renormalization is total and there is no division-by-zero edge case, unlike
top-p; *mass retention* — retained mass ≥ `p_max`; *monotonicity and
conservativity* — the kept set shrinks as `p_base` grows, and `p_base = 0` is
the identity. Plus a counterexample lemma: min-p and top-p refine each other
in neither direction.

**(c) Attention sinks: `softmax₁ ≅ softmax over V ⊎ {∗}` with the adjoined
logit fixed at 0, restricted to V.** Pure algebra (`e⁰ = 1`), no analysis.
Consequences: softmax₁ yields *subdistributions* with explicit deficiency
`1/(1+Z)`; token mass = 1 − sink mass ≤ 1; the sink logit at zero weight
recovers ordinary attention (conservativity); renormalization recovers a
distribution iff token mass ≠ 0. This connects our mass-conservation results
(`ResidualStream.agda`, `Distribution`) to a concrete architecture change
worth trying at 115M (§3.6), and it is one lemma.

**(d) Delta-rule linear attention at Ring level (the KDA/DeltaNet
generalization).**
   `Attention/Linear.agda` already flags this: diagonal transitions keep every
   transition product diagonal, "which is why this module needs only scalar
   semiring algebra and no matrix products; the delta rule `(I − βkkᵀ)` needs
   subtraction and is future Ring-level work." That is precisely the §3.3
   architecture candidate, so the spec work and the model work are the same
   decision. Scope: a `Ring`-parameterized module with genuine matrix
   transitions, re-proving `recurrent≡parallel`/`chunk-closed` via the
   monoid action `(A,B)∘(A′,B′) = (A A′, A B′ + B)` — associativity of that
   action is the whole theorem, and it covers GLA and KDA uniformly.
   Stretch goal: **WY-representation exactness** —
   `∏_t (I − β_t k_t k_tᵀ) ≡ I − Σ_t w_t k_tᵀ` for the intra-chunk `w`
   recurrence — which is the correctness statement of the fast kernel itself
   and is division-free (unit lower-triangular solve = forward substitution).
**(e) BPE round-trip, canonicity, and prompt normalization.**
`decode ∘ encode ≡ id` holds by induction over merges (each merge is a
concatenation homomorphism), while **`encode ∘ decode ≠ id`** in general:
encoding is a *retraction, not an isomorphism*, with equality exactly on
canonical (greedy-merge-normal-form) sequences. That characterization is the
formal root of spurious-tokenization bugs, is the reason GLM built TITO
(§3.2), appears not to be formalized publicly, and gives our plan-TSV
fingerprint tests a semantic anchor. Bundle two companions: the
trailing-whitespace prompt hazard (§1.3) stated formally, and BPE's
**non-prefix-stability** (appending a byte can retokenize earlier text) as a
counterexample lemma — which contrasts with BLT-style entropy patching, where
`concat (seg xs) ≡ xs` is definitional and the monotonic rule *is*
prefix-stable.

**Tier 2 — worth doing when the corresponding design decision comes up.**

**(f) Support-restriction attention + receptive-field reachability.** Windowed
attention as `S(i) = {j ≤ i | i − j < w}`, chunked as an equivalence-class
restriction, DSA-style top-k as an arbitrary selected support. Theorems:
conservativity (`w ≥ n ⇒ windowed ≡ dense`, and `k ≥ length prefix ⇒ sparse
≡ dense` — the regression-test-shaped statements); monotonicity in `w`;
**masked-softmax restriction** (softmax over a filtered list = the renormalized
restriction of the full softmax to the same index set — the identity that makes
"sparse = dense restricted to a support" *mean* something, and it is pure
algebra with `exp` abstracted as any positive weight function); the layered
receptive-field induction (`L` stacked window-`w` layers ⇒ `i` depends on `j`
iff `i − j < L(w−1)+1`); and top-k's invariance under monotone score
transformations. The rolling-buffer KV cache (`i mod w`) is then a data
refinement — exactly the shape our spec-vs-Futhark methodology exists for.

**(g) Skip-trigram factorization and induction-impossibility** (§3.9). The
one-layer decomposition `logits = W_U W_E + Σ_h A^h ⊗ (W_U W_OV^h W_E)` is an
exact identity provable from linearity of embed/unembed plus head additivity.
The *informative* theorem is the representability limit: each head's
contribution factorizes as `A(src,dst) · OV(src)`, so a rank-factored
skip-trigram ensemble cannot express arbitrary trigram statistics. The stretch
goal — "no rank-factored skip-trigram ensemble computes the induction map on
sequences containing novel token pairs" — is finite, combinatorial, and to
this survey's knowledge **never formalized**. It is the natural sequel to
`TiedHead.agda`, in the same vocabulary.

**(h) Untied-head expressivity**: the constructive converse of `TiedHead.agda`
— an untied head *can* represent a given skew bigram preference (a witness
construction). Pairs the existing impossibility proof with a possibility proof
and fully grounds the untying decision (§1.2).

**(i) Engram locality and collision semantics** (if we pilot §3.1's hashed
n-gram memory). The module is a pure function of the last N tokens:
*locality* — `takeLast N c₁ ≡ takeLast N c₂ → engram c₁ ≡ engram c₂`; hash
determinism; and a precise **collision semantics** — with multi-head hashing
the retrieved value is `Σ_h table_h[hash_h(ngram)]`, so two n-grams collide in
the full module iff they collide in *every* head. All finite maps, fully
constructive, and it turns a vague "mitigates collisions" claim into a
statement.

**Tier 3 — cheap lemmas that come free with whatever we adopt.**

- **MLA absorption exactness** (even though we skip MLA): `(W_UK c)ᵀ(W_Q h) =
  cᵀ((W_UKᵀ W_Q) h)` — associativity — states that the absorbed-matrix
  inference path is bit-identical to the materialize-keys training path in
  exact arithmetic. This is our "hoist before hand-writing" lemma class, and
  the **negative companion** is the real design theorem: absorption fails when
  a position-dependent rotation intervenes, which is *why* MLA needs decoupled
  RoPE keys.
- **RMSNorm scale-invariance** (`N(cx) = N(x)` for positive `c`, statable via
  the squared form over an ordered field) and the **zero-centered-gain
  reparametrization equality** (§3.4): a definitional equality worth having
  once we decay `w` but not `g`.
- **Newton-Schulz intertwining** if we adopt Muon: for any polynomial `q`,
  `q(AAᵀ)·A = A·q(AᵀA)` by induction, associativity only — the honest
  constructive core. With an SVD supplied as a *hypothesis*, `p(UΣVᵀ) =
  U p(Σ) Vᵀ` for odd `p`, plus orthogonal equivariance `NS(AMB) = A·NS(M)·B`.
  Convergence of singular values to 1 needs analysis — explicitly out of scope.
- **QK-Clip bilinear rescaling** (hypothesis-form, no square roots): logits are
  bilinear in `(W_q, W_k)`, so scaling by `(c,d)` scales every logit by `c·d`;
  hence any `c·d·S_max ≤ τ` bounds the recomputed logits. Plus the locality
  statement that the rescale touches nothing else in the forward pass.
- **RoPE relative-position identity** `⟨R^i q, R^j k⟩ = ⟨R^{i−j} q, k⟩` over
  formal rotations constrained by `c² + s² = 1` — no trigonometry, instantiable
  over ℚ via Pythagorean triples — and **NoPE permutation-invariance** (a NoPE
  head's output depends only on the *multiset* of prefix (k,v) pairs) if we
  test NoPE per §3.3.
- **muP abc-symmetry**: for scale-invariant optimizers the computed function is
  invariant under `(a,b,c) ↦ (θa, b/θ, c/θ)` (Adam) — per-step induction, pure
  algebra, the precise sense in which "parametrizations are equivalence
  classes". Needs an abstract optimizer interface first. The muP *limit*
  theorem is a width→∞ Gaussian-process result — **out of scope**.
- **Two-level accumulation** (the FP8 spec, if we ever quantize for CPU
  inference): `sum xs ≡ sum (map sum (chunk n xs))` — a list homomorphism,
  exact in a commutative monoid, and the exact-arithmetic correctness statement
  of "inner folds in low precision, outer fold exactly".
- **MoE gate/selection separation** (only with a MoE arm): the bias influences
  the selected index set but never the weights, so the output stays a weighted
  sum with renormalized original affinities; plus `length (topk k xs) ≡ min k
  (length xs)` as the cardinality conservation law.
- **Importance-sampling unbiasedness and the "bias ledger"** (only with RL):
  finite-support `Σ q·(p/q)·f = Σ p·f`, then clipping breaks it by a
  finite, explicitly-expressible sum over clipped elements — the formal frame
  for why IcePop/GSPO-style corrections exist. Group-advantage lemmas
  (`Σ A_i = 0`, shift invariance, scale equivariance) come free; use the
  mean-centered variant, since σ-normalization drags in square roots.

---

## 5. Pilot protocol for ana-next decisions

Every candidate change earns its place the same way:

1. **A/B at bpe10m scale** (~10M params, hours on the 3090), matched data via
   plan-TSV fingerprints, sequential backend for byte-exact reproducibility.
2. **Loss gap vs. seed-noise floor** — a change must beat the measured noise
   of its own metric (for generation metrics: ≥8 seeds, medians, the ~0.047
   rep1 floor).
3. **Element-wise kernel verification** against the Agda-specified semantics
   before any GPU run (the CE-pullback lesson).
4. **Memory-traffic budget** stated up front: reads/writes per token vs. the
   n = 1 baseline, because the backend is memory-bound.
5. Spec first where a spec is cheap: if the change has theorem-shaped
   content, the Agda module lands before or with the implementation.

---

## 6. The ranked plan

Synthesis across all of the above. The ordering weights *evidence at our
actual scale* above everything else, because that is the axis on which most
frontier results fail us.

### 6.1 Adopt — evidence exists at or near 100M

1. **Muon** (with Moonshot's RMS matching, keeping embeddings/head/norms on
   AdamW, and GLM's Muon-Split for factored projections). Three labs in
   production plus a community-replicated speedrun *at d = 768, 124M params*.
   ~30 lines over existing GEMM primitives, <1% FLOP overhead, and it attacks
   our binding constraint directly: fewer steps to equal loss on an 8-day
   budget.
2. **muP-style LR transfer**: sweep at width 128–192 for a few GPU-hours, then
   transfer. Independently replicated at 111M–2.7B by Cerebras. Do the sweep at
   whatever depth we settle on, since transfer is across width.
3. **WSD schedule with branch-decay and decay-phase data splicing.** Nearly
   free given we already checkpoint every 2000 steps, and it converts the run
   itself into a scaling-law and corpus-evaluation instrument.
4. **QK-Norm** on the softmax layers (Qwen3 at 0.6B, Gemma 3, GLM, OLMo 2 —
   four independent adopters) plus **zero-centered weight-decayed norm gains**.
5. **Keep embeddings tied** (they already are — README, `Config.hs`, and
   `TiedHead.agda` exists because of it): at our vocab × dim tying holds
   ~22% of parameters, proportionally a bigger lever than MobileLLM's 11.8%.
   The open decision is *untying* (§1.2) — run the `head-probe HEAD_TIE=0/1`
   A/B first so the decision is measured rather than assumed.
6. **Learned per-head sink logits** (or softmax₁): one scalar per head, a
   one-line softmax change, with 160M-scale evidence from StreamingLLM and the
   cleanest accompanying theorem in the document.

### 6.2 Fix the GLA gates — three independent attacks, cheapest first

This is the highest-value model-quality work, and the sweep produced three
distinct mechanisms. Try them in cost order:

1. **RG-LRU-style reparametrization** (§3.7): the `a^(c·r)` response curve with
   `c = 8`, plus `√(1−a²)` input scaling so open gates don't cause
   interference. A *formula change inside the existing kernel* — no new
   algorithm — and it directly explains why our τ = 16 arm opened gates but
   lost on loss.
2. **Delta rule** (§3.3, KDA/Gated DeltaNet): move erasure into
   `(I − β k kᵀ)` so decay no longer has to do the forgetting. More powerful,
   two-lab validated at 3:1, but a genuinely harder chunkwise Futhark kernel.
   Its spec work and its implementation are the same decision (§4.2(d)).
3. **Gate initialization by distillation** (§3.1, generalizing DSA's dense
   warm-up): freeze the model and train the gates to imitate the softmax
   layers' attention distribution by KL. Cheap, and attacks the problem from
   initialization rather than parametrization.

Also test **NoPE on the softmax layers** (Kimi Linear's finding) — it pairs
naturally with gates carrying recency, and it *deletes* code from those layers.

### 6.3 Experiment — mechanism is scale-free but unvalidated at 100M

Each of these would be a genuine contribution either way, since nobody
publishes at our scale:

- **Engram-style hashed n-gram memory** (§3.1) / **decoupled input vocabulary**
  (§3.13) — evaluate as one family. FLOP-free capacity for a
  memorization-starved trunk, a pure gather in Futhark, works at context 256.
  Budget the table against the arena, since memory is our weak axis.
- **Deep-and-thin re-shape** (18–24 layers at width 512–640 at fixed
  parameters). MobileLLM at 125M and GLM at frontier scale agree on the
  direction; Mistral Small is the honest counter-datapoint (different
  objective). **Measure MFU first** — more, smaller GEMMs may hurt occupancy
  on our kernel-bound backend.
- **MTP as an auxiliary loss** (§3.1, parameter-shared per GLM-5). Unpublished
  at 115M dense; older work put gains at ≥3B, so calibrate expectations.
- **Hybrid ratio arms at 5:1 and 7:1** (Gemma 3's ratio ablation was flat to
  7:1) — but see §3.9: the softmax layers carry *all* induction capacity, so
  removing them has a mechanistic cost the perplexity curve may hide. Measure
  prefix-matching scores, not just loss.
- **Layer sharing** (MobileLLM-LS): free parameters, smaller checkpoints,
  trivial in Futhark.

### 6.4 Skip, with reasons

MLA (context too short; GQA dominates here), DSA/NSA/IndexShare/CSA/HCA (pay
only at ≥16–32K context), mHC (§2.1), FP8 (no hardware or Futhark path, and we
are shape-bound not FLOP-bound), MXFP4/quantization (serving-only), BLT (the
BPE crossover is ~150B+ bytes and it needs a 100M-param entropy model — steal
only hash n-gram embeddings), DualPipe/EPLB/slime-scale infrastructure
(multi-node problems), MoE routing (until a tiny-MoE arm exists), RL
(GRPO when the time comes, not before), and long-context machinery generally
(YaRN/DCA/ABF) until context exceeds 4096.

### 6.5 Two project strengths worth stating explicitly

- **Determinism as an advantage.** DeepSeek and Z.ai both treat "π_infer ≠
  π_train as executed programs" as a first-class RL problem (off-policy
  masking, IcePop clipping). Our byte-exact sequential backend makes that
  problem vanish by construction.
- **Unclaimed formal ground.** There is no published Agda formalization of
  attention, decoding, or LM training, and nothing anywhere on formalized
  sampling-exactness. `Decoding.agda` already sits on novel territory, and
  §4.2(a) would extend it.

---

## 7. Sources

Project-internal: `docs/PAPER-2512.24880-FINDINGS.md`,
`docs/PAPER-2604.07242-FINDINGS.md`, `docs/RUN-2026-07-25-WIKI-FULL.md`,
`run/generation-samples.md` (gitignored), memory notes 2026-07/08.

All external numbers are **author-reported unless marked replicated** in the
text above. Retrieved 2026-08-16.

**DeepSeek**: [mHC 2512.24880](https://arxiv.org/abs/2512.24880) ·
[V2/MLA 2405.04434](https://arxiv.org/abs/2405.04434) ·
[V3 (MTP, FP8, DualPipe) 2412.19437](https://arxiv.org/abs/2412.19437) ·
[V3.2/DSA 2512.02556](https://arxiv.org/abs/2512.02556) ·
[V4 2606.19348](https://arxiv.org/abs/2606.19348) ·
[Engram 2601.07372](https://arxiv.org/abs/2601.07372) ·
[aux-loss-free routing 2408.15664](https://arxiv.org/abs/2408.15664) ·
[GRPO/DeepSeekMath 2402.03300](https://arxiv.org/abs/2402.03300) ·
[NSA 2502.11089](https://arxiv.org/abs/2502.11089)

**Z.ai / GLM**: [GLM-4.5 2508.06471](https://arxiv.org/abs/2508.06471) ·
[GLM-5 2602.15763](https://arxiv.org/abs/2602.15763) ·
[GLM-5.2 card](https://huggingface.co/zai-org/GLM-5.2) ·
[SAO 2607.07508](https://arxiv.org/abs/2607.07508) ·
[slime](https://github.com/THUDM/slime)

**Moonshot / Kimi**: [Kimi Linear / KDA 2510.26692](https://arxiv.org/abs/2510.26692) ·
[K2 / MuonClip 2507.20534](https://arxiv.org/abs/2507.20534) ·
[Muon is Scalable 2502.16982](https://arxiv.org/abs/2502.16982) ·
[Muon original](https://kellerjordan.github.io/posts/muon/) ·
[K1.5 2501.12599](https://arxiv.org/abs/2501.12599) ·
[fla kernels](https://github.com/fla-org/flash-linear-attention)

**Qwen**: [Qwen3 2505.09388](https://arxiv.org/abs/2505.09388) ·
[Qwen3-Next card](https://huggingface.co/Qwen/Qwen3-Next-80B-A3B-Instruct) ·
[gated attention 2505.06708](https://arxiv.org/abs/2505.06708) ·
[GSPO 2507.18071](https://arxiv.org/abs/2507.18071) ·
[Qwen2.5-1M/DCA 2501.15383](https://arxiv.org/abs/2501.15383)

**Meta**: [Llama 3 2407.21783](https://arxiv.org/abs/2407.21783) ·
[BLT 2412.09871](https://arxiv.org/abs/2412.09871) ·
[MobileLLM 2402.14905](https://arxiv.org/abs/2402.14905) ·
[Coconut 2412.06769](https://arxiv.org/abs/2412.06769) ·
[Llama 4 / iRoPE](https://huggingface.co/blog/llama4-release)

**OpenAI / Google / Mistral**:
[gpt-oss 2508.10925](https://arxiv.org/abs/2508.10925) ·
[Gemma 3 2503.19786](https://arxiv.org/abs/2503.19786) ·
[Griffin/Hawk 2402.19427](https://arxiv.org/abs/2402.19427) ·
[RecurrentGemma 2404.07839](https://arxiv.org/abs/2404.07839) ·
[Mistral 7B 2310.06825](https://arxiv.org/abs/2310.06825) ·
[Ministral](https://mistral.ai/news/ministraux/)

**Theory, optimizers, schedules**:
[muP / TP-V 2203.03466](https://arxiv.org/abs/2203.03466) ·
[u-muP 2407.17465](https://arxiv.org/abs/2407.17465) ·
[Cerebras-GPT 2304.03208](https://arxiv.org/abs/2304.03208) ·
[μ-transfer study 2404.05728](https://arxiv.org/abs/2404.05728) ·
[SOAP 2409.11321](https://arxiv.org/abs/2409.11321) ·
[Schedule-Free 2405.15682](https://arxiv.org/abs/2405.15682) ·
[MiniCPM/WSD 2404.06395](https://arxiv.org/abs/2404.06395) ·
[WSD analysis 2405.18392](https://arxiv.org/abs/2405.18392) ·
[OLMo 2 2501.00656](https://arxiv.org/abs/2501.00656)

**Decoding and attention theory**:
[speculative decoding 2211.17192](https://arxiv.org/abs/2211.17192) ·
[Chen et al. 2302.01318](https://arxiv.org/abs/2302.01318) ·
[min-p 2407.01082](https://arxiv.org/abs/2407.01082) ·
[min-p critique 2506.13681](https://arxiv.org/abs/2506.13681) ·
[typical sampling 2202.00666](https://arxiv.org/abs/2202.00666) ·
[StreamingLLM 2309.17453](https://arxiv.org/abs/2309.17453) ·
[softmax-off-by-one](https://www.evanmiller.org/attention-is-off-by-one.html) ·
[why attend to first token 2504.02732](https://arxiv.org/abs/2504.02732) ·
[linear attention 2006.16236](https://arxiv.org/abs/2006.16236) ·
[GLA 2312.06635](https://arxiv.org/abs/2312.06635) ·
[DeltaNet 2406.06484](https://arxiv.org/abs/2406.06484) ·
[Gated DeltaNet 2412.06464](https://arxiv.org/abs/2412.06464)

**Formal verification prior art**:
[TorchLean 2602.22631](https://arxiv.org/abs/2602.22631) ·
[Certigrad](https://proceedings.mlr.press/v70/selsam17a/selsam17a.pdf) ·
[Compact Proofs 2406.11779](https://arxiv.org/abs/2406.11779)

**Anthropic**:
[transformer circuits framework](https://transformer-circuits.pub/2021/framework/index.html) ·
[induction heads](https://transformer-circuits.pub/2022/in-context-learning-and-induction-heads/index.html) ·
[superposition](https://transformer-circuits.pub/2022/toy_model/index.html)

**Data and tokenizers**:
[FineWeb 2406.17557](https://arxiv.org/abs/2406.17557) ·
[vocab scaling 2407.13623](https://arxiv.org/abs/2407.13623) ·
[Over-Tokenized 2501.16975](https://arxiv.org/abs/2501.16975) ·
[BPE formal perspective 2306.16837](https://arxiv.org/abs/2306.16837) ·
[BPE APX-completeness 2411.08671](https://arxiv.org/abs/2411.08671)
