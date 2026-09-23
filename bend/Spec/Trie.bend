import Base

# Language/Trie.agda: Elliott's automatic presentation of a weighted
# language by its two canonical observations, empty-word weight (nu) and
# one-token residual (delta).
#
# Agda's trie is coinductive; Bend2 has no coinduction, and a recursive def
# must terminate.  The trie is therefore rendered by DEPTH: Trie(n) is the
# observable structure down to n tokens, computed as a type by recursion on
# n (a dependent type).  Every Agda statement about the infinite trie is the
# statement about all of its finite depths, so the laws below are stated
# for every n; bisimulation becomes depth-n bisimulation, and the from/to
# round trips hold at the depth the word reaches.
#
# A language is used many times while its trie unfolds, so the language is a
# template argument, instantiated below.

type Leaf<-W: Data> is Type:
  Leaf{w: W}

type Node<-A: Data, -W: Data, -T: Type> is Type:
  Node{w: W, d: A -> T}

def Trie(n: Nat, -A: Data, -W: Data) -> Type:
  match n:
    case 0n:
      Leaf<W>
    case 1n+p:
      Node<A, W, Trie(p, A, W)>

def nuT(n: Nat, -A: Data, -W: Data, t: Trie(n, A, W)) -> W:
  match n:
    case 0n:
      match t:
        case Leaf{w}:
          w
    case 1n+p:
      match t:
        case Node{w, d}:
          w

# the word's weight read off the trie, at the depth the word reaches
def toLanguage(n: Nat, -A: Data, -W: Data, xs: List<&2, A>, t: Trie(n, A, W)) -> W:
  match n xs t:
    case 0n _ Leaf{w}:
      w
    case 1n+p Nil{} Node{w, d}:
      w
    case 1n+p x <> rest Node{w, d}:
      toLanguage(p, A, W, rest, d(x))

# the trie of a language, after a consumed prefix
def fromLanguage(~A: Data, ~W: Data, ~L: List<&2, A> -> W, n: Nat, +prefix: List<&2, A>) -> Trie(n, A, W):
  match n:
    case 0n:
      Leaf{L(prefix)}
    case 1n+p:
      Node{L(prefix), x => fromLanguage(~A, ~W, ~L, p, List.append(&2, A, prefix, [x]))}

law List.append_assoc:
  for -A: Data
  for xs: List<&2, A>
  for -ys: List<&2, A>
  for -zs: List<&2, A>
  {List.append(&2, A, List.append(&2, A, xs, ys), zs) == List.append(&2, A, xs, List.append(&2, A, ys, zs)) : List<&2, A>}

def List.append_assoc(A, xs, ys, zs):
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %List.append_assoc(A, t, ys, zs) : {h <> List.append(&2, A, List.append(&2, A, t, ys), zs) == h <> _ : List<&2, A>}
      {==}

law List.append_nil:
  for -A: Data
  for xs: List<&2, A>
  {List.append(&2, A, xs, Nil{}) == xs : List<&2, A>}

def List.append_nil(A, xs):
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %List.append_nil(A, t) : {h <> List.append(&2, A, t, Nil{}) == h <> _ : List<&2, A>}
      {==}

def len(-A: Data, xs: List<&2, A>) -> Nat:
  List.length(&2, A, xs)

# to . from is the identity on every word, at the word's depth
def to_from(~A: Data, ~W: Data, ~L: List<&2, A> -> W, xs: List<&2, A>, +prefix: List<&2, A>) ->
    {toLanguage(len(A, xs), A, W, xs, fromLanguage(~A, ~W, ~L, len(A, xs), prefix)) == L(List.append(&2, A, prefix, xs)) : W}:
  match xs:
    case Nil{}:
      %List.append_nil(A, prefix) : {L(_) == L(List.append(&2, A, prefix, Nil{})) : W}
      {==}
    case +x <> t:
      %List.append_assoc(A, prefix, [x], t)
        : {toLanguage(len(A, t), A, W, t, fromLanguage(~A, ~W, ~L, len(A, t), List.append(&2, A, prefix, [x]))) == L(_) : W}
      to_from(~A, ~W, ~L, t, List.append(&2, A, prefix, [x]))

