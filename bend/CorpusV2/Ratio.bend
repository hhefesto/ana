import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Json.bend as J
import ../Check/Lib.bend as Cl
import ../Agent/Spec.bend as A
import ./Lib.bend as L
import ./Keyed.bend as K

# repair-mix: the user's ratio rule on a run's transcripts (2026-10-22, for
# run 5).  The user: "For each program that is incorrect, and it takes a tool
# call to fix, the training corpus should contain four times the program
# correct from the start. I don't want ana to train on answering wrong on the
# first try, I want ana to learn how to correct her mistakes if they occur."
#
#   bend-corpus-v2 repair-mix OUT WORD...
#
#   in=FILE      a transcript stream (NUL pairs: id, text) under the rule
#   free=FILE    a stream passed through whole: its first-time transcripts
#                count toward their units' copies, its repairs are not
#                counted, capped or dropped (a run that keeps a set as it was)
#   held=FILE    held-out units, a line each: a unit id, or `REASON TAB ID`
#                as decl-new's OUT.dropped writes it (only the reasons
#                v2-held, held-file, held-text and held-decl count); an id
#                without `#` holds out every unit of that file
#   ratio=N      first-time transcripts a kept repair needs (4)
#   cap=N        repairs kept a unit (1)
#   share=P      the repair budget: only units whose slot, int(sha256(salt
#                NUL "share" NUL u)[:8], 16) % 100, is under P keep repairs
#                (100: every unit); the rest go as drop-share, and their
#                units keep only their own first-time transcripts
#   salt=S       the keys' salt ("ana repair-mix")
#   fill=other|repair   whether a fill (a hole handed over, id .../fill) is a
#                repair (other: it is kept as it stands, uncounted)
#   derive=none|whole|all   a repair whose unit has no first-time transcript:
#                none drops it; whole derives one from the repair for a
#                whole-file unit (an id without `#`: port's files), all for
#                any unit (rto.derive: the repair less its fix line, its
#                attempts and tries and the tool's answers to them)
#   dry          count only: OUT.stats and the summary, no OUT
#
# A transcript's class is read with the trainer's own reader (Agent/Spec's
# ag.read, the roles TRAIN_MASK=kinds weighs): a repair has an attempt or a
# try (a program the tool rejected, weight 0) before its act; a first-time
# transcript has an act and neither; anything else is other.  An id ending
# /verify is the verify shape (dropped, as run 3 dropped it); /fill is a fill.
#
# A transcript's unit is its id less a leading `mut:` (mutate's repairs),
# less its last `/` segment (the shape: direct, repair, fill, chain-K, an
# operator-K, repair for a port's file), less a trailing `+N` (the unit's
# N-th presentation).  Its tag is that last segment less a trailing `-N`
# (the shape or the operator).
#
# The rule, a unit u at a time (u not held out): f(u) its first-time
# transcripts (every source's), r(u) its repairs from in= sources.  The kept
# repairs are none when u is outside the share, else the cap(u) =
# min(cap, |r(u)|) whose key, sha256(salt NUL u NUL tag) then
# sha256(salt NUL id), is least: a unit's operators are drawn
# evenly whatever how many mutants each gave (no operator crowds out the
# rest), and the choice is the same on any machine.  When f(u) = 0 they are
# dropped (no-first) unless derive covers u.  The unit's first-time
# transcripts are then copied until there are max(f(u), ratio * kept(u)) of
# them, the extra copies spread evenly over its distinct ones in the order
# read (copy k of id is id/eK, k from 2); a derived one is id/first, its
# copies id/first/eK.  So every unit has first-time >= ratio * kept and
# kept <= cap, its ordinary appearance counting toward the ratio.
#
# OUT holds everything kept and every copy in sha256(salt NUL id) order (K's
# spool, `sort -z`): no window packs a transcript next to its own copies or
# its unit's repair (format 2 rendered a unit's presentations side by side).
# OUT.stats: `key count` lines in byte order (the classes read, held, dropped
# and written, their bytes, the units by state, the kept repairs by tag), also
# printed.  Without free= sources, OUT is then audited (rto.audit): every
# unit's first-time count >= ratio * its repairs, repairs <= cap, no id twice.
#
# Logs go to stderr, stamped UTC-6.  The laws are bend/tests/ratio.bend.
# Every def is prefixed `rto.`.

def rto.log(+msg: String) -> IO(Unit):
  K.kor.log("repair-mix", msg)

def rto.big() -> Nat:
  U32.to_nat(4294967295)

# Ids (pure) ------------------------------------------------------------------------

def rto.rev(+xs: List<&2, U32>) -> List<&2, U32>:
  List.reverse(&2, U32, xs)

# the last `/` segment (all of id when it has none)
def rto.seg(+id: List<&2, U32>) -> List<&2, U32>:
  rto.rev(L.v2.before(rto.rev(id), 47))

# everything before the last `/` (all of id when it has none)
def rto.stem(+id: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, L.v2.has(id, 47), L.v2.parent(id, 47), id)

def rto.isd(+c: U32) -> Bool:
  Bool.and(U32.is_le(48, c), U32.is_le(c, 57))

def rto.hd.isd(+xs: List<&2, U32>) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case +c <> t:
      rto.isd(c)

# the leading digits dropped
def rto.undigit(xs: List<&2, U32>, at: Bool) -> List<&2, U32>:
  match xs at:
    case h <> +t True{}:
      rto.undigit(t, rto.hd.isd(t))
    case r _:
      r

# xs less a trailing SEP N (SEP the byte c, N one digit or more), else xs
def rto.unnum(+xs: List<&2, U32>, +c: U32) -> List<&2, U32>:
  +r = rto.rev(xs)
  +d = rto.undigit(r, rto.hd.isd(r))
  +num = Bool.not(Nat.is_eq(S.len(d), S.len(r)))
  Bool.pick(List<&2, U32>, Bool.and(num, L.v2.head.is(d, c)), rto.rev(List.drop(&2, U32, d, 1n)), xs)

def rto.unmut(+id: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, S.prefix(id, S.b("mut:")), List.drop(&2, U32, id, 4n), id)

# a transcript's unit
def rto.unit(+id: List<&2, U32>) -> List<&2, U32>:
  rto.unnum(rto.stem(rto.unmut(id)), 43)

# its tag: the shape or the operator
def rto.tag(+id: List<&2, U32>) -> List<&2, U32>:
  rto.unnum(rto.seg(id), 45)

# a whole-file unit (no `#`: a port's file)
def rto.whole(+u: List<&2, U32>) -> Bool:
  Bool.not(L.v2.has(u, 35))

# Classes (pure) --------------------------------------------------------------------
#
# 0 first-time, 1 repair, 2 other, 3 verify

def rto.class.name(+c: Nat) -> String:
  match c:
    case 0n:
      "first"
    case 1n:
      "repair"
    case 2n:
      "other"
    case _:
      "verify"

