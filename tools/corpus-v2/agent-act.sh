#!/usr/bin/env bash
# agent-act.sh CKPT DIR [K] (2026-10-07): ana's own episodes on train units,
# the turn-based training data (docs/AGENT.md): the act set's prompts
# (actset.sh) answered through the tool loop as E5 answers its own (the
# unit's real checker the tool, up to AGENT_CALLS = 4 calls), but sampled
# (TEMPERATURE 0.7, TOP_P 0.95), AGENT_SEEDS (2) a prompt, check tags from
# 200,000 (so it runs beside E5), the records from the train split. Every
# episode goes to DIR/episodes.eplog; then `bend-episode accept` keeps those
# that train (solved within K, the grammar, no escape hatch), at most 2 a
# unit, those that fixed a rejected term first, in DIR/accepted/LANG-act/
# transcripts.train.nul (a language each for bend-plan-windows).
# agent-eval resumes a DIR, so rerunning goes on where it stopped. K: only
# the first K prompts of each language and shape (a pilot; E5's cut: K = 10
# asks 90 prompts, 180 jobs at 2 seeds). Loading the records takes about
# 14 minutes over all of run/v2/results' 2.9 GB of train records; act-box.sh
# ships only the act set's.
#   systemd-run --user --unit=ft-act -p MemoryMax=26G -p OOMPolicy=continue --working-directory=$PWD \
#     bash -c "tools/corpus-v2/agent-act.sh CKPT DIR > DIR.log 2>&1"
set -euo pipefail
ckpt=${1:?usage: agent-act.sh CKPT DIR [K]}; dir=${2:?}; k=${3:-0}
cd /home/hhefesto/src/formalTransformer
D=${DEPLOY_BIN:-run/v2/gcroot-deploy-agent/bin/deploy}
EP=${EPISODE_BIN:-run/agent/gcroot-bend-episode/bin/bend-episode}
log() { echo "[$(TZ=Etc/GMT+6 date '+%Y-%m-%d %H:%M:%S') UTC-6] agent-act: $*"; }
log "start: $ckpt into $dir, ${PROCS:-5} processes x ${THREADS:-2} threads"
BEND_FT_THREADS=${FT_THREADS:-2} EVALSET=${ACTSET:-run/v2/act/prompts.nul} AGENT_DEPLOY=$D AGENT_RECORDS=train \
  TEMPERATURE=${TEMPERATURE:-0.7} TOP_P=${TOP_P:-0.95} AGENT_SEEDS=${AGENT_SEEDS:-2} AGENT_TAG=${AGENT_TAG:-200000} \
  TOKENS=${TOKENS:-160} AGENT_CALLS=${AGENT_CALLS:-4} PROCS=${PROCS:-5} THREADS=${THREADS:-2} \
  $D corpus-v2 agent-eval "$ckpt" "$dir" 2 $( [ "$k" != 0 ] && echo "$k" )
$EP accept ${AGENT_CALLS:-4} ${CAP:-2} "$dir/accepted" "$dir/episodes.eplog"
log done
