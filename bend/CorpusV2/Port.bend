import Base
import ../Sys.bend as S
import ../Clock.bend as Ck
import ../Tokenizer.bend as Tk
import ../Sha256.bend as H
import ../Transcript.bend as Tr
import ./Lib.bend as L
import ./Collect.bend as C
import ./Holdout.bend as Ho
import ./Keyed.bend as K
import ./MutOps.bend as M
import ./PortOps.bend as P

# port: the Bend files a collection's loader rejected, renamed so the locked
# compiler loads them, kept when it then passes them (or fails the same
# definitions the author's compiler fails), with a repair transcript each
# (2026-10-16).
#
#   bend-corpus-v2 port CFG [STEP...]      STEP: plan check refs seed keep out; all (the default) is plan check keep out
#
# Run from the repository root.  The config (collect's grammar: a directive a
# line, `#` starts a comment):
#
#   collect DIR       the collection's output (bend-corpus-v2 collect's OUT): its
#                     stage/bend.check.tsv (the `load` rows are the files),
#                     vault/repos.txt, stage/pre/big.repos, stage/pre/new.sha,
#                     stage/keys/corpus.paths and corpus.sha
#   src DIR           its clones (collect's src; read only)
#   out DIR           the work (OUT/stage, OUT/tree) and the outputs
#   inbox DIR         the files that stay broken, a directory a repository
#   vault-known F...  earlier vaults' repository names (collect's vault-known)
#   loader PATH       the locked compiler (`timeout SECS LOADER FILE --check-only` in the
#                     file's directory, collect's verdict classes)
#   base PATH         its Base (bend2/base.bend of the source it runs)
#   base-old PATH     an older Base: a constructor only the locked one has may be a
#                     binder's name (PortOps' binder rename)
#   ref PATH...       compilers that may load an original, tried in order: the first
#                     one that loads it gives the author's failures
#   loader-secs N     (60)   procs N (4)
#   tokenizer F       (weights/code32k.bpe)   window N (2048): Transcript's fits
#
# The steps (each reads what the one before wrote):
#
#   plan   the `load` files less a vault repository's (collect's vault/repos.txt and
#          vault-known) and a held-out unit's (C3's rule on collect's units:
#          Ho.ho.held, big.repos split by directory): OUT/stage/cands.tsv, and
#          the others with their reason in OUT/stage/excluded.tsv.  A repository
#          at a time: the files with everything they import from the clones
#          (sibling links read through; a hub import is the loader's), PortOps'
#          renames on all of them, each written to OUT/tree at its path (the
#          links too): OUT/stage/plan.tsv (`path TAB changed TAB own TAB binder
#          TAB qualified TAB alias TAB seg`), OUT/stage/inv/REPO.tsv (`new TAB
#          old`, every rename of the repository's files), OUT/stage/hash.tsv
#          (`path TAB hash`: sha256 of the loader's path and of each file of the
#          candidate's closure in OUT/tree, its path and its text's sha256).
#   check  the loader on every candidate in OUT/tree (OUT/stage/check/K.port, the
#          check `STATUS 0x1F OUTPUT`; OUT/stage/check.tsv `path TAB class TAB
#          message`); the loader on the original (in src) of every changed one
#          that passes (K.orig: the error a transcript shows); each ref in turn on
#          the original of every one it fails a definition of (the first ref that
#          loads it; OUT/stage/ref.tsv `path TAB i TAB class`, a row each attempt,
#          i the ref's place in the config, kept across runs).  Every result is
#          cached in OUT/stage/cache and kept across runs: a port's by its hash
#          (p-HASH.ck), an original's by the loader and its path (o-KEY.ck), the
#          first loading ref's by its path (r-KEY.ck; the clones never change),
#          so a check after a re-plan runs the loader only on the candidates
#          whose closure changed.
#   refs   check's ref checks alone, each ref on the checked ports' originals that
#          no ref loaded and ref.tsv does not say it tried (refs added to the
#          config later run on what the earlier ones left).
#   seed   OUT/stage/check's results into the cache (a run's checks made before
#          the cache: hash.tsv anew from OUT/tree as it stands, then each K.port,
#          K.orig and K.ref under its key); then plan and check again.
#   keep   pass, or checked with the failures (PortOps' pto.fails: its Error and
#          Location lines, the port's read back through the renames) equal to
#          the original's under the first ref that loads it: OUT/stage/keep.tsv
#          (`path TAB 1|0 TAB why`).
#   out    the kept files routed as collect's pre routes them: a (repository, path)
#          the corpus has, a content key the corpus or the collection has, out;
#          then `bend-corpus-v2 raw` (the holdout lists, filler, copies, long
#          lines, generated markers): OUT/bend.jsonl, ids `port:REPO/PATH`;
#          OUT/transcripts.train.nul, a repair transcript (Transcript's format-2
#          repair turns, the whole file: User "Write the Bend file `PATH`." and
#          "This attempt fails. Fix it.", the original as the Attempt, the locked
#          loader's error on it, the port as the Term, its pass) for each kept
#          changed file that passes, whose original's error points into itself
#          and that fits the window, id `port:REPO/PATH/repair`; INBOX/REPO/ for
#          every candidate not kept: the repository's files from OUT/tree (none of
#          a held-out unit) and FAILING.tsv (`path TAB class TAB message TAB why`:
#          the loader's verdict and keep's reason), each
#          failing file's loader output beside it as PATH.err; OUT/summary.txt.
#
# Every def is prefixed `pt.`.

def pt.log(+msg: String) -> IO(Unit):
  Ck.log("port: " ++ msg)

def pt.die(+msg: String) -> IO(Unit):
  do IO<Unit>:
    pt.log(msg)
    IO.die(Unit, 1, "port: " ++ msg)

def pt.fuel() -> Nat:
  U32.to_nat(4294967295)

def pt.l1(xs: List<&2, String>) -> List<String>:
  Ho.ho.l1(xs)

