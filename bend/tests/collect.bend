import Base
import ../Sys.bend as S
import ../CorpusV2/Collect.bend as Co

# collect's pure parts (bend/CorpusV2/Collect.bend): the config, the repository
# lines, the listing rules, the loader's verdict, units, PINS and the vault's count.
# Each line prints `ok NAME` or `FAIL NAME`.  Run: bend bend/tests/collect.bend

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def cfg() -> Co.ColCfg():
  Co.col.cf.lines(S.split.lines(S.b("# a comment\nout run/x   # trailing\n\nrepo a/b all\ngrowth c/d lt100k exclude demos/ x/\nrepo e/f bogus\nupstream bendlang/bend 1d895ca0\ncorpus f1 f2\ncorpus f3\nprocs 8\n")))

def repo.is(+r: Co.ColRepo, +name: String, +dir: String, +rule: Nat, +excl: List<&2, List<&2, U32>>, +kind: Nat) -> Bool:
  match r:
    case Co.ColRepo{+n, +d, +u, +e, +k}:
      Bool.and(Bool.and(S.eq(n, S.b(name)), S.eq(d, S.b(dir))), Bool.and(Bool.and(Nat.is_eq(u, rule), Nat.is_eq(k, kind)),
        S.eq(S.join(e, 32), S.join(excl, 32))))

def nth(rs: List<&2, Co.ColRepo>, +i: Nat) -> Co.ColRepo:
  Maybe.default(&2, Co.ColRepo, List.get(&2, Co.ColRepo, rs, i), Co.ColRepo{Nil{}, Nil{}, 7n, Nil{}, 7n})

def why(+rule: Nat, +p: String, +z: Nat) -> Nat:
  Co.col.why(rule, [S.b("demos/")], 1000000n, Co.ColF{S.b(p), z})

def main() -> IO(Unit):
  +c = cfg()
  +rs = Co.col.repos(c)
  do IO<Unit>:
    IO.print(verdict("cfg-one", S.eq(Co.col.cf.one(c, "out", "-"), S.b("run/x"))))
    IO.print(verdict("cfg-default", S.eq(Co.col.cf.one(c, "src", "-"), S.b("-"))))
    IO.print(verdict("cfg-nat", Nat.is_eq(Co.col.cf.nat(c, "procs", 4n), 8n)))
    IO.print(verdict("cfg-all", S.eq(S.join(Co.col.cf.all(c, "corpus"), 32), S.b("f1 f2 f3"))))
    IO.print(verdict("repos-count", Nat.is_eq(List.length(&2, Co.ColRepo, rs), 4n)))
    IO.print(verdict("repo-new", repo.is(nth(rs, 0n), "a/b", "a__b", 0n, Nil{}, 0n)))
    IO.print(verdict("repo-growth", repo.is(nth(rs, 1n), "c/d", "c__d", 1n, [S.b("demos/"), S.b("x/")], 1n)))
    IO.print(verdict("repo-bad-rule", Nat.is_eq(List.length(&2, List<&2, U32>, Co.col.bad.rules(rs)), 1n)))
    IO.print(verdict("repo-upstream-last", repo.is(nth(rs, 3n), "bendlang/bend", "bendlang__bend", 0n, Nil{}, 2n)))
    IO.print(verdict("fold", S.eq(Co.col.r.fold(nth(rs, 3n)), S.b("bend"))))
    IO.print(verdict("why-keep", Nat.is_eq(why(0n, "src/a.bend", 10n), 0n)))
    IO.print(verdict("why-excluded", Nat.is_eq(why(0n, "demos/a.bend", 10n), 1n)))
    IO.print(verdict("why-vendored", Nat.is_eq(why(0n, "x/node_modules/a.bend", 10n), 2n)))
    IO.print(verdict("why-vendor-file", Nat.is_eq(why(0n, "x/vendor", 10n), 0n)))
    IO.print(verdict("why-generated", Nat.is_eq(why(0n, "a_generated.bend", 10n), 3n)))
    IO.print(verdict("why-big", Nat.is_eq(why(0n, "a.bend", 1000001n), 4n)))
    IO.print(verdict("why-1mb-kept", Nat.is_eq(why(0n, "a.bend", 1000000n), 0n)))
    IO.print(verdict("why-lt100k", Nat.is_eq(why(1n, "a.bend", 100000n), 4n)))
    IO.print(verdict("loader-pass", S.eq(Co.col.verdict(0, S.b("ok\n")), S.b("pass\t"))))
    IO.print(verdict("loader-timeout", S.eq(Co.col.verdict(124, Nil{}), S.b("timeout\t"))))
    IO.print(verdict("loader-checked", S.eq(Co.col.verdict(1, S.b("x\n- expected : Nat\nLocation: f\n")), S.b("checked\t- expected : Nat"))))
    IO.print(verdict("loader-location-space", S.eq(Co.col.verdict(1, S.b("Location:  f\nError: bad\n")), S.b("load\tError: bad"))))
    IO.print(verdict("loader-todo", S.eq(Co.col.verdict(1, S.b("Error: 3 TODOs found.\n")), S.b("checked\tError: 3 TODOs found."))))
    IO.print(verdict("loader-unsafe", S.eq(Co.col.verdict(1, S.b("Error: 2 defs rely on unsafe or foreign code:\n")), S.b("checked\tError: 2 defs rely on unsafe or foreign code:"))))
    IO.print(verdict("loader-load", S.eq(Co.col.verdict(1, S.b("Error: \n- message  : no such file\n")), S.b("load\t- message  : no such file"))))
    IO.print(verdict("loader-cut", Nat.is_eq(S.len(Co.col.verdict(1, S.append(S.b("Error: "), List.replicate(U32, 300n, 120)))), 165n)))
    IO.print(verdict("unit-big", S.eq(Co.col.unit(Set.add(Set.new(), Co.col.k(S.b("r"))), S.b("r"), S.b("a/b/c.bend")), S.b("r/a/b"))))
    IO.print(verdict("unit-big-root", S.eq(Co.col.unit(Set.add(Set.new(), Co.col.k(S.b("r"))), S.b("r"), S.b("c.bend")), S.b("r/"))))
    IO.print(verdict("unit-small", S.eq(Co.col.unit(Set.new(), S.b("r"), S.b("a/c.bend")), S.b("r"))))
    IO.print(verdict("quoted", S.eq(S.join(Co.col.quoted(S.split(S.b("{\"s\": [\"a\", \"b\"]}"), 34), False{}), 32), S.b("s a b"))))
    IO.print(verdict("vault-quarter", Nat.is_eq(Co.col.vault.n(S.b("quarter"), 26n), 7n)))
    IO.print(verdict("vault-none", Nat.is_eq(Co.col.vault.n(S.b("none"), 26n), 0n)))
    IO.print(verdict("pin-last", S.eq(Co.col.pin(S.split.lines(S.b("a/b\t111\td\tMIT\nc/d\t222\td\t-\na/b\t333\td\tMIT\n")), S.b("a/b")), S.b("333"))))
    IO.print(verdict("pin-none", S.eq(Co.col.pin(S.split.lines(S.b("a/b\t111\td\tMIT\n")), S.b("x/y")), Nil{})))
    IO.print(verdict("runs", S.eq(S.join(Co.col.rn.lines(Co.col.runs(S.split.lines(S.b("a\tx\na\ty\nb\tz\n")))), 32), S.b("a\t2 b\t1"))))
