import Base
import ../Sys.bend as S
import ../ToBend/Names.bend as N
import ../ToBend/Ast.bend as T
import ./Ast.bend as A

# Cata: the translation of parsed Agda (Agda2Bend/Ast.bend) into the Bend
# syntax tree (ToBend/Ast.bend).  It is a fold: each form's Bend is built
# from its parts' Bend and the form's own data (a name's entry in the
# symbol table, a binder's INFO), with the context of the binders in scope
# passed down.  `act.t(fuel, a, ctx, env)` is the fold over terms; ctx maps
# each de Bruijn index to the Bend term it stands for (index 0 first).
#
# What it maps (the plan of 2026-10-19):
# - Set ℓ, Setω and every sort to Type; Level binders, arguments and
#   level-valued definitions are dropped (Bend has one universe);
# - a Pi to @x:A -> B, erased (@-x) when the binder is hidden, instance,
#   irrelevant or @0, or a type, a type family (a Pi into a sort), or a
#   parameter of a definition whose value is a type;
# - a definition's application to a call grouped by its arity (the
#   parameters its clauses match), dropped arguments left out: f(a, b)(c);
# - constructors to C{..} (Nat's zero and suc to 0n and 1n+n, Bool's to
#   True{} and False{}, ≡'s refl to {==}), ≡ itself to {a == b : A};
# - a module application's copy (agda-export writes only its case tree,
#   FORMAT.md "Copies") to its leaf with the arguments substituted, so the
#   output calls the generic original as agda-categories' source does;
# - clauses to one match on the parameters they split, in parameter order
#   (Bend refuses a match on an earlier parameter inside one on a later),
#   patterns nested as Agda wrote them; copattern clauses to the record's
#   constructor; a record field's projection to a match on the record.
# What it cannot map it writes as a BtTodo with the reason, which fails
# that def at the gate and names the cause in the ledger.  Every def is
# prefixed `act.` (the substitution `asb.`).

# The switch for quantities: OFF since 2026-10-20 07:20.  Mapping every level
# to a quantity was unsound: a type at a variable level may be a function
# type, which Bend makes Type, so `Setoids c ℓ` cannot have homs of kind
# Kind(qc <&> qℓ) (probe: 146 of 2226 items checked).  A quantity argument
# has to be the kind of the type it governs, which needs kind inference;
# until then levels are dropped as before.
def act.quant.on() -> Bool:
  True{}

# Substitution -----------------------------------------------------------------
#
# A copy's leaf is a term in the scope of its own variables; inlining it
# substitutes the use site's arguments for them, shifting each argument's
# free variables over the binders it is put under.  Sorts and levels are
# walked too: with levels as quantities (2026-10-20) a level variable left
# unshifted named the wrong binder (`Rel Carrier ℓ` opened to `Carrier ->
# Carrier -> Kind(Carrier)`).

# the elimination spine es, then more
def asb.elims.cat(es: A.Ag, more: A.Ag) -> A.Ag:
  match es:
    case A.AgEApp{i, t, rest}:
      A.AgEApp{i, t, asb.elims.cat(rest, more)}
    case A.AgEProj{q, rest}:
      A.AgEProj{q, asb.elims.cat(rest, more)}
    case A.AgERaw{x, rest}:
      A.AgERaw{x, asb.elims.cat(rest, more)}
    case _:
      more

def asb.push.head(t: A.Ag, es: A.Ag) -> A.Ag:
  match t:
    case A.AgVar{i, x, es0}:
      A.AgVar{i, x, asb.elims.cat(es0, es)}
    case A.AgDef{q, es0}:
      A.AgDef{q, asb.elims.cat(es0, es)}
    case A.AgCon{q, o, es0}:
      A.AgCon{q, o, asb.elims.cat(es0, es)}
    case A.AgMeta{es0}:
      A.AgMeta{asb.elims.cat(es0, es)}
    case t:
      t

# t applied to the eliminations es: a head takes them; a lambda becomes a
# redex (AgBeta) the copy inlining reduces; anything else is left as it is
def asb.push(t: A.Ag, es: A.Ag) -> A.Ag:
  match t es:
    case t A.AgENil{}:
      t
    case A.AgLam{i, x, d, b} es:
      A.AgBeta{A.AgLam{i, x, d, b}, es}
    case A.AgBeta{f, es0} es:
      A.AgBeta{f, asb.elims.cat(es0, es)}
    case t es:
      asb.push.head(t, es)

# the binder count under a lambda's or a Pi's body: one more when it
# binds (abs), the same when it does not (noabs: FORMAT.md, "binds none")
def asb.under(dep: Bool, +c: Nat) -> Nat:
  match dep:
    case True{}:
      1n+c
    case False{}:
      c

# variables at or above c shifted up by d
def asb.shift(t: A.Ag, +d: Nat, +c: Nat) -> A.Ag:
  match t:
    case A.AgSort{s}:
      A.AgSort{asb.shift(s, d, c)}
    case A.AgSSet{l}:
      A.AgSSet{asb.shift(l, d, c)}
    case A.AgSProp{l}:
      A.AgSProp{asb.shift(l, d, c)}
    case A.AgLevel{l}:
      A.AgLevel{asb.shift(l, d, c)}
    case A.AgLMax{n, ps}:
      A.AgLMax{n, asb.shift(ps, d, c)}
    case A.AgLPlus{k, x, rest}:
      A.AgLPlus{k, asb.shift(x, d, c), asb.shift(rest, d, c)}
    case A.AgBeta{f, es}:
      A.AgBeta{asb.shift(f, d, c), asb.shift(es, d, c)}
    case A.AgVar{+i, x, es}:
      A.AgVar{Bool.pick(Nat, Nat.is_lt(i, c), i, Nat.add(i, d)), x, asb.shift(es, d, c)}
    case A.AgLam{i, x, +dep, b}:
      A.AgLam{i, x, dep, asb.shift(b, d, asb.under(dep, c))}
    case A.AgDef{q, es}:
      A.AgDef{q, asb.shift(es, d, c)}
    case A.AgCon{q, o, es}:
      A.AgCon{q, o, asb.shift(es, d, c)}
    case A.AgPi{i, x, a, +dep, b}:
      A.AgPi{i, x, asb.shift(a, d, c), dep, asb.shift(b, d, asb.under(dep, c))}
    case A.AgEl{s, a}:
      A.AgEl{asb.shift(s, d, c), asb.shift(a, d, c)}
    case A.AgDontCare{a}:
      A.AgDontCare{asb.shift(a, d, c)}
    case A.AgMeta{es}:
      A.AgMeta{asb.shift(es, d, c)}
    case A.AgEApp{i, a, rest}:
      A.AgEApp{i, asb.shift(a, d, c), asb.shift(rest, d, c)}
    case A.AgEProj{q, rest}:
      A.AgEProj{q, asb.shift(rest, d, c)}
    case A.AgERaw{x, rest}:
      A.AgERaw{x, asb.shift(rest, d, c)}
    case t:
      t

# the n-th of xs (a variable past the end is left free)
def asb.nth(n: Nat, xs: List<&2, A.Ag>) -> Maybe<&2, A.Ag>:
  match n xs:
    case 0n h <> t:
      Some{h}
    case 1n+p h <> t:
      asb.nth(p, t)
    case _ Nil{}:
      None{}

def asb.var.of(m: Maybe<&2, A.Ag>, +depth: Nat, +i: Nat, +n: Nat, x: List<&2, U32>, es: A.Ag) -> A.Ag:
  match m:
    case Some{v}:
      asb.push(asb.shift(v, depth, 0n), es)
    case None{}:
      A.AgVar{Nat.sub(i, n), x, es}

# a variable of the substituted term: bound inside it (below depth), one
# of the n substituted, or a free one past them (renumbered)
def asb.subst.var(bound: Bool, +i: Nat, +depth: Nat, +vs: List<&2, A.Ag>, +n: Nat, x: List<&2, U32>, es: A.Ag) -> A.Ag:
  match bound:
    case True{}:
      A.AgVar{i, x, es}
    case False{}:
      asb.var.of(asb.nth(Nat.sub(i, depth), vs), depth, i, n, x, es)

# t (in the scope of n variables, under depth binders of its own) with
# variable depth+j replaced by vs[j]: vs lists the values from index 0 (the
# last variable) up
def asb.subst(t: A.Ag, +depth: Nat, +vs: List<&2, A.Ag>, +n: Nat) -> A.Ag:
  match t:
    case A.AgSort{s}:
      A.AgSort{asb.subst(s, depth, vs, n)}
    case A.AgSSet{l}:
      A.AgSSet{asb.subst(l, depth, vs, n)}
    case A.AgSProp{l}:
      A.AgSProp{asb.subst(l, depth, vs, n)}
    case A.AgLevel{l}:
      A.AgLevel{asb.subst(l, depth, vs, n)}
    case A.AgLMax{n2, ps}:
      A.AgLMax{n2, asb.subst(ps, depth, vs, n)}
    case A.AgLPlus{k, x, rest}:
      A.AgLPlus{k, asb.subst(x, depth, vs, n), asb.subst(rest, depth, vs, n)}
    case A.AgBeta{f, es}:
      A.AgBeta{asb.subst(f, depth, vs, n), asb.subst(es, depth, vs, n)}
    case A.AgVar{+i, x, es}:
      asb.subst.var(Nat.is_lt(i, depth), i, depth, vs, n, x, asb.subst(es, depth, vs, n))
    case A.AgLam{i, x, +dep, b}:
      A.AgLam{i, x, dep, asb.subst(b, asb.under(dep, depth), vs, n)}
    case A.AgDef{q, es}:
      A.AgDef{q, asb.subst(es, depth, vs, n)}
    case A.AgCon{q, o, es}:
      A.AgCon{q, o, asb.subst(es, depth, vs, n)}
    case A.AgPi{i, x, a, +dep, b}:
      A.AgPi{i, x, asb.subst(a, depth, vs, n), dep, asb.subst(b, asb.under(dep, depth), vs, n)}
    case A.AgEl{s, a}:
      A.AgEl{asb.subst(s, depth, vs, n), asb.subst(a, depth, vs, n)}
    case A.AgDontCare{a}:
      A.AgDontCare{asb.subst(a, depth, vs, n)}
    case A.AgMeta{es}:
      A.AgMeta{asb.subst(es, depth, vs, n)}
    case A.AgEApp{i, a, rest}:
      A.AgEApp{i, asb.subst(a, depth, vs, n), asb.subst(rest, depth, vs, n)}
    case A.AgEProj{q, rest}:
      A.AgEProj{q, asb.subst(rest, depth, vs, n)}
    case A.AgERaw{x, rest}:
      A.AgERaw{x, asb.subst(rest, depth, vs, n)}
    case t:
      t

# Symbols ----------------------------------------------------------------------

# A parameter's mode in Bend: dropped (a Level), erased, live, copied (+)
# or a template (~); the last two, and live for a hidden parameter used as
# a value, come from the quantity pass (ToBend/Copy.bend).
type ActM is Data:
  AmDrop{}
  AmErased{}
  AmLive{}
  AmCopy{}
  AmTpl{}

# What a name is in Bend when it is not translated as itself: Nat, Bool,
# Unit, ≡ and their constructors are Base's.  Levels are quantities
# (2026-10-20, so a category's homs may be Data, as Product needs): Level is
# Quant, lzero and lsuc ℓ are &1 (Type), ℓ ⊔ ℓ' the smaller of the two, and
# another level-valued definition (AbLevel) &1.
type ActB is Data:
  AbNone{}
  AbQuant{}
  AbQone{}
  AbQmin{}
  AbNat{}
  AbZero{}
  AbSuc{}
  AbBool{}
  AbTrue{}
  AbFalse{}
  AbEq{}
  AbRefl{}
  AbLevel{}
  AbUnit{}
  AbTt{}

# a copy's case-tree leaf: its variable count and term
type ActCopy is Data:
  ActCopy{n: Nat, body: A.Ag}

# A name's entry: the module it lives in and its Bend name there, its kind,
# its parameters' modes (every Pi of its type, in order), its arity (the
# parameters its Bend def or type takes; a call passes the rest in a second
# application), its builtin role, for a record its fields' keys in order
# (for a data type its constructors'), the Bend name of a record's
# constructor, and a copy's leaf.
type ActSym is Data:
  ActSym{mod: List<&2, U32>, name: List<&2, U32>, kind: A.AgKw, modes: List<&2, ActM>, arity: Nat, b: ActB, fields: List<&2, String>, ctor: List<&2, U32>, copy: Maybe<&2, ActCopy>}

# What a translation sees: the module being written, the symbol table (by
# NameId key), each module's import alias, and the leaves of the type-valued
# definitions that unfold (by key: a header unfolds one to reach the Pis
# its clauses take, e.g. `refl : Reflexive _≈_` with a clause on `{x}`).
type ActEnv is Data:
  ActEnv{mod: List<&2, U32>, tab: Map<&2, ActSym>, al: Map<&2, List<&2, U32>>, unf: Map<&2, ActCopy>}

# a name's key in the table: its NameId
def act.key(q: A.AgQ) -> String:
  match q:
    case A.AgQ{s, w, k}:
      S.str(w) ++ ":" ++ S.str(k)

def act.sym0() -> ActSym:
  ActSym{Nil{}, Nil{}, A.AkWord{}, Nil{}, 0n, AbNone{}, Nil{}, Nil{}, None{}}

def act.qs.of(q: A.AgQ) -> List<&2, U32>:
  match q:
    case A.AgQ{s, w, k}:
      s

# the entry of a name the table does not have: of kind AkWord, its module
# `?` and its name Agda's, so the reason of the gap it leaves names it
def act.sym.none(q: A.AgQ) -> ActSym:
  ActSym{S.b("?"), act.qs.of(q), A.AkWord{}, Nil{}, 0n, AbNone{}, Nil{}, Nil{}, None{}}

def act.sym.got(r: Map<&2, ActSym> & ActSym) -> ActSym:
  (m, s) = r
  s

# the entry of q (an empty one, of kind AkWord, when the table has none)
def act.sym(+env: ActEnv, +q: A.AgQ) -> ActSym:
  match env:
    case ActEnv{mod, tab, al, unf}:
      act.sym.got(Map.get(ActSym, act.sym.none(q), tab, act.key(q)))

