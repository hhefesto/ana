# Cloud fast path — train `bpe10m`, pull weights, kill the instance ASAP

Goal: spend the **least paid GPU time** to train `bpe10m` on a rented GPU and get
the weights onto your local machine, then destroy the instance. The model is
~10 M params, the checkpoint is tiny (~120 MB), and all CPU-heavy prep (tokenizer
+ corpora + plan) is done locally. CUDA is pinned to **12.6** in `flake.nix`;
`cloud-init.sh` builds the host from that closure using only the box's kernel
driver.

Primary provider below is **vast.ai** (Docker containers). The **Verda** VM path
is identical except for the two notes marked *(Verda)*.

The one rule that saves the most money: **DESTROY** the instance when done (not
"stop"), and pull milestone snapshots so the weights are always safe at home.

---

## 0. Prerequisites (local — done, no spend)

- **Tokenizer**: `~/datasets/wikipedia-en/enwiki-8k.bpe` ✅
- **Plan + corpora**: `run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv` (1,465 segments)
  ✅ plus all 1,465 `shard-<k>-bpe10m.corpus` (~9.3 GB) ✅
- **CUDA host builds locally** ✅ (`nix build .#formal-transformer-cuda`, RPATH
  clean, links CUDA 12.6). No GPU needed to build.

> **This run: full dataset (all 1,465 shards), benchmark-gated.** Transfer all
> corpora, run the whole plan (`MAX_SHARDS` unset), and pull the checkpoint as
> **milestone snapshots — one per 1/4 of the corpus** via `pull-stages.sh` (§4).
> Those let you watch the model sharpen and double as eviction insurance.
> *Cheaper alt:* transfer the first `N` shards and set `MAX_SHARDS=N`.

---

## 1. Rent the instance (vast.ai)

