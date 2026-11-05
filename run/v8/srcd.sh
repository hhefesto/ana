#!/usr/bin/env bash
# The units of the emits that have ended, on delfos (the user, 11-05: "Move all current tasks to just delfos"): these are
# hours run5c.sh would otherwise spend after 21:00, and olimpo has no room for them while R5b's mix and plan run.  a2bsrc.sh
# itself, one stream at a time as it does here, with a copy of each earlier stream's results as its seen= (tod3, 08:25; 
# a stream done here comes back with its results, and a NAME DONE in a2bsrc15.log that run5c.sh then skips).  A stream it does
# not finish stays as it was here, and run5c.sh does it.  It stops DEADLINE less 30 minutes.
#   STREAMS (the order is decl-new's: each sees those before)
cd /home/hhefesto/src/ana || exit 1
H=192.168.3.6; R=/home/hhefesto/ana-help/r5; A=/home/hhefesto/src/agda2bend/run/a2b
DL=$(( $(date -d "${DEADLINE:-2026-11-05 21:00}" +%s) - 1800 ))
say() { echo "$(date '+%F %T') srcd: $*"; }
LOG=run/v8/a2bsrc15.log
sed -e "s|^cd /home/hhefesto/src/ana|cd $R|" -e "s|^B=/home/hhefesto/src/ana/|B=$R/|" -e 's|^D=run/v5/gcroot-deploy-982e162/bin/deploy|D=run/v5/deploy-982e162-t180/bin/deploy|' run/v5/clean/a2bsrc.sh | ssh $H "cat > $R/run/v5/clean/a2bsrc-d.sh && chmod +x $R/run/v5/clean/a2bsrc-d.sh" || { say "no a2bsrc-d.sh"; exit 1; }
RPATH=$(ssh $H 'echo $PATH')
stop() { ssh $H "systemctl --user stop 'ana-help-src-*'" 2>/dev/null; }
trap 'stop; exit 1' TERM INT
for k in ${STREAMS:-at2 um16 aa21 pm21 rd1}; do
  n=a2b$k
  grep -q "$n DONE" $LOG 2>/dev/null && continue
  [ "$(date +%s)" -ge "$DL" ] && { say "the deadline"; break; }
  systemctl --user is-active -q a2b-$k && { say "$k: its emit runs, left"; continue; }
  say "$n: there"
  rsync -a --exclude=export $A/corpus-$k $H:$A/ || { say "$n: rsync of the corpus FAILED"; continue; }
  [ -e $A/corpus-$k.log ] && rsync -a $A/corpus-$k.log $H:$A/
  case $k in gh*) ssh $H "mkdir -p $A/ev-$k"; rsync -a $A/ev-$k/own.txt $H:$A/ev-$k/ || { say "$n: no own.txt"; continue; } ;; esac
  mkdir -p run/v6/transcripts-$n
  rsync -a run/v6/transcripts-$n $H:$R/run/v6/ || { say "$n: rsync FAILED"; continue; }
  [ -d run/v5/clean/src/$n ] && { ssh $H "mkdir -p $R/run/v5/clean/src"; rsync -a run/v5/clean/src/$n $H:$R/run/v5/clean/src/; }
  # (to the deadline: the unit's own timeout, so that a stream cannot outlive this)
  left=$(( DL - $(date +%s) ))
  ssh $H "systemctl --user reset-failed ana-help-src-$k 2>/dev/null; systemd-run --user --wait --collect --unit=ana-help-src-$k --slice=ana-help.slice -p MemoryMax=${MEM:-6G} -p MemorySwapMax=2G -p OOMPolicy=continue -p RuntimeMaxSec=$left -p WorkingDirectory=$R --setenv=PATH='$RPATH' --setenv=CHECK_PROCS=${CHECK_PROCS:-3} --setenv=CHECKD_N=${CHECKD_N:-2} --setenv=CHECKD_PORT=${CHECKD_PORT:-47500} -p StandardOutput=append:$R/run/v8/a2bsrc-d.log -p StandardError=append:$R/run/v8/a2bsrc-d.log /run/current-system/sw/bin/bash run/v5/clean/a2bsrc-d.sh $k" >/dev/null 2>&1 || { say "$n: FAILED there (delfos $R/run/v8/a2bsrc-d.log); run5c.sh takes it"; ssh $H "tail -3 $R/run/v8/a2bsrc-d.log" | cut -c1-200; continue; }
  ssh $H "grep -q '$n DONE' $R/run/v8/a2bsrc-d.log" || { say "$n: no DONE there"; continue; }
  rsync -a $H:$R/run/v6/transcripts-$n run/v6/ || { say "$n: back FAILED"; continue; }
  mkdir -p run/v5/clean/src; rsync -a $H:$R/run/v5/clean/src/$n run/v5/clean/src/ || { say "$n: tree back FAILED"; continue; }
  echo "$(date '+%F %T') $n DONE" >> $LOG
  say "$n DONE: $(tr -cd '\0' < run/v6/transcripts-$n/bend/transcripts.train.nul | wc -c | awk '{print int($1/2)}') sessions"
done
say "end"