def act.alias.got(r: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, U32>:
  (m, a) = r
  a

def act.is.here(+env: ActEnv, +m: List<&2, U32>) -> Bool:
  match env:
    case ActEnv{mod, tab, al, unf}:
      S.eq(mod, m)

def act.alias(+env: ActEnv, +m: List<&2, U32>) -> List<&2, U32>:
  match env:
    case ActEnv{mod, tab, al, unf}:
      act.alias.got(Map.get(List<&2, U32>, m, al, S.str(m)))

def act.ref.of(here: Bool, +env: ActEnv, +m: List<&2, U32>, +n: List<&2, U32>) -> List<&2, U32>:
  match here:
    case True{}:
      n
    case False{}:
      List.append(&2, U32, act.alias(env, m), 46 <> n)

# how the module being written names a symbol: its own names as they are,
# another module's through that module's alias
def act.ref(+env: ActEnv, s: ActSym) -> List<&2, U32>:
  match s:
    case ActSym{+m, +n, k, ms, ar, b, fs, c, cp}:
      act.ref.of(act.is.here(env, m), env, m, n)

def act.ctor.ref(+env: ActEnv, s: ActSym) -> List<&2, U32>:
  match s:
    case ActSym{+m, n, k, ms, ar, b, fs, +c, cp}:
      act.ref.of(act.is.here(env, m), env, m, c)

# Modes ----------------------------------------------------------------------

def act.q.is(q: A.AgQ, +s: String) -> Bool:
  match q:
    case A.AgQ{qs, w, k}:
      S.eq(qs, S.b(s))

# a TYPE whose values are Levels: its sort is the level universe, or it is
# Agda.Primitive.Level
def act.ty.level(t: A.Ag) -> Bool:
  match t:
    case A.AgEl{A.AgSUniv{A.AkLeveluniv{}}, x}:
      True{}
    case A.AgEl{s, A.AgDef{q, es}}:
      act.q.is(q, "Agda.Primitive.Level")
    case _:
      False{}

# a TYPE that ends, after its Pis, in a sort (Set ℓ itself, or a type family)
def act.ends.sort(t: A.Ag) -> Bool:
  match t:
    case A.AgEl{s, x}:
      act.ends.sort(x)
    case A.AgPi{i, x, a, d, b}:
      act.ends.sort(b)
    case A.AgSort{s}:
      True{}
    case _:
      False{}

# a TYPE that ends, after its Pis, in Level (a level-valued definition)
def act.ends.level(t: A.Ag) -> Bool:
  match t:
    case A.AgEl{A.AgSUniv{A.AkLeveluniv{}}, x}:
      True{}
    case A.AgEl{s, A.AgDef{q, es}}:
      act.q.is(q, "Agda.Primitive.Level")
    case A.AgEl{s, x}:
      act.ends.level(x)
    case A.AgPi{i, x, a, d, b}:
      act.ends.level(b)
    case _:
      False{}

# hidden, instance, irrelevant or @0
def act.info.erased(i: A.AgI) -> Bool:
  match i:
    case A.AgI{+h, r, m}:
      Bool.or(Bool.or(A.aas.kw.eq(h, A.AkHidden{}), A.aas.kw.eq(h, A.AkInstance{})), Bool.or(A.aas.kw.eq(r, A.AkIrrelevant{}), A.aas.kw.eq(m, A.AkQ0{})))

def act.mode.of(lv: Bool, er: Bool) -> ActM:
  match lv er:
    case True{} _:
      Bool.pick(ActM, act.quant.on(), AmErased{}, AmDrop{})
    case False{} True{}:
      AmErased{}
    case False{} False{}:
      AmLive{}

# a Pi binder's mode: a Level is dropped; it is erased when hidden,
# instance, irrelevant or @0, when it is a type or a type family, or when
# the whole definition is type-valued (tylevel)
def act.mode(i: A.AgI, +a: A.Ag, tylevel: Bool) -> ActM:
  act.mode.of(act.ty.level(a), Bool.or(Bool.or(act.info.erased(i), act.ends.sort(a)), tylevel))

# the modes of every Pi of a TYPE
def act.modes(t: A.Ag, +tylevel: Bool) -> List<&2, ActM>:
  match t:
    case A.AgEl{s, x}:
      act.modes(x, tylevel)
    case A.AgPi{i, x, a, d, b}:
      act.mode(i, a, tylevel) <> act.modes(b, tylevel)
    case A.AgStored{x}:
      act.modes(x, tylevel)
    case _:
      Nil{}

def act.bi(+s: List<&2, U32>, +name: String, b: ActB, other: ActB) -> ActB:
  Bool.pick(ActB, S.eq(s, S.b(name)), b, other)

# the builtin role of a name, by its printed name
def act.builtin(+s: List<&2, U32>) -> ActB:
  act.bi(s, "Agda.Builtin.Nat.Nat", AbNat{}, act.bi(s, "Agda.Builtin.Nat.Nat.zero", AbZero{}, act.bi(s, "Agda.Builtin.Nat.Nat.suc", AbSuc{},
  act.bi(s, "Agda.Builtin.Bool.Bool", AbBool{}, act.bi(s, "Agda.Builtin.Bool.Bool.true", AbTrue{}, act.bi(s, "Agda.Builtin.Bool.Bool.false", AbFalse{},
  act.bi(s, "Agda.Builtin.Equality._≡_", AbEq{}, act.bi(s, "Agda.Builtin.Equality._≡_.refl", AbRefl{},
  act.bi(s, "Agda.Builtin.Unit.⊤", AbUnit{}, act.bi(s, "Agda.Builtin.Unit.tt", AbTt{},
  act.bi(s, "Agda.Primitive.Level", AbQuant{}, act.bi(s, "Agda.Primitive.lzero", AbQone{}, act.bi(s, "Agda.Primitive.lsuc", AbQone{},
  act.bi(s, "Agda.Primitive._⊔_", AbQmin{}, AbNone{}))))))))))))))

# Terms ------------------------------------------------------------------------

def act.level() -> T.Bt:
  T.BtTodo{S.b("level")}

def act.todo(s: String) -> T.Bt:
  T.BtTodo{S.b(s)}

# the term a de Bruijn index stands for
def act.ctx.at(i: Nat, ctx: List<&2, T.Bt>) -> T.Bt:
  match i ctx:
    case 0n h <> t:
      h
    case 1n+p h <> t:
      act.ctx.at(p, t)
    case _ Nil{}:
      act.todo("a variable outside its scope")

# Quantities ------------------------------------------------------------------
#
# A level is a quantity in Bend: a type of sort Set ℓ has kind Kind(qℓ), so
# a type whose level is a variable may be Data where its user needs copies
# (Product's morphism pairs), and `Set ℓ` built from variables only is
# `Kind(…)`.  A constant level or a successor is a universe of sets: Type
# (&1).  The smaller of two quantities is `a <&> b`; &1 absorbs the rest.

def act.q1() -> T.Bt:
  T.BtVar{S.b("&1")}

def act.is.q1(t: T.Bt) -> Bool:
  match t:
    case T.BtVar{n}:
      S.eq(n, S.b("&1"))
    case _:
      False{}

# (quantity terms are names, so the minimum is written as one: "(a <&> b)")
def act.q.name(t: T.Bt) -> List<&2, U32>:
  match t:
    case T.BtVar{n}:
      n
    case _:
      S.b("&1")

def act.q2() -> T.Bt:
  T.BtVar{S.b("&2")}

def act.is.q2(t: T.Bt) -> Bool:
  match t:
    case T.BtVar{n}:
      S.eq(n, S.b("&2"))
    case _:
      False{}

# (&2 is the unit of the minimum, &1 absorbs it)
def act.qmin(+a: T.Bt, +b: T.Bt) -> T.Bt:
  Bool.pick(T.Bt, act.is.q2(a), b, Bool.pick(T.Bt, act.is.q2(b), a, Bool.pick(T.Bt, Bool.or(act.is.q1(a), act.is.q1(b)), act.q1(), T.BtVar{List.append(&2, U32, 40 <> act.q.name(a), List.append(&2, U32, S.b(" <&> "), List.append(&2, U32, act.q.name(b), [41])))})))

# ⊔ applied: its two (kept) arguments
def act.qmin.args(args: T.Bt) -> T.Bt:
  match args:
    case T.BtArgs{T.BtDead{a}, T.BtArgs{T.BtDead{b}, T.BtANil{}}}:
      act.qmin(a, b)
    case T.BtArgs{a, T.BtArgs{b, T.BtANil{}}}:
      act.qmin(a, b)
    case _:
      act.q1()

def act.qt.ismin(s: ActSym) -> Bool:
  match s:
    case ActSym{m, n, k, ms, ar, AbQmin{}, fs, c, cp}:
      True{}
    case _:
      False{}

# a level term as a quantity
def act.qt(t: A.Ag, +ctx: List<&2, T.Bt>, +env: ActEnv) -> T.Bt:
  match t:
    case A.AgLevel{l}:
      Bool.pick(T.Bt, act.quant.on(), act.qt(l, ctx, env), act.level())
    case A.AgLMax{0n, ps}:
      act.qt(ps, ctx, env)
    case A.AgLMax{1n+n, ps}:
      act.q1()
    case A.AgLPlus{0n, x, A.AgLEnd{}}:
      act.qt(x, ctx, env)
    case A.AgLPlus{0n, x, rest}:
      act.qmin(act.qt(x, ctx, env), act.qt(rest, ctx, env))
    case A.AgLPlus{1n+k, x, rest}:
      act.q1()
    case A.AgVar{+i, x, es}:
      act.ctx.at(i, ctx)
    case A.AgDef{+q, A.AgEApp{i, a, A.AgEApp{i2, b, A.AgENil{}}}}:
      Bool.pick(T.Bt, act.qt.ismin(act.sym(env, q)), act.qmin(act.qt(a, ctx, env), act.qt(b, ctx, env)), act.q1())
    case A.AgDefX{+q, A.AgEApp{i, a, A.AgEApp{i2, b, A.AgENil{}}}}:
      Bool.pick(T.Bt, act.qt.ismin(act.sym(env, q)), act.qmin(act.qt(a, ctx, env), act.qt(b, ctx, env)), act.q1())
    case _:
      act.q1()

# a sort: Set ℓ is Kind(qℓ), unless qℓ is &1 (Type); any other sort is Type
def act.kind.of(+q: T.Bt) -> T.Bt:
  Bool.pick(T.Bt, act.is.q1(q), T.BtType{}, T.BtApp{T.BtVar{S.b("Kind")}, T.BtArgs{q, T.BtANil{}}})

def act.sort(s: A.Ag, +ctx: List<&2, T.Bt>, +env: ActEnv) -> T.Bt:
  match s:
    case A.AgSSet{l}:
      act.kind.of(act.qt(l, ctx, env))
    case _:
      T.BtType{}

# the context entry of a Level binder
def act.is.marker(t: T.Bt) -> Bool:
  match t:
    case T.BtTodo{why}:
      S.eq(why, S.b("level"))
    case _:
      False{}

def act.sym.level(s: ActSym) -> Bool:
  match s:
    case ActSym{m, n, k, ms, ar, AbLevel{}, fs, c, cp}:
      True{}
    case _:
      False{}

# is an argument a level expression: a level, a Level-valued definition
# applied, or a level variable (its context entry is the level marker)
def act.is.level(a: A.Ag, +ctx: List<&2, T.Bt>, +env: ActEnv) -> Bool:
  match a:
    case A.AgLevel{l}:
      True{}
    case A.AgDef{q, es}:
      act.sym.level(act.sym(env, q))
    case A.AgDefX{q, es}:
      act.sym.level(act.sym(env, q))
    case A.AgVar{i, x, es}:
      act.is.marker(act.ctx.at(i, ctx))
    case _:
      False{}

# an argument as the fold gives it to an application: a level argument is
# the level marker (an application to a variable drops it; one to a
# definition drops it by the definition's modes)
def act.arg(lv: Bool, t: T.Bt) -> T.Bt:
  match lv:
    case True{}:
      act.level()
    case False{}:
      t

# the names of the binders in scope
def act.names(ctx: List<&2, T.Bt>) -> List<&2, List<&2, U32>>:
  match ctx:
    case Nil{}:
      Nil{}
    case T.BtVar{x} <> t:
      x <> act.names(t)
    case h <> t:
      act.names(t)

def act.used(+x: List<&2, U32>, ns: List<&2, List<&2, U32>>) -> Bool:
  match ns:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(S.eq(h, x), act.used(x, t))

def act.hint.of(+b: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.eq(b, S.b("anon")), S.b("x"), b)

def act.hint(+x: List<&2, U32>) -> List<&2, U32>:
  act.hint.of(S.b(N.tnm.part(S.str(x))))

def act.nth.name(+b: List<&2, U32>, +n: Nat) -> List<&2, U32>:
  List.append(&2, U32, b, 95 <> S.b(Nat.show(n)))

# b_n, or b_(n+1) and so on while that one is taken too (clash: b_n is)
def act.fresh.try(fuel: Nat, clash: Bool, +b: List<&2, U32>, +ns: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, U32>:
  match fuel clash:
    case 1n+f True{}:
      act.fresh.try(f, act.used(act.nth.name(b, 1n+n), ns), b, ns, 1n+n)
    case _ _:
      act.nth.name(b, n)

def act.fresh.of(clash: Bool, +b: List<&2, U32>, +n: Nat, +ns: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match clash:
    case True{}:
      act.fresh.try(64n, act.used(act.nth.name(b, n), ns), b, ns, n)
    case False{}:
      b

def act.fresh.go(+b: List<&2, U32>, +ctx: List<&2, T.Bt>) -> List<&2, U32>:
  +ns = act.names(ctx)
  act.fresh.of(act.used(b, ns), b, List.length(&2, T.Bt, ctx), ns)

def act.fresh.in.of(+b: List<&2, U32>, +ns: List<&2, List<&2, U32>>, +n: Nat) -> List<&2, U32>:
  act.fresh.of(act.used(b, ns), b, n, ns)


# A name for a binder from Agda's hint, distinct from every name in scope
# (a clash gets the scope's depth after an underscore).
# a fresh name against the context and the names seen besides
def act.fresh.in(+x: List<&2, U32>, +ctx: List<&2, T.Bt>, +seen: List<&2, List<&2, U32>>) -> List<&2, U32>:
  act.fresh.in.of(act.hint(x), List.append(&2, List<&2, U32>, act.names(ctx), seen), Nat.add(List.length(&2, T.Bt, ctx), List.length(&2, List<&2, U32>, seen)))

def act.fresh(+x: List<&2, U32>, +ctx: List<&2, T.Bt>) -> List<&2, U32>:
  act.fresh.go(act.hint(x), ctx)
# Copies ------------------------------------------------------------------------

# the first n arguments of an elimination spine (in order) and the rest;
# ok is False when the spine has fewer, or a projection among them
type ActSplit is Data:
  ActSplit{vs: List<&2, A.Ag>, rest: A.Ag, ok: Bool}

def act.split.put(t: A.Ag, s: ActSplit) -> ActSplit:
  match s:
    case ActSplit{vs, rest, ok}:
      ActSplit{t <> vs, rest, ok}

def act.split(n: Nat, es: A.Ag) -> ActSplit:
  match n es:
    case 0n es:
      ActSplit{Nil{}, es, True{}}
    case 1n+p A.AgEApp{i, t, rest}:
      act.split.put(t, act.split(p, rest))
    case 1n+p es:
      ActSplit{Nil{}, es, False{}}

def act.unf.got(r: Map<&2, ActCopy> & ActCopy) -> ActCopy:
  (m, c) = r
  c

def act.unfold.split(+n: Nat, body: A.Ag, s: ActSplit) -> A.Ag:
  match s:
    case ActSplit{vs, rest, True{}}:
      asb.push(asb.subst(body, 0n, List.reverse(&2, A.Ag, vs), n), rest)
    case ActSplit{vs, rest, False{}}:
      A.AgNone{}

# the leaf a type-valued definition unfolds to, with the arguments
# substituted (the rest applied); AgNone when it does not unfold
def act.unfold.of(c: ActCopy, +es: A.Ag) -> A.Ag:
  match c:
    case ActCopy{0n, A.AgNone{}}:
      A.AgNone{}
    case ActCopy{+n, body}:
      act.unfold.split(n, body, act.split(n, es))

# Opaque types: a record field that is a type (Category.Obj C, C [ A , B ],
# Setoid.Carrier S) has elements no clause can split on; the projection's
# symbol carries the mark in its fields.  A visible Pi over such a type
# whose codomain mentions its variable (`η : ∀ X → D [ F₀ X , G₀ X ]`, a
# law's `∀ f → …`) is erased, as the spike erases objects and morphisms:
# Bend cannot copy an element of a Type, and these are used only in types
# and at other erased places (a non-dependent one, `F₁ : C [ A , B ] → …`,
# stays live: it is data).
def act.opaque.mark(srt: Bool) -> List<&2, String>:
  match srt:
    case True{}:
      ["opaque-sort"]
    case False{}:
      Nil{}

def act.opaque.fs(fs: List<&2, String>) -> Bool:
  match fs:
    case h <> Nil{}:
      String.eq(h, "opaque-sort")
    case _:
      False{}

def act.opaque.is(s: ActSym) -> Bool:
  match s:
    case ActSym{m, n, k, ms, ar, b, fs, c, None{}}:
      act.opaque.fs(fs)
    case _:
      False{}

def act.opaque.copy(s: ActSym) -> ActCopy:
  match s:
    case ActSym{m, n, k, ms, ar, b, fs, c, Some{cp}}:
      cp
    case _:
      ActCopy{0n, A.AgNone{}}

# whether an elimination spine projects an opaque field (C .Obj)
def act.opaque.es(es: A.Ag, +tab: Map<&2, ActSym>) -> Bool:
  match es:
    case A.AgEProj{+q, rest}:
      Bool.or(act.opaque.is(act.sym.got(Map.get(ActSym, act.sym0(), tab, act.key(q)))), act.opaque.es(rest, tab))
    case A.AgEApp{i, a, rest}:
      act.opaque.es(rest, tab)
    case _:
      False{}

# whether a TYPE is opaque, seen through copies and type-valued definitions
def act.opaque(fuel: Nat, t: A.Ag, +tab: Map<&2, ActSym>, +unf: Map<&2, ActCopy>) -> Bool:
  match fuel t:
    case f A.AgEl{s, x}:
      act.opaque(f, x, tab, unf)
    case 1n+(+f) A.AgDef{+q, +es}:
      +s = act.sym.got(Map.get(ActSym, act.sym0(), tab, act.key(q)))
      Bool.or(act.opaque.is(s), Bool.or(act.opaque(f, act.unfold.of(act.opaque.copy(s), es), tab, unf), act.opaque(f, act.unfold.of(act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.key(q))), es), tab, unf)))
    case 1n+(+f) A.AgDefX{+q, +es}:
      +s = act.sym.got(Map.get(ActSym, act.sym0(), tab, act.key(q)))
      Bool.or(act.opaque.is(s), Bool.or(act.opaque(f, act.unfold.of(act.opaque.copy(s), es), tab, unf), act.opaque(f, act.unfold.of(act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.key(q))), es), tab, unf)))
    case f A.AgVar{i, x, es}:
      act.opaque.es(es, tab)
    case _ _:
      False{}

# a Pi binder erased as over an opaque type (dep: its codomain mentions it)
def act.opaque.dep(dep: Bool, +a: A.Ag, +tab: Map<&2, ActSym>, +unf: Map<&2, ActCopy>) -> Bool:
  match dep:
    case True{}:
      act.opaque(8n, a, tab, unf)
    case False{}:
      False{}

def act.opaque.env(dep: Bool, +a: A.Ag, +env: ActEnv) -> Bool:
  match env:
    case ActEnv{mod, +tab, al, +unf}:
      act.opaque.dep(dep, a, tab, unf)

def act.expand.copy(+n: Nat, body: A.Ag, q: A.AgQ, +es: A.Ag, s: ActSplit) -> A.Ag:
  match s:
    case ActSplit{vs, rest, True{}}:
      asb.push(asb.subst(body, 0n, List.reverse(&2, A.Ag, vs), n), rest)
    case ActSplit{vs, rest, False{}}:
      A.AgDefX{q, es}

# a definition seen by the inlining: a copy's leaf with the arguments
# substituted (the rest applied to it), anything else marked resolved
def act.expand(s: ActSym, q: A.AgQ, +es: A.Ag) -> A.Ag:
  match s:
    case ActSym{m, n, k, ms, ar, b, fs, c, Some{ActCopy{+nv, body}}}:
      act.expand.copy(nv, body, q, es, act.split(nv, es))
    case _:
      A.AgDefX{q, es}

# a lambda's body with its one argument: put for variable 0 when the
# lambda binds (abs); a constant lambda (noabs) binds none
def act.beta1(d: Bool, b: A.Ag, v: A.Ag) -> A.Ag:
  match d:
    case True{}:
      asb.subst(b, 0n, [v], 1n)
    case False{}:
      b

# Eta unfoldings ---------------------------------------------------------------
#
# A function whose case tree splits only records with eta (Σ's _,_) before
# its one leaf unfolds where its value is a type.  Product's
# `_⇒_ = zipWith C._⇒_ D._⇒_ _×_` matches its two pairs, so `A ⇒ B` stays
# stuck on the variables A B in Bend (which has no record eta), and the
# record's `id` then has no type it fits.  The unfolding (made by
# act.etu.of) writes each split field as the projection of its parameter
# (`proj₁ A`); act.inline takes it only when the call's value is a type (a
# sort, a Pi, a data type or record, a type-valued definition), where every
# place is dead, so the parameters repeat freely.  The unfoldings sit in
# the unfoldings map under "eta:" KEY.

def act.etu.key(q: A.AgQ) -> String:
  "eta:" ++ act.key(q)

def act.etu.get(+env: ActEnv, q: A.AgQ) -> ActCopy:
  match env:
    case ActEnv{mod, tab, al, unf}:
      act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.etu.key(q)))

# whether an elimination spine is applications only
def act.es.plain(es: A.Ag) -> Bool:
  match es:
    case A.AgEApp{i, t, rest}:
      act.es.plain(rest)
    case A.AgENil{}:
      True{}
    case _:
      False{}

def act.es.apps(es: A.Ag) -> Nat:
  match es:
    case A.AgEApp{i, t, rest}:
      1n+act.es.apps(rest)
    case _:
      0n

# the arguments var k-1 ... var 0
def act.etu.args(k: Nat) -> A.Ag:
  match k:
    case 0n:
      A.AgENil{}
    case 1n+(+p):
      A.AgEApp{A.aas.i.vis(), A.AgVar{p, S.b("eta"), A.AgENil{}}, act.etu.args(p)}

def act.etu.lam(k: Nat, b: A.Ag) -> A.Ag:
  match k:
    case 0n:
      b
    case 1n+p:
      A.AgLam{A.aas.i.vis(), S.b("eta"), True{}, act.etu.lam(p, b)}

def act.etu.short(plain: Bool, +k: Nat, +n: Nat, body: A.Ag, +es: A.Ag) -> A.Ag:
  match plain:
    case True{}:
      act.etu.lam(k, act.unfold.of(ActCopy{n, body}, asb.elims.cat(asb.shift(es, k, 0n), act.etu.args(k))))
    case False{}:
      A.AgNone{}

# the unfolding applied to a call's arguments, under a lambda for each one
# the call leaves out (`zipWith f g h` is a relation); AgNone for none
def act.etu.at(c: ActCopy, +es: A.Ag) -> A.Ag:
  match c:
    case ActCopy{0n, A.AgNone{}}:
      A.AgNone{}
    case ActCopy{+n, body}:
      act.etu.short(Bool.or(Bool.not(Nat.is_lt(act.es.apps(es), n)), act.es.plain(es)), Nat.sub(n, act.es.apps(es)), n, body, es)

def act.unf.has.got(r: Map<&2, ActCopy> & Bool) -> Bool:
  (m, b) = r
  b

def act.kind.type(s: ActSym) -> Bool:
  match s:
    case ActSym{m, n, A.AkRecord{}, ms, ar, b, fs, c, cp}:
      True{}
    case ActSym{m, n, A.AkData{}, ms, ar, b, fs, c, cp}:
      True{}
    case _:
      False{}

def act.type.sym(s: ActSym, +env: ActEnv, q: A.AgQ) -> Bool:
  match env:
    case ActEnv{mod, tab, al, unf}:
      Bool.or(act.kind.type(s), act.unf.has.got(Map.has(&2, ActCopy, unf, act.key(q))))

# whether a term is a type by its head (a copy seen through)
def act.type.head(fuel: Nat, t: A.Ag, +env: ActEnv) -> Bool:
  match fuel t:
    case f A.AgSort{s}:
      True{}
    case f A.AgPi{i, x, a, d, b}:
      True{}
    case f A.AgEl{s, x}:
      True{}
    case f A.AgLam{i, x, d, b}:
      act.type.head(f, b, env)
    case f A.AgBeta{g, es}:
      act.type.head(f, g, env)
    case f A.AgDefX{+q, es}:
      act.type.sym(act.sym(env, q), env, q)
    case 1n+f A.AgDef{+q, +es}:
      Bool.or(act.type.sym(act.sym(env, q), env, q), act.type.head(f, act.expand(act.sym(env, q), q, es), env))
    case _ _:
      False{}

# whether a term builds a constructor (under its lambdas)
def act.con.head(t: A.Ag) -> Bool:
  match t:
    case A.AgLam{i, x, d, b}:
      act.con.head(b)
    case A.AgBeta{g, es}:
      act.con.head(g)
    case A.AgCon{q, o, es}:
      True{}
    case _:
      False{}

def act.etu.n(c: ActCopy) -> Nat:
  match c:
    case ActCopy{n, b}:
      n

def act.etu.pick(+u: A.Ag, d: A.Ag, part: Bool, +env: ActEnv) -> A.Ag:
  Bool.pick(A.Ag, Bool.or(act.type.head(16n, u, env), Bool.and(Bool.and(part, act.quant.on()), act.con.head(u))), u, d)

# a call act.inline resolved as no copy (AgDefX), unfolded instead when it
# has an eta unfolding and its value there is a type, or it is partial and
# builds a pair (Product's `_∘_ = zip C._∘_ D._∘_`: by projections its laws
# reduce on morphism variables; a pair used twice then needs Data homs,
# which the quantity repairs specialise it to).  at: the call is a record
# constructor's argument, under its lambdas (2026-10-21: only there, as
# Product's fields are; `map₁ f = map f id` unfolded used its pair twice
# and needed Data, where the call checks)
def act.etu.try(t: A.Ag, +q: A.AgQ, +es: A.Ag, at: Bool, +env: ActEnv) -> A.Ag:
  match t:
    case A.AgDefX{q2, es2}:
      +c = act.etu.get(env, q)
      act.etu.pick(act.etu.at(c, es), A.AgDefX{q2, es2}, Bool.and(at, Nat.is_lt(act.es.apps(es), act.etu.n(c))), env)
    case t:
      t

# Copattern reductions --------------------------------------------------------
#
# A field projected out of a definition made by copatterns reduces here to
# that field's clause: `isPartialEquivalence (partialSetoid S)` is
# `IsEquivalence.isPartialEquivalence (isEquivalence S)`, and through
# Category's hom-setoid a reasoning lemma's `partialSetoid(~hom-setoid(~C,
# X, Y))` (a template argument, which must be closed: its objects had to be
# templates, and no caller with a lambda's objects could use the lemma)
# becomes C's equiv at X Y, with S or C used once.  Bend would do the same
# when it inlines a template; doing it here also takes non-closed records.
# The clauses sit in the unfoldings under "cop:" DEF "|" FIELD (act.cop.add).

def act.cop.key(f: A.AgQ, q: A.AgQ) -> String:
  "cop:" ++ act.key(f) ++ "|" ++ act.key(q)

def act.ag.none(t: A.Ag) -> Bool:
  match t:
    case A.AgNone{}:
      True{}
    case _:
      False{}

def act.ag.last(xs: List<&2, A.Ag>) -> Maybe<&2, A.Ag>:
  match xs:
    case Nil{}:
      None{}
    case h <> Nil{}:
      Some{h}
    case h <> t:
      act.ag.last(t)

def act.sym.arity(s: ActSym) -> Nat:
  match s:
    case ActSym{m, n, k, ms, ar, b, fs, c, cp}:
      ar

def act.cop.push(u: A.Ag, rest: A.Ag) -> A.Ag:
  match u:
    case A.AgNone{}:
      A.AgNone{}
    case u:
      asb.push(u, rest)

def act.cop.rec(m: Maybe<&2, A.Ag>, +q: A.AgQ, rest: A.Ag, +unf: Map<&2, ActCopy>) -> A.Ag:
  match m:
    case Some{A.AgDef{f, +es}}:
      act.cop.push(act.unfold.of(act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.cop.key(f, q))), es), rest)
    case Some{A.AgDefX{f, +es}}:
      act.cop.push(act.unfold.of(act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.cop.key(f, q))), es), rest)
    case _:
      A.AgNone{}

def act.cop.split(s: ActSplit, +q: A.AgQ, +unf: Map<&2, ActCopy>) -> A.Ag:
  match s:
    case ActSplit{vs, rest, True{}}:
      act.cop.rec(act.ag.last(vs), q, rest, unf)
    case _:
      A.AgNone{}

# q applied to es reduced as a copattern definition's field (AgNone when not)
def act.cop.at(+env: ActEnv, +q: A.AgQ, +es: A.Ag) -> A.Ag:
  match env:
    case ActEnv{mod, +tab, al, +unf}:
      act.cop.split(act.split(act.sym.arity(act.sym.got(Map.get(ActSym, act.sym0(), tab, act.key(q)))), es), q, unf)

