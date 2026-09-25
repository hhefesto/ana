{
  description = "ana: an autoregressive transformer specified, trained and evaluated in Bend, and the corpus tools that feed it";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  # Bend 2: the ft-kernels fork of bendlang/bend (github:hhefesto/bend2),
  # which adds the bulk GPU ops the dense trainer runs on (Array.gemm/mm on
  # cuBLAS, Array.einsum as generated CUDA kernels; each op's meaning is its
  # base.bend definition), F32 file I/O and IO.time.  Bend is a flake; the
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
      # Every .bend source, nothing else.
      bendSrc = sourceOf [ (nixpkgs.lib.fileset.fileFilter (f: f.hasExt "bend") ./bend) ];
      # the pinned bend command (clang on its PATH, telemetry off)
      bendFor = pkgs: bend2.packages.${pkgs.stdenv.hostPlatform.system}.default;
      # A Bend2 program compiled to a native binary (C via clang).
      ghcHarness =
        pkgs:
        pkgs.haskellPackages.ghcWithPackages (
          p: with p; [
            aeson array async attoparsec bytestring containers data-default deepseq directory
            exceptions filepath free hashable lens megaparsec mtl parsec primitive process
            QuickCheck random safe scientific split stm text time transformers
            unordered-containers vector
          ]
        );
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
          # the transcript corpus (docs/TRANSCRIPT-FORMAT.md): declarations
          # cut out of source files, then, after deploy/check/<lang>.sh has
          # run the real checkers on them, rendered as transcripts
          bend-units = bendBinary pkgs "bend-units" "Units.bend";
          bend-transcript = bendBinary pkgs "bend-transcript" "Transcript.bend";
          # the GHC deploy/check/haskell.sh drives: the common Hackage
          # packages, so a module importing only these checks on its own
          ghc-harness = ghcHarness pkgs;
          # `ana` on the Bend2 port: the same flags, the same environment
          # (TEMPERATURE, TOP_K, TOP_P, SAMPLE_SEED, SAMPLE_STATS,
          # TOKENIZER_FILE), run from the repository root so the tokenizer
          # candidates under weights/ and run/ resolve.
          ana-bend = pkgs.writeShellApplication {
            name = "ana-bend";
            runtimeInputs = [ pkgs.coreutils ];
            text = ''
              usage() {
                cat <<'USAGE'
            Usage: ana-bend [--checkpoint PATH] [--tokens N] [--threads N] [--prompt TEXT | TEXT...]

            Generate from an FTC2 checkpoint with the Bend2 decoder.  Without
            --checkpoint, the path recorded in run/last-checkpoint is used.
            USAGE
              }
              checkpoint=""
              tokens="''${WIKI_TOKENS:-128}"
              threads="$(nproc)"
              prompt="''${WIKI_PROMPT:-The}"
              rest=()
              while [ $# -gt 0 ]; do
                case "$1" in
                  --checkpoint) checkpoint="$2"; shift ;;
                  --tokens) tokens="$2"; shift ;;
                  --threads) threads="$2"; shift ;;
                  --prompt) prompt="$2"; shift ;;
                  -h|--help) usage; exit 0 ;;
                  *) rest+=("$1") ;;
                esac
                shift
              done
              if [ ''${#rest[@]} -gt 0 ]; then prompt="''${rest[*]}"; fi
              if [ -z "$checkpoint" ]; then
                if [ -f run/last-checkpoint ]; then checkpoint="$(cat run/last-checkpoint)"
                else echo "ana-bend: pass --checkpoint PATH (no run/last-checkpoint here)" >&2; exit 1; fi
              fi
              CKPT="$checkpoint" PROMPT="$prompt" TOKENS="$tokens" \
                exec ${self.packages.${system}.bend-generate}/bin/bend-generate --threads "$threads"
            '';
          };
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
          # stated over type-checks and is proven
          bend-spec = pkgs.runCommand "bend-spec" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend src/Everything.bend | tee result
            grep -qx "All terms check." result
            touch $out
          '';
          # the self-contained unit tests, against known answers
          bend-tests = pkgs.runCommand "bend-tests" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            cd src/tests
            bend sha.bend > sha.out
            printf '%s\n' e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 \
              ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad \
              248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1 | diff - sha.out
            bend num.bend > num.out
            printf '%s\n' 236d88fe5618cf00 9bde02468acf1357 0000000048d159e2 0000000000000001 ffffffffffffffff 1.5 | diff - num.out
            # the exact store size (Nat) equals Lay.of's U32 total wherever
            # U32 cannot wrap
            bend layout.bend > layout.out
            if grep -q MISMATCH layout.out; then cat layout.out; exit 1; fi
            test "$(grep -c '^ok ' layout.out)" = 52
            # the unit extractor: unit counts per language, and every unit
            # rebuilds its file byte for byte
            bend units.bend > units.out
            printf '%s\n' "ok haskell 2" "ok agda 1" "ok lean 2" "ok bend 2" "ok nix 1" | diff - units.out
            touch $out
          '';
          # the training stack: the hand-written pullbacks agree with central
          # finite differences (f32: 5% relative plus 3e-5 absolute, the
          # difference quotient's resolution at eps 0.01), the training
          # forward's loss is the decode path's, and a short byte-level run
          # lowers the validation loss
          bend-train = pkgs.runCommand "bend-train" { nativeBuildInputs = [ (bendFor pkgs) pkgs.gawk ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            (cd src/tests && bend train.bend) | tee grad.out
            awk '/^train loss/ { t = $3 } /^decode loss/ { d = $3 }
                 / analytic=/ { split($2, a, "="); split($3, n, "="); x = a[2]; y = n[2]; e = x - y; if (e < 0) e = -e;
                   m = (x < 0 ? -x : x); if ((y < 0 ? -y : y) > m) m = (y < 0 ? -y : y);
                   k++; if (e > 0.05 * m + 3e-5) { print "gradcheck FAIL: " $0; bad = 1 } }
                 END { e = t - d; if (e < 0) e = -e; if (e > 1e-5) { print "train/decode loss differ"; bad = 1 }
                       if (k != 16) { print "expected 16 probes, got " k; bad = 1 } exit bad }' grad.out
            cat src/*.bend src/Spec/*.bend > corpus.txt
            CORPUS=corpus.txt PRESET=tiny-v3 TRAIN_STEPS=30 TRAIN_BATCH=8 TRAIN_LR=3e-3 TRAIN_WARMUP=5 \
              OUT=tiny.btc ${self.packages.${system}.bend-train}/bin/bend-train --threads 4 | tee run.out
            awk '/validation loss/ { v[++n] = $5 } END { if (n < 2 || !(v[n] < v[1] - 0.3)) { print "loss did not fall"; exit 1 } }' run.out
            head -1 tiny.btc | grep -qx BTC1
            touch $out
          '';
          # the dense program against the tree trainer: same weights and
          # windows, the loss and every gradient within 1e-5 relative
          # (reverse mode derived from the ops, chunked GLA, both gate kinds);
          # then a short dense run lowers the validation loss
          bend-dense = pkgs.runCommand "bend-dense" { nativeBuildInputs = [ (bendFor pkgs) pkgs.gawk ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            (cd src && bend tests/dense.bend -o $TMPDIR/dense) && $TMPDIR/dense --threads 4 | tee dense.out
            awk '/gradient max/ { r = $(NF); gsub(/[()]/, "", r); k++; if (r + 0 > 1e-5) { print "gradient differs: " $0; bad = 1 } }
                 END { if (k != 3) { print "expected 3 gradient checks, got " k; bad = 1 } exit bad }' dense.out
            cat src/*.bend src/Spec/*.bend > corpus.txt
            CORPUS=corpus.txt PRESET=tiny-v3 TRAIN_STEPS=30 TRAIN_BATCH=8 TRAIN_LR=3e-3 TRAIN_WARMUP=5 \
              OUT=tiny.btc ${self.packages.${system}.bend-train-dense}/bin/bend-train-dense --threads 4 | tee run.out
            awk '/validation_loss=/ { for (i = 1; i <= NF; i++) if ($i ~ /^validation_loss=/) { split($i, a, "="); v[++n] = a[2] } }
                 END { if (n < 2 || !(v[n] < v[1] - 0.3)) { print "loss did not fall"; exit 1 } }' run.out
            head -1 tiny.btc | grep -qx BTC1
            # the trajectory itself, byte for byte (bend/tests/dense-identity.sh
            # writes the goldens): six steps of small4-v3, batch 8 in micro-
            # batches of 4, AdamW and Muon, on a corpus nothing edits. A layout
            # change must leave these parameters unchanged.
            for opt in adamw muon; do
              CORPUS=${./docs/haskell-era/RUN-2026-07-25-WIKI-FULL.md} PRESET=small4-v3 TRAIN_STEPS=6 TRAIN_BATCH=8 \
                TRAIN_MICRO=4 TRAIN_LR=3e-3 TRAIN_WARMUP=2 TRAIN_OPT=$opt EVAL_EVERY=3 OUT=$opt.btc \
                ${self.packages.${system}.bend-train-dense}/bin/bend-train-dense --gpu off --threads 4 > $opt.log
            done
            sha256sum adamw.btc muon.btc | diff - ${./bend/tests/dense-identity.sha256}
            touch $out
          '';
        }
      );

      apps = forAllSystems (system: {
        ana-bend = {
          type = "app";
          program = "${self.packages.${system}.ana-bend}/bin/ana-bend";
          meta.description = "Generate with the Bend2 decoder";
        };
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
        default = self.apps.${system}.ana-bend;
      });

      devShells = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          agda = pkgs.agda.withPackages (p: [ p.standard-library ]);
          cudaPackages = pkgs.cudaPackages_12_8;
          cudaCudart = cudaPackages.cuda_cudart;
          cudaCccl = cudaPackages.cccl;
          cudaNvcc = cudaPackages.cuda_nvcc;
          cudaNvrtc = cudaPackages.cuda_nvrtc;
          cudaCublas = cudaPackages.libcublas;
        in
        {
          # Bend, plus the toolchains the transcript harness drives
          # (deploy/check/*.sh): the compilers and checkers of the languages
          # the corpus teaches.  Lean comes through elan, because a Lean
          # project pins its own toolchain (mathlib's lean-toolchain).
          default = pkgs.mkShell {
            packages = [
              (bendFor pkgs)
              pkgs.jq
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
