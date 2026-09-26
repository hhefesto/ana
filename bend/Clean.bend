import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./Clock.bend as Ck
import ./Num.bend as N
import ./Check/Lib.bend as L

# bend-clean: the checked units of one language cleaned before rendering,
# then split into train and holdout.
#
#   bend-clean RESULTS.nul TRAIN.nul HOLDOUT.nul EVAL.jsonl
#
# RESULTS.nul is what bend-check wrote (Check/Lib.bend has the record);
# TRAIN.nul and HOLDOUT.nul are the same records, a subset, in the same
# order.  A unit is dropped, the first rule that applies counted:
#
#   exact_dup     its signature and body (fields 4 and 7) are an earlier
#                 unit's, byte for byte (a 64-bit hash of them)
#   contaminated  one of its body's 10-grams (whitespace words) is a 10-gram
#                 of a text in EVAL.jsonl (the whole-project code holdout)
#   near_dup      MinHash over the body's 5-word shingles (128 hashes, 32
#                 bands of 4) finds an earlier unit, and the two signatures
#                 agree in at least 90 of 128 places (Jaccard about 0.7)
#
# The rest go to HOLDOUT.nul when a hash of the unit's id is below
# HOLDOUT_PCT (2) mod 100, else to TRAIN.nul, so the holdout never holds a
# near copy of a train unit.  TRAIN.nul.stats counts every rule (keys in
# byte order).  The matching runs through files and external sort and join
# (LC_ALL=C) in a work directory (KEEP_WORK set: kept and named), so memory
# stays small whatever the corpus.  The eval texts' 10-grams are cached as
# EVAL.10grams (sorted, unique), reused while it is newer than EVAL.

# Hashes ---------------------------------------------------------------------

# the murmur3 finalizer: every input bit moves every output bit
def fmix(+h: U32) -> U32:
  +a = U32.mul(U32.xor(h, U32.shrn(h, 16n)), 2246822507)
  +c = U32.mul(U32.xor(a, U32.shrn(a, 13n)), 3266489909)
  U32.xor(c, U32.shrn(c, 16n))

# FNV-1a over a list of words (bytes, or word hashes), from a basis
def fnv.go(xs: List<&2, U32>, +h: U32) -> U32:
  match xs:
    case Nil{}:
      h
    case +x <> t:
      fnv.go(t, U32.mul(U32.xor(h, x), 16777619))

def fnv(+xs: List<&2, U32>) -> U32:
  fmix(fnv.go(xs, 2166136261))

# two independent lanes, sixteen hex digits
def h64(+xs: List<&2, U32>) -> String:
  N.U32.hex(fmix(fnv.go(xs, 2166136261))) ++ N.U32.hex(fmix(fnv.go(xs, 3735928559)))

# the whitespace words of a text, each hashed
def word.hashes(ws: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> more:
      fnv(w) <> word.hashes(more)

def toks(+xs: List<&2, U32>) -> List<&2, U32>:
  word.hashes(L.words(xs))

# every run of n consecutive words
def grams(ts: List<&2, U32>, +n: Nat) -> List<&2, List<&2, U32>>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> +more:
      +w = List.take(&2, U32, t <> more, n)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(List.length(&2, U32, w), n), w <> grams(more, n), Nil{})

# MinHash ----------------------------------------------------------------------

def salts.go(n: Nat, +k: U32) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      fmix(U32.add(U32.mul(k, 2654435769), 1013904223)) <> salts.go(p, U32.add(k, 1))

def salts() -> List<&2, U32>:
  salts.go(128n, 0)

def min(+a: U32, +b: U32) -> U32:
  Bool.pick(U32, U32.is_lt(a, b), a, b)

def mins.put(ss: List<&2, U32>, ms: List<&2, U32>, +h: U32) -> List<&2, U32>:
  match ss ms:
    case +s <> st m <> mt:
      min(m, fmix(U32.xor(h, s))) <> mins.put(st, mt, h)
    case _ _:
      Nil{}

