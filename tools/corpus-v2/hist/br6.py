#!/usr/bin/env python3
# Bend code on the collected repositories' other branches and pull requests (2026-10-28; the user's
# goal 11388: the most Bend code).  The collection clones a repository's default branch at its pin;
# 133 of run 6's 298 GitHub repositories have other branches (4641 in all) and their pull requests'
# heads are 12383 refs more (`git ls-remote`, 10-28; bendlang/bend 1155, baton 312).  A probe:
# bendlang/bend's unmerged heads hold 1479 .bend blobs that no commit of the pin's history has.
#
#   br6.py PINS.tsv OUT HELD.jsonl...
#
# For each GitHub repository of PINS.tsv (OWNER/NAME TAB pin ...) none of whose files any HELD
# corpus (vault, holdout: every run's) has, a bare partial clone (commits and trees) with every
# branch and pull-request head (OUT/git/SLUG.git, kept: resumable, OUT/done.txt).  A head the pin
# has (merged, or behind) is skipped.  A head's .bend file whose blob no commit of the pin's history
# has, and no head taken before (branches first, then pull requests newest first), is taken, at
# most KP (BR_KP, 3) versions a path, never under mutants/ (wrong on purpose: gavel's, knot's).
# A taken file goes to OUT/tree/SLUG~KEY/PATH (KEY: b-BRANCH or pNUMBER) with the files it imports
# (relative `import ./x.bend`, `import "x.c"`, transitively, as the head has them), so it checks
# there as in its repository.  Output:
#   OUT/list.txt   SLUG~KEY/PATH, the taken files (the corpus's; their imports are only context)
#   OUT/sel.tsv    SLUG~KEY, PATH, blob, head commit, ref
#   OUT/stats.tsv  repo, heads, unmerged heads, taken files, context files
import sys, os, subprocess, re, json, time, shutil, collections
from concurrent.futures import ThreadPoolExecutor
import threading
LOCK = threading.Lock()

PINS, OUT, HELD = sys.argv[1], sys.argv[2], sys.argv[3:]
KP = int(os.environ.get('BR_KP', '3'))
JOBS = int(os.environ.get('BR_JOBS', '4'))
ONLY = set(os.environ.get('BR_ONLY', '').split())
# BR_FORKS=FILE (repo TAB fork ...: forks pushed since Bend 2, after their creation): the forks'
# branches instead (refs/f/OWNER/BRANCH, KEY f-OWNER-BRANCH), in the clones of BR_GIT (br6's), a
# blob of the pin's history or of a branch or pull-request head (br6's run took those) never taken
FORKS = os.environ.get('BR_FORKS')
GIT = os.environ.get('BR_GIT', OUT + '/git')
forks = collections.defaultdict(list)
if FORKS:
    for ln in open(FORKS):
        f = ln.rstrip('\n').split('\t')
        if len(f) >= 2: forks[f[0]].append(f[1])
env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='false')
os.makedirs(GIT, exist_ok=True); os.makedirs(OUT + '/tree', exist_ok=True)
log = open(OUT + '/br6.log', 'a')
def say(*a):
    print(time.strftime('%F %T'), *a, file=log, flush=True)
def git(d, *a, inp=None, timeout=1800):
    return subprocess.run(['git', '-C', d, *a], input=inp, capture_output=True, check=True, env=env, timeout=timeout).stdout

held = set()
for f in HELD:
    for l in open(f, 'rb'):
        i = json.loads(l)['id']
        held.add(i.split(':', 1)[1].split('/', 1)[0])
done = set(open(OUT + '/done.txt').read().split()) if os.path.exists(OUT + '/done.txt') else set()
pins = {}
for ln in open(PINS):
    f = ln.rstrip('\n').split('\t')
    if len(f) >= 2 and '/' in f[0] and not f[0].startswith('hub'): pins[f[0]] = f[1]   # the last row

