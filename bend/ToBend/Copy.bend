import Base
import ../Sys.bend as S
import ./Ast.bend as T

# Copy: the quantity pass.  Bend is affine: a live variable may be used
# once, twice only when it is bound with + and its type is Data, and any
# number of times when it is a template (~x: syntax substituted at compile
# time, a closed term at every call).  Agda has no such rule, so the fold's
# Bend needs its binders marked, and a hidden parameter the fold erased may
# still be used as a value (`typeOf {A} _ = A`, an instance argument).
#
# Uses are counted in live positions only: a Pi's domain and codomain, a
# datatype's arguments, an equation's sides and type, an annotation's type
# and an argument at an erased parameter (BtDead) are dead, where Bend lets
# a variable repeat.  The cases of a match are alternatives: a variable's
# uses there are the most any one case makes, not their sum.  A use inside
# a lambda is one use, however often the lambda is called.
#
# From the counts, per parameter of a def: erased but used live becomes
# live; used live twice or more becomes + when its type is Data (Nat, Bool,
# Unit, an equation, a Data type the module declares), else a template (a
# record such as a Category, a function).  Templates go first in the
# header, as Bend requires; the callers' arguments follow the new modes
# because Agda2Bend.bend translates the module again with them.  Lambdas
# and pattern variables used twice get + (their types are not known here;
# the gate refuses one that is not Data).  Every def is prefixed `tcp.`.

def tcp.max(+a: Nat, +b: Nat) -> Nat:
  Bool.pick(Nat, Nat.is_lt(a, b), b, a)

# the live uses of x in t
def tcp.uses(+x: List<&2, U32>, t: T.Bt) -> Nat:
  match t:
    case T.BtVar{y}:
      Bool.pick(Nat, S.eq(x, y), 1n, 0n)
    case T.BtApp{f, a}:
      Nat.add(tcp.uses(x, f), tcp.uses(x, a))
    case T.BtLam{m, +y, b}:
      Bool.pick(Nat, S.eq(x, y), 0n, tcp.uses(x, b))
    case T.BtCon{c, a}:
      tcp.uses(x, a)
    case T.BtSucc{a}:
      tcp.uses(x, a)
    case T.BtAnn{a, ty}:
      tcp.uses(x, a)
    case T.BtMatch{xs, cs}:
      Nat.add(tcp.uses(x, xs), tcp.uses(x, cs))
    case T.BtCase{p, b, rest}:
      tcp.max(tcp.uses(x, b), tcp.uses(x, rest))
    case T.BtExpr{e}:
      tcp.uses(x, e)
    case T.BtArgs{a, rest}:
      Nat.add(tcp.uses(x, a), tcp.uses(x, rest))
    case _:
      0n

