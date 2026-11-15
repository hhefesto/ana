import Base
import ./Sys.bend as S

# theory-cut: R7's theory prose as filler pieces (change 7, docs/r7/PLAN.md, 2026-11-15).
# The user, 11-12: "I want ana to also be knowledgeable on the theory behind the code. Use
# category theory, type theory and in general math prose that helps in proofs with dependent
# types"; "All of them, credited, as Proof-Pile-2 did: nLab, and the arXiv papers under arXiv's
# default license"; "also add all the theory/prose you can find in denotational semantics and
# similar"; "Also use anything you can find in formal verification".  11-14: at most 2-3 copies
# of a code file, so the windows' ends need other text: this.
#
#   bend-theory-cut IN OUT
#
# IN: NUL pairs (id, text), a document each (run/v9/theory/filler.sh writes them: arXiv:ID for a
# Proof-Pile-2 paper theory-pick kept, nlab:NAME for an nLab page, SOURCE:PATH for a book's file).
# OUT: NUL pairs (id#k, piece), the filler files of the prose language, and OUT.stats.
#
# Meaning.  A document's lines, less the ones that are not prose: a LaTeX comment (its first
# non-blank byte `%`), nLab's layout (`+--`, `=--`, `[[!`, `{:`, `{#`, `* table of contents`,
# `#Contents#`, `###Context###`, after leading blanks) and any line over 4096 bytes.  Its
# paragraphs: the runs of the lines left that are not blank.  Its pieces: the paragraphs in order,
# packed while the piece stays within thc.lim(k) bytes (k the piece's index: 0.5, 1, 1.5, 2, 3, 4
# and 6 KiB in turn, so a window's gap of any size finds a piece that fits it best, PlanWindows.bend's
# best fit); a paragraph longer than that is a piece alone; joined by a blank line, ending in a
# newline.  A piece under 256 bytes is left out.  Nothing is changed inside a line.

# a document's line: 0 blank, 1 left out, 2 prose
type Ln is Data:
  Ln{k: Nat, l: List<&2, U32>}

# the counts: documents, their bytes, pieces kept, short pieces left out, the kept pieces' bytes
type Thc is Data:
  Thc{docs: Nat, inb: Nat, pieces: Nat, short: Nat, outb: Nat}

def thc.b(s: String) -> List<&2, U32>:
  S.b(s)

# the line from its first byte that is not a space or a tab
def thc.blank(+xs: List<&2, U32>) -> Bool:
  Bool.or(S.head.is(xs, 32), S.head.is(xs, 9))

def thc.trim.go(xs: List<&2, U32>, b: Bool) -> List<&2, U32>:
  match xs b:
    case Nil{} _:
      Nil{}
    case c <> +t True{}:
      thc.trim.go(t, thc.blank(t))
    case c <> t False{}:
      c <> t

def thc.trim(+xs: List<&2, U32>) -> List<&2, U32>:
  thc.trim.go(xs, thc.blank(xs))

