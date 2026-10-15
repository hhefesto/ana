import Base
import ../Sys.bend as S
import ../Box/Local.bend as Lc
import ../Box/Act.bend as Ac
import ../Box/ActBox.bend as Ab
import ../CorpusV2/AgentAct.bend as Aa
import ../Agent/Episode.bend as E
import ../Agent/EpTool.bend as Et

# The act round's pure parts (2026-10-15, the plan's Phase 3: bend/Box/Act.bend,
# ActBox.bend, CorpusV2/AgentAct.bend, Agent/EpTool.bend's langs) against what
# act-box.sh, agent-act.sh, s2-driver.sh and move.sh computed: start's PROCS on
# run 3's second box (nproc 192, cpu.max 46 cores), the check's verdict on a
# real check.txt (act round 1's, from run/v3/run3/act1.log), the per-language
# table on the head of round 1's eplog (fixtures/act/r1-head.langs is the
# paste/awk pipeline's own table, sorted), setup's unit and tree rules, the
# frame and pair cuts, agent-act's command lines with the script's defaults,
# and the follower's exit status and pass-through.  Each check prints `ok
# NAME` or `FAIL NAME`; any FAIL exits 1.  Run from bend/tests.

type ActCk is Data:
  ActCk{name: String, ok: Bool}

def act.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "act: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def act.say(cs: List<&2, ActCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      act.end(Nat.is_eq(bad, 0n), bad, names)
    case ActCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        act.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def act.b(+s: String) -> List<&2, U32>:
  S.b(s)

def act.is(+got: List<&2, U32>, +want: String) -> Bool:
  S.eq(got, S.b(want))

