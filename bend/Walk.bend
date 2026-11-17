import Base
import ./Sys.bend as S
import ./Bytes.bend as B
import ./Tokenizer.bend as Tk
import ./Nul.bend as Ns
import ./Units.bend as U
import ./Transcript.bend as T
import ./Check/Bend.bend as Bd
import ./Check/Lib.bend as Cl
import ./Sha256.bend as H
import ./CorpusV2/Eval.bend as Ev
import ./CorpusV2/Mutate.bend as Mu
import ./CorpusV2/Exlaw.bend as Ex
import ./Agent/Spec.bend as A

# walk: sessions that fill several holes of one file in turn, the file carried
# along, every check a new run of the checker on the file as it stands then
# (R9, 2026-11-17).  The user, 11-17: "Longer tasks within 2,048 tokens. For
# example, one session could fill several holes in the same file in turn, with
# the file carried along. That needs new data collected on olimpo."
#
#   bend-walk TOKENIZER UNITS OUT [WINDOW]
#
# UNITS is a checked Bend unit file (NUL pairs: an id, then bend-check's record,
# fields joined by 0x1E; exlaw's outputs, run/v9/f4/law/*.nul, are such).  Its
# units come in file order, a file's in a row, each one's head (field 5) the
# file before it, so a unit's head opens with the one before's head, pre and
# body: a run of such units is a run of one file's declarations, other
# definitions between them as the file has them.
#
# (Agent/Spec.bend's reader reads each kept session's tries as J and its one act,
# the reply, or the walk is dropped: reader-differs.)
#
# A walk is K units of a run (2 to KMAX, default 5, the first a hash of the
# first unit's id picks; fewer when the session would not fit the window),
# the file cut after the last one (the tail left out, as bend-check's
# variants: a def may only call the defs above it), in one of two shapes:
#
#   walk-fill-K-J   every one of the K bodies is `?goal`: check (the first
#                   hole's goal), then for each unit in turn a look at it and
#                   the names its Context lists, and a def of its body, whose
#                   echo is the check of the file then (the next hole's goal;
#                   after the last, the pass); the reply
#   walk-add-K-J    the first K - 1 bodies are holes and the last unit is not
#                   in the file yet: the fills as above (the last one's check
#                   passes), a look at the names the last one uses, its add
#                   (the direct ask's), the pass; the reply
#
# J is 1 when one of the writes is first a wrong one (the unit's first kept
# mutant, its check a new run on the file as it stands then), followed by the
# right one (35 in 100 walks, the step a hash), else 0.  The reader
# (Agent/Spec.bend) takes the wrong write as a try (weight 0): a later write
# names the same definition.  Every other write is an act: each names another.
#
# Every check is a run of BEND (`bend Unit.bend --check-only`, under TIMEOUT
# seconds, 60) on the whole text, as Unit.bend beside the unit's file in a copy
# of its repository's .bend files (Check/Bend.bend's layout), the source tree
# the first of BEND_SRC's roots (`:` between) whose copy of the file holds the
# first unit's body (Exlaw.bend's rule).  A walk is kept only when the checks
# say what the session says of them: before each fill the first error is that
# unit's hole (`Location: NAME`, `?goal`), a wrong write fails at its own
# definition, and the last check passes.  Nothing else is generated: the
# looks and the writes' echoes are text of the file and the checker's output.
#
# OUT gets the kept sessions (id: the first unit's, then /mugen-SHAPE), in
# order; OUT.stats the counts; OUT.log a line a walk.

# Units --------------------------------------------------------------------------------------

type Wu is Data:
  Wu{id: List<&2, U32>, fs: List<&2, List<&2, U32>>}

def Wu.id(+w: Wu) -> List<&2, U32>:
  match w:
    case Wu{i, f}:
      i

def Wu.fs(+w: Wu) -> List<&2, List<&2, U32>>:
  match w:
    case Wu{i, f}:
      f

def wu.f(+w: Wu, +k: Nat) -> List<&2, U32>:
  T.field(Wu.fs(w), k)

def wu.name(+w: Wu) -> List<&2, U32>:
  wu.f(w, 2n)

# the file through the declaration: head, pre, body
def wu.upto(+w: Wu) -> List<&2, U32>:
  T.cat([wu.f(w, 5n), wu.f(w, 6n), wu.f(w, 7n)])

# the file's id: the unit's before `#`
def wu.file(+w: Wu) -> List<&2, U32>:
  T.mg.upto(Wu.id(w), 35)

def wu.has.mut(+w: Wu) -> Bool:
  Bool.not(T.empty(T.mutant(Wu.fs(w), 0n)))

# a Bend unit with a hole and the hole's check
def wu.ok(+w: Wu) -> Bool:
  Bool.and(U.eq(wu.f(w, 0n), U.b("bend")), Bool.and(Bool.not(T.empty(wu.f(w, 10n))), Bool.not(T.empty(wu.f(w, 13n)))))

def wu.keep(ok: Bool, +w: Wu, rest: List<&2, Wu>) -> List<&2, Wu>:
  match ok:
    case True{}:
      w <> rest
    case False{}:
      rest

def wu.of(kvs: List<&2, Ev.EvKv>) -> List<&2, Wu>:
  match kvs:
    case Nil{}:
      Nil{}
    case Ev.EvKv{+k, +v} <> more:
      +w = {Wu{k, Ev.ev.split(v, 30)} : Wu}
      wu.keep(wu.ok(w), w, wu.of(more))

# Runs ---------------------------------------------------------------------------------------

# b follows a in one file: the same file, b's head opening with a's declaration
def wk.next(+a: Wu, +b: Wu) -> Bool:
  Bool.and(U.eq(wu.file(a), wu.file(b)), S.prefix(wu.f(b, 5n), wu.upto(a)))

# whether ws opens with a unit that follows prev
def wk.follows(+prev: Wu, +ws: List<&2, Wu>) -> Bool:
  match ws:
    case Nil{}:
      False{}
    case +w <> t:
      wk.next(prev, w)

# go: ws's first unit follows prev (the run goes on)
def wk.runs.go(ws: List<&2, Wu>, run: List<&2, Wu>, acc: List<&2, List<&2, Wu>>, go: Bool) -> List<&2, List<&2, Wu>>:
  match ws go:
    case Nil{} _:
      List.reverse(&2, List<&2, Wu>, List.reverse(&2, Wu, run) <> acc)
    case +w <> +t True{}:
      wk.runs.go(t, w <> run, acc, wk.follows(w, t))
    case +w <> +t False{}:
      wk.runs.go(t, [w], List.reverse(&2, Wu, run) <> acc, wk.follows(w, t))

