# Cloud Training

## Selected Target

The next model is the intermediate `bpe10m` preset:

```text
vocabulary: 8192
context: 256 BPE tokens
model dimension: 320
feed-forward dimension: 864
layers: 6
heads: 5
parameters: 10,059,840
```

Its tokenizer identity includes the `fastbpe-word-v1` pretokenization
algorithm and a SHA-256 digest of the canonical merge table. A corpus or
checkpoint made with another 8192-token table is incompatible by design.

## Provider Choice

For an experimental budget below USD 50, start with one Verda spot RTX 6000
Ada. One fast GPU is intentional: the current host is single-device, and this
model fits comfortably in 48 GB. Renting a multi-GPU instance before Tier-2
gradient reduction exists would pay for idle devices.

Rates observed on 2026-07-11:

| Provider and GPU | VRAM | Spot/on-demand rate | Time for USD 50 |
|---|---:|---:|---:|
| Verda RTX 6000 Ada spot | 48 GB | USD 0.364/h | 137 h |
| Verda A100 SXM spot | 80 GB | USD 0.6265/h | 79 h |
| Verda H100 SXM spot | 80 GB | USD 1.14/h | 43 h |
| Runpod RTX 6000 Ada | 48 GB | USD 0.77/h | 64 h |
| Runpod A100 PCIe 80 GB | 80 GB | USD 1.39/h | 35 h |

