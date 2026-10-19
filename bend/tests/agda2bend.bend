import Base
import ../Sys.bend as S
import ../ToBend/Sexp.bend as X
import ../Agda2Bend/Ast.bend as A

# agda2bend's laws, run from this directory on the committed exports in
# fixtures/agda2bend (agda-export's output for small modules, so the laws
# need no Agda).  Each line prints `ok NAME` or `FAIL NAME`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

# Sexp ---------------------------------------------------------------------

# an expression that was read prints back as the bytes l
def rt.same.of(m: Maybe<&2, X.Sx>, l: List<&2, U32>) -> Bool:
  match m:
    case Some{x}:
      S.eq(X.tsx.show(x), l)
    case None{}:
      False{}

# a line reads as one expression and prints back byte for byte
def rt.line(+line: List<&2, U32>) -> Bool:
  rt.same.of(X.tsx.one(line), line)

# the number of lines that do not round-trip (empty lines aside)
def rt.bad(ls: List<&2, List<&2, U32>>) -> Nat:
  match ls:
    case Nil{}:
      0n
    case +l <> t:
      Nat.add(Bool.pick(Nat, Bool.or(S.eq(l, Nil{}), rt.line(l)), 0n, 1n), rt.bad(t))

def rt.nonempty(+xs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  List.filter(~List<&2, U32>, ~(l => Bool.not(S.eq(l, Nil{}))), S.split.lines(xs))

# The streaming reader hands out as many expressions as the file has lines,
# each the same as the line read whole: the reader, the expressions so far,
# how many differed, and the lines still to compare.
type RtSt is Type:
  RtSt{rd: X.TsxRd, n: Nat, bad: Nat, ls: List<&2, List<&2, U32>>}

def rt.same(m: Maybe<&2, X.Sx>, ls: List<&2, List<&2, U32>>) -> Bool & List<&2, List<&2, U32>>:
  match ls:
    case l <> t:
      (rt.same.of(m, l), t)
    case Nil{}:
      (False{}, Nil{})

def rt.stream.put(rd: X.TsxRd, +n: Nat, +bad: Nat, r: Bool & List<&2, List<&2, U32>>) -> IO(Bool & RtSt):
  (ok, ls) = r
  IO.pure(Bool & RtSt, (True{}, RtSt{rd, 1n+n, Nat.add(bad, Bool.pick(Nat, ok, 0n, 1n)), ls}))

def rt.stream.got(+n: Nat, +bad: Nat, ls: List<&2, List<&2, U32>>, r: X.TsxRd & Maybe<&2, X.Sx>) -> IO(Bool & RtSt):
  (rd, m) = r
  match m:
    case Some{x}:
      rt.stream.put(rd, n, bad, rt.same(Some{x}, ls))
    case None{}:
      IO.pure(Bool & RtSt, (False{}, RtSt{rd, n, bad, ls}))

# one read while the file has more; the state as it is once it has ended
def rt.stream.step(more: Bool, s: RtSt) -> IO(Bool & RtSt):
  match more s:
    case True{} RtSt{rd, +n, +bad, ls}:
      do IO<Bool & RtSt>:
        r : X.TsxRd & Maybe<&2, X.Sx> <- X.tsx.next(rd)
        rt.stream.got(n, bad, ls, r)
    case False{} s:
      IO.pure(Bool & RtSt, (False{}, s))

def rt.stream.step.of(x: Bool & RtSt) -> IO(Bool & RtSt):
  (more, s) = x
  rt.stream.step(more, s)

def rt.stream.snd(x: Bool & RtSt) -> RtSt:
  (more, s) = x
  s

def rt.stream.go(fuel: Nat, x: Bool & RtSt) -> IO(RtSt):
  match fuel:
    case 0n:
      IO.pure(RtSt, rt.stream.snd(x))
    case 1n+p:
      IO.bind(Bool & RtSt, RtSt, rt.stream.step.of(x), rt.stream.go(p))

def rt.stream.fin(+lines: Nat, s: RtSt) -> IO(Bool):
  match s:
    case RtSt{rd, n, bad, ls}:
      do IO<Bool>:
        X.tsx.shut(rd)
        return Bool.and(Nat.is_eq(n, lines), Nat.is_eq(bad, 0n))

def rt.stream(+path: String, +xs: List<&2, U32>) -> IO(Bool):
  do IO<Bool>:
    rd : X.TsxRd <- X.tsx.open(path)
    s : RtSt <- rt.stream.go(64n, (True{}, RtSt{rd, 0n, 0n, rt.nonempty(xs)}))
    rt.stream.fin(List.length(&2, List<&2, U32>, rt.nonempty(xs)), s)

def has.field(m: Maybe<&2, X.Sx>, +want: List<&2, U32>) -> Bool:
  match m:
    case Some{x}:
      S.eq(X.tsx.show(x), want)
    case None{}:
      False{}

def sexp.laws(+bool: List<&2, U32>, +unit: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    IO.print(verdict("sexp escapes", rt.line(S.b("(a \"x\\\"y\\\\z\" (b) () \"\" (c d))"))))
    IO.print(verdict("sexp raw newline in a string", rt.line(S.b("(s \"a\nb\")"))))
    IO.print(verdict("sexp several", Nat.is_eq(List.length(&2, X.Sx, X.tsx.read(S.b("(a) b \"c\" (d (e))"))), 4n)))
    IO.print(verdict("sexp unclosed is none", Bool.not(Maybe.is_some(&2, X.Sx, X.tsx.one(S.b("(a (b)"))))))
    IO.print(verdict("sexp stray close is none", Bool.not(Maybe.is_some(&2, X.Sx, X.tsx.one(S.b("(a))"))))))
    IO.print(verdict("sexp field", has.field(X.tsx.field(X.tsx.args(Maybe.default(&2, X.Sx, X.tsx.one(S.b("(def (q \"A\" 1 2) (name \"n\") (kind record))")), X.SxNil{})), S.b("kind")), S.b("(kind record)"))))
    IO.print(verdict("sexp nat", Nat.is_eq(X.tsx.nat(X.SxAtom{S.b("4096")}), 4096n)))
    IO.print(verdict("sexp roundtrip Agda.Builtin.Bool", Nat.is_eq(rt.bad(S.split.lines(bool)), 0n)))
    IO.print(verdict("sexp roundtrip Agda.Builtin.Unit", Nat.is_eq(rt.bad(S.split.lines(unit)), 0n)))
    sb : Bool <- rt.stream("fixtures/agda2bend/Agda.Builtin.Bool.sexp", bool)
    IO.print(verdict("sexp stream Agda.Builtin.Bool", sb))
    su : Bool <- rt.stream("fixtures/agda2bend/Agda.Builtin.Unit.sexp", unit)
    IO.print(verdict("sexp stream Agda.Builtin.Unit", su))

# Ast ----------------------------------------------------------------------

# FORMAT.md's keywords, each of which must classify as its own constructor
# (whose code is its hash), never as AkWord
def ast.words() -> List<&2, String>:
  ["w", "relevant", "var", "apply", "hidden", "visible", "q", "def", "plus", "set", "max", "el", "system", "none", "abs", "dom", "pi", "p", "b", "x", "con", "pvar", "lam", "no", "inf", "type", "range", "sort", "function", "level", "l", "yes", "proj", "catchall", "irrelevant", "intervaluniv", "vars", "done", "clause", "tel", "unreachable", "body", "pats", "where-module", "recursive", "of", "noabs", "sset", "without-k", "funsort", "mutual", "terminates", "opaque", "compiled", "clauses", "projection", "with-of", "fun-flags", "restored-params", "extlam", "kan-op", "module", "name", "flags", "fixity", "kind", "modality", "canonical", "language", "lines", "inline", "copy", "br", "fallthrough", "lazy", "unknown", "record", "from", "orig", "index", "proper", "lams", "noparams", "eta", "copattern", "cons", "lits", "branches", "case", "pisort", "field", "pcon", "pproj", "pdot", "q0", "erased", "split", "copattern-lhs", "infix", "constructor", "iapply", "abstract", "pars", "induction", "fields", "no-compilation", "pdef", "prefix", "data", "src-con", "projections", "con-kind", "erasure", "forced", "arity", "inductive", "named-con", "pattern-matching", "inferred", "infixr", "infixl", "leveluniv", "wild", "split-arg", "builtin", "term", "absurd", "other", "erased-cubical", "primitive", "postulate", "const-transp", "path-cons", "ixs", "lit", "nat", "word64", "float", "string", "char", "qname", "meta", "dontcare", "dummy", "instance", "shape-irrelevant", "q1", "postfix", "prop", "sizeuniv", "lockuniv", "univsort", "metas", "defs", "dummys", "plit", "piapply", "lbr", "fail", "with-k", "cubical", "coinductive", "specified", "pattern", "rec", "dot", "imports", "options", "library-options", "builtins", "prim", "rewrite", "file"]

def ast.kw.one(+b: List<&2, U32>) -> Nat:
  Bool.pick(Nat, Bool.and(U32.is_eq(A.aas.kw.code(A.aas.kw(b)), A.aas.hash(b, 0)), U32.is_ne(A.aas.hash(b, 0), 0)), 0n, 1n)

# the count of words that do not classify as their own keyword
def ast.kw.ok(ws: List<&2, String>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case w <> t:
      Nat.add(ast.kw.one(S.b(w)), ast.kw.ok(t))

# the keyword codes of the words are pairwise distinct (no two words share
# a constructor): the count of pairs that clash
def ast.kw.clash.one(+c: U32, ws: List<&2, String>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case w <> t:
      Nat.add(Bool.pick(Nat, U32.is_eq(A.aas.kw.code(A.aas.kw(S.b(w))), c), 1n, 0n), ast.kw.clash.one(c, t))

def ast.kw.clash(ws: List<&2, String>) -> Nat:
  match ws:
    case Nil{}:
      0n
    case w <> +t:
      Nat.add(ast.kw.clash.one(A.aas.kw.code(A.aas.kw(S.b(w))), t), ast.kw.clash(t))

# A decoded export file: modules, definitions, the definition count its
# header announced, AgRaw nodes outside the cubical helpers (flag
# no-compilation), and whether `Bool` came out as a data type with two
# constructors.
type AstSt is Data:
  AstSt{mods: Nat, defs: Nat, want: Nat, raws: Nat, bool: Bool}

def ast.nocomp(fl: List<&2, A.AgKw>) -> Bool:
  match fl:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(A.aas.kw.eq(h, A.AkNoCompilation{}), ast.nocomp(t))

def ast.qs.len(a: A.Ag) -> Nat:
  match a:
    case A.AgQs{i, q, rest}:
      1n+ast.qs.len(rest)
    case _:
      0n

def ast.is.bool(+nm: List<&2, U32>, d: A.AgD) -> Bool:
  match d:
    case A.AgDData{p, ix, cs, s}:
      Bool.and(S.eq(nm, S.b("Bool")), Nat.is_eq(ast.qs.len(cs), 2n))
    case _:
      False{}

def ast.add.def(s: AstSt, d: A.AgDecl) -> AstSt:
  match s d:
    case AstSt{mods, defs, want, raws, bool} A.AgDecl{q, +nm, mo, f, l, l0, l1, k, m, fl, lang, ty, +dd}:
      AstSt{mods, 1n+defs, want, Nat.add(raws, Bool.pick(Nat, ast.nocomp(fl), 0n, Nat.add(A.aas.raws(ty), A.aas.d.raws(dd)))), Bool.or(bool, ast.is.bool(nm, dd))}

def ast.add(s: AstSt, t: A.AgTop) -> AstSt:
  match s t:
    case AstSt{mods, defs, want, raws, bool} A.AgTopMod{A.AgMod{nm, f, im, op, n}}:
      AstSt{1n+mods, defs, Nat.add(want, n), raws, bool}
    case s A.AgTopDef{d}:
      ast.add.def(s, d)
    case s A.AgTopOther{}:
      s

def ast.top.of(m: Maybe<&2, X.Sx>) -> A.AgTop:
  match m:
    case Some{x}:
      A.aas.top(x)
    case None{}:
      A.AgTopOther{}

def ast.file(ls: List<&2, List<&2, U32>>, s: AstSt) -> AstSt:
  match ls:
    case Nil{}:
      s
    case l <> t:
      ast.file(t, ast.add(s, ast.top.of(X.tsx.one(l))))

def ast.file.ok(s: AstSt) -> Bool:
  match s:
    case AstSt{mods, +defs, want, raws, bool}:
      Bool.and(Bool.and(Nat.is_eq(mods, 1n), Nat.is_eq(defs, want)), Bool.and(Nat.is_eq(raws, 0n), Nat.is_gt(defs, 0n)))

def ast.file.bool(s: AstSt) -> Bool:
  match s:
    case AstSt{mods, defs, want, raws, bool}:
      bool

def ast.laws(+bool: List<&2, U32>, +unit: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    IO.print(verdict("ast keywords classify", Nat.is_eq(ast.kw.ok(ast.words()), 0n)))
    IO.print(verdict("ast keywords distinct", Nat.is_eq(ast.kw.clash(ast.words()), 0n)))
    IO.print(verdict("ast not a keyword", A.aas.kw.eq(A.aas.kw(S.b("Category")), A.AkWord{})))
    +sb : AstSt = ast.file(rt.nonempty(bool), AstSt{0n, 0n, 0n, 0n, False{}})
    IO.print(verdict("ast decode Agda.Builtin.Bool", ast.file.ok(sb)))
    IO.print(verdict("ast Bool is data with 2 constructors", ast.file.bool(sb)))
    IO.print(verdict("ast decode Agda.Builtin.Unit", ast.file.ok(ast.file(rt.nonempty(unit), AstSt{0n, 0n, 0n, 0n, False{}}))))

def main() -> IO(Unit):
  do IO<Unit>:
    +bool : List<&2, U32> <- S.read("fixtures/agda2bend/Agda.Builtin.Bool.sexp")
    +unit : List<&2, U32> <- S.read("fixtures/agda2bend/Agda.Builtin.Unit.sexp")
    sexp.laws(bool, unit)
    ast.laws(bool, unit)
