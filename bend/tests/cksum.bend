import Base
import ../Cksum.bend as C
import ../Sys.bend as S

# POSIX cksum against coreutils' values (`printf '%s\n' S | cksum`).

def verdict(+name: String, +want: U32, +got: U32) -> String:
  Bool.pick(String, U32.is_eq(want, got), "ok ", "FAIL ") ++ name

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(verdict("empty", 3515105045, C.cksum(S.b("\n"))))
    IO.print(verdict("a", 2418082923, C.cksum(S.b("a\n"))))
    IO.print(verdict("hello", 3015617425, C.cksum(S.b("hello\n"))))
    IO.print(verdict("id", 127603731, C.cksum(S.b("hackage:foo/src/A.hs#bar@12\n"))))
    IO.print(verdict("long", 328237085, C.cksum(S.append(S.b(String.repeat("x", 300n)), [10]))))
