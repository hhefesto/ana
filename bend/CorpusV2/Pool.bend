import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ./Lib.bend as L

# Corpus v2's pool and filler (docs/CORPUS-V2.md, C3 and C4), the old
# tools/corpus-v2/pool.py and filler.py byte for byte.
#
#   pool [OUT]            the checked units of run 1, one set per language, split
#                         by the v2 holdout: OUT/LANG.{train,holdout}.nul and
#                         OUT/summary.txt (OUT: run/v2/results)
#   filler [OUT [RES]]    the source files run 1's units were cut from, each once,
#                         less the held-out ones: OUT/LANG/files-{hi,lo}.nul,
#                         OUT/LANG/results.holdout.nul (a copy of RES's) and
#                         OUT/filler.keys (OUT: run/v2/transcripts, RES:
#                         run/v2/results)
#
# Run from the repository root.  One Bend process evaluates on one core, so
# each tool fans its work out over processes of its own binary (argv[0]) with
# the internal subcommands pool-want, pool-part, pool-lang, filler-part and
# filler-lang, in a work directory OUT.work that it removes when it is done.
# Every name here starts with `po.` or `fi.` (a program's defs share one namespace).

# Shared --------------------------------------------------------------------------

def po.big() -> Nat:
  U32.to_nat(4294967295)

def po.langs() -> List<&2, String>:
  ["haskell", "agda", "lean", "nix", "bend"]

def po.waves() -> List<&2, String>:
  ["run/transcripts-final", "run/transcripts-next", "run/transcripts-w1", "run/transcripts-w2", "run/transcripts-w3", "run/transcripts-w4"]

# the languages in four chains of about equal work (at most four processes run
# at once): the largest alone, the two smallest together
def po.chains() -> List<&2, List<&2, String>>:
  [["bend"], ["haskell"], ["lean"], ["agda", "nix"]]

def po.spaces(n: Nat) -> String:
  String.concat(List.replicate(String, n, " "))

# Python's {:Nd} and {:N}
def po.rj(+w: Nat, n: Nat) -> String:
  +s = Nat.show(n)
  po.spaces(Nat.sub(w, String.length(s))) ++ s

def po.lj(+w: Nat, +s: String) -> String:
  s ++ po.spaces(Nat.sub(w, String.length(s)))

def po.nat.got(m: Maybe<&2, Nat>) -> Nat:
  match m:
    case Some{n}:
      n
    case None{}:
      0n

def po.nat(+xs: List<&2, U32>) -> Nat:
  po.nat.got(Nat.read(S.str(S.chomp(xs))))

