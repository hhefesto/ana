#!/usr/bin/env bash
# Raw code for the chain when no new transcripts are ready (the user,
# 2026-10-02: "Feed it raw code when nothing new is available"). From the
# repository root:
#   bend/gpu/raw-stage.sh mix                  split run/code-train-v3.jsonl by language and interleave it
#   bend/gpu/raw-stage.sh build K              slice K (~SLICE bytes of the mix) as shards and a plan in run/rawK
#   bend/gpu/raw-stage.sh push K HOST PORT     to the box as run/rawK (plan last, after every shard's sha)
# then append to the chain's stages:  rawK traind-next 0 run/rawK/plan-rawK-b16-windows.tsv run/rawK rawK
#
# New raw code (code ana has not been fed, run/raw-new/LANG*.jsonl from the
# 2026-10-03 agents, deduplicated against code-train-v3) goes through the same
# steps under another mix and prefix (R the mix's directory, P the stages' prefix):
#   R=run/rawnew1 bend/gpu/raw-stage.sh mixnew FILE.jsonl...   the files interleaved by language
#   R=run/rawnew1 P=nr bend/gpu/raw-stage.sh build K           slice K as run/nrK
#   P=nr bend/gpu/raw-stage.sh push K HOST PORT                stage nrK
#
# The mix: ana's five languages from the extracted code (Haskell .hs/.lhs,
# Lean, Agda .agda/.lagda, Nix, Bend; Idris and Markdown left out), PER
# documents a round in proportion to their counts, so they run dry together;
# and fp100m's transcripts (run/transcripts-final/LANG/transcripts.train.nul,
# as JSONL in run/raw/src/tr-LANG.jsonl) cycling at about 20% of the bytes, so hours of raw
# code keep the turn format in view. Documents are packed to 128 KB before
# tokenizing (PACK_TARGET), since the trainer makes no window from a shorter
# document. SIZE fp100m (ctx 2048), batch 16.
set -euo pipefail
R=${R:-run/raw}
P=${P:-raw}
SLICE=${SLICE:-300000000}

mix() {
  mkdir -p "$R/src"
  python3 - "$R/src" <<'PY'
import sys, json
out = sys.argv[1]
lang = {"hs": "haskell", "lhs": "haskell", "lean": "lean", "agda": "agda", "lagda": "agda", "nix": "nix", "bend": "bend"}
fs = {l: open(f"{out}/{l}.jsonl", "wb") for l in set(lang.values())}
n = {l: 0 for l in fs}
with open("run/code-train-v3.jsonl", "rb") as f:
    for line in f:
        i = line.find(b'"id":"'); j = line.find(b'"', i + 6)
        name = line[i + 6:j].decode("utf-8", "replace").rsplit("/", 1)[-1]
        ext = name.rsplit(".", 1)[-1] if "." in name else ""
        l = lang.get(ext)
        if l: fs[l].write(line); n[l] += 1
print(n)
# fp100m's transcripts as JSONL, for the replay
for l in ["haskell", "lean", "agda", "nix", "bend"]:
    d = open(f"run/transcripts-final/{l}/transcripts.train.nul", "rb").read().split(b"\0")
    with open(f"{out}/tr-{l}.jsonl", "w") as o:
        for i in range(0, len(d) - 1, 2):
            o.write(json.dumps({"id": d[i].decode("utf-8", "replace"), "text": d[i + 1].decode("utf-8", "replace")}, ensure_ascii=False) + "\n")
PY
  hs=$(wc -l < "$R/src/haskell.jsonl"); le=$(wc -l < "$R/src/lean.jsonl"); ag=$(wc -l < "$R/src/agda.jsonl"); nx=$(wc -l < "$R/src/nix.jsonl"); be=$(wc -l < "$R/src/bend.jsonl")
  per() { python3 -c "import sys; print(max(1, round(100 * $1 / $hs)))"; }
  # transcripts: about 20% of the bytes; code documents average ~7 KB, transcripts ~1.2 KB
  nix run .#deploy -- mix "$R/mix.jsonl" \
    "$R/src/haskell.jsonl:100" "$R/src/lean.jsonl:$(per $le)" "$R/src/agda.jsonl:$(per $ag)" "$R/src/nix.jsonl:$(per $nx)" "$R/src/bend.jsonl:$(per $be)" \
    "$R/src/tr-haskell.jsonl:41:cycle" "$R/src/tr-lean.jsonl:26:cycle" "$R/src/tr-agda.jsonl:28:cycle" \
    "$R/src/tr-nix.jsonl:13:cycle" "$R/src/tr-bend.jsonl:67:cycle"
  ls -la "$R/mix.jsonl"
}