def mins(+ss: List<&2, U32>, shs: List<&2, U32>, ms: List<&2, U32>) -> List<&2, U32>:
  match shs:
    case Nil{}:
      ms
    case +h <> more:
      mins(ss, more, mins.put(ss, ms, h))

# the shingles: the 5-word runs, or the whole body when it is shorter
def shingles.of(gs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match gs:
    case Nil{}:
      Nil{}
    case +g <> more:
      fmix(fnv.go(g, 2166136261)) <> shingles.of(more)

def shingles(+ts: List<&2, U32>) -> List<&2, U32>:
  +gs = grams(ts, 5n)
  Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, List<&2, U32>, gs), 0n),
    Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, U32, ts), 0n), Nil{}, [fmix(fnv.go(ts, 2166136261))]),
    shingles.of(gs))

def signature(+ts: List<&2, U32>) -> List<&2, U32>:
  mins(salts(), shingles(ts), List.replicate(U32, 128n, 4294967295))

# Lines ----------------------------------------------------------------------

def pad9(+i: Nat) -> String:
  +s = Nat.show(i)
  String.concat(List.replicate(String, Nat.sub(9n, String.length(s)), "0")) ++ s

def pad2(+i: Nat) -> String:
  Bool.pick(String, Nat.is_lt(i, 10n), "0" ++ Nat.show(i), Nat.show(i))

def hexes(ms: List<&2, U32>) -> String:
  match ms:
    case Nil{}:
      ""
    case +m <> more:
      N.U32.hex(m) ++ hexes(more)

# `HASH INDEX` for every 10-gram
def gram.lines(gs: List<&2, List<&2, U32>>, +ix: String) -> List<&2, U32>:
  match gs:
    case Nil{}:
      Nil{}
    case +g <> more:
      S.append(S.b(h64(g) ++ " " ++ ix ++ "\n"), gram.lines(more, ix))

# `BB-HASH INDEX` for every band of four hashes
def band.lines(fuel: Nat, ms: List<&2, U32>, +b: Nat, +ix: String) -> List<&2, U32>:
  match fuel ms:
    case 1n+f +m <> +more:
      +row = List.take(&2, U32, m <> more, 4n)
      S.append(S.b(pad2(b) ++ "-" ++ h64(row) ++ " " ++ ix ++ "\n"), band.lines(f, List.drop(&2, U32, m <> more, 4n), 1n+b, ix))
    case _ _:
      Nil{}