def pt.unlines(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      S.append(x, 10 <> pt.unlines(t))

def pt.field(+ws: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  M.mto.nth(ws, i)

def pt.nat(+xs: List<&2, U32>) -> Nat:
  S.env.nat.got(Nat.read(S.str(xs)), 0n)

def pt.b2n(b: Bool) -> Nat:
  match b:
    case True{}:
      1n
    case False{}:
      0n

def pt.nat.in(xs: List<&2, Nat>, +x: Nat) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(Nat.is_eq(h, x), pt.nat.in(t, x))

# The context --------------------------------------------------------------------------------------

type PtCx is Data:
  PtCx{cfg: List<&2, List<&2, List<&2, U32>>>, out: String, col: String, src: String, self: String, procs: Nat}

def pt.cx.cfg(+c: PtCx) -> List<&2, List<&2, List<&2, U32>>>:
  match c:
    case PtCx{f, o, l, s, x, p}:
      f

def pt.cx.out(+c: PtCx) -> String:
  match c:
    case PtCx{f, o, l, s, x, p}:
      o

def pt.cx.col(+c: PtCx) -> String:
  match c:
    case PtCx{f, o, l, s, x, p}:
      l

def pt.cx.src(+c: PtCx) -> String:
  match c:
    case PtCx{f, o, l, s, x, p}:
      s

def pt.cx.self(+c: PtCx) -> String:
  match c:
    case PtCx{f, o, l, s, x, p}:
      x

def pt.cx.procs(+c: PtCx) -> Nat:
  match c:
    case PtCx{f, o, l, s, x, p}:
      p

def pt.st(+c: PtCx, +name: String) -> String:
  pt.cx.out(c) ++ "/stage/" ++ name

def pt.str(+c: PtCx, +d: String, +dflt: String) -> String:
  C.col.cf.str(pt.cx.cfg(c), d, dflt)

def pt.secs(+c: PtCx) -> U32:
  U32.from_nat(C.col.cf.nat(pt.cx.cfg(c), "loader-secs", 60n))

def pt.loader(+c: PtCx) -> String:
  pt.str(c, "loader", "bend")

# A file's names: the repository directory, the folded repository (collect's
# and the corpus's), its path in the repository
def pt.repo.dir(+p: List<&2, U32>) -> List<&2, U32>:
  L.v2.before(p, 47)

def pt.id(+p: List<&2, U32>) -> List<&2, U32>:
  S.append(S.b("port:"), p)

def pt.fold(+p: List<&2, U32>) -> List<&2, U32>:
  L.v2.repo.of(S.append(S.b("repo:"), p))

def pt.rel(+p: List<&2, U32>) -> List<&2, U32>:
  L.v2.path.of(S.append(S.b("repo:"), p))

# collect's unit of a file: its repository, or repository/directory when the
# repository is split by directory
def pt.unit(+bigs: Set(), +p: List<&2, U32>) -> List<&2, U32>:
  C.col.unit(bigs, pt.fold(p), pt.rel(p))

# Plan ------------------------------------------------------------------------------------------------

# the `load` rows' files, relative to src
def pt.loads(ls: List<&2, List<&2, U32>>, +pre: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +ws = S.split(l, 9)
      +rest = pt.loads(more, pre)
      +ok = Bool.and(S.eq(pt.field(ws, 1n), S.b("load")), S.prefix(pt.field(ws, 0n), pre))
      Bool.pick(List<&2, List<&2, U32>>, ok, List.drop(&2, U32, pt.field(ws, 0n), S.len(pre)) <> rest, rest)

# 0 a candidate, 1 a vault repository's, 2 a held-out unit's
def pt.why(+vault: Set(), +bigs: Set(), +p: List<&2, U32>) -> Nat:
  Bool.pick(Nat, P.pto.in(vault, pt.fold(p)), 1n, Bool.pick(Nat, Ho.ho.held(pt.unit(bigs, p)), 2n, 0n))

def pt.with.why(ps: List<&2, List<&2, U32>>, +vault: Set(), +bigs: Set(), +k: Nat) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +rest = pt.with.why(more, vault, bigs, k)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(pt.why(vault, bigs, p), k), p <> rest, rest)

# the sibling links (`find SRC -maxdepth 1 -type l -printf '%f\t%l\n'`)
def pt.links.of(ls: List<&2, List<&2, U32>>) -> List<&2, P.PtoLink>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +ws = S.split(l, 9)
      +rest = pt.links.of(more)
      Bool.pick(List<&2, P.PtoLink>, Nat.is_eq(List.length(&2, List<&2, U32>, ws), 2n), P.PtoLink{pt.field(ws, 0n), pt.field(ws, 1n)} <> rest, rest)

# the candidates by repository, in order (the list is sorted by path)
def pt.groups.go(ps: List<&2, List<&2, U32>>, +cur: List<&2, List<&2, U32>>, +dir: List<&2, U32>, +acc: List<&2, List<&2, List<&2, U32>>>) -> List<&2, List<&2, List<&2, U32>>>:
  match ps:
    case Nil{}:
      List.reverse(&2, List<&2, List<&2, U32>>, Bool.pick(List<&2, List<&2, List<&2, U32>>>, List.is_empty(&2, List<&2, U32>, cur), acc, List.reverse(&2, List<&2, U32>, cur) <> acc))
    case +p <> more:
      +d = pt.repo.dir(p)
      +same = Bool.or(S.eq(d, dir), List.is_empty(&2, List<&2, U32>, cur))
      pt.groups.go(more, Bool.pick(List<&2, List<&2, U32>>, same, p <> cur, [p]), d,
        Bool.pick(List<&2, List<&2, List<&2, U32>>>, same, acc, List.reverse(&2, List<&2, U32>, cur) <> acc))

def pt.groups(+ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, List<&2, U32>>>:
  pt.groups.go(ps, Nil{}, Nil{}, Nil{})

# The closure: the files and everything they import from the clones, a level
# of imports at a time (a file that cannot be read is passed over: the
# loader will say so)

type PtCl is Data:
  PtCl{next: List<&2, List<&2, U32>>, seen: Set(), acc: List<&2, P.PtoMod>}

def pt.imp.paths(imps: List<&2, P.PtoImp>) -> List<&2, List<&2, U32>>:
  match imps:
    case Nil{}:
      Nil{}
    case +i <> more:
      +p = P.pto.imp.path(i)
      +rest = pt.imp.paths(more)
      Bool.pick(List<&2, List<&2, U32>>, List.is_empty(&2, U32, p), rest, p <> rest)

# the paths not yet seen (each once), and the set with them
def pt.unseen(ps: List<&2, List<&2, U32>>, +seen: Set(), +acc: List<&2, List<&2, U32>>) -> PtCl:
  match ps:
    case Nil{}:
      PtCl{List.reverse(&2, List<&2, U32>, acc), seen, Nil{}}
    case +p <> more:
      +new = Bool.not(P.pto.in(seen, p))
      pt.unseen(more, Bool.pick(Set(), new, Set.add(seen, P.pto.key(p)), seen), Bool.pick(List<&2, List<&2, U32>>, new, p <> acc, acc))

def pt.cl.put(next: List<&2, List<&2, U32>>, mod: P.PtoMod, acc: List<&2, P.PtoMod>, u: PtCl) -> PtCl:
  match u:
    case PtCl{news, seen2, x}:
      PtCl{List.append(&2, List<&2, U32>, next, news), seen2, mod <> acc}

def pt.cl.add(+ls: List<&2, P.PtoLink>, +p: List<&2, U32>, m: Maybe<&2, List<&2, U32>>, s: PtCl) -> PtCl:
  match m s:
    case None{} s2:
      s2
    case Some{+t} PtCl{next, +seen, acc}:
      +mod = P.pto.mod(ls, p, t)
      pt.cl.put(next, mod, acc, pt.unseen(pt.imp.paths(P.pto.mod.imps(mod)), seen, Nil{}))

def pt.cl.file(+src: String, +ls: List<&2, P.PtoLink>, +p: List<&2, U32>, s: PtCl) -> IO(PtCl):
  do IO<PtCl>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(src ++ "/" ++ S.str(p))
    return pt.cl.add(ls, p, m, s)

def pt.cl.level(ps: List<&2, List<&2, U32>>, +src: String, +ls: List<&2, P.PtoLink>, s: PtCl) -> IO(PtCl):
  match ps:
    case Nil{}:
      IO.pure(PtCl, s)
    case +p <> more:
      IO.bind(PtCl, PtCl, pt.cl.file(src, ls, p, s), pt.cl.level(more, src, ls))

def pt.cl.go(fuel: Nat, +src: String, +ls: List<&2, P.PtoLink>, s: PtCl) -> IO(PtCl):
  match fuel s:
    case 1n+f PtCl{next, +seen, +acc}:
      IO.bind(PtCl, PtCl, pt.cl.level(next, src, ls, PtCl{Nil{}, seen, acc}), pt.cl.go(f, src, ls))
    case _ s2:
      IO.pure(PtCl, s2)

def pt.cl.mods(s: PtCl) -> List<&2, P.PtoMod>:
  match s:
    case PtCl{n, z, acc}:
      List.reverse(&2, P.PtoMod, acc)

# the modules of a group's closure, the group's files first
def pt.closure(+src: String, +ls: List<&2, P.PtoLink>, +ps: List<&2, List<&2, U32>>) -> IO(List<&2, P.PtoMod>):
  do IO<List<&2, P.PtoMod>>:
    s : PtCl <- pt.cl.go(64n, src, ls, PtCl{ps, P.pto.set(ps), Nil{}})
    return pt.cl.mods(s)

# The closure hashes: a candidate's result is the loader's on it and every
# file it imports, so it is cached by a hash of them (OUT/stage/cache, kept
# across runs): sha256 of the loader's path, then each file of the closure in
# OUT/tree (the candidate and everything it imports, read through the links)
# as its path and its text's sha256, in path order.  OUT/stage/hash.tsv:
# `path TAB hash` a candidate.

type PtLm is Data:
  PtLm{path: List<&2, U32>, h: String, imps: List<&2, List<&2, U32>>}

def pt.lm.h(+m: PtLm) -> String:
  match m:
    case PtLm{p, h, i}:
      h

def pt.lm.imps(+m: PtLm) -> List<&2, List<&2, U32>>:
  match m:
    case PtLm{p, h, i}:
      i

type PtLc is Data:
  PtLc{next: List<&2, List<&2, U32>>, seen: Set(), acc: List<&2, PtLm>}

def pt.lc.put(next: List<&2, List<&2, U32>>, m: PtLm, acc: List<&2, PtLm>, u: PtCl) -> PtLc:
  match u:
    case PtCl{news, seen2, x}:
      PtLc{List.append(&2, List<&2, U32>, next, news), seen2, m <> acc}

def pt.lc.add(+ls: List<&2, P.PtoLink>, +p: List<&2, U32>, m: Maybe<&2, List<&2, U32>>, s: PtLc) -> PtLc:
  match m s:
    case None{} s2:
      s2
    case Some{+t} PtLc{next, +seen, acc}:
      +imps = pt.imp.paths(P.pto.imps.res(P.pto.hd.imps(P.pto.header(t)), ls, p))
      pt.lc.put(next, PtLm{p, H.sha256(t), imps}, acc, pt.unseen(imps, seen, Nil{}))

def pt.lc.file(+root: String, +ls: List<&2, P.PtoLink>, +p: List<&2, U32>, s: PtLc) -> IO(PtLc):
  do IO<PtLc>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(root ++ "/" ++ S.str(p))
    return pt.lc.add(ls, p, m, s)

def pt.lc.level(ps: List<&2, List<&2, U32>>, +root: String, +ls: List<&2, P.PtoLink>, s: PtLc) -> IO(PtLc):
  match ps:
    case Nil{}:
      IO.pure(PtLc, s)
    case +p <> more:
      IO.bind(PtLc, PtLc, pt.lc.file(root, ls, p, s), pt.lc.level(more, root, ls))

def pt.lc.go(fuel: Nat, +root: String, +ls: List<&2, P.PtoLink>, s: PtLc) -> IO(PtLc):
  match fuel s:
    case 1n+f PtLc{next, +seen, +acc}:
      IO.bind(PtLc, PtLc, pt.lc.level(next, root, ls, PtLc{Nil{}, seen, acc}), pt.lc.go(f, root, ls))
    case _ s2:
      IO.pure(PtLc, s2)

def pt.lm.map(ms: List<&2, PtLm>, m: Map<&2, PtLm>) -> Map<&2, PtLm>:
  match ms:
    case Nil{}:
      m
    case PtLm{+p, h, i} <> more:
      pt.lm.map(more, Map.set(&2, PtLm, m, P.pto.key(p), PtLm{p, h, i}))

def pt.lc.map(s: PtLc) -> Map<&2, PtLm>:
  match s:
    case PtLc{n, z, acc}:
      pt.lm.map(acc, Map.new(&2, PtLm))

def pt.lm.snd(r: Map<&2, PtLm> & Bool) -> Bool:
  (m, x) = r
  x

def pt.lm.val(r: Map<&2, PtLm> & PtLm) -> PtLm:
  (m, x) = r
  x

def pt.lm.has(+m: Map<&2, PtLm>, +p: List<&2, U32>) -> Bool:
  pt.lm.snd(Map.has(&2, PtLm, m, P.pto.key(p)))

def pt.lm.get(+m: Map<&2, PtLm>, +p: List<&2, U32>) -> PtLm:
  pt.lm.val(Map.get(PtLm, PtLm{Nil{}, "", Nil{}}, m, P.pto.key(p)))

# the closure of a path: it and what it imports, transitively (paths in the map)
def pt.reach(fuel: Nat, q: List<&2, List<&2, U32>>, +m: Map<&2, PtLm>, +seen: Set(), +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match fuel q:
    case 1n+f +p <> +more:
      +new = Bool.and(Bool.not(P.pto.in(seen, p)), pt.lm.has(m, p))
      pt.reach(f, Bool.pick(List<&2, List<&2, U32>>, new, List.append(&2, List<&2, U32>, more, pt.lm.imps(pt.lm.get(m, p))), more), m,
        Bool.pick(Set(), new, Set.add(seen, P.pto.key(p)), seen), Bool.pick(List<&2, List<&2, U32>>, new, p <> acc, acc))
    case _ _:
      acc

def pt.hash.parts(ps: List<&2, List<&2, U32>>, +m: Map<&2, PtLm>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      L.v2.concat([p, [0], S.b(pt.lm.h(pt.lm.get(m, p))), [0], pt.hash.parts(more, m)])

def pt.hash(+loader: String, +m: Map<&2, PtLm>, +p: List<&2, U32>) -> String:
  H.sha256(L.v2.concat([S.b(loader), [0], pt.hash.parts(C.col.sort(pt.reach(1000000n, [p], m, Set.new(), Nil{})), m)]))

def pt.hash.lines(ps: List<&2, List<&2, U32>>, +loader: String, +m: Map<&2, PtLm>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      L.v2.concat([p, S.b("\t" ++ pt.hash(loader, m, p) ++ "\n"), pt.hash.lines(more, loader, m)])

# the group's hash.tsv lines, from OUT/tree as it stands
def pt.group.hashes(+c: PtCx, +ls: List<&2, P.PtoLink>, +g: List<&2, List<&2, U32>>) -> IO(Unit):
  do IO<Unit>:
    s : PtLc <- pt.lc.go(64n, pt.cx.out(c) ++ "/tree", ls, PtLc{g, P.pto.set(g), Nil{}})
    S.add(pt.st(c, "hash.tsv"), pt.hash.lines(g, pt.loader(c), pt.lc.map(s)))

# a plan's line, and its renames as `new TAB old` lines
def pt.plan.line(+p: P.PtoPlan) -> List<&2, U32>:
  L.v2.concat([P.pto.plan.path(p), S.b("\t" ++ Nat.show(pt.b2n(P.pto.plan.changed(p))) ++ "\t" ++ Nat.show(P.pto.plan.own(p)) ++ "\t" ++ Nat.show(P.pto.plan.binder(p))
    ++ "\t" ++ Nat.show(P.pto.plan.qual(p)) ++ "\t" ++ Nat.show(List.length(&2, P.PtoRn, P.pto.plan.alias(p))) ++ "\t" ++ Nat.show(P.pto.plan.seg(p)) ++ "\n")])

def pt.inv.lines(rs: List<&2, P.PtoRn>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case P.PtoRn{o, n} <> more:
      L.v2.concat([n, [9], o, [10], pt.inv.lines(more)])

def pt.plans.inv(ps: List<&2, P.PtoPlan>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      S.append(pt.inv.lines(P.pto.plan.all(p)), pt.plans.inv(more))

# the plans of the group's own files (the first n), as plan.tsv lines
def pt.plans.lines(ps: List<&2, P.PtoPlan>, +want: Set()) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +rest = pt.plans.lines(more, want)
      Bool.pick(List<&2, U32>, P.pto.in(want, P.pto.plan.path(p)), S.append(pt.plan.line(p), rest), rest)

def pt.write.tree(ps: List<&2, P.PtoPlan>, +tree: String) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +p <> more:
      +f = tree ++ "/" ++ S.str(P.pto.plan.path(p))
      do IO<Unit>:
        S.mkdir(S.parent(f))
        S.write(f, P.pto.plan.text(p))
        pt.write.tree(more, tree)

type PtN is Data:
  PtN{groups: Nat, mods: Nat, changed: Nat}

def pt.n.add(n: PtN, +m: Nat, +k: Nat) -> PtN:
  match n:
    case PtN{a, x, y}:
      PtN{1n+a, Nat.add(x, m), Nat.add(y, k)}

def pt.changed.n(ps: List<&2, P.PtoPlan>) -> Nat:
  match ps:
    case Nil{}:
      0n
    case +p <> more:
      Nat.add(pt.b2n(P.pto.plan.changed(p)), pt.changed.n(more))

def pt.group(+c: PtCx, +b: P.PtoBase, +ls: List<&2, P.PtoLink>, +g: List<&2, List<&2, U32>>, n: PtN) -> IO(PtN):
  +dir = S.str(pt.repo.dir(M.mto.lhd(g)))
  do IO<PtN>:
    +ms : List<&2, P.PtoMod> <- pt.closure(pt.cx.src(c), ls, g)
    +ps : List<&2, P.PtoPlan> = P.pto.plans(ms, b)
    pt.write.tree(ps, pt.cx.out(c) ++ "/tree")
    pt.group.hashes(c, ls, g)
    S.add(pt.st(c, "plan.tsv"), pt.plans.lines(ps, P.pto.set(g)))
    S.write(pt.st(c, "inv/" ++ dir ++ ".tsv"), pt.plans.inv(ps))
    +k : Nat = pt.changed.n(ps)
    pt.log("plan: " ++ dir ++ ": " ++ Nat.show(List.length(&2, List<&2, U32>, g)) ++ " files, " ++ Nat.show(List.length(&2, P.PtoMod, ms)) ++ " with their imports, " ++ Nat.show(k) ++ " renamed")
    return pt.n.add(n, List.length(&2, P.PtoMod, ms), k)

def pt.groups.run(gs: List<&2, List<&2, List<&2, U32>>>, +c: PtCx, +b: P.PtoBase, +ls: List<&2, P.PtoLink>, n: PtN) -> IO(PtN):
  match gs:
    case Nil{}:
      IO.pure(PtN, n)
    case +g <> more:
      IO.bind(PtN, PtN, pt.group(c, b, ls, g, n), pt.groups.run(more, c, b, ls))

def pt.links.make(ls: List<&2, P.PtoLink>, +tree: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case P.PtoLink{n, t} <> more:
      do IO<Unit>:
        +o : S.Out <- S.run(tree, [], 60, "ln", ["-sfn", S.str(t), S.str(n)], Nil{})
        pt.links.make(more, tree)

def pt.tagged(ps: List<&2, List<&2, U32>>, +why: String) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> more:
      L.v2.concat([p, S.b("\t" ++ why ++ "\n"), pt.tagged(more, why)])

def pt.n.show(n: PtN) -> String:
  match n:
    case PtN{a, m, k}:
      Nat.show(a) ++ " repositories, " ++ Nat.show(m) ++ " files with their imports, " ++ Nat.show(k) ++ " of them renamed"

def pt.plan(+c: PtCx) -> IO(Unit):
  +col = pt.cx.col(c)
  +src = pt.cx.src(c)
  +tree = pt.cx.out(c) ++ "/tree"
  do IO<Unit>:
    S.rm(tree)
    S.rm(pt.st(c, "inv"))
    S.mkdir(pt.st(c, "inv"))
    S.mkdir(tree)
    +rows : List<&2, List<&2, U32>> <- C.col.read.lines(col ++ "/stage/bend.check.tsv")
    +vk : List<&2, List<&2, U32>> <- C.col.files.lines((col ++ "/vault/repos.txt") <> C.col.cf.files(pt.cx.cfg(c), "vault-known"))
    +bk : List<&2, List<&2, U32>> <- C.col.read.lines(col ++ "/stage/pre/big.repos")
    +vault : Set() = P.pto.set(vk)
    +bigs : Set() = C.col.set(bk)
    +loads : List<&2, List<&2, U32>> = pt.loads(rows, S.b(src ++ "/"))
    +cands : List<&2, List<&2, U32>> = pt.with.why(loads, vault, bigs, 0n)
    S.write(pt.st(c, "cands.tsv"), pt.unlines(cands))
    S.write(pt.st(c, "excluded.tsv"), S.append(pt.tagged(pt.with.why(loads, vault, bigs, 1n), "vault"), pt.tagged(pt.with.why(loads, vault, bigs, 2n), "held out")))
    pt.log("plan: " ++ Nat.show(List.length(&2, List<&2, U32>, loads)) ++ " files the loader rejected, " ++ Nat.show(List.length(&2, List<&2, U32>, cands)) ++ " candidates (the rest a vault repository's or a held-out unit's: stage/excluded.tsv)")
    +lo : S.Out <- S.run(".", [], 600, "find", [src, "-maxdepth", "1", "-type", "l", "-printf", "%f\t%l\n"], Nil{})
    +ls : List<&2, P.PtoLink> = pt.links.of(S.split.lines(S.Out.text(lo)))
    pt.links.make(ls, tree)
    +bt : List<&2, U32> <- S.read(pt.str(c, "base", ""))
    +ot : List<&2, U32> <- S.read(pt.str(c, "base-old", ""))
    +b : P.PtoBase = P.pto.base.of(bt, ot)
    S.write(pt.st(c, "plan.tsv"), Nil{})
    S.write(pt.st(c, "hash.tsv"), Nil{})
    n : PtN <- pt.groups.run(pt.groups(cands), c, b, ls, PtN{0n, 0n, 0n})
    pt.log("plan: " ++ pt.n.show(n))

# Check -----------------------------------------------------------------------------------------------

def pt.class(+r: C.ColRes) -> String:
  C.col.class(C.col.res.status(r), S.split.lines(C.col.res.text(r)))

# the check as a field: STATUS 0x1F OUTPUT
def pt.ck(+r: C.ColRes) -> List<&2, U32>:
  L.v2.concat([S.b(U32.show(C.col.res.status(r))), [31], C.col.res.text(r)])

def pt.ck.status(+ck: List<&2, U32>) -> U32:
  U32.from_nat(pt.nat(L.v2.before(ck, 31)))

def pt.ck.text(+ck: List<&2, U32>) -> List<&2, U32>:
  L.v2.after(ck, 31)

def pt.ck.class(+ck: List<&2, U32>) -> String:
  C.col.class(pt.ck.status(ck), S.split.lines(pt.ck.text(ck)))

# a job: the loader on the file at root/p (k its index)
def pt.job(+loader: String, +secs: U32, +root: String, +p: List<&2, U32>, +k: Nat) -> C.ColJob:
  +f = root ++ "/" ++ S.str(p)
  C.ColJob{k, 2n, [C.ColCmd{S.parent(f), ["LC_ALL=C"], secs, loader, [S.base(f), "--check-only"], ""}]}

# the jobs of the files whose index is in ks (an ascending list), in order
def pt.jobs(ps: List<&2, List<&2, U32>>, +ks: List<&2, Nat>, +k: Nat, +loader: String, +secs: U32, +root: String) -> List<&2, C.ColJob>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +rest = pt.jobs(more, ks, 1n+k, loader, secs, root)
      Bool.pick(List<&2, C.ColJob>, pt.nat.in(ks, k), pt.job(loader, secs, root, p, k) <> rest, rest)

def pt.upto(n: Nat, +k: Nat) -> List<&2, Nat>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      k <> pt.upto(m, 1n+k)

def pt.save(rs: List<&2, C.ColRes>, +dir: String, +suffix: String) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> more:
      do IO<Unit>:
        S.write(dir ++ "/" ++ Nat.show(C.col.res.n(r)) ++ suffix, pt.ck(r))
        pt.save(more, dir, suffix)

def pt.rows(rs: List<&2, C.ColRes>, +ps: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      L.v2.concat([M.mto.nth(ps, C.col.res.n(r)), [9], C.col.verdict(C.col.res.status(r), C.col.res.text(r)), [10], pt.rows(more, ps)])

def pt.ks.class(rs: List<&2, C.ColRes>, +cls: String) -> List<&2, Nat>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      +rest = pt.ks.class(more, cls)
      Bool.pick(List<&2, Nat>, String.eq(pt.class(r), cls), C.col.res.n(r) <> rest, rest)

def pt.ks.loaded(rs: List<&2, C.ColRes>, +yes: Bool) -> List<&2, Nat>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      +rest = pt.ks.loaded(more, yes)
      +cls = pt.class(r)
      +loaded = Bool.or(String.eq(cls, "pass"), String.eq(cls, "checked"))
      Bool.pick(List<&2, Nat>, Bool.xor(loaded, yes), rest, C.col.res.n(r) <> rest)

def pt.nats.and(xs: List<&2, Nat>, +ys: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      +rest = pt.nats.and(more, ys)
      Bool.pick(List<&2, Nat>, pt.nat.in(ys, x), x <> rest, rest)

# the plan's changed files (plan.tsv's paths whose second field is 1)
def pt.changed.of(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +ws = S.split(l, 9)
      +rest = pt.changed.of(more)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(pt.field(ws, 1n), S.b("1")), pt.field(ws, 0n) <> rest, rest)

def pt.ks.in(ps: List<&2, List<&2, U32>>, +s: Set(), +k: Nat) -> List<&2, Nat>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +rest = pt.ks.in(more, s, 1n+k)
      Bool.pick(List<&2, Nat>, P.pto.in(s, p), k <> rest, rest)

def pt.ref.rows(rs: List<&2, C.ColRes>, +ps: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      L.v2.concat([M.mto.nth(ps, C.col.res.n(r)), S.b("\t" ++ Nat.show(i) ++ "\t" ++ pt.class(r) ++ "\n"), pt.ref.rows(more, ps, i)])

def pt.keep.loaded(rs: List<&2, C.ColRes>) -> List<&2, C.ColRes>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      +rest = pt.keep.loaded(more)
      +cls = pt.class(r)
      Bool.pick(List<&2, C.ColRes>, Bool.or(String.eq(cls, "pass"), String.eq(cls, "checked")), r <> rest, rest)

# ref.tsv holds a row an attempt (`path TAB i TAB class`, i the ref's place in
# the config): an original is loaded when a row of it says pass or checked
def pt.row.loaded(+l: List<&2, U32>) -> Bool:
  +cls = pt.field(S.split(l, 9), 2n)
  Bool.or(S.eq(cls, S.b("pass")), S.eq(cls, S.b("checked")))

def pt.ref.loaded(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +rest = pt.ref.loaded(more)
      Bool.pick(List<&2, List<&2, U32>>, pt.row.loaded(l), L.v2.before(l, 9) <> rest, rest)

def pt.ref.tried(ls: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +rest = pt.ref.tried(more, i)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(pt.field(S.split(l, 9), 1n), S.b(Nat.show(i))), L.v2.before(l, 9) <> rest, rest)

# the indices of ks whose original no ref loaded yet and ref i has not tried
def pt.ks.todo(ks: List<&2, Nat>, +ps: List<&2, List<&2, U32>>, +done: Set(), +tried: Set()) -> List<&2, Nat>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> more:
      +p = M.mto.nth(ps, k)
      +rest = pt.ks.todo(more, ps, done, tried)
      Bool.pick(List<&2, Nat>, Bool.or(P.pto.in(done, p), P.pto.in(tried, p)), rest, k <> rest)

# The cache (OUT/stage/cache): a port's check by its closure hash (p-HASH.ck),
# an original's under the loader by the loader and its path (o-KEY.ck: the
# clones never change), the first ref's that loads an original by its path
# (r-KEY.ck; ref.tsv says which ref)
def pt.cache(+c: PtCx) -> String:
  pt.st(c, "cache")

def pt.hm.of(ls: List<&2, List<&2, U32>>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      m
    case +l <> more:
      pt.hm.of(more, Map.set(&2, List<&2, U32>, m, P.pto.key(L.v2.before(l, 9)), L.v2.after(l, 9)))

def pt.hm.val(r: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, U32>:
  (m, x) = r
  x

def pt.ck.port(+c: PtCx, +hm: Map<&2, List<&2, U32>>, +p: List<&2, U32>) -> String:
  pt.cache(c) ++ "/p-" ++ S.str(pt.hm.val(Map.get(List<&2, U32>, Nil{}, hm, P.pto.key(p)))) ++ ".ck"

def pt.ck.orig(+c: PtCx, +p: List<&2, U32>) -> String:
  pt.cache(c) ++ "/o-" ++ H.sha256(L.v2.concat([S.b(pt.loader(c)), [0], p])) ++ ".ck"

def pt.ck.ref(+c: PtCx, +p: List<&2, U32>) -> String:
  pt.cache(c) ++ "/r-" ++ H.sha256(p) ++ ".ck"

# a job's result into its cache file (name: the file's path to its cache file)
def pt.save.to(rs: List<&2, C.ColRes>, +ps: List<&2, List<&2, U32>>, +c: PtCx, +hm: Map<&2, List<&2, U32>>, +kind: Nat) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> more:
      +p = M.mto.nth(ps, C.col.res.n(r))
      +f = Bool.pick(String, Nat.is_eq(kind, 0n), pt.ck.port(c, hm, p), Bool.pick(String, Nat.is_eq(kind, 1n), pt.ck.orig(c, p), pt.ck.ref(c, p)))
      do IO<Unit>:
        S.write(f, pt.ck(r))
        pt.save.to(more, ps, c, hm, kind)

# the indices of ks whose cache file is missing
def pt.missing(ks: List<&2, Nat>, +ps: List<&2, List<&2, U32>>, +c: PtCx, +hm: Map<&2, List<&2, U32>>, +kind: Nat, +acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  match ks:
    case Nil{}:
      IO.pure(List<&2, Nat>, List.reverse(&2, Nat, acc))
    case +k <> more:
      +p = M.mto.nth(ps, k)
      +f = Bool.pick(String, Nat.is_eq(kind, 0n), pt.ck.port(c, hm, p), pt.ck.orig(c, p))
      do IO<List<&2, Nat>>:
        there : Bool <- S.exists(f)
        pt.missing(more, ps, c, hm, kind, Bool.pick(List<&2, Nat>, there, acc, k <> acc))

# each of ks from the cache into check/K.SUFFIX, and as a job's result
def pt.fill(ks: List<&2, Nat>, +ps: List<&2, List<&2, U32>>, +c: PtCx, +hm: Map<&2, List<&2, U32>>, +kind: Nat, +suffix: String, acc: List<&2, C.ColRes>) -> IO(List<&2, C.ColRes>):
  match ks:
    case Nil{}:
      IO.pure(List<&2, C.ColRes>, List.reverse(&2, C.ColRes, acc))
    case +k <> more:
      +p = M.mto.nth(ps, k)
      +f = Bool.pick(String, Nat.is_eq(kind, 0n), pt.ck.port(c, hm, p), pt.ck.orig(c, p))
      do IO<List<&2, C.ColRes>>:
        +ck : List<&2, U32> <- S.read(f)
        S.write(pt.st(c, "check/" ++ Nat.show(k) ++ suffix), ck)
        pt.fill(more, ps, c, hm, kind, suffix, C.ColRes{k, pt.ck.status(ck), pt.ck.text(ck)} <> acc)

# the loader on the files of ks not in the cache (kind 0 the ports in the
# tree, 1 the originals in the clones), then every one of ks from the cache
def pt.cached(+what: String, +ks: List<&2, Nat>, +ps: List<&2, List<&2, U32>>, +c: PtCx, +hm: Map<&2, List<&2, U32>>, +kind: Nat, +root: String, +suffix: String) -> IO(List<&2, C.ColRes>):
  do IO<List<&2, C.ColRes>>:
    +miss : List<&2, Nat> <- pt.missing(ks, ps, c, hm, kind, Nil{})
    pt.log("check: " ++ what ++ ": " ++ Nat.show(List.length(&2, Nat, ks)) ++ " files, " ++ Nat.show(Nat.sub(List.length(&2, Nat, ks), List.length(&2, Nat, miss))) ++ " in the cache, the loader on " ++ Nat.show(List.length(&2, Nat, miss)) ++ ", " ++ Nat.show(pt.cx.procs(c)) ++ " at once")
    +rs : List<&2, C.ColRes> <- C.col.pool("check: " ++ what, pt.cx.procs(c), pt.jobs(ps, miss, 0n, pt.loader(c), pt.secs(c), root))
    pt.save.to(rs, ps, c, hm, kind)
    pt.fill(ks, ps, c, hm, kind, suffix, Nil{})
# each ref in turn on the checked ports' originals no earlier ref loaded
# (resumable: what ref.tsv says was tried is not tried again)
def pt.refs(refs: List<&2, List<&2, U32>>, +c: PtCx, +ps: List<&2, List<&2, U32>>, +ks: List<&2, Nat>, +i: Nat) -> IO(Unit):
  match refs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> more:
      do IO<Unit>:
        +rl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "ref.tsv"))
        +todo : List<&2, Nat> = pt.ks.todo(ks, ps, P.pto.set(pt.ref.loaded(rl)), P.pto.set(pt.ref.tried(rl, i)))
        +rs : List<&2, C.ColRes> <- C.col.pool("check: ref " ++ Nat.show(i) ++ " on the originals", pt.cx.procs(c), pt.jobs(ps, todo, 0n, S.str(r), pt.secs(c), pt.cx.src(c)))
        +got : List<&2, C.ColRes> = pt.keep.loaded(rs)
        pt.save.to(got, ps, c, Map.new(&2, List<&2, U32>), 2n)
        S.add(pt.st(c, "ref.tsv"), pt.ref.rows(rs, ps, i))
        pt.log("check: ref " ++ Nat.show(i) ++ " (" ++ S.str(r) ++ ") loads " ++ Nat.show(List.length(&2, C.ColRes, got)) ++ " of " ++ Nat.show(List.length(&2, Nat, todo)) ++ " originals")
        pt.refs(more, c, ps, ks, 1n+i)

def pt.count(rs: List<&2, C.ColRes>, +cls: String) -> Nat:
  List.length(&2, Nat, pt.ks.class(rs, cls))

def pt.check(+c: PtCx) -> IO(Unit):
  +dir = pt.st(c, "check")
  do IO<Unit>:
    +ps : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "cands.tsv"))
    +pl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "plan.tsv"))
    +hl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "hash.tsv"))
    +hm : Map<&2, List<&2, U32>> = pt.hm.of(hl, Map.new(&2, List<&2, U32>))
    S.rm(dir)
    S.mkdir(dir)
    S.mkdir(pt.cache(c))
    +n : Nat = List.length(&2, List<&2, U32>, ps)
    +rs : List<&2, C.ColRes> <- pt.cached("the ports", pt.upto(n, 0n), ps, c, hm, 0n, pt.cx.out(c) ++ "/tree", ".port")
    S.write(pt.st(c, "check.tsv"), pt.rows(rs, ps))
    pt.log("check: pass " ++ Nat.show(pt.count(rs, "pass")) ++ ", checked " ++ Nat.show(pt.count(rs, "checked")) ++ ", load " ++ Nat.show(pt.count(rs, "load")) ++ ", timeout " ++ Nat.show(pt.count(rs, "timeout")))
    +ch : List<&2, Nat> = pt.ks.in(ps, P.pto.set(pt.changed.of(pl)), 0n)
    +os : List<&2, Nat> = pt.nats.and(pt.ks.class(rs, "pass"), ch)
    +ro : List<&2, C.ColRes> <- pt.cached("the originals of changed files that pass", os, ps, c, hm, 1n, pt.cx.src(c), ".orig")
    pt.refs(C.col.cf.all(pt.cx.cfg(c), "ref"), c, ps, pt.ks.class(rs, "checked"), 0n)

# the indices of check.tsv's rows of class cls
def pt.ks.rows(ls: List<&2, List<&2, U32>>, +cls: List<&2, U32>, +k: Nat) -> List<&2, Nat>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +rest = pt.ks.rows(more, cls, 1n+k)
      Bool.pick(List<&2, Nat>, S.eq(pt.field(S.split(l, 9), 1n), cls), k <> rest, rest)

# refs: the ref checks alone (check's last part), the refs ref.tsv has not tried
def pt.refs.step(+c: PtCx) -> IO(Unit):
  do IO<Unit>:
    +ps : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "cands.tsv"))
    +cl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "check.tsv"))
    pt.refs(C.col.cf.all(pt.cx.cfg(c), "ref"), c, ps, pt.ks.rows(cl, S.b("checked"), 0n), 0n)


# seed: the results OUT/stage/check holds (a run's, before a re-plan) into the
# cache, each port by its closure's hash in OUT/tree as it stands (hash.tsv is
# written anew from it), each original's and ref's by its path
def pt.seed.put(+f: String, m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.pure(Unit, Unit{})
    case Some{x}:
      S.write(f, x)

def pt.seed.one(+c: PtCx, +hm: Map<&2, List<&2, U32>>, +p: List<&2, U32>, +k: Nat, u: Unit) -> IO(Unit):
  +base = pt.st(c, "check/" ++ Nat.show(k))
  do IO<Unit>:
    a : Maybe<&2, List<&2, U32>> <- S.slurp(base ++ ".port")
    pt.seed.put(pt.ck.port(c, hm, p), a)
    b : Maybe<&2, List<&2, U32>> <- S.slurp(base ++ ".orig")
    pt.seed.put(pt.ck.orig(c, p), b)
    r : Maybe<&2, List<&2, U32>> <- S.slurp(base ++ ".ref")
    pt.seed.put(pt.ck.ref(c, p), r)

def pt.seed.go(ps: List<&2, List<&2, U32>>, +c: PtCx, +hm: Map<&2, List<&2, U32>>, +k: Nat, u: Unit) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, u)
    case +p <> more:
      IO.bind(Unit, Unit, pt.seed.one(c, hm, p, k, u), pt.seed.go(more, c, hm, 1n+k))

def pt.hashes.go(gs: List<&2, List<&2, List<&2, U32>>>, +c: PtCx, +ls: List<&2, P.PtoLink>, u: Unit) -> IO(Unit):
  match gs:
    case Nil{}:
      IO.pure(Unit, u)
    case +g <> more:
      IO.bind(Unit, Unit, pt.group.hashes(c, ls, g), pt.hashes.go(more, c, ls))

def pt.links(+c: PtCx) -> IO(List<&2, P.PtoLink>):
  do IO<List<&2, P.PtoLink>>:
    +lo : S.Out <- S.run(".", [], 600, "find", [pt.cx.src(c), "-maxdepth", "1", "-type", "l", "-printf", "%f\t%l\n"], Nil{})
    return pt.links.of(S.split.lines(S.Out.text(lo)))

def pt.seed(+c: PtCx) -> IO(Unit):
  do IO<Unit>:
    +ps : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "cands.tsv"))
    +ls : List<&2, P.PtoLink> <- pt.links(c)
    S.write(pt.st(c, "hash.tsv"), Nil{})
    pt.hashes.go(pt.groups(ps), c, ls, Unit{})
    +hl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "hash.tsv"))
    S.mkdir(pt.cache(c))
    pt.seed.go(ps, c, pt.hm.of(hl, Map.new(&2, List<&2, U32>)), 0n, Unit{})
    pt.log("seed: the checks of " ++ Nat.show(List.length(&2, List<&2, U32>, ps)) ++ " candidates into " ++ pt.cache(c))
