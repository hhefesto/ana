#!/usr/bin/env python3
# Real fixes from the collected repositories' git histories (2026-10-28; the user's goal: the most
# Bend code, error-then-fix cases included, at least 4 solutions per error case).
#
#   hist6.py PINS.tsv OUTDIR CORPUS.jsonl... [-- OWNER/NAME...]
#
# A CORPUS may be NUL pairs (.nul) too.  HIST_CLASS: the GitHub repositories' id class (repo; run
# 2's corpus: curated, `curated:OWNER__NAME/PATH`).
# HIST_LOCAL=1: PINS.tsv lines are `CLASS:SLUG TAB DIR` instead, local repositories (the user's own,
# own5's `own:ana/...` ids: ~/src/ana), cloned from DIR, every branch's history (`--all`).
#
# The files wanted are the training corpora's (CORPUS.jsonl: `{"id": "repo:OWNER__NAME/PATH",
# "text": ...}`, as collect writes them; vault and holdout files are not given, so none is mined).
# For each repository of PINS.tsv (OWNER/NAME TAB pin ...) with a wanted file (BendHub packages have
# no history), a bare partial clone (commits and trees; blobs fetched for the wanted files only)
# into OUTDIR/git.  For a wanted file, its versions in the history of the pin, newest first; the
# corpus text is one of them (its git blob id), and the K versions older than it are its past.
# bend-units (the deploy's, MAX 0: every declaration) cuts the corpus text and the older versions
# into units: a unit of the corpus text whose newest older body differing beyond whitespace
# exists gets that body as its history mutant.  Put back into today's file it is the code as it
# was, and today's body its fix, when the check rejects it (units6.sh's check decides, as for any
# mutant; hist-merge.py hands them to it).
# Output, appended per repository (resumable: OUTDIR/done.txt):
#   OUTDIR/hist.nul   NUL pairs: unit id, record "sha256(today's body) 0x1E old body 0x1E commit 0x1E time"
#   OUTDIR/stats.tsv  repo, commits, wanted files, with history, text not in history, units,
#                     units with a history mutant
# The clone is deleted after its repository is done (disk).
# Memory (10-28): the first version held a repository's every blob and unit at once and was killed
# at 7 GB on Giulio2002/bend-ssz (16527 .bend files); files go in batches of BATCH now, and only
# the corpora's.
import sys, os, subprocess, hashlib, re, time, shutil, json

args = sys.argv[1:]
ONLY = set()
if '--' in args:
    k = args.index('--'); ONLY = set(args[k + 1:]); args = args[:k]
PINS, OUT, CORPORA = args[0], args[1], args[2:]
K = int(os.environ.get('HIST_K', '8'))
BATCH = int(os.environ.get('HIST_BATCH', '150'))
UNITS = os.environ.get('BEND_UNITS', '/nix/store/impkz92xqmwzfk1f07yiz9vimkbvljd1-bend-units/bin/bend-units')
env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='false', BEND_NO_TELEMETRY='1')
os.makedirs(OUT + '/git', exist_ok=True)
done = set(open(OUT + '/done.txt').read().split()) if os.path.exists(OUT + '/done.txt') else set()

def say(*a): print(time.strftime('[%F %T]'), *a, flush=True)
def git(d, *a, inp=None, timeout=900):
    return subprocess.run(['git', '-C', d, *a], input=inp, capture_output=True, check=True, env=env, timeout=timeout).stdout
def ws(b): return re.sub(rb'\s+', b'', b)
def blobid(t): return hashlib.sha1(b'blob %d\0' % len(t) + t).hexdigest().encode()

def corpus(c):
    """(id, text) of a corpus: JSON lines, or NUL pairs (a .nul: a transcripts run's files-hi.nul)"""
    if c.endswith('.nul'):
        d = open(c, 'rb').read().split(b'\0')
        for k in range(0, len(d) - 1, 2):
            yield {'id': d[k].decode('utf-8', 'surrogateescape'), 'text': d[k + 1].decode('utf-8', 'surrogateescape')}
    else:
        for ln in open(c, 'rb'): yield json.loads(ln)

