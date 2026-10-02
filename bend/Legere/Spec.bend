import Base
import ./Semiring.bend as R

# The meaning of legere.  A text is a list of lines; a labelling gives each
# line a tag (an index 0..k-1, Legere/Tags.bend names them); a section is a
# maximal run of lines with one tag, so labellings and segmentations into
# sections are the same thing (adjacent sections differ in tag, as
# StarCoder2 merges consecutive same-kind cells).
#
# A model gives weights in a semiring W: `start` for the first line's tag,
# `trans` from each tag to the next line's, `final` after the last line,
# and an emission table, one row per line, weighing the line under each tag
# (Legere/Ngram.bend computes it).  The weight of a labelling is the product
# of its weights; the weight of a text is the sum over all its labellings:
#
#   ⟦M⟧(lines) = Σ_τ start(τ₀)·e₀(τ₀) · Π_i trans(τ_{i-1}, τ_i)·e_i(τ_i) · final(τ_n)
#
# This is the weighted language (Σ_t s_t · (Λ_t)⁺)⁺ of Elliott's
# convolution paper over the alphabet of lines, with sections never empty
# (so the star is a finite sum on every finite text, in any semiring), and
# Goodman's semiring parsing: the one meaning answers every question by its
# carrier (Legere/Semiring.bend).  The definitions here enumerate every
# labelling: they are exponential, the specification, run only on tiny
# texts; Legere/Forward.bend computes the same values in time linear in
# the text, and the tests hold it to these.

type Hmm<-W: Data> is Data:
  Hmm{start: List<&2, W>, trans: List<&2, List<&2, W>>, final: List<&2, W>}

def Hmm.start(-W: Data, +h: Hmm<W>) -> List<&2, W>:
  match h:
    case Hmm{s, t, f}:
      s

def Hmm.trans(-W: Data, +h: Hmm<W>) -> List<&2, List<&2, W>>:
  match h:
    case Hmm{s, t, f}:
      t

def Hmm.final(-W: Data, +h: Hmm<W>) -> List<&2, W>:
  match h:
    case Hmm{s, t, f}:
      f

# the number of tags
def Hmm.k(-W: Data, +h: Hmm<W>) -> Nat:
  List.length(&2, W, Hmm.start(W, h))

# the transition weight from tag p to tag t
def tr(~W: Data, ~S: R.Sr<W>, +h: Hmm<W>, +p: Nat, +t: Nat) -> W:
  R.at(~W, ~S, R.at.row(W, Hmm.trans(W, h), p), t)

# The weight of one labelling (a tag per line).  The empty text has one
# labelling, the empty one, of weight one; a labelling of another length
# weighs zero.
def weight.go(~W: Data, ~S: R.Sr<W>, em: List<&2, List<&2, W>>, ts: List<&2, Nat>, +h: Hmm<W>, +p: Nat) -> W:
  match em ts:
    case Nil{} Nil{}:
      R.at(~W, ~S, Hmm.final(W, h), p)
    case +r <> rs +t <> tt:
      R.mul(~W, ~S, R.mul(~W, ~S, tr(~W, ~S, h, p, t), R.at(~W, ~S, r, t)), weight.go(~W, ~S, rs, tt, h, t))
    case _ _:
      R.zero(~W, ~S)

def weight(~W: Data, ~S: R.Sr<W>, +h: Hmm<W>, em: List<&2, List<&2, W>>, ts: List<&2, Nat>) -> W:
  match em ts:
    case Nil{} Nil{}:
      R.one(~W, ~S)
    case +r <> rs +t <> tt:
      R.mul(~W, ~S, R.mul(~W, ~S, R.at(~W, ~S, Hmm.start(W, h), t), R.at(~W, ~S, r, t)), weight.go(~W, ~S, rs, tt, h, t))
    case _ _:
      R.zero(~W, ~S)

