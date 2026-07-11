{
  description = "A denotationally specified autoregressive transformer with Agda, Haskell, and Futhark interpretations";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          haskellPackage = pkgs.haskellPackages.callCabal2nix "formal-transformer" ./. { };
          futharkKernels = self.packages.${system}.futhark-kernels;
          gpuGhc = pkgs.haskellPackages.ghcWithPackages (p: [
            p.binary
            p.text
            p.vector
          ]);
          conformanceGhc = pkgs.haskellPackages.ghcWithPackages (p: [
            p.ad
            p.binary
          ]);
        in
        {
          default = haskellPackage;
          formal-transformer = haskellPackage;
          futhark-kernels = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-futhark-kernels";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.futhark ];
            buildPhase = ''
              runHook preBuild
              # The reduced entry set: rusticl's clBuildProgram time grows
              # with vjp-generated code, so the OpenCL trainer program keeps
              # a single differentiated entry (micro_batch_loss_grad).
              futhark opencl --library backend/futhark/kernels-opencl.fut -o kernels
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib $out/include $out/share/formal-transformer
              cp kernels.c $out/lib/
              cp kernels.h $out/include/
              cp kernels.json $out/share/formal-transformer/
              runHook postInstall
            '';
          };
          formal-transformer-gpu = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-gpu";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [
              gpuGhc
              pkgs.pkg-config
            ];
            buildInputs = [
              pkgs.ocl-icd
              pkgs.opencl-headers
            ];
            buildPhase = ''
              runHook preBuild
              $CC -O2 -c ${futharkKernels}/lib/kernels.c -I${futharkKernels}/include -o kernels.o
              ghc -O2 -threaded -DOPENCL_BACKEND \
                -ibackend/gpu -ibackend/src \
                backend/gpu/Main.hs backend/gpu/FutharkKernels.hs kernels.o \
                -optl-lOpenCL -o formal-transformer-gpu
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp formal-transformer-gpu $out/bin/
              runHook postInstall
            '';
          };
          formal-transformer-sequential = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-sequential";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [
              gpuGhc
              pkgs.futhark
            ];
            buildPhase = ''
              runHook preBuild
              futhark c --library backend/futhark/kernels.fut -o kernels
              $CC -O2 -c kernels.c -o kernels.o
              ghc -O2 -threaded \
                -ibackend/gpu -ibackend/src \
                backend/gpu/Main.hs backend/gpu/FutharkKernels.hs kernels.o \
                -optl-lm -o formal-transformer-sequential
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp formal-transformer-sequential $out/bin/
              runHook postInstall
            '';
          };
          # Same host and full kernel program as the sequential backend, but
          # compiled with Futhark's multicore C backend: every kernel runs
          # data-parallel across all CPU cores.  Checkpoints stay
          # interchangeable with the other backends.
          formal-transformer-multicore = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-multicore";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [
              gpuGhc
              pkgs.futhark
            ];
            buildPhase = ''
              runHook preBuild
              futhark multicore --library backend/futhark/kernels.fut -o kernels
              $CC -O2 -c kernels.c -o kernels.o
              ghc -O2 -threaded \
                -ibackend/gpu -ibackend/src \
                backend/gpu/Main.hs backend/gpu/FutharkKernels.hs kernels.o \
                -optl-lm -optl-lpthread -o formal-transformer-multicore
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp formal-transformer-multicore $out/bin/
              runHook postInstall
            '';
          };
          conformance = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-conformance";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [
              conformanceGhc
              pkgs.futhark
            ];
            buildPhase = ''
              runHook preBuild
              futhark c --library backend/futhark/kernels.fut -o kernels
              $CC -O2 -c kernels.c -o kernels.o
              ghc -O2 -threaded \
                -ibackend/gpu -ibackend/conformance -ibackend/src \
                backend/conformance/Main.hs backend/gpu/FutharkKernels.hs kernels.o \
                -optl-lm -o conformance
              ./conformance | tee conformance-results.txt
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/share/formal-transformer
              cp conformance $out/bin/
              cp conformance-results.txt $out/share/formal-transformer/
              runHook postInstall
            '';
          };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          agda = pkgs.agda.withPackages (p: [ p.standard-library ]);
        in
        {
          haskell = self.packages.${system}.formal-transformer;
          agda =
            pkgs.runCommand "formal-transformer-agda-check"
              {
                nativeBuildInputs = [ agda ];
                src = ./.;
              }
              ''
                cp -r $src source
                chmod -R u+w source
                cd source
                agda -i . Everything.agda
                touch $out
              '';
          futhark =
            pkgs.runCommand "formal-transformer-futhark-check"
              {
                nativeBuildInputs = [ pkgs.futhark ];
                src = ./.;
              }
              ''
                cp -r $src source
                cd source
                futhark check backend/futhark/kernels.fut
                futhark check backend/futhark/kernels-opencl.fut
                futhark check backend/futhark/tests.fut
                touch $out
              '';
          gpu-host = self.packages.${system}.formal-transformer-gpu;
          sequential-host = self.packages.${system}.formal-transformer-sequential;
          conformance = self.packages.${system}.conformance;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          cli = "${self.packages.${system}.formal-transformer}/bin/formal-transformer";
          sequential = "${self.packages.${system}.formal-transformer-sequential}/bin/formal-transformer-sequential";
          multicore = "${self.packages.${system}.formal-transformer-multicore}/bin/formal-transformer-multicore";
          gpu = "${self.packages.${system}.formal-transformer-gpu}/bin/formal-transformer-gpu";
          # Zero-argument Wikipedia training: starts a fresh run or resumes
          # the checkpoint it wrote last time.  Every default is an env
          # override, but the schedule is anchored to WIKI_STEPS at run
          # creation, so changing it later requires a new checkpoint path.
          #
          # WIKI_BACKEND defaults to the multicore CPU backend: it uses
          # every core and needs no watchdog care.  WIKI_BACKEND=opencl
          # opts into the GPU (right for the tiny preset, a compute-only
          # GPU, or once the compute-ring watchdog is raised — see
          # ~/src/etc-nixos-configuration/olimpo.nix); on a display GPU
          # with a 10 s compute-ring watchdog the small preset's gradient
          # kernel is soft-reset.  WIKI_BACKEND=sequential keeps the
          # single-core oracle backend.
          wikiTrain = pkgs.writeShellApplication {
            name = "wiki-train";
            runtimeInputs = [
              pkgs.jq
              pkgs.gawk
              pkgs.coreutils
            ];
            text = ''
              size="''${WIKI_SIZE:-small}"
              backend="''${WIKI_BACKEND:-multicore}"
              export TRAIN_BATCH="''${TRAIN_BATCH:-4}"
              case "$backend" in
                opencl)
                  # One sequence per launch keeps each kernel watchdog-sized.
                  export MICRO_BATCH="''${MICRO_BATCH:-1}"
                  trainer=${gpu} ;;
                multicore)
                  export MICRO_BATCH="''${MICRO_BATCH:-$TRAIN_BATCH}"
                  trainer=${multicore} ;;
                sequential)
                  export MICRO_BATCH="''${MICRO_BATCH:-$TRAIN_BATCH}"
                  trainer=${sequential} ;;
                *)
                  echo "wiki-train: unknown WIKI_BACKEND '$backend' (expected multicore, sequential, or opencl)" >&2
                  exit 1 ;;
              esac
              if [ "$backend" = opencl ]; then
                export FUT_CACHE="''${FUT_CACHE:-run/futhark-opencl.cache}"
              fi

              # Explicit-corpus mode: one corpus, one run, one epoch target.
              if [ -n "''${WIKI_CORPUS:-}" ]; then
                checkpoint="''${WIKI_CHECKPOINT:-run/wiki-small.checkpoint}"
                steps="''${WIKI_STEPS:-epoch}"
                mkdir -p "$(dirname "$checkpoint")"
                echo "wiki-train: corpus=$WIKI_CORPUS checkpoint=$checkpoint target=$steps size=$size backend=$backend"
                exec "$trainer" train "$WIKI_CORPUS" "$checkpoint" "$steps" "$size"
              fi

              # Whole-dataset mode (the default): consume EVERY article of
              # the Wikipedia dump, one shard at a time.  Each shard is a
              # line range of the JSONL, prepared into a corpus on the fly,
              # trained for one full epoch warm-started from the previous
              # shard's weights, and marked done.  The loop is resumable at
              # every level and finishes only when all shards are done —
              # i.e. when all possible training material has been used.
              data="''${WIKI_DATA:-$HOME/datasets/wikipedia-en/enwiki-natural-language.jsonl}"
              if [ ! -f "$data" ]; then
                echo "wiki-train: dataset not found: $data" >&2
                echo "  set WIKI_DATA to the articles JSONL (one {\"id\",\"title\",\"text\"} per line)" >&2
                exit 1
              fi
              rundir="''${WIKI_RUN_DIR:-run/wiki}"
              per="''${WIKI_SHARD_ARTICLES:-4000}"
              mkdir -p "$rundir"
              latest="run/wiki-latest.checkpoint"
              counted="$rundir/article-count"
              if [ ! -f "$counted" ]; then
                echo "wiki-train: counting articles in $data (one-time pass)..."
                wc -l < "$data" > "$counted"
              fi
              total="$(cat "$counted")"
              shards=$(( (total + per - 1) / per ))
              echo "wiki-train: $total articles, $per per shard -> $shards shards, size=$size backend=$backend"
              k=0
              while [ "$k" -lt "$shards" ]; do
                marker="$rundir/shard-$k.done"
                if [ -f "$marker" ]; then k=$((k + 1)); continue; fi
                corpus="$rundir/shard-$k.corpus"
                checkpoint="$rundir/shard-$k.checkpoint"
                start=$(( k * per + 1 ))
                end=$(( (k + 1) * per ))
                if [ ! -f "$corpus" ]; then
                  echo "wiki-train: preparing shard $k (articles $start..$end)"
                  awk -v a="$start" -v b="$end" 'NR>b{exit} NR>=a' "$data" \
                    | jq -j '.id, "\u0000", .text, "\u0000"' \
                    | ${cli} prepare-stdin "$corpus"
                fi
                if [ -f "$latest" ] && [ ! -f "$checkpoint" ]; then
                  export TRAIN_INIT="$latest"
                else
                  unset TRAIN_INIT
                fi
                echo "wiki-train: shard $k/$shards"
                "$trainer" train "$corpus" "$checkpoint" epoch "$size"
                cp "$checkpoint" "$latest"
                touch "$marker"
                rm -f "$corpus" "$checkpoint"
                k=$((k + 1))
              done
              echo "wiki-train: all $shards shards complete - the entire dataset has been consumed"
            '';
          };
          # Zero-argument generation: prefers the training app's checkpoint,
          # falls back to the committed 1000-step run.
          wikiGenerate = pkgs.writeShellApplication {
            name = "wiki-generate";
            text = ''
              prompt="''${WIKI_PROMPT:-A formal language}"
              tokens="''${WIKI_TOKENS:-128}"
              if [ -n "''${WIKI_CHECKPOINT:-}" ]; then
                checkpoint="$WIKI_CHECKPOINT"
              elif [ -f run/wiki-latest.checkpoint ]; then
                checkpoint=run/wiki-latest.checkpoint
              elif [ -f run/wiki-small.checkpoint ]; then
                checkpoint=run/wiki-small.checkpoint
              elif [ -f run/wiki-small-5000.checkpoint ]; then
                checkpoint=run/wiki-small-5000.checkpoint
              elif [ -f run/wiki-small-1000.checkpoint ]; then
                checkpoint=run/wiki-small-1000.checkpoint
              else
                echo "wiki-generate: no checkpoint found under run/" >&2
                echo "  train first: nix run .#wiki-train" >&2
                exit 1
              fi
              echo "wiki-generate: checkpoint=$checkpoint tokens=$tokens" >&2
              exec ${sequential} generate "$checkpoint" "$prompt" "$tokens"
            '';
          };
        in
        {
        default = {
          type = "app";
          program = "${self.packages.${system}.formal-transformer}/bin/formal-transformer";
          meta.description = "Run the formal transformer CPU reference tools";
        };
        wiki-train = {
          type = "app";
          program = "${wikiTrain}/bin/wiki-train";
          meta.description = "Start or resume Wikipedia training with default corpus, checkpoint, and schedule";
        };
        wiki-generate = {
          type = "app";
          program = "${wikiGenerate}/bin/wiki-generate";
          meta.description = "Generate text from the latest Wikipedia checkpoint";
        };
        formal-transformer-gpu = {
          type = "app";
          program = "${self.packages.${system}.formal-transformer-gpu}/bin/formal-transformer-gpu";
          meta.description = "Train and generate with the Futhark OpenCL backend";
        };
        formal-transformer-sequential = {
          type = "app";
          program = "${
            self.packages.${system}.formal-transformer-sequential
          }/bin/formal-transformer-sequential";
          meta.description = "Train and generate with the Futhark sequential-C backend";
        };
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          agda = pkgs.agda.withPackages (p: [ p.standard-library ]);
        in
        {
          default = pkgs.mkShell {
            packages = [
              agda
              pkgs.cabal-install
              pkgs.futhark
              pkgs.ghc
              pkgs.haskell-language-server
              pkgs.pkg-config
              pkgs.ocl-icd
            ];
          };
        }
      );
    };
}
