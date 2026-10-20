import Base
import ../Sys.bend as S
import ../ToBend/Sexp.bend as X
import ../Agda2Bend/Ast.bend as A
import ../ToBend/Ast.bend as T
import ../ToBend/Print.bend as P
import ../Agda2Bend/Cata.bend as C
import ../Agda2Bend.bend as D
import ../ToBend/Gate.bend as G
import ../ToBend/Copy.bend as Q

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
    case A.AgDData{p, ix, cs, s, cl}:
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

# Print ------------------------------------------------------------------------

def v(s: String) -> T.Bt:
  T.BtVar{S.b(s)}

def app(f: String, xs: List<&2, T.Bt>) -> T.Bt:
  T.tba.call(v(f), xs)

# A -> A -> Type
def pr.rel(+a: String) -> T.Bt:
  T.BtPi{T.BmLive{}, S.b("_"), False{}, v(a), T.BtPi{T.BmLive{}, S.b("_"), False{}, v(a), T.BtType{}}}

# @-x:A -> R(x, x)
def pr.refl.ty() -> T.Bt:
  T.BtPi{T.BmErased{}, S.b("x"), True{}, v("A"), app("R", [v("x"), v("x")])}

def pr.isequiv() -> T.BItem:
  T.BiType{S.b("IsEquivalence"), [T.BParam{T.BmErased{}, S.b("A"), T.BtType{}}, T.BParam{T.BmErased{}, S.b("R"), pr.rel("A")}], False{},
    [T.BCtor{S.b("IsEquivalence"), [T.BField{S.b("refl"), pr.refl.ty()}, T.BField{S.b("sym"), T.BtPi{T.BmErased{}, S.b("x"), True{}, v("A"), T.BtPi{T.BmErased{}, S.b("y"), True{}, v("A"), T.BtPi{T.BmLive{}, S.b("_"), False{}, app("R", [v("x"), v("y")]), app("R", [v("y"), v("x")])}}}}]}],
    [S.b("IsEquivalence (agda-stdlib Relation.Binary)")]}

def pr.proj() -> T.BItem:
  T.BiDef{S.b("IsEquivalence.refl"), [T.BParam{T.BmErased{}, S.b("A"), T.BtType{}}, T.BParam{T.BmErased{}, S.b("R"), pr.rel("A")}, T.BParam{T.BmLive{}, S.b("e"), T.BtTyApp{S.b("IsEquivalence"), T.tba.args([v("A"), v("R")])}}],
    pr.refl.ty(), T.BtMatch{T.tba.args([v("e")]), T.BtCase{T.tba.args([T.BtCon{S.b("IsEquivalence"), T.tba.args([v("refl"), v("sym")])}]), T.BtExpr{v("refl")}, T.BtCEnd{}}}, Nil{}}

def pr.want() -> String:
  "# a file\nimport Base\nimport ./Other.bend as O\n\n# IsEquivalence (agda-stdlib Relation.Binary)\ntype IsEquivalence<-A: Type, -R: A -> A -> Type> is Type:\n  IsEquivalence{refl: @-x:A -> R(x, x), sym: @-x:A -> @-y:A -> R(x, y) -> R(y, x)}\n\ndef IsEquivalence.refl(-A: Type, -R: A -> A -> Type, e: IsEquivalence<A, R>) -> @-x:A -> R(x, x):\n  match e:\n    case IsEquivalence{refl, sym}:\n      refl\n"

def pr.file() -> List<&2, U32>:
  P.tpr.file(T.BFile{[S.b("a file")], [T.BImport{S.b("./Other.bend"), S.b("O")}], [pr.isequiv(), pr.proj()]})

# terms: a Pi in a domain and a lambda at a head are parenthesized; a
# template argument; erased and live dependent Pis; an equation, a literal,
# a successor, an annotation, a constructor with no fields
def pr.terms() -> List<&2, U32>:
  P.tpr.t(T.tba.args([
    T.BtPi{T.BmLive{}, S.b("_"), False{}, T.BtPi{T.BmLive{}, S.b("_"), False{}, v("A"), v("B")}, v("C")},
    T.BtApp{T.BtLam{T.BmLive{}, S.b("x"), v("x")}, T.tba.args([v("y")])},
    app("f", [T.BtTplArg{v("C")}, T.BtEq{v("Nat"), T.BtNat{S.b("2")}, T.BtSucc{v("p")}}]),
    T.BtPi{T.BmLive{}, S.b("x"), True{}, v("A"), app("B", [v("x")])},
    T.BtAnn{T.BtCon{S.b("Unit"), T.BtANil{}}, v("Unit")},
    T.BtLam{T.BmCopy{}, S.b("h"), T.BtStr{S.b("a\"b")}}]), P.TpLoose{}, 0n, Nil{})

