import Base
import ../Sys.bend as S
import ./Spec.bend as A
import ./Episode.bend as E
import ../Transcript.bend as Tr
import ../Tokenizer.bend as Tk
import ../CorpusV2/Eval.bend as Ev

# bend-episode: Agent/Episode.bend's log from the shell.
#
#   bend-episode text LOG     each record's text (the episode as ana read it), each followed by NUL
#   bend-episode why LOG K    a line a record: N END WHY TRIES CALLS (WHY `ok`, or why the record
#                             is not a training episode under at most K calls)
#   bend-episode accept K CAP OUT LOG...   the episodes that train, at most CAP a unit, as
#                             each language's transcripts (below)
#   bend-episode fixed K CAP OUT LOG...    the unsolved ones with the unit's own fix (below)
#
# A log that does not read (not a log, or a record cut short) exits 1.
#
# Every transcript accept and fixed write fits a window, bend-transcript's law
# (Transcript.bend `fits`): its tokens under TOKENIZER (weights/code32k.bpe),
# plus BOS and EOS, within WINDOW - 64 (WINDOW 2048). One that does not is
# left out, never cut (2026-10-13: run 3's act round 1 gave 106 over the
# window, up to 23,333 tokens, and bend-windows refuses them).

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
# `trustMe`: the checker passes them, the task is not done) and it fits the
# window (else its reason is long, and it takes no slot); at most CAP a
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

# the window's law: the tokenizer and the limit (WINDOW - 64)
type EtW is Data:
  EtW{bpe: Tk.Bpe, lim: Nat}

def et.fits(+w: EtW, +text: List<&2, U32>) -> Bool:
  match w:
    case EtW{b, lim}:
      Tr.fits(b, lim, text)

# a grammatical record's verdict: hatch, long (over the window), or "" (it
# trains); a match, so only those are encoded
def et.verdict.if(ok: Bool, +w: String, +win: EtW, +lang: List<&2, U32>, +code: List<&2, U32>, +text: List<&2, U32>) -> String:
  match ok:
    case True{}:
      Bool.pick(String, et.hatch(lang, code), "hatch", Bool.pick(String, et.fits(win, text), "", "long"))
    case False{}:
      w

# a record's verdict: "" it trains, else why not
def et.verdict(+win: EtW, +k: Nat, +r: E.EpRec) -> String:
  +ss = E.EpRec.segs(r)
  +w = E.ep.why(ss, k)
  +code = A.ag.answer.code(E.ep.turns(ss))
  et.verdict.if(String.is_empty(w), w, win, et.meta(E.EpRec.meta(r), "lang"), code, E.ep.text(ss))

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
def et.take(+win: EtW, +k: Nat, +cap: Nat, +tried: Bool, +r: E.EpRec, a: EtA) -> EtA:
  +m = E.EpRec.meta(r)
  +mine = Bool.not(Bool.xor(Nat.is_lt(0n, E.ep.tries(E.EpRec.segs(r))), tried))
  et.take.if(Bool.and(mine, String.is_empty(et.verdict(win, k, r))), S.str(et.meta(m, "unit")), et.doc(m, r), cap, a)

def et.pass(rs: List<&2, E.EpRec>, +win: EtW, +k: Nat, +cap: Nat, +tried: Bool, a: EtA) -> EtA:
  match rs:
    case Nil{}:
      a
    case +r <> t:
      et.pass(t, win, k, cap, tried, et.take(win, k, cap, tried, r, a))

def et.why.all(rs: List<&2, E.EpRec>, +win: EtW, +k: Nat, cs: List<&2, EtC>) -> List<&2, EtC>:
  match rs:
    case Nil{}:
      cs
    case +r <> t:
      et.why.all(t, win, k, et.bump(cs, et.verdict(win, k, r)))

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

def et.accept.one(+out: String, +win: EtW, +k: Nat, +cap: Nat, +l: String, +rs: List<&2, E.EpRec>) -> IO(Nat):
  +mine = et.lang.of(S.b(l), rs)
  et.accept.put(out ++ "/" ++ l ++ "-act", l, et.pass(mine, win, k, cap, False{}, et.pass(mine, win, k, cap, True{}, EtA{Nil{}, Set.new(), 0n})))

def et.accept.all(ls: List<&2, String>, +out: String, +win: EtW, +k: Nat, +cap: Nat, +rs: List<&2, E.EpRec>, +n: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, n)
    case l <> t:
      do IO<Nat>:
        m : Nat <- et.accept.one(out, win, k, cap, l, rs)
        et.accept.all(t, out, win, k, cap, rs, Nat.add(n, m))

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

