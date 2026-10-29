# sess7.py's shell replay (2026-10-28): what one shell command of an agent's session did to the
# files sess7.py follows.  Not a shell: enough of one for the commands the agents ran.
#
#   run(cmd, cwd, st, home) -> (target, text, many, why)
#
# st: path -> text known (changed in place; any file, as agents splice `.bend` files from text
# files they wrote).  target: the one `.bend` file the command gave bend (None: none; many: more
# than one), text: st[target] when bend ran on it (None: not known).
# Followed: `cd`, `VAR=value` / `export` (then $VAR, ${VAR}), heredocs, `{ ...; } > F` groups,
# redirects of commands whose output is known (cat, sed without -i, head, tail, echo), `tee F`,
# `cp A B` / `mv A B`, `sed -i` (replayed by GNU sed --sandbox on a copy of the text known: no
# e/r/w commands), bend by `nix run ..#bend --`, `nix develop -c`, `bun .../main.ts`.  Any other
# command naming a file that may write it (python, perl, awk, patch, git, rm, a loop, a redirect
# of output not known) forgets it.  A command that does not parse (shlex) forgets every `.bend`
# path it names.
import re, os, shlex, subprocess, tempfile

HEREDOC = re.compile(r"<<(-?)\s*(['\"]?)([A-Za-z_]\w*)\2")
BENDTOK = re.compile(r'''[^\s'"`;|&<>(){}=]+\.bend\b''')
PATHTOK = re.compile(r'''[^\s'"`;|&<>(){}=]+\.(bend|txt|out|tmp|part|frag|new|orig|bak)\b''')
SEPS = {';', '&&', '||', '|', '\n', '&', ';;', '|&'}
REDIR = {'>', '>>', '>|', '&>', '&>>', '<', '<>', '>&', '<&', '<<<'}
WRAP = {'timeout', 'nice', 'env', 'time', 'command', 'exec', 'nohup', 'stdbuf', 'ionice', 'chrt'}
FLOW = {'for', 'while', 'until', 'if', 'then', 'do', 'done', 'fi', 'else', 'elif', 'case', 'esac', 'function', 'select'}
READONLY = {'grep', 'rg', 'less', 'wc', 'ls', 'diff', 'sort', 'uniq', 'cut', 'stat', 'file', 'md5sum', 'sha256sum',
            'test', '[', 'true', 'false', 'du', 'nl', 'cmp', 'realpath', 'readlink', 'basename', 'dirname', 'tr', 'fold',
            'column', 'sleep', 'date', 'pwd', 'type', 'which', 'xxd', 'od', 'comm', 'mkdir', 'git-diff', 'bend-units'}

def norm(p, cwd, home):
    p = p.replace('$HOME', home).replace('${HOME}', home)
    if p == '~' or p.startswith('~/'): p = home + p[1:]
    if not p.startswith('/'): p = os.path.join(cwd, p)
    return os.path.normpath(p)

def heredocs(cmd):
    lines = cmd.split('\n'); out, bodies, i = [], [], 0
    while i < len(lines):
        ln = lines[i]; ms = list(HEREDOC.finditer(ln))
        if not ms:
            out.append(ln); i += 1; continue
        pos = i + 1
        for m in ms:
            body = []
            while pos < len(lines) and (lines[pos].lstrip('\t') if m.group(1) else lines[pos]) != m.group(3):
                body.append(lines[pos]); pos += 1
            pos += 1
            k = len(bodies); bodies.append('\n'.join(body) + '\n')
            ln = ln.replace(m.group(0), ' __HEREDOC%d__ ' % k, 1)
        out.append(ln); i = pos
    return '\n'.join(out), bodies

def tokens(cmd):
    lx = shlex.shlex(cmd, posix=True, punctuation_chars=';&|<>()\n')
    lx.whitespace = ' \t\r'
    lx.whitespace_split = True
    return list(lx)

def parse(toks):
    """units: {'words': [...], 'piped': bool} or {'group': [units], 'words': [redirects], 'piped': bool}"""
    top = []; stack = [top]; cur = []; after = None; piped = False
    def flush():
        nonlocal cur, piped
        if cur: stack[-1].append({'words': cur, 'piped': piped}); piped = False
        cur = []
    for t in toks:
        if t in ('{', '('):
            flush(); g = {'group': [], 'words': [], 'piped': piped, 'sub': t == '('}; piped = False
            stack[-1].append(g); stack.append(g['group']); after = None
        elif t in ('}', ')'):
            flush()
            if len(stack) > 1:
                stack.pop(); after = stack[-1][-1]
        elif t in SEPS or (set(t) <= set(';&|\n') and t not in REDIR):
            flush(); after = None
            piped = t in ('|', '|&')
        elif after is not None:
            after['words'].append(t)
        else:
            cur.append(t)
    flush()
    return top

def expand(w, var):
    def sub(m):
        n = m.group(1) or m.group(2)
        return var.get(n, m.group(0))
    return re.sub(r'\$\{(\w+)\}|\$(\w+)', sub, w)

