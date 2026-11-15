#!/usr/bin/env bash
# Run 7's box (unit ana-r7go).  The user, 11-15: "be ready to train on my approval": this script rents, so it is
# started only after that approval, with RENT_OK=yes; without it, it stops before anything is rented.  As run6go.sh:
#   1. R7 must be ready: run/v9/run7.sh (from ana-r7chain2) logged "end: run/v9/R7 is ready", and R7's fixed
#      validation set run/v9/R7valid/shard-0-fp100m.corpus is there.  Otherwise nothing is rented.
#   2. Rents the cheapest RTX 5090 that fits RUN5.md step 2 (one GPU, reliability > 0.98, 100 GB disk, 64 GB RAM,
#      verified, a contract of 4 days or more, at most $MAXDPH an hour; not in China), sets it up (rsync, clang 19).
#   3. Stages R7 (ana-stage7), the checkpoint C (ana-ckpt7) and the validation set (ana-valid7), checks both sums,
#      then gate (PASS, 0 gemm as loops), time, `again` from C as r7 with VALID_CORPUS (TrainDense's fixed
#      validation, 71a9d9b; never run on a GPU before: the script waits for r7.log's "fixed windows" line), and the
#      guard (tools/runs/run7.cfg: chain + credit watch), which pulls a save every 5,000 steps and destroys the box
#      when r7 is done.
# C: the checkpoint r7 starts from (the user's choice; default R5g's last, r5g-step106500, as R6 started).
# Until r7 trains, a failure destroys the box (it holds only copies) and the next offer is tried, two boxes at most.
# Once the guard runs, the box is the chain's.  Log: run/v9/run7go.log; the box's outputs in run/v9/run7/.
A=/home/hhefesto/src/ana
cd $A || exit 1
D=run/v9/run7 P=run/v9/R7 CFG=tools/runs/run7.cfg E=bend/gpu/r7-box.env
VC=run/v9/R7valid/shard-0-fp100m.corpus
C=${C:-r5g-step106500}
CF=; for d in run/v9/run5g/out run/v9/run6/out; do [ -s $d/$C.checkpoint ] && { CF=$d/$C.checkpoint; break; }; done
PL=$P/plan-fp100m-b16-windows.tsv
V=$HOME/.local/share/vastai-venv/bin/vastai
MAXDPH=${MAXDPH:-0.95}
IMG=nvidia/cuda:12.8.1-devel-ubuntu22.04
Q='gpu_name=RTX_5090 num_gpus=1 reliability>0.98 inet_down>200 inet_up>100 disk_space>=100 cpu_ram>=64 duration>=4 verified=true'
export PATH=$PWD/run/gcroot-bend-ops/bin:$PATH
SO="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=30 -o ServerAliveInterval=30 -o BatchMode=yes"
mkdir -p $D/out
say() { echo "$(date '+%F %T') $*"; }
IID=
gone() { if [ -n "$IID" ]; then say "destroying vast $IID (r7 not started on it)"; $V destroy instance $IID -y; IID=; fi; }
die() { say "FAILED: $*"; gone; exit 1; }
trap 'say "stopped"; gone; exit 1' TERM INT
box() { timeout ${T:-1800} ssh $SO -p $SP root@$SH "$@"; }

[ "$RENT_OK" = yes ] || die "RENT_OK is not yes: renting waits for the user's approval; nothing rented"
while systemctl --user is-active -q ana-r7chain2; do
  grep -q "end: $P is ready" run/v9/run7.log 2>/dev/null && break
  say "waiting for R7 (ana-r7chain2, run/v9/r7chain2.log)"; sleep 300
done
grep -q "end: $P is ready" run/v9/run7.log 2>/dev/null || die "run7 ended without R7 ($(tail -n 1 run/v9/run7.log 2>/dev/null)); nothing rented"
[ -s $PL ] || die "no $PL"
[ -s $VC ] || die "no $VC (R7's validation set)"
[ -n "$CF" ] || die "no checkpoint $C in run/v9/run5g/out or run/v9/run6/out"
steps=$(head -n 1 $PL | cut -d' ' -f3)
credit=$($V show user --raw | jq -r .credit)
say "R7 ready: $steps steps, about $((steps * 25 / 36000)) h at 2.5 s a step, about \$$(awk -v s=$steps -v d=$MAXDPH 'BEGIN {printf "%.0f", s*2.5/3600*d}') at most at \$$MAXDPH/h; credit \$$credit; from $CF"
awk -v c="$credit" 'BEGIN {exit !(c >= 5)}' || die "credit \$$credit is under \$5; nothing rented"
ln -f $CF $D/out/   # the chain holds every checkpoint on the box to a copy here; without this one it never destroys