def wk.long.on(keep: Bool, +r: List<&2, Wu>, rest: List<&2, List<&2, Wu>>) -> List<&2, List<&2, Wu>>:
  match keep:
    case True{}:
      r <> rest
    case False{}:
      rest

def wk.long(rs: List<&2, List<&2, Wu>>) -> List<&2, List<&2, Wu>>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> more:
      wk.long.on(Nat.is_lt(1n, List.length(&2, Wu, r)), r, wk.long(more))

# the runs of two units or more
def wk.runs(ws: List<&2, Wu>) -> List<&2, List<&2, Wu>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> +t:
      wk.long(wk.runs.go(t, [w], Nil{}, wk.follows(w, t)))

# The file's states ----------------------------------------------------------------------------

# a unit's body in a state: 0 its own, 1 the hole, 2 its first kept mutant
def wk.body(+w: Wu, +c: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(c, 0n), wu.f(w, 7n), Bool.pick(List<&2, U32>, Nat.is_eq(c, 1n), wu.f(w, 10n), T.mutant(Wu.fs(w), 0n)))

# the text between a's body and b's declaration
def wk.gap(+a: Wu, +b: Wu) -> List<&2, U32>:
  List.drop(&2, U32, wu.f(b, 5n), U.len(wu.upto(a)))

def wk.gap.next(+w: Wu, +t: List<&2, Wu>) -> List<&2, U32>:
  match t:
    case Nil{}:
      Nil{}
    case +n <> more:
      wk.gap(w, n)

# the units' declarations, each with its body as cs says (3: not in the file,
# the last unit only), and the text after it up to the next one
def wk.pieces(ws: List<&2, Wu>, cs: List<&2, Nat>) -> List<&2, U32>:
  match ws cs:
    case +w <> +t +c <> ct:
      +p = Bool.pick(List<&2, U32>, Nat.is_eq(c, 3n), Nil{}, T.cat([wu.f(w, 6n), wk.body(w, c), wk.gap.next(w, t)]))
      U.append(p, wk.pieces(t, ct))
    case _ _:
      Nil{}

def wk.text(+ws: List<&2, Wu>, +cs: List<&2, Nat>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      U.append(wu.f(w, 5n), wk.pieces(w <> t, cs))

def wk.reps(+k: Nat, +c: Nat) -> List<&2, Nat>:
  match k:
    case 0n:
      Nil{}
    case 1n+p:
      c <> wk.reps(p, c)

# a walk's plan: its units, its shape (0 fill, 1 add), its wrong write's step
# (1..K; 0 none)
type Wp is Data:
  Wp{ws: List<&2, Wu>, kind: Nat, j: Nat}

def Wp.ws(+p: Wp) -> List<&2, Wu>:
  match p:
    case Wp{w, k, j}:
      w

def Wp.kind(+p: Wp) -> Nat:
  match p:
    case Wp{w, k, j}:
      k

def Wp.j(+p: Wp) -> Nat:
  match p:
    case Wp{w, k, j}:
      j

def wp.k(+p: Wp) -> Nat:
  List.length(&2, Wu, Wp.ws(p))

# state i of a fill walk: the first i bodies their own, the rest holes; of an
# add walk (i < K): the first i their own, the others but the last holes, the
# last not there; i = K: every body its own
def wk.cs(+p: Wp, +i: Nat) -> List<&2, Nat>:
  +k = wp.k(p)
  Bool.pick(List<&2, Nat>, Bool.or(Nat.is_eq(Wp.kind(p), 0n), Nat.is_eq(i, k)),
    List.append(&2, Nat, wk.reps(i, 0n), wk.reps(Nat.sub(k, i), 1n)),
    List.concat(&2, Nat, [wk.reps(i, 0n), wk.reps(Nat.sub(Nat.sub(k, 1n), i), 1n), [3n]]))

def wk.append.nat(xs: List<&2, Nat>, ys: List<&2, Nat>) -> List<&2, Nat>:
  List.append(&2, Nat, xs, ys)

# the wrong write's state: before step j their own, j its mutant, after it as
# the state before j's write
def wk.cs.miss(+p: Wp) -> List<&2, Nat>:
  +k = wp.k(p)
  +j = Wp.j(p)
  +last = Nat.is_eq(j, k)
  +rest = Bool.pick(List<&2, Nat>, Nat.is_eq(Wp.kind(p), 0n), wk.reps(Nat.sub(k, j), 1n),
    Bool.pick(List<&2, Nat>, last, Nil{}, wk.append.nat(wk.reps(Nat.sub(Nat.sub(k, 1n), j), 1n), [3n])))
  List.concat(&2, Nat, [wk.reps(Nat.sub(j, 1n), 0n), [2n], rest])

def wk.states.go(n: Nat, +p: Wp, +i: Nat) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      Nil{}
    case 1n+m:
      wk.text(Wp.ws(p), wk.cs(p, i)) <> wk.states.go(m, p, 1n+i)

# the texts to check, in order: states 0..K, then the wrong write's (J = 1)
def wk.states.fa(+p: Wp) -> List<&2, List<&2, U32>>:
  +s = wk.states.go(1n+wp.k(p), p, 0n)
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(Wp.j(p), 0n), s, List.append(&2, List<&2, U32>, s, [wk.text(Wp.ws(p), wk.cs.miss(p))]))

# The session --------------------------------------------------------------------------------