def tcp.mem(+x: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(S.eq(h, x), tcp.mem(x, t))

# Types a + binder may have: Base's Nat, Bool, Unit, an equation, or one of
# the Data types named in datas.
def tcp.dataish(t: T.Bt, +datas: List<&2, List<&2, U32>>) -> Bool:
  match t:
    case T.BtVar{+x}:
      Bool.or(Bool.or(S.eq(x, S.b("Nat")), S.eq(x, S.b("Bool"))), Bool.or(S.eq(x, S.b("Unit")), tcp.mem(x, datas)))
    case T.BtTyApp{+n, a}:
      tcp.mem(n, datas)
    case T.BtEq{ty, a, b}:
      True{}
    case _:
      False{}

def tcp.mode.by(m: T.BMode, none: Bool, once: Bool, data: Bool) -> T.BMode:
  match none once data:
    case True{} _ _:
      m
    case False{} True{} _:
      T.BmLive{}
    case False{} False{} True{}:
      T.BmCopy{}
    case False{} False{} False{}:
      T.BmTpl{}

def tcp.mode.of(m: T.BMode, +n: Nat, data: Bool) -> T.BMode:
  match m:
    case T.BmTpl{}:
      T.BmTpl{}
    case T.BmCopy{}:
      T.BmCopy{}
    case _:
      tcp.mode.by(m, Nat.is_eq(n, 0n), Nat.is_lt(n, 2n), data)

# a parameter's mode from its uses in the body (a mode only rises: erased,
# live, then copied or a template)
def tcp.param(p: T.BParam, +body: T.Bt, +datas: List<&2, List<&2, U32>>) -> T.BMode:
  match p:
    case T.BParam{m, +x, +ty}:
      tcp.mode.of(m, tcp.uses(x, body), tcp.dataish(ty, datas))

def tcp.params(ps: List<&2, T.BParam>, +body: T.Bt, +datas: List<&2, List<&2, U32>>) -> List<&2, T.BMode>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      tcp.param(p, body, datas) <> tcp.params(t, body, datas)

# a def's parameters' modes as its body needs them, in header order (the
# empty list for any other item)
def tcp.decide(it: T.BItem, +datas: List<&2, List<&2, U32>>) -> List<&2, T.BMode>:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      tcp.params(ps, body, datas)
    case _:
      Nil{}

# the names of the Data types an item list declares
def tcp.datas(its: List<&2, T.BItem>) -> List<&2, List<&2, U32>>:
  match its:
    case Nil{}:
      Nil{}
    case T.BiType{n, ps, True{}, cs, doc} <> t:
      n <> tcp.datas(t)
    case i <> t:
      tcp.datas(t)

# Marking ----------------------------------------------------------------------

def tcp.lam.mode(+n: Nat) -> T.BMode:
  Bool.pick(T.BMode, Nat.is_lt(n, 2n), T.BmLive{}, T.BmCopy{})

# a case's patterns, each variable the body uses twice marked +
def tcp.pats(p: T.Bt, +body: T.Bt) -> T.Bt:
  match p:
    case T.BtPv{m, +x}:
      T.BtPv{tcp.lam.mode(tcp.uses(x, body)), x}
    case T.BtCon{c, a}:
      T.BtCon{c, tcp.pats(a, body)}
    case T.BtSucc{a}:
      T.BtSucc{tcp.pats(a, body)}
    case T.BtArgs{a, rest}:
      T.BtArgs{tcp.pats(a, body), tcp.pats(rest, body)}
    case p:
      p

# lambdas and pattern variables used twice marked +
def tcp.mark(t: T.Bt) -> T.Bt:
  match t:
    case T.BtLam{m, +x, +b}:
      T.BtLam{tcp.lam.mode(tcp.uses(x, b)), x, tcp.mark(b)}
    case T.BtApp{f, a}:
      T.BtApp{tcp.mark(f), tcp.mark(a)}
    case T.BtTplArg{a}:
      T.BtTplArg{tcp.mark(a)}
    case T.BtCon{c, a}:
      T.BtCon{c, tcp.mark(a)}
    case T.BtSucc{a}:
      T.BtSucc{tcp.mark(a)}
    case T.BtAnn{a, ty}:
      T.BtAnn{tcp.mark(a), ty}
    case T.BtDead{a}:
      T.BtDead{a}
    case T.BtMatch{xs, cs}:
      T.BtMatch{xs, tcp.mark(cs)}
    case T.BtCase{p, +b, rest}:
      T.BtCase{tcp.pats(p, b), tcp.mark(b), tcp.mark(rest)}
    case T.BtExpr{e}:
      T.BtExpr{tcp.mark(e)}
    case T.BtArgs{a, rest}:
      T.BtArgs{tcp.mark(a), tcp.mark(rest)}
    case t:
      t

def tcp.set.modes(ps: List<&2, T.BParam>, ms: List<&2, T.BMode>) -> List<&2, T.BParam>:
  match ps ms:
    case T.BParam{m0, x, ty} <> pt m <> mt:
      T.BParam{m, x, ty} <> tcp.set.modes(pt, mt)
    case ps Nil{}:
      ps
    case Nil{} ms:
      Nil{}

def tcp.is.tpl(p: T.BParam) -> Bool:
  match p:
    case T.BParam{T.BmTpl{}, x, ty}:
      True{}
    case _:
      False{}

def tcp.tpl.first(+ps: List<&2, T.BParam>) -> List<&2, T.BParam>:
  List.append(&2, T.BParam, List.filter(~T.BParam, ~(p => tcp.is.tpl(p)), ps), List.filter(~T.BParam, ~(p => Bool.not(tcp.is.tpl(p))), ps))

# A def with its header's modes set (templates first) and its lambdas and
# pattern variables marked.
def tcp.finish(it: T.BItem, ms: List<&2, T.BMode>) -> T.BItem:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      T.BiDef{n, tcp.tpl.first(tcp.set.modes(ps, ms)), ret, tcp.mark(body), doc}
    case it:
      it