# every labelling of n lines with k tags (k^n of them), lexicographic
def seqs.each(+t: Nat, ss: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Nat>>:
  match ss:
    case Nil{}:
      Nil{}
    case s <> rest:
      (t <> s) <> seqs.each(t, rest)

def seqs.all(ts: List<&2, Nat>, +ss: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Nat>>:
  match ts:
    case Nil{}:
      Nil{}
    case +t <> rest:
      List.append(&2, List<&2, Nat>, seqs.each(t, ss), seqs.all(rest, ss))

def seqs(+k: Nat, n: Nat) -> List<&2, List<&2, Nat>>:
  match n:
    case 0n:
      {Nil{} : List<&2, Nat>} <> Nil{}
    case 1n+p:
      seqs.all(List.range(k), seqs(k, p))

def labellings(-W: Data, +h: Hmm<W>, +em: List<&2, List<&2, W>>) -> List<&2, List<&2, Nat>>:
  seqs(Hmm.k(W, h), List.length(&2, List<&2, W>, em))

# the sum of the weights of the labellings ss
def total(~W: Data, ~S: R.Sr<W>, +h: Hmm<W>, +em: List<&2, List<&2, W>>, ss: List<&2, List<&2, Nat>>) -> W:
  match ss:
    case Nil{}:
      R.zero(~W, ~S)
    case s <> rest:
      R.add(~W, ~S, weight(~W, ~S, h, em, s), total(~W, ~S, h, em, rest))

# ⟦M⟧: the weight of the text
def score(~W: Data, ~S: R.Sr<W>, +h: Hmm<W>, +em: List<&2, List<&2, W>>) -> W:
  total(~W, ~S, h, em, labellings(W, h, em))

# line i has tag u
def tag.is.at(m: Maybe<&2, Nat>, +u: Nat) -> Bool:
  match m:
    case Some{t}:
      Nat.is_eq(t, u)
    case None{}:
      False{}

def tag.is(+i: Nat, +u: Nat, ts: List<&2, Nat>) -> Bool:
  tag.is.at(List.get(&2, Nat, ts, i), u)

def keep.pick(s: List<&2, Nat>, rest: List<&2, List<&2, Nat>>, b: Bool) -> List<&2, List<&2, Nat>>:
  match b:
    case True{}:
      s <> rest
    case False{}:
      rest

def keep.tag(+i: Nat, +u: Nat, ss: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Nat>>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> rest:
      keep.pick(s, keep.tag(i, u, rest), tag.is(i, u, s))

# the marginal weight of line i having tag u: the sum over the labellings
# that give it u (divided by ⟦M⟧, in logp, the posterior: classify)
def marginal(~W: Data, ~S: R.Sr<W>, +h: Hmm<W>, +em: List<&2, List<&2, W>>, +i: Nat, +u: Nat) -> W:
  total(~W, ~S, h, em, keep.tag(i, u, labellings(W, h, em)))

# a section starts at line i (i > 0): lines i-1 and i differ in tag
def starts.at(a: Maybe<&2, Nat>, b: Maybe<&2, Nat>) -> Bool:
  match a b:
    case Some{x} Some{y}:
      Bool.not(Nat.is_eq(x, y))
    case _ _:
      False{}

def starts(+i: Nat, +ts: List<&2, Nat>) -> Bool:
  match i:
    case 0n:
      False{}
    case 1n+p:
      starts.at(List.get(&2, Nat, ts, p), List.get(&2, Nat, ts, 1n+p))

def keep.starts(+i: Nat, ss: List<&2, List<&2, Nat>>) -> List<&2, List<&2, Nat>>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> rest:
      keep.pick(s, keep.starts(i, rest), starts(i, s))

# the marginal weight of a section starting at line i (in logp, over ⟦M⟧,
# the posterior: DocJev's Noul, does a new section start here?)
def boundary(~W: Data, ~S: R.Sr<W>, +h: Hmm<W>, +em: List<&2, List<&2, W>>, +i: Nat) -> W:
  total(~W, ~S, h, em, keep.starts(i, labellings(W, h, em)))

# The best labelling and its weight, in maxp (log weights): the first of
# the heaviest, in the lexicographic order of seqs.
def best.go(+h: Hmm<F32>, +em: List<&2, List<&2, F32>>, ss: List<&2, List<&2, Nat>>, +w: F32, b: List<&2, Nat>) -> F32 & List<&2, Nat>:
  match ss:
    case Nil{}:
      (w, b)
    case +s <> rest:
      +v = weight(~F32, ~R.maxp(), h, em, s)
      +gt = F32.is_gt(v, w)
      best.go(h, em, rest, Bool.pick(F32, gt, v, w), Bool.pick(List<&2, Nat>, gt, s, b))

def best(+h: Hmm<F32>, +em: List<&2, List<&2, F32>>) -> F32 & List<&2, Nat>:
  best.go(h, em, labellings(F32, h, em), R.ninf(), Nil{})

# Sections: the maximal runs of a labelled text.  Concatenating their
# lines gives the text back (law roundtrip), so a segmentation never loses
# or reorders a byte (Units.bend's head ++ pre ++ body ++ tail invariant).
type Sec<-L: Data> is Data:
  Sec{tag: Nat, lines: List<&2, L>}

# a line and its tag
type Ln<-L: Data> is Data:
  Ln{tag: Nat, line: L}

def merge.pick(-L: Data, +t: Nat, +l: L, +u: Nat, xs: List<&2, L>, rest: List<&2, Sec<L>>, same: Bool) -> List<&2, Sec<L>>:
  match same:
    case True{}:
      Sec{u, l <> xs} <> rest
    case False{}:
      Sec{t, l <> Nil{}} <> Sec{u, xs} <> rest

# put line l, tagged t, in front of the sections
def merge(-L: Data, +t: Nat, +l: L, secs: List<&2, Sec<L>>) -> List<&2, Sec<L>>:
  match secs:
    case Nil{}:
      Sec{t, l <> Nil{}} <> Nil{}
    case Sec{+u, xs} <> rest:
      merge.pick(L, t, l, u, xs, rest, Nat.is_eq(t, u))

def sections(-L: Data, ps: List<&2, Ln<L>>) -> List<&2, Sec<L>>:
  match ps:
    case Nil{}:
      Nil{}
    case Ln{+t, +l} <> rest:
      merge(L, t, l, sections(L, rest))

def flat(-L: Data, secs: List<&2, Sec<L>>) -> List<&2, L>:
  match secs:
    case Nil{}:
      Nil{}
    case Sec{t, xs} <> rest:
      List.append(&2, L, xs, flat(L, rest))

def lines.of(-L: Data, ps: List<&2, Ln<L>>) -> List<&2, L>:
  match ps:
    case Nil{}:
      Nil{}
    case Ln{t, +l} <> rest:
      l <> lines.of(L, rest)

def merge_flat.pick(-L: Data, +t: Nat, +l: L, +u: Nat, +xs: List<&2, L>, +rest: List<&2, Sec<L>>, same: Bool) ->
    {flat(L, merge.pick(L, t, l, u, xs, rest, same)) == l <> flat(L, Sec{u, xs} <> rest) : List<&2, L>}:
  match same:
    case True{}:
      {==}
    case False{}:
      {==}

law merge_flat:
  for -L: Data
  for +t: Nat
  for +l: L
  for +secs: List<&2, Sec<L>>
  {flat(L, merge(L, t, l, secs)) == l <> flat(L, secs) : List<&2, L>}

def merge_flat(L, t, l, secs):
  match secs:
    case Nil{}:
      {==}
    case Sec{+u, +xs} <> +rest:
      merge_flat.pick(L, t, l, u, xs, rest, Nat.is_eq(t, u))

law roundtrip:
  for -L: Data
  for +ps: List<&2, Ln<L>>
  {flat(L, sections(L, ps)) == lines.of(L, ps) : List<&2, L>}

def roundtrip(L, ps):
  match ps:
    case Nil{}:
      {==}
    case Ln{+t, +l} <> +rest:
      %Equal.sym(List<&2, L>, flat(L, merge(L, t, l, sections(L, rest))), l <> flat(L, sections(L, rest)), merge_flat(L, t, l, sections(L, rest)))
        : {_ == l <> lines.of(L, rest) : List<&2, L>}
      %roundtrip(L, rest) : {l <> flat(L, sections(L, rest)) == l <> _ : List<&2, L>}
      {==}
