#!/usr/bin/env bash
# check-link.sh — refuse to start a deploy against a link that cannot carry it.
#
# Three rented instances in a row accepted SSH, then reset every sustained
# transfer: a burst of a few hundred MB/s, a collapse to under 1 MB/s, and a
# peer reset. One of them took 90 minutes of billed time before that became
# obvious. This makes it obvious in about twenty seconds.
#
# The test is deliberately a *sustained* transfer rather than a ping or a login:
# every one of those boxes passed a login and failed a transfer, which is the
# whole problem.
#
# usage: ./deploy/check-link.sh [user@]host [port] [megabytes]
# exit 0 = usable, 1 = do not deploy against this box
set -euo pipefail

host=${1:?usage: check-link.sh [user@]host [port] [megabytes]}
port=${2:-22}
mb=${3:-20}
min_kbs=${MIN_KBS:-500}

ssh_opts="-p $port -o BatchMode=yes -o ConnectTimeout=25 -o ServerAliveInterval=15"

echo "check-link: sustained ${mb} MB transfer to $host:$port ..."
start=$(date +%s%N)
if ! dd if=/dev/zero bs=1M count="$mb" 2>/dev/null \
  | timeout 300 ssh $ssh_opts "$host" "cat > /tmp/.link-probe && stat -c %s /tmp/.link-probe" \
  > /tmp/.link-probe-result 2>/dev/null; then
  echo "check-link: FAILED — the transfer did not complete." >&2
  echo "  This box will not carry the closure or the corpus. Destroy it." >&2
  exit 1
fi
end=$(date +%s%N)

got=$(tr -d '\r' < /tmp/.link-probe-result | tail -1)
want=$((mb * 1024 * 1024))
rm -f /tmp/.link-probe-result
ssh $ssh_opts "$host" 'rm -f /tmp/.link-probe' 2>/dev/null || true

if [ "${got:-0}" != "$want" ]; then
  echo "check-link: FAILED — $got of $want bytes arrived. Destroy this box." >&2
  exit 1
fi

seconds=$(awk -v a="$start" -v b="$end" 'BEGIN{printf "%.2f", (b-a)/1e9}')
kbs=$(awk -v w="$want" -v s="$seconds" 'BEGIN{printf "%.0f", w/1024/s}')
printf 'check-link: OK — %s MB in %s s (%s kB/s)\n' "$mb" "$seconds" "$kbs"

if [ "$kbs" -lt "$min_kbs" ]; then
  echo "check-link: WARNING — under ${min_kbs} kB/s." >&2
  echo "  The 15 GB corpus would take $(awk -v k="$kbs" 'BEGIN{printf "%.1f", 15*1024*1024/k/3600}') hours at this rate." >&2
  exit 1
fi
