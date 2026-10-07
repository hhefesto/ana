import Base
import ./Spec.bend as A

# An episode as the loop writes it (docs/AGENT.md), the unit of turn-based
# training: ana's term, the tool's turn, ana's next term ... up to K calls;
# solved when the tool's last turn passes.
#
# Meaning.  An episode is its segments in order, each the text one author
# wrote: the prompt (who 0), ana (1), a tool (2: its name, its exit status,
# 0 passed, 1 failed).  The episode's text is the segments' texts in order
# (`ep.text`); its roles and weights are Agent/Spec.bend's reading of that
# text, the trainer's (`ep.turns`), so a segment's author never sets a weight
# on its own: the reader is the one source of them.  The loop
# (Agent/Loop.bend) keeps its segments newest first and folds them into
# text with `ep.text.newest`; `ep.law.newest` says that fold is `ep.text` of
# the segments in order, so the log it writes (`ep.put`, oldest first)
# renders the text ana read.  `ep.law.snoc`: appending a segment appends its
# text (the log is append-only).
#
# The grammar of a training episode (`ep.why`, "" when it holds): the text
# opens with `## User`; after the prompt's turns the Term or Type turns and
# the tool's turns alternate as (try call echo)* act call echo, every try
# and the act under the prompt's open heading (no drift to another label);
# every echo but the last fails, the last passes; at most K calls; and the
# authors agree with the roles: a byte reads as echo exactly when a tool
# wrote it.
#
# The log (`*.eplog`): records, each `EP1 LEN\n` then LEN bytes: a line
# `MLEN ELEN NSEG\n`, MLEN bytes of metadata (KEY=VALUE lines), ELEN bytes
# of how it ended (solved, eos, budget, calls, tool-error), then each
# segment: a line `WHO CODE TLEN XLEN\n`, TLEN bytes of the tool's name,
# XLEN bytes of text.  Lengths frame everything, so tool output and ana's
# bytes may hold any byte (NUL, RS, invalid UTF-8): `ep.get ∘ ep.put = id`
# (bend/tests/episode.bend).

type EpSeg is Data:
  EpSeg{who: Nat, tool: List<&2, U32>, code: U32, text: List<&2, U32>}

type EpRec is Data:
  EpRec{meta: List<&2, U32>, end: List<&2, U32>, segs: List<&2, EpSeg>}

def ep.seg.who(+s: EpSeg) -> Nat:
  match s:
    case EpSeg{w, t, c, x}:
      w

def ep.seg.tool(+s: EpSeg) -> List<&2, U32>:
  match s:
    case EpSeg{w, t, c, x}:
      t

def ep.seg.code(+s: EpSeg) -> U32:
  match s:
    case EpSeg{w, t, c, x}:
      c

def ep.seg.text(+s: EpSeg) -> List<&2, U32>:
  match s:
    case EpSeg{w, t, c, x}:
      x

def EpRec.meta(+r: EpRec) -> List<&2, U32>:
  match r:
    case EpRec{m, e, s}:
      m

def EpRec.end(+r: EpRec) -> List<&2, U32>:
  match r:
    case EpRec{m, e, s}:
      e

def EpRec.segs(+r: EpRec) -> List<&2, EpSeg>:
  match r:
    case EpRec{m, e, s}:
      s

# The text ---------------------------------------------------------------------

# the episode's text: its segments' texts, oldest first
def ep.text(ss: List<&2, EpSeg>) -> List<&2, U32>:
  match ss:
    case Nil{}:
      Nil{}
    case s <> t:
      List.append(&2, U32, ep.seg.text(s), ep.text(t))

# the loop's fold: segments newest first, each text put before acc
def ep.text.newest(ss: List<&2, EpSeg>, acc: List<&2, U32>) -> List<&2, U32>:
  match ss:
    case Nil{}:
      acc
    case s <> t:
      ep.text.newest(t, List.append(&2, U32, ep.seg.text(s), acc))

# ss reversed onto acc
def ep.rev(ss: List<&2, EpSeg>, acc: List<&2, EpSeg>) -> List<&2, EpSeg>:
  match ss:
    case Nil{}:
      acc
    case s <> t:
      ep.rev(t, s <> acc)

# the loop's segments in order
def ep.order(ss: List<&2, EpSeg>) -> List<&2, EpSeg>:
  ep.rev(ss, Nil{})

