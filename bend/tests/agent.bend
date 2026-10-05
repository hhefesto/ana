import Base
import ../Agent/Spec.bend as A
import ../Mask.bend as Ms
import ../Tokenizer.bend as Tk
import ../Bytes.bend as B

# The meaning of episodes (Agent/Spec.bend) on the shapes format 2 renders
# (bend/Transcript.bend `render2`): reading gives each turn the role the
# shape means, reading never changes the text, every echo answers a call,
# the weights are 0 exactly on attempts and echoes, and the loop's unfold
# lets only the tool write an echo.  Each line prints `ok NAME` or
# `FAIL NAME`.  The corpus-scale laws (every transcript of run/v2, and the
# token reading against the byte reading) are `bend-agent laws`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

def b(s: String) -> List<&2, U32>:
  A.ag.ascii(s)

def codes(e: List<&2, A.Turn>) -> List<&2, Nat>:
  match e:
    case Nil{}:
      Nil{}
    case A.Turn{r, x} <> t:
      A.ag.role.code(r) <> codes(t)

def nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case a <> s c <> t:
      Bool.and(Nat.is_eq(a, c), nats.eq(s, t))
    case _ _:
      False{}

def sum(xs: List<&2, F32>) -> F32:
  match xs:
    case Nil{}:
      0.0
    case h <> t:
      F32.add(h, sum(t))

# the bytes of the turns of role `code`
def bytes.of(e: List<&2, A.Turn>, +code: Nat) -> Nat:
  match e:
    case Nil{}:
      0n
    case A.Turn{r, x} <> t:
      Nat.add(Bool.pick(Nat, Nat.is_eq(A.ag.role.code(r), code), List.length(&2, U32, x), 0n), bytes.of(t, code))

# Shapes (Transcript.bend `turn`: "## LABEL\n\n" body "\n"; a fence
# "```lang\n" text "\n```\n"; the checker's body "```\n" out "\n[exit N]\n```\n")

def user(+ask: String) -> String:
  "## User\n\n" ++ ask ++ "\n\n"

def context() -> String:
  "## Context\n\n```haskell\nimport Data.List\n```\n\n"

def typ() -> String:
  "## Type\n\ntype\n```haskell\nf :: Int -> Int\n```\n\n"

def fenced(+label: String, +code: String) -> String:
  "## " ++ label ++ "\n\n```haskell\n" ++ code ++ "\n```\n\n"

def ghc(+out: String) -> String:
  "## ghc\n\n```\n" ++ out ++ "```\n\n"

def direct() -> String:
  user("Define `f`.") ++ context() ++ typ() ++ fenced("Term", "f = (+ 1)") ++ ghc("[exit 0]\n")

def repair() -> String:
  user("Define `f`.\n\nThis attempt fails. Fix it.") ++ context() ++ typ() ++ fenced("Attempt", "f = (++ 1)")
    ++ ghc("Unit.hs:3:5: error: No instance for (Num [a0])\n[exit 1]\n") ++ fenced("Term", "f = (+ 1)") ++ ghc("[exit 0]\n")

def to.type() -> String:
  user("Write the type signature of `f`.") ++ context() ++ fenced("Term", "f = (+ 1)")
    ++ ghc("Unit.hs:3:1: warning: Top-level binding with no type signature: f :: Num a => a -> a\n[exit 0]\n")
    ++ typ() ++ ghc("[exit 0]\n")

def verify() -> String:
  user("Does this check?") ++ context() ++ typ() ++ fenced("Attempt", "f = (+ 1)") ++ ghc("[exit 0]\n")

# a Bend term whose code holds a `## Term` line not after an empty line: no turn
def trap() -> String:
  user("Define `g`.") ++ "## Term\n\n```bend\ndef g() -> Nat:\n## Term\n  0n\n```\n\n" ++ "## bend\n\n```\nAll terms check.\n[exit 0]\n```\n\n"

def shape(+name: String, +text: String, +want: List<&2, Nat>) -> String:
  +xs = b(text)
  +e = A.ag.read.bytes(xs)
  verdict(name, Bool.and(nats.eq(codes(e), want), Bool.and(A.ag.law.roundtrip(10, A.ag.hds.bytes(), xs), A.ag.law.calls(e))))

