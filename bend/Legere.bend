import Base
import ./Sys.bend as S
import ./Json.bend as J
import ./Clock.bend as Ck
import ./Legere/Semiring.bend as R
import ./Legere/Spec.bend as Sp
import ./Legere/Forward.bend as F
import ./Legere/Tags.bend as Tg
import ./Legere/Lines.bend as Li
import ./Legere/Ngram.bend as Ng
import ./Legere/Model.bend as Mo
import ./Legere/Out.bend as O

# bend-legere: a Bend Jev.  It reads text, cuts it into sections tagged with
# ana's tags (prose; haskell agda lean bend nix; shell diff output code; the
# fences), with calibrated posteriors, and (stage units) hands the code it
# finds to bend-check and bend-transcript.  The meaning is
# Legere/Spec.bend; docs/LEGERE.md has the design and the measurements.
#
#   bend-legere eval CORPUS HOLDOUT
#     train on CORPUS ({"id","text"} JSONL: the Claude Code sessions) and
#     the five languages' source files, fit the temperature on a tenth of
#     CORPUS (ids whose FNV-1a is 0 mod 10), and score HOLDOUT
#
# Environment: LANGS (run/transcripts-final: LANG/files-{hi,lo}.nul),
# BUDGET (bytes each tag trains on at most, 6000000).

# Reading a JSONL corpus --------------------------------------------------------

type Rj is Type:
  Rj{rd: S.Rd, acc: List<&2, J.Doc>, go: Bool}

def rj.cons(d: Maybe<&2, J.Doc>, acc: List<&2, J.Doc>) -> List<&2, J.Doc>:
  match d:
    case Some{x}:
      x <> acc
    case None{}:
      acc

def rj.line(rd: S.Rd, acc: List<&2, J.Doc>, m: Maybe<&2, List<&2, U32>>) -> Rj:
  match m:
    case None{}:
      Rj{rd, acc, False{}}
    case Some{+l}:
      Rj{rd, rj.cons(J.doc(l), acc), True{}}

def rj.pair(acc: List<&2, J.Doc>, r: S.Rd & Maybe<&2, List<&2, U32>>) -> Rj:
  (rd, m) = r
  rj.line(rd, acc, m)

def rj.step(p: Rj) -> IO(Rj):
  match p:
    case Rj{rd, acc, g}:
      do IO<Rj>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return rj.pair(acc, r)

def rj.go(fuel: Nat, p: Rj) -> IO(List<&2, J.Doc>):
  match fuel p:
    case 1n+f Rj{rd, acc, True{}}:
      IO.bind(Rj, List<&2, J.Doc>, rj.step(Rj{rd, acc, True{}}), rj.go(f))
    case _ Rj{rd, acc, g}:
      do IO<List<&2, J.Doc>>:
        S.Rd.close(rd)
        return List.reverse(&2, J.Doc, acc)

def read.jsonl(path: String) -> IO(List<&2, J.Doc>):
  do IO<List<&2, J.Doc>>:
    rd : S.Rd <- S.Rd.lines(path)
    rj.go(U32.to_nat(100000000), Rj{rd, Nil{}, True{}})

# Training on a language's source files (NUL-framed id, text pairs) -------------

type Lf is Type:
  Lf{rd: S.Rd, a: Array<F32>, t: Nat, left: Nat, k: Nat, stride: Nat, isid: Bool, go: Bool}

def lf.take(take: Bool, a: Array<F32>, +x: List<&2, U32>, +t: Nat) -> Array<F32>:
  match take:
    case True{}:
      Mo.see.all(Li.lines(x), a, t)
    case False{}:
      a

def lf.text(rd: S.Rd, a: Array<F32>, +t: Nat, +left: Nat, +k: Nat, +stride: Nat, +x: List<&2, U32>) -> Lf:
  +take = Nat.is_eq(Nat.mod(k, stride), 0n)
  +left2 = Bool.pick(Nat, take, Nat.sub(left, S.len(x)), left)
  Lf{rd, lf.take(take, a, x, t), t, left2, 1n+k, stride, True{}, Nat.is_lt(0n, left2)}

def lf.got(rd: S.Rd, a: Array<F32>, +t: Nat, +left: Nat, +k: Nat, +stride: Nat, isid: Bool, m: Maybe<&2, List<&2, U32>>) -> Lf:
  match isid m:
    case True{} Some{x}:
      Lf{rd, a, t, left, k, stride, False{}, True{}}
    case False{} Some{+x}:
      lf.text(rd, a, t, left, k, stride, x)
    case _ _:
      Lf{rd, a, t, left, k, stride, True{}, False{}}

def lf.pair(a: Array<F32>, +t: Nat, +left: Nat, +k: Nat, +stride: Nat, isid: Bool, r: S.Rd & Maybe<&2, List<&2, U32>>) -> Lf:
  (rd, m) = r
  lf.got(rd, a, t, left, k, stride, isid, m)

def lf.step(s: Lf) -> IO(Lf):
  match s:
    case Lf{rd, a, t, left, k, stride, isid, g}:
      do IO<Lf>:
        r : S.Rd & Maybe<&2, List<&2, U32>> <- S.Rd.next(rd)
        return lf.pair(a, t, left, k, stride, isid, r)

