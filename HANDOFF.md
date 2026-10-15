# Session Handoff

This file holds everything needed to continue this work from another machine and account. It was restarted from zero on 2026-10-02 for a new path: **legere**, the Bend Jev. The previous handoff (the FP-agent transcript corpus: the checks, the Bend ×4 rebuild, the filler) is in git at `e9cce23:HANDOFF.md`. The one before it (the v3 hot start and the dense trainer) is at `41e1920:HANDOFF.md`, and master's Haskell-era trainer is at the tag `haskell-final`.

## Operating a run with the Bend tools (2026-10-15)

Every step of a run is now a Bend command. The scripts that did these jobs are unwired: each has a `# UNWIRED` header, exits 2, and is kept for reference. The one exception is bend/gpu/fp.sh, kept as a fallback (see the end of this section). This section gives the order of the steps. Each module's header comment gives the details and every setting. Run everything from the repository root. A long job must not name a store path that a GC can remove, so build GC roots first:

```sh
nix build --max-jobs 1 .#bend-ops -o run/gcroot-bend-ops
nix build --max-jobs 1 .#bend-corpus-v2 -o run/v2/gcroot-bend-corpus-v2
nix build --max-jobs 1 .#deploy -o run/gcroot-deploy
export PATH=$PWD/run/gcroot-bend-ops/bin:$PWD/run/v2/gcroot-bend-corpus-v2/bin:$PATH
```

`nix run .#deploy -- ops ARGS` and `nix run .#deploy -- corpus-v2 ARGS` run the same tools. In the commands below, `root@IP PORT` is the box's ssh login and port.

1. **Stage the box** (bend/Box/Stage.bend; bend/Box/Drive.bend for the stages built here). Once the box answers ssh:
   ```sh
   BOX_ENV=bend/gpu/v3-box.env bend-ops stage box root@IP PORT
   ```
   BOX_ENV names the run's bend-push settings (run 3's here). This sends the trainer, the gate and bend-box as C, builds bend-box on the box with its clang, then pushes the plan's shards in plan order. It ends by printing what to run on the box: `cd formalTransformer && ./bend-box gate && ./bend-box time && ./bend-box run`. The run takes fp.sh's environment (bend/Box/OnBox.bend), for example run 3's S1: `PLAN=run/v3/S1/plan-fp100m-b16-windows.tsv RUN=run/v3/S1 NAME=s1 STEPS=36696 ./bend-box run`.

   Later stages are built here and pushed:
   ```sh
   NAME=w1 NEW="haskell-w1=run/transcripts-w1/haskell lean-w1=run/transcripts-w1/lean" bend-ops stage next
   bend-ops stage push w1 run/w1 root@IP PORT
   bend-ops stage raw mix
   bend-ops stage restage root@IP PORT CKPT STAGE...
   ```
   - `stage next` builds run/w1.
   - `stage push` sends the shards, checks their sha256, then sends the plan last and writes STAGED.
   - `stage raw` takes `mix`, `mixnew FILE.jsonl...`, `build K` or `push K root@IP PORT`.
   - `stage restage` puts a run on a new box: the C, bend-box, CKPT and the stages.
2. **Start the chain and the watch** (bend/Box/Chain.bend, bend/Box/Watch.bend) once the first stage trains. STAGES holds one stage a line, `NAME BINARY EVERY [PLAN RUN_DIR SHARD_SIZE]`. Its first line is the running stage, for example `s1 traind 5000`, and you may append lines at any time. DEST, here run/v4/run4, gets chain.log (UTC-6 stamps), the markers and out/ with the pulled checkpoints.
   ```sh
   mkdir -p run/v4/run4
   systemd-run --user --unit=ft-chain-run4 -p MemoryMax=2G -p OOMPolicy=continue --working-directory=$PWD \
     $PWD/run/gcroot-bend-ops/bin/bend-ops chain root@IP PORT INSTANCE run/v4/run4 run/v4/run4.stages
   systemd-run --user --unit=ft-watch-run4 -p MemoryMax=2G -p OOMPolicy=continue --working-directory=$PWD \
     $PWD/run/gcroot-bend-ops/bin/bend-ops watch root@IP PORT run/v4/run4 1.00
   ```
   - Pass settings with `-E NAME=VALUE`, for example ALERT_CMD, EXTRA_EVAL or BOX_DRIVER.
   - The output also goes to `journalctl --user -u ft-chain-run4`.
   - Copy both lines into run/v4/run4/units.txt. A reboot kills transient units, and each program resumes where it stopped when started again with the same line.
3. **Feed raw slices** (Drive.bend `feed`) while the chain runs, after `bend-ops stage raw mix` or `mixnew`. For each slice, feed builds it, waits while the vast credit does not cover the queue, pushes it and appends `PK traind-next 0 ...` to STAGES. The other settings are in Drive.bend's header (P, R, SLICE and the waits).
   ```sh
   systemd-run --user --unit=ft-feed-run4 -p MemoryMax=16G -p OOMPolicy=continue --working-directory=$PWD \
     -E CREDIT_GUARD=1 -E DEPLOY=$PWD/run/gcroot-deploy/bin/deploy \
     $PWD/run/gcroot-bend-ops/bin/bend-ops feed root@IP PORT run/v4/run4.stages 1 9
   ```
4. **Run the act round** (bend/Box/Act.bend) on the same box, beside the trainer; nothing in it stops the trainer. The box runs the tools from run/v2/gcroot-deploy-agent and run/agent/gcroot-bend-episode, so rebuild those from the tree you run: `nix build --max-jobs 1 .#deploy -o run/v2/gcroot-deploy-agent` and `nix build --max-jobs 1 .#bend-episode -o run/agent/gcroot-bend-episode`.
   ```sh
   bend-corpus-v2 actset                            # once: run/v2/act/prompts.nul
   bend-ops act --dry-run run/v4/act-dry            # what setup sends; nothing is sent
   bend-ops act setup root@IP PORT
   bend-ops act ckpt root@IP PORT run/v4/run4/out/s1-step20000.checkpoint
   bend-ops act check root@IP PORT run/v4/run4/out/s1-step20000.checkpoint
   bend-ops act start root@IP PORT run/v4/run4/out/s1-step20000.checkpoint run/v4/act/r1
   bend-ops act pull root@IP PORT run/v4/act/r1
   ```
   `bend-ops act ensure root@IP PORT CKPT DIR [RESUME]` covers a new box or a restart. It retries setup and ckpt, then starts a round only when none is running.
5. **Build S2** (bend/CorpusV2/S2.bend) when S1's log says `done at step BOUNDARY`. Work on the box (`ssh -p PORT root@IP`) in the act workspace, `cd /home/hhefesto/src/formalTransformer` (ACT_WS). If the act round still runs, stop it first and cut its files to whole records:
   - `~/formalTransformer/bend-box act-stop`;
   - `~/formalTransformer/bend-box cut-frames run/v3/act/r1/episodes.eplog` (bend/Box/ActBox.bend);
   - agent-act's last two steps, `bend-episode accept` and `fixed`, whose lines are in bend/CorpusV2/AgentAct.bend's header.

   Then build S2 (run 3's case):
   ```sh
   run/v2/gcroot-deploy-agent/bin/deploy corpus-v2 s2 ~/formalTransformer/run/v3/S1 36696 ~/formalTransformer/run/v3/S2 run/v3/act/r1
   ```
   s2 computes NLR, the learning rate S1's schedule reaches at BOUNDARY. It checks NLR against S1's own log (S1_LOG, by default ~/formalTransformer/train.log) and stops before any work when they differ. Its last stdout line is the stage line. Append that line here to STAGES, for example `s2 traind-next 5000 run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m`, within WAIT (2 h) of S1's end.
6. **Run the evals** (bend/Box/Evals.bend) here, on the pulled checkpoints. The evals take hours, so start them as a unit like the chain. Evals already done are skipped, so a rerun as checkpoints arrive costs only the new ones. A new run's evals are a new config: copy tools/evals/run3.cfg and change its tags and pairs.
   ```sh
   bend-ops evals tools/evals/run3.cfg > run/v3/evalruns/compare.txt
   TAGS="s2-step56725 v2-step53880" bend-ops evals tools/evals/run3.cfg
   ```
7. **Verify and destroy.** The chain does this. After the last stage it:
   - scores the checkpoints on the box (eval.log, eval-next.log);
   - pulls the last ones;
   - checks that every checkpoint on the box is here with the same sha256 (DEST/sha256.box.txt ⊆ DEST/sha256.txt), and that every wanted checkpoint is here and whole;
   - destroys the box, and counts the destroy only once a listing no longer shows the instance. chain.log then says `finished`, and DEST/DESTROYED appears.

   The markers:
   - DEST/DIED names a stage that died; no later stage starts.
   - DEST/REFUSED means the chain would not destroy. The watch destroys an hour later, once the box is safe (no trainer, and every checkpoint on the box is here with its sha256), and otherwise alerts every hour.
   - `date -d '+2 hours' +%s > run/v4/run4/HOLD` delays the destroy to that epoch.
   - `touch run/v4/run4/CONTINUED` stops it for good.
8. **Test in the sandbox and lint.** The sandbox is a fake box: bend-sim stands in for ssh, rsync, vastai and the trainers. It never touches a real box, vast or money. Each scenario prints `ok`/`FAIL` lines and exits 1 on a FAIL.
   ```sh
   nix build --max-jobs 1 .#bend-sim -o run/gcroot-bend-sim
   nix build --max-jobs 1 .#bend-box -o run/gcroot-bend-box
   export BEND_SIM=$PWD/run/gcroot-bend-sim/bin/bend-sim BEND_BOX=$PWD/run/gcroot-bend-box/bin/bend-box SIM_CV2=$PWD/run/v2/gcroot-bend-corpus-v2/bin/bend-corpus-v2
   bend-ops sim all run/sim-chain
   bend-ops sim stage all run/sim-stage
   bend-ops sim soak run/sim-soak 3600
   bend-ops lint --bend --run-since 2026-10-14
   nix build --max-jobs 1 .#checks.x86_64-linux.shell-lint .#checks.x86_64-linux.ops-sim
   ```
   - `sim all` runs the chain and the watch through 10 scenarios (bend/Box/Scenario.bend).
   - `sim stage all` runs 17 scenarios: stage, feed, act and dense-identity, each against the script it replaced (bend/Box/ScnStage.bend). It also reads SIM_PUSH and SIM_EPISODE, and SIM_TRAINER for dense-identity; without SIM_TRAINER it builds the trainer from the flake.
   - `sim soak` runs the chain at POLL=1 and logs its RSS.
   - `lint` checks that every tracked shell file and flake.nix body is a thin shim, and that no Bend `sh -c` string holds logic (bend/Box/Lint.bend). `--run-since` also warns about new untracked run/**/*.sh drivers.

**Not yet shown on real hardware.** Every path above has been checked against the script it replaced, in the sandbox or on run 3's real files, but none has yet run against a real vast box. bend-box's GPU modes (build, gate, time and run on CUDA) cannot be shown without a GPU. So bend/gpu/fp.sh stays wired; it is the one line left in tools/lint/shell-allow.txt, and `stage box` copies it to the box. If bend-box fails there:
- run `./fp.sh gate`, `./fp.sh time` and `./fp.sh run` on the box;
- start the chain with `-E BOX_DRIVER=./fp.sh`.

Unwire fp.sh once bend-box has trained on a real box.

**A run's drivers are one config file** (tools/runs/*.cfg; TEMPLATE.cfg explains each key, and run3.cfg reproduces run 3's drivers). Copy TEMPLATE.cfg to tools/runs/run4.cfg and fill in the host, port, instance, DEST, STAGES and the boundary. Then:
```sh
nix build --max-jobs 1 .#bend-ops -o run/gcroot-bend-ops   # the config's `ops` key names this path
bend-ops guard tools/runs/run4.cfg --dry-run    # the units it would start
bend-ops guard tools/runs/run4.cfg install      # a persistent user unit that brings them back after a boot
bend-ops guard tools/runs/run4.cfg              # starts chain, watch and handover units that are not running
```
- **`bend-ops unit start NAME [--mem X] [--out FILE] [--env K=V]... CMD...`** replaces the hand-written systemd-run lines in step 2 above.
  - It runs CMD as a user unit with MemoryMax (4G by default) and OOMPolicy=continue.
  - It records the command line under ~/.local/state/bend-ops/units.
  - After a reboot, `unit restart NAME` runs a recorded unit again; `unit list` shows each one and whether it is running.