def pr.terms.want() -> String:
  "(A -> B) -> C, (x => x)(y), f(~C, {2n == 1n+p : Nat}), @x:A -> B(x), {Unit{} : Unit}, +h => \"a\\\"b\""

def print.laws() -> IO(Unit):
  do IO<Unit>:
    IO.print(verdict("print a type and a projection as the spike writes them", S.eq(pr.file(), S.b(pr.want()))))
    IO.print(verdict("print terms", S.eq(pr.terms(), S.b(pr.terms.want()))))

# Gate and quantity repairs ----------------------------------------------------------

def gt.pr(it: T.BItem) -> List<&2, U32>:
  P.tpr.file(T.BFile{Nil{}, Nil{}, [it]})

def gt.prm(m: Maybe<&2, T.BItem>) -> List<&2, U32>:
  match m:
    case Some{it}:
      gt.pr(it)
    case None{}:
      S.b("none")

# def contra(-A: Type, x: A -> A -> Nat, x_5: A) -> Nat: x(x_5, x_5), the
# arguments dead (x is a variable) when dead is True
def gt.contra(dead: Bool) -> T.BItem:
  +a = Bool.pick(T.Bt, dead, T.BtDead{v("x_5")}, v("x_5"))
  T.BiDef{S.b("contra"), [T.BParam{T.BmErased{}, S.b("A"), T.BtType{}}, T.BParam{T.BmLive{}, S.b("x"), T.BtPi{T.BmLive{}, S.b("_"), False{}, v("A"), T.BtPi{T.BmLive{}, S.b("_"), False{}, v("A"), v("Nat")}}}, T.BParam{T.BmLive{}, S.b("x_5"), v("A")}],
    v("Nat"), T.BtExpr{app("x", [a, a])}, Nil{}}

def gt.contra.want() -> String:
  "import Base\n\ndef contra(-A: Data, x: A -> A -> Nat, +x_5: A) -> Nat:\n  x(x_5, x_5)\n"

# def use(-B: Type, y: B) -> B: y
def gt.use() -> T.BItem:
  T.BiDef{S.b("use"), [T.BParam{T.BmErased{}, S.b("B"), T.BtType{}}, T.BParam{T.BmLive{}, S.b("y"), v("B")}], v("B"), T.BtExpr{v("y")}, Nil{}}

def gate.laws() -> IO(Unit):
  do IO<Unit>:
    IO.print(verdict("the carets mark a binder", S.eq(G.tgt.span(S.split.lines(S.b("Location: u\n1 | def u(-A: Type) -> A -> A:\n2>|   +x_8 => x_8\n  |   ^^^^^\n3 | "))), S.b("+x_8"))))
    IO.print(verdict("the carets mark an argument", S.eq(G.tgt.span(S.split.lines(S.b("  12>|   u02e2(A, B, C, x, g)\n     |         ^\n  13 | "))), S.b("A"))))
    IO.print(verdict("a Type where Data is expected is repair 3", Nat.is_eq(G.tgt.repair.kind(S.b("expected : Data observed : Type ")), 3n)))
    IO.print(verdict("a + parameter typed by a type parameter declares it Data", S.eq(gt.pr(Q.tcp.finish(gt.contra(False{}), Q.tcp.decide(gt.contra(False{}), Nil{}))), S.b(gt.contra.want()))))
    IO.print(verdict("the gate's + repair declares the type parameter Data", S.eq(gt.prm(Q.tcp.raise(gt.contra(True{}), S.b("x_5"), True{})), S.b(gt.contra.want()))))
    IO.print(verdict("a caller's type parameter is declared Data", S.eq(gt.prm(Q.tcp.data.raise(gt.use(), S.b("B"))), S.b("import Base\n\ndef use(-B: Data, y: B) -> B:\n  y\n"))))
    IO.print(verdict("only a type parameter is declared Data", S.eq(gt.prm(Q.tcp.data.raise(gt.use(), S.b("y"))), S.b("none"))))

# Translation --------------------------------------------------------------------
#
# The committed exports of Agda.Primitive, Level and Function.Base (a whole
# import cone) translated in process, each module's file before the gate
# against fixtures/agda2bend/golden/<Module>.bend: the translator's output
# when the goldens were made, reviewed, of which the gate kept
# golden/Function.Base.checked.bend (20 of Function.Base's 33 items) under
# the locked compiler.  A change to the translation shows up here first.

