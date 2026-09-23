import Base
import ./Algebra.bend as Al
import ./Reverse.bend as Rv
import ./Nat.bend as NL

# AD/Batch.agda: pullbacks accumulate over sums and batches.
#
# The micro-batch theorem: the pullback of a summed loss is the sum of the
# per-micro-batch pullbacks of one shared cotangent.  That is what licenses
# a trainer to accumulate gradients micro-batch by micro-batch and still
# take the gradient of the whole batch's loss.
#
# A batch is a family of reverse derivatives indexed by a list of indices
# (every finite list of maps is one); the family is a template, the index
# list an ordinary value, so each member can be evaluated as often as the
# statement mentions it.
# pointwise sum of additive maps sharing a source
def sumMaps.at(~A: Data, ~B: Data, ~mb: Al.Monoid<B>, fa: A -> B, ga: A -> B, +x: A) -> B:
  Al.MO.add(B, mb)(fa(x), ga(x))

def sumMaps(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>,
            f: Rv.AMap<A, B, ma, mb>, g: Rv.AMap<A, B, ma, mb>) -> Rv.AMap<A, B, ma, mb>:
  match f g:
    case Rv.AMap{fa, fz, fp} Rv.AMap{ga, gz, gp}:
      Rv.AMap{x => sumMaps.at(~A, ~B, ~mb, fa, ga, x),
        Equal.trans(B, Al.MO.add(B, mb)(fa(Al.MO.zero(A, ma)), ga(Al.MO.zero(A, ma))), Al.MO.add(B, mb)(Al.MO.zero(B, mb), Al.MO.zero(B, mb)), Al.MO.zero(B, mb),
          Rv.add.cong2(~B, ~mb, fa(Al.MO.zero(A, ma)), Al.MO.zero(B, mb), ga(Al.MO.zero(A, ma)), Al.MO.zero(B, mb), fz, gz),
          Al.MO.add_zero_l(B, mb, Al.MO.zero(B, mb))),
        x => y => Equal.trans(B,
          Al.MO.add(B, mb)(fa(Al.MO.add(A, ma)(x, y)), ga(Al.MO.add(A, ma)(x, y))),
          Al.MO.add(B, mb)(Al.MO.add(B, mb)(fa(x), fa(y)), Al.MO.add(B, mb)(ga(x), ga(y))),
          Al.MO.add(B, mb)(Al.MO.add(B, mb)(fa(x), ga(x)), Al.MO.add(B, mb)(fa(y), ga(y))),
          Rv.add.cong2(~B, ~mb, fa(Al.MO.add(A, ma)(x, y)), Al.MO.add(B, mb)(fa(x), fa(y)), ga(Al.MO.add(A, ma)(x, y)), Al.MO.add(B, mb)(ga(x), ga(y)), fp(x, y), gp(x, y)),
          Al.MO.interchange(~B, ~mb, fa(x), fa(y), ga(x), ga(y)))}

def zeroMap(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>) -> Rv.AMap<A, B, ma, mb>:
  Rv.AMap{x => Al.MO.zero(B, mb), {==},
    x => y => Equal.sym(B, Al.MO.add(B, mb)(Al.MO.zero(B, mb), Al.MO.zero(B, mb)), Al.MO.zero(B, mb), Al.MO.add_zero_l(B, mb, Al.MO.zero(B, mb)))}

def plusD.diag(~B: Data, +db: B) -> Rv.P2<B, B>:
  Rv.P2{db, db}

# the reverse derivative of addition: primal sum, pullback the diagonal
def plusD.at(~B: Data, ~mb: Al.Monoid<B>, +p: Rv.P2<B, B>) -> Rv.DP<Rv.P2<B, B>, B, Rv.productMonoid(~B, ~B, ~mb, ~mb), mb>:
  Rv.DP{Al.MO.add(B, mb)(Rv.P2.a(B, B, p), Rv.P2.b(B, B, p)), Rv.AMap{db => plusD.diag(~B, db), {==}, x => y => {==}}}

def plusD(~B: Data, ~mb: Al.Monoid<B>) -> Rv.D(Rv.P2<B, B>, B, Rv.productMonoid(~B, ~B, ~mb, ~mb), mb):
  p => plusD.at(~B, ~mb, p)

