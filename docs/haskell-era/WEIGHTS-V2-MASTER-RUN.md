# The v2 master-run weights (final artifact)

The bpe100m "master run" — v2.0.0, decomposed-GEMM trainer, the
re-sharded mixed corpus (`run/mixed-bpe100m-s32000`, 304 shards,
358,276 planned steps) — was **stopped by decision on 2026-08-20 at
step 337,244 of 358,276 (94.13%)** to repurpose the rented GPU for the
warm-started v3 run (see `docs/V3-DECISIONS.md` §6).  The final ~21K
steps of the cosine LR decay were foregone; train-loss EMA at the stop
was ~3.359.  The last checkpoint WRITE was step 336,872 — the 372 steps
past it were never persisted and are lost with the process.

The checkpoint itself cannot live in this repository — `.gitignore`
excludes `*.checkpoint` and `/run/` wholesale, and the GitHub remote
rejects files over 100MB — so this manifest is the tracked record.

## The artifact

| field | value |
|---|---|
| SHA-256 | `b18ae97b98590add43b1769627d770277a045ea1580837006d119bcec658bc01` |
| size | 1,385,138,070 bytes |
| completed step | 336,872 / 358,276 (94.026%) |
| weights written | 2026-08-20 19:21 UTC |
| model | bpe100m — 115,428,096 parameters |
| config | `Config {vocabSize = 32768, contextSize = 256, modelDim = 768, ffDim = 2048, layerCount = 12, headCount = 12}` (v2; decodes as arms-off v3 through the one-way migration) |
| tokenizer | `run/enwiki-fineweb-32k.bpe` (32,768 pieces) |
| plan identity | `run/mixed-bpe100m-s32000/plan-bpe100m-b64-s32000.tsv`, batch 64 |

## Provenance

Pulled 2026-08-20 with `deploy/pull-latest-weights.sh` (read-only) from
the training box (`run/remote-box.env`):
`root@65.95.12.163:44704:/root/formalTransformer/run/wiki-bpe100m-global.checkpoint`.

Local copy:
`run/pulled-root-65.95.12.163-44704-checkpoints/wiki-bpe100m-step336872.checkpoint`
(same directory holds earlier step snapshots: 327417, 329536, 330546,
and 336,000 under the `wiki-bpe100m-global.checkpoint` name, sha256
`365e4bbe2c6d5ccaf160e8f59ed23a3e61997e33f60939c565160ad55b645494` —
the box wrote the 336,872 checkpoint two minutes after that pull
completed).  The box's own copy at the remote path above is left in
place — it is the `TRAIN_INIT` warm-start source for the v3 run, and
the v3 launch log confirms `completed step 336872` as its source.  The
full v2 training log is archived beside the checkpoints as
`train-cloud-v2-final.log`.

Verified at pull time: `check-checkpoint` prints `compatible:`;
`checkpoint-info` reports the step and config quoted above; the SHA-256
here is of the exact bytes pulled.