def wk.at(+xs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  U.nth(xs, i)

def wk.names(ws: List<&2, Wu>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      wu.name(w) <> wk.names(t)

def wk.last.go(ws: List<&2, Wu>, +w: Wu) -> Wu:
  match ws:
    case Nil{}:
      w
    case +v <> t:
      wk.last.go(t, v)

def wk.last(+ws: List<&2, Wu>) -> Wu:
  match ws:
    case Nil{}:
      Wu{Nil{}, Nil{}}
    case +w <> t:
      wk.last.go(t, w)

def wk.nth(+ws: List<&2, Wu>, +i: Nat) -> Wu:
  match ws:
    case Nil{}:
      Wu{Nil{}, Nil{}}
    case +w <> t:
      Bool.pick(Wu, Nat.is_eq(i, 0n), w, wk.nth(t, Nat.sub(i, 1n)))

def wk.first(+ws: List<&2, Wu>) -> Wu:
  match ws:
    case Nil{}:
      Wu{Nil{}, Nil{}}
    case +w <> t:
      w

def wk.holes(+n: Nat) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(n, 1n), U.b("the hole"), U.b("the holes"))

# the ask: the fills, and the add with its doc and signature
def wk.ask(+p: Wp, +path: List<&2, U32>) -> List<&2, U32>:
  +ws = Wp.ws(p)
  +k = wp.k(p)
  +fills = Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(Wp.kind(p), 0n), wk.names(ws), List.take(&2, List<&2, U32>, wk.names(ws), Nat.sub(k, 1n)))
  +n = List.length(&2, List<&2, U32>, fills)
  +fill = T.cat([U.b("Fill "), wk.holes(n), U.b(" (`?goal`) in "), T.f3.ands(fills), U.b(" in "), path])
  +l = wk.last(ws)
  +add = T.cat([fill, U.b(", then add "), T.code(wu.name(l)), U.b(".")])
  Bool.pick(List<&2, U32>, Nat.is_eq(Wp.kind(p), 0n), U.append(fill, U.b(".")),
    T.cat([T.mg.doc(Wu.fs(l), add), U.b("\n\n"), T.mg.chomp(T.fence(U.b("bend"), T.tidy(wu.f(l, 4n))))]))

def wk.out(+w: Wu, +path: List<&2, U32>, +c: List<&2, U32>) -> List<&2, U32>:
  T.f2.out(Wu.fs(w), path, c)

