# Classify the survey's repositories that no collection holds: Bend 2, Bend 1 or unknown.
#   classify.py OUT(survey dir) KNOWN(known.txt) EXCLUDE(file of OWNER/NAME)
# Reads OUT/files.tsv and OUT/repos.tsv; per repository asks GitHub's GraphQL API (10 at a time)
# for its metadata and the text of up to 3 of its .bend files (first, middle and last path),
# and marks each text with marks.kind (2 Bend 2, 1 Bend 1, 0 no marker).  A repository is
# Bend 2 if any sample is.  Writes OUT/classes.tsv:
#   repo hits kind samplekinds created pushed fork-of license stars kB archived
import json, subprocess, sys, os, time, collections
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import marks
out, knownf, exf = sys.argv[1:4]
known = {l.strip().lower() for l in open(knownf) if l.strip()}
excl = {l.split()[0].lower() for l in open(exf) if l.strip() and not l.startswith('#')}
paths = collections.defaultdict(list)
for l in open(out + '/files.tsv'):
    r, p, s = l.rstrip('\n').split('\t')
    paths[r].append(p)
todo = sorted(r for r in paths if r.lower() not in known and r.lower() not in excl)
print('repos', len(paths), 'known', sum(1 for r in paths if r.lower() in known),
      'excluded', sum(1 for r in paths if r.lower() in excl), 'to classify', len(todo), flush=True)
def picks(ps):
    ps = sorted(ps)
    return [ps[i] for i in sorted({0, len(ps) // 2, len(ps) - 1})]
rows = []
done = set()
if os.path.exists(out + '/classes.tsv'):
    for l in open(out + '/classes.tsv'):
        rows.append(l.rstrip('\n')); done.add(l.split('\t')[0])
todo = [r for r in todo if r not in done]
F = 'createdAt pushedAt isArchived stargazerCount diskUsage parent { nameWithOwner } licenseInfo { spdxId }'
for i in range(0, len(todo), 10):
    batch = todo[i:i + 10]
    q = []
    for j, r in enumerate(batch):
        o, n = r.split('/', 1)
        objs = ' '.join('f%d: object(expression: %s) { ... on Blob { text } }' % (k, json.dumps('HEAD:' + p))
                        for k, p in enumerate(picks(paths[r])))
        q.append('r%d: repository(owner: %s, name: %s) { %s %s }' % (j, json.dumps(o), json.dumps(n), F, objs))
    query = '{ ' + ' '.join(q) + ' }'
    for attempt in range(5):
        p = subprocess.run(['gh', 'api', 'graphql', '-f', 'query=' + query], capture_output=True, text=True)
        try:
            d = json.loads(p.stdout).get('data') or {}
            break
        except Exception:
            time.sleep(10 * (attempt + 1))
    else:
        d = {}
    with open(out + '/classes.tsv', 'a') as f:
        for j, r in enumerate(batch):
            x = d.get('r%d' % j)
            if not x:
                row = [r, str(len(paths[r])), 'err', '', '', '', '', '', '', '', '']
            else:
                ks = []
                for k in range(3):
                    b = x.get('f%d' % k)
                    if b and b.get('text') is not None: ks.append(str(marks.kind(b['text'])))
                kind = '2' if '2' in ks else ('1' if '1' in ks else ('0' if ks else 'none'))
                row = [r, str(len(paths[r])), kind, ''.join(ks), x['createdAt'][:10], x['pushedAt'][:10],
                       (x.get('parent') or {}).get('nameWithOwner', ''), (x.get('licenseInfo') or {}).get('spdxId', ''),
                       str(x['stargazerCount']), str(x['diskUsage']), str(x['isArchived'])]
            f.write('\t'.join(row) + '\n')
    print(i + len(batch), '/', len(todo), flush=True)
c = collections.Counter(l.split('\t')[2] for l in open(out + '/classes.tsv'))
print('kinds', dict(c))
