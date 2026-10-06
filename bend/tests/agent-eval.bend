import Base
import ../Agent/Spec.bend as A
import ../CorpusV2/Agent.bend as Ag

# E5's reading of ana's output (CorpusV2/Agent.bend): ana's stdout is the
# episode then agent.fin's closing newline, and Ag.ea.text takes it to the
# transcript Spec's ag.solved reads. A passing last echo is solved, read
# that way and only that way; a failing echo and a call the quota stopped
# are not; the calls are the echoes holding an answer. Every def is
# prefixed `te.`.

def te.head() -> String:
  "=== ana: step 61000 of 63125 (96.634% of its plan) ===\n## User\n\nDefine `nest`.\n\n## Term\n\n```haskell\nnest = runCont . sequence . map cont\n```\n\n## ghc\n"

# ana's stdout for an episode whose one call passed (E5 2026-10-06, episode 1)
def te.pass() -> List<&2, U32>:
  A.ag.ascii(te.head() ++ "\n```\n[3 of 3] Compiling Unit             ( Unit.hs, nothing )\n[exit 0]\n```\n\n\n")

def te.fail() -> List<&2, U32>:
  A.ag.ascii(te.head() ++ "\n```\nUnit.hs:31:14: error: [GHC-83865]\n[exit 1]\n```\n\n## Term\n\n```haskell\nnest = undefined\n```\n\n## ghc\n\n")

def te.solved(+x: List<&2, U32>) -> Bool:
  A.ag.solved(A.ag.read.bytes(Ag.ea.text(x)))

def te.line(ok: Bool, +name: String) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(te.line(te.solved(te.pass()), "a passing last echo is solved"))
    IO.print(te.line(Bool.not(A.ag.solved(A.ag.read.bytes(te.pass()))), "read with the closing newline it is not (the bug)"))
    IO.print(te.line(Bool.not(te.solved(te.fail())), "a failing echo then a stopped call is not"))
    IO.print(te.line(Nat.is_eq(Ag.ea.answered(A.ag.read.bytes(Ag.ea.text(te.pass()))), 1n), "one call answered"))
    IO.print(te.line(Nat.is_eq(Ag.ea.answered(A.ag.read.bytes(Ag.ea.text(te.fail()))), 1n), "one answered, the stopped one not"))
