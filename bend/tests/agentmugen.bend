import Base
import ../Units.bend as U
import ../Transcript.bend as T
import ../Agent/Spec.bend as A
import ../CorpusV2/AgentMugen.bend as M
import ../Agent/Loop.bend as Lp

# agent-mugen (CorpusV2/AgentMugen.bend), the tool ana's loop calls in the
# mugen shape, on a hand-made Bend unit: given each rendered session up to a
# call's `## echo` line, its read, edit and grep answer what the renderer
# wrote after it (the check and `bend base` run Bend: tools/corpus-v2/mugen/agent-mugen-law.py held
# them to gen5's sessions on 2026-11-03: 31 calls of 6 sessions, then 266
# calls of 60, all the same); mugen's refusals; the asks' parsing; when a file is done;
# that the loop calls on `## echo`.
# Prints `ok ...` per check, or `MISMATCH ...`.

def ck(s: String, o: String) -> List<&2, U32>:
  U.concat([U.b(s), [31], U.b(o)])

# own:demo/Two.bend#twice@6: the head defines `one`, which the body uses
def two() -> List<&2, List<&2, U32>>:
  [U.b("bend"), U.b("type"), U.b("twice"), U.b("n twice, plus one."), U.b("def twice(n: Nat) -> Nat:"), U.b("import Base\n\ndef one() -> Nat:\n  1n\n\n# n twice, plus one.\n"),
   U.b("def twice(n: Nat) -> Nat:\n"), U.b("  Nat.add(Nat.add(n, n), one())\n"), Nil{}, U.b("Nat.add n one"), U.b("  ?goal\n"),
   ck("0", "ALL PROOFS CHECK\n"), U.b("def Nat.add(a: Nat, b: Nat) -> Nat"),
   ck("1", "SOME PROOFS FAIL\nError:\n- expected : Nat\n- observed : ?goal\n"), Nil{},
   U.b("  Nat.add(Nat.add(n, m), one())\n"), ck("1", "SOME PROOFS FAIL\nError:\n- expected : a defined name\n- observed : m\n")]

def base() -> Map<&2, List<&2, U32>>:
  T.Mgc.base(T.mg.cfg(U.b("Nat.add\tdef Nat.add(a: Nat, b: Nat) -> Nat:\n"), "/dev/null"))

def path() -> List<&2, U32>:
  T.mg.path(U.b("own:demo/Two.bend#twice@6"))

def task(+shape: String) -> M.AmT:
  M.am.task.of(M.am.task.bytes(U.b("own:demo/Two.bend#twice@6"), "/nowhere", U.b(shape), T.mg.join(two(), [30])))