# Keep ------------------------------------------------------------------------------------------------

# a ref.tsv's paths (the originals some ref loaded)
def pt.firsts(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      L.v2.before(l, 9) <> pt.firsts(more)

def pt.inv.of(ls: List<&2, List<&2, U32>>) -> List<&2, P.PtoRn>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      P.PtoRn{L.v2.before(l, 9), L.v2.after(l, 9)} <> pt.inv.of(more)

type PtKeep is Data:
  PtKeep{ok: Bool, why: String}

# a checked port against its original under the first ref that loads it
def pt.judge.checked(+port: List<&2, U32>, has: Bool, +ref: List<&2, U32>, +inv: List<&2, P.PtoRn>) -> PtKeep:
  match has:
    case False{}:
      PtKeep{False{}, "checked; no ref loads the original"}
    case True{}:
      +a = P.pto.fails(pt.ck.text(port), inv)
      +b = P.pto.fails(pt.ck.text(ref), Nil{})
      +same = Bool.and(P.pto.texts.eq(a, b), Bool.not(List.is_empty(&2, List<&2, U32>, a)))
      Bool.pick(PtKeep, same, PtKeep{True{}, "checked, the author's failures"},
        Bool.pick(PtKeep, String.eq(pt.ck.class(ref), "pass"), PtKeep{False{}, "checked; the original passes under the ref"}, PtKeep{False{}, "checked; other failures than the original's under the ref"}))

def pt.judge(+cls: String, +port: List<&2, U32>, has: Bool, +ref: List<&2, U32>, +inv: List<&2, P.PtoRn>) -> PtKeep:
  Bool.pick(PtKeep, String.eq(cls, "pass"), PtKeep{True{}, "pass"},
    Bool.pick(PtKeep, String.eq(cls, "checked"), pt.judge.checked(port, has, ref, inv), PtKeep{False{}, cls}))

def pt.keep.line(+p: List<&2, U32>, k: PtKeep) -> List<&2, U32>:
  match k:
    case PtKeep{ok, why}:
      L.v2.concat([p, S.b("\t" ++ Nat.show(pt.b2n(ok)) ++ "\t" ++ why ++ "\n")])

def pt.keep.one(+c: PtCx, +refd: Set(), +p: List<&2, U32>, +k: Nat, +acc: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  +base = pt.st(c, "check/" ++ Nat.show(k))
  +has = P.pto.in(refd, p)
  do IO<List<&2, List<&2, U32>>>:
    +port : List<&2, U32> <- S.read(base ++ ".port")
    +ref : List<&2, U32> <- Bool.pick(IO(List<&2, U32>), has, S.read(pt.ck.ref(c, p)), IO.pure(List<&2, U32>, Nil{}))
    +il : List<&2, List<&2, U32>> <- Bool.pick(IO(List<&2, List<&2, U32>>), has, C.col.read.lines(pt.st(c, "inv/" ++ S.str(pt.repo.dir(p)) ++ ".tsv")), IO.pure(List<&2, List<&2, U32>>, Nil{}))
    +line : List<&2, U32> = pt.keep.line(p, pt.judge(pt.ck.class(port), port, has, ref, pt.inv.of(il)))
    return line <> acc

def pt.keep.go(ps: List<&2, List<&2, U32>>, +c: PtCx, +refd: Set(), +k: Nat, acc: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, List.reverse(&2, List<&2, U32>, acc))
    case +p <> more:
      IO.bind(List<&2, List<&2, U32>>, List<&2, List<&2, U32>>, pt.keep.one(c, refd, p, k, acc), pt.keep.go(more, c, refd, 1n+k))

def pt.kept.n(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> more:
      Nat.add(pt.b2n(S.eq(pt.field(S.split(l, 9), 1n), S.b("1"))), pt.kept.n(more))

def pt.keep(+c: PtCx) -> IO(Unit):
  do IO<Unit>:
    +ps : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "cands.tsv"))
    +rl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "ref.tsv"))
    +ls : List<&2, List<&2, U32>> <- pt.keep.go(ps, c, P.pto.set(pt.ref.loaded(rl)), 0n, Nil{})
    +out : List<&2, U32> = L.v2.concat(ls)
    S.write(pt.st(c, "keep.tsv"), out)
    pt.log("keep: " ++ Nat.show(pt.kept.n(S.split.lines(out))) ++ " of " ++ Nat.show(List.length(&2, List<&2, U32>, ps)) ++ " ported files kept (stage/keep.tsv)")

