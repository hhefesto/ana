import Base
import ../Sys.bend as S
import ./Ast.bend as T

# Qfix: solving quantity arguments (2026-10-20).  With levels as quantities
# (the user's choice to specialise Product, Bifunctor and Yoneda to Data
# homs), the cata writes each quantity argument from Agda's level, but a
# level does not say whether a type's values may be copied: a function type
# is Type at any level, so `Setoids c ℓ` cannot have homs of kind
# Kind(qc <&> qℓ).  This pass replaces every quantity argument of a call
# or a type application by the one its other arguments determine:
#
# - a parameter `-A: Kind(q)` (or a family `-B: A -> Kind(q)`) takes q from
#   the kind of the type passed: &1 for a function type, &2 for Data, the
#   hom quantity for `Arr(C)(x, y)`;
# - a parameter typed by a type application with quantity arguments
#   (`C: Category<o, l, e>`) takes them from the argument's own type;
# - any other quantity argument is &1 (Type).
#
# A def whose body is a record's value (Setoids) gets its return type's
# quantities from the kinds of its fields.  Quantity terms are names: &1,
# &2, a quantity variable, or a minimum written "(a <&> b)".  Every def is
# prefixed `tqf.`.

# A signature: a def's header and return type, or a type's parameters, its
# kind and constructors.
type TqSig is Data:
  TqDef{ps: List<&2, T.BParam>, ret: T.Bt, body: T.Bt}
  TqType{ps: List<&2, T.BParam>, kind: T.Bt, cs: List<&2, T.BCtor>}
  TqNone{}

# the signatures (by the name other modules print) and the module's own
# alias with its dot (its own names are printed bare)
type TqEnv is Data:
  TqEnv{sig: Map<&2, TqSig>, here: List<&2, U32>}

def tqf.got(r: Map<&2, TqSig> & TqSig) -> TqSig:
  (m, s) = r
  s

def tqf.has(r: Map<&2, TqSig> & Bool) -> Bool:
  (m, b) = r
  b

def tqf.pick(hit: Bool, +n: List<&2, U32>, +sig: Map<&2, TqSig>, +here: List<&2, U32>) -> TqSig:
  match hit:
    case True{}:
      tqf.got(Map.get(TqSig, TqNone{}, sig, S.str(n)))
    case False{}:
      tqf.got(Map.get(TqSig, TqNone{}, sig, S.str(List.append(&2, U32, here, n))))

def tqf.sig(+e: TqEnv, +n: List<&2, U32>) -> TqSig:
  match e:
    case TqEnv{+sig, +here}:
      tqf.pick(tqf.has(Map.has(&2, TqSig, sig, S.str(n))), n, sig, here)

# a name's signature unless the context binds it (m: its type there), for a
# field or a parameter shadows a global of the same name
def tqf.sig.free(m: Maybe<&2, T.Bt>, +e: TqEnv, +n: List<&2, U32>) -> TqSig:
  match m:
    case Some{t}:
      TqNone{}
    case None{}:
      tqf.sig(e, n)

# Quantity terms ---------------------------------------------------------------

def tqf.q1() -> T.Bt:
  T.BtVar{S.b("&1")}

def tqf.q2() -> T.Bt:
  T.BtVar{S.b("&2")}

def tqf.is(+t: T.Bt, +s: String) -> Bool:
  match t:
    case T.BtVar{n}:
      S.eq(n, S.b(s))
    case _:
      False{}

def tqf.name(t: T.Bt) -> List<&2, U32>:
  match t:
    case T.BtVar{n}:
      n
    case _:
      S.b("&1")

# the smaller of two quantities (&2 is the unit, &1 absorbs)
def tqf.min(+a: T.Bt, +b: T.Bt) -> T.Bt:
  Bool.pick(T.Bt, tqf.is(a, "&2"), b, Bool.pick(T.Bt, tqf.is(b, "&2"), a, Bool.pick(T.Bt, Bool.or(tqf.is(a, "&1"), tqf.is(b, "&1")), tqf.q1(), Bool.pick(T.Bt, S.eq(tqf.name(a), tqf.name(b)), a, T.BtVar{List.append(&2, U32, 40 <> tqf.name(a), List.append(&2, U32, S.b(" <&> "), List.append(&2, U32, tqf.name(b), [41])))}))))

# the quantity a kind term stands for: Kind(q) is q, Data &2, anything else
# (Type, a Pi, an application) &1; past a family's Pis
def tqf.endq(t: T.Bt) -> T.Bt:
  match t:
    case T.BtPi{m, y, d, a, b}:
      tqf.endq(b)
    case T.BtApp{T.BtVar{+k}, T.BtArgs{+q, T.BtANil{}}}:
      Bool.pick(T.Bt, S.eq(k, S.b("Kind")), q, tqf.q1())
    case T.BtVar{+d}:
      Bool.pick(T.Bt, S.eq(d, S.b("Data")), tqf.q2(), tqf.q1())
    case T.BtDead{a}:
      tqf.endq(a)
    case _:
      tqf.q1()

def tqf.is.quant(p: T.BParam) -> Bool:
  match p:
    case T.BParam{m, x, ty}:
      tqf.is(ty, "Quant")

# Substitution of a signature's parameters ------------------------------------

# a quantity variable x inside a minimum's name, as the name of v
def tqf.qtext(+n: List<&2, U32>, +x: List<&2, U32>, +v: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.head.is(n, 40), S.replace(S.replace(n, 40 <> List.append(&2, U32, x, [32]), 40 <> List.append(&2, U32, v, [32])), 32 <> List.append(&2, U32, x, [41]), 32 <> List.append(&2, U32, v, [41])), n)

def tqf.np.put(skip: Bool, +c: U32, r: List<&2, U32>) -> List<&2, U32>:
  match skip:
    case True{}:
      r
    case False{}:
      c <> r

