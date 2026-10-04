# evalrun.py: E1 (direct pass@1) and E2 (repair@1) of one checkpoint on evalset.py's prompts
# (docs/CORPUS-V2.md), greedy, on the CPU (bend-generate), each answer checked by the real
# checker in its held-out unit, as the corpus was built (bend-check):
#   evalrun.py gen CKPT DIR FORMAT [K]   answers into DIR/results.json: TOKENS (100) tokens,
#                                        PROCS (3) generators of THREADS (5) threads; FORMAT 1
#                                        asks repairs in format 1 (run 1), 2 in format 2;
#                                        K: the first K prompts of each language and shape
#   evalrun.py check DIR                 ana's Term (up to its closing fence) lifted into the
#                                        unit (the transcript shows the body dedented: the
#                                        change that maps the reference to the stored body
#                                        maps ana's term), bend-check per language (Bend per
#                                        source tree, BEND_SRC), then DIR/report.txt
import sys, os, json, subprocess, time, glob, collections, concurrent.futures
G = "run/gcroot-bend-generate/bin/bend-generate"
LANGS = ["haskell", "agda", "lean", "nix", "bend"]

def gen(ckpt, d, fmt, k):
    ps = json.load(open("run/v2/evalset/prompts.json"))
    if k:
        n = collections.Counter(); keep = []
        for p in ps:
            if n[(p["lang"], p["shape"])] < k: keep.append(p); n[(p["lang"], p["shape"])] += 1
        ps = keep
    os.makedirs(d, exist_ok=True)
    def one(p):
        q = p["prompt1"] if fmt == "1" and "prompt1" in p else p["prompt"]
        env = dict(os.environ, CKPT=ckpt, PROMPT=q, TOKENS=os.environ.get("TOKENS", "100"), TEMPERATURE="0", TOKENIZER_FILE="weights/code32k.bpe")
        t = time.time()
        r = subprocess.run([G, "--threads", os.environ.get("THREADS", "5")], env=env, capture_output=True, text=True)
        i = r.stdout.find(q); g = r.stdout[i + len(q):] if i >= 0 else ""
        j = g.find("```")
        return dict(p, asked=q, raw=r.stdout, term=g[:j] if j >= 0 else g, closed=j >= 0, secs=round(time.time() - t, 1))
    out = []
    with concurrent.futures.ThreadPoolExecutor(int(os.environ.get("PROCS", "3"))) as ex:
        for r in ex.map(one, ps):
            out.append(r); json.dump(out, open(f"{d}/results.json", "w"), indent=1, ensure_ascii=False)
            print(len(out), r["lang"], r["shape"], r["secs"], "s", flush=True)

def lift(ref, body, term):
    if ref == body: return term
    lead = body[:len(body) - len(body.lstrip(" "))]
    ind = lambda t: "".join((lead + l if l.strip() else l) for l in t.splitlines(True))
    if ind(ref) == body: return ind(term)       # every line indented (Agda, Bend) wins, as for a one-line reference
    if lead + ref == body: return lead + term   # the first line only (Lean's " by")
    if ref.strip() == body.strip(): return body.replace(body.strip(), term.strip())
    return None

def bend_src(uid):
    cls, rest = uid.split(":", 1); repo = rest.split("/", 1)[0]
    for root in sorted(glob.glob("run/code-sources*/")):
        if os.path.isdir(os.path.join(root, cls, repo)): return os.path.join(root, cls)
    return os.path.expanduser("~/src")

def check(d):
    ps = json.load(open(f"{d}/results.json"))
    rec = {}
    for l in LANGS:
        x = open(f"run/v2/results/{l}.holdout.nul", "rb").read().split(b"\0")
        for i in range(0, len(x) - 1, 2): rec[x[i].decode("utf-8", "replace")] = x[i + 1]
    groups = collections.defaultdict(list)
    for n, p in enumerate(ps):
        f = rec[p["id"]].split(b"\x1e"); body = f[7].decode("utf-8", "replace")
        t = lift(p["ref"], body, p["term"]); p["lifted"] = t is not None
        if t is None: continue
        g = p["lang"] if p["lang"] != "bend" else "bend=" + bend_src(p["id"])
        # one unit a prompt: the id carries the prompt's number (a unit can be asked twice)
        groups[g].append((f"{p['id']}~{n}", b"\x1e".join(f[:7] + [t.encode()] + f[8:10] + [b""])))
    verdict = {}
    for g, us in groups.items():
        lang, _, src = g.partition("=")
        name = lang if not src else "bend-" + str(abs(hash(src)) % 10**6)
        with open(f"{d}/ans.{name}.nul", "wb") as o:
            for i, u in us: o.write(i.encode() + b"\0" + u + b"\0")
        env = dict(os.environ, **({"BEND_SRC": src} if src else {}), KEEP_WORK="")
        subprocess.run(["nix", "run", ".#deploy", "--", "check", lang, f"{d}/ans.{name}.nul", f"{d}/r.{name}.nul", "4"],
                       env=env, stdout=open(f"{d}/log.{name}", "w"), stderr=subprocess.STDOUT, timeout=3600)
        x = open(f"{d}/r.{name}.nul", "rb").read().split(b"\0")
        for i in range(0, len(x) - 1, 2):
            verdict[x[i].decode("utf-8", "replace")] = x[i + 1].split(b"\x1e")[11].split(b"\x1f")[0].decode()
    tab = collections.defaultdict(collections.Counter)
    lines = []
    for n, p in enumerate(ps):
        v = verdict.get(f"{p['id']}~{n}")   # bend-check keeps only the units whose original passes
        p["pass"] = v == "0"
        c = tab[(p["lang"], p["shape"])]; c["n"] += 1; c["pass"] += p["pass"]; c["lifted"] += p["lifted"]; c["closed"] += p["closed"]
        lines.append(f"{'PASS' if p['pass'] else 'fail'} {p['lang']:7} {p['shape']:6} {p['id'][:100]}")
    head = [f"{l:7} {s:6} pass {c['pass']:3d}/{c['n']:3d}   closed {c['closed']:3d}   lifted {c['lifted']:3d}" for (l, s), c in sorted(tab.items())]
    tot = sum(c["pass"] for c in tab.values()), sum(c["n"] for c in tab.values())
    open(f"{d}/report.txt", "w").write("\n".join(head + [f"all pass {tot[0]}/{tot[1]}", ""] + lines) + "\n")
    json.dump(ps, open(f"{d}/results.json", "w"), indent=1, ensure_ascii=False)
    print("\n".join(head + [f"all pass {tot[0]}/{tot[1]}"]))

if __name__ == "__main__":
    if sys.argv[1] == "gen": gen(sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5]) if len(sys.argv) > 5 else 0)
    elif sys.argv[1] == "check": check(sys.argv[2])
    else: sys.exit("usage: evalrun.py gen CKPT DIR FORMAT [K] | check DIR")
