# Verda fast path — train `bpe10m`, pull weights, kill the instance ASAP

Goal: spend the **least paid GPU time** to get a testable `bpe10m` checkpoint
onto your local machine, then destroy the instance. The design already makes
this cheap: the model is ~10M params, the checkpoint is tiny (~120 MB), and all
CPU-heavy prep (tokenizer + corpora + plan) is done locally beforehand. CUDA is
pinned to **12.6** in `flake.nix` to match Verda's image driver.

The one rule that saves the most money: **destroy** the instance when done, do
not just "stop" it — and pull the checkpoint continuously so you can destroy at
any moment.

---

## 0. Prerequisites (local, already in progress — no spend)

- **Tokenizer**: `~/datasets/wikipedia-en/enwiki-8k.bpe` ✅ (exists)
- **Plan + corpora**: produced by the planning resume into `run/wiki-bpe10m/`.
  It finishes as `run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv` plus one
  `shard-<k>-bpe10m.corpus` per shard. Wait for this before renting.
- **CUDA host builds locally** ✅ (already verified: `nix build .#formal-transformer-cuda`,
  RPATH clean, links CUDA 12.6). Nothing GPU-specific is needed to build.

> **This run: full dataset (all 1,465 shards), benchmark-gated.** Transfer all
> corpora and let `train-cloud.sh` run the whole plan (`MAX_SHARDS` unset). The
> checkpoint is pulled home as **milestone snapshots — one per 1/4 of the corpus
> (~25/50/75/100%)** — via `deploy/pull-stages.sh` (§4/§5). Those let you watch
> the model sharpen across training and double as eviction insurance.
>
> *Cheaper alternative, if you ever want it:* transfer only the first `N` shards
> and set `MAX_SHARDS=N` for a partial, testable checkpoint; stopping early is
> safe and resumes from its exact global step later.

---

## 1. Create the instance

- **Image**: `Ubuntu 24.04 + CUDA 12.6` — **not** Minimal (no driver), and you
  do **not** need the `+ Docker` variant (we run Nix on the host).
- **GPU**: RTX 6000 Ada **spot** ($0.364/h observed) — best $/token for this f32,
  non-tensor-core workload. (A100 is *slower and pricier* here; see
  `docs/CLOUD-TRAINING.md`.) Spot is fine: we snapshot at each quarter and
  `train-cloud.sh` resumes from the checkpoint's exact global step.
- **SSH key**: paste your public key
  `~/.ssh/xpsoasis-ed25519.pub` (comment `hhefesto@olimpo`).
- **Startup script**: leave empty. Bring-up is `verda-init.sh`, run
  interactively so you *see* the driver/PTX/linkage checks.

Set a shell var locally once the instance is up:

```bash
INSTANCE=ubuntu@<instance-ip>       # or root@<ip>, per Verda
```

---

## 2. Transfer — overlap it with the build (do both at once)

**Terminal A — code + plan + tokenizer (small, seconds):**

```bash
cd ~/src/formalTransformer
# code only (exclude .git, run/, result symlink)
rsync -az --info=progress2 --exclude .git --exclude run --exclude result \
  ./ "$INSTANCE:formalTransformer/"

ssh "$INSTANCE" 'mkdir -p formalTransformer/run/wiki-bpe10m ~/datasets/wikipedia-en'

# plan + tokenizer
rsync -az run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv \
  "$INSTANCE:formalTransformer/run/wiki-bpe10m/"
rsync -az ~/datasets/wikipedia-en/enwiki-8k.bpe \
  "$INSTANCE:~/datasets/wikipedia-en/"
```

**Terminal A — all corpora (~10 GB, the one long transfer):**

```bash
cd ~/src/formalTransformer
rsync -az --info=progress2 run/wiki-bpe10m/shard-*-bpe10m.corpus \
  "$INSTANCE:formalTransformer/run/wiki-bpe10m/"
```

**Terminal B — build the CUDA host (runs while corpora copy):**

```bash
ssh "$INSTANCE"
# on the instance:
cd formalTransformer
./deploy/verda-init.sh
```

`verda-init.sh` prints the driver's CUDA level (must be ≥ 12.6), installs Nix,
builds `formal-transformer-cuda`, verifies no stub leak, and runs `inspect
bpe10m` (proves `libcuda.so.1` resolves). It never trains.

---

## 3. Benchmark gate (cents — do this before any long run)

