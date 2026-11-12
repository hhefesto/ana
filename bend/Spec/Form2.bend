import Base

# Form 2's calls on a file (docs/form2/README.md; the user, 11-12: design it
# now), stated in Elliott's denotational-design way: first what a file means
# to the calls, then the calls as functions on that meaning, then the laws.
#
# The meaning: a file is its lines, cut into the text before the first
# definition and a list of pieces.  A piece is a definition's name, its body
# (its head line and the lines after it, up to the last that is not a gap
# line) and its gap (the blank and comment lines after the body, up to the
# next head).  Consecutive heads of one name are one piece (Haskell's and
# Agda's signature and equations).  What a head is (`hd`, giving its name) and
# what a gap line is (`gp`) are the language's: template arguments.  The cut
# works on any text, parsed or not, so a file that fails its check still has
# its pieces.
#
# The calls: `## look NAME` is `get`, the body of the first piece of that
# name; `## def` is `put`, which replaces that body and keeps the piece's name
# and gap, so no comment or blank line between definitions is ever lost.
#
# The laws (theorem templates, checked at the instance at the end):
#   join_split  cutting a file and joining it back gives the same lines
#   get_put     putting back what look showed changes nothing
#   put_get     look after def shows what def wrote (the name in the file),
#               and still nothing when the name is not in the file
#   put_put     a second def of a name overrides the first
#   names_put   def keeps every name, in order: no piece added or lost
# get_put, put_get and put_put are the lens laws (Foster et al., TOPLAS 2007).
# A name not in the file: get is None and put changes nothing, so `## def` of
# an unknown name is refused, and a new definition is its own call, `## add`.

type Piece<-A: Data, -N: Data> is Data:
  Piece{name: N, body: List<&2, A>, gap: List<&2, A>}

# pre and pgap: the text before the first head, its trailing gap lines apart
type Doc<-A: Data, -N: Data> is Data:
  Doc{pre: List<&2, A>, pgap: List<&2, A>, defs: List<&2, Piece<A, N>>}

# Joining ---------------------------------------------------------------------

def cat(-A: Data, -N: Data, ds: List<&2, Piece<A, N>>) -> List<&2, A>:
  match ds:
    case Nil{}:
      Nil{}
    case Piece{n, b, g} <> t:
      List.append(&2, A, b, List.append(&2, A, g, cat(A, N, t)))

def join(-A: Data, -N: Data, d: Doc<A, N>) -> List<&2, A>:
  match d:
    case Doc{p, g, ds}:
      List.append(&2, A, p, List.append(&2, A, g, cat(A, N, ds)))

# Cutting, from the last line up ------------------------------------------------

# l is not a head: a gap line with no body below it joins the gap
def split.body(-A: Data, -N: Data, +l: A, gl: Bool, pb: List<&2, A>, pg: List<&2, A>, ds: List<&2, Piece<A, N>>) -> Doc<A, N>:
  match gl:
    case True{}:
      match pb:
        case Nil{}:
          Doc{Nil{}, l <> pg, ds}
        case h <> t:
          Doc{l <> (h <> t), pg, ds}
    case False{}:
      Doc{l <> pb, pg, ds}

# l heads a definition named n; the next piece has the same name: one piece
def split.merge(-A: Data, -N: Data, same: Bool, +l: A, n: N, pb: List<&2, A>, pg: List<&2, A>, n1: N, b1: List<&2, A>, g1: List<&2, A>, rest: List<&2, Piece<A, N>>) -> Doc<A, N>:
  match same:
    case True{}:
      Doc{Nil{}, Nil{}, Piece{n, l <> List.append(&2, A, pb, List.append(&2, A, pg, b1)), g1} <> rest}
    case False{}:
      Doc{Nil{}, Nil{}, Piece{n, l <> pb, pg} <> (Piece{n1, b1, g1} <> rest)}

def split.head(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +l: A, +n: N, pb: List<&2, A>, pg: List<&2, A>, ds: List<&2, Piece<A, N>>) -> Doc<A, N>:
  match ds:
    case Nil{}:
      Doc{Nil{}, Nil{}, [Piece{n, l <> pb, pg}]}
    case Piece{+n1, b1, g1} <> rest:
      split.merge(A, N, eq(n, n1), l, n, pb, pg, n1, b1, g1, rest)

