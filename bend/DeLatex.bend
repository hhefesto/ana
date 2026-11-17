import Base
import ./Sys.bend as S

# de-latex: a theory document's lines as plain English prose (R8, docs/r8/PLAN.md, 2026-11-17).
# The user, 11-16: "fillers shouldn't be latex, it should be regular English prose. That is one item
# we need to fix before starting to train"; 11-17: "The filler should be De-LaTeX-ed".  R7's
# bend-theory-cut changed nothing inside a line: 68.8% of the arXiv pieces' lines had a backslash.
#
# Meaning, a document at a time (dl.doc):
#   - a LaTeX document (one with a line `\begin{document}`) loses everything up to that line, and
#     everything from `\end{document}`, `\begin{thebibliography}` or `\bibliography{` on;
#   - a line goes whole when it is a LaTeX comment (its first non-blank byte `%`), nLab's layout
#     (`+--`, `=--`, `[[!`, `{:`, `{#`, `* table of contents`, `#Contents#`, `###Context###`), a
#     table row (`|`) or over 4096 bytes; it does not break its paragraph;
#   - a block goes whole and spoils its paragraph (below): display math (`$$ .. $$`, `\[ .. \]`), a code fence
#     (``` .. ```), and the environments of dl.envs (equations, figures, tables, diagrams, code,
#     bibliographies);
#   - every other line is read by dl.go: a command that only formats (`\emph`, `\textbf`,
#     `\section`, `\mathrm`, ...) goes and its argument stays; one that points (`\cite`, `\ref`,
#     `\label`, `\footnote`, `\url`, ...) goes with its argument; a symbol (`\alpha`, `\to`,
#     `\circ`, `\mathbb{N}`, ...) becomes its Unicode character; braces, `~`, markdown's `*`, `_`,
#     backquotes, `[[link|text]]`, `[text](url)` and HTML tags read as the text they show; inline
#     math `$..$` and `\(..\)` stays only if it reads as a short formula (under 40 bytes, every
#     command a known symbol);
#   - a line with anything left that is not prose (an unknown command, a long formula, `\frac`,
#     display math) spoils its paragraph; a line with under 3 letters left (`\begin{theorem}`, `\item`)
#     is a paragraph break.  A spoilt line comes out as a single NUL: TheoryCut.bend leaves out every
#     paragraph (a run of lines that are not blank) holding one, as its sentences lean on what went
#     (11-17: "Observe that" with its equation gone is not English prose).
# The piece's score (dl.score): the permille of its bytes that are plain prose (letters, digits,
# blanks and . , ; : ' " ( ) - ! ?); TheoryCut.bend keeps a piece only at PROSE_MIN or above.

# a command: its name, what it does (dl.go), its replacement
#   0 unknown (the line goes), 1 the name goes (its argument stays), 2 the name and its argument
#   go, 3 the replacement, 4 the line goes, 5 \mathbb, 6 the name and its first group go
type DlE is Data:
  DlE{n: List<&2, U32>, k: Nat, r: List<&2, U32>}

def dl.ks(+k: Nat, xs: List<&2, String>) -> List<&2, DlE>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      DlE{S.b(x), k, Nil{}} <> dl.ks(k, t)

# name, replacement, name, replacement, ...
def dl.rs(xs: List<&2, String>) -> List<&2, DlE>:
  match xs:
    case +n <> +r <> t:
      DlE{S.b(n), 3n, S.b(r)} <> dl.rs(t)
    case _:
      Nil{}

def dl.fmt() -> List<&2, String>:
  ["emph", "textbf", "textit", "textsl", "textsf", "textsc", "texttt", "textrm", "textup", "textnormal",
   "textmd", "text", "mathrm", "mathbf", "mathsf", "mathit", "mathtt", "mathcal", "mathscr", "mathfrak",
   "boldsymbol", "bm", "operatorname", "mbox", "hbox", "underline", "uline", "section", "subsection",
   "subsubsection", "chapter", "paragraph", "subparagraph", "part", "title", "noindent", "medskip",
   "bigskip", "smallskip", "newline", "par", "centering", "maketitle", "clearpage", "newpage", "hfill",
   "vfill", "indent", "left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr",
   "biggl", "biggr", "displaystyle", "textstyle", "scriptstyle", "limits", "nolimits", "nonumber",
   "notag", "protect", "relax", "footnotesize", "small", "large", "Large", "normalsize", "tiny", "em",
   "it", "bf", "rm", "sf", "tt", "sc", "upshape", "itshape", "bfseries", "mdseries", "normalfont",
   "item", "proof", "qedhere", "qed", "xspace", "ensuremath", "mathnormal", "textsuperscript", "smash"]