attempt() {
  local oid i j st out
  oid=
  for i in $(seq 1 12); do
    oid=$($V search offers "$Q" -o dph --raw | jq -r '.[] | select(((.geolocation // "") | test("China|CN")) | not) | "\(.id) \(.dph_total) \(.geolocation)"' \
      | awk -v skip=" $tried " -v max=$MAXDPH 'index(skip, " " $1 " ") == 0 && $2 <= max' | head -n 1)
    [ -n "$oid" ] && break
    say "no offer under \$$MAXDPH/h; again in 10 min"; sleep 600
  done
  [ -n "$oid" ] || { say "no offer in 2 h"; return 1; }
  say "offer $oid"
  OID=${oid%% *}
  out=$($V create instance $OID --image $IMG --disk 100 --ssh --direct --raw 2>&1)
  IID=$(echo "$out" | grep -o '"new_contract": *[0-9]*' | grep -o '[0-9]*$')
  [ -n "$IID" ] || { say "create: $out"; return 1; }
  echo $IID > $D/INSTANCE
  say "rented vast $IID"
  for i in $(seq 1 40); do
    j=$($V show instance $IID --raw 2>/dev/null | jq 'if type == "array" then .[0] else . end' 2>/dev/null)
    st=$(echo "$j" | jq -r '.actual_status // empty' 2>/dev/null)
    [ "$st" = running ] && break
    sleep 30
  done
  [ "$st" = running ] || { say "not running after 20 min ($st)"; return 1; }
  echo "$j" > $D/instance.json
  HOST=$(echo "$j" | jq -r .ssh_host) PORT=$(echo "$j" | jq -r .ssh_port)
  DIP=$(echo "$j" | jq -r '.public_ipaddr // empty' | tr -d ' \n') DPORT=$(echo "$j" | jq -r '.ports["22/tcp"][0].HostPort // empty')
  say "relay $HOST:$PORT, direct ${DIP:-none}:${DPORT:-none}"
  ssh-keygen -R "[$HOST]:$PORT" > /dev/null 2>&1; [ -n "$DIP" ] && ssh-keygen -R "[$DIP]:$DPORT" > /dev/null 2>&1
  # the relay is the chain's; the direct port, when it answers, stages (faster)
  for i in $(seq 1 20); do ssh $SO -p $PORT root@$HOST true 2>/dev/null && break; sleep 30; done
  ssh $SO -p $PORT root@$HOST true || { say "no ssh through the relay"; return 1; }
  SH=$HOST SP=$PORT
  if [ -n "$DIP" ] && [ -n "$DPORT" ] && ssh $SO -p $DPORT root@$DIP true 2>/dev/null; then SH=$DIP SP=$DPORT; fi
  say "staging through $SH:$SP"

  say "setup: rsync, clang 19"
  box 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq rsync wget lsb-release gnupg software-properties-common && wget -qO- https://apt.llvm.org/llvm.sh | bash -s -- 19 && clang-19 --version | head -1 && mkdir -p ana/out ana/run/v9/R7valid' > $D/setup.log 2>&1 \
    || { say "setup ($D/setup.log: $(tail -1 $D/setup.log))"; return 1; }
  tail -1 $D/setup.log

  sed -i -e "s|^host .*|host root@$HOST|" -e "s|^port .*|port $PORT|" -e "s|^instance .*|instance $IID|" $CFG
  systemctl --user stop ana-stage7 ana-ckpt7 ana-valid7 2>/dev/null; systemctl --user reset-failed ana-stage7 ana-ckpt7 ana-valid7 2>/dev/null
  systemd-run --user -q --unit=ana-stage7 -p WorkingDirectory=$A --setenv=PATH="$PATH" \
    bash -c "{ echo \"\$(date '+%F %T') stage box\"; BOX_ENV=$E bend-ops stage box root@$SH $SP; echo rc=\$?; } >> $D/stage.log 2>&1" > /dev/null
  systemd-run --user -q --unit=ana-ckpt7 -p WorkingDirectory=$A \
    bash -c "rsync -a -e 'ssh $SO -p $SP' --partial $CF root@$SH:ana/out/ > $D/ckpt.log 2>&1; echo rc=\$? >> $D/ckpt.log" > /dev/null
  systemd-run --user -q --unit=ana-valid7 -p WorkingDirectory=$A \
    bash -c "rsync -a -e 'ssh $SO -p $SP' --partial $VC root@$SH:ana/run/v9/R7valid/ > $D/valid.log 2>&1; echo rc=\$? >> $D/valid.log" > /dev/null
  say "staging (ana-stage7, $D/stage.log), the checkpoint (ana-ckpt7, $D/ckpt.log), the validation set (ana-valid7, $D/valid.log)"

  while systemctl --user is-active -q ana-ckpt7 ana-valid7; do sleep 60; done
  grep -qx "rc=0" $D/ckpt.log || { say "the checkpoint's rsync ($(tail -1 $D/ckpt.log))"; return 1; }
  grep -qx "rc=0" $D/valid.log || { say "the validation set's rsync ($(tail -1 $D/valid.log))"; return 1; }
  local here there f
  for f in "$CF out/$C.checkpoint" "$VC $VC"; do
    set -- $f
    here=$(sha256sum $1 | cut -d' ' -f1)
    there=$(box "sha256sum ana/$2" | cut -d' ' -f1)
    [ "$here" = "$there" ] || { say "$1 sha256: here $here, box $there"; return 1; }
    say "$1 on the box, sha256 $here"
  done

  say "waiting for the plan, shards 0-3 and bend-box on the box"
  local ok=
  for i in $(seq 1 240); do
    box "cd ana && test -x bend-box && test -s $PL && test -s $P/shard-3-fp100m.corpus" 2>/dev/null && { ok=1; break; }
    systemctl --user is-active -q ana-stage7 || break
    sleep 60
  done
  [ -n "$ok" ] || box "cd ana && test -x bend-box && test -s $PL && test -s $P/shard-3-fp100m.corpus" || { say "no plan, shards or bend-box (the stage: $(tail -1 $D/stage.log))"; return 1; }
  box 'cd ana && cp run/eval/v2-mugen.corpus run/eval/transcript-next.corpus' || say "no run/eval/v2-mugen.corpus on the box yet: eval-next.log will score R7's own holdout"

  say "gate"
  box "cd ana && ./bend-box gate" > $D/gate.out 2>&1
  tail -5 $D/gate.out
  grep -q "PASS" $D/gate.out || { say "gate did not PASS ($D/gate.out)"; return 1; }
  grep -q "(0 as loops)" $D/gate.out || { say "gate: gemm as loops ($D/gate.out)"; return 1; }

  say "time"
  box "cd ana && PLAN=$PL RUN=$P ./bend-box time" > $D/time.out 2>&1 || { say "time ($D/time.out)"; return 1; }
  tail -3 $D/time.out

  say "again from $C as r7, VALID_CORPUS=$VC"
  box "cd ana && VALID_CORPUS=$VC NLR=1e-4 NWARM=300 ./bend-box again out/$C.checkpoint $PL $P fp100m r7" > $D/again.out 2>&1 || { say "again ($D/again.out)"; return 1; }
  # the first validation reading on the fixed set: TrainDense says "validation: N fixed windows of PATH"
  for i in $(seq 1 20); do
    sleep 60
    box "cd ana && head -40 r7.log" > $D/r7-head.out 2>&1
    grep -q "fixed windows of" $D/r7-head.out && break
  done
  cat $D/r7-head.out
  grep -q "loaded" $D/r7-head.out || { say "r7.log does not open with loaded"; return 1; }
  grep -q "fixed windows of" $D/r7-head.out || { say "r7.log has no fixed validation windows after 20 min (VALID_CORPUS not read)"; return 1; }

  say "guard"
  bend-ops guard $CFG install || { say "guard install"; return 1; }
  bend-ops guard $CFG || { say "guard"; return 1; }
  systemctl --user is-active ft-fp-chain-v7 ft-credit-watch-v7
  say "the box is the chain's now: vast $IID (relay $HOST:$PORT)"
  IID=
  return 0
}

tried=
for n in 1 2; do
  OID=
  if attempt; then say "end: r7 is training"; exit 0; fi
  tried="$tried $OID"
  systemctl --user stop ana-stage7 ana-ckpt7 ana-valid7 2>/dev/null
  gone
done
die "two boxes failed; nothing is rented"
