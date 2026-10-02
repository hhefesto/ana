import Base
import ./Semiring.bend as R
import ./Spec.bend as Sp
import ./Forward.bend as F
import ./Tags.bend as Tg
import ./Lines.bend as Li
import ./Ngram.bend as Ng

# legere's model from counts, and its answers on a document.
#
# The tag counts live in a small Array<F32> (256 slots):
#   12 t + u   t followed by u        144 + t  a document starts with t
#   160 + t    a document ends with t 176 + t  lines with gold t
#   192 + t    lines inside a block a cue names t
# A tag's next-line distribution (the 12 tags and the end of the text) is
# add-half smoothed, so no labelling the data never showed weighs zero.

def cnt() -> Array<F32>:
  Array.new(F32, 8n, 0.0)

def known(+g: Nat) -> Bool:
  Nat.is_lt(g, Tg.k())

def bump(+b: Bool) -> F32:
  Bool.pick(F32, b, 1.0, 0.0)

def ix(+n: Nat) -> U32:
  U32.from_nat(n)

def at(+xs: List<&2, F32>, +i: Nat) -> F32:
  R.at(~F32, ~R.maxp(), xs, i)

def addat(xs: List<&2, F32>, +i: Nat, +d: F32) -> List<&2, F32>:
  match xs i:
    case Nil{} _:
      Nil{}
    case x <> t 0n:
      F32.add(x, d) <> t
    case x <> t 1n+q:
      x <> addat(t, q, d)

def zeros(n: Nat) -> List<&2, F32>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      0.0 <> zeros(p)

def cnt.go(ls: List<&2, Li.Lab>, a: Array<F32>, +prev: Nat) -> Array<F32>:
  match ls:
    case Nil{}:
      Ng.inc(a, U32.add(160, ix(prev)), bump(known(prev)))
    case +l <> rest:
      +g = Li.Lab.gold(l)
      +m = Li.Lab.mask(l)
      a1 = Ng.inc(a, U32.add(U32.mul(12, ix(prev)), ix(g)), bump(Bool.and(known(prev), known(g))))
      a2 = Ng.inc(a1, U32.add(176, ix(g)), bump(known(g)))
      cnt.go(rest, Ng.inc(a2, U32.add(192, ix(m)), bump(Nat.is_lt(m, Tg.scored()))), g)

def first.gold(ls: List<&2, Li.Lab>) -> Nat:
  match ls:
    case Nil{}:
      Tg.unknown()
    case l <> t:
      Li.Lab.gold(l)

# count one document's labels (its first line's gold starts it)
def cnt.doc(a: Array<F32>, +ls: List<&2, Li.Lab>) -> Array<F32>:
  +g = first.gold(ls)
  cnt.go(ls, Ng.inc(a, U32.add(144, ix(g)), bump(known(g))), Tg.unknown())

# count one document's labelled lines into the line models.  keep[t] (in
# 0..10000) is the share of tag t's lines kept: every tag trains on at most
# the same budget of bytes, so no tag's model is richer than another's
# because its class is common (a session's stdout holds code of every
# language, and an unbalanced output model wins on all of it).  A line is
# kept by its hash, so the sample spreads over the corpus.
def see.pick(a: Array<F32>, +l: List<&2, U32>, +g: Nat, yes: Bool) -> Array<F32>:
  match yes:
    case True{}:
      Ng.see.line(a, l, g)
    case False{}:
      a

def line.hash(xs: List<&2, U32>, +h: U32) -> U32:
  match xs:
    case Nil{}:
      Ng.mix(h)
    case +c <> t:
      line.hash(t, Ng.fnv(h, c))

def kept(+keep: List<&2, F32>, +g: Nat, +l: List<&2, U32>) -> Bool:
  Bool.and(Nat.is_lt(g, Tg.scored()),
    F32.is_lt(U32.to_f32(U32.mod(line.hash(l, 2166136261), 10000)), at(keep, g)))

def see.go(ls: List<&2, List<&2, U32>>, bs: List<&2, Li.Lab>, a: Array<F32>, +keep: List<&2, F32>) -> Array<F32>:
  match ls bs:
    case +l <> lt b <> bt:
      +g = Li.Lab.gold(b)
      see.go(lt, bt, see.pick(a, l, g, kept(keep, g, l)), keep)
    case _ _:
      a

