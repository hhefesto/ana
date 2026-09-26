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
      # the GHC deploy/check/haskell.sh drives: the packages listed in
      # deploy/check/ghc-packages.txt (one per line, # comments)
      ghcPackageNames = builtins.filter (l: l != "" && builtins.substring 0 1 l != "#") (
        nixpkgs.lib.splitString "\n" (builtins.readFile ./deploy/check/ghc-packages.txt)
      );
      ghcHarness =
        pkgs: pkgs.haskellPackages.ghcWithPackages (p: map (n: p.${n}) ghcPackageNames);
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
          # transcripts packed whole into one-context windows, the rest of
          # each window the end of a code file (deploy/plan-transcripts.sh)
          bend-windows = bendBinary pkgs "bend-windows" "Windows.bend";
          # the GHC deploy/check/haskell.sh drives: the common Hackage
          # packages, so a module importing only these checks on its own
          ghc-harness = ghcHarness pkgs;
          # `ana`: the Haskell-era app of the same name, on the Bend2 decoder.
          # The same flags, the same environment (WIKI_*, TEMPERATURE, TOP_K,
          # TOP_P, SAMPLE_SEED, SAMPLE_STATS, TOKENIZER_FILE), the same
          # discovery of the newest local weights, the same opt-in pull.
          # Run from the repository root so the tokenizer candidates under
          # weights/ and run/ resolve.
          ana = pkgs.writeShellApplication {
            name = "ana";
            runtimeInputs = [ pkgs.coreutils pkgs.openssh pkgs.rsync ];
            text = ''
              usage() {
                cat >&2 <<'USAGE'
            ana [OPTIONS] [PROMPT]

            Generate text from a trained checkpoint with the Bend2 decoder.  With
            no options it uses the newest local weights and never contacts the
            network.  With no prompt it asks for one.

            Local:
              --checkpoint PATH        generate from this checkpoint (skips discovery)
              --tokenizer PATH         tokenizer artifact (default: discovered by matching
                                       the checkpoint's identity against weights/*.bpe and
                                       run/*.bpe)
              --tokens N               generation budget (default 128)
              --threads N              decoder threads (default: all cores)
              --prompt TEXT            prompt; also accepted as trailing arguments
              --list                   list local checkpoints, newest first, then exit
              -h, --help               this message

            Pulling from a trainer (opt-in; nothing is contacted without --pull/--host):
              --pull                   refresh weights from a trainer first
              --host ADDR              trainer address: IP, hostname, or user@host
                                       (implies --pull)
              --user NAME              ssh user when --host carries none (default root)
              --port N                 ssh port (default 22)
              --key PATH               ssh identity file
              --remote-checkpoint PATH remote checkpoint path (default
                                       /root/formalTransformer/run/hot.checkpoint)

            A pull lands in run/pulled-HOST-PORT-checkpoints/, never on top of an
            existing checkpoint, keeps the trainer's write time, and records its
            destination in run/last-checkpoint for reference.  A later no-argument
            run selects the newest local weights, so a fresh pull wins by being
            newest, not by being pointed at.

            Newest means the latest write time among the checkpoints under run/
            whose first bytes are FTC2 or BTC1 (rsync and cp -p keep the write
            time; a checkpoint copied without it ranks by the copy's time).  Ties
            break toward the higher step in the file name.

            Environment fallbacks (arguments win): WIKI_PROMPT, WIKI_TOKENS,
            WIKI_CHECKPOINT, WIKI_TOKENIZER, and for --pull: WIKI_REMOTE,
            WIKI_REMOTE_PORT, WIKI_REMOTE_KEY, WIKI_REMOTE_CHECKPOINT, or the same
            assignments in run/remote-box.env.  TEMPERATURE, TOP_P, TOP_K and
            SAMPLE_SEED shape decoding (defaults: temperature 0.8, nucleus top-p
            0.95, top-k off, seed 0).
            USAGE
              }

              pull=0
              list=0
              host=
              user=
              port=
              key=
              remote_checkpoint=
              checkpoint=
              tokenizer=
              tokens=
              threads=
              prompt=
              prompt_set=0

              need_value() {
                if [ "$1" -lt 2 ]; then
                  echo "ana: $2 needs a value" >&2
                  exit 1
                fi
              }

              while [ $# -gt 0 ]; do
                case "$1" in
                  --pull) pull=1 ;;
                  --list) list=1 ;;
                  --host) need_value $# "$1"; host="$2"; pull=1; shift ;;
                  --user) need_value $# "$1"; user="$2"; shift ;;
                  --port) need_value $# "$1"; port="$2"; shift ;;
                  --key) need_value $# "$1"; key="$2"; shift ;;
                  --remote-checkpoint) need_value $# "$1"; remote_checkpoint="$2"; shift ;;
                  --checkpoint) need_value $# "$1"; checkpoint="$2"; shift ;;
                  --tokenizer) need_value $# "$1"; tokenizer="$2"; shift ;;
                  --tokens) need_value $# "$1"; tokens="$2"; shift ;;
                  --threads) need_value $# "$1"; threads="$2"; shift ;;
                  --prompt) need_value $# "$1"; prompt="$2"; prompt_set=1; shift ;;
                  -h|--help) usage; exit 0 ;;
                  --) shift
                      while [ $# -gt 0 ]; do
                        if [ "$prompt_set" = 1 ]; then prompt="$prompt $1"; else prompt="$1"; prompt_set=1; fi
                        shift
                      done
                      break ;;
                  -*) echo "ana: unknown option $1" >&2; usage; exit 1 ;;
                  *)  if [ "$prompt_set" = 1 ]; then prompt="$prompt $1"; else prompt="$1"; prompt_set=1; fi ;;
                esac
                shift
              done

              if [ "$prompt_set" = 0 ] && [ -n "''${WIKI_PROMPT:-}" ]; then
                prompt="$WIKI_PROMPT"
                prompt_set=1
              fi
              if [ -z "$tokens" ]; then tokens="''${WIKI_TOKENS:-128}"; fi
              if [ -z "$threads" ]; then threads="$(nproc)"; fi
              if [ -z "$checkpoint" ]; then checkpoint="''${WIKI_CHECKPOINT:-}"; fi
              if [ -z "$tokenizer" ]; then tokenizer="''${WIKI_TOKENIZER:-}"; fi
              case "$tokens" in
                ""|*[!0-9]*)
                  echo "ana: --tokens must be a non-negative integer (got '$tokens')" >&2
                  exit 1 ;;
              esac

              # The pull is opt-in.  Without --pull/--host this app makes no
              # network call at all, so a destroyed training box costs nothing.
              if [ "$pull" = 1 ]; then
                if [ -z "$host" ]; then host="''${WIKI_REMOTE:-}"; fi
                if [ -z "$host" ] && [ -f run/remote-box.env ]; then
                  # shellcheck disable=SC1091
                  . run/remote-box.env
                  host="''${WIKI_REMOTE:-}"
                  if [ -z "$port" ]; then port="''${WIKI_REMOTE_PORT:-}"; fi
                  if [ -z "$remote_checkpoint" ]; then remote_checkpoint="''${WIKI_REMOTE_CHECKPOINT:-}"; fi
                fi
                if [ -z "$host" ]; then
                  echo "ana: --pull needs a trainer to pull from" >&2
                  echo "  pass --host user@host (with --port/--key as needed)," >&2
                  echo "  or set WIKI_REMOTE, or write run/remote-box.env" >&2
                  exit 1
                fi
                if [ -z "$port" ]; then port="''${WIKI_REMOTE_PORT:-22}"; fi
                if [ -z "$key" ]; then key="''${WIKI_REMOTE_KEY:-}"; fi
                if [ -z "$remote_checkpoint" ]; then
                  remote_checkpoint="''${WIKI_REMOTE_CHECKPOINT:-/root/formalTransformer/run/hot.checkpoint}"
                fi
                case "$port" in
                  ""|*[!0-9]*)
                    echo "ana: --port must be an integer (got '$port')" >&2
                    exit 1 ;;
                esac
                case "$host" in
                  *@*) ;;
                  *) host="''${user:-root}@$host" ;;
                esac
                if [ -n "$key" ] && [ ! -f "$key" ]; then
                  echo "ana: ssh key not found: $key" >&2
                  exit 1
                fi
                # One directory per trainer, and never the shared run/ root: a
                # pull can then not overwrite weights from a different box (or
                # from a finished run) with whatever this box happens to hold.
                slug="$(printf '%s-%s' "$host" "$port" | tr -c 'A-Za-z0-9._-' '-')"
                dest_dir="run/pulled-$slug-checkpoints"
                mkdir -p "$dest_dir"
                ssh_command="ssh -p $port -o ConnectTimeout=10 -o BatchMode=yes"
                if [ -n "$key" ]; then
                  printf -v key_quoted '%q' "$key"
                  ssh_command="$ssh_command -i $key_quoted"
                fi
                echo "ana: pulling $host:$remote_checkpoint -> $dest_dir/" >&2
                # rsync writes a temp file and renames, so a torn transfer never
                # replaces good local weights; -t keeps the trainer's write time,
                # which is what discovery ranks by.
                if rsync -zt -e "$ssh_command" "$host:$remote_checkpoint" "$dest_dir/"; then
                  pulled="$dest_dir/$(basename "$remote_checkpoint")"
                  echo "ana: pull complete: $pulled" >&2
                  printf '%s\n' "$pulled" > run/last-checkpoint
                else
                  echo "ana: pull failed (box offline?); using local checkpoints" >&2
                fi
              fi

              # Every local checkpoint, ranked: write time, then the step in
              # the file name.  A candidate is readable when its magic is FTC2
              # (the compact format both trainers save) or BTC1 (the tree
              # trainer's); anything else is listed and never chosen.
              ranked="$(
                for candidate in run/*.checkpoint run/*/*.checkpoint; do
                  if [ ! -f "$candidate" ]; then continue; fi
                  magic="$(head -c 4 -- "$candidate" | tr -c 'A-Z0-9' '?')"
                  case "$magic" in FTC2|BTC1) status=$magic ;; *) status=unreadable ;; esac
                  mtime="$(stat -L --format=%Y -- "$candidate")"
                  step="$(printf '%s' "$candidate" | sed -n 's|.*step-\{0,1\}\([0-9]\{1,\}\).*|\1|p')"
                  printf '%s %s %s %s\n' "$mtime" "''${step:-0}" "$status" "$candidate"
                done | sort -k1,1rn -k2,2rn
              )"
              newest="$(printf '%s\n' "$ranked" | awk '$3 != "unreadable" { print $4; exit }')"

              if [ "$list" = 1 ]; then
                if [ -z "$ranked" ]; then
                  echo "ana: no checkpoints under run/" >&2
                  exit 1
                fi
                printf '%s\n' "$ranked" | while IFS=' ' read -r mtime _ status candidate; do
                  mark=" "
                  if [ "$candidate" = "$newest" ]; then mark="*"; fi
                  printf '%s %-10s %12s bytes  %s  %s\n' "$mark" "$status" \
                    "$(stat -L --format=%s -- "$candidate")" \
                    "$(date -d "@$mtime" '+%Y-%m-%d %H:%M')" "$candidate"
                done
                exit 0
              fi

              if [ -z "$checkpoint" ]; then
                if [ -z "$newest" ]; then
                  echo "ana: no readable checkpoint under run/ (pass --checkpoint, or --pull from a trainer)" >&2
                  exit 1
                fi
                checkpoint="$newest"
              elif [ ! -f "$checkpoint" ]; then
                echo "ana: checkpoint not found: $checkpoint" >&2
                exit 1
              fi
              if [ "$prompt_set" = 0 ]; then
                if [ -t 0 ]; then
                  printf 'ana (%s)\nprompt> ' "$checkpoint" >&2
                fi
                IFS= read -r prompt || true
                if [ -z "$prompt" ]; then
                  echo "ana: no prompt" >&2
                  exit 1
                fi
              fi
              echo "ana: $checkpoint" >&2
              if [ -n "$tokenizer" ]; then export TOKENIZER_FILE="$tokenizer"; fi
              CKPT="$checkpoint" PROMPT="$prompt" TOKENS="$tokens" \
                exec ${self.packages.${system}.bend-generate}/bin/bend-generate --threads "$threads"
            '';
          };
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
            printf '%s\n' "ok haskell 2" "ok agda 1" "ok lean 2" "ok bend 2" "ok nix 1" "ok lagda 1" | diff - units.out
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
        default = self.apps.${system}.ana;
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