def sed_replay(args, src):
    """args: sed's arguments with the file argument the placeholder '@@F@@': (file after, stdout)"""
    with tempfile.TemporaryDirectory() as d:
        f = os.path.join(d, 'f.bend')
        with open(f, 'w', errors='surrogateescape') as o: o.write(src)
        a = [f if x == '@@F@@' else x for x in args]
        try:
            r = subprocess.run(['sed', '--sandbox'] + a, cwd=d, capture_output=True, timeout=10)
        except (subprocess.TimeoutExpired, OSError):
            return None, None
        if r.returncode != 0: return None, None
        return open(f, errors='surrogateescape').read(), r.stdout.decode('utf-8', 'surrogateescape')

def sed_split(args):
    """(options and script words, file words) of sed's arguments; None if a script file is used"""
    head, files, script = [], [], False
    i = 0
    while i < len(args):
        a = args[i]
        if a in ('-e', '--expression', '-l', '--line-length'):
            head += args[i:i + 2]; script = script or a in ('-e', '--expression'); i += 2; continue
        if a in ('-f', '--file') or a.startswith('--file='): return None
        if a.startswith('-') and len(a) > 1 and not files:
            if re.match(r'-[nErsuz]*f', a): return None
            head.append(a); i += 1; continue
        if not script:
            head.append(a); script = True; i += 1; continue
        files.append(a); i += 1
    return head, files

def headtail(b0, args, text):
    n, plus = 10, False; files = []
    i = 0
    while i < len(args):
        a = args[i]
        if a == '-n' and i + 1 < len(args): v = args[i + 1]; i += 2
        elif re.match(r'^-n?[+]?\d+$', a): v = a.lstrip('-n') or '10'; i += 1
        elif a.startswith('-'): return None
        else: files.append(a); i += 1; continue
        plus = v.startswith('+'); n = int(v.lstrip('+'))
    ls = text.splitlines(True)
    if b0 == 'head': return ''.join(ls[:n])
    return ''.join(ls[n - 1:]) if plus else ''.join(ls[-n:] if n else [])

