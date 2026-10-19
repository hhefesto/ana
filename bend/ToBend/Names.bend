import Base
import ../Sys.bend as S

# Names: Agda's (and later Lean's) names as Bend identifiers.  A name part
# such as `_∘_`, `∘-resp-≈ˡ` or `F₀` keeps its letters and digits, and each
# symbol becomes a word between underscores: `comp`, `comp_resp_eq_l`,
# `F_0`.  Runs of underscores collapse, and the mixfix holes at the ends
# go.  A symbol the table does not know is `u` and its code point in hex.
# A part left empty is `anon`; one that starts with a digit gets an `n` in
# front; one equal to a Bend keyword or to one of Base's global names
# (Nat, List, Unit, True, ...) gets a `_` after it.
#
# The mapping is not injective (`_∘_` and `∘` both give `comp`), so a
# module's names are made unique afterwards (tnm.uniq): the second and
# later of a name get `_2`, `_3`, ..., in definition order, and the choice
# is recorded with the module's other translation facts, so every importer
# uses the same name.  The original name stays in the comment above each
# def.  Every def is prefixed `tnm.`.

# The word for a symbol, "" when the table has none.  The table covers the
# symbols of agda-categories and its standard library cone, by frequency.
def tnm.word(c: U32) -> String:
  match c:
    case 691:
      "r"
    case 737:
      "l"
    case 8776:
      "eq"
    case 8729:
      "dot"
    case 8658:
      "Arr"
    case 8804:
      "le"
    case 8743:
      "and"
    case 8801:
      "eqq"
    case 8728:
      "comp"
    case 8851:
      "meet"
    case 8321:
      "1"
    case 8322:
      "2"
    case 8744:
      "or"
    case 8242:
      "p"
    case 8315:
      "minus"
    case 215:
      "times"
    case 8764:
      "sim"
    case 8739:
      "div"
    case 10217:
      "ra"
    case 10216:
      "la"
    case 8712:
      "in"
    case 8818:
      "lesssim"
    case 8314:
      "plus"
    case 8777:
      "neq"
    case 185:
      "1"
    case 951:
      "eta"
    case 8846:
      "sum"
    case 8759:
      "cons"
    case 949:
      "eps"
    case 8852:
      "join"
    case 8596:
      "iff"
    case 8855:
      "ox"
    case 172:
      "not"
    case 8760:
      "monus"
    case 8320:
      "0"
    case 8868:
      "Top"
    case 8773:
      "iso"
    case 8469:
      "N"
    case 960:
      "pi"
    case 8869:
      "Bot"
    case 8802:
      "neqq"
    case 8853:
      "oplus"
    case 178:
      "2"
    case 10230:
      "to"
    case 728:
      "flip"
    case 945:
      "alpha"
    case 8805:
      "ge"
    case 7495:
      "b"
    case 8771:
      "simeq"
    case 955:
      "lam"
    case 8799:
      "dec"
    case 7506:
      "o"
    case 8467:
      "l"
    case 8769:
      "nsim"
    case 8660:
      "Iff"
    case 8838:
      "sub"
    case 8707:
      "ex"
    case 8244:
      "ppp"
    case 8341:
      "h"
    case 8834:
      "psub"
    case 8243:
      "pp"
    case 931:
      "Sigma"
    case 8779:
      "eqv"
    case 8718:
      "qed"
    case 8784:
      "doteq"
    case 8656:
      "Larr"
    case 946:
      "beta"
    case 8816:
      "nle"
    case 8970:
      "lfloor"
    case 8618:
      "hook"
    case 8594:
      "to"
    case 8971:
      "rfloor"
    case 8713:
      "notin"
    case 8608:
      "surj"
    case 8617:
      "hookl"
    case 10518:
      "bij"
    case 8347:
      "s"
    case 8704:
      "all"
    case 7525:
      "v"
    case 8611:
      "inj"
    case 968:
      "psi"
    case 8258:
      "ast3"
    case 8593:
      "up"
    case 10234:
      "iff2"
    case 948:
      "delta"
    case 8709:
      "empty"
    case 8814:
      "nlt"
    case 947:
      "gamma"
    case 9675:
      "circ"
    case 8595:
      "down"
    case 8826:
      "prec"
    case 7522:
      "i"
    case 8969:
      "rceil"
    case 928:
      "Pi"
    case 9725:
      "box"
    case 8968:
      "lceil"
    case 8862:
      "ulc"
    case 8991:
      "lrc"
    case 8680:
      "Rto"
    case 8815:
      "ngt"
    case 8740:
      "ndiv"
    case 10215:
      "rbr"
    case 9472:
      "hline"
    case 8902:
      "star"
    case 9667:
      "ltri"
    case 10214:
      "lbr"
    case 8319:
      "n"
    case 8817:
      "nge"
    case 8323:
      "3"
    case 8791:
      "circeq"
    case 8592:
      "from"
    case 8255:
      "tie"
    case 8812:
      "between"
    case 8705:
      "compl"
    case 183:
      "cdot"
    case 7580:
      "c"
    case 8621:
      "perm"
    case 9432:
      "i"
    case 894:
      "semi"
    case 39:
      "p"
    case 91:
      "lb"
    case 93:
      "rb"
    case 40:
      "lp"
    case 41:
      "rp"
    case 123:
      "lc"
    case 125:
      "rc"
    case 44:
      "comma"
    case 58:
      "colon"
    case 59:
      "semi"
    case 43:
      "plus"
    case 42:
      "star"
    case 47:
      "slash"
    case 92:
      "bslash"
    case 124:
      "bar"
    case 38:
      "amp"
    case 94:
      "hat"
    case 60:
      "lt"
    case 62:
      "gt"
    case 61:
      "is"
    case 33:
      "bang"
    case 63:
      "q"
    case 64:
      "at"
    case 35:
      "hash"
    case 36:
      "dollar"
    case 37:
      "pct"
    case 126:
      "tilde"
    case 96:
      "tick"
    case 34:
      "quote"
    case _:
      ""

