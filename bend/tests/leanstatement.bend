import Base
import ../Sys.bend as S
import ../LeanStatement.bend as L

# bend-lean-statement (bend/LeanStatement.bend, 2026-11-03): where a statement
# stops (brackets, the `let`s and `have`s that own a `:=`, comments, strings,
# words that only start like a keyword), a direct session cut inside its
# statement against one that is not, and the tool on sessions written here: the
# prompt rewritten and nothing else moved, the fill of a cut unit and a fill
# whose check shows the hole in the statement left out, a session too large
# whole, one with no size, everything else byte for byte.
#
# Each check prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.  Compiled (the
# interpreter's stack does not hold the reader).

type Ck is Data:
  Ck{name: String, ok: Bool}

def ck.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "leanstatement: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def ck.say(cs: List<&2, Ck>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      ck.end(Nat.is_eq(bad, 0n), bad, names)
    case Ck{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        ck.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

# what comes from the statement's end on, or "none"
def ck.from(+s: String, m: Maybe<&2, Nat>) -> String:
  match m:
    case None{}:
      "none"
    case Some{+k}:
      S.str(List.drop(&2, U32, S.b(s), k))

def ck.stop(+n: String, +s: String, +want: String) -> Ck:
  Ck{n, S.eq(S.b(ck.from(s, L.ls.end(S.b(s)))), S.b(want))}

def ck.stops() -> List<&2, Ck>:
  [ck.stop("a plain statement", "theorem t : a = b := by simp", ":= by simp"),
   ck.stop("a let owns its :=", "theorem t (a : N) :\n  let x : R := 1;\n  x = a := by simp", ":= by simp"),
   ck.stop("two lets", "t : let x := 1; let y := 2; x = y := rfl", ":= rfl"),
   ck.stop("a have owns its :=", "t : have h : a := b; c := d", ":= d"),
   ck.stop("a let in brackets is its bracket's", "t : (let x := 1; x) = 1 := rfl", ":= rfl"),
   ck.stop("a binder's default", "def f (n : N := 5) : N := n", ":= n"),
   ck.stop("a pattern let", "t : let (a, b) := p; a = b := rfl", ":= rfl"),
   ck.stop("angle brackets", "t : f ⟨x := 1⟩ = 1 := rfl", ":= rfl"),
   ck.stop("a word that starts like let", "t : letter = a := rfl", ":= rfl"),
   ck.stop("a word that ends like have", "t : behave = a := rfl", ":= rfl"),
   ck.stop("a line comment", "t : a -- let x := 1\n  := rfl", ":= rfl"),
   ck.stop("a block comment", "t : a /- := -/ := rfl", ":= rfl"),
   ck.stop("a string", "t : a = \":= \\\" :=\" := rfl", ":= rfl"),
   ck.stop("no := at all", "instance : C where\n  x := 1", ":= 1"),
   ck.stop("nothing", "theorem t : a", "none")]

def ck.direct(+stmt: String, +rest: String) -> List<&2, U32>:
  S.b("## user\n\nProve `t` in p/t.lean.\n\n```lean\n" ++ stmt ++ "\n```\n\n## read\n\np/t.lean 1 1\n\n## echo\n\n```\nimport Mathlib\n[lines 1-1 of 1]\n```\n\n## edit\n\np/t.lean\n-import Mathlib\n+import Mathlib\n+\n+theorem t (a : N) :\n+    let x : R := 1;\n+    x = a := by\n+  simp\n\n## echo\n\n```\n--- p/t.lean\n```\n\n## mugen\n\nProved `t`." ++ rest)

def ck.whole.is(m: L.Wh, +want: String) -> Bool:
  match m:
    case L.WhCut{+s, a, b}:
      S.eq(s, S.b(want))
    case L.WhNot{why}:
      False{}

def ck.not.is(m: L.Wh, +want: String) -> Bool:
  match m:
    case L.WhCut{s, a, b}:
      False{}
    case L.WhNot{+why}:
      S.eq(S.b(why), S.b(want))

def ck.cut() -> String:
  "theorem t (a : N) :\n    let x : R"

def ck.full() -> String:
  "theorem t (a : N) :\n    let x : R := 1;\n    x = a"

def ck.put.at(+t: List<&2, U32>, m: Maybe<&2, L.Sp>) -> List<&2, U32>:
  match m:
    case None{}:
      Nil{}
    case Some{L.Sp{+a, +b}}:
      L.ls.put(t, S.b(ck.full()), a, b)

def ck.put() -> List<&2, U32>:
  +t = ck.direct(ck.cut(), "")
  ck.put.at(t, L.ls.span(t))

def ck.pure() -> List<&2, Ck>:
  [Ck{"a prompt cut inside its statement gets the whole one", ck.whole.is(L.ls.whole(ck.direct(ck.cut(), "")), ck.full())},
   Ck{"a prompt with the whole statement stays", ck.not.is(L.ls.whole(ck.direct(ck.full(), "")), "whole")},
   Ck{"no code block", ck.not.is(L.ls.whole(S.b("## user\n\nProve it.\n\n## edit\n\np\n+x := 1")), "no-prompt")},
   Ck{"a code block past the first heading is not the prompt", ck.not.is(L.ls.whole(S.b("## user\n\nProve it.\n\n## echo\n\n```lean\nx\n```")), "no-prompt")},
   Ck{"no edit", ck.not.is(L.ls.whole(S.b("## user\n\n```lean\nx\n```\n\n## mugen\n\nno.")), "no-edit")},
   Ck{"an answer without the prompt", ck.not.is(L.ls.whole(S.b("## user\n\n```lean\nx\n```\n\n## edit\n\np\n+y := 1")), "prompt-not-in-answer")},
   Ck{"an answer without :=", ck.not.is(L.ls.whole(S.b("## user\n\n```lean\nx\n```\n\n## edit\n\np\n+x where")), "no-:=")},
   Ck{"the rewrite puts it in the prompt's place", S.eq(ck.put(), ck.direct(ck.full(), ""))}]

def ck.pair(+id: String, +t: List<&2, U32>) -> List<&2, U32>:
  L.ls.pair(S.b(id), t)

def ck.cat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  List.concat(&2, U32, xss)

def ck.fill() -> List<&2, U32>:
  S.b("## user\n\nFill the hole.\n\n## mugen\n\nFilled.")

def ck.input() -> List<&2, U32>:
  ck.cat([ck.pair("u1/mugen-direct", ck.direct(ck.cut(), "")),
          ck.pair("u1/mugen-fill", ck.fill()),
          ck.pair("u1/mugen-repair-0", S.b("## user\n\nrepair one")),
          ck.pair("u2/mugen-direct", ck.direct(ck.full(), "")),
          ck.pair("u2/mugen-fill", ck.fill()),
          ck.pair("u3/mugen-fill", S.b("## echo\n\nerror: unexpected end of input\n")),
          ck.pair("u4/mugen-direct", ck.direct(ck.cut(), " a large one")),
          ck.pair("u4/mugen-fill", ck.fill()),
          ck.pair("u5/mugen-direct", ck.direct(ck.cut(), " no size"))])

def ck.want() -> List<&2, U32>:
  ck.cat([ck.pair("u1/mugen-direct", ck.direct(ck.full(), "")),
          ck.pair("u1/mugen-repair-0", S.b("## user\n\nrepair one")),
          ck.pair("u2/mugen-direct", ck.direct(ck.full(), "")),
          ck.pair("u2/mugen-fill", ck.fill())])

def ck.sizes() -> List<&2, U32>:
  S.b("u1/mugen-direct\tdirect\t100\t1\t1\t1\nu1/mugen-fill\tfill\t100\t1\t1\t1\nu2/mugen-direct\tdirect\t999\t1\t1\t1\nu4/mugen-direct\tdirect\t990\t1\t1\t1\n")

def ck.counts(+c: String) -> Bool:
  +b = S.b(c)
  Bool.and(S.infix(b, S.b("direct cut 3")), Bool.and(S.infix(b, S.b("direct cut, too large whole 1")), Bool.and(S.infix(b, S.b("direct cut, no size 1")), Bool.and(S.infix(b, S.b("direct whole 1")),
    Bool.and(S.infix(b, S.b("fill 4")), Bool.and(S.infix(b, S.b("fill dropped 2")), Bool.and(S.infix(b, S.b("fill dropped by its check 1")), S.infix(b, S.b("other 1")))))))))

def ck.tool(+dir: String) -> IO(List<&2, Ck>):
  do IO<List<&2, Ck>>:
    S.write(dir ++ "/in", ck.input())
    S.write(dir ++ "/sizes", ck.sizes())
    +counts : String <- L.ls.run(dir ++ "/in", dir ++ "/sizes", dir ++ "/out", 1000n)
    +out : List<&2, U32> <- S.read(dir ++ "/out")
    +changed : List<&2, U32> <- S.read(dir ++ "/out.changed")
    +moved : List<&2, U32> <- S.read(dir ++ "/out.rewritten")
    return [Ck{"the tool: the output", S.eq(out, ck.want())},
            Ck{"the tool: what it changed", S.eq(changed, S.b("rewrote\tu1/mugen-direct\ndropped\tu1/mugen-fill\ndropped\tu3/mugen-fill\ntoo-large\tu4/mugen-direct\ndropped\tu4/mugen-fill\ntoo-large\tu5/mugen-direct\n"))},
            Ck{"the tool: the sessions it rewrote", S.eq(moved, ck.pair("u1/mugen-direct", ck.direct(ck.full(), "")))},
            Ck{"the tool: the counts", ck.counts(counts)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    tool : List<&2, Ck> <- ck.tool(dir)
    S.rm(dir)
    ck.say(List.concat(&2, Ck, [ck.stops(), ck.pure(), tool]), 0n, "")
