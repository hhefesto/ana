import Base
import ./Algebra.bend as Al
# AD/Reverse.agda: dual maps and augmented reverse derivatives.
#
# An additive map preserves zero and addition; a dual map runs the other
# way; an augmented reverse derivative returns the primal value and the
# pullback (a dual map) at a point.  Composition and pairing of reverse
# derivatives obey the chain rules below.
#
# Maps are ordinary values here: their laws are ERASED fields, so a map's
# function can be used once live and freely inside its own proofs.  The
# monoids are template arguments (their operations run).
type AMap<-A: Data, -B: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>> is Type:
  AMap{apply: A -> B,
       -pz: {apply(Al.MO.zero(A, ma)) == Al.MO.zero(B, mb) : B},
       -pa: @+x:A -> @+y:A -> {apply(Al.MO.add(A, ma)(x, y)) == Al.MO.add(B, mb)(apply(x), apply(y)) : B}}

def AMap.apply(-A: Data, -B: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>, m: AMap<A, B, ma, mb>) -> A -> B:
  match m:
    case AMap{f, z, p}:
      f

law id.pa:
  for -A: Data
  for -ma: Al.Monoid<A>
  for +x: A
  for +y: A
  {Al.MO.add(A, ma)(x, y) == Al.MO.add(A, ma)(x, y) : A}

def id.pa(A, ma, x, y):
  {==}

def identityMap(-A: Data, -ma: Al.Monoid<A>) -> AMap<A, A, ma, ma>:
  AMap{x => x, {==}, x => y => {==}}

# g after f
def composeMap(-A: Data, -B: Data, -C: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>, -mc: Al.Monoid<C>,
               g: AMap<B, C, mb, mc>, f: AMap<A, B, ma, mb>) -> AMap<A, C, ma, mc>:
  match g f:
    case AMap{ga, gz, gp} AMap{fa, fz, fp}:
      AMap{x => ga(fa(x)),
        Equal.trans(C, ga(fa(Al.MO.zero(A, ma))), ga(Al.MO.zero(B, mb)), Al.MO.zero(C, mc),
          Equal.cong(B, C, ga, fa(Al.MO.zero(A, ma)), Al.MO.zero(B, mb), fz), gz),
        x => y => Equal.trans(C, ga(fa(Al.MO.add(A, ma)(x, y))), ga(Al.MO.add(B, mb)(fa(x), fa(y))), Al.MO.add(C, mc)(ga(fa(x)), ga(fa(y))),
          Equal.cong(B, C, ga, fa(Al.MO.add(A, ma)(x, y)), Al.MO.add(B, mb)(fa(x), fa(y)), fp(x, y)), gp(fa(x), fa(y)))}

# A dual map reverses the primal direction.
def Dual(-A: Data, -B: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>) -> Type:
  AMap<B, A, mb, ma>

# The product monoid ----------------------------------------------------

type P2<-A: Data, -B: Data> is Data:
  P2{a: A, b: B}

def P2.a(-A: Data, -B: Data, p: P2<A, B>) -> A:
  match p:
    case P2{a, b}:
      a

def P2.b(-A: Data, -B: Data, p: P2<A, B>) -> B:
  match p:
    case P2{a, b}:
      b

def prod.add(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, +p: P2<A, B>, +q: P2<A, B>) -> P2<A, B>:
  P2{Al.MO.add(A, ma)(P2.a(A, B, p), P2.a(A, B, q)), Al.MO.add(B, mb)(P2.b(A, B, p), P2.b(A, B, q))}

def cong2(-A: Data, -B: Data, -a: A, -a2: A, -b: B, -b2: B, +e: {a == a2 : A}, +f: {b == b2 : B}) ->
    {P2{a, b} == P2{a2, b2} : P2<A, B>}:
  %e : {P2{a, b} == P2{_, b2} : P2<A, B>}
  %f : {P2{a, b} == P2{a, _} : P2<A, B>}
  {==}

