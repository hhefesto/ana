# Units of a repository's mutants/ files that are wrong on purpose (2026-10-28): gavel's
# references/T/mutants/*.bend and knot's tests/perch-performance/cases/C/mutants/*.bend are
# their authors' wrong programs (a law or a test is to catch each one), and they check, so
# the collection took them as code.  A unit of one is held out of the mix (mix6.sh held=)
# unless its def is, to the text, a def of a file beside the mutants/ directory (gavel's
# solution.bend; knot's clean/, baseline/, ...): then it is the right one under another name.
#
#   mutheld.py CLASS=SRC... < unit-ids > held.txt    (stdout `differs TAB id` / `same TAB id`
#                                                    with -v; the held lines alone without)
# CLASS=SRC[,SRC...]: the source trees of a class of ids, e.g. repo=run/v6/collect/src/bend,
# curated=run/v6/recheck-v2/src/curated,run/v6/collect/src/bend (the defs beside are those of
# every tree that has the directory: run 2's tree lacks some solution.bend files).  An id:
# CLASS:PATH#NAME@LINE.
import os, re, sys

def defs(path):
    try: t = open(path, encoding='utf-8', errors='replace').read().split('\n')
    except OSError: return {}
    out, cur = {}, None
    for l in t:
        m = re.match(r'(def|law|type) ([A-Za-z0-9_.]+)', l)
        if m: cur = m.group(2); out[cur] = [l]; continue
        if l and not l[0].isspace() and not l.startswith('#'): cur = None
        if cur: out[cur].append(l)
    return {k: '\n'.join(v).rstrip() for k, v in out.items()}

def beside(mutdir):
    up = os.path.dirname(mutdir); fs = []
    for root, ds, names in os.walk(up):
        ds[:] = [d for d in ds if os.path.join(root, d) != mutdir]
        fs += [os.path.join(root, n) for n in names if n.endswith('.bend')]
    return fs

verbose = '-v' in sys.argv
roots = dict(a.split('=', 1) for a in sys.argv[1:] if '=' in a)
cache, n, held = {}, 0, 0
for l in sys.stdin:
    uid = l.strip()
    if '/mutants/' not in uid or '#' not in uid: continue
    f, rest = uid.split('#', 1); name = rest.rsplit('@', 1)[0]
    cl, rel = f.split(':', 1)
    if cl not in roots: sys.exit('mutheld: no source tree for class ' + cl)
    trees = roots[cl].split(',')
    mut = os.path.join(trees[0], rel)
    md = os.path.dirname(rel)
    while os.path.basename(md) != 'mutants' and len(md) > 1: md = os.path.dirname(md)
    if (cl, md) not in cache:
        good = set()
        for t in trees:
            for g in beside(os.path.join(t, md)): good |= set(defs(g).items())
        cache[(cl, md)] = good
    a = defs(mut).get(name); n += 1
    same = a is not None and (name, a) in cache[(cl, md)]
    if not same: held += 1
    if verbose: print(('same' if same else 'differs') + '\t' + uid)
    elif not same: print(uid)
print('mutheld: %d units of mutants/ files, %d held (differ from every def beside)' % (n, held), file=sys.stderr)
