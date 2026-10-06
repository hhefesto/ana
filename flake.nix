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
          bend-agent-laws = bendBinary pkgs "bend-agent-laws" "Agent/Laws.bend";
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
            text = ''
              if [ "$#" -eq 0 ]; then
                echo "usage: deploy TOOL [ARGS...]   (TOOL: extract, plan-corpus, code-evals, mix, push, transcripts, check, units, clean, transcript, windows, plan-windows, pack, prepare, plan-segment, legere, corpus-v2)" >&2
                exit 2
              fi
              tool=$1
              shift
              exec "bend-$tool" "$@"
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
          # stated over type-checks and is proven
          bend-spec = pkgs.runCommand "bend-spec" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            bend src/Everything.bend | tee result
            grep -qx "ALL PROOFS CHECK" result
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
            # rebuilds its file byte for byte; the Term turn's indentation
            bend units.bend > units.out
            printf '%s\n' "ok term bend" "ok term haskell-instance" "ok term haskell" "ok term lean" "ok haskell 2" "ok agda 1" "ok lean 2" "ok bend 2" "ok nix 1" "ok lagda 1" | diff - units.out
            # the transcript renderer's format 2 (docs/CORPUS-V2.md): each
            # shape's turns, the direct shape byte for byte, every Term the
            # original, a unit's presentations distinct, Nix never direct
            bend transcript.bend > transcript.out
            printf '%s\n' "ok direct" "ok turns 0" "ok turns 1" "ok turns 2" "ok turns 3" "ok turns 4" "ok turns 5" "ok terms" "ok copies repo:x/A.hs#twice@1" "ok copies repo:x/a.nix#file@1" | diff - transcript.out
            # E5 reads ana's output as a transcript less ana's closing
            # newline: a passing last echo is solved (it never was before)
            bend agent-eval.bend > agent-eval.out
            printf '%s\n' "ok a passing last echo is solved" "ok read with the closing newline it is not (the bug)" "ok a failing echo then a stopped call is not" "ok one call answered" "ok one answered, the stopped one not" | diff - agent-eval.out
            # the corpus tools' libraries: processes and text (Sys), JSON
            # strings as jq decodes and writes them (Json), POSIX cksum
            bend sys.bend > sys.out
            printf 'ok %s\n' run merge timeout cwd env stdin clean parent root chomp split replace nul slurp exists | diff - sys.out
            bend json.bend > json.out
            printf 'ok %s\n' escapes space trailing bad-escape unpaired-high lone-low raw-tab unclosed quote doc doc-order doc-extra nonul line | diff - json.out
            bend cksum.bend > cksum.out
            if grep -v '^ok ' cksum.out; then exit 1; fi
            test "$(grep -c '^ok ' cksum.out)" = 5
            # the drivers' own rules: the mix's rounding and ids, the
            # extractor's UTF-8, license and holdout verdicts
            bend mix.bend > mix.out
            if grep -v '^ok ' mix.out; then exit 1; fi
            test "$(grep -c '^ok ' mix.out)" = 12
            bend extract.bend > extract.out
            if grep -v '^ok ' extract.out; then exit 1; fi
            test "$(grep -c '^ok ' extract.out)" = 32
            # the cleaner's MinHash: one word apart agrees in 90+ of 128
            bend clean.bend > clean.out
            printf 'ok %s\n' near far self grams short key | diff - clean.out
            # legere: forward-backward and Viterbi equal the enumeration
            # (Legere/Spec.bend) in Nat and Bool, within 1e-4 in logp and
            # maxp; the cues' gold and mask; Σ_b P(b | h) = 1; sections give
            # the lines back
            bend legere.bend > legere.out
            printf 'ok %s\n' score bool marginals boundaries logp posteriors bposteriors viterbi cues ngram roundtrip | diff - legere.out
            # ana's episodes (Agent/Spec.bend): each shape's roles, reading's
            # round trip, every call answered, weight 0 exactly on attempts and
            # echoes, the loop's unfold, and a code32k window's weights
            # (compiled: the interpreter's stack is too small for the
            # tokenizer's parse)
            mkdir -p weights && cp ${./weights/code32k.bpe} weights/code32k.bpe
            bend agent.bend -o agent-test && ./agent-test > agent.out
            head -8 agent.out > agent8.out
            printf 'ok %s\n' direct repair term-to-type verify trap "weights direct" "weights repair" unfold | diff - agent8.out
            grep -q '^ok window' agent.out
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
                 END { if (k != 4) { print "expected 4 gradient checks (3 plain, 1 masked), got " k; bad = 1 } exit bad }' dense.out
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
          # the dense decode step (bend/Dense/Decode.bend, ana's engine)
          # against Model.bend's decode, its meaning: every position's logits
          # within 1e-5 relative, before and after the softmax ring wraps,
          # with and without v3's arms; a reset gives them again bit for bit
          bend-decode-dense = pkgs.runCommand "bend-decode-dense" { nativeBuildInputs = [ (bendFor pkgs) pkgs.gawk ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            (cd src && bend tests/decode-dense.bend -o $TMPDIR/dd) && $TMPDIR/dd --threads 4 | tee dd.out
            awk '/logits, positions/ { r = $(NF); gsub(/[()]/, "", r); k++; if (r + 0 > 1e-5) { print "logits differ: " $0; bad = 1 } }
                 END { if (k != 4) { print "expected 4 logit checks, got " k; bad = 1 } exit bad }' dd.out
            test "$(grep -c '^ok ' dd.out)" = 5 && ! grep -q '^FAIL' dd.out
            touch $out
          '';
          # CPU bulk ops refine the Base definitions without changing F32
          # bits. Small cases compare to JS; seeded and adversarial cases
          # cover SIMD tails, threaded reductions, aliases and wrapping.
          bend-bulk-cpu = pkgs.runCommand "bend-bulk-cpu" { nativeBuildInputs = [ (bendFor pkgs) ]; } ''
            export HOME=$TMPDIR
            cp -r ${bendSrc}/bend src
            chmod -R u+w src
            for name in GemmConf EinsumConf; do
              bend src/gpu/$name.bend > $name.js
              bend src/gpu/$name.bend -o $TMPDIR/$name
              BEND_FT=loop $TMPDIR/$name --gpu off --threads 1 > $name.loop
              cmp $name.js $name.loop
              $TMPDIR/$name --gpu off --threads 8 > $name.fast
              cmp $name.loop $name.fast
            done
            bend src/tests/bulk-cpu.bend -o $TMPDIR/bulk
            BEND_FT=loop $TMPDIR/bulk --gpu off --threads 1 > reference
            BEND_FT=c $TMPDIR/bulk --gpu off --threads 8 > actual
            cmp reference actual
            for threads in 1 8 16; do
              $TMPDIR/bulk --gpu off --threads $threads > actual
              cmp reference actual
            done
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