def prod.assoc(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, +x: P2<A, B>, +y: P2<A, B>, +z: P2<A, B>) ->
    {prod.add(~A, ~B, ~ma, ~mb, prod.add(~A, ~B, ~ma, ~mb, x, y), z) == prod.add(~A, ~B, ~ma, ~mb, x, prod.add(~A, ~B, ~ma, ~mb, y, z)) : P2<A, B>}:
  +a1 = P2.a(A, B, x)
  +a2 = P2.a(A, B, y)
  +a3 = P2.a(A, B, z)
  +b1 = P2.b(A, B, x)
  +b2 = P2.b(A, B, y)
  +b3 = P2.b(A, B, z)
  cong2(A, B, Al.MO.add(A, ma)(Al.MO.add(A, ma)(a1, a2), a3), Al.MO.add(A, ma)(a1, Al.MO.add(A, ma)(a2, a3)),
        Al.MO.add(B, mb)(Al.MO.add(B, mb)(b1, b2), b3), Al.MO.add(B, mb)(b1, Al.MO.add(B, mb)(b2, b3)),
        Al.MO.add_assoc(A, ma, a1, a2, a3), Al.MO.add_assoc(B, mb, b1, b2, b3))

def prod.comm(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, +x: P2<A, B>, +y: P2<A, B>) ->
    {prod.add(~A, ~B, ~ma, ~mb, x, y) == prod.add(~A, ~B, ~ma, ~mb, y, x) : P2<A, B>}:
  +a1 = P2.a(A, B, x)
  +a2 = P2.a(A, B, y)
  +b1 = P2.b(A, B, x)
  +b2 = P2.b(A, B, y)
  cong2(A, B, Al.MO.add(A, ma)(a1, a2), Al.MO.add(A, ma)(a2, a1), Al.MO.add(B, mb)(b1, b2), Al.MO.add(B, mb)(b2, b1),
        Al.MO.add_comm(A, ma, a1, a2), Al.MO.add_comm(B, mb, b1, b2))

def prod.zero_l(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, +x: P2<A, B>) ->
    {prod.add(~A, ~B, ~ma, ~mb, P2{Al.MO.zero(A, ma), Al.MO.zero(B, mb)}, x) == x : P2<A, B>}:
  match x:
    case P2{+a, +b}:
      cong2(A, B, Al.MO.add(A, ma)(Al.MO.zero(A, ma), a), a, Al.MO.add(B, mb)(Al.MO.zero(B, mb), b), b,
            Al.MO.add_zero_l(A, ma, a), Al.MO.add_zero_l(B, mb, b))

def productMonoid(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>) -> Al.Monoid<P2<A, B>>:
  Al.Monoid{P2{Al.MO.zero(A, ma), Al.MO.zero(B, mb)}, p => q => prod.add(~A, ~B, ~ma, ~mb, p, q),
    x => y => z => prod.assoc(~A, ~B, ~ma, ~mb, x, y, z), x => y => prod.comm(~A, ~B, ~ma, ~mb, x, y), x => prod.zero_l(~A, ~B, ~ma, ~mb, x)}

def sumPullbacks.apply(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, fa: B -> A, ga: C -> A, +p: P2<B, C>) -> A:
  Al.MO.add(A, ma)(fa(P2.a(B, C, p)), ga(P2.b(B, C, p)))

def add.cong2(~A: Data, ~ma: Al.Monoid<A>, -x1: A, -x2: A, -y1: A, -y2: A, +e: {x1 == x2 : A}, +f: {y1 == y2 : A}) ->
    {Al.MO.add(A, ma)(x1, y1) == Al.MO.add(A, ma)(x2, y2) : A}:
  %e : {Al.MO.add(A, ma)(x1, y1) == Al.MO.add(A, ma)(_, y2) : A}
  %f : {Al.MO.add(A, ma)(x1, y1) == Al.MO.add(A, ma)(x1, _) : A}
  {==}

