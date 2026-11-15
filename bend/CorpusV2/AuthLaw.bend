import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Clock.bend as Ck
import ../Units.bend as U
import ../Transcript.bend as T
import ../Check/Bend.bend as Bd
import ./Eval.bend as Ev
import ./Mutate.bend as Mu
import ./ExlawText.bend as X
import ./AuthLawText.bend as A

# authlaw: the authors' laws of the corpus's units (collector A: built
# 2026-11-14 in /tmp/bx/lawres, moved here 11-15, `bend-corpus-v2 authlaw`,
# run/v9/f4.sh's `authlaw` step; the user, 11-14: "Yes" to building "the
# authors'-law collector" in Bend; "the law is the spec, the model writes the
# code, and the repo's proof checks it"; "Check each law with the repo's own
# PROOF.bend (or the file the law is in)"; keep only laws whose check passed).
# The user, 11-15: a law that names several functions goes to "every function
# it names, as now"; the laws that check fixed inputs go into training "ranked
# below laws that hold for every input" (al.ranked); a law that passes only
# after other failing laws or helpers were taken out of its proof file counts
# as checked, "the law's own proof checks, and the record says what was
# removed" (field 10).
# BEND_SRC: the roots the units were checked in (`:` between, in order, as
# exlaw's); BEND: the checker.
#
#   authlaw index OUT               every LAWS.bend of the roots: a pair a law
#                                   (ROOT TAB LAWFILE TAB LAW; the units it names)
#   authlaw match INDEX OUT PART..  every passing Bend def of the parts that a
#                                   law names: a LAWS.bend law of its root, or
#                                   a law later in its own file proven there; a
#                                   job a (unit, law), under the unit's id
#   authlaw plan W OUT JOBS..       the jobs in W shards OUT.K, a repository's in one
#   authlaw check JOBS OUT          each check file (the PROOF.bend beside the
#                                   law file, or the unit's own file) checked in
#                                   a copy of its repository (A.al.prep, A.al.rm):
#                                   OUT.pass, OUT.fail, OUT.time (a record a
#                                   job), OUT.files (a record a check file),
#                                   OUT.stats
#   authlaw stats OUT PFX..         the counts of checks PFX.., in Bend
#   authlaw render PASS N OUT       N sessions (the law as the spec, the def as
#                                   the answer) from passing records, one a
#                                   repository, its laws for every input first
#                                   (al.ranked)
#   authlaw ask PASS OUT            the authors'-law ask (the user, 11-15: "Yes"):
#                                   a pair a unit, PATH#NAME then its laws as
#                                   the ask states them (0x1F between), for
#                                   bend-transcript's AUTHLAW; a held-out file's
#                                   laws left out (VALID_K, CorpusV2/ValidText.bend)
#
# A job's record (0x1E between): root, repository, kind (laws-file or
# same-file), law file, law, check file, the units the law names, the unit's
# name, its declaration, its body, its doc.  A result's: authlaw.v1, status
# (pass, fail, open, hole, unsafe, todo, timeout, undecided, error, no-proof,
# missing), why, kind, root, law file, law, the law's text (its doc comment
# and the law), the law file's imports it uses, check file, the checks' account,
# the units the law names, name, declaration, body, doc.  `--check-only`
# only: Lean is not here, so no result is a `--verdict`.

# Roots -----------------------------------------------------------------------------------------

