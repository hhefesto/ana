import Base

# Language/Weighted.agda: a weighted language is a function from words to
# weights, determined by its empty-word weight and one-token residuals.
#
# Each language is used once per unfolding, so these theorems quantify over
# an arbitrary (erased) language and are checked generically: they hold for
# every language, including the one the model denotes.

def Language(-A: Data, -W: Type) -> Type:
  List<&2, A> -> W

def nu(-A: Data, -W: Type, L: Language(A, W)) -> W:
  L(Nil{})

def residual(-A: Data, -W: Type, L: Language(A, W), +prefix: List<&2, A>) -> Language(A, W):
  s => L(List.append(&2, A, prefix, s))

def delta(-A: Data, -W: Type, L: Language(A, W), +x: A) -> Language(A, W):
  s => L(x <> s)

# advance along a word, one residual per token
def advance(-A: Data, -W: Type, xs: List<&2, A>, L: Language(A, W)) -> Language(A, W):
  match xs:
    case Nil{}:
      L
    case x <> t:
      advance(A, W, t, delta(A, W, L, x))

def scoreByFold(-A: Data, -W: Type, L: Language(A, W), xs: List<&2, A>) -> W:
  nu(A, W, advance(A, W, xs, L))

law residual_empty:
  for -A: Data
  for -W: Type
  for -L: Language(A, W)
  for -s: List<&2, A>
  {residual(A, W, L, Nil{})(s) == L(s) : W}

def residual_empty(A, W, L, s):
  {==}

# residual (residual L xs) ys = residual L (xs ++ ys), pointwise
law residual_append:
  for -A: Data
  for -W: Type
  for -L: Language(A, W)
  for xs: List<&2, A>
  for -ys: List<&2, A>
  for -s: List<&2, A>
  {residual(A, W, residual(A, W, L, xs), ys)(s) == residual(A, W, L, List.append(&2, A, xs, ys))(s) : W}

def residual_append(A, W, L, xs, ys, s):
  match xs:
    case Nil{}:
      {==}
    case x <> t:
      residual_append(A, W, delta(A, W, L, x), t, ys, s)

# Every weighted language is determined by nu and singleton residuals.
law determination:
  for -A: Data
  for -W: Type
  for -L: Language(A, W)
  for xs: List<&2, A>
  {scoreByFold(A, W, L, xs) == L(xs) : W}

def determination(A, W, L, xs):
  match xs:
    case Nil{}:
      {==}
    case x <> t:
      determination(A, W, delta(A, W, L, x), t)