def lf.go(fuel: Nat, s: Lf) -> IO(Array<F32> & Nat):
  match fuel s:
    case 1n+f Lf{rd, a, t, left, k, stride, isid, True{}}:
      IO.bind(Lf, Array<F32> & Nat, lf.step(Lf{rd, a, t, left, k, stride, isid, True{}}), lf.go(f))
    case _ Lf{rd, a, t, left, k, stride, isid, g}:
      do IO<Array<F32> & Nat>:
        S.Rd.close(rd)
        return (a, left)

def lang.open(a: Array<F32>, +path: String, +t: Nat, +left: Nat, +stride: Nat, ok: Bool) -> IO(Array<F32> & Nat):
  match ok:
    case True{}:
      do IO<Array<F32> & Nat>:
        rd : S.Rd <- S.Rd.open(path)
        lf.go(U32.to_nat(100000000), Lf{rd, a, t, left, 0n, stride, True{}, True{}})
    case False{}:
      IO.pure(Array<F32> & Nat, (a, left))

# train tag t on up to `left` bytes of a NUL file, every stride-th text so
# the sample spreads over the file; answers the bytes still wanted
def lang.file(a: Array<F32>, +path: String, +t: Nat, +left: Nat) -> IO(Array<F32> & Nat):
  do IO<Array<F32> & Nat>:
    +size : Nat <- S.size(path)
    +ok : Bool = Bool.and(Nat.is_lt(0n, size), Nat.is_lt(0n, left))
    lang.open(a, path, t, left, Nat.max(1n, Nat.div(size, Nat.max(left, 1n))), ok)

def lang.done(+l: String, r: Array<F32> & Nat) -> IO(Array<F32>):
  (a, +left) = r
  do IO<Array<F32>>:
    Ck.log("legere: " ++ l ++ ": " ++ Nat.show(left) ++ " bytes of the budget unused")
    return a

def lang.lo(+dir: String, +l: String, +t: Nat, r: Array<F32> & Nat) -> IO(Array<F32>):
  (a, +left) = r
  IO.bind(Array<F32> & Nat, Array<F32>, lang.file(a, dir ++ "/" ++ l ++ "/files-lo.nul", t, left), x => lang.done(l, x))

def lang(a: Array<F32>, +dir: String, +l: String, +t: Nat, +budget: Nat) -> IO(Array<F32>):
  do IO<Array<F32>>:
    r : Array<F32> & Nat <- lang.file(a, dir ++ "/" ++ l ++ "/files-hi.nul", t, budget)
    lang.lo(dir, l, t, r)

def langs(a: Array<F32>, +dir: String, +budget: Nat) -> IO(Array<F32>):
  do IO<Array<F32>>:
    a1 : Array<F32> <- lang(a, dir, "haskell", 1n, budget)
    a2 : Array<F32> <- lang(a1, dir, "agda", 2n, budget)
    a3 : Array<F32> <- lang(a2, dir, "lean", 3n, budget)
    a4 : Array<F32> <- lang(a3, dir, "bend", 4n, budget)
    lang(a4, dir, "nix", 5n, budget)

# Training on the sessions ---------------------------------------------------

def fnv.bytes(xs: List<&2, U32>, +h: U32) -> U32:
  match xs:
    case Nil{}:
      h
    case +c <> t:
      fnv.bytes(t, Ng.fnv(h, c))

# a tenth of the corpus fits the temperature; it is never counted
def is.val(+id: List<&2, U32>) -> Bool:
  U32.is_eq(U32.mod(Ng.mix(fnv.bytes(id, 2166136261)), 10), 0)

type Two is Type:
  Two{ng: Array<F32>, tc: Array<F32>}

def train.lab(+ls: List<&2, List<&2, U32>>, +labs: List<&2, Li.Lab>, +keep: List<&2, F32>, two: Two) -> Two:
  match two:
    case Two{ng, tc}:
      Two{Mo.see.go(ls, labs, ng, keep), Mo.cnt.doc(tc, labs)}

def train.doc(+text: List<&2, U32>, +keep: List<&2, F32>, two: Two) -> Two:
  +ls = Li.lines(text)
  train.lab(ls, Li.labs(ls), keep, two)

def train.pick(val: Bool, +text: List<&2, U32>, +keep: List<&2, F32>, two: Two) -> Two:
  match val:
    case True{}:
      two
    case False{}:
      train.doc(text, keep, two)

def train.docs(ds: List<&2, J.Doc>, +keep: List<&2, F32>, two: Two) -> Two:
  match ds:
    case Nil{}:
      two
    case J.Doc{+id, +text} <> rest:
      train.docs(rest, keep, train.pick(is.val(id), text, keep, two))

# bytes per gold tag over the training documents
def tag.bytes(ds: List<&2, J.Doc>, +acc: List<&2, F32>) -> List<&2, F32>:
  match ds:
    case Nil{}:
      acc
    case J.Doc{+id, +text} <> rest:
      +ls = Li.lines(text)
      tag.bytes(rest, Bool.pick(List<&2, F32>, is.val(id), acc, Mo.bytes.go(ls, Li.labs(ls), acc)))

