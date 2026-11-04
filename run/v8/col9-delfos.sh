#!/usr/bin/env bash
# col9's check, the rest of it, on delfos (the user, 11-04: "delfos currently has only one core being used").
# olimpo's guard stopped ana-work.slice at 14:00 with 21,223 of the 36,791 units decided; run/v8/col9-salv holds
# what they kept (bend/CheckSalvage.bend). Delfos checks the other 15,568, then results.nul comes back here and
# run/v5/clean/col9.sh goes on from the render. A check's timeout is 240 s there, not 180: its 4 cores are shared.
cd /home/hhefesto/src/ana || exit 1
D=192.168.3.6; H=ana-help/c9; V=run/v8; T=$V/transcripts-col9
say() { echo "$(date '+%F %T') $*"; }
r() { ssh -o BatchMode=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=20 $D "$@"; }
put() { rsync -a --partial --timeout=300 -e 'ssh -o BatchMode=yes' "$@"; }
DP=/nix/store/y2qa5x4fah8czc1764js5khcfaxn3ffm-deploy
B=$(readlink -f run/v5/gcroot-bend-2.0.39)
say "closures"; nix copy --no-check-sigs --to ssh-ng://hhefesto@$D $DP $B || { say "nix copy FAILED"; exit 1; }
r "mkdir -p ~/$H/$T/bend ~/$H/$V/collect9/src"
say "tree"; put $V/collect9/src/bend $D:$H/$V/collect9/src/ || { say "tree FAILED"; exit 1; }
say "units"; put $T/col9.jsonl $D:$H/$T/ || exit 1
put $T/bend/units.nul $T/bend/files-hi.nul $T/bend/files-lo.nul $D:$H/$T/bend/ || exit 1
put $V/col9-salv/s.nul $D:$H/$T/bend/results.prev.nul || exit 1
put $V/col9-salv/s.ids $D:$H/done.ids || exit 1
n=$(wc -l < $V/col9-salv/s.ids); k=17688
printf 'kept %s\nrecovered-from-killed-shards %s\nunits %s\n' $k $k $k | r "cat > ~/$H/$T/bend/results.prev.nul.stats"
say "check on delfos"
SH="env CORPUS=$T/col9.jsonl OUT=$T BEND=$B/bin/bend BEND_SRC=$V/collect9/src/bend MAX=100000 MAX_HI=100000 HOLDOUT_PCT=0 TIMEOUT=240 DONE=\$HOME/$H/done.ids CHECK_PROCS=${CHECK_PROCS:-5} CHECK_JOBS=1 UNIT_JOBS=4 $DP/bin/deploy transcripts check bend"
r "systemctl --user reset-failed ana-help-col9 2>/dev/null; cd ~/$H && systemd-run --user --unit=ana-help-col9 --slice=ana-help.slice --same-dir --collect -p OOMPolicy=continue -p OOMScoreAdjust=300 -p MemoryHigh=${MEM_HIGH:-3G} -p MemoryMax=${MEM_MAX:-4G} -p Nice=5 -p StandardOutput=append:\$HOME/$H/check.log -p StandardError=append:\$HOME/$H/check.log --setenv=BEND_NO_TELEMETRY=1 sh -c '$SH'" || { say "start FAILED"; exit 1; }
sleep 30
while [ "$(r "systemctl --user is-active ana-help-col9" 2>/dev/null)" = active ]; do sleep 120; done
r "test -s ~/$H/$T/bend/results.nul.stats" || { say "check FAILED on delfos: ssh $D tail ~/$H/check.log"; exit 1; }
say "results here"
put $D:$H/$T/bend/results.nul $D:$H/$T/bend/results.nul.stats $T/bend/ || { say "copy FAILED"; exit 1; }
say "check: $(tr '\n' ' ' < $T/bend/results.nul.stats)"
say "DONE: run/v5/clean/col9.sh goes on from the render"
