#!/usr/bin/env bash
# R5b's Bend mix again (11-04 23:30): repair-mix at 2bad31d keeps an id's first read, where run/v6/mix2/bend had 3,635 ids
# twice and mix-corpus refused it at the end of plan-windows.  The share stays the dry mix's 87 (19:20): the ids dropped are
# 0.25% of what it counted, and a second dry mix takes 48 min.  Then run5b.sh goes on from its plan (bend.done).
cd /home/hhefesto/src/ana || exit 1
export BEND_NO_TELEMETRY=1 LC_ALL=C
M2=run/v6/mix2
export CV=$PWD/run/v6/mugen/chain/gcroot-bend-corpus-v2/bin/bend-corpus-v2
rm -f $M2/bend.done
MG=1 FF=1 CH=1 SHARE=87 run/v5/clean/mix6.sh $M2/bend > $M2/bend.log 2>&1 || { echo "FAILED: mix6 ($M2/bend.log)"; exit 1; }
n=$(gawk 'BEGIN{RS="\0"} NR%2==1' $M2/bend | sort -S 2G -T /tmp/bx | uniq -d | wc -l)
echo "ids twice: $n"; [ "$n" = 0 ] || exit 1
touch $M2/bend.done
systemd-run --user --unit=ana-run5b --collect --slice=ana-work.slice -p WorkingDirectory=$PWD -p StandardOutput=append:$PWD/run/v6/run5b.log -p StandardError=append:$PWD/run/v6/run5b.log bash run/v6/run5b.sh