def dl.drops() -> List<&2, String>:
  ["cite", "citep", "citet", "citealp", "citealt", "citeauthor", "citeyear", "nocite", "ref", "eqref",
   "cref", "Cref", "autoref", "pageref", "label", "footnote", "footnotemark", "footnotetext", "thanks",
   "index", "vspace", "hspace", "bibitem", "url", "includegraphics", "input", "include", "marginpar",
   "hyperlink", "hypertarget", "phantom", "vphantom", "hphantom", "nameref", "todo", "vskip", "hskip",
   "setlength", "addtocounter", "setcounter", "newcommand", "renewcommand", "providecommand", "def",
   "DeclareMathOperator", "newtheorem", "theoremstyle", "usepackage", "documentclass", "bibliographystyle",
   "bibliography", "addcontentsline", "tableofcontents", "printbibliography", "arxiv", "doi", "email",
   "src", "srcsnippet", "javaimport", "cppimport", "pcodeimport", "codeimport", "indexsee", "caption",
   "index", "hline", "cline", "newpage", "pagebreak", "linebreak", "nopagebreak", "enlargethispage"]

def dl.bads() -> List<&2, String>:
  ["frac", "dfrac", "tfrac", "binom", "sqrt", "overline", "hat", "widehat", "tilde", "widetilde", "bar",
   "vec", "stackrel", "underbrace", "overbrace", "xymatrix", "mathop", "substack", "overset", "underset",
   "xrightarrow", "xleftarrow", "dot", "ddot", "check", "breve", "acute", "grave", "not", "cancel"]

def dl.syms() -> List<&2, String>:
  ["alpha", "α", "beta", "β", "gamma", "γ", "delta", "δ", "epsilon", "ε", "varepsilon", "ε", "zeta", "ζ",
   "eta", "η", "theta", "θ", "vartheta", "ϑ", "iota", "ι", "kappa", "κ", "lambda", "λ", "mu", "μ", "nu", "ν",
   "xi", "ξ", "pi", "π", "rho", "ρ", "varrho", "ϱ", "sigma", "σ", "tau", "τ", "upsilon", "υ", "phi", "φ",
   "varphi", "φ", "chi", "χ", "psi", "ψ", "omega", "ω", "Gamma", "Γ", "Delta", "Δ", "Theta", "Θ",
   "Lambda", "Λ", "Xi", "Ξ", "Pi", "Π", "Sigma", "Σ", "Upsilon", "Υ", "Phi", "Φ", "Psi", "Ψ", "Omega", "Ω",
   "to", "→", "rightarrow", "→", "longrightarrow", "⟶", "leftarrow", "←", "gets", "←", "longleftarrow", "⟵",
   "mapsto", "↦", "longmapsto", "⟼", "Rightarrow", "⇒", "implies", "⇒", "Leftarrow", "⇐",
   "Leftrightarrow", "⇔", "iff", "⇔", "leftrightarrow", "↔", "hookrightarrow", "↪", "twoheadrightarrow", "↠",
   "rightrightarrows", "⇉", "uparrow", "↑", "downarrow", "↓", "circ", "∘", "cdot", "·", "times", "×",
   "otimes", "⊗", "oplus", "⊕", "odot", "⊙", "leq", "≤", "le", "≤", "geq", "≥", "ge", "≥", "neq", "≠",
   "ne", "≠", "in", "∈", "notin", "∉", "ni", "∋", "subseteq", "⊆", "subset", "⊂", "supseteq", "⊇",
   "supset", "⊃", "cup", "∪", "cap", "∩", "bigcup", "⋃", "bigcap", "⋂", "forall", "∀", "exists", "∃",
   "neg", "¬", "lnot", "¬", "wedge", "∧", "land", "∧", "vee", "∨", "lor", "∨", "top", "⊤", "bot", "⊥",
   "perp", "⊥", "vdash", "⊢", "models", "⊨", "equiv", "≡", "cong", "≅", "simeq", "≃", "sim", "∼",
   "approx", "≈", "infty", "∞", "emptyset", "∅", "varnothing", "∅", "partial", "∂", "nabla", "∇",
   "sum", "∑", "prod", "∏", "coprod", "∐", "int", "∫", "langle", "⟨", "rangle", "⟩", "llbracket", "⟦",
   "rrbracket", "⟧", "lbrace", "{", "rbrace", "}", "mid", "|", "prime", "′", "ell", "ℓ", "star", "⋆",
   "ast", "∗", "colon", ":", "setminus", "∖", "pm", "±", "dagger", "†", "ldots", "…", "cdots", "⋯",
   "dots", "…", "vdots", "⋮", "Box", "□", "Diamond", "◇", "lfloor", "⌊", "rfloor", "⌋", "lceil", "⌈",
   "rceil", "⌉", "aleph", "ℵ", "hbar", "ℏ", "parallel", "∥", "bullet", "•", "triangleleft", "◁",
   "triangleright", "▷", "lhd", "◁", "rhd", "▷", "wp", "℘", "Re", "ℜ", "Im", "ℑ", "quad", " ", "qquad", " ",
   "LaTeX", "LaTeX", "TeX", "TeX", "eg", "e.g.", "ie", "i.e.", "etc", "etc.", "textendash", "-",
   "textemdash", "-", "S", "§", "dashv", "⊣", "Downarrow", "⇓", "Uparrow", "⇑", "nearrow", "↗",
   "searrow", "↘", "leadsto", "⇝", "rightharpoonup", "⇀", "lll", "⋘", "ll", "≪", "gg", "≫", "propto", "∝",
   "sqsubseteq", "⊑", "sqcup", "⊔", "sqcap", "⊓", "uplus", "⊎", "amalg", "⨿", "wr", "≀", "bigotimes", "⨂",
   "bigoplus", "⨁", "bigvee", "⋁", "bigwedge", "⋀", "therefore", "∴", "because", "∵", "angle", "∠",
   "triangle", "△", "square", "□", "checkmark", "✓", "flat", "♭", "sharp", "♯", "natural", "♮",
   "textbackslash", "\\", "backslash", "∖", "lvert", "|", "rvert", "|", "vert", "|", "Vert", "‖",
   "lVert", "‖", "rVert", "‖", "colonequals", "≔", "coloneqq", "≔", "defeq", "≝", "triangleq", "≜"]

