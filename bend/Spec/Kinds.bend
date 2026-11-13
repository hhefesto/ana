import Base

# Form 2's new kinds of session (docs/form2/KINDS.md; the user, 11-13: the
# prose in the request and as a `#` comment ana writes, helpers first, example
# laws), stated first as what they mean, then as functions, then the laws.
#
# A direct session hands ana a file and asks for a definition.  Until 11-13
# the file was the unit's head (every line above the definition) and her one
# `## add` wrote the definition alone.  Now the head is cut at a line c: the
# file she reads is the lines before c, and her add writes the lines from c on
# (the definitions right above hers that it calls, each with its comment, and
# her own comment), then her definition and its laws.  So the file her add
# leaves is the unit's file, line for line, and the check recorded for the unit
# is the check of that file: no checker runs for a cut.  That is the law
# `cut_join`: whatever c is, the lines before it and the lines from it are the
# head.
#
# Which c: a gap's trailing comment lines (`#` at column 0, no blank line
# between them and the head below) belong to the piece below; the pieces
# taken are the ones at the end of the head the definition calls, through one
# another, at most 3 (8 when they reach the file's first definition).  That
# choice is the renderer's (Transcript.bend "Form 2's kinds"); `cut_join`
# holds for any choice.

def take(-A: Data, n: Nat, xs: List<&2, A>) -> List<&2, A>:
  match n xs:
    case 0n _:
      Nil{}
    case 1n+k Nil{}:
      Nil{}
    case 1n+k h <> t:
      h <> take(A, k, t)

def drop(-A: Data, n: Nat, xs: List<&2, A>) -> List<&2, A>:
  match n xs:
    case 0n _:
      xs
    case 1n+k Nil{}:
      Nil{}
    case 1n+k h <> t:
      drop(A, k, t)

def len(-A: Data, xs: List<&2, A>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      1n+len(A, t)

# the file ana reads and her add's text: the head cut at line c
def cut(-A: Data, +xs: List<&2, A>, +c: Nat) -> List<&2, A> & List<&2, A>:
  (take(A, c, xs), drop(A, c, xs))

def join(-A: Data, p: List<&2, A> & List<&2, A>) -> List<&2, A>:
  match p:
    case (a, b):
      List.append(&2, A, a, b)

# The laws -----------------------------------------------------------------------

def take_drop(-A: Data, n: Nat, xs: List<&2, A>) -> {List.append(&2, A, take(A, n, xs), drop(A, n, xs)) == xs : List<&2, A>}:
  match n xs:
    case 0n _:
      {==}
    case 1n+k Nil{}:
      {==}
    case 1n+k +h <> t:
      %take_drop(A, k, t) : {h <> List.append(&2, A, take(A, k, t), drop(A, k, t)) == h <> _ : List<&2, A>}
      {==}


law cut_join:
  for -A: Data
  for xs: List<&2, A>
  for c: Nat
  {join(A, cut(A, xs, c)) == xs : List<&2, A>}

def cut_join(A, xs, c):
  take_drop(A, c, xs)

# An example, computed: a head whose last definition the function calls, cut
# before that definition's comment.

def ex.head() -> List<&2, String>:
  ["import Base", "", "# one more", "def inc(n: Nat) -> Nat:", "  1n+n", ""]

law check.kinds.example:
  {cut(String, ex.head(), 2n) == (["import Base", ""], ["# one more", "def inc(n: Nat) -> Nat:", "  1n+n", ""]) : List<&2, String> & List<&2, String>}
  & {join(String, cut(String, ex.head(), 2n)) == ex.head() : List<&2, String>}

def check.kinds.example():
  ({==}, {==})