# Out -------------------------------------------------------------------------------------------------

def pt.kept.of(ls: List<&2, List<&2, U32>>, +want: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +ws = S.split(l, 9)
      +rest = pt.kept.of(more, want)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(pt.field(ws, 1n), want), pt.field(ws, 0n) <> rest, rest)

# Route: each kept file's (repository, path) and content key, against the
# corpus's and the collection's (sort and comm, as collect's pre)
def pt.keys.one(+tree: String, +rd: String, +p: List<&2, U32>, u: Unit) -> IO(Unit):
  do IO<Unit>:
    +t : List<&2, U32> <- S.read(tree ++ "/" ++ S.str(p))
    +k : String = L.v2.key(t)
    S.add(rd ++ "/cand.paths.u", L.v2.concat([pt.fold(p), [9], pt.rel(p), [10]]))
    S.add(rd ++ "/cand.sha.u", S.b(k ++ "\n"))
    S.add(rd ++ "/keys.tsv", L.v2.concat([p, S.b("\t" ++ k ++ "\n")]))

def pt.keys.go(ps: List<&2, List<&2, U32>>, +tree: String, +rd: String, u: Unit) -> IO(Unit):
  match ps:
    case Nil{}:
      IO.pure(Unit, u)
    case +p <> more:
      IO.bind(Unit, Unit, pt.keys.one(tree, rd, p, u), pt.keys.go(more, tree, rd))