def dl.table() -> List<&2, DlE>:
  List.append(&2, DlE, dl.ks(1n, dl.fmt()),
  List.append(&2, DlE, dl.ks(2n, dl.drops()),
  List.append(&2, DlE, dl.ks(4n, dl.bads()),
  List.append(&2, DlE, dl.ks(5n, ["mathbb", "mathds", "bbold"]),
  List.append(&2, DlE, dl.ks(6n, ["begin", "end", "href", "textcolor", "colorbox", "color"]),
  dl.rs(dl.syms()))))))

# (Bend checks a def against the defs above it, and a match takes a parameter, not a local binder:
# each walk below takes its decision about the head as a parameter, computed for the next head by a
# def above it, as TheoryCut.bend's thc.pack does)

# is the head entry's name `name`
def dl.heq(+tbl: List<&2, DlE>, +name: List<&2, U32>) -> Bool:
  match tbl:
    case Nil{}:
      False{}
    case DlE{+n, k, r} <> t:
      S.eq(n, name)

def dl.look(+name: List<&2, U32>, tbl: List<&2, DlE>, hit: Bool) -> DlE:
  match tbl hit:
    case Nil{} _:
      DlE{Nil{}, 0n, Nil{}}
    case e <> t True{}:
      e
    case e <> +t False{}:
      dl.look(name, t, dl.heq(t, name))

def dl.find(+name: List<&2, U32>, +tbl: List<&2, DlE>) -> DlE:
  dl.look(name, tbl, dl.heq(tbl, name))

def dl.kof(e: DlE) -> Nat:
  match e:
    case DlE{n, k, r}:
      k

def dl.rof(e: DlE) -> List<&2, U32>:
  match e:
    case DlE{n, k, r}:
      r

def dl.letter(+c: U32) -> Bool:
  Bool.or(Bool.and(U32.is_lt(64, c), U32.is_lt(c, 91)), Bool.and(U32.is_lt(96, c), U32.is_lt(c, 123)))

def dl.digit(+c: U32) -> Bool:
  Bool.and(U32.is_lt(47, c), U32.is_lt(c, 58))

