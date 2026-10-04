# combine.py RAW_SHARE OUT T_DIR R_DIR... [--steps N]: corpus v2's one mix (docs/CORPUS-V2.md, C5)
# as one run directory and plan: the transcript windows' shards (T_DIR, windows.sh's) and the
# raw shards (each R_DIR, rawshards.sh's) interleaved in their own orders, the next shard
# always raw while raw's training windows are under RAW_SHARE of all so far, ending where
# the transcripts end (or at N global steps: a pilot's own short plan, so its learning-rate
# schedule runs out with it). The shards are hard links, OUT/shard-K-fp100m.corpus, each
# planned again at its document offset in the new order (bend-plan-segment: the trainer
# draws validation documents by global index), then OUT/plan-fp100m-b16-windows.tsv in
# master's format (`plan 1 STEPS IDENTITY ...`, a `segment` line a shard).
import sys, os, hashlib, subprocess, concurrent.futures

args = sys.argv[1:]
steps_cap = None
if "--steps" in args:
    j = args.index("--steps"); steps_cap = int(args[j + 1]); del args[j:j + 2]
share, out, tdir, rdirs = float(args[0]), args[1], args[2], args[3:]
PS = "run/v2/gcroot-bend-plan-segment/bin/bend-plan-segment"
TOK = "weights/code32k.bpe"

def segments(d):
    plan = next(os.path.join(d, f) for f in ["plan-fp100m-b16-windows.tsv", "plan-fp100m-b16-s2000.tsv"] if os.path.exists(os.path.join(d, f)))
    for l in open(plan):
        w = l.split()
        if w and w[0] == "segment":   # segment K OFFSET DOCS ID TW VW STEPS START END
            yield {"src": os.path.join(d, f"shard-{w[1]}-fp100m.corpus"), "docs": int(w[3]), "tw": int(w[5])}

T = list(segments(tdir)); R = [s for d in rdirs for s in segments(d)]
order = []; ct = cr = 0; ti = ri = 0; est = 0
while ti < len(T):
    if ri < len(R) and cr < share * (ct + cr + 1):
        s = R[ri]; ri += 1; cr += s["tw"]; s["kind"] = "raw"
    else:
        s = T[ti]; ti += 1; ct += s["tw"]; s["kind"] = "transcripts"
    order.append(s); est += -(-s["tw"] // 16)
    if steps_cap and est >= steps_cap: break
if ri >= len(R) and ti < len(T) and not steps_cap:
    print(f"warning: raw ran out after {ri} shards; the rest is transcripts only", file=sys.stderr)

os.makedirs(out, exist_ok=True)
off = 0
for k, s in enumerate(order):
    s["k"], s["off"] = k, off; off += s["docs"]
    dst = os.path.join(out, f"shard-{k}-fp100m.corpus")
    if os.path.lexists(dst): os.remove(dst)
    os.link(s["src"], dst)

def plan_one(s):
    r = subprocess.run([PS, "--threads", "1", os.path.join(out, f"shard-{s['k']}-fp100m.corpus"), str(s["off"]), "16", "fp100m"],
                       capture_output=True, text=True)
    if r.returncode != 0: raise SystemExit(f"plan-segment failed on shard {s['k']}: {r.stderr[-300:]}")
    return r.stdout.split()   # segment OFFSET DOCS DATASET TW VW STEPS

with concurrent.futures.ThreadPoolExecutor(8) as ex: lines = list(ex.map(plan_one, order))
segs = []; cum = 0; tw = {"raw": 0, "transcripts": 0}
for s, w in zip(order, lines):
    st = int(w[6]); segs.append(f"segment {s['k']} {w[1]} {w[2]} {w[3]} {w[4]} {w[5]} {w[6]} {cum} {cum + st}")
    cum += st; tw[s["kind"]] += int(w[4])
ht = hashlib.sha256(open(TOK, "rb").read()).hexdigest()
hm = hashlib.sha256("\n".join(segs).encode()).hexdigest()
ident = f"mixed-v2:sha256={hm}:raw={share}:windows={tw['raw'] + tw['transcripts']}:batch=16:size=fp100m:tokenizer={ht}"
with open(os.path.join(out, "plan-fp100m-b16-windows.tsv"), "w") as o:
    o.write(f"plan 1 {cum} {ident} {hm} {off} {len(order)} 16 fp100m {ht}\n" + "\n".join(segs) + "\n")
with open(os.path.join(out, "order.tsv"), "w") as o:
    for s in order: o.write(f"{s['k']}\t{s['kind']}\t{s['src']}\n")
raw_frac = tw["raw"] / max(1, tw["raw"] + tw["transcripts"])
print(f"{out}: {len(order)} shards ({sum(s['kind'] == 'raw' for s in order)} raw), {cum} steps, "
      f"training windows: transcripts {tw['transcripts']}, raw {tw['raw']} ({raw_frac:.1%})")