# the sum of two losses: primals add, pullbacks of ONE cotangent add
def addD.at(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, r: Rv.DP<A, B, ma, mb>, s: Rv.DP<A, B, ma, mb>) -> Rv.DP<A, B, ma, mb>:
  match r s:
    case Rv.DP{y1, f1} Rv.DP{y2, f2}:
      Rv.DP{Al.MO.add(B, mb)(y1, y2), sumMaps(~B, ~A, ~mb, ~ma, f1, f2)}

def zeroD.at(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>) -> Rv.DP<A, B, ma, mb>:
  Rv.DP{Al.MO.zero(B, mb), zeroMap(~B, ~A, ~mb, ~ma)}

# a batch: the family F over the indices is, summed
def batch.at(~I: Data, ~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~F: @+i:I -> Rv.D(A, B, ma, mb),
             ix: List<&2, I>, +x: A) -> Rv.DP<A, B, ma, mb>:
  match ix:
    case Nil{}:
      zeroD.at(~A, ~B, ~ma, ~mb)
    case +i <> rest:
      addD.at(~A, ~B, ~ma, ~mb, F(i)(x), batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x))

def batchD(~I: Data, ~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~F: @+i:I -> Rv.D(A, B, ma, mb),
           +ix: List<&2, I>) -> Rv.D(A, B, ma, mb):
  x => batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, ix, x)

# sum over the family of each member's primal / pullback of db
def primals(~I: Data, ~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~F: @+i:I -> Rv.D(A, B, ma, mb),
            ix: List<&2, I>, +x: A) -> B:
  match ix:
    case Nil{}:
      Al.MO.zero(B, mb)
    case +i <> rest:
      Al.MO.add(B, mb)(Rv.DP.y(A, B, ma, mb, F(i)(x)), primals(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x))

def pullbacks(~I: Data, ~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~F: @+i:I -> Rv.D(A, B, ma, mb),
              ix: List<&2, I>, +x: A, +db: B) -> A:
  match ix:
    case Nil{}:
      Al.MO.zero(A, ma)
    case +i <> rest:
      Al.MO.add(A, ma)(Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, F(i)(x)))(db), pullbacks(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x, db))

def addD.primal(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, r: Rv.DP<A, B, ma, mb>, s: Rv.DP<A, B, ma, mb>) ->
    {Rv.DP.y(A, B, ma, mb, addD.at(~A, ~B, ~ma, ~mb, r, s)) == Al.MO.add(B, mb)(Rv.DP.y(A, B, ma, mb, r), Rv.DP.y(A, B, ma, mb, s)) : B}:
  match r s:
    case Rv.DP{y1, f1} Rv.DP{y2, f2}:
      {==}

def sumMaps.apply(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, f: Rv.AMap<A, B, ma, mb>, g: Rv.AMap<A, B, ma, mb>, +x: A) ->
    {Rv.AMap.apply(A, B, ma, mb, sumMaps(~A, ~B, ~ma, ~mb, f, g))(x) == Al.MO.add(B, mb)(Rv.AMap.apply(A, B, ma, mb, f)(x), Rv.AMap.apply(A, B, ma, mb, g)(x)) : B}:
  match f g:
    case Rv.AMap{fa, fz, fp} Rv.AMap{ga, gz, gp}:
      {==}

def addD.pullback(~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, r: Rv.DP<A, B, ma, mb>, s: Rv.DP<A, B, ma, mb>, +db: B) ->
    {Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, addD.at(~A, ~B, ~ma, ~mb, r, s)))(db)
      == Al.MO.add(A, ma)(Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, r))(db), Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, s))(db)) : A}:
  match r s:
    case Rv.DP{y1, f1} Rv.DP{y2, f2}:
      sumMaps.apply(~B, ~A, ~mb, ~ma, f1, f2, db)