def catfile(g, ids):
    out = git(g, 'cat-file', '--batch', inp=b'\n'.join(ids) + b'\n', timeout=3600)
    blobs, k = {}, 0
    while k < len(out):
        nl = out.index(b'\n', k); hd = out[k:nl].split()
        if len(hd) < 3 or hd[1] != b'blob': k = nl + 1; continue
        size = int(hd[2]); blobs[hd[0]] = out[nl + 1:nl + 1 + size]; k = nl + 1 + size + 1
    return blobs

def fetch(g, ids):
    if ids:
        git(g, '-c', 'fetch.negotiationAlgorithm=noop', 'fetch', '-q', 'origin', '--no-tags', '--no-write-fetch-head',
            '--filter=blob:none', '--stdin', inp=b'\n'.join(sorted(ids)) + b'\n', timeout=3600)

IMP = re.compile(rb'^\s*import\s+(?:"([^"]+)"|(\.\.?/\S+))', re.M)
def imports(path, text):
    d = os.path.dirname(path)
    for m in IMP.finditer(text):
        p = (m.group(1) or m.group(2)).decode('utf-8', 'replace')
        if p.startswith('/'): continue
        q = os.path.normpath(os.path.join(d, p))
        if not q.startswith('..'): yield q

def repo(name, pin):
    slug = name.replace('/', '__')
    g = GIT + '/' + slug + '.git'
    if not os.path.isdir(g + '/objects'):
        shutil.rmtree(g, ignore_errors=True)
        subprocess.run(['git', 'init', '-q', '--bare', g], check=True, capture_output=True)
        git(g, 'remote', 'add', 'origin', 'https://github.com/' + name)
        git(g, 'config', 'remote.origin.promisor', 'true'); git(g, 'config', 'remote.origin.partialclonefilter', 'blob:none')
        git(g, 'fetch', '-q', '--filter=blob:none', '--no-tags', 'origin', '+refs/heads/*:refs/b/*', '+refs/pull/*/head:refs/p/*')
    try: git(g, 'cat-file', '-e', pin + '^{commit}')
    except subprocess.CalledProcessError: git(g, 'fetch', '-q', '--filter=blob:none', '--no-tags', 'origin', pin)
    for fk in forks.get(name, []):
        try: git(g, 'fetch', '-q', '--filter=blob:none', '--no-tags', 'https://github.com/' + fk, '+refs/heads/*:refs/f/%s/*' % fk.split('/')[0])
        except Exception as e: say(name, 'fork', fk, 'fetch FAILED', type(e).__name__, str(e)[:120])
    have = set()
    for ln in git(g, 'ls-tree', '-r', pin).splitlines():
        meta, p = ln.split(b'\t', 1); have.add(meta.split()[2])
    for ln in git(g, 'log', '--raw', '--no-abbrev', '--no-renames', '--format=', pin, '--', '*.bend').splitlines():
        if ln.startswith(b':'):
            m = ln.split(b'\t', 1)[0].split(); have.add(m[2]); have.add(m[3])
    refs = []
    for ln in git(g, 'for-each-ref', '--format=%(objectname) %(refname)', 'refs/b', 'refs/p', 'refs/f').decode().splitlines():
        h, r = ln.split(' ', 1)
        if r.startswith('refs/f/'):
            if not FORKS: continue
            key, order = 'f-' + re.sub(r'[^A-Za-z0-9._-]', '_', r[7:].replace('/', '-', 1)), (2, 0)
        elif FORKS:   # br6's run took these heads' files: theirs are known
            for t in git(g, 'ls-tree', '-r', h).splitlines():
                mm = t.split(b'\t', 1)[0].split()
                if mm[1] == b'blob': have.add(mm[2])
            continue
        elif r.startswith('refs/b/'): key, order = 'b-' + re.sub(r'[^A-Za-z0-9._-]', '_', r[7:]), (0, 0)
        else: key, order = 'p' + r[7:], (1, -int(r[7:]))
        refs.append((order, key, h, r))
    refs.sort()
    taken, perpath, sel, ctx = set(), collections.Counter(), [], 0
    tips = {}
    for _, key, h, r in refs:
        if h in tips: continue
        tips[h] = key
        if subprocess.run(['git', '-C', g, 'merge-base', '--is-ancestor', h, pin], env=env, capture_output=True).returncode == 0: continue
        tree = {}
        for ln in git(g, 'ls-tree', '-r', h).splitlines():
            meta, p = ln.split(b'\t', 1); mm = meta.split()
            if mm[1] == b'blob': tree[p.decode('utf-8', 'replace')] = mm[2]
        new = []
        for p, b in sorted(tree.items()):
            if not p.endswith('.bend') or '/mutants/' in '/' + p or b in have or b in taken or perpath[p] >= KP: continue
            taken.add(b); perpath[p] += 1; new.append(p)
        if new: sel.append((key, h, r, tree, new))
    nunm = len([1 for x in sel])
    # the taken files' blobs, then their imports' (as each head has them), to a fixpoint
    texts = {}
    todo = [(s, p) for s in sel for p in s[4]]
    files = collections.defaultdict(set)   # key -> paths to write
    rounds = 0
    while todo and rounds < 12:
        rounds += 1
        ids = {s[3][p] for s, p in todo if p in s[3] and s[3][p] not in texts}
        fetch(g, ids)
        texts.update(catfile(g, sorted(ids)))
        nxt = []
        for s, p in todo:
            if p not in s[3] or p in files[s[0]]: continue
            files[s[0]].add(p)
            t = texts.get(s[3][p], b'')
            for q in imports(p, t):
                if q in s[3] and q not in files[s[0]]: nxt.append((s, q))
        todo = nxt
    nt = 0; ls, ss = [], []
    for key, h, r, tree, new in sel:
        d = OUT + '/tree/' + slug + '~' + key
        for p in sorted(files[key]):
            b = tree[p]
            if b not in texts: continue
            os.makedirs(os.path.dirname(d + '/' + p), exist_ok=True)
            with open(d + '/' + p, 'wb') as o: o.write(texts[b])
            if p not in new: ctx += 1
        for p in new:
            if tree[p] in texts:
                ls.append('%s~%s/%s\n' % (slug, key, p)); nt += 1
                ss.append('\t'.join((slug + '~' + key, p, tree[p].decode(), h, r)) + '\n')
    with LOCK:
        with open(OUT + '/list.txt.part', 'a') as L: L.writelines(ls)
        with open(OUT + '/sel.tsv.part', 'a') as S: S.writelines(ss)
        with open(OUT + '/stats.tsv', 'a') as s:
            s.write('%s\t%d\t%d\t%d\t%d\n' % (name, len(tips), nunm, nt, ctx))
    return len(tips), nunm, nt, ctx

def one(name):
    t0 = time.time()
    try:
        r = repo(name, pins[name])
        say(name, 'heads %d with-new %d taken %d context %d' % r, '%.0fs' % (time.time() - t0))
    except Exception as e:
        say(name, 'FAILED', type(e).__name__, str(e)[:300])
    with LOCK:
        with open(OUT + '/done.txt', 'a') as d: d.write(name + '\n')

names = [n for n in sorted(pins) if n not in done and n.replace('/', '__') not in held and (not ONLY or n in ONLY) and (not FORKS or n in forks)]
skipped = [n for n in pins if n.replace('/', '__') in held]
say('repos %d to do, %d held (vault/holdout) skipped' % (len(names), len(skipped)))
with ThreadPoolExecutor(JOBS) as ex:
    list(ex.map(one, names))
for x in ('list.txt', 'sel.tsv'):
    if os.path.exists(OUT + '/' + x + '.part'): os.replace(OUT + '/' + x + '.part', OUT + '/' + x)
say('ALL DONE')