# by the roles: an act and no attempt or try, first; an act after one, repair
def rto.class.roles(+e: List<&2, A.Turn>) -> Nat:
  +bad = Nat.add(A.ag.count(e, 2n), A.ag.count(e, 6n))
  +act = A.ag.count(e, 3n)
  Bool.pick(Nat, Nat.is_eq(act, 0n), 2n, Bool.pick(Nat, Nat.is_eq(bad, 0n), 0n, 1n))

# shape 0 by the roles, 1 a fill, 2 a verify
def rto.class.of(shape: Nat, +fillrep: Bool, +text: List<&2, U32>) -> Nat:
  match shape:
    case 0n:
      rto.class.roles(A.ag.read.bytes(text))
    case 1n:
      Bool.pick(Nat, fillrep, 1n, 2n)
    case _:
      3n

def rto.shape(+tag: List<&2, U32>) -> Nat:
  Bool.pick(Nat, S.eq(tag, S.b("verify")), 2n, Bool.pick(Nat, S.eq(tag, S.b("fill")), 1n, 0n))

def rto.class(+fillrep: Bool, +id: List<&2, U32>, +text: List<&2, U32>) -> Nat:
  rto.class.of(rto.shape(rto.tag(id)), fillrep, text)

# The first-time transcript a repair implies (pure) -------------------------------------
#
# The repair's turns less every attempt and try and the tool's turn after
# each, and the User turn less "This attempt fails. Fix it.": Transcript's
# direct shape when the repair is its repair shape (the same User, Context,
# Type, Term and pass; laws in bend/tests/ratio.bend).

def rto.fixline() -> List<&2, U32>:
  S.b("\n\nThis attempt fails. Fix it.")

def rto.drv.turn(+code: Nat, +x: List<&2, U32>) -> List<&2, U32>:
  Bool.pick(List<&2, U32>, Nat.is_eq(code, 0n), S.replace.first(x, rto.fixline(), Nil{}), x)

# skip: inside a dropped attempt or try and its tool's answer
def rto.drv.go(e: List<&2, A.Turn>, +skip: Bool) -> List<&2, U32>:
  match e:
    case Nil{}:
      Nil{}
    case A.Turn{r, +x} <> t:
      +c = A.ag.role.code(r)
      +bad = Bool.or(Nat.is_eq(c, 2n), Nat.is_eq(c, 6n))
      +tool = Bool.or(Nat.is_eq(c, 4n), Nat.is_eq(c, 5n))
      +drop = Bool.or(bad, Bool.and(skip, tool))
      +rest = rto.drv.go(t, drop)
      Bool.pick(List<&2, U32>, drop, rest, List.append(&2, U32, rto.drv.turn(c, x), rest))

def rto.derive(+text: List<&2, U32>) -> List<&2, U32>:
  rto.drv.go(A.ag.read.bytes(text), False{})

# The settings ------------------------------------------------------------------------

# derive: 0 none, 1 whole, 2 all
type RtCfg is Data:
  RtCfg{ratio: Nat, cap: Nat, salt: List<&2, U32>, fill: Bool, derive: Nat, dry: Bool, share: Nat}

def rto.cfg0() -> RtCfg:
  RtCfg{4n, 1n, S.b("ana repair-mix"), False{}, 0n, False{}, 100n}

def rto.ratio(+c: RtCfg) -> Nat:
  match c:
    case RtCfg{r, k, s, f, d, y, q}:
      r

def rto.cap(+c: RtCfg) -> Nat:
  match c:
    case RtCfg{r, k, s, f, d, y, q}:
      k

def rto.salt(+c: RtCfg) -> List<&2, U32>:
  match c:
    case RtCfg{r, k, s, f, d, y, q}:
      s

def rto.fill(+c: RtCfg) -> Bool:
  match c:
    case RtCfg{r, k, s, f, d, y, q}:
      f

def rto.dry(+c: RtCfg) -> Bool:
  match c:
    case RtCfg{r, k, s, f, d, y, q}:
      y

def rto.share(+c: RtCfg) -> Nat:
  match c:
    case RtCfg{r, k, s, f, d, y, q}:
      q

# the first n hex digits of xs as a number
def rto.hexv(n: Nat, xs: List<&2, U32>, +acc: Nat) -> Nat:
  match n xs:
    case 1n+k +h <> t:
      rto.hexv(k, t, Nat.add(Nat.mul(acc, 16n), U32.to_nat(J.hexd(h))))
    case _ _:
      acc

# a unit's place in the repair budget: int(sha256(salt NUL "share" NUL u)[:8], 16) % 100
def rto.slot(+salt: List<&2, U32>, +u: List<&2, U32>) -> Nat:
  Nat.mod(rto.hexv(8n, S.b(H.sha256(L.v2.concat([salt, [0], S.b("share"), [0], u]))), 0n), 100n)

# whether a unit may keep repairs: its slot is under share (every unit at 100)
def rto.shared(+c: RtCfg, +u: List<&2, U32>) -> Bool:
  Nat.is_lt(rto.slot(rto.salt(c), u), rto.share(c))

# whether derive covers a unit
def rto.deriv(+c: RtCfg, +u: List<&2, U32>) -> Bool:
  match c:
    case RtCfg{r, k, s, f, d, y, q}:
      Bool.or(Nat.is_eq(d, 2n), Bool.and(Nat.is_eq(d, 1n), rto.whole(u)))

def rto.derive.name(+d: Nat) -> String:
  match d:
    case 0n:
      "none"
    case 1n:
      "whole"
    case _:
      "all"

def rto.cfg.show(+c: RtCfg) -> String:
  match c:
    case RtCfg{+r, +k, +s, +f, +d, +y, +q}:
      "ratio=" ++ Nat.show(r) ++ " cap=" ++ Nat.show(k) ++ " share=" ++ Nat.show(q) ++ " salt=" ++ S.str(s) ++ " fill=" ++ Bool.pick(String, f, "repair", "other") ++ " derive=" ++ rto.derive.name(d) ++ Bool.pick(String, y, " dry", "")

# A unit's state (pure) ------------------------------------------------------------------
#
# f its first-time transcripts, n its repairs (in= sources), best the
# repairs with the least keys, at most cap, in key order

type RtR is Data:
  RtR{key: String, id: String}

type RtU is Data:
  RtU{f: Nat, n: Nat, best: List<&2, RtR>}

def rto.u0() -> RtU:
  RtU{0n, 0n, Nil{}}

def rto.key(+salt: List<&2, U32>, +u: List<&2, U32>, +id: List<&2, U32>) -> String:
  H.sha256(L.v2.concat([salt, [0], u, [0], rto.tag(id)])) ++ H.sha256(L.v2.concat([salt, [0], id]))

def rto.r.le(+a: RtR, +b: RtR) -> Bool:
  match a b:
    case RtR{x, i} RtR{y, j}:
      S.bytes.le(S.b(x), S.b(y))

def rto.ins(+r: RtR, b: List<&2, RtR>) -> List<&2, RtR>:
  match b:
    case Nil{}:
      [r]
    case +h <> +t:
      Bool.pick(List<&2, RtR>, rto.r.le(r, h), r <> h <> t, h <> rto.ins(r, t))

