import Base
import ../Legere/Semiring.bend as R
import ../Legere/Spec.bend as Sp
import ../Legere/Forward.bend as F
import ../Legere/Lines.bend as Li
import ../Legere/Ngram.bend as Ng
import ../Sys.bend as S

# legere's forward-backward and Viterbi (Legere/Forward.bend) against the
# meaning (Legere/Spec.bend), which enumerates every labelling.  Toy models
# with small natural weights (zeros included: log 0 = -inf in F32), k = 3
# tags, texts of 0..6 lines.  Bool and Nat are held exactly, and Bool to
# Nat's support (n ↦ n > 0 is a semiring homomorphism, so both meanings
# agree); logp and maxp within 1e-4 relative.  Each line prints `ok NAME`
# or `FAIL NAME`.

def verdict(+name: String, ok: Bool) -> String:
  Bool.pick(String, ok, "ok ", "FAIL ") ++ name

# a small weight in 0..3 for cell (i, j) of table `salt`
def w(+i: Nat, +j: Nat, +salt: Nat) -> Nat:
  +x = Nat.add(Nat.add(Nat.mul(i, 7n), Nat.mul(j, 13n)), Nat.add(Nat.mul(salt, 29n), Nat.mul(Nat.mul(i, Nat.add(i, j)), 3n)))
  Nat.mod(Nat.mod(x, 7n), 4n)

def row.go(js: List<&2, Nat>, +i: Nat, +salt: Nat) -> List<&2, Nat>:
  match js:
    case Nil{}:
      Nil{}
    case +j <> t:
      w(i, j, salt) <> row.go(t, i, salt)

def row(+k: Nat, +i: Nat, +salt: Nat) -> List<&2, Nat>:
  row.go(List.range(k), i, salt)

def table.go(ixs: List<&2, Nat>, +k: Nat, +salt: Nat) -> List<&2, List<&2, Nat>>:
  match ixs:
    case Nil{}:
      Nil{}
    case +i <> t:
      row(k, i, salt) <> table.go(t, k, salt)

def table(+n: Nat, +k: Nat, +salt: Nat) -> List<&2, List<&2, Nat>>:
  table.go(List.range(n), k, salt)

def hmm(+k: Nat, +salt: Nat) -> Sp.Hmm<Nat>:
  Sp.Hmm{row(k, 100n, salt), table(k, k, Nat.add(salt, 1n)), row(k, 200n, Nat.add(salt, 2n))}

# the same weights in Bool (support) and F32 (log)
def b.row(xs: List<&2, Nat>) -> List<&2, Bool>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      Bool.not(Nat.is_eq(x, 0n)) <> b.row(t)