# the share of each tag's lines to keep (out of 10000) for a budget
def keep.of(bs: List<&2, F32>, +budget: F32) -> List<&2, F32>:
  match bs:
    case Nil{}:
      Nil{}
    case +b <> t:
      F32.mul(10000.0, F32.min(1.0, F32.div(budget, F32.max(b, 1.0)))) <> keep.of(t, budget)

def keep.show(bs: List<&2, F32>, ks: List<&2, F32>, +t: Nat) -> String:
  match bs ks:
    case b <> bt k <> kt:
      " " ++ Tg.name(t) ++ " " ++ F32.show(b) ++ "B:" ++ F32.show(F32.div(k, 100.0)) ++ "%" ++ keep.show(bt, kt, 1n+t)
    case _ _:
      ""

# A document's lines, labels and raw rows ------------------------------------

type Dr is Data:
  Dr{labs: List<&2, Li.Lab>, raws: List<&2, List<&2, F32>>, lines: List<&2, List<&2, U32>>}

def dr.fin(q: Array<F32> & List<&2, List<&2, F32>>, +labs: List<&2, Li.Lab>, +ls: List<&2, List<&2, U32>>, acc: List<&2, Dr>) -> Array<F32> & List<&2, Dr>:
  (a, raws) = q
  (a, Dr{labs, raws, ls} <> acc)

def dr.step(r: Array<F32> & List<&2, Dr>, +text: List<&2, U32>) -> Array<F32> & List<&2, Dr>:
  (a, acc) = r
  +ls = Li.lines(text)
  dr.fin(Mo.raw.rows(a, ls), Li.labs(ls), ls, acc)

def drs.pick(take: Bool, r: Array<F32> & List<&2, Dr>, +text: List<&2, U32>) -> Array<F32> & List<&2, Dr>:
  match take:
    case True{}:
      dr.step(r, text)
    case False{}:
      r

# the rows of every document (val: only the validation tenth)
def drs.go(ds: List<&2, J.Doc>, +val: Bool, r: Array<F32> & List<&2, Dr>) -> Array<F32> & List<&2, Dr>:
  match ds:
    case Nil{}:
      r
    case J.Doc{+id, +text} <> rest:
      drs.go(rest, val, drs.pick(Bool.or(Bool.not(val), is.val(id)), r, text))

def drs.flip(r: Array<F32> & List<&2, Dr>) -> Array<F32> & List<&2, Dr>:
  (a, xs) = r
  (a, List.reverse(&2, Dr, xs))

def drs(a: Array<F32>, ds: List<&2, J.Doc>, +val: Bool) -> Array<F32> & List<&2, Dr>:
  drs.flip(drs.go(ds, val, (a, Nil{})))

# Answers and metrics ------------------------------------------------------

# a setting: mean (per-byte) or sum line scores, and the scale s
type Cfg is Data:
  Cfg{mean: Bool, s: F32}

def set.show(+st: Cfg) -> String:
  match st:
    case Cfg{m, s}:
      Bool.pick(String, m, "mean, scale ", "sum, scale ") ++ F32.show(s)

def answers(+h: Sp.Hmm<F32>, ds: List<&2, Dr>, +st: Cfg, +mode: Nat) -> List<&2, List<&2, Mo.Pl>>:
  match ds st:
    case Nil{} _:
      Nil{}
    case Dr{+labs, +raws, +ls} <> rest Cfg{+m, +s}:
      Mo.answer(h, raws, labs, ls, m, s, mode) <> answers(h, rest, Cfg{m, s}, mode)

# mean bits per line of population pop under mode
def score.at(+h: Sp.Hmm<F32>, +ds: List<&2, Dr>, +st: Cfg, +pop: Nat, +mode: Nat) -> F32:
  +ps = Mo.flat.pop(pop, answers(h, ds, st, mode), Nil{})
  F32.div(Mo.bits(ps), F32.max(1.0, F32.from_nat(List.length(&2, Mo.Pl, ps))))

# the settings tried: sum at temperatures 1..512, mean at scales 0.25..64
def grid() -> List<&2, Cfg>:
  [Cfg{False{}, 1.0}, Cfg{False{}, 0.25}, Cfg{False{}, 0.0625}, Cfg{False{}, 0.03125}, Cfg{False{}, 0.015625},
   Cfg{False{}, 0.0078125}, Cfg{False{}, 0.00390625}, Cfg{False{}, 0.001953125},
   Cfg{True{}, 0.25}, Cfg{True{}, 0.5}, Cfg{True{}, 1.0}, Cfg{True{}, 2.0}, Cfg{True{}, 4.0}, Cfg{True{}, 8.0},
   Cfg{True{}, 16.0}, Cfg{True{}, 32.0}, Cfg{True{}, 64.0}]

