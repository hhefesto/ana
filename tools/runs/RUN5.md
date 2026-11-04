# Run 5: ana for mugen

The goal (the user, 11-02): "close all the bend generation efforts (bring in whatever is cheap to bring in).
then work on getting me to a state where the only thing missing is to rent a gpu box to do training that'll do
well with mugen."

- **Start:** run 4's `run/v4/run4/out/c2-step72491.checkpoint`, hot start (`bend-box again`).
- **Data:** `run/v6/R5` (`tools/runs/run5-build.txt`): every language's sessions in the mugen shape
  (`docs/MUGEN-SHAPE.md`), the user's 4:1 rule, Bend at most 4 repairs a unit.
- **Box:** 2 days of an RTX 5090 (the user, 11-03). Run 4's box took 2.15 s a step (15,250 tok/s), so 46 h is
  about 77,000 steps. The plan is sized to fit.
- **The number to beat:** `agent-mugen-eval` on the 176 held-out tasks: run 4's checkpoint solves 0.

## Before renting

`tail run/v6/run5-final.log` must end `end: run/v6/R5 is ready`. Then:

```sh
nix build --max-jobs 1 .#bend-ops -o run/gcroot-bend-ops
head -1 run/v6/R5/plan-fp100m-b16-windows.tsv | cut -d' ' -f3     # the plan's steps
```

## 1. Credit

Vast had $3.70 on 11-03. A 5090 was $0.47-0.87/h then, so 48 h plus disk and transfer is $26-44. Add about $45.
`~/.local/share/vastai-venv/bin/vastai show user --raw` shows the credit.

## 2. Rent

```sh
V=~/.local/share/vastai-venv/bin/vastai
$V search offers 'gpu_name=RTX_5090 num_gpus=1 reliability>0.98 inet_down>200 disk_space>=100 cpu_ram>=64' -o dph | head
$V create instance OFFER --image nvidia/cuda:12.8.1-devel-ubuntu22.04 --disk 100 --ssh --direct
$V show instances --raw
```

A contract end date past the run matters as much as the price. Put the ssh host, port and the instance id in
`tools/runs/run5.cfg`. Never stop the box: destroy it; the chain does.

## 3. Stage (from here, about 15 minutes)

```sh
export PATH=$PWD/run/gcroot-bend-ops/bin:$PATH
BOX_ENV=bend/gpu/v5-box.env bend-ops stage box root@IP PORT
rsync -e 'ssh -p PORT' --partial run/v4/run4/out/c2-step72491.checkpoint root@IP:ana/out/
ssh -p PORT root@IP 'cd ana && cp run/eval/v2-mugen.corpus run/eval/transcript-next.corpus'
```

The last line makes the chain's second score (eval-next.log) the mugen shape on held-out units.

## 4. Start (on the box)

```sh
cd ana && ./bend-box gate && ./bend-box time
NLR=1e-4 NWARM=300 ./bend-box again out/c2-step72491.checkpoint run/v6/R5/plan-fp100m-b16-windows.tsv run/v6/R5 fp100m r5
```

`gate` must say PASS. `time` should say about 2,150 ms a step and the plan's hours. `r5.log` should open with
`loaded ... c2-step72491` and `from step 72491`, its held-out loss near run 4's 1.715 on the mugen shape.

## 5. Leave it (from here)

```sh
bend-ops guard tools/runs/run5.cfg install
bend-ops guard tools/runs/run5.cfg
```

The chain (`ft-fp-chain-v5`) pulls a save every 5,000 steps. When r5 is done it scores them, pulls the last, checks
every checkpoint against its copy here, and destroys the box. The watch (`ft-credit-watch-v5`) stops the trainer
under $1 of credit so the chain can still pull and destroy.

## 6. Measure (here, about an hour on the CPU)

```sh
nix build --max-jobs 1 .#bend-corpus-v2 .#bend-generate -o run/v6/run5/gcroot
AGENT_DEPLOY=... AGENT_BIN=... bend-corpus-v2 agent-mugen-eval run/v6/run5/out/r5-stepN.checkpoint run/v6/run5/ev 8
```

Run 4's baseline is 0/176 (direct 0/67, fill 0/67, repair 0/42; `/tmp/bx/am/ev2`). `eval-next.log` gives bits a
byte on the held-out mugen sessions; run 4's own figure on them is measured before renting, below.
