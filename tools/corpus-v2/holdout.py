# Corpus v2's holdout and exclusion list (docs/CORPUS-V2.md, C3).
#
# The holdout unit is a repository (folded name: run/v2/names.py), or, for a
# repository with more than BIG files, a file's own directory (its full parent
# path: Mathlib/RingTheory/Ideal, a nixpkgs package's directory), so a giant
# library (mathlib4, nixpkgs, agda-unimath) is never all in or all out and a
# module family stays together; a dataset of one-file records
# (hf:goedel-workbook ...) is split by record. A unit is held out when sha256("corpus-v2 holdout\0" + unit) mod 1000
# < 20 (2.0%): a rule, so a later source gets the same split. The vault
# (run/v2/holdout/vault.tsv) is held out whole.
#
# Writes run/v2/holdout/:
#   units.tsv        every held-out unit, its reason (split | vault-LANG), files, bytes
#   exclude.paths    repository<TAB>path of every file of a held-out unit, in any source, any version
#   exclude.sha256   the content key (run/raw-new/norm_hash.py) of each of those files
#   summary.txt      per language: held-out units, files and bytes against the whole
# run/v2/exclude.py filters any JSONL or NUL stream with them.
import sys, os, json, gzip, glob, hashlib, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from names import repo_of, path_of
from norm_hash import key
BIG = 300
EXT = {"hs": "haskell", "lhs": "haskell", "lean": "lean", "agda": "agda", "lagda": "agda", "md": "agda", "nix": "nix", "bend": "bend"}

def lang_of(path):
    p = path.lower()
    if p.endswith(".lagda.md"): return "agda"
    e = p.rsplit(".", 1)[-1] if "." in p else ""
    return EXT.get(e) if e != "md" else None

def jsonl(p):
    op = gzip.open if p.endswith(".gz") else open
    with op(p, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            try: d = json.loads(line)
            except ValueError: continue
            yield d["id"], d["text"]

def nul(p):
    d = open(p, "rb").read().split(b"\0")
    for i in range(0, len(d) - 1, 2): yield d[i].decode("utf-8", "replace"), d[i + 1].decode("utf-8", "replace")

# every source of code text (raw streams, pools, the vault, the transcripts' filler)
SOURCES = (["run/code-train-v3.jsonl"]
           + sorted(glob.glob("run/raw-new/*.jsonl"))
           + ["run/raw-new/work/pool/hf-ghcode.jsonl.gz"]
           + sorted(glob.glob("run/raw-new/.rawla/stage/lean/*.jsonl.gz"))
           + sorted(glob.glob("run/v2/vault/*.jsonl")))
FILLER = sorted(glob.glob("run/transcripts-*/*/files-*.nul"))

def all_files():
    for p in SOURCES:
        if os.path.exists(p):
            for i, t in jsonl(p): yield i, t
    for p in FILLER:
        if os.path.exists(os.path.realpath(p)):
            for i, t in nul(p): yield i, t

# pass 1: files per repository (distinct paths across every source)
paths = collections.defaultdict(set)
for i, _ in all_files():
    paths[repo_of(i)].add(path_of(i))
nfiles = {r: len(s) for r, s in paths.items()}
del paths

vault = {}
for l in open("run/v2/holdout/vault.tsv").read().splitlines()[1:]:
    lang, r, _ = l.split("\t"); vault[r] = lang

def unit_of(i):
    r, p = repo_of(i), path_of(i)
    if r.startswith("hf:"): return r + "/" + p
    if nfiles.get(r, 0) > BIG: return r + "/" + (p.rsplit("/", 1)[0] if "/" in p else "")
    return r

def held(u):
    return int(hashlib.sha256(("corpus-v2 holdout\0" + u).encode()).hexdigest()[:8], 16) % 1000 < 20

# pass 2: the held-out files, by path and by content
units = collections.defaultdict(lambda: [None, 0, 0])
tot = collections.defaultdict(lambda: [0, 0]); out = collections.defaultdict(lambda: [0, 0])
xpaths, xkeys, counted = set(), set(), set()
for i, t in all_files():
    r = repo_of(i); u = unit_of(i); lang = lang_of(path_of(i)) or "other"
    # counts once per repository/path (the vault's files sit in two sources); keys for every version
    fk = (r, path_of(i)); first = fk not in counted
    if first: counted.add(fk); tot[lang][0] += 1; tot[lang][1] += len(t)
    reason = f"vault-{vault[r]}" if r in vault else ("split" if held(u) else None)
    if reason is None: continue
    xpaths.add(f"{r}\t{path_of(i)}"); xkeys.add(key(t))
    if first:
        uu = r if r in vault else u
        units[uu][0] = reason; units[uu][1] += 1; units[uu][2] += len(t)
        out[lang][0] += 1; out[lang][1] += len(t)

os.makedirs("run/v2/holdout", exist_ok=True)
with open("run/v2/holdout/units.tsv", "w") as o:
    o.write("unit\treason\tfiles\tbytes\n")
    for u, (reason, n, b) in sorted(units.items()): o.write(f"{u}\t{reason}\t{n}\t{b}\n")
open("run/v2/holdout/exclude.paths", "w").write("".join(sorted(p + "\n" for p in xpaths)))
open("run/v2/holdout/exclude.sha256", "w").write("".join(sorted(k + "\n" for k in xkeys)))
with open("run/v2/holdout/summary.txt", "w") as o:
    o.write(f"held-out units: {sum(1 for v in units.values() if v[0] == 'split')} split, "
            f"{sum(1 for v in units.values() if v[0].startswith('vault'))} vault; {len(xpaths)} paths, {len(xkeys)} content keys\n")
    o.write("language   files held out / all     bytes held out / all\n")
    for lang in sorted(tot):
        o.write(f"{lang:9} {out[lang][0]:8d} / {tot[lang][0]:8d} ({out[lang][0] / max(1, tot[lang][0]):5.1%})   "
                f"{out[lang][1] / 1e6:8.1f} / {tot[lang][1] / 1e6:8.1f} MB\n")
print(open("run/v2/holdout/summary.txt").read())
