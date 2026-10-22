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

# the uses of x in t, those at a variable's arguments (mode unknown) counted
# as live: a parameter falls to erased only when it has none
def tcp.uses.unk(+x: List<&2, U32>, t: T.Bt) -> Nat:
  match t:
    case T.BtRw{e, p, b}:
      Nat.add(tcp.uses.unk(x, e), tcp.uses.unk(x, b))
    case T.BtTplArg{a}:
      tcp.uses.unk(x, a)
    case T.BtLet{y, v, b}:
      Nat.add(tcp.uses.unk(x, v), tcp.uses.unk(x, b))
    case T.BtVar{y}:
      Bool.pick(Nat, S.eq(x, y), 1n, 0n)
    case T.BtApp{f, a}:
      Nat.add(tcp.uses.unk(x, f), tcp.uses.unk(x, a))
    case T.BtLam{m, +y, b}:
      Bool.pick(Nat, S.eq(x, y), 0n, tcp.uses.unk(x, b))
    case T.BtCon{c, a}:
      tcp.uses.unk(x, a)
    case T.BtSucc{a}:
      tcp.uses.unk(x, a)
    case T.BtAnn{a, ty}:
      tcp.uses.unk(x, a)
    case T.BtMatch{xs, cs}:
      Nat.add(tcp.uses.unk(x, xs), tcp.uses.unk(x, cs))
    case T.BtCase{p, b, rest}:
      tcp.max(tcp.uses.unk(x, b), tcp.uses.unk(x, rest))
    case T.BtExpr{e}:
      tcp.uses.unk(x, e)
    case T.BtArgs{a, rest}:
      Nat.add(tcp.uses.unk(x, a), tcp.uses.unk(x, rest))
    case T.BtDead{T.BtDead{a}}:
      tcp.uses.unk(x, a)
    case _:
      0n


# whether a byte can be part of a name
def tcp.namec(+c: U32) -> Bool:
  Bool.or(Bool.or(Bool.and(U32.is_le(48, c), U32.is_le(c, 57)), Bool.and(U32.is_le(65, c), U32.is_le(c, 90))), Bool.or(Bool.and(U32.is_le(97, c), U32.is_le(c, 122)), Bool.or(U32.is_eq(c, 95), U32.is_eq(c, 46))))

