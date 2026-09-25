import Base
import ../Units.bend as U
import ../Nul.bend as Ns
import ../Transcript.bend as T

# bend-units on one small file per language: how many units each gives, and
# that every unit's head ++ pre ++ body ++ tail is the file, byte for byte.
# Prints `ok LANG UNITS` per file, or `MISMATCH LANG`.

def hs() -> String:
  "module Util where\n\n-- | Pair two values.\ntup :: a -> b -> (a, b)\ntup a b = (a, b)\n\nunwrapOr :: a -> Maybe a -> a\nunwrapOr _ (Just x) = x\nunwrapOr y _ = y\n"

def agda() -> String:
  "module Id where\n\nopen import Agda.Builtin.Nat\nopen import Agda.Builtin.Equality\n\n-- zero on the right\n+-zero : ∀ n → n + zero ≡ n\n+-zero zero = refl\n+-zero (suc n) = cong suc (+-zero n)\n"

def lean() -> String:
  "import Mathlib.Data.Nat.Basic\n\n/-- n plus zero -/\ntheorem add_zero' (n : ℕ) : n + 0 = n := by\n  simp\n\ndef double (n : ℕ) : ℕ :=\n  n + n\n"

def bend() -> String:
  "import Base\n\nlaw Nat.z:\n  for +x: Nat\n  {Nat.add(x, 0n) == x : Nat}\n\ndef Nat.z(x):\n  match x:\n    case 0n:\n      {==}\n    case 1n+p:\n      %Nat.z(p) : {1n+Nat.add(p, 0n) == 1n+_ : Nat}\n      {==}\n\n# twice n\ndef twice(+n: Nat) -> Nat:\n  Nat.add(n, n)\n"

def nix() -> String:
  "# a set\n{ a = 1; b = 2; }\n"

def whole(+fs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  U.concat([U.nth(fs, 5n), U.nth(fs, 6n), U.nth(fs, 7n), U.nth(fs, 8n)])

def all.whole(us: List<&2, Ns.Doc>, +text: List<&2, U32>) -> Bool:
  match us:
    case Nil{}:
      True{}
    case Ns.Doc{i, r} <> t:
      Bool.and(U.eq(whole(T.split(r, 30)), text), all.whole(t, text))

def line(+name: String, +lang: Nat, +src: String, +expect: Nat) -> String:
  +text = U.b(src)
  +us = U.units.file(lang, 0n, U.b("own:test/" ++ name), text)
  +n = List.length(&2, Ns.Doc, us)
  +ok = Bool.and(Nat.is_eq(n, expect), all.whole(us, text))
  Bool.pick(String, ok, "ok " ++ name ++ " " ++ Nat.show(n), "MISMATCH " ++ name ++ " " ++ Nat.show(n))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(line("haskell", 0n, hs(), 2n))
    IO.print(line("agda", 1n, agda(), 1n))
    IO.print(line("lean", 2n, lean(), 2n))
    IO.print(line("bend", 3n, bend(), 2n))
    IO.print(line("nix", 4n, nix(), 1n))