def split.cons(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +l: A, m: Maybe<&2, N>, gl: Bool, d: Doc<A, N>) -> Doc<A, N>:
  match m d:
    case Some{n} Doc{pb, pg, ds}:
      split.head(~A, ~N, ~eq, l, n, pb, pg, ds)
    case None{} Doc{pb, pg, ds}:
      split.body(A, N, l, gl, pb, pg, ds)

def split(~A: Data, ~N: Data, ~hd: @+x: A -> Maybe<&2, N>, ~gp: @+x: A -> Bool, ~eq: N -> N -> Bool, ls: List<&2, A>) -> Doc<A, N>:
  match ls:
    case Nil{}:
      Doc{Nil{}, Nil{}, Nil{}}
    case +l <> t:
      split.cons(~A, ~N, ~eq, l, hd(l), gp(l), split(~A, ~N, ~hd, ~gp, ~eq, t))

# The round trip ----------------------------------------------------------------

def f2.assoc(-A: Data, xs: List<&2, A>, -ys: List<&2, A>, -zs: List<&2, A>) ->
    {List.append(&2, A, List.append(&2, A, xs, ys), zs) == List.append(&2, A, xs, List.append(&2, A, ys, zs)) : List<&2, A>}:
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %f2.assoc(A, t, ys, zs) : {h <> List.append(&2, A, List.append(&2, A, t, ys), zs) == h <> _ : List<&2, A>}
      {==}

def join.body(-A: Data, -N: Data, +l: A, gl: Bool, pb: List<&2, A>, -pg: List<&2, A>, -ds: List<&2, Piece<A, N>>) ->
    {join(A, N, split.body(A, N, l, gl, pb, pg, ds)) == l <> join(A, N, Doc{pb, pg, ds}) : List<&2, A>}:
  match gl:
    case True{}:
      match pb:
        case Nil{}:
          {==}
        case h <> t:
          {==}
    case False{}:
      {==}

def join.merge(-A: Data, -N: Data, same: Bool, +l: A, -n: N, +pb: List<&2, A>, +pg: List<&2, A>, -n1: N, +b1: List<&2, A>, -g1: List<&2, A>, -rest: List<&2, Piece<A, N>>) ->
    {join(A, N, split.merge(A, N, same, l, n, pb, pg, n1, b1, g1, rest)) == l <> join(A, N, Doc{pb, pg, Piece{n1, b1, g1} <> rest}) : List<&2, A>}:
  match same:
    case True{}:
      %f2.assoc(A, pg, b1, List.append(&2, A, g1, cat(A, N, rest))) : {List.append(&2, A, l <> List.append(&2, A, pb, List.append(&2, A, pg, b1)), List.append(&2, A, g1, cat(A, N, rest))) == l <> List.append(&2, A, pb, _) : List<&2, A>}
      %f2.assoc(A, pb, List.append(&2, A, pg, b1), List.append(&2, A, g1, cat(A, N, rest))) : {List.append(&2, A, l <> List.append(&2, A, pb, List.append(&2, A, pg, b1)), List.append(&2, A, g1, cat(A, N, rest))) == l <> _ : List<&2, A>}
      {==}
    case False{}:
      {==}

def join.head(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +l: A, +n: N, +pb: List<&2, A>, +pg: List<&2, A>, ds: List<&2, Piece<A, N>>) ->
    {join(A, N, split.head(~A, ~N, ~eq, l, n, pb, pg, ds)) == l <> join(A, N, Doc{pb, pg, ds}) : List<&2, A>}:
  match ds:
    case Nil{}:
      {==}
    case Piece{+n1, +b1, g1} <> rest:
      join.merge(A, N, eq(n, n1), l, n, pb, pg, n1, b1, g1, rest)

def join.cons(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +l: A, m: Maybe<&2, N>, gl: Bool, d: Doc<A, N>) ->
    {join(A, N, split.cons(~A, ~N, ~eq, l, m, gl, d)) == l <> join(A, N, d) : List<&2, A>}:
  match m d:
    case Some{n} Doc{+pb, +pg, ds}:
      join.head(~A, ~N, ~eq, l, n, pb, pg, ds)
    case None{} Doc{pb, pg, ds}:
      join.body(A, N, l, gl, pb, pg, ds)