# mixnew FILE...: each file's language from its name (haskell*, lean*, agda*,
# bend*), per round documents in proportion to each language's count so they run
# dry together, and fp100m's transcripts cycling at ~20% of the bytes as in mix
mixnew() {
  mkdir -p "$R/src"
  # fp100m's transcripts as JSONL, for the replay (as in mix)
  python3 - "$R/src" <<'PY'
import sys, json
out = sys.argv[1]
for l in ["haskell", "lean", "agda", "nix", "bend"]:
    d = open(f"run/transcripts-final/{l}/transcripts.train.nul", "rb").read().split(b"\0")
    with open(f"{out}/tr-{l}.jsonl", "w") as o:
        for i in range(0, len(d) - 1, 2):
            o.write(json.dumps({"id": d[i].decode("utf-8", "replace"), "text": d[i + 1].decode("utf-8", "replace")}, ensure_ascii=False) + "\n")
PY
  specs=$(python3 - "$R/src" "$@" <<'PY'
import sys, os, json
out, files = sys.argv[1], sys.argv[2:]
by = {}
for f in files:
    l = os.path.basename(f).split("-")[0].split(".")[0]
    by.setdefault(l, []).append(f)
stat = {}
for l, fs in by.items():
    n = b = 0
    for f in fs:
        for line in open(f, "rb"): n += 1; b += len(line)
    dst = f"{out}/{l}.jsonl"
    if os.path.lexists(dst): os.remove(dst)
    if len(fs) == 1: os.symlink(os.path.abspath(fs[0]), dst)   # no copy of a large file
    else:
        with open(dst, "wb") as o:
            for f in fs: o.write(open(f, "rb").read())
    stat[l] = (n, b)
top = max(stat, key=lambda l: stat[l][0])
per = {l: max(1, round(100 * n / stat[top][0])) for l, (n, b) in stat.items()}
code = sum(per[l] * stat[l][1] / stat[l][0] for l in stat)   # bytes of code a round
tr = 0.25 * code / 1200                                      # transcripts ~20% of all bytes, ~1.2 KB each
w = {"haskell": 79075, "lean": 50079, "agda": 53663, "nix": 24694, "bend": 126763}
specs = [f"{out}/{l}.jsonl:{per[l]}" for l in stat] + \
        [f"{out}/tr-{k}.jsonl:{max(1, round(tr * v / sum(w.values())))}:cycle" for k, v in w.items()]
print(" ".join(specs))
print({l: (n, round(b / 1e6, 1)) for l, (n, b) in stat.items()}, file=sys.stderr)
PY
)
  echo "per round: $specs"
  nix run .#deploy -- mix "$R/mix.jsonl" $specs
  ls -la "$R/mix.jsonl"
}

build() {
  k="${1:?usage: raw-stage.sh build K}"
  d="run/$P$k"; mkdir -p "$d"
  # slice k: the k-th SLICE bytes of the mix, cut at line ends
  python3 - "$R/mix.jsonl" "$d/slice.jsonl" "$k" "$SLICE" <<'PY'
import sys
src, dst, k, size = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
lo, hi = (k - 1) * size, k * size
pos = 0; lines = []
with open(src, "rb") as f:
    for line in f:
        if pos >= lo and pos < hi: lines.append(line)
        pos += len(line)
        if pos >= hi: break
    last = pos < hi  # the mix ran out inside this slice
# plan-corpus cuts a slice into 2000-document parts; the mix's final short
# part can be too small for one window (plan-segment refuses it), so the last
# slice keeps whole parts only
if last and len(lines) % 2000: lines = lines[:len(lines) - len(lines) % 2000]
with open(dst, "wb") as o: o.writelines(lines)
print("slice", k, len(lines), "documents", "(the last)" if last else "")
PY
  [ -s "$d/slice.jsonl" ] || { echo "slice $k is empty"; exit 1; }
  TOKENIZER=weights/code32k.bpe PACK_TARGET=131072 JOBS=${JOBS:-3} nix run .#deploy -- plan-corpus "$d/slice.jsonl" "$d" fp100m 16 2000
  cp "$d"/plan-fp100m-b16-s2000.tsv "$d/plan-fp100m-b16-windows.tsv"
  head -1 "$d/plan-fp100m-b16-windows.tsv" | cut -c1-160
  rm -f "$d/slice.jsonl"
}

push() {
  k="${1:?usage: raw-stage.sh push K HOST PORT}"
  NAME="$P$k" RUN="run/$P$k" EVALC=run/eval/transcript-next.corpus bend/gpu/next-stage.sh push "$2" "$3"
}

case "${1:-}" in
  mix) mix ;;
  mixnew) shift; mixnew "$@" ;;
  build) shift; build "$@" ;;
  push) shift; push "$@" ;;
  *) sed -n 2,20p "$0"; exit 2 ;;
esac
