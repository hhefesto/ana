#!/usr/bin/env bash
# R5b's mix again (the guard stopped it at 02:46, 94% through), once the smaller emits have left the memory: it peaks at 8 G
cd /home/hhefesto/src/ana || exit 1
while systemctl --user is-active -q a2b-plfa22 a2b-aa21 a2b-pm21 a2b-hs23 a2b-pre23 a2b-rd1; do sleep 120; done
systemctl --user reset-failed ana-mix2 2>/dev/null
exec systemd-run --user --unit=ana-mix2 --collect --slice=ana-work.slice -p WorkingDirectory=$PWD -p StandardOutput=append:$PWD/run/v8/remix5b.log -p StandardError=append:$PWD/run/v8/remix5b.log /run/current-system/sw/bin/bash run/v8/remix5b.sh