def join_split(~A: Data, ~N: Data, ~hd: @+x: A -> Maybe<&2, N>, ~gp: @+x: A -> Bool, ~eq: N -> N -> Bool, ls: List<&2, A>) ->
    {join(A, N, split(~A, ~N, ~hd, ~gp, ~eq, ls)) == ls : List<&2, A>}:
  match ls:
    case Nil{}:
      {==}
    case +l <> +t:
      %join_split(~A, ~N, ~hd, ~gp, ~eq, t) : {join(A, N, split.cons(~A, ~N, ~eq, l, hd(l), gp(l), split(~A, ~N, ~hd, ~gp, ~eq, t))) == l <> _ : List<&2, A>}
      join.cons(~A, ~N, ~eq, l, hd(l), gp(l), split(~A, ~N, ~hd, ~gp, ~eq, t))

# look and def ------------------------------------------------------------------

def get.at(-A: Data, b: Bool, xs: List<&2, A>, r: Maybe<&2, List<&2, A>>) -> Maybe<&2, List<&2, A>>:
  match b:
    case True{}:
      Some{xs}
    case False{}:
      r

def get(~A: Data, ~N: Data, ~eq: N -> N -> Bool, ds: List<&2, Piece<A, N>>, +n: N) -> Maybe<&2, List<&2, A>>:
  match ds:
    case Nil{}:
      None{}
    case Piece{nm, xs, g} <> t:
      get.at(A, eq(nm, n), xs, get(~A, ~N, ~eq, t, n))

def put.at(-A: Data, -N: Data, b: Bool, nm: N, xs: List<&2, A>, g: List<&2, A>, t: List<&2, Piece<A, N>>, ys: List<&2, A>, r: List<&2, Piece<A, N>>) -> List<&2, Piece<A, N>>:
  match b:
    case True{}:
      Piece{nm, ys, g} <> t
    case False{}:
      Piece{nm, xs, g} <> r

def put(~A: Data, ~N: Data, ~eq: N -> N -> Bool, ds: List<&2, Piece<A, N>>, +n: N, +ys: List<&2, A>) -> List<&2, Piece<A, N>>:
  match ds:
    case Nil{}:
      Nil{}
    case Piece{+nm, xs, g} <> +t:
      put.at(A, N, eq(nm, n), nm, xs, g, t, ys, put(~A, ~N, ~eq, t, n, ys))

# put with what get answered: nothing when it answered None
def put.opt(~A: Data, ~N: Data, ~eq: N -> N -> Bool, ds: List<&2, Piece<A, N>>, +n: N, m: Maybe<&2, List<&2, A>>) -> List<&2, Piece<A, N>>:
  match m:
    case None{}:
      ds
    case Some{x}:
      put(~A, ~N, ~eq, ds, n, x)

def opt.to(-A: Data, m: Maybe<&2, List<&2, A>>, ys: List<&2, A>) -> Maybe<&2, List<&2, A>>:
  match m:
    case None{}:
      None{}
    case Some{x}:
      Some{ys}

def names(-A: Data, -N: Data, ds: List<&2, Piece<A, N>>) -> List<&2, N>:
  match ds:
    case Nil{}:
      Nil{}
    case Piece{nm, xs, g} <> t:
      nm <> names(A, N, t)

# The lens laws -------------------------------------------------------------------
# Each case on a piece goes through a lemma over b, the piece's eq(nm, n), with
# e : {b == eq(nm, n)} to rewrite the calls that compute it again.

def opt.cons(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +nm: N, +xs: List<&2, A>, +g: List<&2, A>, +t: List<&2, Piece<A, N>>, +n: N, m: Maybe<&2, List<&2, A>>, e: {False{} == eq(nm, n) : Bool}) ->
    {put.opt(~A, ~N, ~eq, Piece{nm, xs, g} <> t, n, m) == Piece{nm, xs, g} <> put.opt(~A, ~N, ~eq, t, n, m) : List<&2, Piece<A, N>>}:
  match m:
    case None{}:
      {==}
    case Some{+x}:
      %e : {put.at(A, N, _, nm, xs, g, t, x, put(~A, ~N, ~eq, t, n, x)) == Piece{nm, xs, g} <> put(~A, ~N, ~eq, t, n, x) : List<&2, Piece<A, N>>}
      {==}

