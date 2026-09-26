import Base
import ../Sys.bend as S
import ./Lib.bend as L

# Lean checks Lean units.  MATHLIB is a mathlib4 checkout with its build
# cache (`lake exe cache get`); the Lean that runs is the toolchain it pins
# (lean-toolchain, from elan's ~/.elan/toolchains), and imports resolve
# through its LEAN_PATH, so a unit whose file imports anything outside
# mathlib and its dependencies fails its original check and is dropped.
#
# deploy/check/Harness.lean does the work: one Lean process per unit
# elaborates the file's head once and each variant from the state it left,
# printing the messages `lean` would print for head ++ variant (the tail is
# never needed: nothing above a declaration depends on what follows it).
#
#   check    the declaration with the variant for its body
#   hole     the body replaced by `_`: the error shows the goal and context
#   Context  `#check NAME` for each name the body uses, from the head's
#            state; a name Lean cannot resolve (a local) is left out
#   type     none (a tactic proof does not determine its statement)
#
# Status 2 means the head's imports failed; a hole is kept only when it
# fails (1), a mutant only when it fails (1).

type Cf is Data:
  Cf{env: List<&2, String>, harness: String, t: U32, cap: Nat}

def Cf.env(+c: Cf) -> List<&2, String>:
  match c:
    case Cf{e, h, t, n}:
      e

def Cf.harness(+c: Cf) -> String:
  match c:
    case Cf{e, h, t, n}:
      h

def Cf.t(+c: Cf) -> U32:
  match c:
    case Cf{e, h, t, n}:
      t

def Cf.cap(+c: Cf) -> Nat:
  match c:
    case Cf{e, h, t, n}:
      n

