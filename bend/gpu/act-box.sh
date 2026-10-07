#!/usr/bin/env bash
# act-box.sh (2026-10-07): run 3's turn-based work on the rented box, beside
# the trainer (docs/AGENT.md). ana's own episodes (tools/corpus-v2/agent-act.sh)
# and the box evals need ana's CPU decoder, the checkers (ghc with its
# packages, Agda with its libraries, Lean with Mathlib, nix-instantiate, Bend)
# and the units' records and source trees. Everything comes through Nix, never
# a container:
#
#   act-box.sh setup HOST PORT        nix on the box (nixpkgs' static nix, one
#                                     binary, as root), the tools by `nix copy
#                                     -s` (the box substitutes from
#                                     cache.nixos.org: of the 2,041 paths, 23
#                                     (70 MB) come from here), the tracked
#                                     files, the act set, its units' and the
#                                     held-out units' records and source trees
#                                     (about 3.5 GB), Mathlib's source, then on
#                                     the box elan's toolchain and `lake exe
#                                     cache get`
#   act-box.sh ckpt HOST PORT CKPT    a checkpoint to the box's workspace
#   act-box.sh check HOST PORT CKPT   agent-act on 1 prompt of each language
#                                     and shape, 2 seeds: every language
#                                     answers, the render law holds
#   act-box.sh act HOST PORT CKPT DIR agent-act on the whole act set, detached
#                                     on the box (DIR.log beside DIR)
#   act-box.sh pull HOST PORT DIR     DIR's accepted episodes, log and report here
#
# The workspace is this repository's own path (WS) on the box, and HOME is its
# HOME: the Agda library file, the checkers' caches, elan's toolchains and the
# scripts name them. The trainer's ~/formalTransformer (fp-stage.sh) is not
# touched, and nothing here stops the trainer: a failure only delays a round.
# PROCS x THREADS (default: (nproc - 4) / 2 processes of 2 threads) leave the
# trainer 4 cores; a Lean check takes about 3 GB.
set -euo pipefail
cmd=${1:?usage: act-box.sh setup|ckpt|check|act|pull HOST PORT ...}
host=${2:?usage: act-box.sh $cmd HOST PORT ...}
port=${3:?usage: act-box.sh $cmd HOST PORT ...}
cd /home/hhefesto/src/formalTransformer
ws=$PWD bh=$HOME
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] act-box: $*"; }
r() { ssh -p "$port" -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new "$host" "$@"; }
rs() { rsync -e "ssh -p $port -o ServerAliveInterval=30 -o StrictHostKeyChecking=accept-new" "$@"; }
# a command in the box's workspace, as here: its HOME, the box's nix on PATH
rw() { r "export HOME=$bh PATH=/usr/local/bin:\$PATH; cd $ws && $*"; }
links="run/v2/gcroot-deploy-agent run/gcroot-bend-generate-agent run/agent/gcroot-bend-episode"
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT

# the box's nix: the static binary under its tools' names, a root store with
# no build users (substitution and copies only, nothing is built there)
box_nix() {
  local n; n=$(readlink -f run/v3/gcroot-nix-static/bin/nix)
  [ -x "$n" ] || { log "no static nix: nix build --inputs-from . nixpkgs#pkgsStatic.nix -o run/v3/gcroot-nix-static"; exit 1; }
  if r 'test -x /usr/local/bin/nix'; then log "nix: on the box"; else
    rs -a "$n" "$host:/usr/local/bin/nix"
    r 'set -e; cd /usr/local/bin; for t in nix-daemon nix-store nix-instantiate nix-build nix-env nix-copy-closure; do ln -sfn nix $t; done
       mkdir -p /etc/nix; printf "experimental-features = nix-command flakes\nbuild-users-group =\nsandbox = false\nmax-jobs = auto\n" > /etc/nix/nix.conf
       nix --version'
  fi
}

# the units a list of NUL-pair files' ids name (UNIT/SHAPE ids lose the shape)
units_of() { cat "$@" | awk -v RS='\0' 'NR % 2 == 1 { sub(/\/[^\/]*$/, ""); print }'; }

# the source trees units need: repo:NAME/.. -> run/code-sources/repos/NAME,
# hackage:PKG/.. -> run/check-cache/hs/src/PKG-VERSION, own: and curated: (all
# of them), and the Agda library file's checkouts
trees() {
  awk '/^repo:/ { sub(/^repo:/, ""); sub(/\/.*/, ""); print "run/code-sources/repos/" $0 }' "$1"
  grep -o "$ws/run/code-sources/repos/[^/]*" run/check-cache/agda/libraries | sed "s|^$ws/||"
  printf '%s\n' run/code-sources/own run/code-sources/curated run/check-cache/agda run/check-cache/hs/hi run/check-cache/hs/info \
    run/check-cache/hs/cabal-dirs
  awk '/^hackage:/ { sub(/^hackage:/, ""); sub(/\/.*/, ""); print }' "$1" | sort -u | while read -r p; do ls -d run/check-cache/hs/src/"$p"-[0-9]* 2>/dev/null || true; done
}

