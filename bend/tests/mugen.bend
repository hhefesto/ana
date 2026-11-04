import Base
import ../Units.bend as U
import ../Transcript.bend as T
import ../Sys.bend as S
import ../Nul.bend as Ns
import ../Agent/Spec.bend as A

# bend-transcript's format mugen (docs/MUGEN-SHAPE.md) on a hand-made Bend
# unit: the direct session byte for byte (every echo as mugen's read, edit
# and shell answer), the repair's edit, diff and reply, each shape's turns in
# order, and the edit's count of old (apart, as mugen's edit splits on it).
# Prints `ok ...` per check, or `MISMATCH ...`.

def ck(s: String, o: String) -> List<&2, U32>:
  U.concat([U.b(s), [31], U.b(o)])

# own:demo/Two.bend#twice@4 (bend/Check/Lib.bend's RESULTS.nul fields): the
# head ends in the def's doc, one mutant
def two() -> List<&2, List<&2, U32>>:
  [U.b("bend"), U.b("type"), U.b("twice"), U.b("n twice."), U.b("def twice(n: Nat) -> Nat:"), U.b("import Base\n\n# n twice.\n"),
   U.b("def twice(n: Nat) -> Nat:\n"), U.b("  Nat.add(n, n)\n"), Nil{}, U.b("Nat.add n"), U.b("  ?goal\n"),
   ck("0", "ALL PROOFS CHECK\n"), U.b("def Nat.add(a: Nat, b: Nat) -> Nat"),
   ck("1", "SOME PROOFS FAIL\nError:\n- expected : Nat\n- observed : ?goal\nContext:\n- n : Nat\nLocation: twice\n4 | def twice(n: Nat) -> Nat:\n5>|   ?goal\n"), Nil{},
   U.b("  Nat.add(n, m)\n"), ck("1", "SOME PROOFS FAIL\nError:\n- expected : a defined name\n- observed : m\nLocation: twice\n5>|   Nat.add(n, m)\n")]

# the same unit with a second mutant (a chain's second wrong edit)
def two2() -> List<&2, List<&2, U32>>:
  List.append(&2, List<&2, U32>, two(), [U.b("  Nat.add(n, k)\n"), ck("1", "SOME PROOFS FAIL\nError:\n- expected : a defined name\n- observed : k\nLocation: twice\n5>|   Nat.add(n, k)\n")])

def base() -> Map<&2, List<&2, U32>>:
  T.Mgc.base(T.mg.cfg(U.b("Nat.add\tdef Nat.add(a: Nat, b: Nat) -> Nat:\nn\tbend: Base has no n (see bend --help)\n"), "/dev/null"))

def path() -> List<&2, U32>:
  T.mg.path(U.b("own:demo/Two.bend#twice@4"))

