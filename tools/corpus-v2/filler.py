# filler.py: the filler of corpus v2's transcript windows (docs/CORPUS-V2.md, C4):
# the source files run 1's units were cut from (files-{hi,lo}.nul of every wave it
# trained: final, next, w1-w4), each file once (run 1 copied Bend's three times
# more, `#cN`), less every held-out file (by unit, path or content, as exclude.py),
# next to format 2's transcripts so bend-plan-windows finds them:
#   run/v2/transcripts/LANG/files-{hi,lo}.nul    (a file in both: hi)
#   run/v2/transcripts/LANG/results.holdout.nul  (pool.py's holdout: plan-windows
#                                                 drops its files from the filler too)
# and run/v2/transcripts/filler.keys, the content key of every filler file (raw.py
# leaves them out of the raw stream, so no file is both).
import sys, os, re, shutil, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from names import repo_of, path_of
from norm_hash import key

WAVES = ["run/transcripts-final", "run/transcripts-next", "run/transcripts-w1", "run/transcripts-w2", "run/transcripts-w3", "run/transcripts-w4"]
LANGS = ["haskell", "agda", "lean", "nix", "bend"]
O = "run/v2/transcripts"
xp = set(open("run/v2/holdout/exclude.paths").read().splitlines())
xk = set(open("run/v2/holdout/exclude.sha256").read().splitlines())
xu = {l.split("\t")[0] for l in open("run/v2/holdout/units.tsv").read().splitlines()[1:]}

def held(i, k):
    r, p = repo_of(i), path_of(i)
    return (r in xu or f"{r}/{p.rsplit('/', 1)[0] if '/' in p else ''}" in xu or f"{r}/{p}" in xu
            or f"{r}\t{p}" in xp or k in xk)

def pairs(p):
    d = open(p, "rb").read().split(b"\0")
    for i in range(0, len(d) - 1, 2): yield d[i], d[i + 1]

keys = set(); out = []
for l in LANGS:
    os.makedirs(f"{O}/{l}", exist_ok=True)
    st = collections.Counter(); seen = set()
    for tier in ["hi", "lo"]:
        with open(f"{O}/{l}/files-{tier}.nul", "wb") as o:
            for w in WAVES:
                p = f"{w}/{l}/files-{tier}.nul"
                if not os.path.exists(p) or os.path.getsize(p) == 0: continue
                for i, t in pairs(p):
                    s = re.sub(r"#c\d+$", "", i.decode("utf-8", "replace"))
                    k = key(t.decode("utf-8", "replace"))
                    if k in seen: st["copy"] += 1; continue
                    seen.add(k)
                    if held(s, k): st["held out"] += 1; continue
                    o.write(s.encode() + b"\0" + t + b"\0"); st[tier] += 1; keys.add(k)
    shutil.copyfile(f"run/v2/results/{l}.holdout.nul", f"{O}/{l}/results.holdout.nul")
    out.append(f"{l:8} hi {st['hi']:6d}  lo {st['lo']:6d}  copies dropped {st['copy']:6d}  held out {st['held out']:5d}")
open(f"{O}/filler.keys", "w").write("".join(sorted(k + "\n" for k in keys)))
print("\n".join(out))