# the weights: one per byte, 0 exactly on the attempt's and the echoes' bytes
def weights(+name: String, +text: String) -> String:
  +xs = b(text)
  +e = A.ag.read.bytes(xs)
  +ws = A.ag.weights(e)
  +n = List.length(&2, U32, xs)
  +on = Nat.sub(n, Nat.add(bytes.of(e, 2n), bytes.of(e, 5n)))
  verdict(name, Bool.and(Nat.is_eq(List.length(&2, F32, ws), n), F32.is_eq(sum(ws), F32.from_nat(on))))

# The loop on a toy: ana answers badly and calls ghc until it has read one
# echo, then answers well; the tool always answers.
def toy.ana(e: List<&2, A.Turn>) -> List<&2, A.Turn>:
  Bool.pick(List<&2, A.Turn>, Nat.is_eq(A.ag.count(e, 5n), 0n),
    [A.Turn{A.RoAct{}, b("bad")}, A.Turn{A.RoCall{}, b("## ghc\n")}],
    [A.Turn{A.RoAct{}, b("good")}])

def toy.tool(e: List<&2, A.Turn>) -> List<&2, U32>:
  b("\n```\nerror\n[exit 1]\n```\n\n")

def unfold() -> String:
  +e = A.ag.unfold(~toy.ana, ~toy.tool, 4n, [A.Turn{A.RoUser{}, b("## User\n\nDo it.\n\n")}])
  verdict("unfold", Bool.and(nats.eq(codes(e), [0n, 3n, 4n, 5n, 3n]), A.ag.law.calls(e)))

# A training window (bend/Mask.bend) under code32k: BOS, filler code, EOS,
# two transcripts each ended by EOS.  The trainer's weights, one per
# target, are 0 on exactly the tokens of the attempt and echo turns (each
# turn encoded alone: no token crosses a turn) and 1 on every other.
def zeros.of(+b: Tk.Bpe, e: List<&2, A.Turn>) -> Nat:
  match e:
    case Nil{}:
      0n
    case A.Turn{+r, +x} <> t:
      +c = A.ag.role.code(r)
      Nat.add(Bool.pick(Nat, Bool.or(Nat.is_eq(c, 2n), Nat.is_eq(c, 5n)), List.length(&2, U32, Tk.Bpe.encode(b, x)), 0n), zeros.of(b, t))

def count.zero(ws: List<&2, F32>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case h <> t:
      Nat.add(Bool.pick(Nat, F32.is_eq(h, 0.0), 1n, 0n), count.zero(t))

def window.test(m: Maybe<&2, Tk.Bpe>) -> String:
  match m:
    case None{}:
      "FAIL window (no tokenizer at weights/code32k.bpe)"
    case Some{+tb}:
      +ids = Ms.ms.ids(tb)
      +fill = Tk.Bpe.encode(tb, b("go :: Int\n## ghc\ngo = 0\n"))
      +w = List.concat(&2, U32, [[0], fill, [1], Tk.Bpe.encode(tb, b(direct())), [1], Tk.Bpe.encode(tb, b(repair())), [1]])
      +ws = Ms.ms.weights(ids, w)
      +want = Nat.add(zeros.of(tb, A.ag.read.bytes(b(direct()))), zeros.of(tb, A.ag.read.bytes(b(repair()))))
      verdict("window (" ++ Nat.show(count.zero(ws)) ++ " of " ++ Nat.show(List.length(&2, F32, ws)) ++ " targets weigh 0)",
        Bool.and(Nat.is_eq(List.length(&2, F32, ws), Nat.sub(List.length(&2, U32, w), 1n)), Nat.is_eq(count.zero(ws), want)))

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(shape("direct", direct(), [0n, 1n, 1n, 3n, 4n, 5n]))
    IO.print(shape("repair", repair(), [0n, 1n, 1n, 2n, 4n, 5n, 3n, 4n, 5n]))
    IO.print(shape("term-to-type", to.type(), [0n, 1n, 1n, 4n, 5n, 3n, 4n, 5n]))
    IO.print(shape("verify", verify(), [0n, 1n, 1n, 2n, 4n, 5n]))
    IO.print(shape("trap", trap(), [0n, 3n, 4n, 5n]))
    IO.print(weights("weights direct", direct()))
    IO.print(weights("weights repair", repair()))
    IO.print(unfold())
    tx : List<&2, U32> <- B.Bytes.read_all("weights/code32k.bpe")
    IO.print(window.test(Tk.Bpe.parse(tx)))
    return Unit{}
