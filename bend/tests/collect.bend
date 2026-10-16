import Base
import ../Sys.bend as S
import ../CorpusV2/Collect.bend as Co

# collect's pure parts (bend/CorpusV2/Collect.bend): the config, the repository
# lines, the listing rules, the loader's verdict, units, PINS and the vault's count;
# the hub (2026-10-16): the hub line, a listing in packages.json's shape read into
# packages, the choice (the newest version of a name by number, then time; every
# unnamed package), PINS over it, the rows, plain paths, the manifest and its hash.
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


# The hub (2026-10-16): a listing in packages.json's shape (pkg-a twice, its older
# version second; an unnamed package with a licence file without an id; one without
# a licence; an empty files object)
def hub.json() -> List<&2, U32>:
  S.b("{\"total\":5,\"packages\":[{\"hash\":\"0xaa\",\"files\":{\"LICENSE\":10,\"main.bend\":20},\"bytes\":30,\"ts\":1792163256974,\"desc\":\"a \\\"q\\\" desc\",\"entry\":\"main.bend\",\"name\":\"pkg-a\",\"version\":\"0.1.11.0\",\"dependents\":0,\"hot\":1.5e2,\"license\":{\"file\":\"LICENSE\",\"id\":\"MIT\"}},{\"hash\":\"0xbb\",\"files\":{\"main.bend\":5},\"ts\":1792000000000,\"desc\":null,\"name\":\"pkg-a\",\"version\":\"0.1.3.0\",\"license\":null},{\"hash\":\"0xcc\",\"files\":{\"a/b.bend\":5},\"ts\":1791000000000,\"name\":null,\"version\":null,\"license\":{\"file\":\"LICENSE\",\"id\":null}},{\"hash\":\"0xdd\",\"files\":{},\"ts\":1790000000000,\"name\":\"pkg-b\",\"version\":\"1.0.0.0\",\"license\":{\"file\":\"LICENSE\",\"id\":\"MIT OR Apache-2.0\"}},{\"hash\":\"0xee\",\"files\":{\"m.bend\":1},\"ts\":1789000000000,\"name\":null,\"version\":null,\"license\":null}]}")

# a publish time in ms (the compiler takes Nat literals up to 2^32 only)
def hub.t(+hi: Nat, +lo: Nat) -> Nat:
  Nat.add(Nat.mul(hi, 1000000n), lo)

def hub.pkgs() -> List<&2, Co.ColHub>:
  Maybe.default(&2, List<&2, Co.ColHub>, Co.col.hub.listing(hub.json()), Nil{})

def hub.nth(hs: List<&2, Co.ColHub>, +i: Nat) -> Co.ColHub:
  Maybe.default(&2, Co.ColHub, List.get(&2, Co.ColHub, hs, i), Co.col.hub.empty())

def hub.is(+h: Co.ColHub, +hash: String, +name: String, +ver: String, +ts: Nat, +lic: String) -> Bool:
  Bool.and(Bool.and(S.eq(Co.col.hub.hash(h), S.b(hash)), S.eq(Co.col.hub.name(h), S.b(name))),
    Bool.and(Bool.and(S.eq(Co.col.hub.version(h), S.b(ver)), Nat.is_eq(Co.col.hub.ts(h), ts)), S.eq(Co.col.hub.lic(h), S.b(lic))))

def hub.hashes(hs: List<&2, Co.ColHub>) -> List<&2, U32>:
  match hs:
    case Nil{}:
      Nil{}
    case +h <> more:
      S.append(S.append(Co.col.hub.hash(h), [32]), hub.hashes(more))

def hub.sha() -> String:
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

def hub.man.n(+xs: String) -> Nat:
  List.length(&2, Co.ColHf, Maybe.default(&2, List<&2, Co.ColHf>, Co.col.hub.man(S.b(xs)), Nil{}))

def hub.cfg() -> Co.ColCfg():
  Co.col.cf.lines(S.split.lines(S.b("out o\nhub https://hub.x/ all exclude tests/ gen/\nhub https://other bogus\n")))

def hub.cf.is(hs: List<&2, Co.ColHubCf>) -> Bool:
  match hs:
    case Co.ColHubCf{+u, +r, +e} <> Nil{}:
      Bool.and(Bool.and(S.eq(u, S.b("https://hub.x/")), Nat.is_eq(r, 0n)), S.eq(S.join(e, 32), S.b("tests/ gen/")))
    case _:
      False{}

def hub.repo.is(rs: List<&2, Co.ColRepo>) -> Bool:
  match rs:
    case +r <> Nil{}:
      Bool.and(repo.is(r, "hub/pkg-a", "hub__pkg-a", 1n, [S.b("x/")], 3n), S.eq(Co.col.r.fold(r), S.b("pkg-a")))
    case _:
      False{}