Sources: [Verda pricing](https://verda.com/pricing) and
[Runpod pricing](https://www.runpod.io/pricing). Prices and availability are
dynamic; verify them before creating an instance.

The A100 is preferable only if an exact training benchmark is at least 1.72
times faster than the 6000 Ada. Benchmark dollars per processed token rather
than advertised tensor FLOPS: this implementation currently uses Futhark `f32`
kernels and does not silently switch to mixed-precision tensor cores.

**Kernel constraint (2026-07-15): the bpe10m gradient kernel is currently too
slow to train on ANY GPU.** On an RTX PRO 4000 Blackwell (sm_120) and again on
an RTX 3090 Ampere (sm_86) the Futhark-generated gradient kernel compiles but
one training step does not finish in >17 min with the GPU pegged at 100% and a
warm kernel cache — the same signature on two unrelated architectures, so the
cause is the generated vjp kernel at bpe10m scale, not the card. Do not rent
until the kernel fix lands (see `HANDOFF.md`). `cloud-init.sh` still refuses
compute capability ≥ 10.0 as untested unless `ALLOW_UNTESTED_ARCH=1`, and
`deploy/step-gate.sh` proves one real step completes before any large transfer
or training spend — on every arch.

## Nix On The Rented Box (VM or container)

Two supported targets. **Verda (VM):** use the `Ubuntu 24.04 + CUDA 12.6` image
(not Minimal, which ships no driver; the `+ Docker` variant is unnecessary).
**vast.ai (container):** rent any CUDA/Ubuntu container template that exposes the
NVIDIA runtime and reports `Max CUDA ≥ 12.6`. Either way, keep the box's kernel
driver, install Nix for all userspace dependencies, and build the pinned CUDA
closure from this flake — safer than replacing a working driver.

`flake.nix` pins the CUDA userspace to **12.6** (`cudaPackages_12_6`): its PTX
is accepted by the widest range of rental-host drivers (most vast.ai hosts
advertise Max CUDA 12.6 or 12.8, few 12.9+), and its NVRTC targets every arch
we allow (Ada sm_89, Ampere sm_86, and older — not Blackwell, which the guard
treats as untested).
The step-by-step minimum-cost runbook is `deploy/cloud-fast-path.md`;
`deploy/cloud-init.sh` brings an instance up — it auto-detects a VM (multi-user
Nix) vs a Docker container (single-user `--no-daemon` Nix, `sandbox = false`) —
and `deploy/train-cloud.sh` trains per-shard from the pre-built plan without
needing the source JSONL on the box.

The CUDA package links against the toolkit's `libcuda` stub only during the Nix
build. Its runtime RPATH contains `/run/opengl-driver/lib` for NixOS plus the
Nix CUDA runtime/NVRTC libraries, but no stub directory. On Ubuntu,
`libcuda.so.1` resolves from the provider driver's loader configuration; in a
container, `cloud-init.sh` sets `LD_LIBRARY_PATH` to the nvidia-runtime-injected
lib dir when the default loader path misses it (persisted to `run/cloud-env.sh`).

```bash
./deploy/cloud-init.sh   # (deploy/bootstrap-ubuntu-nvidia.sh is the older Verda-only variant)
```

The provider driver must support CUDA 12.6-era PTX because Futhark compiles its
embedded CUDA through NVRTC at context creation; any `Max CUDA ≥ 12.6` host
satisfies this. If a benchmark still rejects the PTX (older driver than
advertised), pin lower — `cudaPackages_12_4` is available in this nixpkgs —
rebuild, and re-run the conformance oracle before trusting the new backend
build; do not bundle a mismatched kernel driver into the flake. Never pin below
the GPU's arch support (NVRTC then fails with "invalid --gpu-architecture").

## Whole-Dataset Contract

Whole-Wikipedia mode now performs a planning pass before step one. The plan
records every shard's exact corpus identity, global document offset, train and
validation window counts, local update count, and cumulative step endpoints.
Training then uses:

- one checkpoint for the complete dataset;
- one AdamW first and second moment trajectory;
- one global learning-rate schedule;
- global-index document splitting invariant under physical shard boundaries;
- segment-local deterministic epoch order;
- compact `u16` corpus and `f32` checkpoint wires;
- atomic checkpoints and shard markers.

`TRAIN_BATCH` is semantic for this run and is included in the plan identity.
`MICRO_BATCH`, `CHECKPOINT_EVERY`, `FUT_BLOCK_SIZE`, and `FUT_DEVICE` remain
execution controls.

Prepare the plan and retain compact tokenized corpora locally before renting:

```bash
WIKI_SIZE=bpe10m \
WIKI_TOKENIZER="$HOME/datasets/wikipedia-en/enwiki-8k.bpe" \
TRAIN_BATCH=8 \
WIKI_PLAN_ONLY=1 \
WIKI_KEEP_CORPORA=1 \
nix run .#wiki-train
```

This is CPU-intensive. Retained completed corpus shards are reused if planning
is restarted, while the final plan itself is published only after every shard
record has been validated. Do not run two planners against the same
`WIKI_RUN_DIR` concurrently.

Transfer the repository, the 6.6 GB compressed Wikipedia JSONL (or its
decompressed source), the BPE artifact, the plan, and retained corpora to a
persistent cloud volume. Verify their SHA-256 hashes before starting paid GPU
training.

## Benchmark Gate

On each candidate GPU, run the same corpus and settings:

```bash
TRAIN_BATCH=8 MICRO_BATCH=1 BENCH_STEPS=5 \
./deploy/benchmark-cuda.sh run/wiki/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
```

Repeat once with the same `FUT_CACHE` to separate cold NVRTC compilation from
steady-state training. Increase `MICRO_BATCH`, then `TRAIN_BATCH`, only while
memory and throughput improve.

Reserve USD 3 for these tests. Start the full run only if:

```text
projected hours * hourly GPU rate + storage < USD 47
```

The plan header gives `global_total` updates. Each full update processes
`TRAIN_BATCH * 255` target tokens. Use measured steady-state tokens/second to
project completion. If the projection exceeds the cap, stop the instance and
optimize the kernel rather than spending through the budget.

## Launch

```bash
WIKI_BACKEND=cuda \
WIKI_SIZE=bpe10m \
WIKI_TOKENIZER="$HOME/datasets/wikipedia-en/enwiki-8k.bpe" \
TRAIN_BATCH=8 \
MICRO_BATCH=1 \
CHECKPOINT_EVERY=100 \
FUT_CACHE=run/futhark-cuda.cache \
nohup nix run .#wiki-train >> run/wiki-bpe10m.log 2>&1 &
```

Spot eviction can happen without warning. Keep the plan and tokenized corpora
on a persistent volume and synchronize the compact global checkpoint off the
instance periodically. An interrupted segment resumes from the checkpoint's
global Adam step without resetting moments or the schedule.