# Pullbacks from two components sum into the shared source.
def sumPullbacks(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
                 f: AMap<B, A, mb, ma>, g: AMap<C, A, mc, ma>) -> AMap<P2<B, C>, A, productMonoid(~B, ~C, ~mb, ~mc), ma>:
  match f g:
    case AMap{fa, fz, fp} AMap{ga, gz, gp}:
      AMap{p => sumPullbacks.apply(~A, ~B, ~C, ~ma, fa, ga, p),
        Equal.trans(A, Al.MO.add(A, ma)(fa(Al.MO.zero(B, mb)), ga(Al.MO.zero(C, mc))), Al.MO.add(A, ma)(Al.MO.zero(A, ma), Al.MO.zero(A, ma)), Al.MO.zero(A, ma),
          add.cong2(~A, ~ma, fa(Al.MO.zero(B, mb)), Al.MO.zero(A, ma), ga(Al.MO.zero(C, mc)), Al.MO.zero(A, ma), fz, gz),
          Al.MO.add_zero_l(A, ma, Al.MO.zero(A, ma))),
        x => y => Equal.trans(A,
          Al.MO.add(A, ma)(fa(Al.MO.add(B, mb)(P2.a(B, C, x), P2.a(B, C, y))), ga(Al.MO.add(C, mc)(P2.b(B, C, x), P2.b(B, C, y)))),
          Al.MO.add(A, ma)(Al.MO.add(A, ma)(fa(P2.a(B, C, x)), fa(P2.a(B, C, y))), Al.MO.add(A, ma)(ga(P2.b(B, C, x)), ga(P2.b(B, C, y)))),
          Al.MO.add(A, ma)(Al.MO.add(A, ma)(fa(P2.a(B, C, x)), ga(P2.b(B, C, x))), Al.MO.add(A, ma)(fa(P2.a(B, C, y)), ga(P2.b(B, C, y)))),
          add.cong2(~A, ~ma, fa(Al.MO.add(B, mb)(P2.a(B, C, x), P2.a(B, C, y))), Al.MO.add(A, ma)(fa(P2.a(B, C, x)), fa(P2.a(B, C, y))),
            ga(Al.MO.add(C, mc)(P2.b(B, C, x), P2.b(B, C, y))), Al.MO.add(A, ma)(ga(P2.b(B, C, x)), ga(P2.b(B, C, y))),
            fp(P2.a(B, C, x), P2.a(B, C, y)), gp(P2.b(B, C, x), P2.b(B, C, y))),
          Al.MO.interchange(~A, ~ma, fa(P2.a(B, C, x)), fa(P2.a(B, C, y)), ga(P2.b(B, C, x)), ga(P2.b(B, C, y))))}

type DP<-A: Data, -B: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>> is Type:
  DP{y: B, pull: AMap<B, A, mb, ma>}

def D(-A: Data, -B: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>) -> Type:
  A -> DP<A, B, ma, mb>

def DP.y(-A: Data, -B: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>, r: DP<A, B, ma, mb>) -> B:
  match r:
    case DP{y, p}:
      y

def DP.pull(-A: Data, -B: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>, r: DP<A, B, ma, mb>) -> AMap<B, A, mb, ma>:
  match r:
    case DP{y, p}:
      p

def identityD(-A: Data, -ma: Al.Monoid<A>) -> D(A, A, ma, ma):
  x => DP{x, identityMap(A, ma)}

def composeD.fin(-A: Data, -B: Data, -C: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>, -mc: Al.Monoid<C>,
                 s: DP<B, C, mb, mc>, fs: AMap<B, A, mb, ma>) -> DP<A, C, ma, mc>:
  match s:
    case DP{z, gs}:
      DP{z, composeMap(C, B, A, mc, mb, ma, fs, gs)}

def composeD.at(-A: Data, -B: Data, -C: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>, -mc: Al.Monoid<C>,
                g: D(B, C, mb, mc), r: DP<A, B, ma, mb>) -> DP<A, C, ma, mc>:
  match r:
    case DP{y, fs}:
      composeD.fin(A, B, C, ma, mb, mc, g(y), fs)

# g after f: the primal chains forward, the pullback backward
def composeD(-A: Data, -B: Data, -C: Data, -ma: Al.Monoid<A>, -mb: Al.Monoid<B>, -mc: Al.Monoid<C>,
             g: D(B, C, mb, mc), f: D(A, B, ma, mb)) -> D(A, C, ma, mc):
  x => composeD.at(A, B, C, ma, mb, mc, g, f(x))

def pairD.at(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
             r: DP<A, B, ma, mb>, s: DP<A, C, ma, mc>) -> DP<A, P2<B, C>, ma, productMonoid(~B, ~C, ~mb, ~mc)>:
  match r s:
    case DP{y, fs} DP{z, gs}:
      DP{P2{y, z}, sumPullbacks(~A, ~B, ~C, ~ma, ~mb, ~mc, fs, gs)}