- **GPU** — interruptible offers churn, so pick live by **highest FP32 TFLOPS/$
  with Max CUDA ≥ 12.6** (not vast's tensor-weighted DLPerf), restricted to
  **Ada (RTX 40xx, sm_89) or Ampere (RTX 30xx, sm_86)**. Good examples:
  **RTX 3090 / 3090 Ti (~$0.13/hr, 24 GB, reliable)**, **RTX 4070 Ti / 4080 /
  4090** (fastest FP32). Whole run ≈ $1–2. Need <1 GB VRAM, so don't pay up for
  memory.
  - **NEVER Blackwell** (RTX 50xx, "RTX PRO … Blackwell", compute cap ≥ 10.0):
    the gradient kernel compiles but **hangs** there (verified 2026-07-15 on an
    RTX PRO 4000; `cloud-init.sh` refuses these, `step-gate.sh` catches them).
  - **Avoid sub-12.6 hosts** (Max CUDA 12.0/12.2/12.4) — they reject our PTX.
  - Old datacenter cards (Tesla T4, sm_75) are *compatible* but poor value:
    ~3× the $/FP32-TFLOP of a 3090 and many times the wall-clock.
- **Template**: any CUDA/Ubuntu image that exposes the NVIDIA runtime (the vast
  "NVIDIA CUDA" or a PyTorch template is fine — we build our own CUDA via Nix and
  only use the box's driver). **Container disk ≥ 50 GB.**
- **Persistence (optional):** mount a vast **volume** and put `/nix` + the repo on
  it so an interruption costs nothing. Otherwise a fresh instance just re-runs
  `cloud-init.sh` (~min from cache) and resumes from the last pulled snapshot.
- **SSH key**: vast.ai → *Account → Keys* → paste `~/.ssh/xpsoasis-ed25519.pub`
  (`hhefesto@olimpo`). vast injects it as `root`.

After it boots, vast shows an SSH command like `ssh -p 41234 root@ssh5.vast.ai`.
Capture host + port locally:

```bash
INSTANCE=root@ssh5.vast.ai          # from vast's SSH line
PORT=41234                          # from vast's SSH line
SSH_E="ssh -p $PORT -i ~/.ssh/xpsoasis-ed25519"
```

*(Verda)* Instead: image `Ubuntu 24.04 + CUDA 12.6`, GPU `RTX 6000 Ada spot`, no
startup script; `INSTANCE=ubuntu@<ip>` and `SSH_E="ssh -i ~/.ssh/xpsoasis-ed25519"`
(no `-p`).

---

## 2. Transfer the SMALL stuff — overlap it with the build

Do **not** transfer the 9.3 GB of corpora yet: first prove the GPU actually
runs the kernel (§3). Last attempt we shipped everything to a box whose GPU
couldn't train at all.

**Terminal A — code + plan + tokenizer + shard 0 only (~10 MB, seconds):**

```bash
cd ~/src/formalTransformer
rsync -az --info=progress2 -e "$SSH_E" --exclude .git --exclude run --exclude result \
  ./ "$INSTANCE:formalTransformer/"
ssh -p "$PORT" -i ~/.ssh/xpsoasis-ed25519 "$INSTANCE" \
  'mkdir -p formalTransformer/run/wiki-bpe10m ~/datasets/wikipedia-en'
rsync -az -e "$SSH_E" run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv \
  run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$INSTANCE:formalTransformer/run/wiki-bpe10m/"
rsync -az -e "$SSH_E" ~/datasets/wikipedia-en/enwiki-8k.bpe \
  "$INSTANCE:datasets/wikipedia-en/"
```

**Terminal B — build the host (runs while Terminal A copies):**

```bash
ssh -p "$PORT" -i ~/.ssh/xpsoasis-ed25519 "$INSTANCE"
# on the instance:
cd formalTransformer
./deploy/cloud-init.sh
```

`cloud-init.sh` detects VM vs container, installs Nix (single-user in a
container), builds `formal-transformer-cuda`, guards stub leaks, resolves
`libcuda.so.1` (setting `LD_LIBRARY_PATH` if needed, persisted to
`run/cloud-env.sh`), and runs `inspect bpe10m`. It never trains.

> Note the instance's home: on vast it's `/root`, so the tokenizer lands at
> `~/datasets/wikipedia-en/enwiki-8k.bpe` and the repo at `~/formalTransformer`.

---

## 3. Gate + benchmark (cents — BEFORE the 9.3 GB transfer and the full run)

**Step gate first** — one hard-capped training step on shard 0. On a bad arch
the kernel compiles yet hangs with the GPU pegged at 100%; the gate turns that
into a ≤3-minute verdict:

```bash
# on the instance, in formalTransformer/
./deploy/step-gate.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
# PASS -> continue below.  rc=124 -> DESTROY the instance, rent Ada/Ampere.
```

**Then benchmark:**

```bash
# on the instance, in formalTransformer/
TRAIN_BATCH=8 MICRO_BATCH=1 BENCH_STEPS=5 FUT_CACHE=run/futhark-cuda.cache \
  ./deploy/benchmark-cuda.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
# run a SECOND time (same FUT_CACHE) for steady-state tokens/s (first pays NVRTC)
```

- **PTX rejected / JIT error?** The host driver is older than 12.6 expects (you
  picked a sub-12.6 host). Rent a Max-CUDA-≥12.6 host, or pin the flake lower
  (`cudaPackages_12_6` → `cudaPackages_12_4`), rebuild, and re-run the
  conformance oracle before trusting it (`docs/CLOUD-TRAINING.md`).
- **Tune `MICRO_BATCH`** up (2/4/8) — headless GPU, no display watchdog; result
  is equation-equal, pure throughput.
- **Project cost:** `global_total=$(awk 'NR==1{print $3}'
  run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv)`;
  `hours = global_total * 8 * 255 / tokens_per_sec / 3600`;
  `cost = hours * <your $/hr>`. Proceed only if `cost + storage` is within budget.

**Gate passed and cost approved → now ship the corpora** (local terminal, the
one long transfer, ~9.3 GB):

```bash
cd ~/src/formalTransformer
rsync -az --info=progress2 -e "$SSH_E" run/wiki-bpe10m/shard-*-bpe10m.corpus \
  "$INSTANCE:formalTransformer/run/wiki-bpe10m/"
```

---

## 4. Train the full plan + pull milestone snapshots

**On the instance** (under `tmux`), `MAX_SHARDS` unset = whole plan:

```bash
tmux new -s train
cd formalTransformer
TOKENIZER_FILE="$HOME/datasets/wikipedia-en/enwiki-8k.bpe" \
TRAIN_BATCH=8 MICRO_BATCH=<tuned> CHECKPOINT_EVERY=100 \
FUT_CACHE=run/futhark-cuda.cache \
  ./deploy/train-cloud.sh          # detach: Ctrl-b then d
```

`train-cloud.sh` sources `run/cloud-env.sh` (libcuda path), drives `train-segment`
per shard from the plan (no JSONL), preserves the exact global schedule, and
marks each shard `*.done`.

**On your LOCAL machine** (separate terminal — one snapshot per 1/4 of corpus):

```bash
cd ~/src/formalTransformer
SSH_PORT="$PORT" ./deploy/pull-stages.sh "$INSTANCE"
```

Watches the `*.done` markers and writes
`run/wiki-bpe10m-global.stage-<k>of4.checkpoint` at ~25/50/75/100%, exiting after
the last. *(Verda: drop `SSH_PORT`.)* For a plain interval pull instead:
`SSH_PORT="$PORT" ./deploy/pull-checkpoint.sh "$INSTANCE" <seconds>`.

---

## 5. Stop the meter — destroy the instance

When `train-cloud.sh` reports all shards done, `pull-stages.sh` has the final
`stage-4of4`. Belt-and-braces final pull (also grabs `.best`):

```bash
rsync -az -e "$SSH_E" \
  "$INSTANCE:formalTransformer/run/wiki-bpe10m-global.checkpoint"* run/
```

Then in the vast.ai console **DESTROY** the instance (not "stop"), and delete the
volume if you don't want to keep it. Billing → zero.

**Cost-zeroing checklist:** instance destroyed ✔ · volume deleted (if unused) ✔.

---

## 6. Test locally — no GPU

Checkpoints are backend-portable; the CPU host reads the CUDA-trained weights.
`wiki-generate` auto-picks the newest `run/*.checkpoint`:

```bash
cd ~/src/formalTransformer
WIKI_TOKENIZER=~/datasets/wikipedia-en/enwiki-8k.bpe \
WIKI_PROMPT="The theory of" WIKI_TOKENS=128 nix run .#wiki-generate
# compare an earlier stage:
WIKI_CHECKPOINT=run/wiki-bpe10m-global.stage-1of4.checkpoint \
WIKI_TOKENIZER=~/datasets/wikipedia-en/enwiki-8k.bpe \
WIKI_PROMPT="The theory of" nix run .#wiki-generate
```

`inspect-checkpoint` on a pulled file confirms its global step and
model/tokenizer/dataset identities.

---

## Resume later (optional)

Rent again, re-run `cloud-init.sh`, transfer any missing shards, re-run
`train-cloud.sh`: it skips `*.done` shards and `train-segment` continues from the
checkpoint's exact global Adam step — moments and LR schedule intact. Keep
`run/wiki-bpe10m/` on a persistent volume to make interruptions free.