def tqf.noparen(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      tqf.np.put(Bool.or(U32.is_eq(c, 40), U32.is_eq(c, 41)), c, tqf.noparen(t))

def tqf.atoms(t: T.Bt) -> List<&2, List<&2, U32>>:
  S.split.str(tqf.noparen(tqf.name(t)), S.b(" <&> "))

def tqf.mem(+x: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +y <> t:
      Bool.or(S.eq(x, y), tqf.mem(x, t))

def tqf.dd.put(dup: Bool, +x: List<&2, U32>, r: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match dup:
    case True{}:
      r
    case False{}:
      x <> r

def tqf.no2(xs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      tqf.dd.put(S.eq(x, S.b("&2")), x, tqf.no2(t))

def tqf.dedup(xs: List<&2, List<&2, U32>>, +seen: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      Nil{}
    case +x <> t:
      tqf.dd.put(tqf.mem(x, seen), x, tqf.dedup(t, x <> seen))

def tqf.min.of(xs: List<&2, List<&2, U32>>) -> T.Bt:
  match xs:
    case Nil{}:
      tqf.q2()
    case x <> Nil{}:
      T.BtVar{x}
    case x <> t:
      tqf.min(T.BtVar{x}, tqf.min.of(t))

# a minimum name simplified once a substitution put a literal or a repeat
# in it: &2 is the unit, &1 absorbs, a repeat is one (`Lift<&2, a, Unit>`
# is of kind a); left as it is when nothing simplifies
def tqf.qsimp(+n: List<&2, U32>) -> T.Bt:
  +xs = tqf.atoms(T.BtVar{n})
  +ys = tqf.dedup(tqf.no2(xs), Nil{})
  Bool.pick(T.Bt, tqf.mem(S.b("&1"), xs), tqf.q1(), Bool.pick(T.Bt, Nat.is_eq(List.length(&2, List<&2, U32>, xs), List.length(&2, List<&2, U32>, ys)), T.BtVar{n}, tqf.min.of(ys)))

def tqf.qsimp.if(paren: Bool, +n: List<&2, U32>) -> T.Bt:
  match paren:
    case True{}:
      tqf.qsimp(n)
    case False{}:
      T.BtVar{n}

# t with each parameter of ps named by the matching argument (quantities
# inside minimum names too)
def tqf.sub.one(t: T.Bt, +x: List<&2, U32>, +v: T.Bt) -> T.Bt:
  match t:
    case T.BtVar{+n}:
      +n2 = tqf.qtext(n, x, tqf.name(v))
      Bool.pick(T.Bt, S.eq(n, x), v, tqf.qsimp.if(Bool.and(S.head.is(n2, 40), Bool.not(S.eq(n2, n))), n2))
    case T.BtApp{f, a}:
      T.BtApp{tqf.sub.one(f, x, v), tqf.sub.one(a, x, v)}
    case T.BtArgs{a, rest}:
      T.BtArgs{tqf.sub.one(a, x, v), tqf.sub.one(rest, x, v)}
    case T.BtTplArg{a}:
      T.BtTplArg{tqf.sub.one(a, x, v)}
    case T.BtLam{m, +y, +b}:
      T.BtLam{m, y, Bool.pick(T.Bt, S.eq(x, y), b, tqf.sub.one(b, x, v))}
    case T.BtPi{m, +y, d, a, +b}:
      T.BtPi{m, y, d, tqf.sub.one(a, x, v), Bool.pick(T.Bt, S.eq(x, y), b, tqf.sub.one(b, x, v))}
    case T.BtCon{c, a}:
      T.BtCon{c, tqf.sub.one(a, x, v)}
    case T.BtTyApp{c, a}:
      T.BtTyApp{c, tqf.sub.one(a, x, v)}
    case T.BtEq{ty, a, b}:
      T.BtEq{tqf.sub.one(ty, x, v), tqf.sub.one(a, x, v), tqf.sub.one(b, x, v)}
    case T.BtSucc{a}:
      T.BtSucc{tqf.sub.one(a, x, v)}
    case T.BtAnn{a, ty}:
      T.BtAnn{tqf.sub.one(a, x, v), tqf.sub.one(ty, x, v)}
    case T.BtDead{a}:
      T.BtDead{tqf.sub.one(a, x, v)}
    case t:
      t

def tqf.undead(t: T.Bt) -> T.Bt:
  match t:
    case T.BtDead{a}:
      tqf.undead(a)
    case T.BtTplArg{a}:
      a
    case t:
      t

# t with the parameters ps replaced by the arguments of the spine a
# (all at once: each parameter given an argument is first renamed to a
# placeholder, so `Sigma_<b, c, …>`'s kind `(a <&> b)` is `(b <&> c)`, not
# the `(c <&> c)` of a := b then b := c; 2026-10-21)
def tqf.ph(+i: Nat) -> List<&2, U32>:
  List.append(&2, U32, S.b("%q"), S.b(Nat.show(i) ++ "%"))

def tqf.inst.ren(ps: List<&2, T.BParam>, +a: T.Bt, +i: Nat, t: T.Bt) -> T.Bt:
  match ps a:
    case T.BParam{m, +x, ty} <> pt T.BtArgs{v, rest}:
      tqf.inst.ren(pt, rest, 1n+i, tqf.sub.one(t, x, T.BtVar{tqf.ph(i)}))
    case _ _:
      t

def tqf.inst.put(a: T.Bt, +i: Nat, t: T.Bt) -> T.Bt:
  match a:
    case T.BtArgs{v, rest}:
      tqf.inst.put(rest, 1n+i, tqf.sub.one(t, tqf.ph(i), tqf.undead(v)))
    case _:
      t

def tqf.inst(t: T.Bt, ps: List<&2, T.BParam>, +a: T.Bt) -> T.Bt:
  tqf.inst.put(a, 0n, tqf.inst.ren(ps, a, 0n, t))

def tqf.ps.inst(ps: List<&2, T.BParam>, +x: List<&2, U32>, +v: T.Bt) -> List<&2, T.BParam>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, y, ty} <> t:
      T.BParam{m, y, tqf.sub.one(ty, x, v)} <> tqf.ps.inst(t, x, v)

# Inference --------------------------------------------------------------------
#
# A context is the parameters in scope, with their types (a Pi's binder is
# added under it; a lambda's or a pattern's type is not known, so it is not).

def tqf.ctx.ty(ctx: List<&2, T.BParam>, +x: List<&2, U32>) -> Maybe<&2, T.Bt>:
  match ctx:
    case Nil{}:
      None{}
    case T.BParam{m, +y, ty} <> t:
      Bool.pick(Maybe<&2, T.Bt>, S.eq(x, y), Some{ty}, tqf.ctx.ty(t, x))

def tqf.spine.len(a: T.Bt) -> Nat:
  match a:
    case T.BtArgs{h, t}:
      1n+tqf.spine.len(t)
    case _:
      0n

def tqf.spine.drop(n: Nat, a: T.Bt) -> T.Bt:
  match n a:
    case 1n+p T.BtArgs{h, t}:
      tqf.spine.drop(p, t)
    case _ a:
      a

# a type-valued definition applied (its whole header), as its body: the
# kind of `A × B` is Σ's, not the Type its sort is written as
def tqf.tyval(t: T.Bt) -> Bool:
  match t:
    case T.BtPi{m, y, d, a, b}:
      tqf.tyval(b)
    case T.BtType{}:
      True{}
    case T.BtApp{T.BtVar{+k}, a}:
      S.eq(k, S.b("Kind"))
    case _:
      False{}

def tqf.unf(s: TqSig, +a: T.Bt) -> Maybe<&2, T.Bt>:
  match s:
    case TqDef{+ps, +ret, T.BtExpr{b}}:
      Bool.pick(Maybe<&2, T.Bt>, Bool.and(tqf.tyval(ret), Nat.is_eq(tqf.spine.len(a), List.length(&2, T.BParam, ps))), Some{tqf.inst(b, ps, a)}, None{})
    case _:
      None{}

def tqf.unf.get(m: Maybe<&2, T.Bt>) -> T.Bt:
  match m:
    case Some{t}:
      t
    case None{}:
      T.BtType{}

def tqf.is.some(m: Maybe<&2, T.Bt>) -> Bool:
  match m:
    case Some{t}:
      True{}
    case None{}:
      False{}

# a type in weak head form: the type-valued definitions at its head opened
# (`lt : Rel(a, A, l)` applies as `A -> A -> Kind(l)`, as Bend reduces it)
def tqf.whnf(fuel: Nat, t: T.Bt, +e: TqEnv) -> T.Bt:
  match fuel t:
    case 1n+f T.BtApp{T.BtVar{+fn}, +args}:
      +u = tqf.unf(tqf.sig(e, fn), args)
      Bool.pick(T.Bt, tqf.is.some(u), tqf.whnf(f, tqf.unf.get(u), e), T.BtApp{T.BtVar{fn}, args})
    case 1n+f T.BtDead{a}:
      tqf.whnf(f, a, e)
    case f t:
      t

def tqf.pi.inst(t: T.Bt, +v: T.Bt) -> Maybe<&2, T.Bt>:
  match t:
    case T.BtPi{pm, +y, d, dom, b}:
      Some{tqf.sub.one(b, y, tqf.undead(v))}
    case _:
      None{}

# a function type applied to the arguments of a spine: its Pis stripped,
# each binder replaced by its argument (its head opened first)
def tqf.apply.go(a: T.Bt, m: Maybe<&2, T.Bt>, +e: TqEnv) -> Maybe<&2, T.Bt>:
  match a m:
    case T.BtArgs{v, rest} Some{t}:
      tqf.apply.go(rest, tqf.pi.inst(tqf.whnf(16n, t, e), v), e)
    case T.BtANil{} Some{t}:
      Some{t}
    case _ _:
      None{}

def tqf.apply.pis(m: Maybe<&2, T.Bt>, a: T.Bt, +e: TqEnv) -> Maybe<&2, T.Bt>:
  tqf.apply.go(a, m, e)

def tqf.ty.call(s: TqSig, +args: T.Bt, +e: TqEnv) -> Maybe<&2, T.Bt>:
  match s:
    case TqDef{+ps, ret, b}:
      Bool.pick(Maybe<&2, T.Bt>, Nat.is_lt(tqf.spine.len(args), List.length(&2, T.BParam, ps)), None{}, tqf.apply.pis(Some{tqf.inst(ret, ps, args)}, tqf.spine.drop(List.length(&2, T.BParam, ps), args), e))
    case _:
      None{}

def tqf.ty.var(m: Maybe<&2, T.Bt>, s: TqSig) -> Maybe<&2, T.Bt>:
  match m s:
    case Some{t} s:
      Some{t}
    case None{} TqDef{Nil{}, ret, b}:
      Some{ret}
    case _ _:
      None{}

# an applied name's result type: a bound function's by its type in the
# context (a field `Arr: Obj -> Obj -> Kind(l)`), a global's by its signature
def tqf.ty.app(m: Maybe<&2, T.Bt>, s: TqSig, +args: T.Bt, +e: TqEnv) -> Maybe<&2, T.Bt>:
  match m:
    case Some{t}:
      tqf.apply.pis(Some{t}, args, e)
    case None{}:
      tqf.ty.call(s, args, e)

# the type of a term, as far as the context and the signatures say
def tqf.ty(fuel: Nat, t: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> Maybe<&2, T.Bt>:
  match fuel t:
    case f T.BtVar{+x}:
      tqf.ty.var(tqf.ctx.ty(ctx, x), tqf.sig(e, x))
    case 1n+f T.BtApp{T.BtVar{+fn}, +args}:
      tqf.ty.app(tqf.ctx.ty(ctx, fn), tqf.sig(e, fn), args, e)
    case 1n+f T.BtApp{g, args}:
      tqf.apply.pis(tqf.ty(f, g, ctx, e), args, e)
    case 1n+f T.BtDead{a}:
      tqf.ty(f, a, ctx, e)
    case 1n+f T.BtTplArg{a}:
      tqf.ty(f, a, ctx, e)
    case _ _:
      None{}

def tqf.endq.m(m: Maybe<&2, T.Bt>) -> T.Bt:
  match m:
    case Some{t}:
      tqf.endq(t)
    case None{}:
      tqf.q1()

def tqf.base(+x: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(S.eq(x, S.b("Nat")), S.eq(x, S.b("Bool"))), Bool.or(S.eq(x, S.b("Unit")), S.eq(x, S.b("U32"))))

def tqf.kind.ty(s: TqSig, +args: T.Bt) -> T.Bt:
  match s:
    case TqType{ps, k, cs}:
      tqf.endq(tqf.inst(k, ps, args))
    case _:
      tqf.q1()

# a type's end quantity with the type-valued definitions it ends in opened
# (2026-10-21: a projection's parameter `eq: Rel(a, A, l)` is a family of
# kind l, as Rel's body `A -> A -> Kind(l)` says; read off Rel's own Type
# sort it was &1, and IsEquivalence.refl took `IsEquivalence<a, &1, A, eq>`)
def tqf.endq.unf(fuel: Nat, t: T.Bt, +e: TqEnv) -> T.Bt:
  match fuel t:
    case 1n+f T.BtPi{m, y, d, a, b}:
      tqf.endq.unf(f, b, e)
    case 1n+f T.BtApp{T.BtVar{+fn}, +args}:
      +u = tqf.unf(tqf.sig(e, fn), args)
      Bool.pick(T.Bt, tqf.is.some(u), tqf.endq.unf(f, tqf.unf.get(u), e), tqf.endq(T.BtApp{T.BtVar{fn}, args}))
    case 1n+f T.BtDead{a}:
      tqf.endq.unf(f, a, e)
    case f t:
      tqf.endq(t)

def tqf.endq.mu(m: Maybe<&2, T.Bt>, +e: TqEnv) -> T.Bt:
  match m:
    case Some{t}:
      tqf.endq.unf(16n, t, e)
    case None{}:
      tqf.q1()

# the quantity of a type's values: &1 for a function type, &2 for Data, the
# kind its declaration or its signature gives otherwise
def tqf.kind(fuel: Nat, t: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match fuel t:
    case f T.BtVar{+x}:
      Bool.pick(T.Bt, tqf.base(x), tqf.q2(), tqf.endq.mu(tqf.ctx.ty(ctx, x), e))
    case f T.BtTyApp{+n, +args}:
      tqf.kind.ty(tqf.sig(e, n), args)
    case f T.BtApp{T.BtVar{+fn}, +args}:
      tqf.endq.mu(tqf.ty(16n, T.BtApp{T.BtVar{fn}, args}, ctx, e), e)
    case f T.BtApp{g, args}:
      tqf.endq.mu(tqf.ty(16n, T.BtApp{g, args}, ctx, e), e)
    case f T.BtPi{m, y, d, a, b}:
      tqf.q1()
    case f T.BtEq{ty, a, b}:
      tqf.q2()
    case 1n+f T.BtDead{a}:
      tqf.kind(f, a, ctx, e)
    case 1n+f T.BtTplArg{a}:
      tqf.kind(f, a, ctx, e)
    case _ _:
      tqf.q1()

# a type family's quantity: its body's, past its lambdas; a named family by
# its type's end
def tqf.kind.fam(fuel: Nat, t: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match fuel t:
    case 1n+f T.BtLam{m, y, b}:
      tqf.kind.fam(f, b, ctx, e)
    case f T.BtVar{+x}:
      Bool.pick(T.Bt, tqf.base(x), tqf.q2(), tqf.endq.mu(tqf.ty.var(tqf.ctx.ty(ctx, x), tqf.sig(e, x)), e))
    case 1n+f T.BtDead{a}:
      tqf.kind.fam(f, a, ctx, e)
    case 1n+f T.BtTplArg{a}:
      tqf.kind.fam(f, a, ctx, e)
    case f t:
      tqf.kind(16n, t, ctx, e)

# Solving ----------------------------------------------------------------------

type TqBind is Data:
  TqBind{q: List<&2, U32>, v: T.Bt}

def tqf.find(bs: List<&2, TqBind>, +q: List<&2, U32>) -> Maybe<&2, T.Bt>:
  match bs:
    case Nil{}:
      None{}
    case TqBind{+x, +v} <> t:
      Bool.pick(Maybe<&2, T.Bt>, S.eq(x, q), Some{v}, tqf.find(t, q))

# a quantity variable q of the callee given v (the first answer stays)
def tqf.put.of(m: Maybe<&2, T.Bt>, +q: List<&2, U32>, +v: T.Bt, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match m:
    case Some{w}:
      bs
    case None{}:
      TqBind{q, v} <> bs

def tqf.put(+q: List<&2, U32>, +v: T.Bt, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  tqf.put.of(tqf.find(bs, q), q, v, bs)

# a parameter type's quantity variables matched against an argument's type
def tqf.match.args(pa: T.Bt, aa: T.Bt, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match pa aa:
    case T.BtArgs{T.BtVar{+q}, pr} T.BtArgs{+v, ar}:
      tqf.match.args(pr, ar, tqf.put(q, tqf.undead(v), bs))
    case T.BtArgs{T.BtDead{T.BtVar{+q}}, pr} T.BtArgs{+v, ar}:
      tqf.match.args(pr, ar, tqf.put(q, tqf.undead(v), bs))
    case T.BtArgs{p, pr} T.BtArgs{v, ar}:
      tqf.match.args(pr, ar, bs)
    case _ _:
      bs

def tqf.match.ty(+pn: List<&2, U32>, pa: T.Bt, m: Maybe<&2, T.Bt>, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match m:
    case Some{T.BtTyApp{+an, aa}}:
      Bool.pick(List<&2, TqBind>, S.eq(pn, an), tqf.match.args(pa, aa, bs), bs)
    case _:
      bs

def tqf.bind.fam(q: T.Bt, +a: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match q:
    case T.BtVar{+n}:
      Bool.pick(List<&2, TqBind>, S.head.is(n, 38), bs, tqf.put(n, tqf.kind.fam(16n, a, ctx, e), bs))
    case _:
      bs

# what one parameter's type says of the callee's quantities, given its argument
# (a parameter typed by a type-valued definition, `eq: Rel(a, A, l)`, by
# its opened body)
def tqf.bind(fuel: Nat, pty: T.Bt, +a: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match fuel pty:
    case f T.BtApp{T.BtVar{+k}, T.BtArgs{T.BtVar{+q}, T.BtANil{}}}:
      Bool.pick(List<&2, TqBind>, S.eq(k, S.b("Kind")), tqf.put(q, tqf.kind(16n, a, ctx, e), bs), bs)
    case f T.BtPi{m, y, d, dom, b}:
      tqf.bind.fam(tqf.endq(b), a, ctx, e, bs)
    case f T.BtTyApp{+pn, pa}:
      tqf.match.ty(pn, pa, tqf.ty(16n, a, ctx, e), bs)
    case 1n+f T.BtApp{T.BtVar{+fn}, +pargs}:
      +u = tqf.unf(tqf.sig(e, fn), pargs)
      Bool.pick(List<&2, TqBind>, tqf.is.some(u), tqf.bind(f, tqf.unf.get(u), a, ctx, e, bs), bs)
    case _ _:
      bs


def tqf.solve(ps: List<&2, T.BParam>, a: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match ps a:
    case T.BParam{m, x, ty} <> pt T.BtArgs{+v, rest}:
      tqf.solve(pt, rest, ctx, e, tqf.bind(8n, ty, v, ctx, e, bs))
    case _ _:
      bs

def tqf.or1(m: Maybe<&2, T.Bt>) -> T.Bt:
  match m:
    case Some{v}:
      v
    case None{}:
      tqf.q1()

# an unsolved quantity keeps the cata's, from Agda's level: a record type's own
# quantities (RawRelation<c, l₁, l₂>) are governed by its fields, not by
# any argument
# (a solution keeps the argument's wrapper: a template quantity stays ~q,
# for templates lead a call)
def tqf.rewrap(v: T.Bt, q: T.Bt) -> T.Bt:
  match v:
    case T.BtTplArg{a}:
      T.BtTplArg{q}
    case _:
      T.BtDead{q}

def tqf.or.keep(m: Maybe<&2, T.Bt>, +v: T.Bt) -> T.Bt:
  match m:
    case Some{q}:
      tqf.rewrap(v, q)
    case None{}:
      v

# the arguments with each quantity one as the solutions say (the cata's where unsolved)
def tqf.reargs(ps: List<&2, T.BParam>, a: T.Bt, +bs: List<&2, TqBind>) -> T.Bt:
  match ps a:
    case T.BParam{m, +x, T.BtVar{+k}} <> pt T.BtArgs{+v, rest}:
      T.BtArgs{Bool.pick(T.Bt, S.eq(k, S.b("Quant")), tqf.or.keep(tqf.find(bs, x), v), v), tqf.reargs(pt, rest, bs)}
    case p <> pt T.BtArgs{v, rest}:
      T.BtArgs{v, tqf.reargs(pt, rest, bs)}
    case _ a:
      a

def tqf.has.quant(ps: List<&2, T.BParam>) -> Bool:
  match ps:
    case Nil{}:
      False{}
    case p <> t:
      Bool.or(tqf.is.quant(p), tqf.has.quant(t))

def tqf.fix.call(s: TqSig, +a: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match s:
    case TqDef{+ps, ret, b}:
      Bool.pick(T.Bt, tqf.has.quant(ps), tqf.reargs(ps, a, tqf.solve(ps, a, ctx, e, Nil{})), a)
    case TqType{+ps, k, cs}:
      Bool.pick(T.Bt, tqf.has.quant(ps), tqf.reargs(ps, a, tqf.solve(ps, a, ctx, e, Nil{})), a)
    case TqNone{}:
      a

# a curried call `ex(a, b, A)(P)`: its quantities solved over the header
# and then its return type's Pis (b is P's: `A -> Kind(b)`; 2026-10-21)
def tqf.pis.ps(t: T.Bt) -> List<&2, T.BParam>:
  match t:
    case T.BtPi{m, y, d, dom, b}:
      T.BParam{m, y, dom} <> tqf.pis.ps(b)
    case _:
      Nil{}

def tqf.spine.app(a: T.Bt, +b: T.Bt) -> T.Bt:
  match a:
    case T.BtArgs{h, t}:
      T.BtArgs{h, tqf.spine.app(t, b)}
    case _:
      b

def tqf.fix.call2(s: TqSig, +a: T.Bt, +a2: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match s:
    case TqDef{+ps, +ret, b}:
      Bool.pick(T.Bt, tqf.has.quant(ps), tqf.reargs(ps, a, tqf.solve(List.append(&2, T.BParam, ps, tqf.pis.ps(ret)), tqf.spine.app(a, a2), ctx, e, Nil{})), a)
    case _:
      a

# The pass --------------------------------------------------------------------

# a sort passed as an argument is Type: `if b then A else ¬ A` at
# Kind(a) failed on ¬ A (a function type is no Kind(a)), and the gate's
# &1 repair then specialised Reflects' `of` and `invert` for every caller
# (2026-10-21); Data stays
def tqf.widen(t: T.Bt) -> T.Bt:
  match t:
    case T.BtApp{T.BtVar{+k}, T.BtArgs{+q, T.BtANil{}}}:
      Bool.pick(T.Bt, Bool.and(S.eq(k, S.b("Kind")), Bool.not(tqf.is(q, "&2"))), T.BtType{}, T.BtApp{T.BtVar{k}, T.BtArgs{q, T.BtANil{}}})
    case T.BtDead{a}:
      T.BtDead{tqf.widen(a)}
    case t:
      t

# a term with every call's and type application's quantity arguments solved
# (inner ones first, so an argument's type is already right)
def tqf.fix(t: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match t:
    case T.BtApp{T.BtVar{+fn}, a}:
      T.BtApp{T.BtVar{fn}, tqf.fix.call(tqf.sig.free(tqf.ctx.ty(ctx, fn), e, fn), tqf.fix(a, ctx, e), ctx, e)}
    case T.BtApp{T.BtApp{T.BtVar{+fn}, a}, a2}:
      +a2f = tqf.fix(a2, ctx, e)
      T.BtApp{T.BtApp{T.BtVar{fn}, tqf.fix.call2(tqf.sig.free(tqf.ctx.ty(ctx, fn), e, fn), tqf.fix(a, ctx, e), a2f, ctx, e)}, a2f}
    case T.BtApp{f, a}:
      T.BtApp{tqf.fix(f, ctx, e), tqf.fix(a, ctx, e)}
    case T.BtTyApp{+n, a}:
      T.BtTyApp{n, tqf.fix.call(tqf.sig(e, n), tqf.fix(a, ctx, e), ctx, e)}
    case T.BtArgs{a, rest}:
      T.BtArgs{tqf.widen(tqf.fix(a, ctx, e)), tqf.fix(rest, ctx, e)}
    case T.BtTplArg{a}:
      T.BtTplArg{tqf.fix(a, ctx, e)}
    case T.BtLam{+m, +y, b}:
      T.BtLam{m, y, tqf.fix(b, T.BParam{m, y, T.BtType{}} <> ctx, e)}
    case T.BtPi{+m, +y, d, +a, b}:
      +a2 = tqf.fix(a, ctx, e)
      T.BtPi{m, y, d, a2, tqf.fix(b, T.BParam{m, y, a2} <> ctx, e)}
    case T.BtCon{c, a}:
      T.BtCon{c, tqf.fix(a, ctx, e)}
    case T.BtEq{ty, a, b}:
      T.BtEq{tqf.fix(ty, ctx, e), tqf.fix(a, ctx, e), tqf.fix(b, ctx, e)}
    case T.BtSucc{a}:
      T.BtSucc{tqf.fix(a, ctx, e)}
    case T.BtAnn{a, ty}:
      T.BtAnn{tqf.fix(a, ctx, e), tqf.fix(ty, ctx, e)}
    case T.BtDead{a}:
      T.BtDead{tqf.fix(a, ctx, e)}
    case T.BtMatch{xs, cs}:
      T.BtMatch{tqf.fix(xs, ctx, e), tqf.fix(cs, ctx, e)}
    case T.BtCase{p, b, rest}:
      T.BtCase{p, tqf.fix(b, ctx, e), tqf.fix(rest, ctx, e)}
    case T.BtExpr{b}:
      T.BtExpr{tqf.fix(b, ctx, e)}
    case T.BtRw{r, p, b}:
      T.BtRw{tqf.fix(r, ctx, e), tqf.fix(p, ctx, e), tqf.fix(b, ctx, e)}
    case T.BtLet{y, v, b}:
      T.BtLet{y, tqf.fix(v, ctx, e), tqf.fix(b, ctx, e)}
    case t:
      t

# a definition's body: its leading lambdas typed by its return type's Pis
# (`Sigma_syntax(a, b) -> @-A:Kind(a) -> @-x:(A -> Kind(b)) -> …` with body
# `eta1 => eta2 => Sigma_<…, eta1, eta2>` solves Sigma_<a, b, …>; untyped,
# the lambdas' kinds were &1, and so every `_×_`; 2026-10-21)
def tqf.fix.lams(b: T.Bt, ret: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match b ret:
    case T.BtLam{+m, +y, b2} T.BtPi{pm, +py, d, +dom, rb}:
      T.BtLam{m, y, tqf.fix.lams(b2, tqf.sub.one(rb, py, T.BtVar{y}), T.BParam{m, y, dom} <> ctx, e)}
    case b ret:
      tqf.fix(b, ctx, e)

def tqf.fix.body(body: T.Bt, +ret: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match body:
    case T.BtExpr{b}:
      T.BtExpr{tqf.fix.lams(b, ret, ctx, e)}
    case body:
      tqf.fix(body, ctx, e)

# a header's parameter types solved, each in the scope of those before it
def tqf.fix.ps(ps: List<&2, T.BParam>, +ctx: List<&2, T.BParam>, +e: TqEnv) -> List<&2, T.BParam>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{+m, +x, ty} <> t:
      +ty2 = tqf.fix(ty, ctx, e)
      T.BParam{m, x, ty2} <> tqf.fix.ps(t, T.BParam{m, x, ty2} <> ctx, e)

def tqf.ctx.of(ps: List<&2, T.BParam>, acc: List<&2, T.BParam>) -> List<&2, T.BParam>:
  match ps:
    case Nil{}:
      acc
    case p <> t:
      tqf.ctx.of(t, p <> acc)

# A record value's own quantities: for each quantity parameter q of its
# type, the kind of the field whose type ends in Kind(q) (`Arr: Obj -> Obj
# -> Kind(l)` holds Func for Setoids: l is &1).
def tqf.field.q(fs: List<&2, T.BField>, vs: T.Bt, +q: List<&2, U32>, +ctx: List<&2, T.BParam>, +e: TqEnv) -> Maybe<&2, T.Bt>:
  match fs vs:
    case T.BField{x, ty} <> ft T.BtArgs{+v, vr}:
      Bool.pick(Maybe<&2, T.Bt>, tqf.is(tqf.endq(ty), S.str(q)), Some{tqf.kind.fam(16n, v, ctx, e)}, tqf.field.q(ft, vr, q, ctx, e))
    case _ _:
      None{}

def tqf.put.m(+q: List<&2, U32>, m: Maybe<&2, T.Bt>, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match m:
    case Some{v}:
      tqf.put(q, v, bs)
    case None{}:
      bs

def tqf.rec.qs(ps: List<&2, T.BParam>, +fs: List<&2, T.BField>, +vs: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv, +bs: List<&2, TqBind>) -> List<&2, TqBind>:
  match ps:
    case Nil{}:
      bs
    case T.BParam{m, +x, T.BtVar{+k}} <> t:
      tqf.rec.qs(t, fs, vs, ctx, e, Bool.pick(List<&2, TqBind>, S.eq(k, S.b("Quant")), tqf.put.m(x, tqf.field.q(fs, vs, x, ctx, e), bs), bs))
    case p <> t:
      tqf.rec.qs(t, fs, vs, ctx, e, bs)

def tqf.rec.arg(m: Maybe<&2, T.Bt>, v: T.Bt) -> T.Bt:
  match m:
    case Some{q}:
      T.BtDead{q}
    case None{}:
      v

# the record type's arguments, its quantities from the value where it gives one
def tqf.rec.args(ps: List<&2, T.BParam>, a: T.Bt, +bs: List<&2, TqBind>) -> T.Bt:
  match ps a:
    case T.BParam{m, +x, ty} <> pt T.BtArgs{+v, rest}:
      T.BtArgs{tqf.rec.arg(tqf.find(bs, x), v), tqf.rec.args(pt, rest, bs)}
    case _ a:
      a

def tqf.ret.of(s: TqSig, +n: List<&2, U32>, a: T.Bt, +vs: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match s:
    case TqType{+ps, k, [T.BCtor{c, +fs}]}:
      T.BtTyApp{n, tqf.rec.args(ps, a, tqf.rec.qs(ps, fs, vs, ctx, e, Nil{}))}
    case _:
      T.BtTyApp{n, a}

# a type's arguments with its quantities as another application of it has
# them
def tqf.qargs(ps: List<&2, T.BParam>, a: T.Bt, a2: T.Bt) -> T.Bt:
  match ps a a2:
    case T.BParam{m, x, T.BtVar{+k}} <> pt T.BtArgs{+v, rest} T.BtArgs{v2, rest2}:
      T.BtArgs{Bool.pick(T.Bt, S.eq(k, S.b("Quant")), tqf.rewrap(v, tqf.undead(v2)), v), tqf.qargs(pt, rest, rest2)}
    case p <> pt T.BtArgs{v, rest} T.BtArgs{v2, rest2}:
      T.BtArgs{v, tqf.qargs(pt, rest, rest2)}
    case _ a _:
      a

def tqf.ret.call(m: Maybe<&2, T.Bt>, s: TqSig, +n: List<&2, U32>, +a: T.Bt) -> T.Bt:
  match m s:
    case Some{T.BtTyApp{+n2, a2}} TqType{ps, k, cs}:
      Bool.pick(T.Bt, S.eq(n, n2), T.BtTyApp{n, tqf.qargs(ps, a, a2)}, T.BtTyApp{n, a})
    case _ _:
      T.BtTyApp{n, a}

# a def whose body is a record's value: its return type's quantities from
# it; whose body is a call returning the same type: from the call's type
# (`preorder = ≡-preorder (setoid A)` is a Preorder<a, &2, &2>, ≡ being
# Data, though Agda's levels say a a a; 2026-10-21)
def tqf.ret.fix(ret: T.Bt, +body: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match ret body:
    case T.BtTyApp{+n, a} T.BtExpr{T.BtCon{c, +vs}}:
      tqf.ret.of(tqf.sig(e, n), n, a, vs, ctx, e)
    case T.BtTyApp{+n, +a} T.BtExpr{+b}:
      tqf.ret.call(tqf.ty(16n, b, ctx, e), tqf.sig(e, n), n, a)
    case ret b:
      ret

# a constructor's field types, each in the scope of the fields before it
def tqf.fix.fs(fs: List<&2, T.BField>, +ctx: List<&2, T.BParam>, +e: TqEnv) -> List<&2, T.BField>:
  match fs:
    case Nil{}:
      Nil{}
    case T.BField{+x, ty} <> t:
      +ty2 = tqf.fix(ty, ctx, e)
      T.BField{x, ty2} <> tqf.fix.fs(t, T.BParam{T.BmLive{}, x, ty2} <> ctx, e)

def tqf.fix.cs(cs: List<&2, T.BCtor>, +ctx: List<&2, T.BParam>, +e: TqEnv) -> List<&2, T.BCtor>:
  match cs:
    case Nil{}:
      Nil{}
    case T.BCtor{c, fs} <> t:
      T.BCtor{c, tqf.fix.fs(fs, ctx, e)} <> tqf.fix.cs(t, ctx, e)

# A type-valued definition's own kind --------------------------------------
#
# The cata leaves a type-valued definition with an expression body its
# Agda sort (`_∩_ : … -> A -> Kind(l₁ <&> l₂)`); it keeps it when its body
# is of that kind (as Bend sees it: the same atoms), is Data when its body
# is Data, and is Type otherwise, as `¬ A = A -> ⊥` must be (a function
# type is no Kind(a)).  A caller then passes `P ∩ Q` where a
# Pred(A, l₁ <&> l₂) is expected.  Bend reads a call's kind off this
# declared sort, never off the body (2026-10-21, tested: `Box<&2, T2()>`
# with `def T2() -> Type: Nat` fails), so tqf.kind does too.

def tqf.subset(xs: List<&2, List<&2, U32>>, +ys: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      True{}
    case +x <> t:
      Bool.and(tqf.mem(x, ys), tqf.subset(t, ys))

def tqf.same.q(+a: T.Bt, +b: T.Bt) -> Bool:
  +x = tqf.atoms(a)
  +y = tqf.atoms(b)
  Bool.and(tqf.subset(x, y), tqf.subset(y, x))

def tqf.end.q(t: T.Bt) -> Maybe<&2, T.Bt>:
  match t:
    case T.BtPi{m, y, d, a, b}:
      tqf.end.q(b)
    case T.BtApp{T.BtVar{+k}, T.BtArgs{+q, T.BtANil{}}}:
      Bool.pick(Maybe<&2, T.Bt>, S.eq(k, S.b("Kind")), Some{q}, None{})
    case _:
      None{}

def tqf.end.type(t: T.Bt) -> T.Bt:
  match t:
    case T.BtPi{m, y, d, a, b}:
      T.BtPi{m, y, d, a, tqf.end.type(b)}
    case T.BtApp{T.BtVar{+k}, +a}:
      Bool.pick(T.Bt, S.eq(k, S.b("Kind")), T.BtType{}, T.BtApp{T.BtVar{k}, a})
    case t:
      t

def tqf.end.data(t: T.Bt) -> T.Bt:
  match t:
    case T.BtPi{m, y, d, a, b}:
      T.BtPi{m, y, d, a, tqf.end.data(b)}
    case T.BtApp{T.BtVar{+k}, +a}:
      Bool.pick(T.Bt, S.eq(k, S.b("Kind")), T.BtVar{S.b("Data")}, T.BtApp{T.BtVar{k}, a})
    case t:
      t

def tqf.ret.keep(m: Maybe<&2, T.Bt>, +ret: T.Bt, +b: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match m:
    case Some{+q}:
      +k = tqf.kind.fam(16n, b, ctx, e)
      Bool.pick(T.Bt, tqf.same.q(q, k), ret, Bool.pick(T.Bt, tqf.is(k, "&2"), tqf.end.data(ret), tqf.end.type(ret)))
    case None{}:
      ret

# a sort reached through a type-valued call (`P ∖ Q : Pred A (ℓ₁ ⊔ ℓ₂)`,
# whose body `P ∩ ∁ Q` is a Type, as ¬ is): the call opened, its end
# weakened the same way, when the body is not of its kind
def tqf.ret.open(m: Maybe<&2, T.Bt>, +ret: T.Bt, +w: T.Bt, +b: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match m:
    case Some{+q}:
      +k = tqf.kind.fam(16n, b, ctx, e)
      Bool.pick(T.Bt, tqf.same.q(q, k), ret, Bool.pick(T.Bt, tqf.is(k, "&2"), tqf.end.data(w), tqf.end.type(w)))
    case None{}:
      ret

def tqf.ret.sort(m: Maybe<&2, T.Bt>, +ret: T.Bt, +b: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match m:
    case Some{+q}:
      tqf.ret.keep(Some{q}, ret, b, ctx, e)
    case None{}:
      +w = tqf.whnf(16n, ret, e)
      tqf.ret.open(tqf.end.q(w), ret, w, b, ctx, e)

def tqf.ret.kind(+ret: T.Bt, body: T.Bt, +ctx: List<&2, T.BParam>, +e: TqEnv) -> T.Bt:
  match body:
    case T.BtExpr{+b}:
      tqf.ret.sort(tqf.end.q(ret), ret, b, ctx, e)
    case _:
      ret

def tqf.item(it: T.BItem, +e: TqEnv) -> T.BItem:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      +ps2 = tqf.fix.ps(ps, Nil{}, e)
      +ctx = tqf.ctx.of(ps2, Nil{})
      +ret1 = tqf.fix(ret, ctx, e)
      +body2 = tqf.fix.body(body, ret1, ctx, e)
      T.BiDef{n, ps2, tqf.ret.kind(tqf.ret.fix(ret1, body2, ctx, e), body2, ctx, e), body2, doc}
    case T.BiType{n, ps, k, cs, doc}:
      +ps2 = tqf.fix.ps(ps, Nil{}, e)
      T.BiType{n, ps2, k, tqf.fix.cs(cs, tqf.ctx.of(ps2, Nil{}), e), doc}
    case it:
      it

def tqf.sig.of(it: T.BItem) -> TqSig:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      TqDef{ps, ret, body}
    case T.BiType{n, ps, k, cs, doc}:
      TqType{ps, k, cs}
    case T.BiComment{doc}:
      TqNone{}

# A signature for the other modules: its own module's names (printed bare
# there) given the module's alias, as other modules print them, so that a
# body opened elsewhere (`Rel = REL(a, a, x, x, l)` from Structures) and a
# parameter type (`Dec<a, A>`) name what the caller's env holds; bound
# names stay (2026-10-21)
def tqf.has.b(r: Map<&2, Bool> & Bool) -> Bool:
  (m, b) = r
  b

def tqf.q.name(+n: List<&2, U32>, +names: Map<&2, Bool>, +bound: List<&2, List<&2, U32>>, +pre: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Bool.and(tqf.has.b(Map.has(&2, Bool, names, S.str(n))), Bool.not(tqf.mem(n, bound))), List.append(&2, U32, pre, n), n)

def tqf.qual(t: T.Bt, +names: Map<&2, Bool>, +bound: List<&2, List<&2, U32>>, +pre: List<&2, U32>) -> T.Bt:
  match t:
    case T.BtVar{+n}:
      T.BtVar{tqf.q.name(n, names, bound, pre)}
    case T.BtApp{f, a}:
      T.BtApp{tqf.qual(f, names, bound, pre), tqf.qual(a, names, bound, pre)}
    case T.BtTyApp{+n, a}:
      T.BtTyApp{tqf.q.name(n, names, bound, pre), tqf.qual(a, names, bound, pre)}
    case T.BtArgs{a, rest}:
      T.BtArgs{tqf.qual(a, names, bound, pre), tqf.qual(rest, names, bound, pre)}
    case T.BtTplArg{a}:
      T.BtTplArg{tqf.qual(a, names, bound, pre)}
    case T.BtLam{m, +y, b}:
      T.BtLam{m, y, tqf.qual(b, names, y <> bound, pre)}
    case T.BtPi{m, +y, d, a, b}:
      T.BtPi{m, y, d, tqf.qual(a, names, bound, pre), tqf.qual(b, names, y <> bound, pre)}
    case T.BtCon{c, a}:
      T.BtCon{c, tqf.qual(a, names, bound, pre)}
    case T.BtEq{ty, a, b}:
      T.BtEq{tqf.qual(ty, names, bound, pre), tqf.qual(a, names, bound, pre), tqf.qual(b, names, bound, pre)}
    case T.BtSucc{a}:
      T.BtSucc{tqf.qual(a, names, bound, pre)}
    case T.BtAnn{a, ty}:
      T.BtAnn{tqf.qual(a, names, bound, pre), tqf.qual(ty, names, bound, pre)}
    case T.BtDead{a}:
      T.BtDead{tqf.qual(a, names, bound, pre)}
    case T.BtExpr{b}:
      T.BtExpr{tqf.qual(b, names, bound, pre)}
    case t:
      t

def tqf.qual.ps(ps: List<&2, T.BParam>, +names: Map<&2, Bool>, +bound: List<&2, List<&2, U32>>, +pre: List<&2, U32>) -> List<&2, T.BParam>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, +x, ty} <> t:
      T.BParam{m, x, tqf.qual(ty, names, bound, pre)} <> tqf.qual.ps(t, names, x <> bound, pre)

def tqf.ps.names(ps: List<&2, T.BParam>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, x, ty} <> t:
      x <> tqf.ps.names(t)

def tqf.sig.home(it: T.BItem, +names: Map<&2, Bool>, +pre: List<&2, U32>) -> TqSig:
  match it:
    case T.BiDef{n, +ps, ret, body, doc}:
      +bound = tqf.ps.names(ps)
      TqDef{tqf.qual.ps(ps, names, Nil{}, pre), tqf.qual(ret, names, bound, pre), tqf.qual(body, names, bound, pre)}
    case T.BiType{n, ps, k, cs, doc}:
      TqType{tqf.qual.ps(ps, names, Nil{}, pre), k, cs}
    case T.BiComment{doc}:
      TqNone{}

def tqf.name.of(it: T.BItem) -> List<&2, U32>:
  match it:
    case T.BiDef{n, ps, ret, body, doc}:
      n
    case T.BiType{n, ps, k, cs, doc}:
      n
    case T.BiComment{doc}:
      Nil{}

def tqf.env.put(+n: List<&2, U32>, s: TqSig, e: TqEnv) -> TqEnv:
  match e:
    case TqEnv{sig, here}:
      TqEnv{Map.set(&2, TqSig, sig, S.str(n), s), here}

# The module's items solved in order, each one's signature added for those
# after it (their own names are printed bare).
def tqf.items(its: List<&2, T.BItem>, +e: TqEnv) -> List<&2, T.BItem>:
  match its:
    case Nil{}:
      Nil{}
    case it <> t:
      +it2 = tqf.item(it, e)
      it2 <> tqf.items(t, tqf.env.put(tqf.name.of(it2), tqf.sig.of(it2), e))

