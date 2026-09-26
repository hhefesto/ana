import Base
import ./Bytes.bend as B
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns
import ./Corpus.bend as Cc
import ./Ftcc.bend as Fc

# windows: whole transcripts packed into training documents of exactly one
# context each, the space they leave filled with the end of a code file.
#
#   bend-windows lengths CORPUS
#   bend-windows build TRANSCRIPTS FILLER PLAN OUTPUT CAPACITY PREFIX
#
# Meaning.  The trainer cuts a document of n tokens into the windows of
# BOS : tokens ++ [EOS] and drops the remainder, so a document of exactly
# CAPACITY = ctx - 2 tokens is one window, nothing dropped.  A window
# document here is the last f tokens of a filler document (raw code: a
# file's end, which EOS truly follows), then, for each of its transcripts
# in order, EOS (token 1) and the transcript's tokens:
#
#   window = drop(len(filler) - f, filler) ++ concat [1 : t | t <- ts]
#
# so no transcript is ever cut, each transcript starts right after an EOS
# (as a conversation starts), and the trainer's final EOS ends the last.
#
# `lengths` prints each document's token count, one per line.  PLAN (from
# deploy/plan-transcripts.sh's first-fit-decreasing pass over those
# counts) has one line per window, `f skip k`: the window takes the next k
# transcripts in TRANSCRIPTS' order and, when f > 0, the last f tokens of
# the filler document `skip` documents after the one the previous filler
# came from (every filler document is used at most once, in order).  A
# window whose length is not CAPACITY, a plan that runs past either
# corpus, or a filler shorter than f is refused (exit 1, nothing written).
# The output is FTCC v2 with TRANSCRIPTS' tokenizer identity and master's
# dataset fingerprint (Ftcc.bend); window ids are PREFIX-00000000,
# PREFIX-00000001, ...

type Plan is Data:
  Plan{f: Nat, skip: Nat, k: Nat}

# The plan: every natural number in the text, in threes ---------------------

