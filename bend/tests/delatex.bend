import Base
import ../Sys.bend as S
import ../DeLatex.bend as D

# bend/DeLatex.bend (R8's de-LaTeX-ed filler, 2026-11-17) on documents written here: each check prints
# `ok NAME` or `FAIL NAME` and what came out; any FAIL exits 1.
#   bend tests/delatex.bend -o /tmp/delatex && /tmp/delatex

type DtCk is Data:
  DtCk{name: String, ok: Bool, got: List<&2, U32>}

def dt.lines(ls: List<&2, String>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      S.b(l) <> dt.lines(t)

# a spoilt line ([0]) shows as `#`
def dt.show(ls: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Bool.pick(List<&2, U32>, S.eq(l, [0]), [35], l) <> dt.show(t)

def dt.eqs(xs: List<&2, List<&2, U32>>, ys: List<&2, List<&2, U32>>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(S.eq(x, y), dt.eqs(xt, yt))
    case _ _:
      False{}

def dt.doc(+name: String, +inp: String, +want: List<&2, String>) -> DtCk:
  +got = dt.show(D.dl.doc(D.dl.table(), S.b(inp)))
  DtCk{name, dt.eqs(got, dt.lines(want)), S.join(got, 124)}

def dt.score(+name: String, +inp: String, +lo: Nat, +hi: Nat) -> DtCk:
  +s = D.dl.score(S.b(inp))
  DtCk{name, Bool.and(Bool.not(Nat.is_lt(s, lo)), Bool.not(Nat.is_lt(hi, s))), S.b(Nat.show(s))}

def dt.checks() -> List<&2, DtCk>:
  [dt.doc("inline", "We show that \\emph{every} functor $F \\colon \\mathcal{C} \\to \\mathcal{D}$ preserves limits~\\cite{maclane}.",
     ["We show that every functor F : C → D preserves limits."]),
   dt.doc("section", "\\section{Introduction}\\label{sec:intro}", ["Introduction"]),
   dt.doc("equation", "Before.\n\\begin{equation}\nx = \\frac{a}{b}\n\\end{equation}\nAfter it.", ["Before.", "#", "#", "#", "After it."]),
   dt.doc("unknown", "Let \\Hom be the hom functor.\nThe next line stays.", ["#", "The next line stays."]),
   dt.doc("frac", "the ratio $\\frac{a}{b}$ is fine", ["#"]),
   dt.doc("nlab", "[[category|categories]] and [[functor]]s compose", ["categories and functors compose"]),
   dt.doc("preamble", "\\documentclass{article}\n\\usepackage{amsmath}\n\\begin{document}\nHello world text.\n\\end{document}\nafter", ["Hello world text.", "#", "#"]),
   dt.doc("markdown", "## Idea\nA *monad* is a [monoid](https://ncatlab.org/x) in `C`.", ["Idea", "A monad is a monoid in C."]),
   dt.doc("comment", "First line % a comment\n% a whole comment\nsecond line", ["First line", "second line"]),
   dt.doc("display", "Text here.\n$$\na + b\n$$\nMore text.", ["Text here.", "#", "#", "#", "More text."]),
   dt.doc("fence", "Prose first.\n```agda\nid : A -> A\n```\nProse last.", ["Prose first.", "#", "#", "#", "Prose last."]),
   dt.doc("symbols", "for all $x \\in \\mathbb{N}$, $\\alpha \\circ \\beta$", ["for all x ∈ ℕ, α ∘ β"]),
   dt.doc("escapes", "50\\% of \\$5 and A \\& B", ["50% of $5 and A & B"]),
   dt.doc("longmath", "so $a_1 + a_2 + a_3 + a_4 + a_5 + a_6 + a_7 + a_8 + a_9 + a_{10} + a_{11} + a_{12} + a_{13}$ holds", ["#"]),
   dt.doc("theorem", "\\begin{theorem}\nEvery group is a category.\n\\end{theorem}", ["", "Every group is a category.", ""]),
   dt.doc("shortmath", "a map $f \\colon A \\to B$ here", ["a map f : A → B here"]),
   dt.doc("html", "<div class=\"x\">Some <b>bold</b> words</div>", ["Some bold words"]),
   dt.doc("bibliography", "Last words.\n\\begin{thebibliography}{9}\n\\bibitem{a} A. Author.\n\\end{thebibliography}\nNot this.", ["Last words.", "#", "#", "#", "#"]),
   dt.doc("references", "## Idea\nA monad is a monoid.\n\n## References\n\nSaunders Mac Lane, Categories (1971)\nMore.", ["Idea", "A monad is a monoid.", "", "#", "#", "#", "#"]),
   dt.doc("quotes", "a ``lax'' functor &amp; a &lbrack;strict&rbrack; one", ["a \"lax\" functor & a [strict] one"]),
   dt.doc("newterm", "A category has \\newterm{objects} and \\newterm[x]{arrows}.", ["A category has objects and arrows."]),
   dt.doc("mathmacro", "the set $\\Hom(A, B)$ of maps", ["the set Hom(A, B) of maps"]),
   dt.doc("catarg", "a category $\\cat{C}$ here", ["a category C here"]),
   dt.doc("snip", "Text.\n\\begin{snip}{haskell}\nf x = x\n\\end{snip}\nMore.", ["Text.", "#", "#", "#", "More."]),
   dt.doc("accent", "by Andr\\'{e} Joyal and G\\\"odel", ["by Andre Joyal and Godel"]),
   dt.doc("pandoc", "::: warning\nWords of warning here.\n:::\ncategory: people", ["Words of warning here."]),
   dt.score("score-prose", "A functor maps objects to objects, and arrows to arrows.", 1000n, 1000n),
   dt.score("score-latex", "\\begin{align} x &= \\sum_{i} y_i \\end{align}", 0n, 700n)]

def dt.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "delatex: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def dt.say(cs: List<&2, DtCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      dt.end(Nat.is_eq(bad, 0n), bad, names)
    case DtCk{+n, +ok, +g} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n ++ ": " ++ S.str(g))
        dt.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def main() -> IO(Unit):
  dt.say(dt.checks(), 0n, "")
