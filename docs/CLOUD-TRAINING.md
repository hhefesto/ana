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

For an experimental budget below USD 50, use one high-FP32 GPU with a driver
advertising CUDA 12.8+. One fast GPU is intentional: the host is single-device,
and measured peak device use is only about 1.2 GB. Renting a multi-GPU instance
before Tier-2 gradient reduction exists would pay for idle devices.

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

**Measured result (2026-07-17): CUDA training works on an RTX 5070 Blackwell.**
With CUDA 12.9, the stock full `bpe10m` production gradient takes 57.9 ms per
sequence and real updates sustain 97-100% GPU utilization. The previous A4000
low-occupancy result does not reproduce. A harmful autotune file was rejected;
stock scheduling is the measured configuration.

## Nix On The Rented Box (VM or container)

Two supported targets. **Verda (VM):** use an image advertising CUDA 12.8+
(not Minimal, which ships no driver; the `+ Docker` variant is unnecessary).
**vast.ai (container):** rent any CUDA/Ubuntu container template that exposes the
NVIDIA runtime and reports `Max CUDA >= 12.8`. Either way, keep the box's kernel
driver, install Nix for all userspace dependencies, and build the pinned CUDA
closure from this flake — safer than replacing a working driver.

`flake.nix` pins CUDA userspace to **12.8** (`cudaPackages_12_8`), which targets
Ampere, Ada, and Blackwell sm_120. Since Futhark JIT-compiles PTX through NVRTC,
the provider driver must advertise CUDA 12.8 or newer (>= the pin).
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

The provider driver must support CUDA 12.8-era PTX because Futhark compiles its
embedded CUDA through NVRTC at context creation; any `Max CUDA >= 12.8` host
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
`MICRO_BATCH`, `CHECKPOINT_EVERY`, `FUT_BLOCK_SIZE`, `FUT_DEVICE`, and
`FUT_TUNING` remain execution controls.

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

First profile the exact production `micro_batch_loss_grad` program. The ladder
needs no corpus or tokenizer and excludes the pathological full configuration:

```bash
./deploy/profile-cuda.sh ladder
# inspect run/cuda-profile/cuda-grad-ladder.prof/

# Optional experiment: tune, then independently repeat the ladder.
./deploy/profile-cuda.sh autotune
./deploy/profile-cuda.sh ladder
```

The specs move one axis at a time from tiny/small toward `bpe10m`. Unlike a
tuning file produced from the separate `bench.fut` program, the resulting
`run/cuda-profile/cuda-production.tuning` contains names from the trainer's
actual generated program and can be passed as `FUT_TUNING`.
Treat the file as a hypothesis: RTX 5070 autotuning made six of seven relevant
shapes slower (up to 30x), so that file was rejected after the repeat.

Only after the ladder has a viable schedule, run the full profile explicitly:

```bash
ALLOW_FULL_PROFILE=1 ./deploy/profile-cuda.sh full
```

This opt-in matters because `futhark bench` performs a warmup, measured run,
and profiling run; under the known bad schedule that can burn tens of minutes.

Then gate one actual update. Context compilation and step execution have
separate timeouts, so a cold NVRTC compile is no longer misreported as a slow
gradient:

```bash
./deploy/step-gate.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
```

After the gate passes, benchmark the same corpus and settings:

```bash
VALIDATION_WINDOWS=1 TRAIN_BATCH=8 MICRO_BATCH=1 BENCH_STEPS=200 \
./deploy/benchmark-cuda.sh run/wiki-bpe10m/shard-0-bpe10m.corpus \
  "$HOME/datasets/wikipedia-en/enwiki-8k.bpe"
```

`step-gate.sh` has already populated `FUT_CACHE`. Repeat only when comparing an
execution control. On the measured RTX 5070, `MICRO_BATCH=1` outperformed `8`
(1,575 versus 1,329 end-to-end target tokens/s).

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
TOKENIZER_FILE="$HOME/datasets/wikipedia-en/enwiki-8k.bpe" \
TRAIN_BATCH=8 \
MICRO_BATCH=1 \
CHECKPOINT_EVERY=2000 \
VALIDATE_EVERY=2000 \
VALIDATION_WINDOWS=1 \
FUT_CACHE=run/futhark-cuda.cache \
nohup ./deploy/train-cloud.sh >> run/train-cloud.log 2>&1 &
```

Spot eviction can happen without warning. Keep the plan and tokenized corpora
on a persistent volume and synchronize the compact global checkpoint off the
instance periodically. An interrupted segment resumes from the checkpoint's
global Adam step without resetting moments or the schedule.