def et.win.of(+tok: String, +lim: Nat, m: Maybe<&2, Tk.Bpe>) -> IO(EtW):
  match m:
    case Some{b}:
      IO.pure(EtW, EtW{b, lim})
    case None{}:
      IO.die(EtW, 1, "bend-episode: the tokenizer " ++ tok ++ " does not parse")

# the window's law from TOKENIZER and WINDOW
def et.win() -> IO(EtW):
  do IO<EtW>:
    +tok : String <- S.env("TOKENIZER", "weights/code32k.bpe")
    +w : Nat <- S.env.nat("WINDOW", 2048n)
    tx : List<&2, U32> <- S.read(tok)
    et.win.of(tok, Nat.sub(w, 64n), Tk.Bpe.parse(tx))

def et.accept(+k: Nat, +cap: Nat, +out: String, ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +win : EtW <- et.win()
    +rs : List<&2, E.EpRec> <- et.logs(ps, Nil{})
    n : Nat <- et.accept.all(et.langs(), out, win, k, cap, rs, 0n)
    IO.print("accept: " ++ Nat.show(List.length(&2, E.EpRec, rs)) ++ " episodes;" ++ et.counts(et.why.all(rs, win, k, Nil{}))
      ++ "; " ++ Nat.show(n) ++ " accepted (at most the cap a unit, tried first) into " ++ out ++ "/LANG-act")

# Fixed episodes ------------------------------------------------------------------
#
#   bend-episode fixed K CAP OUT LOG...
#
# ana's unsolved episodes as training episodes with the unit's own fix (the
# user's choice, 2026-10-07: ana fixes too few of its own errors to learn
# from): the prompt, ana's first j rejected Terms and the checker's real
# answers to them (the tries, weight 0), then the unit's original Term and
# the checker's pass on it (the act). The fix is rendered as format 2
# renders it (Transcript.bend `term`, `check.turn`: the chains' last turns)
# and split as the tool loop splits a turn: ana's segment ends with the
# call's heading line (`## ghc`), the tool's holds the rest. j is the
# largest, at most K - 1 and the calls made, under which the whole is a
# training episode (`ep.why`: a changed heading ends the tries; a copy is a
# try like any other) and that fits the window. A solved episode, one with
# no checked Term, one whose unit's original has an escape hatch, or one
# over the window at every j gives none; at most CAP a unit,
# in log order. The records are run/v2/results/LANG.R.nul, R AGENT_RECORDS
# (holdout unless set; agent-act.sh: train), read for the log's units only.
# OUT/LANG-fix/transcripts.train.nul gets each of LANG's as
# `UNIT/fixed-N\0TEXT\0` (N its job).

def et.fx.next(tool: Bool, +p: Nat) -> Nat:
  match tool:
    case True{}:
      p
    case False{}:
      1n+p

# the segments up to and including the j-th tool turn
def et.fx.upto(ss: List<&2, E.EpSeg>, j: Nat) -> List<&2, E.EpSeg>:
  match ss j:
    case _ 0n:
      Nil{}
    case Nil{} _:
      Nil{}
    case +s <> t 1n+p:
      s <> et.fx.upto(t, et.fx.next(Nat.is_eq(E.ep.seg.who(s), 2n), p))

# a text's first line, its newline included
def et.fx.line1(xs: List<&2, U32>) -> List<&2, U32>:
  match xs:
    case Nil{}:
      Nil{}
    case +c <> t:
      c <> Bool.pick(List<&2, U32>, U32.is_eq(c, 10), Nil{}, et.fx.line1(t))

# the unit's fix as the tool loop splits it: ana's Term and the call's
# heading line, then the tool's answer
def et.fx.fix(+fs: List<&2, List<&2, U32>>) -> List<&2, E.EpSeg>:
  +c = Tr.check.turn(fs, Tr.field(fs, 11n))
  +h = et.fx.line1(c)
  [E.EpSeg{1n, Nil{}, 0, List.concat(&2, U32, [Tr.term(fs, Tr.field(fs, 7n)), h])},
   E.EpSeg{2n, Tr.tool(Tr.field(fs, 0n)), 0, List.drop(&2, U32, c, List.length(&2, U32, h))}]

def et.fx.or(ok: Bool, e: List<&2, E.EpSeg>, rest: Maybe<&2, List<&2, E.EpSeg>>) -> Maybe<&2, List<&2, E.EpSeg>>:
  match ok:
    case True{}:
      Some{e}
    case False{}:
      rest

# a training episode that fits the window (a match, so only those are encoded)
def et.fx.fits(ok: Bool, +win: EtW, +e: List<&2, E.EpSeg>) -> Bool:
  match ok:
    case True{}:
      et.fits(win, E.ep.text(e))
    case False{}:
      False{}

# the episode with the most tries, j at most, that trains and fits the window
def et.fx.best(+win: EtW, +j: Nat, +ss: List<&2, E.EpSeg>, +fix: List<&2, E.EpSeg>, +k: Nat) -> Maybe<&2, List<&2, E.EpSeg>>:
  match j:
    case 0n:
      None{}
    case 1n+p:
      +e = List.append(&2, E.EpSeg, et.fx.upto(ss, j), fix)
      et.fx.or(et.fx.fits(E.ep.ok(e, k), win, e), e, et.fx.best(win, p, ss, fix, k))

def et.fx.make.if(none: Bool, +win: EtW, +k: Nat, +ss: List<&2, E.EpSeg>, +fs: List<&2, List<&2, U32>>) -> Maybe<&2, List<&2, E.EpSeg>>:
  match none:
    case True{}:
      None{}
    case False{}:
      et.fx.best(win, Nat.min(E.ep.calls(ss), Nat.sub(k, 1n)), ss, et.fx.fix(fs), k)

# a record's fixed episode, when it gives one (t: its unit's record)
def et.fx.make(+win: EtW, +k: Nat, +r: E.EpRec, +t: List<&2, U32>) -> Maybe<&2, List<&2, E.EpSeg>>:
  +ss = E.EpRec.segs(r)
  +fs = Tr.split(t, 30)
  +lang = et.meta(E.EpRec.meta(r), "lang")
  et.fx.make.if(Bool.or(Bool.or(E.ep.solved(ss), List.is_empty(&2, U32, t)), et.hatch(lang, Tr.field(fs, 7n))), win, k, ss, fs)

# the grammar's reason, or long when the grammar holds (with no episode, the
# window is why)
def et.fx.long(+w: String) -> String:
  Bool.pick(String, String.is_empty(w), "long", w)

# why a record gives no fixed episode ("" it gives one): solved, no-call
# (ana never closed a Term), no-record, hatch (the original's), the
# grammar's reason with one try, or long (it trains with one try but does
# not fit the window)
def et.fx.why(+win: EtW, +k: Nat, +r: E.EpRec, +t: List<&2, U32>) -> String:
  +ss = E.EpRec.segs(r)
  +fs = Tr.split(t, 30)
  +lang = et.meta(E.EpRec.meta(r), "lang")
  +best = Bool.not(Maybe.is_none(&2, List<&2, E.EpSeg>, et.fx.make(win, k, r, t)))
  Bool.pick(String, E.ep.solved(ss), "solved",
    Bool.pick(String, Nat.is_eq(E.ep.calls(ss), 0n), "no-call",
      Bool.pick(String, List.is_empty(&2, U32, t), "no-record",
        Bool.pick(String, et.hatch(lang, Tr.field(fs, 7n)), "hatch",
          Bool.pick(String, best, "ok", et.fx.long(E.ep.why(List.append(&2, E.EpSeg, et.fx.upto(ss, 1n), et.fx.fix(fs)), k)))))))

# the fixed so far: the output (newest first), each unit's count, the
# records by unit, how many, the reasons
type EtF is Type:
  EtF{out: List<&2, List<&2, U32>>, cs: Map<&2, Nat>, rm: Map<&2, List<&2, U32>>, n: Nat, why: List<&2, EtC>}

def et.fx.fin(room: Bool, m: Maybe<&2, List<&2, E.EpSeg>>, +unit: String, +id: List<&2, U32>, +c: Nat,
              o: List<&2, List<&2, U32>>, cs: Map<&2, Nat>, rm: Map<&2, List<&2, U32>>, +n: Nat, ws: List<&2, EtC>) -> EtF:
  match room m:
    case True{} Some{e}:
      EtF{List.concat(&2, U32, [id, [0], E.ep.text(e), [0]]) <> o, Map.set(&2, Nat, cs, unit, 1n+c), rm, 1n+n, ws}
    case _ _:
      EtF{o, cs, rm, n, ws}

# Map.get hands the map back with its answer
def et.fx.cnt(+win: EtW, +k: Nat, +cap: Nat, +r: E.EpRec, +unit: String, +id: List<&2, U32>, +t: List<&2, U32>, o: List<&2, List<&2, U32>>,
              rm: Map<&2, List<&2, U32>>, +n: Nat, ws: List<&2, EtC>, g: Map<&2, Nat> & Nat) -> EtF:
  (cs, +c) = g
  et.fx.fin(Nat.is_lt(c, cap), et.fx.make(win, k, r, t), unit, id, c, o, cs, rm, n, et.bump(ws, et.fx.why(win, k, r, t)))

def et.fx.rec(+win: EtW, +k: Nat, +cap: Nat, +r: E.EpRec, +unit: String, +id: List<&2, U32>, o: List<&2, List<&2, U32>>, cs: Map<&2, Nat>, +n: Nat,
              ws: List<&2, EtC>, g: Map<&2, List<&2, U32>> & List<&2, U32>) -> EtF:
  (rm, +t) = g
  et.fx.cnt(win, k, cap, r, unit, id, t, o, rm, n, ws, Map.get(Nat, 0n, cs, unit))

def et.fx.step(+win: EtW, +k: Nat, +cap: Nat, +r: E.EpRec, a: EtF) -> EtF:
  match a:
    case EtF{o, cs, rm, +n, ws}:
      +m = E.EpRec.meta(r)
      +unit = S.str(et.meta(m, "unit"))
      +id = List.concat(&2, U32, [et.meta(m, "unit"), S.b("/fixed-"), et.meta(m, "n")])
      et.fx.rec(win, k, cap, r, unit, id, o, cs, n, ws, Map.get(List<&2, U32>, Nil{}, rm, unit))

def et.fx.pass(rs: List<&2, E.EpRec>, +win: EtW, +k: Nat, +cap: Nat, a: EtF) -> EtF:
  match rs:
    case Nil{}:
      a
    case +r <> t:
      et.fx.pass(t, win, k, cap, et.fx.step(win, k, cap, r, a))

def et.fx.map(kvs: List<&2, Ev.EvKv>, m: Map<&2, List<&2, U32>>) -> Map<&2, List<&2, U32>>:
  match kvs:
    case Nil{}:
      m
    case Ev.EvKv{k, v} <> t:
      et.fx.map(t, Map.set(&2, List<&2, U32>, m, S.str(k), v))

def et.fx.units(rs: List<&2, E.EpRec>, s: Set()) -> Set():
  match rs:
    case Nil{}:
      s
    case r <> t:
      et.fx.units(t, Set.add(s, S.str(et.meta(E.EpRec.meta(r), "unit"))))

def et.fx.put(+dir: String, +l: String, a: EtF) -> IO(Nat):
  match a:
    case EtF{o, cs, rm, +n, ws}:
      do IO<Nat>:
        S.mkdir(dir)
        S.write(dir ++ "/transcripts.train.nul", List.concat(&2, U32, List.reverse(&2, List<&2, U32>, o)))
        IO.print("fixed: " ++ l ++ " " ++ Nat.show(n) ++ " into " ++ dir ++ "/transcripts.train.nul; episodes by reason:" ++ et.counts(ws))
        return n

# one language: its records (its units' only), its pass, its file
def et.fx.one(+out: String, +win: EtW, +k: Nat, +cap: Nat, +l: String, +rs: List<&2, E.EpRec>) -> IO(Nat):
  +mine = et.lang.of(S.b(l), rs)
  do IO<Nat>:
    kvs : List<&2, Ev.EvKv> <- Ev.ev.holdout([l], et.fx.units(mine, Set.new()), Nil{})
    et.fx.put(out ++ "/" ++ l ++ "-fix", l, et.fx.pass(mine, win, k, cap, EtF{Nil{}, Map.new(&2, Nat), et.fx.map(kvs, Map.new(&2, List<&2, U32>)), 0n, Nil{}}))

def et.fx.all(ls: List<&2, String>, +out: String, +win: EtW, +k: Nat, +cap: Nat, +rs: List<&2, E.EpRec>, +n: Nat) -> IO(Nat):
  match ls:
    case Nil{}:
      IO.pure(Nat, n)
    case l <> t:
      do IO<Nat>:
        m : Nat <- et.fx.one(out, win, k, cap, l, rs)
        et.fx.all(t, out, win, k, cap, rs, Nat.add(n, m))

def et.fixed(+k: Nat, +cap: Nat, +out: String, ps: List<String>) -> IO(Unit):
  do IO<Unit>:
    +win : EtW <- et.win()
    +rs : List<&2, E.EpRec> <- et.logs(ps, Nil{})
    n : Nat <- et.fx.all(et.langs(), out, win, k, cap, rs, 0n)
    IO.print("fixed: " ++ Nat.show(List.length(&2, E.EpRec, rs)) ++ " episodes; " ++ Nat.show(n)
      ++ " fixed episodes (at most the cap a unit) into " ++ out ++ "/LANG-fix")

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
    case "fixed" <> +k <> +cap <> +out <> logs:
      et.fixed(S.env.nat.got(Nat.read(k), 4n), S.env.nat.got(Nat.read(cap), 2n), out, logs)
    case _:
      IO.die(Unit, 2, "usage: bend-episode text LOG | why LOG K | accept K CAP OUT LOG... | fixed K CAP OUT LOG...")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    et.args(List.tail(&1, String, argv))
