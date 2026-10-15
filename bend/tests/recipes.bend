import Base
import ../Sys.bend as S
import ../Sha256.bend as H
import ../CorpusV2/Steps.bend as St
import ../CorpusV2/Keyed.bend as K
import ../CorpusV2/S2.bend as T2
import ../CorpusV2/ActSet.bend as A
import ../CorpusV2/Steady.bend as M
import ../CorpusV2/Recipes.bend as R
import ../Box/Drive.bend as D
import ../Box/Evals.bend as E

# The run recipes' pure parts and keyed-order (2026-10-15, the plan's Phase 4:
# bend/CorpusV2/{Keyed,S2,ActSet,Steady,Recipes}.bend, bend/Box/{Drive,Evals}.bend)
# against what the scripts they replace computed: awk's share and McNemar p
# (printed by awk on the same numbers), the trainer's own lr= at run 3's
# boundary, sha256sum, `bend-corpus-v2 specs-next` and `per`, and run 3's
# files (fixtures/recipes: E1's report.txt, a behaviour verdicts.tsv, the end
# of S1's log; fixtures/box: the head of S1's plan).  Each check prints `ok
# NAME` or `FAIL NAME`; any FAIL exits 1.  Run from bend/tests.

type RcpCk is Data:
  RcpCk{name: String, ok: Bool}

def rt.end(ok: Bool, +bad: Nat, +names: String) -> IO(Unit):
  match ok:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.die(Unit, 1, "recipes: " ++ Nat.show(bad) ++ " check(s) failed:" ++ names)

def rt.say(cs: List<&2, RcpCk>, +bad: Nat, +names: String) -> IO(Unit):
  match cs:
    case Nil{}:
      rt.end(Nat.is_eq(bad, 0n), bad, names)
    case RcpCk{+n, +ok} <> t:
      do IO<Unit>:
        IO.print(Bool.pick(String, ok, "ok ", "FAIL ") ++ n)
        rt.say(t, Bool.pick(Nat, ok, bad, 1n+bad), Bool.pick(String, ok, names, names ++ " " ++ n))

def rt.is(+got: String, +want: String) -> Bool:
  String.eq(got, want)

def rt.bs(+got: List<&2, U32>, +want: String) -> Bool:
  S.eq(got, S.b(want))

def rt.strs(xs: List<&2, List<&2, U32>>) -> String:
  match xs:
    case Nil{}:
      ""
    case +x <> t:
      S.str(x) ++ "|" ++ rt.strs(t)

# keyed-order --------------------------------------------------------------------------------

def rt.keyed() -> List<&2, RcpCk>:
  +rec = K.kor.nul.rec(K.kor.key(S.b("salt1"), S.b("a")), S.b("a"), S.b("text\ta\nb"))
  [RcpCk{"keyed key is sha256(SALT NUL id)", rt.is(K.kor.key(S.b("salt1"), S.b("a")), "506402369055c1874599ee0ae593d2c20bcabf14c49ff9cb23efec2bacdc637f")},
   RcpCk{"keyed pair round trip", rt.bs(K.kor.nul.back(List.take(&2, U32, rec, Nat.sub(S.len(rec), 1n))), "a\u{0}text\ta\nb\u{0}")},
   RcpCk{"keyed line id (JSON, escapes decoded)", rt.bs(K.kor.line.id(S.b("{\"id\": \"x/\\u0041.hs\", \"text\": \"1\"}")), "x/A.hs")},
   RcpCk{"keyed line id (no object: the line)", rt.bs(K.kor.line.id(S.b("plain line")), "plain line")},
   RcpCk{"awk fields", rt.is(rt.strs(K.kor.words(S.b("  segment\t12  x \n"))), "segment|12|x|")}]