# the batch's primal is the sum of the members' primals
def batch_primal(~I: Data, ~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~F: @+i:I -> Rv.D(A, B, ma, mb),
                 +ix: List<&2, I>, +x: A) ->
    {Rv.DP.y(A, B, ma, mb, batchD(~I, ~A, ~B, ~ma, ~mb, ~F, ix)(x)) == primals(~I, ~A, ~B, ~ma, ~mb, ~F, ix, x) : B}:
  match ix:
    case Nil{}:
      {==}
    case +i <> rest:
      %Equal.sym(B, Rv.DP.y(A, B, ma, mb, addD.at(~A, ~B, ~ma, ~mb, F(i)(x), batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x))),
          Al.MO.add(B, mb)(Rv.DP.y(A, B, ma, mb, F(i)(x)), Rv.DP.y(A, B, ma, mb, batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x))),
          addD.primal(~A, ~B, ~ma, ~mb, F(i)(x), batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x)))
        : {_ == primals(~I, ~A, ~B, ~ma, ~mb, ~F, i <> rest, x) : B}
      %batch_primal(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x)
        : {Al.MO.add(B, mb)(Rv.DP.y(A, B, ma, mb, F(i)(x)), Rv.DP.y(A, B, ma, mb, batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x)))
            == Al.MO.add(B, mb)(Rv.DP.y(A, B, ma, mb, F(i)(x)), _) : B}
      {==}

# The micro-batch theorem: the pullback of the summed loss is the sum of
# the members' pullbacks of the same cotangent.
def batch_pullback(~I: Data, ~A: Data, ~B: Data, ~ma: Al.Monoid<A>, ~mb: Al.Monoid<B>, ~F: @+i:I -> Rv.D(A, B, ma, mb),
                   +ix: List<&2, I>, +x: A, +db: B) ->
    {Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, batchD(~I, ~A, ~B, ~ma, ~mb, ~F, ix)(x)))(db) == pullbacks(~I, ~A, ~B, ~ma, ~mb, ~F, ix, x, db) : A}:
  match ix:
    case Nil{}:
      {==}
    case +i <> rest:
      %Equal.sym(A, Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, addD.at(~A, ~B, ~ma, ~mb, F(i)(x), batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x))))(db),
          Al.MO.add(A, ma)(Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, F(i)(x)))(db), Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x)))(db)),
          addD.pullback(~A, ~B, ~ma, ~mb, F(i)(x), batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x), db))
        : {_ == pullbacks(~I, ~A, ~B, ~ma, ~mb, ~F, i <> rest, x, db) : A}
      %batch_pullback(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x, db)
        : {Al.MO.add(A, ma)(Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, F(i)(x)))(db), Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, batch.at(~I, ~A, ~B, ~ma, ~mb, ~F, rest, x)))(db))
            == Al.MO.add(A, ma)(Rv.AMap.apply(B, A, mb, ma, Rv.DP.pull(A, B, ma, mb, F(i)(x)))(db), _) : A}
      {==}

# Instance: squared-loss-like members over Nat, f_i(x) = i * x, whose
# pullback scales the cotangent by i; the micro-batch theorem at that family.
def scale.pz(+i: Nat) -> {Nat.mul(i, 0n) == 0n : Nat}:
  NL.Nat.mul_zero_r(i)

def member.at(+i: Nat, +x: Nat) -> Rv.DP<Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid()>:
  Rv.DP{Nat.mul(i, x), Rv.AMap{d => Nat.mul(i, d), NL.Nat.mul_zero_r(i), a => b => NL.Nat.distrib_l(i, a, b)}}

def member(+i: Nat) -> Rv.D(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid()):
  x => member.at(i, x)

law check.batch:
  for +ix: List<&2, Nat>
  for +x: Nat
  for +db: Nat
  {Rv.AMap.apply(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid(), Rv.DP.pull(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid(), batchD(~Nat, ~Nat, ~Nat, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~member, ix)(x)))(db)
      == pullbacks(~Nat, ~Nat, ~Nat, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~member, ix, x, db) : Nat}
  & {Rv.DP.y(Nat, Nat, Al.Nat.monoid(), Al.Nat.monoid(), batchD(~Nat, ~Nat, ~Nat, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~member, ix)(x))
      == primals(~Nat, ~Nat, ~Nat, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~member, ix, x) : Nat}

def check.batch(ix, x, db):
  (batch_pullback(~Nat, ~Nat, ~Nat, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~member, ix, x, db),
   batch_primal(~Nat, ~Nat, ~Nat, ~Al.Nat.monoid(), ~Al.Nat.monoid(), ~member, ix, x))
