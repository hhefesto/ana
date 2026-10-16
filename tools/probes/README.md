# Probes: a few fixed prompts to try a checkpoint on by hand

Quicksort, merge sort and the FFT in each of ana's five languages (`NAME-LANG.txt`,
LANG one of haskell, lean, agda, nix, bend). Each file is a prompt in the agent layout,
ending at the open fence of `## Term` where ana writes its answer. The Type block holds
everything the checker needs above the answer (imports; for the FFT, the complex type
and its operations), and Context lists the same names as signatures.

Run one, from the repository root:

    CKPT=run/v4/run4/out/c1-step65000.checkpoint TOKENIZER_FILE=weights/code32k.bpe \
    TOKENS=384 TEMPERATURE=0 AGENT_CALLS=4 BEND_FT_THREADS=3 \
    ELAN_TOOLCHAIN=leanprover/lean4:v4.34.0-rc2 \
      run/gcroot-ana/bin/ana --agent --prompt-file tools/probes/fft-haskell.txt

To run all five at once, start each one under `systemd-run --user --scope -p MemoryMax=5G`
(see the OOM notes in HANDOFF). Outputs from earlier runs are in `run/probes/CHECKPOINT/`.

The tool (`bend-agent-tool snippet`) only type-checks the answer. "solved" means it checked,
not that it is right, so test the behaviour by hand. The FFT of [1, 2, 3, 4] is
[10, −2+2i, −2, −2−2i].

`answers/fft-LANG.txt` holds a correct answer for each FFT prompt. Each was checked in
the tool's layout and gave the result above (2026-10-16). So a failed FFT probe is the
model's failure, not the prompt's.

Two prompts differ from the rest:
- **Bend:** an answer is only the def's body, so it cannot define helpers. The prompt
  therefore gives evens, odds, zip_with and twiddle (z(j)·e^(−2πi·j/n)). The other
  languages write these themselves.
- **Nix:** its builtins have no trigonometry, so the prompt's `let` defines sin and cos by
  their Taylor series.