def rt.keyed.io(+dir: String) -> IO(List<&2, RcpCk>):
  do IO<List<&2, RcpCk>>:
    S.write(dir ++ "/t.nul", S.b("a\u{0}text a\nline2\u{0}b\u{0}tb\u{0}c\u{0}\u{0}d\u{0}tab\there\u{0}"))
    r : Nat & Nat <- K.kor.order(False{}, "salt1", K.kor.fuel(), dir ++ "/t.nul", dir ++ "/o.nul")
    +o : List<&2, U32> <- S.read(dir ++ "/o.nul")
    r2 : Nat & Nat <- K.kor.order(False{}, "salt1", 2n, dir ++ "/t.nul", dir ++ "/o2.nul")
    +o2 : List<&2, U32> <- S.read(dir ++ "/o2.nul")
    S.write(dir ++ "/t.jsonl", S.b("{\"id\": \"x/\\u0041.hs\", \"text\": \"1\"}\n{\"id\": \"y\", \"text\": \"2\"}\nplain line\n{\"id\": \"y\", \"text\": \"1\"}\nlast"))
    r3 : Nat & Nat <- K.kor.order(True{}, "s", K.kor.fuel(), dir ++ "/t.jsonl", dir ++ "/o.jsonl")
    +o3 : List<&2, U32> <- S.read(dir ++ "/o.jsonl")
    K.kor.cat([dir ++ "/t.nul", dir ++ "/o2.nul"], dir ++ "/cat.nul")
    +n : Nat <- K.kor.pairs(dir ++ "/cat.nul")
    return [RcpCk{"keyed-order nul (sha256sum's order d c a b)", rt.bs(o, "d\u{0}tab\there\u{0}c\u{0}\u{0}a\u{0}text a\nline2\u{0}b\u{0}tb\u{0}")},
      RcpCk{"keyed-order nul, the first 2", rt.bs(o2, "d\u{0}tab\there\u{0}c\u{0}\u{0}")},
      RcpCk{"keyed-order lines (ties by the line; a last line gains its newline)",
        rt.bs(o3, "{\"id\": \"x/\\u0041.hs\", \"text\": \"1\"}\nlast\nplain line\n{\"id\": \"y\", \"text\": \"1\"}\n{\"id\": \"y\", \"text\": \"2\"}\n")},
      RcpCk{"cat and pairs", Nat.is_eq(n, 6n)}]

# s2 -----------------------------------------------------------------------------------------------

def rt.s2(+plan: List<&2, U32>, +s1log: List<&2, U32>) -> List<&2, RcpCk>:
  +pl = T2.s2s.lines(plan)
  +rest = T2.s2s.rest(pl, 170n)
  [RcpCk{"s2 share = awk's (262 of 315153)", rt.is(T2.s2s.share(262n, 314891n), "0.0009")},
   RcpCk{"s2 share = awk's (six more)", Bool.and(Bool.and(rt.is(T2.s2s.share(3238n, 314891n), "0.0102"), rt.is(T2.s2s.share(1n, 1n), "0.5000")),
     Bool.and(Bool.and(rt.is(T2.s2s.share(5n, 99995n), "0.0001"), rt.is(T2.s2s.share(9999n, 1n), "0.9999")),
       Bool.and(rt.is(T2.s2s.share(3171n, 311653n), "0.0101"), rt.is(T2.s2s.share(0n, 5n), "0.0000"))))},
   RcpCk{"s2 NLR is run 3's lr= at 36696", rt.is(T2.s2s.nlr("3e-4", 36696n, 300n, 56497n), "0.00008288989")},
   RcpCk{"s2 the S1 log's last lr=", rt.bs(Maybe.default(&2, List<&2, U32>, T2.s2s.lr.last(s1log, None{}), Nil{}), "0.00008288989")},
   RcpCk{"s2 plan steps", Nat.is_eq(T2.s2s.steps(pl), 56497n)},
   RcpCk{"s2 a segment starts at 170, none at 171", Bool.and(T2.s2s.starts(pl, 170n), Bool.not(T2.s2s.starts(pl, 171n)))},
   RcpCk{"s2 the rest from 170 (awk's lines, sha256)", rt.is(H.sha256(T2.s2s.unlines(rest)), "a18df0ca9125270a1f9e9fc22cf3a931db3917de50b9c8b4c84d3dd67f95fe9e")},
   RcpCk{"s2 the rest's windows and segments", Bool.and(Nat.is_eq(T2.s2s.tw(rest, False{}), 33682n), Nat.is_eq(List.length(&2, List<&2, U32>, rest), 27n))},
   RcpCk{"s2 per", Bool.and(Bool.and(Nat.is_eq(T2.s2s.per(0n), 1n), Nat.is_eq(T2.s2s.per(149n), 1n)), Bool.and(Nat.is_eq(T2.s2s.per(150n), 2n), Nat.is_eq(T2.s2s.per(4754n), 48n)))},
   RcpCk{"s2 stage line relative to the trainer's directory",
     Bool.and(rt.is(T2.s2s.stage("5000", T2.s2s.rel("/root/formalTransformer/run/v3/S2", "/root/formalTransformer")), "s2 traind-next 5000 run/v3/S2/plan-fp100m-b16-windows.tsv run/v3/S2 fp100m"),
       rt.is(T2.s2s.rel("run/v3/S2", "/root/formalTransformer"), "run/v3/S2"))}]

