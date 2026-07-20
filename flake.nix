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
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          haskellPackage = pkgs.haskellPackages.callCabal2nix "formal-transformer" ./. { };
          futharkKernels = self.packages.${system}.futhark-kernels;
          futharkKernelsCuda = self.packages.${system}.futhark-kernels-cuda;
          # CUDA userspace. Futhark JIT-compiles its kernel PTX through NVRTC at
          # context creation, so NVRTC must (a) support the GPU's compute
          # capability and (b) not emit PTX newer than the host driver accepts.
          # CUDA 12.9 is the oldest toolkit in this nixpkgs pin that targets
          # Blackwell (sm_120). Futhark ships PTX and compiles it through NVRTC
          # at context creation, so rental hosts must advertise Max CUDA 12.9+.
          cudaPackages = pkgs.cudaPackages_12_9;
          cudaCudart = cudaPackages.cuda_cudart;
          cudaCccl = cudaPackages.cccl;
          cudaNvcc = cudaPackages.cuda_nvcc;
          cudaNvrtc = cudaPackages.cuda_nvrtc;
          cudaCublas = cudaPackages.libcublas;
          gpuGhc = pkgs.haskellPackages.ghcWithPackages (p: [
           p.binary
           p.cryptohash-sha256
           p.text
           p.parallel
           p.time
           p.vector
         ]);
          conformanceGhc = pkgs.haskellPackages.ghcWithPackages (p: [
            p.ad
            p.binary
            p.vector
          ]);
          gemmGhc = pkgs.haskellPackages.ghcWithPackages (p: [ p.vector ]);
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
          futhark-kernels-cuda = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-futhark-kernels-cuda";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.futhark ];
            buildPhase = ''
              runHook preBuild
              futhark cuda --library backend/futhark/kernels-opencl.fut -o kernels
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
          futhark-pieces = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-futhark-pieces";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.futhark ];
            buildPhase = ''
              runHook preBuild
              futhark multicore --library backend/futhark/pieces.fut -o pieces
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib $out/include $out/share/formal-transformer
              cp pieces.c $out/lib/
              cp pieces.h $out/include/
              cp pieces.json $out/share/formal-transformer/
              runHook postInstall
            '';
          };
          futhark-pieces-cuda = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-futhark-pieces-cuda";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.futhark ];
            buildPhase = ''
              runHook preBuild
              futhark cuda --library backend/futhark/pieces.fut -o pieces
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib $out/include $out/share/formal-transformer
              cp pieces.c $out/lib/
              cp pieces.h $out/include/
              cp pieces.json $out/share/formal-transformer/
              runHook postInstall
            '';
            meta.platforms = [ "x86_64-linux" ];
          };
          futhark-pieces-conformance = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-futhark-pieces-conformance";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ pkgs.futhark ];
            buildPhase = ''
              runHook preBuild
              futhark c --library backend/futhark/pieces-conformance.fut -o pieces_conformance
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/lib $out/include $out/share/formal-transformer
              cp pieces_conformance.c $out/lib/
              cp pieces_conformance.h $out/include/
              cp pieces_conformance.json $out/share/formal-transformer/
              runHook postInstall
            '';
          };
          gemm-blas-test = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-gemm-blas-test";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ gemmGhc ];
            buildInputs = [ pkgs.openblas ];
            buildPhase = ''
              runHook preBuild
              ghc -Wall -Wcompat -Werror -O2 -ibackend/gemm \
                backend/gemm/BlasTest.hs -lopenblas -o gemm-blas-test
              OPENBLAS_NUM_THREADS=1 ./gemm-blas-test
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp gemm-blas-test $out/bin/
              runHook postInstall
            '';
          };
          gemm-conformance = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-gemm-conformance";
            version = "0.1.0";
            src = ./.;
            nativeBuildInputs = [ conformanceGhc ];
            buildInputs = [ pkgs.openblas ];
            buildPhase = ''
              runHook preBuild
              $CC -O2 -c ${self.packages.${system}.futhark-pieces-conformance}/lib/pieces_conformance.c \
                -I${self.packages.${system}.futhark-pieces-conformance}/include \
                -o pieces_conformance.o
              ghc -Wall -Wcompat -Werror -O2 -ibackend/gemm -ibackend/src \
                backend/gemm/GemmConformance.hs backend/gemm/PiecesConformance.hs \
                pieces_conformance.o -lopenblas -lm -o gemm-conformance
              OPENBLAS_NUM_THREADS=1 ./gemm-conformance | tee gemm-conformance-results.txt
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin $out/share/formal-transformer
              cp gemm-conformance $out/bin/
              cp gemm-conformance-results.txt $out/share/formal-transformer/
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
              ghc -O2 -threaded -rtsopts "-with-rtsopts=-N" -DOPENCL_BACKEND \
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
          formal-transformer-cuda = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-cuda";
            version = "0.1.0";
            src = ./.;
            __structuredAttrs = true;
            strictDeps = true;
            nativeBuildInputs = [
              gpuGhc
              cudaPackages.removeStubsFromRunpathHook
              pkgs.patchelf
            ];
            buildInputs = [
              cudaCccl
              cudaCudart
              cudaNvcc
              cudaNvrtc
            ];
            buildPhase = ''
              runHook preBuild
              $CC -O2 -c ${futharkKernelsCuda}/lib/kernels.c \
                -I${futharkKernelsCuda}/include \
                -I${cudaCudart}/include -I${cudaCccl}/include \
                -I${cudaNvcc}/include \
                -I${cudaNvrtc.include}/include \
                -o kernels.o
              ghc -O2 -threaded -rtsopts "-with-rtsopts=-N" -DCUDA_BACKEND \
                -ibackend/gpu -ibackend/src \
                backend/gpu/Main.hs backend/gpu/FutharkKernels.hs kernels.o \
                -optl-L${cudaCudart}/lib/stubs \
                -optl-L${cudaCudart}/lib -optl-L${cudaNvrtc.lib}/lib \
                -optl-lcuda -optl-lcudart -optl-lnvrtc -optl-lm -optl-lpthread \
                -o formal-transformer-cuda
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp formal-transformer-cuda $out/bin/
              runHook postInstall
            '';
            postFixup = ''
              removeStubsFromRunpath $out/bin/formal-transformer-cuda
              case "$(patchelf --print-rpath $out/bin/formal-transformer-cuda)" in
                *stubs*) echo "CUDA driver stubs leaked into runtime RPATH" >&2; exit 1 ;;
              esac
            '';
            meta.platforms = [ "x86_64-linux" ];
          };
          formal-transformer-gemm-cuda = pkgs.stdenv.mkDerivation {
            pname = "formal-transformer-gemm-cuda";
            version = "0.1.0";
            src = ./.;
            __structuredAttrs = true;
            strictDeps = true;
            nativeBuildInputs = [
              gpuGhc
              cudaPackages.removeStubsFromRunpathHook
              pkgs.patchelf
            ];
            buildInputs = [
              cudaCccl
              cudaCudart
              cudaNvcc
              cudaNvrtc
              cudaCublas
              pkgs.openblas
            ];
            buildPhase = ''
              runHook preBuild
              $CC -O2 -c ${self.packages.${system}.futhark-pieces-cuda}/lib/pieces.c \
                -I${self.packages.${system}.futhark-pieces-cuda}/include \
                -I${cudaCudart}/include -I${cudaCccl}/include \
                -I${cudaNvcc}/include -I${cudaNvrtc.include}/include \
                -o pieces.o
              $CC -std=c11 -Wall -Wextra -Werror -O2 \
                -I${cudaCudart}/include -I${cudaCublas.include}/include \
                -c backend/gemm/cublas_shim.c -o cublas_shim.o
              ghc -O2 -threaded -rtsopts "-with-rtsopts=-N" \
                -ibackend/gemm -ibackend/gpu -ibackend/src \
                backend/gpu/Main.hs backend/gemm/GemmKernels.hs \
                backend/gemm/ProductionPieces.hs backend/gemm/CudaBlasOps.hs \
                pieces.o cublas_shim.o -lopenblas \
                -optl-L${cudaCudart}/lib/stubs \
                -optl-L${cudaCudart}/lib -optl-L${cudaNvrtc.lib}/lib \
                -optl-L${cudaCublas.lib}/lib \
                -optl-lcuda -optl-lcudart -optl-lnvrtc -optl-lcublas \
                -optl-lm -optl-lpthread -o formal-transformer-gemm-cuda
              ghc -O2 -ibackend/gemm -ibackend/src \
                backend/gemm/CudaBlasTest.hs backend/gemm/CudaBlasOps.hs \
                cublas_shim.o -lopenblas \
                -optl-L${cudaCudart}/lib/stubs \
                -optl-L${cudaCudart}/lib -optl-L${cudaCublas.lib}/lib \
                -optl-lcuda -optl-lcudart -optl-lcublas -optl-lm \
                -o cuda-blas-test
              runHook postBuild
            '';
            installPhase = ''
              runHook preInstall
              mkdir -p $out/bin
              cp formal-transformer-gemm-cuda cuda-blas-test $out/bin/
              runHook postInstall
            '';
            postFixup = ''
              removeStubsFromRunpath $out/bin/formal-transformer-gemm-cuda
              removeStubsFromRunpath $out/bin/cuda-blas-test
              for executable in formal-transformer-gemm-cuda cuda-blas-test; do
                case "$(patchelf --print-rpath "$out/bin/$executable")" in
                  *stubs*) echo "CUDA driver stubs leaked into runtime RPATH" >&2; exit 1 ;;
                esac
              done
            '';
            meta.platforms = [ "x86_64-linux" ];
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
              ghc -O2 -threaded -rtsopts "-with-rtsopts=-N" \
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
              ghc -O2 -threaded -rtsopts "-with-rtsopts=-N" \
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
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
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
                nativeBuildInputs = [ pkgs.futhark pkgs.stdenv.cc ];
                src = ./.;
              }
              ''
                cp -r $src source
                chmod -R u+w source
                cd source
                futhark check backend/futhark/kernels.fut
                futhark check backend/futhark/kernels-opencl.fut
                futhark check backend/futhark/tests.fut
                futhark check backend/futhark/bench.fut
                futhark check backend/futhark/pieces.fut
                futhark check backend/futhark/pieces-conformance.fut
                futhark test --backend=c backend/futhark/tests.fut
                futhark test --backend=c backend/futhark/pieces-conformance.fut
                touch $out
              '';
          gpu-host = self.packages.${system}.formal-transformer-gpu;
          cuda-host = self.packages.${system}.formal-transformer-cuda;
          gemm-cuda-host = self.packages.${system}.formal-transformer-gemm-cuda;
          sequential-host = self.packages.${system}.formal-transformer-sequential;
          conformance = self.packages.${system}.conformance;
          futhark-pieces = self.packages.${system}.futhark-pieces;
          futhark-pieces-cuda = self.packages.${system}.futhark-pieces-cuda;
          futhark-pieces-conformance = self.packages.${system}.futhark-pieces-conformance;
          gemm-blas = self.packages.${system}.gemm-blas-test;
          gemm-conformance = self.packages.${system}.gemm-conformance;
        }
      );

      apps = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          cli = "${self.packages.${system}.formal-transformer}/bin/formal-transformer";
          sequential = "${self.packages.${system}.formal-transformer-sequential}/bin/formal-transformer-sequential";
          multicore = "${self.packages.${system}.formal-transformer-multicore}/bin/formal-transformer-multicore";
          gpu = "${self.packages.${system}.formal-transformer-gpu}/bin/formal-transformer-gpu";
          cuda = "${self.packages.${system}.formal-transformer-cuda}/bin/formal-transformer-cuda";
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
                cuda)
                  export MICRO_BATCH="''${MICRO_BATCH:-$TRAIN_BATCH}"
                  export FUT_CACHE="''${FUT_CACHE:-run/futhark-cuda.cache}"
                  trainer=${cuda} ;;
                multicore)
                  export MICRO_BATCH="''${MICRO_BATCH:-$TRAIN_BATCH}"
                  trainer=${multicore} ;;
                sequential)
                  export MICRO_BATCH="''${MICRO_BATCH:-$TRAIN_BATCH}"
                  trainer=${sequential} ;;
                *)
                  echo "wiki-train: unknown WIKI_BACKEND '$backend' (expected cuda, multicore, sequential, or opencl)" >&2
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
              tokenizer="''${WIKI_TOKENIZER:-$HOME/datasets/wikipedia-en/enwiki-8k.bpe}"
              if [ "$size" = bpe10m ] && [ ! -f "$tokenizer" ]; then
                echo "wiki-train: BPE tokenizer not found: $tokenizer" >&2
                echo "  set WIKI_TOKENIZER to the versioned 8192-token .bpe artifact" >&2
                exit 1
              fi
              if [ "$size" = bpe10m ]; then
                export TOKENIZER_FILE="$tokenizer"
              fi
              mkdir -p "$rundir"
              counted="$rundir/article-count"
              if [ ! -f "$counted" ]; then
                echo "wiki-train: counting articles in $data (one-time pass)..."
                wc -l < "$data" > "$counted"
              fi
              total="$(cat "$counted")"
              shards=$(( (total + per - 1) / per ))
              echo "wiki-train: $total articles, $per per shard -> $shards shards, size=$size backend=$backend"
              data_hash="$(sha256sum "$data" | cut -d ' ' -f 1)"
              if [ "$size" = bpe10m ]; then
                tokenizer_hash="$(sha256sum "$tokenizer" | cut -d ' ' -f 1)"
              else
                tokenizer_hash=lossless-byte-v1
              fi
              global_id="wikipedia-global-v1:sha256=$data_hash:articles=$total:shard=$per:batch=$TRAIN_BATCH:size=$size:tokenizer=$tokenizer_hash"
              plan="$rundir/plan-$size-b$TRAIN_BATCH-s$per.tsv"

              # The cosine schedule must know its global total before step 1.
              # Plan one bounded shard at a time using the trainer's exact
              # split/window semantics, then atomically publish the plan.
              if [ ! -f "$plan" ]; then
                segments="$plan.segments.tmp"
                pending="$plan.tmp"
                rm -f "$segments" "$pending"
                cumulative=0
                k=0
                while [ "$k" -lt "$shards" ]; do
                  corpus="$rundir/shard-$k-$size.corpus"
                  first=$(( k * per + 1 ))
                  last=$(( (k + 1) * per ))
                  offset=$(( k * per ))
                  echo "wiki-train: planning shard $k/$shards (articles $first..$last)"
                  if [ ! -f "$corpus" ]; then
                    awk -v a="$first" -v b="$last" 'NR>b{exit} NR>=a' "$data" \
                      | jq -j '.id, "\u0000", .text, "\u0000"' \
                      | if [ "$size" = bpe10m ]; then
                          ${cli} prepare-bpe-stdin "$tokenizer" "$corpus"
                        else
                          ${cli} prepare-stdin "$corpus"
                        fi
                  fi
                  record="$(${cli} plan-segment "$corpus" "$offset" "$TRAIN_BATCH" "$size")"
                  read -r tag planned_offset documents corpus_id train_windows validation_windows steps <<< "$record"
                  if [ "$tag" != segment ] || [ "$planned_offset" != "$offset" ]; then
                    echo "wiki-train: invalid segment plan output: $record" >&2
                    exit 1
                  fi
                  segment_start=$cumulative
                  cumulative=$(( cumulative + steps ))
                  printf 'segment %s %s %s %s %s %s %s %s %s\n' \
                    "$k" "$offset" "$documents" "$corpus_id" "$train_windows" \
                    "$validation_windows" "$steps" "$segment_start" "$cumulative" >> "$segments"
                  if [ "''${WIKI_KEEP_CORPORA:-0}" != 1 ]; then
                    rm -f "$corpus"
                  fi
                  k=$((k + 1))
                done
                printf 'plan 1 %s %s %s %s %s %s %s %s\n' \
                  "$cumulative" "$global_id" "$data_hash" "$total" "$per" \
                  "$TRAIN_BATCH" "$size" "$tokenizer_hash" > "$pending"
                cat "$segments" >> "$pending"
                mv "$pending" "$plan"
                rm -f "$segments"
              fi

              read -r plan_tag plan_version global_total planned_global_id \
                planned_data_hash planned_total planned_per planned_batch \
                planned_size planned_tokenizer_hash < "$plan"
              if [ "$plan_tag" != plan ] || [ "$plan_version" != 1 ] \
                || [ "$planned_global_id" != "$global_id" ] \
                || [ "$planned_data_hash" != "$data_hash" ] \
                || [ "$planned_total" != "$total" ] || [ "$planned_per" != "$per" ] \
                || [ "$planned_batch" != "$TRAIN_BATCH" ] || [ "$planned_size" != "$size" ] \
                || [ "$planned_tokenizer_hash" != "$tokenizer_hash" ]; then
                echo "wiki-train: existing plan does not match this dataset/run configuration" >&2
                exit 1
              fi
              if [ "''${WIKI_PLAN_ONLY:-0}" = 1 ]; then
                echo "wiki-train: plan complete: $plan ($global_total global steps)"
                exit 0
              fi

              checkpoint="''${WIKI_CHECKPOINT:-run/wiki-$size-global.checkpoint}"
              unset TRAIN_INIT
              while read -r tag k offset documents corpus_id train_windows \
                validation_windows steps segment_start segment_end; do
                if [ "$tag" != segment ]; then continue; fi
                marker="$rundir/shard-$k-$size.done"
                if [ -f "$marker" ]; then continue; fi
                corpus="$rundir/shard-$k-$size.corpus"
                first=$(( offset + 1 ))
                last=$(( offset + documents ))
                if [ ! -f "$corpus" ]; then
                  echo "wiki-train: preparing shard $k (articles $first..$last)"
                  awk -v a="$first" -v b="$last" 'NR>b{exit} NR>=a' "$data" \
                    | jq -j '.id, "\u0000", .text, "\u0000"' \
                    | if [ "$size" = bpe10m ]; then
                        ${cli} prepare-bpe-stdin "$tokenizer" "$corpus"
                      else
                        ${cli} prepare-stdin "$corpus"
                      fi
                fi
                echo "wiki-train: shard $k/$shards global steps $segment_start..$segment_end/$global_total"
                "$trainer" train-segment "$corpus" "$checkpoint" "$global_total" \
                  "$segment_start" "$segment_end" "$offset" "$global_id" "$corpus_id" "$size"
                touch "$marker"
                rm -f "$corpus"
              done < "$plan"
              echo "wiki-train: all $shards shards complete - the entire dataset has been consumed"
            '';
          };
          # Zero-argument generation: use an explicit checkpoint or discover
          # the most recently updated checkpoint in the run directory.
          wikiGenerate = pkgs.writeShellApplication {
            name = "wiki-generate";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              if [ -n "''${WIKI_PROMPT:-}" ]; then
                prompt="$WIKI_PROMPT"
              elif [ -t 0 ]; then
                printf 'prompt> ' >&2
                IFS= read -r prompt || {
                  echo "wiki-generate: no prompt entered" >&2
                  exit 1
                }
              else
                echo "wiki-generate: WIKI_PROMPT is not set and stdin is not a terminal" >&2
                echo "  set WIKI_PROMPT=... or run interactively to type a prompt" >&2
                exit 1
              fi
              tokens="''${WIKI_TOKENS:-128}"
              if [ -n "''${WIKI_CHECKPOINT:-}" ]; then
                checkpoint="$WIKI_CHECKPOINT"
              else
                # Newest first, but only checkpoints this host's architecture
                # can interpret: a checkpoint from another architecture (for
                # example another branch's model/layout identity) is skipped
                # with a note instead of aborting generation.
                checkpoint=
                candidates="$(
                  for candidate in run/*.checkpoint run/*-checkpoints/*.checkpoint; do
                    if [ ! -f "$candidate" ]; then continue; fi
                    printf '%s %s\n' "$(stat -L --format=%Y -- "$candidate")" "$candidate"
                  done | sort -rn | cut -d' ' -f2-
                )"
                for candidate in $candidates; do
                  if ${sequential} check-checkpoint "$candidate" >/dev/null 2>&1; then
                    checkpoint="$candidate"
                    break
                  else
                    echo "wiki-generate: skipping incompatible checkpoint $candidate" >&2
                  fi
                done
              fi
              if [ -z "$checkpoint" ]; then
                echo "wiki-generate: no compatible checkpoint found under run/" >&2
                echo "  train first: nix run .#wiki-train" >&2
                exit 1
              fi
              if [ -z "''${WIKI_TOKENIZER:-}" ] && [ -f weights/enwiki-8k.bpe ]; then
                export TOKENIZER_FILE="weights/enwiki-8k.bpe"
              else
                export TOKENIZER_FILE="''${WIKI_TOKENIZER:-$HOME/datasets/wikipedia-en/enwiki-8k.bpe}"
              fi
              echo "wiki-generate: checkpoint=$checkpoint tokens=$tokens" >&2
              echo "wiki-generate: loading model; generated text streams after initialization" >&2
              exec ${sequential} generate "$checkpoint" "$prompt" "$tokens"
            '';
          };
          watchTraining = pkgs.writeShellApplication {
            name = "watch-training";
            runtimeInputs = [
              pkgs.coreutils
              pkgs.openssh
            ];
            text = ''
              host="''${TRAIN_SSH_HOST:-root@154.9.228.248}"
              port="''${TRAIN_SSH_PORT:-21300}"
              remote_log="''${TRAIN_REMOTE_LOG:-/root/formalTransformer-5070ti/run/train-cloud-rtx5070ti.log}"
              lines="''${TRAIN_LOG_LINES:-20}"
              reconnect_delay="''${TRAIN_RECONNECT_DELAY:-2}"

              if [ -z "$port" ]; then
                echo "watch-training: TRAIN_SSH_PORT must be an integer" >&2
                exit 1
              fi
              case "$port" in
                *[!0-9]*) echo "watch-training: TRAIN_SSH_PORT must be an integer" >&2; exit 1 ;;
              esac
              if [ -z "$lines" ]; then
                echo "watch-training: TRAIN_LOG_LINES must be an integer" >&2
                exit 1
              fi
              case "$lines" in
                *[!0-9]*) echo "watch-training: TRAIN_LOG_LINES must be an integer" >&2; exit 1 ;;
              esac

              ssh_options=(
                -q -T
                -o BatchMode=yes
                -o ConnectTimeout=15
                -o ServerAliveInterval=15
                -o ServerAliveCountMax=3
                -p "$port"
              )
              if [ -n "''${TRAIN_SSH_KEY:-}" ]; then
                ssh_options+=(-i "$TRAIN_SSH_KEY")
              fi
              printf -v remote_command 'tail -n %q -F -- %q' "$lines" "$remote_log"

              echo "watch-training: $host:$remote_log (reconnecting automatically)" >&2
              while true; do
                rc=0
                # remote_command is shell-escaped above with printf %q.
                # shellcheck disable=SC2029
                ssh "''${ssh_options[@]}" "$host" "$remote_command" || rc=$?
                echo "watch-training: connection closed (rc=$rc); reconnecting in ''${reconnect_delay}s" >&2
                sleep "$reconnect_delay"
              done
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
        watch-training = {
          type = "app";
          program = "${watchTraining}/bin/watch-training";
          meta.description = "Follow the active cloud training log with automatic SSH reconnection";
        };
        formal-transformer-gpu = {
          type = "app";
          program = "${self.packages.${system}.formal-transformer-gpu}/bin/formal-transformer-gpu";
          meta.description = "Train and generate with the Futhark OpenCL backend";
        };
        formal-transformer-cuda = {
          type = "app";
          program = "${self.packages.${system}.formal-transformer-cuda}/bin/formal-transformer-cuda";
          meta.description = "Train and generate with the Futhark CUDA backend";
        };
        formal-transformer-gemm-cuda = {
          type = "app";
          program = "${self.packages.${system}.formal-transformer-gemm-cuda}/bin/formal-transformer-gemm-cuda";
          meta.description = "Train with explicit FP32, TF32, or BF16 cuBLAS GEMMs";
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
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          agda = pkgs.agda.withPackages (p: [ p.standard-library ]);
          cudaPackages = pkgs.cudaPackages_12_9;
          cudaCudart = cudaPackages.cuda_cudart;
          cudaCccl = cudaPackages.cccl;
          cudaNvcc = cudaPackages.cuda_nvcc;
           cudaNvrtc = cudaPackages.cuda_nvrtc;
           cudaCublas = cudaPackages.libcublas;
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
          cuda = pkgs.mkShell {
            packages = [
              pkgs.futhark
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
