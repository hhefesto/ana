# Cloud fast path — train `bpe10m`, pull weights, kill the instance ASAP

> **STATUS (2026-07-17): ACTIVE TRAINING on an RTX 5070.** CUDA 12.9 targets
> Blackwell sm_120; the stock production gradient is 57.9 ms per sequence and
> real updates saturate the GPU at 97-100%. A 200-step `MICRO_BATCH=1` benchmark
> reached 1,575 target tokens/s including startup/final-checkpoint overhead;
> steady updates are about 0.45-0.50 s. Autotuning was harmful and is rejected.

Goal: spend the **least paid GPU time** to train `bpe10m` on a rented GPU and get
the weights onto your local machine, then destroy the instance. The model is
~10 M params, the checkpoint is tiny (~120 MB), and all CPU-heavy prep (tokenizer
+ corpora + plan) is done locally. CUDA is pinned to **12.8** in `flake.nix`
(keep the pin at or below the rental driver's Max CUDA);
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
  clean, links CUDA 12.8). No GPU needed to build.

> **This run: full dataset (all 1,465 shards), benchmark-gated.** Transfer all
> corpora, run the whole plan (`MAX_SHARDS` unset), and pull the checkpoint as
> **milestone snapshots — one per 1/4 of the corpus** via `pull-stages.sh` (§4).
> Those let you watch the model sharpen and double as eviction insurance.
> *Cheaper alt:* transfer the first `N` shards and set `MAX_SHARDS=N`.

---

## 1. Rent the instance (vast.ai)

- **GPU** — interruptible offers churn, so pick live by **highest FP32 TFLOPS/$
  with Max CUDA >= 12.8** (not vast's tensor-weighted DLPerf). Ampere, Ada, and
  Blackwell are supported. Good examples:
  **RTX 3090 / 3090 Ti (~$0.13/hr, 24 GB, reliable)**, **RTX 4070 Ti / 4080 /
  4090**, and **RTX 5070** (measured working). The full run is projected around
  $30-35 on a $0.104/h 5070. Need only about 1.2 GB VRAM.
  - **Avoid hosts below the flake's CUDA pin (12.8)** — the driver PTX JIT may
    reject newer PTX than it advertises.
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

*(Verda)* Instead: use an image/driver advertising CUDA 12.8+, no
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

## 3. Profile + gate + benchmark (BEFORE the 9.3 GB transfer)

**Profile first.** This runs the production gradient entry over seven tractable
shapes, with named reports under `run/cuda-profile/`; no corpus is needed:

```bash
# on the instance, in formalTransformer/
./deploy/profile-cuda.sh ladder
# Optional experiment; trust only an independently faster repeat:
./deploy/profile-cuda.sh autotune
./deploy/profile-cuda.sh ladder
```

Inspect `run/cuda-profile/cuda-grad-ladder.prof/`, especially each `.summary`
and `.timeline`, for the dominant kernel and its grid/block dimensions. Do not
run the full shape until this ladder is viable. The explicit command is
`ALLOW_FULL_PROFILE=1 ./deploy/profile-cuda.sh full`; it is guarded because
`futhark bench` runs the case three times.

Autotuning is not intrinsically trustworthy. On the RTX 5070 it made six of
seven relevant shapes slower (up to 30x), so stock scheduling was retained.

**Then step gate.** It first creates the CUDA context under a five-minute cap,
populating `FUT_CACHE` without training, then runs one warm-cache step under a
separate three-minute cap:

```bash
# on the instance, in formalTransformer/
./deploy/step-gate.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
# PASS -> continue below. rc=124 -> preserve the ladder report and stop;
# it is a scheduling verdict, not a universal GPU-architecture conclusion.
```

**Then benchmark:**

```bash
# on the instance, in formalTransformer/
VALIDATION_WINDOWS=1 TRAIN_BATCH=8 MICRO_BATCH=1 BENCH_STEPS=200 \
  FUT_CACHE=run/futhark-cuda.cache \
  ./deploy/benchmark-cuda.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
# run a second time to confirm steady-state tokens/s
```

- **PTX rejected / JIT error?** The host driver is older than the flake's CUDA
  pin expects.
  Rent a host at or above the pin, or deliberately pin lower only for a pre-Blackwell
  GPU, rebuild, and re-run the
  conformance oracle before trusting it (`docs/CLOUD-TRAINING.md`).
- **Tune `MICRO_BATCH` only by measurement.** On the RTX 5070, `1` beat `8`
  (1,575 versus 1,329 end-to-end target tokens/s).
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
TRAIN_BATCH=8 MICRO_BATCH=1 CHECKPOINT_EVERY=2000 \
VALIDATE_EVERY=2000 VALIDATION_WINDOWS=1 \
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

## Tensor-core (cuBLAS) variant

To run the decomposed cuBLAS trainer instead of the fused Futhark one, build it
during bring-up with `BUILD_GEMM_CUDA=1 ./deploy/cloud-init.sh` (lands in
`result-gemm/`), pass the build/training gates in `docs/TENSOR-CORE-RUNTIME.md`
(`./result-gemm/bin/cuda-blas-test`, then one tiny train per numerics mode),
and only then point training at it:

```bash
TRAINER=result-gemm/bin/formal-transformer-gemm-cuda GEMM_NUMERICS=tf32 \
  ./deploy/train-cloud.sh
```

`GEMM_NUMERICS` (`fp32`|`tf32`|`bf16`) is checkpointed as the run's numeric
interpretation; resume rejects a mismatch, so keep one checkpoint per mode.

---

## Resume later (optional)

Rent again, re-run `cloud-init.sh`, transfer any missing shards, re-run
`train-cloud.sh`: it skips `*.done` shards and `train-segment` continues from the
checkpoint's exact global Adam step — moments and LR schedule intact. Keep
`run/wiki-bpe10m/` on a persistent volume to make interruptions free.
