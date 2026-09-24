# Session Handoff

This document holds everything needed to continue this work from another machine and account.

## ▶ CONTINUE HERE (2026-09-24, evening): the dense trainer continues master's v3 run

**Goal.** Improve on master's v3 (step 8000) with the Bend2 dense trainer; `bend` merges into master when its continuations beat master v3's.

**What exists now (commits b6d81ae..HEAD)**
- **Hot start:** `TRAIN_INIT=<ftc2>` loads master's FTC2 checkpoint (parameters, Adam moments, Muon momentum, step) into the dense store and trains on master's plan and shards (`PLAN`, `RUN_DIR`, `SHARD_SIZE`), in master's epoch order, with the manifest's schedule and betas. `SAVE_EVERY` writes FTC2 that master's resume reads (`bend/Dense/Ckpt.bend`, `bend/Dense/Plan.bend`, `bend/Corpus.bend`).
- **Dense evaluate:** `EVAL_CORPUS=<ftcc>` scores a checkpoint with master's formula (bpb over every full window; v3 and v2-era manifests).
- **Fork published:** `github:hhefesto/bend2/ft-kernels`, with `File.read_f32be/write_f32be/write_bytes/read_at` (the flake pins it).
- **Log format:** master's fields (`step=/total progress= lr= train_loss= train_loss_ema= gradient_norm= clipped=`, `validation_loss= validation_delta= best_validation_loss= new_best= bits_per_byte=`) plus `ms= tok/s= remaining= eta=`, every line behind a Mexico City timestamp (`[YYYY-MM-DD HH:MM:SS CDMX]`, UTC-6, from the fork's `IO.time`; `IO.now` is monotonic); `hot.sh` runs under `stdbuf -oL` because the runtime's print does not flush.

**Verified**
- **Step for step against master.** Master's v3 process ran on to step 8019 after saving the 8000 checkpoint; the Bend run started from that checkpoint and its 19 overlapping step lines agree with master's to ~5e-6 in the loss and ~1e-5 in the gradient norm (e.g. 8001: 3.4582634/0.3414476 vs 3.4582589/0.34144256; 8019: 3.4962168/0.3393160 vs 3.4962144/0.33931524). Same windows in the same order, same Muon step, same schedule (`run/train-cloud-v3-final.log` vs the box's `train.log`).
- Load→save is byte-identical on master's v3 step-8000 and the mkt checkpoints (`bend/tests/hot.bend`, run by hand: it needs a real checkpoint, so it is not a flake check).
- Validation at step 8000 on the box: 3.627147; master logged 3.6271493 on the same 256 windows.
- Schedule (cosine to zero), epoch hash (`splitmix(i + 0x45504f4348)`), split seed and per-shard window counts equal master's.

**The run (vast 52365970, Michigan RTX 3090; DESTROYED 2026-09-24 after the pull; logs in `bend/gpu/hot-rtx3090-2026-09-24/`)**
- v3 step 8000 → **28000 done** on master's data, 20,000 steps in 12.7 h. Checkpoints 20k–28k are in `run/pulled-vast-52365970/` with `sha256.txt` (each 1,846,967,877 bytes; master's resume reads them).
- **Speed: 2,290 ms/step = 7,155 tok/s = 1.8× master's v3 3090 run (4,110 ms).** The gap to the 1,702 ms G3 measured on another card is the card: the same cold G3 setting on this box ran at 2,180 ms/step (`timing.txt`), so the hot path costs ~110 ms/step (5%) over the cold benchmark and the rest is the box (`SW Thermal Slowdown: Active` at 81 °C, 350–380 W of 390 W, 1.7–1.8 GHz). Check `nvidia-smi -q -d PERFORMANCE` on every box; the first Washington box ran at 450 MHz.
- enwik8 test split, 6,184 windows, one evaluator for all rows: v2 final 1.3728; v3 step 8000 1.4903; Bend 10k 1.5019, 12k 1.5023, 14k 1.4851, 16k 1.4669, 18k 1.4636, 20k 1.4606, **22k 1.4462 (best)**, 24k 1.4534, 26k 1.4478, 28k 1.4516. The last 6k steps plateau around 1.45 on shards 7–8 (4.8–5.3 windows per document).
- **The dip at 10k–12k is the data, not the trainer.** The plan's shards differ in document length: shards 0–1 have 9.9 and 7.7 windows per document, shards 2–3 have 3.9 and 3.6 (mean training loss 2.88 and 2.71 against ~3.47 elsewhere), and 272 of the 304 shards have 1–3. Master's v3 saw only the two long-document shards; the continuation moved into short-document text, enwik8 (long articles) got worse for 4,000 steps, then recovered. Greedy continuations at step 20k do not look better than at 8k for the same reason plus greedy looping, which both checkpoints do.