# actset, steady-mix, recipes ------------------------------------------------------------------

def rt.unit(+id: String, +want: String) -> Bool:
  rt.bs(A.ast.unit(S.b(id)), want)

def rt.misc() -> List<&2, RcpCk>:
  [RcpCk{"actset unit", Bool.and(Bool.and(rt.unit("repo:x/A.hs#f@12+3/direct", "repo:x/A.hs#f@12"), rt.unit("a/b/c", "a/b")),
     Bool.and(Bool.and(rt.unit("x#y+12", "x#y"), rt.unit("a#b+c/d", "a#b+c")), Bool.and(rt.unit("a+1/b", "a+1"), rt.unit("p#q+/r", "p#q+"))))},
   RcpCk{"steady take (bash's $(( )), big integers)", Bool.and(Bool.and(Nat.is_eq(M.smx.take("all", 10n, 100n), 10n), Nat.is_eq(M.smx.take("50", 10n, 100n), 5n)),
     Bool.and(Nat.is_eq(M.smx.take("2900000000", 1234567n, 1900000000n), 1234567n), Nat.is_eq(M.smx.take("2900000000", 1234567n, Nat.mul(9n, 1000000000n)), 397804n)))},
   RcpCk{"steady language of an id", Bool.and(Bool.and(Nat.is_eq(M.smx.lang(M.smx.id(S.b("{\"id\": \"repo:x/a.lhs\", \"text\": 1}"))), 1n),
     Nat.is_eq(M.smx.lang(M.smx.id(S.b("{\"id\":\"x/y.lagda.md\",\"text\":\"\"}"))), 3n)), Bool.and(Nat.is_eq(M.smx.lang(M.smx.id(S.b("{\"id\":  \"n.nix\"}"))), 4n),
       Nat.is_eq(M.smx.lang(M.smx.id(S.b("{\"name\": \"x.hs\"}"))), 0n)))},
   RcpCk{"steady cell (printf %7.1f%%)", Bool.and(rt.is(M.smx.cell(1n, 3n), "    33.3%"), Bool.and(rt.is(M.smx.cell(1n, 8n), "    12.5%"), rt.is(M.smx.cell(0n, 0n), "     0.0%")))},
   RcpCk{"render jobs (23: Bend 8+1, Haskell, Lean, Agda 3+1, Nix 1+1)", Nat.is_eq(List.length(&2, R.RcJob, R.rcp.jobs(R.rcp.langs.render())), 23n)},
   RcpCk{"render log sums (awk's $2, $5)", Bool.and(Nat.is_eq(R.rcp.ut.u(R.rcp.sums(S.split.lines(S.b("transcript: 11257 units in, 22501 transcripts out\nwarning x\n")), 0n, 0n)), 11257n),
     Nat.is_eq(R.rcp.ut.t(R.rcp.sums(S.split.lines(S.b("transcript: 11257 units in, 22501 transcripts out\ntranscript: 3 units in, 4 transcripts out")), 0n, 0n)), 22505n))}]

