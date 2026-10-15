import Base
import ../Sys.bend as S

# Sys: the process shim (status, merged stderr, timeout, cwd, env, stdin),
# the output cleaning the scripts did with sed/head/$(...), byte splitting,
# the NUL-framed reader, the redirections (run.to, run.feed, run.from), the
# glob and byte order.  Each line prints `ok NAME` or `FAIL NAME`.

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

def names.eq(xs: List<&2, List<&2, U32>>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(S.eq(x, S.b(y)), names.eq(xt, yt))
    case _ _:
      False{}

# the children are programs, not shell lines (2026-10-15, the plan's Phase 7):
# cat writes a file's bytes then an error for a missing one (merge), tail -f
# writes and waits (timeout), printenv reads the environment (env)
def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    S.write(dir ++ "/out", S.b("out\n"))
    S.write(dir ++ "/early", S.b("early\n"))
    +a : S.Out <- S.run(".", [], 5, "printf", ["a\\nb\\n"], Nil{})
    IO.print(verdict("run", out.is(a, 0, "a\nb\n")))
    +c : S.Out <- S.run(".", [], 5, "cat", [dir ++ "/out", dir ++ "/missing"], Nil{})
    IO.print(verdict("merge", Bool.and(U32.is_eq(S.Out.status(c), 1), Bool.and(S.prefix(S.Out.text(c), S.b("out\ncat: ")),
      S.suffix(S.Out.text(c), S.b("/missing: No such file or directory\n"))))))
    +d : S.Out <- S.run(".", [], 1, "tail", ["-f", dir ++ "/early"], Nil{})
    IO.print(verdict("timeout", out.is(d, 124, "early\n")))
    +e : S.Out <- S.run("/", [], 5, "pwd", [], Nil{})
    IO.print(verdict("cwd", out.is(e, 0, "/\n")))
    +f : S.Out <- S.run(".", ["FT_SYS_TEST=bar", "FT_EMPTY="], 5, "printenv", ["FT_SYS_TEST", "FT_EMPTY"], Nil{})
    IO.print(verdict("env", out.is(f, 0, "bar\n\n")))
    +g : S.Out <- S.run(".", [], 5, "cat", [], S.b("xyz é"))
    IO.print(verdict("stdin", out.is(g, 0, "xyz é")))
    IO.print(verdict("clean", S.eq(S.clean("/w", 2n, S.b("/w/a /w/x\n/w/b\n/w/c\n\n")), S.b("a x\nb"))))
    IO.print(verdict("parent", String.eq(S.parent("/tmp/w/0") ++ S.parent("x"), "/tmp/wx")))
    IO.print(verdict("root", S.eq(S.clean("/t/w/0", 9n, S.b("/t/w/0/U.nix /t/w/lib/a.nix\n")), S.b("U.nix lib/a.nix"))))
    IO.print(verdict("chomp", S.eq(S.clean("/w", 9n, S.b("a\n\nb\n\n\n")), S.b("a\n\nb"))))
    IO.print(verdict("split", String.eq(pieces(S.split(S.b("a\n\nb"), 10)) ++ pieces(S.split(S.b("a\n"), 10)) ++ pieces(S.split(S.b("\n"), 10)), "[a][][b][a][]")))
    IO.print(verdict("replace", S.eq(S.replace(S.b("aXXbXXX"), S.b("XX"), S.b("-")), S.b("a-b-X"))))
    S.write(dir ++ "/nul", S.b("id1\u{0}text one\u{0}id2\u{0}\u{0}"))
    rd : S.Rd <- S.Rd.open(dir ++ "/nul")
    r0 : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
    got : String <- fields.go(10n, r0, "")
    IO.print(verdict("nul", String.eq(got, "[id1][text one][id2][]")))
    +h : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/nul")
    IO.print(verdict("slurp", Nat.is_eq(S.len(S.slurp.or(h)), 18n)))
    +x : Bool <- S.exists(dir ++ "/none")
    IO.print(verdict("exists", Bool.not(x)))
    +t : S.Out <- S.run.to(dir, [], 5, "cat", ["out", "missing"], "to")
    +tw : List<&2, U32> <- S.read(dir ++ "/to")
    IO.print(verdict("to", Bool.and(Bool.and(U32.is_eq(S.Out.status(t), 1), S.eq(tw, S.b("out\n"))),
      S.suffix(S.Out.text(t), S.b("missing: No such file or directory\n")))))
    S.write(dir ++ "/log", S.b("before\n"))
    +fd : U32 <- S.run.feed(dir, ["FT_SYS_TEST=bar"], 5, "cat", ["-", "early"], "log", S.b("fed é\n"))
    +fl : List<&2, U32> <- S.read(dir ++ "/log")
    IO.print(verdict("feed", Bool.and(U32.is_eq(fd, 0), S.eq(fl, S.b("before\nfed é\nearly\n")))))
    +fr : S.Out <- S.run.from(dir, [], 5, "cat", ["-", "missing"], "out")
    IO.print(verdict("from", Bool.and(U32.is_eq(S.Out.status(fr), 1), S.eq(S.Out.text(fr), S.b("out\n")))))
    S.mkdir(dir ++ "/g/sub")
    S.write(dir ++ "/g/b.nul", Nil{})
    S.write(dir ++ "/g/a.nul", Nil{})
    S.write(dir ++ "/g/.h.nul", Nil{})
    S.write(dir ++ "/g/c.txt", Nil{})
    S.write(dir ++ "/g/sub/x.nul", Nil{})
    +g1 : List<&2, List<&2, U32>> <- S.glob(dir ++ "/g/*.nul " ++ dir ++ "/g/s?b/*.nul " ++ dir ++ "/g/.h.nul " ++ dir ++ "/g/none/*.nul " ++ dir ++ "/g/gone")
    IO.print(verdict("glob", names.eq(S.bytes.sort(g1), [dir ++ "/g/.h.nul", dir ++ "/g/a.nul", dir ++ "/g/b.nul", dir ++ "/g/sub/x.nul"])))
    IO.print(verdict("bytes", names.eq(S.bytes.sort([S.b("b"), S.b("ab"), S.b("a"), S.b("B"), S.b(""), S.b("é"), S.b("a")]), ["", "B", "a", "a", "ab", "b", "é"])))
    S.rm(dir)