# Every copy in a term inlined, through chains of copies of copies, and
# the lambda redexes substitution leaves reduced.  Each expansion or
# reduction spends one unit of fuel (a resolved definition too), and the
# fuel bounds the nesting: what is left when it runs out stays as it is
# and fails at the translation as an unknown copy.
def act.inline.go(+fuel: Nat, a: A.Ag, +at: Bool, +env: ActEnv) -> A.Ag:
  match fuel a:
    case 1n+p A.AgBeta{A.AgLam{i, x, d, b}, A.AgEApp{i2, v, rest}}:
      act.inline.go(p, asb.push(act.beta1(d, b, v), rest), False{}, env)
    case f A.AgBeta{g, A.AgENil{}}:
      act.inline.go(f, g, at, env)
    case 1n+p A.AgDef{+q, +es}:
      act.inline.go(p, act.etu.try(act.expand(act.sym(env, q), q, es), q, es, at, env), False{}, env)
    case 1n+p A.AgDefX{+q, es}:
      +es2 = act.inline.go(p, es, False{}, env)
      +r = act.cop.at(env, q, es2)
      Bool.pick(A.Ag, act.ag.none(r), A.AgDef{q, es2}, act.inline.go(p, r, False{}, env))
    case f A.AgVar{i, x, es}:
      A.AgVar{i, x, act.inline.go(f, es, False{}, env)}
    case f A.AgCon{q, o, es}:
      A.AgCon{q, o, act.inline.go(f, es, True{}, env)}
    case f A.AgLam{i, x, d, b}:
      A.AgLam{i, x, d, act.inline.go(f, b, at, env)}
    case f A.AgPi{i, x, a2, d, b}:
      A.AgPi{i, x, act.inline.go(f, a2, False{}, env), d, act.inline.go(f, b, False{}, env)}
    case f A.AgEl{s, t}:
      A.AgEl{s, act.inline.go(f, t, False{}, env)}
    case f A.AgDontCare{t}:
      A.AgDontCare{act.inline.go(f, t, False{}, env)}
    case f A.AgEApp{i, t, rest}:
      A.AgEApp{i, act.inline.go(f, t, at, env), act.inline.go(f, rest, at, env)}
    case f A.AgEProj{q, rest}:
      A.AgEProj{q, act.inline.go(f, rest, False{}, env)}
    case f a2:
      a2

def act.inline(+fuel: Nat, a: A.Ag, +env: ActEnv) -> A.Ag:
  act.inline.go(fuel, a, False{}, env)

# Applications ----------------------------------------------------------------

def act.bmode(m: ActM) -> T.BMode:
  match m:
    case AmErased{}:
      T.BmErased{}
    case AmCopy{}:
      T.BmCopy{}
    case AmTpl{}:
      T.BmTpl{}
    case _:
      T.BmLive{}

def act.m.of(m: T.BMode) -> ActM:
  match m:
    case T.BmErased{}:
      AmErased{}
    case T.BmCopy{}:
      AmCopy{}
    case T.BmTpl{}:
      AmTpl{}
    case T.BmLive{}:
      AmLive{}

def act.list.nolevel.put(lv: Bool, h: T.Bt, t: List<&2, T.Bt>) -> List<&2, T.Bt>:
  match lv:
    case True{}:
      t
    case False{}:
      h <> t

# the arguments of a spine as a list, the level markers left out
def act.list.nolevel(a: T.Bt) -> List<&2, T.Bt>:
  match a:
    case T.BtArgs{+h, t}:
      act.list.nolevel.put(act.is.marker(h), h, act.list.nolevel(t))
    case _:
      Nil{}

def act.app.list(f: T.Bt, xs: List<&2, T.Bt>) -> T.Bt:
  match xs:
    case Nil{}:
      f
    case h <> t:
      T.BtApp{f, T.tba.args(h <> t)}

# a variable applied: its level arguments dropped, and every argument
# marked as at a parameter whose mode is unknown (BtDead): the variable's
# type is not known here, and its Pi often erases the argument, so the
# quantity pass does not count these uses (Bend's check finds a real
# double use); the mark is doubled (BtDead of BtDead) as "unknown", which
# the template test takes as live: a template argument there must be closed
def act.deads(xs: List<&2, T.Bt>) -> List<&2, T.Bt>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      T.BtDead{T.BtDead{h}} <> act.deads(t)

def act.app.var(f: T.Bt, args: T.Bt) -> T.Bt:
  act.app.list(f, act.deads(act.list.nolevel(args)))

# The kept arguments of a call: an argument whose parameter is dropped is
# left out, one at an erased parameter is marked dead, one at a template
# is passed as such; past the type's Pis every argument is kept but a
# level.
def act.keep(args: T.Bt, ms: List<&2, ActM>) -> List<&2, T.Bt>:
  match args ms:
    case T.BtArgs{a, rest} AmDrop{} <> t:
      act.keep(rest, t)
    case T.BtArgs{a, rest} AmErased{} <> t:
      T.BtDead{a} <> act.keep(rest, t)
    case T.BtArgs{a, rest} AmTpl{} <> t:
      T.BtTplArg{a} <> act.keep(rest, t)
    case T.BtArgs{a, rest} m <> t:
      a <> act.keep(rest, t)
    case T.BtArgs{a, rest} Nil{}:
      act.list.nolevel(T.BtArgs{a, rest})
    case _ _:
      Nil{}

# a call's arguments split at the definition's arity
type ActTake is Data:
  ActTake{args: T.Bt, ms: List<&2, ActM>, rest: T.Bt, rms: List<&2, ActM>, ok: Bool}

def act.take.put(a: T.Bt, m: ActM, t: ActTake) -> ActTake:
  match t:
    case ActTake{args, ms, rest, rms, ok}:
      ActTake{T.BtArgs{a, args}, m <> ms, rest, rms, ok}

# the modes of the n parameters a call left out (live past the type's Pis)
def act.take.need(n: Nat, ms: List<&2, ActM>) -> List<&2, ActM>:
  match n ms:
    case 0n ms:
      Nil{}
    case 1n+p m <> t:
      m <> act.take.need(p, t)
    case 1n+p Nil{}:
      AmLive{} <> act.take.need(p, Nil{})

# the first n arguments and their modes, the rest of both; when the call
# has fewer than n, ok is False and rms holds the missing parameters' modes
def act.take(n: Nat, args: T.Bt, ms: List<&2, ActM>) -> ActTake:
  match n args ms:
    case 0n args ms:
      ActTake{T.BtANil{}, Nil{}, args, ms, True{}}
    case 1n+p T.BtArgs{a, rest} m <> t:
      act.take.put(a, m, act.take(p, rest, t))
    case 1n+p T.BtArgs{a, rest} Nil{}:
      act.take.put(a, AmLive{}, act.take(p, rest, Nil{}))
    case 1n+p T.BtANil{} ms:
      ActTake{T.BtANil{}, Nil{}, T.BtANil{}, act.take.need(1n+p, ms), False{}}
    case 1n+p args ms:
      ActTake{T.BtANil{}, Nil{}, T.BtANil{}, Nil{}, False{}}

# a header's templates come first (ToBend/Copy.bend), so a call's template
# arguments do too, in order, before the others
def act.is.tpl(t: T.Bt) -> Bool:
  match t:
    case T.BtTplArg{a}:
      True{}
    case _:
      False{}

def act.tpl.first(+xs: List<&2, T.Bt>) -> List<&2, T.Bt>:
  List.append(&2, T.Bt, List.filter(~T.Bt, ~(x => act.is.tpl(x)), xs), List.filter(~T.Bt, ~(x => Bool.not(act.is.tpl(x))), xs))

# A call with fewer arguments than the def's header takes is eta-expanded:
# a lambda for each missing kept parameter (a dropped one needs none).  The
# names are eta1, eta2, ...: a call's own arguments were translated before
# its lambdas exist, so they cannot mention them.
def act.eta.names(ms: List<&2, ActM>, +k: Nat) -> List<&2, List<&2, U32>>:
  match ms:
    case Nil{}:
      Nil{}
    case AmDrop{} <> t:
      act.eta.names(t, k)
    case m <> t:
      List.append(&2, U32, S.b("eta"), S.b(Nat.show(k))) <> act.eta.names(t, 1n+k)

def act.eta.vars(ns: List<&2, List<&2, U32>>) -> List<&2, T.Bt>:
  match ns:
    case Nil{}:
      Nil{}
    case n <> t:
      T.BtVar{n} <> act.eta.vars(t)

def act.eta(ns: List<&2, List<&2, U32>>, b: T.Bt) -> T.Bt:
  match ns:
    case Nil{}:
      b
    case n <> t:
      T.BtLam{T.BmLive{}, n, act.eta(t, b)}

# A call missing arguments is eta-expanded, each lambda in the mode of the
# callee's parameter it stands for (an erased one is -eta, its variable
# passed in a dead position), as the call's type has it.
def act.eta.ms(ms: List<&2, ActM>) -> List<&2, ActM>:
  match ms:
    case Nil{}:
      Nil{}
    case AmDrop{} <> t:
      act.eta.ms(t)
    case m <> t:
      m <> act.eta.ms(t)

def act.eta.by(ns: List<&2, List<&2, U32>>, ms: List<&2, ActM>, b: T.Bt) -> T.Bt:
  match ns ms:
    case n <> t AmErased{} <> mt:
      T.BtLam{T.BmErased{}, n, act.eta.by(t, mt, b)}
    case n <> t m <> mt:
      T.BtLam{T.BmLive{}, n, act.eta.by(t, mt, b)}
    case _ _:
      b

def act.eta.args(ns: List<&2, List<&2, U32>>, ms: List<&2, ActM>) -> List<&2, T.Bt>:
  match ns ms:
    case n <> t AmErased{} <> mt:
      T.BtDead{T.BtVar{n}} <> act.eta.args(t, mt)
    case n <> t AmTpl{} <> mt:
      T.BtTplArg{T.BtVar{n}} <> act.eta.args(t, mt)
    case n <> t m <> mt:
      T.BtVar{n} <> act.eta.args(t, mt)
    case _ _:
      Nil{}

# f(first arity kept arguments)(the other kept ones), as the Bend def's
# header takes the first group and its value the rest
def act.call.of(+f: List<&2, U32>, t: ActTake) -> T.Bt:
  match t:
    case ActTake{args, ms, rest, rms, True{}}:
      act.app.list(T.BtApp{T.BtVar{f}, T.tba.args(act.tpl.first(act.keep(args, ms)))}, act.keep(rest, rms))
    case ActTake{args, ms, rest, +rms, False{}}:
      +ns = act.eta.names(rms, 1n)
      +em = act.eta.ms(rms)
      act.eta.by(ns, em, T.BtApp{T.BtVar{f}, T.tba.args(act.tpl.first(List.append(&2, T.Bt, act.keep(args, ms), act.eta.args(ns, em))))})

def act.call(+f: List<&2, U32>, ms: List<&2, ActM>, +n: Nat, args: T.Bt) -> T.Bt:
  act.call.of(f, act.take(n, args, ms))

# ≡'s kept arguments are its type and its two sides; with fewer it is a
# relation, eta-expanded (eqx, eqy: its arguments were translated before
# these lambdas exist)
# (its arguments arrive marked dead: ≡ is type-valued, so all its
# parameters are erased; an equation's sides are dead anyway, and the
# rewrites read them as plain variables, so the marks come off)
def act.undead(t: T.Bt) -> T.Bt:
  match t:
    case T.BtDead{a}:
      a
    case t:
      t

# ≡'s level argument, a quantity once levels are, is no part of the equation
def act.eq.noq(on: Bool, xs: List<&2, T.Bt>) -> List<&2, T.Bt>:
  match on xs:
    case True{} h <> t:
      t
    case _ xs:
      xs

def act.eq(xs: List<&2, T.Bt>) -> T.Bt:
  match xs:
    case ty <> a <> b <> Nil{}:
      T.BtEq{act.undead(ty), act.undead(a), act.undead(b)}
    case ty <> a <> Nil{}:
      T.BtLam{T.BmLive{}, S.b("eqy"), T.BtEq{act.undead(ty), act.undead(a), T.BtVar{S.b("eqy")}}}
    case ty <> Nil{}:
      T.BtLam{T.BmLive{}, S.b("eqx"), T.BtLam{T.BmLive{}, S.b("eqy"), T.BtEq{act.undead(ty), T.BtVar{S.b("eqx")}, T.BtVar{S.b("eqy")}}}}
    case _:
      act.todo("≡ applied to other than its two sides")

# A datatype applied: Bend writes it with all its parameters (D<A, B>), so
# one applied to fewer is eta-expanded over the missing ones (Σ-syntax = Σ).
def act.tyapp.of(+ref: List<&2, U32>, t: ActTake) -> T.Bt:
  match t:
    case ActTake{args, ms, rest, rms, True{}}:
      T.BtTyApp{ref, T.tba.args(act.keep(args, ms))}
    case ActTake{args, ms, rest, rms, False{}}:
      +ns = act.eta.names(rms, 1n)
      act.eta(ns, T.BtTyApp{ref, T.tba.args(List.append(&2, T.Bt, act.keep(args, ms), act.eta.vars(ns)))})

def act.app.def.kind(k: A.AgKw, cp: Bool, +ref: List<&2, U32>, ms: List<&2, ActM>, +ar: Nat, args: T.Bt) -> T.Bt:
  match k cp:
    case _ True{}:
      act.todo("a module application's copy that was not inlined")
    case A.AkRecord{} False{}:
      act.tyapp.of(ref, act.take(ar, args, ms))
    case A.AkData{} False{}:
      act.tyapp.of(ref, act.take(ar, args, ms))
    case A.AkFunction{} False{}:
      act.call(ref, ms, ar, args)
    case A.AkPrimitive{} False{}:
      act.call(ref, ms, ar, args)
    case A.AkPostulate{} False{}:
      act.todo("a postulate")
    case _ False{}:
      T.BtTodo{List.append(&2, U32, S.b("a name the symbol table does not have: "), ref)}

def act.copy.is(c: Maybe<&2, ActCopy>) -> Bool:
  match c:
    case Some{x}:
      True{}
    case None{}:
      False{}

# a definition applied
def act.app.def(s: ActSym, +env: ActEnv, args: T.Bt) -> T.Bt:
  match s:
    case ActSym{m, n, k, ms, ar, AbLevel{}, fs, c, cp}:
      Bool.pick(T.Bt, act.quant.on(), act.q1(), act.level())
    case ActSym{m, n, k, ms, ar, AbQuant{}, fs, c, cp}:
      Bool.pick(T.Bt, act.quant.on(), T.BtVar{S.b("Quant")}, act.level())
    case ActSym{m, n, k, ms, ar, AbQone{}, fs, c, cp}:
      Bool.pick(T.Bt, act.quant.on(), act.q1(), act.level())
    case ActSym{m, n, k, ms, ar, AbQmin{}, fs, c, cp}:
      Bool.pick(T.Bt, act.quant.on(), act.qmin.args(args), act.level())
    case ActSym{m, n, k, ms, ar, AbNat{}, fs, c, cp}:
      T.BtVar{S.b("Nat")}
    case ActSym{m, n, k, ms, ar, AbBool{}, fs, c, cp}:
      T.BtVar{S.b("Bool")}
    case ActSym{m, n, k, ms, ar, AbUnit{}, fs, c, cp}:
      T.BtVar{S.b("Unit")}
    case ActSym{m, n, k, ms, ar, AbEq{}, fs, c, cp}:
      act.eq(act.eq.noq(act.quant.on(), act.keep(args, ms)))
    case ActSym{+m, +n, k, ms, ar, b, fs, c, cp}:
      act.app.def.kind(k, act.copy.is(cp), act.ref.of(act.is.here(env, m), env, m, n), ms, ar, args)

def act.first(xs: List<&2, T.Bt>) -> T.Bt:
  match xs:
    case h <> t:
      h
    case Nil{}:
      act.todo("suc with no argument")

# {==} for each of a constructor's equation fields (an indexed family's)
def act.refls(fs: List<&2, String>) -> List<&2, T.Bt>:
  match fs:
    case Nil{}:
      Nil{}
    case h <> t:
      T.BtRefl{} <> act.refls(t)

def act.app.con.kind(k: A.AgKw, +ref: List<&2, U32>, ms: List<&2, ActM>, fs: List<&2, String>, args: T.Bt) -> T.Bt:
  match k:
    case A.AkConstructor{}:
      T.BtCon{ref, T.tba.args(List.append(&2, T.Bt, act.keep(args, ms), act.refls(fs)))}
    case _:
      T.BtTodo{List.append(&2, U32, S.b("a constructor the symbol table does not have: "), ref)}

# a constructor applied (its own arguments only, as Agda writes them)
def act.app.con(s: ActSym, +env: ActEnv, args: T.Bt) -> T.Bt:
  match s:
    case ActSym{m, n, k, ms, ar, AbZero{}, fs, c, cp}:
      T.BtNat{S.b("0")}
    case ActSym{m, n, k, ms, ar, AbSuc{}, fs, c, cp}:
      T.BtSucc{act.first(act.keep(args, ms))}
    case ActSym{m, n, k, ms, ar, AbTrue{}, fs, c, cp}:
      T.BtCon{S.b("True"), T.BtANil{}}
    case ActSym{m, n, k, ms, ar, AbFalse{}, fs, c, cp}:
      T.BtCon{S.b("False"), T.BtANil{}}
    case ActSym{m, n, k, ms, ar, AbRefl{}, fs, c, cp}:
      T.BtRefl{}
    case ActSym{m, n, k, ms, ar, AbTt{}, fs, c, cp}:
      T.BtCon{S.b("Unit"), T.BtANil{}}
    case ActSym{+m, +n, k, ms, ar, b, fs, c, cp}:
      act.app.con.kind(k, act.ref.of(act.is.here(env, m), env, m, n), ms, fs, args)

# the context under a binder: its entry in front when it binds (abs), the
# same context when it does not (noabs)
def act.bind(dep: Bool, e: T.Bt, ctx: List<&2, T.Bt>) -> List<&2, T.Bt>:
  match dep:
    case True{}:
      e <> ctx
    case False{}:
      ctx

def act.lit(l: A.Ag) -> T.Bt:
  match l:
    case A.AgLNat{s}:
      T.BtNat{s}
    case A.AgLStr{s}:
      T.BtStr{s}
    case _:
      act.todo("a literal Bend has no counterpart for (Word64, Float, Char, a quoted name)")

# a Pi: a Level binder leaves only the codomain
def act.pi(lv: Bool, m: ActM, nm: List<&2, U32>, d: Bool, a: T.Bt, +b: T.Bt) -> T.Bt:
  Bool.pick(T.Bt, Bool.and(lv, Bool.not(act.quant.on())), b, T.BtPi{act.bmode(m), nm, d, a, b})

# The fold over terms (and elimination spines, which become argument
# spines).  ctx: the Bend term of each binder in scope, index 0 first.
def act.t(a: A.Ag, +ctx: List<&2, T.Bt>, +env: ActEnv) -> T.Bt:
  match a:
    case A.AgVar{+i, x, es}:
      act.app.var(act.ctx.at(i, ctx), act.t(es, ctx, env))
    case A.AgDef{+q, es}:
      act.app.def(act.sym(env, q), env, act.t(es, ctx, env))
    case A.AgDefX{+q, es}:
      act.app.def(act.sym(env, q), env, act.t(es, ctx, env))
    case A.AgCon{+q, o, es}:
      act.app.con(act.sym(env, q), env, act.t(es, ctx, env))
    case A.AgLam{i, +x, d, b}:
      +nm = act.fresh(x, ctx)
      T.BtLam{T.BmLive{}, nm, act.t(b, act.bind(d, T.BtVar{nm}, ctx), env)}
    case A.AgPi{i, +x, +a2, +d, b}:
      +lv = act.ty.level(a2)
      +nm = act.fresh(x, ctx)
      act.pi(lv, act.mode(i, a2, act.opaque.env(d, a2, env)), nm, d, act.t(a2, ctx, env), act.t(b, act.bind(d, Bool.pick(T.Bt, Bool.and(lv, Bool.not(act.quant.on())), act.level(), T.BtVar{nm}), ctx), env))
    case A.AgSort{s}:
      Bool.pick(T.Bt, act.quant.on(), act.sort(s, ctx, env), T.BtType{})
    case A.AgEl{s, t}:
      act.t(t, ctx, env)
    case A.AgLit{l}:
      act.lit(l)
    case A.AgLevel{l}:
      act.qt(l, ctx, env)
    case A.AgDontCare{t}:
      act.t(t, ctx, env)
    case A.AgStored{t}:
      act.todo("a stored term (agda-export could not restore a projection's parameters)")
    case A.AgMeta{es}:
      act.todo("an unsolved metavariable")
    case A.AgRaw{c, x}:
      act.todo("a cubical or unknown form")
    case A.AgBeta{f, es}:
      act.todo("a lambda applied that the inlining did not reduce")
    case A.AgENil{}:
      T.BtANil{}
    case A.AgEApp{i, +t, rest}:
      T.BtArgs{act.arg(Bool.and(Bool.not(act.quant.on()), act.is.level(t, ctx, env)), act.t(t, ctx, env)), act.t(rest, ctx, env)}
    case A.AgEProj{q, rest}:
      T.BtArgs{act.todo("a projection elimination (stored form)"), act.t(rest, ctx, env)}
    case A.AgERaw{x, rest}:
      T.BtArgs{act.todo("a cubical elimination"), act.t(rest, ctx, env)}
    case _:
      act.todo("not a term")

# Symbols of a module's definitions ----------------------------------------------

def act.qs(q: A.AgQ) -> List<&2, U32>:
  match q:
    case A.AgQ{s, w, k}:
      s

# the keys of a name list, in order
def act.keys(a: A.Ag) -> List<&2, String>:
  match a:
    case A.AgQs{i, q, rest}:
      act.key(q) <> act.keys(rest)
    case _:
      Nil{}

def act.vars.len(a: A.Ag) -> Nat:
  match a:
    case A.AgVars{i, x, rest}:
      1n+act.vars.len(rest)
    case _:
      0n

# a copy's leaf: done (vars ...) TERM
def act.copy.of(tree: A.Ag) -> Maybe<&2, ActCopy>:
  match tree:
    case A.AgDone{xs, t}:
      Some{ActCopy{act.vars.len(xs), t}}
    case _:
      None{}

# the patterns a clause matches before its first projection pattern
def act.pats.len(ps: A.Ag) -> Nat:
  match ps:
    case A.AgPArg{i, x, A.AgPProj{q}, rest}:
      0n
    case A.AgPArg{i, x, p, rest}:
      1n+act.pats.len(rest)
    case _:
      0n

def act.cls.arity(cls: A.Ag) -> Nat:
  match cls:
    case A.AgCl{tel, ps, body, ty, ca, rest}:
      act.pats.len(ps)
    case _:
      0n

def act.flag(+k: A.AgKw, fl: List<&2, A.AgKw>) -> Bool:
  match fl:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(A.aas.kw.eq(h, k), act.flag(k, t))