def pairD.go(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
             f: D(A, B, ma, mb), g: D(A, C, ma, mc), +x: A) -> DP<A, P2<B, C>, ma, productMonoid(~B, ~C, ~mb, ~mc)>:
  pairD.at(~A, ~B, ~C, ~ma, ~mb, ~mc, f(x), g(x))

def pairD(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
          f: D(A, B, ma, mb), g: D(A, C, ma, mc)) -> D(A, P2<B, C>, ma, productMonoid(~B, ~C, ~mb, ~mc)):
  x => pairD.go(~A, ~B, ~C, ~ma, ~mb, ~mc, f, g, x)

# Chain rules --------------------------------------------------------------

law identity_chain:
  for -A: Data
  for -ma: Al.Monoid<A>
  for -x: A
  {DP.y(A, A, ma, ma, identityD(A, ma)(x)) == x : A}

def identity_chain(A, ma, x):
  {==}

law identity_pullback:
  for -A: Data
  for -ma: Al.Monoid<A>
  for -x: A
  for -dx: A
  {AMap.apply(A, A, ma, ma, DP.pull(A, A, ma, ma, identityD(A, ma)(x)))(dx) == dx : A}

def identity_pullback(A, ma, x, dx):
  {==}

law composition_primal.fin:
  for -A: Data
  for -B: Data
  for -C: Data
  for -ma: Al.Monoid<A>
  for -mb: Al.Monoid<B>
  for -mc: Al.Monoid<C>
  for s: DP<B, C, mb, mc>
  for -fs: AMap<B, A, mb, ma>
  {DP.y(A, C, ma, mc, composeD.fin(A, B, C, ma, mb, mc, s, fs)) == DP.y(B, C, mb, mc, s) : C}

def composition_primal.fin(A, B, C, ma, mb, mc, s, fs):
  match s:
    case DP{z, gs}:
      {==}

law composition_primal.at:
  for -A: Data
  for -B: Data
  for -C: Data
  for -ma: Al.Monoid<A>
  for -mb: Al.Monoid<B>
  for -mc: Al.Monoid<C>
  for g: D(B, C, mb, mc)
  for r: DP<A, B, ma, mb>
  {DP.y(A, C, ma, mc, composeD.at(A, B, C, ma, mb, mc, g, r)) == DP.y(B, C, mb, mc, g(DP.y(A, B, ma, mb, r))) : C}

def composition_primal.at(A, B, C, ma, mb, mc, g, r):
  match r:
    case DP{y, fs}:
      composition_primal.fin(A, B, C, ma, mb, mc, g(y), fs)

# the primal of a composite is the composite of primals
law composition_primal:
  for -A: Data
  for -B: Data
  for -C: Data
  for -ma: Al.Monoid<A>
  for -mb: Al.Monoid<B>
  for -mc: Al.Monoid<C>
  for f: D(A, B, ma, mb)
  for g: D(B, C, mb, mc)
  for x: A
  {DP.y(A, C, ma, mc, composeD(A, B, C, ma, mb, mc, g, f)(x)) == DP.y(B, C, mb, mc, g(DP.y(A, B, ma, mb, f(x)))) : C}

def composition_primal(A, B, C, ma, mb, mc, f, g, x):
  composition_primal.at(A, B, C, ma, mb, mc, g, f(x))

law composeMap.apply:
  for -A: Data
  for -B: Data
  for -C: Data
  for -ma: Al.Monoid<A>
  for -mb: Al.Monoid<B>
  for -mc: Al.Monoid<C>
  for f: AMap<B, A, mb, ma>
  for g: AMap<C, B, mc, mb>
  for -dz: C
  {AMap.apply(C, A, mc, ma, composeMap(C, B, A, mc, mb, ma, f, g))(dz) == AMap.apply(B, A, mb, ma, f)(AMap.apply(C, B, mc, mb, g)(dz)) : A}

def composeMap.apply(A, B, C, ma, mb, mc, f, g, dz):
  match f g:
    case AMap{fa, fz, fp} AMap{ga, gz, gp}:
      {==}

