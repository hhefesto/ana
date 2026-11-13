#!/usr/bin/env zsh
# Form 2's kinds, held to the tool (2026-11-13; docs/form2/KINDS.md): every echo of a rendered session against
# agent-mugen's on the same calls (the episode up to that echo's heading), byte for byte but for blank lines at its ends.
#   f3-roundtrip.zsh RESULTS SESSIONS SESSION-ID SHAPE SRC
# RESULTS the units the session was rendered from (bend-transcript's input), SESSIONS its output, SHAPE the task's shape
# for agent-mugen (direct-cut for a Bend direct ask, chain or fix that starts from one; fill; repair-M), SRC a tree
# holding the unit's repository.  CV (bend-corpus-v2), BEND, W (the work directory, /tmp/bx/f3/rt) from the environment.
# A thin shim: the logic is bend-corpus-v2 agent-mugen's and bend-transcript's.  Prints a line an echo, then the count.
set -u
R=$1 S=$2 sid=$3 shape=$4 src=$5
CV=${CV:-run/v9/f3/gcroot-cv2/bin/bend-corpus-v2}
BEND=${BEND:-run/v5/gcroot-bend-2.0.39/bin/bend}
trim() { sed -e "/./,\$!d" "$1" | tac | sed -e "/./,\$!d" | tac; }
w=${W:-/tmp/bx/f3/rt}/${${sid//[^A-Za-z0-9]/_}[-60,-1]}; rm -rf $w; mkdir -p $w
unit=${sid%/*}
LC_ALL=C gawk -v RS='\0' -v ORS='\0' -v u="$unit" -v src="$src" -v sh="$shape" \
  'NR % 2 == 1 {id = $0; next} id == u {print id; printf "%s\036%s\036%s\0", src, sh, $0; exit}' $R > $w/task.nul
[ -s $w/task.nul ] || { echo "no record for $unit"; exit 1; }
LC_ALL=C gawk -v RS='\0' -v s="$sid" 'NR % 2 == 1 {id = $0; next} id == s {printf "%s", $0; exit}' $S > $w/session.txt
n=$(grep -c '^## echo$' $w/session.txt); bad=0
for k in $(seq 1 $n); do
  LC_ALL=C gawk -v k=$k -v ep=$w/ep.$k -v want=$w/want.$k '
    state == 0 { print > ep }
    state == 0 && /^## echo$/ { if (++e == k) state = 1; next }
    state == 1 { if (/^## [a-z]+$/) state = 2; else print > want }' $w/session.txt
  BEND=$BEND AGENT_WORK=$w/work AM_FORM=2 BEND_NO_TELEMETRY=1 $CV agent-mugen $w/task.nul echo < $w/ep.$k > $w/got.$k 2> $w/err.$k; st=$?
  if cmp -s <(trim $w/want.$k) <(trim $w/got.$k); then echo "echo $k: same (exit $st)"
  else echo "echo $k: DIFFER (exit $st)"; diff <(trim $w/want.$k) <(trim $w/got.$k) | head -12; bad=$((bad + 1)); fi
done
echo "$sid: $n echoes, $bad differ"
