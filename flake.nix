{
  description = "ana: an autoregressive transformer specified, trained and evaluated in Bend, and the corpus tools that feed it";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Bend 2: the ft-kernels fork of bendlang/bend (github:hhefesto/bend2),
  # which adds the bulk GPU ops the dense trainer runs on (Array.gemm/mm on
  # cuBLAS, Array.einsum as generated CUDA kernels; each op's meaning is its
  # base.bend definition) and F32 file I/O (the wall clock, its IO.time until
  # 2026-10-15, is our own effect now: bend/Clock.bend's ck.wall over
  # bend/effs/wall.c and wall.js).  Bend is a flake; the
  # fork's `default` package runs its own source with Bun (upstream's
  # `default` fetches the release archive, which cannot carry the fork).
  inputs.bend2 = {
    url = "github:hhefesto/bend2/ft-kernels";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, bend2 }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      # What a build is allowed to see: a derivation handed the whole flake
      # source would rebuild on every prose edit.
      sourceOf =
        paths:
        nixpkgs.lib.fileset.toSource {
          root = ./.;
          fileset = nixpkgs.lib.fileset.unions paths;
        };
      # Every .bend source, and the C and JS of our own effects (bend/effs:
      # Clock.bend's wall clock, 2026-10-15), which a build splices in.
      bendSrc = sourceOf [
        (nixpkgs.lib.fileset.fileFilter (f: f.hasExt "bend") ./bend)
        ./bend/effs
      ];
      # What the shell lint reads (2026-10-14): every *.sh, every file without
      # an extension (its shebang may name a shell), flake.nix, the allowlist,
      # and every .bend (2026-10-15: --bend reads the sh -c strings in Bend).
      lintSrc = sourceOf [
        (nixpkgs.lib.fileset.fileFilter (f: f.hasExt "sh" || f.hasExt "bend" || !(nixpkgs.lib.hasInfix "." f.name)) ./.)
        ./flake.nix
        ./tools/lint
      ];
      # the pinned bend command (clang on its PATH, telemetry off)
      bendFor = pkgs: bend2.packages.${pkgs.stdenv.hostPlatform.system}.default;
      # A Bend2 program compiled to a native binary (C via clang).
      # the GHC `bend-check haskell` drives: the packages listed in
      # deploy/check/ghc-packages.txt (one per line, # comments)
      ghcPackageNames = builtins.filter (l: l != "" && builtins.substring 0 1 l != "#") (
        nixpkgs.lib.splitString "\n" (builtins.readFile ./deploy/check/ghc-packages.txt)
      );
      ghcHarness =
        pkgs: pkgs.haskellPackages.ghcWithPackages (p: map (n: p.${n}) ghcPackageNames);
      # the Agda the transcript harness drives (bend-check agda)
      agdaFor = pkgs: pkgs.agda.withPackages (p: [ p.standard-library ]);
      bendBinary =
        pkgs: name: entry:
        pkgs.runCommand name { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
          export HOME=$TMPDIR
          cp -r ${bendSrc}/bend src
          chmod -R u+w src
          mkdir -p $out/bin
          bend src/${entry} -o $out/bin/${name}
        '';
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          bend = bendFor pkgs;
          bend-generate = bendBinary pkgs "bend-generate" "Generate.bend";
          bend-bench = bendBinary pkgs "bend-bench" "Bench.bend";
          # the Bend2 trainer: CORPUS, TOKENIZER_FILE, PRESET, TRAIN_* as in
          # master; writes a BTC1 text checkpoint that bend-generate reads
          bend-train = bendBinary pkgs "bend-train" "Train.bend";
          # the dense trainer: the same environment (plus TRAIN_MICRO,
          # TRAIN_CHUNK), the step as programs over one store; a CUDA build
          # (clang and /usr/local/cuda present) runs it on the GPU
          bend-train-dense = bendBinary pkgs "bend-train-dense" "TrainDense.bend";
          # master's `evaluate CKPT CORPUS` (CKPT, CORPUS, EVAL_WINDOWS)
          bend-evaluate = bendBinary pkgs "bend-evaluate" "Evaluate.bend";
          # the corpus tools (deploy/plan-corpus.sh drives them), each
          # byte-identical to master's Haskell subcommand of the same job:
          # pack-stdin, prepare-bpe-stdin and plan-segment, over files
          bend-pack = bendBinary pkgs "bend-pack" "Pack.bend";
          bend-prepare = bendBinary pkgs "bend-prepare" "Prepare.bend";
          bend-plan-segment = bendBinary pkgs "bend-plan-segment" "PlanSegment.bend";
          # the corpus drivers: the code corpus from the source trees, its
          # shards and plan, the code eval corpora, the mix of sources, and
          # the transfer to a training box (with `bend-push link`)
          bend-extract = bendBinary pkgs "bend-extract" "Extract.bend";
          bend-plan-corpus = bendBinary pkgs "bend-plan-corpus" "PlanCorpus.bend";
          bend-code-evals = bendBinary pkgs "bend-code-evals" "CodeEvals.bend";
          bend-mix = bendBinary pkgs "bend-mix" "Mix.bend";
          bend-push = bendBinary pkgs "bend-push" "Push.bend";
          # the transcript corpus (docs/TRANSCRIPT-FORMAT.md): declarations
          # cut out of source files, then, after bend-check has run the real
          # checkers on them, rendered as transcripts
          bend-units = bendBinary pkgs "bend-units" "Units.bend";
          bend-transcript = bendBinary pkgs "bend-transcript" "Transcript.bend";
          # the checked units cleaned (exact and near duplicates, units
          # sharing a 10-gram with the eval holdout) and split train/holdout
          bend-clean = bendBinary pkgs "bend-clean" "Clean.bend";
          # the checkers: `bend-check LANG UNITS.nul RESULTS.nul [JOBS]` runs
          # ghc, agda, lean, nix-instantiate or bend on every unit's variants
          bend-check = bendBinary pkgs "bend-check" "Check.bend";
          # the stages from the code corpus to transcripts, per language
          bend-transcripts = bendBinary pkgs "bend-transcripts" "Transcripts.bend";
          # transcripts packed whole into one-context windows, the rest of
          # each window the end of a code file (`bend-windows plan` plans them)
          bend-windows = bendBinary pkgs "bend-windows" "Windows.bend";
          # the languages' transcripts mixed, packed into windows (with the
          # languages' files as filler) and cut into training shards with
          # their plan: `deploy plan-windows RUN_DIR SIZE BATCH LANG:PER ...`
          bend-plan-windows = bendBinary pkgs "bend-plan-windows" "PlanWindows.bend";
          # legere, a Bend Jev (docs/LEGERE.md): raw text cut into sections
          # tagged with ana's tags, with calibrated posteriors; its code goes
          # on to bend-units, bend-check and bend-transcript
          bend-legere = bendBinary pkgs "bend-legere" "Legere.bend";
          # corpus v2's tools (docs/CORPUS-V2.md): the holdout, the units
          # pooled and split, the filler, the raw code, the one mix, the
          # evaluation, and the steps the run scripts take (Python before)
          bend-corpus-v2 = bendBinary pkgs "bend-corpus-v2" "CorpusV2.bend";
          # ana's tool loop (docs/AGENT.md): the tools `ana --agent` calls
          # (the episode on stdin, the echo on stdout), and Agent/Spec.bend's
          # laws over a transcript file (the trainer's token reading against
          # the byte reading)
          bend-agent-tool = bendBinary pkgs "bend-agent-tool" "Agent/Tools.bend";
          bend-episode = bendBinary pkgs "bend-episode" "Agent/EpTool.bend";
          bend-agent-laws = bendBinary pkgs "bend-agent-laws" "Agent/Laws.bend";
          # bend-ops (bend/Box/, 2026-10-14: all logic in Bend, shell a thin
          # shim): the box operations from this machine, and `bend-ops lint`.
          # The programs it drives are on its PATH, as ana's wrapper does for
          # find; vastai stays the venv's ($V, ~/.local/share/vastai-venv).
          bend-ops = pkgs.writeShellApplication {
            name = "bend-ops";
            runtimeInputs = [
              pkgs.bash
              pkgs.openssh
              pkgs.rsync
              pkgs.coreutils
              pkgs.findutils
              pkgs.procps
              pkgs.util-linux
              pkgs.libnotify
              pkgs.git
              pkgs.gh
              # `stage box|restage` emit the trainer, the gate and bend-box as C
              # with the pinned compiler and push the corpus with bend-push
              (bendFor pkgs)
              self.packages.${system}.bend-push
            ];
            text = ''
              exec ${bendBinary pkgs "bend-ops" "Box/Main.bend"}/bin/bend-ops "$@"
            '';
          };
          # bend-box (bend/Box/OnBox.bend, 2026-10-14): the driver on a rented
          # box (fp.sh's modes, and eval-both).  A box builds it from box.c
          # with its own clang (`bend-ops stage box`); this package is for
          # running it here (tests, a sandbox box).
          bend-box = bendBinary pkgs "bend-box" "Box/BoxMain.bend";
          # the box in a sandbox: one binary whose argv[0] picks its part
          # (traind, traind-next, dense, nvidia-smi, clang, vastai); `bend-sim
          # links DIR` makes those names in DIR (bend/tests/Sim.bend)
          bend-sim = bendBinary pkgs "bend-sim" "tests/Sim.bend";
          # the GHC `bend-check haskell` drives: the common Hackage
          # packages, so a module importing only these checks on its own
          ghc-harness = ghcHarness pkgs;
          # the corpus tools by their job, with the toolchains they drive on
          # PATH: `nix run .#deploy -- check haskell UNITS.nul RESULTS.nul`
          # runs bend-check, `deploy transcripts all nix` bend-transcripts,
          # and so on (TOOL is the binary's name without `bend-`).  Run it
          # from the repository root.  nix-instantiate is the system's, as
          # when the Nix units were checked.  Lean comes through elan (a Lean
          # project pins its own toolchain).
          deploy = pkgs.writeShellApplication {
            name = "deploy";
            runtimeInputs =
              (map (t: self.packages.${system}.${t}) [
                "bend-check"
                "bend-transcripts"
                "bend-units"
                "bend-transcript"
                "bend-clean"
                "bend-windows"
                "bend-plan-windows"
                "bend-pack"
                "bend-prepare"
                "bend-plan-segment"
                "bend-extract"
                "bend-plan-corpus"
                "bend-code-evals"
                "bend-mix"
                "bend-push"
                "bend-legere"
                "bend-corpus-v2"
                "bend-ops"
              ])
              ++ [
                (bendFor pkgs)
                (ghcHarness pkgs)
                (agdaFor pkgs)
                pkgs.elan
                pkgs.coreutils
                pkgs.findutils
                pkgs.gnutar
                pkgs.gzip
                pkgs.git
                pkgs.rsync
                pkgs.openssh
              ];
            # the one line the plan keeps (2026-10-14: shell a thin shim; the
            # usage when no TOOL is given, exit 1)
            text = ''
              exec "bend-''${1:?usage: deploy TOOL [ARGS...]   (TOOL: extract, plan-corpus, code-evals, mix, push, transcripts, check, units, clean, transcript, windows, plan-windows, pack, prepare, plan-segment, legere, corpus-v2, ops)}" "''${@:2}"
            '';
          };
          # `ana`: the Haskell-era app of the same name, on the Bend2 decoder.
          # Its command line (flags, the WIKI_* environment, the newest local
          # checkpoint, --list, --prompt-file) is bend/Generate.bend's own;
          # the wrapper only puts `find` on its PATH (discovery lists run/
          # with it: Bend has no directory listing).  Run it from the
          # repository root so run/ and the tokenizers under weights/ resolve.
          ana = pkgs.runCommand "ana" { nativeBuildInputs = [ pkgs.makeWrapper ]; } ''
            makeWrapper ${self.packages.${system}.bend-generate}/bin/bend-generate $out/bin/ana \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.findutils self.packages.${system}.bend-agent-tool (bendFor pkgs) (agdaFor pkgs) ]}
          '';
          ana-bend = self.packages.${system}.ana;
          default = self.packages.${system}.bend;
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
        in
        {
          # every specification law and every implementation module it is
          # stated over type-checks and is proven: the compiler's verdict is
          # its exit status (1 on SOME PROOFS FAIL or a type error);
          # --check-only gives the verdict even if Everything.bend had a main
          bend-spec = pkgs.runCommand "bend-spec" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend --check-only src/Everything.bend
            touch $out
          '';
          # the self-contained unit tests, against known answers: each test,
          # what it must print and why are bend/tests/Checks.bend's `suite`
          # (agent.bend runs compiled and reads weights/code32k.bpe)
          bend-tests = pkgs.runCommand "bend-tests" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            mkdir -p src/tests/weights
            cp ${./weights/code32k.bpe} src/tests/weights/code32k.bpe
            cd src/tests
            # bend-ops' primitives (bend/tests/ops.bend) read their fixtures from
            # bend/tests/fixtures (bendSrc holds .bend files only)
            cp -r ${./bend/tests/fixtures} fixtures
            bend Checks.bend suite
            touch $out
          '';
          # shell stays a thin shim (2026-10-14): bend-ops lint over lintSrc
          # (every shell file and flake.nix's shell bodies) against the
          # ratchet in tools/lint/shell-allow.txt, and (--bend, strict since
          # 2026-10-15) every sh -c string in the Bend sources; the report is $out
          shell-lint = pkgs.runCommand "shell-lint" { } ''
            cd ${lintSrc}
            exec ${self.packages.${system}.bend-ops}/bin/bend-ops lint --tree . --bend --report "$out"
          '';
          # the sandbox box in the build sandbox (2026-10-15, Phase 1c): `bend-ops sim
          # stage push-drop`, the new side alone (SIM_NEW_ONLY): stage push over bend-sim's
          # ssh and rsync, a copy the link drops tried again, the shards' sha256, the plan
          # last, STAGED; the run's directory is $out
          ops-sim = pkgs.runCommand "ops-sim" { } ''
            export SIM_NEW_ONLY=1 SIM_REPO=${sourceOf [ ./bend/gpu ]} BEND_SIM=${self.packages.${system}.bend-sim}/bin/bend-sim BEND_BOX=${self.packages.${system}.bend-box}/bin/bend-box
            exec ${self.packages.${system}.bend-ops}/bin/bend-ops sim stage push-drop "$out"
          '';
          # the behaviour test's tasks and references are what its spec says
          # (2026-10-14: bend-corpus-v2 behaviour tasks --check, the Bend port
          # of tasks.sh, regenerates them in memory and compares byte for byte)
          behaviour-tasks =
            let
              src = sourceOf [
                ./tools/corpus-v2/behaviour/spec
                ./tools/corpus-v2/behaviour/tasks
                ./tools/corpus-v2/behaviour/refs
              ];
            in
            pkgs.runCommand "behaviour-tasks" { } ''
              export BEHAVIOUR_DIR=${src}/tools/corpus-v2/behaviour
              ${self.packages.${system}.bend-corpus-v2}/bin/bend-corpus-v2 behaviour tasks --check
              touch $out
            '';
          # the training stack: the hand-written pullbacks agree with central
          # finite differences (f32: 5% relative plus 3e-5 absolute, the
          # difference quotient's resolution at eps 0.01), the training
          # forward's loss is the decode path's (tests/train.bend decides
          # both), and a short byte-level run lowers the validation loss
          # (Checks.bend train-run)
          bend-train = pkgs.runCommand "bend-train" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend src/tests/train.bend
            cat src/*.bend src/Spec/*.bend > corpus.txt
            bend src/tests/Checks.bend train-run ${self.packages.${system}.bend-train}/bin/bend-train corpus.txt
            touch $out
          '';
          # the dense program against the tree trainer: same weights and
          # windows, the loss and every gradient within 1e-5 relative
          # (reverse mode derived from the ops, chunked GLA, both gate kinds;
          # tests/dense.bend decides); then a short dense run lowers the
          # validation loss, a validation set smaller than a micro-batch
          # scores above 0, and six steps per optimizer on a frozen corpus
          # give the goldens' parameters byte for byte
          # (bend/tests/dense-identity.sh wrote them, unwired 2026-10-15:
          # `bend-ops dense-identity` writes them; Checks.bend dense-run)
          bend-dense = pkgs.runCommand "bend-dense" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend src/tests/dense.bend -o dense
            ./dense --threads 4
            cat src/*.bend src/Spec/*.bend > corpus.txt
            bend src/tests/Checks.bend dense-run ${self.packages.${system}.bend-train-dense}/bin/bend-train-dense corpus.txt \
              ${./docs/haskell-era/RUN-2026-07-25-WIKI-FULL.md} ${./bend/tests/dense-identity.sha256}
            touch $out
          '';
          # the dense decode step (bend/Dense/Decode.bend, ana's engine)
          # against Model.bend's decode, its meaning: every position's logits
          # within 1e-5 relative, before and after the softmax ring wraps,
          # with and without v3's arms; a reset gives them again bit for bit
          # (tests/decode-dense.bend decides)
          bend-decode-dense = pkgs.runCommand "bend-decode-dense" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend src/tests/decode-dense.bend -o dd
            ./dd --threads 4
            touch $out
          '';
          # ana's chunked prefill (bend/Dense/Decode.bend dd.feeds: chunks of
          # up to C tokens through the chunk program) against the one-token
          # step it refines: the layers' states and the next logits bit for
          # bit and the store's greedy pick the same, chunks of 16 on ctx 64
          # (six runs: whole and partial chunks, a stepped remainder,
          # attention batched before the ring's wrap and per token across
          # and after it), with and without v3's arms; the chunked logits
          # within 1e-5 of Model.bend's decode (tests/prefill-dense.bend
          # decides)
          bend-prefill-dense = pkgs.runCommand "bend-prefill-dense" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend src/tests/prefill-dense.bend -o pd
            ./pd --threads 4
            touch $out
          '';
          # CPU bulk ops refine the Base definitions without changing F32
          # bits. Small cases compare to JS; seeded and adversarial cases
          # cover SIMD tails, threaded reductions, aliases and wrapping.
          # Checks.bend bulk-cpu runs every lane and compares the bytes.
          bend-bulk-cpu = pkgs.runCommand "bend-bulk-cpu" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend src/tests/Checks.bend bulk-cpu src
            touch $out
          '';
        }
      );

      apps = forAllSystems (system: {
        ana = {
          type = "app";
          program = "${self.packages.${system}.ana}/bin/ana";
          meta.description = "Generate text from the newest local checkpoint with the Bend2 decoder";
        };
        ana-bend = self.apps.${system}.ana;
        ana-bend-train = {
          type = "app";
          program = "${self.packages.${system}.bend-train}/bin/bend-train";
          meta.description = "Train with the Bend2 tree trainer (BTC1 checkpoints)";
        };
        bend = {
          type = "app";
          program = "${self.packages.${system}.bend}/bin/bend";
          meta.description = "The pinned Bend2 compiler and checker";
        };
        deploy = {
          type = "app";
          program = "${self.packages.${system}.deploy}/bin/deploy";
          meta.description = "The corpus tools (bend-check, bend-transcripts, ...) with the toolchains they drive";
        };
        default = self.apps.${system}.ana;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          agda = agdaFor pkgs;
          cudaPackages = pkgs.cudaPackages_12_8;
          cudaCudart = cudaPackages.cuda_cudart;
          cudaCccl = cudaPackages.cccl;
          cudaNvcc = cudaPackages.cuda_nvcc;
          cudaNvrtc = cudaPackages.cuda_nvrtc;
          cudaCublas = cudaPackages.libcublas;
        in
        {
          # Bend, plus the toolchains the transcript harness drives
          # (bend-check): the compilers and checkers of the languages
          # the corpus teaches.  Lean comes through elan, because a Lean
          # project pins its own toolchain (mathlib's lean-toolchain).
          default = pkgs.mkShell {
            packages = [
              (bendFor pkgs)
              (ghcHarness pkgs)
              agda
              pkgs.elan
            ];
          };
          cuda = pkgs.mkShell {
            packages = [
              cudaCccl
              cudaCudart
              cudaNvcc
              cudaNvrtc
              cudaCublas
            ];
            shellHook = ''
              export CPATH="${cudaCudart}/include:${cudaCccl}/include:${cudaNvcc}/include:${cudaNvrtc.include}/include''${CPATH:+:$CPATH}"
              export LIBRARY_PATH="${cudaCudart}/lib/stubs:${cudaCudart}/lib:${cudaNvrtc.lib}/lib''${LIBRARY_PATH:+:$LIBRARY_PATH}"
              export LD_LIBRARY_PATH="${cudaCudart}/lib:${cudaNvrtc.lib}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            '';
          };
        }
      );
    };
}