setup() {
  local t0 paths elan
  t0=$(date +%s)
  box_nix
  paths=$(readlink -f $links)
  log "nix copy: $(echo "$paths" | wc -l) tools, their closures substituted on the box"
  NIX_SSHOPTS="-p $port -o ServerAliveInterval=30" nix copy -s --no-check-sigs \
    --to "ssh-ng://$host?remote-program=/usr/local/bin/nix-daemon" $paths
  r "mkdir -p $ws/run/v2/act $ws/run/v2/results $ws/run/v3 $ws/run/agent $ws/run/harness $bh"
  for l in $links; do r "ln -sfn $(readlink -f "$l") $ws/$l"; done
  rw "\$(readlink -f run/v2/gcroot-deploy-agent)/bin/deploy 2>&1 | head -1"
  log "tracked files"
  git ls-files -z | rs -a --from0 --files-from=- ./ "$host:$ws/"
  log "act set, records (the act units' train records, every held-out record)"
  units_of run/v2/act/prompts.nul run/v2/evalset/prompts*.nul | sort -u > "$S/units.txt"
  awk -v RS='\0' 'NR % 2 == 1' run/v2/results/*.holdout.nul >> "$S/units.txt"
  sort -u -o "$S/units.txt" "$S/units.txt"
  for l in haskell agda lean nix bend; do
    awk -v RS='\0' -v ORS='\0' 'FNR == NR { u[$0] = 1; next } FNR % 2 == 1 { keep = ($0 in u) } keep' \
      RS='\n' "$S/units.txt" RS='\0' "run/v2/results/$l.train.nul" > "$S/$l.train.nul"
  done
  rs -a "$S"/*.train.nul run/v2/results/*.holdout.nul "$host:$ws/run/v2/results/"
  rs -a run/v2/act/prompts.nul "$host:$ws/run/v2/act/"
  rs -aR run/v2/evalset run/v2/transcripts/*/transcripts.holdout.nul run/v2/transcripts/*/results.holdout.nul "$host:$ws/"
  log "source trees"
  trees "$S/units.txt" | sort -u > "$S/trees.txt"
  log "$(wc -l < "$S/trees.txt") trees, $(du -shc $(cat "$S/trees.txt") | tail -1 | cut -f1)"
  # -r: --files-from turns off -a's recursion
  rs -ar --info=stats1 --files-from="$S/trees.txt" ./ "$host:$ws/"
  log "Mathlib: the checkout here, its build from Mathlib's cache there"
  rs -a --exclude=.lake run/harness/mathlib4 "$host:$ws/run/harness/"
  elan=$(nix path-info -r "$(readlink -f run/v2/gcroot-deploy-agent)" | grep -E -- '-elan-[0-9]')
  rw "cd run/harness/mathlib4 && PATH=$elan/bin:\$PATH elan toolchain install \$(cat lean-toolchain) && PATH=$elan/bin:\$PATH lake exe cache get" \
    > "$S/lake.log" 2>&1 || { tail -20 "$S/lake.log"; log "lake exe cache get failed"; exit 1; }
  tail -3 "$S/lake.log"
  log "setup done in $(( ($(date +%s) - t0) / 60 )) min"
}

ckpt() {
  local c=${1:?usage: act-box.sh ckpt HOST PORT CKPT}
  r "mkdir -p $ws/$(dirname "$c")"
  rs -a --partial --info=progress2 "$c" "$host:$ws/$c"
  [ "$(r "sha256sum $ws/$c" | cut -d' ' -f1)" = "$(sha256sum "$c" | cut -d' ' -f1)" ] || { log "$c: sha256 differs on the box"; exit 1; }
  log "$c on the box, sha256 matches"
}

procs() { echo "\$(( (\$(nproc) - 4) / 2 ))"; }

act() {
  local c=${1:?} d=${2:?}
  rw "mkdir -p \$(dirname $d) && PROCS=\${PROCS:-$(procs)} THREADS=\${THREADS:-2} nohup setsid bash -c \
    'tools/corpus-v2/agent-act.sh $c $d > $d.log 2>&1' > /dev/null 2>&1 < /dev/null & echo started"
  log "act: $c into $d on the box (log $d.log)"
}

check() {
  local c=${1:?usage: act-box.sh check HOST PORT CKPT} d=run/v3/act/check
  rw "rm -rf $d $d.log; PROCS=\$(( \$(nproc) / 2 )) THREADS=2 tools/corpus-v2/agent-act.sh $c $d 1 > $d.log 2>&1" || true
  rw "cat $d/report.txt; tail -3 $d.log" | tee "$S/check.txt"
  # the render law on every episode, and all 9 languages and shapes answered
  # (Nix has no direct prompt)
  grep -Eq '^render law ([0-9]+)/\1$' "$S/check.txt" || { log "check: the render law did not hold on every episode"; exit 1; }
  local n; n=$(grep -cE 'solved within 1:[0-9]+/[1-9]' "$S/check.txt" || true)
  [ "$n" = 9 ] || { log "check: $n of the 9 languages and shapes answered"; exit 1; }
  log "check: passed"
}

pull() {
  local d=${1:?usage: act-box.sh pull HOST PORT DIR}
  mkdir -p "$d"
  rs -a --partial "$host:$ws/$d/accepted" "$host:$ws/$d/agent.nul" "$host:$ws/$d/episodes.eplog" "$host:$ws/$d/report.txt" "$d/" || true
  rs -a "$host:$ws/$d.log" "$d.log" || true
  ls -la "$d" "$d/accepted" 2>/dev/null
}

case $cmd in
  setup) setup ;;
  ckpt) ckpt "${4:-}" ;;
  check) check "${4:-}" ;;
  act) act "${4:-}" "${5:-}" ;;
  pull) pull "${4:-}" ;;
  *) echo "usage: act-box.sh setup|ckpt|check|act|pull HOST PORT ..." >&2; exit 2 ;;
esac