def tnm.hexd(+d: U32) -> Char:
  Chr{Bool.pick(U32, U32.is_lt(d, 10), U32.add(d, 48), U32.add(d, 87))}

def tnm.hex.go(n: Nat, +x: U32, acc: String) -> String:
  match n:
    case 0n:
      acc
    case 1n+p:
      tnm.hex.go(p, U32.div(x, 16), SCon{tnm.hexd(U32.mod(x, 16)), acc})

# a symbol with no word: u and its code point in hex
def tnm.hex(+c: U32) -> String:
  "u" ++ tnm.hex.go(Bool.pick(Nat, U32.is_lt(c, 65536), 4n, 6n), c, SNil{})

def tnm.alnum(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_ge(c, 97), U32.is_le(c, 122)), Bool.and(U32.is_ge(c, 65), U32.is_le(c, 90))), Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57)))

def tnm.sep(+c: U32) -> Bool:
  Bool.or(U32.is_eq(c, 95), U32.is_eq(c, 45))

def tnm.word.or.go(none: Bool, +c: U32, w: String) -> String:
  match none:
    case True{}:
      tnm.hex(c)
    case False{}:
      w

def tnm.word.or(+c: U32, +w: String) -> String:
  tnm.word.or.go(String.eq(w, ""), c, w)

# One character, in front of acc: a letter or digit as itself, `_` and `-`
# as `_`, a symbol as `_WORD_`.
def tnm.char.go(an: Bool, sp: Bool, +c: U32, acc: String) -> String:
  match an sp:
    case True{} _:
      SCon{Chr{c}, acc}
    case False{} True{}:
      SCon{Chr{95}, acc}
    case False{} False{}:
      SCon{Chr{95}, tnm.word.or(c, tnm.word(c)) ++ SCon{Chr{95}, acc}}