def po.or.nil(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case None{}:
      Nil{}
    case Some{t}:
      t

def po.nuls(xs: List<&2, String>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      List.append(&2, U32, S.b(x), 0 <> po.nuls(more))

# A NUL file's (id, text) pairs, as Python's `split(b"\0")` paired them: a
# last id without its text (an odd number of fields) pairs with "".
type PoPr is Data:
  PoPr{id: List<&2, U32>, text: List<&2, U32>}

def po.next.text(+i: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(S.Rd & Maybe<&2, PoPr>):
  (r, m) = x
  IO.pure(S.Rd & Maybe<&2, PoPr>, (r, Some{PoPr{i, po.or.nil(m)}}))

def po.next.id.m(r: S.Rd, m: Maybe<&2, List<&2, U32>>) -> IO(S.Rd & Maybe<&2, PoPr>):
  match m:
    case None{}:
      IO.pure(S.Rd & Maybe<&2, PoPr>, (r, None{}))
    case Some{i}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, S.Rd & Maybe<&2, PoPr>, S.Rd.next(r), po.next.text(i))

def po.next.id(x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(S.Rd & Maybe<&2, PoPr>):
  (r, m) = x
  po.next.id.m(r, m)

def po.next(r: S.Rd) -> IO(S.Rd & Maybe<&2, PoPr>):
  IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, S.Rd & Maybe<&2, PoPr>, S.Rd.next(r), po.next.id)

# a shell line that must succeed (LC_ALL=C: byte order, as Python sorts)
def po.sh.ok(ok: Bool, +what: String, +o: S.Out) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, what ++ " failed: " ++ S.str(S.lines.take(S.Out.text(o), 20n)))

def po.sh(+what: String, +script: String, args: List<String>) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(".", ["LC_ALL=C"], 86400, "sh", List.append(&1, String, ["-c", script, "sh"], args), Nil{})
    po.sh.ok(U32.is_eq(S.Out.status(o), 0), what, o)

def po.strs(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> po.strs(more)

# Fan-out: this binary's subcommands as processes, their output in a log
def po.self.run(+self: String, args: List<String>, +log: String) -> IO(U32):
  S.run.log(".", [], 86400, self, args, log)

def po.join(chs: List<Chan(Nat)>, +bad: Nat) -> IO(Nat):
  match chs:
    case Nil{}:
      IO.pure(Nat, bad)
    case ch <> more:
      do IO<Nat>:
        +n : Nat <- IO.join(Nat, ch)
        po.join(more, Nat.add(bad, n))

def po.bad(+st: U32) -> Nat:
  Bool.pick(Nat, U32.is_eq(st, 0), 0n, 1n)

def po.check.if(ok: Bool, +what: String, +bad: Nat) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, what ++ ": " ++ Nat.show(bad) ++ " process(es) failed (see the logs in the work directory)")

def po.check(+what: String, +bad: Nat) -> IO(Unit):
  po.check.if(Nat.is_eq(bad, 0n), what, bad)

# the program as invoked
def po.self.of(xs: List<String>) -> String:
  match xs:
    case Nil{}:
      "bend-corpus-v2"
    case x <> more:
      x

def po.self() -> IO(String):
  do IO<String>:
    argv : List<String> <- IO.args()
    return po.self.of(argv)

def po.arg(xs: List<String>, +i: Nat, d: String) -> String:
  match xs i:
    case Nil{} _:
      d
    case x <> more 0n:
      x
    case x <> more 1n+k:
      po.arg(more, k, d)

def po.read.lines(+path: String) -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    xs : List<&2, U32> <- S.read(path)
    return L.v2.lines.str(S.split.lines(xs))

# Pool --------------------------------------------------------------------------
#
# 1. pool-want WORK LANG (a process per language): the units run 1 was
#    given, a transcript id being UNIT/SHAPE or UNIT+/repair, into
#    WORK/want.LANG (the ids, NUL ended) and WORK/units.LANG (how many).
# 2. Their records: every run/transcripts*/*/results.{train,holdout}.nul in
#    sorted order, the first record of an id winning.  Four pool-part
#    processes take a contiguous run of the files each and spool the first
#    record (in their run) of each wanted id as `id 0x01 record` NUL items into
#    WORK/spool.LANG.K.
# 3. Each language's spools, sorted by id, stable (`sort -z -s -t 0x01 -k1,1`,
#    LC_ALL=C: Python's bytes order; an id's earliest run first).
# 4. pool-lang: in id order, an id's first item only; a unit whose
#    declaration (sha256 of fields 0, 4 and 7, NUL between) an earlier one
#    gave is a duplicate; the rest go to the holdout (held by the id) or train.

# the unit of a transcript id: before its last '/', less trailing '+'s
def po.plus.drop(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      po.plus.drop(t, L.v2.head.is(t, 43))
    case r _:
      r

def po.unit.cut(+xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, L.v2.has(xs, 47), L.v2.parent(xs, 47), xs)

def po.unit(+tid: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, po.unit.cut(tid))
  List.reverse(&2, U32, po.plus.drop(r, L.v2.head.is(r, 43)))

# 1. the wanted units ---------------------------------------------------------

type PoWs is Type:
  PoWs{r: S.Rd, s: Set(), go: Bool}

def po.want.got(s: Set(), x: S.Rd & Maybe<&2, PoPr>) -> IO(PoWs):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(PoWs, PoWs{r, s, False{}})
    case Some{PoPr{i, t}}:
      IO.pure(PoWs, PoWs{r, Set.add(s, S.str(po.unit(i))), True{}})

def po.want.step(w: PoWs) -> IO(PoWs):
  match w:
    case PoWs{r, s, g}:
      IO.bind(S.Rd & Maybe<&2, PoPr>, PoWs, po.next(r), po.want.got(s))

def po.want.go(fuel: Nat, w: PoWs) -> IO(PoWs):
  match fuel w:
    case 1n+f PoWs{r, s, True{}}:
      IO.bind(PoWs, PoWs, po.want.step(PoWs{r, s, True{}}), po.want.go(f))
    case _ PoWs{r, s, g}:
      IO.pure(PoWs, PoWs{r, s, g})

def po.want.fin(w: PoWs) -> IO(Set()):
  match w:
    case PoWs{r, s, g}:
      do IO<Set()>:
        S.Rd.close(r)
        return s

def po.want.open(ok: Bool, +path: String, s: Set()) -> IO(Set()):
  match ok:
    case False{}:
      IO.pure(Set(), s)
    case True{}:
      do IO<Set()>:
        r : S.Rd <- S.Rd.open(path)
        w : PoWs <- po.want.go(po.big(), PoWs{r, s, True{}})
        po.want.fin(w)

def po.want.file(+path: String, s: Set()) -> IO(Set()):
  do IO<Set()>:
    ok : Bool <- S.exists(path)
    po.want.open(ok, path, s)

def po.want.files(ps: List<&2, String>, s: Set()) -> IO(Set()):
  match ps:
    case Nil{}:
      IO.pure(Set(), s)
    case p <> more:
      IO.bind(Set(), Set(), po.want.file(p, s), po.want.files(more))

def po.want.paths(ws: List<&2, String>, +l: String) -> List<&2, String>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> more:
      (w ++ "/" ++ l ++ "/transcripts.train.nul") <> (w ++ "/" ++ l ++ "/transcripts.holdout.nul") <> po.want.paths(more, l)

def po.want.save(+work: String, +l: String, s: Set()) -> IO(Unit):
  +ids = Set.to_list(s)
  do IO<Unit>:
    S.write(work ++ "/want." ++ l, po.nuls(ids))
    S.write(work ++ "/units." ++ l, S.b(Nat.show(List.length(&2, String, ids))))

# pool-want WORK LANG
def po.want.run(+work: String, +l: String) -> IO(Unit):
  do IO<Unit>:
    s : Set() <- po.want.files(po.want.paths(po.waves(), l), Set.new())
    po.want.save(work, l, s)

def po.want(xs: List<String>) -> IO(Unit):
  match xs:
    case w <> l <> more:
      po.want.run(w, l)
    case _:
      IO.die(Unit, 2, "usage: pool-want WORK LANG")

# 2. the spool workers --------------------------------------------------------

# each language's wanted ids, whether an id is wanted by each, its spool
type PoW is Data:
  PoW{h: Set(), a: Set(), l: Set(), n: Set(), b: Set()}

type PoB is Data:
  PoB{h: Bool, a: Bool, l: Bool, n: Bool, b: Bool}

type PoO is Type:
  PoO{h: File, a: File, l: File, n: File, b: File}

def po.want.has5(rh: Set() & Bool, ra: Set() & Bool, rl: Set() & Bool, rn: Set() & Bool, rb: Set() & Bool) -> PoW & PoB:
  (h, bh) = rh
  (a, ba) = ra
  (l, bl) = rl
  (n, bn) = rn
  (b, bb) = rb
  (PoW{h, a, l, n, b}, PoB{bh, ba, bl, bn, bb})

def po.want.has(w: PoW, +k: String) -> PoW & PoB:
  match w:
    case PoW{h, a, l, n, b}:
      po.want.has5(Set.has(h, k), Set.has(a, k), Set.has(l, k), Set.has(n, k), Set.has(b, k))

# hd, then t, then a NUL: three writes (an append would copy the record)
def po.emit3(f: File, hd: List<&2, U32>, t: List<&2, U32>) -> IO(File):
  do IO<File>:
    f2 : File <- S.emit(f, hd)
    f3 : File <- S.emit(f2, t)
    S.emit(f3, [0])

def po.put(b: Bool, f: File, +hd: List<&2, U32>, +t: List<&2, U32>) -> IO(File):
  match b:
    case True{}:
      po.emit3(f, hd, t)
    case False{}:
      IO.pure(File, f)

def po.put5(bs: PoB, o: PoO, +hd: List<&2, U32>, +t: List<&2, U32>) -> IO(PoO):
  match bs o:
    case PoB{bh, ba, bl, bn, bb} PoO{fh, fa, fl, fn, fb}:
      do IO<PoO>:
        gh : File <- po.put(bh, fh, hd, t)
        ga : File <- po.put(ba, fa, hd, t)
        gl : File <- po.put(bl, fl, hd, t)
        gn : File <- po.put(bn, fn, hd, t)
        gb : File <- po.put(bb, fb, hd, t)
        return PoO{gh, ga, gl, gn, gb}

type PoWk is Type:
  PoWk{r: S.Rd, w: PoW, seen: Set(), o: PoO, go: Bool}

def po.part.emit(any: Bool, bs: PoB, r: S.Rd, w: PoW, seen: Set(), o: PoO, +k: String, +i: List<&2, U32>, t: List<&2, U32>) -> IO(PoWk):
  match any:
    case False{}:
      IO.pure(PoWk, PoWk{r, w, seen, o, True{}})
    case True{}:
      do IO<PoWk>:
        o2 : PoO <- po.put5(bs, o, S.append(i, [1]), t)
        return PoWk{r, w, Set.add(seen, k), o2, True{}}

def po.part.put(bs: PoB, r: S.Rd, w: PoW, seen: Set(), o: PoO, +k: String, +i: List<&2, U32>, t: List<&2, U32>) -> IO(PoWk):
  match bs:
    case PoB{+bh, +ba, +bl, +bn, +bb}:
      po.part.emit(Bool.or(bh, Bool.or(ba, Bool.or(bl, Bool.or(bn, bb)))), PoB{bh, ba, bl, bn, bb}, r, w, seen, o, k, i, t)

def po.part.want(wb: PoW & PoB, r: S.Rd, seen: Set(), o: PoO, +k: String, +i: List<&2, U32>, t: List<&2, U32>) -> IO(PoWk):
  (w, bs) = wb
  po.part.put(bs, r, w, seen, o, k, i, t)

def po.part.was(was: Bool, r: S.Rd, w: PoW, seen: Set(), o: PoO, +k: String, +i: List<&2, U32>, t: List<&2, U32>) -> IO(PoWk):
  match was:
    case True{}:
      IO.pure(PoWk, PoWk{r, w, seen, o, True{}})
    case False{}:
      po.part.want(po.want.has(w, k), r, seen, o, k, i, t)

def po.part.seen(sb: Set() & Bool, r: S.Rd, w: PoW, o: PoO, +k: String, +i: List<&2, U32>, t: List<&2, U32>) -> IO(PoWk):
  (seen, was) = sb
  po.part.was(was, r, w, seen, o, k, i, t)

def po.part.got(w: PoW, seen: Set(), o: PoO, x: S.Rd & Maybe<&2, PoPr>) -> IO(PoWk):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(PoWk, PoWk{r, w, seen, o, False{}})
    case Some{PoPr{+i, t}}:
      +k = S.str(i)
      po.part.seen(Set.has(seen, k), r, w, o, k, i, t)

def po.part.step(s: PoWk) -> IO(PoWk):
  match s:
    case PoWk{r, w, seen, o, g}:
      IO.bind(S.Rd & Maybe<&2, PoPr>, PoWk, po.next(r), po.part.got(w, seen, o))

def po.part.go(fuel: Nat, s: PoWk) -> IO(PoWk):
  match fuel s:
    case 1n+f PoWk{r, w, seen, o, True{}}:
      IO.bind(PoWk, PoWk, po.part.step(PoWk{r, w, seen, o, True{}}), po.part.go(f))
    case _ PoWk{r, w, seen, o, g}:
      IO.pure(PoWk, PoWk{r, w, seen, o, g})

type PoAcc is Type:
  PoAcc{w: PoW, seen: Set(), o: PoO}

def po.part.done(s: PoWk) -> IO(PoAcc):
  match s:
    case PoWk{r, w, seen, o, g}:
      do IO<PoAcc>:
        S.Rd.close(r)
        return PoAcc{w, seen, o}

def po.part.file(+path: String, a: PoAcc) -> IO(PoAcc):
  match a:
    case PoAcc{w, seen, o}:
      do IO<PoAcc>:
        r : S.Rd <- S.Rd.open(path)
        s : PoWk <- po.part.go(po.big(), PoWk{r, w, seen, o, True{}})
        po.part.done(s)

def po.part.files(ps: List<&2, String>, a: PoAcc) -> IO(PoAcc):
  match ps:
    case Nil{}:
      IO.pure(PoAcc, a)
    case p <> more:
      IO.bind(PoAcc, PoAcc, po.part.file(p, a), po.part.files(more))

def po.part.close(a: PoAcc) -> IO(Unit):
  match a:
    case PoAcc{w, seen, PoO{fh, fa, fl, fn, fb}}:
      do IO<Unit>:
        File.close(fh)
        File.close(fa)
        File.close(fl)
        File.close(fn)
        File.close(fb)

def po.set.load(+path: String) -> IO(Set()):
  do IO<Set()>:
    xs : List<&2, U32> <- S.read(path)
    return Set.from_list(L.v2.lines.str(S.split(xs, 0)))

def po.spool(+work: String, +l: String, +k: String) -> IO(File):
  IO.try(File, File.open(work ++ "/spool." ++ l ++ "." ++ k, "w"))

# pool-part WORK K: the files listed in WORK/files.K
def po.part.run(+work: String, +k: String) -> IO(Unit):
  do IO<Unit>:
    ps : List<&2, String> <- po.read.lines(work ++ "/files." ++ k)
    wh : Set() <- po.set.load(work ++ "/want.haskell")
    wa : Set() <- po.set.load(work ++ "/want.agda")
    wl : Set() <- po.set.load(work ++ "/want.lean")
    wn : Set() <- po.set.load(work ++ "/want.nix")
    wb : Set() <- po.set.load(work ++ "/want.bend")
    fh : File <- po.spool(work, "haskell", k)
    fa : File <- po.spool(work, "agda", k)
    fl : File <- po.spool(work, "lean", k)
    fn : File <- po.spool(work, "nix", k)
    fb : File <- po.spool(work, "bend", k)
    a : PoAcc <- po.part.files(ps, PoAcc{PoW{wh, wa, wl, wn, wb}, Set.new(), PoO{fh, fa, fl, fn, fb}})
    po.part.close(a)

def po.part(xs: List<String>) -> IO(Unit):
  match xs:
    case w <> k <> more:
      po.part.run(w, k)
    case _:
      IO.die(Unit, 2, "usage: pool-part WORK K")

# 4. one language's records, in id order --------------------------------------

type PoC is Data:
  PoC{train: Nat, hold: Nat, dup: Nat}

def po.c.train(c: PoC) -> PoC:
  match c:
    case PoC{t, h, d}:
      PoC{1n+t, h, d}

def po.c.hold(c: PoC) -> PoC:
  match c:
    case PoC{t, h, d}:
      PoC{t, 1n+h, d}

def po.c.dup(c: PoC) -> PoC:
  match c:
    case PoC{t, h, d}:
      PoC{t, h, 1n+d}

# the declaration's key: language, signature and body (fields 0, 4, 7)
# (fields 0..7 lead the record; the bulk after them is not walked)
def po.after.n(n: Nat, +xs: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      xs
    case 1n+k:
      po.after.n(k, L.v2.after(xs, 30))

def po.decl(+rec: List<&2, U32>) -> String:
  +r4 = po.after.n(4n, rec)
  H.sha256(L.v2.concat([L.v2.before(rec, 30), [0], L.v2.before(r4, 30), [0], L.v2.before(po.after.n(3n, r4), 30)]))

type PoLs is Type:
  PoLs{r: S.Rd, e: L.Excl, prev: List<&2, U32>, seen: Set(), tr: File, ho: File, c: PoC, go: Bool}

def po.lang.put(held: Bool, r: S.Rd, e: L.Excl, seen: Set(), tr: File, ho: File, c: PoC, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(PoLs):
  match held:
    case True{}:
      do IO<PoLs>:
        h2 : File <- po.emit3(ho, S.append(id, [0]), rec)
        return PoLs{r, e, id, seen, tr, h2, po.c.hold(c), True{}}
    case False{}:
      do IO<PoLs>:
        t2 : File <- po.emit3(tr, S.append(id, [0]), rec)
        return PoLs{r, e, id, seen, t2, ho, po.c.train(c), True{}}

def po.lang.dup(was: Bool, r: S.Rd, +e: L.Excl, seen: Set(), tr: File, ho: File, c: PoC, +k: String, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(PoLs):
  match was:
    case True{}:
      IO.pure(PoLs, PoLs{r, e, id, seen, tr, ho, po.c.dup(c), True{}})
    case False{}:
      po.lang.put(L.v2.held.id(e, id), r, e, Set.add(seen, k), tr, ho, c, id, rec)

def po.lang.seen(sb: Set() & Bool, r: S.Rd, e: L.Excl, tr: File, ho: File, c: PoC, +k: String, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(PoLs):
  (seen, was) = sb
  po.lang.dup(was, r, e, seen, tr, ho, c, k, id, rec)

def po.lang.same(same: Bool, r: S.Rd, e: L.Excl, seen: Set(), tr: File, ho: File, c: PoC, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(PoLs):
  match same:
    case True{}:
      IO.pure(PoLs, PoLs{r, e, id, seen, tr, ho, c, True{}})
    case False{}:
      +k = po.decl(rec)
      po.lang.seen(Set.has(seen, k), r, e, tr, ho, c, k, id, rec)

def po.lang.got(e: L.Excl, prev: List<&2, U32>, seen: Set(), tr: File, ho: File, c: PoC, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(PoLs):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(PoLs, PoLs{r, e, prev, seen, tr, ho, c, False{}})
    case Some{+it}:
      +id = L.v2.before(it, 1)
      po.lang.same(S.eq(prev, id), r, e, seen, tr, ho, c, id, List.drop(&2, U32, it, 1n+S.len(id)))

def po.lang.step(s: PoLs) -> IO(PoLs):
  match s:
    case PoLs{r, e, prev, seen, tr, ho, c, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, PoLs, S.Rd.next(r), po.lang.got(e, prev, seen, tr, ho, c))

def po.lang.go(fuel: Nat, s: PoLs) -> IO(PoLs):
  match fuel s:
    case 1n+f PoLs{r, e, prev, seen, tr, ho, c, True{}}:
      IO.bind(PoLs, PoLs, po.lang.step(PoLs{r, e, prev, seen, tr, ho, c, True{}}), po.lang.go(f))
    case _ PoLs{r, e, prev, seen, tr, ho, c, g}:
      IO.pure(PoLs, PoLs{r, e, prev, seen, tr, ho, c, g})

# pool.py's summary line
def po.line(+l: String, +units: Nat, c: PoC) -> String:
  match c:
    case PoC{+t, +h, +d}:
      po.lj(8n, l) ++ " units " ++ po.rj(6n, units) ++ ": train " ++ po.rj(6n, t) ++ ", holdout " ++ po.rj(5n, h)
        ++ ", duplicate " ++ po.rj(5n, d) ++ ", no record " ++ po.rj(4n, Nat.sub(units, Nat.add(t, Nat.add(h, d))))

def po.lang.fin(+work: String, +l: String, +units: Nat, s: PoLs) -> IO(Unit):
  match s:
    case PoLs{r, e, prev, seen, tr, ho, c, g}:
      do IO<Unit>:
        S.Rd.close(r)
        File.close(tr)
        File.close(ho)
        S.write(work ++ "/line." ++ l, S.b(po.line(l, units, c)))

# pool-lang WORK LANG OUT
def po.lang.run(+work: String, +l: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    e : L.Excl <- L.v2.ex.load("run/v2/holdout")
    u : List<&2, U32> <- S.read(work ++ "/units." ++ l)
    r : S.Rd <- S.Rd.open(work ++ "/sorted." ++ l)
    tr : File <- IO.try(File, File.open(out ++ "/" ++ l ++ ".train.nul", "w"))
    ho : File <- IO.try(File, File.open(out ++ "/" ++ l ++ ".holdout.nul", "w"))
    s : PoLs <- po.lang.go(po.big(), PoLs{r, e, [0], Set.new(), tr, ho, PoC{0n, 0n, 0n}, True{}})
    po.lang.fin(work, l, po.nat(u), s)

def po.lang(xs: List<String>) -> IO(Unit):
  match xs:
    case w <> l <> o <> more:
      po.lang.run(w, l, o)
    case _:
      IO.die(Unit, 2, "usage: pool-lang WORK LANG OUT")

# the orchestrator --------------------------------------------------------------

def po.workers() -> Nat:
  4n

# the results files, as Python's sorted(glob(..train..) + glob(..holdout..))
def po.results.script() -> String:
  "for f in run/transcripts*/*/results.train.nul run/transcripts*/*/results.holdout.nul; do if [ -e \"$f\" ] || [ -L \"$f\" ]; then printf '%s\\n' \"$f\"; fi; done | LC_ALL=C sort"

def po.results.if(ok: Bool, +o: S.Out) -> IO(List<&2, String>):
  match ok:
    case True{}:
      IO.pure(List<&2, String>, L.v2.lines.str(S.split.lines(S.Out.text(o))))
    case False{}:
      IO.die(List<&2, String>, 1, "pool: listing the results files failed")

def po.results.got(+o: S.Out) -> IO(List<&2, String>):
  po.results.if(U32.is_eq(S.Out.status(o), 0), o)

def po.results() -> IO(List<&2, String>):
  do IO<List<&2, String>>:
    +o : S.Out <- S.run.quiet(".", [], 600, "sh", ["-c", po.results.script()], Nil{})
    po.results.got(o)

def po.sizes(ps: List<&2, String>) -> IO(List<&2, Nat>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, Nat>, Nil{})
    case +p <> more:
      do IO<List<&2, Nat>>:
        n : Nat <- S.size(p)
        rest : List<&2, Nat> <- po.sizes(more)
        return Nat.div(n, 1024n) <> rest

def po.sum(ns: List<&2, Nat>) -> Nat:
  match ns:
    case Nil{}:
      0n
    case n <> more:
      Nat.add(n, po.sum(more))

# each file's run: where it starts in the whole, in g equal parts
def po.gidx(ns: List<&2, Nat>, +start: Nat, +total: Nat, +g: Nat) -> List<&2, Nat>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> more:
      Nat.min(Nat.sub(g, 1n), Nat.div(Nat.mul(start, g), Nat.add(total, 1n))) <> po.gidx(more, Nat.add(start, n), total, g)

def po.pick(ps: List<&2, String>, gs: List<&2, Nat>, +k: Nat) -> List<&2, U32>:
  match ps gs:
    case +p <> pm +g <> gm:
      List.append(&2, U32, Bool.pick(List<&2, U32>, Nat.is_eq(g, k), S.b(p ++ "\n"), Nil{}), po.pick(pm, gm, k))
    case _ _:
      Nil{}

def po.groups.write(m: Nat, +work: String, +ps: List<&2, String>, +gs: List<&2, Nat>, +k: Nat) -> IO(Unit):
  match m:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+p:
      do IO<Unit>:
        S.write(work ++ "/files." ++ Nat.show(k), po.pick(ps, gs, k))
        po.groups.write(p, work, ps, gs, 1n+k)

def po.parts.fork(m: Nat, +self: String, +work: String, +k: Nat) -> IO(List<Chan(Nat)>):
  match m:
    case 0n:
      IO.pure(List<Chan(Nat)>, Nil{})
    case 1n+p:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, IO.bind(U32, Nat, po.self.run(self, ["pool-part", work, Nat.show(k)], work ++ "/part." ++ Nat.show(k) ++ ".log"), st => IO.pure(Nat, po.bad(st))))
        rest : List<Chan(Nat)> <- po.parts.fork(p, self, work, 1n+k)
        return ch <> rest

def po.spools(m: Nat, +work: String, +l: String, +k: Nat) -> List<&2, String>:
  match m:
    case 0n:
      Nil{}
    case 1n+p:
      (work ++ "/spool." ++ l ++ "." ++ Nat.show(k)) <> po.spools(p, work, l, 1n+k)

# 3. a language's spools sorted by id (stable: an earlier run's record first)
def po.sort.script() -> String:
  "d=$1; o=$2; t=$3; shift 3; sort -z -s -t \"$t\" -k1,1 -S 512M --parallel=2 -T \"$d\" -o \"$o\" \"$@\" && rm -f \"$@\""

def po.sort(+work: String, +l: String) -> IO(Unit):
  po.sh("pool: sorting " ++ l, po.sort.script(), List.append(&1, String, [work, work ++ "/sorted." ++ l, "\u{1}"], po.strs(po.spools(po.workers(), work, l, 0n))))

def po.want.chain(ls: List<&2, String>, +self: String, +work: String, +bad: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, bad)
    case +l <> more:
      do IO<Nat>:
        +st : U32 <- po.self.run(self, ["pool-want", work, l], work ++ "/want." ++ l ++ ".log")
        po.want.chain(more, self, work, Nat.add(bad, po.bad(st)))

def po.want.fork(cs: List<&2, List<&2, String>>, +self: String, +work: String) -> IO(List<Chan(Nat)>):
  match cs:
    case Nil{}:
      IO.pure(List<Chan(Nat)>, Nil{})
    case c <> more:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, po.want.chain(c, self, work, 0n))
        rest : List<Chan(Nat)> <- po.want.fork(more, self, work)
        return ch <> rest

def po.lang.chain(ls: List<&2, String>, +self: String, +work: String, +out: String, +bad: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, bad)
    case +l <> more:
      do IO<Nat>:
        po.sort(work, l)
        +st : U32 <- po.self.run(self, ["pool-lang", work, l, out], work ++ "/lang." ++ l ++ ".log")
        S.rm(work ++ "/sorted." ++ l)
        po.lang.chain(more, self, work, out, Nat.add(bad, po.bad(st)))

def po.chains.fork(cs: List<&2, List<&2, String>>, +self: String, +work: String, +out: String) -> IO(List<Chan(Nat)>):
  match cs:
    case Nil{}:
      IO.pure(List<Chan(Nat)>, Nil{})
    case c <> more:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, po.lang.chain(c, self, work, out, 0n))
        rest : List<Chan(Nat)> <- po.chains.fork(more, self, work, out)
        return ch <> rest

def po.summary(ls: List<&2, String>, +work: String) -> IO(List<&2, List<&2, U32>>):
  match ls:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case l <> more:
      do IO<List<&2, List<&2, U32>>>:
        x : List<&2, U32> <- S.read(work ++ "/line." ++ l)
        rest : List<&2, List<&2, U32>> <- po.summary(more, work)
        return x <> rest

def po.groups(+work: String, +ps: List<&2, String>) -> IO(Unit):
  do IO<Unit>:
    +ns : List<&2, Nat> <- po.sizes(ps)
    po.groups.write(po.workers(), work, ps, po.gidx(ns, 0n, po.sum(ns), po.workers()), 0n)

def po.pool.run(+self: String, +out: String) -> IO(Unit):
  +work = out ++ ".work"
  do IO<Unit>:
    S.rm(work)
    S.mkdir(work)
    S.mkdir(out)
    cws : List<Chan(Nat)> <- po.want.fork(po.chains(), self, work)
    +b0 : Nat <- po.join(cws, 0n)
    po.check("pool: the wanted units", b0)
    ps : List<&2, String> <- po.results()
    po.groups(work, ps)
    chs : List<Chan(Nat)> <- po.parts.fork(po.workers(), self, work, 0n)
    +b1 : Nat <- po.join(chs, 0n)
    po.check("pool: spooling the records", b1)
    cls : List<Chan(Nat)> <- po.chains.fork(po.chains(), self, work, out)
    +b2 : Nat <- po.join(cls, 0n)
    po.check("pool: splitting the languages", b2)
    +ls : List<&2, List<&2, U32>> <- po.summary(po.langs(), work)
    S.write(out ++ "/summary.txt", S.append(S.join(ls, 10), [10]))
    IO.print(S.str(S.join(ls, 10)))
    S.rm(work)

# pool [OUT]
def po.pool(xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    self : String <- po.self()
    po.pool.run(self, po.arg(xs, 0n, "run/v2/results"))

# Filler --------------------------------------------------------------------------
#
# Per language, the files-{hi,lo}.nul of every wave in order (hi first), each
# (id, text) with the id less a trailing #cN: a file whose content key or
# (stripped) id the language has had is a copy; else it is had, and kept
# unless held out (by the id, or the key in exclude.sha256).
#
# 1. filler-part WORK K N (four at once): every language's pairs, in order;
#    for the pairs i = K (mod N) a line of WORK/keys.LANG.K: the content key,
#    or `-` when the id came before (the key then is rarely needed: the id is
#    had, unless every earlier pair of it was a copy).
# 2. `paste -d '\n'` interleaves them into WORK/keys.LANG, a line per pair.
# 3. filler-lang WORK LANG OUT RES: the decisions, in order, writing
#    OUT/LANG/files-{hi,lo}.nul, WORK/written.LANG (the kept keys) and the
#    summary line; RES/LANG.holdout.nul is copied in.
# 4. OUT/filler.keys: the kept keys, sorted, once each (`sort -u`).

def fi.is.digit(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.and(U32.is_le(48, h), U32.is_le(h, 57))

def fi.digits(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      fi.digits(t, fi.is.digit(t))
    case r _:
      r

# re.sub(r"#c\d+$", "", id)
def fi.strip(+id: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, id)
  +d = fi.digits(r, fi.is.digit(r))
  Bool.pick(List<&2, U32>, Bool.and(Nat.is_lt(S.len(d), S.len(r)), S.prefix(d, [99, 35])), List.reverse(&2, U32, List.drop(&2, U32, d, 2n)), id)

def fi.keep.if(some: Bool, +p: String, rest: List<&2, String>) -> List<&2, String>:
  match some:
    case True{}:
      p <> rest
    case False{}:
      rest

def fi.keep(+n: Nat, +p: String, rest: List<&2, String>) -> List<&2, String>:
  fi.keep.if(Nat.is_lt(0n, n), p, rest)

def fi.inputs.go(ws: List<&2, String>, +l: String, +tier: String) -> IO(List<&2, String>):
  match ws:
    case Nil{}:
      IO.pure(List<&2, String>, Nil{})
    case w <> more:
      +p = w ++ "/" ++ l ++ "/files-" ++ tier ++ ".nul"
      do IO<List<&2, String>>:
        +n : Nat <- S.size(p)
        rest : List<&2, String> <- fi.inputs.go(more, l, tier)
        return fi.keep(n, p, rest)

# a language's inputs of a tier, in wave order (missing and empty ones left out)
def fi.inputs(+l: String, +tier: String) -> IO(List<&2, String>):
  fi.inputs.go(po.waves(), l, tier)

# 1. the key workers ------------------------------------------------------------

type FiWs is Type:
  FiWs{r: S.Rd, ids: Set(), o: File, i: Nat, go: Bool}

def fi.part.put(mine: Bool, was: Bool, r: S.Rd, ids: Set(), o: File, +i: Nat, t: List<&2, U32>) -> IO(FiWs):
  match mine was:
    case False{} _:
      IO.pure(FiWs, FiWs{r, ids, o, 1n+i, True{}})
    case True{} True{}:
      do IO<FiWs>:
        o2 : File <- S.emit(o, [45, 10])
        return FiWs{r, ids, o2, 1n+i, True{}}
    case True{} False{}:
      do IO<FiWs>:
        o2 : File <- S.emit(o, S.b(L.v2.key(t) ++ "\n"))
        return FiWs{r, ids, o2, 1n+i, True{}}

def fi.part.was(was: Bool, mine: Bool, r: S.Rd, ids: Set(), o: File, +i: Nat, +s: String, t: List<&2, U32>) -> IO(FiWs):
  match was:
    case True{}:
      fi.part.put(mine, True{}, r, ids, o, i, t)
    case False{}:
      fi.part.put(mine, False{}, r, Set.add(ids, s), o, i, t)

def fi.part.ids(sb: Set() & Bool, mine: Bool, r: S.Rd, o: File, +i: Nat, +s: String, t: List<&2, U32>) -> IO(FiWs):
  (ids, was) = sb
  fi.part.was(was, mine, r, ids, o, i, s, t)

def fi.part.got(+kk: Nat, +nn: Nat, ids: Set(), o: File, +i: Nat, x: S.Rd & Maybe<&2, PoPr>) -> IO(FiWs):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(FiWs, FiWs{r, ids, o, i, False{}})
    case Some{PoPr{id, t}}:
      +s = S.str(fi.strip(id))
      fi.part.ids(Set.has(ids, s), Nat.is_eq(Nat.mod(i, nn), kk), r, o, i, s, t)

def fi.part.step(+kk: Nat, +nn: Nat, s: FiWs) -> IO(FiWs):
  match s:
    case FiWs{r, ids, o, +i, g}:
      IO.bind(S.Rd & Maybe<&2, PoPr>, FiWs, po.next(r), fi.part.got(kk, nn, ids, o, i))

def fi.part.go(fuel: Nat, +kk: Nat, +nn: Nat, s: FiWs) -> IO(FiWs):
  match fuel s:
    case 1n+f FiWs{r, ids, o, i, True{}}:
      IO.bind(FiWs, FiWs, fi.part.step(kk, nn, FiWs{r, ids, o, i, True{}}), fi.part.go(f, kk, nn))
    case _ FiWs{r, ids, o, i, g}:
      IO.pure(FiWs, FiWs{r, ids, o, i, g})

type FiWa is Type:
  FiWa{ids: Set(), o: File, i: Nat}

def fi.part.done(s: FiWs) -> IO(FiWa):
  match s:
    case FiWs{r, ids, o, i, g}:
      do IO<FiWa>:
        S.Rd.close(r)
        return FiWa{ids, o, i}

def fi.part.file(+kk: Nat, +nn: Nat, +path: String, a: FiWa) -> IO(FiWa):
  match a:
    case FiWa{ids, o, i}:
      do IO<FiWa>:
        r : S.Rd <- S.Rd.open(path)
        s : FiWs <- fi.part.go(po.big(), kk, nn, FiWs{r, ids, o, i, True{}})
        fi.part.done(s)

def fi.part.files(ps: List<&2, String>, +kk: Nat, +nn: Nat, a: FiWa) -> IO(FiWa):
  match ps:
    case Nil{}:
      IO.pure(FiWa, a)
    case p <> more:
      IO.bind(FiWa, FiWa, fi.part.file(kk, nn, p, a), fi.part.files(more, kk, nn))

def fi.part.close(a: FiWa) -> IO(Unit):
  match a:
    case FiWa{ids, o, i}:
      File.close(o)

def fi.part.lang(+kk: Nat, +nn: Nat, +work: String, +l: String) -> IO(Unit):
  do IO<Unit>:
    o : File <- IO.try(File, File.open(work ++ "/keys." ++ l ++ "." ++ Nat.show(kk), "w"))
    hs : List<&2, String> <- fi.inputs(l, "hi")
    ls : List<&2, String> <- fi.inputs(l, "lo")
    a : FiWa <- fi.part.files(List.append(&2, String, hs, ls), kk, nn, FiWa{Set.new(), o, 0n})
    fi.part.close(a)

def fi.part.langs(ls: List<&2, String>, +kk: Nat, +nn: Nat, +work: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case l <> more:
      do IO<Unit>:
        fi.part.lang(kk, nn, work, l)
        fi.part.langs(more, kk, nn, work)

# filler-part WORK K N
def fi.part(xs: List<String>) -> IO(Unit):
  match xs:
    case w <> k <> n <> more:
      fi.part.langs(po.langs(), po.nat(S.b(k)), po.nat(S.b(n)), w)
    case _:
      IO.die(Unit, 2, "usage: filler-part WORK K N")

# 3. one language's decisions -------------------------------------------------

type FiC is Data:
  FiC{hi: Nat, lo: Nat, copy: Nat, held: Nat}

def fi.c.copy(c: FiC) -> FiC:
  match c:
    case FiC{h, l, k, d}:
      FiC{h, l, 1n+k, d}

def fi.c.held(c: FiC) -> FiC:
  match c:
    case FiC{h, l, k, d}:
      FiC{h, l, k, 1n+d}

def fi.c.tier(hi: Bool, c: FiC) -> FiC:
  match hi c:
    case True{} FiC{h, l, k, d}:
      FiC{1n+h, l, k, d}
    case False{} FiC{h, l, k, d}:
      FiC{h, 1n+l, k, d}

type FiLs is Type:
  FiLs{r: S.Rd, k: S.Rd, e: L.Excl, seen: Set(), ids: Set(), o: File, wk: File, hi: Bool, c: FiC, go: Bool}

def fi.lang.put(held: Bool, r: S.Rd, k: S.Rd, e: L.Excl, seen: Set(), ids: Set(), o: File, wk: File, +hi: Bool, c: FiC, +s: List<&2, U32>, t: List<&2, U32>, +key: String) -> IO(FiLs):
  match held:
    case True{}:
      IO.pure(FiLs, FiLs{r, k, e, seen, ids, o, wk, hi, fi.c.held(c), True{}})
    case False{}:
      do IO<FiLs>:
        o2 : File <- po.emit3(o, S.append(s, [0]), t)
        w2 : File <- S.emit(wk, S.b(key ++ "\n"))
        return FiLs{r, k, e, seen, ids, o2, w2, hi, fi.c.tier(hi, c), True{}}

def fi.lang.seen.if(was: Bool, r: S.Rd, k: S.Rd, +e: L.Excl, seen: Set(), ids: Set(), o: File, wk: File, +hi: Bool, c: FiC, +s: List<&2, U32>, t: List<&2, U32>, +key: String) -> IO(FiLs):
  match was:
    case True{}:
      IO.pure(FiLs, FiLs{r, k, e, seen, ids, o, wk, hi, fi.c.copy(c), True{}})
    case False{}:
      fi.lang.put(Bool.or(L.v2.held.id(e, s), L.v2.held.key(e, key)), r, k, e, Set.add(seen, key), Set.add(ids, S.str(s)), o, wk, hi, c, s, t, key)

def fi.lang.seen(sb: Set() & Bool, r: S.Rd, k: S.Rd, e: L.Excl, ids: Set(), o: File, wk: File, +hi: Bool, c: FiC, +s: List<&2, U32>, t: List<&2, U32>, +key: String) -> IO(FiLs):
  (seen, was) = sb
  fi.lang.seen.if(was, r, k, e, seen, ids, o, wk, hi, c, s, t, key)

# the key: the worker's, or computed here when it left `-`
def fi.key.of(dash: Bool, +kl: List<&2, U32>, +t: List<&2, U32>) -> String:
  match dash:
    case True{}:
      L.v2.key(t)
    case False{}:
      S.str(kl)

def fi.lang.ids.if(was: Bool, r: S.Rd, k: S.Rd, e: L.Excl, seen: Set(), ids: Set(), o: File, wk: File, +hi: Bool, c: FiC, +s: List<&2, U32>, +t: List<&2, U32>, +kl: List<&2, U32>) -> IO(FiLs):
  match was:
    case True{}:
      IO.pure(FiLs, FiLs{r, k, e, seen, ids, o, wk, hi, fi.c.copy(c), True{}})
    case False{}:
      +key = fi.key.of(L.v2.head.is(kl, 45), kl, t)
      fi.lang.seen(Set.has(seen, key), r, k, e, ids, o, wk, hi, c, s, t, key)

def fi.lang.ids(sb: Set() & Bool, r: S.Rd, k: S.Rd, e: L.Excl, seen: Set(), o: File, wk: File, +hi: Bool, c: FiC, +s: List<&2, U32>, t: List<&2, U32>, kl: List<&2, U32>) -> IO(FiLs):
  (ids, was) = sb
  fi.lang.ids.if(was, r, k, e, seen, ids, o, wk, hi, c, s, t, kl)

def fi.kl(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  match m:
    case None{}:
      [45]
    case Some{l}:
      l

def fi.lang.pair(r: S.Rd, e: L.Excl, seen: Set(), ids: Set(), o: File, wk: File, +hi: Bool, c: FiC, +i: List<&2, U32>, t: List<&2, U32>, y: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(FiLs):
  (k, m) = y
  +s = fi.strip(i)
  fi.lang.ids(Set.has(ids, S.str(s)), r, k, e, seen, o, wk, hi, c, s, t, fi.kl(m))

def fi.lang.got(k: S.Rd, e: L.Excl, seen: Set(), ids: Set(), o: File, wk: File, +hi: Bool, c: FiC, x: S.Rd & Maybe<&2, PoPr>) -> IO(FiLs):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(FiLs, FiLs{r, k, e, seen, ids, o, wk, hi, c, False{}})
    case Some{PoPr{i, t}}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, FiLs, S.Rd.next(k), fi.lang.pair(r, e, seen, ids, o, wk, hi, c, i, t))

def fi.lang.step(s: FiLs) -> IO(FiLs):
  match s:
    case FiLs{r, k, e, seen, ids, o, wk, hi, c, g}:
      IO.bind(S.Rd & Maybe<&2, PoPr>, FiLs, po.next(r), fi.lang.got(k, e, seen, ids, o, wk, hi, c))

def fi.lang.go(fuel: Nat, s: FiLs) -> IO(FiLs):
  match fuel s:
    case 1n+f FiLs{r, k, e, seen, ids, o, wk, hi, c, True{}}:
      IO.bind(FiLs, FiLs, fi.lang.step(FiLs{r, k, e, seen, ids, o, wk, hi, c, True{}}), fi.lang.go(f))
    case _ FiLs{r, k, e, seen, ids, o, wk, hi, c, g}:
      IO.pure(FiLs, FiLs{r, k, e, seen, ids, o, wk, hi, c, g})

type FiAcc is Type:
  FiAcc{k: S.Rd, e: L.Excl, seen: Set(), ids: Set(), o: File, wk: File, hi: Bool, c: FiC}

def fi.lang.done(s: FiLs) -> IO(FiAcc):
  match s:
    case FiLs{r, k, e, seen, ids, o, wk, hi, c, g}:
      do IO<FiAcc>:
        S.Rd.close(r)
        return FiAcc{k, e, seen, ids, o, wk, hi, c}

def fi.lang.file(+path: String, a: FiAcc) -> IO(FiAcc):
  match a:
    case FiAcc{k, e, seen, ids, o, wk, hi, c}:
      do IO<FiAcc>:
        r : S.Rd <- S.Rd.open(path)
        s : FiLs <- fi.lang.go(po.big(), FiLs{r, k, e, seen, ids, o, wk, hi, c, True{}})
        fi.lang.done(s)

def fi.lang.files(ps: List<&2, String>, a: FiAcc) -> IO(FiAcc):
  match ps:
    case Nil{}:
      IO.pure(FiAcc, a)
    case p <> more:
      IO.bind(FiAcc, FiAcc, fi.lang.file(p, a), fi.lang.files(more))

# between the tiers: everything but the tier's output
type FiT is Type:
  FiT{k: S.Rd, e: L.Excl, seen: Set(), ids: Set(), wk: File, c: FiC}

def fi.tier.done(a: FiAcc) -> IO(FiT):
  match a:
    case FiAcc{k, e, seen, ids, o, wk, hi, c}:
      do IO<FiT>:
        File.close(o)
        return FiT{k, e, seen, ids, wk, c}

def fi.tier.run(+out: String, +l: String, +tier: String, t: FiT) -> IO(FiT):
  match t:
    case FiT{k, e, seen, ids, wk, c}:
      do IO<FiT>:
        ps : List<&2, String> <- fi.inputs(l, tier)
        o : File <- IO.try(File, File.open(out ++ "/" ++ l ++ "/files-" ++ tier ++ ".nul", "w"))
        a : FiAcc <- fi.lang.files(ps, FiAcc{k, e, seen, ids, o, wk, String.eq(tier, "hi"), c})
        fi.tier.done(a)

# filler.py's summary line
def fi.line(+l: String, c: FiC) -> String:
  match c:
    case FiC{h, lo, k, d}:
      po.lj(8n, l) ++ " hi " ++ po.rj(6n, h) ++ "  lo " ++ po.rj(6n, lo) ++ "  copies dropped " ++ po.rj(6n, k) ++ "  held out " ++ po.rj(5n, d)

def fi.lang.fin(+work: String, +l: String, t: FiT) -> IO(Unit):
  match t:
    case FiT{k, e, seen, ids, wk, c}:
      do IO<Unit>:
        S.Rd.close(k)
        File.close(wk)
        S.write(work ++ "/line." ++ l, S.b(fi.line(l, c)))

# filler-lang WORK LANG OUT RES
def fi.lang.run(+work: String, +l: String, +out: String, +res: String) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(out ++ "/" ++ l)
    e : L.Excl <- L.v2.ex.load("run/v2/holdout")
    k : S.Rd <- S.Rd.lines(work ++ "/keys." ++ l)
    wk : File <- IO.try(File, File.open(work ++ "/written." ++ l, "w"))
    t1 : FiT <- fi.tier.run(out, l, "hi", FiT{k, e, Set.new(), Set.new(), wk, FiC{0n, 0n, 0n, 0n}})
    t2 : FiT <- fi.tier.run(out, l, "lo", t1)
    fi.lang.fin(work, l, t2)
    po.sh("filler: copying " ++ l ++ "'s holdout results", "cp \"$1\" \"$2\"", [res ++ "/" ++ l ++ ".holdout.nul", out ++ "/" ++ l ++ "/results.holdout.nul"])

def fi.lang(xs: List<String>) -> IO(Unit):
  match xs:
    case w <> l <> o <> r <> more:
      fi.lang.run(w, l, o, r)
    case _:
      IO.die(Unit, 2, "usage: filler-lang WORK LANG OUT RES")

# the orchestrator --------------------------------------------------------------

def fi.parts.fork(m: Nat, +self: String, +work: String, +k: Nat) -> IO(List<Chan(Nat)>):
  match m:
    case 0n:
      IO.pure(List<Chan(Nat)>, Nil{})
    case 1n+p:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, IO.bind(U32, Nat, po.self.run(self, ["filler-part", work, Nat.show(k), Nat.show(po.workers())], work ++ "/part." ++ Nat.show(k) ++ ".log"), st => IO.pure(Nat, po.bad(st))))
        rest : List<Chan(Nat)> <- fi.parts.fork(p, self, work, 1n+k)
        return ch <> rest

def fi.keyparts(m: Nat, +work: String, +l: String, +k: Nat) -> List<&2, String>:
  match m:
    case 0n:
      Nil{}
    case 1n+p:
      (work ++ "/keys." ++ l ++ "." ++ Nat.show(k)) <> fi.keyparts(p, work, l, 1n+k)

# 2. a language's key lines, interleaved back into pair order
def fi.paste(ls: List<&2, String>, +work: String) -> IO(Unit):
  match ls:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +l <> more:
      do IO<Unit>:
        po.sh("filler: interleaving " ++ l ++ "'s keys", "o=$1; d=$2; shift 2; paste -d \"$d\" \"$@\" > \"$o\" && rm -f \"$@\"",
          List.append(&1, String, [work ++ "/keys." ++ l, "\n"], po.strs(fi.keyparts(po.workers(), work, l, 0n))))
        fi.paste(more, work)

def fi.lang.chain(ls: List<&2, String>, +self: String, +work: String, +out: String, +res: String, +bad: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, bad)
    case +l <> more:
      do IO<Nat>:
        +st : U32 <- po.self.run(self, ["filler-lang", work, l, out, res], work ++ "/lang." ++ l ++ ".log")
        fi.lang.chain(more, self, work, out, res, Nat.add(bad, po.bad(st)))

def fi.chains.fork(cs: List<&2, List<&2, String>>, +self: String, +work: String, +out: String, +res: String) -> IO(List<Chan(Nat)>):
  match cs:
    case Nil{}:
      IO.pure(List<Chan(Nat)>, Nil{})
    case c <> more:
      do IO<List<Chan(Nat)>>:
        ch : Chan(Nat) <- IO.fork(Nat, fi.lang.chain(c, self, work, out, res, 0n))
        rest : List<Chan(Nat)> <- fi.chains.fork(more, self, work, out, res)
        return ch <> rest

def fi.written(ls: List<&2, String>, +work: String) -> List<&2, String>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> more:
      (work ++ "/written." ++ l) <> fi.written(more, work)

def fi.filler.run(+self: String, +out: String, +res: String) -> IO(Unit):
  +work = out ++ ".work"
  do IO<Unit>:
    S.rm(work)
    S.mkdir(work)
    S.mkdir(out)
    chs : List<Chan(Nat)> <- fi.parts.fork(po.workers(), self, work, 0n)
    +b1 : Nat <- po.join(chs, 0n)
    po.check("filler: the content keys", b1)
    fi.paste(po.langs(), work)
    cls : List<Chan(Nat)> <- fi.chains.fork(po.chains(), self, work, out, res)
    +b2 : Nat <- po.join(cls, 0n)
    po.check("filler: the languages", b2)
    po.sh("filler: filler.keys", "o=$1; d=$2; shift 2; sort -u -S 512M -T \"$d\" -o \"$o\" \"$@\"",
      List.append(&1, String, [out ++ "/filler.keys", work], po.strs(fi.written(po.langs(), work))))
    +ls : List<&2, List<&2, U32>> <- po.summary(po.langs(), work)
    IO.print(S.str(S.join(ls, 10)))
    S.rm(work)

# filler [OUT [RES]]
def fi.filler.args(+self: String, xs: List<String>) -> IO(Unit):
  match xs:
    case o <> r <> more:
      fi.filler.run(self, o, r)
    case o <> more:
      fi.filler.run(self, o, "run/v2/results")
    case _:
      fi.filler.run(self, "run/v2/transcripts", "run/v2/results")

def fi.filler(xs: List<String>) -> IO(Unit):
  do IO<Unit>:
    self : String <- po.self()
    fi.filler.args(self, xs)

# The subcommands ---------------------------------------------------------------

def po.code(+c: String) -> Nat:
  Bool.pick(Nat, String.eq(c, "pool"), 1n, Bool.pick(Nat, String.eq(c, "pool-part"), 2n, Bool.pick(Nat, String.eq(c, "pool-lang"), 3n,
    Bool.pick(Nat, String.eq(c, "filler"), 4n, Bool.pick(Nat, String.eq(c, "filler-part"), 5n, Bool.pick(Nat, String.eq(c, "filler-lang"), 6n, Bool.pick(Nat, String.eq(c, "pool-want"), 7n, 0n)))))))

# is c one of this module's subcommands
def po.is(+c: String) -> Bool:
  Nat.is_lt(0n, po.code(c))

def po.run.n(n: Nat, xs: List<String>) -> IO(Unit):
  match n:
    case 1n:
      po.pool(xs)
    case 2n:
      po.part(xs)
    case 3n:
      po.lang(xs)
    case 4n:
      fi.filler(xs)
    case 5n:
      fi.part(xs)
    case 6n:
      fi.lang(xs)
    case 7n:
      po.want(xs)
    case _:
      IO.die(Unit, 2, "usage: pool [OUT] | filler [OUT [RES]]")

# run subcommand c with its arguments xs
def po.run(+c: String, xs: List<String>) -> IO(Unit):
  po.run.n(po.code(c), xs)
