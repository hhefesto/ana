import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../Check/Lib.bend as Cl
import ../CorpusV2/Lib.bend as L
import ../CorpusV2/Keyed.bend as K
import ../CorpusV2/Ratio.bend as R
import ../CorpusV2/Intake.bend as I

# bend-corpus-v2 repair-mix (bend/CorpusV2/Ratio.bend, 2026-10-22: the user's
# rule "for each program that is incorrect, and it takes a tool call to fix,
# the training corpus should contain four times the program correct from the
# start") and run 5's intake (bend/CorpusV2/Intake.bend: files-jsonl,
# raw-drop, port-fix).
#
# The pure parts against their meaning: a transcript's unit and tag from its
# id, its class from the trainer's reader (an attempt or a try before the act
# is a repair), the first-time transcript a repair implies (a format-2
# repair less its attempt is the same unit's direct transcript, byte for
# byte), held lines, the copies a unit's first-time transcripts get, a unit's
# slot in the budget (hard-coded from `sha256sum`).
#
# The tool on fixtures/ratio (real transcripts: a unit with a direct
# transcript, its format-2 repair and three mutation repairs; another with a
# run-3 chain; a held-out unit; a unit with repairs and no first-time
# transcript; a Haskell term-to-type; a port's whole-file repair):
# the law (every unit's first-time count >= ratio * its repairs, repairs <=
# cap, no id twice: R.rto.audit and a count here), the kept repair is the
# one with the least key (keys from `sha256sum`), the drops by reason, the
# held-out units gone, the copies byte for byte, the derived first-time
# transcripts, the key order, a second run the same bytes, a dry run the
# same stats and no OUT; then cap=2, ratio=2, share=50 and fill=repair.
# Then files-jsonl, raw-drop and port-fix on files written here (port-fix
# runs `bend` from the PATH, as the build sandbox has it, and reads
# weights/code32k.bpe).
#
# Each check prints `ok NAME` or `FAIL NAME`; any FAIL exits 1.  Run from
# bend/tests, compiled (the interpreter's stack does not hold the reader).

type RtCk is Data:
  RtCk{name: String, ok: Bool}

def rt.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "ratio: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def rt.say(cs: List<&2, RtCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      rt.end(Nat.is_eq(bad, 0n), bad, names)
    case RtCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        rt.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def rt.is(+got: List<&2, U32>, +want: String) -> Bool:
  S.eq(got, S.b(want))

# Fixtures' ids -----------------------------------------------------------------------

def rt.u1() -> String:
  "own:bend2/tests/parse/uppercase_binder.bend#id2@7"

def rt.ua() -> String:
  "curated:0x5f3759df-fs__scrapanium/benchmarks/client.bend#assert_status@7"

def rt.up() -> String:
  "port:hub__near-v-framework/domain/architecture/view/type.bend"

def rt.uh() -> String:
  "curated:1Computer1_hectoparsec/src/Hectoparsec/Class.hs#hidden@328"

def rt.u3() -> String:
  "own:bend2/tests/eval/either_suite.bend#id@10"

def rt.u4() -> String:
  "own:bend2/tests/check/erased_type_quantifier.bend#idT@7"

# A NUL stream's pairs --------------------------------------------------------------------

type RtP is Data:
  RtP{id: List<&2, U32>, t: List<&2, U32>}

def rt.pairs(xs: List<&2, List<&2, U32>>) -> List<&2, RtP>:
  match xs:
    case +i <> +t <> more:
      RtP{i, t} <> rt.pairs(more)
    case _:
      Nil{}

def rt.read(+p: String) -> IO(List<&2, RtP>):
  do IO<List<&2, RtP>>:
    +xs : List<&2, U32> <- S.read(p)
    return rt.pairs(S.split(xs, 0))

def rt.p.id(+p: RtP) -> List<&2, U32>:
  match p:
    case RtP{i, t}:
      i

def rt.p.t(+p: RtP) -> List<&2, U32>:
  match p:
    case RtP{i, t}:
      t

# the text of the record with id, if any
def rt.text(ps: List<&2, RtP>, +id: String) -> Maybe<&2, List<&2, U32>>:
  match ps:
    case Nil{}:
      None{}
    case RtP{+i, +t} <> more:
      Bool.pick(Maybe<&2, List<&2, U32>>, rt.is(i, id), Some{t}, rt.text(more, id))

