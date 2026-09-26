import Base
import ../Clean.bend as C
import ../Sys.bend as S

# Clean: the MinHash signature and the n-grams bend-clean drops units by.
# Each line prints `ok NAME` or `FAIL NAME`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def same(xs: List<&2, U32>, ys: List<&2, U32>, +n: Nat) -> Nat:
  match xs ys:
    case +x <> xt +y <> yt:
      same(xt, yt, Bool.pick(Nat, U32.is_eq(x, y), 1n+n, n))
    case _ _:
      n

def text(+w: String) -> String:
  "go :: Int -> Int\ngo n = if n <= 0 then 0 else go (n - 1) + " ++ w ++ " * n\n  where helper k = map (+ k) [1 .. n] ++ filter even (take 10 (iterate (* 2) k)) ++ reverse [n, n - 1 .. 0]\n  -- and a tail long enough for shingles to carry weight: fold the list with a step\n"

def other() -> String:
  "{ pkgs, lib, ... }: { services.nginx.enable = true; networking.firewall.allowedTCPPorts = [ 80 443 ]; users.users.alice = { isNormalUser = true; extraGroups = [ \"wheel\" ]; }; }"

def main() -> IO(Unit):
  +a = C.signature(C.toks(S.b(text("m"))))
  +b = C.signature(C.toks(S.b(text("k"))))
  +o = C.signature(C.toks(S.b(other())))
  do IO<Unit>:
    IO.print(verdict("near", Nat.is_le(90n, same(a, b, 0n))))
    IO.print(verdict("far", Nat.is_lt(same(a, o, 0n), 20n)))
    IO.print(verdict("self", Nat.is_eq(same(a, a, 0n), 128n)))
    IO.print(verdict("grams", Nat.is_eq(List.length(&2, List<&2, U32>, C.grams(C.toks(S.b("a b c d e f g h i j k l")), 10n)), 3n)))
    IO.print(verdict("short", Nat.is_eq(List.length(&2, U32, C.shingles(C.toks(S.b("a b c")))), 1n)))
    IO.print(verdict("key", String.eq(C.h64(S.b("x")), C.h64(S.b("x")))))
