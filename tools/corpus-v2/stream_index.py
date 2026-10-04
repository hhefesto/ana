# every repository any training stream of run 1 holds (folded names), per stream
import sys, json, glob, os, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from names import repo_of
def jsonl_ids(p):
    with open(p, "rb") as f:
        for line in f:
            i = line.find(b'"id":'); i = line.find(b'"', i + 5) + 1; j = line.find(b'"', i)
            yield line[i:j].decode("utf-8", "replace")
def nul_ids(p):
    d = open(p, "rb").read().split(b"\0")
    for i in range(0, len(d) - 1, 2): yield d[i].decode("utf-8", "replace")
streams = {"code-train-v3": ("jsonl", ["run/code-train-v3.jsonl"])}
for f in ["haskell", "haskell-2", "lean", "agda-f", "bend", "lean-2", "agda-2f"]:
    streams[f"raw-new:{f}"] = ("jsonl", [f"run/raw-new/{f}.jsonl"])
for w in ["transcripts-final", "transcripts-next", "transcripts-w1", "transcripts-w2", "transcripts-w3", "transcripts-w4"]:
    streams[w] = ("nul", sorted(glob.glob(f"run/{w}/*/transcripts.*.nul") + glob.glob(f"run/{w}/*/files-*.nul")))
idx = {}
for name, (kind, files) in streams.items():
    s = set()
    for p in files:
        if not os.path.exists(p) or os.path.islink(p) and not os.path.exists(os.path.realpath(p)): continue
        for i in (jsonl_ids(p) if kind == "jsonl" else nul_ids(p)): s.add(repo_of(i))
    idx[name] = sorted(s)
    print(f"{name:24} {len(s):7d} repositories")
json.dump(idx, open("run/v2/holdout/stream-index.json", "w"))
