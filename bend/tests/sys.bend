import Base
import ../Sys.bend as S

# Sys: the process shim (status, merged stderr, timeout, cwd, env, stdin),
# the output cleaning the scripts did with sed/head/$(...), byte splitting,
# and the NUL-framed reader.  Each line prints `ok NAME` or `FAIL NAME`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def out.is(+o: S.Out, +st: U32, +text: String) -> Bool:
  Bool.and(U32.is_eq(S.Out.status(o), st), S.eq(S.Out.text(o), S.b(text)))

def pieces(xs: List<&2, List<&2, U32>>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> more:
      "[" ++ S.str(x) ++ "]" ++ pieces(more)

def fields.go(fuel: Nat, r: S.Rd & Maybe<&2, List<&2, U32>>, acc: String) -> IO(String):
  match fuel r:
    case 1n+p Tuple{rd, Some{x}}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, String, S.Rd.next(rd), rq => fields.go(p, rq, acc ++ "[" ++ S.str(x) ++ "]"))
    case _ Tuple{rd, _}:
      do IO<String>:
        S.Rd.close(rd)
        return acc

def main() -> IO(Unit):
  do IO<Unit>:
    +a : S.Out <- S.run(".", [], 5, "printf", ["a\\nb\\n"], Nil{})
    IO.print(verdict("run", out.is(a, 0, "a\nb\n")))
    +c : S.Out <- S.run(".", [], 5, "sh", ["-c", "echo out; echo err >&2; exit 3"], Nil{})
    IO.print(verdict("merge", out.is(c, 3, "out\nerr\n")))
    +d : S.Out <- S.run(".", [], 1, "sh", ["-c", "echo early; sleep 5"], Nil{})
    IO.print(verdict("timeout", out.is(d, 124, "early\n")))
    +e : S.Out <- S.run("/", [], 5, "pwd", [], Nil{})
    IO.print(verdict("cwd", out.is(e, 0, "/\n")))
    +f : S.Out <- S.run(".", ["FT_SYS_TEST=bar", "FT_EMPTY="], 5, "sh", ["-c", "echo \"$FT_SYS_TEST[$FT_EMPTY]\""], Nil{})
    IO.print(verdict("env", out.is(f, 0, "bar[]\n")))
    +g : S.Out <- S.run(".", [], 5, "cat", [], S.b("xyz é"))
    IO.print(verdict("stdin", out.is(g, 0, "xyz é")))
    IO.print(verdict("clean", S.eq(S.clean("/w", 2n, S.b("/w/a /w/x\n/w/b\n/w/c\n\n")), S.b("a x\nb"))))
    IO.print(verdict("parent", String.eq(S.parent("/tmp/w/0") ++ S.parent("x"), "/tmp/wx")))
    IO.print(verdict("root", S.eq(S.clean("/t/w/0", 9n, S.b("/t/w/0/U.nix /t/w/lib/a.nix\n")), S.b("U.nix lib/a.nix"))))
    IO.print(verdict("chomp", S.eq(S.clean("/w", 9n, S.b("a\n\nb\n\n\n")), S.b("a\n\nb"))))
    IO.print(verdict("split", String.eq(pieces(S.split(S.b("a\n\nb"), 10)) ++ pieces(S.split(S.b("a\n"), 10)) ++ pieces(S.split(S.b("\n"), 10)), "[a][][b][a][]")))
    IO.print(verdict("replace", S.eq(S.replace(S.b("aXXbXXX"), S.b("XX"), S.b("-")), S.b("a-b-X"))))
    +dir : String <- S.mktemp()
    S.write(dir ++ "/nul", S.b("id1\u{0}text one\u{0}id2\u{0}\u{0}"))
    rd : S.Rd <- S.Rd.open(dir ++ "/nul")
    r0 : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
    got : String <- fields.go(10n, r0, "")
    IO.print(verdict("nul", String.eq(got, "[id1][text one][id2][]")))
    +h : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/nul")
    IO.print(verdict("slurp", Nat.is_eq(S.len(S.slurp.or(h)), 18n)))
    +x : Bool <- S.exists(dir ++ "/none")
    IO.print(verdict("exists", Bool.not(x)))
    S.rm(dir)