law ep.law.newest:
  for ss: List<&2, EpSeg>
  for -acc: List<&2, EpSeg>
  {ep.text.newest(ss, ep.text(acc)) == ep.text(ep.rev(ss, acc)) : List<&2, U32>}

def ep.law.newest(ss, acc):
  match ss:
    case Nil{}:
      {==}
    case +s <> t:
      ep.law.newest(t, s <> acc)

law ep.append_nil:
  for xs: List<&2, U32>
  {List.append(&2, U32, xs, Nil{}) == xs : List<&2, U32>}

def ep.append_nil(xs):
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %ep.append_nil(t) : {h <> List.append(&2, U32, t, Nil{}) == h <> _ : List<&2, U32>}
      {==}

law ep.append_assoc:
  for xs: List<&2, U32>
  for -ys: List<&2, U32>
  for -zs: List<&2, U32>
  {List.append(&2, U32, List.append(&2, U32, xs, ys), zs) == List.append(&2, U32, xs, List.append(&2, U32, ys, zs)) : List<&2, U32>}

def ep.append_assoc(xs, ys, zs):
  match xs:
    case Nil{}:
      {==}
    case +h <> t:
      %ep.append_assoc(t, ys, zs) : {h <> List.append(&2, U32, List.append(&2, U32, t, ys), zs) == h <> _ : List<&2, U32>}
      {==}

law ep.law.snoc:
  for ss: List<&2, EpSeg>
  for s: EpSeg
  {List.append(&2, U32, ep.text(ss), ep.seg.text(s)) == ep.text(List.append(&2, EpSeg, ss, [s])) : List<&2, U32>}

def ep.law.snoc(ss, s):
  match ss:
    case Nil{}:
      %ep.append_nil(ep.seg.text(s)) : {_ == List.append(&2, U32, ep.seg.text(s), Nil{}) : List<&2, U32>}
      {==}
    case +h <> t:
      %ep.law.snoc(t, s) : {List.append(&2, U32, List.append(&2, U32, ep.seg.text(h), ep.text(t)), ep.seg.text(s)) == List.append(&2, U32, ep.seg.text(h), _) : List<&2, U32>}
      ep.append_assoc(ep.seg.text(h), ep.text(t), ep.seg.text(s))

# Reading -----------------------------------------------------------------------

def ep.turns(ss: List<&2, EpSeg>) -> List<&2, A.Turn>:
  A.ag.read.bytes(ep.text(ss))

def ep.weights(ss: List<&2, EpSeg>) -> List<&2, F32>:
  A.ag.weights(ep.turns(ss))

# the tool calls made: the tool segments
def ep.calls(ss: List<&2, EpSeg>) -> Nat:
  match ss:
    case Nil{}:
      0n
    case s <> t:
      Nat.add(Bool.pick(Nat, Nat.is_eq(ep.seg.who(s), 2n), 1n, 0n), ep.calls(t))

def ep.last.tool(ss: List<&2, EpSeg>, +best: U32) -> U32:
  match ss:
    case Nil{}:
      best
    case +s <> t:
      ep.last.tool(t, Bool.pick(U32, Nat.is_eq(ep.seg.who(s), 2n), ep.seg.code(s), best))

# solved: the last tool turn passed
def ep.solved(ss: List<&2, EpSeg>) -> Bool:
  U32.is_eq(ep.last.tool(ss, 9), 0)

# The grammar ---------------------------------------------------------------------

def ep.codes(e: List<&2, A.Turn>) -> List<&2, Nat>:
  match e:
    case Nil{}:
      Nil{}
    case A.Turn{r, x} <> t:
      A.ag.role.code(r) <> ep.codes(t)

# the prompt's bytes: the leading segments the prompt wrote
def ep.prompt.len(ss: List<&2, EpSeg>) -> Nat:
  match ss:
    case Nil{}:
      0n
    case +s <> t:
      Bool.pick(Nat, Nat.is_eq(ep.seg.who(s), 0n), Nat.add(List.length(&2, U32, ep.seg.text(s)), ep.prompt.len(t)), 0n)