def tnm.raw(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{Chr{+c}, t}:
      tnm.char.go(tnm.alnum(c), tnm.sep(c), c, tnm.raw(t))

def tnm.is.us(c: Char) -> Bool:
  match c:
    case Chr{c}:
      U32.is_eq(c, 95)

# whether s starts with `_`
def tnm.head.us(s: String) -> Bool:
  match s:
    case SCon{c, t}:
      tnm.is.us(c)
    case SNil{}:
      False{}

# Runs of `_` collapsed to one; leading ones dropped (lead: nothing but
# underscores so far), trailing ones by tnm.trim.  prev: the last character
# kept was `_`; us: s starts with `_`, decided by the caller so the
# recursion stays in one def.
def tnm.squeeze(s: String, us: Bool, lead: Bool, prev: Bool) -> String:
  match s us lead prev:
    case SNil{} _ _ _:
      SNil{}
    case SCon{c, +t} True{} True{} _:
      tnm.squeeze(t, tnm.head.us(t), True{}, True{})
    case SCon{c, +t} True{} False{} True{}:
      tnm.squeeze(t, tnm.head.us(t), False{}, True{})
    case SCon{c, +t} True{} False{} False{}:
      SCon{c, tnm.squeeze(t, tnm.head.us(t), False{}, True{})}
    case SCon{c, +t} False{} _ _:
      SCon{c, tnm.squeeze(t, tnm.head.us(t), False{}, False{})}

def tnm.squeeze.all(+s: String) -> String:
  tnm.squeeze(s, tnm.head.us(s), True{}, False{})

# underscores collapsed, and none at either end (the mixfix holes)
def tnm.trim(s: String) -> String:
  String.reverse(tnm.squeeze.all(String.reverse(tnm.squeeze.all(s))))

def tnm.digit.first(s: String) -> Bool:
  match s:
    case SCon{Chr{+c}, t}:
      Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57))
    case _:
      False{}

# Bend's keywords and Base's global names (types and constructors), which a
# name may not be
def tnm.reserved() -> List<&2, String>:
  ["def", "type", "law", "for", "exs", "where", "match", "case", "do", "return", "import", "as", "is", "Type", "Data", "Kind", "Quant",
   "App", "Array", "ArrayView", "Audio", "Bool", "Chan", "Char", "Cmp", "Either", "Empty", "Es", "Event", "Ex", "Exists", "F32", "File",
   "Image", "IO", "Ix", "List", "Listener", "Map", "Maybe", "Nat", "Or", "Pair", "Poll", "Result", "Set", "Sigma", "Socket", "String",
   "U32", "Unit", "View", "Window", "Word", "ALeaf", "ANode", "Chr", "Close", "Con", "Done", "E1", "E2", "EIn", "EIx", "EK", "Emit", "EQ",
   "ESel", "Exit", "Fail", "False", "GT", "Halt", "Inl", "Inr", "IxAt", "IxNo", "Key", "Look", "LT", "MLeaf", "MNode", "Mouse", "Move",
   "MTip", "Nil", "None", "Pix", "Qua", "Ready", "SCon", "Scroll", "SNil", "Some", "Succ", "Text", "True", "Tuple", "Wait", "WCon",
   "WNil", "Zero", "Equal"]

def tnm.member(+s: String, xs: List<&2, String>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(String.eq(h, s), tnm.member(s, t))

def tnm.fix(empty: Bool, digit: Bool, +s: String) -> String:
  match empty digit:
    case True{} _:
      "anon"
    case False{} True{}:
      "n" ++ s
    case False{} False{}:
      s

def tnm.safe(reserved: Bool, s: String) -> String:
  match reserved:
    case True{}:
      s ++ "_"
    case False{}:
      s

def tnm.part.of(+s: String) -> String:
  tnm.safe(tnm.member(s, tnm.reserved()), s)

def tnm.part.fixed(+s: String) -> String:
  tnm.part.of(tnm.fix(String.eq(s, ""), tnm.digit.first(s), s))

# one part of a file path: as tnm.part, but a Base name or keyword is fine
# as a file or directory name, so it is kept as it is
def tnm.path.fixed(+s: String) -> String:
  tnm.fix(String.eq(s, ""), tnm.digit.first(s), s)

def tnm.path(s: String) -> String:
  tnm.path.fixed(tnm.trim(tnm.raw(s)))


# one part of a name (no dots) as a Bend identifier
def tnm.part(s: String) -> String:
  tnm.part.fixed(tnm.trim(tnm.raw(s)))