# step i (1..K) of the fills: a look at unit i, [its wrong write], its write
def wk.fills(ws: List<&2, Wu>, +i: Nat, +p: Wp, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      +fs = Wu.fs(w)
      +miss = Bool.pick(List<&2, U32>, Nat.is_eq(Wp.j(p), i), T.f2.write("def", "ok", fs, path, T.mutant(fs, 0n), wk.out(w, path, wk.at(cks, 1n+wp.k(p)))), Nil{})
      +step = T.cat([T.f2.looks(fs, path, wu.f(w, 10n), base), miss, T.f2.write("def", "ok", fs, path, wu.f(w, 7n), wk.out(w, path, wk.at(cks, i)))])
      U.append(step, wk.fills(t, 1n+i, p, path, base, cks))

# the add (step K of an add walk): a look at the names it uses, [its wrong
# add, then the def], its write
def wk.add(+w: Wu, +k: Nat, +p: Wp, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +fs = Wu.fs(w)
  +miss = Nat.is_eq(Wp.j(p), k)
  +wrong = Bool.pick(List<&2, U32>, miss, T.f2.write("add", "added", fs, path, T.mutant(fs, 0n), wk.out(w, path, wk.at(cks, 1n+k))), Nil{})
  +right = T.f2.write(Bool.pick(String, miss, "def", "add"), Bool.pick(String, miss, "ok", "added"), fs, path, wu.f(w, 7n), wk.out(w, path, wk.at(cks, k)))
  T.cat([T.f2.looks.new(fs, path, base), wrong, right])

def wk.reply(+p: Wp, +path: List<&2, U32>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +ws = Wp.ws(p)
  +k = wp.k(p)
  +l = wk.last(ws)
  +v = T.f2.verdict(Wu.fs(l), wk.at(cks, k))
  +fills = Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(Wp.kind(p), 0n), wk.names(ws), List.take(&2, List<&2, U32>, wk.names(ws), Nat.sub(k, 1n)))
  +n = List.length(&2, List<&2, U32>, fills)
  +did = T.cat([U.b(" Filled "), wk.holes(n), U.b(" in "), T.f3.ands(fills)])
  T.mg.reply(Bool.pick(List<&2, U32>, Nat.is_eq(Wp.kind(p), 0n), T.cat([v, did, U.b(" ("), path, U.b(").")]),
    T.cat([v, did, U.b(" and added "), T.code(wu.name(l)), U.b(" ("), path, U.b(").")])))

# the session, cks the checks of wk.states's texts in order
def wk.session.fa(+p: Wp, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +ws = Wp.ws(p)
  +k = wp.k(p)
  +f = wk.first(ws)
  +head = T.cat([T.mg.user(wk.ask(p, path)), T.f2.check(path, T.f2.hole.out(Wu.fs(f), path, wk.at(cks, 0n)))])
  Bool.pick(List<&2, U32>, Nat.is_eq(Wp.kind(p), 0n), T.cat([head, wk.fills(ws, 1n, p, path, base, cks), wk.reply(p, path, cks)]),
    T.cat([head, wk.fills(List.take(&2, Wu, ws, Nat.sub(k, 1n)), 1n, p, path, base, cks), wk.add(wk.last(ws), k, p, path, base, cks), wk.reply(p, path, cks)]))

def wk.shape(+p: Wp) -> List<&2, U32>:
  T.cat([U.nth([U.b("walk-fill-"), U.b("walk-add-"), U.b("walk-direct-")], Wp.kind(p)), T.mg.n(wp.k(p)), U.b("-"), T.mg.n(Bool.pick(Nat, Nat.is_eq(Wp.j(p), 0n), 0n, 1n))])

# The checks' rule ---------------------------------------------------------------------------

def wk.status(+c: List<&2, U32>) -> List<&2, U32>:
  T.check.status(T.check.of(c))

def wk.said(+c: List<&2, U32>) -> List<&2, U32>:
  T.check.out(T.check.of(c))

def wk.passes(+c: List<&2, U32>) -> Bool:
  U.eq(wk.status(c), U.b("0"))

# the first error is at NAME
def wk.fails.at(+c: List<&2, U32>, +n: List<&2, U32>) -> Bool:
  Bool.and(U.eq(wk.status(c), U.b("1")), S.infix(wk.said(c), T.cat([U.b("Location: "), n, U.b("\n")])))

# ... and is its hole
def wk.hole.at(+c: List<&2, U32>, +n: List<&2, U32>) -> Bool:
  Bool.and(wk.fails.at(c, n), S.infix(wk.said(c), U.b("?goal")))

# a wrong write's check: it fails, and not at a hole (every unit before it is
# its own, so the first error is its: at its definition, or a parse error in
# it, whose Location names none)
def wk.wrong(+c: List<&2, U32>) -> Bool:
  Bool.and(U.eq(wk.status(c), U.b("1")), Bool.not(S.infix(wk.said(c), U.b("?goal"))))

# check i (i < the last fill's) is the hole of unit i + 1
def wk.holes.ok(ws: List<&2, Wu>, +i: Nat, +upto: Nat, +cks: List<&2, List<&2, U32>>) -> Bool:
  match ws:
    case Nil{}:
      True{}
    case +w <> t:
      Bool.pick(Bool, Nat.is_lt(i, upto), Bool.and(wk.hole.at(wk.at(cks, i), wu.name(w)), wk.holes.ok(t, 1n+i, upto, cks)), True{})

# what the session says of its checks holds: fill: checks 0..K-1 each the next
# unit's hole, K passes; add: checks 0..K-2 the next hole, K-1 and K pass; the
# wrong write's check fails at its own definition
def wk.valid.fa(+p: Wp, +cks: List<&2, List<&2, U32>>) -> Bool:
  +k = wp.k(p)
  +ws = Wp.ws(p)
  +j = Wp.j(p)
  +fills = Bool.pick(Nat, Nat.is_eq(Wp.kind(p), 0n), k, Nat.sub(k, 1n))
  +holes = wk.holes.ok(ws, 0n, fills, cks)
  +ends = Bool.and(wk.passes(wk.at(cks, k)), Bool.pick(Bool, Nat.is_eq(Wp.kind(p), 0n), True{}, wk.passes(wk.at(cks, Nat.sub(k, 1n)))))
  +miss = Bool.pick(Bool, Nat.is_eq(j, 0n), True{}, wk.wrong(wk.at(cks, 1n+k)))
  Bool.and(Bool.and(holes, ends), miss)

# The walks of a run ------------------------------------------------------------------------

# the recorded checks a walk's checks are likely to be like, for its size: the
# next unit's hole check, the original's for a pass, the mutant's
def wk.guess.go(ws: List<&2, Wu>, +i: Nat, +upto: Nat) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      Bool.pick(List<&2, U32>, Nat.is_lt(i, upto), wu.f(w, 13n), wu.f(w, 11n)) <> wk.guess.go(t, 1n+i, upto)

def wk.guess.fa(+p: Wp) -> List<&2, List<&2, U32>>:
  +ws = Wp.ws(p)
  +k = wp.k(p)
  +fills = Bool.pick(Nat, Nat.is_eq(Wp.kind(p), 0n), k, Nat.sub(k, 1n))
  +l = wk.last(ws)
  +j = Wp.j(p)
  +mc = Bool.pick(List<&2, U32>, Nat.is_eq(j, 0n), Nil{}, T.mutant.check(Wu.fs(wk.nth(ws, Nat.sub(j, 1n))), 0n))
  List.concat(&2, List<&2, U32>, [wk.guess.go(ws, 0n, fills), [wu.f(l, 11n)], [mc]])

# The direct walk ----------------------------------------------------------------------------
#
#   walk-direct-K-J  none of the K units is in the file (the text between them
#                    is): read its last lines, then for each in turn a look at
#                    the names it uses and its add (the direct ask's), each
#                    add's check a pass; the reply
#
# mugen's add puts a definition after the file's last line (a newline first
# when the file lacks one: AgentMugen's am.f2.add), so the units come back at
# the end, in order, the text between them before them all: the checks say
# whether that file holds (a definition there may not use one of the units).
# A look's and a write's line numbers are the file's as it stands then (the
# unit's record with its head the file before the add).

# A unit's comment (the `#` lines right above its declaration) goes with it:
# out of the text it stood under, into the add (she writes the doc as a comment
# above her function: docs/form2/KINDS.md), so no comment is left over a
# definition it is not about.

def wk.doc.at(+rs: List<&2, List<&2, U32>>) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case l <> t:
      S.head.is(l, 35)

# the lines of a text, reversed, split: the `#` lines at its end (in order), the rest
def wk.doc.go(rs: List<&2, List<&2, U32>>, doc: List<&2, List<&2, U32>>, at: Bool) -> List<&2, List<&2, U32>> & List<&2, List<&2, U32>>:
  match rs at:
    case +l <> +t True{}:
      wk.doc.go(t, l <> doc, wk.doc.at(t))
    case _ _:
      (List.reverse(&2, List<&2, U32>, rs), doc)

def wk.pair.a(p: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>) -> List<&2, U32>:
  match p:
    case (a, d):
      T.cat(a)

def wk.pair.b(p: List<&2, List<&2, U32>> & List<&2, List<&2, U32>>) -> List<&2, U32>:
  match p:
    case (a, d):
      T.cat(d)

# a text less the comment at its end
def wk.undoc(+x: List<&2, U32>) -> List<&2, U32>:
  +rs = List.reverse(&2, List<&2, U32>, U.lines(x))
  wk.pair.a(wk.doc.go(rs, Nil{}, wk.doc.at(rs)))

# the comment at a text's end
def wk.doc.of(+x: List<&2, U32>) -> List<&2, U32>:
  +rs = List.reverse(&2, List<&2, U32>, U.lines(x))
  wk.pair.b(wk.doc.go(rs, Nil{}, wk.doc.at(rs)))

# the text between the units, less each next one's comment
def wk.gaps(ws: List<&2, Wu>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> +t:
      U.append(wk.undoc(wk.gap.next(w, t)), wk.gaps(t))

# the file before the first add
def wk.base0(+ws: List<&2, Wu>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      T.mg.end.nl(U.append(wk.undoc(wu.f(w, 5n)), wk.gaps(w <> t)))

def wk.docs.next(+w: Wu, +t: List<&2, Wu>) -> List<&2, U32>:
  match t:
    case Nil{}:
      Nil{}
    case +n <> more:
      wk.doc.of(wk.gap(w, n))

# each unit's comment: the first's from its head, the others' from the text before them
def wk.docs.go(ws: List<&2, Wu>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> +t:
      wk.docs.next(w, t) <> wk.docs.go(t)

def wk.docs(+ws: List<&2, Wu>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      List.take(&2, List<&2, U32>, wk.doc.of(wu.f(w, 5n)) <> wk.docs.go(w <> t), List.length(&2, Wu, w <> t))

# a unit's record for a direct walk: its head the file before its add, its
# pre with its comment above
def wk.dfs(+w: Wu, +doc: List<&2, U32>, +before: List<&2, U32>) -> List<&2, List<&2, U32>>:
  +fs = Wu.fs(w)
  List.concat(&2, List<&2, U32>, [List.take(&2, List<&2, U32>, fs, 5n), [before, U.append(doc, wu.f(w, 6n))], List.drop(&2, List<&2, U32>, fs, 7n)])

# the declarations of units k.. up to unit i (1-based), each with its comment,
# unit m's with its mutant
def wk.decls(ws: List<&2, Wu>, ds: List<&2, List<&2, U32>>, +k: Nat, +i: Nat, +m: Nat) -> List<&2, U32>:
  match ws ds:
    case +w <> t +d <> dt:
      +x = T.mg.end.nl(T.cat([d, wu.f(w, 6n), wk.body(w, Bool.pick(Nat, Nat.is_eq(k, m), 2n, 0n))]))
      U.append(Bool.pick(List<&2, U32>, Nat.is_le(k, i), x, Nil{}), wk.decls(t, dt, 1n+k, i, m))
    case _ _:
      Nil{}

# the file after i adds (unit m's its mutant)
def wk.dtext(+ws: List<&2, Wu>, +i: Nat, +m: Nat) -> List<&2, U32>:
  U.append(wk.base0(ws), wk.decls(ws, wk.docs(ws), 1n, i, m))

def wk.dstates.go(n: Nat, +ws: List<&2, Wu>, +i: Nat) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      Nil{}
    case 1n+r:
      wk.dtext(ws, i, 0n) <> wk.dstates.go(r, ws, 1n+i)

def wk.dstates(+p: Wp) -> List<&2, List<&2, U32>>:
  +s = wk.dstates.go(1n+wp.k(p), Wp.ws(p), 0n)
  Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(Wp.j(p), 0n), s, List.append(&2, List<&2, U32>, s, [wk.dtext(Wp.ws(p), Wp.j(p), Wp.j(p))]))

# a record with its head (field 5) h
def wk.fs.head(+fs: List<&2, List<&2, U32>>, +h: List<&2, U32>) -> List<&2, List<&2, U32>>:
  List.concat(&2, List<&2, U32>, [List.take(&2, List<&2, U32>, fs, 5n), [h], List.drop(&2, List<&2, U32>, fs, 6n)])

def wk.nth.b(+xs: List<&2, List<&2, U32>>, +i: Nat) -> List<&2, U32>:
  U.nth(xs, i)

# each unit's doc and signature, as the direct ask gives one
def wk.sigs(ws: List<&2, Wu>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      +doc = T.tidy(wu.f(w, 3n))
      T.cat([U.b("\n\n"), Bool.pick(List<&2, U32>, T.empty(doc), Nil{}, U.append(doc, U.b("\n\n"))), T.mg.chomp(T.fence(U.b("bend"), T.tidy(wu.f(w, 4n)))), wk.sigs(t)])

def wk.dask(+p: Wp, +path: List<&2, U32>) -> List<&2, U32>:
  T.cat([U.b("Add "), T.f3.ands(wk.names(Wp.ws(p))), U.b(" to "), path, U.b(", in that order."), wk.sigs(Wp.ws(p))])

# step i (1..K): a look at the names unit i uses, [its wrong add, then the def], its add
def wk.dsteps(ws: List<&2, Wu>, +i: Nat, +p: Wp, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      +fs = wk.dfs(w, wk.nth.b(wk.docs(Wp.ws(p)), Nat.sub(i, 1n)), wk.dtext(Wp.ws(p), Nat.sub(i, 1n), 0n))
      +miss = Nat.is_eq(Wp.j(p), i)
      +wrong = Bool.pick(List<&2, U32>, miss, T.f2.write("add", "added", fs, path, T.mutant(fs, 0n), wk.out(w, path, wk.at(cks, 1n+wp.k(p)))), Nil{})
      +right = T.f2.write(Bool.pick(String, miss, "def", "add"), Bool.pick(String, miss, "ok", "added"), fs, path, wu.f(w, 7n), wk.out(w, path, wk.at(cks, i)))
      U.append(T.cat([T.f2.looks.new(fs, path, base), wrong, right]), wk.dsteps(t, 1n+i, p, path, base, cks))

def wk.dsession(+p: Wp, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  +ws = Wp.ws(p)
  +fs0 = wk.fs.head(Wu.fs(wk.first(ws)), wk.base0(ws))
  +v = T.f2.verdict(Wu.fs(wk.last(ws)), wk.at(cks, wp.k(p)))
  T.cat([T.mg.user(wk.dask(p, path)), T.f2.read.tail(fs0, path), wk.dsteps(ws, 1n, p, path, base, cks),
    T.mg.reply(T.cat([v, U.b(" Added "), T.f3.ands(wk.names(ws)), U.b(" ("), path, U.b(").")]))])

# checks 1..K pass
def wk.pass.from(ws: List<&2, Wu>, +i: Nat, +cks: List<&2, List<&2, U32>>) -> Bool:
  match ws:
    case Nil{}:
      True{}
    case +w <> t:
      Bool.and(wk.passes(wk.at(cks, i)), wk.pass.from(t, 1n+i, cks))

def wk.dvalid(+p: Wp, +cks: List<&2, List<&2, U32>>) -> Bool:
  +ws = Wp.ws(p)
  +j = Wp.j(p)
  +miss = Bool.pick(Bool, Nat.is_eq(j, 0n), True{}, wk.wrong(wk.at(cks, 1n+wp.k(p))))
  Bool.and(wk.pass.from(ws, 1n, cks), miss)

def wk.origs(ws: List<&2, Wu>) -> List<&2, List<&2, U32>>:
  match ws:
    case Nil{}:
      Nil{}
    case +w <> t:
      wu.f(w, 11n) <> wk.origs(t)

def wk.dguess(+p: Wp) -> List<&2, List<&2, U32>>:
  +ws = Wp.ws(p)
  +j = Wp.j(p)
  +mc = Bool.pick(List<&2, U32>, Nat.is_eq(j, 0n), Nil{}, T.mutant.check(Wu.fs(wk.nth(ws, Nat.sub(j, 1n))), 0n))
  List.concat(&2, List<&2, U32>, [[wu.f(wk.first(ws), 11n)], wk.origs(ws), [mc]])

# The shapes' dispatch (d: a direct walk) ------------------------------------------------------

def wk.is.d(+p: Wp) -> Bool:
  Nat.is_eq(Wp.kind(p), 2n)

def wk.states.on(d: Bool, +p: Wp) -> List<&2, List<&2, U32>>:
  match d:
    case True{}:
      wk.dstates(p)
    case False{}:
      wk.states.fa(p)

def wk.states(+p: Wp) -> List<&2, List<&2, U32>>:
  wk.states.on(wk.is.d(p), p)

def wk.session.on(d: Bool, +p: Wp, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match d:
    case True{}:
      wk.dsession(p, path, base, cks)
    case False{}:
      wk.session.fa(p, path, base, cks)

def wk.session(+p: Wp, +path: List<&2, U32>, +base: Map<&2, List<&2, U32>>, +cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  wk.session.on(wk.is.d(p), p, path, base, cks)

def wk.valid.on(d: Bool, +p: Wp, +cks: List<&2, List<&2, U32>>) -> Bool:
  match d:
    case True{}:
      wk.dvalid(p, cks)
    case False{}:
      wk.valid.fa(p, cks)

def wk.valid(+p: Wp, +cks: List<&2, List<&2, U32>>) -> Bool:
  wk.valid.on(wk.is.d(p), p, cks)

def wk.guess.on(d: Bool, +p: Wp) -> List<&2, List<&2, U32>>:
  match d:
    case True{}:
      wk.dguess(p)
    case False{}:
      wk.guess.fa(p)

def wk.guess(+p: Wp) -> List<&2, List<&2, U32>>:
  wk.guess.on(wk.is.d(p), p)

def wk.toks(+b: Tk.Bpe, +x: List<&2, U32>) -> Nat:
  List.length(&2, U32, Tk.Bpe.encode(b, x))

# the plan for units ws: shape and wrong write by the first's hash
def wk.plan(+ws: List<&2, Wu>) -> Wp:
  +id = Wu.id(wk.first(ws))
  +k = List.length(&2, Wu, ws)
  +r = T.roll(id, 43n, 100n)
  +kind = Bool.pick(Nat, Nat.is_lt(r, 34n), 0n, Bool.pick(Nat, Nat.is_lt(r, 67n), 1n, 2n))
  +j0 = Nat.add(1n, T.roll(id, 53n, k))
  +j = Bool.pick(Nat, Bool.and(Nat.is_lt(T.roll(id, 47n, 100n), 35n), wu.has.mut(wk.nth(ws, Nat.sub(j0, 1n)))), j0, 0n)
  Wp{ws, kind, j}

# whether the walk of rs's first k units (2 or more), its session guessed,
# fits the window (margin 64)
def wk.fits.k(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +path: List<&2, U32>, +rs: List<&2, Wu>, +k: Nat) -> Bool:
  +p = wk.plan(List.take(&2, Wu, rs, k))
  +n = wk.toks(b, wk.session(p, path, base, wk.guess(p)))
  Nat.is_le(Nat.add(n, 66n), limit)

def wk.fits(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +path: List<&2, U32>, +rs: List<&2, Wu>, k: Nat) -> Bool:
  match k:
    case 0n:
      False{}
    case 1n:
      False{}
    case 2n+m:
      wk.fits.k(b, limit, base, path, rs, 2n+m)

# how many of the run's first units the walk takes: the hash's K (2..kmax),
# fewer while its guessed session passes the window; 0: none fit

# fit: the walk of k units fits
def wk.take.go(+b: Tk.Bpe, +limit: Nat, +base: Map<&2, List<&2, U32>>, +path: List<&2, U32>, +rs: List<&2, Wu>, k: Nat, fit: Bool) -> Nat:
  match k fit:
    case 0n _:
      0n
    case 1n _:
      0n
    case 2n++m True{}:
      2n+m
    case 2n++m False{}:
      wk.take.go(b, limit, base, path, rs, 1n+m, wk.fits(b, limit, base, path, rs, 1n+m))

def wk.take(+b: Tk.Bpe, +limit: Nat, +kmax: Nat, +base: Map<&2, List<&2, U32>>, +path: List<&2, U32>, +rs: List<&2, Wu>) -> Nat:
  +n = List.length(&2, Wu, rs)
  +want = Nat.add(2n, T.roll(Wu.id(wk.first(rs)), 41n, Nat.sub(kmax, 1n)))
  +k0 = Nat.min(want, n)
  # a single unit left over joins the walk when it may
  +k1 = Bool.pick(Nat, Bool.and(Nat.is_eq(Nat.sub(n, k0), 1n), Nat.is_lt(k0, kmax)), n, k0)
  wk.take.go(b, limit, base, path, rs, k1, wk.fits(b, limit, base, path, rs, k1))

# The run (IO) ------------------------------------------------------------------------------

type Wc is Data:
  Wc{bend: String, t: U32, roots: List<&2, List<&2, U32>>, tmp: String, b: Tk.Bpe, limit: Nat, kmax: Nat, base: Map<&2, List<&2, U32>>, out: String}

def Wc.bend(+c: Wc) -> String:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      b

def Wc.t(+c: Wc) -> U32:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      t

def Wc.roots(+c: Wc) -> List<&2, List<&2, U32>>:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      r

def Wc.tmp(+c: Wc) -> String:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      m

def Wc.b(+c: Wc) -> Tk.Bpe:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      k

def Wc.limit(+c: Wc) -> Nat:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      l

def Wc.kmax(+c: Wc) -> Nat:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      x

def Wc.base(+c: Wc) -> Map<&2, List<&2, U32>>:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      s

def Wc.out(+c: Wc) -> String:
  match c:
    case Wc{b, t, r, m, k, l, x, s, o}:
      o

# a counter
type Wk is Data:
  Wk{k: String, n: Nat}

def wk.bump.go(st: List<&2, Wk>, +k: String, +d: Nat, found: Bool) -> List<&2, Wk>:
  match st:
    case Nil{}:
      Bool.pick(List<&2, Wk>, found, Nil{}, [Wk{k, d}])
    case Wk{+a, +n} <> t:
      +hit = String.eq(a, k)
      Wk{a, Bool.pick(Nat, hit, Nat.add(n, d), n)} <> wk.bump.go(t, k, d, Bool.or(hit, found))

def wk.bump(st: List<&2, Wk>, +k: String, +d: Nat) -> List<&2, Wk>:
  wk.bump.go(st, k, d, False{})

def wk.get(+st: List<&2, Wk>, +k: String) -> Nat:
  match st:
    case Nil{}:
      0n
    case Wk{+a, +n} <> t:
      Bool.pick(Nat, String.eq(a, k), n, wk.get(t, k))

def wk.st.bytes(st: List<&2, Wk>) -> List<&2, U32>:
  match st:
    case Nil{}:
      Nil{}
    case Wk{a, n} <> t:
      T.cat([S.b(a), [9], T.mg.n(n), [10], wk.st.bytes(t)])

# a placed file: the check's directories
type Wd is Data:
  Wd{tdir: String, udir: String}

def wk.check1(+c: Wc, +d: Wd, +x: List<&2, U32>) -> IO(List<&2, U32>):
  match d:
    case Wd{+td, +ud}:
      do IO<List<&2, U32>>:
        S.write(ud ++ "/Unit.bend", x)
        +o : S.Out <- S.run(ud, [], Wc.t(c), Wc.bend(c), ["Unit.bend", "--check-only"], Nil{})
        return Bd.check.of(td, 100n, o)

def wk.checks(+c: Wc, +d: Wd, xs: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match xs:
    case Nil{}:
      IO.pure(List<&2, List<&2, U32>>, Nil{})
    case +x <> more:
      do IO<List<&2, List<&2, U32>>>:
        +k : List<&2, U32> <- wk.check1(c, d, x)
        +r : List<&2, List<&2, U32>> <- wk.checks(c, d, more)
        return k <> r

# each check's status, in order (the log's)
def wk.stats(cks: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match cks:
    case Nil{}:
      Nil{}
    case +c <> t:
      U.append(wk.status(c), wk.stats(t))

def wk.emit(ok: Bool, +c: Wc, +id: List<&2, U32>, +shape: List<&2, U32>, +text: List<&2, U32>) -> IO(Unit):
  match ok:
    case True{}:
      S.add(Wc.out(c) ++ ".tmp", T.cat([id, U.b("/mugen-"), shape, [0], text, [0]]))
    case False{}:
      IO.pure(Unit, Unit{})

def wk.log(+c: Wc, +line: List<&2, U32>) -> IO(Unit):
  S.add(Wc.out(c) ++ ".log", U.append(line, [10]))

def wk.checks.if(go: Bool, +c: Wc, +d: Wd, +xs: List<&2, List<&2, U32>>, +had: List<&2, List<&2, U32>>) -> IO(List<&2, List<&2, U32>>):
  match go:
    case True{}:
      wk.checks(c, d, xs)
    case False{}:
      IO.pure(List<&2, List<&2, U32>>, had)

# one walk: its checks run, kept when valid and in the window
# (a direct walk whose checks differ, a definition between the units using
# one of them, is tried again as an add walk)
def wk.walk(+c: Wc, +d: Wd, +path: List<&2, U32>, +p0: Wp, +st0: List<&2, Wk>) -> IO(List<&2, Wk>):
  +id = Wu.id(wk.first(Wp.ws(p0)))
  do IO<List<&2, Wk>>:
    +cks0 : List<&2, List<&2, U32>> <- wk.checks(c, d, wk.states(p0))
    +back : Bool = Bool.and(wk.is.d(p0), Bool.not(wk.valid(p0, cks0)))
    +p : Wp = Bool.pick(Wp, back, Wp{Wp.ws(p0), 1n, Wp.j(p0)}, p0)
    +shape : List<&2, U32> = wk.shape(p)
    +cks : List<&2, List<&2, U32>> <- wk.checks.if(back, c, d, wk.states(p), cks0)
    +st : List<&2, Wk> = Bool.pick(List<&2, Wk>, back, wk.bump(wk.bump(st0, "direct-fell-back", 1n), "checks", List.length(&2, List<&2, U32>, cks0)), st0)
    +ok : Bool = wk.valid(p, cks)
    +text : List<&2, U32> = wk.session(p, path, Wc.base(c), cks)
    +n : Nat = wk.toks(Wc.b(c), text)
    +fits : Bool = Nat.is_le(Nat.add(n, 2n), Wc.limit(c))
    +e : List<&2, A.Turn> = A.ag.read.bytes(text)
    +rd : Bool = Bool.and(Nat.is_eq(A.ag.count(e, 6n), Bool.pick(Nat, Nat.is_eq(Wp.j(p), 0n), 0n, 1n)), Nat.is_eq(A.ag.count(e, 3n), 1n))
    +why : String = Bool.pick(String, ok, Bool.pick(String, fits, Bool.pick(String, rd, "kept", "reader-differs"), "too-long"), "checks-differ")
    +keep : Bool = Bool.and(ok, Bool.and(fits, rd))
    wk.emit(keep, c, id, shape, text)
    wk.log(c, T.cat([id, [9], shape, [9], S.b(why), [9], T.mg.n(n), [9], T.mg.n(List.length(&2, List<&2, U32>, cks)), U.b(" checks "), wk.stats(cks)]))
    +s1 : List<&2, Wk> = wk.bump(wk.bump(st, why, 1n), "checks", List.length(&2, List<&2, U32>, cks))
    return Bool.pick(List<&2, Wk>, keep, wk.bump(wk.bump(s1, S.str(shape), 1n), "tokens", n), s1)

def wk.take.c(+c: Wc, +path: List<&2, U32>, +rs: List<&2, Wu>) -> Nat:
  wk.take(Wc.b(c), Wc.limit(c), Wc.kmax(c), Wc.base(c), path, rs)

# a run's walks, one after another; k: how many units the next one takes (0:
# none, the first unit is passed over)
def wk.walks(fuel: Nat, +c: Wc, +d: Wd, +path: List<&2, U32>, +rs: List<&2, Wu>, st: List<&2, Wk>, k: Nat) -> IO(List<&2, Wk>):
  match fuel k:
    case 0n _:
      IO.pure(List<&2, Wk>, st)
    case 1n+f 0n:
      +rest = List.drop(&2, Wu, rs, 1n)
      wk.walks(f, c, d, path, rest, wk.bump(st, "passed-over", Bool.pick(Nat, Nat.is_eq(List.length(&2, Wu, rs), 0n), 0n, 1n)), wk.take.c(c, path, rest))
    case 1n+f 1n++q:
      +rest = List.drop(&2, Wu, rs, 1n+q)
      do IO<List<&2, Wk>>:
        +st2 : List<&2, Wk> <- wk.walk(c, d, path, wk.plan(List.take(&2, Wu, rs, 1n+q)), st)
        wk.walks(f, c, d, path, rest, st2, wk.take.c(c, path, rest))

# a run placed: its repository copied under the work dir once, its walks
def wk.placed(+c: Wc, +src: String, +rs: List<&2, Wu>, st: List<&2, Wk>) -> IO(List<&2, Wk>):
  +f = wk.first(rs)
  +rel = Bd.rel.of(Wu.id(f), wu.name(f))
  +tdir = Wc.tmp(c) ++ "/t" ++ String.take(H.sha256(S.b(src)), 8n)
  +repo = S.str(Bd.repo.of(rel))
  +udir = tdir ++ "/src/" ++ S.str(Cl.before.last(rel, [47]))
  do IO<List<&2, Wk>>:
    +h : Bool <- S.exists(tdir ++ "/src/" ++ repo)
    Mu.mtt.copy(h, src, tdir, repo)
    +path : List<&2, U32> = T.mg.path(Wu.id(f))
    +st2 : List<&2, Wk> <- wk.walks(1n+List.length(&2, Wu, rs), c, Wd{tdir, udir}, path, rs, wk.bump(st, "runs", 1n), wk.take.c(c, path, rs))
    S.rm(udir ++ "/Unit.bend")
    return st2

def wk.found(ok: Bool, +c: Wc, +src: String, +rs: List<&2, Wu>, st: List<&2, Wk>) -> IO(List<&2, Wk>):
  match ok:
    case True{}:
      wk.placed(c, src, rs, st)
    case False{}:
      do IO<List<&2, Wk>>:
        wk.log(c, U.append(Wu.id(wk.first(rs)), U.b("\tno-source")))
        return wk.bump(st, "no-source", 1n)

def wk.run1(+c: Wc, +rs: List<&2, Wu>, st: List<&2, Wk>) -> IO(List<&2, Wk>):
  +f = wk.first(rs)
  +rel = Bd.rel.of(Wu.id(f), wu.name(f))
  do IO<List<&2, Wk>>:
    +src : String <- Ex.ex.roots(Wc.roots(c), rel, wu.f(f, 7n))
    wk.found(Bool.not(String.is_empty(src)), c, src, rs, st)

def wk.all(rss: List<&2, List<&2, Wu>>, +c: Wc, st: List<&2, Wk>) -> IO(List<&2, Wk>):
  match rss:
    case Nil{}:
      IO.pure(List<&2, Wk>, st)
    case +rs <> more:
      do IO<List<&2, Wk>>:
        +st2 : List<&2, Wk> <- wk.run1(c, rs, st)
        wk.all(more, c, st2)

def wk.run(+inp: String, +out: String, +window: Nat, +tk: Tk.Bpe) -> IO(Unit):
  do IO<Unit>:
    +bend : String <- Mu.mtt.bend()
    +src : String <- S.env("BEND_SRC", "")
    +t : Nat <- S.env.nat("TIMEOUT", 60n)
    +kmax : Nat <- S.env.nat("KMAX", 5n)
    +bp : String <- S.env("BASE", "")
    bx : List<&2, U32> <- T.mg.base.read.on(String.eq(bp, ""), bp)
    S.rm(out ++ ".d")
    S.mkdir(out ++ ".d")
    +tmp : String <- S.realpath(out ++ ".d")
    S.write(out ++ ".tmp", Nil{})
    S.write(out ++ ".log", Nil{})
    kvs : List<&2, Ev.EvKv> <- Ev.ev.nul(inp)
    +ws : List<&2, Wu> = wu.of(kvs)
    +rss : List<&2, List<&2, Wu>> = wk.runs(ws)
    +base : Map<&2, List<&2, U32>> = T.mg.base.of(T.split(bx, 10), Map.new(&2, List<&2, U32>))
    +c : Wc = Wc{bend, U32.from_nat(t), S.split(S.b(src), 58), tmp, tk, Nat.sub(window, 64n), Nat.max(kmax, 2n), base, out}
    +st0 : List<&2, Wk> = wk.bump(wk.bump(Nil{}, "units", List.length(&2, Wu, ws)), "runs-of-2+", List.length(&2, List<&2, Wu>, rss))
    +st : List<&2, Wk> <- wk.all(rss, c, st0)
    S.mv(out ++ ".tmp", out)
    S.write(out ++ ".stats", wk.st.bytes(st))
    S.rm(out ++ ".d")
    IO.print("walk " ++ inp ++ ": " ++ Nat.show(wk.get(st, "units")) ++ " units, " ++ Nat.show(wk.get(st, "runs")) ++ " runs, "
      ++ Nat.show(wk.get(st, "kept")) ++ " walks kept (" ++ Nat.show(wk.get(st, "checks-differ")) ++ " checks differ, "
      ++ Nat.show(wk.get(st, "too-long")) ++ " too long, " ++ Nat.show(wk.get(st, "no-source")) ++ " no source), "
      ++ Nat.show(wk.get(st, "checks")) ++ " checks, " ++ Nat.show(wk.get(st, "tokens")) ++ " tokens")

def wk.start(+inp: String, +out: String, +window: Nat, m: Maybe<&2, Tk.Bpe>) -> IO(Unit):
  match m:
    case Some{+tk}:
      wk.run(inp, out, window, tk)
    case None{}:
      IO.die(Unit, 1, "bend-walk: the tokenizer does not read")

def wk.go(+tok: String, +inp: String, +out: String, +window: Nat) -> IO(Unit):
  do IO<Unit>:
    tx : List<&2, U32> <- B.Bytes.read_all(tok)
    wk.start(inp, out, window, Tk.Bpe.parse(tx))

def wk.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +tok <> +inp <> +out <> Nil{}:
      wk.go(tok, inp, out, 2048n)
    case +tok <> +inp <> +out <> +w <> Nil{}:
      wk.go(tok, inp, out, Maybe.default(&2, Nat, Nat.read(w), 2048n))
    case _:
      IO.die(Unit, 2, "usage: bend-walk TOKENIZER UNITS OUT [WINDOW]   (env BEND, BEND_SRC, BASE, TIMEOUT 60, KMAX 5)")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    xs : List<String> = List.tail(&1, String, argv)
    wk.main(xs)