# a file's fate: 0 train, 1 a path the corpus has, 2 a content key the corpus
# has, 3 one the collection has
def pt.fate(+hp: Set(), +h1: Set(), +h2: Set(), +p: List<&2, U32>, +k: List<&2, U32>) -> Nat:
  Bool.pick(Nat, P.pto.in(hp, L.v2.concat([pt.fold(p), [9], pt.rel(p)])), 1n, Bool.pick(Nat, P.pto.in(h1, k), 2n, Bool.pick(Nat, P.pto.in(h2, k), 3n, 0n)))

def pt.fate.name(n: Nat) -> String:
  match n:
    case 0n:
      "train"
    case 1n:
      "path in the corpus"
    case 2n:
      "copy of the corpus"
    case _:
      "copy of the collection"

def pt.route.one(+tree: String, +rd: String, +hp: Set(), +h1: Set(), +h2: Set(), +l: List<&2, U32>, u: Unit) -> IO(Unit):
  +p = L.v2.before(l, 9)
  +f = pt.fate(hp, h1, h2, p, L.v2.after(l, 9))
  do IO<Unit>:
    S.add(rd ++ "/route.tsv", L.v2.concat([p, S.b("\t" ++ pt.fate.name(f) ++ "\n")]))
    +t : List<&2, U32> <- Bool.pick(IO(List<&2, U32>), Nat.is_eq(f, 0n), S.read(tree ++ "/" ++ S.str(p)), IO.pure(List<&2, U32>, Nil{}))
    Bool.pick(IO(Unit), Nat.is_eq(f, 0n), S.add(rd ++ "/cand.jsonl", L.v2.py.line(pt.id(p), t)), IO.pure(Unit, Unit{}))