def rto.best(+c: RtCfg, +u: List<&2, U32>, +id: List<&2, U32>, b: List<&2, RtR>) -> List<&2, RtR>:
  List.take(&2, RtR, rto.ins(RtR{rto.key(rto.salt(c), u, id), S.str(id)}, b), rto.cap(c))

def rto.in.best(+id: String, b: List<&2, RtR>) -> Bool:
  match b:
    case Nil{}:
      False{}
    case RtR{k, +i} <> t:
      Bool.or(String.eq(i, id), rto.in.best(id, t))

def rto.u.f(+x: RtU) -> Nat:
  match x:
    case RtU{f, n, b}:
      f

def rto.u.n(+x: RtU) -> Nat:
  match x:
    case RtU{f, n, b}:
      n

def rto.u.best(+x: RtU) -> List<&2, RtR>:
  match x:
    case RtU{f, n, b}:
      b

# the repairs a unit keeps: its best, unless it is outside the share, or
# it has no first-time transcript and derive does not cover it
def rto.kept.n(+c: RtCfg, +u: List<&2, U32>, +x: RtU) -> Nat:
  +ok = Bool.and(rto.shared(c, u), Bool.or(Nat.is_lt(0n, rto.u.f(x)), rto.deriv(c, u)))
  Bool.pick(Nat, ok, List.length(&2, RtR, rto.u.best(x)), 0n)

# the first-time transcripts a unit ends with: max(f, ratio * kept)
def rto.firsts.n(+c: RtCfg, +u: List<&2, U32>, +x: RtU) -> Nat:
  Nat.max(rto.u.f(x), Nat.mul(rto.ratio(c), rto.kept.n(c, u, x)))

# the extra copies of the unit's j-th first-time transcript (f > 0): the
# missing ones spread evenly, the first (missing mod f) one more
def rto.extras(+c: RtCfg, +u: List<&2, U32>, +x: RtU, +j: Nat) -> Nat:
  +f = rto.u.f(x)
  +e = Nat.sub(rto.firsts.n(c, u, x), f)
  Nat.add(Nat.div(e, f), Bool.pick(Nat, Nat.is_lt(j, Nat.mod(e, f)), 1n, 0n))

# what pass 1 does with a transcript: 0 count a first-time one, 1 a
# repair, 2 nothing (held out, other, verify, a free source's repair)
def rto.kind1(+held: Bool, +c: Nat, +free: Bool) -> Nat:
  Bool.pick(Nat, held, 2n, Bool.pick(Nat, Nat.is_eq(c, 0n), 0n, Bool.pick(Nat, Bool.and(Nat.is_eq(c, 1n), Bool.not(free)), 1n, 2n)))

def rto.upd(kind: Nat, +c: RtCfg, +u: List<&2, U32>, +id: List<&2, U32>, x: RtU) -> RtU:
  match kind x:
    case 0n RtU{f, n, b}:
      RtU{1n+f, n, b}
    case _ RtU{f, n, b}:
      RtU{f, 1n+n, rto.best(c, u, id, b)}

# what pass 2 does with a transcript: 0 held out, 1 a verify, 2 a
# first-time one (and its copies), 3 a kept repair, 4 a kept repair whose
# unit's first-time transcripts are derived from it, 5 a repair over the
# cap, 6 a repair whose unit has no first-time transcript, 7 passed through
# (other, or a free source's repair), 8 a repair of a unit outside the share
def rto.kind2(+c: RtCfg, +free: Bool, +cl: Nat, +held: Bool, +u: List<&2, U32>, +id: List<&2, U32>, +x: RtU) -> Nat:
  +nofirst = Nat.is_eq(rto.u.f(x), 0n)
  +rep = Bool.pick(Nat, Bool.not(rto.shared(c, u)), 8n, Bool.pick(Nat, Bool.and(nofirst, Bool.not(rto.deriv(c, u))), 6n,
    Bool.pick(Nat, rto.in.best(S.str(id), rto.u.best(x)), Bool.pick(Nat, nofirst, 4n, 3n), 5n)))
  Bool.pick(Nat, held, 0n, Bool.pick(Nat, Nat.is_eq(cl, 3n), 1n, Bool.pick(Nat, Nat.is_eq(cl, 0n), 2n,
    Bool.pick(Nat, Bool.and(Nat.is_eq(cl, 1n), Bool.not(free)), rep, 7n))))

# Held-out units -------------------------------------------------------------------------

def rto.held.reason(+r: List<&2, U32>) -> Bool:
  Bool.or(Bool.or(S.eq(r, S.b("v2-held")), S.eq(r, S.b("held-file"))), Bool.or(S.eq(r, S.b("held-text")), S.eq(r, S.b("held-decl"))))

# a held file's line: the id it holds out, if any
def rto.held.line(+l: List<&2, U32>) -> Maybe<&2, String>:
  +tab = L.v2.has(l, 9)
  +id = Bool.pick(List<&2, U32>, tab, rto.rev(L.v2.before(rto.rev(l), 9)), l)
  +ok = Bool.and(Bool.not(Nat.is_eq(S.len(id), 0n)), Bool.or(Bool.not(tab), rto.held.reason(L.v2.before(l, 9))))
  Bool.pick(Maybe<&2, String>, ok, Some{S.str(id)}, None{})

# the file a held line names (its id before `#`)
def rto.held.file(m: Maybe<&2, String>) -> Maybe<&2, String>:
  match m:
    case Some{+x}:
      Some{S.str(L.v2.before(S.b(x), 35))}
    case None{}:
      None{}

def rto.set.add(m: Maybe<&2, String>, h: Set()) -> Set():
  match m:
    case Some{x}:
      Set.add(h, x)
    case None{}:
      h

def rto.nonempty(xss: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match xss:
    case Nil{}:
      Nil{}
    case +x <> more:
      +r = rto.nonempty(more)
      Bool.pick(List<&2, List<&2, U32>>, Nat.is_eq(S.len(x), 0n), r, x <> r)

# the id, and for a unit (FILE#NAME@LINE) the marker #FILE: its file holds a
# held-out declaration, which holds out a whole-file unit (a port's file)
def rto.held.add.if(has: Bool, +x: String, +f: String, h: Set()) -> Set():
  match has:
    case True{}:
      Set.add(Set.add(h, x), "#" ++ f)
    case False{}:
      Set.add(h, x)

def rto.held.add(m: Maybe<&2, String>, h: Set()) -> Set():
  match m:
    case Some{+x}:
      +b = S.b(x)
      rto.held.add.if(L.v2.has(b, 35), x, S.str(L.v2.before(b, 35)), h)
    case None{}:
      h

def rto.held.or(+key: String, r: Set() & Bool) -> Set() & Bool:
  (h, a) = r
  match a:
    case True{}:
      (h, True{})
    case False{}:
      Set.has(h, key)

# whether a unit is held out: the unit, its file (the id before `#`), or for
# a whole-file unit a held unit of the file
def rto.held(h: Set(), +u: List<&2, U32>) -> Set() & Bool:
  +f = S.str(L.v2.before(u, 35))
  +w = Bool.pick(String, rto.whole(u), "#" ++ S.str(u), S.str(u))
  rto.held.or(w, rto.held.or(f, Set.has(h, S.str(u))))

type RtHl is Type:
  RtHl{r: S.Rd, h: Set(), n: Nat, more: Bool}

def rto.hl.got(h: Set(), +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RtHl):
  (r, m) = x
  match m:
    case None{}:
      IO.pure(RtHl, RtHl{r, h, n, False{}})
    case Some{+l}:
      IO.pure(RtHl, RtHl{r, rto.held.add(rto.held.line(l), h), 1n+n, True{}})

def rto.hl.go(fuel: Nat, s: RtHl) -> IO(RtHl):
  match fuel s:
    case 1n+f RtHl{r, h, n, True{}}:
      IO.bind(RtHl, RtHl, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, RtHl, S.Rd.next(r), rto.hl.got(h, n)), rto.hl.go(f))
    case _ s2:
      IO.pure(RtHl, s2)

