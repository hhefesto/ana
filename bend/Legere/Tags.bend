import Base
import ../Sys.bend as S

# ana's tags, as legere's line labels.  The five checkable languages are the
# fence languages of ana's transcripts (docs/TRANSCRIPT-FORMAT.md); the rest
# are what a coding session holds besides them.
#
#    0 prose     1 haskell   2 agda    3 lean    4 bend    5 nix
#    6 shell     7 diff      8 output  9 code (any other language)
#   10 open      11 close    (a fence's opening and closing lines)
#
# Tags 0..9 are scored by a line model (Legere/Ngram.bend); open and close
# weigh a line by its shape alone (a fence or not).  `unknown` (99) labels a
# line no cue decides: it is never trained on or scored.

def k() -> Nat:
  12n

def scored() -> Nat:
  10n

def open() -> Nat:
  10n

def close() -> Nat:
  11n

def unknown() -> Nat:
  99n

def names() -> List<&2, String>:
  ["prose", "haskell", "agda", "lean", "bend", "nix", "shell", "diff", "output", "code", "open", "close"]

def name.go(ns: List<&2, String>, t: Nat) -> String:
  match ns t:
    case Nil{} _:
      "unknown"
    case n <> r 0n:
      n
    case n <> r 1n+p:
      name.go(r, p)

def name(t: Nat) -> String:
  name.go(names(), t)

# the checker's language of a code tag (Check.bend's LANG), for tags 1..5
def lang(+t: Nat) -> Maybe<&2, String>:
  match t:
    case 1n:
      Some{"haskell"}
    case 2n:
      Some{"agda"}
    case 3n:
      Some{"lean"}
    case 4n:
      Some{"bend"}
    case 5n:
      Some{"nix"}
    case _:
      None{}

def lower.c(+c: U32) -> U32:
  Bool.pick(U32, Bool.and(U32.is_le(65, c), U32.is_le(c, 90)), U32.add(c, 32), c)

def lower(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case c <> t:
      lower.c(c) <> lower(t)

def among(+x: List<&2, U32>, ws: List<&2, String>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case w <> t:
      Bool.or(S.eq(x, S.b(w)), among(x, t))

# a fence's info string (its first word, any case) as a tag; None when it is
# empty, so the cue before the fence decides
def of.word(+w: List<&2, U32>) -> Nat:
  Bool.pick(Nat, among(w, ["haskell", "hs", "lhs", "ghci"]), 1n,
  Bool.pick(Nat, among(w, ["agda"]), 2n,
  Bool.pick(Nat, among(w, ["lean", "lean4"]), 3n,
  Bool.pick(Nat, among(w, ["bend"]), 4n,
  Bool.pick(Nat, among(w, ["nix"]), 5n,
  Bool.pick(Nat, among(w, ["sh", "bash", "shell", "console", "zsh", "fish", "shellsession"]), 6n,
  Bool.pick(Nat, among(w, ["diff", "patch"]), 7n,
  Bool.pick(Nat, among(w, ["text", "txt", "output", "log", "stdout", "stderr", "plaintext", "plain"]), 8n,
  Bool.pick(Nat, among(w, ["markdown", "md"]), 0n, 9n)))))))))

def word.go(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      Bool.pick(List<&2, U32>, Bool.or(Bool.or(U32.is_eq(c, 32), U32.is_eq(c, 123)), Bool.or(U32.is_eq(c, 9), U32.is_eq(c, 44))), Nil{}, c <> word.go(t))

def of.info(+info: List<&2, U32>) -> Maybe<&2, Nat>:
  +w = lower(word.go(info))
  Bool.pick(Maybe<&2, Nat>, S.eq(w, Nil{}), None{}, Some{of.word(w)})

# a file extension (no dot, any case) as a tag
def of.ext(+e: List<&2, U32>) -> Nat:
  +x = lower(e)
  Bool.pick(Nat, among(x, ["hs", "lhs", "hsc"]), 1n,
  Bool.pick(Nat, among(x, ["agda", "lagda"]), 2n,
  Bool.pick(Nat, among(x, ["lean"]), 3n,
  Bool.pick(Nat, among(x, ["bend"]), 4n,
  Bool.pick(Nat, among(x, ["nix"]), 5n,
  Bool.pick(Nat, among(x, ["sh", "bash", "zsh"]), 6n,
  Bool.pick(Nat, among(x, ["diff", "patch"]), 7n,
  Bool.pick(Nat, among(x, ["log", "out", "output"]), 8n,
  Bool.pick(Nat, among(x, ["md", "markdown", "txt", "rst", "org"]), 0n, 9n)))))))))