want = {}   # CLASS:SLUG -> {path: corpus text}
for c in CORPORA:
    for d in corpus(c):
        i = d['id']
        if ':' not in i or i.startswith('repo:hub__'): continue
        cls, rest = i.split(':', 1)
        if '/' not in rest: continue
        slug, path = rest.split('/', 1)
        want.setdefault(cls + ':' + slug, {})[path.encode('utf-8', 'surrogateescape')] = d['text'].encode('utf-8', 'surrogateescape')
say('wanted', sum(len(v) for v in want.values()), 'files of', len(want), 'repositories')

# One bend-units call a file: its memory grows with all it was given (28 MB of birc at once took
# 26 GB, 10-28; one file a call peaks at 1.7 GB, birc's 100 KB history_search.bend).  A call that
# fails (killed by the unit's MemoryMax, timeout) loses that file only.
JOBS = int(os.environ.get('HIST_JOBS', '3'))
from concurrent.futures import ThreadPoolExecutor

def units1(k, i, t, tmp):
    a, b = '%s.%d.in' % (tmp, k), '%s.%d.out' % (tmp, k)
    try:
        with open(a, 'wb') as f: f.write(i + b'\0' + t + b'\0')
        subprocess.run([UNITS, 'bend', a, b, '0'], check=True, capture_output=True, env=env, timeout=600)
        d = open(b, 'rb').read().split(b'\0')
        return [(d[k], d[k + 1].split(b'\x1e')) for k in range(0, len(d) - 1, 2)]
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired):
        say('  bend-units failed:', i.decode('utf-8', 'replace')[:160]); return []
    finally:
        for x in (a, b):
            if os.path.exists(x): os.remove(x)

def units(pairs, tmp):
    """bend-units over (id, text) pairs: list of (id, fields)"""
    ok = [(i, t) for i, t in pairs if not (b'\0' in t or b'\x1e' in t or b'\x1f' in t)]
    with ThreadPoolExecutor(JOBS) as ex:
        rs = ex.map(lambda kp: units1(kp[0], kp[1][0], kp[1][1], tmp), enumerate(ok))
        return [u for r in rs for u in r]

def catfile(g, ids):
    out = git(g, 'cat-file', '--batch', inp=b'\n'.join(ids) + b'\n', timeout=3600)
    blobs, k = {}, 0
    while k < len(out):
        nl = out.index(b'\n', k)
        if out[k:nl].endswith(b' missing'): k = nl + 1; continue
        h, typ, size = out[k:nl].split(); size = int(size)
        blobs[h] = out[nl + 1:nl + 1 + size]; k = nl + 1 + size + 1
    return blobs

LOCAL = os.environ.get('HIST_LOCAL') == '1'
CLASS = os.environ.get('HIST_CLASS', 'repo')   # the ids' class of GitHub repositories (run 2's: curated)