def rto.hl.fin(+path: String, s: RtHl) -> IO(Set()):
  match s:
    case RtHl{r, h, +n, g}:
      do IO<Set()>:
        S.Rd.close(r)
        rto.log("held " ++ path ++ ": " ++ Nat.show(n) ++ " lines")
        return h

def rto.held.load(ps: List<&2, String>, h: Set()) -> IO(Set()):
  match ps:
    case Nil{}:
      IO.pure(Set(), h)
    case +p <> more:
      do IO<Set()>:
        r : S.Rd <- S.Rd.lines(p)
        s : RtHl <- rto.hl.go(rto.big(), RtHl{r, h, 0n, True{}})
        h2 : Set() <- rto.hl.fin(p, s)
        rto.held.load(more, h2)

# Pass 1: every unit's first-time transcripts and best repairs ----------------------------------

type RtP1 is Type:
  RtP1{r: S.Rd, m: Map<&2, RtU>, h: Set(), n: Nat, more: Bool, odd: Bool}

def rto.p1.unit.got(+kind: Nat, +c: RtCfg, +u: List<&2, U32>, +id: List<&2, U32>, y: Map<&2, RtU> & RtU) -> Map<&2, RtU>:
  (m, x) = y
  Map.set(&2, RtU, m, S.str(u), rto.upd(kind, c, u, id, x))

def rto.p1.unit(kind: Nat, +c: RtCfg, +u: List<&2, U32>, +id: List<&2, U32>, m: Map<&2, RtU>) -> Map<&2, RtU>:
  match kind:
    case 0n:
      rto.p1.unit.got(0n, c, u, id, Map.get(RtU, rto.u0(), m, S.str(u)))
    case 1n:
      rto.p1.unit.got(1n, c, u, id, Map.get(RtU, rto.u0(), m, S.str(u)))
    case _:
      m

def rto.p1.held(+c: RtCfg, +free: Bool, r: S.Rd, m: Map<&2, RtU>, +n: Nat, +u: List<&2, U32>, +id: List<&2, U32>, +cl: Nat, x: Set() & Bool) -> RtP1:
  (h, hd) = x
  RtP1{r, rto.p1.unit(rto.kind1(hd, cl, free), c, u, id, m), h, 1n+n, True{}, False{}}