def b.rows(xss: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Bool>>:
  match xss:
    case Nil{}:
      Nil{}
    case xs <> t:
      b.row(xs) <> b.rows(t)

def l.row(xs: List<&2, Nat>) -> List<&2, F32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      F32.log(F32.from_nat(x)) <> l.row(t)

def l.rows(xss: List<&2, List<&2, Nat>>) -> List<&2, List<&2, F32>>:
  match xss:
    case Nil{}:
      Nil{}
    case xs <> t:
      l.row(xs) <> l.rows(t)

def b.hmm(h: Sp.Hmm<Nat>) -> Sp.Hmm<Bool>:
  match h:
    case Sp.Hmm{s, t, f}:
      Sp.Hmm{b.row(s), b.rows(t), b.row(f)}

def l.hmm(h: Sp.Hmm<Nat>) -> Sp.Hmm<F32>:
  match h:
    case Sp.Hmm{s, t, f}:
      Sp.Hmm{l.row(s), l.rows(t), l.row(f)}

# a ≈ b: both log 0, or within 1e-4 of each other relative to max(1, |b|)
def near(+a: F32, +b: F32) -> Bool:
  Bool.or(Bool.and(R.is_ninf(a), R.is_ninf(b)),
    F32.is_le(F32.abs(F32.sub(a, b)), F32.mul(0.0001, F32.max(1.0, F32.abs(b)))))

def bool.eq(+a: Bool, +b: Bool) -> Bool:
  Bool.or(Bool.and(a, b), Bool.and(Bool.not(a), Bool.not(b)))

def nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(Nat.is_eq(x, y), nats.eq(xt, yt))
    case _ _:
      False{}

def rows.eq(xss: List<&2, List<&2, Nat>>, yss: List<&2, List<&2, Nat>>) -> Bool:
  match xss yss:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(nats.eq(x, y), rows.eq(xt, yt))
    case _ _:
      False{}

def f32s.near(xs: List<&2, F32>, ys: List<&2, F32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(near(x, y), f32s.near(xt, yt))
    case _ _:
      False{}

def f32rows.near(xss: List<&2, List<&2, F32>>, yss: List<&2, List<&2, F32>>) -> Bool:
  match xss yss:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(f32s.near(x, y), f32rows.near(xt, yt))
    case _ _:
      False{}

# the meaning's marginals as a table: line i, tag u
def spec.mrow(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, +em: List<&2, List<&2, W>>, +i: Nat, us: List<&2, Nat>) -> List<&2, W>:
  match us:
    case Nil{}:
      Nil{}
    case +u <> t:
      Sp.marginal(~W, ~S, h, em, i, u) <> spec.mrow(~W, ~S, h, em, i, t)

def spec.margs(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, +em: List<&2, List<&2, W>>, ixs: List<&2, Nat>, +k: Nat) -> List<&2, List<&2, W>>:
  match ixs:
    case Nil{}:
      Nil{}
    case +i <> t:
      spec.mrow(~W, ~S, h, em, i, List.range(k)) <> spec.margs(~W, ~S, h, em, t, k)

# the meaning's boundaries for lines 1..n-1
def spec.bounds(~W: Data, ~S: R.Sr<W>, +h: Sp.Hmm<W>, +em: List<&2, List<&2, W>>, js: List<&2, Nat>) -> List<&2, W>:
  match js:
    case Nil{}:
      Nil{}
    case +j <> t:
      Sp.boundary(~W, ~S, h, em, 1n+j) <> spec.bounds(~W, ~S, h, em, t)

# log posteriors from the meaning: marginal over score, in log space
def spec.post(+z: F32, xss: List<&2, List<&2, F32>>) -> List<&2, List<&2, F32>>:
  F.over.rows(xss, z)

# every row of probabilities sums to 1 (log posteriors, exp'd)
def sums.one(xss: List<&2, List<&2, F32>>) -> Bool:
  match xss:
    case Nil{}:
      True{}
    case xs <> t:
      Bool.and(near(R.Sr.add(F32, R.logp())(R.ninf(), R.sum(~F32, ~R.logp(), xs)), 0.0), sums.one(t))

def best.ok(+h: Sp.Hmm<F32>, +em: List<&2, List<&2, F32>>, v: F32 & List<&2, Nat>, s: F32 & List<&2, Nat>) -> Bool:
  (+vw, vt) = v
  (sw, st) = s
  Bool.and(near(vw, sw), near(Sp.weight(~F32, ~R.maxp(), h, em, vt), vw))

def u32s.eq(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case x <> xt y <> yt:
      Bool.and(U32.is_eq(x, y), u32s.eq(xt, yt))
    case _ _:
      False{}

def sec.lines(+ps: List<&2, Sp.Ln<U32>>) -> Bool:
  u32s.eq(Sp.flat(U32, Sp.sections(U32, ps)), Sp.lines.of(U32, ps))

# one case: k tags, n lines, the tables of `salt`; the checks in order
def case.checks(+k: Nat, +n: Nat, +salt: Nat) -> List<&2, Bool>:
  +h = hmm(k, salt)
  +em = table(n, k, Nat.add(salt, 3n))
  +bh = b.hmm(h)
  +bem = b.rows(em)
  +lh = l.hmm(h)
  +lem = l.rows(em)
  +ns = Sp.score(~Nat, ~R.nat(), h, em)
  +lz = Sp.score(~F32, ~R.logp(), lh, lem)
  [Nat.is_eq(F.score(~Nat, ~R.nat(), h, em), ns),
   Bool.and(bool.eq(F.score(~Bool, ~R.bool(), bh, bem), Sp.score(~Bool, ~R.bool(), bh, bem)), bool.eq(Sp.score(~Bool, ~R.bool(), bh, bem), Nat.is_gt(ns, 0n))),
   rows.eq(F.marginals(~Nat, ~R.nat(), h, em), spec.margs(~Nat, ~R.nat(), h, em, List.range(n), k)),
   nats.eq(F.boundaries(~Nat, ~R.nat(), h, em), spec.bounds(~Nat, ~R.nat(), h, em, List.range(Nat.sub(n, 1n)))),
   Bool.and(near(F.score(~F32, ~R.logp(), lh, lem), lz), near(lz, F32.log(F32.from_nat(ns)))),
   Bool.or(R.is_ninf(lz), Bool.and(sums.one(F.posteriors(lh, lem)),
     f32rows.near(F.posteriors(lh, lem), spec.post(lz, spec.margs(~F32, ~R.logp(), lh, lem, List.range(n), k))))),
   Bool.or(R.is_ninf(lz), f32s.near(F.bposteriors(lh, lem), F.over(spec.bounds(~F32, ~R.logp(), lh, lem, List.range(Nat.sub(n, 1n))), lz))),
   best.ok(lh, lem, F.viterbi(lh, lem), Sp.best(lh, lem))]

def and.rows(xs: List<&2, Bool>, ys: List<&2, Bool>) -> List<&2, Bool>:
  match xs ys:
    case x <> xt y <> yt:
      Bool.and(x, y) <> and.rows(xt, yt)
    case _ _:
      Nil{}

def all.cases(cs: List<&2, Nat>, +k: Nat, +salt: Nat) -> List<&2, Bool>:
  match cs:
    case Nil{}:
      [True{}, True{}, True{}, True{}, True{}, True{}, True{}, True{}]
    case +n <> t:
      and.rows(case.checks(k, n, salt), all.cases(t, k, salt))

def names() -> List<&2, String>:
  ["score", "bool", "marginals", "boundaries", "logp", "posteriors", "bposteriors", "viterbi"]

def show(ns: List<&2, String>, bs: List<&2, Bool>) -> IO(Unit):
  match ns bs:
    case n <> nt b <> bt:
      do IO<Unit>:
        IO.print(verdict(n, b))
        show(nt, bt)
    case _ _:
      IO.pure(Unit, Unit{})

def sec.case() -> List<&2, Sp.Ln<U32>>:
  [Sp.Ln{0n, 10}, Sp.Ln{0n, 11}, Sp.Ln{2n, 12}, Sp.Ln{1n, 13}, Sp.Ln{1n, 14}, Sp.Ln{0n, 15}]

# a session's cues: a Write header names its block, **stdout:** names
# output, a ```` block holds ``` lines, an info string names its block, a
# bare fence with no cue is unknown (99); fence lines are open (10) and
# close (11); outside fences gold is prose and nothing is forced
def cue.text() -> String:
  "## Assistant\n\nSome prose.\n\n### Write — `/x/Foo.hs`\n\n```\nmodule Foo where\nx = 1\n```\n\n**stdout:**\n\n```\nhello\n```\n\n````\n# md\n```haskell\ninner\n```\n````\n\n```haskell\ny = 2\n```\n\n```\nmystery\n```\n"

def cue.gold() -> List<&2, Nat>:
  [0n, 0n, 0n, 0n, 0n, 0n, 10n, 1n, 1n, 11n, 0n, 0n, 0n, 10n, 8n, 11n, 0n, 10n, 99n, 99n, 99n, 99n, 11n, 0n, 10n, 1n, 11n, 0n, 10n, 99n, 11n]

def cue.mask() -> List<&2, Nat>:
  [99n, 99n, 99n, 99n, 99n, 99n, 10n, 1n, 1n, 11n, 99n, 99n, 99n, 10n, 8n, 11n, 99n, 10n, 99n, 99n, 99n, 99n, 11n, 99n, 10n, 1n, 11n, 99n, 10n, 99n, 11n]

def golds(ls: List<&2, Li.Lab>) -> List<&2, Nat>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      Li.Lab.gold(l) <> golds(t)

def masks(ls: List<&2, Li.Lab>) -> List<&2, Nat>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      Li.Lab.mask(l) <> masks(t)

# Λ_t is a distribution at every context: Σ_b P_t(b | h) = 1 (exact
# counts: a small model in a table with room to spare)
def ng.sum.fin(q: Array<F32> & F32, +s: F32) -> Array<F32> & F32:
  (a, p) = q
  (a, F32.add(s, p))

def ng.sum.step(r: Array<F32> & F32, +c1: U32, +c2: U32, +c3: U32, +b: U32) -> Array<F32> & F32:
  (a, s) = r
  ng.sum.fin(Ng.prob(a, 1, c1, c2, c3, b), s)

def ng.sum.go(bs: List<&2, Nat>, r: Array<F32> & F32, +c1: U32, +c2: U32, +c3: U32) -> Array<F32> & F32:
  match bs:
    case Nil{}:
      r
    case +b <> t:
      ng.sum.go(t, ng.sum.step(r, c1, c2, c3, U32.from_nat(b)), c1, c2, c3)

def ng.one(r: Array<F32> & F32) -> Bool:
  (a, s) = r
  near(s, 1.0)

def ng.model() -> Array<F32>:
  Ng.see.line(Ng.see.line(Ng.see.line(Ng.table.of(20n), S.b("abc\n"), 1n), S.b("abd\n"), 1n), S.b("x = 1\n"), 1n)

def ng.ok() -> Bool:
  Bool.and(ng.one(ng.sum.go(List.range(256n), (ng.model(), 0.0), Ng.bos(), Ng.bos(), Ng.bos())),
    Bool.and(ng.one(ng.sum.go(List.range(256n), (ng.model(), 0.0), 98, 97, Ng.bos())),
      ng.one(ng.sum.go(List.range(256n), (ng.model(), 0.0), 122, 121, 120))))

def main() -> IO(Unit):
  +ns = List.range(7n)
  +r = and.rows(and.rows(all.cases(ns, 3n, 0n), all.cases(ns, 3n, 5n)), and.rows(all.cases(ns, 3n, 11n), all.cases(ns, 2n, 17n)))
  do IO<Unit>:
    show(names(), r)
    +labs : List<&2, Li.Lab> = Li.labs(Li.lines(S.b(cue.text())))
    IO.print(verdict("cues", Bool.and(nats.eq(golds(labs), cue.gold()), nats.eq(masks(labs), cue.mask()))))
    IO.print(verdict("ngram", ng.ok()))
    IO.print(verdict("roundtrip", Bool.and(sec.lines(sec.case()), Nat.is_eq(List.length(&2, Sp.Sec<U32>, Sp.sections(U32, sec.case())), 4n))))