# bytes per gold tag (the first pass, for the keep shares)
def bytes.go(ls: List<&2, List<&2, U32>>, bs: List<&2, Li.Lab>, acc: List<&2, F32>) -> List<&2, F32>:
  match ls bs:
    case +l <> lt b <> bt:
      bytes.go(lt, bt, addat(acc, Li.Lab.gold(b), F32.from_nat(List.length(&2, U32, l))))
    case _ _:
      acc

# Reading counts back -------------------------------------------------------

def reads.fin(r: Array<F32> & F32, acc: List<&2, F32>) -> Array<F32> & List<&2, F32>:
  (a, v) = r
  (a, v <> acc)

def reads.step(r: Array<F32> & List<&2, F32>, +i: U32) -> Array<F32> & List<&2, F32>:
  (a, acc) = r
  reads.fin(Array.get(F32, a, i), acc)

def reads.go(ix: List<&2, U32>, r: Array<F32> & List<&2, F32>) -> Array<F32> & List<&2, F32>:
  match ix:
    case Nil{}:
      r
    case +i <> t:
      reads.go(t, reads.step(r, i))

# slots base .. base+n-1, in that order
def span.go(ns: List<&2, Nat>, +base: U32) -> List<&2, U32>:
  match ns:
    case Nil{}:
      Nil{}
    case +n <> t:
      U32.add(base, ix(n)) <> span.go(t, base)

def reads(a: Array<F32>, +base: U32, +n: Nat) -> Array<F32> & List<&2, F32>:
  reads.go(List.reverse(&2, U32, span.go(List.range(n), base)), (a, Nil{}))

def sum(xs: List<&2, F32>) -> F32:
  match xs:
    case Nil{}:
      0.0
    case x <> t:
      F32.add(x, sum(t))

# log((c + 1/2) / (total + n/2)) for each count c
def smooth(xs: List<&2, F32>, +total: F32, +n: F32) -> List<&2, F32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      F32.log(F32.div(F32.add(x, 0.5), F32.add(total, F32.mul(n, 0.5)))) <> smooth(t, total, n)

def norm(+xs: List<&2, F32>) -> List<&2, F32>:
  smooth(xs, sum(xs), F32.from_nat(List.length(&2, F32, xs)))

# every count slot, in order
def counts(a: Array<F32>) -> Array<F32> & List<&2, F32>:
  reads(a, 0, 256n)

def slice(+xs: List<&2, F32>, +base: Nat, +n: Nat) -> List<&2, F32>:
  List.take(&2, F32, List.drop(&2, F32, xs, base), n)

# tag t's row: its next-line weights and its end weight, normalized together
def row.of(+cs: List<&2, F32>, +t: Nat) -> List<&2, F32>:
  +xs = slice(cs, Nat.mul(12n, t), Tg.k())
  +f = at(cs, Nat.add(160n, t))
  smooth(xs, F32.add(sum(xs), f), F32.from_nat(Nat.add(Tg.k(), 1n)))

def fin.of(+cs: List<&2, F32>, +t: Nat) -> F32:
  +xs = slice(cs, Nat.mul(12n, t), Tg.k())
  +f = at(cs, Nat.add(160n, t))
  F32.log(F32.div(F32.add(f, 0.5), F32.add(F32.add(sum(xs), f), F32.mul(F32.from_nat(Nat.add(Tg.k(), 1n)), 0.5))))

def rows.of(ts: List<&2, Nat>, +cs: List<&2, F32>) -> List<&2, List<&2, F32>>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> rest:
      row.of(cs, t) <> rows.of(rest, cs)

def fins.of(ts: List<&2, Nat>, +cs: List<&2, F32>) -> List<&2, F32>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> rest:
      fin.of(cs, t) <> fins.of(rest, cs)

# the model's start, transition and final weights (log space)
def hmm(+cs: List<&2, F32>) -> Sp.Hmm<F32>:
  Sp.Hmm{norm(slice(cs, 144n, Tg.k())), rows.of(List.range(Tg.k()), cs), fins.of(List.range(Tg.k()), cs)}

# log p(tag) over every labelled line, and over the lines of named blocks
def prior(+cs: List<&2, F32>) -> List<&2, F32>:
  norm(slice(cs, 176n, Tg.k()))

def inside(+cs: List<&2, F32>) -> List<&2, F32>:
  norm(slice(cs, 192n, Tg.scored()))

