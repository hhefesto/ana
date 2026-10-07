import Base
import ../Sys.bend as S
import ./Spec.bend as A
import ./Episode.bend as E

# bend-episode: Agent/Episode.bend's log from the shell.
#
#   bend-episode text LOG     each record's text (the episode as ana read it), each followed by NUL
#   bend-episode why LOG K    a line a record: N END WHY TRIES CALLS (WHY `ok`, or why the record
#                             is not a training episode under at most K calls)
#   bend-episode accept K CAP OUT LOG...   the episodes that train, at most CAP a unit, as
#                             each language's transcripts (below)
#
# A log that does not read (not a log, or a record cut short) exits 1.

def et.texts(rs: List<&2, E.EpRec>) -> List<&2, U32>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      List.concat(&2, U32, [E.ep.text(E.EpRec.segs(r)), [0], et.texts(t)])

def et.why.line(+i: Nat, +k: Nat, +r: E.EpRec) -> String:
  +ss = E.EpRec.segs(r)
  +w = E.ep.why(ss, k)
  Nat.show(i) ++ " " ++ S.str(E.EpRec.end(r)) ++ " " ++ Bool.pick(String, String.is_empty(w), "ok", w) ++ " "
    ++ Nat.show(E.ep.tries(ss)) ++ " " ++ Nat.show(E.ep.calls(ss))

def et.whys(rs: List<&2, E.EpRec>, +i: Nat, +k: Nat) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case +r <> t:
      do IO<Unit>:
        IO.print(et.why.line(i, k, r))
        et.whys(t, 1n+i, k)

def et.with(mode: Nat, +k: Nat, m: Maybe<&2, List<&2, E.EpRec>>) -> IO(Unit):
  match mode m:
    case _ None{}:
      IO.die(Unit, 1, "bend-episode: not a log, or a record is cut short")
    case 0n Some{rs}:
      IO.write(S.str(et.texts(rs)))
    case _ Some{rs}:
      et.whys(rs, 0n, k)

# Accepting episodes for training -------------------------------------------------
#
#   bend-episode accept K CAP OUT LOG...
#
# An episode trains when its grammar holds under at most K calls
# (Episode.bend `ep.why`) and its answer has no escape hatch (Haskell
# `undefined`; Lean `sorry`, `admit`; Agda `postulate`, `{!`, `TERMINATING`,
# `trustMe`: the checker passes them, the task is not done); at most CAP a
# unit, those that fixed a rejected term (a try or more) first, then in log
# order. OUT/LANG-act/transcripts.train.nul gets each of LANG's (haskell,
# agda, lean, nix, bend; its metadata's lang) as `UNIT/episode-N\0TEXT\0` (N
# the job, its metadata's n), TEXT the episode as ana read it: a format-2
# transcript a tool's answers run through, rendered by the reader the
# trainer masks with. OUT/LANG-act is a language for bend-plan-windows (its
# filler files, holdout links: the caller's). The counts by reason go to
# standard output.

def et.meta.go(ls: List<&2, List<&2, U32>>, +p: List<&2, U32>) -> List<&2, U32>:
  match ls:
    case Nil{}:
      Nil{}
    case +l <> t:
      Bool.pick(List<&2, U32>, S.prefix(l, p), List.drop(&2, U32, l, S.len(p)), et.meta.go(t, p))

# the metadata's value for KEY ("" when it has none)
def et.meta(+m: List<&2, U32>, +key: String) -> List<&2, U32>:
  et.meta.go(S.split.lines(m), S.b(key ++ "="))

def et.has(+xs: List<&2, U32>, +s: String) -> Bool:
  S.infix(xs, S.b(s))

def et.hatch(+lang: List<&2, U32>, +code: List<&2, U32>) -> Bool:
  Bool.pick(Bool, S.eq(lang, S.b("haskell")), et.has(code, "undefined"),
    Bool.pick(Bool, S.eq(lang, S.b("lean")), Bool.or(et.has(code, "sorry"), et.has(code, "admit")),
      Bool.pick(Bool, S.eq(lang, S.b("agda")), Bool.or(Bool.or(et.has(code, "postulate"), et.has(code, "{!")), Bool.or(et.has(code, "TERMINATING"), et.has(code, "trustMe"))),
        False{})))

