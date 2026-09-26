import Base
import ../Sys.bend as S
import ./Lib.bend as L

# Nix checks Nix units.  A Nix unit is a whole file, written as Unit.nix
# and evaluated with
#
#   nix-instantiate --eval --strict Unit.nix
#
# under an empty NIX_PATH, so the check is the value (a function prints as
# <LAMBDA>) or the evaluation error.  A file that imports <nixpkgs> or a
# path beside it fails its original check and is dropped.  Nix has no types
# and no holes: Context, hole and type are empty.  A mutant is kept when
# its evaluation fails with a status other than a timeout's 124.

def eval(+t: U32, +dir: String, body: List<&2, U32>) -> IO(S.Out):
  do IO<S.Out>:
    S.write(dir ++ "/Unit.nix", body)
    S.run(dir, ["NIX_PATH="], t, "nix-instantiate", ["--eval", "--strict", "Unit.nix"], Nil{})

def check.of(+dir: String, +cap: Nat, +o: S.Out) -> List<&2, U32>:
  L.check(U32.show(S.Out.status(o)), S.clean(dir, cap, S.Out.text(o)))

def mu.add(+m: List<&2, U32>, +o: S.Out, +dir: String, +cap: Nat, r: L.Mu) -> L.Mu:
  L.mu.rule(S.Out.status(o), m, check.of(dir, cap, o), r)

def muts(+t: U32, +dir: String, +cap: Nat, ms: List<&2, List<&2, U32>>) -> IO(L.Mu):
  match ms:
    case Nil{}:
      IO.pure(L.Mu, L.Mu{Nil{}, Nil{}})
    case +m <> more:
      do IO<L.Mu>:
        +o : S.Out <- eval(t, dir, m)
        r : L.Mu <- muts(t, dir, cap, more)
        return mu.add(m, o, dir, cap, r)

def kept(+u: L.U, +verdict: List<&2, U32>, r: L.Mu) -> L.Got:
  match r:
    case L.Mu{cs, ks}:
      L.Kept{L.result(u, verdict <> Nil{} <> Nil{} <> Nil{} <> cs), ks}

def orig(ok: Bool, +t: U32, +dir: String, +cap: Nat, +u: L.U, +o: S.Out) -> IO(L.Got):
  match ok:
    case False{}:
      IO.pure(L.Got, L.Dropped{["original_exit_" ++ U32.show(S.Out.status(o))]})
    case True{}:
      do IO<L.Got>:
        r : L.Mu <- muts(t, dir, cap, L.U.mutants(u))
        return kept(u, check.of(dir, cap, o), r)

def unit(+t: U32, +dir: String, +cap: Nat, +u: L.U) -> IO(L.Got):
  do IO<L.Got>:
    +o : S.Out <- eval(t, dir, L.U.at(u, 7n))
    orig(U32.is_eq(S.Out.status(o), 0), t, dir, cap, u, o)

def job(+t: U32, +dir: String, +cap: Nat, us: List<&2, L.U>) -> IO(List<&2, L.Got>):
  match us:
    case Nil{}:
      IO.pure(List<&2, L.Got>, Nil{})
    case +u <> more:
      do IO<List<&2, L.Got>>:
        g : L.Got <- unit(t, dir, cap, u)
        gs : List<&2, L.Got> <- job(t, dir, cap, more)
        return g <> gs