# drive (stage next, stage raw, feed) -----------------------------------------------------------

def rt.drive() -> List<&2, RcpCk>:
  [RcpCk{"next specs = bend-corpus-v2 specs-next's", rt.is(Maybe.default(&2, String, D.drv.specs.next("1.0", ["haskell-new:300", "bend-new:100"]), ""),
     "haskell-new:15 bend-new:5 haskell:5:cycle lean:3:cycle agda:3:cycle nix:1:cycle bend:8:cycle")},
   RcpCk{"next LABEL=DIR", Bool.and(rt.is(D.drv.lab("haskell-new=run/a=b"), "haskell-new"), rt.is(D.drv.dir("haskell-new=run/a=b"), "run/a=b"))},
   RcpCk{"raw mix specs (per = corpus-v2 per)", rt.is(String.join(D.drv.mix.specs("run/raw", 79075n, 50079n, 53663n, 24694n, 126763n), " "),
     "run/raw/src/haskell.jsonl:100 run/raw/src/lean.jsonl:63 run/raw/src/agda.jsonl:68 run/raw/src/nix.jsonl:31 run/raw/src/bend.jsonl:160 run/raw/src/tr-haskell.jsonl:41:cycle run/raw/src/tr-lean.jsonl:26:cycle run/raw/src/tr-agda.jsonl:28:cycle run/raw/src/tr-nix.jsonl:13:cycle run/raw/src/tr-bend.jsonl:67:cycle")},
   RcpCk{"feed stage line", rt.is(D.drv.stage.line("raw3"), "raw3 traind-next 0 run/raw3/plan-raw3-b16-windows.tsv run/raw3 raw3")},
   RcpCk{"feed newest trainer log (ls -t | grep -v ^eval)", rt.bs(Maybe.default(&2, List<&2, U32>, D.drv.newest(S.split.lines(S.b("out\neval-s2.log\nstage.log.d\ns2.log\ntrain.log\n"))), Nil{}), "s2.log")},
   RcpCk{"feed CUR (grep -o step= | tail -1)", Bool.and(rt.is(D.drv.cur(S.b("s2.log"), S.b("step=1/9\nstep=36697/56725\n")), "s2 step=36697/56725"), rt.is(D.drv.cur(S.b("s2.log"), Nil{}), "s2 "))},
   RcpCk{"feed slice steps (the plan's field 3)", Nat.is_eq(D.drv.plan.steps(S.b("plan 1 2206 mixed-v2:x 9 9\nsegment 0 0 1\n")), 2206n)}]

# evals ---------------------------------------------------------------------------------------

def rt.cfg() -> List<&2, U32>:
  S.b("# a comment\nevals e1 e5\n\ndeploy a b\ntag s2-x run/a.checkpoint run/e\ntag v2-y run/b.checkpoint run/f\npair s2-x v2-y\n  # indented\nevalset P\nevalset Q\n")

def rt.ep() -> List<&2, U32>:
  S.b("prompt\n## Term\n\n```lean\ndef a := 1\n```\n## Echo\nerr\n## Term\n\n```lean\ndef a := 1\n```\n## Echo\nerr\n## Term\n\n```lean\ndef a := 2\n```\n## Term\n\nno fence")

def rt.cp.is(r: Nat & Nat, +n: Nat, +c: Nat) -> Bool:
  (+a, +b) = r
  Bool.and(Nat.is_eq(a, n), Nat.is_eq(b, c))