# the setting with the fewest validation bits per line, over both
# populations' lines (pop 0, mode 0: nothing forced) and named blocks
# (pop 1, mode 1: fences forced)
def best.t(ts: List<&2, Cfg>, +h: Sp.Hmm<F32>, +ds: List<&2, Dr>, +bt: Cfg, +bs: F32, log: String) -> Cfg & String:
  match ts:
    case Nil{}:
      (bt, log)
    case +t <> rest:
      +s = F32.add(score.at(h, ds, t, 1n, 1n), score.at(h, ds, t, 0n, 0n))
      +b = F32.is_lt(s, bs)
      best.t(rest, h, ds, Bool.pick(Cfg, b, t, bt), Bool.pick(F32, b, s, bs), log ++ " [" ++ set.show(t) ++ "]:" ++ F32.show(s))

def pct(+a: Nat, +n: Nat) -> String:
  F32.show(F32.div(F32.mul(100.0, F32.from_nat(a)), F32.max(1.0, F32.from_nat(n)))) ++ "%"

def per.show(ns: List<&2, F32>, oks: List<&2, F32>, +t: Nat) -> String:
  match ns oks:
    case +n <> nt o <> ot:
      Bool.pick(String, F32.is_lt(0.0, n), " " ++ Tg.name(t) ++ " " ++ F32.show(F32.div(F32.mul(100.0, o), n)) ++ "% of " ++ F32.show(n), "")
        ++ per.show(nt, ot, 1n+t)
    case _ _:
      ""

def per.of(r: List<&2, F32> & List<&2, F32>) -> String:
  (n, ok) = r
  per.show(n, ok, 0n)

def conf.row(xs: List<&2, F32>) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> t:
      " " ++ F32.show(x) ++ conf.row(t)

def conf.show(rows: List<&2, List<&2, F32>>, +g: Nat) -> String:
  match rows:
    case Nil{}:
      ""
    case r <> t:
      "    " ++ Tg.name(g) ++ ":" ++ conf.row(r) ++ "\n" ++ conf.show(t, 1n+g)

def f1(t: Mo.Tri) -> String:
  match t:
    case Mo.Tri{+tp, +fp, +fn}:
      "boundary F1 " ++ F32.show(F32.div(F32.mul(2.0, F32.from_nat(tp)), F32.max(1.0, F32.from_nat(Nat.add(Nat.mul(2n, tp), Nat.add(fp, fn))))))
        ++ " (tp " ++ Nat.show(tp) ++ ", fp " ++ Nat.show(fp) ++ ", fn " ++ Nat.show(fn) ++ ")"

# one population's report: legere against a baseline distribution
def report(+name: String, +docs: List<&2, List<&2, Mo.Pl>>, +pop: Nat, +base: List<&2, F32>, +bname: String) -> IO(Unit):
  +ps = Mo.flat.pop(pop, docs, Nil{})
  +n = List.length(&2, Mo.Pl, ps)
  +nf = F32.max(1.0, F32.from_nat(n))
  do IO<Unit>:
    IO.print(name ++ ": " ++ Nat.show(n) ++ " lines")
    IO.print("  legere:   " ++ F32.show(F32.div(Mo.bits(ps), nf)) ++ " bits/line, accuracy " ++ pct(Mo.oks(ps), n)
      ++ ", ECE " ++ F32.show(Mo.ece(ps)) ++ Bool.pick(String, Nat.is_eq(pop, 0n), ", " ++ f1(Mo.bnd(docs, pop, Mo.Tri{0n, 0n, 0n})), ""))
    IO.print("  " ++ bname ++ ": " ++ F32.show(F32.div(Mo.base.bits(ps, base), nf)) ++ " bits/line, accuracy "
      ++ pct(Mo.base.oks(ps, Mo.argmax(base)), n))
    IO.print("  per tag (recall):" ++ per.of(Mo.per.go(ps, Mo.zeros(Tg.k()), Mo.zeros(Tg.k()))))
    IO.print("  confusion (row gold, columns top tag 0..11):\n" ++ conf.show(Mo.conf.go(ps, Mo.conf.zero(Tg.k(), Tg.k())), 0n))

# Fitting: train on a corpus, fit the setting on its validation tenth ---------

type Fit is Type:
  Fit{ng: Array<F32>, h: Sp.Hmm<F32>, cs: List<&2, F32>, cfg: Cfg, vtag: String, log: String}

def fit.cfg(ng: Array<F32>, +h: Sp.Hmm<F32>, +cs: List<&2, F32>, +vtag: String, tl: Cfg & String) -> Fit:
  (cfg, log) = tl
  Fit{ng, h, cs, cfg, vtag, log}

def fit.fin(r: Array<F32> & List<&2, Dr>, +h: Sp.Hmm<F32>, +cs: List<&2, F32>) -> Fit:
  (ng, +vds) = r
  fit.cfg(ng, h, cs, Nat.show(List.length(&2, Dr, vds)) ++ " validation documents", best.t(grid(), h, vds, Cfg{False{}, 1.0}, F32.div(1.0, 0.0), ""))

def fit.counts(ng: Array<F32>, r: Array<F32> & List<&2, F32>, +docs: List<&2, J.Doc>) -> Fit:
  (tc, +cs) = r
  +h = Mo.hmm(cs)
  fit.fin(drs(ng, docs, True{}), h, cs)

