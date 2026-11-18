import Base
import ./Sys.bend as S
import ./Check/Lib.bend as Cl
import ./CorpusV2/Lib.bend as L
import ./CorpusV2/Pool.bend as P

# bend-r8: R8's pass over a mixed transcript stream (2026-11-17, docs/r8/PLAN.md).  The user, 11-17: "Do
# start the rebuild with your recommendations" (mugen's, 11-16: cap the sessions a declaration gets at 2-3,
# preferring different kinds; drop the give-up endings).
#
#   bend-r8 IN.nul OUT.nul        env R8_CAP (3), R8_GIVEUP (drop | keep; drop), R8_REPAIR (no limit)
#
# R9's change, merged into R8 (2026-11-18, docs/r9/PLAN.md; the user, 11-17: "Fewer repair sessions per unit may
# help a little"; 11-18: "I want any benefit R9 would have brought to be merged into R8"): with R8_REPAIR=k, a
# repair-kind session (r8.repair) goes when its declaration has k of them out already: `drop-repair`.  Unset, no
# limit: R8's pass as it was, byte for byte.
#
# IN: NUL pairs (session id, text), a mix's output (repair-mix: in sha256(salt NUL id) order, so what comes
# first is as good as a draw).  A session's declaration (r8.key): its id less a leading `mut:`, up to its
# first `@` (`repo:FILE#DECL`); an id without `@` (a port's whole file) less its last `/` segment.  Its kind:
# repair-mix's tag (r8.tag: the last `/` segment less a trailing `-N`).  In order, a session goes when
#   - its kind holds `giveup` (mugen-fix-giveup: "I could not get X to pass in N tries ... I put the hole
#     back", trained at weight 1) and R8_GIVEUP is drop: `drop-giveup`;
#   - its declaration has R8_CAP sessions out already, or R8_CAP - 1 and one of its kind is among them (so a
#     declaration's last place goes to a kind it has not had yet): `drop-cap`;
# else it goes to OUT as read, byte for byte: `out`.  OUT.stats and stdout: the counts, `in` the sessions read.

# (repair-mix's id reading, CorpusV2/Ratio.bend's rto.seg, rto.stem, rto.unnum, rto.unmut, rto.tag, as they are
# there: Ratio.bend's IO would make this file's proofs lean on foreign code)
def r8.rev(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, xs)

def r8.seg(+id: List<&2, U32>) -> List<&2, U32>:
  r8.rev(L.v2.before(r8.rev(id), 47))

def r8.stem(+id: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, L.v2.has(id, 47), L.v2.parent(id, 47), id)