def pt.route.go(ls: List<&2, List<&2, U32>>, +tree: String, +rd: String, +hp: Set(), +h1: Set(), +h2: Set(), u: Unit) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, u)
    case +l <> more:
      IO.bind(Unit, Unit, pt.route.one(tree, rd, hp, h1, h2, l, u), pt.route.go(more, tree, rd, hp, h1, h2))

def pt.route(+c: PtCx, +kept: List<&2, List<&2, U32>>) -> IO(Unit):
  +rd = pt.st(c, "route")
  +col = pt.cx.col(c) ++ "/stage"
  +tree = pt.cx.out(c) ++ "/tree"
  do IO<Unit>:
    S.rm(rd)
    S.mkdir(rd)
    S.write(rd ++ "/cand.paths.u", Nil{})
    S.write(rd ++ "/cand.sha.u", Nil{})
    S.write(rd ++ "/keys.tsv", Nil{})
    S.write(rd ++ "/route.tsv", Nil{})
    S.write(rd ++ "/cand.jsonl", Nil{})
    pt.keys.go(kept, tree, rd, Unit{})
    C.col.sortf(rd, ["-u"], rd ++ "/cand.paths", [rd ++ "/cand.paths.u"])
    C.col.sortf(rd, ["-u"], rd ++ "/cand.sha", [rd ++ "/cand.sha.u"])
    C.col.c.to("comm paths", "comm", ["-12", rd ++ "/cand.paths", col ++ "/keys/corpus.paths"], rd ++ "/hit.paths")
    C.col.c.to("comm corpus keys", "comm", ["-12", rd ++ "/cand.sha", col ++ "/keys/corpus.sha"], rd ++ "/hit.corpus.sha")
    C.col.c.to("comm collection keys", "comm", ["-12", rd ++ "/cand.sha", col ++ "/pre/new.sha"], rd ++ "/hit.new.sha")
    +hp : List<&2, List<&2, U32>> <- C.col.read.lines(rd ++ "/hit.paths")
    +h1 : List<&2, List<&2, U32>> <- C.col.read.lines(rd ++ "/hit.corpus.sha")
    +h2 : List<&2, List<&2, U32>> <- C.col.read.lines(rd ++ "/hit.new.sha")
    +ks : List<&2, List<&2, U32>> <- C.col.read.lines(rd ++ "/keys.tsv")
    pt.route.go(ks, tree, rd, P.pto.set(hp), P.pto.set(h1), P.pto.set(h2), Unit{})
    pt.log("out: route: " ++ Nat.show(List.length(&2, List<&2, U32>, ks)) ++ " kept files; a path the corpus has " ++ Nat.show(List.length(&2, List<&2, U32>, hp))
      ++ ", a content key the corpus has " ++ Nat.show(List.length(&2, List<&2, U32>, h1)) ++ ", one the collection has " ++ Nat.show(List.length(&2, List<&2, U32>, h2)) ++ " (stage/route/route.tsv)")

# The ids of a JSONL file, a line at a time
type PtIds is Type:
  PtIds{r: S.Rd, acc: List<&2, List<&2, U32>>, more: Bool}

def pt.ids.got(+acc: List<&2, List<&2, U32>>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(PtIds):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(PtIds, PtIds{r, acc, False{}})
    case Some{+l}:
      IO.pure(PtIds, PtIds{r, K.kor.line.id(l) <> acc, True{}})

def pt.ids.step(s: PtIds) -> IO(PtIds):
  match s:
    case PtIds{r, +acc, more}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, PtIds, S.Rd.next(r), pt.ids.got(acc))

def pt.ids.go(fuel: Nat, s: PtIds) -> IO(PtIds):
  match fuel s:
    case 1n+f PtIds{r, acc, True{}}:
      IO.bind(PtIds, PtIds, pt.ids.step(PtIds{r, acc, True{}}), pt.ids.go(f))
    case _ z:
      IO.pure(PtIds, z)

def pt.ids.fin(s: PtIds) -> IO(List<&2, List<&2, U32>>):
  match s:
    case PtIds{r, acc, more}:
      do IO<List<&2, List<&2, U32>>>:
        S.Rd.close(r)
        return List.reverse(&2, List<&2, U32>, acc)

def pt.ids(+path: String) -> IO(List<&2, List<&2, U32>>):
  do IO<List<&2, List<&2, U32>>>:
    r : S.Rd <- S.Rd.lines(path)
    s : PtIds <- pt.ids.go(pt.fuel(), PtIds{r, Nil{}, True{}})
    pt.ids.fin(s)

# Transcripts: the whole file as format 2's repair (its Context and Type
# empty: a file has none), the record's fields as bend-check writes them
def pt.fs(+rel: List<&2, U32>, +port: List<&2, U32>, +pck: List<&2, U32>, +orig: List<&2, U32>, +ock: List<&2, U32>) -> List<&2, List<&2, U32>>:
  [S.b("bend"), S.b("definition"), rel, L.v2.concat([S.b("Write the Bend file `"), rel, S.b("`.")]), Nil{}, Nil{}, Nil{}, port, Nil{}, Nil{}, Nil{}, pck, Nil{}, Nil{}, Nil{}, orig, ock]