# `HASH` for every 10-gram of a text
def eval.lines(gs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match gs:
    case Nil{}:
      Nil{}
    case +g <> more:
      S.append(S.b(h64(g) ++ "\n"), eval.lines(more))

# Pass A: exact duplicates dropped, the rest hashed into the work files -------

type Pa is Type:
  Pa{rd: S.Rd, grams: File, sigs: File, bands: File, keys: Set(), dups: Set(), i: Nat, n: Nat, go: Bool}

type Ra is Data:
  Ra{dups: Set(), units: Nat, dup: Nat}

def pa.fresh(rd: S.Rd, g: File, sg: File, bd: File, keys: Set(), dups: Set(), +i: Nat, +n: Nat, +rec: List<&2, U32>) -> IO(Pa):
  +fs = L.fields(rec)
  +ts = toks(L.nth(fs, 7n))
  +ix = pad9(i)
  +sig = signature(ts)
  do IO<Pa>:
    g2 : File <- S.emit(g, gram.lines(grams(ts, 10n), ix))
    s2 : File <- S.emit(sg, S.b(ix ++ " " ++ hexes(sig) ++ "\n"))
    b2 : File <- S.emit(bd, band.lines(33n, sig, 0n, ix))
    return Pa{rd, g2, s2, b2, keys, dups, 1n+i, n, True{}}

def pa.key(seen: Bool, rd: S.Rd, g: File, sg: File, bd: File, keys: Set(), dups: Set(), +i: Nat, +n: Nat, +key: String, +rec: List<&2, U32>) -> IO(Pa):
  match seen:
    case True{}:
      IO.pure(Pa, Pa{rd, g, sg, bd, keys, Set.add(dups, pad9(i)), 1n+i, 1n+n, True{}})
    case False{}:
      pa.fresh(rd, g, sg, bd, Set.add(keys, key), dups, i, n, rec)

def pa.seen(r: Set() & Bool, rd: S.Rd, g: File, sg: File, bd: File, dups: Set(), +i: Nat, +n: Nat, +key: String, +rec: List<&2, U32>) -> IO(Pa):
  (keys, seen) = r
  pa.key(seen, rd, g, sg, bd, keys, dups, i, n, key, rec)

def pa.rec(rd: S.Rd, g: File, sg: File, bd: File, keys: Set(), dups: Set(), +i: Nat, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Pa):
  match m:
    case None{}:
      do IO<Pa>:
        S.Rd.close(rd)
        File.close(g)
        File.close(sg)
        File.close(bd)
        IO.die(Pa, 1, "clean: RESULTS ends after an id (no record)")
    case Some{+rec}:
      +fs = L.fields(rec)
      +key = h64(S.append(L.nth(fs, 4n), 10 <> L.nth(fs, 7n)))
      pa.seen(Set.has(keys, key), rd, g, sg, bd, dups, i, n, key, rec)

def pa.rec.pair(g: File, sg: File, bd: File, keys: Set(), dups: Set(), +i: Nat, +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pa):
  (rd, m) = r
  pa.rec(rd, g, sg, bd, keys, dups, i, n, m)

def pa.id(rd: S.Rd, g: File, sg: File, bd: File, keys: Set(), dups: Set(), +i: Nat, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Pa):
  match m:
    case None{}:
      IO.pure(Pa, Pa{rd, g, sg, bd, keys, dups, i, n, False{}})
    case Some{id}:
      do IO<Pa>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pa.rec.pair(g, sg, bd, keys, dups, i, n, r)

def pa.id.pair(g: File, sg: File, bd: File, keys: Set(), dups: Set(), +i: Nat, +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pa):
  (rd, m) = r
  pa.id(rd, g, sg, bd, keys, dups, i, n, m)

def pa.step(p: Pa) -> IO(Pa):
  match p:
    case Pa{rd, g, sg, bd, keys, dups, +i, +n, go}:
      do IO<Pa>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pa.id.pair(g, sg, bd, keys, dups, i, n, r)

def pa.go(fuel: Nat, p: Pa) -> IO(Ra):
  match fuel p:
    case 1n+f Pa{rd, g, sg, bd, keys, dups, i, n, True{}}:
      IO.bind(Pa, Ra, pa.step(Pa{rd, g, sg, bd, keys, dups, i, n, True{}}), pa.go(f))
    case _ Pa{rd, g, sg, bd, keys, dups, i, n, go}:
      do IO<Ra>:
        S.Rd.close(rd)
        File.close(g)
        File.close(sg)
        File.close(bd)
        return Ra{dups, i, n}

# Pass B: the eval texts' 10-grams -------------------------------------------

type Pb is Type:
  Pb{rd: S.Rd, out: File, docs: Nat, go: Bool}

def pb.doc(rd: S.Rd, o: File, +n: Nat, d: Maybe<&2, J.Doc>) -> IO(Pb):
  match d:
    case None{}:
      IO.pure(Pb, Pb{rd, o, n, True{}})
    case Some{J.Doc{id, +text}}:
      do IO<Pb>:
        o2 : File <- S.emit(o, eval.lines(grams(toks(text), 10n)))
        return Pb{rd, o2, 1n+n, True{}}

def pb.line(rd: S.Rd, o: File, +n: Nat, m: Maybe<&2, List<&2, U32>>) -> IO(Pb):
  match m:
    case None{}:
      IO.pure(Pb, Pb{rd, o, n, False{}})
    case Some{+l}:
      pb.doc(rd, o, n, J.doc(l))

def pb.pair(o: File, +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pb):
  (rd, m) = r
  pb.line(rd, o, n, m)

def pb.step(p: Pb) -> IO(Pb):
  match p:
    case Pb{rd, o, +n, g}:
      do IO<Pb>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pb.pair(o, n, r)

def pb.go(fuel: Nat, p: Pb) -> IO(Nat):
  match fuel p:
    case 1n+f Pb{rd, o, n, True{}}:
      IO.bind(Pb, Nat, pb.step(Pb{rd, o, n, True{}}), pb.go(f))
    case _ Pb{rd, o, n, g}:
      do IO<Nat>:
        S.Rd.close(rd)
        File.close(o)
        return n

# Candidates: consecutive equal band keys in the sorted band file ------------

# the first word of a line, and the rest after its space
def word.first(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 32), Nil{}, h <> word.first(t))

