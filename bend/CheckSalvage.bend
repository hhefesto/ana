import Base
import ./Sys.bend as S

# check-salvage OUT UNITS PART...: what a stopped `bend-check` with one worker
# per shard already decided, so a restart checks only the rest. PART is each
# shard's part.0 from its work directory, in shard order (SHARD of as many
# SHARDS as there are parts); its fields are (position, id, record), in position
# order. Writes:
#
#   OUT.nul   the kept results as RESULTS pairs, shard order: results.prev.nul
#   OUT.ids   the ids at or before each shard's last kept unit, for DONE
#
# The units a shard dropped after its last kept one are checked again; nothing
# is lost. (The stopped shards' stats died with them.)

# bend-check's shard of a unit (Check.bend's kh.go, shard.mine)
def cs.hash(s: String, +h: U32) -> U32:
  match s:
    case SNil{}:
      h
    case SCon{Chr{c}, t}:
      cs.hash(t, U32.mod(U32.add(U32.mul(h, 31), c), 1000003))

def cs.upto.go(xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> cs.upto.go(t, S.head.is(t, 35))
    case _ _:
      Nil{}

def cs.file(+id: List<&2, U32>) -> List<&2, U32>:
  cs.upto.go(id, S.head.is(id, 35))

def cs.shard(+id: List<&2, U32>, +n: Nat) -> Nat:
  U32.to_nat(U32.mod(cs.hash(S.str(cs.file(id)), 7), U32.from_nat(n)))

def cs.nat(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      cs.nat(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))))

def cs.big() -> Nat:
  U32.to_nat(4294967295)

# One part: its pairs out, and one past the last kept position (0: none kept)
type Pt is Type:
  Pt{rd: S.Rd, f: File, last: Nat, n: Nat, go: Bool}

def pt.rec(f: File, +last: Nat, +n: Nat, +i: List<&2, U32>, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pt):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(Pt, Pt{rd, f, last, n, False{}})
    case Some{+rec}:
      do IO<Pt>:
        g : File <- S.emit(f, S.append(id, 0 <> S.append(rec, [0])))
        return Pt{rd, g, 1n+cs.nat(i, 0n), 1n+n, True{}}

def pt.id(f: File, +last: Nat, +n: Nat, +i: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pt):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(Pt, Pt{rd, f, last, n, False{}})
    case Some{+id}:
      do IO<Pt>:
        r2 : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pt.rec(f, last, n, i, id, r2)

def pt.i(f: File, +last: Nat, +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Pt):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(Pt, Pt{rd, f, last, n, False{}})
    case Some{+i}:
      do IO<Pt>:
        r2 : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        pt.id(f, last, n, i, r2)

def pt.step(rd: S.Rd, f: File, +last: Nat, +n: Nat) -> IO(Pt):
  do IO<Pt>:
    r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
    pt.i(f, last, n, r)

def pt.go(fuel: Nat, p: Pt) -> IO(Pt):
  match fuel p:
    case 1n+q Pt{rd, f, +last, +n, True{}}:
      IO.bind(Pt, Pt, pt.step(rd, f, last, n), pt.go(q))
    case _ d:
      IO.pure(Pt, d)

# The parts in order: the file handed on, each part's Pt.last
type Ps is Type:
  Ps{f: File, lasts: List<&2, Nat>, kept: Nat}

def ps.got(p: Pt, +lasts: List<&2, Nat>, +kept: Nat) -> IO(Ps):
  match p:
    case Pt{rd, f, +last, +n, g}:
      do IO<Ps>:
        S.Rd.close(rd)
        IO.print(Nat.show(n) ++ " kept, up to position " ++ Nat.show(last))
        return Ps{f, List.append(&2, Nat, lasts, [last]), Nat.add(kept, n)}

def ps.part(+x: String, f: File, +lasts: List<&2, Nat>, +kept: Nat) -> IO(Ps):
  do IO<Ps>:
    rd : S.Rd <- S.Rd.open(x)
    p : Pt <- pt.go(cs.big(), Pt{rd, f, 0n, 0n, True{}})
    ps.got(p, lasts, kept)