def rto.p1.do(+c: RtCfg, +free: Bool, r: S.Rd, m: Map<&2, RtU>, h: Set(), +n: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> RtP1:
  +u = rto.unit(id)
  rto.p1.held(c, free, r, m, n, u, id, rto.class(rto.fill(c), id, t), rto.held(h, u))

def rto.p1.pair(+c: RtCfg, +free: Bool, m: Map<&2, RtU>, h: Set(), +n: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RtP1):
  (r, mt) = x
  match mt:
    case None{}:
      IO.pure(RtP1, RtP1{r, m, h, n, False{}, True{}})
    case Some{+t}:
      IO.pure(RtP1, rto.p1.do(c, free, r, m, h, n, id, t))

def rto.p1.got(+c: RtCfg, +free: Bool, m: Map<&2, RtU>, h: Set(), +n: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RtP1):
  (r, mt) = x
  match mt:
    case None{}:
      IO.pure(RtP1, RtP1{r, m, h, n, False{}, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, RtP1, S.Rd.next(r), rto.p1.pair(c, free, m, h, n, id))

def rto.p1.step(+c: RtCfg, +free: Bool, s: RtP1) -> IO(RtP1):
  match s:
    case RtP1{r, m, h, n, g, odd}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, RtP1, S.Rd.next(r), rto.p1.got(c, free, m, h, n))

def rto.p1.go(fuel: Nat, +c: RtCfg, +free: Bool, s: RtP1) -> IO(RtP1):
  match fuel s:
    case 1n+f RtP1{r, m, h, n, True{}, odd}:
      IO.bind(RtP1, RtP1, rto.p1.step(c, free, RtP1{r, m, h, n, True{}, odd}), rto.p1.go(f, c, free))
    case _ s2:
      IO.pure(RtP1, s2)

type RtMH is Type:
  RtMH{m: Map<&2, RtU>, h: Set()}

def rto.odd(+path: String, odd: Bool) -> IO(Unit):
  match odd:
    case True{}:
      IO.die(Unit, 1, "repair-mix: " ++ path ++ " ends with an id that has no text (an odd number of NUL fields)")
    case False{}:
      IO.pure(Unit, Unit{})

def rto.p1.fin(+path: String, s: RtP1) -> IO(RtMH):
  match s:
    case RtP1{r, m, h, +n, g, odd}:
      do IO<RtMH>:
        S.Rd.close(r)
        rto.odd(path, odd)
        rto.log("pass 1: " ++ path ++ ": " ++ Nat.show(n) ++ " transcripts")
        return RtMH{m, h}

# Sources ----------------------------------------------------------------------------------

type RtSrc is Data:
  RtSrc{path: String, free: Bool}

def rto.p1.src(+c: RtCfg, +src: RtSrc, mh: RtMH) -> IO(RtMH):
  match src mh:
    case RtSrc{+p, +free} RtMH{m, h}:
      do IO<RtMH>:
        r : S.Rd <- S.Rd.open(p)
        s : RtP1 <- rto.p1.go(rto.big(), c, free, RtP1{r, m, h, 0n, True{}, False{}})
        rto.p1.fin(p, s)

def rto.p1.all(+c: RtCfg, ss: List<&2, RtSrc>, mh: RtMH) -> IO(RtMH):
  match ss:
    case Nil{}:
      IO.pure(RtMH, mh)
    case +s <> more:
      IO.bind(RtMH, RtMH, rto.p1.src(c, s, mh), rto.p1.all(c, more))

# Pass 2: the output ------------------------------------------------------------------------

def rto.emit.if(dry: Bool, +salt: List<&2, U32>, +id: List<&2, U32>, +t: List<&2, U32>, o: File) -> IO(File):
  match dry:
    case True{}:
      IO.pure(File, o)
    case False{}:
      S.emit(o, K.kor.nul.rec(K.kor.key(salt, id), id, t))

# a record onto the spool (none when dry)
def rto.emit(+c: RtCfg, +id: List<&2, U32>, +t: List<&2, U32>, o: File) -> IO(File):
  rto.emit.if(rto.dry(c), rto.salt(c), id, t, o)

def rto.copy.id(+id: List<&2, U32>, +k: Nat) -> List<&2, U32>:
  L.v2.concat([id, S.b("/e"), S.b(Nat.show(k))])

# copies k, k+1, ... (n of them) of a transcript
def rto.copies(n: Nat, +k: Nat, +c: RtCfg, +id: List<&2, U32>, +t: List<&2, U32>, o: File) -> IO(File):
  match n:
    case 0n:
      IO.pure(File, o)
    case 1n+p:
      IO.bind(File, File, rto.emit(c, rto.copy.id(id, k), t, o), rto.copies(p, 1n+k, c, id, t))

# a transcript and n copies of it
def rto.emit.n(+n: Nat, +c: RtCfg, +id: List<&2, U32>, +t: List<&2, U32>, o: File) -> IO(File):
  IO.bind(File, File, rto.emit(c, id, t, o), rto.copies(n, 2n, c, id, t))

type RtP2 is Type:
  RtP2{r: S.Rd, o: File, m: Map<&2, RtU>, j: Map<&2, Nat>, h: Set(), st: List<&2, Cl.Stat>, more: Bool, odd: Bool}

def rto.bump(+k: String, +n: Nat, st: List<&2, Cl.Stat>) -> List<&2, Cl.Stat>:
  Cl.stat.bump(k, n, st)

def rto.bump2(+k: String, +n: Nat, +bk: String, +b: Nat, st: List<&2, Cl.Stat>) -> List<&2, Cl.Stat>:
  Cl.stat.bump(bk, b, Cl.stat.bump(k, n, st))

# a first-time transcript: it and its copies, the unit's count of them seen
def rto.p2.first(+c: RtCfg, +u: List<&2, U32>, +id: List<&2, U32>, +t: List<&2, U32>, +x: RtU, r: S.Rd, o: File, m: Map<&2, RtU>, h: Set(), st: List<&2, Cl.Stat>, y: Map<&2, Nat> & Nat) -> IO(RtP2):
  (j, +k) = y
  +e = rto.extras(c, u, x, k)
  +b = Nat.mul(1n+e, S.len(t))
  do IO<RtP2>:
    o2 : File <- rto.emit.n(e, c, id, t, o)
    return RtP2{r, o2, m, Map.set(&2, Nat, j, S.str(u), 1n+k), h, rto.bump2("out-copy", e, "out-bytes-first", b, rto.bump("out-first", 1n, st)), True{}, False{}}

# a kept repair whose unit's first-time transcripts come from it
def rto.p2.derived(+c: RtCfg, +id: List<&2, U32>, +t: List<&2, U32>, o: File) -> IO(File):
  +d = rto.derive(t)
  IO.bind(File, File, rto.emit(c, id, t, o), rto.emit.n(Nat.sub(rto.ratio(c), 1n), c, L.v2.concat([id, S.b("/first")]), d))

def rto.p2.act(a: Nat, +c: RtCfg, +free: Bool, +cl: Nat, +u: List<&2, U32>, +id: List<&2, U32>, +t: List<&2, U32>, +x: RtU, r: S.Rd, o: File, m: Map<&2, RtU>, j: Map<&2, Nat>, h: Set(), st: List<&2, Cl.Stat>) -> IO(RtP2):
  match a:
    case 0n:
      IO.pure(RtP2, RtP2{r, o, m, j, h, rto.bump("held-" ++ rto.class.name(cl), 1n, st), True{}, False{}})
    case 1n:
      IO.pure(RtP2, RtP2{r, o, m, j, h, rto.bump("drop-verify", 1n, st), True{}, False{}})
    case 2n:
      rto.p2.first(c, u, id, t, x, r, o, m, h, st, Map.get(Nat, 0n, j, S.str(u)))
    case 3n:
      do IO<RtP2>:
        o2 : File <- rto.emit(c, id, t, o)
        return RtP2{r, o2, m, j, h, rto.bump("kept-tag " ++ S.str(rto.tag(id)), 1n, rto.bump2("out-repair", 1n, "out-bytes-repair", S.len(t), st)), True{}, False{}}
    case 4n:
      +dl = S.len(rto.derive(t))
      do IO<RtP2>:
        o2 : File <- rto.p2.derived(c, id, t, o)
        return RtP2{r, o2, m, j, h, rto.bump("kept-tag " ++ S.str(rto.tag(id)), 1n, rto.bump2("out-repair", 1n, "out-bytes-repair", S.len(t),
          rto.bump2("out-derived", rto.ratio(c), "out-bytes-first", Nat.mul(rto.ratio(c), dl), st))), True{}, False{}}
    case 5n:
      IO.pure(RtP2, RtP2{r, o, m, j, h, rto.bump("drop-cap", 1n, st), True{}, False{}})
    case 6n:
      IO.pure(RtP2, RtP2{r, o, m, j, h, rto.bump("drop-no-first", 1n, st), True{}, False{}})
    case 8n:
      IO.pure(RtP2, RtP2{r, o, m, j, h, rto.bump("drop-share", 1n, st), True{}, False{}})
    case _:
      +k = "out-" ++ Bool.pick(String, free, "free-", "") ++ rto.class.name(cl)
      do IO<RtP2>:
        o2 : File <- rto.emit(c, id, t, o)
        return RtP2{r, o2, m, j, h, rto.bump2(k, 1n, "out-bytes-" ++ rto.class.name(cl), S.len(t), st), True{}, False{}}

def rto.p2.unit(+c: RtCfg, +free: Bool, +cl: Nat, +hd: Bool, +u: List<&2, U32>, +id: List<&2, U32>, +t: List<&2, U32>, r: S.Rd, o: File, j: Map<&2, Nat>, h: Set(), st: List<&2, Cl.Stat>, y: Map<&2, RtU> & RtU) -> IO(RtP2):
  (m, +x) = y
  +st2 = rto.bump2("in-" ++ rto.class.name(cl), 1n, "in-bytes-" ++ rto.class.name(cl), S.len(t), st)
  rto.p2.act(rto.kind2(c, free, cl, hd, u, id, x), c, free, cl, u, id, t, x, r, o, m, j, h, st2)

def rto.p2.held(+c: RtCfg, +free: Bool, +cl: Nat, +u: List<&2, U32>, +id: List<&2, U32>, +t: List<&2, U32>, r: S.Rd, o: File, m: Map<&2, RtU>, j: Map<&2, Nat>, st: List<&2, Cl.Stat>, x: Set() & Bool) -> IO(RtP2):
  (h, hd) = x
  rto.p2.unit(c, free, cl, hd, u, id, t, r, o, j, h, st, Map.get(RtU, rto.u0(), m, S.str(u)))

def rto.p2.do(+c: RtCfg, +free: Bool, r: S.Rd, o: File, m: Map<&2, RtU>, j: Map<&2, Nat>, h: Set(), st: List<&2, Cl.Stat>, +id: List<&2, U32>, +t: List<&2, U32>) -> IO(RtP2):
  +u = rto.unit(id)
  rto.p2.held(c, free, rto.class(rto.fill(c), id, t), u, id, t, r, o, m, j, st, rto.held(h, u))

def rto.p2.pair(+c: RtCfg, +free: Bool, o: File, m: Map<&2, RtU>, j: Map<&2, Nat>, h: Set(), st: List<&2, Cl.Stat>, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RtP2):
  (r, mt) = x
  match mt:
    case None{}:
      IO.pure(RtP2, RtP2{r, o, m, j, h, st, False{}, True{}})
    case Some{+t}:
      rto.p2.do(c, free, r, o, m, j, h, st, id, t)

def rto.p2.got(+c: RtCfg, +free: Bool, o: File, m: Map<&2, RtU>, j: Map<&2, Nat>, h: Set(), st: List<&2, Cl.Stat>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RtP2):
  (r, mt) = x
  match mt:
    case None{}:
      IO.pure(RtP2, RtP2{r, o, m, j, h, st, False{}, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, RtP2, S.Rd.next(r), rto.p2.pair(c, free, o, m, j, h, st, id))

def rto.p2.step(+c: RtCfg, +free: Bool, s: RtP2) -> IO(RtP2):
  match s:
    case RtP2{r, o, m, j, h, st, g, odd}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, RtP2, S.Rd.next(r), rto.p2.got(c, free, o, m, j, h, st))

def rto.p2.go(fuel: Nat, +c: RtCfg, +free: Bool, s: RtP2) -> IO(RtP2):
  match fuel s:
    case 1n+f RtP2{r, o, m, j, h, st, True{}, odd}:
      IO.bind(RtP2, RtP2, rto.p2.step(c, free, RtP2{r, o, m, j, h, st, True{}, odd}), rto.p2.go(f, c, free))
    case _ s2:
      IO.pure(RtP2, s2)

type RtW is Type:
  RtW{o: File, m: Map<&2, RtU>, j: Map<&2, Nat>, h: Set(), st: List<&2, Cl.Stat>}

def rto.p2.fin(+path: String, s: RtP2) -> IO(RtW):
  match s:
    case RtP2{r, o, m, j, h, st, g, odd}:
      do IO<RtW>:
        S.Rd.close(r)
        rto.odd(path, odd)
        rto.log("pass 2: " ++ path ++ " done")
        return RtW{o, m, j, h, st}

def rto.p2.src(+c: RtCfg, +src: RtSrc, w: RtW) -> IO(RtW):
  match src w:
    case RtSrc{+p, +free} RtW{o, m, j, h, st}:
      do IO<RtW>:
        r : S.Rd <- S.Rd.open(p)
        s : RtP2 <- rto.p2.go(rto.big(), c, free, RtP2{r, o, m, j, h, st, True{}, False{}})
        rto.p2.fin(p, s)

def rto.p2.all(+c: RtCfg, ss: List<&2, RtSrc>, w: RtW) -> IO(RtW):
  match ss:
    case Nil{}:
      IO.pure(RtW, w)
    case +s <> more:
      IO.bind(RtW, RtW, rto.p2.src(c, s, w), rto.p2.all(c, more))

# The units' summary (pure) ------------------------------------------------------------------

def rto.b2n(b: Bool) -> Nat:
  match b:
    case True{}:
      1n
    case False{}:
      0n

# units: seen (not held out), with first-time transcripts, with repairs,
# keeping repairs, whose repairs go for want of a first-time transcript,
# deriving theirs; first-time transcripts they end with
def rto.units.st(+c: RtCfg, us: List<&2, Sigma<&2, &2, String, _ => RtU>>, st: List<&2, Cl.Stat>) -> List<&2, Cl.Stat>:
  match us:
    case Nil{}:
      st
    case (+k, +x) <> more:
      +u = S.b(k)
      +hasf = Nat.is_lt(0n, rto.u.f(x))
      +hasr = Nat.is_lt(0n, rto.u.n(x))
      +kept = rto.kept.n(c, u, x)
      +st1 = rto.bump2("units", 1n, "units-first", rto.b2n(hasf), rto.bump2("units-repair", rto.b2n(hasr), "units-kept", rto.b2n(Nat.is_lt(0n, kept)), st))
      +sh = rto.shared(c, u)
      +st2 = rto.bump2("units-no-first", rto.b2n(Bool.and(Bool.and(hasr, sh), Bool.and(Bool.not(hasf), Nat.is_eq(kept, 0n)))), "units-derived", rto.b2n(Bool.and(Bool.not(hasf), Nat.is_lt(0n, kept))), st1)
      +st3 = rto.bump("units-repair-unshared", rto.b2n(Bool.and(hasr, Bool.not(sh))), st2)
      rto.units.st(c, more, rto.bump2("units-first-final", rto.firsts.n(c, u, x), "units-first-read", rto.u.f(x), st3))

# The audit: the law on a written stream -------------------------------------------------------
#
# Each record's unit is its id's less a copy's /eK and a derived /first;
# then, unit by unit, first-time count >= ratio * repairs and repairs <= cap
# (fill= as the run had it), and no id twice (OUT is in key order, so an id
# twice is two neighbours).

def rto.is.copy(+seg: List<&2, U32>) -> Bool:
  match seg:
    case Nil{}:
      False{}
    case +h <> +t:
      Bool.and(Bool.and(U32.is_eq(h, 101), Bool.not(Nat.is_eq(S.len(t), 0n))), Nat.is_eq(S.len(rto.undigit(t, rto.hd.isd(t))), 0n))

# the id a copy or a derived transcript came from
def rto.base(+id: List<&2, U32>) -> List<&2, U32>:
  +a = Bool.pick(List<&2, U32>, rto.is.copy(rto.seg(id)), rto.stem(id), id)
  Bool.pick(List<&2, U32>, S.eq(rto.seg(a), S.b("first")), rto.stem(a), a)

type RtAu is Type:
  RtAu{r: S.Rd, m: Map<&2, RtU>, prev: List<&2, U32>, recs: Nat, dups: Nat, more: Bool}

def rto.au.upd(+cl: Nat, x: RtU) -> RtU:
  match x:
    case RtU{+f, +n, b}:
      RtU{Nat.add(f, rto.b2n(Nat.is_eq(cl, 0n))), Nat.add(n, rto.b2n(Nat.is_eq(cl, 1n))), b}

def rto.au.got(+cl: Nat, +u: List<&2, U32>, y: Map<&2, RtU> & RtU) -> Map<&2, RtU>:
  (m, x) = y
  Map.set(&2, RtU, m, S.str(u), rto.au.upd(cl, x))

def rto.au.rec(+fill: Bool, r: S.Rd, m: Map<&2, RtU>, +prev: List<&2, U32>, +n: Nat, +d: Nat, +id: List<&2, U32>, +t: List<&2, U32>) -> RtAu:
  +b = rto.base(id)
  +u = rto.unit(b)
  RtAu{r, rto.au.got(rto.class(fill, b, t), u, Map.get(RtU, rto.u0(), m, S.str(u))), id, 1n+n, Nat.add(d, rto.b2n(S.eq(id, prev))), True{}}

def rto.au.pair(+fill: Bool, m: Map<&2, RtU>, +prev: List<&2, U32>, +n: Nat, +d: Nat, +id: List<&2, U32>, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RtAu):
  (r, mt) = x
  match mt:
    case None{}:
      IO.die(RtAu, 1, "repair-mix audit: an id without its text")
    case Some{+t}:
      IO.pure(RtAu, rto.au.rec(fill, r, m, prev, n, d, id, t))

def rto.au.got1(+fill: Bool, m: Map<&2, RtU>, +prev: List<&2, U32>, +n: Nat, +d: Nat, x: S.Rd & Maybe<&2, List<&2, U32>>) -> IO(RtAu):
  (r, mt) = x
  match mt:
    case None{}:
      IO.pure(RtAu, RtAu{r, m, prev, n, d, False{}})
    case Some{+id}:
      IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, RtAu, S.Rd.next(r), rto.au.pair(fill, m, prev, n, d, id))

