# agda2bend milestone 0 (2026-10-18): agda-categories' core encoded in Bend 2 by hand, the
# target the emitter must reproduce from Agda's elaborated export. It prints ALL PROOFS CHECK
# under run/gcroot-bend/bin/bend (2.0.37). The rules it settled:
# - Levels are erased: Set ℓ is Type (Bend has one universe).
# - A record becomes a one-constructor `type X is Type:` with dependent fields in order, and
#   each field a projection def that matches once (its type names the earlier projections).
# - A record-valued parameter (a Category, a Functor) is a template `~C`, first in the list:
#   functions are Type and never copied, so a field used twice must come through the
#   projection of a closed template, each use a fresh copy (`f(f(x))` on a field is refused).
# - Objects and morphisms that occur only in types, erased arguments and equation endpoints
#   are erased binders `-a`; those are dead, so they may repeat freely.
# - The setoid's refl/sym/trans are IsEquivalence projections at one hom-set.
# - An equation {a == b : T} is Data (its evidence is erased), so it may be reused.
# - A law field over erased morphisms cannot be proven by induction on them (an erased
#   scrutinee matches only in a dead region); agda-categories' instances prove theirs
#   definitionally or from another category's laws, as endoCat below does.
import Base

# IsEquivalence (agda-stdlib Relation.Binary): R is reflexive, symmetric, transitive
type IsEquivalence<-A: Type, -R: A -> A -> Type> is Type:
  IsEquivalence{refl: @-x:A -> R(x, x), sym: @-x:A -> @-y:A -> R(x, y) -> R(y, x), trans: @-x:A -> @-y:A -> @-z:A -> R(x, y) -> R(y, z) -> R(x, z)}

def IsEquivalence.refl(-A: Type, -R: A -> A -> Type, e: IsEquivalence<A, R>) -> @-x:A -> R(x, x):
  match e:
    case IsEquivalence{refl, sym, trans}:
      refl

def IsEquivalence.sym(-A: Type, -R: A -> A -> Type, e: IsEquivalence<A, R>) -> @-x:A -> @-y:A -> R(x, y) -> R(y, x):
  match e:
    case IsEquivalence{refl, sym, trans}:
      sym

def IsEquivalence.trans(-A: Type, -R: A -> A -> Type, e: IsEquivalence<A, R>) -> @-x:A -> @-y:A -> @-z:A -> R(x, y) -> R(y, z) -> R(x, z):
  match e:
    case IsEquivalence{refl, sym, trans}:
      trans

# Category (agda-categories Categories.Category.Core, levels erased): hom-sets are setoids
type Category is Type:
  Category{Obj: Type, Hom: Obj -> Obj -> Type, Eq: @a:Obj -> @b:Obj -> Hom(a, b) -> Hom(a, b) -> Type, id: @-a:Obj -> Hom(a, a), comp: @-a:Obj -> @-b:Obj -> @-c:Obj -> Hom(b, c) -> Hom(a, b) -> Hom(a, c), assoc: @-a:Obj -> @-b:Obj -> @-c:Obj -> @-d:Obj -> @-f:Hom(a, b) -> @-g:Hom(b, c) -> @-h:Hom(c, d) -> Eq(a, d, comp(a, b, d, comp(b, c, d, h, g), f), comp(a, c, d, h, comp(a, b, c, g, f))), idl: @-a:Obj -> @-b:Obj -> @-f:Hom(a, b) -> Eq(a, b, comp(a, b, b, id(b), f), f), idr: @-a:Obj -> @-b:Obj -> @-f:Hom(a, b) -> Eq(a, b, comp(a, a, b, f, id(a)), f), equiv: @-a:Obj -> @-b:Obj -> IsEquivalence<Hom(a, b), Eq(a, b)>, resp: @-a:Obj -> @-b:Obj -> @-c:Obj -> @-f:Hom(b, c) -> @-h:Hom(b, c) -> @-g:Hom(a, b) -> @-i:Hom(a, b) -> Eq(b, c, f, h) -> Eq(a, b, g, i) -> Eq(a, c, comp(a, b, c, f, g), comp(a, b, c, h, i))}

def Cat.Obj(C: Category) -> Type:
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      Obj

def Cat.Hom(C: Category) -> Cat.Obj(C) -> Cat.Obj(C) -> Type:
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      Hom

def Cat.Eq(C: Category) -> @a:Cat.Obj(C) -> @b:Cat.Obj(C) -> Cat.Hom(C)(a, b) -> Cat.Hom(C)(a, b) -> Type:
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      Eq