def repo(name, pin, files, cls='repo', slug=None, url=None):
    slug = slug or name.replace('/', '__')
    g = OUT + '/git/' + cls + '__' + slug + '.git'
    if not os.path.isdir(g):
        if LOCAL:   # a local clone: every branch (the user's work is often unpushed, as telomare's bend)
            subprocess.run(['git', 'clone', '-q', '--mirror', url, g], check=True, capture_output=True, env=env, timeout=1800)
        else:
            subprocess.run(['git', 'clone', '-q', '--bare', '--filter=blob:none', 'https://github.com/' + name, g],
                           check=True, capture_output=True, env=env, timeout=1800)
    if not LOCAL:
        try: git(g, 'cat-file', '-e', pin + '^{commit}')
        except subprocess.CalledProcessError:
            git(g, 'fetch', '-q', 'origin', pin, timeout=1800)
    ncommits = int(git(g, 'rev-list', '--count', pin).strip())
    hist = {}   # path -> [(commit, time, blob)] newest first
    cur = None
    for ln in git(g, 'log', '--raw', '--no-abbrev', '--no-renames', '--format=C %H %ct', pin, '--', '*.bend').splitlines():
        if ln.startswith(b'C '):
            _, h, t = ln.split(); cur = (h, t); continue
        if ln.startswith(b':'):
            meta, path = ln.split(b'\t', 1)
            if path not in files: continue
            b = meta.split()[3]
            hist.setdefault(path, []).append((cur[0], cur[1], b))
    vers, lost = {}, 0
    for p, hs in hist.items():
        tb = blobid(files[p])
        at = [k for k, x in enumerate(hs) if x[2] == tb]
        if not at: lost += 1; continue   # the corpus text is none of the file's versions
        v = []
        for c, t, b in hs[at[0] + 1:]:
            if b.startswith(b'0000000') or b == tb or any(b == x[2] for x in v): continue
            v.append((c, t, b))
            if len(v) >= K: break
        if v: vers[p] = v
    need = sorted(set(x[2] for v in vers.values() for x in v))
    if need and not LOCAL:
        git(g, '-c', 'fetch.negotiationAlgorithm=noop', 'fetch', '-q', 'origin', '--no-tags', '--no-write-fetch-head',
            '--filter=blob:none', '--stdin', inp=b'\n'.join(need) + b'\n', timeout=3600)
    base = cls.encode() + b':' + slug.encode() + b'/'
    nunits = n = 0
    ps = sorted(vers)
    for s in range(0, len(ps), BATCH):
        batch = ps[s:s + BATCH]
        blobs = catfile(g, sorted(set(x[2] for p in batch for x in vers[p])))
        pairs = []
        for p in batch:
            pairs.append((base + p, files[p]))
            for c, t, b in vers[p]:
                if b in blobs: pairs.append((b'old:' + c + b':' + t + b':' + slug.encode() + b'/' + p, blobs[b]))
        del blobs
        us = units(pairs, OUT + '/tmp')
        now, old = {}, {}
        for uid, f in us:
            fid, rest = uid.split(b'#', 1); nm = rest.rsplit(b'@', 1)[0]
            if fid.startswith(b'old:'):
                _, c, t, sp = fid.split(b':', 3)
                old.setdefault((sp, nm), []).append((int(t), c, f[7]))
            else:
                now[uid] = (fid[len(cls) + 1:], nm, f[7])
        nunits += len(now)
        with open(OUT + '/hist.nul', 'ab') as o:
            for uid, (sp, nm, body) in now.items():
                cs = sorted(old.get((sp, nm), []), key=lambda x: -x[0])  # newest first
                for t, c, ob in cs:
                    if ws(ob) == ws(body) or not ob.strip(): continue  # the same up to layout: older still
                    o.write(uid + b'\0' + hashlib.sha256(body).hexdigest().encode() + b'\x1e' + ob + b'\x1e' + c + b'\x1e' + str(t).encode() + b'\0')
                    n += 1; break
    r = (ncommits, len(files), len(vers), lost, nunits, n)
    with open(OUT + '/stats.tsv', 'a') as s:
        s.write('\t'.join(map(str, (name,) + r)) + '\n')
    assert os.path.abspath(g).startswith(os.path.abspath(OUT + '/git') + '/')
    shutil.rmtree(g)
    return r

for ln in open(PINS):
    f = ln.rstrip('\n').split('\t')
    if len(f) < 2 or f[0] in done or (ONLY and f[0] not in ONLY): continue
    if LOCAL:
        name, pin, (cls, slug), url = f[0], '--all', f[0].split(':', 1), f[1]
    else:
        if '/' not in f[0]: continue
        name, pin, cls, slug, url = f[0], f[1], CLASS, f[0].replace('/', '__'), None
    files = want.get(cls + ':' + slug)
    if not files: continue
    t0 = time.time()
    try:
        r = repo(name, pin, files, cls, slug, url)
        say(name, 'commits %d wanted %d with-history %d text-not-in-history %d units %d history-mutants %d' % r, '%.0fs' % (time.time() - t0))
    except Exception as e:
        say(name, 'FAILED', type(e).__name__, str(e)[:200])
        shutil.rmtree(OUT + '/git/' + cls + '__' + slug + '.git', ignore_errors=True)
    with open(OUT + '/done.txt', 'a') as d: d.write(name + '\n')
say('ALL DONE')