def digit(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

# the numbers of xs, newest first; cur is the number being read (none: 0n
# and not reading)
def nums.go(xs: List<&2, U32>, +cur: Nat, +reading: Bool, +acc: List<&2, Nat>) -> List<&2, Nat>:
  match xs:
    case Nil{}:
      Bool.pick(List<&2, Nat>, reading, cur <> acc, acc)
    case +c <> t:
      +d = digit(c)
      +v = Nat.add(Nat.mul(cur, 10n), U32.to_nat(U32.sub(c, 48)))
      nums.go(t, Bool.pick(Nat, d, v, 0n), d, Bool.pick(List<&2, Nat>, Bool.and(reading, Bool.not(d)), cur <> acc, acc))

def plans(ns: List<&2, Nat>) -> List<&2, Plan>:
  match ns:
    case f <> s <> k <> t:
      Plan{f, s, k} <> plans(t)
    case _:
      Nil{}

def plan.read(+xs: List<&2, U32>) -> List<&2, Plan>:
  plans(List.reverse(&2, Nat, nums.go(xs, 0n, False{}, Nil{})))

# Windows ----------------------------------------------------------------

def pad8(+n: Nat) -> String:
  +s = Nat.show(n)
  String.concat(List.replicate(String, Nat.sub(8n, String.length(s)), "0")) ++ s

def id.of(+prefix: String, +i: Nat) -> List<&2, U32>:
  Tk.str.bytes(prefix ++ "-" ++ pad8(i))

def eos.join(ts: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ts:
    case Nil{}:
      Nil{}
    case t <> more:
      1 <> List.append(&2, U32, t, eos.join(more))

def last(+xs: List<&2, U32>, +f: Nat) -> List<&2, U32>:
  List.drop(&2, U32, xs, Nat.sub(List.length(&2, U32, xs), f))

# The build: one pass over the plan, the state carrying what is left of both
# corpora, the windows so far (newest first) and the first problem met (after
# which nothing more is built)
type St is Data:
  St{fs: List<&2, List<&2, U32>>, ts: List<&2, List<&2, U32>>, problem: String, docs: List<&2, Fc.Doc>}

# the filler of a window: f = 0 takes none and keeps the filler stream;
# otherwise skip documents, take the next one's last f tokens
def filler.next(+f: Nat, fs: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  match fs:
    case Nil{}:
      (None{}, Nil{})
    case +x <> more:
      (Bool.pick(Maybe<&2, List<&2, U32>>, Nat.is_le(f, List.length(&2, U32, x)), Some{last(x, f)}, None{}), more)

def filler.take(+f: Nat, +skip: Nat, fs: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  match f:
    case 0n:
      (Some{Nil{}}, fs)
    case 1n+p:
      filler.next(1n+p, List.drop(&2, List<&2, U32>, fs, skip))

def St.check(ok: Bool, +toks: List<&2, U32>, fs: List<&2, List<&2, U32>>, ts: List<&2, List<&2, U32>>, docs: List<&2, Fc.Doc>, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match ok:
    case False{}:
      St{fs, ts, "windows: window " ++ Nat.show(i) ++ " holds " ++ Nat.show(List.length(&2, U32, toks)) ++ " tokens, not " ++ Nat.show(cap) ++ " (or the transcripts ran out)", docs}
    case True{}:
      St{fs, ts, "", Fc.Doc{id.of(prefix, i), toks} <> docs}

def St.fill(fl: Maybe<&2, List<&2, U32>>, fs: List<&2, List<&2, U32>>, +ts: List<&2, List<&2, U32>>, docs: List<&2, Fc.Doc>, +k: Nat, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match fl:
    case None{}:
      St{fs, ts, "windows: window " ++ Nat.show(i) ++ ": the filler corpus ran out or its document is too short", docs}
    case Some{+pre}:
      +mine = List.take(&2, List<&2, U32>, ts, k)
      +toks = List.append(&2, U32, pre, eos.join(mine))
      St.check(Bool.and(Nat.is_eq(List.length(&2, List<&2, U32>, mine), k), Nat.is_eq(List.length(&2, U32, toks), cap)), toks, fs, List.drop(&2, List<&2, U32>, ts, k), docs, cap, prefix, i)

def St.take(r: Maybe<&2, List<&2, U32>> & List<&2, List<&2, U32>>, +ts: List<&2, List<&2, U32>>, docs: List<&2, Fc.Doc>, +k: Nat, +cap: Nat, +prefix: String, +i: Nat) -> St:
  (fl, rest) = r
  St.fill(fl, rest, ts, docs, k, cap, prefix, i)

def St.step.ok(ok: Bool, fs: List<&2, List<&2, U32>>, +ts: List<&2, List<&2, U32>>, +prob: String, docs: List<&2, Fc.Doc>, p: Plan, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match ok p:
    case False{} _:
      St{fs, ts, prob, docs}
    case True{} Plan{+f, +skip, +k}:
      St.take(filler.take(f, skip, fs), ts, docs, k, cap, prefix, i)

def St.step(st: St, p: Plan, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match st:
    case St{fs, ts, +prob, docs}:
      St.step.ok(String.is_empty(prob), fs, ts, prob, docs, p, cap, prefix, i)

def build.go(ps: List<&2, Plan>, st: St, +cap: Nat, +prefix: String, +i: Nat) -> St:
  match ps:
    case Nil{}:
      st
    case p <> more:
      build.go(more, St.step(st, p, cap, prefix, i), cap, prefix, 1n+i)

# Main -------------------------------------------------------------------

def lengths.show(ds: List<&2, List<&2, U32>>) -> String:
  match ds:
    case Nil{}:
      ""
    case d <> more:
      Nat.show(List.length(&2, U32, d)) ++ "\n" ++ lengths.show(more)

def lengths(+path: String) -> IO(Unit):
  do IO<Unit>:
    +xs : List<&2, U32> <- Ns.read(path)
    +c : Cc.Corpus <- IO.pure(Cc.Corpus, Cc.corpus(xs))
    Ns.write(path ++ ".lengths", Tk.str.bytes(lengths.show(Cc.Corpus.docs(c))))

def tok.of(+c: Cc.Corpus) -> String:
  match c:
    case Cc.Corpus{m, v, t, d, x}:
      t

def write.if(ok: Bool, +ds: List<&2, Fc.Doc>, +tok: String, +out: String, +p: String) -> IO(Unit):
  match ok:
    case False{}:
      IO.die(Unit, 1, p)
    case True{}:
      +tb = Tk.str.bytes(tok)
      +dataset = Fc.dataset(tb, ds)
      do IO<Unit>:
        Ns.write(out, Fc.bytes(tb, Tk.str.bytes(dataset), ds))
        IO.print("windows: " ++ Nat.show(List.length(&2, Fc.Doc, ds)) ++ " windows written to " ++ out)
        IO.print("dataset fingerprint: " ++ dataset)

def write(st: St, +tok: String, +out: String) -> IO(Unit):
  match st:
    case St{fs, ts, +p, ds}:
      write.if(String.is_empty(p), List.reverse(&2, Fc.Doc, ds), tok, out, p)

def build(+tp: String, +fp: String, +pp: String, +out: String, +cap: Nat, +prefix: String) -> IO(Unit):
  do IO<Unit>:
    +tx : List<&2, U32> <- Ns.read(tp)
    +fx : List<&2, U32> <- Ns.read(fp)
    +px : List<&2, U32> <- Ns.read(pp)
    +tc : Cc.Corpus <- IO.pure(Cc.Corpus, Cc.corpus(tx))
    +fc : Cc.Corpus <- IO.pure(Cc.Corpus, Cc.corpus(fx))
    write(build.go(plan.read(px), St{Cc.Corpus.docs(fc), Cc.Corpus.docs(tc), "", Nil{}}, cap, prefix, 0n), tok.of(tc), out)

def build.cap(+t: String, +f: String, +p: String, +o: String, m: Maybe<&2, Nat>, +pre: String) -> IO(Unit):
  match m:
    case Some{+c}:
      build(t, f, p, o, c, pre)
    case None{}:
      IO.die(Unit, 2, "windows: CAPACITY must be a natural number")

def usage() -> IO(Unit):
  IO.die(Unit, 2, "usage: bend-windows lengths CORPUS | bend-windows build TRANSCRIPTS FILLER PLAN OUTPUT CAPACITY PREFIX")

def args.go(ls: Bool, bd: Bool, rest: List<String>) -> IO(Unit):
  match ls bd rest:
    case True{} _ p <> Nil{}:
      lengths(p)
    case False{} True{} t <> f <> p <> o <> c <> pre <> Nil{}:
      build.cap(t, f, p, o, Nat.read(c), pre)
    case _ _ _:
      usage()

def args(xs: List<String>) -> IO(Unit):
  match xs:
    case +m <> rest:
      args.go(String.eq(m, "lengths"), String.eq(m, "build"), rest)
    case Nil{}:
      usage()

def main() -> IO(Unit):
  do IO<Unit>:
    xs : List<String> <- IO.args()
    args(xs)
