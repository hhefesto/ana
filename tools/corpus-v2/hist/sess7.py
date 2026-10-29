#!/usr/bin/env python3
# Real errors from the agents' own sessions (2026-10-28; the user's goal 11388: the most Bend code,
# error-then-fix cases included, at least 4 solutions per error case).
#
#   sess7.py OUT CORPUS.jsonl [SESSIONS_DIR...]
#
# own5's files (CORPUS: run/v5/transcripts-own5/own5.jsonl, ids `own:SLUG/PATH`) were written by
# agents: Claude's workers (claude-direct, claude-hs: run/v5/claude-gen), mugen and its subagents
# (ana, telomare, agda2bend, mugen), Claude Code sessions in ~/src/ana and ~/src/telomare.  Their
# session logs (Claude Code's JSONL, ~/.claude/projects: the Agent SDK's too) hold each file as it
# was each time the agent checked it with `bend F --check-only` (or ran it) and the check failed:
# a real error, which the agent then fixed.  Codex (bend-gen, hs2bend: ~/.codex/sessions, SESS_CODEX;
# `none`: not read) ran JavaScript scripts: their exec_command and apply_patch calls with plain literal
# arguments are replayed, outputs matched to calls when they are as many (a loop: forgotten).
#
# The file's text is followed through the session: Write / mcp__mugen__write (the whole text),
# Edit (Claude Code logs the text before it, originalFile) / mcp__mugen__edit (old -> new on the
# text known), a shell command that names the file and may write it (>, sed -i, mv, cp, python,
# patch, git) forgets it.  A check is a shell command whose one `.bend` file is given to bend
# (cd's followed); its output says ALL PROOFS CHECK or SOME PROOFS FAIL.  A failed check of a
# file whose text is not known takes the text the next Edit started from (originalFile), when
# nothing touched the file in between.
#
# A session file maps to a corpus id by the longest path suffix they share (2 parts at least, or
# the base name alone when one id has it in the slug the path names), and only when its text is
# like the corpus text (line sets' Jaccard >= 0.25).  The corpus text itself is no error.
#
# OUT/states.nul   NUL pairs: id, "time 0x1E session 0x1E error excerpt 0x1E text" (failed checks)
# OUT/git/SLUG     a git repository a slug: a commit per failed state (its session time), oldest
#                  first, then one commit of every corpus text of the slug (the newest): hist6.py
#                  with HIST_LOCAL=1 (OUT/LOCAL.tsv) mines it as any history
# OUT/stats.tsv    per slug: sessions, checks, failed, states kept
import sys, os, json, re, glob, hashlib, subprocess, collections, time, calendar

OUT, CORPUS = sys.argv[1], sys.argv[2]
ROOTS = sys.argv[3:] or [os.path.expanduser('~/.claude/projects')]
HOME = os.path.expanduser('~')
os.makedirs(OUT, exist_ok=True)

def say(*a): print(time.strftime('[%F %T]'), *a, file=sys.stderr, flush=True)

corpus = {}   # id -> text
for ln in open(CORPUS):
    d = json.loads(ln)
    if d['id'].startswith('own:'): corpus[d['id']] = d['text']
suf = collections.defaultdict(set)   # path suffix -> ids
for i in corpus:
    parts = i.split('/', 1)[1].split('/')
    for k in range(1, len(parts) + 1):
        suf['/'.join(parts[-k:])].add(i)
lines = {i: set(t.splitlines()) for i, t in corpus.items()}

HINTS = [('claude-gen/direct/', 'claude-direct'), ('claude-gen/hs/', 'claude-hs'), ('/bend-gen/', 'bend-gen'),
         ('/hs2bend/', 'hs2bend'), ('/src/ana/', 'ana'), ('/formalTransformer/', 'ana'), ('/telomare', 'telomare'),
         ('/src/mugen/', 'mugen'), ('/agda2bend', 'agda2bend')]
def slug_hint(p):
    for h, s in HINTS:
        if h in p: return s
    return None

mapc = {}
def corpus_id(p):
    if p in mapc: return mapc[p]
    parts = p.split('/'); hint = slug_hint(p); r = None
    for k in range(len(parts), 0, -1):
        c = suf.get('/'.join(parts[-k:]))
        if not c: continue
        if hint: c = {i for i in c if i.split('/', 1)[0] == 'own:' + hint} or (c if k >= 2 else set())
        if len(c) == 1 and (k >= 2 or hint): r = next(iter(c))
        break
    mapc[p] = r
    return r