# A constructor's own arguments are its fields, values in Bend (a
# record's Carrier : Set c is a field like any other): live, a Level
# still dropped.
def act.ms.live(ms: List<&2, ActM>) -> List<&2, ActM>:
  match ms:
    case Nil{}:
      Nil{}
    case AmDrop{} <> t:
      AmDrop{} <> act.ms.live(t)
    case m <> t:
      AmLive{} <> act.ms.live(t)

def act.drop.n(n: Nat, ms: List<&2, ActM>) -> List<&2, ActM>:
  match n ms:
    case 1n+p m <> t:
      act.drop.n(p, t)
    case _ ms:
      ms

def act.sym.copy(c: Maybe<&2, ActCopy>, +mo: List<&2, U32>, +nm: List<&2, U32>, ms: List<&2, ActM>, b: ActB) -> ActSym:
  match c:
    case Some{ActCopy{+n, t}}:
      ActSym{mo, nm, A.AkFunction{}, ms, n, b, Nil{}, Nil{}, Some{ActCopy{n, t}}}
    case None{}:
      ActSym{mo, nm, A.AkFunction{}, ms, 0n, b, Nil{}, Nil{}, None{}}

# A function's entry: a record field's projection takes the record's
# parameters and the record (its index); a copy, its leaf's variables;
# any other function, a projection-like one included (Agda's index there
# only says which argument determines the ones before it), what its first
# clause matches.
# Lifting: a plain function takes every Pi of its type as a parameter, not
# only those its clauses bind (`step-≈-⟩ = forward …` binds none of its
# points; `flip f = λ y x → …` binds f).  Its body is then applied to the
# extra parameters (act.lift.app) and a call fills them all (a partial one
# is eta-expanded), so the quantity pass may erase a lifted parameter its
# body never uses, as it does a header's: a chain's points are then dead
# where they are passed.  Not lifted: projections and projection-like
# functions, copies, copattern definitions, type-valued definitions, and a
# definition without clauses.
def act.pats.proj(ps: A.Ag) -> Bool:
  match ps:
    case A.AgPArg{i, x, A.AgPProj{q}, rest}:
      True{}
    case A.AgPArg{i, x, p, rest}:
      act.pats.proj(rest)
    case _:
      False{}

def act.cls.liftable(cls: A.Ag) -> Bool:
  match cls:
    case A.AgCl{tel, ps, body, ty, ca, rest}:
      Bool.not(act.pats.proj(ps))
    case _:
      False{}

def act.lift.ar(+n: Nat, +m: Nat, ok: Bool) -> Nat:
  match ok:
    case True{}:
      Bool.pick(Nat, Nat.is_lt(n, m), m, n)
    case False{}:
      n

def act.sym.fun(cp: Bool, srt: Bool, tl: Bool, p: A.AgProj, +cls: A.Ag, tree: A.Ag, +mo: List<&2, U32>, +nm: List<&2, U32>, +ms: List<&2, ActM>, b: ActB) -> ActSym:
  match cp p:
    case True{} p:
      act.sym.copy(act.copy.of(tree), mo, nm, ms, b)
    case False{} A.AgPrOf{Some{r}, o, ix}:
      ActSym{mo, nm, A.AkFunction{}, ms, ix, b, act.opaque.mark(srt), Nil{}, None{}}
    case False{} A.AgPrOf{None{}, o, ix}:
      ActSym{mo, nm, A.AkFunction{}, ms, act.cls.arity(cls), b, Nil{}, Nil{}, None{}}
    case False{} A.AgPrNone{}:
      ActSym{mo, nm, A.AkFunction{}, ms, act.lift.ar(act.cls.arity(cls), List.length(&2, ActM, ms), Bool.and(Bool.not(tl), act.cls.liftable(cls))), b, Nil{}, Nil{}, None{}}

def act.con.name.of(un: Bool, +nm: List<&2, U32>) -> List<&2, U32>:
  match un:
    case True{}:
      List.take(&2, U32, nm, Nat.sub(S.len(nm), 12n))
    case False{}:
      nm

# a record's unnamed constructor is R.constructor: its Bend name is R's
def act.con.name(+nm: List<&2, U32>) -> List<&2, U32>:
  act.con.name.of(S.suffix(nm, S.b(".constructor")), nm)

# A name's local part: its printed name without the module's, each part
# made a Bend identifier (ToBend/Names.bend), joined by dots.
def act.parts(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> Nil{}:
      S.b(N.tnm.part(S.str(h)))
    case h <> t:
      List.append(&2, U32, S.b(N.tnm.part(S.str(h))), 46 <> act.parts(t))

def act.local.of(here: Bool, +top: List<&2, U32>, +qs: List<&2, U32>) -> List<&2, U32>:
  match here:
    case True{}:
      act.parts(S.split(List.drop(&2, U32, qs, 1n+S.len(top)), 46))
    case False{}:
      act.parts(S.split(qs, 46))

def act.local(+top: List<&2, U32>, +qs: List<&2, U32>) -> List<&2, U32>:
  act.local.of(S.prefix(qs, List.append(&2, U32, top, 46 <> Nil{})), top, qs)

# A type-valued function whose case tree is one leaf headed by a variable
# (a module parameter: `_∙_ IdempotentOn x = (x ∙ x) ≈ x` over `_≈_`) uses
# its parameters live in its body, which Bend checks as code; inlined where
# it is used, its body sits in a type, a dead position.  So its symbol is
# made a copy (inlined, not emitted).
def act.var.head(t: A.Ag) -> Bool:
  match t:
    case A.AgVar{i, x, es}:
      True{}
    case _:
      False{}

def act.inl.d(srt: Bool, d: A.AgD) -> Bool:
  match srt d:
    case True{} A.AgDFun{A.AgPrNone{}, r, w, e, t, mu, cls, A.AgDone{xs, body}}:
      act.var.head(body)
    case _ _:
      False{}

def act.tel.len(t: A.Ag) -> Nat:
  match t:
    case A.AgTel{x, i, ty, rest}:
      1n+act.tel.len(rest)
    case _:
      0n

# A data type or record made by module application is the original applied
# to the module's arguments, which its clause says (agda-export writes it
# explicitly from format 2.1): inlined where used, as a function copy is.
# The clause's variables are its telescope's, in order.
def act.tel.n(t: A.Ag) -> Nat:
  match t:
    case A.AgStored{x}:
      act.tel.len(x)
    case t:
      act.tel.len(t)

def act.copy.cl(cp: Bool, cl: A.Ag) -> Maybe<&2, ActCopy>:
  match cp cl:
    case True{} A.AgCl{tel, ps, body, ty, ca, rest}:
      Some{ActCopy{act.tel.n(tel), body}}
    case _ _:
      None{}

# a constructor made by module application: the original it copies (terms
# and patterns name the copy; Bend has only the original)
def act.con.src.d(cp: Bool, d: A.AgD) -> Maybe<&2, A.AgQ>:
  match cp d:
    case True{} A.AgDCon{dq, p, ar, ck, src}:
      Some{src}
    case _ _:
      None{}

def act.con.src(d: A.AgDecl) -> Maybe<&2, A.AgQ>:
  match d:
    case A.AgDecl{q, qn, md, f, l, l0, l1, k, m, fl, lang, ty, dd}:
      act.con.src.d(act.flag(A.AkCopy{}, fl), dd)

# Indexed families: Bend has none, so an index is one more (erased) type
# parameter and each constructor carries an equation per index, {i == t},
# t the index its Agda type ends at (Reflects A true: {b == True{} :
# Bool}).  A constructor applied passes {==} for each; a pattern binds them.
# A type after its Pis.
def act.target(t: A.Ag) -> A.Ag:
  match t:
    case A.AgEl{s, A.AgPi{i, x, a, d, b}}:
      act.target(b)
    case t:
      t

def act.es.len(es: A.Ag) -> Nat:
  match es:
    case A.AgEApp{i, t, rest}:
      1n+act.es.len(rest)
    case _:
      0n

# the arguments of a spine after its first n
def act.es.after(n: Nat, es: A.Ag) -> A.Ag:
  match n es:
    case 1n+p A.AgEApp{i, t, rest}:
      act.es.after(p, rest)
    case _ es:
      es

def act.ixs.target(+pars: Nat, t: A.Ag) -> Nat:
  match t:
    case A.AgEl{s, A.AgDef{q, es}}:
      act.es.len(act.es.after(pars, es))
    case _:
      0n

# a constructor's index count: its type's target's arguments after the
# data type's parameters (0 for any other definition)
def act.ixs.of(d: A.AgD, t: A.Ag) -> Nat:
  match d:
    case A.AgDCon{dq, +pars, ar, ck, src}:
      act.ixs.target(pars, act.target(t))
    case _:
      0n

# a constructor's equation fields, by name (only their number matters)
def act.ix.names(n: Nat) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      "ix_eq" <> act.ix.names(p)

def act.sym.d(d: A.AgD, cp: Bool, srt: Bool, tl: Bool, +mo: List<&2, U32>, +nm: List<&2, U32>, +ms: List<&2, ActM>, b: ActB, ix: Nat) -> ActSym:
  match d:
    case A.AgDFun{p, r, w, e, t, mu, cls, tree}:
      act.sym.fun(cp, srt, tl, p, cls, tree, mo, nm, ms, b)
    case A.AgDRec{+pars, c, named, ind, fs, tel, eta, pm, rcl}:
      ActSym{mo, nm, A.AkRecord{}, ms, pars, b, act.keys(fs), act.con.name(act.local(mo, act.qs(c))), act.copy.cl(cp, rcl)}
    case A.AgDData{+pars, +ixs, cs, s, dcl}:
      ActSym{mo, nm, A.AkData{}, ms, Nat.add(pars, ixs), b, act.keys(cs), Nil{}, act.copy.cl(cp, dcl)}
    case A.AgDCon{dq, +pars, ar, ck, src}:
      ActSym{mo, act.con.name(nm), A.AkConstructor{}, act.ms.live(act.drop.n(pars, ms)), ar, b, act.ix.names(ix), Nil{}, None{}}
    case A.AgDPost{}:
      ActSym{mo, nm, A.AkPostulate{}, ms, 0n, b, Nil{}, Nil{}, None{}}
    case A.AgDPrim{n, cls, tree}:
      ActSym{mo, nm, A.AkPrimitive{}, ms, act.cls.arity(cls), b, Nil{}, Nil{}, None{}}
    case A.AgDOther{x}:
      ActSym{mo, nm, A.AkWord{}, ms, 0n, b, Nil{}, Nil{}, None{}}

def act.role.pick(b: ActB, lv: Bool) -> ActB:
  match b lv:
    case AbNone{} True{}:
      AbLevel{}
    case b _:
      b

def act.role(+qs: List<&2, U32>, lv: Bool) -> ActB:
  act.role.pick(act.builtin(qs), lv)

# a module's file under src/: its name's parts, each a plain name
def act.path.parts(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      S.b(".bend")
    case h <> Nil{}:
      List.append(&2, U32, S.b(N.tnm.path(S.str(h))), S.b(".bend"))
    case h <> t:
      List.append(&2, U32, S.b(N.tnm.path(S.str(h))), 47 <> act.path.parts(t))

def act.path(+m: List<&2, U32>) -> List<&2, U32>:
  act.path.parts(S.split(m, 46))

# Headers ------------------------------------------------------------------------

# A def's parameters from the first n Pis of its type, the rest of the type
# as its result, the context they leave, and every parameter's entry in
# order (ents: a non-dependent Pi's parameter binds no variable of the
# context, but a clause's pattern still stands for it; a dropped one is
# the level marker); ok is False when the type has fewer Pis than n.
type ActPs is Data:
  ActPs{ps: List<&2, T.BParam>, ret: T.Bt, ctx: List<&2, T.Bt>, ents: List<&2, T.Bt>, ok: Bool}

def act.entry(m: ActM, +nm: List<&2, U32>) -> T.Bt:
  match m:
    case AmDrop{}:
      act.level()
    case _:
      T.BtVar{nm}

def act.params.put(m: ActM, +nm: List<&2, U32>, ty: T.Bt, r: ActPs) -> ActPs:
  match m r:
    case AmDrop{} ActPs{ps, ret, ctx, es, ok}:
      ActPs{ps, ret, ctx, act.level() <> es, ok}
    case m ActPs{ps, ret, ctx, es, ok}:
      ActPs{T.BParam{act.bmode(m), nm, ty} <> ps, ret, ctx, T.BtVar{nm} <> es, ok}

def act.unfold(+env: ActEnv, q: A.AgQ, +es: A.Ag) -> A.Ag:
  match env:
    case ActEnv{mod, tab, al, unf}:
      act.unfold.of(act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.key(q))), es)

# whether a TYPE ends in a sort once the type-valued definitions it ends in
# are opened (`_≉_ : Rel A ℓ` is a relation: Rel opens to A -> A -> Set)
def act.ends.sort.u(fuel: Nat, t: A.Ag, +unf: Map<&2, ActCopy>) -> Bool:
  match fuel t:
    case f A.AgEl{s, x}:
      act.ends.sort.u(f, x, unf)
    case f A.AgPi{i, x, a, d, b}:
      act.ends.sort.u(f, b, unf)
    case f A.AgSort{s}:
      True{}
    case 1n+f A.AgDef{+q, +es}:
      act.ends.sort.u(f, act.unfold.of(act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.key(q))), es), unf)
    case _ _:
      False{}

# the modes of every Pi of a TYPE, the Pis of the type-valued definitions it
# ends in included (sym : Symmetric _≈_ takes {x y} after the record: both
# erased, as Symmetric opens to them), so a call keeps those arguments dead
def act.modes.u(fuel: Nat, t: A.Ag, +tylevel: Bool, +tab: Map<&2, ActSym>, +unf: Map<&2, ActCopy>) -> List<&2, ActM>:
  match fuel t:
    case f A.AgEl{s, x}:
      act.modes.u(f, x, tylevel, tab, unf)
    case f A.AgPi{i, x, +a, +d, b}:
      act.mode(i, a, Bool.or(tylevel, act.opaque.dep(d, a, tab, unf))) <> act.modes.u(f, b, tylevel, tab, unf)
    case f A.AgStored{x}:
      act.modes.u(f, x, tylevel, tab, unf)
    case 1n+f A.AgDef{+q, +es}:
      act.modes.u(f, act.unfold.of(act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.key(q))), es), tylevel, tab, unf)
    case _ _:
      Nil{}

# Whether a definition is type-valued (every Pi erased): its type ends in a
# sort once the type-valued definitions it ends in are opened (`_⊓_ : PT A B
# → PT A B → PT A B` is a predicate transformer: its P and Q are used only
# in dead places, and live they would make X a copy), but a record field's
# projection by its own type only, as the field's Bend type has it
# (`_≈_ : Rel (A ⇒ B) e` opens to two morphisms the field takes live;
# erased, a call's arguments were dead, so Copy left CommutativeSquare's
# f g h i erased where the body uses them live, and Bend refused it).
def act.tylevel(d: A.AgD, +ty: A.Ag, +unf: Map<&2, ActCopy>) -> Bool:
  match d:
    case A.AgDFun{A.AgPrOf{Some{r}, o, ix}, rs, w, e, t, mu, cls, tree}:
      act.ends.sort(ty)
    case _:
      act.ends.sort.u(8n, ty, unf)

# A definition's entry, given its module and its (unique) Bend name.
def act.sym.of(+mo: List<&2, U32>, +nm: List<&2, U32>, d: A.AgDecl, +tab: Map<&2, ActSym>, +unf: Map<&2, ActCopy>) -> ActSym:
  match d:
    case A.AgDecl{q, qn, md, f, l, l0, l1, k, m, +fl, lang, +ty, +dd}:
      act.sym.d(dd, Bool.or(act.flag(A.AkCopy{}, fl), act.inl.d(act.ends.sort(ty), dd)), act.ends.sort(ty), act.tylevel(dd, ty, unf), mo, nm, act.modes.u(8n, ty, act.tylevel(dd, ty, unf), tab, unf), act.role(act.qs(q), act.ends.level(ty)), act.ixs.of(dd, ty))

# seen: the names this header has given so far (a non-dependent Pi's
# parameter is in no context, but its name is taken)
def act.params.go(fuel: Nat, n: Nat, t: A.Ag, ms: List<&2, ActM>, +ctx: List<&2, T.Bt>, +seen: List<&2, List<&2, U32>>, +env: ActEnv) -> ActPs:
  match fuel n t ms:
    case f 0n t ms:
      ActPs{Nil{}, act.t(t, ctx, env), ctx, Nil{}, True{}}
    case f 1n+p A.AgEl{s, A.AgPi{i, +x, a, d, b}} +m <> mt:
      +nm = act.fresh.in(x, ctx, seen)
      act.params.put(m, nm, act.t(a, ctx, env), act.params.go(f, p, b, mt, act.bind(d, act.entry(m, nm), ctx), nm <> seen, env))
    case f 1n+p A.AgEl{s, A.AgPi{i, +x, +a, +d, b}} Nil{}:
      +nm = act.fresh.in(x, ctx, seen)
      +m = act.mode(i, a, act.opaque.env(d, a, env))
      act.params.put(m, nm, act.t(a, ctx, env), act.params.go(f, p, b, Nil{}, act.bind(d, act.entry(m, nm), ctx), nm <> seen, env))
    case 1n+g 1n+p A.AgEl{s, A.AgDef{+q, +es}} ms:
      act.params.go(g, 1n+p, A.AgEl{s, act.inline(1024n, act.unfold(env, q, es), env)}, ms, ctx, seen, env)
    case f 1n+p t ms:
      ActPs{Nil{}, act.todo("a type with fewer Pis than its clauses take parameters"), ctx, Nil{}, False{}}

# The fuel bounds the unfoldings a header may take (each a type-valued
# definition opened to reach the Pis the clauses take).
def act.params(fuel: Nat, n: Nat, t: A.Ag, ms: List<&2, ActM>, +ctx: List<&2, T.Bt>, +env: ActEnv) -> ActPs:
  act.params.go(fuel, n, t, ms, ctx, Nil{}, env)

# Clauses ------------------------------------------------------------------------

# a pattern variable's binding: its position in the clause's telescope and
# the Bend term it stands for
type ActBind is Data:
  ActBind{pos: Nat, t: T.Bt}

# a translated pattern (or pattern spine), its bindings, and whether the
# clause is left out: it holds an absurd pattern, or a cubical one (the
# clauses --cubical-compatible generates beside the user's, FORMAT.md)
type ActPat is Data:
  ActPat{p: T.Bt, bs: List<&2, ActBind>, absurd: Bool}

def act.tel.hints(t: A.Ag) -> List<&2, List<&2, U32>>:
  match t:
    case A.AgTel{x, i, ty, rest}:
      act.hint(x) <> act.tel.hints(rest)
    case _:
      Nil{}

