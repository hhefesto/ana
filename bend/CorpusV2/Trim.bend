import Base
import ../Sys.bend as S
import ../Cksum.bend as Ck
import ../Check/Lib.bend as Cl
import ./Pool.bend as P

# trim-mutants: at most K of each unit's mutants, before the check (2026-11-03,
# run 8's second half).  run/v5/clean/trim-mutants.py in Bend (the user,
# 2026-10-14: all logic in Bend), at the user's cap of 4 repairs a unit
# (10-29, 10-30): the repair mix keeps at most 4 a unit, so a unit's other
# mutants would be checked only to be dropped, and a check is most of the
# work.
#
#   bend-corpus-v2 trim-mutants UNITS OUT [K]          (K: 4)
#
# UNITS is bend-units' NUL pairs: an id, then a record whose fields are
# joined by 0x1E, fields 11.. the mutants (Check/Lib.bend).  A unit with K
# mutants or fewer goes to OUT byte for byte.  Otherwise its first 11
# fields, then K mutants in a row from the start its id picks, wrapping:
# the start every checker already takes for a unit's first mutant, the POSIX
# cksum of the id and a newline, mod the unit's mutant count
# (Check/Haskell.bend's mut.start), so the operators stay mixed.  The
# Python picked its start from sha256 instead; the counts are the same.
# OUT.stats: units, units-trimmed, mutants-in, mutants-out.

def trm.k0() -> Nat:
  4n

def trm.big() -> Nat:
  U32.to_nat(4294967295)

def trm.log(+msg: String) -> IO(Unit):
  IO.print("trim-mutants: " ++ msg)

# fields joined by 0x1E (the inverse of Cl.fields.exact)
def trm.join.rest(fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      Nil{}
    case x <> more:
      30 <> S.append(x, trm.join.rest(more))

def trm.join(fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match fs:
    case Nil{}:
      Nil{}
    case x <> more:
      S.append(x, trm.join.rest(more))

# the start the id picks among n mutants
def trm.start(+id: List<&2, U32>, +n: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(n, 0n), 0n, Nat.mod(U32.to_nat(Ck.cksum(S.append(id, [10]))), n))

# K mutants from the start, wrapping
def trm.pick(+ms: List<&2, List<&2, U32>>, +s: Nat, +k: Nat) -> List<&2, List<&2, U32>>:
  List.take(&2, List<&2, U32>, List.append(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, ms, s), List.take(&2, List<&2, U32>, ms, s)), k)

# the record kept: the whole record, or its first 11 fields and K mutants
def trm.rec(+k: Nat, +id: List<&2, U32>, +rec: List<&2, U32>) -> List<&2, U32>:
  +fs = Cl.fields.exact(rec)
  +ms = List.drop(&2, List<&2, U32>, fs, 11n)
  +n = List.length(&2, List<&2, U32>, ms)
  Bool.pick(List<&2, U32>, Nat.is_lt(k, n),
    trm.join(List.append(&2, List<&2, U32>, List.take(&2, List<&2, U32>, fs, 11n), trm.pick(ms, trm.start(id, n), k))),
    rec)

def trm.stat(+k: Nat, +rec: List<&2, U32>, st: List<&2, Cl.Stat>) -> List<&2, Cl.Stat>:
  +n = List.length(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, Cl.fields.exact(rec), 11n))
  +cut = Nat.is_lt(k, n)
  Cl.stat.bump("mutants-out", Bool.pick(Nat, cut, k, n), Cl.stat.bump("mutants-in", n,
    Cl.stat.bump("units-trimmed", Bool.pick(Nat, cut, 1n, 0n), Cl.stat.bump("units", 1n, st))))

type TrmSt is Type:
  TrmSt{r: S.Rd, o: File, st: List<&2, Cl.Stat>, more: Bool}

def trm.text(+k: Nat, o: File, st: List<&2, Cl.Stat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(TrmSt):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(TrmSt, TrmSt{r, o, st, False{}})
    case Some{+rec}:
      do IO<TrmSt>:
        o2 : File <- P.po.emit3(o, S.append(id, [0]), trm.rec(k, id, rec))
        return TrmSt{r, o2, trm.stat(k, rec, st), True{}}

def trm.id(+k: Nat, r: S.Rd, o: File, st: List<&2, Cl.Stat>, m: Maybe<&2, List<&2, U32>>) -> IO(TrmSt):
  match m:
    case None{}:
      IO.pure(TrmSt, TrmSt{r, o, st, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, TrmSt, S.Rd.next(r), trm.text(k, o, st, id))

def trm.got(+k: Nat, o: File, st: List<&2, Cl.Stat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(TrmSt):
  (r, m) = x
  trm.id(k, r, o, st, m)

def trm.step(+k: Nat, s: TrmSt) -> IO(TrmSt):
  match s:
    case TrmSt{r, o, st, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, TrmSt, S.Rd.next(r), trm.got(k, o, st))

def trm.go(fuel: Nat, +k: Nat, s: TrmSt) -> IO(TrmSt):
  match fuel s:
    case 1n+f TrmSt{r, o, st, True{}}:
      IO.bind(TrmSt, TrmSt, trm.step(k, TrmSt{r, o, st, True{}}), trm.go(f, k))
    case _ TrmSt{r, o, st, g}:
      IO.pure(TrmSt, TrmSt{r, o, st, g})

def trm.fin(+out: String, s: TrmSt) -> IO(List<&2, Cl.Stat>):
  match s:
    case TrmSt{r, o, +st, g}:
      do IO<List<&2, Cl.Stat>>:
        S.Rd.close(r)
        File.close(o)
        S.write(out ++ ".stats", S.b(Cl.stat.show(st)))
        S.mv(out ++ ".tmp", out)
        return st

def trm.run(+units: String, +out: String, +k: Nat) -> IO(Unit):
  do IO<Unit>:
    trm.log(units ++ " to " ++ out ++ ", at most " ++ Nat.show(k) ++ " mutants a unit")
    r : S.Rd <- S.Rd.open(units)
    o : File <- IO.try(File, File.open(out ++ ".tmp", "w"))
    s : TrmSt <- trm.go(trm.big(), k, TrmSt{r, o, Nil{}, True{}})
    +st : List<&2, Cl.Stat> <- trm.fin(out, s)
    IO.print(S.str(S.chomp(S.b(Cl.stat.show(st)))))

def trm.usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-corpus-v2 trim-mutants UNITS OUT [K]   (K: 4)")

def trm.k.got(+units: String, +out: String, m: Maybe<&2, Nat>) -> IO(Unit):
  match m:
    case Some{+k}:
      trm.run(units, out, k)
    case None{}:
      trm.usage()

def trm.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +u <> +o <> Nil{}:
      trm.run(u, o, trm.k0())
    case +u <> +o <> +k <> Nil{}:
      trm.k.got(u, o, Nat.read(k))
    case _:
      trm.usage()