**Open items**
1. ~~Finish, pull, time, destroy.~~ Done (above).
2. Compare against master v3 step 8000: the bpb table (above) plus continuations (`bend-generate`, five prompts, greedy and seed 0) for steps 8000, 20000, 22000 and 28000. **Measured 2026-09-24:** distinct 4-grams / total over the five greedy continuations fall with training, 0.70 (8000) → 0.60 (20k) → 0.55 (22k) → 0.54 (28k), while the seeded samples stay at 0.97–0.99 and enwik8 improves. Greedy decoding loops more as the model grows more confident on this (mostly short-document) data; the eye judging greedy output sees the later checkpoints as worse. Ranking checkpoints needs many seeded samples scored blind, or a repetition-aware decode, not greedy. The user decides on merging.
3. Speed: the GLA einsum kernels are ~60% of the step (see the previous section's item 5).
4. `Dense/Ckpt.bend`: offsets are U32 (files under 4 GB; v4 at 463M would not fit) and saves write in place (no rename effect).

## Previous (2026-09-24, morning): Bend2 training at GPU speed, all phases done

**Goal.** Bend2 training at least as fast as master, using the GPU fully.
- **Result:** bpe100m-v3 on a vast RTX 3090 runs at **9,626 tok/s (1,702 ms/step)**. Master's logged v3 run on a 3090 did **3,985 tok/s**, so this is **2.4×**.
- **MFU** by master's formula: 27.6%.
- **Power:** median 304 W of 315 W.
- Details, the method, and the table of each speed-up are in `docs/BEND-PORT.md`, section "Training on a GPU: the dense trainer". Logs are in `bend/gpu/g3-rtx3090-2026-09-24/`.

**Where the code is**
- **The fork** `~/src/bend2`, branch `ft-kernels`, which the flake uses via `git+file`, adds these ops to `base.bend` (each op's meaning is its Bend definition):
  - `Array.gemm` and `Array.mm`: products, run on cuBLAS via dlopen, or on a C loop without a GPU;
  - `Array.einsum`: an `Ex` expression summed over up to six indices, with indirect views for gather and scatter. It runs as NVRTC-generated kernels with self-tuned strategies, or as the reference-order loop on the CPU.
- **How ops run:** bulk ops queue on one stream (lazy sync). A program that has bulk ops but no `!` builds with any clang, using `-DBEND_NO_SRC`.
- **Runtime knobs:** `BEND_GEMM_NUMERICS`, `BEND_GEMM=loop` (the oracle), `BEND_PROFILE=1|2`, `BEND_FT_STRAT`, `BEND_FT_CACHE`, `BEND_FT_DUMP`.
- **The port** (`bend` branch):
  - `bend/Dense/{Ex,Op,Layout,Model,Step,Io}.bend`: the step as data, with reverse mode derived as a program transformation;
  - `bend/TrainDense.bend`: the trainer (`bend-train-dense`). It takes the same environment as `Train.bend`, plus `TRAIN_MICRO` and `TRAIN_CHUNK` (default 16);
  - `bend/Spec/Dense.bend`: the structural laws;
  - `bend/tests/dense.bend`: the oracle against the tree trainer.

**Gates**

| gate | what | result |
|---|---|---|
| G0 | GEMM from Bend against direct cuBLAS | matches |
| G1 | generated kernels against the loop | identical output |
| G2 | dense against tree trainer: every gradient on CPU and GPU; 6-step AdamW/Muon trajectories | within 5e-7; match to about 1e-7 |
| G3 | tok/s against master | 2.4× master |
| checks | `bend-spec`, `bend-dense`, `bend-tests`, `bend-train` | pass |

**Open items, in order of value** (1, 3 and 4 done in the evening; see above)
1. ~~Publish the fork.~~ Done: `github:hhefesto/bend2/ft-kernels`.
2. **Same-box A/B against master.** Master's number is from a different 3090. Building master's gemm-cuda trainer on a box needs nix, which is slow. The hot run measured 1.8× on a third card, so the margin is real but the exact factor is not.
3. ~~Warm start~~ Done (hot start).
4. ~~Dense evaluate~~ Done (`EVAL_CORPUS`).
5. **More speed.** The remaining time is mostly the GLA einsums that have `exp(B_τ − B_σ)` inside, and their transposes: about 60% of the step.
   - Candidates: shared-memory tiled einsum kernels, or the cumulative decay as a product (needs per-op fp32 numerics).
   - Chunk 8 is about 3.5% faster than 16.
   - The micro-batch is 32, capped by the 2³¹-float array limit; two stores would allow 64.

**Box lessons (2026-09-24)**
- A vast box in Korea downloaded at about 140 KB/s, so apt's clang-19 would have taken hours. Test the network before staging.
- Ubuntu's clang-15 builds a bulk-op program in 44 s.
- Pick boxes with at least 64 GB RAM, and run with `--gpu 48GB`: the managed heap also holds the host's lists and trees.

## Rules that bit before

- A CUDA build of a Bend program **uses the GPU by default**, so a CPU baseline needs `--gpu off --threads N`.
- The NVRTC `--gpu-build` step takes about 15 min for a 2.2 MB program. The resulting `.gpu` cubin can be reused on the same `sm_XX`.
- The vast image `nvidia/cuda:12.4.1-devel-ubuntu22.04` needs clang-19 (install with `llvm.sh 19`) and lacks `/usr/bin/time`.
  - `nproc` reports the host's cores, not the container's; read `/sys/fs/cgroup/cpu.max` instead.
  - Destroy the box with `vastai destroy instance ID -y`.
- `pkill -f` matches its own ssh shell, so kill by PID.
- Rent a box only once the binaries and scripts are staged. Commits carry no Co-Authored-By, and nothing is pushed without asking.