# Emission rows -----------------------------------------------------------
#
# A line's raw row: log Λ_t(line) for the scored tags, then open and close,
# which weigh 1 (log 0) a line of the right shape and 0 (-inf) any other.

def open.w(f: Li.Fence) -> F32:
  match f:
    case Li.Fence{m, info}:
      0.0
    case Li.NoFence{}:
      R.ninf()

def close.w(+f: Li.Fence) -> F32:
  Bool.pick(F32, Li.closes(f, 0n), 0.0, R.ninf())

def raw.fin(q: Array<F32> & List<&2, F32>, +l: List<&2, U32>) -> Array<F32> & List<&2, F32>:
  (a, rev) = q
  +f = Li.fence(l)
  (a, List.reverse(&2, F32, close.w(f) <> open.w(f) <> rev))

def raw.row(a: Array<F32>, +l: List<&2, U32>) -> Array<F32> & List<&2, F32>:
  raw.fin(Ng.row.rev(a, l, Tg.scored()), l)

def raw.cons(q: Array<F32> & List<&2, F32>, acc: List<&2, List<&2, F32>>) -> Array<F32> & List<&2, List<&2, F32>>:
  (a, r) = q
  (a, r <> acc)

def raw.step(r: Array<F32> & List<&2, List<&2, F32>>, +l: List<&2, U32>) -> Array<F32> & List<&2, List<&2, F32>>:
  (a, acc) = r
  raw.cons(raw.row(a, l), acc)

def raw.go(ls: List<&2, List<&2, U32>>, r: Array<F32> & List<&2, List<&2, F32>>) -> Array<F32> & List<&2, List<&2, F32>>:
  match ls:
    case Nil{}:
      r
    case +l <> rest:
      raw.go(rest, raw.step(r, l))

def raw.flip(r: Array<F32> & List<&2, List<&2, F32>>) -> Array<F32> & List<&2, List<&2, F32>>:
  (a, rev) = r
  (a, List.reverse(&2, List<&2, F32>, rev))

# a document's raw rows, one per line
def raw.rows(a: Array<F32>, ls: List<&2, List<&2, U32>>) -> Array<F32> & List<&2, List<&2, F32>>:
  raw.flip(raw.go(ls, (a, Nil{})))

# What a mode forces: 0 nothing, 1 the fence lines only (a bare block: the
# structure is seen, the name hidden), 2 every cue (production).
def mode.mask(+mode: Nat, +m: Nat) -> Nat:
  match mode:
    case 0n:
      Tg.unknown()
    case 1n:
      Bool.pick(Nat, Bool.and(Nat.is_le(Tg.open(), m), Nat.is_lt(m, Tg.k())), m, Tg.unknown())
    case _:
      m

# the row the model sees: each line score times w, and -inf for every tag
# but the forced one
def em.row(xs: List<&2, F32>, +w: F32, +m: Nat, +j: Nat) -> List<&2, F32>:
  match xs:
    case Nil{}:
      Nil{}
    case x <> t:
      Bool.pick(F32, Bool.and(known(m), Bool.not(Nat.is_eq(m, j))), R.ninf(), F32.mul(x, w)) <> em.row(t, w, m, 1n+j)

# A line's weight w: the scale s (sum: the line's log-likelihood times s, a
# temperature 1/s), or s over the line's length in bytes (mean: its mean log
# probability per byte times s, so a long line weighs no more than a short
# one).  Both are weighted languages of lines; the validation tenth picks.
def line.w(+mean: Bool, +s: F32, +l: List<&2, U32>) -> F32:
  Bool.pick(F32, mean, F32.div(s, F32.from_nat(Nat.max(1n, List.length(&2, U32, l)))), s)

def em.rows(raws: List<&2, List<&2, F32>>, labs: List<&2, Li.Lab>, ls: List<&2, List<&2, U32>>, +mean: Bool, +s: F32, +mode: Nat) -> List<&2, List<&2, F32>>:
  match raws labs ls:
    case r <> rt l <> lt x <> xt:
      em.row(r, line.w(mean, s, x), mode.mask(mode, Li.Lab.mask(l)), 0n) <> em.rows(rt, lt, xt, mean, s, mode)
    case _ _ _:
      Nil{}

# A document's answers -------------------------------------------------------

# a line's gold and mask, its log posterior per tag, and its Viterbi tag
type Pl is Data:
  Pl{gold: Nat, mask: Nat, post: List<&2, F32>, vit: Nat}

