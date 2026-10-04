# evalset.py [N_DIRECT] [N_REPAIR]: corpus v2's generation prompts (docs/CORPUS-V2.md, E1, E2)
# from the repository holdout, cut from render.sh's held-out format 2 transcripts:
#   direct  the transcript up to its Term's fence: the answer is ana's whole Term (E1). The
#           direct shape is the same text in format 1, so run 1 and run 2 get one prompt.
#   repair  up to the Term after the given Attempt and the checker's error (E2); `prompt1` is
#           format 1's version for run 1 (the ask alone, the mutant under `## Term`).
# Up to N_DIRECT (40) direct and N_REPAIR (20) repair prompts a language (Nix: repair only,
# 2 x N_REPAIR), one per unit, units in hash order. Each prompt carries the unit's id and
# reference Term. Writes run/v2/evalset/prompts.json. The control (every reference answered,
# `evalrun.py check` on it: 275/280 passed on 2026-10-04) then drops the prompts whose own
# reference fails the harness (run/v2/evalset/dropped-by-control.txt: 5 Bend units whose file's
# version is in no source tree).
import sys, os, json, hashlib, collections
LANGS = ["haskell", "agda", "lean", "nix", "bend"]
nd = int(sys.argv[1]) if len(sys.argv) > 1 else 40
nr = int(sys.argv[2]) if len(sys.argv) > 2 else 20
FIX = "\n\nThis attempt fails. Fix it."

def pairs(p):
    d = open(p, "rb").read().split(b"\0")
    for i in range(0, len(d) - 1, 2): yield d[i].decode("utf-8", "replace"), d[i + 1].decode("utf-8", "replace")

out = []
for l in LANGS:
    fence = f"## Term\n\n```{l}\n"
    by = collections.defaultdict(dict)
    for tid, text in pairs(f"run/v2/transcripts/{l}/transcripts.holdout.nul"):
        base, shape = tid.rsplit("/", 1)
        unit = base.rsplit("+", 1)[0] if "+" in base.rsplit("#", 1)[-1] else base
        by[unit].setdefault(shape, text)
    units = sorted(by, key=lambda u: hashlib.sha256(("corpus-v2 evalset\0" + u).encode()).hexdigest())
    want = {"direct": 0 if l == "nix" else nd, "repair": 2 * nr if l == "nix" else nr}
    got = collections.Counter(); used = set()
    for shape in ["direct", "repair"]:
        for u in units:
            if got[shape] >= want[shape] or u in used or shape not in by[u]: continue
            t = by[u][shape]; k = t.rfind(fence)
            if k < 0: continue
            prompt = t[:k + len(fence)]; ref = t[k + len(fence):].split("\n```", 1)[0] + "\n"
            p = {"lang": l, "id": u, "shape": shape, "prompt": prompt, "ref": ref}
            if shape == "repair":
                p["prompt1"] = prompt.replace(FIX, "", 1).replace("## Attempt\n\n", "## Term\n\n", 1)
            out.append(p); got[shape] += 1; used.add(u)
    print(l, dict(got))
os.makedirs("run/v2/evalset", exist_ok=True)
json.dump(out, open("run/v2/evalset/prompts.json", "w"), indent=1, ensure_ascii=False)
print(len(out), "prompts")
