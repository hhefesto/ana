#!/usr/bin/env bash
# R8 (11-17): each language's R8 sessions less the private pairs (the user, 11-15: "secrets, emails and netsem
# out"; bend/NulFilter.bend, NF_MAXB 0: nothing cut), run/v9/mix8/LANG.r8 -> LANG.r8p.  A thin shim.
cd /home/hhefesto/src/ana || exit 1
NF=run/v9/gcroot-nf/bin/bend-nul-filter; N=run/v9/mix8
for l in bend haskell agda lean nix; do
  ( [ -e $N/$l.r8p.done ] || { NF_MAXB=0 NF_PRIVATE=$HOME/.config/ana/private-needles $NF $N/$l.r8 $N/$l.r8p.tmp > $N/$l.r8p.log 2>&1 \
      && mv $N/$l.r8p.tmp.stats $N/$l.r8p.stats && mv $N/$l.r8p.tmp $N/$l.r8p && touch $N/$l.r8p.done \
      && echo "$(date '+%F %T') $l: $(tr '\n' ' ' < $N/$l.r8p.stats)" || echo "$(date '+%F %T') $l: FAILED ($N/$l.r8p.log)"; } ) &
done
wait