def zip.pl(labs: List<&2, Li.Lab>, posts: List<&2, List<&2, F32>>, vits: List<&2, Nat>) -> List<&2, Pl>:
  match labs posts vits:
    case Li.Lab{g, m} <> lt p <> pt v <> vt:
      Pl{g, m, p, v} <> zip.pl(lt, pt, vt)
    case _ _ _:
      Nil{}

def answer.fin(labs: List<&2, Li.Lab>, posts: List<&2, List<&2, F32>>, v: F32 & List<&2, Nat>) -> List<&2, Pl>:
  (s, vt) = v
  zip.pl(labs, posts, vt)

def answer(+h: Sp.Hmm<F32>, raws: List<&2, List<&2, F32>>, +labs: List<&2, Li.Lab>, ls: List<&2, List<&2, U32>>, +mean: Bool, +s: F32, +mode: Nat) -> List<&2, Pl>:
  +em = em.rows(raws, labs, ls, mean, s, mode)
  answer.fin(labs, F.posteriors(h, em), F.viterbi(h, em))

# Metrics --------------------------------------------------------------------
#
# Populations: 0, every line a cue labels; 1, the lines of named blocks.

def in.pop(+pop: Nat, +g: Nat, +m: Nat) -> Bool:
  match pop:
    case 0n:
      known(g)
    case _:
      Nat.is_lt(m, Tg.scored())

def keep(+pop: Nat, ps: List<&2, Pl>, +acc: List<&2, Pl>) -> List<&2, Pl>:
  match ps:
    case Nil{}:
      acc
    case Pl{+g, +m, p, v} <> t:
      keep(pop, t, Bool.pick(List<&2, Pl>, in.pop(pop, g, m), Pl{g, m, p, v} <> acc, acc))

def flat.pop(+pop: Nat, docs: List<&2, List<&2, Pl>>, acc: List<&2, Pl>) -> List<&2, Pl>:
  match docs:
    case Nil{}:
      acc
    case d <> t:
      flat.pop(pop, t, keep(pop, d, acc))

def argmax.go(xs: List<&2, F32>, +j: Nat, +bv: F32, +bi: Nat) -> Nat:
  match xs:
    case Nil{}:
      bi
    case +x <> t:
      +gt = F32.is_gt(x, bv)
      argmax.go(t, 1n+j, Bool.pick(F32, gt, x, bv), Bool.pick(Nat, gt, j, bi))

def argmax(xs: List<&2, F32>) -> Nat:
  argmax.go(xs, 0n, R.ninf(), 0n)

def maxv(xs: List<&2, F32>) -> F32:
  match xs:
    case Nil{}:
      R.ninf()
    case +x <> t:
      F32.max(x, maxv(t))

def ln2() -> F32:
  0.6931472

# bits: -log2 of the gold tag's posterior, summed
def bits(ps: List<&2, Pl>) -> F32:
  match ps:
    case Nil{}:
      0.0
    case Pl{g, m, p, v} <> t:
      F32.add(F32.neg(F32.div(at(p, g), ln2())), bits(t))

def oks(ps: List<&2, Pl>) -> Nat:
  match ps:
    case Nil{}:
      0n
    case Pl{+g, m, +p, v} <> t:
      Nat.add(Bool.pick(Nat, Nat.is_eq(argmax(p), g), 1n, 0n), oks(t))

# a baseline that answers every line with the distribution lp
def base.bits(ps: List<&2, Pl>, +lp: List<&2, F32>) -> F32:
  match ps:
    case Nil{}:
      0.0
    case Pl{g, m, p, v} <> t:
      F32.add(F32.neg(F32.div(at(lp, g), ln2())), base.bits(t, lp))

def base.oks(ps: List<&2, Pl>, +b: Nat) -> Nat:
  match ps:
    case Nil{}:
      0n
    case Pl{g, m, p, v} <> t:
      Nat.add(Bool.pick(Nat, Nat.is_eq(g, b), 1n, 0n), base.oks(t, b))

# calibration: ten bins of the top posterior; per bin the lines, the summed
# confidence and the lines whose top tag is gold
type Cal is Data:
  Cal{n: List<&2, F32>, conf: List<&2, F32>, ok: List<&2, F32>}

def cal.bin(+c: F32) -> Nat:
  F32.to_nat(F32.min(9.0, F32.floor(F32.mul(c, 10.0))))

