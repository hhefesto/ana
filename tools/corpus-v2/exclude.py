# exclude.py IN OUT: copy a JSONL ({"id","text"} lines) or NUL (id\0text\0) stream less every
# record corpus v2 holds out (run/v2/holdout/: a held-out unit's repository/path, any version,
# or a held-out file's content anywhere); prints what it dropped and why.
# Transcript and unit ids (repo:x/path#decl@n) are matched by their file.
import sys, os, json
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from names import repo_of, path_of
from norm_hash import key
src, dst = sys.argv[1], sys.argv[2]
xp = set(open("run/v2/holdout/exclude.paths").read().splitlines())
xk = set(open("run/v2/holdout/exclude.sha256").read().splitlines())
xu = {l.split("\t")[0] for l in open("run/v2/holdout/units.tsv").read().splitlines()[1:]}
def drop(i, text, body_is_file):
    r = repo_of(i)
    p = path_of(i)
    if r in xu or f"{r}/{p.rsplit('/', 1)[0] if '/' in p else ''}" in xu or f"{r}/{p}" in xu: return "unit"
    if f"{r}\t{path_of(i)}" in xp: return "path"
    if body_is_file and key(text) in xk: return "content"
    return None
n = 0; why = {}
if src.endswith(".jsonl"):
    with open(src, encoding="utf-8") as f, open(dst, "w", encoding="utf-8") as o:
        for line in f:
            d = json.loads(line); w = drop(d["id"], d["text"], True)
            if w: why[w] = why.get(w, 0) + 1
            else: o.write(line); n += 1
else:
    d = open(src, "rb").read().split(b"\0")
    with open(dst, "wb") as o:
        for i in range(0, len(d) - 1, 2):
            ident = d[i].decode("utf-8", "replace")
            w = drop(ident, d[i + 1].decode("utf-8", "replace"), "#" not in ident)
            if w: why[w] = why.get(w, 0) + 1
            else: o.write(d[i] + b"\0" + d[i + 1] + b"\0"); n += 1
print(f"{src}: kept {n}, dropped {sum(why.values())} {why}")