def like(i, text):
    a, b = lines[i], set(text.splitlines())
    return len(a & b) / max(1, len(a | b)) >= 0.25

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sess7sh

def norm(p, cwd):
    return sess7sh.norm(p, cwd, HOME)

def text_of(c):
    if isinstance(c, str): return c
    if isinstance(c, list):
        return '\n'.join(x.get('text', '') for x in c if isinstance(x, dict))
    return ''

def verdict(t):
    a, s = 'ALL PROOFS CHECK' in t, 'SOME PROOFS FAIL' in t
    if a == s: return None
    return 'ok' if a else 'fail'

def excerpt(t):
    k = t.find('SOME PROOFS FAIL')
    return t[k:k + 1500]


GATEFAIL = re.compile(r'(?m)^FAIL check (\S+\.bend)\b')

def shell_event(proj, f, st, pend, cmd, cwd, res, ts):
    if '.bend' not in cmd and 'FAIL check' not in (res or ''): return
    p, text, many, why = sess7sh.run(cmd, cwd, st, HOME)
    # a gate's report (Codex's tools/Check.hs: `FAIL check PATH` and the error): the file as known now
    for m in GATEFAIL.finditer(res or ''):
        q = norm(m.group(1), cwd)
        if q in st:
            stats[proj, 'gate-failed'] += 1
            states.setdefault(('?', q, hashlib.sha256(st[q].encode('utf-8', 'surrogateescape')).hexdigest()), (ts, f, res[m.start():m.start() + 1500], st[q]))
        else:
            stats[proj, 'gate-unknown'] += 1
    v = verdict(res) if res else None
    # a file the command named is no longer waiting for an Edit's originalFile
    for q in list(pend):
        if q != p and os.path.basename(q) in cmd: pend.pop(q, None)
    if not v: return
    if why: stats[proj, why + '-' + v] += 1
    if many:   # several files checked at once: which failed is not known
        stats[proj, 'many'] += 1; return
    if not p:
        stats[proj, 'unparsed-' + v] += 1; return
    stats[proj, 'checks'] += 1
    if v == 'ok':
        pend.pop(p, None)
    elif text is not None:
        stats[proj, 'failed'] += 1
        states.setdefault(('?', p, hashlib.sha256(text.encode('utf-8', 'surrogateescape')).hexdigest()), (ts, f, excerpt(res), text))
        pend.pop(p, None)
    else:
        stats[proj, 'fail-unknown'] += 1
        pend[p] = (ts, excerpt(res))

def apply_patch(st, patch, cwd):
    """Codex's apply_patch (*** Begin Patch ... *** End Patch) on the texts known"""
    L = patch.split('\n'); i = 0
    while i < len(L):
        l = L[i]
        if l.startswith('*** Add File: '):
            p = norm(l[14:].strip(), cwd); body = []; i += 1
            while i < len(L) and not L[i].startswith('*** '):
                body.append(L[i][1:] if L[i].startswith('+') else L[i]); i += 1
            st[p] = '\n'.join(body) + '\n'
            continue
        if l.startswith('*** Delete File: '):
            st.pop(norm(l[17:].strip(), cwd), None); i += 1; continue
        if l.startswith('*** Update File: '):
            p = norm(l[17:].strip(), cwd); i += 1; mv = None
            if i < len(L) and L[i].startswith('*** Move to: '):
                mv = norm(L[i][13:].strip(), cwd); i += 1
            hunks, cur, anc = [], [], ''
            while i < len(L) and not (L[i].startswith('*** ') and L[i] != '*** End of File'):
                if L[i].startswith('@@'):
                    if cur: hunks.append((anc, cur))
                    anc, cur = L[i][2:].strip(), []
                elif L[i] != '*** End of File':
                    cur.append(L[i])
                i += 1
            if cur: hunks.append((anc, cur))
            t = st.get(p)
            if t is not None:
                F = t.split('\n'); pos = 0
                for anc, h in hunks:
                    old = [x[1:] if x[:1] in (' ', '-') else x for x in h if x[:1] in (' ', '-', '')]
                    new = [x[1:] if x[:1] in (' ', '+') else x for x in h if x[:1] in (' ', '+', '')]
                    start = pos
                    if anc:
                        k = next((k for k in range(pos, len(F)) if anc in F[k]), None)
                        if k is None: t = None; break
                        start = k
                    at = None
                    for eq in (lambda a, b: a == b, lambda a, b: a.rstrip() == b.rstrip(), lambda a, b: a.strip() == b.strip()):
                        if not old:
                            at = len(F) if not anc else start + 1; break
                        at = next((k for k in range(start, len(F) - len(old) + 1)
                                   if all(eq(F[k + j], old[j]) for j in range(len(old)))), None)
                        if at is not None: break
                    if at is None: t = None; break
                    F[at:at + len(old)] = new; pos = at + len(new)
                if t is not None: t = '\n'.join(F)
            if t is None: st.pop(p, None)
            else: st[p] = t
            if mv:
                st.pop(p, None)
                if t is None: st.pop(mv, None)
                else: st[mv] = t
            continue
        i += 1