def relist(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> more:
      x <> relist(more)

# the `#check NAME` lines for the names the body uses
def checks(ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case n <> more:
      S.append(S.b("#check "), S.append(n, 10 <> checks(more)))

# The variants, in the order Harness.lean answers them, and where the hole
# and the Context sit among them (0: absent; else position + 1).
type Vs is Data:
  Vs{vs: List<&2, List<&2, U32>>, hole: Nat, ctx: Nat, m0: Nat}

def pre.each(+pre: List<&2, U32>, ms: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ms:
    case Nil{}:
      Nil{}
    case m <> more:
      S.append(pre, m) <> pre.each(pre, more)

def variants(+u: L.U) -> Vs:
  +pre = L.U.at(u, 6n)
  +h = L.U.at(u, 10n)
  +cs = checks(L.words(L.U.at(u, 9n)))
  +hn = Bool.pick(Nat, Nat.is_eq(S.len(h), 0n), 0n, 1n)
  +cn = Bool.pick(Nat, Nat.is_eq(S.len(cs), 0n), 0n, 1n)
  +a = {[S.append(pre, L.U.at(u, 7n))] : List<&2, List<&2, U32>>}
  +b = Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(hn, 0n), Nil{}, {[S.append(pre, h)] : List<&2, List<&2, U32>>})
  +c = Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(cn, 0n), Nil{}, {[cs] : List<&2, List<&2, U32>>})
  +vs = List.append(&2, List<&2, U32>, a, List.append(&2, List<&2, U32>, b, List.append(&2, List<&2, U32>, c, pre.each(pre, L.U.mutants(u)))))
  Vs{vs, Bool.pick(Nat, Nat.is_eq(hn, 0n), 0n, 2n), Bool.pick(Nat, Nat.is_eq(cn, 0n), 0n, Nat.add(2n, hn)), Nat.add(1n, Nat.add(hn, cn))}

def job.tail(vs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match vs:
    case Nil{}:
      Nil{}
    case v <> more:
      30 <> S.append(v, job.tail(more))

# the head, then each variant behind a 0x1E
def job.bytes(+head: List<&2, U32>, vs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  S.append(head, job.tail(vs))

# the answer's pieces: every 0x1E counts
def answers(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  L.fields.exact(xs)

def status.is(+c: List<&2, U32>, +s: String) -> Bool:
  S.eq(L.check.status(c), S.b(s))

# `$(printf '%s' "${C#*US}" | head -n CAP)`
def text.capped(+cap: Nat, +c: List<&2, U32>) -> List<&2, U32>:
  S.chomp(S.no.nul(S.lines.take(L.check.text(c), cap)))

def mut.at(kept: Bool, +cap: Nat, +m: List<&2, U32>, +c: List<&2, U32>, r: L.Mu) -> L.Mu:
  match kept r:
    case True{} L.Mu{cs, ks}:
      L.Mu{m <> L.check("1", text.capped(cap, c)) <> cs, "mutant_kept" <> ks}
    case False{} L.Mu{cs, ks}:
      L.Mu{cs, "mutant_checks" <> ks}

def muts(+cap: Nat, ms: List<&2, List<&2, U32>>, cs: List<&2, List<&2, U32>>) -> L.Mu:
  match ms cs:
    case +m <> mt +c <> ct:
      mut.at(status.is(c, "1"), cap, m, c, muts(cap, mt, ct))
    case _ _:
      L.Mu{Nil{}, Nil{}}

def hole.of(+at: Nat, +cs: List<&2, List<&2, U32>>) -> L.Hk:
  +c = L.nth(cs, Nat.sub(at, 1n))
  Bool.pick(L.Hk, Nat.is_eq(at, 0n), L.Hk{Nil{}, Nil{}},
    Bool.pick(L.Hk, status.is(c, "1"), L.Hk{c, ["hole"]}, L.Hk{Nil{}, ["hole_exit_" ++ S.str(L.check.status(c))]}))

def ctx.of(+cap: Nat, +at: Nat, +cs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(at, 0n), Nil{}, text.capped(cap, L.nth(cs, Nat.sub(at, 1n))))

def kept.mu(+u: L.U, +c0: List<&2, U32>, +cx: List<&2, U32>, hc: List<&2, U32>, hk: List<&2, String>, r: L.Mu) -> L.Got:
  match r:
    case L.Mu{ms, +ks}:
      L.Kept{L.result(u, c0 <> cx <> hc <> Nil{} <> ms), List.append(&2, String, hk, Bool.pick(List<&2, String>, Nat.is_eq(S.len(cx), 0n), ks, "context" <> ks))}

def kept.fin(+u: L.U, +c0: List<&2, U32>, +cx: List<&2, U32>, h: L.Hk, r: L.Mu) -> L.Got:
  match h:
    case L.Hk{hc, hk}:
      kept.mu(u, c0, cx, hc, hk, r)

def Vs.n(+v: Vs) -> Nat:
  match v:
    case Vs{vs, h, c, m}:
      List.length(&2, List<&2, U32>, vs)

def Vs.vs(+v: Vs) -> List<&2, List<&2, U32>>:
  match v:
    case Vs{vs, h, c, m}:
      vs

def answered.ok(ok: Bool, +cap: Nat, +u: L.U, +v: Vs, +cs: List<&2, List<&2, U32>>) -> L.Got:
  match ok v:
    case False{} _:
      L.Dropped{["original_exit_" ++ S.str(L.check.status(L.nth(cs, 0n)))]}
    case True{} Vs{vs, hole, ctx, m0}:
      kept.fin(u, L.nth(cs, 0n), ctx.of(cap, ctx, cs), hole.of(hole, cs), muts(cap, L.U.mutants(u), List.drop(&2, List<&2, U32>, cs, m0)))

def answered(+cap: Nat, +u: L.U, +v: Vs, +cs: List<&2, List<&2, U32>>, +n: Nat) -> L.Got:
  Bool.pick(L.Got, Nat.is_eq(List.length(&2, List<&2, U32>, cs), n),
    answered.ok(status.is(L.nth(cs, 0n), "0"), cap, u, v, cs), L.Dropped{["driver_short"]})

def ran(ok: Bool, +cap: Nat, +dir: String, +u: L.U, +v: Vs, +e: U32) -> IO(L.Got):
  match ok:
    case False{}:
      IO.pure(L.Got, L.Dropped{["driver_exit_" ++ U32.show(e)]})
    case True{}:
      do IO<L.Got>:
        out : List<&2, U32> <- S.read(dir ++ "/out")
        return answered(cap, u, v, answers(out), Vs.n(v))

def unit(+c: Cf, +dir: String, +u: L.U) -> IO(L.Got):
  +v = variants(u)
  do IO<L.Got>:
    S.write(dir ++ "/job", job.bytes(L.U.at(u, 5n), Vs.vs(v)))
    S.rm(dir ++ "/out")
    +o : S.Out <- S.run(dir, relist(Cf.env(c)), Cf.t(c), "lean", ["--run", Cf.harness(c), "job", "out"], Nil{})
    +there : Bool <- S.exists(dir ++ "/out")
    ran(Bool.and(U32.is_eq(S.Out.status(o), 0), there), Cf.cap(c), dir, u, v, S.Out.status(o))

def job(+c: Cf, +dir: String, us: List<&2, L.U>) -> IO(List<&2, L.Got>):
  match us:
    case Nil{}:
      IO.pure(List<&2, L.Got>, Nil{})
    case +u <> more:
      do IO<List<&2, L.Got>>:
        g : L.Got <- unit(c, dir, u)
        gs : List<&2, L.Got> <- job(c, dir, more)
        return g <> gs
