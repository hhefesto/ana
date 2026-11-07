#!/usr/bin/env bash
# run5d.sh's control flow in seconds, no real work: stubs at its relative paths and for systemd, in a throwaway tree.
# plan-windows fails once at 8 jobs (the fallback); shard 91 fails its units; shard 92 ends after the freeze.
set -u
R=$(mktemp -d /tmp/bx/r5dsim.XXXX); ROOT=$PWD; mkdir -p $R/bin $R/run/v8 $R/run/v5/clean $R/run/v6/mix $R/a2b $R/gh $R/units
cp run/v8/run5d.sh run/v8/fill5c.sh $R/run/v8/
cat > $R/bin/systemctl <<'EOF'
#!/usr/bin/env bash
# --user is-active -q U | stop U | reset-failed U
U=$SIMROOT/units; shift
case $1 in
  is-active) [ -s $U/$3 ] && kill -0 $(cat $U/$3) 2>/dev/null ;;
  stop) echo "stop $2" >> $SIMROOT/stops; [ -s "$U/$2" ] && pkill -P $(cat "$U/$2") 2>/dev/null; [ -s "$U/$2" ] && kill $(cat "$U/$2") 2>/dev/null; rm -f "$U/$2"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat > $R/bin/systemd-run <<'EOF'
#!/usr/bin/env bash
n=; a=()
while [ $# -gt 0 ]; do case $1 in
  --unit=*) n=${1#--unit=}; shift ;;
  --user|--collect|--same-dir) shift ;;
  --slice=*|--setenv=*) shift ;;
  -p) shift 2 ;;
  *) break ;;
esac; done
( exec "$@" >> $PWD/run/v8/$n.log 2>&1 ) &
echo $! > $SIMROOT/units/$n
EOF
cat > $R/run/v8/gh-cut.sh <<'EOF'
#!/usr/bin/env bash
echo gh-cut; exit 1
EOF
cat > $R/run/v5/clean/a2bsrc.sh <<'EOF'
#!/usr/bin/env bash
k=$1; [ $k = gh91 ] && exit 1
[ $k = gh92 ] && sleep 60
sleep 1; mkdir -p run/v6/transcripts-a2b$k/bend; echo x > run/v6/transcripts-a2b$k/bend/results.train.nul; echo x > run/v6/transcripts-a2b$k/bend/transcripts.train.nul
EOF
cat > $R/run/v5/clean/mugen6q.sh <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = move ]; then for d in run/v6/transcripts-*; do n=${d##*/transcripts-}; [ -s $d/bend/results.train.nul ] && mkdir -p run/v6/mugen/$n && touch run/v6/mugen/$n/DONE; done; exit 0; fi
sleep 1
EOF
cat > $R/run/v5/clean/chain6.sh <<'EOF'
#!/usr/bin/env bash
for d in run/v6/mugen/*/DONE; do [ -e "$d" ] || continue; n=${d%/DONE}; n=${n##*/}; [ $n = chain ] && continue; mkdir -p run/v6/mugen/chain/$n; touch run/v6/mugen/chain/$n/DONE; done
EOF
cat > $R/run/v5/clean/mix6.sh <<'EOF'
#!/usr/bin/env bash
o=$1; mkdir -p $(dirname $o); echo "mix6 $o ${2:-} list=$A2BLIST share=${SHARE:-}: $(cat $A2BLIST)" >> $SIMROOT/mixes
printf 'out-first 600000\nout-other 1000\nout-free-repair 100\nout-derived 1\nout-copy 1000000\nout-repair 1400000\n' > $o.stats
[ "${2:-}" = dry ] && exit 0
printf 'id1\0text\0id2\0text\0' > $o
EOF
mkdir -p $R/run/v6/gcroot-nulmix/bin $R/run/v6/gcroot-bend-plan-windows/bin $R/run/v2/transcripts/bend/x
cat > $R/run/v6/gcroot-nulmix/bin/fillunion <<'EOF'
#!/usr/bin/env bash
printf 'a\0b\0' > $1.tmp; echo "fillunion $*" >> $SIMROOT/mixes
EOF
cat > $R/run/v6/gcroot-bend-plan-windows/bin/bend-plan-windows <<'EOF'
#!/usr/bin/env bash
echo "plan JOBS=$JOBS K=$FILLER_COPIES OUT=$OUT $*" >> $SIMROOT/mixes
[ $JOBS = 8 ] && exit 1
mkdir -p $1; echo "windows 1 86662" > $1/plan-fp100m-b16-windows.tsv
EOF
chmod +x $R/bin/* $R/run/v8/*.sh $R/run/v5/clean/*.sh $R/run/v6/gcroot-nulmix/bin/* $R/run/v6/gcroot-bend-plan-windows/bin/*
cd $R
for l in haskell agda lean nix; do printf 'a\0b\0' > run/v6/mix/$l; done
# 38 streams, as R5c's; gh5 is in it, which must not take gh50 with it
printf '%s' "a2bold1" > run/v8/r5c.a2b; for i in $(seq 2 37); do printf ' a2bold%s' $i >> run/v8/r5c.a2b; done; echo ' a2bgh5' >> run/v8/r5c.a2b
for k in gh5 gh50 gh51 gh91 gh92 gh90-x; do mkdir -p a2b/corpus-$k; printf 'm\t1\tx\tchecked\n' > a2b/corpus-$k/ledger.tsv; done
printf 'm\nm\nm\n' >> a2b/corpus-gh51/ledger.tsv; mkdir -p a2b/corpus-gh93
: > run/v8/a2bsrc15.log
export SIMROOT=$R ANA=$R A2BDIR=$R/a2b GHDIR=$R/gh TICK=1 PATH=$R/bin:$PATH
t() { date -d "+$1 sec" '+%F %T'; }
export EXPSTOP="$(t 1)" NONEW="$(t 2)" CUT="$(t 3)" DRYAT="$(t 8)" FREEZE="$(t 14)"
bash run/v8/run5d.sh; echo "exit $?"
echo "--- stops"; sort -u stops | tr '\n' ';'; echo
echo "--- mixes"; cut -c1-260 mixes
echo "--- r5d.a2b tail"; cut -d' ' -f39- run/v8/r5d.a2b; echo "--- dry tail"; cut -d' ' -f39- run/v8/r5d.a2b.dry
echo "--- links"; ls run/v8/R5dsrc/bend | tr '\n' ' '; echo; ls run/v8/R5d; echo "--- gh"; ls gh
cd $ROOT; [ -n "${KEEP:-}" ] || rm -rf "$R"