# a record's verdict: "" it trains, else why not
def et.verdict(+k: Nat, +r: E.EpRec) -> String:
  +ss = E.EpRec.segs(r)
  +w = E.ep.why(ss, k)
  +code = A.ag.answer.code(E.ep.turns(ss))
  Bool.pick(String, String.is_empty(w), Bool.pick(String, et.hatch(et.meta(E.EpRec.meta(r), "lang"), code), "hatch", ""), w)

type EtC is Data:
  EtC{why: String, n: Nat}

def et.bump(cs: List<&2, EtC>, +w: String) -> List<&2, EtC>:
  match cs:
    case Nil{}:
      [EtC{w, 1n}]
    case EtC{+x, +n} <> +t:
      Bool.pick(List<&2, EtC>, String.eq(x, w), EtC{x, 1n+n} <> t, EtC{x, n} <> et.bump(t, w))

def et.counts(cs: List<&2, EtC>) -> String:
  match cs:
    case Nil{}:
      ""
    case EtC{+x, n} <> t:
      " " ++ Bool.pick(String, String.is_empty(x), "ok", x) ++ " " ++ Nat.show(n) ++ et.counts(t)

# the accepted so far: the output's records (newest first), the units' slots
# taken (UNIT TAB 1, UNIT TAB 2), how many
type EtA is Type:
  EtA{out: List<&2, List<&2, U32>>, seen: Set(), n: Nat}

def et.slot(+had1: Bool, +key1: String, +key2: String) -> String:
  Bool.pick(String, had1, key2, key1)

def et.put(room: Bool, +key: String, +doc: List<&2, U32>, o: List<&2, List<&2, U32>>, s: Set(), +n: Nat) -> EtA:
  match room:
    case True{}:
      EtA{doc <> o, Set.add(s, key), 1n+n}
    case False{}:
      EtA{o, s, n}

def et.room2(+key1: String, +key2: String, +had1: Bool, +doc: List<&2, U32>, +cap: Nat, o: List<&2, List<&2, U32>>, +n: Nat, r: Set() & Bool) -> EtA:
  (s, had2) = r
  +room = Bool.not(Bool.or(Bool.and(had1, had2), Bool.or(Nat.is_eq(cap, 0n), Bool.and(had1, Nat.is_lt(cap, 2n)))))
  et.put(room, et.slot(had1, key1, key2), doc, o, s, n)

def et.room1(+key1: String, +key2: String, +doc: List<&2, U32>, +cap: Nat, o: List<&2, List<&2, U32>>, +n: Nat, r: Set() & Bool) -> EtA:
  (s, had1) = r
  et.room2(key1, key2, had1, doc, cap, o, n, Set.has(s, key2))

def et.take.if(ok: Bool, +unit: String, +doc: List<&2, U32>, +cap: Nat, a: EtA) -> EtA:
  match ok a:
    case True{} EtA{o, s, +n}:
      et.room1(unit ++ "\t1", unit ++ "\t2", doc, cap, o, n, Set.has(s, unit ++ "\t1"))
    case False{} EtA{o, s, n}:
      EtA{o, s, n}

def et.doc(+m: List<&2, U32>, +r: E.EpRec) -> List<&2, U32>:
  List.concat(&2, U32, [et.meta(m, "unit"), S.b("/episode-"), et.meta(m, "n"), [0], E.ep.text(E.EpRec.segs(r)), [0]])

# one record into the accepted, when it trains, is of this pass (tried or
# not) and its unit has room (a cap of 1 or 2)
def et.take(+k: Nat, +cap: Nat, +tried: Bool, +r: E.EpRec, a: EtA) -> EtA:
  +m = E.EpRec.meta(r)
  +mine = Bool.not(Bool.xor(Nat.is_lt(0n, E.ep.tries(E.EpRec.segs(r))), tried))
  et.take.if(Bool.and(mine, String.is_empty(et.verdict(k, r))), S.str(et.meta(m, "unit")), et.doc(m, r), cap, a)

def et.pass(rs: List<&2, E.EpRec>, +k: Nat, +cap: Nat, +tried: Bool, a: EtA) -> EtA:
  match rs:
    case Nil{}:
      a
    case +r <> t:
      et.pass(t, k, cap, tried, et.take(k, cap, tried, r, a))

def et.why.all(rs: List<&2, E.EpRec>, +k: Nat, cs: List<&2, EtC>) -> List<&2, EtC>:
  match rs:
    case Nil{}:
      cs
    case +r <> t:
      et.why.all(t, k, et.bump(cs, et.verdict(k, r)))

