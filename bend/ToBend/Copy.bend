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
    case T.BtRw{e, p, b}:
      tcp.uses(x, b)
    case T.BtLet{y, v, b}:
      Nat.add(tcp.uses(x, v), tcp.uses(x, b))
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

# whether x occurs inside a template argument: a template argument must be
# closed, so a parameter passed there must be a template itself
def tcp.in.tpl(+x: List<&2, U32>, t: T.Bt, +under: Bool) -> Bool:
  match t:
    case T.BtRw{e, p, b}:
      tcp.in.tpl(x, b, under)
    case T.BtLet{y, v, b}:
      Bool.or(tcp.in.tpl(x, v, under), tcp.in.tpl(x, b, under))
    case T.BtVar{y}:
      Bool.and(under, S.eq(x, y))
    case T.BtTplArg{a}:
      tcp.in.tpl(x, a, True{})
    case T.BtApp{f, a}:
      Bool.or(tcp.in.tpl(x, f, under), tcp.in.tpl(x, a, under))
    case T.BtLam{m, y, b}:
      tcp.in.tpl(x, b, under)
    case T.BtCon{c, a}:
      tcp.in.tpl(x, a, under)
    case T.BtSucc{a}:
      tcp.in.tpl(x, a, under)
    case T.BtAnn{a, ty}:
      tcp.in.tpl(x, a, under)
    case T.BtDead{a}:
      tcp.in.tpl(x, a, under)
    case T.BtMatch{xs, cs}:
      tcp.in.tpl(x, cs, under)
    case T.BtCase{p, b, rest}:
      Bool.or(tcp.in.tpl(x, b, under), tcp.in.tpl(x, rest, under))
    case T.BtExpr{e}:
      tcp.in.tpl(x, e, under)
    case T.BtArgs{a, rest}:
      Bool.or(tcp.in.tpl(x, a, under), tcp.in.tpl(x, rest, under))
    case _:
      False{}

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

# Data kinds: a + binder's type must be Data.  When that type is a type
# parameter of the def (`+x: A` with `-A: Type`), the parameter is declared
# `-A: Data` instead; a caller then passes a Data type, or its own type
# parameter, which the gate declares Data the same way (Bend refuses any
# other).  The binders looked at are the parameters and the lambdas at the
# head of the body, whose types are the return type's Pi domains.
def tcp.kind.ty(t: T.Bt) -> Bool:
  match t:
    case T.BtType{}:
      True{}
    case T.BtVar{+d}:
      S.eq(d, S.b("Data"))
    case _:
      False{}