# does xs start with a letter
def dl.hl(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      dl.letter(c)

# the command name at the front of xs (its letters)
def dl.name.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case +c <> +t True{}:
      c <> dl.name.go(t, dl.hl(t))
    case _ _:
      Nil{}

def dl.name(+xs: List<&2, U32>) -> List<&2, U32>:
  dl.name.go(xs, dl.hl(xs))

# xs after the name at its front
def dl.after.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case c <> +t True{}:
      dl.after.go(t, dl.hl(t))
    case ys _:
      ys

def dl.after(+xs: List<&2, U32>) -> List<&2, U32>:
  dl.after.go(xs, dl.hl(xs))

# the head's class for a group: 1 `{`, 2 `}`, 0 else
def dl.bc(+xs: List<&2, U32>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +c <> t:
      Bool.pick(Nat, U32.is_eq(c, 123), 1n, Bool.pick(Nat, U32.is_eq(c, 125), 2n, 0n))

# xs after the `}` closing a group, d more groups open inside it (xs after its `{`: d = 0)
def dl.close(xs: List<&2, U32>, k: Nat, d: Nat) -> List<&2, U32>:
  match xs k d:
    case Nil{} _ _:
      Nil{}
    case c <> +t 1n e:
      dl.close(t, dl.bc(t), 1n+e)
    case c <> t 2n 0n:
      t
    case c <> +t 2n 1n+e:
      dl.close(t, dl.bc(t), e)
    case c <> +t _ e:
      dl.close(t, dl.bc(t), e)

# xs less a group `{...}` at its front (xs when there is none)
def dl.grp(+xs: List<&2, U32>) -> List<&2, U32>:
  +t = List.drop(&2, U32, xs, 1n)
  Bool.pick(List<&2, U32>, S.head.is(xs, 123), dl.close(t, dl.bc(t), 0n), xs)

# xs after the first byte c (Nil when there is none)
def dl.past.go(xs: List<&2, U32>, +c: U32, z: Bool) -> List<&2, U32>:
  match xs z:
    case Nil{} _:
      Nil{}
    case h <> t True{}:
      t
    case h <> +t False{}:
      dl.past.go(t, c, S.head.is(t, c))

def dl.past(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  dl.past.go(xs, c, S.head.is(xs, c))

# xs less an optional argument `[...]` at its front
def dl.opt(+xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.head.is(xs, 91), dl.past(xs, 93), xs)

def dl.h2(+xs: List<&2, U32>) -> Bool:
  S.prefix(xs, [93, 93])

# the bytes before the first `]]`
def dl.upto2.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case +c <> +t False{}:
      c <> dl.upto2.go(t, dl.h2(t))
    case _ _:
      Nil{}

# xs after the first `]]`
def dl.past2.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case Nil{} _:
      Nil{}
    case c <> t True{}:
      List.drop(&2, U32, t, 1n)
    case c <> +t False{}:
      dl.past2.go(t, dl.h2(t))

def dl.lastf(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case x <> Nil{}:
      x
    case x <> t:
      dl.lastf(t)

# a wiki link's text: `[[page]]` shows page, `[[page|text]]` text
def dl.link(+body: List<&2, U32>) -> List<&2, U32>:
  dl.lastf(S.split(dl.upto2.go(body, dl.h2(body)), 124))

def dl.linkrest(+body: List<&2, U32>) -> List<&2, U32>:
  dl.past2.go(body, dl.h2(body))

# \mathbb{X}: the double-struck letter for N Z R Q C, else nothing (the letter stays)
def dl.bb(+xs: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.prefix(xs, S.b("{N}")), S.b("ℕ"),
  Bool.pick(List<&2, U32>, S.prefix(xs, S.b("{Z}")), S.b("ℤ"),
  Bool.pick(List<&2, U32>, S.prefix(xs, S.b("{R}")), S.b("ℝ"),
  Bool.pick(List<&2, U32>, S.prefix(xs, S.b("{Q}")), S.b("ℚ"),
  Bool.pick(List<&2, U32>, S.prefix(xs, S.b("{C}")), S.b("ℂ"), Nil{})))))

def dl.bbn(+xs: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Nat.is_eq(S.len(dl.bb(xs)), 0n), 0n, 3n)

# an HTML tag's start after `<`: a letter, `/` or `!`
def dl.tag(+t: List<&2, U32>) -> Bool:
  match t:
    case Nil{}:
      False{}
    case +c <> r:
      Bool.or(dl.letter(c), Bool.or(U32.is_eq(c, 47), U32.is_eq(c, 33)))

# a byte read as nothing outside math: markdown's `*`, `_`, backquote, `[`, `]`
def dl.mark(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 42), Bool.or(U32.is_eq(c, 95), Bool.or(U32.is_eq(c, 96), Bool.or(U32.is_eq(c, 91), U32.is_eq(c, 93)))))

# a byte's class outside math: 0 itself, 6 nothing, 7 `[[` a wiki link, 8 `](` a markdown link's
# target, 9 an HTML tag, 40 LaTeX's opening quote ``
def dl.tcls(+c: U32, +t: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.and(U32.is_eq(c, 96), S.head.is(t, 96)), 40n,
  Bool.pick(Nat, Bool.and(U32.is_eq(c, 91), S.head.is(t, 91)), 7n,
  Bool.pick(Nat, Bool.and(U32.is_eq(c, 93), S.head.is(t, 40)), 8n,
  Bool.pick(Nat, Bool.and(U32.is_eq(c, 60), dl.tag(t)), 9n,
  Bool.pick(Nat, dl.mark(c), 6n, 0n)))))

# a byte's class: 0 itself, 1 `\`, 2 `$`, 3 a space (`~`, a tab), 4 nothing (a brace), 5 the line's
# end (`%`, a comment), else dl.tcls's outside math
def dl.cls(+c: U32, +t: List<&2, U32>, +m: Bool) -> Nat:
  Bool.pick(Nat, U32.is_eq(c, 92), 1n,
  Bool.pick(Nat, U32.is_eq(c, 36), 2n,
  Bool.pick(Nat, Bool.or(U32.is_eq(c, 126), U32.is_eq(c, 9)), 3n,
  Bool.pick(Nat, Bool.or(U32.is_eq(c, 123), U32.is_eq(c, 125)), 4n,
  Bool.pick(Nat, U32.is_eq(c, 37), 5n,
  Bool.pick(Nat, m, 0n, dl.tcls(c, t)))))))

# an accent's mark after `\` (R8, 11-17: `Andr\'{e}` spoilt its paragraph): ' ` " ^ ~ = .
def dl.accent(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 39), Bool.or(U32.is_eq(c, 96), Bool.or(U32.is_eq(c, 34), Bool.or(U32.is_eq(c, 94), Bool.or(U32.is_eq(c, 126), Bool.or(U32.is_eq(c, 61), U32.is_eq(c, 46)))))))

# after `\`: 10 nothing, 11 a command (a letter), 12 `\\` (a line break), 13 an escaped byte
# (% $ & # _ { }), 14 a space (, ; : ! or a blank), 15 `\(`, 16 `\)`, 17 `\-` (a hyphenation),
# 18 anything else
def dl.bcls(+t: List<&2, U32>) -> Nat:
  match t:
    case Nil{}:
      10n
    case +c <> r:
      Bool.pick(Nat, dl.letter(c), 11n,
      Bool.pick(Nat, U32.is_eq(c, 92), 12n,
      Bool.pick(Nat, Bool.or(U32.is_eq(c, 37), Bool.or(U32.is_eq(c, 36), Bool.or(U32.is_eq(c, 38), Bool.or(U32.is_eq(c, 35), Bool.or(U32.is_eq(c, 95), Bool.or(U32.is_eq(c, 123), U32.is_eq(c, 125))))))), 13n,
      Bool.pick(Nat, Bool.or(U32.is_eq(c, 44), Bool.or(U32.is_eq(c, 59), Bool.or(U32.is_eq(c, 58), Bool.or(U32.is_eq(c, 33), U32.is_eq(c, 32))))), 14n,
      Bool.pick(Nat, U32.is_eq(c, 40), 15n,
      Bool.pick(Nat, U32.is_eq(c, 41), 16n,
      Bool.pick(Nat, U32.is_eq(c, 45), 17n,
      Bool.pick(Nat, dl.accent(c), 19n, 18n))))))))

# xs after a command's name and its `*`
def dl.r1(+t: List<&2, U32>) -> List<&2, U32>:
  +r0 = dl.after(t)
  Bool.pick(List<&2, U32>, S.head.is(r0, 42), List.drop(&2, U32, r0, 1n), r0)

# does xs open an argument (`{` or `[`)
def dl.harg(+xs: List<&2, U32>) -> Bool:
  Bool.or(S.head.is(xs, 123), S.head.is(xs, 91))

# a command's class from its kind k (t: from its name on): 20 + k for a known one; an unknown one
# (R8, 11-17, the user: "Category theory and algorithm text books": a book's own macros, `\newterm{..}`,
# `\cat{C}`, `\Hom`, spoilt most of its paragraphs) is 28 with an argument (the name and an optional
# argument go, the argument stays), 27 in math without one (it reads as its name), else 20 (it spoils)
def dl.unk(+t: List<&2, U32>, +m: Bool, +k: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_eq(k, 0n), Bool.pick(Nat, dl.harg(dl.r1(t)), 28n, Bool.pick(Nat, m, 27n, 20n)), Nat.add(20n, k))

# a backslash's class: dl.bcls's, a command's dl.unk
def dl.hc.b(+t: List<&2, U32>, +tbl: List<&2, DlE>, +m: Bool, b: Nat) -> Nat:
  match b:
    case 11n:
      dl.unk(t, m, dl.kof(dl.find(dl.name(t), tbl)))
    case 10n:
      10n
    case 12n:
      12n
    case 13n:
      13n
    case 14n:
      14n
    case 15n:
      15n
    case 16n:
      16n
    case 17n:
      17n
    case 19n:
      19n
    case _:
      18n

# a `$`'s class: 30 `$$` (display math), 31 the end of inline math, 32 its start
def dl.hc.s(+m: Bool, dd: Bool) -> Nat:
  match dd:
    case True{}:
      30n
    case False{}:
      Bool.pick(Nat, m, 31n, 32n)

def dl.hc.c(+t: List<&2, U32>, +tbl: List<&2, DlE>, +m: Bool, +k: Nat, is1: Bool, is2: Bool) -> Nat:
  match is1 is2:
    case True{} _:
      dl.hc.b(t, tbl, m, dl.bcls(t))
    case False{} True{}:
      dl.hc.s(m, S.head.is(t, 36))
    case False{} False{}:
      k

# the class of xs's head, as dl.go takes it
def dl.hc(+xs: List<&2, U32>, +tbl: List<&2, DlE>, +m: Bool) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +c <> +t:
      +k = dl.cls(c, t, m)
      dl.hc.c(t, tbl, m, k, Nat.is_eq(k, 1n), Nat.is_eq(k, 2n))

def dl.inc(+m: Bool, +n: Nat) -> Nat:
  Bool.pick(Nat, m, 1n+n, n)

# the end of inline math read n bytes: a NUL (the line goes) when the formula is too long to read as prose
def dl.long(+n: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_lt(40n, n), [0], Nil{})

# a line read (m: inside inline math, n: its bytes so far, k: the head's class, dl.hc); a NUL in the
# output marks what is not prose
def dl.go(fuel: Nat, xs: List<&2, U32>, +tbl: List<&2, DlE>, +m: Bool, +n: Nat, k: Nat) -> List<&2, U32>:
  match fuel xs k:
    case 0n _ _:
      Nil{}
    case 1n+f Nil{} _:
      Bool.pick(List<&2, U32>, m, [0], Nil{})
    case 1n+f +c <> +t 0n:
      c <> dl.go(f, t, tbl, m, dl.inc(m, n), dl.hc(t, tbl, m))
    case 1n+f c <> +t 3n:
      32 <> dl.go(f, t, tbl, m, dl.inc(m, n), dl.hc(t, tbl, m))
    case 1n+f c <> +t 4n:
      dl.go(f, t, tbl, m, dl.inc(m, n), dl.hc(t, tbl, m))
    case 1n+f c <> t 5n:
      Bool.pick(List<&2, U32>, m, [0], Nil{})
    case 1n+f c <> +t 6n:
      dl.go(f, t, tbl, m, n, dl.hc(t, tbl, m))
    case 1n+f c <> +t 7n:
      +body = List.drop(&2, U32, t, 1n)
      +r = dl.linkrest(body)
      S.append(dl.link(body), dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m)))
    case 1n+f c <> +t 8n:
      +r = dl.past(t, 41)
      dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> +t 9n:
      +r = dl.past(t, 62)
      dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> +t 40n:
      +r = List.drop(&2, U32, t, 1n)
      34 <> dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> t 10n:
      Nil{}
    case 1n+f c <> +t 12n:
      +r = List.drop(&2, U32, t, 1n)
      32 <> dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m))
    case 1n+f c <> +t 13n:
      +r = List.drop(&2, U32, t, 1n)
      S.append(List.take(&2, U32, t, 1n), dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m)))
    case 1n+f c <> +t 14n:
      +r = List.drop(&2, U32, t, 1n)
      32 <> dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m))
    case 1n+f c <> +t 15n:
      +r = List.drop(&2, U32, t, 1n)
      dl.go(f, r, tbl, True{}, 0n, dl.hc(r, tbl, True{}))
    case 1n+f c <> +t 16n:
      +r = List.drop(&2, U32, t, 1n)
      S.append(dl.long(n), dl.go(f, r, tbl, False{}, 0n, dl.hc(r, tbl, False{})))
    case 1n+f c <> +t 17n:
      +r = List.drop(&2, U32, t, 1n)
      dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> +t 19n:
      +r = List.drop(&2, U32, t, 1n)
      dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> +t 21n:
      +r = dl.r1(t)
      dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m))
    case 1n+f c <> +t 22n:
      +r = dl.grp(dl.opt(dl.r1(t)))
      dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m))
    case 1n+f c <> +t 23n:
      +r = dl.r1(t)
      S.append(dl.rof(dl.find(dl.name(t), tbl)), dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m)))
    case 1n+f c <> +t 25n:
      +r1 = dl.r1(t)
      +r = List.drop(&2, U32, r1, dl.bbn(r1))
      S.append(dl.bb(r1), dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m)))
    case 1n+f c <> +t 26n:
      +r = dl.grp(dl.r1(t))
      dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m))
    case 1n+f c <> +t 30n:
      +r = List.drop(&2, U32, t, 1n)
      0 <> dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> +t 31n:
      S.append(dl.long(n), dl.go(f, t, tbl, False{}, 0n, dl.hc(t, tbl, False{})))
    case 1n+f c <> +t 32n:
      dl.go(f, t, tbl, True{}, 0n, dl.hc(t, tbl, True{}))
    case 1n+f c <> +t 27n:
      +r = dl.r1(t)
      S.append(dl.name(t), dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m)))
    case 1n+f c <> +t 28n:
      +r = dl.opt(dl.r1(t))
      dl.go(f, r, tbl, m, dl.inc(m, n), dl.hc(r, tbl, m))
    case 1n+f c <> +t 20n:
      +r = dl.r1(t)
      0 <> dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> +t 24n:
      +r = dl.r1(t)
      0 <> dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f c <> +t 18n:
      +r = List.drop(&2, U32, t, 1n)
      0 <> dl.go(f, r, tbl, m, n, dl.hc(r, tbl, m))
    case 1n+f +c <> +t _:
      c <> dl.go(f, t, tbl, m, n, dl.hc(t, tbl, m))