def ps.go(xs: List<String>, p: Ps) -> IO(Ps):
  match xs p:
    case Nil{} d:
      IO.pure(Ps, d)
    case x <> more Ps{f, +lasts, +kept}:
      IO.bind(Ps, Ps, ps.part(x, f, lasts, kept), ps.go(more))

# The units: the ids their shard got past
type Un is Type:
  Un{rd: S.Rd, f: File, i: Nat, n: Nat, go: Bool}

def cs.at(xs: List<&2, Nat>, k: Nat) -> Nat:
  match xs k:
    case Nil{} _:
      0n
    case +x <> _ 0n:
      x
    case _ <> t 1n+j:
      cs.at(t, j)

def un.put(past: Bool, rd: S.Rd, f: File, +i: Nat, +n: Nat, +id: List<&2, U32>) -> IO(Un):
  match past:
    case True{}:
      do IO<Un>:
        g : File <- S.emit(f, S.append(id, [10]))
        return Un{rd, g, 1n+i, 1n+n, True{}}
    case False{}:
      IO.pure(Un, Un{rd, f, 1n+i, n, True{}})

def un.rec(+lasts: List<&2, Nat>, +sn: Nat, f: File, +i: Nat, +n: Nat, +id: List<&2, U32>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Un):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(Un, Un{rd, f, i, n, False{}})
    case Some{x}:
      un.put(Nat.is_lt(i, cs.at(lasts, cs.shard(id, sn))), rd, f, i, n, id)

def un.id(+lasts: List<&2, Nat>, +sn: Nat, f: File, +i: Nat, +n: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(Un):
  (rd, m) = r
  match m:
    case None{}:
      IO.pure(Un, Un{rd, f, i, n, False{}})
    case Some{+id}:
      do IO<Un>:
        r2 : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        un.rec(lasts, sn, f, i, n, id, r2)

def un.step(+lasts: List<&2, Nat>, +sn: Nat, rd: S.Rd, f: File, +i: Nat, +n: Nat) -> IO(Un):
  do IO<Un>:
    r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
    un.id(lasts, sn, f, i, n, r)

def un.go(fuel: Nat, +lasts: List<&2, Nat>, +sn: Nat, u: Un) -> IO(Un):
  match fuel u:
    case 1n+q Un{rd, f, +i, +n, True{}}:
      IO.bind(Un, Un, un.step(lasts, sn, rd, f, i, n), un.go(q, lasts, sn))
    case _ d:
      IO.pure(Un, d)

def cs.ids.fin(u: Un, +kept: Nat) -> IO(Unit):
  match u:
    case Un{rd, f, +i, +n, g}:
      do IO<Unit>:
        S.Rd.close(rd)
        File.close(f)
        IO.print(Nat.show(kept) ++ " kept; " ++ Nat.show(n) ++ " of " ++ Nat.show(i) ++ " units decided or passed")

def cs.ids(+out: String, +units: String, p: Ps) -> IO(Unit):
  match p:
    case Ps{f, +lasts, +kept}:
      do IO<Unit>:
        File.close(f)
        o : File <- IO.try(File, File.open(out ++ ".ids", "w"))
        rd : S.Rd <- S.Rd.open(units)
        u : Un <- un.go(cs.big(), lasts, List.length(&2, Nat, lasts), Un{rd, o, 0n, 0n, True{}})
        cs.ids.fin(u, kept)

def cs.run(+out: String, +units: String, parts: List<String>) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(out ++ ".nul", "w"))
    p : Ps <- ps.go(parts, Ps{f, Nil{}, 0n})
    cs.ids(out, units, p)

def cs.args(xs: List<String>) -> IO(Unit):
  match xs:
    case +o <> +u <> ps:
      cs.run(o, u, ps)
    case _:
      IO.die(Unit, 2, "usage: check-salvage OUT UNITS PART...")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    cs.args(List.tail(&1, String, argv))