def tcp.ty.put(k: Bool, x: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match k:
    case True{}:
      x <> rest
    case False{}:
      rest

# the parameters that are types (Type or Data): a binder of one of them may
# be +, its parameter then declared Data
def tcp.ty.params(ps: List<&2, T.BParam>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, x, ty} <> t:
      tcp.ty.put(tcp.kind.ty(ty), x, tcp.ty.params(t))

# the name a + binder's type is, put on acc
def tcp.want.put(m: T.BMode, ty: T.Bt, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match m ty:
    case T.BmCopy{} T.BtVar{x}:
      x <> acc
    case _ _:
      acc

def tcp.want.ps(ps: List<&2, T.BParam>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      acc
    case T.BParam{m, x, ty} <> t:
      tcp.want.ps(t, tcp.want.put(m, ty, acc))

# the lambdas at the head of a body against the return type's Pis
def tcp.want.lams(b: T.Bt, ret: T.Bt, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match b ret:
    case T.BtLam{m, x, bb} T.BtPi{pm, px, dep, a, rb}:
      tcp.want.lams(bb, rb, tcp.want.put(m, a, acc))
    case T.BtExpr{e} ret:
      tcp.want.lams(e, ret, acc)
    case _ _:
      acc

def tcp.kind.set(p: T.BParam, +want: List<&2, List<&2, U32>>) -> T.BParam:
  match p:
    case T.BParam{m, +x, T.BtType{}}:
      T.BParam{m, x, Bool.pick(T.Bt, tcp.mem(x, want), T.BtVar{S.b("Data")}, T.BtType{})}
    case p:
      p

def tcp.kinds.ps(ps: List<&2, T.BParam>, +want: List<&2, List<&2, U32>>) -> List<&2, T.BParam>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> t:
      tcp.kind.set(p, want) <> tcp.kinds.ps(t, want)

# a def with the type parameters its + binders' types name declared Data
def tcp.kinds(it: T.BItem) -> T.BItem:
  match it:
    case T.BiDef{n, +ps, +ret, +body, doc}:
      T.BiDef{n, tcp.kinds.ps(ps, tcp.want.lams(body, ret, tcp.want.ps(ps, Nil{}))), ret, body, doc}
    case it:
      it

def tcp.has.type(ps: List<&2, T.BParam>, +v: List<&2, U32>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case T.BParam{m, +x, T.BtType{}} <> t:
      Bool.or(S.eq(x, v), tcp.has.type(t, v))
    case p <> t:
      tcp.has.type(t, v)

def tcp.data.of(hit: Bool, it: T.BItem) -> Maybe<&2, T.BItem>:
  match hit:
    case True{}:
      Some{it}
    case False{}:
      None{}

# The item with its type parameter v declared Data (the gate's repair when
# a call passes v where Data is expected), or None when v is not one.
def tcp.data.raise(it: T.BItem, +v: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match it:
    case T.BiDef{n, +ps, ret, body, doc}:
      tcp.data.of(tcp.has.type(ps, v), T.BiDef{n, tcp.kinds.ps(ps, v <> Nil{}), ret, body, doc})
    case _:
      None{}

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

def tcp.mode.of(m: T.BMode, +n: Nat, data: Bool, tpl: Bool) -> T.BMode:
  match m tpl:
    case T.BmTpl{} _:
      T.BmTpl{}
    case _ True{}:
      T.BmTpl{}
    case T.BmCopy{} False{}:
      T.BmCopy{}
    case m False{}:
      tcp.mode.by(m, Nat.is_eq(n, 0n), Nat.is_lt(n, 2n), data)

# a parameter's mode from its uses in the body (a mode only rises: erased,
# live, then copied or a template)
def tcp.param(p: T.BParam, +body: T.Bt, +datas: List<&2, List<&2, U32>>) -> T.BMode:
  match p:
    case T.BParam{m, +x, +ty}:
      tcp.mode.of(m, tcp.uses(x, body), tcp.dataish(ty, datas), tcp.in.tpl(x, body, False{}))

def tcp.params(ps: List<&2, T.BParam>, +body: T.Bt, +datas: List<&2, List<&2, U32>>) -> List<&2, T.BMode>:
  match ps:
    case Nil{}:
      Nil{}
    case +p <> t:
      tcp.param(p, body, datas) <> tcp.params(t, body, datas)

# Templates go first, so a parameter a template's type mentions must be a
# template too (`~x: A` cannot come before A otherwise): the names the
# templates' types mention, and the modes with those raised, to a fixed
# point (one parameter more each round at least, so the parameter count of
# rounds is enough).
def tcp.tpl.names(ps: List<&2, T.BParam>, ms: List<&2, T.BMode>, acc: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match ps ms:
    case T.BParam{x, n, ty} <> pt T.BmTpl{} <> mt:
      tcp.tpl.names(pt, mt, T.tba.refs(ty, acc))
    case p <> pt m <> mt:
      tcp.tpl.names(pt, mt, acc)
    case _ _:
      acc

def tcp.tpl.raise(ps: List<&2, T.BParam>, ms: List<&2, T.BMode>, +ns: List<&2, List<&2, U32>>) -> List<&2, T.BMode>:
  match ps ms:
    case T.BParam{x, +n, ty} <> pt m <> mt:
      Bool.pick(T.BMode, tcp.mem(n, ns), T.BmTpl{}, m) <> tcp.tpl.raise(pt, mt, ns)
    case _ ms:
      ms

def tcp.close(fuel: Nat, +ps: List<&2, T.BParam>, +ms: List<&2, T.BMode>) -> List<&2, T.BMode>:
  match fuel:
    case 0n:
      ms
    case 1n+p:
      tcp.close(p, ps, tcp.tpl.raise(ps, ms, tcp.tpl.names(ps, ms, Nil{})))

# a def's parameters' modes as its body needs them, in header order (the
# empty list for any other item)
def tcp.decide(it: T.BItem, +datas: List<&2, List<&2, U32>>) -> List<&2, T.BMode>:
  match it:
    case T.BiDef{n, +ps, ret, body, doc}:
      tcp.close(List.length(&2, T.BParam, ps), ps, tcp.params(ps, body, List.append(&2, List<&2, U32>, tcp.ty.params(ps), datas)))
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

# an erased lambda (an eta-expansion's, at an erased parameter) stays erased
def tcp.lam.keep(m: T.BMode, +n: Nat) -> T.BMode:
  match m:
    case T.BmErased{}:
      T.BmErased{}
    case _:
      tcp.lam.mode(n)

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
    case T.BtRw{e, p, b}:
      T.BtRw{e, p, tcp.mark(b)}
    case T.BtLet{y, v, b}:
      T.BtLet{y, tcp.mark(v), tcp.mark(b)}
    case T.BtLam{m, +x, +b}:
      T.BtLam{tcp.lam.keep(m, tcp.uses(x, b)), x, tcp.mark(b)}
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
      tcp.kinds(T.BiDef{n, tcp.tpl.first(tcp.set.modes(ps, ms)), ret, tcp.mark(body), doc})
    case it:
      it

# Repairs the gate asks for -------------------------------------------------------
#
# When Bend's check names a binder (x consumed more than once; -x expected
# where x is used live), the gate raises that binder and checks again
# instead of dropping the def: + on a parameter, lambda or pattern variable
# used twice; live for an erased parameter used as a value.  A binder that
# is already there cannot be raised again, and the def is then dropped.

type TcpR is Data:
  TcpR{t: T.Bt, changed: Bool}

# rebuild the node of kind k from its two parts
def tcp.r.mk(k: Nat, x: T.Bt, y: T.Bt) -> T.Bt:
  match k:
    case 0n:
      T.BtApp{x, y}
    case 1n+p:
      T.BtArgs{x, y}

def tcp.r.app(a: TcpR, b: TcpR, k: Nat) -> TcpR:
  match a b:
    case TcpR{x, c1} TcpR{y, c2}:
      TcpR{tcp.r.mk(k, x, y), Bool.or(c1, c2)}

def tcp.r.mk1(k: Nat, x: T.Bt) -> T.Bt:
  match k:
    case 0n:
      T.BtExpr{x}
    case 1n+p:
      T.BtDead{x}

def tcp.r.one(r: TcpR, k: Nat) -> TcpR:
  match r:
    case TcpR{x, c}:
      TcpR{tcp.r.mk1(k, x), c}

def tcp.lam.raise(hit: Bool, +m: T.BMode, +x: List<&2, U32>, r: TcpR) -> TcpR:
  match hit m r:
    case True{} T.BmLive{} TcpR{b, c}:
      TcpR{T.BtLam{T.BmCopy{}, x, b}, True{}}
    case _ m TcpR{b, c}:
      TcpR{T.BtLam{m, x, b}, c}

def tcp.pv.raise(hit: Bool, +m: T.BMode, +x: List<&2, U32>) -> TcpR:
  match hit m:
    case True{} T.BmLive{}:
      TcpR{T.BtPv{T.BmCopy{}, x}, True{}}
    case _ m:
      TcpR{T.BtPv{m, x}, False{}}

def tcp.raise.con(c: List<&2, U32>, r: TcpR) -> TcpR:
  match r:
    case TcpR{a, ch}:
      TcpR{T.BtCon{c, a}, ch}

def tcp.raise.match(xs: T.Bt, r: TcpR) -> TcpR:
  match r:
    case TcpR{cs, ch}:
      TcpR{T.BtMatch{xs, cs}, ch}

def tcp.raise.case(p: TcpR, b: TcpR, rest: TcpR) -> TcpR:
  match p b rest:
    case TcpR{p1, c1} TcpR{b1, c2} TcpR{r1, c3}:
      TcpR{T.BtCase{p1, b1, r1}, Bool.or(c1, Bool.or(c2, c3))}

def tcp.raise.rw(e: T.Bt, p: T.Bt, r: TcpR) -> TcpR:
  match r:
    case TcpR{b, ch}:
      TcpR{T.BtRw{e, p, b}, ch}

# the lambdas and pattern variables named v in t given +
def tcp.raise.t(t: T.Bt, +v: List<&2, U32>) -> TcpR:
  match t:
    case T.BtRw{e, p, b}:
      tcp.raise.rw(e, p, tcp.raise.t(b, v))
    case T.BtLam{+m, +x, b}:
      tcp.lam.raise(S.eq(x, v), m, x, tcp.raise.t(b, v))
    case T.BtPv{+m, +x}:
      tcp.pv.raise(S.eq(x, v), m, x)
    case T.BtApp{f, a}:
      tcp.r.app(tcp.raise.t(f, v), tcp.raise.t(a, v), 0n)
    case T.BtArgs{a, rest}:
      tcp.r.app(tcp.raise.t(a, v), tcp.raise.t(rest, v), 1n)
    case T.BtExpr{e}:
      tcp.r.one(tcp.raise.t(e, v), 0n)
    case T.BtDead{e}:
      tcp.r.one(tcp.raise.t(e, v), 1n)
    case T.BtCon{c, a}:
      tcp.raise.con(c, tcp.raise.t(a, v))
    case T.BtMatch{xs, cs}:
      tcp.raise.match(xs, tcp.raise.t(cs, v))
    case T.BtCase{p, b, rest}:
      tcp.raise.case(tcp.raise.t(p, v), tcp.raise.t(b, v), tcp.raise.t(rest, v))
    case t:
      TcpR{t, False{}}

# a parameter named v raised: to + (copy) from live, or to live from erased
type TcpP is Data:
  TcpP{ps: List<&2, T.BParam>, changed: Bool}

def tcp.p.put(p: T.BParam, r: TcpP, ch: Bool) -> TcpP:
  match r:
    case TcpP{ps, c}:
      TcpP{p <> ps, Bool.or(c, ch)}

def tcp.p.raise(hit: Bool, copy: Bool, p: T.BParam) -> T.BParam & Bool:
  match hit copy p:
    case True{} True{} T.BParam{T.BmLive{}, x, ty}:
      (T.BParam{T.BmCopy{}, x, ty}, True{})
    case True{} False{} T.BParam{T.BmErased{}, x, ty}:
      (T.BParam{T.BmLive{}, x, ty}, True{})
    case _ _ p:
      (p, False{})

def tcp.p.step(r: T.BParam & Bool, rest: TcpP) -> TcpP:
  (p, ch) = r
  tcp.p.put(p, rest, ch)

def tcp.p.name(p: T.BParam) -> List<&2, U32>:
  match p:
    case T.BParam{m, x, ty}:
      x

def tcp.raise.ps(ps: List<&2, T.BParam>, +v: List<&2, U32>, +copy: Bool) -> TcpP:
  match ps:
    case Nil{}:
      TcpP{Nil{}, False{}}
    case +p <> t:
      tcp.p.step(tcp.p.raise(S.eq(tcp.p.name(p), v), copy, p), tcp.raise.ps(t, v, copy))

def tcp.raise.def(n: List<&2, U32>, r: TcpP, ret: T.Bt, b: TcpR, doc: List<&2, List<&2, U32>>) -> Maybe<&2, T.BItem>:
  match r b:
    case TcpP{ps, False{}} TcpR{body, False{}}:
      None{}
    case TcpP{ps, c1} TcpR{body, c2}:
      Some{tcp.kinds(T.BiDef{n, ps, ret, body, doc})}

# The item with binder v raised (copy: + for a use twice, else live for
# an erased one used live), or None when nothing could be raised.
def tcp.raise(it: T.BItem, +v: List<&2, U32>, +copy: Bool) -> Maybe<&2, T.BItem>:
  match it copy:
    case T.BiDef{n, ps, ret, body, doc} True{}:
      tcp.raise.def(n, tcp.raise.ps(ps, v, True{}), ret, tcp.raise.t(body, v), doc)
    case T.BiDef{n, ps, ret, body, doc} False{}:
      tcp.raise.def(n, tcp.raise.ps(ps, v, False{}), ret, TcpR{body, False{}}, doc)
    case _ _:
      None{}