def js_lit(s, i):
    """the JavaScript string literal at s[i] (None: not a plain literal), and the index after it"""
    while i < len(s) and s[i] in ' \t\n': i += 1
    if i >= len(s) or s[i] not in '"\'`': return None, i
    q = s[i]; j = i + 1; out = []
    while j < len(s):
        ch = s[j]
        if ch == '\\' and j + 1 < len(s):
            nx = s[j + 1]
            if nx == 'n': out.append('\n')
            elif nx == 't': out.append('\t')
            elif nx == 'r': out.append('\r')
            elif nx == 'u' and re.match(r'[0-9a-fA-F]{4}', s[j + 2:j + 6]): out.append(chr(int(s[j + 2:j + 6], 16))); j += 4
            elif nx == '\n': pass
            else: out.append(nx)
            j += 2; continue
        if ch == q:
            k = j + 1
            while k < len(s) and s[k] in ' \t\n': k += 1
            if k < len(s) and s[k] == '+': return None, j + 1   # concatenation
            return ''.join(out), j + 1
        if q == '`' and ch == '$' and s[j + 1:j + 2] == '{': return None, j
        out.append(ch); j += 1
    return None, j

def js_ops(s):
    """the exec_command / apply_patch calls of a Codex exec script, in order: ('exec', cmd, workdir),
    ('patch', text), or (kind, None) when its argument is not a plain literal"""
    ops = []
    for m in re.finditer(r'tools\.(exec_command|apply_patch)\(', s):
        if m.group(1) == 'apply_patch':
            t, _ = js_lit(s, m.end()); ops.append(('patch', t)); continue
        seg = s[m.end():m.end() + 200000]
        k = re.match(r'\s*\{\s*["\']?cmd["\']?\s*:', seg)
        if not k: ops.append(('exec', None, None)); continue
        cmd, e = js_lit(seg, k.end())
        wd = None
        w = re.match(r'\s*,\s*["\']?workdir["\']?\s*:', seg[e:])
        if w: wd, _ = js_lit(seg, e + w.end())
        ops.append(('exec', cmd, wd))
    return ops

def exec_out(t):
    try:
        d = json.loads(t)
        if isinstance(d, dict) and 'output' in d:
            return d['output'] if isinstance(d['output'], str) else ''
    except ValueError:
        pass
    return t

states = {}   # (id, sha) -> (time, session, err, text)
stats = collections.Counter()
files = []
for r in ROOTS:
    files += glob.glob(r + '/**/*.jsonl', recursive=True)