# the episode proper: the turns from the one holding byte n (ana's first)
# on; the prompt's open heading is that turn's heading
def ep.proper(e: List<&2, A.Turn>, +n: Nat) -> List<&2, A.Turn>:
  match e:
    case Nil{}:
      Nil{}
    case +x <> +t:
      +l = List.length(&2, U32, A.ag.turn.text(x))
      Bool.pick(List<&2, A.Turn>, Nat.is_lt(n, l), x <> t, ep.proper(t, Nat.sub(n, l)))

# (try call echo)* act call echo, each try and the act under heading h; the
# echoes' verdicts: every one before the last fails, the last passes
def ep.alt(e: List<&2, A.Turn>, +h: List<&2, U32>) -> String:
  match e:
    case A.Turn{+r, +x} <> A.Turn{+c, y} <> A.Turn{+o, +z} <> +t:
      +rc = A.ag.role.code(r)
      +shape = Bool.and(Nat.is_eq(A.ag.role.code(c), 4n), Nat.is_eq(A.ag.role.code(o), 5n))
      +same = A.ag.eq(A.ag.line1(10, x), h)
      +last = List.is_empty(&2, A.Turn, t)
      Bool.pick(String, Bool.not(shape), "shape",
        Bool.pick(String, Bool.or(Bool.not(same), Nat.is_eq(rc, 1n)), "drift",
          Bool.pick(String, last,
            Bool.pick(String, Bool.and(Nat.is_eq(rc, 3n), A.ag.verdict(z)), "", "unsolved"),
            Bool.pick(String, Bool.and(Nat.is_eq(rc, 6n), Bool.not(A.ag.verdict(z))), ep.alt(t, h), "shape"))))
    case _:
      "shape"

def ep.open(e: List<&2, A.Turn>) -> List<&2, U32>:
  match e:
    case A.Turn{r, x} <> t:
      A.ag.line1(10, x)
    case Nil{}:
      Nil{}

# each byte's author: 1 when a tool wrote it, else 0
def ep.tooled(ss: List<&2, EpSeg>) -> List<&2, Nat>:
  match ss:
    case Nil{}:
      Nil{}
    case +s <> t:
      List.append(&2, Nat, List.replicate(Nat, List.length(&2, U32, ep.seg.text(s)), Bool.pick(Nat, Nat.is_eq(ep.seg.who(s), 2n), 1n, 0n)), ep.tooled(t))

def ep.echoed(rs: List<&2, A.Role>) -> List<&2, Nat>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      Bool.pick(Nat, Nat.is_eq(A.ag.role.code(r), 5n), 1n, 0n) <> ep.echoed(t)

def ep.nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case a <> s c <> t:
      Bool.and(Nat.is_eq(a, c), ep.nats.eq(s, t))
    case _ _:
      False{}

# why the episode is not a training episode under at most k calls ("" it
# is): no User first; unsolved (the tool's last turn did not pass); more
# than k calls; an author the roles disagree with, past the prompt (a
# repair prompt's given echo is the prompt's own text); then the grammar
def ep.why(+ss: List<&2, EpSeg>, +k: Nat) -> String:
  +x = ep.text(ss)
  +e = A.ag.read.bytes(x)
  +n = ep.prompt.len(ss)
  +p = ep.proper(e, n)
  +g = ep.alt(p, ep.open(p))
  +authors = ep.nats.eq(List.drop(&2, Nat, ep.tooled(ss), n), List.drop(&2, Nat, ep.echoed(A.ag.roles(e)), n))
  Bool.pick(String, Bool.not(A.ag.prefix(x, A.ag.ascii("## User\n"))), "no-user",
    Bool.pick(String, Bool.not(ep.solved(ss)), "unsolved",
      Bool.pick(String, Nat.is_lt(k, ep.calls(ss)), "calls",
        Bool.pick(String, Bool.not(authors), "authors", g))))

def ep.ok(+ss: List<&2, EpSeg>, +k: Nat) -> Bool:
  String.is_empty(ep.why(ss, k))

# the tries: Term or Type turns a tool rejected
def ep.tries(ss: List<&2, EpSeg>) -> Nat:
  A.ag.count(ep.turns(ss), 6n)

# The log -----------------------------------------------------------------------

def ep.ascii(s: String) -> List<&2, U32>:
  A.ag.ascii(s)

def ep.num(+n: Nat) -> List<&2, U32>:
  A.ag.ascii(Nat.show(n))