def rto.au.go(fuel: Nat, +fill: Bool, s: RtAu) -> IO(RtAu):
  match fuel s:
    case 1n+f RtAu{r, m, +p, +n, +d, True{}}:
      IO.bind(RtAu, RtAu, IO.bind(S.Rd & Maybe<&2, List<&2, U32>>, RtAu, S.Rd.next(r), rto.au.got1(fill, m, p, n, d)), rto.au.go(f, fill))
    case _ s2:
      IO.pure(RtAu, s2)

# the units that break the law
def rto.au.bad(+ratio: Nat, +cap: Nat, us: List<&2, Sigma<&2, &2, String, _ => RtU>>, +acc: Nat) -> Nat:
  match us:
    case Nil{}:
      acc
    case (k, +x) <> more:
      +ok = Bool.and(Nat.is_le(Nat.mul(ratio, rto.u.n(x)), rto.u.f(x)), Nat.is_le(rto.u.n(x), cap))
      rto.au.bad(ratio, cap, more, Nat.add(acc, rto.b2n(Bool.not(ok))))

# (records, units, units breaking the law, ids twice, first-time, repairs)
type RtAud is Data:
  RtAud{recs: Nat, units: Nat, bad: Nat, dups: Nat, firsts: Nat, reps: Nat}

def rto.au.sum(us: List<&2, Sigma<&2, &2, String, _ => RtU>>, +f: Nat, +n: Nat) -> Nat & Nat:
  match us:
    case Nil{}:
      (f, n)
    case (k, +x) <> more:
      rto.au.sum(more, Nat.add(f, rto.u.f(x)), Nat.add(n, rto.u.n(x)))