def Cat.id(C: Category) -> @-a:Cat.Obj(C) -> Cat.Hom(C)(a, a):
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      id

def Cat.comp(C: Category) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-c:Cat.Obj(C) -> Cat.Hom(C)(b, c) -> Cat.Hom(C)(a, b) -> Cat.Hom(C)(a, c):
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      comp

def Cat.idl(C: Category) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-f:Cat.Hom(C)(a, b) -> Cat.Eq(C)(a, b, Cat.comp(C)(a, b, b, Cat.id(C)(b), f), f):
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      idl

def Cat.idr(C: Category) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-f:Cat.Hom(C)(a, b) -> Cat.Eq(C)(a, b, Cat.comp(C)(a, a, b, f, Cat.id(C)(a)), f):
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      idr

def Cat.equiv(C: Category) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> IsEquivalence<Cat.Hom(C)(a, b), Cat.Eq(C)(a, b)>:
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      equiv

def Cat.resp(C: Category) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-c:Cat.Obj(C) -> @-f:Cat.Hom(C)(b, c) -> @-h:Cat.Hom(C)(b, c) -> @-g:Cat.Hom(C)(a, b) -> @-i:Cat.Hom(C)(a, b) -> Cat.Eq(C)(b, c, f, h) -> Cat.Eq(C)(a, b, g, i) -> Cat.Eq(C)(a, c, Cat.comp(C)(a, b, c, f, g), Cat.comp(C)(a, b, c, h, i)):
  match C:
    case Category{Obj, Hom, Eq, id, comp, assoc, idl, idr, equiv, resp}:
      resp

# the setoid's refl, sym and trans at one hom-set
def Cat.refl(~C: Category, -a: Cat.Obj(C), -b: Cat.Obj(C), -f: Cat.Hom(C)(a, b)) -> Cat.Eq(C)(a, b, f, f):
  IsEquivalence.refl(Cat.Hom(C)(a, b), Cat.Eq(C)(a, b), Cat.equiv(C)(a, b))(f)

def Cat.sym(~C: Category, -a: Cat.Obj(C), -b: Cat.Obj(C), -f: Cat.Hom(C)(a, b), -g: Cat.Hom(C)(a, b), e: Cat.Eq(C)(a, b, f, g)) -> Cat.Eq(C)(a, b, g, f):
  IsEquivalence.sym(Cat.Hom(C)(a, b), Cat.Eq(C)(a, b), Cat.equiv(C)(a, b))(f, g, e)

def Cat.trans(~C: Category, -a: Cat.Obj(C), -b: Cat.Obj(C), -f: Cat.Hom(C)(a, b), -g: Cat.Hom(C)(a, b), -h: Cat.Hom(C)(a, b), e1: Cat.Eq(C)(a, b, f, g), e2: Cat.Eq(C)(a, b, g, h)) -> Cat.Eq(C)(a, b, f, h):
  IsEquivalence.trans(Cat.Hom(C)(a, b), Cat.Eq(C)(a, b), Cat.equiv(C)(a, b))(f, g, h, e1, e2)

# lemma (Categories.Category.Core ∘-resp-≈ˡ): f ≈ h → f ∘ g ≈ h ∘ g
def Cat.resp_l(~C: Category, -a: Cat.Obj(C), -b: Cat.Obj(C), -c: Cat.Obj(C), -f: Cat.Hom(C)(b, c), -h: Cat.Hom(C)(b, c), -g: Cat.Hom(C)(a, b), e: Cat.Eq(C)(b, c, f, h)) -> Cat.Eq(C)(a, c, Cat.comp(C)(a, b, c, f, g), Cat.comp(C)(a, b, c, h, g)):
  Cat.resp(C)(a, b, c, f, h, g, g, e, Cat.refl(~C, a, b, g))

# lemma (Morphism.Reasoning id-comm): f ∘ id ≈ id ∘ f, by identityʳ then identityˡ reversed
def Cat.id_comm(~C: Category, -a: Cat.Obj(C), -b: Cat.Obj(C), -f: Cat.Hom(C)(a, b)) -> Cat.Eq(C)(a, b, Cat.comp(C)(a, a, b, f, Cat.id(C)(a)), Cat.comp(C)(a, b, b, Cat.id(C)(b), f)):
  Cat.trans(~C, a, b, Cat.comp(C)(a, a, b, f, Cat.id(C)(a)), f, Cat.comp(C)(a, b, b, Cat.id(C)(b), f), Cat.idr(C)(a, b, f), Cat.sym(~C, a, b, Cat.comp(C)(a, b, b, Cat.id(C)(b), f), f, Cat.idl(C)(a, b, f)))