law composition_chain.fin:
  for -A: Data
  for -B: Data
  for -C: Data
  for -ma: Al.Monoid<A>
  for -mb: Al.Monoid<B>
  for -mc: Al.Monoid<C>
  for s: DP<B, C, mb, mc>
  for fs: AMap<B, A, mb, ma>
  for -dz: C
  {AMap.apply(C, A, mc, ma, DP.pull(A, C, ma, mc, composeD.fin(A, B, C, ma, mb, mc, s, fs)))(dz)
    == AMap.apply(B, A, mb, ma, fs)(AMap.apply(C, B, mc, mb, DP.pull(B, C, mb, mc, s))(dz)) : A}

def composition_chain.fin(A, B, C, ma, mb, mc, s, fs, dz):
  match s:
    case DP{z, gs}:
      composeMap.apply(A, B, C, ma, mb, mc, fs, gs, dz)

law composition_chain.at:
  for -A: Data
  for -B: Data
  for -C: Data
  for -ma: Al.Monoid<A>
  for -mb: Al.Monoid<B>
  for -mc: Al.Monoid<C>
  for g: D(B, C, mb, mc)
  for r: DP<A, B, ma, mb>
  for -dz: C
  {AMap.apply(C, A, mc, ma, DP.pull(A, C, ma, mc, composeD.at(A, B, C, ma, mb, mc, g, r)))(dz)
    == AMap.apply(B, A, mb, ma, DP.pull(A, B, ma, mb, r))(AMap.apply(C, B, mc, mb, DP.pull(B, C, mb, mc, g(DP.y(A, B, ma, mb, r))))(dz)) : A}

def composition_chain.at(A, B, C, ma, mb, mc, g, r, dz):
  match r:
    case DP{y, fs}:
      composition_chain.fin(A, B, C, ma, mb, mc, g(y), fs, dz)

# the pullback of a composite is the composite of pullbacks, reversed
law composition_chain:
  for -A: Data
  for -B: Data
  for -C: Data
  for -ma: Al.Monoid<A>
  for -mb: Al.Monoid<B>
  for -mc: Al.Monoid<C>
  for f: D(A, B, ma, mb)
  for g: D(B, C, mb, mc)
  for x: A
  for -dz: C
  {AMap.apply(C, A, mc, ma, DP.pull(A, C, ma, mc, composeD(A, B, C, ma, mb, mc, g, f)(x)))(dz)
    == AMap.apply(B, A, mb, ma, DP.pull(A, B, ma, mb, f(x)))(AMap.apply(C, B, mc, mb, DP.pull(B, C, mb, mc, g(DP.y(A, B, ma, mb, f(x)))))(dz)) : A}

def composition_chain(A, B, C, ma, mb, mc, f, g, x, dz):
  composition_chain.at(A, B, C, ma, mb, mc, g, f(x), dz)

# pairing: the primal is the pair, the pullback the sum of pullbacks
def pairing_primal.at(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
                      r: DP<A, B, ma, mb>, s: DP<A, C, ma, mc>) ->
    {DP.y(A, P2<B, C>, ma, productMonoid(~B, ~C, ~mb, ~mc), pairD.at(~A, ~B, ~C, ~ma, ~mb, ~mc, r, s)) == P2{DP.y(A, B, ma, mb, r), DP.y(A, C, ma, mc, s)} : P2<B, C>}:
  match r s:
    case DP{y, fs} DP{z, gs}:
      {==}

def pairing_chain.fin(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
                      fs: AMap<B, A, mb, ma>, gs: AMap<C, A, mc, ma>, +db: B, +dc: C) ->
    {AMap.apply(P2<B, C>, A, productMonoid(~B, ~C, ~mb, ~mc), ma, sumPullbacks(~A, ~B, ~C, ~ma, ~mb, ~mc, fs, gs))(P2{db, dc})
      == Al.MO.add(A, ma)(AMap.apply(B, A, mb, ma, fs)(db), AMap.apply(C, A, mc, ma, gs)(dc)) : A}:
  match fs gs:
    case AMap{fa, fz, fp} AMap{ga, gz, gp}:
      {==}