def dl.read(+xs: List<&2, U32>, +tbl: List<&2, DlE>) -> List<&2, U32>:
  dl.go(1n+S.len(xs), xs, tbl, False{}, 0n, dl.hc(xs, tbl, False{}))

def dl.hsp(+xs: List<&2, U32>) -> Bool:
  S.head.is(xs, 32)

# runs of blanks as one space, none at either end (sp: a space is owed before the next byte; any:
# a byte is out)
def dl.squash(xs: List<&2, U32>, +sp: Bool, +any: Bool, bl: Bool) -> List<&2, U32>:
  match xs bl:
    case Nil{} _:
      Nil{}
    case c <> +t True{}:
      dl.squash(t, any, any, dl.hsp(t))
    case +c <> +t False{}:
      S.append(Bool.pick(List<&2, U32>, sp, [32], Nil{}), c <> dl.squash(t, False{}, True{}, dl.hsp(t)))

# LaTeX's closing quote '' and the HTML entities nLab writes
def dl.ent(+xs: List<&2, U32>) -> List<&2, U32>:
  S.replace(S.replace(S.replace(S.replace(S.replace(S.replace(S.replace(S.replace(xs, S.b("&lbrack;"), S.b("[")), S.b("&rbrack;"), S.b("]")), S.b("&amp;"), S.b("&")), S.b("&lt;"), S.b("<")), S.b("&gt;"), S.b(">")), S.b("&quot;"), [34]), S.b("&nbsp;"), S.b(" ")), [39, 39], [34])