def rt.some(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{x}:
      True{}
    case None{}:
      False{}

def rt.has(+ps: List<&2, RtP>, +id: String) -> Bool:
  rt.some(rt.text(ps, id))

def rt.text.or(m: Maybe<&2, List<&2, U32>>) -> List<&2, U32>:
  Maybe.default(&2, List<&2, U32>, m, [0])

# records whose unit (less a copy's /eK and a derived /first) is u
def rt.of.unit(ps: List<&2, RtP>, +u: String) -> List<&2, RtP>:
  match ps:
    case Nil{}:
      Nil{}
    case RtP{+i, +t} <> more:
      +r = rt.of.unit(more, u)
      Bool.pick(List<&2, RtP>, rt.is(R.rto.unit(R.rto.base(i)), u), RtP{i, t} <> r, r)

# records of class c (fill=other)
def rt.n.class(ps: List<&2, RtP>, +c: Nat) -> Nat:
  match ps:
    case Nil{}:
      0n
    case RtP{+i, +t} <> more:
      Nat.add(Bool.pick(Nat, Nat.is_eq(R.rto.class(False{}, R.rto.base(i), t), c), 1n, 0n), rt.n.class(more, c))

# the law, counted here: first >= ratio * repairs and repairs <= cap, for u
def rt.law(+ps: List<&2, RtP>, +ratio: Nat, +cap: Nat, +u: String) -> Bool:
  +us = rt.of.unit(ps, u)
  +f = rt.n.class(us, 0n)
  +n = rt.n.class(us, 1n)
  Bool.and(Nat.is_le(Nat.mul(ratio, n), f), Nat.is_le(n, cap))

def rt.counts(+ps: List<&2, RtP>, +u: String) -> Nat & Nat:
  +us = rt.of.unit(ps, u)
  (rt.n.class(us, 0n), rt.n.class(us, 1n))

def rt.counts.is(c: Nat & Nat, +f: Nat, +n: Nat) -> Bool:
  (+a, +b) = c
  Bool.and(Nat.is_eq(a, f), Nat.is_eq(b, n))

# every copy (id/eK) has its original's text, and the original is there
def rt.copies.ok(+all: List<&2, RtP>, ps: List<&2, RtP>) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case RtP{+i, +t} <> more:
      +cp = R.rto.is.copy(R.rto.seg(i))
      +ok = Bool.pick(Bool, cp, S.eq(rt.text.or(rt.text(all, S.str(R.rto.stem(i)))), t), True{})
      Bool.and(ok, rt.copies.ok(all, more))

# the ids in key order (sha256(salt NUL id), the spool's order)
def rt.keyed(ps: List<&2, RtP>, +prev: String) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case RtP{+i, t} <> more:
      +k = K.kor.key(S.b("ana repair-mix"), i)
      Bool.and(S.bytes.le(S.b(prev), S.b(k)), rt.keyed(more, k))

def rt.none.of(+ps: List<&2, RtP>, +u: String) -> Bool:
  List.is_empty(&2, RtP, rt.of.unit(ps, u))

# a stat's count (0 when absent)
def rt.st(st: List<&2, Cl.Stat>, +k: String) -> Nat:
  match st:
    case Nil{}:
      0n
    case Cl.Stat{+x, +n} <> more:
      Bool.pick(Nat, String.eq(x, k), n, rt.st(more, k))

def rt.sts(+st: List<&2, Cl.Stat>, ks: List<&2, String>) -> List<&2, Nat>:
  match ks:
    case Nil{}:
      Nil{}
    case +k <> more:
      rt.st(st, k) <> rt.sts(st, more)

def rt.nats.eq(xs: List<&2, Nat>, ys: List<&2, Nat>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +a <> s +b <> t:
      Bool.and(Nat.is_eq(a, b), rt.nats.eq(s, t))
    case _ _:
      False{}

def rt.keys() -> List<&2, String>:
  ["out-first", "out-copy", "out-repair", "out-derived", "out-other", "drop-cap", "drop-no-first", "drop-share", "drop-verify",
   "held-first", "held-repair", "held-other"]

def rt.st.is(+st: List<&2, Cl.Stat>, +want: List<&2, Nat>) -> Bool:
  rt.nats.eq(rt.sts(st, rt.keys()), want)

def rt.aud.is(a: R.RtAud, +recs: Nat, +units: Nat, +firsts: Nat, +reps: Nat) -> Bool:
  match a:
    case R.RtAud{+n, +u, +b, +d, +f, +k}:
      Bool.and(Bool.and(Bool.and(Nat.is_eq(n, recs), Nat.is_eq(u, units)), Bool.and(Nat.is_eq(f, firsts), Nat.is_eq(k, reps))),
        Bool.and(Nat.is_eq(b, 0n), Nat.is_eq(d, 0n)))

# The pure parts -----------------------------------------------------------------------------

def rt.none(m: Maybe<&2, String>) -> Bool:
  match m:
    case Some{x}:
      False{}
    case None{}:
      True{}

def rt.some.is(m: Maybe<&2, String>, +want: String) -> Bool:
  match m:
    case Some{+x}:
      String.eq(x, want)
    case None{}:
      False{}

# a transcript up to its first checker turn (`## bend`)
def rt.upto.at(+xs: List<&2, U32>, m: Maybe<&2, Nat>) -> List<&2, U32>:
  match m:
    case Some{+k}:
      List.take(&2, U32, xs, k)
    case None{}:
      Nil{}

def rt.upto(+xs: List<&2, U32>) -> List<&2, U32>:
  rt.upto.at(xs, S.find(xs, S.b("## bend"), 0n))

def rt.head.or(ps: List<&2, RtP>) -> RtP:
  match ps:
    case Nil{}:
      RtP{Nil{}, Nil{}}
    case p <> more:
      p

def rt.fx(+f: String) -> String:
  "fixtures/ratio/" ++ f

def rt.pure() -> List<&2, RtCk>:
  [RtCk{"unit: mut: and the operator dropped", rt.is(R.rto.unit(S.b("mut:" ++ rt.u1() ++ "/misspell-0")), rt.u1())},
   RtCk{"unit: a presentation's +N and its shape dropped", rt.is(R.rto.unit(S.b(rt.ua() ++ "+3/repair")), rt.ua())},
   RtCk{"unit: a chain's", rt.is(R.rto.unit(S.b(rt.ua() ++ "/chain-3")), rt.ua())},
   RtCk{"unit: a port's whole file, and whole", Bool.and(rt.is(R.rto.unit(S.b(rt.up() ++ "/repair")), rt.up()), R.rto.whole(S.b(rt.up())))},
   RtCk{"unit: a declaration is not whole", Bool.not(R.rto.whole(S.b(rt.ua())))},
   RtCk{"tag: the operator or shape less -N", Bool.and(Bool.and(rt.is(R.rto.tag(S.b("mut:" ++ rt.u1() ++ "/swap-args-0")), "swap-args"),
     rt.is(R.rto.tag(S.b(rt.ua() ++ "/chain-repair-2")), "chain-repair")), rt.is(R.rto.tag(S.b(rt.ua() ++ "+1/repair")), "repair"))},
   RtCk{"base: a copy's /eK and a derived /first dropped", Bool.and(Bool.and(rt.is(R.rto.base(S.b("a#f@1/direct/e3")), "a#f@1/direct"),
     rt.is(R.rto.base(S.b("p:r/x.bend/repair/first/e2")), "p:r/x.bend/repair")), Bool.and(rt.is(R.rto.base(S.b("p:r/x.bend/repair/first")), "p:r/x.bend/repair"),
     rt.is(R.rto.base(S.b("a#f@1/drop-arg-0")), "a#f@1/drop-arg-0")))},
   RtCk{"held line: an id; REASON TAB ID for the held reasons only", Bool.and(Bool.and(
     rt.some.is(R.rto.held.line(S.b("held-decl\ta#f@1")), "a#f@1"),
     rt.some.is(R.rto.held.line(S.b("repo:x/y.bend")), "repo:x/y.bend")),
     Bool.and(rt.none(R.rto.held.line(S.b("seen\ta#f@1"))), rt.none(R.rto.held.line(S.b("dup\ta#f@1")))))},
   RtCk{"slot: int(sha256(salt NUL share NUL u)[:8], 16) % 100 (sha256sum: 53 44 50 62 31 17)", rt.nats.eq(
     [R.rto.slot(S.b("ana repair-mix"), S.b(rt.u1())), R.rto.slot(S.b("ana repair-mix"), S.b(rt.ua())), R.rto.slot(S.b("ana repair-mix"), S.b(rt.up())),
      R.rto.slot(S.b("ana repair-mix"), S.b(rt.u3())), R.rto.slot(S.b("ana repair-mix"), S.b(rt.u4())), R.rto.slot(S.b("ana repair-mix"), S.b(rt.uh()))],
     [53n, 44n, 50n, 62n, 31n, 17n])},
   RtCk{"extras: f=1 kept=1 ratio 4 gives 3 copies; f=3 gives 1, 0, 0; f=5 none", rt.nats.eq(
     [R.rto.extras(R.rto.cfg0(), S.b("u"), R.RtU{1n, 1n, [R.RtR{"k", "i"}]}, 0n),
      R.rto.extras(R.rto.cfg0(), S.b("u"), R.RtU{3n, 1n, [R.RtR{"k", "i"}]}, 0n), R.rto.extras(R.rto.cfg0(), S.b("u"), R.RtU{3n, 1n, [R.RtR{"k", "i"}]}, 1n),
      R.rto.extras(R.rto.cfg0(), S.b("u"), R.RtU{3n, 1n, [R.RtR{"k", "i"}]}, 2n), R.rto.extras(R.rto.cfg0(), S.b("u"), R.RtU{5n, 1n, [R.RtR{"k", "i"}]}, 0n)],
     [3n, 1n, 0n, 0n, 0n])}]

# the classes and the derived transcript, on the fixtures' own texts
def rt.texts(+base: List<&2, RtP>, +mut: List<&2, RtP>, +chain: List<&2, RtP>, +t2t: List<&2, RtP>, +port: List<&2, RtP>) -> List<&2, RtCk>:
  +dir = rt.text.or(rt.text(base, rt.ua() ++ "/direct"))
  +rep1 = rt.text.or(rt.text(base, rt.ua() ++ "+1/repair"))
  +rep3 = rt.text.or(rt.text(base, rt.ua() ++ "+3/repair"))
  +fill = rt.text.or(rt.text(base, rt.ua() ++ "+2/fill"))
  +m1 = rt.text.or(rt.text(mut, "mut:" ++ rt.u1() ++ "/drop-arg-0"))
  +d1 = rt.text.or(rt.text(base, rt.u1() ++ "+1/direct"))
  +ch = rt.text.or(rt.text(chain, rt.ua() ++ "/chain-3"))
  +pr = rt.text.or(rt.text(port, rt.up() ++ "/repair"))
  +pd = R.rto.derive(pr)
  [RtCk{"class: a direct transcript is first-time", Nat.is_eq(R.rto.class(False{}, S.b(rt.ua() ++ "/direct"), dir), 0n)},
   RtCk{"class: format 2's repair and a mutation repair are repairs (an Attempt before the act)", Bool.and(
     Nat.is_eq(R.rto.class(False{}, S.b(rt.ua() ++ "+1/repair"), rep1), 1n), Nat.is_eq(R.rto.class(False{}, S.b("mut:" ++ rt.u1() ++ "/drop-arg-0"), m1), 1n))},
   RtCk{"class: a run-3 chain (Terms the tool rejected, then the act) is a repair", Nat.is_eq(R.rto.class(False{}, S.b(rt.ua() ++ "/chain-3"), ch), 1n)},
   RtCk{"class: a fill is other, or a repair under fill=repair; a verify is a verify", Bool.and(Bool.and(
     Nat.is_eq(R.rto.class(False{}, S.b(rt.ua() ++ "+2/fill"), fill), 2n), Nat.is_eq(R.rto.class(True{}, S.b(rt.ua() ++ "+2/fill"), fill), 1n)),
     Nat.is_eq(R.rto.class(False{}, S.b(rt.ua() ++ "+4/verify"), dir), 3n))},
   RtCk{"class: a term-to-type transcript is first-time", Nat.is_eq(R.rto.class(False{}, rt.p.id(rt.head.or(t2t)), rt.p.t(rt.head.or(t2t))), 0n)},
   RtCk{"derive: format 2's two repairs less their attempts are the unit's direct transcript, byte for byte", Bool.and(S.eq(R.rto.derive(rep1), dir), S.eq(R.rto.derive(rep3), dir))},
   RtCk{"derive: a mutation repair less its attempt is the unit's direct transcript up to the pass (the locked compiler words its pass anew)", Bool.and(S.eq(rt.upto(R.rto.derive(m1)), rt.upto(d1)), Bool.not(Nat.is_eq(S.len(rt.upto(d1)), 0n)))},
   RtCk{"derive: a chain less its tries is the unit's direct transcript, byte for byte", S.eq(R.rto.derive(ch), dir)},
   RtCk{"derive: a port's repair gives User (no fix line), Term and the pass, first-time", Bool.and(Bool.and(
     Bool.not(S.infix(pd, S.b("## Attempt"))), Bool.not(S.infix(pd, S.b("This attempt fails")))),
     Bool.and(S.prefix(pd, S.b("## User\n\nWrite the Bend file `domain/architecture/view/type.bend`.\n\n## Term")), Nat.is_eq(R.rto.class(False{}, S.b(rt.up() ++ "/first"), pd), 0n)))}]

# The tool on the fixtures -------------------------------------------------------------------

def rt.srcs() -> List<&2, R.RtSrc>:
  [R.RtSrc{rt.fx("base.nul"), False{}}, R.RtSrc{rt.fx("mut.nul"), False{}}, R.RtSrc{rt.fx("chain.nul"), False{}},
   R.RtSrc{rt.fx("t2t.nul"), False{}}, R.RtSrc{rt.fx("port.nul"), False{}}]

# ratio, cap, fill, derive whole, dry, share
def rt.cfg(+ratio: Nat, +cap: Nat, +fill: Bool, +dry: Bool, +share: Nat) -> R.RtCfg:
  R.RtCfg{ratio, cap, S.b("ana repair-mix"), fill, 1n, dry, share}

def rt.run(+out: String, +c: R.RtCfg) -> IO(List<&2, Cl.Stat>):
  R.rto.go(out, rt.srcs(), [rt.fx("held.txt")], c)

def rt.tool(+dir: String) -> IO(List<&2, RtCk>):
  +o = dir ++ "/out.nul"
  do IO<List<&2, RtCk>>:
    +st : List<&2, Cl.Stat> <- rt.run(o, rt.cfg(4n, 1n, False{}, False{}, 100n))
    +ps : List<&2, RtP> <- rt.read(o)
    +bytes : List<&2, U32> <- S.read(o)
    +a : R.RtAud <- R.rto.audit(False{}, 4n, 1n, o)
    +sf : List<&2, U32> <- S.read(o ++ ".stats")
    st2 : List<&2, Cl.Stat> <- rt.run(dir ++ "/again.nul", rt.cfg(4n, 1n, False{}, False{}, 100n))
    +b2 : List<&2, U32> <- S.read(dir ++ "/again.nul")
    st3 : List<&2, Cl.Stat> <- rt.run(dir ++ "/dry.nul", rt.cfg(4n, 1n, False{}, True{}, 100n))
    dry : Bool <- S.exists(dir ++ "/dry.nul")
    +sd : List<&2, U32> <- S.read(dir ++ "/dry.nul.stats")
    spool : Bool <- S.exists(o ++ ".rto-spool")
    +port : List<&2, RtP> <- rt.read(rt.fx("port.nul"))
    +prep : List<&2, U32> = rt.text.or(rt.text(port, rt.up() ++ "/repair"))
    return [RtCk{"tool: the law holds (audit: 18 records, 4 units, 13 first-time, 3 repairs, none breaks it, no id twice)", rt.aud.is(a, 18n, 4n, 13n, 3n)},
      RtCk{"tool: the law counted here, unit by unit (ratio 4, cap 1)", Bool.and(Bool.and(rt.law(ps, 4n, 1n, rt.u1()), rt.law(ps, 4n, 1n, rt.ua())),
        Bool.and(rt.law(ps, 4n, 1n, rt.up()), rt.law(ps, 4n, 1n, rt.uh())))},
      RtCk{"tool: each unit's first-time and repair counts (4+1, 4+1, 4+1 derived, 1+0)", Bool.and(Bool.and(rt.counts.is(rt.counts(ps, rt.u1()), 4n, 1n),
        rt.counts.is(rt.counts(ps, rt.ua()), 4n, 1n)), Bool.and(rt.counts.is(rt.counts(ps, rt.up()), 4n, 1n), rt.counts.is(rt.counts(ps, rt.uh()), 1n, 0n)))},
      RtCk{"tool: the kept repair is the least key's (sha256sum: drop-arg for the first unit, the chain for the second)", Bool.and(Bool.and(
        rt.has(ps, "mut:" ++ rt.u1() ++ "/drop-arg-0"), rt.has(ps, rt.ua() ++ "/chain-3")), Bool.and(Bool.not(rt.has(ps, rt.u1() ++ "/repair")), Bool.not(rt.has(ps, rt.ua() ++ "+1/repair"))))},
      RtCk{"tool: the stats: first 3, copies 6, repairs 3, derived 4, other 2; cap 5, no first 3; held 1 4 1",
        rt.st.is(st, [3n, 6n, 3n, 4n, 2n, 5n, 3n, 0n, 0n, 1n, 4n, 1n])},
      RtCk{"tool: OUT.stats is the stats", rt.is(sf, Cl.stat.show(st))},
      RtCk{"tool: no held-out unit and no repair without a first-time transcript in OUT", Bool.and(rt.none.of(ps, rt.u4()), rt.none.of(ps, rt.u3()))},
      RtCk{"tool: the held lines of other reasons hold nothing (the seen and dup units are in OUT)", Bool.and(rt.has(ps, rt.u1() ++ "+1/direct"), rt.has(ps, rt.ua() ++ "/direct"))},
      RtCk{"tool: every copy is its original byte for byte", rt.copies.ok(ps, ps)},
      RtCk{"tool: the copies are /e2../e4 of the direct transcript", Bool.and(rt.has(ps, rt.u1() ++ "+1/direct/e4"), Bool.not(rt.has(ps, rt.u1() ++ "+1/direct/e5")))},
      RtCk{"tool: the port's repair kept with four derived first-time transcripts", Bool.and(Bool.and(rt.has(ps, rt.up() ++ "/repair"),
        S.eq(rt.text.or(rt.text(ps, rt.up() ++ "/repair/first")), R.rto.derive(prep))), Bool.and(rt.has(ps, rt.up() ++ "/repair/first/e4"), Bool.not(rt.has(ps, rt.up() ++ "/repair/first/e5"))))},
      RtCk{"tool: the fills pass through as they stand (fill=other)", Bool.and(rt.has(ps, rt.ua() ++ "+2/fill"), rt.has(ps, rt.u1() ++ "+2/fill"))},
      RtCk{"tool: OUT is in key order, the spool removed", Bool.and(rt.keyed(ps, ""), Bool.not(spool))},
      RtCk{"tool: a second run writes the same bytes and stats", Bool.and(S.eq(b2, bytes), String.eq(Cl.stat.show(st2), Cl.stat.show(st)))},
      RtCk{"tool: dry writes no OUT and the same stats", Bool.and(Bool.not(dry), Bool.and(S.eq(sd, sf), String.eq(Cl.stat.show(st3), Cl.stat.show(st))))}]

def rt.vary(+dir: String) -> IO(List<&2, RtCk>):
  do IO<List<&2, RtCk>>:
    +s2 : List<&2, Cl.Stat> <- rt.run(dir ++ "/cap2.nul", rt.cfg(4n, 2n, False{}, False{}, 100n))
    +p2 : List<&2, RtP> <- rt.read(dir ++ "/cap2.nul")
    +a2 : R.RtAud <- R.rto.audit(False{}, 4n, 2n, dir ++ "/cap2.nul")
    +sr : List<&2, Cl.Stat> <- rt.run(dir ++ "/r2.nul", rt.cfg(2n, 1n, False{}, False{}, 100n))
    +ar : R.RtAud <- R.rto.audit(False{}, 2n, 1n, dir ++ "/r2.nul")
    +sh : List<&2, Cl.Stat> <- rt.run(dir ++ "/s50.nul", rt.cfg(4n, 1n, False{}, False{}, 50n))
    +ph : List<&2, RtP> <- rt.read(dir ++ "/s50.nul")
    +ah : R.RtAud <- R.rto.audit(False{}, 4n, 1n, dir ++ "/s50.nul")
    +sf : List<&2, Cl.Stat> <- rt.run(dir ++ "/fill.nul", rt.cfg(4n, 1n, True{}, False{}, 100n))
    +af : R.RtAud <- R.rto.audit(True{}, 4n, 1n, dir ++ "/fill.nul")
    return [RtCk{"cap=2: the law (28 records, 4 units, 21 first-time, 5 repairs)", rt.aud.is(a2, 28n, 4n, 21n, 5n)},
      RtCk{"cap=2: the two least keys a unit (sha256sum: drop-arg and the format-2 repair; the chain and +3/repair)", Bool.and(Bool.and(
        rt.has(p2, "mut:" ++ rt.u1() ++ "/drop-arg-0"), rt.has(p2, rt.u1() ++ "/repair")), Bool.and(rt.has(p2, rt.ua() ++ "/chain-3"), rt.has(p2, rt.ua() ++ "+3/repair")))},
      RtCk{"cap=2: the stats (copies 14, cap drops 3)", rt.st.is(s2, [3n, 14n, 5n, 4n, 2n, 3n, 3n, 0n, 0n, 1n, 4n, 1n])},
      RtCk{"ratio=2: the law (12 records, 7 first-time, 3 repairs) and the stats", Bool.and(rt.aud.is(ar, 12n, 4n, 7n, 3n), rt.st.is(sr, [3n, 2n, 3n, 2n, 2n, 5n, 3n, 0n, 0n, 1n, 4n, 1n]))},
      RtCk{"share=50: units at slots 53, 50 and 62 keep no repair, the one at 44 keeps its own (9 records)", Bool.and(rt.aud.is(ah, 9n, 3n, 6n, 1n),
        rt.st.is(sh, [3n, 3n, 1n, 0n, 2n, 2n, 0n, 8n, 0n, 1n, 4n, 1n]))},
      RtCk{"share=50: the first unit keeps its one first-time transcript, uncopied", Bool.and(rt.counts.is(rt.counts(ph, rt.u1()), 1n, 0n), rt.none.of(ph, rt.up()))},
      RtCk{"fill=repair: the law with fills counted as repairs (16 records)", rt.aud.is(af, 16n, 4n, 13n, 3n)},
      RtCk{"fill=repair: no fill passes through; cap drops 7", rt.st.is(sf, [3n, 6n, 3n, 4n, 0n, 7n, 3n, 0n, 0n, 1n, 5n, 0n])}]

# Intake -------------------------------------------------------------------------------------------

def rt.fj(+dir: String) -> IO(List<&2, RtCk>):
  +d = dir ++ "/fj"
  do IO<List<&2, RtCk>>:
    S.mkdir(d ++ "/sub")
    S.write(d ++ "/sub/a.bend", S.b("import Base\n\ndef a() -> U32:\n  1\n"))
    S.write(d ++ "/b.bend", S.b("def b() -> String:\n  \"q\\\"\"\n"))
    S.write(d ++ "/n.bend", [100, 0, 101])
    S.write(d ++ "/c.txt", S.b("not bend"))
    I.itk.files.jsonl("own:x", d, dir ++ "/fj.jsonl")
    +o : List<&2, U32> <- S.read(dir ++ "/fj.jsonl")
    +s : List<&2, U32> <- S.read(dir ++ "/fj.jsonl.stats")
    return [RtCk{"files-jsonl: the .bend files in bytewise path order as JSON lines, PREFIX/PATH ids; a NUL file left out",
        rt.is(o, "{\"id\": \"own:x/b.bend\", \"text\": \"def b() -> String:\\n  \\\"q\\\\\\\"\\\"\\n\"}\n{\"id\": \"own:x/sub/a.bend\", \"text\": \"import Base\\n\\ndef a() -> U32:\\n  1\\n\"}\n")},
      RtCk{"files-jsonl: the stats", rt.is(s, "bytes 60\nfiles 2\nnul 1\n")}]

# files-jsonl's drop= (2026-10-27): a file less the named defs and the comments just above them
def rt.dd.text(x: List<&2, U32> & Nat & Nat) -> List<&2, U32>:
  (t, _, _) = x
  t

def rt.dd.count.is(x: List<&2, U32> & Nat & Nat, +n: Nat, +b: Nat) -> Bool:
  (_, n2, b2) = x
  Bool.and(Nat.is_eq(n, n2), Nat.is_eq(b, b2))

def rt.dd.src() -> List<&2, U32>:
  S.b("import Base\n\n# keep me\ndef f(+n: Nat) -> Nat:\n  n\n\n# a test\ndef observations0() -> IO(Unit):\n  IO.print(\"x\")\n\n# not a test\ndef observe(+n: Nat) -> Nat:\n  n\n\n# main runs it\ndef main() -> IO(Unit):\n  observations0()\n")

def rt.fjd(+dir: String) -> IO(List<&2, RtCk>):
  +d = dir ++ "/fjd"
  +ws : List<&2, List<&2, U32>> = [S.b("main"), S.b("observations*")]
  +kept : String = "import Base\n\n# keep me\ndef f(+n: Nat) -> Nat:\n  n\n\n# not a test\ndef observe(+n: Nat) -> Nat:\n  n\n\n"
  do IO<List<&2, RtCk>>:
    S.mkdir(d ++ "/t")
    S.write(d ++ "/m.bend", rt.dd.src())
    S.write(d ++ "/t/Test.bend", S.b("def main() -> U32:\n  1\n"))
    I.itk.files.jsonl.with("own:y", d, dir ++ "/fjd.jsonl", ["*/Test.bend"], ws)
    +o : List<&2, U32> <- S.read(dir ++ "/fjd.jsonl")
    +s : List<&2, U32> <- S.read(dir ++ "/fjd.jsonl.stats")
    return [RtCk{"files-jsonl drop=: main and observations* go with the comments above them; observe stays (a prefix needs its *)",
        rt.is(rt.dd.text(I.itk.dd.file(ws, rt.dd.src())), kept)},
      RtCk{"files-jsonl drop=: 2 defs, 116 bytes dropped (the kept and dropped bytes add up to the file's)",
        Bool.and(Nat.is_eq(Nat.add(S.len(S.b(kept)), 116n), S.len(rt.dd.src())), rt.dd.count.is(I.itk.dd.file(ws, rt.dd.src()), 2n, 116n))},
      RtCk{"files-jsonl drop=: a file none of whose defs is named stays byte for byte",
        rt.is(rt.dd.text(I.itk.dd.file([S.b("zzz")], rt.dd.src())), S.str(rt.dd.src()))},
      RtCk{"files-jsonl skip=: */Test.bend is left out; drop= writes the stripped text",
        rt.is(o, "{\"id\": \"own:y/m.bend\", \"text\": \"import Base\\n\\n# keep me\\ndef f(+n: Nat) -> Nat:\\n  n\\n\\n# not a test\\ndef observe(+n: Nat) -> Nat:\\n  n\\n\\n\"}\n")},
      RtCk{"files-jsonl drop=: the stats add defs-dropped and bytes-dropped", rt.is(s, "bytes 98\nfiles 1\nnul 0\ndefs-dropped 2\nbytes-dropped 116\n")}]

def rt.rd(+dir: String) -> IO(List<&2, RtCk>):
  do IO<List<&2, RtCk>>:
    S.write(dir ++ "/in1.jsonl", S.b("{\"id\": \"repo:x/a.bend\", \"text\": \"1\"}\n{\"id\": \"repo:x/b.bend\", \"text\": \"2\"}\n"))
    S.write(dir ++ "/in2.jsonl", S.b("{\"id\": \"repo:y/c.bend\", \"text\": \"3\"}\n{\"id\": \"repo:z/d.bend\", \"text\": \"4\"}\n"))
    S.write(dir ++ "/files.txt", S.b("repo:x/a.bend\n"))
    S.write(dir ++ "/units.dropped", S.b("held-decl\trepo:y/c.bend#f@3\nseen\trepo:z/d.bend#g@1\ndup\trepo:x/b.bend#h@2\n"))
    I.itk.raw.drop(dir ++ "/rd.jsonl", [dir ++ "/in1.jsonl", dir ++ "/in2.jsonl"], [dir ++ "/files.txt", dir ++ "/units.dropped"])
    +o : List<&2, U32> <- S.read(dir ++ "/rd.jsonl")
    tmp : Bool <- S.exists(dir ++ "/rd.jsonl.tmp")
    return [RtCk{"raw-drop: a listed file and a held unit's file go; a seen or dup unit's file stays; the order kept",
        rt.is(o, "{\"id\": \"repo:x/b.bend\", \"text\": \"2\"}\n{\"id\": \"repo:z/d.bend\", \"text\": \"4\"}\n")},
      RtCk{"raw-drop: OUT.tmp is moved into place", Bool.not(tmp)}]

def rt.pf(+dir: String) -> IO(List<&2, RtCk>):
  +ib = dir ++ "/inbox"
  +fx = dir ++ "/fixed"
  do IO<List<&2, RtCk>>:
    S.mkdir(ib ++ "/o__r")
    S.mkdir(fx ++ "/o__r")
    S.write(ib ++ "/o__r/a.bend", S.b("import Base\n\ndef f() -> U32:\n  True{}\n"))
    S.write(fx ++ "/o__r/a.bend", S.b("import Base\n\ndef f() -> U32:\n  1\n"))
    S.write(fx ++ "/o__r/FIXED.tsv", S.b("a.bend\tfixed\tthe body is a U32\nb.bend\tunfixable\tno\nc.bend\tmaybe\tx\n"))
    I.itk.port.fix(ib, fx, dir ++ "/pf")
    +j : List<&2, U32> <- S.read(dir ++ "/pf/bend.jsonl")
    +ps : List<&2, RtP> <- rt.read(dir ++ "/pf/transcripts.train.nul")
    +st : List<&2, U32> <- S.read(dir ++ "/pf/stats")
    +t : List<&2, U32> = rt.text.or(rt.text(ps, "port-fix:o__r/a.bend/repair"))
    return [RtCk{"port-fix: a fixed file is a raw record port-fix:REPO/PATH", rt.is(j, "{\"id\": \"port-fix:o__r/a.bend\", \"text\": \"import Base\\n\\ndef f() -> U32:\\n  1\\n\"}\n")},
      RtCk{"port-fix: its whole-file repair: the inbox's file as the Attempt, the fixed as the Term, a repair",
        Bool.and(Bool.and(Nat.is_eq(List.length(&2, RtP, ps), 1n), Nat.is_eq(R.rto.class(False{}, S.b("port-fix:o__r/a.bend/repair"), t), 1n)),
          Bool.and(S.infix(t, S.b("## Attempt\n\n```bend\nimport Base\n\ndef f() -> U32:\n  True{}\n```")), S.infix(t, S.b("## Term\n\n```bend\nimport Base\n\ndef f() -> U32:\n  1\n```"))))},
      RtCk{"port-fix: its unit is the whole file", rt.is(R.rto.unit(S.b("port-fix:o__r/a.bend/repair")), "port-fix:o__r/a.bend")},
      RtCk{"port-fix: the stats", rt.is(st, "fixed 1\nrepair transcripts 1\nrepositories with a FIXED.tsv 1\nstatus other 1\nunfixable 1\n")}]

def main() -> IO(Unit):
  do IO<Unit>:
    +dir : String <- S.mktemp()
    +base : List<&2, RtP> <- rt.read(rt.fx("base.nul"))
    +mut : List<&2, RtP> <- rt.read(rt.fx("mut.nul"))
    +chain : List<&2, RtP> <- rt.read(rt.fx("chain.nul"))
    +t2t : List<&2, RtP> <- rt.read(rt.fx("t2t.nul"))
    +port : List<&2, RtP> <- rt.read(rt.fx("port.nul"))
    tool : List<&2, RtCk> <- rt.tool(dir)
    vary : List<&2, RtCk> <- rt.vary(dir)
    fj : List<&2, RtCk> <- rt.fj(dir)
    fjd : List<&2, RtCk> <- rt.fjd(dir)
    rd : List<&2, RtCk> <- rt.rd(dir)
    pf : List<&2, RtCk> <- rt.pf(dir)
    S.rm(dir)
    rt.say(List.concat(&2, RtCk, [rt.pure(), rt.texts(base, mut, chain, t2t, port), tool, vary, fj, fjd, rd, pf]), 0n, "")
