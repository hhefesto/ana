import Base
import ../Num.bend as N
import ../Train/Data.bend as D

# Master's run plan (backend/gpu/Main.hs parsePlan, trainInContext): the
# corpus is sharded, and segment k of the plan trains shard k's training
# windows for steps start+1 .. end of the global schedule. A shard's
# documents split into training and validation by their GLOBAL index (the
# segment's document offset plus the index within the shard, Data.hs
# trainingSequencesFrom), and each is cut into full windows. Within a
# segment the windows are visited in epoch order (epochSampler): sorted by
# splitmix of their index + 0x45504f4348, then sliced cyclically, batch b
# of global step s being positions ((s - start - 1)·b + i) mod count.

type Seg is Data:
  Seg{index: Nat, offset: Nat, id: String, tw: Nat, start: Nat, end: Nat}

def Seg.index(+s: Seg) -> Nat:
  match s:
    case Seg{i, o, d, t, a, e}:
      i

def Seg.offset(+s: Seg) -> Nat:
  match s:
    case Seg{i, o, d, t, a, e}:
      o

def Seg.id(+s: Seg) -> String:
  match s:
    case Seg{i, o, d, t, a, e}:
      d

def Seg.tw(+s: Seg) -> Nat:
  match s:
    case Seg{i, o, d, t, a, e}:
      t

def Seg.start(+s: Seg) -> Nat:
  match s:
    case Seg{i, o, d, t, a, e}:
      a

def Seg.end(+s: Seg) -> Nat:
  match s:
    case Seg{i, o, d, t, a, e}:
      e

# Text -----------------------------------------------------------------------

def cut.push(+c: U32, r: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match r:
    case Nil{}:
      [[c]]
    case w <> t:
      (c <> w) <> t

def cut.if(hit: Bool, +c: U32, r: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match hit:
    case True{}:
      Nil{} <> r
    case False{}:
      cut.push(c, r)

# the byte list cut at every `sep` (empty pieces kept)
def cut(xs: List<&2, U32>, +sep: U32) -> List<&2, List<&2, U32>>:
  match xs:
    case Nil{}:
      [Nil{}]
    case +c <> t:
      cut.if(U32.is_eq(c, sep), c, cut(t, sep))

def nat.go(xs: List<&2, U32>, +acc: Nat) -> Nat:
  match xs:
    case Nil{}:
      acc
    case +c <> t:
      nat.go(t, Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(c, 48))))

def nat(xs: List<&2, U32>) -> Nat:
  nat.go(xs, 0n)

def text(xs: List<&2, U32>) -> String:
  match xs:
    case Nil{}:
      SNil{}
    case c <> t:
      SCon{Chr{c}, text(t)}

def same(xs: List<&2, U32>, ys: List<&2, U32>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> a +y <> b:
      Bool.and(U32.is_eq(x, y), same(a, b))
    case _ _:
      False{}

# the fields are read only on a segment line (the header's are hashes)
def line.if(seg: Bool, ws: List<&2, List<&2, U32>>) -> List<&2, Seg>:
  match seg ws:
    case True{} i <> o <> d <> id <> tw <> vw <> st <> a <> e <> t:
      [Seg{nat(i), nat(o), text(id), nat(tw), nat(a), nat(e)}]
    case _ _:
      Nil{}

# segment <index> <offset> <docs> <identity> <tw> <vw> <steps> <start> <end>
def line(ws: List<&2, List<&2, U32>>) -> List<&2, Seg>:
  match ws:
    case +k <> t:
      line.if(same(k, [115, 101, 103, 109, 101, 110, 116]), t)
    case _:
      Nil{}

def segs(ls: List<&2, List<&2, U32>>) -> List<&2, Seg>:
  match ls:
    case Nil{}:
      Nil{}
    case l <> t:
      List.append(&2, Seg, line(cut(l, 32)), segs(t))

# the plan file's segment lines
def parse(xs: List<&2, U32>) -> List<&2, Seg>:
  segs(cut(xs, 10))

def total.of(ws: List<&2, List<&2, U32>>) -> Nat:
  match ws:
    case p <> v <> t <> r:
      nat(t)
    case _:
      0n

# the header's global step total: plan <version> <total> ...
def total(xs: List<&2, U32>) -> Nat:
  total.of(cut(List.take(&2, U32, xs, 64n), 32))

# whether the list's first segment is unfinished after `done` steps (an
# empty list: stop)
def unfinished(ss: List<&2, Seg>, +done: Nat) -> Bool:
  match ss:
    case Nil{}:
      True{}
    case +s <> t:
      Nat.is_lt(done, Seg.end(s))

def remaining.go(+ss: List<&2, Seg>, stop: Bool, +done: Nat) -> List<&2, Seg>:
  match ss stop:
    case _ True{}:
      ss
    case Nil{} False{}:
      Nil{}
    case s <> +t False{}:
      remaining.go(t, unfinished(t, done), done)

# the segments still to train after `done` steps (the plan is in order,
# so they are a suffix)
def remaining(+ss: List<&2, Seg>, +done: Nat) -> List<&2, Seg>:
  remaining.go(ss, unfinished(ss, done), done)

# Windows ------------------------------------------------------------------

type Tagged is Data:
  Tagged{h: N.U64, w: List<&2, U32>}

def hash(+i: Nat) -> N.U64:
  D.mix(N.U64.add(N.U64{69, 1347371848}, N.U64.of(U32.from_nat(i))))

def Tagged.le(a: Tagged, b: Tagged) -> Bool:
  match a b:
    case Tagged{N.U64{+ah, +al}, x} Tagged{N.U64{+bh, +bl}, y}:
      Bool.or(U32.is_lt(ah, bh), Bool.and(U32.is_eq(ah, bh), U32.is_le(al, bl)))

def tag(ws: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, Tagged>:
  match ws:
    case Nil{}:
      Nil{}
    case w <> t:
      Tagged{hash(i), w} <> tag(t, 1n+i)

def untag(ts: List<&2, Tagged>) -> List<&2, List<&2, U32>>:
  match ts:
    case Nil{}:
      Nil{}
    case Tagged{h, w} <> t:
      w <> untag(t)

def epoch.of(+ctx: Nat, sp: D.Split) -> List<&2, List<&2, U32>>:
  match sp:
    case D.Split{t, v}:
      untag(List.sort(~Tagged, ~Tagged.le, tag(D.all.windows(ctx, t), 0n)))

# the training windows of a shard's documents in epoch order
def epoch(+ctx: Nat, +offset: Nat, docs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  epoch.of(ctx, D.split.go(docs, offset))

def valid.of(+ctx: Nat, +k: Nat, sp: D.Split) -> List<&2, List<&2, U32>>:
  match sp:
    case D.Split{t, v}:
      List.take(&2, List<&2, U32>, D.all.windows(ctx, v), k)

# the first k validation windows of a shard's documents
def valid(+ctx: Nat, +offset: Nat, +k: Nat, docs: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  valid.of(ctx, k, D.split.go(docs, offset))
