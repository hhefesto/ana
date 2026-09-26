import Base
import ./Nul.bend as Ns
import ./Tokenizer.bend as Tk
import ./Ftcc.bend as Fc

# units: declarations cut out of source files, each carrying what the
# checker harness (bend-check LANG) needs to check it and its
# variants, for the coding-agent transcripts (docs/TRANSCRIPT-FORMAT.md).
#
#   bend-units LANG INPUT.nul OUTPUT.nul [MAX_PER_FILE]
#
# LANG is haskell, agda, lean, bend or nix. The input is the NUL-framed
# (id, text) stream of source files; the output is one (id, record) pair
# per unit, the id "<file id>#<name>@<line>", the record its fields joined
# by the byte 0x1E (a file holding 0x1E or 0x1F is skipped):
#
#   0 lang    1 kind (type | proposition | empty)    2 name
#   3 doc     the comment above the declaration, markers removed
#   4 sig     the signature or statement, as shown in the Type turn
#   5 head    the file before the declaration (whole lines)
#   6 pre     the declaration before its body (the signature lines; a lean
#             declaration through its ":="; a bend law and the blank lines
#             after it; a bend def's header line)
#   7 body    8 tail  the file after the declaration
#   9 names   the words the body uses that may name something (space-joined)
#   10 hole   the body with a hole (empty: no hole for this unit)
#   11..      mutants: the body with one change each
#
# head ++ pre ++ body ++ tail is the file, byte for byte. Which declarations make
# units, per language (every one is a declaration at column 0):
#
#   haskell  `name :: type` (continuation lines indented) followed at once by
#            the equations `name ...` (and their indented lines, blank lines
#            between them); the doc is a `-- |` block right above.
#   agda     `name : type` then the clauses `name ...`, the same shape; the
#            doc is the `--` lines right above; mixfix names (with `_`) are
#            skipped. The kind is proposition when the signature's result
#            mentions ≡ ≤ < ≈ ¬ ↔ ⊥ Dec ∈ ⊆ ∼, or the file's id contains
#            "Properties".
#   lean     [attributes, modifiers] theorem|lemma|def|abbrev|instance name
#            ...: the signature up to the first `:=` outside brackets, the
#            body after it; theorem and lemma are propositions. The doc is a
#            `/-- ... -/` block right above.
#   bend     `law name:` and the `def name(...)` proving it (the law is the
#            signature, the whole def the body; a proposition), or `def
#            name(...) -> T:` and its indented body; the doc is the `#`
#            lines right above.
#   nix      a whole file is one unit (no signature).
#
# A unit's body is at most 40 lines and 3,000 bytes, its signature at most
# 1,500 bytes; files over 2,000 lines are skipped; at most MAX_PER_FILE
# units (default 4, 0 for all) come from one file, spread evenly over it. The hole: the body
# replaced by `_` (lean), `?goal` (bend), or, in haskell (`_`) and agda
# (`?`), the right side of the last one-line equation. Mutants (up to four,
# positions chosen by a hash of the id): a word that names something
# replaced by another such word of the body; two adjacent words swapped; a
# word dropped. The first word of a line is never touched (it is the
# equation's own name). A mutant equal to the body is not emitted.

type Ln is Data:
  Ln{line: List<&2, U32>, rest: List<&2, U32>}

# Bytes ---------------------------------------------------------------------

def b(s: String) -> List<&2, U32>:
  Tk.utf8.bytes(s)

def append(xs: List<&2, U32>, ys: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, xs, ys)

def concat(xss: List<&2, List<&2, U32>>) -> List<&2, U32>:
  List.concat(&2, U32, xss)

def len(+xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

def eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case a <> s c <> t:
      Bool.and(U32.is_eq(a, c), eq(s, t))
    case _ _:
      False{}

# is p a prefix of xs
def prefix(xs: List<&2, U32>, p: List<&2, U32>) -> Bool:
  match xs p:
    case _ Nil{}:
      True{}
    case a <> s c <> t:
      Bool.and(U32.is_eq(a, c), prefix(s, t))
    case _ _:
      False{}

def has(+xs: List<&2, U32>, +x: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(U32.is_eq(h, x), has(t, x))

# does p occur in xs
def infix(+xs: List<&2, U32>, +p: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      Nat.is_eq(len(p), 0n)
    case h <> +t:
      Bool.or(prefix(h <> t, p), infix(t, p))

def is_space(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 9)), Bool.or(U32.is_eq(c, 10), U32.is_eq(c, 13)))

def is_delim(+c: U32) -> Bool:
  Bool.or(is_space(c), Bool.or(Bool.or(Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 41)), Bool.or(U32.is_eq(c, 91), U32.is_eq(c, 93))),
    Bool.or(Bool.or(U32.is_eq(c, 123), U32.is_eq(c, 125)), Bool.or(U32.is_eq(c, 44), U32.is_eq(c, 59)))))

