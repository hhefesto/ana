#!/usr/bin/env python3
# upgrade.py's files as a corpus, and their old bodies as history mutants (2026-10-28).
#
#   upg-corpus.py corpus UPG LIST SRC TRAIN.jsonl HELD.jsonl... > UPG/upg.jsonl
#     the files of LIST and UPG/files (upgrade.py's), checked whole in UPG/tree as collect's loader
#     classes them (exit 0 pass; a `Location: NAME`, unsafe/foreign or TODO line: checked, a def's
#     own error; else load, which drops the file), pass and checked ones as JSON lines {id, text}
#     (`repo:PATH`); not a file of a held (vault, holdout) repository's, nor a TRAIN id; counts on
#     stderr, UPG/classes.tsv
#   upg-corpus.py git UPG SRC upg.jsonl
#     a git repository a repository of upg.jsonl, UPG/git/SLUG: its .bend files as SRC has them,
#     then as UPG/tree has them; UPG/git/LOCAL.tsv for hist6.py (HIST_LOCAL=1 HIST_HUB=1)
#   upg-corpus.py filter UPG HIST.nul OUT.nul
#     hist6.py's records less those whose old body is the new one but for upgrade.py's renames
#     (NAME for NAME_, UPG/renames.tsv): a rename alone is no error anybody made; the rest's old
#     bodies get the renames too
import sys, os, re, json, subprocess, collections, shutil, hashlib, concurrent.futures as cf

BEND = os.environ.get('BEND', '/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend')
PROCS = int(os.environ.get('PROCS', '4'))
env = dict(os.environ, BEND_NO_TELEMETRY='1')
LOC = re.compile(r'^Location: [^ ]|rel(y|ies) on unsafe or foreign code|TODOs? found', re.M)

def klass(p):
    try:
        r = subprocess.run([BEND, os.path.basename(p), '--check-only'], cwd=os.path.dirname(p),
                           capture_output=True, timeout=300, env=env)
    except subprocess.TimeoutExpired:
        return 'timeout'
    if r.returncode == 0: return 'pass'
    return 'checked' if LOC.search((r.stdout + r.stderr).decode('utf-8', 'replace')) else 'load'

def corpus(upg, lst, src, train, held):
    tr = set()
    for ln in open(train, 'rb'): tr.add(json.loads(ln)['id'])
    hr = set()
    for h in held:
        for ln in open(h, 'rb'): hr.add(json.loads(ln)['id'].split('/', 1)[0])
    rels = set(l.strip() for l in open(lst) if l.strip())
    for root, _, fs in os.walk(upg + '/files'):
        for f in fs:
            if f.endswith('.bend'): rels.add(os.path.relpath(os.path.join(root, f), upg + '/files'))
    c = collections.Counter()
    todo = []
    for r in sorted(rels):
        i = 'repo:' + r
        if i.split('/', 1)[0] in hr: c['held repository'] += 1; continue
        if i in tr: c['in train already'] += 1; continue
        todo.append(r)
    with cf.ThreadPoolExecutor(PROCS) as ex, open(upg + '/classes.tsv', 'w') as t:
        for r, k in zip(todo, ex.map(lambda r: klass(os.path.join(upg, 'tree', r)), todo)):
            t.write('%s\t%s\n' % (r, k)); c[k] += 1
            if k in ('pass', 'checked'):
                text = open(os.path.join(upg, 'tree', r), 'rb').read().decode('utf-8', 'surrogateescape')
                sys.stdout.write(json.dumps({'id': 'repo:' + r, 'text': text}, ensure_ascii=False) + '\n')
    for k in sorted(c): print(k, c[k], file=sys.stderr)