say('sessions', len(files), 'corpus', len(corpus))
for f in sorted(files):
    proj = os.path.relpath(f, ROOTS[0]).split('/')[0]
    st = {}         # path -> text (known)
    pend = {}       # path -> (time, err): failed, text unknown, waiting for the next Edit's originalFile
    uses = {}       # tool_use id -> (name, input, cwd)
    last_ts = ''
    try: fh = open(f, errors='replace')
    except OSError: continue
    for line in fh:
        if '"tool_use"' not in line and '"tool_result"' not in line: continue
        try: d = json.loads(line)
        except ValueError: continue
        cwd = d.get('cwd') or HOME; ts = d.get('timestamp') or last_ts; last_ts = ts
        m = d.get('message') or {}
        cont = m.get('content')
        if not isinstance(cont, list): continue
        for b in cont:
            if not isinstance(b, dict): continue
            if b.get('type') == 'tool_use':
                uses[b.get('id')] = (b.get('name'), b.get('input') or {}, cwd)
                continue
            if b.get('type') != 'tool_result': continue
            u = uses.pop(b.get('tool_use_id'), None)
            if not u: continue
            name, inp, ucwd = u
            res = text_of(b.get('content')); err = bool(b.get('is_error'))
            if name in ('Write', 'mcp__mugen__write'):
                p = inp.get('file_path') or inp.get('path')
                if not p or err: continue
                p = norm(p, ucwd)
                if p.endswith('.bend') and isinstance(inp.get('content'), str):
                    st[p] = inp['content']; pend.pop(p, None)
            elif name == 'Edit':
                p = inp.get('file_path')
                if not p or err: continue
                p = norm(p, ucwd)
                if not p.endswith('.bend'): continue
                tr = d.get('toolUseResult')
                pre = tr.get('originalFile') if isinstance(tr, dict) else None
                if pre is None: pre = st.get(p)
                if p in pend and pre is not None:
                    t0, e0 = pend.pop(p)
                    stats[proj, 'failed'] += 1
                    states.setdefault(('?', p, hashlib.sha256(pre.encode()).hexdigest()), (t0, f, e0, pre))
                pend.pop(p, None)
                o, n = inp.get('old_string', ''), inp.get('new_string', '')
                if pre is not None and o in pre:
                    st[p] = pre.replace(o, n) if inp.get('replace_all') else pre.replace(o, n, 1)
                else:
                    st.pop(p, None)
            elif name == 'mcp__mugen__edit':
                if err: continue
                for e in inp.get('edits') or []:
                    p = e.get('path')
                    if not p: continue
                    p = norm(p, ucwd)
                    if not p.endswith('.bend'): continue
                    pend.pop(p, None)
                    pre = st.get(p); o, n = e.get('old', ''), e.get('new', '')
                    if pre is not None and o in pre:
                        st[p] = pre.replace(o, n) if e.get('all') else pre.replace(o, n, 1)
                    else:
                        st.pop(p, None)
            elif name in ('Read', 'mcp__mugen__read'):
                p = inp.get('file_path') or inp.get('path')
                if not p or err: continue
                p = norm(p, ucwd)
                if not p.endswith('.bend') or p in st: continue
                full = None
                tr = d.get('toolUseResult')
                if name == 'Read' and isinstance(tr, dict) and isinstance(tr.get('file'), dict):
                    fl = tr['file']
                    if fl.get('startLine') == 1 and fl.get('numLines') == fl.get('totalLines') and isinstance(fl.get('content'), str):
                        full = fl['content']
                        if full and not full.endswith('\n'): full += '\n'
                elif name == 'mcp__mugen__read':
                    m2 = re.search(r'\n\[lines 1-(\d+) of (\d+)\]$', res)
                    if m2 and m2.group(1) == m2.group(2): full = res[:m2.start()] + '\n'
                if full is not None:
                    st[p] = full; stats[proj, 'read'] += 1
            elif name in ('Bash', 'mcp__mugen__shell'):
                shell_event(proj, f, st, pend, inp.get('command') or '', ucwd, res, ts)
    stats[proj, 'sessions'] += 1
    stats[proj, 'pend-lost'] += len(pend)


CODEX = os.environ.get('SESS_CODEX', os.path.expanduser('~/.codex/sessions'))
cfiles = sorted(glob.glob(CODEX + '/**/*.jsonl', recursive=True)) if CODEX != 'none' else []
say('codex sessions', len(cfiles))
for f in cfiles:
    meta = None; calls = {}; st = {}; pend = {}; proj = 'codex'
    try: fh = open(f, errors='replace')
    except OSError: continue
    for line in fh:
        try: d = json.loads(line)
        except ValueError: continue
        pl = d.get('payload') or {}; ts = d.get('timestamp') or ''
        if d.get('type') == 'session_meta':
            meta = pl.get('cwd') or HOME; proj = 'codex:' + meta.replace(HOME, '~'); continue
        if not meta or d.get('type') != 'response_item': continue
        ty = pl.get('type')
        if ty in ('custom_tool_call', 'function_call'):
            calls[pl.get('call_id')] = (pl.get('name'), pl.get('input') if ty == 'custom_tool_call' else pl.get('arguments'))
            continue
        if ty not in ('custom_tool_call_output', 'function_call_output'): continue
        name, s = calls.pop(pl.get('call_id'), (None, None))
        if not isinstance(s, str): continue
        o = pl.get('output')
        items = [x.get('text', '') for x in o if isinstance(x, dict)] if isinstance(o, list) else [o if isinstance(o, str) else '']
        if name == 'apply_patch':
            apply_patch(st, s, meta); continue
        if name == 'exec_command':
            try: a = json.loads(s)
            except ValueError: continue
            c = a.get('cmd'); c = ' '.join(c) if isinstance(c, list) else c
            if isinstance(c, str): shell_event(proj, f, st, pend, c, norm(a.get('workdir') or meta, meta), exec_out(items[0] if items else ''), ts)
            continue
        if name != 'exec': continue
        ops = js_ops(s)
        loop = re.search(r'\bfor\s*\(|\.map\(|forEach|while\s*\(', s)
        outs = items[1:]
        mapped = not loop and len(outs) == len(ops)
        nexec = sum(1 for x in ops if x[0] == 'exec')
        for k, op in enumerate(ops):
            if op[0] == 'patch':
                if op[1] is None or loop:
                    for t in sess7sh.BENDTOK.findall(s): st.pop(norm(t, meta), None)
                else:
                    apply_patch(st, op[1], meta)
            else:
                cmd, wd = op[1], op[2]
                if cmd is None or loop:
                    for t in sess7sh.BENDTOK.findall(s): st.pop(norm(t, meta), None)
                    continue
                res = exec_out(outs[k]) if mapped else ('\n'.join(exec_out(x) for x in outs) if nexec == 1 else '')
                shell_event(proj, f, st, pend, cmd, norm(wd, meta) if wd else meta, res, ts)
    stats[proj, 'sessions'] += 1
    stats[proj, 'pend-lost'] += len(pend)