def pt.render(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  L.v2.concat([Tr.user2(fs, 1n), Tr.attempt(fs, Tr.mutant(fs, 0n)), Tr.check.turn(fs, Tr.mutant.check(fs, 0n)), Tr.answer(fs)])

type PtW is Data:
  PtW{bpe: Tk.Bpe, lim: Nat}

def pt.fits(+w: PtW, +text: List<&2, U32>) -> Bool:
  match w:
    case PtW{b, lim}:
      Tr.fits(b, lim, text)

def pt.win(+tok: String, +lim: Nat, m: Maybe<&2, Tk.Bpe>) -> IO(PtW):
  match m:
    case Some{b}:
      IO.pure(PtW, PtW{b, lim})
    case None{}:
      IO.die(PtW, 1, "port: the tokenizer " ++ tok ++ " does not parse")

# the index of each candidate, by path
def pt.index.go(ps: List<&2, List<&2, U32>>, +k: Nat, m: Map<&2, Nat>) -> Map<&2, Nat>:
  match ps:
    case Nil{}:
      m
    case +p <> more:
      pt.index.go(more, 1n+k, Map.set(&2, Nat, m, P.pto.key(p), k))

def pt.index.val(r: Map<&2, Nat> & Nat) -> Nat:
  (m, x) = r
  x

def pt.index.of(+m: Map<&2, Nat>, +p: List<&2, U32>) -> Nat:
  pt.index.val(Map.get(Nat, 0n, m, P.pto.key(p)))

# 0 written, 1 no repair (unchanged, not a pass, no original's error), 2 the
# error points elsewhere (an import), 3 over the window
def pt.tr.why(+changed: Bool, +pck: List<&2, U32>, +ock: List<&2, U32>, +orig: List<&2, U32>) -> Nat:
  +ok = Bool.and(Bool.and(changed, String.eq(pt.ck.class(pck), "pass")), Bool.not(List.is_empty(&2, U32, ock)))
  Bool.pick(Nat, Bool.not(ok), 1n, Bool.pick(Nat, P.pto.at.self(pt.ck.text(ock), orig), 0n, 2n))

def pt.tr.fit(fit: Bool, +text: List<&2, U32>) -> List<&2, U32>:
  match fit:
    case True{}:
      text
    case False{}:
      Nil{}

# a text over 16 bytes a token of the window is left out untokenized (code
# runs 3 to 4 bytes a code32k token)
def pt.tr.short(short: Bool, +w: PtW, +text: List<&2, U32>) -> List<&2, U32>:
  match short:
    case True{}:
      pt.tr.fit(pt.fits(w, text), text)
    case False{}:
      Nil{}

def pt.w.lim(+w: PtW) -> Nat:
  match w:
    case PtW{b, lim}:
      lim

# the transcript (empty: none, or over the window)
def pt.tr.text(ok: Bool, +w: PtW, +fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ok:
    case True{}:
      +t = pt.render(fs)
      pt.tr.short(Nat.is_le(S.len(t), Nat.mul(16n, pt.w.lim(w))), w, t)
    case False{}:
      Nil{}

def pt.tr.one(+c: PtCx, +w: PtW, +idx: Map<&2, Nat>, +ch: Set(), +id: List<&2, U32>, acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  +p = List.drop(&2, U32, id, 5n)
  +base = pt.st(c, "check/" ++ Nat.show(pt.index.of(idx, p)))
  +changed = P.pto.in(ch, p)
  do IO<List<&2, Nat>>:
    +pck : List<&2, U32> <- S.read(base ++ ".port")
    m : Maybe<&2, List<&2, U32>> <- S.slurp(base ++ ".orig")
    +ock : List<&2, U32> = S.slurp.or(m)
    +orig : List<&2, U32> <- S.read(pt.cx.src(c) ++ "/" ++ S.str(p))
    +port : List<&2, U32> <- S.read(pt.cx.out(c) ++ "/tree/" ++ S.str(p))
    +why0 : Nat = pt.tr.why(changed, pck, ock, orig)
    +text : List<&2, U32> = pt.tr.text(Nat.is_eq(why0, 0n), w, pt.fs(pt.rel(p), port, pck, orig, ock))
    +why : Nat = Bool.pick(Nat, Bool.and(Nat.is_eq(why0, 0n), List.is_empty(&2, U32, text)), 3n, why0)
    Bool.pick(IO(Unit), Nat.is_eq(why, 0n), S.add(pt.cx.out(c) ++ "/transcripts.train.nul", L.v2.concat([id, S.b("/repair"), [0], text, [0]])), IO.pure(Unit, Unit{}))
    return why <> acc

def pt.tr.go(ids: List<&2, List<&2, U32>>, +c: PtCx, +w: PtW, +idx: Map<&2, Nat>, +ch: Set(), acc: List<&2, Nat>) -> IO(List<&2, Nat>):
  match ids:
    case Nil{}:
      IO.pure(List<&2, Nat>, acc)
    case +i <> more:
      IO.bind(List<&2, Nat>, List<&2, Nat>, pt.tr.one(c, w, idx, ch, i, acc), pt.tr.go(more, c, w, idx, ch))

def pt.nats.count(xs: List<&2, Nat>, +k: Nat) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +x <> more:
      Nat.add(pt.b2n(Nat.is_eq(x, k)), pt.nats.count(more, k))

# The inbox: a repository a directory, its files from the tree (none of a
# vault repository or a held-out unit), the failing ones listed in
# FAILING.tsv (`path TAB class TAB message TAB why`, the path in the repository) with
# their loader output beside them (PATH.err)

# check.tsv's rows of the paths in s
def pt.rows.in(ls: List<&2, List<&2, U32>>, +s: Set()) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +rest = pt.rows.in(more, s)
      Bool.pick(List<&2, List<&2, U32>>, P.pto.in(s, L.v2.before(l, 9)), l <> rest, rest)

# keep.tsv's reasons by path, and a check.tsv row with its file's reason after it
def pt.why.of(ls: List<&2, List<&2, U32>>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      m
    case +l <> more:
      pt.why.of(more, Map.set(&2, List<&2, U32>, m, P.pto.key(L.v2.before(l, 9)), pt.field(S.split(l, 9), 2n)))

def pt.rows.why(ls: List<&2, List<&2, U32>>, +wm: Map<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      L.v2.concat([l, [9], pt.hm.val(Map.get(List<&2, U32>, Nil{}, wm, P.pto.key(L.v2.before(l, 9))))]) <> pt.rows.why(more, wm)

# the rows of the repository dir
def pt.rows.dir(ls: List<&2, List<&2, U32>>, +dir: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      +rest = pt.rows.dir(more, dir)
      Bool.pick(List<&2, List<&2, U32>>, S.eq(pt.repo.dir(l), dir), l <> rest, rest)

def pt.rows.rel(ls: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      List.drop(&2, U32, l, n) <> pt.rows.rel(more, n)

def pt.ok.files(ps: List<&2, List<&2, U32>>, +vault: Set(), +bigs: Set()) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +rest = pt.ok.files(more, vault, bigs)
      Bool.pick(List<&2, String>, Nat.is_eq(pt.why(vault, bigs, p), 0n), S.str(p) <> rest, rest)

def pt.errs(rows: List<&2, List<&2, U32>>, +c: PtCx, +idx: Map<&2, Nat>, +inbox: String) -> IO(Unit):
  match rows:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> more:
      +p = L.v2.before(l, 9)
      do IO<Unit>:
        +ck : List<&2, U32> <- S.read(pt.st(c, "check/" ++ Nat.show(pt.index.of(idx, p)) ++ ".port"))
        S.mkdir(S.parent(inbox ++ "/" ++ S.str(p)))
        S.write(inbox ++ "/" ++ S.str(p) ++ ".err", pt.ck.text(ck))
        pt.errs(more, c, idx, inbox)

def pt.inbox.repo(+c: PtCx, +idx: Map<&2, Nat>, +rows: List<&2, List<&2, U32>>, +vault: Set(), +bigs: Set(), +inbox: String, +dir: List<&2, U32>, u: Unit) -> IO(Unit):
  +tree = pt.cx.out(c) ++ "/tree"
  +d = S.str(dir)
  +mine = pt.rows.dir(rows, dir)
  do IO<Unit>:
    +fo : S.Out <- S.run(tree, [], 600, "find", [d, "-name", "*.bend", "-type", "f"], Nil{})
    +fs : List<&2, String> = pt.ok.files(C.col.nonempty(S.split.lines(S.Out.text(fo))), vault, bigs)
    S.mkdir(inbox ++ "/" ++ d)
    +co : S.Out <- S.run(tree, [], 3600, "cp", pt.l1(List.append(&2, String, ["--parents", "-t", inbox], fs)), Nil{})
    S.write(inbox ++ "/" ++ d ++ "/FAILING.tsv", pt.unlines(pt.rows.rel(mine, 1n+S.len(dir))))
    pt.errs(mine, c, idx, inbox)

def pt.inbox.go(ds: List<&2, List<&2, U32>>, +c: PtCx, +idx: Map<&2, Nat>, +rows: List<&2, List<&2, U32>>, +vault: Set(), +bigs: Set(), +inbox: String, u: Unit) -> IO(Unit):
  match ds:
    case Nil{}:
      IO.pure(Unit, u)
    case +d <> more:
      IO.bind(Unit, Unit, pt.inbox.repo(c, idx, rows, vault, bigs, inbox, d, u), pt.inbox.go(more, c, idx, rows, vault, bigs, inbox))

def pt.dirs(ps: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      pt.repo.dir(p) <> pt.dirs(more)

# Out and the summary ---------------------------------------------------------------------------------

def pt.count.lines(ls: List<&2, List<&2, U32>>, +col: Nat, +v: List<&2, U32>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> more:
      Nat.add(pt.b2n(S.eq(pt.field(S.split(l, 9), col), v)), pt.count.lines(more, col, v))

def pt.gate.ok(ok: Bool, +g: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      pt.die("out: the raw gate failed (see " ++ g ++ ".log)")

def pt.out(+c: PtCx) -> IO(Unit):
  +out = pt.cx.out(c)
  +gate = pt.st(c, "gate")
  +inbox = pt.str(c, "inbox", "")
  +col = pt.cx.col(c)
  do IO<Unit>:
    +ps : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "cands.tsv"))
    +kl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "keep.tsv"))
    +kept : List<&2, List<&2, U32>> = pt.kept.of(kl, S.b("1"))
    +failed : List<&2, List<&2, U32>> = pt.kept.of(kl, S.b("0"))
    pt.route(c, kept)
    S.rm(gate)
    +st : U32 <- S.run.log(".", pt.l1(["JOBS=" ++ Nat.show(pt.cx.procs(c)), "RAW_CHUNK=100000000"]), 2000000, pt.cx.self(c), pt.l1(["raw", gate, pt.st(c, "route/cand.jsonl")]), gate ++ ".log")
    pt.gate.ok(U32.is_eq(st, 0), gate)
    +gs : List<&2, U32> <- S.read(gate ++ "/summary.txt")
    pt.log("out: gate: " ++ S.str(S.chomp(gs)))
    C.col.cp.maybe(gate ++ "/bend.jsonl", out ++ "/bend.jsonl")
    +ids : List<&2, List<&2, U32>> <- pt.ids(out ++ "/bend.jsonl")
    +bz : Nat <- S.size(out ++ "/bend.jsonl")
    pt.log("out: " ++ out ++ "/bend.jsonl: " ++ Nat.show(List.length(&2, List<&2, U32>, ids)) ++ " files, " ++ C.col.mb(bz) ++ " MB")
    S.write(out ++ "/transcripts.train.nul", Nil{})
    +tok : String = pt.str(c, "tokenizer", "weights/code32k.bpe")
    tx : List<&2, U32> <- S.read(tok)
    +w : PtW <- pt.win(tok, Nat.sub(C.col.cf.nat(pt.cx.cfg(c), "window", 2048n), 64n), Tk.Bpe.parse(tx))
    +pl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "plan.tsv"))
    +idx : Map<&2, Nat> = pt.index.go(ps, 0n, Map.new(&2, Nat))
    +whys : List<&2, Nat> <- pt.tr.go(ids, c, w, idx, P.pto.set(pt.changed.of(pl)), Nil{})
    +tz : Nat <- S.size(out ++ "/transcripts.train.nul")
    pt.log("out: transcripts: " ++ Nat.show(pt.nats.count(whys, 0n)) ++ " written (" ++ C.col.mb(tz) ++ " MB); none for " ++ Nat.show(pt.nats.count(whys, 1n)) ++ " (unchanged, not a pass, or no error of the original), "
      ++ Nat.show(pt.nats.count(whys, 2n)) ++ " (the original's error is in an import), " ++ Nat.show(pt.nats.count(whys, 3n)) ++ " (over the window)")
    +cl : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "check.tsv"))
    +rows : List<&2, List<&2, U32>> = pt.rows.why(pt.rows.in(cl, P.pto.set(failed)), pt.why.of(kl, Map.new(&2, List<&2, U32>)))
    +vk : List<&2, List<&2, U32>> <- C.col.files.lines((col ++ "/vault/repos.txt") <> C.col.cf.files(pt.cx.cfg(c), "vault-known"))
    +bk : List<&2, List<&2, U32>> <- C.col.read.lines(col ++ "/stage/pre/big.repos")
    +ds : List<&2, List<&2, U32>> = C.col.uniq(pt.dirs(failed))
    S.rm(inbox)
    S.mkdir(inbox)
    +ia : String <- S.realpath(inbox)
    pt.inbox.go(ds, c, idx, rows, P.pto.set(vk), C.col.set(bk), ia, Unit{})
    S.write(ia ++ "/README.txt", S.b("Bend files bend-corpus-v2 port could not recover (bend/CorpusV2/Port.bend): a directory a repository, its files as the port left them (the renames applied; none of a vault repository or a held-out unit), REPO/FAILING.tsv a failing file a line (path in the repository, the locked loader's class and first message, the port's reason: load, timeout, checked with failures other than the original's under the first upstream compiler that loads it, checked where the original passes under one, checked where no upstream compiler loads the original), and each failing file's whole loader output beside it as PATH.err. A fix must pass, or fail only where the author's code fails, under the locked compiler (run/gcroot-bend/bin/bend FILE --check-only, run in the file's directory), and must not delete or weaken a definition or a law.\n"))
    +rt : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "route/route.tsv"))
    +ex : List<&2, List<&2, U32>> <- C.col.read.lines(pt.st(c, "excluded.tsv"))
    +sm : List<&2, U32> = S.b("port (bend-corpus-v2 port)\n"
      ++ "candidates           " ++ Nat.show(List.length(&2, List<&2, U32>, ps)) ++ " (the loader's rejects less " ++ Nat.show(pt.count.lines(ex, 1n, S.b("vault"))) ++ " of vault repositories and " ++ Nat.show(pt.count.lines(ex, 1n, S.b("held out"))) ++ " of held-out units)\n"
      ++ "check (the ports)    pass " ++ Nat.show(pt.count.lines(cl, 1n, S.b("pass"))) ++ ", checked " ++ Nat.show(pt.count.lines(cl, 1n, S.b("checked"))) ++ ", load " ++ Nat.show(pt.count.lines(cl, 1n, S.b("load"))) ++ ", timeout " ++ Nat.show(pt.count.lines(cl, 1n, S.b("timeout"))) ++ "\n"
      ++ "kept                 " ++ Nat.show(List.length(&2, List<&2, U32>, kept)) ++ " (pass " ++ Nat.show(pt.count.lines(kl, 2n, S.b("pass"))) ++ ", checked with the author's failures " ++ Nat.show(pt.count.lines(kl, 2n, S.b("checked, the author's failures"))) ++ ")\n"
      ++ "route                train " ++ Nat.show(pt.count.lines(rt, 1n, S.b("train"))) ++ ", path in the corpus " ++ Nat.show(pt.count.lines(rt, 1n, S.b("path in the corpus"))) ++ ", copy of the corpus " ++ Nat.show(pt.count.lines(rt, 1n, S.b("copy of the corpus"))) ++ ", copy of the collection " ++ Nat.show(pt.count.lines(rt, 1n, S.b("copy of the collection"))) ++ "\n"
      ++ "gate                 " ++ S.str(S.chomp(gs)) ++ "\n"
      ++ "bend.jsonl           " ++ Nat.show(List.length(&2, List<&2, U32>, ids)) ++ " files, " ++ C.col.mb(bz) ++ " MB JSONL\n"
      ++ "transcripts          " ++ Nat.show(pt.nats.count(whys, 0n)) ++ " (" ++ C.col.mb(tz) ++ " MB); none: no repair " ++ Nat.show(pt.nats.count(whys, 1n)) ++ ", error in an import " ++ Nat.show(pt.nats.count(whys, 2n)) ++ ", over the window " ++ Nat.show(pt.nats.count(whys, 3n)) ++ "\n"
      ++ "inbox                " ++ Nat.show(List.length(&2, List<&2, U32>, ds)) ++ " repositories, " ++ Nat.show(List.length(&2, List<&2, U32>, failed)) ++ " failing files (" ++ inbox ++ ")\n")
    S.write(out ++ "/summary.txt", sm)
    IO.print(S.str(sm))

