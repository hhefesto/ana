#!/usr/bin/env python3
# Bare operators, upgraded (2026-10-28; the user's goal: the most Bend code, error-then-fix cases
# included).  Until Bend 2.0.16 (09-19) a bare operator meant Nat; since then the check rejects it
# ("a type for this operator (write (a + b : Nat))", and a note: "Until 2.0.16 a bare operator
# meant Nat ... Wrap the expression and it'll work again").  Run 6's collection lost 1,978 files to
# it at the loader (mitschabaude-bot/pi-bend's 1,255).  This wraps the expression the error points
# at in `( ... : Nat)`, as the error says, and checks again, until the file checks or fails
# otherwise (or the same error comes back: given up).
#
#   upgrade.py SRC LIST OUT
#
# LIST: paths under SRC, a line each (a repository's tree: imports are relative).  The file is
# rewritten in a copy of its repository under OUT/tree (SRC is not touched); OUT/upgrade.tsv:
# path, steps, the end (pass | other: the first error line | stuck | limit), and OUT/files/PATH
# the upgraded text when it changed; OUT/renames.tsv: repository TAB a name Base took, renamed NAME_.
# A name Base took since (`a fresh name (duplicate declaration: NAME)`, ~1,100 of run 6's dropped
# files: Text, Ready, Wait, Pair, Word, Window, ...) is renamed NAME_ in the file declaring it and
# every file reaching it (RENAME=0: not).  env BEND, PROCS (4), STEPS (300), TIMEOUT (120 s).
import sys, os, re, subprocess, shutil, concurrent.futures as cf

BEND = os.environ.get('BEND', '/home/hhefesto/src/ana/run/v5/gcroot-bend-2.0.39/bin/bend')
PROCS = int(os.environ.get('PROCS', '4'))
STEPS = int(os.environ.get('STEPS', '300'))
TIMEOUT = int(os.environ.get('TIMEOUT', '120'))
SRC, LIST, OUT = sys.argv[1:4]
SRC = os.path.abspath(SRC)
env = dict(os.environ, BEND_NO_TELEMETRY='1')
OPEN, CLOSE = '([{', ')]}'

def check(p):
    try:
        r = subprocess.run([BEND, os.path.basename(p), '--check-only'], cwd=os.path.dirname(p),
                           capture_output=True, timeout=TIMEOUT, env=env)
    except subprocess.TimeoutExpired:
        return None, ['timeout']
    return r.returncode, (r.stdout + r.stderr).decode('utf-8', 'replace').splitlines()

def where(lines):
    """the error's line (1-based) and column (0-based) in the file: the `N>|` line and the caret under it"""
    for k, l in enumerate(lines):
        m = re.match(r'^\s*(\d+)>\|', l)
        if m and k + 1 < len(lines):
            c = lines[k + 1]
            pre = m.end() + 1   # `N>| ` then the line
            if '^' in c and c[:pre].strip(' ') in ('|', ''):
                return int(m.group(1)), c.index('^') - pre, l[pre:]
    return None

def extent(s, c):
    """the expression starting at s[c]: up to a `,`, `;`, ` : ` or an unmatched closer at its depth, or
    the line's end (a `#` comment left out)"""
    d, k = 0, c
    while k < len(s):
        ch = s[k]
        if ch == '"':
            k += 1
            while k < len(s) and s[k] != '"': k += 2 if s[k] == '\\' else 1
        elif ch in OPEN: d += 1
        elif ch in CLOSE:
            if d == 0: break
            d -= 1
        elif d == 0 and (ch in ',;' or s.startswith(' : ', k) or ch == '#' or (ch == ':' and k + 1 < len(s) and s[k + 1] in ' \n' and s[k - 1] != ' ')):
            break
        k += 1
    e = k
    while e > c and s[e - 1] in ' \t': e -= 1
    return e

import threading
locks, glock = {}, threading.Lock()
def lock(f):
    with glock: return locks.setdefault(f, threading.Lock())