class Sh:
    def __init__(s, cwd, st, home, bodies):
        s.cwd, s.st, s.home, s.bodies = cwd, st, home, bodies
        s.var = {'HOME': home}; s.flow = False
        s.target = None; s.text = None; s.many = False
    def n(s, p): return norm(p, s.cwd, s.home)
    def forget_words(s, ws):
        for x in ws:
            for m in PATHTOK.finditer(x):
                t = m.group(0)
                if '$' not in t: s.st.pop(s.n(t), None)
    def write(s, outs, out, append=False):
        for o in outs:
            p = s.n(o)
            if p == '/dev/null': continue
            if out is None: s.st.pop(p, None)
            elif append:
                if p in s.st: s.st[p] = s.st[p] + out
            else: s.st[p] = out
    def redirs(s, words):
        argv, outs, apps = [], [], []
        i = 0
        while i < len(words):
            w = words[i]
            if w in REDIR:
                if i + 1 < len(words):
                    tgt = words[i + 1]
                    if w in ('>&', '<&') and tgt.isdigit(): pass
                    elif w.startswith('<'): pass
                    elif w in ('>>', '&>>'): apps.append(tgt)
                    else: outs.append(tgt)
                i += 2; continue
            if w.isdigit() and i + 1 < len(words) and words[i + 1] in REDIR: i += 1; continue
            argv.append(w); i += 1
        return argv, outs, apps
    def unit(s, u):
        """run a unit; its stdout if known (else None)"""
        words = [expand(w, s.var) for w in u['words']]
        if 'group' in u:
            _, outs, apps = s.redirs(words)
            saved = s.cwd if u.get('sub') else None
            outs_known = []
            for v in u['group']:
                outs_known.append(s.unit(v))
            if saved: s.cwd = saved
            out = None if any(x is None for x in outs_known) else ''.join(outs_known)
            s.write(outs, out); s.write(apps, out, True)
            return out
        argv, outs, apps = s.redirs(words)
        while argv and re.match(r'^[A-Za-z_]\w*=', argv[0]):
            k, v = argv[0].split('=', 1)
            if len(argv) == 1: s.var[k] = v
            argv = argv[1:]
        if argv and argv[0] in ('export', 'local', 'declare', 'readonly'):
            for a in argv[1:]:
                if re.match(r'^[A-Za-z_]\w*=', a):
                    k, v = a.split('=', 1); s.var[k] = v
            return ''
        while argv and os.path.basename(argv[0]) in WRAP:
            w0 = os.path.basename(argv[0]); argv = argv[1:]
            while argv and (argv[0].startswith('-') or (w0 == 'env' and '=' in argv[0])
                            or (w0 in ('nice', 'ionice') and argv[0].isdigit())):
                argv = argv[1:]
            if w0 == 'timeout' and argv and re.match(r'^[\d.]+[smhd]?$', argv[0]): argv = argv[1:]
        if not argv:
            s.write(outs, None if u['piped'] else ''); s.write(apps, None if u['piped'] else '', True)
            return ''
        a0 = argv[0]; b0 = os.path.basename(a0)
        if b0 == 'nix' and len(argv) > 2:
            if argv[1] == 'run' and '--' in argv and any(x.endswith(('#bend', '#bend2')) for x in argv[2:argv.index('--')]):
                argv = ['bend'] + argv[argv.index('--') + 1:]
            elif argv[1] in ('develop', 'shell') and ('-c' in argv or '--command' in argv):
                k = argv.index('-c') if '-c' in argv else argv.index('--command')
                argv = argv[k + 1:] or ['true']
            a0 = argv[0]; b0 = os.path.basename(a0)
        if b0 in ('bun', 'node', 'deno') and len(argv) > 1 and 'bend' in argv[1] and argv[1].endswith(('main.ts', 'bend.ts', 'main.js')):
            argv = ['bend'] + argv[2:]; a0 = b0 = 'bend'
        hd = [s.bodies[int(m.group(1))] for x in argv for m in [re.match(r'^__HEREDOC(\d+)__$', x)] if m]
        argv = [x for x in argv if not re.match(r'^__HEREDOC\d+__$', x)]
        if b0 in FLOW: s.flow = True
        if s.flow:
            s.forget_words(argv + outs + apps); return None
        out = None
        if b0 in ('cd', 'pushd'):
            s.cwd = s.n(argv[1]) if len(argv) > 1 and argv[1] != '-' else s.home
            out = ''
        elif b0 == 'bend' or a0.endswith('/bin/bend') or re.match(r'^\$\{?(BEND\w*|B)\}?$', a0):
            for x in argv[1:]:
                if x.endswith('.bend'):
                    p = s.n(x)
                    if s.target and s.target != p: s.many = True
                    s.target = p; s.text = s.st.get(p)
        elif b0 == 'sed':
            sp = sed_split(argv[1:])
            inplace = any(re.match(r'^(-[nErsuz]*i|--in-place)', x) for x in argv[1:])
            if sp is None:
                s.forget_words(argv[1:])
            else:
                head, files = sp
                if inplace:
                    for x in files:
                        p = s.n(x)
                        if p in s.st:
                            new, _ = sed_replay(head + ['@@F@@'], s.st[p])
                            if new is None: s.st.pop(p, None)
                            else: s.st[p] = new
                    out = ''
                elif len(files) == 1 and s.n(files[0]) in s.st and not u['piped']:
                    _, out = sed_replay(head + ['@@F@@'], s.st[s.n(files[0])])
        elif b0 == 'cat':
            fs = [x for x in argv[1:] if not x.startswith('-')]
            if hd and not fs: out = hd[0]
            elif fs and not hd and all(s.n(x) in s.st for x in fs): out = ''.join(s.st[s.n(x)] for x in fs)
        elif b0 in ('head', 'tail'):
            fs = [x for x in argv[1:] if not x.startswith('-') and not re.match(r'^[+]?\d+$', x)]
            if len(fs) == 1 and s.n(fs[0]) in s.st:
                out = headtail(b0, argv[1:], s.st[s.n(fs[0])])
        elif b0 == 'echo':
            a = argv[1:]
            if a and a[0] == '-n': out = ' '.join(a[1:])
            elif a and a[0].startswith('-'): out = None
            else: out = ' '.join(a) + '\n'
        elif b0 == 'tee':
            fs = [x for x in argv[1:] if not x.startswith('-')]
            body = hd[0] if hd else None
            for x in fs:
                if body is not None and '-a' not in argv: s.st[s.n(x)] = body
                else: s.st.pop(s.n(x), None)
            out = body
        elif b0 in ('cp', 'mv', 'install'):
            ops = [x for x in argv[1:] if not x.startswith('-')]
            if len(ops) == 2:
                a, d = s.n(ops[0]), s.n(ops[1])
                if not os.path.splitext(d)[1] and os.path.splitext(a)[1]: d = os.path.join(d, os.path.basename(a))
                if a in s.st: s.st[d] = s.st[a]
                else: s.st.pop(d, None)
                if b0 == 'mv': s.st.pop(a, None)
            else:
                s.forget_words(ops)
            out = ''
        elif b0 == 'printf':   # coreutils printf only formats
            try:
                r = subprocess.run(['printf'] + argv[1:], capture_output=True, timeout=5)
                if r.returncode == 0: out = r.stdout.decode('utf-8', 'surrogateescape')
            except (subprocess.TimeoutExpired, OSError):
                pass
        elif b0 in READONLY:
            pass
        else:   # anything else may write any file it names, in its words or its heredoc
            s.forget_words(argv[1:])
            for h in hd: s.forget_words([h])
        if u['piped'] and b0 not in ('tee',): out = None
        s.write(outs, out); s.write(apps, out, True)
        return out

def run(cmd, cwd, st, home):
    named = {norm(t, cwd, home) for t in BENDTOK.findall(cmd) if '$' not in t and '*' not in t}
    c2, bodies = heredocs(cmd)
    try:
        units = parse(tokens(c2))
    except ValueError:
        for p in named: st.pop(p, None)
        return None, None, False, 'unparsed'
    sh = Sh(cwd, st, home, bodies)
    for u in units:
        sh.unit(u)
    return sh.target, sh.text, sh.many, ('flow' if sh.flow else '')