def rto.au.mk(+recs: Nat, +dups: Nat, +units: Nat, +bad: Nat, fr: Nat & Nat) -> RtAud:
  (f, n) = fr
  RtAud{recs, units, bad, dups, f, n}

def rto.au.fin(+ratio: Nat, +cap: Nat, s: RtAu) -> IO(RtAud):
  match s:
    case RtAu{r, m, p, +n, +d, g}:
      +us = Map.to_list(&2, RtU, m)
      do IO<RtAud>:
        S.Rd.close(r)
        return rto.au.mk(n, d, List.length(&2, Sigma<&2, &2, String, _ => RtU>, us), rto.au.bad(ratio, cap, us, 0n), rto.au.sum(us, 0n, 0n))

def rto.audit(+fill: Bool, +ratio: Nat, +cap: Nat, +path: String) -> IO(RtAud):
  do IO<RtAud>:
    r : S.Rd <- S.Rd.open(path)
    s : RtAu <- rto.au.go(rto.big(), fill, RtAu{r, Map.new(&2, RtU), [0], 0n, 0n, True{}})
    rto.au.fin(ratio, cap, s)

def rto.aud.show(+a: RtAud) -> String:
  match a:
    case RtAud{+n, +u, +b, +d, +f, +k}:
      Nat.show(n) ++ " records, " ++ Nat.show(u) ++ " units, " ++ Nat.show(f) ++ " first-time, " ++ Nat.show(k) ++ " repairs; " ++
        Nat.show(b) ++ " units break first >= ratio * repairs or repairs <= cap; " ++ Nat.show(d) ++ " ids twice"

def rto.aud.ok(+a: RtAud) -> Bool:
  match a:
    case RtAud{n, u, b, d, f, k}:
      Bool.and(Nat.is_eq(b, 0n), Nat.is_eq(d, 0n))

# The command ------------------------------------------------------------------------------------

type RtArgs is Data:
  RtArgs{srcs: List<&2, RtSrc>, held: List<&2, String>, cfg: RtCfg, bad: List<&2, String>}

def rto.cfg.nat(+which: Nat, m: Maybe<&2, Nat>, +c: RtCfg) -> Maybe<&2, RtCfg>:
  match m c:
    case Some{+k} RtCfg{+r, +p, +s, +f, +d, +y, +q}:
      Bool.pick(Maybe<&2, RtCfg>, Bool.and(Nat.is_eq(which, 0n), Nat.is_lt(0n, k)), Some{RtCfg{k, p, s, f, d, y, q}},
        Bool.pick(Maybe<&2, RtCfg>, Bool.and(Nat.is_eq(which, 1n), Nat.is_lt(0n, k)), Some{RtCfg{r, k, s, f, d, y, q}},
          Bool.pick(Maybe<&2, RtCfg>, Bool.and(Nat.is_eq(which, 2n), Bool.and(Nat.is_lt(0n, k), Nat.is_le(k, 100n))), Some{RtCfg{r, p, s, f, d, y, k}}, None{})))
    case _ _:
      None{}

def rto.cfg.word(+x: List<&2, U32>, +c: RtCfg) -> Maybe<&2, RtCfg>:
  match c:
    case RtCfg{+r, +p, +s, +f, +d, +y, +q}:
      +v = L.v2.after(x, 61)
      +key = L.v2.before(x, 61)
      Bool.pick(Maybe<&2, RtCfg>, S.eq(x, S.b("dry")), Some{RtCfg{r, p, s, f, d, True{}, q}},
      Bool.pick(Maybe<&2, RtCfg>, S.eq(key, S.b("ratio")), rto.cfg.nat(0n, Nat.read(S.str(v)), c),
      Bool.pick(Maybe<&2, RtCfg>, S.eq(key, S.b("cap")), rto.cfg.nat(1n, Nat.read(S.str(v)), c),
      Bool.pick(Maybe<&2, RtCfg>, S.eq(key, S.b("share")), rto.cfg.nat(2n, Nat.read(S.str(v)), c),
      Bool.pick(Maybe<&2, RtCfg>, Bool.and(S.eq(key, S.b("salt")), L.v2.has(x, 61)), Some{RtCfg{r, p, v, f, d, y, q}},
      Bool.pick(Maybe<&2, RtCfg>, S.eq(x, S.b("fill=repair")), Some{RtCfg{r, p, s, True{}, d, y, q}},
      Bool.pick(Maybe<&2, RtCfg>, S.eq(x, S.b("fill=other")), Some{RtCfg{r, p, s, False{}, d, y, q}},
      Bool.pick(Maybe<&2, RtCfg>, S.eq(x, S.b("derive=none")), Some{RtCfg{r, p, s, f, 0n, y, q}},
      Bool.pick(Maybe<&2, RtCfg>, S.eq(x, S.b("derive=whole")), Some{RtCfg{r, p, s, f, 1n, y, q}},
      Bool.pick(Maybe<&2, RtCfg>, S.eq(x, S.b("derive=all")), Some{RtCfg{r, p, s, f, 2n, y, q}}, None{}))))))))))

