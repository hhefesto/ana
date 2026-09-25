# deploy/check/lib.sh: the part of the checker harness every language
# shares. Sourced by deploy/check/<lang>.sh, never run.
#
#   deploy/check/<lang>.sh UNITS.nul RESULTS.nul [JOBS]
#
# UNITS.nul is what bend-units wrote: NUL-framed (id, record) pairs, the
# record's fields joined by the byte 0x1E (bend/Units.bend lists them:
# 0 lang, 1 kind, 2 name, 3 doc, 4 sig, 5 head, 6 pre, 7 body, 8 tail,
# 9 names, 10 hole, 11.. mutants). The language's script defines
# check_unit, which runs the real checker on the unit's variants and either
# sets RESULT and returns 0, or returns 1 (the unit is dropped).
#
# RESULTS.nul holds one pair per kept unit (grouped by worker), the record's
# fields joined by 0x1E:
#
#   0..10  the unit's fields 0..10
#   11     the original's check
#   12     the Context: `name : type` lines as the checker printed them
#   13     the hole's check (empty: no hole)
#   14     the checker's type for the declaration's name (empty: none)
#   15..   pairs: a mutant, then its check (only mutants the checker rejects)
#
# A check is the checker's exit status, the byte 0x1F, and its output, with
# the work directory's path removed from it (so files read `Unit.hs`, not
# /tmp/...). A unit is kept when its original checks (exit 0); a mutant
# when its check fails with a status other than a timeout's 124. Every
# decision is counted in RESULTS.nul.stats.
#
# JOBS workers (default: the core count) take every JOBS-th unit each;
# check_unit sees the unit's fields in F and its id in UNIT_ID.

set -uo pipefail

FS=$'\x1e'
US=$'\x1f'
CAP_LINES=${CAP_LINES:-100}
TIMEOUT=${TIMEOUT:-60}

declare -A STATS=()
stat() { STATS[$1]=$(( ${STATS[$1]:-0} + ${2:-1} )); }

# the output of a command, capped, with the work directory's path removed
# and its trailing newlines kept out (they carry nothing)
clean() { sed -e "s|$1/||g" | head -n "$CAP_LINES"; }

# $1 as a check: "<status>\x1F<output>"
check_of() { printf '%s%s%s' "$1" "$US" "$2"; }

worker() {
  local in=$1 out=$2 jobs=$3 k=$4 dir=$5 n=0 id rec
  mkdir -p "$dir"
  : > "$out"
  while IFS= read -r -d '' id && IFS= read -r -d '' rec; do
    (( n++ % jobs == k )) || continue
    stat units
    F=()
    UNIT_ID=$id
    readarray -t -d "$FS" F < <(printf '%s' "$rec")
    if check_unit "$dir"; then
      stat kept
      printf '%s\0%s\0' "$id" "$RESULT" >> "$out"
    fi
  done < "$in"
  local key
  for key in "${!STATS[@]}"; do printf '%s %s\n' "$key" "${STATS[$key]}"; done > "$out.stats"
}

# the result record: the unit's fields 0..10, then the checks
result() {
  local IFS=$FS
  RESULT="${F[*]:0:11}$FS$*"
}

check_main() {
  local in=${1:?usage: $0 UNITS.nul RESULTS.nul [JOBS]} out=${2:?usage: $0 UNITS.nul RESULTS.nul [JOBS]}
  local jobs=${3:-$(nproc)} work k
  work=$(mktemp -d)
  for (( k = 0; k < jobs; k++ )); do
    worker "$in" "$out.part$k" "$jobs" "$k" "$work/$k" &
  done
  wait
  : > "$out"
  for (( k = 0; k < jobs; k++ )); do cat "$out.part$k" >> "$out"; done
  cat "$out".part*.stats | awk '{ s[$1] += $2 } END { for (k in s) print k, s[k] }' | sort > "$out.stats"
  rm -f "$out".part*
  rm -rf "$work"
  cat "$out.stats"
}