# Main ------------------------------------------------------------------------------------------------

def pt.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 port CFG [STEP...]   (STEP: plan check keep out all; see bend/CorpusV2/Port.bend)")

def pt.step(+s: String, +c: PtCx) -> IO(Unit):
  Bool.pick(IO(Unit), String.eq(s, "plan"), pt.plan(c), Bool.pick(IO(Unit), String.eq(s, "check"), pt.check(c), Bool.pick(IO(Unit), String.eq(s, "refs"), pt.refs.step(c), Bool.pick(IO(Unit), String.eq(s, "seed"), pt.seed(c),
    Bool.pick(IO(Unit), String.eq(s, "keep"), pt.keep(c), Bool.pick(IO(Unit), String.eq(s, "out"), pt.out(c), pt.usage()))))))

def pt.steps(xs: List<String>, +c: PtCx) -> IO(Unit):
  match xs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +s <> more:
      do IO<Unit>:
        pt.log("step " ++ s)
        pt.step(s, c)
        pt.steps(more, c)

def pt.all.of(isall: Bool, xs: List<String>) -> List<String>:
  match isall:
    case True{}:
      ["plan", "check", "keep", "out"]
    case False{}:
      xs

# the steps (none, or `all`: every one)
def pt.all(xs: List<String>) -> List<String>:
  match xs:
    case Nil{}:
      ["plan", "check", "keep", "out"]
    case +s <> more:
      pt.all.of(String.eq(s, "all"), s <> more)

def pt.run(+path: String, steps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +cs : List<&2, List<&2, List<&2, U32>>> <- C.col.load(path)
    self : String <- C.col.self()
    +c : PtCx = PtCx{cs, C.col.cf.str(cs, "out", ""), C.col.cf.str(cs, "collect", ""), C.col.cf.str(cs, "src", ""), self, C.col.cf.nat(cs, "procs", 4n)}
    +ok : Bool = Bool.and(Bool.and(Bool.not(String.is_empty(pt.cx.out(c))), Bool.not(String.is_empty(pt.cx.col(c)))), Bool.and(Bool.not(String.is_empty(pt.cx.src(c))), Bool.not(String.is_empty(pt.str(c, "inbox", "")))))
    Bool.pick(IO(Unit), ok, pt.steps(pt.all(steps), c), IO.die(Unit, 2, "port: the config needs collect, src, out and inbox"))

# `port CFG [STEP...]`
def pt.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +a <> more:
      pt.run(a, more)
    case Nil{}:
      pt.usage()
