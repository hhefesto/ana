import Base
import ../Units.bend as U
import ../Transcript.bend as T
import ../Sys.bend as S

# bend-transcript's format 2 (docs/CORPUS-V2.md, C1, C2) on hand-made records:
# each shape's turns in order, the direct shape byte for byte, every Term the
# original, the presentations a unit gives (distinct; Nix never direct).
# Prints `ok ...` per check, or `MISMATCH ...`.

# a check: its status, 0x1F, its output
def ck(s: String, o: String) -> List<&2, U32>:
  U.concat([U.b(s), [31], U.b(o)])

# a Haskell unit (bend/Check/Lib.bend's RESULTS.nul fields): 0 lang .. 10 hole,
# 11 the original's check, 12 Context, 13 the hole's, 14 the type, then two
# mutants with their checks
def hs() -> List<&2, List<&2, U32>>:
  [U.b("haskell"), U.b("type"), U.b("twice"), Nil{}, U.b("twice :: Int -> Int"), Nil{}, U.b("twice :: Int -> Int\n"),
   U.b("twice n = n + n\n"), Nil{}, Nil{}, U.b("twice n = _\n"), ck("0", ""), U.b("(+) :: Num a => a -> a -> a"),
   ck("-", "Found hole: _ :: Int"), ck("-", "twice :: Int -> Int"),
   U.b("twice n = n + m\n"), ck("1", "Unit.hs:1:15: error: Variable not in scope: m"),
   U.b("twice n = n n +\n"), ck("1", "Unit.hs:1:17: error: parse error")]

# a Nix unit: a whole file, no Context, no hole, one mutant
def nix() -> List<&2, List<&2, U32>>:
  [U.b("nix"), U.b("file"), U.b("file"), Nil{}, Nil{}, Nil{}, Nil{}, U.b("{ a = 1; }\n"), Nil{}, Nil{}, Nil{},
   ck("0", "{ a = 1; }"), Nil{}, Nil{}, Nil{}, U.b("{ a = = 1; }\n"), ck("1", "error: syntax error")]

# the `## ` lines of a text, joined
def labels(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> more:
      U.append(Bool.pick(List<&2, U32>, U.prefix(l, U.b("## ")), l, Nil{}), labels(more))

def turns(+shape: Nat, +want: String) -> String:
  +got = labels(U.lines(T.render2(shape, hs(), 0n)))
  Bool.pick(String, U.eq(got, U.b(want)), "ok turns " ++ Nat.show(shape), "MISMATCH turns " ++ Nat.show(shape))

def direct() -> String:
  Bool.pick(String, U.eq(T.render2(0n, hs(), 0n), U.b("## User\n\nDefine `twice`.\n\n## Context\n\n```haskell\n(+) :: Num a => a -> a -> a\n```\n\n## Type\n\ntype\n```haskell\ntwice :: Int -> Int\n```\n\n## Term\n\n```haskell\ntwice n = n + n\n```\n\n## ghc\n\n```\n[exit 0]\n```\n\n")), "ok direct", "MISMATCH direct")

# the Term of shapes 0, 1 (each mutant) and 3 is the original
def term.of(+shape: Nat, +m: Nat) -> Bool:
  Nat.is_lt(U.find(T.render2(shape, hs(), m), U.b("## Term\n\n```haskell\ntwice n = n + n\n```"), 0n), U.len(T.render2(shape, hs(), m)))

def terms() -> String:
  Bool.pick(String, Bool.and(Bool.and(term.of(0n, 0n), term.of(1n, 0n)), Bool.and(term.of(1n, 1n), term.of(3n, 0n))), "ok terms", "MISMATCH terms")

def shapes(ps: List<&2, T.Plan>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case T.Plan{s, m} <> more:
      U.append(U.b(Nat.show(s) ++ ":" ++ Nat.show(m) ++ " "), shapes(more))

def has.direct(ps: List<&2, T.Plan>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case T.Plan{+s, m} <> more:
      Bool.or(Nat.is_eq(s, 0n), has.direct(more))

# eight presentations asked of each: the Haskell unit gives seven (direct,
# repair 0 and 1, fill, term to type, verify both ways); the Nix unit three
# (repair, verify both ways), none direct
def copies(+id: String, +fs: List<&2, List<&2, U32>>, +n: Nat, +nodirect: Bool) -> String:
  +ps = T.choose(fs, T.plan2(U.b(id), fs) <> T.more2(U.b(id), fs), Nil{}, 8n)
  +ok = Bool.and(Nat.is_eq(List.length(&2, T.Plan, ps), n), Bool.or(Bool.not(nodirect), Bool.not(has.direct(ps))))
  Bool.pick(String, ok, "ok copies " ++ id, "MISMATCH copies " ++ id ++ " " ++ S.str(shapes(ps)))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(direct())
    IO.print(turns(0n, "## User\n## Context\n## Type\n## Term\n## ghc\n"))
    IO.print(turns(1n, "## User\n## Context\n## Type\n## Attempt\n## ghc\n## Term\n## ghc\n"))
    IO.print(turns(2n, "## User\n## Context\n## Term\n## ghc\n## Type\n## ghc\n"))
    IO.print(turns(3n, "## User\n## Context\n## Type\n## Attempt\n## ghc\n## Term\n## ghc\n"))
    IO.print(turns(4n, "## User\n## Context\n## Type\n## Attempt\n## ghc\n"))
    IO.print(turns(5n, "## User\n## Context\n## Type\n## Attempt\n## ghc\n"))
    IO.print(terms())
    IO.print(copies("repo:x/A.hs#twice@1", hs(), 7n, False{}))
    IO.print(copies("repo:x/a.nix#file@1", nix(), 3n, True{}))