def al.strs(xs: List<&2, List<&2, U32>>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +r = al.strs(t)
      Bool.pick(List<&2, String>, T.empty(x), r, S.str(x) <> r)

def al.roots() -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +src : String <- S.env("BEND_SRC", "")
    return al.strs(S.split(S.b(src), 58))

# Index -----------------------------------------------------------------------------------------

def al.dotless(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +r = al.dotless(t)
      Bool.pick(List<&2, List<&2, U32>>, U.prefix(x, U.b("./")), List.drop(&2, U32, x, 2n) <> r, r)

# a root's LAWS.bend files, their paths from it
def al.ix.find(+root: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    +o : S.Out <- S.run.quiet(root, Nil{}, 3600, "find", ["-L", ".", "-name", "LAWS.bend", "-not", "-path", "*/node_modules/*"], Nil{})
    return al.dotless(S.split.lines(S.Out.text(o)))

def al.ix.rec(islaw: Bool, +b: A.AlB, +pre: List<&2, U32>, +ims: List<&2, A.AlI>, +lf: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match islaw:
    case True{}:
      [T.cat([pre, A.AlB.name(b), [0], T.mg.join(A.al.refs(A.AlB.text(b), ims, lf, defs), [32]), [0]])]
    case False{}:
      Nil{}

def al.ix.recs(bs: List<&2, A.AlB>, +pre: List<&2, U32>, +ims: List<&2, A.AlI>, +lf: List<&2, U32>, +defs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      List.append(&2, List<&2, U32>, al.ix.rec(Nat.is_eq(A.AlB.kind(b), 1n), b, pre, ims, lf, defs), al.ix.recs(t, pre, ims, lf, defs))

def al.ix.file(+root: String, +lf: List<&2, U32>, +out: String) -> IO(Nat):
  do IO<Nat>:
    x : List<&2, U32> <- S.read(root ++ "/" ++ S.str(lf))
    +bs : List<&2, A.AlB> = A.al.blocks(x)
    +ims : List<&2, A.AlI> = A.al.imps(bs, A.al.dirname(lf))
    S.add(out, T.cat(al.ix.recs(bs, T.cat([S.b(root), [9], lf, [9]]), ims, lf, A.al.names(bs, 2n))))
    return List.length(&2, List<&2, U32>, A.al.names(bs, 1n))

def al.ix.files(fs: List<&2, List<&2, U32>>, +root: String, +out: String, +n: Nat) -> IO(Nat):
  match fs:
    case Nil{}:
      IO.pure(Nat, n)
    case +f <> t:
      do IO<Nat>:
        +k : Nat <- al.ix.file(root, f, out)
        al.ix.files(t, root, out, Nat.add(n, k))

def al.ix.roots(rs: List<&2, String>, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match rs:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, st)
    case +r <> t:
      do IO<List<&2, Mu.MttKv>>:
        +fs : List<&2, List<&2, U32>> <- al.ix.find(r)
        +n : Nat <- al.ix.files(fs, r, out, 0n)
        +nf : Nat = List.length(&2, List<&2, U32>, fs)
        IO.print("index " ++ r ++ ": " ++ Nat.show(nf) ++ " LAWS.bend, " ++ Nat.show(n) ++ " laws")
        al.ix.roots(t, out, Mu.mtt.bump(Mu.mtt.bump(st, "laws-files", nf), "laws", n))

def al.index(+out: String) -> IO(Unit):
  do IO<Unit>:
    +rs : List<&2, String> <- al.roots()
    S.write(out, Nil{})
    +st : List<&2, Mu.MttKv> <- al.ix.roots(rs, out, Nil{})
    S.write(out ++ ".stats", Mu.mtt.kv.bytes(st))

# Match -----------------------------------------------------------------------------------------

def al.mp.add(+old: List<&2, U32>, +e: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, T.empty(old), e, T.cat([old, [29], e]))

# each unit key of rs keyed to the index entry e too
def al.mp.put(rs: List<&2, List<&2, U32>>, +e: List<&2, U32>, +m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match rs:
    case Nil{}:
      m
    case +r <> t:
      +key = T.mg.str(r)
      al.mp.put(t, e, Map.set(&2, List<&2, U32>, m, key, al.mp.add(T.mg.got(Map.get(List<&2, U32>, Nil{}, m, key)), e)))

# a root's place in the roots (as bytes; none: "")
def al.ridx(rs: List<&2, String>, +r: List<&2, U32>, +i: Nat) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +x <> t:
      +n = al.ridx(t, r, 1n+i)
      Bool.pick(List<&2, U32>, U.eq(S.b(x), r), T.mg.n(i), n)

# an index entry kept small: the root's place, the law file, the law
def al.mp.ent(+rs: List<&2, String>, +k: List<&2, U32>) -> List<&2, U32>:
  +p = T.split(k, 9)
  T.cat([al.ridx(rs, T.field(p, 0n), 0n), [9], T.field(p, 1n), [9], T.field(p, 2n)])

def al.mp.load(kvs: List<&2, Ev.EvKv>, +rs: List<&2, String>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      m
    case Ev.EvKv{+k, +v} <> t:
      al.mp.load(t, rs, al.mp.put(A.al.words(v), al.mp.ent(rs, k), m))

# a unit some law names: its id, fields, the index entries (laws-file), its own file's laws
type AlH is Data:
  AlH{id: List<&2, U32>, fs: List<&2, List<&2, U32>>, a1: List<&2, List<&2, U32>>, a2: List<&2, List<&2, U32>>}

type AlMt is Data:
  AlMt{m: Map<&2, List<&2, U32>>, hs: List<&2, AlH>, st: List<&2, Mu.MttKv>}

def AlMt.m(+r: AlMt) -> Map<&2, List<&2, U32>>:
  match r:
    case AlMt{m, h, s}:
      m

def AlMt.hs(+r: AlMt) -> List<&2, AlH>:
  match r:
    case AlMt{m, h, s}:
      h

def AlMt.st(+r: AlMt) -> List<&2, Mu.MttKv>:
  match r:
    case AlMt{m, h, s}:
      s

def al.own.if(go: Bool, +tail: List<&2, U32>, +name: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match go:
    case True{}:
      A.al.own(tail, name)
    case False{}:
      Nil{}

def al.bump.if(c: Bool, +st: List<&2, Mu.MttKv>, +k: String) -> List<&2, Mu.MttKv>:
  match c:
    case True{}:
      Mu.mtt.bump(st, k, 1n)
    case False{}:
      st

# a unit: a passing Bend def (not a proposition), the laws-file entries its
# key (FILE#NAME) has, and the laws after it in its own file (not a LAWS.bend)
# that name it and are proven there
def al.mt.one(+k: List<&2, U32>, +v: List<&2, U32>, +m: Map<&2, List<&2, U32>>, +hs: List<&2, AlH>, +st: List<&2, Mu.MttKv>) -> AlMt:
  +fs = Ev.ev.split(v, 30)
  +name = T.field(fs, 2n)
  +ok = Bool.and(Bool.and(S.eq(T.field(fs, 0n), S.b("bend")), Bool.not(S.eq(T.field(fs, 1n), S.b("proposition")))), S.prefix(T.field(fs, 11n), [48, 31]))
  +rel = Bd.rel.of(k, name)
  +lawsf = U.eq(A.al.basename(rel), U.b("LAWS.bend"))
  +tail = T.field(fs, 8n)
  +a2 = al.own.if(Bool.and(Bool.and(ok, Bool.not(lawsf)), U.infix(T.cat([[10], tail]), U.b("\nlaw "))), tail, name)
  +es = T.mg.got(Map.get(List<&2, U32>, Nil{}, m, T.mg.str(T.cat([rel, [35], name]))))
  +a1 = Bool.pick(List<&2, List<&2, U32>>, ok, A.al.words.go(T.split(es, 29)), Nil{})
  +h1 = Nat.is_lt(0n, X.ex.count(a1))
  +h2 = Nat.is_lt(0n, X.ex.count(a2))
  +st2 = al.bump.if(h2, al.bump.if(h1, al.bump.if(ok, Mu.mtt.bump(st, "units", 1n), "units.bend-def-passing"), "units.named.laws-file"), "units.named.same-file")
  AlMt{m, Bool.pick(List<&2, AlH>, Bool.or(h1, h2), {AlH{k, fs, a1, a2} : AlH} <> hs, hs), st2}

def al.mt.all(kvs: List<&2, Ev.EvKv>, r: AlMt) -> AlMt:
  match kvs r:
    case Nil{} x:
      x
    case Ev.EvKv{+k, +v} <> t AlMt{m, +hs, +st}:
      al.mt.all(t, al.mt.one(k, v, m, hs, st))

def al.root.got(has: Bool, +p: String, +body: List<&2, U32>) -> IO(Bool):
  match has:
    case False{}:
      IO.pure(Bool, False{})
    case True{}:
      do IO<Bool>:
        xs : List<&2, U32> <- S.read(p)
        return U.infix(xs, S.chomp(body))

# the first root whose copy of rel holds the body (as exlaw's; none: "")
def al.root(rs: List<&2, String>, +rel: String, +body: List<&2, U32>) -> IO(String):
  match rs:
    case Nil{}:
      IO.pure(String, "")
    case +r <> more:
      do IO<String>:
        +has : Bool <- S.exists(r ++ "/" ++ rel)
        +ok : Bool <- al.root.got(has, r ++ "/" ++ rel, body)
        Bool.pick(IO(String), ok, IO.pure(String, r), al.root(more, rel, body))

def al.job(+id: List<&2, U32>, +root: List<&2, U32>, +kind: String, +lf: List<&2, U32>, +l: List<&2, U32>, +c: List<&2, U32>, +refs: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  T.cat([id, [0], T.mg.join([root, Bd.repo.of(lf), S.b(kind), lf, l, c, refs, T.field(fs, 2n), T.field(fs, 6n), T.field(fs, 7n), T.field(fs, 3n)], [30]), [0]])

def al.a1.ok(+e: List<&2, U32>, +ri: List<&2, U32>) -> Bool:
  U.eq(T.field(T.split(e, 9), 0n), ri)

def al.a1.jobs(es: List<&2, List<&2, U32>>, +root: List<&2, U32>, +ri: List<&2, U32>, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match es:
    case Nil{}:
      Nil{}
    case +e <> t:
      +r = al.a1.jobs(t, root, ri, id, fs)
      +p = T.split(e, 9)
      +lf = T.field(p, 1n)
      +j = al.job(id, root, "laws-file", lf, T.field(p, 2n), T.cat([A.al.dirname(lf), U.b("/PROOF.bend")]), Nil{}, fs)
      Bool.pick(List<&2, List<&2, U32>>, al.a1.ok(e, ri), j <> r, r)

def al.a2.jobs(ls: List<&2, List<&2, U32>>, +root: List<&2, U32>, +id: List<&2, U32>, +rel: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      al.job(id, root, "same-file", rel, l, rel, Nil{}, fs) <> al.a2.jobs(t, root, id, rel, fs)

def al.mt.count(+none: Bool, +n1: Nat, +k1: Nat, +n2: Nat, +st: List<&2, Mu.MttKv>) -> List<&2, Mu.MttKv>:
  +s0 = al.bump.if(none, st, "units.no-root")
  +k = Bool.pick(Nat, none, 0n, k1)
  Mu.mtt.bump(Mu.mtt.bump(Mu.mtt.bump(s0, "jobs.laws-file", k), "laws-file.other-root", Nat.sub(n1, k)), "jobs.same-file", Bool.pick(Nat, none, 0n, n2))

def al.mt.hit(h: AlH, +rs: List<&2, String>, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match h:
    case AlH{+id, +fs, +a1, +a2}:
      +rel = Bd.rel.of(id, T.field(fs, 2n))
      do IO<List<&2, Mu.MttKv>>:
        +root : String <- al.root(rs, S.str(rel), T.field(fs, 7n))
        +rb : List<&2, U32> = S.b(root)
        +none : Bool = String.is_empty(root)
        +j1 : List<&2, List<&2, U32>> = al.a1.jobs(a1, rb, al.ridx(rs, rb, 0n), id, fs)
        +j2 : List<&2, List<&2, U32>> = al.a2.jobs(a2, rb, id, rel, fs)
        S.add(out, Bool.pick(List<&2, U32>, none, Nil{}, T.cat(List.append(&2, List<&2, U32>, j1, j2))))
        return al.mt.count(none, X.ex.count(a1), X.ex.count(j1), X.ex.count(j2), st)

def al.mt.hits(hs: List<&2, AlH>, +rs: List<&2, String>, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match hs:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, st)
    case h <> t:
      do IO<List<&2, Mu.MttKv>>:
        +st2 : List<&2, Mu.MttKv> <- al.mt.hit(h, rs, out, st)
        al.mt.hits(t, rs, out, st2)

def al.mt.parts(ps: List<String>, m: Map<&2, List<&2, U32>>, +rs: List<&2, String>, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, st)
    case +p <> t:
      do IO<List<&2, Mu.MttKv>>:
        kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(p)
        +r : AlMt = al.mt.all(kvs, AlMt{m, Nil{}, st})
        +st3 : List<&2, Mu.MttKv> <- al.mt.hits(AlMt.hs(r), rs, out, AlMt.st(r))
        IO.print("match " ++ p ++ ": " ++ Nat.show(Mu.mtt.get(st3, "units")) ++ " units so far, " ++ Nat.show(Mu.mtt.get(st3, "jobs.laws-file")) ++ " laws-file jobs, " ++ Nat.show(Mu.mtt.get(st3, "jobs.same-file")) ++ " same-file jobs")
        al.mt.parts(t, AlMt.m(r), rs, out, st3)

def al.match(+ix: String, +out: String, ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +rs : List<&2, String> <- al.roots()
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(ix)
    m : Map<&2, List<&2, U32>> = al.mp.load(kvs, rs, Map.new(&2, List<&2, U32>))
    S.write(out, Nil{})
    +st : List<&2, Mu.MttKv> <- al.mt.parts(ps, m, rs, out, Nil{})
    S.write(out ++ ".stats", Mu.mtt.kv.bytes(st))

# Plan ------------------------------------------------------------------------------------------

def al.l2(ps: List<String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      p <> al.l2(t)

def al.reads(ps: List<&2, String>) -> IO(List<&2, Ev.EvKv>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, Ev.EvKv>, Nil{})
    case +p <> t:
      do IO<List<&2, Ev.EvKv>>:
        a : List<&2, Ev.EvKv> <- Ev.ev.nul(p)
        b : List<&2, Ev.EvKv> <- al.reads(t)
        return List.append(&2, Ev.EvKv, a, b)

# a job's shard: its root and repository's
def al.shard(+v: List<&2, U32>, +w: Nat) -> Nat:
  +fs = Ev.ev.split(v, 30)
  T.roll(T.cat([T.field(fs, 0n), [9], T.field(fs, 1n)]), 7n, w)

def al.pl.recs(kvs: List<&2, Ev.EvKv>, +w: Nat, +k: Nat) -> List<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+id, +v} <> t:
      +r = al.pl.recs(t, w, k)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(al.shard(v, w), k), T.cat([id, [0], v, [0]]) <> r, r)

def al.pl.go(n: Nat, +kvs: List<&2, Ev.EvKv>, +w: Nat, +out: String) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+ +k:
      do IO<Unit>:
        +rs : List<&2, List<&2, U32>> = al.pl.recs(kvs, w, k)
        S.write(out ++ "." ++ Nat.show(k), T.cat(rs))
        IO.print("plan " ++ out ++ "." ++ Nat.show(k) ++ ": " ++ Nat.show(X.ex.count(rs)) ++ " jobs")
        al.pl.go(k, kvs, w, out)

def al.plan(+w: Nat, +out: String, ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +kvs : List<&2, Ev.EvKv> <- al.reads(al.l2(ps))
    al.pl.go(w, kvs, w, out)

# Samples ---------------------------------------------------------------------------------------

def al.repo.of(+v: List<&2, U32>) -> List<&2, U32>:
  T.field(Ev.ev.split(v, 30), 1n)

# the ids of up to n units, one a repository (in the jobs' order)
def al.pk.ids(kvs: List<&2, Ev.EvKv>, +n: Nat, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+id, +v} <> t:
      +repo = al.repo.of(v)
      +take = Bool.and(Nat.is_lt(0n, n), Bool.not(T.f3.in(seen, repo)))
      +r = al.pk.ids(t, Bool.pick(Nat, take, Nat.sub(n, 1n), n), Bool.pick(List<&2, List<&2, U32>>, take, repo <> seen, seen))
      Bool.pick(List<&2, List<&2, U32>>, take, id <> r, r)

# the jobs whose id (ids) or repository (repos) is listed
def al.pk.keep(kvs: List<&2, Ev.EvKv>, +ids: List<&2, List<&2, U32>>, +repos: List<&2, List<&2, U32>>, +neg: Bool) -> List<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+id, +v} <> t:
      +r = al.pk.keep(t, ids, repos, neg)
      +hit = Bool.or(T.f3.in(ids, id), T.f3.in(repos, al.repo.of(v)))
      Bool.pick(List<&2, List<&2, U32>>, Bool.pick(Bool, neg, Bool.not(hit), hit), T.cat([id, [0], v, [0]]) <> r, r)

# `pick N OUT JOBS..`: every job of N units, one a repository; `repos R,R.. OUT JOBS..`: every job of those repositories
def al.pick.jobs(+n: Nat, +repos: List<&2, List<&2, U32>>, +neg: Bool, +out: String, ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +kvs : List<&2, Ev.EvKv> <- al.reads(al.l2(ps))
    +ids : List<&2, List<&2, U32>> = al.pk.ids(kvs, n, Nil{})
    +rs : List<&2, List<&2, U32>> = al.pk.keep(kvs, ids, repos, neg)
    S.write(out, T.cat(rs))
    IO.print("pick " ++ out ++ ": " ++ Nat.show(X.ex.count(ids)) ++ " units, " ++ Nat.show(X.ex.count(rs)) ++ " jobs")

# Check -----------------------------------------------------------------------------------------

def al.le(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} _:
      True{}
    case _ Nil{}:
      False{}
    case +x <> xt +y <> yt:
      +r = al.le(xt, yt)
      Bool.pick(Bool, U32.is_eq(x, y), r, U32.is_lt(x, y))

# a job keyed: by root, repository, check file, law, id; its repository's and check file's keys
type AlJ is Data:
  AlJ{key: List<&2, U32>, gk: List<&2, U32>, fk: List<&2, U32>, id: List<&2, U32>, fs: List<&2, List<&2, U32>>}

def AlJ.key(+j: AlJ) -> List<&2, U32>:
  match j:
    case AlJ{k, g, f, i, s}:
      k

def AlJ.gk(+j: AlJ) -> List<&2, U32>:
  match j:
    case AlJ{k, g, f, i, s}:
      g

def AlJ.fk(+j: AlJ) -> List<&2, U32>:
  match j:
    case AlJ{k, g, f, i, s}:
      f

def AlJ.id(+j: AlJ) -> List<&2, U32>:
  match j:
    case AlJ{k, g, f, i, s}:
      i

def AlJ.fs(+j: AlJ) -> List<&2, List<&2, U32>>:
  match j:
    case AlJ{k, g, f, i, s}:
      s

def al.j.le(a: AlJ, b: AlJ) -> Bool:
  match a b:
    case AlJ{+x, g, f, i, s} AlJ{+y, h, e, n, z}:
      al.le(x, y)

def al.keyed(kvs: List<&2, Ev.EvKv>) -> List<&2, AlJ>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+id, +v} <> t:
      +fs = Ev.ev.split(v, 30)
      +g = T.cat([T.field(fs, 0n), [9], T.field(fs, 1n)])
      +f = T.cat([T.field(fs, 0n), [9], T.field(fs, 5n)])
      {AlJ{T.cat([g, [9], T.field(fs, 5n), [9], T.field(fs, 4n), [9], id]), g, f, id, fs} : AlJ} <> al.keyed(t)

def al.put.f(+cur: List<&2, AlJ>, +acc: List<&2, List<&2, AlJ>>) -> List<&2, List<&2, AlJ>>:
  Bool.pick(List<&2, List<&2, AlJ>>, Nat.is_eq(List.length(&2, AlJ, cur), 0n), acc, List.reverse(&2, AlJ, cur) <> acc)

# the sorted jobs a run per check file
def al.by.file(js: List<&2, AlJ>, +ck: List<&2, U32>, +cur: List<&2, AlJ>, +acc: List<&2, List<&2, AlJ>>) -> List<&2, List<&2, AlJ>>:
  match js:
    case Nil{}:
      List.reverse(&2, List<&2, AlJ>, al.put.f(cur, acc))
    case +j <> t:
      +k = AlJ.fk(j)
      +same = U.eq(k, ck)
      al.by.file(t, k, Bool.pick(List<&2, AlJ>, same, j <> cur, [j]), Bool.pick(List<&2, List<&2, AlJ>>, same, acc, al.put.f(cur, acc)))

def al.fgk(+f: List<&2, AlJ>) -> List<&2, U32>:
  match f:
    case Nil{}:
      Nil{}
    case +j <> t:
      AlJ.gk(j)

def al.put.g(+cur: List<&2, List<&2, AlJ>>, +acc: List<&2, List<&2, List<&2, AlJ>>>) -> List<&2, List<&2, List<&2, AlJ>>>:
  Bool.pick(List<&2, List<&2, List<&2, AlJ>>>, Nat.is_eq(List.length(&2, List<&2, AlJ>, cur), 0n), acc, List.reverse(&2, List<&2, AlJ>, cur) <> acc)

# the check files a run per repository
def al.by.repo(fs: List<&2, List<&2, AlJ>>, +ck: List<&2, U32>, +cur: List<&2, List<&2, AlJ>>, +acc: List<&2, List<&2, List<&2, AlJ>>>) -> List<&2, List<&2, List<&2, AlJ>>>:
  match fs:
    case Nil{}:
      List.reverse(&2, List<&2, List<&2, AlJ>>, al.put.g(cur, acc))
    case +f <> t:
      +k = al.fgk(f)
      +same = U.eq(k, ck)
      al.by.repo(t, k, Bool.pick(List<&2, List<&2, AlJ>>, same, f <> cur, [f]), Bool.pick(List<&2, List<&2, List<&2, AlJ>>>, same, acc, al.put.g(cur, acc)))

# a check's setting: the checker, the check's directory and file, the copy's
# src/ (the files' paths are from it), the time a check has, the checks it
# has, the law file's base name
type AlX is Data:
  AlX{bend: String, dir: String, base: String, src: String, secs: U32, cap: Nat, lb: List<&2, U32>}

def AlX.bend(+x: AlX) -> String:
  match x:
    case AlX{b, d, e, r, s, n, k}:
      b

def AlX.dir(+x: AlX) -> String:
  match x:
    case AlX{b, d, e, r, s, n, k}:
      d

def AlX.base(+x: AlX) -> String:
  match x:
    case AlX{b, d, e, r, s, n, k}:
      e

def AlX.src(+x: AlX) -> String:
  match x:
    case AlX{b, d, e, r, s, n, k}:
      r

def AlX.secs(+x: AlX) -> U32:
  match x:
    case AlX{b, d, e, r, s, n, k}:
      s

def AlX.cap(+x: AlX) -> Nat:
  match x:
    case AlX{b, d, e, r, s, n, k}:
      n

def AlX.lb(+x: AlX) -> List<&2, U32>:
  match x:
    case AlX{b, d, e, r, s, n, k}:
      k

type AlRC is Data:
  AlRC{r: A.AlR, ck: A.AlCk}

def AlRC.r(+p: AlRC) -> A.AlR:
  match p:
    case AlRC{r, c}:
      r

def AlRC.ck(+p: AlRC) -> A.AlCk:
  match p:
    case AlRC{r, c}:
      c

# the files written in the copy
def al.write.fs(fs: List<&2, A.AlF>, +src: String) -> IO(Unit):
  match fs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case A.AlF{+p, +x} <> t:
      do IO<Unit>:
        S.write(src ++ S.str(p), x)
        al.write.fs(t, src)

# one check (go), the files written first; else (the checks stop) why
def al.run1(go: Bool, +why: List<&2, U32>, +x: AlX, +ck: A.AlCk) -> IO(AlRC):
  match go:
    case False{}:
      IO.pure(AlRC, AlRC{A.AlOther{why}, ck})
    case True{}:
      do IO<AlRC>:
        al.write.fs(A.AlCk.fs(ck), AlX.src(x))
        +t0 : Nat <- Ck.ck.wall()
        +o : S.Out <- S.run(AlX.dir(x), Nil{}, AlX.secs(x), AlX.bend(x), [AlX.base(x), "--check-only"], Nil{})
        +t1 : Nat <- Ck.ck.wall()
        +said : List<&2, U32> = A.al.said(S.Out.status(o), S.Out.text(o))
        return AlRC{A.al.result(S.Out.status(o), S.Out.text(o)), A.al.ran(Nat.sub(t1, t0), said, ck)}

# the checks after the first: while one fails at a name and checks are left
def al.loop(n: Nat, r: A.AlR, +x: AlX, +ck: A.AlCk) -> IO(A.AlCk):
  match n r:
    case 1n+m A.AlLoc{+nm, +w}:
      +rm = A.al.rm(nm, w, ck)
      do IO<A.AlCk>:
        +p : AlRC <- al.run1(Bool.not(A.AlRm.stop(rm)), A.AlRm.why(rm), x, A.AlRm.ck(rm))
        al.loop(m, AlRC.r(p), x, AlRC.ck(p))
    case _ +r0:
      IO.pure(A.AlCk, A.al.finish(r0, AlX.lb(x), ck))

def al.ck.run(go: Bool, +x: AlX, +ck: A.AlCk) -> IO(A.AlCk):
  match go:
    case False{}:
      IO.pure(A.AlCk, ck)
    case True{}:
      do IO<A.AlCk>:
        +p : AlRC <- al.run1(True{}, Nil{}, x, ck)
        al.loop(AlX.cap(x), AlRC.r(p), x, AlRC.ck(p))

def al.restore(go: Bool, +fs: List<&2, A.AlF>, +src: String) -> IO(Unit):
  match go:
    case False{}:
      IO.pure(Unit, Unit{})
    case True{}:
      al.write.fs(fs, src)

# the law file's laws all standing, nothing taken out: no check comes (no
# proof, or over the size limit), so the prep's reading of every file is skipped
def al.lawnames(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      +r = al.lawnames(t)
      Bool.pick(List<&2, List<&2, U32>>, U.prefix(l, U.b("law ")), A.AlS.name(A.al.start(l)) <> r, r)

def al.lls(ls: List<&2, List<&2, U32>>) -> List<&2, A.AlL>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      {A.AlL{l, Nil{}} : A.AlL} <> al.lls(t)

def al.prep.if(go: Bool, +a1: Bool, +aliases: List<&2, List<&2, U32>>, +fs: List<&2, A.AlF>) -> A.AlCk:
  match go:
    case True{}:
      A.al.prep(a1, aliases, fs)
    case False{}:
      A.AlCk{fs, al.lls(al.lawnames(A.al.lines(A.al.fs.first(fs)))), Nil{}, Nil{}, 0n, 0n, Nil{}}

# a check over the size limit: its laws not decided yet
def al.toobig(+done: List<&2, A.AlSt>, +live: List<&2, A.AlL>, +size: Nat) -> List<&2, A.AlSt>:
  A.al.mark(live, U.b("too-big"), T.cat([U.b("not checked: its files are "), T.mg.n(size), U.b(" bytes, over TOTAL_MAX")]), done)

# the law file has no file with proofs that imports it
def al.noproof(ss: List<&2, A.AlSt>) -> List<&2, A.AlSt>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      {A.AlSt{A.AlSt.name(s), U.b("no-proof"), U.b("no PROOF.bend beside the law file, nor a file it imports, imports the law file")} : A.AlSt} <> al.noproof(t)

def al.counts(ss: List<&2, A.AlSt>, +st: List<&2, Mu.MttKv>) -> List<&2, Mu.MttKv>:
  match ss:
    case Nil{}:
      st
    case +s <> t:
      al.counts(t, Mu.mtt.bump(st, S.str(A.AlSt.st(s)), 1n))

def al.pfx(kvs: List<&2, Mu.MttKv>, +p: String, +st: List<&2, Mu.MttKv>) -> List<&2, Mu.MttKv>:
  match kvs:
    case Nil{}:
      st
    case Mu.MttKv{+k, +n} <> t:
      al.pfx(t, p, Mu.mtt.bump(st, p ++ k, n))

# a job's result record (status, why, ... as the header says)
def al.rec(+j: AlJ, +s: A.AlSt, +bl: List<&2, A.AlB>, +ims: List<&2, A.AlI>, +defs: List<&2, List<&2, U32>>, +acct: List<&2, U32>) -> List<&2, U32>:
  +fs = AlJ.fs(j)
  +b = A.al.piece(bl, 1n, T.field(fs, 4n))
  +refs = T.mg.join(A.al.refs(A.AlB.text(b), ims, T.field(fs, 3n), defs), [32])
  +imps = T.mg.join(A.al.used.imps(A.al.imp.blocks(bl), A.AlB.text(b)), [10])
  T.cat([AlJ.id(j), [0], T.mg.join([U.b("authlaw.v1"), A.AlSt.st(s), A.AlSt.why(s), T.field(fs, 2n), T.field(fs, 0n), T.field(fs, 3n), T.field(fs, 4n), A.al.spec(b), imps,
    T.field(fs, 5n), acct, refs, T.field(fs, 7n), T.field(fs, 8n), T.field(fs, 9n), T.field(fs, 10n)], [30]), [0]])

def al.emit(js: List<&2, AlJ>, +ss: List<&2, A.AlSt>, +bl: List<&2, A.AlB>, +ims: List<&2, A.AlI>, +defs: List<&2, List<&2, U32>>, +acct: List<&2, U32>, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match js:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, st)
    case +j <> t:
      +s = A.al.st.of(ss, T.field(AlJ.fs(j), 4n))
      +sn = A.AlSt.st(s)
      +sfx = Bool.pick(String, U.eq(sn, U.b("pass")), ".pass", Bool.pick(String, U.eq(sn, U.b("timeout")), ".time", ".fail"))
      do IO<List<&2, Mu.MttKv>>:
        S.add(out ++ sfx, al.rec(j, s, bl, ims, defs, acct))
        al.emit(t, ss, bl, ims, defs, acct, out, Mu.mtt.bump(st, "jobs." ++ S.str(sn), 1n))

def al.first(+f: List<&2, AlJ>) -> List<&2, List<&2, U32>>:
  match f:
    case Nil{}:
      Nil{}
    case +j <> t:
      AlJ.fs(j)

# the files with proofs found so far and the law file's alias in each
type AlPs is Data:
  AlPs{fs: List<&2, A.AlF>, als: List<&2, List<&2, U32>>, n: Nat}

def AlPs.fs(+p: AlPs) -> List<&2, A.AlF>:
  match p:
    case AlPs{f, a, n}:
      f

def AlPs.n(+p: AlPs) -> Nat:
  match p:
    case AlPs{f, a, n}:
      n

def AlPs.als(+p: AlPs) -> List<&2, List<&2, U32>>:
  match p:
    case AlPs{f, a, n}:
      a

def al.pf.add(ok: Bool, +p: List<&2, U32>, +x: List<&2, U32>, +a: List<&2, U32>, ps: AlPs) -> AlPs:
  match ok ps:
    case True{} AlPs{fs, als, n}:
      AlPs{List.append(&2, A.AlF, fs, [{A.AlF{p, x} : A.AlF}]), List.append(&2, List<&2, U32>, als, [a]), Nat.add(n, U.len(x))}
    case False{} AlPs{fs, als, n}:
      AlPs{fs, als, Nat.add(n, U.len(x))}

def al.imp.paths(ims: List<&2, A.AlI>) -> List<&2, List<&2, U32>>:
  match ims:
    case Nil{}:
      Nil{}
    case A.AlI{+a, +p} <> t:
      p <> al.imp.paths(t)

# a file's alias of the law file lf, read only when its text names lf's file (go)
def al.pf.alias(go: Bool, +x: List<&2, U32>, +p: List<&2, U32>, +lf: List<&2, U32>) -> List<&2, U32>:
  match go:
    case True{}:
      A.al.alias.of(A.al.imps(A.al.blocks(x), A.al.dirname(p)), lf)
    case False{}:
      Nil{}

# of the paths, the files that import the law file lf (other than skip), each with its alias of it
def al.pf.go(ps: List<&2, List<&2, U32>>, +src: String, +lf: List<&2, U32>, +skip: List<&2, U32>, +tmax: Nat, +acc: AlPs) -> IO(AlPs):
  match ps:
    case Nil{}:
      IO.pure(AlPs, acc)
    case +p <> t:
      do IO<AlPs>:
        +x : List<&2, U32> <- S.read(src ++ S.str(p))
        +small : Bool = Nat.is_le(Nat.add(AlPs.n(acc), U.len(x)), tmax)
        +a : List<&2, U32> = al.pf.alias(Bool.and(small, U.infix(x, A.al.basename(lf))), x, p, lf)
        +ok : Bool = Bool.and(Bool.not(T.empty(a)), Bool.and(Bool.not(U.eq(p, lf)), Bool.not(U.eq(p, skip))))
        al.pf.go(t, src, lf, skip, tmax, al.pf.add(ok, p, x, a, acc))

# a text's pieces, or none (go: the text is not over the size limit)
def al.blocks.if(go: Bool, +x: List<&2, U32>) -> List<&2, A.AlB>:
  match go:
    case True{}:
      A.al.blocks(x)
    case False{}:
      Nil{}

def al.pf.if(go: Bool, +ps: List<&2, List<&2, U32>>, +src: String, +lf: List<&2, U32>, +c: List<&2, U32>, +tmax: Nat) -> IO(AlPs):
  match go:
    case True{}:
      al.pf.go(ps, src, lf, c, tmax, AlPs{Nil{}, Nil{}, 0n})
    case False{}:
      IO.pure(AlPs, AlPs{Nil{}, Nil{}, 0n})

# a check: its files (the law file, then the check file and the files with
# proofs; a unit's own file: itself), its laws through its checks, then its
# jobs' records
def al.ck.file(+f: List<&2, AlJ>, +bend: String, +secs: U32, +cap: Nat, +tmax: Nat, +tdir: String, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  +fs = al.first(f)
  +a1 = U.eq(T.field(fs, 2n), U.b("laws-file"))
  +lf = T.field(fs, 3n)
  +c = T.field(fs, 5n)
  +src = tdir ++ "/src/"
  +lb0 = A.al.basename(lf)
  +lb = List.take(&2, U32, lb0, Nat.sub(U.len(lb0), 5n))
  +x = {AlX{bend, src ++ S.str(A.al.dirname(c)), S.str(A.al.basename(c)), src, secs, cap, lb} : AlX}
  do IO<List<&2, Mu.MttKv>>:
    +tc0 : List<&2, U32> <- S.read(src ++ S.str(c))
    +tl0 : List<&2, U32> <- S.read(src ++ S.str(lf))
    +pre : Nat = Nat.add(U.len(tc0), Bool.pick(Nat, a1, U.len(tl0), 0n))
    +ok : Bool = Nat.is_le(pre, tmax)
    +bl : List<&2, A.AlB> = al.blocks.if(ok, tl0)
    +cims : List<&2, A.AlI> = A.al.imps(al.blocks.if(ok, tc0), A.al.dirname(c))
    +a0 : List<&2, U32> = A.al.alias.of(cims, lf)
    +others : List<&2, List<&2, U32>> = Bool.pick(List<&2, List<&2, U32>>, a1, al.imp.paths(cims), Nil{})
    +pf : AlPs <- al.pf.if(ok, others, src, lf, c, tmax)
    +size : Nat = Nat.add(pre, AlPs.n(pf))
    +big : Bool = Bool.or(Bool.not(ok), Nat.is_lt(tmax, size))
    +files : List<&2, A.AlF> = Bool.pick(List<&2, A.AlF>, a1, List.append(&2, A.AlF, [{A.AlF{lf, tl0} : A.AlF}, {A.AlF{c, tc0} : A.AlF}], AlPs.fs(pf)), [{A.AlF{c, tc0} : A.AlF}])
    +aliases : List<&2, List<&2, U32>> = List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, T.empty(a0), Nil{}, [a0]), AlPs.als(pf))
    +nop : Bool = Bool.and(Bool.and(a1, ok), Nat.is_eq(X.ex.count(aliases), 0n))
    +ck0 : A.AlCk = al.prep.if(Bool.not(Bool.or(nop, big)), a1, aliases, files)
    +go : Bool = Bool.and(Bool.and(Bool.not(nop), Bool.not(big)), Nat.is_lt(0n, List.length(&2, A.AlL, A.AlCk.live(ck0))))
    +ck : A.AlCk <- al.ck.run(go, x, ck0)
    al.restore(go, files, src)
    +ss0 : List<&2, A.AlSt> = Bool.pick(List<&2, A.AlSt>, nop, al.noproof(A.al.mark(A.AlCk.live(ck), U.b("open"), Nil{}, A.AlCk.done(ck))), A.AlCk.done(ck))
    +ss : List<&2, A.AlSt> = Bool.pick(List<&2, A.AlSt>, Bool.and(big, Bool.not(nop)), al.toobig(A.AlCk.done(ck), A.AlCk.live(ck), size), ss0)
    +cs : List<&2, Mu.MttKv> = al.counts(ss, Nil{})
    +acct : List<&2, U32> = T.cat([U.b("bend "), S.b(S.str(A.al.basename(c))), U.b(" --check-only ("), T.mg.n(List.length(&2, A.AlF, files)), U.b(" files), "), T.mg.n(A.AlCk.runs(ck)), U.b(" checks, "), T.mg.n(A.AlCk.ms(ck)),
      U.b(" ms; last: "), A.AlCk.last(ck), U.b("; "), T.mg.join(List.take(&2, List<&2, U32>, A.AlCk.notes(ck), 6n), U.b("; "))])
    S.add(out ++ ".files", T.cat([T.field(fs, 0n), [9], c, [0], T.mg.join([T.field(fs, 2n), lf, T.mg.n(List.length(&2, A.AlSt, ss)), Mu.mtt.kv.bytes(cs), acct], [30]), [0]]))
    +st2 : List<&2, Mu.MttKv> = Mu.mtt.bump(Mu.mtt.bump(Mu.mtt.bump(al.pfx(cs, "laws.", st), "files", 1n), "runs", A.AlCk.runs(ck)), "ms", A.AlCk.ms(ck))
    al.emit(f, ss, bl, A.al.imps(bl, A.al.dirname(lf)), A.al.names(bl, 2n), acct, out, al.bump.if(go, st2, "files.checked"))

def al.ck.files(fs: List<&2, List<&2, AlJ>>, +bend: String, +secs: U32, +cap: Nat, +tmax: Nat, +tdir: String, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match fs:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, st)
    case f <> t:
      do IO<List<&2, Mu.MttKv>>:
        +st2 : List<&2, Mu.MttKv> <- al.ck.file(f, bend, secs, cap, tmax, tdir, out, st)
        al.ck.files(t, bend, secs, cap, tmax, tdir, out, st2)

def al.gfirst(+g: List<&2, List<&2, AlJ>>) -> List<&2, List<&2, U32>>:
  match g:
    case Nil{}:
      Nil{}
    case +f <> t:
      al.first(f)

# a repository: its .bend files copied (Mutate's copy), its check files, the copy gone
def al.ck.repo(+g: List<&2, List<&2, AlJ>>, +bend: String, +secs: U32, +cap: Nat, +tmax: Nat, +tmp: String, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  +fs = al.gfirst(g)
  +root = S.str(T.field(fs, 0n))
  +repo = S.str(T.field(fs, 1n))
  +tdir = tmp ++ "/t" ++ String.take(H.sha256(S.b(root ++ "/" ++ repo)), 10n)
  do IO<List<&2, Mu.MttKv>>:
    S.rm(tdir)
    S.mkdir(tdir)
    Mu.mtt.copy(False{}, root, tdir, repo)
    +t0 : Nat <- Ck.ck.wall()
    +st2 : List<&2, Mu.MttKv> <- al.ck.files(g, bend, secs, cap, tmax, tdir, out, st)
    +t1 : Nat <- Ck.ck.wall()
    S.rm(tdir)
    IO.print("check " ++ repo ++ ": " ++ Nat.show(List.length(&2, List<&2, AlJ>, g)) ++ " check files, " ++ Nat.show(Nat.div(Nat.sub(t1, t0), 1000n)) ++ " s; so far " ++ Nat.show(Mu.mtt.get(st2, "jobs.pass")) ++ " jobs pass of " ++ Nat.show(Nat.add(Nat.add(Mu.mtt.get(st2, "jobs.pass"), Mu.mtt.get(st2, "jobs.fail")), Mu.mtt.get(st2, "jobs.open"))) ++ "+")
    return Mu.mtt.bump(st2, "repos", 1n)

def al.ck.repos(gs: List<&2, List<&2, List<&2, AlJ>>>, +bend: String, +secs: U32, +cap: Nat, +tmax: Nat, +tmp: String, +out: String, +st: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match gs:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, st)
    case g <> t:
      do IO<List<&2, Mu.MttKv>>:
        +st2 : List<&2, Mu.MttKv> <- al.ck.repo(g, bend, secs, cap, tmax, tmp, out, st)
        S.write(out ++ ".stats", Mu.mtt.kv.bytes(st2))
        al.ck.repos(t, bend, secs, cap, tmax, tmp, out, st2)

def al.check(+inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +bend : String <- Mu.mtt.bend()
    +secs : Nat <- S.env.nat("TIMEOUT", 180n)
    +cap : Nat <- S.env.nat("CHECKS", 10n)
    +tmax : Nat <- S.env.nat("TOTAL_MAX", 3000000n)
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(inp)
    +js : List<&2, AlJ> = List.sort(~AlJ, ~al.j.le, al.keyed(kvs))
    +gs : List<&2, List<&2, List<&2, AlJ>>> = al.by.repo(al.by.file(js, Nil{}, Nil{}, Nil{}), Nil{}, Nil{}, Nil{})
    S.write(out ++ ".pass", Nil{})
    S.write(out ++ ".fail", Nil{})
    S.write(out ++ ".time", Nil{})
    S.write(out ++ ".files", Nil{})
    S.mkdir(out ++ ".d")
    +tmp : String <- S.realpath(out ++ ".d")
    +st : List<&2, Mu.MttKv> <- al.ck.repos(gs, bend, U32.from_nat(secs), cap, tmax, tmp, out, Mu.mtt.bump(Nil{}, "jobs", List.length(&2, AlJ, js)))
    S.write(out ++ ".stats", Mu.mtt.kv.bytes(st))
    S.rm(out ++ ".d")

# Stats -----------------------------------------------------------------------------------------

def al.ids(kvs: List<&2, Ev.EvKv>) -> List<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+k, +v} <> t:
      k <> al.ids(t)

def al.lawkeys(kvs: List<&2, Ev.EvKv>) -> List<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+k, +v} <> t:
      +fs = Ev.ev.split(v, 30)
      T.cat([T.field(fs, 4n), [9], T.field(fs, 5n), [9], T.field(fs, 6n)]) <> al.lawkeys(t)

def al.idlaws(kvs: List<&2, Ev.EvKv>) -> List<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+k, +v} <> t:
      +fs = Ev.ev.split(v, 30)
      T.cat([k, [9], T.field(fs, 4n), [9], T.field(fs, 5n), [9], T.field(fs, 6n)]) <> al.idlaws(t)

def al.le.of(a: List<&2, U32>, b: List<&2, U32>) -> Bool:
  al.le(a, b)

# distinct keys of a sorted list
def al.uniq(xs: List<&2, List<&2, U32>>, +prev: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +x <> t:
      al.uniq(t, x, Bool.pick(Nat, U.eq(x, prev), n, 1n+n))

def al.distinct(+xs: List<&2, List<&2, U32>>) -> Nat:
  al.uniq(List.sort(~List<&2, U32>, ~al.le.of, xs), [0], 0n)

# a record's law is stated for every input (a `for` binder), not a vector
def al.univ(+v: List<&2, U32>) -> Bool:
  A.al.for.every(T.field(Ev.ev.split(v, 30), 7n))

def al.only.univ(kvs: List<&2, Ev.EvKv>) -> List<&2, Ev.EvKv>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+k, +v} <> t:
      +r = al.only.univ(t)
      Bool.pick(List<&2, Ev.EvKv>, al.univ(v), {Ev.EvKv{k, v} : Ev.EvKv} <> r, r)

# the records whose law checks fixed inputs only
def al.only.fixed(kvs: List<&2, Ev.EvKv>) -> List<&2, Ev.EvKv>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+k, +v} <> t:
      +r = al.only.fixed(t)
      Bool.pick(List<&2, Ev.EvKv>, al.univ(v), r, {Ev.EvKv{k, v} : Ev.EvKv} <> r)

# the records ranked as the user, 11-15: the laws for every input first, then
# those that check fixed inputs, "ranked below laws that hold for every input"
# (A.al.rank), each kind in its order
def al.ranked(+kvs: List<&2, Ev.EvKv>) -> List<&2, Ev.EvKv>:
  List.append(&2, Ev.EvKv, al.only.univ(kvs), al.only.fixed(kvs))

# a check file record's ms (its account's ` checks, N ms;`)
def al.acct.ms(+a: List<&2, U32>) -> Nat:
  +i = U.find(a, U.b(" checks, "), 0n)
  +rest = List.drop(&2, U32, a, Nat.add(i, 9n))
  Maybe.default(&2, Nat, Nat.read(S.str(A.al.word(rest))), 0n)

# the check files of a kind: their count, their checks' ms (kind none: every one)
type AlNm is Data:
  AlNm{n: Nat, ms: Nat}

def al.files.ms(kvs: List<&2, Ev.EvKv>, +kind: List<&2, U32>, +n: Nat, +ms: Nat) -> AlNm:
  match kvs:
    case Nil{}:
      AlNm{n, ms}
    case Ev.EvKv{+k, +v} <> t:
      +fs = Ev.ev.split(v, 30)
      +hit = Bool.or(T.empty(kind), U.eq(T.field(fs, 0n), kind))
      al.files.ms(t, kind, Bool.pick(Nat, hit, 1n+n, n), Bool.pick(Nat, hit, Nat.add(ms, al.acct.ms(T.field(fs, 4n))), ms))

def al.pair.put(p: AlNm, +kn: String, +km: String, +st: List<&2, Mu.MttKv>) -> List<&2, Mu.MttKv>:
  match p:
    case AlNm{n, ms}:
      Mu.mtt.bump(Mu.mtt.bump(st, kn, n), km, ms)

def al.st.read(ps: List<&2, String>, +kvs: List<&2, Mu.MttKv>) -> IO(List<&2, Mu.MttKv>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, Mu.MttKv>, kvs)
    case +p <> t:
      do IO<List<&2, Mu.MttKv>>:
        xs : List<&2, U32> <- S.read(p ++ ".stats")
        al.st.read(t, Mu.mtt.kv.read(S.split.lines(xs), kvs))

def al.sfx(ps: List<&2, String>, +s: String) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      (p ++ s) <> al.sfx(t, s)

def al.stats(+out: String, ps0: List<String>) -> IO(Unit):
  +ps = al.l2(ps0)
  do IO<Unit>:
    +kv0 : List<&2, Mu.MttKv> <- al.st.read(ps, Nil{})
    +pass : List<&2, Ev.EvKv> <- al.reads(al.sfx(ps, ".pass"))
    +fail : List<&2, Ev.EvKv> <- al.reads(al.sfx(ps, ".fail"))
    +time : List<&2, Ev.EvKv> <- al.reads(al.sfx(ps, ".time"))
    +all : List<&2, Ev.EvKv> = List.concat(&2, Ev.EvKv, [pass, fail, time])
    +up : List<&2, Ev.EvKv> = al.only.univ(pass)
    +files : List<&2, Ev.EvKv> <- al.reads(al.sfx(ps, ".files"))
    +kv : List<&2, Mu.MttKv> = Mu.mtt.bump(Mu.mtt.bump(Mu.mtt.bump(Mu.mtt.bump(Mu.mtt.bump(kv0, "jobs.pass.distinct", al.distinct(al.idlaws(pass))), "units.with-a-passing-law", al.distinct(al.ids(pass))),
      "laws.distinct-passing", al.distinct(al.lawkeys(pass))), "units.with-a-job", al.distinct(al.ids(all))), "laws.distinct-in-jobs", al.distinct(al.lawkeys(all)))
    +kv2 : List<&2, Mu.MttKv> = Mu.mtt.bump(Mu.mtt.bump(Mu.mtt.bump(kv, "jobs.pass.for-every-input", al.distinct(al.idlaws(up))), "units.with-a-passing-law-for-every-input", al.distinct(al.ids(up))), "laws.distinct-passing.for-every-input", al.distinct(al.lawkeys(up)))
    +kv3 : List<&2, Mu.MttKv> = al.pair.put(al.files.ms(files, U.b("same-file"), 0n, 0n), "check-files.same-file", "ms.same-file", al.pair.put(al.files.ms(files, U.b("laws-file"), 0n, 0n), "check-files.laws-file", "ms.laws-file", kv2))
    +kv4 : List<&2, Mu.MttKv> = Mu.mtt.bump(kv3, "check-files.distinct", al.distinct(al.ids(files)))
    S.write(out, Mu.mtt.kv.bytes(kv4))
    IO.print(S.str(Mu.mtt.kv.bytes(kv4)))

def al.fks(js: List<&2, AlJ>, +k: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match js:
    case Nil{}:
      Nil{}
    case +j <> t:
      +r = al.fks(t, k)
      Bool.pick(List<&2, List<&2, U32>>, Bool.or(T.empty(k), U.eq(T.field(AlJ.fs(j), 2n), k)), AlJ.fk(j) <> r, r)

def al.gks(js: List<&2, AlJ>) -> List<&2, List<&2, U32>>:
  match js:
    case Nil{}:
      Nil{}
    case +j <> t:
      AlJ.gk(j) <> al.gks(t)

def al.jids(js: List<&2, AlJ>) -> List<&2, List<&2, U32>>:
  match js:
    case Nil{}:
      Nil{}
    case +j <> t:
      AlJ.id(j) <> al.jids(t)

# `count JOBS..`: the jobs, their units, check files (laws-file, same-file) and repositories
def al.count(ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +kvs : List<&2, Ev.EvKv> <- al.reads(al.l2(ps))
    +js : List<&2, AlJ> = al.keyed(kvs)
    IO.print("jobs " ++ Nat.show(List.length(&2, AlJ, js)) ++ "\nunits " ++ Nat.show(al.distinct(al.jids(js))) ++ "\ncheck-files " ++ Nat.show(al.distinct(al.fks(js, Nil{})))
      ++ "\ncheck-files.laws-file " ++ Nat.show(al.distinct(al.fks(js, U.b("laws-file")))) ++ "\ncheck-files.same-file " ++ Nat.show(al.distinct(al.fks(js, U.b("same-file"))))
      ++ "\nrepos " ++ Nat.show(al.distinct(al.gks(js))))

# Render ----------------------------------------------------------------------------------------

def al.fence(+x: List<&2, U32>) -> List<&2, U32>:
  T.cat([U.b("```bend\n"), X.ex.trim(x), U.b("\n```")])

# a passing record as a session: the ask (the def's name, file and doc, its
# declaration, the law as the spec), the answer (the def), the check
def al.session(+id: List<&2, U32>, +fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +name = T.field(fs, 12n)
  +path = Bd.rel.of(id, name)
  +same = U.eq(T.field(fs, 3n), U.b("same-file"))
  +doc = X.ex.trim(T.field(fs, 15n))
  +wh = Bool.pick(List<&2, U32>, same, T.cat([U.b("Later in the same file, this law names it, and the file proves it:")]),
    T.cat([U.b("The repository states this law in `"), T.field(fs, 5n), U.b("` and proves it in `"), T.field(fs, 9n), U.b("`:")]))
  +imps = T.field(fs, 8n)
  +lw = Bool.pick(List<&2, U32>, T.empty(imps), T.field(fs, 7n), T.cat([imps, U.b("\n\n"), T.field(fs, 7n)]))
  T.cat([U.b("#### "), id, U.b("\n## user\n\nAdd `"), name, U.b("` to `"), path, U.b("`."), Bool.pick(List<&2, U32>, T.empty(doc), Nil{}, T.cat([U.b("\n\n"), doc])),
    U.b("\n\n"), al.fence(S.lines.first(T.field(fs, 13n))), U.b("\n\n"), wh, U.b("\n\n"), al.fence(lw),
    U.b("\n\n## assistant\n\n"), al.fence(T.cat([T.field(fs, 13n), T.field(fs, 14n)])),
    U.b("\n\n## checker (recorded by authlaw)\n\n"), T.field(fs, 10n), U.b("\n\n")])

# up to n records, one a repository (the first of each), as sessions
def al.pick(kvs: List<&2, Ev.EvKv>, +n: Nat, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+id, +v} <> t:
      +fs = Ev.ev.split(v, 30)
      +repo = Bd.repo.of(T.field(fs, 5n))
      +take = Bool.and(Nat.is_lt(0n, n), Bool.not(T.f3.in(seen, repo)))
      +r = al.pick(t, Bool.pick(Nat, take, Nat.sub(n, 1n), n), Bool.pick(List<&2, List<&2, U32>>, take, repo <> seen, seen))
      Bool.pick(List<&2, List<&2, U32>>, take, al.session(id, fs) <> r, r)

def al.render(+inp: String, +n: Nat, +out: String) -> IO(Unit):
  do IO<Unit>:
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(inp)
    S.write(out, T.cat(al.pick(al.ranked(kvs), n, Nil{})))

# The ask ---------------------------------------------------------------------------------------

# every passing record, ranked, into the ask's map (AuthLawText.bend "The ask")
def al.askf.go(+k: U32, kvs: List<&2, Ev.EvKv>, a: A.AlAk) -> A.AlAk:
  match kvs:
    case Nil{}:
      a
    case Ev.EvKv{+id, +v} <> t:
      al.askf.go(k, t, A.al.ask.rec(k, id, Ev.ev.split(v, 30), a))

def al.askf.write(+out: String, r: List<&2, U32> & Nat & Nat & Nat) -> IO(Unit):
  match r:
    case (xs, nu, nl, nh):
      do IO<Unit>:
        S.write(out, xs)
        IO.print("authlaw ask: " ++ Nat.show(nu) ++ " units, " ++ Nat.show(nl) ++ " laws; " ++ Nat.show(nh) ++ " records left out (a held-out file's)")

def al.askf.run(+inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(inp)
    +k : Nat <- S.env.nat("VALID_K", 2n)
    al.askf.write(out, A.al.ask.done(al.askf.go(U32.from_nat(k), al.ranked(kvs), A.al.ask.new())))

# The prove units -------------------------------------------------------------------------------
#
# R7's change 6 (docs/r7/PLAN.md; the user, 11-15: "Yes" to "prove sessions from the authors'
# laws"): `authlaw prove PASS ROOT OUT`, the passing records of one root (field 4, as the check
# ran: a unit's path is its root's) walked in order, a check file read once for its run of
# records (f4's authlaw.pass keeps a file's records together), each record's unit (AuthLawText.bend
# al.pv.take) added to OUT, in Units.bend's shape for bend-check.  MAXMS (20000): the most ms its
# one check may have taken; TCAP (2): the trivial proofs (no `%` step, no `match`) a check file
# gives at most.

# the ms a record's check took (its account's ", 1 checks, N ms"; none: 0)
def al.pv.ms(+a: List<&2, U32>) -> Nat:
  +k = U.b(" checks, ")
  +r = List.drop(&2, U32, a, Nat.add(U.find(a, k, 0n), U.len(k)))
  Maybe.default(&2, Nat, Nat.read(S.str(List.take(&2, U32, r, U.find(r, [32], 0n)))), 0n)

# the walk at a record of the root: its check file read when the walk is not on it already
def al.pv.file(go: Bool, +p: List<&2, U32>, +st: A.AlPv) -> IO(A.AlPv):
  match go:
    case True{}:
      do IO<A.AlPv>:
        x : List<&2, U32> <- S.read(S.str(p))
        return A.al.pv.fresh(p, x, st)
    case False{}:
      IO.pure(A.AlPv, st)

# a record's unit added to OUT, the walk after it
def al.pv.put(+out: String, +r: A.AlPvR) -> IO(A.AlPv):
  do IO<A.AlPv>:
    S.add(out, A.AlPvR.out(r))
    return A.AlPvR.st(r)

def al.pv.one(+id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +maxms: Nat, +tcap: Nat, +out: String, +st: A.AlPv) -> IO(A.AlPv):
  +want = A.al.pv.want(fs, maxms, al.pv.ms(T.field(fs, 10n)))
  +p = A.al.pv.path(fs)
  do IO<A.AlPv>:
    st1 : A.AlPv <- al.pv.file(Bool.and(want, Bool.not(U.eq(p, A.AlPv.path(st)))), p, st)
    al.pv.put(out, A.al.pv.rec(want, id, fs, tcap, st1))

# the records in order: another root's passed by, not counted
def al.pv.mine(mine: Bool, +id: List<&2, U32>, +fs: List<&2, List<&2, U32>>, +maxms: Nat, +tcap: Nat, +out: String, +st: A.AlPv) -> IO(A.AlPv):
  match mine:
    case True{}:
      al.pv.one(id, fs, maxms, tcap, out, st)
    case False{}:
      IO.pure(A.AlPv, st)

def al.pv.go(kvs: List<&2, Ev.EvKv>, +root: List<&2, U32>, +maxms: Nat, +tcap: Nat, +out: String, +st: A.AlPv) -> IO(A.AlPv):
  match kvs:
    case Nil{}:
      IO.pure(A.AlPv, st)
    case Ev.EvKv{+id, +v} <> t:
      +fs = Ev.ev.split(v, 30)
      do IO<A.AlPv>:
        st1 : A.AlPv <- al.pv.mine(U.eq(T.field(fs, 4n), root), id, fs, maxms, tcap, out, st)
        al.pv.go(t, root, maxms, tcap, out, st1)

def al.pv.run(+inp: String, +root: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(inp)
    +maxms : Nat <- S.env.nat("MAXMS", 20000n)
    +tcap : Nat <- S.env.nat("TCAP", 2n)
    S.write(out, Nil{})
    st : A.AlPv <- al.pv.go(kvs, S.b(root), maxms, tcap, out, A.al.pv.new())
    IO.print(A.al.pv.said(st))

law al.pv.ms.reads:
  {al.pv.ms(U.b("x (1 files), 1 checks, 577 ms; last")) == 577n : Nat}

def al.pv.ms.reads():
  {==}

# Main ------------------------------------------------------------------------------------------

def al.nat(+s: String) -> Nat:
  Maybe.default(&2, Nat, Nat.read(s), 0n)

def al.main(xs: List<String>) -> IO(Unit):
  match xs:
    case "index" <> +out <> Nil{}:
      al.index(out)
    case "match" <> +ix <> +out <> ps:
      al.match(ix, out, ps)
    case "plan" <> +w <> +out <> ps:
      al.plan(al.nat(w), out, ps)
    case "pick" <> +n <> +out <> ps:
      al.pick.jobs(al.nat(n), Nil{}, False{}, out, ps)
    case "repos" <> +rs <> +out <> ps:
      al.pick.jobs(0n, A.al.words.go(T.split(S.b(rs), 44)), False{}, out, ps)
    case "except" <> +rs <> +out <> ps:
      al.pick.jobs(0n, A.al.words.go(T.split(S.b(rs), 44)), True{}, out, ps)
    case "check" <> +inp <> +out <> Nil{}:
      al.check(inp, out)
    case "count" <> ps:
      al.count(ps)
    case "stats" <> +out <> ps:
      al.stats(out, ps)
    case "render" <> +inp <> +n <> +out <> Nil{}:
      al.render(inp, al.nat(n), out)
    case "ask" <> +inp <> +out <> Nil{}:
      al.askf.run(inp, out)
    case "prove" <> +inp <> +root <> +out <> Nil{}:
      al.pv.run(inp, root, out)
    case _:
      IO.die(Unit, 2, "usage: authlaw index OUT | match INDEX OUT PART.. | plan W OUT JOBS.. | pick N OUT JOBS.. | repos R,R.. OUT JOBS.. | check JOBS OUT | stats OUT PFX.. | render PASS N OUT | ask PASS OUT | prove PASS ROOT OUT")