- **`bend-ops handover CFG`** (bend/Box/Handover.bend) does step 5 by itself, in s2-driver.sh's order:
  - It waits for S1's `done at step BOUNDARY`.
  - It stops the act round unless the round finished, cuts its frames, and runs accept and fixed.
  - It builds S2 on the box with `corpus-v2 s2` and appends its line to STAGES.
  - It exits 1 and leaves STAGES alone if S1 died or s2 failed.
  - It exits at once if STAGES already has the stage.
- **`bend-ops move CFG STEP`** (bend/Box/Move.bend) takes a run from a failing box to a new one, step by step: `old-stop`, `old-pull`, `restage`, `resume`, `watch`, `act`, `old-check`.
  - old-stop checks the save before stopping anything.
  - resume rewrites the stage's STAGES line and keeps the old one as STAGES.OLD_INSTANCE.
- `bend-ops sim drive all run/sim-drive` runs 7 scenarios against run 3's boot-guard.sh, s2-driver.sh and move.sh. Not yet shown: act-ensure, act-pull, `move restage` and `move act`, which need real nix on a box, and `guard install` against real systemd.

## ▶ CONTINUE HERE (2026-10-15): run 3 beat run 2; every box step is a Bend command; run 4 is not yet planned

- **No box is rented.** Run 3's box was destroyed on 2026-10-13, and its 15 checkpoints are local in run/v3/run3/out.
- **The tools:** every step of a run is a Bend command (the section above). The bend2 fork is on upstream 2.0.37+: hhefesto/bend2 ft-kernels 37e80669, with the old head tagged ft-kernels-2.0.35.
- **New raw Bend for run 4:** run/v4/collect/bend.
  - bend.jsonl holds 801 files (6.9 MB); vault/bend.jsonl holds 33.
  - It covers 19 new repositories, upstream bendlang/bend since 1d895ca0, and the growth of the known repositories.
  - The run-4 raw build must take it.