```bash
# on the instance, in formalTransformer/
TRAIN_BATCH=8 MICRO_BATCH=1 BENCH_STEPS=5 FUT_CACHE=run/futhark-cuda.cache \
  ./deploy/benchmark-cuda.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
# run it a SECOND time (same FUT_CACHE) to get steady-state tokens/s
# (first run pays one-time NVRTC PTX compilation)
```

- **PTX rejected / JIT error?** The driver is older than 12.6 expects. Pin the
  flake lower: change `cudaPackages_12_6` → `cudaPackages_12_4` in `flake.nix`
  (12.4 is present in this nixpkgs), rebuild, re-benchmark. Per
  `docs/CLOUD-TRAINING.md`, re-run the conformance oracle before trusting a new
  backend build.
- **Tokens/s good?** Try `MICRO_BATCH=2,4,8` — a headless datacenter GPU has no
  display watchdog, so larger micro-batches amortize launch overhead. The result
  is equation-equal; it's a pure throughput knob.
- **Project cost** (full run): each of the plan's `global_total` updates
  processes `TRAIN_BATCH*255` tokens.
  `hours = global_total * 8 * 255 / tokens_per_sec / 3600`;
  `cost = hours * 0.364`. Only start the full run if `cost + storage < ~$47`.
  Read `global_total` from the plan header:
  `awk 'NR==1{print $3}' run/wiki-bpe10m/plan-bpe10m-b8-s4000.tsv`.

---

## 4. Train the full plan + pull milestone snapshots

**On the instance** (under `tmux` so an SSH drop doesn't kill it), `MAX_SHARDS`
unset = the whole plan:

```bash
tmux new -s train
cd formalTransformer
TOKENIZER_FILE="$HOME/datasets/wikipedia-en/enwiki-8k.bpe" \
TRAIN_BATCH=8 MICRO_BATCH=<tuned> CHECKPOINT_EVERY=100 \
FUT_CACHE=run/futhark-cuda.cache \
  ./deploy/train-cloud.sh
# detach: Ctrl-b then d
```

`train-cloud.sh` drives `train-segment` per shard from the plan (no JSONL
needed), preserving the exact global schedule, and marks each shard `*.done`.

**On your LOCAL machine** (separate terminal — snapshot every 1/4 of the
corpus, so you keep milestone weights and survive eviction):

```bash
cd ~/src/formalTransformer
SSH_KEY=~/.ssh/xpsoasis-ed25519 ./deploy/pull-stages.sh "$INSTANCE"
```

It watches the `*.done` markers and pulls
`run/wiki-bpe10m-global.stage-<k>of4.checkpoint` at ~25/50/75/100%, exiting after
the final one. (For a plain interval pull instead, `deploy/pull-checkpoint.sh
"$INSTANCE" <seconds>` is still available.)

---

## 5. Stop the meter — destroy the instance

When `train-cloud.sh` reports all shards done, `pull-stages.sh` has already
pulled the final `stage-4of4` snapshot and exited. As a belt-and-braces final
pull (and to grab `.best`):

```bash
rsync -az -e 'ssh -i ~/.ssh/xpsoasis-ed25519' \
  "$INSTANCE:formalTransformer/run/wiki-bpe10m-global.checkpoint"* run/
```

Then in the Verda console **DESTROY / TERMINATE** the instance (not "stop").
Also delete any attached volume you no longer need. Billing should go to zero.

**Cost-zeroing checklist:** instance destroyed ✔ · volume deleted (if unused) ✔
· no lingering spot reservation ✔.

---

## 6. Test locally — no GPU

Checkpoints are backend-portable, so the CPU host reads the CUDA-trained weights
directly. `wiki-generate` auto-picks the newest `run/*.checkpoint` and reads the
BPE tokenizer from `WIKI_TOKENIZER`:

```bash
cd ~/src/formalTransformer
WIKI_TOKENIZER=~/datasets/wikipedia-en/enwiki-8k.bpe \
WIKI_PROMPT="The theory of" WIKI_TOKENS=128 \
  nix run .#wiki-generate
```

You can also inspect the checkpoint metadata (`inspect-checkpoint`) to confirm
its global step, model, tokenizer, and dataset identities.

---

## Resume later (optional, to keep training)

Bring the instance back (or a new one), re-run `verda-init.sh`, transfer the
next batch of shards, and re-run `train-cloud.sh`. It skips `*.done` shards and
`train-segment` continues from the checkpoint's exact global Adam step — moments
and LR schedule intact. Keep `run/wiki-bpe10m/` (plan + corpora + markers) on a
persistent volume if you want eviction to cost nothing.