IMP = re.compile(r'^import\s+(\S+\.bend)\b', re.M)
IMPS = {}
def imports(f):
    """f's own imports (our edits never touch an import line: cached)"""
    if f not in IMPS:
        try: t = open(f, encoding='utf-8', errors='surrogateescape').read()
        except OSError: t = ''
        IMPS[f] = [q for q in (os.path.normpath(os.path.join(os.path.dirname(f), m.group(1))) for m in IMP.finditer(t))
                   if os.path.isfile(q)]   # a hub import (NAME@VERSION/...) is not a file here
    return IMPS[f]

def closure(p):
    """p's imports (relative .bend paths), all the way down"""
    seen, todo = [], [p]
    while todo:
        f = todo.pop()
        for q in imports(f):
            if q not in seen and q != p: seen.append(q); todo.append(q)
    return seen

def wrap(f, ln, col, shown):
    """the operator at f's line ln, column col wrapped in ( ... : Nat); False: the line is not shown's"""
    with lock(f):
        ls = open(f, encoding='utf-8', errors='surrogateescape').read().split('\n')
        if ln - 1 >= len(ls) or ls[ln - 1].rstrip() != shown.rstrip(): return False
        s = ls[ln - 1]
        if col < 0 or col >= len(s): return False
        b = start(s, col) if s[col] in OPS else col
        e = extent(s, col)
        if e <= col or b > col: return False
        ls[ln - 1] = s[:b] + '(' + s[b:e] + ' : Nat)' + s[e:]
        open(f, 'w', encoding='utf-8', errors='surrogateescape').write('\n'.join(ls))
        return True

RENAME = os.environ.get('RENAME', '1') == '1'
def importers(f):
    """the files of f's repository copy that reach f by their imports (f too)"""
    top = os.path.join(OUT, 'tree', os.path.relpath(f, OUT + '/tree').split('/')[0])
    out = [f]
    for root, _, xs in os.walk(top):
        for x in xs:
            q = os.path.join(root, x)
            if x.endswith('.bend') and q != f and f in closure(q): out.append(q)
    return out

def code_sub(line, pat, repl):
    """pat to repl in a line's code: not in a string, not after a `#` outside one"""
    out, k, start, ins = [], 0, 0, False
    while k < len(line):
        ch = line[k]
        if ins:
            if ch == '\\': k += 2; continue
            if ch == '"': out.append(line[start:k + 1]); start = k + 1; ins = False
        elif ch == '"':
            out.append(pat.sub(repl, line[start:k])); start = k; ins = True
        elif ch == '#':
            out.append(pat.sub(repl, line[start:k])); out.append(line[k:]); return ''.join(out)
        k += 1
    out.append(line[start:] if ins else pat.sub(repl, line[start:]))
    return ''.join(out)

def rename(p, fs, ln, shown, name):
    """a name Base took since (duplicate declaration: NAME): the file declaring it (its line shown),
    and every file reaching that one, call theirs NAME_ (a word of code, not of a string or a comment)"""
    f = next((g for g in fs if (lambda ls: ln - 1 < len(ls) and ls[ln - 1].rstrip() == shown.rstrip())(
        open(g, encoding='utf-8', errors='surrogateescape').read().split('\n'))), None)
    if f is None: return False
    pat = re.compile(r'(?<![A-Za-z0-9_])' + re.escape(name) + r'(?![A-Za-z0-9_])')
    with glock:
        open(OUT + '/renames.tsv', 'a').write('%s\t%s\n' % (os.path.relpath(f, OUT + '/tree').split('/')[0], name))
    for g in importers(f):
        with lock(g):
            t = open(g, encoding='utf-8', errors='surrogateescape').read()
            o = [code_sub(line, pat, name + '_') for line in t.split('\n')]
            n = '\n'.join(o)
            if n != t: open(g, 'w', encoding='utf-8', errors='surrogateescape').write(n)
    return True

