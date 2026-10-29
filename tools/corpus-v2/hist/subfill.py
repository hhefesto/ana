#!/usr/bin/env python3
# The collected repositories' git submodules, filled in (2026-10-28; the user's goal 11388: the most
# Bend code).  The collection clones a repository sparse (`*.bend`) without its submodules, so a
# file importing one (aivv73/bend-voxel's deps/bend-vulkan, hapsland's vendor/bendlib, ...) fails
# "no such file": 75 of run 6's loader's files (10-28).
#   subfill.py COL OUT CHECK.tsv
# For each repository of COL (OWNER__NAME, a pinned clone) with a CHECK.tsv (collect's
# stage/bend.check.tsv) "no such file" row whose missing path is under one of its gitlinks: a copy
# of the repository in OUT/OWNER__NAME, each such submodule's files at the gitlink's commit put in
# it (.bend and .c, transitively: a submodule's own submodules), and the row's file on stdout
# (OWNER__NAME/PATH).  Clones: OUT/../git (bare, partial).
import sys, os, re, subprocess, shutil, collections
COL, OUT, CHECK = sys.argv[1:4]
G = os.path.join(os.path.dirname(os.path.abspath(OUT)), 'git')
os.makedirs(OUT, exist_ok=True); os.makedirs(G, exist_ok=True)
env = dict(os.environ, GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='false')
def git(d, *a, inp=None):
    return subprocess.run(['git', '-C', d, *a], input=inp, capture_output=True, check=True, env=env, timeout=1800).stdout
def err(*a): print(*a, file=sys.stderr, flush=True)
rows = collections.defaultdict(list)
pre = os.path.abspath(COL) + '/'
for ln in open(CHECK, encoding='utf-8', errors='replace'):
    p = ln.rstrip('\n').split('\t')
    if len(p) < 3 or p[1] != 'load': continue
    m = re.search(r'no such file: (\S+)', p[2])
    if not m or not m.group(1).startswith(pre): continue
    f = p[0].split('/src/bend/', 1)[-1]
    r = f.split('/', 1)[0]
    miss = m.group(1)[len(pre):]
    if miss.startswith(r + '/'): rows[r].append((f, miss[len(r) + 1:]))
def links(d, commit, mods_text):
    urls = {}
    cur = None
    for ln in mods_text.splitlines():
        ln = ln.strip()
        if ln.startswith('path'): cur = ln.split('=', 1)[1].strip()
        elif ln.startswith('url') and cur: urls[cur] = ln.split('=', 1)[1].strip()
    out = {}
    for ln in git(d, 'ls-tree', '-r', commit).decode().splitlines():
        meta, path = ln.split('\t', 1)
        if meta.startswith('160000'): out[path] = (meta.split()[2], urls.get(path))
    return out
def gh(u, owner):
    m = re.search(r'github\.com[:/]([^/\s]+/[^/\s]+?)(?:\.git)?/?$', u or '')
    if m: return m.group(1)
    if u and u.startswith('../'): return owner + '/' + u[3:].removesuffix('.git')
    return None
def fill(dest, name, commit, depth=0):
    g = G + '/' + name.replace('/', '__') + '.git'
    if not os.path.isdir(g + '/objects'):
        shutil.rmtree(g, ignore_errors=True)
        subprocess.run(['git', 'init', '-q', '--bare', g], check=True, capture_output=True)
        git(g, 'remote', 'add', 'origin', 'https://github.com/' + name)
        git(g, 'config', 'remote.origin.promisor', 'true'); git(g, 'config', 'remote.origin.partialclonefilter', 'blob:none')
    try: git(g, 'cat-file', '-e', commit + '^{commit}')
    except subprocess.CalledProcessError: git(g, 'fetch', '-q', '--filter=blob:none', '--no-tags', 'origin', commit)
    ents = []
    for ln in git(g, 'ls-tree', '-r', commit).decode().splitlines():
        meta, path = ln.split('\t', 1); mm = meta.split()
        if mm[1] == 'blob' and (path.endswith('.bend') or path.endswith('.c') or path.endswith('.h')): ents.append((path, mm[2]))
    ids = sorted({b for _, b in ents})
    if ids:
        git(g, '-c', 'fetch.negotiationAlgorithm=noop', 'fetch', '-q', 'origin', '--no-tags', '--no-write-fetch-head',
            '--filter=blob:none', '--stdin', inp=('\n'.join(ids) + '\n').encode())
    n = 0
    for path, b in ents:
        q = os.path.join(dest, path)
        if os.path.exists(q): continue
        os.makedirs(os.path.dirname(q), exist_ok=True)
        with open(q, 'wb') as o: o.write(git(g, 'cat-file', 'blob', b)); n += 1
    try: mods = git(g, 'show', commit + ':.gitmodules').decode()
    except subprocess.CalledProcessError: mods = ''
    if mods and depth < 4:
        for path, (c, u) in links(g, commit, mods).items():
            sub = gh(u, name.split('/')[0])
            if sub: n += fill(os.path.join(dest, path), sub, c, depth + 1)
    return n
for r, fs in sorted(rows.items()):
    d = os.path.join(COL, r)
    try: mods = git(d, 'show', 'HEAD:.gitmodules').decode()
    except subprocess.CalledProcessError: continue
    ls = links(d, 'HEAD', mods)
    need = {l for _, miss in fs for l in ls if miss.startswith(l + '/')}
    if not need: continue
    dst = os.path.join(OUT, r)
    if not os.path.isdir(dst): shutil.copytree(d, dst, symlinks=True, ignore=shutil.ignore_patterns('.git'))
    for l in sorted(need):
        c, u = ls[l]; sub = gh(u, r.split('__')[0])
        if not sub: err('subfill: %s %s: no GitHub url (%s)' % (r, l, u)); continue
        try: err('subfill: %s %s <- %s %s: %d files' % (r, l, sub, c[:8], fill(os.path.join(dst, l), sub, c)))
        except Exception as e: err('subfill: %s %s FAILED %s %s' % (r, l, type(e).__name__, str(e)[:200]))
    for f, miss in fs:
        if any(miss.startswith(l + '/') for l in need): print(f)