def get_put.at(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +nm: N, +xs: List<&2, A>, +g: List<&2, A>, +t: List<&2, Piece<A, N>>, +n: N, b: Bool,
    ih: {put.opt(~A, ~N, ~eq, t, n, get(~A, ~N, ~eq, t, n)) == t : List<&2, Piece<A, N>>}) ->
    {b == eq(nm, n) : Bool} ->
    {put.opt(~A, ~N, ~eq, Piece{nm, xs, g} <> t, n, get.at(A, b, xs, get(~A, ~N, ~eq, t, n))) == Piece{nm, xs, g} <> t : List<&2, Piece<A, N>>}:
  match b:
    case True{}:
      e =>
        %e : {put.at(A, N, _, nm, xs, g, t, xs, put(~A, ~N, ~eq, t, n, xs)) == Piece{nm, xs, g} <> t : List<&2, Piece<A, N>>}
        {==}
    case False{}:
      e =>
        %ih : {put.opt(~A, ~N, ~eq, Piece{nm, xs, g} <> t, n, get(~A, ~N, ~eq, t, n)) == Piece{nm, xs, g} <> _ : List<&2, Piece<A, N>>}
        opt.cons(~A, ~N, ~eq, nm, xs, g, t, n, get(~A, ~N, ~eq, t, n), e)

def get_put(~A: Data, ~N: Data, ~eq: N -> N -> Bool, ds: List<&2, Piece<A, N>>, +n: N) ->
    {put.opt(~A, ~N, ~eq, ds, n, get(~A, ~N, ~eq, ds, n)) == ds : List<&2, Piece<A, N>>}:
  match ds:
    case Nil{}:
      {==}
    case Piece{+nm, +xs, +g} <> +t:
      get_put.at(~A, ~N, ~eq, nm, xs, g, t, n, eq(nm, n), get_put(~A, ~N, ~eq, t, n))({==})

def put_get.at(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +nm: N, +xs: List<&2, A>, +g: List<&2, A>, +t: List<&2, Piece<A, N>>, +n: N, +ys: List<&2, A>, b: Bool,
    ih: {get(~A, ~N, ~eq, put(~A, ~N, ~eq, t, n, ys), n) == opt.to(A, get(~A, ~N, ~eq, t, n), ys) : Maybe<&2, List<&2, A>>}) ->
    {b == eq(nm, n) : Bool} ->
    {get(~A, ~N, ~eq, put.at(A, N, b, nm, xs, g, t, ys, put(~A, ~N, ~eq, t, n, ys)), n) == opt.to(A, get.at(A, b, xs, get(~A, ~N, ~eq, t, n)), ys) : Maybe<&2, List<&2, A>>}:
  match b:
    case True{}:
      e =>
        %e : {get.at(A, _, ys, get(~A, ~N, ~eq, t, n)) == Some{ys} : Maybe<&2, List<&2, A>>}
        {==}
    case False{}:
      e =>
        %e : {get.at(A, _, xs, get(~A, ~N, ~eq, put(~A, ~N, ~eq, t, n, ys), n)) == opt.to(A, get(~A, ~N, ~eq, t, n), ys) : Maybe<&2, List<&2, A>>}
        ih

def put_get(~A: Data, ~N: Data, ~eq: N -> N -> Bool, ds: List<&2, Piece<A, N>>, +n: N, +ys: List<&2, A>) ->
    {get(~A, ~N, ~eq, put(~A, ~N, ~eq, ds, n, ys), n) == opt.to(A, get(~A, ~N, ~eq, ds, n), ys) : Maybe<&2, List<&2, A>>}:
  match ds:
    case Nil{}:
      {==}
    case Piece{+nm, +xs, +g} <> +t:
      put_get.at(~A, ~N, ~eq, nm, xs, g, t, n, ys, eq(nm, n), put_get(~A, ~N, ~eq, t, n, ys))({==})