def fit.two(two: Two, +docs: List<&2, J.Doc>) -> Fit:
  match two:
    case Two{ng, tc}:
      fit.counts(ng, Mo.counts(tc), docs)

def langs.two(two: Two, +dir: String, +budget: Nat) -> IO(Two):
  match two:
    case Two{ng, tc}:
      do IO<Two>:
        ng2 : Array<F32> <- langs(ng, dir, budget)
        return Two{ng2, tc}

# the model: line models, transitions, and the setting fit on validation
def fit(+corpus: String) -> IO(Fit):
  do IO<Fit>:
    +dir : String <- S.env("LANGS", "run/transcripts-final")
    +budget : Nat <- S.env.nat("BUDGET", U32.to_nat(6000000))
    +docs : List<&2, J.Doc> <- read.jsonl(corpus)
    +tb : List<&2, F32> = tag.bytes(docs, Mo.zeros(Tg.k()))
    +keep : List<&2, F32> = keep.of(tb, F32.from_nat(budget))
    Ck.log("legere: read " ++ Nat.show(List.length(&2, J.Doc, docs)) ++ " documents; session bytes per tag and the share kept:" ++ keep.show(tb, keep, 0n))
    two : Two = train.docs(docs, keep, Two{Ng.table(), Mo.cnt()})
    tw2 : Two <- langs.two(two, dir, budget)
    Ck.log("legere: counted the sessions and the languages; fitting the setting")
    return fit.two(tw2, docs)

# eval -----------------------------------------------------------------------

def eval.hold(r: Array<F32> & List<&2, Dr>, +h: Sp.Hmm<F32>, +cs: List<&2, F32>, +t: Cfg, +vtag: String, +log: String) -> IO(Unit):
  (ng, +hold) = r
  do IO<Unit>:
    Ck.log("legere: settings" ++ log)
    IO.print("legere eval: " ++ set.show(t) ++ " (fit on " ++ vtag ++ ")")
    report("bare blocks (holdout lines inside named blocks; fences forced, names hidden)",
      answers(h, hold, t, 1n), 1n, Mo.inside(cs), "p(tag | inside a block)")
    report("no fences (every labelled holdout line; nothing forced)",
      answers(h, hold, t, 0n), 0n, Mo.prior(cs), "prior p(tag)            ")

def eval.with(f: Fit, +hold: List<&2, J.Doc>) -> IO(Unit):
  match f:
    case Fit{ng, h, cs, cfg, vtag, log}:
      eval.hold(drs(ng, hold, False{}), h, cs, cfg, vtag, log)

def eval(+corpus: String, +holdout: String) -> IO(Unit):
  do IO<Unit>:
    f : Fit <- fit(corpus)
    +hold : List<&2, J.Doc> <- read.jsonl(holdout)
    eval.with(f, hold)

# segment ----------------------------------------------------------------------
#
# Every input document labelled with every cue forced (mode 2), cut into
# sections:
#   OUT/sections.nul       DOC#K, then tag 0x1E first line 0x1E lines 0x1E
#                          shares 0x1E the section's text
#   OUT/LANG/files.nul     own:legere/DOC-K.EXT, the code (a section with a
#                          share of at least 0.9 of LANG, wrapped)
#   OUT/LANG/prose.nul     the same ids, each code's User line
#   OUT/src/legere/...     the Bend files, for bend-check's BEND_SRC

type Sg is Data:
  Sg{secs: List<&2, List<&2, U32>>, code: List<&2, O.Ce>, bad: Nat}

def sg.add(r: List<&2, List<&2, U32>> & List<&2, O.Ce>, +bad: Nat) -> Sg:
  (sa, ca) = r
  Sg{sa, ca, bad}

def sg.doc(+id: List<&2, U32>, +text: List<&2, U32>, +secs: List<&2, Sp.Sec<O.Lp>>, acc: Sg) -> Sg:
  match acc:
    case Sg{sa, ca, bad}:
      sg.add(O.doc.go(secs, id, 0n, 0n, Nil{}, sa, ca), Nat.add(bad, Bool.pick(Nat, S.eq(O.text.of(secs), text), 0n, 1n)))

def seg.go(docs: List<&2, J.Doc>, ds: List<&2, Dr>, +h: Sp.Hmm<F32>, +t: Cfg, acc: Sg) -> Sg:
  match docs ds t:
    case J.Doc{+id, +text} <> dt Dr{+labs, +raws, +ls} <> drt Cfg{+m, +sc}:
      seg.go(dt, drt, h, Cfg{m, sc}, sg.doc(id, text, O.sections(Mo.answer(h, raws, labs, ls, m, sc, 2n), ls), acc))
    case _ _ _:
      acc

def ce.files(cs: List<&2, O.Ce>, +t: Nat) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case O.Ce{+u, +id, +code, user} <> rest:
      S.append(Bool.pick(List<&2, U32>, Nat.is_eq(u, t), S.append(id, S.append(O.nul(), S.append(code, O.nul()))), Nil{}), ce.files(rest, t))