def git(upg, src, jl):
    slugs = collections.Counter()
    for ln in open(jl, 'rb'): slugs[json.loads(ln)['id'][len('repo:'):].split('/', 1)[0]] += 1
    os.makedirs(upg + '/git', exist_ok=True)
    e = dict(env, GIT_AUTHOR_NAME='upgrade', GIT_AUTHOR_EMAIL='upgrade@ana', GIT_COMMITTER_NAME='upgrade',
             GIT_COMMITTER_EMAIL='upgrade@ana', GIT_AUTHOR_DATE='1790000000 +0000', GIT_COMMITTER_DATE='1790000000 +0000')
    with open(upg + '/git/LOCAL.tsv', 'w') as L:
        for s in sorted(slugs):
            g = os.path.join(upg, 'git', s)
            shutil.rmtree(g, ignore_errors=True); os.makedirs(g)
            subprocess.run(['git', 'init', '-q', g], check=True, env=e)
            for k, base in enumerate((os.path.join(src, s), os.path.join(upg, 'tree', s))):
                for x in os.listdir(g):
                    if x != '.git': (shutil.rmtree if os.path.isdir(os.path.join(g, x)) else os.remove)(os.path.join(g, x))
                for root, _, fs in os.walk(base):
                    if '/.git' in root + '/': continue
                    for f in fs:
                        if not f.endswith('.bend'): continue
                        q = os.path.join(root, f); o = os.path.join(g, os.path.relpath(q, base))
                        os.makedirs(os.path.dirname(o), exist_ok=True); shutil.copyfile(q, o)
                e2 = dict(e, GIT_AUTHOR_DATE='%d +0000' % (1790000000 + k), GIT_COMMITTER_DATE='%d +0000' % (1790000000 + k))
                subprocess.run(['git', '-C', g, 'add', '-A'], check=True, env=e2)
                subprocess.run(['git', '-C', g, 'commit', '-q', '--allow-empty', '-m', ('as collected', 'upgraded')[k]], check=True, env=e2)
            L.write('repo:%s\t%s\n' % (s, os.path.abspath(g)))
    print('repositories', len(slugs), file=sys.stderr)

def filt(upg, hist, out):
    ren = collections.defaultdict(set)
    if os.path.exists(upg + '/renames.tsv'):
        for l in open(upg + '/renames.tsv'):
            r, n = l.rstrip('\n').split('\t'); ren[r].add(n)
    d = open(hist, 'rb').read().split(b'\0')
    c = collections.Counter()
    with open(out, 'wb') as o:
        for i in range(0, len(d) - 1, 2):
            uid = d[i]; sha, old, cm, t = d[i + 1].split(b'\x1e')
            slug = uid.split(b':', 1)[1].split(b'/', 1)[0].decode('utf-8', 'surrogateescape')
            new = old
            for n in sorted(ren.get(slug, ()), key=len, reverse=True):
                new = re.sub(rb'(?<![A-Za-z0-9_])' + re.escape(n.encode()) + rb'(?![A-Za-z0-9_])', n.encode() + b'_', new)
            # the record has the new body's sha256 only: a rename alone if old, renamed, hashes to it
            if hashlib.sha256(new).hexdigest().encode() == sha: c['a rename alone (out)'] += 1; continue
            # kept with the renames applied: the old body as written but for the names, its error the
            # one its author made (a bare operator), not one of Base's names meeting it here
            o.write(uid + b'\0' + b'\x1e'.join((sha, new, cm, t)) + b'\0'); c['kept'] += 1
    for k in sorted(c): print(k, c[k], file=sys.stderr)

a = sys.argv[1:]
if a[:1] == ['corpus'] and len(a) >= 5: corpus(a[1], a[2], a[3], a[4], a[5:])
elif a[:1] == ['git'] and len(a) == 4: git(a[1], a[2], a[3])
elif a[:1] == ['filter'] and len(a) == 4: filt(a[1], a[2], a[3])
else: sys.exit('usage: upg-corpus.py corpus UPG LIST SRC TRAIN.jsonl HELD.jsonl... | git UPG SRC upg.jsonl | filter UPG HIST.nul OUT.nul')
