#!/usr/bin/env python3
# br6.py's files less what the collection's `list` step would leave out (2026-10-28):
#   br6-filter.py TREE LIST CFG... -- HELD.jsonl... > LIST.kept   (reasons' counts on stderr)
# a path under a config's `repo`/`growth` line's exclude prefixes (the last line naming the
# repository wins, as collect's runs went: run 3 to run 6), a vendored directory (Collect.bend's
# col.vendored.names), a `*_generated*` file, a file over `big` (1,000,000 bytes) or, for an
# lt100k repository, of 100 KB or more; and a path a HELD corpus has in the same repository
# (vault, holdout: a head's version of a held-out file is that file still).
import sys, os, collections
a = sys.argv[1:]; k = a.index('--')
TREE, LIST, CFGS, HELD = a[0], a[1], a[2:k], a[k + 1:]
VEND = {'vendor', 'vendored', 'third_party', 'third-party', 'node_modules', '.lake', 'lake-packages', '_build',
        'dist-newstyle', '.stack-work', '_opam'}
rules = {}
for c in CFGS:
    for ln in open(c):
        w = ln.split()
        if len(w) >= 3 and w[0] in ('repo', 'growth'):
            ex = w[w.index('exclude') + 1:] if 'exclude' in w else []
            rules[w[1].replace('/', '__')] = (w[2], ex)
import json
held = set()
for h in HELD:
    for ln in open(h, 'rb'):
        i = json.loads(ln)['id']
        held.add(i.split(':', 1)[1])
why = collections.Counter()
for ln in open(LIST):
    rel = ln.strip()
    if not rel: continue
    top, path = rel.split('/', 1)
    slug = top.split('~', 1)[0]
    rule, ex = rules.get(slug, ('all', []))
    size = os.path.getsize(os.path.join(TREE, rel))
    parts = path.split('/')
    if any(path.startswith(e) for e in ex): r = 'excluded prefix'
    elif any(p in VEND for p in parts[:-1]): r = 'vendored'
    elif '_generated' in parts[-1]: r = 'generated name'
    elif size > 1000000: r = 'big'
    elif rule == 'lt100k' and size >= 100000: r = 'lt100k'
    elif rule == 'novendor' and path.startswith('vendor/'): r = 'novendor'
    elif slug + '/' + path in held: r = 'held path'
    else:
        sys.stdout.write(rel + '\n'); why['kept'] += 1; continue
    why[r] += 1
print(' '.join('%s %d' % x for x in sorted(why.items())), file=sys.stderr)