# the spaces a dropped citation or label leaves before punctuation
def dl.tidy(+xs: List<&2, U32>) -> List<&2, U32>:
  dl.ent(S.replace(S.replace(S.replace(S.replace(S.replace(dl.squash(xs, False{}, False{}, dl.hsp(xs)), S.b(" ."), S.b(".")), S.b(" ,"), S.b(",")), S.b(" )"), S.b(")")), S.b("( "), S.b("(")), S.b("()"), Nil{}))

# a line's lead (blanks, markdown's heading `#`s and quote `>`s)
def dl.hlead(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      Bool.or(U32.is_eq(c, 32), Bool.or(U32.is_eq(c, 9), Bool.or(U32.is_eq(c, 35), U32.is_eq(c, 62))))

def dl.lead.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case c <> +t True{}:
      dl.lead.go(t, dl.hlead(t))
    case ys _:
      ys

def dl.lead(+xs: List<&2, U32>) -> List<&2, U32>:
  dl.lead.go(xs, dl.hlead(xs))

def dl.hblank(+xs: List<&2, U32>) -> Bool:
  Bool.or(S.head.is(xs, 32), S.head.is(xs, 9))

def dl.trim.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case c <> +t True{}:
      dl.trim.go(t, dl.hblank(t))
    case ys _:
      ys

def dl.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  dl.trim.go(xs, dl.hblank(xs))

def dl.letters(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +c <> t:
      dl.letters(t, Bool.pick(Nat, dl.letter(c), 1n+n, n))

def dl.any(+l: List<&2, U32>, ps: List<&2, String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> t:
      Bool.or(S.prefix(l, S.b(p)), dl.any(l, t))

# a line that goes whole without breaking its paragraph (x: the line from its first non-blank byte)
def dl.skip(+x: List<&2, U32>, +l: List<&2, U32>) -> Bool:
  Bool.or(dl.any(x, ["%", "+--", "=--", "[[!", "{:", "{#", "* table of contents", "#Contents#", "###Context###", "|", ":::", "category:"]), Bool.or(S.infix(x, S.b(".html#")), Nat.is_lt(4096n, S.len(l))))

def dl.envs() -> List<&2, String>:
  ["equation", "align", "alignat", "eqnarray", "gather", "multline", "flalign", "displaymath", "math",
   "figure", "table", "tabular", "tabularx", "longtable", "tikzpicture", "tikzcd", "xy", "xymatrix", "diagram",
   "CD", "array", "matrix", "pmatrix", "bmatrix", "cases", "thebibliography", "verbatim", "lstlisting",
   "minted", "code", "spec", "hscode", "comment", "algorithm", "algorithmic", "subequations", "picture",
   "prooftree", "mathpar", "bprooftree", "dmath", "split", "aligned", "gathered", "Verbatim", "quiver",
   "snip", "snipv", "Haskell", "haskell", "scope", "pgfonlayer", "algorithm2e", "lstinputlisting", "tabbing",
   "alltt", "Code", "java", "cpp", "pcode"]

def dl.henv(+xs: List<&2, U32>) -> Bool:
  Bool.not(Bool.or(S.head.is(xs, 125), Bool.or(S.head.is(xs, 42), Nat.is_eq(S.len(List.take(&2, U32, xs, 1n)), 0n))))

# the environment's name at the front of x (after `\begin{`), less a trailing `*`
def dl.envname.go(xs: List<&2, U32>, z: Bool) -> List<&2, U32>:
  match xs z:
    case +c <> +t True{}:
      c <> dl.envname.go(t, dl.henv(t))
    case _ _:
      Nil{}

def dl.envname(+xs: List<&2, U32>) -> List<&2, U32>:
  dl.envname.go(xs, dl.henv(xs))

def dl.anyeq(+x: List<&2, U32>, ps: List<&2, String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> t:
      Bool.or(S.eq(x, S.b(p)), dl.anyeq(x, t))

# a heading (markdown `#`s, or `\section{..}`) that opens a document's references or links: the rest of the
# document goes (11-17: not acknowledgments, a book's come in its preface: Spivak's went whole)
def dl.refs() -> List<&2, String>:
  ["References", "Bibliography", "Related concepts", "Related entries", "Related nLab entries", "Related pages",
   "See also", "Literature", "Selected writings", "Further reading"]

def dl.anyhead(+h: List<&2, U32>, ps: List<&2, String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> t:
      Bool.or(Bool.and(S.prefix(h, S.b(p)), Nat.is_le(S.len(h), Nat.add(S.len(S.b(p)), 3n))), dl.anyhead(h, t))

def dl.refhead(+x: List<&2, U32>) -> Bool:
  Bool.or(Bool.and(S.head.is(x, 35), dl.anyhead(dl.lead(x), dl.refs())),
    Bool.and(S.prefix(x, S.b("\\section")), Bool.or(S.infix(x, S.b("{References}")), S.infix(x, S.b("{Bibliography}")))))

# what ends a block a line opens (x from its first non-blank byte): Nil when it opens none; [0] for
# the rest of the document
def dl.opens(+x: List<&2, U32>) -> List<&2, U32>:
  +env = dl.envname(List.drop(&2, U32, x, 7n))
  +fin = S.append(S.b("\\end{"), env)
  Bool.pick(List<&2, U32>, Bool.or(dl.refhead(x), Bool.or(S.prefix(x, S.b("\\end{document}")), Bool.or(S.prefix(x, S.b("\\begin{thebibliography}")), S.prefix(x, S.b("\\bibliography{"))))), [0],
  Bool.pick(List<&2, U32>, Bool.and(S.prefix(x, S.b("\\begin{")), dl.anyeq(env, dl.envs())),
    Bool.pick(List<&2, U32>, S.infix(List.drop(&2, U32, x, 7n), fin), Nil{}, fin),
  Bool.pick(List<&2, U32>, S.prefix(x, S.b("$$")), Bool.pick(List<&2, U32>, S.infix(List.drop(&2, U32, x, 2n), S.b("$$")), Nil{}, S.b("$$")),
  Bool.pick(List<&2, U32>, S.prefix(x, S.b("\\[")), Bool.pick(List<&2, U32>, S.infix(x, S.b("\\]")), Nil{}, S.b("\\]")),
  Bool.pick(List<&2, U32>, S.prefix(x, S.b("```")), S.b("```"), Nil{})))))

# a line read: the prose left; [0] (it spoils its paragraph) when it is not prose; Nil (a paragraph
# break) when it is only markup
def dl.line(+l: List<&2, U32>, +tbl: List<&2, DlE>) -> List<&2, U32>:
  +y = dl.tidy(dl.read(dl.lead(l), tbl))
  Bool.pick(List<&2, U32>, S.infix(y, [0]), [0], Bool.pick(List<&2, U32>, Nat.is_lt(dl.letters(y, 0n), 3n), Nil{}, y))

# a line's class, st what ends the block it is in (Nil: none): 0 in the block, 1 the block's last,
# 2 it opens a block, 3 it goes whole (dl.skip), 4 prose to read
def dl.lcls(+l: List<&2, U32>, +st: List<&2, U32>) -> Nat:
  +x = dl.trim(l)
  Bool.pick(Nat, Bool.not(Nat.is_eq(S.len(st), 0n)), Bool.pick(Nat, S.infix(l, st), 1n, 0n),
  Bool.pick(Nat, Bool.not(Nat.is_eq(S.len(dl.opens(x)), 0n)), 2n,
  Bool.pick(Nat, dl.skip(x, l), 3n, 4n)))

def dl.lh(+ls: List<&2, List<&2, U32>>, +st: List<&2, U32>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      dl.lcls(l, st)

# the lines as dl.doc reads them (st: what ends the block they are in; k: the head's class, dl.lh)
def dl.lines(ls: List<&2, List<&2, U32>>, +tbl: List<&2, DlE>, +st: List<&2, U32>, k: Nat) -> List<&2, List<&2, U32>>:
  match ls k:
    case Nil{} _:
      Nil{}
    case l <> +t 0n:
      [0] <> dl.lines(t, tbl, st, dl.lh(t, st))
    case l <> +t 1n:
      [0] <> dl.lines(t, tbl, Nil{}, dl.lh(t, Nil{}))
    case +l <> +t 2n:
      +o = dl.opens(dl.trim(l))
      [0] <> dl.lines(t, tbl, o, dl.lh(t, o))
    case l <> +t 3n:
      dl.lines(t, tbl, Nil{}, dl.lh(t, Nil{}))
    case +l <> +t _:
      dl.line(l, tbl) <> dl.lines(t, tbl, Nil{}, dl.lh(t, Nil{}))

def dl.hbd(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      S.prefix(dl.trim(l), S.b("\\begin{document}"))

# a LaTeX document's lines after its `\begin{document}`
def dl.body(ls: List<&2, List<&2, U32>>, z: Bool) -> List<&2, List<&2, U32>>:
  match ls z:
    case Nil{} _:
      Nil{}
    case l <> t True{}:
      t
    case l <> +t False{}:
      dl.body(t, dl.hbd(t))

# a document's lines, de-LaTeX-ed: a paragraph break is an empty line, a spoilt line [0]
def dl.doc(+tbl: List<&2, DlE>, +t: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ls = S.split(t, 10)
  +ls2 = Bool.pick(List<&2, List<&2, U32>>, S.infix(t, S.b("\\begin{document}")), dl.body(ls, dl.hbd(ls)), ls)
  dl.lines(ls2, tbl, Nil{}, dl.lh(ls2, Nil{}))

# is a byte plain prose: a letter, a digit, a blank or . , ; : ' " ( ) - ! ?
def dl.plain(+c: U32) -> Bool:
  Bool.or(dl.letter(c), Bool.or(dl.digit(c), Bool.or(U32.is_eq(c, 32), Bool.or(U32.is_eq(c, 10),
  Bool.or(U32.is_eq(c, 46), Bool.or(U32.is_eq(c, 44), Bool.or(U32.is_eq(c, 59), Bool.or(U32.is_eq(c, 58),
  Bool.or(U32.is_eq(c, 39), Bool.or(U32.is_eq(c, 34), Bool.or(U32.is_eq(c, 40), Bool.or(U32.is_eq(c, 41),
  Bool.or(U32.is_eq(c, 45), Bool.or(U32.is_eq(c, 33), U32.is_eq(c, 63)))))))))))))))

def dl.plains(xs: List<&2, U32>, +n: Nat) -> Nat:
  match xs:
    case Nil{}:
      n
    case +c <> t:
      dl.plains(t, Bool.pick(Nat, dl.plain(c), 1n+n, n))

# the permille of a piece's bytes that are plain prose
def dl.score(+p: List<&2, U32>) -> Nat:
  +n = S.len(p)
  Bool.pick(Nat, Nat.is_eq(n, 0n), 0n, Nat.div(Nat.mul(dl.plains(p, 0n), 1000n), n))
