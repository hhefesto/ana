# Shared settings of the tools/a2b scripts (sourced, not run; R is the repo).
# A2B_BEND: the bend that checks: the flake's (hhefesto/bend2, with record eta), GC-rooted
#           at run/a2b/gcroot-bend (`nix build .#bend -o run/a2b/gcroot-bend`; made here
#           when missing).  run/gcroot-bend is older (no eta) and fails gated modules.
# A2B_LOCK: the lock that serialises heavy Bend compiles between agents.
# A2B_TMP:  scratch (logs, stub projects) outside the repo.
# A2B_CC:   the C compiler for the dev builds.
if [ -z "$A2B_BEND" ]; then
  [ -x "$R/run/a2b/gcroot-bend/bin/bend" ] || (cd "$R" && nix build .#bend -o run/a2b/gcroot-bend) >&2
  A2B_BEND=$R/run/a2b/gcroot-bend/bin/bend
fi
A2B_LOCK=${A2B_LOCK:-/tmp/claude-1000/bend-heavy.lock}
A2B_TMP=${A2B_TMP:-/tmp/claude-1000/a2b}
mkdir -p "$(dirname "$A2B_LOCK")" "$A2B_TMP"
if [ -z "$A2B_CC" ]; then
  A2B_CC=$(command -v clang || ls -d /nix/store/*-clang-wrapper-21.1.8/bin/clang 2>/dev/null | head -1)
fi