def hub.main() -> IO(Unit):
  +ps = hub.pkgs()
  +pins = S.split.lines(S.b("hub/pkg-a\t0xbb\t2026-10-14T17:46:40Z\tMIT-0 (default)\tpkg-a@0.1.3.0\nhub/pkg-b\t0xff\td\t-\tpkg-b@9.0.0.0\n"))
  +f1 : Co.ColHf = Co.ColHf{S.b(hub.sha()), S.b("main.bend")}
  do IO<Unit>:
    IO.print(verdict("hub-cfg", hub.cf.is(Co.col.hub.cf(hub.cfg()))))
    IO.print(verdict("hub-cfg-base", String.eq(Co.col.hub.base(S.b("https://hub.x/")), "https://hub.x")))
    IO.print(verdict("hub-cfg-bad-rule", Nat.is_eq(List.length(&2, List<&2, U32>, Co.col.hub.cf.rules(Co.col.hub.cf(Co.col.cf.lines(S.split.lines(S.b("hub u bogus\n")))))), 1n)))
    IO.print(verdict("hub-cfg-none", Nat.is_eq(List.length(&2, Co.ColHubCf, Co.col.hub.cf(cfg())), 0n)))
    IO.print(verdict("hub-page-url", String.eq(Co.col.hub.page.url("https://hub.x", 200n), "https://hub.x/packages.json?sort=new&limit=100&after=200")))
    IO.print(verdict("hub-listing", Nat.is_eq(List.length(&2, Co.ColHub, ps), 5n)))
    IO.print(verdict("hub-total", Nat.is_eq(Co.col.hub.total(hub.json()), 5n)))
    IO.print(verdict("hub-not-json", Maybe.is_none(&2, List<&2, Co.ColHub>, Co.col.hub.listing(S.b("{\"total\":1,\"packages\":[")))))
    IO.print(verdict("hub-pkg-named", hub.is(hub.nth(ps, 0n), "0xaa", "pkg-a", "0.1.11.0", hub.t(1792163n, 256974n), "MIT")))
    IO.print(verdict("hub-pkg-no-licence", hub.is(hub.nth(ps, 1n), "0xbb", "pkg-a", "0.1.3.0", hub.t(1792000n, 0n), "MIT-0 (default)")))
    IO.print(verdict("hub-pkg-licence-file", hub.is(hub.nth(ps, 2n), "0xcc", "", "", hub.t(1791000n, 0n), "LICENSE")))
    IO.print(verdict("hub-pkg-licence-or", hub.is(hub.nth(ps, 3n), "0xdd", "pkg-b", "1.0.0.0", hub.t(1790000n, 0n), "MIT OR Apache-2.0")))
    IO.print(verdict("hub-vcmp-numbers", Nat.is_eq(Co.col.hub.vcmp(Co.col.hub.ver(S.b("0.1.11.0")), Co.col.hub.ver(S.b("0.1.3.0"))), 2n)))
    IO.print(verdict("hub-vcmp-equal", Nat.is_eq(Co.col.hub.vcmp(Co.col.hub.ver(S.b("1.0.0.0")), Co.col.hub.ver(S.b("1.0.0.0"))), 1n)))
    IO.print(verdict("hub-vcmp-prefix", Nat.is_eq(Co.col.hub.vcmp(Co.col.hub.ver(S.b("1.0")), Co.col.hub.ver(S.b("1.0.0.0"))), 0n)))
    IO.print(verdict("hub-choose", S.eq(hub.hashes(Co.col.hub.choose(ps)), S.b("0xcc 0xee 0xaa 0xdd "))))
    IO.print(verdict("hub-choose-order-free", S.eq(hub.hashes(Co.col.hub.choose(List.reverse(&2, Co.ColHub, ps))), S.b("0xcc 0xee 0xaa 0xdd "))))
    IO.print(verdict("hub-choose-later-same-version", S.eq(hub.hashes(Co.col.hub.choose([Co.ColHub{S.b("0x1"), S.b("c"), S.b("1.0.0.0"), 5n, Nil{}}, Co.ColHub{S.b("0x2"), S.b("c"), S.b("1.0.0.0"), 9n, Nil{}}, Co.ColHub{S.b("0x3"), S.b("c"), S.b("1.0.0.0"), 7n, Nil{}}])), S.b("0x2 "))))
    IO.print(verdict("hub-uniq", S.eq(hub.hashes(Co.col.hub.uniq(List.append(&2, Co.ColHub, ps, [hub.nth(ps, 2n)]))), S.b("0xaa 0xbb 0xcc 0xdd 0xee "))))
    IO.print(verdict("hub-pinned", S.eq(hub.hashes(Co.col.hub.pins(Co.col.hub.choose(ps), ps, pins)), S.b("0xcc 0xee 0xbb 0xff "))))
    IO.print(verdict("hub-pinned-row", hub.is(hub.nth(Co.col.hub.pins(Co.col.hub.choose(ps), ps, pins), 2n), "0xbb", "pkg-a", "0.1.3.0", hub.t(1792000n, 0n), "MIT-0 (default)")))
    IO.print(verdict("hub-pinned-gone", hub.is(hub.nth(Co.col.hub.pins(Co.col.hub.choose(ps), ps, pins), 3n), "0xff", "pkg-b", "?", 0n, "?")))
    IO.print(verdict("hub-dir", S.eq(S.join([Co.col.hub.dir(hub.nth(ps, 0n)), Co.col.hub.dir(hub.nth(ps, 2n))], 32), S.b("hub__pkg-a hub__0xcc"))))
    IO.print(verdict("hub-pin-row", S.eq(Co.col.hub.pin.row(hub.nth(ps, 0n)), S.b("hub/pkg-a\t0xaa\t2026-10-16T15:07:36Z\tMIT\tpkg-a@0.1.11.0\n"))))
    IO.print(verdict("hub-pin-row-unnamed", S.eq(Co.col.hub.pin.row(hub.nth(ps, 2n)), S.b("hub/0xcc\t0xcc\t2026-10-03T04:00:00Z\tLICENSE\t0xcc\n"))))
    IO.print(verdict("hub-row", S.eq(Co.col.hub.row(hub.nth(ps, 0n)), S.b("hub__pkg-a\thub/pkg-a\t0xaa\t0.1.11.0\tMIT\n"))))
    IO.print(verdict("hub-repos", hub.repo.is(Co.col.hub.repos.of(S.split.lines(S.b("hub__pkg-a\thub/pkg-a\t0xaa\t0.1.11.0\tMIT\nbad line\n")), 1n, [S.b("x/")]))))
    IO.print(verdict("hub-path-ok", Bool.and(Co.col.hub.path.ok(S.b("src/A.bend")), Co.col.hub.path.ok(S.b("a-b_c.d/e.bend")))))
    IO.print(verdict("hub-path-bad", Bool.not(Bool.or(Bool.or(Bool.or(Co.col.hub.path.ok(Nil{}), Co.col.hub.path.ok(S.b("/x"))), Bool.or(Co.col.hub.path.ok(S.b("a/")), Co.col.hub.path.ok(S.b("a//b")))),
      Bool.or(Bool.or(Co.col.hub.path.ok(S.b("../x")), Co.col.hub.path.ok(S.b("a/./b"))), Bool.or(Co.col.hub.path.ok(S.b("a b.bend")), Co.col.hub.path.ok(S.b("a\\b.bend"))))))))
    IO.print(verdict("hub-manifest", Nat.is_eq(hub.man.n(hub.sha() ++ " main.bend\n" ++ hub.sha() ++ " src/x.bend\n"), 2n)))
    IO.print(verdict("hub-manifest-bad", Nat.is_eq(Nat.add(Nat.add(hub.man.n(hub.sha() ++ " main.bend\n" ++ hub.sha() ++ " ../x.bend\n"), hub.man.n(String.drop(hub.sha(), 1n) ++ " main.bend\n")),
      Nat.add(hub.man.n(""), hub.man.n(hub.sha() ++ "\n"))), 0n)))
    IO.print(verdict("hub-manifest-hash", Bool.and(Co.col.hub.man.ok(S.b("0xba7816bf8f01cfea414140de5dae2223"), S.b("abc")),
      Bool.not(Bool.or(Bool.or(Co.col.hub.man.ok(S.b("0xba7816bf8f01cfea414140de5dae2224"), S.b("abc")), Co.col.hub.man.ok(S.b("ba7816bf8f01cfea414140de5dae2223"), S.b("abc"))), Co.col.hub.man.ok(S.b("0xba7816bf"), S.b("abc")))))))
    IO.print(verdict("hub-sums", S.eq(Co.col.hub.sums([f1, Co.ColHf{S.b(hub.sha()), S.b("a/b.bend")}]), S.b(hub.sha() ++ "  main.bend\n" ++ hub.sha() ++ "  a/b.bend\n"))))
    IO.print(verdict("hub-gets", String.eq(String.join(Co.col.hub.gets([f1], "https://hub.x", "0xaa"), " "), "-o main.bend https://hub.x/0xaa/main.bend")))

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
    hub.main()
