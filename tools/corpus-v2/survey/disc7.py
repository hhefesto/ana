#!/usr/bin/env python3
# Bend repositories the code search misses (2026-10-28; the user's goal 11388: the most Bend code).
# GitHub's code search has no hit in bendlib/bendlib (217 .bend files, Apache-2.0, pushed today),
# found as a submodule of dearlordylord/hapsland: the run-6 survey (survey.py) only saw what that
# index holds.  Candidates here, besides code search:
#   - every repository of an owner of a collected one (PINS files' owners: they write Bend);
#   - the submodules of the collected repositories (.gitmodules at the pin);
#   - repository search (names, descriptions, topics: bend2, bendlang, ...).
# A candidate no collection knows (KNOWN, lower-case OWNER/NAME a line), not EXCLUDEd, not a fork,
# not empty, pushed since SINCE (2026-08-20: Bend 2's bend.ts is from 08-25): its default branch's tree (one REST call), its .bend files.
#   disc7.py OUT KNOWN EXCLUDE PINS... -- COLLECT-SRC-DIR...
# writes OUT/cands.tsv (repo, source), OUT/files.tsv (repo, path, sha) and
# OUT/repos.tsv (repo, .bend files) as survey.py does, for classify.py.
import json, subprocess, sys, os, time, glob, re, collections
a = sys.argv[1:]
k = a.index('--'); dirs = a[k + 1:]; a = a[:k]
OUT, KNOWN, EXCL, PINS = a[0], a[1], a[2], a[3:]
os.makedirs(OUT, exist_ok=True)
# Bend 2 (bend2/bend.ts) is from 2026-08-25: a repository last pushed before has none
SINCE = os.environ.get('SINCE', '2026-08-20')
log = open(OUT + '/log.txt', 'a')
def say(*x):
    print(time.strftime('%T'), *x, file=log, flush=True)
def api(path, *f, jq=None):
    for t in range(5):
        p = subprocess.run(['gh', 'api', '-X', 'GET', path, *sum((['-f', x] for x in f), [])] + (['--paginate', '--jq', jq] if jq else []),
                           capture_output=True, text=True)
        if p.returncode == 0:
            return p.stdout.split() if jq else json.loads(p.stdout)
        if '404' in p.stderr or 'Not Found' in p.stdout or '409' in p.stderr: return None
        say('retry', path, p.stderr[:200].replace('\n', ' ')); time.sleep(20 * (t + 1))
    return None
known = {l.strip().lower() for l in open(KNOWN) if l.strip()}
excl = {l.split()[0].lower() for l in open(EXCL) if l.strip() and not l.startswith('#')}
owners = set()
for f in PINS:
    for l in open(f):
        r = l.split('\t')[0]
        known.add(r.lower())
        if '/' in r and not r.startswith('hub/'): owners.add(r.split('/')[0])
cands = {}   # repo -> source
def cand(r, src):
    r = r.strip().rstrip('/')
    if r.endswith('.git'): r = r[:-4]
    if r.count('/') != 1 or r.lower() in known or r.lower() in excl: return
    cands.setdefault(r, src)
# submodules
for d in dirs:
    for g in sorted(glob.glob(d + '/*/')):
        p = subprocess.run(['git', '-C', g, 'show', 'HEAD:.gitmodules'], capture_output=True, text=True)
        if p.returncode: continue
        own = os.path.basename(g.rstrip('/')).split('__')[0]
        for u in re.findall(r'url\s*=\s*(\S+)', p.stdout):
            m = re.search(r'github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$', u)
            if m: cand(m.group(1), 'submodule')
            elif u.startswith('../'): cand(own + '/' + u[3:], 'submodule')
say('submodule candidates', len(cands))
# owners' repositories
for o in sorted(owners):
    for r in api('users/%s/repos' % o, 'per_page=100', 'type=owner',
                 jq='.[] | select(.fork | not) | select(.size > 0) | select(.pushed_at >= "%s") | .full_name' % SINCE) or []:
        cand(r, 'owner')
say('owners', len(owners), 'candidates', len(cands))
# repository search
for q in ['bend2', 'bendlang', 'bend-lang', 'bend lang', 'topic:bend', 'topic:bendlang', 'topic:bend2', 'topic:bend-lang',
          'hvm2 bend', 'higherorderco', 'bend in:name', '"ALL PROOFS CHECK"', 'Bend Base in:readme', 'bend language in:readme']:
    for pg in range(1, 11):
        d = api('search/repositories', 'q=' + q, 'per_page=100', 'page=%d' % pg)
        time.sleep(2.1)
        if not d or not d.get('items'): break
        for r in d['items']:
            if not r.get('fork') and r.get('size', 0) > 0 and r.get('pushed_at', '') >= SINCE: cand(r['full_name'], 'search')
        if pg * 100 >= d.get('total_count', 0): break
say('search candidates', len(cands))
with open(OUT + '/cands.tsv', 'w') as f:
    for r, s in sorted(cands.items()): f.write('%s\t%s\n' % (r, s))
done = set()
if os.path.exists(OUT + '/files.tsv'):
    done = {l.split('\t')[0] for l in open(OUT + '/checked.txt')} if os.path.exists(OUT + '/checked.txt') else set()
F = open(OUT + '/files.tsv', 'a'); C = open(OUT + '/checked.txt', 'a')
n = 0
for r in sorted(cands):
    if r in done: continue
    t = api('repos/%s/git/trees/HEAD' % r, 'recursive=1')
    bs = [(x['path'], x['sha']) for x in (t or {}).get('tree', []) if x.get('type') == 'blob' and x['path'].endswith('.bend')]
    for p, s in bs: F.write('%s\t%s\t%s\n' % (r, p, s))
    F.flush(); C.write('%s\t%d\t%s\n' % (r, len(bs), 'truncated' if (t or {}).get('truncated') else '')); C.flush()
    if bs: n += 1; say('bend', r, len(bs), cands[r])
    time.sleep(0.4)
c = collections.Counter(l.split('\t')[0] for l in open(OUT + '/files.tsv'))
with open(OUT + '/repos.tsv', 'w') as f:
    for r, k in sorted(c.items()): f.write('%s\t%d\n' % (r, k))
say('DONE candidates', len(cands), 'with .bend', len(c))
