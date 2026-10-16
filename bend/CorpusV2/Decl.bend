import Base
import ../Sys.bend as S
import ../Json.bend as J
import ../Check/Lib.bend as Cl
import ./Lib.bend as L
import ./Pool.bend as P
import ./Keyed.bend as K

# decl-new: a new wave's units less what the corpus already trains on or holds
# out, declaration by declaration (2026-10-16, run 5's collection: the pool's
# one-unit-a-declaration rule and corpus v2's holdout carried to a wave that
# comes after the pool).
#
#   bend-corpus-v2 decl-new UNITS OUT [held=FILE]... [seen=FILE]... [cap=PREFIX:N]...
#
# UNITS, a seen FILE and a held FILE ending in .nul are NUL pairs: an id
# (`FILE#NAME@LINE`), then a record whose fields are joined by 0x1E, as
# bend-units writes them or bend-check's results (fields 0..10 are the
# unit's either way: Check/Lib.bend).  A held FILE ending in .jsonl is source
# files, `{"id", "text"}` lines.  A held file is held out (a vault, a
# holdout, held-out units); a seen file is units the corpus trains on.
#
# A unit's declaration is the pool's key (Pool.bend's po.decl: sha256 of its
# language, signature and body, NUL between); its file is its id before the
# `#`; its file's text is its head, pre, body and tail (fields 5 to 8, the
# file byte for byte: Units.bend), keyed as corpus v2 keys a text (L.v2.key;
# computed once a file: a file's units are consecutive).  Each unit of
# UNITS, in order, is dropped for the first of these that holds, else kept:
#
#   v2-held     its id is held out by V2_HOLDOUT's units and paths (run/v2/holdout;
#               L.v2.held.id: a held-out repository, directory, file or path)
#   held-file   its file is a held file (a held .jsonl's id, a held unit's file)
#   held-text   its file's content key is a held file's, or V2_HOLDOUT's exclude.sha256 has it
#   held-decl   its declaration is a held unit's
#   seen        its declaration is a seen unit's
#   cap         its file's id starts with a cap's PREFIX (the first such cap) and
#               the file has more than N units in UNITS, and it is not one of
#               the N kept: every stride-th unit of the file from its first,
#               stride the file's count div N (bend-units' MAX_PER_FILE spread
#               with offset 0; a first pass counts the capped files' units)
#   dup         its declaration is an earlier kept unit's of UNITS
#
# A cap brings a rule of an earlier wave to this one: community round 3 cut
# Giulio2002/bend-collections at 16 units a file (the user's round 1 rule:
# its one-line forwarding proofs cost about 40 CPU-s a unit to check).
#
# OUT: the kept pairs as they stand, in UNITS' order (written as OUT.tmp,
# moved at the end); OUT.dropped: `REASON TAB ID` a dropped unit; OUT.stats:
# `key count` lines in byte order (every reason, kept and units, zeros too),
# also printed.  Logs go to stderr, stamped UTC-6.  The laws are
# bend/tests/decl.bend.  Every def is prefixed `dcl.`.

def dcl.log(+msg: String) -> IO(Unit):
  K.kor.log("decl-new", msg)

def dcl.big() -> Nat:
  U32.to_nat(4294967295)

# the reasons, by code (0: kept)
def dcl.reason(n: Nat) -> String:
  match n:
    case 1n:
      "v2-held"
    case 2n:
      "held-file"
    case 3n:
      "held-text"
    case 4n:
      "held-decl"
    case 5n:
      "seen"
    case 6n:
      "dup"
    case 7n:
      "cap"
    case _:
      "kept"

# every key at 0, so the stats always list them
def dcl.st0() -> List<&2, Cl.Stat>:
  [Cl.Stat{"units", 0n}, Cl.Stat{"kept", 0n}, Cl.Stat{"v2-held", 0n}, Cl.Stat{"held-file", 0n}, Cl.Stat{"held-text", 0n},
    Cl.Stat{"held-decl", 0n}, Cl.Stat{"seen", 0n}, Cl.Stat{"cap", 0n}, Cl.Stat{"dup", 0n}]

