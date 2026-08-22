#!/usr/bin/env bash
# diloco-check.sh — confirm the ranks have not drifted apart.
#
# After every outer step each rank logs a digest of its parameters.  The ranks
# average in a fixed rank order from values that are exactly representable as
# f32, so those digests are equal by construction -- which makes an inequality
# a real alarm rather than expected floating-point noise, and makes this a
# cheap standing check rather than a diagnostic of last resort.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

logs=(run/train-rank*.log)
if [ ! -e "${logs[0]}" ]; then
  echo "diloco-check: no run/train-rank*.log yet" >&2
  exit 1
fi

reference=""
status=0
for log in "${logs[@]}"; do
  rank="${log##*rank}"; rank="${rank%%.log}"
  extracted="$(mktemp)"
  grep -o 'outer_step=[0-9]* step=[0-9]* rank=[0-9]* digest=[0-9a-f]*' "$log" \
    | sed 's/ rank=[0-9]*//' > "$extracted"
  count="$(wc -l < "$extracted")"
  echo "rank $rank: $count outer steps, last $(tail -n1 "$extracted" 2>/dev/null || echo none)"
  if [ -z "$reference" ]; then
    reference="$extracted"
  else
    # Compare only the prefix both ranks have reached; one being a few steps
    # ahead is normal, disagreeing on a step they have both passed is not.
    lines="$(( $(wc -l < "$reference") < count ? $(wc -l < "$reference") : count ))"
    if ! diff <(head -n "$lines" "$reference") <(head -n "$lines" "$extracted") > /dev/null; then
      echo "DRIFT: rank $rank disagrees with rank 0" >&2
      diff <(head -n "$lines" "$reference") <(head -n "$lines" "$extracted") | head -6 >&2
      status=1
    fi
  fi
done
[ "$status" -eq 0 ] && echo "digests agree across ranks"
exit "$status"