def ep.len(+xs: List<&2, U32>) -> Nat:
  List.length(&2, U32, xs)

def ep.put.segs(ss: List<&2, EpSeg>) -> List<&2, U32>:
  match ss:
    case Nil{}:
      Nil{}
    case EpSeg{+w, +t, +c, +x} <> r:
      List.concat(&2, U32, [ep.num(w), [32], ep.num(U32.to_nat(c)), [32], ep.num(ep.len(t)), [32], ep.num(ep.len(x)), [10], t, x, ep.put.segs(r)])

# a record's bytes
def ep.put(+meta: List<&2, U32>, +end: List<&2, U32>, +ss: List<&2, EpSeg>) -> List<&2, U32>:
  +body = List.concat(&2, U32, [ep.num(ep.len(meta)), [32], ep.num(ep.len(end)), [32], ep.num(List.length(&2, EpSeg, ss)), [10], meta, end, ep.put.segs(ss)])
  List.concat(&2, U32, [ep.ascii("EP1 "), ep.num(ep.len(body)), [10], body])

# Reading the log.  Every reader is defined before its callers and recurses
# only into itself; a branch that recurses takes its condition as a
# parameter (computed for the next byte), so the recursion is in a match
# arm, never inside a strict Bool.pick.

def ep.is.digit(+h: U32) -> Bool:
  Bool.and(U32.is_le(48, h), U32.is_le(h, 57))