def rt.evals(+report: List<&2, U32>, +verdicts: List<&2, U32>) -> List<&2, RcpCk>:
  +kvs = E.evr.cfg(rt.cfg())
  +ts = E.evr.tags(kvs)
  [RcpCk{"evals McNemar p = awk's (pair.sh, 11 pairs)", rt.is(String.join([E.evr.p(16n, 3n), E.evr.p(17n, 4n), E.evr.p(13n, 7n), E.evr.p(3n, 2n), E.evr.p(2n, 10n), E.evr.p(0n, 0n),
     E.evr.p(1n, 0n), E.evr.p(7n, 15n), E.evr.p(4n, 21n), E.evr.p(11n, 12n), E.evr.p(30n, 40n)], " "), "0.00 0.01 0.26 1.00 0.04 1.00 1.00 0.13 0.00 1.00 0.28")},
   RcpCk{"evals config", Bool.and(Bool.and(rt.is(String.join(E.evr.get(kvs, "evals", Nil{}), " "), "e1 e5"), rt.is(E.evr.get1(kvs, "evalset", ""), "Q")),
     Bool.and(Nat.is_eq(List.length(&2, E.EvTag, ts), 2n), rt.is(E.evr.tag.ckpt(Maybe.default(&2, E.EvTag, E.evr.tag.find(ts, "v2-y"), E.EvTag{"", "", ""})), "run/b.checkpoint")))},
   RcpCk{"evals TAGS picks in its own order", rt.is(E.evr.names(E.evr.pick(["v2-y", "nope", "s2-x"], ts)), " v2-y s2-x")},
   RcpCk{"evals pair line (pair.sh's counts)", rt.is(E.evr.line("E1", "a", "b", [S.b("x"), S.b("y"), S.b("y"), S.b("z")], [S.b("z"), S.b("w")]),
     "E1        a               b                A  3  B  2  both  1  only A  2  only B  1  p 1.00")},
   RcpCk{"evals behaviour counts (cut -f2 | sort | uniq -c)", rt.is(E.evr.counts(verdicts), " 6 compile 18 pass 6 wrong")},
   RcpCk{"evals behaviour passes", Nat.is_eq(List.length(&2, List<&2, U32>, E.evr.tsv.pass(S.split.lines(verdicts), S.b("haskell/"))), 18n)},
   RcpCk{"evals E1 by language (report.txt)", rt.is(E.evr.lp.row(E.evr.langs(), E.evr.lp.lines(S.split.lines(report), Nil{}, False{})), "    15/31     9/46      3/7      1/9      4/6")},
   RcpCk{"evals E5 solved (agent.nul field 5)", rt.is(rt.strs(E.evr.solved(E.evr.nul(S.b("a/direct\u{0}0\u{1E}haskell\u{1E}a\u{1E}direct\u{1E}1\u{1E}1\u{1E}6.4\u{0}b/repair\u{0}1\u{1E}lean\u{1E}b\u{1E}repair\u{1E}0\u{1E}4\u{1E}9.1\u{0}")))), "a/direct|")},
   RcpCk{"evals copies (copy.awk: 3 retries, 1 copy)", rt.cp.is(E.evr.cp.one(rt.ep()), 3n, 1n)}]

def main() -> IO(Unit):
  do IO<Unit>:
    +plan : List<&2, U32> <- S.read("fixtures/box/plan-s1-head.tsv")
    +s1log : List<&2, U32> <- S.read("fixtures/recipes/s1-tail.log")
    +report : List<&2, U32> <- S.read("fixtures/recipes/report-s2-56725.txt")
    +verdicts : List<&2, U32> <- S.read("fixtures/recipes/verdicts-s2-56725.tsv")
    +dir : String <- S.mktemp()
    io : List<&2, RcpCk> <- rt.keyed.io(dir)
    S.rm(dir)
    rt.say(List.concat(&2, RcpCk, [rt.keyed(), io, rt.s2(plan, s1log), rt.misc(), rt.drive(), rt.evals(report, verdicts)]), 0n, "")