def word.rest(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> +t:
      Bool.pick(List<&2, U32>, U32.is_eq(h, 32), t, word.rest(t))

# the pairs of a group of indices (ascending, from the sort): every pair in
# a group of at most 32, else the first against each other one
def pairs.with(+a: List<&2, U32>, bs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> more:
      S.append(S.append(a, 32 <> S.append(b, [10])), pairs.with(a, more))

def pairs.all(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +a <> +more:
      S.append(pairs.with(a, more), pairs.all(more))

def pairs.star(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +a <> more:
      pairs.with(a, more)

def pairs.of(+xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_le(List.length(&2, List<&2, U32>, xs), 32n), pairs.all(xs), pairs.star(xs))

type Pc is Type:
  Pc{rd: S.Rd, out: File, key: List<&2, U32>, grp: List<&2, List<&2, U32>>, go: Bool}

def pc.flush(o: File, grp: List<&2, List<&2, U32>>) -> IO(File):
  S.emit(o, pairs.of(List.reverse(&2, List<&2, U32>, grp)))

def pc.put(same: Bool, rd: S.Rd, o: File, +key: List<&2, U32>, grp: List<&2, List<&2, U32>>, +k: List<&2, U32>, +ix: List<&2, U32>) -> IO(Pc):
  match same:
    case True{}:
      IO.pure(Pc, Pc{rd, o, key, ix <> grp, True{}})
    case False{}:
      do IO<Pc>:
        o2 : File <- pc.flush(o, grp)
        return Pc{rd, o2, k, [ix], True{}}

def pc.line(rd: S.Rd, o: File, +key: List<&2, U32>, grp: List<&2, List<&2, U32>>, m: Maybe<&2, List<&2, U32>>) -> IO(Pc):
  match m:
    case None{}:
      do IO<Pc>:
        o2 : File <- pc.flush(o, grp)
        return Pc{rd, o2, key, Nil{}, False{}}
    case Some{+l}:
      +k = word.first(l)
      pc.put(S.eq(k, key), rd, o, key, grp, k, word.rest(l))

def pc.pair(o: File, +key: List<&2, U32>, grp: List<&2, List<&2, U32>>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pc):
  (rd, m) = r
  pc.line(rd, o, key, grp, m)

def pc.step(p: Pc) -> IO(Pc):
  match p:
    case Pc{rd, o, +key, grp, g}:
      do IO<Pc>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pc.pair(o, key, grp, r)

def pc.go(fuel: Nat, p: Pc) -> IO(Unit):
  match fuel p:
    case 1n+f Pc{rd, o, k, grp, True{}}:
      IO.bind(Pc, Unit, pc.step(Pc{rd, o, k, grp, True{}}), pc.go(f))
    case _ Pc{rd, o, k, grp, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(o)

# Verification: `I J SIG_I SIG_J` lines, the later unit dropped when the two
# signatures agree in at least 90 of their 128 hashes -------------------------

def agree(fuel: Nat, xs: List<&2, U32>, ys: List<&2, U32>, +n: Nat) -> Nat:
  match fuel xs ys:
    case 1n+f +x <> +xt +y <> +yt:
      +a = {x <> xt : List<&2, U32>}
      +b = {y <> yt : List<&2, U32>}
      agree(f, List.drop(&2, U32, a, 8n), List.drop(&2, U32, b, 8n),
        Bool.pick(Nat, S.eq(List.take(&2, U32, a, 8n), List.take(&2, U32, b, 8n)), 1n+n, n))
    case _ _ _:
      n

type Pv is Type:
  Pv{rd: S.Rd, near: Set(), go: Bool}

def pv.line(rd: S.Rd, +near: Set(), m: Maybe<&2, List<&2, U32>>) -> Pv:
  match m:
    case None{}:
      Pv{rd, near, False{}}
    case Some{+l}:
      +ws = S.split(l, 32)
      +j = S.str(L.nth(ws, 1n))
      Pv{rd, Bool.pick(Set(), Nat.is_le(90n, agree(129n, L.nth(ws, 2n), L.nth(ws, 3n), 0n)), Set.add(near, j), near), True{}}

def pv.pair(near: Set(), r: S.Rd & Maybe<&2, List<&2, U32>>) -> Pv:
  (rd, m) = r
  pv.line(rd, near, m)

def pv.step(p: Pv) -> IO(Pv):
  match p:
    case Pv{rd, near, g}:
      do IO<Pv>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return pv.pair(near, r)

def pv.go(fuel: Nat, p: Pv) -> IO(Set()):
  match fuel p:
    case 1n+f Pv{rd, near, True{}}:
      IO.bind(Pv, Set(), pv.step(Pv{rd, near, True{}}), pv.go(f))
    case _ Pv{rd, near, g}:
      do IO<Set()>:
        S.Rd.close(rd)
        return near

# a file of index lines as a set
type Ps is Type:
  Ps{rd: S.Rd, s: Set(), go: Bool}

def ps.line(rd: S.Rd, s: Set(), m: Maybe<&2, List<&2, U32>>) -> Ps:
  match m:
    case None{}:
      Ps{rd, s, False{}}
    case Some{l}:
      Ps{rd, Set.add(s, S.str(l)), True{}}

def ps.pair(s: Set(), r: S.Rd & Maybe<&2, List<&2, U32>>) -> Ps:
  (rd, m) = r
  ps.line(rd, s, m)

def ps.step(p: Ps) -> IO(Ps):
  match p:
    case Ps{rd, s, g}:
      do IO<Ps>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return ps.pair(s, r)

def ps.go(fuel: Nat, p: Ps) -> IO(Set()):
  match fuel p:
    case 1n+f Ps{rd, s, True{}}:
      IO.bind(Ps, Set(), ps.step(Ps{rd, s, True{}}), ps.go(f))
    case _ Ps{rd, s, g}:
      do IO<Set()>:
        S.Rd.close(rd)
        return s

def big() -> Nat:
  1000000000n

def set.of(+path: String) -> IO(Set()):
  do IO<Set()>:
    rd : S.Rd <- S.Rd.lines(path)
    ps.go(big(), Ps{rd, Set.new(), True{}})

# Pass C: the survivors, split -------------------------------------------------

type Cs is Data:
  Cs{dup: Nat, contam: Nat, near: Nat, train: Nat, hold: Nat}

type Pw is Type:
  Pw{rd: S.Rd, train: File, hold: File, dups: Set(), contam: Set(), near: Set(), i: Nat, c: Cs, go: Bool}

# 0 keep, 1 exact_dup, 2 contaminated, 3 near_dup
def rule(+d: Bool, +c: Bool, +n: Bool) -> Nat:
  Bool.pick(Nat, d, 1n, Bool.pick(Nat, c, 2n, Bool.pick(Nat, n, 3n, 0n)))

def cs.put(c: Cs, r: Nat, hold: Bool) -> Cs:
  match c r hold:
    case Cs{d, x, n, t, h} 0n True{}:
      Cs{d, x, n, t, 1n+h}
    case Cs{d, x, n, t, h} 0n False{}:
      Cs{d, x, n, 1n+t, h}
    case Cs{d, x, n, t, h} 1n _:
      Cs{1n+d, x, n, t, h}
    case Cs{d, x, n, t, h} 2n _:
      Cs{d, 1n+x, n, t, h}
    case Cs{d, x, n, t, h} _ _:
      Cs{d, x, 1n+n, t, h}

def pw.write(r: Nat, hold: Bool, tr: File, ho: File, +bytes: List<&2, U32>) -> IO(File & File):
  match r hold:
    case 0n True{}:
      do IO<File & File>:
        h2 : File <- S.emit(ho, bytes)
        return (tr, h2)
    case 0n False{}:
      do IO<File & File>:
        t2 : File <- S.emit(tr, bytes)
        return (t2, ho)
    case _ _:
      IO.pure(File & File, (tr, ho))

def pw.files(rd: S.Rd, dups: Set(), contam: Set(), near: Set(), +i: Nat, c: Cs, fs: File & File) -> Pw:
  (tr, ho) = fs
  Pw{rd, tr, ho, dups, contam, near, 1n+i, c, True{}}

def pw.out(+da: Bool, +db: Bool, +dd: Bool, rd: S.Rd, tr: File, ho: File, dups: Set(), contam: Set(), near: Set(), +i: Nat, c: Cs, +pct: U32, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(Pw):
  +r = rule(da, db, dd)
  +hold = U32.is_lt(U32.mod(fnv(id), 100), pct)
  do IO<Pw>:
    fs : File & File <- pw.write(r, hold, tr, ho, S.append(id, 0 <> S.append(rec, [0])))
    return pw.files(rd, dups, contam, near, i, cs.put(c, r, hold), fs)

def pw.d(x: Set() & Bool, +da: Bool, +db: Bool, rd: S.Rd, tr: File, ho: File, dups: Set(), contam: Set(), +i: Nat, c: Cs, +pct: U32, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(Pw):
  (near, dd) = x
  pw.out(da, db, dd, rd, tr, ho, dups, contam, near, i, c, pct, id, rec)

def pw.b(x: Set() & Bool, +da: Bool, rd: S.Rd, tr: File, ho: File, dups: Set(), near: Set(), +i: Nat, c: Cs, +pct: U32, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(Pw):
  (contam, db) = x
  pw.d(Set.has(near, pad9(i)), da, db, rd, tr, ho, dups, contam, i, c, pct, id, rec)

def pw.a(x: Set() & Bool, rd: S.Rd, tr: File, ho: File, contam: Set(), near: Set(), +i: Nat, c: Cs, +pct: U32, +id: List<&2, U32>, +rec: List<&2, U32>) -> IO(Pw):
  (dups, da) = x
  pw.b(Set.has(contam, pad9(i)), da, rd, tr, ho, dups, near, i, c, pct, id, rec)

def pw.rec(rd: S.Rd, tr: File, ho: File, dups: Set(), contam: Set(), near: Set(), +i: Nat, c: Cs, +pct: U32, +id: List<&2, U32>, m: Maybe<&2, List<&2, U32>>) -> IO(Pw):
  match m:
    case None{}:
      IO.pure(Pw, Pw{rd, tr, ho, dups, contam, near, i, c, False{}})
    case Some{+rec}:
      pw.a(Set.has(dups, pad9(i)), rd, tr, ho, contam, near, i, c, pct, id, rec)

def pw.rec.pair(tr: File, ho: File, dups: Set(), contam: Set(), near: Set(), +i: Nat, c: Cs, +pct: U32, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pw):
  (rd, m) = r
  pw.rec(rd, tr, ho, dups, contam, near, i, c, pct, id, m)

def pw.id(rd: S.Rd, tr: File, ho: File, dups: Set(), contam: Set(), near: Set(), +i: Nat, c: Cs, +pct: U32, m: Maybe<&2, List<&2, U32>>) -> IO(Pw):
  match m:
    case None{}:
      IO.pure(Pw, Pw{rd, tr, ho, dups, contam, near, i, c, False{}})
    case Some{+id}:
      do IO<Pw>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pw.rec.pair(tr, ho, dups, contam, near, i, c, pct, id, r)

def pw.id.pair(tr: File, ho: File, dups: Set(), contam: Set(), near: Set(), +i: Nat, c: Cs, +pct: U32, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pw):
  (rd, m) = r
  pw.id(rd, tr, ho, dups, contam, near, i, c, pct, m)

def pw.step(+pct: U32, p: Pw) -> IO(Pw):
  match p:
    case Pw{rd, tr, ho, dups, contam, near, +i, c, g}:
      do IO<Pw>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pw.id.pair(tr, ho, dups, contam, near, i, c, pct, r)

def pw.go(fuel: Nat, +pct: U32, p: Pw) -> IO(Cs):
  match fuel p:
    case 1n+f Pw{rd, tr, ho, dups, contam, near, i, c, True{}}:
      IO.bind(Pw, Cs, pw.step(pct, Pw{rd, tr, ho, dups, contam, near, i, c, True{}}), pw.go(f, pct))
    case _ Pw{rd, tr, ho, dups, contam, near, i, c, g}:
      do IO<Cs>:
        S.Rd.close(rd)
        File.close(tr)
        File.close(ho)
        return c

def sh.ok(ok: Bool, +what: String, +o: S.Out) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "clean: " ++ what ++ " failed: " ++ S.str(S.lines.take(S.Out.text(o), 20n)))

# The driver --------------------------------------------------------------------

def sh(+w: String, +what: String, +script: String, args: List<String>) -> IO(Unit):
  do IO<Unit>:
    +o : S.Out <- S.run(w, ["LC_ALL=C"], 2000000, "sh", List.append(&1, String, ["-c", script, "sh"], args), Nil{})
    sh.ok(U32.is_eq(S.Out.status(o), 0), what, o)

def nl.sp(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +h <> t:
      Bool.pick(U32, U32.is_eq(h, 10), 32, h) <> nl.sp(t)

def stats(+units: Nat, c: Cs) -> String:
  match c:
    case Cs{d, x, n, t, h}:
      "contaminated " ++ Nat.show(x) ++ "\nexact_dup " ++ Nat.show(d) ++ "\nholdout " ++ Nat.show(h)
        ++ "\nnear_dup " ++ Nat.show(n) ++ "\ntrain " ++ Nat.show(t) ++ "\nunits " ++ Nat.show(units) ++ "\n"

def finish.work(gone: Bool, +w: String) -> IO(Unit):
  match gone:
    case True{}:
      S.rm(w)
    case False{}:
      Ck.log("clean: work " ++ w)

def finish(+keep: String, +w: String, +train: String, +units: Nat, c: Cs) -> IO(Unit):
  +st = stats(units, c)
  do IO<Unit>:
    S.write(train ++ ".stats", S.b(st))
    Ck.log("clean: " ++ S.str(nl.sp(S.b(st))))
    finish.work(String.is_empty(keep), w)

def ra.dups(r: Ra) -> Set():
  match r:
    case Ra{d, u, n}:
      d

def ra.units(+r: Ra) -> Nat:
  match r:
    case Ra{d, u, n}:
      u

# The eval texts' 10-grams, sorted and unique, cached beside EVAL as
# EVAL.10grams while that is newer than EVAL (every language reads the same)
def evals(cached: Bool, +w: String, +e: String) -> IO(Unit):
  match cached:
    case True{}:
      do IO<Unit>:
        Ck.log("clean: the eval 10-grams from " ++ e ++ ".10grams")
        sh(w, "the cached eval 10-grams", "ln -s \"$1\" eval.s", [e ++ ".10grams"])
    case False{}:
      do IO<Unit>:
        er : S.Rd <- S.Rd.lines(e)
        eo : File <- IO.try(File, File.open(w ++ "/eval", "w"))
        +docs : Nat <- pb.go(big(), Pb{er, eo, 0n, True{}})
        Ck.log("clean: " ++ Nat.show(docs) ++ " eval texts hashed")
        sh(w, "the eval sort", "sort -u -S 1G -T . eval > eval.s && rm eval && cp eval.s \"$1.tmp\" && mv \"$1.tmp\" \"$1\"", [e ++ ".10grams"])

def clean(+results: String, +train: String, +hold: String, +eval: String) -> IO(Unit):
  do IO<Unit>:
    +w : String <- S.mktemp()
    +keep : String <- S.env("KEEP_WORK", "")
    +pct : Nat <- S.env.nat("HOLDOUT_PCT", 2n)
    Ck.log("clean: " ++ results ++ " against " ++ eval ++ " in " ++ w)
    rd : S.Rd <- S.Rd.open(results)
    g : File <- IO.try(File, File.open(w ++ "/grams", "w"))
    sg : File <- IO.try(File, File.open(w ++ "/sigs", "w"))
    bd : File <- IO.try(File, File.open(w ++ "/bands", "w"))
    +ra : Ra <- pa.go(big(), Pa{rd, g, sg, bd, Set.new(), Set.new(), 0n, 0n, True{}})
    Ck.log("clean: " ++ Nat.show(ra.units(ra)) ++ " units hashed")
    +e : String <- S.realpath(eval)
    +o : S.Out <- S.run(w, [], 60, "sh", ["-c", "[ -s \"$1\" ] && [ \"$1\" -nt \"$2\" ]", "sh", e ++ ".10grams", e], Nil{})
    evals(U32.is_eq(S.Out.status(o), 0), w, e)
    sh(w, "the 10-gram match", "sort -S 1G -T . grams > grams.s && join -o 2.2 eval.s grams.s | sort -u > contam", [])
    sh(w, "the band sort", "sort -S 1G -T . bands > bands.s", [])
    br : S.Rd <- S.Rd.lines(w ++ "/bands.s")
    po : File <- IO.try(File, File.open(w ++ "/pairs", "w"))
    pc.go(big(), Pc{br, po, Nil{}, Nil{}, True{}})
    sh(w, "the pair join", "sort -u -S 1G -T . pairs > pairs.s && join pairs.s sigs | sort -k2,2 -S 1G -T . > p1 && join -1 2 -2 1 -o 1.1,1.2,1.3,2.2 p1 sigs > p2", [])
    vr : S.Rd <- S.Rd.lines(w ++ "/p2")
    +near : Set() <- pv.go(big(), Pv{vr, Set.new(), True{}})
    +contam : Set() <- set.of(w ++ "/contam")
    rd2 : S.Rd <- S.Rd.open(results)
    tr : File <- IO.try(File, File.open(train ++ ".tmp", "w"))
    ho : File <- IO.try(File, File.open(hold ++ ".tmp", "w"))
    c : Cs <- pw.go(big(), U32.from_nat(pct), Pw{rd2, tr, ho, ra.dups(ra), contam, near, 0n, Cs{0n, 0n, 0n, 0n, 0n}, True{}})
    S.mv(train ++ ".tmp", train)
    S.mv(hold ++ ".tmp", hold)
    finish(keep, w, train, ra.units(ra), c)

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-clean RESULTS.nul TRAIN.nul HOLDOUT.nul EVAL.jsonl")

def args.go(xs: List<String>) -> IO(Unit):
  match xs:
    case +r <> +t <> +h <> +e <> Nil{}:
      clean(r, t, h, e)
    case _:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args.go(xs)
