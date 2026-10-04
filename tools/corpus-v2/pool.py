# pool.py: the checked units of run 1, one set per language, split by corpus v2's
# holdout (docs/CORPUS-V2.md, C3): the same data, for bend-transcript's format 2.
#
# The units are those run 1's transcripts came from (train and holdout of every
# wave it trained: final, next, w1-w4); each unit's record (bend-check's
# RESULTS.nul fields) is taken from whichever wave's results.{train,holdout}.nul
# holds it. A unit whose declaration (language, signature, body) another unit
# already gave is dropped. A unit of a held-out repository or directory
# (exclude.py's rule, by the unit's file) goes to the holdout, the rest to train.
#
# Writes run/v2/results/LANG.{train,holdout}.nul and run/v2/results/summary.txt.
import sys, os, glob, hashlib, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from names import repo_of, path_of

WAVES = ["run/transcripts-final", "run/transcripts-next", "run/transcripts-w1", "run/transcripts-w2", "run/transcripts-w3", "run/transcripts-w4"]
LANGS = ["haskell", "agda", "lean", "nix", "bend"]
OUT = "run/v2/results"

def pairs(p):
    d = open(p, "rb").read().split(b"\0")
    for i in range(0, len(d) - 1, 2): yield d[i], d[i + 1]

def unit_id(tid):
    # a transcript id: UNIT/SHAPE, or UNIT+/repair for a unit's second
    return tid.rsplit(b"/", 1)[0].rstrip(b"+")

# 1. the units run 1 was given (trained or held out), by language
want = {l: set() for l in LANGS}
for w in WAVES:
    for l in LANGS:
        for part in ["train", "holdout"]:
            p = f"{w}/{l}/transcripts.{part}.nul"
            if os.path.exists(p):
                for t, _ in pairs(p): want[l].add(unit_id(t))

# 2. their records, from every wave's checked and cleaned results
rec = {}
for p in sorted(glob.glob("run/transcripts*/*/results.train.nul") + glob.glob("run/transcripts*/*/results.holdout.nul")):
    for i, r in pairs(p):
        if i not in rec: rec[i] = r

# 3. one unit a declaration, split by the v2 holdout
xp = set(open("run/v2/holdout/exclude.paths").read().splitlines())
xu = {l.split("\t")[0] for l in open("run/v2/holdout/units.tsv").read().splitlines()[1:]}
def held(i):
    r, p = repo_of(i), path_of(i)
    return r in xu or f"{r}/{p.rsplit('/', 1)[0] if '/' in p else ''}" in xu or f"{r}/{p}" in xu or f"{r}\t{p}" in xp

os.makedirs(OUT, exist_ok=True)
summary = []
for l in LANGS:
    seen = set(); st = collections.Counter()
    with open(f"{OUT}/{l}.train.nul", "wb") as tr, open(f"{OUT}/{l}.holdout.nul", "wb") as ho:
        for i in sorted(want[l]):
            r = rec.get(i)
            if r is None: st["no record"] += 1; continue
            fs = r.split(b"\x1e")
            k = hashlib.sha256(fs[0] + b"\0" + fs[4] + b"\0" + fs[7]).digest()
            if k in seen: st["duplicate"] += 1; continue
            seen.add(k)
            s = i.decode("utf-8", "replace")
            if held(s): ho.write(i + b"\0" + r + b"\0"); st["holdout"] += 1
            else: tr.write(i + b"\0" + r + b"\0"); st["train"] += 1
    summary.append(f"{l:8} units {len(want[l]):6d}: train {st['train']:6d}, holdout {st['holdout']:5d}, duplicate {st['duplicate']:5d}, no record {st['no record']:4d}")
open(f"{OUT}/summary.txt", "w").write("\n".join(summary) + "\n")
print("\n".join(summary))