- **Before run 4's rental:**
  - Pick an offer whose `duration` covers the job; check its `end_date` (run 3's first box expired after 3 h).
  - Run the act round's setup afresh: round 1 had no Haskell episodes, because the box lacked the GHC harness and the tarballs. act's check now fails such a language.
  - Validate bend-box on the GPU with `./bend-box gate`, `time` and `run`, and keep fp.sh as the fallback until it has trained.
  - No shadow watch (decided 2026-10-15). The plan wanted the old credit watch beside the new one in alert-only mode, but credit-watch.sh never had such a mode. Its decisions are covered instead by the sandbox runs against the old script: the low-credit stop, the destroy after GRACE when a wanted checkpoint is missing, the destroy that does not take, and the failed listing (`bend-ops sim 5`, `6`, `8` and `9`). On the first rental, watch `journalctl --user -u <watch unit>` and the credit by hand during the first hour.

## Run 3 (2026-10-07 to 10-13): turn-based compiler episodes; at the end it beats run 2 on E1 and E5

- **The plan** (approved 2026-10-07):
  - ana writes a Term, the compiler answers, and ana writes again, up to 4 turns; a retry is role RoTry, with weight 0.
  - S1 is the steady plan run/v3/S1: 56,497 steps, 82.8% raw.
  - At S1's boundary (step 36,696) an act round on the box turns ana's own episodes into S2's on-policy data. That data is ana's successes plus `bend-episode fixed`: ana's rejected Terms followed by the known fix.
- **Boxes:**
  - vast 55552041, from 2026-10-12 06:20: an RTX 5090 at $0.671/h. Its contract ended after about 3 h, so the run moved (run/v3/run3/move.sh) to vast 55567872 (RTX 5090, $0.551/h with disk). It resumed from s1-step4000; validation reloaded exactly (1.2514915 against 1.2514917).
  - The new box reported nproc 192 under a 46-core cgroup quota; `bend-ops act` now counts the quota.
  - Ingress was about 2 MB/s, and sshd's keepalive dropped saturated links.
- **Act round 1:** v2-step40000, about 3,600 episodes/h on 48 vCPUs, 9,029 accepted. **No Haskell:** the box lacked run/check-cache/ghc-harness and run/code-sources/tarballs.
- **S2:**
  - It started 2026-10-13 06:33 with NLR 8.288989e-05, equal to S1's last lr; episodes are 1.0% of its windows.
  - s2.sh failed three ways, all fixed by hand on the box and then in the repo (26e4fbc):
    - episodes longer than a window;
    - a filler slice with no long file;
    - Combine's hard-coded gcroot.
- **The end:** 2026-10-13 18:33 at step 56,725. The chain verified all 13 box checkpoints against the local copies, then destroyed the box at 23:48. $1.59 of credit was left.
- **Final evals** (2026-10-14; `bend-ops evals tools/evals/run3.cfg` reproduces them; paired, exact McNemar):

  | Comparison | E1 | E5 | Behaviour |
  |---|---|---|---|
  | run 3 s2-50000 vs run 2 v2-50000 | 33 vs 20 (p 0.01) | 38 vs 26 (p 0.02) | 15 vs 15 |
  | run 3 s2-56725 vs run 2 v2-53880 | 32 vs 19 (p 0.00) | 37 vs 25 (p 0.01) | 18 vs 17 |
  | run 3 s2-56725 vs run 2's best, v2-40000 | 32 vs 26 (p 0.26) | 37 vs 32 (p 0.36) | |

  - Within run 3, 40k → 56725: E1 18 → 32 and E5 25 → 37, both p 0.00. The gain came in the lr tail.
  - E1 by language at the final checkpoint: Haskell 15/31, Lean 9/46 (run 2: 1–4), Agda 3/7, Nix 1/9, Bend 4/6.
  - Retries still copy the previous Term 84–98% of the time.

## Previous (2026-10-06, 23:05 UTC-6): run 2 ends ≈ 01:20; at step 40000 it passes run 1 on every eval

**Run 2** (vast 54410376; the box and the chain are described in the 10-05 section below):
- **State at 23:05:** step 49,749 of 53,880 (92%). It averages 1.99 s/step with saves, so it ends ≈ **01:20 on 2026-10-07**. Then the chain scores on the box, pulls the last checkpoint, checks every sha256 and destroys the box.
- **Credit:** $4.89 at 23:05, burning $0.58/h. About $3.30 should be left at the destroy, so the $1 credit watch should not fire.
- **Pulled:** v2-step5000 to 45000 (every 5000, plus 21000 by hand) in `run/v2/run2/out/`.
- **One stalled pull:** at 30000 one rsync connection sat at 220 KiB/s while a fresh ssh ran at 4 MB/s. A SIGTERM to that rsync made `pull_one` retry from `--partial-dir`, and it landed in 2 min. Ask the user before doing that again.
- **This machine is on Wi-Fi** since the 07:50 reboot: `enp6s0` has no carrier.

**Run 2's quality** (E1 and E5 on the 99 doubly held-out prompts; the behaviour test below):

| checkpoint | E1 | E5 (within 1 / 4 calls) | behaviour /30 |
|---|---|---|---|
| v2-step15000 | 14 | – | 3 |
| v2-step20000 | 14 | – | 10 |
| v2-step21000 | 16 | 15 / 15 | 11 |
| v2-step40000 | **26** | 30 / **32** | **15** |
| v2-step45000 | 22 | 26 / 30 | 15 |
| run 1's nr7-step61000 | 21 | 26 / 28 | 3 |

- Step 40000 is the first to pass run 1, and run 1's figures are optimistic (post-raw). 45000's dips are mostly Haskell direct (8 → 5 in both evals): noise at 99 prompts.
- **The gain from the checker's answers grows:** 0 at 21000, 2 at 40000, 4 at 45000, all Lean.
- **Repair is still weak by hand:** given ghc's two "Conflicting definitions" errors on a broken mergeSort, step 40000 copies the answer unchanged.
- **Nix scores 0/9 on E1 from 40000 on.** It writes whole nixpkgs files out more fully, and they outgrow E1's 100 tokens; E5's 160 tokens gives 4/9.
- **The behaviour test** (`run/v2/evalruns/behaviour/`, untracked): 30 small Haskell tasks, answered greedy, then compiled and run against expected outputs. `run.sh CKPT TAG`; `REF` as the checkpoint is the control (30/30). (2026-10-15: the harness is tracked and in Bend, `bend-corpus-v2 behaviour run CKPT|REF TAG [LANG...]`, tools/corpus-v2/behaviour/README.txt; its run.sh was unwired 2026-10-14.) It catches what a type check passes: 40000's quicksort type-checks, but both filters keep the pivot's duplicates (`<= x`, `>= x`), so `quicksort [5,5,1]` is `[1,5,5,5]`.
- **One command for all three:** `run/v2/evalruns/eval-run2.sh STEP` (its header has the systemd-run line; about 30 min). (2026-10-15: replaced by `TAGS=v2-stepSTEP bend-ops evals tools/evals/run2.cfg`.)

**ana on hand-written prompts** (`run/prompts/`, gitignored; run them with `TEMPERATURE=0`, since the default 0.8 fails most of them):
- **merge sort takes two prompts on step 40000.** `merge.prompt` is correct alone. `mergesort2.prompt` gives `merge`'s signature in `## Context` (as the transcripts list helpers), names the halves left and right, and starts the Term with the two base cases. Each of the three is needed. On 35000 mergesort2 writes `merge . sort` instead.
- **Printing in Bend:** ana's None branch is always `IO.pure(Unit{})`, never the corpus's `IO.pure(Unit, Unit{})` (1,929 times), and it leaves out `U32.show`. `print_or.prompt` works by making the value a String, with `or_else` in the Context.
- **The snippet tool now checks Bend answers** (ee44016): the file opens with `import Base`, and the answer is indented under the Type's `def`. Before that, every standalone Bend answer failed.

**Next:**
- When run 2 ends: check that chain.log says every wanted checkpoint was pulled and matched before the destroy, then run `eval-run2.sh` on the final checkpoint.
- The format-2 repair view (docs/AGENT.md, Next 2).

## Previous (2026-10-06, 07:00 UTC-6): run 2 is training; ana is fast; E5 is fixed; Bend is on upstream 2.0.35+

**Run 2** (vast 54410376; the box and the chain are described in the 10-05 section below):
- **State at 07:00:** step ≈ 20,700 of 53,880. 1.90 s/step, GPU at 99% and ~595 W, 82 °C. Losses are falling with no NaN.
- **Pulled:** the chain has pulled v2-step5000, 10000, 15000 and 20000 into `run/v2/run2/out/`. v2-step21000 was pulled by hand at 07:31 and its sha256 checked against the box.
- **ana on v2-step21000** (4 format-2 prompts, greedy, `ana --agent` with `bend-agent-tool snippet`):
  - merge, countIf and `Nat.add_comm a b` are correct.
  - safeDiv type-checks, but it tests the dividend: ghc's exit 0 is not correctness.
  - On merge it called `## ghci`, which is not a tool, so nothing checked it.
  - The snippet tool's `lean` is elan with no default toolchain, so it needs `ELAN_TOOLCHAIN=leanprover/lean4:v4.34.0-rc2`. bend-check is unaffected (each project pins its own toolchain).
- **Follow the training:** `ssh -p 40039 root@66.225.46.15 tail -f formalTransformer/train.log`.
- **End:** ≈ 00:30 on 2026-10-07 if the credit lasts.
- **Credit: $14.09 at 07:20 after the user topped up, burning ~$0.58/h.** That is enough to finish (~$10 to 00:30). The credit watch still stops the trainer under $1.

**Boot guard.** The reboot at 20:58 on 10-05 killed the transient chain and credit-watch units for 3.5 h. `ft-run2-guard.service` (a persistent user unit, enabled, with linger) runs `run/v2/run2/boot-guard.sh` at boot. It restarts either unit if inactive, until the chain has destroyed the box.

**ana is fast** (docs/BEND-PORT.md, "Decoding on the dense store"):
- Decode runs at 21 ms/token and a prompt at 1.5 ms/token (bit-exact, held by flake checks).
- An E1 generation takes 4 min. E5 takes 12.7 min.
- master is 9e65d77, on the fork at 3d52da39 (below).

**E5** (docs/AGENT.md, "E5 on run 1"):
- Two silent bugs had made every earlier E5 wrong: the scoring newline (4ca428d) and the concurrent-Agda race (4f8cc2b).
- nr7-step61000 scores **28/99 within 4 calls**, 26 within 1 (E1: 21/99).
- Run 2's v2-step15000 scores **E1 14/99** (docs/CORPUS-V2.md).
- Scripts (untracked): `run/v2/evalruns/agent-e5.sh` and `run2-e1.sh STEP` (one per pulled checkpoint: step 20000 also 14/99).
- The gcroots `run/gcroot-bend-generate`, `run/gcroot-bend-generate-agent` and `run/v2/gcroot-deploy-agent` keep the builds alive through a GC.

**Bend is on upstream 2.0.35+ (done 07:20, with the user's permission):**
- **The fork:** `ft-kernels` = 3d52da39, upstream main 53fc961d plus one commit (13 files, +3,294/−22; 2,375 lines of them in comp.ts). The old head d6b3def7 is the tag `ft-kernels-2.0.34`, pushed before the force-with-lease push.
- **master 9e65d77** locks it together with the compat patch, which can't compile on the old compiler:
  - 9 `ok : Result<…> <- Chan.send` binds;
  - `Ready` → `HsReady` in Check/Haskell.bend.
- **Validated:**
  - all 7 flake checks and every package (37 targets);
  - the plan-corpus identity slice;
  - an E1 re-check (21/99, the same verdicts);
  - ana's greedy text, seeded sampling and SAMPLE_STATS byte-identical, at the same speed;
  - the credit watch's `deploy corpus-v2 credit`;
  - an E5 rerun (`agent-nr7-61000-port`): 28/99 again, 95/99 episodes byte-identical. The other 4 are Agda passes missing only "Checking Unit (Unit.agda)." because the interface was cached.
- **gcroots on the port:**
  - `run/gcroot-bend-generate`, `run/gcroot-bend-generate-agent`, `run/gcroot-bend-agent-tool`, `run/v2/gcroot-deploy-agent`;
  - the old builds stay rooted as `run/gcroot-bend-generate-2.0.34` and `run/v2/gcroot-deploy-2.0.34`.
- **Upstream makes no part of the fork redundant** (memory note `project-bend2-fork-remotes`).
- **Not yet in the fork:** 3 small upstream commits from 2026-10-06 (#1345, #1358, #1360). Take them at the next rebase.

**Disk:** 107 GB free. Old training sets and the 53 GB market snapshot were removed with the user's approval.

**Next:**
- E1 on each run-2 checkpoint as it arrives.
- At the end of run 2: E1 and E5 on its final checkpoint. Run 2 is format 2, which wants the repair view (docs/AGENT.md, Next 2).

## Previous (2026-10-05, evening UTC-6): run 2 is training (TRAIN_MASK=kinds); E5 is running locally

**The user (2026-10-05): "Do the next steps, I'll add more credit before it runs out".**
- **Run 2: vast 54410376**, RTX 5090, Illinois, $0.58/h with a 45 GB disk, image `nvidia/cuda:12.8.1-devel-ubuntu22.04` (+ apt clang-15, rsync); `ssh -p 40039 root@66.225.46.15`. Rented 19:26, trainer started 19:34: `PLAN=run/v2/mixall/plan-fp100m-b16-windows.tsv RUN=run/v2/mixall NAME=v2 STEPS=53880 SAVE=1000 ./fp.sh run` (from scratch, Muon 3e-4, warmup 300, log `train.log`, saves `out/v2-step<N>.checkpoint`). The startup line says `training targets: by role (TRAIN_MASK=kinds ...)`. G2 gate PASS on the box (masked case 5.1e-7). **1,845 ms/step, 17,700 tok/s: 53,880 steps ≈ 27.6 h, ends ≈ 23:10 on 2026-10-06, ≈ $16 + egress.** The plan: `run/v2/mixall` (combine 17:01: 1,037 shards, 3.7 GB, 94,182 transcript + 759,859 raw windows, raw 89%); staged by `BOX_ENV=bend/gpu/v2-box.env bend/gpu/fp-stage.sh` (unwired 2026-10-15: `BOX_ENV=bend/gpu/v2-box.env bend-ops stage box HOST PORT`) (unit ft-v2-stage, log `run/v2/run2/stage.log`; the trainer started while the push was still sending shards in plan order, far ahead of it).
- **Unattended:** `ft-fp-chain-v2` runs `run/v2/run2/fp-chain.sh` over `run/v2/run2.stages` (one stage `v2 traind 5000`: pulls every 5,000th checkpoint into `run/v2/run2/`, then scores, pulls the last, checks sha256 and DESTROYS the box); `ft-credit-watch-v2` stops the trainer when the credit falls under $1 (then the chain scores, pulls and destroys). (bend/gpu/fp-chain.sh and credit-watch.sh, which these units ran as copies, were unwired 2026-10-15: `bend-ops chain HOST PORT INSTANCE DEST STAGES` and `bend-ops watch HOST PORT DEST [MIN]`.) **Credit was $5.95 at the rental: under $1 at ≈ 04:00 on 2026-10-06 unless the user tops up** (they said they would).
- **E5** (`ft-agent-e5`, log `run/v2/evalruns/agent-e5.log`, out `run/v2/evalruns/agent-nr7-61000/`): nr7-step61000 on the 99 doubly held-out prompts, 4 calls, 160 tokens a stretch; 24/99 by 18:42, 0 solved (all Haskell so far); ends ≈ 00:30. The loop works (every echo is the unit's real check); nr7 resubmits the same answer after the same error. Two findings: the log's "N calls" counts a final call the quota stopped (role-5 turns incl. the unanswered one), so "5 calls" = 4 answered; held-out units 4 and 21 were cut just before a closing bracket at column 1 (the bracket stays in the unit's after-text), so a complete answer gets a duplicate `}` and cannot pass.
- **Echo law on the train results:** all five languages, 0 failures (`run/agent/echo-all.log`).
- **memo port** (~/src/OptMem, branch `bend2`): 5 commits by 14:51 (store, commands, recall's ERE, the flake's bend-memo, tools/compare.sh); 3 modified files and an untracked `bend/P1.bend` uncommitted; not yet verified (the subagent stopped on a usage limit).

## ▶ EARLIER (2026-10-05, afternoon UTC-6): ana calls the real tools and is never trained on their answers (docs/AGENT.md)

**The user (2026-10-05):** "ana shouldn't even try to reproduce what ghc is going to spit out. ana should call tools like ghc or bend to run code ana produced and see if that code works well and iterate from that"; OptMem should be one of its tools, "but it shouldn't be the case that it tries to guess what memory is going to answer"; OptMem should be Bend2; Denotational Design throughout; continuous learning (cycles of acting and learning) *later*: design a tactic for it now; all five languages; the memo port in parallel.
- **The meaning** (bend/Agent/Spec.bend): an episode's turns have roles (user, given, attempt, act, call, echo); P(τ) factors so only act/call depend on θ, hence weight 1 on act/call, 0 on echo and on a given attempt. The reader works over any symbol alphabet; laws in bend/tests/agent.bend (9 ok, compiled; in the bend-tests check) and `bend-agent-laws` over every v2 transcript: 585,060 train + 5,819 holdout, 0 failures (`run/agent/laws-all.log`).
- **Training:** `TRAIN_MASK=kinds` (bend/Mask.bend; TrainDense's plan/hot starts; fp.sh passes it by default, MASK= turns it off). The gate (tests/dense.bend) has a masked case: 5.9e-7 relative. Unset, the trainer is unchanged. **The verify shape is dropped**; run/v2/T is being rebuilt from run/v2/transcripts-nv (unit ft-v2-windows-nv, log run/v2/windows-nv.log; old T in run/v2/T-with-verify).
- **The loop:** `ana --agent` (bend/Agent/Loop.bend; AGENT_TOOL, default `bend-agent-tool snippet`; AGENT_CALLS 4; TOKENS a stretch). The decoder is the library bend/Decode.bend (`dc.`); plain `ana` output byte-identical (greedy and sampled, 2026-10-05). First episode on nr7-step61000: every `## ghc` turn GHC's own; ana repeated a wrong answer (expected from a checkpoint trained to predict errors).
- **Raw mix:** the first remix refused duplicate ids; `run/v2/dedupe-ids.sh` (1,104 Stack files that are older versions of run/v2/raw paths and 6 Stack self-duplicates dropped, 15 NuminaMath ids renamed #2) then `run/v2/remix-mix.sh` (unit ft-v2-remix-mix: mix, then slices R/1..n).
- **memo in Bend2:** a subagent is porting it in ~/src/OptMem on branch `bend2` (gates: 4,932 golden covers, the 38 CLI tests via MEMO_BIN, a byte-compare script).
- **Next:** when T and R are done, `bend-corpus-v2 combine SHARE run/v2/mixall run/v2/T run/v2/R/1 ...` (SHARE = R windows / (T + R)); run 2 with TRAIN_MASK=kinds (ask before renting; $5.95 credit). Then (docs/AGENT.md "Next"): the unit tool (ana's term as the unit's mutant through bend-check) and E5 (solved within k calls); the format-2 repair view; the episode log; memo as a tool; the act/learn cycle as stages.

## ▶ EARLIER (2026-10-04, evening UTC-6): corpus v2's tools are Bend now (no Python in ana); the raw pool is being rebuilt; run 2 waits for the user's choice

**The user (10:40): "Be sure to destroy the instance once everything finishes and start working on the improved corpus. It will have the same data, but it should be presented in a way that reduces our errors."** (10:38: "I added 5 usd. You shouldn't use it all.") Credit $5.95 after the destroy; no instance.
- **Run 1 ended** at step 67,717 (nr9); scores in `run/pulled-vast-54027515/chain.log`; box 2 destroyed 13:23 after `box-baseline.sh` (unwired 2026-10-14, done) scored run 1 on the v2 eval corpora (table in docs/CORPUS-V2.md, Evaluation). **nr9-step67717 and w3-step40731 were lost**: their pulls failed on a link drop and the chain's sha check passed on the one file present (fixed in faab51f: pulls retry, the destroy waits for every wanted checkpoint). Latest local: `run/anatest-20261003/ckpt/nr7-step61000.checkpoint`.
- **Corpus v2 is built** (docs/CORPUS-V2.md, "Same data, presented to reduce the errors"): format 2 transcripts of every unit run 1 saw (`run/v2/transcripts/`), filler once, raw once (`run/v2/raw/`), transcript windows `run/v2/T` (107,740 windows, 6,097 steps), raw shards `run/v2/R/1..4`, and two interleaved plans: `run/v2/mix30` (8,716 steps, 30% raw, ~$2.9 on a 5090) and `run/v2/mix60` (15,138 steps, ~$4.8). Start: `PLAN=run/v2/mix30/plan-fp100m-b16-windows.tsv RUN=run/v2/mix30 NAME=v2 STEPS=8716 ./fp.sh run` on a box staged with the shards (hard links; push with `rsync -L` or bend-push).
- **No Python (the user, 2026-10-04: "ana and all my projects are Functional Programming, no python is allowed. At most a small shim of bash/sh").** Every corpus v2 tool is `bend-corpus-v2` (bend/CorpusV2.bend + bend/CorpusV2/; `nix run .#deploy -- corpus-v2 SUB`; GC root `run/v2/gcroot-bend-corpus-v2`), proven byte-identical to the Python it replaced (624d3f5); the scripts' Python snippets are subcommands too. Bend traps found on the way: memory `project-bend2-silent-traps` (strict Bool.pick; one namespace across imports). Slow spots to improve: Sha256.bend (~0.5-1 MB/s) and Sys's 1 MiB reads.
- **Raw pool rebuild (unit ft-v2-raw-rebuild):** run/v2/raw/bend.jsonl was stale (written before filler's one-version fix: 396 files, should be 549). `run/v2/raw-rebuild.sh` writes run/v2/raw.next with the Bend tool and checks the other languages are identical; then: move it into place, `tools/corpus-v2/rawshards.sh mix`, `build 1..4`, and `bend-corpus-v2 combine` for mix30/mix60 again. (rawshards.sh is unwired: `mix` on 2026-10-14, since run 3 mixed with steady-mix, now `bend-corpus-v2 steady-mix`; `build K` on 2026-10-15, replaced by `bend-corpus-v2 raw-build K`.)
- **Evaluation:** E1/E2 prompts `run/v2/evalset/prompts.nul` (275) and `prompts-both.nul` (99: units held out by BOTH v1 and v2, the only fair ones for run 1: ~98% of v2's holdout units were in run 1's training transcripts), `bend-corpus-v2 gen/check`; E3 corpora `run/eval/v2-tr-LANG.corpus`, `run/eval/v2-vault-LANG.corpus`. Running (unit ft-v2-run1-baselines, `run/v2/evalruns/run1-baselines-bend.sh`): fp100m-8803 then w1-19080 on prompts-both → `run/v2/evalruns/both-NAME/report.txt`.
- **Next (ask first, it costs money):** run 2 from scratch on mix30 (the plan), or a continuation from nr7-61000 on the same plan.

## ▶ EARLIER (2026-10-03, 09:30 UTC-6): training goes on on box 2 (vast 54027515, RTX 5090, US, $0.494/h); box 1 destroyed after a verified salvage

**What happened:** vast stopped box 1 (53909778) at ~05:03 when the credit ran out; the user added $10 and said "continue on the rented box", but while it was stopped another renter took its GPU (`vastai start` answers "Required resources are currently unavailable, state change queued"). **A stopped instance's disk stays readable through the host's rsync daemon:** `vastai copy C.ID:/root/... local:...` works, and so does plain `rsync -e "ssh -p PORT" vastai_kaalia@HOST::C.ID//root/...` with the port and host that `vastai copy` prints. `run/salvage-53909778.sh` pulled the five checkpoints only box 1 had (raw4-step25500, w1-step19080, e2-step18125, n2-step18644, next-step9322) and box 1's logs (`run/pulled-vast-53909778/box1-logs/`); an `rsync -anc` pass found all five equal to the host's; then box 1 was destroyed. Two rentals on the Korean provider (host 406325) answered `success: False` and left stubs (destroyed); the US offer 53546455 worked.
**Box 2:** `ssh -p 50891 root@137.175.22.196`, 45 GB disk, G2 gate PASS (4e-7). `bend/gpu/fp-restage.sh HOST PORT CKPT STAGE...` (unwired 2026-10-15: `bend-ops stage restage`) staged it (trainer C from HEAD, byte-identical to box 1's `traind-next.c`, sha `ee13dd1a…`; the checkpoint with its sha256; then raw4, w2, raw5–9 in order). **raw4 resumed with `fp.sh resume`** (a plain hot start, no TRAIN_NEXT: the trainer derives the plan's start from the manifest) from step 25500 for 1,637 steps: its lr equals box 1's step for step and step 25501's loss is identical (1.0582947; later steps differ in the 6th digit, tf32). 2.09 s/step (box 1: 1.98).
**The chain:** `ft-fp-chain-box2` runs `run/fp-chain-box2.sh` over `run/fp100m-chain-box2.stages` (raw4 → w2 → raw5…raw9) into `run/pulled-vast-54027515/`, with `EXTRA_EVAL` = fp100m-step8803, e2-step18125, w1-step19080, raw4-step25500 (pushed to the box by `ft-push-extra`), so the final scores on both held-out sets cover the whole run (box 1's final scoring never ran). ≈ 13k steps ≈ 7.6 h: ends ≈ 17:30 UTC-6, ≈ $3.8; then pull, sha check, destroy.
**Next: corpus v2 for ana's second run (the user, 19:30: "Plan on how to improve the corpus. We'll use the improved version for a second go around"):** `docs/CORPUS-V2.md`. Run 1's findings: 80–90% of transcripts put a mutant or a hole in the assistant's first Term (so ana answers mutant-shaped and predicts its own answers fail); Nix whole-file tasks are unanswerable; the holdout was drawn per declaration while the raw stages fed the held-out files (all 2,044 Haskell/Lean/Agda/Nix held-out files are in code-train-v3), so held-out scores after raw1 are contaminated; Bend2 is 20 transcripts per file plus 4× filler. Plan: `## Attempt` (given) vs `## Term` (best effort) shapes, holdout by repository with one exclusion list and a vault, a repetition budget, one interleaved mix, an E1–E4 evaluation first, then run 2 from scratch.

**Afternoon (the user: "Look for new bend code to include. Also add more non repeated Agda+Lean+Haskell in raw form"):** three Opus agents, deduplicated against `run/raw-new/seen.sha256` (normalized-content keys, `run/raw-new/norm_hash.py`, of every Haskell/Lean/Agda/Bend file in code-train-v3: that already includes mathlib4, lean4, agda, agda-stdlib, agda-categories, HoTT-Agda and all of Hackage).
- **Bend2:** transcripts `run/transcripts-w3/bend` (3,631 train / 78 holdout, ~851k tokens: community round-4 leftovers, upstream since 75cc3602 (now bendlang/bend, 2.0.35 out today), 16 new GitHub repos) and `run/transcripts-w4/bend` (1,310 / 21, ~332k); raw `run/raw-new/bend.jsonl` (7,693 files that parse under 2.0.34). 46% of community originals fail the 2.0.34 loader (Base name clashes, typed arithmetic): code written for other Bend2 versions.
- **Raw:** `haskell.jsonl` + `haskell-2.jsonl` (431,768 files, 1.55 GB text: GHC HEAD, ~4,200 GitHub repos not on Hackage, ~9,800 exercise repos, the ungated HF Haskell subset; other versions of Hackage files held back, 8 MB a repo), `lean.jsonl` + `lean-2.jsonl` (216k files, 1.35 GB: Goedel/Numina/DeepSeek-Prover proofs, ~700 repos; ~2 GB more extractable with `run/raw-new/.rawla/deliver.sh 3`), `agda-f.jsonl` + `agda-2f.jsonl` (every Agda repo on GitHub; `filter-agda*.py` drops two synthetic repos and caps 10 MB a repo).
- **Staging:** `raw-stage.sh mixnew` (unwired 2026-10-15: `bend-ops stage raw`) (by-count interleave, ~20% transcript replay) → `run/rawnew1/mix.jsonl` (first deliveries, ~3.9 GB ≈ 12 slices `nrK`) and `run/rawnew2` (second deliveries, slices `nsK`); `ft-raw-driver-nr` then `ft-raw-driver-ns` (raw-driver.sh, unwired 2026-10-15: `bend-ops feed`) build, push and append with **CREDIT_GUARD** (a slice is appended only while the vast credit covers the queue + $0.60 end + $1 margin); `ft-credit-watch` stops the trainer under $1 so the chain scores, pulls and destroys. w3/w4 are inserted after raw9 by `run/w{3,4}-stage.sh` through `bend/gpu/insert-stage.py` (never behind the stage the chain is on). With $6 at 17:00 about 6 nr slices fit (training to ≈ 01:50, box destroyed ≈ 02:45 on 2026-10-04); a top-up lets the drivers go on by themselves.
- **Disk (the user approved):** deleted run/mixed-corpus.jsonl and the two older runs' checkpoint dirs in the repo **and** in the hard-link snapshot `~/data/market-shapes/snapshots/before-20260911/` (a repo file with link count 2 is hard-linked there; deleting one name frees nothing), keeping `wiki-bpe100m-step336872` and `wiki-bpe100m-v3-global` (now the only copies); unrooted 20 result-market-* links; nix GC: 75 GB free after.
- **The relay nearly lost w2's checkpoint (12:29):** a dropped ssh connection made `last_of` empty, raw6 started from w2's save and the next step would have deleted it; fixed in `fp-chain.sh` (3dc0267). The box's link drops every few minutes; pushes resume with `--partial`.

**ana tested again (09:35):** the 2026-10-02 prompts (10 held-out transcripts, greedy, 100 tokens), `run/anatest-20261003/` (`gen.py`, `score.sh`; controls re-run today 10/10 in `controls/`): **w1-step19080 1/10** (Agda `mul-Commutative-Semigroup` again, as e2-step14000), **raw4-step25500 0/10** (that Agda answer lost; it now writes holes, `_` and `?goal`, the transcripts' hole step; Bend `respond` starts right, `"HTTP/1.1 " ++ status ++`, then repeats). **18:12:** w2-step27879 **1/10** and raw9-step37000 **1/10**, both the Lean `toReal_top_mul` with a proof of their own (`rw [← mul_comm a, ENNReal.toReal_mul_top]`, not the reference's): ana's first checked Lean proof; the Agda answer stays lost after raw code, the holes stay. **2026-10-04 09:05:** nr7-step61000 (pulled to `run/anatest-20261003/ckpt/`, sha 8c3d7c43…) **0/10**: the Lean answer gained a third, redundant rewrite (`rw [mul_comm, ENNReal.toReal_mul_top, toReal_mul_top]`: "did not find (?a * ∞).toReal in 0 = 0"); Bend `Duration.from_mins` calls the right helper with wrong arguments; Agda `is-linear` uses both Context lemmas but applies one to the other instead of pairing them; holes (`= _`), a Haskell clause loop, a `<code>` loop in Bend, and the same invented Nix package (`ocs` 2.4) for both Nix prompts. Per-prompt report: `run/anatest-20261003/nr7-step61000/report.txt` (`report.py`; failing units' errors only with KEEP_WORK=1, Lean's in the work dir). The prompts are contaminated (CORPUS-V2 finding 5). Ten prompts cannot rank checkpoints; the final scores (bpb on both held-out sets, EXTRA_EVAL) and the unwritten 200-prompt repair-accuracy driver can.

## ▶ EARLIER (2026-10-02) (2026-10-02, 12:30 UTC-6): legere reviewed; the trainer can now start ana from the fp100m plan; the box waits for a yes

**The user's direction (2026-10-02 afternoon):** legere is the next generation of ana's data path, meant to feed ana new training material continuously; ana's Bend trainer should start training on our dataset on a rented GPU box; and legere improves iteratively so each round of sessions becomes transcripts.

### What was done this afternoon

1. **legere assessed** (the review is in `docs/LEGERE.md`, "Assessment"; the verdict in short):
   - The denotational core is sound: `Spec.bend` is a real semantic function (every labelling enumerated), `Forward.bend` is held to it exactly in Bool and Nat and to 1e-4 in logp/maxp (`bend tests/legere.bend`: 11 `ok` lines, re-run today), and `roundtrip` is a proof, not a test. Spec and implementation are both Bend, as asked.
   - Three claims were tightened: "the run is a monoid homomorphism" was listed as a law but never stated or tested (it is a fold by construction; removed from the laws below); the line model `Λ_t` (hashed Witten-Bell) has no specification of its own, only the Σ_b P = 1 test; the boundary posterior (Jev's `Noul`) is computed and tested but not written to `sections.nul`.
   - The design flaw behind the known weakness: the mean-per-byte scale (fit at 0.5) throws away the block's *length* as evidence, so a 20-line Haskell block adds only 1–6 nats against a 4.5-nat entry prior. The summed form overcounts because lines in a block are not independent given the tag. The fix that keeps the meaning is a context-conditioned line model, `Λ_t(line_i | line_{i-1})`: the emission table is still a function of the text, so Spec, Forward and the tests apply unchanged. That is the next legere model, ahead of the entry-prior split.
   - The output is straightforward to convert: `segment → units → bend-check → bend-clean → bend-transcript` runs unchanged on legere's files and produced correct transcripts. The yield is the problem (10 transcripts from 3,172 docs), not the shape; see "legere's next round" below.
2. **The trainer gained a plan start** (`bend/TrainDense.bend`, `Checkpoint.bend` `Save.*`, `Dense/Plan.bend` `identity`/`batch`; `docs/BEND-PORT.md` "Plan start"). Until today a fresh run could only tokenize a text file and a hot start alone read a plan's shards: **the fp100m run could not have started.** Now `PLAN` set with `TRAIN_INIT` empty trains from fresh parameters on the plan's shards and schedule and saves FTC2 every `SAVE_EVERY` steps, which `TRAIN_INIT` continues. The micro-batch must divide the batch in every mode (a remainder used to drop its windows silently). `PRESET=fp-tiny` (fp100m's vocabulary and context, toy dimensions) exists for CPU tests.
   - **CPU round trip** (plan start 2 steps on fp100m's shard 0 saving each step, then a hot start from step 1 for one step; the step-2 lines and checkpoints must agree): **passes** (12:43 UTC-6): B's step-2 line equals A's (train_loss 10.148527, gradient_norm 2.7763617) and the step-2 checkpoints are byte-identical (sha256 `64dd2b66…`, 35.4 MB). A CPU step of fp-tiny at batch 16 × ctx 2048 takes ~890 s, so the test is a 45-minute run (`scratchpad/plan/roundtrip.sh` of this session; the recipe is in `docs/BEND-PORT.md`). The flake's `bend-dense` identity check still passes (goldens unchanged). One thing the log showed: training-time validation averages over *whole* micro-batches, so `EVAL_WINDOWS` below `TRAIN_MICRO` prints `validation_loss=0`; keep it a multiple (fp.sh uses 128 at micro 4).
3. **The box is staged, not rented** (`bend/gpu/fp-stage.sh HOST PORT` (unwired 2026-10-15: `bend-ops stage box HOST PORT`), then on the box `fp.sh gate`, `fp.sh time`, `fp.sh run`, `fp.sh eval`; `bend/gpu/fp100m-box.env` for `bend-push`). Checked today without a box: `bend TrainDense.bend -o traind.c` works on 2.0.34 (5.8 MB of C, 7 s); it compiles clean with clang under `-DBEND_CUDA=1 -DBEND_NO_SRC` against CUDA 12.8 headers and stubs, and as a CPU binary it trains; `bend-push` dry run sends the plan, the tokenizer and the 36 shards in plan order, **0.64 GB** in all. The GPU gate on the box is G2 (`tests/dense.bend` on the GPU against the tree trainer, every gradient within 1e-5); the rebased fork has never run on a GPU, so the gate comes first. Kernel strategies pin with `BEND_FT_STRAT=1` (one integer for every einsum kernel; 1 is the only value valid for every shape) when two GPU runs must agree.

### The box (2026-10-02 afternoon; the user: "Do rent box", "Keep cheap", "Only one box")

- **First box, vast 53902708** (RTX 3090, Pennsylvania, $0.245/h with an 80 GB disk): G2 gate **PASS** on the GPU (the dense program matches the tree trainer's CPU gradients to 4e-7 relative, both chunks, both shapes; the rebased fork's first GPU run); `fp.sh time 20`: **5,182 ms/step = 6,317 tok/s** at micro 4, SM 100%, 284 W, 6.9 GB on the card (the store), host RSS 4.8 GB (peak 11.3 GB). The run reached step 191 (loss 10.41 → 4.01), then the user chose a cheaper box and it was **destroyed** (its logs are in `run/pulled-vast-53902708/`). The search that picked it required ≥ 64 GB RAM and 300 Mb/s down, which hid the cheaper offers: the run needs ~12 GB of host RAM.
- **Second box, vast 53907028**, destroyed after 6 minutes unused: listed at $0.139/h, billed $0.230/h. **vast's listed `dph_total` assumes a small disk; the real price is `dph_base + storage_cost × disk_GB / 720`, and storage_cost varies 10× between hosts** ($0.867/GB-month on that one: $0.096/h for 80 GB). Price every offer at the disk you will ask for, plus `inet_up_cost` × the GB you will pull.
- **Third box, vast 53907415: RTX 5090** (California, $0.506/h with a 45 GB disk, image `nvidia/cuda:12.8.1-devel-ubuntu22.04`), the user's choice over a $0.159/h 3090: est. $2.20 (4.2 h) to $3.62 (7 h) against the 3090's $2.11 over 12.9 h. Blackwell (sm_120) has never run the fork: the einsum kernels take their architecture from the device at runtime (`comp.ts:5231`), so a CUDA ≥ 12.8 image is needed; the G2 gate decides, and on a failure the box is destroyed and the 3090 rented.
- **That 5090 never started** (vast answered `success: False` and left a stopped stub; someone else took the offer); the stub was destroyed. **Fourth box, vast 53909778: RTX 5090, South Korea, $0.488/h** with a 45 GB disk, reliability 0.998, CUDA 12.8.1 image. Measured: G2 gate **PASS on Blackwell** (gradients within 4.5e-7; the fork's first sm_120 run); `fp.sh time 20`: **1,951 ms/step = 16,781 tok/s, 2.66× the 3090**, 500 W, 99% SM, 7.2 GB on the card; its first 20 losses equal the 3090 run's to 6 digits. **The whole plan ≈ 4.8 h ≈ $2.35.** Links from here: 1.25 MB/s up, 3 MB/s down (a 1.85 GB checkpoint ≈ 10 min).
- **The run started 14:01 UTC-6** (trainer pid 1699; ends ≈ 18:50 UTC-6). `ft-fp-finish` (restarted for this box, into `run/pulled-vast-53909778/`) now pulls every 1000th checkpoint *while the run goes on* (only once the log says `saved`, since saves write in place), then scores those and the last on the held-out transcripts, pulls the last, verifies every sha256 and destroys the box.
- **The relay replaced the finisher** (stopped 16:31; the relay first failed at once because `fp-relay.sh` lacked its executable bit, so nothing pulled or watched until it was restarted through `bash` at 17:56). `ft-fp-relay` runs `run/fp-relay.sh` (a copy of `bend/gpu/fp-relay.sh`, unwired 2026-10-14 with fp-finish.sh: bend/gpu/fp-chain.sh replaced both, and `bend-ops chain` replaced fp-chain.sh on 2026-10-15; bash reads a running script, so never edit the copy in use), log `run/pulled-vast-53909778/relay.log`. It pulls fp100m's every-1000th checkpoint during the run; when fp100m ends it waits up to 30 minutes for the next plan on the box (`run/next/plan-next-b16-windows.tsv`, its shards `run/next/shard-K-next.corpus`, the marker `run/next/STAGED`, and `traind-next.c`, already built there as `traind-next` from `a8520b2`), starts `fp.sh next out/fp100m-step8803.checkpoint` (TRAIN_NEXT, lr 1e-4 after 100 warmup steps, cosine over the plan), follows it the same way, then scores every pulled checkpoint on `run/eval/transcript-fp.corpus` and `run/eval/transcript-next.corpus`, pulls the last ones, verifies the sha256 and destroys the box. Without the next plan in time it scores, pulls and destroys. Building `traind-next` on the box (clang, nice 19) did not move the trainer's 1,987 ms/step.
- **The continuation's data, done 17:41** (two agents, this machine only, the box untouched):
  - **Haskell:** 15,715 train / 317 holdout transcripts (~5.2M tokens) from 8,858 kept units of ~21.3k checked, out of 341 GitHub repos not on Hackage, shallow-cloned into `run/code-sources-next/curated/` (elm/compiler, unison, juvix, bsc, Kind, kitten, Carp, granule, cubicaltt, elaboration-zoo, exercism's solutions, 47 PL-research repos, 89 AoC/CIS194/book-solution repos, 179 interpreter/type-inference repos) plus 55 new telomare declarations. Pilot kept rates: exercism 97%, elaboration-zoo 93%, kitten 87%, cubicaltt 80%, Carp 77%, Kind 70%, elm 33%; unison, juvix, dex, sixten ~0 (missing dependencies). 2.3–4.5 CPU-s a unit. ~3,080 units of batch 4 never ran (`run/transcripts-next-r4p{9,10,11}/`). **342 symlinks in `run/code-sources/{curated,own}/` point into `run/code-sources-next/`** (the checker resolves ids there only), so a future `bend-extract` over `run/code-sources` takes these repos in.
  - **Bend2:** 5,489 train / 122 holdout transcripts (~1.9M tokens): own 555 new units (upstream bend2 at 75cc3602's new tests and benches, this repo's legere and trainer code, refl), the guide's 15 programs, and community round 4 (30 repos, 11 of them new: PedroAVJ/near-bend, michaelsproul/bentdelta, qasimkamran/Bend2-libs, ...; 8,721 new units, ~6,100 checked by the 17:40 cutoff, the rest in `run/transcripts-next-community2/bend/units.nul`). About half the community originals fail on the 2.0.34 checker (not investigated). ~10 CPU-s a unit. Every transcript carries the new verdict line (`ALL PROOFS CHECK` / `SOME PROOFS FAIL`).
  - **The largest untouched pool:** `HACKAGE_PCT=30` in the old extraction means 70% of the Hackage packages on disk (`run/code-sources/tarballs/`) were never turned into transcripts. That is the next round's Haskell, before any new download.
- **05:00 wave 2 first failed, then re-run:** the agents' finalize scripts call `deploy` by a hard-coded store path, and **that path had been garbage-collected overnight** (the build was not a GC root), so clean and render failed for all three languages while the checks' results survived. `nix build .#deploy -o run/gcroot-deploy` made it a root again and `ft-wave2b` re-ran the driver. **Rule: a long-running job that names a store path must hold a GC root for it** (`nix build ... -o run/gcroot-NAME`), or call `nix run .#X` each time. Raw slice 9 first failed too (its last 2000-document part was too short for one window; `raw-stage.sh` now keeps whole parts in the last slice). Raw slices 1–9 total 18,637 steps (≈ 10.3 h).
- **Overnight, unattended (set up 23:59):** the chain (`ft-fp-chain4`) runs e2 → n2 → **w1** (wave 1: 11,054 Haskell from never-used Hackage packages, 3,187 Lean, 3,805 Agda transcripts with 1:1 replay; 436 steps; staged 23:57) → **raw1…raw9** (raw code slices, appended by `ft-raw-driver` = `bend/gpu/raw-driver.sh` (unwired 2026-10-15: `bend-ops feed`) as each is built and pushed; ~1.3 h each) → scores → pull → destroy. **`ft-wave2.timer` at 05:00** runs `bend/gpu/wave-driver.sh w2` (unwired 2026-10-14, a one-off): the three agents' finalize scripts (`run/transcripts-w2/{haskell,lean,agda}-finalize.sh`, which stop their checks), build, push, and insert `w2` before the first raw slice not yet started. Expected end of the chain ≈ 13:00–14:00 on 2026-10-03 if every raw slice runs. 1lab cannot be checked (its library needs `--quote-metas`, which Agda 2.8.0 lacks). Agda wave 1's kept rates: agda-unimath 100%, agda-categories 98%, agda-stdlib 94%, agda's test/Succeed 57%, HoTT-Agda 6%. Haskell wave 1: 55% kept; the wave-2 scheduler starts a batch only with ≥ 16 GB free on /home, so the checkpoint pulls may stop it early.
- **ana tested (23:35):** `e2-step14000`, greedy (`TEMPERATURE=0`, 100 tokens, `bend-generate` on the CPU, ~0.94 s/token on 8 shared threads, ~84 s to load), 10 held-out first-time transcripts (2 per language) cut after `## Term` and the opening fence; ana's term put back into its unit and run through `bend-check` exactly as the corpus was built, with the references as controls. **Controls 10/10; ana 1/10** (Agda `mul-Commutative-Semigroup`, the reference up to a line break). It keeps the format (writes the term, closes the fence, then predicts the checker turn itself), uses the Context's names and mathlib-style tactics, but the terms are wrong; Bend degenerates into repetition, Nix whole-file tasks are near impossible as posed. Harness lessons for the repair-accuracy driver: **the transcript's Term is the body dedented** (Agda/Bend indentation removed, Lean's leading space removed), so an answer must be re-indented the way the reference maps to the stored body, and the every-line rule must win over the first-line rule when both fit (a one-line reference); the Bend checker needs `BEND_SRC` = the unit's class tree. Files: `run/anatest-20261002/`.
- **Raw code when nothing new is ready (the user, 23:00: "Feed it raw code when nothing new is available"):** `bend/gpu/raw-stage.sh mix` (unwired 2026-10-15, with raw-driver.sh: `bend-ops stage raw`, `bend-ops feed`) splits `run/code-train-v3.jsonl` into ana's five languages (232,923 Haskell, 23,608 Nix, 16,007 Lean, 8,112 Agda, 1,667 Bend files; Idris and Markdown left out) and interleaves them by count with fp100m's transcripts cycling at ~20% of the bytes (`run/raw/mix.jsonl`, ~2.5 GB ≈ 11 h of the 5090); `build K` makes slice K (300 MB ≈ 80M tokens ≈ 1.3 h) into `run/rawK/` with `bend-plan-corpus` (packed to 128 KB), `push K HOST PORT` stages it (plan last). Stage line: `rawK traind-next 0 run/rawK/plan-rawK-b16-windows.tsv run/rawK rawK`; **EVERY 0** = none of its checkpoints pulled, only its newest kept on the box and deleted once the next stage has loaded it (bounded disk both ends). **Order:** a transcript wave, when staged, is inserted in the stages file right after the stage that is training (the chain reads the file afresh at each boundary), so new transcripts always go before raw slices not yet started. Chain unit since 23:06: `ft-fp-chain4` (`run/fp-chain4.sh`).
- **After the chain's corpus (the user, 21:10: "use any agda, lean and haskell dataset you have access to"):** three agents (Haskell: the 70% of Hackage on disk never cut, cap 200/package; Lean: more declarations per file of mathlib4/batteries/lean4 than fp100m's 4, plus public Lean 4 proof datasets if a pilot checks ≥ 40% against our mathlib; Agda: more declarations per file of the Agda repos on disk, plus 1lab now that any public code is allowed) deliver **wave 1 by 00:00 UTC-6** in `run/transcripts-w1/{haskell,lean,agda}/` and leave their checks running for **wave 2** (`run/transcripts-w2/LANG-finalize.sh`, not yet run). Each wave becomes a stage: `NAME=w1 NEW="haskell-w1=run/transcripts-w1/haskell lean-w1=run/transcripts-w1/lean agda-w1=run/transcripts-w1/agda" bend/gpu/next-stage.sh build`, then `... push HOST PORT` (the plan lands last, after every shard's sha matches) (next-stage.sh unwired 2026-10-15: the same NAME and NEW with `bend-ops stage next`, then `bend-ops stage push w1 run/w1 HOST PORT`), then append `w1 traind-next 1000 run/w1/plan-w1-b16-windows.tsv run/w1 w1` to `run/fp100m-chain.stages`. **The chain (`ft-fp-chain3`, restarted 21:08) takes appended stages**: at the end of the list it waits up to 2 h for another line, and a stage whose plan is not on the box yet waits up to 2 h for it, before the scores and the destroy.
- **Tonight's chain (the user, 18:30: "run the same corpus again once it finishes" → "Both, in that order"):** `ft-fp-chain3` (since 21:08; before it `ft-fp-chain2`) runs `run/fp-chain3.sh` (a copy of `bend/gpu/fp-chain.sh`, unwired 2026-10-15: `bend-ops chain`) over `run/fp100m-chain.stages` (= `bend/gpu/fp100m-chain.stages`): **fp100m** (done 19:00:42 UTC-6 at step 8803) → **next** (the new code, steps 8803–9322, started 19:11) → **e2** (fp100m's second epoch, 8,803 steps from next's last save, lr 1e-4, warmup 440, ~4.8 h; checkpoints pulled every 2000) → **n2** (the new code again) → scores of every pulled checkpoint on both held-out sets (`eval.log`, `eval-next.log`) → pull → sha256 check → **destroy**. Expected end ≈ 00:45 UTC-6, ≈ $2.70 for the chain. Each stage is `fp.sh again` (TRAIN_NEXT) from the last save of the one before; a stage whose log is already on the box is followed, not restarted, so the chain can be stopped and started again at any time (`systemctl --user stop ft-fp-chain2`, then a fresh copy). Log: `run/pulled-vast-53909778/chain.log`. A dead stage (no trainer, log still 20 min) stops the chain at the scores.
- **The continuation, staged 17:55:** `run/next/` (built by `bend/gpu/next-stage.sh build`, pushed by `push` (both unwired 2026-10-15: `bend-ops stage next`, `bend-ops stage push`) with every shard's sha checked, then `run/next/STAGED` on the box): 43,164 transcripts (15,715 new Haskell, 5,489 new Bend2, 21,960 replay), **9,164 windows, 519 steps in 3 shards** (~18.7M tokens, ≈ 17 min on the 5090), warmup 25 steps, lr 1e-4; the held-out new transcripts as `run/eval/transcript-next.corpus` (175k tokens). 52 duplicate filler ids in the Haskell agent's `files-hi.nul` made `bend-mix` refuse; the first copies were kept (`files-hi.nul.with-dups` is the original).
- **The continuation's data, as planned** (prepared 14:30–18:00 by two agents on this machine): new Bend2 (upstream 2.0.34's new code, this repo's legere and trainer code, community repos updated since 2026-09-26) and new Haskell (GitHub repos not on Hackage), checked by the real checkers into `run/transcripts-next/{bend,haskell}/`, exact-deduplicated against the old corpus. The mix: `bend-plan-windows` over `run/transcripts-mix-next/` with `haskell-new` and `bend-new` read once and the old five languages as `:cycle` replay at about 1:1, in fp100m's proportions; the replay languages get no filler of their own.
- `vastai destroy instance ID` asks for confirmation: use `-y` (the finisher had it missing and would have aborted silently; fixed).

### The run, as approved (setting below unless the user changes it)

- **Box:** one RTX 3090 or better on vast.ai, ≥ 64 GB RAM, `--gpu 48GB`; test the link first (`bend-push link`, done by `fp-stage.sh`, unwired 2026-10-15 for `bend-ops stage box`).
- **Setting** (`fp.sh`, overridable): `PRESET=fp100m` (115M, ctx 2048), the plan's batch 16 in micro-batches of 4 (the store is 1.77e9 floats; 8 does not fit one array), Muon at lr 3e-4, warmup 300 of 8,803 steps, weight decay 0.01, clip 1.0, tf32 (master's v3 manifest had lr 3e-4, Muon 0.95, wd 0.01, clip 1.0, tf32, warmup 100 of 358k). A save every 500 steps (18 files of 1.85 GB), validation every 250 steps on 128 shard windows.
- **Cost:** `fp.sh time` measures it; at the hot start's 7,155 tok/s (ctx 256) the 288M tokens are 11 h; ctx 2048 at micro 4 will be slower per token (attention is quadratic and the micro-batch small), so plan on 12–20 h, a few dollars at 3090 prices, plus an hour of gates.
- **Ranking checkpoints:** `fp.sh eval` gives bits per byte on `run/eval/transcript-fp.corpus` (5.6 MB of held-out transcripts); the repair-accuracy driver (200 held-out prefixes sampled and re-checked) is still unwritten and ranks them properly.
- **Open hyperparameter question:** Muon's lr is the manifest's 3e-4 as in v3; the G3 speed benchmark used 0.02. Keep 3e-4 unless the user says otherwise.

### legere's next round (so each batch of sessions becomes training data)

1. **Yield:** 10 transcripts from 3,172 docs. The losses, in order: the session converter elides long Write blocks (38 Haskell files lost: fix upstream in `~/src/llm-transcript`, export whole files); Edit calls (987 `.hs`) are diffs, not files (reconstruct by applying them to the Read'd original); project modules not on disk (check Write'd files inside their repository).
2. **The model:** the context-conditioned line model above; then the entry prior by authoring context; then compiler acceptance as a likelihood.
3. **Shape:** write the boundary posterior into `sections.nul` (Jev's second question); a `Ngram.spec` (exact counts in a `Map`) that the hashed table is held to on small corpora.
4. **The loop:** a warm start of ana on a *new* plan (`TRAIN_INIT` plus a different `PLAN`: load the parameters and moments, write a new manifest with the new plan's identity and total). The plan start shares all the code it needs; it is the next trainer change once the first run exists.

**Still for the user to decide** (unchanged): failing session code as "given code + compiler notes" transcripts; mixing Bend's new `ALL PROOFS CHECK` verdict with the 81k older `All terms check.` transcripts.

Also today, before the review: legere v1 end to end (`docs/LEGERE.md` has the numbers: 0.593 bits/line vs 1.680 on named blocks with names hidden; 0.615 vs 2.322 with nothing forced; 51,368 sections, byte-exact; 15 code sections checked, 10 transcripts), bend2 rebased onto upstream 2.0.34 (`hhefesto/bend2` `14c97234`, locked at `7b05622`; upstream solved none of the fork's needs) and the `IO.args` fix in all 15 tools (`c5302ce`).

## The goal

**What Jev is.** Jev (TypeSafe AI, "System One") is a *decision model*: evidence plus a typed question gives a typed answer with a probability, never prose. legere is ours, in Bend2. It does four things:

1. It reads raw text. The first source is the user's Claude Code sessions, `~/src/llm-transcript/corpus.jsonl`.
2. It cuts the text into sections and tags each one with ana's tags (prose, or code in `haskell agda lean bend nix`, or other), each with a posterior.
3. It checks runnable code with the real compiler.
4. It emits units that the existing pipeline (`bend-check`, `bend-clean`, `bend-transcript`, `bend-plan-windows`) turns into ana transcripts unchanged.

Decisions taken with the user on 2026-10-02:

1. **Name `legere`.** Latin for both "to read" and "to pick out, gather". Binary `bend-legere`, module `bend/Legere.bend`.
2. **Prose maps onto transcript turns.** The prose before a code block becomes `## User`, signatures `## Type`, definitions `## Term`, and the checker turn follows.
3. **First input: the sessions corpus.**

## The meaning

The meaning is written in Bend, and the fast code refines it (Elliott; Goodman; Bradley).

- **Tags:** `Prose | Code{lang} | Other{name}`.
- **Typed questions:** `classify(section) : Dist Tag`, `boundary(line) : Dist Bool` and `check(L, code) : Check`. The compiler is the decider.
- **Calibration** is a measured property, never assumed. The ideal legere is the true `P(tag | text)`, the unique minimiser of the log-score.
- **The segmenter is a weighted language over a semiring:** `D = (Σ_t s_t · (Λ_t)⁺)⁺` over lines, where `Λ_t` scores one line under tag t. The carrier chosen answers each question:
  - `Bool`: is the text well formed?
  - `Nat`: how many segmentations?
  - `LogProb`: the posteriors (by forward-backward).
  - `Viterbi`: the best segmentation itself.
- **Laws**, stated on meanings and held in `bend/tests/legere.bend` unless marked proven:
  - the round trip `flat (sections ps) == lines ps` (proven, `law roundtrip`);
  - Forward equals Spec exactly in Bool and Nat, within 1e-4 in logp and maxp (score, marginals, boundaries, posteriors, Viterbi);
  - `Bool` is `Nat`'s support (n ↦ n > 0 is a semiring homomorphism);
  - every posterior row sums to 1.
  (Forward's run over `u ++ v` is a fold by construction; no separate law is claimed.)

## Facts

**The FP-agent corpus is built.** The Bend ×4 rebuild finished on 2026-10-01 at 21:31: `run/fp100m/plan-fp100m-b16-windows.tsv`, 156,067 windows of 2,046 tokens, 8,803 global steps at batch 16, `shard-{0..35}-fp100m.corpus`. Two things remain on that path: the store split (2b) and the run itself, which needs a box (ask first); see `e9cce23:HANDOFF.md`, Phases.

**The sessions corpus** (`~/src/llm-transcript/`):
- `corpus.jsonl` holds 3,172 docs (11 MB, `{"id","text"}`) from 26 sessions. `corpus.jsonl.holdout.jsonl` holds 273 docs from 4 sessions.
- The turns are `## User` / `## Assistant`.
- Tool calls appear as `### Write — \`path\``, `### Edit — \`path\`` (followed by a ```` ```diff ```` fence) and `### Read — \`path\``.
- Command output appears under `**stdout:**` / `**stderr:**` (4,483 / 237).
- Fences: 18,112 bare, 5,045 `sh`, 1,865 `diff`, 8 `haskell`, 4 `agda`, 1 `nix`.
- Write calls by extension: 54 `.hs`, 140 `.md`, 29 `.sh`, 15 `.tel2`. Edit calls: 987 `.hs`, 78 `.nix`, 66 `.agda`.
- These cues are free labels: hide them and predict them back.

**Research** (deep-research run, 2026-10-02):
- DocJev (github.com/jerryjliu/docjev, the only verified view of Jev segmenting) asks a category `Choice` and a boundary `Noul` per page. It claims **no** calibration; a segment's score is a plain mean.
- NLoN (arXiv 1803.07292) separates prose from code per line (AUC 0.98 within one source) but does not name the language.
- Guesslang lacks Agda, Lean, Nix and Bend.
- StarCoder2's notebook format (merged same-kind blocks, text/code/output sentinels, `<empty_output>`) is the precedent for the output shape.
- APRIL (arXiv 2602.02990, Lean diagnostics with error, line, column and goal) supports compiler notes for *repair fine-tuning*. No verified evidence shows they help in pretraining, so that is an ablation for later.

## Phases

| phase | what | state |
|---|---|---|
| 0 | HANDOFF.md restarted | **done** |
| 1 | `Legere/Spec.bend` + `Semiring.bend` + brute-force reference + `tests/legere.bend` | **done** (`e1a5f10`) |
| 2 | `Ngram`, `Lines`, `Forward`; `train`, `segment`. Gate: Forward/Viterbi equal the reference; the round trip is byte-identical on all 3,172 docs | **done** |
| 3 | Calibration + `eval`. Gate: on the holdout, beat both the prior-only and the cue-rules-only baselines on log-score | **done** (0.593 vs 1.680, 0.615 vs 2.322 bits/line) |
| 4 | `units`, then the existing check/clean/render on the sessions' code. Gate: transcripts read right by eye, and `bend-plan-windows` accepts them | **done** for check and render; `notes` added; plan-windows not yet run on them (only 10 transcripts) |
| 5 | Flake: `bend-legere`, the deploy PATH, the `bend-tests` check | **done**; `Legere/Spec.bend` is in `Everything.bend` |

**ana's training path** (the fp100m run):

| step | what | state |
|---|---|---|
| T1 | the trainer starts from a plan (`PLAN`, fresh parameters, FTC2 saves) | **done** today; CPU round trip above |
| T2 | the box staged: `fp-stage.sh`, `fp.sh`, the push env; C generation and CUDA compile checked locally (fp-stage.sh unwired 2026-10-15: `bend-ops stage box`) | **done** today |
| T3 | the box: G2 gate on the GPU, `fp.sh time`, then `fp.sh run` over the whole plan; checkpoints pulled and ranked | **needs a box: ask first** |
| T4 | the repair-accuracy eval driver (200 held-out prefixes, `bend-generate` + `bend-check`) | not written |
| T5 | warm start on a new plan, for legere's rounds | not written; designed above |

Later, not v1:
- compiler acceptance as a likelihood (top-2 check, Bayes update);
- ana itself as `Λ_t`;
- Edit-diff reconstruction;
- checking Write'd files inside their source repo;
- the compiler-notes-in-pretraining ablation (needs a box: ask first).

## Where things are

- **legere** (new): `bend/Legere.bend`, `bend/Legere/*.bend`, `bend/tests/legere.bend`, `docs/LEGERE.md`. Outputs go to `run/legere/`.
- **What legere reuses:**
  - `bend/Sys.bend`: text helpers, `run` for spawning, `env`, `slurp`, `emit`, `Rd.lines`.
  - `bend/Units.bend`: `lines` (:197); the fence logic `md.opens`/`md.go` (:255-286); the per-language declaration cutters; the unit record (:16-27).
  - `bend/Json.bend`, `bend/Nul.bend`, `bend/Clock.bend` (`say`, UTC-6).
  - `bend/Check.bend` and `bend/Check/*.bend`: the checkers.
  - `bend/Transcript.bend`: the renderer. Its User line is field 3, `doc`.
  - `bend/PlanWindows.bend`: it reads `OUT/LANG/transcripts.train.nul` and the filler `files-{hi,lo}.nul`.
- **Transcript pipeline:** `docs/TRANSCRIPT-FORMAT.md`; `nix run .#deploy -- transcripts STAGE LANG`; `nix run .#deploy -- check LANG UNITS.nul RESULTS.nul [JOBS]`.
- **Bend2:**
  - The fork is `~/src/bend2`: remote `hhefesto`, branch `ft-kernels`. Never push to `origin`.
  - The guide is `~/src/bend2/guide/GUIDE.md`; Base is `~/src/bend2/bend2/base.bend`. Base has `Map` keyed by String (:84, :3039).
  - F32 only (no F64).
- **References:**
  - `~/src/conal-elliott`: `paper-2021-language-derivatives/Weighted.lagda` is the cleanest spec of weighted ν/δ; `weighted-derivatives/haskell/WeightedDerivatives.hs`; `NOTES-bradley-vs-elliott.md`.
  - `~/src/tai-danae-bradley`: use paper 10's composition *inequality*, not paper 06's equality.
- **Flake:** `bendBinary pkgs NAME ENTRY` (`flake.nix:46-54`); packages at :67-111; the `deploy` app at :122-163; `bend-tests` at :427-470.
- **The run on a box** ("Operating a run with the Bend tools (2026-10-15)" above): `bend-ops` here (bend/Box/Main.bend: stage, chain, watch, feed, act, evals, sim, lint), `bend-box` on the box (bend/Box/OnBox.bend: build, gate, time, run, again, next, resume, eval, eval-both; bend/gpu/fp.sh is its fallback until it has run on a GPU), and bend-push's settings in `bend/gpu/*-box.env` (fp100m, v2, v3). The scripts these replaced (fp-stage.sh, fp-restage.sh, next-stage.sh, raw-stage.sh, raw-driver.sh, act-box.sh, fp-chain.sh, credit-watch.sh) were unwired on 2026-10-15. The trainer's modes are in `docs/BEND-PORT.md` ("Hot start", "Plan start"). The fp100m corpus is `run/fp100m/` (36 shards, 0.64 GB, plan `plan-fp100m-b16-windows.tsv`); the eval corpus `run/eval/transcript-fp.corpus`.
- **The v3 manifest's hyperparameters** (read from `run/pulled-vast-52365970/v3-bend-step28000.checkpoint` today): lr 3e-4, betas 0.9/0.999, eps 1e-8, wd 0.01, warmup 100, total 358,276, Muon 0.95, clip 1.0, tf32, batch 64.

## Bend pitfalls met

- **A Bend process evaluates on one thread.** `IO.fork` gives concurrency for effects only, so parse-heavy work fans out as processes (`SHARD/SHARDS`, `Transcripts.bend:600-612`).
- **Parsers must stay linear.** Never append to the end of an accumulator per line, and never `+`-copy an accumulator for a strict `Bool.pick`.
- **SIGTERM:** a busy Bend process, with or without forked jobs, exits on SIGTERM. Measured 2026-10-02 on both compilers; the old "ignores SIGTERM" note was probably the `sh`/`timeout` wrapper. `systemctl --user kill -s KILL` is still the sure stop for a unit.
- **`IO.print` never flushes.** Log to stderr (`Clock.say`) or run under `stdbuf -oL`.
- **Large Nat literals:** `1000n` and `70000n` compile and run on both compilers in a plain program (2026-10-02). `U32.to_nat(N)` stays the safe spelling where the old overflow was seen.
- **`IO.args` leads with the program** (Bend 2.0.32+). Every main drops it with `List.tail`.
- **Bend reserves `is` as a keyword**, so it can't name a variable.
- **A `match` and a destructuring `let` take only a parameter or a pattern variable, never a computed value.** Pass the pair to a helper that takes it as a parameter. The same rule forbids `(a, b) = x` inside a `do` block.
- **A def must come before its callers, and mutual recursion is refused.** Make a strict `Bool.pick` lazy with a flag argument the next call matches on (`Legere/Lines.bend` `count.go`).
- **`Done` is a reserved constructor name.**
- **Nix sees only git-tracked files**: `git add` a new `.bend` before any nix build.
- **Long jobs run as transient systemd user units:** `systemd-run --user --unit=ft-NAME -p MemoryMax=… -p OOMPolicy=continue`. Caps are generous guards, not throttles.

## Rules

- **Money:** rent a GPU box only once everything is staged, and ask the user before spending money. That covers boxes and the Claude Message Batches API.
- **Box hygiene:**
  - DESTROY a box, never stop it; `vastai` lives in `~/.local/share/vastai-venv`.
  - Run long jobs under `nohup` and `stdbuf -oL`, because the Bend runtime's print does not flush.
  - Check `nvidia-smi -q -d PERFORMANCE` for thermal slowdown.
  - A CUDA-built Bend program uses the GPU by default, so a CPU baseline needs `--gpu off --threads N`.
- **Git:**
  - Commits carry no Co-Authored-By. Nothing is pushed without asking.
  - `private/*` branches push only to the `private` remote. Never push to `origin` in `~/src/bend2`.
- **Logs:** every log line is stamped in Mexico City time (UTC-6), from our own wall-clock effect, `ck.wall` in bend/Clock.bend (bend/effs/wall.c and wall.js; the fork's `IO.time` until 2026-10-15).
- **Subagents:** they run on Opus 5.5 only, never another model.
- **Shell is a thin shim (2026-10-14, the user: "I want all logic to be in bend"):** `bend-ops lint` (bend/Box/Lint.bend; the flake check `shell-lint`) allows a shell file at most 12 lines of `set -euo pipefail`, `export`, `cd` and one final `exec`; `tools/lint/shell-allow.txt` lists the live scripts still to port (a ratchet: an unlisted file with logic fails); since 2026-10-15 it holds only bend/gpu/fp.sh, BOX_DRIVER's fallback until bend-box has run on a GPU. A dead script is unwired, not deleted: `# UNWIRED DATE: why` and `exit 2` after its shebang. Since 2026-10-15 a flake.nix body may hold plain sequential commands, and the check runs `--bend` strictly: an `sh -c` string with logic in a Bend source fails it.
- **Byte identity:** every layout or corpus-tool change is held to it, with `bend-ops dense-identity` for the trainer (bend/tests/dense-identity.sh until 2026-10-15, when it was unwired) and `cmp` of `.corpus`, plan and results files for the tools.