def rto.args.cfg(m: Maybe<&2, RtCfg>, +w: String, +ss: List<&2, RtSrc>, +hs: List<&2, String>, +c: RtCfg, +bad: List<&2, String>) -> RtArgs:
  match m:
    case Some{c2}:
      RtArgs{ss, hs, c2, bad}
    case None{}:
      RtArgs{ss, hs, c, w <> bad}

def rto.args.one(+w: String, a: RtArgs) -> RtArgs:
  match a:
    case RtArgs{+ss, +hs, +c, +bad}:
      +x = S.b(w)
      Bool.pick(RtArgs, S.prefix(x, S.b("in=")), RtArgs{RtSrc{S.str(List.drop(&2, U32, x, 3n)), False{}} <> ss, hs, c, bad},
      Bool.pick(RtArgs, S.prefix(x, S.b("free=")), RtArgs{RtSrc{S.str(List.drop(&2, U32, x, 5n)), True{}} <> ss, hs, c, bad},
      Bool.pick(RtArgs, S.prefix(x, S.b("held=")), RtArgs{ss, S.str(List.drop(&2, U32, x, 5n)) <> hs, c, bad},
        rto.args.cfg(rto.cfg.word(x, c), w, ss, hs, c, bad))))

# the words, sources and held files in the order given
def rto.args(ws: List<String>) -> RtArgs:
  match ws:
    case Nil{}:
      RtArgs{Nil{}, Nil{}, rto.cfg0(), Nil{}}
    case +w <> more:
      rto.args.one(w, rto.args(more))

def rto.any.free(ss: List<&2, RtSrc>) -> Bool:
  match ss:
    case Nil{}:
      False{}
    case RtSrc{p, +f} <> more:
      Bool.or(f, rto.any.free(more))

def rto.srcs.show(ss: List<&2, RtSrc>) -> String:
  match ss:
    case Nil{}:
      ""
    case RtSrc{+p, +f} <> more:
      " " ++ Bool.pick(String, f, "free=", "in=") ++ p ++ rto.srcs.show(more)

def rto.strs(xs: List<&2, String>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> more:
      " " ++ x ++ rto.strs(more)

def rto.usage() -> String:
  "usage: bend-corpus-v2 repair-mix OUT WORD...   (in=FILE free=FILE held=FILE ratio=N cap=N share=P salt=S fill=other|repair derive=none|whole|all dry; bend/CorpusV2/Ratio.bend)"

# the written stream audited, unless a free source makes the law moot
def rto.audit.if(go: Bool, +c: RtCfg, +out: String) -> IO(Unit):
  match go:
    case False{}:
      rto.log("audit: skipped (dry, or a free= source passes repairs the rule does not count)")
    case True{}:
      do IO<Unit>:
        +a : RtAud <- rto.audit(rto.fill(c), rto.ratio(c), rto.cap(c), out)
        rto.log("audit: " ++ rto.aud.show(a))
        Bool.pick(IO(Unit), rto.aud.ok(a), IO.pure(Unit, Unit{}), IO.die(Unit, 1, "repair-mix: the audit failed: " ++ rto.aud.show(a)))

def rto.write.if(dry: Bool, +out: String, +spool: String) -> IO(Unit):
  match dry:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      +sorted = out ++ ".rto-sorted"
      do IO<Unit>:
        K.kor.sort(False{}, K.kor.dir(out), spool, sorted)
        S.rm(spool)
        +n : Nat <- K.kor.back(False{}, sorted, out, rto.big())
        S.rm(sorted)
        rto.log(out ++ ": " ++ Nat.show(n) ++ " transcripts, in key order")

def rto.fin(+out: String, +c: RtCfg, +ss: List<&2, RtSrc>, +spool: String, w: RtW) -> IO(List<&2, Cl.Stat>):
  match w:
    case RtW{o, m, j, h, st}:
      +st2 = rto.units.st(c, Map.to_list(&2, RtU, m), st)
      do IO<List<&2, Cl.Stat>>:
        File.close(o)
        S.write(out ++ ".stats", S.b(Cl.stat.show(st2)))
        rto.write.if(rto.dry(c), out, spool)
        rto.audit.if(Bool.and(Bool.not(rto.dry(c)), Bool.not(rto.any.free(ss))), c, out)
        return st2

def rto.w0(o: File, mh: RtMH) -> RtW:
  match mh:
    case RtMH{m, h}:
      RtW{o, m, Map.new(&2, Nat), h, Nil{}}

# the whole run; the answer is the stats
def rto.go(+out: String, +ss: List<&2, RtSrc>, +hs: List<&2, String>, +c: RtCfg) -> IO(List<&2, Cl.Stat>):
  +spool = Bool.pick(String, rto.dry(c), "/dev/null", out ++ ".rto-spool")
  do IO<List<&2, Cl.Stat>>:
    rto.log(out ++ ":" ++ rto.srcs.show(ss) ++ "; held" ++ rto.strs(hs) ++ "; " ++ rto.cfg.show(c))
    h : Set() <- rto.held.load(hs, Set.new())
    mh : RtMH <- rto.p1.all(c, ss, RtMH{Map.new(&2, RtU), h})
    o : File <- IO.try(File, File.open(spool, "w"))
    w : RtW <- rto.p2.all(c, ss, rto.w0(o, mh))
    rto.fin(out, c, ss, spool, w)

def rto.say(st: List<&2, Cl.Stat>) -> IO(Unit):
  IO.print(Cl.stat.show(st))

def rto.main.of(+out: String, a: RtArgs) -> IO(Unit):
  match a:
    case RtArgs{+ss, +hs, +c, +bad}:
      Bool.pick(IO(Unit), Bool.not(List.is_empty(&2, String, bad)), IO.die(Unit, 2, "repair-mix: not understood:" ++ rto.strs(bad) ++ "\n" ++ rto.usage()),
        Bool.pick(IO(Unit), List.is_empty(&2, RtSrc, ss), IO.die(Unit, 2, "repair-mix: no in= or free= source\n" ++ rto.usage()),
          IO.bind(List<&2, Cl.Stat>, Unit, rto.go(out, ss, hs, c), rto.say)))

def rto.main(xs: List<String>) -> IO(Unit):
  match xs:
    case +out <> more:
      rto.main.of(out, rto.args(more))
    case _:
      IO.die(Unit, 2, rto.usage())