def pairing_chain.at(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
                     r: DP<A, B, ma, mb>, s: DP<A, C, ma, mc>, +db: B, +dc: C) ->
    {AMap.apply(P2<B, C>, A, productMonoid(~B, ~C, ~mb, ~mc), ma, DP.pull(A, P2<B, C>, ma, productMonoid(~B, ~C, ~mb, ~mc), pairD.at(~A, ~B, ~C, ~ma, ~mb, ~mc, r, s)))(P2{db, dc})
      == Al.MO.add(A, ma)(AMap.apply(B, A, mb, ma, DP.pull(A, B, ma, mb, r))(db), AMap.apply(C, A, mc, ma, DP.pull(A, C, ma, mc, s))(dc)) : A}:
  match r s:
    case DP{y, fs} DP{z, gs}:
      pairing_chain.fin(~A, ~B, ~C, ~ma, ~mb, ~mc, fs, gs, db, dc)

def pairing_primal(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
                   f: D(A, B, ma, mb), g: D(A, C, ma, mc), +x: A) ->
    {DP.y(A, P2<B, C>, ma, productMonoid(~B, ~C, ~mb, ~mc), pairD(~A, ~B, ~C, ~ma, ~mb, ~mc, f, g)(x)) == P2{DP.y(A, B, ma, mb, f(x)), DP.y(A, C, ma, mc, g(x))} : P2<B, C>}:
  pairing_primal.at(~A, ~B, ~C, ~ma, ~mb, ~mc, f(x), g(x))

def pairing_chain(~A: Data, ~B: Data, ~C: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~mc: Al.Monoid<C>,
                  f: D(A, B, ma, mb), g: D(A, C, ma, mc), +x: A, +db: B, +dc: C) ->
    {AMap.apply(P2<B, C>, A, productMonoid(~B, ~C, ~mb, ~mc), ma, DP.pull(A, P2<B, C>, ma, productMonoid(~B, ~C, ~mb, ~mc), pairD(~A, ~B, ~C, ~ma, ~mb, ~mc, f, g)(x)))(P2{db, dc})
      == Al.MO.add(A, ma)(AMap.apply(B, A, mb, ma, DP.pull(A, B, ma, mb, f(x)))(db), AMap.apply(C, A, mc, ma, DP.pull(A, C, ma, mc, g(x)))(dc)) : A}:
  pairing_chain.at(~A, ~B, ~C, ~ma, ~mb, ~mc, f(x), g(x), db, dc)

# Instances: pairing at the Nat and Bool monoids (the templates above are
# checked here).
law check.pairing:
  for f: D(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid())
  for g: D(Nat, Bool, Al.Nat.monoid(), Al.Bool.monoid())
  for +x: Nat
  for +db: Nat
  for +dc: Bool
  {AMap.apply(P2<Nat, Bool>, Nat, productMonoid(~Nat, ~Bool, ~Al.Nat.monoid(), ~Al.Bool.monoid()), Al.Nat.monoid(), DP.pull(Nat, P2<Nat, Bool>, Al.Nat.monoid(), productMonoid(~Nat, ~Bool, ~Al.Nat.monoid(), ~Al.Bool.monoid()), pairD(~Nat, ~Nat, ~Bool, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~Al.Bool.monoid(), f, g)(x)))(P2{db, dc})
      == Nat.add(AMap.apply(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid(), DP.pull(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid(), f(x)))(db), AMap.apply(Bool, Nat, Al.Bool.monoid(), Al.Nat.monoid(), DP.pull(Nat, Bool, Al.Nat.monoid(), Al.Bool.monoid(), g(x)))(dc)) : Nat}

def check.pairing(f, g, x, db, dc):
  pairing_chain(~Nat, ~Nat, ~Bool, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~Al.Bool.monoid(), f, g, x, db, dc)

law check.pairing_primal:
  for f: D(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid())
  for g: D(Nat, Bool, Al.Nat.monoid(), Al.Bool.monoid())
  for +x: Nat
  {DP.y(Nat, P2<Nat, Bool>, Al.Nat.monoid(), productMonoid(~Nat, ~Bool, ~Al.Nat.monoid(), ~Al.Bool.monoid()), pairD(~Nat, ~Nat, ~Bool, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~Al.Bool.monoid(), f, g)(x))
      == P2{DP.y(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid(), f(x)), DP.y(Nat, Bool, Al.Nat.monoid(), Al.Bool.monoid(), g(x))} : P2<Nat, Bool>}

def check.pairing_primal(f, g, x):
  pairing_primal(~Nat, ~Nat, ~Bool, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~Al.Bool.monoid(), f, g, x)