def labels(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      U.append(Bool.pick(List<&2, U32>, U.prefix(l, U.b("## ")), l, Nil{}), labels(more))

def has(+text: List<&2, U32>, +part: String) -> Bool:
  U.infix(text, U.b(part))

def direct() -> String:
  Bool.pick(String, U.eq(T.mg.direct(two(), path(), base()), U.b("## user\n\nAdd `twice` to demo/Two.bend.\n\nn twice.\n\n```bend\ndef twice(n: Nat) -> Nat:\n```\n\n## read\n\ndemo/Two.bend 1 3\n\n## echo\n\n```\nimport Base\n\n# n twice.\n[lines 1-3 of 3]\n```\n\n## shell\n\nbend base Nat.add | head -1\n\n## echo\n\n```\ndef Nat.add(a: Nat, b: Nat) -> Nat:\n(exit 0)\n```\n\n## edit\n\ndemo/Two.bend\n-# n twice.\n+# n twice.\n+def twice(n: Nat) -> Nat:\n+  Nat.add(n, n)\n\n## echo\n\n```\n--- demo/Two.bend\n+++ demo/Two.bend\n@@ -1,3 +1,5 @@\n import Base\n \n # n twice.\n+def twice(n: Nat) -> Nat:\n+  Nat.add(n, n)\n```\n\n## shell\n\nbend demo/Two.bend --check-only\n\n## echo\n\n```\nALL PROOFS CHECK\n(exit 0)\n```\n\n## mugen\n\nAdded `twice` to demo/Two.bend; bend check passes.\n\n")), "ok direct", "MISMATCH direct")

def repair() -> String:
  +t = T.mg.repair(two(), path(), base(), 0n)
  +ok = Bool.and(Bool.and(has(t, "## read\n\ndemo/Two.bend 4 2\n\n## echo\n\n```\ndef twice(n: Nat) -> Nat:\n  Nat.add(n, m)\n[lines 4-5 of 5]\n```\n"),
      has(t, "## edit\n\ndemo/Two.bend\n-  Nat.add(n, m)\n+  Nat.add(n, n)\n\n")),
    Bool.and(has(t, "```\n--- demo/Two.bend\n+++ demo/Two.bend\n@@ -2,4 +2,4 @@\n \n # n twice.\n def twice(n: Nat) -> Nat:\n-  Nat.add(n, m)\n+  Nat.add(n, n)\n```\n"),
      has(t, "## mugen\n\nFixed `twice` in demo/Two.bend: bend check said expected a defined name, observed m at line 5. It passes now.\n")))
  Bool.pick(String, ok, "ok repair", "MISMATCH repair")

def turns(+name: String, +t: List<&2, U32>, +want: String) -> String:
  Bool.pick(String, U.eq(labels(U.lines(t)), U.b(want)), "ok turns " ++ name, "MISMATCH turns " ++ name)

# old's count in xs, apart: aaa holds aa once
def count() -> String:
  +ok = Bool.and(Bool.and(Nat.is_eq(T.mg.count(U.b("aaa"), U.b("aa")), 1n), Nat.is_eq(T.mg.count(U.b("abab"), U.b("ab")), 2n)),
    Bool.and(Nat.is_eq(T.mg.count(U.b("xyz"), U.b("q")), 0n), Nat.is_eq(T.mg.count(U.b("  acc\n    acc\n"), U.b("  acc\n")), 2n)))
  Bool.pick(String, ok, "ok count", "MISMATCH count")

# MUGEN_ONLY: "" keeps every shape, `repair` the repair-M ones (by the id's
# last segment, not a path's)
def only() -> String:
  +ds = {[Ns.Doc{U.b("own:a/mugen-repair/X.bend#f@1/mugen-direct"), U.b("d")}, Ns.Doc{U.b("own:a/X.bend#f@1/mugen-repair-0"), U.b("r0")},
    Ns.Doc{U.b("own:a/X.bend#f@1/mugen-fill"), U.b("f")}, Ns.Doc{U.b("own:a/X.bend#f@1/mugen-repair-1"), U.b("r1")}] : List<&2, Ns.Doc>}
  +ok = Bool.and(Nat.is_eq(List.length(&2, Ns.Doc, T.mg.docs.only("", ds)), 4n),
    Bool.and(Nat.is_eq(List.length(&2, Ns.Doc, T.mg.docs.only("repair", ds)), 2n),
      Bool.and(T.mg.only.ok("repair", U.b("own:a/X.bend#f@1/mugen-repair-0")), Bool.not(T.mg.only.ok("repair", U.b("own:a/mugen-repair/X.bend#f@1/mugen-direct"))))))
  Bool.pick(String, ok, "ok only", "MISMATCH only")

# another language's unit (2026-11-03): its checker's command and output, Unit.EXT as
# the file's path, the look-ups one `ana-type`, the reply naming the checker
def hs() -> List<&2, List<&2, U32>>:
  [U.b("haskell"), U.b("type"), U.b("twice"), Nil{}, U.b("twice :: Int -> Int"), U.b("module Two where\n\n"),
   U.b("twice :: Int -> Int\n"), U.b("twice n = n + n\n"), Nil{}, U.b("n <$> f'"), U.b("twice n = _\n"),
   ck("0", "[1 of 1] Compiling Unit ( Unit.hs, nothing )\n"), U.b("(<$>) :: Int\n"),
   ck("-", "Unit.hs:4:11: error: [GHC-88464]\n    Found hole: _ :: Int\n"), ck("-", ""),
   U.b("twice n = n + m\n"), ck("-", "Unit.hs:4:15: error: [GHC-88464]\n    Variable not in scope: m\n/home/hhefesto/src/formalTransformer/run/code-sources/a\n")]

def hs.path() -> List<&2, U32>:
  T.mg.path(U.b("own:demo/Two.hs#twice@3"))

def other() -> String:
  +r = T.mg.repair(hs(), hs.path(), base(), 0n)
  +d = T.mg.direct(hs(), hs.path(), base())
  +f = T.mg.fill(hs(), hs.path(), base())
  +ok = Bool.and(Bool.and(has(r, "## shell\n\nghc -fno-code -w demo/Two.hs\n\n## echo\n\n```\ndemo/Two.hs:4:15: error: [GHC-88464]\n    Variable not in scope: m\ncode-sources/a\n(exit 1)\n```\n"),
      has(r, "## mugen\n\nFixed `twice` in demo/Two.hs: ghc said [GHC-88464] at line 4. It passes now.\n")),
    Bool.and(Bool.and(has(d, "```haskell\ntwice :: Int -> Int\n```"), has(d, "## shell\n\nana-type demo/Two.hs n '<$>' \"f'\"\n\n## echo\n\n```\n(<$>) :: Int\n(exit 0)\n```")),
      Bool.and(has(d, "## mugen\n\nAdded `twice` to demo/Two.hs; ghc passes.\n"), has(f, "Fill the hole (`_`) in `twice` in demo/Two.hs."))))
  Bool.pick(String, ok, "ok other", "MISMATCH other")

def ok.if(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok " ++ name, "MISMATCH " ++ name)

# a chain's second edit edits what the first left, the wrong edit's check is
# its mutant's recorded check, and the session ends in the pass and the reply
def chain.bytes() -> String:
  +t = T.mg.direct.j(two(), path(), base(), 1n, 0n, 1n)
  +ok = Bool.and(Bool.and(has(t, "+  Nat.add(n, m)\n\n## echo\n"), has(t, "## edit\n\ndemo/Two.bend\n-  Nat.add(n, m)\n+  Nat.add(n, n)\n\n")),
    Bool.and(has(t, "- observed : m\n"), has(t, "ALL PROOFS CHECK\n(exit 0)\n```\n\n## mugen\n\nAdded `twice` to demo/Two.bend; bend check passes.\n")))
  ok.if("chain's edits and checks", ok)

# a night's transcript, her Term twice, then the fix: the repeat left out, her
# Terms back under the def's indent, the checks as recorded
def night.text() -> List<&2, U32>:
  U.b("## User\n\nn twice.\n\n## Type\n\ntype\n```bend\ndef twice(n: Nat) -> Nat:\n```\n\n## Term\n\n```bend\nNat.add(n, m)\n```\n\n## bend\n\n```\nSOME PROOFS FAIL\n[exit 1]\n```\n\n## Term\n\n```bend\nNat.add(n, m)\n```\n\n## bend\n\n```\nSOME PROOFS FAIL\n[exit 1]\n```\n\n## Term\n\n```bend\nmatch n:\n  case 0n:\n\n    0n\n```\n\n## bend\n\n```\nALL PROOFS CHECK\n[exit 0]\n```\n\n")

def night() -> String:
  +ns = T.nt.uniq(T.nt.of(A.ag.blocks(10, A.ag.hds.bytes(), night.text())), Nil{})
  +t = T.nt.session(two(), path(), base(), ns)
  +ok = Bool.and(Bool.and(Nat.is_eq(List.length(&2, T.Nt, ns), 2n), T.nt.last.passed(ns)),
    Bool.and(has(t, "+  Nat.add(n, m)\n\n## echo\n"), Bool.and(has(t, "```\nSOME PROOFS FAIL\n(exit 1)\n```\n"),
      Bool.and(has(t, "+  match n:\n+    case 0n:\n+\n+      0n\n"), has(t, "```\nALL PROOFS CHECK\n(exit 0)\n```\n\n## mugen\n")))))
  ok.if("night", ok)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(other())
    IO.print(direct())
    IO.print(repair())
    IO.print(turns("direct", T.mg.direct(two(), path(), base()), "## user\n## read\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(turns("fill", T.mg.fill(two(), path(), base()), "## user\n## shell\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(turns("chain, direct", T.mg.direct.j(two(), path(), base(), 1n, 0n, 1n), "## user\n## read\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(turns("chain, fill", T.mg.fill.j(two(), path(), base(), 1n, 0n, 1n), "## user\n## shell\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(turns("chain, repair", T.mg.repair.j(two2(), path(), base(), 0n, 1n, 2n), "## user\n## shell\n## echo\n## read\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(ok.if("a chain's tries change the body", Bool.and(T.mg.tries.ok(1n, two2(), Nil{}, 0n, 2n), Bool.not(T.mg.tries.ok(1n, two2(), U.b("  Nat.add(n, m)\n"), 0n, 2n)))))
    IO.print(chain.bytes())
    IO.print(night())
    IO.print(turns("repair", T.mg.repair(two(), path(), base(), 0n), "## user\n## shell\n## echo\n## read\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(count())
    IO.print(only())