def cal.go(ps: List<&2, Pl>, c: Cal) -> Cal:
  match ps c:
    case Pl{+g, m, +p, v} <> t Cal{n, cf, ok}:
      +conf = F32.exp(maxv(p))
      +b = cal.bin(conf)
      cal.go(t, Cal{addat(n, b, 1.0), addat(cf, b, conf), addat(ok, b, bump(Nat.is_eq(argmax(p), g)))})
    case _ c2:
      c2

def ece.sum(cf: List<&2, F32>, ok: List<&2, F32>) -> F32:
  match cf ok:
    case x <> xt y <> yt:
      F32.add(F32.abs(F32.sub(y, x)), ece.sum(xt, yt))
    case _ _:
      0.0

def ece.of(c: Cal, +n: F32) -> F32:
  match c:
    case Cal{cn, cf, ok}:
      F32.div(ece.sum(cf, ok), F32.max(n, 1.0))

# expected calibration error: Σ_bins |correct - confidence| / lines
def ece(+ps: List<&2, Pl>) -> F32:
  ece.of(cal.go(ps, Cal{zeros(10n), zeros(10n), zeros(10n)}), F32.from_nat(List.length(&2, Pl, ps)))


# per tag: lines with gold t and those whose top tag is t
def per.go(ps: List<&2, Pl>, n: List<&2, F32>, ok: List<&2, F32>) -> List<&2, F32> & List<&2, F32>:
  match ps:
    case Nil{}:
      (n, ok)
    case Pl{+g, m, +p, v} <> t:
      per.go(t, addat(n, g, 1.0), addat(ok, g, bump(Nat.is_eq(argmax(p), g))))

# boundaries between consecutive lines both in the population: a gold one
# where their gold tags differ, a predicted one where their Viterbi tags do
type Tri is Data:
  Tri{tp: Nat, fp: Nat, fn: Nat}

def tri.add(+t: Tri, +pg: Bool, +pv: Bool) -> Tri:
  match t:
    case Tri{a, b, c}:
      Tri{Nat.add(a, Bool.pick(Nat, Bool.and(pg, pv), 1n, 0n)), Nat.add(b, Bool.pick(Nat, Bool.and(Bool.not(pg), pv), 1n, 0n)),
        Nat.add(c, Bool.pick(Nat, Bool.and(pg, Bool.not(pv)), 1n, 0n))}

def bnd.go(ps: List<&2, Pl>, +pop: Nat, +pg: Nat, +pv: Nat, +pin: Bool, +tr: Tri) -> Tri:
  match ps:
    case Nil{}:
      tr
    case Pl{+g, +m, p, +v} <> t:
      +inp = in.pop(pop, g, m)
      bnd.go(t, pop, g, v, inp, Bool.pick(Tri, Bool.and(pin, inp), tri.add(tr, Bool.not(Nat.is_eq(pg, g)), Bool.not(Nat.is_eq(pv, v))), tr))

def bnd(docs: List<&2, List<&2, Pl>>, +pop: Nat, +tr: Tri) -> Tri:
  match docs:
    case Nil{}:
      tr
    case d <> t:
      bnd(t, pop, bnd.go(d, pop, Tg.unknown(), Tg.unknown(), False{}, tr))

# count every line of a text under tag t (a language's source files)
def see.all(ls: List<&2, List<&2, U32>>, a: Array<F32>, +t: Nat) -> Array<F32>:
  match ls:
    case Nil{}:
      a
    case +l <> rest:
      see.all(rest, Ng.see.line(a, l, t), t)

def conf.bump(rows: List<&2, List<&2, F32>>, +g: Nat, +a: Nat) -> List<&2, List<&2, F32>>:
  match rows g:
    case Nil{} _:
      Nil{}
    case r <> t 0n:
      addat(r, a, 1.0) <> t
    case r <> t 1n+q:
      r <> conf.bump(t, q, a)

# confusion: row g counts, for lines with gold g, each top tag
def conf.go(ps: List<&2, Pl>, rows: List<&2, List<&2, F32>>) -> List<&2, List<&2, F32>>:
  match ps:
    case Nil{}:
      rows
    case Pl{+g, m, +p, v} <> t:
      conf.go(t, conf.bump(rows, g, argmax(p)))

def conf.zero(n: Nat, +k: Nat) -> List<&2, List<&2, F32>>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      zeros(k) <> conf.zero(p, k)
