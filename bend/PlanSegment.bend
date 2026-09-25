import Base
import ./Nul.bend as Ns
import ./Corpus.bend as Cc
import ./Config.bend as C
import ./Train.bend as Tr
import ./Train/Data.bend as D


# plan-segment: master's `formal-transformer plan-segment CORPUS
# DOCUMENT_OFFSET TRAIN_BATCH SIZE` (Main.hs planSegment):
#
#   bend-plan-segment CORPUS OFFSET BATCH SIZE
#
# prints one line
#
#   segment OFFSET DOCS DATASET TRAIN_WINDOWS VALID_WINDOWS STEPS
#
# Meaning: the shard's documents are numbered from OFFSET (their place in
# the whole corpus), split by the trainer's rule (Train/Data.bend: document
# i is held out iff mix(seed + i) mod 10^6 < 10^5), and each contributes
# its full windows at the preset's context: a document of n tokens is the
# stream BOS : tokens ++ [EOS] of n + 2, cut into floor((n + 2) / ctx)
# windows.  STEPS is the training windows over BATCH, rounded up.  A shard
# with no training window is refused, as master refused it.

def windows(ds: List<&2, List<&2, U32>>, +ctx: Nat) -> Nat:
  match ds:
    case Nil{}:
      0n
    case d <> more:
      Nat.add(Nat.div(Nat.add(List.length(&2, U32, d), 2n), ctx), windows(more, ctx))

def line(+offset: Nat, +docs: Nat, +dataset: String, +tw: Nat, +vw: Nat, +batch: Nat) -> String:
  "segment " ++ Nat.show(offset) ++ " " ++ Nat.show(docs) ++ " " ++ dataset ++ " "
    ++ Nat.show(tw) ++ " " ++ Nat.show(vw) ++ " " ++ Nat.show(Nat.div(Nat.sub(Nat.add(tw, batch), 1n), batch))

def report(+offset: Nat, +docs: Nat, +dataset: String, +tw: Nat, +vw: Nat, +batch: Nat, none: Bool) -> IO(Unit):
  match none:
    case True{}:
      IO.die(Unit, 1, "plan-segment: training split has no full context sequences")
    case False{}:
      IO.print(line(offset, docs, dataset, tw, vw, batch))

def plan.split(sp: D.Split, +offset: Nat, +docs: Nat, +dataset: String, +batch: Nat, +ctx: Nat) -> IO(Unit):
  match sp:
    case D.Split{train, valid}:
      +tw = windows(train, ctx)
      report(offset, docs, dataset, tw, windows(valid, ctx), batch, Nat.is_eq(tw, 0n))

def plan(c: Cc.Corpus, +offset: Nat, +batch: Nat, +ctx: Nat) -> IO(Unit):
  match c:
    case Cc.Corpus{m, v, t, dataset, +docs}:
      plan.split(D.split.go(docs, offset), offset, List.length(&2, List<&2, U32>, docs), dataset, batch, ctx)

def corpus.ok(+c: Cc.Corpus) -> Bool:
  match c:
    case Cc.Corpus{m, v, t, d, x}:
      U32.is_eq(m, 1179927363)

def plan.magic(+c: Cc.Corpus, +offset: Nat, +batch: Nat, +ctx: Nat, ok: Bool) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, "plan-segment: not a compact corpus (magic is not FTCC)")
    case True{}:
      plan(c, offset, batch, ctx)

def checked(+path: String, +offset: Nat, +batch: Nat, +size: String, known: Bool, positive: Bool) -> IO(Unit):
  match known positive:
    case False{} _:
      IO.die(Unit, 2, "plan-segment: unknown model size " ++ size ++ " (expected one of the presets in Train.bend preset.names)")
    case True{} False{}:
      IO.die(Unit, 2, "plan-segment: TRAIN_BATCH must be positive")
    case True{} True{}:
      do IO<Unit>:
        +xs : List<&2, U32> <- Ns.read(path)
        +c : Cc.Corpus <- IO.pure(Cc.Corpus, Cc.corpus(xs))
        plan.magic(c, offset, batch, C.Config.ctx(Tr.preset(size)), corpus.ok(c))

def numbers(+path: String, mo: Maybe<&2, Nat>, mb: Maybe<&2, Nat>, +size: String) -> IO(Unit):
  match mo mb:
    case Some{+o} Some{+b}:
      checked(path, o, b, size, Tr.preset.known(size), Bool.not(Nat.is_eq(b, 0n)))
    case _ _:
      IO.die(Unit, 2, "plan-segment: DOCUMENT_OFFSET must be nonnegative and TRAIN_BATCH must be positive")

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case path <> offset <> batch <> size <> Nil{}:
      numbers(path, Nat.read(offset), Nat.read(batch), size)
    case _:
      IO.die(Unit, 2, "usage: bend-plan-segment CORPUS DOCUMENT_OFFSET TRAIN_BATCH SIZE")

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
