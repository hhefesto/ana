import Base
import ./Sys.bend as S
import ./Clock.bend as Ck
import ./Check/Lib.bend as L
import ./Check/Nix.bend as Nx
import ./Check/Bend.bend as Bd
import ./Check/Lean.bend as Ln
import ./Check/Agda.bend as Ag
import ./Check/Haskell.bend as Hs
import ./Check/AgdaLibs.bend as Al

# bend-check: the real checkers over the units bend-units cut.
#
#   bend-check LANG UNITS.nul RESULTS.nul [JOBS]
#   bend-check agda-libs [precompile]
#
# The second sets up the libraries the Agda checker needs (Check/AgdaLibs.bend).
# LANG is nix, bend, lean, agda or haskell.  Check/Lib.bend has the formats
# of UNITS.nul and RESULTS.nul; Check/<Lang>.bend says what each language's
# checker runs and what it needs from the environment.  Common to all:
# TIMEOUT (seconds per checker run; each language has its default),
# CAP_LINES (100: lines of checker output a check keeps), KEEP_WORK (set:
# the work directory is kept and named on stderr).
#
# JOBS workers (default: the runtime's thread count) take jobs from a
# channel as they free up.  A job is one unit, except for Haskell: a first
# pass groups the units by package (a Hackage package, else the nearest
# directory above the file holding a .cabal), and a package's units go to
# one worker, largest package first, read back from UNITS.nul fifty at a
# time, so its interfaces are built once.  Each worker appends its kept
# units to its own part file, tagged with their position in UNITS.nul; a
# merge of the parts by position writes RESULTS.nul, so the results are in
# input order whatever the timing.  RESULTS.nul.stats counts every
# decision, keys in byte order.

type Cfg is Data:
  Nix{t: U32, cap: Nat}
  Bnd{c: Bd.Cf}
  Lean{c: Ln.Cf}
  Agda{c: Ag.Cf}
  Haskell{c: Hs.Hc, units: String, dirs: Set()}

def Cfg.name(+c: Cfg) -> String:
  match c:
    case Nix{t, cap}:
      "nix"
    case Bnd{b}:
      "bend"
    case Lean{l}:
      "lean"
    case Agda{a}:
      "agda"
    case Haskell{h, u, d}:
      "haskell"

# the most units a job holds
def Cfg.group(+c: Cfg) -> Nat:
  match c:
    case _:
      1n

# consecutive units with one key share a job
def Cfg.key(+c: Cfg, +u: L.U) -> List<&2, U32>:
  match c:
    case _:
      Nil{}

def Cfg.job(+c: Cfg, +k: Nat, +dir: String, us: List<&2, L.U>) -> IO(List<&2, L.Got>):
  match c:
    case Nix{+t, +cap}:
      Nx.job(t, dir, cap, us)
    case Bnd{+b}:
      Bd.job(b, dir, us)
    case Lean{+l}:
      Ln.job(l, dir, us)
    case Agda{+a}:
      Ag.job(a, k, dir, us)
    case Haskell{+h, u, d}:
      Hs.job(h, dir, Nil{}, us)

# A unit's place in UNITS.nul: its position, and its bytes' offset and
# length (id, NUL, record, NUL).
type Lc is Data:
  Lc{i: Nat, off: Nat, len: Nat}

# A job: units, or (a package) every unit id and where the units are.
type Job is Data:
  Job{us: List<&2, L.U>}
  Keyed{ids: List<&2, List<&2, U32>>, locs: List<&2, Lc>}

# Workers --------------------------------------------------------------------

# a job's kept units as part-file triples: position, id, record
def part.bytes(us: List<&2, L.U>, gs: List<&2, L.Got>) -> List<&2, U32>:
  match us gs:
    case +u <> ut L.Kept{rec, ks} <> gt:
      S.append(S.b(Nat.show(L.U.i(u))), 0 <> S.append(L.U.id(u), 0 <> S.append(rec, 0 <> part.bytes(ut, gt))))
    case u <> ut L.Dropped{ks} <> gt:
      part.bytes(ut, gt)
    case _ _:
      Nil{}

def job.stats(gs: List<&2, L.Got>, st: List<&2, L.Stat>) -> List<&2, L.Stat>:
  match gs:
    case Nil{}:
      st
    case L.Kept{r, ks} <> more:
      job.stats(more, L.stat.all("units" <> "kept" <> ks, st))
    case L.Dropped{ks} <> more:
      job.stats(more, L.stat.all("units" <> ks, st))

type Wk is Data:
  Wk{go: Bool, st: List<&2, L.Stat>}

# A unit read back from its place: id, NUL, record, NUL.
def unit.of(+l: Lc, +xs: List<&2, U32>) -> L.U:
  match l:
    case Lc{i, off, len}:
      +id = Hs.upto(xs, 0)
      +rest = List.drop(&2, U32, xs, 1n+S.len(id))
      {L.U{i, id, L.fields(Hs.upto(rest, 0))} : L.U}

type Ru is Type:
  Ru{f: File, acc: List<&2, L.U>}