def put_put.at(~A: Data, ~N: Data, ~eq: N -> N -> Bool, +nm: N, +xs: List<&2, A>, +g: List<&2, A>, +t: List<&2, Piece<A, N>>, +n: N, +ys: List<&2, A>, +zs: List<&2, A>, b: Bool,
    ih: {put(~A, ~N, ~eq, put(~A, ~N, ~eq, t, n, ys), n, zs) == put(~A, ~N, ~eq, t, n, zs) : List<&2, Piece<A, N>>}) ->
    {b == eq(nm, n) : Bool} ->
    {put(~A, ~N, ~eq, put.at(A, N, b, nm, xs, g, t, ys, put(~A, ~N, ~eq, t, n, ys)), n, zs) == put.at(A, N, b, nm, xs, g, t, zs, put(~A, ~N, ~eq, t, n, zs)) : List<&2, Piece<A, N>>}:
  match b:
    case True{}:
      e =>
        %e : {put.at(A, N, _, nm, ys, g, t, zs, put(~A, ~N, ~eq, t, n, zs)) == Piece{nm, zs, g} <> t : List<&2, Piece<A, N>>}
        {==}
    case False{}:
      e =>
        %e : {put.at(A, N, _, nm, xs, g, put(~A, ~N, ~eq, t, n, ys), zs, put(~A, ~N, ~eq, put(~A, ~N, ~eq, t, n, ys), n, zs)) == Piece{nm, xs, g} <> put(~A, ~N, ~eq, t, n, zs) : List<&2, Piece<A, N>>}
        %ih : {Piece{nm, xs, g} <> put(~A, ~N, ~eq, put(~A, ~N, ~eq, t, n, ys), n, zs) == Piece{nm, xs, g} <> _ : List<&2, Piece<A, N>>}
        {==}

def put_put(~A: Data, ~N: Data, ~eq: N -> N -> Bool, ds: List<&2, Piece<A, N>>, +n: N, +ys: List<&2, A>, +zs: List<&2, A>) ->
    {put(~A, ~N, ~eq, put(~A, ~N, ~eq, ds, n, ys), n, zs) == put(~A, ~N, ~eq, ds, n, zs) : List<&2, Piece<A, N>>}:
  match ds:
    case Nil{}:
      {==}
    case Piece{+nm, +xs, +g} <> +t:
      put_put.at(~A, ~N, ~eq, nm, xs, g, t, n, ys, zs, eq(nm, n), put_put(~A, ~N, ~eq, t, n, ys, zs))({==})

def names_put.at(-A: Data, -N: Data, b: Bool, +nm: N, -xs: List<&2, A>, -g: List<&2, A>, +t: List<&2, Piece<A, N>>, -ys: List<&2, A>, +r: List<&2, Piece<A, N>>,
    ih: {names(A, N, r) == names(A, N, t) : List<&2, N>}) ->
    {names(A, N, put.at(A, N, b, nm, xs, g, t, ys, r)) == nm <> names(A, N, t) : List<&2, N>}:
  match b:
    case True{}:
      {==}
    case False{}:
      %ih : {nm <> names(A, N, r) == nm <> _ : List<&2, N>}
      {==}

def names_put(~A: Data, ~N: Data, ~eq: N -> N -> Bool, ds: List<&2, Piece<A, N>>, +n: N, +ys: List<&2, A>) ->
    {names(A, N, put(~A, ~N, ~eq, ds, n, ys)) == names(A, N, ds) : List<&2, N>}:
  match ds:
    case Nil{}:
      {==}
    case Piece{+nm, xs, g} <> +t:
      names_put.at(A, N, eq(nm, n), nm, xs, g, t, ys, put(~A, ~N, ~eq, t, n, ys), names_put(~A, ~N, ~eq, t, n, ys))

# The instance: Bend's own layout, a line a String -----------------------------
# A head is `def NAME`, `law NAME` or `type NAME` at column 0; a gap line is
# blank or a comment at column 0.  (The other languages' heads are the
# renderer's: bend/Form2.bend.)

def bd.namech(+c: Char) -> Bool:
  Bool.not(Bool.or(Char.is_eq(c, '('), Bool.or(Char.is_eq(c, ':'), Bool.or(Char.is_eq(c, '<'), Char.is_space(c)))))

def bd.name(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, t}:
      Bool.pick(String, bd.namech(c), SCon{c, bd.name(t)}, SNil{})

def bd.after(+s: String, +p: String) -> Maybe<&2, String>:
  Bool.pick(Maybe<&2, String>, String.starts_with(s, p), Some{bd.name(String.drop(s, String.length(p)))}, None{})