OPS = '+-*/%<>=!&|^'
def start(s, c):
    """the left operand's start of the operator at s[c]: back to a `,`, an unmatched opener, a `=`
    (not of an operator), a `: `, a `<-` or the line's indentation"""
    d, k = 0, c - 1
    while k >= 0 and s[k] == ' ': k -= 1
    while k >= 0:
        ch = s[k]
        if ch in CLOSE: d += 1
        elif ch in OPEN:
            if d == 0: break
            d -= 1
        elif d == 0:
            if ch in ',;': break
            if ch == '=' and (k + 1 >= len(s) or s[k + 1] not in '=') and (k == 0 or s[k - 1] not in '=<>!'): break
            if ch == ':' and k + 1 < len(s) and s[k + 1] == ' ': break
            if ch == '-' and k + 1 < len(s) and s[k + 1] == '>': break
            if ch == '<' and k + 1 < len(s) and s[k + 1] == '-': break
        k -= 1
    b = k + 1
    while b < c and s[b] == ' ': b += 1
    return b

def upgrade(rel):
    """rel's check until it passes or fails otherwise; a bare operator's error, in rel or in a file
    it imports (found by the line the error shows), is wrapped where it is, in the copy"""
    p = os.path.join(OUT, 'tree', rel)
    seen = set()
    steps = 0
    end = 'limit'
    while steps < STEPS:
        rc, out = check(p)
        if rc == 0 and out[:1] == ['ALL PROOFS CHECK']: end = 'pass'; break
        msg = next((l for l in out if l.startswith('- message') or l.startswith('- expected')), out[0] if out else '')
        dup = re.search(r'a fresh (?:constructor )?name \(duplicate declaration: ([A-Za-z_][A-Za-z0-9_.]*)\)', msg) if RENAME else None
        if 'a type for this operator' not in msg and not dup:
            end = 'other: ' + msg.strip()[:120]; break
        w = where(out)
        if w is None: end = 'other: no location'; break
        ln, col, shown = w
        key = (ln, col, shown, msg)
        if key in seen: end = 'stuck'; break
        seen.add(key)
        fs = [p] + closure(p)
        if dup:
            if not rename(p, fs, ln, shown, dup.group(1)): end = 'other: the line shown is in no file it reaches'; break
        elif not any(wrap(f, ln, col, shown) for f in fs):
            end = 'other: the line shown is in no file it reaches'; break
        steps += 1
    return rel, steps, end

rels = [l.strip() for l in open(LIST) if l.strip()]
os.makedirs(OUT + '/tree', exist_ok=True)
byrepo = {}
for r in rels: byrepo.setdefault(r.split('/')[0], []).append(r)
for top in byrepo:   # copy first, before any thread
    w = os.path.join(OUT, 'tree', top)
    if not os.path.isdir(w): shutil.copytree(os.path.join(SRC, top), w, symlinks=True, ignore=shutil.ignore_patterns('.git'))
tsv = OUT + '/upgrade.tsv'
jobs = [r for top in byrepo for r in byrepo[top]]
ROUNDS = int(os.environ.get('ROUNDS', '3'))
last = {}
for rnd in range(ROUNDS):
    # files PROCS at once, a repository's too: a file is checked in place in the copy, which keeps
    # what each run upgraded; a file whose error was in an import goes again the next round
    with open(tsv + '.%d' % rnd, 'w') as t, cf.ThreadPoolExecutor(PROCS) as ex:
        for rel, steps, end in ex.map(upgrade, jobs):
            t.write('%s\t%d\t%s\n' % (rel, steps, end)); t.flush(); last[rel] = (steps, end)
    again = [r for r in jobs if last[r][1] != 'pass' and last[r][0] > 0]   # changed something: again
    print('round', rnd, 'files', len(jobs), 'ends', dict(__import__('collections').Counter(e.split(':')[0] for _, e in (last[r] for r in jobs))), flush=True)
    if not again: break
    jobs = again
with open(tsv, 'w') as t:
    for r in rels: t.write('%s\t%d\t%s\n' % ((r,) + last[r]))
# every file of the copies that changed: OUT/files/PATH
n = 0
for top in byrepo:
    for root, _, fs in os.walk(os.path.join(OUT, 'tree', top)):
        for f in fs:
            if not f.endswith('.bend'): continue
            q = os.path.join(root, f); rel = os.path.relpath(q, OUT + '/tree')
            a = open(q, 'rb').read()
            if a != open(os.path.join(SRC, rel), 'rb').read():
                o = os.path.join(OUT, 'files', rel); os.makedirs(os.path.dirname(o), exist_ok=True)
                open(o, 'wb').write(a); n += 1
print('files upgraded', n)