# Bisimulation to depth n: equal observations at every depth up to n.
def Bisim(n: Nat, -A: Data, -W: Data, s: Trie(n, A, W), t: Trie(n, A, W)) -> Type:
  match n s t:
    case 0n Leaf{sw} Leaf{tw}:
      {sw == tw : W}
    case 1n+p Node{sw, sd} Node{tw, td}:
      Pair({sw == tw : W}, @+x: A -> Bisim(p, A, W, sd(x), td(x)))

# Bisimilar tries denote the same language (sound), and tries denoting the
# same language are bisimilar (complete) -- the depth-n forms of
# ≈-sound / ≈-complete, stated for the tries of two languages.
def sound(~A: Data, ~W: Data, ~L: List<&2, A> -> W, ~K: List<&2, A> -> W,
          ~same: @+xs: List<&2, A> -> {L(xs) == K(xs) : W},
          xs: List<&2, A>, +prefix: List<&2, A>) ->
    {toLanguage(len(A, xs), A, W, xs, fromLanguage(~A, ~W, ~L, len(A, xs), prefix)) == toLanguage(len(A, xs), A, W, xs, fromLanguage(~A, ~W, ~K, len(A, xs), prefix)) : W}:
  %to_from(~A, ~W, ~L, xs, prefix) : {_ == toLanguage(len(A, xs), A, W, xs, fromLanguage(~A, ~W, ~K, len(A, xs), prefix)) : W}
  %to_from(~A, ~W, ~K, xs, prefix) : {L(List.append(&2, A, prefix, xs)) == _ : W}
  same(List.append(&2, A, prefix, xs))

# The tries of one language, built after different prefixes, agree at
# every depth when the prefixes denote the same residual.
def complete(~A: Data, ~W: Data, ~L: List<&2, A> -> W, n: Nat, +prefix: List<&2, A>) ->
    Bisim(n, A, W, fromLanguage(~A, ~W, ~L, n, prefix), fromLanguage(~A, ~W, ~L, n, prefix)):
  match n:
    case 0n:
      {==}
    case 1n+p:
      ({==}, x => complete(~A, ~W, ~L, p, List.append(&2, A, prefix, [x])))

# Instances ----------------------------------------------------------------

def len.nat(xs: List<&2, Nat>) -> Nat:
  List.length(&2, Nat, xs)

def sum.nat(xs: List<&2, Nat>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      Nat.add(h, sum.nat(t))

def any.bool(xs: List<&2, Bool>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(h, any.bool(t))

law check.to_from:
  for +pre: List<&2, Nat>
  for +xs: List<&2, Nat>
  for +bpre: List<&2, Bool>
  for +bs: List<&2, Bool>
  {toLanguage(len(Nat, xs), Nat, Nat, xs, fromLanguage(~Nat, ~Nat, ~sum.nat, len(Nat, xs), pre)) == sum.nat(List.append(&2, Nat, pre, xs)) : Nat}
  & {toLanguage(len(Bool, bs), Bool, Bool, bs, fromLanguage(~Bool, ~Bool, ~any.bool, len(Bool, bs), bpre)) == any.bool(List.append(&2, Bool, bpre, bs)) : Bool}

def check.to_from(pre, xs, bpre, bs):
  (to_from(~Nat, ~Nat, ~sum.nat, xs, pre), to_from(~Bool, ~Bool, ~any.bool, bs, bpre))

law check.complete:
  for n: Nat
  for +pre: List<&2, Nat>
  Bisim(n, Nat, Nat, fromLanguage(~Nat, ~Nat, ~len.nat, n, pre), fromLanguage(~Nat, ~Nat, ~len.nat, n, pre))

def check.complete(n, pre):
  complete(~Nat, ~Nat, ~len.nat, n, pre)