# Functor (agda-categories Categories.Functor.Core): maps objects and morphisms, keeps id, ∘ and ≈
type Functor<-C: Category, -D: Category> is Type:
  Functor{F0: Cat.Obj(C) -> Cat.Obj(D), F1: @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> Cat.Hom(C)(a, b) -> Cat.Hom(D)(F0(a), F0(b)), identity: @-a:Cat.Obj(C) -> Cat.Eq(D)(F0(a), F0(a), F1(a, a, Cat.id(C)(a)), Cat.id(D)(F0(a))), homomorphism: @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-c:Cat.Obj(C) -> @-f:Cat.Hom(C)(a, b) -> @-g:Cat.Hom(C)(b, c) -> Cat.Eq(D)(F0(a), F0(c), F1(a, c, Cat.comp(C)(a, b, c, g, f)), Cat.comp(D)(F0(a), F0(b), F0(c), F1(b, c, g), F1(a, b, f))), F_resp: @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-f:Cat.Hom(C)(a, b) -> @-g:Cat.Hom(C)(a, b) -> Cat.Eq(C)(a, b, f, g) -> Cat.Eq(D)(F0(a), F0(b), F1(a, b, f), F1(a, b, g))}

def Fun.F0(-C: Category, -D: Category, F: Functor<C, D>) -> Cat.Obj(C) -> Cat.Obj(D):
  match F:
    case Functor{F0, F1, identity, homomorphism, F_resp}:
      F0

def Fun.F1(-C: Category, -D: Category, F: Functor<C, D>) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> Cat.Hom(C)(a, b) -> Cat.Hom(D)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b)):
  match F:
    case Functor{F0, F1, identity, homomorphism, F_resp}:
      F1

def Fun.identity(-C: Category, -D: Category, F: Functor<C, D>) -> @-a:Cat.Obj(C) -> Cat.Eq(D)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(a), Fun.F1(C, D, F)(a, a, Cat.id(C)(a)), Cat.id(D)(Fun.F0(C, D, F)(a))):
  match F:
    case Functor{F0, F1, identity, homomorphism, F_resp}:
      identity

def Fun.homomorphism(-C: Category, -D: Category, F: Functor<C, D>) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-c:Cat.Obj(C) -> @-f:Cat.Hom(C)(a, b) -> @-g:Cat.Hom(C)(b, c) -> Cat.Eq(D)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(a, c, Cat.comp(C)(a, b, c, g, f)), Cat.comp(D)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(b, c, g), Fun.F1(C, D, F)(a, b, f))):
  match F:
    case Functor{F0, F1, identity, homomorphism, F_resp}:
      homomorphism

def Fun.F_resp(-C: Category, -D: Category, F: Functor<C, D>) -> @-a:Cat.Obj(C) -> @-b:Cat.Obj(C) -> @-f:Cat.Hom(C)(a, b) -> @-g:Cat.Hom(C)(a, b) -> Cat.Eq(C)(a, b, f, g) -> Cat.Eq(D)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F1(C, D, F)(a, b, f), Fun.F1(C, D, F)(a, b, g)):
  match F:
    case Functor{F0, F1, identity, homomorphism, F_resp}:
      F_resp

# the identity functor (Categories.Functor idF)
def Fun.idF(~C: Category) -> Functor<C, C>:
  Functor{x => x, a => b => f => f, a => Cat.refl(~C, a, a, Cat.id(C)(a)), a => b => c => f => g => Cat.refl(~C, a, c, Cat.comp(C)(a, b, c, g, f)), a => b => f => g => e => e}

