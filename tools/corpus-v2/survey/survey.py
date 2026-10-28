# GitHub survey of repositories holding .bend files (2026-10-28, run 6's collection):
# code search `extension:bend size:A..B`, bisecting a size range until it has <= 1000 hits,
# every page of every leaf; writes OUT/files.tsv (repo, path, sha) and OUT/repos.tsv (repo, hits).
# Code search allows 10 requests a minute: one every 6.5 s.
import json, subprocess, sys, time, collections, os
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
log = open(OUT + '/log.txt', 'a')
def say(*a):
    print(time.strftime('%H:%M:%S'), *a, file=log, flush=True)
last = [0.0]
def get(q, page):
    for attempt in range(8):
        w = last[0] + 6.5 - time.time()
        if w > 0: time.sleep(w)
        last[0] = time.time()
        p = subprocess.run(['gh', 'api', '-X', 'GET', 'search/code', '-f', 'q=' + q, '-f', 'per_page=100', '-f', 'page=%d' % page],
                           capture_output=True, text=True)
        if p.returncode == 0:
            return json.loads(p.stdout)
        say('retry', q, page, p.stdout[:200].replace('\n', ' '), p.stderr[:200].replace('\n', ' '))
        time.sleep(30 * (attempt + 1))
    say('GAVE UP', q, page)
    return None
files = {}
def leaf(q, first):
    n = first['total_count']
    items = list(first['items'])
    pages = min(10, (n + 99) // 100)
    for pg in range(2, pages + 1):
        d = get(q, pg)
        if d is None or not d['items']: break
        items += d['items']
    for it in items:
        files[(it['repository']['full_name'], it['path'])] = it['sha']
    say('leaf', q, n, len(items), 'repos so far', len({r for r, _ in files}))
def walk(a, b):
    q = 'extension:bend size:%d..%d' % (a, b)
    d = get(q, 1)
    if d is None: return
    n = d['total_count']
    if n > 1000 and b > a:
        m = (a + b) // 2
        say('split', q, n)
        walk(a, m); walk(m + 1, b)
    else:
        leaf(q, d)
walk(0, 400000)
with open(OUT + '/files.tsv', 'w') as f:
    for (r, p), s in sorted(files.items()): f.write('%s\t%s\t%s\n' % (r, p, s))
c = collections.Counter(r for r, _ in files)
with open(OUT + '/repos.tsv', 'w') as f:
    for r, k in sorted(c.items()): f.write('%s\t%d\n' % (r, k))
say('DONE files', len(files), 'repos', len(c))
