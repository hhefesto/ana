# Session Handoff

This document holds everything needed to continue this work from another machine and account.

## ▶ CONTINUE HERE (2026-09-24): Bend2 training at GPU speed, all phases done

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

**Open items, in order of value**
1. **Publish the fork.** This needs the user's OK. Then point `inputs.bend2` at the published fork instead of the local path.
2. **Same-box A/B against master.** Master's number is from a different 3090. Building master's gemm-cuda trainer on a box needs nix, which is slow. The 2.4× margin is large, but it is not a controlled comparison.
3. **Warm start** from an FTC2 checkpoint in the dense trainer.
4. **Dense evaluate:** master evaluates with its batch forward. Generate stays on the tree decoder, which is byte-identical to master.
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