# A unit (pure) -------------------------------------------------------------------

# its file: the id before the `#`
def dcl.file(+id: List<&2, U32>) -> List<&2, U32>:
  L.v2.before(id, 35)

# its file's text: fields 5 to 8 (head, pre, body, tail)
def dcl.text(+rec: List<&2, U32>) -> List<&2, U32>:
  L.v2.concat(List.take(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, Cl.fields(rec), 5n), 4n))

# its declaration's key (the pool's)
def dcl.decl(+rec: List<&2, U32>) -> String:
  P.po.decl(rec)

# its file's content key: the last file's when it is the same file
def dcl.tkey(same: Bool, +pk: String, +rec: List<&2, U32>) -> String:
  match same:
    case True{}:
      pk
    case False{}:
      L.v2.key(dcl.text(rec))

# The held-out and seen sets ------------------------------------------------------

# files: held files (as their ids); texts: their content keys; ds: held (or
# seen) declarations; pf, pk: the last held unit's file and its content key
type DclAdd is Data:
  DclAdd{fs: Set(), ts: Set(), ds: Set(), pf: List<&2, U32>, pk: String}

def dcl.add0() -> DclAdd:
  DclAdd{Set.new(), Set.new(), Set.new(), [0], ""}

# a unit of a held (True) or seen (False) file
def dcl.add.unit(held: Bool, a: DclAdd, +id: List<&2, U32>, +rec: List<&2, U32>) -> DclAdd:
  match held a:
    case True{} DclAdd{fs, ts, ds, +pf, +pk}:
      +file = dcl.file(id)
      +tk = dcl.tkey(S.eq(file, pf), pk, rec)
      DclAdd{Set.add(fs, S.str(file)), Set.add(ts, tk), Set.add(ds, dcl.decl(rec)), file, tk}
    case False{} DclAdd{fs, ts, ds, pf, pk}:
      DclAdd{fs, ts, Set.add(ds, dcl.decl(rec)), pf, pk}

# a line of a held .jsonl (a line that is no record adds nothing)
def dcl.add.doc(m: Maybe<&2, J.Doc>, a: DclAdd) -> DclAdd:
  match m a:
    case Some{J.Doc{+i, +t}} DclAdd{fs, ts, ds, pf, pk}:
      DclAdd{Set.add(fs, S.str(i)), Set.add(ts, L.v2.key(t)), ds, pf, pk}
    case None{} DclAdd{fs, ts, ds, pf, pk}:
      DclAdd{fs, ts, ds, pf, pk}

# a file's records into the sets: mode 1 held units, 2 held source files, 3 seen units
type DclLd is Type:
  DclLd{r: S.Rd, a: DclAdd, n: Nat, more: Bool}