def ce.prose(cs: List<&2, O.Ce>, +t: Nat) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case O.Ce{+u, +id, code, +user} <> rest:
      S.append(Bool.pick(List<&2, U32>, Nat.is_eq(u, t), S.append(id, S.append(O.nul(), S.append(user, O.nul()))), Nil{}), ce.prose(rest, t))

def ce.count(cs: List<&2, O.Ce>, +t: Nat) -> Nat:
  match cs:
    case Nil{}:
      0n
    case O.Ce{+u, id, code, user} <> rest:
      Nat.add(Bool.pick(Nat, Nat.is_eq(u, t), 1n, 0n), ce.count(rest, t))

def write.lang(+out: String, +cs: List<&2, O.Ce>, +t: Nat, +l: String) -> IO(Unit):
  do IO<Unit>:
    S.mkdir(out ++ "/" ++ l)
    S.write(out ++ "/" ++ l ++ "/files.nul", ce.files(cs, t))
    S.write(out ++ "/" ++ l ++ "/prose.nul", ce.prose(cs, t))
    IO.print("legere segment: " ++ l ++ ": " ++ Nat.show(ce.count(cs, t)) ++ " code sections")

def write.bend.one(yes: Bool, +out: String, +id: List<&2, U32>, +code: List<&2, U32>) -> IO(Unit):
  match yes:
    case True{}:
      S.write(out ++ "/src/" ++ S.str(List.drop(&2, U32, id, 4n)), code)
    case False{}:
      IO.pure(Unit, Unit{})

# the Bend files under OUT/src (the id without its own: class)
def write.bend(+out: String, cs: List<&2, O.Ce>) -> IO(Unit):
  match cs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case O.Ce{+u, +id, +code, user} <> rest:
      do IO<Unit>:
        write.bend.one(Nat.is_eq(u, 4n), out, id, code)
        write.bend(out, rest)

def seg.write(+out: String, acc: Sg) -> IO(Unit):
  match acc:
    case Sg{+sa, +ca, bad}:
      do IO<Unit>:
        S.mkdir(out ++ "/src/legere")
        S.write(out ++ "/sections.nul", O.join(List.reverse(&2, List<&2, U32>, sa)))
        IO.print("legere segment: " ++ Nat.show(List.length(&2, List<&2, U32>, sa)) ++ " sections; " ++ Nat.show(bad) ++ " documents whose sections do not give their text back")
        write.lang(out, ca, 1n, "haskell")
        write.lang(out, ca, 2n, "agda")
        write.lang(out, ca, 3n, "lean")
        write.lang(out, ca, 4n, "bend")
        write.lang(out, ca, 5n, "nix")
        write.bend(out, ca)

def seg.rows(r: Array<F32> & List<&2, Dr>, +h: Sp.Hmm<F32>, +t: Cfg, +docs: List<&2, J.Doc>, +out: String) -> IO(Unit):
  (ng, +ds) = r
  seg.write(out, seg.go(docs, ds, h, t, Sg{Nil{}, Nil{}, 0n}))

def seg.with(f: Fit, +docs: List<&2, J.Doc>, +out: String) -> IO(Unit):
  match f:
    case Fit{ng, h, cs, +cfg, vtag, log}:
      do IO<Unit>:
        Ck.log("legere: " ++ set.show(cfg) ++ " (fit on " ++ vtag ++ ")")
        seg.rows(drs(ng, docs, False{}), h, cfg, docs, out)

