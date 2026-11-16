#!/usr/bin/env bash
# El cubo de Edgar's render (2026-11-16; run/v9/col10c.sh's checked units): once ana-col10c says DONE, f6.sh as
# r7chain2 ran it for col10b, into run/v9/f6c (exlaw, the authors' laws of LAWS.bend, the ask, the render in the
# mugen shape, the join split into train and R7's fixed validation set; F6 and N name every output, so f6's and
# f6b's are not touched).  The mix that takes it is the next run's (run7.sh's EXTRA, as col10b's): R7 as built has
# it not.  Nothing is rented.  A thin shim: the logic is f6.sh's.
cd /home/hhefesto/src/ana || exit 1
V=run/v9
say() { echo "$(date '+%F %T') col10c-f6: $*"; }
until grep -q 'col10c DONE' $V/col10c.log 2>/dev/null; do
  systemctl --user -q is-active ana-col10c || grep -q 'col10c DONE' $V/col10c.log || { say "ana-col10c stopped without DONE ($V/col10c.log)"; exit 1; }
  sleep 60
done
say "col10c done: $(tr '\n' ' ' < $V/transcripts-col10c/bend/results.train.nul.stats 2>/dev/null)"
F6=$V/f6c N=col10c R=$V/transcripts-col10c/bend/results.train.nul SRCS=$V/collect10c/src/bend P=${P:-8} \
  bash $V/f6.sh > $V/f6c.log 2>&1 || { say "f6 FAILED ($V/f6c.log)"; exit 1; }
say "f6c DONE: $(tail -3 $V/f6c.log | tr '\n' ' ')"