# functor composition G ∘F F (Categories.Functor _∘F_): the laws by G's F-resp-≈ on F's law, then G's law
def Fun.compF(~C: Category, ~D: Category, ~E: Category, ~G: Functor<D, E>, ~F: Functor<C, D>) -> Functor<C, E>:
  Functor{
    x => Fun.F0(D, E, G)(Fun.F0(C, D, F)(x)),
    a => b => f => Fun.F1(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F1(C, D, F)(a, b, f)),
    a => Cat.trans(~E, Fun.F0(D, E, G)(Fun.F0(C, D, F)(a)), Fun.F0(D, E, G)(Fun.F0(C, D, F)(a)),
      Fun.F1(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(a), Fun.F1(C, D, F)(a, a, Cat.id(C)(a))),
      Fun.F1(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(a), Cat.id(D)(Fun.F0(C, D, F)(a))),
      Cat.id(E)(Fun.F0(D, E, G)(Fun.F0(C, D, F)(a))),
      Fun.F_resp(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(a), Fun.F1(C, D, F)(a, a, Cat.id(C)(a)), Cat.id(D)(Fun.F0(C, D, F)(a)), Fun.identity(C, D, F)(a)),
      Fun.identity(D, E, G)(Fun.F0(C, D, F)(a))),
    a => b => c => f => g => Cat.trans(~E, Fun.F0(D, E, G)(Fun.F0(C, D, F)(a)), Fun.F0(D, E, G)(Fun.F0(C, D, F)(c)),
      Fun.F1(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(a, c, Cat.comp(C)(a, b, c, g, f))),
      Fun.F1(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(c), Cat.comp(D)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(b, c, g), Fun.F1(C, D, F)(a, b, f))),
      Cat.comp(E)(Fun.F0(D, E, G)(Fun.F0(C, D, F)(a)), Fun.F0(D, E, G)(Fun.F0(C, D, F)(b)), Fun.F0(D, E, G)(Fun.F0(C, D, F)(c)), Fun.F1(D, E, G)(Fun.F0(C, D, F)(b), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(b, c, g)), Fun.F1(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F1(C, D, F)(a, b, f))),
      Fun.F_resp(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(a, c, Cat.comp(C)(a, b, c, g, f)), Cat.comp(D)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(b, c, g), Fun.F1(C, D, F)(a, b, f)), Fun.homomorphism(C, D, F)(a, b, c, f, g)),
      Fun.homomorphism(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F0(C, D, F)(c), Fun.F1(C, D, F)(a, b, f), Fun.F1(C, D, F)(b, c, g))),
    a => b => f => g => e => Fun.F_resp(D, E, G)(Fun.F0(C, D, F)(a), Fun.F0(C, D, F)(b), Fun.F1(C, D, F)(a, b, f), Fun.F1(C, D, F)(a, b, g), Fun.F_resp(C, D, F)(a, b, f, g, e))}

# a concrete category in agda-categories' style (its Sets): one object, the morphisms are the
# functions Nat -> Nat, composition is function composition, ≈ is pointwise equality

def pw_resp(-f: Nat -> Nat, -h: Nat -> Nat, -g: Nat -> Nat, -i: Nat -> Nat, e1: @-x:Nat -> {f(x) == h(x) : Nat}, e2: @-x:Nat -> {g(x) == i(x) : Nat}) -> @-x:Nat -> {f(g(x)) == h(i(x)) : Nat}:
  x => Equal.trans(Nat, f(g(x)), f(i(x)), h(i(x)), Equal.cong(Nat, Nat, f, g(x), i(x), e2(x)), e1(i(x)))

def endoCat() -> Category:
  Category{Unit, a => b => Nat -> Nat, a => b => f => g => @-x:Nat -> {f(x) == g(x) : Nat}, a => x => x, a => b => c => g => f => x => g(f(x)), a => b => c => d => f => g => h => x => {==}, a => b => f => x => {==}, a => b => f => x => {==}, a => b => IsEquivalence{f => x => {==}, f => g => e => x => Equal.sym(Nat, f(x), g(x), e(x)), f => g => h => e1 => e2 => x => Equal.trans(Nat, f(x), g(x), h(x), e1(x), e2(x))}, a => b => c => f => h => g => i => e1 => e2 => pw_resp(f, h, g, i, e1, e2)}

# the generic lemma id-comm at endoCat, on the morphism (x => 2x)
def double(n: Nat) -> Nat:
  match n:
    case 0n:
      0n
    case 1n+p:
      1n+1n+double(p)

def test_id_comm() -> Cat.Eq(endoCat())(Unit{}, Unit{}, Cat.comp(endoCat())(Unit{}, Unit{}, Unit{}, double, Cat.id(endoCat())(Unit{})), Cat.comp(endoCat())(Unit{}, Unit{}, Unit{}, Cat.id(endoCat())(Unit{}), double)):
  Cat.id_comm(~endoCat(), Unit{}, Unit{}, double)

# the composite of two identity functors sends double to double, pointwise at 3
def test_compF() -> {Fun.F1(endoCat(), endoCat(), Fun.compF(~endoCat(), ~endoCat(), ~endoCat(), ~Fun.idF(~endoCat()), ~Fun.idF(~endoCat())))(Unit{}, Unit{}, double)(3n) == 6n : Nat}:
  {==}