def ep.head.digit(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      ep.is.digit(h)
    case Nil{}:
      True{}

def ep.head.nl(+xs: List<&2, U32>) -> Bool:
  match xs:
    case h <> t:
      U32.is_eq(h, 10)
    case Nil{}:
      False{}

# a decimal from its digits (None: a byte that is not a digit, or none);
# ok: the next byte is a digit (or the end)
def ep.nat.go(xs: List<&2, U32>, ok: Bool, +acc: Nat, +any: Bool) -> Maybe<&2, Nat>:
  match xs ok:
    case Nil{} _:
      Bool.pick(Maybe<&2, Nat>, any, Some{acc}, None{})
    case +h <> +t True{}:
      ep.nat.go(t, ep.head.digit(t), Nat.add(Nat.mul(acc, 10n), U32.to_nat(U32.sub(h, 48))), True{})
    case h <> t False{}:
      None{}

def ep.nat(+xs: List<&2, U32>) -> Maybe<&2, Nat>:
  ep.nat.go(xs, ep.head.digit(xs), 0n, False{})

# a cut: the bytes before a point and the bytes after it; none when the
# input ends first
type EpCut is Data:
  EpCut{take: List<&2, U32>, rest: List<&2, U32>}
  EpShort{}

def EpCut.rest(+c: EpCut) -> List<&2, U32>:
  match c:
    case EpCut{a, r}:
      r
    case EpShort{}:
      Nil{}

# the line before the first newline and what follows it; at: the next byte
# is the newline
def ep.line.go(xs: List<&2, U32>, at: Bool, +acc: List<&2, U32>) -> EpCut:
  match xs at:
    case Nil{} _:
      EpShort{}
    case h <> t True{}:
      EpCut{List.reverse(&2, U32, acc), t}
    case +h <> +t False{}:
      ep.line.go(t, ep.head.nl(t), h <> acc)

def ep.line(+xs: List<&2, U32>) -> EpCut:
  ep.line.go(xs, ep.head.nl(xs), Nil{})

# n bytes and the rest
def ep.cut.go(n: Nat, xs: List<&2, U32>, +acc: List<&2, U32>) -> EpCut:
  match n xs:
    case 0n _:
      EpCut{List.reverse(&2, U32, acc), xs}
    case 1n+p +h <> t:
      ep.cut.go(p, t, h <> acc)
    case _ Nil{}:
      EpShort{}

def ep.cut(+xs: List<&2, U32>, +n: Nat) -> EpCut:
  ep.cut.go(n, xs, Nil{})

# a header line's space-separated numbers (empty: one is not a number)
def ep.nums.go(xs: List<&2, U32>, +cur: List<&2, U32>) -> List<&2, Maybe<&2, Nat>>:
  match xs:
    case Nil{}:
      [ep.nat(List.reverse(&2, U32, cur))]
    case +h <> +t:
      Bool.pick(List<&2, Maybe<&2, Nat>>, U32.is_eq(h, 32), ep.nat(List.reverse(&2, U32, cur)) <> ep.nums.go(t, Nil{}), ep.nums.go(t, h <> cur))

def ep.all(ms: List<&2, Maybe<&2, Nat>>) -> Maybe<&2, List<&2, Nat>>:
  match ms:
    case Nil{}:
      Some{Nil{}}
    case Some{+x} <> t:
      Maybe.map(&2, List<&2, Nat>, List<&2, Nat>, ys => x <> ys, ep.all(t))
    case None{} <> t:
      None{}

def ep.or.none(m: Maybe<&2, List<&2, Nat>>) -> List<&2, Nat>:
  match m:
    case Some{+ns}:
      ns
    case None{}:
      Nil{}

def ep.nums(+l: List<&2, U32>) -> List<&2, Nat>:
  ep.or.none(ep.all(ep.nums.go(l, Nil{})))

def ep.at(ns: List<&2, Nat>, +i: Nat) -> Nat:
  match ns i:
    case Nil{} _:
      0n
    case +x <> t 0n:
      x
    case +x <> t 1n+p:
      ep.at(t, p)

def ep.nums.of(+c: EpCut) -> List<&2, Nat>:
  match c:
    case EpCut{+l, r}:
      ep.nums(l)
    case EpShort{}:
      Nil{}

# One segment: a line `WHO CODE TLEN XLEN`, the tool's name, the text.
type EpSg is Data:
  EpSg{seg: EpSeg, rest: List<&2, U32>}
  EpSgBad{}

def EpSg.rest(+g: EpSg) -> List<&2, U32>:
  match g:
    case EpSg{s, r}:
      r
    case EpSgBad{}:
      Nil{}

def ep.sg.text(+w: Nat, +c: Nat, +t: List<&2, U32>, x: EpCut) -> EpSg:
  match x:
    case EpCut{+tx, +r}:
      EpSg{EpSeg{w, t, U32.from_nat(c), tx}, r}
    case EpShort{}:
      EpSgBad{}

def ep.sg.tool(+w: Nat, +c: Nat, +xl: Nat, t: EpCut) -> EpSg:
  match t:
    case EpCut{+tn, +r}:
      ep.sg.text(w, c, tn, ep.cut(r, xl))
    case EpShort{}:
      EpSgBad{}

def ep.sg.of(+ns: List<&2, Nat>, +r: List<&2, U32>, ok: Bool) -> EpSg:
  match ok:
    case True{}:
      ep.sg.tool(ep.at(ns, 0n), ep.at(ns, 1n), ep.at(ns, 3n), ep.cut(r, ep.at(ns, 2n)))
    case False{}:
      EpSgBad{}

def ep.sg(+xs: List<&2, U32>) -> EpSg:
  +ln = ep.line(xs)
  +ns = ep.nums.of(ln)
  ep.sg.of(ns, EpCut.rest(ln), Nat.is_eq(List.length(&2, Nat, ns), 4n))

# n segments, and the bytes after them
type EpGot is Data:
  EpGot{segs: List<&2, EpSeg>, rest: List<&2, U32>}
  EpBad{}

def ep.got.cons(g: EpSg, r: EpGot) -> EpGot:
  match g r:
    case EpSg{+s, x} EpGot{ss, rest}:
      EpGot{s <> ss, rest}
    case _ _:
      EpBad{}

def ep.get.segs(n: Nat, +xs: List<&2, U32>) -> EpGot:
  match n:
    case 0n:
      EpGot{Nil{}, xs}
    case 1n+p:
      +g = ep.sg(xs)
      ep.got.cons(g, ep.get.segs(p, EpSg.rest(g)))

# One record's body: a line `MLEN ELEN NSEG`, the metadata, how it ended,
# the segments, and nothing after them.
def ep.rec.fin(+m: List<&2, U32>, +e: List<&2, U32>, g: EpGot) -> Maybe<&2, EpRec>:
  match g:
    case EpGot{ss, r}:
      Bool.pick(Maybe<&2, EpRec>, List.is_empty(&2, U32, r), Some{EpRec{m, e, ss}}, None{})
    case EpBad{}:
      None{}

def ep.rec.end(+m: List<&2, U32>, +ns: Nat, e: EpCut) -> Maybe<&2, EpRec>:
  match e:
    case EpCut{+ex, +r}:
      ep.rec.fin(m, ex, ep.get.segs(ns, r))
    case EpShort{}:
      None{}

def ep.rec.meta(+el: Nat, +ns: Nat, m: EpCut) -> Maybe<&2, EpRec>:
  match m:
    case EpCut{+mx, +r}:
      ep.rec.end(mx, ns, ep.cut(r, el))
    case EpShort{}:
      None{}

def ep.rec.of(+ns: List<&2, Nat>, +r: List<&2, U32>, ok: Bool) -> Maybe<&2, EpRec>:
  match ok:
    case True{}:
      ep.rec.meta(ep.at(ns, 1n), ep.at(ns, 2n), ep.cut(r, ep.at(ns, 0n)))
    case False{}:
      None{}

def ep.rec(+body: List<&2, U32>) -> Maybe<&2, EpRec>:
  +ln = ep.line(body)
  +ns = ep.nums.of(ln)
  ep.rec.of(ns, EpCut.rest(ln), Nat.is_eq(List.length(&2, Nat, ns), 3n))

# One framed record, `EP1 LEN\n` and LEN bytes, and the bytes after it.
type EpOne is Data:
  EpOne{rec: EpRec, rest: List<&2, U32>}
  EpNone{}

def EpOne.rest(+o: EpOne) -> List<&2, U32>:
  match o:
    case EpOne{r, x}:
      x
    case EpNone{}:
      Nil{}

def ep.one.body(m: Maybe<&2, EpRec>, +rest: List<&2, U32>) -> EpOne:
  match m:
    case Some{+r}:
      EpOne{r, rest}
    case None{}:
      EpNone{}

def ep.one.frame(c: EpCut) -> EpOne:
  match c:
    case EpCut{+body, +rest}:
      ep.one.body(ep.rec(body), rest)
    case EpShort{}:
      EpNone{}

def ep.one.len(m: Maybe<&2, Nat>, +r: List<&2, U32>) -> EpOne:
  match m:
    case Some{+n}:
      ep.one.frame(ep.cut(r, n))
    case None{}:
      EpNone{}

def ep.one.head(c: EpCut) -> EpOne:
  match c:
    case EpCut{+l, +r}:
      Bool.pick(EpOne, A.ag.prefix(l, ep.ascii("EP1 ")), ep.one.len(ep.nat(List.drop(&2, U32, l, 4n)), r), EpNone{})
    case EpShort{}:
      EpNone{}

def ep.one(+xs: List<&2, U32>) -> EpOne:
  ep.one.head(ep.line(xs))

def ep.recs.cons(o: EpOne, m: Maybe<&2, List<&2, EpRec>>) -> Maybe<&2, List<&2, EpRec>>:
  match o m:
    case EpOne{+r, x} Some{rs}:
      Some{r <> rs}
    case _ _:
      None{}

# the records of a log, in order (None: it is not a log, or a record is cut
# short); done: no bytes are left
def ep.get.go(fuel: Nat, done: Bool, +xs: List<&2, U32>) -> Maybe<&2, List<&2, EpRec>>:
  match fuel done:
    case _ True{}:
      Some{Nil{}}
    case 0n False{}:
      None{}
    case 1n+p False{}:
      +o = ep.one(xs)
      +rest = EpOne.rest(o)
      ep.recs.cons(o, ep.get.go(p, List.is_empty(&2, U32, rest), rest))

def ep.get(+xs: List<&2, U32>) -> Maybe<&2, List<&2, EpRec>>:
  ep.get.go(Nat.add(List.length(&2, U32, xs), 1n), List.is_empty(&2, U32, xs), xs)

# Files ---------------------------------------------------------------------------

def ep.file.fin(r: File & Result<&1, &1, U32 & String, Unit>) -> IO(Unit):
  (f, e) = r
  do IO<Unit>:
    u : Unit <- IO.pass(Unit, e)
    File.close(f)

# append bytes to a file (created when missing)
def ep.file.add(path: String, xs: List<&2, U32>) -> IO(Unit):
  do IO<Unit>:
    f : File <- IO.try(File, File.open(path, "a"))
    r : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(f, xs)
    ep.file.fin(r)
