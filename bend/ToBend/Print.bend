import Base
import ../Sys.bend as S
import ./Ast.bend as T

# Print: Bend 2 source text from the syntax tree of ToBend/Ast.bend, as
# GUIDE.md's syntax reference writes it.  Every def prepends its text to an
# accumulator (`acc`), so a file is built front to back with no appends.
#
# Parentheses go only where the grammar needs them: around a Pi or a
# lambda that is the domain of an arrow or the head of an application.  A
# match is a statement: it is printed on its own lines, indented, wherever
# a def's or a case's body is one.  Every def is prefixed `tpr.`.

# Where a term is printed: anywhere (an argument, a body), the domain of an
# arrow, the head of an application, the rest of an argument list (each
# element after a comma), a statement at an indentation, a case list, or a
# list of scrutinees or patterns (separated by spaces; TpWords for the first),
# or a datatype's arguments (D<..>: a function type there takes parentheses).
type TpK is Data:
  TpLoose{}
  TpWords{}
  TpWordsRest{}
  TpTyArgs{}
  TpTyRest{}
  TpDom{}
  TpHead{}
  TpRest{}
  TpStmt{}
  TpCases{}

def tpr.s(s: String, acc: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, S.b(s), acc)

def tpr.b(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  List.append(&2, U32, xs, acc)

def tpr.spaces(n: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      acc
    case 1n+p:
      32 <> tpr.spaces(p, acc)

# a binder's mode as its prefix: "", "-", "+", "~"
def tpr.mode(m: T.BMode, acc: List<&2, U32>) -> List<&2, U32>:
  match m:
    case T.BmLive{}:
      acc
    case T.BmErased{}:
      45 <> acc
    case T.BmCopy{}:
      43 <> acc
    case T.BmTpl{}:
      126 <> acc

# a lambda's binder: Bend writes + on a lambda, never - or ~
def tpr.lam.mode(m: T.BMode, acc: List<&2, U32>) -> List<&2, U32>:
  match m:
    case T.BmCopy{}:
      43 <> acc
    case _:
      acc

# a Pi's binder: @x: or @-x:, nothing for a non-dependent live arrow
def tpr.pi.head(m: T.BMode, +x: List<&2, U32>, dep: Bool, acc: List<&2, U32>) -> List<&2, U32>:
  match m dep:
    case T.BmErased{} _:
      64 <> 45 <> tpr.b(x, 58 <> acc)
    case _ True{}:
      64 <> tpr.b(x, 58 <> acc)
    case _ False{}:
      acc

def tpr.str.esc(q: Bool, bs: Bool, nl: Bool, h: U32, rest: List<&2, U32>) -> List<&2, U32>:
  match q bs nl:
    case True{} _ _:
      92 <> 34 <> rest
    case False{} True{} _:
      92 <> 92 <> rest
    case False{} False{} True{}:
      92 <> 110 <> rest
    case False{} False{} False{}:
      h <> rest

# a string literal: " and \ escaped, a newline as \n
def tpr.str.go(xs: List<&2, U32>, acc: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      acc
    case +h <> t:
      tpr.str.esc(U32.is_eq(h, 34), U32.is_eq(h, 92), U32.is_eq(h, 10), h, tpr.str.go(t, acc))

# t printed at k: ind is the indentation of a statement (TpStmt, TpCases).
def tpr.t(t: T.Bt, k: TpK, +ind: Nat, acc: List<&2, U32>) -> List<&2, U32>:
  match t k:
    # statements: a match on its own lines, anything else as one line
    case T.BtMatch{xs, cs} TpStmt{}:
      tpr.spaces(ind, tpr.s("match ", tpr.t(xs, TpWords{}, 0n, 58 <> 10 <> tpr.t(cs, TpCases{}, Nat.add(ind, 2n), acc))))
    case T.BtCase{p, b, rest} TpCases{}:
      tpr.spaces(ind, tpr.s("case ", tpr.t(p, TpWords{}, 0n, 58 <> 10 <> tpr.t(b, TpStmt{}, Nat.add(ind, 2n), tpr.t(rest, TpCases{}, ind, acc)))))
    case T.BtCEnd{} TpCases{}:
      acc
    case T.BtRw{e, p, b} TpStmt{}:
      tpr.spaces(ind, 37 <> tpr.t(e, TpHead{}, 0n, tpr.s(" : ", tpr.t(p, TpLoose{}, 0n, 10 <> tpr.t(b, TpStmt{}, ind, acc)))))
    case T.BtLet{x, v, b} TpStmt{}:
      tpr.spaces(ind, tpr.b(x, tpr.s(" = ", tpr.t(v, TpLoose{}, 0n, 10 <> tpr.t(b, TpStmt{}, ind, acc)))))
    case T.BtExpr{e} TpStmt{}:
      tpr.spaces(ind, tpr.t(e, TpLoose{}, 0n, 10 <> acc))
    case T.BtExpr{e} _:
      tpr.t(e, TpLoose{}, 0n, acc)
    # a datatype's arguments: each as an arrow's domain is (a Pi or a
    # lambda parenthesized)
    case T.BtArgs{a, rest} TpTyRest{}:
      44 <> 32 <> tpr.t(a, TpDom{}, 0n, tpr.t(rest, TpTyRest{}, 0n, acc))
    case T.BtArgs{a, rest} TpTyArgs{}:
      tpr.t(a, TpDom{}, 0n, tpr.t(rest, TpTyRest{}, 0n, acc))
    # scrutinees and patterns: separated by one space
    case T.BtArgs{a, rest} TpWordsRest{}:
      32 <> tpr.t(a, TpHead{}, 0n, tpr.t(rest, TpWordsRest{}, 0n, acc))
    case T.BtArgs{a, rest} TpWords{}:
      tpr.t(a, TpHead{}, 0n, tpr.t(rest, TpWordsRest{}, 0n, acc))
    # argument lists: the first element, then ", " before each other
    case T.BtArgs{a, rest} TpRest{}:
      44 <> 32 <> tpr.t(a, TpLoose{}, 0n, tpr.t(rest, TpRest{}, 0n, acc))
    case T.BtArgs{a, rest} _:
      tpr.t(a, TpLoose{}, 0n, tpr.t(rest, TpRest{}, 0n, acc))
    case T.BtANil{} _:
      acc
    # a Pi or a lambda in a domain or a head is parenthesized
    case T.BtPi{m, +x, d, a, b} TpDom{}:
      40 <> tpr.pi.head(m, x, d, tpr.t(a, TpDom{}, 0n, tpr.s(" -> ", tpr.t(b, TpLoose{}, 0n, 41 <> acc))))
    case T.BtPi{m, +x, d, a, b} TpHead{}:
      40 <> tpr.pi.head(m, x, d, tpr.t(a, TpDom{}, 0n, tpr.s(" -> ", tpr.t(b, TpLoose{}, 0n, 41 <> acc))))
    case T.BtPi{m, +x, d, a, b} _:
      tpr.pi.head(m, x, d, tpr.t(a, TpDom{}, 0n, tpr.s(" -> ", tpr.t(b, TpLoose{}, 0n, acc))))
    case T.BtLam{m, x, b} TpDom{}:
      40 <> tpr.lam.mode(m, tpr.b(x, tpr.s(" => ", tpr.t(b, TpLoose{}, 0n, 41 <> acc))))
    case T.BtLam{m, x, b} TpHead{}:
      40 <> tpr.lam.mode(m, tpr.b(x, tpr.s(" => ", tpr.t(b, TpLoose{}, 0n, 41 <> acc))))
    case T.BtLam{m, x, b} _:
      tpr.lam.mode(m, tpr.b(x, tpr.s(" => ", tpr.t(b, TpLoose{}, 0n, acc))))
    # a dead argument prints as itself; a pattern variable with its mode
    case T.BtDead{a} k:
      tpr.t(a, k, ind, acc)
    case T.BtPv{m, x} _:
      tpr.lam.mode(m, tpr.b(x, acc))
    # atoms and bracketed forms
    case T.BtVar{x} _:
      tpr.b(x, acc)
    case T.BtApp{f, args} _:
      tpr.t(f, TpHead{}, 0n, 40 <> tpr.t(args, TpLoose{}, 0n, 41 <> acc))
    case T.BtTplArg{a} _:
      126 <> tpr.t(a, TpLoose{}, 0n, acc)
    case T.BtType{} _:
      tpr.s("Type", acc)
    case T.BtCon{c, args} _:
      tpr.b(c, 123 <> tpr.t(args, TpLoose{}, 0n, 125 <> acc))
    case T.BtTyApp{n, T.BtANil{}} _:
      tpr.b(n, acc)
    case T.BtTyApp{n, args} _:
      tpr.b(n, 60 <> tpr.t(args, TpTyArgs{}, 0n, 62 <> acc))
    case T.BtEq{ty, a, b} _:
      123 <> tpr.t(a, TpLoose{}, 0n, tpr.s(" == ", tpr.t(b, TpLoose{}, 0n, tpr.s(" : ", tpr.t(ty, TpLoose{}, 0n, 125 <> acc)))))
    case T.BtRefl{} _:
      tpr.s("{==}", acc)
    case T.BtNat{s} _:
      tpr.b(s, 110 <> acc)
    case T.BtSucc{a} _:
      tpr.s("1n+", tpr.t(a, TpHead{}, 0n, acc))
    case T.BtStr{s} _:
      34 <> tpr.str.go(s, 34 <> acc)
    case T.BtAnn{a, ty} _:
      123 <> tpr.t(a, TpLoose{}, 0n, tpr.s(" : ", tpr.t(ty, TpLoose{}, 0n, 125 <> acc)))
    case T.BtWild{} _:
      95 <> acc
    case T.BtTodo{why} _:
      tpr.s("?TODO", acc)
    # a match outside a statement cannot be written: the translation never
    # builds one there
    case _ _:
      tpr.s("?TODO", acc)

# Items -------------------------------------------------------------------------

def tpr.doc(ls: List<&2, List<&2, U32>>, acc: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      acc
    case l <> t:
      35 <> 32 <> tpr.b(l, 10 <> tpr.doc(t, acc))

def tpr.param(p: T.BParam, acc: List<&2, U32>) -> List<&2, U32>:
  match p:
    case T.BParam{m, x, ty}:
      tpr.mode(m, tpr.b(x, 58 <> 32 <> tpr.t(ty, TpLoose{}, 0n, acc)))

# params joined by ", " (first: no comma before it)
def tpr.params(ps: List<&2, T.BParam>, first: Bool, acc: List<&2, U32>) -> List<&2, U32>:
  match ps first:
    case Nil{} _:
      acc
    case p <> t True{}:
      tpr.param(p, tpr.params(t, False{}, acc))
    case p <> t False{}:
      44 <> 32 <> tpr.param(p, tpr.params(t, False{}, acc))

def tpr.field(f: T.BField, acc: List<&2, U32>) -> List<&2, U32>:
  match f:
    case T.BField{x, ty}:
      tpr.b(x, 58 <> 32 <> tpr.t(ty, TpLoose{}, 0n, acc))

def tpr.fields(fs: List<&2, T.BField>, first: Bool, acc: List<&2, U32>) -> List<&2, U32>:
  match fs first:
    case Nil{} _:
      acc
    case f <> t True{}:
      tpr.field(f, tpr.fields(t, False{}, acc))
    case f <> t False{}:
      44 <> 32 <> tpr.field(f, tpr.fields(t, False{}, acc))

def tpr.ctors(cs: List<&2, T.BCtor>, acc: List<&2, U32>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      acc
    case T.BCtor{c, fs} <> t:
      32 <> 32 <> tpr.b(c, 123 <> tpr.fields(fs, True{}, 125 <> 10 <> tpr.ctors(t, acc)))

def tpr.typarams(ps: List<&2, T.BParam>, acc: List<&2, U32>) -> List<&2, U32>:
  match ps:
    case Nil{}:
      acc
    case p <> t:
      60 <> tpr.params(p <> t, True{}, 62 <> acc)

def tpr.item(it: T.BItem, acc: List<&2, U32>) -> List<&2, U32>:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      tpr.doc(doc, tpr.s("def ", tpr.b(n, 40 <> tpr.params(ps, True{}, tpr.s(") -> ", tpr.t(ret, TpLoose{}, 0n, 58 <> 10 <> tpr.t(body, TpStmt{}, 2n, acc)))))))
    case T.BiType{n, ps, d, cs, doc}:
      tpr.doc(doc, tpr.s("type ", tpr.b(n, tpr.typarams(ps, tpr.s(Bool.pick(String, d, " is Data:", " is Type:"), 10 <> tpr.ctors(cs, acc))))))
    case T.BiComment{doc}:
      tpr.doc(doc, acc)

# items separated by a blank line
def tpr.items(its: List<&2, T.BItem>, acc: List<&2, U32>) -> List<&2, U32>:
  match its:
    case Nil{}:
      acc
    case it <> t:
      10 <> tpr.item(it, tpr.items(t, acc))

def tpr.imports(ims: List<&2, T.BImport>, acc: List<&2, U32>) -> List<&2, U32>:
  match ims:
    case Nil{}:
      acc
    case T.BImport{p, a} <> t:
      tpr.s("import ", tpr.b(p, tpr.s(" as ", tpr.b(a, 10 <> tpr.imports(t, acc)))))

# a whole file: the header comment, `import Base` and the imports, the items
def tpr.file(f: T.BFile) -> List<&2, U32>:
  match f:
    case T.BFile{head, ims, its}:
      tpr.doc(head, tpr.s("import Base\n", tpr.imports(ims, tpr.items(its, Nil{}))))