def dcl.ld.text(held: Bool, a: DclAdd, +n: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(DclLd):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(DclLd, DclLd{r, a, n, False{}})
    case Some{+rec}:
      IO.pure(DclLd, DclLd{r, dcl.add.unit(held, a, id, rec), 1n+n, True{}})

def dcl.ld.id(held: Bool, r: S.Rd, a: DclAdd, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(DclLd):
  match m:
    case None{}:
      IO.pure(DclLd, DclLd{r, a, n, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclLd, S.Rd.next(r), dcl.ld.text(held, a, n, id))

def dcl.ld.got(held: Bool, a: DclAdd, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(DclLd):
  (r, m) = x
  dcl.ld.id(held, r, a, n, m)

def dcl.ld.line(a: DclAdd, +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(DclLd):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(DclLd, DclLd{r, a, n, False{}})
    case Some{+l}:
      IO.pure(DclLd, DclLd{r, dcl.add.doc(J.doc(l), a), 1n+n, True{}})

def dcl.ld.step(mode: Nat, s: DclLd) -> IO(DclLd):
  match mode s:
    case 2n DclLd{r, a, n, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclLd, S.Rd.next(r), dcl.ld.line(a, n))
    case 1n DclLd{r, a, n, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclLd, S.Rd.next(r), dcl.ld.got(True{}, a, n))
    case _ DclLd{r, a, n, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclLd, S.Rd.next(r), dcl.ld.got(False{}, a, n))

def dcl.ld.go(fuel: Nat, +mode: Nat, s: DclLd) -> IO(DclLd):
  match fuel s:
    case 1n+f DclLd{r, a, n, True{}}:
      IO.bind(DclLd, DclLd, dcl.ld.step(mode, DclLd{r, a, n, True{}}), dcl.ld.go(f, mode))
    case _ DclLd{r, a, n, g}:
      IO.pure(DclLd, DclLd{r, a, n, g})

def dcl.ld.fin(+what: String, +path: String, s: DclLd) -> IO(DclAdd):
  match s:
    case DclLd{r, a, +n, g}:
      do IO<DclAdd>:
        S.Rd.close(r)
        dcl.log(what ++ " " ++ path ++ ": " ++ Nat.show(n) ++ " records")
        return a

def dcl.is.jsonl(+path: String) -> Bool:
  S.suffix(S.b(path), S.b(".jsonl"))

# held: a .jsonl is source files (2), anything else units (1); seen: units (3)
def dcl.mode(held: Bool, +path: String) -> Nat:
  Bool.pick(Nat, held, Bool.pick(Nat, dcl.is.jsonl(path), 2n, 1n), 3n)

def dcl.load(+held: Bool, +path: String, a: DclAdd) -> IO(DclAdd):
  +mode = dcl.mode(held, path)
  do IO<DclAdd>:
    r : S.Rd <- Bool.pick(IO(S.Rd), Nat.is_eq(mode, 2n), S.Rd.lines(path), S.Rd.open(path))
    s : DclLd <- dcl.ld.go(dcl.big(), mode, DclLd{r, a, 0n, True{}})
    dcl.ld.fin(Bool.pick(String, held, "held", "seen"), path, s)

def dcl.loads(+held: Bool, ps: List<String>, a: DclAdd) -> IO(DclAdd):
  match ps:
    case Nil{}:
      IO.pure(DclAdd, a)
    case +p <> more:
      do IO<DclAdd>:
        a2 : DclAdd <- dcl.load(held, p, a)
        dcl.loads(held, more, a2)

# Caps -------------------------------------------------------------------------------

# a cap: the files whose id starts with pre keep at most n units
type DclCap is Data:
  DclCap{pre: List<&2, U32>, n: Nat}

# N of the first cap whose PREFIX the file's id starts with (0: none)
def dcl.cap.of(+caps: List<&2, DclCap>, +file: List<&2, U32>) -> Nat:
  match caps:
    case Nil{}:
      0n
    case DclCap{+pre, +n} <> more:
      Bool.pick(Nat, S.prefix(file, pre), n, dcl.cap.of(more, file))

# the unit at i of a file of n units is kept under cap: every stride-th from
# the first, the first cap of them (all when cap is 0 or n is at most cap)
def dcl.sel(+i: Nat, +n: Nat, +cap: Nat) -> Bool:
  +stride = Nat.max(Nat.div(n, Nat.max(cap, 1n)), 1n)
  Bool.or(Bool.or(Nat.is_eq(cap, 0n), Nat.is_le(n, cap)),
    Bool.and(Nat.is_eq(Nat.mod(i, stride), 0n), Nat.is_lt(Nat.div(i, stride), cap)))

def dcl.n.fin(r: Map<&2, Nat> & Nat) -> Nat:
  (m, n) = r
  n

# the units a capped file has in UNITS (the first pass's count)
def dcl.n.of(+m: Map<&2, Nat>, +file: List<&2, U32>) -> Nat:
  dcl.n.fin(Map.get(Nat, 0n, m, S.str(file)))

# The first pass: the capped files' units counted
type DclCn is Type:
  DclCn{r: S.Rd, m: Map<&2, Nat>, more: Bool}

def dcl.cn.set(+k: String, r: Map<&2, Nat> & Nat) -> Map<&2, Nat>:
  (m, n) = r
  Map.set(&2, Nat, m, k, 1n+n)

def dcl.cn.bump(go: Bool, m: Map<&2, Nat>, +k: String) -> Map<&2, Nat>:
  match go:
    case True{}:
      dcl.cn.set(k, Map.get(Nat, 0n, m, k))
    case False{}:
      m

def dcl.cn.add(+caps: List<&2, DclCap>, m: Map<&2, Nat>, +id: List<&2, U32>) -> Map<&2, Nat>:
  +file = dcl.file(id)
  dcl.cn.bump(Nat.is_lt(0n, dcl.cap.of(caps, file)), m, S.str(file))

def dcl.cn.text(+caps: List<&2, DclCap>, m: Map<&2, Nat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(DclCn):
  (r, t) = x
  match t:
    case None{}:
      IO.pure(DclCn, DclCn{r, m, False{}})
    case Some{rec}:
      IO.pure(DclCn, DclCn{r, dcl.cn.add(caps, m, id), True{}})

def dcl.cn.id(+caps: List<&2, DclCap>, r: S.Rd, m: Map<&2, Nat>, x: Maybe<&2, List<&2, U32>>) -> IO(DclCn):
  match x:
    case None{}:
      IO.pure(DclCn, DclCn{r, m, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclCn, S.Rd.next(r), dcl.cn.text(caps, m, id))

def dcl.cn.got(+caps: List<&2, DclCap>, m: Map<&2, Nat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(DclCn):
  (r, i) = x
  dcl.cn.id(caps, r, m, i)

def dcl.cn.go(fuel: Nat, +caps: List<&2, DclCap>, s: DclCn) -> IO(DclCn):
  match fuel s:
    case 1n+f DclCn{r, m, True{}}:
      IO.bind(DclCn, DclCn, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclCn, S.Rd.next(r), dcl.cn.got(caps, m)), dcl.cn.go(f, caps))
    case _ DclCn{r, m, g}:
      IO.pure(DclCn, DclCn{r, m, g})

def dcl.cn.fin(s: DclCn) -> IO(Map<&2, Nat>):
  match s:
    case DclCn{r, m, g}:
      do IO<Map<&2, Nat>>:
        S.Rd.close(r)
        return m

# no caps: no first pass
def dcl.count(+units: String, caps: List<&2, DclCap>) -> IO(Map<&2, Nat>):
  match caps:
    case Nil{}:
      IO.pure(Map<&2, Nat>, Map.new(&2, Nat))
    case +c <> +more:
      do IO<Map<&2, Nat>>:
        r : S.Rd <- S.Rd.open(units)
        s : DclCn <- dcl.cn.go(dcl.big(), c <> more, DclCn{r, Map.new(&2, Nat), True{}})
        dcl.cn.fin(s)

# What a unit is judged against: V2_HOLDOUT's exclusion, the held files,
# their texts' keys, the held declarations, the seen declarations, the caps
# and the capped files' counts.
type DclH is Data:
  DclH{e: L.Excl, fs: Set(), ts: Set(), ds: Set(), ss: Set(), caps: List<&2, DclCap>, cn: Map<&2, Nat>}

def dcl.h.of(+e: L.Excl, held: DclAdd, seen: DclAdd, +caps: List<&2, DclCap>, cn: Map<&2, Nat>) -> DclH:
  match held seen:
    case DclAdd{fs, ts, ds, pf, pk} DclAdd{gs, us, ss, qf, qk}:
      DclH{e, fs, ts, ds, ss, caps, cn}

# the first reason that holds (0: none); i is the unit's place in its file
def dcl.why(+h: DclH, +file: List<&2, U32>, +id: List<&2, U32>, +tk: String, +dk: String, +i: Nat) -> Nat:
  match h:
    case DclH{+e, fs, ts, ds, ss, +caps, +cn}:
      Bool.pick(Nat, L.v2.held.id(e, id), 1n,
        Bool.pick(Nat, L.v2.in(fs, S.str(file)), 2n,
          Bool.pick(Nat, Bool.or(L.v2.in(ts, tk), L.v2.held.key(e, tk)), 3n,
            Bool.pick(Nat, L.v2.in(ds, dk), 4n,
              Bool.pick(Nat, L.v2.in(ss, dk), 5n,
                Bool.pick(Nat, dcl.sel(i, dcl.n.of(cn, file), dcl.cap.of(caps, file)), 0n, 7n))))))

# a unit no other rule dropped is a duplicate when an earlier kept unit has
# its declaration; else its declaration is kept
def dcl.dup.was(was: Bool, s: Set(), +dk: String) -> Set() & Nat:
  match was:
    case True{}:
      (s, 6n)
    case False{}:
      (Set.add(s, dk), 0n)

def dcl.dup.got(+dk: String, x: Set() & Bool) -> Set() & Nat:
  (s, was) = x
  dcl.dup.was(was, s, dk)

def dcl.dup(why: Nat, kept: Set(), +dk: String) -> Set() & Nat:
  match why:
    case 0n:
      dcl.dup.got(dk, Set.has(kept, dk))
    case 1n+p:
      (kept, 1n+p)

# The pass over UNITS ---------------------------------------------------------------

# pf, pk, pi: the last unit's file, its content key and the last unit's place in it
type DclSt is Type:
  DclSt{r: S.Rd, o: File, d: File, kept: Set(), pf: List<&2, U32>, pk: String, pi: Nat, st: List<&2, Cl.Stat>, more: Bool}

# a kept pair to OUT, a dropped one's reason and id to OUT.dropped
def dcl.put(why: Nat, o: File, d: File, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(File & File):
  match why:
    case 0n:
      do IO<File & File>:
        o2 : File <- P.po.emit3(o, S.append(id, [0]), rec)
        return (o2, d)
    case 1n+p:
      do IO<File & File>:
        d2 : File <- S.emit(d, L.v2.concat([S.b(dcl.reason(1n+p)), [9], id, [10]]))
        return (o, d2)

def dcl.u.out(r: S.Rd, kept: Set(), +file: List<&2, U32>, +tk: String, +i: Nat, st: List<&2, Cl.Stat>, x: File & File) -> IO(DclSt):
  (o, d) = x
  IO.pure(DclSt, DclSt{r, o, d, kept, file, tk, i, st, True{}})

def dcl.u.fin(r: S.Rd, o: File, d: File, +file: List<&2, U32>, +tk: String, +i: Nat, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +rec: List<&2, U32>, x: Set() & Nat) -> IO(DclSt):
  (kept, +why) = x
  do IO<DclSt>:
    od : File & File <- dcl.put(why, o, d, id, rec)
    dcl.u.out(r, kept, file, tk, i, Cl.stat.bump(dcl.reason(why), 1n, Cl.stat.bump("units", 1n, st)), od)

def dcl.u.rec(+h: DclH, r: S.Rd, o: File, d: File, kept: Set(), +pf: List<&2, U32>, +pk: String, +pi: Nat, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(DclSt):
  +file = dcl.file(id)
  +same = S.eq(file, pf)
  +i = Bool.pick(Nat, same, 1n+pi, 0n)
  +tk = dcl.tkey(same, pk, rec)
  +dk = dcl.decl(rec)
  dcl.u.fin(r, o, d, file, tk, i, st, id, rec, dcl.dup(dcl.why(h, file, id, tk, dk, i), kept, dk))

def dcl.u.text(+h: DclH, o: File, d: File, kept: Set(), +pf: List<&2, U32>, +pk: String, +pi: Nat, st: List<&2, Cl.Stat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(DclSt):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(DclSt, DclSt{r, o, d, kept, pf, pk, pi, st, False{}})
    case Some{+rec}:
      dcl.u.rec(h, r, o, d, kept, pf, pk, pi, st, id, rec)

def dcl.u.id(+h: DclH, r: S.Rd, o: File, d: File, kept: Set(), +pf: List<&2, U32>, +pk: String, +pi: Nat, st: List<&2, Cl.Stat>, m: Maybe<&2, List<&2, U32>>) -> IO(DclSt):
  match m:
    case None{}:
      IO.pure(DclSt, DclSt{r, o, d, kept, pf, pk, pi, st, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclSt, S.Rd.next(r), dcl.u.text(h, o, d, kept, pf, pk, pi, st, id))

def dcl.u.got(+h: DclH, o: File, d: File, kept: Set(), +pf: List<&2, U32>, +pk: String, +pi: Nat, st: List<&2, Cl.Stat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(DclSt):
  (r, m) = x
  dcl.u.id(h, r, o, d, kept, pf, pk, pi, st, m)

def dcl.u.step(+h: DclH, s: DclSt) -> IO(DclSt):
  match s:
    case DclSt{r, o, d, kept, pf, pk, pi, st, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, DclSt, S.Rd.next(r), dcl.u.got(h, o, d, kept, pf, pk, pi, st))

def dcl.u.go(fuel: Nat, +h: DclH, s: DclSt) -> IO(DclSt):
  match fuel s:
    case 1n+f DclSt{r, o, d, kept, pf, pk, pi, st, True{}}:
      IO.bind(DclSt, DclSt, dcl.u.step(h, DclSt{r, o, d, kept, pf, pk, pi, st, True{}}), dcl.u.go(f, h))
    case _ DclSt{r, o, d, kept, pf, pk, pi, st, g}:
      IO.pure(DclSt, DclSt{r, o, d, kept, pf, pk, pi, st, g})

def dcl.u.fin.all(+out: String, s: DclSt) -> IO(List<&2, Cl.Stat>):
  match s:
    case DclSt{r, o, d, kept, pf, pk, pi, +st, g}:
      do IO<List<&2, Cl.Stat>>:
        S.Rd.close(r)
        File.close(o)
        File.close(d)
        S.write(out ++ ".stats", S.b(Cl.stat.show(st)))
        S.mv(out ++ ".tmp", out)
        return st

# the whole tool: the sets, the capped files' counts, then the pass (its stats answered)
def dcl.run(+units: String, +out: String, held: List<String>, seen: List<String>, +caps: List<&2, DclCap>, +v2: String) -> IO(List<&2, Cl.Stat>):
  do IO<List<&2, Cl.Stat>>:
    e : L.Excl <- L.v2.ex.load(v2)
    ha : DclAdd <- dcl.loads(True{}, held, dcl.add0())
    sa : DclAdd <- dcl.loads(False{}, seen, dcl.add0())
    cn : Map<&2, Nat> <- dcl.count(units, caps)
    +h : DclH = dcl.h.of(e, ha, sa, caps, cn)
    r : S.Rd <- S.Rd.open(units)
    o : File <- IO.try(File, File.open(out ++ ".tmp", "w"))
    d : File <- IO.try(File, File.open(out ++ ".dropped", "w"))
    s : DclSt <- dcl.u.go(dcl.big(), h, DclSt{r, o, d, Set.new(), [0], "", 0n, dcl.st0(), True{}})
    dcl.u.fin.all(out, s)

# The command ----------------------------------------------------------------------

type DclArgs is Data:
  DclArgs{held: List<&2, String>, seen: List<&2, String>, caps: List<&2, DclCap>, bad: List<&2, String>}

def dcl.cap.mk(has: Bool, +pre: List<&2, U32>, m: Maybe<&2, Nat>) -> Maybe<&2, DclCap>:
  match has m:
    case True{} Some{n}:
      Some{DclCap{pre, n}}
    case _ _:
      None{}

# PREFIX:N (N after the last `:`, so a PREFIX may hold `:`, as `repo:` does)
def dcl.cap.word(+x: List<&2, U32>) -> Maybe<&2, DclCap>:
  +num = List.reverse(&2, U32, L.v2.before(List.reverse(&2, U32, x), 58))
  dcl.cap.mk(L.v2.has(x, 58), L.v2.parent(x, 58), Nat.read(S.str(num)))

def dcl.args.cap(m: Maybe<&2, DclCap>, +w: String, h: List<&2, String>, s: List<&2, String>, c: List<&2, DclCap>, b: List<&2, String>) -> DclArgs:
  match m:
    case Some{x}:
      DclArgs{h, s, x <> c, b}
    case None{}:
      DclArgs{h, s, c, w <> b}

def dcl.args.one(+w: String, a: DclArgs) -> DclArgs:
  match a:
    case DclArgs{+h, +s, +c, +b}:
      +x = S.b(w)
      Bool.pick(DclArgs, S.prefix(x, S.b("held=")), DclArgs{S.str(List.drop(&2, U32, x, 5n)) <> h, s, c, b},
        Bool.pick(DclArgs, S.prefix(x, S.b("seen=")), DclArgs{h, S.str(List.drop(&2, U32, x, 5n)) <> s, c, b},
          Bool.pick(DclArgs, S.prefix(x, S.b("cap=")), dcl.args.cap(dcl.cap.word(List.drop(&2, U32, x, 4n)), w, h, s, c, b), DclArgs{h, s, c, w <> b})))

# the held=, seen= and cap= words, each list in the order given
def dcl.args(ws: List<String>) -> DclArgs:
  match ws:
    case Nil{}:
      DclArgs{Nil{}, Nil{}, Nil{}, Nil{}}
    case +w <> more:
      dcl.args.one(w, dcl.args(more))

def dcl.strs(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> dcl.strs(more)

def dcl.any.jsonl(xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +x <> more:
      Bool.or(dcl.is.jsonl(x), dcl.any.jsonl(more))

def dcl.caps.show(cs: List<&2, DclCap>) -> String:
  match cs:
    case Nil{}:
      ""
    case DclCap{p, n} <> more:
      " " ++ S.str(p) ++ "*:" ++ Nat.show(n) ++ dcl.caps.show(more)

def dcl.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 decl-new UNITS OUT [held=FILE]... [seen=FILE]... [cap=PREFIX:N]...   (env: V2_HOLDOUT, default run/v2/holdout)")

def dcl.go(+units: String, +out: String, a: DclArgs) -> IO(Unit):
  match a:
    case DclArgs{+h, +s, +c, b}:
      do IO<Unit>:
        Bool.pick(IO(Unit), Nat.is_eq(List.length(&2, String, b), 0n), IO.pure(Unit, Unit{}), dcl.usage())
        Bool.pick(IO(Unit), dcl.any.jsonl(s), K.kor.die("decl-new", "a seen file is units (.nul): source files hold no declarations"), IO.pure(Unit, Unit{}))
        +v2 : String <- S.env("V2_HOLDOUT", "run/v2/holdout")
        dcl.log(units ++ " to " ++ out ++ ": " ++ Nat.show(List.length(&2, String, h)) ++ " held, " ++ Nat.show(List.length(&2, String, s)) ++ " seen, " ++ v2 ++ "'s holdout, caps:" ++ dcl.caps.show(c))
        st : List<&2, Cl.Stat> <- dcl.run(units, out, dcl.strs(h), dcl.strs(s), c, v2)
        IO.print(S.str(S.chomp(S.b(Cl.stat.show(st)))))
        dcl.log("done: " ++ out ++ " (" ++ out ++ ".stats, " ++ out ++ ".dropped)")

def dcl.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +u <> +o <> more:
      dcl.go(u, o, dcl.args(more))
    case _:
      dcl.usage()