def act.count(+x: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Nat:
  match xs:
    case Nil{}:
      0n
    case h <> t:
      Nat.add(Bool.pick(Nat, S.eq(h, x), 1n, 0n), act.count(x, t))

def act.nth.b(n: Nat, xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match n xs:
    case 0n h <> t:
      h
    case 1n+p h <> t:
      act.nth.b(p, t)
    case _ Nil{}:
      S.b("x")

def act.pv.of(plain: Bool, +h: List<&2, U32>, +pos: Nat) -> List<&2, U32>:
  match plain:
    case True{}:
      h
    case False{}:
      List.append(&2, U32, h, 95 <> S.b(Nat.show(pos)))

def act.pv.name.of(+h: List<&2, U32>, +pos: Nat, +hints: List<&2, List<&2, U32>>, +pnames: List<&2, List<&2, U32>>) -> List<&2, U32>:
  act.pv.of(Bool.and(Bool.and(Nat.is_eq(act.count(h, hints), 1n), Bool.not(act.used(h, pnames))), Bool.not(S.eq(h, S.b("x")))), h, pos)

# A pattern variable's name: its telescope hint when that is unique among
# the telescope's hints and no parameter's name, else the hint and its
# position (x_3).
def act.pv.name(+pos: Nat, +hints: List<&2, List<&2, U32>>, +pnames: List<&2, List<&2, U32>>) -> List<&2, U32>:
  act.pv.name.of(act.nth.b(pos, hints), pos, hints, pnames)

def act.pat.cat(a: ActPat, b: ActPat) -> ActPat:
  match a b:
    case ActPat{p, bs, ab} ActPat{q, cs, ac}:
      ActPat{T.BtArgs{p, q}, List.append(&2, ActBind, bs, cs), Bool.or(ab, ac)}

def act.pat.first(a: T.Bt) -> T.Bt:
  match a:
    case T.BtArgs{h, t}:
      h
    case _:
      act.todo("suc with no pattern")

# an equation field's pattern: a placeholder the case names (act.eq.deep)
def act.wilds(fs: List<&2, String>) -> List<&2, T.Bt>:
  match fs:
    case Nil{}:
      Nil{}
    case h <> t:
      T.BtPv{T.BmLive{}, S.b("ix_eq")} <> act.wilds(t)

# a spine with more patterns after it: one for each equation field
def act.spine.wild(sp: T.Bt, fs: List<&2, String>) -> T.Bt:
  match sp:
    case T.BtArgs{a, rest}:
      T.BtArgs{a, act.spine.wild(rest, fs)}
    case _:
      T.tba.args(act.wilds(fs))

def act.pat.con.kind(k: A.AgKw, +ref: List<&2, U32>, fs: List<&2, String>, sub: T.Bt) -> T.Bt:
  match k:
    case A.AkConstructor{}:
      T.BtCon{ref, act.spine.wild(sub, fs)}
    case _:
      T.BtTodo{List.append(&2, U32, S.b("a constructor pattern the symbol table does not have: "), ref)}

def act.pat.con.p(s: ActSym, +env: ActEnv, sub: T.Bt) -> T.Bt:
  match s:
    case ActSym{m, n, k, ms, ar, AbZero{}, fs, c, cp}:
      T.BtNat{S.b("0")}
    case ActSym{m, n, k, ms, ar, AbSuc{}, fs, c, cp}:
      T.BtSucc{act.pat.first(sub)}
    case ActSym{m, n, k, ms, ar, AbTrue{}, fs, c, cp}:
      T.BtCon{S.b("True"), T.BtANil{}}
    case ActSym{m, n, k, ms, ar, AbFalse{}, fs, c, cp}:
      T.BtCon{S.b("False"), T.BtANil{}}
    case ActSym{m, n, k, ms, ar, AbTt{}, fs, c, cp}:
      T.BtCon{S.b("Unit"), T.BtANil{}}
    case ActSym{m, n, k, ms, ar, AbRefl{}, fs, c, cp}:
      act.todo("a match on refl (an equation's rewrite is not translated yet)")
    case ActSym{+m, +n, k, ms, ar, b, fs, c, cp}:
      act.pat.con.kind(k, act.ref.of(act.is.here(env, m), env, m, n), fs, sub)

def act.pat.con(s: ActSym, +env: ActEnv, sub: ActPat) -> ActPat:
  match sub:
    case ActPat{p, bs, ab}:
      ActPat{act.pat.con.p(s, env, p), bs, ab}

# A pattern, or a spine of them (a constructor's own arguments), with the
# bindings of its variables.  n is the telescope's length (a variable's
# index counts from its end).
def act.pat(p: A.Ag, +n: Nat, +hints: List<&2, List<&2, U32>>, +pnames: List<&2, List<&2, U32>>, +env: ActEnv) -> ActPat:
  match p:
    case A.AgPArg{i, x, q, rest}:
      act.pat.cat(act.pat(q, n, hints, pnames, env), act.pat(rest, n, hints, pnames, env))
    case A.AgPEnd{}:
      ActPat{T.BtANil{}, Nil{}, False{}}
    case A.AgPVar{x, +ix, o}:
      +pos = Nat.sub(Nat.sub(n, 1n), ix)
      +nm = act.pv.name(pos, hints, pnames)
      ActPat{T.BtPv{T.BmLive{}, nm}, [ActBind{pos, T.BtVar{nm}}], A.aas.kw.eq(o, A.AkAbsurd{})}
    case A.AgPDot{t}:
      ActPat{T.BtWild{}, Nil{}, False{}}
    case A.AgPCon{+q, r, ps}:
      act.pat.con(act.sym(env, q), env, act.pat(ps, n, hints, pnames, env))
    case A.AgPLit{A.AgLNat{s}}:
      ActPat{T.BtNat{s}, Nil{}, False{}}
    case A.AgRaw{c, x}:
      ActPat{T.BtWild{}, Nil{}, True{}}
    case _:
      ActPat{act.todo("a pattern not translated (a literal other than a Nat, a copattern)"), Nil{}, False{}}

def act.top.var(p: A.Ag, +n: Nat, ent: T.Bt) -> List<&2, ActBind>:
  match p:
    case A.AgPVar{x, +ix, o}:
      [ActBind{Nat.sub(Nat.sub(n, 1n), ix), ent}]
    case _:
      Nil{}

def act.pat.add(bs: List<&2, ActBind>, a: ActPat) -> ActPat:
  match a:
    case ActPat{p, cs, ab}:
      ActPat{p, List.append(&2, ActBind, bs, cs), ab}

# A clause's patterns: at a parameter the match splits (scr), the pattern;
# at another, its variable stands for the parameter itself.  The result
# holds the patterns of the split parameters only.
def act.top(ps: A.Ag, scr: List<&2, Bool>, ents: List<&2, T.Bt>, +n: Nat, +hints: List<&2, List<&2, U32>>, +pnames: List<&2, List<&2, U32>>, +env: ActEnv) -> ActPat:
  match ps scr ents:
    case A.AgPArg{i, x, q, rest} True{} <> st e <> et:
      act.pat.cat(act.pat(q, n, hints, pnames, env), act.top(rest, st, et, n, hints, pnames, env))
    case A.AgPArg{i, x, q, rest} False{} <> st e <> et:
      act.pat.add(act.top.var(q, n, e), act.top(rest, st, et, n, hints, pnames, env))
    case _ _ _:
      ActPat{T.BtANil{}, Nil{}, False{}}

def act.bind.find(+pos: Nat, bs: List<&2, ActBind>) -> T.Bt:
  match bs:
    case Nil{}:
      act.todo("a pattern variable the clause does not bind (a dot or forced pattern)")
    case ActBind{+p, t} <> rest:
      Bool.pick(T.Bt, Nat.is_eq(p, pos), t, act.bind.find(pos, rest))

# the body's context from the bindings: telescope position n-1 first
def act.ctx.of(k: Nat, +bs: List<&2, ActBind>) -> List<&2, T.Bt>:
  match k:
    case 0n:
      Nil{}
    case 1n+(+p):
      act.bind.find(p, bs) <> act.ctx.of(p, bs)

# Equations: Bend cannot match on an equation, so a clause matching refl
# (`sym refl = refl`, `cong f refl = refl`) is translated as a rewrite of
# the goal before its body.  Agda's match makes one side of the equation a
# dot pattern (that variable is gone from the clause); with e : {a == b},
# Bend's `%e : P` needs the goal to be P with b at the holes and leaves P
# with a there, so when the dotted variable d is b the rewrite is
# `%e : G[d := _]`, and when it is a, the reversed equation first
# (`e2 = Equal.sym(T, a, b, e)`, then `%e2 : G[d := _]`).  G is the case's
# goal: the def's result type with the case's patterns put for the
# parameters it splits.  A clause may hold several; each rewrites the goal
# the one before left.
type ActRw is Data:
  ActRw{rws: List<&2, T.Bt>, dots: List<&2, List<&2, U32>>}

def act.var.name(t: T.Bt) -> List<&2, U32>:
  match t:
    case T.BtVar{x}:
      x
    case _:
      S.b("r")

def act.rw.add(e: T.Bt, r: ActRw) -> ActRw:
  match r:
    case ActRw{rs, ds}:
      ActRw{e <> rs, ds}

def act.rw.dot(e: T.Bt, r: ActRw) -> ActRw:
  match r:
    case ActRw{rs, ds}:
      ActRw{rs, act.var.name(e) <> ds}

def act.is.refl(s: ActSym) -> Bool:
  match s:
    case ActSym{m, n, k, ms, ar, AbRefl{}, fs, c, cp}:
      True{}
    case _:
      False{}

def act.rw.refl(hit: Bool, e: T.Bt, r: ActRw) -> ActRw:
  match hit:
    case True{}:
      act.rw.add(e, r)
    case False{}:
      r

def act.rw.pat(p: A.Ag, +e: T.Bt, +env: ActEnv, r: ActRw) -> ActRw:
  match p:
    case A.AgPCon{+q, rec, ps}:
      act.rw.refl(act.is.refl(act.sym(env, q)), e, r)
    case A.AgPDot{t}:
      act.rw.dot(e, r)
    case _:
      r

# a clause's top-level refl and dot patterns, by parameter
def act.rw.scan(ps: A.Ag, ents: List<&2, T.Bt>, +env: ActEnv) -> ActRw:
  match ps ents:
    case A.AgPArg{i, x, p, rest} +e <> et:
      act.rw.pat(p, e, env, act.rw.scan(rest, et, env))
    case _ _:
      ActRw{Nil{}, Nil{}}

# a pattern as the term it stands for
def act.pat.term(p: T.Bt) -> T.Bt:
  match p:
    case T.BtPv{m, x}:
      T.BtVar{x}
    case T.BtCon{c, a}:
      T.BtCon{c, act.pat.term(a)}
    case T.BtSucc{a}:
      T.BtSucc{act.pat.term(a)}
    case T.BtArgs{a, rest}:
      T.BtArgs{act.pat.term(a), act.pat.term(rest)}
    case p:
      p

def act.goal.put(t: T.Bt, +x: List<&2, U32>, +p: T.Bt, wild: Bool) -> T.Bt:
  match wild:
    case True{}:
      t
    case False{}:
      T.tba.subst(t, x, act.pat.term(p))

def act.wild(p: T.Bt) -> Bool:
  match p:
    case T.BtWild{}:
      True{}
    case _:
      False{}

# the def's result type with each split parameter replaced by the case's
# pattern for it (a catch-all leaves it as it is)
def act.goal(xs: List<&2, T.Bt>, ps: T.Bt, t: T.Bt) -> T.Bt:
  match xs ps:
    case x <> xt T.BtArgs{+p, rest}:
      act.goal(xt, rest, act.goal.put(t, act.var.name(x), p, act.wild(p)))
    case _ _:
      t

def act.param.ty(ps: List<&2, T.BParam>, +x: List<&2, U32>) -> T.Bt:
  match ps:
    case Nil{}:
      T.BtWild{}
    case T.BParam{m, +n, ty} <> t:
      Bool.pick(T.Bt, S.eq(n, x), ty, act.param.ty(t, x))

def act.dotted(t: T.Bt, +ds: List<&2, List<&2, U32>>) -> Bool:
  match t:
    case T.BtVar{x}:
      act.used(x, ds)
    case _:
      False{}

# One rewrite's plan: 0 none (no side of e is a dotted variable), 1 with
# e, 2 with e reversed (sym: the Equal.sym call, named e2); the motive P
# and the goal the rewrite leaves.
type ActStep is Data:
  ActStep{k: Nat, p: T.Bt, goal: T.Bt, sym: T.Bt, e2: List<&2, U32>}

# The side to mark in the goal: the dotted variable when the goal mentions
# it (the goal then says what the body proves of the other side), else
# the other side (the body's hypotheses mention the dotted one: `trans
# refl eq = eq` proves i ≡ k from eq : j ≡ k, so i becomes j).  Marking b
# rewrites with e; marking a, with e reversed.
def act.mark.b(rb: Bool, ra: Bool, inb: Bool, ina: Bool) -> Nat:
  match rb ra inb ina:
    case True{} _ True{} _:
      1n
    case True{} _ False{} True{}:
      2n
    case False{} True{} _ True{}:
      2n
    case False{} True{} True{} False{}:
      1n
    case _ _ _ _:
      0n

def act.occurs(+x: List<&2, U32>, +t: T.Bt) -> Bool:
  act.used(x, T.tba.refs(t, Nil{}))

def act.step.k(k: Nat, +t: T.Bt, +a: T.Bt, +b: T.Bt, +e: T.Bt, +goal: T.Bt) -> ActStep:
  match k:
    case 1n:
      ActStep{1n, T.tba.subst(goal, act.var.name(b), T.BtWild{}), T.tba.subst(goal, act.var.name(b), a), T.BtWild{}, Nil{}}
    case 2n:
      ActStep{2n, T.tba.subst(goal, act.var.name(a), T.BtWild{}), T.tba.subst(goal, act.var.name(a), b), T.BtApp{T.BtVar{S.b("Equal.sym")}, T.tba.args([T.BtDead{t}, T.BtDead{a}, T.BtDead{b}, e])}, List.append(&2, U32, act.var.name(e), S.b("_sym"))}
    case _:
      ActStep{0n, T.BtWild{}, goal, T.BtWild{}, Nil{}}

def act.step.dir(rb: Bool, ra: Bool, +t: T.Bt, +a: T.Bt, +b: T.Bt, +e: T.Bt, +goal: T.Bt) -> ActStep:
  act.step.k(act.mark.b(rb, ra, act.occurs(act.var.name(b), goal), act.occurs(act.var.name(a), goal)), t, a, b, e, goal)

def act.step(ty: T.Bt, +e: T.Bt, +ds: List<&2, List<&2, U32>>, +goal: T.Bt) -> ActStep:
  match ty:
    case T.BtEq{+t, +a, +b}:
      act.step.dir(act.dotted(b, ds), act.dotted(a, ds), t, a, b, e, goal)
    case _:
      ActStep{0n, T.BtWild{}, goal, T.BtWild{}, Nil{}}

def act.step.goal(s: ActStep) -> T.Bt:
  match s:
    case ActStep{k, p, g, y, e2}:
      g

# the rewrite a step plans, in front of the rest
def act.step.wrap(s: ActStep, e: T.Bt, inner: T.Bt) -> T.Bt:
  match s:
    case ActStep{0n, p, g, y, e2}:
      inner
    case ActStep{1n, p, g, y, e2}:
      T.BtRw{e, p, inner}
    case ActStep{k, p, g, y, +e2}:
      T.BtLet{e2, y, T.BtRw{T.BtVar{e2}, p, inner}}

# the clause's rewrites, in order, before its body
def act.rws(fuel: Nat, es: List<&2, T.Bt>, +ds: List<&2, List<&2, U32>>, +goal: T.Bt, +hps: List<&2, T.BParam>, body: T.Bt) -> T.Bt:
  match fuel es:
    case 1n+p +e <> t:
      +s = act.step(act.param.ty(hps, act.var.name(e)), e, ds, goal)
      act.step.wrap(s, e, act.rws(p, t, ds, act.step.goal(s), hps, body))
    case _ _:
      body

# Indexed patterns: a constructor pattern of an indexed family names its
# equation fields after its place (x_2_eq: parameter x's pattern, its
# second argument), and at a split parameter each becomes a rewrite like a
# refl pattern's.  Its type is {v == t : T}: v the index the parameter's
# type has there, t the term the clause's dot pattern gives v (Agda's
# match made v a dot pattern), T v's type.
type ActDot is Data:
  ActDot{x: List<&2, U32>, t: A.Ag}

# the clause's top-level dot patterns, by parameter
def act.dots(ps: A.Ag, ents: List<&2, T.Bt>) -> List<&2, ActDot>:
  match ps ents:
    case A.AgPArg{i, x, A.AgPDot{t}, rest} e <> et:
      ActDot{act.var.name(e), t} <> act.dots(rest, et)
    case A.AgPArg{i, x, p, rest} e <> et:
      act.dots(rest, et)
    case _ _:
      Nil{}

def act.dot.find(ds: List<&2, ActDot>, +v: List<&2, U32>) -> Maybe<&2, A.Ag>:
  match ds:
    case Nil{}:
      None{}
    case ActDot{+x, +t} <> rest:
      Bool.pick(Maybe<&2, A.Ag>, S.eq(x, v), Some{t}, act.dot.find(rest, v))

def act.at(+pre: List<&2, U32>, +i: Nat) -> List<&2, U32>:
  List.append(&2, U32, pre, 95 <> S.b(Nat.show(i)))

# the equation placeholders of a pattern (or a spine of them, i its
# position) named after their place under pre
def act.eq.deep(p: T.Bt, +pre: List<&2, U32>, +i: Nat) -> T.Bt:
  match p:
    case T.BtArgs{a, rest}:
      T.BtArgs{act.eq.deep(a, act.at(pre, i), 1n), act.eq.deep(rest, pre, 1n+i)}
    case T.BtCon{c, a}:
      T.BtCon{c, act.eq.deep(a, pre, 1n)}
    case T.BtSucc{a}:
      T.BtSucc{act.eq.deep(a, pre, 1n)}
    case T.BtPv{+m, +nm}:
      T.BtPv{m, Bool.pick(List<&2, U32>, S.eq(nm, S.b("ix_eq")), List.append(&2, U32, pre, S.b("_eq")), nm)}
    case p:
      p

# the top patterns, each under its parameter's name
def act.eq.spine(ps: T.Bt, xs: List<&2, T.Bt>) -> T.Bt:
  match ps xs:
    case T.BtArgs{p, rest} x <> xt:
      T.BtArgs{act.eq.deep(p, act.var.name(x), 1n), act.eq.spine(rest, xt)}
    case ps _:
      ps

def act.spine.list(a: T.Bt) -> List<&2, T.Bt>:
  match a:
    case T.BtArgs{h, t}:
      h <> act.spine.list(t)
    case _:
      Nil{}

def act.list.take(n: Nat, xs: List<&2, T.Bt>) -> List<&2, T.Bt>:
  match n xs:
    case 1n+p h <> t:
      h <> act.list.take(p, t)
    case _ xs:
      Nil{}

def act.list.last(+n: Nat, xs: List<&2, T.Bt>) -> List<&2, T.Bt>:
  List.reverse(&2, T.Bt, act.list.take(n, List.reverse(&2, T.Bt, xs)))

# the equation variables of a top constructor pattern: its arguments
# named x_i_eq, by position
def act.eq.vars(a: T.Bt, +x: List<&2, U32>, +i: Nat) -> List<&2, List<&2, U32>>:
  match a:
    case T.BtArgs{T.BtPv{m, +nm}, rest}:
      +e = List.append(&2, U32, act.at(x, i), S.b("_eq"))
      List.append(&2, List<&2, U32>, Bool.pick(List<&2, List<&2, U32>>, S.eq(nm, e), [e], Nil{}), act.eq.vars(rest, x, 1n+i))
    case T.BtArgs{h, rest}:
      act.eq.vars(rest, x, 1n+i)
    case _:
      Nil{}

# an equation variable's parameter: {v == t : T} when the clause dots v
def act.eq.p(m: Maybe<&2, A.Ag>, +e: List<&2, U32>, +v: T.Bt, +hps: List<&2, T.BParam>, +ctx: List<&2, T.Bt>, +env: ActEnv) -> List<&2, T.BParam>:
  match m:
    case Some{t}:
      [T.BParam{T.BmLive{}, e, T.BtEq{act.param.ty(hps, act.var.name(v)), v, act.t(act.inline(100000n, t, env), ctx, env)}}]
    case None{}:
      Nil{}

def act.eq.ps(es: List<&2, List<&2, U32>>, ixs: List<&2, T.Bt>, +hps: List<&2, T.BParam>, +dots: List<&2, ActDot>, +ctx: List<&2, T.Bt>, +env: ActEnv) -> List<&2, T.BParam>:
  match es ixs:
    case +e <> et +v <> vt:
      List.append(&2, T.BParam, act.eq.p(act.dot.find(dots, act.var.name(v)), e, v, hps, ctx, env), act.eq.ps(et, vt, hps, dots, ctx, env))
    case _ _:
      Nil{}

# a spine's terms, an erased one's mark taken off
def act.spine.undead(a: T.Bt) -> List<&2, T.Bt>:
  match a:
    case T.BtArgs{h, t}:
      act.undead(h) <> act.spine.undead(t)
    case _:
      Nil{}

def act.ty.args(t: T.Bt) -> List<&2, T.Bt>:
  match t:
    case T.BtTyApp{n, a}:
      act.spine.undead(a)
    case _:
      Nil{}

# the equation parameters of one top pattern at parameter x
def act.eq.top(p: T.Bt, +x: List<&2, U32>, +hps: List<&2, T.BParam>, +dots: List<&2, ActDot>, +ctx: List<&2, T.Bt>, +env: ActEnv) -> List<&2, T.BParam>:
  match p:
    case T.BtCon{c, a}:
      +es = act.eq.vars(a, x, 1n)
      act.eq.ps(es, act.list.last(List.length(&2, List<&2, U32>, es), act.ty.args(act.param.ty(hps, x))), hps, dots, ctx, env)
    case _:
      Nil{}

def act.eq.tops(ps: T.Bt, xs: List<&2, T.Bt>, +hps: List<&2, T.BParam>, +dots: List<&2, ActDot>, +ctx: List<&2, T.Bt>, +env: ActEnv) -> List<&2, T.BParam>:
  match ps xs:
    case T.BtArgs{p, rest} x <> xt:
      List.append(&2, T.BParam, act.eq.top(p, act.var.name(x), hps, dots, ctx, env), act.eq.tops(rest, xt, hps, dots, ctx, env))
    case _ _:
      Nil{}

def act.ps.vars(ps: List<&2, T.BParam>) -> List<&2, T.Bt>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, x, ty} <> t:
      T.BtVar{x} <> act.ps.vars(t)

# a case's body: the rewrites of its refl patterns, then those of its
# indexed patterns' equations (eqs), then the body
def act.case.body(+eqs: List<&2, T.BParam>, rw: ActRw, +goal: T.Bt, +hps: List<&2, T.BParam>, body: T.Bt) -> T.Bt:
  match rw:
    case ActRw{rs, ds}:
      act.rws(64n, List.append(&2, T.Bt, rs, act.ps.vars(eqs)), ds, goal, List.append(&2, T.BParam, hps, eqs), body)

# the scrutinees: the entries of the split parameters
def act.scr.vars(scr: List<&2, Bool>, ents: List<&2, T.Bt>) -> List<&2, T.Bt>:
  match scr ents:
    case True{} <> st e <> et:
      e <> act.scr.vars(st, et)
    case False{} <> st e <> et:
      act.scr.vars(st, et)
    case _ _:
      Nil{}

# Absurd clauses: Agda's `f ()` needs no split when the variable's type is
# empty (⊥ = Irrelevant Empty), but Bend has to see the emptiness, so the
# clause's body matches the variable down to an empty data type: a
# type-valued definition is opened, a one-field record (Irrelevant A, Lift
# A) is matched and its field, whose type is taken to be the record's last
# argument, eliminated in turn, and an empty data type is a match with no
# cases.  One step of that walk:
type ActAbsSt is Data:
  AbsDone{}
  AbsOpen{t: A.Ag}
  AbsWrap{c: List<&2, U32>, t: A.Ag}
  AbsFail{}

# the last argument of a spine
def act.es.last(es: A.Ag) -> A.Ag:
  match es:
    case A.AgEApp{i, t, A.AgENil{}}:
      t
    case A.AgEApp{i, t, rest}:
      act.es.last(rest)
    case _:
      A.AgNone{}

def act.abs.sym(s: ActSym, q: A.AgQ, +es: A.Ag, +env: ActEnv) -> ActAbsSt:
  match s:
    case ActSym{m, n, A.AkData{}, ms, ar, b, Nil{}, c, cp}:
      AbsDone{}
    case ActSym{+m, n, A.AkRecord{}, ms, ar, b, f <> Nil{}, +c, cp}:
      AbsWrap{act.ref.of(act.is.here(env, m), env, m, c), act.es.last(es)}
    case ActSym{m, n, A.AkFunction{}, ms, ar, b, fs, c, cp}:
      AbsOpen{act.inline(1024n, act.unfold(env, q, es), env)}
    case _:
      AbsFail{}

def act.abs.def(t: A.Ag, +env: ActEnv) -> ActAbsSt:
  match t:
    case A.AgDef{+q, +es}:
      act.abs.sym(act.sym(env, q), q, es, env)
    case _:
      AbsFail{}

def act.abs.step(t: A.Ag, +env: ActEnv) -> ActAbsSt:
  match t:
    case A.AgEl{s, a}:
      act.abs.def(a, env)
    case t:
      act.abs.def(t, env)

def act.abs.match(+x: List<&2, U32>, cs: T.Bt) -> T.Bt:
  T.BtMatch{T.tba.args([T.BtVar{x}]), cs}

# the elimination of x, a step at a time
def act.abs.elim(fuel: Nat, st: ActAbsSt, +x: List<&2, U32>, +env: ActEnv) -> T.Bt:
  match fuel st:
    case _ AbsDone{}:
      act.abs.match(x, T.BtCEnd{})
    case 1n+f AbsOpen{t}:
      act.abs.elim(f, act.abs.step(t, env), x, env)
    case 1n+f AbsWrap{c, t}:
      +y = List.append(&2, U32, x, S.b("_f"))
      act.abs.match(x, T.BtCase{T.tba.args([T.BtCon{c, T.tba.args([T.BtPv{T.BmLive{}, y}])}]), act.abs.elim(f, act.abs.step(t, env), y, env), T.BtCEnd{}})
    case _ _:
      T.BtExpr{act.todo("an absurd pattern on a type agda2bend cannot see is empty")}

# a clause's first top-level absurd pattern variable: its parameter and type
type ActAbs is Data:
  ActAbs{x: List<&2, U32>, ty: A.Ag}

def act.tel.nth(tel: A.Ag, n: Nat) -> A.Ag:
  match tel n:
    case A.AgTel{x, i, ty, rest} 0n:
      ty
    case A.AgTel{x, i, ty, rest} 1n+p:
      act.tel.nth(rest, p)
    case _ _:
      A.AgNone{}

def act.abs.find(ps: A.Ag, ents: List<&2, T.Bt>, +tel: A.Ag, +n: Nat) -> Maybe<&2, ActAbs>:
  match ps ents:
    case A.AgPArg{i, x, A.AgPVar{v, +ix, A.AkAbsurd{}}, rest} e <> et:
      Some{ActAbs{act.var.name(e), act.tel.nth(tel, Nat.sub(Nat.sub(n, 1n), ix))}}
    case A.AgPArg{i, x, p, rest} e <> et:
      act.abs.find(rest, et, tel, n)
    case _ _:
      None{}

# a clause's body: an absurd one's elimination, else the body translated
def act.abs.body(m: Maybe<&2, ActAbs>, body: A.Ag, +ctx: List<&2, T.Bt>, +env: ActEnv) -> T.Bt:
  match m body:
    case Some{ActAbs{x, ty}} A.AgAbsurd{}:
      act.abs.elim(16n, act.abs.step(ty, env), x, env)
    case _ body:
      T.BtExpr{act.t(act.inline(100000n, body, env), ctx, env)}

# the parameters some clause has an absurd pattern variable at (they must
# be live, as a split one: the elimination matches them)
def act.abs.one(p: A.Ag) -> Bool:
  match p:
    case A.AgPVar{x, n, A.AkAbsurd{}}:
      True{}
    case _:
      False{}

def act.abs.ps(ps: A.Ag) -> List<&2, Bool>:
  match ps:
    case A.AgPArg{i, x, p, rest}:
      act.abs.one(p) <> act.abs.ps(rest)
    case _:
      Nil{}

# a case: its patterns, and its body after the rewrites its refl patterns
# need (an absurd or cubical clause is left out)
def act.case.of(a: ActPat, +n: Nat, body: A.Ag, +env: ActEnv, rest: T.Bt, rw: ActRw, abs: Maybe<&2, ActAbs>, +dots: List<&2, ActDot>, +svars: List<&2, T.Bt>, +hps: List<&2, T.BParam>, +ret: T.Bt) -> T.Bt:
  match a:
    case ActPat{p, +bs, True{}}:
      rest
    case ActPat{p, +bs, False{}}:
      +q = act.eq.spine(p, svars)
      +ctx = act.ctx.of(n, bs)
      T.BtCase{q, act.case.body(act.eq.tops(q, svars, hps, dots, ctx, env), rw, act.goal(svars, q, ret), hps, act.abs.body(abs, body, ctx, env)), rest}

# the cases of a match from the clauses (an absurd clause is left out)
def act.cases(cls: A.Ag, +scr: List<&2, Bool>, +ents: List<&2, T.Bt>, +pnames: List<&2, List<&2, U32>>, +env: ActEnv, +hps: List<&2, T.BParam>, +ret: T.Bt) -> T.Bt:
  match cls:
    case A.AgCl{+tel, +ps, body, ty, ca, rest}:
      +n = act.tel.len(tel)
      act.case.of(act.top(ps, scr, ents, n, act.tel.hints(tel), pnames, env), n, body, env, act.cases(rest, scr, ents, pnames, env, hps, ret), act.rw.scan(ps, ents, env), act.abs.find(ps, ents, tel, n), act.dots(ps, ents), act.scr.vars(scr, ents), hps, ret)
    case _:
      T.BtCEnd{}

# which of the first k parameters a clause splits (a constructor or a
# literal pattern there)
def act.split.one(p: A.Ag, +env: ActEnv) -> Bool:
  match p:
    case A.AgPCon{+q, r, ps}:
      Bool.not(act.is.refl(act.sym(env, q)))
    case A.AgPLit{l}:
      True{}
    case _:
      False{}

def act.split.pos(ps: A.Ag, +env: ActEnv) -> List<&2, Bool>:
  match ps:
    case A.AgPArg{i, x, A.AgPProj{q}, rest}:
      Nil{}
    case A.AgPArg{i, x, p, rest}:
      act.split.one(p, env) <> act.split.pos(rest, env)
    case _:
      Nil{}

def act.or.lists(a: List<&2, Bool>, b: List<&2, Bool>) -> List<&2, Bool>:
  match a b:
    case x <> xs y <> ys:
      Bool.or(x, y) <> act.or.lists(xs, ys)
    case Nil{} b:
      b
    case a Nil{}:
      a

# the parameters any clause splits
def act.scr(cls: A.Ag, +env: ActEnv) -> List<&2, Bool>:
  match cls:
    case A.AgCl{tel, ps, body, ty, ca, rest}:
      act.or.lists(act.split.pos(ps, env), act.scr(rest, env))
    case _:
      Nil{}

# the parameters any clause has an absurd pattern variable at
def act.abs.pos(cls: A.Ag) -> List<&2, Bool>:
  match cls:
    case A.AgCl{tel, ps, body, ty, ca, rest}:
      act.or.lists(act.abs.ps(ps), act.abs.pos(rest))
    case _:
      Nil{}

def act.any(xs: List<&2, Bool>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(h, act.any(t))

def act.ent.names(ents: List<&2, T.Bt>) -> List<&2, List<&2, U32>>:
  act.names(ents)

# the first case's body (the def's, when no clause splits a parameter)
def act.body.first(cs: T.Bt) -> T.Bt:
  match cs:
    case T.BtCase{p, b, rest}:
      b
    case _:
      T.BtExpr{act.todo("a function with no clause")}

def act.body.of(split: Bool, +scr: List<&2, Bool>, cls: A.Ag, +ents: List<&2, T.Bt>, +pnames: List<&2, List<&2, U32>>, +env: ActEnv, +hps: List<&2, T.BParam>, +ret: T.Bt) -> T.Bt:
  match split:
    case True{}:
      T.BtMatch{T.tba.args(act.scr.vars(scr, ents)), act.cases(cls, scr, ents, pnames, env, hps, ret)}
    case False{}:
      act.body.first(act.cases(cls, scr, ents, pnames, env, hps, ret))

def act.body.with(+scr: List<&2, Bool>, cls: A.Ag, +ents: List<&2, T.Bt>, +env: ActEnv, +hps: List<&2, T.BParam>, +ret: T.Bt) -> T.Bt:
  act.body.of(act.any(scr), scr, cls, ents, act.names(ents), env, hps, ret)


# A def's body from its clauses: one match on the parameters they split,
# in parameter order, or the one clause's body when none splits.
def act.body(+cls: A.Ag, +ents: List<&2, T.Bt>, +env: ActEnv, +hps: List<&2, T.BParam>, +ret: T.Bt) -> T.Bt:
  act.body.with(act.scr(cls, env), cls, ents, env, hps, ret)
# Items ------------------------------------------------------------------------

# A parameter a clause splits must be live (Bend matches erased values only
# in dead regions): the header's modes with those made live.  ms walks
# every parameter, ps only the kept ones.
def act.live.ps(ps: List<&2, T.BParam>, scr: List<&2, Bool>, ms: List<&2, ActM>) -> List<&2, T.BParam>:
  match ps scr ms:
    case ps s <> st AmDrop{} <> mt:
      act.live.ps(ps, st, mt)
    case T.BParam{T.BmErased{}, x, ty} <> pt True{} <> st m2 <> mt:
      T.BParam{T.BmLive{}, x, ty} <> act.live.ps(pt, st, mt)
    case p <> pt True{} <> st m2 <> mt:
      p <> act.live.ps(pt, st, mt)
    case p <> pt False{} <> st m2 <> mt:
      p <> act.live.ps(pt, st, mt)
    case ps _ _:
      ps

# the comment above a def: its Agda name and binding site
def act.doc(+qs: List<&2, U32>, +file: List<&2, U32>, +line: Nat) -> List<&2, List<&2, U32>>:
  [List.append(&2, U32, S.b("Agda: "), qs), S.b(S.base(S.str(file)) ++ ", line " ++ Nat.show(line))]

def act.last.of(xs: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match xs:
    case h <> Nil{}:
      h
    case h <> t:
      act.last.of(t)
    case Nil{}:
      S.b("f")

def act.last.part(+n: List<&2, U32>) -> List<&2, U32>:
  act.last.of(S.split(n, 46))

def act.key.pos(+k: String, ks: List<&2, String>) -> Nat:
  match ks:
    case Nil{}:
      0n
    case h <> t:
      Bool.pick(Nat, String.eq(h, k), 0n, 1n+act.key.pos(k, t))

def act.field.var(s: ActSym) -> List<&2, U32>:
  match s:
    case ActSym{m, +n, k, ms, ar, b, fs, c, cp}:
      List.append(&2, U32, S.b("f_"), act.last.part(n))

def act.sym.key(+env: ActEnv, k: String) -> ActSym:
  match env:
    case ActEnv{mod, tab, al, unf}:
      act.sym.got(Map.get(ActSym, act.sym0(), tab, k))

# a record's fields as pattern variables: their names' last parts
def act.field.vars(ks: List<&2, String>, +env: ActEnv) -> List<&2, T.Bt>:
  match ks:
    case Nil{}:
      Nil{}
    case k <> t:
      T.BtVar{act.field.var(act.sym.key(env, k))} <> act.field.vars(t, env)

def act.nth.t(n: Nat, xs: List<&2, T.Bt>) -> T.Bt:
  match n xs:
    case 0n h <> t:
      h
    case 1n+p h <> t:
      act.nth.t(p, t)
    case _ Nil{}:
      act.todo("a field the record does not have")

def act.last.t(xs: List<&2, T.Bt>) -> T.Bt:
  match xs:
    case h <> Nil{}:
      h
    case h <> t:
      act.last.t(t)
    case Nil{}:
      act.todo("a projection with no record argument")

# A record field's projection: a match on the record (its last parameter)
# that answers the field.
def act.proj.body(r: ActSym, +env: ActEnv, +own: String, +ents: List<&2, T.Bt>) -> T.Bt:
  match r:
    case ActSym{+m, n, k, ms, ar, b, +fs, +c, cp}:
      +vs = act.field.vars(fs, env)
      T.BtMatch{T.tba.args([act.last.t(ents)]), T.BtCase{T.tba.args([T.BtCon{act.ref.of(act.is.here(env, m), env, m, c), T.tba.args(vs)}]), T.BtExpr{act.nth.t(act.key.pos(own, fs), vs)}, T.BtCEnd{}}}

def act.proj.rec(p: A.AgProj) -> Maybe<&2, A.AgQ>:
  match p:
    case A.AgPrOf{Some{r}, o, ix}:
      Some{r}
    case _:
      None{}

# Copatterns: each field's clause, its value a lambda over the patterns
# after the projection.

def act.copat.hit(ps: A.Ag, +key: String) -> Bool:
  match ps:
    case A.AgPArg{i, x, A.AgPProj{q}, rest}:
      String.eq(act.key(q), key)
    case A.AgPArg{i, x, p, rest}:
      act.copat.hit(rest, key)
    case _:
      False{}

# the patterns after the projection
def act.copat.extra(ps: A.Ag) -> A.Ag:
  match ps:
    case A.AgPArg{i, x, A.AgPProj{q}, rest}:
      rest
    case A.AgPArg{i, x, p, rest}:
      act.copat.extra(rest)
    case _:
      A.AgPEnd{}

def act.lams(xs: T.Bt, b: T.Bt) -> T.Bt:
  match xs:
    case T.BtArgs{T.BtPv{m, x}, rest}:
      T.BtLam{T.BmLive{}, x, act.lams(rest, b)}
    case T.BtArgs{p, rest}:
      act.todo("a copattern clause that matches after its projection")
    case _:
      b

def act.falses(xs: List<&2, T.Bt>) -> List<&2, Bool>:
  match xs:
    case Nil{}:
      Nil{}
    case h <> t:
      False{} <> act.falses(t)

def act.copat.value(a: ActPat, b: ActPat, +n: Nat, body: A.Ag, +env: ActEnv) -> T.Bt:
  match a b:
    case ActPat{p, bs, x} ActPat{q, cs, y}:
      act.lams(q, act.t(act.inline(100000n, body, env), act.ctx.of(n, List.append(&2, ActBind, bs, cs)), env))

def act.copat.of(+tel: A.Ag, +ps: A.Ag, body: A.Ag, +ents: List<&2, T.Bt>, +env: ActEnv) -> T.Bt:
  +n = act.tel.len(tel)
  +hints = act.tel.hints(tel)
  act.copat.value(act.top(ps, act.falses(ents), ents, n, hints, act.names(ents), env), act.pat(act.copat.extra(ps), n, hints, act.names(ents), env), n, body, env)

def act.copat.hit.cl(cls: A.Ag, +key: String) -> Bool:
  match cls:
    case A.AgCl{tel, ps, body, ty, ca, rest}:
      act.copat.hit(ps, key)
    case _:
      False{}

# hit: whether the first clause defines the field key (decided by the caller)
def act.copat.find(cls: A.Ag, +key: String, +ents: List<&2, T.Bt>, +env: ActEnv, hit: Bool) -> T.Bt:
  match cls hit:
    case A.AgCl{tel, ps, body, ty, ca, rest} True{}:
      act.copat.of(tel, ps, body, ents, env)
    case A.AgCl{tel, ps, body, ty, ca, +rest} False{}:
      act.copat.find(rest, key, ents, env, act.copat.hit.cl(rest, key))
    case _ _:
      act.todo("a field no copattern clause defines")

def act.copat.fields(ks: List<&2, String>, +cls: A.Ag, +ents: List<&2, T.Bt>, +env: ActEnv) -> List<&2, T.Bt>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> t:
      act.copat.find(cls, k, ents, env, act.copat.hit.cl(cls, k)) <> act.copat.fields(t, cls, ents, env)

def act.copat.rec(r: ActSym, +env: ActEnv, +cls: A.Ag, +ents: List<&2, T.Bt>) -> T.Bt:
  match r:
    case ActSym{+m, n, A.AkRecord{}, ms, ar, b, fs, +c, cp}:
      T.BtExpr{T.BtCon{act.ref.of(act.is.here(env, m), env, m, c), T.tba.args(act.copat.fields(fs, cls, ents, env))}}
    case _:
      T.BtExpr{act.todo("copattern clauses whose type is not a record")}

# the head name of a TYPE after n Pis (a copattern definition's record)
def act.cod.q(n: Nat, t: A.Ag) -> Maybe<&2, A.AgQ>:
  match n t:
    case n A.AgEl{s, x}:
      act.cod.q(n, x)
    case 1n+p A.AgPi{i, x, a, d, b}:
      act.cod.q(p, b)
    case 0n A.AgDef{q, es}:
      Some{q}
    case 0n A.AgDefX{q, es}:
      Some{q}
    case _ _:
      None{}

def act.pats.all(ps: A.Ag) -> Nat:
  match ps:
    case A.AgPArg{i, x, p, rest}:
      1n+act.pats.all(rest)
    case _:
      0n

def act.copat.is(cls: A.Ag) -> Bool:
  match cls:
    case A.AgCl{tel, +ps, body, ty, ca, rest}:
      Bool.not(Nat.is_eq(act.pats.len(ps), act.pats.all(ps)))
    case _:
      False{}

def act.copat.body(q: Maybe<&2, A.AgQ>, +env: ActEnv, +cls: A.Ag, +ents: List<&2, T.Bt>) -> T.Bt:
  match q:
    case Some{r}:
      act.copat.rec(act.sym(env, r), env, cls, ents)
    case None{}:
      T.BtExpr{act.todo("copattern clauses whose type is not a record")}

def act.ps.ents(r: ActPs) -> List<&2, T.Bt>:
  match r:
    case ActPs{ps, ret, ctx, es, ok}:
      es

def act.ps.ps(r: ActPs) -> List<&2, T.BParam>:
  match r:
    case ActPs{ps, ret, ctx, es, ok}:
      ps

def act.ps.ret(r: ActPs) -> T.Bt:
  match r:
    case ActPs{ps, ret, ctx, es, ok}:
      ret

# a function: its header from its type, its body from its clauses (or, for
# a record field, a match on the record; for copattern clauses, the
# record's constructor)
# the kept (not dropped) parameters among the first n
def act.kept.n(n: Nat, ms: List<&2, ActM>) -> Nat:
  match n ms:
    case 1n+p AmDrop{} <> t:
      act.kept.n(p, t)
    case 1n+p m <> t:
      1n+act.kept.n(p, t)
    case _ _:
      0n

def act.bp.names(ps: List<&2, T.BParam>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, x, ty} <> t:
      x <> act.bp.names(t)

def act.mem.name(+n: List<&2, U32>, xs: List<&2, List<&2, U32>>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case h <> t:
      Bool.or(S.eq(h, n), act.mem.name(n, t))

# a body (match, cases, rewrites, lets, expressions) with the variable n
# renamed n2, a case or let binding n shadowing it
def act.sub.deep(t: T.Bt, +n: List<&2, U32>, +n2: List<&2, U32>) -> T.Bt:
  match t:
    case T.BtExpr{e}:
      T.BtExpr{T.tba.subst(e, n, T.BtVar{n2})}
    case T.BtMatch{xs, cs}:
      T.BtMatch{T.tba.subst(xs, n, T.BtVar{n2}), act.sub.deep(cs, n, n2)}
    case T.BtCase{+p, +b, rest}:
      T.BtCase{p, Bool.pick(T.Bt, act.mem.name(n, T.tba.pvars(p, Nil{})), b, act.sub.deep(b, n, n2)), act.sub.deep(rest, n, n2)}
    case T.BtRw{e, p, b}:
      T.BtRw{T.tba.subst(e, n, T.BtVar{n2}), T.tba.subst(p, n, T.BtVar{n2}), act.sub.deep(b, n, n2)}
    case T.BtLet{+y, v, +b}:
      T.BtLet{y, T.tba.subst(v, n, T.BtVar{n2}), Bool.pick(T.Bt, S.eq(y, n), b, act.sub.deep(b, n, n2))}
    case t:
      T.tba.subst(t, n, T.BtVar{n2})

# a case pattern with its variable n renamed n2
def act.alpha.pat(p: T.Bt, +n: List<&2, U32>, +n2: List<&2, U32>) -> T.Bt:
  match p:
    case T.BtVar{+y}:
      Bool.pick(T.Bt, S.eq(y, n), T.BtVar{n2}, T.BtVar{y})
    case T.BtPv{+m, +y}:
      Bool.pick(T.Bt, S.eq(y, n), T.BtPv{m, n2}, T.BtPv{m, y})
    case T.BtCon{c, a}:
      T.BtCon{c, act.alpha.pat(a, n, n2)}
    case T.BtArgs{a, rest}:
      T.BtArgs{act.alpha.pat(a, n, n2), act.alpha.pat(rest, n, n2)}
    case T.BtSucc{a}:
      T.BtSucc{act.alpha.pat(a, n, n2)}
    case p:
      p

# t with each binder named n (a lambda's, a Pi's, a let's, a case's
# pattern variable) renamed n2 in its scope; a free n, the lifted
# parameter itself, stays
def act.alpha(t: T.Bt, +n: List<&2, U32>, +n2: List<&2, U32>) -> T.Bt:
  match t:
    case T.BtLam{+m, +y, b}:
      +b2 = act.alpha(b, n, n2)
      Bool.pick(T.Bt, S.eq(y, n), T.BtLam{m, n2, T.tba.subst(b2, n, T.BtVar{n2})}, T.BtLam{m, y, b2})
    case T.BtPi{+m, +y, +d, +a, b}:
      +b2 = act.alpha(b, n, n2)
      Bool.pick(T.Bt, S.eq(y, n), T.BtPi{m, n2, d, act.alpha(a, n, n2), T.tba.subst(b2, n, T.BtVar{n2})}, T.BtPi{m, y, d, act.alpha(a, n, n2), b2})
    case T.BtLet{+y, +v, b}:
      +b2 = act.alpha(b, n, n2)
      Bool.pick(T.Bt, S.eq(y, n), T.BtLet{n2, act.alpha(v, n, n2), T.tba.subst(b2, n, T.BtVar{n2})}, T.BtLet{y, act.alpha(v, n, n2), b2})
    case T.BtCase{+p, b, +rest}:
      +b2 = act.alpha(b, n, n2)
      Bool.pick(T.Bt, act.mem.name(n, T.tba.pvars(p, Nil{})), T.BtCase{act.alpha.pat(p, n, n2), act.sub.deep(b2, n, n2), act.alpha(rest, n, n2)}, T.BtCase{p, b2, act.alpha(rest, n, n2)})
    case T.BtApp{f, a}:
      T.BtApp{act.alpha(f, n, n2), act.alpha(a, n, n2)}
    case T.BtArgs{a, rest}:
      T.BtArgs{act.alpha(a, n, n2), act.alpha(rest, n, n2)}
    case T.BtTplArg{a}:
      T.BtTplArg{act.alpha(a, n, n2)}
    case T.BtCon{c, a}:
      T.BtCon{c, act.alpha(a, n, n2)}
    case T.BtTyApp{c, a}:
      T.BtTyApp{c, act.alpha(a, n, n2)}
    case T.BtEq{ty, a, b}:
      T.BtEq{act.alpha(ty, n, n2), act.alpha(a, n, n2), act.alpha(b, n, n2)}
    case T.BtSucc{a}:
      T.BtSucc{act.alpha(a, n, n2)}
    case T.BtAnn{a, ty}:
      T.BtAnn{act.alpha(a, n, n2), act.alpha(ty, n, n2)}
    case T.BtDead{a}:
      T.BtDead{act.alpha(a, n, n2)}
    case T.BtRw{e, p, b}:
      T.BtRw{act.alpha(e, n, n2), act.alpha(p, n, n2), act.alpha(b, n, n2)}
    case T.BtMatch{xs, cs}:
      T.BtMatch{act.alpha(xs, n, n2), act.alpha(cs, n, n2)}
    case T.BtExpr{e}:
      T.BtExpr{act.alpha(e, n, n2)}
    case t:
      t

# a body applied to one more parameter, n: a head lambda takes it (in each
# case of a match, under a rewrite or a let), else the value is applied, an
# erased parameter (dead: m) in a dead place so Copy does not raise it
def act.lift.arg(m: T.BMode, +n: List<&2, U32>) -> T.Bt:
  match m:
    case T.BmErased{}:
      T.BtDead{T.BtVar{n}}
    case _:
      T.BtVar{n}

def act.lift.one(b: T.Bt, +m: T.BMode, +n: List<&2, U32>) -> T.Bt:
  match b:
    case T.BtExpr{T.BtLam{lm, x, e}}:
      T.BtExpr{T.tba.subst(e, x, T.BtVar{n})}
    case T.BtExpr{e}:
      T.BtExpr{T.BtApp{e, T.BtArgs{act.lift.arg(m, n), T.BtANil{}}}}
    case T.BtMatch{xs, cs}:
      T.BtMatch{xs, act.lift.one(cs, m, n)}
    case T.BtCase{p, cb, rest}:
      T.BtCase{p, act.lift.one(cb, m, n), act.lift.one(rest, m, n)}
    case T.BtRw{e, p, rb}:
      T.BtRw{e, p, act.lift.one(rb, m, n)}
    case T.BtLet{x, v, rb}:
      T.BtLet{x, v, act.lift.one(rb, m, n)}
    case b:
      b

# (a binder in the body named like n is renamed first, so n is not captured)
def act.lift.app(ps: List<&2, T.BParam>, b: T.Bt) -> T.Bt:
  match ps:
    case Nil{}:
      b
    case T.BParam{m, +n, ty} <> t:
      act.lift.app(t, act.lift.one(act.alpha(b, n, List.append(&2, U32, n, S.b("_b"))), m, n))

def act.fun.body(p: A.AgProj, +cls: A.Ag, +key: String, +ar: Nat, +t: A.Ag, +ents: List<&2, T.Bt>, +env: ActEnv, copat: Bool, +r: ActPs, +ms: List<&2, ActM>) -> T.Bt:
  match p copat:
    case A.AgPrOf{Some{r}, o, ix} _:
      act.proj.body(act.sym(env, r), env, key, ents)
    case _ True{}:
      act.copat.body(act.cod.q(ar, t), env, cls, ents)
    case _ False{}:
      act.lift.app(List.drop(&2, T.BParam, act.ps.ps(r), act.kept.n(act.cls.arity(cls), ms)), act.body(cls, ents, env, act.ps.ps(r), act.ps.ret(r)))

def act.fun.item(+nm: List<&2, U32>, +ms: List<&2, ActM>, +cls: A.Ag, body: T.Bt, r: ActPs, doc: List<&2, List<&2, U32>>, +env: ActEnv) -> List<&2, T.BItem>:
  match r:
    case ActPs{ps, ret, ctx, es, ok}:
      [T.BiDef{nm, act.live.ps(ps, act.or.lists(act.scr(cls, env), act.abs.pos(cls)), ms), ret, body, doc}]

def act.fun.with(+nm: List<&2, U32>, +ms: List<&2, ActM>, +ar: Nat, p: A.AgProj, +cls: A.Ag, +key: String, +t: A.Ag, +env: ActEnv, doc: List<&2, List<&2, U32>>, +r: ActPs) -> List<&2, T.BItem>:
  act.fun.item(nm, ms, cls, act.fun.body(p, cls, key, ar, t, act.ps.ents(r), env, act.copat.is(cls), r, ms), r, doc, env)

# Sorts by place (with quantities on): Kind(q) is a requirement in Bend (every
# value copyable at q), where Agda's Set ℓ is only a bound, so a definition
# keeps Type (`¬ A = A → ⊥` is a function type at any level). Kind(q) stays
# where kinds are declared: data and record parameters, field types (with
# type-valued definitions opened, so that Category's `_⇒_ : Rel Obj ℓ` shows
# Kind(l)) and the projections that read them.
def act.unkind(t: T.Bt) -> T.Bt:
  match t:
    case T.BtApp{T.BtVar{+k}, +a}:
      Bool.pick(T.Bt, S.eq(k, S.b("Kind")), T.BtType{}, T.BtApp{T.BtVar{k}, act.unkind(a)})
    case T.BtApp{f, a}:
      T.BtApp{act.unkind(f), act.unkind(a)}
    case T.BtArgs{a, rest}:
      T.BtArgs{act.unkind(a), act.unkind(rest)}
    case T.BtTplArg{a}:
      T.BtTplArg{act.unkind(a)}
    case T.BtLam{m, y, b}:
      T.BtLam{m, y, act.unkind(b)}
    case T.BtPi{m, y, d, a, b}:
      T.BtPi{m, y, d, act.unkind(a), act.unkind(b)}
    case T.BtCon{c, a}:
      T.BtCon{c, act.unkind(a)}
    case T.BtTyApp{c, a}:
      T.BtTyApp{c, act.unkind(a)}
    case T.BtEq{ty, a, b}:
      T.BtEq{act.unkind(ty), act.unkind(a), act.unkind(b)}
    case T.BtSucc{a}:
      T.BtSucc{act.unkind(a)}
    case T.BtAnn{a, ty}:
      T.BtAnn{act.unkind(a), act.unkind(ty)}
    case T.BtDead{a}:
      T.BtDead{act.unkind(a)}
    case T.BtMatch{xs, cs}:
      T.BtMatch{act.unkind(xs), act.unkind(cs)}
    case T.BtCase{p, b, rest}:
      T.BtCase{p, act.unkind(b), act.unkind(rest)}
    case T.BtExpr{e}:
      T.BtExpr{act.unkind(e)}
    case T.BtRw{e, p, b}:
      T.BtRw{act.unkind(e), act.unkind(p), act.unkind(b)}
    case T.BtLet{y, v, b}:
      T.BtLet{y, act.unkind(v), act.unkind(b)}
    case t:
      t

def act.unkind.ps(ps: List<&2, T.BParam>) -> List<&2, T.BParam>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, x, ty} <> t:
      T.BParam{m, x, act.unkind(ty)} <> act.unkind.ps(t)

def act.unkind.its(its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  match its:
    case Nil{}:
      Nil{}
    case T.BiDef{n, ps, ret, body, doc} <> t:
      T.BiDef{n, act.unkind.ps(ps), act.unkind(ret), act.unkind(body), doc} <> act.unkind.its(t)
    case it <> t:
      it <> act.unkind.its(t)

# a type's end (past its Pis) as Type when it is a kind
def act.unkind.end(t: T.Bt) -> T.Bt:
  match t:
    case T.BtPi{m, y, d, a, b}:
      T.BtPi{m, y, d, a, act.unkind.end(b)}
    case T.BtApp{T.BtVar{+k}, +a}:
      Bool.pick(T.Bt, S.eq(k, S.b("Kind")), T.BtType{}, T.BtApp{T.BtVar{k}, a})
    case t:
      t

# a type-valued definition (`_×_`, Rel, `¬_`) keeps its parameters' and body's
# kinds, so `A × B` is as copyable as Σ A B, and only its own sort is Type
# (2026-10-21: one with an expression body keeps its sort, and Qfix's
# tqf.ret.kind keeps it when the body is of that kind)
def act.unkind.ret(its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  match its:
    case Nil{}:
      Nil{}
    case T.BiDef{n, ps, ret, T.BtExpr{b}, doc} <> t:
      T.BiDef{n, ps, ret, T.BtExpr{b}, doc} <> act.unkind.ret(t)
    case T.BiDef{n, ps, ret, body, doc} <> t:
      T.BiDef{n, ps, act.unkind.end(ret), body, doc} <> act.unkind.ret(t)
    case it <> t:
      it <> act.unkind.ret(t)

# a proper projection keeps its kinds; any other function has Type
def act.unkind.if(p: A.AgProj, its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  match p:
    case A.AgPrOf{Some{r}, o, ix}:
      its
    case _:
      act.unkind.its(its)

# a field's or a projection's type with the type-valued definitions it ends
# in opened (Rel Obj ℓ is Obj → Obj → Set ℓ)
# (only with quantities on; tl: the definition is type-valued)
# (2026-10-20: a proper projection keeps its kinds even when it is
# type-valued: `Setoid.Carrier` is a Kind(c), the field's own kind, so the
# quantity of `IsEquivalence Carrier _≈_` is c, not the &1 of a Type)
# (2026-10-21: whether a value definition's kinds become Type.  They did
# so that a caller could pass a function type for `A : Set a`, before Qfix
# solved each call's quantities; with it on, `isYes : Dec<&1, A>` met
# `True_`'s `Dec<a, A>`)
def act.unkind.vals() -> Bool:
  False{}

def act.unkind.val(on: Bool, its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  match on:
    case True{}:
      act.unkind.its(its)
    case False{}:
      its

def act.unkind.np(tl: Bool, its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  match tl:
    case True{}:
      act.unkind.ret(its)
    case False{}:
      act.unkind.val(act.unkind.vals(), its)

def act.unkind.when(on: Bool, p: A.AgProj, tl: Bool, its: List<&2, T.BItem>) -> List<&2, T.BItem>:
  match on p:
    case True{} A.AgPrOf{Some{r}, o, ix}:
      its
    case True{} _:
      act.unkind.np(tl, its)
    case False{} _:
      its

def act.unfold.wrap(+s: A.Ag, u: A.Ag, +t: A.Ag, +env: ActEnv) -> A.Ag:
  match u:
    case A.AgNone{}:
      t
    case u:
      A.AgEl{s, act.inline(1024n, u, env)}

def act.unfold.sorts(fuel: Nat, t: A.Ag, +env: ActEnv) -> A.Ag:
  match fuel t:
    case 1n+f A.AgEl{+s, A.AgDef{+q, +es}}:
      act.unfold.sorts(f, act.unfold.wrap(s, act.unfold(env, q, es), A.AgEl{s, A.AgDef{q, es}}, env), env)
    case 1n+f A.AgEl{+s, A.AgDefX{+q, +es}}:
      act.unfold.sorts(f, act.unfold.wrap(s, act.unfold(env, q, es), A.AgEl{s, A.AgDefX{q, es}}, env), env)
    case 1n+f A.AgEl{s, A.AgPi{i, x, a, d, b}}:
      A.AgEl{s, A.AgPi{i, x, a, d, act.unfold.sorts(f, b, env)}}
    case f t:
      t
def act.field.sorts(on: Bool, t: A.Ag, +env: ActEnv) -> A.Ag:
  match on:
    case True{}:
      act.unfold.sorts(8n, t, env)
    case False{}:
      t

def act.proj.sorts(on: Bool, p: A.AgProj, t: A.Ag, +env: ActEnv) -> A.Ag:
  match on p:
    case True{} A.AgPrOf{Some{r}, o, ix}:
      act.unfold.sorts(8n, t, env)
    case _ _:
      t

# type-valuedness inside an item: a projection's by its own type, another
# function's once its type-valued ends are opened (as act.tylevel)
def act.tylevel.env(p: A.AgProj, +ty: A.Ag, +env: ActEnv) -> Bool:
  match p env:
    case A.AgPrOf{Some{r}, o, ix} e:
      act.ends.sort(ty)
    case _ ActEnv{mod, tab, al, +unf}:
      act.ends.sort.u(8n, ty, unf)

def act.item.fun(s: ActSym, d: A.AgD, +key: String, +ty: A.Ag, +env: ActEnv, doc: List<&2, List<&2, U32>>) -> List<&2, T.BItem>:
  match s d:
    case ActSym{m, +n, k, +ms, +ar, b, fs, c, cp} A.AgDFun{+p, r, w, e, te, mu, +cls, tree}:
      +t = act.proj.sorts(act.quant.on(), p, act.inline(100000n, ty, env), env)
      act.unkind.when(act.quant.on(), p, act.tylevel.env(p, ty, env), act.fun.with(n, ms, ar, p, cls, key, t, env, doc, act.params(64n, ar, t, ms, Nil{}, env)))
    case _ _:
      Nil{}

# A record: its non-level parameters (erased) and its fields, each field's
# type in the scope of the parameters and the earlier fields, from the
# telescope Agda keeps of both.
type ActRt is Data:
  ActRt{ps: List<&2, T.BParam>, fs: List<&2, T.BField>}

def act.rt.param(m: ActM, +nm: List<&2, U32>, ty: T.Bt, r: ActRt) -> ActRt:
  match m r:
    case AmDrop{} r:
      r
    case m ActRt{ps, fs}:
      ActRt{T.BParam{T.BmErased{}, nm, ty} <> ps, fs}

def act.rt.field(+nm: List<&2, U32>, ty: T.Bt, r: ActRt) -> ActRt:
  match r:
    case ActRt{ps, fs}:
      ActRt{ps, T.BField{nm, ty} <> fs}

def act.rtel(tel: A.Ag, np: Nat, ms: List<&2, ActM>, +ctx: List<&2, T.Bt>, +env: ActEnv) -> ActRt:
  match tel np ms:
    case A.AgTel{+x, i, ty, rest} 1n+p +m <> mt:
      +nm = act.fresh(x, ctx)
      act.rt.param(m, nm, act.t(act.field.sorts(act.quant.on(), act.inline(100000n, ty, env), env), ctx, env), act.rtel(rest, p, mt, act.entry(m, nm) <> ctx, env))
    case A.AgTel{+x, i, ty, rest} 1n+p Nil{}:
      +nm = act.fresh(x, ctx)
      act.rt.param(AmErased{}, nm, act.t(act.field.sorts(act.quant.on(), act.inline(100000n, ty, env), env), ctx, env), act.rtel(rest, p, Nil{}, T.BtVar{nm} <> ctx, env))
    case A.AgTel{+x, i, ty, rest} 0n ms:
      +nm = act.fresh(x, ctx)
      act.rt.field(nm, act.t(act.field.sorts(act.quant.on(), act.inline(100000n, ty, env), env), ctx, env), act.rtel(rest, 0n, ms, T.BtVar{nm} <> ctx, env))
    case _ _ _:
      ActRt{Nil{}, Nil{}}

# Kinds of the declared types (2026-10-20) ------------------------------------
#
# A type is as reusable as its fields' types, as Base's List is.  A field of
# a type parameter `-A: Kind(q)` contributes q (and so does a family
# `-B: A -> Kind(q)` applied); Nat, Bool, Unit, an equation or the type
# itself contribute &2; anything else contributes &1 (a function, a type, or
# another type).  The kind is the smallest: Data for &2, Type for &1, and
# Kind(q) in between.  So Σ A B is Kind(a <&> b), and Product's morphism
# pairs are Data when its homs are.

# the quantity a type's values have, from its type: Kind(q) is q, Data &2
def act.ty.endq(t: T.Bt) -> T.Bt:
  match t:
    case T.BtPi{m, y, d, a, b}:
      act.ty.endq(b)
    case T.BtApp{T.BtVar{+k}, T.BtArgs{+q, T.BtANil{}}}:
      Bool.pick(T.Bt, S.eq(k, S.b("Kind")), q, act.q1())
    case T.BtVar{+d}:
      Bool.pick(T.Bt, S.eq(d, S.b("Data")), act.q2(), act.q1())
    case _:
      act.q1()

# the quantity of the parameter named x's values (&1 if it is no parameter)
def act.p.q(ps: List<&2, T.BParam>, +x: List<&2, U32>) -> T.Bt:
  match ps:
    case Nil{}:
      act.q1()
    case T.BParam{m, +y, ty} <> t:
      Bool.pick(T.Bt, S.eq(x, y), act.ty.endq(ty), act.p.q(t, x))

def act.base.data(+x: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(S.eq(x, S.b("Nat")), S.eq(x, S.b("Bool"))), S.eq(x, S.b("Unit")))

# a field's contribution
def act.fq(+self: List<&2, U32>, ty: T.Bt, +ps: List<&2, T.BParam>) -> T.Bt:
  match ty:
    case T.BtVar{+x}:
      Bool.pick(T.Bt, act.base.data(x), act.q2(), act.p.q(ps, x))
    case T.BtApp{T.BtVar{+x}, a}:
      act.p.q(ps, x)
    case T.BtTyApp{+x, a}:
      Bool.pick(T.Bt, S.eq(x, self), act.q2(), act.q1())
    case T.BtEq{t, a, b}:
      act.q2()
    case _:
      act.q1()

def act.kind.fs(+self: List<&2, U32>, fs: List<&2, T.BField>, +ps: List<&2, T.BParam>) -> T.Bt:
  match fs:
    case Nil{}:
      act.q2()
    case T.BField{x, ty} <> t:
      act.qmin(act.fq(self, ty, ps), act.kind.fs(self, t, ps))

def act.kind.cs(+self: List<&2, U32>, cs: List<&2, T.BCtor>, +ps: List<&2, T.BParam>) -> T.Bt:
  match cs:
    case Nil{}:
      act.q2()
    case T.BCtor{c, fs} <> t:
      act.qmin(act.kind.fs(self, fs, ps), act.kind.cs(self, t, ps))

def act.kind.term(+q: T.Bt) -> T.Bt:
  Bool.pick(T.Bt, act.is.q2(q), T.BtVar{S.b("Data")}, Bool.pick(T.Bt, act.is.q1(q), T.BtType{}, T.BtApp{T.BtVar{S.b("Kind")}, T.BtArgs{q, T.BtANil{}}}))

def act.item.rec.of(+nm: List<&2, U32>, +c: List<&2, U32>, r: ActRt, doc: List<&2, List<&2, U32>>) -> List<&2, T.BItem>:
  match r:
    case ActRt{+ps, +fs}:
      [T.BiType{nm, ps, Bool.pick(T.Bt, act.quant.on(), act.kind.term(act.kind.fs(nm, fs, ps)), T.BtType{}), [T.BCtor{c, fs}], doc}]

def act.item.rec(s: ActSym, d: A.AgD, +env: ActEnv, doc: List<&2, List<&2, U32>>) -> List<&2, T.BItem>:
  match s d:
    case ActSym{m, +n, k, ms, ar, b, fs, +c, cp} A.AgDRec{pars, con, named, ind, fls, tel, eta, pm, rcl}:
      act.item.rec.of(n, c, act.rtel(tel, pars, ms, Nil{}, env), doc)
    case _ _:
      Nil{}

# A constructor's own arguments as fields (a Level one is dropped), each
# type in the scope of the data type's parameters and the earlier fields.
def act.cfield.put(lv: Bool, +nm: List<&2, U32>, ty: T.Bt, fs: List<&2, T.BField>) -> List<&2, T.BField>:
  match lv:
    case True{}:
      fs
    case False{}:
      T.BField{nm, ty} <> fs

# an indexed family's constructor's equation fields: per index parameter
# (its name and type) and the index the constructor's type ends at, {i == t : T}
def act.ix.eqs(ixs: List<&2, T.BParam>, es: A.Ag, +ctx: List<&2, T.Bt>, +seen: List<&2, List<&2, U32>>, +env: ActEnv) -> List<&2, T.BField>:
  match ixs es:
    case T.BParam{m, +x, ty} <> pt A.AgEApp{i, a, rest}:
      +nm = act.fresh.in(S.b("ix_eq"), ctx, seen)
      T.BField{nm, T.BtEq{ty, T.BtVar{x}, act.t(a, ctx, env)}} <> act.ix.eqs(pt, rest, ctx, nm <> seen, env)
    case _ _:
      Nil{}

def act.ix.fields(ixs: List<&2, T.BParam>, +pars: Nat, t: A.Ag, +ctx: List<&2, T.Bt>, +seen: List<&2, List<&2, U32>>, +env: ActEnv) -> List<&2, T.BField>:
  match t:
    case A.AgEl{s, A.AgDef{q, es}}:
      act.ix.eqs(ixs, act.es.after(pars, es), ctx, seen, env)
    case _:
      Nil{}

# (the index parameters' names are in seen, so no field hides one)
def act.cfields(t: A.Ag, +ctx: List<&2, T.Bt>, +seen: List<&2, List<&2, U32>>, +env: ActEnv, +ixs: List<&2, T.BParam>, +pars: Nat) -> List<&2, T.BField>:
  match t:
    case A.AgEl{s, A.AgPi{i, +x, +a, d, b}}:
      +lv = act.ty.level(a)
      +nm = act.fresh.in(x, ctx, seen)
      act.cfield.put(lv, nm, act.t(a, ctx, env), act.cfields(b, act.bind(d, Bool.pick(T.Bt, lv, act.level(), T.BtVar{nm}), ctx), nm <> seen, env, ixs, pars))
    case t:
      act.ix.fields(ixs, pars, t, ctx, seen, env)

# a TYPE after its first n Pis
def act.after(n: Nat, t: A.Ag) -> A.Ag:
  match n t:
    case 1n+p A.AgEl{s, A.AgPi{i, x, a, d, b}}:
      act.after(p, b)
    case _ t:
      t

def act.ps.ctx(r: ActPs) -> List<&2, T.Bt>:
  match r:
    case ActPs{ps, ret, ctx, es, ok}:
      ctx

def act.ps.names(ps: List<&2, T.BParam>) -> List<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      Nil{}
    case T.BParam{m, x, ty} <> t:
      x <> act.ps.names(t)

def act.ctor.of(s: ActSym, +pars: Nat, +t: A.Ag, +env: ActEnv, +ixs: List<&2, T.BParam>) -> T.BCtor:
  match s:
    case ActSym{m, n, k, ms, ar, b, fs, c, cp}:
      T.BCtor{n, act.cfields(act.after(pars, t), act.ps.ctx(act.params(64n, pars, t, act.modes(t, True{}), Nil{}, env)), act.ps.names(ixs), env, ixs, pars)}

def act.decl.got(r: Map<&2, A.AgDecl> & A.AgDecl) -> A.AgDecl:
  (m, d) = r
  d

def act.decl0() -> A.AgDecl:
  A.AgDecl{A.AgQ{Nil{}, Nil{}, Nil{}}, Nil{}, Nil{}, Nil{}, 0n, 0n, 0n, A.AkWord{}, A.aas.i.vis(), Nil{}, A.AkWord{}, A.AgNone{}, A.AgDOther{A.AxNil{}}}

def act.ctor(d: A.AgDecl, +pars: Nat, +env: ActEnv, +ixs: List<&2, T.BParam>) -> T.BCtor:
  match d:
    case A.AgDecl{q, qn, md, f, l, l0, l1, k, m, fl, lang, ty, dd}:
      act.ctor.of(act.sym(env, q), pars, act.inline(100000n, ty, env), env, ixs)

def act.ctors(ks: List<&2, String>, +pars: Nat, +env: ActEnv, +decls: Map<&2, A.AgDecl>, +ixs: List<&2, T.BParam>) -> List<&2, T.BCtor>:
  match ks:
    case Nil{}:
      Nil{}
    case k <> t:
      act.ctor(act.decl.got(Map.get(A.AgDecl, act.decl0(), decls, k)), pars, env, ixs) <> act.ctors(t, pars, env, decls, ixs)

# a field type a Data value may hold: Nat, Bool, Unit, an equation, or the
# type itself (by name, with no parameters)
def act.dataish(+self: List<&2, U32>, t: T.Bt) -> Bool:
  match t:
    case T.BtVar{+x}:
      Bool.or(Bool.or(S.eq(x, S.b("Nat")), S.eq(x, S.b("Bool"))), S.eq(x, S.b("Unit")))
    case T.BtTyApp{x, T.BtANil{}}:
      S.eq(x, self)
    case T.BtEq{ty, a, b}:
      True{}
    case _:
      False{}

def act.dataish.fs(+self: List<&2, U32>, fs: List<&2, T.BField>) -> Bool:
  match fs:
    case Nil{}:
      True{}
    case T.BField{x, ty} <> t:
      Bool.and(act.dataish(self, ty), act.dataish.fs(self, t))

def act.dataish.cs(+self: List<&2, U32>, cs: List<&2, T.BCtor>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case T.BCtor{c, fs} <> t:
      Bool.and(act.dataish.fs(self, fs), act.dataish.cs(self, t))

def act.ps.take(n: Nat, ps: List<&2, T.BParam>) -> List<&2, T.BParam>:
  match n ps:
    case 1n+p h <> t:
      h <> act.ps.take(p, t)
    case _ ps:
      Nil{}

# the last n of a list of parameters (an indexed family's indices)
def act.ps.last(+n: Nat, ps: List<&2, T.BParam>) -> List<&2, T.BParam>:
  List.reverse(&2, T.BParam, act.ps.take(n, List.reverse(&2, T.BParam, ps)))

def act.item.data.of(+nm: List<&2, U32>, r: ActPs, +cs: List<&2, T.BCtor>, doc: List<&2, List<&2, U32>>) -> List<&2, T.BItem>:
  match r:
    case ActPs{+ps, ret, ctx, es, ok}:
      [T.BiType{nm, ps, act.kind.term(act.kind.cs(nm, cs, ps)), cs, doc}]

def act.item.data(s: ActSym, d: A.AgD, ty: A.Ag, +env: ActEnv, +decls: Map<&2, A.AgDecl>, doc: List<&2, List<&2, U32>>) -> List<&2, T.BItem>:
  match s d:
    case ActSym{m, +n, k, +ms, ar, b, fs, c, cp} A.AgDData{+pars, +ixs, cons, sort, dcl}:
      +t = act.inline(100000n, ty, env)
      +r = act.params(64n, Nat.add(pars, ixs), t, ms, Nil{}, env)
      act.item.data.of(n, r, act.ctors(act.keys(cons), pars, env, decls, act.ps.last(ixs, act.ps.ps(r))), doc)
    case _ _:
      Nil{}

# The items of one definition: a function's def, a record's or data
# type's type; nothing for a constructor (its type has it), a copy (it is
# inlined where used), a Level name or a builtin (Base has it), or one of
# the transp and hcomp helpers --cubical-compatible generates (no-compilation).
def act.items.of(s: ActSym, k: A.AgKw, cp: Bool, nc: Bool, d: A.AgD, +key: String, ty: A.Ag, +env: ActEnv, +decls: Map<&2, A.AgDecl>, doc: List<&2, List<&2, U32>>) -> List<&2, T.BItem>:
  match s k cp nc:
    case s _ True{} _:
      Nil{}
    case s _ False{} True{}:
      Nil{}
    case ActSym{m, n, k2, ms, ar, AbNone{}, fs, c, cop} A.AkFunction{} False{} False{}:
      act.item.fun(ActSym{m, n, k2, ms, ar, AbNone{}, fs, c, cop}, d, key, ty, env, doc)
    case ActSym{m, n, k2, ms, ar, AbNone{}, fs, c, cop} A.AkRecord{} False{} False{}:
      act.item.rec(ActSym{m, n, k2, ms, ar, AbNone{}, fs, c, cop}, d, env, doc)
    case ActSym{m, n, k2, ms, ar, AbNone{}, fs, c, cop} A.AkData{} False{} False{}:
      act.item.data(ActSym{m, n, k2, ms, ar, AbNone{}, fs, c, cop}, d, ty, env, decls, doc)
    case ActSym{m, n, k2, ms, ar, AbNone{}, fs, c, cop} A.AkPostulate{} False{} False{}:
      [T.BiComment{List.append(&2, List<&2, U32>, doc, [S.b("a postulate: not translated (Bend has none)")])}]
    case _ _ _ _:
      Nil{}

# whether a symbol is inlined where used (a copy, or made one)
def act.sym.copied(s: ActSym) -> Bool:
  match s:
    case ActSym{m, n, k, ms, ar, b, fs, c, cp}:
      act.copy.is(cp)

def act.items(d: A.AgDecl, +env: ActEnv, +decls: Map<&2, A.AgDecl>) -> List<&2, T.BItem>:
  match d:
    case A.AgDecl{+q, qn, md, +f, +l, l0, l1, k, m, +fl, lang, ty, dd}:
      act.items.of(act.sym(env, q), k, Bool.or(act.flag(A.AkCopy{}, fl), act.sym.copied(act.sym(env, q))), act.flag(A.AkNoCompilation{}, fl), dd, act.key(q), ty, env, decls, act.doc(act.qs(q), f, l))

# A type-valued function whose case tree is one leaf (no split): it
# unfolds, as a copy does, when a header needs the Pis behind it.
def act.unf.d(cp: Bool, srt: Bool, d: A.AgD) -> Maybe<&2, ActCopy>:
  match cp srt d:
    case False{} True{} A.AgDFun{A.AgPrNone{}, r, w, e, t, mu, cls, A.AgDone{xs, body}}:
      Some{ActCopy{act.vars.len(xs), body}}
    case _ _ _:
      None{}

# a definition's opening, when it is a type-valued one (unf: the earlier ones)
def act.unf.of(d: A.AgDecl, +unf: Map<&2, ActCopy>) -> Maybe<&2, ActCopy>:
  match d:
    case A.AgDecl{q, qn, md, f, l, l0, l1, k, m, fl, lang, +ty, dd}:
      act.unf.d(act.flag(A.AkCopy{}, fl), act.ends.sort.u(8n, ty, unf), dd)

# A definition's eta unfolding (see act.etu.key): its case tree walked with
# the terms its leaf's variables stand for, over its n parameters; a split
# of a parameter whose type is a record with eta puts the record's
# projections of it in its place.  Anything else (a data split, a nested
# split, a catch-all, no split at all) has none.

# a record type's fields and arguments (the record found through
# type-valued definitions: A × B is Σ A (λ _ → B))
type ActRec is Data:
  ActRec{fs: List<&2, String>, es: A.Ag, ok: Bool}

# (the record by its symbol: the module's own declarations are all the
# decl map has, and Σ is Agda.Builtin.Sigma's; a split's eta branch already
# says the record has eta).  A record a module application copied is not
# taken: its fields are copies Bend has no names for (Core's `open import
# Categories.Morphism.IsoEquiv 𝒞` copies `_≃_`, 2026-10-21); the copy's
# clause leads to the original instead (act.etu.leaf)
def act.etu.rec.fs(s: ActSym, es: A.Ag) -> ActRec:
  match s:
    case ActSym{m, n, A.AkRecord{}, ms, ar, b, fs, c, None{}}:
      ActRec{fs, es, True{}}
    case _:
      ActRec{Nil{}, A.AgENil{}, False{}}

# what a name unfolds to: a copy's clause, else its leaf in the unfoldings
def act.etu.leaf(s: ActSym, +unf: Map<&2, ActCopy>, +q: A.AgQ) -> ActCopy:
  match s:
    case ActSym{m, n, k, ms, ar, b, fs, c, Some{cp}}:
      cp
    case _:
      act.unf.got(Map.get(ActCopy, ActCopy{0n, A.AgNone{}}, unf, act.key(q)))

def act.etu.rec.pick(a: ActRec, b: ActRec) -> ActRec:
  match a:
    case ActRec{fs, es, True{}}:
      ActRec{fs, es, True{}}
    case _:
      b

def act.etu.rec(fuel: Nat, t: A.Ag, +tab: Map<&2, ActSym>, +unf: Map<&2, ActCopy>) -> ActRec:
  match fuel t:
    case f A.AgEl{s, x}:
      act.etu.rec(f, x, tab, unf)
    case 1n+f A.AgDef{+q, +es}:
      act.etu.rec.pick(act.etu.rec.fs(act.sym.got(Map.get(ActSym, act.sym0(), tab, act.key(q))), es), act.etu.rec(f, act.unfold.of(act.etu.leaf(act.sym.got(Map.get(ActSym, act.sym0(), tab, act.key(q))), unf, q), es), tab, unf))
    case _ _:
      ActRec{Nil{}, A.AgENil{}, False{}}

# a name from its key (w:k), the only part a translation looks up
def act.q.parts(ps: List<&2, List<&2, U32>>) -> A.AgQ:
  match ps:
    case w <> k <> Nil{}:
      A.AgQ{Nil{}, w, k}
    case _:
      A.AgQ{Nil{}, Nil{}, Nil{}}

def act.q.of.key(k: String) -> A.AgQ:
  act.q.parts(S.split(S.b(k), 58))

# each field's projection of p (the record's arguments, then p)
def act.etu.projs(fs: List<&2, String>, +es: A.Ag, +p: A.Ag) -> List<&2, A.Ag>:
  match fs:
    case q <> rest:
      A.AgDef{act.q.of.key(q), asb.elims.cat(es, A.AgEApp{A.aas.i.vis(), p, A.AgENil{}})} <> act.etu.projs(rest, es, p)
    case _:
      Nil{}

def act.etu.len.ok(+xs: List<&2, A.Ag>, +nf: Nat) -> List<&2, A.Ag>:
  Bool.pick(List<&2, A.Ag>, Nat.is_eq(List.length(&2, A.Ag, xs), nf), xs, [A.AgNone{}])

def act.etu.fields.of(r: ActRec, +p: A.Ag, +nf: Nat) -> List<&2, A.Ag>:
  match r:
    case ActRec{fs, +es, True{}}:
      act.etu.len.ok(act.etu.projs(fs, es, p), nf)
    case _:
      [A.AgNone{}]

def act.etu.dom(m: Maybe<&2, A.Ag>) -> A.Ag:
  match m:
    case Some{d}:
      d
    case None{}:
      A.AgNone{}

# the fields a split puts in place of the term it splits (a parameter)
def act.etu.fields(m: Maybe<&2, A.Ag>, +nf: Nat, +doms: List<&2, A.Ag>, +n: Nat, +unf: Map<&2, ActCopy>, +tab: Map<&2, ActSym>) -> List<&2, A.Ag>:
  match m:
    case Some{A.AgVar{+vi, x, A.AgENil{}}}:
      act.etu.fields.of(act.etu.rec(8n, act.etu.dom(asb.nth(Nat.sub(Nat.sub(n, 1n), vi), doms)), tab, unf), A.AgVar{vi, x, A.AgENil{}}, nf)
    case _:
      [A.AgNone{}]

def act.etu.at.k(+k: Nat, +nf: Nat, +terms: List<&2, A.Ag>, +doms: List<&2, A.Ag>, +n: Nat, +unf: Map<&2, ActCopy>, +tab: Map<&2, ActSym>) -> List<&2, A.Ag>:
  List.append(&2, A.Ag, List.take(&2, A.Ag, terms, k), List.append(&2, A.Ag, act.etu.fields(asb.nth(k, terms), nf, doms, n, unf, tab), List.drop(&2, A.Ag, terms, 1n+k)))

def act.etu.ok(ts: List<&2, A.Ag>) -> Bool:
  match ts:
    case Nil{}:
      True{}
    case A.AgNone{} <> t:
      False{}
    case h <> t:
      act.etu.ok(t)

def act.etu.done.ok(ok: Bool, +n: Nat, body: A.Ag, +terms: List<&2, A.Ag>) -> Maybe<&2, ActCopy>:
  match ok:
    case True{}:
      Some{ActCopy{n, asb.subst(body, 0n, List.reverse(&2, A.Ag, terms), List.length(&2, A.Ag, terms))}}
    case False{}:
      None{}

def act.etu.done(split: Bool, +n: Nat, body: A.Ag, +terms: List<&2, A.Ag>) -> Maybe<&2, ActCopy>:
  match split:
    case True{}:
      act.etu.done.ok(act.etu.ok(terms), n, body, terms)
    case False{}:
      None{}

def act.etu.tree(fuel: Nat, tree: A.Ag, +terms: List<&2, A.Ag>, +doms: List<&2, A.Ag>, +n: Nat, split: Bool, +unf: Map<&2, ActCopy>, +tab: Map<&2, ActSym>) -> Maybe<&2, ActCopy>:
  match fuel tree:
    case 1n+f A.AgCase{i, +k, A.AgBranches{False{}, A.AgBEnd{}, A.AgBr{cq, +nf, sub, A.AgBEnd{}}, A.AgBEnd{}, A.AgNone{}}}:
      act.etu.tree(f, sub, act.etu.at.k(k, nf, terms, doms, n, unf, tab), doms, n, True{}, unf, tab)
    case f A.AgDone{xs, body}:
      act.etu.done(split, n, body, terms)
    case _ _:
      None{}

# the parameters' terms: var n-1 (the first) ... var 0
def act.etu.init(k: Nat) -> List<&2, A.Ag>:
  match k:
    case 0n:
      Nil{}
    case 1n+(+p):
      A.AgVar{p, S.b("x"), A.AgENil{}} <> act.etu.init(p)

# the variables, among n parameters, of the dependent binders at positions ps
def act.etu.vs(ps: List<&2, Nat>, +n: Nat) -> List<&2, A.Ag>:
  match ps:
    case Nil{}:
      Nil{}
    case p <> t:
      A.AgVar{Nat.sub(Nat.sub(n, 1n), p), S.b("x"), A.AgENil{}} <> act.etu.vs(t, n)

def act.etu.dep(d: Bool, +j: Nat, deps: List<&2, Nat>) -> List<&2, Nat>:
  match d:
    case True{}:
      j <> deps
    case False{}:
      deps

# each Pi's domain in the scope of all n parameters (a non-dependent Pi
# binds no variable, so each domain is renamed, not shifted)
def act.etu.doms(t: A.Ag, +j: Nat, +n: Nat, +deps: List<&2, Nat>) -> List<&2, A.Ag>:
  match t:
    case A.AgEl{s, x}:
      act.etu.doms(x, j, n, deps)
    case A.AgPi{i, x, a, +d, b}:
      asb.subst(a, 0n, act.etu.vs(deps, n), List.length(&2, Nat, deps)) <> act.etu.doms(b, 1n+j, n, act.etu.dep(d, j, deps))
    case _:
      Nil{}

def act.etu.go(skip: Bool, +n: Nat, +ty: A.Ag, tree: A.Ag, +unf: Map<&2, ActCopy>, +tab: Map<&2, ActSym>) -> Maybe<&2, ActCopy>:
  match skip:
    case True{}:
      None{}
    case False{}:
      act.etu.tree(64n, tree, act.etu.init(n), act.etu.doms(ty, 0n, n, Nil{}), n, False{}, unf, tab)

# a function's eta unfolding (not a projection, a copy or a type-valued one)
def act.etu.of(d: A.AgDecl, +unf: Map<&2, ActCopy>, +tab: Map<&2, ActSym>) -> Maybe<&2, ActCopy>:
  match d:
    case A.AgDecl{q, qn, md, f, l, l0, l1, k, m, +fl, lang, +ty, A.AgDFun{A.AgPrNone{}, r, w, e, t, mu, cls, tree}}:
      act.etu.go(Bool.or(act.flag(A.AkCopy{}, fl), act.ends.sort(ty)), act.cls.arity(cls), ty, tree, unf, tab)
    case _:
      None{}

# a copattern definition's field clauses into the unfoldings (see
# act.cop.key): a tree that splits its result by copatterns first, each
# field a leaf (a field taking more patterns has none)
def act.cop.brs(+dq: A.AgQ, brs: A.Ag, u: Map<&2, ActCopy>) -> Map<&2, ActCopy>:
  match brs:
    case A.AgBr{fq, k, A.AgDone{xs, body}, rest}:
      act.cop.brs(dq, rest, Map.set(&2, ActCopy, u, act.cop.key(dq, fq), ActCopy{act.vars.len(xs), body}))
    case A.AgBr{fq, k, t, rest}:
      act.cop.brs(dq, rest, u)
    case _:
      u

def act.cop.add(d: A.AgDecl, unf: Map<&2, ActCopy>) -> Map<&2, ActCopy>:
  match d:
    case A.AgDecl{q, qn, md, f, l, l0, l1, k, m, fl, lang, ty, A.AgDFun{p, r, w, e, t, mu, cls, A.AgCase{i, n, A.AgBranches{True{}, brs, eta, lits, ca}}}}:
      act.cop.brs(q, brs, unf)
    case _:
      unf

# A record field's projection, for the quantity pass's destructuring
# (ToBend/Copy.bend): its record's module and constructor (Bend names), the
# field's index and the field count; ok False for any other definition.
type ActPj is Data:
  ActPj{cmod: List<&2, U32>, ctor: List<&2, U32>, i: Nat, k: Nat, ok: Bool}

def act.pj.rec(s: ActSym, +key: String) -> ActPj:
  match s:
    case ActSym{m, n, A.AkRecord{}, ms, ar, b, +fs, c, cp}:
      ActPj{m, c, act.key.pos(key, fs), List.length(&2, String, fs), True{}}
    case _:
      ActPj{Nil{}, Nil{}, 0n, 0n, False{}}

def act.pj.of(d: A.AgDecl, +tab: Map<&2, ActSym>) -> ActPj:
  match d:
    case A.AgDecl{+q, qn, md, f, l, l0, l1, k, m, fl, lang, ty, A.AgDFun{A.AgPrOf{Some{r}, o, ix}, rs, w, e, t, mu, cls, tree}}:
      act.pj.rec(act.sym.got(Map.get(ActSym, act.sym0(), tab, act.key(r))), act.key(q))
    case _:
      ActPj{Nil{}, Nil{}, 0n, 0n, False{}}

# The quantity pass's modes put back into a symbol --------------------------------

def act.m.code(m: ActM) -> Nat:
  match m:
    case AmDrop{}:
      0n
    case AmErased{}:
      1n
    case AmLive{}:
      2n
    case AmCopy{}:
      3n
    case AmTpl{}:
      4n

type ActRe is Data:
  ActRe{ms: List<&2, ActM>, changed: Bool}

def act.re.put(m: ActM, r: ActRe, ch: Bool) -> ActRe:
  match r:
    case ActRe{ms, c}:
      ActRe{m <> ms, Bool.or(c, ch)}

# past the header, the modes Copy gives the return type's Pis the body's
# lambdas bind (a lowered point of `step-≈-⟩`), on the modes after the arity
def act.remode.rest(ms: List<&2, ActM>, hdr: List<&2, T.BMode>) -> ActRe:
  match ms hdr:
    case AmDrop{} <> t hdr:
      act.re.put(AmDrop{}, act.remode.rest(t, hdr), False{})
    case +m <> t h <> ht:
      +n = act.m.of(h)
      act.re.put(n, act.remode.rest(t, ht), Bool.not(Nat.is_eq(act.m.code(m), act.m.code(n))))
    case ms Nil{}:
      ActRe{ms, False{}}
    case Nil{} hdr:
      ActRe{Nil{}, False{}}

# A symbol's modes with its header's (the first ar parameters, the dropped
# ones skipped) replaced by the pass's; changed says whether any differs.
# A header longer than the modes (its type a definition the header opened
# to reach more Pis) adds the rest, which callers otherwise take as live.
def act.remode(ar: Nat, ms: List<&2, ActM>, hdr: List<&2, T.BMode>) -> ActRe:
  match ar ms hdr:
    case 0n ms hdr:
      act.remode.rest(ms, hdr)
    case 1n+p AmDrop{} <> t hdr:
      act.re.put(AmDrop{}, act.remode(p, t, hdr), False{})
    case 1n+p +m <> t h <> ht:
      +n = act.m.of(h)
      act.re.put(n, act.remode(p, t, ht), Bool.not(Nat.is_eq(act.m.code(m), act.m.code(n))))
    case 1n+p m <> t Nil{}:
      act.re.put(m, act.remode(p, t, Nil{}), False{})
    case 1n+p Nil{} h <> ht:
      +n = act.m.of(h)
      act.re.put(n, act.remode(p, Nil{}, ht), Bool.not(Nat.is_eq(act.m.code(n), 2n)))
    case 1n+p Nil{} Nil{}:
      ActRe{Nil{}, False{}}

def act.sym.remode.of(s: ActSym, r: ActRe) -> ActSym & Bool:
  match s r:
    case ActSym{m, n, k, x, ar, b, fs, c, cp} ActRe{ms, ch}:
      (ActSym{m, n, k, ms, ar, b, fs, c, cp}, ch)


# a symbol with new modes
def act.sym.remode(s: ActSym, hdr: List<&2, T.BMode>) -> ActSym & Bool:
  match s:
    case ActSym{m, n, k, ms, +ar, b, fs, c, cp}:
      act.sym.remode.of(ActSym{m, n, k, Nil{}, ar, b, fs, c, cp}, act.remode(ar, ms, hdr))