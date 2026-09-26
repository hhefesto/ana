import Base
import ../Mix.bend as M

# Mix: the summary's percentages as awk's printf "%.1f" prints 100 * a / b,
# exact ties included (the double nearest 0.15 is below it, the one nearest
# 0.45 above; 0.25 and 0.75 are doubles, rounded to even).  Each line prints
# `ok a/b` or `FAIL a/b got`.

def check(+a: Nat, +b: Nat, +want: String) -> String:
  +got = M.pct(a, b)
  Bool.pick(String, String.eq(got, want), "ok ", "FAIL ") ++ Nat.show(a) ++ "/" ++ Nat.show(b) ++ Bool.pick(String, String.eq(got, want), "", " " ++ got)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(check(1n, 8n, "12.5"))
    IO.print(check(1n, 400n, "0.2"))
    IO.print(check(3n, 400n, "0.8"))
    IO.print(check(3n, 2000n, "0.1"))
    IO.print(check(9n, 2000n, "0.5"))
    IO.print(check(7n, 2000n, "0.3"))
    IO.print(check(2n, 3n, "66.7"))
    IO.print(check(5n, 4000n, "0.1"))
    IO.print(check(333n, 2000n, "16.6"))
    IO.print(check(1999n, 2000n, "100.0"))
    IO.print(check(49n, 50n, "98.0"))
    IO.print(check(0n, 0n, "0.0"))
