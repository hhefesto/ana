import Base
import ../Sys.bend as S
import ./Spec.bend as A

# bend-agent-tool: the tools ana's loop calls (bend/Agent/Loop.bend).
#
#   bend-agent-tool snippet TOOL   < EPISODE
#
# The episode so far comes on standard input; its last turn is ana's call
# (`## TOOL`).  `snippet` checks ana's answer alone: the code of its Type
# turn (when there is one) and of its answer (the episode's act turn, read
# with Agent/Spec.bend's reader), in one file, Unit.<ext>, under the
# language's checker:
#
#   ghc   ghc -fno-code -w (run/check-cache/ghc-harness's ghc, or $GHC)
#   lean  lean (with $LEAN_PATH when set)
#   agda  agda
#   bend  bend --check-only
#   nix   nix-instantiate --eval --strict (NIX_PATH empty)
#
# Standard output is the echo: the rest of the tool's turn after its
# heading line, rendered by Agent/Spec.bend's `ag.echo` (40 lines, then
# `[N more lines]`, then `[exit N]`), which bend-agent-laws holds to
# Transcript.bend's `checker` on every check of the corpus: ana reads the
# tool in the layout it was trained on.  The exit status is 0 when the check passed, 1 when it
# failed, 2 when the tool could not run.

def at.nl(+xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, U32, xs), 0n), Nil{}, List.append(&2, U32, xs, [10]))

# the file: the given Type's code, then the answer's (a Lean answer to a
# Type is its proof: `:=` between them, unless the answer opens with it)
def at.file(+tool: String, +e: List<&2, A.Turn>) -> List<&2, U32>:
  +ty = A.ag.type.code(e)
  +te = A.ag.answer.code(e)
  +lean = Bool.and(String.eq(tool, "lean"), Bool.not(Nat.is_eq(List.length(&2, U32, ty), 0n)))
  +join = Bool.pick(List<&2, U32>, Bool.and(lean, Bool.not(A.ag.prefix(te, A.ag.ascii(":=")))), A.ag.ascii(" :=\n"), [10])
  +hs = Bool.pick(List<&2, U32>, String.eq(tool, "ghc"), A.ag.ascii("module Unit where\n\n"), Nil{})
  List.append(&2, U32, hs, List.append(&2, U32, ty, List.append(&2, U32, Bool.pick(List<&2, U32>, Nat.is_eq(List.length(&2, U32, ty), 0n), Nil{}, join), at.nl(te))))

def at.ext(+tool: String) -> String:
  Bool.pick(String, String.eq(tool, "ghc"), "hs", Bool.pick(String, String.eq(tool, "lean"), "lean",
    Bool.pick(String, String.eq(tool, "agda"), "agda", Bool.pick(String, String.eq(tool, "bend"), "bend", "nix"))))

def at.known(+tool: String) -> Bool:
  Bool.or(Bool.or(String.eq(tool, "ghc"), String.eq(tool, "lean")), Bool.or(Bool.or(String.eq(tool, "agda"), String.eq(tool, "bend")), String.eq(tool, "nix")))

def at.argv(+tool: String) -> List<String>:
  Bool.pick(List<String>, String.eq(tool, "ghc"), ["-fno-code", "-w", "-fdiagnostics-color=never", "-fno-show-valid-hole-fits", "Unit.hs"],
    Bool.pick(List<String>, String.eq(tool, "bend"), ["Unit.bend", "--check-only"],
      Bool.pick(List<String>, String.eq(tool, "nix"), ["--eval", "--strict", "Unit.nix"], ["Unit." ++ at.ext(tool)])))

def at.prog(+tool: String, +ghc: String) -> String:
  Bool.pick(String, String.eq(tool, "ghc"), ghc, Bool.pick(String, String.eq(tool, "nix"), "nix-instantiate", tool))

def at.env(+tool: String, +lp: String) -> List<String>:
  Bool.pick(List<String>, String.eq(tool, "nix"), ["NIX_PATH="],
    Bool.pick(List<String>, Bool.and(String.eq(tool, "lean"), Bool.not(String.is_empty(lp))), ["LEAN_PATH=" ++ lp], []))

# the echo: the checker's turn after its heading line
def at.echo(+tool: String, +dir: String, +o: S.Out) -> List<&2, U32>:
  A.ag.echo(List.append(&2, U32, S.b(U32.show(S.Out.status(o))), 31 <> S.clean(dir, 100n, S.Out.text(o))))

# exit 0 when the check passed; else 1 (IO.die flushes the echo first)
def at.done(ok: Bool, +tool: String, +st: U32) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "agent-tool: " ++ tool ++ " exited " ++ U32.show(st))

def at.snippet(+tool: String, m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match m:
    case None{}:
      IO.die(Unit, 2, "agent-tool: cannot read the episode on standard input")
    case Some{+xs}:
      +e = A.ag.read.bytes(xs)
      do IO<Unit>:
        +root0 : String <- S.env("PWD", ".")
        +ghc : String <- S.env("GHC", root0 ++ "/run/check-cache/ghc-harness/bin/ghc")
        +lp : String <- S.env("LEAN_PATH", "")
        +dir : String <- S.mktemp()
        S.write(dir ++ "/Unit." ++ at.ext(tool), at.file(tool, e))
        +o : S.Out <- S.run(dir, at.env(tool, lp), 120, at.prog(tool, ghc), at.argv(tool), Nil{})
        S.rm(dir)
        IO.write(S.str(at.echo(tool, dir, o)))
        at.done(U32.is_eq(S.Out.status(o), 0), tool, S.Out.status(o))

def at.run(ok: Bool, +tool: String) -> IO(Unit):
  match ok:
    case True{}:
      do IO<Unit>:
        m : Maybe<&2, List<&2, U32>> <- S.slurp("/dev/stdin")
        at.snippet(tool, m)
    case False{}:
      IO.die(Unit, 2, "agent-tool: no tool " ++ tool ++ " (ghc, lean, agda, bend, nix)")

def at.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "snippet" <> +tool <> Nil{}:
      at.run(at.known(tool), tool)
    case _:
      IO.die(Unit, 2, "usage: bend-agent-tool snippet TOOL < EPISODE")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    at.args(List.tail(&1, String, argv))
