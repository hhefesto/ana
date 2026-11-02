import Base
import ../Units.bend as U
import ../Transcript.bend as T
import ../Sys.bend as S

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

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(direct())
    IO.print(repair())
    IO.print(turns("direct", T.mg.direct(two(), path(), base()), "## user\n## read\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(turns("fill", T.mg.fill(two(), path(), base()), "## user\n## shell\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(turns("repair", T.mg.repair(two(), path(), base(), 0n), "## user\n## shell\n## echo\n## read\n## echo\n## shell\n## echo\n## edit\n## echo\n## shell\n## echo\n## mugen\n"))
    IO.print(count())
