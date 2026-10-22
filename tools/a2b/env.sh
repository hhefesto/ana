# Shared settings of the tools/a2b scripts (sourced, not run).
# A2B_LOCK: the lock that serialises heavy Bend compiles between agents.
# A2B_TMP:  scratch (logs, stub projects) outside the repo.
# A2B_CC:   the C compiler for the dev builds.
A2B_LOCK=${A2B_LOCK:-/tmp/claude-1000/bend-heavy.lock}
A2B_TMP=${A2B_TMP:-/tmp/claude-1000/a2b}
mkdir -p "$(dirname "$A2B_LOCK")" "$A2B_TMP"
if [ -z "$A2B_CC" ]; then
  A2B_CC=$(command -v clang || ls -d /nix/store/*-clang-wrapper-21.1.8/bin/clang 2>/dev/null | head -1)
fi
