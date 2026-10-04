# the vault: up to 150 repositories per language that no training stream of run 1 holds
# (run/v2/holdout/stream-index.json), >= 3 files, chosen by sha256(name); their files go to
# run/v2/vault/LANG.jsonl and their names to run/v2/holdout/vault.tsv. Agda from mix 2's
# agda-2f.jsonl (not trained yet: it leaves mix 2), Lean from the undelivered pool, Haskell
# from the Haskell agent's leftover HF pool. Bend: no untrained source exists.
import sys, os, json, gzip, glob, hashlib, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from names import repo_of
idx = json.load(open("run/v2/holdout/stream-index.json"))
def trained(exclude):
    return set().union(*(set(v) for k, v in idx.items() if k not in exclude))
def records(paths):
    for p in paths:
        op = gzip.open if p.endswith(".gz") else open
        with op(p, "rt", encoding="utf-8") as f:
            for line in f: yield line
def pick(lang, paths, exclude):
    seen = trained(exclude)
    by = collections.defaultdict(list)
    for line in records(paths):
        d = json.loads(line); r = repo_of(d["id"])
        if r not in seen: by[r].append(line)
    cand = sorted((r for r, xs in by.items() if len(xs) >= 3), key=lambda r: hashlib.sha256(r.encode()).hexdigest())
    chosen = cand[:150]
    with open(f"run/v2/vault/{lang}.jsonl", "w") as o:
        for r in chosen: o.writelines(by[r])
    print(f"{lang}: {len(by)} untrained repositories, {len(cand)} with >= 3 files, {len(chosen)} chosen, "
          f"{sum(len(by[r]) for r in chosen)} files, {sum(len(l) for r in chosen for l in by[r]) / 1e6:.1f} MB")
    return [(lang, r, len(by[r])) for r in chosen]
rows = []
rows += pick("agda", ["run/raw-new/agda-2f.jsonl"], {"raw-new:agda-2f"})
rows += pick("lean", sorted(glob.glob("run/raw-new/.rawla/stage/lean/*.jsonl.gz")), set())
rows += pick("haskell", ["run/raw-new/work/pool/hf-ghcode.jsonl.gz"], set())
with open("run/v2/holdout/vault.tsv", "w") as o:
    o.write("lang\trepository\tfiles\n")
    for l, r, n in rows: o.write(f"{l}\t{r}\t{n}\n")
