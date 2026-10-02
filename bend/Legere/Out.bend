import Base
import ../Sys.bend as S
import ../Units.bend as U
import ./Spec.bend as Sp
import ./Tags.bend as Tg
import ./Lines.bend as Li
import ./Model.bend as Mo

# What `bend-legere segment` writes for one document: its sections, the
# code among them (wrapped for its checker), and the prose before each
# piece of code (the transcript's User line).
#
# A section's share of tag u is the mean, over its lines, of P(line has u |
# text): the expected fraction of its lines with tag u, a distribution over
# u (not the joint probability that every line has u, which DocJev's page
# mean is often mistaken for).

type Lp is Data:
  Lp{line: List<&2, U32>, post: List<&2, F32>}

def lps(pls: List<&2, Mo.Pl>, ls: List<&2, List<&2, U32>>) -> List<&2, Sp.Ln<Lp>>:
  match pls ls:
    case Mo.Pl{g, m, p, v} <> pt l <> lt:
      Sp.Ln{v, Lp{l, p}} <> lps(pt, lt)
    case _ _:
      Nil{}

def body(xs: List<&2, Lp>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case Lp{l, p} <> t:
      S.append(l, body(t))

def share.sum(xs: List<&2, Lp>, +u: Nat) -> F32:
  match xs:
    case Nil{}:
      0.0
    case Lp{l, p} <> t:
      F32.add(F32.exp(Mo.at(p, u)), share.sum(t, u))

def share(+xs: List<&2, Lp>, +u: Nat) -> F32:
  F32.div(share.sum(xs, u), F32.max(1.0, F32.from_nat(List.length(&2, Lp, xs))))

# "tag:share" for each tag with at least 0.01, in tag order
def shares.go(+xs: List<&2, Lp>, ts: List<&2, Nat>) -> String:
  match ts:
    case Nil{}:
      ""
    case +u <> rest:
      +s = share(xs, u)
      Bool.pick(String, F32.is_le(0.01, s), " " ++ Tg.name(u) ++ ":" ++ F32.show(F32.div(F32.round(F32.mul(s, 1000.0)), 1000.0)), "") ++ shares.go(xs, rest)

def shares(+xs: List<&2, Lp>) -> String:
  shares.go(xs, List.range(Tg.k()))

# The User line ---------------------------------------------------------------

# a paragraph that is only headings or tool cues says nothing to ask
def cue.line(+l: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(S.prefix(l, S.b("#")), S.prefix(l, S.b("**stdout:**"))), Bool.or(S.prefix(l, S.b("**stderr:**")), S.prefix(l, S.b("*(thought for"))))

def all.cue(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      True{}
    case +l <> t:
      Bool.and(Bool.or(U.blank(l), cue.line(l)), all.cue(t))

def nonempty(+xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case x <> t:
      True{}

# Scanning the lines backwards: the last paragraph (a run between blank
# lines) that is not only headings and cues.  stop: the paragraph in cur is
# the answer.
def last.go(rs: List<&2, List<&2, U32>>, +cur: List<&2, List<&2, U32>>, stop: Bool) -> List<&2, List<&2, U32>>:
  match rs stop:
    case +l <> t False{}:
      +done = Bool.and(U.blank(l), Bool.and(nonempty(cur), Bool.not(all.cue(cur))))
      +keep = Bool.pick(List<&2, List<&2, U32>>, U.blank(l), Bool.pick(List<&2, List<&2, U32>>, done, cur, Nil{}), l <> cur)
      last.go(t, keep, done)
    case _ _:
      Bool.pick(List<&2, List<&2, U32>>, all.cue(cur), Nil{}, cur)

def join(ls: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      S.append(l, join(t))

# the User line: the last such paragraph of the prose, its last 1 KB
def user(+prose: List<&2, U32>) -> List<&2, U32>:
  +p = Li.trim(join(last.go(List.reverse(&2, List<&2, U32>, Li.lines(prose)), Nil{}, False{})))
  +n = S.len(p)
  List.drop(&2, U32, p, Nat.sub(n, 1024n))

# Wrapping code for its checker ----------------------------------------------
#
# Haskell: bend-check skips a file with no `module` line (a Main module
# needs main), so a snippet without one gets `module Snippet where`.  The
# others are checked as they stand.
def has.module(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(S.prefix(l, S.b("module ")), has.module(t))

# the leading pragma lines ({-# ... #-}, blank lines between) and the rest;
# go: the head of ls is one
def is.pragma(+ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case +l <> t:
      Bool.or(S.prefix(l, S.b("{-#")), U.blank(l))
    case Nil{}:
      False{}

def head.pragmas(+ls: List<&2, List<&2, U32>>, +acc: List<&2, U32>, go: Bool) -> List<&2, U32> & List<&2, List<&2, U32>>:
  match ls go:
    case l <> +t True{}:
      head.pragmas(t, S.append(acc, l), is.pragma(t))
    case _ _:
      (acc, ls)

def wrap.after(r: List<&2, U32> & List<&2, List<&2, U32>>) -> List<&2, U32>:
  (pre, rest) = r
  S.append(pre, S.append(S.b("module Snippet where\n\n"), join(rest)))

# a Haskell snippet with no module line gets one after its pragmas
def wrap(+t: Nat, +code: List<&2, U32>) -> List<&2, U32>:
  +ls = Li.lines(code)
  Bool.pick(List<&2, U32>, Bool.and(Nat.is_eq(t, 1n), Bool.not(has.module(ls))), wrap.after(head.pragmas(ls, Nil{}, is.pragma(ls))), code)

# The session converter elides the middle of a long file ("… (132 lines
# elided) …"): such a section is not the file, and is not checked.
def elided(ls: List<&2, List<&2, U32>>) -> Bool:
  match ls:
    case Nil{}:
      False{}
    case +l <> t:
      Bool.or(Bool.and(S.prefix(l, S.b("… (")), S.infix(l, S.b("lines elided"))), elided(t))

def ext(+t: Nat) -> String:
  match t:
    case 1n:
      ".hs"
    case 2n:
      ".agda"
    case 3n:
      ".lean"
    case 4n:
      ".bend"
    case 5n:
      ".nix"
    case _:
      ".txt"

# A document's output ------------------------------------------------------------

# a piece of code to check: its tag, its file id under BEND_SRC-style
# naming (own:legere/DOC-K.EXT), the wrapped code and its User line
type Ce is Data:
  Ce{t: Nat, id: List<&2, U32>, code: List<&2, U32>, user: List<&2, U32>}

def sep() -> List<&2, U32>:
  [30]

def nul() -> List<&2, U32>:
  [0]

def record(+id: List<&2, U32>, +k: Nat, +t: Nat, +first: Nat, +n: Nat, +sh: String, +b: List<&2, U32>) -> List<&2, U32>:
  S.append(id, S.append(S.b("#" ++ Nat.show(k)), S.append(nul(),
    S.append(S.b(Tg.name(t)), S.append(sep(), S.append(S.b(Nat.show(first)), S.append(sep(), S.append(S.b(Nat.show(n)),
      S.append(sep(), S.append(S.b(sh), S.append(sep(), S.append(b, nul()))))))))))))

def is.code(+t: Nat, +xs: List<&2, Lp>) -> Bool:
  Bool.and(Bool.and(Bool.and(Nat.is_le(1n, t), Nat.is_le(t, 5n)), F32.is_le(0.9, share(xs, t))), Bool.not(elided(Li.lines(body(xs)))))

def code.put(take: Bool, +id: List<&2, U32>, +k: Nat, +t: Nat, +b: List<&2, U32>, +prose: List<&2, U32>, acc: List<&2, Ce>) -> List<&2, Ce>:
  match take:
    case True{}:
      Ce{t, S.append(S.b("own:legere/"), S.append(id, S.b("-" ++ Nat.show(k) ++ ext(t)))), wrap(t, b), user(prose)} <> acc
    case False{}:
      acc

# every section's record (newest first) and the code to check
def doc.go(secs: List<&2, Sp.Sec<Lp>>, +id: List<&2, U32>, +k: Nat, +first: Nat, +prose: List<&2, U32>,
    sacc: List<&2, List<&2, U32>>, cacc: List<&2, Ce>) -> List<&2, List<&2, U32>> & List<&2, Ce>:
  match secs:
    case Nil{}:
      (sacc, cacc)
    case Sp.Sec{+t, +xs} <> rest:
      +b = body(xs)
      +n = List.length(&2, Lp, xs)
      doc.go(rest, id, 1n+k, Nat.add(first, n), Bool.pick(List<&2, U32>, Bool.and(Nat.is_eq(t, 0n), Bool.not(S.eq(user(b), Nil{}))), b, prose),
        record(id, k, t, first, n, shares(xs), b) <> sacc, code.put(is.code(t, xs), id, k, t, b, prose, cacc))

# a document's sections from its answers and lines
def sections(pls: List<&2, Mo.Pl>, ls: List<&2, List<&2, U32>>) -> List<&2, Sp.Sec<Lp>>:
  Sp.sections(Lp, lps(pls, ls))

# the text the sections give back (law roundtrip: the document's text)
def text.of(secs: List<&2, Sp.Sec<Lp>>) -> List<&2, U32>:
  match secs:
    case Nil{}:
      Nil{}
    case Sp.Sec{t, xs} <> rest:
      S.append(body(xs), text.of(rest))