def et.keep(on: Bool, +r: E.EpRec, t: List<&2, E.EpRec>) -> List<&2, E.EpRec>:
  match on:
    case True{}:
      r <> t
    case False{}:
      t

# the records of language L (a unit is of one language, so a unit's cap is
# the same within its language)
def et.lang.of(+l: List<&2, U32>, rs: List<&2, E.EpRec>) -> List<&2, E.EpRec>:
  match rs:
    case Nil{}:
      Nil{}
    case +r <> t:
      et.keep(S.eq(et.meta(E.EpRec.meta(r), "lang"), l), r, et.lang.of(l, t))

def et.langs() -> List<&2, String>:
  ["haskell", "agda", "lean", "nix", "bend"]

def et.accept.put(+dir: String, +l: String, a: EtA) -> IO(Nat):
  match a:
    case EtA{o, s, +n}:
      do IO<Nat>:
        S.mkdir(dir)
        S.write(dir ++ "/transcripts.train.nul", List.concat(&2, U32, List.reverse(&2, List<&2, U32>, o)))
        IO.print("accept: " ++ l ++ " " ++ Nat.show(n) ++ " into " ++ dir ++ "/transcripts.train.nul")
        return n

def et.accept.one(+out: String, +k: Nat, +cap: Nat, +l: String, +rs: List<&2, E.EpRec>) -> IO(Nat):
  +mine = et.lang.of(S.b(l), rs)
  et.accept.put(out ++ "/" ++ l ++ "-act", l, et.pass(mine, k, cap, False{}, et.pass(mine, k, cap, True{}, EtA{Nil{}, Set.new(), 0n})))

def et.accept.all(ls: List<&2, String>, +out: String, +k: Nat, +cap: Nat, +rs: List<&2, E.EpRec>, +n: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, n)
    case l <> t:
      do IO<Nat>:
        m : Nat <- et.accept.one(out, k, cap, l, rs)
        et.accept.all(t, out, k, cap, rs, Nat.add(n, m))

def et.got(+p: String, m: Maybe<&2, List<&2, E.EpRec>>) -> IO(List<&2, E.EpRec>):
  match m:
    case Some{rs}:
      IO.pure(List<&2, E.EpRec>, rs)
    case None{}:
      IO.die(List<&2, E.EpRec>, 1, "bend-episode: " ++ p ++ " is not a log, or a record is cut short")

def et.logs(ps: List<String>, acc: List<&2, E.EpRec>) -> IO(List<&2, E.EpRec>):
  match ps:
    case Nil{}:
      IO.pure(List<&2, E.EpRec>, acc)
    case +p <> t:
      do IO<List<&2, E.EpRec>>:
        xs : List<&2, U32> <- S.read(p)
        rs : List<&2, E.EpRec> <- et.got(p, E.ep.get(xs))
        et.logs(t, List.append(&2, E.EpRec, acc, rs))

def et.accept(+k: Nat, +cap: Nat, +out: String, ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +rs : List<&2, E.EpRec> <- et.logs(ps, Nil{})
    n : Nat <- et.accept.all(et.langs(), out, k, cap, rs, 0n)
    IO.print("accept: " ++ Nat.show(List.length(&2, E.EpRec, rs)) ++ " episodes;" ++ et.counts(et.why.all(rs, k, Nil{}))
      ++ "; " ++ Nat.show(n) ++ " accepted (at most the cap a unit, tried first) into " ++ out ++ "/LANG-act")

def et.read(+mode: Nat, +k: Nat, +path: String) -> IO(Unit):
  do IO<Unit>:
    xs : List<&2, U32> <- S.read(path)
    et.with(mode, k, E.ep.get(xs))

def et.args(xs: List<String>) -> IO(Unit):
  match xs:
    case "text" <> +path <> Nil{}:
      et.read(0n, 0n, path)
    case "why" <> +path <> +k <> Nil{}:
      et.read(1n, S.env.nat.got(Nat.read(k), 4n), path)
    case "accept" <> +k <> +cap <> +out <> logs:
      et.accept(S.env.nat.got(Nat.read(k), 4n), S.env.nat.got(Nat.read(cap), 2n), out, logs)
    case _:
      IO.die(Unit, 2, "usage: bend-episode text LOG | why LOG K | accept K CAP OUT LOG...")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    et.args(List.tail(&1, String, argv))