# the tool's pure answer to a call (read, edit, grep), the file the earlier
# calls left; none for the others (they run Bend)
def pure(+t: M.AmT, +cs: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>>:
  +x = M.am.last.or(cs)
  +f = M.am.replay(M.am.init(cs), t, M.am.f0(t))
  +lb = M.am.label(x)
  +body = M.am.body(x)
  +grep = Bool.and(U.eq(lb, U.b("shell")), U.prefix(body, U.b("grep ")))
  Bool.pick(Maybe<&2, List<&2, U32>>, U.eq(lb, U.b("read")), Some{M.AmO.echo(M.am.read(t, f, body))},
    Bool.pick(Maybe<&2, List<&2, U32>>, U.eq(lb, U.b("edit")), Some{M.AmO.echo(M.am.edit.echo(t, f, body))},
      Bool.pick(Maybe<&2, List<&2, U32>>, grep, Some{M.AmO.echo(M.am.grep(t, f, body))}, None{})))

def same(m: Maybe<&2, List<&2, U32>>, +echo: List<&2, U32>) -> Nat & Nat:
  match m:
    case Some{e}:
      (1n, Bool.pick(Nat, U.eq(A.ag.after1(10, T.mg.echo(e)), A.ag.after1(10, echo)), 1n, 0n))
    case None{}:
      (0n, 0n)

def add(p: Nat & Nat, q: Nat & Nat) -> Nat & Nat:
  (a, b) = p
  (c, d) = q
  (Nat.add(a, c), Nat.add(b, d))

# every call answered as the session's own echo: (pure calls, the same)
def walk(bs: List<&2, A.Blk>, +t: M.AmT, +cs: List<&2, List<&2, U32>>) -> Nat & Nat:
  match bs:
    case A.Blk{+c, +x} <> A.Blk{+d, +y} <> +more:
      +cs2 = List.append(&2, List<&2, U32>, cs, [x])
      Bool.pick(Nat & Nat, Bool.and(A.ag.is.call(c), Nat.is_eq(d, 7n)), add(same(pure(t, cs2), y), walk(more, t, cs2)), walk(A.Blk{d, y} <> more, t, cs))
    case _:
      (0n, 0n)

def echoes.nk(+name: String, +want: Nat, +n: Nat, +k: Nat) -> String:
  Bool.pick(String, Bool.and(Nat.is_eq(n, want), Nat.is_eq(k, n)), "ok echoes " ++ name, "MISMATCH echoes " ++ name ++ " (" ++ Nat.show(k) ++ " of " ++ Nat.show(n) ++ ")")

def echoes.of(+name: String, +want: Nat, p: Nat & Nat) -> String:
  (n, k) = p
  echoes.nk(name, want, n, k)

def echoes(+name: String, +shape: String, +text: List<&2, U32>, +want: Nat) -> String:
  echoes.of(name, want, walk(A.ag.blocks(10, A.ag.hds.bytes(), text), task(shape), Nil{}))

# mugen's refusals: no such file, old not there, old twice
def refuse() -> String:
  +t = task("direct")
  +f = M.am.f0(t)
  +a = M.AmO.echo(M.am.read(t, f, U.b("demo/One.bend 1 3")))
  +b = M.AmE.why(M.am.edit(t, f, U.b("demo/Two.bend\n-  2n\n+  3n")))
  +c = M.AmE.why(M.am.edit(t, U.append(f, f), U.b("demo/Two.bend\n-  1n\n+  2n")))
  +d = M.AmE.f(M.am.edit(t, f, U.b("demo/Two.bend\n-  1n\n+  2n")))
  +ok = Bool.and(Bool.and(U.eq(a, U.b("ENOENT: no such file or directory, open 'demo/One.bend'")), U.eq(b, U.b("Edit 1 (demo/Two.bend): old was not found. No file was changed."))),
    Bool.and(U.eq(c, U.b("Edit 1 (demo/Two.bend): old matches more than once; give more context, or all. No file was changed.")), U.infix(d, U.b("def one() -> Nat:\n  2n\n"))))
  Bool.pick(String, ok, "ok refuse", "MISMATCH refuse")

# the live tool's other languages: the calls the sessions make, as argv; the
# paths and commands it refuses (run for real by hand, 2026-11-03)
def bs(xs: List<String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      U.b(x) <> bs(t)

def argv.is(+cmd: String, want: List<String>) -> Bool:
  U.eq(T.mg.join(M.am.live.argv(U.b(cmd)), [0]), T.mg.join(bs(want), [0]))

def live() -> String:
  +ok = Bool.and(Bool.and(argv.is("ghc -fno-code -w a/B.hs", ["ghc", "-fno-code", "-w", "a/B.hs"]), argv.is("agda a/B.agda", ["agda", "a/B.agda"])),
    Bool.and(Bool.and(argv.is("lake env lean a/B.lean", ["lake", "env", "lean", "a/B.lean"]), argv.is("nix-instantiate --eval --strict a.nix", ["nix-instantiate", "--eval", "--strict", "a.nix"])),
      Bool.and(argv.is("ana-goal a/B.agda", ["ana-goal", "a/B.agda"]), argv.is("ana-type a/B.hs f '<$>' \"a'\"", ["ana-type", "a/B.hs", "f", "<$>", "a'"]))))
  +no = Bool.and(Bool.and(argv.is("agda /etc/passwd", []), argv.is("ana-goal ../B.agda", [])),
    Bool.and(Bool.and(argv.is("ana-type /x f", []), argv.is("rm -rf a", [])),
      Bool.and(argv.is("agda a b", []), argv.is("ana-type a.hs f\n:!rm a", []))))
  Bool.pick(String, Bool.and(ok, no), "ok live", "MISMATCH live")

# the names a bend base command asks for, both forms the renderer writes
def names() -> String:
  +a = M.am.base.names(U.b("bend base Nat.add | head -1"))
  +b = M.am.base.names(U.b("for n in Nat.add List.map; do bend base $n | head -1; done"))
  +ok = Bool.and(U.eq(T.mg.join(a, [32]), U.b("Nat.add")), U.eq(T.mg.join(b, [32]), U.b("Nat.add List.map")))
  Bool.pick(String, ok, "ok names", "MISMATCH names")

# done: the head and the declaration, then a body (the head alone, or the
# declaration without a body, is not)
def done() -> String:
  +t = task("direct")
  +fs = two()
  +ok = Bool.and(Bool.and(M.am.done(t, T.mg.with(fs, U.b("  one()\n"))), Bool.not(M.am.done(t, T.mg.head(fs)))),
    Bool.not(M.am.done(t, T.mg.with(fs, Nil{}))))
  Bool.pick(String, ok, "ok done", "MISMATCH done")

# the reference session: the ask, the edit to the unit's body, the check's call
def ref() -> String:
  +r = M.am.ref(task("repair-0"))
  +ok = Bool.and(U.prefix(r, U.b("## user\n\n`twice` in demo/Two.bend fails bend check. Fix it.")),
    Bool.and(U.infix(r, U.b("## edit\n\ndemo/Two.bend\n-  Nat.add(Nat.add(n, m), one())\n+  Nat.add(Nat.add(n, n), one())\n\n")), U.suffix(r, U.b("## shell\n\nbend demo/Two.bend --check-only\n\n## echo\n"))))
  Bool.pick(String, ok, "ok ref", "MISMATCH ref")

# the loop calls on `## echo` after an empty line (the tool's name `echo`),
# as on a format-2 tool's heading; not on ana's own call headings
def call() -> String:
  +hs = A.ag.hds.bytes()
  +a = Lp.al.call.at(hs, Lp.AlLine{List.reverse(&2, U32, U.b("## echo")), True{}})
  +b = Lp.al.call.at(hs, Lp.AlLine{List.reverse(&2, U32, U.b("## bend")), True{}})
  +c = Lp.al.call.at(hs, Lp.AlLine{List.reverse(&2, U32, U.b("## read")), True{}})
  +d = Lp.al.call.at(hs, Lp.AlLine{List.reverse(&2, U32, U.b("## echo")), False{}})
  +ok = Bool.and(Bool.and(U.eq(a, U.b("echo")), U.eq(b, U.b("bend"))), Bool.and(T.empty(c), T.empty(d)))
  Bool.pick(String, ok, "ok call", "MISMATCH call")

# /ana's bare task is mugen's `## user` turn when the wrapper says so, the bytes
# the sessions and the eval's prompts open with; any other prompt stays whole
def ask() -> String:
  +a = U.eq(U.b(Lp.al.ask("mugen", "Fix `f`.")), T.mg.user(U.b("Fix `f`.")))
  +b = U.eq(U.b(Lp.al.ask("", "## user\n\nFix `f`.\n\n")), T.mg.user(U.b("Fix `f`.")))
  Bool.pick(String, Bool.and(a, b), "ok ask", "MISMATCH ask")

# a tool's output past 30,000: its first 15,000, the number cut, its last 14,936; no
# character split at either cut (mugen's clip)
def rep(n: Nat, +xs: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      U.append(xs, rep(k, xs))

def clip() -> String:
  +whole = rep(30000n, U.b("a"))
  +big = U.append(rep(15000n, U.b("h")), U.append(rep(100n, U.b("m")), rep(14936n, U.b("t"))))
  +want = U.append(rep(15000n, U.b("h")), U.append(U.b("\n[... 100 characters cut ...]\n"), rep(14936n, U.b("t"))))
  # a 2-byte character across each cut: gone whole, nothing left of it
  +two = U.append(rep(14999n, U.b("h")), U.append([195, 169], U.append(rep(100n, U.b("m")), U.append([195, 169], rep(14935n, U.b("t"))))))
  +want2 = U.append(rep(14999n, U.b("h")), U.append(U.b("\n[... 102 characters cut ...]\n"), rep(14935n, U.b("t"))))
  +ok = Bool.and(Bool.and(U.eq(M.am.clip(whole), whole), U.eq(M.am.clip(big), want)), U.eq(M.am.clip(two), want2))
  Bool.pick(String, ok, "ok clip", "MISMATCH clip")

# The harness fixes of 11-11.  A closing fence after a one-line command is
# dropped; the first call made for her is the one her sessions open with,
# for each shape; the repetition cut sees a short run repeated and nothing
# in a run of distinct tokens.
def upto(n: Nat) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+(+k):
      U32.from_nat(k) <> upto(k)

def fixes() -> String:
  +fence = U.eq(M.am.body(U.b("## shell\n\nana-type src/Sort.hs mergeSortSort\n\n```\n")), U.b("ana-type src/Sort.hs mergeSortSort"))
  +plain = U.eq(M.am.body(U.b("## shell\n\nbend x.bend --check-only\n\n")), U.b("bend x.bend --check-only"))
  +d = U.prefix(T.mg.direct(two(), path(), base()), U.append(M.am.prompt(task("direct")), M.am.first(task("direct"))))
  +f = U.prefix(T.mg.fill(two(), path(), base()), U.append(M.am.prompt(task("fill")), M.am.first(task("fill"))))
  +r = U.prefix(T.mg.repair(two(), path(), base(), 0n), U.append(M.am.prompt(task("repair-0")), M.am.first(task("repair-0"))))
  +loop = Lp.al.rep.any(16n, rep(40n, [7, 8, 9]), 96n)
  +distinct = Bool.not(Lp.al.rep.any(16n, upto(96n), 96n))
  +ok = Bool.and(Bool.and(Bool.and(fence, plain), Bool.and(d, f)), Bool.and(r, Bool.and(loop, distinct)))
  Bool.pick(String, ok, "ok fixes", "MISMATCH fixes")

# The stricter score's pure parts: a def's head read; a type's inputs; the
# unit's own calls renamed (not another name's, not a field's); the tests
# appended for two()'s `twice`; no proof there
def score.decl(d: M.AmD) -> Bool:
  match d:
    case M.AmD{+n, +tys, +ret, +ok}:
      Bool.and(Bool.and(ok, U.eq(n, U.b("nonzero"))), Bool.and(Bool.and(U.eq(U.nth(tys, 0n), U.b("List<&2, U32>")), U.eq(U.nth(tys, 1n), U.b("Bool"))),
        Bool.and(Nat.is_eq(List.length(&2, List<&2, U32>, tys), 2n), U.eq(ret, U.b("Maybe<&2, List<&2, U32>>")))))

def score() -> String:
  +dl = score.decl(M.am.sc.decl(U.b("def nonzero(ss: List<&2, U32>, z: Bool) -> Maybe<&2, List<&2, U32>>:\n")))
  +vs = U.eq(T.mg.join(M.am.sc.vals(4n, M.am.sc.kind(U.b("List<&2, U32>"))), [10]), U.b("[]\n[1]\n[1, 4294967295]\n[4294967295, 1, 4294967295]"))
  +ps = U.eq(T.mg.join(M.am.sc.vals(4n, M.am.sc.kind(U.b("Result<&1, &1, U32 & String, Bool>"))), [10]), U.b("Done{True{}}\nDone{False{}}\nFail{(0, \"\")}"))
  +ren = U.eq(M.am.sc.ren(U.b("  go(a, x.go(b), go4(c), go (d))\n"), U.b("go")), U.b("  go.orig_(a, x.go(b), go4(c), go (d))\n"))
  +plan = M.am.sc.plan(two())
  +p0 = U.prefix(plan, U.b("\ndef twice.orig_(n: Nat) -> Nat:\n  Nat.add(Nat.add(n, n), one())\n\ndef twice.t0_() -> {twice(0n) == twice.orig_(0n) : Nat}:\n  {==}\n\n"))
  +p3 = U.infix(plan, U.b("def twice.t3_() -> {twice(5n) == twice.orig_(5n) : Nat}:"))
  +ok = Bool.and(Bool.and(Bool.and(dl, vs), Bool.and(ps, ren)), Bool.and(Bool.and(p0, p3), Bool.not(M.am.sc.proof(two()))))
  Bool.pick(String, ok, "ok score", "MISMATCH score")

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(fixes())
    IO.print(score())
    IO.print(ask())
    IO.print(clip())
    IO.print(echoes("direct", "direct", T.mg.direct(two(), path(), base()), 3n))
    IO.print(echoes("fill", "fill", T.mg.fill(two(), path(), base()), 2n))
    IO.print(echoes("repair", "repair-0", T.mg.repair(two(), path(), base(), 0n), 3n))
    IO.print(refuse())
    IO.print(names())
    IO.print(done())
    IO.print(ref())
    IO.print(call())
    IO.print(live())
