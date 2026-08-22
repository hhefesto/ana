# Milestone 1 runbook — one short single-GPU rental

The box is billed by the hour, so the order below is fixed and everything that
a CPU could do has already been done off it. Target: 6-10 hours, ~$5-10.

**Spec:** one RTX 5090 (32 GB is needed for the memory sweep, not for the
ablation), **>= 64 GB host RAM**, >= 100 GB disk.

**Standing rules for any rented box, from earlier runs:**

- `nohup` everything long-running; record its PID and **kill by PID**. Never an
  unbracketed `pkill -f` over ssh -- the pattern matches your own shell.
- Commits made on the box carry **no** `Co-Authored-By` trailer.
- When finished: pull, verify by sha256, then **DESTROY**. Never stop or pause;
  a stopped instance still bills storage and its restart is not guaranteed.
- Never pipe a command whose exit status matters into `tail`. That is how a
  failed extraction reported success on this project already.

---

## 0. Bring the box up

```
deploy/bootstrap-ubuntu-nvidia.sh <host>            # driver + nix
BUILD_GEMM_CUDA=1 deploy/cloud-init.sh <host>       # the GEMM CUDA trainer
```

`nvidia-smi` must show a 5090 and the driver must load before anything else is
worth doing.

## 1. The exact v2/v3 baselines (~5 minutes)

Already measured on CPU to +/- 0.043 over a 32-slice spread sample: **v2 1.337,
v3 1.450**. This step replaces the spread sample with the full test split,
which is about a minute of GPU time per model.

```
deploy/push-corpus.sh <host> run/eval/enwik8-test-fw32k.corpus
deploy/push-corpus.sh <host> run/eval/wiki-heldout-fw32k.corpus
# on the box, for each of the two checkpoints:
TOKENIZER_FILE=run/enwiki-fineweb-32k.bpe MICRO_BATCH=32 \
  result-gemm/bin/formal-transformer-gemm-cuda evaluate CKPT CORPUS
```

Use the `-fw32k` corpora. The older `enwik8-test-32k` and `wiki-heldout` carry
a superseded tokenizer identity and `evaluate` will refuse them -- which is
correct behaviour and is why they were rebuilt.

## 2. Context-1024 ablation — THE decision this rental exists for (~5 hours)

Two presets differing **only** in `contextSize`: vocab 32,768, d=320, ff=864,
L=8, h=5. One tokenized shard serves both, because tokenization does not depend
on context -- only the plan does. Matched tokens per step: batch 64 at ctx 256
against batch 16 at ctx 1024, same step count.

Compare **bpb**, which is per byte and therefore comparable across contexts.

> **Decision rule, fixed in advance:** if ctx-1024 bpb does not beat ctx-256 by
> at least **0.02**, NoPE is not using the extra context and RoPE gets ported to
> the softmax layers.

The sequencing constraint that used to sit here is gone: the baselines above no
longer depend on preset identity staying stable, so a RoPE `Config` field can be
added whenever the ablation calls for it.

## 3. 463M memory and throughput sweep — chooses an irreversible value (~1 hour)

```
deploy/sweep-cuda.sh <host> bpe460m    # micro in {2,4,8,16,24}
```

Record peak MiB and tok/s for each. Fixed device cost is ~17.4 GB (nine
parameter-sized f32 buffers under Muon, plus context and cuBLAS) and
activations at context 1024 are estimated at 500-900 MiB/sample, which puts the
usable micro-batch somewhere between 6 and 29 -- too wide to commit a ten-day
run to.

> **`TRAIN_BATCH` enters the plan identity and cannot change once the corpus is
> planned.** This sweep is the only chance to choose it. Intent is 64 (32 per
> rank); `MICRO_BATCH` follows from the sweep with gradient accumulation.

Write both into `deploy/bpe460m.env`, which currently carries them marked
provisional.

## 4. Checkpoint round-trip at 463M (~30 minutes)

Save, reload, `check-checkpoint`, and record **peak host RSS**. Expect a ~7.4 GB
file and ~35 GB RSS. This decides the RAM spec of the training box, and it is
the risk that most plausibly sinks the run: two ranks saving at once would want
~70 GB, which is why rank 1 does not save.

## 5. Close out

Write the measured numbers into `docs/`, commit on the box without trailers,
pull, verify by sha256, then **DESTROY**.

---

## Go / no-go for the two-GPU run

| gate | threshold |
|---|---|
| combined throughput | >= 8,000 tok/s (below this Phase A exceeds ~11 days) |
| micro-batch | >= 8 |
| checkpoint save | fits in the training box's RAM |
| context decision | resolved either way -- ctx 1024, or ctx 1024 with RoPE |