def all.space(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      Bool.and(is_space(h), all.space(t))

def head.space(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      Bool.and(is_space(h), Bool.not(U32.is_eq(h, 10)))
    case Nil{}:
      False{}

def drop.spaces(+xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t True{}:
      drop.spaces(t, head.space(t))
    case _ _:
      xs

def trim.left(+xs: List<&2, U32>) -> List<&2, U32>:
  drop.spaces(xs, head.space(xs))

def head.any.space(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      is_space(h)
    case Nil{}:
      False{}

def drop.all.space.go(+xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t True{}:
      drop.all.space.go(t, head.any.space(t))
    case _ _:
      xs

def drop.all.space(+xs: List<&2, U32>) -> List<&2, U32>:
  drop.all.space.go(xs, head.any.space(xs))

def trim.right(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, drop.all.space(List.reverse(&2, U32, xs)))

# Lines -------------------------------------------------------------------------
#
# A file is its lines, each with its newline (the last may lack one), so
# joining them back is the file.

def Ln.put(h: U32, l: Ln) -> Ln:
  match l:
    case Ln{a, r}:
      Ln{h <> a, r}

def line.take(+xs: List<&2, U32>, stop: Bool) -> Ln:
  match xs stop:
    case h <> +t False{}:
      Ln.put(h, line.take(t, U32.is_eq(h, 10)))
    case _ _:
      Ln{Nil{}, xs}

def Ln.line(+l: Ln) -> List<&2, U32>:
  match l:
    case Ln{a, r}:
      a

def Ln.rest(+l: Ln) -> List<&2, U32>:
  match l:
    case Ln{a, r}:
      r

def lines.go(fuel: Nat, +xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match fuel xs:
    case 1n+p h <> t:
      +l = line.take(h <> t, False{})
      Ln.line(l) <> lines.go(p, Ln.rest(l))
    case _ _:
      Nil{}

def lines(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  lines.go(1n+len(xs), xs)

def blank(+l: List<&2, U32>) -> Bool:
  all.space(l)

def col0(+l: List<&2, U32>) -> Bool:
  match l:
    case h <> t:
      Bool.not(is_space(h))
    case Nil{}:
      False{}

# the line's first word (up to a space)
def word0.go(+xs: List<&2, U32>, sp: Bool) -> List<&2, U32>:
  match xs sp:
    case h <> +t False{}:
      h <> word0.go(t, head.any.space(t))
    case _ _:
      Nil{}

def word0(+l: List<&2, U32>) -> List<&2, U32>:
  word0.go(l, head.any.space(l))

# what follows the first word, spaces skipped
def after0(+l: List<&2, U32>) -> List<&2, U32>:
  trim.left(List.drop(&2, U32, l, len(word0(l))))

def nth(+ls: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  Maybe.default(&2, List<&2, U32>, List.get(&2, List<&2, U32>, ls, i), Nil{})

def slice(+ls: List<&2, List<&2, U32>>, +a: Nat, +e: Nat) -> List<&2, U32>:
  concat(List.take(&2, List<&2, U32>, List.drop(&2, List<&2, U32>, ls, a), Nat.sub(e, a)))

# Literate Agda -----------------------------------------------------------------
#
# A .lagda.md or .lagda / .lagda.tex file is read as the plain Agda it
# means: a prose line becomes a line comment ("-- " before it; a blank one
# stays blank), a code block's delimiter lines become "--", and code lines
# are kept as they are. No line moves and no code column moves, so a
# checker's positions in the plain file are the literate file's.
#
# The blocks are Agda's own (Agda.Syntax.Parser.Literate): in Markdown a
# block opens on a line that is ``` or ```agda (a block in another language
# is prose) and closes on ```; in LaTeX it opens on \begin{code} and closes
# on \end{code}. A blank prose line right above an opening line becomes
# "--" too, so the paragraph above a block is the doc comment of the block's
# first declaration.

def lit.core(+l: List<&2, U32>) -> List<&2, U32>:
  trim.right(trim.left(l))

def lit.dash(+l: List<&2, U32>) -> List<&2, U32>:
  append(b("--"), Bool.pick(List<&2, U32>, has(l, 10), [10], Nil{}))

def lit.cmt(+l: List<&2, U32>) -> List<&2, U32>:
  append(b("-- "), l)

def md.opens(+l: List<&2, U32>) -> Bool:
  +c = lit.core(l)
  Bool.or(eq(c, b("```")), eq(c, b("```agda")))

def md.closes(+l: List<&2, U32>) -> Bool:
  eq(lit.core(l), b("```"))

# the line in the plain file, from the state (0 prose, 1 an Agda block,
# 2 another language's block) and the next line
def md.line(+st: Nat, +l: List<&2, U32>, +next: List<&2, U32>) -> List<&2, U32>:
  match st:
    case 0n:
      Bool.pick(List<&2, U32>, md.opens(l), lit.dash(l),
        Bool.pick(List<&2, U32>, blank(l), Bool.pick(List<&2, U32>, md.opens(next), lit.dash(l), l), lit.cmt(l)))
    case 1n:
      Bool.pick(List<&2, U32>, md.closes(l), lit.dash(l), l)
    case _:
      lit.cmt(l)

def md.next(+st: Nat, +l: List<&2, U32>) -> Nat:
  match st:
    case 0n:
      Bool.pick(Nat, md.opens(l), 1n, Bool.pick(Nat, prefix(lit.core(l), b("```")), 2n, 0n))
    case _:
      Bool.pick(Nat, md.closes(l), 0n, st)

def md.go(ls: List<&2, List<&2, U32>>, +st: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> +t:
      md.line(st, l, nth(t, 0n)) <> md.go(t, md.next(st, l))

def tex.opens(+l: List<&2, U32>) -> Bool:
  Bool.and(infix(l, b("\\begin{code}")), Bool.not(prefix(trim.left(l), b("%"))))

def tex.closes(+l: List<&2, U32>) -> Bool:
  infix(l, b("\\end{code}"))

def tex.line(+st: Nat, +l: List<&2, U32>, +next: List<&2, U32>) -> List<&2, U32>:
  match st:
    case 0n:
      Bool.pick(List<&2, U32>, tex.opens(l), lit.dash(l),
        Bool.pick(List<&2, U32>, blank(l), Bool.pick(List<&2, U32>, tex.opens(next), lit.dash(l), l), lit.cmt(l)))
    case _:
      Bool.pick(List<&2, U32>, tex.closes(l), lit.dash(l), l)

def tex.next(+st: Nat, +l: List<&2, U32>) -> Nat:
  match st:
    case 0n:
      Bool.pick(Nat, tex.opens(l), 1n, 0n)
    case _:
      Bool.pick(Nat, tex.closes(l), 0n, 1n)

def tex.go(ls: List<&2, List<&2, U32>>, +st: Nat) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> +t:
      tex.line(st, l, nth(t, 0n)) <> tex.go(t, tex.next(st, l))

def suffix(+xs: List<&2, U32>, +s: List<&2, U32>) -> Bool:
  prefix(List.reverse(&2, U32, xs), List.reverse(&2, U32, s))

# 0 plain, 1 literate Markdown, 2 literate LaTeX (Agda files only)
def lit.kind(+lang: Nat, +id: List<&2, U32>) -> Nat:
  +tex = Bool.or(suffix(id, b(".lagda")), suffix(id, b(".lagda.tex")))
  Bool.pick(Nat, Nat.is_eq(lang, 1n), Bool.pick(Nat, suffix(id, b(".lagda.md")), 1n, Bool.pick(Nat, tex, 2n, 0n)), 0n)

def unlit(+k: Nat, +text: List<&2, U32>) -> List<&2, U32>:
  match k:
    case 0n:
      text
    case 1n:
      concat(md.go(lines(text), 0n))
    case _:
      concat(tex.go(lines(text), 0n))

# Units -------------------------------------------------------------------------

def lines.count(+ls: List<&2, List<&2, U32>>) -> Nat:
  List.length(&2, List<&2, U32>, ls)

def small(+body: List<&2, U32>, +sig: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(Nat.is_le(lines.count(lines(body)), 40n), Nat.is_le(len(body), U32.to_nat(3000))),
    Bool.and(Nat.is_le(len(sig), U32.to_nat(1500)), Bool.not(all.space(body))))

# The sig-and-equations shape (haskell, agda) -------------------------------------
#
# rest is the file's lines from the signature line on. The signature is
# that line and the indented lines after it; the equations begin on the
# next line, which must start with the name, and run while a line starts
# with the name, is indented, or is blank with such a line after it.

def indented(+l: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(col0(l)), Bool.not(blank(l)))

def head.indented(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case l <> t:
      indented(l)
    case Nil{}:
      False{}

# A declaration may sit at an indent (an Agda one inside `module _ where`,
# an `instance` or a `where` block): its signature's first line and its
# equations start at that indent, what belongs to them is deeper. At indent
# 0, `at` is col0 and `deeper` is indented, so every other shape is unchanged.
def indent(+l: List<&2, U32>) -> Nat:
  Nat.sub(len(l), len(trim.left(l)))

def deeper(+ind: Nat, +l: List<&2, U32>) -> Bool:
  Bool.and(Nat.is_lt(ind, indent(l)), Bool.not(blank(l)))

def at(+ind: Nat, +l: List<&2, U32>) -> Bool:
  Bool.and(Nat.is_eq(indent(l), ind), Bool.not(blank(l)))

def head.deeper(+ind: Nat, +ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case l <> t:
      deeper(ind, l)
    case Nil{}:
      False{}

def sig.more.go(ls: List<&2, List<&2, U32>>, +ind: Nat, ok: Bool) -> Nat:
  match ls ok:
    case l <> +t True{}:
      1n+sig.more.go(t, ind, head.deeper(ind, t))
    case _ _:
      0n

def sig.more(+ind: Nat, +ls: List<&2, List<&2, U32>>) -> Nat:
  sig.more.go(ls, ind, head.deeper(ind, ls))

def eq.line(+ind: Nat, +name: List<&2, U32>, +l: List<&2, U32>) -> Bool:
  Bool.or(deeper(ind, l), Bool.and(at(ind, l), eq(word0(trim.left(l)), name)))

def eq.next(+ind: Nat, +name: List<&2, U32>, +ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      eq.line(ind, name, l)

def eq.ok(+ind: Nat, +name: List<&2, U32>, +ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(eq.line(ind, name, l), Bool.and(blank(l), eq.next(ind, name, t)))

# lines of equations from ls on (trailing blank lines not counted)
def eq.go(ls: List<&2, List<&2, U32>>, +ind: Nat, +name: List<&2, U32>, +k: Nat, +last: Nat, ok: Bool) -> Nat:
  match ls ok:
    case +l <> +t True{}:
      eq.go(t, ind, name, 1n+k, Bool.pick(Nat, blank(l), last, 1n+k), eq.ok(ind, name, t))
    case _ _:
      last

def eq.len(+ind: Nat, +name: List<&2, U32>, +ls: List<&2, List<&2, U32>>) -> Nat:
  eq.go(ls, ind, name, 0n, 0n, Bool.and(eq.next(ind, name, ls), True{}))

# the right side of the last one-line equation replaced by mark (" _" in
# haskell, " ?" in agda): the body's lines walked from the last, the first
# that fits (at column 0, with " = ", no indented line after it) replaced
type Hl is Data:
  Hl{done: Bool, ls: List<&2, List<&2, U32>>}

# the offset just past the first " = " in l (0: none)
def eq.sign.at(+l: List<&2, U32>, +k: Nat) -> Nat:
  match l:
    case Nil{}:
      0n
    case h <> +t:
      Bool.pick(Nat, prefix(h <> t, b(" = ")), Nat.add(k, 3n), eq.sign.at(t, 1n+k))

def hole.line(+l: List<&2, U32>, +mark: List<&2, U32>) -> List<&2, U32>:
  append(List.take(&2, U32, l, Nat.sub(eq.sign.at(l, 0n), 1n)), append(mark, b("\n")))

def hole.fits(+ind: Nat, +l: List<&2, U32>, +next.indented: Bool) -> Bool:
  Bool.and(at(ind, l), Bool.and(Bool.not(next.indented), Bool.not(Nat.is_eq(eq.sign.at(l, 0n), 0n))))

# rls: the body's lines, last first; acc: the lines already walked, in order
def hole.go(rls: List<&2, List<&2, U32>>, +ind: Nat, +mark: List<&2, U32>, +done: Bool, +next.indented: Bool, acc: List<&2, List<&2, U32>>) -> Hl:
  match rls:
    case Nil{}:
      Hl{done, acc}
    case +l <> t:
      +fits = Bool.and(Bool.not(done), hole.fits(ind, l, next.indented))
      hole.go(t, ind, mark, Bool.or(done, fits), deeper(ind, l), Bool.pick(List<&2, U32>, fits, hole.line(l, mark), l) <> acc)

def hole.fin(h: Hl) -> List<&2, U32>:
  match h:
    case Hl{done, ls}:
      Bool.pick(List<&2, U32>, done, concat(ls), Nil{})

# the body with its hole, or empty when no equation fits
def hole.eqs(+ind: Nat, +body: List<&2, U32>, +mark: List<&2, U32>) -> List<&2, U32>:
  hole.fin(hole.go(List.reverse(&2, List<&2, U32>, lines(body)), ind, mark, False{}, False{}, Nil{}))

# Words ---------------------------------------------------------------------------
#
# A body is a list of segments: runs of delimiters (space, newline, brackets,
# comma, semicolon) and words between them. A word is `lead` when it starts
# a line at column 0 (in haskell and agda, an equation's own name).

type Seg is Data:
  Seg{w: Bool, lead: Bool, bs: List<&2, U32>}

type Run is Data:
  Run{run: List<&2, U32>, rest: List<&2, U32>}

def Run.put(h: U32, r: Run) -> Run:
  match r:
    case Run{a, t}:
      Run{h <> a, t}

def head.delim(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      is_delim(h)
    case Nil{}:
      False{}

def head.nonempty(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      True{}
    case Nil{}:
      False{}

# the longest prefix whose bytes are delimiters (d) or not (not d)
def run.go(+xs: List<&2, U32>, +d: Bool, same: Bool) -> Run:
  match xs same:
    case h <> +t True{}:
      Run.put(h, run.go(t, d, Bool.and(head.nonempty(t), Bool.pick(Bool, d, head.delim(t), Bool.not(head.delim(t))))))
    case _ _:
      Run{Nil{}, xs}

def first.nl(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 10)
    case Nil{}:
      False{}

def last.nl(+xs: List<&2, U32>) -> Bool:
  first.nl(List.reverse(&2, U32, xs))

def Run.run(+r: Run) -> List<&2, U32>:
  match r:
    case Run{a, t}:
      a

def Run.rest(+r: Run) -> List<&2, U32>:
  match r:
    case Run{a, t}:
      t

# the bytes after the last newline of a run (all of it when it has none)
def tail.nl(+rs: List<&2, U32>) -> Nat:
  match rs:
    case Nil{}:
      0n
    case h <> +t:
      Bool.pick(Nat, U32.is_eq(h, 10), 0n, 1n+tail.nl(t))

# does the word after this delimiter run start a line at the declaration's
# indent (nl: the run itself starts a line)
def lead.after(+run: List<&2, U32>, +ind: Nat, +nl: Bool) -> Bool:
  Bool.pick(Bool, has(run, 10), Nat.is_eq(tail.nl(List.reverse(&2, U32, run)), ind), Bool.and(nl, Nat.is_eq(len(run), ind)))

def segs.go(fuel: Nat, +xs: List<&2, U32>, +ind: Nat, +nl: Bool) -> List<&2, Seg>:
  match fuel xs:
    case 1n+p +h <> +t:
      +d = is_delim(h)
      +r = run.go(h <> t, d, True{})
      Seg{Bool.not(d), Bool.and(Bool.not(d), nl), Run.run(r)} <> segs.go(p, Run.rest(r), ind, Bool.and(d, lead.after(Run.run(r), ind, nl)))
    case _ _:
      Nil{}

def segs(+body: List<&2, U32>, +ind: Nat) -> List<&2, Seg>:
  segs.go(1n+len(body), body, ind, True{})

def segs.join(ss: List<&2, Seg>) -> List<&2, U32>:
  match ss:
    case Nil{}:
      Nil{}
    case Seg{w, l, bs} <> t:
      append(bs, segs.join(t))

# Comments and strings -----------------------------------------------------------
#
# A word inside a line comment (`--`, or `#` in bend and nix) or a string
# literal is not code: its w flag is cleared, so neither the names nor the
# mutants see it (the text is unchanged). The state: 0 code, 1 comment, 2 a
# "string (both end at a newline), 3 a nix ''string.

def quotes(+bs: List<&2, U32>, +prev: U32) -> Nat:
  match bs:
    case Nil{}:
      0n
    case h <> +t:
      Nat.add(Bool.pick(Nat, Bool.and(U32.is_eq(h, 34), Bool.not(U32.is_eq(prev, 92))), 1n, 0n), quotes(t, h))

def odd(+n: Nat) -> Bool:
  Nat.is_eq(Nat.mod(n, 2n), 1n)

def cmt.mark(+lang: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_le(3n, lang), b("#"), b("--"))

def word.state(+st: Nat, +lang: Nat, +bs: List<&2, U32>) -> Nat:
  match st:
    case 0n:
      +nix2 = Bool.and(Nat.is_eq(lang, 4n), infix(bs, b("''")))
      Bool.pick(Nat, prefix(bs, cmt.mark(lang)), 1n, Bool.pick(Nat, nix2, 3n, Bool.pick(Nat, odd(quotes(bs, 0)), 2n, 0n)))
    case 1n:
      1n
    case 2n:
      Bool.pick(Nat, odd(quotes(bs, 0)), 0n, 2n)
    case _:
      Bool.pick(Nat, infix(bs, b("''")), 0n, 3n)

def word.code(+st: Nat, +lang: Nat, +bs: List<&2, U32>) -> Bool:
  +quoted = Bool.or(Nat.is_lt(0n, quotes(bs, 0)), Bool.and(Nat.is_eq(lang, 4n), infix(bs, b("''"))))
  Bool.and(Nat.is_eq(st, 0n), Bool.and(Bool.not(prefix(bs, cmt.mark(lang))), Bool.not(quoted)))

def delim.state(+st: Nat, +bs: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.and(has(bs, 10), Bool.or(Nat.is_eq(st, 1n), Nat.is_eq(st, 2n))), 0n, st)

def mask.go(ss: List<&2, Seg>, +lang: Nat, +st: Nat) -> List<&2, Seg>:
  match ss:
    case Nil{}:
      Nil{}
    case Seg{+w, l, +bs} <> t:
      +code = Bool.and(w, word.code(st, lang, bs))
      +nst = Bool.pick(Nat, w, word.state(st, lang, bs), delim.state(st, bs))
      Seg{code, Bool.and(l, code), bs} <> mask.go(t, lang, nst)

# an Agda body's indent is its first line's; every other body's is 0
def mask(+lang: Nat, +body: List<&2, U32>) -> List<&2, Seg>:
  +ind = Bool.pick(Nat, Nat.is_eq(lang, 1n), indent(body), 0n)
  mask.go(segs(body, ind), lang, 0n)

# Names: words that may name something the checker can type ------------------

def bs.of(xs: List<&2, String>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      b(x) <> bs.of(t)

def keywords(+lang: Nat) -> List<&2, List<&2, U32>>:
  match lang:
    case 0n:
      bs.of(["case", "class", "data", "default", "deriving", "do", "else", "foreign", "if", "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype", "of", "then", "type", "where", "forall", "mdo", "proc", "rec", "pattern", "qualified", "as", "hiding", "otherwise"])
    case 1n:
      bs.of(["where", "with", "rewrite", "let", "in", "data", "record", "field", "constructor", "module", "open", "import", "using", "hiding", "renaming", "to", "public", "private", "abstract", "instance", "postulate", "mutual", "pattern", "syntax", "infix", "infixl", "infixr", "variable", "Set", "Prop", "begin", "forall", "→", "∀", "λ", "≡", "=", ":", "|", "…"])
    case 2n:
      bs.of(["by", "fun", "=>", ":=", "at", "with", "do", "then", "else", "if", "match", "let", "have", "show", "from", "calc", "using", "only", "simp", "simp_all", "rw", "rwa", "exact", "exacts", "apply", "intro", "intros", "refine", "use", "constructor", "cases", "induction", "rcases", "obtain", "omega", "linarith", "nlinarith", "ring", "norm_num", "decide", "aesop", "assumption", "contradiction", "exfalso", "unfold", "dsimp", "simpa", "field_simp", "positivity", "gcongr", "congr", "ext", "funext", "specialize", "subst", "Type", "Prop", "Sort", "sorry", "fun", "this", "←", "→", "↔", "∀", "∃", "·", "⟨", "⟩", "▸", "⊢", "set", "suffices", "conv", "change", "convert", "trans", "symm", "left", "right", "exists", "rintro", "filter_upwards", "push_neg", "by_contra", "by_cases", "tauto", "trivial", "rfl", "norm_cast", "push_cast", "exact_mod_cast", "split_ifs", "interval_cases", "fin_cases", "refine'", "apply_fun", "simp_rw", "nth_rw", "bound", "fun_prop", "abel", "group", "module", "lift", "choose", "infer_instance", "haveI", "letI", "native_decide", "rename_i", "next", "all_goals", "any_goals", "first", "repeat", "iterate", "try", "on_goal", "case", "classical", "contrapose", "wlog", "clear", "revert", "generalize", "ring_nf", "linear_combination", "congr!", "ext1", "where", "termination_by", "decreasing_by", "deriving", "instance", "theorem", "lemma", "def", "open", "in", "end", "section", "namespace", "variable", "omit", "include", "mutual", "private", "protected", "noncomputable"])
    case 3n:
      bs.of(["match", "case", "def", "law", "for", "exs", "return", "do", "with", "where", "True", "False", "Nil", "Some", "None", "->", "=>", "==", "<>"])
    case _:
      Nil{}

def member(ks: List<&2, List<&2, U32>>, +w: List<&2, U32>) -> Bool:
  match ks:
    case Nil{}:
      False{}
    case k <> t:
      Bool.or(eq(k, w), member(t, w))

def is_lower(+c: U32) -> Bool:
  Bool.or(Bool.and(U32.is_ge(c, 97), U32.is_le(c, 122)), U32.is_eq(c, 95))

def is_upper(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 65), U32.is_le(c, 90))

def is_digit(+c: U32) -> Bool:
  Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57))

# a word's first byte may start a name: a letter, `_` (haskell and agda
# mixfix), or a non-ASCII byte (agda's and lean's unicode names)
def name.start(+w: List<&2, U32>) -> Bool:
  match w:
    case +h <> t:
      Bool.or(Bool.or(is_lower(h), is_upper(h)), Bool.and(U32.is_ge(h, 128), Bool.not(U32.is_eq(h, 194))))
    case Nil{}:
      False{}

# a byte of a haskell, lean, bend or nix name
def name.byte(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.or(is_lower(c), is_upper(c)), Bool.or(is_digit(c), U32.is_ge(c, 128))), Bool.or(U32.is_eq(c, 39), U32.is_eq(c, 46)))

def all.name(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case h <> t:
      Bool.and(name.byte(h), all.name(t))

# U+2190..U+2BFF (arrows, mathematical operators, brackets like ⟨ ⟩) are
# symbols, never part of a name: their UTF-8 is E2 86..AB
def sym.second(+t: List<&2, U32>) -> Bool:
  match t:
    case x <> r:
      Bool.and(U32.is_ge(x, 134), U32.is_le(x, 171))
    case Nil{}:
      False{}

def sym.free(+w: List<&2, U32>) -> Bool:
  match w:
    case Nil{}:
      True{}
    case h <> +t:
      Bool.and(Bool.not(Bool.and(U32.is_eq(h, 226), sym.second(t))), sym.free(t))

# bend and lean words carry markers the name does not: %f(... ?g ... @f
def unmark(+w: List<&2, U32>) -> List<&2, U32>:
  match w:
    case +h <> t:
      Bool.pick(List<&2, U32>, Bool.or(Bool.or(U32.is_eq(h, 37), U32.is_eq(h, 64)), U32.is_eq(h, 33)), t, h <> t)
    case Nil{}:
      Nil{}

# agda names may hold any non-delimiter byte (`+-comm`); the others only name bytes
def nameish(+lang: Nat, +self: List<&2, U32>, +w: List<&2, U32>) -> Bool:
  +shape = Bool.and(sym.free(w), Bool.or(Nat.is_eq(lang, 1n), all.name(w)))
  Bool.and(Bool.and(Bool.and(name.start(w), Nat.is_le(2n, len(w))), shape), Bool.and(Bool.not(member(keywords(lang), w)), Bool.not(eq(w, self))))

def names.go(ss: List<&2, Seg>, +lang: Nat, +self: List<&2, U32>, +acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ss:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, acc)
    case Seg{w, l, +bs} <> t:
      +u = unmark(bs)
      names.go(t, lang, self, Bool.pick(List<&2, List<&2, U32>>, Bool.and(w, Bool.and(nameish(lang, self, u), Bool.not(member(acc, u)))), u <> acc, acc))

def names(+lang: Nat, +self: List<&2, U32>, +body: List<&2, U32>) -> List<&2, List<&2, U32>>:
  List.take(&2, List<&2, U32>, names.go(mask(lang, body), lang, self, Nil{}), 16n)

# Search ----------------------------------------------------------------------------

# the offset of the first p in xs (k counts from the start; len(xs) when absent)
def find(+xs: List<&2, U32>, +p: List<&2, U32>, +k: Nat) -> Nat:
  match xs:
    case Nil{}:
      k
    case h <> +t:
      Bool.pick(Nat, prefix(h <> t, p), k, find(t, p, 1n+k))

def is_open(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 91)), U32.is_eq(c, 123))

def is_close(+c: U32) -> Bool:
  Bool.or(Bool.or(U32.is_eq(c, 41), U32.is_eq(c, 93)), U32.is_eq(c, 125))

def depth.step(+c: U32, +d: Nat) -> Nat:
  Bool.pick(Nat, is_open(c), 1n+d, Bool.pick(Nat, is_close(c), Nat.sub(d, 1n), d))

# the offset of the first ":=" outside brackets (0: none; a declaration never
# starts with one)
def top.at(+xs: List<&2, U32>, +p: List<&2, U32>, +d: Nat, +k: Nat) -> Nat:
  match xs:
    case Nil{}:
      0n
    case +h <> +t:
      Bool.pick(Nat, Bool.and(Nat.is_eq(d, 0n), prefix(h <> t, p)), k, top.at(t, p, depth.step(h, d), 1n+k))

def assign.at(+xs: List<&2, U32>) -> Nat:
  top.at(xs, b(":="), 0n, 0n)

def typed(+sig: List<&2, U32>) -> Bool:
  Nat.is_lt(0n, top.at(sig, b(" :"), 0n, 0n))

# a name ends at a delimiter or a colon: `foo(x`, `foo:`, `foo{a}`
def name.stop(+c: U32) -> Bool:
  Bool.or(is_delim(c), U32.is_eq(c, 58))

def head.stop(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      name.stop(h)
    case Nil{}:
      True{}

def name.cut.go(+xs: List<&2, U32>, stop: Bool) -> List<&2, U32>:
  match xs stop:
    case h <> +t False{}:
      h <> name.cut.go(t, head.stop(t))
    case _ _:
      Nil{}

def name.cut(+xs: List<&2, U32>) -> List<&2, U32>:
  name.cut.go(xs, head.stop(xs))

def strip(+l: List<&2, U32>, +p: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, prefix(l, p), List.drop(&2, U32, l, len(p)), l)

def any.infix(ms: List<&2, List<&2, U32>>, +xs: List<&2, U32>) -> Bool:
  match ms:
    case Nil{}:
      False{}
    case m <> t:
      Bool.or(infix(xs, m), any.infix(t, xs))

# Doc comments ----------------------------------------------------------------------
#
# `above` is the file's lines before the declaration, nearest first.

def head.prefix(+ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> Bool:
  match ls:
    case l <> t:
      prefix(l, p)
    case Nil{}:
      False{}

# the lines from the first on while they start with p
def run.prefix.go(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>, ok: Bool) -> List<&2, List<&2, U32>>:
  match ls ok:
    case l <> +t True{}:
      l <> run.prefix.go(t, p, head.prefix(t, p))
    case _ _:
      Nil{}

def run.prefix(+ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, List<&2, U32>>:
  run.prefix.go(ls, p, head.prefix(ls, p))

# the lines after those that start with p
def drop.prefix.go(+ls: List<&2, List<&2, U32>>, +p: List<&2, U32>, ok: Bool) -> List<&2, List<&2, U32>>:
  match ls ok:
    case l <> +t True{}:
      drop.prefix.go(t, p, head.prefix(t, p))
    case _ _:
      ls

def drop.prefix(+ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, List<&2, U32>>:
  drop.prefix.go(ls, p, head.prefix(ls, p))

# each line without its marker p and the spaces after it, joined
def doc.lines(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      append(trim.left(strip(l, p)), doc.lines(t, p))

# haskell: a `-- |` block right above
def doc.hs(+above: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +ds = List.reverse(&2, List<&2, U32>, run.prefix(above, b("--")))
  Bool.pick(List<&2, U32>, prefix(nth(ds, 0n), b("-- |")), trim.left(strip(doc.lines(ds, b("--")), b("|"))), Nil{})

# agda: the `--` lines right above, rule lines (all dashes) and blank ones left out
def doc.keep(+l: List<&2, U32>) -> Bool:
  Bool.and(Bool.not(blank(l)), Bool.not(prefix(l, b("-"))))

def doc.agda.go(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      +s = trim.left(strip(l, b("--")))
      append(Bool.pick(List<&2, U32>, doc.keep(s), s, Nil{}), doc.agda.go(t))

def doc.agda(+above: List<&2, List<&2, U32>>) -> List<&2, U32>:
  doc.agda.go(List.reverse(&2, List<&2, U32>, run.prefix(above, b("--"))))

# lean: a `/-- ... -/` block right above (attribute lines between skipped):
# the nearest "/--" before the text's final "-/", with no "-/" between them
def doc.lean(+above: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +txt = concat(List.reverse(&2, List<&2, U32>, List.take(&2, List<&2, U32>, drop.prefix(above, b("@[")), 40n)))
  +rt = List.reverse(&2, U32, trim.right(txt))
  +k = find(rt, b("--/"), 0n)
  +inner = List.reverse(&2, U32, List.take(&2, U32, rt, k))
  +core = List.take(&2, U32, inner, Nat.sub(len(inner), 2n))
  Bool.pick(List<&2, U32>, Bool.and(Bool.and(prefix(rt, b("/-")), Nat.is_lt(k, len(rt))), Bool.not(infix(core, b("-/")))), trim.right(trim.left(core)), Nil{})

# bend: the `#` lines right above
def doc.bend(+above: List<&2, List<&2, U32>>) -> List<&2, U32>:
  doc.lines(List.reverse(&2, List<&2, U32>, run.prefix(above, b("#"))), b("#"))

# nix: the `#` lines the file starts with
def doc.nix(+ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  doc.lines(run.prefix(ls, b("#")), b("#"))

# Declarations ----------------------------------------------------------------------
#
# A hit is a declaration found at line `at`, spanning n lines: `pre` is its
# text before the body (the signature, or a lean declaration through its
# ":="), so the file is lines[0, at) ++ pre ++ body ++ lines[at + n, ..).

type Hit is Data:
  Hit{at: Nat, n: Nat, name: List<&2, U32>, kind: List<&2, U32>, doc: List<&2, U32>, sig: List<&2, U32>,
      pre: List<&2, U32>, body: List<&2, U32>, hole: List<&2, U32>}
  No{}

def hit.fin(ok: Bool, h: Hit) -> Hit:
  match ok:
    case True{}:
      h
    case False{}:
      No{}

def keep.hit(ok: Bool, h: Hit, acc: List<&2, Hit>) -> List<&2, Hit>:
  match ok:
    case True{}:
      h <> acc
    case False{}:
      acc

# a hit joins acc when it is small enough for the window
def hit.push(h: Hit, acc: List<&2, Hit>) -> List<&2, Hit>:
  match h:
    case No{}:
      acc
    case Hit{at, n, name, kind, doc, +sig, pre, +body, hole}:
      keep.hit(small(body, sig), Hit{at, n, name, kind, doc, sig, pre, body, hole}, acc)

def head.blank(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case l <> t:
      blank(l)
    case Nil{}:
      False{}

# how many blank lines ls starts with
def blank.run.go(ls: List<&2, List<&2, U32>>, ok: Bool) -> Nat:
  match ls ok:
    case l <> +t True{}:
      1n+blank.run.go(t, head.blank(t))
    case _ _:
      0n

# haskell (`name :: type`) and agda (`name : type`)
def hs.start(+l: List<&2, U32>) -> Bool:
  Bool.and(Bool.and(col0(l), is_lower(Maybe.default(&2, U32, List.get(&2, U32, l, 0n), 0))), prefix(after0(l), b("::")))

def agda.start(+l: List<&2, U32>) -> Bool:
  +t = trim.left(l)
  +w = word0(t)
  +a = after0(t)
  Bool.and(Bool.and(Bool.not(blank(l)), Bool.or(prefix(a, b(": ")), prefix(a, b(":\n")))), Bool.and(Bool.not(has(w, 95)), Bool.not(prefix(w, b("--")))))

# agda's proposition rule: the result type (after the last →) mentions a
# relation, or the module is a Properties module
def agda.result(+sig: List<&2, U32>) -> List<&2, U32>:
  +r = List.reverse(&2, U32, sig)
  List.reverse(&2, U32, List.take(&2, U32, r, find(r, List.reverse(&2, U32, b("→")), 0n)))

def agda.kind(+sig: List<&2, U32>, +id: List<&2, U32>) -> List<&2, U32>:
  +rel = any.infix(bs.of(["≡", "≤", "<", "≈", "¬", "↔", "⊥", "Dec", "∈", "⊆", "∼"]), agda.result(sig))
  Bool.pick(List<&2, U32>, Bool.or(rel, infix(id, b("Properties"))), b("proposition"), b("type"))

def hit.eqs.if(ok: Bool, +lang: Nat, +id: List<&2, U32>, +rest: List<&2, List<&2, U32>>, +above: List<&2, List<&2, U32>>, +i: Nat, +ind: Nat, +name: List<&2, U32>) -> Hit:
  match ok:
    case False{}:
      No{}
    case True{}:
      +ns : Nat = 1n+sig.more(ind, List.drop(&2, List<&2, U32>, rest, 1n))
      +nb = eq.len(ind, name, List.drop(&2, List<&2, U32>, rest, ns))
      +sig = slice(rest, 0n, ns)
      +body = slice(rest, ns, Nat.add(ns, nb))
      +hs = Nat.is_eq(lang, 0n)
      +kind = Bool.pick(List<&2, U32>, hs, b("type"), agda.kind(sig, id))
      +doc = Bool.pick(List<&2, U32>, hs, doc.hs(above), doc.agda(above))
      +hole = hole.eqs(ind, body, Bool.pick(List<&2, U32>, hs, b(" _"), b(" ?")))
      hit.fin(Bool.not(Nat.is_eq(nb, 0n)), Hit{i, Nat.add(ns, nb), name, kind, doc, trim.right(sig), sig, body, hole})

# lean: [@[attrs]] [modifiers] theorem|lemma|def|abbrev|instance name
def any.prefix(ps: List<&2, List<&2, U32>>, +l: List<&2, U32>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> t:
      Bool.or(prefix(l, p), any.prefix(t, l))

def lean.line(+l: List<&2, U32>) -> Bool:
  Bool.or(indented(l), any.prefix(bs.of(["]", ")", "}", "⟩", "|", "termination_by", "decreasing_by"]), l))

def lean.next(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case l <> t:
      lean.line(l)

def lean.ok(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(lean.line(l), Bool.and(blank(l), lean.next(t)))

# lines of the declaration after its first (trailing blank lines not counted)
def lean.go(ls: List<&2, List<&2, U32>>, +k: Nat, +last: Nat, ok: Bool) -> Nat:
  match ls ok:
    case +l <> +t True{}:
      lean.go(t, 1n+k, Bool.pick(Nat, blank(l), last, 1n+k), lean.ok(t))
    case _ _:
      last

def lean.len(+ls: List<&2, List<&2, U32>>) -> Nat:
  lean.go(ls, 0n, 0n, lean.next(ls))

def drop.attr(+l: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, prefix(l, b("@[")), trim.left(List.drop(&2, U32, l, 1n+find(l, b("]"), 0n))), l)

def drop.mods(fuel: Nat, +l: List<&2, U32>) -> List<&2, U32>:
  match fuel:
    case 0n:
      l
    case 1n+p:
      Bool.pick(List<&2, U32>, member(bs.of(["private", "protected", "noncomputable", "nonrec", "partial", "unsafe", "scoped", "local"]), word0(l)), drop.mods(p, after0(l)), l)

def lean.start(+l: List<&2, U32>, +m: List<&2, U32>) -> Bool:
  Bool.and(col0(l), Bool.and(member(bs.of(["theorem", "lemma", "def", "abbrev", "instance"]), word0(m)), name.start(name.cut(after0(m)))))

# split at the first ":=" outside brackets (hole: " _"); failing that before
# the first "\n  |" (pattern-matching equations; no hole)
def hit.lean.split(none: Bool, +i: Nat, +n: Nat, +name: List<&2, U32>, +kind: List<&2, U32>, +doc: List<&2, U32>, +text: List<&2, U32>, +k: Nat) -> Hit:
  match none:
    case False{}:
      +sig = trim.right(List.take(&2, U32, text, k))
      hit.fin(Bool.and(typed(sig), Bool.not(infix(sig, b(" where")))), Hit{i, n, name, kind, doc, sig, List.take(&2, U32, text, Nat.add(k, 2n)), List.drop(&2, U32, text, Nat.add(k, 2n)), b(" _\n")})
    case True{}:
      +p = find(text, b("\n  |"), 0n)
      +sig = trim.right(List.take(&2, U32, text, p))
      hit.fin(Bool.and(Nat.is_lt(p, len(text)), typed(sig)), Hit{i, n, name, kind, doc, sig, List.take(&2, U32, text, p), List.drop(&2, U32, text, p), Nil{}})

def hit.lean.if(ok: Bool, +rest: List<&2, List<&2, U32>>, +above: List<&2, List<&2, U32>>, +i: Nat, +name: List<&2, U32>, +kw: List<&2, U32>) -> Hit:
  match ok:
    case False{}:
      No{}
    case True{}:
      +n : Nat = 1n+lean.len(List.drop(&2, List<&2, U32>, rest, 1n))
      +text = slice(rest, 0n, n)
      +k = assign.at(text)
      +kind = Bool.pick(List<&2, U32>, Bool.or(eq(kw, b("theorem")), eq(kw, b("lemma"))), b("proposition"), b("type"))
      hit.lean.split(Nat.is_eq(k, 0n), i, n, name, kind, doc.lean(above), text, k)

# bend: `law name:` and the `def name(` proving it, or `def name(...) -> T:`
def hit.law(+rest: List<&2, List<&2, U32>>, +above: List<&2, List<&2, U32>>, +i: Nat, +name: List<&2, U32>) -> Hit:
  +nl : Nat = 1n+eq.len(0n, Nil{}, List.drop(&2, List<&2, U32>, rest, 1n))
  +after = List.drop(&2, List<&2, U32>, rest, nl)
  +nbl = blank.run.go(after, head.blank(after))
  +dr = List.drop(&2, List<&2, U32>, rest, Nat.add(nl, nbl))
  +dl = nth(dr, 0n)
  +nd : Nat = 1n+eq.len(0n, Nil{}, List.drop(&2, List<&2, U32>, dr, 1n))
  +ok = prefix(dl, append(b("def "), append(name, b("("))))
  hit.fin(ok, Hit{i, Nat.add(Nat.add(nl, nbl), nd), name, b("proposition"), doc.bend(above), trim.right(slice(rest, 0n, nl)), slice(rest, 0n, Nat.add(nl, nbl)), slice(dr, 0n, nd), append(dl, b("  ?goal\n"))})

def hit.def(+rest: List<&2, List<&2, U32>>, +above: List<&2, List<&2, U32>>, +i: Nat, +name: List<&2, U32>) -> Hit:
  +nb = eq.len(0n, Nil{}, List.drop(&2, List<&2, U32>, rest, 1n))
  +l = nth(rest, 0n)
  hit.fin(Bool.not(Nat.is_eq(nb, 0n)), Hit{i, 1n+nb, name, b("type"), doc.bend(above), trim.right(l), l, slice(rest, 1n, 1n+nb), b("  ?goal\n")})

def hit.bend(isl: Bool, df: Bool, +rest: List<&2, List<&2, U32>>, +above: List<&2, List<&2, U32>>, +i: Nat, +name: List<&2, U32>) -> Hit:
  match isl df:
    case True{} _:
      hit.law(rest, above, i, name)
    case False{} True{}:
      hit.def(rest, above, i, name)
    case False{} False{}:
      No{}

def hit.at(+lang: Nat, +id: List<&2, U32>, +l: List<&2, U32>, +rest: List<&2, List<&2, U32>>, +above: List<&2, List<&2, U32>>, +i: Nat) -> Hit:
  match lang:
    case 0n:
      hit.eqs.if(hs.start(l), 0n, id, rest, above, i, 0n, word0(l))
    case 1n:
      hit.eqs.if(agda.start(l), 1n, id, rest, above, i, indent(l), word0(trim.left(l)))
    case 2n:
      +m = drop.mods(4n, drop.attr(l))
      hit.lean.if(lean.start(l, m), rest, above, i, name.cut(after0(m)), word0(m))
    case 3n:
      hit.bend(prefix(l, b("law ")), Bool.and(prefix(l, b("def ")), infix(l, b(") -> "))), rest, above, i, name.cut(after0(l)))
    case _:
      No{}

def walk(ls: List<&2, List<&2, U32>>, +lang: Nat, +id: List<&2, U32>, +above: List<&2, List<&2, U32>>, +i: Nat, acc: List<&2, Hit>) -> List<&2, Hit>:
  match ls:
    case Nil{}:
      List.reverse(&2, Hit, acc)
    case +l <> +t:
      walk(t, lang, id, l <> above, 1n+i, hit.push(hit.at(lang, id, l, l <> t, above, i), acc))

# nix: the whole file
def nix.hit(+ls: List<&2, List<&2, U32>>, +text: List<&2, U32>) -> Hit:
  Hit{0n, lines.count(ls), b("file"), Nil{}, doc.nix(ls), Nil{}, Nil{}, text, Nil{}}

def scan(nix: Bool, +lang: Nat, +id: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +text: List<&2, U32>) -> List<&2, Hit>:
  match nix:
    case True{}:
      hit.push(nix.hit(ls, text), Nil{})
    case False{}:
      walk(ls, lang, id, Nil{}, 0n, Nil{})

# at most maxn hits (0: all), evenly spread over the file, the offset chosen
# by the file's id
def choose.go(hs: List<&2, Hit>, +k: Nat, +stride: Nat, +r: Nat, +left: Nat, acc: List<&2, Hit>) -> List<&2, Hit>:
  match hs:
    case Nil{}:
      List.reverse(&2, Hit, acc)
    case h <> t:
      +keep = Bool.and(Nat.is_eq(Nat.mod(k, stride), r), Bool.not(Nat.is_eq(left, 0n)))
      choose.go(t, 1n+k, stride, r, Bool.pick(Nat, keep, Nat.sub(left, 1n), left), keep.hit(keep, h, acc))

def choose(+hs: List<&2, Hit>, +maxn: Nat, +off: Nat) -> List<&2, Hit>:
  +n = List.length(&2, Hit, hs)
  +all = Bool.or(Nat.is_eq(maxn, 0n), Nat.is_le(n, maxn))
  +stride = Bool.pick(Nat, all, 1n, Nat.div(n, 1n+Nat.sub(maxn, 1n)))
  choose.go(hs, 0n, stride, Nat.mod(off, stride), Bool.pick(Nat, all, n, maxn), Nil{})

# Mutants ---------------------------------------------------------------------------
#
# Positions come from FNV-1a (32-bit) of the unit's id and a salt.

def fnv32.go(bs: List<&2, U32>, h: U32) -> U32:
  match bs:
    case Nil{}:
      h
    case x <> t:
      fnv32.go(t, U32.mul(U32.xor(h, x), 16777619))

def fnv32(bs: List<&2, U32>) -> U32:
  fnv32.go(bs, 2166136261)

def pick.at(+id: List<&2, U32>, +salt: Nat, +n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      Nat.mod(U32.to_nat(fnv32(append(id, b(Nat.show(salt))))), 1n+p)

def seg.word(+s: Seg) -> Bool:
  match s:
    case Seg{w, l, bs}:
      Bool.and(w, Bool.not(l))

def seg.bytes(+s: Seg) -> List<&2, U32>:
  match s:
    case Seg{w, l, bs}:
      bs

def seg.get(+ss: List<&2, Seg>, +k: Nat) -> Seg:
  Maybe.default(&2, Seg, List.get(&2, Seg, ss, k), Seg{False{}, False{}, Nil{}})

# mode 0: a name the body uses (to be replaced by another); 1: a word with a
# word after it on the same line (to be swapped with it); 2: any word (to be
# dropped). Never a word at column 0.
def cand.ok(+mode: Nat, +nm: List<&2, List<&2, U32>>, +s: Seg, +t: List<&2, Seg>) -> Bool:
  match mode:
    case 0n:
      Bool.and(seg.word(s), member(nm, unmark(seg.bytes(s))))
    case 1n:
      +v = seg.get(t, 1n)
      Bool.and(Bool.and(seg.word(s), seg.word(v)), Bool.and(Bool.not(has(seg.bytes(seg.get(t, 0n)), 10)), Bool.not(eq(seg.bytes(s), seg.bytes(v)))))
    case _:
      seg.word(s)

def push.if(ok: Bool, x: Nat, xs: List<&2, Nat>) -> List<&2, Nat>:
  match ok:
    case True{}:
      x <> xs
    case False{}:
      xs

# armed: past the first line (bend's first line is the def's own header)
def cands(ss: List<&2, Seg>, +mode: Nat, +nm: List<&2, List<&2, U32>>, +armed: Bool, +k: Nat, acc: List<&2, Nat>) -> List<&2, Nat>:
  match ss:
    case Nil{}:
      List.reverse(&2, Nat, acc)
    case +s <> +t:
      +on = Bool.or(armed, Bool.and(Bool.not(seg.word(s)), has(seg.bytes(s), 10)))
      cands(t, mode, nm, on, 1n+k, push.if(Bool.and(armed, cand.ok(mode, nm, s, t)), k, acc))

def mutant.segs(+mode: Nat, +ss: List<&2, Seg>, +k: Nat, +nm: List<&2, List<&2, U32>>, +id: List<&2, U32>, +salt: Nat) -> List<&2, Seg>:
  match mode:
    case 0n:
      +w = seg.bytes(seg.get(ss, k))
      +u = unmark(w)
      +m = List.length(&2, List<&2, U32>, nm)
      +q = pick.at(id, Nat.add(salt, 10n), m)
      +r0 = nth(nm, q)
      +r = Bool.pick(List<&2, U32>, eq(r0, u), nth(nm, Nat.mod(1n+q, 1n+Nat.sub(m, 1n))), r0)
      List.set(&2, Seg, ss, k, Seg{True{}, False{}, append(List.take(&2, U32, w, Nat.sub(len(w), len(u))), r)})
    case 1n:
      List.set(&2, Seg, List.set(&2, Seg, ss, k, seg.get(ss, Nat.add(k, 2n))), Nat.add(k, 2n), seg.get(ss, k))
    case _:
      List.set(&2, Seg, ss, k, Seg{True{}, False{}, Nil{}})

def mutant.of(none: Bool, +mode: Nat, +ss: List<&2, Seg>, +k: Nat, +nm: List<&2, List<&2, U32>>, +id: List<&2, U32>, +salt: Nat) -> List<&2, U32>:
  match none:
    case True{}:
      Nil{}
    case False{}:
      segs.join(mutant.segs(mode, ss, k, nm, id, salt))

# the body with one change (empty: no position for this mode)
def mutant(+mode: Nat, +lang: Nat, +id: List<&2, U32>, +salt: Nat, +body: List<&2, U32>, +nm: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +ss = mask(lang, body)
  +cs = cands(ss, mode, nm, Bool.not(Nat.is_eq(lang, 3n)), 0n, Nil{})
  +n = List.length(&2, Nat, cs)
  +k = Maybe.default(&2, Nat, List.get(&2, Nat, cs, pick.at(id, salt, n)), 0n)
  mutant.of(Nat.is_eq(n, 0n), mode, ss, k, nm, id, salt)

# mutants that are not empty, not the body and not repeated
def dedup(+body: List<&2, U32>, ms: List<&2, List<&2, U32>>, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ms:
    case Nil{}:
      List.reverse(&2, List<&2, U32>, seen)
    case +m <> t:
      +drop = Bool.or(Bool.or(Nat.is_eq(len(m), 0n), eq(m, body)), member(seen, m))
      dedup(body, t, Bool.pick(List<&2, List<&2, U32>>, drop, seen, m <> seen))

def mutants(+lang: Nat, +id: List<&2, U32>, +body: List<&2, U32>, +nm: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  dedup(body, [mutant(0n, lang, id, 1n, body, nm), mutant(0n, lang, id, 2n, body, nm), mutant(1n, lang, id, 3n, body, nm), mutant(2n, lang, id, 4n, body, nm)], Nil{})

# Records ---------------------------------------------------------------------------

def sep.more(xs: List<&2, List<&2, U32>>, +s: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      s <> append(x, sep.more(t, s))

def sep.join(xs: List<&2, List<&2, U32>>, +s: U32) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      append(x, sep.more(t, s))

def lang.names() -> List<&2, List<&2, U32>>:
  bs.of(["haskell", "agda", "lean", "bend", "nix"])

def lang.code.go(ns: List<&2, List<&2, U32>>, +w: List<&2, U32>, +k: Nat) -> Nat:
  match ns:
    case Nil{}:
      k
    case n <> t:
      Bool.pick(Nat, eq(n, w), k, lang.code.go(t, w, 1n+k))

def lang.code(s: String) -> Nat:
  lang.code.go(lang.names(), b(s), 0n)

def build(h: Hit, +lang: Nat, +id: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +nl: Nat) -> List<&2, Ns.Doc>:
  match h:
    case No{}:
      Nil{}
    case Hit{+at, n, +name, kind, doc, sig, pre, +body, hole}:
      +nm = names(lang, name, body)
      +uid = concat([id, b("#"), name, b("@"), b(Nat.show(1n+at))])
      +head = slice(ls, 0n, at)
      +tail = slice(ls, Nat.add(at, n), nl)
      +fields : List<&2, List<&2, U32>> = [nth(lang.names(), lang), kind, name, trim.right(drop.all.space(doc)), sig, head, pre, body, tail, sep.join(nm, 32), hole]
      [Ns.Doc{uid, sep.join(List.append(&2, List<&2, U32>, fields, mutants(lang, uid, body, nm)), 30)}]

def builds(hs: List<&2, Hit>, +lang: Nat, +id: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +nl: Nat) -> List<&2, Ns.Doc>:
  match hs:
    case Nil{}:
      Nil{}
    case h <> t:
      List.append(&2, Ns.Doc, build(h, lang, id, ls, nl), builds(t, lang, id, ls, nl))

def units.lines(ok: Bool, +lang: Nat, +maxn: Nat, +id: List<&2, U32>, +ls: List<&2, List<&2, U32>>, +nl: Nat, +text: List<&2, U32>) -> List<&2, Ns.Doc>:
  match ok:
    case False{}:
      Nil{}
    case True{}:
      builds(choose(scan(Nat.is_eq(lang, 4n), lang, id, ls, text), maxn, U32.to_nat(fnv32(id))), lang, id, ls, nl)

# a file holding the record separators, or longer than 2,000 lines, gives none
def units.plain(+lang: Nat, +maxn: Nat, +id: List<&2, U32>, +text: List<&2, U32>) -> List<&2, Ns.Doc>:
  +ls = lines(text)
  +nl = lines.count(ls)
  units.lines(Bool.and(Nat.is_le(nl, 2000n), Bool.not(Bool.or(has(text, 30), has(text, 31)))), lang, maxn, id, ls, nl, text)

# a literate file's units are those of the plain Agda it means (above), so
# their head ++ pre ++ body ++ tail is that plain file
def units.file(+lang: Nat, +maxn: Nat, +id: List<&2, U32>, +text: List<&2, U32>) -> List<&2, Ns.Doc>:
  units.plain(lang, maxn, id, unlit(lit.kind(lang, id), text))

def units.all(+lang: Nat, +maxn: Nat, fs: List<&2, Ns.Doc>) -> List<&2, Ns.Doc>:
  match fs:
    case Nil{}:
      Nil{}
    case Ns.Doc{i, t} <> more:
      List.append(&2, Ns.Doc, units.file(lang, maxn, i, t), units.all(lang, maxn, more))

# Main ------------------------------------------------------------------------------

def emit(+lang: Nat, +maxn: Nat, out: String, +d: Ns.Docs, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "units: " ++ Ns.Docs.problem(d))
    case True{}:
      +fs = Ns.Docs.docs(d)
      +us = units.all(lang, maxn, fs)
      do IO<Unit>:
        Ns.write(out, Ns.put(us, Nil{}))
        IO.print("units: " ++ Nat.show(List.length(&2, Ns.Doc, fs)) ++ " files in, " ++ Nat.show(List.length(&2, Ns.Doc, us)) ++ " units out")

def run(+lang: Nat, +maxn: Nat, inp: String, out: String, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 2, "units: LANG is haskell, agda, lean, bend or nix")
    case True{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- Ns.read(inp)
        +d : Ns.Docs <- IO.pure(Ns.Docs, Ns.docs(xs))
        emit(lang, maxn, out, d, String.is_empty(Ns.Docs.problem(d)))

def max.of(xs: List<String>) -> Nat:
  match xs:
    case Nil{}:
      4n
    case x <> t:
      Maybe.default(&2, Nat, Nat.read(x), 4n)

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case l <> inp <> out <> more:
      +k = lang.code(l)
      run(k, max.of(more), inp, out, Nat.is_lt(k, 5n))
    case _:
      IO.die(Unit, 2, "usage: bend-units LANG INPUT.nul OUTPUT.nul [MAX_PER_FILE]")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