def read.unit.got(+l: Lc, acc: List<&2, L.U>, r: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> IO(Ru):
  (f, x) = r
  do IO<Ru>:
    xs : List<&2, U32> <- IO.pass(List<&2, U32>, x)
    return Ru{f, unit.of(l, xs) <> acc}

def read.unit(+l: Lc, st: Ru) -> IO(Ru):
  match l st:
    case Lc{+i, +off, +len} Ru{f, acc}:
      do IO<Ru>:
        r : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_at(f, U32.from_nat(off), U32.from_nat(len))
        read.unit.got(Lc{i, off, len}, acc, r)

def read.units(ls: List<&2, Lc>, st: Ru) -> IO(Ru):
  match ls:
    case Nil{}:
      IO.pure(Ru, st)
    case +l <> more:
      IO.bind(Ru, Ru, read.unit(l, st), read.units(more))

def read.chunk.fin(st: Ru) -> IO(List<&2, L.U>):
  match st:
    case Ru{f, acc}:
      do IO<List<&2, L.U>>:
        File.close(f)
        return List.reverse(&2, L.U, acc)

# the units at their places
def read.chunk(+path: String, ls: List<&2, Lc>) -> IO(List<&2, L.U>):
  do IO<List<&2, L.U>>:
    f : File <- IO.try(File, File.open(path, "r"))
    st : Ru <- read.units(ls, Ru{f, Nil{}})
    read.chunk.fin(st)

def keyed.chunk() -> Nat:
  50n

def wk.done(+part: String, +us: List<&2, L.U>, +gs: List<&2, L.Got>, st: List<&2, L.Stat>) -> IO(Wk):
  do IO<Wk>:
    S.add(part, part.bytes(us, gs))
    return Wk{True{}, job.stats(gs, st)}

def big() -> Nat:
  U32.to_nat(4294967295)

def join.all(chs: List<Chan(List<&2, L.Stat>)>, st: List<&2, L.Stat>) -> IO(List<&2, L.Stat>):
  match chs:
    case Nil{}:
      IO.pure(List<&2, L.Stat>, st)
    case +ch <> more:
      do IO<List<&2, L.Stat>>:
        s : List<&2, L.Stat> <- IO.join(List<&2, L.Stat>, ch)
        join.all(more, L.stat.merge(s, st))

# A process's share of the units (SHARD of SHARDS): those whose Haskell
# package, or (the other languages) file, hashes to SHARD mod SHARDS, the hash (7; h * 31 + c mod 1000003) over the
# code points, as bend-transcripts' hackage.ok.
def kh.go(s: String, +h: U32) -> U32:
  match s:
    case SNil{}:
      h
    case SCon{Chr{c}, t}:
      kh.go(t, U32.mod(U32.add(U32.mul(h, 31), c), 1000003))

def shard.mine(+sk: Nat, +sn: Nat, +key: String) -> Bool:
  U32.is_eq(U32.mod(kh.go(key, 7), U32.from_nat(sn)), U32.from_nat(sk))

# The dispatcher: reads UNITS.nul a unit at a time, gathers jobs -------------

type Dp is Type:
  Dp{rd: S.Rd, i: Nat, key: List<&2, U32>, grp: List<&2, L.U>, gn: Nat, go: Bool}

def dp.send(+jobs: Chan(Job), grp: List<&2, L.U>, gn: Nat) -> IO(Unit):
  match gn:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+m:
      do IO<Unit>:
        ok : Bool <- Chan.send(Job, jobs, Job{List.reverse(&2, L.U, grp)})
        return Unit{}

def dp.place(same: Bool, +jobs: Chan(Job), rd: S.Rd, +i: Nat, key: List<&2, U32>, grp: List<&2, L.U>, +gn: Nat, +u: L.U, +k: List<&2, U32>) -> IO(Dp):
  match same:
    case True{}:
      IO.pure(Dp, Dp{rd, 1n+i, key, u <> grp, 1n+gn, True{}})
    case False{}:
      do IO<Dp>:
        dp.send(jobs, grp, gn)
        return Dp{rd, 1n+i, k, [u], 1n, True{}}

# a unit of another shard: passed over, its place still counted
def dp.mine(mine: Bool, same: Bool, +jobs: Chan(Job), rd: S.Rd, +i: Nat, key: List<&2, U32>, grp: List<&2, L.U>, +gn: Nat, +u: L.U, +k: List<&2, U32>) -> IO(Dp):
  match mine:
    case True{}:
      dp.place(same, jobs, rd, i, key, grp, gn, u, k)
    case False{}:
      IO.pure(Dp, Dp{rd, 1n+i, key, grp, gn, True{}})

def dp.rec.m(+c: Cfg, +sk: Nat, +sn: Nat, +jobs: Chan(Job), rd: S.Rd, +i: Nat, +key: List<&2, U32>, grp: List<&2, L.U>, +gn: Nat, +id: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> IO(Dp):
  match m:
    case None{}:
      do IO<Dp>:
        S.Rd.close(rd)
        IO.die(Dp, 1, "bend-check: a unit id without its record")
    case Some{+rec}:
      +u = {L.U{i, id, L.fields(rec)} : L.U}
      +k = Cfg.key(c, u)
      dp.mine(shard.mine(sk, sn, S.str(Hs.upto(id, 35))), Bool.and(S.eq(k, key), Nat.is_lt(gn, Cfg.group(c))), jobs, rd, i, key, grp, gn, u, k)

def dp.rec(+c: Cfg, +sk: Nat, +sn: Nat, +jobs: Chan(Job), +i: Nat, +key: List<&2, U32>, grp: List<&2, L.U>, +gn: Nat, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Dp):
  (rd, m) = r
  dp.rec.m(c, sk, sn, jobs, rd, i, key, grp, gn, id, m)

def dp.id.m(+c: Cfg, +sk: Nat, +sn: Nat, +jobs: Chan(Job), rd: S.Rd, +i: Nat, +key: List<&2, U32>, grp: List<&2, L.U>, +gn: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Dp):
  match m:
    case None{}:
      do IO<Dp>:
        dp.send(jobs, grp, gn)
        return Dp{rd, i, key, Nil{}, 0n, False{}}
    case Some{+id}:
      do IO<Dp>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        dp.rec(c, sk, sn, jobs, i, key, grp, gn, id, r)

def dp.id(+c: Cfg, +sk: Nat, +sn: Nat, +jobs: Chan(Job), +i: Nat, +key: List<&2, U32>, grp: List<&2, L.U>, +gn: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Dp):
  (rd, m) = r
  dp.id.m(c, sk, sn, jobs, rd, i, key, grp, gn, m)

def dp.step(+c: Cfg, +sk: Nat, +sn: Nat, +jobs: Chan(Job), d: Dp) -> IO(Dp):
  match d:
    case Dp{rd, +i, +key, grp, +gn, g}:
      do IO<Dp>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        dp.id(c, sk, sn, jobs, i, key, grp, gn, r)

# every unit dispatched: the reader and the number of units
def dp.go(fuel: Nat, +c: Cfg, +sk: Nat, +sn: Nat, +jobs: Chan(Job), d: Dp) -> IO(S.Rd & Nat):
  match fuel d:
    case 1n+p Dp{rd, i, key, grp, gn, True{}}:
      IO.bind(Dp, S.Rd & Nat, dp.step(c, sk, sn, jobs, Dp{rd, i, key, grp, gn, True{}}), dp.go(p, c, sk, sn, jobs))
    case _ Dp{rd, i, key, grp, gn, g}:
      IO.pure(S.Rd & Nat, (rd, i))

# Pass 1 of a keyed run (Haskell): every unit's package and place ---------

# A unit's package, as the dispatcher sees it: a Hackage package, else the
# nearest directory above the file that holds a .cabal or .cabal.in (dirs),
# else the repository.
def set.fin(r: Set() & Bool) -> Bool:
  (s, b) = r
  b

def set.has(s: Set(), +k: String) -> Bool:
  set.fin(Set.has(s, k))

def hkey.walk(fuel: Nat, +p: String, +base: String, +dirs: Set()) -> String:
  match fuel:
    case 0n:
      base
    case 1n+f:
      +up = S.parent(p)
      Bool.pick(String, String.eq(up, p), base,
        Bool.pick(String, set.has(dirs, up), up,
          Bool.pick(String, Nat.is_le(String.length(up), String.length(base)), base, hkey.walk(f, up, base, dirs))))

def hkey.base(+cs: String, +g: List<&2, U32>) -> String:
  Bool.pick(String, S.prefix(g, S.b("repo:")), cs ++ "/repos/" ++ S.str(S.strip(g, S.b("repo:"))),
    Bool.pick(String, S.prefix(g, S.b("own:")), cs ++ "/own/" ++ S.str(S.strip(g, S.b("own:"))),
      Bool.pick(String, S.prefix(g, S.b("curated:")), cs ++ "/curated/" ++ S.str(S.strip(g, S.b("curated:"))), S.str(g))))

def hkey(+cs: String, +dirs: Set(), +id: List<&2, U32>) -> String:
  +f = Hs.upto(id, 35)
  +g = Hs.upto(f, 47)
  +rel = List.drop(&2, U32, f, 1n+S.len(g))
  +base = hkey.base(cs, g)
  Bool.pick(String, S.prefix(g, S.b("hackage:")), S.str(g), hkey.walk(64n, base ++ "/" ++ S.str(rel), base, dirs))

type Grp is Data:
  Grp{n: Nat, ids: List<&2, List<&2, U32>>, locs: List<&2, Lc>}

def Grp.n(+g: Grp) -> Nat:
  match g:
    case Grp{n, i, l}:
      n

type Kp is Type:
  Kp{rd: S.Rd, i: Nat, off: Nat, m: Map<&2, Grp>, order: List<&2, String>, go: Bool}

def kp.added(rd: S.Rd, +i: Nat, +off: Nat, +len: Nat, +order: List<&2, String>, +key: String, +fresh: Bool, m: Map<&2, Grp>) -> Kp:
  Kp{rd, 1n+i, Nat.add(off, len), m, Bool.pick(List<&2, String>, fresh, key <> order, order), True{}}

def kp.put.g(rd: S.Rd, +i: Nat, +off: Nat, +len: Nat, order: List<&2, String>, +key: String, +id: List<&2, U32>, m: Map<&2, Grp>, g: Grp) -> Kp:
  match g:
    case Grp{+n, ids, locs}:
      kp.added(rd, i, off, len, order, key, Nat.is_eq(n, 0n), Map.set(&2, Grp, m, key, Grp{1n+n, id <> ids, Lc{i, off, len} <> locs}))

def kp.put(rd: S.Rd, +i: Nat, +off: Nat, +len: Nat, order: List<&2, String>, +key: String, +id: List<&2, U32>, r: Map<&2, Grp> & Grp) -> Kp:
  (m, g) = r
  kp.put.g(rd, i, off, len, order, key, id, m, g)

# a unit of another shard's package: passed over, its place still counted
def kp.mine(mine: Bool, rd: S.Rd, +i: Nat, +off: Nat, +len: Nat, m: Map<&2, Grp>, order: List<&2, String>, +key: String, +id: List<&2, U32>) -> Kp:
  match mine:
    case True{}:
      kp.put(rd, i, off, len, order, key, id, Map.get(Grp, Grp{0n, Nil{}, Nil{}}, m, key))
    case False{}:
      Kp{rd, 1n+i, Nat.add(off, len), m, order, True{}}

def kp.rec.m(+cs: String, +dirs: Set(), +sk: Nat, +sn: Nat, rd: S.Rd, +i: Nat, +off: Nat, m: Map<&2, Grp>, order: List<&2, String>, +id: List<&2, U32>, x: Maybe<&2, List<&2, U32>>) -> IO(Kp):
  match x:
    case None{}:
      do IO<Kp>:
        S.Rd.close(rd)
        IO.die(Kp, 1, "bend-check: a unit id without its record")
    case Some{+rec}:
      +key = hkey(cs, dirs, id)
      IO.pure(Kp, kp.mine(shard.mine(sk, sn, key), rd, i, off, Nat.add(Nat.add(S.len(id), S.len(rec)), 2n), m, order, key, id))

def kp.rec(+cs: String, +dirs: Set(), +sk: Nat, +sn: Nat, +i: Nat, +off: Nat, m: Map<&2, Grp>, order: List<&2, String>, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Kp):
  (rd, x) = r
  kp.rec.m(cs, dirs, sk, sn, rd, i, off, m, order, id, x)

def kp.id.m(+cs: String, +dirs: Set(), +sk: Nat, +sn: Nat, rd: S.Rd, +i: Nat, +off: Nat, m: Map<&2, Grp>, order: List<&2, String>, x: Maybe<&2, List<&2, U32>>) -> IO(Kp):
  match x:
    case None{}:
      IO.pure(Kp, Kp{rd, i, off, m, order, False{}})
    case Some{+id}:
      do IO<Kp>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        kp.rec(cs, dirs, sk, sn, i, off, m, order, id, r)

def kp.id(+cs: String, +dirs: Set(), +sk: Nat, +sn: Nat, +i: Nat, +off: Nat, m: Map<&2, Grp>, order: List<&2, String>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Kp):
  (rd, x) = r
  kp.id.m(cs, dirs, sk, sn, rd, i, off, m, order, x)

def kp.step(+cs: String, +dirs: Set(), +sk: Nat, +sn: Nat, k: Kp) -> IO(Kp):
  match k:
    case Kp{rd, +i, +off, m, order, g}:
      do IO<Kp>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        kp.id(cs, dirs, sk, sn, i, off, m, order, r)

def kp.go(fuel: Nat, +cs: String, +dirs: Set(), +sk: Nat, +sn: Nat, k: Kp) -> IO(Kp):
  match fuel k:
    case 1n+p Kp{rd, i, off, m, order, True{}}:
      IO.bind(Kp, Kp, kp.step(cs, dirs, sk, sn, Kp{rd, i, off, m, order, True{}}), kp.go(p, cs, dirs, sk, sn))
    case _ Kp{rd, i, off, m, order, g}:
      IO.pure(Kp, Kp{rd, i, off, m, order, g})

def grp.get(r: Map<&2, Grp> & Grp) -> Grp:
  (m, g) = r
  g

def grps(+m: Map<&2, Grp>, ks: List<&2, String>) -> List<&2, Grp>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> more:
      grp.get(Map.get(Grp, Grp{0n, Nil{}, Nil{}}, m, k)) <> grps(m, more)

def grp.le(a: Grp, c: Grp) -> Bool:
  match a c:
    case Grp{+n, i, l} Grp{+o, j, k}:
      Nat.is_le(o, n)

# PKG_CAP: of a package's n units (j = 0.. in input order) the cap evenly
# spaced ones, j with j * cap mod n < cap; PKG_REST: the others.  No cap
# (0) or n <= cap: every unit, and none as the rest.
def pick.in(+cap: Nat, +n: Nat, +j: Nat) -> Bool:
  Bool.or(Nat.is_eq(cap, 0n), Bool.or(Nat.is_le(n, cap),
    U32.is_lt(U32.mod(U32.mul(U32.from_nat(j), U32.from_nat(cap)), U32.from_nat(n)), U32.from_nat(cap))))

def pick.keep(+rest: Bool, +p: Bool) -> Bool:
  Bool.pick(Bool, rest, Bool.not(p), p)

def pick.ids(+cap: Nat, +rest: Bool, +n: Nat, xs: List<&2, List<&2, U32>>, +j: Nat) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      +r = pick.ids(cap, rest, n, more, 1n+j)
      Bool.pick(List<&2, List<&2, U32>>, pick.keep(rest, pick.in(cap, n, j)), x <> r, r)

def pick.locs(+cap: Nat, +rest: Bool, +n: Nat, xs: List<&2, Lc>, +j: Nat) -> List<&2, Lc>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> more:
      +r = pick.locs(cap, rest, n, more, 1n+j)
      Bool.pick(List<&2, Lc>, pick.keep(rest, pick.in(cap, n, j)), x <> r, r)

# the packages' picked units, in input order, the empty ones gone
def grps.cap(+cap: Nat, +rest: Bool, gs: List<&2, Grp>) -> List<&2, Grp>:
  match gs:
    case Nil{}:
      Nil{}
    case Grp{+n, ids, locs} <> more:
      +xs = pick.ids(cap, rest, n, List.reverse(&2, List<&2, U32>, ids), 0n)
      +ls = pick.locs(cap, rest, n, List.reverse(&2, Lc, locs), 0n)
      +k = List.length(&2, Lc, ls)
      +r = grps.cap(cap, rest, more)
      Bool.pick(List<&2, Grp>, Nat.is_eq(k, 0n), r, Grp{k, xs, ls} <> r)

def send.grps(+q: Chan(Job), gs: List<&2, Grp>) -> IO(Unit):
  match gs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Grp{n, ids, locs} <> more:
      do IO<Unit>:
        ok : Bool <- Chan.send(Job, q, Keyed{ids, locs})
        send.grps(q, more)

def Grp.sum(gs: List<&2, Grp>) -> Nat:
  match gs:
    case Nil{}:
      0n
    case Grp{n, i, l} <> more:
      Nat.add(n, Grp.sum(more))

def List.head.or(gs: List<&2, Grp>) -> Grp:
  match gs:
    case g <> more:
      g
    case Nil{}:
      Grp{0n, Nil{}, Nil{}}

# every unit read once for its package; then the packages as jobs, the
# largest first
def kp.sent(+cap: Nat, +rest: Bool, +q: Chan(Job), k: Kp) -> IO(Unit):
  match k:
    case Kp{rd, i, off, +m, order, g}:
      +gs = List.sort(~Grp, ~grp.le, grps.cap(cap, rest, grps(m, List.reverse(&2, String, order))))
      do IO<Unit>:
        S.Rd.close(rd)
        Ck.log("bend-check: " ++ Nat.show(Grp.sum(gs)) ++ " of " ++ Nat.show(i) ++ " units in " ++ Nat.show(List.length(&2, Grp, gs)) ++ " packages, the largest " ++ Nat.show(Grp.n(List.head.or(gs))))
        send.grps(q, gs)

# SHARD of SHARDS (default 0 of 1), PKG_CAP (0: none), PKG_REST (1: the
# units the cap leaves out)
def dispatch.keyed(+cs: String, +dirs: Set(), +units: String, +q: Chan(Job)) -> IO(Unit):
  do IO<Unit>:
    +sk : Nat <- S.env.nat("SHARD", 0n)
    +sn : Nat <- S.env.nat("SHARDS", 1n)
    +cap : Nat <- S.env.nat("PKG_CAP", 0n)
    +rest : Nat <- S.env.nat("PKG_REST", 0n)
    Ck.log("bend-check: shard " ++ Nat.show(sk) ++ " of " ++ Nat.show(sn) ++ ", package cap " ++ Nat.show(cap) ++ Bool.pick(String, Nat.is_eq(rest, 0n), "", " (the rest)"))
    rd : S.Rd <- S.Rd.open(units)
    k : Kp <- kp.go(big(), cs, dirs, sk, sn, Kp{rd, 0n, 0n, Map.new(&2, Grp), Nil{}, True{}})
    kp.sent(cap, Bool.not(Nat.is_eq(rest, 0n)), q, k)

def dispatch.fin(r: S.Rd & Nat) -> IO(Unit):
  (rd, n) = r
  S.Rd.close(rd)

def dispatch.stream(+c: Cfg, +units: String, +q: Chan(Job)) -> IO(Unit):
  do IO<Unit>:
    +sk : Nat <- S.env.nat("SHARD", 0n)
    +sn : Nat <- S.env.nat("SHARDS", 1n)
    Ck.log("bend-check: shard " ++ Nat.show(sk) ++ " of " ++ Nat.show(sn))
    rd : S.Rd <- S.Rd.open(units)
    r : S.Rd & Nat <- dp.go(big(), c, sk, sn, q, Dp{rd, 0n, Nil{}, Nil{}, 0n, True{}})
    dispatch.fin(r)

def dispatch(+c: Cfg, +units: String, +q: Chan(Job)) -> IO(Unit):
  match c:
    case Haskell{h, u, +dirs}:
      dispatch.keyed(Hs.Hc.cs(h), dirs, units, q)
    case _:
      dispatch.stream(c, units, q)

# The merge: the part files, each in position order, into RESULTS.nul -------

type Tri is Data:
  Tri{i: Nat, id: List<&2, U32>, rec: List<&2, U32>}

def Tri.i(+t: Tri) -> Nat:
  match t:
    case Tri{i, id, rec}:
      i

type Hd is Type:
  Hd{rd: S.Rd, top: Maybe<&2, Tri>}

def num(+xs: List<&2, U32>) -> Nat:
  Maybe.default(&2, Nat, Nat.read(S.str(xs)), 0n)

def hd.rec.m(+ix: Nat, +id: List<&2, U32>, rd: S.Rd, m: Maybe<&2, List<&2, U32>>) -> IO(Hd):
  match m:
    case None{}:
      do IO<Hd>:
        S.Rd.close(rd)
        IO.die(Hd, 1, "bend-check: a part file ends inside a triple")
    case Some{rec}:
      IO.pure(Hd, Hd{rd, Some{Tri{ix, id, rec}}})

def hd.rec(+ix: Nat, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Hd):
  (rd, m) = r
  hd.rec.m(ix, id, rd, m)

def hd.id.m(+ix: Nat, rd: S.Rd, m: Maybe<&2, List<&2, U32>>) -> IO(Hd):
  match m:
    case None{}:
      do IO<Hd>:
        S.Rd.close(rd)
        IO.die(Hd, 1, "bend-check: a part file ends inside a triple")
    case Some{+id}:
      do IO<Hd>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        hd.rec(ix, id, r)

def hd.id(+ix: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Hd):
  (rd, m) = r
  hd.id.m(ix, rd, m)

def hd.ix.m(rd: S.Rd, m: Maybe<&2, List<&2, U32>>) -> IO(Hd):
  match m:
    case None{}:
      IO.pure(Hd, Hd{rd, None{}})
    case Some{+x}:
      do IO<Hd>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        hd.id(num(x), r)

def hd.ix(r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Hd):
  (rd, m) = r
  hd.ix.m(rd, m)

# a part file's next triple
def hd.next(rd: S.Rd) -> IO(Hd):
  do IO<Hd>:
    r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
    hd.ix(r)

def better(top: Maybe<&2, Tri>, best: Maybe<&2, Nat>) -> Maybe<&2, Nat>:
  match top best:
    case None{} _:
      best
    case Some{Tri{i, id, rec}} None{}:
      Some{i}
    case Some{Tri{+i, id, rec}} Some{+b}:
      Some{Bool.pick(Nat, Nat.is_lt(i, b), i, b)}

def hd.min.put(h: Hd, r: List<Hd> & Maybe<&2, Nat>) -> List<Hd> & Maybe<&2, Nat>:
  (hs, b) = r
  (h <> hs, b)

# the smallest position on top of any part, the heads handed back
def hd.min(hs: List<Hd>, best: Maybe<&2, Nat>) -> List<Hd> & Maybe<&2, Nat>:
  match hs:
    case Nil{}:
      (Nil{}, best)
    case Hd{rd, +top} <> more:
      hd.min.put(Hd{rd, top}, hd.min(more, better(top, best)))

type Ac is Type:
  Ac{done: List<Hd>, out: File}

def hd.hit(hit: Bool, rd: S.Rd, +t: Tri, done: List<Hd>, out: File) -> IO(Ac):
  match hit t:
    case False{} _:
      IO.pure(Ac, Ac{Hd{rd, Some{t}} <> done, out})
    case True{} Tri{i, id, rec}:
      do IO<Ac>:
        o : File <- S.emit(out, S.append(id, 0 <> S.append(rec, [0])))
        h : Hd <- hd.next(rd)
        return Ac{h <> done, o}

def hd.one.t(rd: S.Rd, top: Maybe<&2, Tri>, +ix: Nat, done: List<Hd>, out: File) -> IO(Ac):
  match top:
    case None{}:
      IO.pure(Ac, Ac{Hd{rd, None{}} <> done, out})
    case Some{+t}:
      hd.hit(Nat.is_eq(Tri.i(t), ix), rd, t, done, out)

def hd.one(h: Hd, +ix: Nat, a: Ac) -> IO(Ac):
  match h a:
    case Hd{rd, top} Ac{done, out}:
      hd.one.t(rd, top, ix, done, out)

# the head holding position ix written out and advanced; the others kept
def hd.adv(hs: List<Hd>, +ix: Nat, a: Ac) -> IO(Ac):
  match hs:
    case Nil{}:
      IO.pure(Ac, a)
    case h <> more:
      IO.bind(Ac, Ac, hd.one(h, ix, a), hd.adv(more, ix))

type Mg is Type:
  Mg{hs: List<Hd>, out: File, go: Bool}

def mg.of(a: Ac) -> Mg:
  match a:
    case Ac{d, o}:
      Mg{d, o, True{}}

def mg.min.b(hs: List<Hd>, b: Maybe<&2, Nat>, out: File) -> IO(Mg):
  match b:
    case None{}:
      IO.pure(Mg, Mg{hs, out, False{}})
    case Some{+ix}:
      do IO<Mg>:
        a : Ac <- hd.adv(hs, ix, Ac{Nil{}, out})
        return mg.of(a)

def mg.min(r: List<Hd> & Maybe<&2, Nat>, out: File) -> IO(Mg):
  (hs, b) = r
  mg.min.b(hs, b, out)

def mg.step(m: Mg) -> IO(Mg):
  match m:
    case Mg{hs, out, g}:
      mg.min(hd.min(hs, None{}), out)

def hd.close(hs: List<Hd>) -> IO(Unit):
  match hs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Hd{rd, top} <> more:
      do IO<Unit>:
        S.Rd.close(rd)
        hd.close(more)

def mg.go(fuel: Nat, m: Mg) -> IO(Unit):
  match fuel m:
    case 1n+p Mg{hs, out, True{}}:
      IO.bind(Mg, Unit, mg.step(Mg{hs, out, True{}}), mg.go(p))
    case _ Mg{hs, out, g}:
      do IO<Unit>:
        hd.close(hs)
        File.close(out)

def heads(n: Nat, +k: Nat, +work: String) -> IO(List<Hd>):
  match n:
    case 0n:
      IO.pure(List<Hd>, Nil{})
    case 1n+m:
      do IO<List<Hd>>:
        rd : S.Rd <- S.Rd.open(work ++ "/part." ++ Nat.show(k))
        h : Hd <- hd.next(rd)
        rest : List<Hd> <- heads(m, 1n+k, work)
        return h <> rest

def merge(+jobs: Nat, +work: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    hs : List<Hd> <- heads(jobs, 0n, work)
    f : File <- IO.try(File, File.open(out, "w"))
    mg.go(big(), Mg{hs, f, True{}})

# Main -------------------------------------------------------------------------

def stat.get(st: List<&2, L.Stat>, +key: String) -> Nat:
  match st:
    case Nil{}:
      0n
    case L.Stat{+k, +n} <> more:
      Bool.pick(Nat, String.eq(k, key), n, stat.get(more, key))

def tidy(gone: Bool, +work: String) -> IO(Unit):
  match gone:
    case True{}:
      S.rm(work)
    case False{}:
      IO.print_err("work: " ++ work)

def finish(+keep: String, +work: String, +out: String, +st: List<&2, L.Stat>) -> IO(Unit):
  do IO<Unit>:
    S.write(out ++ ".stats", S.b(L.stat.show(st)))
    Ck.log("bend-check: " ++ Nat.show(stat.get(st, "kept")) ++ " of " ++ Nat.show(stat.get(st, "units")) ++ " units kept; " ++ out)
    IO.write(L.stat.show(st))
    tidy(String.is_empty(keep), work)

# elan's toolchain directory for a lean-toolchain line: the first `/` is
# `--`, the first `:` is `---` (leanprover/lean4:v4.34.0 names
# leanprover--lean4---v4.34.0)
def toolchain(+xs: List<&2, U32>) -> String:
  S.str(S.chomp(S.replace.first(S.replace.first(xs, [47], S.b("--")), [58], S.b("---"))))

def lean.path(have: Bool, +bin: String, +path: String) -> String:
  match have:
    case True{}:
      bin ++ ":" ++ path
    case False{}:
      path

def store.agda.at(hit: Bool, +t: List<&2, U32>, r: Maybe<&2, String>) -> Maybe<&2, String>:
  match hit:
    case False{}:
      r
    case True{}:
      +q = Ag.upto(t, 34)
      Bool.pick(Maybe<&2, String>, Bool.and(S.suffix(q, S.b("/bin/agda")), Bool.not(Nat.is_eq(S.len(q), S.len(t)))), Some{S.str(q)}, r)

# The real agda behind nixpkgs' wrapper (the wrapper passes its own
# --library-file): the first quoted "/nix/store/.../bin/agda" in it.
def store.agda(xs: List<&2, U32>) -> Maybe<&2, String>:
  match xs:
    case Nil{}:
      None{}
    case +h <> +t:
      store.agda.at(S.prefix(h <> t, S.b("\"/nix/store/")), t, store.agda(t))

def agda.bin(m: Maybe<&2, String>, +w: String) -> String:
  match m:
    case Some{b}:
      b
    case None{}:
      w

def libs.there(ok: Bool, +libs: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "bend-check: " ++ libs ++ " missing: run bend-check agda-libs")

def words.str(ws: List<&2, List<&2, U32>>) -> List<&2, String>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> more:
      S.str(w) <> words.str(more)

def hide.of(+have: Set(), ps: List<&2, String>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> more:
      +r = hide.of(have, more)
      Bool.pick(List<&2, String>, set.has(have, p), "-hide-package" <> p <> r, r)

def tar.map(ls: List<&2, List<&2, U32>>, m: Map<&2, String>) -> Map<&2, String>:
  match ls:
    case Nil{}:
      m
    case +l <> more:
      +b = L.before.last(l, S.b(".tar.gz"))
      tar.map(more, Map.set(&2, String, m, S.str(L.before.last(b, [45])), S.str(b)))

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-check nix|bend|lean|agda|haskell UNITS.nul RESULTS.nul [JOBS] | bend-check agda-libs [precompile]")

def lang.code(+l: String) -> Nat:
  Bool.pick(Nat, String.eq(l, "nix"), 1n, Bool.pick(Nat, String.eq(l, "bend"), 2n, Bool.pick(Nat, String.eq(l, "lean"), 3n,
    Bool.pick(Nat, String.eq(l, "agda"), 4n, Bool.pick(Nat, String.eq(l, "haskell"), 5n, 0n)))))

def jobs.of(m: Maybe<&2, Nat>, +d: Nat) -> Nat:
  match m:
    case Some{+n}:
      Bool.pick(Nat, Nat.is_eq(n, 0n), d, n)
    case None{}:
      d

# a package's units, a chunk at a time, read back from UNITS.nul
def keyed.go(fuel: Nat, +c: Cfg, +dir: String, +part: String, +ids: List<&2, List<&2, U32>>, +locs: List<&2, Lc>, st: List<&2, L.Stat>) -> IO(Wk):
  match fuel c locs:
    case 0n _ _:
      IO.pure(Wk, Wk{True{}, st})
    case _ _ Nil{}:
      IO.pure(Wk, Wk{True{}, st})
    case 1n+f Haskell{+h, +path, +dirs} +l <> +more:
      do IO<Wk>:
        +us : List<&2, L.U> <- read.chunk(path, List.take(&2, Lc, l <> more, keyed.chunk()))
        +gs : List<&2, L.Got> <- Hs.job(h, dir, ids, us)
        S.add(part, part.bytes(us, gs))
        keyed.go(f, Haskell{h, path, dirs}, dir, part, ids, List.drop(&2, Lc, l <> more, keyed.chunk()), job.stats(gs, st))
    case _ _ _:
      IO.pure(Wk, Wk{True{}, st})

def wk.got(+c: Cfg, +k: Nat, +dir: String, +part: String, m: Maybe<&1, Job>, st: List<&2, L.Stat>) -> IO(Wk):
  match m:
    case None{}:
      IO.pure(Wk, Wk{False{}, st})
    case Some{Job{+us}}:
      do IO<Wk>:
        +gs : List<&2, L.Got> <- Cfg.job(c, k, dir, us)
        wk.done(part, us, gs, st)
    case Some{Keyed{+ids, +locs}}:
      keyed.go(1n+List.length(&2, Lc, locs), c, dir, part, ids, locs, st)

def wk.step(+c: Cfg, +k: Nat, +dir: String, +part: String, +jobs: Chan(Job), w: Wk) -> IO(Wk):
  match w:
    case Wk{g, st}:
      do IO<Wk>:
        m : Maybe<&1, Job> <- Chan.recv(Job, jobs)
        wk.got(c, k, dir, part, m, st)

def wk.go(fuel: Nat, +c: Cfg, +k: Nat, +dir: String, +part: String, +jobs: Chan(Job), w: Wk) -> IO(List<&2, L.Stat>):
  match fuel w:
    case 1n+p Wk{True{}, st}:
      IO.bind(Wk, List<&2, L.Stat>, wk.step(c, k, dir, part, jobs, Wk{True{}, st}), wk.go(p, c, k, dir, part, jobs))
    case _ Wk{g, st}:
      IO.pure(List<&2, L.Stat>, st)

# worker k: its own directory and part file
def wk(+c: Cfg, +k: Nat, +work: String, +jobs: Chan(Job)) -> IO(List<&2, L.Stat>):
  +dir = work ++ "/" ++ Nat.show(k)
  +part = work ++ "/part." ++ Nat.show(k)
  do IO<List<&2, L.Stat>>:
    S.mkdir(dir)
    S.write(part, Nil{})
    wk.go(big(), c, k, dir, part, jobs, Wk{True{}, Nil{}})

def fork.all(n: Nat, +k: Nat, +c: Cfg, +work: String, +jobs: Chan(Job)) -> IO(List<Chan(List<&2, L.Stat>)>):
  match n:
    case 0n:
      IO.pure(List<Chan(List<&2, L.Stat>)>, Nil{})
    case 1n+m:
      do IO<List<Chan(List<&2, L.Stat>)>>:
        ch : Chan(List<&2, L.Stat>) <- IO.fork(List<&2, L.Stat>, wk(c, k, work, jobs))
        rest : List<Chan(List<&2, L.Stat>)> <- fork.all(m, 1n+k, c, work, jobs)
        return ch <> rest

def check(+c: Cfg, +units: String, +out: String, +jobs: Nat) -> IO(Unit):
  do IO<Unit>:
    +work : String <- S.mktemp()
    +keep : String <- S.env("KEEP_WORK", "")
    Ck.log("bend-check " ++ Cfg.name(c) ++ ": " ++ units ++ " with " ++ Nat.show(jobs) ++ " workers in " ++ work)
    +q : Chan(Job) <- Chan.new(Job, U32.from_nat(jobs))
    chs : List<Chan(List<&2, L.Stat>)> <- fork.all(jobs, 0n, c, work, q)
    dispatch(c, units, q)
    Chan.close(Job, q)
    +st : List<&2, L.Stat> <- join.all(chs, Nil{})
    merge(jobs, work, out)
    finish(keep, work, out, st)

def cfg.haskell(+jobs: Nat, +units: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- S.env.nat("TIMEOUT", 60n)
    +cap : Nat <- S.env.nat("CAP_LINES", 100n)
    +root0 : String <- S.env("PWD", ".")
    +root : String <- S.realpath(root0)
    +ghc : String <- S.env("GHC", root ++ "/run/check-cache/ghc-harness/bin/ghc")
    +cs : String = root ++ "/run/code-sources"
    +hc : String <- S.env("HC", root ++ "/run/check-cache/hs")
    S.mkdir(hc ++ "/src")
    S.mkdir(hc ++ "/hi")
    S.mkdir(hc ++ "/info")
    tb : S.Out <- S.run(".", [], 600, "find", [cs ++ "/tarballs", "-maxdepth", "1", "-name", "*.tar.gz", "-printf", "%f\n"], Nil{})
    tbs : List<&2, List<&2, U32>> <- Hs.sorted(S.split.lines(S.Out.text(tb)))
    n1 : S.Out <- S.run.quiet(".", [], 600, S.parent(ghc) ++ "/ghc-pkg", ["list", "--simple-output", "--names-only"], Nil{})
    n2 : S.Out <- S.run.quiet(".", [], 600, S.parent(ghc) ++ "/ghc-pkg", ["list", "--simple-output"], Nil{})
    +have : Set() = Set.from_list(words.str(List.append(&2, List<&2, U32>, L.words(S.Out.text(n1)), L.words(S.Out.text(n2)))))
    +hide : List<&2, String> = hide.of(have, ["rerebase", "relude", "monads-tf", "crypton", "base-compat-batteries", "ghc-lib-parser", "ghc-lib", "ram", "regex-pcre-builtin", "skylighting-core"])
    cd : S.Out <- S.run(".", [], 600, "find", [cs ++ "/repos", cs ++ "/own", cs ++ "/curated", "(", "-name", "*.cabal", "-o", "-name", "*.cabal.in", ")",
      "-not", "-path", "*/.git/*", "-not", "-path", "*/dist-newstyle/*", "-printf", "%h\n"], Nil{})
    +dirs : Set() = Set.from_list(words.str(S.split.lines(S.Out.text(cd))))
    check(Haskell{Hs.Hc{ghc, cs, hc, U32.from_nat(t), cap, have, hide, tar.map(tbs, Map.new(&2, String))}, units, dirs}, units, out, jobs)

def cfg.nix(+jobs: Nat, +units: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- S.env.nat("TIMEOUT", 30n)
    +cap : Nat <- S.env.nat("CAP_LINES", 100n)
    check(Nix{U32.from_nat(t), cap}, units, out, jobs)

def cfg.bend(+jobs: Nat, +units: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- S.env.nat("TIMEOUT", 60n)
    +cap : Nat <- S.env.nat("CAP_LINES", 100n)
    +bend : String <- S.env("BEND", "bend")
    +home : String <- S.env("HOME", "/")
    +src0 : String <- S.env("BEND_SRC", home ++ "/src")
    +src : String <- S.realpath(src0)
    check(Bnd{Bd.Cf{bend, src, U32.from_nat(t), cap}}, units, out, jobs)

def cfg.lean(+jobs: Nat, +units: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- S.env.nat("TIMEOUT", 300n)
    +cap : Nat <- S.env.nat("CAP_LINES", 100n)
    +m0 : String <- S.env("MATHLIB", "run/harness/mathlib4")
    +ml : String <- S.realpath(m0)
    +h0 : String <- S.env("HARNESS", "deploy/check/Harness.lean")
    +harness : String <- S.realpath(h0)
    +home : String <- S.env("HOME", "/")
    tc : List<&2, U32> <- S.read(ml ++ "/lean-toolchain")
    +bin : String = home ++ "/.elan/toolchains/" ++ toolchain(tc) ++ "/bin"
    +have : Bool <- S.exists(bin)
    +p0 : String <- S.env("PATH", "")
    +path : String = lean.path(have, bin, p0)
    +lp : List<&2, U32> <- S.must("lake env in " ++ ml, "env", ["-C", ml, "PATH=" ++ path, "lake", "env", "printenv", "LEAN_PATH"])
    check(Lean{Ln.Cf{["PATH=" ++ path, "LEAN_PATH=" ++ S.str(S.chomp(lp))], harness, U32.from_nat(t), cap}}, units, out, jobs)

def cfg.agda(+jobs: Nat, +units: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    +t : Nat <- S.env.nat("TIMEOUT", 120n)
    +cap : Nat <- S.env.nat("CAP_LINES", 100n)
    +root0 : String <- S.env("PWD", ".")
    +root : String <- S.realpath(root0)
    +libs : String <- S.env("AGDA_LIBS", root ++ "/run/check-cache/agda/libraries")
    +have : Bool <- S.exists(libs)
    libs.there(have, libs)
    +a : String <- S.env("AGDA", "agda")
    w0 : List<&2, U32> <- S.must("command -v " ++ a, "sh", ["-c", "command -v \"$1\"", "sh", a])
    +w : String = S.str(S.chomp(w0))
    wt : List<&2, U32> <- S.read(w)
    check(Agda{Ag.Cf{agda.bin(store.agda(wt), w), libs, root ++ "/run/code-sources", U32.from_nat(t), cap}}, units, out, jobs)

def lang(code: Nat, +jobs: Nat, +units: String, +out: String) -> IO(Unit):
  match code:
    case 1n:
      cfg.nix(jobs, units, out)
    case 2n:
      cfg.bend(jobs, units, out)
    case 3n:
      cfg.lean(jobs, units, out)
    case 4n:
      cfg.agda(jobs, units, out)
    case 5n:
      cfg.haskell(jobs, units, out)
    case _:
      usage()

def libs(ok: Bool, pre: Bool) -> IO(Unit):
  match ok:
    case True{}:
      Al.run(pre)
    case False{}:
      usage()

def args.go(xs: List<String>, +threads: Nat) -> IO(Unit):
  match xs:
    case +l <> Nil{}:
      libs(String.eq(l, "agda-libs"), False{})
    case +l <> +p <> Nil{}:
      libs(Bool.and(String.eq(l, "agda-libs"), String.eq(p, "precompile")), True{})
    case +l <> u <> o <> Nil{}:
      lang(lang.code(l), threads, u, o)
    case +l <> u <> o <> j <> Nil{}:
      lang(lang.code(l), jobs.of(Nat.read(j), threads), u, o)
    case _:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    +n : U32 <- IO.thread_count()
    args.go(xs, U32.to_nat(n))
