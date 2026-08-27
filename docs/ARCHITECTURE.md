# ana — the whole model, end to end

Everything below is the `bpe460m` (v4) configuration:
`Config 32768 1024 1280 3456 20 20 GateRgLru True True True`
= **463,084,260 parameters**. Where v2/v3 differ, they are noted.

---

## 1. Data pipeline

```
  Wikipedia + FineWeb-Edu             Hackage 19,418 pkgs, mathlib4, lean4,
  interleaved 3:2, 9,700,651 docs     agda-stdlib, cubical, agda, idris2,
  36.38 GB  (run/mixed-corpus.jsonl)  nixpkgs, 23 hhefesto repos
            |                                     |
            |                          extract-code.sh
            |                          . permissive license only (2,641 dropped)
            |                          . dedup by sha256 (6.8% dropped)
            |                          . whole projects held out for eval
            |                                     |
            |                          270,054 docs / 1.8 GB
            |                          88% Haskell, 8% Lean, 3% Nix,
            |                          1% Agda, 0.4% Idris
            |                                     |
            +--------------- PHASE A -------------+------- PHASE B ------->
            |                                     |
            v                                     v
   +------------------+                  +------------------+
   |   pack-stdin     |  concatenate short documents to ~128 KB, blank-line
   |  (FT.Pack)       |  separated; --group keeps a pack inside one repo
   +------------------+
            |            WHY: fullWindows discards any document shorter than
            |            one window. At ctx 1024, 79.7% of documents yield
            |            NOTHING and only 51.6% of bytes survive. Packing
            |            takes that to ~98%: 1.92x the training windows.
            v
   +------------------+
   | BPE  code32k.bpe |  32,768 pieces, pretokenization rule v2
   |                  |  (a run of spaces is ONE word, so a 4-space indent
   |                  |   can become one token instead of four forever)
   +------------------+
            |            bytes/token: Haskell 4.06  Nix 3.80  Agda 3.16
            |                         Lean 3.59  Idris 2.96  prose 4.55
            v
   +------------------+
   |   fullWindows    |  non-overlapping windows of exactly 1024 tokens,
   |   BOS .. EOS     |  remainder discarded; 90/10 train/val split by a
   +------------------+  hash of document POSITION (not content)
            |
            v
      ~7.6B tokens (Phase A)  +  ~0.47B tokens of code (Phase B)
```

---

## 2. The stack

```
   token ids [1024]
        |
        v
  +-----------------------------------+
  | embedding   [32768 x 1280]        |  41,943,040 params
  +-----------------------------------+
        |
        v
  ####################################################################
  #  20 blocks, interleaved 3:1  --  layer i is SOFTMAX iff i%4 == 3 #
  ####################################################################
        |
   L0  GLA  ---+
   L1  GLA     |
   L2  GLA     |  15 x GLA block      21,466,880 each = 322,003,200
   L3  SOFTMAX |   5 x SOFTMAX block  19,827,348 each =  99,136,740
   L4  GLA     |
   L5  GLA     |
   L6  GLA     |
   L7  SOFTMAX |
   L8  GLA     |
   L9  GLA     |
   L10 GLA     |
   L11 SOFTMAX |
   L12 GLA     |
   L13 GLA     |
   L14 GLA     |
   L15 SOFTMAX |
   L16 GLA     |
   L17 GLA     |
   L18 GLA     |
   L19 SOFTMAX-+
        |
        v
  +-----------------------------------+
  | final_rms   [1280]                |  1,280 params
  +-----------------------------------+
        |
        v
  +-----------------------------------+
  | TIED head: reuse embedding^T      |  0 extra params
  +-----------------------------------+
        |
        v
   logits [1024 x 32768]   <-- the largest activation in the model, twice
```

---

## 3. Inside a block

Both kinds share the same shell — pre-norm, residual, SwiGLU — and differ
only in how the token mixer works.

```
        x  [1280]
        |
        +--------------------------------------+
        |                                      |
        v                                      |
   rms_att [1280]   RMSNorm with a learned gain|
        |                                      |
        v                                      |
   +===========================+               |
   |   TOKEN MIXER (below)     |               |  residual
   +===========================+               |
        |                                      |
        +------------------(+)-----------------+
                            |
        +-------------------+------------------+
        |                                      |
        v                                      |
   rms_ff [1280]                               |
        |                                      |
        v                                      |
   +---------------------------+               |
   | SwiGLU                    |               |  residual
   |   gate = Wgate x  [3456]  |               |
   |   up   = Wup   x  [3456]  |               |
   |   h    = silu(gate) * up  |               |
   |   out  = Wdown h  [1280]  |               |
   +---------------------------+               |
        |                                      |
        +------------------(+)-----------------+
                            |
                            v
                         x' [1280]
```

### 3a. GLA mixer — 15 of 20 layers

Gated Linear Attention: a **linear recurrence with a data-dependent
per-channel forget gate**. No softmax, no O(n^2) score matrix; state is a
fixed 64x64 matrix per head, so cost is linear in context.