def segment(+corpus: String, +input: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    f : Fit <- fit(corpus)
    +docs : List<&2, J.Doc> <- read.jsonl(input)
    seg.with(f, docs, out)

# units -------------------------------------------------------------------------
#
#   bend-legere units OUT LANG
#     bend-units LANG OUT/LANG/files.nul OUT/LANG/units.raw.nul ($BEND_UNITS,
#     default bend-units), then each unit's doc (field 3, which
#     bend-transcript makes the User line) set to its file's User line from
#     OUT/LANG/prose.nul when that is not empty: OUT/LANG/units.nul.  From
#     there bend-check, bend-clean and bend-transcript run unchanged.

def kv.map(fs: List<&2, List<&2, U32>>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match fs:
    case k <> v <> rest:
      kv.map(rest, Map.set(&2, List<&2, U32>, m, S.str(k), v))
    case _:
      m

# the file id of a unit id: the bytes before its first '#'
def file.of(+uid: List<&2, U32>) -> String:
  S.str(Li.upto(uid, 35))

def set.doc(fs: List<&2, List<&2, U32>>, +user: List<&2, U32>, +i: Nat) -> List<&2, List<&2, U32>>:
  match fs:
    case Nil{}:
      Nil{}
    case f <> t:
      Bool.pick(List<&2, U32>, Bool.and(Nat.is_eq(i, 3n), Bool.not(S.eq(user, Nil{}))), user, f) <> set.doc(t, user, 1n+i)

def map.v(r: Map<&2, List<&2, U32>> & List<&2, U32>) -> List<&2, U32>:
  (m, v) = r
  v

def re.doc(+user: List<&2, U32>, +uid: List<&2, U32>, +rec: List<&2, U32>) -> List<&2, U32>:
  S.append(uid, S.append([0], S.append(S.join(set.doc(S.split(rec, 30), user, 0n), 30), [0])))

def re.go(fs: List<&2, List<&2, U32>>, +m: Map<&2, List<&2, U32>>, acc: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match fs:
    case +uid <> +rec <> rest:
      re.go(rest, m, re.doc(map.v(Map.get(List<&2, U32>, Nil{}, m, file.of(uid))), uid, rec) <> acc)
    case _:
      O.join(List.reverse(&2, List<&2, U32>, acc))

def units.fin(+dir: String, raw: Maybe<&2, List<&2, U32>>, prose: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match raw prose:
    case Some{+r} Some{p}:
      do IO<Unit>:
        S.write(dir ++ "/units.nul", re.go(S.split(r, 0), kv.map(S.split(p, 0), Map.new(&2, List<&2, U32>)), Nil{}))
        IO.print("legere units: " ++ Nat.show(Nat.div(List.length(&2, List<&2, U32>, S.split(r, 0)), 2n)) ++ " units in " ++ dir ++ "/units.nul")
    case _ _:
      IO.die(Unit, 1, "legere units: cannot read " ++ dir ++ "/units.raw.nul or prose.nul")

def units(+out: String, +lang: String) -> IO(Unit):
  +dir = out ++ "/" ++ lang
  do IO<Unit>:
    +bu : String <- S.env("BEND_UNITS", "bend-units")
    log : List<&2, U32> <- S.must("legere units: bend-units", bu, [lang, dir ++ "/files.nul", dir ++ "/units.raw.nul"])
    raw : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/units.raw.nul")
    prose : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/prose.nul")
    units.fin(dir, raw, prose)

# notes ------------------------------------------------------------------------
#
#   bend-legere notes OUT LANG
#     every code file of OUT/LANG/files.nul compiled whole by its language's
#     checker, pass or fail (Jev's check, made ours: the compiler decides):
#     OUT/LANG/notes.nul holds the file's id, then its exit status 0x1F the
#     checker's output (the first 40 lines, the work directory's path
#     removed).  The transcripts keep ana's rule (bend-check drops a unit
#     whose original fails, so no transcript answers with broken code); the
#     notes keep every compiler's word on every piece of code found.

# a language's checker command: program, arguments, file, environment
def c.prog(+lang: String) -> String:
  Bool.pick(String, String.eq(lang, "haskell"), "ghc", Bool.pick(String, String.eq(lang, "agda"), "agda",
    Bool.pick(String, String.eq(lang, "lean"), "lean", Bool.pick(String, String.eq(lang, "bend"), "bend", "nix-instantiate"))))

def c.file(+lang: String) -> String:
  "Snippet" ++ Bool.pick(String, String.eq(lang, "haskell"), ".hs", Bool.pick(String, String.eq(lang, "agda"), ".agda",
    Bool.pick(String, String.eq(lang, "lean"), ".lean", Bool.pick(String, String.eq(lang, "bend"), ".bend", ".nix"))))

def c.args.of(+lang: String, hs: Bool, bd: Bool, nx: Bool) -> List<String>:
  match hs bd nx:
    case True{} _ _:
      ["-fno-code", "-fdiagnostics-color=never", c.file(lang)]
    case _ True{} _:
      [c.file(lang), "--check-only"]
    case _ _ True{}:
      ["--eval", "--strict", c.file(lang)]
    case _ _ _:
      [c.file(lang)]

def c.args(+lang: String) -> List<String>:
  c.args.of(lang, String.eq(lang, "haskell"), String.eq(lang, "bend"), String.eq(lang, "nix"))

def c.env.of(nx: Bool) -> List<String>:
  match nx:
    case True{}:
      ["NIX_PATH="]
    case False{}:
      []

def c.env(+lang: String) -> List<String>:
  c.env.of(String.eq(lang, "nix"))

# Agda: the file's top module must be named after the file, so the first
# `module NAME` line names Snippet instead (the rest of the line kept)
def not.sep(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      Bool.not(Bool.or(U32.is_eq(h, 32), U32.is_eq(h, 10)))
    case Nil{}:
      False{}

def word.drop(+xs: List<&2, U32>, go: Bool) -> List<&2, U32>:
  match xs go:
    case h <> +t True{}:
      word.drop(t, not.sep(t))
    case _ _:
      xs

def agda.fix(+l: List<&2, U32>, +done: Bool) -> List<&2, U32>:
  +rest = List.drop(&2, U32, l, 7n)
  Bool.pick(List<&2, U32>, Bool.and(Bool.not(done), S.prefix(l, S.b("module "))),
    S.append(S.b("module Snippet"), word.drop(rest, not.sep(rest))), l)

def agda.go(ls: List<&2, List<&2, U32>>, +done: Bool) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      S.append(agda.fix(l, done), agda.go(t, Bool.or(done, S.prefix(l, S.b("module ")))))

def note(+id: List<&2, U32>, +o: S.Out, +dir: String) -> List<&2, U32>:
  S.append(id, S.append([0], S.append(S.b(U32.show(S.Out.status(o))), S.append([31], S.append(S.clean(dir, 40n, S.Out.text(o)), [0])))))

def notes.go(fs: List<&2, List<&2, U32>>, +lang: String, acc: List<&2, List<&2, U32>>) -> IO(List<&2, U32>):
  match fs:
    case +id <> +code <> rest:
      do IO<List<&2, U32>>:
        +dir : String <- S.mktemp()
        S.write(dir ++ "/" ++ c.file(lang), Bool.pick(List<&2, U32>, String.eq(lang, "agda"), agda.go(Li.lines(code), False{}), code))
        +o : S.Out <- S.run(dir, c.env(lang), 300, c.prog(lang), c.args(lang), Nil{})
        S.rm(dir)
        notes.go(rest, lang, note(id, o, dir) <> acc)
    case _:
      IO.pure(List<&2, U32>, O.join(List.reverse(&2, List<&2, U32>, acc)))

def notes.fin(+dir: String, m: Maybe<&2, List<&2, U32>>, +lang: String) -> IO(Unit):
  match m:
    case Some{+fs}:
      do IO<Unit>:
        +xs : List<&2, U32> <- notes.go(S.split(fs, 0), lang, Nil{})
        S.write(dir ++ "/notes.nul", xs)
        IO.print("legere notes: " ++ Nat.show(Nat.div(List.length(&2, List<&2, U32>, S.split(xs, 0)), 2n)) ++ " files compiled; " ++ dir ++ "/notes.nul")
    case None{}:
      IO.die(Unit, 1, "legere notes: cannot read " ++ dir ++ "/files.nul")

def notes(+out: String, +lang: String) -> IO(Unit):
  +dir = out ++ "/" ++ lang
  do IO<Unit>:
    m : Maybe<&2, List<&2, U32>> <- S.slurp(dir ++ "/files.nul")
    notes.fin(dir, m, lang)

# Explaining a file: each line's mean log probability per byte under every
# scored tag (the model's evidence, before the scale and the transitions)
def ex.row(xs: List<&2, F32>, +n: F32, +t: Nat) -> String:
  match xs:
    case Nil{}:
      ""
    case x <> rest:
      Bool.pick(String, Nat.is_lt(t, Tg.scored()), " " ++ Tg.name(t) ++ "=" ++ F32.show(F32.div(x, n)), "") ++ ex.row(rest, n, 1n+t)

def ex.lines(raws: List<&2, List<&2, F32>>, ls: List<&2, List<&2, U32>>) -> String:
  match raws ls:
    case +r <> rt +l <> lt:
      +n = F32.from_nat(Nat.max(1n, List.length(&2, U32, l)))
      +top = Mo.argmax(List.take(&2, F32, r, Tg.scored()))
      Tg.name(top) ++ " |" ++ ex.row(r, n, 0n) ++ " | " ++ S.str(Li.trim(l)) ++ "\n" ++ ex.lines(rt, lt)
    case _ _:
      ""

def ex.fin(r: Array<F32> & List<&2, List<&2, F32>>, +ls: List<&2, List<&2, U32>>) -> IO(Unit):
  (a, raws) = r
  IO.print(ex.lines(raws, ls))

def ex.got(two: Two, m: Maybe<&2, List<&2, U32>>) -> IO(Unit):
  match two m:
    case Two{ng, tc} Some{+text}:
      +ls = Li.lines(text)
      ex.fin(Mo.raw.rows(ng, ls), ls)
    case _ _:
      IO.die(Unit, 1, "legere explain: cannot read the file")

def explain(+corpus: String, +file: String) -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.env("LANGS", "run/transcripts-final")
    +budget : Nat <- S.env.nat("BUDGET", U32.to_nat(6000000))
    +docs : List<&2, J.Doc> <- read.jsonl(corpus)
    +tb : List<&2, F32> = tag.bytes(docs, Mo.zeros(Tg.k()))
    two : Two = train.docs(docs, keep.of(tb, F32.from_nat(budget)), Two{Ng.table(), Mo.cnt()})
    tw2 : Two <- langs.two(two, dir, budget)
    m : Maybe<&2, List<&2, U32>> <- S.slurp(file)
    ex.got(tw2, m)

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-legere eval CORPUS HOLDOUT | segment CORPUS INPUT OUT | units OUT LANG | notes OUT LANG | explain CORPUS FILE")

def args.go(xs: List<String>) -> IO(Unit):
  match xs:
    case "eval" <> +c <> +h <> Nil{}:
      eval(c, h)
    case "explain" <> +c <> +f <> Nil{}:
      explain(c, f)
    case "segment" <> +c <> +i <> +o <> Nil{}:
      segment(c, i, o)
    case "units" <> +o <> +l <> Nil{}:
      units(o, l)
    case "notes" <> +o <> +l <> Nil{}:
      notes(o, l)
    case _:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    # IO.args leads with the program as invoked (Bend 2.0.32)
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    args.go(xs)