# map to corpus ids
kept = {}
lost = collections.Counter()
noid = collections.Counter()
for (_, p, h), (ts, f, e, text) in states.items():
    i = corpus_id(p)
    if not i:
        lost['no-id'] += 1; noid[os.path.dirname(p)] += 1; continue
    if text == corpus[i]: lost['is-corpus-text'] += 1; continue
    if not like(i, text): lost['unlike'] += 1; continue
    kept[(i, h)] = (ts, f, e, text)
say('failed states', len(states), 'kept', len(kept), dict(lost))
say('no id:', noid.most_common(12))
with open(OUT + '/states.nul', 'wb') as o:
    for (i, h), (ts, f, e, text) in sorted(kept.items(), key=lambda x: (x[0][0], x[1][0])):
        o.write(i.encode() + b'\0' + b'\x1e'.join(x.encode('utf-8', 'surrogateescape') for x in (ts, f, e, text)) + b'\0')
byslug = collections.defaultdict(list)
for (i, h), (ts, f, e, text) in kept.items():
    byslug[i.split('/', 1)[0][4:]].append((ts, i.split('/', 1)[1], text))
with open(OUT + '/stats.tsv', 'w') as s:
    for (proj, k), v in sorted(stats.items()): s.write('%s\t%s\t%d\n' % (proj, k, v))
    for sl, v in sorted(byslug.items()): s.write('slug %s\tstates\t%d\tfiles\t%d\n' % (sl, len(v), len(set(x[1] for x in v))))

def epoch(ts):
    try: return calendar.timegm(time.strptime(ts[:19], '%Y-%m-%dT%H:%M:%S'))
    except ValueError: return 0

os.makedirs(OUT + '/git', exist_ok=True)
with open(OUT + '/LOCAL.tsv', 'w') as L:
    for sl, v in sorted(byslug.items()):
        g = OUT + '/git/' + sl
        if os.path.exists(g): subprocess.run(['rm', '-rf', g], check=True)
        subprocess.run(['git', 'init', '-q', '-b', 'main', g], check=True)
        fi = []
        def data(b):
            fi.append(b'data %d\n' % len(b)); fi.append(b); fi.append(b'\n')
        mark = 0; last = None; tmax = 0
        for ts, path, text in sorted(v):
            t = epoch(ts); tmax = max(tmax, t); mark += 1
            fi.append(b'commit refs/heads/main\nmark :%d\n' % mark)
            fi.append(b'committer sess7 <sess7@ana> %d +0000\n' % t)
            data(b'session state (failed check)\n')
            if last: fi.append(b'from :%d\n' % last)
            fi.append(b'M 100644 inline %s\n' % path.encode()); data(text.encode('utf-8', 'surrogateescape'))
            last = mark
        mark += 1
        fi.append(b'commit refs/heads/main\nmark :%d\n' % mark)
        fi.append(b'committer sess7 <sess7@ana> %d +0000\n' % max(tmax + 60, int(time.time())))
        data(b'corpus text (own5)\n')
        if last: fi.append(b'from :%d\n' % last)
        pre = 'own:' + sl + '/'
        for i, t in sorted(corpus.items()):
            if i.startswith(pre):
                fi.append(b'M 100644 inline %s\n' % i[len(pre):].encode()); data(t.encode('utf-8', 'surrogateescape'))
        fi.append(b'done\n')
        subprocess.run(['git', '-C', g, 'fast-import', '--quiet', '--done'], input=b''.join(fi), check=True)
        L.write('own:%s\t%s\n' % (sl, os.path.abspath(g)))
        say(sl, 'states', len(v), 'repo', g)
say('DONE')