def bd.hd(+l: String) -> Maybe<&2, String>:
  Maybe.or(&2, String, bd.after(l, "def "), Maybe.or(&2, String, bd.after(l, "law "), bd.after(l, "type ")))

def bd.blank(s: String) -> Bool:
  match s:
    case SNil{}:
      True{}
    case SCon{c, t}:
      Bool.and(Char.is_space(c), bd.blank(t))

def bd.gp(+l: String) -> Bool:
  Bool.or(bd.blank(l), String.starts_with(l, "#"))

def bd.eq(a: String, b: String) -> Bool:
  String.eq(a, b)

law check.form2:
  for ls: List<&2, String>
  for +ds: List<&2, Piece<String, String>>
  for +n: String
  for +ys: List<&2, String>
  for +zs: List<&2, String>
  {join(String, String, split(~String, ~String, ~bd.hd, ~bd.gp, ~bd.eq, ls)) == ls : List<&2, String>}
  & {put.opt(~String, ~String, ~bd.eq, ds, n, get(~String, ~String, ~bd.eq, ds, n)) == ds : List<&2, Piece<String, String>>}
  & {get(~String, ~String, ~bd.eq, put(~String, ~String, ~bd.eq, ds, n, ys), n) == opt.to(String, get(~String, ~String, ~bd.eq, ds, n), ys) : Maybe<&2, List<&2, String>>}
  & {put(~String, ~String, ~bd.eq, put(~String, ~String, ~bd.eq, ds, n, ys), n, zs) == put(~String, ~String, ~bd.eq, ds, n, zs) : List<&2, Piece<String, String>>}
  & {names(String, String, put(~String, ~String, ~bd.eq, ds, n, ys)) == names(String, String, ds) : List<&2, String>}

def check.form2(ls, ds, n, ys, zs):
  (join_split(~String, ~String, ~bd.hd, ~bd.gp, ~bd.eq, ls),
   (get_put(~String, ~String, ~bd.eq, ds, n),
    (put_get(~String, ~String, ~bd.eq, ds, n, ys),
     (put_put(~String, ~String, ~bd.eq, ds, n, ys, zs),
      names_put(~String, ~String, ~bd.eq, ds, n, ys)))))

# An example, computed: comments and blank lines between definitions stay in
# the gaps, a blank line inside a body stays in the body, a law and its proof
# (consecutive heads of one name) are one piece, and def touches one body.

def defs(-A: Data, -N: Data, d: Doc<A, N>) -> List<&2, Piece<A, N>>:
  match d:
    case Doc{p, g, ds}:
      ds

def ex.file() -> List<&2, String>:
  ["import Base", "", "# a comment", "law f:", "  for x: Nat", "  Nat", "def f(x):", "  match x:", "", "    case 0n:", "      0n", "    case 1n+p:", "      p", "", "# about g", "def g() -> Nat:", "  1n"]

def ex.doc() -> Doc<String, String>:
  split(~String, ~String, ~bd.hd, ~bd.gp, ~bd.eq, ex.file())

def ex.g2() -> List<&2, String>:
  ["def g() -> Nat:", "  2n"]

law check.form2.example:
  {names(String, String, defs(String, String, ex.doc())) == ["f", "g"] : List<&2, String>}
  & {get(~String, ~String, ~bd.eq, defs(String, String, ex.doc()), "f") == Some{["law f:", "  for x: Nat", "  Nat", "def f(x):", "  match x:", "", "    case 0n:", "      0n", "    case 1n+p:", "      p"]} : Maybe<&2, List<&2, String>>}
  & {get(~String, ~String, ~bd.eq, defs(String, String, ex.doc()), "h") == None{} : Maybe<&2, List<&2, String>>}
  & {cat(String, String, put(~String, ~String, ~bd.eq, defs(String, String, ex.doc()), "g", ex.g2())) == ["law f:", "  for x: Nat", "  Nat", "def f(x):", "  match x:", "", "    case 0n:", "      0n", "    case 1n+p:", "      p", "", "# about g", "def g() -> Nat:", "  2n"] : List<&2, String>}

def check.form2.example():
  ({==}, ({==}, ({==}, {==})))