def r8.isd(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def r8.hd.isd(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      r8.isd(c)

def r8.undigit(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      r8.undigit(t, r8.hd.isd(t))
    case r _:
      r

def r8.unnum(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  +r = r8.rev(xs)
  +d = r8.undigit(r, r8.hd.isd(r))
  +num = Bool.not(Nat.is_eq(S.len(d), S.len(r)))
  Bool.pick(List<&2, U32>, Bool.and(num, L.v2.head.is(d, c)), r8.rev(List.drop(&2, U32, d, 1n)), xs)

def r8.unmut(+id: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.prefix(id, S.b("mut:")), List.drop(&2, U32, id, 4n), id)

def r8.tag(+id: List<&2, U32>) -> List<&2, U32>:
  r8.unnum(r8.seg(id), 45)

def r8.key(+id: List<&2, U32>) -> List<&2, U32>:
  +x = r8.unmut(id)
  Bool.pick(List<&2, U32>, L.v2.has(x, 64), L.v2.before(x, 64), r8.stem(x))

def r8.kindkey(+key: List<&2, U32>, +id: List<&2, U32>) -> List<&2, U32>:
  S.append(key, 1 <> r8.tag(id))

def r8.giveup(+id: List<&2, U32>) -> Bool:
  S.infix(r8.tag(id), S.b("giveup"))

# A repair-kind session: its kind holds a wrong program and its fix.  A tag ending in `repair` (mugen-repair,
# mugen-fix-miss-repair, mugen-fix-repeat-repair, mugen-chain-repair, repair), or a chain's or a repeat's
# (mugen-chain, mugen-chain-fill, mugen-fix-repeat, mugen-fix-repeat-fill).  A fix's miss (mugen-fix-miss-direct,
# -fill) is not: its one try is an edit mugen refused, and no wrong program is ever in the file (CorpusV2/Ratio.bend).
def r8.repair(+id: List<&2, U32>) -> Bool:
  +t = r8.tag(id)
  Bool.or(S.suffix(t, S.b("repair")), Bool.or(S.prefix(t, S.b("mugen-chain")), S.prefix(t, S.b("mugen-fix-repeat"))))

# a declaration's repair-kind count's key in the map (beside its key and its kinds' keys)
def r8.repkey(+key: List<&2, U32>) -> List<&2, U32>:
  S.append(key, [2])

# what happens to a session: 0 drop-giveup, 1 drop-cap, 2 out (n: its declaration's sessions out so far,
# s: those of its kind)
def r8.decide(+cap: Nat, +drop: Bool, +gu: Bool, +n: Nat, +s: Nat) -> Nat:
  Bool.pick(Nat, Bool.and(drop, gu), 0n,
  Bool.pick(Nat, Bool.and(Nat.is_lt(n, cap), Bool.or(Nat.is_eq(s, 0n), Nat.is_lt(1n+n, cap))), 2n, 1n))

# R9's: what r8.decide says, but 3 (drop-repair) for a repair-kind session (rep) that would go out when its
# declaration has rcap of them out already (nr)
def r8.decide9(+cap: Nat, +drop: Bool, +gu: Bool, +n: Nat, +s: Nat, +rcap: Nat, +rep: Bool, +nr: Nat) -> Nat:
  +d = r8.decide(cap, drop, gu, n, s)
  Bool.pick(Nat, Bool.and(Nat.is_eq(d, 2n), Bool.and(rep, Bool.not(Nat.is_lt(nr, rcap)))), 3n, d)

type R8St is Type:
  R8St{r: S.Rd, o: File, c: Map<&2, Nat>, st: List<&2, Cl.Stat>, more: Bool}

def r8.put(a: Nat, r: S.Rd, o: File, c: Map<&2, Nat>, st: List<&2, Cl.Stat>, +key: String, +kk: String, +rk: String, +n: Nat, +s: Nat, +nr: Nat, +rep: Bool, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(R8St):
  match a:
    case 0n:
      IO.pure(R8St, R8St{r, o, c, Cl.stat.bump("drop-giveup", 1n, st), True{}})
    case 1n:
      IO.pure(R8St, R8St{r, o, c, Cl.stat.bump("drop-cap", 1n, st), True{}})
    case 3n:
      IO.pure(R8St, R8St{r, o, c, Cl.stat.bump("drop-repair", 1n, st), True{}})
    case _:
      do IO<R8St>:
        o2 : File <- P.po.emit3(o, S.append(id, [0]), t)
        return R8St{r, o2, Map.set(&2, Nat, Map.set(&2, Nat, Map.set(&2, Nat, c, key, 1n+n), kk, 1n+s), rk, Bool.pick(Nat, rep, 1n+nr, nr)), Cl.stat.bump("out", 1n, st), True{}}

def r8.one.c(+cap: Nat, +drop: Bool, +rcap: Nat, r: S.Rd, o: File, st: List<&2, Cl.Stat>, +key: String, +kk: String, +rk: String, +n: Nat, +s: Nat, +id: List<&2, U32>, +t: List<&2, U32>, y: Map<&2, Nat> & Nat) -> IO(R8St):
  (c3, +nr) = y
  +rep = r8.repair(id)
  r8.put(r8.decide9(cap, drop, r8.giveup(id), n, s, rcap, rep, nr), r, o, c3, Cl.stat.bump("in", 1n, st), key, kk, rk, n, s, nr, rep, id, t)

def r8.one.b(+cap: Nat, +drop: Bool, +rcap: Nat, r: S.Rd, o: File, st: List<&2, Cl.Stat>, +key: String, +kk: String, +rk: String, +n: Nat, +id: List<&2, U32>, +t: List<&2, U32>, y: Map<&2, Nat> & Nat) -> IO(R8St):
  (c2, +s) = y
  r8.one.c(cap, drop, rcap, r, o, st, key, kk, rk, n, s, id, t, Map.get(Nat, 0n, c2, rk))

def r8.one.a(+cap: Nat, +drop: Bool, +rcap: Nat, r: S.Rd, o: File, st: List<&2, Cl.Stat>, +key: String, +kk: String, +rk: String, +id: List<&2, U32>, +t: List<&2, U32>, y: Map<&2, Nat> & Nat) -> IO(R8St):
  (c1, +n) = y
  r8.one.b(cap, drop, rcap, r, o, st, key, kk, rk, n, id, t, Map.get(Nat, 0n, c1, kk))

def r8.one(+cap: Nat, +drop: Bool, +rcap: Nat, r: S.Rd, o: File, c: Map<&2, Nat>, st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(R8St):
  +kb = r8.key(id)
  +key = S.str(kb)
  r8.one.a(cap, drop, rcap, r, o, st, key, S.str(r8.kindkey(kb, id)), S.str(r8.repkey(kb)), id, t, Map.get(Nat, 0n, c, key))

def r8.text(+cap: Nat, +drop: Bool, +rcap: Nat, o: File, c: Map<&2, Nat>, st: List<&2, Cl.Stat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(R8St):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(R8St, R8St{r, o, c, Cl.stat.bump("odd", 1n, st), False{}})
    case Some{+t}:
      r8.one(cap, drop, rcap, r, o, c, st, id, t)

def r8.id(+cap: Nat, +drop: Bool, +rcap: Nat, r: S.Rd, o: File, c: Map<&2, Nat>, st: List<&2, Cl.Stat>, m: Maybe<&2, List<&2, U32>>) -> IO(R8St):
  match m:
    case None{}:
      IO.pure(R8St, R8St{r, o, c, st, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, R8St, S.Rd.next(r), r8.text(cap, drop, rcap, o, c, st, id))

def r8.got(+cap: Nat, +drop: Bool, +rcap: Nat, o: File, c: Map<&2, Nat>, st: List<&2, Cl.Stat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(R8St):
  (r, m) = x
  r8.id(cap, drop, rcap, r, o, c, st, m)

def r8.step(+cap: Nat, +drop: Bool, +rcap: Nat, s: R8St) -> IO(R8St):
  match s:
    case R8St{r, o, c, st, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, R8St, S.Rd.next(r), r8.got(cap, drop, rcap, o, c, st))

def r8.go(fuel: Nat, +cap: Nat, +drop: Bool, +rcap: Nat, s: R8St) -> IO(R8St):
  match fuel s:
    case 1n+f R8St{r, o, c, st, True{}}:
      IO.bind(R8St, R8St, r8.step(cap, drop, rcap, R8St{r, o, c, st, True{}}), r8.go(f, cap, drop, rcap))
    case _ s2:
      IO.pure(R8St, s2)

def r8.fin(+out: String, s: R8St) -> IO(Unit):
  match s:
    case R8St{r, o, c, +st, g}:
      do IO<Unit>:
        S.Rd.close(r)
        File.close(o)
        S.write(out ++ ".stats", S.b(Cl.stat.show(st)))
        IO.print(S.str(S.chomp(S.b(Cl.stat.show(st)))))

def r8.run(+cap: Nat, +drop: Bool, +rcap: Nat, +inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    r : S.Rd <- S.Rd.open(inp)
    o : File <- IO.try(File, File.open(out, "w"))
    s : R8St <- r8.go(U32.to_nat(4294967295), cap, drop, rcap, R8St{r, o, Map.new(&2, Nat), Nil{}, True{}})
    r8.fin(out, s)

def r8.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +i <> +o <> Nil{}:
      do IO<Unit>:
        cap : Nat <- S.env.nat("R8_CAP", 3n)
        +g : String <- S.env("R8_GIVEUP", "drop")
        rcap : Nat <- S.env.nat("R8_REPAIR", U32.to_nat(4294967295))
        r8.run(cap, S.eq(S.b(g), S.b("drop")), rcap, i, o)
    case _:
      IO.die(Unit, 2, "usage: bend-r8 IN.nul OUT.nul   (env R8_CAP: a declaration's sessions, 3; R8_GIVEUP: drop | keep; R8_REPAIR: a declaration's repair-kind sessions, no limit)")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    r8.main(xs)