def act.lines.eq(xs: List<&2, List<&2, U32>>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(S.eq(x, S.b(y)), act.lines.eq(xt, yt))
    case _ _:
      False{}

def act.strs.eq(xs: List<&2, String>, ys: List<&2, String>) -> Bool:
  match xs ys:
    case Nil{} Nil{}:
      True{}
    case +x <> xt +y <> yt:
      Bool.and(String.eq(x, y), act.strs.eq(xt, yt))
    case _ _:
      False{}

def act.m.is(m: Maybe<&2, List<&2, U32>>, +want: String) -> Bool:
  match m:
    case Some{+x}:
      S.eq(x, S.b(want))
    case None{}:
      False{}

def act.m.none(m: Maybe<&2, List<&2, U32>>) -> Bool:
  match m:
    case Some{x}:
      False{}
    case None{}:
      True{}

# PROCS --------------------------------------------------------------------------------------

def act.procs() -> List<&2, ActCk>:
  [ActCk{"procs: nproc 192, cpu.max 46 cores is 21", Nat.is_eq(Ac.acb.procs.of(act.b("192\n"), Some{act.b("4600000 100000\n")}), 21n)},
   ActCk{"procs: no quota (max) is (192 - 4) / 2", Nat.is_eq(Ac.acb.procs.of(act.b("192\n"), Some{act.b("max 100000\n")}), 94n)},
   ActCk{"procs: cpu.max unread is nproc's", Nat.is_eq(Ac.acb.procs.of(act.b("192\n"), None{}), 94n)},
   ActCk{"procs: a quota rounds down", Nat.is_eq(Ac.acb.procs.of(act.b("48\n"), Some{act.b("4650000 100000\n")}), 21n)},
   ActCk{"procs: at least 1", Nat.is_eq(Ac.acb.procs.of(act.b("4\n"), None{}), 1n)}]

# The check's verdict ------------------------------------------------------------------------

def act.check(+txt: List<&2, U32>, +table: List<&2, U32>) -> List<&2, ActCk>:
  +l17 = S.replace(txt, act.b("render law 18/18"), act.b("render law 17/18"))
  +l018 = S.replace(txt, act.b("render law 18/18"), act.b("render law 018/18"))
  +nob = S.replace(txt, act.b("  bend repair, solved within 1:0/2"), act.b("  bend repair, solved within 1:0/0"))
  [ActCk{"check: render law 18/18 holds (run 3's check.txt)", Ac.acb.law.ok(txt)},
   ActCk{"check: 17/18 does not", Bool.not(Ac.acb.law.ok(l17))},
   ActCk{"check: 018/18 does not (the same digits)", Bool.not(Ac.acb.law.ok(l018))},
   ActCk{"check: 9 languages and shapes answered", Nat.is_eq(Ac.acb.answered(txt), 9n)},
   ActCk{"check: one asked none is 8", Nat.is_eq(Ac.acb.answered(nob), 8n)},
   ActCk{"check: round 1's table fails bend and haskell", String.eq(Ac.acb.spaced(Ac.acb.bad(table)), "lang=bend lang=haskell ")},
   ActCk{"check: a table that answers passes", List.is_empty(&2, List<&2, U32>, Ac.acb.bad(act.b("lang=agda 8 864 906\nlang=nix 0 0 0\nlang=lean 0 3607 3952\n")))}]

# The per-language table (bend-episode langs) ------------------------------------------------------

def act.langs.got(m: Maybe<&2, List<&2, E.EpRec>>, +log: List<&2, U32>, +want: List<&2, U32>) -> List<&2, ActCk>:
  match m:
    case None{}:
      [ActCk{"langs: the fixture eplog reads", False{}}]
    case Some{+rs}:
      [ActCk{"langs: the fixture eplog reads (52 records)", Nat.is_eq(List.length(&2, E.EpRec, rs), 52n)},
       ActCk{"langs: the paste/awk table on r1's head", S.eq(Et.et.langs.of(log, rs, 4n), want)}]

def act.awk() -> List<&2, ActCk>:
  [ActCk{"langs: awk's fields", act.lines.eq(Et.et.lg.fields(act.b("  lang=x\t3 a  b \n")), ["lang=x", "3", "a", "b"])},
   ActCk{"langs: $6 > 0 as awk compares", Bool.and(Bool.and(Et.et.lg.pos(act.b("4")), Bool.not(Et.et.lg.pos(act.b("0")))),
     Bool.and(Bool.and(Bool.not(Et.et.lg.pos(act.b(""))), Bool.not(Et.et.lg.pos(act.b("-2")))), Bool.and(Et.et.lg.pos(act.b("x")), Bool.not(Et.et.lg.pos(act.b("0.0e5"))))))},
   ActCk{"langs: paste pads the side that ran out", act.lines.eq(Et.et.lg.paste([act.b("lang=a"), act.b("lang=b")], [act.b("0 x")]), ["lang=a\t0 x", "lang=b\t"])}]

# Units and trees ------------------------------------------------------------------------------

def act.units() -> List<&2, ActCk>:
  [ActCk{"units: UNIT/SHAPE is UNIT", act.is(Ac.acb.unit.of(act.b("repo:x/A.hs#f@1/direct")), "repo:x/A.hs#f@1")},
   ActCk{"units: no slash is itself", act.is(Ac.acb.unit.of(act.b("plain")), "plain")},
   ActCk{"units: a trailing slash goes", act.is(Ac.acb.unit.of(act.b("a/b/")), "a/b")},
   ActCk{"units: sort -u bytewise", act.lines.eq(Ac.acb.sort.u([act.b("b"), act.b("B"), act.b("a"), act.b("b"), act.b("")]), ["", "B", "a", "b"])},
   ActCk{"trees: repo:", act.m.is(Ac.acb.tr.repo(act.b("repo:mathlib4/Mathlib/X.lean#a@1")), "run/code-sources/repos/mathlib4")},
   ActCk{"trees: hackage:", act.m.is(Ac.acb.tr.hackage(act.b("hackage:aeson/src/A.hs#f@2")), "aeson")},
   ActCk{"trees: curated:", act.m.is(Ac.acb.tr.oc(act.b("curated:0x7067__unreal-review/spec/findings.bend#or4@120")), "run/code-sources/curated/0x7067__unreal-review")},
   ActCk{"trees: own: with no path", act.m.is(Ac.acb.tr.oc(act.b("own:x")), "run/code-sources/own/x")},
   ActCk{"trees: not own or curated", Bool.and(act.m.none(Ac.acb.tr.oc(act.b("repo:x/y"))), act.m.none(Ac.acb.tr.oc(act.b("owner:x/y"))))},
   ActCk{"trees: the Agda library file (grep -o, sed)", act.lines.eq(Ac.acb.tr.agda(act.b("/nix/store/s-standard-library-2.3/standard-library.agda-lib\n/W/run/code-sources/repos/agda-x/x.agda-lib\n/W/run/check-cache/agda/y.agda-lib\n/W/run/code-sources/repos/a/W/run/code-sources/repos/b\n"), "/W"),
     ["run/code-sources/repos/agda-x", "run/code-sources/repos/a", "run/code-sources/repos/b"])},
   ActCk{"trees: PKG-[0-9]* in hs/src", act.lines.eq(Ac.acb.tr.hk([act.b("aeson"), act.b("foo"), act.b("foo-1-bar")],
       Ac.acb.idx.of([act.b("aeson-2.2.1.0"), act.b("aeson-pretty-0.8"), act.b("foo-1-bar-2.0"), act.b("text-2.0")], False{}),
       Ac.acb.idx.of(Nil{}, True{})),
     ["run/check-cache/hs/src/aeson-2.2.1.0", "run/check-cache/hs/src/foo-1-bar-2.0", "run/check-cache/hs/src/foo-1-bar-2.0"])},
   ActCk{"trees: PKG-[0-9]*.tar.gz in tarballs", act.lines.eq(Ac.acb.tr.hk([act.b("aeson")], Ac.acb.idx.of(Nil{}, False{}),
       Ac.acb.idx.of([act.b("aeson-1.tar.gz"), act.b("aeson-2.2"), act.b("aeson-.tar.gz"), act.b("aeson-pretty-1.tar.gz")], True{})),
     ["run/code-sources/tarballs/aeson-1.tar.gz"])},
   ActCk{"trees: links outside the workspace are dropped", act.lines.eq(Ac.acb.inside([act.b("run/code-sources-next/curated/x"), act.b("../../nix/store/y")]), ["run/code-sources-next/curated/x"])}]

# Frames and pairs -------------------------------------------------------------------------------

def act.cuts() -> List<&2, ActCk>:
  +two = act.b("EP1 3\nabcEP1 2\nxyEP1 5\nab")
  +p = Ab.abx.pairs.scan(act.b("a\u{0}b\u{0}c\u{0}d"), Ab.AbxP{0n, 0n, 0n, 0n})
  +q = Ab.abx.pairs.scan(act.b("a\u{0}\u{0}\u{0}"), Ab.AbxP{0n, 0n, 0n, 0n})
  [ActCk{"cut-frames: two whole frames, a cut one", Bool.and(Nat.is_eq(Ab.abx.w.off(Ab.abx.frames.of(two)), 17n), Nat.is_eq(Ab.abx.w.n(Ab.abx.frames.of(two)), 2n))},
   ActCk{"cut-frames: not a header", Nat.is_eq(Ab.abx.w.off(Ab.abx.frames.of(act.b("XP1 3\nabc"))), 0n)},
   ActCk{"cut-frames: LEN must be digits", Bool.and(Nat.is_eq(Ab.abx.w.n(Ab.abx.frames.of(act.b("EP1 \n"))), 0n), Nat.is_eq(Ab.abx.w.n(Ab.abx.frames.of(act.b("EP1 1a\nab"))), 0n))},
   ActCk{"cut-frames: a whole file", Nat.is_eq(Ab.abx.w.off(Ab.abx.frames.of(act.b("EP1 3\nabcEP1 0\n"))), 15n)},
   ActCk{"cut-pairs: the last whole pair", Bool.and(Nat.is_eq(Ab.abx.p.good(p), 4n), Nat.is_eq(Ab.abx.p.pairs(p), 1n))},
   ActCk{"cut-pairs: empty fields count", Bool.and(Nat.is_eq(Ab.abx.p.good(q), 3n), Nat.is_eq(Ab.abx.p.pairs(q), 1n))},
   ActCk{"act-stop: a session from /proc/PID/stat", Bool.and(Nat.is_eq(Maybe.default(&2, Nat, Ab.abx.sid.of(act.b("4242 (bend-corpus-v2) S 1 4242 4242 0 -1 4194560\n")), 0n), 4242n),
     Nat.is_eq(Maybe.default(&2, Nat, Ab.abx.sid.of(act.b("7 (a) b) R 1 2 3 4\n")), 0n), 3n))}]

# agent-act --------------------------------------------------------------------------------------

def act.empty(n: Nat) -> List<&2, String>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      "" <> act.empty(k)

def act.cut.is(r: List<&2, U32> & List<&2, U32>, +w: String, +p: String) -> Bool:
  (a, b) = r
  Bool.and(S.eq(a, S.b(w)), S.eq(b, S.b(p)))

def act.aac() -> List<&2, ActCk>:
  +d = Aa.aac.settings.of(act.empty(13n))
  +nd = Aa.aac.settings.of(["nix run .#deploy --", "", "21", "", "", "", "", "", "", "", "", "3", "1"])
  [ActCk{"agent-act: agent-eval's environment, the script's defaults", act.strs.eq(Aa.aac.eval.env(d),
     ["BEND_FT_THREADS=2", "EVALSET=run/v2/act/prompts.nul", "AGENT_DEPLOY=run/v2/gcroot-deploy-agent/bin/deploy", "AGENT_RECORDS=train",
      "TEMPERATURE=0.7", "TOP_P=0.95", "AGENT_SEEDS=2", "AGENT_TAG=200000", "TOKENS=256", "AGENT_CALLS=4", "PROCS=5", "THREADS=2"])},
   ActCk{"agent-act: agent-eval's command line (K 0 left out)", act.strs.eq(Aa.aac.eval.argv(d, "C", "D", "0"),
     ["run/v2/gcroot-deploy-agent/bin/deploy", "corpus-v2", "agent-eval", "C", "D", "2"])},
   ActCk{"agent-act: K and a DEPLOY_BIN of words", act.strs.eq(Aa.aac.eval.argv(nd, "C", "D", "1"), ["nix", "run", ".#deploy", "--", "corpus-v2", "agent-eval", "C", "D", "2", "1"])},
   ActCk{"agent-act: accept and fixed", Bool.and(act.strs.eq(Aa.aac.ep.argv(d, "accept", "D"),
       ["run/agent/gcroot-bend-episode/bin/bend-episode", "accept", "4", "2", "D/accepted", "D/episodes.eplog"]),
     act.strs.eq(Aa.aac.ep.argv(nd, "fixed", "D"), ["run/agent/gcroot-bend-episode/bin/bend-episode", "fixed", "3", "1", "D/accepted", "D/episodes.eplog"]))},
   ActCk{"agent-act: PROCS from the environment", Bool.and(String.eq(Aa.aac.procs(nd), "21"), String.eq(Aa.aac.procs(d), "5"))},
   ActCk{"agent-act: whole lines out, the rest kept", Bool.and(Bool.and(act.cut.is(Aa.aac.cut(act.b("a\nb\nc")), "a\nb\n", "c"), act.cut.is(Aa.aac.cut(act.b("abc")), "", "abc")),
     act.cut.is(Aa.aac.cut(act.b("a\n")), "a\n", ""))}]

# the follower: exit statuses, and a line passed on as the program wrote it
def act.follow() -> IO(List<&2, ActCk>):
  do IO<List<&2, ActCk>>:
    +a : U32 <- Aa.aac.follow(Nil{}, "true", Nil{})
    +b : U32 <- Aa.aac.follow(["ACT_TEST=7"], "sh", ["-c", "exit $ACT_TEST"])
    +c : U32 <- Aa.aac.follow(Nil{}, "printf", ["ok agent-act: the follower passes a line on\\n"])
    return [ActCk{"agent-act: the follower's exit statuses", Bool.and(Bool.and(U32.is_eq(a, 0), U32.is_eq(b, 7)), U32.is_eq(c, 0))}]

def main() -> IO(Unit):
  do IO<Unit>:
    +txt : List<&2, U32> <- S.read("fixtures/act/check.txt")
    +log : List<&2, U32> <- S.read("fixtures/act/r1-head.eplog")
    +want : List<&2, U32> <- S.read("fixtures/act/r1-head.langs")
    fl : List<&2, ActCk> <- act.follow()
    +table : List<&2, U32> = act.b("lang=agda 8 864 906\nlang=bend 611 64 764\nlang=haskell 2596 0 2778\nlang=lean 0 3607 3952\nlang=nix 0 730 1008\n")
    act.say(List.concat(&2, ActCk, [act.procs(), act.check(txt, table), act.langs.got(E.ep.get(log), log, want), act.awk(), act.units(), act.cuts(), act.aac(), fl]), 0n, "")