```
   q = Wq x   k = Wk x   v = Wv x        [1280] -> 20 heads x 64
   z = Walpha x                          the gate projection [1280 x 1280]

   RG-LRU gate, per channel c:
        log a = 8 * sigmoid(z_c) * log sigmoid(lambda_c)     (capped <= -1e-4)
        a     = exp(log a)                in (0, 1)
        beta  = sqrt(1 - a^2)             write scale

   recurrence, per head, S is [64 x 64]:
        S_t = diag(a_t) . S_{t-1}  +  (beta_t k_t) v_t^T
        o_t = q_t . S_t

   computed CHUNKWISE at chunk 64 (64 divides 1024), which is
   algebraically identical to the scan -- Linear.agda proves
   recurrent == parallel and chunk-closed.
```

> The `-1e-4` cap is load-bearing. `sqrt(1-a^2)` is not Lipschitz at a=1:
> its derivative diverges, and in f32 the pullback became a literal 1/0.
> That produced a **finite loss with an infinite gradient**, and
> `clip_global_norm` passed it through because `NaN > max_norm` is False.

### 3b. Softmax mixer — 5 of 20 layers

```
   q = Wq x   k = Wk x   v = Wv x        20 heads x 64

   qk-norm:   q_hat = rms(q) * qk_gain_q      [64]
              k_hat = rms(k) * qk_gain_k      [64]

   scores = q_hat . k_hat^T / sqrt(64)   causal mask
            + ONE EXTRA SLOT per head: sink[head]
   attention = softmax(scores)           the sink absorbs probability mass,
   o = attention . v                     letting a head attend to nothing

   NO POSITIONAL ENCODING (NoPE).
```

> Position is carried entirely by the GLA gates: a data-dependent
> transition subsumes a rotation. This is why context 1024 is a plain
> config change and no parameter slice depends on context at all --
> `contextSize` is deliberately NOT part of `Layout.core`, so a checkpoint
> warm-starts across context lengths.
>
> **Untested at 1024.** NoPE is measured only at 256. The Milestone 1
> ablation decides it, and RoPE on these 5 layers is the contingency.

---

## 4. Per-block parameter budget

```
  GLA block                              SOFTMAX block
  ---------------------------------      ---------------------------------
  rms_att       [1280]        1,280      rms_att      [1280]        1,280
  Wq,Wk,Wv,Wo   [1280^2] x4 6,553,600    Wq,Wk,Wv,Wo  [1280^2]x4 6,553,600
  Walpha        [1280^2]  1,638,400      qk_gain_q    [64]             64
  gate_lambda   [1280]        1,280      qk_gain_k    [64]             64
                                         sink         [20]             20
  rms_ff        [1280]        1,280      rms_ff       [1280]        1,280
  Wgate,Wup   [3456x1280]x2 8,847,360    Wgate,Wup  [3456x1280]x2 8,847,360
  Wdown       [1280x3456]   4,423,680    Wdown      [1280x3456]   4,423,680
                          -----------                           -----------
                           21,466,880                            19,827,348

  embedding 41,943,040  +  15x21,466,880  +  5x19,827,348  +  1,280
                                                    = 463,084,260
```

---

## 5. Training

```
  +----------------------------------------------------------------+
  |  RANK 0  (GPU 0)              |   RANK 1  (GPU 1)              |
  |  CUDA_VISIBLE_DEVICES=0       |   CUDA_VISIBLE_DEVICES=1       |
  |  own FUT_CACHE                |   own FUT_CACHE                |
  |                               |                                |
  |  local batch 32 of the        |   local batch 32, the          |
  |  global 64                    |   disjoint half                |
  |         |                     |          |                     |
  |    forward + reverse-mode AD  |    forward + reverse-mode AD   |
  |         |                     |          |                     |
  |    Muon   on matrices (cols>1)|    same                        |
  |    AdamW  on vectors/embedding|                                |
  |         |                     |          |                     |
  +---------|---------------------+----------|---------------------+
            |                                 |
            +--- every H=30 steps ------------+
                          |
                 theta_bar = (theta_0 + theta_1) / 2    fixed rank order,
                 delta     = theta_prev - theta_bar     so both ranks are
                 m         = 0.9 m + delta              BIT-IDENTICAL
                 theta_new = theta_prev - 0.7(delta + 0.9 m)   [Nesterov]
                          |
            +-------------+-------------+
            |                           |
        rank 0 writes checkpoints   rank 1 never does
        (~7.4 GB, ~35 GB host RSS)  (two saves = ~70 GB)
```

Only **parameters** cross between ranks; inner optimizer moments stay local.
Exchange is via files in `/dev/shm`, written temp-then-rename so presence
implies completeness. A missing peer **kills the run** rather than silently
continuing at half the effective batch.

> Two GPUs give **throughput, not memory**. Data parallelism replicates the
> model per device, so 463M plus Muon state must fit on ONE card: nine
> parameter-sized f32 buffers = 16.7 GB before a single activation.

---

## 6. Where it stands

```
   model          v1  10.6M   8k vocab   ctx 256    enwik8  1.994 bpb
                  v2   115M  32k vocab   ctx 256    enwik8  1.337 bpb
                  v3   115M  32k vocab   ctx 256    enwik8  1.450 bpb  (2.2% trained)
                  v4   463M  32k vocab   ctx 1024   <- not yet trained

   target    GPT-2-small                            enwik8  1.16  bpb
```

The gap is **0.18 bpb**, not the 0.83 the project notes carried for a month:
that figure belonged to the 8k-vocab era, and no eval corpus matched the 32k
training tokenizer until one was built.