def thc.any(+l: List<&2, U32>, ps: List<&2, String>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case +p <> t:
      Bool.or(S.prefix(l, thc.b(p)), thc.any(l, t))

def thc.layout() -> List<&2, String>:
  ["%", "+--", "=--", "[[!", "{:", "{#", "* table of contents", "#Contents#", "###Context###"]

def thc.kind(+l: List<&2, U32>) -> Nat:
  +x = thc.trim(l)
  Bool.pick(Nat, Nat.is_eq(S.len(x), 0n), 0n,
    Bool.pick(Nat, Bool.or(thc.any(x, thc.layout()), Nat.is_lt(4096n, S.len(l))), 1n, 2n))

def thc.marks(ls: List<&2, List<&2, U32>>) -> List<&2, Ln>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Ln{thc.kind(l), l} <> thc.marks(t)

# the run of lines so far (reversed) as a paragraph before rest; none when empty
def thc.flush(cur: List<&2, List<&2, U32>>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match cur:
    case Nil{}:
      rest
    case c <> t:
      S.join(List.reverse(&2, List<&2, U32>, c <> t), 10) <> rest

def thc.paras(ls: List<&2, Ln>, cur: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ls:
    case Nil{}:
      thc.flush(cur, Nil{})
    case Ln{0n, l} <> t:
      thc.flush(cur, thc.paras(t, Nil{}))
    case Ln{1n, l} <> t:
      thc.paras(t, cur)
    case Ln{_, l} <> t:
      thc.paras(t, l <> cur)

# a piece's bound, by its index (R6's windows left a gap of 482 tokens on average, about 1.6 KB, and
# each window takes one filler file's end: many small pieces, fewer large ones)
def thc.lim(+k: Nat) -> Nat:
  +m = Nat.mod(k, 7n)
  Bool.pick(Nat, Nat.is_eq(m, 0n), 512n,
    Bool.pick(Nat, Nat.is_eq(m, 1n), 1024n,
      Bool.pick(Nat, Nat.is_eq(m, 2n), 1536n,
        Bool.pick(Nat, Nat.is_eq(m, 3n), 2048n,
          Bool.pick(Nat, Nat.is_eq(m, 4n), 3072n,
            Bool.pick(Nat, Nat.is_eq(m, 5n), 4096n, 6144n))))))

# the paragraphs joined by blank lines, ending in a newline
def thc.glue(ps: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> Nil{}:
      S.append(p, [10])
    case p <> more:
      S.append(p, 10 <> 10 <> thc.glue(more))

def thc.out(acc: List<&2, List<&2, U32>>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match acc:
    case Nil{}:
      rest
    case a <> t:
      thc.glue(List.reverse(&2, List<&2, U32>, a <> t)) <> rest

# does the next paragraph go in the piece so far (n bytes; none yet: it does)
def thc.fits(+ps: List<&2, List<&2, U32>>, +n: Nat, +k: Nat) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case +p <> +t:
      Bool.or(Nat.is_eq(n, 0n), Bool.not(Nat.is_lt(thc.lim(k), Nat.add(Nat.add(n, 2n), S.len(p)))))

# Bend checks a def only against the defs above it, so the walk takes its decision for the head
# as a parameter (fit), computed for the next head by thc.fits
def thc.pack(ps: List<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>, +n: Nat, +k: Nat, fit: Bool) -> List<&2, List<&2, U32>>:
  match ps fit:
    case Nil{} _:
      thc.out(acc, Nil{})
    case +p <> +t True{}:
      thc.pack(t, p <> acc, Nat.add(Nat.add(n, 2n), S.len(p)), k, thc.fits(t, Nat.add(Nat.add(n, 2n), S.len(p)), k))
    case +p <> +t False{}:
      thc.out(acc, thc.pack(t, [p], S.len(p), 1n+k, thc.fits(t, S.len(p), 1n+k)))

# a document's pieces, short ones too
def thc.pieces(+t: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +ps = thc.paras(thc.marks(S.split(t, 10)), Nil{})
  thc.pack(ps, Nil{}, 0n, 0n, thc.fits(ps, 0n, 0n))

def thc.short(+p: List<&2, U32>) -> Bool:
  Nat.is_lt(S.len(p), 256n)

def thc.count(+c: Thc, +p: List<&2, U32>) -> Thc:
  match c:
    case Thc{d, i, n, s, o}:
      Bool.pick(Thc, thc.short(p), Thc{d, i, n, 1n+s, o}, Thc{d, i, 1n+n, s, Nat.add(o, S.len(p))})

def thc.one(o: File, +id: List<&2, U32>, +k: Nat, +p: List<&2, U32>, short: Bool) -> IO(File):
  match short:
    case True{}:
      IO.pure(File, o)
    case False{}:
      S.emit(o, S.append(id, S.append(35 <> thc.b(Nat.show(k)), 0 <> S.append(p, [0]))))

def thc.emit(ps: List<&2, List<&2, U32>>, o: File, +id: List<&2, U32>, +k: Nat, +c: Thc) -> IO(File & Thc):
  match ps:
    case Nil{}:
      IO.pure(File & Thc, (o, c))
    case +p <> t:
      IO.bind(File, File & Thc, thc.one(o, id, k, p, thc.short(p)), o2 => thc.emit(t, o2, id, 1n+k, thc.count(c, p)))

def thc.doc(+c: Thc, +t: List<&2, U32>) -> Thc:
  match c:
    case Thc{d, i, n, s, o}:
      Thc{1n+d, Nat.add(i, S.len(t)), n, s, o}

type ThcS is Type:
  ThcS{r: S.Rd, o: File, c: Thc, more: Bool}

def thc.put(r: S.Rd, x: File & Thc) -> IO(ThcS):
  (o, c) = x
  IO.pure(ThcS, ThcS{r, o, c, True{}})

def thc.text(o: File, +c: Thc, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ThcS):
  (r, m) = x
  match m:
    case None{}:
      IO.die(ThcS, 1, "theory-cut: an id with no text")
    case Some{+t}:
      IO.bind(File & Thc, ThcS, thc.emit(thc.pieces(t), o, id, 0n, thc.doc(c, t)), thc.put(r))

def thc.id(r: S.Rd, o: File, +c: Thc, m: Maybe<&2, List<&2, U32>>) -> IO(ThcS):
  match m:
    case None{}:
      IO.pure(ThcS, ThcS{r, o, c, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, ThcS, S.Rd.next(r), thc.text(o, c, id))

def thc.got(o: File, +c: Thc, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(ThcS):
  (r, m) = x
  thc.id(r, o, c, m)

def thc.step(s: ThcS) -> IO(ThcS):
  match s:
    case ThcS{r, o, c, g}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, ThcS, S.Rd.next(r), thc.got(o, c))

def thc.go(fuel: Nat, s: ThcS) -> IO(ThcS):
  match fuel s:
    case 1n+f ThcS{r, o, c, True{}}:
      IO.bind(ThcS, ThcS, thc.step(ThcS{r, o, c, True{}}), thc.go(f))
    case _ s2:
      IO.pure(ThcS, s2)

def thc.show(+c: Thc) -> String:
  match c:
    case Thc{d, i, n, s, o}:
      "docs " ++ Nat.show(d) ++ "\nbytes-in " ++ Nat.show(i) ++ "\npieces " ++ Nat.show(n) ++ "\nshort " ++ Nat.show(s) ++ "\nbytes-out " ++ Nat.show(o) ++ "\n"

def thc.fin(+out: String, s: ThcS) -> IO(Unit):
  match s:
    case ThcS{r, o, +c, g}:
      do IO<Unit>:
        S.Rd.close(r)
        File.close(o)
        S.write(out ++ ".stats", thc.b(thc.show(c)))
        IO.print(S.str(S.chomp(thc.b(thc.show(c)))))

def thc.run(+inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    r : S.Rd <- S.Rd.open(inp)
    o : File <- IO.try(File, File.open(out, "w"))
    s : ThcS <- thc.go(U32.to_nat(4294967295), ThcS{r, o, Thc{0n, 0n, 0n, 0n, 0n}, True{}})
    thc.fin(out, s)

def thc.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +i <> +o <> Nil{}:
      thc.run(i, o)
    case _:
      IO.die(Unit, 2, "usage: bend-theory-cut IN OUT")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    thc.main(xs)