def tcp.bound.at(xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +c <> t:
      Bool.not(tcp.namec(c))

# whether q occurs in xs as a whole name
def tcp.tok.in(xs: List<&2, U32>, +q: List<&2, U32>, prev: Bool) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> +t:
      Bool.or(Bool.and(prev, Bool.and(S.prefix(c <> t, q), tcp.bound.at(List.drop(&2, U32, c <> t, S.len(q))))), tcp.tok.in(t, q, Bool.not(tcp.namec(c))))

# whether a name is x or a quantity minimum "(… x …)" naming it
def tcp.names.x(+y: List<&2, U32>, +x: List<&2, U32>) -> Bool:
  Bool.or(S.eq(x, y), Bool.and(S.head.is(y, 40), tcp.tok.in(y, x, True{})))

def tcp.mem(+x: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(S.eq(h, x), tcp.mem(x, t))

# (a quantity minimum among xs names each quantity inside it)
def tcp.mem.q(+x: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +h <> t:
      Bool.or(tcp.names.x(h, x), tcp.mem.q(x, t))

# whether x occurs inside a template argument: a template argument must be
# closed, so a parameter passed there must be a template itself
# (at a live place only: in a dead one, a Pi, an equation or an argument at
# an erased parameter, Bend takes any variable there, even an erased one, so
# `P =[ f ]⇒ Q = P ⇒ (Q on f)` keeps f erased and `_on_`'s template stops
# there instead of reaching every Congruent₁ f with a variable f); a
# variable's argument, whose mode is not known (BtDead twice), counts as live
def tcp.in.tpl(+x: List<&2, U32>, t: T.Bt, +under: Bool) -> Bool:
  match t:
    case T.BtRw{e, p, b}:
      tcp.in.tpl(x, b, under)
    case T.BtLet{y, v, b}:
      Bool.or(tcp.in.tpl(x, v, under), tcp.in.tpl(x, b, under))
    case T.BtVar{+y}:
      Bool.and(under, tcp.names.x(y, x))
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
    case T.BtDead{T.BtDead{a}}:
      tcp.in.tpl(x, a, under)
    case T.BtDead{a}:
      Bool.and(under, tcp.in.tpl(x, a, under))
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
    case T.BtApp{T.BtVar{+k}, a}:
      S.eq(k, S.b("Kind"))
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
    case T.BParam{m, +x, T.BtApp{T.BtVar{+k}, +a}}:
      T.BParam{m, x, Bool.pick(T.Bt, Bool.and(S.eq(k, S.b("Kind")), tcp.mem(x, want)), T.BtVar{S.b("Data")}, T.BtApp{T.BtVar{k}, a})}
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
    case T.BParam{m, +x, T.BtApp{T.BtVar{+k}, a}} <> t:
      Bool.or(Bool.and(S.eq(k, S.b("Kind")), S.eq(x, v)), tcp.has.type(t, v))
    case p <> t:
      tcp.has.type(t, v)

def tcp.data.of(hit: Bool, it: T.BItem) -> Maybe<&2, T.BItem>:
  match hit:
    case True{}:
      Some{it}
    case False{}:
      None{}

# A point-free def's type parameters are its return type's Pis, bound by
# the body's head lambdas (`_-[_]-_`'s eta1 … eta5): the return type with
# the Pi whose lambda is v declared Data, and whether there was one.
type TcpRet is Data:
  TcpRet{ret: T.Bt, hit: Bool}

def tcp.ret.put(+hit: Bool, pm: T.BMode, px: List<&2, U32>, dep: Bool, a: T.Bt, r: TcpRet) -> TcpRet:
  match r:
    case TcpRet{rb, h}:
      TcpRet{T.BtPi{pm, px, dep, Bool.pick(T.Bt, hit, T.BtVar{S.b("Data")}, a), rb}, Bool.or(hit, h)}

def tcp.ret.data(b: T.Bt, ret: T.Bt, +v: List<&2, U32>) -> TcpRet:
  match b ret:
    case T.BtLam{m, +x, bb} T.BtPi{pm, px, dep, T.BtType{}, rb}:
      tcp.ret.put(S.eq(x, v), pm, px, dep, T.BtType{}, tcp.ret.data(bb, rb, v))
    case T.BtLam{m, x, bb} T.BtPi{pm, px, dep, a, rb}:
      tcp.ret.put(False{}, pm, px, dep, a, tcp.ret.data(bb, rb, v))
    case T.BtExpr{e} ret:
      tcp.ret.data(e, ret, v)
    case _ ret:
      TcpRet{ret, False{}}

def tcp.data.ret(r: TcpRet, n: List<&2, U32>, ps: List<&2, T.BParam>, body: T.Bt, doc: List<&2, List<&2, U32>>) -> Maybe<&2, T.BItem>:
  match r:
    case TcpRet{ret, True{}}:
      Some{T.BiDef{n, ps, ret, body, doc}}
    case _:
      None{}

def tcp.data.or(hit: Bool, +it: T.BItem, r: TcpRet, n: List<&2, U32>, ps: List<&2, T.BParam>, body: T.Bt, doc: List<&2, List<&2, U32>>) -> Maybe<&2, T.BItem>:
  match hit:
    case True{}:
      Some{it}
    case False{}:
      tcp.data.ret(r, n, ps, body, doc)

# The item with its type parameter v declared Data (the gate's repair when
# a call passes v where Data is expected), or None when v is not one; a
# head lambda v of a point-free def has its return type's Pi raised instead.
def tcp.data.raise(it: T.BItem, +v: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match it:
    case T.BiDef{+n, +ps, +ret, +body, +doc}:
      tcp.data.or(tcp.has.type(ps, v), T.BiDef{n, tcp.kinds.ps(ps, v <> Nil{}), ret, body, doc}, tcp.ret.data(body, ret, v), n, ps, body, doc)
    case _:
      None{}

# a live parameter with no live use falls to erased: a reasoning chain's
# points (`step-≈-⟩ x …` takes x explicitly, but only its type mentions it)
# are then dead wherever they are passed, so a proof may repeat them
def tcp.lower(m: T.BMode) -> T.BMode:
  match m:
    case T.BmLive{}:
      T.BmErased{}
    case m:
      m

def tcp.mode.low(m: T.BMode, low: Bool) -> T.BMode:
  match low:
    case True{}:
      tcp.lower(m)
    case False{}:
      m

# Quantity specialisation (a repair the gate asks for) -------------------------
#
# A def that copies a value whose type's kind is a quantity parameter's (`+p`
# with p a morphism pair, of Kind(qℓ <&> qℓ′)) does not check at every
# quantity.  So it is specialised to &2 (Data) in each quantity parameter
# the checker's observed type names.  The parameter stays, since callers
# still pass it; its uses become &2.  A caller that passes its own quantity
# where &2 is now expected is specialised the same way.  The result is
# weaker than the Agda original (it holds for Data homs only), as the user
# chose on 2026-10-20; the def's comment says so.

def tcp.q.params(ps: List<&2, T.BParam>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, +x, T.BtVar{+k}} <> t:
      tcp.ty.put(S.eq(k, S.b("Quant")), x, tcp.q.params(t))
    case p <> t:
      tcp.q.params(t)

# the text before and after "observed : "
def tcp.obs.of(m: Maybe<&2, Nat>, +w: List<&2, U32>) -> List<&2, U32>:
  match m:
    case Some{i}:
      List.drop(&2, U32, w, i)
    case None{}:
      Nil{}

def tcp.obs(+w: List<&2, U32>) -> List<&2, U32>:
  tcp.obs.of(S.find(w, S.b("observed : "), 0n), w)

def tcp.exp.of(m: Maybe<&2, Nat>, +w: List<&2, U32>) -> List<&2, U32>:
  match m:
    case Some{i}:
      List.take(&2, U32, w, i)
    case None{}:
      w

# the quantity parameters the observed type names and the expected does not
def tcp.q.cands(qs: List<&2, List<&2, U32>>, +exp: List<&2, U32>, +obs: List<&2, U32>) -> List<&2, List<&2, U32>>:
  match qs:
    case Nil{}:
      Nil{}
    case +q <> t:
      tcp.ty.put(Bool.and(tcp.tok.in(obs, q, True{}), Bool.not(tcp.tok.in(exp, q, True{}))), q, tcp.q.cands(t, exp, obs))

# a name with q as &2: q itself, or q inside a minimum "(a <&> b)"
def tcp.q.name(+n: List<&2, U32>, +q: List<&2, U32>, +lit: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.eq(n, q), lit, S.replace(S.replace(n, 40 <> List.append(&2, U32, q, [32]), 40 <> List.append(&2, U32, lit, [32])), 32 <> List.append(&2, U32, q, [41]), 32 <> List.append(&2, U32, lit, [41])))

# t with the quantity q as &2 everywhere
def tcp.qsub(t: T.Bt, +q: List<&2, U32>, +lit: List<&2, U32>) -> T.Bt:
  match t:
    case T.BtVar{+n}:
      T.BtVar{tcp.q.name(n, q, lit)}
    case T.BtApp{f, a}:
      T.BtApp{tcp.qsub(f, q, lit), tcp.qsub(a, q, lit)}
    case T.BtArgs{a, rest}:
      T.BtArgs{tcp.qsub(a, q, lit), tcp.qsub(rest, q, lit)}
    case T.BtTplArg{a}:
      T.BtTplArg{tcp.qsub(a, q, lit)}
    case T.BtLam{m, y, b}:
      T.BtLam{m, y, tcp.qsub(b, q, lit)}
    case T.BtPi{m, y, d, a, b}:
      T.BtPi{m, y, d, tcp.qsub(a, q, lit), tcp.qsub(b, q, lit)}
    case T.BtCon{c, a}:
      T.BtCon{c, tcp.qsub(a, q, lit)}
    case T.BtTyApp{c, a}:
      T.BtTyApp{c, tcp.qsub(a, q, lit)}
    case T.BtEq{ty, a, b}:
      T.BtEq{tcp.qsub(ty, q, lit), tcp.qsub(a, q, lit), tcp.qsub(b, q, lit)}
    case T.BtSucc{a}:
      T.BtSucc{tcp.qsub(a, q, lit)}
    case T.BtAnn{a, ty}:
      T.BtAnn{tcp.qsub(a, q, lit), tcp.qsub(ty, q, lit)}
    case T.BtDead{a}:
      T.BtDead{tcp.qsub(a, q, lit)}
    case T.BtMatch{xs, cs}:
      T.BtMatch{tcp.qsub(xs, q, lit), tcp.qsub(cs, q, lit)}
    case T.BtCase{p, b, rest}:
      T.BtCase{p, tcp.qsub(b, q, lit), tcp.qsub(rest, q, lit)}
    case T.BtExpr{e}:
      T.BtExpr{tcp.qsub(e, q, lit)}
    case T.BtRw{e, p, b}:
      T.BtRw{tcp.qsub(e, q, lit), tcp.qsub(p, q, lit), tcp.qsub(b, q, lit)}
    case T.BtLet{y, v, b}:
      T.BtLet{y, tcp.qsub(v, q, lit), tcp.qsub(b, q, lit)}
    case t:
      t

def tcp.qsub.ps(ps: List<&2, T.BParam>, +q: List<&2, U32>, +lit: List<&2, U32>) -> List<&2, T.BParam>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, x, ty} <> t:
      T.BParam{m, x, tcp.qsub(ty, q, lit)} <> tcp.qsub.ps(t, q, lit)

def tcp.q.note(+lit: List<&2, U32>) -> String:
  Bool.pick(String, S.eq(lit, S.b("&2")), " (Data), weaker than the Agda original", " (Type)")

def tcp.q.one(it: T.BItem, +q: List<&2, U32>, +lit: List<&2, U32>) -> T.BItem:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      T.BiDef{n, tcp.qsub.ps(ps, q, lit), tcp.qsub(ret, q, lit), tcp.qsub(body, q, lit), List.append(&2, List<&2, U32>, doc, [S.b("specialised: quantity " ++ S.str(q) ++ " is " ++ S.str(lit) ++ tcp.q.note(lit))])}
    case it:
      it

def tcp.q.item(qs: List<&2, List<&2, U32>>, it: T.BItem, +lit: List<&2, U32>) -> T.BItem:
  match qs:
    case Nil{}:
      it
    case +q <> t:
      tcp.q.item(t, tcp.q.one(it, q, lit), lit)

def tcp.q.done(+qs: List<&2, List<&2, U32>>, it: T.BItem, +lit: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match qs:
    case Nil{}:
      None{}
    case q <> t:
      Some{tcp.q.item(qs, it, lit)}

# The item specialised in the quantities the failure names, or None: to &2
# those the observed type names (a copy needs Data), to &1 those the
# expected kind names (a Type fills a Kind(q): `_≉_ = λ x y → ¬ …`).
def tcp.q.spec(+it: T.BItem, +why: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match it:
    case T.BiDef{n, +ps, ret, body, doc}:
      tcp.q.done(tcp.q.cands(tcp.q.params(ps), tcp.exp.of(S.find(why, S.b("observed : "), 0n), why), tcp.obs(why)), it, S.b("&2"))
    case _:
      None{}

def tcp.q.spec1(+it: T.BItem, +why: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match it:
    case T.BiDef{n, +ps, ret, body, doc}:
      tcp.q.done(tcp.q.cands(tcp.q.params(ps), tcp.obs(why), tcp.exp.of(S.find(why, S.b("observed : "), 0n), why)), it, S.b("&1"))
    case _:
      None{}

# the gate's Data repair, then the quantity one
def tcp.data.or.q(m: Maybe<&2, T.BItem>, +it: T.BItem, +why: List<&2, U32>) -> Maybe<&2, T.BItem>:
  match m:
    case Some{x}:
      Some{x}
    case None{}:
      tcp.q.spec(it, why)

def tcp.mode.by(m: T.BMode, none: Bool, once: Bool, data: Bool, low: Bool) -> T.BMode:
  match none once data:
    case True{} _ _:
      tcp.mode.low(m, low)
    case False{} True{} _:
      T.BmLive{}
    case False{} False{} True{}:
      T.BmCopy{}
    case False{} False{} False{}:
      T.BmTpl{}

def tcp.mode.of(m: T.BMode, +n: Nat, data: Bool, tpl: Bool, low: Bool) -> T.BMode:
  match m tpl:
    case T.BmTpl{} _:
      T.BmTpl{}
    case _ True{}:
      T.BmTpl{}
    case T.BmCopy{} False{}:
      T.BmCopy{}
    case m False{}:
      tcp.mode.by(m, Nat.is_eq(n, 0n), Nat.is_lt(n, 2n), data, low)

# a parameter's mode from its uses in the body (a mode rises: erased, live,
# then copied or a template; a live one with no live use falls to erased)
def tcp.param(p: T.BParam, +body: T.Bt, +datas: List<&2, List<&2, U32>>) -> T.BMode:
  match p:
    case T.BParam{m, +x, +ty}:
      tcp.mode.of(m, tcp.uses(x, body), tcp.dataish(ty, datas), tcp.in.tpl(x, body, False{}), Nat.is_eq(tcp.uses.unk(x, body), 0n))

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
      Bool.pick(T.BMode, tcp.mem.q(n, ns), T.BmTpl{}, m) <> tcp.tpl.raise(pt, mt, ns)
    case _ ms:
      ms

def tcp.close(fuel: Nat, +ps: List<&2, T.BParam>, +ms: List<&2, T.BMode>) -> List<&2, T.BMode>:
  match fuel:
    case 0n:
      ms
    case 1n+p:
      tcp.close(p, ps, tcp.tpl.raise(ps, ms, tcp.tpl.names(ps, ms, Nil{})))

# A return type's Pi raised to live where the body's head lambda for it uses
# its variable live (a lambda takes its Pi's mode): an erased Pi over an
# opaque type, `_∼ᵒ_ = flip _∼_`, whose y x the relation takes live.
# (a live Pi does NOT fall to erased when its lambda has no use, as a
# parameter does: the Pi is part of the def's type, and `∣_⟫-_` passes
# `const` where a live `B -> A` is wanted; tried 2026-10-20.  Lowering
# `step-≈-⟩`'s point would need its head lambdas lifted into the header first)
def tcp.ret.mode(m: T.BMode, used: Bool, none: Bool) -> T.BMode:
  match m used none:
    case T.BmErased{} True{} _:
      T.BmLive{}
    case m _ _:
      m

def tcp.ret.at(pm: T.BMode, +x: List<&2, U32>, +bb: T.Bt) -> T.BMode:
  tcp.ret.mode(pm, Bool.not(Nat.is_eq(tcp.uses(x, bb), 0n)), Nat.is_eq(tcp.uses.unk(x, bb), 0n))

# the modes of the return type's Pis the body's head lambdas bind, as set
# here: the symbol takes them after its header's, so a call marks those
# arguments as it does the header's
def tcp.ret.ms(b: T.Bt, ret: T.Bt) -> List<&2, T.BMode>:
  match b ret:
    case T.BtLam{m, +x, +bb} T.BtPi{pm, px, dep, a, rb}:
      tcp.ret.at(pm, x, bb) <> tcp.ret.ms(bb, rb)
    case T.BtExpr{e} ret:
      tcp.ret.ms(e, ret)
    case _ ret:
      Nil{}

def tcp.ret.live(b: T.Bt, ret: T.Bt) -> T.Bt:
  match b ret:
    case T.BtLam{m, +x, +bb} T.BtPi{pm, px, dep, a, rb}:
      T.BtPi{tcp.ret.at(pm, x, bb), px, dep, a, tcp.ret.live(bb, rb)}
    case T.BtExpr{e} ret:
      tcp.ret.live(e, ret)
    case _ ret:
      ret

# a def's parameters' modes as its body needs them, in header order (the
# empty list for any other item), then its return type's Pis its head lambdas bind
def tcp.decide(it: T.BItem, +datas: List<&2, List<&2, U32>>) -> List<&2, T.BMode>:
  match it:
    case T.BiDef{n, +ps, +ret, +body, doc}:
      List.append(&2, T.BMode, tcp.close(List.length(&2, T.BParam, ps), ps, tcp.params(ps, body, List.append(&2, List<&2, U32>, tcp.ty.params(ps), datas))), tcp.ret.ms(body, ret))
    case _:
      Nil{}

def tcp.is.data(k: T.Bt) -> Bool:
  match k:
    case T.BtVar{+d}:
      S.eq(d, S.b("Data"))
    case _:
      False{}

def tcp.datas.put(k: Bool, +n: List<&2, U32>, rest: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match k:
    case True{}:
      n <> rest
    case False{}:
      rest

# the names of the Data types an item list declares
def tcp.datas(its: List<&2, T.BItem>) -> List<&2, List<&2, U32>>:
  match its:
    case Nil{}:
      Nil{}
    case T.BiType{+n, ps, k, cs, doc} <> t:
      tcp.datas.put(tcp.is.data(k), n, tcp.datas(t))
    case i <> t:
      tcp.datas(t)

# Destructuring ----------------------------------------------------------------
#
# A record parameter used live only through projections of distinct fields
# (`partialSetoid` takes S's Carrier, _≈_ and isEquivalence; composing two
# Funcs takes f's to and cong) is matched once instead, each projection
# becoming its field's variable and any other (dead) mention the record
# rebuilt: then it is used once, live, where Copy made it a template (a
# record of functions cannot be +), and a template wants closed arguments,
# so its callers' lambdas (Setoids' `_∘_ = λ f g → …`) and, through
# `partialSetoid(~hom-setoid(~C, X, Y))`, every reasoning lemma's objects
# had to be templates too.  Only a body that is one expression is
# destructured (a match then starts it, in parameter order); a field used
# live twice keeps the template.

# a projection, by its name as a module prints it: the record's
# constructor (alias-qualified), the field's index and the field count
type TcpProj is Data:
  TcpProj{ctor: List<&2, U32>, i: Nat, k: Nat}

# the projections (by alias-qualified name) and the module's own alias
# with its dot (its own names are printed bare)
type TcpEnv is Data:
  TcpEnv{pj: Map<&2, TcpProj>, here: List<&2, U32>}

def tcp.pj.got(r: Map<&2, TcpProj> & TcpProj) -> TcpProj:
  (m, p) = r
  p

def tcp.pj.has(r: Map<&2, TcpProj> & Bool) -> Bool:
  (m, b) = r
  b

def tcp.pj.pick(hit: Bool, +f: List<&2, U32>, +pj: Map<&2, TcpProj>, +here: List<&2, U32>) -> TcpProj:
  match hit:
    case True{}:
      tcp.pj.got(Map.get(TcpProj, TcpProj{Nil{}, 0n, 0n}, pj, S.str(f)))
    case False{}:
      tcp.pj.got(Map.get(TcpProj, TcpProj{Nil{}, 0n, 0n}, pj, S.str(List.append(&2, U32, here, f))))

# the projection a callee is (k = 0 when none)
def tcp.pj.of(+e: TcpEnv, +f: List<&2, U32>) -> TcpProj:
  match e:
    case TcpEnv{+pj, +here}:
      tcp.pj.pick(tcp.pj.has(Map.has(&2, TcpProj, pj, S.str(f))), f, pj, here)

# the variable an argument spine ends in (Nil when it ends otherwise)
def tcp.last.var(a: T.Bt) -> List<&2, U32>:
  match a:
    case T.BtArgs{T.BtVar{x}, T.BtANil{}}:
      x
    case T.BtArgs{h, rest}:
      tcp.last.var(rest)
    case _:
      Nil{}

# the spine without its last argument
def tcp.init.args(a: T.Bt) -> T.Bt:
  match a:
    case T.BtArgs{h, T.BtANil{}}:
      T.BtANil{}
    case T.BtArgs{h, rest}:
      T.BtArgs{h, tcp.init.args(rest)}
    case a:
      a

# whether f(a) projects x: the field's projection, else k = 0
def tcp.proj.at(+e: TcpEnv, f: T.Bt, +a: T.Bt, +x: List<&2, U32>) -> TcpProj:
  match f:
    case T.BtVar{+fn}:
      Bool.pick(TcpProj, S.eq(tcp.last.var(a), x), tcp.pj.of(e, fn), TcpProj{Nil{}, 0n, 0n})
    case _:
      TcpProj{Nil{}, 0n, 0n}

# x's live uses: those that are not a projection's record, and the fields
# its live projections take (with the record's constructor and size)
type TcpPU is Data:
  TcpPU{other: Nat, fs: List<&2, Nat>, ctor: List<&2, U32>, k: Nat}

def tcp.pu0() -> TcpPU:
  TcpPU{0n, Nil{}, Nil{}, 0n}

def tcp.pu.ctor(+a: List<&2, U32>, +b: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(S.len(a), 0n), b, a)

# a projection's arguments counted without its record (x, the last, once)
def tcp.pu.less(u: TcpPU) -> TcpPU:
  match u:
    case TcpPU{o, fs, c, k}:
      TcpPU{Nat.sub(o, 1n), fs, c, k}

def tcp.pu.add(a: TcpPU, b: TcpPU) -> TcpPU:
  match a b:
    case TcpPU{o1, f1, +c1, k1} TcpPU{o2, f2, +c2, k2}:
      TcpPU{Nat.add(o1, o2), List.append(&2, Nat, f1, f2), tcp.pu.ctor(c1, c2), tcp.max(k1, k2)}

# whether t is a projection of x (the field's projection, else k = 0); the
# walks below take it as a parameter (Bend has no mutual recursion)
def tcp.proj.t(+e: TcpEnv, t: T.Bt, +x: List<&2, U32>) -> TcpProj:
  match t:
    case T.BtApp{f, +a}:
      tcp.proj.at(e, f, a, x)
    case _:
      TcpProj{Nil{}, 0n, 0n}

def tcp.pu(+x: List<&2, U32>, t: T.Bt, +e: TcpEnv, p: TcpProj) -> TcpPU:
  match t p:
    case T.BtApp{f, +a} TcpProj{c, i, 1n+k}:
      tcp.pu.add(TcpPU{0n, [i], c, 1n+k}, tcp.pu.less(tcp.pu(x, a, e, tcp.proj.t(e, a, x))))
    case T.BtApp{+f, +a} q:
      tcp.pu.add(tcp.pu(x, f, e, tcp.proj.t(e, f, x)), tcp.pu(x, a, e, tcp.proj.t(e, a, x)))
    case T.BtRw{r, p2, +b} q:
      tcp.pu(x, b, e, tcp.proj.t(e, b, x))
    case T.BtLet{y, +v, +b} q:
      tcp.pu.add(tcp.pu(x, v, e, tcp.proj.t(e, v, x)), tcp.pu(x, b, e, tcp.proj.t(e, b, x)))
    case T.BtVar{y} q:
      TcpPU{Bool.pick(Nat, S.eq(x, y), 1n, 0n), Nil{}, Nil{}, 0n}
    case T.BtTplArg{+a} q:
      tcp.pu(x, a, e, tcp.proj.t(e, a, x))
    case T.BtLam{m, +y, +b} q:
      Bool.pick(TcpPU, S.eq(x, y), tcp.pu0(), tcp.pu(x, b, e, tcp.proj.t(e, b, x)))
    case T.BtCon{c2, +a} q:
      tcp.pu(x, a, e, tcp.proj.t(e, a, x))
    case T.BtSucc{+a} q:
      tcp.pu(x, a, e, tcp.proj.t(e, a, x))
    case T.BtAnn{+a, ty} q:
      tcp.pu(x, a, e, tcp.proj.t(e, a, x))
    case T.BtMatch{+xs, +cs} q:
      tcp.pu.add(tcp.pu(x, xs, e, tcp.proj.t(e, xs, x)), tcp.pu(x, cs, e, tcp.proj.t(e, cs, x)))
    case T.BtCase{p2, +b, +rest} q:
      tcp.pu.add(tcp.pu(x, b, e, tcp.proj.t(e, b, x)), tcp.pu(x, rest, e, tcp.proj.t(e, rest, x)))
    case T.BtExpr{+b} q:
      tcp.pu(x, b, e, tcp.proj.t(e, b, x))
    case T.BtArgs{+a, +rest} q:
      tcp.pu.add(tcp.pu(x, a, e, tcp.proj.t(e, a, x)), tcp.pu(x, rest, e, tcp.proj.t(e, rest, x)))
    case _ q:
      tcp.pu0()

def tcp.nat.mem(+n: Nat, xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(Nat.is_eq(h, n), tcp.nat.mem(n, t))

def tcp.distinct(xs: List<&2, Nat>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +h <> +t:
      Bool.and(Bool.not(tcp.nat.mem(h, t)), tcp.distinct(t))

# whether the uses call for destructuring: two live projections at least,
# of distinct fields, and no other live use
def tcp.pu.ok(u: TcpPU) -> Bool:
  match u:
    case TcpPU{o, +fs, c, k}:
      Bool.and(Nat.is_eq(o, 0n), Bool.and(Bool.not(Nat.is_lt(List.length(&2, Nat, fs), 2n)), tcp.distinct(fs)))

def tcp.nth.name(ns: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case h <> t:
      Bool.pick(List<&2, U32>, Nat.is_eq(i, 0n), h, tcp.nth.name(t, Nat.sub(i, 1n)))

def tcp.vars(ns: List<&2, List<&2, U32>>) -> T.Bt:
  match ns:
    case Nil{}:
      T.BtANil{}
    case n <> t:
      T.BtArgs{T.BtVar{n}, tcp.vars(t)}

# x's field variables: x_f0, x_f1, ...
def tcp.fnames(k: Nat, +x: List<&2, U32>, +j: Nat) -> List<&2, List<&2, U32>>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      List.append(&2, U32, x, S.b("_f" ++ Nat.show(j))) <> tcp.fnames(p, x, 1n+j)

# t with x's projections its field variables, and x itself the record
# rebuilt from them (only dead mentions are left); p: whether t projects x
def tcp.pr(+x: List<&2, U32>, t: T.Bt, +e: TcpEnv, +ns: List<&2, List<&2, U32>>, +con: T.Bt, p: TcpProj) -> T.Bt:
  match t p:
    case T.BtApp{f, a} TcpProj{c, +i, 1n+k}:
      T.BtVar{tcp.nth.name(ns, i)}
    case T.BtApp{+f, +a} q:
      T.BtApp{tcp.pr(x, f, e, ns, con, tcp.proj.t(e, f, x)), tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x))}
    case T.BtRw{+r, +p2, +b} q:
      T.BtRw{tcp.pr(x, r, e, ns, con, tcp.proj.t(e, r, x)), tcp.pr(x, p2, e, ns, con, tcp.proj.t(e, p2, x)), tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x))}
    case T.BtLet{y, +v, +b} q:
      T.BtLet{y, tcp.pr(x, v, e, ns, con, tcp.proj.t(e, v, x)), tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x))}
    case T.BtVar{+y} q:
      Bool.pick(T.Bt, S.eq(x, y), con, T.BtVar{y})
    case T.BtTplArg{+a} q:
      T.BtTplArg{tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x))}
    case T.BtLam{m, y, +b} q:
      T.BtLam{m, y, tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x))}
    case T.BtPi{m, y, d, +a, +b} q:
      T.BtPi{m, y, d, tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x)), tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x))}
    case T.BtCon{c2, +a} q:
      T.BtCon{c2, tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x))}
    case T.BtTyApp{n, +a} q:
      T.BtTyApp{n, tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x))}
    case T.BtEq{+ty, +a, +b} q:
      T.BtEq{tcp.pr(x, ty, e, ns, con, tcp.proj.t(e, ty, x)), tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x)), tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x))}
    case T.BtSucc{+a} q:
      T.BtSucc{tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x))}
    case T.BtAnn{+a, +ty} q:
      T.BtAnn{tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x)), tcp.pr(x, ty, e, ns, con, tcp.proj.t(e, ty, x))}
    case T.BtDead{+a} q:
      T.BtDead{tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x))}
    case T.BtMatch{+xs, +cs} q:
      T.BtMatch{tcp.pr(x, xs, e, ns, con, tcp.proj.t(e, xs, x)), tcp.pr(x, cs, e, ns, con, tcp.proj.t(e, cs, x))}
    case T.BtCase{p2, +b, +rest} q:
      T.BtCase{p2, tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x)), tcp.pr(x, rest, e, ns, con, tcp.proj.t(e, rest, x))}
    case T.BtExpr{+b} q:
      T.BtExpr{tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x))}
    case T.BtArgs{+a, +rest} q:
      T.BtArgs{tcp.pr(x, a, e, ns, con, tcp.proj.t(e, a, x)), tcp.pr(x, rest, e, ns, con, tcp.proj.t(e, rest, x))}
    case t q:
      t