def gold.of(+m: String, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, +ds: List<&2, A.AgDecl>, +want: List<&2, U32>, tr: D.A2bTr) -> D.A2bG & Bool:
  match tr:
    case D.A2bTr{its, g}:
      (g, S.eq(D.a2b.raw.text(S.b(m), al, ral, List.length(&2, A.AgDecl, ds), its), want))

def gold.one(+m: String, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, g: D.A2bG) -> IO(D.A2bG & Bool):
  do IO<D.A2bG & Bool>:
    +ds : List<&2, A.AgDecl> <- D.a2b.decls(S.b("fixtures/agda2bend/" ++ m ++ ".sexp"))
    +want : List<&2, U32> <- S.read("fixtures/agda2bend/golden/" ++ m ++ ".bend")
    return gold.of(m, al, ral, ds, want, D.a2b.mod.items(S.b(m), al, ds, g))

def gold.next(+m: String, +al: Map<&2, List<&2, U32>>, +ral: Map<&2, List<&2, U32>>, r: D.A2bG & Bool) -> IO(D.A2bG):
  (g, ok) = r
  do IO<D.A2bG>:
    IO.print(verdict("translate " ++ m ++ " as its golden", ok))
    return g

def gold.laws() -> IO(Unit):
  +order : List<&2, List<&2, U32>> = [S.b("Agda.Primitive"), S.b("Level"), S.b("Function.Base")]
  +al : Map<&2, List<&2, U32>> = D.a2b.aliases(order)
  +ral : Map<&2, List<&2, U32>> = D.a2b.ral(order, al, Map.new(&2, List<&2, U32>))
  do IO<Unit>:
    r1 : D.A2bG & Bool <- gold.one("Agda.Primitive", al, ral, D.A2bG{Map.new(&2, C.ActSym), Map.new(&2, C.ActCopy), Map.new(&2, Bool)})
    g1 : D.A2bG <- gold.next("Agda.Primitive", al, ral, r1)
    r2 : D.A2bG & Bool <- gold.one("Level", al, ral, g1)
    g2 : D.A2bG <- gold.next("Level", al, ral, r2)
    r3 : D.A2bG & Bool <- gold.one("Function.Base", al, ral, g2)
    g3 : D.A2bG <- gold.next("Function.Base", al, ral, r3)
    return Unit{}

# fixtures/agda2bend/src/A2bFix.agda (its export A2bFix.sexp, after
# Agda.Primitive and Agda.Builtin.Bool): an indexed family (equation fields,
# rewrites at the dot patterns), an absurd clause through a one-field record
# and a type parameter's value used twice; the gate kept all 10 items
# (golden/A2bFix.checked.bend).
def gold.fix.laws() -> IO(Unit):
  +order : List<&2, List<&2, U32>> = [S.b("Agda.Primitive"), S.b("Agda.Builtin.Bool"), S.b("A2bFix")]
  +al : Map<&2, List<&2, U32>> = D.a2b.aliases(order)
  +ral : Map<&2, List<&2, U32>> = D.a2b.ral(order, al, Map.new(&2, List<&2, U32>))
  do IO<Unit>:
    r1 : D.A2bG & Bool <- gold.one("Agda.Primitive", al, ral, D.A2bG{Map.new(&2, C.ActSym), Map.new(&2, C.ActCopy), Map.new(&2, Bool)})
    g1 : D.A2bG <- gold.next("Agda.Primitive", al, ral, r1)
    r2 : D.A2bG & Bool <- gold.one("Agda.Builtin.Bool", al, ral, g1)
    g2 : D.A2bG <- gold.next("Agda.Builtin.Bool", al, ral, r2)
    r3 : D.A2bG & Bool <- gold.one("A2bFix", al, ral, g2)
    g3 : D.A2bG <- gold.next("A2bFix", al, ral, r3)
    return Unit{}

def main() -> IO(Unit):
  do IO<Unit>:
    +bool : List<&2, U32> <- S.read("fixtures/agda2bend/Agda.Builtin.Bool.sexp")
    +unit : List<&2, U32> <- S.read("fixtures/agda2bend/Agda.Builtin.Unit.sexp")
    sexp.laws(bool, unit)
    ast.laws(bool, unit)
    print.laws()
    gate.laws()
    gold.laws()
    gold.fix.laws()
