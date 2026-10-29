#!/usr/bin/env python3
# BendHub's version histories as git histories (2026-10-28; the user's goal: the most Bend code,
# error-then-fix cases included).  A hub package has no git history, but its name's older
# versions are on the hub: an older version's body of a def that today's Bend rejects is a real
# past error, and the pinned version's body its fix, as for a repository's older commits.
#
#   hubhist.py SRC OUTDIR CORPUS.jsonl...
#
# SRC: a collection's tree (run/v6/collect/src/bend: .hub/packages-*.json, the hub's listing as
# collect read it; HUB.tsv, the pinned packages; hub__NAME, a pinned package's files).  For each
# named package with a file in a CORPUS (`repo:hub__NAME/PATH` ids) and versions published before
# its pinned one: OUTDIR/repos/NAME, a git repository with a commit per version, oldest first (its
# .bend files from URL/0xHASH/PATH, checked against its manifest, which must hash to the hash), the
# pinned version's files (SRC/hub__NAME, the corpus's texts) last.  OUTDIR/LOCAL.tsv: `repo:hub__NAME
# TAB OUTDIR/repos/NAME`, for hist6.py (HIST_LOCAL=1 HIST_HUB=1).  A version that fails to fetch is
# logged and left out.
import sys, os, json, glob, hashlib, subprocess, shutil, collections, time, re
from concurrent.futures import ThreadPoolExecutor

SRC, OUT, CORPORA = sys.argv[1], sys.argv[2], sys.argv[3:]
URL = os.environ.get('HUB_URL', 'https://hub.bend-lang.com')
JOBS = int(os.environ.get('HUB_JOBS', '8'))
SAFE = re.compile(r'^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$')
def say(*a): print(time.strftime('[%F %T]'), *a, flush=True)

def curl(url):
    r = subprocess.run(['curl', '-fsS', '--retry', '3', '--retry-delay', '2', '--connect-timeout', '30',
                        '--max-time', '120', url], capture_output=True, timeout=600)
    if r.returncode != 0: raise RuntimeError('curl %s: %s' % (url, r.stderr.decode('utf-8', 'replace')[:200]))
    return r.stdout

pk = []
for f in sorted(glob.glob(SRC + '/.hub/packages-*.json')):
    d = json.load(open(f))
    pk += d['packages'] if isinstance(d, dict) else d
pins = {}
for l in open(SRC + '/HUB.tsv'):
    f = l.rstrip('\n').split('\t')
    if len(f) >= 3: pins[f[0]] = f[2]
want = collections.Counter()
for c in CORPORA:
    for ln in open(c, 'rb'):
        i = json.loads(ln)['id']
        if i.startswith('repo:hub__') and not i.startswith('repo:hub__0x'):
            want[i.split('/', 1)[0][len('repo:hub__'):]] += 1
by = collections.defaultdict(list)
for p in pk:
    if p.get('name'): by[p['name']].append(p)

def version(p):
    """an older version's .bend files {path: bytes} (None: it failed)"""
    h = p['hash']
    try:
        man = curl('%s/%s/manifest' % (URL, h))
        if not (re.fullmatch(r'0x[0-9a-f]{32}', h) and hashlib.sha256(man).hexdigest().startswith(h[2:])):
            say('  %s@%s: the manifest does not hash to %s' % (p['name'], p.get('version'), h)); return None
        fs = {}
        for ln in man.decode().splitlines():
            s, _, path = ln.partition(' ')
            if not SAFE.match(path) or any(x in ('.', '..') for x in path.split('/')):
                say('  %s: a manifest path is not plain: %r' % (h, path)); return None
            if not path.endswith('.bend'): continue
            b = curl('%s/%s/%s' % (URL, h, path))
            if hashlib.sha256(b).hexdigest() != s:
                say('  %s: %s does not hash to its manifest line' % (h, path)); return None
            fs[path] = b
        return fs
    except Exception as e:
        say('  %s@%s (%s): FAILED %s' % (p['name'], p.get('version'), h, str(e)[:200])); return None

os.makedirs(OUT + '/repos', exist_ok=True)
local = open(OUT + '/LOCAL.tsv', 'w')
env0 = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_AUTHOR_NAME='hub', GIT_AUTHOR_EMAIL='hub@hub.bend-lang.com',
            GIT_COMMITTER_NAME='hub', GIT_COMMITTER_EMAIL='hub@hub.bend-lang.com')
npk = nver = 0
for n in sorted(want):
    ph = pins.get('hub__' + n)
    vs = by.get(n, [])
    pt = [p['ts'] for p in vs if p['hash'] == ph]
    if not pt: say(n, 'no pinned version in the listing'); continue
    old = sorted([p for p in vs if p['ts'] < pt[0]], key=lambda p: p['ts'])
    if not old: continue
    g = os.path.join(OUT, 'repos', n)
    assert os.path.abspath(g).startswith(os.path.abspath(OUT + '/repos') + '/')
    if os.path.isdir(g + '/.git') and os.path.exists(g + '/.done'):
        local.write('repo:hub__%s\t%s\n' % (n, os.path.abspath(g))); continue
    shutil.rmtree(g, ignore_errors=True); os.makedirs(g)
    with ThreadPoolExecutor(JOBS) as ex:
        got = list(ex.map(version, old))
    pin = {}
    pd = os.path.join(SRC, 'hub__' + n)
    for root, _, files in os.walk(pd):
        for f in files:
            if f.endswith('.bend'):
                q = os.path.join(root, f); pin[os.path.relpath(q, pd)] = open(q, 'rb').read()
    subprocess.run(['git', 'init', '-q', g], check=True, env=env0)
    k = 0
    for p, fs in list(zip(old, got)) + [(dict(hash=ph, ts=pt[0], version='pinned'), pin)]:
        if fs is None: continue
        for x in os.listdir(g):
            if x != '.git': shutil.rmtree(os.path.join(g, x)) if os.path.isdir(os.path.join(g, x)) else os.remove(os.path.join(g, x))
        for path, b in fs.items():
            q = os.path.join(g, path); os.makedirs(os.path.dirname(q), exist_ok=True); open(q, 'wb').write(b)
        t = '%d +0000' % (p['ts'] // 1000)
        env = dict(env0, GIT_AUTHOR_DATE=t, GIT_COMMITTER_DATE=t)
        subprocess.run(['git', '-C', g, 'add', '-A'], check=True, env=env)
        subprocess.run(['git', '-C', g, 'commit', '-q', '--allow-empty', '-m', '%s@%s %s' % (n, p.get('version'), p['hash'])], check=True, env=env)
        k += 1
    open(g + '/.done', 'w').write('%d\n' % k)
    say(n, 'versions', len(old), 'fetched', sum(1 for x in got if x is not None), 'commits', k)
    npk += 1; nver += sum(1 for x in got if x is not None)
    local.write('repo:hub__%s\t%s\n' % (n, os.path.abspath(g))); local.flush()
say('ALL DONE packages', npk, 'older versions', nver)