# the record's constructor as this module prints it
def tcp.ctor.here(+c: List<&2, U32>, +e: TcpEnv) -> List<&2, U32>:
  match e:
    case TcpEnv{pj, +here}:
      S.strip(c, here)

def tcp.wrap.of(u: TcpPU, +x: List<&2, U32>, +b: T.Bt, +e: TcpEnv) -> T.Bt:
  match u:
    case TcpPU{o, fs, +c, +k}:
      +ns = tcp.fnames(k, x, 0n)
      +con : T.Bt = T.BtCon{tcp.ctor.here(c, e), tcp.vars(ns)}
      T.BtMatch{T.BtArgs{T.BtVar{x}, T.BtANil{}}, T.BtCase{T.BtArgs{con, T.BtANil{}}, tcp.pr(x, b, e, ns, con, tcp.proj.t(e, b, x)), T.BtCEnd{}}}

def tcp.wrap.if(ok: Bool, +u: TcpPU, +x: List<&2, U32>, +b: T.Bt, +e: TcpEnv) -> T.Bt:
  match ok:
    case True{}:
      tcp.wrap.of(u, x, b, e)
    case False{}:
      b

# the parameters from the last: the later ones' matches go innermost
def tcp.destr.ps(ps: List<&2, T.BParam>, +b: T.Bt, +e: TcpEnv) -> T.Bt:
  match ps:
    case Nil{}:
      b
    case T.BParam{m, +x, ty} <> t:
      +inner = tcp.destr.ps(t, b, e)
      +u = tcp.pu(x, inner, e, tcp.proj.t(e, inner, x))
      tcp.wrap.if(tcp.pu.ok(u), u, x, inner, e)

# a def whose body is one expression, its record parameters destructured
def tcp.destr(it: T.BItem, +e: TcpEnv) -> T.BItem:
  match it:
    case T.BiDef{n, +ps, ret, T.BtExpr{b}, doc}:
      T.BiDef{n, ps, ret, tcp.destr.ps(ps, T.BtExpr{b}, e), doc}
    case it:
      it

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
    case T.BiDef{n, ps, ret, +body, doc}:
      tcp.kinds(T.BiDef{n, tcp.tpl.first(tcp.set.modes(ps, ms)), tcp.ret.live(body, ret), tcp.mark(body), doc})
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
